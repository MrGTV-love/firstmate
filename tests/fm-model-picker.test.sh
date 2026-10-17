#!/usr/bin/env bash
# Model-picker collector behavior through bin/fm-model-picker.sh: the fixture suite, the
# data-root contract, calibration tables created first and never touched by a matrix rebuild,
# exact-slug ingest from a seeded cache (banned route and unknown-age pages ignored), the
# chart-diff verdict on an empty compared set, a clean error when the network is off, unit
# cells stored as numbers with a unit, a verdict that goes UNTRUSTED when the matrix is rebuilt
# without chart-diff, coverage that follows the cache and never an older database, a payload slug
# that cannot name a file outside projection/, a model whose attributes come from its newest page,
# a fetched page that does not parse never replacing the last good copy, a verdict that names the
# leaderboard cells it did not compare, one 404 line per URL, and which network
# requests and exit code each flag and each outage produce against a scripted site.
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
  assert_equals "dispatch_log,outcomes,models,metrics,observations,reconcile_runs" "$tables" "calibration tables are created before the matrix"
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

seed_units() {  # <data-dir>: one compare page whose table rows carry every unit family
  mkdir -p "$1/raw"
  python3 -I - "$1/raw" <<'PY'
import json, sys
from pathlib import Path
raw = Path(sys.argv[1])
objs = [{"id": "id-" + s, "slug": s, "name": s.upper(), "creator": {"name": "Acme", "slug": "acme"}, "intelligenceIndex": i,
         "price1mBlended7To2To1": blended, "price1mInputTokens": inp, "price1mOutputTokens": out, "cacheHitPrice": cache,
         "openness": {"opennessIndex": 70.5}}
        for s, i, blended, inp, out, cache in (("m-a", 50.4, 2.5, 3.0, 15.0, 0.3), ("m-b", 40.2, 1.25, 1.0, 5.0, 0.1))]
rows = [
    ("Intelligence Index", "50", "40"),
    ("Price per 1M Tokens", "$2.50", "$1.25"),
    ("Input Price per 1M Tokens", "$3.00", "$1.00"),
    ("Output Price per 1M Tokens", "$15.00", "$5.00"),
    ("Cache Hit Price per 1M Tokens", "$0.30", "$0.10"),
    ("Reasoning Tokens per Task", "37k", "84k"),
    ("Output Tokens to Run Intelligence Index", "260M", "8M"),
    ("Output Speed", "95 tokens/s", "121 tokens/s"),
    ("Time to First Token", "10.19s", "250ms"),
    ("Context Window", "128k tokens ~192 A4 pages of size 12 Arial font", "1000k tokens ~1,500 A4 pages of size 12 Arial font"),
    ("Total parameters", "1.6T", "37B"),
    ("Active parameters", "3.6B", "3B"),
    ("Cost per Task", "$5.98", "$0.02"),
    ("Cost to Run Intelligence Index", "$8,708", "$0"),
    ("Reasoning", "Yes", "No"),
    ("Release Date", "September 2026", "April 2026"),
]
head = "".join(f"<th>Acme {o['name']}</th>" for o in objs)
body = "".join(f"<tr><td>{r[0]}</td><td>{r[1]}</td><td>{r[2]}</td></tr>" for r in rows)
page = (f"<html><table><thead><tr><th></th>{head}</tr></thead><tbody>{body}</tbody></table><script>"
        + json.dumps({"models": objs}, separators=(",", ":")).replace('"', '\\"') + "</script></html>")
(raw / "models_comparisons_m-a-vs-m-b.html").write_text(page)
(raw / "models_comparisons_m-a-vs-m-b.html.ts").write_text("2026-10-15T20:00:00Z")
PY
}

metric_row() {  # <db> <label>: unit|scale|values of one comparison-table metric
  sql "$1" "select x.unit, x.scale, group_concat(o.value, ',') from (select * from observations order by value) o join metrics x on x.id=o.metric_id where o.source='comparison-table' and x.label='$2' group by x.id"
}

test_unit_cells_are_stored_as_numbers() {
  local data=$TMP_ROOT/units db
  seed_units "$data"
  run "$data" --db
  expect_code 0 "$CODE" "--db on unit-bearing cells"
  db=$data/aa.sqlite
  assert_equals "0" "$(sql "$db" "select count(*) from observations o join metrics x on x.id=o.metric_id where x.label='Reasoning Tokens per Task' and o.value is null")" "k-suffixed token cells are not NULL"
  assert_equals "count|quantity|37000.0,84000.0" "$(metric_row "$db" "Reasoning Tokens per Task")" "k suffix expands to a count"
  assert_equals "count|quantity|8000000.0,260000000.0" "$(metric_row "$db" "Output Tokens to Run Intelligence Index")" "M suffix expands to a count"
  assert_equals "count|quantity|3000000000.0,3600000000.0" "$(metric_row "$db" "Active parameters")" "B suffix expands to a count"
  assert_equals "count|quantity|37000000000.0,1600000000000.0" "$(metric_row "$db" "Total parameters")" "B and T suffixes share one unit"
  assert_equals "tokens/s|quantity|95.0,121.0" "$(metric_row "$db" "Output Speed")" "tokens/s is a unit"
  assert_equals "s|quantity|0.25,10.19" "$(metric_row "$db" "Time to First Token")" "s and ms are both seconds"
  assert_equals "tokens|quantity|128000.0,1000000.0" "$(metric_row "$db" "Context Window")" "a context-window cell reads its tokens"
  assert_equals "usd|quantity|0.02,5.98" "$(metric_row "$db" "Cost per Task")" "a dollar cell has a unit"
  assert_equals "usd|quantity|0.0,8708.0" "$(metric_row "$db" "Cost to Run Intelligence Index")" "dollars with a thousands comma"
  assert_equals "usd|quantity|1.25,2.5" "$(metric_row "$db" "Price per 1M Tokens")" "a price series states the same scale as a cost cell"
  assert_equals "points|raw|40.0,50.0" "$(metric_row "$db" "Intelligence Index")" "a bare number takes the unit its source series states"
  assert_equals "None|text|None" "$(metric_row "$db" "Reasoning")" "a text row has no unit, a text scale and no value"
  assert_equals "None|text|None" "$(metric_row "$db" "Release Date")" "a date row has no unit, a text scale and no value"
  assert_equals "4" "$(sql "$db" "select count(*) from observations o join metrics x on x.id=o.metric_id where x.label in ('Reasoning', 'Release Date') and o.value is null and o.raw is not null")" "the text cells stay in the matrix as raw text"
  python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))["metrics"]
