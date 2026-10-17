"""
Embedded-payload parser for Artificial Analysis pages.

Compare pages embed the selected models as a JSON array starting at '"models":[{"id":"';
evaluation pages embed the charted models under '"initialModels":[{"id":"'. Each object has
an exact slug, a name, a creator and full-precision values, so identity is exact: no fuzzy
matching. Everything here fails closed: no marker means no payload, an object without
slug/name/creator.name is rejected with a reason, and a table header that does not equal
the payload's names quarantines the page.

SERIES_MAP is the single list of embedded fields that become metric series. A null field
writes no row: a missing value is never a zero.
"""
import json

COMPARE_MARKER = '"models":[{"id":"'
EVAL_MARKER = '"initialModels":[{"id":"'

# canonical id, embedded field path, label, unit, scale, derived, comparison-table row label,
# evaluation page slug. scale "fraction" means the payload stores 0..1 and charts show percent;
# the raw value is stored and the scale is recorded in metrics. cid values must equal
# collect.canon_metric_id(label) so the three paths land on one series
# (collect.run_selftest asserts it).
_S = [
    ("omniscience-accuracy", "omniscienceAccuracy", "AA-Omniscience Accuracy", "fraction", "fraction", False, None, None),
    ("omniscience-non-hallucination-rate", "omniscienceHallucinationRate", "AA-Omniscience Non-Hallucination Rate", "fraction", "fraction", True, None, None),
    ("aa-briefcase-rubric", "briefcaseBreakdown.rubricPassRate", "AA-Briefcase Rubric Score (%)", "fraction", "fraction", False, None, None),
    ("aa-briefcase-analytical-elo", "briefcaseBreakdown.analyticalQuality.elo", "Analytical Quality & Presentation Elo", "elo", "raw", False, None, None),
    ("ifbench", "ifbench", "IFBench", "fraction", "fraction", False, None, "ifbench"),
    ("aime2025", "aime25", "AIME 2025", "fraction", "fraction", False, None, "aime-2025"),
    ("livecodebench", "livecodebench", "LiveCodeBench", "fraction", "fraction", False, None, "livecodebench"),
    ("mmmupro", "mmmuPro", "MMMU-Pro", "fraction", "fraction", False, None, "mmmu-pro"),
    ("gpqadiamond", "gpqa", "GPQA Diamond", "fraction", "fraction", False, None, "gpqa-diamond"),
    ("tau2bench", "tau2", "Tau2-Bench", "fraction", "fraction", False, None, "tau2-bench"),
    ("tau3banking", "tauBanking", "Tau3-Banking", "fraction", "fraction", False, None, "tau3-banking"),
    ("terminalbench21", "terminalBench21", "Terminal-Bench 2.1", "fraction", "fraction", False, None, "terminalbench-2-1"),
    ("terminalbenchhard", "terminalbenchHard", "Terminal-Bench Hard", "fraction", "fraction", False, None, "terminalbench-hard"),
    ("terminalbenchscience", "terminalBenchScience", "Terminal-Bench-Science", "fraction", "fraction", False, None, "terminal-bench-science"),
    ("mlcraa", "mlcrOverall", "MLCR-AA", "fraction", "fraction", False, None, "mlcr-aa"),
    ("itbenchaa", "itBenchSre|itbenchSre", "ITBench-AA", "fraction", "fraction", False, None, "itbench-aa"),
    ("frontiercode", "frontierCode", "FrontierCode", "fraction", "fraction", False, None, "frontiercode"),
    ("enterpriseopsgymaa", "enterpriseOpsGym", "EnterpriseOps-Gym-AA", "fraction", "fraction", False, None, "enterprise-ops-gym-aa"),
    ("apexagentsaa", "apexAgents", "APEX-Agents-AA", "fraction", "fraction", False, None, "apex-agents-aa"),
    ("aaanalystagent", "analystAgent", "AA-AnalystAgent", "fraction", "fraction", False, None, "aa-analyst-agent"),
    # second path for series already captured through tables
    ("intelligence-index", "intelligenceIndex", "Intelligence Index", "points", "raw", False, "Intelligence Index", "artificial-analysis-intelligence-index"),
    ("omniscience-index", "omniscience", "AA-Omniscience", "points", "raw", False, "AA-Omniscience", "omniscience"),
    ("aa-briefcase-elo", "briefcaseBreakdown.overall.elo|briefcaseBreakdown.elo", "AA-Briefcase v1.1", "elo", "raw", False, "AA-Briefcase v1.1", "aa-briefcase"),
    ("gdpval-aa-elo", "gdpval", "GDPval-AA v2.1", "elo", "raw", False, "GDPval-AA v2.1", "gdpval-aa"),
    ("gdppdf", "gdpPdfAllPass", "GDP.pdf", "fraction", "fraction", False, "GDP.pdf", "gdp-pdf"),
    ("scicode", "scicode", "SciCode", "fraction", "fraction", False, "SciCode", "scicode"),
    ("aa-lcr", "lcr", "AA-LCR v1.1", "fraction", "fraction", False, "AA-LCR v1.1", "artificial-analysis-long-context-reasoning"),
    ("humanityslastexam", "hle", "Humanity's Last Exam", "fraction", "fraction", False, "Humanity's Last Exam", "humanitys-last-exam"),
    ("critpt", "critpt", "CritPt", "fraction", "fraction", False, "CritPt", "critpt"),
    ("automationbench-aa", "automationBenchPartialScore", "AutomationBench-AA", "fraction", "fraction", False, "AutomationBench-AA", "automationbench-aa"),
    ("terminal-bench-4-0", "terminalBench40", "Terminal-Bench 4.0", "fraction", "fraction", False, "Terminal-Bench 4.0", "terminalbench-4-0"),
    ("harveylabaa", "harveyLab", "Harvey-LAB-AA", "fraction", "fraction", False, None, "harvey-lab-aa"),
    ("math500", "math500", "MATH-500", "fraction", "fraction", False, None, "math-500"),
    ("mmlupro", "mmluPro", "MMLU-Pro", "fraction", "fraction", False, None, "mmlu-pro"),
    ("globalmmlulite", "globalMmluLiteScore", "Global-MMLU-Lite", "fraction", "fraction", False, None, "global-mmlu-lite"),
    ("openness-index", "opennessIndex", "Artificial Analysis Openness Index", "points", "raw", False, None, "artificial-analysis-openness-index"),
    ("aa3d", "aa3dElo", "AA-3D", "elo", "raw", False, None, "aa-3d"),
    # economics (comparison-table rows)
    ("priceper1mtokens", "price1mBlended7To2To1", "Price per 1M Tokens", "usd", "raw", False, "Price per 1M Tokens", None),
    ("inputpriceper1mtokens", "price1mInputTokens", "Input Price per 1M Tokens", "usd", "raw", False, "Input Price per 1M Tokens", None),
    ("outputpriceper1mtokens", "price1mOutputTokens", "Output Price per 1M Tokens", "usd", "raw", False, "Output Price per 1M Tokens", None),
    ("cachehitpriceper1mtokens", "cacheHitPrice", "Cache Hit Price per 1M Tokens", "usd", "raw", False, "Cache Hit Price per 1M Tokens", None),
]
SERIES_MAP = {
    s[0]: {"cid": s[0], "field": s[1], "label": s[2], "unit": s[3], "scale": s[4], "derived": s[5],
           "compare_label": s[6], "eval_slug": s[7]}
    for s in _S}

