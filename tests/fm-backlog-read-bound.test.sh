#!/usr/bin/env bash
# tests/fm-backlog-read-bound.test.sh - behavior tests for the per-item bound on
# bin/fm-backlog-transition-lib.sh's backlog row read.
#
# The defect this pins: bin/fm-bootstrap.sh's reconcile and close-replay sweeps
# read the backlog backend once per item, and an unbounded read of a wedged
# backend consumed the whole FM_SESSION_START_TIMEOUT. The digest was then
# truncated before the wake queue, supervision instructions, fleet state, and
# context sections printed, leaving a whole fleet unsupervised.
#
# Both halves are proved here:
#   - a deliberately hanging `tasks-axi show` cannot exceed the per-item bound,
#     and the failure names the item it could not read
#   - a session start against that same wedged backend still completes end to
#     end, with every digest section present and a loud partial reconcile
#
# The bound must hold on its own, independent of any particular tasks-axi
# install, so the fake here simply never returns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-backlog-read-bound-tests)
trap fm_test_cleanup EXIT

BOUND_SECS=2
# Generous enough that a slow CI box never flakes, far below the unbounded hang
# (300s per read) and below the session-start budget the defect consumed.
BOUND_CEILING=30

# A backend whose `show` never returns. Everything the compatibility gate and the
# startup listing need still answers promptly, so the only thing under test is
# the read that hangs.
make_hanging_tasks_axi() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '%s\n' '0.2.6'; exit 0 ;;
  update)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --body-file <path>' '  --archive-body'
    exit 0
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
    exit 0
    ;;
  show)
    # A real backend rejects an unusable id promptly instead of wedging, which
    # is what makes a dropped 124 surface as "absent" rather than as a bound.
    if [ -z "${2:-}" ]; then
      printf 'code: NOT_FOUND\n' >&2
      exit 1
    fi
    [ -z "${FM_TEST_TASKS_AXI_HANG_LOG:-}" ] || printf '%s\n' "$2" >> "$FM_TEST_TASKS_AXI_HANG_LOG"
    # The wedge under test: a read that never returns.
    sleep "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}"
    exit 0
    ;;
  hold)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi hold <id> [flags]' '  --kind captain' '  --until <date>'
    exit 0
    ;;
  add)
    # Recorded, never silent: creating a row that already exists is the damage a
    # timed-out read must never be spent on.
    [ -z "${FM_TEST_TASKS_AXI_ADD_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_TASKS_AXI_ADD_LOG"
    exit 0
    ;;
  list)
    printf 'count: 0\n'
    printf 'tasks[0]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

elapsed_since() {  # <start-epoch>
  local now
  now=$(date +%s)
  printf '%s\n' "$((now - $1))"
}

# --- half one: the per-item bound holds -------------------------------------

UNIT="$TMP_ROOT/unit"
UNIT_FAKEBIN=$(fm_fakebin "$UNIT")
mkdir -p "$UNIT/data"
make_hanging_tasks_axi "$UNIT_FAKEBIN"
printf '# Backlog\n' > "$UNIT/data/backlog.md"

# Three items, so "every skipped item is still named" is actually exercised
# rather than inferred from a single skip.
PROBE_OUT="$UNIT/probe.out"
PROBE_LOG="$UNIT/probe.log"
PATH="$UNIT_FAKEBIN:$BASE_PATH" FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
  FM_TEST_TASKS_AXI_HANG_LOG="$PROBE_LOG" \
  bash -c '
    set -u
    . "$1/bin/fm-tasks-axi-lib.sh"
    . "$1/bin/fm-backlog-transition-lib.sh"
    for id in wedged-one wedged-two wedged-three; do
      start=$(date +%s)
      fm_backlog_row_probe "$2" "$id" && printf "unexpected-success\n"
      printf "elapsed:%s=%s\n" "$id" "$(( $(date +%s) - start ))"
      printf "error:%s=%s\n" "$id" "$FM_BACKLOG_ROW_ERROR"
    done
  ' _ "$ROOT" "$UNIT/data" > "$PROBE_OUT" 2>&1

