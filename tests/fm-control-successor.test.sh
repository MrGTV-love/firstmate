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
#   6. UNCHANGED: --branch stays refused on every other verb, and a relaunch of
#      a task with no successor generates the profile it always did.
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

# The tip of a branch of the case's project, as Main reads it; empty when absent.
tip_of() {  # <case-dir> <branch>
  git -C "$1/proj" rev-parse --verify --quiet "refs/heads/$2" 2>/dev/null || true
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
  local id=suc-record dir out rc before_meta after_meta prior_tip
  dir=$(new_successor_case record "$id")
  before_meta=$(meta_lines "$dir" "$id")
  cp "$dir/home/data/$id/brief.md" "$dir/brief.before"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note "v2 continues the pipeline head") || rc=$?
  expect_code 0 "$rc" "recording a proved successor should succeed"$'\n'"$out"
  after_meta=$(meta_lines "$dir" "$id")
  assert_equals 1 "$(grep -c '^successor_branch=' "$dir/home/state/$id.meta")" "exactly one successor_branch= line must be recorded"
  assert_equals "successor_branch=fm/$id-v2" "$(grep '^successor_branch=' "$dir/home/state/$id.meta")" "the successor was not recorded literally"
  assert_equals "branch=fm/$id" "$(grep '^branch=' "$dir/home/state/$id.meta")" "the prior branch must stay recorded"
  prior_tip=$(git -C "$dir/proj" rev-parse "fm/$id")
  assert_equals "$(printf '%s\n' "$before_meta" | awk -v b="branch=fm/$id" -v s="fm/$id-v2" -v t="$prior_tip" \
    '{ print } $0 == b { print "successor_branch=" s; print "successor_proved_tip=" t }')" "$after_meta" \
    "the record may gain only the successor line and its proved tip (the recorded branch's tip), directly after branch="
  assert_contains "$out" "proved_tip=$prior_tip" "the receipt must name the proved tip"
  assert_equals "Ship branch: fm/$id" "$(grep '^Ship branch:' "$dir/home/data/$id/brief.md")" "the brief's Ship branch line must stay equal to branch="
  assert_contains "$(cat "$dir/home/data/$id/brief.md")" "fm/$id-v2" "the brief must name the successor"
  assert_contains "$(cat "$dir/home/data/$id/brief.md")" "v2 continues the pipeline head" "the brief must carry the note"
  assert_contains "$out" "successor-recorded $id" "the first line must name the outcome"
  snap "$dir" once
  cp "$dir/home/state/$id.meta" "$dir/meta.once"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note "v2 continues the pipeline head") || rc=$?
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
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note "v2 for the PR") || rc=$?
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
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note "v2 continues the pipeline head") || rc=$?
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

test_successor_touches_no_tree_ref_process_run_or_profile_and_relaunch_keeps_them() {
  local id=suc-preserve dir out rc pid_before diff_wt diff_other changed
  dir=$(new_successor_case preserve "$id")
  snap "$dir" before
  pid_before=$(cat "$dir/sentinel-pid")
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note "v2 continues the pipeline head") || rc=$?
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
    --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  FM_FAKE_ACTOR=branch expect_successor_refusal "$dir" "$id" branch "the supervision branch never performs this action" 6 \
    --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  /bin/sleep 0 &
  foreign=$!
  wait "$foreign"
  printf '%s\n' "$foreign" > "$dir/home/state/.lock"
  expect_successor_refusal "$dir" "$id" not-the-lock-owner "requires the actual lock-owning main Firstmate" 1 \
    --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  pass "successor: a worker, the supervision branch and a session that does not own the home lock are refused without changing anything"
}

test_successor_refuses_other_tasks_and_records() {
  local id=suc-kinds dir
  dir=$(new_successor_case kinds "$id")
  expect_successor_refusal "$dir" "no-such-task" unknown "no task 'no-such-task'" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  printf 'remote_host=far.example\n' >> "$dir/home/state/$id.meta"
  expect_successor_refusal "$dir" "$id" remote "remotely placed" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  sed -i.bak '/^remote_host=/d' "$dir/home/state/$id.meta" && rm -f "$dir/home/state/$id.meta.bak"
  sed -i.bak 's/^kind=ship$/kind=scout/' "$dir/home/state/$id.meta" && rm -f "$dir/home/state/$id.meta.bak"
  expect_successor_refusal "$dir" "$id" scout "applies to a ship" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  sed -i.bak 's/^kind=scout$/kind=secondmate/' "$dir/home/state/$id.meta" && rm -f "$dir/home/state/$id.meta.bak"
  expect_successor_refusal "$dir" "$id" secondmate "applies to a ship" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  sed -i.bak 's/^kind=secondmate$/kind=ship/' "$dir/home/state/$id.meta" && rm -f "$dir/home/state/$id.meta.bak"
  printf 'phase=start\ntask=%s\n' "$id" > "$dir/home/state/$id.control-relaunch"
  expect_successor_refusal "$dir" "$id" relaunch-transaction "unfinished relaunch transaction" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  rm -f "$dir/home/state/$id.control-relaunch"
  : > "$dir/home/state/$id.backlog-close"
  expect_successor_refusal "$dir" "$id" backlog-close "pending authoritative backlog close" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  rm -f "$dir/home/state/$id.backlog-close"
  rm -f "$dir/home/data/$id/brief.md"
  expect_successor_refusal "$dir" "$id" no-brief "no regular instructions file" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  printf '# Task\nShip branch: fm/somewhere-else\n' > "$dir/home/data/$id/brief.md"
  expect_successor_refusal "$dir" "$id" brief-mismatch "Ship branch other than its recorded branch" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  pass "successor: a scout, secondmate, remote or unknown task, an unfinished relaunch, a pending close and a bad brief refuse without changing anything"
}

