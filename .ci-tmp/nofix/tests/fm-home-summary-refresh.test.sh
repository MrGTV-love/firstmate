#!/usr/bin/env bash
# Behavioral coverage for per-home summary publication through the real
# producer, writer, watcher-carried status trigger, and snapshot ledger consumer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-summary-refresh)
HOME_DIR="$TMP_ROOT/mate-home"
CADENCE_HOME="$TMP_ROOT/cadence-home"
PARENT_HOME="$TMP_ROOT/parent-home"
LARGE_HOME="$TMP_ROOT/large-home"
STATELESS_HOME="$TMP_ROOT/stateless-home"
LARGE_CHILD_HOME="$TMP_ROOT/large-child-home"
LARGE_PARENT_HOME="$TMP_ROOT/large-parent-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
WATCH_PID=
SLOW_WRITER_PID=
SUCCESS_WRITER_PID=
SLOW_WORKER_PGID=
SLOW_NM_PID=
LOCK_HOLDER_PID=

cleanup() {
  local pid
  case "$SLOW_WORKER_PGID" in
    ''|*[!0-9]*) ;;
    *) kill -KILL -- "-$SLOW_WORKER_PGID" >/dev/null 2>&1 || true ;;
  esac
  for pid in "$WATCH_PID" "$SLOW_WRITER_PID" "$SUCCESS_WRITER_PID" "$SLOW_NM_PID" "$LOCK_HOLDER_PID"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_NM_COUNT:-}" ]; then
  printf '.\n' >> "$FM_TEST_NM_COUNT"
fi
if [ -n "${FM_TEST_NM_HOLD:-}" ] && [ -e "$FM_TEST_NM_HOLD" ]; then
  printf '%s\n' "$$" > "$FM_TEST_NM_HOLD.entered"
  while [ -e "$FM_TEST_NM_HOLD" ]; do sleep 0.1; done
fi
if [ -n "${FM_TEST_NM_MARKER:-}" ]; then
  printf '%s\n' "$$" > "$FM_TEST_NM_MARKER"
  sleep "${FM_TEST_NM_SLEEP:-30}"
