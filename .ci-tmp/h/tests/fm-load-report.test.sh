#!/usr/bin/env bash
# fm-load-report.test.sh - Load sampling format, the load verdict, and the
# pipeline convergence verdict, driven through bin/fm-load-report.sh against a
# private samples file and a fixture no-mistakes database.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-load-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-load-report)
export FM_CPU_POOL_DIR="$TMP_ROOT/pool"
unset FM_LOAD_SAMPLES FM_CPU_PASS_HELD

make_db() {  # <path> <review-fix rounds per run...>; -1 marks a run that hit the wall-clock limit
  python3 - "$@" <<'PY'
import sqlite3, sys
path, rounds = sys.argv[1], [int(x) for x in sys.argv[2:]]
conn = sqlite3.connect(path)
conn.executescript("""
CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, created_at INTEGER NOT NULL, error TEXT);
CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, purpose TEXT NOT NULL,
  started_at INTEGER NOT NULL, duration_ms INTEGER NOT NULL, exit_status TEXT NOT NULL, failure_category TEXT);
""")
inv = 0
for index, count in enumerate(rounds):
    run = "run-%02d" % index
    error = "agent fix reached its absolute wall-clock limit" if count < 0 else None
    conn.execute("INSERT INTO runs VALUES (?, ?, ?, ?)",
                 (run, "failed" if error else "completed", 2000 + index, error))
    for purpose in ["review"] + ["review-fix"] * max(count, 0):
        inv += 1
        conn.execute("INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, 'ok', NULL)",
                     ("i%d" % inv, run, purpose, 2000 + index, 600000))
# A run that never reached review is not a convergence sample.
conn.execute("INSERT INTO runs VALUES ('no-review', 'cancelled', 1997, NULL)")
for index, status in enumerate(("pending", "running")):
    run = "live-" + status
    conn.execute("INSERT INTO runs VALUES (?, ?, ?, NULL)", (run, status, 3000 + index))
    conn.execute("INSERT INTO agent_invocations VALUES (?, ?, 'review', ?, 1, 'ok', NULL)",
                 (run + "-review", run, 3000 + index))
# A run from before the window is ignored.
conn.execute("INSERT INTO runs VALUES ('old', 'completed', 10, NULL)")
conn.execute("INSERT INTO agent_invocations VALUES ('old-r', 'old', 'review', 10, 1, 'ok', NULL)")
for extra in range(5):
    conn.execute("INSERT INTO agent_invocations VALUES (?, 'old', 'review-fix', 10, 1, 'ok', NULL)",
                 ("old-f%d" % extra,))
conn.commit()
PY
}

field() {  # <json> <python expression over r>
  printf '%s' "$1" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(eval(sys.argv[1]))' "$2"
}

test_record_appends_one_sample() {
  local out line fields
  out="$TMP_ROOT/record.tsv"
  "$TOOL" record --out "$out" || fail "record failed"
  "$TOOL" record --out "$out" || fail "second record failed"
  assert_equals 2 "$(wc -l <"$out" | tr -d ' ')" "each record must append exactly one line"
  line=$(tail -1 "$out")
  fields=$(printf '%s\n' "$line" | awk -F'\t' '{print NF}')
  assert_equals 7 "$fields" "a sample must have seven tab-separated fields"
  printf '%s\n' "$line" | grep -Eq '^[0-9]+	[0-9.]+	[0-9.]+	[0-9.]+	[0-9]+	[0-9]+	0$' \
    || fail "sample must carry epoch, three loads, cpus, pool size and held passes: $line"
  pass "record appends one sample with load, cpus and pool use"
}