test_successor_refuses_inadmissible_names() {
  local id=suc-names dir name
  dir=$(new_successor_case names "$id")
  # Each name is refused by the check that owns it, and the refusal names that
  # check: the character rule for the names below, git's own name rule for the
  # ones after them. The family bound would refuse every one of them too, so the
  # reason text is what shows the earlier check still works.
  # shellcheck disable=SC2016 # 'a$b' must reach the verb as a literal name, not expand.
  for name in 'with space' 'wild*card' 'qu?stion' 'br[acket' '-leading' 'back\slash' '@{-1}' 'tab	name' 'qu"ote' "a'b" 'with#hash' 'a@b' 'a=b' 'a;b' 'a$b'; do
    expect_successor_refusal "$dir" "$id" "name-$name" "it may use only letters, digits" 1 --branch "$name" --note why
  done
  for name in 'bad..name' 'trailing.lock' 'trailing/'; do
    expect_successor_refusal "$dir" "$id" "name-$name" "it is not a valid git branch name" 1 --branch "$name" --note why
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
  expect_successor_refusal "$dir" "$id" ref-missing "does not exist in the project's ref store" 1 --branch "fm/$id-v3" --tip "$(tip_of "$dir" "fm/$id")" --note why
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
  expect_successor_refusal "$dir" "$id" prior-missing "the recorded branch 'fm/$id' does not exist" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  git -C "$dir/proj" branch -q -m "fm/$id-renamed" "fm/$id"
  git -C "$dir/wt" checkout -q --detach
  expect_successor_refusal "$dir" "$id" detached-copy "is not checked out in the recorded copy" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  git -C "$dir/wt" checkout -q "fm/$id-v2"
  mv "$dir/wt" "$dir/wt-gone"
  expect_successor_refusal "$dir" "$id" copy-gone "recorded copy" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
  mv "$dir/wt-gone" "$dir/wt"
  # An archive branch that does not carry the task's own id, or whose hex is not its tip's, proves nothing.
  git -C "$dir/proj" branch "archive/other-$id-pipeline-$(git -C "$dir/proj" rev-parse --short=8 "fm/$id-v2b")" "fm/$id-v2b"
  git -C "$dir/proj" branch "archive/$id-pipeline-deadbeef" "fm/$id-v2b"
  expect_successor_refusal "$dir" "$id" foreign-archive "is not proved to be this task's successor" 1 --branch "fm/$id-v2b" --note why
  expect_successor_refusal "$dir" "$id" no-note "requires --note" 1 --branch "fm/$id-v2"
  expect_successor_refusal "$dir" "$id" no-branch "requires --branch" 1 --note why
  expect_successor_refusal "$dir" "$id" extra-worktree "successor takes only" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why --worktree "$dir/wt"
  printf 'successor_branch=fm/%s-elder\n' "$id" >> "$dir/home/state/$id.meta"
  expect_successor_refusal "$dir" "$id" second-successor "already records successor branch fm/$id-elder" 1 --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why
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
    out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
    expect_code 1 "$rc" "a failure at $step must refuse"$'\n'"$out"
    snap "$dir" after
    same "$dir" before after "a failure at $step" state data wt wt-other proj-git nm sentinel
    assert_equals 0 "$(grep -c '^successor_branch=' "$dir/home/state/$id.meta")" "a failure at $step left a half-recorded successor"
    [ ! -e "$dir/home/state/.control-$id.lock" ] || fail "a failure at $step left the lifecycle lock behind"
    rm -f "$dir/fakebin/$tool"
    rc=0
    out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
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
  sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why > "$dir/out-a" 2>&1 &
  holder_pid=$!
  i=0
  while [ ! -e "$dir/parked" ] && [ "$i" -lt 1000 ]; do /bin/sleep 0.01; i=$((i + 1)); done
  [ -e "$dir/parked" ] || fail "call A never reached its record publication"
  out_b=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc_b=$?
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
  sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why > "$dir/out-c" 2>&1 &
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
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  cmp -s "$dir/profile.before" "$dir/home/state/$id.write-confinement.sb" || fail "the operation changed the profile file"
  rc=0
  out=$(NM_HOME="$dir/nm" run_control "$dir" "$id" relaunch --note "apply the recorded successor") || rc=$?
  expect_code 0 "$rc" "the relaunch after recording should succeed"$'\n'"$out"
  s1=$(meta_field "$dir" "$id" claude_session_id)
  common=$(git -C "$dir/proj" rev-parse --path-format=absolute --git-common-dir)
  common=$(cd "$common" && pwd -P)
  profile_without_session_lines "$dir" "$dir/profile.before" "$s0" | profile_comparable > "$dir/p0"
  profile_without_session_lines "$dir" "$dir/home/state/$id.write-confinement.sb" "$s1" | profile_comparable > "$dir/p1"
  {
    for path in "$common/refs/heads/fm/$id-v2" "$common/logs/refs/heads/fm/$id-v2"; do
      printf '(allow file-write* (literal "%s"))\n' "$path"
      printf '(allow file-write* (literal "%s.lock"))\n' "$path"
    done
  } | sed "s#$dir#<CASE>#g" | LC_ALL=C sort > "$dir/expected-added"
  # Every allow and deny line is compared (profile_comparable leaves out only the
  # per-session sibling folders of Claude's shared temp root): the new profile may gain
  # the four literal allow lines and may drop nothing, so a removed deny is seen.
  diff "$dir/p0" "$dir/p1" | sed -n 's/^> //p' | LC_ALL=C sort > "$dir/actual-added"
  assert_equals "" "$(diff "$dir/p0" "$dir/p1" | sed -n 's/^< //p')" "the new profile dropped a line the old one had"
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
  profile_without_session_lines "$dir" "$dir/home/state/$id.write-confinement.sb" "$s" | profile_comparable \
    | python3 -I -c 'import re, sys
root = sys.argv[1]
text = sys.stdin.read()
for form in (re.escape(root), root, re.sub(r"[^A-Za-z0-9]", "-", root)):
    text = text.replace(form, "<CASE>")
# the relaunch makes one sibling temp folder with mktemp; its random suffix is not part of the profile rules
text = re.sub(r"fm-control-relaunch\.[A-Za-z0-9]+", "fm-control-relaunch.<RAND>", text)
sys.stdout.write(text)' "$dir" | shasum -a 256 | cut -d' ' -f1 > "$dir/profile.digest"
  printf 'DIGEST no-successor-relaunch-profile=%s\n' "$(cat "$dir/profile.digest")"
  pass "successor: a relaunch of a task with no successor generates the profile it always did"
}

