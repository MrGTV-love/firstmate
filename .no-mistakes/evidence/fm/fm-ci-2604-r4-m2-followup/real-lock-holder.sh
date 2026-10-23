#!/bin/bash
set -eu
. "$1/bin/fm-remote-job-lib.sh"
WORK=$2
mkdir -p "$WORK"
lock="$WORK/repair.lock"
holder=
contender=
cleanup() {
  [ -z "$holder" ] || command kill -KILL "$holder" 2>/dev/null || true
  [ -z "$contender" ] || command kill -KILL "$contender" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT
printf 'interpreter=/bin/bash version=%s BASHPID=%s parent=%s\n' "$BASH_VERSION" "${BASHPID:-absent}" "$$"
(
  fm_remote_job_reload_lock_acquire "$lock" || exit 1
  : > "$WORK/holder.ready"
  while [ ! -e "$WORK/holder.release" ]; do sleep 0.05; done
) &
holder=$!
for _ in $(seq 1 100); do [ ! -e "$WORK/holder.ready" ] || break; sleep 0.05; done
[ -e "$WORK/holder.ready" ]
owner="$WORK/$(readlink "$lock")"
recorded=$(cat "$owner/pid")
printf 'actual subshell pid=%s recorded lock pid=%s parent pid=%s\n' "$holder" "$recorded" "$$"
[ "$recorded" = "$holder" ] && [ "$recorded" != "$$" ]
fm_remote_job_recorded_owner_alive "$owner"
printf 'persisted holder identity:\n'
cat "$owner/pid" "$owner/start" "$owner/command"
(
  fm_remote_job_reload_lock_acquire "$lock" || exit 1
  cat "$FM_REMOTE_JOB_RELOAD_OWNER/pid" > "$WORK/contender.acquired"
  while [ ! -e "$WORK/contender.release" ]; do sleep 0.05; done
  fm_remote_job_reload_lock_release "$lock"
) &
contender=$!
sleep 0.4
[ ! -e "$WORK/contender.acquired" ]
printf 'live holder protected: contender pid=%s still waiting=yes\n' "$contender"
command kill -KILL "$holder"
wait "$holder" 2>/dev/null || true
holder=
command kill -0 "$$"
if fm_remote_job_recorded_owner_alive "$owner"; then echo 'dead holder erroneously alive' >&2; exit 1; fi
for _ in $(seq 1 100); do [ ! -e "$WORK/contender.acquired" ] || break; sleep 0.05; done
[ -e "$WORK/contender.acquired" ]
recorded=$(cat "$WORK/contender.acquired")
printf 'after holder death: parent pid=%s alive=yes contender actual=%s recorded=%s acquired=yes\n' "$$" "$contender" "$recorded"
[ "$recorded" = "$contender" ]
[ ! -e "$owner" ]
: > "$WORK/contender.release"
wait "$contender"
contender=
[ ! -e "$lock" ] && [ ! -L "$lock" ]
printf 'dead holder record removed=yes lock released=yes\n'
