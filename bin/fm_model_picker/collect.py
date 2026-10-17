#!/usr/bin/env python3
"""
Model-picker collector: Artificial Analysis full-site extraction + chart reconciliation.

Extracts, per evaluation page:
  1. leaderboard <table> rows (definitive path: rank, creator, model, value, CI, date)
  2. chart <text> label sequences (second path: model names + value labels as rendered)
  3. ld+json Dataset blocks (metric provenance: names/descriptions/units)
and per model page: intelligence index, output speed, cost per task, prices.

Then reconciles: same metric from the table path vs the chart-label path must agree.
Mismatches are reported, never silently dropped.

The operational wrapper is bin/fm-model-picker.sh (its header owns the CLI).
Data root: FM_MODEL_PICKER_DATA, else <data dir>/model-picker (docs/configuration.md).
"""
import hashlib
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import html as htmllib
from decimal import Decimal
from pathlib import Path

from . import aadb, chartdiff, embedded

BASE = "https://artificialanalysis.ai"
UA = "model-picker-collector/1.0 (personal research; low-frequency; cache-first)"
DELAY = 0.8
ATTEMPTS = 3
NEG_MAX_AGE = None  # seconds; set from --stale-after-hours so a daily run re-asks about old 404s
ANCHOR = "claude-opus-5-5"
ALT_ANCHOR = "claude-sonnet-5-5"
CODE_ROOT = Path(__file__).resolve().parents[2]


def data_root(env=None):
    """FM_MODEL_PICKER_DATA, else <data dir>/model-picker; the data dir follows
    FM_DATA_OVERRIDE, then FM_HOME, then FM_ROOT_OVERRIDE, then the code root."""
    env = os.environ if env is None else env
    if env.get("FM_MODEL_PICKER_DATA"):
        return Path(env["FM_MODEL_PICKER_DATA"])
    home = Path(env.get("FM_HOME") or env.get("FM_ROOT_OVERRIDE") or CODE_ROOT)
    return Path(env.get("FM_DATA_OVERRIDE") or home / "data") / "model-picker"


HERE = data_root()
RAW = HERE / "raw"
NEG_FILE = RAW / "_http_404.jsonl"


def configure(root):
    """Point every output at one data root (the CLI default and the test fixtures)."""
    global HERE, RAW, NEG_FILE
    HERE = Path(root)
    RAW = HERE / "raw"
    NEG_FILE = RAW / "_http_404.jsonl"

EVAL_SLUGS = [
    "artificial-analysis-intelligence-index", "artificial-analysis-openness-index",
    "aa-briefcase", "gdpval-aa", "aa-3d", "apex-agents-aa", "aa-analyst-agent",
    "automationbench-aa", "harvey-lab-aa", "gdp-pdf", "enterprise-ops-gym-aa",
    "terminalbench-4-0", "terminal-bench-science", "frontiercode",
    "artificial-analysis-long-context-reasoning", "omniscience", "scicode",
    "humanitys-last-exam", "critpt", "gpqa-diamond", "itbench-aa", "mmmu-pro",
    "ifbench", "mlcr-aa", "tau3-banking", "terminalbench-2-1", "terminalbench-hard",
    "tau2-bench", "mmlu-pro", "livecodebench", "math-500", "aime-2025",
    "global-mmlu-lite",
]

TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")


def clean(fragment: str) -> str:
    return WS_RE.sub(" ", htmllib.unescape(TAG_RE.sub(" ", fragment))).strip()


FETCH_TS = {}


_sleep = time.sleep
_urlopen = urllib.request.urlopen


class FetchError(Exception):
    """A failed fetch. status is the HTTP code, or None for a network failure."""

    def __init__(self, path, status, detail=""):
        super().__init__(f"{path}: HTTP {status}" if status else f"{path}: {detail}")
        self.path, self.status = path, status


class CacheMiss(FetchError):
    """The page is not in cache and network use is off."""

    def __init__(self, path):
        super().__init__(path, None, "not in cache and network use is off")


class Rejected(FetchError):
    """The page loaded (HTTP 200) but does not parse. `why` is the reason page_problem gave."""

    def __init__(self, path, why):
        super().__init__(path, None, "page rejected: " + (why if isinstance(why, str) else why["reason"]))
        self.why = why


class Fetched:
    """One page: its text, its real fetch time ('unknown' without a sidecar), and whether it
    came from cache."""

    def __init__(self, text, ts, cached):
        self.text, self.ts, self.cached = text, ts, cached


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


_SAFE_RE = re.compile(r"[^A-Za-z0-9._=?&%+,~-]")


def _legacy_stem(path):
    return path.strip("/").replace("/", "_")


def cache_file(path):
    """Cache file for a URL path. A name over 150 characters is cut and gets a sha1
    suffix, so two long batches can never share one file."""
    name = _SAFE_RE.sub("_", _legacy_stem(path))
    if len(name) > 150:
        name = name[:150] + "-" + hashlib.sha1(path.encode("utf-8")).hexdigest()[:10]
    return RAW / (name + ".html")


_NEG = {"file": None, "records": {}}


def _neg_records():
    """Every remembered 404, the newest record per URL. NEG_FILE is read once per process, and
    again only when NEG_FILE changes; remember_404 keeps the memory and the file in step."""
    if _NEG["file"] != NEG_FILE:
        records = {}
        if NEG_FILE.exists():
            for line in NEG_FILE.read_text(encoding="utf-8").splitlines():
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(rec, dict) and rec.get("url") and (rec["url"] not in records or str(rec.get("at")) >= str(records[rec["url"]].get("at"))):
                    records[rec["url"]] = rec
        _NEG["file"], _NEG["records"] = NEG_FILE, records
    return _NEG["records"]


def _neg_fresh(rec, now=None):
    try:
        age = aadb.snapshot_age_seconds(rec.get("at"), now)
    except (ValueError, TypeError):
        return False
    return NEG_MAX_AGE is None or (age is not None and age <= NEG_MAX_AGE)


def load_404s(now=None):
    """Remembered 404s. With NEG_MAX_AGE set, an older memory is ignored so a page the site
    later adds is requested again."""
    return {url: rec for url, rec in _neg_records().items() if _neg_fresh(rec, now)}


def remembered_404(path, now=None):
    rec = _neg_records().get(path)
    return rec is not None and _neg_fresh(rec, now)


def remember_404(path, at):
    """One record per URL: a repeated 404 replaces its line, so the file never grows with repeats."""
    records = _neg_records()
    records[path] = {"url": path, "at": at, "status": 404}
    _atomic_write(NEG_FILE, "".join(json.dumps(rec) + "\n" for rec in records.values()))


def _retry_after(err):
    try:
        return min(float(err.headers.get("Retry-After", "")), 120.0)
    except (AttributeError, TypeError, ValueError):
        return 0.0


def fetch_page(path, kind, requested, refresh=False, network=True, skip_legacy=False):
    """Cache-first. refresh=True revalidates; network=False raises on a cache miss.
    Every source keeps its original fetch timestamp - a run never redates stale data.
    A remembered 404 makes no network call. DELAY follows every network attempt.
    Every body it returns, fetched or cached, passed page_problem for `kind`; a body that does
    not parse raises Rejected, and a fetched one leaves the last good copy and its .ts untouched.
    `requested` is the exact slug set a compare page must hold (None for every other kind)."""
    new = cache_file(path)
    legacy = RAW / (_legacy_stem(path)[:180] + ".html")
    found = [c for c in ([] if skip_legacy else [legacy]) + [new] if c.exists()]
    if found and not refresh:
        cache = found[0]
        ts_file = Path(str(cache) + ".ts")
        ts = ts_file.read_text(encoding="utf-8").strip() if ts_file.exists() else "unknown"
        text = cache.read_text(encoding="utf-8", errors="replace")
        why = page_problem(kind, path, text, ts, requested)
        if why is not None:
            raise Rejected(path, why)
        FETCH_TS[path] = ts
        return Fetched(text, ts, True)
    if remembered_404(path):
        raise FetchError(path, 404, "remembered 404")
    if not network:
        raise CacheMiss(path)
    last = None
    for attempt in range(ATTEMPTS):
        wait = 2 * (2 ** attempt)
        try:
            req = urllib.request.Request(BASE + path, headers={"User-Agent": UA})
            # measured: value=60 date=2026-10-17 host=Mac-Studio margin=17x (110 live page fetches, slowest 3.45s, p50 1.05s)
            with _urlopen(req, timeout=60) as resp:
                data = resp.read().decode("utf-8", errors="replace")
            now = utc_now()
            why = page_problem(kind, path, data, now, requested)
            if why is None:
                RAW.mkdir(parents=True, exist_ok=True)
                tmp = new.with_name(new.name + ".tmp")
                tmp.write_text(data, encoding="utf-8")
                os.replace(tmp, new)
                Path(str(new) + ".ts").write_text(now, encoding="utf-8")
                FETCH_TS[path] = now
            _sleep(DELAY)
            if why is not None:
                raise Rejected(path, why)
            return Fetched(data, now, False)
        except urllib.error.HTTPError as e:
            _sleep(DELAY)
            if e.code == 404:
                remember_404(path, utc_now())
                raise FetchError(path, 404, str(e))
            last = FetchError(path, e.code, str(e))
            if e.code != 429 and e.code < 500:
                raise last
            wait = max(wait, _retry_after(e))
        except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
            _sleep(DELAY)
            last = FetchError(path, None, str(e))
        if attempt + 1 < ATTEMPTS:
            _sleep(wait)
    raise last


