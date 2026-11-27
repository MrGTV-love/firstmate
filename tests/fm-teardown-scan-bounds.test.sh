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
#   6. A walk is bounded whichever project lock it runs under: the teardown's own, or a child project lock of a forced
#      secondmate teardown (teardown_project_lock_held). One case per site, each through the real script, each with the walk
#      held at its first record: the copy-clearance scan of the preflight, of the child return, of the child slot and of a
#      child secondmate's home under legacy custody (a Treehouse with no lease command), the docker-stack and registered-lane
#      walks under legacy custody, and the inner pass of the released-root proof (fm_task_copy_prior_root_released); mutants
#      that take the arming or the inner check away; a forced secondmate teardown with no project lock stays unbounded; and
#      two static cases pin the lock fact and the list of places that take a project lock.
# Usage: bash tests/fm-teardown-scan-bounds.test.sh [test_function_name ...]
# The cases source libraries inside subshells on purpose, so a variable they set there is not the suite's own.
# The snapshot lists names only, with no newline in any.
# SC2016: the cases look up statements of bin/fm-teardown.sh by their text, in single quotes, and mean no expansion.
# shellcheck disable=SC2012,SC2016,SC2030,SC2031
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

# make_gate_bin <dir> <function> <stack-glob> <arg-glob> [mutant] [<index>:<line>]: <dir>/bin holds symlinks to every bin file
# but the ones it changes. The one that defines <function> gets a gate: the first time <function> is called with a first
# argument matching <arg-glob> and a call stack (the names of its callers, innermost first, joined by spaces) matching
# <stack-glob> while the teardown holds ANY project lock (its own, TREEHOUSE_PROJECT_LOCK_HELD, or a child lock of a forced
# secondmate teardown, DESCENDANT_TREEHOUSE_LOCK_PATHS; the gate reads those two records itself, so it works against an older
# bin too; with FM_GATE_NOLOCK set in the run's environment it blocks with no lock held, for the case that shows a walk
# outside any lock stays unbounded) it writes the call stack to $FM_BLOCK_DIR/blocked.walk and waits (at most 5 minutes) for $FM_BLOCK_DIR/release.walk.
# <index>:<line> also requires BASH_LINENO[<index>] to be <line>: the statement of the caller that made the call.
# A mutant also changes the library (isolated copies, never the real one): "nested-hand-over" makes the foreign-copy walk
# unbounded; "check-off" makes teardown_scan_deadline_check do nothing; "main-lock-only" arms the bound for the teardown's
# own lock only (what the first round-two head did); "inner-off" takes the deadline out of fm_task_copy_prior_root_released.
make_gate_bin() {
  local dir=$1 fn=$2 caller=$3 glob=$4 mutant=${5:-} at=${6:-} src=${FM_HANG_SRC_BIN:-$SCAN_BIN} f
  mkdir -p "$dir/bin"
  for f in "$src"/*; do ln -s "$f" "$dir/bin/${f##*/}"; done
  python3 -I - "$src" "$dir/bin" "$fn" "$caller" "$glob" "$mutant" "$at" <<'PY' || fail "could not build the gate bin for $fn ($mutant)"
import glob, os, re, sys
src, dst, fn, caller, pat, mutant, at = sys.argv[1:8]
extra = ''
if at:
    idx, line = at.split(':')
    extra = ' && [ "${BASH_LINENO[%s]}" = "%s" ]' % (idx, line)
gate = (
    '  case "${FUNCNAME[*]:1}" in %s)\n'
    '    case "$1" in %s)\n'
    '      if { [ "${TREEHOUSE_PROJECT_LOCK_HELD:-0}" = 1 ] || [ -n "${DESCENDANT_TREEHOUSE_LOCK_PATHS[*]+held}" ] || [ -n "${FM_GATE_NOLOCK:-}" ]; } && [ ! -e "$FM_BLOCK_DIR/blocked.walk" ]%s; then\n'
    '        echo "${FUNCNAME[*]} :: ${BASH_LINENO[*]}" > "$FM_BLOCK_DIR/blocked.walk"\n'
    '        _gw=0; while [ ! -e "$FM_BLOCK_DIR/release.walk" ] && [ "$_gw" -lt 3000 ]; do sleep 0.1; _gw=$((_gw + 1)); done\n'
    '      fi ;;\n'
    '    esac ;;\n'
    '  esac\n') % (caller.replace(' ', '\\ '), pat, extra)
texts = {}
def get(name):
    if name not in texts:
        texts[name] = open(os.path.join(src, name)).read()
    return texts[name]
hits = []
for path in sorted(glob.glob(os.path.join(src, "*.sh"))):
    text = open(path).read()
    if re.search(r'^%s\(\) \{[^\n]*\n' % re.escape(fn), text, re.M):
        hits.append(os.path.basename(path))
if len(hits) != 1:
    sys.exit(1)
