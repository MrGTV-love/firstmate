#!/usr/bin/env bash
# Behavior tests for processes that an ended test run leaves behind.
#
# The leak this pins: a fixture's stub (a lock holder, a polling fake) is started
# in a subshell or disowned, so the test's job-table reaping cannot see it, and a
# test killed hard never runs its cleanup trap at all. Removing the fixture
# directory does not stop the stub, which then polls for hours. Observed
# 2026-10-08: a poll-publish-holder.sh stub with seven CPU-minutes, parent pid 1.
#
# bin/fm-test-reap-orphans.sh stops such a stub only when a fixture marker proves
# the run that made it has ended (or is the caller). These cases assert about
# their own fixture processes and scan only their own scratch directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-test-reap-orphans)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REAPER="$ROOT/bin/fm-test-reap-orphans.sh"
SCAN="$TMP_ROOT/scan"
mkdir -p "$SCAN"

TRACKED_PIDS=()
TRACKED_IDENTITIES=()
reap_cleanup() {
  local i current
  for i in "${!TRACKED_PIDS[@]}"; do
    current=$(fm_test_pid_identity "${TRACKED_PIDS[$i]}" 2>/dev/null) || continue
    [ "$current" = "${TRACKED_IDENTITIES[$i]}" ] || continue
    kill -KILL "${TRACKED_PIDS[$i]}" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap reap_cleanup EXIT

track() {
  local identity
  identity=$(fm_test_pid_identity "$1" 2>/dev/null) || return 0
  TRACKED_PIDS+=("$1")
  TRACKED_IDENTITIES+=("$identity")
}

alive() { kill -0 "$1" 2>/dev/null; }

wait_gone() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    alive "$pid" || return 0
    sleep 0.1
  done
  return 1
}

wait_file() { # <file> <seconds>
  local file=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -s "$file" ] && return 0
    sleep 0.05
  done
  return 1
}

# A stub that waits for a release file, bounded as every polling stub must be.
write_stub() { # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
n=0
while [ ! -e "$1" ] && [ "$n" -lt $(( ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120} * 20 )) ]; do
  sleep 0.05
  n=$((n + 1))
done
SH
  chmod +x "$1"
}

# make_root <name> <owner-pid>: a fixture root stamped for that owner.
make_root() {
  local root identity
  root=$(mktemp -d "$SCAN/fm-$1.XXXXXX") || fail "could not make a fixture root"
  root=$(cd "$root" && pwd -P)
  identity=$(fm_test_pid_identity "$2") || fail "could not identify the owner of $1"
  printf '%s\n%s\n' "$2" "$identity" > "$root/.fm-test-fixture"
  printf '%s\n' "$root"
}

# orphan <pidfile> <command...>: start a command whose parent exits at once, so it
# is a child of init the way a stub left by a dead test is.
orphan() {
  local pidfile=$1
  shift
  ( "$@" >/dev/null 2>&1 & echo $! > "$pidfile" )
  wait_file "$pidfile" 5 || fail "the orphan fixture did not start"
  track "$(cat "$pidfile")"
}

# A long-lived stand-in for the dead test: its pid and identity go in the marker.
start_owner() {
  sleep 120 &
  OWNER=$!
  track "$OWNER"
}

start_owner
ROOT_DEAD=$(make_root dead "$OWNER")
write_stub "$ROOT_DEAD/stub.sh"
orphan "$TMP_ROOT/dead.pid" bash "$ROOT_DEAD/stub.sh" "$ROOT_DEAD/release"
DEAD_STUB=$(cat "$TMP_ROOT/dead.pid")
# The same stub kept by a live parent is a running test's own job, not an orphan.
write_stub "$ROOT_DEAD/live-parent.sh"
bash "$ROOT_DEAD/live-parent.sh" "$ROOT_DEAD/release" &
LIVE_PARENT_STUB=$!
track "$LIVE_PARENT_STUB"
# An orphan that never names the fixture root is not this run's.
write_stub "$TMP_ROOT/unrelated.sh"
orphan "$TMP_ROOT/unrelated.pid" bash "$TMP_ROOT/unrelated.sh" "$TMP_ROOT/never"
UNRELATED=$(cat "$TMP_ROOT/unrelated.pid")
# A root whose name merely begins with the dead root's name is a different root.
SIBLING="${ROOT_DEAD}2"
mkdir -p "$SIBLING"
write_stub "$SIBLING/stub.sh"
orphan "$TMP_ROOT/sibling.pid" bash "$SIBLING/stub.sh" "$SIBLING/release"
SIBLING_STUB=$(cat "$TMP_ROOT/sibling.pid")

