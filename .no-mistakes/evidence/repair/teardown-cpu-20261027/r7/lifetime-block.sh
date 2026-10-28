# Every group started below a registered refresh is recorded by its launcher
# before it starts, so cleanup cannot outrun a writer whose own launcher is
# gone. Each case interrupts an exact owned process, shows the bounded wait
# still failing while the orphaned writer runs, then lets that writer touch
# the home and drains only after it exits.
LIFE_REAL_ENV=$(command -v env)
LIFE_REGISTRIES=
LIFE_HOLDS=
NESTBIN="$TMP_ROOT/nestbin"
mkdir -p "$NESTBIN"
# Every refresh child is started through env. This one can fail the worker at
# once, publish the worker's pid, or hold one launched mode before it runs
# (ignoring TERM, as a busy child may, so only its bound's KILL stops it).
cat > "$NESTBIN/env" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --_worker "*)
    [ -z "${FM_TEST_WORKER_PIDFILE:-}" ] || printf '%s\n' "$$" > "$FM_TEST_WORKER_PIDFILE"
    [ "${FM_TEST_WORKER_FAIL:-0}" != 1 ] || exit 143
    ;;
esac
case " $* " in
  *" ${FM_TEST_HOLD_MODE:-unset} "*)
    trap '' TERM
    printf '%s\n' "$$" > "$FM_TEST_HOLD.entered"
    while [ -e "$FM_TEST_HOLD" ]; do sleep 0.1; done
    ;;
esac
exec "$FM_TEST_REAL_ENV" "$@"
SH
chmod +x "$NESTBIN/env"

# <label> <registry> <home> <hold>: the bounded wait fails and keeps the registry
# while the orphaned writer is held; released, it recreates the removed state
# directory, and only then does the registry drain.
assert_orphan_writer_waited() {
  local label=$1 reg=$2 home=$3 hold=$4
  rm -rf "$home/state"
  if FM_TEST_PROCESS_WAIT_SECONDS=1 fm_test_wait_processes "$reg" 2> "$TMP_ROOT/$label.wait.err"; then
    fail "$label: cleanup found no running writer while an orphaned child of the refresh was held"
  fi
  assert_grep "owned writers still running after 1s" "$TMP_ROOT/$label.wait.err" \
    "$label: the bounded wait did not name the running writer"
  [ -f "$reg" ] || fail "$label: the bounded wait discarded the writer registry"
  rm -f "$hold"
  fm_test_wait_processes "$reg" || fail "$label: the released writer never drained"
  [ -d "$home/state" ] || fail "$label: the released child never wrote its home, so nothing was proven"
}

# A failure-accounting child sources fm-wake-lib.sh, whose first act creates
# state/. The refresh parent is killed while that child is held.
nested_mode_case() {  # bash|default
  local label="nested-$1" home reg hold pid
  home=$(new_bare_home "$label-home")
  reg=$(mktemp "$TMP_ROOT/.$label-registry.XXXXXX")
  hold="$TMP_ROOT/$label-hold"
  : > "$hold"
  LIFE_REGISTRIES="$LIFE_REGISTRIES $reg"
  LIFE_HOLDS="$LIFE_HOLDS $hold"
  if [ "$1" = bash ]; then set -- FM_TIMEOUT_MECHANISM_OVERRIDE=bash; else set --; fi
  env "$@" PATH="$NESTBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$LIFE_REAL_ENV" FM_TEST_WORKER_FAIL=1 \
    FM_TEST_HOLD_MODE=--_note-failure FM_TEST_HOLD="$hold" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_TEST_PROCESS_REGISTRY="$reg" "$WRITER" --best-effort &
  pid=$!
  fm_test_wait_until 60 test -s "$hold.entered" || fail "$label: the accounting child was never launched"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_orphan_writer_waited "$label" "$reg" "$home" "$hold"
}

