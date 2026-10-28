#!/usr/bin/env bash
# fm-proc-budget.test.sh - bin/fm-proc-budget.sh: the per-tree process budget.
#
# The kernel compares the RLIMIT_NPROC limit with the user's whole process
# count, so a runaway tree can starve every other process of the same user.
# These cases drive the wrapper as a separate process: the limit arithmetic
# against a stub `ps`, the refusals, and the incident reproduction - a shim
# whose `basename` is itself, run under a small budget - which must stop inside
# the budgeted tree while an unbudgeted probe keeps forking.
# Child commands are single-quoted on purpose: they expand in the child bash.
# shellcheck disable=SC2016
set -u
set -o pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

WRAP="$ROOT/bin/fm-proc-budget.sh"
TMP_ROOT=$(fm_test_tmproot fm-proc-budget)

assert_present "$WRAP" "bin/fm-proc-budget.sh is missing"
[ -x "$WRAP" ] || fail "bin/fm-proc-budget.sh must be executable"

# A `ps` that reports a fixed number of processes, so the arithmetic is exact.
mkdir -p "$TMP_ROOT/stub-ps"
cat >"$TMP_ROOT/stub-ps/ps" <<'SH'
#!/bin/sh
i=0
while [ "$i" -lt "${FM_TEST_PS_COUNT:-0}" ]; do
  echo "$i"
  i=$((i + 1))
done
exit "${FM_TEST_PS_STATUS:-0}"
SH
chmod +x "$TMP_ROOT/stub-ps/ps"

# The child is a builtin-only bash, so lowering the limit below the host's real
# process count (the stub reports far fewer) never blocks the child itself.
limit_with_stub() {  # <ps-count> <wrapper args...>
  local count=$1
  shift
  PATH="$TMP_ROOT/stub-ps:$PATH" FM_TEST_PS_COUNT=$count \
    "$WRAP" "$@" -- bash -c 'ulimit -u'
}

effective_limit() {
  local limit=$1 inherited
  for inherited in "$(ulimit -S -u)" "$(ulimit -H -u)"; do
    case "$inherited" in
      ''|*[!0-9]*) ;;
      *) [ "$limit" -lt "$inherited" ] || limit=$inherited ;;
    esac
  done
  printf '%s\n' "$limit"
}

test_default_extra_is_added_to_the_count() {
  local got
  got=$(limit_with_stub 7) || fail "wrapper refused a plain command"
  assert_equals "$(effective_limit 1507)" "$got" "the default budget is the process count plus 1500, capped by inheritance"
  pass "default budget is the current count plus 1500"
}

test_explicit_extra() {
  local got
  got=$(limit_with_stub 7 40) || fail "wrapper refused an explicit extra"
  assert_equals "$(effective_limit 47)" "$got" "an explicit extra replaces the default, capped by inheritance"
  pass "explicit extra sets the budget"
}

test_budget_never_widens_the_inherited_limit() {
  local real low got
  case "$(uname -s)" in
    Linux) real=$(ps -L -U "$(id -u)" -o lwp= | wc -l) || fail "cannot read the baseline task count" ;;
    *) real=$(ps -U "$(id -u)" -o pid= | wc -l) || fail "cannot read the baseline process count" ;;
  esac
  low=$(effective_limit "$((real + 1500))")
  got=$(PATH="$TMP_ROOT/stub-ps:$PATH" FM_TEST_PS_COUNT=100000 \
    bash -c 'ulimit -u "$1" || exit 125; shift; exec "$@"' _ "$low" "$WRAP" 1500 -- \
    bash -c 'printf "%s %s\n" "$(ulimit -S -u)" "$(ulimit -H -u)"') \
    || fail "wrapper failed under a lower inherited limit"
  assert_equals "$low $low" "$got" "a budget above the inherited limit leaves both limits unchanged"
  got=$(PATH="$TMP_ROOT/stub-ps:$PATH" FM_TEST_PS_COUNT=7 \
    bash -c 'ulimit -u "$1" || exit 125; shift; exec "$@"' _ "$low" "$WRAP" 40 -- \
    bash -c 'ulimit -u 99999 2>/dev/null && echo raised; ulimit -u') \
    || fail "wrapper failed under a higher inherited limit"
  assert_equals "$(effective_limit 47)" "$got" "a budget below the inherited limit lowers it, and the child cannot raise it again"
  pass "a budget only ever tightens the limit it inherits"
}

