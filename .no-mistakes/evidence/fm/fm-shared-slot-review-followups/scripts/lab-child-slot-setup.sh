#!/usr/bin/env bash
# lab-child-slot-setup.sh <lab-home> <aux-dir-outside-lab>: secondmate "domain"
# whose plain home (aux/subhome) runs child ship "child" in a REAL Treehouse
# pool slot of project alpha; the child slot holds a registered nested copy
# .claude/worktrees/parked with work no record names. Live tmux endpoints for
# both.
set -euo pipefail
LAB=$1 AUX=$2
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
SUB=$AUX/subhome CP=$AUX/subhome/projects/alpha
mkdir -p "$SUB/state" "$SUB/data" "$LAB/tmux"
printf 'domain\n' > "$SUB/.fm-secondmate-home"
git init -q --bare -b main "$AUX/alpha-origin.git"
git init -q -b main "$CP"; (cd "$CP" && echo a > a.txt && printf '.claude/\n' > .gitignore && git add . && git commit -qm base && git remote add origin "$AUX/alpha-origin.git" && git push -q -u origin main)
CW=$(cd "$CP" && TREEHOUSE_ROOT="$AUX/cpool" treehouse get --lease --lease-holder child </dev/null 2>/dev/null); CW=$(cd "$CW" && pwd -P)
echo "$CW" > "$LAB/child-slot"
mkdir -p "$CW/.claude/worktrees"; git -C "$CP" worktree add -q -b parked "$CW/.claude/worktrees/parked"
echo 'parked work' > "$CW/.claude/worktrees/parked/parked.txt"; echo "$CW/.claude/worktrees/parked" > "$LAB/nested-path"
printf 'task=child\nhome=%s\n' "$SUB" > "$(dirname "$CW")/.fm-slot-owner"
cat > "$SUB/state/child.meta" <<M
window=firstmate:fm-child
endpoint_task_id=child
worktree=$CW
project=$CP
harness=echo
kind=ship
mode=no-mistakes
yolo=off
M
cat > "$LAB/state/domain.meta" <<M
window=firstmate:fm-domain
endpoint_task_id=domain
worktree=$SUB
project=$SUB
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$SUB
projects=alpha
M
printf '%s\n' "- domain - design domain (home: $SUB; scope: design domain; projects: alpha; added 2026-10-12)" > "$LAB/data/secondmates.md"
echo 'Lab: the captain approved discarding this secondmate for a forced-refusal check.' > "$LAB/captain-words.txt"
TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s firstmate -n fm-domain 'sleep 3600'
TMUX_TMPDIR="$LAB/tmux" tmux new-window -t firstmate -n fm-child 'sleep 3600'