fi
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" \
  "$HOME_DIR/projects/task" "$HOME_DIR/bin"
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
printf '# Seeded Firstmate home\n' > "$HOME_DIR/AGENTS.md"
printf 'mate\n' > "$HOME_DIR/.fm-secondmate-home"
fm_git_init_commit "$HOME_DIR/projects/task"
git -C "$HOME_DIR/projects/task" checkout -q -b fm/ledger-task
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight
- [ ] ledger-task - Publish the home ledger (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$HOME_DIR/state/ledger-task.meta" \
  "window=fmtest:fm-ledger-task" \
  "worktree=$HOME_DIR/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.ledger123456"
busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" ledger-task)
"$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" ledger-task idle \
  --gen "$busy_gen" --source claude-hook --event stop

NOW_ONE=2026-08-28T10:00:00Z
EPOCH_ONE=1787911200
NOW_TWO=2026-08-28T10:01:00Z
EPOCH_TWO=1787911260
NOW_THREE=2026-08-28T10:02:00Z
EPOCH_THREE=1787911320

run_writer() {  # <now> <epoch> [writer args...]
  local now=$1 epoch=$2
  shift 2
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_SNAPSHOT_NOW="$now" FM_SNAPSHOT_NOW_EPOCH="$epoch" \
    "$WRITER" "$@"
}

run_producer() {  # <now> <epoch>
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_SNAPSHOT_NOW="$1" FM_SNAPSHOT_NOW_EPOCH="$2" \
    "$SNAPSHOT" --secondmate-home-summary
}

wait_for_ledger_generation() {  # <generated> [tenths]
  local want=$1 attempts=${2:-150} i=0 got
  while [ "$i" -lt "$attempts" ]; do
    got=$(jq -r '.generated // ""' "$HOME_DIR/state/home-summary.json" 2>/dev/null || true)
    [ "$got" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_writer "$NOW_ONE" "$EPOCH_ONE" || fail "initial home-summary publication failed"
jq -e --arg home "$HOME_DIR" --arg now "$NOW_ONE" --argjson epoch "$EPOCH_ONE" '
  .schema == "fm-secondmate-home-summary.v1"
  and .home == $home
  and .generated == $now
  and .generated_epoch == $epoch
' "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "initial ledger did not expose the extended producer schema"

PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$HOME_DIR/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$HOME_DIR/state/.last-watcher-beat" ] \
  || fail "the real watcher did not begin polling: $(cat "$TMP_ROOT/watch.err" 2>/dev/null)"
printf 'blocked [key=fixture-dependency]: waiting for the fixture dependency\n' \
  >> "$HOME_DIR/state/ledger-task.status"
wait_for_ledger_generation "$NOW_TWO" \
  || fail "a status append did not refresh the ledger within the watcher cadence"
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=

run_producer "$NOW_TWO" "$EPOCH_TWO" > "$TMP_ROOT/fresh-summary.json" \
  || fail "fresh secondmate-home-summary production failed"
jq -S 'del(.generated, .generated_epoch)' "$HOME_DIR/state/home-summary.json" \
  > "$TMP_ROOT/published-normalized.json"
jq -S 'del(.generated, .generated_epoch)' "$TMP_ROOT/fresh-summary.json" \
  > "$TMP_ROOT/fresh-normalized.json"
cmp -s "$TMP_ROOT/published-normalized.json" "$TMP_ROOT/fresh-normalized.json" \
  || fail "the status-triggered ledger differed from the real fresh producer"
pass "watcher-carried status append publishes the real home summary"

# A structured in-flight inventory above Linux MAX_ARG_STRLEN must remain
# publishable through both fleet snapshot modes and the real home-summary writer.
mkdir -p "$LARGE_HOME/state" "$LARGE_HOME/data" "$LARGE_HOME/config" \
  "$LARGE_HOME/projects"
printf '# Seeded Firstmate home\n' > "$LARGE_HOME/AGENTS.md"
printf 'large\n' > "$LARGE_HOME/.fm-secondmate-home"
large_id_suffix=$(printf 'i%.0s' $(seq 1 110))
{
  printf '%s\n' '## In flight'
  i=1
  while [ "$i" -le 1200 ]; do
    printf '%s\n' "- [ ] orphan-$i-$large_id_suffix - Missing metadata (repo: firstmate) (kind: ship)"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Queued' '' '## Done'
} > "$LARGE_HOME/data/backlog.md"
[ "$(wc -c < "$LARGE_HOME/data/backlog.md")" -gt 131072 ] \
  || fail "large in-flight fixture did not exceed the per-argument limit"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/large-snapshot.json" \
  || fail "fleet snapshot json mode failed for a large backlog"
jq -e '.schema == "fm-fleet-snapshot.v1"
  and (.backlog.records | length) == 1200
  and (.main_inventory.orphan_in_flight | length) == 1200' \
  "$TMP_ROOT/large-snapshot.json" >/dev/null \
  || fail "large fleet snapshot did not preserve the orphan inventory"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/large-summary.json" \
  || fail "secondmate home-summary mode failed for a large backlog"
jq -e '.schema == "fm-secondmate-home-summary.v1"' "$TMP_ROOT/large-summary.json" \
  >/dev/null || fail "large secondmate home-summary output was not valid"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "home-summary writer failed for a large backlog"
jq -e '.schema == "fm-secondmate-home-summary.v1"' \
  "$LARGE_HOME/state/home-summary.json" >/dev/null \
  || fail "large secondmate home-summary was not published"
pass "large backlog snapshots and home-summary publication stay within exec limits"

mkdir -p "$STATELESS_HOME/data" "$STATELESS_HOME/config" \
  "$STATELESS_HOME/projects"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
  > "$STATELESS_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STATELESS_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/stateless-snapshot.json" \
  || fail "fleet snapshot json mode failed without a state directory"
jq -e '.schema == "fm-fleet-snapshot.v1" and (.tasks | length) == 0' \
  "$TMP_ROOT/stateless-snapshot.json" >/dev/null \
  || fail "stateless fleet snapshot output was not valid"
[ ! -e "$STATELESS_HOME/state" ] \
  || fail "fleet snapshot created operational state for transport files"
pass "fleet snapshot transport does not require or mutate operational state"

mkdir -p "$LARGE_CHILD_HOME/state" "$LARGE_CHILD_HOME/data" \
  "$LARGE_CHILD_HOME/config" "$LARGE_CHILD_HOME/projects" "$LARGE_CHILD_HOME/bin"
printf '# Seeded Firstmate home\n' > "$LARGE_CHILD_HOME/AGENTS.md"
printf 'large-child\n' > "$LARGE_CHILD_HOME/.fm-secondmate-home"
{
  printf '%s\n' '## In flight'
  i=1
  while [ "$i" -le 600 ]; do
    printf '%s\n' "- [ ] orphan-$i-$large_id_suffix - Missing metadata (repo: firstmate) (kind: ship)"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Queued' '' '## Done'
} > "$LARGE_CHILD_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_CHILD_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "large child home-summary publication failed"
large_child_bytes=$(wc -c < "$LARGE_CHILD_HOME/state/home-summary.json")
[ "$large_child_bytes" -gt 131072 ] && [ "$large_child_bytes" -le 262144 ] \
  || fail "large child ledger did not cross only the per-argument limit: $large_child_bytes"
mkdir -p "$LARGE_PARENT_HOME/state" "$LARGE_PARENT_HOME/data" \
  "$LARGE_PARENT_HOME/config" "$LARGE_PARENT_HOME/projects"
printf -- '- large-child - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-08-28)\n' \
  "$LARGE_CHILD_HOME" > "$LARGE_PARENT_HOME/data/secondmates.md"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
  > "$LARGE_PARENT_HOME/data/backlog.md"
fm_write_secondmate_meta "$LARGE_PARENT_HOME/state/large-child.meta" \
  "$LARGE_CHILD_HOME" "fmtest:fm-large-child" firstmate claude
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_PARENT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/large-parent-snapshot.json" \
  || fail "parent fleet snapshot failed for a large child ledger"
jq -e '.secondmate_current.records[0]
  | .provenance.summary_source == "local-ledger"
    and .invalidity.kind == "orphan_in_flight"
    and (.invalidity.ids | length) == 600' \
  "$TMP_ROOT/large-parent-snapshot.json" >/dev/null \
  || fail "parent fleet snapshot did not preserve the large child invalidity: $(jq -c '.secondmate_current.records[0]' "$TMP_ROOT/large-parent-snapshot.json")"
pass "parent snapshot consumes large child ledgers without argument transport"

mkdir -p "$CADENCE_HOME/state" "$CADENCE_HOME/data" "$CADENCE_HOME/config" \
  "$CADENCE_HOME/projects"
printf '# Seeded Firstmate home\n' > "$CADENCE_HOME/AGENTS.md"
printf 'cadence\n' > "$CADENCE_HOME/.fm-secondmate-home"
cat > "$CADENCE_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CADENCE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$WRITER" || fail "could not seed the cadence ledger"
touch -t 203801010000 "$CADENCE_HOME/state/home-summary.json"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CADENCE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/cadence-watch.out" 2> "$TMP_ROOT/cadence-watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$CADENCE_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$CADENCE_HOME/state/.last-watcher-beat" ] \
  || fail "the cadence watcher did not complete its initial cycle"
python3 - "$CADENCE_HOME/data/backlog.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("## Queued\n\n## Done", "## Queued\n- [ ] cadence-task - Publish without a status signal (repo: firstmate) (kind: ship)\n\n## Done"))
PY
i=0
while ! jq -e 'any(.queued[]; .id == "cadence-task")' \
  "$CADENCE_HOME/state/home-summary.json" >/dev/null 2>&1; do
  kill -0 "$WATCH_PID" 2>/dev/null \
    || fail "the cadence watcher exited before publishing the backlog-only change"
  [ "$i" -lt 80 ] \
    || fail "a backlog-only change did not refresh within the configured watcher cadence"
  sleep 0.1
  i=$((i + 1))
done
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
pass "live watcher cadence bounds publication staleness without signals"

# Consumer boundary: first serialize behind any watcher-started publication,
# then replace the ledger with a structurally complete but semantically false
# state. The default parent snapshot must consume that publication rather than
# silently recomputing a different view of the owning home.
run_writer "$NOW_TWO" "$EPOCH_TWO" || fail "could not settle the ledger before the consumer check"
jq '.state = "no_active_work" | .active_children = [] | .holds = []
    | .counts.active_children = 0 | .counts.holds = 0' \
  "$HOME_DIR/state/home-summary.json" > "$HOME_DIR/state/home-summary.poisoned"
mv -f "$HOME_DIR/state/home-summary.poisoned" "$HOME_DIR/state/home-summary.json"
mkdir -p "$PARENT_HOME/state" "$PARENT_HOME/data" "$PARENT_HOME/config" "$PARENT_HOME/projects"
printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-08-28)\n' \
  "$HOME_DIR" > "$PARENT_HOME/data/secondmates.md"
cat > "$PARENT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
fm_write_secondmate_meta "$PARENT_HOME/state/mate.meta" "$HOME_DIR" \
  "fmtest:fm-mate" firstmate claude
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$PARENT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$SNAPSHOT" --json > "$TMP_ROOT/parent-snapshot.json" \
  || fail "parent fleet snapshot failed"
jq -e '
  .secondmate_current.records[0].provenance.selected == "structured-home"
  and .secondmate_current.records[0].provenance.summary_source == "local-ledger"
  and .secondmate_current.records[0].current.state == "no_active_work"
  and (.secondmate_current.records[0].active_children | length) == 0
  and (.secondmate_current.records[0].holds | length) == 0
' "$TMP_ROOT/parent-snapshot.json" >/dev/null \
  || fail "fleet snapshot did not consume the published local ledger: $(jq -c '.secondmate_current.records[0]' "$TMP_ROOT/parent-snapshot.json")"
pass "fleet snapshot consumes the published local ledger by default"

# Restore the established ledger, then stop a real writer while its real producer
# is blocked in a current-state read. The prior ledger must remain byte-identical
# and valid because no partial producer output is ever published at its path.
run_writer "$NOW_TWO" "$EPOCH_TWO" || fail "could not restore the real ledger"
printf 'working: replacement summary is being computed\n' \
  >> "$HOME_DIR/state/ledger-task.status"
cp "$HOME_DIR/state/home-summary.json" "$TMP_ROOT/prior-ledger.json"
SLOW_MARKER="$TMP_ROOT/slow-no-mistakes.pid"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_TEST_NM_MARKER="$SLOW_MARKER" FM_TEST_NM_SLEEP=30 \
  "$WRITER" > "$TMP_ROOT/killed-writer.out" 2> "$TMP_ROOT/killed-writer.err" &
SLOW_WRITER_PID=$!
i=0
while [ ! -s "$SLOW_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$SLOW_WRITER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -s "$SLOW_MARKER" ] || fail "the real producer did not reach the controlled slow current-state read"
SLOW_NM_PID=$(cat "$SLOW_MARKER" 2>/dev/null || true)
writer_pgid=$(ps -o pgid= -p "$SLOW_WRITER_PID" 2>/dev/null | tr -d '[:space:]')
ancestor=$SLOW_NM_PID
child_pgid=
i=0
while [ "$i" -lt 20 ]; do
  ancestor_pgid=$(ps -o pgid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]')
  parent=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]')
  if [ "$parent" = "$SLOW_WRITER_PID" ]; then
    if [ "$ancestor_pgid" != "$writer_pgid" ]; then
      SLOW_WORKER_PGID=$ancestor_pgid
    else
      SLOW_WORKER_PGID=$child_pgid
    fi
    break
  fi
  child_pgid=$ancestor_pgid
  ancestor=$parent
  i=$((i + 1))
done
case "$SLOW_WORKER_PGID" in
  ''|*[!0-9]*) fail "the bounded writer did not expose its worker process group" ;;
esac
[ "$SLOW_WORKER_PGID" != "$writer_pgid" ] \
  || fail "the bounded worker did not have an isolated process group"
kill -KILL -- "-$SLOW_WORKER_PGID" >/dev/null 2>&1 \
  || fail "the bounded writer process group could not be terminated"
wait "$SLOW_WRITER_PID" >/dev/null 2>&1 || true
SLOW_WRITER_PID=
SLOW_WORKER_PGID=
SLOW_NM_PID=
jq -e . "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "killing the writer exposed invalid JSON at the ledger path"
cmp -s "$TMP_ROOT/prior-ledger.json" "$HOME_DIR/state/home-summary.json" \
  || fail "killing the writer replaced the prior complete ledger"

# Observe the ledger continuously through one successful replacement. Every read
# must parse, and the final document must be the newly computed complete summary.
READER_FAILURE="$TMP_ROOT/reader-failure"
SUCCESS_MARKER="$TMP_ROOT/success-no-mistakes.pid"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_TEST_NM_MARKER="$SUCCESS_MARKER" FM_TEST_NM_SLEEP=1 \
  "$WRITER" > "$TMP_ROOT/success-writer.out" 2> "$TMP_ROOT/success-writer.err" &
SLOW_WRITER_PID=$!
while kill -0 "$SLOW_WRITER_PID" 2>/dev/null; do
  if ! jq -e . "$HOME_DIR/state/home-summary.json" >/dev/null 2>&1; then
    : > "$READER_FAILURE"
    break
  fi
done
if ! wait "$SLOW_WRITER_PID"; then
  SLOW_WRITER_PID=
  fail "successful atomic replacement failed: $(cat "$TMP_ROOT/success-writer.err" 2>/dev/null)"
fi
SLOW_WRITER_PID=
[ ! -e "$READER_FAILURE" ] || fail "a reader observed torn JSON during atomic replacement"
jq -e --arg now "$NOW_THREE" --argjson epoch "$EPOCH_THREE" '
  .generated == $now and .generated_epoch == $epoch
' "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "the successful replacement did not publish the new complete document"
pass "writer kill and replacement preserve an atomic JSON ledger"

# Best-effort mode is the contract used by every lifecycle trigger. A failed
# producer records the failure and returns success without touching the ledger.
FAILBIN="$TMP_ROOT/failbin"
mkdir -p "$FAILBIN"
cat > "$FAILBIN/jq" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$FAILBIN/jq"
cp "$HOME_DIR/state/home-summary.json" "$TMP_ROOT/before-best-effort.json"
PATH="$FAILBIN:$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$WRITER" --best-effort \
  || fail "best-effort refresh propagated its producer failure"
cmp -s "$TMP_ROOT/before-best-effort.json" "$HOME_DIR/state/home-summary.json" \
  || fail "failed best-effort refresh changed the prior ledger"
grep -F 'summary producer failed' "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "best-effort refresh did not log its failure"
pass "best-effort publication logs and continues"

LOCK_MARKER="$TMP_ROOT/lock-held"
cp "$HOME_DIR/state/.home-summary-refresh.streak" "$TMP_ROOT/before-lock-timeouts.streak" \
  || fail "the acquired producer failure left no failure streak"
rm -f "$HOME_DIR/state/.home-summary-refresh.log"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$HOME_DIR" "$LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$LOCK_MARKER" ] || fail "could not hold the publication lock for timeout coverage"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_HOME_SUMMARY_TIMEOUT=1 "$WRITER" --best-effort \
  || fail "lock timeout changed the best-effort caller result"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_HOME_SUMMARY_TIMEOUT=1 "$WRITER" --best-effort \
  || fail "repeated lock timeout changed the best-effort caller result"
[ "$(grep -c 'refresh exceeded its 1-second deadline' "$HOME_DIR/state/.home-summary-refresh.log" 2>/dev/null || true)" -ge 2 ] \
  || fail "repeated publication lock timeouts vanished from failure reporting"
cmp -s "$TMP_ROOT/before-lock-timeouts.streak" "$HOME_DIR/state/.home-summary-refresh.streak" \
  || fail "lock-contention failures changed the streak without refresh ownership"
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
pass "best-effort refresh bounds publication lock acquisition"

HANGBIN="$TMP_ROOT/hangbin"
REAL_JQ=$(command -v jq)
mkdir -p "$HANGBIN"
cat > "$HANGBIN/jq" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.home-summary.json.*) sleep 30 ;;
  esac
