#!/usr/bin/env bash
# fm-control.sh successor: record one successor task branch for a ship so the
# write profile of that task's NEXT launch covers it, and touch nothing else.
#
# These tests pin, hermetically over real throwaway git repositories:
#   1. RECORD-SUCCESSOR: one call records successor_branch= beside the prior
#      branch=, keeps the brief's Ship branch line, and a second identical call
#      changes nothing and says so. The line goes before any pr= line so the PR
#      monitor still parses the record.
#   2. PRESERVE-AND-RECEIPT: the call prints owner, action and a next command
#      that relaunch accepts, and reads, writes and signals nothing in either
#      work tree, the project's refs, the run-owned resources or the process
#      table; the relaunch that follows keeps both work trees and the run-owned
#      resources, apart from the named worker wiring files it always rewrites.
#   3. ADMISSION: every refusal names its missing proof and changes no byte of
#      the record, the brief, the profile, either work tree or the refs.
#   4. ATOMIC: a failure injected at each write step restores the record and
#      the brief; two calls on one task serialize on the lifecycle and
#      metadata locks.
#   5. PROFILE-COVERS (macOS): the profile the next relaunch generates differs
#      from the previous one by exactly the successor's literal allow lines.
#   6. UNCHANGED: --branch and --check stay refused on every other verb, and a
#      relaunch of a task with no successor generates the profile it always did.
# The real sandbox-exec confinement runs live in
# tests/fm-write-confinement-successor.test.sh.

# shellcheck source=tests/fm-control-relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-helpers.sh"
# shellcheck source=tests/fm-control-successor-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-successor-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

successor_cleanup() {
  successor_stop_sentinels
  successor_remove_task_tmp suc-
  relaunch_cleanup
}
trap successor_cleanup EXIT


commit_file() {  # <copy> <file> <text>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m "$3"
}

# The first real use's shape: a ship whose record names fm/<id>, with no pr=
# line, one copy with fm/<id>-v2 checked out and fm/<id> still behind it, a
# second task with its own copy, a fake gate repository and run files, and a
# live process standing in for the worker.
new_successor_case() {  # <name> <id>
  local id=$2 dir
  dir=$(new_case "$1" "$id")
  add_ship_task "$dir" "$id" claude
  git -C "$dir/wt" branch -m "task-$id" "fm/$id"
  commit_file "$dir/wt" work.txt "task work $id"
  git -C "$dir/wt" checkout -q -b "fm/$id-v2"
  commit_file "$dir/wt" v2.txt "v2 work $id"
  git -C "$dir/proj" worktree add -q -b "fm/other-$id" "$dir/wt-other"
  commit_file "$dir/wt-other" other.txt "other task work $id"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/wt"
    echo "project=$dir/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "branch=fm/$id"
    echo "tasktmp=/tmp/fm-$id"
    echo "write_confinement=seatbelt-v1"
    echo "model=default"
    echo "effort=default"
    echo "spawn_gen=s1.1.1"
  } > "$dir/home/state/$id.meta"
  {
    echo "window=fmses:fm-other-$id"
    echo "endpoint_task_id=other-$id"
    echo "worktree=$dir/wt-other"
    echo "project=$dir/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "branch=fm/other-$id"
    echo "tasktmp=/tmp/fm-other-$id"
    echo "model=default"
    echo "effort=default"
  } > "$dir/home/state/other-$id.meta"
  mkdir -p "$dir/home/data/other-$id"
  printf '# Task\nShip branch: fm/other-%s\n' "$id" > "$dir/home/data/other-$id/brief.md"
  cat >> "$dir/home/data/$id/brief.md" <<EOF

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/$id
EOF
  # Run-owned resources: the gate repository and the run's records, which live
  # outside both copies and outside the worker process.
  git init -q --bare "$dir/nm/repos/0123456789ab.git"
  git -C "$dir/nm/repos/0123456789ab.git" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit-tree -m run "$(git -C "$dir/nm/repos/0123456789ab.git" hash-object -t tree -w --stdin </dev/null)" \
    > "$dir/nm/run-head"
  git -C "$dir/nm/repos/0123456789ab.git" update-ref "refs/heads/no-mistakes/run-$id" "$(cat "$dir/nm/run-head")"
  mkdir -p "$dir/nm/runs" "$dir/nm/worktrees/run-$id"
  printf '{"run":"run-%s","status":"running"}\n' "$id" > "$dir/nm/runs/run-$id.json"
  printf 'pipeline scratch\n' > "$dir/nm/worktrees/run-$id/scratch.txt"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/nm-calls"
exit 0
SH
  chmod +x "$dir/fakebin/no-mistakes"
  : > "$dir/fake/nm-calls"
  printf '(version 1)\n(allow default)\n; sentinel profile for %s\n' "$id" > "$dir/home/state/$id.write-confinement.sb"
  make_continuation_owner_fixture "$dir"
  successor_ps_fallback "$dir"
  successor_start_sentinel "$dir"
  printf '%s\n' "$dir"
}

# One call of the verb under the case's home, as the lock-owning main session.
sc() {  # <case-dir> <id> <args...>
  local dir=$1 id=$2
  shift 2
  ( export NM_HOME="$dir/nm"; run_continuation_control "$dir" "$id" successor "$@" )
}

snap() {  # <case-dir> <tag>
  local dir=$1 tag=$2 pid
  mkdir -p "$dir/snap/$tag"
  fp "$dir/home/state" > "$dir/snap/$tag/state"
  fp "$dir/home/data" > "$dir/snap/$tag/data"
  fp "$dir/wt" > "$dir/snap/$tag/wt"
  fp "$dir/wt-other" > "$dir/snap/$tag/wt-other"
  fp "$dir/proj/.git" > "$dir/snap/$tag/proj-git"
  fp "$dir/nm" > "$dir/snap/$tag/nm"
  fp "$dir/fake" > "$dir/snap/$tag/fake"
  pid=$(cat "$dir/sentinel-pid")
  # The process table may be refused to a sandboxed worker; an unreadable table
  # is recorded as such and never compared as if it were empty.
  if /bin/ps -ax -o pid=,command= > "$dir/snap/$tag/ps.all" 2>/dev/null && [ -s "$dir/snap/$tag/ps.all" ]; then
    grep -F "$dir" "$dir/snap/$tag/ps.all" | grep -v 'grep -F' | LC_ALL=C sort > "$dir/snap/$tag/procs" || true
    grep -E "^ *$pid " "$dir/snap/$tag/ps.all" > "$dir/snap/$tag/sentinel" || true
  else
    printf 'process table unavailable\n' > "$dir/snap/$tag/procs"
    printf 'process table unavailable\n' > "$dir/snap/$tag/sentinel"
    [ -e "$TMP_ROOT/.ps-note" ] || { : > "$TMP_ROOT/.ps-note"; printf 'note: the process table is refused here, so process snapshots are not compared; liveness is checked with kill -0\n'; }
  fi
  rm -f "$dir/snap/$tag/ps.all"
  kill -0 "$pid" 2>/dev/null || fail "the stand-in worker process (pid $pid) is no longer alive"
}

