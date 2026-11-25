#!/usr/bin/env bash
# r6-2-liveness.sh <bin-dir> <scratch>: source the real teardown libraries (as bin/fm-teardown.sh and
# the suite's r5 harness do) and call the real liveness functions with NO stubs: a real live pid
# (this script's own sleep), a real exited pid, and a lock path that does not exist so the real
# fm_lock_path_mtime fails. Prints rc for each call.
set -u
B=$1 S=$2
mkdir -p "$S/tmp"; export TMPDIR="$S/tmp"
secondmate_registry_parse_line() { :; }
fm_refuse_text() { printf '%s' "$1"; }
. "$B/fm-task-copy-lib.sh"; . "$B/fm-backlog-transition-lib.sh"; . "$B/fm-teardown-nested-lib.sh"
type fm_lock_path_mtime >/dev/null 2>&1 || . "$B/fm-lock-lib.sh"
sleep 300 & live=$!
sleep 0.1 & dead=$!; wait "$dead" 2>/dev/null
: > "$S/real.lock"; touch -t 203001010000 "$S/real.lock"   # a lock written after the live pid started
echo "fm_lock_path_mtime on a missing path: '$(fm_lock_path_mtime "$S/missing.lock")' rc=$(fm_lock_path_mtime "$S/missing.lock" >/dev/null; echo $?)"
rc=0; teardown_launcher_live_since "$live" '' || rc=$?;                       echo "teardown_launcher_live_since <live pid> '' (unreadable lock time) -> rc=$rc"
rc=0; teardown_lock_launcher_may_be_live "$live" "$S/missing.lock" || rc=$?;  echo "teardown_lock_launcher_may_be_live <live pid> <missing lock> -> rc=$rc"
rc=0; teardown_lock_launcher_may_be_live "$live" "$S/real.lock" || rc=$?;     echo "teardown_lock_launcher_may_be_live <live pid> <lock newer than pid> -> rc=$rc (control: live)"
rc=0; teardown_lock_launcher_may_be_live "$dead" "$S/missing.lock" || rc=$?;  echo "teardown_lock_launcher_may_be_live <exited pid> <missing lock> -> rc=$rc (control: gone)"
kill "$live"; wait "$live" 2>/dev/null
