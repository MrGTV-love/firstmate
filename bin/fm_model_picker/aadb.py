"""
SQLite store for the model picker: calibration tables first, then the benchmark matrix.

dispatch_log and outcomes are created BEFORE any benchmark table (build-first deliverable):
shadow mode writes to them before any live pick. They carry the handoff columns plus four
extra shadow columns (mode, rule_worker, rule_validator, rule_effort) so one row holds both
the picker's pick and the current dispatch rule's choice.

The benchmark matrix (models, metrics, observations, reconcile_runs) is loaded
by `migrate` from raw evidence only; every derived aggregate is recomputed, never imported.
"""
import calendar
import json
import sqlite3
import time
from pathlib import Path

SCHEMA_VERSION = 1

DDL_CALIBRATION = [
    """CREATE TABLE IF NOT EXISTS dispatch_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at TEXT NOT NULL,
        mode TEXT NOT NULL CHECK (mode IN ('shadow', 'live')),
        task_type TEXT, work_type TEXT, complexity_score REAL,
        chosen_worker TEXT, chosen_validator TEXT, effort TEXT,
        rule_worker TEXT, rule_validator TEXT, rule_effort TEXT,
        jev_raw_payload BLOB, jev_candidate_version TEXT,
        gates TEXT, pareto_pruned TEXT, spend_priority TEXT,
        snapshot_age REAL, validator_verdict TEXT, validator_disagreement TEXT,
        rework INTEGER, captain_acceptance TEXT)""",
    """CREATE TABLE IF NOT EXISTS outcomes (
        dispatch_id INTEGER PRIMARY KEY REFERENCES dispatch_log(id),
        quality REAL, rework INTEGER, time_s REAL, accepted INTEGER, notes TEXT)""",
]

DISPATCH_FIELDS = (
    "at", "mode", "task_type", "work_type", "complexity_score", "chosen_worker",
    "chosen_validator", "effort", "rule_worker", "rule_validator", "rule_effort",
    "jev_raw_payload", "jev_candidate_version", "gates", "pareto_pruned", "spend_priority",
    "snapshot_age", "validator_verdict", "validator_disagreement", "rework",
    "captain_acceptance")
