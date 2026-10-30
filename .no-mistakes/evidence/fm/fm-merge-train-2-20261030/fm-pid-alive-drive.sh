#!/usr/bin/env bash
# usage: drive.sh <wake-lib> <proc_root>
set -euo pipefail
. "$1"
sleep 30 & live=$!
mkdir -p "$2/$live/stat"   # stat path readable but cannot be read: same as a process that exits mid-read
FM_PROC_ROOT_OVERRIDE=$2
export FM_PROC_ROOT_OVERRIDE
if fm_pid_alive "$live"; then echo "live pid $live with unreadable stat -> alive (caller kept running)"; else echo "live pid $live -> reported dead"; fi
kill "$live"; wait "$live" 2>/dev/null || true
mkdir -p "$2/$live/stat"
if fm_pid_alive "$live"; then echo "exited pid $live -> reported alive"; else echo "exited pid $live -> dead (caller kept running)"; fi
echo "caller reached end"