test_report_load_and_convergence_verdicts() {
  local samples db out
  samples="$TMP_ROOT/samples.tsv"
  printf '1000\t10.00\t9.00\t8.00\t4\t4\t1\n1100\t6.00\t6.00\t6.00\t4\t4\t3\n1200\t7.00\t7.00\t7.00\t4\t4\t2\n' >"$samples"
  db="$TMP_ROOT/ok.sqlite"
  make_db "$db" 0 1 2 0 1 2 0 1 2 0 3 3 3 3 3 3 3 3 3 3
  out=$("$TOOL" report --samples "$samples" --since 1100 --nm-db "$db" --json) || fail "report failed: $out"
  assert_equals 2 "$(field "$out" 'r["load"]["samples"]')" "--since must bound the load window"
  assert_equals 7.0 "$(field "$out" 'r["load"]["load1_max"]')" "load max must cover the window only"
  assert_equals True "$(field "$out" 'r["load"]["load_within_2x_cpus"]')" "p95 at or under 2x cpus must pass"
  assert_equals 3 "$(field "$out" 'r["load"]["pool_held_max"]')" "pool use must be reported"
  assert_equals 10 "$(field "$out" 'r["pipeline"]["runs_considered"]')" "runs without review and runs before --since must be skipped"
  assert_equals True "$(field "$out" 'all(x["status"] == "completed" for x in r["pipeline"]["cohort_runs"])')" "later pending and running runs must not enter the cohort"
  assert_equals True "$(field "$out" '[x["run"] for x in r["pipeline"]["cohort_runs"]] == ["run-%02d" % i for i in range(10)]')" "the cohort must contain the first ten eligible runs, oldest first"
  assert_equals True "$(field "$out" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "later nonconverging runs must not change a successful first-ten verdict"
  out=$("$TOOL" report --samples "$samples" --since 1100 --nm-db "$db") || fail "text report failed: $out"
  assert_contains "$out" "first eligible runs=10 of 10 converged_within_2_fix_rounds=True" "text output must report the first-ten verdict"

  printf '1300\t9.00\t9.00\t9.00\t4\t4\t0\n' >>"$samples"
  db="$TMP_ROOT/bad.sqlite"
  make_db "$db" 0 1 3 0 1 2 0 1 2 0 0 1 2 0 1 2 0 1 2 0
  out=$("$TOOL" report --samples "$samples" --since 1100 --nm-db "$db" --json) || fail "report failed: $out"
  assert_equals False "$(field "$out" 'r["load"]["load_within_2x_cpus"]')" "p95 above 2x cpus must fail"
  assert_equals False "$(field "$out" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "later successful runs must not hide a first-ten run with 3 fix rounds"

  db="$TMP_ROOT/timeout.sqlite"
  make_db "$db" 0 1 -1 0 1 2 0 1 2 0
  out=$("$TOOL" report --samples "$samples" --since 1100 --nm-db "$db" --json) || fail "report failed: $out"
  assert_equals False "$(field "$out" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "a run that hit a timeout must not count as converged"
  assert_equals wall-clock "$(field "$out" 'r["pipeline"]["timeout_class_run_errors"][0]["class"]')" "timeout-class run errors must be named"

  db="$TMP_ROOT/few.sqlite"
  make_db "$db" 0 1
  out=$("$TOOL" report --samples "$samples" --since 1100 --nm-db "$db" --json) || fail "report failed: $out"
  assert_equals None "$(field "$out" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "fewer runs than wanted must not give a verdict"
  out=$("$TOOL" report --samples "$samples" --since 1100 --nm-db "$db") || fail "text report failed: $out"
  assert_contains "$out" "converged_within_2_fix_rounds=pending" "text output must report an incomplete cohort as pending"
  pass "report gives load and convergence verdicts over the window"
}

test_unsuccessful_runs_do_not_converge() {
  local samples db out status
  samples="$TMP_ROOT/unsuccessful.tsv"
  printf '1000\t1.00\t1.00\t1.00\t4\t4\t0\n' >"$samples"
  for status in failed cancelled; do
    db="$TMP_ROOT/$status.sqlite"
    make_db "$db" 0 1 2 0 1 2 0 1 2 0
    python3 - "$db" "$status" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as conn:
    conn.execute("UPDATE runs SET status = ? WHERE id = 'run-09'", (sys.argv[2],))
PY
    out=$("$TOOL" report --samples "$samples" --nm-db "$db" --json) || fail "report failed: $out"
    assert_equals "$status" "$(field "$out" 'r["pipeline"]["cohort_runs"][-1]["status"]')" "unsuccessful terminal runs must remain in the convergence window"
    assert_equals False "$(field "$out" 'r["pipeline"]["cohort_runs"][-1]["converged"]')" "a non-timeout unsuccessful run cannot converge"
    assert_equals False "$(field "$out" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "one unsuccessful run must fail the window"
    out=$("$TOOL" report --samples "$samples" --nm-db "$db") || fail "text report failed: $out"
    assert_contains "$out" "converged_within_2_fix_rounds=False" "text output must retain the unsuccessful verdict"
  done
  pass "failed and cancelled runs cannot produce successful convergence"
}