test_retained_soft_limit_seals_the_hard_limit() {
  local real low got
  case "$(uname -s)" in
    Linux) real=$(ps -L -U "$(id -u)" -o lwp= | wc -l) || fail "cannot read the baseline task count" ;;
    *) real=$(ps -U "$(id -u)" -o pid= | wc -l) || fail "cannot read the baseline process count" ;;
  esac
  low=$(effective_limit "$((real + 500))")
  low=$((low - 1))
  got=$(PATH="$TMP_ROOT/stub-ps:$PATH" FM_TEST_PS_COUNT=100000 \
    bash -c 'ulimit -S -u "$1" || exit 125; shift; exec "$@"' _ "$low" "$WRAP" -- \
    bash -c 'ulimit -S -u "$1" 2>/dev/null && echo raised; printf "%s %s\n" "$(ulimit -S -u)" "$(ulimit -H -u)"' _ "$((low + 1))") \
    || fail "wrapper failed under a lower inherited soft limit"
  assert_equals "$low $low" "$got" "a retained soft limit must also seal the hard limit and prevent raising it"
  pass "a retained soft limit seals the inherited hard limit"
}

test_exit_status_and_arguments_pass_through() {
  local rc out
  "$WRAP" 100 -- bash -c 'exit 7'
  rc=$?
  expect_code 7 "$rc" "the child's exit status is the wrapper's"
  out=$("$WRAP" 100 -- printf '%s|' 'a b' c) || fail "arguments were not passed through"
  assert_equals 'a b|c|' "$out" "arguments reach the child intact"
  out=$("$WRAP" -- printf 'x') || fail "omitting the extra must use the default"
  assert_equals x "$out" "-- alone selects the default budget"
  pass "exit status and arguments pass through"
}

test_refusals_never_run_the_command() {
  local rc marker="$TMP_ROOT/ran" args
  for args in "" "nope" "0" "-5" "1.5"; do
    rm -f "$marker"
    if [ -z "$args" ]; then
      "$WRAP" -- 2>/dev/null
    else
      "$WRAP" "$args" -- touch "$marker" 2>/dev/null
    fi
    rc=$?
    expect_code 2 "$rc" "bad extra '${args}'"
    assert_absent "$marker" "a refused call must not run the command (extra '${args}')"
  done
  "$WRAP" 100 touch "$marker" 2>/dev/null
  rc=$?
  expect_code 2 "$rc" "a missing -- separator"
  assert_absent "$marker" "a call without -- must not run the command"

  # No readable process count means no budget can be set; the command must not
  # run unbudgeted behind the caller's back.
  PATH="$TMP_ROOT/stub-ps:$PATH" FM_TEST_PS_COUNT=0 "$WRAP" 100 -- touch "$marker" 2>/dev/null
  rc=$?
  expect_code 125 "$rc" "an empty process count"
  assert_absent "$marker" "an unreadable count must not run the command"
  PATH="$TMP_ROOT/stub-ps:$PATH" FM_TEST_PS_COUNT=50 FM_TEST_PS_STATUS=1 \
    "$WRAP" 100 -- touch "$marker" 2>/dev/null
  rc=$?
  expect_code 125 "$rc" "a failing ps"
  assert_absent "$marker" "a failing ps must not run the command"
  pass "bad calls and an unreadable process count never run the command"
}

