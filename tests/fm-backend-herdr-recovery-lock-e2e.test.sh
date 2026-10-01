#!/usr/bin/env bash
# Two real-Herdr homes recover while one is held at worktree allocation, then
# recover and abort beside a fresh projection held at worktree allocation.
# Generated isolated clones replace Treehouse allocation; no pool is touched.
# The public spawn path must retain task custody but release presentation
# custody after exact reclaim or fresh binding.
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
LANES='primary bravo fresh abort late'
PRIMARY_PID='' BRAVO_PID='' FRESH_PID='' ABORT_PID='' LAB_READY=0
cleanup() {
  local rc=$? lane pid
  for lane in $LANES; do touch "$TEST_DIR/release-$lane"; done
  for pid in "$PRIMARY_PID" "$BRAVO_PID" "$FRESH_PID" "$ABORT_PID"; do
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
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
done
for lane in $LANES; do
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
      "$TEST_DIR"/project-*) lane=${cwd#"$TEST_DIR"/project-} ;;
      *) exit 1 ;;
    esac
    case " $LANES " in *" $lane "*) ;; *) exit 1 ;; esac
    [ -d "$TEST_DIR/copy-$lane/.git" ] || exit 1
    touch "$TEST_DIR/$lane-at-allocation"
    if [ -e "$TEST_DIR/hold-$lane" ]; then
      for ((i=0; i<600; i++)); do
        [ ! -e "$TEST_DIR/release-$lane" ] || break
        sleep 0.1
      done
      [ -e "$TEST_DIR/release-$lane" ] || exit 1
    fi
    [ ! -e "$TEST_DIR/fail-$lane" ] || exit 1
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
export PATH="$TEST_DIR/fakebin:$PATH" LANES
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
HERDR_LAB_HELPER="$TEST_DIR/probe" fm_backend_herdr_send_text_line "$HERDR_LAB_SESSION:primary" 'treehouse get'
HERDR_LAB_HELPER="$TEST_DIR/probe" fm_backend_herdr_send_literal "$HERDR_LAB_SESSION:bravo" 'treehouse get'
for form in run send-text send send-keys; do
  if HERDR_LAB_HELPER="$TEST_DIR/probe" herdr pane "$form" primary 'treehouse  get' --session "$HERDR_LAB_SESSION"; then fail "unmatched allocation form was forwarded"; fi
done
if HERDR_LAB_HELPER="$TEST_DIR/probe" herdr pane run foreign 'treehouse get' --session "$HERDR_LAB_SESSION"; then fail "foreign cwd was accepted"; fi
grep -F "pane run primary cd -- $TEST_DIR/copy-primary" "$TEST_DIR/probe-calls" >/dev/null || fail "submitted allocation was not intercepted"
grep -F "pane send-text bravo cd -- $TEST_DIR/copy-bravo" "$TEST_DIR/probe-calls" >/dev/null || fail "literal allocation was not intercepted"
if grep -E '(^|[[:space:];/])treehouse([[:space:];]|$)' "$TEST_DIR/probe-calls" >/dev/null; then fail "unmatched Treehouse command reached probe"; fi
rm "$TEST_DIR/primary-at-allocation" "$TEST_DIR/bravo-at-allocation"
LAB_READY=1
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
echo "# herdr $(lab status --json | jq -r '.server.version') recovery custody lab"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
TEST_SESSION_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$HERDR_LAB_SESSION")
export TEST_SESSION_LOCK
write_brief() { # <home> <task-id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Recover the exact fixture.

## Firstmate spec
Exercise cross-home custody.
EOF
}
# Seed exact version-2 restored bindings with production helpers. Recovery
# itself is exercised only through the executable spawn interface below.
for home in primary bravo; do
  FM_HOME="$TEST_DIR/home-$home"
  touch "$FM_HOME/state/.last-watcher-beat"
  printf 'on\n' > "$FM_HOME/config/herdr-presentation-spaces"
  label=$(fm_backend_herdr_workspace_label)
  parent=$(lab workspace create --cwd "$TEST_DIR/project-$home" --label "$label" --focus | jq -r '.result.workspace.workspace_id')
  printf '%s\n' "$parent" > "$TEST_DIR/parent-$home"
  lanes=$home
  [ "$home" = primary ] || lanes='bravo abort late'
  for lane in $lanes; do
    id="recovery-$lane"
    write_brief "$FM_HOME" "$id"
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
done
write_brief "$TEST_DIR/home-primary" fresh-primary
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
FOCUS=$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")
: > "$TEST_DIR/mutation-owners"
spawn() { # <home> <task-id> <lane>
  exec env FM_HOME="$TEST_DIR/home-$1" FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    bash "$ROOT/bin/fm-spawn.sh" "$2" "$TEST_DIR/project-$3" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}
