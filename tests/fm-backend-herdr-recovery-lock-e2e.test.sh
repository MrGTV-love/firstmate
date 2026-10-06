#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for tool in herdr jq python3 lsof tasks-axi; do
  command -v "$tool" >/dev/null || { echo "skip: $tool not found"; exit 0; }
done
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
TEST_DIR=$(mktemp -d "$ROOT/.fm-herdr-recovery-lock.XXXXXX")
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
mkdir "$TEST_DIR/tmp"
export TMPDIR="$TEST_DIR/tmp"
HERDR_ORIGINAL_PATH=$PATH
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name recovery-lock)
RECOVERY="$HERDR_LAB_SESSION-recovery"
FRESH="$HERDR_LAB_SESSION-fresh"
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH TEST_DIR
export HERDR_SESSION=$HERDR_LAB_SESSION
LANES='primary bravo fresh abort late doomed owned-conclude owned-reap wrong-conclude wrong-reap recover-conclude recover-reap abort-conclude abort-reap fresh-conclude fresh-reap forced-parent forced-nested forced-child recover-forced abort-forced fresh-forced'
PRIMARY_PID='' BRAVO_PID='' FRESH_PID='' ABORT_PID='' DOOMED_PID='' TEARDOWN_PID='' LAB_READY=0
FIXTURE_PIDS=''
cleanup() {
  local rc=$? lane pid
  for lane in $LANES; do touch "$TEST_DIR/release-$lane" "$TEST_DIR/release-return-$lane" "$TEST_DIR/release-conclude-$lane" "$TEST_DIR/release-reap-$lane"; done
  for pid in "$PRIMARY_PID" "$BRAVO_PID" "$FRESH_PID" "$ABORT_PID" "$DOOMED_PID" "$TEARDOWN_PID"; do
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  for pid in $FIXTURE_PIDS; do
    if [ -f "$TEST_DIR/process-birth-$pid" ] && [ "$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || true)" = "$(cat "$TEST_DIR/process-birth-$pid")" ]; then
      kill "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
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
  if [ "$lane" = forced-child ]; then
    git -C "$TEST_DIR/project-$lane" worktree add --quiet --detach "$TEST_DIR/copy-$lane" HEAD
  else
    git clone -q "$TEST_DIR/project-$lane" "$TEST_DIR/copy-$lane"
    git -C "$TEST_DIR/copy-$lane" remote remove origin
  fi
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
cat > "$TEST_DIR/fakebin/treehouse" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
# Accept only an exact generated-copy return from its generated project. Any
# other form refuses; nothing here reaches the shared allocator.
[ "$#" = 3 ] && [ "$1" = return ] && [ "$2" = --force ] || exit 1
case "$3" in
  "$TEST_DIR"/copy-*) lane=${3#"$TEST_DIR"/copy-} ;;
  *) exit 1 ;;
esac
case " $LANES " in *" $lane "*) ;; *) exit 1 ;; esac
[ "$(pwd -P)" = "$TEST_DIR/project-$lane" ] || exit 1
touch "$TEST_DIR/$lane-at-return"
if [ -e "$TEST_DIR/hold-return-$lane" ]; then
  while [ ! -e "$TEST_DIR/release-return-$lane" ]; do sleep 0.1; done
fi
printf '%s\n' "$lane" >> "$TEST_DIR/returns"
WRAPPER
chmod +x "$TEST_DIR/fakebin/treehouse"
mkdir "$TEST_DIR/teardownbin"
REAL_GIT=$(command -v git)
export REAL_GIT
cat > "$TEST_DIR/fakebin/git" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = -C ]; then
  case "${2:-}" in
    "$TEST_DIR"/copy-*)
      lane=${2#"$TEST_DIR"/copy-}
      if [ -e "$TEST_DIR/status-armed-$lane" ] && [ -e "$TEST_DIR/hold-conclude-$lane" ] && [ ! -e "$TEST_DIR/concluded-$lane" ]; then
        touch "$TEST_DIR/$lane-at-conclude"
        while [ ! -e "$TEST_DIR/release-conclude-$lane" ]; do sleep 0.1; done
      fi
      ;;
  esac
fi
exec "$REAL_GIT" "$@"
WRAPPER
chmod +x "$TEST_DIR/fakebin/git"
REAL_TASKS_AXI=$(command -v tasks-axi)
export REAL_TASKS_AXI
cat > "$TEST_DIR/fakebin/tasks-axi" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  done|reopen)
    if [ -e "$TEST_DIR/fail-transition-${2:-}" ]; then
      printf 'error: controlled owned backlog transition interruption\n' >&2
      exit 1
    fi
    ;;
esac
exec "$REAL_TASKS_AXI" "$@"
WRAPPER
chmod +x "$TEST_DIR/fakebin/tasks-axi"
cat > "$TEST_DIR/teardownbin/no-mistakes" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
case "$(pwd -P)" in "$TEST_DIR"/copy-*) lane=${PWD#"$TEST_DIR"/copy-} ;; *) exit 1 ;; esac
case " $LANES " in *" $lane "*) ;; *) exit 1 ;; esac
[ -e "$TEST_DIR/run-$lane" ] || exit 1
case "$*" in
  'axi status'|"axi status --run fixture-$lane")
    if [ "$*" = 'axi status' ]; then
      query_started=$(date +%s)
      sleep 1
      printf '%s\n' "$(( $(date +%s) - query_started ))" > "$TEST_DIR/query-seconds-$lane"
    fi
    status=awaiting_approval outcome=''
    [ ! -e "$TEST_DIR/concluded-$lane" ] || { status=cancelled; outcome=cancelled; }
    printf 'id: fixture-%s\nbranch: %s\nhead: %s\nstatus: %s\noutcome: %s\n' "$lane" "$(git symbolic-ref --short HEAD)" "$(git rev-parse HEAD)" "$status" "$outcome"
    [ "$*" != 'axi status' ] || touch "$TEST_DIR/status-armed-$lane"
    ;;
  "axi abort --run fixture-$lane")
    printf '%s\n' "$lane" >> "$TEST_DIR/conclusions"
    touch "$TEST_DIR/concluded-$lane"
    ;;
  *) exit 1 ;;
esac
WRAPPER
REAL_LSOF=$(command -v lsof)
export REAL_LSOF
cat > "$TEST_DIR/fakebin/lsof" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = '-a -d cwd -Fpn' ] || exit 1
if [ -n "${FIXTURE_REAP_LANE:-}" ] && [ -e "$TEST_DIR/hold-reap-$FIXTURE_REAP_LANE" ]; then
  touch "$TEST_DIR/$FIXTURE_REAP_LANE-at-reap"
  while [ ! -e "$TEST_DIR/release-reap-$FIXTURE_REAP_LANE" ]; do sleep 0.1; done