done
exec "$FM_TEST_REAL_JQ" "$@"
SH
chmod +x "$HANGBIN/jq"
rm -f "$HOME_DIR/state/.home-summary-refresh.log"
PATH="$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=1 \
  "$WRITER" --best-effort \
  || fail "validation timeout changed the best-effort caller result"
grep -F 'refresh exceeded its 1-second deadline' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "publication validation timeout was not logged"
pass "best-effort refresh bounds validation and publication"

MKBIN="$TMP_ROOT/mkdir-hangbin"
REAL_MKDIR=$(command -v mkdir)
mkdir -p "$MKBIN"
cat > "$MKBIN/mkdir" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_TEST_STALLED_STATE" ]; then
    if [ -n "${FM_TEST_MKDIR_MARKER:-}" ] && [ ! -e "$FM_TEST_MKDIR_MARKER" ]; then
      printf '%s\n' "$$" > "$FM_TEST_MKDIR_MARKER"
    fi
    sleep 30
    [ -z "${FM_TEST_MKDIR_DONE_MARKER:-}" ] || : > "$FM_TEST_MKDIR_DONE_MARKER"
  fi
done
exec "$FM_TEST_REAL_MKDIR" "$@"
SH
chmod +x "$MKBIN/mkdir"
INIT_ENTERED="$TMP_ROOT/state-init-entered"
INIT_DONE="$TMP_ROOT/state-init-done"
cp "$HOME_DIR/state/home-summary.json" "$TMP_ROOT/before-state-init-ledger.json"
PATH="$MKBIN:$FAKEBIN:$PATH" FM_TEST_REAL_MKDIR="$REAL_MKDIR" \
  FM_TEST_MKDIR_MARKER="$INIT_ENTERED" FM_TEST_MKDIR_DONE_MARKER="$INIT_DONE" \
  FM_TEST_STALLED_STATE="$HOME_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=1 \
  "$WRITER" --best-effort >/dev/null 2>"$TMP_ROOT/stalled-state.err" \
  || fail "state initialization timeout changed the best-effort caller result"
[ -s "$INIT_ENTERED" ] || fail "the refresh never attempted state initialization"
[ ! -e "$INIT_DONE" ] || fail "the stalled initializer completed instead of being interrupted"
init_pid=$(cat "$INIT_ENTERED")
fm_test_wait_until 80 bash -c "! kill -0 \"\$1\" 2>/dev/null" _ "$init_pid" \
  || fail "the refresh left its stalled initializer alive"
cmp -s "$TMP_ROOT/before-state-init-ledger.json" "$HOME_DIR/state/home-summary.json" \
  || fail "interrupted initialization changed the prior published ledger"
pass "best-effort refresh bounds state initialization"

DETACH_INIT_MARKER="$TMP_ROOT/detach-init-entered"
PATH="$MKBIN:$FAKEBIN:$PATH" FM_TEST_REAL_MKDIR="$REAL_MKDIR" \
  FM_TEST_STALLED_STATE="$HOME_DIR/state" FM_TEST_MKDIR_MARKER="$DETACH_INIT_MARKER" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=1 \
  WRITER="$WRITER" python3 - <<'PY' \
  || fail "detached state initialization blocked its foreground caller"
import os
import signal
import subprocess
import time

