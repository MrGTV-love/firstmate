#!/usr/bin/env bash
# run.sh <label> [draft]  - one live Escape-restore pass on real omp in the private tmux lab
set -u
S=/Users/charlesabrooker/tmp/fm-lab.Hp5879; H=$S/home; A=$S/agent; OMP=$(command -v omp); label=$1; draft=${2:-}; predrain=${3:-}
T() { TMUX_TMPDIR="$S/tmux" tmux -L fm-lab "$@"; }
q() { env -u FM_SUPERVISION_ACTOR -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME=$H $H/bin/fm-wake-drain.sh --queued; }
OUT=$S/$label; mkdir -p $OUT
rm -f $H/state/.wake-queue* $H/state/.lab-* $H/state/.wake-followup-* $H/state/.watcher-down $H/state/trigger-* $S/model.log $S/model.port
python3 -I $S/model.py $S/model.log $S/model.port $H > $S/model.out 2>&1 &
for i in $(seq 1 20); do [ -s $S/model.port ] && break; sleep 0.25; done
sed -i '' "s#baseUrl: http://127.0.0.1:[0-9]*/v1#baseUrl: http://127.0.0.1:$(cat $S/model.port)/v1#" $A/models.yml
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_HOME -u FM_SUPERVISION_ACTOR -u TMUX TMUX_TMPDIR="$S/tmux" tmux -L fm-lab new-session -d -s primary -x 200 -y 50 -c "$H" "bash -c 'printf \"%s\\n\" \$\$ > $H/state/.lock; exec env FM_HOME=$H PI_CODING_AGENT_DIR=$A $OMP --no-extensions -e $S/lab-queue-probe.ts -e $H/.omp/fm-lab-wrapper.ts --model lab/m1 2> $OUT/omp.stderr'"
for i in $(seq 1 60); do grep -q 'idle=1' $H/state/.lab-queue-probe 2>/dev/null && break; sleep 0.5; done
sleep 2
echo "## [$label] 1. idle lane: watcher close -> production idle wake captured by fixture (row stays owed)"
: > $H/state/.wake-followup-capture-request; : > $H/state/trigger-$label
for i in $(seq 1 40); do [ -s $H/state/.wake-followup-captured ] && break; sleep 0.25; done
cat $H/state/.wake-followup-captured; echo "queued rows:"; q
if [ -n "$predrain" ]; then
  echo "## [$label] 1b. lane drains and acknowledges every row (as a lane does inside a turn)"
  out=$(env -u FM_SUPERVISION_ACTOR -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME=$H $H/bin/fm-wake-drain.sh 2>&1); echo "$out"
  seq=$(echo "$out" | grep -o -- '--ack-through [0-9]*' | awk '{print $2}'); gen=$(echo "$out" | grep -o -- '--recovery-generation [^ ]*' | awk '{print $2}')
  env -u FM_SUPERVISION_ACTOR -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME=$H $H/bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen"; echo "ack rc=$?"; echo "queued rows after ack:"; q; echo "(end rows)"
fi
echo "## [$label] 2. busy turn (model calls bash sleep 40)"
T send-keys -t primary -l 'BUSYLAB please run the sleep'; sleep 1; T send-keys -t primary Enter
for i in $(seq 1 40); do grep -q 'idle=0' $H/state/.lab-queue-probe && break; sleep 0.25; done; sleep 3; cat $H/state/.lab-queue-probe
if [ -n "$draft" ]; then echo "## [$label] 2b. operator types a draft (not submitted): '$draft'"; T send-keys -t primary -l "$draft"; sleep 1; fi
echo "## [$label] 3. fixture queues the tracked wake text as a vendor follow-up during the busy turn"
: > $H/state/.wake-followup-queue-request
for i in $(seq 1 40); do [ -s $H/state/.wake-followup-queued ] && grep -q 'queued=1' $H/state/.lab-queue-probe && break; sleep 0.25; done; cat $H/state/.lab-queue-probe
T capture-pane -p -t primary > $OUT/pane-before-escape.txt
echo "## [$label] 4. operator presses Escape (interrupt)"; T send-keys -t primary Escape
sleep 15
T capture-pane -p -t primary > $OUT/pane-after.txt
echo "## [$label] 5. results"
echo "-- setEditorText calls (extension edits to the composer):"; cat $H/state/.lab-set-editor-log 2>/dev/null | cut -c1-400
echo "-- sendUserMessage calls by the extension:"; cat $H/state/.lab-send-log 2>/dev/null | cut -c1-300
echo "-- recovered:"; cat $H/state/.wake-followup-recovered 2>/dev/null
echo "-- probe now:"; cat $H/state/.lab-queue-probe
echo "-- composer now (editor log tail):"; tail -1 $H/state/.lab-editor-log 2>/dev/null
echo "-- queued rows now:"; q; echo "(end rows)"
echo "-- model requests:"; python3 -c '
import json,sys
for l in open(sys.argv[1]):
    e=json.loads(l)
    if "title-request" in e["last_user"]: continue
    print(round(e["t"]), "n=%s"%e["n"], e["roles"], "sys=%r"%e["sys"][:50], repr(e["last_user"][-110:]), e.get("tool_call",""), ("drain_rc=%s ack_rc=%s"%(e["drain"]["rc"], e["drain"].get("ack_rc"))) if "drain" in e else "")' $S/model.log
cp $H/state/.lab-* $H/state/.wake-followup-* $S/model.log $OUT/ 2>/dev/null
T kill-server; pkill -f "$S/model.py"; sleep 1