# The incident, leashed. Worker fm-board-listener-retire linked `basename` to a
# shim whose first line calls `basename`: every call started another copy, with
# no base case, until the user's process cap stopped it and every other lane
# lost forks. SHIM_MAX_DEPTH is only a safety valve so a regression of the
# wrapper cannot pile up thousands of processes on the host.
make_bomb() {  # <dir>
  local dir=$1 name
  mkdir -p "$dir"
  cat >"$dir/shim.sh" <<'SH'
#!/usr/bin/env bash
SHIM_DEPTH=$(( ${SHIM_DEPTH:-0} + 1 )); export SHIM_DEPTH
printf '%s\n' "$SHIM_DEPTH" >> "$SHIM_LOG"
[ "$SHIM_DEPTH" -le "$SHIM_MAX_DEPTH" ] || exit 99
n=$(basename "$0")
exec "$n" "$@"
SH
  chmod +x "$dir/shim.sh"
  for name in basename date; do ln -sf shim.sh "$dir/$name"; done
}

test_budget_stops_a_runaway_tree_inside_the_tree() {
  local bomb="$TMP_ROOT/bomb" log="$TMP_ROOT/bomb.log" err="$TMP_ROOT/bomb.err"
  local probe="$TMP_ROOT/probe.out" true_bin depth probe_pid rc
  true_bin=/usr/bin/true
  [ -x "$true_bin" ] || true_bin=/bin/true
  make_bomb "$bomb"
  : >"$log"

  # An unbudgeted probe forks as fast as it can for as long as the bomb runs;
  # a fork failure outside the budgeted tree ends it without the done marker.
  bash -c '
    n=0
    while [ ! -e "$2" ]; do "$1" || exit 3; n=$((n + 1)); done
    echo "done $n" >"$3"
  ' _ "$true_bin" "$TMP_ROOT/probe.stop" "$probe" 2>"$TMP_ROOT/probe.err" &
  probe_pid=$!

  fm_run_timed 90 "$WRAP" 300 -- env PATH="$bomb:$PATH" SHIM_LOG="$log" SHIM_MAX_DEPTH=1500 \
    date +%s >"$TMP_ROOT/bomb.out" 2>"$err"
  rc=$?
  : >"$TMP_ROOT/probe.stop"
  wait "$probe_pid"
  expect_code 0 $? "the unbudgeted probe must keep forking while the budgeted tree runs away"

  depth=$(tail -1 "$log")
  [ -n "$depth" ] || fail "the bomb never started: $(cat "$err")"
  [ "$depth" -gt 20 ] || fail "the bomb did not recurse (depth $depth): the case would be vacuous"
  [ "$depth" -lt 1500 ] || fail "the budget did not stop the runaway tree (depth $depth, rc $rc)"
  assert_contains "$(cat "$err")" "Resource temporarily unavailable" \
    "the runaway tree must meet the process limit inside its own tree"
  [ -s "$probe" ] || fail "the probe outside the budget lost a fork: $(cat "$TMP_ROOT/probe.err")"
  assert_contains "$(cat "$probe")" "done " "the probe outside the budget must finish cleanly"
  pass "a budgeted runaway tree stops at depth $depth while an unbudgeted probe forks freely"
}

# Run every memory case inside a real 2 GiB memory stop, including fixtures
# that deliberately break the inner reader. No ad-hoc watchdog is needed.
run_memory_case() {
  "$WRAP" --memory-kib 2097152 -- "$@"
}

memory_supported() {
  if [ "$(uname -s)" != Darwin ]; then
    "$WRAP" --memory-kib 2097152 -- touch "$TMP_ROOT/unsupported-ran" 2>"$TMP_ROOT/unsupported.err"
    expect_code 125 $? "unsupported memory reader refuses before launch"
    assert_absent "$TMP_ROOT/unsupported-ran" "unsupported reader must not launch the command"
    pass "memory stop refuses unsupported hosts before launch"
    return 1
  fi
  return 0
}

assert_memory_pid_ended() {
  local pid=$1 state
  for _ in {1..50}; do
    state=$(python3 "$ROOT/bin/fm-proc-info.py" table pid,stat | while read -r candidate status; do
      [ "$candidate" != "$pid" ] || printf '%s' "$status"
    done)
    case "$state" in
      ''|Z*|*E) return 0 ;;
    esac
    sleep 0.1
  done
  fail "memory stop left descendant $pid alive ($state)"
}

