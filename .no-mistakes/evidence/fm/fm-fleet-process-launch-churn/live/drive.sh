#!/usr/bin/env bash
# drive.sh <bin-root> <scenario> <label> <outdir> [noperl]
# Runs the REAL bin/fm-watch.sh as a full watcher in a disposable lab home.
set -u
ROOT=$1 SCEN=$2 LABEL=$3 OUT=$4 NOPERL=${5:-}
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5N3HGEA455JY77H4E2GBPD4
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 9; }
STATE="$LAB/state"
SHIM="$LAB/shim"; mkdir -p "$SHIM"
LOG="$LAB/launch.log"; : > "$LOG"
for tool in sleep dirname perl; do
  real=$(command -v "$tool")
  cat > "$SHIM/$tool" <<SH
#!/bin/bash
printf '%s %s %s %s\n' "\$(/bin/date +%s)" "$tool" "\$PPID" "\$*" >> "$LOG"
exec $real "\$@"
SH
  chmod +x "$SHIM/$tool"
done
# Fake tmux so nothing ever reaches a real tmux server.
printf '#!/bin/bash\nexit 1\n' > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
PATHDIRS="$SHIM:$PATH"
if [ "$NOPERL" = noperl ]; then
  rm -f "$SHIM/perl"
  NP="$LAB/noperl"; mkdir -p "$NP"
  IFS=: read -r -a dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b=${f##*/}
      case "$b" in perl*|sleep|dirname|tmux) continue ;; esac
      [ -x "$f" ] && [ ! -e "$NP/$b" ] && ln -s "$f" "$NP/$b"
    done
  done
  PATHDIRS="$SHIM:$NP"
  PATH="$PATHDIRS" command -v perl >/dev/null 2>&1 && { echo "perl still visible"; exit 9; }
fi
TIMEOUT=60
case "$SCEN" in
  slow)
    cat > "$STATE/live.check.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$$" > "$FM_HOME/state/check-started"
/bin/sleep 12
printf 'live-slow-check-output\n'
touch "$FM_HOME/state/check-finished"
exit 0
SH
    ;;
  deadline)
    TIMEOUT=3
    cat > "$STATE/live.check.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$$" > "$FM_HOME/state/check-started"
trap '' TERM
kill -STOP $$
printf must-not-complete
SH
    ;;
  descendant)
    cat > "$STATE/live.check.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$$" > "$FM_HOME/state/check-started"
(trap '' TERM; exec /bin/sleep 120) &
printf '%s\n' "$!" > "$FM_HOME/state/descendant-pid"
printf 'leader-finished\n'
touch "$FM_HOME/state/check-finished"
SH
    ;;
esac
chmod 0700 "$STATE/live.check.sh"
FM_HOME="$LAB" bash "$ROOT/bin/fm-check-register.sh" live >/dev/null || { echo "register failed"; exit 9; }
START=$(/bin/date +%s)
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE \
  PATH="$PATHDIRS" FM_HOME="$LAB" FM_POLL=1 FM_GUARD_GRACE=6 FM_CHECK_TIMEOUT=$TIMEOUT FM_HEARTBEAT=999999 \
  /bin/bash "$ROOT/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
