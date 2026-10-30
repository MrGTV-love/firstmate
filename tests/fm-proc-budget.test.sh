#!/usr/bin/env bash
# fm-proc-budget.test.sh - bin/fm-proc-budget.sh: the per-tree process budget.
#
# The kernel compares the RLIMIT_NPROC limit with the user's whole process
# count, so a runaway tree can starve every other process of the same user.
# These cases drive the wrapper as a separate process: the limit arithmetic
# against a stub `ps`, the refusals, and the incident reproduction - a shim
# whose `basename` is itself, run under a small budget - which must stop inside
# the budgeted tree while an unbudgeted probe keeps forking. --own-procs cases
# prove the tree's own count, not the user's, decides the stop: neighbours that
# spend the shared headroom starve the positional form and leave --own-procs alone.
# Child commands are single-quoted on purpose: they expand in the child bash.
# shellcheck disable=SC2016
set -u
set -o pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
[ -z "${SHIM_PIDS:-}" ] || printf '%s\n' "$$" >> "$SHIM_PIDS"
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

  # No wall-clock cap: SHIM_MAX_DEPTH bounds a regressed wrapper and the
  # runner's inactivity stop owns a hang.
  "$WRAP" 300 -- env PATH="$bomb:$PATH" SHIM_LOG="$log" SHIM_MAX_DEPTH=1500 \
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

test_memory_fixture_retains_inherited_process_limit() {
  local soft output rc
  soft=$(ulimit -S -u)
  output=$(run_memory_case "$WRAP" --memory-kib 262144 -- bash -c 'printf "%s %s\n" "$(ulimit -S -u)" "$(ulimit -H -u)"')
  rc=$?
  expect_code 0 "$rc" "memory-only fixture starts under the inherited process ceiling"
  assert_equals "$soft $soft" "$output" "both memory layers retain the inherited soft process limit and only seal the hard limit"
  pass "memory-only fixtures retain inherited process headroom without raising either limit"
}

test_memory_tree_over_limit() {
  local rc pid soft
  soft=$(ulimit -S -u)
  cat >"$TMP_ROOT/memory-tree.py" <<'PY'
import os
import resource
import subprocess
import sys
import time

if len(sys.argv) == 1:
    with open(os.environ["FM_MEMORY_NPROC"], "w") as handle:
        handle.write("%d %d\n" % resource.getrlimit(resource.RLIMIT_NPROC))
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
  FM_MEMORY_PIDS="$TMP_ROOT/memory.pids" FM_MEMORY_NPROC="$TMP_ROOT/memory.nproc" run_memory_case \
    "$WRAP" --memory-kib 131072 -- python3 "$TMP_ROOT/memory-tree.py" 2>"$TMP_ROOT/memory.err"
  rc=$?
  expect_code 99 "$rc" "over-limit command tree: $(<"$TMP_ROOT/memory.err")"
  assert_equals "$soft $soft" "$(cat "$TMP_ROOT/memory.nproc")" "the memory payload keeps the inherited soft process limit, with no extra user-count cap"
  assert_contains "$(cat "$TMP_ROOT/memory.err")" "exceeded 131072 KiB" "over-limit reason names the bound"
  [ "$(wc -l <"$TMP_ROOT/memory.err" | tr -d ' ')" -eq 1 ] || fail "memory stop must emit exactly one reason"
  [ "$(wc -l <"$TMP_ROOT/memory.pids" | tr -d ' ')" -eq 2 ] || fail "child and grandchild must both have started"
  while read -r pid; do
    assert_memory_pid_ended "$pid"
  done <"$TMP_ROOT/memory.pids"
  pass "over-limit child and grandchild are ended with status 99"
}

