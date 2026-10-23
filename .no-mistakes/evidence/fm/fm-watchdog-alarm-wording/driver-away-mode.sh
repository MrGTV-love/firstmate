#!/usr/bin/env bash
# Live drive of the EXECUTED away-mode daemon into a wedge alarm in a lab home.
set -u
WT=$1
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-wd-away.XXXXXX")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$SCR/home" "$SCR/shims"
for b in osascript herdr; do
cat > "$SCR/shims/$b" <<S
#!/bin/sh
{ printf '$b argv:'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$SCR/notify.calls"
S
chmod +x "$SCR/shims/$b"; done
printf 'osascript\nherdr\n' > "$LAB/config/wedge-alarm"
env -u TMUX TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s sup -x 120 -y 40 "/bin/sleep 600" || echo "lab tmux failed"
: > "$LAB/state/.afk"
printf 'lab escalation: test item\n' > "$LAB/state/.subsuper-escalations"
echo 1000 > "$LAB/state/.subsuper-escalations.since"
env -u FM_WEDGE_ALARM_EXEC -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  HOME="$SCR/home" FM_TELEMETRY_DIR="$SCR/tel" PATH="$SCR/shims:$PATH" TMUX_TMPDIR="$LAB/tmux" \
  FM_HOME="$LAB" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET='sup:0.0' \
  FM_MAX_DEFER_SECS=1 FM_HOUSEKEEPING_TICK=1 FM_ESCALATE_BATCH_SECS=1 FM_INJECT_CONFIRM_RETRIES=1 \
  nice -n 20 "$WT/bin/fm-supervise-daemon.sh" > "$SCR/daemon.out" 2>&1 &
dpid=$!
for i in $(seq 1 40); do [ -s "$SCR/notify.calls" ] && break; sleep 1; done
kill -TERM "$dpid" 2>/dev/null; sleep 2; kill -KILL "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
pkill -f "$LAB" 2>/dev/null
echo "--- notifier calls from the executed daemon ---"; cat "$SCR/notify.calls" 2>/dev/null || echo '<none>'
echo "--- marker ---"; head -3 "$LAB/state/.subsuper-inject-wedged" 2>/dev/null || echo '<none>'
echo "--- daemon log (wedge lines) ---"; grep -i "wedge\|ERROR\|refus" "$LAB/state/.supervise-daemon.log" 2>/dev/null | head -10
echo "--- daemon stdout ---"; head -20 "$SCR/daemon.out"
TMUX_TMPDIR="$LAB/tmux" tmux -L default kill-server 2>/dev/null
rm -rf "$LAB" "$SCR"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