probe_elapsed() {  # <id>
  sed -n "s/^elapsed:$1=//p" "$PROBE_OUT"
}

probe_error() {  # <id>
  sed -n "s/^error:$1=//p" "$PROBE_OUT"
}

grep -q '^unexpected-success$' "$PROBE_OUT" \
  && fail "a hanging tasks-axi show must not report a successful row read: $(cat "$PROBE_OUT")"

FIRST_ELAPSED=$(probe_elapsed wedged-one)
[ -n "$FIRST_ELAPSED" ] || fail "probe produced no timing: $(cat "$PROBE_OUT")"
[ "$FIRST_ELAPSED" -lt "$BOUND_CEILING" ] \
  || fail "bounded row read took ${FIRST_ELAPSED}s, over the ${BOUND_CEILING}s ceiling: $(cat "$PROBE_OUT")"
pass "a hanging tasks-axi show returns within the per-item bound instead of running unbounded"

FIRST_ERROR=$(probe_error wedged-one)
case "$FIRST_ERROR" in
  *wedged-one*bound*) ;;
  *) fail "the timed-out read must name the item and its bound, got: $FIRST_ERROR" ;;
esac
pass "a timed-out row read reports one error naming the item that timed out"

for SKIPPED in wedged-two wedged-three; do
  SKIPPED_ERROR=$(probe_error "$SKIPPED")
  case "$SKIPPED_ERROR" in
    *"$SKIPPED"*skipped*) ;;
    *) fail "every skipped item must still be named as skipped, $SKIPPED got: $SKIPPED_ERROR" ;;
  esac
done
[ "$(cat "$PROBE_LOG")" = wedged-one ] \
  || fail "the latch repeated a known-wedged backend read: $(cat "$PROBE_LOG")"
pass "after the first bound hit the sweep continues and names every remaining item without paying the bound again"

# A padded zero is still zero, and `timeout 0` / `alarm 0` disable the deadline
# outright, so a bound that only rejects the literal 0 silently restores the
# unbounded read this whole change exists to prevent.
PADDED_OUT="$UNIT/padded.out"
PADDED_START=$(date +%s)
PATH="$UNIT_FAKEBIN:$BASE_PATH" FM_BACKLOG_ROW_TIMEOUT_SECS=00 \
  bash -c '
    set -u
    . "$1/bin/fm-tasks-axi-lib.sh"
    . "$1/bin/fm-backlog-transition-lib.sh"
    fm_backlog_row_probe "$2" padded-zero && printf "unexpected-success\n"
    printf "error=%s\n" "$FM_BACKLOG_ROW_ERROR"
  ' _ "$ROOT" "$UNIT/data" > "$PADDED_OUT" 2>&1
PADDED_ELAPSED=$(elapsed_since "$PADDED_START")

[ "$PADDED_ELAPSED" -lt "$BOUND_CEILING" ] \
  || fail "a padded-zero bound disabled the deadline: the read ran ${PADDED_ELAPSED}s"
case "$(sed -n 's/^error=//p' "$PADDED_OUT")" in
  *padded-zero*bound*) ;;
  *) fail "a padded-zero bound must fall back to the default bound and report it: $(cat "$PADDED_OUT")" ;;
esac
pass "a padded-zero bound falls back to the default instead of disabling the deadline"

# --- a bound hit is not absence ---------------------------------------------
#
# Turning a hang into a fast 124 reaches every caller that reads a non-zero row
# status as "this row does not exist". bin/fm-captain-hold.sh's hold path is the
# one where that misreading corrupts: it would create a task that already
# exists. The bound must stop the command instead.

CAPTAIN="$TMP_ROOT/captain"
CAPTAIN_FAKEBIN=$(fm_fakebin "$CAPTAIN")
mkdir -p "$CAPTAIN/data" "$CAPTAIN/state" "$CAPTAIN/config"
make_hanging_tasks_axi "$CAPTAIN_FAKEBIN"
cp "$ROOT/.tasks.toml" "$CAPTAIN/.tasks.toml"
printf '# Backlog\n' > "$CAPTAIN/data/backlog.md"

