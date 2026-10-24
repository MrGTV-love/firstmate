#!/usr/bin/env bash
# Builds a disposable world for fm-copy-sweep.sh with Vernant's REAL closeout driver.
# Usage: build-real-driver-world.sh <world-dir> <n-copies> [lock-mode: dead|live]
set -eu
W=$1; N=$2; MODE=${3:-dead}
VSLOT=$HOME/.treehouse/vernant-2ee7ec/102/vernant   # read-only source of the real driver
HOMED=$W/home TH=$W/th SLOT=$W/th/pool1/1/repo
mkdir -p "$HOMED/state" "$HOMED/config" "$HOMED/data" "$TH/pool1/1"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
git init -q -b main "$W/origin.git" --bare
git init -q -b main "$SLOT"
printf 'base\n' > "$SLOT/README.md"
git -C "$SLOT" add README.md; git -C "$SLOT" commit -qm base
git -C "$SLOT" remote add origin "$W/origin.git"
git -C "$SLOT" push -q -u origin main
# Real driver source, extracted read-only from the Vernant slot's committed tree.
git -C "$VSLOT" archive HEAD scripts | tar -x -C "$SLOT"
printf '%s\n' scripts/ .claude/ >> "$SLOT/.git/info/exclude"
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$TH/pool1/treehouse-state.json"
# A launcher that is gone (dead) or still running (live).
if [ "$MODE" = live ]; then
  (cd "$W" && exec sleep 3600) & pid=$!; echo "$pid" > "$W/live.pid"
else
  sleep 0.1 & pid=$!; wait "$pid" || true
fi
for i in $(seq 1 "$N"); do
  name=c$i copy=$SLOT/.claude/worktrees/c$i
  git -C "$SLOT" worktree add -q -b "fm/$name" "$copy"
  printf '%s\n' "$name" > "$copy/$name.txt"
  git -C "$copy" add "$name.txt"; git -C "$copy" commit -qm "$name"
  git -C "$copy" push -q origin "fm/$name"
  # "Merge the PR": land the branch on origin/main (fast-forward merge commit).
  git -C "$SLOT" fetch -q origin "fm/$name"
  git -C "$SLOT" merge -q --no-ff -m "Merge PR $name" FETCH_HEAD
  git -C "$SLOT" push -q origin main
  git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$pid launcher=$pid" "$copy"
done
git -C "$SLOT" fetch -q origin
echo "world=$W slot=$SLOT launcher=$pid mode=$MODE copies=$N"