# The 23 series the prototype could not capture, in the handoff's order. Series 21-23 have no
# field in any payload: they exist only in the eval page chart window.
MISSING_23 = [
    "omniscience-accuracy", "omniscience-non-hallucination-rate", "aa-briefcase-rubric",
    "aa-briefcase-analytical-elo", "ifbench", "aime2025", "livecodebench", "mmmupro",
    "gpqadiamond", "tau2bench", "tau3banking", "terminalbench21", "terminalbenchhard",
    "terminalbenchscience", "mlcraa", "itbenchaa", "frontiercode", "enterpriseopsgymaa",
    "apexagentsaa", "aaanalystagent", "math500", "mmlupro", "globalmmlulite"]


def extract_array(page, marker):
    """The embedded model array after `marker`, or (None, reason). Fails closed."""
    un = page.replace('\\"', '"')
    i = un.find(marker)
    if i < 0:
        return None, "no embedded payload marker"
    try:
        arr, _ = json.JSONDecoder().raw_decode(un[un.index("[", i):])
    except (ValueError, json.JSONDecodeError) as e:
        return None, f"embedded payload is not valid JSON: {e}"
    if not isinstance(arr, list) or not arr:
        return None, "embedded payload is empty"
    return arr, None


def check_objects(arr):
    """Split into (accepted objects, rejects). Each accepted object has a string slug, a
    string name and a creator.name; anything else is rejected with its reason."""
    ok, rejects, seen = [], [], set()
    for i, o in enumerate(arr):
        slug = o.get("slug") if isinstance(o, dict) else None
        if not isinstance(o, dict):
            rejects.append({"index": i, "reason": "payload entry is not an object"})
        elif not isinstance(slug, str) or not slug:
            rejects.append({"index": i, "reason": "missing slug"})
        elif not isinstance(o.get("name"), str) or not o["name"]:
            rejects.append({"index": i, "slug": slug, "reason": "missing name"})
        elif not isinstance(o.get("creator"), dict) or not isinstance(o["creator"].get("name"), str) or not o["creator"]["name"]:
            rejects.append({"index": i, "slug": slug, "reason": "missing creator.name"})
        elif slug in seen:
            rejects.append({"index": i, "slug": slug, "reason": "duplicate slug in payload"})
        else:
            seen.add(slug)
            ok.append(o)
    return ok, rejects