same() {  # <case-dir> <before-tag> <after-tag> <what> <part>...
  local dir=$1 before=$2 after=$3 what=$4 part
  shift 4
  for part in "$@"; do
    cmp -s "$dir/snap/$before/$part" "$dir/snap/$after/$part" \
      || { diff "$dir/snap/$before/$part" "$dir/snap/$after/$part" | head -20 >&2; fail "$what changed $part"; }
  done
}

# Parse the three named receipt parts.
receipt_part() {  # <output> <name>
  printf '%s\n' "$1" | sed -n "s/^$2: //p"
}

meta_lines() {  # <case-dir> <id>
  cat "$1/home/state/$2.meta"
}

test_successor_records_the_branch_and_is_idempotent() {
  local id=suc-record dir out rc before_meta after_meta
  dir=$(new_successor_case record "$id")
  before_meta=$(meta_lines "$dir" "$id")
  cp "$dir/home/data/$id/brief.md" "$dir/brief.before"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --note "v2 continues the pipeline head") || rc=$?
  expect_code 0 "$rc" "recording a proved successor should succeed"$'\n'"$out"
  after_meta=$(meta_lines "$dir" "$id")
  assert_equals 1 "$(grep -c '^successor_branch=' "$dir/home/state/$id.meta")" "exactly one successor_branch= line must be recorded"
  assert_equals "successor_branch=fm/$id-v2" "$(grep '^successor_branch=' "$dir/home/state/$id.meta")" "the successor was not recorded literally"
  assert_equals "branch=fm/$id" "$(grep '^branch=' "$dir/home/state/$id.meta")" "the prior branch must stay recorded"
  assert_equals "$(printf '%s\n' "$before_meta" | sed "/^branch=fm\/$id\$/a\\
successor_branch=fm/$id-v2")" "$after_meta" "the record may gain only the successor line, directly after branch="
  assert_equals "Ship branch: fm/$id" "$(grep '^Ship branch:' "$dir/home/data/$id/brief.md")" "the brief's Ship branch line must stay equal to branch="
  assert_contains "$(cat "$dir/home/data/$id/brief.md")" "fm/$id-v2" "the brief must name the successor"
  assert_contains "$(cat "$dir/home/data/$id/brief.md")" "v2 continues the pipeline head" "the brief must carry the note"
  assert_contains "$out" "successor-recorded $id" "the first line must name the outcome"
  snap "$dir" once
  cp "$dir/home/state/$id.meta" "$dir/meta.once"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --note "v2 continues the pipeline head") || rc=$?
  expect_code 0 "$rc" "a second identical call should succeed as a no-op"$'\n'"$out"
  assert_contains "$out" "successor-already-recorded $id" "the second call must say it recorded nothing"
  snap "$dir" twice
  same "$dir" once twice "the second identical call" state data wt wt-other proj-git nm fake
  cmp -s "$dir/meta.once" "$dir/home/state/$id.meta" || fail "the second identical call changed the record"
  pass "successor: records successor_branch= beside the prior branch, keeps the Ship branch line, and a second identical call changes nothing and says so"
}

test_successor_goes_before_a_recorded_pr() {
  local id=suc-pr dir out rc
  dir=$(new_successor_case pr "$id")
  printf '%s\n' "pr=https://github.com/example/repo/pull/7" "pr_head=$(git -C "$dir/wt" rev-parse HEAD)" "egress=" >> "$dir/home/state/$id.meta"
  fm_pr_metadata_identity_parse "$dir/home/state/$id.meta" || fail "the fixture's PR record must parse before the call"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --note "v2 for the PR") || rc=$?
  expect_code 0 "$rc" "a task with a recorded PR may record a successor"$'\n'"$out"
  assert_equals "successor_branch=fm/$id-v2" "$(grep '^successor_branch=' "$dir/home/state/$id.meta")" "the successor was not recorded"
  [ "$(grep -n '^successor_branch=' "$dir/home/state/$id.meta" | cut -d: -f1)" -lt "$(grep -n '^pr=' "$dir/home/state/$id.meta" | cut -d: -f1)" ] \
    || fail "successor_branch= must come before the pr= line"
  fm_pr_metadata_identity_parse "$dir/home/state/$id.meta" \
    || fail "the PR monitor can no longer parse the record: successor_branch= was written after pr="
  assert_equals "https://github.com/example/repo/pull/7" "$FM_PR_META_URL" "the PR identity changed"
  pass "successor: the line goes before any pr= line, so the PR monitor still parses the record"
}

test_successor_receipt_names_owner_action_and_a_next_command_relaunch_accepts() {
  local id=suc-receipt dir out rc owner action next args
  dir=$(new_successor_case receipt "$id")
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --note "v2 continues the pipeline head") || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  owner=$(receipt_part "$out" owner)
  action=$(receipt_part "$out" action)
  next=$(receipt_part "$out" next)
  [ -n "$owner" ] || fail "the receipt has no owner part: $out"
  [ -n "$action" ] || fail "the receipt has no action part: $out"
  [ -n "$next" ] || fail "the receipt has no next part: $out"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^owner: ')" "the receipt must carry one owner line"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^action: ')" "the receipt must carry one action line"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^next: ')" "the receipt must carry one next line"
  assert_contains "$owner" "$dir/home" "the owner must name the lock-owning home"
  assert_contains "$action" "$id" "the action must name the task"
  assert_contains "$action" "fm/$id" "the action must name the prior branch"
  assert_contains "$action" "fm/$id-v2" "the action must name the successor"
  assert_contains "$action" "$dir/home/state/$id.meta" "the action must name the record it wrote"
  assert_contains "$action" "$dir/home/data/$id/brief.md" "the action must name the brief it wrote"
  assert_contains "$next" "$id relaunch" "the next command must be the relaunch of this task"
  # The command line parses and is the one relaunch accepts.
  case "$next" in
    "FM_HOME=$dir/home bash "*" $id relaunch "*) ;;
    *) fail "the next command has an unexpected shape: $next" ;;
  esac
  args=${next#*" $id relaunch "}
  eval "set -- $args"
  rc=0
  out=$(NM_HOME="$dir/nm" run_control "$dir" "$id" relaunch "$@") || rc=$?
  expect_code 0 "$rc" "the receipt's next command must be accepted by relaunch"$'\n'"$out"
  assert_contains "$out" "relaunched $id" "relaunch did not run the receipt's command"
  pass "successor: the receipt names owner, action and a next command that relaunch accepts"
}

