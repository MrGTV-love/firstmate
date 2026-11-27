#!/usr/bin/env bash
# bin/fm-teardown.sh's copy-clearance scan while it holds the shared Treehouse project lock, and its exit on SIGTERM.
#
# The scan reads every task record of every local home. A teardown that spent minutes in it held the project lock
# against every spawn in the home, and one that was stopped could leave a child that ignored SIGTERM
# (data/fm-teardown-pure-bash-spin/report.md, sections Fix and Lock window).
#
# What this pins, with the real teardown over private fixtures. A shim in the walk's per-record command blocks on a marker
# the harness releases. Waiting: the harness polls for markers (each poll bounded), and the deadline cases wait out the
# 3-second deadline on the wall clock, 4 seconds in all, because a deadline cannot expire without time passing; no case
# sleeps a fixed time for anything else. SIGKILL: a case that passes sends none. Two cases send it after their result is
# recorded: to the fixture's own deliberate producer that ignores SIGTERM and never finishes (cleanup, never the way the
# case passes), and, only in the branch where the case has already failed because the teardown stayed blocked, to the
# teardown's own leader. tests/lib.sh's shared fixture cleanup also ends a case's leftover fixture processes with SIGKILL.
#   1. Each of the three project-lock windows in which a scan runs (bin/fm-teardown.sh: the preflight, the slot
#      reservation, the final return) refuses a scan that outlives FM_TEARDOWN_SCAN_DEADLINE_SECS: exit 1, a message
#      naming the scan deadline and a retry, the lock released, nothing changed since the scan began, and a retry
#      that finishes the teardown.
#   2. SIGTERM to the teardown's own process group while a 300-record scan runs ends every process of the group, the
#      leader by SIGTERM with its EXIT trap run, the lock released, nothing changed.
#   3. SIGTERM while the scan waits on a producer that ignores SIGTERM still ends the teardown (case iii).
#   4. SIGTERM after the first destructive step leaves the task record and the copy for a retry, which finishes.
#   5. The other per-record walks that can run under the project lock take the same deadline, one case per window branch:
#      the foreign-copy ownership walk of window 3's held/peers branch, the shared-slot walk of window 1 and the peer walk
#      of window 2's absent-claim branch, each with a mutant that takes the deadline away.
# Usage: bash tests/fm-teardown-scan-bounds.test.sh [test_function_name ...]
# The cases source libraries inside subshells on purpose, so a variable they set there is not the suite's own.
# The snapshot lists names only, with no newline in any.
# shellcheck disable=SC2012,SC2030,SC2031
set -u

# shellcheck source=tests/fm-record-scan-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-record-scan-helpers.sh"

# FM_SCAN_BIN names the bin directory the cases drive (default: this checkout's); pointing it at an older bin/ shows which
# cases fail without the fix.
SCAN_BIN=${FM_SCAN_BIN:-$ROOT/bin}