test_branch_stays_refused_on_every_other_verb() {
  local id=suc-others dir verb out rc
  dir=$(new_successor_case others "$id")
  for verb in interrupt exit stay adopt authorize-continuation relaunch reassociate; do
    rc=0
    out=$(run_continuation_control "$dir" "$id" "$verb" --branch "fm/$id-v2") || rc=$?
    expect_code 1 "$rc" "$verb must still refuse '--branch'"$'\n'"$out"
    assert_contains "$out" "unexpected argument '--branch'" "$verb changed its refusal of '--branch'"
  done
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --check) || rc=$?
  expect_code 1 "$rc" "successor has no --check mode"$'\n'"$out"
  assert_contains "$out" "unexpected argument '--check'" "successor must refuse --check as an unknown argument"
  pass "successor: --branch stays refused, with the same message, on every other verb, and successor takes no --check"
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
  out=$(sc "$dir" "$id" --branch "fm/$id-v3" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
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
    expect_successor_refusal "$dir" "$id" "archive-${forged##*/}" "is not proved to be this task's successor" 1 --branch "fm/$id-v2b" --tip "$tip" --note why
    git -C "$dir/proj" branch -q -D "$forged"
  done
  cp -p "$dir/home/state/$id.meta" "$dir/meta.pre"
  cp -p "$dir/home/data/$id/brief.md" "$dir/brief.pre"
  for kind in submitted pipeline; do
    git -C "$dir/proj" branch "archive/$id-$kind-$hex" "$tip"
    rc=0
    out=$(sc "$dir" "$id" --branch "fm/$id-v2b" --tip "$tip" --note why) || rc=$?
    expect_code 0 "$rc" "the exact archive/$id-$kind-<8 hex> name at the successor's tip is the matched control and must admit"$'\n'"$out"
    assert_contains "$out" "archive/$id-$kind-$hex" "the control names the archive branch that proved it"
    assert_equals "successor_proved_tip=$tip" "$(grep '^successor_proved_tip=' "$dir/home/state/$id.meta")" "the record must carry the archive's tip as the proved tip"
    git -C "$dir/proj" branch -q -D "archive/$id-$kind-$hex"
    cp -p "$dir/meta.pre" "$dir/home/state/$id.meta"
    cp -p "$dir/brief.pre" "$dir/home/data/$id/brief.md"
  done
  pass "successor: the archive-tip route refuses another id, another task, a wrong or uppercase hex and an id-extending name, and admits the task's own submitted and pipeline archive names"
}

# The archive-tip route admits a branch whose history contains the task's own archive
# tip, not only one equal to it, and records that archive tip as the proved tip. A
# branch whose history lacks every archive tip of the task stays refused.
test_successor_archive_route_admits_a_branch_past_the_archive_tip() {
  local id=suc-past dir tree tip past other hex out rc
  dir=$(new_successor_case past "$id")
  tree=$(git -C "$dir/proj" rev-parse "fm/$id-v2^{tree}")
  tip=$(git -C "$dir/proj" -c user.name=fmtest -c user.email=fmtest@example.invalid commit-tree -m "archived head" -p "fm/$id-v2" "$tree")
  hex=$(printf '%s' "$tip" | cut -c1-8)
  git -C "$dir/proj" branch "archive/$id-pipeline-$hex" "$tip"
  past=$(git -C "$dir/proj" -c user.name=fmtest -c user.email=fmtest@example.invalid commit-tree -m "one past the archive" -p "$tip" "$tree")
  other=$(git -C "$dir/proj" -c user.name=fmtest -c user.email=fmtest@example.invalid commit-tree -m "beside the archive" -p "fm/$id-v2" "$tree")
  git -C "$dir/proj" branch "fm/$id-v2c" "$other"
  expect_successor_refusal "$dir" "$id" past-without-tip "is not proved to be this task's successor" 1 --branch "fm/$id-v2c" --tip "$tip" --note why
  git -C "$dir/proj" branch "fm/$id-v2b" "$past"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2b" --tip "$tip" --note why) || rc=$?
  expect_code 0 "$rc" "a branch one commit past the task's archive tip must be admitted"$'\n'"$out"
  assert_contains "$out" "route: route=archive-tip archive=archive/$id-pipeline-$hex successor=fm/$id-v2b successor_sha=$past proved_tip=$tip" "the receipt must name the archive and its tip as the proved tip"
  assert_equals "successor_proved_tip=$tip" "$(grep '^successor_proved_tip=' "$dir/home/state/$id.meta")" "the record must carry the archive tip as the proved tip"
  pass "successor: the archive-tip route admits a branch past the task's archive tip with that tip as the proved tip, and refuses a branch whose history lacks it"
}