out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the reaper failed with a live owner: $out"
alive "$DEAD_STUB" || fail "the reaper stopped a stub whose owner is still running"
pass "a stub is left alone while the run that made it is alive"

kill -KILL "$OWNER" 2>/dev/null || true
wait "$OWNER" 2>/dev/null || true
wait_gone "$OWNER" 5 || fail "the stand-in owner did not exit"

out=$("$REAPER" --dry-run --tmpdir "$SCAN" 2>&1) || fail "the reaper dry run failed: $out"
assert_contains "$out" "would reap pid=$DEAD_STUB " "the dry run did not name the orphaned stub"
alive "$DEAD_STUB" || fail "the dry run stopped the stub it only reported"
pass "a dry run names the orphaned stub and signals nothing"

out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the reaper failed: $out"
assert_contains "$out" "reaped pid=$DEAD_STUB " "the reaper did not report the orphaned stub"
wait_gone "$DEAD_STUB" 10 || fail "the orphaned stub of an ended run survived the reaper"
pass "the reaper stops a stub whose owning run has ended"

alive "$LIVE_PARENT_STUB" || fail "the reaper stopped a process that still has a live parent"
alive "$UNRELATED" || fail "the reaper stopped an orphan that never named a fixture root"
alive "$SIBLING_STUB" || fail "the reaper stopped a process under a root that only shares a name prefix"
pass "the reaper leaves live-parent, unrelated and prefix-sharing processes alone"

out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "a repeat reaper run failed: $out"
assert_not_contains "$out" "reaped" "the reaper reported work on a repeat run"
pass "the reaper is idempotent"

# The owner-exit sweep: the caller owns the root and reaps what it left, including
# a stub a subshell started (invisible to the shell's own job table) and the
# child that stub forked.
OWNED=$(fm_test_tmproot fm-test-reap-owned)
OWNED=$(cd "$OWNED" && pwd -P)
cat > "$OWNED/forking.sh" <<'SH'
#!/usr/bin/env bash
sleep 120 &
echo $! > "$2"
n=0
while [ ! -e "$1" ] && [ "$n" -lt $(( ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120} * 20 )) ]; do
  sleep 0.05
  n=$((n + 1))
done
SH
chmod +x "$OWNED/forking.sh"
( bash "$OWNED/forking.sh" "$OWNED/release" "$OWNED/child.pid" >/dev/null 2>&1 & echo $! > "$OWNED/stub.pid" )
wait_file "$OWNED/stub.pid" 5 || fail "the owned stub did not start"
wait_file "$OWNED/child.pid" 5 || fail "the owned stub's child did not start"
OWNED_STUB=$(cat "$OWNED/stub.pid")
OWNED_CHILD=$(cat "$OWNED/child.pid")
track "$OWNED_STUB"
track "$OWNED_CHILD"
# A job the caller still holds, below the owner rather than under init, goes too.
write_stub "$OWNED/job.sh"
bash "$OWNED/job.sh" "$OWNED/release" &
OWNED_JOB=$!
track "$OWNED_JOB"

