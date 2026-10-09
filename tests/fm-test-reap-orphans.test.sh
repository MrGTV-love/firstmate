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

initialized_identity() {
  local pid=$1 command deadline=$((SECONDS + 5))
  shift
  while [ "$SECONDS" -lt "$deadline" ]; do
    command=$(COLUMNS=10000 LC_ALL=C ps -p "$pid" -o command= 2>/dev/null) || return 1
    if [ "$command" = "$*" ]; then
      fm_test_pid_identity "$pid"
      return
    fi
    sleep 0.05
  done
  return 1
}

track() {
  local identity=$2
  [ -n "$identity" ] || fail "fixture $1 did not initialize"
  TRACKED_PIDS+=("$1")
  TRACKED_IDENTITIES+=("$identity")
}

alive() {
  local pid=$1 identity=${2:-} current i
  if [ -z "$identity" ]; then
    for i in "${!TRACKED_PIDS[@]}"; do
      [ "${TRACKED_PIDS[$i]}" != "$pid" ] || identity=${TRACKED_IDENTITIES[$i]}
    done
  fi
  [ -n "$identity" ] || return 1
  current=$(fm_test_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current" = "$identity" ]
}

wait_gone() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 )) identity=${3:-}
  while [ "$(date +%s)" -lt "$deadline" ]; do
    alive "$pid" "$identity" || return 0
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
  ( [ -z "${ORPHAN_CWD:-}" ] || cd "$ORPHAN_CWD" || exit 1
    "$@" >/dev/null 2>&1 &
    pid=$!
    initialized_identity "$pid" "$@" > "$pidfile.identity" || exit 1
    printf '%s\n' "$pid" > "$pidfile"
  ) || fail "could not record the orphan fixture's original identity"
  wait_file "$pidfile" 5 || fail "the orphan fixture did not start"
  track "$(cat "$pidfile")" "$(cat "$pidfile.identity")"
}

# A long-lived stand-in for the dead test: its pid and identity go in the marker.
start_owner() {
  sleep 120 &
  OWNER=$!
  track "$OWNER" "$(initialized_identity "$OWNER" sleep 120)"
}

mkfifo "$TMP_ROOT/identity-exec"
(
  read -r line < "$TMP_ROOT/identity-exec"
  exec sleep 120
) &
IDENTITY_FIXTURE=$!
track "$IDENTITY_FIXTURE" "previous ownership identity"
(initialized_identity "$IDENTITY_FIXTURE" sleep 120 > "$TMP_ROOT/identity-captured") &
IDENTITY_CAPTURE=$!
sleep 0.1
[ ! -s "$TMP_ROOT/identity-captured" ] || fail "identity capture accepted a fixture before exec"
printf 'exec\n' > "$TMP_ROOT/identity-exec"
wait "$IDENTITY_CAPTURE" || fail "could not identify the initialized identity fixture"
IDENTITY_FIXTURE_ORIGINAL=$(cat "$TMP_ROOT/identity-captured")
track "$IDENTITY_FIXTURE" "$IDENTITY_FIXTURE_ORIGINAL"
wait_gone "$IDENTITY_FIXTURE" 1 "different original identity" || fail "a replaced original identity must count as gone"
alive "$IDENTITY_FIXTURE" || fail "the newest registered identity must identify the live replacement"
if wait_gone "$IDENTITY_FIXTURE" 1; then
  fail "a still-live original identity must not count as gone"
fi
kill -KILL "$IDENTITY_FIXTURE" 2>/dev/null || true
wait "$IDENTITY_FIXTURE" 2>/dev/null || true
pass "disappearance checks distinguish a replaced identity from the still-live original"

start_owner
ROOT_DEAD=$(make_root dead "$OWNER")
write_stub "$ROOT_DEAD/stub.sh"
orphan "$TMP_ROOT/dead.pid" bash "$ROOT_DEAD/stub.sh" "$ROOT_DEAD/release"
DEAD_STUB=$(cat "$TMP_ROOT/dead.pid")
# The same stub kept by a live parent is a running test's own job, not an orphan.
write_stub "$ROOT_DEAD/live-parent.sh"
bash "$ROOT_DEAD/live-parent.sh" "$ROOT_DEAD/release" &
LIVE_PARENT_STUB=$!
track "$LIVE_PARENT_STUB" "$(initialized_identity "$LIVE_PARENT_STUB" bash "$ROOT_DEAD/live-parent.sh" "$ROOT_DEAD/release")"
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

