#!/usr/bin/env bash
# Live drive: a real fm-watch.sh in a lab home, five checks, SIGKILL while check 3 runs,
# then a fresh watcher. Usage: sweep-cut.sh <tree-root> <label>
set -u
R=$1; L=$2
cd "$R"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fmlive-drv/lab-$L.err)"
echo "== tree: $L ($(cd "$R" && git rev-parse --short HEAD 2>/dev/null || cat "$R/.sha"))"
echo "== lab FM_HOME=$FM_HOME"
S=$FM_HOME/state
: > "$FM_HOME/runs.log"
for id in c1 c2 c3 c4 c5; do
cat > "$S/$id.check.sh" <<SH
#!/usr/bin/env bash
printf '%s start %s\n' "$id" "\$(date +%T)" >> "\$FM_HOME/runs.log"
if [ "$id" = c3 ] && [ -e "\$FM_HOME/block-c3" ]; then : > "\$FM_HOME/inflight-c3"; while [ -e "\$FM_HOME/block-c3" ]; do sleep 0.1; done; fi
sleep 1
[ "$id" != c1 ] || echo "owner-dm-from-$id"
printf '%s end %s\n' "$id" "\$(date +%T)" >> "\$FM_HOME/runs.log"
SH
chmod 700 "$S/$id.check.sh"
printf 'fm-custom-check-v1\n%s\n' "$(shasum -a 256 "$S/$id.check.sh" | awk '{print $1}')" > "$S/$id.check-trust"; chmod 600 "$S/$id.check-trust"
done
: > "$FM_HOME/block-c3"
start() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$FM_HOME" FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch.sh > "$FM_HOME/watch.$1.out" 2> "$FM_HOME/watch.$1.err" & W=$!; }
start 1
for i in $(seq 1 300); do [ -e "$FM_HOME/inflight-c3" ] && break; sleep 0.1; done
echo "== watcher 1 pid=$W reached check 3: $([ -e "$FM_HOME/inflight-c3" ] && echo yes || echo NO)"
echo "-- state files at the cut:"; ls -a "$S" | grep -E 'sweep|last-check|wake-queue$' | tr '\n' ' '; echo
kill -KILL "$W"; wait "$W" 2>/dev/null
echo "== SIGKILL sent to watcher 1 (pid $W) inside check 3"
rm -f "$FM_HOME/block-c3"
n=2
# Supervision restarts a watcher after each wake; do the same until the sweep closes.
while [ $n -le 12 ]; do
  start $n
  for i in $(seq 1 200); do kill -0 "$W" 2>/dev/null || break; [ -e "$S/.last-check" ] && [ ! -e "$S/.sweep-open" ] && [ ! -e "$S/.sweep-closing" ] && break; sleep 0.1; done
  if kill -0 "$W" 2>/dev/null; then sleep 3; fi
  if kill -0 "$W" 2>/dev/null; then kill -TERM "$W"; wait "$W" 2>/dev/null; echo "== watcher $n (pid $W) idle after the close; stopped"; break; fi
  wait "$W" 2>/dev/null; echo "== watcher $n (pid $W) exited with wake: $(head -c 160 "$FM_HOME/watch.$n.out")"
  n=$((n+1))
done
echo "-- runs.log (each check start/end):"; cat "$FM_HOME/runs.log"
for id in c1 c2 c3 c4 c5; do printf '%s runs=%s  ' $id "$(grep -c "^$id start" "$FM_HOME/runs.log")"; done; echo
for f in "$FM_HOME"/watch.*.out; do echo "-- ${f##*/}:"; cat "$f"; done
echo "-- times the c1 wake was printed across both watchers: $(cat "$FM_HOME"/watch.*.out | grep -c owner-dm-from-c1)"
echo "-- .wake-queue rows with the c1 output: $(grep -c owner-dm-from-c1 "$S/.wake-queue" 2>/dev/null || echo 0)"
echo "-- state after: $(ls -a "$S" | grep -E 'sweep|last-check' | tr '\n' ' ')"
tl=$(grep "teardown:" /tmp/fmlive-drv/lab-$L.err | sed "s/^fm-lab-home: teardown: //"); eval "$tl" && echo "== lab torn down"
