#!/usr/bin/env bash
# tests/fm-omp-composer-box-live-e2e.test.sh - the live omp box-composer guard
# (live-harness-optin family; task fm-omp-composer-unknown-blocks-control).
#
# omp draws its composer in the shape `composer.shape` selects. Firstmate pins
# `borderless` for every worker it launches (.omp/fm-session-overlay.yml), but a
# running omp live-reloads the overlay files it was started with: when the
# tracked overlay stopped carrying the pin, every already-running worker fell
# back to the captain's own `box` shape, which carries its status line in the
# top border and folds the editor's last row into the bottom border. The
# classifier read that screen as `unknown`, so fm-control exit and relaunch
# refused every idle worker ("composer state is 'unknown', not proven empty").
# That shape is vendor-rendered, so per .agents/skills/firstmate-coding-guidelines
# the portable fixtures in tests/fm-composer-lib.test.sh are not enough on
# their own: this guard launches the INSTALLED omp idle in an isolated Herdr lab
# with the box shape pinned, and requires, through the production Herdr adapter
# and the public fm-control lifecycle commands:
#   - the idle pane really is the box shape (status in the top border);
#   - an empty composer reads `empty`, and a typed draft reads `pending` and
#     makes fm-control exit refuse by name without typing anything;
#   - fm-control exit then stops the idle worker and preserves its endpoint.
# It fails naming omp and `omp --version`.
#
# Reading an idle screen and exiting submit no prompt, so no model tokens are
# spent and the gate is default-on wherever omp, herdr, and jq are installed
# (fm_live_gate): FM_OMP_COMPOSER_BOX_LIVE=1 forces it (an absent tool then
# fails instead of skipping) and =0 disables it. The relaunch proof starts a
# real worker on the brief, which does spend tokens, so it stays opt-in behind
# FM_OMP_COMPOSER_BOX_LIVE_RELAUNCH=1.
# Refresh docs/verification/runtime-backends.md ("omp box composer") from this
# guard's output after any omp upgrade.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49M05K2KST38EB9PT2GA4QJ/tests/lib.sh"

ROOT="/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49M05K2KST38EB9PT2GA4QJ"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

LIVE_CONTROLS=FM_OMP_COMPOSER_BOX_LIVE
if [ "${FM_OMP_COMPOSER_BOX_LIVE_RELAUNCH:-0}" = 1 ]; then
  LIVE_CONTROLS="$LIVE_CONTROLS,FM_OMP_COMPOSER_BOX_LIVE_RELAUNCH"
fi
fm_live_gate default-on "$LIVE_CONTROLS" herdr jq omp

[ -x "$LAB_HELPER" ] || fail "FM_OMP_COMPOSER_BOX_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name omp-composer-box-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-omp-composer-box-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
TASK_ID="ompbox$$"
LAUNCH_DIR=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ -n "${PANE:-}" ]; then
    env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane read "$PANE" --source visible | tee "$EVIDENCE_DIR/$RUN_LABEL-failed-screen.txt"
    env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" agent get "$PANE" | tee "$EVIDENCE_DIR/$RUN_LABEL-failed-agent.json"
    env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane get "$PANE" | tee "$EVIDENCE_DIR/$RUN_LABEL-failed-pane.json"
  fi
  fm_test_cleanup
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  # fm-spawn write-protects the task's git hook directory in the control home.
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  if [ -n "$LAUNCH_DIR" ]; then
    rm -rf "$LAUNCH_DIR"
  fi
  rm -rf "/tmp/fm-$TASK_ID" "$TMP_ROOT"
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

evidence_capture() {
  local label=$1
  lab pane read "$PANE" --source visible > "$EVIDENCE_DIR/$RUN_LABEL-$label.txt"
  lab pane read "$PANE" --source visible --format ansi > "$EVIDENCE_DIR/$RUN_LABEL-$label.ansi"
}

