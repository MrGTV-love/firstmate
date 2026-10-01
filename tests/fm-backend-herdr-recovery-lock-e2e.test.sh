#!/usr/bin/env bash
# Two real-Herdr homes recover while one is held at worktree allocation.
# Generated isolated clones replace Treehouse allocation; no pool is touched.
# The public spawn path must retain task custody but release presentation
# custody after exact reclaim.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for tool in herdr jq python3; do
  command -v "$tool" >/dev/null || { echo "skip: $tool not found"; exit 0; }
done
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-recovery-lock.XXXXXX")
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
HERDR_ORIGINAL_PATH=$PATH
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name recovery-lock)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH TEST_DIR
export HERDR_SESSION=$HERDR_LAB_SESSION
PRIMARY_PID='' BRAVO_PID='' LAB_READY=0
cleanup() {
  local rc=$? lane
  touch "$TEST_DIR/release-primary"
  [ -z "$PRIMARY_PID" ] || wait "$PRIMARY_PID" 2>/dev/null || true
  [ -z "$BRAVO_PID" ] || wait "$BRAVO_PID" 2>/dev/null || true
  if [ "$LAB_READY" = 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fi
  for lane in primary bravo; do
    [ ! -f "$TEST_DIR/home-$lane/.fm-lab-home" ] || "$LAB_HOME_HELPER" teardown "$TEST_DIR/home-$lane" || rc=1
  done
  chmod -R u+w "$TEST_DIR"
  rm -rf "$TEST_DIR"
  exit "$rc"
}
trap cleanup EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
lab() { PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
for lane in primary bravo; do
  "$LAB_HOME_HELPER" create "$TEST_DIR/home-$lane" >/dev/null
  git init -q "$TEST_DIR/project-$lane"
  printf 'fixture\n' > "$TEST_DIR/project-$lane/README.md"
  git -C "$TEST_DIR/project-$lane" add README.md
  git -C "$TEST_DIR/project-$lane" -c user.name=Tests -c user.email=tests@example.invalid commit -qm fixture
  git clone -q "$TEST_DIR/project-$lane" "$TEST_DIR/copy-$lane"
  git -C "$TEST_DIR/copy-$lane" remote remove origin
done
printf 'bravo\n' > "$TEST_DIR/home-bravo/.fm-secondmate-home"
mkdir "$TEST_DIR/fakebin"
cat > "$TEST_DIR/fakebin/herdr" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n - 2))]}" = --session ] && [ "${args[$((n - 1))]}" = "$HERDR_LAB_SESSION" ]; then
  unset 'args[n-1]' 'args[n-2]'
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session*) exit 1 ;; esac
  treehouse_command='(^|[[:space:];/])treehouse([[:space:];]|$)'
  if [[ "$arg" =~ $treehouse_command ]]; then
    # Recognize only the exact submitted/literal allocation forms. A miss
    # refuses before any real command reaches a pane or the shared allocator.
    [ "$#" = 4 ] && [ "$1" = pane ] && { [ "$2" = run ] || [ "$2" = send-text ]; } && [ "$4" = 'treehouse get' ] || exit 1
    cwd=$(PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$3" | jq -r '.result.pane.foreground_cwd')
    case "$cwd" in
      "$TEST_DIR/project-primary") lane=primary ;;
      "$TEST_DIR/project-bravo") lane=bravo ;;
      *) exit 1 ;;
    esac
    [ -d "$TEST_DIR/copy-$lane/.git" ] || exit 1
    if [ "$lane" = primary ]; then
      touch "$TEST_DIR/primary-at-allocation"
      for ((i=0; i<600; i++)); do
        [ ! -e "$TEST_DIR/release-primary" ] || break
        sleep 0.1
      done
      [ -e "$TEST_DIR/release-primary" ] || exit 1
    fi
    printf -v command 'cd -- %q' "$TEST_DIR/copy-$lane"
    set -- pane "$2" "$3" "$command"
    break
  fi
done
case "${1:-} ${2:-}" in
  'tab create'|'pane close')
    owner=$(cat "$TEST_SESSION_LOCK/pid")
    kill -0 "$owner" || exit 1
    printf '%s\t%s\n' "$owner" "$*" >> "$TEST_DIR/mutation-owners"
    ;;