# The worker is held after its launch and before it runs any of its own code;
# the refresh parent is killed in that window.
held_worker_case() {
  local label=held-worker home reg hold pid pending_reg
  home=$(new_bare_home "$label-home")
  reg=$(mktemp "$TMP_ROOT/.$label-registry.XXXXXX")
  hold="$TMP_ROOT/$label-hold"
  : > "$hold"
  LIFE_REGISTRIES="$LIFE_REGISTRIES $reg"
  LIFE_HOLDS="$LIFE_HOLDS $hold"
  PATH="$NESTBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$LIFE_REAL_ENV" FM_TEST_HOLD_MODE=--_worker \
    FM_TEST_HOLD="$hold" FM_HOME_SUMMARY_TIMEOUT=60 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_TEST_PROCESS_REGISTRY="$reg" "$WRITER" --best-effort &
  pid=$!
  fm_test_wait_until 60 test -s "$hold.entered" || fail "$label: the worker was never launched"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_orphan_writer_waited "$label" "$reg" "$home" "$hold"
  # A reserved launch whose group was never recorded is a pending handoff,
  # never a finished writer.
  pending_reg=$(mktemp "$TMP_ROOT/.pending-registry.XXXXXX")
  FM_TEST_PROCESS_REGISTRY="$pending_reg" bash -c '
    . "$1/bin/fm-timeout-lib.sh" && fm_process_reserve record pending-launch' _ "$ROOT" \
    || fail "could not reserve a launch record"
  if FM_TEST_PROCESS_WAIT_SECONDS=1 fm_test_wait_processes "$pending_reg" 2> "$TMP_ROOT/pending.wait.err"; then
    fail "a reserved launch with no recorded group was read as a finished writer"
  fi
  assert_grep "pending:$pending_reg." "$TMP_ROOT/pending.wait.err" \
    "the bounded wait did not name the pending launch"
  [ -f "$pending_reg" ] || fail "a pending launch did not keep its registry"
  rm -f "$pending_reg" "$pending_reg".*
}

# Groups started below the worker (the current-state reader and its no-mistakes
# read) outlive the worker's own group. The held read writes the home once
# released.
escape_case() {
  local label=escaped-group root reg hold wpid pid
  root="$TMP_ROOT/$label"
  # The stopped worker's own scratch lands in the fixture root, not the shared TMPDIR.
  mkdir -p "$root/tmp"
  cp -R "$COALESCE_HOME" "$root/home" && rm -f "$root/home/state/home-summary.json" \
    || fail "$label: could not copy the fixture home"
  reg=$(mktemp "$TMP_ROOT/.$label-registry.XXXXXX")
  hold="$TMP_ROOT/$label-hold"
  : > "$hold"
  LIFE_REGISTRIES="$LIFE_REGISTRIES $reg"
  LIFE_HOLDS="$LIFE_HOLDS $hold"
  PATH="$NESTBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$LIFE_REAL_ENV" \
    FM_TEST_WORKER_PIDFILE="$root/worker.pid" FM_TEST_NM_HOLD="$hold" \
    FM_TEST_NM_MARKER="$root/home/state/.late-read" FM_TEST_NM_SLEEP=0 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$root/home" FM_TEST_PROCESS_REGISTRY="$reg" \
    TMPDIR="$root/tmp" "$WRITER" --best-effort &
  pid=$!
  fm_test_wait_until 60 test -s "$hold.entered" || fail "$label: the held read was never reached"
  wpid=$(cat "$root/worker.pid")
  case "$wpid" in ''|*[!0-9]*) fail "$label: the worker published no pid" ;; esac
  kill -KILL -- "-$wpid" 2>/dev/null || fail "$label: could not stop the worker's own group $wpid"
  fm_test_wait_until 60 bash -c '! kill -0 "$1" 2>/dev/null' _ "$pid" \
    || fail "$label: the refresh parent did not finish after its worker was stopped"
  wait "$pid" 2>/dev/null || true
  ! kill -0 -- "-$wpid" 2>/dev/null || fail "$label: the worker's group still has members"
  rm -f "$root/home/state/.late-read"
  if FM_TEST_PROCESS_WAIT_SECONDS=1 fm_test_wait_processes "$reg" 2> "$TMP_ROOT/$label.wait.err"; then
    fail "$label: cleanup found no running writer while a group below the stopped worker was held"
  fi
  assert_grep "owned writers still running after 1s" "$TMP_ROOT/$label.wait.err" \
    "$label: the bounded wait did not name the running writer"
  rm -f "$hold"
  fm_test_wait_processes "$reg" || fail "$label: the released read never drained"
  [ -e "$root/home/state/.late-read" ] || fail "$label: the released read never wrote its home"
}

nested_mode_case bash
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  nested_mode_case default
fi
pass "cleanup waits for a launched failure-accounting child after its refresh parent is killed"
held_worker_case
pass "cleanup waits for a worker launched but not yet running when its refresh parent is killed"
escape_case
pass "cleanup waits for groups started below a worker that outlive the worker's own group"