started = time.monotonic()
process = subprocess.Popen(
    [os.environ["WRITER"], "--detach"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
try:
    result = process.wait(timeout=3)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise SystemExit("the detached foreground caller stalled on state initialization")
if result != 0:
    raise SystemExit(f"detached initialization changed caller result: {result}")
if time.monotonic() - started >= 2:
    raise SystemExit("the detached foreground caller waited for state initialization")
PY
fm_test_wait_until 60 test -e "$DETACH_INIT_MARKER" \
  || fail "the detached worker never attempted its bounded state initialization"
detach_init_pid=$(cat "$DETACH_INIT_MARKER")
fm_test_wait_until 80 bash -c "! kill -0 \"\$1\" 2>/dev/null" _ "$detach_init_pid" \
  || fail "the detached worker left its stalled initialization running past the bound"
pass "detached foreground returns before stalled bounded state initialization"

SIGNALBIN="$TMP_ROOT/signalbin"
SIGNAL_MARKER="$TMP_ROOT/worker-signaled"
REAL_ENV=$(command -v env)
mkdir -p "$SIGNALBIN"
cat > "$SIGNALBIN/env" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$FM_TEST_SIGNAL_MARKER" ]; then
  : > "$FM_TEST_SIGNAL_MARKER"
  exit 143
fi
exec "$FM_TEST_REAL_ENV" "$@"
SH
chmod +x "$SIGNALBIN/env"
rm -f "$HOME_DIR/state/.home-summary-refresh.log"
PATH="$SIGNALBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$REAL_ENV" \
  FM_TEST_SIGNAL_MARKER="$SIGNAL_MARKER" FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" "$WRITER" --best-effort \
  || fail "worker termination changed the best-effort caller result"
grep -F 'refresh worker failed with exit 143' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "worker termination was not logged at the parent boundary"
pass "best-effort refresh logs worker termination"

rm -f "$SIGNAL_MARKER" "$HOME_DIR/state/.home-summary-refresh.log"
mkdir "$HOME_DIR/state/.home-summary-refresh.log"
if ! PATH="$SIGNALBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$REAL_ENV" \
  FM_TEST_SIGNAL_MARKER="$SIGNAL_MARKER" FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=1 \
  WRITER="$WRITER" python3 - <<'PY'
import os
import subprocess

read_fd, write_fd = os.pipe()
os.set_blocking(write_fd, False)
try:
    while True:
        os.write(write_fd, b"x" * 4096)
except BlockingIOError:
    pass
os.set_blocking(write_fd, True)
try:
    result = subprocess.run(
        [os.environ["WRITER"], "--best-effort"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=write_fd,
        env=os.environ,
        timeout=21,  # 1s refresh + 4s logging + 10s accounting + 4s release + headroom
    )
finally:
    os.close(write_fd)
    os.close(read_fd)
if result.returncode != 0:
    raise SystemExit(f"blocked failure logger changed caller result: {result.returncode}")
PY
then
  fail "best-effort failure reporting was not fully bounded"
fi
pass "best-effort refresh bounds failure reporting fallback"

PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "an unavailable failure record blocked valid publication"
jq -e --arg now "$NOW_ONE" '.generated == $now' \
  "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "valid publication did not replace the ledger with an unavailable failure record"
rmdir "$HOME_DIR/state/.home-summary-refresh.log"
pass "valid publication ignores an unavailable failure record"

# mv treats a directory destination as a container and returns success. That is
# not ledger publication: reject it while fenced, leave its contents untouched,
# and count the best-effort attempt that acquired the refresh lock.
DIRECTORY_HOME="$TMP_ROOT/directory-home"
mkdir -p "$DIRECTORY_HOME/state/home-summary.json" "$DIRECTORY_HOME/data" \
  "$DIRECTORY_HOME/config" "$DIRECTORY_HOME/projects"
printf '# Seeded Firstmate home\n' > "$DIRECTORY_HOME/AGENTS.md"
printf 'directory\n' > "$DIRECTORY_HOME/.fm-secondmate-home"
cat > "$DIRECTORY_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
printf 'prior directory contents\n' > "$DIRECTORY_HOME/state/home-summary.json/sentinel"
cp "$DIRECTORY_HOME/state/home-summary.json/sentinel" "$TMP_ROOT/directory-sentinel"
if PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$DIRECTORY_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" > "$TMP_ROOT/directory.out" 2> "$TMP_ROOT/directory.err"; then
  fail "a directory ledger destination falsely reported direct publication success"
fi
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$DIRECTORY_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" --best-effort \
  || fail "a directory ledger destination changed the best-effort caller result"
directory_streak_count=
IFS= read -r directory_streak_count < "$DIRECTORY_HOME/state/.home-summary-refresh.streak" \
  || fail "a directory destination did not write the acquired failure streak"
assert_equals 'count=1' "$directory_streak_count" \
  "a directory destination did not count exactly one acquired best-effort refresh failure"
assert_grep 'atomic ledger replacement failed: destination is a directory:' \
  "$DIRECTORY_HOME/state/.home-summary-refresh.log" \
  "a directory destination did not record its publication failure"
[ -d "$DIRECTORY_HOME/state/home-summary.json" ] \
  || fail "a failed publication replaced the directory destination"
cmp -s "$TMP_ROOT/directory-sentinel" "$DIRECTORY_HOME/state/home-summary.json/sentinel" \
  || fail "a failed publication changed existing directory contents"
for entry in "$DIRECTORY_HOME/state/home-summary.json/"* \
  "$DIRECTORY_HOME/state/home-summary.json/".[!.]* \
  "$DIRECTORY_HOME/state/home-summary.json/"..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  [ "$entry" = "$DIRECTORY_HOME/state/home-summary.json/sentinel" ] \
    || fail "a failed publication left a false ledger inside the directory: $entry"
done
[ ! -e "$DIRECTORY_HOME/state/.home-summary-refresh.lock" ] \
  || fail "a failed directory publication left the refresh lock held"
pass "directory ledger destinations fail without false publication and count acquired attempts"

# --- publication cost, beacon isolation, and failure discoverability ---------
#
# The three regressions below all came from one live incident: in a real home
# whose tasks had accumulated ordinary status history, the producer needed
# minutes, so publication burned its whole deadline on every attempt, never
# published, starved the watcher's liveness beacon while it did, and said
# nothing about any of it because --best-effort is deliberately non-fatal.

# Publication cost must scale with what a home actually accumulates. Status
# history is append-only and unbounded, and the producer folds every task's
# whole stream, so an ordinary long-lived home is the real input - not the
# one-line log a freshly seeded fixture has. This home carries a status log of
# realistic width and depth and must still publish inside a deadline well under
# the default one.
COST_HOME="$TMP_ROOT/cost-home"
mkdir -p "$COST_HOME/state" "$COST_HOME/data" "$COST_HOME/config" \
  "$COST_HOME/projects/task"
printf '# Seeded Firstmate home\n' > "$COST_HOME/AGENTS.md"
printf 'cost\n' > "$COST_HOME/.fm-secondmate-home"
fm_git_init_commit "$COST_HOME/projects/task"
cat > "$COST_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] cost-task - Publish from an accumulated home (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$COST_HOME/state/cost-task.meta" \
  "window=fmtest:fm-cost-task" \
  "worktree=$COST_HOME/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.cost123456"
cost_busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$COST_HOME/state" cost-task)
"$ROOT/bin/fm-busy-event.sh" apply "$COST_HOME/state" cost-task idle \
  --gen "$cost_busy_gen" --source claude-hook --event stop
python3 - "$COST_HOME/state/cost-task.status" <<'PY'
import sys
note = ("the crewmate ran validation and reported checks on the branch "
        "after review ") * 25
with open(sys.argv[1], "w") as handle:
    for i in range(300):
        handle.write(f"working: {note}({i})\n")
    handle.write("needs-decision [key=cost-gate]: which base to rebuild from\n")
PY
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COST_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  FM_HOME_SUMMARY_TIMEOUT=30 "$WRITER" --best-effort \
  || fail "accumulated-home publication changed the best-effort caller result"
[ -f "$COST_HOME/state/home-summary.json" ] \
  || fail "an accumulated home did not publish within a 30-second deadline: $(cat "$COST_HOME/state/.home-summary-refresh.log" 2>/dev/null)"
jq -e --arg home "$COST_HOME" '
  .schema == "fm-secondmate-home-summary.v1"
  and .home == $home
  and any(.decisions_open[]; .key == "cost-gate")
' "$COST_HOME/state/home-summary.json" >/dev/null \
  || fail "the accumulated home published a ledger missing its open decision"
pass "publication completes on a home carrying accumulated status history"

# One unreachable home must not extend publication without limit. A remote
# secondmate's current state is read over ssh, and ssh's own dead-peer detection
# deliberately never kills a slow-but-alive remote command, so nothing under the
# producer bounds that read on its own. Point the transport at a stub that never
# answers and require the producer to return anyway, reporting that home as
# unknown rather than waiting on it.
REMOTE_HOME="$TMP_ROOT/remote-home"
mkdir -p "$REMOTE_HOME/state" "$REMOTE_HOME/data" "$REMOTE_HOME/config" \
  "$REMOTE_HOME/projects" "$TMP_ROOT/sshbin"
printf '# Seeded Firstmate home\n' > "$REMOTE_HOME/AGENTS.md"
printf 'remote\n' > "$REMOTE_HOME/.fm-secondmate-home"
cat > "$REMOTE_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] rsm - Read remote current state (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
cat > "$REMOTE_HOME/data/secondmates.md" <<'EOF'
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
fm_write_meta "$REMOTE_HOME/state/rsm.meta" \
  "window=remote:rsm" \
  "endpoint_task_id=rsm" \
  "worktree=/remote/home/never-locally-present" \
  "harness=claude" \
  "kind=secondmate" \
  "mode=secondmate" \
  "home=/remote/home" \
  "remote_host=remote-mac" \
  "remote_root=/remote/root" \
  "remote_backend=herdr" \
  "remote_herdr_session=fm-remote" \
  "remote_target=fm-remote:w1:p1"
cat > "$TMP_ROOT/sshbin/stalled-ssh" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_SSH_CALLED"
cat > /dev/null
sleep 60
SH
chmod +x "$TMP_ROOT/sshbin/stalled-ssh"
started=$(date +%s)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REMOTE_HOME" \
  FM_SSH_BIN="$TMP_ROOT/sshbin/stalled-ssh" FM_TEST_SSH_CALLED="$TMP_ROOT/stalled-ssh.called" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  FM_SNAPSHOT_CREW_STATE_TIMEOUT=2 \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/stalled-summary.json" \
  || fail "an unreachable remote home failed the whole producer"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 40 ] \
  || fail "the producer waited $elapsed seconds despite skipping remote endpoint state"
[ ! -e "$TMP_ROOT/stalled-ssh.called" ] \
  || fail "the producer issued a remote per-task state probe"
jq -e '
  .schema == "fm-secondmate-home-summary.v1"
  and .valid == false
  and .state == "unknown"
  and .invalidity.kind == "child_current_unavailable"
  and (.invalidity.ids == ["rsm"])
  and any(.endpoints[]; .id == "rsm" and .state == "unknown")
' "$TMP_ROOT/stalled-summary.json" >/dev/null \
  || fail "an unreachable remote task was not reported as unknown"
pass "producer skips remote per-task state probes"

# The watcher's beacon is what the rest of supervision reads as proof it is
# alive. Publication is side-band, so no matter how long it takes, the beacon
# must keep advancing. Hold the publication lock for the whole observation
# window, then require the beacon to keep ticking anyway.
BEAT_HOME="$TMP_ROOT/beat-home"
mkdir -p "$BEAT_HOME/state" "$BEAT_HOME/data" "$BEAT_HOME/config" \
  "$BEAT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$BEAT_HOME/AGENTS.md"
printf 'beat\n' > "$BEAT_HOME/.fm-secondmate-home"
cat > "$BEAT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
BEAT_LOCK_MARKER="$TMP_ROOT/beat-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BEAT_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 120
' _ "$ROOT" "$BEAT_HOME" "$BEAT_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$BEAT_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$BEAT_LOCK_MARKER" ] || fail "could not stall publication for beacon coverage"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BEAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=1 FM_HOME_SUMMARY_TIMEOUT=90 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/beat-watch.out" 2> "$TMP_ROOT/beat-watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$BEAT_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 200 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$BEAT_HOME/state/.last-watcher-beat" ] \
  || fail "the stalled-publication watcher never beat: $(cat "$TMP_ROOT/beat-watch.err" 2>/dev/null)"
beat_mtime() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime)' "$1"; }
seen=0
last=$(beat_mtime "$BEAT_HOME/state/.last-watcher-beat")
i=0
while [ "$seen" -lt 3 ] && [ "$i" -lt 200 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null \
    || fail "the stalled-publication watcher exited: $(cat "$TMP_ROOT/beat-watch.err" 2>/dev/null)"
  sleep 0.1
  now=$(beat_mtime "$BEAT_HOME/state/.last-watcher-beat")
  if [ "$now" != "$last" ]; then
    seen=$((seen + 1))
    last=$now
  fi
  i=$((i + 1))
done
[ "$seen" -ge 3 ] \
  || fail "the beacon advanced only $seen time(s) in 20 seconds while publication was stalled"
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
pass "a stalled publication does not delay the watcher liveness beacon"

RESTART_HOME="$TMP_ROOT/restart-home"
mkdir -p "$RESTART_HOME/state" "$RESTART_HOME/data" "$RESTART_HOME/config" \
  "$RESTART_HOME/projects/task"
printf '# Seeded Firstmate home\n' > "$RESTART_HOME/AGENTS.md"
printf 'restart\n' > "$RESTART_HOME/.fm-secondmate-home"
fm_git_init_commit "$RESTART_HOME/projects/task"
cat > "$RESTART_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] restart-task - Preserve publication single flight (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$RESTART_HOME/state/restart-task.meta" \
  "window=fmtest:fm-restart-task" \
  "worktree=$RESTART_HOME/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.restart123456"
# This is readiness setup, not a startup latency assertion. The arm contract
# allows 10s (30s on MSYS) before declaring startup failed; give the real watcher
# that full cold-start allowance, while still stopping immediately if it exits.
wait_for_restart_beacon() {
  local deadline=$((SECONDS + 30))
  while [ ! -e "$RESTART_HOME/state/.last-watcher-beat" ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || return 1
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}
RESTART_LOCK_MARKER="$TMP_ROOT/restart-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  while :; do sleep 1; done
' _ "$ROOT" "$RESTART_HOME" "$RESTART_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$RESTART_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_LOCK_MARKER" ] || fail "could not hold the publication lock for restart coverage"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/restart-watch-one.out" 2> "$TMP_ROOT/restart-watch-one.err" &
WATCH_PID=$!
wait_for_restart_beacon \
  || fail "the first restart watcher did not begin polling: $(cat "$TMP_ROOT/restart-watch-one.err")"
printf 'needs-decision [key=restart-gate]: restart the watcher\n' \
  > "$RESTART_HOME/state/restart-task.status"
restart_signal_deadline=$((SECONDS + 30))
while kill -0 "$WATCH_PID" 2>/dev/null && [ "$SECONDS" -lt "$restart_signal_deadline" ]; do
  sleep 0.05
done
kill -0 "$WATCH_PID" 2>/dev/null \
  && fail "the first restart watcher did not surface its actionable signal: $(cat "$TMP_ROOT/restart-watch-one.err")"
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
rm -f "$RESTART_HOME/state/.last-watcher-beat"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/restart-watch-two.out" 2> "$TMP_ROOT/restart-watch-two.err" &
WATCH_PID=$!
wait_for_restart_beacon \
  || fail "the replacement restart watcher did not begin polling: $(cat "$TMP_ROOT/restart-watch-two.err")"
sleep 4
[ ! -s "$RESTART_HOME/state/.home-summary-refresh.log" ] \
  || fail "watcher restart queued refreshes behind a live publication lock: $(cat "$RESTART_HOME/state/.home-summary-refresh.log")"
if ! kill -0 "$WATCH_PID" 2>/dev/null; then
  wait "$WATCH_PID" >/dev/null 2>&1 || true
  rm -f "$RESTART_HOME/state/.last-watcher-beat"
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
    FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$WATCH" > "$TMP_ROOT/restart-watch-three.out" 2> "$TMP_ROOT/restart-watch-three.err" &
  WATCH_PID=$!
  wait_for_restart_beacon \
    || fail "the recovery replacement watcher did not begin polling: $(cat "$TMP_ROOT/restart-watch-three.err")"
fi
# The short watcher deadline above is a contention guard, not a publication
# budget. Stop its competing detached trigger before the direct stale-owner
# recovery check so that trigger cannot win and time out mid-production.
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
kill -KILL "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_HOME_SUMMARY_IF_IDLE=1 "$WRITER" --best-effort \
  || fail "stale-lock recovery changed the best-effort caller result"
i=0
while [ ! -e "$RESTART_HOME/state/home-summary.json" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_HOME/state/home-summary.json" ] \
  || fail "a dead publication lock wedged publication"
pass "publication remains single-flight across watcher restart"

# A publication that keeps failing is deliberately non-fatal to its caller, so
# the only way an operator learns about it is a session start saying so. Seed
# the home-local failure record a real failing home would have, and require the
# check a session start already runs to name it - then go quiet once the ledger
# is published again.
REPORT_HOME="$TMP_ROOT/report-home"
mkdir -p "$REPORT_HOME/state" "$REPORT_HOME/data" "$REPORT_HOME/config" \
  "$REPORT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$REPORT_HOME/AGENTS.md"
printf 'report\n' > "$REPORT_HOME/.fm-secondmate-home"
cat > "$REPORT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
cat > "$REPORT_HOME/state/.home-summary-refresh.log" <<'EOF'
[2026-08-28T09:58:00Z] refresh exceeded its 60-second deadline
[2026-08-28T09:59:00Z] refresh exceeded its 60-second deadline
EOF
run_bootstrap_detect() {
  local threshold=${2:-2}
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
    FM_HOME_SUMMARY_FAILURE_REPORT="$threshold" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

COMPAT_HOME="$TMP_ROOT/compat-home"
mkdir -p "$COMPAT_HOME/state" "$COMPAT_HOME/data" "$COMPAT_HOME/config" \
  "$COMPAT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$COMPAT_HOME/AGENTS.md"
printf 'compat\n' > "$COMPAT_HOME/.fm-secondmate-home"
cat > "$COMPAT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COMPAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "could not seed the compatibility ledger"
cat > "$COMPAT_HOME/state/.home-summary-refresh.log" <<'EOF'
[2026-08-28T09:58:00Z] historical failure before publication
[2026-08-28T09:59:00Z] historical failure before publication
[2026-08-28T10:01:00Z] first failure after publication
EOF
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
case "$compat_out" in
  *HOME_SUMMARY:*)
    fail "historical failures satisfied the current publication threshold: $compat_out"
    ;;
esac
printf '[2026-08-28T10:02:00Z] second failure after publication\n' \
  >> "$COMPAT_HOME/state/.home-summary-refresh.log"
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
printf '%s\n' "$compat_out" | grep -F '2 failed attempt(s)' >/dev/null \
  || fail "current publication failures did not satisfy the report threshold: $compat_out"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COMPAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  "$WRITER" || fail "could not republish the compatibility ledger"
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
case "$compat_out" in
  *HOME_SUMMARY:*)
    fail "republishing did not scope retained failure history: $compat_out"
    ;;
esac
pass "bootstrap scopes retained failures to the current publication"

# A timed-out attempt can finish recording after a newer ledger is published.
# Its record must retain the attempt's ordering rather than look like a failure
# of the newer publication and keep the session-start diagnostic active.
ORDER_HOME="$TMP_ROOT/order-home"
ORDER_DATE_BIN="$TMP_ROOT/order-date-bin"
mkdir -p "$ORDER_HOME/state" "$ORDER_HOME/data" "$ORDER_HOME/config" \
  "$ORDER_HOME/projects" "$ORDER_DATE_BIN"
printf '# Seeded Firstmate home\n' > "$ORDER_HOME/AGENTS.md"
printf 'order\n' > "$ORDER_HOME/.fm-secondmate-home"
cat > "$ORDER_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
REAL_DATE=$(command -v date)
cat > "$ORDER_DATE_BIN/date" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = -u ] && [ "$2" = +%Y-%m-%dT%H:%M:%SZ ]; then
  python3 - "$FM_TEST_ORDER_START" "$FM_TEST_ORDER_EARLY" "$FM_TEST_ORDER_LATE" <<'PY'
import sys
import time

started = float(sys.argv[1])
print(sys.argv[2] if time.time() - started < 1 else sys.argv[3])
PY
  exit 0
fi
exec "$FM_TEST_REAL_DATE" "$@"
SH
chmod +x "$ORDER_DATE_BIN/date"
ORDER_LOCK_MARKER="$TMP_ROOT/order-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ORDER_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$ORDER_HOME" "$ORDER_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$ORDER_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$ORDER_LOCK_MARKER" ] || fail "could not hold the publication lock for ordering coverage"
order_started=$(python3 -c 'import time; print(time.time())')
PATH="$ORDER_DATE_BIN:$FAKEBIN:$PATH" FM_TEST_REAL_DATE="$REAL_DATE" \
  FM_TEST_ORDER_START="$order_started" FM_TEST_ORDER_EARLY="$NOW_ONE" \
  FM_TEST_ORDER_LATE="$NOW_THREE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ORDER_HOME" FM_HOME_SUMMARY_TIMEOUT=2 \
  "$WRITER" --best-effort \
  || fail "ordered timeout changed the best-effort caller result"
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ORDER_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$WRITER" || fail "could not publish after the ordered timeout"
order_out=$(run_bootstrap_detect "$ORDER_HOME" 1)
case "$order_out" in
  *HOME_SUMMARY:*)
    fail "a pre-publication attempt was reported after the newer ledger: $order_out"
    ;;