esac
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
WRAPPER
chmod +x "$TEST_DIR/fakebin/herdr"
export PATH="$TEST_DIR/fakebin:$PATH"
# Prove allocation interception against the actual adapter forms before a
# real session exists. The probe helper has no Herdr or Treehouse invocation.
cat > "$TEST_DIR/probe" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
shift 2
printf '%s\n' "$*" >> "$TEST_DIR/probe-calls"
case "$1 ${2:-}" in
  'status --json') printf '{"client":{"version":"0.9.0","protocol":19},"server":{"running":true}}\n' ;;
  'pane get') jq -n --arg cwd "$TEST_DIR/project-$3" '{result:{pane:{foreground_cwd:$cwd}}}' ;;
  'pane run'|'pane send-text') printf '{}\n' ;;
  *) exit 1 ;;
esac
PROBE
chmod +x "$TEST_DIR/probe"
FM_HOME="$TEST_DIR/home-primary"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
touch "$TEST_DIR/release-primary"
HERDR_LAB_HELPER="$TEST_DIR/probe" fm_backend_herdr_send_text_line "$HERDR_LAB_SESSION:primary" 'treehouse get'
HERDR_LAB_HELPER="$TEST_DIR/probe" fm_backend_herdr_send_literal "$HERDR_LAB_SESSION:bravo" 'treehouse get'
for form in run send-text send send-keys; do
  if HERDR_LAB_HELPER="$TEST_DIR/probe" herdr pane "$form" primary 'treehouse  get' --session "$HERDR_LAB_SESSION"; then fail "unmatched allocation form was forwarded"; fi
done
if HERDR_LAB_HELPER="$TEST_DIR/probe" herdr pane run foreign 'treehouse get' --session "$HERDR_LAB_SESSION"; then fail "foreign cwd was accepted"; fi
grep -F "pane run primary cd -- $TEST_DIR/copy-primary" "$TEST_DIR/probe-calls" >/dev/null || fail "submitted allocation was not intercepted"
grep -F "pane send-text bravo cd -- $TEST_DIR/copy-bravo" "$TEST_DIR/probe-calls" >/dev/null || fail "literal allocation was not intercepted"
if grep -E '(^|[[:space:];/])treehouse([[:space:];]|$)' "$TEST_DIR/probe-calls" >/dev/null; then fail "unmatched Treehouse command reached probe"; fi
rm "$TEST_DIR/release-primary" "$TEST_DIR/primary-at-allocation"
LAB_READY=1
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
echo "# herdr $(lab status --json | jq -r '.server.version') recovery custody lab"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
TEST_SESSION_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$HERDR_LAB_SESSION")
export TEST_SESSION_LOCK
# Seed exact version-2 restored bindings with production helpers. Recovery
# itself is exercised only through the executable spawn interface below.
for lane in primary bravo; do
  FM_HOME="$TEST_DIR/home-$lane"
  id="recovery-$lane"
  mkdir -p "$FM_HOME/data/$id"
  touch "$FM_HOME/state/.last-watcher-beat"
  printf 'on\n' > "$FM_HOME/config/herdr-presentation-spaces"
  cat > "$FM_HOME/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Recover the exact fixture.

## Firstmate spec
Exercise cross-home custody.
EOF
  label=$(fm_backend_herdr_workspace_label)
  parent=$(lab workspace create --cwd "$TEST_DIR/project-$lane" --label "$label" --focus | jq -r '.result.workspace.workspace_id')
  fm_lock_try_acquire "$TEST_SESSION_LOCK"
  token=$(fm_backend_herdr_projection_journal_create "$FM_HOME/state" "$id")
  wslabel=$(fm_backend_herdr_projection_workspace_label "$id" "$token")
  fm_backend_herdr_projection_create_task "$TEST_DIR/project-$lane" "$wslabel" "fm-$id"
  ws=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
  tab=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
  pane=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
  fm_backend_herdr_projection_order_best_effort "$HERDR_LAB_SESSION" "$ws" "$label" "$parent"
  fm_backend_herdr_projection_live_binding_matches "$HERDR_LAB_SESSION" "$token" "$ws" "$tab" "$pane" "$parent" "$label" "$wslabel" "fm-$id"
  fm_backend_herdr_projection_journal_bind "$FM_HOME/state/$id.herdr-presentation" "$id" "$FM_HOME" "$HERDR_LAB_SESSION" "$ws" "$tab" "$pane" "$parent" "$label" "$wslabel" "fm-$id"
  cat > "$FM_HOME/state/$id.meta" <<EOF
