#!/usr/bin/env bash
# Drives fm_project_lock_cpu from bin/fm-project-lock-lib.sh against a live busy process tree.
# Usage: cpu-sampler-check.sh <worktree> [shim-dir-with-ps]
cd "$1" || exit 1
[ -z "${2:-}" ] || PATH="$2:$PATH"
. bin/fm-project-lock-lib.sh 2>/dev/null
( bash -c 'while :; do :; done' & wait ) &
H=$!
sleep 1; a=$(fm_project_lock_cpu "$H"); rc=$?; echo "sample1 centiseconds=$a rc=$rc"
sleep 3; b=$(fm_project_lock_cpu "$H"); rc=$?; echo "sample2 centiseconds=$b rc=$rc"
if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then echo "RESULT: busy holder tree CPU rises ($a -> $b)"; else echo "RESULT: NO RISE"; fi
kill $(pgrep -P "$H") "$H" 2>/dev/null
out=$(fm_project_lock_cpu 999999); echo "missing pid: output='$out' rc=$?"
