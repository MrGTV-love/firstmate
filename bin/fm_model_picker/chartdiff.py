"""
Three-path chart-diff: does the collection match the charts?

Paths, per metric and model:
  A  the server-rendered table value (comparison-table row or eval leaderboard cell),
  B  the full-precision value embedded in the page payload,
  C  the rendered chart label pair, from raw/rendered/*.txt (top 5 to 31 models per page).

B is compared to C, and A to B where both exist. Before comparing, B is rounded to the digits
the shown value carries, so a displayed 96.3% is judged against round(B x 100, 1).
checked == 0 is NOT COMPARED and is never reported as zero disagreements. Mismatches block
the TRUSTED verdict until resolved: re-fetch the page live once, and if the paths still differ
the metric is quarantined and the snapshot stays UNTRUSTED. Documenting is not resolving.
"""
import re
from pathlib import Path
from decimal import ROUND_HALF_UP, Decimal

from . import embedded

VAL_RE = re.compile(r"^[−\-]?[\d,]+(?:\.\d+)?%?$|^\$[\d,]+(?:\.\d+)?$")
COUNT_RE = re.compile(r"^(\d+) of (\d+) models$")
PRIMARY_RE = re.compile(r": (Score|All-pass Rate)$")
EXTRA_TITLES = {
    "AA-Omniscience Accuracy": "omniscience-accuracy",
    "AA-Omniscience Hallucination Rate": "omniscience-hallucination-rate",
}
# a chart that shows the underlying field of a derived series: chart cid -> (series cid, derived)
CHART_SERIES = {"omniscience-hallucination-rate": ("omniscience-non-hallucination-rate", True)}
CHART_LABELS = {"omniscience-hallucination-rate": "AA-Omniscience Hallucination Rate"}
CID_BY_EVAL = {s["eval_slug"]: cid for cid, s in embedded.SERIES_MAP.items() if s["eval_slug"]}


def parse_chart_sections(text):
    """Chart sections from a rendered capture: [{'title', 'cid_hint', 'n', 'of', 'pairs'}].
    A section is 'N of M models', then N names, then N values. The title is read from the lines
    just above it. Sections whose names or values do not form a clean block are skipped."""
    lines = [l.strip() for l in text.splitlines()]
    out = []
    for i, line in enumerate(lines):
        m = COUNT_RE.match(line)
        if not m:
            continue
        k = int(m.group(1))
        context = [l for l in lines[max(0, i - 5):i] if l]
        hint = None
        for c in context:
            if PRIMARY_RE.search(c):
                hint = "primary"
            elif c in EXTRA_TITLES:
                hint = EXTRA_TITLES[c]
        if hint is None:
            continue
        for start in range(i + 1, i + 8):
            names, vals = lines[start:start + k], lines[start + k:start + 2 * k]
            if len(names) == k and len(vals) == k and not any(VAL_RE.match(n) for n in names) \
                    and all(VAL_RE.match(v) for v in vals):
                out.append({"title": next((c for c in context if PRIMARY_RE.search(c) or c in EXTRA_TITLES), ""),
                            "cid_hint": hint, "n": k, "of": int(m.group(2)), "pairs": list(zip(names, vals))})
                break
    return out


def _shown(raw):
    """(Decimal value, decimals shown, is_percent) of a displayed value, or None. A trailing
    '*' marks an estimated value and is not part of the number."""
    s = raw.replace("−", "-").replace(",", "").replace("$", "").strip().rstrip("*")
    pct = s.endswith("%")
    s = s.rstrip("%")
    try:
        d = Decimal(s)
    except Exception:
        return None
    return d, (len(s.split(".")[1]) if "." in s else 0), pct


def _round_half_up(x, places):
    return x.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


def agrees(b, raw, scale, derived=False):
    """Does full-precision value b (stored scale) render as the shown value `raw`? The shown
    digits decide the rounding, half up. A derived series shows the underlying field, not
    1 minus it. The value is rounded from its shortest decimal form (how the site formats
    it) and, failing that, from its exact binary value. A percent shown for a raw-scale
    series (or the reverse) is a unit disagreement."""
    shown = _shown(raw)
    if shown is None or b is None:
        return False
    want, places, pct = shown
    if pct != (scale == "fraction"):
        return False
    base = (1 - b) if derived else b
    factor = 100 if pct else 1
    # the site formats the value's shortest decimal form; also accept the exact binary value
    for dec in (Decimal(repr(float(base))), Decimal(float(base))):
        if want == _round_half_up(dec * factor, places):
            return True
    return False