window=$HERDR_LAB_SESSION:$pane
worktree=$TEST_DIR/copy-$lane
project=$TEST_DIR/project-$lane
harness=sh
kind=ship
mode=no-mistakes
yolo=off
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
spawn_gen=old-$lane
EOF
  cp "$FM_HOME/state/$id.meta" "$TEST_DIR/$lane-old.meta"
  cp "$FM_HOME/state/$id.herdr-presentation" "$TEST_DIR/$lane-old.journal"
  fm_lock_release "$TEST_SESSION_LOCK"
done
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
FOCUS=$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")
: > "$TEST_DIR/mutation-owners"
spawn() {
  local lane=$1
  exec env FM_HOME="$TEST_DIR/home-$lane" FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    bash "$ROOT/bin/fm-spawn.sh" "recovery-$lane" "$TEST_DIR/project-$lane" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}
spawn primary >"$TEST_DIR/primary.out" 2>"$TEST_DIR/primary.err" &
PRIMARY_PID=$!
for ((i=0; i<600; i++)); do
  [ ! -e "$TEST_DIR/primary-at-allocation" ] || break
  sleep 0.1
done
[ -e "$TEST_DIR/primary-at-allocation" ] || fail "primary did not reach allocation: $(cat "$TEST_DIR/primary.err")"
# Primary stays alive beyond the contender's entire acquisition window. The
# contender must complete before release, so success cannot come from a retry,
# a larger acquisition deadline, or faster scheduling of the allocation.
spawn bravo >"$TEST_DIR/bravo.out" 2>"$TEST_DIR/bravo.err" &
BRAVO_PID=$!
wait "$BRAVO_PID" || fail "cross-home recovery failed while primary allocation was held: $(cat "$TEST_DIR/bravo.err")"
BRAVO_PID=
kill -0 "$PRIMARY_PID" || fail "primary allocation was not still held"
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "recovery moved focus"
# Same-task exclusion must survive releasing the session lock.
if (spawn primary) >"$TEST_DIR/duplicate.out" 2>"$TEST_DIR/duplicate.err"; then fail "duplicate primary recovery launched"; fi
grep -F 'task set is locked' "$TEST_DIR/duplicate.err" >/dev/null || fail "duplicate did not refuse at the held task-set gate: $(cat "$TEST_DIR/duplicate.err")"
[ "$(cat "$TEST_DIR/home-primary/state/.spawn-recovery-primary.lock/pid")" = "$PRIMARY_PID" ] || fail "primary lost its per-task lock owner"
touch "$TEST_DIR/release-primary"
wait "$PRIMARY_PID" || fail "primary recovery failed: $(cat "$TEST_DIR/primary.err")"
PRIMARY_PID=
field() { sed -n "s/^$2=//p" "$1"; }
for lane in primary bravo; do
  old="$TEST_DIR/$lane-old.meta"
  meta="$TEST_DIR/home-$lane/state/recovery-$lane.meta"
  journal="$TEST_DIR/home-$lane/state/recovery-$lane.herdr-presentation"
  [ "$(field "$meta" herdr_workspace_id)" = "$(field "$old" herdr_workspace_id)" ] || fail "$lane workspace identity changed"
  [ "$(field "$meta" herdr_pane_id)" != "$(field "$old" herdr_pane_id)" ] || fail "$lane old husk was reused"
  [ "$(field "$meta" herdr_tab_id)" != "$(field "$old" herdr_tab_id)" ] || fail "$lane old tab was reused"
  [ "$(field "$meta" spawn_gen)" != "$(field "$old" spawn_gen)" ] || fail "$lane generation did not advance"
  [ "$(field "$meta" herdr_pane_id)" = "$(field "$journal" pane_id)" ] || fail "$lane journal and metadata diverged"
  [ "$(field "$journal" projection_id)" = "$(field "$TEST_DIR/$lane-old.journal" projection_id)" ] || fail "$lane token changed"
  [ "$(field "$journal" home)" = "$TEST_DIR/home-$lane" ] || fail "$lane home custody changed"
  if lab pane get "$(field "$old" herdr_pane_id)" >/dev/null 2>&1; then fail "$lane old husk survived"; fi
done
[ "$(field "$TEST_DIR/home-primary/state/recovery-primary.meta" spawn_gen)" != "$(field "$TEST_DIR/home-bravo/state/recovery-bravo.meta" spawn_gen)" ] || fail "home generations were conflated"
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "launch handoff moved focus"
[ "$(cut -f1 "$TEST_DIR/mutation-owners" | sort -u | wc -l | tr -d '[:space:]')" = 2 ] || fail "presentation mutations did not have two exclusive process owners"
echo 'ok - cross-home recovery completes while unrelated allocation is held, preserving task custody, exact binding, generation and focus'
