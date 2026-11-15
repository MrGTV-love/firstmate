#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# Usage: bash tests/fm-teardown.test.sh [test_function_name ...]
# With no names, run every registered case in order. Named cases run in that
# same order; unknown names are rejected before any test case runs.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + real work pushed to origin, PR not merged -> REFUSE (pushed is not landed)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch;
#       test_local_only_force_overrides_unpushed lives in tests/fm-teardown-cleanup.test.sh)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#   (q2) no-mistakes + squash-merged, local followed pipeline rebase -> ALLOW
#   (q3) no-mistakes + squash-merged, same file, different content   -> REFUSE
#   (q4) no-mistakes + squash-merged rebased local plus extra commit -> REFUSE
#   (q5) gh down + squash-merged stale local, content not in default -> REFUSE
#   (q6) no-mistakes + squash-merged, pre-rebase copy pushed elsewhere, every patch in PR head -> ALLOW
#   (q7) same, but one pre-rebase commit's change is missing from the PR head -> REFUSE
#   (q8) same, but the merge of main carries a change of its own     -> REFUSE
#   (q9) no-mistakes + squash-merged, copy is the input of the run that pushed the merged PR head, pipeline rewrote it -> ALLOW
#   (q10) same, but the copy's HEAD is not exactly the run's input head (behind it, past it, or elsewhere), or no recorded run ties to the merged PR head, or a record is missing -> REFUSE
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
#
# Nested repositories survive Treehouse's own `git clean -fd`:
#   (z1) scout + nested clone + scratch file                 -> no untracked entries
#   (z2) ship + nested clone, no --force                     -> REFUSE, bytes unchanged
#   (z3) return leaves residue                               -> lost-slot warning, cleanup, exit 4
#   (z3b) residue, then a later step refuses                 -> lost-slot warning still printed
#   (z3c) forced secondmate + child scout nested clone       -> child copy returns clean
#   (z3d) forced secondmate + child return leaves residue    -> warning, retirement completes, exit 4
#   (z3e) return removes the copy                            -> cannot-verify warning, exit 4
#   (z4) scout + ignored file                                -> ignored file survives
set -u

# shellcheck source=tests/fm-teardown-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-helpers.sh" || exit 1

test_local_only_fork_remote_allows() {
  local case_dir rc leftover
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  # The supervision branch's bounded per-task outcome cache is a footprint of
  # the retired task, not a record anything reads after it is gone.
  printf 'fm-branch-outcome-index-v1\t5\t0\t-\n' > "$case_dir/state/.task-x1.branch-outcome-index"
  printf 'gen=g1\n' > "$case_dir/state/task-x1.control-exit"
  printf '%s\tattempt\n' "$(date +%s)" > "$case_dir/state/.session-end-relaunch-task-x1"
  printf 'g1\t1\trelaunched\n' > "$case_dir/state/.session-end-handled-task-x1"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: teardown left the task's branch outcome index behind"
  for leftover in task-x1.control-exit .session-end-relaunch-task-x1 .session-end-handled-task-x1; do
    [ ! -e "$case_dir/state/$leftover" ] \
      || fail "fork-allow: teardown left the task's $leftover behind"
  done
  # The supervision branch reports the teardown it just performed AFTER the
  # task's records are gone (bin/fm-branch-prompt.sh); that report must be
  # stored, must publish its ready sequence, and must not recreate the index.
  post_seq=$(FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-x1 --verdict captain --summary 'PR merged and cleaned up') \
    || fail "fork-allow: post-teardown branch report was refused"
  [ "$post_seq" = 1 ] || fail "fork-allow: post-teardown branch report got seq $post_seq, expected 1"
  grep -q '"task":"task-x1"' "$case_dir/state/branch-outcomes.jsonl" \
    || fail "fork-allow: post-teardown branch report was not stored"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: post-teardown branch report recreated the retired task index"
  [ "$(cat "$case_dir/state/.branch-outcome-index-ready")" = 1 ] \
    || fail "fork-allow: post-teardown branch report did not publish its ready sequence"
  fm_test_wait_until --progress-file "$case_dir/state/home-summary.json" -- jq -e --arg id task-x1 "
    .schema == \"fm-secondmate-home-summary.v1\"
    and all(.endpoints[]; .id != \$id)
  " "$case_dir/state/home-summary.json" \
    || fail "successful task teardown did not publish the task's removal from the home summary ledger"
  pass "local-only worktree with HEAD on a fork remote is torn down and the home summary is refreshed"
}

# A successful teardown publishes the home summary only as a side effect, so it
# must not wait for a refresh already in flight. Hold the refresh lock with a
# 20-second deadline: a blocking trigger would wait that deadline out and record
# a failure; a detached one records nothing and leaves its marker.
test_teardown_does_not_wait_for_the_home_summary_refresh() {
  local case_dir rc holder marker
  case_dir=$(make_case summary-detach)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  marker="$case_dir/state/.test-summary-lock-held"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
    : > "$3"
    sleep 120
  ' _ "$ROOT" "$case_dir" "$marker" &
  holder=$!
  fm_test_wait_until --while-alive "$holder" -- test -e "$marker" || { kill "$holder" 2>/dev/null; fail "could not hold the refresh lock"; }
  rc=0
  FM_HOME_SUMMARY_TIMEOUT=20 run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "teardown should succeed with a refresh in flight"
  fm_test_wait_until --progress-file "$case_dir/state/.home-summary-refresh.pending" -- test -e "$case_dir/state/.home-summary-refresh.pending" \
    || { kill "$holder" 2>/dev/null; fail "the teardown trigger left no marker for the refresh in flight"; }
  sleep 2
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ ! -s "$case_dir/state/.home-summary-refresh.log" ] \
    || fail "teardown waited out a refresh and recorded a failure: $(cat "$case_dir/state/.home-summary-refresh.log")"
  pass "teardown does not wait for the home summary refresh"
}

test_teardown_closes_the_backlog_item_itself() {
  local case_dir out
  case_dir=$(make_case tasks-axi-close)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  mkdir -p "$case_dir/state/.nm-read-cache-task-x1"
  printf 'entry\n' > "$case_dir/state/.nm-read-cache-task-x1/status"

  out=$(run_teardown "$case_dir") || fail "teardown failed with a real backlog"
  assert_absent "$case_dir/state/.nm-read-cache-task-x1" \
    "teardown left the task's no-mistakes read cache behind"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown returned success while its backlog item was still open: $(backlog_row_state "$case_dir")"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "closed backlog item did not record the task's PR"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed close left its pending-close record behind"
  printf '%s\n' "$out" | grep -F 'bin/fm-tasks-axi.sh ready' >/dev/null \
    || fail "teardown dropped the dependency-cleared follow-up: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'Run tasks-axi done' >/dev/null \
    && fail "teardown still asked a later turn to close the item it already closed: $out"
  pass "teardown closes its own backlog item before reporting success"
}

test_teardown_records_task_closed_once() {
  local case_dir rc=0
  case_dir=$(make_case ledger-closed)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  : > "$case_dir/config/fleet-ledger"

  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "teardown failed with the ledger on: $(cat "$case_dir/stderr")"
  [ "$(backlog_row_state "$case_dir")" = "done" ] || fail "the backlog item was not closed"
  assert_equals '["task-x1","merged_pr","https://github.com/example/repo/pull/7",true]' \
    "$(ledger_closed_rows "$case_dir")" "task.closed record"

  # A second teardown finds no task record and closes nothing.
  run_teardown "$case_dir" > /dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a repeated teardown unexpectedly succeeded"
  assert_equals 1 "$(ledger_closed_rows "$case_dir" | wc -l | tr -d ' ')" "task.closed records after a repeated teardown"
  pass "ledger on: a completed teardown records one task.closed with the PR, and a repeat records none"
}

test_teardown_closed_record_names_each_evidence_kind() {
  local case_dir
  # A local-only landing is recorded as local main, with no PR.
  case_dir=$(make_case ledger-closed-local)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt landed "merged work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  seed_backlog_in_flight "$case_dir"
  : > "$case_dir/config/fleet-ledger"
  run_teardown "$case_dir" > /dev/null 2> "$case_dir/stderr" || fail "local-only teardown failed: $(cat "$case_dir/stderr")"
  assert_equals '["task-x1","local_main",null,true]' "$(ledger_closed_rows "$case_dir")" "local-only task.closed record"

  # A captain's drop is recorded as the drop file.
  case_dir=$(make_case ledger-closed-drop)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" unlanded.txt "unlanded work" "unlanded work"
  seed_backlog_in_flight "$case_dir"
  : > "$case_dir/config/fleet-ledger"
  printf 'Drop it, the plan changed.\n' > "$case_dir/drop.txt"
  run_teardown "$case_dir" --force --drop-file "$case_dir/drop.txt" > /dev/null 2> "$case_dir/stderr" \
    || fail "forced drop teardown failed: $(cat "$case_dir/stderr")"
  assert_equals '["task-x1","drop_file",null,true]' "$(ledger_closed_rows "$case_dir")" "dropped task.closed record"
  pass "ledger on: the closed record names local main and a captain's drop as its evidence"
}

test_teardown_refusal_and_failing_ledger_leave_teardown_alone() {
  local case_dir off_dir rc=0 normalized_on normalized_off
  # A refused teardown closes nothing and records nothing.
  case_dir=$(make_case ledger-closed-refused)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" unlanded.txt "unlanded work" "unpushed work"
  seed_backlog_in_flight "$case_dir"
  : > "$case_dir/config/fleet-ledger"
  run_teardown "$case_dir" > /dev/null 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "ledger-closed-refused: teardown should refuse"
  assert_equals "" "$(ledger_closed_rows "$case_dir")" "task.closed records after a refused teardown"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] || fail "a refused teardown moved its backlog item"

  # An unwritable ledger changes neither the exit status nor the output.
  case_dir=$(make_case ledger-closed-failing)
  off_dir=$(make_case ledger-closed-off)
  for dir in "$case_dir" "$off_dir"; do
    write_meta "$dir" no-mistakes ship
    printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$dir/state/task-x1.meta"
    seed_backlog_in_flight "$dir"
  done
  : > "$case_dir/config/fleet-ledger"
  mkdir "$case_dir/state/fleet-ledger.jsonl"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "ledger-closed-failing: an unwritable ledger must not fail teardown"
  [ "$(backlog_row_state "$case_dir")" = "done" ] || fail "the backlog item was not closed when the ledger failed"
  assert_grep 'fm-fleet-ledger: could not record closed for task-x1' "$case_dir/stderr" "the failed ledger write was not reported"
  run_teardown "$off_dir" > "$off_dir/stdout" 2> "$off_dir/stderr" || fail "flag-off teardown failed"
  normalized_on=$(sed "s#$case_dir#CASE#g" "$case_dir/stdout")
  normalized_off=$(sed "s#$off_dir#CASE#g" "$off_dir/stdout")
  assert_equals "$normalized_off" "$normalized_on" "teardown stdout with an unwritable ledger and with the flag absent"
  # Each failing ledger write (cleaned_up, then closed) costs exactly one line.
  assert_equals 1 "$(grep -c 'could not record closed for task-x1' "$case_dir/stderr")" "closed-record failure lines on stderr"
  assert_equals 2 "$(grep -c 'fm-fleet-ledger' "$case_dir/stderr")" "ledger lines on stderr"
  pass "a refused teardown records nothing, and an unwritable ledger costs one stderr line without changing teardown"
}

test_teardown_closes_a_gerrit_task_with_its_change_url_as_a_note() {
  local case_dir out real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  case_dir=$(make_case tasks-axi-close-gerrit)
  write_meta "$case_dir" no-mistakes ship
  printf 'pr=%s\n' "$gerrit_url" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  # Pin the refusal tasks-axi applies to a --pr link that is not a canonical
  # GitHub pull request, so this case keeps reproducing whatever the installed
  # release accepts.
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"

  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed Gerrit task failed: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown left a landed Gerrit task's backlog item at $(backlog_row_state "$case_dir"): $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" --full \
    | grep -F "body: \"Gerrit change $gerrit_url\"" >/dev/null \
    || fail "closed Gerrit backlog item did not record its change URL as a note"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed Gerrit close left its pending-close record behind"

  case_dir=$(make_case tasks-axi-close-github-under-refusal)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  cp "$TMP_ROOT/tasks-axi-close-gerrit/fakebin/tasks-axi" "$case_dir/fakebin/tasks-axi"
  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed GitHub task failed: $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" \
    | grep -F 'links: "pr:https://github.com/example/repo/pull/7"' >/dev/null \
    || fail "a GitHub pull request no longer closed as the item's pr link"
  pass "teardown closes a landed Gerrit task with its change URL as a note and a GitHub task with --pr"
}

test_teardown_manual_backend_leaves_the_backlog_to_the_operator() {
  local case_dir out backlog_path
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "manual backlog backend was mutated by teardown anyway"
  backlog_path=$(cd "$case_dir/data" && pwd -P)/backlog.md
  printf '%s\n' "$out" | grep -F "Update $backlog_path - move task-x1 to Done" >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  pass "teardown honors config/backlog-backend=manual and still finishes cleanly"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" unlanded.txt "unlanded work" "unpushed work"
  # No fork, no push to origin, not merged into main.

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc variant wt_head
  for variant in unpushed pushed offline no-remote; do
    case_dir=$(make_case "merged-main-$variant")
    write_meta "$case_dir" local-only ship
    wt_commit_file "$case_dir" feature.txt landed "merged work"
    wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
    git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
    if [ "$variant" = pushed ]; then
      git -C "$case_dir/wt" push -q origin fm/task-x1
    elif [ "$variant" = no-remote ]; then
      git -C "$case_dir/wt" remote remove origin
    elif [ "$variant" = offline ]; then
      git -C "$case_dir/wt" remote set-url origin "$case_dir/nonexistent-origin"
    fi
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "merged-main-$variant: local landing refused: $(cat "$case_dir/stderr")"
    ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main-$variant: teardown printed a refusal"
  done
  pass "local main landing succeeds independently of pushed and remote availability"
}

test_no_mistakes_pushed_branch_without_merge_refuses() {
  local case_dir rc words
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt hello "shippable work"
  # The branch reached origin, but no PR merged it and main lacks its content: recoverable, not delivered.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "nm-origin: a pushed but unmerged ship must refuse"
  grep -q "a pushed branch alone is not completion" "$case_dir/stderr" || fail "nm-origin: the refusal did not say pushed is not landed"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "nm-origin: the refusal removed the task record"

  # Without the captain's words, --force is refused too, and nothing is discarded.
  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "nm-origin: --force without the captain's words must refuse"
  grep -q "requires --drop-file" "$case_dir/stderr" || fail "nm-origin: the refusal did not ask for the captain's words"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "nm-origin: a refused --force removed the task record"

  # With the words, the discard proceeds: the words are kept, and the row records a drop.
  words="$case_dir/words.txt"
  printf 'Drop it; the premise is gone.\n' > "$words"
  rc=0
  run_teardown "$case_dir" --force --drop-file "$words" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "nm-origin: a drop with the captain's words must complete: $(cat "$case_dir/stderr")"
  cmp -s "$words" "$case_dir/data/task-x1/captain-drop.md" || fail "nm-origin: the captain's exact words were not retained"
  grep -F "[x] task-x1" "$case_dir/data/backlog.md" >/dev/null || fail "nm-origin: the dropped row was not closed"
  grep -E '^[[:space:]]+dropped$' "$case_dir/data/backlog.md" >/dev/null || fail "nm-origin: the row does not record the fixed drop note"
  pass "a pushed but unmerged ship refuses, and only the captain's own words discard it"
}

test_drop_file_without_force_is_a_usage_error() {
  local case_dir rc
  case_dir=$(make_case drop-no-force)
  write_meta "$case_dir" no-mistakes ship
  rc=0
  run_teardown "$case_dir" --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 2 "$rc" "drop-no-force: --drop-file alone must be a usage error"
  rc=0
  run_teardown "$case_dir" --force --drop-file "$case_dir/empty.txt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "drop-no-force: an unreadable words file must refuse"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "drop-no-force: a refusal removed the task record"
  pass "--drop-file needs --force and a readable words file"
}

test_forced_dirty_landed_deliverables_retain_captain_words() {
  local case_dir kind delivery mode rc words
  for delivery in ship scout local-only; do
    case_dir=$(make_case "forced-dirty-landed-$delivery")
    kind=$delivery
    mode=no-mistakes
    if [ "$delivery" = local-only ]; then kind=ship; mode=local-only; fi
    write_meta "$case_dir" "$mode" "$kind"
    seed_backlog_in_flight "$case_dir" "$kind"
    if [ "$kind" = ship ]; then
      wt_commit_file "$case_dir" feature.txt landed "landed feature"
      if [ "$delivery" = local-only ]; then
        git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
        git -C "$case_dir/wt" remote set-url origin "$case_dir/nonexistent-origin"
      else
        append_pr_meta_for_current_head "$case_dir"
        add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
      fi
    else
      mkdir -p "$case_dir/data/task-x1"
      printf 'Delivered investigation report.\n' > "$case_dir/data/task-x1/report.md"
    fi
    printf 'uncommitted scratch\n' > "$case_dir/wt/scratch.txt"
    words="$case_dir/words.txt"
    printf 'Discard the remaining scratch; keep the delivered result.\n' > "$words"
    rc=0
    run_teardown "$case_dir" --force --drop-file "$words" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "forced-dirty-$kind: authorized cleanup refused: $(cat "$case_dir/stderr")"
    cmp -s "$words" "$case_dir/data/task-x1/captain-drop.md" || fail "forced-dirty-$kind: exact captain words were lost"
    [ "$(backlog_row_state "$case_dir")" = "done" ] || fail "forced-dirty-$kind: backlog was not closed"
    if [ "$kind" = ship ]; then
      grep -Eq '^[[:space:]]+dropped$' "$case_dir/data/backlog.md" || fail "forced-dirty-$delivery: ship did not record the fixed drop note"
      assert_no_grep 'local main' "$case_dir/data/backlog.md" "forced-dirty-$delivery: ship retained a landing label instead of dropped"
      assert_no_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" "forced-dirty-$delivery: ship retained a landing label instead of dropped"
    else
      ! grep -Eq '^[[:space:]]+dropped$' "$case_dir/data/backlog.md" || fail "forced-dirty-scout: delivered report was mislabeled dropped"
      assert_grep 'task-x1/report.md' "$case_dir/data/backlog.md" "forced-dirty-scout: report completion was lost"
      assert_present "$case_dir/data/task-x1/report.md" "forced-dirty-scout: delivered report was removed"
    fi
  done
  pass "forced dirty ships record dropped and scouts retain delivered reports, with exact captain words retained for both"
}

test_scout_report_must_be_a_regular_nonempty_file() {
  local case_dir rc
  case_dir=$(make_case scout-report-file)
  write_meta "$case_dir" no-mistakes scout
  mkdir -p "$case_dir/data/task-x1/report.md"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "scout-report-file: a directory named report.md is not a report"
  rmdir "$case_dir/data/task-x1/report.md"
  : > "$case_dir/data/task-x1/report.md"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "scout-report-file: an empty report is not a report"
  grep -q "has no report" "$case_dir/stderr" || fail "scout-report-file: the refusal did not name the missing report"
  pass "a scout completes only with a regular non-empty report"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_task_archives_reap_only_carried_refs() {
  local case_dir base submitted replayed pipeline rc=0 name
  case_dir=$(make_case archive-carried)
  write_meta "$case_dir" no-mistakes ship
  base=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" 'feature file.txt' alpha "add feature"
  submitted=$(git -C "$case_dir/wt" rev-parse HEAD)
  replayed=$(printf 'replayed feature\n' | git -C "$case_dir/project" commit-tree \
    "$(git -C "$case_dir/wt" rev-parse "HEAD^{tree}")" -p "$base")
  wt_commit_file "$case_dir" later.txt beta "pipeline follow-up"
  pipeline=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" branch archive/task-x1-submitted-0a0a0a01 "$submitted"
  git -C "$case_dir/project" branch archive/task-x1-submitted-0a0a0a02 "$replayed"
  git -C "$case_dir/project" branch archive/task-x1-pipeline-0b0b0b01 "$pipeline"
  git -C "$case_dir/project" branch archive/other-pipeline-final "$pipeline"
  git -C "$case_dir/project" branch archive/task-x1 "$submitted"
  git -C "$case_dir/project" branch unrelated "$pipeline"
  land_archive_fixture_pr "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "carried archives: teardown failed: $(cat "$case_dir/stderr")"
  for name in submitted-0a0a0a01 submitted-0a0a0a02 pipeline-0b0b0b01; do
    assert_archive_ref "$case_dir" "archive/task-x1-$name" ""
    assert_grep "reaped archive/task-x1-$name" "$case_dir/stderr" "carried archive was not named"
  done
  assert_archive_ref "$case_dir" archive/other-pipeline-final "$pipeline"
  assert_archive_ref "$case_dir" archive/task-x1 "$submitted"
  assert_archive_ref "$case_dir" unrelated "$pipeline"
  pass "teardown reaps only this task's ancestor and patch-equivalent archives carried by the squash"
}

test_task_archives_ignore_other_tasks_and_non_custody_names() {
  local case_dir head rc=0 name
  case_dir=$(make_case archive-prefix)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt alpha "feature"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" branch archive/task-x1-pipeline-0b0b0b01 "$head"
  for name in task-x1-2-pipeline-0b0b0b02 task-x1-2-submitted-0a0a0a02 \
    task-x1-pipeline-final task-x1-pipeline-0B0B0B03 task-x1-pipeline-0b0b0b044 \
    task-x1-submitted-0a0a0a05-extra; do
    git -C "$case_dir/project" branch "archive/$name" "$head"
  done
  land_archive_fixture_pr "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "prefix archives: teardown failed: $(cat "$case_dir/stderr")"
  assert_archive_ref "$case_dir" archive/task-x1-pipeline-0b0b0b01 ""
  assert_grep 'reaped archive/task-x1-pipeline-0b0b0b01' "$case_dir/stderr" "own archive was not named"
  for name in task-x1-2-pipeline-0b0b0b02 task-x1-2-submitted-0a0a0a02 \
    task-x1-pipeline-final task-x1-pipeline-0B0B0B03 task-x1-pipeline-0b0b0b044 \
    task-x1-submitted-0a0a0a05-extra; do
    assert_archive_ref "$case_dir" "archive/$name" "$head"
    if grep -qF "archive/$name" "$case_dir/stderr"; then
      fail "archive/$name belongs to another task or is not a custody name but was named"
    fi
  done
  pass "teardown judges only the task's exact custody archive names, never another task's"
}

test_task_archives_keep_links_to_other_refs() {
  local case_dir base head rc=0 archives
  case_dir=$(make_case archive-links)
  write_meta "$case_dir" no-mistakes ship
  base=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" feature.txt alpha "feature"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" branch fm/other-symref "$base"
  git -C "$case_dir/project" branch fm/other-symlink "$base"
  git -C "$case_dir/project" branch archive/task-x1-submitted-0a0a0a01 "$head"
  git -C "$case_dir/project" symbolic-ref refs/heads/archive/task-x1-submitted-0a0a0a02 refs/heads/fm/other-symref
  archives="$case_dir/project/.git/refs/heads/archive"
  ln -s ../fm/other-symlink "$archives/task-x1-pipeline-0b0b0b01"
  land_archive_fixture_pr "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "linked archives: teardown failed: $(cat "$case_dir/stderr")"
  assert_archive_ref "$case_dir" archive/task-x1-submitted-0a0a0a01 ""
  assert_grep 'reaped archive/task-x1-submitted-0a0a0a01' "$case_dir/stderr" "ordinary archive was not reaped"
  assert_archive_ref "$case_dir" fm/other-symref "$base"
  assert_archive_ref "$case_dir" fm/other-symlink "$base"
  [ "$(git -C "$case_dir/project" symbolic-ref refs/heads/archive/task-x1-submitted-0a0a0a02)" = refs/heads/fm/other-symref ] \
    || fail "symbolic archive was not kept"
  [ -L "$archives/task-x1-pipeline-0b0b0b01" ] || fail "symlinked archive was not kept"
  assert_grep 'keeping archive/task-x1-submitted-0a0a0a02' "$case_dir/stderr" "symbolic archive was not named"
  assert_grep 'keeping archive/task-x1-pipeline-0b0b0b01' "$case_dir/stderr" "symlinked archive was not named"
  pass "archives that link to another ref stay named and never reap the linked branch"
}

test_task_archives_keep_unproven_and_checked_out_refs() {
  local case_dir landed extra merge edited rc=0 name
  case_dir=$(make_case archive-unproven)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt alpha "landed feature"
  landed=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" extra.txt unlanded "unlanded archive edit"
  extra=$(git -C "$case_dir/wt" rev-parse HEAD)
  # git cherry ignores merges: this archive has only a merge above the PR head,
  # but that merge's tree contains an edit absent from both its parents.
  merge=$(commit_tree_from_wt_head "$case_dir" "$landed" "empty second parent")
  edited=$(printf 'edited merge\n' | git -C "$case_dir/project" commit-tree \
    "$(git -C "$case_dir/wt" rev-parse "HEAD^{tree}")" -p "$landed" -p "$merge")
  git -C "$case_dir/project" branch archive/task-x1-submitted-0a0a0a03 "$extra"
  git -C "$case_dir/project" branch archive/task-x1-pipeline-0b0b0b02 "$edited"
  git -C "$case_dir/wt" reset -q --hard "$landed"
  git -C "$case_dir/project" branch archive/task-x1-pipeline-0b0b0b03 "$landed"
  git -C "$case_dir/project" worktree add -q "$case_dir/archive-held" archive/task-x1-pipeline-0b0b0b03
  git -C "$case_dir/project" branch archive/task-x1-pipeline-0b0b0b04 "$landed"
  land_archive_fixture_pr "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "unproven archives must not prevent landed task cleanup: $(cat "$case_dir/stderr")"
  assert_archive_ref "$case_dir" archive/task-x1-submitted-0a0a0a03 "$extra"
  assert_archive_ref "$case_dir" archive/task-x1-pipeline-0b0b0b02 "$edited"
  assert_archive_ref "$case_dir" archive/task-x1-pipeline-0b0b0b03 "$landed"
  assert_archive_ref "$case_dir" archive/task-x1-pipeline-0b0b0b04 ""
  for name in submitted-0a0a0a03 pipeline-0b0b0b02 pipeline-0b0b0b03; do
    assert_grep "keeping archive/task-x1-$name" "$case_dir/stderr" "retained archive was not named"
  done
  [ "$(git -C "$case_dir/archive-held" symbolic-ref HEAD)" = refs/heads/archive/task-x1-pipeline-0b0b0b03 ] \
    || fail "archive cleanup detached another copy"
  pass "unlanded edits, cherry-invisible merge edits, and checked-out archives stay named and intact"
}

test_task_archives_require_matching_squash_content() {
  local shape case_dir head merge rc
  for shape in different missing; do
    case_dir=$(make_case "archive-squash-$shape")
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" feature.txt alpha "feature"
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    git -C "$case_dir/project" branch archive/task-x1-pipeline-0b0b0b01 "$head"
    append_pr_meta_url "$case_dir"
    if [ "$shape" = different ]; then
      land_on_origin_main "$case_dir" feature.txt different
      git -C "$case_dir/project" fetch -q origin
      merge=$(git -C "$case_dir/project" rev-parse origin/main)
    else
      merge=
    fi
    add_gh_pr_merged_for_head "$case_dir" "$head" "$merge"
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "$shape squash: ordinary landing proof should still pass: $(cat "$case_dir/stderr")"
    assert_archive_ref "$case_dir" archive/task-x1-pipeline-0b0b0b01 "$head"
    assert_grep 'keeping archive/task-x1-pipeline-0b0b0b01' "$case_dir/stderr" "$shape squash: archive not named"
  done
  pass "even ancestor archives stay when squash content differs or the merge object is unproven"
}

test_task_archives_include_deleted_and_literal_paths_in_merge_proof() {
  local shape case_dir base head merge rc archive file=':(literal)renamed file.txt'
  for shape in matching restored-source; do
    case_dir=$(make_case "archive-deleted-$shape")
    write_meta "$case_dir" no-mistakes ship
    printf 'rename me\n' > "$case_dir/project/old.txt"
    git -C "$case_dir/project" add old.txt
    git -C "$case_dir/project" commit -qm "baseline file"
    git -C "$case_dir/project" push -q origin main
    base=$(git -C "$case_dir/project" rev-parse HEAD)
    git -C "$case_dir/wt" reset -q --hard "$base"
    git -C "$case_dir/wt" --literal-pathspecs mv -- old.txt "$file"
    git -C "$case_dir/wt" commit -qm rename
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    archive=archive/task-x1-pipeline-0b0b0b05
    git -C "$case_dir/project" branch "$archive" "$head"
    if [ "$shape" = matching ]; then
      land_archive_fixture_pr "$case_dir"
    else
      # The destination matches, but the squash did not carry the deletion.
      # Treat both PR and squash path sets as literal filenames, not pathspecs.
      printf 'rename me\n' > "$case_dir/project/$file"
      git -C "$case_dir/project" --literal-pathspecs add -- "$file"
      git -C "$case_dir/project" commit -qm "incomplete rename squash"
      merge=$(git -C "$case_dir/project" rev-parse HEAD)
      git -C "$case_dir/project" push -q origin main
      append_pr_meta_url "$case_dir"
      add_gh_pr_merged_for_head "$case_dir" "$head" "$merge"
    fi
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "$shape rename: task landing proof should pass: $(cat "$case_dir/stderr")"
    if [ "$shape" = matching ]; then
      assert_archive_ref "$case_dir" "$archive" ""
      assert_grep "reaped $archive" "$case_dir/stderr" "matching rename was not reaped"
    else
      assert_archive_ref "$case_dir" "$archive" "$head"
      assert_grep "keeping $archive" "$case_dir/stderr" "incomplete rename was not named"
    fi
  done
  pass "archive merge proof includes deleted paths and treats pathspec-like filenames literally"
}

test_task_archives_survive_refusal_and_forced_discard() {
  local case_dir head rc=0
  case_dir=$(make_case archive-refused)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt unlanded "unlanded feature"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" branch archive/task-x1-submitted-0a0a0a04 "$head"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "archive cleanup must not precede landing proof"
  assert_archive_ref "$case_dir" archive/task-x1-submitted-0a0a0a04 "$head"
  assert_refusal_retained_task_state "$case_dir" archive-refused "$head"
  rc=0
  run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" \
    > "$case_dir/forced.stdout" 2> "$case_dir/forced.stderr" || rc=$?
  expect_code 0 "$rc" "authorized discard failed: $(cat "$case_dir/forced.stderr")"
  assert_archive_ref "$case_dir" archive/task-x1-submitted-0a0a0a04 "$head"
  pass "landing refusal and forced discard never reap recovery archives"
}

test_task_archives_keep_refs_when_forge_is_unreachable() {
  local case_dir head rc=0
  case_dir=$(make_case archive-offline)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt alpha "feature"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" branch archive/task-x1-pipeline-0b0b0b01 "$head"
  land_on_origin_main "$case_dir" feature.txt alpha
  append_pr_meta_url "$case_dir"
  add_gh_axi_error "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "content landing fallback failed: $(cat "$case_dir/stderr")"
  assert_archive_ref "$case_dir" archive/task-x1-pipeline-0b0b0b01 "$head"
  assert_grep 'keeping archive/task-x1-pipeline-0b0b0b01' "$case_dir/stderr" "offline archive not named"
  pass "content-only landing with an unreachable forge keeps and names recovery archives"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  seed_backlog_in_flight "$case_dir"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "no-pr-branch-discovery: resolved PR URL was not recorded on completion"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

# A worker can run the suite from a task copy whose git directory is not
# reachable from where the copy is mounted: ROOT/.git then names a gitdir this
# environment cannot resolve, and any stdin-only git command inheriting the
# caller's directory fails. The landed-patch proof must depend only on the copy
# it reads, or it reports landed work as unproven.
test_landed_proof_ignores_unresolvable_git_directory_in_cwd() {
  local case_dir rc parent_head pr_head dangling
  case_dir=$(make_case landed-proof-dangling-cwd)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  dangling="$case_dir/unresolvable-git-cwd"
  mkdir "$dangling"
  printf 'gitdir: %s\n' "$case_dir/no-such-git-directory" > "$dangling/.git"
  ( cd "$dangling" && git rev-parse --show-toplevel >/dev/null 2>&1 ) \
    && fail "landed-proof-cwd: the fixture working directory still resolves a git worktree"

  rc=0
  ( cd "$dangling" && run_teardown "$case_dir" ) > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "landed-proof-cwd: teardown should succeed when the caller's working directory names an unresolvable git directory: $(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "landed-proof-cwd: teardown printed a REFUSED line"
  pass "the landed-patch proof ignores an unresolvable git directory in the caller's working directory"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_squash_merged_rebased_branch_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-rebased)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "squash-rebased: teardown should succeed when the worktree followed the pipeline rebase"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased: teardown printed a REFUSED line"
  pass "squash-merged task whose local branch followed the pipeline rebase is torn down"
}

# A Forgejo task whose default branch moved on after the squash merge, editing
# the same lines, leaves the content check inconclusive, so only the forge's
# merged record can prove the work landed. With the record merged teardown
# proceeds; with it unmerged the same history refuses.
test_squash_merged_forgejo_pr_allows_when_main_moved_on() {
  local case_dir rc pr_head tmp merged expected
  for merged in true false; do
    case_dir=$(make_case "forgejo-merged-$merged")
    write_meta "$case_dir" no-mistakes ship
    pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
    tmp="$case_dir/_main_later"
    git clone -q "$case_dir/origin.git" "$tmp"
    printf '%s\n' base main-edit feature-edit-reworded > "$tmp/shared.txt"
    git -C "$tmp" add -- shared.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main rewords shared"
    git -C "$tmp" push -q origin main
    rm -rf "$tmp"
    printf '%s\n' \
      'pr=https://git.example.org/team/repo/pulls/7' \
      "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
    add_gh_axi_error "$case_dir"
    add_tea_pull_for_head "$case_dir" "$merged" "$pr_head"

    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

    expected=1
    [ "$merged" = false ] || expected=0
    expect_code "$expected" "$rc" "forgejo-merged-$merged: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
    grep -qF -- 'api --login fj --repo team/repo /repos/{owner}/{repo}/pulls/7' "$case_dir/tea.log" \
      || fail "forgejo-merged-$merged: teardown did not read the Forgejo pull request through tea"
  done
  pass "teardown proves a Forgejo task landed from the merged pull request when the content check is inconclusive"
}

test_squash_merged_same_file_different_content_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-same-path-diverged)
  write_meta "$case_dir" no-mistakes ship
  # The pipeline rebase produced a different blob for shared.txt than the stale
  # local still holds, then squash-merged. Same path is not proof the local
  # content landed.
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "squash-same-path-diverged: teardown should refuse when the same file has different content"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-same-path-diverged: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-same-path-diverged "$local_head"
  pass "squash-merged same-path different content still refuses"
}

# The local branch followed the pipeline rebase, so without later.txt this is the
# q2 ALLOW case exactly. The one unlanded follow-up commit is the sole difference
# and must be the sole reason teardown refuses.
test_squash_merged_rebased_local_with_unlanded_commit_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-rebased-unlanded)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased-plus-unlanded)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "squash-rebased-unlanded: teardown should refuse extra local commits that never landed"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased-unlanded: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-rebased-unlanded "$local_head"
  pass "squash-merged rebased local still refuses a genuinely unlanded follow-up commit"
}