test_successor_check_proves_and_writes_nothing() {
  local id=suc-check dir out rc
  dir=$(new_successor_case check "$id")
  snap "$dir" before
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --check) || rc=$?
  expect_code 0 "$rc" "--check of a proved successor should succeed"$'\n'"$out"
  assert_contains "$out" "successor-check $id" "--check must name its outcome"
  snap "$dir" after
  same "$dir" before after "--check" state data wt wt-other proj-git nm fake sentinel
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v3" --check) || rc=$?
  expect_code 1 "$rc" "--check of an unproved successor must refuse"$'\n'"$out"
  pass "successor: --check runs every proof and writes nothing"
}

test_successor_touches_no_tree_ref_process_run_or_profile_and_relaunch_keeps_them() {
  local id=suc-preserve dir out rc pid_before diff_wt diff_other changed
  dir=$(new_successor_case preserve "$id")
  snap "$dir" before
  pid_before=$(cat "$dir/sentinel-pid")
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --note "v2 continues the pipeline head") || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  snap "$dir" op
  git -C "$dir/proj" for-each-ref --format='%(refname) %(objectname)' > "$dir/refs.op"
  same "$dir" before op "the operation" wt wt-other proj-git nm fake sentinel procs
  kill -0 "$pid_before" 2>/dev/null || fail "the operation stopped the worker process"
  assert_equals "" "$(cat "$dir/fake/nm-calls")" "the operation called no-mistakes"
  cmp -s "$dir/snap/before/state" "$dir/snap/op/state" && fail "the record should have changed"
  grep -q "sentinel profile" "$dir/home/state/$id.write-confinement.sb" || fail "the operation rewrote the profile file"
  rc=0
  out=$(NM_HOME="$dir/nm" run_control "$dir" "$id" relaunch --note "apply the recorded successor") || rc=$?
  expect_code 0 "$rc" "the relaunch after the operation should succeed"$'\n'"$out"
  snap "$dir" relaunch
  same "$dir" op relaunch "the relaunch" nm
  successor_relaunch_git_changes "$dir/snap/op/proj-git" "$dir/snap/relaunch/proj-git" "the relaunch"
  assert_equals "$(git -C "$dir/proj" for-each-ref --format='%(refname) %(objectname)')" "$(cat "$dir/refs.op")" "the relaunch moved a project ref"
  diff_wt=$(diff "$dir/snap/op/wt" "$dir/snap/relaunch/wt" || true)
  diff_other=$(diff "$dir/snap/op/wt-other" "$dir/snap/relaunch/wt-other" || true)
  [ -z "$diff_other" ] || fail "the relaunch changed the other task's copy: $diff_other"
  # The worker wiring files are the only paths a relaunch rewrites in the copy.
  changed=$(printf '%s\n' "$diff_wt" | sed -n 's/^[<>] \(dir \)\{0,1\}\([^ ]*\) .*/\2/p' | LC_ALL=C sort -u | grep -v -e '^\.claude/settings\.local\.json$' -e '^\.fm-busy-stop$' -e '^\.claude$' -e '^dir \.claude' || true)
  [ -z "$changed" ] || fail "the relaunch changed task files beyond its worker wiring: $changed"
  printf 'note: relaunch rewrote only the worker wiring: %s\n' "$(printf '%s\n' "$diff_wt" | sed -n 's/^[<>] \(dir \)\{0,1\}\([^ ]*\) .*/\2/p' | LC_ALL=C sort -u | tr '\n' ' ')"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$(git -C "$dir/proj" rev-parse "fm/$id-v2")" ] || fail "the relaunch moved the task copy's HEAD"
  successor_assert_read_only_run_calls "$dir" "the relaunch"
  assert_equals "successor_branch=fm/$id-v2" "$(grep '^successor_branch=' "$dir/home/state/$id.meta")" "the relaunch lost the recorded successor"
  kill -0 "$pid_before" 2>/dev/null || fail "the relaunch signalled the unrelated worker process"
  pass "successor: the operation touches no tree, ref, process, run resource or profile, and the relaunch keeps both copies and the run-owned resources"
}

expect_successor_refusal() {  # <dir> <id> <label> <text> <code> <args...>
  local dir=$1 id=$2 label=$3 text=$4 code=$5 out rc=0
  shift 5
  snap "$dir" "pre-$label"
  out=$(sc "$dir" "$id" "$@") || rc=$?
  expect_code "$code" "$rc" "$label must refuse"$'\n'"$out"
  assert_contains "$out" "$text" "$label refused without naming the missing proof"
  snap "$dir" "post-$label"
  same "$dir" "pre-$label" "post-$label" "the refusal for $label" state data wt wt-other proj-git nm fake sentinel
}

test_successor_refuses_callers_without_authority() {
  local id=suc-authority dir foreign=
  dir=$(new_successor_case authority "$id")
  FM_FAKE_TASK_ID=$id expect_successor_refusal "$dir" "$id" worker "workers cannot record a successor branch" 1 \
    --branch "fm/$id-v2" --note why
  FM_FAKE_ACTOR=branch expect_successor_refusal "$dir" "$id" branch "the supervision branch never performs this action" 6 \
    --branch "fm/$id-v2" --note why
  /bin/sleep 0 &
  foreign=$!
  wait "$foreign"
  printf '%s\n' "$foreign" > "$dir/home/state/.lock"
  expect_successor_refusal "$dir" "$id" not-the-lock-owner "requires the actual lock-owning main Firstmate" 1 \
    --branch "fm/$id-v2" --note why
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  pass "successor: a worker, the supervision branch and a session that does not own the home lock are refused without changing anything"
}