def window_index(window):
    """Name lookups inside one page's payload window: (creator, name), name and shortName."""
    by_name, by_short = {}, {}
    for o in window:
        by_name.setdefault(o["name"], []).append(o["slug"])
        if o.get("shortName"):
            by_short.setdefault(o["shortName"], []).append(o["slug"])
    return by_name, by_short


def resolve_label(label, index):
    """The one slug a rendered label names within the page window, else None. A label that
    matches two models is ambiguous and resolves to nothing (fail closed)."""
    by_name, by_short = index
    for table in (by_name, by_short):
        hit = table.get(label)
        if hit and len(set(hit)) == 1:
            return hit[0]
    return None


def rendered_observations(eval_slug, e):
    """Observation dicts for the rendered captures of one eval page (path C): the page's
    first primary chart, each extra chart named in EXTRA_TITLES, and the rendered leaderboard
    rows. Each carries the model key (slug), canonical id, label, value, raw text and capture
    time. Labels resolve through the page's own payload window; an unresolved label is
    returned in `unresolved` terms by compare_all, never guessed here."""
    r = e.get("rendered")
    if not r or not e.get("window"):
        return []
    index = window_index(e["window"])
    base_cid = CID_BY_EVAL.get(eval_slug)
    out, seen = [], set()

    def emit(cid, label_name, raw, kind):
        slug = resolve_label(label_name, index)
        shown = _shown(raw)
        if slug is None or shown is None or cid is None:
            return
        spec = embedded.SERIES_MAP.get(cid)
        out.append({"model": slug, "cid": cid, "label": spec["label"] if spec else CHART_LABELS.get(cid, cid),
                    "value": float(shown[0] / (100 if shown[2] else 1)), "raw": raw,
                    "observed_at": r["at"], "kind": kind, "eval": eval_slug})

    for sec in r.get("charts", []):
        if sec["cid_hint"] in seen:
            continue
        seen.add(sec["cid_hint"])
        cid = base_cid if sec["cid_hint"] == "primary" else sec["cid_hint"]
        for name, raw in sec["pairs"]:
            emit(cid, name, raw, "chart")
    for name, raw in (r.get("rows") or {}).items():
        emit(base_cid, name, raw, "row")
    return out


def _new(cid, path_a, path_b):
    return {"metric": cid, "path_a": path_a, "path_b": path_b, "checked": 0, "agreements": 0,
            "mismatches": [], "notes": [], "pages": set(), "status": "not-compared", "before": None}


def _tally(res, ok, **example):
    res["checked"] += 1
    if ok:
        res["agreements"] += 1
    else:
        res["mismatches"].append(example)
        if example.get("page"):
            res["pages"].add(example["page"])


