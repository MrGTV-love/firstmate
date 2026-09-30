#!/usr/bin/env bash
# Live adversarial smoke for the Herdr Claude payload proof (test-phase evidence,
# not a tracked test). Real Claude Code in an isolated fm-lab-* Herdr session.
# Every Herdr call goes through bin/fm-herdr-lab.sh; cleanup trap before provision.
#   A. fm-control exit while a "human" types beside the typed /exit before the
#      proof read: expect known send failure, marker removed, agent alive,
#      human text still in the composer (no Enter, no Ctrl+U).
#   B. multi-line payload (Claude paste placeholder) with a human note appended:
#      expect send-failed, note still in the composer.
#   C. a project /<skill> slash command is proven, submitted and executed.
#   D. fm-control exit then stops the worker.
set -u
ROOT=${ROOT:?run from the worktree with ROOT set}
LAB_HELPER=${HERDR_LAB_HELPER:?}
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-adversarial)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-adv.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
ID="advtask$$"
RESULT=0
fail() { printf 'not ok - %s\n' "$1"; RESULT=1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() {
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || RESULT=1
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
  printf 'result=%s session=%s\n' "$RESULT" "$SESSION"
  exit "$RESULT"
}
trap cleanup EXIT

# Wrapper: forwards to the lab helper; when $TMP_ROOT/inject.match equals the
# typed text, it sends $TMP_ROOT/inject.human right after (a human keystroke
# landing before the proof read). One-shot.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@"); n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] \
  || { echo "wrapper refused call without --session $SESSION" >&2; exit 98; }
args=("\${args[@]:0:\$((n-2))}")
env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"; rc=\$?
if [ "\${args[0]:-} \${args[1]:-}" = "pane send-text" ] && [ -f "$TMP_ROOT/inject.match" ] \
  && [ "\${args[3]:-}" = "\$(cat "$TMP_ROOT/inject.match")" ]; then
  human=\$(cat "$TMP_ROOT/inject.human"); rm -f "$TMP_ROOT/inject.match"
  printf '%s\n' "\$(date +%T) injected human text after send" >> "$TMP_ROOT/inject.log"
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane send-text "\${args[2]}" "\$human" >/dev/null
fi
exit \$rc
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || { fail "provision"; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH"
. "$ROOT/bin/backends/herdr.sh"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

PROJ="$TMP_ROOT/proj"; SKILL_TOKEN="FMSKILLPROBE$$_$RANDOM"
mkdir -p "$PROJ/.claude/skills/fmprobe"
git -C "$PROJ" init -q && git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat > "$PROJ/.claude/skills/fmprobe/SKILL.md" <<EOF
---
name: fmprobe
description: Test probe. Use only when invoked as /fmprobe.
---
Reply with exactly $SKILL_TOKEN and nothing else. Do not run any tool.
EOF
HOME_C="$TMP_ROOT/control-home"; mkdir -p "$HOME_C/state" "$HOME_C/data/$ID"
ws=$(lab workspace create --cwd "$PROJ" --label "fm-$ID" --no-focus) || { fail "workspace"; exit 1; }
PANE=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id')
T="$SESSION:$PANE"
cat > "$HOME_C/state/$ID.meta" <<EOF
window=$T
endpoint_task_id=$ID
worktree=$PROJ
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$(printf '%s' "$ws" | jq -er '.result.workspace.workspace_id')
herdr_tab_id=$(printf '%s' "$ws" | jq -er '.result.root_pane.tab_id')
herdr_pane_id=$PANE
EOF
# Production launch shape: unnamed, default color.
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null
control() { FM_HOME="$HOME_C" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 "$ROOT/bin/fm-control.sh" "$@" 2>&1; }
screen() { lab pane read "$PANE" --source visible 2>/dev/null; }
wait_idle() {
  local i=0 trusted=0 s st
  while [ $i -lt 90 ]; do
    s=$(screen || true)
    case "$s" in
      *'bypass permissions on'*) st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
        case "$st" in idle|done) return 0 ;; esac ;;
      *'Yes, I trust this folder'*) [ $trusted = 1 ] || { trusted=1; lab pane send-keys "$PANE" down enter >/dev/null; } ;;
    esac
    i=$((i+1)); sleep 1
  done
  return 1
}
clear_composer() { local i; for i in 1 2 3 4 5 6; do lab pane send-keys "$PANE" ctrl+u >/dev/null; sleep 0.5
  [ "$(fm_backend_herdr_composer_state "$T")" = empty ] && return 0; done; return 1; }