VERSION=$(PATH="$ORIGINAL_PATH" omp --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
SUBJECT="omp ($VERSION) on $HERDR_VER"

# The session overlay with its composer pin swapped for the box shape: the same
# posture every worker launches with, minus the one setting under test.
BOX_OVERLAY="$TMP_ROOT/box-overlay.yml"
sed 's/^  shape: borderless$/  shape: box/' "$ROOT/.omp/fm-session-overlay.yml" > "$BOX_OVERLAY"

CONTROL_HOME="$TMP_ROOT/control-home"
PROJECT="$TMP_ROOT/proj"
WORKTREE="$TMP_ROOT/wt"
"$ROOT/bin/fm-lab-home.sh" create "$CONTROL_HOME" || fail "lab home creation failed"
mkdir -p "$CONTROL_HOME/state" "$CONTROL_HOME/data/$TASK_ID"
CONTROL_HOME_ROOT=$(cd "$CONTROL_HOME" 2>/dev/null && pwd -P) || CONTROL_HOME_ROOT=$CONTROL_HOME
if command -v shasum >/dev/null 2>&1; then
  CONTROL_HOME_HASH=$(printf '%s' "$CONTROL_HOME_ROOT" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  CONTROL_HOME_HASH=$(printf '%s' "$CONTROL_HOME_ROOT" | sha256sum | awk '{print $1}')
else
  fail "test needs shasum or sha256sum"
fi
LAUNCH_DIR="/tmp/fm-$TASK_ID+$CONTROL_HOME_HASH"
fm_git_worktree "$PROJECT" "$WORKTREE" "$TASK_ID" \
  || fail "could not create the task worktree"
cat > "$CONTROL_HOME/data/$TASK_ID/brief.md" <<'EOF'
# Task
## Captain's intent
Verify that an idle box-shaped omp worker can be safely relaunched.

## Firstmate spec
Do not edit any file.
EOF

ws=$(lab workspace create --cwd "$WORKTREE" --label "fm-$TASK_ID" --no-focus) \
  || fail "could not create the isolated workspace"
PANE=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
cat > "$CONTROL_HOME/state/$TASK_ID.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$TASK_ID
worktree=$WORKTREE
project=$PROJECT
harness=omp
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
TARGET="$SESSION:$PANE"

lab pane run "$PANE" "env PI_CODING_AGENT_DIR='$PI_CODING_AGENT_DIR' OMP_SKIP_SETUP=1 FM_OMP_HARNESS=omp omp --config '$BOX_OVERLAY' --auto-approve --cwd '$WORKTREE'" >/dev/null \
  || fail "could not launch $SUBJECT in the isolated pane"

control() {  # <fm-control arguments...>
  FM_HOME="$CONTROL_HOME" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# The box shape is the proof's subject: wait until the idle composer is drawn
# with its status in the top border, so a launch that still shows a splash or a
# different shape fails here by name instead of passing vacuously.
i=0
screen=
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  if printf '%s\n' "$screen" | grep -Eq '^╭── (π|󰵗) [>·] ' \
    && [ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] \
    && [ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ]; then
    break
  fi
  i=$((i + 1))
  sleep 1
done
printf '%s\n' "$screen" | grep -Eq '^╭── (π|󰵗) [>·] ' || {
  printf '%s\n' "$screen" >&2
  fail "$SUBJECT never drew its box composer with the status line in the top border"
}
printf '%s\n' "$screen" | grep -Eq '^╰─ .* ─╯$' \
  || fail "$SUBJECT drew no folded last row (╰─ … ─╯) under its box status border"
pass "live omp box composer: $SUBJECT draws the box shape (status in the top border, folded last row) in isolated session $SESSION"

state=$(fm_backend_herdr_composer_state "$TARGET")
[ "$state" = empty ] \
  || fail "$SUBJECT: an idle empty box composer read '$state', not empty"
evidence_capture initial-render
[ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] \
  || fail "$SUBJECT: the initial empty box composer has no live agent"
evidence_capture idle
printf "initial composer=%s agent=%s endpoint=%s\n" "$state" "$(fm_backend_herdr_agent_state "$TARGET")" "$TARGET"
pass "live omp box composer: $SUBJECT idle empty composer reads empty through the production Herdr adapter"


# Drive consumer-visible draft collisions in the actual omp UI.
plain_caps=$'styled=0\ncursor=0\nidentity=0'
styled_caps=$'styled=1\ncursor=0\nidentity=0'
plain_screen=$(lab pane read "$PANE" --source visible)
printf 'Initial plain-capture state=%s\n' "$(fm_composer_classify_screen "$plain_caps" "$plain_screen")"
for label in hint-copy shell-glyph agent-glyph border-text wrapped-draft; do
  case "$label" in
    hint-copy) draft='⇧⇥ to change thinking effort' ;;
    shell-glyph) draft='>' ;;
    agent-glyph) draft='❯' ;;
    border-text) draft='─ typed draft ─' ;;
    wrapped-draft) draft='one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three twenty-four twenty-five twenty-six' ;;
  esac
  fm_backend_herdr_send_literal "$TARGET" "$draft" || fail "could not type $label"
  i=0
  while [ "$i" -lt 20 ]; do
    state=$(fm_backend_herdr_composer_state "$TARGET")
    [ "$state" != pending ] || break
    i=$((i+1)); sleep 1
  done
  [ "$state" = pending ] || fail "$label real typed input read $state"
  raw=$(lab pane read "$PANE" --source visible --format ansi)
  plain=$(lab pane read "$PANE" --source visible)
  extracted=$(fm_composer_extract_selected_content "$styled_caps" "$raw")
  [ "$extracted" = "$draft" ] || fail "$label extraction lost typed draft: '$extracted'"
  if [ "$label" = hint-copy ]; then
    plain_state=$(fm_composer_classify_screen "$plain_caps" "$plain")
    plain_content=$(fm_composer_extract_selected_content "$plain_caps" "$plain")
    [ "$plain_state" = unknown ] || fail "ambiguous unstyled hint read $plain_state"
    [ "$plain_content" = "$draft" ] || fail "unstyled hint draft was discarded"
    printf 'hint-copy styled=pending plain=%s plain-content=%s\n' "$plain_state" "$plain_content"
  fi
  if out=$(control "$TASK_ID" exit); then fail "$label exit unexpectedly allowed: $out"; fi
  case "$out" in *'composer visibly holds pending text'*) ;; *) fail "$label wrong refusal: $out" ;; esac
  raw_after=$(lab pane read "$PANE" --source visible --format ansi)
  [ "$(fm_composer_extract_selected_content "$styled_caps" "$raw_after")" = "$draft" ] || fail "$label refusal changed draft"
  [ ! -e "$CONTROL_HOME/state/$TASK_ID.control-exit" ] || fail "$label refusal wrote exit marker"
  printf '%s\n' "$out"
  evidence_capture "$label"
  printf 'ok - actual omp %s draft preserved; exit refused; extracted=%s\n' "$label" "$extracted"
  lab pane send-keys "$PANE" ctrl+u >/dev/null || fail "clear $label failed"
  i=0
  while [ "$i" -lt 20 ]; do
    state=$(fm_backend_herdr_composer_state "$TARGET")
    [ "$state" != empty ] || break
    i=$((i+1)); sleep 1
  done
  [ "$state" = empty ] || fail "$label clearing did not restore empty composer"
