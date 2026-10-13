#!/usr/bin/env bash
# lab-secondmate-setup.sh <lab-home> <commit-tarball> <aux-dir-outside-lab>: a code root that is its own
# git repo (the target commit's tree), a REAL Treehouse pool of it, one slot
# durably leased as secondmate "domain"'s home, a registered nested copy
# .claude/worktrees/agent-x holding uncommitted work, and a live tmux endpoint.
set -euo pipefail
LAB=$1 TARBALL=$2 AUX=$3
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
mkdir -p "$AUX/fmroot" "$LAB/tmux"
tar -x -C "$AUX/fmroot" -f "$TARBALL"
git -C "$AUX/fmroot" init -q -b main && git -C "$AUX/fmroot" add -A && git -C "$AUX/fmroot" commit -qm 'lab code root'
HOME_SLOT=$(cd "$AUX/fmroot" && TREEHOUSE_ROOT="$AUX/smpool" treehouse get --lease --lease-holder domain </dev/null 2>/dev/null)
HOME_SLOT=$(cd "$HOME_SLOT" && pwd -P); echo "$HOME_SLOT" > "$LAB/home-slot"
printf 'domain\n' > "$HOME_SLOT/.fm-secondmate-home"; mkdir -p "$HOME_SLOT/state" "$HOME_SLOT/data"
mkdir -p "$HOME_SLOT/.claude/worktrees"
git -C "$AUX/fmroot" worktree add -q -b agent-x "$HOME_SLOT/.claude/worktrees/agent-x"
echo 'agent work not landed' > "$HOME_SLOT/.claude/worktrees/agent-x/work.txt"
echo "$HOME_SLOT/.claude/worktrees/agent-x" > "$LAB/nested-path"
cat > "$LAB/state/domain.meta" <<M
window=firstmate:fm-domain
endpoint_task_id=domain
worktree=$HOME_SLOT
project=$HOME_SLOT
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$HOME_SLOT
projects=alpha
M
printf '%s\n' "- domain - design domain (home: $HOME_SLOT; scope: design domain; projects: alpha; added 2026-10-12)" > "$LAB/data/secondmates.md"
echo 'Lab: the captain approved discarding this secondmate for a forced-refusal check.' > "$LAB/captain-words.txt"
TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s firstmate -n fm-domain 'sleep 3600'