test_memory_nested_wrapper() {
  local rc pid soft
  soft=$(ulimit -S -u)
  # The inner wrapper runs its own supervisor with a higher bound. The outer
  # stop must still count and end the inner 192 MiB payload.
  FM_MEMORY_NESTED_PID="$TMP_ROOT/nested-memory.pid" FM_MEMORY_NPROC="$TMP_ROOT/nested-memory.nproc" \
    run_memory_case "$WRAP" --memory-kib 131072 -- \
    "$WRAP" --memory-kib 524288 -- python3 -c \
    'import os, resource, time; open(os.environ["FM_MEMORY_NESTED_PID"], "w").write(str(os.getpid())); open(os.environ["FM_MEMORY_NPROC"], "w").write("%d %d" % resource.getrlimit(resource.RLIMIT_NPROC)); allocation = bytearray(192 * 1024 * 1024); time.sleep(4); raise SystemExit(7)' \
    2>"$TMP_ROOT/nested-memory.err"
  rc=$?
  expect_code 99 "$rc" "lower outer memory stop covers nested wrapper sessions: $(<"$TMP_ROOT/nested-memory.err")"
  assert_equals "$soft $soft" "$(cat "$TMP_ROOT/nested-memory.nproc")" "all three memory layers keep the inherited process ceiling"
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
  local output rc pid natural="$TMP_ROOT/memory-leftover.finished"
  mkdir -p "$TMP_ROOT/sleep-shim"
  printf '#!/bin/sh\necho "$$" >>"$FM_SLEEP_PIDS"\nexec /bin/sleep "$@"\n' >"$TMP_ROOT/sleep-shim/sleep"
  chmod +x "$TMP_ROOT/sleep-shim/sleep"
  : >"$TMP_ROOT/sleep.pids"
  rm -f "$natural"
  # The leftover holds no stdout and marks its own natural finish after 600 s.
  # Once its processes are gone, an absent mark proves the wrapper ended it.
  output=$(PATH="$TMP_ROOT/sleep-shim:$PATH" FM_SLEEP_PIDS="$TMP_ROOT/sleep.pids" \
    "$WRAP" --memory-kib 262144 -- bash -c '
      sh -c '\''sleep 600; : >"$1"'\'' _ "$1" >/dev/null 2>&1 &
      echo "$!" >>"$FM_SLEEP_PIDS"; echo done' _ "$natural")
  rc=$?
  expect_code 0 "$rc" "root status after a leftover background job is ended"
  assert_equals 'done' "$output" "the command's output is untouched"
  # A job ended before its first line records no PID and leaves no sleep.
  while read -r pid; do
    assert_memory_pid_ended "$pid"
  done <"$TMP_ROOT/sleep.pids"
  assert_absent "$natural" "the leftover ran to its natural finish instead of being ended"
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

test_memory_supervisor_kill_during_cleanup() {
  local root_pid job_pid
  python3 - "$WRAP" "$TMP_ROOT/cleanup.pids" <<'PY'
import os
import signal
import subprocess
import sys
import time

wrapper = subprocess.Popen([sys.argv[1], "--memory-kib", "262144", "--", "bash", "-c",
                            '(trap "" TERM; exec sleep 600) & echo "$$ $!" >"$0"; sleep 1.5', sys.argv[2]])
while wrapper.poll() is None and not (os.path.exists(sys.argv[2]) and open(sys.argv[2]).read().strip()):
    time.sleep(0.01)
root = int(open(sys.argv[2]).read().split()[0])
# The root is reaped when cleanup starts; the leftover ignores TERM, so the
# supervisor is still inside its one-second TERM grace when it is killed.
while wrapper.poll() is None:
    try:
        os.kill(root, 0)
    except ProcessLookupError:
        break
    time.sleep(0.01)
time.sleep(0.2)
os.kill(wrapper.pid, signal.SIGKILL)
wrapper.wait()
PY
  read -r root_pid job_pid <"$TMP_ROOT/cleanup.pids" || fail "memory-stopped command did not start"
  assert_memory_pid_ended "$job_pid"
  pass "a supervisor killed during its own cleanup leaves no TERM-ignoring member behind"
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

test_memory_supervisor_cleanup_refusal() {
  local fixture="$TMP_ROOT/cleanup-refusal"
  mkdir -p "$fixture"
  cp "$WRAP" "$ROOT/bin/fm-proc-budget-memory.py" "$fixture/"
  cp "$ROOT/bin/fm-proc-info.py" "$fixture/fm-proc-info-real.py"
  cat >"$fixture/fm-proc-info.py" <<'PY'
import errno
import os
from pathlib import Path
import runpy

real = str(Path(__file__).with_name("fm-proc-info-real.py"))
if __name__ == "__main__":
    # The independent guardian keeps using the real kernel reader.
    runpy.run_path(real, run_name="__main__")
else:
    globals().update(runpy.run_path(real))
    real_kinfo = kinfo

    def kinfo(pid):
        if Path(os.environ["FM_CLEANUP_FAULT"]).exists():
            raise OSError(errno.EPERM, "injected supervisor kinfo refusal")
        return real_kinfo(pid)
PY
  run_memory_case python3 - "$fixture" <<'PY'
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys

fixture = Path(sys.argv[1])
info = runpy.run_path(str(fixture / "fm-proc-info-real.py"))
marker = fixture / "fault"
os.environ["FM_CLEANUP_FAULT"] = str(marker)
payload = '''import os, pathlib, subprocess, sys
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
pathlib.Path(sys.argv[1]).write_text(f"{os.getpid()} {child.pid}")
if sys.argv[2] == "fault": pathlib.Path(sys.argv[3]).touch()
'''
for mode in ("control", "fault"):
    marker.unlink(missing_ok=True)
    pids = fixture / (mode + ".pids")
    result = subprocess.run([str(fixture / "fm-proc-budget.sh"), "--memory-kib", "524288", "--",
                             sys.executable, "-c", payload, str(pids), mode, str(marker)],
                            capture_output=True, text=True)
    root, child = map(int, pids.read_text().split())
    try:
        record = info["kinfo"](child)
        alive = record[info["P_STAT"]] != info["SZOMB"]
    except LookupError:
        alive = False
    if alive:
        # Always clean up the finite fixture, even when the regression fails.
        assert os.getpgid(child) == root, "fixture ownership changed"
        os.kill(child, signal.SIGKILL)
    print(f"{mode}: status={result.returncode} child_alive={alive} reason={result.stderr.strip()}", flush=True)
    assert not alive, f"{mode}: cleanup left a descendant alive"
    if mode == "control":
        assert result.returncode == 0 and not result.stderr, result
    else:
        assert result.returncode == 125, result
        assert "tree cleanup failed" in result.stderr, result
        assert len(result.stderr.splitlines()) == 1, result
PY
  expect_code 0 $? "supervisor cleanup refusal must leave no descendant and report failure"
  pass "supervisor-only kinfo refusal leaves the guardian armed until the tree ends and returns 125"
}

test_memory_group_kill_idiom_keeps_status() {
  "$WRAP" --memory-kib 262144 -- bash -c "trap 'kill 0' EXIT; sleep 0.003"
  expect_code 0 $? "a command that signals its own group keeps its own status"
  pass "a command's kill 0 does not kill its memory reader"
}

test_memory_inherited_fd_reaches_command() {
  "$WRAP" --memory-kib 262144 -- bash -c 'echo inherited >&3' 3>"$TMP_ROOT/fd3.log"
  expect_code 0 $? "a command writing to a descriptor its caller passed"
  assert_equals inherited "$(cat "$TMP_ROOT/fd3.log")" "descriptor 3 reaches the command as with exec"
  pass "descriptors the caller passes reach the memory-stopped command"
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

# Memory-specific cases share one scoped count fixture, not a user-count + 1500
# cap that unrelated same-user processes can spend before a payload starts.
# Reporting the actual inherited soft limit keeps that ceiling at every wrapper
# layer; the normal hard-limit seal can lower the hard limit but never raise it.
# Dynamic local scope also reaches Python-launched wrappers and copied readers.
# Process-budget arithmetic, real-UID refusal, sealing and runaway cases remain
# outside this owner, with their original counts and production guard coverage.
run_memory_cases() {
  local FM_TEST_PS_COUNT PATH="$TMP_ROOT/stub-ps:$PATH"
  FM_TEST_PS_COUNT=$(ulimit -S -u)
  case "$FM_TEST_PS_COUNT" in
    ''|*[!0-9]*) fail "the memory fixtures need a finite inherited process limit, got '$FM_TEST_PS_COUNT'" ;;
  esac
  export FM_TEST_PS_COUNT PATH
  test_memory_fixture_retains_inherited_process_limit
  test_memory_tree_over_limit
  test_memory_nested_wrapper
  test_memory_normal_command
  test_memory_setuid_member_is_not_counted
  test_memory_root_exit_ends_leftovers
  test_memory_supervisor_kill_ends_tree
  test_memory_ignored_hangup_passes_through
  test_memory_out_of_group_member_ends_with_supervisor
  test_memory_supervisor_kill_during_cleanup
  test_memory_supervisor_death_before_reader_ready
  test_memory_supervisor_cleanup_refusal
  test_memory_group_kill_idiom_keeps_status
  test_memory_inherited_fd_reaches_command
  test_memory_command_start_matches_exec
  test_memory_reader_failure
}

test_memory_invalid_limits
test_no_memory_option_never_starts_reader
if memory_supported; then
  run_memory_cases
fi

test_default_extra_is_added_to_the_count
test_explicit_extra
test_budget_never_widens_the_inherited_limit
test_retained_soft_limit_seals_the_hard_limit
test_exit_status_and_arguments_pass_through
test_refusals_never_run_the_command
test_budget_stops_a_runaway_tree_inside_the_tree

# --- --own-procs: the tree's own count, never the user's ---------------------
#
# These waits have no wall-clock cap. They wait for an outcome the test itself
# causes (a marker file, a process gone), and a hang is the runner's inactivity
# stop to catch, not a guessed number of seconds here.
wait_for_file() {  # <file> [<pid whose death ends the wait>]
  while [ ! -e "$1" ]; do
    [ -z "${2:-}" ] || kill -0 "$2" 2>/dev/null || return 1
    sleep 0.05
  done
}

pid_alive() {  # a zombie is not alive: it holds no work, only a table row
  local state
  kill -0 "$1" 2>/dev/null || return 1
  if [ -r "/proc/$1/stat" ]; then
    state=$(sed -e 's/.*) //' -e 's/ .*//' "/proc/$1/stat" 2>/dev/null)
  else
    # A confined worker's sandbox refuses ps, so the Darwin table comes from
    # bin/fm-proc-info.py; elsewhere ps answers.
    state=$(python3 "$ROOT/bin/fm-proc-info.py" table pid,stat 2>/dev/null | while read -r candidate status; do
      [ "$candidate" != "$1" ] || printf '%s' "$status"
    done)
    [ -n "$state" ] || state=$(ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]')
  fi
  case "$state" in
    Z*) return 1 ;;
  esac
  return 0
}

wait_pids_ended() {  # <file of pids>
  local pid
  while read -r pid; do
    while pid_alive "$pid"; do sleep 0.05; done
  done <"$1"
}

test_own_procs_invalid_calls() {
  local args marker="$TMP_ROOT/own-bad-ran"
  for args in 0 01 -1 nope 1.5 1234567890; do
    "$WRAP" --own-procs "$args" -- touch "$marker" 2>/dev/null
    expect_code 2 $? "invalid own-procs limit $args"
    assert_absent "$marker" "invalid own-procs limit $args cannot run the command"
  done
  "$WRAP" --own-procs -- touch "$marker" 2>/dev/null
  expect_code 2 $? "own-procs without a value"
  "$WRAP" --own-procs 5 --own-procs 6 -- touch "$marker" 2>/dev/null
  expect_code 2 $? "own-procs given twice"
  "$WRAP" --own-procs 50 --memory-kib 262144 -- touch "$marker" 2>/dev/null
  expect_code 2 $? "own-procs combined with memory-kib"
  "$WRAP" --memory-kib 262144 --own-procs 50 -- touch "$marker" 2>/dev/null
  expect_code 2 $? "memory-kib combined with own-procs"
  assert_absent "$marker" "a refused own-procs call must not run the command"
  pass "invalid or combined own-procs calls refuse before launch"
}

test_own_procs_passes_status_and_arguments_through() {
  local rc out
  "$WRAP" --own-procs 50 -- bash -c 'exit 7'
  rc=$?
  expect_code 7 "$rc" "the child's exit status is the wrapper's"
  out=$("$WRAP" --own-procs 50 -- printf '%s|' 'a b' c) || fail "arguments were not passed through"
  assert_equals 'a b|c|' "$out" "arguments reach the child intact"
  pass "own-procs passes the exit status and arguments through"
}

# The leash: a recursive tree is stopped by its own count, before the kernel
# limit (left at its default here) is anywhere near.
test_own_procs_stops_a_runaway_tree() {
  local bomb="$TMP_ROOT/own-bomb" log="$TMP_ROOT/own-bomb.log" pids="$TMP_ROOT/own-bomb.pids"
  local err="$TMP_ROOT/own-bomb.err" depth rc
  make_bomb "$bomb"
  : >"$log"
  : >"$pids"
  "$WRAP" --own-procs 100 -- env PATH="$bomb:$PATH" SHIM_LOG="$log" SHIM_PIDS="$pids" SHIM_MAX_DEPTH=1500 \
    date +%s >"$TMP_ROOT/own-bomb.out" 2>"$err"
  rc=$?
  expect_code 98 "$rc" "a tree past its own limit"
  depth=$(tail -1 "$log")
  [ -n "$depth" ] || fail "the bomb never started: $(cat "$err")"
  [ "$depth" -gt 20 ] || fail "the bomb did not recurse (depth $depth): the case would be vacuous"
  [ "$depth" -lt 1500 ] || fail "the own-tree stop did not stop the runaway tree (depth $depth)"
  assert_contains "$(grep 'fm-proc-budget:' "$err")" "over the own-tree limit of 100" "the reason names the limit"
  assert_not_contains "$(cat "$err")" "Resource temporarily unavailable" "the tree was stopped by its own count, not the kernel"
  [ "$(grep -c 'fm-proc-budget:' "$err")" -eq 1 ] || fail "an own-tree stop must emit exactly one reason"
  wait_pids_ended "$pids"
  pass "a runaway tree is stopped at its own limit (depth $depth) and leaves no process behind"
}

test_own_procs_nested_wrapper() {
  local rc pid pids="$TMP_ROOT/own-nested.pids"
  : >"$pids"
  "$WRAP" --own-procs 40 -- "$WRAP" --own-procs 100000 -- \
    bash -c 'for _ in $(seq 1 80); do sleep 5001 & echo "$!" >>"$0"; done; wait' "$pids" \
    2>"$TMP_ROOT/own-nested.err"
  rc=$?
  expect_code 98 "$rc" "the outer limit covers a nested wrapper's tree"
  assert_contains "$(cat "$TMP_ROOT/own-nested.err")" "over the own-tree limit of 40" "the outer bound stops the payload"
  [ -s "$pids" ] || fail "the nested payload never started"
  while read -r pid; do
    ! pid_alive "$pid" || fail "the nested payload outlived the outer stop"
  done <"$pids"
  pass "a lower outer own-tree limit counts and ends a nested wrapper's tree"
}

# The kernel limit is the safety net and keeps its meaning.
test_own_procs_keeps_the_kernel_limit() {
  local bomb="$TMP_ROOT/net-bomb" log="$TMP_ROOT/net-bomb.log" err="$TMP_ROOT/net-bomb.err" depth
  make_bomb "$bomb"
  : >"$log"
  "$WRAP" 300 --own-procs 1000000 -- env PATH="$bomb:$PATH" SHIM_LOG="$log" SHIM_MAX_DEPTH=1500 \
    date +%s >"$TMP_ROOT/net-bomb.out" 2>"$err"
  depth=$(tail -1 "$log")
  [ -n "$depth" ] && [ "$depth" -gt 20 ] || fail "the bomb did not recurse (depth ${depth:-none})"
  [ "$depth" -lt 1500 ] || fail "the kernel limit did not stop the runaway tree (depth $depth)"
  assert_contains "$(cat "$err")" "Resource temporarily unavailable" "an out-of-reach own limit leaves the kernel limit to stop the tree"
  pass "the kernel limit still stops a tree the own-tree limit cannot reach"
}

test_own_procs_leftovers_end_with_the_command() {
  local out rc natural="$TMP_ROOT/own-leftover.finished"
  mkdir -p "$TMP_ROOT/own-sleep-shim"
  printf '#!/bin/sh\necho "$$" >>"$FM_SLEEP_PIDS"\nexec /bin/sleep "$@"\n' >"$TMP_ROOT/own-sleep-shim/sleep"
  chmod +x "$TMP_ROOT/own-sleep-shim/sleep"
  : >"$TMP_ROOT/own-sleep.pids"
  rm -f "$natural"
  # The leftover holds no stdout and marks its own natural finish after 600 s.
  # Once its processes are gone, an absent mark proves the wrapper ended it.
  out=$(PATH="$TMP_ROOT/own-sleep-shim:$PATH" FM_SLEEP_PIDS="$TMP_ROOT/own-sleep.pids" \
    "$WRAP" --own-procs 50 -- bash -c '
      sh -c '\''sleep 600; : >"$1"'\'' _ "$1" >/dev/null 2>&1 &
      echo "$!" >>"$FM_SLEEP_PIDS"; echo done' _ "$natural")
  rc=$?
  expect_code 0 "$rc" "root status after a leftover background job is ended"
  assert_equals 'done' "$out" "the command's output is untouched"
  wait_pids_ended "$TMP_ROOT/own-sleep.pids"
  assert_absent "$natural" "the leftover ran to its natural finish instead of being ended"
  pass "a background job left behind by a finished command is ended and the wrapper returns"
}

test_own_procs_term_ends_the_tree() {
  local pids="$TMP_ROOT/own-term.pids" wrapper rc
  rm -f "$pids"
  "$WRAP" --own-procs 50 -- bash -c 'sleep 5002 & echo "$$ $!" >"$0.tmp"; mv "$0.tmp" "$0"; wait' "$pids" &
  wrapper=$!
  wait_for_file "$pids" "$wrapper" || fail "the own-procs command never started"
  kill -TERM "$wrapper"
  wait "$wrapper"
  rc=$?
  expect_code 143 "$rc" "a TERM sent to the wrapper"
  tr ' ' '\n' <"$pids" >"$pids.list"
  wait_pids_ended "$pids.list"
  pass "TERM to the wrapper ends the whole tree and returns 128 plus the signal"
}

# A TERM that lands right after the release, before the first sample, still
# ends the started command through the tree cleanup.
test_own_procs_term_at_release_ends_the_command() {
  local rc finished="$TMP_ROOT/own-release-term.finished"
  rm -f "$finished"
  python3 - "$ROOT/bin/fm-proc-budget-tree.py" "$finished" <<'PY'
import os
import runpy
import signal
import sys

tree = runpy.run_path(sys.argv[1], run_name="tree")
real = os.write

def write(fd, data):
    written = real(fd, data)
    if data == b"\n":
        os.kill(os.getpid(), signal.SIGTERM)
    return written

os.write = write
sys.exit(tree["run"](50, ["bash", "-c", 'sleep 30; : >"$1"', "_", sys.argv[2]]))
PY
  rc=$?
  expect_code 143 "$rc" "a TERM caught as the command is released"
  assert_absent "$finished" "the released command ran to its end instead of being ended"
  pass "a TERM caught at the release ends the started command and returns 128 plus the signal"
}

# The dead-man link. The supervisor is killed mid-run: alone, and as a runner
# such as bin/fm-duration.py ends the caller's group (TERM, then KILL at once).
# The members ignore TERM, so only a KILL from the group's reader ends them.
test_own_procs_supervisor_death_ends_the_tree() {
  local pids="$TMP_ROOT/own-deadman.pids" target supervisor
  for target in supervisor group; do
    rm -f "$pids"
    perl -e 'setpgrp(0, 0); exec @ARGV or die' "$WRAP" --own-procs 50 -- bash -c '
      trap "" TERM; sleep 5003 & first=$!; sleep 5003 &
      echo "$$ $first $!" >"$0.tmp"; mv "$0.tmp" "$0"; wait' "$pids" &
    supervisor=$!
    wait_for_file "$pids" "$supervisor" || fail "the own-procs command never started"
    if [ "$target" = supervisor ]; then
      kill -KILL "$supervisor"
    else
      kill -TERM -- "-$supervisor"
      kill -KILL -- "-$supervisor"
    fi
    wait "$supervisor" 2>/dev/null
    tr ' ' '\n' <"$pids" >"$pids.list"
    wait_pids_ended "$pids.list"
  done
  pass "a supervisor killed mid-run, alone or with its caller's group, leaves no tree member running"
}

# An unreadable sample is "unknown, try again next sample". Only an unreadable
# table before launch refuses; one the command already runs under never ends it.
own_procs_driver() {  # <mode> <state-file>
  python3 - "$ROOT/bin/fm-proc-budget-tree.py" "$1" "$2" <<'PY'
import runpy
import sys

tree = runpy.run_path(sys.argv[1], run_name="tree")
mode, state = sys.argv[2], sys.argv[3]
real = tree["Table"].read
calls = [0]

def flaky(self):
    calls[0] += 1
    if mode == "launch":
        raise tree["SampleError"]("injected: table unreadable")
    # Call 1 is the launch check. The next three samples are unreadable; the
    # command only exits after the third, so each one happened while it ran.
    if 1 < calls[0] <= 4:
        if calls[0] == 4:
            open(state, "w").close()
        raise tree["SampleError"]("injected: sample unreadable")
    return real(self)

tree["Table"].read = flaky
script = 'if [ "$1" = launch ]; then touch "$2.ran"; exit 0; fi; while [ ! -e "$2" ]; do sleep 0.01; done; exit 7'
sys.exit(tree["run"](50, ["bash", "-c", script, "_", mode, state]))
PY
}

test_own_procs_unreadable_samples_are_unknown() {
  local rc err="$TMP_ROOT/own-unreadable.err"
  rm -f "$TMP_ROOT/own-state" "$TMP_ROOT/own-state.ran"
  own_procs_driver sample "$TMP_ROOT/own-state" 2>"$err"
  rc=$?
  expect_code 7 "$rc" "samples that cannot be read while the command runs"
  assert_contains "$(cat "$err")" "3 own-tree sample(s) were unreadable and skipped" "the skipped samples are reported once"
  own_procs_driver launch "$TMP_ROOT/own-state" 2>"$err"
  rc=$?
  expect_code 125 "$rc" "a table that cannot be read before launch"
  assert_absent "$TMP_ROOT/own-state.ran" "an unwatchable tree must not run"
  assert_contains "$(cat "$err")" "command not started" "the refusal says the command did not start"
  pass "an unreadable sample is skipped and reported; only an unreadable launch table refuses"
}

# The slow-host case. A neighbour lane spends the user's shared process count
# while this tree runs, and every delay in the tree's work is five times longer.
# The positional extra is headroom over the WHOLE user's count, so the tree
# loses its forks; --own-procs counts only the tree and the same work succeeds.
start_neighbours() {  # <count>
  local dir="$TMP_ROOT/neighbours"
  rm -rf "$dir"
  mkdir -p "$dir"
  cat >"$dir/spawn.py" <<'PY'
import os
import subprocess
import sys

count, ready, pids = int(sys.argv[1]), sys.argv[2], sys.argv[3]
kids = []
try:
    for _ in range(count):
        kids.append(subprocess.Popen(["/bin/sleep", "86400"]))
    with open(pids + ".tmp", "w") as handle:
        handle.write(" ".join(str(kid.pid) for kid in kids))
    os.rename(pids + ".tmp", pids)
    open(ready, "w").close()
    sys.stdin.read()  # the test closes the pipe, or dies, to release the neighbours
finally:
    for kid in kids:
        kid.kill()
    for kid in kids:
        kid.wait()
PY
  mkfifo "$dir/hold"
  python3 "$dir/spawn.py" "$1" "$dir/ready" "$dir/pids" <"$dir/hold" &
  NEIGHBOUR_PID=$!
  exec 8>"$dir/hold"
  wait_for_file "$dir/ready" "$NEIGHBOUR_PID" || { stop_neighbours; return 1; }
}

stop_neighbours() {
  exec 8>&-
  wait "$NEIGHBOUR_PID"
}

make_slow_tree() {
  local dir="$TMP_ROOT/slow-tree"
  # The interpreter itself, not a version-manager shim that forks before the
  # tree starts, so a starved control fails at the tree's own fork.
  SLOW_TREE_PYTHON=$(python3 -c 'import sys; print(sys.executable)')
  mkdir -p "$dir/shim"
  # Every sleep the tree asks for lasts five times as long.
  cat >"$dir/shim/sleep" <<'SH'
#!/bin/sh
exec /bin/sleep "$(awk -v n="$1" 'BEGIN { print n * 5 }')"
SH
  chmod +x "$dir/shim/sleep"
  cat >"$dir/tree.py" <<'PY'
import os
import subprocess
import sys
import time

ready, go, done = sys.argv[1:4]
open(ready, "w").close()
while not os.path.exists(go):
    time.sleep(0.05)
for _ in range(5):
    subprocess.run(["/usr/bin/true"], check=True)  # a starved fork raises here
    subprocess.run(["sleep", "0.1"], check=True)   # the shim makes it 0.5 s
open(done, "w").close()
PY
}

# run_slow_tree <neighbours> <wrapper args...>: prints the wrapper's exit status.
run_slow_tree() {
  local dir="$TMP_ROOT/slow-tree" neighbours=$1 wrapper rc
  shift
  rm -f "$dir/ready" "$dir/go" "$dir/done"
  PATH="$dir/shim:$PATH" "$WRAP" "$@" -- "$SLOW_TREE_PYTHON" "$dir/tree.py" "$dir/ready" "$dir/go" "$dir/done" \
    2>"$dir/err" &
  wrapper=$!
  wait_for_file "$dir/ready" "$wrapper" || { wait "$wrapper"; echo $?; return; }
  start_neighbours "$neighbours" || {
    kill "$wrapper"
    wait "$wrapper"
    fail "the neighbours never started (fork limit reached?)"
  }
  : >"$dir/go"
  wait "$wrapper"
  rc=$?
  stop_neighbours
  echo "$rc"
}

test_own_procs_survives_neighbours_on_a_slow_host() {
  local dir="$TMP_ROOT/slow-tree" rc
  make_slow_tree
  # Control: the positional extra of 16 is spent by 300 neighbour processes, so
  # the rest of the user would have to free 284 processes to leave it unstarved.
  rc=$(run_slow_tree 300 16) || exit 1
  [ "$rc" != 0 ] || fail "the control was not starved: the scenario would be vacuous"
  assert_absent "$dir/done" "the starved control must not have finished"
  assert_contains "$(cat "$dir/err")" "BlockingIOError" "the control lost its forks to the neighbours"
  rc=$(run_slow_tree 300 --own-procs 128) || exit 1
  expect_code 0 "$rc" "a tree under its own limit while neighbours spend the shared count"
  assert_present "$dir/done" "the slowed tree finished its work"
  pass "neighbours starve the positional extra of 16 but not --own-procs 128, with the tree's work five times slower"
}

test_own_procs_reads_a_linux_stat_row() {
  python3 - "$ROOT/bin/fm-proc-budget-tree.py" <<'PY' || fail "the Linux /proc row was misread"
import runpy
import sys

parse = runpy.run_path(sys.argv[1], run_name="tree")["Table"].parse_stat
# pid (comm) state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt
# utime stime cutime cstime priority nice threads itrealvalue starttime ...
tail = b"%s 4321 4300 4300 0 -1 4194560 11 0 0 0 1 2 0 0 20 0 1 0 987654 1000 100"
assert parse(b"4400 (bash) " + tail % b"S") == (4321, 4300, 987654, False)
assert parse(b"4400 (a b) (c)) " + tail % b"R") == (4321, 4300, 987654, False), "parentheses in the name"
assert parse(b"4400 (sleep) " + tail % b"Z") == (4321, 4300, 987654, True), "a zombie"
assert parse(b"4400 (sleep) " + tail % b"X") == (4321, 4300, 987654, True), "a dead row"
assert parse(b"4400 (half) S 1") is None, "a half-read row is skipped, not guessed"
assert parse(b"") is None
PY
  pass "a Linux /proc row yields parent, group, start identity and zombie state"
}

test_own_procs_command_start_matches_exec() {
  local target plain own
  printf 'echo ran-as-script\n' >"$TMP_ROOT/own-no-shebang"
  chmod +x "$TMP_ROOT/own-no-shebang"
  : >"$TMP_ROOT/own-not-executable"
  for target in "$TMP_ROOT/no-such-command" fm-proc-budget-no-such-command "$TMP_ROOT/own-not-executable" "$TMP_ROOT/own-no-shebang"; do
    plain=$("$WRAP" -- "$target" 2>/dev/null; echo "rc=$?")
    own=$("$WRAP" --own-procs 50 -- "$target" 2>/dev/null; echo "rc=$?")
    assert_equals "$plain" "$own" "own-procs starts $target as exec does"
  done
  assert_equals $'ran-as-script\nrc=0' "$own" "a script without a shebang runs under the shell"
  pass "a command that cannot start, or a script without a shebang, behaves as without the option"
}

test_own_procs_invalid_calls
test_own_procs_reads_a_linux_stat_row
test_own_procs_command_start_matches_exec
test_own_procs_passes_status_and_arguments_through
test_own_procs_unreadable_samples_are_unknown
test_own_procs_leftovers_end_with_the_command
test_own_procs_term_ends_the_tree
test_own_procs_term_at_release_ends_the_command
test_own_procs_supervisor_death_ends_the_tree
test_own_procs_stops_a_runaway_tree
test_own_procs_nested_wrapper
test_own_procs_keeps_the_kernel_limit
test_own_procs_survives_neighbours_on_a_slow_host
