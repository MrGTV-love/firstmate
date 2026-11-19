#!/usr/bin/env bash
# INT variant: the writer is exec'd from python with SIGINT reset to default, because a
# non-interactive bash background job ignores SIGINT on entry (a harness artifact, not product behaviour).
set -u
ROOT=$1; N=$2
STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-kill-state.XXXXXX")
mkdir -p "$STATE/t1.inbox/handled"
i=0
while [ "$i" -lt "$N" ]; do
  i=$((i+1))
  printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\nhandled steer %s\nsecond line\n' "$i" > "$STATE/t1.inbox/handled/$(printf '%04d' "$i").msg"
done
LIB="$ROOT/bin/fm-task-inbox-lib.sh"
TEXT="KILLED-STEER corr=K1"
FM_STATE_OVERRIDE="$STATE" /usr/bin/python3 -I -c '
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp("bash", ["bash", "-c", ". \"$1\"; fm_task_inbox_write_idempotent \"$2\" t1 \"$3\"", "_", sys.argv[1], sys.argv[2], sys.argv[3]])
' "$LIB" "$STATE" "$TEXT" > "$STATE/k1.out" 2> "$STATE/k1.err" &
PID=$!
n=0
while [ ! -L "$STATE/t1.inbox/.seq.lock" ] && [ "$n" -lt 2000 ]; do n=$((n+1)); sleep 0.01; done
sleep 0.2
echo "pre-signal: lock_held=$([ -L "$STATE/t1.inbox/.seq.lock" ] && echo yes || echo no) work_dirs=$(ls -a "$STATE/t1.inbox" | grep -c '^\.work\.') alive=$(kill -0 $PID 2>/dev/null && echo yes || echo no)"
kill -s INT "$PID" 2>/dev/null
wait "$PID" 2>/dev/null; RC=$?
echo "signal=INT writer_exit=$RC"
echo "post-signal entries: $(ls -a "$STATE/t1.inbox" | grep -E '^\.(dedup|work|staging)' | tr '\n' ' ')"
echo "lock_left=$([ -L "$STATE/t1.inbox/.seq.lock" ] && echo yes || echo no) unhandled_after_signal=$(ls "$STATE/t1.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')"
echo "writer_stderr: $(head -c 200 "$STATE/k1.err")"
TIMEFORMAT=%R
T=$( { time FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_task_inbox_write_idempotent "$2" t1 "$3"' _ "$LIB" "$STATE" "AFTER-KILL-STEER corr=K2" > "$STATE/k2.out" 2> "$STATE/k2.err"; echo "rc=$?" > "$STATE/k2.rc"; } 2>&1 )
echo "second_call rc=$(cut -d= -f2 "$STATE/k2.rc") seconds=$T printed=$(sed "s|$STATE|STATE|" "$STATE/k2.out") err=$(head -c 200 "$STATE/k2.err")"
echo "second_call_entries: $(ls -a "$STATE/t1.inbox" | grep -E '^\.(dedup|work|staging)' | tr '\n' ' ') unhandled=$(ls "$STATE/t1.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$STATE"
