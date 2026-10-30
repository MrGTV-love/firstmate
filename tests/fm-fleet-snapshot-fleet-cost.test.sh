#!/usr/bin/env bash
# Behavior tests for fleet snapshot cost and progress-owned supplemental reads.
# Also covers 5x source-work dilation, silent-reader cleanup and unknown evidence.
#
# The producer (fm-fleet-snapshot.sh --secondmate-home-summary) must finish well inside
# the refresh deadline while the host is busy. On a loaded host its cost is the number of
# short-lived processes it starts: the same refresh that took seconds on an idle host
# overran its 60-second deadline once the fleet was running. This runs a fixture fleet of
# 27 tasks with 53 contribution records (the size at which the refresh overran) and bounds
# the number of jq processes it starts, which a wall-clock bound could not do reliably on a
# busy CI host. A per-task or per-record jq shows up here as hundreds of starts, so the
# bound fails for a producer that spends a dozen processes on every task.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-cost)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TASKS=27
RECORDS=53
# This fleet starts about 520 jq processes in the per-task design and about 115 in the
# single-pass design.
JQ_START_BOUND=200

HOME_DIR=$TMP_ROOT/home
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
REAL_JQ=$(command -v jq)
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/config" "$HOME_DIR/wt"

JQ_STARTS=$TMP_ROOT/jq-starts
: > "$JQ_STARTS"
cat > "$FAKEBIN/jq" <<SH
#!/usr/bin/env bash
echo x >> "$JQ_STARTS"
exec "$REAL_JQ" "\$@"
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) printf 'codex\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/jq" "$FAKEBIN/no-mistakes" "$FAKEBIN/tmux"

NOW=2026-10-08T12:00:00Z
backlog="## In flight"$'\n'
i=0
while [ "$i" -lt "$TASKS" ]; do
  i=$((i + 1))
  id=$(printf 'task-%02d' "$i")
  kind=ship
  [ $((i % 4)) -ne 0 ] || kind=scout
  backlog="$backlog- [ ] $id - Task $i (repo: alpha) (kind: $kind) (since 2026-10-01)"$'\n'
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$HOME_DIR/wt" \
    "project=alpha" \
    "harness=claude" \
    "kind=$kind" \
    "mode=ship" \
    "yolo=off"
  n=0
  : > "$HOME_DIR/state/$id.status"
  while [ "$n" -lt 40 ]; do
    n=$((n + 1))
    printf 'working [at=%s]: step %s of %s\n' "$((1791000000 + n))" "$n" "$id" >> "$HOME_DIR/state/$id.status"
  done
done
printf '%s\n' "$backlog" > "$HOME_DIR/data/backlog.md"

i=0
while [ "$i" -lt "$RECORDS" ]; do
  i=$((i + 1))
  id=$(printf 'contrib-%02d' "$i")
  mkdir -p "$HOME_DIR/data/$id"
  jq -n --arg task "$id" --arg url "https://github.com/o/r/pull/$i" --arg at "$NOW" '
    {schema:"fm-contributions.v1",task:$task,records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:"0123456789abcdef0123456789abcdef01234567",state:"merged",draft:false,
        mergeable:"unknown",review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$HOME_DIR/data/$id/contributions.json"
done

OUT=$TMP_ROOT/summary.json
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_SNAPSHOT_NOW="$NOW" FM_CONTRIBUTIONS_NOW="$NOW" \
  "$SNAPSHOT" --secondmate-home-summary > "$OUT" 2> "$TMP_ROOT/summary.err" \
  || fail "the producer failed: $(cat "$TMP_ROOT/summary.err")"
STARTS=$(wc -l < "$JQ_STARTS" | tr -d ' ')

jq -e --argjson tasks "$TASKS" --argjson records "$RECORDS" '
  .schema == "fm-secondmate-home-summary.v1"
  and .counts.endpoints == $tasks
  and .contributions.known == $records' "$OUT" >/dev/null \
  || fail "the fixture fleet did not produce the full summary: $(head -c 600 "$OUT")"
[ "$STARTS" -le "$JQ_START_BOUND" ] \
  || fail "a $TASKS-task fleet started $STARTS jq processes; the bound is $JQ_START_BOUND"
pass "the producer summarizes a $TASKS-task fleet with $STARTS jq starts (bound $JQ_START_BOUND)"

# The same bounded reads must survive a 5x host delay while they report progress.
# A silent source must still be stopped, with its evidence explicitly unknown.
READ_HOME=$TMP_ROOT/read-home
READ_BIN=$(fm_fakebin "$READ_HOME")
mkdir -p "$READ_HOME/state" "$READ_HOME/data" "$READ_HOME/config" "$READ_HOME/projects"
fm_write_meta "$READ_HOME/state/mate.meta" \
  'kind=secondmate' 'harness=codex' 'backend=tmux' 'window=firstmate:fm-mate'
printf 'working [key=review]: review underway\n' > "$READ_HOME/state/mate.status"
printf -- '- mate (home: %s/missing; scope: reviews; projects: alpha; added 2026-10-01)\n' \
  "$READ_HOME" > "$READ_HOME/data/secondmates.md"

cat > "$READ_BIN/read-delay" <<'SH'
#!/usr/bin/env bash
source_name=$1
if [ "${FM_TEST_HUNG_SOURCE:-}" = "$source_name" ]; then
  printf '%s\n' "$$" > "$FM_TEST_HUNG_PID"
  exec python3 -c 'import signal; signal.pause()'
fi
n=0
while [ "$n" -lt "${FM_TEST_DILATION:-1}" ]; do
  sleep 0.6
  printf 'source progress\n' >&2
  n=$((n + 1))
done
SH
cat > "$READ_BIN/head" <<SH
#!/usr/bin/env bash
case "\$*" in
  *secondmates.md) "$READ_BIN/read-delay" registry ;;