assert "reasoning" not in m and "releasedate" not in m, sorted(m)
for cid in ("reasoningtokenspertask", "outputspeed", "timetofirsttoken", "costpertask", "contextwindow", "totalparameters"):
    assert m[cid]["value"] is not None and m[cid]["unit"] and m[cid]["scale"] == "quantity", (cid, m[cid])
assert m["reasoningtokenspertask"]["value"] == 84000.0 and m["reasoningtokenspertask"]["unit"] == "count"
assert m["timetofirsttoken"]["unit"] == "s" and m["outputspeed"]["unit"] == "tokens/s" and m["costpertask"]["unit"] == "usd"
assert m["openness-index"]["value"] == 70.5 and m["openness-index"]["unit"] == "points" and m["openness-index"]["source"] == "embedded", m["openness-index"]
usd = {cid: v["scale"] for cid, v in m.items() if v["unit"] == "usd"}
assert usd == {"priceper1mtokens": "quantity", "inputpriceper1mtokens": "quantity", "outputpriceper1mtokens": "quantity",
               "cachehitpriceper1mtokens": "quantity", "costpertask": "quantity", "costtorunintelligenceindex": "quantity"}, usd
' "$data/projection/m-b.json" || fail "the projection carries the unit-bearing metrics, every dollar metric as quantity, and no text rows"
  pass "model picker: unit-bearing cells are stored as numbers with a unit; text rows stay out of the projections"
}

seed_discovery() {  # <data-dir>: a cached sitemap and selector catalog naming m-a and m-b
  mkdir -p "$1/raw"
  printf '%s' '<urlset><url><loc>https://artificialanalysis.ai/models/m-a</loc></url><url><loc>https://artificialanalysis.ai/models/m-b</loc></url></urlset>' >"$1/raw/sitemap.xml.html"
  printf '%s' '<html>{"slug":"m-a","name":"M-A","deprecated":false,"releaseDate":"2026-01-01","creator":{"slug":"acme","name":"Acme"}}{"slug":"m-b","name":"M-B","deprecated":false,"releaseDate":"2026-01-01","creator":{"slug":"acme","name":"Acme"}}</html>' >"$1/raw/models_comparisons.html"
}

seed_pages() {  # <data-dir>: a cached evaluation page and cohort model page for every page an acquisition run asks for
  PYTHONPATH="$ROOT/bin" PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys
from pathlib import Path
from fm_model_picker import collect
collect.configure(sys.argv[1])
for path in ["/evaluations/" + s for s in collect.EVAL_SLUGS] + ["/models/" + s for s in collect.COHORT]:
    f = collect.cache_file(path)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text("<html><table><tr><td>1</td><td>Acme</td><td>M-A</td><td>1500</td></tr></table></html>" if "/evaluations/" in path
                 else "<html>58 Artificial Analysis Intelligence Index 95 Output tokens per second \x241.50 Cost per Intelligence Index task In \x243.00Out \x2415.00</html>")
    Path(str(f) + ".ts").write_text("2026-10-15T20:00:00Z")
' "$1"
}

test_rebuild_without_chartdiff_is_untrusted() {
  local data=$TMP_ROOT/stale
  seed_cache "$data"
  seed_discovery "$data"
  seed_pages "$data"
  run "$data" --sweep --embedded-only --chartdiff
  expect_code 0 "$CODE" "day 1: sweep with chart-diff"
  assert_contains "$OUT" "chart-diff: TRUSTED" "day 1 is judged"
  assert_contains "$(cat "$data/verdict.json")" '"verdict": "TRUSTED"' "day 1 verdict is TRUSTED"
  sed -i.bak 's|<td>50</td>|<td>99</td>|' "$data/raw/models_comparisons_m-a-vs-m-b.html"
  run "$data" --sweep --embedded-only --db
  expect_code 0 "$CODE" "day 2: sweep and database rebuild without chart-diff"
  assert_contains "$(cat "$data/verdict.json")" '"verdict": "UNTRUSTED"' "a rebuild without chart-diff cannot keep yesterday's TRUSTED"
  assert_contains "$(cat "$data/verdict.json")" '"reason": "matrix rebuilt without chart-diff"' "the verdict names why"
  assert_contains "$(cat "$data/verdict.json")" '"ran_at": "20' "the verdict carries the time"
  assert_contains "$OUT" "verdict.json is UNTRUSTED" "the rebuild says so"
  run "$data" --db
  assert_contains "$(cat "$data/verdict.json")" '"verdict": "UNTRUSTED"' "a plain --db rebuild is UNTRUSTED too"
  sed -i.bak 's|<td>99</td>|<td>50</td>|' "$data/raw/models_comparisons_m-a-vs-m-b.html"
  run "$data" --chartdiff --replay
  expect_code 0 "$CODE" "day 3: chart-diff over the rebuilt matrix"
  assert_contains "$(cat "$data/verdict.json")" '"verdict": "TRUSTED"' "only chart-diff restores a verdict"
  pass "model picker: a matrix rebuilt without chart-diff turns a TRUSTED verdict UNTRUSTED until chart-diff runs"
}

