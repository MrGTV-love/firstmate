#!/usr/bin/env bash
# Live A/B probe: run the real fm-watch.sh in a fresh marked lab home with one
# slow registered custom check, and count the external sleep/dirname/uname
# launches whose parent is the watcher main shell while the check runs.
# Usage: live-wait.sh <lab> <tree-dir> <label> <hold-seconds> <out-dir> <worktree>
set -u
LAB=$1 TREE=$2 LABEL=$3 HOLD=$4 OUT=$5 WT=$6
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || exit 90
STATE="$HOME_DIR/state"
mkdir -p "$STATE"
SHIM="$HOME_DIR/shim"
mkdir -p "$SHIM"
LOG="$HOME_DIR/launches.log"
: > "$LOG"
for tool in sleep dirname uname basename; do
  real=$(command -v "$tool")
  cat > "$SHIM/$tool" <<SH
#!/bin/bash
printf '%s %s %s %s\n' "\$(/bin/date +%s)" "\$PPID" "$tool" "\$*" >> "$LOG"
exec "$real" "\$@"
SH
  chmod +x "$SHIM/$tool"
done
cat > "$STATE/slow.check.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$STATE/check-started"
/bin/sleep $HOLD
touch "$STATE/check-finished"
SH
chmod 0700 "$STATE/slow.check.sh"
env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" bash "$TREE/bin/fm-check-register.sh" slow >/dev/null || exit 91
started=$(date +%s)
env -u TMUX -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" FM_WEDGE_ALARM_EXEC=/usr/bin/true PATH="$SHIM:$PATH" FM_HOME="$HOME_DIR" \
  FM_POLL=1 FM_GUARD_GRACE=6 FM_CHECK_TIMEOUT=120 FM_HEARTBEAT=999999 \
  "$TREE/bin/fm-watch.sh" > "$HOME_DIR/watch.out" 2> "$HOME_DIR/watch.err" &
WPID=$!
for ((i = 0; i < 600; i++)); do [ -s "$STATE/check-started" ] && break; /bin/sleep 0.1; done
[ -s "$STATE/check-started" ] || { echo "$LABEL: watcher never entered check"; cat "$HOME_DIR/watch.err"; kill "$WPID"; exit 92; }
entered=$(date +%s)
before_sleep=$(awk -v p="$WPID" '$2==p && $3=="sleep"' "$LOG" | wc -l | tr -d ' ')
startup_dirname=$(awk '$3=="dirname"' "$LOG" | wc -l | tr -d ' ')
startup_uname=$(awk '$3=="uname"' "$LOG" | wc -l | tr -d ' ')
max_age=0
for ((s = 0; s < HOLD - 4; s++)); do
  /bin/sleep 1
  now=$(date +%s)
  m=$(/usr/bin/stat -f %m "$STATE/.last-watcher-beat" 2>/dev/null || echo 0)
  age=$((now - m)); [ "$age" -le "$max_age" ] || max_age=$age
done
window=$(( $(date +%s) - entered ))
during_sleep=$(awk -v p="$WPID" '$2==p && $3=="sleep"' "$LOG" | wc -l | tr -d ' ')
during_sleep=$((during_sleep - before_sleep))
alive=no; kill -0 "$WPID" 2>/dev/null && alive=yes
check_pid=$(cat "$STATE/check-started")
kill -TERM "$WPID" 2>/dev/null
for ((i = 0; i < 100; i++)); do kill -0 "$WPID" 2>/dev/null || break; /bin/sleep 0.1; done
watcher_gone=yes; kill -0 "$WPID" 2>/dev/null && watcher_gone=no
/bin/sleep 0.5
check_gone=yes; kill -0 "$check_pid" 2>/dev/null && check_gone=no
orphan_sleep=$(pgrep -f "/bin/sleep $HOLD" | wc -l | tr -d ' ')
{
  echo "label=$LABEL tree=$TREE"
  echo "watcher_pid=$WPID time_to_check=$((entered - started))s alive_during_check=$alive"
  echo "startup_dirname_launches_before_check=$startup_dirname startup_uname_launches_before_check=$startup_uname"
  echo "watcher_main_shell_sleep_launches_during_check=$during_sleep over ${window}s"
  echo "max_beat_age_during_check=${max_age}s (FM_GUARD_GRACE=6)"
  echo "after_TERM: watcher_gone=$watcher_gone check_child_gone=$check_gone leftover_check_sleep=$orphan_sleep"
  echo "--- watcher stderr tail"; tail -5 "$HOME_DIR/watch.err"
} | tee "$OUT/live-wait-$LABEL.txt"
cp "$LOG" "$OUT/live-wait-$LABEL.launches.log"
rm -rf "$HOME_DIR"