test_successor_refuses_other_tasks_and_records() {
  local id=suc-kinds dir
  dir=$(new_successor_case kinds "$id")
  expect_successor_refusal "$dir" "no-such-task" unknown "no task 'no-such-task'" 1 --branch "fm/$id-v2" --note why
  printf 'remote_host=far.example\n' >> "$dir/home/state/$id.meta"
  expect_successor_refusal "$dir" "$id" remote "remotely placed" 1 --branch "fm/$id-v2" --note why
  sed -i.bak '/^remote_host=/d' "$dir/home/state/$id.meta" && rm -f "$dir/home/state/$id.meta.bak"
  sed -i.bak 's/^kind=ship$/kind=scout/' "$dir/home/state/$id.meta" && rm -f "$dir/home/state/$id.meta.bak"
  expect_successor_refusal "$dir" "$id" scout "applies to a ship" 1 --branch "fm/$id-v2" --note why
  sed -i.bak 's/^kind=scout$/kind=secondmate/' "$dir/home/state/$id.meta" && rm -f "$dir/home/state/$id.meta.bak"
  expect_successor_refusal "$dir" "$id" secondmate "applies to a ship" 1 --branch "fm/$id-v2" --note why
  sed -i.bak 's/^kind=secondmate$/kind=ship/' "$dir/home/state/$id.meta" && rm -f "$dir/home/state/$id.meta.bak"
  printf 'phase=start\ntask=%s\n' "$id" > "$dir/home/state/$id.control-relaunch"
  expect_successor_refusal "$dir" "$id" relaunch-transaction "unfinished relaunch transaction" 1 --branch "fm/$id-v2" --note why
  rm -f "$dir/home/state/$id.control-relaunch"
  : > "$dir/home/state/$id.backlog-close"
  expect_successor_refusal "$dir" "$id" backlog-close "pending authoritative backlog close" 1 --branch "fm/$id-v2" --note why
  rm -f "$dir/home/state/$id.backlog-close"
  rm -f "$dir/home/data/$id/brief.md"
  expect_successor_refusal "$dir" "$id" no-brief "no regular instructions file" 1 --branch "fm/$id-v2" --note why
  printf '# Task\nShip branch: fm/somewhere-else\n' > "$dir/home/data/$id/brief.md"
  expect_successor_refusal "$dir" "$id" brief-mismatch "Ship branch other than its recorded branch" 1 --branch "fm/$id-v2" --note why
  pass "successor: a scout, secondmate, remote or unknown task, an unfinished relaunch, a pending close and a bad brief refuse without changing anything"
}

test_successor_refuses_inadmissible_names() {
  local id=suc-names dir name
  dir=$(new_successor_case names "$id")
  # shellcheck disable=SC2016 # 'a$b' must reach the verb as a literal name, not expand.
  for name in 'bad..name' 'with space' 'wild*card' 'qu?stion' 'br[acket' '-leading' 'back\slash' '@{-1}' 'trailing.lock' 'trailing/' 'tab	name' 'qu"ote' "a'b" 'with#hash' 'a@b' 'a=b' 'a;b' 'a$b'; do
    expect_successor_refusal "$dir" "$id" "name-$name" "is not admissible" 1 --branch "$name" --note why
  done
  expect_successor_refusal "$dir" "$id" equals-branch "equals the task's recorded branch" 1 --branch "fm/$id" --note why
  expect_successor_refusal "$dir" "$id" archive-prefix "under archive/" 1 --branch "archive/$id-submitted-0123abcd" --note why
  printf 'base_branch=release\n' >> "$dir/home/state/$id.meta"
  expect_successor_refusal "$dir" "$id" base-branch "recorded base branch" 1 --branch release --note why
  expect_successor_refusal "$dir" "$id" other-tasks-branch "task other-$id already records it as its branch" 1 --branch "fm/other-$id" --note why
  printf 'successor_branch=fm/other-successor\n' >> "$dir/home/state/other-$id.meta"
  expect_successor_refusal "$dir" "$id" other-tasks-successor "task other-$id already records it as its successor branch" 1 --branch fm/other-successor --note why
  mkdir -p "$dir/home/data/bare-$id"
  { echo "kind=ship"; echo "project=$dir/proj"; } > "$dir/home/state/bare-$id.meta"
  expect_successor_refusal "$dir" "$id" other-tasks-default-branch "task bare-$id already records it as its branch" 1 --branch "fm/bare-$id" --note why
  pass "successor: a bad name, the recorded or base branch, an archive name and another task's branch or successor refuse without changing anything"
}

test_successor_refuses_unproved_successors() {
  local id=suc-proof dir
  dir=$(new_successor_case proof "$id")
  expect_successor_refusal "$dir" "$id" ref-missing "does not exist in the project's ref store" 1 --branch "fm/$id-v3" --note why
  git -C "$dir/proj" branch "fm/$id-v2b" "fm/$id-v2"
  expect_successor_refusal "$dir" "$id" not-checked-out "is not proved to be this task's successor" 1 --branch "fm/$id-v2b" --note why
  expect_successor_refusal "$dir" "$id" default-branch "is the project's default branch" 1 --branch main --note why
  git -C "$dir/wt-other" checkout -q -b "fm/$id-elsewhere"
  expect_successor_refusal "$dir" "$id" other-copys-branch "which is not this task's recorded copy" 1 --branch "fm/$id-elsewhere" --note why
  git -C "$dir/wt-other" checkout -q "fm/other-$id"
  git -C "$dir/wt" checkout -q -b "fm/$id-div" "fm/$id~1"
  commit_file "$dir/wt" div.txt "divergent work"
  expect_successor_refusal "$dir" "$id" not-a-descendant "is not an ancestor of the successor tip" 1 --branch "fm/$id-div" --note why
  git -C "$dir/wt" checkout -q "fm/$id-v2"
  git -C "$dir/proj" branch -q -m "fm/$id" "fm/$id-renamed"
  expect_successor_refusal "$dir" "$id" prior-missing "the recorded branch 'fm/$id' does not exist" 1 --branch "fm/$id-v2" --note why
  git -C "$dir/proj" branch -q -m "fm/$id-renamed" "fm/$id"
  git -C "$dir/wt" checkout -q --detach
  expect_successor_refusal "$dir" "$id" detached-copy "is not checked out in the recorded copy" 1 --branch "fm/$id-v2" --note why
  git -C "$dir/wt" checkout -q "fm/$id-v2"
  mv "$dir/wt" "$dir/wt-gone"
  expect_successor_refusal "$dir" "$id" copy-gone "recorded copy" 1 --branch "fm/$id-v2" --note why
  mv "$dir/wt-gone" "$dir/wt"
  # An archive branch that does not carry the task's own id, or whose hex is not its tip's, proves nothing.
  git -C "$dir/proj" branch "archive/other-$id-pipeline-$(git -C "$dir/proj" rev-parse --short=8 "fm/$id-v2b")" "fm/$id-v2b"
  git -C "$dir/proj" branch "archive/$id-pipeline-deadbeef" "fm/$id-v2b"
  expect_successor_refusal "$dir" "$id" foreign-archive "is not proved to be this task's successor" 1 --branch "fm/$id-v2b" --note why
  expect_successor_refusal "$dir" "$id" no-note "requires --note" 1 --branch "fm/$id-v2"
  expect_successor_refusal "$dir" "$id" no-branch "requires --branch" 1 --note why
  expect_successor_refusal "$dir" "$id" extra-worktree "successor takes only" 1 --branch "fm/$id-v2" --note why --worktree "$dir/wt"
  printf 'successor_branch=fm/%s-elder\n' "$id" >> "$dir/home/state/$id.meta"
  expect_successor_refusal "$dir" "$id" second-successor "already records successor branch fm/$id-elder" 1 --branch "fm/$id-v2" --note why
  pass "successor: a missing ref, the default branch, another copy's branch, a non-descendant, a missing prior branch, a detached or gone copy, a foreign archive, missing arguments and a second successor refuse without changing anything"
}

