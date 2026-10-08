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
    conn.execute("INSERT INTO runs VALUES (?, ?, ?, NULL)", (run, status, 1998 + index))
    conn.execute("INSERT INTO agent_invocations VALUES (?, ?, 'review', ?, 1, 'ok', NULL)",
                 (run + "-review", run, 1998 + index))
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
  assert_equals 10 "$(field "$out" 'r["pipeline"]["runs_considered"]')" "live runs, runs without review, and runs before --since must be skipped"
  assert_equals True "$(field "$out" 'all(x["status"] == "completed" for x in r["pipeline"]["cohort_runs"])')" "pending and running runs that reached review must not enter the window"
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
test_report_missing_database_is_an_error
