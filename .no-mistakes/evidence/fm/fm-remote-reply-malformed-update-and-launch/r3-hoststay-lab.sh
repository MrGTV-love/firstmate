#!/usr/bin/env bash
# Model-free host-local stay refusal against a REAL isolated fm-lab Herdr pane.
set -u
ROOT=$1
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
# Same sandbox harness the repo live tests use (exports the temp-sandbox gate bypass).
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset FM_BACKEND_HERDR_BIN FM_BACKEND_HERDR_CLIENT_SESSION
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name hoststay)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-r3-hoststay.XXXXXX"); TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT=$TMP_ROOT/parent; REMOTE_HOME=$TMP_ROOT/remote; FAKEBIN=$TMP_ROOT/fakebin; ID=hoststay-lab
FAILS=0
ok() { echo "ok - $*"; }
bad() { echo "not ok - $*"; FAILS=$((FAILS+1)); }
cleanup() { trap - EXIT; fm_test_cleanup || true; echo "# teardown $SESSION"; PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" && echo "# teardown ok"; rm -rf -- "$TMP_ROOT"; echo "FAILS=$FAILS"; [ "$FAILS" = 0 ]; exit $?; }
trap cleanup EXIT
mkdir -p "$PARENT/state" "$PARENT/data" "$PARENT/config" "$REMOTE_HOME/state/parent-route" "$REMOTE_HOME/data/.parent-route" "$REMOTE_HOME/config" "$FAKEBIN"
printf '%s\n' "$ID" > "$REMOTE_HOME/.fm-secondmate-home"
printf '# Isolated fixture\n' > "$REMOTE_HOME/AGENTS.md"
ln -s "$ROOT/bin" "$REMOTE_HOME/bin"
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -eu
printf '%s\\n' "\$*" >> "$TMP_ROOT/herdr.log"
args=("\$@"); n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = fm-remote ] || exit 97
args=("\${args[@]:0:\$((n-2))}")
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
cat > "$FAKEBIN/ssh" <<EOF
#!/usr/bin/env bash
set -eu
printf 'ssh %s\\n' "\$*" >> "$TMP_ROOT/ssh.log"
while [ "\$#" -gt 0 ]; do case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
[ "\$1" = isolated-lab ] && [ "\$2" = fm-remote-entrypoint.sh ] || exit 91
shift 2
args=()
while IFS= read -r -d '' arg; do args+=("\$arg"); done < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64(\$ARGV[0])' "\$4")
printf 'decoded-argv %s\\n' "\${args[*]}" >> "$TMP_ROOT/ssh.log"
[ "\${args[0]}" = fm-remote-secondmate-control.sh ] && [ "\${args[1]}" = stay ] || exit 92
exec env FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-remote-secondmate-control.sh" "\${args[@]:1}"
EOF
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/ssh"
"$LAB_HELPER" provision "$SESSION" >/dev/null && echo "# provisioned $SESSION"
lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS=$(lab workspace create --cwd "$REMOTE_HOME" --label hoststay --no-focus)
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id')
echo "# real lab pane $PANE (plain shell, no agent)"
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
spawn_gen=hoststay-$$
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
printf -- '- %s - isolated lab (host: isolated-lab; root: %s; home: %s; scope: test; projects: ; added 2026-10-26)\n' "$ID" "$ROOT" "$REMOTE_HOME" > "$PARENT/data/secondmates.md"
sleep 1
inputs() { grep -Ec '^(pane (send-text|send-keys|run|close)|tab (create|close)) ' "$TMP_ROOT/herdr.log" 2>/dev/null || true; }
VIS_BEFORE=$(lab pane read "$PANE" --source visible)
META_BEFORE=$(cat "$REMOTE_HOME/state/parent-route/$ID.meta")
export PATH="$FAKEBIN:$ORIGINAL_PATH" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=5 FM_SPAWN_NO_GUARD=1
echo; echo '$ FM_HOME=<remote> fm-remote-secondmate-control.sh stay hoststay-lab   # host-local, real lab pane'
OUT=$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-remote-secondmate-control.sh" stay "$ID" 2>&1); RC=$?
printf '%s\nrc=%s\n' "$OUT" "$RC"
[ "$RC" -ne 0 ] && case "$OUT" in *'no agent is running'*) true;; *) false;; esac && ok "host-local stay refuses a pane with no agent (dead endpoint), rc=$RC" || bad "dead endpoint"
echo; echo '# herdr now reports an idle claude agent in that pane (a process named claude with no FM_SPAWN_GEN, not a real claude process, no matching launch generation)'
lab pane run "$PANE" 'exec -a claude sleep 300' >/dev/null; sleep 2
lab pane report-agent "$PANE" --source r3-hoststay --agent claude --state idle >/dev/null
VIS_BEFORE=$(lab pane read "$PANE" --source visible)
echo '$ FM_HOME=<remote> fm-remote-secondmate-control.sh stay hoststay-lab'
OUT=$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-remote-secondmate-control.sh" stay "$ID" 2>&1); RC=$?
printf '%s\nrc=%s\n' "$OUT" "$RC"
[ "$RC" -ne 0 ] && ok "host-local stay refuses an agent it cannot attribute (rc=$RC)" || bad "accepted unattributable agent"
case "$OUT" in *'cannot positively attribute its live Herdr agent to this task; refusing lifecycle input'*) ok "refusal comes from the ordinary control plane ownership gate";; *) bad "refusal did not come from ownership gate";; esac
[ "$(inputs)" = 0 ] && ok "no pane/tab input call reached the real lab pane" || bad "pane input calls: $(inputs)"
for extra in none two; do
  if [ $extra = none ]; then A=$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-remote-secondmate-control.sh" stay 2>&1); R=$?
  else A=$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-remote-secondmate-control.sh" stay "$ID" extra 2>&1); R=$?; fi
  echo; echo "\$ fm-remote-secondmate-control.sh stay ($extra extra args) -> rc=$R"; printf '%s\n' "$A" | grep 'stay <id>'
  [ "$R" = 2 ] && case "$A" in *'fm-remote-secondmate-control.sh stay <id>'*) true;; *) false;; esac && ok "arity $extra refused with usage rc=2" || bad "arity $extra"