# A failure at each write step restores the record and the brief.
test_successor_failure_at_each_write_step_changes_nothing() {
  local id=suc-atomic dir step tool pattern out rc real
  for step in stage-brief stage-meta backup-meta backup-brief publish-brief publish-meta; do
    dir=$(new_successor_case "atomic-$step" "$id")
    case "$step" in
      stage-brief) tool=mktemp pattern='*/.brief.successor.*' ;;
      stage-meta) tool=mktemp pattern="*/.$id.meta.successor.*" ;;
      backup-meta) tool=mktemp pattern="*/.$id.meta.prior.*" ;;
      backup-brief) tool=mktemp pattern='*/.brief.prior.*' ;;
      publish-brief) tool=mv pattern='*/.brief.successor.*' ;;
      publish-meta) tool=mv pattern="*/.$id.meta.successor.*" ;;
    esac
    real=$(command -v "$tool")
    cat > "$dir/fakebin/$tool" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    $pattern) exit 1 ;;
  esac
done
exec "$real" "\$@"
SH
    chmod +x "$dir/fakebin/$tool"
    snap "$dir" before
    rc=0
    out=$(sc "$dir" "$id" --branch "fm/$id-v2" --note why) || rc=$?
    expect_code 1 "$rc" "a failure at $step must refuse"$'\n'"$out"
    snap "$dir" after
    same "$dir" before after "a failure at $step" state data wt wt-other proj-git nm sentinel
    assert_equals 0 "$(grep -c '^successor_branch=' "$dir/home/state/$id.meta")" "a failure at $step left a half-recorded successor"
    [ ! -e "$dir/home/state/.control-$id.lock" ] || fail "a failure at $step left the lifecycle lock behind"
    rm -f "$dir/fakebin/$tool"
    rc=0
    out=$(sc "$dir" "$id" --branch "fm/$id-v2" --note why) || rc=$?
    expect_code 0 "$rc" "after a failure at $step the same call must still succeed"$'\n'"$out"
  done
  pass "successor: a failure injected at each write step leaves the record and the brief exactly as before and no lock behind"
}

test_successor_serializes_on_the_lifecycle_and_metadata_locks() {
  local id=suc-locks dir out_a out_b rc_a=0 rc_b=0 i holder_pid meta_lock
  dir=$(new_successor_case locks "$id")
  # Call A parks at its record publication; call B, started meanwhile, must
  # refuse on the lifecycle lock and change nothing.
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */.$id.meta.successor.*)
      : > "$dir/parked"
      i=0
      while [ ! -e "$dir/release" ] && [ "\$i" -lt 2000 ]; do /bin/sleep 0.01; i=\$((i + 1)); done
      ;;
  esac
done
exec "$real_mv" "\$@"
SH
  chmod +x "$dir/fakebin/mv"
  sc "$dir" "$id" --branch "fm/$id-v2" --note why > "$dir/out-a" 2>&1 &
  holder_pid=$!
  i=0
  while [ ! -e "$dir/parked" ] && [ "$i" -lt 1000 ]; do /bin/sleep 0.01; i=$((i + 1)); done
  [ -e "$dir/parked" ] || fail "call A never reached its record publication"
  out_b=$(sc "$dir" "$id" --branch "fm/$id-v2" --note why) || rc_b=$?
  expect_code 1 "$rc_b" "a concurrent call must refuse on the lifecycle lock"$'\n'"$out_b"
  assert_contains "$out_b" "another lifecycle action is already running for task $id" "the concurrent call lost the lifecycle-lock refusal"
  assert_equals 0 "$(grep -c '^successor_branch=' "$dir/home/state/$id.meta")" "the concurrent call changed the record while call A held the locks"
  : > "$dir/release"
  wait "$holder_pid" || rc_a=$?
  out_a=$(cat "$dir/out-a")
  expect_code 0 "$rc_a" "call A should finish"$'\n'"$out_a"
  assert_equals 1 "$(grep -c '^successor_branch=' "$dir/home/state/$id.meta")" "exactly one successor line must remain"
  rm -f "$dir/fakebin/mv"
  # Metadata lock: held by another process, the call waits and writes nothing
  # until it is released.
  rm -f "$dir/release" "$dir/parked"
  dir=$(new_successor_case locks-meta "$id")
  meta_lock=$(FM_HOME="$dir/home" bash -c ". '$ROOT/bin/fm-wake-lib.sh' && fm_meta_lock_path '$dir/home/state/$id.meta'") || fail "cannot resolve the metadata lock path"
  (
    FM_HOME="$dir/home" bash -c ". '$ROOT/bin/fm-wake-lib.sh'; fm_lock_acquire_wait '$meta_lock' && : > '$dir/meta-held' && while [ ! -e '$dir/meta-release' ]; do /bin/sleep 0.01; done; fm_lock_release '$meta_lock'"
  ) &
  holder_pid=$!
  i=0
  while [ ! -e "$dir/meta-held" ] && [ "$i" -lt 1000 ]; do /bin/sleep 0.01; i=$((i + 1)); done
  [ -e "$dir/meta-held" ] || fail "the metadata lock holder never started"
  # The call parks at its record publication, so "has the call got past the lock"
  # is observed and not guessed from a fixed sleep: while another process holds
  # the metadata lock it must not reach the publication; once the lock is
  # released it must.
  cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */.$id.meta.successor.*)
      : > "$dir/parked"
      i=0
      while [ ! -e "$dir/release" ] && [ "\$i" -lt 2000 ]; do /bin/sleep 0.01; i=\$((i + 1)); done
      ;;
  esac