add_pair() {  # <data-dir> <slug> <slug>: a cached compare page for two models that both carry gpqa
  python3 -I - "$1/raw" "$2" "$3" <<'PY'
import json, sys
from pathlib import Path
raw, a, b = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
objs = [{"id": "id-" + s, "slug": s, "name": s.upper(), "creator": {"name": "Acme", "slug": "acme"}, "intelligenceIndex": 10, "gpqa": 0.5}
        for s in (a, b)]
head = "".join(f"<th>Acme {o['name']}</th>" for o in objs)
cells = "".join("<td>10</td>" for _ in objs)
page = (f"<html><table><thead><tr><th></th>{head}</tr></thead><tbody><tr><td>Intelligence Index</td>{cells}</tr></tbody></table><script>"
        + json.dumps({"models": objs}, separators=(",", ":")).replace('"', '\\"') + "</script></html>")
(raw / f"models_comparisons_{a}-vs-{b}.html").write_text(page)
(raw / f"models_comparisons_{a}-vs-{b}.html.ts").write_text("2026-10-15T21:00:00Z")
PY
}

test_coverage_follows_the_cache_not_the_database() {
  local data=$TMP_ROOT/cov
  seed_cache "$data"
  seed_pages "$data"
  run "$data" --db
  expect_code 0 "$CODE" "day 1: the database is built"
  assert_grep "| gpqadiamond | embedded | 1 | captured |" "$data/coverage.md" "day 1 coverage counts the cached models"
  add_pair "$data" m-c m-d
  run "$data" --evals-only --replay
  expect_code 0 "$CODE" "day 2: acquisition without a database rebuild"
  assert_grep "| gpqadiamond | embedded | 3 | captured |" "$data/coverage.md" "an acquisition run recomputes coverage from the cache, not from the day-1 database"
  add_pair "$data" m-e m-f
  run "$data" --coverage-only
  expect_code 0 "$CODE" "--coverage-only"
  assert_grep "| gpqadiamond | embedded | 5 | captured |" "$data/coverage.md" "--coverage-only never reads an older database"
  assert_equals "2" "$(sql "$data/aa.sqlite" "select count(*) from models")" "neither run rebuilt the database"
  pass "model picker: coverage.md follows the cache, never an older database"
}

test_unsafe_payload_slug_is_rejected() {
  local data=$TMP_ROOT/slug
  mkdir -p "$data/raw"
  printf '%s' '<html>"initialModels":[{"id":"i1","slug":"m-ok","name":"M-OK","creator":{"name":"Acme","slug":"acme"},"gpqa":0.5},{"id":"i2","slug":"../escape","name":"ESC","creator":{"name":"Acme","slug":"acme"},"gpqa":0.4}]</html>' >"$data/raw/evaluations_gpqa-diamond.html"
  printf '2026-10-15T20:00:00Z' >"$data/raw/evaluations_gpqa-diamond.html.ts"
  run "$data" --db
  expect_code 0 "$CODE" "--db with an unsafe slug in a payload"
  assert_absent "$data/escape.json" "a payload slug never names a file outside projection/"
  assert_present "$data/projection/m-ok.json" "the plain-word model in the same payload is kept"
  assert_equals "m-ok" "$(sql "$data/aa.sqlite" "select group_concat(slug) from models")" "the unsafe slug is not a model"
  pass "model picker: a payload slug that is not a plain word is rejected, not written as a file name"
}

FLAG_N=0
FLAG_PY=$(cat <<'PY'
import contextlib, email.message, http.client, io, os, sys, urllib.error
from pathlib import Path
from fm_model_picker import collect

root, flags = sys.argv[1], sys.argv[2:]
collect.configure(root)
mode = os.environ.get("SITE", "")
slugs = ["m-a", "m-b"] if mode == "maintenance" else ["m-a", "m-b", "m-new"] + ([f"x-{i:02d}" for i in range(17)] if mode in ("outage", "scattered") else [])
SITEMAP = "<urlset>" + "".join(f"<url><loc>{collect.BASE}/models/{s}</loc></url>" for s in slugs) + "</urlset>"
CATALOG = "<html>" + "".join(
    '{"slug":"%s","name":"%s","deprecated":false,"releaseDate":"2026-01-01","creator":{"slug":"acme","name":"Acme"}}' % (s, s.upper())
    for s in ("m-a", "m-b")) + "</html>"


DOWN = "<html><body>Down for maintenance</body></html>"
EVAL_PAGE = "<html><table><tr><td>1</td><td>Acme</td><td>M-A</td><td>1500</td></tr></table></html>"
COHORT_PAGE = "<html>58 Artificial Analysis Intelligence Index 95 Output tokens per second $1.50 Cost per Intelligence Index task In $3.00Out $15.00</html>"


def site(path):
    if ((mode == "maintenance" and path.startswith("/models/comparisons/"))
            or (mode == "evals-blank" and path.startswith("/evaluations/"))
            or (mode == "sitemap-blank" and path == "/sitemap.xml")
            or (mode == "catalog-blank" and path == "/models/comparisons")
            or (mode == "cohort-blank" and path.startswith("/models/") and not path.startswith("/models/comparisons"))):
        return DOWN
    if mode == "refetch-other" and path == "/models/comparisons/m-a-vs-m-b":
        return collect._fake_page([collect._fake_obj("m-x", intelligenceIndex=30.0), collect._fake_obj("m-y", intelligenceIndex=30.0)])
    if path == "/sitemap.xml":
        return SITEMAP
    if path == "/models/comparisons":
        return CATALOG
    if path.startswith("/models/comparisons/") and mode == "wrong-models":
        return collect._fake_page([collect._fake_obj("m-zzz"), collect._fake_obj("m-yyy")])
    if path.startswith("/models/comparisons/"):
        return collect._fake_page([collect._fake_obj(n, intelligenceIndex=30.0) for n in path[len("/models/comparisons/"):].split("-vs-")])
    if path.startswith("/evaluations/"):
        return EVAL_PAGE
    return COHORT_PAGE


def put(path, text):
    f = collect.cache_file(path)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(text, encoding="utf-8")
    Path(str(f) + ".ts").write_text("2026-01-01T00:00:00Z", encoding="utf-8")


for slug in collect.EVAL_SLUGS:
    put("/evaluations/" + slug, EVAL_PAGE)
for slug in collect.COHORT:
    put("/models/" + slug, COHORT_PAGE)
put("/sitemap.xml", SITEMAP)
put("/models/comparisons", CATALOG)
put("/models/comparisons/m-a-vs-m-b", collect._fake_page([collect._fake_obj(n, intelligenceIndex=30.0) for n in ("m-a", "m-b")]))
if mode == "refetch-other":
    put("/models/comparisons/m-c-vs-m-d", collect._fake_page([collect._fake_obj(n, intelligenceIndex=30.0) for n in ("m-c", "m-d")]))
    bad = collect.cache_file("/models/comparisons/m-a-vs-m-b")
    bad.write_text(bad.read_text(encoding="utf-8").replace("<td>30</td>", "<td>99</td>"), encoding="utf-8")
if os.environ.get("DROP"):
    collect.cache_file(os.environ["DROP"]).unlink()

requested = []


class Resp:
    def __init__(self, body):
        self.body = body

    def read(self):
        if isinstance(self.body, Exception):
            raise self.body
        return self.body.encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


dropped = []


def opener(req, timeout=None):
    path = req.full_url[len(collect.BASE):]
    requested.append(path)
    if ((mode == "outage" and path.startswith("/models/comparisons/"))
            or (mode == "scattered" and path.startswith("/models/comparisons/") and "x-09" not in path)
            or (mode == "evals-down" and path.startswith("/evaluations/"))
            or (mode == "cohort-down" and path.startswith("/models/") and not path.startswith("/models/comparisons"))):
        raise urllib.error.HTTPError(req.full_url, 500, "x", email.message.Message(), None)
    if mode == "unsupported" and path.startswith("/models/comparisons/") and "m-new" in path:
        raise urllib.error.HTTPError(req.full_url, 404, "x", email.message.Message(), None)
    if mode == "dropped" and path == "/models/comparisons/m-new" and not dropped:
        dropped.append(path)
        return Resp(http.client.IncompleteRead(b"par"))
    return Resp(site(path))


collect._urlopen, collect._sleep = opener, lambda seconds: None
sys.argv = ["fm-model-picker", *flags]
err = io.StringIO()
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
    code = collect.cli()
for path in requested:
    print("REQ", path)
for line in err.getvalue().splitlines():
    print("ERR", line)
print("EXIT", code)
PY
)

