#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-snapshot-window)
HOME_DIR=$TMP_ROOT/home
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
REAL_JQ=$(command -v jq)
REAL_CP=$(command -v cp)
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME_DIR/wt"

cat > "$TMP_ROOT/read-hooks.sh" <<'SH'
task_read_start() {
  local phase=$1 id=$2 deadline
  [ -n "${FM_TEST_READ_TRACE:-}" ] || return 0
  printf 'start %s\n' "$id" >> "$FM_TEST_READ_TRACE/$phase.log"
  deadline=$((SECONDS + 10))
  if [ "$id" = task-01 ]; then
    : > "$FM_TEST_READ_TRACE/$phase.first-started"
    while [ ! -e "$FM_TEST_READ_TRACE/$phase.ninth-started" ]; do
      [ "$SECONDS" -lt "$deadline" ] || break
      sleep 0.05
    done
  else
    while [ ! -e "$FM_TEST_READ_TRACE/$phase.first-started" ]; do
      [ "$SECONDS" -lt "$deadline" ] || return 90
      sleep 0.05
    done
    if [ "$id" = task-09 ]; then
      if [ ! -e "$FM_TEST_READ_TRACE/$phase.first-ended" ]; then
        : > "$FM_TEST_READ_TRACE/$phase.overlap"
      fi
      : > "$FM_TEST_READ_TRACE/$phase.ninth-started"
    fi
  fi
}

task_read_end() {
  local phase=$1 id=$2
  [ -n "${FM_TEST_READ_TRACE:-}" ] || return 0
  printf 'end %s\n' "$id" >> "$FM_TEST_READ_TRACE/$phase.log"
  if [ "$id" = task-01 ]; then
    : > "$FM_TEST_READ_TRACE/$phase.first-ended"
  fi
  return 0
}
SH
cat > "$FAKEBIN/cp" <<'SH'
#!/usr/bin/env bash
. "$FM_TEST_READ_HOOKS"
id=''
for arg in "$@"; do
  case "$arg" in
    "$FM_HOME"/state/task-??.status)
      id=${arg##*/}
      id=${id%.status}
      ;;
  esac
done
[ -n "$id" ] || exec "$FM_TEST_REAL_CP" "$@"
task_read_start observations "$id" || exit $?
rc=0
if [ "${FM_TEST_FAIL_PHASE:-}" = observations ] && [ "$id" = task-02 ]; then
  rc=7
else
  "$FM_TEST_REAL_CP" "$@" || rc=$?
fi
task_read_end observations "$id"
exit "$rc"
SH
cat > "$FAKEBIN/jq" <<'SH'
#!/usr/bin/env bash
. "$FM_TEST_READ_HOOKS"
id=''
previous=''
for arg in "$@"; do
  if [ "$previous" = id ]; then
    case "$arg" in task-??) id=$arg ;; esac
  fi
  previous=$arg
done
[ -n "$id" ] || exec "$FM_TEST_REAL_JQ" "$@"
task_read_start composition "$id" || exit $?
rc=0
if [ "${FM_TEST_FAIL_PHASE:-}" = composition ] && [ "$id" = task-02 ]; then
  rc=7
else
  "$FM_TEST_REAL_JQ" "$@" || rc=$?
fi
task_read_end composition "$id"
exit "$rc"
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    for id in 01 02 03 04 05 06 07 08 09; do printf 'fm-task-%s\n' "$id"; done
    ;;
  display-message) printf 'codex\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/cp" "$FAKEBIN/jq" "$FAKEBIN/no-mistakes" "$FAKEBIN/tmux"

for n in 01 02 03 04 05 06 07 08 09; do
  fm_write_meta "$HOME_DIR/state/task-$n.meta" \
    "window=firstmate:fm-task-$n" "worktree=$HOME_DIR/wt" \
    'project=alpha' 'harness=claude' 'kind=ship' 'mode=ship' 'spawn_gen=fixture'
  printf 'working [at=1791450000]: task %s\n' "$n" > "$HOME_DIR/state/task-$n.status"
done

run_snapshot() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SNAPSHOT_NOW=2026-10-08T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1791460800 \
    FM_TEST_READ_HOOKS="$TMP_ROOT/read-hooks.sh" \
    FM_TEST_REAL_CP="$REAL_CP" FM_TEST_REAL_JQ="$REAL_JQ" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --home-input
}

FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=1 run_snapshot > "$TMP_ROOT/serial.json" 2> "$TMP_ROOT/serial.err" \
  || fail "serialized snapshot failed: $(cat "$TMP_ROOT/serial.err")"
mkdir -p "$TMP_ROOT/trace"
FM_TEST_READ_TRACE="$TMP_ROOT/trace" FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=8 \
  run_snapshot > "$TMP_ROOT/parallel.json" 2> "$TMP_ROOT/parallel.err" \
  || fail "rolling snapshot failed: $(cat "$TMP_ROOT/parallel.err")"
for phase in observations composition; do
  [ -e "$TMP_ROOT/trace/$phase.overlap" ] \
    || fail "$phase did not start task 9 before the first read ended"
  jq -R -s -e '
    [splits("\n") | select(length > 0) | split(" ")] as $events
    | (reduce $events[] as $event ({active:0,peak:0,valid:true};
        .active += (if $event[0] == "start" then 1 else -1 end)
        | .peak = ([.peak,.active] | max)
        | .valid = (.valid and .active >= 0 and .active <= 8))) as $window
    | $window.valid and $window.active == 0
      and ([$events[] | select(.[0] == "start") | .[1]] | sort)
        == [range(1;10) | "task-0\(.)"]
      and ([$events[] | select(.[0] == "end") | .[1]] | sort)
        == [range(1;10) | "task-0\(.)"]
  ' "$TMP_ROOT/trace/$phase.log" >/dev/null \
    || fail "$phase exceeded eight active reads or lost a task"
done
cmp -s "$TMP_ROOT/serial.json" "$TMP_ROOT/parallel.json" \
  || fail 'completion-order scheduling changed snapshot bytes'
jq -e '.schema == "fm-fleet-home-input.v1" and [.tasks[].id] == [range(1;10) | "task-0\(.)"]' \
  "$TMP_ROOT/parallel.json" >/dev/null || fail 'snapshot lost final ID ordering'
pass 'both windows start task 9 before the first read ends within the eight-worker bound'
pass 'completion-order scheduling preserves byte-identical ID-sorted output'

for phase in observations composition; do
  rc=0
  FM_TEST_FAIL_PHASE="$phase" FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=8 \
    run_snapshot > "$TMP_ROOT/failure.json" 2> "$TMP_ROOT/failure.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "$phase child failure returned $rc instead of 1"
  [ ! -s "$TMP_ROOT/failure.json" ] || fail "$phase failure published a partial snapshot"
  case "$phase" in
    observations) diagnostic='task observation failed' ;;
    composition) diagnostic='task snapshot failed' ;;
  esac
  assert_contains "$(cat "$TMP_ROOT/failure.err")" "$diagnostic" "$phase lost the child exit status"
  pass "$phase retains a failed child's status after replenishing its slot"
done
