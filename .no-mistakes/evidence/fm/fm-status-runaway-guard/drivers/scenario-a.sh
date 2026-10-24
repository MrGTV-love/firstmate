#!/usr/bin/env bash
# Scenario A: the exact 2026-10-18 producer loop under a process named omp, real watcher, lab home.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5JEP7JBE1M3121EZV5RJ1V3
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5JEP7JBE1M3121EZV5RJ1V3
CAP=${CAP:-16384}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"; : > "$LAB/config/supervision-host-off"
NB=$(mktemp -d "${TMPDIR:-/tmp}/fm-named.XXXXXX"); ln -s "$(command -v bash)" "$NB/omp"
S="$LAB/state/d1-intake.status"; : > "$S"
echo "lab=$LAB cap=$CAP"
# The incident command, verbatim, held open by the loop's redirection, under a hard 8 MiB limit.
( ulimit -f 16384; exec "$NB/omp" -c 'while :; do printf '"'"'text\n'"'"' "$(date +%s)"; done >> "$1"' _ "$S" ) &
WPID=$!
sleep 0.5
# A bystander omp that holds no status log.
"$NB/omp" -c 'sleep 600' & BY=$!
run_watch() {
  timeout 120 env -u TMUX -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=$CAP FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
    FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
    "$WT/bin/fm-watch.sh"
}
drain() { env -u NO_MISTAKES_GATE FM_HOME="$LAB" "$WT/bin/fm-wake-drain.sh" "$@"; }
ack() {
  local err seq gen
  err=$(drain 2>&1)
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \([^ ]*\)$/\1/p')
  gen=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \([^ ]*\)$/\1/p')
  [ -n "$seq" ] && drain --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
start=$SECONDS; n=0
while [ $n -lt 8 ]; do
  n=$((n+1))
  out=$(run_watch 2>>"$LAB/../fm-watch-a.err")
  echo "--- watcher run $n (t=$((SECONDS-start))s) wake text:"; printf '%s\n' "$out"
  case "$out" in *status-log-over-cap*) break ;; esac
  ack || echo "(ack failed)"
done
st() { ps -p "$1" -o state= | tr -d ' ' | cut -c1; }
sz() { stat -f %z "$S"; }
# find the actual omp writer pid (child of subshell)
OPID=$(pgrep -P "$WPID" 2>/dev/null | head -1); [ -n "$OPID" ] || OPID=$WPID
echo "writer pid=$OPID state=$(st "$OPID") bystander state=$(st "$BY")"
a=$(sz); sleep 2; b=$(sz)
echo "log exists: $( [ -f "$S" ] && echo yes); size=$a then after 2s size=$b (cap $CAP)"
echo "over-cap rows in .wake-queue: $(grep -c status-log-over-cap "$LAB/state/.wake-queue")"
echo "--- drain view of the queue:"; drain 2>&1 | head -30
echo "--- tail sample of log:"; tail -3 "$S"
kill -CONT "$OPID" 2>/dev/null; kill -9 "$OPID" "$WPID" "$BY" 2>/dev/null
wait 2>/dev/null
TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null
rm -rf "$LAB" "$NB"; echo "lab removed: $( [ -d "$LAB" ] || echo yes)"
