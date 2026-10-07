#!/usr/bin/env bash
# tests/fm-claude-titled-composer-live-e2e.test.sh - the live claude titled-top-
# border composer guard (live-harness-optin family; task
# fm-claude-titled-composer-unknown).
#
# Claude Code draws its session title (`--name`, `/rename`, a hook-supplied
# title, or the title it generates from the first prompt) INSIDE the prompt
# box's top rule: `──── <title> ─`. That row is no longer a solid rule, so the
# cursorless profiles read the composer as `unknown`, every steer's doorbell
# was skipped, and fm-control exit and relaunch refused an idle worker
# ("composer state is 'unknown', not proven empty"). That shape is
# vendor-rendered, so per .agents/skills/firstmate-coding-guidelines the
# portable fixtures in tests/fm-composer-lib.test.sh are not enough on their
# own: this guard launches the INSTALLED claude idle with a session name in a
# guarded Herdr lab and requires, through the production Herdr adapter and the
# public fm-control lifecycle commands:
#   - the idle pane really draws a titled top border over the `❯` row;
#   - an empty composer reads `empty`, and a typed draft reads `pending` and
#     makes fm-control exit refuse by name without typing anything;
#   - fm-control exit then stops the idle worker and preserves its endpoint.
# It fails naming claude and `claude --version`.
#
# Launching idle and exiting submit no prompt, so no model tokens are spent and
# the gate is default-on wherever claude, herdr, jq, node, and treehouse-free git are
# installed (fm_live_gate): FM_CLAUDE_TITLED_COMPOSER_LIVE=1 forces it (an
# absent tool then fails instead of skipping) and =0 disables it.
# FM_CLAUDE_TITLED_COMPOSER_LIVE_SEND=1 adds the real fm-send doorbell proof,
# which submits a prompt and so spends tokens, and
# FM_CLAUDE_TITLED_COMPOSER_LIVE_RELAUNCH=1 adds the fm-control relaunch proof,
# which starts a real worker on the brief and so spends tokens too.
# Refresh docs/verification/runtime-backends.md ("claude titled top border")
# from this guard's output after any claude upgrade.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

LIVE_CONTROLS=FM_CLAUDE_TITLED_COMPOSER_LIVE
if [ "${FM_CLAUDE_TITLED_COMPOSER_LIVE_SEND:-0}" = 1 ]; then
  LIVE_CONTROLS="$LIVE_CONTROLS,FM_CLAUDE_TITLED_COMPOSER_LIVE_SEND"
fi
if [ "${FM_CLAUDE_TITLED_COMPOSER_LIVE_RELAUNCH:-0}" = 1 ]; then
  LIVE_CONTROLS="$LIVE_CONTROLS,FM_CLAUDE_TITLED_COMPOSER_LIVE_RELAUNCH"
fi
fm_live_gate default-on "$LIVE_CONTROLS" herdr jq claude git node

[ -x "$LAB_HELPER" ] || fail "FM_CLAUDE_TITLED_COMPOSER_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name claude-titled-live)
mkdir -p "$ROOT/.no-mistakes/test-tmp" || fail "could not create the worktree test scratch directory"
TMP_ROOT=$(mktemp -d "$ROOT/.no-mistakes/test-tmp/fm-claude-titled-live.XXXXXX") \
  || fail "could not allocate the isolated test root"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
TASK_ID="claudetitled$$"

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

SOURCE_CONFIG_ROOT=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SOURCE_CONFIG_JSON="$HOME/.claude.json"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  SOURCE_CONFIG_JSON="$CLAUDE_CONFIG_DIR/.claude.json"
fi
if [ -e "$SOURCE_CONFIG_ROOT/.config.json" ] || [ -L "$SOURCE_CONFIG_ROOT/.config.json" ]; then
  SOURCE_CONFIG_JSON="$SOURCE_CONFIG_ROOT/.config.json"
fi
SOURCE_AUTH_ROOT=${CLAUDE_SECURESTORAGE_CONFIG_DIR-${CLAUDE_CONFIG_DIR:-}}
SOURCE_AUTH_DIR=${SOURCE_AUTH_ROOT:-$HOME/.claude}
export CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config"
export FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/herdr-lab-state"
export TMPDIR="$TMP_ROOT/tmp"
export CLAUDE_SECURESTORAGE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"
mkdir -m 700 "$CLAUDE_CONFIG_DIR" "$TMPDIR" \
  || fail "could not create the private Claude configuration"

