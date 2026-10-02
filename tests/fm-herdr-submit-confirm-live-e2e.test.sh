#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# in two shapes and drives each through the submit path and the public
# fm-control lifecycle commands:
#   - production: an unnamed session with the pane's default color, launched
#     the way fm-spawn launches a worker. It must refuse exit over a pending
#     draft by name, execute /compact, be replaced by fm-control relaunch (the
#     replacement is fm-spawn's own launch and must read its instructions), and
#     then stop through fm-control exit with its endpoint preserved.
#   - forced truecolor: the same launch with truecolor forced, where Claude
#     draws a recognized slash command in a theme color the default ghost
#     ceiling can strip. It must refuse exit over that colored draft by name,
#     execute /compact, report empty for a landed idle steer and a U+2063
#     operational payload, and stop through fm-control exit.
# It fails naming the harness and version rather than degrading quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
PROD_ID="submitprod$$"
COLOR_ID="submitcolor$$"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  # fm-spawn stages a relaunch under this per-task temp root and write-protects
  # the task's git hook directory in the control home.
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT" "/tmp/fm-$PROD_ID"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
SUBJECT="Claude Code ($VERSION) on $HERDR_VER"

CONTROL_HOME="$TMP_ROOT/control-home"
PROD_PROJ="$TMP_ROOT/proj"
PROD_WT="$TMP_ROOT/wt"
RELAUNCH_TOKEN="FMHERDRRELAUNCH$$_$RANDOM"
mkdir -p "$CONTROL_HOME/state" "$CONTROL_HOME/data/$PROD_ID"
fm_git_worktree "$PROD_PROJ" "$PROD_WT" "$PROD_ID" \
  || fail "could not create the production-shape worktree"
cat > "$CONTROL_HOME/data/$PROD_ID/brief.md" <<EOF
# Task
## Captain's intent
Prove that a relaunched worker reads its instructions.

## Firstmate spec
Reply with exactly $RELAUNCH_TOKEN and nothing else.
Do not edit any file.
EOF

# open_pane <id> <cwd> <project>: one workspace and one task record; sets PANE.
open_pane() {
  local id=$1 cwd=$2 project=$3 ws
  ws=$(lab workspace create --cwd "$cwd" --label "fm-$id" --no-focus) \
    || fail "could not create the isolated workspace for $id"
  PANE=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') \
    || fail "workspace create did not return a pane id for $id"
  cat > "$CONTROL_HOME/state/$id.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$id
worktree=$cwd
project=$project
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
}

open_pane "$PROD_ID" "$PROD_WT" "$PROD_PROJ"
PROD_PANE=$PANE
open_pane "$COLOR_ID" "$ROOT" "$ROOT"
COLOR_PANE=$PANE

CLAUDE_LAUNCH="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'"
lab pane run "$PROD_PANE" "$CLAUDE_LAUNCH" >/dev/null \
  || fail "could not launch $SUBJECT in the production-shape pane"
lab pane run "$COLOR_PANE" "FORCE_COLOR=3 COLORTERM=truecolor TERM=xterm-256color $CLAUDE_LAUNCH" >/dev/null \
  || fail "could not launch $SUBJECT in the forced-truecolor pane"

control() {  # <fm-control arguments...>
  FM_HOME="$CONTROL_HOME" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

wait_idle_composer() {  # <pane> <shape>
  local pane=$1 i=0 trusted=0 screen st
  while [ "$i" -lt 60 ]; do
    screen=$(lab pane read "$pane" --source visible 2>/dev/null || true)
    case "$screen" in
      *'bypass permissions on'*)
        # The composer footer means Claude is past any folder-trust prompt. Herdr
        # can report the agent idle while that prompt is still up, so the wait
        # keys off the rendered composer rather than the native status alone.
        st=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
        case "$st" in idle|done) return 0 ;; esac
        ;;
      *'Yes, I trust this folder'*)
        # A fresh checkout path stops on Claude's folder-trust prompt, which the
        # pre-send proof would read as a non-empty composer. Accept it once and
        # keep waiting for a real idle composer; the accepted dialog stays in the
        # viewport. The prompt preselects "No, exit", so move to "Yes" before
        # confirming; a bare Enter quits Claude.
        if [ "$trusted" = 0 ]; then
          trusted=1
          lab pane send-keys "$pane" down enter >/dev/null \
            || fail "could not accept Claude's folder-trust prompt in the $2 pane"
        fi
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  fail "$SUBJECT never rendered an idle composer in the $2 pane"
}

