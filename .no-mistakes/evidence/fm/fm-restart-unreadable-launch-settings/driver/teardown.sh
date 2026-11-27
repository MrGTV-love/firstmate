#!/usr/bin/env bash
# Tear down one lab made by setup.sh: guarded Herdr teardown, lab-home teardown, rm.
set -u
. "$1/env.sh"
PATH="$FM_LAB_REAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION"; s1=$?
"$ROOT/bin/fm-lab-home.sh" teardown "$FM_HOME" && rm -rf "$FM_HOME"; s2=$?
git -C "$LAB/proj" worktree remove --force "$LAB/wt" 2>/dev/null
rm -rf "$LAB"
echo "herdr-teardown=$s1 labhome-teardown=$s2"