flag_run() {  # <flags...>: a fresh seeded data root, a scripted site; sets OUT to the REQ lines and the EXIT line
  local data=${FLAG_ROOT:-$TMP_ROOT/flags-$((++FLAG_N))}
  CODE=0
  OUT=$(SITE=${SITE:-} PYTHONPATH="$ROOT/bin" PYTHONDONTWRITEBYTECODE=1 python3 -c "$FLAG_PY" "$data" "$@") || CODE=$?
  expect_code 0 "$CODE" "flag run: $*"
  FLAG_DATA=$data
}

requests_matching() {  # <grep pattern>: how many requests of the last flag run match
  printf '%s\n' "$OUT" | grep -c -- "$1" || true
}

test_flags_decide_which_requests_are_made() {
  flag_run
  assert_equals "33" "$(requests_matching '^REQ /evaluations/')" "no flags: every evaluation page is revalidated"
  assert_equals "0" "$(requests_matching '^REQ /models/')" "no flags: cached cohort model pages are not revalidated"
  assert_equals "0" "$(requests_matching '^REQ /sitemap.xml')" "no flags: no sweep"
  flag_run --evals-only
  assert_equals "33" "$(requests_matching '^REQ /evaluations/')" "--evals-only revalidates the evaluation pages"
  assert_equals "33" "$(requests_matching '^REQ')" "--evals-only skips the cohort and the sweep"
  flag_run --replay
  assert_equals "0" "$(requests_matching '^REQ')" "--replay: no revalidation"
  flag_run --evals-only --replay
  assert_equals "0" "$(requests_matching '^REQ')" "--evals-only --replay reads the cache"
  flag_run --sweep
  assert_equals "33" "$(requests_matching '^REQ /evaluations/')" "--sweep revalidates the evaluation pages"
  assert_equals "1" "$(requests_matching '^REQ /sitemap.xml$')" "--sweep revalidates the sitemap"
  assert_equals "1" "$(requests_matching '^REQ /models/comparisons$')" "--sweep revalidates the selector catalog"
  assert_equals "1" "$(requests_matching '^REQ /models/comparisons/m-new$')" "--sweep fetches the slug without values"
  assert_equals "0" "$(requests_matching '^REQ /models/comparisons/m-a')" "--sweep leaves cached slugs alone"
  flag_run --sweep --replay
  assert_equals "REQ /models/comparisons/m-new
EXIT 0" "$OUT" "--sweep --replay: the network is used only for the slug without values"
  flag_run --sweep --embedded-only
  assert_equals "EXIT 0" "$OUT" "--embedded-only makes no request"
  assert_contains "$(cat "$FLAG_DATA/snapshot.json")" "not fetched: network use is off" "--embedded-only records why the slug has no values"
  flag_run --sweep --replay --stale-after-hours 1
  assert_equals "1" "$(requests_matching '^REQ /models/comparisons/m-a-vs-m-b-vs-m-new$')" "--stale-after-hours re-fetches a cached compare page older than the limit"
  flag_run --replay --models m-zz
  assert_equals "REQ /models/m-zz
EXIT 0" "$OUT" "--models replaces the cohort, and a cohort page is fetched only on a cache miss"
  flag_run --coverage-only
  assert_equals "EXIT 0" "$OUT" "--coverage-only makes no request"
  assert_present "$FLAG_DATA/coverage.md" "--coverage-only writes coverage.md"
  flag_run --db
  assert_equals "EXIT 0" "$OUT" "--db makes no request"
  assert_present "$FLAG_DATA/aa.sqlite" "--db writes the database"
  flag_run --chartdiff
  assert_equals "EXIT 0" "$OUT" "--chartdiff re-fetches nothing when the paths agree"
  assert_contains "$(cat "$FLAG_DATA/verdict.json")" '"verdict": "TRUSTED"' "--chartdiff writes the verdict"
  pass "model picker: each flag makes the network requests its header promises"
}