JSON_FIELDS = ("gates", "pareto_pruned", "spend_priority")


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def connect(path):
    """Open the database with foreign keys on (an unknown dispatch_id is rejected)."""
    if str(path) != ":memory:":
        Path(path).parent.mkdir(parents=True, exist_ok=True)
    # measured: value=30 date=2026-10-17 host=Mac-Studio margin=7x (three full --db rebuilds, slowest 4.08s end to end, the write lock held for less)
    conn = sqlite3.connect(str(path), timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_calibration(conn):
    """Create the calibration tables only; the matrix tables come later."""
    for stmt in DDL_CALIBRATION:
        conn.execute(stmt)
    conn.commit()


def snapshot_age_seconds(fetched_at, now=None):
    """Seconds since the snapshot's real fetch time. 'unknown' stays unknown (None)."""
    if not fetched_at or fetched_at == "unknown":
        return None
    t = calendar.timegm(time.strptime(fetched_at, "%Y-%m-%dT%H:%M:%SZ"))
    return max(0.0, (time.time() if now is None else now) - t)


def log_dispatch(conn, **fields):
    """Insert one dispatch row and return its id. `mode` is required (shadow or live).
    jev_raw_payload is stored unchanged (str or bytes); gates, pareto_pruned and
    spend_priority are stored as sorted JSON."""
    unknown = sorted(set(fields) - set(DISPATCH_FIELDS))
    if unknown:
        raise TypeError(f"unknown dispatch_log fields: {unknown}")
    if "mode" not in fields:
        raise TypeError("log_dispatch needs mode='shadow' or mode='live'")
    row = {k: fields.get(k) for k in DISPATCH_FIELDS}
    row["at"] = row["at"] or utc_now()
    payload = row["jev_raw_payload"]
    if payload is not None and not isinstance(payload, (str, bytes)):
        raise TypeError("jev_raw_payload must be the unchanged str or bytes of the Jev result")
    for k in JSON_FIELDS:
        if row[k] is not None and not isinstance(row[k], str):
            row[k] = json.dumps(row[k], sort_keys=True)
    cur = conn.execute(
        f"INSERT INTO dispatch_log ({', '.join(DISPATCH_FIELDS)}) "
        f"VALUES ({', '.join('?' * len(DISPATCH_FIELDS))})", [row[k] for k in DISPATCH_FIELDS])
    conn.commit()
    return cur.lastrowid


def _flag(value):
    return None if value is None else ("yes" if value is True else "no" if value is False else str(value))


def _update(conn, dispatch_id, **cols):
    sets = ", ".join(f"{k} = ?" for k in cols)
    cur = conn.execute(f"UPDATE dispatch_log SET {sets} WHERE id = ?", [*cols.values(), dispatch_id])
    if cur.rowcount != 1:
        raise LookupError(f"no dispatch_log row {dispatch_id}")
    conn.commit()


def record_validator(conn, dispatch_id, verdict, disagreement):
    """The validator's verdict, and whether it disagreed with the worker (bool or text)."""
    _update(conn, dispatch_id, validator_verdict=verdict, validator_disagreement=_flag(disagreement))


def record_outcome(conn, dispatch_id, quality=None, rework=None, time_s=None, accepted=None, notes=None):
    """One outcome per dispatch. An unknown dispatch_id raises sqlite3.IntegrityError."""
    conn.execute(
        "INSERT INTO outcomes (dispatch_id, quality, rework, time_s, accepted, notes) VALUES (?,?,?,?,?,?)",
        (dispatch_id, quality, rework, time_s, None if accepted is None else int(bool(accepted)), notes))
    conn.commit()

def calibration_selftest():
    """Insert, read back, reject an unknown dispatch_id, keep the raw payload byte for byte."""
    conn = connect(":memory:")
    init_calibration(conn)
    tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY rowid")]
    assert tables[:2] == ["dispatch_log", "outcomes"] or tables[:3] == ["dispatch_log", "sqlite_sequence", "outcomes"], tables
    raw = '{"worker": "gpt-6-1-sol",\r\n "why": "café — trailing  "}\n\n  '
    did = log_dispatch(
        conn, mode="shadow", task_type="ship", work_type="code", complexity_score=0.62,
        chosen_worker="gpt-6-1-sol", chosen_validator="claude-opus-5-5", effort="high",
        rule_worker="claude-sonnet-5-5", rule_validator="gpt-6-1-sol", rule_effort="medium",
        jev_raw_payload=raw, jev_candidate_version="jev-1.13.0", gates={"eligible": 4},
        pareto_pruned=["a", "b"], spend_priority={"gpt-6-1-sol": 2}, snapshot_age=3600.0, rework=1, captain_acceptance="accepted")
    row = conn.execute("SELECT * FROM dispatch_log WHERE id=?", (did,)).fetchone()
    assert row["jev_raw_payload"] == raw, "raw payload must survive unchanged"
    assert row["mode"] == "shadow" and row["rule_worker"] == "claude-sonnet-5-5" and row["rule_effort"] == "medium"
    assert json.loads(row["gates"]) == {"eligible": 4} and row["snapshot_age"] == 3600.0
    blob = b"\xff\xfe\x00 not utf-8 \r\n"
    bid = log_dispatch(conn, mode="live", jev_raw_payload=blob)
    assert conn.execute("SELECT jev_raw_payload FROM dispatch_log WHERE id=?", (bid,)).fetchone()[0] == blob
    record_validator(conn, did, "agree", False)
    row = conn.execute("SELECT * FROM dispatch_log WHERE id=?", (did,)).fetchone()
    assert (row["validator_verdict"], row["validator_disagreement"], row["rework"], row["captain_acceptance"]) == ("agree", "no", 1, "accepted")
    record_outcome(conn, did, quality=0.9, rework=1, time_s=840.0, accepted=True, notes="ok")
    out = conn.execute("SELECT * FROM outcomes WHERE dispatch_id=?", (did,)).fetchone()
    assert out["accepted"] == 1 and out["quality"] == 0.9
    for bad in (lambda: record_outcome(conn, 9999, quality=1.0), lambda: record_outcome(conn, did, quality=0.1)):
        try:
            bad()
            raise AssertionError("outcome for an unknown or repeated dispatch_id must be rejected")
        except sqlite3.IntegrityError:
            pass
    for bad in (lambda: log_dispatch(conn, mode="maybe"), lambda: log_dispatch(conn),
                lambda: log_dispatch(conn, mode="shadow", bogus=1),
                lambda: log_dispatch(conn, mode="shadow", jev_raw_payload={"parsed": "dict"})):
        try:
            bad()
            raise AssertionError("invalid dispatch input must be rejected")
        except (sqlite3.IntegrityError, TypeError):
            pass
    try:
        record_validator(conn, 9999, "agree", False)
        raise AssertionError("validator record for an unknown dispatch must be rejected")
    except LookupError:
        pass
    assert snapshot_age_seconds("2026-10-16T00:00:00Z", now=calendar.timegm((2026, 10, 16, 1, 0, 0))) == 3600
    assert snapshot_age_seconds("unknown") is None
    conn.close()

DDL_MATRIX = [
    """CREATE TABLE IF NOT EXISTS models (
        id INTEGER PRIMARY KEY,
        slug TEXT UNIQUE, name TEXT NOT NULL, creator TEXT, deprecated INTEGER, release_date TEXT,
        first_seen TEXT, last_seen TEXT)""",
    """CREATE TABLE IF NOT EXISTS metrics (
        id INTEGER PRIMARY KEY,
        canonical_id TEXT NOT NULL, label TEXT NOT NULL, unit TEXT, scale TEXT, version TEXT,
        UNIQUE (canonical_id, label))""",
    """CREATE TABLE IF NOT EXISTS observations (
        model_id INTEGER NOT NULL REFERENCES models(id),
        metric_id INTEGER NOT NULL REFERENCES metrics(id),
        variant TEXT NOT NULL DEFAULT '',
        observed_at TEXT NOT NULL,
        value REAL,
        source TEXT NOT NULL CHECK (source IN ('comparison-table', 'embedded', 'eval-leaderboard', 'rendered-chart')),
        ci TEXT, raw TEXT,
        partial INTEGER NOT NULL DEFAULT 0, derived INTEGER NOT NULL DEFAULT 0,
        UNIQUE (model_id, metric_id, variant, source, observed_at))""",
    """CREATE TABLE IF NOT EXISTS reconcile_runs (
        id INTEGER PRIMARY KEY,
        ran_at TEXT NOT NULL, metric_id TEXT NOT NULL, path_a TEXT, path_b TEXT,
        checked INTEGER NOT NULL, agreements INTEGER NOT NULL, mismatches INTEGER NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('agree', 'mismatch', 'resolved', 'quarantined', 'not-compared')),
        notes TEXT)""",
    "CREATE INDEX IF NOT EXISTS observations_by_metric ON observations (metric_id, model_id)",
]
SOURCES = ("comparison-table", "embedded", "eval-leaderboard", "rendered-chart")
SOURCE_RANK = {s: i for i, s in enumerate(("embedded", "eval-leaderboard", "comparison-table", "rendered-chart"))}


def init_db(conn):
    """Calibration tables FIRST, then the benchmark matrix. Idempotent; refuses a newer schema."""
    have = conn.execute("PRAGMA user_version").fetchone()[0]
    if have > SCHEMA_VERSION:
        raise RuntimeError(f"database schema {have} is newer than this code ({SCHEMA_VERSION})")
    init_calibration(conn)
    for stmt in DDL_MATRIX:
        conn.execute(stmt)
    conn.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
    conn.commit()


def open_db(path):
    conn = connect(path)
    init_db(conn)
    return conn

def load_raw():
    """Read raw evidence only: the cached compare pages (exact payload + table), the cached
    evaluation pages (leaderboard table + chart-window payload) and the rendered captures.
    Derived aggregates are never read; every one is recomputed from these."""
    from . import chartdiff, collect, embedded

    compare, skipped, quarantined = collect.ingest_cached_pages()
    evals, skipped_evals = {}, []
    for slug in collect.EVAL_SLUGS:
        try:
            f = collect.fetch_page("/evaluations/" + slug, network=False)
        except collect.FetchError:
            skipped_evals.append({"slug": slug, "reason": "evaluation page not in cache"})
            continue
        if f.ts == "unknown":
            skipped_evals.append({"slug": slug, "reason": "age unknown"})
            continue
        tables = collect.extract_tables(f.text)
        arr, why = embedded.extract_array(f.text, embedded.EVAL_MARKER)
        window, rejects = embedded.check_objects(arr) if arr else ([], [])
        e = {"ts": f.ts, "leaderboard": collect.parse_leaderboard(tables[0]["rows"]) if tables else {},
             "table_rows": tables[0]["rows"] if tables else [], "window": window, "window_why": why, "rejects": rejects,
             "rendered": None}
        rfile = collect.RAW / "rendered" / (slug + ".txt")
        if rfile.exists():
            text = rfile.read_text(encoding="utf-8", errors="replace")
            e["rendered"] = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(rfile.stat().st_mtime)),
                             "rows": collect.parse_rendered_sections(text)["rows"],
                             "charts": chartdiff.parse_chart_sections(text)}
        evals[slug] = e
    return {"compare": compare, "evals": evals, "skipped": skipped, "quarantined": quarantined,
            "skipped_evals": skipped_evals}