LAB_ROOT="$SCAN/fm-lab-copy"
mkdir -p "$TMP_ROOT/lab-git-bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/lab-git-bin/git"
chmod +x "$TMP_ROOT/lab-git-bin/git"
cat > "$TMP_ROOT/lab-owner.sh" <<'SH'
#!/usr/bin/env bash
env PATH="$3:$PATH" "$1" create "$2" >/dev/null || exit 1
mkfifo "$2/owner-wait" || exit 1
printf 'ready\n' > "$2/ready"
read -r line < "$2/owner-wait"
SH
bash "$TMP_ROOT/lab-owner.sh" "$ROOT/bin/fm-lab-home.sh" "$LAB_ROOT" "$TMP_ROOT/lab-git-bin" &
LAB_OWNER=$!
track "$LAB_OWNER" "$(initialized_identity "$LAB_OWNER" bash "$TMP_ROOT/lab-owner.sh" "$ROOT/bin/fm-lab-home.sh" "$LAB_ROOT" "$TMP_ROOT/lab-git-bin")"
wait_file "$LAB_ROOT/ready" 5 || fail "the lab creator did not finish"
mkdir -p "$LAB_ROOT/bin"
write_stub "$LAB_ROOT/bin/fm-watch.sh"
orphan "$TMP_ROOT/lab-watch.pid" bash "$LAB_ROOT/bin/fm-watch.sh" "$LAB_ROOT/release"
LAB_WATCH=$(cat "$TMP_ROOT/lab-watch.pid")
assert_contains "$(cat "$LAB_ROOT/.fm-lab-home")" "owner_pid=$LAB_OWNER" "the lab marker must retain its creating caller"
out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the lab scan failed: $out"
alive "$LAB_WATCH" || fail "the reaper stopped a live creator's scratch-copy watcher"
env FM_TEST_GATE_LIB="$ROOT/bin/fm-gate-refuse-lib.sh" FM_TEST_LAB_ROOT="$LAB_ROOT" \
  bash -c '. "$FM_TEST_GATE_LIB"; fm_gate_lab_home "$FM_TEST_LAB_ROOT"' \
  || fail "provenance changed the lab gate marker contract"
kill -KILL "$LAB_OWNER" 2>/dev/null || true
wait "$LAB_OWNER" 2>/dev/null || true
out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the ended lab scan failed: $out"
wait_gone "$LAB_WATCH" 10 || fail "the ended lab's scratch-copy watcher survived"
pass "lab creation records its caller and ended scratch-copy watchers are reaped"

mkdir -p "$TMP_ROOT/go-build-cwd"
cat > "$TMP_ROOT/go-cwd_test.go" <<'GO'
package fixture

import (
	"testing"
	"time"
)

func TestWait(t *testing.T) {
	time.Sleep(120 * time.Second)
}
GO
env GOENV=off GOTOOLCHAIN=local GOWORK=off go test -c \
  -o "$TMP_ROOT/go-build-cwd/package.test" "$TMP_ROOT/go-cwd_test.go" \
  || fail "could not build the Go cwd fixture"
start_owner
GO_ROOT=$(make_root go-cwd "$OWNER")
mkdir -p "$GO_ROOT/package" "${GO_ROOT}2/package"
ORPHAN_CWD="$GO_ROOT/package" orphan "$TMP_ROOT/go.pid" "$TMP_ROOT/go-build-cwd/package.test"
GO_STUB=$(cat "$TMP_ROOT/go.pid")
ORPHAN_CWD="${GO_ROOT}2/package" orphan "$TMP_ROOT/go-sibling.pid" "$TMP_ROOT/go-build-cwd/package.test"
GO_SIBLING=$(cat "$TMP_ROOT/go-sibling.pid")
(cd "$GO_ROOT/package" && exec "$TMP_ROOT/go-build-cwd/package.test") &
GO_LIVE_PARENT=$!
track "$GO_LIVE_PARENT" "$(initialized_identity "$GO_LIVE_PARENT" "$TMP_ROOT/go-build-cwd/package.test")"
kill -KILL "$OWNER" 2>/dev/null || true
wait "$OWNER" 2>/dev/null || true
out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the cwd scan failed: $out"
wait_gone "$GO_STUB" 10 || fail "the detached go-build test executable survived with cwd under the ended run"
alive "$GO_SIBLING" || fail "cwd attribution crossed a root prefix boundary"
alive "$GO_LIVE_PARENT" || fail "cwd attribution reaped a test executable with a live parent"
pass "go-build-only argv is attributed by cwd without crossing ownership boundaries"