test_incomplete_acquisition_exits_4_after_writing_outputs() {
  SITE=outage flag_run --sweep --replay --db
  assert_contains "$OUT" "EXIT 4" "a sweep that stops after three straight failures does not exit 0"
  assert_contains "$OUT" "ERR INCOMPLETE" "the incomplete run says so on stderr"
  assert_contains "$OUT" "sweep stopped after 3 consecutive fetch failures" "and says why"
  assert_contains "$(cat "$FLAG_DATA/snapshot.json")" "sweep stopped after 3 consecutive fetch failures" "the snapshot records the stop"
  assert_present "$FLAG_DATA/aa.sqlite" "the database was still built"
  assert_present "$FLAG_DATA/projection/m-a.json" "the projections were still written"
  assert_present "$FLAG_DATA/coverage.md" "coverage.md was still written"
  SITE=evals-down flag_run --evals-only
  assert_contains "$OUT" "EXIT 4" "evaluation pages that cannot be fetched do not exit 0"
  assert_equals "33" "$(printf '%s\n' "$OUT" | grep -c -- '^ERR .*/evaluations/' || true)" "every failed evaluation page is named"
  assert_present "$FLAG_DATA/snapshot.json" "the snapshot was still written"
  SITE=cohort-down flag_run --replay --models m-zz
  assert_contains "$OUT" "EXIT 4" "a model page that cannot be fetched does not exit 0"
  assert_contains "$OUT" "ERR   /models/m-zz" "the failed model page is named"
  flag_run --replay
  assert_contains "$OUT" "EXIT 0" "a complete acquisition exits 0"
  assert_not_contains "$OUT" "ERR" "and prints no incomplete notice"
  pass "model picker: an acquisition that fetched less than it set out to exits 4 once its outputs are written"
}

test_scattered_fetch_failures_exit_4() {
  SITE=scattered flag_run --sweep --replay --db
  assert_contains "$OUT" "EXIT 4" "failed batches between successes do not exit 0"
  assert_equals "3" "$(requests_matching '^ERR   /models/comparisons/.*: HTTP 500$')" "every failed batch is named once"
  assert_contains "$OUT" "ERR   /models/comparisons/x-04-vs-x-05-vs-x-06-vs-x-07-vs-x-08: HTTP 500" "the failed page is named"
  assert_not_contains "$OUT" "sweep stopped" "the streak never reached three, so this is not a stopped sweep"
  assert_contains "$(cat "$FLAG_DATA/snapshot.json")" '"stopped": null' "the snapshot says the sweep ran to the end"
  assert_contains "$(cat "$FLAG_DATA/snapshot.json")" "fetch failed: /models/comparisons/x-14-vs-x-15-vs-x-16: HTTP 500" "the snapshot records the slug-level reason"
  assert_present "$FLAG_DATA/aa.sqlite" "the database was still built"
  assert_present "$FLAG_DATA/projection/m-a.json" "the projections were still written"
  flag_run --sweep --embedded-only
  assert_equals "EXIT 0" "$OUT" "a sweep that fetches nothing on purpose is not incomplete"
  pass "model picker: scattered fetch failures exit 4, a cache-only sweep exits 0"
}

snapshot_failures() {  # <data-dir>: the sweep's failure record held in snapshot.json
  python3 -I -c 'import json, sys; s = json.load(open(sys.argv[1])); print(json.dumps([s["slug_status"], s["sweep_failures"], s["sweep"]], sort_keys=True))' "$1/snapshot.json"
}

test_failure_record_lives_in_snapshot_only() {
  local data=$TMP_ROOT/failure-record before
  FLAG_ROOT=$data
  SITE=outage flag_run --sweep --replay
  assert_contains "$OUT" "EXIT 4" "the outage sweep is incomplete"
  before=$(snapshot_failures "$data")
  assert_contains "$before" "not fetched: sweep stopped after 3 consecutive fetch failures" "the sweep recorded why slugs have no values"
  flag_run --replay
  assert_contains "$OUT" "EXIT 0" "a plain replay reads the cache"
  assert_equals "$before" "$(snapshot_failures "$data")" "a plain replay carries the sweep's failures forward unchanged"
  flag_run --db
  assert_contains "$OUT" "EXIT 0" "--db rebuilds the matrix"
  assert_equals "0" "$(sql "$data/aa.sqlite" "select count(*) from sqlite_master where name='slug_status'")" "the database holds no slug_status table"
  assert_equals "$before" "$(snapshot_failures "$data")" "--db leaves the sweep's failures, with their original values, in snapshot.json"
  unset FLAG_ROOT
  pass "model picker: the sweep's failure record lives in snapshot.json and the database carries no slug_status table"
}