copy_config_file() {
  local source=$1 destination=$2
  if [ -e "$source" ] || [ -L "$source" ]; then
    [ -f "$source" ] && [ -r "$source" ] \
      || fail "Claude source configuration is not a readable file: $source"
    (umask 077; cat "$source" > "$destination") \
      || fail "could not copy Claude configuration into the disposable store"
  fi
}
copy_config_file "$SOURCE_CONFIG_JSON" "$CLAUDE_CONFIG_DIR/.claude.json"
copy_config_file "$SOURCE_CONFIG_ROOT/settings.json" "$CLAUDE_CONFIG_DIR/settings.json"
copy_config_file "$SOURCE_AUTH_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.credentials.json"

if [ "$(uname -s)" = Darwin ]; then
  KEYCHAIN_SERVICE=Claude\ Code
  if [ -n "${CLAUDE_CODE_CUSTOM_OAUTH_URL:-}" ]; then
    KEYCHAIN_SERVICE="$KEYCHAIN_SERVICE-custom-oauth"
  fi
  KEYCHAIN_SERVICE="$KEYCHAIN_SERVICE-credentials"
  if [ -n "$SOURCE_AUTH_ROOT" ]; then
    SOURCE_AUTH_HASH=$(node -e \
      "process.stdout.write(require('crypto').createHash('sha256').update(process.argv[1].normalize('NFC')).digest('hex').slice(0,8))" "$SOURCE_AUTH_ROOT") \
      || fail "could not identify the source Claude Keychain entry"
    KEYCHAIN_SERVICE="$KEYCHAIN_SERVICE-$SOURCE_AUTH_HASH"
  fi
  KEYCHAIN_ACCOUNT=${USER:-$(id -un)}
  if ! [[ "$KEYCHAIN_ACCOUNT" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    KEYCHAIN_ACCOUNT=claude-code-user
  fi
  if (umask 077; security find-generic-password -a "$KEYCHAIN_ACCOUNT" -w -s "$KEYCHAIN_SERVICE" \
      > "$CLAUDE_CONFIG_DIR/keychain-credentials.json" 2>/dev/null); then
    copy_config_file "$CLAUDE_CONFIG_DIR/keychain-credentials.json" "$CLAUDE_CONFIG_DIR/.credentials.json"
  fi
  rm -f "$CLAUDE_CONFIG_DIR/keychain-credentials.json"
fi

[ -f "$CLAUDE_CONFIG_DIR/settings.json" ] \
  || (umask 077; printf '{}\n' > "$CLAUDE_CONFIG_DIR/settings.json")
[ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ] \
  || (umask 077; printf '{}\n' > "$CLAUDE_CONFIG_DIR/.credentials.json")
(umask 077; jq --slurpfile credentials "$CLAUDE_CONFIG_DIR/.credentials.json" '
  .env = (.env // {}) |
  .env.CLAUDE_CONFIG_DIR = env.CLAUDE_CONFIG_DIR |
  .env.CLAUDE_SECURESTORAGE_CONFIG_DIR = env.CLAUDE_CONFIG_DIR |
  ((env.CLAUDE_CODE_OAUTH_TOKEN | select(. != "")) //
    (.env.CLAUDE_CODE_OAUTH_TOKEN | select(. != "")) //
    $credentials[0].claudeAiOauth.accessToken // null) as $token |
  if ($token | type) == "string" and ($token | length) > 0 then
    .env.CLAUDE_CODE_OAUTH_TOKEN = $token
  else . end
' "$CLAUDE_CONFIG_DIR/settings.json" > "$CLAUDE_CONFIG_DIR/settings-copy.json") \
  || fail "could not retain Claude authentication in the disposable settings"
mv "$CLAUDE_CONFIG_DIR/settings-copy.json" "$CLAUDE_CONFIG_DIR/settings.json" \
  || fail "could not install the disposable Claude settings"
printf -v CLAUDE_CONFIG_QUOTED '%q' "$CLAUDE_CONFIG_DIR"
CLAUDE_LAUNCH_PREFIX="CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_QUOTED CLAUDE_SECURESTORAGE_CONFIG_DIR=$CLAUDE_CONFIG_QUOTED"

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
SUBJECT="claude ($VERSION) on $HERDR_VER"

# The title text is the doorbell's own first words, punctuation stripped - the
# way a worker whose first prompt was a doorbell line got titled in the field.
TITLE='Firstmate operational input waiting read Users probe'

CONTROL_HOME="$TMP_ROOT/control-home"
PROJECT="$TMP_ROOT/proj"
WORKTREE="$TMP_ROOT/wt"
mkdir -p "$CONTROL_HOME/state" "$CONTROL_HOME/data/$TASK_ID"
fm_git_worktree "$PROJECT" "$WORKTREE" "$TASK_ID" \
  || fail "could not create the task worktree"
"$ROOT/bin/fm-claude-trust.sh" "$WORKTREE" "$PROJECT" >/dev/null \
  || fail "could not pre-register Claude workspace trust for the lab worktree"
cat > "$CONTROL_HOME/data/$TASK_ID/brief.md" <<'EOF'
# Task
## Captain's intent
Verify that an idle titled-border claude worker can be steered and exited safely.

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
TARGET="$SESSION:$PANE"

LAUNCH_FLAGS=
if [ "${FM_CLAUDE_TITLED_COMPOSER_LIVE_SEND:-0}" = 1 ]; then
  # Only the doorbell proof needs a worker that can read and move inbox files
  # outside its worktree without a permission prompt.
  LAUNCH_FLAGS=' --dangerously-skip-permissions'
fi
lab pane run "$PANE" "$CLAUDE_LAUNCH_PREFIX claude -n '$TITLE'$LAUNCH_FLAGS" >/dev/null \
  || fail "could not launch $SUBJECT in the isolated pane"

control() {  # <fm-control arguments...>
  FM_HOME="$CONTROL_HOME" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# titled_over_prompt: 0 when the screen shows a rule carrying a title directly
# above the `❯` row (the shape under test), never a plain rule.
titled_over_prompt() {
  printf '%s\n' "$1" | awk '
    /^─{8,} .* ─$/ { titled = NR; next }
    /^❯/ { if (titled && NR == titled + 1) found = 1 }
    END { exit found ? 0 : 1 }'
}

# Wait for the titled border and Herdr's live-agent registration: a splash,
# a plain-border launch, or an unregistered agent must never satisfy the
# guard's lifecycle precondition.
i=0
screen=
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  if titled_over_prompt "$screen" \
    && [ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ]; then
    break
  fi
  i=$((i + 1))
  sleep 1
done
titled_over_prompt "$screen" || {
  printf '%s\n' "$screen" >&2
  fail "$SUBJECT never drew a session title inside its prompt box's top border"
}
pass "live claude titled border: $SUBJECT draws the session title in the prompt box's top border in isolated session $SESSION"

i=0
state=
while [ "$i" -lt 20 ]; do
  state=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$state" = empty ] && break
  i=$((i + 1))
  sleep 1
done
[ "$state" = empty ] \
  || fail "$SUBJECT: an idle empty titled-border composer read '$state', not empty"
[ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] \
  || fail "$SUBJECT: the initial empty titled-border composer has no live agent"
pass "live claude titled border: $SUBJECT idle empty composer reads empty through the production Herdr adapter"

fm_backend_herdr_send_literal "$TARGET" 'unsent draft text' \
  || fail "$SUBJECT: could not type a draft into the titled-border composer"
i=0
while [ "$i" -lt 20 ]; do
  sleep 1
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in *'unsent draft text'*) break ;; esac
  i=$((i + 1))
done
case "$screen" in
  *'unsent draft text'*) ;;
  *) printf '%s\n' "$screen" >&2; fail "$SUBJECT: the typed draft never rendered in the titled-border composer" ;;
esac
titled_over_prompt "$screen" \
  || fail "$SUBJECT: the border lost its title while a draft was typed, so the draft check proves nothing"
state=$(fm_backend_herdr_composer_state "$TARGET")
[ "$state" = pending ] \
  || fail "$SUBJECT: a titled-border composer holding a typed draft read '$state', not pending"
if out=$(control "$TASK_ID" exit); then
  fail "$SUBJECT: fm-control exit typed over a pending draft in the titled-border composer: $out"
fi
case "$out" in
  *'composer visibly holds pending text'*) ;;
  *) fail "$SUBJECT: fm-control exit did not name the pending draft in the titled-border composer: $out" ;;
esac
[ ! -e "$CONTROL_HOME/state/$TASK_ID.control-exit" ] \
  || fail "$SUBJECT: a refused exit left a deliberate-exit marker"
screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
case "$screen" in
  *'unsent draft text/exit'*|*'unsent draft text /exit'*) fail "$SUBJECT: the exit command was concatenated onto the draft" ;;
