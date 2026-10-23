#!/usr/bin/env bash
# Live probe: real fm-watch.sh in a fresh marked lab home runs one registered
# custom check that either hangs past its deadline (hang) or exits leaving a
# TERM-ignoring descendant in its group (leftover). Optional noperl mode runs
# the watcher on a PATH that mirrors the normal PATH minus every perl* binary.
# Usage: live-stop.sh <lab> <tree> <label> <hang|leftover> <perl|noperl> <out> <worktree>
set -u
LAB=$1 TREE=$2 LABEL=$3 MODE=$4 PERLMODE=$5 OUT=$6 WT=$7
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || exit 90
STATE="$HOME_DIR/state"
mkdir -p "$STATE"
SHIM="$HOME_DIR/shim"
mkdir -p "$SHIM"
LOG="$HOME_DIR/launches.log"
: > "$LOG"
real_sleep=$(command -v sleep)
cat > "$SHIM/sleep" <<SH
#!/bin/bash
printf '%s %s sleep %s\n' "\$(/bin/date +%s)" "\$PPID" "\$*" >> "$LOG"
exec "$real_sleep" "\$@"
SH
chmod +x "$SHIM/sleep"
RUNPATH="$SHIM:$PATH"
if [ "$PERLMODE" = noperl ]; then
  NP="$HOME_DIR/noperl-bin"
  mkdir -p "$NP"
  IFS=: read -r -a dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      n=${f##*/}
      case "$n" in perl*) continue ;; esac
      [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$NP/$n" ] && ln -s "$f" "$NP/$n"
    done
  done
  RUNPATH="$SHIM:$NP"
  PATH="$RUNPATH" bash -c 'command -v perl' && { echo "perl still visible"; exit 93; }
fi
case "$MODE" in
  hang) body="printf '%s\n' \"\$\$\" > '$STATE/desc-pid'; exec /bin/sleep 63"; timeout=3 ;;
  leftover) body="(trap '' TERM; exec /bin/sleep 64) & printf '%s\n' \"\$!\" > '$STATE/desc-pid'; echo leader-done"; timeout=30 ;;
esac
cat > "$STATE/stop.check.sh" <<SH
#!/usr/bin/env bash
date +%s > "$STATE/check-started"
$body
SH
chmod 0700 "$STATE/stop.check.sh"
env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" bash "$TREE/bin/fm-check-register.sh" stop >/dev/null || exit 91
env -u TMUX -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" FM_WEDGE_ALARM_EXEC=/usr/bin/true PATH="$RUNPATH" FM_HOME="$HOME_DIR" \
  FM_POLL=1 FM_GUARD_GRACE=6 FM_CHECK_TIMEOUT=$timeout FM_HEARTBEAT=999999 \
  /bin/bash "$TREE/bin/fm-watch.sh" > "$HOME_DIR/watch.out" 2> "$HOME_DIR/watch.err" &
WPID=$!
for ((i = 0; i < 600; i++)); do [ -s "$STATE/desc-pid" ] && break; /bin/sleep 0.1; done
[ -s "$STATE/desc-pid" ] || { echo "$LABEL: check never started"; cat "$HOME_DIR/watch.err"; kill "$WPID"; exit 92; }
t0=$(cat "$STATE/check-started")
desc=$(cat "$STATE/desc-pid")
gone_at=
for ((i = 0; i < 200; i++)); do
  if ! kill -0 "$desc" 2>/dev/null; then gone_at=$(date +%s); break; fi
  /bin/sleep 0.1
done
/bin/sleep 4
alive=no; kill -0 "$WPID" 2>/dev/null && alive=yes
last_check=no; [ -e "$STATE/.last-check" ] && last_check=yes
sleeps=$(awk -v p="$WPID" '$2==p' "$LOG")
wrc=running
if [ "$alive" = no ]; then wait "$WPID"; wrc=$?; else kill -TERM "$WPID" 2>/dev/null; for ((i = 0; i < 100; i++)); do kill -0 "$WPID" 2>/dev/null || break; /bin/sleep 0.1; done; fi
{
  echo "label=$LABEL tree=$TREE mode=$MODE perl=$PERLMODE FM_CHECK_TIMEOUT=$timeout"
  echo "check_descendant_pid=$desc killed_after=$([ -n "$gone_at" ] && echo "$((gone_at - t0))s" || echo NOT_KILLED)"
  echo "watcher_alive_4s_after_cleanup=$alive check_sweep_completed(.last-check)=$last_check"
  echo "watcher_exit_status_if_exited=$wrc"; echo "--- watcher stdout"; cat "$HOME_DIR/watch.out"; tail -3 "$STATE/.watch-cycle-exits.log" 2>/dev/null
  echo "watcher_main_shell_sleep_launches:"; printf '%s\n' "${sleeps:-  (none)}"
  echo "--- watcher stderr (filtered job-kill notices)"; grep -v 'Terminated: 15\|"\$@" 2> /dev/null\|^else$\|"\$@" 2>&1;\|^fi )\|eval "exec' "$HOME_DIR/watch.err" | tail -8
} | tee "$OUT/live-stop-$LABEL.txt"
kill -0 "$desc" 2>/dev/null && kill -KILL "$desc"
echo "leftover check temp/fifo files in state: $(ls -a "$STATE" | grep -c "fm-check-output\|\.wait$")" | tee -a "$OUT/live-stop-$LABEL.txt"
rm -rf "$HOME_DIR"