test_unparseable_compare_page_keeps_last_good_copy() {
  local data=$TMP_ROOT/rejected
  FLAG_ROOT=$data
  flag_run --sweep --replay --db
  assert_contains "$OUT" "EXIT 0" "day 1: a good sweep"
  assert_present "$data/projection/m-a.json" "day 1 projects m-a"
  SITE=maintenance flag_run --sweep --replay --stale-after-hours 1 --db
  assert_contains "$OUT" "EXIT 4" "day 2: a 200 page that does not parse does not exit 0"
  assert_contains "$OUT" "ERR INCOMPLETE" "the incomplete run says so on stderr"
  assert_contains "$OUT" "ERR   /models/comparisons/m-a-vs-m-b: page rejected: no table" "the rejected page is named with its reason"
  assert_equals "0" "$(grep -c 'Down for maintenance' "$data/raw/models_comparisons_m-a-vs-m-b.html" || true)" "the cached copy is still the last good page"
  assert_equals "2026-01-01T00:00:00Z" "$(cat "$data/raw/models_comparisons_m-a-vs-m-b.html.ts")" "and keeps its real fetch time"
  assert_present "$data/projection/m-a.json" "the old projection files stay"
  assert_present "$data/projection/m-b.json" "the old projection files stay"
  assert_equals "failure|no table" "$(python3 -I -c 'import json, sys; s = json.load(open(sys.argv[1]))["slug_status"]["m-a"]; print(s["status"] + "|" + s["reason"])' "$data/snapshot.json")" "the failure record is written"
  FLAG_ROOT=$TMP_ROOT/wrong-models
  SITE=wrong-models flag_run --sweep --replay
  assert_contains "$OUT" "EXIT 4" "a page that holds other models than the URL names does not exit 0"
  assert_contains "$OUT" "ERR   /models/comparisons/m-new: page rejected: identity mismatch" "the identity mismatch is named"
  assert_absent "$FLAG_DATA/raw/models_comparisons_m-new.html" "a page with the wrong models never enters the cache"
  assert_contains "$(cat "$FLAG_DATA/snapshot.json")" "identity mismatch" "the snapshot records the identity mismatch"
  unset FLAG_ROOT
  pass "model picker: a compare page that does not parse is rejected, exits 4, and leaves the last good copy and projections"
}

test_unsupported_slug_404_is_not_incomplete() {
  SITE=unsupported flag_run --sweep --replay
  assert_contains "$OUT" "EXIT 0" "an unsupported slug (404 alone and paired with an anchor) is a recorded reason, not a failure"
  assert_not_contains "$OUT" "ERR" "and prints no incomplete notice"
  assert_contains "$(cat "$FLAG_DATA/snapshot.json")" "unsupported slug (404 alone and paired with an anchor)" "the reason is recorded"
  pass "model picker: an unsupported-slug 404 still exits 0"
}

test_unparseable_eval_page_and_sitemap_are_rejected() {
  SITE=evals-blank flag_run --evals-only
  assert_contains "$OUT" "EXIT 4" "evaluation pages that load with no table or payload do not exit 0"
  assert_equals "33" "$(printf '%s\n' "$OUT" | grep -c -- '^ERR .*/evaluations/.*: page rejected: no table or payload$' || true)" "every rejected evaluation page is named"
  assert_equals "0" "$(grep -c 'Down for maintenance' "$FLAG_DATA/raw/evaluations_aa-3d.html" || true)" "the cached evaluation page is still the last good copy"
  assert_equals "2026-01-01T00:00:00Z" "$(cat "$FLAG_DATA/raw/evaluations_aa-3d.html.ts")" "and keeps its real fetch time"
  SITE=sitemap-blank flag_run --sweep
  assert_contains "$OUT" "EXIT 4" "a sitemap that does not parse does not exit 0"
  assert_contains "$OUT" "ERR   /sitemap.xml: page rejected: no <loc> entries" "the rejected sitemap is named"
  assert_equals "0" "$(grep -c 'Down for maintenance' "$FLAG_DATA/raw/sitemap.xml.html" || true)" "the cached sitemap is still the last good copy"
  assert_equals "2026-01-01T00:00:00Z" "$(cat "$FLAG_DATA/raw/sitemap.xml.html.ts")" "and keeps its real fetch time"
  assert_contains "$(cat "$FLAG_DATA/snapshot.json")" '"m-new"' "the sweep went on with the last good sitemap"
  SITE=catalog-blank flag_run --sweep
  assert_contains "$OUT" "EXIT 4" "a selector catalog that does not parse does not exit 0"
  assert_contains "$OUT" "ERR   /models/comparisons: page rejected: no model catalog" "the rejected catalog is named"
  assert_equals "0" "$(grep -c 'Down for maintenance' "$FLAG_DATA/raw/models_comparisons.html" || true)" "the cached catalog is still the last good copy"
  assert_equals "2026-01-01T00:00:00Z" "$(cat "$FLAG_DATA/raw/models_comparisons.html.ts")" "and keeps its real fetch time"
  DROP=/sitemap.xml SITE=sitemap-blank flag_run --sweep
  assert_contains "$OUT" "EXIT 2" "with no good sitemap to fall back on the run ends"
  assert_contains "$OUT" "ERR error: /sitemap.xml: page rejected: no <loc> entries" "and says why"
  pass "model picker: an evaluation page, sitemap or catalog that does not parse is rejected and never replaces the cache"
}

test_newest_page_decides_model_attributes() {
  local data=$TMP_ROOT/newest db
  mkdir -p "$data/raw"
  python3 -I - "$data/raw" <<'PY'
import json, sys
from pathlib import Path
raw = Path(sys.argv[1])
def put(names, deprecated, released, ts):
    objs = [{"id": "id-" + s, "slug": s, "name": s.upper(), "creator": {"name": "Acme", "slug": "acme"}, "intelligenceIndex": 10,
             "deprecated": deprecated if s == "m-a" else False, "releaseDate": released} for s in names]
    head = "".join(f"<th>Acme {o['name']}</th>" for o in objs)
    cells = "".join("<td>10</td>" for _ in objs)
    page = (f"<html><table><thead><tr><th></th>{head}</tr></thead><tbody><tr><td>Intelligence Index</td>{cells}</tr></tbody></table><script>"
            + json.dumps({"models": objs}, separators=(",", ":")).replace('"', '\\"') + "</script></html>")
    stem = "-vs-".join(names)
    (raw / f"models_comparisons_{stem}.html").write_text(page)
    (raw / f"models_comparisons_{stem}.html.ts").write_text(ts)
put(["m-a", "m-b"], False, "2026-01-01", "2026-10-14T10:00:00Z")
put(["m-a", "m-c"], True, "2026-02-02", "2026-10-15T10:00:00Z")
PY
  run "$data" --db
  expect_code 0 "$CODE" "--db over two cached pages for one model"
  db=$data/aa.sqlite
  assert_equals "1|2026-02-02" "$(sql "$db" "select deprecated, release_date from models where slug='m-a'")" "the newer page decides a model's deprecated flag and release date"
  assert_equals "0|2026-01-01" "$(sql "$db" "select deprecated, release_date from models where slug='m-b'")" "a model on one page keeps that page's attributes"
  assert_equals "true 2026-02-02" "$(python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(str(d["deprecated"]).lower(), d["release_date"])' "$data/projection/m-a.json")" "the projection carries the newest attributes"
  pass "model picker: a model's attributes come from its newest cached page"
}

