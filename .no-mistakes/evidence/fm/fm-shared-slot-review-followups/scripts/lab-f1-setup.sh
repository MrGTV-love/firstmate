#!/usr/bin/env bash
# lab-f1-setup.sh <lab-home> <code-root>: build the F1 shape in a disposable
# lab: a real git project with a bare origin, a REAL Treehouse pool slot
# durably leased to "parked", a parked ship record naming the slot root whose
# own branch is landed, and a nested registered copy holding 3 unpushed
# commits + untracked files that no record names.
set -euo pipefail
LAB=$1 CODE=$2
W=$LAB/work
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
mkdir -p "$W" "$LAB/tmux" "$LAB/shim"
git init -q --bare -b main "$W/origin.git"
git init -q -b main "$W/proj"
( cd "$W/proj" && echo base > README.md && printf '.claude/\n' > .gitignore && git add . && git commit -qm base \
  && git remote add origin "$W/origin.git" && git push -q -u origin main )
export TREEHOUSE_ROOT="$W/pool"
SLOT=$(cd "$W/proj" && treehouse get --lease --lease-holder parked </dev/null 2>/dev/null)
SLOT=$(cd "$SLOT" && pwd -P)
echo "$SLOT" > "$LAB/slot-path"
git -C "$SLOT" switch -q -c fm/parked
echo 'parked root work' > "$SLOT/root.txt"; git -C "$SLOT" add root.txt; git -C "$SLOT" commit -qm 'parked root work'
git -C "$SLOT" push -q origin fm/parked fm/parked:main
git -C "$W/proj" pull -q --ff-only origin main
NESTED="$SLOT/.claude/worktrees/parked-v2"
mkdir -p "$SLOT/.claude/worktrees"
git -C "$W/proj" worktree add -q -b fm/parked-v2 "$NESTED"
for n in 1 2 3; do echo "unlanded $n" > "$NESTED/commit-$n.txt"; git -C "$NESTED" add "commit-$n.txt"; git -C "$NESTED" commit -qm "nested unlanded commit $n"; done
for n in 1 2 3 4 5; do echo "untracked $n" > "$NESTED/scratch-$n.txt"; done
echo "$NESTED" > "$LAB/nested-path"
printf 'task=parked\nhome=%s\n' "$LAB" > "$(dirname "$SLOT")/.fm-slot-owner"
mkdir -p "$LAB/data/parked"
cat > "$LAB/data/parked/brief.md" <<B
# Task
## Captain's intent
Lab F1 parked task.

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/parked
B
cat > "$LAB/state/parked.meta" <<M
window=fmses:fm-parked
endpoint_task_id=parked
worktree=$SLOT
project=$W/proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
branch=fm/parked
tasktmp=$LAB/tasktmp-parked
model=default
effort=default
spawn_gen=lab.1
M
mkdir -p "$LAB/tasktmp-parked"
# Shims for network/daemon dependencies only (forge, no-mistakes daemon, docker);
# git, treehouse, tmux and the firstmate scripts are real.
for t in gh gh-axi no-mistakes docker; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "%s/shim.log"\ncase "$1 ${2:-}" in "pr list") printf "count: 0 (showing first 0)\\npull_requests[]: []\\n";; "pr view") echo "error: pull request not found" >&2; exit 1;; esac\nexit 0\n' "$t" "$LAB" > "$LAB/shim/$t"
  chmod +x "$LAB/shim/$t"
done
echo 'Lab: the captain approved discarding this work for a forced-refusal check.' > "$LAB/captain-words.txt"
TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s fmses -n fm-parked 'sleep 3600'
