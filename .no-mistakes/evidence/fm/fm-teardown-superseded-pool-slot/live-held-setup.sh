#!/usr/bin/env bash
# Add a foreign nested copy with unlanded work inside the recorded old-folder slot,
# so teardown must take the held-close route (slot kept, never returned).
set -u
F=$1; . "$F/env"; . "$F/paths"
ex=$(git -C "$REC" rev-parse --path-format=absolute --git-path info/exclude)
printf '.claude/\n' >> "$ex"
mkdir -p "$REC/.claude/worktrees"
git -C "$P" worktree add -q -b fm/task-live-v2 "$REC/.claude/worktrees/fc-one" main
echo foreign > "$REC/.claude/worktrees/fc-one/foreign.txt"
git -C "$REC/.claude/worktrees/fc-one" add foreign.txt
git -C "$REC/.claude/worktrees/fc-one" commit -q -m "unlanded foreign work"
echo "nested foreign copy: $REC/.claude/worktrees/fc-one"
