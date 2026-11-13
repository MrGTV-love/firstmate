#!/usr/bin/env bash
# Live drive: real arm + watcher in a lab home. A take-over arrives while the watcher is inside
# prelude step 10 (a blocking check), then an idle take-over. Usage: takeover.sh <tree-root> <label>
set -u
R=$1; L=$2
cd "$R"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fmlive-drv/lab-to-$L.err)"
export FM_OPEN_LOOPS_BIN=/usr/bin/true FM_HOME FM_POLL=1 FM_HEARTBEAT=999999 FM_MEMORY_GUARD_BIN=$(command -v true)
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
export KLOG=$FM_HOME/kill.log; : > "$KLOG"
kill() { case "${1:-}" in -l|-L) o=$(builtin kill "$@") || return $?; printf '%s\n' "${o#SIG}"; return 0;; esac
  printf '%s %s kill %s\n' "$(date +%T)" "${BASHPID:-$$}" "$*" >> "$KLOG"; builtin kill "$@"; }
export -f kill
S=$FM_HOME/state
echo "== tree: $L ($(cat .sha 2>/dev/null || git rev-parse --short HEAD))  lab FM_HOME=$FM_HOME"
cat > "$S/c1.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'c1 start %s\n' "$(date +%T)" >> "$FM_HOME/runs.log"
if [ -e "$FM_HOME/block" ]; then : > "$FM_HOME/inflight"; while [ -e "$FM_HOME/block" ]; do sleep 0.1; done; rm -f "$FM_HOME/inflight"; fi
printf 'c1 end %s\n' "$(date +%T)" >> "$FM_HOME/runs.log"
SH
chmod 700 "$S/c1.check.sh"; printf 'fm-custom-check-v1\n%s\n' "$(shasum -a 256 "$S/c1.check.sh" | awk '{print $1}')" > "$S/c1.check-trust"; chmod 600 "$S/c1.check-trust"
: > "$FM_HOME/block"
tok() { printf 'token=%s seq=%s' "$(cat "$S/.watcher-down" 2>/dev/null | tr '\n' ' ' | head -c 80)" "$(cat "$S/.wake-queue.seq" 2>/dev/null)"; }
bin/fm-watch-arm.sh > "$FM_HOME/arm1.out" 2>&1 & A1=$!
for i in $(seq 1 300); do [ -e "$FM_HOME/inflight" ] && break; sleep 0.1; done
W=$(cat "$S/.watch.lock/pid" 2>/dev/null)
echo "== arm1 pid=$A1 started watcher pid=$W; watcher is inside check c1 (step 10): $([ -e "$FM_HOME/inflight" ] && echo yes || echo NO)"
echo "   prelude-inflight marker: $(tr '\t' ' ' < "$S/.prelude-inflight" 2>/dev/null || echo none)   $(tok)"
echo "== BUSY TAKE-OVER: arm2 --take-over $A1 at $(date +%T)"
bin/fm-watch-arm.sh --take-over "$A1" > "$FM_HOME/arm2.out" 2>&1 & A2=$!
sleep 9
echo "   after 9 s: arm2 says: $(cat "$FM_HOME/arm2.out" | tr '\n' '|')"
echo "   watcher $W alive: $(builtin kill -0 "$W" 2>/dev/null && echo yes || echo no); still in check: $([ -e "$FM_HOME/inflight" ] && echo yes || echo no)"
echo "   signals (not -0) sent to watcher $W so far: $(grep " kill " "$KLOG" | grep -v ' -0 ' | grep -c -- " $W\$")"
rm -f "$FM_HOME/block"; echo "== check c1 unblocked at $(date +%T)"
sleep 4
echo "   watcher $W alive after its step ended: $(builtin kill -0 "$W" 2>/dev/null && echo yes || echo no); lock holder: $(cat "$S/.watch.lock/pid" 2>/dev/null)  $(tok)"
echo "   arm1 alive: $(builtin kill -0 $A1 2>/dev/null && echo yes || echo no)  arm2 alive: $(builtin kill -0 $A2 2>/dev/null && echo yes || echo no)"
# Supervision keeps a watcher running: if none, a plain arm starts one.
if ! builtin kill -0 "$(cat "$S/.watch.lock/pid" 2>/dev/null)" 2>/dev/null; then
  echo "== no live watcher; plain arm3 re-arms (as the host would)"; bin/fm-watch-arm.sh > "$FM_HOME/arm3.out" 2>&1 & A3=$!; sleep 8
  echo "   arm3 says: $(cat "$FM_HOME/arm3.out" | tr '\n' '|')"
fi
W2=$(cat "$S/.watch.lock/pid" 2>/dev/null); OWNER=$(ps -o ppid= -p "$W2" | tr -d ' ')
echo "== IDLE TAKE-OVER: watcher $W2 (parent arm $OWNER) idle in its poll; $(tok); prelude marker: $(cat "$S/.prelude-inflight" 2>/dev/null || echo none)"
bin/fm-watch-arm.sh --take-over "$OWNER" > "$FM_HOME/arm4.out" 2>&1 & A4=$!
sleep 10
echo "   arm4 says: $(cat "$FM_HOME/arm4.out" | tr '\n' '|')"
echo "   TERM sent to $W2: $(grep -c -- "-TERM $W2\$" "$KLOG"); old watcher alive: $(builtin kill -0 "$W2" 2>/dev/null && echo yes || echo no); new lock holder: $(cat "$S/.watch.lock/pid" 2>/dev/null)  $(tok)"
echo "== all arm outputs:"; for f in "$FM_HOME"/arm*.out; do echo "-- ${f##*/}: $(tr '\n' '|' < "$f")"; done
echo "== empty 'check: rearm-resurface' wakes printed by any arm: $(cat "$FM_HOME"/arm*.out | grep -c 'rearm-resurface')"
echo "== kill log (signals other than -0):"; grep -v ' -0 ' "$KLOG" || true
echo "== cycle ledger:"; cut -f1-12 "$S/.watch-cycle-exits.log" 2>/dev/null | tail -8
echo "== runs:"; cat "$FM_HOME/runs.log"
bin/fm-watch-arm.sh --stop > /dev/null 2>&1 || true
for p in $A1 $A2 ${A3:-} $A4; do builtin kill -TERM $p 2>/dev/null; done; sleep 1
for p in $(cat "$S/.watch.lock/pid" 2>/dev/null); do builtin kill -TERM "$p" 2>/dev/null; done; sleep 1
tl=$(grep "teardown:" /tmp/fmlive-drv/lab-to-$L.err | sed "s/^fm-lab-home: teardown: //"); eval "$tl" && echo "== lab torn down"
