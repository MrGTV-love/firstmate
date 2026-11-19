#!/usr/bin/env bash
# usage: remote-stop-kill.sh <tree-root>
#
# Drives the REAL fm_remote_job_stop_worker_tree (bin/fm-remote-job-lib.sh) on a
# worker-shaped process group. The group leader is a script named
# fm-remote-job-worker.sh (the only process-shape the real stop accepts), and its
# child is the REAL fm_task_inbox_write_idempotent, held inside the dedup scan by a
# blocking grep shim on PATH. The real stop sends TERM to the worker group, waits
# up to 5 s (50 x 0.1 s), then KILLs survivors. This is the stop a remote job gets
# when its caller disconnects (fm-remote-job-lib.sh cancel path), not the local
# fixture's instant group KILL.
set -u
TREE=$1
LIB="$TREE/bin/fm-task-inbox-lib.sh"
JLIB="$TREE/bin/fm-remote-job-lib.sh"
D=$(mktemp -d /tmp/fm-val-rs.XXXXXX)
STATE=$D/state
INBOX=$STATE/t1.inbox
mkdir -p "$D/shim" "$INBOX/handled"
i=0
while [ "$i" -lt 1600 ]; do
  i=$((i + 1))
  printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\nhandled steer %s\nsecond line\n' "$i" > "$INBOX/handled/$(printf '%04d' "$i").msg"
done
MARK=$D/blocked.pid
cat > "$D/shim/grep" <<SH
#!/bin/sh
case " \$* " in *" --null "*) printf '%s\n' "\$\$" > "$MARK"; exec /bin/sleep 300 ;; esac
exec /usr/bin/grep "\$@"
SH
chmod +x "$D/shim/grep"
cat > "$D/fm-remote-job-worker.sh" <<'SH'
#!/usr/bin/env bash
# Worker-shaped leader: runs the real idempotent writer as its child.
. "$1"
rec=$(fm_task_inbox_write_idempotent "$2" t1 "$3"); rc=$?
printf 'writer-rc=%s rec=%s\n' "$rc" "$rec"
exit "$rc"
SH
TEXT='KILLED-STEER corr=R1
second line'
set -m
PATH="$D/shim:$PATH" FM_STATE_OVERRIDE="$STATE" bash "$D/fm-remote-job-worker.sh" "$LIB" "$STATE" "$TEXT" > "$D/out" 2> "$D/err" &
W=$!
set +m
t0=$(date +%s)
while [ ! -s "$MARK" ] && [ $(( $(date +%s) - t0 )) -lt 30 ]; do sleep 0.05; done
sleep 0.3
blocked=$(cat "$MARK" 2>/dev/null)
echo "worker pid=$W blocking-grep pid=${blocked:-none} blocked-in-scan=$([ -n "$blocked" ] && echo yes || echo no)"
echo "pre-stop entries: $(ls -a "$INBOX" | grep -E '^\.(dedup|work|staging|seq)' | tr '\n' ' ')"
# shellcheck source=/dev/null
. "$JLIB"
s0=$(date +%s.%N)
if fm_remote_job_stop_worker_tree "$W"; then stop_rc=0; else stop_rc=$?; fi
s1=$(date +%s.%N)
echo "fm_remote_job_stop_worker_tree rc=$stop_rc seconds=$(echo "$s1 - $s0" | bc)"
wait "$W" 2>/dev/null; wrc=$?
echo "worker exit status=$wrc (143 = TERM reached the writer)"
echo "worker stdout: $(tr '\n' ' ' < "$D/out")"
echo "after stop: blocking-grep alive=$(kill -0 "${blocked:-0}" 2>/dev/null && echo yes || echo no)"
echo "after stop: entries: $(ls -a "$INBOX" | grep -E '^\.(dedup|work|staging|seq)' | tr '\n' ' ')"
echo "after stop: work-dir contents: $(ls -a "$INBOX"/.work.* 2>/dev/null | tr '\n' ' ')"
echo "after stop: any temp holding the killed text: $(grep -rl 'KILLED-STEER' "$INBOX" 2>/dev/null | sed "s|$D/||" | tr '\n' ' ')"
echo "after stop: unhandled .msg: $(ls "$INBOX" | grep -c '\.msg$')"
# Second call, no shim: must succeed.
t2=$(date +%s)
second=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_task_inbox_write_idempotent "$2" t1 "$3"' _ "$LIB" "$STATE" 'AFTER-STEER corr=R2
second line'); src=$?
echo "second call rc=$src seconds=$(( $(date +%s) - t2 )) printed=${second#"$STATE"/}"
echo "after second call: unhandled .msg: $(ls "$INBOX" | grep '\.msg$' | tr '\n' ' ')"
echo "after second call: entries: $(ls -a "$INBOX" | grep -E '^\.(dedup|work|staging|seq)' | tr '\n' ' ')"
rm -rf "$D"