def display_name(obj):
    return f'{obj["creator"]["name"]} {obj["name"]}'


def check_header(objs, header_cells):
    """Each table header cell must equal creator.name + ' ' + name of the matching object, in
    order. Returns None when it holds, else a reason. The payload may list more models than
    the table shows, never fewer."""
    names = [display_name(o) for o in objs]
    cells = [c for c in header_cells if c]
    if not cells:
        return "no table header to cross-check"
    if len(cells) > len(names):
        return f"table shows {len(cells)} models, payload holds {len(names)}"
    for i, (cell, name) in enumerate(zip(cells, names)):
        if cell != name:
            return f"header {i} {cell!r} != payload {name!r}"
    return None


# series whose table cell carries an asterisk when the payload flags the value as estimated
ESTIMATED_FLAGS = {"intelligence-index": "intelligenceIndexIsEstimated"}


def get_path(obj, path):
    cur = obj
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def series_value(obj, spec):
    """The stored (raw) value for one series, or None. null, missing and non-numeric fields
    write no row. A derived series is 1 minus its field and is labelled derived."""
    v = None
    for field in spec["field"].split("|"):
        v = get_path(obj, field)
        if v is not None:
            break
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return 1 - v if spec["derived"] else v


def model_series(obj):
    """{canonical id: value} for every series the object holds."""
    out = {}
    for cid, spec in SERIES_MAP.items():
        v = series_value(obj, spec)
        if v is not None:
            out[cid] = v
    return out


def model_attrs(obj):
    """The catalog fields stored on the models table."""
    return {"slug": obj["slug"], "name": obj["name"], "creator": obj["creator"]["name"],
            "creator_slug": obj["creator"].get("slug") or "",
            "deprecated": bool(obj.get("deprecated")), "release_date": obj.get("releaseDate") or "",
            "short_name": obj.get("shortName") or "",
            "estimated": [cid for cid, flag in ESTIMATED_FLAGS.items() if obj.get(flag) is True]}


def parse_compare_page(page, header_cells):
    """Parse one compare page: returns {'objects', 'rejects', 'quarantine'}; quarantine is the
    reason string when the page cannot be trusted (no payload or header mismatch)."""
    arr, why = extract_array(page, COMPARE_MARKER)
    if arr is None:
        return {"objects": [], "rejects": [], "quarantine": why}
    objs, rejects = check_objects(arr)
    why = check_header(objs, header_cells) if not rejects else f"{len(rejects)} rejected payload objects"
    return {"objects": [] if why else objs, "rejects": rejects, "quarantine": why}