done
exec "$real_mv" "\$@"
SH
  chmod +x "$dir/fakebin/mv"
  sc "$dir" "$id" --branch "fm/$id-v2" --note why > "$dir/out-c" 2>&1 &
  rc_a=$!
  i=0
  while [ ! -e "$dir/parked" ] && [ "$i" -lt 400 ]; do /bin/sleep 0.01; i=$((i + 1)); done
  [ ! -e "$dir/parked" ] || fail "the call reached its record publication while another process held the metadata lock"
  assert_equals 0 "$(grep -c '^successor_branch=' "$dir/home/state/$id.meta")" "the call wrote while another process held the metadata lock"
  : > "$dir/meta-release"
  wait "$holder_pid" || true
  i=0
  while [ ! -e "$dir/parked" ] && [ "$i" -lt 1000 ]; do /bin/sleep 0.01; i=$((i + 1)); done
  [ -e "$dir/parked" ] || fail "the call did not reach its record publication once the metadata lock was released: $(cat "$dir/out-c")"
  : > "$dir/release"
  wait "$rc_a" || fail "the call did not finish once the metadata lock was released: $(cat "$dir/out-c")"
  assert_equals 1 "$(grep -c '^successor_branch=' "$dir/home/state/$id.meta")" "the call did not record after the metadata lock was released"
  pass "successor: two calls serialize on the lifecycle lock, and the call waits on the metadata lock before it writes"
}

# Darwin only: the profile the next relaunch generates differs from the previous
# one by exactly the successor's literal allow lines.
profile_without_session_lines() {  # <case-dir> <file> <session-id>...
  local file=$2 dir=$1 pattern=
  shift 2
  for s in "$@"; do pattern="$pattern -e $s"; done
  # shellcheck disable=SC2086
  if [ -n "$pattern" ]; then grep -v -F $pattern "$file"; else cat "$file"; fi | sed "s#$dir#<CASE>#g"
}

test_relaunch_profile_covers_exactly_the_recorded_successor() {
  local id=suc-profile dir out rc s0 s1 common
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: write confinement profiles are generated on macOS only; Linux remains unconfined\n'
    return 0
  fi
  dir=$(new_successor_case profile "$id")
  # The first relaunch creates the throwaway home's .claude folder, which the next
  # profile then also protects; create it first so the two profiles differ only by
  # the successor.
  mkdir -p "$dir/user-home/.claude"
  rc=0
  out=$(NM_HOME="$dir/nm" run_control "$dir" "$id" relaunch --note "baseline launch") || rc=$?
  expect_code 0 "$rc" "the baseline relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" write_confinement)" = seatbelt-v1 ] || fail "the fixture relaunch did not generate a profile"
  s0=$(meta_field "$dir" "$id" claude_session_id)
  cp "$dir/home/state/$id.write-confinement.sb" "$dir/profile.before"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --note why) || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  cmp -s "$dir/profile.before" "$dir/home/state/$id.write-confinement.sb" || fail "the operation changed the profile file"
  rc=0
  out=$(NM_HOME="$dir/nm" run_control "$dir" "$id" relaunch --note "apply the recorded successor") || rc=$?
  expect_code 0 "$rc" "the relaunch after recording should succeed"$'\n'"$out"
  s1=$(meta_field "$dir" "$id" claude_session_id)
  common=$(git -C "$dir/proj" rev-parse --path-format=absolute --git-common-dir)
  common=$(cd "$common" && pwd -P)
  profile_without_session_lines "$dir" "$dir/profile.before" "$s0" > "$dir/p0"
  profile_without_session_lines "$dir" "$dir/home/state/$id.write-confinement.sb" "$s1" > "$dir/p1"
  {
    for path in "$common/refs/heads/fm/$id-v2" "$common/logs/refs/heads/fm/$id-v2"; do
      printf '(allow file-write* (literal "%s"))\n' "$path"
      printf '(allow file-write* (literal "%s.lock"))\n' "$path"
    done
  } | sed "s#$dir#<CASE>#g" | LC_ALL=C sort > "$dir/expected-added"
  # Only allow lines are compared: the deny lines also name every sibling folder of
  # the shared Claude temp root at build time, which other sessions change between
  # the two builds and which has nothing to do with the successor.
  grep '^(allow' "$dir/p0" > "$dir/p0.allow"
  grep '^(allow' "$dir/p1" > "$dir/p1.allow"
  diff "$dir/p0.allow" "$dir/p1.allow" | sed -n 's/^> //p' | LC_ALL=C sort > "$dir/actual-added"
  assert_equals "" "$(diff "$dir/p0.allow" "$dir/p1.allow" | sed -n 's/^< //p')" "the new profile dropped an allow line the old one had"
  assert_equals "$(cat "$dir/expected-added")" "$(cat "$dir/actual-added")" "the profile may gain exactly the successor's four literal allow lines"
  pass "successor: the profile the next relaunch generates gains exactly the successor's literal allow lines"
}