def compare_all(raw):
    """Run every path pairing over raw evidence. Returns {(metric, path A, path B): result}.
    Compare pages: only the newest row per slug (a re-fetched page supersedes an older one)."""
    from . import collect

    results = {}

    def acc(cid, a, b):
        return results.setdefault((cid, a, b), _new(cid, a, b))

    latest = {slug: lst[-1] for slug, lst in raw["compare"].items()}
    for slug, r in sorted(latest.items()):
        for label, cell in r["table"].items():
            cid = collect.canon_metric_id(label)
            spec = embedded.SERIES_MAP.get(cid)
            if not spec or spec["compare_label"] != label or _shown(cell) is None:
                continue
            res = acc(cid, "comparison-table", "embedded")
            b = r["series"].get(cid)
            ok = b is not None and agrees(b, cell, spec["scale"], spec["derived"])
            why = "table shows a value, payload has none" if b is None else "shown value differs from payload"
            if ok and cid in embedded.ESTIMATED_FLAGS and cell.endswith("*") != (cid in r["attrs"].get("estimated", ())):
                ok, why = False, "asterisk (estimated) disagrees with the payload flag"
            _tally(res, ok, slug=slug, page=("compare", r["page"]), a=cell, b=b, why=why)
    for eslug, e in sorted(raw["evals"].items()):
        cid = CID_BY_EVAL.get(eslug)
        spec = embedded.SERIES_MAP.get(cid)
        window = {o["slug"]: o for o in e["window"]}
        index = window_index(e["window"])
        if e["leaderboard"] and spec:
            res = acc(cid, "eval-leaderboard", "embedded")
            by_cn = {(o["creator"]["name"], o["name"]): o for o in e["window"]}
            names = [o["name"] for o in e["window"]]
            by_name = {o["name"]: o for o in e["window"] if names.count(o["name"]) == 1}
            outside = 0
            for name, rec in e["leaderboard"].items():
                o = by_cn.get((rec["creator"], name)) if rec.get("creator") else by_name.get(name)
                if o is None or rec.get("value") is None:
                    outside += o is None
                    continue
                b = embedded.series_value(o, spec)
                _tally(res, b is not None and agrees(b, rec["raw"], spec["scale"], spec["derived"]),
                       slug=o["slug"], page=("eval", eslug), a=rec["raw"], b=b, why="leaderboard value differs from payload")
            if outside:
                res["notes"].append(f"{eslug}: {outside} leaderboard rows are outside the chart window (not compared)")
        r = e.get("rendered")
        if not r:
            continue
        seen = set()
        for sec in r["charts"]:
            if sec["cid_hint"] in seen:
                continue
            seen.add(sec["cid_hint"])
            ccid = cid if sec["cid_hint"] == "primary" else sec["cid_hint"]
            series_cid, derived = CHART_SERIES.get(ccid, (ccid, False))
            sspec = embedded.SERIES_MAP.get(series_cid)
            if sspec is None:
                continue
            res = acc(series_cid, "embedded", "rendered-chart")
            fallback = 0
            for name, shown in sec["pairs"]:
                slug = resolve_label(name, index)
                if slug is None:
                    _tally(res, False, slug=None, page=("eval", eslug), a=name, b=None, why="chart label matches no model in the page payload")
                    continue
                b = embedded.series_value(window[slug], sspec)
                if b is None and slug in latest:
                    b = latest[slug]["series"].get(series_cid)
                    fallback += 1
                _tally(res, b is not None and agrees(b, shown, sspec["scale"], derived), slug=slug, page=("eval", eslug),
                       a=shown, b=b, why="chart label differs from payload" if b is not None else "chart shows a value, payload has none")
            if fallback:
                res["notes"].append(f"{eslug}: {fallback} values read from the compare-page payload (field absent from the eval-page payload)")
        if r["rows"] and e["leaderboard"] and cid:
            res = acc(cid, "eval-leaderboard", "rendered-chart")
            for name, shown in r["rows"].items():
                rec = e["leaderboard"].get(name)
                if rec is None:
                    _tally(res, False, slug=None, page=("eval", eslug), a=shown, b=None, why="rendered row names no leaderboard row")
                    continue
                a, b = _shown(rec["raw"]), _shown(shown)
                _tally(res, a is not None and b is not None and a[:2] == b[:2], slug=None, page=("eval", eslug),
                       a=rec["raw"], b=shown, why="rendered row differs from leaderboard cell")
    return results


def not_compared(results, raw):
    """Every tracked series, and every table row, that no path pairing checked."""
    done = {k[0] for k, r in results.items() if r["checked"]}
    out = sorted(c for c in embedded.SERIES_MAP if c not in done)
    labels = set()
    for lst in raw["compare"].values():
        for r in lst:
            labels.update(r["table"])
    mapped = {s["compare_label"] for s in embedded.SERIES_MAP.values() if s["compare_label"]}
    return out, sorted(l for l in labels if l not in mapped)