test_memory_tree_over_limit() {
  local rc pid
  cat >"$TMP_ROOT/memory-tree.py" <<'PY'
import os
import subprocess
import sys
import time

if len(sys.argv) == 1:
    subprocess.Popen([sys.executable, __file__, "child"])
    time.sleep(60)
else:
    if sys.argv[1] == "child":
        subprocess.Popen([sys.executable, __file__, "grandchild"])
    with open(os.environ["FM_MEMORY_PIDS"], "a") as handle:
        handle.write(str(os.getpid()) + "\n")
    # Both allocations are finite and together exceed 128 MiB, not 2 GiB.
    allocation = bytearray(80 * 1024 * 1024)
    time.sleep(60)
PY
  FM_MEMORY_PIDS="$TMP_ROOT/memory.pids" run_memory_case \
    "$WRAP" --memory-kib 131072 -- python3 "$TMP_ROOT/memory-tree.py" 2>"$TMP_ROOT/memory.err"
  rc=$?
  expect_code 99 "$rc" "over-limit command tree"
  assert_contains "$(cat "$TMP_ROOT/memory.err")" "exceeded 131072 KiB" "over-limit reason names the bound"
  [ "$(wc -l <"$TMP_ROOT/memory.err" | tr -d ' ')" -eq 1 ] || fail "memory stop must emit exactly one reason"
  [ "$(wc -l <"$TMP_ROOT/memory.pids" | tr -d ' ')" -eq 2 ] || fail "child and grandchild must both have started"
  while read -r pid; do
    assert_memory_pid_ended "$pid"
  done <"$TMP_ROOT/memory.pids"
  pass "over-limit child and grandchild are ended with status 99"
}

test_memory_nested_wrapper() {
  local rc pid
  # The inner wrapper runs its own supervisor with a higher bound. The outer
  # stop must still count and end the inner 192 MiB payload.
  FM_MEMORY_NESTED_PID="$TMP_ROOT/nested-memory.pid" run_memory_case "$WRAP" --memory-kib 131072 -- \
    "$WRAP" --memory-kib 524288 -- python3 -c \
    'import os, time; open(os.environ["FM_MEMORY_NESTED_PID"], "w").write(str(os.getpid())); allocation = bytearray(192 * 1024 * 1024); time.sleep(4); raise SystemExit(7)' \
    2>"$TMP_ROOT/nested-memory.err"
  rc=$?
  expect_code 99 "$rc" "lower outer memory stop covers nested wrapper sessions"
  assert_contains "$(cat "$TMP_ROOT/nested-memory.err")" "exceeded 131072 KiB" "the outer bound, not the higher inner bound, must stop the payload"
  read -r pid <"$TMP_ROOT/nested-memory.pid"
  assert_memory_pid_ended "$pid"
  pass "lower outer limit accounts for and ends payloads in nested wrapper sessions"
}

test_memory_normal_command() {
  local output rc
  output=$(run_memory_case "$WRAP" 1500 --memory-kib 262144 -- bash -c 'printf "%s|" "a b"; sleep 2; exit 7')
  rc=$?
  expect_code 7 "$rc" "under-limit status passes through"
  assert_equals 'a b|' "$output" "under-limit arguments and output are untouched"
  pass "normal memory-bounded command retains output and status"
}

test_memory_setuid_member_is_not_counted() {
  local rc
  # The pipe fills, so the setuid-root ps stays alive across several samples.
  run_memory_case "$WRAP" --memory-kib 262144 -- \
    bash -c '/bin/ps -axwwE -o args -o args | sleep 3; exit 7'
  rc=$?
  expect_code 7 "$rc" "healthy tree with a running setuid ps"
  pass "an unreadable other-user member is left out of the sum and does not end a healthy tree"
}

