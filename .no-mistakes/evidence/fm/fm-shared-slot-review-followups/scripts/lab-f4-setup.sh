#!/usr/bin/env bash
# lab-f4-setup.sh <lab-home> [duplicate]: on top of lab-f1-setup, add a finished
# ship whose record names its OWN landed nested copy in the shared slot, with a
# leftover process whose cwd is that copy, plus a parked-root process at the
# slot root. "duplicate" adds a second record naming the same nested copy.
set -euo pipefail
LAB=$1 MODE=${2:-own}
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
SLOT=$(cat "$LAB/slot-path") P=$LAB/work/proj
FIN="$SLOT/.claude/worktrees/finished"
git -C "$P" worktree add -q -b fm/finished "$FIN" origin/main
echo done > "$FIN/finished.txt"; git -C "$FIN" add finished.txt; git -C "$FIN" commit -qm 'finished work'
git -C "$FIN" push -q origin HEAD:main HEAD:fm/finished
echo "$FIN" > "$LAB/finished-path"
sed -e 's/parked/finished/g' "$LAB/state/parked.meta" | sed "s#^worktree=.*#worktree=$FIN#" > "$LAB/state/finished.meta"
mkdir -p "$LAB/data/finished" "$LAB/tasktmp-finished"
sed 's/parked/finished/g' "$LAB/data/parked/brief.md" > "$LAB/data/finished/brief.md"
printf 'task=finished\nhome=%s\n' "$LAB" > "$(dirname "$SLOT")/.fm-slot-owner"
if [ "$MODE" = duplicate ]; then
  printf 'worktree=%s\nkind=ship\nproject=%s\nwindow=fmses:fm-other\nendpoint_task_id=other\n' "$FIN" "$P" > "$LAB/state/other.meta"
fi
TMUX_TMPDIR="$LAB/tmux" tmux new-window -t fmses -n fm-finished 'sleep 3600'
(cd "$FIN" && nohup perl -e 'sleep 3600' >/dev/null 2>&1 & echo $! > "$LAB/finished-leftover.pid")
(cd "$SLOT" && nohup perl -e 'sleep 3600' >/dev/null 2>&1 & echo $! > "$LAB/parked-root.pid")
