#!/usr/bin/env bash
# lab-snapshot.sh <lab-home>: print observable custody state.
LAB=$1 W=$1/work SLOT=$(cat "$1/slot-path") NESTED=$(cat "$1/nested-path")
echo "== record:"; ls "$LAB/state"/*.meta 2>/dev/null || echo '(no records)'
echo "== claim:"; cat "$(dirname "$SLOT")/.fm-slot-owner" 2>/dev/null || echo '(no claim)'
echo "== treehouse status:"; (cd "$W/proj" && TREEHOUSE_ROOT="$W/pool" treehouse status </dev/null 2>/dev/null | grep -v 'new version\|treehouse update')
echo "== registered worktrees:"; git -C "$W/proj" worktree list
echo "== nested unpushed commits:"; git -C "$NESTED" log --oneline HEAD --not --remotes 2>&1
echo "== nested untracked:"; git -C "$NESTED" status --short --untracked-files=all 2>&1
echo "== tmux windows:"; TMUX_TMPDIR="$LAB/tmux" tmux list-windows -a -F '#S:#W' 2>&1