test_squash_merged_stale_local_refuses_when_forge_unreachable() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-stale-offline)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_axi_error "$case_dir"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "squash-stale-offline: teardown should refuse when the forge is down and trees conflict"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-stale-offline: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-stale-offline "$local_head"
  pass "squash-merged stale local still refuses when the forge is unreachable"
}

# The task copy stayed on the pre-rebase commits after the pipeline pushed a
# rebased copy as the PR head and the PR was squash-merged. Every commit's patch
# is in the PR head and the merge of main adds nothing of its own, so the copy
# is landed even though its commits sit on another remote.
test_squash_merged_pushed_prerebase_copy_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-pushed-prerebase)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_pushed_prerebase_history "$case_dir" landed)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "squash-pushed-prerebase: teardown should accept a pre-rebase copy whose every patch is in the merged PR head"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-pushed-prerebase: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a pushed pre-rebase copy whose patches are all in the PR head"
}

refusal_names_add_a() {
  grep -Eq '^[[:xdigit:]]+ add a$' "$1"
}

test_squash_pushed_missing_subject_match_ignores_hash_boundary() {
  local stderr="$TMP_ROOT/squash-pushed-missing-subject.stderr"
  printf '%s\n' 'c29cadd add b' > "$stderr"
  ! refusal_names_add_a "$stderr" || fail "squash-pushed-missing: commit ID plus add b was mistaken for an add a subject"
  printf '%s\n' 'abcdef0 add a' >> "$stderr"
  refusal_names_add_a "$stderr" || fail "squash-pushed-missing: a genuine add a subject was not detected"
  pass "squash-pushed-missing subject match ignores a commit ID ending in add and detects a genuine add a"
}

# One pre-rebase commit's change never reached the PR head, so the copy still
# holds work the merged PR lacks. The refusal must name that commit and keep
# every recovery route.
test_squash_merged_pushed_prerebase_copy_missing_commit_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-pushed-missing)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_pushed_prerebase_history "$case_dir" missing-commit)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "squash-pushed-missing: teardown should refuse when one pre-rebase commit's change is not in the PR head"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-pushed-missing: no REFUSED line in stderr"
  grep -q 'add b' "$case_dir/stderr" || fail "squash-pushed-missing: the refusal does not name the commit missing from the PR head"
  ! refusal_names_add_a "$case_dir/stderr" || fail "squash-pushed-missing: the refusal names a commit whose patch is in the PR head"
  assert_refusal_retained_task_state "$case_dir" squash-pushed-missing "$local_head"
  pass "squash-merged PR still refuses a pushed pre-rebase copy with a commit missing from the PR head"
}

# A merge of main carries nothing of its own only when it is exactly what git
# would produce. A merge commit with a hand-written change is unlanded work.
test_squash_merged_pushed_prerebase_copy_with_edited_merge_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-pushed-edited-merge)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_pushed_prerebase_history "$case_dir" edited-merge)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "squash-pushed-edited-merge: teardown should refuse a merge commit with its own change"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-pushed-edited-merge: no REFUSED line in stderr"
  grep -q 'hand-written change' "$case_dir/stderr" || fail "squash-pushed-edited-merge: the refusal does not name the edited merge"
  assert_refusal_retained_task_state "$case_dir" squash-pushed-edited-merge "$local_head"
  pass "squash-merged PR still refuses a merge commit that carries a change of its own"
}

# Main moved after the PR head was cut, and the copy merged that move in. The
# commit the merge brought is already in the default branch, so it is not the
# copy's own work and needs no proof in the PR head; judged without the default
# branch it would count as a commit the PR head lacks.
test_squash_merged_prerebase_copy_with_a_later_main_merge_allows() {
  local case_dir rc tmp pr_head
  case_dir=$(make_case squash-prerebase-later-main)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" a.txt alpha "add a"

  tmp="$case_dir/_pipeline"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q -b fm/task-x1
  printf '%s\n' alpha > "$tmp/a.txt"
  git -C "$tmp" add -- a.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add a"
  printf '%s\n' alpha review-edit > "$tmp/a.txt"
  git -C "$tmp" add -- a.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "review: edit a"
  pr_head=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/pull/7/head"

  git -C "$tmp" checkout -q main
  printf '%s\n' moved > "$tmp/m.txt"
  git -C "$tmp" add -- m.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main moves"
  git -C "$tmp" push -q origin main
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    merge -q --no-ff --no-edit origin/main

  git -C "$tmp" merge -q --squash fm/task-x1 >/dev/null
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "feat: squash (#7)"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "squash-prerebase-later-main: teardown should accept a pre-rebase copy that merged a main commit the PR head lacks"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-prerebase-later-main: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a pre-rebase copy that merged a later main commit the PR head lacks"
}

# PR 93 shape: the copy is an earlier iteration the pipeline rebuilt as different
# commits, so the PR head shares nothing with it.
test_pipeline_input_diverged_iteration_allows() {
  local case_dir pr_head
  pr_head=$(pipeline_input_case pipeline-input-diverged diverged-iteration)
  case_dir="$TMP_ROOT/pipeline-input-diverged"
  assert_pipeline_input_copy_allowed_by_record "$case_dir" pipeline-input-diverged "$pr_head"
  pass "merged PR accepts a diverged earlier iteration that the recorded run started from"
}

# PR 103 shape: the copy is the input the pipeline replayed onto a moved main,
# rewrote, and extended with its own review commits.
test_pipeline_input_rewritten_by_pipeline_allows() {
  local case_dir pr_head
  pr_head=$(pipeline_input_case pipeline-input-rewritten rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-rewritten"
  assert_pipeline_input_copy_allowed_by_record "$case_dir" pipeline-input-rewritten "$pr_head"
  pass "merged PR accepts the local input that the recorded run rewrote and extended"
}

# The run-record read is a query against a database a busy daemon may hold. It is
# stopped by silence, never by how long it takes: a read that burns CPU for longer
# than the ten seconds it used to be allowed is slow, not hung, and must prove the
# copy landed. A read that really is silent has proved nothing either way, so
# teardown neither refuses nor fires the unlanded-work guard: it says the answer is
# unknown and exits 75, the retry status the sweeps take without a refusal memo.
install_quiet_record_reader() {  # <case-dir> <burn|hang>
  local case_dir=$1 mode=$2 real_python
  # The interpreter itself, not a version-manager shim: a shim puts its own bin
  # first on PATH, so the reader that teardown starts would bypass this stand-in.
  real_python=$(python3 -c 'import sys; print(sys.executable)')
  printf '%s\n' "$mode" > "$case_dir/record-reader-mode"
  cat > "$case_dir/fakebin/python3" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -I ] && [ "\${2:-}" = - ] && [ -f "$case_dir/record-reader-mode" ]; then
  case "\$(cat "$case_dir/record-reader-mode")" in
    hang) exec sleep 60 ;;
    burn)
      rm -f "$case_dir/record-reader-mode"
      end=\$((SECONDS + 13))
      while [ "\$SECONDS" -lt "\$end" ]; do :; done ;;
  esac
fi
exec "$real_python" "\$@"
SH
  chmod +x "$case_dir/fakebin/python3"
}