WPID=$!
for i in $(seq 1 300); do [ -s "$STATE/check-started" ] && break; /bin/sleep 0.1; done
CSTART=$(/bin/date +%s)
echo "label=$LABEL scenario=$SCEN watcher_pid=$WPID noperl=${NOPERL:-no}"
if [ ! -s "$STATE/check-started" ]; then echo "RESULT check never started"; cat "$LAB/watch.err" | tail -20; fi
STARTUP_DIRNAME=$(awk -v w="$WPID" '$2=="dirname"' "$LOG" | wc -l | tr -d ' ')
echo "startup_dirname_launches_before_check=$STARTUP_DIRNAME"
maxage=0
case "$SCEN" in
  slow)
    for s in $(seq 1 10); do
      /bin/sleep 1
      m=$(/usr/bin/stat -f %m "$STATE/.last-watcher-beat" 2>/dev/null || echo 0)
      age=$(( $(/bin/date +%s) - m ))
      [ "$age" -gt "$maxage" ] && maxage=$age
    done
    echo "max_beat_age_during_check_s=$maxage (grace 6)"
    for i in $(seq 1 100); do [ -e "$STATE/check-finished" ] && break; /bin/sleep 0.2; done
    /bin/sleep 3
    ;;
  deadline)
    for i in $(seq 1 150); do
      cp=$(cat "$STATE/check-started" 2>/dev/null)
      kill -0 "$cp" 2>/dev/null || break; /bin/sleep 0.1
    done
    END=$(/bin/date +%s)
    cp=$(cat "$STATE/check-started")
    if kill -0 "$cp" 2>/dev/null; then echo "stopped_check_pid=$cp STILL ALIVE"; else echo "stopped_check_pid=$cp gone after $((END - CSTART))s (timeout $TIMEOUT)"; fi
    /bin/sleep 2
    ;;
  descendant)
    for i in $(seq 1 50); do [ -e "$STATE/check-finished" ] && break; /bin/sleep 0.1; done
    /bin/sleep 4
    dp=$(cat "$STATE/descendant-pid")
    if kill -0 "$dp" 2>/dev/null; then echo "TERM-ignoring descendant $dp STILL ALIVE"; else echo "TERM-ignoring descendant $dp removed"; fi
    ;;
esac
CEND=$(/bin/date +%s)
if kill -0 "$WPID" 2>/dev/null; then echo "watcher_alive_after_check=yes"; else wait "$WPID"; echo "watcher_exited_after_check status=$?"; fi
echo "watch.out: $(tr '\n' '|' < "$LAB/watch.out" | cut -c1-300)"
echo "watcher_child_sleep_launches_during_check_window=$(awk -v w="$WPID" -v a="$CSTART" -v b="$CEND" '$2=="sleep" && $3==w && $1>=a && $1<=b' "$LOG" | wc -l | tr -d ' ') window_s=$((CEND - CSTART))"
echo "watcher_child_perl_launches_during_check_window=$(awk -v w="$WPID" -v a="$CSTART" -v b="$CEND" '$2=="perl" && $3==w && $1>=a && $1<=b' "$LOG" | wc -l | tr -d ' ')"
echo "sleep_args_from_watcher_in_window: $(awk -v w="$WPID" -v a="$CSTART" -v b="$CEND" '$2=="sleep" && $3==w && $1>=a && $1<=b {print $4}' "$LOG" | sort | uniq -c | tr '\n' ';')"
grep -rl "live-slow-check-output\|leader-finished" "$STATE" 2>/dev/null | grep -v live.check.sh | sed "s|$LAB|<lab>|" | head -3 | sed 's/^/check_output_delivered_in: /'
kill -TERM "$WPID" 2>/dev/null
for i in $(seq 1 100); do kill -0 "$WPID" 2>/dev/null || break; /bin/sleep 0.1; done
kill -0 "$WPID" 2>/dev/null && { echo "watcher survived TERM"; kill -KILL "$WPID"; } || echo "watcher stopped on TERM"
grep -E "unexpected EOF|syntax error|command not found" "$LAB/watch.err" | head -5 | sed 's/^/watch.err: /'
LEFT=$(ps -axo pid=,command= | grep -F "$LAB" | grep -v grep | wc -l | tr -d ' ')
echo "leftover_processes_referencing_lab=$LEFT"
cp "$LOG" "$OUT/$LABEL-$SCEN${NOPERL:+-noperl}-launch.log"
cp "$LAB/watch.out" "$OUT/$LABEL-$SCEN${NOPERL:+-noperl}-watch.out"
tail -30 "$LAB/watch.err" > "$OUT/$LABEL-$SCEN${NOPERL:+-noperl}-watch.err"
rm -rf "$LAB"
