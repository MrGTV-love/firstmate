#!/usr/bin/env bash
# real-omp-guard.sh <repo> <lab>
# Launch the real omp on the lab's private tmux socket with the incident command, wait until the
# status log passes 1 MiB, then run the real guard scan and record what it did.
REPO=$1; LAB=$2; F=$LAB/state/incident.status
: > "$F"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$REPO" -e FM_HOME="$LAB" "bash $LAB/launch.sh; sleep 300"
w=0
while [ "$(stat -f %z "$F")" -le 1048576 ] && [ "$w" -lt 1200 ]; do sleep 0.1; w=$((w+1)); done
echo "waited ${w}x0.1s; size at detection: $(stat -f %z "$F")"
echo "--- who holds it, by lsof"; lsof -nP -F pcfa -- "$F" 2>&1 | tr '\n' ' '; echo
echo "--- running scan (cap 1 MiB)"
FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_STATUS_CAP_BYTES=1048576 "$REPO/bin/fm-status-cap-guard.sh" scan > "$LAB/scan.out" 2>&1; echo "scan rc=$?"
cut -f1,3,4 "$LAB/scan.out" | sed "s#$LAB#<lab>#g"
pid=$(sed -n 's/.*stopped pid \([0-9][0-9]*\) (omp).*/\1/p' "$LAB/scan.out" | head -1)
echo "--- stopped pid: ${pid:-none}"
if [ -n "$pid" ]; then
  echo "process state after guard (T = stopped):"; ps -o pid,ppid,state,comm -p "$pid"
  s1=$(stat -f %z "$F"); sleep 3; s2=$(stat -f %z "$F"); echo "size before/after 3 s wait: $s1 / $s2"
  echo "--- resuming it with kill -CONT, as the wake text says, and checking it is a live omp"
  kill -CONT "$pid"; sleep 1; ps -o pid,state,comm -p "$pid"
fi
echo "--- file still exists: $(ls -l "$F" | awk '{print $5}') bytes; line count $(wc -l < "$F")"