esac
exec "$(command -v head)" "\$@"
SH
cat > "$READ_BIN/tail" <<SH
#!/usr/bin/env bash
case "\$*" in
  '-c 65536 '*mate.status) "$READ_BIN/read-delay" activities ;;
esac
exec "$(command -v tail)" "\$@"
SH
cat > "$READ_BIN/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) printf 'fm-mate\n' ;;
  display-message) printf 'codex\n' ;;
  capture-pane)
    "$READ_BIN/read-delay" terminal
    printf 'review underway\n> \n'
    ;;
esac
SH
cat > "$READ_BIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
READ_JQ_STARTS=$TMP_ROOT/read-jq-starts
cat > "$READ_BIN/jq" <<SH
#!/usr/bin/env bash
printf 'x\\n' >> "$READ_JQ_STARTS"
exec "$REAL_JQ" "\$@"
SH
READ_PY_STARTS=$TMP_ROOT/read-python-starts
REAL_PYTHON=$(command -v python3)
cat > "$READ_BIN/python3" <<SH
#!/usr/bin/env bash
case "\$*" in *'fm-duration.py keep-going '*) printf '%s\\n' "\$*" >> "$READ_PY_STARTS" ;; esac
exec "$REAL_PYTHON" "\$@"
SH
chmod +x "$READ_BIN/"*

run_read_snapshot() {  # <dilation> [<hung-source>]
  : > "$READ_JQ_STARTS"
  : > "$READ_PY_STARTS"
  PATH="$READ_BIN:$PATH" FM_HOME="$READ_HOME" FM_DURATION_FILE=off \
    FM_TEST_DILATION=$1 FM_TEST_HUNG_SOURCE=${2:-} FM_TEST_HUNG_PID="$TMP_ROOT/hung.pid" \
    FM_SNAPSHOT_REGISTRY_TIMEOUT=2 FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=2 \
    FM_SNAPSHOT_TERMINAL_TIMEOUT=2 \
    "$SNAPSHOT" --json > "$TMP_ROOT/reads.json" 2> "$TMP_ROOT/reads.err" \
    || fail "snapshot failed: $(cat "$TMP_ROOT/reads.err")"
}

for dilation in 1 5; do
  run_read_snapshot "$dilation"
  jq -e '
    .secondmate_current.registry.available == true
    and .secondmate_current.registry.records[0].id == "mate"
    and (.secondmate_current.records[0] |
      .parent_event.activity_scan.available == true
      and .parent_event.open_activities[0].key == "review"
      and .terminal_evidence.captured == true
      and .terminal_evidence.event_note_seen == true)
  ' "$TMP_ROOT/reads.json" >/dev/null \
    || fail "${dilation}x source delay discarded healthy evidence: $(cat "$TMP_ROOT/reads.json")"
  read_starts=$(wc -l < "$READ_JQ_STARTS" | tr -d ' ')
  # Same one-secondmate snapshot: 48 starts before batching, 32 after. Leave
  # room for independent observations, but reject a return to per-field parsing.
  [ "$read_starts" -le 40 ] || fail "one secondmate started $read_starts jq processes (bound 40)"
  # The supplemental reads run serially, once per secondmate. A Python start
  # each (0.2-0.5 s on a loaded host) made the 15-mate snapshot twice as slow
  # as base's hard caps. With Perl present they must add no Python starts.
  py_reads=$(grep -c 'fm-secondmate-registry\|fm-parent-activities\|fm-terminal-capture' "$READ_PY_STARTS")
  if command -v perl >/dev/null 2>&1 && [ "$py_reads" -gt 0 ]; then
    fail "$py_reads supplemental reads each started a Python progress runner"
  fi
  pass "registry, parent activities and terminal evidence survive ${dilation}x source delay ($read_starts jq starts)"
done

for source_name in registry activities terminal; do
  rm -f "$TMP_ROOT/hung.pid"
  run_read_snapshot 1 "$source_name"
  [ -s "$TMP_ROOT/hung.pid" ] || fail "$source_name hang was not exercised"
  hung_pid=$(cat "$TMP_ROOT/hung.pid")
  if kill -0 "$hung_pid" 2>/dev/null; then
    kill "$hung_pid" 2>/dev/null || true
    fail "$source_name left its stalled reader alive"
  fi
  case "$source_name" in
    registry) predicate='.secondmate_current.registry | .available == false and .complete == false' ;;
    activities) predicate='.secondmate_current.records[0].parent_event.activity_scan | .available == false and .records == []' ;;
    terminal) predicate='.secondmate_current.records[0].terminal_evidence | .captured == false and .freshness == "unknown"' ;;
  esac
  jq -e "$predicate" "$TMP_ROOT/reads.json" >/dev/null \
    || fail "$source_name stall was treated as known evidence"
  jq -e '.secondmate_current.records[0].current.state == "unknown"' "$TMP_ROOT/reads.json" >/dev/null \
    || fail "$source_name stall decided a peer was dead"
  pass "$source_name silent reader is reaped and its evidence remains unknown"
done