snapshot_model() {  # <data-dir> <slug>: the cohort facts held for a model in snapshot.json
  python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["models"].get(sys.argv[2]), sort_keys=True))' "$1/snapshot.json" "$2"
}

test_unparseable_cohort_page_is_rejected() {
  local data=$TMP_ROOT/cohort before
  FLAG_ROOT=$data
  flag_run --replay --models m-zz
  assert_contains "$OUT" "EXIT 0" "day 1: a model page that parses"
  before=$(snapshot_model "$data" m-zz)
  assert_contains "$before" '"intelligence_index": 58.0' "day 1 stores the model's facts"
  rm -f "$data/raw/models_m-zz.html" "$data/raw/models_m-zz.html.ts"
  SITE=cohort-blank flag_run --replay --models m-zz
  assert_contains "$OUT" "EXIT 4" "day 2: a 200 model page with no model facts does not exit 0"
  assert_contains "$OUT" "ERR   /models/m-zz: page rejected: no model facts" "the rejected model page is named"
  assert_absent "$data/raw/models_m-zz.html" "a rejected model page never enters the cache"
  assert_equals "$before" "$(snapshot_model "$data" m-zz)" "the previous facts stay in snapshot.json, not an empty record"
  FLAG_ROOT=$TMP_ROOT/cohort-fresh
  SITE=cohort-blank flag_run --replay --models m-yy
  assert_contains "$OUT" "EXIT 4" "a model page that never parsed does not exit 0"
  assert_equals "null" "$(snapshot_model "$FLAG_DATA" m-yy)" "and no empty record is stored for it"
  unset FLAG_ROOT
  pass "model picker: a cohort model page that does not parse is rejected, exits 4, and leaves the previous facts"
}

test_chartdiff_refetch_must_return_the_same_models() {
  SITE=refetch-other flag_run --chartdiff
  assert_contains "$OUT" "REQ /models/comparisons/m-a-vs-m-b" "the disagreeing page is re-fetched once"
  assert_equals "1" "$(requests_matching '^REQ /models/comparisons/m-a-vs-m-b$')" "and only once"
  assert_contains "$OUT" "EXIT 3" "a re-fetch that returns other models does not make the verdict TRUSTED"
  assert_contains "$(cat "$FLAG_DATA/verdict.json")" '"verdict": "UNTRUSTED"' "the verdict stays UNTRUSTED"
  assert_equals "1" "$(grep -c '<td>99</td>' "$FLAG_DATA/raw/models_comparisons_m-a-vs-m-b.html" || true)" "the old page stays in the cache"
  assert_equals "0" "$(grep -c 'M-X' "$FLAG_DATA/raw/models_comparisons_m-a-vs-m-b.html" || true)" "and the page for other models never enters it"
  assert_equals "2026-01-01T00:00:00Z" "$(cat "$FLAG_DATA/raw/models_comparisons_m-a-vs-m-b.html.ts")" "with its real fetch time"
  assert_contains "$(cat "$FLAG_DATA/reconcile.md")" "shown value differs from payload" "the mismatch is still listed"
  assert_present "$FLAG_DATA/projection/m-a.json" "m-a stays in the matrix"
  pass "model picker: a chart-diff re-fetch must return the models the page names, else the mismatch stands"
}

test_page_that_earlier_ingested_and_is_now_quarantined_exits_4() {
  local data=$TMP_ROOT/regressed
  seed_cache "$data"
  add_pair "$data" m-c m-d
  run "$data" --db
  expect_code 0 "$CODE" "day 1: every cached page ingests"
  assert_contains "$OUT" "[db] cached compare pages quarantined: 0" "the count is reported on every run"
  sed -i.bak 's|Acme M-A|Acme M-Z|' "$data/raw/models_comparisons_m-a-vs-m-b.html"
  run "$data" --db
  expect_code 4 "$CODE" "day 2: a page that stamped rows yesterday no longer ingests"
  assert_contains "$OUT" "[db] cached compare pages quarantined: 1: models_comparisons_m-a-vs-m-b.html (quarantined: header 0 'Acme M-Z' != payload 'Acme M-A')" "the count line names the file and why"
  assert_contains "$ERR" "INCOMPLETE" "the run says it is incomplete"
  assert_contains "$ERR" "models_comparisons_m-a-vs-m-b.html stamped rows in the previous matrix and no longer ingests" "and names the page"
  assert_absent "$data/projection/m-a.json" "its models left the matrix"
  assert_present "$data/projection/m-c.json" "the pages that still ingest stay"
  seed_cache "$TMP_ROOT/never"
  sed -i.bak 's|Acme M-A|Acme M-Z|' "$TMP_ROOT/never/raw/models_comparisons_m-a-vs-m-b.html"
  run "$TMP_ROOT/never" --db
  expect_code 0 "$CODE" "a page that never ingested is reported, not a regression"
  assert_contains "$OUT" "[db] cached compare pages quarantined: 1: models_comparisons_m-a-vs-m-b.html" "and still counted"
  pass "model picker: a cached page that earlier ingested and now does not exits 4 with a count line"
}