def _version(label):
    import re
    m = re.search(r"\bv(\d+(?:\.\d+)+)\b", label)
    return m.group(1) if m else None


def build_observations(raw):
    """-> (models, observations). Every observation keeps its page's real fetch time (the
    rendered captures use the file's modification time). A leaderboard row whose
    (creator, name) matches no catalog model becomes a model with no slug: identity is exact
    or absent, never fuzzy."""
    from . import chartdiff, collect, embedded

    models, obs, newest = {}, {}, {}

    def add_model(attrs, observed_at):
        key = attrs["slug"]
        if key not in models or observed_at > newest[key]:
            models[key] = {"slug": key, "name": attrs["name"], "creator": attrs["creator"],
                           "deprecated": int(attrs["deprecated"]), "release_date": attrs["release_date"]}
            newest[key] = observed_at
        return key

    def add(model, cid, label, source, observed_at, value, raw=None, ci=None, unit=None, scale=None,
            partial=0, derived=0):
        k = (model, cid, label, "", source, observed_at)
        obs[k] = {"model": model, "cid": cid, "label": label, "variant": "", "source": source,
                  "observed_at": observed_at, "value": value, "raw": raw, "ci": ci, "unit": unit,
                  "scale": scale, "partial": partial, "derived": derived}

    for lst in raw["compare"].values():
        for r in lst:
            ts = r["observed_at"]
            key = add_model(r["attrs"], ts)
            for label, cell in r["table"].items():
                value, unit = collect.parse_cell(cell)
                add(key, collect.canon_metric_id(label), label, "comparison-table", ts, value, raw=cell, unit=unit)
            for cid, v in r["series"].items():
                spec = embedded.SERIES_MAP[cid]
                add(key, cid, spec["label"], "embedded", ts, v, unit=spec["unit"], scale=spec["scale"],
                    derived=int(spec["derived"]), ci="estimated" if cid in r["attrs"].get("estimated", ()) else None)
    by_name = {(m["creator"], m["name"]): k for k, m in models.items()}
    for slug, e in raw["evals"].items():
        for o in e["window"]:
            key = add_model(embedded.model_attrs(o), e["ts"])
            by_name[(o["creator"]["name"], o["name"])] = key
            for cid, v in embedded.model_series(o).items():
                spec = embedded.SERIES_MAP[cid]
                add(key, cid, spec["label"], "embedded", e["ts"], v, unit=spec["unit"], scale=spec["scale"],
                    partial=1, derived=int(spec["derived"]),
                    ci="estimated" if cid in embedded.model_attrs(o)["estimated"] else None)
    count = {}
    for m in models.values():
        count[m["name"]] = count.get(m["name"], 0) + 1
    by_only = {m["name"]: k for k, m in models.items() if count[m["name"]] == 1}
    for slug, e in raw["evals"].items():
        cid, label = collect.canon_metric_id("eval-leaderboard:" + slug), "eval-leaderboard:" + slug
        for name, rec in e["leaderboard"].items():
            key = by_name.get((rec["creator"], name)) if rec.get("creator") else by_only.get(name)
            if key is None:
                key = f"~{rec.get('creator')}|{name}"
                models.setdefault(key, {"slug": None, "name": name, "creator": rec.get("creator"),
                                        "deprecated": None, "release_date": None})
            add(key, cid, label, "eval-leaderboard", e["ts"], rec["value"], raw=rec["raw"], ci=rec.get("ci"))
        for o in chartdiff.rendered_observations(slug, e):
            key = o.pop("model")
            add(key, o.pop("cid"), o.pop("label"), "rendered-chart", o.pop("observed_at"), o.pop("value"),
                raw=o.get("raw"), partial=1)
    first, last = {}, {}
    for o in obs.values():
        m = o["model"]
        first[m] = min(first.get(m, o["observed_at"]), o["observed_at"])
        last[m] = max(last.get(m, o["observed_at"]), o["observed_at"])
    for k, m in models.items():
        m["first_seen"], m["last_seen"] = first.get(k), last.get(k)
    return models, list(obs.values())


