#!/usr/bin/env bash
# Live drive: fresh lab home, one arm + watcher, idle take-over, watch the taking arm's output.
set -u
R=$1; L=$2; cd "$R"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fmlive-drv/lab-idle-$L.err)"
export FM_OPEN_LOOPS_BIN=/usr/bin/true FM_HOME FM_POLL=6 FM_HEARTBEAT=999999 FM_MEMORY_GUARD_BIN=$(command -v true)
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
S=$FM_HOME/state
echo "== tree: $L  lab=$FM_HOME"
bin/fm-watch-arm.sh > "$FM_HOME/arm1.out" 2>&1 & A1=$!
sleep 9; W=$(cat "$S/.watch.lock/pid")
echo "token before take-over: '$(cat "$S/.watcher-down" 2>/dev/null)' prelude marker: '$(cat "$S/.prelude-inflight" 2>/dev/null)'"
bin/fm-watch-arm.sh --take-over "$A1" > "$FM_HOME/arm2.out" 2>&1 & A2=$!
sleep 12
echo "arm1: $(tr '\n' '|' < "$FM_HOME/arm1.out")"
echo "arm2: $(tr '\n' '|' < "$FM_HOME/arm2.out")"
echo "token after: '$(cat "$S/.watcher-down" 2>/dev/null)'"
bin/fm-watch-arm.sh --stop >/dev/null 2>&1; builtin kill $A1 $A2 2>/dev/null; sleep 1
tl=$(grep "teardown:" /tmp/fmlive-drv/lab-idle-$L.err | sed "s/^fm-lab-home: teardown: //"); eval "$tl" && echo "== lab torn down"