wait_agent_settled() {  # <pane>
  local i=0 st
  while [ "$i" -lt 45 ]; do
    st=$(lab agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in idle|done) return 0 ;; esac
    i=$((i + 1))
    sleep 1
  done
}

wait_rendered() {  # <pane> <text> <occurrences> <seconds>
  local i=0 screen
  while [ "$i" -lt "$4" ]; do
    screen=$(lab pane read "$1" --source recent --lines 200 2>/dev/null || true)
    [ "$(printf '%s\n' "$screen" | grep -F -c "$2" || true)" -lt "$3" ] || return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# A human's typed slash command must survive a lifecycle command: the public
# pre-send guard refuses by name, types nothing, and leaves the agent running.
# The pass line records whether the draft was drawn below the default ghost
# ceiling, the shape that used to read as an empty composer.
check_pending_draft_refusal() {  # <id> <pane> <shape>
  local id=$1 pane=$2 shape=$3 target="$SESSION:$2" out row='' screen style i=0
  fm_backend_herdr_send_literal "$target" /compact \
    || fail "$SUBJECT: could not type a draft into the $shape pane"
  while [ "$i" -lt 20 ]; do
    sleep 1
    row=$(lab pane read "$pane" --source visible --format ansi 2>/dev/null | grep -F '❯' | grep -F '/compact' | head -1)
    [ -z "$row" ] || break
    i=$((i + 1))
  done
  if [ -z "$row" ]; then
    lab pane read "$pane" --source visible >&2 || true
    fail "$SUBJECT: the typed /compact draft never rendered in the $shape composer"
  fi
  case "$(printf '%s\n' "$row" | fm_composer_strip_ghost)" in
    *'/compact'*) style='above the default ghost ceiling' ;;
    *) style='below the default ghost ceiling' ;;
  esac
  if out=$(control "$id" exit); then
    fail "$SUBJECT: fm-control exit typed over a pending /compact draft in the $shape pane: $out"
  fi
  case "$out" in
    *'composer visibly holds pending text'*) ;;
    *) fail "$SUBJECT: fm-control exit did not name the pending draft in the $shape pane: $out" ;;
  esac
  [ ! -e "$CONTROL_HOME/state/$id.control-exit" ] \
    || fail "$SUBJECT: a refused exit left a deliberate-exit marker in the $shape pane"
  [ "$(fm_backend_herdr_agent_state "$target")" = alive ] \
    || fail "$SUBJECT: a refused exit did not leave the $shape agent running"
  screen=$(lab pane read "$pane" --source visible 2>/dev/null || true)
  case "$screen" in
    *'/compact/exit'*) fail "$SUBJECT: the exit command was concatenated onto the $shape draft" ;;
  esac
  fm_backend_herdr_composer_clear "$target" /compact "$(fm_backend_herdr_composer_identity "$target")" \
    || fail "$SUBJECT: could not clear the draft from the $shape composer"
  pass "live Herdr submit confirm: $SUBJECT fm-control exit refuses a pending /compact draft by name in the $shape shape (draft drawn $style)"
}

# /compact on a fresh conversation has a deterministic, token-free outcome.
# Its handler response proves submission; an empty composer alone cannot.
check_compact() {  # <pane> <shape>
  local verdict
  verdict=$(fm_backend_herdr_send_text_submit "$SESSION:$1" /compact 3 0.4 1.2)
  [ "$verdict" != send-failed ] || fail "$SUBJECT refused /compact in the $2 shape"
  wait_rendered "$1" 'Not enough messages to compact.' 1 10 \
    || fail "$SUBJECT never handled the fresh-session /compact in the $2 shape (submit reported '$verdict')"
  pass "live Herdr submit confirm: $SUBJECT executes /compact in the $2 shape"
}