fi
pids=''
while IFS= read -r pid; do
  case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
  kill -0 "$pid" 2>/dev/null || continue
  [ -f "$TEST_DIR/process-birth-$pid" ] || exit 1
  [ "$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || true)" = "$(cat "$TEST_DIR/process-birth-$pid")" ] || continue
  pids="${pids:+$pids,}$pid"
done < "$TEST_DIR/inventory-pids"
[ -n "$pids" ] || exit 0
"$REAL_LSOF" -a -p "$pids" -d cwd -Fpn
WRAPPER
chmod +x "$TEST_DIR/teardownbin/no-mistakes" "$TEST_DIR/fakebin/lsof"
: > "$TEST_DIR/inventory-pids"
export PATH="$TEST_DIR/teardownbin:$TEST_DIR/fakebin:$PATH" LANES
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
[ "$(command -v treehouse)" = "$TEST_DIR/fakebin/treehouse" ] || fail "generated return interception is not first on PATH"
[ "$(PATH="$TEST_DIR/teardownbin:$PATH" command -v no-mistakes)" = "$TEST_DIR/teardownbin/no-mistakes" ] || fail "teardown run-query stub is not first on PATH"
(cd "$TEST_DIR/project-primary" && treehouse return --force "$TEST_DIR/copy-primary") || fail "exact generated-copy return was refused"
if (cd "$TEST_DIR/project-primary" && treehouse get); then fail "unmatched Treehouse allocation was accepted"; fi
if (cd "$TEST_DIR/project-primary" && treehouse return "$TEST_DIR/copy-primary"); then fail "unforced return was accepted"; fi
if (cd "$TEST_DIR/project-bravo" && treehouse return --force "$TEST_DIR/copy-primary"); then fail "foreign-project return was accepted"; fi
if (cd "$TEST_DIR/project-primary" && treehouse return --force "$TEST_DIR/project-primary"); then fail "non-copy return was accepted"; fi
[ "$(cat "$TEST_DIR/returns")" = primary ] || fail "return interception recorded an unexpected call"
rm "$TEST_DIR/primary-at-allocation" "$TEST_DIR/bravo-at-allocation" "$TEST_DIR/primary-at-return" "$TEST_DIR/returns"
mkdir "$TEST_DIR/offline-owned" "$TEST_DIR/offline-unrelated"
fixture_process() {
  (cd "$1" && exec python3 -c 'import os, pathlib, sys; pathlib.Path(sys.argv[1]).touch(); os.execlp("sleep", "sleep", "3600")' "$TEST_DIR/ready-${1##*/}") &
  FIXTURE_PID=$!
  FIXTURE_PIDS="$FIXTURE_PIDS $FIXTURE_PID"
  while [ ! -e "$TEST_DIR/ready-${1##*/}" ]; do
    kill -0 "$FIXTURE_PID" || fail "generated process failed to enter its owned cwd"
    sleep 0.1
  done
  LC_ALL=C ps -p "$FIXTURE_PID" -o lstart= > "$TEST_DIR/process-birth-$FIXTURE_PID"
  [ -s "$TEST_DIR/process-birth-$FIXTURE_PID" ] || fail "generated process lacks a birth identity"
  printf '%s\n' "$FIXTURE_PID" >> "$TEST_DIR/inventory-pids"
}
fixture_process "$TEST_DIR/offline-owned"
OFFLINE_OWNED_PID=$FIXTURE_PID
fixture_process "$TEST_DIR/offline-unrelated"
UNRELATED_PID=$FIXTURE_PID
python3 - "$ROOT/bin/fm-teardown.sh" "$TEST_DIR/runtime-cleanup.sh" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
start = source.index("pids_with_cwd_under() {")
end = source.index("\n}\n", source.index("reap_task_worktree_processes() {", start)) + 3
pathlib.Path(sys.argv[2]).write_text(source[start:end])
PY
(
  . "$ROOT/bin/fm-nm-run-lib.sh"
  # shellcheck source=/dev/null
  . "$TEST_DIR/runtime-cleanup.sh"
  task_pids_under_roots "$TEST_DIR/offline-owned" || fail "offline owned inventory failed"
  [ "$TASK_PIDS" = "$OFFLINE_OWNED_PID" ] || fail "offline inventory did not isolate the owned process: $TASK_PIDS"
  ID=offline-owned BACKEND=herdr reap_task_worktree_processes worktree "$TEST_DIR/offline-owned" || fail "offline owned reaper failed"
  task_pids_under_roots "$TEST_DIR/offline-owned" || fail "offline post-reap inventory failed"
  [ -z "$TASK_PIDS" ] || fail "offline owned process survived reaping"
) >"$TEST_DIR/offline.out" 2>"$TEST_DIR/offline.err" || fail "offline executable inventory/reaper failed: $(cat "$TEST_DIR/offline.err")"
wait "$OFFLINE_OWNED_PID" 2>/dev/null || true
kill -0 "$UNRELATED_PID" || fail "offline reaper touched the unrelated process"
echo 'ok - offline executable inventory and reaper remove only generated owned processes before Herdr provisioning'
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
  lanes='primary owned-conclude owned-reap wrong-conclude wrong-reap'
  [ "$home" = primary ] || lanes='bravo abort late recover-conclude recover-reap abort-conclude abort-reap recover-forced abort-forced'
  for lane in $lanes; do
    id="$RECOVERY-$lane"
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
endpoint_task_id=$id
EOF
    cp "$FM_HOME/state/$id.meta" "$TEST_DIR/$lane-old.meta"
    cp "$FM_HOME/state/$id.herdr-presentation" "$TEST_DIR/$lane-old.journal"
    fm_lock_release "$TEST_SESSION_LOCK"
  done
done
write_brief "$TEST_DIR/home-primary" "$FRESH-primary"
write_brief "$TEST_DIR/home-bravo" "$FRESH-bravo"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
FOCUS=$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")
: > "$TEST_DIR/mutation-owners"
spawn() { # <home> <task-id> <lane>
  exec env FM_HOME="$TEST_DIR/home-$1" FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    bash "$ROOT/bin/fm-spawn.sh" "$2" "$TEST_DIR/project-$3" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}