wait_idle || { fail "Claude never reached an idle composer"; screen; exit 1; }
printf 'claude=%s herdr=%s session=%s pane=%s\n' "$(PATH=$ORIGINAL_PATH claude --version | head -1)" "$(PATH=$ORIGINAL_PATH herdr --version)" "$SESSION" "$PANE"

# --- A -----------------------------------------------------------------------
printf '%s' /exit > "$TMP_ROOT/inject.match"; printf '%s' ' keep my note' > "$TMP_ROOT/inject.human"
out=$(control "$ID" exit); rc=$?
printf -- '--- A: fm-control exit rc=%s\n%s\n' "$rc" "$out"
cat "$TMP_ROOT/inject.log" 2>/dev/null
sleep 2; sA=$(screen); printf -- '--- A: composer after refusal\n%s\n' "$(printf '%s\n' "$sA" | grep -F '❯' | tail -3)"
stA=$(fm_backend_herdr_agent_state "$T")
if [ "$rc" -ne 0 ] && [[ $out == *'could not be sent'* ]] && [ ! -e "$HOME_C/state/$ID.control-exit" ] \
  && [ "$stA" = alive ] && [[ $sA == *'keep my note'* ]] && [ -s "$TMP_ROOT/inject.log" ]; then
  pass "A: fm-control exit with human text typed beside /exit refuses as send-failed, drops the marker, Claude stays alive, human text preserved"
else
  fail "A: rc=$rc state=$stA marker=$([ -e "$HOME_C/state/$ID.control-exit" ] && echo present || echo absent)"
fi
clear_composer || fail "could not clear composer after A"

# --- B -----------------------------------------------------------------------
wait_idle || true
ML=$'Line one of a pasted note\nLine two of a pasted note\nLine three of a pasted note'
printf '%s' "$ML" > "$TMP_ROOT/inject.match"; printf '%s' ' keep my note' > "$TMP_ROOT/inject.human"
: > "$TMP_ROOT/inject.log"
vB=$(fm_backend_herdr_send_text_submit "$T" "$ML" 3 0.4 1.2)
sleep 2; sB=$(screen); stB=$(fm_backend_herdr_agent_state "$T")
printf -- '--- B: verdict=%s agent=%s\n--- B: composer rows\n%s\n' "$vB" "$stB" "$(printf '%s\n' "$sB" | grep -F -A3 '❯' | tail -6)"
if [ "$vB" = send-failed ] && [[ $sB == *'keep my note'* ]] && [ -s "$TMP_ROOT/inject.log" ]; then
  if [[ $sB == *'[Pasted text'* ]]; then
    pass "B: '[Pasted text #N] keep my note' composer refused send-failed with the note preserved"
  else
    pass "B: multi-line payload plus human note refused send-failed with the note preserved (Claude did not collapse to a placeholder here)"
  fi
else
  fail "B: verdict=$vB"
fi
clear_composer || fail "could not clear composer after B"

# --- C -----------------------------------------------------------------------
wait_idle || true
rm -f "$TMP_ROOT/inject.match"
vC=$(fm_backend_herdr_send_text_submit "$T" /fmprobe 3 0.4 1.2)
printf -- '--- C: /fmprobe verdict=%s\n' "$vC"
ok=0; for i in $(seq 1 90); do
  lab pane read "$PANE" --source recent --lines 200 2>/dev/null | grep -F -q "$SKILL_TOKEN" && { ok=1; break; }; sleep 1; done
printf -- '--- C: screen tail\n%s\n' "$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null | grep -v '^\s*$' | tail -8)"
if [ "$vC" != send-failed ] && [ $ok = 1 ]; then pass "C: /fmprobe skill command reached Claude and it replied $SKILL_TOKEN"
else fail "C: verdict=$vC token_seen=$ok"; fi

# --- D -----------------------------------------------------------------------
wait_idle || true
out=$(control "$ID" exit); rc=$?
printf -- '--- D: fm-control exit rc=%s\n%s\n' "$rc" "$out"
stD=$(fm_backend_herdr_agent_state "$T")
if [ $rc -eq 0 ] && [[ $out == *"stopped $ID"* ]] && [ "$stD" = dead ]; then pass "D: fm-control exit stopped the worker (agent state dead)"
else fail "D: rc=$rc state=$stD"; fi