esac
pass "failure records preserve refresh attempt ordering"

report_out=$(run_bootstrap_detect "$REPORT_HOME")
printf '%s\n' "$report_out" \
  | grep -F 'HOME_SUMMARY: this home has never published state/home-summary.json' \
    >/dev/null \
  || fail "a home that never published its ledger was reported as silent: $report_out"
printf '%s\n' "$report_out" \
  | grep -F '2 failed attempt(s)' >/dev/null \
  || fail "the publication report omitted the recorded failure count: $report_out"
printf '%s\n' "$report_out" \
  | grep -F 'refresh exceeded its 60-second deadline' >/dev/null \
  || fail "the publication report omitted the recorded reason: $report_out"

PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REPORT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  "$WRITER" || fail "could not publish the ledger that clears the report"
report_out=$(run_bootstrap_detect "$REPORT_HOME")
case "$report_out" in
  *HOME_SUMMARY:*)
    fail "a published ledger still reported stale publication failures: $report_out"
    ;;
esac
pass "repeated publication failure is reported at session start until it clears"

# --- detached triggers, coalescing, and escalation of a repeating failure -----
#
# Session start, spawn, and teardown publish only as a side effect, so they run
# the refresh with --detach and never wait for it. A live incident showed what
# waiting costs: the refresh needed longer than its own deadline, so every
# session start burned the full deadline on a call that could not succeed, and
# 425 identical failures were recorded without anyone being told.