ADD_LOG="$CAPTAIN/add.log"
HOLD_OUT="$CAPTAIN/hold.out"
HOLD_STDOUT="$CAPTAIN/hold.stdout"
HOLD_STATUS=0
HOLD_START=$(date +%s)
PATH="$CAPTAIN_FAKEBIN:$BASE_PATH" FM_HOME="$CAPTAIN" \
  FM_STATE_OVERRIDE="$CAPTAIN/state" FM_DATA_OVERRIDE="$CAPTAIN/data" \
  FM_CONFIG_OVERRIDE="$CAPTAIN/config" FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
  FM_TEST_TASKS_AXI_ADD_LOG="$ADD_LOG" \
  "$ROOT/bin/fm-captain-hold.sh" hold wedged-hold --title 'Wedged hold' --reason 'backend wedged' \
  > "$HOLD_STDOUT" 2> "$HOLD_OUT" || HOLD_STATUS=$?

[ "$HOLD_STATUS" -ne 0 ] \
  || fail "holding a task against a wedged backend must not report success: $(cat "$HOLD_OUT")"
[ ! -s "$ADD_LOG" ] \
  || fail "a timed-out read was spent as absence: tasks-axi add ran anyway: $(cat "$ADD_LOG")"
[ "$(elapsed_since "$HOLD_START")" -lt "$BOUND_CEILING" ] \
  || fail "holding a task exceeded the bounded-read ceiling: $(cat "$HOLD_OUT")"
[ ! -s "$HOLD_STDOUT" ] \
  || fail "a timed-out hold reported a task outcome: $(cat "$HOLD_STDOUT")"
pass "a bound hit stops a captain hold without creating a task"

# The teardown gate reaches a row read through the same resolver, so the bound
# hit has to survive the command substitution that carries the resolved id.
fm_write_meta "$CAPTAIN/state/wedged-origin.meta" \
  'window=firstmate:fm-wedged-origin' \
  'worktree=/nonexistent/wedged-origin' \
  'project=alpha' \
  'harness=claude' \
  'decisions_reviewed=1' \
  'decision_keys=wedged-entry'

VERIFY_OUT="$CAPTAIN/verify.out"
VERIFY_STDOUT="$CAPTAIN/verify.stdout"
VERIFY_LOG="$CAPTAIN/verify.log"
VERIFY_STATUS=0
VERIFY_START=$(date +%s)
PATH="$CAPTAIN_FAKEBIN:$BASE_PATH" FM_HOME="$CAPTAIN" \
  FM_STATE_OVERRIDE="$CAPTAIN/state" FM_DATA_OVERRIDE="$CAPTAIN/data" \
  FM_CONFIG_OVERRIDE="$CAPTAIN/config" FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
  FM_TEST_TASKS_AXI_HANG_LOG="$VERIFY_LOG" \
  "$ROOT/bin/fm-captain-hold.sh" verify wedged-origin > "$VERIFY_STDOUT" 2> "$VERIFY_OUT" || VERIFY_STATUS=$?

[ "$VERIFY_STATUS" -ne 0 ] \
  || fail "verify must not attest an inventory it could not read: $(cat "$VERIFY_OUT")"
[ "$(elapsed_since "$VERIFY_START")" -lt "$BOUND_CEILING" ] \
  || fail "verify exceeded the bounded-read ceiling: $(cat "$VERIFY_OUT")"
[ ! -s "$VERIFY_STDOUT" ] \
  || fail "verify attested an unreadable inventory: $(cat "$VERIFY_STDOUT")"
[ "$(cat "$VERIFY_LOG")" = wedged-entry ] \
  || fail "verify continued resolving after a bound hit: $(cat "$VERIFY_LOG")"
pass "the teardown verify gate stops at a bound hit without attesting the inventory"