teardown() { # <home> <task-id>
  exec env PATH="$TEST_DIR/teardownbin:$PATH" FIXTURE_REAP_LANE="${FIXTURE_REAP_LANE:-}" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$TEST_DIR/home-$1" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$TEST_DIR/home-$1/state" FM_DATA_OVERRIDE="$TEST_DIR/home-$1/data" FM_CONFIG_OVERRIDE="$TEST_DIR/home-$1/config" \
    bash "$ROOT/bin/fm-teardown.sh" "$2" --force
}
await_marker() { # <marker> <pid> <name>
  for ((i=0; i<600; i++)); do
    [ ! -e "$TEST_DIR/$1" ] || return 0
    kill -0 "$2" 2>/dev/null || break
    sleep 0.1
  done
  fail "$3 did not reach $1: $(cat "$TEST_DIR/$3.err")"
}
await_allocation() { await_marker "$1-at-allocation" "$2" "$1"; }
touch "$TEST_DIR/hold-primary"
spawn primary "$RECOVERY-primary" primary >"$TEST_DIR/primary.out" 2>"$TEST_DIR/primary.err" &
PRIMARY_PID=$!
await_allocation primary "$PRIMARY_PID"
# Primary stays alive beyond the contender's entire acquisition window. The
# contender must complete before release, so success cannot come from a retry,
# a larger acquisition deadline, or faster scheduling of the allocation.
spawn bravo "$RECOVERY-bravo" bravo >"$TEST_DIR/bravo.out" 2>"$TEST_DIR/bravo.err" &
BRAVO_PID=$!
wait "$BRAVO_PID" || fail "cross-home recovery failed while primary allocation was held: $(cat "$TEST_DIR/bravo.err")"
BRAVO_PID=
kill -0 "$PRIMARY_PID" || fail "primary allocation was not still held"
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "recovery moved focus"
# Same-task exclusion must survive releasing the session lock.
if (spawn primary "$RECOVERY-primary" primary) >"$TEST_DIR/duplicate.out" 2>"$TEST_DIR/duplicate.err"; then fail "duplicate primary recovery launched"; fi
grep -F 'task set is locked' "$TEST_DIR/duplicate.err" >/dev/null || fail "duplicate did not refuse at the held task-set gate: $(cat "$TEST_DIR/duplicate.err")"
[ "$(cat "$TEST_DIR/home-primary/state/.spawn-$RECOVERY-primary.lock/pid")" = "$PRIMARY_PID" ] || fail "primary lost its per-task lock owner"
touch "$TEST_DIR/release-primary"
wait "$PRIMARY_PID" || fail "primary recovery failed: $(cat "$TEST_DIR/primary.err")"
PRIMARY_PID=
field() { sed -n "s/^$2=//p" "$1"; }
assert_dead() {
  local presence
  presence=$(fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$1")
  [ "$presence" = dead ] || fail "$2: exact pane presence is $presence, not dead"
}
assert_reclaimed() { # <home> <lane>
  local old="$TEST_DIR/$2-old.meta" meta="$TEST_DIR/home-$1/state/$RECOVERY-$2.meta"
  local journal="$TEST_DIR/home-$1/state/$RECOVERY-$2.herdr-presentation"
  [ "$(field "$meta" herdr_workspace_id)" = "$(field "$old" herdr_workspace_id)" ] || fail "$2 workspace identity changed"
  [ "$(field "$meta" herdr_pane_id)" != "$(field "$old" herdr_pane_id)" ] || fail "$2 old husk was reused"
  [ "$(field "$meta" herdr_tab_id)" != "$(field "$old" herdr_tab_id)" ] || fail "$2 old tab was reused"
  [ "$(field "$meta" spawn_gen)" != "$(field "$old" spawn_gen)" ] || fail "$2 generation did not advance"
  [ "$(field "$meta" herdr_pane_id)" = "$(field "$journal" pane_id)" ] || fail "$2 journal and metadata diverged"
  [ "$(field "$journal" projection_id)" = "$(field "$TEST_DIR/$2-old.journal" projection_id)" ] || fail "$2 token changed"
  [ "$(field "$journal" home)" = "$TEST_DIR/home-$1" ] || fail "$2 home custody changed"
  assert_dead "$(field "$old" herdr_pane_id)" "$2 old husk survived or could not be verified"
}
assert_reclaimed primary primary
assert_reclaimed bravo bravo
[ "$(field "$TEST_DIR/home-primary/state/$RECOVERY-primary.meta" spawn_gen)" != "$(field "$TEST_DIR/home-bravo/state/$RECOVERY-bravo.meta" spawn_gen)" ] || fail "home generations were conflated"
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "launch handoff moved focus"
[ "$(cut -f1 "$TEST_DIR/mutation-owners" | sort -u | wc -l | tr -d '[:space:]')" = 2 ] || fail "presentation mutations did not have two exclusive process owners"
echo 'ok - cross-home recovery completes while unrelated allocation is held, preserving task custody, exact binding, generation and focus'

# A reclaimed recovery waits at allocation. A fresh projection from the other
# home then holds its own allocation until the recovery has aborted and a
# later recovery has completed, so neither result can come from the fresh
# allocation finishing within any acquisition window.
: > "$TEST_DIR/mutation-owners"
touch "$TEST_DIR/hold-abort" "$TEST_DIR/fail-abort" "$TEST_DIR/hold-fresh"
spawn bravo "$RECOVERY-abort" abort >"$TEST_DIR/abort.out" 2>"$TEST_DIR/abort.err" &
ABORT_PID=$!
await_allocation abort "$ABORT_PID"
REPLACEMENT_PANE=$(field "$TEST_DIR/home-bravo/state/$RECOVERY-abort.herdr-presentation" pane_id)
[ -n "$REPLACEMENT_PANE" ] && [ "$REPLACEMENT_PANE" != "$(field "$TEST_DIR/abort-old.meta" herdr_pane_id)" ] || fail "abort recovery did not advance its exact journal"
lab pane get "$REPLACEMENT_PANE" >/dev/null || fail "abort replacement pane was not live before setup failed"
spawn primary "$FRESH-primary" fresh >"$TEST_DIR/fresh.out" 2>"$TEST_DIR/fresh.err" &
FRESH_PID=$!
await_allocation fresh "$FRESH_PID"
FRESH_JOURNAL="$TEST_DIR/home-primary/state/$FRESH-primary.herdr-presentation"
FRESH_PANE=$(field "$FRESH_JOURNAL" pane_id)
[ -n "$FRESH_PANE" ] || fail "fresh projection did not publish its exact binding before allocation"
touch "$TEST_DIR/release-abort"
if wait "$ABORT_PID"; then fail "abort recovery launched after its setup failed"; fi
ABORT_PID=
if grep -F 'focus lock unavailable' "$TEST_DIR/abort.err" >/dev/null; then fail "abort cleanup could not reacquire session custody: $(cat "$TEST_DIR/abort.err")"; fi
assert_dead "$REPLACEMENT_PANE" "aborted recovery replacement"
assert_dead "$(field "$TEST_DIR/abort-old.meta" herdr_pane_id)" "aborted recovery old husk"
cmp -s "$TEST_DIR/abort-old.meta" "$TEST_DIR/home-bravo/state/$RECOVERY-abort.meta" || fail "aborted recovery published metadata"
[ "$(field "$TEST_DIR/home-bravo/state/$RECOVERY-abort.herdr-presentation" pane_id)" = "$REPLACEMENT_PANE" ] || fail "aborted recovery rewrote its journal"
lab pane get "$FRESH_PANE" >/dev/null || fail "abort cleanup touched the fresh projection"
(spawn bravo "$RECOVERY-late" late) >"$TEST_DIR/late.out" 2>"$TEST_DIR/late.err" || fail "recovery failed while a fresh projection allocation was held: $(cat "$TEST_DIR/late.err")"
kill -0 "$FRESH_PID" || fail "fresh allocation was not still held"
assert_reclaimed bravo late
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "recovery beside a fresh projection moved focus"
touch "$TEST_DIR/release-fresh"
wait "$FRESH_PID" || fail "fresh projection failed: $(cat "$TEST_DIR/fresh.err")"
FRESH_PID=
FRESH_META="$TEST_DIR/home-primary/state/$FRESH-primary.meta"
[ "$(field "$FRESH_META" herdr_pane_id)" = "$FRESH_PANE" ] || fail "fresh journal and metadata diverged"
[ "$(field "$FRESH_JOURNAL" home)" = "$TEST_DIR/home-primary" ] || fail "fresh home custody changed"
[ "$(field "$FRESH_JOURNAL" parent_workspace_id)" = "$(cat "$TEST_DIR/parent-primary")" ] || fail "fresh projection changed its exact parent"
[ "$(field "$FRESH_META" herdr_workspace_id)" = "$(field "$FRESH_JOURNAL" workspace_id)" ] || fail "fresh workspace custody diverged"
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "fresh launch handoff moved focus"
[ "$(cut -f1 "$TEST_DIR/mutation-owners" | sort -u | wc -l | tr -d '[:space:]')" = 3 ] || fail "presentation mutations did not have the abort, fresh and late process owners"
echo 'ok - recovery and failed-setup abort cleanup complete beside a held fresh projection allocation, preserving exact custody and focus'

# A fresh projection waits at allocation. A teardown from the other home then
# holds its own worktree return until the fresh setup has failed and its abort
# cleanup has finished, so cleanup cannot come from the return finishing within
# any acquisition window.
touch "$TEST_DIR/hold-doomed" "$TEST_DIR/fail-doomed" "$TEST_DIR/hold-return-primary"
spawn bravo "$FRESH-bravo" doomed >"$TEST_DIR/doomed.out" 2>"$TEST_DIR/doomed.err" &
DOOMED_PID=$!
await_allocation doomed "$DOOMED_PID"
DOOMED_JOURNAL="$TEST_DIR/home-bravo/state/$FRESH-bravo.herdr-presentation"
DOOMED_PANE=$(field "$DOOMED_JOURNAL" pane_id)
[ -n "$DOOMED_PANE" ] || fail "doomed fresh projection did not publish its exact binding before allocation"
lab pane get "$DOOMED_PANE" >/dev/null || fail "doomed fresh pane was not live before setup failed"
TORN_META="$TEST_DIR/home-primary/state/$RECOVERY-primary.meta"
TORN_PANE=$(field "$TORN_META" herdr_pane_id)
teardown primary "$RECOVERY-primary" >"$TEST_DIR/teardown.out" 2>"$TEST_DIR/teardown.err" &
TEARDOWN_PID=$!
await_marker primary-at-return "$TEARDOWN_PID" teardown
touch "$TEST_DIR/release-doomed"
if wait "$DOOMED_PID"; then fail "doomed fresh spawn launched after its setup failed"; fi
DOOMED_PID=
kill -0 "$TEARDOWN_PID" || fail "teardown return was not still held while the failed spawn cleaned up"
if grep -F 'focus lock unavailable' "$TEST_DIR/doomed.err" >/dev/null; then fail "fresh abort cleanup could not reacquire session custody beside a held teardown return: $(cat "$TEST_DIR/doomed.err")"; fi
assert_dead "$DOOMED_PANE" "aborted fresh projection"
[ ! -e "$TEST_DIR/home-bravo/state/$FRESH-bravo.meta" ] || fail "aborted fresh projection published metadata"
[ "$(field "$DOOMED_JOURNAL" pane_id)" = "$DOOMED_PANE" ] || fail "aborted fresh projection rewrote its journal"
assert_dead "$TORN_PANE" "teardown pane before held return"
[ -e "$TORN_META" ] || fail "teardown removed its record before its return completed"
touch "$TEST_DIR/release-return-primary"
wait "$TEARDOWN_PID" || fail "teardown failed after its held return: $(cat "$TEST_DIR/teardown.err")"
TEARDOWN_PID=
[ "$(cat "$TEST_DIR/returns")" = primary ] || fail "teardown did not return exactly its own generated copy"
[ ! -e "$TORN_META" ] || fail "teardown kept its task record"
lab pane get "$FRESH_PANE" >/dev/null || fail "teardown touched its home's sibling projection"
lab pane get "$(field "$TEST_DIR/home-bravo/state/$RECOVERY-late.meta" herdr_pane_id)" >/dev/null || fail "abort or teardown touched the other home's live projection"
[ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "abort cleanup beside a held teardown moved focus"
echo 'ok - fresh-projection abort cleanup completes beside a teardown held in its worktree return, preserving exact custody and focus'

assert_owned_cleanup_held() {
  local phase=$1 lane=$2 id=$3 owner=$4
  kill -0 "$owner" || fail "$phase cleanup is no longer held"
  [ -e "$TEST_DIR/$lane-at-$phase" ] || fail "$phase cleanup did not enter its controlled executable"
  [ ! -e "$TEST_DIR/release-$phase-$lane" ] || fail "$phase cleanup was released prematurely"
  [ ! -e "$TEST_DIR/concluded-$lane" ] || [ "$phase" != conclude ] || fail "owned conclusion completed before release"
  [ "$phase" != conclude ] || [ "$(cat "$TEST_DIR/query-seconds-$lane")" -ge 1 ] || fail "owned conclusion did not complete its deliberately delayed bounded query"
  [ "$(cat "$TEST_DIR/home-primary/state/.control-$id.lock/pid")" = "$owner" ] || fail "$phase cleanup lost task custody"
  [ "$(cat "$TEST_DIR/home-primary/state/.meta-$id.lock/pid")" = "$owner" ] || fail "$phase cleanup lost metadata custody"
  fm_lock_try_acquire "$TEST_SESSION_LOCK" || fail "$phase cleanup retained session custody"
  [ "$(cat "$TEST_SESSION_LOCK/pid")" = "$$" ] || fail "$phase session release probe did not own the lock"
  printf '%s\t%s\t%s\n' "$phase" "$owner" "$$" >> "$TEST_DIR/cleanup-release-owners"
  fm_lock_release "$TEST_SESSION_LOCK"
}
assert_siblings() {
  local home meta journal
  for home in primary bravo; do
    meta="$FRESH_META"
    [ "$home" = primary ] || meta="$TEST_DIR/home-bravo/state/$RECOVERY-late.meta"
    journal="${meta%.meta}.herdr-presentation"
    cmp -s "$TEST_DIR/sibling-$home.meta" "$meta" || fail "owned cleanup changed $home sibling metadata"
    cmp -s "$TEST_DIR/sibling-$home.journal" "$journal" || fail "owned cleanup changed $home sibling journal"
    [ "$(fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$(field "$meta" herdr_pane_id)")" = present ] || fail "owned cleanup touched $home sibling pane"
  done
  [ "$(fm_backend_herdr_projection_focus_snapshot "$HERDR_LAB_SESSION")" = "$FOCUS" ] || fail "owned cleanup moved sibling focus"
}
cp "$FRESH_META" "$TEST_DIR/sibling-primary.meta"
cp "$FRESH_JOURNAL" "$TEST_DIR/sibling-primary.journal"
cp "$TEST_DIR/home-bravo/state/$RECOVERY-late.meta" "$TEST_DIR/sibling-bravo.meta"
cp "$TEST_DIR/home-bravo/state/$RECOVERY-late.herdr-presentation" "$TEST_DIR/sibling-bravo.journal"
: > "$TEST_DIR/cleanup-release-owners"
for phase in conclude reap; do
  : > "$TEST_DIR/mutation-owners"
  lane="owned-$phase"
  id="$RECOVERY-$lane"
  recover="recover-$phase"
  abort="abort-$phase"
  fresh="fresh-$phase"
  fresh_id="$FRESH-$phase"
  write_brief "$TEST_DIR/home-bravo" "$fresh_id"
  touch "$TEST_DIR/fail-$abort" "$TEST_DIR/fail-$fresh"
  owned_meta="$TEST_DIR/home-primary/state/$id.meta"
  owned_pane=$(field "$owned_meta" herdr_pane_id)
  fixture_process "$TEST_DIR/copy-$lane"
  owned_pid=$FIXTURE_PID
  touch "$TEST_DIR/hold-$phase-$lane"
  [ "$phase" != conclude ] || touch "$TEST_DIR/run-$lane"
  FIXTURE_REAP_LANE=$lane teardown primary "$id" >"$TEST_DIR/teardown.out" 2>"$TEST_DIR/teardown.err" &
  TEARDOWN_PID=$!
  teardown_owner=$TEARDOWN_PID
  await_marker "$lane-at-$phase" "$TEARDOWN_PID" teardown
  assert_owned_cleanup_held "$phase" "$lane" "$id" "$TEARDOWN_PID"
  if (teardown primary "$id") >"$TEST_DIR/duplicate.out" 2>"$TEST_DIR/duplicate.err"; then fail "$phase duplicate teardown escaped task custody"; fi
  grep -F 'another lifecycle action is already running' "$TEST_DIR/duplicate.err" >/dev/null || fail "$phase duplicate did not refuse at task custody"
  spawn bravo "$RECOVERY-$recover" "$recover" >"$TEST_DIR/$recover.out" 2>"$TEST_DIR/$recover.err" &
  BRAVO_PID=$!
  recover_owner=$BRAVO_PID
  wait "$BRAVO_PID" || fail "$phase recovery failed: $(cat "$TEST_DIR/$recover.err")"
  BRAVO_PID=
  assert_owned_cleanup_held "$phase" "$lane" "$id" "$TEARDOWN_PID"
  spawn bravo "$RECOVERY-$abort" "$abort" >"$TEST_DIR/$abort.out" 2>"$TEST_DIR/$abort.err" &
  ABORT_PID=$!
  abort_owner=$ABORT_PID
  if wait "$ABORT_PID"; then fail "$phase reclaimed abort unexpectedly launched"; fi
  ABORT_PID=
  assert_owned_cleanup_held "$phase" "$lane" "$id" "$TEARDOWN_PID"
  spawn bravo "$fresh_id" "$fresh" >"$TEST_DIR/$fresh.out" 2>"$TEST_DIR/$fresh.err" &
  DOOMED_PID=$!
  fresh_owner=$DOOMED_PID
  if wait "$DOOMED_PID"; then fail "$phase fresh abort unexpectedly launched"; fi
  DOOMED_PID=
  abort_pane=$(field "$TEST_DIR/home-bravo/state/$RECOVERY-$abort.herdr-presentation" pane_id)
  fresh_pane=$(field "$TEST_DIR/home-bravo/state/$fresh_id.herdr-presentation" pane_id)
  assert_owned_cleanup_held "$phase" "$lane" "$id" "$TEARDOWN_PID"
  assert_dead "$abort_pane" "$phase reclaimed abort replacement"
  assert_dead "$(field "$TEST_DIR/$abort-old.meta" herdr_pane_id)" "$phase reclaimed abort husk"
  assert_dead "$fresh_pane" "$phase fresh abort exact pane"
  cmp -s "$TEST_DIR/$abort-old.meta" "$TEST_DIR/home-bravo/state/$RECOVERY-$abort.meta" || fail "$phase aborted recovery published metadata"
  [ ! -e "$TEST_DIR/home-bravo/state/$fresh_id.meta" ] || fail "$phase fresh abort published metadata"
  [ "$(field "$TEST_DIR/home-bravo/state/$RECOVERY-$abort.herdr-presentation" pane_id)" = "$abort_pane" ] || fail "$phase reclaimed abort rewrote binding"
  [ "$(field "$TEST_DIR/home-bravo/state/$fresh_id.herdr-presentation" pane_id)" = "$fresh_pane" ] || fail "$phase fresh abort rewrote binding"
  assert_reclaimed bravo "$recover"
  [ "$(fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$owned_pane")" = present ] || fail "$phase teardown mutated its endpoint before cleanup finished"
  kill -0 "$owned_pid" || fail "$phase owned process was reaped before the held cleanup finished"
  assert_siblings
  [ "$(cut -f1 "$TEST_DIR/mutation-owners" | sort -u)" = "$(printf '%s\n' "$recover_owner" "$abort_owner" "$fresh_owner" | sort -u)" ] || fail "$phase held cleanup presentation mutations had unexpected session-lock owners"
  touch "$TEST_DIR/release-$phase-$lane"
  wait "$TEARDOWN_PID" || fail "$phase teardown failed: $(cat "$TEST_DIR/teardown.err")"
  TEARDOWN_PID=
  wait "$owned_pid" 2>/dev/null || true
  assert_dead "$owned_pane" "$phase owned teardown"
  [ ! -e "$owned_meta" ] || fail "$phase teardown retained metadata after success"
  [ "$phase" != conclude ] || [ "$(cat "$TEST_DIR/conclusions")" = "$lane" ] || fail "conclusion did not abort exactly its owned run"
  grep -F "reaping leaked worktree process(es) for $id: $owned_pid" "$TEST_DIR/teardown.err" >/dev/null || fail "$phase teardown did not exercise actual owned process reaping"
  kill -0 "$UNRELATED_PID" || fail "$phase teardown reaped the unrelated process"
  assert_siblings
  [ "$(cut -f1 "$TEST_DIR/mutation-owners" | sort -u)" = "$(printf '%s\n' "$teardown_owner" "$recover_owner" "$abort_owner" "$fresh_owner" | sort -u)" ] || fail "$phase released cleanup presentation mutations lost exact session-lock ownership"
  echo "ok - recovery and fresh/reclaimed abort cleanup complete beside held actual owned $phase, with task/meta custody, session release and exact sibling focus"
done

FORCED_PARENT_ID="$RECOVERY-forced-parent"
FORCED_NESTED_ID="$RECOVERY-forced-nested"
FORCED_CHILD_ID="$RECOVERY-forced-child"
FORCED_HOME="$TEST_DIR/home-forced"
FORCED_NESTED_HOME="$FORCED_HOME/nested"
"$LAB_HOME_HELPER" create "$FORCED_HOME" >/dev/null
"$LAB_HOME_HELPER" create "$FORCED_NESTED_HOME" >/dev/null
printf '%s\n' "$FORCED_PARENT_ID" > "$FORCED_HOME/.fm-secondmate-home"
printf '%s\n' "$FORCED_NESTED_ID" > "$FORCED_NESTED_HOME/.fm-secondmate-home"
mkdir "$TEST_DIR/forced-code-root"
ln -s "$ROOT/bin" "$TEST_DIR/forced-code-root/bin"
flat_fixture_meta() {
  local home=$1 id=$2 lane=$3 kind=$4 worktree=$5 child_home=$6 out ws tab pane
  fm_lock_try_acquire "$TEST_SESSION_LOCK"
  out=$(lab workspace create --cwd "$TEST_DIR/project-$lane" --label "fixture-$id" --no-focus)
  ws=$(printf '%s\n' "$out" | jq -r '.result.workspace.workspace_id')
  tab=$(printf '%s\n' "$out" | jq -r '.result.tab.tab_id')
  pane=$(printf '%s\n' "$out" | jq -r '.result.root_pane.pane_id')
  [ "$ws" != null ] && [ "$tab" != null ] && [ "$pane" != null ] || fail "forced fixture lacks its exact flat binding"
  cat > "$home/state/$id.meta" <<EOF
window=$HERDR_LAB_SESSION:$pane
endpoint_task_id=$id
worktree=$worktree
project=$TEST_DIR/project-$lane
home=$child_home
kind=$kind
mode=local-only
harness=sh
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
spawn_gen=fixture-$id
EOF
  fm_lock_release "$TEST_SESSION_LOCK"
}
flat_fixture_meta "$TEST_DIR/home-primary" "$FORCED_PARENT_ID" forced-parent secondmate "$FORCED_HOME" "$FORCED_HOME"
flat_fixture_meta "$FORCED_HOME" "$FORCED_NESTED_ID" forced-nested secondmate "$FORCED_NESTED_HOME" "$FORCED_NESTED_HOME"
flat_fixture_meta "$FORCED_NESTED_HOME" "$FORCED_CHILD_ID" forced-child ship "$TEST_DIR/copy-forced-child" ''
FORCED_PARENT_PANE=$(field "$TEST_DIR/home-primary/state/$FORCED_PARENT_ID.meta" herdr_pane_id)
FORCED_NESTED_PANE=$(field "$FORCED_HOME/state/$FORCED_NESTED_ID.meta" herdr_pane_id)
FORCED_CHILD_PANE=$(field "$FORCED_NESTED_HOME/state/$FORCED_CHILD_ID.meta" herdr_pane_id)
cp "$FORCED_NESTED_HOME/state/$FORCED_CHILD_ID.meta" "$TEST_DIR/forced-child-before.meta"
touch "$TEST_DIR/hold-return-forced-child"
env PATH="$TEST_DIR/teardownbin:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$TEST_DIR/home-primary" \
  FM_ROOT_OVERRIDE="$TEST_DIR/forced-code-root" bash "$ROOT/bin/fm-teardown.sh" "$FORCED_PARENT_ID" --force >"$TEST_DIR/teardown.out" 2>"$TEST_DIR/teardown.err" &
TEARDOWN_PID=$!
await_marker forced-child-at-return "$TEARDOWN_PID" teardown
assert_forced_return_held() {
  local home id lock
  assert_owned_cleanup_held return forced-child "$FORCED_PARENT_ID" "$TEARDOWN_PID"
  for home in "$FORCED_HOME" "$FORCED_NESTED_HOME"; do
    lock=$(fm_task_set_lock_path "$home/state")
    [ "$(cat "$lock/pid")" = "$TEARDOWN_PID" ] || fail "forced recursion lost descendant task-set custody"
  done
  for id in "$FORCED_NESTED_ID" "$FORCED_CHILD_ID"; do
    home=$FORCED_HOME
    [ "$id" = "$FORCED_NESTED_ID" ] || home=$FORCED_NESTED_HOME
    [ "$(cat "$home/state/.control-$id.lock/pid")" = "$TEARDOWN_PID" ] || fail "forced recursion lost descendant task custody"
    [ "$(cat "$home/state/.meta-$id.lock/pid")" = "$TEARDOWN_PID" ] || fail "forced recursion lost descendant metadata custody"
  done
  cmp -s "$TEST_DIR/forced-child-before.meta" "$FORCED_NESTED_HOME/state/$FORCED_CHILD_ID.meta" || fail "forced recursion removed child identity before its return completed"
  assert_dead "$FORCED_CHILD_PANE" "forced recursive child before held return"
  [ -d "$TEST_DIR/copy-forced-child" ] || fail "forced child copy vanished before return release"
  assert_siblings
}
assert_forced_return_held
spawn bravo "$RECOVERY-recover-forced" recover-forced >"$TEST_DIR/recover-forced.out" 2>"$TEST_DIR/recover-forced.err" &
BRAVO_PID=$!
wait "$BRAVO_PID" || fail "recovery failed beside forced recursive return: $(cat "$TEST_DIR/recover-forced.err")"
BRAVO_PID=
assert_reclaimed bravo recover-forced
assert_forced_return_held
touch "$TEST_DIR/fail-abort-forced" "$TEST_DIR/fail-fresh-forced"
spawn bravo "$RECOVERY-abort-forced" abort-forced >"$TEST_DIR/abort-forced.out" 2>"$TEST_DIR/abort-forced.err" &
ABORT_PID=$!
if wait "$ABORT_PID"; then fail "forced-return reclaimed abort unexpectedly launched"; fi
ABORT_PID=
assert_dead "$(field "$TEST_DIR/home-bravo/state/$RECOVERY-abort-forced.herdr-presentation" pane_id)" "forced-return reclaimed abort replacement"
assert_dead "$(field "$TEST_DIR/abort-forced-old.meta" herdr_pane_id)" "forced-return reclaimed abort husk"
cmp -s "$TEST_DIR/abort-forced-old.meta" "$TEST_DIR/home-bravo/state/$RECOVERY-abort-forced.meta" || fail "forced-return reclaimed abort published metadata"
assert_forced_return_held
write_brief "$TEST_DIR/home-bravo" "$FRESH-forced"
spawn bravo "$FRESH-forced" fresh-forced >"$TEST_DIR/fresh-forced.out" 2>"$TEST_DIR/fresh-forced.err" &
DOOMED_PID=$!
if wait "$DOOMED_PID"; then fail "forced-return fresh abort unexpectedly launched"; fi
DOOMED_PID=
assert_dead "$(field "$TEST_DIR/home-bravo/state/$FRESH-forced.herdr-presentation" pane_id)" "forced-return fresh abort exact pane"
[ ! -e "$TEST_DIR/home-bravo/state/$FRESH-forced.meta" ] || fail "forced-return fresh abort published metadata"
assert_forced_return_held
touch "$TEST_DIR/release-return-forced-child"
wait "$TEARDOWN_PID" || fail "forced recursive teardown failed after its return release: $(cat "$TEST_DIR/teardown.err")"
TEARDOWN_PID=
assert_dead "$FORCED_PARENT_PANE" "forced parent teardown"
assert_dead "$FORCED_NESTED_PANE" "forced nested secondmate teardown"
assert_dead "$FORCED_CHILD_PANE" "forced grandchild teardown"
[ ! -e "$FORCED_HOME" ] || fail "forced recursive teardown retained its generated child home"
[ ! -e "$TEST_DIR/home-primary/state/$FORCED_PARENT_ID.meta" ] || fail "forced recursive teardown retained its parent record"
[ "$(grep -Fxc forced-child "$TEST_DIR/returns")" = 1 ] || fail "forced recursive teardown did not return exactly its generated grandchild copy once"
assert_siblings
echo 'ok - recovery and fresh/reclaimed abort cleanup complete beside a held forced-secondmate recursive child return, preserving descendant task/meta custody and exact sibling focus'

bootstrap_primary() {
  env PATH="$TEST_DIR/teardownbin:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_HOME="$TEST_DIR/home-primary" FM_ROOT_OVERRIDE="$ROOT" TASKS_AXI_BACKEND=markdown \
    bash "$ROOT/bin/fm-bootstrap.sh"
}
export TASKS_AXI_BACKEND=markdown
printf '%s\n' markdown > "$TEST_DIR/home-primary/config/backlog-backend"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$TEST_DIR/home-primary/data/backlog.md"
for phase in conclude reap; do
  id="$RECOVERY-wrong-$phase"
  tasks-axi add "$id" 'Owned cleanup refusal fixture' --kind ship --file "$TEST_DIR/home-primary/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$TEST_DIR/home-primary/data/backlog.md" >/dev/null
done
tasks-axi hold "$RECOVERY-wrong-reap" --reason 'Captain must choose the retained result' --kind captain --file "$TEST_DIR/home-primary/data/backlog.md" >/dev/null
for phase in conclude reap; do
  lane="wrong-$phase"
  id="$RECOVERY-$lane"
  meta="$TEST_DIR/home-primary/state/$id.meta"
  journal="${meta%.meta}.herdr-presentation"
  pane=$(field "$meta" herdr_pane_id)
  copy_head=$(git -C "$TEST_DIR/copy-$lane" rev-parse HEAD)
  printf 'pr=https://github.com/example/fixture/pull/1\n' >> "$meta"
  cp "$journal" "$TEST_DIR/$lane-before.journal"
  cp "$meta" "$TEST_DIR/$lane-before.meta"
  awk '/^herdr_pane_id=/ { print "herdr_pane_id=wrong-pane"; next } { print }' "$meta" > "$TEST_DIR/$lane-wrong.meta"
  cp "$TEST_DIR/$lane-wrong.meta" "$meta"
  cp "$TEST_DIR/home-primary/data/backlog.md" "$TEST_DIR/$lane-backlog.before"
  if (teardown primary "$id") >"$TEST_DIR/teardown.out" 2>"$TEST_DIR/teardown.err"; then fail "$phase teardown accepted wrong exact endpoint"; fi
  cmp -s "$TEST_DIR/$lane-wrong.meta" "$meta" || fail "$phase wrong-identity refusal changed metadata"
  [ ! -e "$TEST_DIR/home-primary/state/$id.backlog-close" ] || fail "$phase wrong-identity refusal published an authoritative marker"
  bootstrap_primary >"$TEST_DIR/$lane-startup-wrong.out" 2>"$TEST_DIR/$lane-startup-wrong.err" || fail "$phase startup after wrong-identity refusal failed"
  cmp -s "$TEST_DIR/$lane-wrong.meta" "$meta" || fail "$phase startup removed wrong-identity retained metadata"
  cmp -s "$TEST_DIR/$lane-backlog.before" "$TEST_DIR/home-primary/data/backlog.md" || fail "$phase startup applied a refused backlog transition"
  [ "$(fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$pane")" = present ] || fail "$phase wrong-identity startup lost the reconcilable endpoint"
  cmp -s "$TEST_DIR/$lane-before.journal" "$journal" || fail "$phase wrong-identity startup changed journal custody"
  [ -d "$TEST_DIR/copy-$lane/.git" ] && [ "$(git -C "$TEST_DIR/copy-$lane" rev-parse HEAD)" = "$copy_head" ] || fail "$phase wrong-identity startup lost the isolated copy"
  if grep -Fx "$lane" "$TEST_DIR/returns" >/dev/null; then fail "$phase wrong-identity startup returned the isolated copy"; fi
  assert_siblings
  cp "$TEST_DIR/$lane-before.meta" "$meta"
  touch "$TEST_DIR/hold-$phase-$lane"
  [ "$phase" != conclude ] || touch "$TEST_DIR/run-$lane"
  FIXTURE_REAP_LANE=$lane teardown primary "$id" >"$TEST_DIR/teardown.out" 2>"$TEST_DIR/teardown.err" &
  TEARDOWN_PID=$!
  await_marker "$lane-at-$phase" "$TEARDOWN_PID" teardown
  assert_owned_cleanup_held "$phase" "$lane" "$id" "$TEARDOWN_PID"
  replacement_gen="replaced-$phase"
  awk -v gen="$replacement_gen" '/^spawn_gen=/ { print "spawn_gen=" gen; next } { print }' "$meta" > "$TEST_DIR/$lane-replaced.meta"
  cp "$TEST_DIR/$lane-replaced.meta" "$meta"
  touch "$TEST_DIR/release-$phase-$lane"
  if wait "$TEARDOWN_PID"; then fail "$phase teardown accepted replaced generation"; fi
  TEARDOWN_PID=
  grep -F 'endpoint metadata or spawn generation changed after admission' "$TEST_DIR/teardown.err" >/dev/null || fail "$phase replaced generation refused outside the exact revalidation boundary: $(cat "$TEST_DIR/teardown.err")"
  cmp -s "$TEST_DIR/$lane-replaced.meta" "$meta" || fail "$phase refusal changed replacement metadata"
  cmp -s "$TEST_DIR/$lane-before.journal" "$journal" || fail "$phase refusal changed journal identity"
  [ "$(fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$pane")" = present ] || fail "$phase refusal touched the replaced generation endpoint"
  if grep -Fx "$lane" "$TEST_DIR/returns" >/dev/null; then fail "$phase refusal returned replaced generation copy"; fi
  [ ! -e "$TEST_DIR/home-primary/state/$id.backlog-close" ] || fail "$phase replaced-generation refusal published an authoritative marker"
  bootstrap_primary >"$TEST_DIR/$lane-startup-replaced.out" 2>"$TEST_DIR/$lane-startup-replaced.err" || fail "$phase startup after replaced-generation refusal failed"
  cmp -s "$TEST_DIR/$lane-replaced.meta" "$meta" || fail "$phase startup removed replacement generation metadata"
  cmp -s "$TEST_DIR/$lane-backlog.before" "$TEST_DIR/home-primary/data/backlog.md" || fail "$phase startup applied a replaced-generation transition"
  [ "$(fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$pane")" = present ] || fail "$phase replaced-generation startup lost the reconcilable endpoint"
  cmp -s "$TEST_DIR/$lane-before.journal" "$journal" || fail "$phase replaced-generation startup changed journal custody"
  [ -d "$TEST_DIR/copy-$lane/.git" ] && [ "$(git -C "$TEST_DIR/copy-$lane" rev-parse HEAD)" = "$copy_head" ] || fail "$phase replaced-generation startup lost the isolated copy"
  if grep -Fx "$lane" "$TEST_DIR/returns" >/dev/null; then fail "$phase replaced-generation startup returned the isolated copy"; fi
  assert_siblings
  echo "ok - owned $phase refuses exact replaced generation before endpoint, journal, worktree or record mutation"
  touch "$TEST_DIR/fail-transition-$id"
  if (teardown primary "$id") >"$TEST_DIR/teardown.out" 2>"$TEST_DIR/teardown.err"; then fail "$phase controlled backlog interruption did not defer replay"; fi
  marker="$TEST_DIR/home-primary/state/$id.backlog-close"
  [ -f "$marker" ] || fail "$phase admitted cleanup lost its deferred marker"
  [ "$(field "$marker" spawn_gen)" = "$replacement_gen" ] || fail "$phase deferred marker names the wrong generation"
  if [ "$phase" = reap ]; then
    [ "$(field "$marker" mode)" = retain ] || fail "captain-held deferred marker lost retain mode"
  else
    [ -z "$(field "$marker" mode)" ] || fail "ordinary deferred close became retention"
  fi
  assert_dead "$pane" "$phase deferred cleanup exact endpoint"
  [ ! -e "$meta" ] || fail "$phase transition interruption recreated removed metadata"
  rm "$TEST_DIR/fail-transition-$id"
  bootstrap_primary >"$TEST_DIR/$lane-replay.out" 2>"$TEST_DIR/$lane-replay.err" || fail "$phase actual startup replay failed"
  [ ! -e "$marker" ] || fail "$phase actual startup did not consume its deferred marker"
  row=$(tasks-axi show "$id" --file "$TEST_DIR/home-primary/data/backlog.md" --full)
  if [ "$phase" = reap ]; then
    printf '%s\n' "$row" | grep -F '  state: queued' >/dev/null || fail "captain-held replay did not retain the row queued"
    printf '%s\n' "$row" | grep -F '  hold_kind: captain' >/dev/null || fail "captain-held replay lost the captain decision"
    printf '%s\n' "$row" | grep -F 'https://github.com/example/fixture/pull/1' >/dev/null || fail "captain-held replay lost its deliverable"
  else
    printf '%s\n' "$row" | grep -F '  state: done' >/dev/null || fail "ordinary startup replay did not close its row"
  fi
  assert_siblings
  echo "ok - $phase pre-mutation refusal survives actual startup; admitted deferred $([ "$phase" = reap ] && printf retain || printf close) replays only its exact generation"
done