esac
pass "live claude titled border: $SUBJECT reads a typed draft pending and fm-control exit refuses it by name without typing"

# Clear the draft (Ctrl+U clears the composer line) and prove it reads empty
# again before the doorbell and the real exit.
lab pane send-keys "$PANE" ctrl+u >/dev/null || fail "$SUBJECT: could not clear the draft"
i=0
state=
while [ "$i" -lt 20 ]; do
  state=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$state" != empty ] || break
  i=$((i + 1))
  sleep 1
done
[ "$state" = empty ] || fail "$SUBJECT: the cleared titled-border composer read '$state', not empty"

MULTILINE_DRAFT=$'keep this unsent text\n❯'
MULTILINE_CONTENT='keep this unsent text ❯'
fm_backend_herdr_send_literal "$TARGET" "$MULTILINE_DRAFT" \
  || fail "$SUBJECT: could not type a multiline draft into the titled-border composer"
i=0
content=
while [ "$i" -lt 20 ]; do
  sleep 1
  content=$(fm_backend_herdr_composer_content "$TARGET" claude) || content=
  [ "$content" != "$MULTILINE_CONTENT" ] || break
  i=$((i + 1))
done
[ "$content" = "$MULTILINE_CONTENT" ] \
  || fail "$SUBJECT: multiline composer content lost draft rows or the later glyph: '$content'"
screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
titled_over_prompt "$screen" \
  || fail "$SUBJECT: the multiline draft no longer has a titled composer border"
state=$(fm_backend_herdr_composer_state "$TARGET")
[ "$state" = pending ] \
  || fail "$SUBJECT: a titled-border composer holding a multiline draft read '$state', not pending"
if out=$(control "$TASK_ID" exit); then
  fail "$SUBJECT: fm-control exit typed over a pending multiline draft: $out"
fi
case "$out" in
  *'composer visibly holds pending text'*) ;;
  *) fail "$SUBJECT: fm-control exit did not name the pending multiline draft: $out" ;;
esac
[ ! -e "$CONTROL_HOME/state/$TASK_ID.control-exit" ] \
  || fail "$SUBJECT: a refused multiline exit left a deliberate-exit marker"
content=$(fm_backend_herdr_composer_content "$TARGET" claude) \
  || fail "$SUBJECT: could not read multiline content after the refused exit"
[ "$content" = "$MULTILINE_CONTENT" ] \
  || fail "$SUBJECT: the refused exit changed the multiline draft: '$content'"
pass "live claude titled border: $SUBJECT retains a multiline draft and its later glyph, reads pending, and refuses exit without typing"

fm_backend_herdr_composer_clear "$TARGET" "$MULTILINE_DRAFT" "$(fm_backend_herdr_composer_identity "$TARGET")" \
  || fail "$SUBJECT: could not safely clear the multiline draft"
i=0
state=
while [ "$i" -lt 20 ]; do
  state=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$state" != empty ] || break
  i=$((i + 1))
  sleep 1
done
[ "$state" = empty ] || fail "$SUBJECT: the cleared multiline composer read '$state', not empty"
content=$(fm_backend_herdr_composer_content "$TARGET" claude) \
  || fail "$SUBJECT: could not read content after clearing the multiline draft"
[ -z "$content" ] || fail "$SUBJECT: clearing left multiline draft content: '$content'"