done

fm_backend_herdr_send_literal "$TARGET" 'unsent draft text' \
  || fail "$SUBJECT: could not type a draft into the box composer"
i=0
while [ "$i" -lt 20 ]; do
  sleep 1
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in *'unsent draft text'*) break ;; esac
  i=$((i + 1))
done
case "$screen" in
  *'unsent draft text'*) ;;
  *) printf '%s\n' "$screen" >&2; fail "$SUBJECT: the typed draft never rendered in the box composer" ;;
esac
state=$(fm_backend_herdr_composer_state "$TARGET")
[ "$state" = pending ] \
  || fail "$SUBJECT: a box composer holding a typed draft read '$state', not pending"
if out=$(control "$TASK_ID" exit); then
  fail "$SUBJECT: fm-control exit typed over a pending draft in the box composer: $out"
fi
case "$out" in
  *'composer visibly holds pending text'*) ;;
  *) fail "$SUBJECT: fm-control exit did not name the pending draft in the box composer: $out" ;;
esac
[ ! -e "$CONTROL_HOME/state/$TASK_ID.control-exit" ] \
  || fail "$SUBJECT: a refused exit left a deliberate-exit marker"
screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
case "$screen" in
  *'unsent draft text/quit'*|*'unsent draft text /quit'*) fail "$SUBJECT: the exit command was concatenated onto the draft" ;;