# scan_snapshot <case-dir>: what a retry depends on, with the lock artefacts left out (they are asserted apart).
scan_snapshot() {
  local c=$1 f
  (
    # shellcheck disable=SC2012 # names only
    cd "$c" || exit 1
    echo "state:"
    # shellcheck disable=SC2010,SC2012 # names only, none with a newline
    ls -A state | grep -v -e lock -e '^[.]teardown-run[.]' | LC_ALL=C sort
    echo "records:"
    for f in state/*.meta h*/state/*.meta; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done
    echo "slot:"
    ls -A pool/9/repo 2>&1 | LC_ALL=C sort
    echo "pool:"
    ls -A pool/9 2>&1 | LC_ALL=C sort
    cat pool/treehouse-state.json 2>&1
    echo "worktrees:"
    git -C project worktree list --porcelain | grep -c '^worktree '
    echo "data:"
    ls -A data 2>&1 | LC_ALL=C sort
  )
}

lock_artefacts() {  # <case-dir>: a project lock, or a holder or waiter in its holds or queue, still in the state directory
  find "$1/state" -maxdepth 3 \( -name '.treehouse-project-*.lock' -o -path '*.treehouse-project-*.lock.holds/*' \
    -o -path '*.treehouse-project-*.lock.queue/*' \) ! -name sequence 2>/dev/null | LC_ALL=C sort
}

# One window: block the scan of the <w>th lock window at its first record, let the deadline pass, release.
scan_deadline_window_case() {  # <window 1|2|3>
  local w=$1 case_dir n entry after rc
  case_dir=$(make_scan_case "deadline-w$w" 6)
  add_fd_git_shim "$case_dir"
  n=$((5 * (w - 1) + 1))
  start_scan_teardown "$case_dir" "$SCAN_BIN" FM_TEARDOWN_SCAN_DEADLINE_SECS=3 FM_BLOCK_AT="$n"
  wait_for_file "$case_dir/block/blocked.$n"
  entry=$(scan_snapshot "$case_dir")
  [ "$(project_lock_state "$case_dir")" = held ] || fail "window $w: the scan does not hold the project lock (the case would prove nothing)"
  wait_until_clock_passes 4
  : > "$case_dir/block/release.$n"
  finish_scan_teardown "$case_dir"
  rc=$(cat "$case_dir/rc")
  expect_code 1 "$rc" "window $w: the scan past its deadline should refuse: $(tail -3 "$case_dir/out")"
  assert_grep "scan deadline" "$case_dir/out" "window $w: the refusal does not name the scan deadline"
  assert_grep "retry the teardown" "$case_dir/out" "window $w: the refusal does not say a retry is safe"
  assert_grep "FM_TEARDOWN_SCAN_DEADLINE_SECS" "$case_dir/out" "window $w: the refusal does not name its setting"
  after=$(scan_snapshot "$case_dir")
  [ "$entry" = "$after" ] || fail "window $w: the refusal changed state:$(printf '\n'; diff <(printf '%s\n' "$entry") <(printf '%s\n' "$after"))"
  [ "$(project_lock_state "$case_dir")" = free ] || fail "window $w: the project lock was not released by the refusal"
  [ -z "$(lock_artefacts "$case_dir")" ] || fail "window $w: lock entries remain: $(lock_artefacts "$case_dir")"
  assert_present "$case_dir/state/task-x1.meta" "window $w: the refusal removed the task record"
  assert_present "$case_dir/pool/9/repo" "window $w: the refusal removed the copy"
  # Retry: nothing blocks, the default deadline applies, and the teardown finishes.
  run_scan_teardown "$case_dir" "$SCAN_BIN"
  expect_code 0 "$(cat "$case_dir/rc")" "window $w: the retry should finish: $(tail -3 "$case_dir/out")"
  assert_absent "$case_dir/state/task-x1.meta" "window $w: the retry left the task record"
}

test_a_scan_past_its_deadline_refuses_in_the_preflight_window() {
  scan_deadline_window_case 1
  pass "window 1 (preflight): a scan past its deadline refuses, changes nothing, frees the lock, and a retry finishes"
}

test_a_scan_past_its_deadline_refuses_in_the_slot_reservation_window() {
  scan_deadline_window_case 2
  pass "window 2 (slot reservation): a scan past its deadline refuses, changes nothing, frees the lock, and a retry finishes"
}

test_a_scan_past_its_deadline_refuses_in_the_final_return_window() {
  scan_deadline_window_case 3
  pass "window 3 (final return): a scan past its deadline refuses, changes nothing, frees the lock, and a retry finishes"
}

test_a_scan_without_the_lock_is_not_bounded_by_the_deadline() {
  local case_dir
  case_dir=$(make_scan_case deadline-unlocked 6)
  add_fd_git_shim "$case_dir"
  # The scans outside the project lock keep their old behaviour: a teardown whose task has no pool slot never
  # holds the lock, so an expired deadline cannot refuse it.
  rm -rf "$case_dir/pool/treehouse-state.json"
  run_scan_teardown "$case_dir" "$SCAN_BIN" FM_TEARDOWN_SCAN_DEADLINE_SECS=1
  assert_no_grep "scan deadline" "$case_dir/out" "an unlocked teardown was refused by the scan deadline"
  pass "the scan deadline is read only for a scan that holds the project lock"
}

# --- SIGTERM ---------------------------------------------------------------------------------------------------------

test_sigterm_during_the_scan_ends_the_whole_group_with_the_lock_released() {
  local case_dir pid before after waited members
  case_dir=$(make_scan_case sigterm-scan 300)
  add_fd_git_shim "$case_dir"
  FM_SCAN_TRACE=1 start_scan_teardown "$case_dir" "$SCAN_BIN" FM_BLOCK_AT=260
  pid=$SCAN_PID
  wait_for_file "$case_dir/block/blocked.260"
  before=$(scan_snapshot "$case_dir")
  [ "$(project_lock_state "$case_dir")" = held ] || fail "sigterm: the scan does not hold the project lock"
  members=$(group_members "$pid" | tr '\n' ' ')
  case " $members " in *" $pid "*) ;; *) fail "sigterm: the leader $pid is not the process group $pid ($members)" ;; esac
  # The group holds only this run: every member descends from the leader.
  kill -TERM -- "-$pid"
  finish_scan_teardown "$case_dir"
  waited=0
  while [ -n "$(group_members "$pid")" ] && [ "$waited" -lt 40 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  [ -z "$(group_members "$pid")" ] || fail "sigterm: processes of the group are still alive after 8 s: $(group_members "$pid" | tr '\n' ' ')"
  expect_code 143 "$(cat "$case_dir/rc")" "sigterm: the leader should end by SIGTERM (143)"
  assert_grep "teardown_release_locks" "$case_dir/out" "sigterm: the EXIT trap did not run"
  after=$(scan_snapshot "$case_dir")
  [ "$before" = "$after" ] || fail "sigterm: a mutation followed the signal:$(printf '\n'; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
  [ "$(project_lock_state "$case_dir")" = free ] || fail "sigterm: the project lock was not released"
  [ -z "$(lock_artefacts "$case_dir")" ] || fail "sigterm: lock entries remain: $(lock_artefacts "$case_dir")"
  pass "SIGTERM during a 300-record scan ends every process of the group, the leader by SIGTERM, the lock released, nothing changed"
}

test_sigterm_while_the_scan_waits_on_a_producer_that_ignores_it_still_ends_the_teardown() {
  local case_dir pid before after waited producer rc
  case_dir=$(make_scan_case sigterm-producer 40)
  add_fd_git_shim "$case_dir"
  # The scan's per-record git is a producer that ignores SIGTERM and never exits: Bash 3.2 does not act on SIGTERM
  # while it reads a command substitution's pipe, so a parent reading git that way would stay blocked.
  FM_SCAN_TRACE=1 start_scan_teardown "$case_dir" "$SCAN_BIN" FM_BLOCK_AT=20 FM_BLOCK_IGNORE_TERM=1
  pid=$SCAN_PID
  wait_for_file "$case_dir/block/blocked.20"
  producer=$(cat "$case_dir/block/producer.pid")
  before=$(scan_snapshot "$case_dir")
  [ "$(project_lock_state "$case_dir")" = held ] || fail "producer: the scan does not hold the project lock"
  kill -TERM -- "-$pid"
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  rc=blocked
  if ! kill -0 "$pid" 2>/dev/null; then finish_scan_teardown "$case_dir"; rc=$(cat "$case_dir/rc"); fi
  after=$(scan_snapshot "$case_dir")
  lock=$(project_lock_state "$case_dir")
  producer_alive=0
  kill -0 "$producer" 2>/dev/null && producer_alive=1
  # The result is recorded; only now does the harness remove its own deliberate non-terminating producer.
  # This SIGKILL (and its twin in the canon case) is cleanup of the fixture's producer, never how a case passes; the
  # leader's SIGKILL below runs only when the case has already failed (see the suite header).
  kill -KILL "$producer" 2>/dev/null
  if [ "$rc" = blocked ]; then
    kill -KILL "$pid" 2>/dev/null
    fail "producer: the teardown was still blocked 8 s after SIGTERM (its EXIT trap never ran)"
  fi
  [ "$producer_alive" = 1 ] || fail "producer: the producer was already gone, so the case proves nothing"
  expect_code 143 "$rc" "producer: the leader should end by SIGTERM (143)"
  assert_grep "teardown_release_locks" "$case_dir/out" "producer: the EXIT trap did not run"
  [ "$lock" = free ] || fail "producer: the project lock was not released"
  [ "$before" = "$after" ] || fail "producer: a mutation followed the signal"
  pass "SIGTERM ends a teardown whose scan waits on a producer that ignores SIGTERM: trap run, lock released, nothing changed"
}

# make_hanging_canonical_bin <dir>: <dir>/bin holds symlinks to every bin file but fm-task-copy-lib.sh, whose copy has a
# fm_task_copy_canonical_dir that, for one filler copy asked by the copy-clearance scan, hangs ignoring SIGTERM (a fork
# child that never finishes, as the stalled teardown's was). FM_HANG_SRC_BIN names the bin directory to copy from (default: this checkout's).
make_hanging_canonical_bin() {
  local dir=$1 src=${FM_HANG_SRC_BIN:-$SCAN_BIN} f
  mkdir -p "$dir/bin"
  for f in "$src"/*; do ln -s "$f" "$dir/bin/${f##*/}"; done
  rm -f "$dir/bin/fm-task-copy-lib.sh"
  python3 -I - "$src/fm-task-copy-lib.sh" "$dir/bin/fm-task-copy-lib.sh" <<'PY' || fail "the library has no fm_task_copy_canonical_dir to make hang"
import sys
text = open(sys.argv[1]).read()
anchor = 'fm_task_copy_canonical_dir() {  # <path>\n  local target=$1\n'
if text.count(anchor) != 1:
    sys.exit(1)
hang = anchor + '  case "$target:${FUNCNAME[1]:-}" in */pool/fill-20/repo:require_cleanup_copy_clearance) trap "" TERM; : > "$FM_BLOCK_DIR/blocked.canon"; while :; do sleep 1; done ;; esac\n'
open(sys.argv[2], "w").write(text.replace(anchor, hang))
PY
}