test_memory_root_exit_ends_leftovers() {
  local start output rc pid
  mkdir -p "$TMP_ROOT/sleep-shim"
  printf '#!/bin/sh\necho "$$" >>"$FM_SLEEP_PIDS"\nexec /bin/sleep "$@"\n' >"$TMP_ROOT/sleep-shim/sleep"
  chmod +x "$TMP_ROOT/sleep-shim/sleep"
  : >"$TMP_ROOT/sleep.pids"
  start=$SECONDS
  output=$(PATH="$TMP_ROOT/sleep-shim:$PATH" FM_SLEEP_PIDS="$TMP_ROOT/sleep.pids" \
    "$WRAP" --memory-kib 262144 -- bash -c 'sleep 600 & echo done')
  rc=$?
  expect_code 0 "$rc" "root status after a leftover background job is ended"
  assert_equals 'done' "$output" "the command's output is untouched"
  [ $((SECONDS - start)) -lt 30 ] || fail "memory stop waited for a leftover descendant"
  # A job ended before its first line records no PID and leaves no sleep.
  while read -r pid; do
    assert_memory_pid_ended "$pid"
  done <"$TMP_ROOT/sleep.pids"
  pass "the command's exit ends a background job orphaned before the first sample and returns at once"
}

test_memory_supervisor_kill_ends_tree() {
  local root_pid job_pid
  python3 - "$WRAP" "$TMP_ROOT/supervised.pids" <<'PY'
import os
import signal
import subprocess
import sys
import time

wrapper = subprocess.Popen([sys.argv[1], "--memory-kib", "262144", "--", "bash", "-c",
                            'sleep 600 & echo "$$ $!" >"$0"; wait', sys.argv[2]])
while wrapper.poll() is None and not (os.path.exists(sys.argv[2]) and open(sys.argv[2]).read().strip()):
    time.sleep(0.05)
os.kill(wrapper.pid, signal.SIGKILL)
wrapper.wait()
PY
  read -r root_pid job_pid <"$TMP_ROOT/supervised.pids" || fail "memory-stopped command did not start"
  assert_memory_pid_ended "$root_pid"
  assert_memory_pid_ended "$job_pid"
  pass "a SIGKILLed supervisor's command tree is ended by the reader's dead-man link"
}

test_memory_ignored_hangup_passes_through() {
  local rc
  python3 - "$WRAP" "$TMP_ROOT/hup.pid" <<'PY'
import os
import signal
import subprocess
import sys
import time

signal.signal(signal.SIGHUP, signal.SIG_IGN)
wrapper = subprocess.Popen([sys.argv[1], "--memory-kib", "262144", "--", "bash", "-c",
                            'echo "$$" >"$0"; sleep 2; exit 7', sys.argv[2]])
while wrapper.poll() is None and not (os.path.exists(sys.argv[2]) and open(sys.argv[2]).read().strip()):
    time.sleep(0.05)
os.kill(wrapper.pid, signal.SIGHUP)
os.kill(int(open(sys.argv[2]).read()), signal.SIGHUP)
sys.exit(wrapper.wait())
PY
  rc=$?
  expect_code 7 "$rc" "a caller-ignored HUP neither ends the supervisor nor the command"
  pass "an ignored HUP stays ignored by the supervisor and the command"
}

test_memory_out_of_group_member_ends_with_supervisor() {
  local pid
  python3 - "$WRAP" "$TMP_ROOT/setsid.pid" <<'PY'
import os
import signal
import subprocess
import sys
import time

child = ('import subprocess, sys, time\n'
         'p = subprocess.Popen(["sleep", "600"], start_new_session=True)\n'
         'open(sys.argv[1], "w").write("%d\\n" % p.pid)\n'
         'time.sleep(600)\n')
wrapper = subprocess.Popen([sys.argv[1], "--memory-kib", "262144", "--", sys.executable, "-c", child, sys.argv[2]])
while wrapper.poll() is None and not (os.path.exists(sys.argv[2]) and open(sys.argv[2]).read().strip()):
    time.sleep(0.05)
# Let at least one one-second sample see the new session's member.
time.sleep(2)
os.kill(wrapper.pid, signal.SIGKILL)
wrapper.wait()
PY
  read -r pid <"$TMP_ROOT/setsid.pid" || fail "memory-stopped command did not start its setsid child"
  assert_memory_pid_ended "$pid"
  pass "a seen member in another session is ended by the dead-man link"
}

