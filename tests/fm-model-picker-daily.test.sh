#!/usr/bin/env bash
# Behavior tests for bin/fm-model-picker-daily.sh and bin/fm-model-picker-daily-install.sh.
#
# Each case builds a scratch home and data root, runs the real runner against it with a fake
# collector, a fake budget wrapper and an injected clock (the documented FM_TEST_SEAM seams), and
# reads the wakes back through bin/fm-wake-drain.sh --queued. The fake collector rewrites the
# staged root the way the real one does (verdict UNTRUSTED first, matrix rebuilt, projection
# replaced), so a run that touched the live root instead of a staged copy would show.
# The installer runs against a fake launchctl and a scratch agent directory under a scratch HOME.
# No case reaches the network or a model.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

trap fm_test_cleanup EXIT
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-model-picker-daily)
RUNNER="$ROOT/bin/fm-model-picker-daily.sh"
INSTALL="$ROOT/bin/fm-model-picker-daily-install.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
unset FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_MODEL_PICKER_DATA FM_STATE_OVERRIDE

NOW=1800000000
HOUR=3600

stamp() { python3 -I -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' "$1"; }

sha256sum_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

sql() {  # <db> <query>
  python3 -I -c 'import sqlite3, sys; print("\n".join("|".join(str(c) for c in r) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])))' "$1" "$2"
}

tree_hash() {  # <dir>: the hash of every file under it, by path
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
}

shadow_trusts() {  # <data-root>: prints true or false, from the consumer's own guard
  python3 -I - "$ROOT/bin" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fm_model_picker import shadow
print("true" if shadow.verdict_state(sys.argv[2])[0] else "false")
PY
}

# make_fixture <data-root> <observed-epoch>: a live root whose newest observation has that time.
make_fixture() {
  local root=$1 observed=$2
  rm -rf "$root"
  mkdir -p "$root/projection" "$root/raw/rendered"
  python3 -I - "$ROOT/bin" "$root" "$(stamp "$observed")" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
from fm_model_picker import aadb
root, observed = Path(sys.argv[2]), sys.argv[3]
conn = aadb.open_db(root / "aa.sqlite")
conn.execute("INSERT INTO models (id, slug, name) VALUES (1, 'fixture-model', 'Fixture')")
conn.execute("INSERT INTO metrics (id, canonical_id, label) VALUES (1, 'fixture.metric', 'Fixture metric')")
conn.execute("INSERT INTO observations (model_id, metric_id, observed_at, value, source) VALUES (1, 1, ?, 1.0, 'embedded')", (observed,))
conn.commit()
aadb.log_dispatch(conn, mode="shadow", task_type="fixture-original")
conn.close()
PY
  printf '{"verdict": "TRUSTED", "ran_at": "%s"}\n' "$(stamp "$observed")" > "$root/verdict.json"
  printf '{"slug": "fixture-model", "as_of": "%s"}\n' "$(stamp "$observed")" > "$root/projection/fixture-model.json"
  printf '{"collected_at": "%s"}\n' "$(stamp "$observed")" > "$root/snapshot.json"
  printf 'coverage\n' > "$root/coverage.md"
  printf 'reconcile\n' > "$root/reconcile.md"
  printf 'page\n' > "$root/raw/page.html"
  printf 'rendered\n' > "$root/raw/rendered/chart.txt"
  touch -t 202601020304 "$root/raw/rendered/chart.txt"
}

install_fakes() {
  cat > "$TMP_ROOT/fake-budget.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG.budget"
[ "${1:-}" = -- ] || exit 2
shift
FAKE_BUDGET_WRAPPED=1 exec "$@"
EOF
  cat > "$TMP_ROOT/fake-collector.sh" <<'EOF'
#!/usr/bin/env bash
# The collector as the runner sees it: argv, data root and wrapper marker are logged, then the
# data root is rewritten in place and the run ends the way FAKE_EXIT says.
printf 'argv=%s\ndata=%s\nwrapped=%s\n' "$*" "$FM_MODEL_PICKER_DATA" "${FAKE_BUDGET_WRAPPED:-no}" >> "$FAKE_LOG"
if [ "${FAKE_BUDGET_WRAPPED:-}" != 1 ]; then
  echo "error: collector ran without the budget wrapper" >&2
  exit 97
fi
[ -z "${FAKE_STARTED:-}" ] || : > "$FAKE_STARTED"
[ -z "${FAKE_SLEEP:-}" ] || /bin/sleep "$FAKE_SLEEP"
now=$(python3 -I -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' "$FM_MODEL_PICKER_DAILY_NOW")
printf '{"verdict": "UNTRUSTED", "ran_at": "%s"}\n' "$now" > "$FM_MODEL_PICKER_DATA/verdict.json"
python3 -I - "$FM_MODEL_PICKER_DATA" "$now" "${FAKE_LIVE_DB:-}" <<'PY'
import shutil, sqlite3, sys
from pathlib import Path
data, now, live = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
conn = sqlite3.connect(data / "aa.sqlite")
conn.execute("DELETE FROM observations")
conn.execute("INSERT INTO observations (model_id, metric_id, observed_at, value, source) VALUES (1, 1, ?, 2.0, 'embedded')", (now,))
conn.commit()
conn.close()
for old in (data / "projection").iterdir():
    if old.is_dir():
        shutil.rmtree(old)
    else:
        old.unlink()
(data / "projection" / "rebuilt-model.json").write_text('{"slug": "rebuilt-model"}\n')
(data / "snapshot.json").write_text('{"collected_at": "' + now + '"}\n')
if live:
    other = sqlite3.connect(live)
    other.execute("INSERT INTO dispatch_log (at, mode, task_type) VALUES (?, 'shadow', 'written-during-the-run')", (now,))
    other.commit()
    other.close()
PY
[ -z "${FAKE_STDOUT:-}" ] || printf '%s\n' "$FAKE_STDOUT"
[ -z "${FAKE_STDERR:-}" ] || printf '%b' "$FAKE_STDERR" >&2
code=${FAKE_EXIT:-0}
if [ "$code" -eq 0 ]; then
  printf '{"verdict": "TRUSTED", "ran_at": "%s"}\n' "$now" > "$FM_MODEL_PICKER_DATA/verdict.json"
fi
exit "$code"
EOF
  chmod +x "$TMP_ROOT/fake-budget.sh" "$TMP_ROOT/fake-collector.sh"
}

# new_home <name>: a scratch home with a live fixture root 1 hour old at NOW; sets HOME_DIR and DATA_DIR.
new_home() {
  HOME_DIR="$TMP_ROOT/$1/home"
  DATA_DIR="$HOME_DIR/data/model-picker"
  mkdir -p "$HOME_DIR/state"
  make_fixture "$DATA_DIR" $((NOW - HOUR))
  FAKE_LOG="$TMP_ROOT/$1/fake.log"
  : > "$FAKE_LOG"
}

# run_runner <verb> [VAR=value ...]: sets CODE, OUT and ERR; NOW_AT moves the clock.
run_runner() {
  local verb=$1
  shift
  CODE=0
  env FM_HOME="$HOME_DIR" FM_TEST_SEAM=1 FM_MODEL_PICKER_DAILY_NOW="${NOW_AT:-$NOW}" \
    FM_MODEL_PICKER_DAILY_COLLECTOR="$TMP_ROOT/fake-collector.sh" FM_MODEL_PICKER_DAILY_BUDGET="$TMP_ROOT/fake-budget.sh" \
    FAKE_LOG="$FAKE_LOG" "$@" "$RUNNER" "$verb" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || CODE=$?
  OUT=$(cat "$TMP_ROOT/out")
  ERR=$(cat "$TMP_ROOT/err")
}

queued_wakes() { FM_HOME="$HOME_DIR" "$DRAIN" --queued; }
wake_count() { queued_wakes | grep -c . || true; }

test_run_chains_budget_collector_and_promotes() {
  new_home chain
  local before_state
  run_runner run FAKE_LIVE_DB="$DATA_DIR/aa.sqlite"
  expect_code 0 "$CODE" "a clean run"
  assert_contains "$(cat "$FAKE_LOG.budget")" "-- $TMP_ROOT/fake-collector.sh --sweep --stale-after-hours 24 --chartdiff --db" \
    "the collector runs through the budget wrapper with exactly the daily flags"
  assert_contains "$(cat "$FAKE_LOG")" "wrapped=1" "the collector ran inside the wrapper"
  assert_not_contains "$(cat "$FAKE_LOG")" "data=$DATA_DIR"$'\n' "the collector never runs against the live data root"
  assert_contains "$(cat "$FAKE_LOG")" "data=$DATA_DIR.daily." "the collector runs against a staged copy beside the live root"
  assert_equals 0 "$(wake_count)" "a clean run raises no wake"
  assert_contains "$(cat "$DATA_DIR/verdict.json")" TRUSTED "the good verdict is live"
  assert_equals "$(stamp "$NOW")" "$(sql "$DATA_DIR/aa.sqlite" 'SELECT MAX(observed_at) FROM observations')" "the new snapshot is live"
  assert_present "$DATA_DIR/projection/rebuilt-model.json" "the new projection is live"
  assert_absent "$DATA_DIR/projection/fixture-model.json" "a projection the run dropped is gone"
  assert_equals "fixture-original
written-during-the-run" "$(sql "$DATA_DIR/aa.sqlite" 'SELECT task_type FROM dispatch_log ORDER BY id')" \
    "dispatch_log keeps its rows, including one written while the run was under way"
  assert_equals "202601020304" "$(date -r "$DATA_DIR/raw/rendered/chart.txt" +%Y%m%d%H%M)" "a rendered capture keeps its modification time"
  assert_equals "page" "$(cat "$DATA_DIR/raw/page.html")" "the raw cache is kept"
  before_state=$(ls -A "$(dirname "$DATA_DIR")")
  assert_equals "model-picker" "$before_state" "no staging directory is left beside the data root"
  assert_equals "" "$(find "$DATA_DIR" -maxdepth 1 \( -name '*aside*' -o -name '*prev*' -o -name '*tmp*' \))" "promotion leaves nothing set aside inside the data root"
  pass "daily runner: budget chain, staged copy, promotion keeps dispatch_log"
}

test_failed_run_keeps_last_good_and_raises_one_wake() {
  local exit_code line before after rows
  for exit_code in 1 2 3 4; do
    new_home "fail$exit_code"
    before=$(tree_hash "$DATA_DIR")
    line="stderr line for exit $exit_code"
    run_runner run FAKE_EXIT="$exit_code" FAKE_STDERR="$line\nsecond line\n"
    expect_code "$exit_code" "$CODE" "the runner returns the collector's exit $exit_code"
    after=$(tree_hash "$DATA_DIR")
    assert_equals "$before" "$after" "exit $exit_code leaves aa.sqlite, verdict.json, projection/ and the rest byte-identical"
    rows=$(queued_wakes)
    assert_equals 1 "$(printf '%s\n' "$rows" | grep -c .)" "exit $exit_code raises exactly one wake"
    assert_contains "$rows" "check: model-picker-daily: the daily collector run exited $exit_code: $line;" "the wake names the exit and the first stderr line"
    assert_not_contains "$rows" "second line" "only the first stderr line is quoted"
    assert_contains "$rows" "the failed run's newest observed_at was $(stamp "$NOW");" "the wake names the failed run's newest observed_at"
    assert_equals "$(stamp "$NOW")" "$(cat "$HOME_DIR/state/.model-picker-daily.last.observed_at")" "the newest observed_at is kept beside the failed run's verdict"
    assert_equals "$(stamp $((NOW - HOUR)))" "$(sql "$DATA_DIR/aa.sqlite" 'SELECT MAX(observed_at) FROM observations')" "the live aa.sqlite still holds its own newest observed_at"
    printf '%s\n' "$rows" | awk -F '\t' '{ exit !($3 == "check") }' || fail "the wake is a check row"
    run_runner run FAKE_EXIT="$exit_code" FAKE_STDERR="$line\n"
    assert_equals 1 "$(wake_count)" "the same failure again the same day raises nothing more"
    NOW_AT=$((NOW + 86400)) run_runner run FAKE_EXIT="$exit_code" FAKE_STDERR="$line\n"
    assert_equals 2 "$(wake_count)" "the same failure the next day raises one more wake"
  done
  pass "daily runner: exits 1 to 4 keep the last good data and raise one wake per day"
}

test_untrusted_exit_without_stderr_names_the_verdict_line() {
  new_home untrusted
  run_runner run FAKE_EXIT=3 FAKE_STDOUT="chart-diff: UNTRUSTED (2 mismatches); 40 values compared"
  expect_code 3 "$CODE" "an UNTRUSTED run"
  assert_contains "$(queued_wakes)" "exited 3: no stderr line; stdout said: chart-diff: UNTRUSTED (2 mismatches)" "the wake quotes the verdict line when stderr is empty"
  assert_contains "$(queued_wakes)" "$HOME_DIR/state/.model-picker-daily.last.*" "the wake says where the failed run's evidence is"
  assert_contains "$(cat "$HOME_DIR/state/.model-picker-daily.last.stdout")" "chart-diff: UNTRUSTED" "the failed run's stdout is kept"
  assert_contains "$(cat "$HOME_DIR/state/.model-picker-daily.last.verdict.json")" UNTRUSTED "the failed run's verdict is kept beside the untouched live one"
  assert_contains "$(cat "$DATA_DIR/verdict.json")" TRUSTED "the live verdict is still the last good one"
  pass "daily runner: an UNTRUSTED run with empty stderr still names its cause"
}

test_budget_stop_and_staging_failure_are_failures() {
  new_home budget
  run_runner run FAKE_EXIT=98 FAKE_STDERR="fm-proc-budget: tree of 300 exceeded 256\n"
  expect_code 98 "$CODE" "a budget stop"
  assert_contains "$(queued_wakes)" "exited 98: fm-proc-budget: tree of 300 exceeded 256" "a budget stop raises its wake"
  new_home nowrap
  CODE=0
  env FM_HOME="$HOME_DIR" FM_TEST_SEAM=1 FM_MODEL_PICKER_DAILY_NOW="$NOW" FM_MODEL_PICKER_DAILY_COLLECTOR="$TMP_ROOT/fake-collector.sh" \
    FM_MODEL_PICKER_DAILY_BUDGET=/usr/bin/env FAKE_LOG="$FAKE_LOG" "$RUNNER" run >/dev/null 2>&1 || CODE=$?
  expect_code 97 "$CODE" "a wrapper that does not mark its command fails the fake collector's own check"
  pass "daily runner: a budget stop is a failed run"
}

test_clean_run_on_stale_snapshot_ends_fresh() {
  new_home recover
  make_fixture "$DATA_DIR" $((NOW - 40 * HOUR))
  run_runner run
  expect_code 0 "$CODE" "a clean run over a 40 hour old snapshot"
  run_runner check
  assert_equals 0 "$(wake_count)" "the promoted snapshot is fresh, so the check raises nothing"
  pass "daily runner: a good run replaces a stale snapshot"
}

test_freshness_boundaries() {
  local hours before
  for hours in 35 36; do
    new_home "fresh$hours"
    make_fixture "$DATA_DIR" $((NOW - hours * HOUR))
    before=$(tree_hash "$HOME_DIR")
    run_runner check
    expect_code 0 "$CODE" "check at $hours hours"
    assert_equals 0 "$(wake_count)" "a $hours hour old snapshot raises nothing"
    assert_equals "$before" "$(tree_hash "$HOME_DIR")" "the check at $hours hours changes no file"
  done
  new_home stale37
  make_fixture "$DATA_DIR" $((NOW - 37 * HOUR))
  before=$(tree_hash "$DATA_DIR")
  run_runner check
  expect_code 0 "$CODE" "check at 37 hours"
  assert_contains "$(queued_wakes)" "check: model-picker-daily: the model-picker snapshot is 37.0 hours old (newest observed_at $(stamp $((NOW - 37 * HOUR))))" "the wake names the age in hours"
  assert_equals 1 "$(wake_count)" "one wake"
  assert_equals "$before" "$(tree_hash "$DATA_DIR")" "the check reads only"
  run_runner check
  run_runner check
  assert_equals 1 "$(wake_count)" "polling again the same day raises nothing more"
  NOW_AT=$((NOW + 86400)) run_runner check
  assert_equals 2 "$(wake_count)" "the next day of staleness raises one more wake"
  assert_contains "$(queued_wakes)" "61.0 hours old" "the next day's wake names its own age"
  pass "daily check: 35 and 36 hours pass, 37 raises one wake a day, and nothing is written"
}

test_old_snapshot_that_exists_is_stale() {
  new_home monthold
  make_fixture "$DATA_DIR" $((NOW - 31 * 24 * HOUR))
  run_runner check
  assert_contains "$(queued_wakes)" "744.0 hours old" "a 31 day old snapshot is stale although its files exist"
  pass "daily check: a 31 day old snapshot raises a wake"
}

test_missing_snapshot_raises_one_wake() {
  new_home none
  rm -rf "$DATA_DIR"
  run_runner check
  expect_code 0 "$CODE" "check with no snapshot"
  assert_contains "$(queued_wakes)" "the model-picker snapshot is missing: no aa.sqlite at $DATA_DIR/aa.sqlite" "the wake says the snapshot is missing"
  run_runner check
  assert_equals 1 "$(wake_count)" "one wake for the day"
  assert_absent "$DATA_DIR" "the check creates nothing"
  mkdir -p "$DATA_DIR"
  run_runner check
  assert_equals "" "$(ls -A "$DATA_DIR")" "a check creates no snapshot file in an empty data root"
  new_home empty
  python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("DELETE FROM observations"); c.commit()' "$DATA_DIR/aa.sqlite"
  run_runner check
  assert_contains "$(queued_wakes)" "holds no observations" "an empty matrix counts as missing"
  new_home corrupt
  printf 'not a database' > "$DATA_DIR/aa.sqlite"
  run_runner check
  assert_contains "$(queued_wakes)" "cannot read $DATA_DIR/aa.sqlite" "an unreadable database counts as missing"
  pass "daily check: a missing, empty or unreadable snapshot raises one wake"
}

test_data_root_follows_the_collector_resolution() {
  new_home custom
  local custom="$TMP_ROOT/custom-root"
  make_fixture "$custom" $((NOW - 37 * HOUR))
  run_runner check FM_MODEL_PICKER_DATA="$custom"
  assert_contains "$(queued_wakes)" "37.0 hours old" "FM_MODEL_PICKER_DATA selects the checked root"
  pass "daily check: the data root is the collector's own"
}

test_second_run_is_refused_while_one_is_under_way() {
  new_home lock
  make_fixture "$DATA_DIR" $((NOW - 40 * HOUR))
  local started="$TMP_ROOT/lock/started" pid
  env FM_HOME="$HOME_DIR" FM_TEST_SEAM=1 FM_MODEL_PICKER_DAILY_NOW="$NOW" FM_MODEL_PICKER_DAILY_COLLECTOR="$TMP_ROOT/fake-collector.sh" \
    FM_MODEL_PICKER_DAILY_BUDGET="$TMP_ROOT/fake-budget.sh" FAKE_LOG="$FAKE_LOG" FAKE_STARTED="$started" FAKE_SLEEP=5 FAKE_EXIT=2 "$RUNNER" run >/dev/null 2>&1 &
  pid=$!
  fm_test_wait_until --while-alive "$pid" -- test -e "$started" || { kill "$pid" 2>/dev/null; fail "the first run never reached its collector"; }
  run_runner run
  expect_code 75 "$CODE" "a second run while the first is under way"
  assert_contains "$ERR" "holds" "the refusal names the lock"
  run_runner check
  expect_code 0 "$CODE" "a check while a collection is under way"
  assert_contains "$(queued_wakes)" "40.0 hours old" "the freshness check does not wait for a hung collection"
  wait "$pid" 2>/dev/null || true
  pass "daily runner: one run at a time, and the check never waits for it"
}

test_staging_cleanup_touches_only_owned_stages() {
  new_home owner
  local parent dead
  parent=$(dirname "$DATA_DIR")
  /bin/sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null
  mkdir -p "$parent/model-picker.daily.keep" "$parent/model-picker.daily.4242" "$parent/model-picker.daily.live" \
    "$parent/model-picker.daily.stale" "$TMP_ROOT/owner/elsewhere"
  printf 'unrelated\n' > "$parent/model-picker.daily.keep/notes.txt"
  printf 'unmarked\n' > "$parent/model-picker.daily.4242/notes.txt"
  printf '%s\n' "$$" > "$parent/model-picker.daily.live/.fm-model-picker-daily-owner"
  printf '%s\n' "$dead" > "$parent/model-picker.daily.stale/.fm-model-picker-daily-owner"
  printf '%s\n' "$dead" > "$TMP_ROOT/owner/elsewhere/.fm-model-picker-daily-owner"
  ln -s "$TMP_ROOT/owner/elsewhere" "$parent/model-picker.daily.link"
  run_runner run
  expect_code 0 "$CODE" "a run beside other same-prefix directories"
  assert_present "$parent/model-picker.daily.keep/notes.txt" "an unrelated same-prefix directory is kept"
  assert_present "$parent/model-picker.daily.4242/notes.txt" "a numbered directory with no owner record is kept"
  assert_present "$parent/model-picker.daily.live" "a stage whose owner is alive is kept"
  assert_absent "$parent/model-picker.daily.stale" "a stage whose recorded owner is gone is removed"
  assert_present "$TMP_ROOT/owner/elsewhere/.fm-model-picker-daily-owner" "a symbolic link is never followed"
  assert_present "$parent/model-picker.daily.link" "the link itself is kept"
  pass "daily runner: staging cleanup removes only a stage whose owner is gone"
}

test_failed_promotion_restores_the_previous_snapshot() {
  new_home restore
  python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("PRAGMA user_version=99"); c.commit()' "$DATA_DIR/aa.sqlite"
  local before after rows
  before=$(tree_hash "$DATA_DIR")
  run_runner run
  expect_code 1 "$CODE" "a promotion that fails after the collector exited 0"
  after=$(tree_hash "$DATA_DIR")
  assert_equals "$before" "$after" "a failed promotion leaves every file of the last good snapshot byte-identical"
  assert_contains "$(cat "$DATA_DIR/verdict.json")" TRUSTED "the last good verdict is back"
  assert_equals "model-picker" "$(ls -A "$(dirname "$DATA_DIR")")" "nothing is left beside the data root"
  rows=$(queued_wakes)
  assert_equals 1 "$(printf '%s\n' "$rows" | grep -c .)" "one wake"
  assert_contains "$rows" "installing its output into $DATA_DIR failed (the runner exits 1; the live verdict now reads TRUSTED): previous snapshot restored; promotion failed:" "the wake states the true result, read back from the verdict file"
  assert_equals true "$(shadow_trusts "$DATA_DIR")" "the consumer's guard trusts the restored snapshot"
  assert_not_contains "$rows" "exited 0 but promoting" "the old wording is gone"
  pass "daily runner: a failed promotion restores the previous snapshot"
}

test_promotion_installs_a_whole_generation() {
  new_home whole
  mkdir -p "$DATA_DIR/projection/zzz-dir"
  printf 'nested\n' > "$DATA_DIR/projection/zzz-dir/file"
  run_runner run
  expect_code 0 "$CODE" "a promotion over a projection that holds a nonempty subdirectory"
  assert_equals "rebuilt-model.json" "$(ls -A "$DATA_DIR/projection")" "the projection is exactly the staged generation"
  assert_equals 0 "$(wake_count)" "no wake"
  pass "daily runner: a whole generation replaces the projection directory"
}

test_verdict_reads_untrusted_while_a_promotion_waits() {
  new_home window
  local release="$TMP_ROOT/window/release" locked="$TMP_ROOT/window/locked" holder runner
  python3 -I - "$DATA_DIR/aa.sqlite" "$locked" "$release" <<'PY' &
import os, sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("BEGIN IMMEDIATE")
open(sys.argv[2], "w").close()
for _ in range(1200):
    if os.path.exists(sys.argv[3]):
        break
    time.sleep(0.1)
conn.execute("ROLLBACK")
PY
  holder=$!
  fm_test_wait_until --while-alive "$holder" -- test -e "$locked" || fail "the lock holder never started"
  env FM_HOME="$HOME_DIR" FM_TEST_SEAM=1 FM_MODEL_PICKER_DAILY_NOW="$NOW" FM_MODEL_PICKER_DAILY_COLLECTOR="$TMP_ROOT/fake-collector.sh" \
    FM_MODEL_PICKER_DAILY_BUDGET="$TMP_ROOT/fake-budget.sh" FAKE_LOG="$FAKE_LOG" "$RUNNER" run >/dev/null 2>&1 &
  runner=$!
  fm_test_wait_until --while-alive "$runner" -- grep -q UNTRUSTED "$DATA_DIR/verdict.json" || { : > "$release"; fail "the verdict never read UNTRUSTED during the promotion"; }
  assert_contains "$(cat "$DATA_DIR/verdict.json")" "promotion in progress" "a reader sees UNTRUSTED while the promotion is under way"
  : > "$release"
  wait "$runner"
  expect_code 0 "$?" "the promotion after the lock is released"
  wait "$holder" 2>/dev/null || true
  assert_contains "$(cat "$DATA_DIR/verdict.json")" TRUSTED "the new verdict replaces the marker"
  assert_not_contains "$(cat "$DATA_DIR/verdict.json")" "promotion in progress" "the marker is gone"
  pass "daily runner: the live verdict reads UNTRUSTED for the whole install window"
}

test_incomplete_rollback_never_restores_a_trusted_verdict() {
  new_home incomplete
  local before_db before_proj
  before_db=$(sha256sum_of "$DATA_DIR/aa.sqlite")
  run_runner run FM_MODEL_PICKER_DAILY_FAULT='rename:\.daily\.[0-9]+/snapshot\.json$>>/snapshot\.json$;rename:/projection$>>\.daily\.[0-9]+/projection$'
  expect_code 1 "$CODE" "a forward failure and a failed undo"
  assert_contains "$(cat "$DATA_DIR/verdict.json")" UNTRUSTED "the verdict file says UNTRUSTED"
  assert_equals false "$(shadow_trusts "$DATA_DIR")" "the consumer's guard refuses the half-restored snapshot"
  assert_equals "$before_db" "$(sha256sum_of "$DATA_DIR/aa.sqlite")" "the database was never changed"
  before_proj=$(queued_wakes)
  assert_contains "$before_proj" "(the runner exits 1; the live verdict now reads UNTRUSTED): RESTORE INCOMPLETE, live verdict left UNTRUSTED;" "the wake tells the truth about the verdict, ahead of any path"
  assert_equals 1 "$(wake_count)" "one wake"
  run_runner run
  expect_code 0 "$CODE" "the next good run repairs it"
  assert_equals true "$(shadow_trusts "$DATA_DIR")" "the consumer's guard trusts the repaired snapshot"
  assert_equals "rebuilt-model.json" "$(ls -A "$DATA_DIR/projection")" "the projection is the new generation"
  assert_equals "" "$(find "$DATA_DIR" -maxdepth 1 \( -name '*aside*' -o -name '*prev*' -o -name '*tmp*' \))" "the killed promotion's leftovers are cleaned"
  pass "daily runner: an incomplete rollback never restores a trusted verdict over a mixed generation"
}

test_promotion_killed_at_the_commit_boundary_is_refused_and_repaired() {
  local point old_db
  for point in before-commit after-commit; do
    new_home "kill-$point"
    run_runner run FM_MODEL_PICKER_DAILY_FAULT="kill:$point"
    expect_code 1 "$CODE" "a promotion killed $point"
    assert_equals UNTRUSTED "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["verdict"])' "$DATA_DIR/verdict.json")" "the verdict reads UNTRUSTED after a kill $point"
    assert_equals false "$(shadow_trusts "$DATA_DIR")" "the consumer's guard refuses the snapshot after a kill $point"
    old_db=$(sql "$DATA_DIR/aa.sqlite" 'SELECT value FROM observations')
    if [ "$point" = before-commit ]; then assert_equals "1.0" "$old_db" "the database is the old generation"; else assert_equals "2.0" "$old_db" "the database is the new generation"; fi
    assert_contains "$(queued_wakes)" "the live verdict now reads UNTRUSTED" "the wake names the verdict a reader sees"
    run_runner run
    expect_code 0 "$CODE" "the next good run after a kill $point"
    assert_equals true "$(shadow_trusts "$DATA_DIR")" "the consumer's guard trusts the repaired snapshot"
    assert_equals "2.0" "$(sql "$DATA_DIR/aa.sqlite" 'SELECT value FROM observations')" "the new generation is live"
    assert_equals "fixture-original" "$(sql "$DATA_DIR/aa.sqlite" 'SELECT task_type FROM dispatch_log ORDER BY id')" "dispatch_log survived"
    assert_equals "" "$(find "$DATA_DIR" -maxdepth 1 \( -name '*aside*' -o -name '*prev*' -o -name '*tmp*' \))" "the leftovers of the killed promotion are cleaned"
  done
  pass "daily runner: a promotion killed at the commit boundary is refused by the guard and repaired by the next run"
}

test_independent_reader_at_the_commit_boundary() {
  local point announce release runner
  for point in before-commit after-commit; do
    new_home "hold-$point"
    announce="$TMP_ROOT/hold-$point/announce"
    release="$TMP_ROOT/hold-$point/release"
    env FM_HOME="$HOME_DIR" FM_TEST_SEAM=1 FM_MODEL_PICKER_DAILY_NOW="$NOW" FM_MODEL_PICKER_DAILY_COLLECTOR="$TMP_ROOT/fake-collector.sh" \
      FM_MODEL_PICKER_DAILY_BUDGET="$TMP_ROOT/fake-budget.sh" FAKE_LOG="$FAKE_LOG" \
      FM_MODEL_PICKER_DAILY_FAULT="hold:$point:$announce:$release" "$RUNNER" run >/dev/null 2>&1 &
    runner=$!
    fm_test_wait_until --while-alive "$runner" -- test -e "$announce" || { : > "$release"; fail "the promotion never reached $point"; }
    assert_equals false "$(shadow_trusts "$DATA_DIR")" "a reader at $point is refused by the guard"
    assert_contains "$(cat "$DATA_DIR/verdict.json")" UNTRUSTED "a reader at $point sees UNTRUSTED"
    if [ "$point" = before-commit ]; then
      assert_equals "1.0" "$(sql "$DATA_DIR/aa.sqlite" 'SELECT value FROM observations')" "a reader at before-commit sees the old database"
    else
      assert_equals "2.0" "$(sql "$DATA_DIR/aa.sqlite" 'SELECT value FROM observations')" "a reader at after-commit sees the new database"
    fi
    : > "$release"
    wait "$runner"
    expect_code 0 "$?" "the promotion released at $point"
    assert_equals true "$(shadow_trusts "$DATA_DIR")" "the guard trusts the finished promotion"
  done
  pass "daily runner: an independent reader at the commit boundary is never trusted with a mixture"
}

test_wake_keeps_the_outcome_with_a_long_path() {
  local long outcome
  long=$(printf 'd%.0s' $(seq 1 120))
  new_home "$long/$long"
  run_runner run FM_MODEL_PICKER_DAILY_FAULT='rename:\.daily\.[0-9]+/snapshot\.json$>>/snapshot\.json$'
  expect_code 1 "$CODE" "a restored promotion failure under a long path"
  outcome=$(queued_wakes)
  assert_contains "$outcome" "the live verdict now reads TRUSTED): previous snapshot restored; promotion failed:" "the restored outcome survives the long path"
  new_home "$long/incomplete"
  run_runner run FM_MODEL_PICKER_DAILY_FAULT='rename:\.daily\.[0-9]+/snapshot\.json$>>/snapshot\.json$;rename:/projection$>>\.daily\.[0-9]+/projection$'
  expect_code 1 "$CODE" "an incomplete rollback under a long path"
  assert_contains "$(queued_wakes)" "the live verdict now reads UNTRUSTED): RESTORE INCOMPLETE, live verdict left UNTRUSTED;" "the incomplete outcome survives the long path"
  pass "daily runner: the wake names the real outcome ahead of long paths"
}

# --- installer --------------------------------------------------------------

setup_installer() {
  mkdir -p "$TMP_ROOT/inst/home" "$TMP_ROOT/inst/fmhome/state" "$TMP_ROOT/inst/agents"
  : > "$TMP_ROOT/inst/loaded"
  : > "$TMP_ROOT/inst/calls"
  cat > "$TMP_ROOT/inst/launchctl" <<EOF
#!/usr/bin/env bash
# A launchctl that remembers what is loaded and, like the real one, refuses to bootstrap a label twice.
printf '%s\n' "\$*" >> "$TMP_ROOT/inst/calls"
label=\${2##*/}
case "\$1" in
  print) grep -Fxq "\$label" "$TMP_ROOT/inst/loaded" ;;
  bootstrap)
    label=\$(basename "\$3" .plist)
    grep -Fxq "\$label" "$TMP_ROOT/inst/loaded" && { echo "already loaded" >&2; exit 37; }
    echo "\$label" >> "$TMP_ROOT/inst/loaded" ;;
  bootout) grep -Fxv "\$label" "$TMP_ROOT/inst/loaded" > "$TMP_ROOT/inst/loaded.new"; mv "$TMP_ROOT/inst/loaded.new" "$TMP_ROOT/inst/loaded" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$TMP_ROOT/inst/launchctl"
}

