#!/usr/bin/env bash
# Live driver for fm_test_wait_until (branch) versus main's capped wait.
# Usage: slow-host-driver.sh <worktree> <base-commit>
# Runs real producers on a host loaded by CPU-burning neighbours.
set -u
WT=$1 BASE=$2
cd "$WT" || exit 2
# shellcheck source=/dev/null
. tests/lib.sh
TMP=$(fm_test_tmproot fm-slow-host-driver)
# main's helper, renamed, taken verbatim from the base commit.
eval "$(git show "$BASE:tests/lib.sh" | awk '/^fm_test_wait_until\(\)/,/^}/' | sed 's/^fm_test_wait_until()/old_wait()/')"

burners=()
start_burners() { local i; for ((i = 0; i < $1; i++)); do python3 -c 'while True: pass' & burners+=($!); done; }
stop_burners() { [ "${#burners[@]}" -gt 0 ] || return 0; kill "${burners[@]}" 2>/dev/null; wait "${burners[@]}" 2>/dev/null; burners=(); }
trap stop_burners EXIT
now() { python3 -c 'import time; print("%.2f" % time.time())'; }
since() { python3 -c "import sys,time; print('%.1f' % (time.time() - float(sys.argv[1])))" "$1"; }

# Producer: 20 steps of small CPU work plus a sleep, both scaled by <dilation>;
# journal per step. exec makes the background PID the real worker.
producer() {  # <journal> <result> <dilation>
  exec python3 -c '
import hashlib, pathlib, sys, time
journal, result, dilation = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
started = time.monotonic()
for step in range(20):
    for _ in range(2000 * dilation):
        hashlib.sha256(b"x").digest()
    time.sleep(0.1 * dilation)
    journal.write_text(str(step))
result.write_text("published work=%.1fs" % (time.monotonic() - started))
' "$@"
}

echo "== host: $(sysctl -n hw.ncpu) cpus; uptime: $(uptime)"
start_burners 36
echo "== started ${#burners[@]} CPU-burning neighbours; load now: $(sysctl -n vm.loadavg)"

# S1: one producer, 20 steps of 0.1s x <dilation> plus tiny CPU work. A 5s
# total cap (main's helper, a margin over the 1x run) versus the branch helper.
for dilation in 1 5; do
  echo "== S1 dilation ${dilation}x: RED check with main's capped helper (cap 5s)"
  rm -f "$TMP/j$dilation" "$TMP/r$dilation"
  ( producer "$TMP/j$dilation" "$TMP/r$dilation" "$dilation" ) & p=$!
  t=$(now); rc=0; old_wait 5 test -s "$TMP/r$dilation" || rc=$?
  echo "main old_wait 5 -> rc=$rc after $(since "$t")s; result present at verdict: $([ -s "$TMP/r$dilation" ] && echo yes || echo no); producer alive at verdict: $(kill -0 $p 2>/dev/null && echo yes || echo no)"
  wait "$p"; echo "producer finished anyway: $(cat "$TMP/r$dilation")"
  echo "== S1 dilation ${dilation}x: branch helper on the same producer"
  rm -f "$TMP/j$dilation" "$TMP/r$dilation"
  t=$(now); producer "$TMP/j$dilation" "$TMP/r$dilation" "$dilation" & p=$!
  rc=0; fm_test_wait_until --while-alive "$p" --progress-file "$TMP/j$dilation" -- test -s "$TMP/r$dilation" || rc=$?
  echo "branch fm_test_wait_until -> rc=$rc after $(since "$t")s; result: $(cat "$TMP/r$dilation" 2>/dev/null)"
  wait "$p"
done

echo "== S2 dead peer (SIGKILL mid-work) under load, DEFAULT 15-minute inactivity"
rm -f "$TMP/jd" "$TMP/rd"
producer "$TMP/jd" "$TMP/rd" 5 & p=$!
( sleep 3; kill -9 "$p" ) &
t=$(now); rc=0; fm_test_wait_until --while-alive "$p" --progress-file "$TMP/jd" -- test -s "$TMP/rd" 2> "$TMP/dead.err" || rc=$?
echo "rc=$rc after $(since "$t")s; stderr: $(cat "$TMP/dead.err")"
wait "$p" 2>/dev/null

echo "== S3 hung peer (SIGSTOP: alive, no CPU, no journal change) under load, --inactivity 3"
rm -f "$TMP/jh" "$TMP/rh"
producer "$TMP/jh" "$TMP/rh" 5 & p=$!
fm_test_wait_until --while-alive "$p" -- test -s "$TMP/jh"   # first step done
kill -STOP "$p"
t=$(now); rc=0; fm_test_wait_until --while-alive "$p" --progress-file "$TMP/jh" --inactivity 3 -- test -s "$TMP/rh" 2> "$TMP/hung.err" || rc=$?
echo "rc=$rc after $(since "$t")s; stderr: $(cat "$TMP/hung.err"); peer still alive (not killed by helper): $(kill -0 $p 2>/dev/null && echo yes || echo no)"
kill -CONT "$p"; kill "$p"; wait "$p" 2>/dev/null

echo "== S4 busy-but-pointless peer (burns CPU, never touches its outcome) --inactivity 3"
python3 -c 'while True: pass' & p=$!
t=$(now); rc=0; fm_test_wait_until --while-alive "$p" --progress-file "$TMP/never" --inactivity 3 -- test -s "$TMP/never" 2> "$TMP/spin.err" || rc=$?
echo "rc=$rc after $(since "$t")s; stderr: $(cat "$TMP/spin.err")"
kill "$p"; wait "$p" 2>/dev/null

echo "== S5 slow, failing process-table reads are unknown, not death (ps shim: sleeps 2s then fails)"
mkdir -p "$TMP/slowps"
printf '#!/bin/sh\nsleep 2\nexit 1\n' > "$TMP/slowps/ps"; chmod +x "$TMP/slowps/ps"
rm -f "$TMP/js" "$TMP/rs"
producer "$TMP/js" "$TMP/rs" 3 & p=$!
t=$(now); rc=0
PATH="$TMP/slowps:$PATH" fm_test_wait_until --while-alive "$p" --progress-file "$TMP/js" --inactivity 2 -- test -s "$TMP/rs" 2> "$TMP/slowps.err" || rc=$?
echo "rc=$rc after $(since "$t")s; result: $(cat "$TMP/rs" 2>/dev/null); stderr: $(tr '\n' ' ' < "$TMP/slowps.err")"
wait "$p"

echo "== S6 peer exits, child it left finishes the work (descendant)"
rm -f "$TMP/rc6" "$TMP/c6"
bash -c '( sleep 4; printf done > "$1" ) & printf "%s\n" "$!" > "$2"; sleep 1' _ "$TMP/rc6" "$TMP/c6" & p=$!
fm_test_wait_until --while-alive "$p" -- test -s "$TMP/c6"
t=$(now); rc=0; fm_test_wait_until --while-alive "$p" -- test -s "$TMP/rc6" 2> "$TMP/desc.err" || rc=$?
echo "rc=$rc after $(since "$t")s; result: $(cat "$TMP/rc6" 2>/dev/null); stderr: $(cat "$TMP/desc.err")"
wait "$p"

stop_burners
echo "== load at end: $(sysctl -n vm.loadavg)"
rm -rf "$TMP"
