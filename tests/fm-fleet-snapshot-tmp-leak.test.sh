#!/usr/bin/env bash
# Behavior tests for the scratch directories bin/fm-fleet-snapshot.sh makes in TMPDIR.
#
# The leak this pins: a snapshot cut short by a bound or a signal left its
# fm-fleet-tasks.* directory behind, one per interrupted run (2145 of them, with
# 71 fm-fleet-snapshot.*, piled up in a shared temp dir and slowed every scan of
# it). TERM, INT and HUP must leave nothing. KILL cannot run any cleanup, so the
# next run must remove what a dead owner left, without touching a live run's
# directories or any directory this script did not name for an owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-snapshot-tmp-leak)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FM_HOME_DIR="$TMP_ROOT/home"
SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$FM_HOME_DIR/state" "$FM_HOME_DIR/data" "$FM_HOME_DIR/config" "$FM_HOME_DIR/projects" "$SCRATCH"
fm_write_meta "$FM_HOME_DIR/state/task.meta" 'kind=ship'

# A directory this script did not name for an owner: it must survive every run.
LEGACY="$SCRATCH/fm-fleet-tasks.LEGACY"
mkdir "$LEGACY"

# Copying the task's metadata is the first foreground step after the task
# directory exists, so a stalled copy holds the run open at the right moment.
cat > "$FAKEBIN/cp" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_STALL_PIDFILE:-}" ]; then
  case "$*" in
    *task.meta*)
      fm_test_record_process "$FM_TEST_STALL_PIDFILE" "$$"
      exec sleep 60
      ;;
  esac
fi
exec /bin/cp "$@"
SH
chmod +x "$FAKEBIN/cp"

snapshot_env() {  # <command...>
  env PATH="$FAKEBIN:$PATH" FM_HOME="$FM_HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" TMPDIR="$SCRATCH" "$@"
}

scratch_dirs() {  # the snapshot's own directories, minus the planted one
  local entry
  for entry in "$SCRATCH"/fm-fleet-*; do
    [ -e "$entry" ] || continue
    [ "$entry" != "$LEGACY" ] || continue
    printf '%s\n' "${entry##*/}"
  done
}

run_to_completion() {
  snapshot_env bash "$ROOT/bin/fm-fleet-snapshot.sh" --json >/dev/null 2>&1 \
    || fail "a snapshot run on a clean fixture failed"
}

# stall_run <name>: start a snapshot held open mid-run; sets RUN_PID, STUB_PID.
stall_run() {
  local pidfile="$TMP_ROOT/stall.$1.pid" tries=0
  fm_test_track_process "$pidfile" "sleep 60"
  # The job is started without a wrapper function so that its pid is the
  # snapshot's own, and perl restores the default SIGINT that a background shell
  # job would ignore.
  # shellcheck disable=SC2016 # perl expands its own variables.
  env PATH="$FAKEBIN:$PATH" FM_HOME="$FM_HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" TMPDIR="$SCRATCH" \
    FM_TEST_STALL_PIDFILE="$pidfile" perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' \
    bash "$ROOT/bin/fm-fleet-snapshot.sh" --json >/dev/null 2>&1 &
  RUN_PID=$!
  while [ ! -s "$pidfile" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 1200 ] || fail "the $1 run never reached its stalled copy"
    sleep 0.05
  done
  IFS=$'\t' read -r STUB_PID _ < "$pidfile"
  [ -n "$(scratch_dirs)" ] || fail "the $1 run made no scratch directory, so the case proves nothing"
}

# Releasing the stalled copy lets a deferred TERM, INT or HUP handler run.
finish_run() {
  kill -KILL "$STUB_PID" 2>/dev/null || true
  wait "$RUN_PID" 2>/dev/null || true
}

run_to_completion
[ -z "$(scratch_dirs)" ] || fail "a completed run left scratch directories: $(scratch_dirs)"
pass "a completed snapshot leaves no scratch directory"

for sig in TERM INT HUP; do
  stall_run "$sig"
  kill -"$sig" "$RUN_PID"
  finish_run
  [ -z "$(scratch_dirs)" ] || fail "a snapshot ended by $sig left scratch directories: $(scratch_dirs)"
  pass "a snapshot ended by $sig leaves no scratch directory"
done

stall_run KILL
kill -KILL "$RUN_PID"
finish_run
[ -n "$(scratch_dirs)" ] || fail "a KILLed snapshot left nothing, so the sweep case proves nothing"
run_to_completion
[ -z "$(scratch_dirs)" ] || fail "the next run did not remove a dead owner's directories: $(scratch_dirs)"
pass "the next snapshot removes the directories a KILLed one left"

stall_run live
LIVE_DIRS=$(scratch_dirs)
run_to_completion
[ "$(scratch_dirs)" = "$LIVE_DIRS" ] || fail "a second run disturbed a live run's directories: $(scratch_dirs)"
finish_run
[ -z "$(scratch_dirs)" ] || fail "the live run left scratch directories once it ended: $(scratch_dirs)"
pass "a second snapshot leaves a live snapshot's directories alone"

[ -d "$LEGACY" ] || fail "a snapshot removed a directory that names no owner"
pass "directories that name no owner are never removed"