test_pipeline_input_slow_record_read_still_proves_the_copy() {
  local case_dir pr_head local_head rc
  pr_head=$(pipeline_input_case pipeline-input-slow-read rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-slow-read"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  write_nm_run_record "$case_dir" 01RUNSLOW "https://github.com/example/repo/pull/7" "$local_head" "$pr_head"
  install_quiet_record_reader "$case_dir" burn

  rc=$(FM_TEARDOWN_NM_STALL_SECS=2 run_teardown_status "$case_dir")
  expect_code 0 "$rc" "pipeline-input-slow-read: a slow, working record read should still prove the copy"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "pipeline-input-slow-read: teardown printed a REFUSED line"
  pass "a slow but working run-record read still proves the copy was the pipeline's input"
}

test_pipeline_input_silent_record_read_is_unknown() {
  local case_dir pr_head local_head rc events
  pr_head=$(pipeline_input_case pipeline-input-silent-read rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-silent-read"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  events="$case_dir/guard-events.jsonl"
  # The record answers "not landed" once it is read: its run started from the merged
  # head, not from this copy.
  write_nm_run_record "$case_dir" 01RUNSILENT "https://github.com/example/repo/pull/7" "$pr_head" "$pr_head"
  install_quiet_record_reader "$case_dir" hang

  rc=$(FM_GUARD_EVENT_LOG="$events" FM_TEARDOWN_NM_STALL_SECS=2 run_teardown_status "$case_dir")
  expect_code 75 "$rc" "pipeline-input-silent-read: a silent record read should exit for a retry"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "unknown: the no-mistakes run record did not answer; retry teardown" "$case_dir/stderr" \
    "pipeline-input-silent-read: teardown did not say the record did not answer"
  ! grep -q REFUSED "$case_dir/stderr" || fail "pipeline-input-silent-read: a silent read was reported as a refusal"
  ! grep -q teardown-unlanded "$events" 2>/dev/null \
    || fail "pipeline-input-silent-read: a silent read fired the unlanded-work guard: $(cat "$events")"
  assert_refusal_retained_task_state "$case_dir" pipeline-input-silent-read "$local_head"

  rm -f "$case_dir/record-reader-mode"
  rc=$(FM_GUARD_EVENT_LOG="$events" FM_TEARDOWN_NM_STALL_SECS=2 run_teardown_status "$case_dir")
  expect_code 1 "$rc" "pipeline-input-silent-read: a record that answers 'not this copy' should still refuse"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "pipeline-input-silent-read: the answered read did not refuse"
  grep -q '"teardown-unlanded"' "$events" 2>/dev/null \
    || fail "pipeline-input-silent-read: the answered refusal did not fire the unlanded-work guard"
  assert_refusal_retained_task_state "$case_dir" pipeline-input-silent-read-answered "$local_head"
  pass "a silent run-record read is unknown and retried, while an answered one still refuses"
}

# SQLite's own busy wait is the one wait the record reader cannot watch: a writer
# that holds the database lock past it makes the read give up with "database is
# locked". That is a read that ran out of time, not an answer, so it is unknown
# and retried exactly like a silent read, never a refusal. The stand-in shortens
# only that busy wait so the case does not sit out the real 30 s.
test_pipeline_input_locked_record_read_is_unknown() {
  local case_dir pr_head local_head rc events real_python holder
  pr_head=$(pipeline_input_case pipeline-input-locked-read rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-locked-read"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  events="$case_dir/guard-events.jsonl"
  write_nm_run_record "$case_dir" 01RUNLOCKED "https://github.com/example/repo/pull/7" "$pr_head" "$pr_head"
  real_python=$(python3 -c 'import sys; print(sys.executable)')
  cat > "$case_dir/fakebin/python3" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -I ] && [ "\${2:-}" = - ]; then
  exec "$real_python" -I -c 'import sqlite3, sys
connect = sqlite3.connect
sqlite3.connect = lambda *args, **kwargs: connect(*args, **dict(kwargs, timeout=0.2))
exec(compile(sys.stdin.read(), "<stdin>", "exec"), {"__name__": "__main__"})' "\${@:3}"
fi
exec "$real_python" "\$@"
SH
  chmod +x "$case_dir/fakebin/python3"
  "$real_python" -I -c 'import sqlite3, sys, time
db = sqlite3.connect(sys.argv[1], isolation_level=None)
db.execute("BEGIN EXCLUSIVE")
open(sys.argv[2], "w").close()
time.sleep(120)' "$case_dir/nm/state.sqlite" "$case_dir/locked" &
  holder=$!
  fm_test_wait_until --while-alive "$holder" -- test -e "$case_dir/locked" || fail "pipeline-input-locked-read: the lock holder never took the lock"

  rc=$(FM_GUARD_EVENT_LOG="$events" FM_TEARDOWN_NM_STALL_SECS=60 run_teardown_status "$case_dir")
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 75 "$rc" "pipeline-input-locked-read: a lock-blocked record read should exit for a retry"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "unknown: the no-mistakes run record did not answer; retry teardown" "$case_dir/stderr" \
    "pipeline-input-locked-read: teardown did not say the record did not answer"
  ! grep -q REFUSED "$case_dir/stderr" || fail "pipeline-input-locked-read: a locked read was reported as a refusal"
  ! grep -q teardown-unlanded "$events" 2>/dev/null \
    || fail "pipeline-input-locked-read: a locked read fired the unlanded-work guard: $(cat "$events")"
  assert_refusal_retained_task_state "$case_dir" pipeline-input-locked-read "$local_head"
  pass "a run-record read that SQLite's busy wait gives up on is unknown and retried, not refused"
}

# A copy that lags the run's input head is not the input the run started from.
test_pipeline_input_refuses_copy_behind_the_input_head() {
  local case_dir pr_head input_head local_head
  pr_head=$(pipeline_input_case pipeline-input-behind rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-behind"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" extra.txt extra "input-only commit"
  input_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" reset -q --hard "$local_head"
  write_nm_run_record "$case_dir" 01RUNBEHIND "https://github.com/example/repo/pull/7" "$input_head" "$pr_head"

  assert_pipeline_input_refusal "$case_dir" pipeline-input-behind "$local_head" \
    "01RUNBEHIND" "is not that head"
  pass "merged PR still refuses a copy that is behind the recorded run's input head"
}

# A run that pushed the merged head is the only one that can prove anything, and
# an unrelated earlier run for the same PR must not stand in the way of it.
test_pipeline_input_ties_the_run_by_pushed_head_allows() {
  local case_dir pr_head local_head rc
  pr_head=$(pipeline_input_case pipeline-input-reruns rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-reruns"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  write_nm_run_record "$case_dir" 01RUNEARLY "https://github.com/example/repo/pull/7" "$pr_head" "$local_head"
  write_nm_run_record "$case_dir" 01RUNFINAL "https://github.com/example/repo/pull/7" "$local_head" "$pr_head"

  rc=$(run_teardown_status "$case_dir")
  expect_code 0 "$rc" "pipeline-input-reruns: teardown should accept the run that pushed the merged head"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "pipeline-input-reruns: teardown printed a REFUSED line"
  pass "merged PR is proven by the run that pushed its head, not by an earlier run on the same PR"
}

# A commit made after the run started is unlanded work whatever the record says.
test_pipeline_input_refuses_commit_made_after_the_run_started() {
  local case_dir pr_head input_head local_head
  pr_head=$(pipeline_input_case pipeline-input-late rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-late"
  input_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  write_nm_run_record "$case_dir" 01RUNLATE "https://github.com/example/repo/pull/7" "$input_head" "$pr_head"
  wt_commit_file "$case_dir" later.txt later "work after the run started"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  assert_pipeline_input_refusal "$case_dir" pipeline-input-late "$local_head" \
    "01RUNLATE" "is not that head"
  pass "merged PR still refuses a copy with a commit made after the recorded run started"
}

# A recorded run that did not start from this copy proves nothing about it.
test_pipeline_input_refuses_copy_outside_the_run_input() {
  local case_dir pr_head local_head
  pr_head=$(pipeline_input_case pipeline-input-outside rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-outside"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  write_nm_run_record "$case_dir" 01RUNOUTSIDE "https://github.com/example/repo/pull/7" "$pr_head" "$pr_head"

  assert_pipeline_input_refusal "$case_dir" pipeline-input-outside "$local_head" \
    "01RUNOUTSIDE" "started from"
  pass "merged PR still refuses a copy that is not part of the recorded run's input"
}

# A run recorded for another PR does not tie to the merged PR.
test_pipeline_input_refuses_run_recorded_for_another_pr() {
  local case_dir pr_head local_head
  pr_head=$(pipeline_input_case pipeline-input-other-pr rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-other-pr"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  write_nm_run_record "$case_dir" 01RUNOTHERPR "https://github.com/example/repo/pull/8" "$local_head" "$pr_head"

  assert_pipeline_input_refusal "$case_dir" pipeline-input-other-pr "$local_head" \
    "no no-mistakes run record names the merged PR https://github.com/example/repo/pull/7"
  pass "merged PR still refuses when the only recorded run belongs to another PR"
}

# A run for this PR that pushed some other head is not the run whose head merged.
test_pipeline_input_refuses_run_that_pushed_another_head() {
  local case_dir pr_head local_head
  pr_head=$(pipeline_input_case pipeline-input-other-head rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-other-head"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  write_nm_run_record "$case_dir" 01RUNOTHERHEAD "https://github.com/example/repo/pull/7" "$local_head" "$local_head"

  assert_pipeline_input_refusal "$case_dir" pipeline-input-other-head "$local_head" \
    "01RUNOTHERHEAD pushed" "not the merged PR head" "no recorded run pushed the merged PR head"
  pass "merged PR still refuses when no recorded run pushed the merged PR head"
}

# Every missing record is named so the next step is to find it, not to guess.
test_pipeline_input_refuses_when_the_state_database_is_missing() {
  local case_dir local_head
  pipeline_input_case pipeline-input-no-db rewritten-input >/dev/null
  case_dir="$TMP_ROOT/pipeline-input-no-db"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  assert_pipeline_input_refusal "$case_dir" pipeline-input-no-db "$local_head" \
    "no no-mistakes state database at $case_dir/nm/state.sqlite"
  pass "merged PR still refuses and names the state database when it is missing"
}

test_pipeline_input_refuses_when_the_input_head_is_not_recorded() {
  local case_dir pr_head local_head
  pr_head=$(pipeline_input_case pipeline-input-no-input rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-no-input"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  write_nm_run_record "$case_dir" 01RUNNOINPUT "https://github.com/example/repo/pull/7" "" "$pr_head"

  assert_pipeline_input_refusal "$case_dir" pipeline-input-no-input "$local_head" \
    "01RUNNOINPUT" "submitted_head_sha"
  pass "merged PR still refuses and names the input head when the run did not record it"
}

test_pipeline_input_refuses_when_the_pushed_head_is_not_recorded() {
  local case_dir local_head
  pipeline_input_case pipeline-input-no-pushed rewritten-input >/dev/null
  case_dir="$TMP_ROOT/pipeline-input-no-pushed"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  write_nm_run_record "$case_dir" 01RUNNOPUSH "https://github.com/example/repo/pull/7" "$local_head" ""

  assert_pipeline_input_refusal "$case_dir" pipeline-input-no-pushed "$local_head" \
    "01RUNNOPUSH" "last_pushed_sha"
  pass "merged PR still refuses and names the pushed head when the run did not record it"
}

test_pipeline_input_refuses_when_the_run_table_lacks_the_input_column() {
  local case_dir pr_head local_head
  pr_head=$(pipeline_input_case pipeline-input-no-column rewritten-input)
  case_dir="$TMP_ROOT/pipeline-input-no-column"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  write_nm_run_record "$case_dir" 01RUNNOCOL "https://github.com/example/repo/pull/7" "$local_head" "$pr_head" submitted_head_sha

  assert_pipeline_input_refusal "$case_dir" pipeline-input-no-column "$local_head" \
    "missing column(s) submitted_head_sha"
  pass "merged PR still refuses and names the column when the run table has no input head"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$case_dir/code-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$case_dir/code-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$case_dir/code-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FM_TEST_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  assert_present "$case_dir/treehouse.log" \
    "content-landed: teardown never reached destructive worktree cleanup"
  assert_absent "$case_dir/state/task-x1.meta" \
    "content-landed: teardown left task metadata after destructive cleanup"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

# bin/fm-pr-ready-reconcile.sh keeps one refusal marker per task; teardown must
# retire the torn-down task's marker and leave every other task's untouched.
test_teardown_removes_pr_ready_refusal_marker() {
  local case_dir rc cache
  case_dir=$(make_case pr-ready-refusal)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  cache="$case_dir/state/.pr-ready-reconcile"
  mkdir -p "$cache"
  printf 'registration refused\n' > "$cache/task-x1.refused"
  printf 'registration refused\n' > "$cache/task-other.refused"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "pr-ready-refusal: teardown should succeed"
  assert_absent "$case_dir/state/task-x1.meta" "pr-ready-refusal: teardown left task metadata"
  assert_absent "$cache/task-x1.refused" "pr-ready-refusal: teardown left the task's refusal marker"
  assert_present "$cache/task-other.refused" "pr-ready-refusal: teardown removed another task's refusal marker"
  pass "teardown removes the task's PR-ready refusal marker and no other task's"
}

# A task recording base_branch= landed when its content reached that branch, not
# the default branch: a squash merge into the base branch is the landing.
test_content_fallback_uses_recorded_base_branch() {
  local case_dir rc landed tmp
  for landed in base default; do
    case_dir=$(make_case "content-base-$landed")
    write_meta "$case_dir" direct-PR ship
    printf 'base_branch=feature/hub\n' >> "$case_dir/state/task-x1.meta"
    tmp="$case_dir/_hub"
    git clone -q "$case_dir/origin.git" "$tmp"
    git -C "$tmp" push -q origin HEAD:refs/heads/feature/hub
    rm -rf "$tmp"
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    if [ "$landed" = base ]; then
      tmp="$case_dir/_land"
      git clone -q "$case_dir/origin.git" "$tmp"
      git -C "$tmp" checkout -q feature/hub
      printf 'hello\n' > "$tmp/feature.txt"
      git -C "$tmp" add feature.txt
      git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash feature.txt"
      git -C "$tmp" push -q origin HEAD:feature/hub
      rm -rf "$tmp"
    else
      land_on_origin_main "$case_dir" feature.txt hello
    fi
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$case_dir/fakebin/treehouse"

    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$landed" = base ]; then
      expect_code 0 "$rc" "content-base: content squashed into the recorded base branch should count as landed"
      assert_absent "$case_dir/state/task-x1.meta" "content-base: teardown kept the record of landed work"
    else
      [ "$rc" -ne 0 ] || fail "content-base: content only on the default branch passed for a task based on feature/hub"
      assert_present "$case_dir/state/task-x1.meta" "content-base: a refused teardown removed the task record"
    fi
  done
  pass "the content-landed fallback checks a task's recorded base branch, not the default branch"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

test_untracked_only_refusal_diagnostic() {
  assert_dirty_diagnostic untracked no-mistakes
  assert_dirty_diagnostic untracked local-only
}

test_tracked_edit_refusal_diagnostic() {
  assert_dirty_diagnostic tracked no-mistakes
  assert_dirty_diagnostic tracked local-only
}

test_mixed_refusal_diagnostic() {
  assert_dirty_diagnostic mixed no-mistakes
  assert_dirty_diagnostic mixed local-only
}

test_scout_nested_clone_returns_with_no_untracked_entries() {
  local case_dir wt rc
  case_dir=$(make_case scout-nested-clean)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  seed_nested_clone_and_scratch "$case_dir" "$wt"
  add_treehouse_clean_fd "$case_dir"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "scout-nested-clean: teardown should return the scratch copy"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] \
    || fail "scout-nested-clean: untracked entries remain: $(git -C "$wt" status --porcelain --untracked-files=all)"
  assert_absent "$wt/scratch-clone" "scout-nested-clean: nested clone survived return"
  assert_absent "$wt/scratch.txt" "scout-nested-clean: scratch file survived return"
  pass "scout copy with a nested clone and a scratch file returns with no untracked entries"
}

test_ship_nested_clone_is_refused_and_bytes_stay() {
  local case_dir wt rc head before after
  case_dir=$(make_case ship-nested-refuse)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes ship
  seed_nested_clone_and_scratch "$case_dir" "$wt"
  before=$(cksum "$wt/scratch-clone/payload.txt")
  head=$(git -C "$wt" rev-parse HEAD)
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "ship-nested-refuse: teardown should refuse a nested clone"
  assert_grep "REFUSED" "$case_dir/stderr" "ship-nested-refuse: no REFUSED line"
  assert_grep "uncommitted changes" "$case_dir/stderr" \
    "ship-nested-refuse: refusal did not cite uncommitted changes"
  after=$(cksum "$wt/scratch-clone/payload.txt")
  [ "$before" = "$after" ] || fail "ship-nested-refuse: nested clone bytes changed"
  assert_present "$wt/scratch-clone/.git" "ship-nested-refuse: nested repository was removed"
  assert_present "$wt/scratch.txt" "ship-nested-refuse: scratch file was removed"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "ship-nested-refuse: refusal returned the copy: $(cat "$case_dir/treehouse.log")"
  assert_refusal_retained_task_state "$case_dir" "ship-nested-refuse" "$head"
  pass "ship copy with a nested clone is refused and its bytes stay"
}

test_dirty_return_warns_which_slot_was_lost() {
  local case_dir wt rc
  case_dir=$(make_case dirty-return)
  wt=$(move_case_to_pool_slot "$case_dir" 9)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_leaves_residue "$case_dir"

  rc=0
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "dirty-return: a lost slot should exit 4 after cleanup"
  assert_grep "pool slot 9" "$case_dir/stderr" "dirty-return: warning did not name the slot"
  assert_grep "left-behind-clone" "$case_dir/stderr" "dirty-return: warning did not name the remaining path"
  assert_grep "lost this slot" "$case_dir/stderr" "dirty-return: warning did not say the pool lost the slot"
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "dirty-return: stdout still reported a clean return"
  assert_grep "Backlog: task-x1" "$case_dir/stdout" \
    "dirty-return: the finished teardown skipped its backlog reminder"
  assert_absent "$case_dir/state/task-x1.meta" "dirty-return: task record was not removed"
  pass "a return that leaves residue names the lost slot and the remaining paths"
}

test_dirty_return_warns_even_when_a_later_step_refuses() {
  local case_dir wt rc
  case_dir=$(make_case dirty-return-later-refusal)
  wt=$(move_case_to_pool_slot "$case_dir" 8)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  # The pool return is teardown's final pool critical section: it runs only
  # after the endpoint is closed, so an endpoint-close refusal stops teardown
  # with the slot unreturned and nothing dirty yet. The first step that can
  # refuse after a completed return is the task-record removal, so the later
  # failure is injected there: the return plants the same residue as
  # add_treehouse_that_leaves_residue and then makes the state directory
  # unwritable so that removal refuses.
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then
  shift
  wt=
  for a in "\$@"; do
    case "\$a" in
      --force) ;;
      *) wt=\$a ;;
    esac
  done
  if [ -n "\$wt" ]; then
    git -C "\$wt" clean -fdq || true
    git init -q "\$wt/left-behind-clone"
    git -C "\$wt/left-behind-clone" commit -q --allow-empty -m residue
    chmod a-w "$case_dir/state"
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  chmod u+w "$case_dir/state"

  expect_code 1 "$rc" "dirty-return-later-refusal: the later record-removal refusal should fail teardown"
  assert_grep "pool slot 8" "$case_dir/stderr" \
    "dirty-return-later-refusal: a later refusal dropped the lost-slot warning"
  assert_grep "left-behind-clone" "$case_dir/stderr" \
    "dirty-return-later-refusal: a later refusal dropped the remaining paths"
  assert_present "$case_dir/state/task-x1.meta" \
    "dirty-return-later-refusal: the refused record removal still deleted the record"
  pass "a dirty return is reported even when a later teardown step refuses"
}

test_forced_secondmate_child_scout_nested_clone_returns_clean() {
  local case_dir home child_wt rc
  case_dir=$(make_case secondmate-child-nested-clean)
  write_meta "$case_dir" local-only secondmate
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  child_wt="$case_dir/child-scout-wt"
  git -C "$case_dir/project" worktree add -q -b fm/child-scout "$child_wt" main
  fm_write_meta "$home/state/child-scout.meta" \
    "window=firstmate:fm-child-scout" \
    "endpoint_task_id=child-scout" \
    "worktree=$child_wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=local-only"
  seed_nested_clone_and_scratch "$case_dir" "$child_wt"
  add_treehouse_clean_fd "$case_dir"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "secondmate-child-nested-clean: forced secondmate teardown should succeed"
  [ -z "$(git -C "$child_wt" status --porcelain --untracked-files=all)" ] \
    || fail "secondmate-child-nested-clean: untracked entries remain: $(git -C "$child_wt" status --porcelain --untracked-files=all)"
  assert_absent "$child_wt/scratch-clone" "secondmate-child-nested-clean: nested clone survived return"
  assert_absent "$child_wt/scratch.txt" "secondmate-child-nested-clean: scratch file survived return"
  assert_no_grep "lost this slot" "$case_dir/stderr" \
    "secondmate-child-nested-clean: a clean child return was reported as a lost slot"
  pass "a forced secondmate teardown returns a child scout copy with a nested clone clean"
}

# The remote host runs exactly this forced secondmate teardown for
# `fm-remote-secondmate-control.sh retire --force`; the local side finishes the
# route, record, and reply-source cleanup when it exits 0 or 4 (lost slot).
test_forced_secondmate_dirty_child_return_warns_and_completes() {
  local case_dir home child_wt rc
  case_dir=$(make_case secondmate-child-dirty-return)
  write_meta "$case_dir" local-only secondmate
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  child_wt="$case_dir/pool/6/repo"
  mkdir -p "$case_dir/pool/6"
  git -C "$case_dir/project" worktree add -q -b fm/child-scout "$child_wt" main
  printf '{"worktrees":[{"name":"6","path":"%s","leased":true,"lease_holder":"child-scout"}]}\n' "$child_wt" \
    > "$case_dir/pool/treehouse-state.json"
  fm_write_meta "$home/state/child-scout.meta" \
    "window=firstmate:fm-child-scout" \
    "endpoint_task_id=child-scout" \
    "worktree=$child_wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=local-only"
  add_treehouse_that_leaves_residue "$case_dir"

  rc=0
  mkdir -p "$case_dir/primary-home/state"
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "secondmate-child-dirty-return: a lost child slot should exit 4 after retirement: $(cat "$case_dir/stderr")"
  assert_grep "lost this slot" "$case_dir/stderr" \
    "secondmate-child-dirty-return: no lost-slot warning for the dirty child return"
  assert_grep "left-behind-clone" "$case_dir/stderr" \
    "secondmate-child-dirty-return: warning did not name the remaining path"
  assert_absent "$case_dir/state/task-x1.meta" "secondmate-child-dirty-return: task record was not removed"
  assert_absent "$home" "secondmate-child-dirty-return: secondmate home was not removed"
  pass "a forced secondmate teardown warns about a dirty child return and still completes"
}

test_return_that_removes_copy_warns_cannot_verify() {
  local case_dir wt rc
  case_dir=$(make_case return-removes-copy)
  wt=$(move_case_to_pool_slot "$case_dir" 7)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_removes_copy "$case_dir"

  rc=0
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "return-removes-copy: an unverified slot should exit 4 after cleanup"
  assert_grep "lost this slot" "$case_dir/stderr" "return-removes-copy: no lost-slot warning"
  assert_grep "cannot verify" "$case_dir/stderr" "return-removes-copy: warning did not say the slot is unverified"
  assert_grep "$wt" "$case_dir/stderr" "return-removes-copy: warning did not name the copy"
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "return-removes-copy: stdout still reported a clean return"
  assert_absent "$case_dir/state/task-x1.meta" "return-removes-copy: task record was not removed"
  pass "a return that leaves no readable copy reports the slot as unverified, not clean"
}

test_scout_ignored_files_survive_scratch_clean() {
  local case_dir wt rc
  case_dir=$(make_case scout-ignored-survives)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  printf '%s\n' 'ignored-cache/' > "$wt/.gitignore"
  git -C "$wt" add .gitignore
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m "ignore cache"
  mkdir -p "$wt/ignored-cache"
  printf 'keep-me\n' > "$wt/ignored-cache/blob"
  printf 'scratch\n' > "$wt/scratch.txt"
  add_treehouse_clean_fd "$case_dir"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "scout-ignored: teardown should succeed"
  [ "$(cat "$wt/ignored-cache/blob")" = "keep-me" ] \
    || fail "scout-ignored: ignored file was removed or changed"
  assert_absent "$wt/scratch.txt" "scout-ignored: scratch file survived"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] \
    || fail "scout-ignored: untracked entries remain: $(git -C "$wt" status --porcelain --untracked-files=all)"
  pass "ignored files survive the scratch clean and plain scratch does not"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

test_legacy_record_without_the_flag_refuses() {
  local case_dir rc
  case_dir=$(make_case legacy-noflag)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "legacy-noflag: a record without spawn_gen must refuse without --legacy-record"
  grep -q -- '--legacy-record' "$case_dir/stderr" \
    || fail "legacy-noflag: the refusal did not name the --legacy-record path"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-noflag: the refusal stamped a spawn generation into the record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-noflag: the refusal closed the backlog item anyway"
  assert_present "$case_dir/state/task-x1.meta" \
    "legacy-noflag: the refusal removed the task record"
  pass "a record predating spawn_gen refuses teardown until --legacy-record is passed"
}

test_windowless_legacy_record_with_gone_worktree_refuses() {
  local case_dir out rc
  case_dir=$(make_case windowless-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  rc=0
  out=$(run_teardown "$case_dir" 2>&1) || rc=$?
  expect_code 1 "$rc" "windowless-gone: missing copy without delivery proof must refuse"
  printf '%s\n' "$out" | grep -Fq 'completion requires a recorded GitHub PR confirmed merged' \
    || fail "windowless-gone: missing completion-proof refusal: $out"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "windowless-gone: refusal closed the backlog item"
  assert_present "$case_dir/state/task-x1.meta" \
    "windowless-gone: refusal removed the task record"
  pass "a windowless leftover with a missing worktree refuses without delivery proof"
}

test_windowless_legacy_record_with_gone_worktree_refuses_with_legacy_flag() {
  local case_dir out rc
  case_dir=$(make_case windowless-flag)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  rc=0
  out=$(run_teardown "$case_dir" --legacy-record 2>&1) || rc=$?
  expect_code 1 "$rc" "windowless-flag: --legacy-record must not waive completion proof"
  printf '%s\n' "$out" | grep -Fq 'completion requires a recorded GitHub PR confirmed merged' \
    || fail "windowless-flag: missing completion-proof refusal: $out"
  assert_present "$case_dir/state/task-x1.meta" \
    "windowless-flag: refusal removed the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "windowless-flag: refusal closed the backlog item"
  pass "--legacy-record does not waive a missing copy's delivery proof"
}

test_ship_without_git_copy_completes_with_recorded_merged_pr() {
  local case_dir copy mode out head
  for copy in absent non-git; do
    for mode in no-mistakes local-only; do
      case_dir=$(make_case "recorded-merged-$copy-$mode")
      [ "$copy" != non-git ] || mkdir "$case_dir/missing-wt"
      write_windowless_legacy_meta "$case_dir" "$mode" ship "$case_dir/missing-wt"
      append_pr_meta_url "$case_dir"
      seed_backlog_in_flight "$case_dir"
      head=$(git -C "$case_dir/wt" rev-parse HEAD)
      add_gh_pr_merged_for_head "$case_dir" "$head"

      out=$(run_teardown "$case_dir" 2>&1) \
        || fail "recorded-merged-$copy-$mode: merged recorded PR refused: $out"
      assert_absent "$case_dir/state/task-x1.meta" \
        "recorded-merged-$copy-$mode: successful completion retained metadata"
      [ "$(backlog_row_state "$case_dir")" = "done" ] \
        || fail "recorded-merged-$copy-$mode: successful completion kept backlog open"
      assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
        "recorded-merged-$copy-$mode: completion did not retain the PR"
      assert_no_grep 'local main' "$case_dir/data/backlog.md" \
        "recorded-merged-$copy-$mode: completion invented a local merge"
    done
  done
  pass "absent and non-Git ship copies complete only with their recorded merged PR"
}

test_ship_without_git_copy_refuses_unconfirmed_pr() {
  local case_dir copy proof out rc head state
  for copy in absent non-git; do
    for proof in open closed error unrecorded unsupported; do
      case_dir=$(make_case "unconfirmed-$copy-$proof")
      [ "$copy" != non-git ] || mkdir "$case_dir/missing-wt"
      write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
      seed_backlog_in_flight "$case_dir"
      head=$(git -C "$case_dir/wt" rev-parse HEAD)
      add_gh_pr_merged_for_head "$case_dir" "$head"
      case "$proof" in
        unrecorded) ;;
        unsupported)
          printf '%s\n' 'pr=https://example.invalid/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
          ;;
        *)
          append_pr_meta_url "$case_dir"
          if [ "$proof" = error ]; then
            add_gh_axi_error "$case_dir"
            printf '#!/usr/bin/env bash\nprintf "MERGED\\n"\nexit 1\n' > "$case_dir/fakebin/gh"
          else
            state=OPEN
            [ "$proof" != closed ] || state=CLOSED
            printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "$state" > "$case_dir/fakebin/gh"
          fi
          ;;
      esac

      rc=0
      out=$(run_teardown "$case_dir" 2>&1) || rc=$?
      expect_code 1 "$rc" "unconfirmed-$copy-$proof: absent delivery proof must refuse: $out"
      assert_present "$case_dir/state/task-x1.meta" \
        "unconfirmed-$copy-$proof: refusal removed metadata"
      [ "$(backlog_row_state "$case_dir")" = in_flight ] \
        || fail "unconfirmed-$copy-$proof: refusal closed the backlog"
    done
  done
  pass "ships without Git copies refuse open, closed, unreachable, unrecorded, and unsupported PR proof"
}

test_ship_without_git_copy_requires_captain_words_to_drop() {
  local case_dir copy out rc words
  for copy in absent non-git; do
    case_dir=$(make_case "missing-copy-drop-$copy")
    [ "$copy" != non-git ] || mkdir "$case_dir/missing-wt"
    write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
    seed_backlog_in_flight "$case_dir"
    rc=0
    out=$(run_teardown "$case_dir" --force 2>&1) || rc=$?
    expect_code 1 "$rc" "missing-copy-drop-$copy: force without words must refuse: $out"
    assert_present "$case_dir/state/task-x1.meta" \
      "missing-copy-drop-$copy: unauthorized force removed metadata"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] \
      || fail "missing-copy-drop-$copy: unauthorized force closed backlog"

    words="$case_dir/drop-words"
    printf '%s\n' "Discard this missing copy's unfinished work." > "$words"
    out=$(run_teardown "$case_dir" --force --drop-file "$words" 2>&1) \
      || fail "missing-copy-drop-$copy: authorized drop refused: $out"
    cmp -s "$words" "$case_dir/data/task-x1/captain-drop.md" \
      || fail "missing-copy-drop-$copy: captain words were not retained exactly"
    [ "$(backlog_row_state "$case_dir")" = "done" ] \
      || fail "missing-copy-drop-$copy: authorized drop kept backlog open"
    grep -Eq '^[[:space:]]+dropped$' "$case_dir/data/backlog.md" \
      || fail "missing-copy-drop-$copy: authorized drop lacked drop classification"
    assert_absent "$case_dir/state/task-x1.meta" \
      "missing-copy-drop-$copy: authorized drop retained metadata"
  done
  pass "ships without Git copies require retained captain words for forced drops"
}

test_windowless_legacy_record_still_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case windowless-unlanded)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt unique-windowless-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "windowless-unlanded: a still-present unlanded worktree must refuse"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "windowless-unlanded: no REFUSED line for unlanded windowless work"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "windowless-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "windowless-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "a windowless leftover still refuses while its worktree holds unlanded work"
}

test_windowless_record_outside_the_leftover_class_still_refuses() {
  local case_dir
  case_dir=$(make_case windowless-spawn-gen)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'spawn_gen=s1700000000.1.abc' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-spawn-gen "missing, empty, or ambiguous window endpoint"

  case_dir=$(make_case windowless-orca)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=orca' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-orca "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-no-backlog)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  assert_windowless_record_refuses "$case_dir" windowless-no-backlog "missing, empty, or ambiguous window endpoint"

  case_dir=$(make_case windowless-dup-project)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' "project=$case_dir/other-project" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-dup-project "no spawn_gen that identifies one exact incarnation"
  case_dir=$(make_case windowless-foreign-binding)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'endpoint_task_id=task-other' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-foreign-binding "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-terminal)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-terminal "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-herdr-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=tmux' 'herdr_session=s1' 'herdr_pane_id=p1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-herdr-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-cmux-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'cmux_surface_id=surface-1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-cmux-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-control-char)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing"$'\t'"wt"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-control-char "no spawn_gen that identifies one exact incarnation"
  pass "a windowless record with a spawn_gen, a non-tmux backend or endpoint identity, no backlog validation, or ambiguous, foreign, or malformed identity still refuses"
}

test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag() {
  local case_dir rc out
  case_dir=$(make_case windowless-retry)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  add_failing_truncate_perl "$case_dir"
  add_failing_close_publication_mv "$case_dir"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "windowless-retry: an unrecordable close must fail the first attempt"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "windowless-retry: the failed attempt did not leave its legacy stamp on the record"

  rm -f "$case_dir/fakebin/perl" "$case_dir/fakebin/mv"
  out=$(run_teardown "$case_dir") \
    || fail "windowless-retry: the flag-less retry refused the retained legacy stamp"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-retry: the retry did not accept the missing-endpoint leftover: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-retry: the retry left the leftover record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-retry: the retry returned success with its backlog item still open"
  pass "a windowless leftover retries its retained legacy stamp without --legacy-record"
}

test_legacy_record_teardown_completes_when_landed_and_endpoint_dead() {
  local case_dir out
  case_dir=$(make_case legacy-allow)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  # The default fakebin tmux answers every query with success and no output, so
  # the classifier reads the recorded window as authoritatively missing.

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "legacy-allow: teardown refused a landed legacy record with a dead endpoint"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "legacy-allow: teardown returned success with its backlog item still open"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing, incarnation legacy-' \
    || fail "legacy-allow: the teardown line did not log the accepted legacy incarnation: $out"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "legacy-allow: a landed legacy close left its pending-close record behind"
  assert_absent "$case_dir/state/task-x1.meta" \
    "legacy-allow: teardown left the task record behind"
  pass "a landed legacy record with a dead endpoint tears down and logs its accepted incarnation"
}

test_legacy_record_teardown_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case legacy-unlanded)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  # Real content committed but pushed nowhere and merged nowhere.
  wt_commit_file "$case_dir" feature.txt unique-legacy-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  rc=0
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "legacy-unlanded: --legacy-record must not relax the unlanded-work refusal"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "legacy-unlanded: no REFUSED line for unlanded legacy work"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-unlanded: the unlanded refusal stamped a spawn generation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "--legacy-record never relaxes the unlanded-work refusal"
}

test_legacy_record_teardown_refuses_an_ambiguous_endpoint() {
  local case_dir rc before
  case_dir=$(make_case legacy-ambiguous)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_unreadable_tmux "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  rc=0
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "legacy-ambiguous: an unreadable endpoint must refuse the legacy acceptance"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr" \
    || fail "legacy-ambiguous: the refusal did not name the endpoint state"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-ambiguous: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-ambiguous: the endpoint refusal closed the backlog item anyway"
  pass "an endpoint that cannot be confidently read as dead refuses --legacy-record teardown"
}

test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails() {
  local case_dir rc before
  case_dir=$(make_case legacy-stamp-rollback)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_failing_close_publication_mv "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  rc=0
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" \
    "legacy-stamp-rollback: an unrecordable close must fail the teardown after accepting the legacy record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the failed marker write left the record modified"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-rollback: the failed teardown closed the backlog item anyway"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 1 "$rc" \
    "legacy-stamp-rollback: the flag-less retry must not sail past the endpoint gate on the rolled-back record"
  grep -q -- '--legacy-record' "$case_dir/stderr2" \
    || fail "legacy-stamp-rollback: the retry refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the flag-less retry modified the record"
  pass "--legacy-record teardown rolls its stamp back when the close marker write fails"
}

test_retained_legacy_stamp_still_faces_the_endpoint_gate() {
  local case_dir rc stamped
  case_dir=$(make_case legacy-stamp-retained)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_failing_truncate_perl "$case_dir"
  add_failing_close_publication_mv "$case_dir"

  rc=0
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" \
    "legacy-stamp-retained: an unrecordable close must fail the teardown after accepting the legacy record"
  grep -q "could not be rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-retained: the fixture did not exercise a failed rollback"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the abandoned attempt did not leave its stamp on the record"
  stamped=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  # The stamp the failed rollback left behind is the whole risk: a retry must
  # not read it as an incarnation some spawn published and sail past the
  # dead-or-agent-less endpoint gate onto a reused endpoint.
  add_unreadable_tmux "$case_dir"
  rc=0
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 1 "$rc" \
    "legacy-stamp-retained: the retry must re-run the endpoint gate on the retained stamp"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr2" \
    || fail "legacy-stamp-retained: the retry skipped the dead-or-agent-less endpoint gate"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the retry stamped a second incarnation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-retained: the endpoint refusal closed the backlog item anyway"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout3" 2> "$case_dir/stderr3" || rc=$?
  expect_code 1 "$rc" \
    "legacy-stamp-retained: a flag-less retry must refuse the retained legacy stamp"
  grep -q -- '--legacy-record' "$case_dir/stderr3" \
    || fail "legacy-stamp-retained: the flag-less refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the flag-less refusal modified the task record"
  pass "a legacy stamp a failed rollback left behind still faces the endpoint gate"
}

test_legacy_record_never_accepts_a_corrupt_spawn_gen() {
  local case_dir rc
  case_dir=$(make_case legacy-corrupt)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf 'spawn_gen=one\nspawn_gen=two\n' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  rc=0
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "legacy-corrupt: an ambiguous spawn_gen must refuse even with --legacy-record"
  grep -q "unreadable spawn_gen" "$case_dir/stderr" \
    || fail "legacy-corrupt: the refusal did not name the unreadable spawn_gen"
  [ "$(legacy_meta_gen_count "$case_dir")" = 2 ] \
    || fail "legacy-corrupt: the refusal rewrote the corrupt record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-corrupt: the refusal closed the backlog item anyway"
  pass "a corrupt spawn_gen is never accepted as a legacy record"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  rc=0
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_idle_cwd_does_not_block_stale_index_lock_cleanup() {
  local case_dir rc lock idle
  case_dir=$(make_case idle-cwd-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_lock_aware_treehouse "$case_dir"
  add_lsof_real_lock_queries "$case_dir"
  lock=$(git_index_lock_path "$case_dir/wt")
  : > "$lock"
  touch -t 200001010000 "$lock"
  mkfifo "$case_dir/idle-input"
  exec 9<> "$case_dir/idle-input"
  (cd "$case_dir/wt" && exec bash -c 'read -r _ <&9') &
  idle=$!
  # Observe the real cwd owner rather than cap how long scheduling takes.
  fm_test_wait_until --while-alive "$idle" -- "$REAL_LSOF_FOR_TEST" -a -p "$idle" -d cwd -- "$case_dir/wt" \
    || fail "idle-index-lock: process did not enter worktree cwd"
  rc=0
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=30 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill "$idle"; wait "$idle" 2>/dev/null || true
  exec 9>&-
  expect_code 0 "$rc" "idle-index-lock: teardown should recover an abandoned lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "idle-index-lock: stale lock was not cleared"
  assert_absent "$lock" "idle-index-lock: abandoned lock remains"
  pass "an idle non-Git cwd holder does not block stale index.lock cleanup"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_real_lock_queries "$case_dir"
  fm_test_git_lock_start "$case_dir/wt" "$case_dir/git-owner" index
  lock=$FM_TEST_GIT_LOCK_PATH
  # The real git update-index process holds a real fd on this old lock.
  "$REAL_LSOF_FOR_TEST" -a -p "$FM_TEST_GIT_LOCK_PID" -- "$lock" >/dev/null \
    || fail "live-index-lock: Git did not retain its lock descriptor"

  rc=0
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  fm_test_git_lock_finish
  pass "real Git-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  rc=0
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "REFUSED: cannot determine leaked processes" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  rc=0
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  rc=0
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  # The mtime fault is injected by a fake stat on PATH; on Darwin the lock
  # helper now calls /usr/bin/stat directly, so the fake can never fire there.
  # Skip the Darwin run of this case.
  if [ "$(uname)" = Darwin ]; then
    pass "index-lock mtime fault injection is PATH-based; skipped on Darwin where stat is /usr/bin/stat"
    return
  fi
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  rc=0
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  rc=0
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

# The lock classifier used to write the whole failure text into `grep -q` through a
# pipe. grep -q stops at its first match, so a long text met a closed pipe, and a
# parent that ignores SIGPIPE made bash print "write error: Broken pipe" into the
# teardown's stderr. A stub grep that exits at once and a text far larger than a pipe
# buffer make that deterministic; the retry must still end in success.
test_index_lock_classifier_never_breaks_a_pipe_on_a_long_failure_text() {
  local case_dir rc lock attempt_file real_grep
  real_grep=$(command -v grep)
  case_dir=$(make_case lock-classifier-pipe)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  cat > "$case_dir/fakebin/grep" <<EOF
#!/usr/bin/env bash
case " \$* " in *'index'*'lock'*) exit 0 ;; esac
exec "$real_grep" "\$@"
EOF
  chmod +x "$case_dir/fakebin/grep"
  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"
  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"
  rc=0
  ( trap '' PIPE
    TREEHOUSE_ATTEMPT_FILE="$attempt_file" TREEHOUSE_LOCK_PAD_LINES=40000 \
    FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
    FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" ) || rc=$?
  expect_code 0 "$rc" "lock-classifier-pipe: teardown should succeed on retry"
  assert_no_grep "write error" "$case_dir/stderr" "lock-classifier-pipe: the classifier wrote into a pipe its reader had closed"
  assert_no_grep "Broken pipe" "$case_dir/stderr" "lock-classifier-pipe: the classifier broke its pipe"
  pass "the index.lock classifier reads a long failure text without a pipe, so an early-exiting grep cannot break it"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  rc=0
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  rc=0
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  rc=0
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

# Bundle fixtures use only this suite's temporary repositories and data.
# The command sequence here is the supported recipe in fm-teardown.sh's header.
record_preservation_bundle() {  # <case> <copy> <bundle> [revision...]
  local case_dir=$1 copy=$2 bundle=$3 digest tips
  shift 3
  mkdir -p "${bundle%/*}" "$case_dir/data/task-x1"
  git -C "$copy" bundle create "$bundle" "$@" 2>/dev/null || return 1
  git -C "$copy" bundle verify "$bundle" >/dev/null 2>&1 || return 1
  digest=$(shasum -a 256 "$bundle" | awk '{print $1}')
  tips=$(git bundle list-heads "$bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
  printf '%s\t%s\t%s\n' "$bundle" "$digest" "$tips" > "$case_dir/data/task-x1/preservation-bundles.tsv"
  hold_bundle_call "$case_dir"
}

run_captain_hold() {  # <case> <arg>...
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# The recipe's last step: the captain's land-or-drop call, held on <task-id>
# (task-x1 by default, seeded In flight when the case has no backlog yet), with
# a reason naming the recorded bundle and every recorded tip.
hold_bundle_call() {  # <case> [<task-id> <title>]
  local case_dir=$1 id=${2:-task-x1} record bundle tips
  local -a title=()
  [ -z "${3:-}" ] || title=(--title "$3")
  record="$case_dir/data/task-x1/preservation-bundles.tsv"
  bundle=$(cut -f1 "$record")
  tips=$(cut -f3 "$record")
  [ -f "$case_dir/data/backlog.md" ] || seed_backlog_in_flight "$case_dir"
  run_captain_hold "$case_dir" hold "$id" --owner captain ${title[@]+"${title[@]}"} \
    --reason "Land or drop the unlanded commits of task-x1: preserved in bundle $bundle, recorded tips $tips." >/dev/null
}

# The held backlog with every hold reason decoded, for assertions on what the
# captain is asked.
decoded_backlog() {  # <case>
  ( . "$ROOT/bin/fm-hold-reason-lib.sh"; fm_hold_reason_decode_stream markdown ) < "$1/data/backlog.md"
}

make_bundle_copy_case() {  # <name> [mode]
  make_nested_slot_case "$1" enclosing .claude/worktrees/bundled "${2:-no-mistakes}"
  printf 'recoverable work\n' > "$NESTED_COPY/work.txt"
  git -C "$NESTED_COPY" add work.txt
  git -C "$NESTED_COPY" commit -qm 'unpublished work'
  BUNDLE_PATH="$NESTED_CASE/bundles/work.bundle"
  record_preservation_bundle "$NESTED_CASE" "$NESTED_COPY" "$BUNDLE_PATH" --all || fail 'cannot create bundle fixture'
}

# A nested task copy is not its enclosing task's reserved pool slot.
# Empty slot fields also occur on retries whose earlier cleanup wrote a marker.
test_empty_recorded_slot_nested_drop() {
  local case_dir slot copy head slot_head bundle rc
  make_bundle_copy_case empty-recorded-slot-nested-drop
  case_dir=$NESTED_CASE
  slot=$NESTED_SLOT
  copy=$NESTED_COPY
  head=$(git -C "$copy" rev-parse HEAD)
  slot_head=$(git -C "$slot" rev-parse HEAD)
  bundle=$BUNDLE_PATH
  write_meta "$case_dir" no-mistakes ship "$copy"
  printf 'slot=\n' >> "$case_dir/state/task-x1.meta"
  printf 'spawn_gen=teardown-test-task-x1\nslot=\n' > "$case_dir/state/task-x1.teardown-return-pending"
  printf 'task=other\nhome=%s\n' "$case_dir/home" > "${slot%/*}/.fm-slot-owner"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"other"}]}\n' "$slot" \
    > "$case_dir/pool/treehouse-state.json"
  fm_write_meta "$case_dir/state/other.meta" "worktree=$slot" 'kind=ship'
  cp "$case_dir/state/other.meta" "$case_dir/other.before"
  cp "$case_dir/state/task-x1.meta" "$case_dir/task.before"
  cp "$case_dir/state/task-x1.teardown-return-pending" "$case_dir/pending.before"
  cp "${slot%/*}/.fm-slot-owner" "$case_dir/owner.before"
  cp "$case_dir/pool/treehouse-state.json" "$case_dir/lease.before"
  printf 'other task bytes\n' > "$slot/other.txt"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in pool-dir|status) exit 0 ;; esac
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
[ "\$*" = 'return --force $copy' ] || exit 1
exec git -C '$case_dir/project' worktree remove --force '$copy'
SH
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" --force > "$case_dir/no-drop.stdout" 2> "$case_dir/no-drop.stderr" || rc=$?
  expect_code 1 "$rc" 'empty recorded slot must not waive owner drop-file authorization'
  assert_grep 'requires --drop-file' "$case_dir/no-drop.stderr" 'missing owner authorization did not refuse'
  assert_no_grep 'REFUSED: reserved pool slot  lost its durable lease; retaining the task record and contents' \
    "$case_dir/no-drop.stderr" 'unauthorized empty-slot copy reached reserved-slot return'
  cmp -s "$case_dir/task.before" "$case_dir/state/task-x1.meta" || fail 'unauthorized drop changed task metadata'
  cmp -s "$case_dir/pending.before" "$case_dir/state/task-x1.teardown-return-pending" || fail 'unauthorized drop changed pending metadata'
  assert_present "$copy/.git" 'unauthorized drop removed the nested copy'
  assert_absent "$case_dir/treehouse.log" 'unauthorized drop reached the provider'

  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "empty recorded slot authorized nested drop refused: $(cat "$case_dir/stderr")"
  assert_no_grep 'REFUSED: reserved pool slot  lost its durable lease; retaining the task record and contents' \
    "$case_dir/stderr" 'empty slot entered reserved-slot return'
  assert_absent "$copy" 'authorized drop retained the nested copy'
  assert_absent "$case_dir/state/task-x1.meta" 'authorized drop retained task metadata'
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" 'authorized drop retained pending metadata'
  cmp -s "$case_dir/other.before" "$case_dir/state/other.meta" || fail 'nested drop changed the enclosing owner record'
  cmp -s "$case_dir/owner.before" "${slot%/*}/.fm-slot-owner" || fail 'nested drop changed the enclosing claim'
  cmp -s "$case_dir/lease.before" "$case_dir/pool/treehouse-state.json" || fail 'nested drop changed the enclosing lease'
  assert_equals 'other task bytes' "$(cat "$slot/other.txt")" 'nested drop removed enclosing task bytes'
  assert_equals "$slot_head" "$(git -C "$slot" rev-parse HEAD)" 'nested drop changed enclosing task HEAD'
  if [ -s "$case_dir/treehouse.log" ]; then
    assert_equals "return --force $copy" "$(cat "$case_dir/treehouse.log")" 'nested drop administered the enclosing slot'
  fi
  cmp -s "$FM_TEST_DROP_WORDS" "$case_dir/data/task-x1/captain-drop.md" || fail 'owner drop words were not retained'
  git init -q --bare "$case_dir/restored.git"
  git -C "$case_dir/restored.git" fetch -q "$bundle" 'refs/heads/*:refs/heads/*' || fail 'verified bundle cannot restore commits'
  assert_equals 'recoverable work' "$(git -C "$case_dir/restored.git" show "$head:work.txt")" 'bundle lost the removed commit contents'
  pass 'empty recorded slot drops only the owner-authorized nested copy and preserves its bundled commits and enclosing owner'
}

test_recorded_slot_lost_lease_still_refuses() {
  local case_dir slot rc=0
  make_nested_slot_case recorded-slot-lost-lease enclosing .claude/worktrees/x
  case_dir=$NESTED_CASE
  slot=$NESTED_SLOT
  printf 'slot=%s\n' "$slot" >> "$case_dir/state/task-x1.meta"
  printf 'spawn_gen=teardown-test-task-x1\nslot=%s\n' "$slot" > "$case_dir/state/task-x1.teardown-return-pending"
  cp "$case_dir/state/task-x1.meta" "$case_dir/task.before"
  cp "${slot%/*}/.fm-slot-owner" "$case_dir/owner.before"
  # Lose a real lease after reservation but before the final return check.
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = kill-window ]; then
  printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' '$slot' > '$case_dir/pool/treehouse-state.json'
fi
exit 0
SH
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'a real reserved slot that loses its lease must refuse'
  assert_grep "REFUSED: reserved pool slot $slot lost its durable lease; retaining the task record and contents" \
    "$case_dir/stderr" 'lost-lease refusal did not name the real slot'
  cmp -s "$case_dir/task.before" "$case_dir/state/task-x1.meta" || fail 'lost-lease refusal removed task metadata'
  cmp -s "$case_dir/owner.before" "${slot%/*}/.fm-slot-owner" || fail 'lost-lease refusal changed the claim'
  assert_present "$NESTED_COPY/.git" 'lost-lease refusal removed the nested copy'
  assert_present "$slot/.git" 'lost-lease refusal removed the real slot'
  assert_grep "slot=$slot" "$case_dir/state/task-x1.teardown-return-pending" 'lost-lease refusal lost its pending return'
  assert_absent "$case_dir/treehouse.log" 'lost-lease refusal returned the slot'
  pass 'a real recorded slot whose reserved lease is lost still refuses with its slot named'
}

# Same landed recorded-slot fixture as the lost-lease case, without the fault.
# Provider state records the observable release; it never touches a live pool.
test_recorded_slot_intact_lease_completes() {
  local case_dir slot rc=0
  make_nested_slot_case recorded-slot-intact-lease enclosing .claude/worktrees/x
  case_dir=$NESTED_CASE
  slot=$NESTED_SLOT
  printf 'slot=%s\n' "$slot" >> "$case_dir/state/task-x1.meta"
  printf 'spawn_gen=teardown-test-task-x1\nslot=%s\n' "$slot" > "$case_dir/state/task-x1.teardown-return-pending"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in pool-dir|status) exit 0 ;; esac
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
[ "\$*" = 'return --force $slot' ] || exit 1
printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' '$slot' > '$case_dir/pool/treehouse-state.json'
SH
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "a real reserved slot with its lease intact must complete: $(cat "$case_dir/stderr")"
  assert_no_grep 'REFUSED:' "$case_dir/stderr" 'intact-lease completion printed a refusal'
  assert_equals "return --force $slot" "$(cat "$case_dir/treehouse.log")" 'intact lease did not return exactly the owned slot'
  assert_absent "$NESTED_COPY" 'intact-lease completion retained the nested copy'
  assert_absent "$case_dir/state/task-x1.meta" 'intact-lease completion retained task metadata'
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" 'intact-lease completion retained pending metadata'
  assert_absent "${slot%/*}/.fm-slot-owner" 'intact-lease completion retained the task claim'
  assert_present "$slot/.git" 'intact-lease completion removed the reusable pool slot'
  assert_equals false "$(jq -r '.worktrees[0].leased' "$case_dir/pool/treehouse-state.json")" 'intact-lease completion retained the lease'
  pass 'a real recorded slot with an intact lease completes and releases only its owned slot'
}

test_verified_bundle_preserves_unlanded_copy() {
  local case_dir rc head digest mode second restored stored
  for mode in single multiple; do
    make_bundle_copy_case "bundle-$mode"
    case_dir=$NESTED_CASE
    head=$(git -C "$NESTED_COPY" rev-parse HEAD)
    second=
    if [ "$mode" = multiple ]; then
      second=$(git -C "$NESTED_COPY" commit-tree 'HEAD^{tree}' -p origin/main -m 'independent unpublished tip')
      git -C "$NESTED_SLOT" reset --hard -q "$second"
      record_preservation_bundle "$case_dir" "$NESTED_COPY" "$BUNDLE_PATH" --all || fail 'cannot bundle both tips'
    fi
    digest=$(shasum -a 256 "$BUNDLE_PATH" | awk '{print $1}')
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "bundle-$mode: verified preservation must allow ordinary teardown: $(cat "$case_dir/stderr")"
    assert_absent "$NESTED_COPY" "bundle-$mode: preserved copy was not removed"
    assert_absent "$case_dir/state/task-x1.meta" "bundle-$mode: task was not retired"
    assert_grep "$BUNDLE_PATH" "$case_dir/stderr" 'bundle path not reported'
    assert_grep "$digest" "$case_dir/stderr" 'bundle digest not reported'
    assert_grep "$head" "$case_dir/stderr" 'preserved tip not reported'
    [ -z "$second" ] || assert_grep "$second" "$case_dir/stderr" 'second preserved tip not reported'
    restored="$case_dir/restored.git"
    git init -q --bare "$restored"
    stored="$case_dir/data/task-x1/preserved-bundles/$(cut -f2 "$case_dir/data/task-x1/preservation-bundles.tsv").bundle"
    assert_grep "$stored" "$case_dir/stderr" 'stored recovery path not reported'
    assert_equals "$digest" "$(shasum -a 256 "$stored" | awk '{print $1}')" 'stored bundle digest changed'
    rm "$BUNDLE_PATH"
    git -C "$restored" bundle unbundle "$stored" >/dev/null || fail 'stored bundle cannot restore commits after source deletion'
    assert_equals 'recoverable work' "$(git -C "$restored" show "$head:work.txt")" 'preserved work cannot be recovered'
    [ -z "$second" ] || git -C "$restored" cat-file -e "$second^{commit}" || fail 'second tip cannot be recovered'
  done
  pass 'ordinary teardown removes a copy with one or two unpublished tips preserved in a verified recorded bundle'
}

test_invalid_preservation_bundle_refuses() {
  local shape case_dir rc reason refusal record second digest first size stock_bash_path
  for shape in missing-tip missing-slot-tip recorded-tip verify thin truncated hash no-record symlink malformed two-lines empty-field blank-tips; do
    stock_bash_path=
    refusal='REFUSED: the ship deliverable is not landed'
    make_bundle_copy_case "bundle-invalid-$shape"
    case_dir=$NESTED_CASE
    record="$case_dir/data/task-x1/preservation-bundles.tsv"
    case "$shape" in
      missing-tip)
        git -C "$NESTED_COPY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'missing unpublished tip'
        second=$(git -C "$NESTED_COPY" rev-parse HEAD)
        reason="bundle does not list unlanded tip $second"
        ;;
      missing-slot-tip)
        second=$(git -C "$NESTED_COPY" commit-tree 'HEAD^{tree}' -p origin/main -m 'missing unpublished slot tip')
        git -C "$NESTED_SLOT" reset --hard -q "$second"
        reason="bundle does not list unlanded tip $second"
        refusal="REFUSED: returning pool slot $NESTED_SLOT would sweep away task task-x1's claimed pool slot $NESTED_SLOT, whose HEAD $second is neither landed nor held by a refs/fm/anchor/task-x1-<sha> preservation anchor"
        ;;
      recorded-tip)
        digest=$(shasum -a 256 "$BUNDLE_PATH" | awk '{print $1}')
        printf '%s\t%s\t%s\n' "$BUNDLE_PATH" "$digest" "$(git -C "$NESTED_COPY" rev-parse origin/main)" > "$record"
        reason='record does not list unlanded tip'
        ;;
      verify)
        printf 'not a bundle\n' > "$BUNDLE_PATH"
        digest=$(shasum -a 256 "$BUNDLE_PATH" | awk '{print $1}')
        printf '%s\t%s\t%s\n' "$BUNDLE_PATH" "$digest" "$(git -C "$NESTED_COPY" rev-parse HEAD)" > "$record"
        reason='git bundle verify failed'
        ;;
      thin)
        first=$(git -C "$NESTED_COPY" rev-parse HEAD)
        printf 'later work\n' > "$NESTED_COPY/later.txt"
        git -C "$NESTED_COPY" add later.txt
        git -C "$NESTED_COPY" -c user.email=t@t -c user.name=t commit -qm 'later unpublished work'
        record_preservation_bundle "$case_dir" "$NESTED_COPY" "$BUNDLE_PATH.thin" "$first..fm/task-x1-v2" \
          || fail 'cannot create thin bundle fixture'
        git -C "$NESTED_COPY" bundle verify "$BUNDLE_PATH.thin" >/dev/null 2>&1 \
          || fail 'thin bundle fixture must pass verify inside its own copy'
        reason='bundle cannot be restored in an isolated repository'
        ;;
      truncated)
        size=$(wc -c < "$BUNDLE_PATH")
        head -c $((size - 16)) "$BUNDLE_PATH" > "$BUNDLE_PATH.cut"
        mv "$BUNDLE_PATH.cut" "$BUNDLE_PATH"
        digest=$(shasum -a 256 "$BUNDLE_PATH" | awk '{print $1}')
        printf '%s\t%s\t%s\n' "$BUNDLE_PATH" "$digest" "$(git bundle list-heads "$BUNDLE_PATH" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)" > "$record"
        reason='bundle cannot be restored in an isolated repository'
        ;;
      hash)
        printf 'changed\n' >> "$BUNDLE_PATH"
        reason='sha256 does not match record'
        ;;
      no-record)
        rm "$record"
        reason='missing preservation record'
        ;;
      empty-field)
        printf '%s\t\t%s\n' "$BUNDLE_PATH" "$(git -C "$NESTED_COPY" rev-parse HEAD)" > "$record"
        reason='malformed preservation record in'
        ;;
      blank-tips)
        printf '%s\t%s\t \n' "$BUNDLE_PATH" "$(shasum -a 256 "$BUNDLE_PATH" | awk '{print $1}')" > "$record"
        reason='(no commit tips)'
        stock_bash_path="/bin:$PATH"
        ;;
      symlink)
        ln -s "$BUNDLE_PATH" "$case_dir/bundle-link"
        digest=$(shasum -a 256 "$BUNDLE_PATH" | awk '{print $1}')
        printf '%s\t%s\t%s\n' "$case_dir/bundle-link" "$digest" "$(git -C "$NESTED_COPY" rev-parse HEAD)" > "$record"
        reason='bundle is not a regular nonsymlink file'
        ;;
      malformed)
        printf 'missing fields\n' >> "$record"
        reason='exactly one line required'
        ;;
      two-lines)
        cp "$record" "$record.copy"
        cat "$record.copy" >> "$record"
        rm "$record.copy"
        reason='exactly one line required'
        ;;
    esac
    rc=0
    FM_HOME="$case_dir/home" FM_TEARDOWN_TEST_PATH="${stock_bash_path:-$PATH}" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "bundle-$shape: invalid preservation must refuse"
    assert_grep "$refusal" "$case_dir/stderr" "bundle-$shape: original refusal changed: $(cat "$case_dir/stderr")"
    assert_grep "$reason" "$case_dir/stderr" "bundle-$shape: missing predicate not named"
    assert_grep 'Create a self-contained external bundle' "$case_dir/stderr" "bundle-$shape: supported completing step missing"
    assert_present "$NESTED_COPY/.git" "bundle-$shape: copy was removed"
    assert_present "$case_dir/state/task-x1.meta" "bundle-$shape: task record was removed"
    assert_absent "$case_dir/treehouse.log" "bundle-$shape: pool slot was returned"
  done
  pass 'incomplete, unverifiable, changed, unrecorded, unsafe-path and malformed bundle records retain the original refusal'
}

# Source placement is irrelevant after admission; stored bytes must survive.
test_bundle_storage_inside_removal_root_refuses() {
  local shape case_dir rc target
  for shape in copy slot scratch state-cache; do
    make_bundle_copy_case "bundle-storage-$shape"
    case_dir=$NESTED_CASE
    case "$shape" in
      copy) target="$NESTED_COPY/.claude/preserved" ;;
      slot) target="$NESTED_SLOT/.claude/preserved" ;;
      scratch)
        target="$case_dir/tasktmp"
        printf 'tasktmp=%s\n' "$target" >> "$case_dir/state/task-x1.meta"
        ;;
      state-cache) target="$case_dir/state/.nm-read-cache-task-x1" ;;
    esac
    mkdir -p "$target"
    ln -s "$target" "$case_dir/data/task-x1/preserved-bundles"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "bundle-storage-$shape: stored bytes would be removed"
    assert_grep 'bundle is inside task' "$case_dir/stderr" 'stored removal root not named'
    assert_present "$NESTED_COPY/.git" 'unsafe storage removed the copy'
    assert_present "$BUNDLE_PATH" 'unsafe storage removed the source'
    assert_present "$case_dir/state/task-x1.meta" 'unsafe storage removed task record'
    assert_absent "$case_dir/treehouse.log" 'unsafe storage returned slot'
  done
  pass 'stored bundles refuse aliases into only the actual cleanup removal roots'
}

test_bundle_storage_failure_keeps_copy() {
  local shape case_dir rc
  for shape in copy-error changed-bytes; do
    make_bundle_copy_case "bundle-store-$shape"
    case_dir=$NESTED_CASE
    cat > "$case_dir/fakebin/cp" <<SH
#!/usr/bin/env bash
case "\${2:-}" in
  */preserved-bundles/.bundle.*)
    [ '$shape' != copy-error ] || exit 1
    /bin/cp "\$@" || exit 1
    printf 'damaged stored bytes\\n' >> "\$2"
    exit 0 ;;
esac
exec /bin/cp "\$@"
SH
    chmod +x "$case_dir/fakebin/cp"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "bundle-store-$shape: failed storage must refuse"
    assert_present "$NESTED_COPY/.git" 'storage failure removed the copy'
    assert_equals 'recoverable work' "$(cat "$NESTED_COPY/work.txt")" 'storage failure lost bytes'
    assert_present "$case_dir/state/task-x1.meta" 'storage failure removed task record'
    assert_absent "$case_dir/treehouse.log" 'storage failure returned slot'
    case "$shape" in
      copy-error) assert_grep 'bundle cannot be copied into task data' "$case_dir/stderr" 'copy error not named' ;;
      changed-bytes) assert_grep 'stored bundle sha256 does not match record' "$case_dir/stderr" 'stored digest mismatch not named' ;;
    esac
  done
  pass 'failed copying or mismatched stored bytes retain the copy and commits'
}

