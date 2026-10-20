#!/usr/bin/env bash
# real-omp-watcher-drain.sh <repo> <poll-secs> <cap-bytes|default> <ceiling-bytes> <tag>
# Live scenario: the REAL omp shell (`omp shell`, the harness shell that produced the 2026-10-18
# incident) in a private tmux pane runs the incident command; the REAL fm-watch.sh in a marked
# lab home finds the over-cap status log and stops that one omp pid; then the REAL wake drain
# runs on the same state with a queued signal row.
# Safety: a babysitter SIGKILLs the omp writer if the log passes <ceiling-bytes>; the lab is
# a mktemp dir outside the repo and is removed at the end.
set -u
R=$1; POLL=$2; CAP=$3; CEIL=$4; TAG=$5
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
: > "$LAB/config/supervision-host-off"
S="$LAB/state/incident.status"
export TMUX_TMPDIR; TMUX_TMPDIR=$("$R/bin/fm-lab-home.sh" tmux-dir "$LAB")
TM() { tmux -L fm-lab "$@"; }
cleanup() {
  kill -CONT "${OMP:-0}" 2>/dev/null; kill -9 "${OMP:-0}" 2>/dev/null
  kill "${WP:-0}" 2>/dev/null; kill "${BP:-0}" 2>/dev/null
  TM kill-server 2>/dev/null
  "$R/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT
echo "[$TAG] repo head=$(git -C "$R" rev-parse --short HEAD) poll=${POLL}s cap=$CAP ceiling=$CEIL omp=$(omp --version 2>&1 | head -1)"
capenv=()
[ "$CAP" = default ] || capenv=(FM_STATUS_CAP_BYTES="$CAP")
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_POLL="$POLL" ${capenv[@]+"${capenv[@]}"} \
  FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$R/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
WP=$!
w=0; while [ ! -e "$LAB/state/.last-watcher-beat" ] && [ "$w" -lt 300 ]; do sleep 0.2; w=$((w+1)); done
kill -0 "$WP" 2>/dev/null || { echo "watcher did not start: $(cat "$LAB/watch.err")"; exit 1; }
: > "$S"
TM new-session -d -s primary -x 200 -y 50 -c "$LAB/state" "bash --norc --noprofile -i"
PANE=$(TM display -p -t primary '#{pane_pid}')
TM send-keys -t primary "omp shell -C $LAB/state" Enter
OMP=
w=0; while [ -z "$OMP" ] && [ "$w" -lt 100 ]; do
  OMP=$(ps -axo pid=,ppid=,comm= | awk -v p="$PANE" '$2==p && $3 ~ /(^|\/)omp$/ {print $1; exit}')
  [ -n "$OMP" ] || { sleep 0.3; w=$((w+1)); }
done
[ -n "$OMP" ] || { echo "omp shell never started under pane $PANE"; TM capture-pane -p -t primary | tail -5; exit 1; }
sleep 3
echo "[$TAG] pane shell pid=$PANE  omp pid=$OMP  omp comm=$(ps -p "$OMP" -o comm= | sed 's#.*/##')  omp ppid=$(ps -p "$OMP" -o ppid= | tr -d ' ')"
echo "[$TAG] watcher pid=$WP"
# babysitter
( while kill -0 "$OMP" 2>/dev/null; do
    sz=$(stat -f %z "$S" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$CEIL" ]; then kill -CONT "$OMP" 2>/dev/null; kill -9 "$OMP" 2>/dev/null; echo "BABYSITTER-FIRED size=$sz" > "$LAB/babysitter.fired"; exit; fi
    sleep 0.2
  done ) &
BP=$!
CMD="printf 'text\\n' \"\$(date +%s)\" >> $S"
T0=$(now)
TM send-keys -t primary "$CMD" Enter
echo "[$TAG] command typed into the omp shell: $CMD"
w=0; while kill -0 "$WP" 2>/dev/null && [ "$w" -lt 1200 ]; do sleep 0.25; w=$((w+1)); done
T1=$(now)
alive=no; kill -0 "$WP" 2>/dev/null && alive=yes
st1=$(ps -p "$OMP" -o state= 2>/dev/null | tr -d ' ' | cut -c1)
sz1=$(stat -f %z "$S"); sleep 3
sz2=$(stat -f %z "$S"); st2=$(ps -p "$OMP" -o state= 2>/dev/null | tr -d ' ' | cut -c1)
echo "[$TAG] watcher_still_running=$alive; watcher exited $(perl -e "printf '%.1f', $T1-$T0") s after the command was sent"
echo "[$TAG] omp state at exit=${st1:-gone} (T = stopped), 3 s later=${st2:-gone}; log size at exit=$sz1; 3 s later=$sz2; growth after stop=$((sz2-sz1)) bytes"
[ -e "$LAB/babysitter.fired" ] && echo "[$TAG] $(cat "$LAB/babysitter.fired")  <-- the safety net, not the product, ended the writer"
echo "[$TAG] ratio size/cap: $(perl -e "printf '%.1f', $sz2/($( [ "$CAP" = default ] && echo 33554432 || echo "$CAP"))")  size in GB: $(perl -e "printf '%.2f', $sz2/1e9")"
echo "[$TAG] wake text printed by the watcher:"; sed "s#$LAB#<lab>#g" "$LAB/watch.out" | cut -c1-500
echo "[$TAG] queued rows (time seq kind key text):"; sed "s#$LAB#<lab>#g" "$LAB/state/.wake-queue" 2>/dev/null | cut -c1-260
echo "[$TAG] watcher stderr: $(head -c 300 "$LAB/watch.err")"
echo "[$TAG] over-cap marker: $(cat "$LAB"/state/.status-cap-alerted.* 2>/dev/null | sed "s#$LAB#<lab>#g")"
echo "[$TAG] log still on disk: $(stat -f 'size=%z inode=%i' "$S")"
# real drain on the same state, with the queued signal row for the over-limit log
echo "[$TAG] real wake drain (timeout 90 s):"
d0=$(now)
( cd "$R" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" perl -e 'alarm 90; exec @ARGV' bin/fm-wake-drain.sh > "$LAB/drain.out" 2> "$LAB/drain.err" ); drc=$?
d1=$(now)
echo "[$TAG] drain rc=$drc secs=$(perl -e "printf '%.1f', $d1-$d0") stdout_lines=$(wc -l < "$LAB/drain.out" | tr -d ' ') annotation_lines=$(grep -c 'wake annotation' "$LAB/drain.out")"
echo "[$TAG] drain stdout mentions of incident.status:"; grep -n 'incident.status' "$LAB/drain.out" | sed "s#$LAB#<lab>#g" | cut -c1-300 | head -8
echo "[$TAG] drain stderr:"; sed "s#$LAB#<lab>#g" "$LAB/drain.err" | cut -c1-420 | head -8
echo "[$TAG] log after the drain: $(stat -f 'size=%z inode=%i' "$S")  (unchanged = nothing deleted, truncated or rewritten)"
