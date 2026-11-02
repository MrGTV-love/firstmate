#!/usr/bin/env bash
# Live drive over a REAL ssh transport to a disposable localhost sshd; remote side runs real entrypoint and worker in isolated dirs.
set -u
cd "$1"; EV=$2; WT=$PWD
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; LAB=$(cd "$FM_HOME"; pwd -P)
BASE=$(mktemp -d /tmp/nm-pe.XXXXXX); BASE=$(cd "$BASE"; pwd -P)
san() { sed -e "s#$LAB#\$LAB#g" -e "s#$BASE#\$BASE#g" -e "s#$WT#\$WT#g" | grep -vE '^●|^fm-gate-refuse|^WARNING: watcher'; }
SSHD_PID=
cleanup() {
  FM_PROCEVENT_CLAIM_ROOT="$BASE/claims" bin/fm-procevent.sh sweep-home >/dev/null 2>&1 || true
  if [ -f "$BASE/remote-jobs/worker.pid" ]; then bash -c '. bin/fm-remote-job-lib.sh; fm_remote_job_stop_worker_tree "$1"' _ "$(cat "$BASE/remote-jobs/worker.pid")" >/dev/null 2>&1; fi
  [ -z "$SSHD_PID" ] || kill "$SSHD_PID" 2>/dev/null
  tmux kill-server 2>/dev/null
  chmod -R u+rwX "$LAB" "$BASE" 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$BASE"
}
trap cleanup EXIT
OUT=$EV/procevent-retire-pending-results.txt; : > "$OUT"
REMOTE=$BASE/remote; ACCOUNT=$BASE/account; CLAIMS=$BASE/claims
mkdir -p "$REMOTE/state" "$REMOTE/data/reply" "$ACCOUNT" "$CLAIMS" "$BASE/rbin" "$BASE/sshd"
ln -s "$WT/bin/fm-remote-entrypoint.sh" "$BASE/rbin/fm-remote-entrypoint.sh"
ssh-keygen -q -t ed25519 -N '' -f "$BASE/sshd/host" ; ssh-keygen -q -t ed25519 -N '' -f "$BASE/sshd/client"
cp "$BASE/sshd/client.pub" "$BASE/sshd/authorized_keys"; chmod 600 "$BASE/sshd/authorized_keys"
cat > "$BASE/sshd/force.sh" <<F
#!/bin/bash
export HOME=$ACCOUNT TMPDIR=$BASE/rtmp FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT=$BASE/remote-jobs PATH=$BASE/rbin:\$PATH
mkdir -p "\$TMPDIR"
exec /bin/bash -c "\$SSH_ORIGINAL_COMMAND"
F
chmod +x "$BASE/sshd/force.sh"
PORT=$((42000 + RANDOM % 2000))
cat > "$BASE/sshd/sshd_config" <<C
Port $PORT
ListenAddress 127.0.0.1
HostKey $BASE/sshd/host
AuthorizedKeysFile $BASE/sshd/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PidFile $BASE/sshd/pid
ForceCommand $BASE/sshd/force.sh
LogLevel ERROR
C
cat > "$BASE/sshd/ssh_config" <<C
Host remote-mac
  HostName 127.0.0.1
  Port $PORT
  IdentityFile $BASE/sshd/client
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile $BASE/sshd/known_hosts
  BatchMode yes