# Admission copies the bundle into task data once; every later proof of the
# same teardown reuses the stored copy at its fixed path after a digest check.
test_bundle_admission_stores_once() {
  local case_dir rc proofs
  make_bundle_copy_case bundle-store-once
  case_dir=$NESTED_CASE
  : > "$case_dir/stored-copies.log"
  cat > "$case_dir/fakebin/cp" <<SH
#!/usr/bin/env bash
case "\${2:-}" in
  */preserved-bundles/.bundle.*) printf '%s\\n' "\$2" >> '$case_dir/stored-copies.log' ;;
esac
exec /bin/cp "\$@"
SH
  chmod +x "$case_dir/fakebin/cp"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "bundle-store-once: verified preservation must allow ordinary teardown: $(cat "$case_dir/stderr")"
  proofs=$(grep -c '^teardown: preserved unlanded commits in bundle ' "$case_dir/stderr")
  [ "$proofs" -ge 2 ] || fail "bundle-store-once: the fixture ran $proofs bundle proofs, fewer than two"
  assert_equals 1 "$(wc -l < "$case_dir/stored-copies.log" | tr -d ' ')" 'bundle-store-once: a later proof copied the bundle again'
  pass 'one teardown copies a preservation bundle into task data once and reuses it for later proofs'
}

test_bundle_sources_and_durable_home_locations() {
  local shape case_dir rc stored head restored
  for shape in source-copy source-pool source-state source-scratch home-worktree home-pool; do
    make_bundle_copy_case "bundle-location-$shape"
    case_dir=$NESTED_CASE
    head=$(git -C "$NESTED_COPY" rev-parse HEAD)
    case "$shape" in
      source-copy) BUNDLE_PATH="$NESTED_COPY/.claude/source.bundle" ;;
      source-pool) BUNDLE_PATH="$case_dir/pool/source.bundle" ;;
      source-state) BUNDLE_PATH="$case_dir/state/.nm-read-cache-task-x1/source.bundle" ;;
      source-scratch)
        printf 'tasktmp=%s\n' "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
        BUNDLE_PATH="$case_dir/tasktmp/source.bundle"
        ;;
      home-worktree|home-pool)
        if [ "$shape" = home-worktree ]; then
          stored="$case_dir/project/.claude/home-data"
        else
          stored="$case_dir/pool/home-data"
        fi
        mkdir -p "$stored"
        ln -s "$stored" "$case_dir/data/task-x1/preserved-bundles"
        ;;
    esac
    record_preservation_bundle "$case_dir" "$NESTED_COPY" "$BUNDLE_PATH" --all || fail 'cannot create source fixture'
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "bundle-location-$shape: safe storage must allow cleanup: $(cat "$case_dir/stderr")"
    assert_absent "$NESTED_COPY" 'copy not removed'
    stored="$case_dir/data/task-x1/preserved-bundles/$(cut -f2 "$case_dir/data/task-x1/preservation-bundles.tsv").bundle"
    rm -f "$BUNDLE_PATH"
    restored="$case_dir/restored.git"
    git init -q --bare "$restored"
    git -C "$restored" fetch -q "$stored" "$head:refs/heads/recovered" || fail 'stored copy cannot restore after source removal'
    assert_equals 'recoverable work' "$(git -C "$restored" show "$head:work.txt")" 'restored commit lost bytes'
  done
  pass 'temporary sources and durable homes inside other worktrees or pool folders retain recoverable commits'
}

# A bundle whose pack passes bundle verify and a connectivity-only fsck can still
# hold a commit that no strict reader accepts (here: author and committer are not
# valid idents). Such a bundle does not preserve the work, so the isolated
# restore must run fsck --strict and refuse, keeping the copy, bundle and record.
test_bundle_with_malformed_commit_refuses() {
  local case_dir rc record tree parent bad
  make_bundle_copy_case bundle-malformed-commit
  case_dir=$NESTED_CASE
  record="$case_dir/data/task-x1/preservation-bundles.tsv"
  tree=$(git -C "$NESTED_COPY" rev-parse 'HEAD^{tree}')
  parent=$(git -C "$NESTED_COPY" rev-parse origin/main)
  bad=$(printf 'tree %s\nparent %s\nauthor not an ident\ncommitter not an ident\n\nmalformed commit\n' "$tree" "$parent" \
    | git -C "$NESTED_COPY" hash-object -t commit -w --literally --stdin) || fail 'cannot create malformed commit fixture'
  git -C "$NESTED_COPY" update-ref HEAD "$bad" || fail 'cannot point the copy at the malformed commit'
  record_preservation_bundle "$case_dir" "$NESTED_COPY" "$BUNDLE_PATH" --all || fail 'cannot bundle the malformed commit'
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'bundle-malformed-commit: a bundle holding a malformed commit must refuse'
  assert_present "$NESTED_COPY/.git" 'bundle-malformed-commit: copy was removed'
  assert_present "$BUNDLE_PATH" 'bundle-malformed-commit: the preservation bundle was deleted'
  assert_present "$record" 'bundle-malformed-commit: the preservation record was deleted'
  assert_present "$case_dir/state/task-x1.meta" 'bundle-malformed-commit: task record was removed'
  assert_absent "$case_dir/treehouse.log" 'bundle-malformed-commit: pool slot was returned'
  assert_grep 'REFUSED: the ship deliverable is not landed' "$case_dir/stderr" 'bundle-malformed-commit: original refusal changed'
  assert_grep 'bundle cannot be restored in an isolated repository' "$case_dir/stderr" 'bundle-malformed-commit: restore refusal not named'
  pass 'a bundle that holds a structurally invalid commit never counts as preservation'
}

make_sibling_unpushed_work() {  # <case-dir>
  local case_dir=$1
  git -C "$case_dir/project" worktree add -q -b fm/sibling "$case_dir/sibling" main
  printf 'sibling in flight\n' > "$case_dir/sibling/sibling.txt"
  git -C "$case_dir/sibling" add sibling.txt
  git -C "$case_dir/sibling" -c user.email=t@t -c user.name=t commit -qm 'sibling unpublished work'
  SIBLING_HEAD=$(git -C "$case_dir/sibling" rev-parse HEAD)
}

test_bundle_ignores_branches_other_worktrees_hold() {
  local case_dir rc
  make_bundle_copy_case bundle-sibling
  case_dir=$NESTED_CASE
  make_sibling_unpushed_work "$case_dir"
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'project clone local commit'
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "bundle-sibling: another worktree's unpushed branch must not block this copy: $(cat "$case_dir/stderr")"
  assert_absent "$NESTED_COPY" 'bundle-sibling: preserved copy was not removed'
  assert_absent "$case_dir/state/task-x1.meta" 'bundle-sibling: task was not retired'
  assert_equals "$SIBLING_HEAD" "$(git -C "$case_dir/sibling" rev-parse HEAD)" 'bundle-sibling: sibling worktree lost its commit'
  assert_present "$case_dir/sibling/sibling.txt" 'bundle-sibling: sibling worktree was disturbed'
  pass 'a branch another worktree has checked out never has to be in this copy'"'"'s bundle'
}

test_bundle_covers_a_removed_copys_branch_without_other_worktrees() {
  local case_dir rc
  make_bundle_copy_case bundle-gone
  case_dir=$NESTED_CASE
  make_sibling_unpushed_work "$case_dir"
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'project clone local commit'
  git -C "$case_dir/project" worktree remove --force "$NESTED_COPY"
  assert_absent "$NESTED_COPY" 'bundle-gone: setup did not remove the nested copy'
  mkdir -p "$case_dir/project/.claude/durable-task-data"
  ln -s "$case_dir/project/.claude/durable-task-data" "$case_dir/data/task-x1/preserved-bundles"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "bundle-gone: a removed copy's branch held by its bundle must finish: $(cat "$case_dir/stderr")"
  assert_grep "$BUNDLE_PATH" "$case_dir/stderr" 'bundle-gone: bundle path not reported'
  assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" 'bundle-gone: the slot was not returned'
  assert_absent "$case_dir/state/task-x1.meta" 'bundle-gone: task was not retired'
  pass 'a removed copy'"'"'s branch is judged by its own bundle, not by the project clone or sibling worktrees'
}

test_bundle_survives_a_stale_registered_worktree() {
  local case_dir rc
  make_bundle_copy_case bundle-stale
  case_dir=$NESTED_CASE
  git -C "$case_dir/project" worktree add -q -b fm/stale "$case_dir/stale" main
  rm -rf "$case_dir/stale"
  git -C "$case_dir/project" worktree list --porcelain | grep -q '^prunable' \
    || fail 'bundle-stale: setup left no stale registered worktree'
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "bundle-stale: a deleted but still registered worktree must not block a valid bundle: $(cat "$case_dir/stderr")"
  assert_absent "$NESTED_COPY" 'bundle-stale: preserved copy was not removed'
  assert_absent "$case_dir/state/task-x1.meta" 'bundle-stale: task was not retired'
  pass 'a deleted but still registered worktree does not block a valid recorded bundle'
}

test_bundle_ignores_unrelated_unheld_tip() {
  local case_dir rc stale_head
  make_bundle_copy_case bundle-unheld-tip
  case_dir=$NESTED_CASE
  stale_head=$(git -C "$NESTED_COPY" commit-tree 'HEAD^{tree}' -p origin/main -m 'unrelated unpublished work')
  git -C "$NESTED_COPY" update-ref refs/heads/fm/unrelated "$stale_head"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "unrelated unheld branches survive this teardown: $(cat "$case_dir/stderr")"
  assert_absent "$NESTED_COPY" 'bundle-unheld-tip: preserved copy was not removed'
  assert_equals "$stale_head" "$(git -C "$case_dir/project" rev-parse refs/heads/fm/unrelated)" 'unrelated branch was deleted or moved'
  assert_equals 'recoverable work' "$(git -C "$case_dir/project" show "$stale_head:work.txt")" 'unrelated branch lost bytes'
  pass 'unrelated unheld branches need not be bundled because teardown leaves their refs and bytes intact'
}

# Counts the isolated-restore fetches teardown makes: each one reads the
# recorded bundle by path into a scratch repository.
install_restore_fetch_counter() {  # <case-dir>
  local case_dir=$1
  : > "$case_dir/restore-fetches"
  cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" fetch --quiet "*".bundle "*) printf 'fetch\n' >> "$case_dir/restore-fetches" ;;
esac
exec "\${REAL_GIT_FOR_TEST:?}" "\$@"
SH
  chmod +x "$case_dir/fakebin/git"
}

test_bundle_restore_runs_once_per_unchanged_proof() {
  local case_dir rc proofs
  make_bundle_copy_case bundle-memo
  case_dir=$NESTED_CASE
  install_restore_fetch_counter "$case_dir"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "bundle-memo: a verified bundle must allow ordinary teardown: $(cat "$case_dir/stderr")"
  proofs=$(grep -c 'preserved unlanded commits in bundle' "$case_dir/stderr" || true)
  [ "$proofs" -ge 2 ] || fail "bundle-memo: fixture made only $proofs proof; it cannot show a repeated proof"
  assert_equals 1 "$(wc -l < "$case_dir/restore-fetches" | tr -d ' ')" 'bundle-memo: repeated proofs of one bundle restored it more than once'
  pass 'repeated proofs of one unchanged bundle run the isolated restore once'
}

test_bundle_restore_memo_misses_a_changed_record_or_bundle() {
  local shape case_dir rc head tips size
  for shape in recorded-tips bundle-bytes; do
    make_bundle_copy_case "bundle-memo-$shape"
    case_dir=$NESTED_CASE
    install_restore_fetch_counter "$case_dir"
    head=$(git -C "$NESTED_COPY" rev-parse HEAD)
    case "$shape" in
      recorded-tips)
        cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in kill-*) printf '%s\t%s\t%s\n' '$BUNDLE_PATH' "\$(shasum -a 256 '$BUNDLE_PATH' | awk '{print \$1}')" '$head' > '$case_dir/data/task-x1/preservation-bundles.tsv' ;; esac
exit 0
SH
        ;;
      bundle-bytes)
        size=$(wc -c < "$BUNDLE_PATH")
        tips=$(git bundle list-heads "$BUNDLE_PATH" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
        cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in kill-*)
  head -c $((size - 16)) '$BUNDLE_PATH' > '$BUNDLE_PATH.cut' && mv '$BUNDLE_PATH.cut' '$BUNDLE_PATH'
  printf '%s\t%s\t%s\n' '$BUNDLE_PATH' "\$(shasum -a 256 '$BUNDLE_PATH' | awk '{print \$1}')" '$tips' > '$case_dir/data/task-x1/preservation-bundles.tsv' ;;
esac
exit 0
SH
        ;;
    esac
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    assert_equals 2 "$(wc -l < "$case_dir/restore-fetches" | tr -d ' ')" "bundle-memo-$shape: a changed proof reused the remembered restore"
    case "$shape" in
      recorded-tips)
        expect_code 0 "$rc" "bundle-memo-$shape: a narrower valid record must still allow teardown: $(cat "$case_dir/stderr")"
        ;;
      bundle-bytes)
        expect_code 1 "$rc" "bundle-memo-$shape: a truncated bundle must refuse at the final proof"
        assert_grep 'bundle cannot be restored in an isolated repository' "$case_dir/stderr" "bundle-memo-$shape: the truncated bundle was not refused"
        assert_present "$NESTED_COPY/.git" "bundle-memo-$shape: copy was removed"
        assert_present "$case_dir/state/task-x1.meta" "bundle-memo-$shape: task record was removed"
        ;;
    esac
  done
  pass 'a changed recorded tip set or changed bundle bytes is proved again, not taken from the remembered restore'
}

test_bundle_restore_memo_is_keyed_by_object_format() {
  local case_dir sha1_copy sha256_copy bundle digest tips rc=0
  case_dir=$(make_case bundle-memo-format)
  sha1_copy="$case_dir/sha1-repo"
  sha256_copy="$case_dir/sha256-repo"
  git init -q "$sha1_copy"
  git init -q --object-format=sha256 "$sha256_copy" 2>/dev/null || {
    echo "skip: this git cannot create sha256 repositories"
    return 0
  }
  git -C "$sha1_copy" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'sha1 work'
  bundle="$case_dir/bundles/format.bundle"
  mkdir -p "${bundle%/*}"
  git -C "$sha1_copy" bundle create "$bundle" --all 2>/dev/null || fail 'cannot create the sha1 bundle'
  digest=$(shasum -a 256 "$bundle" | awk '{print $1}')
  tips=$(git bundle list-heads "$bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
  install_restore_fetch_counter "$case_dir"
  PATH="$case_dir/fakebin:$PATH" bash -c '
    . "$1/bin/fm-teardown-nested-lib.sh"
    teardown_bundle_restorable "$2" "$3" "$4" "$5" || exit 11
    teardown_bundle_restorable "$2" "$3" "$4" "$5" || exit 12
    if teardown_bundle_restorable "$6" "$3" "$4" "$5"; then exit 13; fi
  ' _ "$ROOT" "$sha1_copy" "$bundle" "$digest" "$tips" "$sha256_copy" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "bundle-memo-format: restore memo harness failed: $(cat "$case_dir/stderr")"
  assert_equals 2 "$(wc -l < "$case_dir/restore-fetches" | tr -d ' ')" 'bundle-memo-format: the same bundle in another object format reused the remembered restore'
  pass 'the remembered restore is keyed by object format as well as bundle digest and tips'
}

# The same valid bundle accepted by an attended teardown must never authorize
# automatic cleanup, including an old merge notification for a different head.
test_unattended_teardown_refuses_bundle_only_copy() {
  local case_dir rc shape old now out
  for shape in idle-reap branch away quiet; do
    make_bundle_copy_case "bundle-unattended-$shape"
    case_dir=$NESTED_CASE
    rc=0
    case "$shape" in
      idle-reap)
        # The reaper parks a captain-held row before any teardown, so release
        # the call to reach the teardown refusal itself.
        tasks-axi unhold task-x1 --file "$case_dir/data/backlog.md" >/dev/null || fail 'cannot release the fixture hold'
        now=$(date +%s)
        old=$((now - 7200))
        append_pr_meta_url "$case_dir"
        printf 'harness=claude\n' >> "$case_dir/state/task-x1.meta"
        printf 'done [at=%s]: committed\n' "$old" > "$case_dir/state/task-x1.status"
        printf 'g1.1.1\n' > "$case_dir/state/task-x1.busy-gen"
        printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$now" \
          > "$case_dir/state/task-x1.busy-state"
        printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nexample/repo\n7\n' \
          > "$case_dir/state/task-x1.pr-poll-merge-notified"
        chmod 0600 "$case_dir/state/task-x1.pr-poll-merge-notified"
        fm_touch_epoch "$old" "$case_dir/state/task-x1.pr-poll-merge-notified"
        out=$(FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code-root" \
          FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
          FM_CONFIG_OVERRIDE="$case_dir/config" NM_HOME="$case_dir/nm" \
          FM_IDLE_REAP_TEARDOWN_BIN="$TEARDOWN" PATH="$case_dir/fakebin:$PATH" \
          bash "$ROOT/bin/fm-idle-session-reap.sh" reap 2>&1) || rc=$?
        expect_code 0 "$rc" "idle sweep must report its refusal: $out"
        [[ "$out" == *$'teardown-refused\ttask-x1\t'* ]] \
          || fail "idle sweep did not attempt and refuse bundle-only cleanup: $out"
        assert_grep 'REFUSED: the ship deliverable is not landed' \
          "$case_dir/state/.idle-reap/task-x1.refused" 'idle refusal changed'
        ;;
      branch)
        FM_HOME="$case_dir/home" FM_SUPERVISION_ACTOR=branch run_teardown "$case_dir" \
          > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        ;;
      away|quiet)
        printf '%s\n' "$shape" > "$case_dir/state/.afk"
        FM_HOME="$case_dir/home" run_teardown "$case_dir" \
          > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        ;;
    esac
    if [ "$shape" != idle-reap ]; then
      expect_code 1 "$rc" "$shape unattended teardown must refuse bundle-only cleanup"
      assert_grep 'recorded bundles require attended teardown' "$case_dir/stderr" 'missing attended-only reason'
      assert_grep 'REFUSED: the ship deliverable is not landed' "$case_dir/stderr" 'original refusal changed'
    fi
    assert_present "$NESTED_COPY/work.txt" "$shape: copy was removed"
    assert_present "$case_dir/state/task-x1.meta" "$shape: task record was removed"
    assert_present "$BUNDLE_PATH" "$shape: preservation bundle was removed"
    assert_absent "$case_dir/treehouse.log" "$shape: pool slot was returned"
  done
  pass 'idle reap, supervision branch and away or quiet cleanup refuse a copy held only by a bundle'
}

test_bundle_close_note_is_not_removal_authority() {
  local case_dir rc
  make_bundle_copy_case bundle-note-only
  case_dir=$NESTED_CASE
  seed_backlog_in_flight "$case_dir"
  tasks-axi 'done' task-x1 --note "preserved in bundle $BUNDLE_PATH, not landed" \
    --file "$case_dir/data/backlog.md" >/dev/null || fail 'cannot record the bookkeeping note'
  rm "$case_dir/data/task-x1/preservation-bundles.tsv"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'the close note alone must not allow removal'
  assert_grep 'missing preservation record' "$case_dir/stderr" 'the note substituted for preservation proof'
  assert_grep 'REFUSED: the ship deliverable is not landed' "$case_dir/stderr" 'original refusal changed'
  assert_present "$NESTED_COPY/work.txt" 'the close note authorized copy removal'
  assert_present "$case_dir/state/task-x1.meta" 'the close note authorized record removal'
  assert_absent "$case_dir/treehouse.log" 'the close note authorized a pool return'
  pass 'a preserved-in-bundle close note is bookkeeping only, never removal authority'
}

# The shared landed selector over the real fleet snapshot of a case's home.
bundle_case_snapshot() {  # <case-dir>
  PATH="$1/fakebin:$PATH" FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/state" \
    FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    FM_SNAPSHOT_NOW=2026-10-30T12:00:00Z "$ROOT/bin/fm-fleet-snapshot.sh" --json
}

bundle_case_landed_ids() {  # <snapshot-json>
  (
    . "$ROOT/bin/fm-landed-lib.sh"
    printf '%s' "$1" | jq -c "$FM_LANDED_JQ_DEFS"' [.backlog.records[] | select(landed_record) | .id]'
  )
}

# A verified bundle lets the copy go, but its commits still go to the captain to
# land or drop: the row held for that call stays open and held after removal,
# never closed, marked a drop or landed.
test_bundle_kept_ship_keeps_its_row_held_for_the_captain() {
  local shape case_dir rc second tips tip shown snapshot
  for shape in local-only open-pr; do
    if [ "$shape" = local-only ]; then
      make_bundle_copy_case "bundle-row-$shape" local-only
      second=$(git -C "$NESTED_COPY" commit-tree 'HEAD^{tree}' -p origin/main -m 'independent unpublished tip')
      git -C "$NESTED_COPY" update-ref refs/heads/fm/second "$second"
      record_preservation_bundle "$NESTED_CASE" "$NESTED_COPY" "$BUNDLE_PATH" --all || fail 'cannot bundle both tips'
    else
      make_bundle_copy_case "bundle-row-$shape"
    fi
    case_dir=$NESTED_CASE
    tips=$(cut -f3 "$case_dir/data/task-x1/preservation-bundles.tsv")
    [ "$shape" != open-pr ] || append_pr_meta_url "$case_dir"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "bundle-row-$shape: a verified bundle must allow ordinary teardown: $(cat "$case_dir/stderr")"
    assert_absent "$NESTED_COPY" "bundle-row-$shape: the preserved copy was not removed"
    assert_absent "$case_dir/state/task-x1.meta" "bundle-row-$shape: the task was not retired"
    assert_grep "land-or-drop call for bundle $BUNDLE_PATH is held on task task-x1" "$case_dir/stderr" \
      "bundle-row-$shape: teardown did not name the captain's call"
    shown=$(tasks-axi show task-x1 --full --file "$case_dir/data/backlog.md") || fail "bundle-row-$shape: cannot read the row"
    [ "$(backlog_row_state "$case_dir")" != "done" ] || fail "bundle-row-$shape: the row was closed: $shown"
    printf '%s\n' "$shown" | grep -Eq '^  hold_kind: *captain$' || fail "bundle-row-$shape: the call is no longer held: $shown"
    decoded_backlog "$case_dir" > "$case_dir/backlog.decoded" || fail "bundle-row-$shape: cannot decode the hold reason"
    for tip in $tips; do
      assert_grep "$tip" "$case_dir/backlog.decoded" "bundle-row-$shape: the held call lost recorded tip $tip"
    done
    [ "$shape" != local-only ] || [[ "$tips" == *"$second"* ]] || fail "bundle-row-$shape: the fixture does not record two tips"
    assert_grep "Deliverable of the finished work: preserved in bundle $case_dir/data/task-x1/preserved-bundles/$(cut -f2 "$case_dir/data/task-x1/preservation-bundles.tsv").bundle, not landed" \
      "$case_dir/data/backlog.md" "bundle-row-$shape: the row does not record the bundle"
    assert_no_grep 'local main' "$case_dir/data/backlog.md" "bundle-row-$shape: the row claims a local-main landing"
    assert_no_grep 'pull/7' "$case_dir/data/backlog.md" "bundle-row-$shape: the row links a PR that is not merged"
    snapshot=$(bundle_case_snapshot "$case_dir") || fail "bundle-row-$shape: fleet snapshot failed"
    printf '%s' "$snapshot" | jq -e '.backlog.records | any(.id == "task-x1" and .captain_drop == false and .hold_kind == "captain")' \
      >/dev/null || fail "bundle-row-$shape: the snapshot marks the held row a drop: $snapshot"
    assert_equals '[]' "$(bundle_case_landed_ids "$snapshot")" "bundle-row-$shape: the held row is listed as landed"
  done
  pass 'a ship kept only by a verified bundle leaves its captain-held row open, naming every tip and the bundle'
}

# The captain's answer closes the held row: still neither a drop nor a landing,
# and the opt-in ledger records the close with no landing evidence. The
# teardown itself retains the row and records no close.
test_bundle_kept_ship_records_no_landing_in_the_ledger() {
  local case_dir rc snapshot
  make_bundle_copy_case bundle-ledger local-only
  case_dir=$NESTED_CASE
  : > "$case_dir/config/fleet-ledger"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "bundle-ledger: a verified bundle must allow ordinary teardown: $(cat "$case_dir/stderr")"
  assert_equals '' "$(ledger_closed_rows "$case_dir")" 'bundle-ledger: the retained row was recorded as closed'
  printf 'Drop it; the bundle is enough.\n' > "$case_dir/answer.txt"
  run_captain_hold "$case_dir" answer task-x1 --decision-file "$case_dir/answer.txt" \
    > "$case_dir/answer.out" 2>&1 || fail "bundle-ledger: the captain's answer failed: $(cat "$case_dir/answer.out")"
  [ "$(backlog_row_state "$case_dir")" = "done" ] || fail 'bundle-ledger: the answer did not close the row'
  assert_equals '["task-x1","none",null,true]' "$(ledger_closed_rows "$case_dir")" \
    'bundle-ledger: a bundle close must not be recorded as a landing'
  snapshot=$(bundle_case_snapshot "$case_dir") || fail 'bundle-ledger: fleet snapshot failed'
  printf '%s' "$snapshot" | jq -e '.backlog.records | any(.id == "task-x1" and .state == "done" and .captain_drop == false)' \
    >/dev/null || fail "bundle-ledger: the answered row is marked a drop: $snapshot"
  assert_equals '[]' "$(bundle_case_landed_ids "$snapshot")" 'bundle-ledger: the answered row is listed as landed'
  pass 'ledger on: a bundle-kept ship is retained, and its answered close records no landing evidence'
}

# The bundle route needs the captain's call already filed. Without it teardown
# refuses, files nothing, and prints the exact command; running that command
# lets a retry pass. A row already held on another question keeps its question
# and the call is a separate held task.
test_bundle_route_requires_the_captains_call() {
  local shape case_dir rc command head tips tip id
  for shape in unheld other-question absent; do
    make_bundle_copy_case "bundle-call-$shape"
    case_dir=$NESTED_CASE
    head=$(git -C "$NESTED_COPY" rev-parse HEAD)
    tips=$(cut -f3 "$case_dir/data/task-x1/preservation-bundles.tsv")
    case "$shape" in
      unheld)
        tasks-axi unhold task-x1 --file "$case_dir/data/backlog.md" >/dev/null || fail 'cannot release the fixture hold'
        id=task-x1
        ;;
      other-question)
        run_captain_hold "$case_dir" hold task-x1 --owner captain --reason 'Merge PR 7 now?' >/dev/null \
          || fail 'cannot hold the row on another question'
        id=task-x1-bundle
        ;;
      absent)
        printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/data/backlog.md"
        id=task-x1
        ;;
    esac
    cp "$case_dir/data/backlog.md" "$case_dir/backlog.before"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "bundle-call-$shape: a bundle with no captain's call must refuse: $(cat "$case_dir/stderr")"
    assert_grep 'REFUSED: the ship deliverable is not landed' "$case_dir/stderr" "bundle-call-$shape: original refusal changed"
    assert_present "$NESTED_COPY/work.txt" "bundle-call-$shape: copy was removed"
    assert_present "$case_dir/state/task-x1.meta" "bundle-call-$shape: task record was removed"
    cmp -s "$case_dir/backlog.before" "$case_dir/data/backlog.md" || fail "bundle-call-$shape: teardown changed the backlog"
    command=$(sed -n -e 's/^Hold it for the captain, then retry ordinary teardown: //p' \
      -e 's/^File the land-or-drop call as its own task, then retry ordinary teardown: //p' \
      -e 's/^File the land-or-drop call as its row, then retry ordinary teardown: //p' "$case_dir/stderr")
    [ -n "$command" ] || fail "bundle-call-$shape: no hold command printed: $(cat "$case_dir/stderr")"
    if [ "$shape" = absent ]; then
      [[ "$command" == 'bin/fm-captain-hold.sh hold task-x1 --title Land\ or\ drop\ the\ bundle-preserved\ commits\ of\ task-x1 --repo project --owner captain --reason '* ]] \
        || fail "bundle-call-$shape: the command is not the single hold-with-title form: $command"
      [[ "$command" != *'&&'* && "$command" != *fm-tasks-axi.sh* ]] \
        || fail "bundle-call-$shape: the command chains another step: $command"
    else
      [[ "$command" == "bin/fm-captain-hold.sh hold $id "* ]] || fail "bundle-call-$shape: the command holds the wrong task: $command"
    fi
    (
      cd "$ROOT"
      export FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
        FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH"
      eval "$command"
    ) > "$case_dir/hold.out" 2>&1 || fail "bundle-call-$shape: the printed command failed: $command: $(cat "$case_dir/hold.out")"
    decoded_backlog "$case_dir" > "$case_dir/backlog.decoded" || fail "bundle-call-$shape: cannot decode the hold reason"
    assert_grep "unlanded commits of task-x1, tips $head:" "$case_dir/backlog.decoded" \
      "bundle-call-$shape: the call does not name the copy's unlanded tip"
    for tip in $tips; do
      assert_grep "$tip" "$case_dir/backlog.decoded" "bundle-call-$shape: the call does not name recorded tip $tip"
    done
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "bundle-call-$shape: the filed call must let teardown pass: $(cat "$case_dir/stderr")"
    assert_absent "$NESTED_COPY" "bundle-call-$shape: the preserved copy was not removed"
    assert_grep "is held on task $id" "$case_dir/stderr" "bundle-call-$shape: teardown did not name the call's task"
    tasks-axi show "$id" --full --file "$case_dir/data/backlog.md" | grep -Eq '^  hold_kind: *captain$' \
      || fail "bundle-call-$shape: the call $id did not stay open and held"
    tasks-axi show task-x1 --full --file "$case_dir/data/backlog.md" | grep -Eq '^  hold_kind: *captain$' \
      || fail "bundle-call-$shape: the work row did not stay held"
    [ "$shape" != absent ] || tasks-axi show task-x1 --full --file "$case_dir/data/backlog.md" | grep -Eq '^  repo: *project$' \
      || fail "bundle-call-$shape: the filed call row lost the ship's project: $(tasks-axi show task-x1 --full --file "$case_dir/data/backlog.md")"
    [ "$shape" != other-question ] || assert_grep 'Merge PR 7 now?' "$case_dir/backlog.decoded" \
      "bundle-call-$shape: the row's own question was replaced"
  done
  pass 'the bundle route refuses until the captain'"'"'s land-or-drop call is held, prints the command that files it, and passes once it is'
}

# A home whose backlog transition does not apply has no row that can hold the
# captain's call: the bundle route refuses there and prints no command that
# could not pass.
test_bundle_route_refuses_where_no_row_can_hold_the_call() {
  local shape case_dir rc
  for shape in manual orca; do
    make_bundle_copy_case "bundle-no-row-$shape"
    case_dir=$NESTED_CASE
    case "$shape" in
      manual) printf 'manual\n' > "$case_dir/config/backlog-backend" ;;
      orca) printf 'cleanup_recovery=orca\n' >> "$case_dir/state/task-x1.meta" ;;
    esac
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "bundle-no-row-$shape: the bundle route must refuse: $(cat "$case_dir/stderr")"
    assert_grep "no backlog row can hold the captain's land-or-drop call in this home" "$case_dir/stderr" \
      "bundle-no-row-$shape: the refusal does not name the missing row"
    assert_grep 'REFUSED: the ship deliverable is not landed' "$case_dir/stderr" "bundle-no-row-$shape: original refusal changed"
    assert_no_grep 'fm-captain-hold.sh hold' "$case_dir/stderr" "bundle-no-row-$shape: a hold command that cannot pass was printed"
    assert_no_grep 'fm-tasks-axi.sh add' "$case_dir/stderr" "bundle-no-row-$shape: an add command that cannot pass was printed"
    assert_present "$NESTED_COPY/work.txt" "bundle-no-row-$shape: copy was removed"
    assert_present "$case_dir/state/task-x1.meta" "bundle-no-row-$shape: task record was removed"
  done
  pass 'the bundle route refuses in a manual-backlog home and an Orca cleanup recovery, printing no command that cannot pass'
}

# Work the ordinary landing proof accepts never needs the captain's call, even
# with a preservation record present.
test_landed_work_never_needs_the_captains_call() {
  local case_dir rc
  make_bundle_copy_case bundle-landed local-only
  case_dir=$NESTED_CASE
  tasks-axi unhold task-x1 --file "$case_dir/data/backlog.md" >/dev/null || fail 'cannot release the fixture hold'
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$NESTED_COPY" rev-parse HEAD)"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "bundle-landed: landed work must pass the ordinary proof: $(cat "$case_dir/stderr")"
  assert_no_grep 'preserved unlanded commits in bundle' "$case_dir/stderr" 'bundle-landed: landed work took the bundle route'
  assert_no_grep 'fm-captain-hold.sh hold' "$case_dir/stderr" 'bundle-landed: landed work was asked for a captain call'
  assert_absent "$NESTED_COPY" 'bundle-landed: landed copy was not removed'
  [ "$(backlog_row_state "$case_dir")" = "done" ] || fail 'bundle-landed: the landed row was not closed'
  assert_grep 'local main' "$case_dir/data/backlog.md" 'bundle-landed: the landed row does not record its local-main landing'
  pass 'landed work with a preservation record passes the ordinary proof and never needs the captain'"'"'s call'
}

test_bundle_hint_needs_unlanded_tips() {
  local case_dir rc
  make_bundle_copy_case bundle-pushed
  case_dir=$NESTED_CASE
  git -C "$NESTED_COPY" push -q origin fm/task-x1-v2
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'a pushed but undelivered copy must still refuse'
  assert_grep 'copy has no unlanded tips of its own' "$case_dir/stderr" 'bundle-pushed: the bundle limit was not named'
  assert_no_grep 'Create a self-contained external bundle' "$case_dir/stderr" 'bundle-pushed: a bundle was advised for a copy with nothing unpushed'
  assert_present "$NESTED_COPY/.git" 'bundle-pushed: copy was removed'
  assert_present "$case_dir/state/task-x1.meta" 'bundle-pushed: task record was removed'
  pass 'a copy with no local-only commits is not advised to build a bundle'
}

test_bundle_needs_the_copys_own_unlanded_tip() {
  local case_dir rc side
  make_bundle_copy_case bundle-side-only
  case_dir=$NESTED_CASE
  append_pr_meta_url "$case_dir"
  git -C "$NESTED_COPY" push -q origin fm/task-x1-v2
  side=$(git -C "$NESTED_COPY" commit-tree 'HEAD^{tree}' -p origin/main -m 'unlanded side branch work')
  git -C "$NESTED_COPY" update-ref refs/heads/fm/side-only "$side"
  record_preservation_bundle "$case_dir" "$NESTED_COPY" "$BUNDLE_PATH" --all || fail 'cannot bundle the side branch'
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'a pushed copy must not take the bundle route through a side branch'
  assert_grep 'copy has no unlanded tips of its own; existing delivery proof is still required' "$case_dir/stderr" 'bundle-side-only: the delivery-proof reason was not named'
  assert_grep 'REFUSED: the ship deliverable is not landed' "$case_dir/stderr" 'bundle-side-only: the delivery refusal was waived'
  assert_no_grep 'preserved unlanded commits in bundle' "$case_dir/stderr" 'bundle-side-only: the bundle was accepted'
  assert_present "$NESTED_COPY/.git" 'bundle-side-only: copy was removed'
  assert_present "$case_dir/state/task-x1.meta" 'bundle-side-only: task record was removed'
  assert_absent "$case_dir/treehouse.log" 'bundle-side-only: pool slot was returned'
  pass 'a pushed copy whose only local-only commits sit on a side branch still needs its delivery proof'
}

