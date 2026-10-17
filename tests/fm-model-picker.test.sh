#!/usr/bin/env bash
# Model-picker collector behavior through bin/fm-model-picker.sh: the fixture suite, the
# data-root contract, calibration tables created first and never touched by a matrix rebuild,
# exact-slug ingest from a seeded cache (banned route and unknown-age pages ignored), the
# chart-diff verdict on an empty compared set, and a clean error when the network is off.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

trap fm_test_cleanup EXIT
BIN="$ROOT/bin/fm-model-picker.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-picker)
unset FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_MODEL_PICKER_DATA

run() {  # <data-dir> <args...>: sets OUT, ERR and CODE
  local data=$1
  shift
  CODE=0
  FM_MODEL_PICKER_DATA="$data" "$BIN" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || CODE=$?
  OUT=$(cat "$TMP_ROOT/out")
  ERR=$(cat "$TMP_ROOT/err")
}

sql() {  # <db> <query>
  python3 -I -c 'import sqlite3, sys; print("\n".join("|".join(str(c) for c in r) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])))' "$1" "$2"
}

test_selftest_and_help() {
  run "$TMP_ROOT/none" --selftest
  expect_code 0 "$CODE" "--selftest"
  assert_contains "$OUT" "calibration tables, embedded parser, fetch layer, sweep, matrix load, chart-diff" "selftest names every suite"
  assert_absent "$TMP_ROOT/none" "the selftest must not write a data root"
  "$BIN" --help | grep -F -- "--chartdiff" >/dev/null || fail "--help documents the flags"
  pass "model picker: fixture suite runs through the wrapper and writes nothing"
}

test_data_root_resolution() {
  local home=$TMP_ROOT/home
  mkdir -p "$home"
  CODE=0
  FM_HOME="$home" "$BIN" --db >/dev/null 2>&1 || CODE=$?
  expect_code 0 "$CODE" "default data root"
  assert_present "$home/data/model-picker/aa.sqlite" "default is <FM_HOME>/data/model-picker"
  CODE=0
  FM_HOME="$home" FM_DATA_OVERRIDE="$TMP_ROOT/elsewhere" "$BIN" --db >/dev/null 2>&1 || CODE=$?
  assert_present "$TMP_ROOT/elsewhere/model-picker/aa.sqlite" "FM_DATA_OVERRIDE selects the data directory"
  CODE=0
  FM_HOME="$home" FM_MODEL_PICKER_DATA="$TMP_ROOT/explicit" "$BIN" --db >/dev/null 2>&1 || CODE=$?
  assert_present "$TMP_ROOT/explicit/aa.sqlite" "FM_MODEL_PICKER_DATA wins"
  pass "model picker: data root follows FM_MODEL_PICKER_DATA, then the data directory, then FM_HOME"
}

test_calibration_first_and_preserved() {
  local data=$TMP_ROOT/calib db tables
  run "$data" --db
  expect_code 0 "$CODE" "--db on an empty root"
  db=$data/aa.sqlite
  tables=$(sql "$db" "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by rowid" | paste -sd, -)
  assert_equals "dispatch_log,outcomes,models,metrics,observations,reconcile_runs,slug_status" "$tables" "calibration tables are created before the matrix"
  assert_contains "$(sql "$db" "select name from pragma_table_info('dispatch_log')" | paste -sd, -)" "mode,task_type,work_type,complexity_score,chosen_worker,chosen_validator,effort,rule_worker,rule_validator,rule_effort,jev_raw_payload" "dispatch_log carries the shadow columns"
  PYTHONPATH="$ROOT/bin" PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys
from fm_model_picker import aadb
c = aadb.open_db(sys.argv[1])
i = aadb.log_dispatch(c, mode="shadow", chosen_worker="w", rule_worker="r", jev_raw_payload="  raw\r\n")
aadb.record_outcome(c, i, quality=0.8, accepted=True)
' "$db"
  run "$data" --db
  expect_code 0 "$CODE" "second --db"
  assert_equals "  raw" "$(sql "$db" "select rtrim(jev_raw_payload, char(13,10)) from dispatch_log")" "a matrix rebuild keeps dispatch rows byte for byte"
  assert_equals "1" "$(sql "$db" "select count(*) from outcomes")" "a matrix rebuild keeps outcomes"
  assert_equals "1" "$(sql "$db" "pragma user_version")" "schema version is recorded"
  pass "model picker: calibration tables come first and survive a matrix rebuild"
}

