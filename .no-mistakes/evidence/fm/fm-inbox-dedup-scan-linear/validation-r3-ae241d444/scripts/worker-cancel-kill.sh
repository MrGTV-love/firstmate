#!/usr/bin/env bash
# usage: worker-cancel-kill.sh <tree-root> [runs]
#
# Drives the REAL remote job path: fm_remote_job_stage stages a job, the REAL
# bin/fm-remote-job-worker.sh --lane runs it, and the REAL fm_remote_job_cancel
# marks the caller gone. The worker then does its own cancel stop (TERM to the
# job's process group, a 1 s poll of 20 x 0.05 s, then KILL) - the path a remote
# steer takes when the local budget kills the ssh leg.
# The job is fm-writer-job.sh, a tracked command in a scratch git remote root
# holding a copy of the tree's bin/. It runs the REAL fm_task_inbox_write_idempotent
# inside $(...) as cmd_send does, with a blocking dedup grep shim held on PATH
# so the writer is inside the candidate scan when the cancel lands.
# Each run uses its own scratch dirs under /tmp and removes them.
set -u
TREE=$1
RUNS=${2:-1}
for run in $(seq 1 "$RUNS"); do
  # The account home must be a physical path (pwd -P), so resolve the /tmp symlink.
  D=$(cd "$(mktemp -d /tmp/fm-val-wc.XXXXXX)" && pwd -P)
  RR=$D/remote-root; RH=$D/remote-home; AH=$D/account; SR=$D/remote-jobs
  STATE=$D/state; INBOX=$STATE/t1.inbox
  mkdir -p "$RR" "$RH" "$AH" "$D/shim" "$INBOX/handled"
  i=0
  while [ "$i" -lt 1600 ]; do
    i=$((i + 1))
    printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\nhandled steer %s\nsecond line\n' "$i" > "$INBOX/handled/$(printf '%04d' "$i").msg"
  done
  MARK=$D/blocked.mark
  cat > "$D/shim/grep" <<SH
#!/bin/sh
case " \$* " in *" --null "*) printf '%s %s\n' "\$\$" "\$PPID" > "$MARK"; exec /bin/sleep 300 ;; esac
exec /usr/bin/grep "\$@"
SH
  chmod +x "$D/shim/grep"
  git clone -q "$TREE" "$RR"
  cat > "$RR/bin/fm-writer-job.sh" <<SH
#!/bin/bash
# Remote job command: the real idempotent writer, called the way cmd_send calls it.
PATH="$D/shim:\$PATH"
export PATH
. "$RR/bin/fm-task-inbox-lib.sh"
rec=\$(fm_task_inbox_write_idempotent "$STATE" t1 'KILLED-STEER corr=W1
second line') || exit 1
printf 'writer-rec=%s\n' "\$rec"
SH
  chmod +x "$RR/bin/fm-writer-job.sh"
  git -C "$RR" config user.email test@example.com
  git -C "$RR" config user.name Test
  git -C "$RR" add bin/fm-writer-job.sh
  git -C "$RR" commit -qm 'scratch remote root job'
  export FM_REMOTE_JOB_STATE_ROOT=$SR FM_ROOT_OVERRIDE=$RR FM_REMOTE_JOB_TIMEOUT=60 FM_REMOTE_JOB_QUEUE_TIMEOUT=60
  # shellcheck source=/dev/null
  . "$RR/bin/fm-remote-job-lib.sh"
  if ! fm_remote_job_stage "$AH" "$RR" "$RH" fm-writer-job.sh </dev/null >/dev/null; then
    echo "run $run: stage failed: ${FM_REMOTE_JOB_ERROR:-unknown}"; rm -rf "$D"; continue
  fi
  JOB=$FM_REMOTE_JOB_ID
  HOME="$AH" bash "$RR/bin/fm-remote-job-worker.sh" --lane "$JOB" > "$D/worker.out" 2> "$D/worker.err" &
  W=$!
  t0=$(date +%s)
  while [ ! -s "$MARK" ] && [ $(( $(date +%s) - t0 )) -lt 60 ]; do sleep 0.1; done
  sleep 0.3
  read -r blocked_pid writer_shell < "$MARK" 2>/dev/null
  echo "run $run: job=$JOB worker=$W blocked-grep=${blocked_pid:-none} writer-shell=${writer_shell:-none} in-scan=$([ -n "${blocked_pid:-}" ] && echo yes || echo no)"
  c0=$(date +%s)
  if fm_remote_job_cancel "$AH" "$JOB"; then crc=0; else crc=$?; fi
  wait "$W"; wrc=$?
  c1=$(date +%s)
  echo "  cancel rc=$crc; lane exited rc=$wrc after $((c1 - c0)) s from cancel"
  echo "  lane stdout: $(tr '\n' ' ' < "$D/worker.out")"
  sleep 0.5
  echo "  blocking grep alive after: $(kill -0 "${blocked_pid:-0}" 2>/dev/null && echo yes || echo no)"
  echo "  entries after lane: $(ls -a "$INBOX" | grep -E '^\.(dedup|work|staging|seq)' | tr '\n' ' ')"
  echo "  work-dir contents: $(ls -a "$INBOX"/.work.* 2>/dev/null | tr '\n' ' ')"
  echo "  temp files holding the killed text: $(grep -rl 'KILLED-STEER' "$INBOX" 2>/dev/null | sed "s|$D/||" | tr '\n' ' ')"
  echo "  unhandled .msg after lane: $(ls "$INBOX" | grep -c '\.msg$')"
  t2=$(date +%s)
  second=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_task_inbox_write_idempotent "$2" t1 "$3"' _ "$RR/bin/fm-task-inbox-lib.sh" "$STATE" 'AFTER-STEER corr=W2
second line'); src=$?
  echo "  second call rc=$src seconds=$(( $(date +%s) - t2 )) printed=${second#"$STATE"/}"
  echo "  entries after second call: $(ls -a "$INBOX" | grep -E '^\.(dedup|work|staging|seq)' | tr '\n' ' ')"
  rm -rf "$D"
done