test_bundle_hint_skips_a_moved_head_at_final_custody() {
  local case_dir rc slot bundle
  case_dir=$(make_case bundle-moved-head)
  mkdir -p "$case_dir/home/state" "$case_dir/pool/1"
  slot="$case_dir/pool/1/project"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$slot"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"task-x1"}]}\n' "$slot" \
    > "$case_dir/pool/treehouse-state.json"
  printf 'task=task-x1\nhome=%s\n' "$case_dir/home" > "$case_dir/pool/1/.fm-slot-owner"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$slot" "branch=fm/task-x1" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1"
  printf 'recoverable work\n' > "$slot/work.txt"
  git -C "$slot" add work.txt
  git -C "$slot" -c user.email=t@t -c user.name=t commit -qm 'unpublished work'
  bundle="$case_dir/bundles/work.bundle"
  record_preservation_bundle "$case_dir" "$slot" "$bundle" --all || fail 'cannot create bundle fixture'
  cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" log --oneline HEAD --not --remotes "*)
    n=\$(cat "$case_dir/safety-passes" 2>/dev/null || echo 0)
    printf '%s\n' \$((n + 1)) > "$case_dir/safety-passes"
    if [ \$((n + 1)) -eq 3 ]; then
      "\${REAL_GIT_FOR_TEST:?}" -C "$slot" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'moved after admission'
    fi
    ;;
esac
exec "\${REAL_GIT_FOR_TEST:?}" "\$@"
SH
  chmod +x "$case_dir/fakebin/git"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "bundle-moved-head: a HEAD moved after admission must refuse: $(cat "$case_dir/stderr")"
  assert_grep 'preserved unlanded commits in bundle' "$case_dir/stderr" 'bundle-moved-head: initial valid preservation was not admitted'
  assert_grep 'after its landing proof' "$case_dir/stderr" 'bundle-moved-head: the final proof did not name the moved HEAD'
  assert_no_grep 'Create a self-contained external bundle' "$case_dir/stderr" 'bundle-moved-head: a bundle was advised for a moved HEAD'
  assert_present "$slot/.git" 'bundle-moved-head: slot was removed'
  # Read-only pool queries (pool-dir, status) may run; a return must not.
  assert_no_grep 'return' "$case_dir/treehouse.log" 'bundle-moved-head: slot was returned'
  pass 'a HEAD that moves after a bundle admission refuses at final custody without advising a bundle'
}

test_bundle_is_reverified_before_copy_removal() {
  local case_dir rc
  make_bundle_copy_case bundle-recheck
  case_dir=$NESTED_CASE
  # Endpoint cleanup happens after admission but before the final safety proof.
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in kill-*) printf 'changed after admission\\n' >> "$BUNDLE_PATH" ;; esac
exit 0
SH
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'changed preservation must refuse at the final proof'
  assert_grep 'preserved unlanded commits in bundle' "$case_dir/stderr" 'initial valid preservation was not admitted'
  assert_grep 'sha256 does not match record' "$case_dir/stderr" 'final proof reused stale preservation'
  assert_present "$NESTED_COPY/.git" 'changed bundle removed its copy'
  assert_present "$case_dir/state/task-x1.meta" 'changed bundle removed its task record'
  assert_absent "$case_dir/treehouse.log" 'changed bundle returned its pool slot'
  pass 'a bundle changed after admission is rejected before copy removal'
}

test_bundle_does_not_excuse_dirty_copy() {
  local case_dir rc
  make_bundle_copy_case bundle-dirty
  case_dir=$NESTED_CASE
  printf 'unsaved\n' >> "$NESTED_COPY/work.txt"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'a valid bundle must not excuse uncommitted changes'
  assert_grep 'has uncommitted changes' "$case_dir/stderr" 'dirty refusal changed'
  assert_present "$NESTED_COPY/work.txt" 'dirty copy was removed'
  assert_absent "$case_dir/treehouse.log" 'dirty copy returned its pool slot'
  pass 'a verified bundle never excuses uncommitted changes'
}

# A bundle covers only commits. A task copy or own prior copy that teardown
# removes from inside the pool slot keeps its refusal while it holds an ignored
# file no hash record preserves, as it did before bundles were accepted.
test_bundle_does_not_excuse_nested_copy_ignored_files() {
  local case_dir rc run shape nested
  for run in nested:control nested:.claude/worktrees/side nested:nested/side enclosing:control enclosing:nested/current; do
    shape=${run%%:*}
    nested=${run#*:}
    make_nested_slot_case "bundle-ignored-$shape-${nested//\//-}" "$shape" "${nested/#control/nested/control}"
    case_dir=$NESTED_CASE
    printf 'copy work\n' > "$NESTED_COPY/work.txt"
    git -C "$NESTED_COPY" add work.txt
    git -C "$NESTED_COPY" commit -qm 'unpublished copy work'
    record_preservation_bundle "$case_dir" "$NESTED_COPY" "$case_dir/bundles/work.bundle" --all \
      || fail 'cannot create bundle fixture'
    if [ "$nested" = control ]; then
      rc=0
      FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "$run: a bundle must still admit a copy with no unique ignored file: $(cat "$case_dir/stderr")"
      assert_absent "$NESTED_COPY" "$run: bundled copy was not removed"
      continue
    fi
    printf 'unique.dat\n' >> "$(git -C "$NESTED_COPY" rev-parse --path-format=absolute --git-path info/exclude)"
    printf 'only copy\n' > "$NESTED_COPY/unique.dat"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$run: a bundle must not excuse a copy's unpreserved ignored file: $(cat "$case_dir/stderr")"
    assert_grep 'ignored files no hash record preserves: unique.dat' "$case_dir/stderr" "$run: ignored-file refusal missing"
    assert_equals 'only copy' "$(cat "$NESTED_COPY/unique.dat")" "$run: unpreserved ignored file lost"
    assert_present "$NESTED_COPY/.git" "$run: copy was removed"
    assert_present "$case_dir/state/task-x1.meta" "$run: task was retired"
    assert_absent "$case_dir/treehouse.log" "$run: pool slot was returned"
  done
  pass 'a verified bundle never excuses a removed copy holding unpreserved ignored files'
}

# The bundle admits the task copy, not this other copy. Anchored or landed
# commits do not preserve a swept prior copy's unique ignored bytes.
# Ordinary landed-only cleanup is a separate pre-existing rule, not this test.
test_bundle_sweep_keeps_anchored_and_landed_prior_ignored_files() {
  local case_dir prior run proof bytes rc head
  for run in anchored:unique anchored:clean landed:unique landed:clean; do
    proof=${run%%:*}
    bytes=${run#*:}
    make_nested_slot_case "bundle-sweep-$proof-$bytes" enclosing nested/current
    case_dir=$NESTED_CASE
    printf 'task work\n' > "$NESTED_COPY/work.txt"
    git -C "$NESTED_COPY" add work.txt
    git -C "$NESTED_COPY" commit -qm 'unpublished task work'
    record_preservation_bundle "$case_dir" "$NESTED_COPY" "$case_dir/bundles/work.bundle" --all \
      || fail 'cannot create bundle fixture'
    prior="$NESTED_SLOT/nested/prior"
    git -C "$case_dir/project" worktree add -q -b fm/task-x1-prior "$prior" main
    if [ "$proof" = anchored ]; then
      printf 'prior work\n' > "$prior/prior.txt"
      git -C "$prior" add prior.txt
      git -C "$prior" commit -qm 'anchored prior work outside the bundle'
      head=$(git -C "$prior" rev-parse HEAD)
      git -C "$case_dir/project" update-ref "refs/fm/anchor/task-x1-$head" "$head"
    fi
    printf 'prior_worktree=%s\n' "$prior" >> "$case_dir/state/task-x1.meta"
    if [ "$bytes" = unique ]; then
      printf 'unique-anchored.dat\n' >> "$(git -C "$prior" rev-parse --path-format=absolute --git-path info/exclude)"
      printf 'only copy\n' > "$prior/unique-anchored.dat"
    fi
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$bytes" = clean ]; then
      expect_code 0 "$rc" "$run: a clean proved prior copy must not block the bundle route: $(cat "$case_dir/stderr")"
      assert_absent "$prior" "$run: clean prior copy survived"
      assert_absent "$NESTED_COPY" "$run: clean task copy survived"
      continue
    fi
    expect_code 1 "$rc" "$run: bundle admission must not discard a different copy's ignored bytes: $(cat "$case_dir/stderr")"
    assert_grep 'ignored files no hash record preserves: unique-anchored.dat' "$case_dir/stderr" "$run: ignored-file refusal missing"
    assert_equals 'only copy' "$(cat "$prior/unique-anchored.dat")" "$run: prior ignored bytes lost"
    assert_present "$prior/.git" "$run: prior copy removed before refusal"
    assert_present "$NESTED_COPY/.git" "$run: task copy removed before refusal"
    assert_present "$case_dir/state/task-x1.meta" "$run: task retired before refusal"
    assert_absent "$case_dir/treehouse.log" "$run: slot returned before refusal"
  done
  pass 'bundle admission refuses before sweeping anchored or landed prior copies with unique ignored bytes'
}

# The task's current copy is already gone, so the bundle admits its branch ref.
# A swept anchored prior's unique ignored bytes refuse before retire reaps.
test_bundle_removed_copy_sweep_refuses_before_retire() {
  local case_dir prior bytes rc head
  for bytes in unique clean; do
    make_bundle_copy_case "bundle-gone-prior-$bytes"
    case_dir=$NESTED_CASE
    prior="$NESTED_SLOT/nested/prior"
    mkdir -p "${prior%/*}"
    git -C "$case_dir/project" worktree add -q -b fm/task-x1-prior "$prior" main
    printf 'prior work\n' > "$prior/prior.txt"
    git -C "$prior" add prior.txt
    git -C "$prior" commit -qm 'anchored prior work outside the bundle'
    head=$(git -C "$prior" rev-parse HEAD)
    git -C "$case_dir/project" update-ref "refs/fm/anchor/task-x1-$head" "$head"
    printf 'prior_worktree=%s\n' "$prior" >> "$case_dir/state/task-x1.meta"
    if [ "$bytes" = unique ]; then
      printf 'unique-anchored.dat\n' >> "$(git -C "$prior" rev-parse --path-format=absolute --git-path info/exclude)"
      printf 'only copy\n' > "$prior/unique-anchored.dat"
    fi
    git -C "$case_dir/project" worktree remove --force "$NESTED_COPY"
    assert_absent "$NESTED_COPY" "gone-prior-$bytes: setup did not remove the current copy"
    cat > "$case_dir/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*) printf '%s\n' "\$*" >> "$case_dir/lsof-cwd.log"; exit 0 ;;
esac
exit 1
SH
    chmod +x "$case_dir/fakebin/lsof"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$bytes" = clean ]; then
      expect_code 0 "$rc" "gone-prior-clean: a clean anchored prior must not block the bundle route: $(cat "$case_dir/stderr")"
      assert_absent "$prior" 'gone-prior-clean: clean prior copy survived'
      assert_absent "$case_dir/state/task-x1.meta" 'gone-prior-clean: task was not retired'
      assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" 'gone-prior-clean: the slot was not returned'
      continue
    fi
    expect_code 1 "$rc" "gone-prior-unique: bundle admission must not discard a prior copy's ignored bytes: $(cat "$case_dir/stderr")"
    assert_grep 'ignored files no hash record preserves: unique-anchored.dat' "$case_dir/stderr" 'gone-prior-unique: ignored-file refusal missing'
    assert_equals 'only copy' "$(cat "$prior/unique-anchored.dat")" 'gone-prior-unique: prior ignored bytes lost'
    assert_present "$prior/.git" 'gone-prior-unique: prior copy removed before refusal'
    assert_present "$case_dir/state/task-x1.meta" 'gone-prior-unique: task retired before refusal'
    assert_absent "$case_dir/treehouse.log" 'gone-prior-unique: slot reserved or returned before refusal'
    assert_absent "$case_dir/lsof-cwd.log" 'gone-prior-unique: retire reaped processes before refusal'
  done
  pass 'a removed copy'"'"'s bundle-admitted branch refuses before retire while a swept prior holds unique ignored bytes'
}

# A foreign copy inside an own nested copy cannot stay held. Its bundle must
# trigger the same own-copy ignored-byte proof without changing foreign classes.
test_foreign_bundle_sweep_keeps_anchored_prior_ignored_files() {
  local case_dir prior foreign bytes rc head digest stored
  for bytes in unique clean; do
    make_nested_slot_case "foreign-bundle-sweep-$bytes" reverse nested/prior
    case_dir=$NESTED_CASE
    prior=$NESTED_COPY
    add_lsof_no_holder "$case_dir"
    printf 'anchored prior work\n' > "$prior/prior.txt"
    git -C "$prior" add prior.txt
    git -C "$prior" commit -qm 'anchored prior outside foreign bundle'
    head=$(git -C "$prior" rev-parse HEAD)
    git -C "$case_dir/project" update-ref "refs/fm/anchor/task-x1-$head" "$head"
    if [ "$bytes" = unique ]; then
      printf 'unique-anchored.dat\n' >> "$(git -C "$prior" rev-parse --path-format=absolute --git-path info/exclude)"
      printf 'only copy\n' > "$prior/unique-anchored.dat"
    fi
    foreign="$prior/.claude/worktrees/foreign"
    mkdir -p "${foreign%/*}"
    git -C "$case_dir/project" worktree add -q -b fm/foreign-bundled "$foreign" main
    printf 'foreign work\n' > "$foreign/foreign.txt"
    git -C "$foreign" add foreign.txt
    git -C "$foreign" commit -qm 'foreign unlanded work'
    head=$(git -C "$foreign" rev-parse HEAD)
    record_preservation_bundle "$case_dir" "$foreign" "$case_dir/bundles/foreign.bundle" HEAD \
      || fail 'cannot create foreign bundle fixture'
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$bytes" = clean ]; then
      expect_code 0 "$rc" "foreign-$bytes: clean own and foreign copies must remain removable: $(cat "$case_dir/stderr")"
      assert_absent "$prior" 'foreign-clean: prior copy survived'
      assert_absent "$foreign" 'foreign-clean: foreign copy survived'
      digest=$(cut -f2 "$case_dir/data/task-x1/preservation-bundles.tsv")
      stored="$case_dir/data/task-x1/preserved-bundles/$digest.bundle"
      rm "$case_dir/bundles/foreign.bundle"
      git init -q --bare "$case_dir/restore.git"
      git -C "$case_dir/restore.git" fetch -q "$stored" "$head:refs/heads/recovered"
      assert_equals "$head" "$(git -C "$case_dir/restore.git" rev-parse recovered)" 'foreign-clean: exact preserved tip was not restored'
      assert_equals 'foreign work' "$(git -C "$case_dir/restore.git" show recovered:foreign.txt)" 'foreign-clean: preserved content changed'
      continue
    fi
    expect_code 1 "$rc" "foreign-$bytes: a foreign bundle must not waive own ignored bytes: $(cat "$case_dir/stderr")"
    assert_grep 'ignored files no hash record preserves: unique-anchored.dat' "$case_dir/stderr" 'foreign-unique: ignored-file refusal missing'
    assert_equals 'only copy' "$(cat "$prior/unique-anchored.dat")" 'foreign-unique: own ignored bytes lost'
    assert_present "$prior/.git" 'foreign-unique: own copy removed before refusal'
    assert_present "$foreign/.git" 'foreign-unique: foreign copy removed before refusal'
    assert_present "$NESTED_SLOT/.git" 'foreign-unique: task copy removed before refusal'
    assert_present "$case_dir/state/task-x1.meta" 'foreign-unique: task retired before refusal'
    assert_absent "$case_dir/treehouse.log" 'foreign-unique: slot returned before refusal'
  done
  pass 'foreign bundle admission refuses before sweeping anchored own ignored bytes, while clean copies remain recoverable'
}

test_foreign_bundle_preservation_keeps_other_proofs() {
  local shape rc head pid real_cp
  for shape in clean dirty ignored process; do
    make_foreign_copy_case "foreign-bundle-$shape"
    printf 'unpublished foreign bytes\n' > "$FOREIGN_COPY/work.txt"
    git -C "$FOREIGN_COPY" add work.txt
    git -C "$FOREIGN_COPY" commit -qm 'unpublished foreign work'
    head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
    record_preservation_bundle "$FOREIGN_CASE" "$FOREIGN_COPY" "$FOREIGN_CASE/bundles/foreign.bundle" --all \
      || fail 'cannot preserve foreign commits'
    pid=
    case "$shape" in
      dirty) printf 'unsaved\n' >> "$FOREIGN_COPY/work.txt" ;;
      ignored)
        printf 'unique.dat\n' >> "$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)"
        printf 'only copy\n' > "$FOREIGN_COPY/unique.dat"
        real_cp=$(command -v cp)
        cat > "$FOREIGN_CASE/fakebin/cp" <<SH
#!/usr/bin/env bash
case " \$* " in *nested-copy-preserved*) exit 1 ;; esac
exec "$real_cp" "\$@"
SH
        chmod +x "$FOREIGN_CASE/fakebin/cp"
        ;;
      process)
        teardown_fixture_start "$FOREIGN_COPY" KILL sleep 300
        pid=$TEARDOWN_FIXTURE_PID
        cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*) if kill -0 $pid 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $pid '$FOREIGN_COPY'; fi; exit 0 ;;
esac
exit 1
SH
        ;;
    esac
    run_foreign_teardown rc
    if [ "$shape" = clean ]; then
      expect_code 0 "$rc" "foreign bundle: ordinary removal failed: $(cat "$FOREIGN_CASE/stderr")"
      assert_absent "$FOREIGN_COPY" 'foreign bundled copy survived'
      assert_absent "$FOREIGN_CASE/closeout.log" 'unlocked foreign copy invoked the closeout driver'
      assert_grep "$head" "$FOREIGN_CASE/stderr" 'foreign preservation tip not reported'
    elif [ "$shape" = ignored ]; then
      # The held-copy rule closes the task and leaves this copy exactly as it was.
      expect_code 0 "$rc" "foreign bundle: an ignored-file copy must be held: $(cat "$FOREIGN_CASE/stderr")"
      assert_present "$FOREIGN_COPY/.git" 'held bundled copy was removed'
      assert_equals 'only copy' "$(cat "$FOREIGN_COPY/unique.dat")" 'unpreserved ignored file lost'
      assert_grep 'ignored files that exist nowhere else: unique.dat' "$FOREIGN_CASE/data/held-foreign-copies.log" \
        'held copy was not recorded for its ignored file'
      assert_no_grep 'return' "$FOREIGN_CASE/treehouse.log" 'held copy slot was returned'
      assert_absent "$FOREIGN_CASE/closeout.log" 'held copy invoked the closeout driver'
    else
      expect_code 1 "$rc" "foreign bundle must not excuse $shape"
      assert_foreign_copy_untouched "foreign-bundle-$shape"
      case "$shape" in
        dirty) assert_grep 'uncommitted' "$FOREIGN_CASE/stderr" 'dirty proof missing' ;;
        process)
          assert_grep "process $pid is running in it" "$FOREIGN_CASE/stderr" 'process proof missing'
          kill -0 "$pid" 2>/dev/null || fail 'foreign process was signalled'
          teardown_fixture_stop "$pid"
          ;;
      esac
    fi
  done
  pass 'foreign bundles permit ordinary cleanup but never excuse dirty bytes or live foreign processes, and unpreserved ignored files hold the copy'
}


# Merge-train landing proof. A member PR closed (not merged) because a merged train
# PR carried it is landed only when the forge shows that train MERGED into the
# task's base, listing this member URL at the member's recorded head, containing
# that head, and the copy's work carried by the train head. Rows 1 to 8 are built
# so no other proof applies: the default branch has moved on and edited the same
# file, and no bundle or run record exists.
assert_train_allowed() {  # <case-dir> <label>
  local case_dir=$1 label=$2 rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "$label: teardown should accept the verified train"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "$label: teardown printed a REFUSED line"
  assert_grep "return" "$case_dir/treehouse.log" "$label: the slot was not returned"
  assert_absent "$case_dir/state/task-x1.meta" "$label: accepted teardown left the task record"
  assert_grep "$TRAIN_URL" "$case_dir/stderr" "$label: stderr did not name the train PR"
  assert_grep "$TRAIN_MEMBER_URL" "$case_dir/stderr" "$label: stderr did not name the member PR"
  assert_grep "$TRAIN_MEMBER_HEAD" "$case_dir/stderr" "$label: stderr did not name the listed sha"
}

# The closed row records the merged train as its PR and the member as closed by it,
# and the ledger's merged_pr evidence names the train, never the closed member.
assert_train_backlog_close() {  # <case-dir> <label>
  local case_dir=$1 label=$2 row
  row=$(grep -F -- '- [x] task-x1 ' "$case_dir/data/backlog.md") \
    || fail "$label: the backlog has no closed task-x1 row"$'\n'"$(cat "$case_dir/data/backlog.md")"
  case "$row" in *" $TRAIN_URL "*) ;; *) fail "$label: the closed row does not record the train PR: $row" ;; esac
  case "$row" in *"$TRAIN_MEMBER_URL"*) fail "$label: the closed row records the closed member as its PR: $row" ;; esac
  grep -qxF "  closed by merge train: $TRAIN_MEMBER_URL" "$case_dir/data/backlog.md" \
    || fail "$label: the close did not name the member as closed by the train"$'\n'"$(cat "$case_dir/data/backlog.md")"
  if [ -e "$case_dir/config/fleet-ledger" ]; then
    assert_equals "[\"task-x1\",\"merged_pr\",\"$TRAIN_URL\",true]" \
      "$(ledger_closed_rows "$case_dir")" "$label: task.closed record"
  fi
}

# A refused teardown names the failed fact, keeps the copy and every record, and
# never asks the pool to return the slot.
assert_train_refused() {  # <case-dir> <label> <fact> [unknown]
  local case_dir=$1 label=$2 fact=$3 kind=${4:-} rc=0 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD 2>/dev/null || true)
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$label: teardown must refuse"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "REFUSED" "$case_dir/stderr" "$label: refusal did not say REFUSED"
  assert_grep "$fact" "$case_dir/stderr" "$label: refusal did not name the failed fact"$'\n'"$(cat "$case_dir/stderr")"
  if [ "$kind" = unknown ]; then
    assert_no_grep "ship deliverable is not landed" "$case_dir/stderr" \
      "$label: an unread forge fact was reported as not landed"
    assert_grep "unknown, retry" "$case_dir/stderr" "$label: refusal did not say the proof is unknown"
  fi
  assert_absent "$case_dir/treehouse.log" "$label: refused teardown returned the slot"
  assert_present "$case_dir/state/task-x1.meta" "$label: refusal removed the task record"
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the copy"
  [ -z "$head" ] || [ "$(git -C "$case_dir/wt" rev-parse HEAD)" = "$head" ] || fail "$label: refusal moved the copy's HEAD"
}

# The proof is about delivered content, not history: a train can contain a member's
# commit, or replay its patch, and then revert the change before it lands.
test_train_reverted_member_never_counts_as_carried() {
  local landing shape
  for landing in squash merge; do
    for shape in merge flat; do
      # A copy at the member head is reachable from a default branch that took the
      # train in by a merge commit; the default proof sees it first and must refuse it.
      TRAIN_REVERT_MEMBER=1 train_case "train-reverted-$landing-$shape" "$landing" head "" "$shape"
      git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_HEAD:feature.txt" 2>/dev/null \
        && fail "train-reverted-$landing-$shape: the train head still holds the member's file"
      git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_COPY_HEAD:feature.txt" 2>/dev/null \
        || fail "train-reverted-$landing-$shape: the copy lacks the member's file"
      if [ "$shape" = merge ]; then
        git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_COPY_HEAD" "$TRAIN_HEAD" \
          || fail "train-reverted-$landing-$shape: the copy is not an ancestor of the train head"
      else
        git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_COPY_HEAD" "$TRAIN_HEAD" \
          && fail "train-reverted-$landing-$shape: the flattened copy is an ancestor of the train head"
      fi
      assert_train_refused "$TRAIN_CASE" "train-reverted-$landing-$shape" "net change is not present in the train head's final tree"
      assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-reverted-$landing-$shape: the train was accepted"
    done
  done
  TRAIN_REVERT_MEMBER=0
  pass "a train that reverted the member's change before landing is refused in the copy route, by ancestry and by patch replay, squashed or merged"
}

test_train_reverted_member_is_refused_in_the_record_only_route() {
  local landing shape
  for landing in squash merge; do
    for shape in merge flat; do
      TRAIN_REVERT_MEMBER=1 train_absent_case "train-reverted-record-$landing-$shape" "$shape" "$landing"
      assert_train_refused "$TRAIN_CASE" "train-reverted-record-$landing-$shape" "net change is not present in the train head's final tree"
      assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-reverted-record-$landing-$shape: the train was accepted"
      [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] || fail "train-reverted-record-$landing-$shape: refusal closed the backlog"
    done
  done
  TRAIN_REVERT_MEMBER=0
  pass "a train that reverted the member's change before landing is refused in the record-only route too"
}

# A train landed by a merge commit keeps its patch-equivalence proof: its head is
# reachable from the default branch, yet its patches still show what it carried.
test_train_merge_commit_landed_carries_a_prerebase_copy() {
  local shape
  for shape in merge flat; do
    train_case "train-mergecommit-prerebase-$shape" merge prerebase "" "$shape"
    git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_HEAD" origin/main \
      || fail "train-mergecommit-prerebase-$shape: the train head is not reachable from the default branch"
    git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_COPY_HEAD" "$TRAIN_HEAD" \
      && fail "train-mergecommit-prerebase-$shape: the pre-rebase copy is an ancestor of the train head"
    assert_train_allowed "$TRAIN_CASE" "train-mergecommit-prerebase-$shape"
  done
  train_case train-mergecommit-head merge head "" flat
  assert_train_allowed "$TRAIN_CASE" "train-mergecommit-head"
  pass "a pre-rebase copy is carried by a train landed with a merge commit, although the train head is reachable from the default branch"
}

test_train_merge_commit_landed_carries_the_record_only_member() {
  train_absent_case train-mergecommit-record flat merge
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
    || fail "train-mergecommit-record: a carried train was refused: $(cat "$TRAIN_CASE/stderr")"
  assert_grep "$TRAIN_URL" "$TRAIN_CASE/stderr" "train-mergecommit-record: stderr did not name the train PR"
  assert_absent "$TRAIN_CASE/state/task-x1.meta" "train-mergecommit-record: accepted teardown left the task record"
  pass "the record-only route accepts a member whose train was landed with a merge commit"
}

test_train_merge_commit_landed_still_refuses_uncarried_work() {
  train_case train-mergecommit-extra merge extra "" flat
  git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_HEAD" origin/main \
    || fail "train-mergecommit-extra: the train head is not reachable from the default branch"
  assert_train_refused "$TRAIN_CASE" "train-mergecommit-extra" "copy's work is not proven present"
  assert_grep "unmerged follow-up" "$TRAIN_CASE/stderr" "train-mergecommit-extra: refusal did not name the uncarried commit"
  pass "a copy holding a commit the merge-commit-landed train never carried is refused"
}


# An `ours` merge makes a commit K reachable from the default branch without its
# change. The member is built on K and the train `ours`-merges the member head, so
# the member head is an ancestor of the train; neither the train nor the default
# branch ever holds K's file. Reachability, from the default branch or from the
# train, is not delivered content.
test_train_ours_merged_commit_is_never_taken_as_delivered() {
  local landing
  # With a merge-commit landing the copy is also reachable from the default branch, so
  # the default proof sees it first: it must refuse too, and then so must the train route.
  for landing in squash merge; do
    TRAIN_HIDDEN_OURS=1 train_case "train-ours-hidden-$landing" "$landing" head "" ours-flat
    git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_MEMBER_HEAD" "$TRAIN_HEAD" \
      || fail "train-ours-hidden-$landing: the member head is not an ancestor of the train"
    git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_MEMBER_HEAD^^" origin/main \
      || fail "train-ours-hidden-$landing: the hidden commit is not reachable from the default branch"
    git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_COPY_HEAD:hidden.txt" 2>/dev/null \
      || fail "train-ours-hidden-$landing: the copy lacks the hidden change"
    git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_BASE_OID" "$TRAIN_COPY_HEAD" \
      && fail "train-ours-hidden-$landing: the recorded base is an ancestor of the copy"
    git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_HEAD:hidden.txt" 2>/dev/null \
      && fail "train-ours-hidden-$landing: the train holds the hidden change"
    git -C "$TRAIN_CASE/wt" cat-file -e origin/main:hidden.txt 2>/dev/null \
      && fail "train-ours-hidden-$landing: the default branch holds the hidden change"
    assert_train_refused "$TRAIN_CASE" "train-ours-hidden-$landing" "net change is not present in the train head's final tree"
    assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-ours-hidden-$landing: the train was accepted"
  done
  TRAIN_HIDDEN_OURS=0
  pass "a copy built on a commit the default branch only ours-merged is refused though the train contains its head"
}

test_train_ours_merged_commit_is_refused_in_the_record_only_route() {
  local landing
  for landing in squash merge; do
    TRAIN_HIDDEN_OURS=1 train_absent_case "train-ours-hidden-record-$landing" ours-flat "$landing"
    assert_train_refused "$TRAIN_CASE" "train-ours-hidden-record-$landing" "net change is not present in the train head's final tree"
    assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-ours-hidden-record-$landing: the train was accepted"
    [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] || fail "train-ours-hidden-record-$landing: refusal closed the backlog"
  done
  TRAIN_HIDDEN_OURS=0
  pass "the same ours-merged hidden commit is refused in the record-only route, which keeps the backlog row"
}

# The same history is accepted when the train really replays K, so the ours merge
# does not make a genuinely carried member look unlanded.
test_train_ours_merged_commit_is_carried_when_the_train_replays_it() {
  TRAIN_HIDDEN_OURS=1 train_case train-ours-hidden-carried squash head "" flat-hidden
  git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_HEAD:hidden.txt" 2>/dev/null \
    || fail "train-ours-hidden-carried: the train lacks the hidden change"
  assert_train_allowed "$TRAIN_CASE" "train-ours-hidden-carried"
  TRAIN_HIDDEN_OURS=0
  TRAIN_HIDDEN_OURS=1 train_absent_case train-ours-hidden-carried-record flat-hidden squash
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
    || fail "train-ours-hidden-carried-record: a carried train was refused: $(cat "$TRAIN_CASE/stderr")"
  assert_grep "$TRAIN_URL" "$TRAIN_CASE/stderr" "train-ours-hidden-carried-record: stderr did not name the train PR"
  assert_absent "$TRAIN_CASE/state/task-x1.meta" "train-ours-hidden-carried-record: accepted teardown left the task record"
  TRAIN_HIDDEN_OURS=0
  pass "a train that replays the ours-merged commit as well carries the member, in the copy and record-only routes"
}

# train_conflict_merge_into_main <case-dir>: a merge on origin's main that conflicted on
# c.txt (both sides added it) and that a person resolved by hand, then fetched into the
# project and the copy. The merge differs from git's own merge at c.txt alone.
train_conflict_merge_into_main() {
  local case_dir=$1 tmp="$1/_conflict"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name t
  git -C "$tmp" checkout -q -b side
  printf '%s\n' side > "$tmp/c.txt"
  git -C "$tmp" add -- c.txt
  git -C "$tmp" commit -q -m "side adds c"
  git -C "$tmp" checkout -q main
  printf '%s\n' main > "$tmp/c.txt"
  git -C "$tmp" add -- c.txt
  git -C "$tmp" commit -q -m "main adds c"
  git -C "$tmp" merge -q --no-edit side >/dev/null 2>&1 \
    && fail "train_conflict_merge_into_main: the merge did not conflict"
  printf '%s\n' resolved > "$tmp/c.txt"
  git -C "$tmp" add -- c.txt
  git -C "$tmp" commit -q --no-edit
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"
  git -C "$case_dir/project" fetch -q origin
  [ ! -d "$case_dir/wt" ] || git -C "$case_dir/wt" fetch -q origin
}

# The default-reachability proof (content in the default branch) is the same landed-work
# proof the train route sits beside, and it had the same hole: an `ours` merge makes a
# commit reachable from the default branch without its change, so a copy built on that
# commit looked landed. Only the default proof may decide these cases: the forge lists
# no train, and main is not edited after the landing.
default_proof_case() {  # <name> <landing> <copy> <train shape>
  TRAIN_MAIN_EDIT=0 train_case "$1" "$2" "$3" "" "$4"
  printf '[]\n' > "$TRAIN_CASE/gh-fixture/list.json"
}

# assert_default_proof_refused <case-dir> <label>: the copy is not landed, and nothing moved.
assert_default_proof_refused() {
  local case_dir=$1 label=$2 rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$label: teardown must refuse"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "REFUSED" "$case_dir/stderr" "$label: refusal did not say REFUSED"
  assert_absent "$case_dir/treehouse.log" "$label: refused teardown returned the slot"
  assert_present "$case_dir/state/task-x1.meta" "$label: refusal removed the task record"
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the copy"
}

test_default_proof_refuses_a_commit_the_default_branch_only_ours_merged() {
  local landing
  for landing in squash merge; do
    TRAIN_HIDDEN_OURS=1 default_proof_case "default-ours-$landing" "$landing" head ours-flat
    git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_COPY_HEAD:hidden.txt" 2>/dev/null \
      || fail "default-ours-$landing: the copy lacks the hidden change"
    git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_BASE_OID" "$TRAIN_COPY_HEAD" \
      && fail "default-ours-$landing: the recorded base is an ancestor of the copy"
    git -C "$TRAIN_CASE/wt" cat-file -e origin/main:hidden.txt 2>/dev/null \
      && fail "default-ours-$landing: the default branch holds the hidden change"
    git -C "$TRAIN_CASE/wt" cat-file -e origin/main:feature.txt 2>/dev/null \
      || fail "default-ours-$landing: the default branch lacks the member's own change"
    assert_default_proof_refused "$TRAIN_CASE" "default-ours-$landing"
    assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "default-ours-$landing: the train was accepted"
  done
  TRAIN_HIDDEN_OURS=0
  pass "a copy built on a commit the default branch only ours-merged is refused by the content-in-default proof"
}

# The removed copy's branch is read from the project: the same proof, another route.
test_default_proof_refuses_an_ours_merged_commit_for_a_removed_copy() {
  local landing case_dir rc
  for landing in squash merge; do
    make_nested_slot_case "default-ours-nested-$landing" enclosing .claude/worktrees/bundled
    case_dir=$NESTED_CASE
    ln -s "$NESTED_COPY" "$case_dir/wt"
    TRAIN_HIDDEN_OURS=1 TRAIN_MAIN_EDIT=0 setup_train_history "$case_dir" "$landing" head ours-flat
    rm "$case_dir/wt"
    git -C "$case_dir/project" worktree remove --force "$NESTED_COPY"
    assert_absent "$NESTED_COPY" "default-ours-nested-$landing: setup did not remove the nested copy"
    [ "$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1-v2)" = "$TRAIN_MEMBER_HEAD" ] \
      || fail "default-ours-nested-$landing: the removed copy's branch is not at the member head"
    printf '%s\n' "pr=$TRAIN_MEMBER_URL" >> "$case_dir/state/task-x1.meta"
    add_gh_train_fake "$case_dir" CLOSED "$TRAIN_MEMBER_HEAD"
    add_logging_treehouse "$case_dir"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "default-ours-nested-$landing: teardown must refuse"$'\n'"$(cat "$case_dir/stderr")"
    assert_present "$case_dir/state/task-x1.meta" "default-ours-nested-$landing: refusal removed the record"
    assert_absent "$case_dir/treehouse.log" "default-ours-nested-$landing: refusal returned the slot"
  done
  TRAIN_HIDDEN_OURS=0
  pass "a removed copy's branch built on an ours-merged commit is refused by the content-in-default proof"
}