test_sigterm_while_the_scan_waits_on_a_forked_producer_that_ignores_it_ends_the_teardown() {
  local case_dir pid before after waited rc lock producer_alive producer members
  case_dir=$(make_scan_case sigterm-canon 40)
  add_fd_git_shim "$case_dir"
  make_hanging_canonical_bin "$case_dir/h"
  # Record 20's copy canonicalization is a forked producer that ignores SIGTERM and never closes its pipe. Bash 3.2 does
  # not act on SIGTERM while it reads a command substitution's pipe, so a scan that canonicalizes through one stays
  # blocked; the scan reads the path in-process, so it never forks for it.
  FM_SCAN_TRACE=1 start_scan_teardown "$case_dir" "$case_dir/h/bin"
  pid=$SCAN_PID
  waited=0
  while [ ! -e "$case_dir/block/blocked.canon" ] && kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 3000 ]; do sleep 0.1; waited=$((waited + 1)); done
  if [ ! -e "$case_dir/block/blocked.canon" ]; then
    finish_scan_teardown "$case_dir"
    # The teardown never forked for that path: it ran the scan to its end without the producer.
    expect_code 0 "$(cat "$case_dir/rc")" "canon: the teardown should have run its scan to the end without the producer"
    assert_absent "$case_dir/state/task-x1.meta" "canon: the teardown left its task record"
    pass "the scan canonicalizes copies in-process: a forking producer that ignores SIGTERM is never read, so it cannot hold the teardown"
    return 0
  fi
  producer=$(python3 -I "$ROOT/bin/fm-proc-info.py" table pid,ppid,pgid | awk -v g="$pid" '{ gsub(",", " ") } $3 == g && $2 == g { print $1; exit }')
  before=$(scan_snapshot "$case_dir")
  [ "$(project_lock_state "$case_dir")" = held ] || fail "canon: the scan does not hold the project lock"
  kill -TERM -- "-$pid"
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 0.2; waited=$((waited + 1)); done
  rc=blocked
  if ! kill -0 "$pid" 2>/dev/null; then finish_scan_teardown "$case_dir"; rc=$(cat "$case_dir/rc"); fi
  after=$(scan_snapshot "$case_dir")
  lock=$(project_lock_state "$case_dir")
  producer_alive=0
  [ -z "$producer" ] || ! kill -0 "$producer" 2>/dev/null || producer_alive=1
  # The result is recorded; only now is the fixture's own deliberate non-terminating producer removed (cleanup, never a pass).
  [ -z "$producer" ] || kill -KILL "$producer" 2>/dev/null
  if [ "$rc" = blocked ]; then
    kill -KILL "$pid" 2>/dev/null
    fail "canon: the teardown was still blocked 8 s after SIGTERM, reading a producer that ignores it (its EXIT trap never ran)"
  fi
  [ "$producer_alive" = 1 ] || fail "canon: the producer was already gone, so the case proves nothing"
  expect_code 143 "$rc" "canon: the leader should end by SIGTERM (143)"
  assert_grep "teardown_release_locks" "$case_dir/out" "canon: the EXIT trap did not run"
  [ "$lock" = free ] || fail "canon: the project lock was not released"
  [ "$before" = "$after" ] || fail "canon: a mutation followed the signal"
  pass "SIGTERM ends a teardown whose scan was blocked reading a forked producer that ignores it"
}

