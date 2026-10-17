#!/usr/bin/env bash
# Model-picker collector behavior through bin/fm-model-picker.sh: the fixture suite, the
# data-root contract, calibration tables created first and never touched by a matrix rebuild,
# exact-slug ingest from a seeded cache (banned route and unknown-age pages ignored), the
# chart-diff verdict on an empty compared set, a clean error when the network is off, unit
# cells stored as numbers with a unit, a verdict that goes UNTRUSTED when the matrix is rebuilt
# without chart-diff, coverage that follows the cache and never an older database, a payload slug
# that cannot name a file outside projection/, and which network requests and exit code each
# flag and each outage produce against a scripted site.
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

seed_units() {  # <data-dir>: one compare page whose table rows carry every unit family
  mkdir -p "$1/raw"
  python3 -I - "$1/raw" <<'PY'
import json, sys
from pathlib import Path
raw = Path(sys.argv[1])
objs = [{"id": "id-" + s, "slug": s, "name": s.upper(), "creator": {"name": "Acme", "slug": "acme"}, "intelligenceIndex": i,
         "price1mBlended7To2To1": blended, "price1mInputTokens": inp, "price1mOutputTokens": out, "cacheHitPrice": cache}
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

seed_blank_pages() {  # <data-dir>: a cached evaluation page and cohort model page for every page an acquisition run asks for
  PYTHONPATH="$ROOT/bin" PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys
from pathlib import Path
from fm_model_picker import collect
collect.configure(sys.argv[1])
for path in ["/evaluations/" + s for s in collect.EVAL_SLUGS] + ["/models/" + s for s in collect.COHORT]:
    f = collect.cache_file(path)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text("<html></html>")
    Path(str(f) + ".ts").write_text("2026-10-15T20:00:00Z")
' "$1"
}

test_rebuild_without_chartdiff_is_untrusted() {
  local data=$TMP_ROOT/stale
  seed_cache "$data"
  seed_discovery "$data"
  seed_blank_pages "$data"
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
  seed_blank_pages "$data"
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
slugs = ["m-a", "m-b", "m-new"] + ([f"x-{i:02d}" for i in range(17)] if mode == "outage" else [])
SITEMAP = "<urlset>" + "".join(f"<url><loc>{collect.BASE}/models/{s}</loc></url>" for s in slugs) + "</urlset>"
CATALOG = "<html>" + "".join(
    '{"slug":"%s","name":"%s","deprecated":false,"releaseDate":"2026-01-01","creator":{"slug":"acme","name":"Acme"}}' % (s, s.upper())
    for s in ("m-a", "m-b")) + "</html>"


def site(path):
    if path == "/sitemap.xml":
        return SITEMAP
    if path == "/models/comparisons":
        return CATALOG
    if path.startswith("/models/comparisons/"):
        return collect._fake_page([collect._fake_obj(n, intelligenceIndex=30.0) for n in path[len("/models/comparisons/"):].split("-vs-")])
    return "<html></html>"


def put(path, text):
    f = collect.cache_file(path)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(text, encoding="utf-8")
    Path(str(f) + ".ts").write_text("2026-01-01T00:00:00Z", encoding="utf-8")


for slug in collect.EVAL_SLUGS:
    put("/evaluations/" + slug, "<html></html>")
for slug in collect.COHORT:
    put("/models/" + slug, "<html></html>")
put("/sitemap.xml", SITEMAP)
put("/models/comparisons", CATALOG)
put("/models/comparisons/m-a-vs-m-b", collect._fake_page([collect._fake_obj(n, intelligenceIndex=30.0) for n in ("m-a", "m-b")]))

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
    if ((mode == "outage" and path.startswith("/models/comparisons/")) or (mode == "evals-down" and path.startswith("/evaluations/"))
            or (mode == "cohort-down" and path.startswith("/models/") and not path.startswith("/models/comparisons"))):
        raise urllib.error.HTTPError(req.full_url, 500, "x", email.message.Message(), None)
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
  local data=$TMP_ROOT/flags-$((++FLAG_N))
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
