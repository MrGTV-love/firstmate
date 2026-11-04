#!/usr/bin/env bash
# Live driver: a scout task with an open keyed question in a marked lab home
# with a REAL tmux pane; run the real bin/fm-promote.sh, then run its printed
# `next:` fm-send command exactly as printed. Usage: drive-promote.sh <head-root>
set -u
ROOT=$1
cd "$ROOT"
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
LAB=$FM_HOME
trap 'tmux -L fm-lab kill-server 2>/dev/null; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
# Brief-fill helpers taken verbatim from tests/fm-task-delivery.test.sh (fixture text only).
eval "$(sed -n '/^fill_task_subsections()/,/^}/p;/^fill_brief_subsections()/,/^}/p;/^fill_dod_placeholder()/,/^}/p;/^fill_whole_dod()/,/^}/p' tests/fm-task-delivery.test.sh)"
echo "lab home: $LAB"
id=scout-c1
tmux -L fm-lab new-session -d -s lab -n "fm-$id" -x 200 -y 50 'cat >/dev/null'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0"
export FM_SEND_SETTLE=0
mkdir -p "$LAB/state"
printf 'window=lab:fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$LAB/state/$id.meta"
bin/fm-brief.sh "$id" fixture-project --scout >/dev/null 2>&1 || { echo "brief failed"; exit 1; }
fill_brief_subsections "$LAB/data/$id/brief.md" "Build what the scout found." "Keep the scope."
printf 'needs-decision [key=ship-it]: should I build it?\n' > "$LAB/state/$id.status"
echo "\$ bin/fm-promote.sh $id --mode no-mistakes --yolo off"
out=$(bin/fm-promote.sh "$id" --mode no-mistakes --yolo off 2>&1); echo "exit=$?"
printf '%s\n' "$out" | grep -E '^next:' 
cmd=$(printf '%s\n' "$out" | sed -n 's/^next: //p' | grep 'fm-send\.sh')
echo
echo "===== run the printed next: command as printed"
echo "\$ $cmd"
eval "$cmd" >"$LAB/o" 2>"$LAB/e"; echo "exit=$?"; cat "$LAB/o"; grep -v '^fm-gate-refuse\|WARNING: watcher\|^●' "$LAB/e"
echo "--- inbox"; ls "$LAB/state/$id.inbox" 2>/dev/null || echo "(no inbox dir)"
echo "--- pane"; tmux -L fm-lab capture-pane -p -t "lab:fm-$id" | sed '/^$/d'
echo
echo "===== sender chooses: resend with --resolve-key ship-it"
cmd2=${cmd/fm-send.sh fm-$id /fm-send.sh fm-$id --resolve-key ship-it }
echo "\$ $cmd2"
eval "$cmd2" >"$LAB/o" 2>"$LAB/e"; echo "exit=$?"; grep -v '^fm-gate-refuse\|WARNING: watcher\|^●' "$LAB/e"
echo "--- status"; sed -E 's/ \[at=[0-9]+\]//' "$LAB/state/$id.status" | cut -c1-160
echo "--- inbox"; ls "$LAB/state/$id.inbox" 2>/dev/null
echo "--- pane"; tmux -L fm-lab capture-pane -p -t "lab:fm-$id" | sed '/^$/d'
echo "--- drain"; FM_STATE_OVERRIDE="$LAB/state" bin/fm-wake-drain.sh 2>/dev/null | grep -E 'OPEN DECISIONS|\[key=' || echo "(drain lists no open decision)"