rc=0
out=$("$REAPER" --owner-pid "$$" --root "$OWNED" --dry-run 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "the owner-exit dry run failed: $out"
assert_contains "$out" "would reap pid=$OWNED_STUB " "the owner-exit dry run did not name the owned stub"
alive "$OWNED_STUB" || fail "the owner-exit dry run stopped the stub"

rc=0
out=$("$REAPER" --owner-pid 1 --root "$OWNED" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "the reaper accepted an owner that is not the caller (rc=$rc)"
alive "$OWNED_STUB" || fail "a refused owner claim still stopped the stub"
pass "an owner claim must name the caller or an ancestor"

out=$("$REAPER" --owner-pid "$$" --root "$ROOT_DEAD" 2>&1) || fail "the owner-exit sweep failed: $out"
alive "$LIVE_PARENT_STUB" || fail "the owner-exit sweep stopped a root the caller does not own"
pass "the owner-exit sweep only reaps roots whose marker names the caller"

out=$("$REAPER" --owner-pid "$$" --root "$OWNED" 2>&1) || fail "the owner-exit sweep failed: $out"
wait_gone "$OWNED_STUB" 10 || fail "the owner-exit sweep left the stub running"
wait_gone "$OWNED_CHILD" 10 || fail "the owner-exit sweep left the stub's child running"
wait_gone "$OWNED_JOB" 10 || fail "the owner-exit sweep left the owner's own job running"
wait "$OWNED_JOB" 2>/dev/null || true
pass "the owner-exit sweep stops a hidden stub and everything below it"

# tests/lib.sh wires both sweeps in. A test that exits normally takes its
# subshell-started stub down with it; a test killed outright leaves the stub for
# the next test that sources the library, once the marker proves the owner dead.
write_child() { # <script> <mode>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
. "$FM_TEST_LIB"
root=$(fm_test_tmproot fm-test-reap-child)
cat > "$root/stub.sh" <<'STUB'
#!/usr/bin/env bash
n=0
while [ ! -e "$1" ] && [ "$n" -lt $(( ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120} * 20 )) ]; do
  sleep 0.05
  n=$((n + 1))
done
STUB
chmod +x "$root/stub.sh"
( bash "$root/stub.sh" "$root/release" >/dev/null 2>&1 & echo $! > "$FM_TEST_PIDFILE" )
case "$FM_TEST_MODE" in
  normal) exit 0 ;;
  killed) kill -KILL "$$" ;;
esac
SH
}

CHILD_TMP="$TMP_ROOT/child-tmp"
mkdir -p "$CHILD_TMP"
write_child "$TMP_ROOT/child.sh"
child_env() { # <mode> <pidfile>
  env TMPDIR="$CHILD_TMP" FM_TEST_LIB="$ROOT/tests/lib.sh" FM_TEST_MODE="$1" FM_TEST_PIDFILE="$2" \
    FM_TEST_SKIP_ORPHAN_REAP=1 bash "$TMP_ROOT/child.sh"
}

child_env normal "$TMP_ROOT/normal.pid" >/dev/null 2>&1
wait_file "$TMP_ROOT/normal.pid" 5 || fail "the normal-exit test did not start its stub"
NORMAL_STUB=$(cat "$TMP_ROOT/normal.pid")
track "$NORMAL_STUB"
wait_gone "$NORMAL_STUB" 10 || fail "a test that exited normally left its subshell-started stub running"
pass "a test that exits normally leaves no stub of its own behind"

child_env killed "$TMP_ROOT/killed.pid" >/dev/null 2>&1
wait_file "$TMP_ROOT/killed.pid" 5 || fail "the killed test did not start its stub"
KILLED_STUB=$(cat "$TMP_ROOT/killed.pid")
track "$KILLED_STUB"
alive "$KILLED_STUB" || fail "the killed test's stub did not outlive its owner, so this case proves nothing"
# shellcheck disable=SC2016 # The child shell, not this one, expands $FM_TEST_LIB.
env TMPDIR="$CHILD_TMP" FM_TEST_LIB="$ROOT/tests/lib.sh" bash -c '. "$FM_TEST_LIB"' >/dev/null 2>&1
wait_gone "$KILLED_STUB" 10 || fail "sourcing the test library did not reap the stub of a killed test"
pass "sourcing the test library reaps the stub a killed test left behind"