esac
printf "%s\n" "$out"
evidence_capture draft-refused
pass "live omp box composer: $SUBJECT reads a typed draft pending and fm-control exit refuses it by name without typing"

# Clear the draft (Ctrl+U clears the composer line) and prove it reads empty
# again before the real exit.
lab pane send-keys "$PANE" ctrl+u >/dev/null || fail "$SUBJECT: could not clear the draft"
i=0
state=
while [ "$i" -lt 20 ]; do
  state=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$state" != empty ] || break
  i=$((i + 1))
  sleep 1
done
[ "$state" = empty ] || fail "$SUBJECT: the cleared box composer read '$state', not empty"
[ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] \
  || fail "$SUBJECT: the cleared empty box composer has no live agent"

out=$(control "$TASK_ID" exit) \
  || fail "$SUBJECT: fm-control exit refused an idle box composer: $out"
case "$out" in
  *"stopped $TASK_ID"*) ;;
  *) fail "$SUBJECT: exit did not report a verified stop: $out" ;;
esac
[ "$(fm_backend_herdr_agent_state "$TARGET")" = dead ] \
  || fail "$SUBJECT: exit returned but the agent is still running"
lab pane get "$PANE" >/dev/null || fail "exit removed the endpoint it must preserve"
printf "%s\n" "$out"
evidence_capture stopped
pass "live omp box composer: $SUBJECT fm-control exit stops the idle box-shaped worker and preserves its endpoint"

if [ "${FM_OMP_COMPOSER_BOX_LIVE_RELAUNCH:-0}" = 1 ]; then
  # A second box-shaped launch, then the relaunch through fm-spawn's own launch.
  lab pane run "$PANE" "env PI_CODING_AGENT_DIR='$PI_CODING_AGENT_DIR' OMP_SKIP_SETUP=1 FM_OMP_HARNESS=omp omp --config '$BOX_OVERLAY' --auto-approve --cwd '$WORKTREE'" >/dev/null \
    || fail "could not relaunch $SUBJECT in the box shape"
  i=0
  while [ "$i" -lt 60 ]; do
    state=$(fm_backend_herdr_composer_state "$TARGET")
    agent=$(fm_backend_herdr_agent_state "$TARGET")
    screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
    if [ "$state" = empty ] && [ "$agent" = alive ] \
      && printf '%s\n' "$screen" | grep -Eq '^╭── (π|󰵗) [>·] ' \
      && printf '%s\n' "$screen" | grep -Eq '^╰─ .* ─╯$'; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  [ "$i" -lt 60 ] \
    || fail "$SUBJECT: the second launch never proved a live agent with an empty box composer (agent='$agent', composer='$state')"
  evidence_capture pre-relaunch
printf "relaunch precondition composer=%s agent=%s endpoint=%s\n" "$state" "$agent" "$TARGET"
  out=$(control "$TASK_ID" relaunch --harness claude --note "Live guard omp-to-Claude transition.") \
    || fail "$SUBJECT: fm-control relaunch refused an idle box composer: $out"
  case "$out" in
    *"relaunched $TASK_ID harness=claude"*"endpoint=$TARGET "*) ;;
    *) fail "$SUBJECT: relaunch did not report a replacement in the same endpoint: $out" ;;
  esac
  [ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] \
    || fail "$SUBJECT: relaunch returned but no agent is running in the preserved endpoint"
  lab pane get "$PANE" >/dev/null || fail "relaunch removed the endpoint it must preserve"
  printf "%s\n" "$out"
evidence_capture replacement
lab agent get "$PANE" | tee "$EVIDENCE_DIR/$RUN_LABEL-replacement-agent.json"
  lab pane get "$PANE" | tee "$EVIDENCE_DIR/$RUN_LABEL-replacement-pane.json"
  sleep 3
  evidence_capture replacement-rendered
  pass "live omp box composer: $SUBJECT fm-control relaunch replaces the box-shaped worker with a live agent in the same endpoint"
else
  printf 'skip: live omp box composer relaunch: opt-in; set FM_OMP_COMPOSER_BOX_LIVE_RELAUNCH=1 to run\n'
fi