await_allocation() { # <lane> <pid>
  for ((i=0; i<600; i++)); do
    [ ! -e "$TEST_DIR/$1-at-allocation" ] || return 0
    kill -0 "$2" 2>/dev/null || break
    sleep 0.1
  done
  fail "$1 did not reach allocation: $(cat "$TEST_DIR/$1.err")"
}
touch "$TEST_DIR/hold-primary"
spawn primary recovery-primary primary >"$TEST_DIR/primary.out" 2>"$TEST_DIR/primary.err" &
PRIMARY_PID=$!
await_allocation primary "$PRIMARY_PID"
# Primary stays alive beyond the contender's entire acquisition window. The
# contender must complete before release, so success cannot come from a retry,
# a larger acquisition deadline, or faster scheduling of the allocation.
spawn bravo recovery-bravo bravo >"$TEST_DIR/bravo.out" 2>"$TEST_DIR/bravo.err" &
BRAVO_PID=$!
wait "$BRAVO_PID" || fail "cross-home recovery failed while primary allocation was held: $(cat "$TEST_DIR/bravo.err")"
BRAVO_PID=
kill -0 "$PRIMARY_PID" || fail "primary allocation was not still held"
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "recovery moved focus"
# Same-task exclusion must survive releasing the session lock.
if (spawn primary recovery-primary primary) >"$TEST_DIR/duplicate.out" 2>"$TEST_DIR/duplicate.err"; then fail "duplicate primary recovery launched"; fi
grep -F 'task set is locked' "$TEST_DIR/duplicate.err" >/dev/null || fail "duplicate did not refuse at the held task-set gate: $(cat "$TEST_DIR/duplicate.err")"
[ "$(cat "$TEST_DIR/home-primary/state/.spawn-recovery-primary.lock/pid")" = "$PRIMARY_PID" ] || fail "primary lost its per-task lock owner"
touch "$TEST_DIR/release-primary"
wait "$PRIMARY_PID" || fail "primary recovery failed: $(cat "$TEST_DIR/primary.err")"
PRIMARY_PID=
field() { sed -n "s/^$2=//p" "$1"; }
assert_reclaimed() { # <home> <lane>
  local old="$TEST_DIR/$2-old.meta" meta="$TEST_DIR/home-$1/state/recovery-$2.meta"
  local journal="$TEST_DIR/home-$1/state/recovery-$2.herdr-presentation"
  [ "$(field "$meta" herdr_workspace_id)" = "$(field "$old" herdr_workspace_id)" ] || fail "$2 workspace identity changed"
  [ "$(field "$meta" herdr_pane_id)" != "$(field "$old" herdr_pane_id)" ] || fail "$2 old husk was reused"
  [ "$(field "$meta" herdr_tab_id)" != "$(field "$old" herdr_tab_id)" ] || fail "$2 old tab was reused"
  [ "$(field "$meta" spawn_gen)" != "$(field "$old" spawn_gen)" ] || fail "$2 generation did not advance"
  [ "$(field "$meta" herdr_pane_id)" = "$(field "$journal" pane_id)" ] || fail "$2 journal and metadata diverged"
  [ "$(field "$journal" projection_id)" = "$(field "$TEST_DIR/$2-old.journal" projection_id)" ] || fail "$2 token changed"
  [ "$(field "$journal" home)" = "$TEST_DIR/home-$1" ] || fail "$2 home custody changed"
  if lab pane get "$(field "$old" herdr_pane_id)" >/dev/null 2>&1; then fail "$2 old husk survived"; fi
}
assert_reclaimed primary primary
assert_reclaimed bravo bravo
[ "$(field "$TEST_DIR/home-primary/state/recovery-primary.meta" spawn_gen)" != "$(field "$TEST_DIR/home-bravo/state/recovery-bravo.meta" spawn_gen)" ] || fail "home generations were conflated"
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "launch handoff moved focus"
[ "$(cut -f1 "$TEST_DIR/mutation-owners" | sort -u | wc -l | tr -d '[:space:]')" = 2 ] || fail "presentation mutations did not have two exclusive process owners"
echo 'ok - cross-home recovery completes while unrelated allocation is held, preserving task custody, exact binding, generation and focus'

