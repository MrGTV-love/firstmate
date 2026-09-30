#!/usr/bin/env bash
# Live lab driver: a process-event source whose launch never proves its claim
# makes `fm-procevent.sh reconcile` wait its whole launch-confirm window
# (FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=450, above the 300 s grace). Arm a real
# watcher in a disposable lab home and sample its beacon while that reconcile
# runs, then try a re-arm at >330 s.
# Usage: drive-slow-reconcile.sh <code-root> <label>
set -u
CODE=$1 LABEL=$2
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M3RBHP2HEVGS72YBVPJ7PKXK
LOG="$EV/slow-reconcile-$LABEL.log"
: > "$LOG"
say() { printf '[%s +%ss] %s\n' "$LABEL" "$SECONDS" "$*" | tee -a "$LOG"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$CODE/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
RUN=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_ARM_CONFIRM_TIMEOUT
  -u FM_POLL -u FM_GUARD_GRACE -u FM_WATCHER_STALE_GRACE
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=450 FM_HEARTBEAT=999999)
cleanup() {
  "${RUN[@]}" "$CODE/bin/fm-watch-arm.sh" --stop >>"$LOG" 2>&1 || true
  [ -z "${ARM_PID:-}" ] || { kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null; }
  for p in $(pgrep -f "fm-procevent.sh reconcile"); do
    ps -E -p "$p" -o command= 2>/dev/null | grep -q "FM_HOME=$LAB" && kill "$p" 2>/dev/null
  done
  rm -rf "$LAB"
}
trap cleanup EXIT

"${RUN[@]}" "$CODE/bin/fm-procevent.sh" register when probe -- /bin/sleep 1000 >>"$LOG" 2>&1
# Make the registration's argv unreadable so each launch dies before its claim;
# reconcile then waits out the full 450 s confirm window.
sed -i '' 's/^argc=.*/argc=x/' "$LAB/state/procevent/probe.source"
say "code=$CODE lab=$LAB confirm-window=450s grace=300s"

"${RUN[@]}" "$CODE/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 &
ARM_PID=$!
for _ in $(seq 1 150); do [ -s "$LAB/arm.out" ] && break; sleep 0.2; done
say "arm says: $(head -1 "$LAB/arm.out")"
WPID=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)
START=$(date +%s)
beat_age() { echo $(( $(date +%s) - $(stat -f %m "$LAB/state/.last-watcher-beat") )); }
max_age=0
while :; do
  el=$(( $(date +%s) - START ))
  [ "$el" -ge 340 ] && break
  a=$(beat_age); [ "$a" -gt "$max_age" ] && max_age=$a
  say "t=${el}s watcher alive=$(kill -0 "$WPID" 2>/dev/null && echo yes || echo no) beacon age=${a}s reconcile running=$(ps -E -ax -o command= | grep "fm-procevent.sh reconcile" | grep -q "FM_HOME=$LAB" && echo yes || echo no)"
  sleep 30
done
say "max beacon age observed during the slow reconcile: ${max_age}s (grace 300s)"
say "--- re-arm (bin/fm-watch.sh) at >340s ---"
"${RUN[@]}" "$CODE/bin/fm-watch.sh" >"$LAB/rearm.out" 2>&1; rc=$?
sed "s/^/  /" "$LAB/rearm.out" | tee -a "$LOG"; say "re-arm exit=$rc"
