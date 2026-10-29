#!/usr/bin/env bash
# Shared condition waits follow real publisher progress, not elapsed time.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-wait-until)

# The same publisher takes five times longer in the second run, without losing
# progress. Its final output is the condition; its journal proves intermediate
# work. A five-second total ceiling rejects the slow run despite that evidence.
for dilation in 1 5; do
  journal="$TMP_ROOT/progress-$dilation"
  result="$TMP_ROOT/result-$dilation"
  python3 -c '
import pathlib, sys, time
journal, result = map(pathlib.Path, sys.argv[1:3])
for step in range(20):
    time.sleep(0.1 * int(sys.argv[3]))
    journal.write_text(str(step))
result.write_text("published")
' "$journal" "$result" "$dilation" &
  publisher=$!
  fm_test_wait_until --while-alive "$publisher" --progress-file "$journal" --inactivity 5 -- test -s "$result" \
    || fail "${dilation}x healthy publisher was rejected while making progress"
  wait "$publisher" || fail "publisher failed"
  [ "$(cat "$result")" = published ] || fail "publisher result changed"
  pass "${dilation}x publisher reaches the awaited outcome"
done

# A detached publisher can expose only its journal. File-only observation must
# not mistake the waiting shell's CPU for its own progress.
journal="$TMP_ROOT/detached.journal"
result="$TMP_ROOT/detached.result"
python3 -c '
import pathlib, sys, time
journal, result = map(pathlib.Path, sys.argv[1:])
for step in range(20):
    time.sleep(0.2)
    journal.write_text(str(step))
result.write_text("detached")
' "$journal" "$result" &
publisher=$!
fm_test_wait_until --progress-file "$journal" --inactivity 2 -- test -s "$result" \
  || fail "file progress did not preserve the detached publication"
wait "$publisher" || fail "detached publisher failed"
[ "$(cat "$result")" = detached ] || fail "detached result changed"
pass "file-only observation follows a detached publisher beyond the inactivity interval"

# No files change during this CPU-only workload. CPU/runnable progress must
# preserve the wait until the child publishes its final result.
result="$TMP_ROOT/cpu.result"
python3 -c '
import pathlib, sys, time
start = time.process_time()
while time.process_time() - start < 2:
    sum(range(1000))
pathlib.Path(sys.argv[1]).write_text("computed")
' "$result" &
publisher=$!
fm_test_wait_until --while-alive "$publisher" --inactivity 0.3 -- test -s "$result" \
  || fail "productive CPU-only work was rejected"
wait "$publisher" || fail "CPU publisher failed"
[ "$(cat "$result")" = computed ] || fail "CPU result changed"
pass "CPU-only work is not a silent stall"

# Real harm: a live peer with neither CPU nor file progress is stuck. The
# helper returns failure, but cleanup remains the test owner's responsibility.
for dilation in 1 5; do
  sleep "$((30 * dilation))" &
  stalled=$!
  rc=0
  fm_test_wait_until --while-alive "$stalled" --inactivity 0.3 -- false \
    2> "$TMP_ROOT/stall-$dilation.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "${dilation}x stalled peer was not rejected (rc=$rc)"
  assert_grep 'no_progress:' "$TMP_ROOT/stall-$dilation.err" "stall had no progress evidence"
  kill -0 "$stalled" || fail "the wait killed its peer instead of leaving cleanup to its owner"
  kill "$stalled"
  wait "$stalled" 2>/dev/null || true
  pass "${dilation}x silent peer is detected without killing it"
done

rc=0
fm_test_wait_until --progress-file "$TMP_ROOT/never-published" --inactivity 0.3 -- false \
  2> "$TMP_ROOT/file-stall.err" || rc=$?
[ "$rc" -eq 1 ] || fail "a silent detached publisher was not rejected"
assert_grep 'no_progress:' "$TMP_ROOT/file-stall.err" "file stall lacked inactivity evidence"
pass "missing detached publication is a file-progress stall, not waiter CPU progress"

# Real harm: the producer ended before publishing. A completed outcome still
# wins when exit and publication happen between observations.
true &
dead=$!
wait "$dead"
rc=0
fm_test_wait_until --while-alive "$dead" -- false 2> "$TMP_ROOT/dead.err" || rc=$?
[ "$rc" -eq 1 ] || fail "a dead producer with no result was accepted"
assert_grep 'condition unmet (3,' "$TMP_ROOT/dead.err" "death was not distinguished from inactivity"
fm_test_wait_until --while-alive "$dead" -- test -s "$result" \
  || fail "a published result was rejected because its producer exited"