# A local-only task is landed when its branch is reachable from local main. An `ours`
# merge makes it reachable with none of its change.
test_default_proof_refuses_a_local_only_branch_that_main_only_ours_merged() {
  local case_dir rc=0 head
  case_dir=$(make_case local-only-ours)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" hidden.txt unlanded "work that never lands"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t merge -q -s ours --no-edit "$head" >/dev/null
  git -C "$case_dir/project" merge-base --is-ancestor "$head" refs/heads/main \
    || fail "local-only-ours: the commit is not reachable from local main"
  git -C "$case_dir/project" cat-file -e refs/heads/main:hidden.txt 2>/dev/null \
    && fail "local-only-ours: local main holds the hidden change"
  seed_backlog_in_flight "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "local-only-ours: teardown must refuse"$'\n'"$(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.meta" "local-only-ours: refusal removed the task record"
  [ -d "$case_dir/wt" ] || fail "local-only-ours: refusal removed the copy"
  pass "a local-only branch that local main only ours-merged is refused"
}

# A train that reverted the member, then merged by a merge commit, is reachable and yet
# does not hold the change: the old reachability proof accepted it.
test_default_proof_refuses_a_reverted_member_landed_by_a_merge_commit() {
  TRAIN_REVERT_MEMBER=1 default_proof_case default-reverted-merge merge head merge
  git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_COPY_HEAD" origin/main \
    || fail "default-reverted-merge: the copy is not reachable from the default branch"
  git -C "$TRAIN_CASE/wt" cat-file -e origin/main:feature.txt 2>/dev/null \
    && fail "default-reverted-merge: the default branch holds the reverted file"
  assert_default_proof_refused "$TRAIN_CASE" "default-reverted-merge"
  pass "a copy reachable only through a merge that reverted its change is refused by the content-in-default proof"
}

# Every genuine landing the proof accepted before is still accepted.
test_default_proof_still_accepts_genuine_landings() {
  local row rc
  for row in merge-commit-then-main-edit squash-carrying-hidden fast-forward net-empty resolved-conflict-merge-after; do
    case "$row" in
      resolved-conflict-merge-after)
        # A merge whose conflict a person resolved by hand lies after the copy's base.
        # It differs from git's own merge at the conflicted path, which is the
        # author's to resolve, so it does not make the base untrusted.
        TRAIN_MAIN_EDIT=1 TRAIN_MAIN_EDIT_FILE=second.txt train_case "default-ok-$row" merge head "" merge
        printf '[]\n' > "$TRAIN_CASE/gh-fixture/list.json"
        train_conflict_merge_into_main "$TRAIN_CASE"
        git -C "$TRAIN_CASE/wt" cat-file -e origin/main:c.txt 2>/dev/null \
          || fail "default-ok-$row: the default branch lacks the resolved file" ;;
      merge-commit-then-main-edit)
        # The member's own merge commit holds its change; main edits another file later.
        TRAIN_MAIN_EDIT=1 TRAIN_MAIN_EDIT_FILE=second.txt train_case "default-ok-$row" merge head "" merge
        printf '[]\n' > "$TRAIN_CASE/gh-fixture/list.json" ;;
      squash-carrying-hidden)
        # The default branch really took the ours-merged commit's change in as well.
        TRAIN_HIDDEN_OURS=1 default_proof_case "default-ok-$row" squash head flat-hidden
        git -C "$TRAIN_CASE/wt" cat-file -e origin/main:hidden.txt 2>/dev/null \
          || fail "default-ok-$row: the default branch lacks the carried change" ;;
      fast-forward)
        default_proof_case "default-ok-$row" none head merge
        git -C "$TRAIN_CASE/origin.git" update-ref refs/heads/main "$TRAIN_COPY_HEAD"
        git -C "$TRAIN_CASE/wt" fetch -q origin
        [ "$(git -C "$TRAIN_CASE/wt" rev-parse origin/main)" = "$TRAIN_COPY_HEAD" ] \
          || fail "default-ok-$row: origin/main is not at the copy's head" ;;
      net-empty)
        # A commit and its own revert leave the copy's tree equal to its base.
        default_proof_case "default-ok-$row" squash head merge
        git -C "$TRAIN_CASE/wt" reset -q --hard origin/main
        wt_commit_file "$TRAIN_CASE" scratch.txt x "scratch"
        git -C "$TRAIN_CASE/wt" -c user.email=t@t -c user.name=t revert --no-edit HEAD >/dev/null ;;
    esac
    rc=0
    run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" || rc=$?
    expect_code 0 "$rc" "default-ok-$row: a genuinely landed copy must be accepted"$'\n'"$(cat "$TRAIN_CASE/stderr")"
    assert_absent "$TRAIN_CASE/state/task-x1.meta" "default-ok-$row: accepted teardown left the task record"
    assert_grep "return" "$TRAIN_CASE/treehouse.log" "default-ok-$row: the slot was not returned"
  done
  TRAIN_HIDDEN_OURS=0
  pass "the content-in-default proof still accepts a merge-commit landing, a carried hidden commit, a fast-forward, a net-empty copy and a landing beside a hand-resolved merge"
}

# The forge names the commit that landed a MERGED train. That commit must be on the
# default branch's first-parent line and must hold the member's net change: a train
# can be recorded merged by a merge that took none of its content in.
test_train_landing_commit_without_the_change_is_refused() {
  local shape rc
  # Copy route: a train merged by an `ours` merge makes its head, and a member head
  # inside it, reachable from the default branch. The default-reachability proof sees
  # that copy first and must refuse it, and then the train route must too.
  for shape in flat merge; do
    train_case "train-landing-ours-$shape" ours head "" "$shape"
    git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_LANDING_COMMIT:feature2.txt" 2>/dev/null \
      && fail "train-landing-ours-$shape: the landing commit holds the member's file"
    git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_HEAD:feature2.txt" 2>/dev/null \
      || fail "train-landing-ours-$shape: the train head lacks the member's file"
    run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" && rc=0 || rc=$?
    expect_code 1 "$rc" "train-landing-ours-$shape: teardown must refuse"$'\n'"$(cat "$TRAIN_CASE/stderr")"
    assert_grep "landing commit" "$TRAIN_CASE/stderr" "train-landing-ours-$shape: refusal did not name the landing commit"
    assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-landing-ours-$shape: the train was accepted"
    assert_absent "$TRAIN_CASE/treehouse.log" "train-landing-ours-$shape: refused teardown returned the slot"
    assert_present "$TRAIN_CASE/state/task-x1.meta" "train-landing-ours-$shape: refusal removed the task record"
  done
  for shape in flat merge; do
    train_absent_case "train-landing-ours-record-$shape" "$shape" ours
    assert_train_refused "$TRAIN_CASE" "train-landing-ours-record-$shape" "landing commit"
    assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-landing-ours-record-$shape: the train was accepted"
    [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] || fail "train-landing-ours-record-$shape: refusal closed the backlog"
  done
  pass "a merged train whose landing commit holds none of the member's change is refused in the copy and record-only routes"
}

test_train_landing_commit_off_the_default_line_is_refused() {
  train_absent_case train-landing-offline flat squash
  TRAIN_LANDING_COMMIT=$TRAIN_HEAD train_default_list "$TRAIN_CASE"
  assert_train_refused "$TRAIN_CASE" "train-landing-offline" "is not on the first-parent line of the default branch"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-landing-offline: the train was accepted"
  pass "a landing commit that is not on the default branch's first-parent line is refused"
}

test_train_landing_commit_unreadable_is_unknown_not_unlanded() {
  local row id
  for row in missing absent-object; do
    train_absent_case "train-landing-$row" flat squash
    case "$row" in
      missing) id= ;;
      absent-object) id=dddddddddddddddddddddddddddddddddddddddd ;;
    esac
    TRAIN_LANDING_COMMIT=$id train_default_list "$TRAIN_CASE"
    assert_train_refused "$TRAIN_CASE" "train-landing-$row" "landing commit" unknown
  done
  pass "a landing commit the forge did not give, or this clone lacks, is unknown (retry), never unlanded"
}

test_train_member_closed_landed_by_merged_train_allows() {
  train_case train-merge-landed squash head
  seed_backlog_in_flight "$TRAIN_CASE"
  : > "$TRAIN_CASE/config/fleet-ledger"
  assert_train_allowed "$TRAIN_CASE" "train-merge-landed"
  [ "$(backlog_row_state "$TRAIN_CASE")" = "done" ] || fail "train-merge-landed: backlog item stayed open"
  assert_train_backlog_close "$TRAIN_CASE" train-merge-landed
  pass "a CLOSED member whose merged train lists its head and contains it is accepted, naming the train on stderr and on the backlog close"
}

test_train_member_prerebase_copy_allows() {
  train_case train-prerebase squash prerebase
  [ "$TRAIN_COPY_HEAD" != "$TRAIN_MEMBER_HEAD" ] || fail "train-prerebase: the copy is not a pre-rebase head"
  assert_train_allowed "$TRAIN_CASE" "train-prerebase"
  pass "a pre-rebase copy whose patches the train head carries is accepted by the patch proof"
}

test_train_member_squash_landed_allows() {
  train_case train-squash squash head
  git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_HEAD" origin/main \
    && fail "train-squash: the train head is an ancestor of the default branch"
  assert_train_allowed "$TRAIN_CASE" "train-squash"
  pass "a train landed by squash is accepted"
}

test_train_member_copy_inside_train_allows() {
  train_case train-inside squash inside
  [ "$TRAIN_COPY_HEAD" != "$TRAIN_MEMBER_HEAD" ] || fail "train-inside: the copy is at the listed head"
  git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_MEMBER_HEAD" "$TRAIN_COPY_HEAD" \
    || fail "train-inside: the copy is not later than the listed head"
  assert_train_allowed "$TRAIN_CASE" "train-inside"
  pass "a copy later than the listed head but inside the verified train is accepted"
}

test_train_refuses_when_no_merged_pr_lists_the_member() {
  local row body
  for row in empty other-member prefix-of-another-number no-sha; do
    train_case "train-nolist-$row" squash head
    case "$row" in
      empty) printf '[]\n' > "$TRAIN_CASE/gh-fixture/list.json" ;;
      other-member)
        body=$(train_body https://github.com/example/repo/pull/8 "$TRAIN_MEMBER_HEAD")
        train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$body" ;;
      prefix-of-another-number)
        body=$(train_body https://github.com/example/repo/pull/70 "$TRAIN_MEMBER_HEAD")
        train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$body" ;;
      no-sha)
        body=$(printf 'Merge train\n\n- %s\n- %s at short1234\n' "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_URL")
        train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$body" ;;
    esac
    assert_train_refused "$TRAIN_CASE" "train-nolist-$row" "no PR found by the forge lists it"
    assert_grep "ship deliverable is not landed" "$TRAIN_CASE/stderr" "train-nolist-$row: refusal lost the existing text"
  done
  pass "a closed member no merged PR lists at a 40-hex sha is refused (no list, other member, number prefix, no sha)"
}

test_train_refuses_a_listing_that_is_not_the_members_head() {
  local other=dddddddddddddddddddddddddddddddddddddddd
  train_case train-wrong-sha squash head
  train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "$other")"
  assert_train_refused "$TRAIN_CASE" "train-wrong-sha" "not the member PR's recorded head"

  # The member moved on after the train was built: the listed sha is no longer its head.
  train_case train-moved-member squash head
  printf '%s\n' "$other" > "$TRAIN_CASE/gh-fixture/member-head"
  assert_train_refused "$TRAIN_CASE" "train-moved-member" "not the member PR's recorded head"

  # The listed sha is the member's head, but the train head does not contain it.
  train_case train-not-contained squash head
  git -C "$TRAIN_CASE/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "member moved on"
  printf '%s\n' "$(git -C "$TRAIN_CASE/wt" rev-parse HEAD)" > "$TRAIN_CASE/gh-fixture/member-head"
  train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" \
    "$(train_body "$TRAIN_MEMBER_URL" "$(git -C "$TRAIN_CASE/wt" rev-parse HEAD)")"
  assert_train_refused "$TRAIN_CASE" "train-not-contained" "neither contains it nor carries every commit of it"
  pass "a train listing another sha, or a sha its head does not contain, is refused"
}

test_train_refuses_copy_work_the_train_does_not_carry() {
  train_case train-extra squash extra
  assert_train_refused "$TRAIN_CASE" "train-extra" "whose change is not proven present in the merged PR head"
  assert_grep "unmerged follow-up" "$TRAIN_CASE/stderr" "train-extra: refusal did not name the unmerged commit"
  assert_grep "copy's work is not proven present" "$TRAIN_CASE/stderr" "train-extra: refusal did not name the train fact"
  pass "a copy holding a commit the train head never carried is refused with the commit named"
}

test_train_dirty_copy_refuses_before_the_train_is_read() {
  train_case train-dirty squash head
  printf '%s\n' scratch > "$TRAIN_CASE/wt/scratch.txt"
  assert_train_refused "$TRAIN_CASE" "train-dirty" "has uncommitted changes"
  assert_absent "$TRAIN_CASE/gh-fixture/calls.log" "train-dirty: the forge was read for a dirty copy"
  pass "a dirty copy refuses before any forge read, even when its train is verified"
}

test_train_refuses_a_train_that_is_not_merged() {
  local state
  for state in OPEN CLOSED; do
    train_case "train-$state" squash head
    train_list "$TRAIN_CASE" 9 "$state" main "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_HEAD")"
    assert_train_refused "$TRAIN_CASE" "train-$state" "is $state, not merged"
  done
  pass "an open or closed-unmerged train is refused"
}

test_train_refuses_a_train_merged_into_another_branch() {
  train_case train-other-base squash head
  train_list "$TRAIN_CASE" 9 MERGED develop "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_HEAD")"
  assert_train_refused "$TRAIN_CASE" "train-other-base" "merged into develop, not this task's base main"

  # A task that records its own base_branch is judged against that branch.
  train_case train-recorded-base squash head release
  assert_train_refused "$TRAIN_CASE" "train-recorded-base-refuse" "merged into main, not this task's base release"
  train_case train-recorded-base-ok squash head release
  git -C "$TRAIN_CASE/origin.git" branch release main
  git -C "$TRAIN_CASE/wt" fetch -q origin
  train_list "$TRAIN_CASE" 9 MERGED release "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_HEAD")"
  assert_train_allowed "$TRAIN_CASE" "train-recorded-base-ok"
  pass "the train must be merged into the task's base: the default branch, or its recorded base_branch"
}

test_train_unreadable_forge_is_unknown_never_accepted() {
  # The search fails.
  train_case train-search-fails squash head
  : > "$TRAIN_CASE/gh-fixture/list.fail"
  assert_train_refused "$TRAIN_CASE" "train-search-fails" "the forge search for PRs listing" unknown

  # The search answers with something that is not a list.
  train_case train-search-garbled squash head
  printf 'not json\n' > "$TRAIN_CASE/gh-fixture/list.json"
  assert_train_refused "$TRAIN_CASE" "train-search-garbled" "returned nothing readable" unknown

  # The train head cannot be fetched.
  TRAIN_PREFETCH_TRAIN=0 train_case train-fetch-fails squash head
  git -C "$TRAIN_CASE/origin.git" update-ref -d refs/pull/9/head
  git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_HEAD^{commit}" 2>/dev/null \
    && fail "train-fetch-fails: the train head was already in the copy"
  assert_train_refused "$TRAIN_CASE" "train-fetch-fails" "could not be fetched" unknown
  pass "a failed forge search or fetch of the train is unknown, retry, never accepted and never 'not landed'"
}

test_train_control_open_member_is_not_landed_by_a_train() {
  train_case train-open-member squash head
  printf 'OPEN\n' > "$TRAIN_CASE/gh-fixture/member-state"
  assert_train_refused "$TRAIN_CASE" "train-open-member" "ship deliverable is not landed"
  assert_no_grep "pr list" "$TRAIN_CASE/gh-fixture/calls.log" "train-open-member: the train was searched for an open PR"
  pass "a train that lists an OPEN member does not make it landed"
}

test_train_control_merged_member_keeps_the_existing_route() {
  train_case train-merged-member squash head
  printf 'MERGED\n' > "$TRAIN_CASE/gh-fixture/member-state"
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
    || fail "train-merged-member: a merged member was refused: $(cat "$TRAIN_CASE/stderr")"
  assert_no_grep "pr list" "$TRAIN_CASE/gh-fixture/calls.log" "train-merged-member: the train route ran for a merged member"
  assert_no_grep "merged train" "$TRAIN_CASE/stderr" "train-merged-member: the train was named for a merged member"
  pass "a MERGED member is decided by the existing route, with no train read"
}

test_train_control_content_proof_still_accepts_a_closed_member() {
  local mode case_dir
  for mode in no-train forge-down; do
    case_dir=$(make_case "train-content-$mode")
    write_meta "$case_dir" no-mistakes ship
    append_pr_meta_url "$case_dir"
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    land_on_origin_main "$case_dir" feature.txt hello
    train_anchor_root "$case_dir"
    add_gh_train_fake "$case_dir" CLOSED "$(git -C "$case_dir/wt" rev-parse HEAD)"
    [ "$mode" != forge-down ] || : > "$case_dir/gh-fixture/list.fail"
    add_logging_treehouse "$case_dir"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "train-content-$mode: the content proof no longer accepts: $(cat "$case_dir/stderr")"
    assert_grep return "$case_dir/treehouse.log" "train-content-$mode: the slot was not returned"
    assert_no_grep "pr list" "$case_dir/gh-fixture/calls.log" "train-content-$mode: the train was searched although the content proof held"
  done
  pass "a CLOSED member whose clean content is already in the default branch is still accepted by the content proof"
}

# The forge records a PR's base as the base branch's tip, which can be ahead of the commit the
# branch forked from. The copy's change is then measured from its fork point, and the work that
# a squash landed is accepted by the content proof.
test_default_proof_accepts_a_closed_member_whose_recorded_base_is_ahead_of_its_fork_point() {
  local case_dir head
  case_dir=$(make_case default-base-ahead)
  write_meta "$case_dir" no-mistakes ship
  append_pr_meta_url "$case_dir"
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  land_on_origin_main "$case_dir" ahead.txt ahead
  TRAIN_BASE_OID=$(git -C "$case_dir/origin.git" rev-parse main)
  land_on_origin_main "$case_dir" feature.txt hello
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" merge-base --is-ancestor "$TRAIN_BASE_OID" "$head" \
    && fail "default-base-ahead: the recorded base is an ancestor of the copy"
  add_gh_train_fake "$case_dir" CLOSED "$head"
  add_logging_treehouse "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "default-base-ahead: landed work measured from a base ahead of its fork point was refused: $(cat "$case_dir/stderr")"
  assert_grep return "$case_dir/treehouse.log" "default-base-ahead: the slot was not returned"
  assert_no_grep "pr list" "$case_dir/gh-fixture/calls.log" "default-base-ahead: the train was searched although the content proof held"
  pass "a CLOSED member whose recorded base is ahead of its fork point and whose work a squash landed is accepted by the content proof"
}

# The same base on the train route: the member head, a copy at it, and the record-only route are
# measured from the fork point, against the train head and the squash landing.
test_train_member_whose_recorded_base_is_ahead_of_its_fork_point_allows() {
  TRAIN_BASE_AHEAD=1 train_case train-base-ahead squash head
  git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_BASE_OID" "$TRAIN_MEMBER_HEAD" \
    && fail "train-base-ahead: the recorded base is an ancestor of the member head"
  assert_train_allowed "$TRAIN_CASE" train-base-ahead
  TRAIN_BASE_AHEAD=1 train_absent_case train-base-ahead-record merge squash
  TRAIN_BASE_AHEAD=0
  git -C "$TRAIN_CASE/origin.git" merge-base --is-ancestor "$TRAIN_BASE_OID" "$TRAIN_MEMBER_HEAD" \
    && fail "train-base-ahead-record: the recorded base is an ancestor of the member head"
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
    || fail "train-base-ahead-record: a carried member measured from a base ahead of its fork point was refused: $(cat "$TRAIN_CASE/stderr")"
  assert_grep "$TRAIN_URL" "$TRAIN_CASE/stderr" "train-base-ahead-record: stderr did not name the train PR"
  assert_absent "$TRAIN_CASE/state/task-x1.meta" "train-base-ahead-record: accepted teardown left the task record"
  pass "a train member whose recorded base is ahead of its fork point is accepted when the train carried it, in the copy and record-only routes"
}

# The same base never accepts unlanded work: a copy with a commit the train never carried, and a
# member whose file the train reverted (so the change from the fork point is not in the train
# head's tree), stay refused.
test_train_member_whose_recorded_base_is_ahead_still_refuses_unlanded_work() {
  TRAIN_BASE_AHEAD=1 train_case train-base-ahead-extra squash extra
  git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_BASE_OID" "$TRAIN_COPY_HEAD" \
    && fail "train-base-ahead-extra: the recorded base is an ancestor of the copy"
  assert_train_refused "$TRAIN_CASE" train-base-ahead-extra "copy's work is not proven present"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-base-ahead-extra: the train was accepted"
  TRAIN_BASE_AHEAD=1 TRAIN_REVERT_MEMBER=1 train_case train-base-ahead-reverted squash head
  TRAIN_BASE_AHEAD=0
  TRAIN_REVERT_MEMBER=0
  git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_BASE_OID" "$TRAIN_COPY_HEAD" \
    && fail "train-base-ahead-reverted: the recorded base is an ancestor of the copy"
  assert_train_refused "$TRAIN_CASE" train-base-ahead-reverted "net change is not present in the train head's final tree"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-base-ahead-reverted: the train was accepted"
  pass "a recorded base ahead of the fork point never accepts a commit the train did not carry or a change the train reverted"
}

# The record-only route reads the project clone, which nothing else brings up to date: a
# clone whose origin/main is older than the train squash is fetched before the landing commit
# is placed, and a fetch that fails is unknown, never unlanded.
test_train_record_only_route_fetches_a_stale_default_branch() {
  local row
  for row in stale unreachable; do
    train_absent_case "train-absent-stale-$row"
    git -C "$TRAIN_CASE/project" update-ref refs/remotes/origin/main "$TRAIN_BASE_OID"
    git -C "$TRAIN_CASE/project" merge-base --is-ancestor "$TRAIN_LANDING_COMMIT" origin/main \
      && fail "train-absent-stale-$row: the clone's origin/main already holds the train squash"
    if [ "$row" = stale ]; then
      run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
        || fail "train-absent-stale-$row: a verified train was refused on a clone that was not fetched first: $(cat "$TRAIN_CASE/stderr")"
      assert_grep "$TRAIN_URL" "$TRAIN_CASE/stderr" "train-absent-stale-$row: stderr did not name the train PR"
      assert_absent "$TRAIN_CASE/state/task-x1.meta" "train-absent-stale-$row: accepted teardown left the task record"
    else
      git -C "$TRAIN_CASE/project" remote set-url origin "$TRAIN_CASE/no-such-origin.git"
      assert_train_refused "$TRAIN_CASE" "train-absent-stale-$row" "origin/main could not be fetched" unknown
      [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] || fail "train-absent-stale-$row: refusal closed the backlog"
    fi
  done
  pass "the record-only route fetches a stale default branch before it places the train's landing commit, and a failed fetch is unknown"
}

test_train_other_refusals_stay() {
  local case_dir rc
  # A closed member with no train and unlanded work keeps the existing refusal and text.
  case_dir=$(make_case train-unlanded)
  write_meta "$case_dir" no-mistakes ship
  append_pr_meta_url "$case_dir"
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  train_anchor_root "$case_dir"
  add_gh_train_fake "$case_dir" CLOSED "$(git -C "$case_dir/wt" rev-parse HEAD)"
  add_logging_treehouse "$case_dir"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "train-unlanded: unlanded work must refuse"
  assert_grep "REFUSED: the ship deliverable is not landed" "$case_dir/stderr" "train-unlanded: refusal text changed"
  assert_absent "$case_dir/treehouse.log" "train-unlanded: refused teardown returned the slot"
  pass "a closed member with no train and unlanded work keeps the existing refusal"
}

# The record-only route (the copy is gone) applies the same verified-train rule and
# reads no copy: the recorded PR is CLOSED, so only the forge's train proof counts.
train_absent_case() {  # <name> [<train shape>] [<landing>]
  train_case "$1" "${3:-squash}" head "" "${2:-merge}"
  write_windowless_legacy_meta "$TRAIN_CASE" no-mistakes ship "$TRAIN_CASE/missing-wt"
  append_pr_meta_url "$TRAIN_CASE"
  seed_backlog_in_flight "$TRAIN_CASE"
}

test_train_record_only_route_without_a_copy() {
  local row other=dddddddddddddddddddddddddddddddddddddddd
  train_absent_case train-absent-ok
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
    || fail "train-absent-ok: a verified train was refused for a removed copy: $(cat "$TRAIN_CASE/stderr")"
  assert_grep "$TRAIN_URL" "$TRAIN_CASE/stderr" "train-absent-ok: stderr did not name the train PR"
  assert_grep "$TRAIN_MEMBER_HEAD" "$TRAIN_CASE/stderr" "train-absent-ok: stderr did not name the listed sha"
  assert_absent "$TRAIN_CASE/state/task-x1.meta" "train-absent-ok: accepted teardown left the task record"
  [ "$(backlog_row_state "$TRAIN_CASE")" = "done" ] || fail "train-absent-ok: backlog item stayed open"
  assert_train_backlog_close "$TRAIN_CASE" train-absent-ok

  for row in empty other-member wrong-sha prefix-sha missing-sha open-train other-base search-fails fetch-fails; do
    case "$row" in
      fetch-fails) TRAIN_PREFETCH_TRAIN=0 train_absent_case "train-absent-$row" ;;
      *) train_absent_case "train-absent-$row" ;;
    esac
    case "$row" in
      empty)
        printf '[]\n' > "$TRAIN_CASE/gh-fixture/list.json"
        assert_train_refused "$TRAIN_CASE" "train-absent-$row" "no PR found by the forge lists it" ;;
      other-member)
        train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(train_body https://github.com/example/repo/pull/8 "$TRAIN_MEMBER_HEAD")"
        assert_train_refused "$TRAIN_CASE" "train-absent-$row" "no PR found by the forge lists it" ;;
      wrong-sha)
        train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "$other")"
        assert_train_refused "$TRAIN_CASE" "train-absent-$row" "not the member PR's recorded head" ;;
      prefix-sha)
        train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "${TRAIN_MEMBER_HEAD:0:12}")"
        assert_train_refused "$TRAIN_CASE" "train-absent-$row" "no PR found by the forge lists it" ;;
      missing-sha)
        train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "Merge train"$'\n\n'"- $TRAIN_MEMBER_URL"
        assert_train_refused "$TRAIN_CASE" "train-absent-$row" "no PR found by the forge lists it" ;;
      open-train)
        train_list "$TRAIN_CASE" 9 OPEN main "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_HEAD")"
        assert_train_refused "$TRAIN_CASE" "train-absent-$row" "is OPEN, not merged" ;;
      other-base)
        train_list "$TRAIN_CASE" 9 MERGED develop "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_HEAD")"
        assert_train_refused "$TRAIN_CASE" "train-absent-$row" "merged into develop, not this task's base main" ;;
      search-fails)
        : > "$TRAIN_CASE/gh-fixture/list.fail"
        assert_train_refused "$TRAIN_CASE" "train-absent-$row" "the forge search for PRs listing" unknown ;;
      fetch-fails)
        git -C "$TRAIN_CASE/origin.git" update-ref -d refs/pull/9/head
        assert_train_refused "$TRAIN_CASE" "train-absent-$row" "could not be fetched" unknown ;;
    esac
    [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] || fail "train-absent-$row: refusal closed the backlog"
  done
  pass "a removed copy is accepted only on a verified merged train, and every unverified or unread train refuses"
}

# The removed-copy route in a pool slot (teardown_nested_slot landed) judges the
# task's branch ref through the same landed-work rule, so it accepts the same
# verified train and refuses the same unverified ones.
test_train_member_removed_copy_in_pool_slot() {
  local row case_dir rc
  for row in verified wrong-sha; do
    make_nested_slot_case "train-nested-$row" enclosing .claude/worktrees/bundled
    case_dir=$NESTED_CASE
    ln -s "$NESTED_COPY" "$case_dir/wt"
    setup_train_history "$case_dir" squash head
    rm "$case_dir/wt"
    git -C "$case_dir/project" worktree remove --force "$NESTED_COPY"
    assert_absent "$NESTED_COPY" "train-nested-$row: setup did not remove the nested copy"
    printf '%s\n' "pr=$TRAIN_MEMBER_URL" >> "$case_dir/state/task-x1.meta"
    add_gh_train_fake "$case_dir" CLOSED "$TRAIN_MEMBER_HEAD"
    train_default_list "$case_dir"
    if [ "$row" = wrong-sha ]; then
      train_list "$case_dir" 9 MERGED main "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" dddddddddddddddddddddddddddddddddddddddd)"
    fi
    add_logging_treehouse "$case_dir"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$row" = verified ]; then
      expect_code 0 "$rc" "train-nested-$row: a verified train must finish: $(cat "$case_dir/stderr")"
      assert_grep "$TRAIN_URL" "$case_dir/stderr" "train-nested-$row: stderr did not name the train PR"
      assert_absent "$case_dir/state/task-x1.meta" "train-nested-$row: task was not retired"
    else
      expect_code 1 "$rc" "train-nested-$row: an unverified train must refuse: $(cat "$case_dir/stderr")"
      assert_present "$case_dir/state/task-x1.meta" "train-nested-$row: refusal removed the record"
      assert_absent "$case_dir/treehouse.log" "train-nested-$row: refusal returned the slot"
    fi
  done
  pass "a removed copy's branch in a pool slot is landed by a verified train only"
}

# A train the pipeline rebased flat (Vernant's squash-only history) does not contain
# the member head: it replays the member's commits as new commits. The listed head
# is then carried when every one of its commits has an equivalent patch in the train.
test_train_flattened_rebase_carries_the_listed_head() {
  local copy
  for copy in head prerebase; do
    train_case "train-flat-$copy" squash "$copy" "" flat
    if git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_MEMBER_HEAD" "$TRAIN_HEAD"; then
      fail "train-flat-$copy: the flat train contains the member head"
    fi
    assert_train_allowed "$TRAIN_CASE" "train-flat-$copy"
  done
  pass "a flattened-rebase train that replays every member commit is accepted although it does not contain the member head"
}

test_train_flattened_rebase_missing_a_member_commit_refuses() {
  train_case train-flat-missing squash head "" flat-missing
  assert_train_refused "$TRAIN_CASE" "train-flat-missing" "neither contains it nor carries every commit of it"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-flat-missing: the train was accepted"
  pass "a flattened train missing one commit of the member head is refused"
}

# A remote-tracking ref left at the member head's parent must not hide that parent
# from the proof: the flat train dropped it, so neither the member head nor the
# copy is carried, in work mode or record mode.
test_train_flat_missing_with_a_stale_remote_ref_refuses() {
  train_case train-flat-stale squash head "" flat-missing
  git -C "$TRAIN_CASE/wt" update-ref refs/remotes/origin/fm/task-x1 "$TRAIN_MEMBER_HEAD~1"
  assert_train_refused "$TRAIN_CASE" "train-flat-stale" "neither contains it nor carries every commit of it"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-flat-stale: the train was accepted"

  train_absent_case train-absent-flat-stale flat-missing
  git -C "$TRAIN_CASE/project" fetch -q origin refs/pull/7/head
  git -C "$TRAIN_CASE/project" update-ref refs/remotes/origin/fm/task-x1 "$TRAIN_MEMBER_HEAD~1"
  assert_train_refused "$TRAIN_CASE" "train-absent-flat-stale" "neither contains it nor carries every commit of it"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-absent-flat-stale: the train was accepted"
  [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] || fail "train-absent-flat-stale: refusal closed the backlog"
  pass "a flat train missing a member commit refuses even when a stale remote-tracking ref holds that commit"
}

# The train route reads the member again after pr_is_merged saw it CLOSED; a re-read
# that fails is unknown, retry, never 'not landed' and never accepted.
test_train_member_reread_failure_is_unknown() {
  local events
  train_case train-reread-fails squash head
  : > "$TRAIN_CASE/gh-fixture/member-view.once"
  events="$TRAIN_CASE/guard-events.jsonl"
  FM_GUARD_EVENT_LOG="$events" assert_train_refused "$TRAIN_CASE" "train-reread-fails" "could not be read again" unknown
  assert_grep "REFUSED: not known whether the ship deliverable is landed" "$TRAIN_CASE/stderr" \
    "train-reread-fails: the refusal did not say the landing is unknown"
  assert_no_grep "pr list" "$TRAIN_CASE/gh-fixture/calls.log" "train-reread-fails: the train was searched after the member read failed"
  assert_equals "deny:false" \
    "$(jq -rs '[.[] | select(.guard == "teardown-unlanded") | "\(.decision):\(.source_ok)"] | join(" ")' "$events")" \
    "train-reread-fails: an unread train proof was logged as a readable source"

  # An answered refusal (no train lists the member) still logs a readable source.
  train_case train-answered-guard squash head
  printf '[]\n' > "$TRAIN_CASE/gh-fixture/list.json"
  events="$TRAIN_CASE/guard-events.jsonl"
  FM_GUARD_EVENT_LOG="$events" assert_train_refused "$TRAIN_CASE" "train-answered-guard" "ship deliverable is not landed"
  assert_equals "deny:true" \
    "$(jq -rs '[.[] | select(.guard == "teardown-unlanded") | "\(.decision):\(.source_ok)"] | join(" ")' "$events")" \
    "train-answered-guard: an answered refusal was logged as an unread source"
  pass "a failed re-read of the CLOSED member is unknown, retry, and its guard event says the source was not readable"
}

# With no recorded pr=, pr_is_merged finds the member PR by its branch and sees it
# CLOSED; the train route uses that same PR and does not look the branch up again,
# so a later branch lookup that fails cannot turn the proof into 'not landed'.
test_train_member_found_by_branch_is_not_looked_up_again() {
  local case_dir
  case_dir=$(make_case train-branch-lookup-once)
  write_meta "$case_dir" no-mistakes ship
  setup_train_history "$case_dir" squash head
  add_gh_train_fake "$case_dir" CLOSED "$TRAIN_MEMBER_HEAD"
  train_default_list "$case_dir"
  add_logging_treehouse "$case_dir"
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$case_dir/gh-axi.log'
case "\${1:-} \${2:-}" in
  "pr list")
    [ ! -e '$case_dir/gh-axi.seen' ] || { echo "error: forge unavailable" >&2 ; exit 1 ; }
    : > '$case_dir/gh-axi.seen'
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,title,state}:" "  7,train member,closed" ; exit 0 ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  assert_train_allowed "$case_dir" train-branch-lookup-once
  pass "a member PR found by its branch is used by the train route without a second branch lookup"
}