def coverage_view(models, observations):
    """The raw-row shape compute_coverage consumes, rebuilt from observations alone."""
    comparisons, embedded_, windows, evals = {}, {}, {}, {}
    for o in observations:
        key = models[o["model"]]["slug"] or o["model"]
        if o["source"] == "comparison-table":
            comparisons.setdefault(key, {})[o["label"]] = o["raw"]
        elif o["source"] == "embedded" or o["source"] == "rendered-chart":
            bucket = windows if o["partial"] else embedded_
            bucket.setdefault(key, {})[o["label"]] = o["value"]
        elif o["source"] == "eval-leaderboard":
            slug = o["label"].split(":", 1)[1]
            evals.setdefault(slug, {"leaderboard": {}})["leaderboard"][key] = {"value": o["value"]}
    return {"comparisons": comparisons, "embedded": embedded_, "windows": windows, "evals": evals}


def metric_defs(observations):
    """(canonical id, label) -> unit, scale and version. The unit is the first one a cell or the
    source states. A scale the source states wins; otherwise it is read from the shown cells:
    no numbers -> text, all percent -> fraction, a number with a unit -> quantity (the value is
    in that unit, a k/M/B/T suffix already expanded), else raw."""
    from . import collect

    defs = {}
    for o in observations:
        d = defs.setdefault((o["cid"], o["label"]), {"unit": None, "scale": None, "cells": []})
        d["unit"] = d["unit"] or o["unit"]
        d["scale"] = d["scale"] or o["scale"]
        if o["raw"] is not None:
            d["cells"].append(o["raw"])
    for (cid, label), d in defs.items():
        if not d["scale"]:
            nums = [c for c in d["cells"] if collect.parse_cell(c)[0] is not None]
            d["scale"] = ("text" if not nums else "fraction" if all(c.rstrip("*").endswith("%") for c in nums)
                          else "quantity" if d["unit"] else "raw")
        d["version"] = _version(label)
    return defs


