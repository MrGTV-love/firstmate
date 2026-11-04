#!/usr/bin/env bash
# Times a --resolve-key send of a ~10 KB multi-line answer, head vs base, in one
# marked lab home with real tmux panes, to classify the slow long-answer close.
set -u
HEAD_ROOT=$1 BASE_ROOT=$2
eval "$("$HEAD_ROOT/bin/fm-lab-home.sh" env 2>/dev/null)"; LAB=$FM_HOME
trap 'tmux -L fm-lab kill-server 2>/dev/null; "$HEAD_ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
tmux -L fm-lab new-session -d -s lab -n fm-h1 -x 200 -y 50 'cat >/dev/null'
tmux -L fm-lab new-window -d -t lab -n fm-b1 'cat >/dev/null'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0" FM_SEND_SETTLE=0
for id in h1 b1; do printf 'window=lab:fm-%s\nkind=ship\n' $id > "$LAB/state/$id.meta"; printf 'needs-decision [key=ship-it]: build it?\n' > "$LAB/state/$id.status"; done
msg=$(for i in $(seq 1 120); do printf 'Line %d of a long answer with some words to make it about eighty chars wide.\n' "$i"; done)
echo "message bytes: ${#msg}"
( s=$(date +%s); "$HEAD_ROOT/bin/fm-send.sh" h1 --resolve-key ship-it "$msg" >/dev/null 2>&1; echo "head exit=$? seconds=$(( $(date +%s)-s ))" ) &
( s=$(date +%s); "$BASE_ROOT/bin/fm-send.sh" b1 --resolve-key ship-it "$msg" >/dev/null 2>&1; echo "base exit=$? seconds=$(( $(date +%s)-s ))" ) &
wait
for id in h1 b1; do echo "--- $id status"; sed -E 's/ \[at=[0-9]+\]//' "$LAB/state/$id.status" | cut -c1-90; done