# train_pipeline_input_case <name>: the live d1 B5 r4 shape. The copy is the input
# of a run that rewrote it and pushed the member head, so no patch of "add a" is in
# the train, the member is CLOSED, and a merged train lists that pushed head.
# train_anchor_root <case-dir>: the member PR's recorded base for an ad hoc fixture is the root
# commit of the case's origin, so the member's whole history is its change.
train_anchor_root() {
  TRAIN_BASE_OID=$(git -C "$1/origin.git" rev-list --max-parents=0 main | head -1)
}

train_pipeline_input_case() {
  local tmp
  TRAIN_CASE=$(make_case "$1")
  write_meta "$TRAIN_CASE" no-mistakes ship
  append_pr_meta_url "$TRAIN_CASE"
  TRAIN_MEMBER_HEAD=$(setup_pipeline_rewritten_history "$TRAIN_CASE" rewritten-input)
  train_anchor_root "$TRAIN_CASE"
  add_gh_train_fake "$TRAIN_CASE" CLOSED "$TRAIN_MEMBER_HEAD"
  tmp="$TRAIN_CASE/_train"
  git clone -q "$TRAIN_CASE/origin.git" "$tmp"
  git -C "$tmp" fetch -q origin refs/pull/7/head
  git -C "$tmp" checkout -q -b train origin/main~1
  git -C "$tmp" -c user.email=t@t -c user.name=t merge -q --no-ff --no-edit "$TRAIN_MEMBER_HEAD"
  TRAIN_HEAD=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin HEAD:refs/pull/9/head
  rm -rf "$tmp"
  git -C "$TRAIN_CASE/wt" fetch -q origin refs/pull/7/head refs/pull/9/head
  train_default_list "$TRAIN_CASE"
  add_logging_treehouse "$TRAIN_CASE"
}

# A run record shows what a pipeline run pushed, never that the copy's own commits
# survived into the train, so no record can stand in for carried work (Main 3011 F1).
# Dropped-input falsifier: the copy holds a commit neither the train head nor the
# default branch has, and a run record ties exactly this copy to the listed head.
test_train_run_record_never_stands_in_for_carried_work() {
  local copy_head rows
  train_case train-record-dropped-input squash extra
  copy_head=$(git -C "$TRAIN_CASE/wt" rev-parse HEAD)
  write_nm_run_record "$TRAIN_CASE" 01RUNDROPPED "$TRAIN_MEMBER_URL" "$copy_head" "$TRAIN_MEMBER_HEAD"
  assert_train_refused "$TRAIN_CASE" "train-record-dropped-input" "copy's work is not proven present"
  assert_grep "unmerged follow-up" "$TRAIN_CASE/stderr" "train-record-dropped-input: refusal did not name the unmerged commit"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-record-dropped-input: the record carried the copy"
  assert_present "$TRAIN_CASE/nm/state.sqlite" "train-record-dropped-input: refusal removed the run record"
  rows=$(python3 -I -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from runs").fetchone()[0])' "$TRAIN_CASE/nm/state.sqlite")
  [ "$rows" = 1 ] || fail "train-record-dropped-input: refusal changed the run record ($rows rows)"

  # The live d1 B5 r4 shape: a rewritten input whose patch is in no train commit stays refused.
  train_pipeline_input_case train-record-rewritten-input
  copy_head=$(git -C "$TRAIN_CASE/wt" rev-parse HEAD)
  write_nm_run_record "$TRAIN_CASE" 01RUNTRAIN "$TRAIN_MEMBER_URL" "$copy_head" "$TRAIN_MEMBER_HEAD"
  assert_train_refused "$TRAIN_CASE" "train-record-rewritten-input" "copy's work is not proven present"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-record-rewritten-input: the record carried the copy"
  pass "a matching run record never carries a copy whose commits the train head lacks; the copy and the record stay"
}

# A silent record reader changes nothing on the train route, which never reads the record.
test_train_route_never_reads_the_run_record() {
  local copy_head rc
  train_pipeline_input_case train-record-not-read
  copy_head=$(git -C "$TRAIN_CASE/wt" rev-parse HEAD)
  write_nm_run_record "$TRAIN_CASE" 01RUNTRAIN "$TRAIN_MEMBER_URL" "$copy_head" "$TRAIN_MEMBER_HEAD"
  install_quiet_record_reader "$TRAIN_CASE" hang
  rc=0
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" || rc=$?
  expect_code 1 "$rc" "train-record-not-read: the train route must refuse, not wait on a record"$'\n'"$(cat "$TRAIN_CASE/stderr")"
  assert_no_grep "did not answer" "$TRAIN_CASE/stderr" "train-record-not-read: the train route waited on the run record"
  assert_refusal_retained_task_state "$TRAIN_CASE" train-record-not-read "$copy_head"
  pass "the train route never reads the run record, so a silent reader neither delays nor admits it"
}

# Reachability from the default branch is not a carry proof (Main 3237 F1): an
# `ours` merge puts a commit in the default history without its change. Each case
# below hides one commit K that the flat train never carried behind such a merge,
# so the helper that skipped default-reachable commits proved the rest and
# accepted. K sits under the member's replayed commits, so they stay candidates.

# train_ours_merge_into_main <case-dir> <origin ref>: merge that ref into origin's
# main with the ours strategy, then fetch main into the project and the copy.
train_ours_merge_into_main() {
  local case_dir=$1 ref=$2 tmp="$1/_ours"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name t
  git -C "$tmp" merge -q -s ours --no-edit "origin/${ref#refs/heads/}" >/dev/null
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"
  git -C "$case_dir/project" fetch -q origin
  [ ! -d "$case_dir/wt" ] || git -C "$case_dir/wt" fetch -q origin
}

# train_hide_commit <case-dir> <member|copy>: build K (extra.txt on the old main)
# followed by the member's two commits replayed, push K as a branch, and hide K
# in main behind an ours merge. "member" publishes the rebuilt head as the member
# PR head (TRAIN_MEMBER_HEAD changes); "copy" leaves the member alone and sets
# HIDDEN_COPY_HEAD for the caller to reset the copy to. Sets HIDDEN_COMMIT.
train_hide_commit() {
  local case_dir=$1 target=$2 tmp="$1/_member" rebuilt
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name t
  git -C "$tmp" fetch -q origin refs/pull/7/head
  git -C "$tmp" checkout -q -b hidden "$(git -C "$tmp" rev-list -1 --grep='^main moves$' origin/main)"
  printf '%s\n' hidden > "$tmp/extra.txt"
  git -C "$tmp" add -- extra.txt
  git -C "$tmp" commit -q -m "hidden follow-up"
  HIDDEN_COMMIT=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/heads/hidden-k"
  git -C "$tmp" cherry-pick "$TRAIN_MEMBER_HEAD~1" "$TRAIN_MEMBER_HEAD" >/dev/null
  rebuilt=$(git -C "$tmp" rev-parse HEAD)
  case "$target" in
    member)
      TRAIN_MEMBER_HEAD=$rebuilt
      git -C "$tmp" push -q -f origin "HEAD:refs/pull/7/head" ;;
    copy)
      HIDDEN_COPY_HEAD=$rebuilt
      git -C "$tmp" push -q origin "HEAD:refs/heads/hidden-copy" ;;
    *) fail "train_hide_commit: unknown target $target" ;;
  esac
  rm -rf "$tmp"
  train_ours_merge_into_main "$case_dir" refs/heads/hidden-k
  git -C "$case_dir/project" fetch -q origin refs/pull/7/head
  [ ! -d "$case_dir/wt" ] || git -C "$case_dir/wt" fetch -q origin refs/pull/7/head
}

test_train_ours_merged_commit_in_a_copy_never_counts_as_carried() {
  local copy_head
  # Copy route: the copy is K plus the member's replayed commits.
  train_case train-ours-copy squash head "" flat
  train_hide_commit "$TRAIN_CASE" copy
  git -C "$TRAIN_CASE/wt" reset -q --hard "$HIDDEN_COPY_HEAD"
  copy_head=$(git -C "$TRAIN_CASE/wt" rev-parse HEAD)
  git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$HIDDEN_COMMIT" origin/main \
    || fail "train-ours-copy: the hidden commit is not reachable from the default branch"
  if git -C "$TRAIN_CASE/wt" cat-file -e "origin/main:extra.txt" 2>/dev/null; then
    fail "train-ours-copy: the default branch holds the hidden change"
  fi
  assert_train_refused "$TRAIN_CASE" "train-ours-copy" "copy's work is not proven present"
  assert_grep "hidden follow-up" "$TRAIN_CASE/stderr" "train-ours-copy: refusal did not name the hidden commit"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-ours-copy: the train was accepted"
  [ "$(git -C "$TRAIN_CASE/wt" rev-parse HEAD)" = "$copy_head" ] || fail "train-ours-copy: refusal moved the copy"
  pass "a commit hidden in the default history by an ours merge is not carried by the train, in the copy route"
}

test_train_ours_merged_commit_in_a_member_never_counts_as_carried() {
  # Record-only route: the listed member head holds K, which the train never carried.
  train_absent_case train-ours-record flat
  train_hide_commit "$TRAIN_CASE" member
  add_gh_train_fake "$TRAIN_CASE" CLOSED "$TRAIN_MEMBER_HEAD"
  train_default_list "$TRAIN_CASE"
  assert_train_refused "$TRAIN_CASE" "train-ours-record" "neither contains it nor carries every commit of it"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-ours-record: the train was accepted"
  [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] || fail "train-ours-record: refusal closed the backlog"
  pass "a commit hidden in the default history by an ours merge is not carried by the train, in the record-only route"
}

# The same rule must still accept work the train genuinely carries, also when the
# default history holds an ours merge of some unrelated commit.
test_train_flat_carried_work_is_accepted_beside_an_ours_merge() {
  local tmp
  train_case train-ours-carried squash head "" flat
  tmp="$TRAIN_CASE/_other"
  git clone -q "$TRAIN_CASE/origin.git" "$tmp"
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name t
  git -C "$tmp" checkout -q -b unrelated "$(git -C "$tmp" rev-list -1 --grep='^main moves$' origin/main)"
  printf '%s\n' other > "$tmp/other.txt"
  git -C "$tmp" add -- other.txt
  git -C "$tmp" commit -q -m "unrelated work"
  git -C "$tmp" push -q origin HEAD:refs/heads/unrelated
  rm -rf "$tmp"
  train_ours_merge_into_main "$TRAIN_CASE" refs/heads/unrelated
  assert_train_allowed "$TRAIN_CASE" "train-ours-carried"

  train_absent_case train-ours-carried-record flat
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
    || fail "train-ours-carried-record: a carried flat train was refused: $(cat "$TRAIN_CASE/stderr")"
  assert_grep "$TRAIN_URL" "$TRAIN_CASE/stderr" "train-ours-carried-record: stderr did not name the train PR"
  assert_absent "$TRAIN_CASE/state/task-x1.meta" "train-ours-carried-record: accepted teardown left the task record"
  pass "a flat train that carries every member commit is accepted in both routes beside an ours merge of unrelated work"
}

# Main 2206 F1: where a commit sits in the default branch's history says nothing about
# whether its change was kept. K (hidden.txt) is the FIRST parent of the merge M whose
# tree is D's, and the branch was fast-forwarded from D to M, so K is on the first-parent
# line and hidden.txt is in no tree from M on. The member is built on K.
assert_parent_order_fixture() {  # <case-dir> <label>
  local case_dir=$1 label=$2
  git -C "$case_dir/wt" rev-list --first-parent origin/main | grep -qxF -- "$TRAIN_HIDDEN_COMMIT" \
    || fail "$label: K is not on the default branch's first-parent line"
  [ "$(git -C "$case_dir/wt" show origin/main:hidden.txt 2>/dev/null)" != hidden ] \
    || fail "$label: the default branch holds the hidden change"
  [ -z "${TRAIN_LANDING_COMMIT:-}" ] || [ "$(git -C "$case_dir/wt" show "$TRAIN_LANDING_COMMIT:hidden.txt" 2>/dev/null)" != hidden ] \
    || fail "$label: the landing holds the hidden change"
  [ "$(git -C "$case_dir/wt" show "$TRAIN_HEAD:hidden.txt" 2>/dev/null)" != hidden ] \
    || fail "$label: the train holds the hidden change"
  return 0
}

test_train_member_hidden_by_parent_order_is_never_taken_as_delivered() {
  local route order
  # Order 1: K and D change different files. Order 2 (Main 2306 F1): K and D both add
  # hidden.txt with other content, so the merge of the two conflicts and takes D's side.
  for order in 1 2; do
    for route in copy record; do
      if [ "$route" = copy ]; then
        TRAIN_HIDDEN_ORDER=$order TRAIN_MAIN_EDIT=1 train_case "hidden-order$order-$route" squash head "" ours-flat
        git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_COPY_HEAD:hidden.txt" 2>/dev/null \
          || fail "hidden-order$order-$route: the copy lacks the hidden change"
      else
        TRAIN_HIDDEN_ORDER=$order TRAIN_MAIN_EDIT=1 train_absent_case "hidden-order$order-$route" ours-flat squash
      fi
      assert_parent_order_fixture "$TRAIN_CASE" "hidden-order$order-$route"
      assert_train_refused "$TRAIN_CASE" "hidden-order$order-$route" "REFUSED"
      assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "hidden-order$order-$route: the train was accepted"
      [ "$route" = copy ] || [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] \
        || fail "hidden-order$order-$route: refusal closed the backlog"
    done
  done
  pass "a member built on a commit that only parent order put on the default branch's first-parent line is refused, conflicting side or not, in the copy and record-only routes"
}

test_default_proof_refuses_a_commit_that_parent_order_put_on_the_first_parent_line() {
  local copy order
  for order in 1 2; do
    for copy in hidden head; do
      TRAIN_HIDDEN_ORDER=$order default_proof_case "default-hidden-order$order-$copy" squash "$copy" ours-flat
      assert_parent_order_fixture "$TRAIN_CASE" "default-hidden-order$order-$copy"
      git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_COPY_HEAD:hidden.txt" 2>/dev/null \
        || fail "default-hidden-order$order-$copy: the copy lacks the hidden change"
      assert_default_proof_refused "$TRAIN_CASE" "default-hidden-order$order-$copy"
    done
  done
  pass "a copy that holds a change the default branch dropped behind a first-parent merge is refused by the content-in-default proof, conflicting side or not"
}

# Main 2206 F3: a member already on the default branch's first-parent line, and a copy
# later than it that the train carried whole, are landed. The squash landing's first
# parent is H and its tree is the train head's.
test_train_member_on_the_default_line_is_accepted_when_the_train_carried_it() {
  local route
  TRAIN_MEMBER_ON_LINE=1 TRAIN_MAIN_EDIT=1 TRAIN_MAIN_EDIT_FILE=second.txt train_case line-copy squash train "" merge
  [ "$(git -C "$TRAIN_CASE/wt" rev-parse "$TRAIN_LANDING_COMMIT^")" = "$TRAIN_MEMBER_HEAD" ] \
    || fail "line-copy: the landing's first parent is not the member head"
  [ "$(git -C "$TRAIN_CASE/wt" rev-parse "$TRAIN_LANDING_COMMIT^{tree}")" = "$(git -C "$TRAIN_CASE/wt" rev-parse "$TRAIN_HEAD^{tree}")" ] \
    || fail "line-copy: the landing's tree is not the train head's"
  [ "$TRAIN_COPY_HEAD" = "$TRAIN_HEAD" ] || fail "line-copy: the copy is not at the train head"
  assert_train_allowed "$TRAIN_CASE" line-copy
  TRAIN_MEMBER_ON_LINE=1 TRAIN_MAIN_EDIT=1 TRAIN_MAIN_EDIT_FILE=second.txt train_absent_case line-record merge squash
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
    || fail "line-record: a member on the default line that a verified train carried was refused: $(cat "$TRAIN_CASE/stderr")"
  assert_grep "$TRAIN_URL" "$TRAIN_CASE/stderr" "line-record: stderr did not name the train PR"
  assert_absent "$TRAIN_CASE/state/task-x1.meta" "line-record: accepted teardown left the task record"
  assert_train_backlog_close "$TRAIN_CASE" line-record
  pass "a member on the default branch's first-parent line and a later copy of the train head are accepted in the copy and record-only routes"
}

# Main 2206 F2: a git read that fails, or ends early, is no proof. Each case fails one read of the
# content proof (the changed-path list, its mode check, the patch, the throwaway index or the
# apply) and the teardown must keep the copy and every record. In the first and third rows the train
# reverted the member's file, so the unfailed read refuses on content alone; in the others a genuine
# landing (the mode control, the shared file) is accepted without the fault, so only the failed read
# can change the answer.
# FAULT_ROWS names the rows to run (default all), so one row can be run alone.
test_a_failed_or_short_git_read_never_proves_content() {
  local row
  for row in ${FAULT_ROWS:-default-empty copy-short copy-patch-partial record-short record-patch-partial mode-entry apply-fault read-tree-fault}; do
    case "$row" in
      default-empty)
        TRAIN_REVERT_MEMBER=1 default_proof_case "git-fault-$row" merge head merge
        add_git_read_fault "$TRAIN_CASE" "diff --raw -z --no-renames" none ;;
      copy-short)
        TRAIN_REVERT_MEMBER=1 TRAIN_MAIN_EDIT=0 train_case "git-fault-$row" squash head "" merge
        add_git_read_fault "$TRAIN_CASE" "diff --raw -z --no-renames" 'text::100644 100644 0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 M\0feature2.txt\0' ;;
      copy-patch-partial)
        TRAIN_SHARED_APPEND=1 train_case "git-fault-$row" squash head "" merge
        add_git_read_fault "$TRAIN_CASE" "diff --binary --full-index" lastpatch ;;
      record-short)
        TRAIN_REVERT_MEMBER=1 TRAIN_MAIN_EDIT=0 train_absent_case "git-fault-$row" merge squash
        add_git_read_fault "$TRAIN_CASE" "diff --raw -z --no-renames" 'text::100644 100644 0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 M\0feature2.txt\0' ;;
      record-patch-partial)
        TRAIN_SHARED_APPEND=1 train_absent_case "git-fault-$row" merge squash
        add_git_read_fault "$TRAIN_CASE" "diff --binary --full-index" lastpatch ;;
      mode-entry)
        BW_MODE_KEPT=1 BW_LATER_EDIT=1 bespoke_world "git-fault-$row-control" bw_steps_mode_only
        run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
          || fail "git-fault-$row: the control (mode kept, content edited later) was refused: $(cat "$TRAIN_CASE/stderr")"
        BW_MODE_KEPT=1 BW_LATER_EDIT=1 bespoke_world "git-fault-$row" bw_steps_mode_only
        BW_MODE_KEPT=0 BW_LATER_EDIT=0
        add_git_read_fault "$TRAIN_CASE" "ls-tree -z" none ;;
      apply-fault)
        TRAIN_SHARED_APPEND=1 train_case "git-fault-$row" squash head "" merge
        add_git_read_fault "$TRAIN_CASE" "apply --cached -R --check" none ;;
      read-tree-fault)
        TRAIN_SHARED_APPEND=1 train_case "git-fault-$row" squash head "" merge
        add_git_read_fault "$TRAIN_CASE" "read-tree" none ;;
    esac
    assert_default_proof_refused "$TRAIN_CASE" "git-fault-$row"
    [ -s "$TRAIN_CASE/fault.hits" ] || fail "git-fault-$row: the injected read never ran"
    assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "git-fault-$row: the train was accepted"
  done
  TRAIN_REVERT_MEMBER=0
  TRAIN_SHARED_APPEND=0
  pass "a changed-path list, a mode check, a patch, an index or an apply that fails or ends early never proves content, in the default proof, the copy route and the record-only route"
}

# A landing the forge names that is a plain commit (no merge for the audit to read) holds
# its own tree: the member's change must be in it.
test_train_landing_commit_that_is_a_plain_commit_without_the_change_is_refused() {
  local plain
  train_absent_case train-landing-plain flat squash
  plain=$(git -C "$TRAIN_CASE/wt" rev-list -1 --grep='^main moves$' origin/main)
  [ -n "$plain" ] || fail "train-landing-plain: no plain commit on main to name"
  git -C "$TRAIN_CASE/wt" cat-file -e "$plain:feature2.txt" 2>/dev/null \
    && fail "train-landing-plain: the plain commit holds the member's file"
  TRAIN_LANDING_COMMIT=$plain train_default_list "$TRAIN_CASE"
  assert_train_refused "$TRAIN_CASE" "train-landing-plain" "does not hold the member's net change in its tree"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "train-landing-plain: the train was accepted"
  [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] || fail "train-landing-plain: refusal closed the backlog"
  pass "a landing commit that is a plain commit without the member's change is refused, though the merge audit has nothing to read"
}

# train_later_merge_into_main <case-dir>: after the landing, a real two-parent merge on
# origin's main that edits the member's and the train's files by hand, fetched into the
# project and the copy.
train_later_merge_into_main() {
  local case_dir=$1 tmp="$1/_later"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name t
  git -C "$tmp" checkout -q -b other
  printf '%s\n' other > "$tmp/other.txt"
  git -C "$tmp" add -- other.txt
  git -C "$tmp" commit -q -m "other branch work"
  git -C "$tmp" checkout -q main
  printf '%s\n' y > "$tmp/y.txt"
  git -C "$tmp" add -- y.txt
  git -C "$tmp" commit -q -m "main work"
  git -C "$tmp" merge -q --no-commit --no-ff other >/dev/null
  printf '%s\n' later-change > "$tmp/feature.txt"
  printf '%s\n' later-second > "$tmp/second.txt"
  git -C "$tmp" add -- feature.txt second.txt
  git -C "$tmp" commit -q -m "merge other, editing the member's files"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"
  git -C "$case_dir/project" fetch -q origin
  [ ! -d "$case_dir/wt" ] || git -C "$case_dir/wt" fetch -q origin
}

# Main 2306 F2: a change made on the default branch after the train landed does not count
# against a member the landing carried, even when it is a merge that edits the same files.
test_train_member_carried_by_the_landing_is_accepted_after_a_later_default_merge() {
  TRAIN_MEMBER_ON_LINE=1 TRAIN_MAIN_EDIT=0 train_case later-merge-copy squash train "" merge
  train_later_merge_into_main "$TRAIN_CASE"
  [ "$(git -C "$TRAIN_CASE/wt" show origin/main:feature.txt)" = later-change ] || fail "later-merge-copy: the later merge did not edit feature.txt"
  git -C "$TRAIN_CASE/wt" rev-list --merges --first-parent -n 1 origin/main | grep -q . || fail "later-merge-copy: no merge on the default branch"
  assert_train_allowed "$TRAIN_CASE" later-merge-copy
  TRAIN_MEMBER_ON_LINE=1 TRAIN_MAIN_EDIT=0 train_absent_case later-merge-record merge squash
  train_later_merge_into_main "$TRAIN_CASE"
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
    || fail "later-merge-record: a carried member was refused after a later default merge: $(cat "$TRAIN_CASE/stderr")"
  assert_grep "$TRAIN_URL" "$TRAIN_CASE/stderr" "later-merge-record: stderr did not name the train PR"
  assert_absent "$TRAIN_CASE/state/task-x1.meta" "later-merge-record: accepted teardown left the task record"
  pass "a member the landing carried is accepted in the copy and record-only routes after a later default-branch merge that edits its files"
}

# Main 2306 F4: a member already on the default branch's first-parent line is still proven by
# its content at the train head and at the landing: a train that reverted it carries nothing.
test_train_that_reverted_a_first_parent_member_is_refused() {
  TRAIN_MEMBER_ON_LINE=1 TRAIN_REVERT_MEMBER=1 TRAIN_MAIN_EDIT=1 TRAIN_MAIN_EDIT_FILE=second.txt train_case rev-line-copy squash train "" merge
  git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_HEAD:feature.txt" 2>/dev/null && fail "rev-line-copy: the train head still holds the member's file"
  git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_MEMBER_HEAD:feature.txt" 2>/dev/null || fail "rev-line-copy: the member lacks its file"
  assert_train_refused "$TRAIN_CASE" rev-line-copy "net change is not present in the train head's final tree"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "rev-line-copy: the train was accepted"
  TRAIN_MEMBER_ON_LINE=1 TRAIN_REVERT_MEMBER=1 TRAIN_MAIN_EDIT=1 TRAIN_MAIN_EDIT_FILE=second.txt train_absent_case rev-line-record merge squash
  assert_train_refused "$TRAIN_CASE" rev-line-record "net change is not present in the train head's final tree"
  assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "rev-line-record: the train was accepted"
  [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] || fail "rev-line-record: refusal closed the backlog"
  TRAIN_REVERT_MEMBER=0
  pass "a train that reverted a member already on the default line is refused, in the copy and record-only routes"
}

# Main 2306 F5: the listed sha is exactly 40 hex characters. A longer token is not it.
test_train_listing_with_a_longer_hex_token_is_not_a_listing() {
  local route
  for route in copy record; do
    if [ "$route" = copy ]; then
      train_case "long-sha-$route" squash head "" merge
    else
      train_absent_case "long-sha-$route" merge squash
    fi
    train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "${TRAIN_MEMBER_HEAD}A")"
    assert_train_refused "$TRAIN_CASE" "long-sha-$route" "no PR found by the forge lists it"
    assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "long-sha-$route: the train was accepted"
    train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "${TRAIN_MEMBER_HEAD}f")"
    assert_train_refused "$TRAIN_CASE" "long-sha-$route-f" "no PR found by the forge lists it"
  done
  pass "a 41-character hex token after the member URL is not a listing, in the copy and record-only routes"
}

# Main 2306 F3: the patch id of a commit whose read failed is no patch id. One copy commit
# adds two files; the PR head replays them as two commits. A read of the copy's commit that
# fails after the first file's patch must not match the first replayed commit.
test_a_failed_patch_read_never_proves_a_replayed_patch() {
  local case_dir rc pr_head row
  for row in plain failed-read; do
    case_dir=$(make_case "patch-read-$row")
    write_meta "$case_dir" no-mistakes ship
    pr_head=$(setup_pushed_prerebase_history "$case_dir" combined-commit)
    printf '%s\n' \
      'pr=https://github.com/example/repo/pull/7' \
      "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
    add_gh_pr_merged_for_head "$case_dir" "$pr_head"
    [ "$row" = plain ] || add_git_read_fault "$case_dir" "show --pretty=medium --no-ext-diff" firstpatch
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "patch-read-$row: teardown must refuse"$'\n'"$(cat "$case_dir/stderr")"
    assert_grep "REFUSED" "$case_dir/stderr" "patch-read-$row: no REFUSED line"
    assert_present "$case_dir/state/task-x1.meta" "patch-read-$row: refusal removed the task record"
    [ "$row" = plain ] || [ -s "$case_dir/fault.hits" ] || fail "patch-read-$row: the injected read never ran"
  done
  pass "a patch read that fails after a valid prefix is not taken as the commit's patch id"
}

# A copy whose own commit restores an older version of a file the default branch has moved
# past is unlanded work, though the older version is in the file's history.
test_default_proof_refuses_a_copy_that_restores_an_older_version() {
  local tmp
  TRAIN_MAIN_EDIT=0 train_case restore-older squash head "" merge
  printf '[]\n' > "$TRAIN_CASE/gh-fixture/list.json"
  tmp="$TRAIN_CASE/_restore"
  git clone -q "$TRAIN_CASE/origin.git" "$tmp"
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name t
  printf '%s\n' v1 > "$tmp/older.txt"
  git -C "$tmp" add -- older.txt
  git -C "$tmp" commit -q -m "older v1"
  printf '%s\n' v2 > "$tmp/older.txt"
  git -C "$tmp" add -- older.txt
  git -C "$tmp" commit -q -m "older v2"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"
  git -C "$TRAIN_CASE/wt" fetch -q origin
  git -C "$TRAIN_CASE/wt" reset -q --hard origin/main
  printf '%s\n' v1 > "$TRAIN_CASE/wt/older.txt"
  git -C "$TRAIN_CASE/wt" add -- older.txt
  git -C "$TRAIN_CASE/wt" -c user.email=t@t -c user.name=t commit -q -m "restore v1"
  assert_default_proof_refused "$TRAIN_CASE" restore-older
  pass "a copy that restores an older version of a file the default branch moved past is refused"
}

# A file several members of a train change is a version the train holds but the member
# never had (here the train rewrote another line of it). The train still holds the member's
# work when the member's own patch reverse-applies to it.
test_train_accepts_a_file_other_members_appended_to() {
  local shape
  for shape in merge flat; do
    TRAIN_SHARED_APPEND=1 train_case "shared-append-$shape" squash head "" "$shape"
    [ "$(git -C "$TRAIN_CASE/wt" show "$TRAIN_COPY_HEAD:shared.txt" | tr '\n' ' ')" = "base-one base-two base-three base-four member " ] || fail "shared-append-$shape: the copy's shared.txt is not base plus the member's line"
    [ "$(git -C "$TRAIN_CASE/wt" show "$TRAIN_HEAD:shared.txt" | tr '\n' ' ')" = "base-one-edited-by-other base-two base-three base-four member " ] || fail "shared-append-$shape: the train's shared.txt is not the edited line, base, member"
    assert_train_allowed "$TRAIN_CASE" "shared-append-$shape"
  done
  TRAIN_SHARED_APPEND=1 train_absent_case shared-append-record merge squash
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
    || fail "shared-append-record: a carried member was refused: $(cat "$TRAIN_CASE/stderr")"
  assert_absent "$TRAIN_CASE/state/task-x1.meta" "shared-append-record: accepted teardown left the task record"
  pass "a member whose train holds a file with other members' lines added is accepted, in the copy and record-only routes"
}

# bespoke_world <name> <steps function> [<copy>]: a closed-member, merged-train task whose git
# history a steps function builds in a scratch clone of the case's origin. The function gets the
# clone's path and must leave main, the member branch and the train branch pushed, and set:
#   BW_BASE     the member PR's base oid as the forge records it
#   BW_MEMBER   the member head (pushed as refs/pull/7/head)
#   BW_TRAIN    the train head (pushed as refs/pull/9/head)
#   BW_LANDING  the commit the forge names as the train's landing
# The copy is reset to BW_MEMBER, or to BW_COPY when the function sets it. Sets TRAIN_CASE.
bespoke_world() {
  local name=$1 steps=$2 tmp init
  train_case "$name" none head "" merge
  printf '[]\n' > "$TRAIN_CASE/gh-fixture/list.json"
  tmp="$TRAIN_CASE/_bw"
  git clone -q "$TRAIN_CASE/origin.git" "$tmp"
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name t
  init=$(git -C "$tmp" rev-list --max-parents=0 origin/main | head -1)
  git -C "$tmp" checkout -q -B main "$init"
  git -C "$tmp" push -q -f origin main
  git -C "$tmp" push -q origin :refs/pull/7/head :refs/pull/9/head 2>/dev/null || :
  BW_COPY=
  "$steps" "$tmp"
  rm -rf "$tmp"
  git -C "$TRAIN_CASE/project" fetch -q origin
  git -C "$TRAIN_CASE/wt" fetch -q origin refs/pull/7/head
  git -C "$TRAIN_CASE/wt" fetch -q origin refs/pull/9/head 2>/dev/null || :
  git -C "$TRAIN_CASE/wt" reset -q --hard "${BW_COPY:-$BW_MEMBER}"
  TRAIN_MEMBER_HEAD=$BW_MEMBER
  TRAIN_HEAD=$BW_TRAIN
  TRAIN_COPY_HEAD=$(git -C "$TRAIN_CASE/wt" rev-parse HEAD)
  TRAIN_BASE_OID=$BW_BASE
  TRAIN_LANDING_COMMIT=${BW_LANDING:-}
  add_gh_train_fake "$TRAIN_CASE" CLOSED "$TRAIN_MEMBER_HEAD"
  train_default_list "$TRAIN_CASE"
  add_logging_treehouse "$TRAIN_CASE"
}

# bw_commit_file <clone> <path> <content> <message>: commit one file.
bw_commit_file() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -q -m "$4"
}

# Main 2415 F1: a merge that resolved the conflict of H and D to a third, unrelated version.
# H is the clean member (its own text), D changed the same file another way, M has H first and
# D second with a third tree, and the default branch was fast-forwarded from D to M.
bw_steps_third_version() {  # <clone>
  local t=$1 tree d h m
  bw_commit_file "$t" f.txt "baseline only" "baseline"
  git -C "$t" push -q origin main
  BW_BASE=$(git -C "$t" rev-parse HEAD)
  git -C "$t" checkout -q -b member
  bw_commit_file "$t" f.txt "MEMBER ONLY, never landed" "member change"
  h=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/7/head"
  git -C "$t" checkout -q main
  bw_commit_file "$t" f.txt "default side only" "default side"
  d=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin main
  if [ "${BW_THIRD_CARRIES:-0}" = 1 ]; then
    printf '%s\n' "MEMBER ONLY, never landed" > "$t/f.txt"
  else
    printf '%s\n' "third unrelated resolution" > "$t/f.txt"
  fi
  git -C "$t" add -- f.txt
  tree=$(git -C "$t" write-tree)
  m=$(git -C "$t" commit-tree "$tree" -p "$h" -p "$d" -m "resolve f.txt")
  git -C "$t" reset -q --hard "$m"
  git -C "$t" push -q origin main
  BW_MEMBER=$h
  BW_TRAIN=$m
  BW_LANDING=
}

test_default_proof_refuses_a_third_version_conflict_resolution() {
  local control
  for control in 0 1; do
    BW_THIRD_CARRIES=$control bespoke_world "third-version-$control" bw_steps_third_version
    if [ "$control" = 0 ]; then
      [ "$(git -C "$TRAIN_CASE/wt" show origin/main:f.txt)" = "third unrelated resolution" ] || fail "third-version: main lacks the third version"
      assert_default_proof_refused "$TRAIN_CASE" third-version-refused
    else
      [ "$(git -C "$TRAIN_CASE/wt" show origin/main:f.txt)" = "MEMBER ONLY, never landed" ] || fail "third-version control: main lacks the member's text"
      run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
        || fail "third-version control: a merge that carried the member's text was refused: $(cat "$TRAIN_CASE/stderr")"
    fi
  done
  BW_THIRD_CARRIES=0
  pass "a conflict resolved to a third version is refused by the default proof, and the same merge carrying the member's text is accepted"
}

# Main 2415 F2: the member changes only the executable bit; a merge keeps the other side's mode.
bw_steps_mode_only() {  # <clone>
  local t=$1 h d m tree
  bw_commit_file "$t" job.sh "echo job" "baseline"
  git -C "$t" push -q origin main
  BW_BASE=$(git -C "$t" rev-parse HEAD)
  git -C "$t" checkout -q -b member
  chmod +x "$t/job.sh"
  git -C "$t" add -- job.sh
  git -C "$t" commit -q -m "make job.sh executable"
  h=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/7/head"
  git -C "$t" checkout -q main
  bw_commit_file "$t" other.txt "other" "default side"
  d=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin main
  if [ "${BW_MODE_KEPT:-0}" = 1 ]; then
    chmod +x "$t/job.sh"
    git -C "$t" add -- job.sh
    git -C "$t" commit -q -m "default also makes job.sh executable"
    d=$(git -C "$t" rev-parse HEAD)
    git -C "$t" push -q origin main
  fi
  tree=$(git -C "$t" rev-parse "$d^{tree}")
  m=$(git -C "$t" commit-tree "$tree" -p "$h" -p "$d" -m "merge that kept the default side's tree")
  git -C "$t" reset -q --hard "$m"
  git -C "$t" push -q origin main
  if [ "${BW_LATER_EDIT:-0}" = 1 ]; then
    # main then edits the file's content, so the paths no longer compare equal
    printf '%s\n' "echo more" >> "$t/job.sh"
    git -C "$t" add -- job.sh
    git -C "$t" commit -q -m "edit job.sh"
    git -C "$t" push -q origin main
  fi
  BW_MEMBER=$h
  BW_TRAIN=$m
  BW_LANDING=
}

