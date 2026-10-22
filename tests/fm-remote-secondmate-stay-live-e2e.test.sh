#!/usr/bin/env bash
# Real Claude picker release through parent fm-control -> fm-on -> the owning
# host's ordinary control plane, with transport mapped to one isolated Herdr lab.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_REMOTE_STAY_LIVE herdr jq claude perl
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset FM_BACKEND_HERDR_BIN FM_BACKEND_HERDR_CLIENT_SESSION

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name remote-stay-live)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-stay-live.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_HOME="$TMP_ROOT/remote"
FAKEBIN="$TMP_ROOT/fakebin"
ID=remote-stay-live
VERSION=$(claude --version)
cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  rm -rf -- "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
mkdir -p "$PARENT/state" "$PARENT/data" "$REMOTE_HOME/state/parent-route" \
  "$REMOTE_HOME/data/.parent-route" "$REMOTE_HOME/config" "$FAKEBIN"
printf '%s\n' "$ID" > "$REMOTE_HOME/.fm-secondmate-home"
printf '# Isolated lifecycle fixture\n' > "$REMOTE_HOME/AGENTS.md"
ln -s "$ROOT/bin" "$REMOTE_HOME/bin"

# Every backend call is mapped to the guarded lab. Reject every session other
# than the remote protocol's fixed name: no call can reach a real fm-remote.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -eu
printf '%s\\n' "\$*" >> "$TMP_ROOT/herdr.log"
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] \\
  && [ "\${args[\$((n-1))]}" = fm-remote ] || exit 97
args=("\${args[@]:0:\$((n-2))}")
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
cat > "$FAKEBIN/ssh" <<EOF
#!/usr/bin/env bash
set -eu
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "\$1" = isolated-lab ] && [ "\$2" = fm-remote-entrypoint.sh ] || exit 91
shift 2
args=()
while IFS= read -r -d '' arg; do args+=("\$arg"); done < <(
  perl -MMIME::Base64=decode_base64 -e 'print decode_base64(\$ARGV[0])' "\$4"
)
[ "\${args[0]}" = fm-remote-secondmate-control.sh ] || exit 92
[ "\${args[1]}" = stay ] && [ "\${args[2]}" = "$ID" ] || exit 93
exec env FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$ROOT" \\
  "$ROOT/bin/fm-remote-secondmate-control.sh" "\${args[@]:1}"
EOF
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/ssh"
"$LAB_HELPER" provision "$SESSION"
lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS=$(lab workspace create --cwd "$REMOTE_HOME" --label remote-stay-live --no-focus)
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id')
GEN="live-$$"
cat > "$REMOTE_HOME/state/parent-route/$ID.meta" <<EOF
window=fm-remote:$PANE
endpoint_task_id=$ID
worktree=$REMOTE_HOME
project=$REMOTE_HOME
home=$REMOTE_HOME
harness=claude
kind=secondmate
backend=herdr
herdr_session=fm-remote
herdr_workspace_id=$(printf '%s' "$WS" | jq -er '.result.workspace.workspace_id')
herdr_tab_id=$(printf '%s' "$WS" | jq -er '.result.root_pane.tab_id')
herdr_pane_id=$PANE
spawn_gen=$GEN
launch_proof=env-v1
EOF
cat > "$PARENT/state/$ID.meta" <<EOF
window=remote:$ID
endpoint_task_id=$ID
harness=claude
kind=secondmate
home=$REMOTE_HOME
remote_host=isolated-lab
remote_root=$ROOT
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:$PANE
EOF
printf -- '- %s - isolated lab (host: isolated-lab; root: %s; home: %s; scope: test; projects: ; added 2026-10-22)\n' \
  "$ID" "$ROOT" "$REMOTE_HOME" > "$PARENT/data/secondmates.md"
"$ROOT/bin/fm-claude-trust.sh" --secondmate-home "$REMOTE_HOME" "$ID" >/dev/null
PROMPT="Use Bash to run sleep 600 with run_in_background=true. Then reply BACKGROUND_READY and wait. When you receive a Firstmate instruction waiting doorbell, read exactly its named file, carry out its instruction and move it to the handled directory beside it. Do not stop the background shell. Do not edit any other file."
SETTINGS=$(jq -cn --arg command "touch '$TMP_ROOT/turn-finished'" \
  '{hooks:{Stop:[{hooks:[{type:"command",command:$command}]}]}}')