# The reconcile-requests intake reads each row with task_show in this shell and
# must stop on a bound hit by name; spending the 124 as 'refused: <id>
# (absent)' would let a wedged backend erase real rows from the reconcile
# sweep.
REQ="$TMP_ROOT/req"
REQ_FAKEBIN=$(fm_fakebin "$REQ")
mkdir -p "$REQ/data" "$REQ/state" "$REQ/config" "$REQ/state/decision-bindings"
make_hanging_tasks_axi "$REQ_FAKEBIN"
cp "$ROOT/.tasks.toml" "$REQ/.tasks.toml"
printf '# Backlog\n' > "$REQ/data/backlog.md"
printf 'schema=fm-decision-binding.v1\norigin=wedged-origin\n' \
  > "$REQ/state/decision-bindings/probe.origin"

REQ_OUT="$REQ/req.out"
REQ_STDOUT="$REQ/req.stdout"
REQ_STATUS=0
REQ_START=$(date +%s)
printf 'wedged-req\n' \
  | PATH="$REQ_FAKEBIN:$BASE_PATH" FM_HOME="$REQ" \
    FM_STATE_OVERRIDE="$REQ/state" FM_DATA_OVERRIDE="$REQ/data" \
    FM_CONFIG_OVERRIDE="$REQ/config" FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
    "$ROOT/bin/fm-captain-hold.sh" reconcile-requests --source-id probe --source 'test capture' \
    > "$REQ_STDOUT" 2> "$REQ_OUT" || REQ_STATUS=$?

[ "$REQ_STATUS" -ne 0 ] \
  || fail "reconcile-requests must not report success against a wedged backend: $(cat "$REQ_OUT")"
[ "$(elapsed_since "$REQ_START")" -lt "$BOUND_CEILING" ] \
  || fail "the reconcile intake exceeded the bounded-read ceiling: $(cat "$REQ_OUT")"
[ ! -s "$REQ_STDOUT" ] \
  || fail "the reconcile intake classified a timed-out row: $(cat "$REQ_STDOUT")"
assert_absent "$REQ/state/reconcile-requests/wedged-req.request" \
  "a timed-out row must not create a reconcile request"
pass "the reconcile-requests intake stops at a bound hit without classifying or recording the row"

# The migrated-prefix scan is the resolution path whose exact and legacy ids
# genuinely answer NOT_FOUND: only the prefixed migrated row wedges. A dropped
# 124 there falls through to 'no captain-held task $entry resolves to nothing'
# - the exact bound-hit-as-absence outcome the resolver's own 124 arm exists to
# prevent - so the bound must survive the prefixed scan to verify_entry_durable.
MIG="$TMP_ROOT/migrated"
MIG_FAKEBIN=$(fm_fakebin "$MIG")
mkdir -p "$MIG/data" "$MIG/state" "$MIG/config"
cat > "$MIG_FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '%s\n' '0.2.6'; exit 0 ;;
  show)
    printf '%s\n' "${2:-}" >> "$FM_TEST_TASKS_AXI_SHOW_LOG"
    [ -z "${2:-}" ] && { printf 'code: NOT_FOUND\n' >&2; exit 1; }
    # Only the prefixed migrated candidates wedge; the exact and legacy ids
    # answer NOT_FOUND promptly, the concrete path the prefix scan exists for.
    case "$2" in $FM_TEST_PREFIXED_GLOB) sleep "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}"; exit 0 ;; esac
    printf 'code: NOT_FOUND\n' >&2
    exit 1
    ;;
  update)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --body-file <path>' '  --archive-body'
    exit 0
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
    exit 0
    ;;
  hold)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi hold <id> [flags]' '  --kind captain' '  --until <date>'
    exit 0
    ;;
  list)
    printf 'count: 0\n'
    printf 'tasks[0]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:\n'
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$MIG_FAKEBIN/tasks-axi"
cat > "$MIG_FAKEBIN/bd" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list ] && { printf '[]\n'; exit 0; }
exit 1
SH
chmod +x "$MIG_FAKEBIN/bd"
cat > "$MIG/.tasks.toml" <<'TOML'
backend = "beads"