test_memory_supervisor_death_before_reader_ready() {
  local fixture="$TMP_ROOT/startup-fixture" root_pid
  mkdir -p "$fixture"
  cp "$WRAP" "$ROOT/bin/fm-proc-budget-memory.py" "$fixture/"
  cp "$ROOT/bin/fm-proc-info.py" "$fixture/fm-proc-info-real.py"
  cat >"$fixture/fm-proc-info.py" <<'PY'
import os
from pathlib import Path
import runpy
import sys
real = str(Path(__file__).with_name("fm-proc-info-real.py"))
if __name__ != "__main__" or int(sys.argv[2]) == os.getppid():
    globals().update(runpy.run_path(real, run_name=__name__))
else:
    # The command's reader never answers its first sample.
    with open(os.environ["FM_MEMORY_MARKER"], "w") as handle:
        handle.write(sys.argv[2] + "\n")
    sys.stdin.read()
PY
  python3 - "$fixture/fm-proc-budget.sh" "$TMP_ROOT/startup.root" "$TMP_ROOT/startup-payload" <<'PY'
import os
import signal
import subprocess
import sys
import time

os.environ["FM_MEMORY_MARKER"] = sys.argv[2]
wrapper = subprocess.Popen([sys.argv[1], "--memory-kib", "262144", "--", "bash", "-c",
                            'touch "$0"; exec sleep 600', sys.argv[3]])
while wrapper.poll() is None and not (os.path.exists(sys.argv[2]) and open(sys.argv[2]).read().strip()):
    time.sleep(0.01)
os.kill(wrapper.pid, signal.SIGKILL)
wrapper.wait()
PY
  read -r root_pid <"$TMP_ROOT/startup.root" || fail "the command's reader never started"
  assert_memory_pid_ended "$root_pid"
  assert_absent "$TMP_ROOT/startup-payload" "a supervisor killed before its reader answered must not run the command"
  pass "a supervisor killed before its reader is ready leaves no command run or running"
}

test_memory_group_kill_idiom_keeps_status() {
  "$WRAP" --memory-kib 262144 -- bash -c "trap 'kill 0' EXIT; sleep 0.003"
  expect_code 0 $? "a command that signals its own group keeps its own status"
  pass "a command's kill 0 does not kill its memory reader"
}

test_memory_command_start_matches_exec() {
  local target plain memory
  printf 'echo ran-as-script\n' >"$TMP_ROOT/no-shebang"
  chmod +x "$TMP_ROOT/no-shebang"
  : >"$TMP_ROOT/not-executable"
  for target in "$TMP_ROOT/no-such-command" fm-proc-budget-no-such-command "$TMP_ROOT/not-executable" "$TMP_ROOT/no-shebang"; do
    plain=$("$WRAP" -- "$target" 2>/dev/null; echo "rc=$?")
    memory=$("$WRAP" --memory-kib 262144 -- "$target" 2>/dev/null; echo "rc=$?")
    assert_equals "$plain" "$memory" "memory stop starts $target as exec does"
  done
  assert_equals $'ran-as-script\nrc=0' "$memory" "a script without a shebang runs under the shell"
  pass "a command that cannot start, or a script without a shebang, behaves as without the option"
}