new_bare_home() {  # <name> -> prints the home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '# Seeded Firstmate home\n' > "$home/AGENTS.md"
  printf '%s\n' "$1" > "$home/.fm-secondmate-home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

hold_refresh_lock() {  # <home> <seconds>
  local home=$1 marker="$1/state/.test-lock-held"
  rm -f "$marker"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
    : > "$3"
    sleep "$4"
  ' _ "$ROOT" "$home" "$marker" "$2" &
  LOCK_HOLDER_PID=$!
  fm_test_wait_until 20 test -e "$marker" || fail "could not hold the refresh lock for $home"
}

release_refresh_lock() {
  kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
  wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
  LOCK_HOLDER_PID=
}

wake_rows() {  # <home>
  awk -F '\t' '$3 == "check" && $4 == "home-summary-refresh"' "$1/state/.wake-queue" 2>/dev/null
}

wake_row_count() {  # <home>
  wake_rows "$1" | wc -l | tr -d '[:space:]'
}

# A detached trigger must return at once even while a refresh is in flight, and
# must leave no failure behind: a blocking caller would wait out the deadline
# below (30 seconds) and log a failure for work it never needed to wait for.
DETACH_HOME=$(new_bare_home detach-home)
hold_refresh_lock "$DETACH_HOME" 120
started=$(date +%s)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$DETACH_HOME" \
  FM_HOME_SUMMARY_TIMEOUT=30 "$WRITER" --detach \
  || fail "a detached trigger changed its caller's result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 10 ] || fail "a detached trigger waited $elapsed seconds on an in-flight refresh"
fm_test_wait_until 60 test -e "$DETACH_HOME/state/.home-summary-refresh.pending" \
  || fail "a trigger that found a refresh in flight left no marker for it"
sleep 2
[ ! -s "$DETACH_HOME/state/.home-summary-refresh.log" ] \
  || fail "a skipped trigger was recorded as a failure: $(cat "$DETACH_HOME/state/.home-summary-refresh.log")"
release_refresh_lock
pass "a detached trigger returns at once and records no failure while a refresh is in flight"

# With the lock free, the same detached trigger publishes and clears its marker.
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$DETACH_HOME" \
  "$WRITER" --detach || fail "a detached trigger on an idle home failed"
fm_test_wait_until 120 jq -e '.schema == "fm-secondmate-home-summary.v1"' \
  "$DETACH_HOME/state/home-summary.json" \
  || fail "a detached trigger on an idle home never published"
[ ! -e "$DETACH_HOME/state/.home-summary-refresh.pending" ] \
  || fail "a published refresh left its trigger marker behind"
pass "a detached trigger on an idle home publishes and clears its marker"

# Triggers that arrive during a refresh coalesce into exactly one more refresh:
# none is lost (the published summary is never older than the last trigger) and
# none piles up (three triggers do not become three more runs).
COALESCE_HOME=$(new_bare_home coalesce-home)
printf '## In flight\n- [ ] co-task - Coalesce triggers (repo: firstmate) (kind: ship) (since 2026-08-28)\n\n## Queued\n\n## Done\n' \
  > "$COALESCE_HOME/data/backlog.md"
mkdir -p "$COALESCE_HOME/projects/task"
fm_git_init_commit "$COALESCE_HOME/projects/task"
fm_write_meta "$COALESCE_HOME/state/co-task.meta" \
  "window=fmtest:fm-co-task" "worktree=$COALESCE_HOME/projects/task" \
  "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes" "spawn_gen=fm.coalesce1234"
co_busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$COALESCE_HOME/state" co-task)
"$ROOT/bin/fm-busy-event.sh" apply "$COALESCE_HOME/state" co-task idle \
  --gen "$co_busy_gen" --source claude-hook --event stop
CO_COUNT="$TMP_ROOT/coalesce-nm-count"
: > "$CO_COUNT"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COALESCE_HOME" \
  FM_TEST_NM_COUNT="$CO_COUNT" "$WRITER" || fail "the coalescing baseline refresh failed"
per_run=$(wc -l < "$CO_COUNT" | tr -d '[:space:]')
[ "$per_run" -gt 0 ] || fail "the producer never consulted the controlled current-state reader"
: > "$CO_COUNT"
CO_HOLD="$TMP_ROOT/coalesce-hold"
: > "$CO_HOLD"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COALESCE_HOME" \
  FM_TEST_NM_COUNT="$CO_COUNT" FM_TEST_NM_HOLD="$CO_HOLD" \
  "$WRITER" --best-effort &
SLOW_WRITER_PID=$!
fm_test_wait_until 60 test -e "$CO_HOLD.entered" || fail "the in-flight refresh never reached its held read"
for _ in 1 2 3; do
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COALESCE_HOME" \
    FM_TEST_NM_COUNT="$CO_COUNT" FM_TEST_NM_HOLD="$CO_HOLD" \
    "$WRITER" --detach || fail "a trigger during a refresh failed"
done
fm_test_wait_until 60 test -e "$COALESCE_HOME/state/.home-summary-refresh.pending" \
  || fail "triggers during a refresh left no marker"
sleep 2
rm -f "$CO_HOLD"
wait "$SLOW_WRITER_PID" || fail "the in-flight refresh failed"
SLOW_WRITER_PID=
sleep 1
[ "$(wc -l < "$CO_COUNT" | tr -d '[:space:]')" -eq $((per_run * 2)) ] \
  || fail "three triggers during a refresh made $(wc -l < "$CO_COUNT" | tr -d '[:space:]') producer reads, expected exactly one more run ($((per_run * 2)))"
[ ! -e "$COALESCE_HOME/state/.home-summary-refresh.pending" ] \
  || fail "the follow-up refresh left the trigger marker behind"
pass "triggers during a refresh coalesce into exactly one follow-up refresh"

SERIALBIN="$TMP_ROOT/serialbin"
mkdir -p "$SERIALBIN"
cat > "$SERIALBIN/jq" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_VALIDATE_DIR:-}" ]; then
  for arg in "$@"; do
    case "$arg" in
      */.home-summary.json.*)
        run=$(cat "$FM_TEST_VALIDATE_DIR/count" 2>/dev/null || printf 0)
        run=$((run + 1))
        printf '%s\n' "$run" > "$FM_TEST_VALIDATE_DIR/count"
        : > "$FM_TEST_VALIDATE_DIR/entered.$run"
        while [ ! -e "$FM_TEST_VALIDATE_DIR/release.$run" ]; do sleep 0.05; done
        break
        ;;
    esac
  done