[beads]
prefix = "bd"
path = "graph"
binary = "bd"
TOML
printf '# Backlog\n' > "$MIG/data/backlog.md"
fm_write_meta "$MIG/state/wedged-origin.meta" \
  'window=firstmate:fm-wedged-origin' \
  'worktree=/nonexistent/wedged-origin' \
  'project=alpha' \
  'harness=claude' \
  'decisions_reviewed=1' \
  'decision_keys=mig-entry'

VERIFY_MIG_OUT="$MIG/verify.out"
VERIFY_MIG_STDOUT="$MIG/verify.stdout"
VERIFY_MIG_LOG="$MIG/verify.log"
VERIFY_MIG_STATUS=0
VERIFY_MIG_START=$(date +%s)
PATH="$MIG_FAKEBIN:$BASE_PATH" FM_HOME="$MIG" \
  FM_STATE_OVERRIDE="$MIG/state" FM_DATA_OVERRIDE="$MIG/data" \
  FM_CONFIG_OVERRIDE="$MIG/config" FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
  FM_TEST_PREFIXED_GLOB='bd-*' \
  FM_TEST_TASKS_AXI_SHOW_LOG="$VERIFY_MIG_LOG" \
  "$ROOT/bin/fm-captain-hold.sh" verify wedged-origin > "$VERIFY_MIG_STDOUT" 2> "$VERIFY_MIG_OUT" || VERIFY_MIG_STATUS=$?

[ "$VERIFY_MIG_STATUS" -ne 0 ] \
  || fail "verify must not attest an inventory whose migrated-prefix read wedged: $(cat "$VERIFY_MIG_OUT")"
[ "$(elapsed_since "$VERIFY_MIG_START")" -lt "$BOUND_CEILING" ] \
  || fail "migrated-prefix verify exceeded the bounded-read ceiling: $(cat "$VERIFY_MIG_OUT")"
[ ! -s "$VERIFY_MIG_STDOUT" ] \
  || fail "verify attested an unreadable migrated inventory: $(cat "$VERIFY_MIG_STDOUT")"
[ "$(cat "$VERIFY_MIG_LOG")" = "$(printf '%s\n' mig-entry wedged-origin-decision-mig-entry bd-mig-entry)" ] \
  || fail "verify continued resolving after the migrated-prefix bound hit: $(cat "$VERIFY_MIG_LOG")"
pass "a bound hit in the migrated-prefix scan stops verify without attesting the inventory"

# --- half two: the digest still completes end to end ------------------------

E2E="$TMP_ROOT/e2e"
E2E_ROOT="$E2E/root"
E2E_HOME="$E2E/home"
E2E_FAKEBIN="$E2E/fakebin"
mkdir -p "$E2E_HOME/state" "$E2E_HOME/data" "$E2E_HOME/config" "$E2E_FAKEBIN"
git init -q -b main "$E2E_ROOT"
git -C "$E2E_ROOT" commit -q --allow-empty -m init

make_hanging_tasks_axi "$E2E_FAKEBIN"
cp "$E2E_FAKEBIN/tasks-axi" "$E2E_FAKEBIN/tasks-axi-hanging"
cat > "$E2E_FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  show)
    full=0
    for arg in "$@"; do
      [ "$arg" != --full ] || full=1
    done
    printf '%s %s\n' "$2" "$full" >> "$FM_TEST_TASKS_AXI_SHOW_LOG"
    if [ "$full" = 1 ]; then
      exec "$(dirname "$0")/tasks-axi-hanging" "$@"
    fi
    printf 'task:\n  state: queued\n  held: no\n  blocked: no\n'
    exit 0
    ;;
  start|reopen|update)
    if [ "${2:-}" != --help ]; then
      printf '%s\n' "$*" >> "$FM_TEST_TASKS_AXI_MUTATION_LOG"
      exit 1
    fi
    ;;