def migrate(conn, raw=None, log=print):
    """Rebuild the benchmark matrix from raw evidence in one transaction. The matrix is a pure
    function of the cache, so a rerun gives identical row counts. The calibration tables are
    never touched. Returns the counts read and loaded, per source."""
    raw = raw or load_raw()
    models, obs = build_observations(raw)
    defs = metric_defs(obs)
    with conn:
        for table in ("observations", "metrics", "models"):
            conn.execute(f"DELETE FROM {table}")
        ids = {}
        for key, m in models.items():
            cur = conn.execute(
                "INSERT INTO models (slug, name, creator, deprecated, release_date, first_seen, last_seen) VALUES (?,?,?,?,?,?,?)",
                (m["slug"], m["name"], m["creator"], m["deprecated"], m["release_date"], m["first_seen"], m["last_seen"]))
            ids[key] = cur.lastrowid
        mids = {}
        for (cid, label), d in sorted(defs.items()):
            cur = conn.execute("INSERT INTO metrics (canonical_id, label, unit, scale, version) VALUES (?,?,?,?,?)",
                               (cid, label, d["unit"], d["scale"], d["version"]))
            mids[(cid, label)] = cur.lastrowid
        for o in obs:
            conn.execute(
                "INSERT INTO observations (model_id, metric_id, variant, observed_at, value, source, ci, raw, partial, derived) "
                "VALUES (?,?,?,?,?,?,?,?,?,?)",
                (ids[o["model"]], mids[(o["cid"], o["label"])], o["variant"], o["observed_at"], o["value"], o["source"],
                 o["ci"], o["raw"], o["partial"], o["derived"]))
    read, loaded = {}, {r[0]: r[1] for r in conn.execute("SELECT source, COUNT(*) FROM observations GROUP BY source")}
    for o in obs:
        read[o["source"]] = read.get(o["source"], 0) + 1
    for s in SOURCES:
        log(f"[db] {s}: read {read.get(s, 0)}, loaded {loaded.get(s, 0)}")
        if read.get(s, 0) != loaded.get(s, 0):
            raise RuntimeError(f"row count mismatch for source {s}: read {read.get(s, 0)}, loaded {loaded.get(s, 0)}")
    n_models = conn.execute("SELECT COUNT(*) FROM models").fetchone()[0]
    if n_models != len(models):
        raise RuntimeError(f"model count mismatch: read {len(models)}, loaded {n_models}")
    return {"models": n_models, "metrics": len(defs), "read": read, "loaded": loaded,
            "view": coverage_view(models, obs), "model_rows": models}