fi
exec "$FM_TEST_REAL_JQ" "$@"
SH
cat > "$SERIALBIN/env" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_WORKER_ENTERED:-}" ]; then
  for arg in "$@"; do
    [ "$arg" != --_worker ] || : > "$FM_TEST_WORKER_ENTERED"
  done
fi
exec "$FM_TEST_REAL_ENV" "$@"
SH
chmod +x "$SERIALBIN/jq" "$SERIALBIN/env"

DRAIN_HOME=$(new_bare_home drain-home)
VALIDATE_DIR="$TMP_ROOT/drain-validation"
mkdir -p "$VALIDATE_DIR"
PATH="$SERIALBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_TEST_REAL_ENV="$REAL_ENV" FM_TEST_VALIDATE_DIR="$VALIDATE_DIR" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$DRAIN_HOME" "$WRITER" --best-effort &
SLOW_WRITER_PID=$!
for run in 1 2 3 4 5 6; do
  fm_test_wait_until 120 test -e "$VALIDATE_DIR/entered.$run" \
    || fail "pending triggers stopped draining before successful refresh $run"
  if [ "$run" -lt 6 ]; then
    printf '## In flight\n\n## Queued\n- [ ] pending-%s - Latest pending trigger (repo: firstmate) (kind: ship)\n\n## Done\n' "$run" \
      > "$DRAIN_HOME/data/backlog.md"
    PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$DRAIN_HOME" \
      "$WRITER" --detach || fail "pending trigger $run changed its caller result"
    fm_test_wait_until 60 test -e "$DRAIN_HOME/state/.home-summary-refresh.pending" \
      || fail "pending trigger $run left no marker"
  fi
  : > "$VALIDATE_DIR/release.$run"
done
wait "$SLOW_WRITER_PID" || fail "draining successful pending refreshes failed"
SLOW_WRITER_PID=
[ "$(cat "$VALIDATE_DIR/count")" -eq 6 ] \
  || fail "successful pending refreshes did not drain through six attempts"
[ ! -e "$DRAIN_HOME/state/.home-summary-refresh.pending" ] \
  || fail "successful pending refreshes left an unconsumed trigger"
jq -e 'any(.queued[]; .id == "pending-5")' "$DRAIN_HOME/state/home-summary.json" >/dev/null \
  || fail "the final successful refresh did not cover the last pending trigger"
pass "successful pending refreshes drain beyond four attempts"

SERIAL_HOME=$(new_bare_home serial-home)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SERIAL_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "could not seed the serialized outcome ledger"
for attempt in 1 2; do
  PATH="$FAILBIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SERIAL_HOME" \
    "$WRITER" --best-effort || fail "serialization seed failure $attempt changed its caller result"
done
SERIAL_WAKE_MARKER="$TMP_ROOT/serial-wake-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SERIAL_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.wake-queue.lock"
  : > "$3"
  sleep 120
' _ "$ROOT" "$SERIAL_HOME" "$SERIAL_WAKE_MARKER" &
LOCK_HOLDER_PID=$!
fm_test_wait_until 60 test -e "$SERIAL_WAKE_MARKER" \
  || fail "could not hold the wake lock for serialized timeout accounting"
PATH="$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SERIAL_HOME" FM_HOME_SUMMARY_TIMEOUT=1 \
  "$WRITER" --best-effort &
SLOW_WRITER_PID=$!
fm_test_wait_until 100 grep -Fx count=3 "$SERIAL_HOME/state/.home-summary-refresh.streak" \
  || fail "the timed-out attempt did not reach serialized wake accounting"
SUCCESS_ENTERED="$TMP_ROOT/serial-success-entered"
PATH="$SERIALBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_TEST_REAL_ENV="$REAL_ENV" FM_TEST_WORKER_ENTERED="$SUCCESS_ENTERED" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SERIAL_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" "$WRITER" &
SUCCESS_WRITER_PID=$!
fm_test_wait_until 60 test -e "$SUCCESS_ENTERED" \
  || fail "the succeeding refresh never started during timeout accounting"
sleep 1
jq -e --arg now "$NOW_ONE" '.generated == $now' "$SERIAL_HOME/state/home-summary.json" >/dev/null \
  || fail "a newer success published before the prior timeout finished wake accounting"
[ "$(cat "$SERIAL_HOME/state/.home-summary-refresh.lock/pid")" = "$SLOW_WRITER_PID" ] \
  || fail "the timeout owner released refresh ownership before its wake accounting"
[ "$(wake_row_count "$SERIAL_HOME")" = 0 ] \
  || fail "the blocked timeout wake bypassed the wake queue lock"
release_refresh_lock
wait "$SLOW_WRITER_PID" || fail "serialized timeout changed its best-effort result"
SLOW_WRITER_PID=
wait "$SUCCESS_WRITER_PID" || fail "the succeeding serialized refresh failed"
SUCCESS_WRITER_PID=
jq -e --arg now "$NOW_TWO" '.generated == $now' "$SERIAL_HOME/state/home-summary.json" >/dev/null \
  || fail "the succeeding refresh did not publish after timeout accounting"
[ ! -e "$SERIAL_HOME/state/.home-summary-refresh.streak" ] \
  || fail "older timeout accounting restored a failure streak after the newer success"
[ "$(wake_row_count "$SERIAL_HOME")" = 1 ] \
  || fail "the serialized third failure did not publish exactly one wake"
pass "timeout wake accounting finishes before a newer success publishes and resets the streak"