if [ "${FM_CLAUDE_TITLED_COMPOSER_LIVE_SEND:-0}" = 1 ]; then
  INBOX="$CONTROL_HOME/state/$TASK_ID.inbox"
  out=$(FM_HOME="$CONTROL_HOME" "$ROOT/bin/fm-send.sh" "$TASK_ID" \
    'Live guard probe: take no action beyond acknowledging this message.' 2>&1) \
    || fail "$SUBJECT: fm-send failed on an idle titled-border worker: $out"
  case "$out" in
    *'doorbell did not reach'*|*'skipping'*|*'pending text'*) fail "$SUBJECT: fm-send did not ring the idle titled-border worker: $out" ;;
  esac
  # The doorbell reached the worker when it acts on the record: the
  # acknowledgement is the move into handled/.
  i=0
  while [ "$i" -lt 180 ]; do
    if compgen -G "$INBOX/handled/*.msg" >/dev/null 2>&1; then break; fi
    i=$((i + 1))
    sleep 1
  done
  compgen -G "$INBOX/handled/*.msg" >/dev/null 2>&1 \
    || { lab pane read "$PANE" --source visible >&2 2>/dev/null || true; fail "$SUBJECT: the doorbell never reached the titled-border worker (no record in handled/ after 180s)"; }
  pass "live claude titled border: $SUBJECT fm-send doorbell reaches the titled-border worker, which acts on the record and acknowledges it"
  i=0
  state=
  while [ "$i" -lt 120 ]; do
    state=$(fm_backend_herdr_composer_state "$TARGET")
    [ "$state" = empty ] && break
    i=$((i + 1))
    sleep 1
  done
  [ "$state" = empty ] || fail "$SUBJECT: the worker did not return to an empty titled-border composer after the doorbell (read '$state')"
else
  printf 'skip: live claude titled border doorbell: opt-in; set FM_CLAUDE_TITLED_COMPOSER_LIVE_SEND=1 to run\n'
fi

out=$(control "$TASK_ID" exit) \
  || fail "$SUBJECT: fm-control exit refused an idle titled-border composer: $out"
case "$out" in
  *"stopped $TASK_ID"*) ;;
  *) fail "$SUBJECT: exit did not report a verified stop: $out" ;;
esac
[ "$(fm_backend_herdr_agent_state "$TARGET")" = dead ] \
  || fail "$SUBJECT: exit returned but the agent is still running"
lab pane get "$PANE" >/dev/null || fail "exit removed the endpoint it must preserve"
pass "live claude titled border: $SUBJECT fm-control exit stops the idle titled-border worker and preserves its endpoint"

if [ "${FM_CLAUDE_TITLED_COMPOSER_LIVE_RELAUNCH:-0}" = 1 ]; then
  # A second titled launch, then the relaunch through fm-spawn's own launch.
  lab pane run "$PANE" "$CLAUDE_LAUNCH_PREFIX claude -n '$TITLE'" >/dev/null \
    || fail "could not relaunch $SUBJECT with a session title"
  i=0
  while [ "$i" -lt 60 ]; do
    state=$(fm_backend_herdr_composer_state "$TARGET")
    agent=$(fm_backend_herdr_agent_state "$TARGET")
    screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
    if [ "$state" = empty ] && [ "$agent" = alive ] && titled_over_prompt "$screen"; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  [ "$i" -lt 60 ] \
    || fail "$SUBJECT: the second launch never proved a live agent with an empty titled-border composer (agent='$agent', composer='$state')"
  out=$(control "$TASK_ID" relaunch --note "Live guard relaunch.") \
    || fail "$SUBJECT: fm-control relaunch refused an idle titled-border composer: $out"
  case "$out" in
    *"relaunched $TASK_ID harness=claude"*"endpoint=$TARGET "*) ;;
    *) fail "$SUBJECT: relaunch did not report a replacement in the same endpoint: $out" ;;
  esac
  [ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] \
    || fail "$SUBJECT: relaunch returned but no agent is running in the preserved endpoint"
  lab pane get "$PANE" >/dev/null || fail "relaunch removed the endpoint it must preserve"
  pass "live claude titled border: $SUBJECT fm-control relaunch replaces the titled-border worker with a live agent in the same endpoint"
else
  printf 'skip: live claude titled border relaunch: opt-in; set FM_CLAUDE_TITLED_COMPOSER_LIVE_RELAUNCH=1 to run\n'
fi
