#!/usr/bin/env bash
# mutate.sh <name> <file> <python-replace-old> <python-replace-new> <test-cmd...>
# Applies one in-place mutation to the worktree, runs the behavior test, restores the file with git.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5DJJ6GJZAGVVD4816E8MJAX
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5DJJ6GJZAGVVD4816E8MJAX
name=$1 file=$2 old=$3 new=$4; shift 4
cd "$WT" || exit 1
git diff --quiet -- "$file" || { echo "refusing: $file already modified"; exit 1; }
OLD="$old" NEW="$new" FILE="$file" python3 - <<'PY' || { echo "mutation did not apply"; exit 1; }
import os,sys
p=os.environ['FILE']; s=open(p).read(); o=os.environ['OLD']; n=os.environ['NEW']
if s.count(o)!=1: sys.exit(1)
open(p,'w').write(s.replace(o,n))
PY
{
  echo "### mutation: $name"; echo "### file: $file"; echo "### diff:"; git diff -U0 -- "$file" | grep -E '^[-+][^-+]'
  echo "### running: $*"
  "$@" 2>&1 | tail -8
  echo "### test exit status: ${PIPESTATUS[0]}"
} > "$EV/mutation-$name.txt" 2>&1
git checkout -- "$file"
git diff --quiet -- "$file" && echo "restored $file" >> "$EV/mutation-$name.txt" || echo "RESTORE FAILED $file" >> "$EV/mutation-$name.txt"
cat "$EV/mutation-$name.txt"
