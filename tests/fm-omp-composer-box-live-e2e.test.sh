#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_OMP_COMPOSER_BOX_LIVE herdr jq omp python3
[ -x "$LAB_HELPER" ] || fail "FM_OMP_COMPOSER_BOX_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
unset FM_SPAWN_GEN

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name omp-composer-box-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-omp-composer-box-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
TASK_ID="ompbox$$"
OWNED_SESSION=0

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$OWNED_SESSION" = 1 ] && ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    printf "guarded teardown failed for session '%s'; retained private tree for manual cleanup: %s\n" \
      "$SESSION" "$TMP_ROOT" >&2
    exit 1
  fi
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || rc=1
  rm -rf "$TMP_ROOT" || rc=1
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

"$LAB_HELPER" prepare "$SESSION" || fail "could not reserve the isolated Herdr lab"
OWNED_SESSION=1
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
. "$ROOT/bin/fm-launch-proof-lib.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
VERSION=$(PATH="$ORIGINAL_PATH" omp --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
SUBJECT="omp ($VERSION) on $HERDR_VER"

BOX_OVERLAY="$TMP_ROOT/box-overlay.yml"
sed 's/^  shape: borderless$/  shape: box/' "$ROOT/.omp/fm-session-overlay.yml" > "$BOX_OVERLAY"

CONTROL_HOME="$TMP_ROOT/control-home"
PROJECT="$TMP_ROOT/proj"
WORKTREE="$TMP_ROOT/wt"
mkdir -p "$CONTROL_HOME/state" "$CONTROL_HOME/data/$TASK_ID"
fm_git_worktree "$PROJECT" "$WORKTREE" "$TASK_ID" \
  || fail "could not create the task worktree"
cat > "$CONTROL_HOME/data/$TASK_ID/brief.md" <<'EOF'
# Task
## Captain's intent
Verify that native box-shaped omp remains untouched by Firstmate lifecycle commands.

## Firstmate spec
Do not edit any file.
EOF
printf 'preserve dirty native work\n' > "$WORKTREE/unlanded.txt"
export FM_HOME="$CONTROL_HOME" FM_STATE_OVERRIDE="$CONTROL_HOME/state"
export FM_DATA_OVERRIDE="$CONTROL_HOME/data" FM_CONFIG_OVERRIDE="$CONTROL_HOME/config"
export FM_PROJECTS_OVERRIDE="$CONTROL_HOME/projects" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$SESSION"
mkdir -p "$FM_CONFIG_OVERRIDE" "$FM_PROJECTS_OVERRIDE"
printf 'manual\n' > "$FM_CONFIG_OVERRIDE/backlog-backend"

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

lab pane run "$PANE" "env OMP_SKIP_SETUP=1 FM_OMP_HARNESS=omp omp --config '$BOX_OVERLAY' --auto-approve --cwd '$WORKTREE'" >/dev/null \
  || fail "could not launch $SUBJECT in the isolated pane"

control() {  # <fm-control arguments...>
  FM_HOME="$CONTROL_HOME" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

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
[ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] \
  || fail "$SUBJECT: the initial empty box composer has no live agent"
pass "live omp box composer: $SUBJECT idle empty composer reads empty through the production Herdr adapter"

META="$CONTROL_HOME/state/$TASK_ID.meta"
native_pid() {
  lab pane process-info --pane "$PANE" | jq -er --arg config "$BOX_OVERLAY" '
    [.result.process_info.foreground_processes[]
      | select(any(.argv[]?; . == $config))]
    | select(length == 1) | .[0].pid'
}
PID=$(native_pid) || fail "$SUBJECT: the native omp PID could not be identified"
environment=$(fm_remote_herdr_process_env "$PID") || fail "$SUBJECT: native live environment could not be read"
printf '%s\n' "$environment" | grep -Eq '^(PATH|HOME)=' \
  || fail "$SUBJECT: native live environment was not positively readable"
if printf '%s\n' "$environment" | grep -q '^FM_SPAWN_GEN='; then
  fail "$SUBJECT: native omp unexpectedly inherited a Firstmate spawn pin"
fi
[ "$(fm_launch_proof_herdr "$META")" = unmanaged ] \
  || fail "$SUBJECT: direct omp launch did not remain unmanaged"
BEFORE=$(git -C "$WORKTREE" rev-parse HEAD)
BRANCH=$(git -C "$WORKTREE" symbolic-ref HEAD)
PRESERVED=("$META" "$CONTROL_HOME/data/$TASK_ID/brief.md" "$WORKTREE/unlanded.txt")
SNAPSHOT=$(cksum "${PRESERVED[@]}")
STATE_FILES=$(find "$FM_STATE_OVERRIDE" -type f -print | LC_ALL=C sort)

assert_native_refusals() {
  local action out state_before content_before
  state_before=$(fm_backend_herdr_composer_state "$TARGET")
  content_before=$(fm_backend_herdr_composer_content "$TARGET" "$(fm_backend_herdr_composer_identity "$TARGET")")
  lab pane read "$PANE" --source visible > "$TMP_ROOT/before.screen" \
    || fail "$SUBJECT: could not snapshot the native screen"
  for action in interrupt exit relaunch; do
    if [ "$action" = relaunch ]; then
      if out=$(control "$TASK_ID" relaunch --note 'Must not reach native instructions.'); then
        fail "$SUBJECT: ordinary relaunch accepted the unmanaged native worker: $out"
      fi
    elif out=$(control "$TASK_ID" "$action"); then
      fail "$SUBJECT: $action accepted the unmanaged native worker: $out"
    fi
    case "$out" in
      *'cannot positively attribute its live Herdr agent'*'refusing'*) ;;
      *) fail "$SUBJECT: $action did not name the native ownership refusal: $out" ;;
    esac
    [ "$(native_pid)" = "$PID" ] || fail "$SUBJECT: $action replaced the native PID"
    [ "$(fm_launch_proof_herdr "$META")" = unmanaged ] \
      || fail "$SUBJECT: $action changed native ownership"
    [ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] \
      || fail "$SUBJECT: $action stopped the native worker"
    [ "$(fm_backend_herdr_composer_state "$TARGET")" = "$state_before" ] \
      || fail "$SUBJECT: $action changed native composer state"
    [ "$(fm_backend_herdr_composer_content "$TARGET" "$(fm_backend_herdr_composer_identity "$TARGET")")" = "$content_before" ] \
      || fail "$SUBJECT: $action changed native composer content"
    lab pane read "$PANE" --source visible > "$TMP_ROOT/after.screen" \
      || fail "$SUBJECT: could not reread the native screen"
    cmp -s "$TMP_ROOT/before.screen" "$TMP_ROOT/after.screen" \
      || fail "$SUBJECT: $action changed the visible native screen"
    [ "$(cksum "${PRESERVED[@]}")" = "$SNAPSHOT" ] \
      || fail "$SUBJECT: $action changed metadata, instructions or dirty work"
    [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$BEFORE" ] \
      && [ "$(git -C "$WORKTREE" symbolic-ref HEAD)" = "$BRANCH" ] \
      || fail "$SUBJECT: $action changed HEAD or branch"
    [ "$(find "$FM_STATE_OVERRIDE" -type f -print | LC_ALL=C sort)" = "$STATE_FILES" ] \
      || fail "$SUBJECT: $action created lifecycle state"
    lab pane get "$PANE" >/dev/null || fail "$SUBJECT: $action removed the native endpoint"
  done
}

assert_native_refusals

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

assert_native_refusals
pass "live omp box composer: $SUBJECT reads a draft pending and refuses native interrupt, exit and relaunch without altering its PID, screen or draft"
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

assert_native_refusals
pass "live omp box composer: $SUBJECT preserves the live unmanaged empty box-shaped worker, endpoint, metadata, instructions and dirty work after lifecycle refusals"