# The first admission is anchored to the --tip Main reads itself, never to a ref the
# worker can write. The worker points its own archive name at an unmerged in-family
# commit T and a branch holds T: without --tip, or with another sha, the admission
# refuses, changes nothing and prints the command to rerun; with --tip T it records
# T as the proved tip, and a repeat call needs no --tip.
test_successor_first_admission_is_anchored_to_the_tip_main_read() {
  local id=suc-anchor dir tree t hex out rc wrong
  dir=$(new_successor_case anchor "$id")
  tree=$(git -C "$dir/proj" rev-parse "fm/$id-v2^{tree}")
  t=$(git -C "$dir/proj" -c user.name=fmtest -c user.email=fmtest@example.invalid commit-tree -m "planted" -p "fm/$id-v2" "$tree")
  hex=$(printf '%s' "$t" | cut -c1-8)
  git -C "$dir/proj" branch "archive/$id-pipeline-$hex" "$t"
  git -C "$dir/proj" branch "fm/$id-v2b" "$t"
  expect_successor_refusal "$dir" "$id" anchor-missing "no --tip was given" 1 --branch "fm/$id-v2b" --note why
  rc=0; out=$(sc "$dir" "$id" --branch "fm/$id-v2b" --note why) || rc=$?
  expect_code 1 "$rc" "a first admission without --tip must refuse"$'\n'"$out"
  assert_contains "$out" "successor --branch fm/$id-v2b --tip" "the refusal must print the command to rerun with --tip"
  assert_contains "$out" "no-mistakes axi status --run" "the refusal must say where Main reads the sha"
  wrong=$(tip_of "$dir" "fm/$id")
  expect_successor_refusal "$dir" "$id" anchor-mismatch "has the tip $wrong outside" 1 --branch "fm/$id-v2b" --tip "$wrong" --note why
  expect_successor_refusal "$dir" "$id" anchor-malformed "is not a full 40 or 64 lowercase hex commit" 1 --branch "fm/$id-v2b" --tip "$hex" --note why
  rc=0; out=$(sc "$dir" "$id" --branch "fm/$id-v2b" --tip "$t" --note why) || rc=$?
  expect_code 0 "$rc" "the --tip Main read must admit the branch"$'\n'"$out"
  assert_contains "$out" "route: route=archive-tip archive=archive/$id-pipeline-$hex" "the admission must name the archive route"
  assert_contains "$out" "tip: --tip $t" "the receipt must print the --tip used"
  assert_equals "successor_proved_tip=$t" "$(grep '^successor_proved_tip=' "$dir/home/state/$id.meta")" "the record must keep the --tip as the proved tip"
  cp -p "$dir/home/state/$id.meta" "$dir/meta.recorded"
  rc=0; out=$(sc "$dir" "$id" --branch "fm/$id-v2b" --note why) || rc=$?
  expect_code 0 "$rc" "a repeat call for the recorded successor needs no --tip"$'\n'"$out"
  assert_contains "$out" "successor-already-recorded $id" "the repeat must say it recorded nothing"
  assert_contains "$out" "tip: none needed" "the repeat receipt must say no --tip was needed"
  cmp -s "$dir/meta.recorded" "$dir/home/state/$id.meta" || fail "the repeat changed the record"
  pass "successor: a first admission refuses without the --tip Main read or with another sha, admits with it and records it, and a repeat needs no --tip"
}

# A repeated call for the recorded successor re-admits it while its history still
# contains the tip proved at its admission, and refuses once it does not.
test_successor_repeat_re_admits_while_the_proved_tip_is_contained() {
  local id=suc-repeat dir out rc proved root
  dir=$(new_successor_case repeat "$id")
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  proved=$(git -C "$dir/proj" rev-parse "fm/$id")
  commit_file "$dir/wt" v2-more.txt "worker commit on the successor $id"
  cp -p "$dir/home/state/$id.meta" "$dir/meta.recorded"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "a recorded successor that moved on with a new commit must be re-admitted"$'\n'"$out"
  assert_contains "$out" "successor-already-recorded $id" "the repeat must say it recorded nothing"
  assert_contains "$out" "route: route=proved-tip successor=fm/$id-v2" "the repeat must name the proved-tip route"
  assert_contains "$out" "proved_tip=$proved" "the repeat must name the tip proved at admission"
  cmp -s "$dir/meta.recorded" "$dir/home/state/$id.meta" || fail "the repeat changed the record"
  root=$(git -C "$dir/proj" rev-list --max-parents=0 "fm/$id" | head -n 1)
  git -C "$dir/wt" reset -q --hard "$root"
  : > "$FM_GUARD_EVENT_LOG"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 1 "$rc" "a recorded successor reset to history without the proved tip must refuse"$'\n'"$out"
  assert_contains "$out" "no longer contains the tip $proved proved at its admission" "the refusal must name the proved tip"
  cmp -s "$dir/meta.recorded" "$dir/home/state/$id.meta" || fail "the refusal changed the record"
  [ -n "$(admission_event recorded deny)" ] || fail "the refusal wrote no successor-branch-admission deny event"
  pass "successor: a repeated call re-admits a recorded successor that moved on past its proved tip, and refuses one reset to history without it"
}