seed_cache() {  # <data-dir>
  mkdir -p "$1/raw"
  python3 -I - "$1/raw" <<'PY'
import json, sys
from pathlib import Path
raw = Path(sys.argv[1])
def obj(slug, **extra):
    return {"id": "id-" + slug, "slug": slug, "name": slug.upper(), "creator": {"name": "Acme", "slug": "acme"}, **extra}
def page(objs):
    head = "".join(f"<th>{o['creator']['name']} {o['name']}</th>" for o in objs)
    cells = "".join(f"<td>{o.get('intelligenceIndex', 0):.0f}</td>" for o in objs)
    table = f"<table><thead><tr><th></th>{head}</tr></thead><tbody><tr><td>Intelligence Index</td>{cells}</tr></tbody></table>"
    return "<html>" + table + "<script>" + json.dumps({"models": objs}, separators=(",", ":")).replace('"', '\\"') + "</script></html>"
def put(name, objs, ts):
    (raw / f"models_comparisons_{name}.html").write_text(page(objs))
    if ts:
        (raw / f"models_comparisons_{name}.html.ts").write_text(ts)
put("m-a-vs-m-b", [obj("m-a", intelligenceIndex=50.4, gpqa=0.85), obj("m-b", intelligenceIndex=40.2)], "2026-10-15T20:00:00Z")
put("models=m-x", [obj("m-x", intelligenceIndex=1)], "2026-10-15T20:00:00Z")
put("m-old-vs-m-older", [obj("m-old", intelligenceIndex=1), obj("m-older", intelligenceIndex=1)], None)
PY
}

test_seeded_cache_ingest() {
  local data=$TMP_ROOT/seeded
  seed_cache "$data"
  run "$data" --db
  expect_code 0 "$CODE" "--db on a seeded cache"
  assert_equals "m-a|m-b" "$(sql "$data/aa.sqlite" "select group_concat(slug, '|') from (select slug from models order by slug)")" "only exact-slug pages with a fetch time are ingested"
  assert_equals "2026-10-15T20:00:00Z" "$(sql "$data/aa.sqlite" "select distinct observed_at from observations")" "the real fetch time is kept"
  assert_equals "0.85" "$(sql "$data/aa.sqlite" "select o.value from observations o join metrics x on x.id=o.metric_id where x.canonical_id='gpqadiamond'")" "a payload series is stored at full precision"
  assert_contains "$OUT" "row counts per source match the counts read" "load counts are printed and asserted"
  assert_grep "| gpqadiamond | embedded | 1 | captured |" "$data/coverage.md" "coverage.md is recomputed from the loaded rows"
  assert_present "$data/projection/m-a.json" "one JSON projection per catalog model"
  run "$data" --chartdiff --replay
  expect_code 0 "$CODE" "chart-diff over agreeing values"
  assert_contains "$OUT" "chart-diff: TRUSTED (0 mismatches in 2 compared values" "agreement is counted, not assumed"
  sed -i.bak 's|<td>50</td>|<td>99</td>|' "$data/raw/models_comparisons_m-a-vs-m-b.html"
  run "$data" --chartdiff --replay
  expect_code 3 "$CODE" "chart-diff exit code on an UNTRUSTED verdict"
  assert_contains "$OUT" "chart-diff: UNTRUSTED (1 mismatches" "a wrong table value blocks trust"
  assert_grep "shown value differs from payload" "$data/reconcile.md" "the mismatch is listed, not summarized away"
  assert_contains "$(cat "$data/verdict.json")" '"verdict": "UNTRUSTED"' "machine-readable verdict"
  pass "model picker: seeded cache ingests by exact slug; a wrong table value blocks trust"
}

test_empty_compared_set_is_not_zero_disagreements() {
  local data=$TMP_ROOT/empty
  run "$data" --chartdiff --replay
  expect_code 3 "$CODE" "chart-diff on an empty cache"
  assert_contains "$OUT" "chart-diff: UNTRUSTED (nothing was compared" "an empty compared set is never TRUSTED"
  assert_no_grep "0 disagreements" "$data/reconcile.md" "an empty compared set never claims zero disagreements"
  assert_grep "not compared" "$data/reconcile.md" "uncompared metrics are listed as not compared"
  pass "model picker: an empty compared set reads not compared and stays UNTRUSTED"
}

test_network_off_is_a_clean_error() {
  run "$TMP_ROOT/offline" --embedded-only --sweep
  expect_code 2 "$CODE" "--embedded-only without a cache"
  assert_contains "$ERR" "error:" "the missing cache is reported"
  assert_not_contains "$ERR" "Traceback" "no traceback"
  pass "model picker: network off with an empty cache is a clean error"
}

test_selftest_and_help
test_data_root_resolution
test_calibration_first_and_preserved
test_seeded_cache_ingest
test_empty_compared_set_is_not_zero_disagreements
test_network_off_is_a_clean_error
