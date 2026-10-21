#!/usr/bin/env bash
# Runs as a process named "omp": claims the lock as the main Firstmate, then runs
# the real fm-control.sh as its child so the lock-owner ancestry is real.
printf '%s\n' "${LOCKVAL:-$$}" > "$FM_HOME/state/.lock"
"$@"
rc=$?
exit "$rc"