test_cohort_waits_for_earlier_live_runs() {
  local samples db out settled status reviewed created
  samples="$TMP_ROOT/live.tsv"
  printf '1000\t1.00\t1.00\t1.00\t4\t4\t0\n' >"$samples"
  for status in pending running; do
    for reviewed in 0 1; do
      for created in 1996 2009; do
        db="$TMP_ROOT/live-$status-$reviewed-$created.sqlite"
        make_db "$db" 0 1 2 0 1 2 0 1 2 0 0 1 2 0 1 2 0 1 2 0
        python3 - "$db" "$status" "$reviewed" "$created" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as conn:
    conn.execute("INSERT INTO runs VALUES ('a-live', ?, ?, NULL)",
                 (sys.argv[2], int(sys.argv[4])))
    if int(sys.argv[3]):
        conn.execute("INSERT INTO agent_invocations VALUES ('a-review', 'a-live', 'review', ?, 1, 'ok', NULL)",
                     (int(sys.argv[4]),))
PY
        out=$("$TOOL" report --samples "$samples" --nm-db "$db" --json) || fail "report failed: $out"
        assert_equals None "$(field "$out" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "an earlier live run must block a verdict regardless of review entry or creation-time ties"
        out=$("$TOOL" report --samples "$samples" --nm-db "$db") || fail "text report failed: $out"
        assert_contains "$out" "converged_within_2_fix_rounds=pending" "text must share the pending JSON verdict"
        python3 - "$db" "$reviewed" "$created" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as conn:
    conn.execute("UPDATE runs SET status = 'failed' WHERE id = 'a-live'")
    if not int(sys.argv[2]):
        conn.execute("INSERT INTO agent_invocations VALUES ('a-review', 'a-live', 'review', ?, 1, 'ok', NULL)",
                     (int(sys.argv[3]),))
PY
        settled=$("$TOOL" report --samples "$samples" --nm-db "$db" --json) || fail "settled report failed: $settled"
        assert_equals False "$(field "$settled" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "an earlier run that fails after reaching review must settle the verdict as false"
        assert_equals True "$(field "$settled" '"a-live" in [x["run"] for x in r["pipeline"]["cohort_runs"]]')" "the terminal earlier run must enter the first-ten cohort"
        out=$("$TOOL" report --samples "$samples" --nm-db "$db") || fail "text report failed: $out"
        assert_contains "$out" "converged_within_2_fix_rounds=False" "text must share the settled JSON verdict"
        python3 - "$db" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as conn:
    conn.execute("UPDATE runs SET status = 'completed' WHERE id LIKE 'live-%'")
    conn.execute("INSERT INTO runs VALUES ('later', 'completed', 4000, NULL)")
    conn.execute("INSERT INTO agent_invocations VALUES ('later-review', 'later', 'review', 4000, 1, 'ok', NULL)")
PY
        out=$("$TOOL" report --samples "$samples" --nm-db "$db" --json) || fail "later report failed: $out"
        assert_equals "$(field "$settled" 'r["pipeline"]["cohort_runs"]')" "$(field "$out" 'r["pipeline"]["cohort_runs"]')" "later completions must not change settled membership"
        assert_equals False "$(field "$out" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "later successes must not change the settled false verdict"
      done
    done
  done
  pass "earlier live runs block convergence until cohort membership is settled"
}

test_cohort_settles_after_nonreview_run_finishes() {
  local samples db out
  samples="$TMP_ROOT/nonreview.tsv"
  printf '1000\t1.00\t1.00\t1.00\t4\t4\t0\n' >"$samples"
  db="$TMP_ROOT/nonreview.sqlite"
  make_db "$db" 0 1 2 0 1 2 0 1 2 0
  python3 - "$db" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as conn:
    conn.execute("INSERT INTO runs VALUES ('early', 'running', 1996, NULL)")
PY
  out=$("$TOOL" report --samples "$samples" --nm-db "$db" --json) || fail "report failed: $out"
  assert_equals None "$(field "$out" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "an earlier run may still reach review"
  python3 - "$db" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as conn:
    conn.execute("UPDATE runs SET status = 'cancelled' WHERE id = 'early'")
    conn.execute("UPDATE runs SET status = 'running' WHERE id = 'run-09'")
PY
  out=$("$TOOL" report --samples "$samples" --nm-db "$db" --json) || fail "report failed: $out"
  assert_equals None "$(field "$out" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "a live tenth member must keep the verdict pending"
  python3 - "$db" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as conn:
    conn.execute("UPDATE runs SET status = 'completed' WHERE id = 'run-09'")
PY
  out=$("$TOOL" report --samples "$samples" --nm-db "$db" --json) || fail "report failed: $out"
  assert_equals True "$(field "$out" 'r["pipeline"]["converged_within_2_fix_rounds"]')" "a terminal run without review must not block the successful first ten"
  pass "nonreview terminal runs do not block a settled cohort"
}

test_acceptance_cohort_cannot_be_configured() {
  local out rc
  rc=0
  out=$("$TOOL" report --runs 1 2>&1) || rc=$?
  assert_equals 2 "$rc" "the split --runs option must be rejected"
  assert_contains "$out" "unrecognized arguments: --runs 1" "arbitrary acceptance sizes must not be supported"
  rc=0
  out=$("$TOOL" report --runs=1 2>&1) || rc=$?
  assert_equals 2 "$rc" "the equals --runs option must be rejected"
  assert_contains "$out" "unrecognized arguments: --runs=1" "equals form must not restore arbitrary acceptance sizes"
  pass "acceptance always requires the fixed ten-run cohort"
}

test_report_missing_database_is_an_error() {
  local samples rc out
  samples="$TMP_ROOT/samples-missing.tsv"
  printf '1000\t1.00\t1.00\t1.00\t4\t4\t0\n' >"$samples"
  rc=0
  out=$("$TOOL" report --samples "$samples" --nm-db "$TMP_ROOT/absent.sqlite" 2>&1) || rc=$?
  assert_equals 1 "$rc" "an unreadable database must exit 1"
  assert_contains "$out" "pipeline: unavailable" "the load half must still print when the database is unreadable"
  pass "an unreadable database still prints the load facts and exits 1"
}

test_record_appends_one_sample
test_report_load_and_convergence_verdicts
test_unsuccessful_runs_do_not_converge
test_cohort_waits_for_earlier_live_runs
test_cohort_settles_after_nonreview_run_finishes
test_acceptance_cohort_cannot_be_configured
test_report_missing_database_is_an_error