test_sigterm_after_the_first_destructive_step_leaves_a_retry_that_finishes() {
  local case_dir pid
  case_dir=$(make_scan_case sigterm-return 8)
  # A Treehouse whose return waits: the teardown has by then killed its endpoint and removed its runtime state.
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  : > "$FM_BLOCK_DIR/blocked.return"
  waited=0
  while [ ! -e "$FM_BLOCK_DIR/release.return" ] && [ "$waited" -lt 3000 ]; do sleep 0.1; waited=$((waited + 1)); done
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  start_scan_teardown "$case_dir" "$SCAN_BIN"
  pid=$SCAN_PID
  wait_for_file "$case_dir/block/blocked.return"
  kill -TERM -- "-$pid"
  finish_scan_teardown "$case_dir"
  expect_code 143 "$(cat "$case_dir/rc")" "sigterm after return: the leader should end by SIGTERM"
  [ -z "$(group_members "$pid")" ] || fail "sigterm after return: processes of the group are alive: $(group_members "$pid" | tr '\n' ' ')"
  [ "$(project_lock_state "$case_dir")" = free ] || fail "sigterm after return: the project lock was not released"
  assert_present "$case_dir/state/task-x1.meta" "sigterm after return: the record the retry needs is gone"
  assert_present "$case_dir/pool/9/repo" "sigterm after return: the copy is gone before the return ran"
  # The retry has a Treehouse that returns at once.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/treehouse"
  run_scan_teardown "$case_dir" "$SCAN_BIN"
  expect_code 0 "$(cat "$case_dir/rc")" "sigterm after return: the retry should finish: $(tail -3 "$case_dir/out")"
  assert_absent "$case_dir/state/task-x1.meta" "sigterm after return: the retry left the task record"
  pass "SIGTERM after the first destructive step leaves the record and the copy, and a retry finishes the teardown"
}