# C3: the receipt carries a structured route token and the guard writes one event
# at record time naming the route and the successor; a refusal writes a deny event
# naming the rule and the successor.
test_successor_receipt_and_events_name_the_checked_out_route() {
  local id=suc-route dir out rc=0 row
  dir=$(new_successor_case route "$id")
  : > "$FM_GUARD_EVENT_LOG"
  out=$(sc "$dir" "$id" --branch "fm/$id-v3" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 1 "$rc" "an in-family branch that does not exist must refuse"$'\n'"$out"
  row=$(admission_event proof deny)
  [ -n "$row" ] || fail "a refusal wrote no successor-branch-admission deny event"
  assert_equals "fm/$id-v3" "$(printf '%s' "$row" | jq -r .successor)" "the deny event must name the refused successor"
  assert_equals "$id" "$(printf '%s' "$row" | jq -r .task)" "the deny event must name the task"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  assert_contains "$out" "route: route=checked-out successor=fm/$id-v2" "the receipt must carry the structured route and the successor"
  row=$(admission_event record allow)
  [ -n "$row" ] || fail "no successor-branch-admission allow event was written at record time"
  assert_equals checked-out "$(printf '%s' "$row" | jq -r .route)" "the record-time event must name the route"
  assert_equals "fm/$id-v2" "$(printf '%s' "$row" | jq -r .successor)" "the record-time event must name the successor"
  assert_equals "$id" "$(printf '%s' "$row" | jq -r .task)" "the record-time event must name the task"
  pass "successor: the receipt names route=checked-out, the guard writes an allow event with route and successor at record time, and a refusal writes a deny event"
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
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "a name that differs from every compared name by more than case must be admitted"$'\n'"$out"
  pass "successor: a case variant of another task's branch or successor, the recorded, base or default branch is refused, and a name that differs by more than case is admitted"
}

# C8: the registry owns the admission decision. The real metrics reader, run over the
# events a refusal and a record wrote, knows the guard and its harm only when the
# registry holds the entry, and the spawn-write-confinement entry names the permit.
test_registry_owns_the_successor_admission_and_the_reader_attributes_it() {
  local id=suc-registry dir out rc=0 report
  dir=$(new_successor_case registry "$id")
  : > "$FM_GUARD_EVENT_LOG"
  sc "$dir" "$id" --branch "fm/$id-v3" --tip "$(tip_of "$dir" "fm/$id")" --note why >/dev/null || true
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  report=$(env -u FM_TASK_ID bash "$ROOT/bin/fm-guard-metrics.sh" --log "$FM_GUARD_EVENT_LOG" --guards successor-branch-admission --json) \
    || fail "the metrics reader failed: $report"
  assert_equals irreversible "$(printf '%s' "$report" | jq -r '.guards[0].harm')" "the registry must own successor-branch-admission, or the reader cannot name its harm"
  assert_equals 1 "$(printf '%s' "$report" | jq -r '.guards[0].allows')" "the reader must count the record-time allow"
  assert_equals 1 "$(printf '%s' "$report" | jq -r '.guards[0].denies')" "the reader must count the refusal's deny"
  pass "successor: the real metrics reader attributes the record's allow and the refusal's deny to the registered admission guard and knows its harm"
}

# --- Round 2 (outside review of 71d56288f): one failing-first test per finding ---

# F1: an ownership record that cannot be read must refuse, not pass. Another task's
# record names the candidate; unreadable, it must stop the admission, and readable
# it refuses the same name for the ownership it states.
test_successor_refuses_when_another_task_record_cannot_be_read() {
  local id=suc-unreadable dir other out rc=0 before_meta before_brief
  dir=$(new_successor_case unreadable "$id")
  mode_zero_binds "$dir/probe" || { printf 'skip: this user reads mode 000 files, so an unreadable record cannot be staged\n'; return 0; }
  other=$dir/home/state/other-$id.meta
  printf 'successor_branch=fm/%s-v2\n' "$id" >> "$other"
  before_meta=$dir/before.meta
  before_brief=$dir/before.brief
  cp -p "$dir/home/state/$id.meta" "$before_meta"
  cp -p "$dir/home/data/$id/brief.md" "$before_brief"
  chmod 000 "$other"
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  chmod 600 "$other"
  expect_code 1 "$rc" "an unreadable other task record must refuse the admission"$'\n'"$out"
  assert_contains "$out" "cannot read task other-$id's record" "the refusal must name the unreadable record"
  cmp -s "$before_meta" "$dir/home/state/$id.meta" || fail "the refusal changed the task record"
  cmp -s "$before_brief" "$dir/home/data/$id/brief.md" || fail "the refusal changed the instructions"
  # Readable, the same record refuses the name for the ownership it states.
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 1 "$rc" "a readable record that owns the name must refuse it"$'\n'"$out"
  assert_contains "$out" "already records it as its successor branch" "the readable control refuses for the stated ownership"
  # Matched control: with no other record naming it, the name is admitted.
  sed -i.bak '/^successor_branch=/d' "$other" && rm -f "$other.bak"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "a readable inventory with no owner of the name must admit it"$'\n'"$out"
  pass "successor: an unreadable other task record refuses the admission, a readable owner refuses the name, and a readable inventory without an owner admits it"
}

# F2 (1): every work tree on the branch is checked, not the first one listed.
test_successor_refuses_a_branch_also_checked_out_in_another_work_tree() {
  local id=suc-twice dir where out rc
  dir=$(new_successor_case twice "$id")
  for where in a-extra z-extra; do
    git -C "$dir/proj" worktree add -q -f "$dir/$where" "fm/$id-v2"
    rc=0
    out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
    expect_code 1 "$rc" "a branch checked out in the recorded copy and also in $where must refuse"$'\n'"$out"
    assert_contains "$out" "$where" "the refusal must name the other work tree"
    assert_contains "$out" "which is not this task's recorded copy" "the refusal must name the missing proof"
    git -C "$dir/proj" worktree remove --force "$dir/$where"
  done
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "the single-copy control must be admitted"$'\n'"$out"
  assert_contains "$out" "route=checked-out" "the single-copy control is proved by the checked-out route"
  pass "successor: a branch also checked out in a second work tree is refused whichever is listed first, and the single-copy control is admitted"
}

# F2 (2): the ref store the proof reads is the ref store the profile grants.
test_successor_refuses_a_copy_outside_the_projects_ref_store() {
  local id=suc-store dir tree tip hex out rc quarantine
  dir=$(new_successor_case store "$id")
  tree=$(git -C "$dir/proj" rev-parse "fm/$id-v2^{tree}")
  tip=$(git -C "$dir/proj" -c user.name=fmtest -c user.email=fmtest@example.invalid commit-tree -m "successor" -p "fm/$id-v2" "$tree")
  hex=$(printf '%s' "$tip" | cut -c1-8)
  git -C "$dir/proj" branch "fm/$id-v2b" "$tip"
  git -C "$dir/proj" branch "archive/$id-submitted-$hex" "$tip"
  # A second repository holds a linked copy; the task record is pointed at that copy.
  git init -q -b main "$dir/other-repo"
  git -C "$dir/other-repo" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
  git -C "$dir/other-repo" worktree add -q -b "fm/$id-v2b" "$dir/other-copy"
  quarantine=$dir/home/state/$id.meta
  cp -p "$quarantine" "$dir/meta.good"
  sed -i.bak "s#^worktree=.*#worktree=$dir/other-copy#" "$quarantine" && rm -f "$quarantine.bak"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2b" --tip "$tip" --note why) || rc=$?
  expect_code 1 "$rc" "a recorded copy in another repository must refuse, though the project's archive matches"$'\n'"$out"
  assert_contains "$out" "does not share the project's ref store" "the refusal must name the missing proof"
  # Matched control: the same record with the copy that shares the project's ref store is admitted.
  cp -p "$dir/meta.good" "$quarantine"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2b" --tip "$tip" --note why) || rc=$?
  expect_code 0 "$rc" "a copy that shares the project's ref store must be admitted by the archive route"$'\n'"$out"
  assert_contains "$out" "route=archive-tip" "the matching control is proved by the archive-tip route"
  pass "successor: a recorded copy in another repository is refused, and the copy that shares the project's ref store is admitted"
}

# F3: a publication that fails after the rename has replaced the record must still
# leave the record, the brief and the profile as before, with no backup behind.
test_successor_post_rename_publication_failure_restores_everything() {
  local id=suc-late dir mode real_mv out rc leftovers
  real_mv=$(command -v mv)
  for mode in lost diverted; do
    dir=$(new_successor_case "late-$mode" "$id")
    cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
"$real_mv" "\$@" || exit \$?
for arg in "\$@"; do
  case "\$arg" in
    */.$id.meta.successor.*)
      target=\${!#}
      if [ '$mode' = lost ]; then
        rm -f "\$target"
      else
        "$real_mv" "\$target" "\$target.injected" && ln -s "\$target.injected" "\$target"
      fi
      ;;
  esac
done
exit 0
SH
    chmod +x "$dir/fakebin/mv"
    cp -p "$dir/home/state/$id.meta" "$dir/before.meta"
    cp -p "$dir/home/data/$id/brief.md" "$dir/before.brief"
    cp -p "$dir/home/state/$id.write-confinement.sb" "$dir/before.sb"
    rc=0
    out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
    expect_code 1 "$rc" "a post-rename validation failure ($mode) must refuse"$'\n'"$out"
    rm -f "$dir/home/state/$id.meta.injected"
    [ ! -L "$dir/home/state/$id.meta" ] || fail "the record is still a symbolic link after the failed call ($mode)"
    cmp -s "$dir/before.meta" "$dir/home/state/$id.meta" || fail "the record is not back to its prior bytes after a post-rename failure ($mode): $(cat "$dir/home/state/$id.meta" 2>&1 | tail -3)"
    cmp -s "$dir/before.brief" "$dir/home/data/$id/brief.md" || fail "the instructions are not back to their prior bytes ($mode)"
    cmp -s "$dir/before.sb" "$dir/home/state/$id.write-confinement.sb" || fail "the profile changed ($mode)"
    leftovers=$(find "$dir/home/state" "$dir/home/data/$id" -maxdepth 1 \( -name '*.meta.prior.*' -o -name '*.brief.prior.*' -o -name '*.meta.successor.*' -o -name '*.brief.successor.*' \) -print)
    [ -z "$leftovers" ] || fail "the failed call left staging or backup files behind ($mode): $leftovers"
    [ ! -e "$dir/home/state/.control-$id.lock" ] || fail "the failed call left the lifecycle lock behind ($mode)"
    rm -f "$dir/fakebin/mv"
    rc=0
    out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
    expect_code 0 "$rc" "after a post-rename failure ($mode) the same call must still succeed"$'\n'"$out"
  done
  pass "successor: a publication that fails after the rename restores the record, the instructions and the profile, with no backup or lock left"
}

# F5 (a): a refusal changes no task file; under a home's default event log it adds only
# rows: the control script's own gate-containment check, which every control call
# appends before the verb runs, and one deny row of the successor guard per refusal.
test_successor_refusals_write_no_file_under_the_default_event_log() {
  local id=suc-nofile dir log before after other denies out rc
  dir=$(new_successor_case nofile "$id")
  git -C "$dir/proj" branch "fm/$id-v2b" "fm/$id-v2"
  log=$dir/home/state/guard-events.jsonl
  : > "$log"
  state_without_log() { (cd "$dir/home/state" && find . -type f ! -name guard-events.jsonl | LC_ALL=C sort | while read -r f; do shasum -a 256 "$f"; done); }
  before=$(state_without_log)
  snap "$dir" before
  (
    # The harness exports FM_GUARD_EVENT_LOG (a per-run log), which a home does not have, so it
    # is unset to leave the home's own default event log in play. FM_GATE_REFUSE_BYPASS stays:
    # inside a no-mistakes gate it is what lets the call reach the verb, and its own row is
    # the gate-containment guard's.
    unset FM_GUARD_EVENT_LOG
    for branch in "fm/$id-v3" develop "fm/$id-v2b"; do
      rc=0
      out=$(sc "$dir" "$id" --branch "$branch" --note why) || rc=$?
      expect_code 1 "$rc" "the verb itself must refuse $branch"$'\n'"$out"
      assert_contains "$out" "nothing was changed" "the refusal of $branch must be the verb's"
    done
  ) || exit 1
  snap "$dir" after
  same "$dir" before after "the refusals" data wt wt-other proj-git nm fake sentinel
  after=$(state_without_log)
  [ "$before" = "$after" ] || fail "a refusal changed a state file other than the event log"
  other=$(jq -r 'select(.guard != "gate-agent-containment" and .guard != "successor-branch-admission") | .guard' "$log" | sort -u | tr '\n' ' ')
  [ -z "$other" ] || fail "a refusal wrote an event of another guard than the control script's gate check and the successor guard: $other"
  denies=$(jq -r 'select(.guard == "successor-branch-admission") | .decision + ":" + .successor' "$log" | LC_ALL=C sort | tr '\n' ' ')
  assert_equals "deny:develop deny:fm/$id-v2b deny:fm/$id-v3 " "$denies" "each refusal must write exactly one successor-branch-admission deny naming its successor"
  pass "successor: a refusal changes no task file and writes one successor-branch-admission deny event"
}

# F5 (b): the guard's events are best-effort. An event log that cannot take a row
# changes neither a refusal (its text, status and the untouched record) nor a record.
test_successor_event_log_failure_changes_neither_a_refusal_nor_a_record() {
  local id=suc-sink dir out rc refusal_ok refusal_broken
  dir=$(new_successor_case sink "$id")
  mkdir -p "$dir/event-sink-dir"
  cp -p "$dir/home/state/$id.meta" "$dir/before.meta"
  cp -p "$dir/home/data/$id/brief.md" "$dir/before.brief"
  rc=0
  refusal_ok=$(FM_GUARD_EVENT_LOG="$dir/event-log.jsonl" sc "$dir" "$id" --branch "fm/$id-v3" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 1 "$rc" "the refusal with a writable log"$'\n'"$refusal_ok"
  rc=0
  refusal_broken=$(FM_GUARD_EVENT_LOG="$dir/event-sink-dir" sc "$dir" "$id" --branch "fm/$id-v3" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 1 "$rc" "a refusal must stay a refusal when its event cannot be written"$'\n'"$refusal_broken"
  assert_equals "$(printf '%s\n' "$refusal_ok" | grep '^error:')" "$(printf '%s\n' "$refusal_broken" | grep '^error:')" "an unwritable event log changed the refusal text"
  cmp -s "$dir/before.meta" "$dir/home/state/$id.meta" || fail "a refusal under an unwritable event log changed the record"
  cmp -s "$dir/before.brief" "$dir/home/data/$id/brief.md" || fail "a refusal under an unwritable event log changed the instructions"
  jq -e 'select(.guard == "successor-branch-admission" and .decision == "deny")' "$dir/event-log.jsonl" >/dev/null \
    || fail "the writable log did not receive the refusal's deny event"
  rc=0
  out=$(FM_GUARD_EVENT_LOG="$dir/event-sink-dir" sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "an unwritable event log must not stop the record"$'\n'"$out"
  assert_equals "successor_branch=fm/$id-v2" "$(grep '^successor_branch=' "$dir/home/state/$id.meta")" "the record must be made although its event could not be written"
  pass "successor: an event log that cannot take a row changes neither a refusal nor a record"
}

# F6 (a): a note file is read after admission and never for a refusal.
test_successor_reads_the_note_file_only_after_admission() {
  local id=suc-notefile dir out rc note
  dir=$(new_successor_case notefile "$id")
  note=$dir/wt/note.txt
  mode_zero_binds "$dir/probe" || { printf 'skip: this user reads mode 000 files, so an unreadable note file cannot be staged\n'; return 0; }
  printf 'why from a file\n' > "$note"
  chmod 000 "$note"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v3" --tip "$(tip_of "$dir" "fm/$id")" --note-file "$note") || rc=$?
  expect_code 1 "$rc" "an admission refusal must come first"$'\n'"$out"
  assert_contains "$out" "does not exist in the project's ref store" "the refusal must be the admission's, not a note-file error"
  chmod 600 "$note"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note-file "$note") || rc=$?
  expect_code 0 "$rc" "after admission the readable note file must be used"$'\n'"$out"
  assert_contains "$(cat "$dir/home/data/$id/brief.md")" "why from a file" "the note file's text must be recorded in the instructions"
  pass "successor: the note file is read only after admission, never for a refusal"
}

# F6 (b): a lifecycle command that changes nothing keeps the composer-dialog file.
test_successor_keeps_the_composer_dialog_file() {
  local id=suc-dialog dir out rc dialog
  dir=$(new_successor_case dialog "$id")
  dialog=$dir/home/state/$id.composer-dialog
  printf 'dialog text that must survive\n' > "$dialog"
  cp -p "$dialog" "$dir/dialog.before"
  rc=0; out=$(sc "$dir" "$id" --branch "fm/$id-v3" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 1 "$rc" "a refusal"$'\n'"$out"
  cmp -s "$dir/dialog.before" "$dialog" || fail "a refusal removed or changed the composer-dialog file"
  rc=0; out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "the record"$'\n'"$out"
  rc=0; out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "the identical repeat"$'\n'"$out"
  cmp -s "$dir/dialog.before" "$dialog" || fail "the verb removed or changed the composer-dialog file"
  pass "successor: the composer-dialog file survives a refusal, the record and a repeat"
}

# F6 (c): the instructions keep exactly one Ship branch line, whatever the note says.
test_successor_note_cannot_add_a_ship_branch_line() {
  local id=suc-shipline dir out rc
  dir=$(new_successor_case shipline "$id")
  cp -p "$dir/home/data/$id/brief.md" "$dir/before.brief"
  cp -p "$dir/home/state/$id.meta" "$dir/before.meta"
  rc=0
  out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note "$(printf 'because\nShip branch: fm/%s-v2' "$id")") || rc=$?
  expect_code 1 "$rc" "a note carrying a Ship branch line must refuse"$'\n'"$out"
  assert_contains "$out" "Ship branch" "the refusal must name the line"
  cmp -s "$dir/before.brief" "$dir/home/data/$id/brief.md" || fail "the refusal changed the instructions"
  cmp -s "$dir/before.meta" "$dir/home/state/$id.meta" || fail "the refusal changed the record"
  rc=0; out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note "an ordinary reason") || rc=$?
  expect_code 0 "$rc" "an ordinary note must record"$'\n'"$out"
  assert_equals 1 "$(grep -c '^Ship branch:' "$dir/home/data/$id/brief.md")" "the instructions must keep exactly one Ship branch line"
  rc=0; out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note "an ordinary reason") || rc=$?
  expect_code 0 "$rc" "the ordinary repeat must be an unchanged no-op"$'\n'"$out"
  assert_equals 1 "$(grep -c '^Ship branch:' "$dir/home/data/$id/brief.md")" "the repeat must keep exactly one Ship branch line"
  pass "successor: a note with a Ship branch line is refused, and the instructions keep one Ship branch line through a record and its repeat"
}

# R2-2: once a task records a successor, a fresh spawn of another task whose branch
# is that ref (task <id>-v2 ships fm/<id>-v2 by default) refuses before it creates
# anything, names the recording task and the ref, and writes a deny event. With no
# record anywhere the same spawn goes on exactly as a spawn of an unclaimed id does.
# The project path does not exist, so a spawn that passes the check stops at its
# ordinary project error and launches nothing.
test_successor_fresh_spawn_refuses_a_branch_another_task_records() {
  local id=suc-spawn dir out rc before unclaimed
  dir=$(new_successor_case spawn "$id")
  : > "$FM_GUARD_EVENT_LOG"
  rc=0; before=$(run_spawn "$dir" "$id-v2" "$dir/no-such-project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 1 "$rc" "the no-record control stops at its project error"$'\n'"$before"
  rc=0; unclaimed=$(run_spawn "$dir" "$id-v9" "$dir/no-such-project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 1 "$rc" "the unclaimed control stops at its project error"$'\n'"$unclaimed"
  assert_equals "$(printf '%s\n' "$unclaimed" | sed "s/$id-v9/$id-v2/g")" "$before" "with no record anywhere the spawn must go on as a spawn of an unclaimed id does"
  case "$before" in *"spawn refused"*) fail "a spawn with no successor record anywhere was refused: $before" ;; esac
  [ -z "$(jq -c 'select(.guard == "successor-branch-admission")' "$FM_GUARD_EVENT_LOG")" ] || fail "a spawn with no record wrote a successor-branch-admission event"
  rc=0; out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note "successor before the collision") || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  snap "$dir" before-spawn
  rc=0; out=$(run_spawn "$dir" "$id-v2" "$dir/no-such-project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 1 "$rc" "a fresh spawn onto another task's recorded successor must refuse"$'\n'"$out"
  assert_contains "$out" "task $id records refs/heads/fm/$id-v2 as its successor branch" "the refusal must name the recording task and the ref"
  snap "$dir" after-spawn
  same "$dir" before-spawn after-spawn "the refused spawn" state data wt wt-other proj-git nm fake sentinel
  [ -n "$(jq -c --arg b "fm/$id-v2" 'select(.guard == "successor-branch-admission" and .rule == "spawn" and .decision == "deny" and .successor == $b)' "$FM_GUARD_EVENT_LOG")" ] \
    || fail "the refused spawn wrote no successor-branch-admission deny event naming the ref"
  pass "successor: a fresh spawn onto another task's recorded successor refuses and changes nothing, and with no record it goes on as before"
}

# F6 (d): the receipt says what the launch will do for a launch that no profile governs.
test_successor_receipt_matches_what_the_launch_will_do() {
  local id=suc-receipt2 dir out rc
  dir=$(new_successor_case receipt2 "$id")
  # A harness that no write profile governs: the receipt must say the launch is not confined.
  sed -i.bak 's/^harness=.*/harness=codex/' "$dir/home/state/$id.meta" && rm -f "$dir/home/state/$id.meta.bak"
  rc=0; out=$(sc "$dir" "$id" --branch "fm/$id-v2" --tip "$(tip_of "$dir" "fm/$id")" --note why) || rc=$?
  expect_code 0 "$rc" "recording for a harness no profile governs"$'\n'"$out"
  assert_contains "$out" "not write-confined" "the receipt must say that launch is not write-confined"
  case "$out" in *"replacement's write profile is generated"*) fail "the receipt promised a profile for an ungoverned launch: $out" ;; esac
  pass "successor: the receipt of a launch no profile governs says the launch is unconfined"
}

control_relaunch_test_cases=(
test_successor_records_the_branch_and_is_idempotent
test_successor_goes_before_a_recorded_pr
test_successor_receipt_names_owner_action_and_a_next_command_relaunch_accepts
test_successor_touches_no_tree_ref_process_run_or_profile_and_relaunch_keeps_them
test_successor_refuses_callers_without_authority
test_successor_refuses_other_tasks_and_records
test_successor_refuses_inadmissible_names
test_successor_refuses_unproved_successors
test_successor_name_family_bounds_the_checked_out_route
test_successor_archive_route_admits_only_the_task_own_archive_names
test_successor_archive_route_admits_a_branch_past_the_archive_tip
test_successor_repeat_re_admits_while_the_proved_tip_is_contained
test_successor_first_admission_is_anchored_to_the_tip_main_read
test_successor_receipt_and_events_name_the_checked_out_route
test_successor_names_compare_without_regard_to_case
test_registry_owns_the_successor_admission_and_the_reader_attributes_it
test_successor_refuses_when_another_task_record_cannot_be_read
test_successor_refuses_a_branch_also_checked_out_in_another_work_tree
test_successor_refuses_a_copy_outside_the_projects_ref_store
test_successor_post_rename_publication_failure_restores_everything
test_successor_refusals_write_no_file_under_the_default_event_log
test_successor_event_log_failure_changes_neither_a_refusal_nor_a_record
test_successor_fresh_spawn_refuses_a_branch_another_task_records
test_successor_reads_the_note_file_only_after_admission
test_successor_keeps_the_composer_dialog_file
test_successor_note_cannot_add_a_ship_branch_line
test_successor_receipt_matches_what_the_launch_will_do
test_successor_failure_at_each_write_step_changes_nothing
test_successor_serializes_on_the_lifecycle_and_metadata_locks
test_relaunch_profile_covers_exactly_the_recorded_successor
test_relaunch_of_a_task_with_no_successor_generates_the_unchanged_profile
test_branch_stays_refused_on_every_other_verb
)

control_relaunch_run "$@"