done
echo; echo '$ FM_HOME=<parent> fm-control.sh hoststay-lab stay   # parent -> fake ssh -> host-local -> real lab'
POUT=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" FM_DATA_OVERRIDE="$PARENT/data" FM_CONFIG_OVERRIDE="$PARENT/config" "$ROOT/bin/fm-control.sh" "$ID" stay 2>&1); PRC=$?
printf '%s\nrc=%s\n' "$POUT" "$PRC"
grep decoded-argv "$TMP_ROOT/ssh.log"
[ "$PRC" -ne 0 ] && case "$POUT" in *'cannot positively attribute'*) true;; *) false;; esac && ok "parent relays the host refusal text and a nonzero exit" || bad "parent relay"
grep -qx "decoded-argv fm-remote-secondmate-control.sh stay $ID" "$TMP_ROOT/ssh.log" && ok "parent sent exactly: fm-remote-secondmate-control.sh stay $ID" || bad "argv"
for verb in interrupt exit relaunch; do
  n0=$(wc -l < "$TMP_ROOT/ssh.log")
  V=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" FM_DATA_OVERRIDE="$PARENT/data" FM_CONFIG_OVERRIDE="$PARENT/config" "$ROOT/bin/fm-control.sh" "$ID" $verb 2>&1); VR=$?
  n1=$(wc -l < "$TMP_ROOT/ssh.log")
  echo "\$ fm-control.sh $ID $verb -> rc=$VR: ${V:0:110}..."
  [ "$VR" -ne 0 ] && [ "$n0" = "$n1" ] && ok "parent $verb refused before any transport call" || bad "$verb"
done
[ "$(inputs)" = 0 ] && ok "still no pane input after all calls" || bad "inputs later"
VIS_AFTER=$(lab pane read "$PANE" --source visible)
[ "$VIS_BEFORE" = "$VIS_AFTER" ] && ok "real lab pane visible text unchanged" || bad "pane text changed"
[ "$META_BEFORE" = "$(cat "$REMOTE_HOME/state/parent-route/$ID.meta")" ] && ok "endpoint metadata unchanged" || bad "meta changed"
echo "# herdr calls made:"; cut -d' ' -f1-2 "$TMP_ROOT/herdr.log" | sort | uniq -c
