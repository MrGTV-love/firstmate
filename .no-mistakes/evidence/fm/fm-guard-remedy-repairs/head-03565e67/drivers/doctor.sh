#!/usr/bin/env bash
# Live: real fm-on.sh over real ssh to disposable sshd: doctor bootstrap with no git on remote PATH; altered doctor refused.
set -u
cd "$1"; EV=$2; WT=$PWD
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; LAB=$(cd "$FM_HOME"; pwd -P)
BASE=$(mktemp -d /tmp/nm-pe.XXXXXX); BASE=$(cd "$BASE"; pwd -P)
san() { sed -e "s#$LAB#\$LAB#g" -e "s#$BASE#\$BASE#g" -e "s#$WT#\$WT#g"; }
SSHD_PID=
cleanup() { [ -z "$SSHD_PID" ] || kill "$SSHD_PID" 2>/dev/null; chmod -R u+rwX "$LAB" "$BASE" 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$BASE"; }
trap cleanup EXIT
OUT=$EV/doctor-bootstrap-hash.txt; : > "$OUT"
ROOTC=$BASE/root; REMOTE=$BASE/remote; ACCOUNT=$BASE/account
mkdir -p "$ROOTC" "$REMOTE/state" "$REMOTE/data" "$ACCOUNT" "$BASE/rbin" "$BASE/sshd"
git archive HEAD | tar -x -C "$ROOTC"
for t in bash sh env cat dirname basename mktemp ps python3 realpath rm mkdir tr wc shasum sed awk grep head tail cut uname date id ls sleep readlink chmod mv cp touch stat sort tee printf base64 hostname sysctl; do p=$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v "$t") && ln -sf "$p" "$BASE/rbin/$t"; done
ln -s "$ROOTC/bin/fm-remote-entrypoint.sh" "$BASE/rbin/fm-remote-entrypoint.sh"
ssh-keygen -q -t ed25519 -N '' -f "$BASE/sshd/host"; ssh-keygen -q -t ed25519 -N '' -f "$BASE/sshd/client"
cp "$BASE/sshd/client.pub" "$BASE/sshd/authorized_keys"; chmod 600 "$BASE/sshd/authorized_keys"
cat > "$BASE/sshd/force.sh" <<F
#!/bin/bash
export HOME=$ACCOUNT TMPDIR=$BASE/rtmp FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT=$BASE/remote-jobs PATH=$BASE/rbin
/bin/mkdir -p "\$TMPDIR"
command() { if [ "\${1:-}" = -v ] && [ "\${2:-}" = git ]; then return 1; fi; builtin command "\$@"; }
export -f command
exec /bin/bash -c "\$SSH_ORIGINAL_COMMAND"
F
chmod +x "$BASE/sshd/force.sh"
PORT=$((44100 + RANDOM % 2000))
cat > "$BASE/sshd/sshd_config" <<C
Port $PORT
ListenAddress 127.0.0.1
HostKey $BASE/sshd/host
AuthorizedKeysFile $BASE/sshd/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
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
  LogLevel ERROR
C
/usr/sbin/sshd -D -f "$BASE/sshd/sshd_config" -E "$BASE/sshd/log" & SSHD_PID=$!
sleep 1
printf '#!/bin/bash\nexec /usr/bin/ssh -F %q "$@"\n' "$BASE/sshd/ssh_config" > "$BASE/ssh-wrap"; chmod +x "$BASE/ssh-wrap"
export FM_SSH_BIN=$BASE/ssh-wrap
cat > "$LAB/data/secondmates.md" <<S
- ios - iOS delivery (host: remote-mac; root: $ROOTC; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
S
{
echo "# real bin/fm-on.sh, real ssh, disposable sshd on 127.0.0.1; git lookup is hidden from the remote entrypoint (macOS keeps git in /usr/bin, so an exported command shadow hides it, as tests/fm-on.test.sh does)"
echo "remote git lookup: $("$FM_SSH_BIN" -- remote-mac 'command -v git || echo git-not-found')"
echo "pinned hash: $(sed -n 's/^DOCTOR_SHA256=//p' "$ROOTC/bin/fm-remote-entrypoint.sh")"
echo "shipped doctor: $(shasum -a 256 "$ROOTC/bin/fm-remote-doctor.sh" | cut -d' ' -f1)"
echo; echo "## 1. reviewed doctor bootstraps with no git"
echo "\$ bin/fm-on.sh ios fm-remote-doctor.sh"
bin/fm-on.sh ios fm-remote-doctor.sh 2>&1 | san | cut -c1-200 | head -12; echo "exit=${PIPESTATUS[0]}"
echo; echo "## 2. adversarial: one extra byte in the doctor"
printf '\n' >> "$ROOTC/bin/fm-remote-doctor.sh"
bin/fm-on.sh ios fm-remote-doctor.sh 2>&1 | san | cut -c1-260; echo "exit=${PIPESTATUS[0]}"
} >> "$OUT" 2>&1