def verdict(results, nc_series):
    checked = sum(r["checked"] for r in results.values())
    mism = sum(len(r["mismatches"]) for r in results.values())
    m = len(nc_series)
    if checked == 0:
        return f"UNTRUSTED (nothing was compared, {m} metrics not compared)"
    if mism:
        return f"UNTRUSTED ({mism} mismatches, {m} metrics not compared)"
    return f"TRUSTED (0 mismatches in {checked} compared values, {m} metrics not compared)"


def describe(checked, mismatches):
    """Claims follow counts: an empty compared set is 'not compared', never zero disagreements."""
    if checked == 0:
        return "not compared"
    return f"{mismatches} disagreements in {checked} values"


GUESSES = ("omniscience-non-hallucination-rate", "mlcraa")


def _page_path(kind, name, raw):
    """(URL path, page kind, requested slugs) of a page that produced a mismatch, rebuilt from exact
    slugs (not from a file name); path is None when the page is not known."""
    if kind == "eval":
        return "/evaluations/" + name, "evaluation", None
    for lst in raw["compare"].values():
        for r in lst:
            if r["page"] == name:
                return "/models/comparisons/" + "-vs-".join(r["batch"]), "compare", set(r["batch"])
    return None, None, None


def run_chartdiff(network=True, log=print):
    """Compare, re-collect each page that disagrees once, compare again. A metric whose paths
    still differ after the re-fetch is quarantined (the snapshot stays UNTRUSTED); a metric
    that agrees after it is resolved. Returns (results, raw, verdict, refetched)."""
    from . import aadb, collect

    raw = aadb.load_raw()
    first = compare_all(raw)
    pages = sorted(set().union(*(r["pages"] for r in first.values())) if first else set())
    refetched = []
    if pages and network:
        for kind, name in pages:
            path, page_kind, requested = _page_path(kind, name, raw)
            if path is None:
                continue
            try:
                collect.fetch_page(path, page_kind, requested, refresh=True, skip_legacy=True)
                refetched.append(path)
            except collect.FetchError as e:
                log(f"[chartdiff] re-fetch failed: {e}")
        log(f"[chartdiff] {len(pages)} pages had mismatches; re-fetched {len(refetched)} once")
        raw = aadb.load_raw()
    final = compare_all(raw) if refetched else first
    for key, r in final.items():
        before = len(first[key]["mismatches"]) if key in first else 0
        r["before"] = before
        if r["checked"] == 0:
            r["status"] = "not-compared"
        elif not r["mismatches"]:
            r["status"] = "agree" if before == 0 else "resolved"
        else:
            r["status"] = "quarantined" if refetched else "mismatch"
    nc_series, nc_labels = not_compared(final, raw)
    return final, raw, verdict(final, nc_series), refetched


def save_runs(conn, results, nc_series, ran_at):
    """Replace reconcile_runs with this run: one row per metric and path pairing, plus a
    not-compared row for each tracked series no pairing checked."""
    with conn:
        conn.execute("DELETE FROM reconcile_runs")
        for (cid, a, b), r in sorted(results.items()):
            note = "; ".join(r["notes"] + [f"{m.get('slug')}: {m.get('why')} (shown {m.get('a')!r}, payload {m.get('b')!r})"
                                           for m in r["mismatches"][:5]])
            if r["before"]:
                note = f"{r['before']} mismatches before re-fetch; " + note
            conn.execute(
                "INSERT INTO reconcile_runs (ran_at, metric_id, path_a, path_b, checked, agreements, mismatches, status, notes) "
                "VALUES (?,?,?,?,?,?,?,?,?)", (ran_at, cid, a, b, r["checked"], r["agreements"], len(r["mismatches"]), r["status"], note))
        for cid in nc_series:
            conn.execute(
                "INSERT INTO reconcile_runs (ran_at, metric_id, path_a, path_b, checked, agreements, mismatches, status, notes) "
                "VALUES (?,?,?,?,?,?,?,?,?)", (ran_at, cid, "-", "-", 0, 0, 0, "not-compared", "no path pairing had values for this series"))


