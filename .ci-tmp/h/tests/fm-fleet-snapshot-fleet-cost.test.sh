#!/usr/bin/env bash
# Behavior test for the cost of the home-summary producer at the current fleet size.
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
