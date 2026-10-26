#!/usr/bin/env bash
# Round 3: adversarial scenarios for the pre-teardown pane-job proof
# (fm_mp_prove_pane_idle, d74151fb2). Real tmux panes, real treehouse pool,
# real teardown/control/prune; the teardown is logged pass-through.
set -u
. "$(dirname "$0")/live-lab.sh"
lab_init
cat > "$LAB/bin/teardown-logged" <<X
#!/usr/bin/env bash
out=\$("$WT/bin/fm-teardown.sh" "\$@" 2>&1); rc=\$?
printf '=== teardown %s rc=%s\\n%s\\n' "\$*" "\$rc" "\$out" >> "$LAB/teardown-calls.log"
printf '%s\\n' "\$out" >&2
exit \$rc
X
chmod +x "$LAB/bin/teardown-logged"
export FM_MERGE_PRUNE_TEARDOWN_BIN="$LAB/bin/teardown-logged"
tdn() { grep -c "^=== teardown $1 " "$LAB/teardown-calls.log" 2>/dev/null || echo 0; }
slot_line() { (cd "$PROJ" && treehouse status 2>/dev/null) | grep -F -- "$1" || echo "(slot not listed)"; }
tree() { ps -axo pid=,ppid=,comm= | awk -v r="$1" '{p[$1]=$2;c[$1]=$3} END{for(k in p){x=k; while(x in p && x!=r && x>1) x=p[x]; if(x==r) printf "%s(%s) ", k, c[k]}}'; }

echo "===== S5k: a job in the task's pane working in a SUBDIRECTORY of the copy keeps it with one wake; teardown never runs"
new_task t5k 71; C=$COPY
mkdir -p "$C/src"
T send-keys -t firstmate:fm-t5k 'cd src && sleep 901' Enter; sleep 2
echo "pane tree before: $(tree "$PANE")"
prune arm t5k >/dev/null 2>&1
prune run t5k --now >/dev/null 2>&1; prune run t5k --now >/dev/null 2>&1
show t5k; echo "teardown calls for t5k: $(tdn t5k)"
echo "job alive: $(pgrep -f 'sleep 901' >/dev/null && echo yes || echo no); copy on: $(git -C "$C" symbolic-ref -q --short HEAD || echo detached); slot: $(slot_line "$C")"
T send-keys -t firstmate:fm-t5k C-c

echo "===== S5o: a job in the task's pane whose working directory is OUTSIDE the copy does not keep it: the prune reaps"
new_task t5o 72; C=$COPY
OUT=$(mktemp -d "$LAB/outside.XXXX")
T send-keys -t firstmate:fm-t5o "cd $OUT && sleep 902" Enter; sleep 2
echo "pane tree before: $(tree "$PANE")"
prune arm t5o >/dev/null 2>&1
prune run t5o --now >/dev/null 2>&1
show t5o; echo "teardown calls for t5o: $(tdn t5o)"; echo "slot: $(slot_line "$C")"

echo "===== S5a: the worker's agent (a process named claude) and a child it started in the copy do not keep it: the prune reaps"
new_task t5a 73; C=$COPY
T send-keys -t firstmate:fm-t5a "(exec -a claude bash -c 'sleep 903; true')" Enter; sleep 2
echo "pane tree before: $(tree "$PANE")"
prune arm t5a >/dev/null 2>&1
prune run t5a --now >/dev/null 2>&1
show t5a; echo "teardown calls for t5a: $(tdn t5a)"; echo "slot: $(slot_line "$C")"
echo "agent stand-in or its child still alive: $(pgrep -f 'sleep 903' >/dev/null && echo yes || echo no)"

echo "===== S5b2: a background job (sleep &) left by the pane shell at the copy root keeps it with one wake"
new_task t5g 74; C=$COPY
T send-keys -t firstmate:fm-t5g 'sleep 904 &' Enter; sleep 2
echo "pane tree before: $(tree "$PANE")"
prune arm t5g >/dev/null 2>&1
prune run t5g --now >/dev/null 2>&1; prune run t5g --now >/dev/null 2>&1
show t5g; echo "teardown calls for t5g: $(tdn t5g)"
echo "job alive: $(pgrep -f 'sleep 904' >/dev/null && echo yes || echo no); slot: $(slot_line "$C")"
pkill -f 'sleep 904'

echo "===== S5e: a pane job at the copy root keeps the copy; after the job ends and the record is re-armed, the prune reaps"
new_task t5e 75; C=$COPY
T send-keys -t firstmate:fm-t5e 'sleep 905' Enter; sleep 2
prune arm t5e >/dev/null 2>&1
prune run t5e --now >/dev/null 2>&1
echo "while the job runs: state=$(sed -n 's/^state=//p' "$STATE/t5e.merge-prune") wakes=$(wakes t5e) teardown calls=$(tdn t5e)"
T send-keys -t firstmate:fm-t5e C-c; sleep 2
rm -f "$STATE/t5e.merge-prune"
prune arm t5e >/dev/null 2>&1
prune run t5e --now >/dev/null 2>&1
show t5e; echo "teardown calls for t5e: $(tdn t5e)"; echo "slot: $(slot_line "$C")"