# A failure that repeats must become a wake, not a logged line. Use a real
# publication failure after acquisition rather than making host-dependent cold
# startup fit a tiny deadline; deadline behavior is covered independently above.
run_owned_publication_failure() {  # <home> <expected-streak-count>
  local home=$1 count=$2 ledger="$1/state/home-summary.json"
  if [ -f "$ledger" ]; then
    mv "$ledger" "$home/state/.test-ledger-before-failure"
  fi
  mkdir -p "$ledger"
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$WRITER" --best-effort \
    || fail "failed attempt $count changed the best-effort caller result"
  grep -qx "count=$count" "$home/state/.home-summary-refresh.streak" \
    || fail "attempt $count did not account for its acquired publication failure"
  assert_grep "atomic ledger replacement failed: destination is a directory:" \
    "$home/state/.home-summary-refresh.log" \
    "attempt $count did not reach the real publication boundary"
}
ESC_HOME=$(new_bare_home escalate-home)
for attempt in 1 2; do
  run_owned_publication_failure "$ESC_HOME" "$attempt"
done
[ -z "$(wake_rows "$ESC_HOME")" ] \
  || fail "two failures woke firstmate before the threshold: $(wake_rows "$ESC_HOME")"
run_owned_publication_failure "$ESC_HOME" 3
[ "$(wake_row_count "$ESC_HOME")" = 1 ] \
  || fail "three consecutive publication failures did not raise exactly one wake: $(wake_rows "$ESC_HOME")"
wake_row=$(wake_rows "$ESC_HOME")
case "$wake_row" in
  *'3 consecutive refresh failures'*'atomic ledger replacement failed: destination is a directory:'*'ran '[0-9]*s*) ;;
  *) fail "the wake omitted the count, the reason, or the measured duration: $wake_row" ;;
esac
for attempt in 4 5 6; do
  run_owned_publication_failure "$ESC_HOME" "$attempt"
done
[ "$(wake_row_count "$ESC_HOME")" = 1 ] \
  || fail "an unchanged repeating failure raised another wake: $(wake_rows "$ESC_HOME")"
pass "three consecutive publication failures raise one wake that names the reason and duration, and no more"

# A real change of reason is new information and wakes again; the same reason
# does not. Replace the publication failure with a producer that fails outright.
PATH="$FAILBIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ESC_HOME" \
  "$WRITER" --best-effort || fail "a producer failure changed the caller result"
[ "$(wake_row_count "$ESC_HOME")" = 2 ] \
  || fail "a changed failure reason did not raise a new wake: $(wake_rows "$ESC_HOME")"
wake_rows "$ESC_HOME" | tail -1 | grep -F 'summary producer' >/dev/null \
  || fail "the second wake did not name the new reason: $(wake_rows "$ESC_HOME" | tail -1)"
PATH="$FAILBIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ESC_HOME" \
  "$WRITER" --best-effort || fail "a repeated producer failure changed the caller result"
[ "$(wake_row_count "$ESC_HOME")" = 2 ] \
  || fail "a repeated producer failure raised another wake"
pass "a changed failure reason raises a new wake and a repeated one does not"

# The first success ends the streak, so the next run of failures is news again.
rmdir "$ESC_HOME/state/home-summary.json"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ESC_HOME" \
  "$WRITER" || fail "the recovering refresh failed"
[ ! -e "$ESC_HOME/state/.home-summary-refresh.streak" ] \
  || fail "a successful publication left its failure streak behind"
for attempt in 1 2 3; do
  run_owned_publication_failure "$ESC_HOME" "$attempt"
done
[ "$(wake_row_count "$ESC_HOME")" = 3 ] \
  || fail "failures after a recovery were not reported as a new streak: $(wake_rows "$ESC_HOME")"
pass "a successful publication ends the streak so a later streak wakes again"

# --- publication cost on a home whose status history is large ------------------
#
# The recorded incident: a home with 28 status logs (5.4 MB, most lines opening
# or closing a decision) needed 117 seconds to publish against a 60-second
# deadline, because the producer folded every task's whole stream twice from
# line 1 at several milliseconds a line. The fold now starts from the checkpoint
# the wake drain keeps beside each log, so a refresh costs what was appended
# since, not what the log has ever held. Assert that through the bytes the folds
# read (a timing assertion would pass or fail with the host's load).
BIG_HOME=$(new_bare_home big-history-home)
printf '## In flight\n' > "$BIG_HOME/data/backlog.md"
for big in 1 2; do
  printf -- '- [ ] big-task-%s - Publish from a large history (repo: firstmate) (kind: ship) (since 2026-08-28)\n' "$big" \
    >> "$BIG_HOME/data/backlog.md"
  mkdir -p "$BIG_HOME/projects/task$big"
  fm_git_init_commit "$BIG_HOME/projects/task$big"
  fm_write_meta "$BIG_HOME/state/big-task-$big.meta" \
    "window=fmtest:fm-big-task-$big" "worktree=$BIG_HOME/projects/task$big" \
    "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes" "spawn_gen=fm.bighist$big"
  big_busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$BIG_HOME/state" "big-task-$big")
  "$ROOT/bin/fm-busy-event.sh" apply "$BIG_HOME/state" "big-task-$big" idle \
    --gen "$big_busy_gen" --source claude-hook --event stop
  python3 - "$BIG_HOME/state/big-task-$big.status" "$big" <<'PY'
import sys
path, task = sys.argv[1], sys.argv[2]
note = ("the crewmate ran validation and reported checks on the branch after review " * 6)[:420]
with open(path, "w") as handle:
    for i in range(150):
        handle.write(f"needs-decision [key=gate-{i}]: question {i} {note}\n")
        handle.write(f"resolved [key=gate-{i}]: answered {i} {note}\n")
        handle.write(f"done: step {i} {note}\n")
    handle.write(f"needs-decision [key=still-open-{task}]: the question nobody answered\n")
PY
done
printf '\n## Queued\n\n## Done\n' >> "$BIG_HOME/data/backlog.md"
# The drain keeps these checkpoints current at every session start and wake.
for big in 1 2; do
  bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions_incremental "$2" >/dev/null' \
    _ "$ROOT" "$BIG_HOME/state/big-task-$big.status" || fail "could not seed the checkpoint for big-task-$big"
  [ -s "$BIG_HOME/state/.big-task-$big.open-decisions-cursor" ] \
    || fail "the drain's fold left no checkpoint for big-task-$big"
  printf 'working: appended after the checkpoint\nneeds-decision [key=late-%s]: opened after the checkpoint\n' "$big" \
    >> "$BIG_HOME/state/big-task-$big.status"
done
BIG_SPANS="$TMP_ROOT/big-spans.log"
BIG_READER="$TMP_ROOT/big-span-reader"
cat > "$BIG_READER" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$2" "$3" >> "${FM_TEST_BIG_SPANS:?}"
LC_ALL=C tail -c +"$(($2 + 1))" "$1" | LC_ALL=C head -c "$3"
SH
chmod +x "$BIG_READER"
: > "$BIG_SPANS"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BIG_HOME" \
  FM_STATUS_SPAN_READER="$BIG_READER" FM_TEST_BIG_SPANS="$BIG_SPANS" \
  "$WRITER" || fail "a large-history home did not publish inside the default deadline"
jq -e --arg home "$BIG_HOME" '.schema == "fm-secondmate-home-summary.v1" and .home == $home' \
  "$BIG_HOME/state/home-summary.json" >/dev/null || fail "the large-history ledger is not a valid summary"
big_size=$(wc -c < "$BIG_HOME/state/big-task-1.status" | tr -d '[:space:]')
[ "$(wc -l < "$BIG_SPANS" | tr -d '[:space:]')" -ge 2 ] \
  || fail "the producer never folded from a checkpoint: $(cat "$BIG_SPANS")"
big_longest=$(awk '{ if ($2 > max) max = $2 } END { print max + 0 }' "$BIG_SPANS")
[ "$big_longest" -lt 4096 ] \
  || fail "a fold re-read $big_longest bytes of a $big_size-byte log instead of only what was appended"
for big in 1 2; do
  expected=$(printf 'late-%s\nstill-open-%s\n' "$big" "$big")
  published=$(jq -r --arg id "big-task-$big" '.decisions_open[] | select(.id == $id) | .key' \
    "$BIG_HOME/state/home-summary.json" | sort)
  [ "$expected" = "$published" ] \
    || fail "the checkpoint-seeded summary of big-task-$big lost or added decisions: published [$published], expected [$expected]"
done
pass "publication on a large history reads only what was appended and retains decisions from before and after the checkpoint"