run_install() {
  CODE=0
  env HOME="$TMP_ROOT/inst/home" FM_HOME="$TMP_ROOT/inst/fmhome" FM_TEST_SEAM=1 \
    FM_MODEL_PICKER_DAILY_AGENT_DIR="$TMP_ROOT/inst/agents" FM_MODEL_PICKER_DAILY_LAUNCHCTL="$TMP_ROOT/inst/launchctl" \
    "$INSTALL" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || CODE=$?
  OUT=$(cat "$TMP_ROOT/out")
  ERR=$(cat "$TMP_ROOT/err")
}

test_installer_print_names_runner_daily_interval_and_login() {
  setup_installer
  run_install install --print
  expect_code 0 "$CODE" "install --print"
  assert_contains "$OUT" "<string>$ROOT/bin/fm-model-picker-daily.sh</string>"$'\n'"    <string>run</string>" "the default agent runs the daily collection"
  assert_contains "$OUT" "<key>StartInterval</key>"$'\n'"  <integer>86400</integer>" "it runs every 86400 seconds"
  assert_contains "$OUT" "<key>RunAtLoad</key>"$'\n'"  <true/>" "it loads at login"
  assert_contains "$OUT" "<string>$TMP_ROOT/inst/fmhome</string>" "it is rendered for one home"
  assert_contains "$OUT" "<string>com.firstmate.model-picker-daily.run." "the label is per home and per agent"
  assert_equals "" "$(ls -A "$TMP_ROOT/inst/agents")" "--print writes nothing"
  if command -v plutil >/dev/null 2>&1; then
    printf '%s\n' "$OUT" > "$TMP_ROOT/inst/print.plist"
    plutil -lint "$TMP_ROOT/inst/print.plist" >/dev/null || fail "the rendered plist is valid"
  fi
  run_install install --print --agent check
  assert_contains "$OUT" "<string>$ROOT/bin/fm-model-picker-daily.sh</string>"$'\n'"    <string>check</string>" "the second agent runs the freshness check"
  assert_contains "$OUT" "<key>StartInterval</key>"$'\n'"  <integer>3600</integer>" "the check runs hourly"
  assert_contains "$OUT" "<key>RunAtLoad</key>"$'\n'"  <false/>" "installing does not run the check before the first collection"
  assert_not_contains "$OUT" "FM_MODEL_PICKER_DATA" "an unset data root is not written into the agent"
  CODE=0
  env HOME="$TMP_ROOT/inst/home" FM_HOME="$TMP_ROOT/inst/fmhome" FM_MODEL_PICKER_DATA="$TMP_ROOT/relocated&root" "$INSTALL" install --print >"$TMP_ROOT/out" 2>&1 || CODE=$?
  expect_code 0 "$CODE" "install --print with a relocated data root"
  assert_contains "$(cat "$TMP_ROOT/out")" "<key>FM_MODEL_PICKER_DATA</key>"$'\n'"    <string>$TMP_ROOT/relocated&amp;root</string>" "a relocated data root reaches the agent, escaped"
  run_install install --print --agent nonsense
  expect_code 1 "$CODE" "an unknown agent"
  pass "daily installer: print renders the runner, the 24 hour interval, load at login, and the hourly check"
}

