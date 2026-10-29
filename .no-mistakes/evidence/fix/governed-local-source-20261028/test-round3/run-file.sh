#!/usr/bin/env bash
# Usage: run-file.sh <worktree> <test-file> <log> [note]
set -u
cd "$1" || exit 2
{ echo "start=$(date -u +%FT%TZ) head=$(git rev-parse HEAD) python3=$(python3 -c 'import sys;print(sys.version.split()[0], sys.executable)')"
  echo "load=$(sysctl -n vm.loadavg) user_procs=$(ps -U "$(id -u)" -o pid= | wc -l | tr -d ' ') note=${4:-}"
  bash "$2" 2>&1; echo "EXIT=$?"
  echo "load_end=$(sysctl -n vm.loadavg) end=$(date -u +%FT%TZ)"; } >"$3" 2>&1
