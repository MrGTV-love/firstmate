#!/usr/bin/env bash
# real-omp-watcher-then-drain.sh <repo> <lab>
# 1) real fm-watch.sh (poll 2 s, grace 20 s, cap 8 MiB) 2) real omp runs the incident printf under a 128 MiB hard limit
# 3) after the watcher's over-cap wake: the real wake drain, 90 s timeout, as the supervisor would run it.
REPO=$1; LAB=$2; F=$LAB/state/incident.status; ST=$LAB/state
export FM_CONFIG_OVERRIDE="$LAB/config"
FM_HOME="$LAB" FM_STATE_OVERRIDE="$ST" FM_POLL=2 FM_SIGNAL_GRACE=20 FM_STATUS_CAP_BYTES=8388608 \
  FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$REPO/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
WPID=$!
w=0; while [ ! -e "$ST/.last-watcher-beat" ] && [ "$w" -lt 300 ]; do sleep 0.1; w=$((w+1)); done
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$REPO" -e FM_HOME="$LAB" "bash $LAB/launch.sh; sleep 300"
d=0; while kill -0 "$WPID" 2>/dev/null && [ "$d" -lt 1200 ]; do sleep 0.1; d=$((d+1)); done
echo "1) watcher wake after ~$((d/10)) s: $(sed "s#$LAB#<lab>#g" "$LAB/watch.out" | cut -c1-260)"
pid=$(sed -n 's/.*stopped pid \([0-9][0-9]*\) (omp).*/\1/p' "$LAB/watch.out" | head -1); echo "$pid" > "$LAB/writer.pid"
echo "   writer pid ${pid:-none} state: $(ps -o state= -p "${pid:-0}" 2>/dev/null | tr -d ' ')   log size: $(stat -f %z "$F")"
echo "   queued wake rows (kind key): $(awk -F'\t' '{print $3, $4}' "$ST/.wake-queue" 2>/dev/null | tr '\n' ';')"
echo "2) the real wake drain on that state dir (90 s timeout)"
s=$SECONDS
/usr/bin/time -l env FM_STATE_OVERRIDE="$ST" timeout 90 "$REPO/bin/fm-wake-drain.sh" > "$LAB/drain.out" 2> "$LAB/drain.err"
rc=$?
echo "   drain rc=$rc (124 = killed by the 90 s timeout) secs=$((SECONDS-s)) stdout_lines=$(wc -l < "$LAB/drain.out" | tr -d ' ') peak_rss_bytes=$(awk '/maximum resident/{print $1}' "$LAB/drain.err")"
echo "   first stdout lines:"; head -4 "$LAB/drain.out" | cut -c1-200 | sed "s#$LAB#<lab>#g"
echo "   refusal lines naming the log on stderr: $(grep -c 'fm-status: refused' "$LAB/drain.err")"