def write_projections(conn, outdir):
    """One JSON projection per catalog model (the picker's wire format), written last. For each
    canonical metric the newest numeric observation wins; ties prefer embedded full precision.
    Freshness: `as_of` is the newest observed_at across the model's metrics, so it says when the
    model last got any new data, not that every metric is that fresh. Each metric's own
    `observed_at` is authoritative for freshness. A rounded eval-leaderboard value (1803) can win
    over a full-precision embedded value (1802.99) when it is newer."""
    import os

    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    rows = conn.execute(
        "SELECT m.slug, m.name, m.creator, m.deprecated, m.release_date, x.canonical_id, x.label, x.unit, x.scale, "
        "o.value, o.source, o.observed_at, o.partial, o.derived, o.ci "
        "FROM observations o JOIN models m ON m.id = o.model_id JOIN metrics x ON x.id = o.metric_id "
        "WHERE m.slug IS NOT NULL AND o.value IS NOT NULL").fetchall()
    best, head = {}, {}
    for r in rows:
        head[r["slug"]] = {"slug": r["slug"], "name": r["name"], "creator": r["creator"], "deprecated": bool(r["deprecated"]),
                           "release_date": r["release_date"]}
        key = (r["slug"], r["canonical_id"])
        rank = (r["observed_at"], -SOURCE_RANK[r["source"]])
        if key not in best or rank > best[key][0]:
            best[key] = (rank, {"label": r["label"], "value": r["value"], "unit": r["unit"], "scale": r["scale"],
                                "source": r["source"], "observed_at": r["observed_at"], "partial": bool(r["partial"]),
                                "derived": bool(r["derived"]), "estimated": r["ci"] == "estimated"})
    per = {}
    for (slug, cid), (_, rec) in best.items():
        per.setdefault(slug, {})[cid] = rec
    written = set()
    for slug, metrics in per.items():
        doc = dict(head[slug], as_of=max(m["observed_at"] for m in metrics.values()), metrics=metrics)
        tmp = out / (slug + ".json.tmp")
        tmp.write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(tmp, out / (slug + ".json"))
        written.add(slug + ".json")
    for stale in out.glob("*.json"):
        if stale.name not in written:
            stale.unlink()
    return len(written)


