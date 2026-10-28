#!/bin/bash
# Usage: run-test.sh <label> <test-file> [selectors...]
# Runs one existing test file from the gate worktree (HEAD) with stock bash, in a fresh owned TMPDIR,
# records exit, wall secs, ok/not ok counts and owned-root receipts (immediately and after 15 s).
set -u
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M60X7EHPFP3WC1T7VVP0W6VM/r8
WT=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M60X7EHPFP3WC1T7VVP0W6VM
label=$1; shift; file=$1; shift
cd "$WT" || exit 99
T=$(mktemp -d "$HOME/tmp/nm-r8-$label.XXXXXX"); T=$(cd -P "$T" && pwd -P)
echo "head=$(git rev-parse HEAD) tree=$(git rev-parse HEAD^{tree}) dirty=$(git status --porcelain | wc -l | tr -d ' ') bash=$(bash --version | head -1) $(uname -sr) TMPDIR=$T start=$(date -u)" > "$EV/$label.inputs"
s=$(date +%s)
TMPDIR="$T" bash "$file" "$@" > "$EV/$label.out" 2>&1; rc=$?
e=$(date +%s)
{ echo "--- after exit"; find "$T" -maxdepth 3 | head -20; sleep 15; echo "--- after 15s"; find "$T" -maxdepth 3 | head -20
  if [ "$(find "$T" -mindepth 1 | wc -l | tr -d ' ')" = 0 ]; then rmdir "$T" && own=empty_rmdir_ok; else own="kept:$T"; fi
  echo "owned_tmp=$own"; } > "$EV/$label.receipt" 2>&1
own=$(tail -1 "$EV/$label.receipt")
echo "$label exit=$rc secs=$((e-s)) ok=$(grep -c '^ok' "$EV/$label.out") notok=$(grep -c '^not ok' "$EV/$label.out") $own" | tee -a "$EV/receipts.txt"
