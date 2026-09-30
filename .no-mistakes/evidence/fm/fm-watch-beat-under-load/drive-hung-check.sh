#!/usr/bin/env bash
# Live lab driver: a registered check that ignores TERM and never ends. The
# watcher must stop it at its deadline (FM_CHECK_TIMEOUT=5) and keep polling.
set -u
CODE=$1; EV=/Users/charlesabrooker/.no-mistakes/evidence/01M3RBHP2HEVGS72YBVPJ7PKXK; LOG=$EV/hung-check.log; : > $LOG
say() { printf '[+%ss] %s\n' "$SECONDS" "$*" | tee -a "$LOG"; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"; "$CODE/bin/fm-lab-home.sh" create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
RUN=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_ARM_CONFIRM_TIMEOUT -u FM_POLL -u FM_GUARD_GRACE
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_CHECK_TIMEOUT=5 FM_CHECK_INTERVAL=20 FM_HEARTBEAT=999999)
cleanup() { "${RUN[@]}" "$CODE/bin/fm-watch-arm.sh" --stop >>"$LOG" 2>&1; kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null; pkill -KILL -f "$LAB/state/hung.check.sh"; rm -rf "$LAB"; }
trap cleanup EXIT
cat > "$LAB/state/hung.check.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
echo "$(date +%s) start" >> "$FM_HOME/state/hung-runs"
while :; do sleep 1; done
SH
chmod 0700 "$LAB/state/hung.check.sh"
"${RUN[@]}" "$CODE/bin/fm-check-register.sh" hung >>"$LOG" 2>&1
"${RUN[@]}" "$CODE/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 & ARM_PID=$!
for i in $(seq 1 12); do
  sleep 5
  say "watcher alive=$(kill -0 "$(cat $LAB/state/.watch.lock/pid 2>/dev/null)" 2>/dev/null && echo yes || echo no) beacon age=$(( $(date +%s) - $(stat -f %m $LAB/state/.last-watcher-beat) ))s check runs so far=$(wc -l < $LAB/state/hung-runs 2>/dev/null | tr -d ' ') live hung-check procs=$(pgrep -f "$LAB/state/hung.check.sh" | wc -l | tr -d ' ')"
done
say "arm output: $(tr '\n' ' ' < $LAB/arm.out)"