text = get(hits[0])
m = re.search(r'^%s\(\) \{[^\n]*\n' % re.escape(fn), text, re.M)
texts[hits[0]] = text[:m.end()] + gate + text[m.end():]
def change(name, old, new, last=False):
    text = get(name)
    if text.count(old) < 1 or (not last and text.count(old) != 1):
        sys.exit(1)
    k = text.rindex(old) if last else text.index(old)
    texts[name] = text[:k] + new + text[k + len(old):]
if mutant == "nested-hand-over":
    change("fm-teardown-nested-lib.sh", '  FM_TASK_COPY_SCAN_LIMIT_SECS=$scan_limit\n', '  FM_TASK_COPY_SCAN_LIMIT_SECS=0\n')
elif mutant == "check-off":
    change("fm-teardown-nested-lib.sh", '  [ "$1" -le 0 ] || [ "$SECONDS" -lt "$1" ] || teardown_scan_deadline_refuse "$2" "$3"\n', '  :\n')
elif mutant == "main-lock-only":
    change("fm-teardown-nested-lib.sh",
           '  [ "${TREEHOUSE_PROJECT_LOCK_HELD:-0}" = 1 ] || [ -n "${DESCENDANT_TREEHOUSE_LOCK_PATHS[*]+held}" ]\n',
           '  [ "${TREEHOUSE_PROJECT_LOCK_HELD:-0}" = 1 ]\n')
elif mutant == "inner-off":
    change("fm-task-copy-lib.sh", '      [ "$scan_end" -le 0 ] || [ "$SECONDS" -lt "$scan_end" ] || return 3\n', '      :\n', last=True)
elif mutant:
    sys.exit(1)
for name, body in texts.items():
    if os.path.islink(os.path.join(dst, name)):
        os.unlink(os.path.join(dst, name))
    open(os.path.join(dst, name), "w").write(body)
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
  entry=$(${WALK_SNAPSHOT:-walk_snapshot} "$c")
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
  after=$(${WALK_SNAPSHOT:-walk_snapshot} "$c")
  [ "$entry" = "$after" ] || fail "$label: the refusal changed state after the walk began:$(printf '\n'; diff <(printf '%s\n' "$entry") <(printf '%s\n' "$after"))"
  [ "$(project_lock_state "$c" "$home")" = free ] || fail "$label: the project lock was not released by the refusal"
  [ -z "$(lock_artefacts "$home")" ] || fail "$label: lock entries remain: $(lock_artefacts "$home")"
  assert_present "${WALK_RECORD:-$c/state/task-x1.meta}" "$label: the refusal removed the task record"
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

# --- a forced secondmate teardown: the child project locks (the third round) ---------------------------------------------
# A forced teardown of a secondmate holds Treehouse project locks of its own, one per project that holds a child's pool slot
# (bin/fm-teardown.sh preflight_descendant_treehouse_slots, and the child return in cleanup_firstmate_home_children), while
# its own TREEHOUSE_PROJECT_LOCK_HELD stays 0. Every walk under such a lock takes the same deadline (teardown_project_lock_held).
# The shapes: "capable" is a Treehouse with the lease command (the preflight's locks end with the preflight, and each child
# return takes its own), "leaseless" is one without it (the preflight's locks stay held through the whole child cleanup), and
# "nolock" is a child whose copy is in no pool, so the teardown takes no project lock at all.

# dsc_make_case <name> <capable|leaseless|nolock> [inner]: the secondmate "retire" with one child scout "child" in a pool slot
# (shape nolock: a plain copy), 8 other task records in a registered home h1, with "inner" a child secondmate of its own (id aaa-inner, so it is the FIRST child of the loop: the loop's own deadline counts the cleanup of the children before it, and a case that gated a later child failed once under a host load of 70 because the first child's cleanup took longer than the case's 3 s deadline), and with
# DSC_TWO=1 a second child scout "child2" in a second slot of the same project.
# Fake tmux, treehouse and docker. Sets DSC_CASE, DSC_HOME, DSC_CHILD_HOME.
dsc_make_case() {
  local name=$1 shape=$2 inner=${3:-} case_dir home slot child_home fakebin inner_home
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = lease ] && [ "${2:-}" = --help ]; then
  if [ -n "${FM_FAKE_NO_LEASE:-}" ]; then echo 'Error: unknown command "lease" for "treehouse"' >&2; exit 1; fi
  printf 'Usage:\n  treehouse lease <name> [flags]\n\nFlags:\n      --lease-holder string   Optional label recorded as the lease holder\n'
  exit 0
