#!/usr/bin/env bash
# usage: run.sh <src-dir> <label> <evidence-dir> <model-delay-s>
set -u
SRC=$1 LABEL=$2 EVD=$3/live-$2 DELAY=$4
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M78E48V6WPVZCB3M81FKRCM2
mkdir -p "$EVD"
eval "$("$WT/bin/fm-lab-home.sh" env 2>"$EVD/lab-env.txt")" || { echo "lab env failed"; exit 1; }
AUX=$(mktemp -d /tmp/fmlive-aux.XXXXXX); mkdir -p "$AUX/agent" "$AUX/home"
echo "label=$LABEL src=$SRC FM_HOME=$FM_HOME AUX=$AUX OMP_API_BILLING=${OMP_API_BILLING:-unset} omp=$(omp --version 2>/dev/null)" | tee "$EVD/run-info.txt"
[ -d "$SRC/.git" ] || [ -f "$SRC/.git" ] && echo "src head=$(git -C "$SRC" rev-parse HEAD)" >> "$EVD/run-info.txt"
shasum -a 256 "$SRC/.omp/extensions/fm-primary-omp-watch.ts" >> "$EVD/run-info.txt"
python3 -I /tmp/fmlive-scripts/model.py "$AUX/model.log" "$AUX/model.port" "$DELAY" & MODEL_PID=$!
for i in $(seq 40); do [ -s "$AUX/model.port" ] && break; sleep 0.25; done
cat > "$AUX/agent/config.yml" <<YML
setupVersion: 2
modelRoles:
  default: lab/m1
  tiny: lab/m1
  advisor: lab/m1
  vision: lab/m1
advisor:
  enabled: false
YML
cat > "$AUX/agent/models.yml" <<YML
providers:
  lab:
    baseUrl: http://127.0.0.1:$(cat "$AUX/model.port")/v1
    apiKey: lab-key
    api: openai-completions
    models:
      - id: m1
        contextWindow: 200000
        maxTokens: 4096
YML
cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null
  kill "$MODEL_PID" 2>/dev/null
  for p in $(ps -axo pid=,command= | awk -v a="$FM_HOME" -v b="$AUX" 'index($0,a)||index($0,b){print $1}'); do kill -TERM "$p" 2>/dev/null; done
  sleep 1
  for p in $(ps -axo pid=,command= | awk -v a="$FM_HOME" -v b="$AUX" 'index($0,a)||index($0,b){print $1}'); do kill -KILL "$p" 2>/dev/null; done
  cp "$AUX/model.log" "$EVD/model.log" 2>/dev/null
  "$WT/bin/fm-lab-home.sh" teardown "$FM_HOME" && rm -rf "$FM_HOME" "$AUX"
  echo "teardown done rc=$?"
}
trap cleanup EXIT
[ "${QUIET_MEM:-0}" = 1 ] && printf "9999999999\n" > "$FM_HOME/state/.memory-health-next" && echo "memory-health check deferred in lab" >> "$EVD/run-info.txt"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u OMP_PROFILE -u PI_PROFILE \
  tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$SRC" -e FM_HOME="$FM_HOME" \
  "bash -c 'printf \"%s\\n\" \$\$ > $FM_HOME/state/.lock; exec env HOME=$AUX/home PI_CODING_AGENT_DIR=$AUX/agent FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 /Users/charlesabrooker/.bun/bin/omp --config $SRC/.omp/fm-session-overlay.yml --auto-approve --model lab/m1 2>$AUX/omp.err'"
for i in $(seq 120); do [ -s "$FM_HOME/state/.watch.lock/pid" ] && break; sleep 0.5; done
LOG=$FM_HOME/state/extensions/omp-primary-watch/lifecycle.log
LEDGER=$FM_HOME/state/.watch-cycle-exits.log
if [ ! -s "$FM_HOME/state/.watch.lock/pid" ]; then
  echo "NO INITIAL WATCHER"; tmux -L fm-lab capture-pane -p -t primary > "$EVD/pane-noarm.txt"; cp "$LOG" "$EVD/" 2>/dev/null; cp "$AUX/omp.err" "$EVD/" 2>/dev/null; exit 1
fi
echo "initial watcher pid=$(cat "$FM_HOME/state/.watch.lock/pid")" | tee -a "$EVD/run-info.txt"
sleep 3
for n in 1 2 3 4; do
  : > "$FM_HOME/state/t$n.meta"
  printf 'done: live lab close %s\n' "$n" > "$FM_HOME/state/t$n.status"
  echo "$(date +%s.%N 2>/dev/null || date +%s) trigger t$n" >> "$EVD/triggers.txt"
  # wait until this close is in the ledger before triggering the next one
  for i in $(seq 40); do grep -q "reason=actionable-signal" "$LEDGER" 2>/dev/null && [ "$(grep -c 'reason=actionable' "$LEDGER")" -ge "$n" ] && break; sleep 0.25; done
  sleep 2
done
date -u +%FT%TZ > "$EVD/ledger-before-settle.txt"; cat "$LEDGER" >> "$EVD/ledger-before-settle.txt" 2>/dev/null
# allow successors / restoration to settle while the slow model turns still run
sleep ${FINAL_WAIT:-15}
tmux -L fm-lab capture-pane -p -t primary > "$EVD/pane.txt"
cp "$LEDGER" "$EVD/watch-cycle-exits.log" 2>/dev/null
cp "$LOG" "$EVD/lifecycle.log" 2>/dev/null; cp "$FM_HOME/state/.lab-send-log" "$EVD/lab-send-log.txt" 2>/dev/null
echo "--- ledger (reason / successor)"; awk -F'\t' '{print $1, $8, $12}' "$LEDGER" | tee "$EVD/ledger-summary.txt"
echo "--- lifecycle events"; grep -oE 'event=[a-z-]+|"event":"[a-z-]+"' "$LOG" | sort | uniq -c