def extract_tables(page: str):
    """Parse HTML tables preserving header structure: each table is
    {head: [thead rows], rows: head + body rows}. Header selection downstream is
    structural (thead first) — never substring-scored against metric values."""
    tables = []
    for tbl in re.findall(r"<table[^>]*>(.*?)</table>", page, re.S):
        head_rows = []
        for thead in re.findall(r"<thead[^>]*>(.*?)</thead>", tbl, re.S):
            for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", thead, re.S):
                cells = [clean(td) for td in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", tr, re.S)]
                if cells:
                    head_rows.append(cells)
        body = re.sub(r"<thead[^>]*>.*?</thead>", " ", tbl, flags=re.S)
        body_rows = []
        for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", body, re.S):
            cells = [clean(td) for td in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", tr, re.S)]
            if cells:
                body_rows.append(cells)
        if head_rows or body_rows:
            tables.append({"head": head_rows, "rows": head_rows + body_rows})
    return tables


VALUEISH_RE = re.compile(r"^[\d.,%$−\-*+\s]*$")


def looks_like_model_name(name: str) -> bool:
    """A model name must contain letters and no percent signs — '0%' is not a model."""
    return bool(name) and bool(re.search(r"[a-z]", name.lower())) and "%" not in name and not VALUEISH_RE.match(name)


def extract_chart_labels(page: str):
    # recharts SVG text nodes, in document order, with coordinates for pairing
    labels = []
    for m in re.finditer(r"<text[^>]*?x=\"([\d.]+)\"[^>]*?y=\"([\d.]+)\"[^>]*>(.*?)</text>", page, re.S):
        labels.append({"x": float(m.group(1)), "y": float(m.group(2)), "t": clean(m.group(3))})
    return [l for l in labels if l["t"]]


def extract_ldjson(page: str):
    blocks = []
    for m in re.finditer(r'<script type="application/ld\+json">(.*?)</script>', page, re.S):
        try:
            blocks.append(json.loads(m.group(1)))
        except json.JSONDecodeError:
            pass
    return blocks


VALUE_RE = re.compile(r"^[−\-]?[\d,]+(?:\.\d+)?%?$|^\$[\d,]+(?:\.\d+)?$")


LEAD_NUM_RE = re.compile(r"^[−\-]?[\d,]+(?:\.\d+)?%?")


def parse_leaderboard(rows):
    """Parse a leaderboard table: [rank, creator, name, value, CI, date] shape. A table whose
    header has no 'Creator' column (AA-3D: rank, range, model, Elo) carries no creator. The fifth
    column is the interval only when its header says CI or interval (on other pages it is another
    metric and ci is None). A value cell with trailing text ('1197 +/-33 95% interval ...') keeps
    its leading number as the value and the rest as the interval."""
    out = {}
    header = rows[0] if rows else []
    creator_col = len(header) > 1 and header[1].strip().lower() == "creator"
    ci_col = len(header) > 4 and re.search(r"\bci\b|interval", header[4], re.I) is not None
    for cells in rows[1:]:  # skip header
        if len(cells) >= 4 and cells[0].isdigit():
            name = cells[2]
            m = LEAD_NUM_RE.match(cells[3].strip())
            tok = m.group(0) if m else cells[3]
            rest = cells[3].strip()[len(tok):].strip() if m else ""
            ci = cells[4] if ci_col and len(cells) > 4 else (rest or None)
            rec = {"raw": tok, "ci": ci, "rank": int(cells[0]), "creator": cells[1] if creator_col else None}
            raw_val = tok.replace("−", "-").replace(",", "")
            try:
                rec["value"] = float(raw_val.rstrip("%")) / (100 if raw_val.endswith("%") else 1)
            except ValueError:
                rec["value"] = None
            out[name] = rec
    return out


def parse_val(raw):
    """A shown number as a float; '%' divides by 100. A trailing '*' (an estimated value) is dropped."""
    v = raw.replace("−", "-").replace(",", "").replace("$", "").rstrip("*")
    try:
        return float(v.rstrip("%")) / (100 if raw.endswith("%") else 1)
    except ValueError:
        return None


_NUM = r"(?P<n>\d[\d,]*(?:\.\d+)?)"
MAGNITUDE = {"k": Decimal(10) ** 3, "M": Decimal(10) ** 6, "B": Decimal(10) ** 9, "T": Decimal(10) ** 12}
# (unit, cell pattern, factor): the cell states the unit; a k/M/B/T suffix sets the factor itself.
CELL_RULES = (
    ("usd", re.compile(rf"\${_NUM}$"), Decimal(1)),
    ("tokens/s", re.compile(rf"{_NUM} tokens/s$"), Decimal(1)),
    ("s", re.compile(rf"{_NUM}s$"), Decimal(1)),
    ("s", re.compile(rf"{_NUM}ms$"), Decimal("0.001")),
    ("tokens", re.compile(rf"{_NUM}(?P<mag>[kMBT]) tokens(?:\s|$)"), Decimal(1)),
    ("count", re.compile(rf"{_NUM}(?P<mag>[kMBT])$"), Decimal(1)),
)


def parse_cell(raw):
    """(value, unit) of a shown table cell; (None, None) when it holds no number. The unit comes
    from the cell: '$5.98' usd, '95 tokens/s', '10.19s' and '250ms' (stored in s), '128k tokens
    ~192 A4 pages' tokens, a percent fraction. A bare '37k', '260M' or '37B' is expanded to a
    plain count (the label says what is counted). A bare number has no unit."""
    cell = raw.strip().rstrip("*")
    for unit, rx, factor in CELL_RULES:
        m = rx.match(cell)
        if m:
            mag = m.groupdict().get("mag")
            return float(Decimal(m["n"].replace(",", "")) * (MAGNITUDE[mag] if mag else factor)), unit
    value = parse_val(cell)
    return value, ("fraction" if value is not None and cell.endswith("%") else None)


def norm_name(name: str):
    """Canonical model key: base name + effort variant.

    Handles AA's two spellings of the same variant:
    '(max with fallback)' and '(Max, Default Fallback)' both -> 'max'."""
    n = name.lower().replace(" ", " ")
    n = WS_RE.sub(" ", n).strip()
    effort = ""
    m = re.search(r"\(([^)]*)\)", n)
    if m:
        effort = m.group(1).split(",")[0].split(" with")[0].strip()
        n = n.replace(m.group(0), "").strip()
    return f"{n}|{effort}"


def reconcile_eval(slug: str, page: str, tables, chart_labels, rendered=None):
    """Cross-check extraction paths for one eval.

    Primary comparison: SSR table vs rendered chart section (names in rank order,
    values in the same order). Only models present in BOTH paths are compared."""
    report = {"slug": slug, "table_models": 0, "rendered_sections": 0, "checked": 0,
              "mismatches": [], "agreements": 0, "coverage_gaps": 0, "note": ""}
    t0 = tables[0] if tables else None
    t0_rows = t0["rows"] if isinstance(t0, dict) else t0
    board = parse_leaderboard(t0_rows) if t0_rows else {}
    report["table_models"] = len(board)
    rendered = rendered or {}
    r_rows = rendered.get("rows", {}) if isinstance(rendered, dict) else {}
    r_charts = rendered.get("charts", {}) if isinstance(rendered, dict) else {}
    report["rendered_sections"] = (len(r_charts) + (1 if r_rows else 0)) if rendered else 0
    if not board and not rendered:
        report["note"] = "no extracted values on either path"
    elif not board:
        report["note"] = f"rendered path only ({len(r_rows)} leaderboard rows + {sum(len(p) for p in r_charts.values())} chart pairs across {len(r_charts)} sections) — no table for cross-check"
    elif not rendered:
        report["note"] = "table path only — rendered capture missing for this page"
    else:
        # Second-source selection by METRIC IDENTITY — never by score agreement.
        # Agreement-based selection hides exactly the corruption this gate exists
        # to catch (an all-wrong second source scores 0 matches and vanished).
        tokens = [w for w in re.split(r"[^a-z0-9]+", slug.lower()) if len(w) > 2]
        candidates = {}
        if r_rows:
            candidates["rendered leaderboard rows"] = r_rows
        for sec, pairs in r_charts.items():
            if any(t in sec.lower() for t in tokens):
                candidates[f"chart '{sec}'"] = pairs
        if not candidates:
            report["note"] = "no second source with matching metric identity"
        else:
            board_norm = {norm_name(n): (n, rec) for n, rec in board.items() if rec["value"] is not None}
            notes, max_shared = [], 0
            for label, pairs in candidates.items():
                shared = []
                for rn, raw in pairs.items():
                    hit = board_norm.get(norm_name(rn))
                    if hit:
                        shared.append((hit[0], rn, raw, hit[1]["value"]))
                if not shared:
                    notes.append(f"{label}: 0 shared models")
                    continue
                max_shared = max(max_shared, len(shared))
                agree = 0
                for tname, rname, raw, tv in shared:
                    pv = parse_val(raw)
                    if pv is not None and abs(pv - tv) < 1e-6:
                        agree += 1
                    else:
                        report["mismatches"].append({"model": tname, "table": f"{tv}", "rendered": f"{rname}={raw}"})
                report["checked"] += len(shared)
                report["agreements"] += agree
                notes.append(f"{label}: {len(shared)} compared")
            report["note"] = "; ".join(notes)
            report["coverage_gaps"] = max(0, len(board) - max_shared)
    return report


def parse_model_page(page: str):
    txt = re.sub(r"<script[^>]*>.*?</script>", " ", page, flags=re.S)
    txt = re.sub(r"<style[^>]*>.*?</style>", " ", txt, flags=re.S)
    txt = WS_RE.sub(" ", htmllib.unescape(TAG_RE.sub(" ", txt)))
    out = {}
    m = re.search(r"(\d+(?:\.\d+)?)\s+Artificial Analysis Intelligence Index", txt)
    if m:
        out["intelligence_index"] = float(m.group(1))
    m = re.search(r"(\d+(?:\.\d+)?)\s+Output tokens per second", txt)
    if m:
        out["output_speed_tps"] = float(m.group(1))
    m = re.search(r"\$([\d.]+)\s+Cost per Intelligence Index task", txt)
    if m:
        out["cost_per_index_task_usd"] = float(m.group(1))
    m = re.search(r"In \$([\d.]+)Out \$([\d.]+)", txt)
    if m:
        out["price_in"] = float(m.group(1))
        out["price_out"] = float(m.group(2))
    return out


def parse_rendered_sections(text: str):
    """Extract two second-path structures from a rendered page's innerText:
    'rows': leaderboard rows rendered as tab-separated lines (model, value, CI, date)
    'charts': chart sections listing model names in rank order followed by value lists."""
    rows = {}
    for line in text.splitlines():
        if "\t" in line:
            cells = [c.strip() for c in line.split("\t") if c.strip()]
            if (len(cells) >= 2 and len(cells[0]) > 3 and not VALUE_RE.match(cells[0])
                    and parse_val(cells[1]) is not None):
                rows.setdefault(cells[0], cells[1])
    out = {}
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    names, values, section = [], [], ""
    def flush():
        if names and values and len(names) == len(values):
            out[section or "unnamed"] = {n: v for n, v in zip(names, values)}
    for line in lines:
        if "\t" in line:
            continue
        if VALUE_RE.match(line):
            values.append(line)
        elif len(line) > 3 and not line.startswith(("http", "$", "#")):
            if values:
                flush()
                names, values, section = [], [], line
            else:
                if not names:
                    section = line
                names.append(line)
        else:
            if names and values:
                flush()
                names, values = [], []
    flush()
    return {"rows": rows, "charts": out}


MODEL_NON_SLUGS = {"recommend", "comparisons", "multilingual", "caching", "compare",
                   "creators", "releases", "capabilities", "providers"}


def extract_model_catalog(page):
    """The compare page embeds the selector's FULL model catalog as JSON objects
    {"slug":...,"name":...,"deprecated":...,"releaseDate":...,"creator":{...}} —
    the authoritative model universe (the sitemap omits many real models).
    Creator objects ({"slug","name","logo"}) don't match this shape and can't leak in."""
    un = page.replace('\\"', '"')
    entries = re.findall(
        r'\{"slug":"([^"]+)","name":"([^"]*)","deprecated":(true|false),"releaseDate":"([^"]*)"'
        r'(?:,"creator":\{"slug":"([^"]*)","name":"([^"]*)")?', un)
    cat = {}
    for slug, name, dep, rel, cs, cn in entries:
        if slug in MODEL_NON_SLUGS or slug in EVAL_SLUGS:
            continue
        cat[slug] = {"name": name, "deprecated": dep == "true",
                     "releaseDate": rel, "creator": cn or cs or ""}
    return cat


def discover(refresh=True, network=True):
    """Dynamic per-run model universe from BOTH sources: the site's sitemap and the compare
    page's embedded selector catalog. Never a baked URL. Preserves EXACT URL path identifiers
    (dots, case, digits: 'qwen2.5-32b-instruct', 'QwQ-32B-Preview' are valid model IDs).
    Returns the sorted slugs, the catalog, the catalog's creator slugs, and the pages that were rejected
    (the last good copy was read instead; with none, the rejection ends the run)."""
    incomplete = []

    def page(path, kind):
        try:
            return fetch_page(path, kind, None, refresh=refresh, network=network).text
        except Rejected as e:
            incomplete.append(str(e))
            try:
                return fetch_page(path, kind, None, network=False).text
            except FetchError:
                raise e

    xml = page("/sitemap.xml", "sitemap")
    slugs = set()
    for u in re.findall(r"<loc>([^<]+)</loc>", xml):
        m = re.search(r"/models/([^/?#]+)/?$", u)
        if m and m.group(1) not in MODEL_NON_SLUGS:
            slugs.add(m.group(1))
    selector = page("/models/comparisons", "catalog")
    catalog = extract_model_catalog(selector)
    slugs |= set(catalog)
    return {"slugs": sorted(slugs), "catalog": catalog, "creators": extract_creator_slugs(selector), "incomplete": incomplete}


def extract_creator_slugs(page):
    """Creator slugs from the selector catalog's embedded creator objects."""
    return set(re.findall(r'"creator":\{"slug":"([^"]+)"', page.replace('\\"', '"')))


def classify_slugs(slugs, catalog, creator_slugs):
    """Split the discovered universe into model slugs and recorded non-models.
    The selector catalog decides first; a creator slug or site-section name that is not
    in the catalog is not a model and gets a recorded reason instead of a fetch."""
    models, non_models = [], {}
    for s in slugs:
        if s in catalog:
            models.append(s)
        elif s in creator_slugs:
            non_models[s] = "not a model (creator page)"
        elif s in MODEL_NON_SLUGS or s in EVAL_SLUGS:
            non_models[s] = "not a model (site section)"
        else:
            models.append(s)
    return models, non_models


def table_columns(table):
    """Structural comparison-table parse: ((header names, one {metric label: cell} per model
    column), None) or (None, reason). The header comes from <thead>; a first body row is
    accepted only when its model cells look like names (never values like '0%'). The
    'Add model' control cell and any non-name cell are dropped. Identity is NOT decided
    here: the embedded payload decides it (embedded.check_header)."""
    rows = table["rows"] if isinstance(table, dict) else table
    head_rows = table.get("head", []) if isinstance(table, dict) else []
    header = head_rows[0] if head_rows else None
    if header is None and rows:
        cand = rows[0]
        if sum(1 for c in cand[1:] if looks_like_model_name(c)) >= 2:
            header = cand
    if not header:
        return None, "no structural header row"
    keep = [i for i, c in enumerate(header)
            if i > 0 and c and "add model" not in c.lower() and looks_like_model_name(c)]
    cols = [{} for _ in keep]
    for r in rows:
        if len(r) < 2 or not r[0] or r[0] == header[0]:
            continue
        for pos, i in enumerate(keep):
            if i < len(r) and r[i]:
                cols[pos][r[0]] = r[i]
    return ([header[i] for i in keep], cols), None


def ingest_compare_page(text, ts, path, requested=None):
    """One compare page -> ({slug: row}, None) or (None, reason). Identity is exact: the table
    header must equal the payload names in order (embedded.check_header), and when the URL's
    slug set is known it must equal the slug set of the table's columns. Anything else is a
    recorded failure, never an ingest. `ts` is the page's real fetch time."""
    tables = extract_tables(text)
    if not tables:
        return None, "no table"
    cols, why = table_columns(tables[0])
    if cols is None:
        return None, why
    names, table_cols = cols
    parsed = embedded.parse_compare_page(text, names)
    if parsed["quarantine"]:
        return None, "quarantined: " + parsed["quarantine"]
    shown = parsed["objects"][:len(names)]
    got = [o["slug"] for o in shown]
    if requested is not None and set(got) != set(requested):
        return None, {"reason": "identity mismatch", "requested": sorted(requested), "returned": sorted(got)}
    rows = {}
    for idx, o in enumerate(shown):
        rows[o["slug"]] = {"attrs": embedded.model_attrs(o), "series": embedded.model_series(o),
                           "table": table_cols[idx], "observed_at": ts, "page": path, "batch": got}
    return rows, None


def page_problem(kind, path, text, ts, requested):
    """None when a body is fit to be a cached page of this kind, else the reason it is not. The
    one judge: fetch_page applies it to every body it returns. Compare page (kind "compare"):
    table, payload, matching header and exactly the `requested` slugs. Evaluation page: a table
    or a payload. Sitemap: <loc> entries. Selector catalog: models. Cohort model page: model facts."""
    if kind == "compare":
        if requested is None:
            raise TypeError("a compare page is judged against the slugs requested for it")
        return ingest_compare_page(text, ts, path, requested)[1]
    if kind == "evaluation":
        if extract_tables(text) or embedded.extract_array(text, embedded.EVAL_MARKER)[0] is not None:
            return None
        return "no table or payload"
    if kind == "sitemap":
        return None if "<loc>" in text else "no <loc> entries"
    if kind == "catalog":
        return None if extract_model_catalog(text) else "no model catalog"
    if kind == "cohort":
        return None if parse_model_page(text) else "no model facts"
    raise ValueError(f"unknown page kind {kind!r}")


def _name_stem(file):
    return file.name[len("models_comparisons_"):-len(".html")]


def ingest_cached_pages(stale_after_hours=None, now=None):
    """Pass 0, no network: every cached compare page that has a payload and a real fetch time.
    `?models=` pages return AA's default table and are never read. A page with no sidecar has
    unknown age and is left for pass 1 to re-fetch; it is never stamped with the current time."""
    rows, skipped, quarantined = {}, [], []
    for f in sorted(RAW.glob("models_comparisons_*.html")):
        if "models=" in f.name:
            skipped.append({"file": f.name, "reason": "banned ?models= route"})
            continue
        ts_file = Path(str(f) + ".ts")
        ts = ts_file.read_text(encoding="utf-8").strip() if ts_file.exists() else "unknown"
        if ts == "unknown":
            skipped.append({"file": f.name, "reason": "age unknown"})
            continue
        if stale_after_hours is not None:
            age = aadb.snapshot_age_seconds(ts, now)
            if age is None or age > stale_after_hours * 3600:
                skipped.append({"file": f.name, "reason": f"older than {stale_after_hours} h"})
                continue
        # a name over 150 characters was cut (and hashed): the URL's slug set cannot be read back from it
        requested = _name_stem(f).split("-vs-") if len(f.name) - len(".html") <= 150 else None
        page_rows, why = ingest_compare_page(f.read_text(encoding="utf-8", errors="replace"), ts, f.name, requested)
        if page_rows is None:
            quarantined.append({"file": f.name, "reason": why, "fetched_at": ts})
            continue
        for slug, row in page_rows.items():
            rows.setdefault(slug, []).append(row)
    for lst in rows.values():
        lst.sort(key=lambda r: r["observed_at"])
    return rows, skipped, quarantined


def _item(targets):
    return {"ask": list(targets), "targets": list(targets), "paired": False}


def sweep_comparisons(slugs, catalog=None, creator_slugs=(), network=True, stale_after_hours=None, log=print):
    """Delta sweep over the discovered universe, on the path route only
    (/models/comparisons/a-vs-b-...; the ?models= route silently returns a default table).
    Pass 0 reads the cache with no network. Pass 1 fetches only the slugs still without
    values, in batches of 5, DELAY after every attempt, one fetch at a time. A 404 batch is
    split; a singleton 404 is retried once paired with an anchor, and only a failed
    anchor-paired retry means unsupported. The anchor is never tested against itself.
    Exit contract: every slug ends with values or a recorded reason (exit_check)."""
    catalog = catalog or {}
    models, non_models = classify_slugs(slugs, catalog, creator_slugs)
    rows, skipped, quarantined = ingest_cached_pages(stale_after_hours)
    failures = dict(non_models)
    todo = [s for s in sorted(models) if s not in rows]
    known = load_404s()
    for s in list(todo):
        # both the lone and the anchor-paired page are remembered 404s: already proven unsupported
        partner = ALT_ANCHOR if s == ANCHOR else ANCHOR
        if "/models/comparisons/" + s in known and "/models/comparisons/" + "-vs-".join([s, partner]) in known:
            failures[s] = "unsupported slug (404 alone and paired with an anchor)"
            todo.remove(s)
    log(f"[sweep] pass 0 (cache, no network): {len([s for s in models if s in rows])} of {len(models)} model slugs have values; "
        f"{len(skipped)} cached pages skipped, {len(quarantined)} quarantined; {len(non_models)} non-models", flush=True)
    pending = [_item(todo[i:i + 5]) for i in range(0, len(todo), 5)]
    done = streak = 0
    stopped = None
    incomplete = []
    while pending:
        item = pending.pop(0)
        ask, targets = item["ask"], item["targets"]
        path = "/models/comparisons/" + "-vs-".join(ask)
        done += 1
        if done % 20 == 0:
            log(f"[sweep] pass 1: {done} requests, {len(pending)} queued, {len(failures)} failures", flush=True)
        try:
            fetched = fetch_page(path, "compare", set(ask), refresh=True, network=network)
        except Rejected as e:
            streak = 0
            for s in targets:
                failures[s] = e.why
            incomplete.append(str(e))
            continue
        except FetchError as e:
            if e.status == 404:
                streak = 0
                if item["paired"]:
                    for s in targets:
                        failures[s] = "unsupported slug (404 alone and paired with an anchor)"
                elif len(targets) > 1:
                    mid = len(targets) // 2
                    pending[0:0] = [_item(targets[:mid]), _item(targets[mid:])]
                else:
                    partner = ALT_ANCHOR if targets[0] == ANCHOR else ANCHOR
                    pending.insert(0, {"ask": [targets[0], partner], "targets": list(targets), "paired": True})
                continue
            for s in targets:
                failures[s] = f"fetch failed: {e}" if network else "not fetched: network use is off"
            if network:
                incomplete.append(str(e))
            streak = streak + 1 if network else 0
            if streak >= 3:
                stopped = f"sweep stopped after {streak} consecutive fetch failures (last: {e})"
                break
            continue
        streak = 0
        page_rows = ingest_compare_page(fetched.text, fetched.ts, path, set(ask))[0]
        for s in targets:
            rows.setdefault(s, []).append(page_rows[s])
            failures.pop(s, None)
    for item in pending:
        for s in item["targets"]:
            failures.setdefault(s, f"not fetched: {stopped}")
    status = {}
    for s in sorted(set(slugs)):
        if s in rows and any(r["series"] or r["table"] for r in rows[s]):
            status[s] = {"status": "values", "reason": ""}
        elif s in rows:
            status[s] = {"status": "failure", "reason": "page loaded, model has no benchmark values"}
        elif s in failures:
            f = failures[s]
            status[s] = {"status": "failure", "reason": f if isinstance(f, str) else json.dumps(f, sort_keys=True)}
    counts = {"universe": len(set(slugs)), "values": sum(1 for v in status.values() if v["status"] == "values"),
              "failures": sum(1 for v in status.values() if v["status"] == "failure"),
              "non_models": len(non_models), "requests": done}
    return {"rows": {s: rows[s] for s in rows if s in set(slugs)}, "status": status, "skipped": skipped,
            "quarantined": quarantined, "counts": counts, "stopped": stopped, "incomplete": incomplete}


def exit_check(universe, status):
    """Each slug has a row set OR a failure record with a reason. Returns the two counts and
    raises SystemExit(1) naming any slug that has neither."""
    bad = sorted(s for s in universe if s not in status or (status[s]["status"] == "failure" and not status[s]["reason"]))
    if bad:
        raise SystemExit(f"exit check failed: {len(bad)} slugs have neither values nor a recorded reason: {bad[:10]}")
    values = sum(1 for s in universe if status[s]["status"] == "values")
    return values, len(universe) - values


def canon_metric_id(label):
    """Canonical metric identity across sources: 'AA-Omniscience' (comparison row),
    'eval-leaderboard:omniscience', and 'AA-Omniscience Index' are ONE series;
    accuracy and non-hallucination rate are distinct series."""
    core = label.split(":", 1)[1] if ":" in label else label
    c = re.sub(r"[^a-z0-9]", "", core.lower())
    aliases = {
        "aaomniscience": "omniscience-index", "aaomniscienceindex": "omniscience-index",
        "omniscience": "omniscience-index",
        "aaomniscienceaccuracy": "omniscience-accuracy",
        "aaomnisciencehallucinationrate": "omniscience-hallucination-rate",
        "aaomnisciencenonhallucinationrate": "omniscience-non-hallucination-rate",
        "aabriefcase": "aa-briefcase-elo", "aabriefcasev11": "aa-briefcase-elo",
        "aabriefcaseelo": "aa-briefcase-elo", "aabriefcaserubricscore": "aa-briefcase-rubric",
        "analyticalqualitypresentationelo": "aa-briefcase-analytical-elo",
        "gdpvalaa": "gdpval-aa-elo", "gdpvalaav21": "gdpval-aa-elo",
        "aalcr": "aa-lcr", "aalcrv11": "aa-lcr",
        "artificialanalysislongcontextreasoning": "aa-lcr",
        "intelligenceindex": "intelligence-index",
        "artificialanalysisintelligenceindex": "intelligence-index",
        "aintelligenceindex": "intelligence-index",
        "artificialanalysisopennessindex": "openness-index",
        "automationbenchaa": "automationbench-aa", "scicode": "scicode",
        "terminalbench40": "terminal-bench-4-0",
    }
    return aliases.get(c, c)


def compute_coverage(snapshot, eval_slugs):
    """Coverage from OBSERVATION COUNTS on canonical metric IDs. A series with a
    present key but zero observations is MISSING; aliased labels count together and a
    model counts once per series. Inputs are raw rows only: "comparisons" (table rows),
    "embedded" (payload series) and "windows" (eval-page chart windows, always partial)
    keyed by model, plus "evals" leaderboards. Never pass a stored coverage block."""
    cov = {}

    def entry(cid):
        return cov.setdefault(cid, {"models": 0, "sources": set(), "partial": False, "_m": set(), "_lb": 0, "_full": False})

    for key, source, full in (("comparisons", "comparison-tool", True), ("embedded", "embedded", True),
                              ("windows", "chart-window", False)):
        for m, metrics in (snapshot.get(key) or {}).items():
            for k in metrics:
                e = entry(canon_metric_id(k))
                e["_m"].add(m)
                e["sources"].add(source)
                e["_full"] = e["_full"] or full
    for slug, e in snapshot.get("evals", {}).items():
        ent = entry(canon_metric_id("eval-leaderboard:" + slug))
        n = len(e.get("leaderboard", {}))
        if n:
            ent["_lb"] = max(ent["_lb"], n)
            ent["sources"].add("eval-page-leaderboard")
            ent["_full"] = True
    for e in cov.values():
        e["models"] = max(len(e["_m"]), e["_lb"])
        e["partial"] = e["models"] > 0 and not e["_full"]
        for k in ("_m", "_lb", "_full"):
            del e[k]
    expected = {canon_metric_id("eval-leaderboard:" + s) for s in eval_slugs}
    for sub in ["AA-Omniscience Accuracy", "AA-Omniscience Non-Hallucination Rate",
                "AA-Omniscience Index", "IFBench", "AA-Briefcase Rubric Score (%)",
                "Analytical Quality & Presentation Elo"]:
        expected.add(canon_metric_id("submetric:" + sub))
    missing = sorted(s for s in expected if cov.get(s, {}).get("models", 0) == 0)
    return cov, missing


def write_coverage(cov, missing, path):
    lines = ["# Coverage per metric/submetric (canonical IDs, count-based)", "",
             "Recomputed by compute_coverage() from raw rows on every run; never copied from a stored block.",
             "Missingness = zero observations, never key absence; aliased labels ('AA-Omniscience' =",
             "Omniscience Index) share one canonical series and a model counts once per series.",
             "A series seen only in the eval-page chart window (top 5 to 31 models) is partial, never complete.", "",
             "| series | sources | models with values | status |", "|---|---|---|---|"]
    for k in sorted(cov):
        v = cov[k]
        status = "not yet captured" if v["models"] == 0 else "partial: chart window only" if v.get("partial") else "captured"
        lines.append(f"| {k} | {'+'.join(sorted(v['sources'])) or '-'} | {v['models']} | {status} |")
    for s in missing:
        if s not in cov:
            lines.append(f"| {s} | - | 0 | not yet captured |")
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_selftest():
    """The reconcile gate must catch an all-wrong second source — not hide it."""
    table = [["", "Creator", "Name", "Elo", "CI"],
             ["1", "X", "Model A", "1000", ""], ["2", "X", "Model B", "900", ""]]
    bad = {"rows": {"Model A": "999", "Model B": "899"}, "charts": {}}
    r = reconcile_eval("aa-briefcase", "", [table], [], bad)
    assert r["checked"] == 2 and len(r["mismatches"]) == 2, f"ALL-WRONG fixture must yield mismatches: {r}"
    good = {"rows": {"Model A": "1000", "Model B": "900"}, "charts": {}}
    r2 = reconcile_eval("aa-briefcase", "", [table], [], good)
    assert r2["agreements"] == 2 and not r2["mismatches"], f"agreement fixture failed: {r2}"
    unrelated = {"rows": {}, "charts": {"Totally Unrelated Section": {"Model A": "1"}}}
    r3 = reconcile_eval("aa-briefcase", "", [table], [], unrelated)
    assert "no second source" in r3["note"], f"identity gate failed: {r3}"
    bad_chart = {"rows": {}, "charts": {"AA-Briefcase Elo": {"Model A": "1", "Model B": "2"}}}
    r4 = reconcile_eval("aa-briefcase", "", [table], [], bad_chart)
    assert len(r4["mismatches"]) == 2, f"all-wrong chart source must yield mismatches: {r4}"
    # two-model comparison table: blank label header cell + 'Add model' control cell.
    # Both models must ingest — a regression once dropped the first model column.
    two_model = [
        ["", "Model X (Max)", "Model Y (Max)", "Add model from specific provider"],
        ["Intelligence Index", "50", "40", ""],
        ["AA-Briefcase v1.1", "1500", "1400", ""],
    ]
    res, fail = table_columns(two_model)
    assert fail is None, f"two-model fixture failed: {fail}"
    names, cols = res
    assert names == ["Model X (Max)", "Model Y (Max)"], f"first-model-drop regression: {names}"
    assert cols[0]["Intelligence Index"] == "50" and cols[1]["AA-Briefcase v1.1"] == "1400", cols
    # numeric first rows can never be headers: '0%' is not a model name
    numeric = [["", "0%", "50%"], ["Intelligence Index", "50", "40"]]
    res3, fail3 = table_columns(numeric)
    assert res3 is None and fail3, "numeric-row header must be rejected"
    # structural thead wins over body rows
    with_head = {"head": [["", "Model X (Max)", "Model Y (Max)"]], "rows": [["", "Model X (Max)", "Model Y (Max)"], ["", "0%", "50%"], ["AA-Briefcase v1.1", "1500", "1400"]]}
    res4, fail4 = table_columns(with_head)
    assert fail4 is None and res4[0] == ["Model X (Max)", "Model Y (Max)"], f"structural header failed: {fail4} {res4}"
    assert all("0%" not in c for c in res4[1]) and res4[1][0] == {"AA-Briefcase v1.1": "1500"}, "value rows must never become models"
    # coverage: alias and zero-count semantics
    alias_only = {"comparisons": {"M": {"AA-Omniscience": "43"}}, "evals": {}}
    ca, ma = compute_coverage(alias_only, ["omniscience"])
    assert "omniscience-index" not in ma, f"alias: 'AA-Omniscience' row IS the index: {ma}"
    zero_count = {"comparisons": {}, "evals": {"aa-briefcase": {"leaderboard": {}}}}
    cz, mz = compute_coverage(zero_count, ["aa-briefcase"])
    assert "aa-briefcase-elo" in mz, "zero-count key must read as MISSING"
    mixed = {"comparisons": {"M": {"AA-Briefcase v1.1": "1"}}, "evals": {"aa-briefcase": {"leaderboard": {}}, "omniscience": {"leaderboard": {"X": {"value": 1}}}}}
    cm, mm = compute_coverage(mixed, ["aa-briefcase", "omniscience"])
    assert "aa-briefcase-elo" not in mm and "omniscience-index" not in mm, f"alias merge failed: {mm}"
    # a model counts once per series even when two sources carry it; chart-window-only is partial
    twice = {"comparisons": {"m1": {"Intelligence Index": "58"}}, "embedded": {"m1": {"intelligence-index": 57.6}, "m2": {"intelligence-index": 40.1}},
             "windows": {"m1": {"math500": 0.99}}, "evals": {}}
    ct, mt = compute_coverage(twice, ["math-500"])
    assert ct["intelligence-index"]["models"] == 2 and not ct["intelligence-index"]["partial"], ct
    assert ct["math500"]["models"] == 1 and ct["math500"]["partial"] and "math500" not in mt, "window-only series is partial, not missing"
    for cell, want in (("37k", (37000.0, "count")), ("1.6T", (1.6e12, "count")), ("260M", (2.6e8, "count")), ("3.6B", (3.6e9, "count")),
                       ("128k tokens ~192 A4 pages of size 12 Arial font", (128000.0, "tokens")),
                       ("95 tokens/s", (95.0, "tokens/s")), ("10.19s", (10.19, "s")), ("250ms", (0.25, "s")),
                       ("$8,708", (8708.0, "usd")), ("$5.98", (5.98, "usd")), ("85.7%", (0.857, "fraction")),
                       ("514", (514.0, None)), ("58*", (58.0, None))):
        assert parse_cell(cell) == want, f"{cell!r}: {parse_cell(cell)} != {want}"
    for text in ("Yes", "Supports: text and image", "September 2026", "Apache 2.0", "128k tokens/s", "5min"):
        assert parse_cell(text) == (None, None), f"{text!r} holds no number the rules know"
    cols = [["", "Creator", "Model", "Openness Index", "Intelligence Index"], ["1", "Acme", "M-A", "88.89", "11.50"], ["2", "Acme", "M-B", "70.00", "9.00"]]
    assert all(r["ci"] is None for r in parse_leaderboard(cols).values()), "a fifth column that is another metric is not an interval"
    harvey = [["", "Creator", "Name", "Hallucination-Gated All-Pass Rate", "Criterion Pass Rate"], ["1", "Acme", "M-A", "13.1%", "95.5%"]]
    assert parse_leaderboard(harvey)["M-A"]["ci"] is None and parse_leaderboard(harvey)["M-A"]["value"] == 0.131, "a pass rate is not an interval"
    briefcase = [["", "Creator", "Name", "Elo", "CI", "Release Date"], ["1", "Acme", "M-A", "1817", "-11 / +13", "Sep 2026"]]
    assert parse_leaderboard(briefcase)["M-A"]["ci"] == "-11 / +13", "a CI column keeps its interval"
    range_table = [["", "Range", "Model", "Elo"], ["1", "1-3", "M-A", "1197 \u00b133 95% interval 1163 to 1230"]]
    assert parse_leaderboard(range_table)["M-A"]["value"] == 1197.0 and "95% interval" in parse_leaderboard(range_table)["M-A"]["ci"], "trailing text of the value cell stays the interval"
    print("selftest: ok — all-wrong sources yield mismatches; two-model ingest complete; numeric-row headers rejected; thead structural; identity fails closed; coverage is count-based with aliases; unit cells parse")


def run_fetch_selftest():
    """The fetch layer against a scripted opener: no network, no real sleeping."""
    import email.message
    import tempfile

    saved = (HERE, RAW, NEG_FILE, _sleep, _urlopen)
    sleeps, calls, script = [], [], []
    ok = lambda n: f"{n} Artificial Analysis Intelligence Index"
    down = "<html>Down for maintenance</html>"

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

    def opener(req, timeout=None):
        calls.append(req.full_url)
        step = script.pop(0)
        if isinstance(step, tuple):
            hdrs = email.message.Message()
            if step[1]:
                hdrs["Retry-After"] = str(step[1])
            raise urllib.error.HTTPError(req.full_url, step[0], "x", hdrs, None)
        if isinstance(step, http.client.BadStatusLine):
            raise step
        return Resp(step)

    g = globals()
    try:
        with tempfile.TemporaryDirectory() as tmp:
            configure(tmp)
            g["_sleep"], g["_urlopen"] = sleeps.append, opener
            short = cache_file("/models/comparisons/a-vs-b")
            assert short.name == "models_comparisons_a-vs-b.html", short.name
            slug = "x" * 60
            slugs_a = [slug + str(i) for i in range(3)] + ["alpha"]
            long_a = "/models/comparisons/" + "-vs-".join(slugs_a)
            long_b = "/models/comparisons/" + "-vs-".join(slugs_a[:3] + ["bravo"])
            assert len(_legacy_stem(long_a)) > 180
            assert _legacy_stem(long_a)[:180] == _legacy_stem(long_b)[:180]
            assert cache_file(long_a) != cache_file(long_b), "long names must not collide"
            assert len(cache_file(long_a).name) <= 150 + 11 + 5
            RAW.mkdir(parents=True, exist_ok=True)
            want_a = set(slugs_a)
            legacy_body = _fake_page([_fake_obj(x) for x in slugs_a])
            (RAW / (_legacy_stem(long_a)[:180] + ".html")).write_text(legacy_body, encoding="utf-8")
            hit = fetch_page(long_a, "compare", want_a, network=False)
            assert hit.cached and hit.text == legacy_body and hit.ts == "unknown", "legacy name stays readable"
            body = _fake_page([_fake_obj(x, intelligenceIndex=1.0) for x in slugs_a])
            script[:] = [down]
            try:
                fetch_page(long_a, "compare", want_a, skip_legacy=True, refresh=True)
                raise AssertionError("a page that does not parse must be rejected")
            except Rejected as e:
                assert e.why == "no table" and "page rejected: no table" in str(e)
            assert not cache_file(long_a).exists(), "a rejected body never enters the cache"
            script[:] = [body]
            fresh = fetch_page(long_a, "compare", want_a, skip_legacy=True, refresh=True)
            assert fresh.text == body and not fresh.cached and cache_file(long_a).exists()
            assert Path(str(cache_file(long_a)) + ".ts").read_text(encoding="utf-8") == fresh.ts
            again = fetch_page(long_a, "compare", want_a, skip_legacy=True)
            assert again.cached and again.ts == fresh.ts, "a cache hit keeps the real fetch time"
            try:
                page_problem("compare", long_a, body, fresh.ts, None)
                raise AssertionError("a compare page cannot be judged without its requested slugs")
            except TypeError:
                pass
            samples = {
                "compare": ("/models/comparisons/m-p-vs-m-q", {"m-p", "m-q"}, _fake_page([_fake_obj("m-p"), _fake_obj("m-q")]),
                            _fake_page([_fake_obj("m-x"), _fake_obj("m-y")])),
                "evaluation": ("/evaluations/sample", None, "<table><tr><td>1</td><td>Acme</td><td>M</td><td>5</td></tr></table>", None),
                "sitemap": ("/sitemap.xml", None, "<urlset><loc>https://artificialanalysis.ai/models/m-p</loc></urlset>", None),
                "catalog": ("/models/comparisons", None, '{"slug":"m-p","name":"M-P","deprecated":false,"releaseDate":"2026-01-01"}', None),
                "cohort": ("/models/sample", None, ok(58), None),
            }
            for kind, (path, want, good, wrong) in samples.items():
                script[:] = [good]
                assert fetch_page(path, kind, want, refresh=True).text == good, f"{kind}: a matching body is accepted"
                sidecar = Path(str(cache_file(path)) + ".ts")
                sidecar.write_text("2020-01-01T00:00:00Z", encoding="utf-8")
                for bad in [down] + ([wrong] if wrong else []):
                    script[:] = [bad]
                    try:
                        fetch_page(path, kind, want, refresh=True)
                        raise AssertionError(f"{kind}: a 200 body that does not match must be rejected")
                    except Rejected:
                        pass
                    assert cache_file(path).read_text(encoding="utf-8") == good, f"{kind}: a rejected body keeps the last good copy"
                    assert sidecar.read_text(encoding="utf-8") == "2020-01-01T00:00:00Z", f"{kind}: and its fetch time"
                cache_file(path).write_text(down, encoding="utf-8")
                try:
                    fetch_page(path, kind, want)
                    raise AssertionError(f"{kind}: a cached copy that no longer parses must be rejected on read")
                except Rejected:
                    pass
            sleeps.clear(), calls.clear()
            script[:] = [(404, None)]
            try:
                fetch_page("/models/gone", "cohort", None)
                raise AssertionError("404 must raise")
            except FetchError as e:
                assert e.status == 404
            assert sleeps == [DELAY], f"spacing follows a 404: {sleeps}"
            try:
                fetch_page("/models/gone", "cohort", None)
                raise AssertionError("remembered 404 must raise")
            except FetchError as e:
                assert e.status == 404
            assert len(calls) == 1, f"a remembered 404 makes no network call: {calls}"
            assert load_404s()["/models/gone"]["status"] == 404
            remember_404("/models/gone", "2026-10-16T00:00:00Z")
            remember_404("/models/gone", "2026-10-17T00:00:00Z")
            lines = NEG_FILE.read_text(encoding="utf-8").splitlines()
            assert sum(1 for x in lines if '"/models/gone"' in x) == 1 and json.loads(next(x for x in lines if '"/models/gone"' in x))["at"] == "2026-10-17T00:00:00Z", "a repeated 404 replaces its line"
            kept = load_404s()
            NEG_FILE.write_text("", encoding="utf-8")
            assert load_404s() == kept, "NEG_FILE is read once per process, not on every fetch"
            remember_404("/models/gone", "2026-10-17T00:00:00Z")
            sleeps.clear(), calls.clear()
            script[:] = [(500, None), (429, 7), ok(59)]
            assert fetch_page("/models/flaky", "cohort", None).text == ok(59)
            assert sleeps == [DELAY, 2, DELAY, 7, DELAY], f"backoff and Retry-After: {sleeps}"
            sleeps.clear(), calls.clear()
            script[:] = [(503, None)] * 3
            try:
                fetch_page("/models/down", "cohort", None)
                raise AssertionError("exhausted retries must raise")
            except FetchError as e:
                assert e.status == 503 and len(calls) == 3
            assert sleeps == [DELAY, 2, DELAY, 4, DELAY], sleeps
            sleeps.clear(), calls.clear()
            script[:] = [http.client.BadStatusLine("garbage"), http.client.IncompleteRead(b"par"), ok(60)]
            assert fetch_page("/models/dropped", "cohort", None).text == ok(60), "a dropped connection is retried"
            assert sleeps == [DELAY, 2, DELAY, 4, DELAY], f"backoff follows a dropped connection: {sleeps}"
            calls.clear()
            script[:] = [http.client.IncompleteRead(b"par")] * 3
            try:
                fetch_page("/models/dropping", "cohort", None)
                raise AssertionError("exhausted retries must raise")
            except FetchError as e:
                assert e.status is None and len(calls) == 3, "a dropped connection ends as a FetchError, not a traceback"
            calls.clear()
            script[:] = [(403, None)]
            try:
                fetch_page("/models/denied", "cohort", None)
                raise AssertionError("403 must raise")
            except FetchError as e:
                assert e.status == 403 and len(calls) == 1, "other 4xx is not retried"
            RAW.mkdir(parents=True, exist_ok=True)
            remember_404("/models/old-404", "2020-01-01T00:00:00Z")
            calls.clear()
            script[:] = [ok(61)]
            g["NEG_MAX_AGE"] = 3600
            assert fetch_page("/models/old-404", "cohort", None).text == ok(61) and len(calls) == 1, "an old 404 memory is ignored"
            try:
                fetch_page("/models/never-fetched", "cohort", None, network=False)
                raise AssertionError("network off must raise on a miss")
            except FetchError as e:
                assert e.status is None and len(calls) == 1
    finally:
        g["NEG_MAX_AGE"] = None
        configure(saved[0])
        g["_sleep"], g["_urlopen"] = saved[3], saved[4]


def _fake_page(objs):
    """A compare page: a table whose header equals creator + name, and the escaped payload."""
    head = "".join(f"<th>{o['creator']['name']} {o['name']}</th>" for o in objs)
    cells = "".join(f"<td>{o.get('intelligenceIndex', 0):.0f}</td>" for o in objs)
    table = (f"<table><thead><tr><th></th>{head}<th>Add model</th></tr></thead>"
             f"<tbody><tr><td>Intelligence Index</td>{cells}</tr></tbody></table>")
    payload = json.dumps({"models": objs}, separators=(",", ":")).replace('"', '\\"')
    return "<html>" + table + "<script>" + payload + "</script></html>"


def _fake_obj(slug, **extra):
    return {"id": "id-" + slug, "slug": slug, "name": slug.upper(), "creator": {"name": "Acme", "slug": "acme"}, **extra}


def run_sweep_selftest():
    """Sweep against a scripted site: cache pass, split, anchor-paired retry, identity gate,
    banned route, unknown-age pages, exit contract. No network, no real sleeping."""
    import email.message
    import tempfile

    saved = (HERE, RAW, NEG_FILE, _sleep, _urlopen)
    sleeps, calls = [], []
    site = {}

    class Resp:
        def __init__(self, body):
            self.body = body

        def read(self):
            return self.body.encode("utf-8")

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def opener(req, timeout=None):
        path = req.full_url[len(BASE):]
        calls.append(path)
        body = site.get(path)
        if body is None:
            raise urllib.error.HTTPError(req.full_url, 404, "x", email.message.Message(), None)
        return Resp(body)

    def seed(path_stem, objs, ts="2026-10-15T20:00:00Z"):
        RAW.mkdir(parents=True, exist_ok=True)
        f = RAW / f"models_comparisons_{path_stem}.html"
        f.write_text(_fake_page(objs), encoding="utf-8")
        if ts:
            Path(str(f) + ".ts").write_text(ts, encoding="utf-8")

    g = globals()
    try:
        with tempfile.TemporaryDirectory() as tmp:
            configure(tmp)
            g["_sleep"], g["_urlopen"] = sleeps.append, opener
            a, b = _fake_obj("m-a", intelligenceIndex=50.4, gpqa=0.85), _fake_obj("m-b", intelligenceIndex=40.2)
            seed("m-a-vs-m-b", [a, b])
            seed("models=m-x", [_fake_obj("m-x")])
            seed("m-noage-vs-m-other", [_fake_obj("m-noage")], ts=None)
            seed("m-c-vs-m-d", [_fake_obj("m-c"), _fake_obj("m-zzz")])
            long_slugs = [("x" * 60) + str(i) for i in range(3)]
            slugs = ["acme", "m-a", "m-b", "m-c", "m-d", "m-e", "m-f", "m-gone", ANCHOR, "m-noage", *long_slugs]
            catalog = {s: {} for s in slugs if s != "acme"}

            def serve(*names):
                site["/models/comparisons/" + "-vs-".join(names)] = _fake_page([_fake_obj(s, intelligenceIndex=30.0) for s in names])

            # todo sorts to [anchor, m-c, m-d, m-e, m-f] and [m-gone, m-noage]; both 404 whole,
            # then split; the singletons 404 and are retried paired with an anchor
            long_path = "/models/comparisons/" + "-vs-".join(long_slugs)
            assert cache_file(long_path).name.count("-") and len(cache_file(long_path).name) > 150
            cache_file(long_path).write_text(_fake_page([_fake_obj(s, intelligenceIndex=20.0) for s in long_slugs]), encoding="utf-8")
            Path(str(cache_file(long_path)) + ".ts").write_text("2026-10-15T21:00:00Z", encoding="utf-8")
            serve("m-d", "m-e", "m-f")
            serve(ANCHOR, ALT_ANCHOR)
            serve("m-c", ANCHOR)
            serve("m-noage", ANCHOR)
            res = sweep_comparisons(slugs, catalog=catalog, creator_slugs={"acme"}, log=lambda *a, **k: None)
            st = res["status"]
            for s in ("m-a", "m-b", "m-c", "m-d", "m-e", "m-f", ANCHOR, "m-noage"):
                assert st[s]["status"] == "values", (s, st[s])
            assert all(s in res["rows"] for s in long_slugs), "a page with a cut and hashed file name still ingests by exact slug"
            assert "m-x" not in res["rows"] and any("models=" in s["file"] for s in res["skipped"]), "?models= is never read"
            assert any(s["reason"] == "age unknown" for s in res["skipped"]), "a page without a fetch time is not stamped now"
            assert res["rows"]["m-noage"][0]["observed_at"] != "unknown", "a re-fetched page gets its real fetch time"
            assert st["acme"] == {"status": "failure", "reason": "not a model (creator page)"}
            assert any(q["file"].endswith("m-c-vs-m-d.html") for q in res["quarantined"]), "payload slug set must equal the URL's"
            assert st["m-gone"]["status"] == "failure" and "paired with an anchor" in st["m-gone"]["reason"], st["m-gone"]
            assert ALT_ANCHOR not in res["rows"], "a partner model is never ingested"
            assert "/models/comparisons/" + "-vs-".join([ANCHOR, ALT_ANCHOR]) in calls, "the anchor is paired with the alternate"
            assert "/models/comparisons/" + "-vs-".join([ANCHOR, ANCHOR]) not in calls, "the anchor is never tested against itself"
            assert any(c.endswith("m-gone-vs-" + ANCHOR) for c in calls), "a singleton 404 is retried paired with the anchor"
            assert res["rows"]["m-a"][0]["observed_at"] == "2026-10-15T20:00:00Z", "real fetch time is kept"
            assert res["rows"]["m-a"][0]["series"]["gpqadiamond"] == 0.85 and res["rows"]["m-a"][0]["table"] == {"Intelligence Index": "50"}
            values, fails = exit_check(set(slugs), st)
            assert (values, fails) == (11, 2), (values, fails)
            assert len(sleeps) == len(calls), f"DELAY follows every attempt: {len(sleeps)} sleeps, {len(calls)} calls"
            assert not any("?models=" in c for c in calls), "banned route is never requested"
            try:
                exit_check(set(slugs) | {"m-unknown"}, st)
                raise AssertionError("a slug with neither values nor a reason must fail the exit check")
            except SystemExit as e:
                assert "m-unknown" in str(e)
            page = _fake_page([_fake_obj("m-a"), _fake_obj("m-b")])
            rows, why = ingest_compare_page(page, "2026-10-16T00:00:00Z", "p", {"m-a", "m-c"})
            assert rows is None and why["reason"] == "identity mismatch" and why["returned"] == ["m-a", "m-b"], "requested != returned fails closed"
            rows, why = ingest_compare_page(page.replace("Acme M-B", "Acme M-Q"), "t", "p")
            assert rows is None and why.startswith("quarantined"), "a header that differs from the payload quarantines the page"
            rows, why = ingest_compare_page("<table><thead><tr><th></th><th>A</th><th>B</th></tr></thead></table>", "t", "p")
            assert rows is None and "no embedded payload marker" in why, "no payload is a failure, never a fuzzy fallback"
            again = sweep_comparisons(["m-gone"], catalog={"m-gone": {}}, network=False, log=lambda *a, **k: None)
            assert "paired with an anchor" in again["status"]["m-gone"]["reason"], "remembered 404s prove an unsupported slug with no network"
            offline = sweep_comparisons(["m-q"], catalog={"m-q": {}}, network=False, log=lambda *a, **k: None)
            assert offline["status"]["m-q"]["reason"].startswith("not fetched"), "network off records a reason, not silence"
            assert offline["incomplete"] == [] and res["incomplete"] == [], "a 404 and a cache-only sweep are not incomplete"
    finally:
        configure(saved[0])
        g["_sleep"], g["_urlopen"] = saved[3], saved[4]


def _atomic_write(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def acquire_evals(snapshot, live, network):
    """Evaluation pages: leaderboard table, rendered second path, per-page reconciliation."""
    rendered_dir = RAW / "rendered"
    failed = []
    for slug in EVAL_SLUGS:
        try:
            page = fetch_page("/evaluations/" + slug, "evaluation", None, refresh=live, network=network).text
        except FetchError as e:
            snapshot["reconciliation"].append({"slug": slug, "note": f"fetch failed: {e}"})
            failed.append(str(e))
            continue
        tables = extract_tables(page)
        labels = extract_chart_labels(page)
        ld = extract_ldjson(page)
        rendered = {}
        rfile = rendered_dir / (slug + ".txt")
        if rfile.exists():
            rendered = parse_rendered_sections(rfile.read_text(encoding="utf-8", errors="replace"))
        snap = {
            "leaderboard": parse_leaderboard(tables[0]["rows"]) if tables else {},
            "rendered": rendered,
            "ldjson_names": [b.get("name") for b in ld if isinstance(b, dict)],
        }
        snapshot["evals"][slug] = snap
        snapshot["reconciliation"].append(reconcile_eval(slug, page, tables, labels, rendered))
        print(f"[eval] {slug}: table={len(snap['leaderboard'])} rendered_sections={len(rendered)}", flush=True)
    # Catalog-validated identities only: a model name counts if it appears in a
    # leaderboard dictionary (definitive source). Chart-parser keys that are not
    # in the catalog are quarantined as parser noise, never counted as models.
    catalog = set()
    for e in snapshot["evals"].values():
        catalog.update(e.get("leaderboard", {}).keys())
    catalog_norm = {norm_name(n) for n in catalog}
    quarantined = {}
    for slug, e in snapshot["evals"].items():
        r = e.get("rendered", {}) or {}
        for scope, pairs in [("rows", r.get("rows", {})), *[(f"chart:{s}", p) for s, p in (r.get("charts", {}) or {}).items()]]:
            if not isinstance(pairs, dict):
                continue
            for name in list(pairs.keys()):
                if norm_name(name) not in catalog_norm:
                    quarantined.setdefault(f"{slug}/{scope}", []).append(name)
                    # keep the raw capture on disk, but out of the model data
                    if scope == "rows":
                        r.get("rows", {}).pop(name, None)
                    else:
                        (r.get("charts", {}) or {}).get(scope.split("chart:", 1)[1], {}).pop(name, None)
    snapshot["quarantine"] = {k: v[:20] for k, v in quarantined.items()}
    snapshot["catalog_models"] = len(catalog)
    names_all = set(catalog)
    for e in snapshot["evals"].values():
        names_all.update((e.get("rendered", {}) or {}).get("rows", {}).keys())
    snapshot["validated_unique_models"] = len(names_all)
    return failed


def acquire_cohort(snapshot, slugs, network):
    """Model-page economics for the working cohort (cache-first). Returns the fetch failures. A page
    that does not parse is a failure that leaves the model's previous facts in place."""
    failed = []
    for slug in slugs:
        try:
            snapshot["models"][slug] = parse_model_page(fetch_page("/models/" + slug, "cohort", None, network=network).text)
            print(f"[model] {slug}: {snapshot['models'][slug]}", flush=True)
        except Rejected as e:
            failed.append(str(e))
        except FetchError as e:
            snapshot["models"][slug] = {"error": str(e)}
            failed.append(str(e))
    return failed


def run_sweep(snapshot, live, network, stale_after_hours):
    """Discover the universe, sweep it, and record the exit contract's evidence."""
    found = discover(refresh=live, network=network)
    print(f"[sweep] discovered {len(found['slugs'])} model slugs (sitemap + selector catalog; "
          f"{'live' if live else 'cache-first' if network else 'cache only'})", flush=True)
    result = sweep_comparisons(found["slugs"], found["catalog"], found["creators"], network=network,
                               stale_after_hours=stale_after_hours)
    result["incomplete"] = found["incomplete"] + result["incomplete"]
    values, fails = exit_check(set(found["slugs"]), result["status"])
    rows = result["rows"]
    snapshot.update({
        "universe": found["slugs"], "catalog": found["catalog"], "slug_status": result["status"],
        "comparisons": {s: lst[-1]["table"] for s, lst in sorted(rows.items())},
        "embedded": {s: lst[-1]["series"] for s, lst in sorted(rows.items())},
        "sweep_failures": [{"slug": s, "reason": v["reason"]} for s, v in sorted(result["status"].items()) if v["status"] == "failure"],
        "sweep": {"counts": result["counts"], "skipped_pages": result["skipped"],
                  "quarantined_pages": result["quarantined"], "stopped": result["stopped"]},
        "sweep_models": len(rows)})
    print(f"[sweep] exit check: {len(found['slugs'])} slugs = {values} with values + {fails} with a recorded reason "
          f"({result['counts']['non_models']} non-models); {result['counts']['requests']} network requests; "
          f"{len(result['quarantined'])} cached pages quarantined", flush=True)
    if result["stopped"]:
        print(f"[sweep] WARNING: {result['stopped']}", flush=True)
    return result


def report_coverage(view):
    """Recompute coverage from raw rows with compute_coverage() and write coverage.md."""
    cov, missing = compute_coverage(view, EVAL_SLUGS)
    write_coverage(cov, missing, HERE / "coverage.md")
    tracked = set(cov) | set(missing)
    observed = sum(1 for v in cov.values() if v["models"] > 0)
    partial = sorted(k for k, v in cov.items() if v["partial"])
    print(f"coverage (compute_coverage on raw rows): {len(tracked)} tracked series, {observed} with observations "
          f"({len(partial)} partial: chart window only), {len(missing)} not yet captured"
          + (f": {', '.join(missing)}" if missing else ""), flush=True)
    return cov, missing


def coverage_only():
    """coverage.md from the raw cache alone. No acquisition, and never from a stored database or snapshot."""
    models, obs = aadb.build_observations(aadb.load_raw())
    print(f"coverage input: raw cache ({len(obs)} observations)", flush=True)
    report_coverage(aadb.coverage_view(models, obs))


def write_verdict(ran_at, line, **fields):
    _atomic_write(HERE / "verdict.json", json.dumps(
        {"ran_at": ran_at, "verdict": line.split(" ", 1)[0], "line": line, **fields}, indent=1) + "\n")


def report_unread(raw, earlier, incomplete):
    """Name the cached pages the loaders dropped. A compare page whose fetch time stamped rows in
    the previous matrix (`earlier`) and no longer ingests drops its models from the new matrix, so it
    makes the run incomplete."""
    dropped = raw["quarantined"]
    why = lambda x: x["reason"] if isinstance(x["reason"], str) else x["reason"]["reason"]
    print(f"[db] cached compare pages quarantined: {len(dropped)}"
          + (": " + ", ".join(f"{x['file']} ({why(x)})" for x in dropped) if dropped else ""), flush=True)
    if raw["skipped_evals"]:
        print(f"[db] evaluation pages not read: {len(raw['skipped_evals'])}: "
              + ", ".join(f"{x['slug']} ({x['reason']})" for x in raw["skipped_evals"]), flush=True)
    for x in dropped:
        if x["fetched_at"] in earlier:
            incomplete.append(f"cached compare page {x['file']} stamped rows in the previous matrix and no longer ingests: {why(x)}")


def build_db(incomplete):
    """Rebuild aa.sqlite from raw evidence, recompute coverage, write the projections last.
    verdict.json goes UNTRUSTED first: only the chart-diff that follows a rebuild can restore it."""
    write_verdict(utc_now(), "UNTRUSTED (matrix rebuilt without chart-diff)", reason="matrix rebuilt without chart-diff")
    conn = aadb.open_db(HERE / "aa.sqlite")
    earlier = {r[0] for r in conn.execute("SELECT DISTINCT observed_at FROM observations WHERE source IN ('comparison-table', 'embedded')")}
    raw = aadb.load_raw()
    result = aadb.migrate(conn, raw=raw)
    print(f"[db] {HERE / 'aa.sqlite'}: {result['models']} models, {result['metrics']} metrics, "
          f"{sum(result['loaded'].values())} observations; row counts per source match the counts read", flush=True)
    report_unread(raw, earlier, incomplete)
    report_coverage(result["view"])
    return conn


def run_chart_diff(conn_factory, network):
    """Chart-diff, then the database, then the verdict files. Returns the process exit code."""
    results, raw, verdict_line, refetched = chartdiff.run_chartdiff(network=network)
    nc = chartdiff.not_compared(results, raw)
    conn = conn_factory()
    ran_at = utc_now()
    chartdiff.save_runs(conn, results, nc[0], ran_at)
    chartdiff.write_report(HERE / "reconcile.md", results, raw, verdict_line, nc, refetched, ran_at)
    checked = sum(r["checked"] for r in results.values())
    mism = sum(len(r["mismatches"]) for r in results.values())
    write_verdict(ran_at, verdict_line, checked=checked, mismatches=mism, not_compared=nc[0],
                  leaderboard_not_compared=chartdiff.leaderboard_not_compared(results), pages_refetched=len(refetched))
    print(f"chart-diff: {verdict_line}; {checked} values compared across {len(results)} metric/path pairings; "
          f"{len(refetched)} pages re-fetched once for mismatches", flush=True)
    print(f"reconcile.md and verdict.json written under {HERE}", flush=True)
    return 0 if verdict_line.startswith("TRUSTED") else 3


def parse_args(argv):
    import argparse

    ap = argparse.ArgumentParser(
        prog="fm-model-picker", description="Artificial Analysis benchmark collector for the model picker.",
        epilog="Data root: FM_MODEL_PICKER_DATA, else <FM_HOME>/data/model-picker.")
    flags = {
        "--selftest": "run the fixture suite (no network)",
        "--coverage-only": "rebuild coverage.md from the cache, no acquisition",
        "--evals-only": "acquire evaluation pages only (no model-page cohort, no sweep); revalidated unless --replay",
        "--sweep": "sweep the discovered model universe (network only for slugs without values)",
        "--replay": "cache-first everywhere: no revalidation; with --chartdiff, no live re-fetch of disagreeing pages",
        "--embedded-only": "sweep from the cache alone: no network at all",
        "--db": "rebuild aa.sqlite from raw evidence and write the per-candidate projections",
        "--chartdiff": "compare tables, payloads and rendered charts; re-fetch each disagreeing page once; "
                       "write reconcile.md and verdict.json; exit 3 when UNTRUSTED",
    }
    for name, text in flags.items():
        ap.add_argument(name, action="store_true", help=text)
    ap.add_argument("--models", default="", help="comma-separated model-page slugs (default: the working cohort)")
    ap.add_argument("--stale-after-hours", type=float, default=None,
                    help="re-fetch cached compare pages older than this many hours and ignore older remembered 404s")
    return ap.parse_args(argv)


COHORT = ["claude-opus-5-5", "claude-sonnet-5-5", "gpt-6-1-sol", "gemini-4-argon", "kimi-k3", "deepseek-v4-1-flash"]


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    global NEG_MAX_AGE
    NEG_MAX_AGE = args.stale_after_hours * 3600 if args.stale_after_hours else None
    if args.selftest:
        run_selftest()
        run_fetch_selftest()
        run_sweep_selftest()
        aadb.calibration_selftest()
        embedded.selftest()
        chartdiff.selftest()
        aadb.matrix_selftest()
        print("selftest: ok - calibration tables, embedded parser, fetch layer, sweep, matrix load, chart-diff")
        return 0
    if args.coverage_only:
        coverage_only()
        return 0
    sweeping = args.sweep or args.embedded_only
    acquire = sweeping or args.evals_only or not (args.db or args.chartdiff)
    network = not args.embedded_only
    live = not args.replay and not args.embedded_only
    snap_file = HERE / "snapshot.json"
    prev = {}
    if snap_file.exists():
        try:
            prev = json.loads(snap_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            prev = {}
    incomplete = []
    if acquire:
        snapshot = {"collected_at": utc_now(), "source": BASE, "evals": {}, "models": prev.get("models", {}),
                    "reconciliation": [], "quarantine": {},
                    "run_mode": "cache-only" if not network else "live-revalidated" if live else "cache-replay"}
        incomplete += acquire_evals(snapshot, live, network)
        if not args.evals_only:
            incomplete += acquire_cohort(snapshot, [s for s in args.models.split(",") if s] or COHORT, network)
        if sweeping:
            swept = run_sweep(snapshot, live, network, args.stale_after_hours)
            incomplete += swept["incomplete"]
            if swept["stopped"]:
                incomplete.append(swept["stopped"])
        else:
            for key in ("universe", "catalog", "slug_status", "comparisons", "embedded", "sweep_failures", "sweep", "sweep_models"):
                if key in prev:
                    snapshot[key] = prev[key]
        snapshot["sources_fetched_at"] = dict(FETCH_TS)
        _atomic_write(snap_file, json.dumps(snapshot, indent=1))
        print(f"snapshot.json written ({snapshot['run_mode']}); coverage and reconcile are recomputed from raw rows, not stored here", flush=True)
    code = 0
    conn = None
    if args.chartdiff:
        def factory():
            nonlocal conn
            conn = build_db(incomplete)
            return conn

        code = run_chart_diff(factory, network and not args.replay)
    elif args.db:
        conn = build_db(incomplete)
        print("verdict.json is UNTRUSTED: matrix rebuilt without chart-diff; run --chartdiff to judge it", flush=True)
    if conn is not None:
        n = aadb.write_projections(conn, HERE / "projection")
        print(f"[db] {n} per-candidate JSON projections written under {HERE / 'projection'}", flush=True)
        conn.close()
    elif acquire:
        coverage_only()
    if incomplete:
        print(f"INCOMPLETE: outputs were written, but {len(incomplete)} acquisition problems left them not fully fresh:", file=sys.stderr)
        for why in incomplete:
            print(f"  {why}", file=sys.stderr)
        return code or 4
    return code


def cli():
    try:
        return main()
    except FetchError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(cli())