test_memory_reader_failure() {
  local fixture="$TMP_ROOT/memory-fixture" rc pid mode marker
  mkdir -p "$fixture"
  cp "$WRAP" "$ROOT/bin/fm-proc-budget-memory.py" "$fixture/"
  cp "$ROOT/bin/fm-proc-info.py" "$fixture/fm-proc-info-real.py"
  cat >"$fixture/fm-proc-info.py" <<'PY'
import os
from pathlib import Path
import runpy
import sys
import time
real = str(Path(__file__).with_name("fm-proc-info-real.py"))
if __name__ != "__main__":
    # Only the memory transport is faulted; cleanup still reads the real tree.
    globals().update(runpy.run_path(real))
else:
    for line in sys.stdin:
        if not os.path.exists(os.environ["FM_MEMORY_MARKER"]):
            print('{"rss_kib":1,"members":[],"uncounted":[]}', flush=True)
            continue
        mode = os.environ["FM_MEMORY_FAILURE"]
        if mode == "exit":
            sys.exit(0)
        if mode == "hang":
            time.sleep(60)
        print("-" if mode == "unreadable" else "malformed", flush=True)
PY
  for mode in unreadable malformed exit hang; do
    marker="$TMP_ROOT/reader-$mode.pid"
    PATH="$TMP_ROOT/stub-ps:$PATH" FM_TEST_PS_COUNT=100000 \
      FM_MEMORY_MARKER="$marker" FM_MEMORY_FAILURE="$mode" run_memory_case \
      "$fixture/fm-proc-budget.sh" --memory-kib 262144 -- \
      "$WRAP" --memory-kib 524288 -- \
      bash -c 'echo "$$" >"$FM_MEMORY_MARKER"; exec sleep 20' 2>"$TMP_ROOT/reader.err"
    rc=$?
    expect_code 125 "$rc" "failed memory sample ($mode)"
    assert_contains "$(cat "$TMP_ROOT/reader.err")" "cannot sample command-tree memory" "failed sample has a clear reason ($mode)"
    [ "$(wc -l <"$TMP_ROOT/reader.err" | tr -d ' ')" -eq 1 ] || fail "reader failure must emit exactly one reason ($mode)"
    read -r pid <"$marker"
    assert_memory_pid_ended "$pid"
  done

  PATH="$TMP_ROOT/stub-ps:$PATH" FM_TEST_PS_COUNT=100000 \
    FM_MEMORY_MARKER="$marker" FM_MEMORY_FAILURE=unreadable run_memory_case \
    "$fixture/fm-proc-budget.sh" --memory-kib 262144 -- touch "$TMP_ROOT/reader-started" 2>"$TMP_ROOT/reader-start.err"
  expect_code 125 $? "unavailable reader at preflight"
  assert_absent "$TMP_ROOT/reader-started" "unavailable reader must refuse before launch"
  pass "unreadable, malformed, exited, and stalled readers fail closed; failed preflight prevents launch"
}

test_no_memory_option_never_starts_reader() {
  local fixture="$TMP_ROOT/no-memory-fixture" output
  mkdir -p "$fixture"
  cp "$WRAP" "$ROOT/bin/fm-proc-info.py" "$fixture/"
  output=$("$fixture/fm-proc-budget.sh" -- bash -c 'printf unchanged; exit 0') || fail "no-option call unexpectedly requires a memory helper"
  assert_equals unchanged "$output" "without option the original exec path still works"
  pass "no memory option needs no reader or watcher"
}

test_memory_invalid_limits() {
  local limit
  for limit in 0 01 -1 nope 1.5 999999999999999999999999; do
    "$WRAP" --memory-kib "$limit" -- touch "$TMP_ROOT/bad-memory-ran" 2>/dev/null
    expect_code 2 $? "invalid memory limit $limit"
    assert_absent "$TMP_ROOT/bad-memory-ran" "invalid memory limit cannot run the command"
  done
  pass "invalid memory bounds refuse before launch"
}

test_memory_invalid_limits
test_no_memory_option_never_starts_reader
if memory_supported; then
  test_memory_tree_over_limit
  test_memory_nested_wrapper
  test_memory_normal_command
  test_memory_setuid_member_is_not_counted
  test_memory_root_exit_ends_leftovers
  test_memory_supervisor_kill_ends_tree
  test_memory_ignored_hangup_passes_through
  test_memory_out_of_group_member_ends_with_supervisor
  test_memory_supervisor_death_before_reader_ready
  test_memory_group_kill_idiom_keeps_status
  test_memory_command_start_matches_exec
  test_memory_reader_failure
fi

test_default_extra_is_added_to_the_count
test_explicit_extra
test_budget_never_widens_the_inherited_limit
test_retained_soft_limit_seals_the_hard_limit
test_exit_status_and_arguments_pass_through
test_refusals_never_run_the_command
test_budget_stops_a_runaway_tree_inside_the_tree