def matrix_selftest():
    """Load synthetic raw evidence: counts per source match, a rerun is identical, the
    calibration rows survive, an unmatched leaderboard name stays slugless, coverage is
    recomputed from rows, and the projection picks the newest value."""
    import tempfile
    from . import collect

    def obj(slug, name, short, **extra):
        return {"id": "i-" + slug, "slug": slug, "name": name, "shortName": short, "creator": {"name": "Acme", "slug": "acme"}, **extra}

    a, b = obj("m-a", "Alpha (Max)", "Alpha (max)", gpqa=0.5, intelligenceIndex=57.6, intelligenceIndexIsEstimated=True), obj("m-b", "Beta", "Beta", gpqa=None)
    row = {"attrs": {**__import__("fm_model_picker.embedded", fromlist=["x"]).model_attrs(a)}, "series": {"gpqadiamond": 0.5, "intelligence-index": 57.6, "priceper1mtokens": 1.5},
           "table": {"Intelligence Index": "58*", "License": "Open", "Output Speed": "95 tokens/s", "Reasoning Tokens per Task": "84k", "Cost per Task": "$5.98", "Price per 1M Tokens": "$1.50"}, "observed_at": "2026-10-15T10:00:00Z", "page": "p", "batch": ["m-a"]}
    board = {"Alpha (Max)": {"value": 1800.0, "raw": "1800", "ci": "-5 / +5", "rank": 1, "creator": "Acme"},
             "Ghost (Max)": {"value": 1700.0, "raw": "1700", "ci": None, "rank": 2, "creator": "Nowhere"}}
    page = {"ts": "2026-10-15T12:00:00Z", "leaderboard": board, "table_rows": [], "window": [a, b], "window_why": None, "rejects": [],
            "rendered": {"at": "2026-10-15T11:00:00Z", "rows": {}, "charts": []}}
    gp = dict(page, leaderboard={}, ts="2026-10-15T13:00:00Z", rendered={"at": "2026-10-15T11:00:00Z", "rows": {}, "charts": [
        {"title": "GPQA Diamond: Score", "cid_hint": "primary", "n": 1, "of": 9, "pairs": [("Alpha (max)", "50.0%")]}]})
    raw = {"compare": {"m-a": [row]}, "evals": {"aa-briefcase": page, "gpqa-diamond": gp}, "skipped": [], "quarantined": [], "skipped_evals": []}
    with tempfile.TemporaryDirectory() as tmp:
        conn = open_db(Path(tmp) / "aa.sqlite")
        did = log_dispatch(conn, mode="shadow", chosen_worker="w", jev_raw_payload="raw")
        quiet = lambda *a, **k: None
        first = migrate(conn, raw=raw, log=quiet)
        again = migrate(conn, raw=raw, log=quiet)
        assert first["loaded"] == again["loaded"] and first["models"] == again["models"], "a rerun must give the same row counts"
        assert conn.execute("SELECT jev_raw_payload FROM dispatch_log WHERE id=?", (did,)).fetchone()[0] == "raw", "migration never touches calibration rows"
        assert conn.execute("SELECT COUNT(*) FROM models WHERE slug IS NULL").fetchone()[0] == 1, "an unmatched leaderboard name is slugless, not fuzzy-matched"
        assert conn.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='slug_status'").fetchone()[0] == 0, "the sweep's failure record lives in snapshot.json, not the database"
        assert first["read"]["rendered-chart"] == 1 and first["read"]["eval-leaderboard"] == 2
        est = conn.execute("SELECT o.ci FROM observations o JOIN metrics x ON x.id=o.metric_id WHERE x.canonical_id='intelligence-index' AND o.source='embedded'").fetchone()[0]
        assert est == "estimated", "the payload's estimated flag is kept"
        scale = {r[0]: r[1] for r in conn.execute("SELECT label, scale FROM metrics")}
        assert scale["License"] == "text" and scale["Intelligence Index"] == "raw" and scale["GPQA Diamond"] == "fraction", scale
        units = {r[0]: (r[1], r[2], r[3]) for r in conn.execute(
            "SELECT x.label, x.unit, x.scale, o.value FROM observations o JOIN metrics x ON x.id=o.metric_id WHERE o.source='comparison-table'")}
        assert units["Output Speed"] == ("tokens/s", "quantity", 95.0) and units["Reasoning Tokens per Task"] == ("count", "quantity", 84000.0), units
        assert units["Cost per Task"] == ("usd", "quantity", 5.98) and units["License"][2] is None, units
        assert units["Price per 1M Tokens"] == ("usd", "quantity", 1.5) and scale["Price per 1M Tokens"] == "quantity", "the dollar family reads usd + quantity"
        cov, missing = collect.compute_coverage(first["view"], ["gpqa-diamond", "aa-briefcase"])
        assert cov["gpqadiamond"]["models"] == 1 and cov["gpqadiamond"]["sources"] >= {"embedded", "chart-window"}
        assert cov["aa-briefcase-elo"]["models"] == 2 and "aa-briefcase-elo" not in missing, "leaderboard rows count, matched or not"
        n = write_projections(conn, Path(tmp) / "proj")
        doc = json.loads((Path(tmp) / "proj" / "m-a.json").read_text(encoding="utf-8"))
        assert n == 1 and doc["metrics"]["gpqadiamond"]["observed_at"] == "2026-10-15T13:00:00Z" and doc["metrics"]["gpqadiamond"]["source"] == "embedded"
        assert doc["metrics"]["intelligence-index"]["estimated"] is True and not (Path(tmp) / "proj" / "Ghost.json").exists()
        conn.close()


