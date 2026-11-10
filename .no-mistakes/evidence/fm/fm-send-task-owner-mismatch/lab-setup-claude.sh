#!/usr/bin/env bash
# Mint a marked lab home and start the private fm-lab tmux server from the
# operator's normal shell environment (so the Claude worker uses the machine's
# existing login), with one real Claude worker pane for the intake task.
set -u
T=$1
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M72J0F8JK5E0YM7A7MKYVDN2
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>"$T/lab-env.err")"
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$T/lab-env.err")
S=$FM_HOME/state; MINI_HOME=$FM_HOME/projects/mini-home; W=$FM_HOME/projects/intake-wt
mkdir -p "$S" "$FM_HOME/data" "$MINI_HOME/state" "$W"
printf 'window=lab:fm-fm-slack-main-window-intake\nkind=ship\nharness=claude\nworktree=%s\n' "$W" > "$S/fm-slack-main-window-intake.meta"
printf 'window=lab:fm-fm-mini\nendpoint_task_id=fm-mini\nworktree=%s\nproject=%s\nharness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nhome=%s\nprojects=alpha\n' "$MINI_HOME" "$MINI_HOME" "$MINI_HOME" > "$S/fm-mini.meta"
printf 'window=lab:fm-other\nkind=ship\nharness=claude\n' > "$S/other.meta"
tmux -L fm-lab new-session -d -s lab -n driver -x 200 -y 50 "bash --norc --noprofile -i"
for w in fm-mini other; do
  tmux -L fm-lab new-window -d -t lab: -n "fm-$w" "env PS1='worker[$w]\$ ' bash --norc --noprofile -i"
done
tmux -L fm-lab new-window -d -t lab: -n fm-fm-slack-main-window-intake -c "$W" \
  "env FM_HOME=$FM_HOME FM_TASK_INBOX=$S/fm-slack-main-window-intake.inbox claude --add-dir $S --allowedTools Read Write Edit 'Bash(mv:*)' 'Bash(ls:*)' 'Bash(cat:*)'"
{ echo "export FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR TMUX=$TMUX_TMPDIR/tmux-$(id -u)/fm-lab,0,0 S=$S MINI_HOME=$MINI_HOME W=$W FM_GUARD_EVENT_LOG=$S/guard-events.jsonl FM_SEND_SETTLE=0"; printf "TEARDOWN=%q\n" "$TEARDOWN"; } > "$T/lab.env"
: > "$S/guard-events.jsonl"