C
/usr/sbin/sshd -D -f "$BASE/sshd/sshd_config" -E "$BASE/sshd/log" & SSHD_PID=$!
sleep 1
printf '#!/bin/bash\nexec /usr/bin/ssh -F %q "$@"\n' "$BASE/sshd/ssh_config" > "$BASE/ssh-wrap"; chmod +x "$BASE/ssh-wrap"
export FM_SSH_BIN=$BASE/ssh-wrap FM_PROCEVENT_CLAIM_ROOT=$CLAIMS FM_REMOTE_REPLY_WAIT_SECONDS=10
{
echo "# real /usr/bin/ssh to a disposable sshd on 127.0.0.1; remote home \$BASE/remote; parent lab home \$LAB"
echo "## transport probe"; "$FM_SSH_BIN" -- remote-mac echo ssh-transport-ok 2>&1 | san; echo "exit=${PIPESTATUS[0]}"; cat "$BASE/sshd/log" 2>/dev/null | head -5 | san
cat > "$LAB/data/secondmates.md" <<S
- ios - iOS delivery (host: remote-mac; root: $WT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
S
printf '# Detailed remote answer\n' > "$REMOTE/data/reply/report.md"; : > "$REMOTE/state/parent-replies.status"
A=$WT/bin/fm-procevent-remote-reply.sh
SID=$("$A" source-id ios); echo "source id: $SID"
echo "## arm"; "$A" arm ios 2>&1 | san | cut -c1-200; echo "exit=${PIPESTATUS[0]}"
printf 'done [corr=abcdef0123456789]: remote finished; see data/reply/report.md\n' >> "$REMOTE/state/parent-replies.status"
echo "## runner captures the reply over ssh"
bin/fm-procevent.sh start "$SID" > "$BASE/start.out" 2>&1 &
for _ in $(seq 1 120); do R=$(find "$LAB/state/procevent-inbox" -name "$SID.*.result" -print -quit 2>/dev/null); [ -n "$R" ] && [ -s "$R" ] && [ -e "${R%.result}.handled" ] && break; sleep 0.5; done
ls "$LAB/state/procevent-inbox" 2>/dev/null | san
san < "$BASE/start.out" | cut -c1-160 | tail -3
[ -n "${R:-}" ] || { echo "NO CAPTURE"; exit 3; }
pid=$(sed -n 2p "$CLAIMS/$SID.claim" 2>/dev/null); case "$pid" in ''|*[!0-9]*) ;; *) kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; sleep 1 ;; esac
echo; echo "## 1. capture present with no handled receipt (receipt removed to stage an unhandled capture); retire is refused"
rm -f "${R%.result}.handled"
"$A" retire ios > "$BASE/retire.out" 2>&1; rc=$?; san < "$BASE/retire.out"; echo "exit=$rc"
[ -s "$R" ] && echo "capture preserved: yes"
echo; echo "## 1b. the real teardown of this remote secondmate shows the same completing step, not only a bare refusal"
printf 'window=remote:ios\nendpoint_task_id=ios\nkind=secondmate\nharness=claude\nbackend=herdr\nhome=%s\nworktree=%s\nproject=%s\nremote_host=remote-mac\nremote_root=%s\nremote_backend=herdr\nremote_herdr_session=fm-remote\n' "$REMOTE" "$REMOTE" "$REMOTE" "$WT" > "$LAB/state/ios.meta"
echo "\$ bin/fm-teardown.sh ios"
bin/fm-teardown.sh ios 2>&1 | san | cut -c1-420; echo "exit=${PIPESTATUS[0]}"
[ -s "$R" ] && echo "capture preserved: yes"; [ -f "$LAB/state/ios.meta" ] && echo "task record preserved: yes"
rm -f "$LAB/state/ios.meta"
echo; echo "## 2. run each exact printed handle command"
n=0; while IFS= read -r line; do case "$line" in FM_HOME=*) n=$((n+1)); bash -c "$line" 2>&1 | san | cut -c1-200; echo "handle exit=${PIPESTATUS[0]}";; esac; done < "$BASE/retire.out"; echo "printed commands run: $n"
[ -e "${R%.result}.handled" ] && echo "handled receipt written: yes"
echo; echo "## 3. retry the refused retirement"
"$A" retire ios 2>&1 | san | cut -c1-260; echo "exit=${PIPESTATUS[0]}"
echo "remote reply cursor removed: $([ -e "$LAB/state/remote-replies/ios.cursor" ] && echo no || echo yes)"
} >> "$OUT" 2>&1
