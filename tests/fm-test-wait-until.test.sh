#!/usr/bin/env bash
# Shared condition waits follow real publisher progress, not elapsed time.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-wait-until)

# Each helper observation starts a new interpreter. Their saved timestamps must
# include quiet time between processes, including on macOS system Python 3.9.
for interpreter in "$(command -v python3)" /usr/bin/python3; do
[ -x "$interpreter" ] || continue
"$interpreter" - "$ROOT" "$TMP_ROOT" <<'PY'
from pathlib import Path
import subprocess
import sys
import time

root, tmp = map(Path, sys.argv[1:])
record = tmp / 'cross-process-clock.json'
record.unlink(missing_ok=True)
command = [sys.executable, str(root / 'bin/fm-duration.py'), 'progress-check',
           str(record), '0', '0.1', str(tmp / 'absent-publication')]
for expected in (0, 124):
    result = subprocess.run(command, capture_output=True, text=True)
    print('cross-process silence: python={} rc={} record={}'.format(
        sys.version.split()[0], result.returncode, record.read_text()), flush=True)
    assert result.returncode == expected, (expected, result.returncode, result.stderr)
    time.sleep(0.3)
print('ok - separate observer processes detect an unchanged absent publication')
PY
done

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

# Activity alone is not progress toward an outcome. A live peer that burns CPU
# but changes no outcome-specific observable is silent, not productive.
python3 -c '
import time
while True:
    sum(range(1000))
' &
busy=$!
rc=0
fm_test_wait_until --while-alive "$busy" --inactivity 0.3 -- false 2> "$TMP_ROOT/busy.err" || rc=$?
kill "$busy"
wait "$busy" 2>/dev/null || true
[ "$rc" -eq 1 ] || fail "CPU activity without an observable outcome kept the wait alive (rc=$rc)"
assert_grep 'no_progress:' "$TMP_ROOT/busy.err" "CPU-only activity was not judged silent"
pass "CPU-only activity is not progress toward the outcome"

# A live poller completes cycles on its own counter. Slowed five times, a poller
# that publishes on its third cycle still passes; one that keeps polling without
# the outcome fails after the caller's N cycles, not after a quiet interval.
poller() {  # <count-file> <result-file> <dilation> <publish-cycle>
  python3 -c '
import os, pathlib, sys, time
count, result = map(pathlib.Path, sys.argv[1:3])
dilation, publish = int(sys.argv[3]), int(sys.argv[4])
cycle = 0
while True:
    time.sleep(0.1 * dilation)
    cycle += 1
    if cycle == publish:
        result.write_text("published")
    count.with_suffix(".tmp").write_text(str(cycle))
    os.replace(count.with_suffix(".tmp"), count)
' "$@" &
}
for dilation in 1 5; do
  count="$TMP_ROOT/poll-$dilation.count"
  result="$TMP_ROOT/poll-$dilation.result"
  poller "$count" "$result" "$dilation" 3
  peer=$!
  rc=0
  fm_test_wait_until --while-alive "$peer" --cycles 5 "$count" -- test -s "$result" || rc=$?
  kill "$peer"
  wait "$peer" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "${dilation}x poller that published was rejected (rc=$rc)"
  pass "${dilation}x poller reaches the awaited outcome within its cycles"

  count="$TMP_ROOT/idle-$dilation.count"
  poller "$count" "$TMP_ROOT/idle-$dilation.result" "$dilation" 0
  peer=$!
  rc=0
  fm_test_wait_until --while-alive "$peer" --cycles 3 "$count" -- test -s "$TMP_ROOT/idle-$dilation.result" \
    2> "$TMP_ROOT/idle-$dilation.err" || rc=$?
  kill -0 "$peer" || fail "the cycle bound killed its peer instead of leaving cleanup to its owner"
  kill "$peer"
  wait "$peer" 2>/dev/null || true
  [ "$rc" -eq 1 ] || fail "${dilation}x live poller without the outcome was not rejected (rc=$rc)"
  assert_grep 'condition unmet after 3 peer cycles' "$TMP_ROOT/idle-$dilation.err" \
    "the live poller was not judged by its own cycles"
  [ "$(cat "$count")" -ge 3 ] || fail "the wait failed before the poller completed 3 cycles"
  pass "${dilation}x live poller without the outcome fails after its stated cycles"
done

# Real harm: a live peer with no outcome-specific progress is stuck. The
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

