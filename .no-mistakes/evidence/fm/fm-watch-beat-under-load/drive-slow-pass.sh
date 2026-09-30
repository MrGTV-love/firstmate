#!/usr/bin/env bash
# Live lab driver: arm a real firstmate watcher in a disposable lab home, make
# one poll pass slow (a registered custom check that runs longer than the
# default 300 s grace), and sample what supervision sees while the watcher is
# alive and working. Then SIGSTOP the watcher (a genuinely stuck poll) and
# confirm the beacon goes stale and re-arm refuses.
# Usage: drive-slow-pass.sh <code-root> <label>
set -u
CODE=$1 LABEL=$2
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M3RBHP2HEVGS72YBVPJ7PKXK
LOG="$EV/slow-pass-$LABEL.log"
: > "$LOG"
say() { printf '[%s +%ss] %s\n' "$LABEL" "$SECONDS" "$*" | tee -a "$LOG"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"
"$CODE/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { say "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux"
RUN=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_ARM_CONFIRM_TIMEOUT
  -u FM_POLL -u FM_GUARD_GRACE -u FM_WATCHER_STALE_GRACE
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_CHECK_TIMEOUT=600 FM_HEARTBEAT=999999)
cleanup() {
  [ -z "${ARM_PID:-}" ] || kill -CONT "$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)" 2>/dev/null
  touch "$LAB/state/check-release" 2>/dev/null
  "${RUN[@]}" "$CODE/bin/fm-watch-arm.sh" --stop >>"$LOG" 2>&1 || true
  [ -z "${ARM_PID:-}" ] || { kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null; }
  pkill -f "$LAB/state/slow.check.sh" 2>/dev/null || true   # only this lab's check path
  rm -rf "$LAB"
}
trap cleanup EXIT

say "code=$CODE commit=$(git -C "$CODE" rev-parse --short HEAD 2>/dev/null || echo "$LABEL") lab=$LAB"
# A slow custom check: 420 s of real work, well past the 300 s default grace.
cat > "$LAB/state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
date +%s > "$FM_HOME/state/check-started"
i=0; while [ "$i" -lt 4200 ] && [ ! -e "$FM_HOME/state/check-release" ]; do sleep 0.1; i=$((i+1)); done
touch "$FM_HOME/state/check-finished"
SH
chmod 0700 "$LAB/state/slow.check.sh"
"${RUN[@]}" "$CODE/bin/fm-check-register.sh" slow >>"$LOG" 2>&1 || { say "register failed"; exit 1; }

"${RUN[@]}" "$CODE/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 &
ARM_PID=$!
for _ in $(seq 1 300); do [ -s "$LAB/state/check-started" ] && break; sleep 0.2; done
[ -s "$LAB/state/check-started" ] || { say "watcher never entered slow check"; cat "$LAB/arm.out" | tee -a "$LOG"; exit 1; }
say "arm says: $(head -1 "$LAB/arm.out")"
WPID=$(cat "$LAB/state/.watch.lock/pid")
say "watcher pid=$WPID is inside the slow check (pass is blocked on it)"

beat_age() { echo $(( $(date +%s) - $(stat -f %m "$LAB/state/.last-watcher-beat") )); }
max_age=0
while [ ! -e "$LAB/state/check-finished" ]; do
  a=$(beat_age); [ "$a" -gt "$max_age" ] && max_age=$a
  el=$(( $(date +%s) - $(cat "$LAB/state/check-started") ))
  if [ $((el % 30)) -lt 3 ] || [ "$el" -ge 330 ]; then
    say "check running ${el}s; watcher alive=$(kill -0 "$WPID" 2>/dev/null && echo yes || echo no); beacon age=${a}s"
  fi
  if [ "$el" -ge 330 ]; then break; fi
  sleep 3
done
say "max beacon age observed during slow check: ${max_age}s (grace 300s)"

# The Stop auto-arm path: a re-arm while the slow pass is still working.
say "--- re-arm (bin/fm-watch.sh) at >330s into one slow pass ---"
"${RUN[@]}" "$CODE/bin/fm-watch.sh" >"$LAB/rearm.out" 2>&1; rc=$?
sed "s/^/  /" "$LAB/rearm.out" | tee -a "$LOG"; say "re-arm exit=$rc"
say "--- second arm (bin/fm-watch-arm.sh) status line ---"
( "${RUN[@]}" FM_ARM_CONFIRM_TIMEOUT=20 "$CODE/bin/fm-watch-arm.sh" >"$LAB/arm2.out" 2>&1 & echo $! > "$LAB/arm2.pid"; wait ) &
for _ in $(seq 1 100); do [ -s "$LAB/arm2.out" ] && break; sleep 0.3; done
sleep 1; kill "$(cat "$LAB/arm2.pid")" 2>/dev/null
sed "s/^/  /" "$LAB/arm2.out" | tee -a "$LOG"

# Adversarial: a stopped main poll must go stale even with its check child alive.
say "--- SIGSTOP watcher pid=$WPID (stuck loop), check child still running ---"
kill -STOP "$WPID"
sleep 320
say "check child alive=$(pgrep -f "$LAB/state/slow.check.sh" >/dev/null && echo yes || echo no); beacon age=$(beat_age)s"
"${RUN[@]}" "$CODE/bin/fm-watch.sh" >"$LAB/rearm-stopped.out" 2>&1; rc=$?
sed "s/^/  /" "$LAB/rearm-stopped.out" | tee -a "$LOG"; say "re-arm on stopped watcher exit=$rc"
kill -CONT "$WPID"
touch "$LAB/state/check-release"
for _ in $(seq 1 100); do [ -e "$LAB/state/check-finished" ] && break; sleep 0.2; done
say "resumed; check finished=$([ -e "$LAB/state/check-finished" ] && echo yes || echo no)"
