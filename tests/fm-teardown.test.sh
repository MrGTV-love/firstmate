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
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-helpers.sh"

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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
  fm_test_wait_until 60 jq -e --arg id task-x1 "
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
  fm_test_wait_until 20 test -e "$marker" || { kill "$holder" 2>/dev/null; fail "could not hold the refresh lock"; }
  set +e
  FM_HOME_SUMMARY_TIMEOUT=20 run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown should succeed with a refresh in flight"
  fm_test_wait_until 60 test -e "$case_dir/state/.home-summary-refresh.pending" \
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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  FM_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  assert_present "$case_dir/treehouse.log" \
    "content-landed: teardown never reached destructive worktree cleanup"
  assert_absent "$case_dir/state/task-x1.meta" \
    "content-landed: teardown left task metadata after destructive cleanup"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
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

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
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

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "legacy-stamp-rollback: an unrecordable close must fail the teardown after accepting the legacy record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the failed marker write left the record modified"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-rollback: the failed teardown closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
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

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
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
  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
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

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout3" 2> "$case_dir/stderr3"
  rc=$?
  set -e
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

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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
  # Reuse the measured 200-poll ceiling documented in git-lock-helpers.sh.
  fm_test_wait_until 20 "$REAL_LSOF_FOR_TEST" -a -p "$idle" -d cwd -- "$case_dir/wt" \
    || fail "idle-index-lock: process did not enter worktree cwd"
  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=30 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
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

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

teardown_test_cases=(
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
test_task_archives_require_matching_squash_content
test_task_archives_include_deleted_and_literal_paths_in_merge_proof
test_task_archives_survive_refusal_and_forced_discard
test_task_archives_keep_refs_when_forge_is_unreachable
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
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
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
)

# Validate the complete selection before running any behavioral case.
for requested_case in "$@"; do
  registered_case=false
  for test_case in "${teardown_test_cases[@]}"; do
    if [ "$requested_case" = "$test_case" ]; then
      registered_case=true
      break
    fi
  done
  if [ "$registered_case" = false ]; then
    printf 'Unknown test case: %s\n' "$requested_case" >&2
    printf 'Usage: bash tests/fm-teardown.test.sh [test_function_name ...]\n' >&2
    exit 2
  fi
done

for test_case in "${teardown_test_cases[@]}"; do
  if [ "$#" -eq 0 ]; then
    "$test_case"
    continue
  fi
  for requested_case in "$@"; do
    if [ "$requested_case" = "$test_case" ]; then
      "$test_case"
      break
    fi
  done
done
