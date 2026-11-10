#!/usr/bin/env bash
# Sourced by the live drive: mint a marked lab home, start a private fm-lab tmux
# server with one real shell pane per recorded worker, and write the records.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M72J0F8JK5E0YM7A7MKYVDN2
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>"$TMPDIR/lab-env.err")"
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$TMPDIR/lab-env.err")
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/fm-lab"
export FM_HOME TMUX_TMPDIR
S=$FM_HOME/state
mkdir -p "$S" "$FM_HOME/data" "$FM_HOME/config"
MINI_HOME=$FM_HOME/projects/mini-home; mkdir -p "$MINI_HOME/state" "$MINI_HOME/data"
tmux -L fm-lab new-session -d -s lab -n driver -x 200 -y 50 "bash --norc --noprofile -i"
for w in fm-slack-main-window-intake fm-mini other; do
  tmux -L fm-lab new-window -d -t lab: -n "fm-$w" "env PS1='worker[$w]\$ ' FM_TASK_INBOX=$S/$w.inbox bash --norc --noprofile -i"
done
export TMUX="$SOCK,0,0"
printf 'window=lab:fm-fm-slack-main-window-intake\nkind=ship\nharness=claude\nworktree=%s/projects/intake-wt\n' "$FM_HOME" > "$S/fm-slack-main-window-intake.meta"
mkdir -p "$FM_HOME/projects/intake-wt"
printf 'window=lab:fm-fm-mini\nendpoint_task_id=fm-mini\nworktree=%s\nproject=%s\nharness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nhome=%s\nprojects=alpha\n' "$MINI_HOME" "$MINI_HOME" "$MINI_HOME" > "$S/fm-mini.meta"
printf 'window=lab:fm-other\nkind=ship\nharness=claude\n' > "$S/other.meta"
printf 'window=child:fm-child-task\nkind=ship\n' > "$MINI_HOME/state/child-task.meta"
export FM_GUARD_EVENT_LOG=$FM_HOME/state/guard-events.jsonl
: > "$FM_GUARD_EVENT_LOG"
export FM_SEND_SETTLE=0