printf -v LAUNCH 'FM_TASK_ID=%q FM_TASK_INBOX=%q FM_SPAWN_GEN=%q CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --setting-sources project,local --settings %q %q' \
  "$ID" "$REMOTE_HOME/state/parent-route/$ID.inbox" "$GEN" "$SETTINGS" "$PROMPT"
lab pane run "$PANE" "$LAUNCH" >/dev/null
export PATH="$FAKEBIN:$ORIGINAL_PATH"
export FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=5 FM_SPAWN_NO_GUARD=1
# A rendered prompt can contain its token twice before Claude has done any
# work. Its own Stop hook, not echoed prompt text, proves the turn completed.
for ((i=0; i<180; i++)); do
  [ ! -f "$TMP_ROOT/turn-finished" ] || break
  sleep 1
done
[ -f "$TMP_ROOT/turn-finished" ] || fail "$VERSION: the initial turn never completed"
lab pane read "$PANE" --source visible
# This manual lab launch has no installed Herdr hook integration. Register the
# observed idle state after Claude's reply; kernel process proof still has to
# identify the real Claude and its matching launch generation before any key.
lab pane report-agent "$PANE" --source fm-remote-stay-live --agent claude --state idle >/dev/null
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-launch-proof-lib.sh
. "$ROOT/bin/fm-launch-proof-lib.sh"
BEFORE_PID=$(fm_launch_proof_herdr_pid "$REMOTE_HOME/state/parent-route/$ID.meta") \
  || fail "$VERSION: could not attribute the original Claude process"
# An exit of a persistent secondmate must refuse the picker, not answer it.
if OUT=$(FM_HOME="$ROOT" FM_STATE_OVERRIDE="$REMOTE_HOME/state/parent-route" \
  FM_CONFIG_OVERRIDE="$REMOTE_HOME/config" "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1); then
  fail "$VERSION: exit unexpectedly stopped the secondmate: $OUT"
fi
case "$OUT" in
  *'Claude background-task exit picker'*) ;;
  *)
    cat "$TMP_ROOT/herdr.log" >&2
    lab pane get "$PANE" >&2
    lab agent get "$PANE" >&2
    lab pane process-info --pane "$PANE" >&2
    fail "$VERSION: exit did not identify the real picker: $OUT"
    ;;
esac
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
REC=$(fm_task_inbox_write "$REMOTE_HOME/state/parent-route" "$ID" 'Reply STEERING_READ and move this record to handled. Do not stop the background shell.')
[ -f "$REC" ] || fail "could not queue the isolated steering record"
BEFORE=$(cat "$PARENT/state/$ID.meta")
OUT=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" FM_DATA_OVERRIDE="$PARENT/data" \
  FM_CONFIG_OVERRIDE="$PARENT/config" "$ROOT/bin/fm-control.sh" "$ID" stay 2>&1) \
  || fail "$VERSION: remote stay refused: $OUT"
assert_contains "$OUT" "stayed $ID" "$VERSION: remote stay did not report its verified result"
[ "$(cat "$PARENT/state/$ID.meta")" = "$BEFORE" ] || fail "stay changed the parent's route"
[ -f "$REC" ] || fail "stay discarded the unread record"
fm_task_inbox_ring herdr "fm-remote:$PANE" "$REC" "fm-$ID" \
  || fail "$VERSION: the released composer did not accept its queued doorbell"
for ((i=0; i<180; i++)); do
  [ ! -f "$REMOTE_HOME/state/parent-route/$ID.inbox/handled/${REC##*/}" ] || break
  sleep 1
done
if [ ! -f "$REMOTE_HOME/state/parent-route/$ID.inbox/handled/${REC##*/}" ]; then
  lab pane read "$PANE" --source visible >&2
  fail "$VERSION: the released agent never acknowledged its queued steering"
fi
AFTER_PID=$(fm_launch_proof_herdr_pid "$REMOTE_HOME/state/parent-route/$ID.meta") \
  || fail "$VERSION: could not attribute the Claude process after acknowledgement"
[ "$AFTER_PID" = "$BEFORE_PID" ] || fail "$VERSION: stay replaced the agent instead of releasing it"
pass "$VERSION: remote stay releases the real picker, preserves the route and queued record, and the same agent acknowledges steering"