test_relaunch_of_a_task_with_no_successor_generates_the_unchanged_profile() {
  local id=suc-unchanged dir out rc s common allowed
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: write confinement profiles are generated on macOS only; Linux remains unconfined\n'
    return 0
  fi
  dir=$(new_successor_case unchanged "$id")
  rc=0
  out=$(NM_HOME="$dir/nm" run_control "$dir" "$id" relaunch --note "no successor recorded") || rc=$?
  expect_code 0 "$rc" "a relaunch without a successor should succeed"$'\n'"$out"
  s=$(meta_field "$dir" "$id" claude_session_id)
  common=$(cd "$(git -C "$dir/proj" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)
  # Every allow line under refs/heads or logs/refs/heads: the task's branch and its
  # lock, with their reflog lines, as literals; the two archive rules; the two
  # archive folders. Nothing else.
  allowed=$(grep '^(allow' "$dir/home/state/$id.write-confinement.sb" | grep -E 'refs/heads')
  assert_equals 8 "$(printf '%s\n' "$allowed" | wc -l | tr -d ' ')" "a task with no successor must have exactly eight allow lines under refs/heads"
  assert_equals "$(printf '%s\n' \
    '(allow file-write* (literal "<COMMON>/logs/refs/heads/fm/'"$id"'"))' \
    '(allow file-write* (literal "<COMMON>/logs/refs/heads/fm/'"$id"'.lock"))' \
    '(allow file-write* (literal "<COMMON>/refs/heads/fm/'"$id"'"))' \
    '(allow file-write* (literal "<COMMON>/refs/heads/fm/'"$id"'.lock"))' | LC_ALL=C sort)" \
    "$(printf '%s\n' "$allowed" | grep '^(allow file-write\* (literal ' | sed "s#$common#<COMMON>#g" | LC_ALL=C sort)" \
    "a task with no successor must allow exactly its branch, its lock and their reflog lines as literals"
  assert_equals 2 "$(printf '%s\n' "$allowed" | grep -c '^(allow file-write\* (regex #.*refs/heads/archive/')" "the two archive rules must remain"
  assert_equals 2 "$(printf '%s\n' "$allowed" | grep -c '^(allow file-write-create (require-all (literal ')" "the two archive folders must remain"
  # The case root is random and the profile names it three ways: as written, as a
  # regex-escaped path, and as the dash-encoded Claude project folder name; each
  # becomes <CASE> so the digest compares across runs and trees.
  profile_without_session_lines "$dir" "$dir/home/state/$id.write-confinement.sb" "$s" | grep '^(allow' \
    | python3 -I -c 'import re, sys
root = sys.argv[1]
text = sys.stdin.read()
for form in (re.escape(root), root, re.sub(r"[^A-Za-z0-9]", "-", root)):
    text = text.replace(form, "<CASE>")
sys.stdout.write(text)' "$dir" | shasum -a 256 | cut -d' ' -f1 > "$dir/profile.digest"
  printf 'DIGEST no-successor-relaunch-profile=%s\n' "$(cat "$dir/profile.digest")"
  pass "successor: a relaunch of a task with no successor generates the profile it always did"
}

test_branch_and_check_stay_refused_on_every_other_verb() {
  local id=suc-others dir verb out rc
  dir=$(new_successor_case others "$id")
  for verb in interrupt exit stay adopt authorize-continuation relaunch reassociate; do
    for flag in "--branch fm/$id-v2" "--check"; do
      rc=0
      # shellcheck disable=SC2086
      out=$(run_continuation_control "$dir" "$id" "$verb" $flag) || rc=$?
      expect_code 1 "$rc" "$verb must still refuse '$flag'"$'\n'"$out"
      assert_contains "$out" "unexpected argument '${flag%% *}'" "$verb changed its refusal of '$flag'"
    done
  done
  pass "successor: --branch and --check stay refused, with the same message, on every other verb"
}

# C1: both routes admit only a name in the task's own family. Here the checked-out
# route: a branch of another lineage that descends from the recorded tip and is
# checked out in the recorded copy proves everything else and is still refused.
test_successor_name_family_bounds_the_checked_out_route() {
  local id=suc-family dir name out rc=0
  dir=$(new_successor_case family "$id")
  for name in develop release/1.x; do
    git -C "$dir/wt" checkout -q -b "$name" "fm/$id-v2"
    expect_successor_refusal "$dir" "$id" "family-${name%%/*}" "outside the task's own name family" 1 --branch "$name" --note why
    git -C "$dir/wt" checkout -q "fm/$id-v2"
    git -C "$dir/proj" branch -q -D "$name"
  done
  git -C "$dir/wt" checkout -q -b "fm/$id-v3"
  out=$(sc "$dir" "$id" --branch "fm/$id-v3" --check) || rc=$?
  expect_code 0 "$rc" "a name in the family, checked out in the copy and containing the recorded tip, is the matched control and must be admitted"$'\n'"$out"
  assert_contains "$out" "route=checked-out" "the control is proved by the checked-out route"
  pass "successor: develop and release/1.x are refused for the name family on the checked-out route, and a name in the family there is admitted"
}

# C2: the archive-tip route compares a successor's tip only with an archive branch
# named exactly archive/<task>-(submitted|pipeline)-<8 lowercase hex> whose hex
# is the first eight digits of its own tip. Each forged name below sits at the
# successor's tip and proves nothing; each exact name proves it.
test_successor_archive_route_admits_only_the_task_own_archive_names() {
  local id=suc-archive dir tree tip hex upper forged kind i=0 out rc
  dir=$(new_successor_case archive "$id")
  tree=$(git -C "$dir/proj" rev-parse "fm/$id-v2^{tree}")
  while :; do
    tip=$(git -C "$dir/proj" -c user.name=fmtest -c user.email=fmtest@example.invalid commit-tree -m "successor $i" -p "fm/$id-v2" "$tree")
    hex=$(printf '%s' "$tip" | cut -c1-8)
    case "$hex" in *[a-f]*) break ;; esac
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "no commit whose first eight hex digits hold a letter"
  done
  upper=$(printf '%s' "$hex" | tr 'a-f' 'A-F')
  git -C "$dir/proj" branch "fm/$id-v2b" "$tip"
  for forged in "archive/$id-other-$hex" "archive/other-$id-submitted-$hex" "archive/$id-pipeline-deadbeef" "archive/$id-submitted-$upper" "archive/$id-x-submitted-$hex"; do
    git -C "$dir/proj" branch "$forged" "$tip"
    expect_successor_refusal "$dir" "$id" "archive-${forged##*/}" "is not proved to be this task's successor" 1 --branch "fm/$id-v2b" --note why
    git -C "$dir/proj" branch -q -D "$forged"
  done
  for kind in submitted pipeline; do
    git -C "$dir/proj" branch "archive/$id-$kind-$hex" "$tip"
    rc=0
    out=$(sc "$dir" "$id" --branch "fm/$id-v2b" --check) || rc=$?
    expect_code 0 "$rc" "the exact archive/$id-$kind-<8 hex> name at the successor's tip is the matched control and must admit"$'\n'"$out"
    assert_contains "$out" "archive/$id-$kind-$hex" "the control names the archive branch that proved it"
    git -C "$dir/proj" branch -q -D "archive/$id-$kind-$hex"
  done
  pass "successor: the archive-tip route refuses another id, another task, a wrong or uppercase hex and an id-extending name, and admits the task's own submitted and pipeline archive names"
}