test_verdict_names_leaderboard_cells_it_did_not_compare() {
  local data=$TMP_ROOT/leaderboard db
  mkdir -p "$data/raw"
  printf '%s' '<html><table><thead><tr><th></th><th>Creator</th><th>Name</th><th>Elo</th><th>CI</th><th>Release Date</th></tr></thead><tbody><tr><td>1</td><td>Acme</td><td>M-A</td><td>1500</td><td>-1 / +1</td><td>Sep 2026</td></tr><tr><td>2</td><td>Acme</td><td>Outside-1</td><td>1400</td><td>-2 / +2</td><td>Sep 2026</td></tr><tr><td>3</td><td>Acme</td><td>Outside-2</td><td>1300</td><td>-3 / +3</td><td>Sep 2026</td></tr></tbody></table>"initialModels":[{"id":"i1","slug":"m-a","name":"M-A","creator":{"name":"Acme","slug":"acme"},"briefcaseBreakdown":{"overall":{"elo":1500}}}]</html>' >"$data/raw/evaluations_aa-briefcase.html"
  printf '%s' '<html><table><thead><tr><th></th><th>Creator</th><th>Model</th><th>Openness Index</th><th>Intelligence Index</th></tr></thead><tbody><tr><td>1</td><td>Acme</td><td>Open-1</td><td>88.89</td><td>11.50</td></tr><tr><td>2</td><td>Acme</td><td>Open-2</td><td>70.00</td><td>9.00</td></tr></tbody></table></html>' >"$data/raw/evaluations_artificial-analysis-openness-index.html"
  printf '2026-10-15T20:00:00Z' >"$data/raw/evaluations_aa-briefcase.html.ts"
  printf '2026-10-15T20:00:00Z' >"$data/raw/evaluations_artificial-analysis-openness-index.html.ts"
  run "$data" --chartdiff --replay
  expect_code 0 "$CODE" "chart-diff over leaderboards with cells outside the chart window"
  assert_contains "$OUT" "chart-diff: TRUSTED (0 mismatches in 1 compared values, " "the one cell inside the window is compared"
  assert_contains "$OUT" ", 4 leaderboard cells not compared)" "the verdict line names the cells it did not compare"
  assert_contains "$(cat "$data/verdict.json")" '"leaderboard_not_compared": 4' "verdict.json carries the count"
  assert_grep "Evaluation leaderboard cells outside the chart window (stored, not compared): 4" "$data/reconcile.md" "reconcile.md lists the same count"
  db=$data/aa.sqlite
  assert_equals "-1 / +1|-2 / +2|-3 / +3" "$(sql "$db" "select group_concat(o.ci, '|') from (select o.ci from observations o join metrics x on x.id=o.metric_id where x.label='eval-leaderboard:aa-briefcase' order by o.ci) o")" "a CI column keeps its intervals"
  assert_equals "2|0" "$(sql "$db" "select count(*), count(o.ci) from observations o join metrics x on x.id=o.metric_id where x.label='eval-leaderboard:artificial-analysis-openness-index'")" "a fifth column that is another metric is not stored as an interval"
  pass "model picker: the verdict names the leaderboard cells it did not compare; ci holds intervals only"
}

test_daily_runs_keep_one_404_line_per_url() {
  local data=$TMP_ROOT/four04 first
  FLAG_ROOT=$data
  SITE=unsupported flag_run --sweep --replay --stale-after-hours 1
  assert_contains "$OUT" "EXIT 0" "day 1: the unsupported slug is a recorded reason"
  first=$(wc -l <"$data/raw/_http_404.jsonl" | tr -d ' ')
  assert_equals "4" "$first" "the batch, the pair, the slug alone and the slug paired with an anchor are remembered once each"
  sed -i.bak 's|"at": "[^"]*"|"at": "2020-01-01T00:00:00Z"|' "$data/raw/_http_404.jsonl"
  SITE=unsupported flag_run --sweep --replay --stale-after-hours 1
  assert_contains "$OUT" "EXIT 0" "day 2: the aged memories are asked about again"
  assert_equals "1" "$(requests_matching '^REQ /models/comparisons/m-new$')" "the slug alone was requested again"
  assert_equals "1" "$(requests_matching '^REQ /models/comparisons/m-new-vs-claude-opus-5-5$')" "and paired with an anchor"
  assert_equals "$first" "$(wc -l <"$data/raw/_http_404.jsonl" | tr -d ' ')" "and the file still holds one line per URL"
  assert_equals "2" "$(grep -c '2020-01-01' "$data/raw/_http_404.jsonl" || true)" "the two re-asked URLs carry the new time, the others keep theirs"
  unset FLAG_ROOT
  pass "model picker: repeated 404s keep one line per URL"
}

test_dropped_connection_is_retried() {
  SITE=dropped flag_run --sweep --replay
  assert_equals "REQ /models/comparisons/m-new
REQ /models/comparisons/m-new
EXIT 0" "$OUT" "a connection that drops mid-read is retried and the sweep goes on"
  pass "model picker: a dropped connection is retried, not a traceback"
}

test_selftest_and_help
test_data_root_resolution
test_calibration_first_and_preserved
test_seeded_cache_ingest
test_empty_compared_set_is_not_zero_disagreements
test_network_off_is_a_clean_error
test_unit_cells_are_stored_as_numbers
test_rebuild_without_chartdiff_is_untrusted
test_flags_decide_which_requests_are_made
test_coverage_follows_the_cache_not_the_database
test_unsafe_payload_slug_is_rejected
test_incomplete_acquisition_exits_4_after_writing_outputs
test_dropped_connection_is_retried
test_scattered_fetch_failures_exit_4
test_failure_record_lives_in_snapshot_only
test_unparseable_compare_page_keeps_last_good_copy
test_unsupported_slug_404_is_not_incomplete
test_unparseable_eval_page_and_sitemap_are_rejected
test_newest_page_decides_model_attributes
test_unparseable_cohort_page_is_rejected
test_chartdiff_refetch_must_return_the_same_models
test_page_that_earlier_ingested_and_is_now_quarantined_exits_4
test_verdict_names_leaderboard_cells_it_did_not_compare
test_daily_runs_keep_one_404_line_per_url