def write_report(path, results, raw, verdict_line, nc, refetched, ran_at):
    """reconcile.md: the verdict line, one row per metric and path pairing, every mismatch,
    what was not compared, and the evaluation pages with no comparison at all."""
    nc_series, nc_labels = nc
    order = sorted(results.items(), key=lambda kv: (kv[0][0] not in GUESSES, kv[0]))
    lines = ["# Reconciliation report: collection vs charts", "", f"Run: {ran_at}", "", f"**Verdict: {verdict_line}**", "",
             "Paths: A = server-rendered table or leaderboard cell; B = full-precision payload value; C = rendered chart label.",
             "B is rounded to the digits the shown value carries before comparing. 'not compared' means the compared set was empty;",
             "it never means zero disagreements. A mismatch is re-fetched live once, then quarantined: the snapshot stays UNTRUSTED until none remain.",
             "Definition checks first: omniscience-non-hallucination-rate (derived as 1 minus the payload field, confirmed against the chart's hallucination rate) and mlcraa (mlcrOverall confirmed against the MLCR-AA chart).", "",
             "| metric | path A | path B | result | status | notes |", "|---|---|---|---|---|---|"]
    for (cid, a, b), r in order:
        note = "; ".join(r["notes"])[:200]
        lines.append(f"| {cid} | {a} | {b} | {describe(r['checked'], len(r['mismatches']))} ({r['agreements']} agree) | {r['status']} | {note} |")
    for cid in nc_series:
        lines.append(f"| {cid} | - | - | not compared | not-compared | no path pairing had values |")
    bad = [(k, m) for k, r in order for m in r["mismatches"]]
    lines += ["", f"## Mismatches ({len(bad)})", ""]
    for (cid, a, b), m in bad[:200]:
        lines.append(f"- {cid} [{a} vs {b}] {m.get('slug')}: {m.get('why')}; shown {m.get('a')!r}, payload {m.get('b')!r}; page {m.get('page')}")
    if not bad:
        lines.append("None in the compared set.")
    lines += ["", f"Pages re-fetched once for mismatches: {len(refetched)}", "", "## Not compared", "",
              "Series with no path pairing: " + (", ".join(nc_series) or "none"), "",
              "Comparison-table rows with no payload counterpart (shown values are stored, not cross-checked): " + (", ".join(nc_labels) or "none"), "",
              "## Evaluation pages", "", "| page | leaderboard rows | payload window | chart sections | compared values |", "|---|---|---|---|---|"]
    for eslug, e in sorted(raw["evals"].items()):
        cid = CID_BY_EVAL.get(eslug)
        n = sum(r["checked"] for (c, _, _), r in results.items() if c == cid) if cid else 0
        lines.append(f"| {eslug} | {len(e['leaderboard'])} | {len(e['window'])} | {len((e.get('rendered') or {}).get('charts', []))} | {n or 'not compared'} |")
    for s in raw.get("skipped_evals", []):
        lines.append(f"| {s['slug']} | - | - | - | not compared: {s['reason']} |")
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def selftest():
    """Fixtures: the all-wrong second source must produce mismatches, an empty compared set must
    read 'not compared', rounding follows the shown digits, labels resolve exactly or not at all."""
    assert agrees(0.8566, "85.7%", "fraction") and not agrees(0.8566, "85.6%", "fraction")
    assert agrees(0.8566, "86%", "fraction") and not agrees(0.8566, "85%", "fraction")
    assert agrees(1.69925, "$1.6993", "quantity") and agrees(57.62, "58", "raw") and not agrees(57.62, "57", "raw")
    assert agrees(0.25, "75%", "fraction", derived=True) is True, "a derived series is judged as 1 minus the stored value"
    assert not agrees(0.25, "25%", "fraction", derived=True)
    assert not agrees(57.62, "58%", "raw") and not agrees(0.5, "50", "fraction"), "percent and raw scales never mix"
    assert agrees(-9.6, "\u221210", "raw"), "unicode minus"
    assert describe(0, 0) == "not compared" and describe(5, 0) == "0 disagreements in 5 values"
    text = "\n".join(["Header", "X: Score", "Independently benchmarked", "3 of 99 models", "No publicly available API",
                      "Alpha (max)", "Beta (high)", "Gamma", "50.0%", "40.0%", "30.0%",
                      "X: Score vs. Cost per Task", "desc", "3 of 99 models", "Alpha (max)", "$1", "$2", "$3",
                      "AA-Omniscience Accuracy", "desc", "1 of 99 models", "Alpha (max)", "40%"])
    secs = parse_chart_sections(text)
    assert [(s["cid_hint"], s["n"]) for s in secs] == [("primary", 3), ("omniscience-accuracy", 1)], secs
    assert secs[0]["pairs"] == [("Alpha (max)", "50.0%"), ("Beta (high)", "40.0%"), ("Gamma", "30.0%")]

    def obj(slug, name, short, **extra):
        return {"slug": slug, "name": name, "shortName": short, "creator": {"name": "Acme"}, **extra}

    window = [obj("a", "Alpha (Max)", "Alpha (max)", gpqa=0.50), obj("b", "Beta (High)", "Beta (high)", gpqa=0.40),
              obj("c", "Gamma", "Gamma", gpqa=0.30), obj("d", "Alpha", "Alpha (max)", gpqa=0.1)]
    assert resolve_label("Beta (high)", window_index(window)) == "b"
    assert resolve_label("Alpha (max)", window_index(window)) is None, "a label naming two models resolves to nothing"
    assert resolve_label("Nobody", window_index(window)) is None
    page = {"ts": "t", "leaderboard": {}, "window": window[:3], "rendered": {"at": "t", "rows": {}, "charts": secs[:1]}}
    raw = {"compare": {}, "evals": {"gpqa-diamond": page}, "skipped": [], "quarantined": [], "skipped_evals": []}
    res = compare_all(raw)
    r = res[("gpqadiamond", "embedded", "rendered-chart")]
    assert (r["checked"], r["agreements"], len(r["mismatches"])) == (3, 3, 0), r
    wrong = {"compare": {}, "evals": {"gpqa-diamond": dict(page, rendered={"at": "t", "rows": {}, "charts": [dict(secs[0], pairs=[(n, "99.9%") for n, _ in secs[0]["pairs"]])]})},
             "skipped": [], "quarantined": [], "skipped_evals": []}
    rw = compare_all(wrong)[("gpqadiamond", "embedded", "rendered-chart")]
    assert rw["checked"] == 3 and len(rw["mismatches"]) == 3, "an all-wrong second source must produce mismatches"
    unknown = dict(secs[0], pairs=[("Nobody", "50.0%")])
    ru = compare_all({"compare": {}, "evals": {"gpqa-diamond": dict(page, rendered={"at": "t", "rows": {}, "charts": [unknown]})},
                      "skipped": [], "quarantined": [], "skipped_evals": []})[("gpqadiamond", "embedded", "rendered-chart")]
    assert len(ru["mismatches"]) == 1 and "matches no model" in ru["mismatches"][0]["why"], "an unresolved label is a mismatch, not a skip"
    empty = compare_all({"compare": {}, "evals": {}, "skipped": [], "quarantined": [], "skipped_evals": []})
    assert empty == {} and verdict(empty, ["gpqadiamond"]).startswith("UNTRUSTED (nothing was compared"), "an empty compared set is never a clean verdict"
    assert verdict(res, []).startswith("TRUSTED (0 mismatches in 3 compared values")
    assert verdict(compare_all(wrong), ["x"]) == "UNTRUSTED (3 mismatches, 1 metrics not compared)"
    row = {"attrs": {"estimated": ["intelligence-index"]}, "series": {"intelligence-index": 6.8, "scicode": 0.5}, "page": "p", "batch": ["a"],
           "table": {"Intelligence Index": "7*", "SciCode": "50%"}, "observed_at": "t"}
    star = compare_all({"compare": {"a": [row]}, "evals": {}, "skipped": [], "quarantined": [], "skipped_evals": []})
    assert star[("intelligence-index", "comparison-table", "embedded")]["agreements"] == 1, "an asterisk marks an estimated value"
    row2 = dict(row, attrs={"estimated": []})
    flagged = compare_all({"compare": {"a": [row2]}, "evals": {}, "skipped": [], "quarantined": [], "skipped_evals": []})
    assert len(flagged[("intelligence-index", "comparison-table", "embedded")]["mismatches"]) == 1, "an asterisk without the payload flag disagrees"