# --- the other per-record walks under the project lock (the branch cases) ----------------------------------------------
# Every read-only walk of the task records that can run while bin/fm-teardown.sh holds the project lock takes the same
# deadline (docs/configuration.md FM_TEARDOWN_SCAN_DEADLINE_SECS). One case per window branch that reaches a walk the
# copy-clearance scan above does not cover; the walk the case drives is named in each. The walk is held at its first
# record by a gate the harness releases (no fixed sleep); the case then waits out the deadline and releases it.

# make_gate_bin <dir> <function> <stack-glob> <arg-glob> [mutant]: <dir>/bin holds symlinks to every bin file but the one that
# defines <function>, whose copy gates it: the first time it is called with a first argument matching <arg-glob> and a call
# stack (the names of its callers, innermost first, joined by spaces) matching <stack-glob> while the
# teardown holds the project lock, it writes the call stack to $FM_BLOCK_DIR/blocked.walk and waits (at most 5 minutes) for
# $FM_BLOCK_DIR/release.walk. A mutant also takes the deadline away: "nested-hand-over" makes the foreign-copy walk
# unbounded; "check-off" makes teardown_scan_deadline_check do nothing (isolated copies of the library, never the real one).
make_gate_bin() {
  local dir=$1 fn=$2 caller=$3 glob=$4 mutant=${5:-} src=${FM_HANG_SRC_BIN:-$SCAN_BIN} f
  mkdir -p "$dir/bin"
  for f in "$src"/*; do ln -s "$f" "$dir/bin/${f##*/}"; done
  python3 -I - "$src" "$dir/bin" "$fn" "$caller" "$glob" "$mutant" <<'PY' || fail "could not build the gate bin for $fn"
import glob, os, re, sys
src, dst, fn, caller, pat, mutant = sys.argv[1:7]
gate = (
    '  case "${FUNCNAME[*]:1}" in %s)\n'
    '    case "$1" in %s)\n'
    '      if [ "${TREEHOUSE_PROJECT_LOCK_HELD:-0}" = 1 ] && [ ! -e "$FM_BLOCK_DIR/blocked.walk" ]; then\n'
    '        echo "${FUNCNAME[*]} :: ${BASH_LINENO[*]}" > "$FM_BLOCK_DIR/blocked.walk"\n'
    '        _gw=0; while [ ! -e "$FM_BLOCK_DIR/release.walk" ] && [ "$_gw" -lt 3000 ]; do sleep 0.1; _gw=$((_gw + 1)); done\n'
    '      fi ;;\n'
    '    esac ;;\n'
    '  esac\n') % (caller.replace(' ', '\\ '), pat)
def patched(name, text):
    os.unlink(os.path.join(dst, name))
    open(os.path.join(dst, name), "w").write(text)
hits = []
for path in sorted(glob.glob(os.path.join(src, "*.sh"))):
    text = open(path).read()
    m = re.search(r'^%s\(\) \{[^\n]*\n' % re.escape(fn), text, re.M)
    if m:
        hits.append((os.path.basename(path), text[:m.end()] + gate + text[m.end():]))
if len(hits) != 1:
    sys.exit(1)
patched(*hits[0])
if mutant:
    name = "fm-teardown-nested-lib.sh"
    text = open(os.path.join(src, name)).read()
    if mutant == "nested-hand-over":
        old = '  FM_TASK_COPY_SCAN_LIMIT_SECS=$scan_limit\n'
        new = '  FM_TASK_COPY_SCAN_LIMIT_SECS=0\n'
    else:
        old = '  [ "$1" -le 0 ] || [ "$SECONDS" -lt "$1" ] || teardown_scan_deadline_refuse "$2" "$3"\n'
        new = '  :\n'
    if text.count(old) != 1:
        sys.exit(1)
    if os.path.islink(os.path.join(dst, name)):
        os.unlink(os.path.join(dst, name))
    open(os.path.join(dst, name), "w").write(text.replace(old, new))
PY
}

# add_filler_records <state-dir> <case-dir> <n>: n task records that each name an existing directory of their own as worktree=
# and as prior_worktree= (so a walk that reads prior_worktree= lines canonicalizes a path per record).
add_filler_records() {
  local sd=$1 c=$2 n=$3 f=1 fwt
  while [ "$f" -le "$n" ]; do
    fwt="$c/pool/fill-$f/repo"
    mkdir -p "$fwt"
    printf 'worktree=%s\nproject=%s\nkind=ship\nprior_worktree=%s\n' "$fwt" "$c/project" "$fwt" > "$sd/fill-$(printf '%04d' "$f").meta"
    f=$((f + 1))
  done
}

