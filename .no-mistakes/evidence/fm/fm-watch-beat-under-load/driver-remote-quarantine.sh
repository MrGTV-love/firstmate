#!/usr/bin/env bash
# Behavior tests for the bounded remote job queue and worker.
set -u

# shellcheck source=tests/lib.sh
. "$PWD/tests/lib.sh"

ROOT=$PWD
TMP_ROOT=$(fm_test_tmproot fm-remote-job)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
RUNTIME_BIN="$TMP_ROOT/runtime-bin"
FAKE_PERL_LOG="$TMP_ROOT/perl.log"
REAL_GIT=$(command -v git)
OTHER_PID=
RECOVERY_WORKER_PID=
REPEAT_WORKER_PID=
RESTART_SUPERVISOR_PID=
LOST_TERM_PID=
REPLACEMENT_OWNER_PID=
STALL_WORKER_PID=
STALL_REPLACEMENT_PID=
STALL_JOB_GROUP=
QUIET_WORKER_PID=
GROUP_PID=
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$RUNTIME_BIN"
# worker.pid records the serving child, not its restart supervisor, so stopping
# that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup_remote_job_fixture() {
  [ -z "$OTHER_PID" ] || kill "$OTHER_PID" 2>/dev/null || true
  [ -z "$RECOVERY_WORKER_PID" ] || kill "$RECOVERY_WORKER_PID" 2>/dev/null || true
  [ -z "$REPEAT_WORKER_PID" ] || kill "$REPEAT_WORKER_PID" 2>/dev/null || true
  [ -z "$RESTART_SUPERVISOR_PID" ] || kill -KILL "$RESTART_SUPERVISOR_PID" 2>/dev/null || true
  [ -z "$LOST_TERM_PID" ] || kill -KILL "$LOST_TERM_PID" 2>/dev/null || true
  [ -z "$REPLACEMENT_OWNER_PID" ] || kill -KILL "$REPLACEMENT_OWNER_PID" 2>/dev/null || true
  [ -z "$QUIET_WORKER_PID" ] || kill -KILL "$QUIET_WORKER_PID" 2>/dev/null || true
  local stall_pid
  for stall_pid in "$STALL_WORKER_PID" "$STALL_REPLACEMENT_PID"; do
    [ -n "$stall_pid" ] || continue
    kill -KILL "$stall_pid" 2>/dev/null || true
    wait "$stall_pid" 2>/dev/null || true
  done
  [ -z "$STALL_JOB_GROUP" ] || kill -KILL -- "-$STALL_JOB_GROUP" 2>/dev/null || true
  [ -z "$GROUP_PID" ] || kill -KILL -- "-$GROUP_PID" 2>/dev/null || true
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_remote_job_fixture EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$ROOT/bin/fm-remote-delta-read.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
set -u
printf 'home=%s\nroot=%s\nactive=%s\npath=%s\n' "$FM_HOME" "$FM_ROOT_OVERRIDE" "${FM_REMOTE_JOB_ACTIVE:-}" "$PATH"
printf 'args:'
printf ' <%s>' "$@"
printf '\n'
if [ -n "${TOP_SECRET:-}" ]; then printf 'secret=leaked\n'; else printf 'secret=absent\n'; fi
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin=%s\n' "$line"; done
exit "${FM_PROBE_EXIT:-0}"
SH
cat > "$REMOTE_ROOT/bin/fm-timeout-job.sh" <<'SH'
#!/bin/bash
sleep 3
SH
cat > "$REMOTE_ROOT/bin/fm-delay-job.sh" <<'SH'
#!/bin/bash
sleep "$1"
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
cat > "$REMOTE_ROOT/bin/fm-shutdown-job.sh" <<'SH'
#!/bin/bash
trap '' HUP INT TERM
printf 'started\n' > "$1"
read -r _ < "$3"
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-output-job.sh" <<'SH'
#!/bin/bash
set -e
head -c 1200000 < /dev/zero
head -c 1200000 < /dev/zero >&2
exit 23
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
cat > "$RUNTIME_BIN/perl" <<'SH'
#!/bin/bash
printf 'invoked\n' >> "$FM_FAKE_PERL_LOG"
exit 127
SH
chmod +x "$RUNTIME_BIN/perl"

git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'


# shellcheck disable=SC2031 # The earlier assignment was confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_TIMEOUT=5
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"


HOME="$ACCOUNT_HOME" PATH="$RUNTIME_BIN:/usr/bin:/bin:/usr/sbin:/sbin" FM_FAKE_PERL_LOG="$FAKE_PERL_LOG" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=5 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the worker did not publish its readiness heartbeat"


QUARANTINE_STARTED="$TMP_ROOT/quarantine-started"
QUARANTINE_SIDE_EFFECT="$TMP_ROOT/quarantine-side-effect"
QUARANTINE_FIFO="$TMP_ROOT/quarantine-fifo"
mkfifo "$QUARANTINE_FIFO"
FM_REMOTE_JOB_TIMEOUT=5
FM_REMOTE_JOB_TIMEOUT=60 fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$QUARANTINE_STARTED" "$QUARANTINE_SIDE_EFFECT" "$QUARANTINE_FIFO" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
for _ in $(seq 1 100); do
  [ -f "$QUARANTINE_STARTED" ] && break
  sleep 0.05
done
assert_present "$QUARANTINE_STARTED" "the quarantine fixture did not begin executing"
GROUP_PID=$(cat "$JOB_DIR/.claim/group")
kill -0 -- "-$GROUP_PID" 2>/dev/null \
  || fail "the quarantine command group exited before its claim was corrupted"
printf 'invalid\n' > "$JOB_DIR/.claim/group"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
wait "$WORKER_PID" 2>/dev/null || true
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.lock/quarantine" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.lock/quarantine" "failed shutdown released worker ownership"
printf "serving_worker_pid=%s command_group_pid=%s\n" "$WORKER_PID" "$GROUP_PID"
printf "quarantine ownership record:\n"; cat "$STATE_ROOT/worker.lock/quarantine"
printf "worker stderr:\n"; cat "$TMP_ROOT/worker.err"
fm_remote_job_probe "$ACCOUNT_HOME" && fail "quarantined worker ownership still reported ready"
set +e
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err"
REPLACEMENT_RC=$?
set -e
[ "$REPLACEMENT_RC" -ne 0 ] || fail "a replacement worker ignored quarantined ownership"
printf "replacement_worker_exit=%s\n" "$REPLACEMENT_RC"
assert_present "$STATE_ROOT/worker.lock/quarantine" "a replacement removed quarantined ownership"
kill -0 -- "-$GROUP_PID" 2>/dev/null \
  || fail "the quarantine command group exited before explicit termination"
printf "command group proved live before explicit termination\n"
kill -KILL -- "-$GROUP_PID" 2>/dev/null || true
for _ in $(seq 1 100); do
  kill -0 -- "-$GROUP_PID" 2>/dev/null || break
  sleep 0.05
done
! kill -0 -- "-$GROUP_PID" 2>/dev/null \
  || fail "the quarantine command group was still alive after explicit termination"
GROUP_PID=
assert_absent "$QUARANTINE_SIDE_EFFECT" "the quarantined command mutated after explicit termination"
pass "failed shutdown quarantines ownership against replacement workers"