start_owner
LIVE_ROOT=$(mktemp -d "$SCAN/fmlab.XXXXXX") || fail "could not make a live lab root"
LIVE_OWNER=$OWNER
LIVE_OWNER_IDENTITY=$(fm_test_pid_identity "$LIVE_OWNER") || fail "could not identify the live lab creator"
cat > "$LIVE_ROOT/.fm-live-lab" <<RECORD
fm-live-lab v1
owner_pid=$LIVE_OWNER
owner_identity=$LIVE_OWNER_IDENTITY
home=$LIVE_ROOT/home
RECORD
mkdir -p "$LIVE_ROOT/home/bin"
write_stub "$LIVE_ROOT/home/bin/fm-watch.sh"
orphan "$TMP_ROOT/live-lab-watch.pid" bash "$LIVE_ROOT/home/bin/fm-watch.sh" "$LIVE_ROOT/release"
LIVE_LAB_WATCH=$(cat "$TMP_ROOT/live-lab-watch.pid")
sleep 120 &
LIVE_LAB_PANE=$!
track "$LIVE_LAB_PANE" "$(initialized_identity "$LIVE_LAB_PANE" sleep 120)"
printf 'launch_pid=%s\nlaunch_start=%s\n' "$LIVE_LAB_PANE" "$(LC_ALL=C ps -o lstart= -p "$LIVE_LAB_PANE" | awk '{$1=$1; print}')" >> "$LIVE_ROOT/.fm-live-lab"
kill -KILL "$LIVE_OWNER" 2>/dev/null || true
wait "$LIVE_OWNER" 2>/dev/null || true
out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the persistent live lab scan failed: $out"
alive "$LIVE_LAB_WATCH" || fail "a live lab ended merely because up's creator exited"
kill -KILL "$LIVE_LAB_PANE" 2>/dev/null || true
wait "$LIVE_LAB_PANE" 2>/dev/null || true
out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the stopped live lab scan failed: $out"
wait_gone "$LIVE_LAB_WATCH" 10 || fail "the stopped live lab watcher survived"
pass "live labs persist after up exits until their recorded runtime ends"

start_owner
FAILED_ROOT=$(mktemp -d "$SCAN/fmlab.XXXXXX") || fail "could not make a failed lab root"
printf 'fm-live-lab v1\nowner_pid=%s\nowner_identity=%s\n' "$OWNER" "$(fm_test_pid_identity "$OWNER")" > "$FAILED_ROOT/.fm-live-lab"
write_stub "$FAILED_ROOT/fm-watch.sh"
orphan "$TMP_ROOT/failed-lab.pid" bash "$FAILED_ROOT/fm-watch.sh" "$FAILED_ROOT/release"
FAILED_LAB_WATCH=$(cat "$TMP_ROOT/failed-lab.pid")
kill -KILL "$OWNER" 2>/dev/null || true
wait "$OWNER" 2>/dev/null || true
out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the failed creation scan failed: $out"
wait_gone "$FAILED_LAB_WATCH" 10 || fail "a failed pre-launch lab creation retained its watcher"
pass "failed lab creation without a runtime is ended when its creator exits"