# shellcheck disable=SC2016 # The child shell expands its positional argument.
fm_test_wait_until --while-alive "$dead" -- bash -c '! kill -0 "$1" 2>/dev/null' _ "$dead" \
  || fail "a disappearance predicate did not succeed on peer exit"
pass "dead producers fail only when the requested outcome is absent"

# A peer dying during an unmet wait is also a failure, not a full inactivity
# wait. This condition kills only the fixture and deliberately stays false.
sleep 30 &
peer=$!
end_peer() { kill "$peer" 2>/dev/null || true; return 1; }
rc=0
fm_test_wait_until --while-alive "$peer" -- end_peer 2> "$TMP_ROOT/ended.err" || rc=$?
wait "$peer" 2>/dev/null || true
[ "$rc" -eq 1 ] || fail "peer death during the wait was ignored"
assert_grep 'condition unmet (3,' "$TMP_ROOT/ended.err" "ended peer became an inactivity verdict"
pass "peer death during a wait is detected"

# A failed CPU read is unknown, not inactivity. Hide both process-table sources
# while a real publisher stays alive, then prove its result is still accepted.
fakebin=$(fm_fakebin "$TMP_ROOT/blind")
printf '#!/bin/sh\nexit 1\n' > "$fakebin/ps"
chmod +x "$fakebin/ps"
result="$TMP_ROOT/blind.result"
python3 -c 'import pathlib, sys, time; time.sleep(1); pathlib.Path(sys.argv[1]).write_text("observed")' "$result" &
publisher=$!
PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/absent-proc" \
  fm_test_wait_until --while-alive "$publisher" --inactivity 0.1 -- test -s "$result" \
  2> "$TMP_ROOT/blind.err" || fail "missing CPU telemetry became a stall verdict"
wait "$publisher" || fail "blind publisher failed"
assert_grep 'cpu_telemetry_unavailable:' "$TMP_ROOT/blind.err" "CPU read failure was not exercised"
[ "$(cat "$result")" = observed ] || fail "blind observation lost the result"
pass "unavailable CPU telemetry is unknown and retried"

# An invalid or absent observable must not fall back to a capped compatibility
# path, which would silently restore the bug in unmigrated callers.
for shape in no-observable old-api waiter-pid; do
  rc=0
  case "$shape" in
    old-api) fm_test_wait_until 1 false 2>/dev/null || rc=$? ;;
    waiter-pid) fm_test_wait_until --while-alive "$$" -- false 2>/dev/null || rc=$? ;;
    no-observable) fm_test_wait_until -- false 2>/dev/null || rc=$? ;;
  esac
  [ "$rc" -eq 2 ] || fail "$shape was not refused"
done
pass "waits require a producer observable and reject the old capped interface"

# Exercise the observer's public CLI with a controlled kernel table and a real
# live PID. An unreadable interval breaks the inactivity evidence chain; a
# genuinely reused identity or two valid quiet observations still gets caught.
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root, tmp = map(Path, sys.argv[1:])
peer = subprocess.Popen(['sleep', '30'])
try:
    proc = tmp / 'proc'
    member = proc / str(peer.pid)
    member.mkdir(parents=True)
    fields = ['0'] * 50
    fields[0], fields[1], fields[19] = 'S', str(os.getpid()), '10'
    def kernel():
        (member / 'stat').write_text(f'{peer.pid} (publisher) ' + ' '.join(fields))
    kernel()
    env = dict(os.environ, FM_PROC_ROOT_OVERRIDE=str(proc))
    record = tmp / 'observation.json'
    command = [sys.executable, str(root / 'bin/fm-duration.py'), 'progress-check',
               str(record), str(peer.pid), '0.1', '--while-alive']
    def sample(expected, environment=env):
        result = subprocess.run(command, env=environment, capture_output=True, text=True)
        assert result.returncode == expected, (expected, result.returncode, result.stderr)
    sample(0)
    time.sleep(0.2)
    sample(0, dict(env, FM_PROC_ROOT_OVERRIDE=str(tmp / 'absent-proc'),
                   PATH=str(tmp / 'blind/fakebin') + os.pathsep + env['PATH']))
    sample(0)
    time.sleep(0.2)
    sample(124)
    fields[19] = '20'
    kernel()
    sample(3)
    record.write_text(json.dumps({'pid': peer.pid, 'identity': 'corrupt'}))
    sample(0)
    assert peer.poll() is None, 'observation must never signal its peer'
finally:
    peer.terminate()
    peer.wait()
print('ok - unknown intervals reset evidence, genuine inactivity and reused peers are caught, corrupt evidence is retried')
PY