esac
exec "$(dirname "$0")/tasks-axi-hanging" "$@"
SH
chmod +x "$E2E_FAKEBIN/tasks-axi"
# The reconcile sweep this half asserts on runs only under a verified fleet
# lock, and fm-lock.sh finds its holder by walking the invoking process tree
# through `ps`. A CI runner's ancestry carries no harness process, so the lock
# would be refused there and the sweep silently skipped. Pin the lock evidence
# the same way tests/fm-session-start.test.sh's make_fake_ps_harness does:
# every queried pid reports a live `claude` harness, independent of whatever
# process tree the test itself was launched from.
cat > "$E2E_FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/claude'; exit 0 ;;
  *"args="*) printf '%s\n' 'claude'; exit 0 ;;
  *"ppid="*) exit 1 ;;
esac
exit 1
SH
chmod +x "$E2E_FAKEBIN/ps"
fm_fake_exit0 "$E2E_FAKEBIN" tmux node chrome-devtools-axi gh treehouse
fm_fake_version_tool "$E2E_FAKEBIN" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
fm_fake_version_tool "$E2E_FAKEBIN" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
fm_fake_version_tool "$E2E_FAKEBIN" no-mistakes FM_FAKE_NO_MISTAKES_VERSION \
  'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'

printf '# Backlog\n' > "$E2E_HOME/data/backlog.md"
printf 'backend = "markdown"\n' > "$E2E_HOME/.tasks.toml"
for ID in wedged-task-a wedged-task-b wedged-task-c; do
  fm_write_meta "$E2E_HOME/state/$ID.meta" \
    "window=firstmate:fm-$ID" \
    "worktree=/nonexistent/$ID" \
    'project=alpha' \
    'harness=claude' \
    'mode=no-mistakes' \
    'yolo=off'
done

DIGEST="$E2E/digest.out"
SHOW_LOG="$E2E/show.log"
MUTATION_LOG="$E2E/mutation.log"
DIGEST_START=$(date +%s)
env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
  FM_HOME="$E2E_HOME" FM_ROOT_OVERRIDE="$E2E_ROOT" PATH="$E2E_FAKEBIN:$BASE_PATH" \
  FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
  FM_TEST_TASKS_AXI_SHOW_LOG="$SHOW_LOG" FM_TEST_TASKS_AXI_MUTATION_LOG="$MUTATION_LOG" \
  "$ROOT/bin/fm-session-start.sh" > "$DIGEST" 2>&1 || true
DIGEST_ELAPSED=$(elapsed_since "$DIGEST_START")

[ "$DIGEST_ELAPSED" -lt 120 ] \
  || fail "session start took ${DIGEST_ELAPSED}s against a wedged backlog backend"

for SECTION in 'WAKE QUEUE' 'SUPERVISION OPERATING INSTRUCTIONS' 'FLEET STATE' 'CONTEXT'; do
  grep -q "$SECTION" "$DIGEST" \
    || fail "the digest lost its $SECTION section against a wedged backlog backend: $(cat "$DIGEST")"
done
pass "a wedged backlog backend still leaves a complete digest: wake queue, supervision instructions, fleet state, and context all print"

grep -q '^BACKLOG_RECONCILE: wedged-task-a: .*could not be moved to In flight: .*exceeded' "$DIGEST" \
  || fail "the full-body timeout must be reported for the first queued worker: $(cat "$DIGEST")"
for ID in wedged-task-b wedged-task-c; do
  grep -q "^BACKLOG_RECONCILE: $ID: .*could not be read: .*skipped" "$DIGEST" \
    || fail "the later worker must be reported as skipped without repeating the timeout: $(cat "$DIGEST")"
done
[ "$(cat "$SHOW_LOG")" = "$(printf 'wedged-task-a 0\nwedged-task-a 1')" ] \
  || fail "the recovery sweep repeated backend reads after the full-body timeout: $(cat "$SHOW_LOG")"
assert_absent "$MUTATION_LOG" "a timed-out full-body read must not mutate the queued backlog"
pass "a full-body restart timeout latches the recovery sweep, naming every worker without another backend read"

echo "# fm-backlog-read-bound.test.sh: all assertions passed"
