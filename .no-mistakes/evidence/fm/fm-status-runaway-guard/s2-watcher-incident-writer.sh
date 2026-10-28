#!/usr/bin/env bash
# Live drive of the real watcher (bin/fm-watch.sh) against the 2026-10-18 writer shape,
# inside a disposable lab FM_HOME minted by bin/fm-lab-home.sh. Run from the gate worktree.
# Usage: s2-watcher-incident-writer.sh <writer-name: omp|bash|none>
#   omp/bash: a process of that name holds state/<task>.status open and loops
#     printf 'text\n' "$(date +%s)" >&9   (format with no conversion plus an extra argument)
#   none: the log is pushed past the cap by a writer that has already exited.
# Expected: one over-cap wake naming file, size, growth, writer pid; that pid stopped
# (none: stops nothing); the log never deleted or rewritten; no second wake while it
# does not grow.
set -u
NAME=${1:?omp|bash|none}
REPO=$PWD
eval "$("$REPO/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
WPID=
cleanup() {
  [ -z "$WPID" ] || { kill -CONT "$WPID" 2>/dev/null; kill -9 "$WPID" 2>/dev/null; }
  pkill -f "$LAB" 2>/dev/null
  "$REPO/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"; echo "lab removed: $LAB"
}
trap cleanup EXIT
: > "$LAB/config/supervision-host-off"; printf "## In flight\n\n## Queued\n\n## Done\n" > "$LAB/data/backlog.md"
STATE="$LAB/state"; F="$STATE/d1-intake.status"; : > "$F"
sz() { stat -f %z "$1"; }
echo "lab FM_HOME=$LAB writer=$NAME cap=262144"

if [ "$NAME" = none ]; then
  head -c 400000 /dev/zero | tr '\0' 'x' | fold -w 99 > "$F"
else
  mkdir -p "$LAB/bin"; ln -s "$(command -v bash)" "$LAB/bin/$NAME"
  ( ulimit -f 16384   # hard 8 MiB-16 MiB limit so a broken guard cannot fill the disk
    "$LAB/bin/$NAME" -c '
      exec 9>>"$1"
      r=0
      while [ "$r" -lt 400 ]; do
        r=$((r + 1)); i=0; s=$(date +%s)
        while [ "$i" -lt 4000 ]; do i=$((i + 1)); printf "text\n" "$s" >&9; done
        sleep 1 9>&-
      done' _ "$F" &
    echo $! > "$LAB/writer.pid"; wait ) &
  while [ ! -s "$LAB/writer.pid" ]; do sleep 0.1; done
  WPID=$(cat "$LAB/writer.pid")
  echo "writer pid $WPID comm=$(ps -p "$WPID" -o comm=)"
fi

watch() {  # <out>
  FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=262144 \
    FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
    "$REPO/bin/fm-watch.sh" > "$1" 2> "$1.err" &
}
ack() {
  local err=$STATE/.ack.err s g
  FM_HOME="$LAB" "$REPO/bin/fm-wake-drain.sh" > "$STATE/.drain.out" 2> "$err"  # non-zero while no watcher is armed; the ack line decides
  s=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  g=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$s" ] && [ -n "$g" ] || return 1
  FM_HOME="$LAB" "$REPO/bin/fm-wake-drain.sh" --ack-through "$s" --recovery-generation "$g" > /dev/null
}
t0=$SECONDS; attempt=0; found=0
while [ $attempt -lt 20 ]; do
  attempt=$((attempt + 1)); out="$LAB/watch.$attempt.out"
  watch "$out"; wp=$!
  w=0; while kill -0 $wp 2>/dev/null && [ $w -lt 3000 ]; do sleep 0.1; w=$((w+1)); done
  kill -0 $wp 2>/dev/null && { echo "watcher $attempt still running after 300 s"; kill $wp; break; }
  echo "watcher run $attempt exited after $((SECONDS - t0)) s, log $(sz "$F") bytes: $(head -c 300 "$out" | tr '\n' ' ')"
  if grep -q 'check: status-log-over-cap' "$out"; then found=1; break; fi
  ack || { echo "ack failed: $(cat "$STATE/.ack.err" | head -5)"; break; }
done
[ $found = 1 ] || { echo "RESULT: FAIL no over-cap wake"; exit 1; }
echo "--- over-cap wake text ---"; grep 'status-log-over-cap' "$out"
s1=$(sz "$F"); echo "log size at wake: $s1 bytes (cap 262144); exists: $([ -f "$F" ] && echo yes)"
echo "over-cap rows in wake queue: $(grep -c 'status-log-over-cap' "$STATE/.wake-queue" 2>/dev/null)"
if [ -n "$WPID" ]; then echo "writer pid $WPID ps state: $(ps -p "$WPID" -o state= | tr -d ' ') (T = stopped)"; fi
echo "firstmate/test shell state: $(ps -p $$ -o state= | tr -d ' ')"
sleep 3; s2=$(sz "$F"); echo "log size 3 s later: $s2 (grew: $([ "$s2" -gt "$s1" ] && echo YES || echo no))"
ack || echo "ack failed"
watch "$LAB/watch.again.out"; wp=$!
w=0; while kill -0 $wp 2>/dev/null && [ $w -lt 150 ]; do sleep 0.1; w=$((w+1)); done
if kill -0 $wp 2>/dev/null; then echo "second watcher stayed quiet 15 s on the unchanged over-cap log (no second wake)"; kill $wp; wait $wp 2>/dev/null
else echo "second watcher exited: $(head -c 300 "$LAB/watch.again.out")"; fi
echo "final size $(sz "$F") ; first 2 lines: $(head -2 "$F" | tr '\n' '|' | cut -c1-40)"