test_installer_install_replace_status_uninstall() {
  setup_installer
  local run_label check_label
  run_install install
  expect_code 0 "$CODE" "first install"
  run_label=$(grep '\.run\.' "$TMP_ROOT/inst/loaded")
  check_label=$(grep '\.check\.' "$TMP_ROOT/inst/loaded")
  assert_present "$TMP_ROOT/inst/agents/$run_label.plist" "the run plist is in the agent directory"
  assert_present "$TMP_ROOT/inst/agents/$check_label.plist" "the check plist is in the agent directory"
  run_install status
  assert_contains "$OUT" "$run_label plist=present launchd=loaded" "status sees the loaded run agent"
  assert_contains "$OUT" "$check_label plist=present launchd=loaded" "status sees the loaded check agent"
  run_install install
  expect_code 0 "$CODE" "second install"
  assert_equals 2 "$(grep -c . "$TMP_ROOT/inst/loaded")" "a second install leaves two loaded agents"
  assert_equals 2 "$(find "$TMP_ROOT/inst/agents" -type f | grep -c .)" "a second install leaves two plists"
  assert_equals 2 "$(grep -c '^bootout' "$TMP_ROOT/inst/calls")" "the second install boots each first agent out"
  assert_equals "" "$(find "$TMP_ROOT/inst/home" "$TMP_ROOT/inst/fmhome" -type f)" "install writes no file under HOME or the firstmate home"
  run_install uninstall
  expect_code 0 "$CODE" "uninstall"
  assert_equals "" "$(ls -A "$TMP_ROOT/inst/agents")" "uninstall removes both plists"
  assert_equals 0 "$(grep -c . "$TMP_ROOT/inst/loaded")" "uninstall unloads both agents"
  run_install status
  assert_contains "$OUT" "plist=absent launchd=not-loaded" "status after uninstall"
  assert_absent "$TMP_ROOT/inst/home/.claude" "the installer never touched ~/.claude"
  pass "daily installer: install both agents, replace without duplicating, status, uninstall"
}