# A reclaimed recovery waits at allocation. A fresh projection from the other
# home then holds its own allocation until the recovery has aborted and a
# later recovery has completed, so neither result can come from the fresh
# allocation finishing within any acquisition window.
: > "$TEST_DIR/mutation-owners"
touch "$TEST_DIR/hold-abort" "$TEST_DIR/fail-abort" "$TEST_DIR/hold-fresh"
spawn bravo recovery-abort abort >"$TEST_DIR/abort.out" 2>"$TEST_DIR/abort.err" &
ABORT_PID=$!
await_allocation abort "$ABORT_PID"
REPLACEMENT_PANE=$(field "$TEST_DIR/home-bravo/state/recovery-abort.herdr-presentation" pane_id)
[ -n "$REPLACEMENT_PANE" ] && [ "$REPLACEMENT_PANE" != "$(field "$TEST_DIR/abort-old.meta" herdr_pane_id)" ] || fail "abort recovery did not advance its exact journal"
lab pane get "$REPLACEMENT_PANE" >/dev/null || fail "abort replacement pane was not live before setup failed"
spawn primary fresh-primary fresh >"$TEST_DIR/fresh.out" 2>"$TEST_DIR/fresh.err" &
FRESH_PID=$!
await_allocation fresh "$FRESH_PID"
FRESH_JOURNAL="$TEST_DIR/home-primary/state/fresh-primary.herdr-presentation"
FRESH_PANE=$(field "$FRESH_JOURNAL" pane_id)
[ -n "$FRESH_PANE" ] || fail "fresh projection did not publish its exact binding before allocation"
touch "$TEST_DIR/release-abort"
if wait "$ABORT_PID"; then fail "abort recovery launched after its setup failed"; fi
ABORT_PID=
if grep -F 'focus lock unavailable' "$TEST_DIR/abort.err" >/dev/null; then fail "abort cleanup could not reacquire session custody: $(cat "$TEST_DIR/abort.err")"; fi
if lab pane get "$REPLACEMENT_PANE" >/dev/null 2>&1; then fail "aborted recovery left its replacement pane live"; fi
if lab pane get "$(field "$TEST_DIR/abort-old.meta" herdr_pane_id)" >/dev/null 2>&1; then fail "aborted recovery left its old husk live"; fi
cmp -s "$TEST_DIR/abort-old.meta" "$TEST_DIR/home-bravo/state/recovery-abort.meta" || fail "aborted recovery published metadata"
[ "$(field "$TEST_DIR/home-bravo/state/recovery-abort.herdr-presentation" pane_id)" = "$REPLACEMENT_PANE" ] || fail "aborted recovery rewrote its journal"
lab pane get "$FRESH_PANE" >/dev/null || fail "abort cleanup touched the fresh projection"
(spawn bravo recovery-late late) >"$TEST_DIR/late.out" 2>"$TEST_DIR/late.err" || fail "recovery failed while a fresh projection allocation was held: $(cat "$TEST_DIR/late.err")"
kill -0 "$FRESH_PID" || fail "fresh allocation was not still held"
assert_reclaimed bravo late
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "recovery beside a fresh projection moved focus"
touch "$TEST_DIR/release-fresh"
wait "$FRESH_PID" || fail "fresh projection failed: $(cat "$TEST_DIR/fresh.err")"
FRESH_PID=
FRESH_META="$TEST_DIR/home-primary/state/fresh-primary.meta"
[ "$(field "$FRESH_META" herdr_pane_id)" = "$FRESH_PANE" ] || fail "fresh journal and metadata diverged"
[ "$(field "$FRESH_JOURNAL" home)" = "$TEST_DIR/home-primary" ] || fail "fresh home custody changed"
[ "$(field "$FRESH_JOURNAL" parent_workspace_id)" = "$(cat "$TEST_DIR/parent-primary")" ] || fail "fresh projection changed its exact parent"
[ "$(field "$FRESH_META" herdr_workspace_id)" = "$(field "$FRESH_JOURNAL" workspace_id)" ] || fail "fresh workspace custody diverged"
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "fresh launch handoff moved focus"
[ "$(cut -f1 "$TEST_DIR/mutation-owners" | sort -u | wc -l | tr -d '[:space:]')" = 3 ] || fail "presentation mutations did not have the abort, fresh and late process owners"
echo 'ok - recovery and failed-setup abort cleanup complete beside a held fresh projection allocation, preserving exact custody and focus'
