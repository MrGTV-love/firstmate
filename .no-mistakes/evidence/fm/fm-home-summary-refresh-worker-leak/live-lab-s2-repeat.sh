#!/usr/bin/env bash
# Repeat live S2 (worker waits on a live fence holder) N times on a fresh lab home each time,
# with ps snapshots (not pgrep) and the refresh log, to judge whether a failure is product or setup.
set -u
WT=$1; N=${2:-5}
cd "$WT" || exit 2
RC=0
for n in $(seq 1 "$N"); do
  eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; LAB=$FM_HOME
  mkdir -p "$LAB/code-root"; ln -s "$WT/bin" "$LAB/code-root/bin"
  REF="$LAB/code-root/bin/fm-home-summary-refresh.sh"
  pss() { ps -axo pid=,ppid=,stat=,etime=,command= | grep -F -- "$LAB/code-root/bin/fm-home-summary-refresh.sh" | grep -v grep; }
  echo "=== iteration $n lab $LAB"
# Keep the lab owned while the scenario runs: a live private tmux server is the
# runtime evidence bin/fm-test-reap-orphans.sh honors, so concurrent test runs on
# this host do not reap this lab's detached refresh as an orphan.
tmux -L fm-lab new-session -d -s keep "sleep 3600" && echo "lab tmux server up on $TMUX_TMPDIR"
  # fresh home: publish once first, as S1 did
  FM_HOME=$LAB "$REF" --detach; i=0; while [ ! -s "$LAB/state/home-summary.json" ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
  i=0; while [ -n "$(pss)" ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
  rm -f "$LAB/state/home-summary.json"
  st=$LAB/state
  nohup bash -c '. "$1"; st=${2%/*}; : > "$st/.armed"
    while :; do for f in "$st"/.home-summary.json.?*; do [ -e "$f" ] && break 2; done; done
    fm_lock_acquire_wait "$2"; [ -e "$st/home-summary.json" ] && echo late > "$st/.late"; echo $$ > "$3"
    while [ ! -e "$4" ] && [ -d "$5" ]; do sleep 0.2; done; fm_lock_release "$2"' \
    _ "$WT/bin/fm-wake-lib.sh" "$st/.home-summary-refresh.lock.steal" "$st/.holder" "$st/.release" "$st" >/dev/null 2>&1 </dev/null &
  HJ=$!
  i=0; while [ ! -e "$st/.armed" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  FM_HOME=$LAB "$REF" --detach
  i=0; while [ ! -s "$st/.holder" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done
  echo "holder=$(cat "$st/.holder" 2>/dev/null) late=$(cat "$st/.late" 2>/dev/null)"
  for t in 1 4 8; do sleep $(( t==1 ? 1 : (t==4 ? 3 : 4) )); echo "-- t=${t}s procs:"; pss; done
  ok=1
  [ -n "$(pss)" ] || { ok=0; echo "NO WORKER WAITING"; ls -A "$st"; cat "$st/.home-summary-refresh.log" 2>/dev/null; }
  : > "$st/.release"
  i=0; while [ ! -s "$st/home-summary.json" ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
  [ -s "$st/home-summary.json" ] && echo "published ${i}s after release" || { ok=0; echo "NOT PUBLISHED"; ls -A "$st"; cat "$st/.home-summary-refresh.log" 2>/dev/null; }
  i=0; while [ -n "$(pss)" ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
  [ -z "$(pss)" ] || { ok=0; echo "LEFT RUNNING:"; pss; }
  kill -KILL "$HJ" 2>/dev/null
  for p in $(pss | awk '{print $1}'); do kill -KILL "$p" 2>/dev/null; done
  [ "$ok" = 1 ] && echo "ITER $n PASS" || { echo "ITER $n FAIL"; RC=1; }
  tmux -L fm-lab kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB" && echo "lab $LAB removed"
done
echo "OVERALL RC=$RC"; exit $RC