def selftest():
    """Fixtures for the parser: identity, fail-closed rules, nulls, scale, derived series."""
    from . import collect

    for cid, spec in SERIES_MAP.items():
        assert collect.canon_metric_id(spec["label"]) == cid, f"{cid}: label does not canonicalize to the series id"
        if spec["eval_slug"]:
            assert collect.canon_metric_id("eval-leaderboard:" + spec["eval_slug"]) == cid, f"{cid}: eval slug alias"
    for cid in MISSING_23:
        assert cid in SERIES_MAP, f"{cid} has no embedded or chart mapping"

    def obj(slug, name, creator="Acme", **extra):
        return {"id": "i-" + slug, "slug": slug, "name": name, "creator": {"name": creator, "slug": creator.lower()}, **extra}

    models = [obj("m-a", "Model A (Max)", gpqa=0.8566, omniscienceHallucinationRate=0.25, ifbench=None,
                  briefcaseBreakdown={"rubricPassRate": 0.5, "analyticalQuality": {"elo": 1500.5}}, deprecated=False),
              obj("m-b", "Model B", gpqa=None, itbenchSre=0.4)]
    dump = lambda v: json.dumps(v, separators=(",", ":"))
    arr, why = extract_array('junk"models":' + dump(models) + "tail", COMPARE_MARKER)
    assert why is None and [o["slug"] for o in arr] == ["m-a", "m-b"]
    escaped = ('junk\\"models\\":' + dump(models).replace('"', '\\"') + "tail")
    arr2, why2 = extract_array(escaped, COMPARE_MARKER)
    assert why2 is None and len(arr2) == 2, f"escaped payload form: {why2}"
    assert extract_array("no marker here", COMPARE_MARKER)[0] is None, "no marker means no payload"
    assert extract_array('"models":[{"id":"broken', COMPARE_MARKER)[0] is None, "invalid JSON fails closed"
    good, rejects = check_objects(models + [{"slug": "x"}, obj("", "n"), obj("dup", "D"), obj("dup", "D2"),
                                              {"slug": "nc", "name": "N", "creator": {}}, "str"])
    assert [o["slug"] for o in good] == ["m-a", "m-b", "dup"] and len(rejects) == 5, rejects
    assert check_header(good, ["Acme Model A (Max)", "Acme Model B"]) is None
    assert check_header(good, ["Acme Model A (Max)"]) is None, "payload may list more models than the table"
    assert "!=" in check_header(good, ["Acme Model B", "Acme Model A (Max)"]), "order is part of identity"
    assert check_header(good, ["Acme Model A", "Acme Model B"]) is not None, "a name that differs quarantines"
    assert check_header(good, []) is not None
    assert check_header(good, ["a", "b", "c", "d"]) is not None
    s = model_series(models[0])
    assert s["gpqadiamond"] == 0.8566 and "ifbench" not in s, "null writes no row"
    assert abs(s["omniscience-non-hallucination-rate"] - 0.75) < 1e-12, "derived series is 1 minus the field"
    assert s["aa-briefcase-rubric"] == 0.5 and s["aa-briefcase-analytical-elo"] == 1500.5
    assert model_series(models[1]) == {"itbenchaa": 0.4}, "alternate field spelling is read"
    assert model_series(obj("z", "Z", gpqa=0)) == {"gpqadiamond": 0}, "a real zero is a value"
    assert model_series(obj("z", "Z", gpqa=True)) == {}, "booleans are not values"
    ok = parse_compare_page('"models":' + dump(models), ["Acme Model A (Max)", "Acme Model B"])
    assert ok["quarantine"] is None and len(ok["objects"]) == 2
    bad = parse_compare_page('"models":' + dump(models), ["Acme Model A (Max)", "Acme Model Q"])
    assert bad["quarantine"] and bad["objects"] == [], "a header mismatch quarantines the page"
    assert parse_compare_page("nothing", ["x"])["quarantine"] == "no embedded payload marker"
    assert model_attrs(models[0])["creator"] == "Acme"