fi
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "${1:-}" in
  status)
    while IFS= read -r line; do
      case "$line" in "worktree "*) wt=${line#worktree } ;; *) continue ;; esac
      [ -f "${wt%/*/*}/treehouse-state.json" ] || continue
      jq -c '[.worktrees[]? | {name, path, lease_holder: (.lease_holder // ""), processes: []}]' "${wt%/*/*}/treehouse-state.json"
      exit 0
    done < <(git worktree list --porcelain 2>/dev/null)
    printf '[]\n'
    ;;
  lease)
    [ -z "${FM_FAKE_NO_LEASE:-}" ] || { echo 'Error: unknown command "lease" for "treehouse"' >&2; exit 1; }
    [ "$#" -eq 4 ] && [ "$3" = --lease-holder ] && [ -n "$4" ] || exit 2
    state=
    while IFS= read -r line; do
      case "$line" in "worktree "*) wt=${line#worktree } ;; *) continue ;; esac
      [ -f "${wt%/*/*}/treehouse-state.json" ] || continue
      jq -e --arg name "$2" 'any(.worktrees[]; .name == $name)' "${wt%/*/*}/treehouse-state.json" >/dev/null || continue
      state="${wt%/*/*}/treehouse-state.json"
      break
    done < <(git worktree list --porcelain 2>/dev/null)
    [ -n "$state" ] || { echo "Error: no worktree named \"$2\" in pool" >&2; exit 1; }
    jq --arg name "$2" --arg holder "$4" '(.worktrees[] | select(.name == $name)) |= (.leased = true | .lease_holder = $holder)' \
      "$state" > "$state.next" && mv "$state.next" "$state" || exit 1
    ;;
  return)
    slot=${@: -1}
    state="${slot%/*/*}/treehouse-state.json"
    if [ -f "$state" ]; then
      jq --arg slot "$slot" '(.worktrees[] | select(.path == $slot)).leased = false' "$state" > "$state.next" && mv "$state.next" "$state" || exit 1
    fi
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_fake_docker "$fakebin"
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  home="$case_dir/home"
  child_home="$case_dir/retired-home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects" "$child_home/state" "$child_home/config" "$child_home/data" \
    "$child_home/projects" "$case_dir/h1/state" "$case_dir/h1/data"
  touch "$home/state/.last-watcher-beat" "$child_home/state/.last-watcher-beat"
  printf 'codex\n' | tee "$home/config/crew-harness" > "$child_home/config/crew-harness"
  printf 'manual\n' | tee "$home/config/backlog-backend" > "$child_home/config/backlog-backend"
  if [ "$shape" = nolock ]; then
    slot="$case_dir/plain-copy"
    git -C "$case_dir/project" worktree add --quiet --detach "$slot"
  else
    slot="$case_dir/pool/1/project"
    mkdir -p "${slot%/*}"
    git -C "$case_dir/project" worktree add --quiet --detach "$slot"
    printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$slot" > "$case_dir/pool/treehouse-state.json"
    printf 'task=child\nhome=%s\n' "$child_home" > "${slot%/*}/.fm-slot-owner"
  fi
  printf 'retire\n' > "$child_home/.fm-secondmate-home"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$home" > "$child_home/.fm-secondmate-parent"
  printf -- '- retire - local domain (home: %s; scope: fixtures; projects: project; added 2026-10-12)\n- h1 - fixture (home: %s; scope: x; projects: y; added 2026-01-01)\n' \
    "$child_home" "$case_dir/h1" > "$home/data/secondmates.md"
  fm_write_secondmate_meta "$home/state/retire.meta" "$child_home"
  fm_write_meta "$child_home/state/child.meta" \
    "window=firstmate:fm-child" "endpoint_task_id=child" \
    "worktree=$slot" "project=$case_dir/project" "kind=scout" "harness=codex"
  if [ -n "$inner" ]; then
    inner_home="$case_dir/inner-home"
    mkdir -p "$inner_home/state" "$inner_home/config" "$inner_home/data" "$inner_home/projects"
    touch "$inner_home/state/.last-watcher-beat"
    printf 'codex\n' > "$inner_home/config/crew-harness"
    printf 'manual\n' > "$inner_home/config/backlog-backend"
    printf 'aaa-inner\n' > "$inner_home/.fm-secondmate-home"
    printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$child_home" > "$inner_home/.fm-secondmate-parent"
    printf -- '- aaa-inner - nested domain (home: %s; scope: fixtures; projects: project; added 2026-10-12)\n' "$inner_home" > "$child_home/data/secondmates.md"
    fm_write_secondmate_meta "$child_home/state/aaa-inner.meta" "$inner_home"
  fi
  if [ -n "${DSC_TWO:-}" ]; then
    git -C "$case_dir/project" worktree add --quiet --detach "$case_dir/pool/2/project"
    printf '{"worktrees":[{"name":"1","path":"%s","leased":false},{"name":"2","path":"%s","leased":false}]}\n' \
      "$slot" "$case_dir/pool/2/project" > "$case_dir/pool/treehouse-state.json"
    printf 'task=child2\nhome=%s\n' "$child_home" > "$case_dir/pool/2/.fm-slot-owner"
    fm_write_meta "$child_home/state/child2.meta" \
      "window=firstmate:fm-child2" "endpoint_task_id=child2" \
      "worktree=$case_dir/pool/2/project" "project=$case_dir/project" "kind=scout" "harness=codex"
  fi
  add_filler_records "$case_dir/h1/state" "$case_dir" 8
  DSC_CASE=$case_dir
  DSC_HOME=$home
  DSC_CHILD_HOME=$child_home
}