test_installer_refuses_a_home_with_no_state() {
  setup_installer
  rmdir "$TMP_ROOT/inst/fmhome/state"
  run_install install
  expect_code 1 "$CODE" "install into a home with no state directory"
  assert_equals "" "$(ls -A "$TMP_ROOT/inst/agents")" "nothing is written"
  pass "daily installer: a home with no state directory is refused"
}

install_fakes
fm_test_only
test_run_chains_budget_collector_and_promotes
test_failed_run_keeps_last_good_and_raises_one_wake
test_untrusted_exit_without_stderr_names_the_verdict_line
test_budget_stop_and_staging_failure_are_failures
test_clean_run_on_stale_snapshot_ends_fresh
test_freshness_boundaries
test_old_snapshot_that_exists_is_stale
test_missing_snapshot_raises_one_wake
test_data_root_follows_the_collector_resolution
test_second_run_is_refused_while_one_is_under_way
test_staging_cleanup_touches_only_owned_stages
test_failed_promotion_restores_the_previous_snapshot
test_promotion_installs_a_whole_generation
test_verdict_reads_untrusted_while_a_promotion_waits
test_incomplete_rollback_never_restores_a_trusted_verdict
test_promotion_killed_at_the_commit_boundary_is_refused_and_repaired
test_independent_reader_at_the_commit_boundary
test_wake_keeps_the_outcome_with_a_long_path
test_installer_print_names_runner_daily_interval_and_login
test_installer_install_replace_status_uninstall
test_installer_refuses_a_home_with_no_state
