#!/usr/bin/env bash
# Live drive: wake drain ack refusal, per-row command, completion, inside a marked lab home.
set -u
cd "$1"; EV=$2
eval "$(bin/fm-lab-home.sh env 2>/tmp/nm-t2/ol.teardown)"
san() { sed -e "s#$FM_HOME#\$LAB#g" -e "s#$PWD#\$WT#g"; }
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_SUPERVISION_ACTOR=main FM_DURATION_FILE=off
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
python3 - "$FM_HOME" <<'PY'
import json,sys,time
home=sys.argv[1]; now=int(time.time())
rows=[dict(id=i,category='unanswered_question',subject='job:'+s,owner='firstmate',next_action='obtain decision',evidence='decision pending',age_seconds=7200,limit_seconds=1800,overdue=True) for i,s in (('row-0','question-0'),("row-'quoted",'quoted-question'))]
json.dump(dict(schema='fm-open-loops.v1',generated_epoch=now,home=home,complete=True,rows=rows),open(home+'/state/open-loops.json','w'))
PY
L=$FM_HOME/state/open-loops.json
{
echo "## 0. a real wake drain presents the two overdue rows"
out=$(bin/fm-wake-drain.sh 2>&1); rc=$?
printf '%s\n' "$out" | cut -c1-400 | san; echo "exit=$rc"
line=$(printf '%s\n' "$out" | grep -oE -- '--ack-through [0-9]+ --recovery-generation [A-Za-z0-9._-]+' | tail -1)
echo; echo "## 1. acknowledge with no recorded action: refused, prints per-row commands"
echo "\$ bin/fm-wake-drain.sh $line"
out=$(bin/fm-wake-drain.sh $line 2>&1); rc=$?
printf '%s\n' "$out" | san; echo "exit=$rc"
cmds=$(printf '%s\n' "$out" | grep '^env ')
echo "printed command count: $(printf '%s\n' "$cmds" | wc -l | tr -d ' ')"
c0=$(printf '%s\n' "$cmds" | sed -n 1p); c1=$(printf '%s\n' "$cmds" | sed -n 2p)
echo; echo "## 2. adversarial: run a printed command with no action or evidence set"
before=$(shasum "$L"); env -u ACTION_KIND -u ACTION_EVIDENCE bash -c "$c0" 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
[ "$before" = "$(shasum "$L")" ] && echo "ledger unchanged: yes" || echo "ledger unchanged: NO"
echo; echo "## 3. adversarial: invalid evidence for an escalated row"
ACTION_KIND=bogus ACTION_EVIDENCE=x bash -c "$c0" 2>&1 | cut -c1-300 | san; echo "exit=${PIPESTATUS[0]}"
[ "$before" = "$(shasum "$L")" ] && echo "ledger unchanged: yes" || echo "ledger unchanged: NO"
echo; echo "## 3b. --check-actions reports each unmet row with its exact command"
bin/fm-open-loops.sh --check-actions 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
echo; echo "## 3c. adversarial: a steered action with forged delivery evidence must not record"
before=$(shasum "$L"); ACTION_KIND=steered ACTION_EVIDENCE=999.msg bash -c "$c0" 2>&1 | cut -c1-300 | san; echo "exit=${PIPESTATUS[0]}"
[ "$before" = "$(shasum "$L")" ] && echo "ledger unchanged: yes" || echo "ledger unchanged: NO"
echo; echo "## 4. answer one row only; acknowledgement must still refuse the other"
ACTION_KIND=escalated ACTION_EVIDENCE='reported to Main in lab' bash -c "$c0" 2>&1 | cut -c1-220 | san; echo "exit=${PIPESTATUS[0]}"
out=$(bin/fm-wake-drain.sh $line 2>&1); rc=$?
printf '%s\n' "$out" | san | cut -c1-260; echo "exit=$rc"
echo; echo "## 5. answer the shell-quoted row with its printed command, then the same acknowledgement"
ACTION_KIND=escalated ACTION_EVIDENCE='reported to Main in lab 2' bash -c "$c1" 2>&1 | cut -c1-220 | san; echo "exit=${PIPESTATUS[0]}"
bin/fm-wake-drain.sh $line 2>&1 | cut -c1-300 | san; echo "exit=${PIPESTATUS[0]}"
echo; echo "## 6. final recorded receipts"
python3 - "$L" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]));print('recorded actions:',sorted(d.get('handling',{}).get('actions',{})))
PY
} > "$EV/open-loops-ack-needs-action.txt" 2>&1
chmod -R u+rwX "$FM_HOME" 2>/dev/null; bin/fm-lab-home.sh teardown "$FM_HOME" >/dev/null 2>&1; rm -rf "$FM_HOME"