# Exit must go through the lifecycle command, including its pre-send guard
# and authoritative agent-state postcondition, not just the submit helper.
check_public_exit() {  # <id> <pane> <shape>
  local id=$1 pane=$2 shape=$3 out state
  wait_agent_settled "$pane"
  out=$(control "$id" exit) \
    || fail "$SUBJECT: fm-control exit refused in the $shape shape: $out"
  case "$out" in
    *"stopped $id"*) ;;
    *) fail "$SUBJECT: exit did not report a verified stop in the $shape shape: $out" ;;
  esac
  state=$(fm_backend_herdr_agent_state "$SESSION:$pane")
  [ "$state" = dead ] || fail "$SUBJECT: exit returned in the $shape shape but agent state is '$state'"
  lab pane get "$pane" >/dev/null || fail "exit removed the $shape endpoint it must preserve"
  pass "live Herdr submit confirm: $SUBJECT fm-control exit stops the $shape shape and preserves its endpoint"
}

wait_idle_composer "$PROD_PANE" production
wait_idle_composer "$COLOR_PANE" forced-truecolor
CHECKED=1

# --- production shape -------------------------------------------------------

check_pending_draft_refusal "$PROD_ID" "$PROD_PANE" production
check_compact "$PROD_PANE" production

# Relaunch replaces the agent in the same endpoint through fm-spawn's own
# launch. The token lives only in the instructions the replacement must read.
out=$(control "$PROD_ID" relaunch --note "Live guard relaunch; follow the Firstmate spec.") \
  || fail "$SUBJECT: fm-control relaunch refused in the production shape: $out"
case "$out" in
  *"relaunched $PROD_ID harness=claude"*"endpoint=$SESSION:$PROD_PANE "*) ;;
  *) fail "$SUBJECT: relaunch did not report a replacement in the same endpoint: $out" ;;
esac
[ "$(fm_backend_herdr_agent_state "$SESSION:$PROD_PANE")" = alive ] \
  || fail "$SUBJECT: relaunch returned but no agent is running in the production endpoint"
wait_rendered "$PROD_PANE" "$RELAUNCH_TOKEN" 1 180 \
  || fail "$SUBJECT: the relaunched production worker never acknowledged its instructions"
pass "live Herdr submit confirm: $SUBJECT fm-control relaunch replaces the production shape in its endpoint and the replacement reads its instructions"

check_public_exit "$PROD_ID" "$PROD_PANE" production

# --- forced-truecolor shape -------------------------------------------------

check_pending_draft_refusal "$COLOR_ID" "$COLOR_PANE" forced-truecolor
check_compact "$COLOR_PANE" forced-truecolor

TARGET="$SESSION:$COLOR_PANE"
TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against $SUBJECT"
[ "$verdict" = empty ] \
  || fail "$SUBJECT: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
wait_rendered "$COLOR_PANE" "$TOKEN" 2 45 \
  || fail "$SUBJECT: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: $SUBJECT reports empty and renders the requested reply in isolated session $SESSION"

# Away-mode digests start with U+2063, which Claude's composer read-back drops.
# The pre-Enter proof must still accept the rest of the payload.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
wait_agent_settled "$COLOR_PANE"
OP_TOKEN="FMHERDROPPONG$$_$RANDOM"
op_text=
fm_operational_input_encode away-supervisor "Reply with exactly $OP_TOKEN and nothing else." op_text \
  || fail "could not encode an away-supervisor payload"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$op_text" 3 0.4 0.4) \
  || fail "send_text_submit failed to run an operational payload against $SUBJECT"
[ "$verdict" = empty ] \
  || fail "$SUBJECT: a landed U+2063 operational payload must confirm empty, got '$verdict'"
wait_rendered "$COLOR_PANE" "$OP_TOKEN" 2 45 \
  || fail "$SUBJECT: operational submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: $SUBJECT submits a U+2063 away-supervisor payload whose read-back drops the mark"

check_public_exit "$COLOR_ID" "$COLOR_PANE" forced-truecolor

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