# C3: the receipt carries a structured route token and the guard writes one event
# at record time naming the route and the successor; a refusal writes a deny event
# naming the rule and the successor.
test_successor_receipt_and_events_name_the_checked_out_route() {
  local id=suc-route dir out rc=0 row
  dir=$(new_successor_case route "$id")
  : > "$FM_GUARD_EVENT_LOG"
  out=$(sc "$dir" "$id" --branch "fm/$id-v3" --note why) || rc=$?
  expect_code 1 "$rc" "an in-family branch that does not exist must refuse"$'\n'"$out"
  row=$(admission_event proof deny)
  [ -n "$row" ] || fail "no successor-branch-admission deny event was written for a refused proof"
  assert_equals "fm/$id-v3" "$(printf '%s' "$row" | jq -r .successor)" "the deny event must name the successor"
  assert_equals "$id" "$(printf '%s' "$row" | jq -r .task)" "the deny event must name the task"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --note why) || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  assert_contains "$out" "route: route=checked-out successor=fm/$id-v2" "the receipt must carry the structured route and the successor"
  row=$(admission_event record allow)
  [ -n "$row" ] || fail "no successor-branch-admission allow event was written at record time"
  assert_equals checked-out "$(printf '%s' "$row" | jq -r .route)" "the record-time event must name the route"
  assert_equals "fm/$id-v2" "$(printf '%s' "$row" | jq -r .successor)" "the record-time event must name the successor"
  assert_equals "$id" "$(printf '%s' "$row" | jq -r .task)" "the record-time event must name the task"
  pass "successor: the receipt names route=checked-out, and the guard writes an allow event with route and successor at record time and a deny event with the successor for a refusal"
}

# C6: every comparison against another task's branch or successor, the recorded
# branch, the base branch and the default branch ignores case. The control is a
# name that differs by more than case.
test_successor_names_compare_without_regard_to_case() {
  local id=suc-case dir out rc=0 upper_id
  dir=$(new_successor_case case "$id")
  upper_id=$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')
  expect_successor_refusal "$dir" "$id" case-other-branch "task other-$id already records it as its branch" 1 --branch "FM/OTHER-$upper_id" --note why
  expect_successor_refusal "$dir" "$id" case-other-branch-mixed "task other-$id already records it as its branch" 1 --branch "Fm/other-$id" --note why
  expect_successor_refusal "$dir" "$id" case-recorded "equals the task's recorded branch" 1 --branch "FM/$upper_id" --note why
  printf 'base_branch=release\n' >> "$dir/home/state/$id.meta"
  expect_successor_refusal "$dir" "$id" case-base "recorded base branch" 1 --branch RELEASE --note why
  expect_successor_refusal "$dir" "$id" case-default "is the project's default branch" 1 --branch MAIN --note why
  printf 'successor_branch=fm/other-successor\n' >> "$dir/home/state/other-$id.meta"
  expect_successor_refusal "$dir" "$id" case-other-successor "task other-$id already records it as its successor branch" 1 --branch FM/Other-Successor --note why
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --check) || rc=$?
  expect_code 0 "$rc" "a name that differs from every compared name by more than case must be admitted"$'\n'"$out"
  pass "successor: a case variant of another task's branch or successor, the recorded, base or default branch is refused, and a name that differs by more than case is admitted"
}

# C8: the registry owns the admission decision. The real metrics reader, run over the
# events a refusal and a record wrote, knows the guard and its harm only when the
# registry holds the entry, and the spawn-write-confinement entry names the permit.
test_registry_owns_the_successor_admission_and_the_reader_attributes_it() {
  local id=suc-registry dir out rc=0 report registry=$ROOT/docs/guards/registry.json
  dir=$(new_successor_case registry "$id")
  : > "$FM_GUARD_EVENT_LOG"
  sc "$dir" "$id" --branch "fm/$id-v3" --note why >/dev/null || true
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --note why) || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  report=$(env -u FM_TASK_ID bash "$ROOT/bin/fm-guard-metrics.sh" --log "$FM_GUARD_EVENT_LOG" --guards successor-branch-admission --json) \
    || fail "the metrics reader failed: $report"
  assert_equals irreversible "$(printf '%s' "$report" | jq -r '.guards[0].harm')" "the registry must own successor-branch-admission, or the reader cannot name its harm"
  assert_equals 1 "$(printf '%s' "$report" | jq -r '.guards[0].allows')" "the reader must count the record-time allow"
  assert_equals 1 "$(printf '%s' "$report" | jq -r '.guards[0].denies')" "the reader must count the refusal"
  jq -e '.guards[] | select(.id == "successor-branch-admission") | select(.owner == "bin/fm-successor-branch-lib.sh" and .decision == "deny" and .fail_direction == "closed" and .instrumented == true)' "$registry" >/dev/null \
    || fail "the registry must hold a closed, instrumented deny guard owned by the successor library"
  jq -e '.guards[] | select(.id == "spawn-write-confinement") | .layer_note | test("successor-branch-admission")' "$registry" >/dev/null \
    || fail "the spawn-write-confinement entry must name the successor permit"
  pass "successor: the registry holds the admission guard, the reader attributes the record and the refusal to it, and spawn-write-confinement names the permit"
}

control_relaunch_test_cases=(
test_successor_records_the_branch_and_is_idempotent
test_successor_goes_before_a_recorded_pr
test_successor_receipt_names_owner_action_and_a_next_command_relaunch_accepts
test_successor_check_proves_and_writes_nothing
test_successor_touches_no_tree_ref_process_run_or_profile_and_relaunch_keeps_them
test_successor_refuses_callers_without_authority
test_successor_refuses_other_tasks_and_records
test_successor_refuses_inadmissible_names
test_successor_refuses_unproved_successors
test_successor_name_family_bounds_the_checked_out_route
test_successor_archive_route_admits_only_the_task_own_archive_names
test_successor_receipt_and_events_name_the_checked_out_route
test_successor_names_compare_without_regard_to_case
test_registry_owns_the_successor_admission_and_the_reader_attributes_it
test_successor_failure_at_each_write_step_changes_nothing
test_successor_serializes_on_the_lifecycle_and_metadata_locks
test_relaunch_profile_covers_exactly_the_recorded_successor
test_relaunch_of_a_task_with_no_successor_generates_the_unchanged_profile
test_branch_and_check_stay_refused_on_every_other_verb
)

control_relaunch_run "$@"