start_owner
SERVER_ROOT=$(mktemp -d "$SCAN/fmlab.XXXXXX") || fail "could not make the server lab root"
SERVER_DIR="$SERVER_ROOT/socket-dir"
mkdir -p "$SERVER_DIR/tmux-$(id -u)" "$TMP_ROOT/lab-tmux-bin"
: > "$SERVER_DIR/tmux-$(id -u)/default"
printf 'fm-live-lab v1\nowner_pid=%s\nowner_identity=%s\ntmux_dir=%s\n' "$OWNER" "$(fm_test_pid_identity "$OWNER")" "$SERVER_DIR" > "$SERVER_ROOT/.fm-live-lab"
cat > "$TMP_ROOT/lab-tmux-bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$(cat "$FM_TEST_TMUX_STATUS")" in
  active) exit 0 ;;
  unknown) echo 'permission denied' >&2; exit 1 ;;
  stopped) echo 'no server running' >&2; exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/lab-tmux-bin/tmux"
write_stub "$SERVER_ROOT/fm-watch.sh"
orphan "$TMP_ROOT/server-watch.pid" bash "$SERVER_ROOT/fm-watch.sh" "$SERVER_ROOT/release"
SERVER_WATCH=$(cat "$TMP_ROOT/server-watch.pid")
kill -KILL "$OWNER" 2>/dev/null || true
wait "$OWNER" 2>/dev/null || true
printf 'active\n' > "$TMP_ROOT/tmux-status"
out=$(FM_TEST_TMUX_STATUS="$TMP_ROOT/tmux-status" PATH="$TMP_ROOT/lab-tmux-bin:$PATH" "$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the active server scan failed: $out"
alive "$SERVER_WATCH" || fail "the active private lab server did not retain ownership"
printf 'unknown\n' > "$TMP_ROOT/tmux-status"
out=$(FM_TEST_TMUX_STATUS="$TMP_ROOT/tmux-status" PATH="$TMP_ROOT/lab-tmux-bin:$PATH" "$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the uncertain server scan failed: $out"
alive "$SERVER_WATCH" || fail "an uncertain private server probe authorized reaping"
rm -rf "$SERVER_DIR"
out=$(FM_TEST_TMUX_STATUS="$TMP_ROOT/tmux-status" PATH="$TMP_ROOT/lab-tmux-bin:$PATH" "$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the missing server directory scan failed: $out"
alive "$SERVER_WATCH" || fail "a missing private server directory proved that its server stopped"
mkdir -p "$SERVER_DIR/tmux-$(id -u)"
: > "$SERVER_DIR/tmux-$(id -u)/default"
printf 'stopped\n' > "$TMP_ROOT/tmux-status"
out=$(FM_TEST_TMUX_STATUS="$TMP_ROOT/tmux-status" PATH="$TMP_ROOT/lab-tmux-bin:$PATH" "$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the stopped server scan failed: $out"
wait_gone "$SERVER_WATCH" 10 || fail "a confirmed stopped private server retained its orphan watcher"
pass "active and indeterminate private lab servers prevent reaping until stopped"

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
track "$OWNED_STUB" "$(initialized_identity "$OWNED_STUB" bash "$OWNED/forking.sh" "$OWNED/release" "$OWNED/child.pid")"
track "$OWNED_CHILD" "$(initialized_identity "$OWNED_CHILD" sleep 120)"
# A job the caller still holds, below the owner rather than under init, goes too.
write_stub "$OWNED/job.sh"
bash "$OWNED/job.sh" "$OWNED/release" &
OWNED_JOB=$!
track "$OWNED_JOB" "$(initialized_identity "$OWNED_JOB" bash "$OWNED/job.sh" "$OWNED/release")"

rc=0
out=$("$REAPER" --owner-pid 1 --root "$OWNED" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "the reaper accepted an owner that is not the caller (rc=$rc)"
alive "$OWNED_STUB" || fail "a refused owner claim still stopped the stub"
pass "an owner claim must name the caller or an ancestor"

out=$("$REAPER" --owner-pid "$$" --root "$ROOT_DEAD" 2>&1) || fail "the owner-exit sweep failed: $out"
alive "$LIVE_PARENT_STUB" || fail "the owner-exit sweep stopped a root the caller does not own"
pass "the owner-exit sweep only reaps roots whose marker names the caller"

OWNED_MARKER=$(cat "$OWNED/.fm-test-fixture")
printf '%s\ndifferent original owner identity\n' "$$" > "$OWNED/.fm-test-fixture"
out=$("$REAPER" --owner-pid "$$" --root "$OWNED" 2>&1) || fail "the mismatched owner sweep failed: $out"
alive "$OWNED_STUB" || fail "an owner PID without its original identity authorized reaping"
printf '%s\n' "$OWNED_MARKER" > "$OWNED/.fm-test-fixture"
pass "owner-exit authority requires the original owner identity as well as its PID"

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
  printf '#!/usr/bin/env bash\n' > "$1"
  declare -f initialized_identity >> "$1"
  cat >> "$1" <<'SH'
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
( bash "$root/stub.sh" "$root/release" >/dev/null 2>&1 &
  pid=$!
  initialized_identity "$pid" bash "$root/stub.sh" "$root/release" > "$FM_TEST_PIDFILE.identity" || exit 1
  printf '%s\n' "$pid" > "$FM_TEST_PIDFILE"
) || exit 1
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
wait_gone "$NORMAL_STUB" 10 "$(cat "$TMP_ROOT/normal.pid.identity")" || fail "a test that exited normally left its subshell-started stub running"
pass "a test that exits normally leaves no stub of its own behind"

child_env killed "$TMP_ROOT/killed.pid" >/dev/null 2>&1
wait_file "$TMP_ROOT/killed.pid" 5 || fail "the killed test did not start its stub"
KILLED_STUB=$(cat "$TMP_ROOT/killed.pid")
track "$KILLED_STUB" "$(cat "$TMP_ROOT/killed.pid.identity")"
alive "$KILLED_STUB" || fail "the killed test's stub did not outlive its owner, so this case proves nothing"
# shellcheck disable=SC2016 # The child shell, not this one, expands $FM_TEST_LIB.
env TMPDIR="$CHILD_TMP" FM_TEST_LIB="$ROOT/tests/lib.sh" FM_TEST_SKIP_ORPHAN_REAP=0 bash -c '. "$FM_TEST_LIB"' >/dev/null 2>&1
wait_gone "$KILLED_STUB" 10 || fail "sourcing the test library did not reap the stub of a killed test"
pass "sourcing the test library reaps the stub a killed test left behind"

NESTED_RUN=$(mktemp -d "$CHILD_TMP/fm-test-run.XXXXXX") || fail "could not make a parallel run container"
NESTED_WORKER_TMP="$NESTED_RUN/w1/tmp"
mkdir -p "$NESTED_WORKER_TMP"
NESTED_LIVE_ROOT=$(TMPDIR="$NESTED_WORKER_TMP" fm_test_tmproot fm-test-reap-live)
write_stub "$NESTED_LIVE_ROOT/poll-publish-holder.sh"
orphan "$TMP_ROOT/nested-live.pid" bash "$NESTED_LIVE_ROOT/poll-publish-holder.sh" "$NESTED_LIVE_ROOT/release"
NESTED_LIVE_STUB=$(cat "$TMP_ROOT/nested-live.pid")
NESTED_UNMARKED_ROOT="$NESTED_LIVE_ROOT-unmarked"
mkdir -p "$NESTED_UNMARKED_ROOT"
write_stub "$NESTED_UNMARKED_ROOT/poll-publish-holder.sh"
orphan "$TMP_ROOT/nested-unmarked.pid" bash "$NESTED_UNMARKED_ROOT/poll-publish-holder.sh" "$NESTED_UNMARKED_ROOT/release"
NESTED_UNMARKED_STUB=$(cat "$TMP_ROOT/nested-unmarked.pid")
env TMPDIR="$NESTED_WORKER_TMP" FM_TEST_LIB="$ROOT/tests/lib.sh" FM_TEST_MODE=killed \
  FM_TEST_PIDFILE="$TMP_ROOT/nested-killed.pid" FM_TEST_SKIP_ORPHAN_REAP=1 bash "$TMP_ROOT/child.sh" >/dev/null 2>&1
wait_file "$TMP_ROOT/nested-killed.pid" 5 || fail "the killed parallel test did not start its stub"
NESTED_KILLED_STUB=$(cat "$TMP_ROOT/nested-killed.pid")
track "$NESTED_KILLED_STUB" "$(cat "$TMP_ROOT/nested-killed.pid.identity")"
alive "$NESTED_KILLED_STUB" || fail "the parallel test's stub did not outlive its owner"
env TMPDIR="$CHILD_TMP" FM_TEST_LIB="$ROOT/tests/lib.sh" FM_TEST_SKIP_ORPHAN_REAP=0 bash -c '. "$FM_TEST_LIB"' >/dev/null 2>&1
wait_gone "$NESTED_KILLED_STUB" 10 || fail "startup recovery left the killed parallel test's nested stub running"
alive "$NESTED_LIVE_STUB" || fail "startup recovery stopped a live test's nested stub"
alive "$NESTED_UNMARKED_STUB" || fail "startup recovery stopped an unmarked nested stub"
touch "$NESTED_LIVE_ROOT/release" "$NESTED_UNMARKED_ROOT/release"
wait_gone "$NESTED_LIVE_STUB" 5 || fail "the live test's nested stub did not accept its release"
wait_gone "$NESTED_UNMARKED_STUB" 5 || fail "the unmarked nested stub did not accept its release"
pass "startup recovery reaps killed parallel tests' nested stubs without crossing ownership boundaries"

NESTED_LAB_ROOT="$SCAN/fm-lab-nested/home"
bash "$TMP_ROOT/lab-owner.sh" "$ROOT/bin/fm-lab-home.sh" "$NESTED_LAB_ROOT" "$TMP_ROOT/lab-git-bin" &
NESTED_LAB_OWNER=$!
track "$NESTED_LAB_OWNER" "$(initialized_identity "$NESTED_LAB_OWNER" bash "$TMP_ROOT/lab-owner.sh" "$ROOT/bin/fm-lab-home.sh" "$NESTED_LAB_ROOT" "$TMP_ROOT/lab-git-bin")"
wait_file "$NESTED_LAB_ROOT/ready" 5 || fail "the nested lab creator did not finish"
mkdir -p "$NESTED_LAB_ROOT/bin" "$NESTED_LAB_ROOT-unmarked/bin"
write_stub "$NESTED_LAB_ROOT/bin/fm-watch.sh"
orphan "$TMP_ROOT/nested-lab-watch.pid" bash "$NESTED_LAB_ROOT/bin/fm-watch.sh" "$NESTED_LAB_ROOT/release"
NESTED_LAB_WATCH=$(cat "$TMP_ROOT/nested-lab-watch.pid")
write_stub "$NESTED_LAB_ROOT-unmarked/bin/fm-watch.sh"
orphan "$TMP_ROOT/nested-lab-unmarked.pid" bash "$NESTED_LAB_ROOT-unmarked/bin/fm-watch.sh" "$NESTED_LAB_ROOT-unmarked/release"
NESTED_LAB_UNMARKED_WATCH=$(cat "$TMP_ROOT/nested-lab-unmarked.pid")
out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the nested lab scan failed: $out"
alive "$NESTED_LAB_WATCH" || fail "the reaper stopped a live creator's nested lab watcher"
alive "$NESTED_LAB_UNMARKED_WATCH" || fail "the reaper stopped an unmarked nested lab watcher"
kill -KILL "$NESTED_LAB_OWNER" 2>/dev/null || true
wait "$NESTED_LAB_OWNER" 2>/dev/null || true
out=$("$REAPER" --tmpdir "$SCAN" 2>&1) || fail "the ended nested lab scan failed: $out"
assert_contains "$out" "reaped pid=$NESTED_LAB_WATCH root=$NESTED_LAB_ROOT " "the scan did not attribute the watcher to its marked nested lab home"
wait_gone "$NESTED_LAB_WATCH" 10 || fail "the ended nested lab's watcher survived"
alive "$NESTED_LAB_UNMARKED_WATCH" || fail "the ended lab scan stopped an unmarked nested lab watcher"
touch "$NESTED_LAB_ROOT-unmarked/release"
wait_gone "$NESTED_LAB_UNMARKED_WATCH" 5 || fail "the unmarked nested lab watcher did not accept its release"
pass "nested marked lab watchers are reaped while unmarked nested homes are left alone"