# A peer that exits leaves its recorded descendants to finish the work. Each peer
# publishes its child's PID after the fork and the main wait starts only once it
# exists; the peer exits only after the third probe, by which point the observer
# has sampled that tree at least once, so the record names the child without any
# clock.
note_probe() {  # <observed-marker> <result>
  printf 'probe\n' >> "$1.probes"
  [ "$(wc -l < "$1.probes")" -lt 3 ] || : > "$1"
  test -s "$2"
}
observed="$TMP_ROOT/descendant-publish.observed"
result="$TMP_ROOT/descendant.result"
child_pid="$TMP_ROOT/descendant-publish.child"
# shellcheck disable=SC2016 # The peer shell expands its positional arguments.
bash -c '
( while [ ! -e "$1" ]; do sleep 0.05; done; sleep 0.5; printf published > "$2" ) &
printf "%s\n" "$!" > "$3"
while [ ! -e "$1" ]; do sleep 0.05; done
' _ "$observed" "$result" "$child_pid" &
peer=$!
fm_test_wait_until --while-alive "$peer" -- test -s "$child_pid" || fail "the publishing peer never forked its child"
fm_test_wait_until --while-alive "$peer" -- note_probe "$observed" "$result" \
  || fail "a child publishing after its parent exited was rejected"
wait "$peer" || fail "descendant publisher failed"
[ "$(cat "$result")" = published ] || fail "the descendant result changed"
pass "an outcome a live descendant publishes after the peer exits still wins"

observed="$TMP_ROOT/descendant-silent.observed"
child_pid="$TMP_ROOT/descendant-silent.child"
# shellcheck disable=SC2016 # The peer shell expands its positional arguments.
bash -c '
( while [ ! -e "$1" ]; do sleep 0.05; done; exec sleep 1 ) &
printf "%s\n" "$!" > "$2"
while [ ! -e "$1" ]; do sleep 0.05; done
' _ "$observed" "$child_pid" &
peer=$!
fm_test_wait_until --while-alive "$peer" -- test -s "$child_pid" || fail "the silent peer never forked its child"
rc=0
fm_test_wait_until --while-alive "$peer" -- note_probe "$observed" "$TMP_ROOT/never-published" \
  2> "$TMP_ROOT/descendant-silent.err" || rc=$?
wait "$peer" 2>/dev/null || true
[ "$rc" -eq 1 ] || fail "a dead peer whose silent child ended without the outcome was accepted (rc=$rc)"
assert_grep 'condition unmet (3,' "$TMP_ROOT/descendant-silent.err" "the dead peer became an inactivity verdict"
if kill -0 "$(cat "$child_pid")" 2>/dev/null; then
  fail "the dead-peer verdict came while its recorded child was still running"
fi
pass "a dead peer fails only once its recorded descendants are gone too"

# A failed CPU read is unknown, not inactivity. Hide both process-table sources
# while a real publisher stays alive, then prove its result is still accepted.
# The publisher starts its quiet second only after the third probe, by which
# point the observer has taken a blind sample, so a loaded host cannot publish
# before the read failure is exercised.
fakebin=$(fm_fakebin "$TMP_ROOT/blind")
printf '#!/bin/sh\nexit 1\n' > "$fakebin/ps"
chmod +x "$fakebin/ps"
observed="$TMP_ROOT/blind.observed"
result="$TMP_ROOT/blind.result"
python3 -c '
import pathlib, sys, time
observed, result = map(pathlib.Path, sys.argv[1:])
while not observed.exists():
    time.sleep(0.05)
time.sleep(1)
result.write_text("observed")
' "$observed" "$result" &
publisher=$!
PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/absent-proc" \
  fm_test_wait_until --while-alive "$publisher" --inactivity 0.1 -- note_probe "$observed" "$result" \
  2> "$TMP_ROOT/blind.err" || fail "missing CPU telemetry became a stall verdict"
wait "$publisher" || fail "blind publisher failed"
assert_grep 'cpu_telemetry_unavailable:' "$TMP_ROOT/blind.err" "CPU read failure was not exercised"
[ "$(cat "$result")" = observed ] || fail "blind observation lost the result"
pass "unavailable CPU telemetry is unknown and retried"

# An invalid or absent observable must not fall back to a capped compatibility
# path, which would silently restore the bug in unmigrated callers.
for shape in no-observable old-api waiter-pid zero-cycles; do
  rc=0
  case "$shape" in
    zero-cycles) fm_test_wait_until --cycles 0 "$TMP_ROOT/count" -- false 2>/dev/null || rc=$? ;;
    old-api) fm_test_wait_until 1 false 2>/dev/null || rc=$? ;;
    waiter-pid) fm_test_wait_until --while-alive "$$" -- false 2>/dev/null || rc=$? ;;
    no-observable) fm_test_wait_until -- false 2>/dev/null || rc=$? ;;
  esac
  [ "$rc" -eq 2 ] || fail "$shape was not refused"
done
pass "waits require a producer observable and reject the old capped interface"

# Exercise the observer's public CLI with a controlled kernel table and a real
# live PID. An unreadable sample is unknown: it neither stops work nor resets the
# window, so two valid quiet observations across it, or a genuinely reused
# identity, still get caught.
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
    assert record.exists(), 'an unknown sample must keep the observation record'
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
print('ok - unknown samples keep the window, genuine inactivity and reused peers are caught, corrupt evidence is retried')
PY