test_default_proof_refuses_work_whose_only_change_is_a_file_mode() {
  local control
  for control in 0 1; do
    BW_MODE_KEPT=$control bespoke_world "mode-only-$control" bw_steps_mode_only
    [ "$(git -C "$TRAIN_CASE/wt" ls-tree "$TRAIN_MEMBER_HEAD" job.sh | cut -c1-6)" = 100755 ] || fail "mode-only: the member is not executable"
    if [ "$control" = 0 ]; then
      [ "$(git -C "$TRAIN_CASE/wt" ls-tree origin/main job.sh | cut -c1-6)" = 100644 ] || fail "mode-only: main is executable"
      assert_default_proof_refused "$TRAIN_CASE" mode-only-refused
    else
      [ "$(git -C "$TRAIN_CASE/wt" ls-tree origin/main job.sh | cut -c1-6)" = 100755 ] || fail "mode-only control: main is not executable"
      run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
        || fail "mode-only control: a mode that was kept was refused: $(cat "$TRAIN_CASE/stderr")"
    fi
  done
  BW_MODE_KEPT=0
  pass "a change of only the executable bit that the default branch did not keep is refused, and the same change kept is accepted"
}

# Main 2415 F3: the member deletes obsolete.txt; the train (and the landing) restores it.
bw_steps_restored_deletion() {  # <clone>
  local t=$1 h tr
  bw_commit_file "$t" obsolete.txt "obsolete" "baseline"
  git -C "$t" push -q origin main
  BW_BASE=$(git -C "$t" rev-parse HEAD)
  git -C "$t" checkout -q -b member
  git -C "$t" rm -q -- obsolete.txt
  git -C "$t" commit -q -m "delete obsolete.txt"
  h=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/7/head"
  # the member head is on the default branch's first-parent line before the train starts
  git -C "$t" checkout -q main
  git -C "$t" merge -q --ff-only member
  git -C "$t" push -q origin main
  git -C "$t" checkout -q -b train
  if [ "${BW_DELETION_CARRIED:-0}" != 1 ]; then
    bw_commit_file "$t" obsolete.txt "obsolete" "restore obsolete.txt"
  fi
  bw_commit_file "$t" second.txt "second" "second member work"
  tr=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/9/head"
  git -C "$t" checkout -q main
  git -C "$t" merge -q --squash train >/dev/null
  git -C "$t" commit -q -m "train squash (#9)"
  git -C "$t" push -q origin main
  BW_MEMBER=$h
  BW_TRAIN=$tr
  BW_LANDING=$(git -C "$t" rev-parse HEAD)
}

test_train_that_restored_a_deleted_file_is_refused() {
  local control
  for control in 0 1; do
    BW_DELETION_CARRIED=$control bespoke_world "restored-deletion-$control" bw_steps_restored_deletion
    train_default_list "$TRAIN_CASE"
    if [ "$control" = 0 ]; then
      git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_HEAD:obsolete.txt" 2>/dev/null || fail "restored-deletion: the train does not hold the file"
      assert_train_refused "$TRAIN_CASE" restored-deletion-copy "net change is not present in the train head's final tree"
      assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "restored-deletion-copy: the train was accepted"
      BW_DELETION_CARRIED=0 bespoke_world "restored-deletion-record" bw_steps_restored_deletion
      write_windowless_legacy_meta "$TRAIN_CASE" no-mistakes ship "$TRAIN_CASE/missing-wt"
      append_pr_meta_url "$TRAIN_CASE"
      seed_backlog_in_flight "$TRAIN_CASE"
      assert_train_refused "$TRAIN_CASE" restored-deletion-record "net change is not present in the train head's final tree"
      [ "$(backlog_row_state "$TRAIN_CASE")" = in_flight ] || fail "restored-deletion-record: refusal closed the backlog"
    else
      git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_HEAD:obsolete.txt" 2>/dev/null && fail "carried deletion: the train holds the file"
      run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
        || fail "carried deletion: a train that kept the deletion was refused: $(cat "$TRAIN_CASE/stderr")"
    fi
  done
  BW_DELETION_CARRIED=0
  pass "a train that restored a file the member deleted is refused in the copy and record-only routes, and a train that kept the deletion is accepted"
}

# Main 2415 F5: a verified train that also changes 1,501 unrelated files is a valid train.
bw_steps_many_unrelated() {  # <clone>
  local t=$1 h tr i
  bw_commit_file "$t" feature.txt "hello" "baseline"
  git -C "$t" push -q origin main
  BW_BASE=$(git -C "$t" rev-parse HEAD)
  git -C "$t" checkout -q -b member
  bw_commit_file "$t" feature.txt "hello member" "member change"
  h=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/7/head"
  git -C "$t" checkout -q -b train
  mkdir -p "$t/other"
  for ((i = 0; i < ${BW_UNRELATED:-1501}; i++)); do printf '%s\n' "$i" > "$t/other/f$i.txt"; done
  git -C "$t" add -- other
  git -C "$t" commit -q -m "other members' files"
  tr=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/9/head"
  git -C "$t" checkout -q main
  git -C "$t" merge -q --squash train >/dev/null
  git -C "$t" commit -q -m "train squash (#9)"
  BW_LANDING=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin main
  # a later default merge edits the member's file, so only the train route can decide the copy
  git -C "$t" checkout -q -b later "$BW_BASE"
  bw_commit_file "$t" later.txt "later" "later branch"
  git -C "$t" checkout -q main
  git -C "$t" merge -q --no-commit --no-ff later >/dev/null
  printf '%s\n' "hello member, edited later" > "$t/feature.txt"
  git -C "$t" add -- feature.txt
  git -C "$t" commit -q -m "merge later, editing feature.txt"
  git -C "$t" push -q origin main
  BW_MEMBER=$h
  BW_TRAIN=$tr
}

test_train_with_many_unrelated_paths_still_accepts_its_member() {
  local count
  for count in 3 1501; do
    BW_UNRELATED=$count bespoke_world "unrelated-$count" bw_steps_many_unrelated
    train_default_list "$TRAIN_CASE"
    assert_train_allowed "$TRAIN_CASE" "unrelated-$count-copy"
    BW_UNRELATED=$count bespoke_world "unrelated-record-$count" bw_steps_many_unrelated
    train_default_list "$TRAIN_CASE"
    write_windowless_legacy_meta "$TRAIN_CASE" no-mistakes ship "$TRAIN_CASE/missing-wt"
    append_pr_meta_url "$TRAIN_CASE"
    seed_backlog_in_flight "$TRAIN_CASE"
    run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
      || fail "unrelated-record-$count: a valid train was refused: $(cat "$TRAIN_CASE/stderr")"
  done
  BW_UNRELATED=1501
  pass "a verified train that changes 1,501 unrelated paths still accepts its member, in the copy and record-only routes"
}

# Main 2415 F4: a failed read of a train patch is unknown, whichever train commit it is. X is an
# unrelated newer train commit; the member's own patch is replayed by another train commit.
bw_steps_replayed_patch() {  # <clone>
  local t=$1 h tr
  bw_commit_file "$t" feature.txt "hello" "baseline"
  git -C "$t" push -q origin main
  BW_BASE=$(git -C "$t" rev-parse HEAD)
  git -C "$t" checkout -q -b member
  if [ "${BW_TWO_FILES_ONE_COMMIT:-0}" = 1 ]; then
    printf '%s\n' one > "$t/a.txt"
    printf '%s\n' two > "$t/b.txt"
    git -C "$t" add -- a.txt b.txt
    git -C "$t" commit -q -m "add a and b"
  else
    bw_commit_file "$t" a.txt one "add a"
  fi
  h=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/7/head"
  git -C "$t" checkout -q -b train "$BW_BASE"
  if [ "${BW_TWO_FILES_ONE_COMMIT:-0}" = 1 ]; then
    bw_commit_file "$t" a.txt one "add a"
    bw_commit_file "$t" b.txt two "add b"
  else
    GIT_COMMITTER_DATE="2030-01-01T00:00:00Z" git -C "$t" cherry-pick "$h" >/dev/null
  fi
  bw_commit_file "$t" x.txt unrelated "unrelated newer commit"
  tr=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/9/head"
  git -C "$t" checkout -q main
  git -C "$t" merge -q --squash train >/dev/null
  git -C "$t" commit -q -m "train squash (#9)"
  BW_LANDING=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin main
  # main edits the member's file afterwards, so only the train route can decide the copy
  bw_commit_file "$t" a.txt "one, edited later" "main edits a.txt"
  git -C "$t" push -q origin main
  BW_MEMBER=$h
  BW_TRAIN=$tr
  BW_X=$tr
}

test_a_failed_train_patch_read_is_unknown_in_every_route() {
  local row mode shape
  for shape in 0 1; do
    for row in plain fault-unrelated; do
      for mode in copy record; do
        BW_TWO_FILES_ONE_COMMIT=$shape bespoke_world "patch-$shape-$row-$mode" bw_steps_replayed_patch
        train_default_list "$TRAIN_CASE"
        if [ "$mode" = record ]; then
          write_windowless_legacy_meta "$TRAIN_CASE" no-mistakes ship "$TRAIN_CASE/missing-wt"
          append_pr_meta_url "$TRAIN_CASE"
          seed_backlog_in_flight "$TRAIN_CASE"
        fi
        if [ "$row" = plain ]; then
          # one-commit-two-files member against a train that split it: no single train commit has
          # the member's patch, so the patch proof cannot hold and the work is refused for content
          if [ "$shape" = 1 ]; then
            assert_train_refused "$TRAIN_CASE" "patch-$shape-$row-$mode" "neither contains it nor carries every commit of it"
          else
            run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
              || fail "patch-$shape-$row-$mode: a replayed member was refused: $(cat "$TRAIN_CASE/stderr")"
          fi
        else
          if [ "$shape" = 0 ]; then
            add_git_read_fault "$TRAIN_CASE" "show --pretty=medium --no-ext-diff $BW_X" none
          else
            add_git_read_fault "$TRAIN_CASE" "show --pretty=medium --no-ext-diff $TRAIN_MEMBER_HEAD" firstpatch
          fi
          assert_train_refused "$TRAIN_CASE" "patch-$shape-$row-$mode" "unknown, retry" unknown
          assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "patch-$shape-$row-$mode: the train was accepted"
          [ -s "$TRAIN_CASE/fault.hits" ] || fail "patch-$shape-$row-$mode: the injected read never ran"
        fi
      done
    done
  done
  BW_TWO_FILES_ONE_COMMIT=0
  pass "a failed read of a train patch is unknown in the copy and record-only routes, for a read of an unrelated train commit and for a read of the member"
}

# Main 2415 (extra concern): the forge's base for the member must be readable and present. A
# failed read is unknown, never a reason to prove the work by position.
test_an_unreadable_member_base_is_unknown_in_every_proof() {
  local row
  for row in forge-fails object-missing; do
    TRAIN_MAIN_EDIT=1 train_case "base-$row" squash head "" merge
    case "$row" in
      forge-fails) : > "$TRAIN_CASE/gh-fixture/member-base.fail" ;;
      object-missing) printf '%s\n' dddddddddddddddddddddddddddddddddddddddd > "$TRAIN_CASE/gh-fixture/member-base" ;;
    esac
    assert_train_refused "$TRAIN_CASE" "base-$row" "REFUSED"
    assert_grep "unknown, retry" "$TRAIN_CASE/stderr" "base-$row: refusal did not say the proof is unknown"$'\n'"$(cat "$TRAIN_CASE/stderr")"$'\n'"$(cat "$TRAIN_CASE/gh-fixture/calls.log")"
    assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "base-$row: the train was accepted"
  done
  pass "a member base that the forge cannot give, or that is not in the clone, makes the proof unknown and keeps the copy"
}

# A trade-off, recorded as a test so it cannot change unseen: a copy of a CLOSED member PR whose
# commits are reachable from the default branch through a merge commit, with no train listed, is
# measured from the forge's base against the default branch's tip. If main later edited the very
# lines of the copy's change, that change is no longer present in the tip and the proof refuses,
# because without a recorded landing commit no graph position may be trusted to say where it landed.
# The copy is kept (fail closed); a verified train or a merged PR names its landing and is judged there.
test_default_proof_refuses_a_closed_copy_whose_lines_main_edited_later() {
  TRAIN_MAIN_EDIT=1 train_case later-same-lines merge head "" merge
  printf '[]\n' > "$TRAIN_CASE/gh-fixture/list.json"
  git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_COPY_HEAD" origin/main \
    || fail "later-same-lines: the copy is not reachable from the default branch"
  assert_default_proof_refused "$TRAIN_CASE" later-same-lines
  pass "a CLOSED member's reachable copy whose changed lines main edited later is refused by the default proof, and kept"
}

# Main 2645 F1: a pre-rebase copy (it does not contain the recorded member head) holds O1 and O2.
# The recorded PR head H is a rewritten history carrying only O1's file and h.txt. The train replays
# O1 and O2 (so every patch is present), then reverts O2, and the squash landing L has the train's
# tree. The copy's O2 work (dropped.txt) is in neither the train head nor the landing. Main then
# edits a.txt, so only the train route can decide the copy.
bw_steps_prerebase_reverted() {  # <clone>
  local t=$1 c h tr o1 o2
  bw_commit_file "$t" base.txt "base" "baseline"
  git -C "$t" push -q origin main
  BW_BASE=$(git -C "$t" rev-parse HEAD)
  git -C "$t" checkout -q -b original
  bw_commit_file "$t" a.txt one "O1 adds a"
  o1=$(git -C "$t" rev-parse HEAD)
  bw_commit_file "$t" dropped.txt secret "O2 adds dropped"
  o2=$(git -C "$t" rev-parse HEAD)
  c=$o2
  git -C "$t" push -q origin "HEAD:refs/heads/original"
  git -C "$t" checkout -q -b member "$BW_BASE"
  bw_commit_file "$t" a.txt one "rewritten: a"
  bw_commit_file "$t" h.txt present "rewritten: h"
  h=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/7/head"
  git -C "$t" checkout -q -b train "$BW_BASE"
  GIT_COMMITTER_DATE="2030-01-01T00:00:00Z" git -C "$t" cherry-pick "$o1" "$o2" >/dev/null
  if [ "${BW_PREREBASE_CARRIES:-0}" != 1 ]; then
    git -C "$t" rm -q -- dropped.txt
    git -C "$t" commit -q -m "revert O2"
  fi
  bw_commit_file "$t" h.txt present "train: h"
  bw_commit_file "$t" second.txt second "second member work"
  tr=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/9/head"
  git -C "$t" checkout -q main
  git -C "$t" merge -q --squash train >/dev/null
  git -C "$t" commit -q -m "train squash (#9)"
  BW_LANDING=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin main
  bw_commit_file "$t" a.txt "one, edited later" "main edits a.txt"
  git -C "$t" push -q origin main
  BW_MEMBER=$h
  BW_TRAIN=$tr
  BW_COPY=$c
}

test_a_prerebase_copy_whose_reverted_work_the_train_lacks_is_refused() {
  local control
  for control in 0 1; do
    BW_PREREBASE_CARRIES=$control bespoke_world "prerebase-reverted-$control" bw_steps_prerebase_reverted
    train_default_list "$TRAIN_CASE"
    git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_MEMBER_HEAD" "$TRAIN_COPY_HEAD" \
      && fail "prerebase-reverted-$control: the copy contains the member head"
    git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_COPY_HEAD:dropped.txt" 2>/dev/null \
      || fail "prerebase-reverted-$control: the copy lacks dropped.txt"
    if [ "$control" = 0 ]; then
      git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_HEAD:dropped.txt" 2>/dev/null && fail "prerebase-reverted: the train holds dropped.txt"
      git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_LANDING_COMMIT:dropped.txt" 2>/dev/null && fail "prerebase-reverted: the landing holds dropped.txt"
      assert_train_refused "$TRAIN_CASE" prerebase-reverted-copy "net change is not present in the train head's final tree"
      assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "prerebase-reverted-copy: the train was accepted"
    else
      git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_HEAD:dropped.txt" 2>/dev/null || fail "prerebase control: the train lacks dropped.txt"
      assert_train_allowed "$TRAIN_CASE" prerebase-carried-copy
    fi
  done
  BW_PREREBASE_CARRIES=0
  pass "a pre-rebase copy whose work the train replayed and then reverted is refused by content, and the same copy whose work the train kept is accepted"
}

# Main 2662 F1: a pre-rebase copy that stands on a commit the default branch reaches only through
# a merge that dropped it. The copy is clean at K (hidden.txt); the member head H sits on the merge M
# that took K in without its content; the train merges H and adds second.txt; a squash landing L.
# BW_PRE_HOW picks how M dropped K: ours (an `ours` merge), order (K is the first parent and the
# tree is D's), conflict (K and D add hidden.txt differently and the merge keeps D's), honest (a
# clean merge that keeps K's content, so K's content is on the default branch).
bw_steps_prerebase_on_dropped_commit() {  # <clone>
  local t=$1 k c d m tree h tr
  bw_commit_file "$t" base.txt base "baseline"
  git -C "$t" push -q origin main
  git -C "$t" checkout -q -b hidden
  bw_commit_file "$t" hidden.txt hidden "K adds hidden"
  k=$(git -C "$t" rev-parse HEAD)
  if [ "${BW_PRE_OWN:-0}" = 1 ]; then
    bw_commit_file "$t" a.txt one "O1 adds a, on K"
    c=$(git -C "$t" rev-parse HEAD)
  else
    c=$k
  fi
  git -C "$t" push -q origin "HEAD:refs/heads/hidden-k"
  git -C "$t" checkout -q main
  case "${BW_PRE_HOW:-ours}" in
    ours)
      git -C "$t" merge -q -s ours --no-edit "$k" >/dev/null ;;
    order | conflict)
      if [ "${BW_PRE_HOW}" = conflict ]; then
        bw_commit_file "$t" hidden.txt different-side "D adds hidden differently"
      else
        bw_commit_file "$t" side.txt side "D adds side"
      fi
      d=$(git -C "$t" rev-parse HEAD)
      git -C "$t" push -q origin main
      tree=$(git -C "$t" rev-parse "$d^{tree}")
      m=$(git -C "$t" commit-tree "$tree" -p "$k" -p "$d" -m "merge that kept the side's tree")
      git -C "$t" reset -q --hard "$m" ;;
    honest)
      bw_commit_file "$t" side.txt side "D adds side"
      git -C "$t" merge -q --no-ff --no-edit "$k" >/dev/null ;;
  esac
  # the recorded head replays the copy's own work (if any) on the default branch's tip
  git -C "$t" push -q origin main
  BW_BASE=$(git -C "$t" rev-parse HEAD)
  git -C "$t" checkout -q -b member
  if [ "${BW_PRE_OWN:-0}" = 1 ]; then
    bw_commit_file "$t" a.txt one "O1 adds a, replayed"
  fi
  bw_commit_file "$t" feature.txt feature "member adds feature"
  h=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/7/head"
  git -C "$t" checkout -q -b train
  git -C "$t" merge -q --no-ff --no-edit member >/dev/null 2>&1 || :
  bw_commit_file "$t" second.txt second "second member work"
  tr=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin "HEAD:refs/pull/9/head"
  git -C "$t" checkout -q main
  git -C "$t" merge -q --squash train >/dev/null
  git -C "$t" commit -q -m "train squash (#9)"
  BW_LANDING=$(git -C "$t" rev-parse HEAD)
  git -C "$t" push -q origin main
  bw_commit_file "$t" feature.txt "feature, edited later" "main edits feature.txt"
  git -C "$t" push -q origin main
  BW_MEMBER=$h
  BW_TRAIN=$tr
  BW_COPY=$c
}

test_a_prerebase_copy_built_on_an_ours_merged_commit_is_refused() {
  local how own
  for how in ours order conflict; do
    for own in 0 1; do
      BW_PRE_HOW=$how BW_PRE_OWN=$own bespoke_world "prerebase-dropped-$how-$own" bw_steps_prerebase_on_dropped_commit
      train_default_list "$TRAIN_CASE"
      git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_MEMBER_HEAD" "$TRAIN_COPY_HEAD" \
        && fail "prerebase-dropped-$how-$own: the copy contains the member head"
      [ "$own" = 1 ] || git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_COPY_HEAD" "$TRAIN_HEAD" \
        || fail "prerebase-dropped-$how-$own: the copy is not reachable from the train head"
      git -C "$TRAIN_CASE/wt" cat-file -e "$TRAIN_COPY_HEAD:hidden.txt" 2>/dev/null || fail "prerebase-dropped-$how-$own: the copy lacks hidden.txt"
      [ "$(git -C "$TRAIN_CASE/wt" show "$TRAIN_HEAD:hidden.txt" 2>/dev/null)" != hidden ] || fail "prerebase-dropped-$how-$own: the train holds K's hidden.txt"
      [ "$(git -C "$TRAIN_CASE/wt" show "$TRAIN_LANDING_COMMIT:hidden.txt" 2>/dev/null)" != hidden ] || fail "prerebase-dropped-$how-$own: the landing holds K's hidden.txt"
      assert_train_refused "$TRAIN_CASE" "prerebase-dropped-$how-$own" "${TRAIN_COPY_HEAD:0:12} stands on a commit that the default branch reached through a merge that is not what git makes of its parents"
      assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "prerebase-dropped-$how-$own: the train was accepted"
    done
  done
  BW_PRE_HOW=ours
  BW_PRE_OWN=0
  pass "a pre-rebase copy, with or without work of its own, that stands on a commit the default branch reached only through a merge that dropped it is refused, however the merge dropped it"
}

# The control of the same shape: the merge between the copy's base and the recorded base keeps
# the copy's content (a clean merge), so the copy is proven by content and accepted.
test_a_prerebase_copy_built_on_an_honestly_merged_commit_is_accepted() {
  BW_PRE_HOW=honest BW_PRE_OWN=1 bespoke_world prerebase-honest bw_steps_prerebase_on_dropped_commit
  BW_PRE_OWN=0
  train_default_list "$TRAIN_CASE"
  git -C "$TRAIN_CASE/wt" merge-base --is-ancestor "$TRAIN_MEMBER_HEAD" "$TRAIN_COPY_HEAD" \
    && fail "prerebase-honest: the copy contains the member head"
  [ "$(git -C "$TRAIN_CASE/wt" show "$TRAIN_HEAD:hidden.txt" 2>/dev/null)" = hidden ] || fail "prerebase-honest: the train lacks K's hidden.txt"
  run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
    || fail "prerebase-honest: a copy whose content the default branch kept was refused: $(cat "$TRAIN_CASE/stderr")"
  assert_absent "$TRAIN_CASE/state/task-x1.meta" "prerebase-honest: accepted teardown left the task record"
  BW_PRE_HOW=ours
  pass "a pre-rebase copy built on a commit the default branch merged honestly is accepted"
}

# Main 2679 F2: an empty measured change counts only from an X the exact-merge check proved. The pair:
# a pre-rebase copy that IS a commit behind the recorded base (so the change from X is empty) is
# accepted when every merge between it and the recorded base is exact, and refused when one is not.
test_an_empty_change_counts_only_behind_exact_merges() {
  local how
  for how in honest ours; do
    BW_PRE_HOW=$how BW_PRE_OWN=0 bespoke_world "empty-change-$how" bw_steps_prerebase_on_dropped_commit
    train_default_list "$TRAIN_CASE"
    [ "$TRAIN_COPY_HEAD" = "$(git -C "$TRAIN_CASE/wt" rev-parse "$(git -C "$TRAIN_CASE/wt" merge-base "$TRAIN_COPY_HEAD" "$TRAIN_BASE_OID")")" ] \
      || fail "empty-change-$how: the copy is not the merge base with the recorded base, so the measured change is not empty"
    if [ "$how" = honest ]; then
      run_teardown "$TRAIN_CASE" > "$TRAIN_CASE/stdout" 2> "$TRAIN_CASE/stderr" \
        || fail "empty-change-$how: an empty change behind only exact merges was refused: $(cat "$TRAIN_CASE/stderr")"
      assert_absent "$TRAIN_CASE/state/task-x1.meta" "empty-change-$how: accepted teardown left the task record"
    else
      assert_train_refused "$TRAIN_CASE" "empty-change-$how" "REFUSED"
      assert_no_grep "landed by a merged train" "$TRAIN_CASE/stderr" "empty-change-$how: the train was accepted"
    fi
  done
  BW_PRE_HOW=ours
  pass "an empty measured change is accepted behind only exact merges and refused behind one inexact merge"
}

teardown_test_cases=(
test_empty_recorded_slot_nested_drop
test_recorded_slot_lost_lease_still_refuses
test_recorded_slot_intact_lease_completes
test_local_only_fork_remote_allows
test_teardown_does_not_wait_for_the_home_summary_refresh
test_teardown_closes_the_backlog_item_itself
test_teardown_records_task_closed_once
test_teardown_closed_record_names_each_evidence_kind
test_teardown_refusal_and_failing_ledger_leave_teardown_alone
test_teardown_closes_a_gerrit_task_with_its_change_url_as_a_note
test_teardown_manual_backend_leaves_the_backlog_to_the_operator
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_pushed_branch_without_merge_refuses
test_drop_file_without_force_is_a_usage_error
test_forced_dirty_landed_deliverables_retain_captain_words
test_scout_report_must_be_a_regular_nonempty_file
test_no_mistakes_truly_unpushed_refuses
test_squash_merged_branch_deleted_allows
test_task_archives_reap_only_carried_refs
test_task_archives_ignore_other_tasks_and_non_custody_names
test_task_archives_keep_unproven_and_checked_out_refs
test_task_archives_keep_links_to_other_refs
test_task_archives_require_matching_squash_content
test_task_archives_include_deleted_and_literal_paths_in_merge_proof
test_task_archives_survive_refusal_and_forced_discard
test_task_archives_keep_refs_when_forge_is_unreachable
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_landed_proof_ignores_unresolvable_git_directory_in_cwd
test_merged_pr_with_later_local_commit_refuses
test_squash_merged_rebased_branch_allows
test_squash_merged_forgejo_pr_allows_when_main_moved_on
test_squash_merged_same_file_different_content_refuses
test_squash_merged_rebased_local_with_unlanded_commit_refuses
test_squash_merged_stale_local_refuses_when_forge_unreachable
test_squash_merged_pushed_prerebase_copy_allows
test_squash_pushed_missing_subject_match_ignores_hash_boundary
test_squash_merged_pushed_prerebase_copy_missing_commit_refuses
test_squash_merged_pushed_prerebase_copy_with_edited_merge_refuses
test_squash_merged_prerebase_copy_with_a_later_main_merge_allows
test_pipeline_input_diverged_iteration_allows
test_pipeline_input_rewritten_by_pipeline_allows
test_pipeline_input_slow_record_read_still_proves_the_copy
test_pipeline_input_silent_record_read_is_unknown
test_pipeline_input_locked_record_read_is_unknown
test_pipeline_input_refuses_copy_behind_the_input_head
test_pipeline_input_ties_the_run_by_pushed_head_allows
test_pipeline_input_refuses_commit_made_after_the_run_started
test_pipeline_input_refuses_copy_outside_the_run_input
test_pipeline_input_refuses_run_recorded_for_another_pr
test_pipeline_input_refuses_run_that_pushed_another_head
test_pipeline_input_refuses_when_the_state_database_is_missing
test_pipeline_input_refuses_when_the_input_head_is_not_recorded
test_pipeline_input_refuses_when_the_pushed_head_is_not_recorded
test_pipeline_input_refuses_when_the_run_table_lacks_the_input_column
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_train_member_closed_landed_by_merged_train_allows
test_train_member_prerebase_copy_allows
test_train_member_squash_landed_allows
test_train_member_copy_inside_train_allows
test_train_refuses_when_no_merged_pr_lists_the_member
test_train_refuses_a_listing_that_is_not_the_members_head
test_train_refuses_copy_work_the_train_does_not_carry
test_train_run_record_never_stands_in_for_carried_work
test_train_route_never_reads_the_run_record
test_train_ours_merged_commit_in_a_copy_never_counts_as_carried
test_train_ours_merged_commit_in_a_member_never_counts_as_carried
test_train_member_hidden_by_parent_order_is_never_taken_as_delivered
test_default_proof_refuses_a_commit_that_parent_order_put_on_the_first_parent_line
test_train_member_on_the_default_line_is_accepted_when_the_train_carried_it
test_a_failed_or_short_git_read_never_proves_content
test_train_member_carried_by_the_landing_is_accepted_after_a_later_default_merge
test_train_that_reverted_a_first_parent_member_is_refused
test_train_listing_with_a_longer_hex_token_is_not_a_listing
test_a_failed_patch_read_never_proves_a_replayed_patch
test_default_proof_refuses_a_third_version_conflict_resolution
test_default_proof_refuses_a_closed_copy_whose_lines_main_edited_later
test_a_prerebase_copy_whose_reverted_work_the_train_lacks_is_refused
test_a_prerebase_copy_built_on_an_ours_merged_commit_is_refused
test_a_prerebase_copy_built_on_an_honestly_merged_commit_is_accepted
test_an_empty_change_counts_only_behind_exact_merges
test_default_proof_refuses_work_whose_only_change_is_a_file_mode
test_train_that_restored_a_deleted_file_is_refused
test_train_with_many_unrelated_paths_still_accepts_its_member
test_a_failed_train_patch_read_is_unknown_in_every_route
test_an_unreadable_member_base_is_unknown_in_every_proof
test_default_proof_refuses_a_copy_that_restores_an_older_version
test_train_accepts_a_file_other_members_appended_to
test_train_landing_commit_that_is_a_plain_commit_without_the_change_is_refused
test_train_flat_carried_work_is_accepted_beside_an_ours_merge
test_train_flattened_rebase_carries_the_listed_head
test_train_flattened_rebase_missing_a_member_commit_refuses
test_train_flat_missing_with_a_stale_remote_ref_refuses
test_train_member_reread_failure_is_unknown
test_train_member_found_by_branch_is_not_looked_up_again
test_train_dirty_copy_refuses_before_the_train_is_read
test_train_refuses_a_train_that_is_not_merged
test_train_refuses_a_train_merged_into_another_branch
test_train_unreadable_forge_is_unknown_never_accepted
test_train_control_open_member_is_not_landed_by_a_train
test_train_control_merged_member_keeps_the_existing_route
test_train_control_content_proof_still_accepts_a_closed_member
test_train_record_only_route_fetches_a_stale_default_branch
test_default_proof_accepts_a_closed_member_whose_recorded_base_is_ahead_of_its_fork_point
test_train_member_whose_recorded_base_is_ahead_of_its_fork_point_allows
test_train_member_whose_recorded_base_is_ahead_still_refuses_unlanded_work
test_train_other_refusals_stay
test_train_reverted_member_never_counts_as_carried
test_train_reverted_member_is_refused_in_the_record_only_route
test_train_merge_commit_landed_carries_a_prerebase_copy
test_train_merge_commit_landed_carries_the_record_only_member
test_train_merge_commit_landed_still_refuses_uncarried_work
test_train_ours_merged_commit_is_never_taken_as_delivered
test_train_ours_merged_commit_is_refused_in_the_record_only_route
test_train_ours_merged_commit_is_carried_when_the_train_replays_it
test_default_proof_refuses_a_commit_the_default_branch_only_ours_merged
test_default_proof_refuses_an_ours_merged_commit_for_a_removed_copy
test_default_proof_refuses_a_local_only_branch_that_main_only_ours_merged
test_default_proof_refuses_a_reverted_member_landed_by_a_merge_commit
test_default_proof_still_accepts_genuine_landings
test_train_landing_commit_without_the_change_is_refused
test_train_landing_commit_off_the_default_line_is_refused
test_train_landing_commit_unreadable_is_unknown_not_unlanded
test_train_record_only_route_without_a_copy
test_train_member_removed_copy_in_pool_slot
test_teardown_removes_pr_ready_refusal_marker
test_content_fallback_uses_recorded_base_branch
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_untracked_only_refusal_diagnostic
test_tracked_edit_refusal_diagnostic
test_mixed_refusal_diagnostic
test_scout_nested_clone_returns_with_no_untracked_entries
test_ship_nested_clone_is_refused_and_bytes_stay
test_dirty_return_warns_which_slot_was_lost
test_dirty_return_warns_even_when_a_later_step_refuses
test_forced_secondmate_child_scout_nested_clone_returns_clean
test_forced_secondmate_dirty_child_return_warns_and_completes
test_return_that_removes_copy_warns_cannot_verify
test_scout_ignored_files_survive_scratch_clean
test_gh_error_and_content_absent_refuses
test_legacy_record_without_the_flag_refuses
test_windowless_legacy_record_with_gone_worktree_refuses
test_windowless_legacy_record_with_gone_worktree_refuses_with_legacy_flag
test_ship_without_git_copy_completes_with_recorded_merged_pr
test_ship_without_git_copy_refuses_unconfirmed_pr
test_ship_without_git_copy_requires_captain_words_to_drop
test_windowless_legacy_record_still_refuses_unlanded_work
test_windowless_record_outside_the_leftover_class_still_refuses
test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag
test_legacy_record_teardown_completes_when_landed_and_endpoint_dead
test_legacy_record_teardown_refuses_unlanded_work
test_legacy_record_teardown_refuses_an_ambiguous_endpoint
test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails
test_retained_legacy_stamp_still_faces_the_endpoint_gate
test_legacy_record_never_accepts_a_corrupt_spawn_gen
test_stale_index_lock_cleared_and_teardown_succeeds
test_idle_cwd_does_not_block_stale_index_lock_cleanup
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_index_lock_classifier_never_breaks_a_pipe_on_a_long_failure_text
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_verified_bundle_preserves_unlanded_copy
test_invalid_preservation_bundle_refuses
test_bundle_storage_inside_removal_root_refuses
test_bundle_storage_failure_keeps_copy
test_bundle_admission_stores_once
test_bundle_sources_and_durable_home_locations
test_bundle_with_malformed_commit_refuses
test_bundle_ignores_branches_other_worktrees_hold
test_bundle_covers_a_removed_copys_branch_without_other_worktrees
test_bundle_survives_a_stale_registered_worktree
test_bundle_ignores_unrelated_unheld_tip
test_bundle_restore_runs_once_per_unchanged_proof
test_bundle_restore_memo_misses_a_changed_record_or_bundle
test_bundle_restore_memo_is_keyed_by_object_format
test_unattended_teardown_refuses_bundle_only_copy
test_bundle_close_note_is_not_removal_authority
test_bundle_kept_ship_keeps_its_row_held_for_the_captain
test_bundle_kept_ship_records_no_landing_in_the_ledger
test_bundle_route_requires_the_captains_call
test_bundle_route_refuses_where_no_row_can_hold_the_call
test_landed_work_never_needs_the_captains_call
test_bundle_hint_needs_unlanded_tips
test_bundle_needs_the_copys_own_unlanded_tip
test_bundle_hint_skips_a_moved_head_at_final_custody
test_bundle_is_reverified_before_copy_removal
test_bundle_does_not_excuse_dirty_copy
test_bundle_does_not_excuse_nested_copy_ignored_files
test_bundle_sweep_keeps_anchored_and_landed_prior_ignored_files
test_bundle_removed_copy_sweep_refuses_before_retire
test_foreign_bundle_sweep_keeps_anchored_prior_ignored_files
test_foreign_bundle_preservation_keeps_other_proofs
)

fm_test_run_cases "${teardown_test_cases[@]}" -- "$@"