# walk_snapshot <case-dir> [<home>]: what a retry depends on, with the lock artefacts left out: the state names and the
# record sums, the registered copies, the pool tree and its lease, the slot claims, the data names.
walk_snapshot() {
  local c=$1 f
  (
    cd "$c" || exit 1
    echo "state:"
    # shellcheck disable=SC2010,SC2012 # names only, none with a newline
    ls -A state | grep -v -e lock -e '^[.]teardown-run[.]' | LC_ALL=C sort
    echo "records:"
    for f in state/*.meta; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done
    echo "copies:"
    git -C project worktree list --porcelain
    echo "pool:"
    find pool -not -path '*/.git/*' -not -path '*/.git' -print | LC_ALL=C sort
    cat pool/treehouse-state.json 2>&1
    for f in pool/*/.fm-slot-owner; do [ ! -e "$f" ] || { echo "$f"; cat "$f"; }; done
    echo "data:"
    ls -A data 2>&1 | LC_ALL=C sort
  )
}

# start_walk_teardown <case-dir> <bin-dir> <home> [NAME=value ...]: the real teardown of task-x1 in a foreign-copy fixture
# (the environment run_foreign_teardown gives it), in its own process group; output in <case-dir>/out, leader in SCAN_PID.
start_walk_teardown() {
  local c=$1 bindir=$2 home=$3 kv
  shift 3
  mkdir -p "$c/block"
  rm -f "$c/code-root/bin"
  ln -s "$bindir" "$c/code-root/bin"
  (
    export FM_TEARDOWN_VERNANT_PYTHON="$c/vernant-python" FM_HOME="$home" FM_ROOT_OVERRIDE="$c/code-root" \
      FM_STATE_OVERRIDE="$c/state" FM_DATA_OVERRIDE="$c/data" FM_CONFIG_OVERRIDE="$c/config" NM_HOME="$c/nm" \
      PATH="$c/fakebin:$PATH" FM_BLOCK_DIR="$c/block"
    for kv in "$@"; do export "${kv?}"; done
    exec python3 -I -c 'import os,sys; os.setpgrp(); os.execv(sys.argv[1], sys.argv[1:])' /bin/bash "$bindir/fm-teardown.sh" task-x1
  ) > "$c/out" 2>&1 < /dev/null &
  SCAN_PID=$!
  printf '%s\n' "$SCAN_PID" > "$c/leader"
}

# walk_main_line <pattern> [<after-pattern>]: the line of bin/fm-teardown.sh (the bin under test) that holds <pattern>, the first
# one after a line holding <after-pattern> when that is given; the statement of the script itself that starts a window's walk.
walk_main_line() {
  awk -v pat="$1" -v after="${2:-}" 'after == "" { f = 1 } index($0, after) && after != "" { f = 1 } f && index($0, pat) { print NR; exit }' "$SCAN_BIN/fm-teardown.sh"
}

# walk_case_outcome <label> <case-dir> <home> <mode> <main-line> <stack-fragment>...: the gated walk is held until its deadline
# has passed; mode "refuse" asserts the refusal and everything it leaves, "unbounded" (a mutant) asserts there was none. The
# teardown is already running (SCAN_PID). The caller names the walk the gate must have caught by call-stack fragments, and the
# statement of bin/fm-teardown.sh (a line number) that the stack must start from, so a case cannot pass on another window.
walk_case_outcome() {
  local label=$1 c=$2 home=$3 mode=$4 want=$5 entry after rc frag stack names lines top
  shift 5
  wait_for_file "$c/block/blocked.walk"
  stack=$(cat "$c/block/blocked.walk")
  names=${stack%% :: *}
  read -r -a lines <<< "${stack##* :: }"
  top=${lines[$((${#lines[@]} - 2))]}
  for frag in "$@"; do
    case " $names " in *" $frag "*) ;; *) fail "$label: the gate caught another walk, not the one the case names ($frag): $stack" ;; esac
  done
  [ "$want" = any ] || { [ -n "$want" ] && [ "$top" = "$want" ]; } || fail "$label: the walk was reached from bin/fm-teardown.sh line $top, not the window statement at line ${want:-?}: $stack"
  [ "$(project_lock_state "$c" "$home")" = held ] || fail "$label: the walk does not hold the project lock (the case would prove nothing)"
  entry=$(walk_snapshot "$c")
  wait_until_clock_passes 4
  : > "$c/block/release.walk"
  finish_scan_teardown "$c"
  rc=$(cat "$c/rc")
  if [ "$mode" = unbounded ]; then
    assert_no_grep "scan deadline" "$c/out" "$label: the mutant refused all the same: $(tail -3 "$c/out")"
    pass "$label: without the deadline the walk past 4 s is not refused (rc $rc), so the refusal case tests the deadline"
    return 0
  fi
  expect_code 1 "$rc" "$label: the walk past its deadline should refuse: $(tail -3 "$c/out")"
  assert_grep "scan deadline" "$c/out" "$label: the refusal does not name the scan deadline"
  assert_grep "retry the teardown" "$c/out" "$label: the refusal does not say a retry is safe"
  assert_grep "FM_TEARDOWN_SCAN_DEADLINE_SECS" "$c/out" "$label: the refusal does not name its setting"
  after=$(walk_snapshot "$c")
  [ "$entry" = "$after" ] || fail "$label: the refusal changed state after the walk began:$(printf '\n'; diff <(printf '%s\n' "$entry") <(printf '%s\n' "$after"))"
  [ "$(project_lock_state "$c" "$home")" = free ] || fail "$label: the project lock was not released by the refusal"
  [ -z "$(lock_artefacts "$home")" ] || fail "$label: lock entries remain: $(lock_artefacts "$home")"
  assert_present "$c/state/task-x1.meta" "$label: the refusal removed the task record"
}

# Window 3, the held/peers branch: a task closes beside a foreign copy that holds a commit on no remote, so the slot is held
# and the teardown runs teardown_nested_slot return under the project lock; its reprove walks every task record once per
# foreign copy (teardown_foreign_copies_prove, teardown_foreign_copy_unowned, fm_task_copy_other_record).
# State the refusal leaves: the entry of the window (endpoint closed, runtime files removed, return-pending marker written,
# the reserved slot's lease and claim in place), and every copy, the slot and the record untouched.
walk_held_case() {  # <label> [mutant]
  local c
  make_held_case "walk-$1"
  c=$FOREIGN_CASE
  held_foreign_unlanded "$FOREIGN_COPY"
  add_filler_records "$c/state" "$c" 8
  make_gate_bin "$c/gate" fm_task_copy_canonical_dir 'fm_task_copy_other_record *' '*' "${2:-}"
  start_walk_teardown "$c" "$c/gate/bin" "$c/home" FM_TEARDOWN_SCAN_DEADLINE_SECS=3
  if [ -n "${2:-}" ]; then
    walk_case_outcome "held walk ($2)" "$c" "$c/home" unbounded "$(walk_main_line 'teardown_nested_slot return' 'local proof under custody, as the return does')" teardown_foreign_copy_unowned
    return 0
  fi
  walk_case_outcome "held walk" "$c" "$c/home" refuse "$(walk_main_line 'teardown_nested_slot return' 'local proof under custody, as the return does')" teardown_foreign_copy_unowned teardown_nested_slot
  assert_grep "ownership walk for foreign copy" "$c/out" "held walk: the refusal does not name the walk"
  assert_present "$c/state/task-x1.teardown-return-pending" "held walk: the retry marker is gone"
  assert_present "$FOREIGN_COPY" "held walk: the refusal removed the foreign copy"
  # Retry: the real library, the default deadline, and the held close finishes.
  rm -f "$c/code-root/bin" "$c/block/blocked.walk"
  ln -s "$SCAN_BIN" "$c/code-root/bin"
  start_walk_teardown "$c" "$SCAN_BIN" "$c/home"
  finish_scan_teardown "$c"
  expect_code 0 "$(cat "$c/rc")" "held walk: the retry should finish: $(tail -3 "$c/out")"
  assert_absent "$c/state/task-x1.meta" "held walk: the retry left the task record"
}

test_a_foreign_copy_walk_past_its_deadline_refuses_in_the_final_return_window() {
  walk_held_case w3
  pass "window 3 (held/peers branch): the foreign-copy ownership walk past its deadline refuses, leaves the window's entry state, frees the lock, and a retry finishes"
}

test_mutant_without_the_foreign_copy_deadline_the_walk_is_not_refused() {
  walk_held_case w3-mutant nested-hand-over
}

# Window 1: require_shared_task_worktree_slot walks every task record (a read of each record's kind and worktree) under the
# lock the preflight takes. State the refusal leaves: the entry of the window, which is the state at the start of the run.
test_a_shared_slot_walk_past_its_deadline_refuses_in_the_preflight_window() {
  local c
  c=$(make_scan_case walk-w1 8)
  add_fd_git_shim "$c"
  make_gate_bin "$c/gate" fm_meta_get 'require_shared_task_worktree_slot *' '*'
  start_scan_teardown "$c" "$c/gate/bin" FM_TEARDOWN_SCAN_DEADLINE_SECS=3
  walk_case_outcome "shared-slot walk" "$c" "$c" refuse "$(walk_main_line 'require_shared_task_worktree_slot || exit 1')" require_shared_task_worktree_slot
  assert_grep "shared-slot walk for task task-x1" "$c/out" "shared-slot walk: the refusal does not name the walk"
  assert_present "$c/pool/9/repo" "shared-slot walk: the refusal removed the copy"
  rm -f "$c/block/blocked.walk"
  run_scan_teardown "$c" "$SCAN_BIN"
  expect_code 0 "$(cat "$c/rc")" "shared-slot walk: the retry should finish: $(tail -3 "$c/out")"
  assert_absent "$c/state/task-x1.meta" "shared-slot walk: the retry left the task record"
  pass "window 1 (preflight): the shared-slot walk past its deadline refuses, leaves the start state, frees the lock, and a retry finishes"
}

test_mutant_without_the_walk_check_the_shared_slot_walk_is_not_refused() {
  local c
  c=$(make_scan_case walk-w1-mutant 8)
  add_fd_git_shim "$c"
  make_gate_bin "$c/gate" fm_meta_get 'require_shared_task_worktree_slot *' '*' check-off
  start_scan_teardown "$c" "$c/gate/bin" FM_TEARDOWN_SCAN_DEADLINE_SECS=3
  walk_case_outcome "shared-slot walk (check off)" "$c" "$c" unbounded "$(walk_main_line 'require_shared_task_worktree_slot || exit 1')" require_shared_task_worktree_slot
}

# Window 2, the "absent" branch: the record's copy is nested in a pool slot whose claim file is gone, so the teardown runs
# teardown_release_enclosing_slot under the lock, before the bounded scan that follows; its prove step walks the task records
# for peers (teardown_slot_peers_detect). State the refusal leaves: the window's entry, before the slot's reservation.
walk_absent_case() {  # <label> [mutant]
  local c
  make_nested_slot_case "walk-$1" enclosing .claude/worktrees/fc-one > /dev/null
  c=$NESTED_CASE
  rm -f "$c/pool/1/.fm-slot-owner"
  add_filler_records "$c/state" "$c" 8
  make_gate_bin "$c/gate" fm_task_copy_canonical_dir 'teardown_slot_peers_detect *' '*/pool/fill-*' "${2:-}"
  start_walk_teardown "$c" "$c/gate/bin" "$c/home" FM_TEARDOWN_SCAN_DEADLINE_SECS=3
  if [ -n "${2:-}" ]; then
    walk_case_outcome "absent-branch walk ($2)" "$c" "$c/home" unbounded "$(walk_main_line 'absent) teardown_release_enclosing_slot || exit 1')" teardown_slot_peers_detect
    return 0
  fi
  walk_case_outcome "absent-branch walk" "$c" "$c/home" refuse "$(walk_main_line 'absent) teardown_release_enclosing_slot || exit 1')" teardown_slot_peers_detect teardown_nested_slot teardown_release_enclosing_slot
  assert_grep "peer walk for task task-x1" "$c/out" "absent-branch walk: the refusal does not name the walk"
  assert_present "$NESTED_COPY" "absent-branch walk: the refusal removed the copy"
  rm -f "$c/code-root/bin" "$c/block/blocked.walk"
  ln -s "$SCAN_BIN" "$c/code-root/bin"
  start_walk_teardown "$c" "$SCAN_BIN" "$c/home"
  finish_scan_teardown "$c"
  expect_code 0 "$(cat "$c/rc")" "absent-branch walk: the retry should finish: $(tail -3 "$c/out")"
  assert_absent "$c/state/task-x1.meta" "absent-branch walk: the retry left the task record"
}

test_a_peer_walk_past_its_deadline_refuses_in_the_slot_reservation_window() {
  walk_absent_case w2
  pass "window 2 (absent-claim branch): the peer walk past its deadline refuses, leaves the window's entry state, frees the lock, and a retry finishes"
}

test_mutant_without_the_walk_check_the_peer_walk_is_not_refused() {
  walk_absent_case w2-mutant check-off
}

CASES=(
  test_a_scan_past_its_deadline_refuses_in_the_preflight_window
  test_a_scan_past_its_deadline_refuses_in_the_slot_reservation_window
  test_a_scan_past_its_deadline_refuses_in_the_final_return_window
  test_a_scan_without_the_lock_is_not_bounded_by_the_deadline
  test_sigterm_while_the_scan_waits_on_a_producer_that_ignores_it_still_ends_the_teardown
  test_sigterm_while_the_scan_waits_on_a_forked_producer_that_ignores_it_ends_the_teardown
  test_sigterm_after_the_first_destructive_step_leaves_a_retry_that_finishes
  test_sigterm_during_the_scan_ends_the_whole_group_with_the_lock_released
  test_a_foreign_copy_walk_past_its_deadline_refuses_in_the_final_return_window
  test_mutant_without_the_foreign_copy_deadline_the_walk_is_not_refused
  test_a_shared_slot_walk_past_its_deadline_refuses_in_the_preflight_window
  test_mutant_without_the_walk_check_the_shared_slot_walk_is_not_refused
  test_a_peer_walk_past_its_deadline_refuses_in_the_slot_reservation_window
  test_mutant_without_the_walk_check_the_peer_walk_is_not_refused
)

fm_test_run_cases "${CASES[@]}" -- "$@"
echo "# all fm-teardown-scan-bounds tests passed"