# dsc_snapshot <case-dir>: what a retry depends on, with the lock artefacts left out: the names and record sums of every state
# directory, the pool tree and its state, the slot claims, the registered copies, the data names, and every call the fakes saw.
dsc_snapshot() {
  local c=$1 f d
  (
    cd "$c" || exit 1
    for d in home retired-home inner-home h1; do
      [ -d "$d/state" ] || continue
      echo "$d state:"
      # shellcheck disable=SC2010,SC2012 # names only, none with a newline
      ls -A "$d/state" | grep -v -e lock -e '^[.]teardown-run[.]' | LC_ALL=C sort
      for f in "$d"/state/*.meta; do [ ! -e "$f" ] || printf '%s %s\n' "$f" "$(cksum < "$f")"; done
      echo "$d data:"
      ls -A "$d/data" 2>&1 | LC_ALL=C sort
    done
    echo "copies:"
    git -C project worktree list --porcelain
    echo "pool:"
    [ ! -d pool ] || find pool -not -path '*/.git/*' -not -path '*/.git' -print | LC_ALL=C sort
    cat pool/treehouse-state.json 2>&1
    for f in pool/*/.fm-slot-owner; do [ ! -e "$f" ] || { echo "$f"; cat "$f"; }; done
    echo "calls:"
    cat calls.log
  )
}

# start_dsc_teardown <case-dir> <bin-dir> [NAME=value ...]: the real forced teardown of the secondmate "retire" in its own process
# group; output in <case-dir>/out, leader in SCAN_PID. The environment is the one tests/fm-project-capacity.test.sh gives it.
start_dsc_teardown() {
  local c=$1 bindir=$2 kv
  shift 2
  mkdir -p "$c/block" "$c/hhome"
  (
    export HOME="$c/hhome" FM_HOME="$c/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
      FM_FAKE_CALL_LOG="$c/calls.log" FM_BLOCK_DIR="$c/block" PATH="$c/fakebin:$PATH" NM_HOME="$c/nm"
    for kv in "$@"; do export "${kv?}"; done
    exec python3 -I -c 'import os,sys; os.setpgrp(); os.execv(sys.argv[1], sys.argv[1:])' \
      /bin/bash "$bindir/fm-teardown.sh" retire --force --drop-file "$(fm_test_drop_file)"
  ) > "$c/out" 2>&1 < /dev/null &
  SCAN_PID=$!
  printf '%s\n' "$SCAN_PID" > "$c/leader"
}

# dsc_walk_case <label> <shape> <function> <stack> <arg> <main-pattern> <after-pattern> <mutant> <at> <fragment>...:
# a forced secondmate teardown in which the gated walk is held at its first record until its deadline has passed. A mutant takes the
# deadline away and the case asserts there was no refusal; without one it asserts the refusal, that the state at the block is the
# state after it, that it names the walk ($DSC_NAME, when set), that the lock is released, and that the retry finishes the teardown (and so is a healthy run).
dsc_walk_case() {
  local label=$1 shape=$2 fn=$3 stack=$4 arg=$5 mainpat=$6 after=$7 mutant=$8 at=$9 c line
  shift 9
  dsc_make_case "dsc-$label" "$shape" "${DSC_INNER:-}"
  c=$DSC_CASE
  [ "$shape" != leaseless ] || export FM_FAKE_NO_LEASE=1
  [ -z "$at" ] || at="${at%%:*}:$(walk_main_line "${at#*:}" "$after")"
  line=$(walk_main_line "$mainpat" "${after:-}")
  [ -z "$at" ] || [ "${at#*:}" != "" ] || fail "$label: the statement the gate is pinned to is not in bin/fm-teardown.sh"
  make_gate_bin "$c/gate" "$fn" "$stack" "$arg" "$mutant" "$at"
  WALK_SNAPSHOT=dsc_snapshot WALK_RECORD="$DSC_HOME/state/retire.meta" start_dsc_teardown "$c" "$c/gate/bin" FM_TEARDOWN_SCAN_DEADLINE_SECS=3 ${FM_FAKE_NO_LEASE:+FM_FAKE_NO_LEASE=1}
  if [ -n "$mutant" ]; then
    WALK_SNAPSHOT=dsc_snapshot WALK_RECORD="$DSC_HOME/state/retire.meta" walk_case_outcome "$label ($mutant)" "$c" "$DSC_HOME" unbounded "$line" "$@"
    unset FM_FAKE_NO_LEASE
    return 0
  fi
  WALK_SNAPSHOT=dsc_snapshot WALK_RECORD="$DSC_HOME/state/retire.meta" walk_case_outcome "$label" "$c" "$DSC_HOME" refuse "$line" "$@"
  [ -z "${DSC_NAME:-}" ] || assert_grep "$DSC_NAME" "$c/out" "$label: the refusal does not name its walk ($DSC_NAME)"
  # The retry: the real library, the default deadline, and the forced teardown finishes.
  rm -f "$c/block/blocked.walk" "$c/block/release.walk"
  start_dsc_teardown "$c" "$SCAN_BIN" ${FM_FAKE_NO_LEASE:+FM_FAKE_NO_LEASE=1}
  finish_scan_teardown "$c"
  expect_code 0 "$(cat "$c/rc")" "$label: the retry should finish: $(tail -5 "$c/out")"
  assert_absent "$DSC_HOME/state/retire.meta" "$label: the retry left the secondmate record"
  assert_absent "$DSC_CHILD_HOME" "$label: the retry left the secondmate home"
  unset FM_FAKE_NO_LEASE
}

CLEAR_STACK_PRE='require_cleanup_copy_clearance require_exclusive_worktree_slot_record'

# Site 1 (bin/fm-teardown.sh preflight_descendant_treehouse_slots -> require_exclusive_worktree_slot_record): the copy-clearance
# scan the preflight runs for each child pool slot, under the child project lock it has just taken.
test_a_child_slot_scan_past_its_deadline_refuses_in_the_forced_secondmate_preflight() {
  DSC_NAME="copy-clearance scan for task child" dsc_walk_case dsc-s1 capable fm_task_copy_record_paths_to "$CLEAR_STACK_PRE preflight_descendant_treehouse_slots *" '*/fill-*.meta' \
    'preflight_descendant_treehouse_slots || exit 1' '' '' '' require_cleanup_copy_clearance preflight_descendant_treehouse_slots
  pass "site 1 (forced secondmate preflight, child project lock): the child's copy-clearance scan past its deadline refuses, leaves the start state, frees the lock, and a retry finishes"
}

test_mutant_arming_for_the_teardowns_own_lock_only_the_preflight_scan_is_not_refused() {
  dsc_walk_case dsc-s1-mutant capable fm_task_copy_record_paths_to "$CLEAR_STACK_PRE preflight_descendant_treehouse_slots *" '*/fill-*.meta' \
    'preflight_descendant_treehouse_slots || exit 1' '' main-lock-only '' require_cleanup_copy_clearance preflight_descendant_treehouse_slots
}

# Site 2 (cleanup_firstmate_home_children, the child return): the same scan, after the child's endpoint is closed and its project
# lock is waited for and taken.
test_a_child_return_scan_past_its_deadline_refuses_in_the_forced_secondmate_child_return() {
  DSC_NAME="copy-clearance scan for task child" dsc_walk_case dsc-s2 capable fm_task_copy_record_paths_to "$CLEAR_STACK_PRE cleanup_firstmate_home_children *" '*/fill-*.meta' \
    'cleanup_firstmate_home_children "$HOME_PATH" || exit $?' 'teardown_project_lock_wait "$child_project_lock"' '' \
    '2:require_exclusive_worktree_slot_record "$child_meta" "$child_id" "$sub_state" "$child_wt" || return 1' require_cleanup_copy_clearance cleanup_firstmate_home_children
  pass "site 2 (forced secondmate child return, child project lock): the child's copy-clearance scan past its deadline refuses, changes nothing after the block, frees the lock, and a retry finishes"
}

# Site 3 (legacy custody: an installed Treehouse with no lease command keeps every child project lock through the whole child
# cleanup): the scan of the child's slot, the docker-stack walk and the registered-lane walk of the child, and the scan of a
# child secondmate's home.
test_a_child_slot_scan_past_its_deadline_refuses_under_legacy_custody() {
  DSC_NAME="copy-clearance scan for task child" dsc_walk_case dsc-s3-clear leaseless fm_task_copy_record_paths_to "$CLEAR_STACK_PRE cleanup_firstmate_home_children *" '*/fill-*.meta' \
    'cleanup_firstmate_home_children "$HOME_PATH" || exit $?' 'cleanup_firstmate_home_children() {' '' \
    '2:require_exclusive_worktree_slot_record "$child_meta" "$child_id" "$sub_state" "$child_wt" || return 1' require_cleanup_copy_clearance cleanup_firstmate_home_children
  pass "site 3 (legacy custody): the child slot's copy-clearance scan past its deadline refuses, frees the locks, and a retry finishes"
}

test_a_docker_stack_walk_past_its_deadline_refuses_under_legacy_custody() {
  DSC_NAME="docker-stack walk for task child" dsc_walk_case dsc-s3-docker leaseless teardown_scan_deadline_check 'teardown_docker_stacks cleanup_firstmate_home_children *' '*' \
    'cleanup_firstmate_home_children "$HOME_PATH" || exit $?' '' '' '' teardown_docker_stacks cleanup_firstmate_home_children
  pass "site 3 (legacy custody): the child's docker-stack walk past its deadline refuses, frees the locks, and a retry finishes"
}

test_mutant_arming_for_the_teardowns_own_lock_only_the_docker_stack_walk_is_not_refused() {
  dsc_walk_case dsc-s3-docker-mutant leaseless teardown_scan_deadline_check 'teardown_docker_stacks cleanup_firstmate_home_children *' '*' \
    'cleanup_firstmate_home_children "$HOME_PATH" || exit $?' '' main-lock-only '' teardown_docker_stacks cleanup_firstmate_home_children
}

test_a_registered_lane_walk_past_its_deadline_refuses_under_legacy_custody() {
  DSC_NAME="registered-lane walk for task child" dsc_walk_case dsc-s3-lanes leaseless teardown_scan_deadline_check 'task_registered_lanes_under_roots teardown_docker_stacks cleanup_firstmate_home_children *' '*' \
    'cleanup_firstmate_home_children "$HOME_PATH" || exit $?' '' '' '' task_registered_lanes_under_roots teardown_docker_stacks
  pass "site 3 (legacy custody): the child's registered-lane walk past its deadline refuses, frees the locks, and a retry finishes"
}

test_a_child_secondmate_home_scan_past_its_deadline_refuses_under_legacy_custody() {
  DSC_INNER=1 DSC_NAME="copy-clearance scan for task aaa-inner" dsc_walk_case dsc-s3-home leaseless fm_task_copy_record_paths_to 'require_cleanup_copy_clearance cleanup_firstmate_home_children *' '*/fill-*.meta' \
    'cleanup_firstmate_home_children "$HOME_PATH" || exit $?' 'cleanup_firstmate_home_children() {' '' \
    '1:require_cleanup_copy_clearance "$child_meta" "$child_id" "$sub_state" "$child_home" home || return 1' require_cleanup_copy_clearance cleanup_firstmate_home_children
  pass "site 3 (legacy custody): a child secondmate's home scan past its deadline refuses, frees the locks, and a retry finishes"
}

# Site 3 also holds the loop over the children itself (cleanup_firstmate_home_children): under legacy custody it starts under the child
# project lock and does real work for each child, so it is checked before each child. Two children: the first is held at its first step
# (a call both heads make), the deadline passes, and the second child's check refuses. The refusal leaves the first child cleaned up (its
# record gone, its slot returned) and the second child untouched; the retry finishes.
walk_children_case() {  # <label> [mutant]
  local c rc
  DSC_TWO=1 dsc_make_case "dsc-$1" leaseless
  c=$DSC_CASE
  export FM_FAKE_NO_LEASE=1
  make_gate_bin "$c/gate" teardown_preserves_reassociated_copy 'cleanup_firstmate_home_children *' '*/child.meta' "${2:-}"
  start_dsc_teardown "$c" "$c/gate/bin" FM_TEARDOWN_SCAN_DEADLINE_SECS=3 FM_FAKE_NO_LEASE=1
  wait_for_file "$c/block/blocked.walk"
  [ "$(project_lock_state "$c" "$DSC_HOME")" = held ] || fail "child loop: the cleanup does not hold the project lock (the case would prove nothing)"
  assert_contains "$(cat "$c/block/blocked.walk")" "teardown_preserves_reassociated_copy cleanup_firstmate_home_children" "child loop: the gate caught another call"
  wait_until_clock_passes 4
  : > "$c/block/release.walk"
  finish_scan_teardown "$c"
  rc=$(cat "$c/rc")
  if [ -n "${2:-}" ]; then
    expect_code 0 "$rc" "child loop ($2): the mutant should finish: $(tail -3 "$c/out")"
    assert_no_grep "scan deadline" "$c/out" "child loop ($2): the mutant refused all the same"
    pass "child loop ($2): without the deadline the cleanup past 4 s is not refused, so the refusal case tests the deadline"
    unset FM_FAKE_NO_LEASE
    return 0
  fi
  expect_code 1 "$rc" "child loop: the cleanup past its deadline should refuse: $(tail -3 "$c/out")"
  assert_grep "child cleanup walk of $DSC_CHILD_HOME ran past its 3s scan deadline" "$c/out" "child loop: the refusal does not name the walk"
  assert_grep "retry the teardown" "$c/out" "child loop: the refusal does not say a retry is safe"
  assert_absent "$DSC_CHILD_HOME/state/child.meta" "child loop: the first child was not cleaned up before the refusal"
  assert_present "$DSC_CHILD_HOME/state/child2.meta" "child loop: the refusal removed the second child's record"
  assert_present "$c/pool/2/project" "child loop: the refusal removed the second child's slot"
  assert_present "$DSC_HOME/state/retire.meta" "child loop: the refusal removed the secondmate's record"
  [ "$(project_lock_state "$c" "$DSC_HOME")" = free ] || fail "child loop: the project lock was not released by the refusal"
  [ -z "$(lock_artefacts "$DSC_HOME")" ] || fail "child loop: lock entries remain: $(lock_artefacts "$DSC_HOME")"
  rm -f "$c/block/blocked.walk" "$c/block/release.walk"
  start_dsc_teardown "$c" "$SCAN_BIN" FM_FAKE_NO_LEASE=1
  finish_scan_teardown "$c"
  expect_code 0 "$(cat "$c/rc")" "child loop: the retry should finish: $(tail -5 "$c/out")"
  assert_absent "$DSC_HOME/state/retire.meta" "child loop: the retry left the secondmate record"
  assert_absent "$DSC_CHILD_HOME" "child loop: the retry left the secondmate home"
  unset FM_FAKE_NO_LEASE
}

test_the_child_cleanup_loop_past_its_deadline_refuses_before_the_next_child_under_legacy_custody() {
  walk_children_case children
  pass "site 3 (legacy custody): the child cleanup loop past its deadline refuses before the next child, leaves the first cleaned up and the second untouched, frees the locks, and a retry finishes"
}

test_mutant_arming_for_the_teardowns_own_lock_only_the_child_cleanup_loop_is_not_refused() {
  walk_children_case children-mutant main-lock-only
}

# Site 4 (bin/fm-task-copy-lib.sh fm_task_copy_prior_root_released): the inner pass over every record that the peer walk runs for a
# record naming the slot. The peer record is the last record, so no later per-record check of the outer walk could refuse for it.
walk_inner_case() {  # <label> [mutant]
  local c peer
  make_nested_slot_case "walk-$1" enclosing .claude/worktrees/fc-one > /dev/null
  c=$NESTED_CASE
  rm -f "$c/pool/1/.fm-slot-owner"
  peer="$NESTED_SLOT/.claude/worktrees/peer"
  git -C "$c/project" worktree add -q -b fm/peer "$peer" main
  fm_write_meta "$c/state/zz-peer.meta" "window=firstmate:fm-peer" "endpoint_task_id=peer" "worktree=$peer" "branch=fm/peer" \
    "project=$c/project" "kind=ship" "spawn_gen=peer-gen" "prior_worktree=$NESTED_SLOT"
  add_filler_records "$c/state" "$c" 8
  make_gate_bin "$c/gate" fm_task_copy_canonical_dir 'fm_task_copy_prior_root_released teardown_slot_peers_detect *' '*/pool/fill-*' "${2:-}"
  start_walk_teardown "$c" "$c/gate/bin" "$c/home" FM_TEARDOWN_SCAN_DEADLINE_SECS=3
  if [ -n "${2:-}" ]; then
    walk_case_outcome "inner pass ($2)" "$c" "$c/home" unbounded "$(walk_main_line 'absent) teardown_release_enclosing_slot || exit 1')" fm_task_copy_prior_root_released
    return 0
  fi
  walk_case_outcome "inner pass" "$c" "$c/home" refuse "$(walk_main_line 'absent) teardown_release_enclosing_slot || exit 1')" fm_task_copy_prior_root_released teardown_slot_peers_detect teardown_nested_slot
  assert_grep "peer walk for task task-x1" "$c/out" "inner pass: the refusal does not name the walk"
  assert_present "$NESTED_COPY" "inner pass: the refusal removed the copy"
  rm -f "$c/code-root/bin" "$c/block/blocked.walk" "$c/block/release.walk"
  ln -s "$SCAN_BIN" "$c/code-root/bin"
  start_walk_teardown "$c" "$SCAN_BIN" "$c/home"
  finish_scan_teardown "$c"
  expect_code 0 "$(cat "$c/rc")" "inner pass: the retry should finish: $(tail -3 "$c/out")"
  assert_absent "$c/state/task-x1.meta" "inner pass: the retry left the task record"
}

test_the_inner_pass_over_every_record_past_its_deadline_refuses() {
  walk_inner_case inner
  pass "site 4 (fm_task_copy_prior_root_released): the inner pass past its caller's deadline refuses, leaves the window's entry state, frees the lock, and a retry finishes"
}

test_mutant_without_the_inner_pass_check_the_inner_pass_is_not_refused() {
  walk_inner_case inner-mutant inner-off
}

# A forced secondmate teardown whose child copy is in no pool takes no project lock, so the same walk is not bounded.
test_a_forced_secondmate_walk_without_a_project_lock_is_not_bounded() {
  local c
  dsc_make_case dsc-nolock nolock
  c=$DSC_CASE
  make_gate_bin "$c/gate" fm_task_copy_record_paths_to 'require_cleanup_copy_clearance cleanup_firstmate_home_children *' '*/fill-*.meta'
  start_dsc_teardown "$c" "$c/gate/bin" FM_TEARDOWN_SCAN_DEADLINE_SECS=3 FM_GATE_NOLOCK=1
  wait_for_file "$c/block/blocked.walk"
  [ "$(project_lock_state "$c" "$DSC_HOME")" = free ] || fail "no-lock case: the teardown holds a project lock (the case would prove nothing)"
  wait_until_clock_passes 4
  : > "$c/block/release.walk"
  finish_scan_teardown "$c"
  expect_code 0 "$(cat "$c/rc")" "no-lock case: the teardown should finish: $(tail -5 "$c/out")"
  assert_no_grep "scan deadline" "$c/out" "no-lock case: a walk with no project lock was refused by the scan deadline"
  pass "a forced secondmate teardown that holds no project lock is not bounded by the scan deadline"
}

# The fact every scan bound keys on, teardown_project_lock_held (bin/fm-teardown-nested-lib.sh), is derived from the records the
# lock acquire and release code keeps. These two cases pin it: its truth table under `set -u` with Bash 3.2 (an array a caller never
# declared included), and the list of the places that take a project lock, each of which must leave the record it reads.
test_the_project_lock_fact_follows_the_records_the_lock_code_keeps() {
  local body out
  body=$(awk '/^teardown_project_lock_held\(\) \{/,/^}/' "$SCAN_BIN/fm-teardown-nested-lib.sh")
  [ -n "$body" ] || fail "teardown_project_lock_held is not defined in bin/fm-teardown-nested-lib.sh"
  out=$(/bin/bash -c "set -u
$body
r=''
t() { if teardown_project_lock_held; then r=\$r'held,'; else r=\$r'free,'; fi; }
t                                   # neither record exists (a script that takes no project lock)
TREEHOUSE_PROJECT_LOCK_HELD=0; DESCENDANT_TREEHOUSE_LOCK_PATHS=(); t
TREEHOUSE_PROJECT_LOCK_HELD=1; t
TREEHOUSE_PROJECT_LOCK_HELD=0; DESCENDANT_TREEHOUSE_LOCK_PATHS+=(/x/lock); t
DESCENDANT_TREEHOUSE_LOCK_PATHS=(); t
echo \$r") || fail "the truth-table run failed: $out"
  assert_equals "free,free,held,held,free," "$out" "teardown_project_lock_held does not follow the two lock records"
  pass "teardown_project_lock_held is true for the teardown's own lock or any child lock, false for neither, and safe under set -u"
}

test_every_place_the_teardown_takes_a_project_lock_leaves_the_record_the_scan_bound_reads() {
  python3 -I - "$SCAN_BIN" <<'PY' || fail "a place that takes a project lock does not leave the record teardown_project_lock_held reads (see above)"
import re, sys
src = sys.argv[1]
acq = re.compile(r'\b(fm_project_lock_try|fm_project_lock_acquire|teardown_project_lock_wait)\b')
sites = []
for name in ("fm-teardown.sh", "fm-teardown-nested-lib.sh"):
    lines = open(src + "/" + name).read().split("\n")
    func = None
    for i, l in enumerate(lines):
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) *\{', l)
        if m:
            func = m.group(1)
            if acq.search(l):
                continue
        elif l == "}":
            func = None
        if l.lstrip().startswith("#") or not acq.search(l) or re.match(r'^[A-Za-z_][A-Za-z0-9_]*\(\) *\{', l):
            continue
        sites.append((name, i + 1, func, "\n".join(lines[i:i + 5]), "\n".join(lines[i - 12:i + 12])))
expected = {
    "teardown_project_lock_wait": None,
    "teardown_acquire_project_lock": "TREEHOUSE_PROJECT_LOCK_HELD=1",
    "preflight_descendant_treehouse_slots": "DESCENDANT_TREEHOUSE_LOCK_PATHS+=(",
    "cleanup_firstmate_home_children": "DESCENDANT_TREEHOUSE_LOCK_PATHS+=(",
}
bad = 0
for name, no, func, after, around in sites:
    if func not in expected:
        print("%s:%d: a project lock is taken in %s, which no record of teardown_project_lock_held covers" % (name, no, func)); bad += 1
        continue
    want = expected[func]
    if want and want not in (around if func == "teardown_acquire_project_lock" else after):
        print("%s:%d: %s takes a project lock without leaving %s" % (name, no, func, want)); bad += 1
if not sites:
    print("no site found: the check reads nothing"); bad += 1
print("sites: %s" % ", ".join("%s:%d(%s)" % s[:3] for s in sites))
sys.exit(1 if bad else 0)
PY
  pass "every place bin/fm-teardown.sh takes a project lock leaves the record teardown_project_lock_held reads, and no other place takes one"
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
  test_a_child_slot_scan_past_its_deadline_refuses_in_the_forced_secondmate_preflight
  test_mutant_arming_for_the_teardowns_own_lock_only_the_preflight_scan_is_not_refused
  test_a_child_return_scan_past_its_deadline_refuses_in_the_forced_secondmate_child_return
  test_a_child_slot_scan_past_its_deadline_refuses_under_legacy_custody
  test_a_docker_stack_walk_past_its_deadline_refuses_under_legacy_custody
  test_mutant_arming_for_the_teardowns_own_lock_only_the_docker_stack_walk_is_not_refused
  test_a_registered_lane_walk_past_its_deadline_refuses_under_legacy_custody
  test_a_child_secondmate_home_scan_past_its_deadline_refuses_under_legacy_custody
  test_the_inner_pass_over_every_record_past_its_deadline_refuses
  test_mutant_without_the_inner_pass_check_the_inner_pass_is_not_refused
  test_the_child_cleanup_loop_past_its_deadline_refuses_before_the_next_child_under_legacy_custody
  test_mutant_arming_for_the_teardowns_own_lock_only_the_child_cleanup_loop_is_not_refused
  test_a_forced_secondmate_walk_without_a_project_lock_is_not_bounded
  test_the_project_lock_fact_follows_the_records_the_lock_code_keeps
  test_every_place_the_teardown_takes_a_project_lock_leaves_the_record_the_scan_bound_reads
)

fm_test_run_cases "${CASES[@]}" -- "$@"
echo "# all fm-teardown-scan-bounds tests passed"
