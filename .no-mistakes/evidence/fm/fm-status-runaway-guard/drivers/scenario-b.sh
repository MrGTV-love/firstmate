#!/usr/bin/env bash
# Scenario B (adversarial, r9-1): a fast non-omp writer the guard cannot stop, cap 2048 bytes.
# The watcher must still exit, with exactly one over-cap wake row per watcher run.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5JEP7JBE1M3121EZV5RJ1V3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"; : > "$LAB/config/supervision-host-off"
NB=$(mktemp -d "${TMPDIR:-/tmp}/fm-named.XXXXXX"); ln -s "$(command -v bash)" "$NB/pywriter"
S="$LAB/state/lane-x.status"; : > "$S"
echo "lab=$LAB cap=2048"
# ~64 KB every 20 ms (about 3 MB/s), held open, hard limit 128 MiB, killed after 150 s at most.
( ulimit -f 262144; exec timeout 150 "$NB/pywriter" -c 'chunk=$(head -c 65535 /dev/zero | tr "\0" y); exec 9>>"$1"; while :; do printf "%s\n" "$chunk" >&9; sleep 0.02; done' _ "$S" ) &
WPID=$!
sleep 1
run_watch() {
  timeout 120 env -u TMUX -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=2048 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
    FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
    "$WT/bin/fm-watch.sh"
}
drain() { env -u NO_MISTAKES_GATE FM_HOME="$LAB" "$WT/bin/fm-wake-drain.sh" "$@"; }
ack() {
  local err seq gen
  err=$(drain 2>&1)
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p')
  gen=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p')
  [ -n "$seq" ] || { echo "(no ack line)"; return 1; }
  drain --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 && echo "(acked through $seq)"
}
for n in 1 2 3; do
  t0=$SECONDS
  out=$(run_watch 2>>"$LAB.watch.err"); rc=$?
  rows=$(grep -c status-log-over-cap "$LAB/state/.wake-queue" 2>/dev/null)
  echo "--- watcher run $n: exit=$rc after $((SECONDS-t0))s (124 means it hung until timeout); over-cap rows now in queue=$rows"
  printf 'wake text: %s\n' "$out"
  echo "log size now: $(stat -f %z "$S") bytes; writer state: $(ps -p "$(pgrep -P "$WPID" | head -1)" -o state= 2>/dev/null)"
  ack
done
kill -9 $(pgrep -P "$WPID") "$WPID" 2>/dev/null; wait 2>/dev/null
rm -rf "$LAB" "$LAB.watch.err" "$NB"; echo "lab removed: $( [ -d "$LAB" ] || echo yes)"
