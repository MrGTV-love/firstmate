"""
Shadow benchmark-informed model picker.

Observes one dispatch, decides what it WOULD have chosen from measured Artificial Analysis
data plus bounded Jev judgments, and records that beside the dispatch's route: the route that
actually launched, or the route config/crew-dispatch.json chose when no launch was attached.
It never returns, prints or writes a dispatch route: the resolver and the spawn hook ignore
every value this module computes.

Contract: docs/configuration.md "Shadow model picker (FM_MODEL_PICKER_SHADOW)".
Policy constants here are the "uncalibrated seed policy" named in the docs; POLICY_VERSION
changes when a seed mix, floor or veto changes.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from . import aadb

POLICY_VERSION = "2026-10-19.1"
SEED_LABEL = "uncalibrated seed policy"
# measured: value=1209600 date=2026-10-19 host=board margin=1.0 (the design card's fourteen-day freshness limit; stale is disclosed uncertainty, never a drop)
STALE_AFTER_SECONDS = 1209600
PROMPT_TASK_LIMIT = 16000
# measured: value=3600 date=2026-10-23 host=Mac-Studio margin=1.0 (the user-set one-hour bound: a resolve and its launch run back to back in one firstmate turn; an older marker belongs to a dispatch that never launched)
RESOLVER_MARK_FRESH_SECONDS = 3600

EFFORT_LEVELS = ["low", "medium", "high", "xhigh", "max"]
HARNESS_EFFORTS = {
    "claude": ["low", "medium", "high", "xhigh", "max"],
    "omp": ["low", "medium", "high", "xhigh", "max"],
    "pi": ["low", "medium", "high", "xhigh", "max"],
    "pi-signed": ["low", "medium", "high", "xhigh", "max"],
    "muse": ["low", "medium", "high", "xhigh", "max"],
    "codex": ["low", "medium", "high", "xhigh"],
    "grok": ["low", "medium", "high"],
    "agy": ["low", "medium", "high"],
    "rovo": ["low", "medium", "high", "max"],
    "opencode": [],
    "kimi": [],
    "cursor": [],
}

# Metric discipline: every metric keeps its own eval id, raw unit/scale, direction and
# version. Elo is normalized with the published (Elo - 500) / 2000 scale; a fraction is
# normalized as percent.
METRICS = {
    "scicode": {"eval": "SciCode", "kind": "fraction", "direction": "higher"},
    "terminal-bench-4-0": {"eval": "Terminal-Bench 4.0", "kind": "fraction", "direction": "higher"},
    "ifbench": {"eval": "Instruction Following (IFBench)", "kind": "fraction", "direction": "higher"},
    "aa-lcr": {"eval": "AA-LCR", "kind": "fraction", "direction": "higher"},
    "omniscience-accuracy": {"eval": "AA-Omniscience Accuracy", "kind": "fraction", "direction": "higher"},
    "omniscience-non-hallucination-rate": {"eval": "AA-Omniscience Non-Hallucination Rate",
                                           "kind": "fraction", "direction": "higher"},
    "aa-briefcase-elo": {"eval": "AA-Briefcase", "kind": "elo", "direction": "higher"},
    "aa-briefcase-analytical-elo": {"eval": "AA-Briefcase Analytical Quality & Presentation",
                                    "kind": "elo", "direction": "higher"},
    "gdpval-aa-elo": {"eval": "GDPval-AA", "kind": "elo", "direction": "higher"},
    "automationbench-aa": {"eval": "AutomationBench-AA", "kind": "fraction", "direction": "higher"},
}

# Work-type seed policy. Weights and floors are ours and uncalibrated; see the board's
# work-type and metric-discipline cards. A metric absent from the snapshot is UNKNOWN and
# never becomes a zero.
WORK_TYPES = [
    ("Defect fix", "defect_fix",
     [("scicode", 0.40), ("terminal-bench-4-0", 0.35), ("ifbench", 0.25)], [], 40.0),
    ("Diagnosis / investigation", "diagnosis",
     [("aa-lcr", 0.30), ("omniscience-accuracy", 0.30), ("terminal-bench-4-0", 0.25),
      ("omniscience-non-hallucination-rate", 0.15)], [], 40.0),
    ("Feature / capability", "feature",
     [("scicode", 0.40), ("terminal-bench-4-0", 0.35), ("aa-briefcase-elo", 0.25)], [], 40.0),
    ("Hardening / edge-case closure", "hardening",
     [("ifbench", 0.55), ("scicode", 0.45)], [], 32.0),
    ("Verification", "verification",
     [("omniscience-non-hallucination-rate", 0.40), ("ifbench", 0.35),
      ("terminal-bench-4-0", 0.25)], [], 35.0),
    ("Code review", "code_review",
     [("aa-briefcase-analytical-elo", 0.45), ("scicode", 0.30),
      ("omniscience-non-hallucination-rate", 0.25)], [], 38.0),
    ("Research / question-answering", "research",
     [("aa-lcr", 0.35), ("omniscience-accuracy", 0.30),
      ("omniscience-non-hallucination-rate", 0.35)],
     [("omniscience-non-hallucination-rate", 25.0)], 38.0),
    ("Analysis (data & financial)", "analysis",
     [("gdpval-aa-elo", 0.60), ("omniscience-non-hallucination-rate", 0.40)],
     [("omniscience-non-hallucination-rate", 25.0)], 38.0),
    ("Design / planning", "design",
     [("gdpval-aa-elo", 0.55), ("aa-briefcase-elo", 0.45)], [], 42.0),
    ("Ops / infrastructure", "ops",
     [("terminal-bench-4-0", 0.45), ("automationbench-aa", 0.35), ("ifbench", 0.20)], [], 35.0),
    ("Writing / comms", "writing",
     [("ifbench", 0.40), ("aa-briefcase-analytical-elo", 0.30),
      ("omniscience-non-hallucination-rate", 0.30)], [], 30.0),
    ("Upstream engagement", "upstream",
     [("omniscience-non-hallucination-rate", 0.40), ("ifbench", 0.35),
      ("aa-briefcase-analytical-elo", 0.25)], [], 35.0),
]
NONE_FIT = ("none-fit", "none_fit",
            [("gdpval-aa-elo", 0.20), ("aa-briefcase-elo", 0.20), ("scicode", 0.20),
             ("terminal-bench-4-0", 0.15), ("omniscience-non-hallucination-rate", 0.15),
             ("ifbench", 0.10)], [], 38.0)

COMPLEXITY_LEVELS = [
    "Immediate: one obvious edit, no investigation",
    "Small: one file or one narrow check",
    "Moderate: a few files and some investigation",
    "Substantial: cross-module change with written acceptance",
    "Hard: multi-subsystem, ambiguous, or design-heavy",
    "Very hard: long horizon, deep dependency chain, high blast radius",
]

CONFIDENCE_BANDS = [(0.85, "dispatch"), (0.55, "ask")]

_ELO_BASE = 500.0
_ELO_SPAN = 2000.0
_VERSION_RE = re.compile(r"\bv(\d+(?:\.\d+)+)\b")


def warn(message):
    """One line on stderr; never echoes brief text, a credential, or an API body."""
    sys.stderr.write("model-picker-shadow: %s\n" % message)


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def normalize_route(harness, model):
    return "%s:%s" % (harness or "", model or "")


def effort_map_for(harness):
    return HARNESS_EFFORTS.get(harness, [])


def confidence_band(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    if value >= CONFIDENCE_BANDS[0][0]:
        return CONFIDENCE_BANDS[0][1]
    if value >= CONFIDENCE_BANDS[1][0]:
        return CONFIDENCE_BANDS[1][1]
    return "escalate"


def metric_fit(metric_id, raw):
    spec = METRICS[metric_id]
    if not isinstance(raw, (int, float)) or isinstance(raw, bool):
        return None
    if spec["kind"] == "fraction":
        value = raw * 100.0
    else:
        value = (raw - _ELO_BASE) / _ELO_SPAN * 100.0
    return round(max(0.0, min(100.0, value)), 2)


def metric_version(record):
    if not isinstance(record, dict):
        return None
    match = _VERSION_RE.search(record.get("label") or "")
    return match.group(1) if match else None


def work_type_spec(name):
    for label, option, mix, vetoes, floor in WORK_TYPES + [NONE_FIT]:
        if label == name or option == name:
            return {"label": label, "option": option, "mix": mix, "vetoes": vetoes, "floor": floor}
    return work_type_spec("none-fit")


def verdict_state(data_root):
    """Fail closed: only a regular, non-symlinked, parseable file saying TRUSTED is trusted."""
    path = Path(data_root) / "verdict.json"
    try:
        info = path.lstat()
    except OSError:
        return False, "verdict.json is missing", None
    if path.is_symlink() or not os.path.isfile(path) or not (info.st_mode & 0o400):
        return False, "verdict.json is not a readable regular file in the data root", None
    try:
        doc = load_json(path)
    except (OSError, ValueError):
        return False, "verdict.json is unparseable", None
    if not isinstance(doc, dict) or doc.get("verdict") != "TRUSTED":
        return False, "verdict.json does not say TRUSTED", None
    return True, None, doc


def load_table(path):
    doc = load_json(path)
    if not isinstance(doc, dict) or doc.get("schema") != 1:
        raise ValueError("route table schema must be 1")
    if not isinstance(doc.get("routes"), dict):
        raise ValueError("route table needs a routes object")
    if not isinstance(doc.get("families") or {}, dict):
        raise ValueError("route table families must be an object")
    return doc


def table_entry(table, route):
    return (table.get("routes") or {}).get(route)


def projection_for(entry, effort):
    projections = entry.get("projections") or {}
    if not isinstance(projections, dict):
        return None, "route table entry has no projections"
    chosen = projections.get(effort) or projections.get("default")
    if not isinstance(chosen, dict) or not chosen.get("slug"):
        return None, "route table has no projection for effort %s" % (effort or "-")
    return chosen, None


def load_projection(data_root, slug):
    """A projection is untrusted input: it must be a regular file with the asserted name."""
    path = Path(data_root) / "projection" / (slug + ".json")
    try:
        if path.is_symlink() or not path.is_file():
            return None, "projection %s is missing or not a regular file" % slug
        doc = load_json(path)
    except (OSError, ValueError):
        return None, "projection %s is unreadable" % slug
    if not isinstance(doc, dict) or not isinstance(doc.get("metrics"), dict):
        return None, "projection %s has no metrics" % slug
    return doc, None


def asserted_projection(table, entry, chosen, data_root):
    """Load a mapped projection and assert its identity: the table's asserted name and the
    family's creator must both match, else the projection is refused."""
    projection, why = load_projection(data_root, chosen["slug"])
    if projection is None:
        return None, why
    if projection.get("name") != chosen.get("name"):
        return None, ("projection identity refused: %s is %r, table asserts %r"
                      % (chosen["slug"], projection.get("name"), chosen.get("name")))
    creator = ((table.get("families") or {}).get(entry.get("family")) or {}).get("creator")
    if projection.get("creator") != creator:
        return None, ("projection creator %r does not match family %r"
                      % (projection.get("creator"), entry.get("family")))
    return projection, None


def _profile_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [value]
    return []


def routes_from_rules(rules_doc):
    """Every concrete route reachable from the dispatch rules: use, fallback, default and
    default_fallback. Deduplicated by harness:model; the first configured effort wins."""
    found = {}
    if not isinstance(rules_doc, dict):
        return found
    sources = []
    for rule in rules_doc.get("rules") or []:
        if not isinstance(rule, dict):
            continue
        sources.extend(_profile_list(rule.get("use")))
        sources.extend(_profile_list(rule.get("fallback")))
    sources.extend(_profile_list(rules_doc.get("default")))
    sources.extend(_profile_list(rules_doc.get("default_fallback")))
    for profile in sources:
        if not isinstance(profile, dict) or not isinstance(profile.get("harness"), str):
            continue
        if not isinstance(profile.get("model"), str) or not profile["model"]:
            continue
        route = normalize_route(profile["harness"], profile["model"])
        if route in found:
            continue
        found[route] = {
            "route": route,
            "harness": profile["harness"],
            "model": profile["model"],
            "effort": profile.get("effort") if isinstance(profile.get("effort"), str) else None,
        }
    return found


def resolver_assessment(result, route):
    for candidate in result.get("candidates") or []:
        if not isinstance(candidate, dict) or not isinstance(candidate.get("profile"), dict):
            continue
        profile = candidate["profile"]
        if normalize_route(profile.get("harness"), profile.get("model")) == route:
            return candidate
    return None


def quota_lane(harness, model):
    """The candidate's quota account key, as bin/fm-quota-axi-lib.sh's quota_lane binds it."""
    if harness == "codex":
        return "codex-home"
    if harness in ("pi", "pi-signed") and "/" in (model or ""):
        lane = model.split("/", 1)[0]
        return "codex-home" if lane == "codex-native" else lane
    return ""


def quota_row(quota_doc, provider, lane):
    """The one provider row a candidate binds to, as bin/fm-quota-axi-lib.sh's quota_row does."""
    rows = [p for p in quota_doc.get("providers") or []
            if isinstance(p, dict) and p.get("provider") == provider]
    if quota_doc.get("schemaVersion") == 6:
        for key in (lane, "default"):
            for row in rows:
                if row.get("accountKey") == key:
                    return row
        return None
    return rows[0] if rows else None


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def quota_facts(entry, harness, model, quota_doc, assessment):
    """Quota evidence for one route from the resolver's one snapshot (never a second probe).
    API routes carry no quota row: their lane is priced in dollars and gets no quota field."""
    if entry.get("currency") != "subscription":
        return None
    if assessment is not None:
        capacity = assessment.get("capacity")
        if isinstance(capacity, dict):
            return {"spendPriority": None,
                    "headroom_pct": capacity.get("bestAccountHeadroom"),
                    "runway": None, "capacity": capacity.get("status"),
                    "pool": True, "source": "resolver-pool-snapshot"}
        return {"spendPriority": assessment.get("spendPriority"),
                "headroom_pct": assessment.get("pct"),
                "runway": assessment.get("runway"),
                "capacity": "usable" if assessment.get("eligible") else "unusable",
                "source": "resolver-candidate"}
    provider = entry.get("provider")
    if not provider or not isinstance(quota_doc, dict):
        return {"spendPriority": None, "headroom_pct": None, "runway": None,
                "capacity": "unknown", "source": "no-quota-row"}
    row = quota_row(quota_doc, provider, quota_lane(harness, model))
    if row is None:
        return {"spendPriority": None, "headroom_pct": None, "runway": None,
                "capacity": "unknown", "source": "no-quota-row"}
    bare = (model or "").split("/")[-1]
    scopes = {"all_models", "all_products"}
    if model:
        scopes |= {"model:" + bare, "product:" + bare}
    availability = ((row.get("quotaSemantics") or {}).get("effectiveAvailability") or [])
    evidence = [r for r in availability if isinstance(r, dict) and r.get("scope") in scopes]
    if not evidence:
        return {"spendPriority": None, "headroom_pct": None, "runway": None,
                "capacity": "unknown", "source": "no-applicable-row"}
    ranked = [r for r in evidence if _number((r.get("selection") or {}).get("spendPriority"))]
    limiting = (min(ranked, key=lambda r: r["selection"]["spendPriority"])
                if ranked and len(ranked) == len(evidence) else None)
    pcts = [r.get("effectivePercentRemaining") for r in evidence]
    pcts = [p for p in pcts if _number(p)]
    runway = limiting.get("runway") if limiting is not None else None
    return {"spendPriority": limiting["selection"]["spendPriority"] if limiting is not None else None,
            "headroom_pct": min(pcts) if pcts else None,
            "runway": runway.get("status") if isinstance(runway, dict) else None,
            "capacity": "usable" if (pcts and min(pcts) > 0) else "unknown",
            "source": "quota-snapshot"}


def build_candidates(rules_doc, table, data_root, quota_doc, result):
    """One candidate per concrete route. A route the table cannot map stays a candidate
    with its facts read as UNKNOWN: never dropped, never zero."""
    routes = routes_from_rules(rules_doc)
    candidates = []
    for index, route in enumerate(sorted(routes), start=1):
        profile = routes[route]
        entry = table_entry(table, route)
        candidate = {
            "id": "candidate_%d" % index, "route": route, "harness": profile["harness"],
            "model": profile["model"], "effort_configured": profile["effort"],
            "family": None, "currency": None, "projection": None, "fit": None,
            "metrics": {}, "evidence_gaps": [], "cost": None, "token_rate": None,
            "time_rate": {"status": "unknown"}, "quota": None,
            "snapshot_age_seconds": None, "stale": False,
            "configured_eligible": True, "configured_reason": None,
            "configured_capacity_zero": False, "unknown_reason": None, "effort_note": None,
        }
        if entry is None:
            candidate["unknown_reason"] = "route is not in the versioned route table"
            candidates.append(candidate)
            continue
        candidate["family"] = entry.get("family")
        candidate["currency"] = entry.get("currency")
        chosen, why = projection_for(entry, profile["effort"])
        if chosen is None:
            candidate["unknown_reason"] = why
            candidates.append(candidate)
            continue
        projection, why = asserted_projection(table, entry, chosen, data_root)
        if projection is None:
            candidate["unknown_reason"] = why
            candidates.append(candidate)
            continue
        candidate["projection"] = {"slug": chosen["slug"], "name": projection.get("name"),
                                   "as_of": projection.get("as_of"), "asserted": True}
        candidate["effort_note"] = chosen.get("effort_note")
        candidate["metrics"] = projection["metrics"]
        candidate["as_of"] = projection.get("as_of")
        assessment = resolver_assessment(result, route)
        if assessment is not None:
            candidate["configured_eligible"] = bool(assessment.get("eligible"))
            reason = assessment.get("reason")
            candidate["configured_reason"] = reason if isinstance(reason, str) else None
            if not candidate["configured_eligible"] and isinstance(reason, str) and (
                    "exhausted_now" in reason or "0% remaining" in reason):
                candidate["configured_eligible"] = True
                candidate["configured_capacity_zero"] = True
        candidate["quota"] = quota_facts(entry, profile["harness"], profile["model"],
                                         quota_doc, assessment)
        if entry.get("currency") == "api":
            cost = projection["metrics"].get("costpertask")
            if isinstance(cost, dict) and isinstance(cost.get("value"), (int, float)):
                candidate["cost"] = {"kind": "api_dollar_proxy", "usd_per_task": cost["value"]}
            inp = projection["metrics"].get("inputpriceper1mtokens")
            out = projection["metrics"].get("outputpriceper1mtokens")
            candidate["token_rate"] = {
                "input_usd_per_mtok": inp.get("value") if isinstance(inp, dict) else None,
                "output_usd_per_mtok": out.get("value") if isinstance(out, dict) else None,
            }
        candidates.append(candidate)
    return candidates


def demanded_metrics(spec, candidates):
    """The demanded mix over metrics the snapshot actually carries, plus version conflicts.
    A metric whose eval version differs across candidates is excluded and flagged."""
    conflicts = []
    kept = []
    for metric_id, weight in spec["mix"]:
        versions = set()
        for candidate in candidates:
            record = candidate["metrics"].get(metric_id)
            if isinstance(record, dict) and record.get("value") is not None:
                version = metric_version(record)
                if version:
                    versions.add(version)
        if len(versions) > 1:
            conflicts.append({"metric": metric_id, "versions": sorted(versions)})
            continue
        kept.append((metric_id, weight))
    total = sum(weight for _, weight in kept) or 1.0
    return [(metric_id, weight / total) for metric_id, weight in kept], conflicts


def compute_facts(candidate, mix):
    facts = {}
    fit_total = 0.0
    weight_total = 0.0
    age_values = []
    gaps = []
    for metric_id, weight in mix:
        record = candidate["metrics"].get(metric_id)
        if not isinstance(record, dict) or record.get("value") is None:
            gaps.append("%s: no measured value" % METRICS[metric_id]["eval"])
            continue
        fit = metric_fit(metric_id, record["value"])
        if fit is None:
            gaps.append("%s: non-numeric value" % METRICS[metric_id]["eval"])
            continue
        facts[metric_id] = {
            "eval": METRICS[metric_id]["eval"], "metric": metric_id,
            "weight": round(weight, 4), "raw": record["value"],
            "unit": record.get("unit"), "scale": record.get("scale"),
            "direction": METRICS[metric_id]["direction"], "fit": fit,
            "version": metric_version(record), "observed_at": record.get("observed_at"),
        }
        fit_total += fit * weight
        weight_total += weight
        if isinstance(record.get("observed_at"), str):
            age_values.append(record["observed_at"])
    candidate["metric_facts"] = facts
    candidate["fit"] = round(fit_total / weight_total, 2) if weight_total else None
    candidate["evidence_gaps"] = gaps
    if age_values:
        try:
            age = aadb.snapshot_age_seconds(min(age_values))
        except (ValueError, OverflowError):
            age = None
        candidate["snapshot_age_seconds"] = age
        candidate["stale"] = bool(age is not None and age > STALE_AFTER_SECONDS)


def apply_gates(candidates, spec, complexity):
    """Hard gates before Jev sees anything. Fit floors and metric vetoes are uncalibrated
    seed policy; a missing fact never prunes (unknown is not worse)."""
    floor = spec["floor"] + complexity * 20.0
    pruned = []
    for candidate in candidates:
        reasons = []
        if not candidate["configured_eligible"]:
            reasons.append("ineligible: %s" % (candidate["configured_reason"] or "resolver eligibility"))
        if candidate["fit"] is not None and candidate["fit"] < floor:
            reasons.append("fit %.2f below the %s fit floor %.2f" % (candidate["fit"], SEED_LABEL, floor))
        for metric_id, minimum in spec["vetoes"]:
            fact = (candidate.get("metric_facts") or {}).get(metric_id)
            if fact is not None and fact["fit"] < minimum:
                reasons.append("veto: %s fit %.2f below %.2f"
                               % (METRICS[metric_id]["eval"], fact["fit"], minimum))
        if reasons:
            pruned.append({"route": candidate["route"], "reasons": reasons})
    pruned_routes = {p["route"] for p in pruned}
    return [c for c in candidates if c["route"] not in pruned_routes], pruned, floor


def _dominates(a, b, mix):
    """Strict Pareto dominance inside one family and one currency class.
    Unknown on either side blocks dominance; equal is not strict."""
    if a["family"] != b["family"] or a["currency"] != b["currency"]:
        return False
    if a["family"] is None or a["currency"] is None:
        return False
    better = False
    for metric_id, _ in mix:
        fa = (a.get("metric_facts") or {}).get(metric_id)
        fb = (b.get("metric_facts") or {}).get(metric_id)
        if fa is None or fb is None:
            return False
        if fa["fit"] < fb["fit"]:
            return False
        if fa["fit"] > fb["fit"]:
            better = True
    if a["currency"] == "api":
        ca = (a.get("cost") or {}).get("usd_per_task")
        cb = (b.get("cost") or {}).get("usd_per_task")
        if not isinstance(ca, (int, float)) or not isinstance(cb, (int, float)):
            return False
        if ca > cb:
            return False
        if ca < cb:
            better = True
    else:
        qa = (a.get("quota") or {}).get("spendPriority")
        qb = (b.get("quota") or {}).get("spendPriority")
        if not isinstance(qa, (int, float)) or not isinstance(qb, (int, float)):
            return False
        if qa < qb:
            return False
        if qa > qb:
            better = True
    return better


def apply_pareto(survivors, mix):
    """Elimination only, within family + currency. Every family keeps at least one survivor;
    cross-currency pairs are never compared and a cheaper-but-mixed candidate is flagged as a
    trial instead of pruned."""
    dominated = {}
    for candidate in survivors:
        for other in survivors:
            if candidate is other:
                continue
            if _dominates(other, candidate, mix):
                dominated.setdefault(candidate["route"], []).append(other["route"])
    pruned = []
    for route, by in sorted(dominated.items()):
        target = next(c for c in survivors if c["route"] == route)
        pruned.append({"route": route, "dominated_by": sorted(by),
                       "reason": "strict Pareto dominance within %s / %s"
                                 % (target["family"], target["currency"])})
    pruned_routes = {p["route"] for p in pruned}
    kept = [c for c in survivors if c["route"] not in pruned_routes]
    tradeoffs = []
    trials = []
    for i, a in enumerate(kept):
        for b in kept[i + 1:]:
            if a["family"] == b["family"] and a["currency"] == b["currency"]:
                wins = set()
                for metric_id, _ in mix:
                    fa = (a.get("metric_facts") or {}).get(metric_id)
                    fb = (b.get("metric_facts") or {}).get(metric_id)
                    if fa is None or fb is None:
                        continue
                    if fa["fit"] > fb["fit"]:
                        wins.add(a["route"])
                    elif fb["fit"] > fa["fit"]:
                        wins.add(b["route"])
                if wins == {a["route"], b["route"]}:
                    tradeoffs.append({"a": a["route"], "b": b["route"],
                                      "reason": "mixed strengths; both survive for the picker"})
            elif a["currency"] != b["currency"]:
                trials.append({"a": a["route"], "b": b["route"],
                               "reason": "different currencies; no dollar comparison crosses the subscription/API line, so a cheaper trial is flagged and never pruned"})
    spend = {}
    for candidate in kept:
        quota = candidate.get("quota") or {}
        if isinstance(quota.get("spendPriority"), (int, float)):
            spend[candidate["route"]] = quota["spendPriority"]
    return kept, pruned, tradeoffs, trials, spend


def deterministic_complexity(task_text, rules_doc):
    paths = set(re.findall(
        r"\b(?:bin|tests|docs|data|config|src)/[\w./-]+|\b[\w-]+\.(?:sh|py|ts|md|json|toml|yaml|yml)\b",
        task_text))
    steps = len(re.findall(r"(?m)^\s*(?:[-*]|\d+\.)\s+", task_text))
    subsystems = {p.split("/", 1)[0] for p in paths}
    structural = min(1.0, (min(len(paths), 12) / 12.0) * 0.6
                     + (min(len(subsystems), 5) / 5.0) * 0.4)
    horizon_minutes = rules_doc.get("task_horizon_minutes") if isinstance(rules_doc, dict) else None
    if not isinstance(horizon_minutes, (int, float)) or isinstance(horizon_minutes, bool) \
            or horizon_minutes <= 0:
        horizon_minutes = 240
    horizon = min(1.0, float(horizon_minutes) / 480.0)
    decomposability = 1.0 - min(1.0, steps / 12.0)
    value = 0.50 * structural + 0.30 * horizon + 0.20 * decomposability
    return round(min(1.0, max(0.0, value)), 3), {
        "paths": len(paths), "subsystems": sorted(subsystems), "steps": steps,
        "task_horizon_minutes": horizon_minutes, "structural": round(structural, 3),
        "horizon": round(horizon, 3), "decomposability": round(decomposability, 3),
    }


def candidate_summary(candidate):
    if candidate.get("unknown_reason"):
        return "%s (%s, %s). Facts UNKNOWN: %s" % (
            candidate["route"], candidate.get("family") or "family unknown",
            candidate.get("currency") or "currency unknown", candidate["unknown_reason"])
    parts = []
    if candidate.get("fit") is not None:
        parts.append("demanded-mix fit %.2f/100" % candidate["fit"])
    for _, fact in sorted((candidate.get("metric_facts") or {}).items()):
        parts.append("%s raw %s %s -> fit %.2f (version %s)"
                     % (fact["eval"], fact["raw"], fact["unit"] or "", fact["fit"],
                        fact["version"] or "unknown"))
    if candidate.get("evidence_gaps"):
        parts.append("gaps: " + "; ".join(candidate["evidence_gaps"]))
    if candidate.get("cost"):
        parts.append("AA cost per task %.4f USD (API-dollar proxy)"
                     % candidate["cost"]["usd_per_task"])
    if candidate.get("token_rate"):
        parts.append("token rate in %s / out %s USD per 1M (API)"
                     % (candidate["token_rate"]["input_usd_per_mtok"],
                        candidate["token_rate"]["output_usd_per_mtok"]))
    quota = candidate.get("quota") or {}
    if quota:
        parts.append("quota spendPriority %s, headroom %s%%, runway %s, capacity %s"
                     % (quota.get("spendPriority"), quota.get("headroom_pct"),
                        quota.get("runway"), quota.get("capacity")))
    if candidate.get("snapshot_age_seconds") is not None:
        parts.append("snapshot age %d s%s" % (
            candidate["snapshot_age_seconds"], " (STALE)" if candidate["stale"] else ""))
    if candidate.get("effort_note"):
        parts.append(candidate["effort_note"])
    return "%s (%s, %s). %s" % (candidate["route"], candidate.get("family"),
                                 candidate.get("currency"), "; ".join(parts))


def validator_summary(candidate):
    verification = ["omniscience-non-hallucination-rate", "ifbench", "aa-briefcase-analytical-elo"]
    parts = []
    for metric_id in verification:
        record = (candidate.get("metrics") or {}).get(metric_id)
        if isinstance(record, dict) and record.get("value") is not None:
            fit = metric_fit(metric_id, record["value"])
            if fit is not None:
                parts.append("%s fit %.2f (provisional review proxy)"
                             % (METRICS[metric_id]["eval"], fit))
    if not parts:
        parts.append("verification evidence UNKNOWN")
    return "%s (family %s). Verification and code-review evidence: %s" % (
        candidate["route"], candidate.get("family"), "; ".join(parts))


def state_for(task_text, project, extra=None):
    state = {
        "task": task_text[:PROMPT_TASK_LIMIT],
        "project": project or "",
        "policy_version": POLICY_VERSION,
        "policy_label": SEED_LABEL,
        "snapshot": {"verdict": "TRUSTED", "stale_after_seconds": STALE_AFTER_SECONDS},
    }
    if extra:
        state.update(extra)
    return state


def classify_request(task_text, project):
    return {"model": "jev-latest", "state": state_for(task_text, project), "questions": {
        "work_type": {
            "type": "choice",
            "instructions": "Which ONE work type best fits `task`? Pick none_fit when no listed type fits, never a forced best guess.",
            "criteria": {option: label for label, option, _, _, _ in WORK_TYPES + [NONE_FIT]}},
        "complexity": {
            "type": "score",
            "instructions": "How hard is `task` for a capable agent? Judge observable structural signals, horizon and dependency depth, not the task name.",
            "criteria": COMPLEXITY_LEVELS},
    }}


def pick_request(task_text, project, survivors, validators, spec):
    extra = {
        "work_type_mix": [{"metric": METRICS[m]["eval"], "weight": round(w, 4)}
                          for m, w in spec["mix"]],
        "candidates": [{"id": c["id"], "route": c["route"], "family": c.get("family"),
                        "currency": c.get("currency"), "summary": candidate_summary(c)}
                       for c in survivors],
    }
    return {"model": "jev-latest", "state": state_for(task_text, project, extra), "questions": {
        "worker": {
            "type": "choice",
            "instructions": "Choose the ONE worker route that best fits `task` on the demanded evidence, its family, its currency facts and its cost. Candidates already passed the hard gates and within-family Pareto pruning; mixed strengths are normal. Pick only a listed candidate.",
            "criteria": {c["id"]: candidate_summary(c) for c in survivors}},
        "validator": {
            "type": "choice",
            "instructions": "Choose ONE validator route from a DIFFERENT model family than your worker choice. Its evidence is the verification and code-review set (non-hallucination, instruction following, Briefcase analytical quality), not the worker's work-type mix.",
            "criteria": {c["id"]: validator_summary(c) for c in validators}},
        "effort": {
            "type": "score",
            "instructions": "Which reasoning effort should the chosen worker run at for `task`?",
            "criteria": EFFORT_LEVELS},
    }}


def validator_request(task_text, worker, alternatives):
    return {"model": "jev-latest",
            "state": state_for(task_text, "", {"worker_family": worker.get("family")}),
            "questions": {"validator": {
                "type": "choice",
                "instructions": "Choose ONE validator route from a DIFFERENT model family than %s. Its evidence is the code-review set." % worker["route"],
                "criteria": {c["id"]: validator_summary(c) for c in alternatives}}}}


def _confidence(answer, qid):
    confidence = answer.get("confidence")
    if not _number(confidence):
        return None
    if not 0 <= confidence <= 1:
        raise ValueError("malformed Jev payload: %s confidence %s is outside 0..1"
                         % (qid, confidence))
    return confidence


def parse_answers(raw, request):
    doc = json.loads(raw)
    if not isinstance(doc, dict) or not isinstance(doc.get("answers"), dict):
        raise ValueError("malformed Jev payload: no answers object")
    answers = doc["answers"]
    parsed = {}
    for qid, question in request["questions"].items():
        answer = answers.get(qid)
        if not isinstance(answer, dict) or answer.get("type") != question["type"]:
            raise ValueError("malformed Jev payload: %s answer missing or wrong type" % qid)
        if question["type"] == "choice":
            choice = answer.get("choice")
            # An option outside the criteria is a contract violation. Keep it here so the
            # caller can fail closed: an unknown work type becomes none-fit and an unknown
            # worker or validator answer is rejected by the re-check, never used.
            if not isinstance(choice, str) or not choice:
                raise ValueError("Jev answer for %s has no choice" % qid)
            probabilities = answer.get("probabilities")
            if not isinstance(probabilities, dict):
                raise ValueError("malformed Jev payload: %s has no probabilities" % qid)
            confidence = _confidence(answer, qid)
            parsed[qid] = {"choice": choice, "confidence": confidence,
                           "probabilities": probabilities}
        else:
            score = answer.get("score")
            if not _number(score):
                raise ValueError("malformed Jev payload: %s score missing" % qid)
            if not 0 <= score <= len(question["criteria"]) - 1:
                raise ValueError("malformed Jev payload: %s score %s is outside 0..%d"
                                 % (qid, score, len(question["criteria"]) - 1))
            legend = answer.get("legend")
            confidence = _confidence(answer, qid)
            parsed[qid] = {"score": score, "confidence": confidence,
                           "legend": legend if isinstance(legend, dict) else {}}
    version = doc.get("model")
    if not isinstance(version, str) or not re.match(r"\Ajev-[0-9]+(\.[0-9]+)*\Z", version):
        version = None
    return parsed, version


def jev_call(request, key, never_send, helper, scratch_dir):
    """One policy-checked System One POST through the shared transport. The exact response
    body is returned byte for byte; the key never touches argv, the environment or a file."""
    request_path = os.path.join(scratch_dir, "request.json")
    response_path = os.path.join(scratch_dir, "response.json")
    policy_scratch = os.path.join(scratch_dir, "policy.txt")
    with open(request_path, "w", encoding="utf-8") as handle:
        json.dump(request, handle, sort_keys=True)
    read_end, write_end = os.pipe()
    os.write(write_end, key.encode("utf-8") + b"\n")
    os.close(write_end)
    saved = None
    try:
        try:
            saved = os.dup(3)
        except OSError:
            saved = None
        os.dup2(read_end, 3)
        command = ["bash", helper, request_path, never_send, response_path, policy_scratch]
        try:
            proc = subprocess.run(command, pass_fds=(3,), stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=8)  # measured: value=8 date=2026-10-23 host=Mac-Studio margin=1.5 (five-second provider deadline plus helper startup and policy check; one stalled-call run measured 5.2 s)
        except subprocess.TimeoutExpired:
            return None, "request timed out"
    finally:
        if saved is not None:
            os.dup2(saved, 3)
            os.close(saved)
        os.close(read_end)
    if proc.returncode == 3:
        reason = proc.stderr.decode("utf-8", "replace").strip()
        return None, "request withheld by the never-send policy%s" % (
            (": " + reason.splitlines()[0]) if reason else "")
    if proc.returncode == 5:
        return None, "Jev HTTP %s" % proc.stdout.decode("utf-8", "replace").strip()
    if proc.returncode != 0:
        return None, "Jev transport failure"
    try:
        with open(response_path, "rb") as handle:
            return handle.read(), None
    except OSError:
        return None, "Jev response unreadable"


def recheck(worker, validator, effort, pruned_routes, spec, complexity):
    """Prediction is never permission: re-check the allowlist, the gates and the harness's
    effort levels against the pick, and never silently replace it."""
    problems = []
    if worker is None:
        problems.append("worker answer names no listed candidate")
        return problems
    if worker["route"] in pruned_routes:
        problems.append("worker %s is outside the survivor list (pruned)" % worker["route"])
    if not worker["configured_eligible"]:
        problems.append("worker %s is not eligible: %s"
                        % (worker["route"], worker["configured_reason"]))
    if worker.get("fit") is not None and worker["fit"] < spec["floor"] + complexity * 20.0:
        problems.append("worker %s is below the fit floor on re-check" % worker["route"])
    for metric_id, minimum in spec["vetoes"]:
        fact = (worker.get("metric_facts") or {}).get(metric_id)
        if fact is not None and fact["fit"] < minimum:
            problems.append("worker %s fails the %s veto on re-check"
                            % (worker["route"], METRICS[metric_id]["eval"]))
    if validator is not None:
        if not validator["configured_eligible"]:
            problems.append("validator %s is not eligible: %s"
                            % (validator["route"], validator["configured_reason"]))
        if validator.get("family") == worker.get("family"):
            problems.append("validator %s is the worker's own family" % validator["route"])
        record = (validator.get("metrics") or {}).get("omniscience-non-hallucination-rate")
        if isinstance(record, dict) and record.get("value") is not None:
            fit = metric_fit("omniscience-non-hallucination-rate", record["value"])
            if fit is not None and fit < 25.0:
                problems.append("validator %s fails the %s non-hallucination review floor on re-check (%.2f < 25.00)"
                                % (validator["route"], SEED_LABEL, fit))
    if effort is not None:
        if effort not in effort_map_for(worker["harness"]):
            problems.append("effort %s is not accepted by %s" % (effort, worker["harness"]))
    return problems


def pick_effort(score):
    return EFFORT_LEVELS[int(round(score))]


def row_from_pick(*, status, reason, task_key, rule, work_type, work_type_conf,
                  complexity, components, complexity_conf, band, stale, uncertain,
                  chosen_worker, chosen_validator, effort, raw_payload, raw_support,
                  candidate_version, gates, pareto, spend, snapshot_age):
    return {
        "mode": "shadow", "work_type": work_type, "complexity_score": complexity,
        "chosen_worker": chosen_worker, "chosen_validator": chosen_validator,
        "effort": effort,
        "rule_worker": rule.get("worker") if rule else None,
        "rule_validator": rule.get("validator") if rule else None,
        "rule_effort": rule.get("effort") if rule else None,
        "jev_raw_payload": raw_payload, "jev_candidate_version": candidate_version,
        "gates": gates, "pareto_pruned": pareto, "spend_priority": spend,
        "snapshot_age": snapshot_age, "policy_version": POLICY_VERSION,
        "task_key": task_key, "work_type_confidence": work_type_conf,
        "complexity_components": components, "complexity_confidence": complexity_conf,
        "confidence_band": band, "snapshot_stale": None if stale is None else int(bool(stale)),
        "classification_uncertain": None if uncertain is None else int(bool(uncertain)),
        "picker_status": status, "reject_reason": reason,
        "jev_raw_support": raw_support,
    }


def write_row(data_root, row):
    conn = None
    try:
        conn = aadb.connect(Path(data_root) / "aa.sqlite")
        aadb.init_calibration(conn)
        return aadb.log_dispatch(conn, **row)
    except (sqlite3.Error, OSError) as error:
        warn("could not write the shadow dispatch row (%s); dispatch unchanged" % error)
        return None
    finally:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass


def simple_row(status, reason, task_key, rule, verdict_reason=None):
    return row_from_pick(
        status=status, reason=reason, task_key=task_key, rule=rule, work_type=None,
        work_type_conf=None, complexity=None, components=None, complexity_conf=None,
        band=None, stale=None, uncertain=None, chosen_worker=None, chosen_validator=None,
        effort=None, raw_payload=None, raw_support=None, candidate_version=None,
        gates={"policy_version": POLICY_VERSION, "seed_label": SEED_LABEL,
               "verdict": verdict_reason or reason},
        pareto=[], spend={}, snapshot_age=None)


def task_key_for(brief_path):
    path = Path(brief_path)
    if path.name == "brief.md":
        return path.parent.name or None
    return path.stem or None


def resolver_mark_path(data_root, task_key):
    """One-shot marker naming the resolver row for this task, so the spawn hook attaches
    the launch to that row and does not log the same dispatch twice; None when the task
    key cannot name a file."""
    if not task_key or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", task_key):
        return None
    return Path(data_root) / "resolver-rows" / task_key


def brief_identity(brief_path):
    """The brief's real path and content hash, so a marker matches only the brief it was
    written for; None when the brief is not a readable regular file."""
    try:
        path = Path(brief_path).resolve()
        if not path.is_file():
            return None
        return {"brief": str(path), "brief_sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    except OSError:
        return None


def read_mark(mark):
    try:
        doc = json.loads(mark.read_text())
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def mark_row_id(doc):
    row_id = doc.get("row_id") if doc else None
    return row_id if isinstance(row_id, int) and not isinstance(row_id, bool) else None


def take_mark(mark, identity):
    """Consume the resolver's marker: its row id, and whether it was written for this same
    brief within RESOLVER_MARK_FRESH_SECONDS. A stale marker's row is superseded by the
    launch's own row, so the dispatch still counts once."""
    doc = read_mark(mark)
    try:
        mark.unlink()
    except OSError:
        return None, False
    row_id = mark_row_id(doc)
    if row_id is None or identity is None \
            or any(doc.get(name) != value for name, value in identity.items()):
        return row_id, False
    created = doc.get("created_at")
    fresh = isinstance(created, (int, float)) and not isinstance(created, bool) \
        and 0 <= time.time() - created <= RESOLVER_MARK_FRESH_SECONDS
    return row_id, fresh


def parse_gates(text):
    try:
        gates = json.loads(text or "{}")
    except ValueError:
        return {}
    return gates if isinstance(gates, dict) else {}


def amend_row(data_root, dispatch_id, amend):
    """Change one logged shadow row: amend(row, gates) edits its parsed gates and returns
    the other columns to set. False when there is no such row."""
    conn = None
    try:
        conn = aadb.connect(Path(data_root) / "aa.sqlite")
        aadb.init_calibration(conn)
        row = conn.execute("SELECT rule_worker, rule_effort, gates FROM dispatch_log "
                           "WHERE id = ? AND mode = 'shadow'", (dispatch_id,)).fetchone()
        if row is None:
            return False
        gates = parse_gates(row["gates"])
        columns = amend(row, gates)
        aadb.amend_row(conn, dispatch_id, gates, **columns)
        return True
    except (sqlite3.Error, OSError, LookupError) as error:
        warn("could not update shadow row %s (%s); dispatch unchanged" % (dispatch_id, error))
        return False
    finally:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass


def attach_launch(data_root, dispatch_id, rule):
    """Set the resolver row's rule route to the route that actually launched, keeping the
    resolver's own route in gates.launch_attached."""
    def amend(row, gates):
        gates["launch_attached"] = {"resolver_worker": row["rule_worker"],
                                    "resolver_effort": row["rule_effort"]}
        return {"rule_worker": rule["worker"], "rule_effort": rule["effort"]}
    return amend_row(data_root, dispatch_id, amend)


def supersede(data_root, dispatch_id, by):
    """Flag an earlier resolver row for the same task as replaced by a newer resolve, so
    the report counts the dispatch once."""
    def amend(row, gates):
        gates["superseded_by"] = by
        return {}
    return amend_row(data_root, dispatch_id, amend)


def _load_optional(path):
    if not path or not os.path.exists(path):
        return {}
    try:
        doc = load_json(path)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def never_send_path(args):
    """The never-send policy every request is checked against: --never-send, else the home's
    config/dispatch-never-send. There is no way to skip the check."""
    if args.get("never_send"):
        return args["never_send"]
    home = os.environ.get("FM_HOME") or str(Path(__file__).resolve().parent.parent.parent)
    config_dir = os.environ.get("FM_CONFIG_OVERRIDE") or os.path.join(home, "config")
    return os.path.join(config_dir, "dispatch-never-send")


def observe(args, key, helper, data_root):
    brief = args.get("brief")
    task_text = ""
    if args.get("task_text"):
        try:
            task_text = Path(args["task_text"]).read_text(encoding="utf-8", errors="replace")
        except OSError:
            task_text = ""
    status = args.get("status") or "clear"
    reason = args.get("reason") or None
    rules_doc = _load_optional(args.get("rules"))
    result = _load_optional(args.get("result"))
    quota_doc = _load_optional(args.get("quota"))
    rule_profile = (result.get("chosen") or {}).get("profile") or {}
    rule = {"worker": None, "validator": None, "effort": None}
    launch = args.get("hook") == "spawn"
    if (launch or status not in ("withheld", "error")) and isinstance(rule_profile, dict) \
            and isinstance(rule_profile.get("harness"), str):
        rule["worker"] = normalize_route(rule_profile.get("harness"), rule_profile.get("model"))
        effort = rule_profile.get("effort")
        rule["effort"] = effort if isinstance(effort, str) and effort else None
    task_key = task_key_for(brief) if brief else None
    mark = resolver_mark_path(data_root, task_key)
    identity = brief_identity(brief) if mark is not None else None
    marked_row = None
    if launch:
        marked_row, fresh = take_mark(mark, identity) if mark is not None else (None, False)
        if fresh and attach_launch(data_root, marked_row, rule):
            return 0
        mark = None
    elif identity is None:
        mark = None

    def record(row):
        dispatch_id = write_row(data_root, row)
        if dispatch_id is None:
            return
        previous = mark_row_id(read_mark(mark)) if mark is not None else marked_row
        if previous is not None:
            supersede(data_root, previous, dispatch_id)
        if mark is None:
            return
        try:
            mark.parent.mkdir(parents=True, exist_ok=True)
            mark.write_text(json.dumps(dict(identity, row_id=dispatch_id, created_at=time.time()),
                                       sort_keys=True))
        except OSError as error:
            warn("could not leave the resolver row marker (%s); dispatch unchanged" % error)

    if status == "withheld":
        record(simple_row("withheld", reason or "request withheld", task_key, rule))
        return 0
    if status == "error":
        record(simple_row("resolver-error", reason or "resolver error", task_key, rule))
        return 0

    trusted, verdict_reason, _ = verdict_state(data_root)
    if not trusted:
        record(simple_row("no-trusted-snapshot", verdict_reason, task_key, rule,
                          verdict_reason))
        return 0

    try:
        table = load_table(args["table"])
    except (OSError, ValueError) as error:
        record(simple_row("error", "route table unusable: %s" % error, task_key, rule))
        return 0

    det_complexity, det_components = deterministic_complexity(task_text, rules_doc)
    candidates = build_candidates(rules_doc, table, data_root, quota_doc, result)
    request = classify_request(task_text, args.get("project"))
    body, error = jev_call(request, key, never_send_path(args), helper, args["scratch"])
    if error:
        status = "withheld" if error.startswith("request withheld") else "picker-error"
        record(simple_row(status, error, task_key, rule))
        return 0
    responses = [("classification", body)]
    try:
        classified, candidate_version = parse_answers(body, request)
    except ValueError as error:
        row = simple_row("invalid-response", str(error), task_key, rule)
        row["jev_raw_payload"] = body
        record(row)
        return 0

    option = classified["work_type"]["choice"]
    spec = work_type_spec(option)
    uncertain = option not in {o for _, o, _, _, _ in WORK_TYPES}
    if uncertain:
        spec = work_type_spec("none-fit")
    work_type_conf = classified["work_type"]["confidence"]
    if work_type_conf is not None and work_type_conf < 0.60:
        uncertain = True
    complexity_score = classified["complexity"]["score"]
    complexity_norm = complexity_score / (len(COMPLEXITY_LEVELS) - 1)
    complexity = round(0.5 * det_complexity + 0.5 * complexity_norm, 3)
    components = dict(det_components, classification_score=complexity_score,
                      classification_confidence=classified["complexity"]["confidence"],
                      model_perceived=round(complexity_norm, 3))
    complexity_conf = classified["complexity"]["confidence"]

    mix, conflicts = demanded_metrics(spec, candidates)
    for candidate in candidates:
        compute_facts(candidate, mix)
    ages = [c["snapshot_age_seconds"] for c in candidates if c["snapshot_age_seconds"] is not None]
    snapshot_age = max(ages) if ages else None
    stale = bool(snapshot_age is not None and snapshot_age > STALE_AFTER_SECONDS)
    survivors, pruned, floor = apply_gates(candidates, spec, complexity)
    kept, pareto_pruned, tradeoffs, trials, spend = apply_pareto(survivors, mix)
    gates_base = {"policy_version": POLICY_VERSION, "table_version": table.get("table_version"),
                  "seed_label": SEED_LABEL, "floor": floor,
                  "classification": {"work_type": spec["label"],
                                     "confidence": work_type_conf, "uncertain": uncertain},
                  "version_conflicts": conflicts, "pruned": pruned,
                  "tradeoffs": tradeoffs, "currency_trials": trials}
    if not kept:
        row = row_from_pick(
            status="no-survivors", reason="no candidate survived the hard gates and Pareto pruning",
            task_key=task_key, rule=rule, work_type=spec["label"],
            work_type_conf=work_type_conf, complexity=complexity, components=components,
            complexity_conf=complexity_conf, band=None, stale=stale, uncertain=uncertain,
            chosen_worker=None, chosen_validator=None, effort=None,
            raw_payload=None, raw_support=json.dumps(
                [b.decode("utf-8", "replace") for _, b in responses]).encode("utf-8"),
            candidate_version=candidate_version, gates=gates_base, pareto=pareto_pruned,
            spend=spend, snapshot_age=snapshot_age)
        record(row)
        return 0

    validators = [c for c in candidates
                  if c.get("family") and c.get("projection") and c["configured_eligible"]]
    request = pick_request(task_text, args.get("project"), kept, validators, spec)
    body, error = jev_call(request, key, never_send_path(args), helper, args["scratch"])
    if error:
        row = row_from_pick(
            status="picker-error", reason=error, task_key=task_key, rule=rule,
            work_type=spec["label"], work_type_conf=work_type_conf, complexity=complexity,
            components=components, complexity_conf=complexity_conf, band=None, stale=stale,
            uncertain=uncertain, chosen_worker=None, chosen_validator=None, effort=None,
            raw_payload=None, raw_support=json.dumps(
                [b.decode("utf-8", "replace") for _, b in responses]).encode("utf-8"),
            candidate_version=candidate_version, gates=gates_base, pareto=pareto_pruned,
            spend=spend, snapshot_age=snapshot_age)
        record(row)
        return 0
    responses.append(("pick", body))
    try:
        picked, candidate_version = parse_answers(body, request)
    except ValueError as error:
        row = row_from_pick(
            status="invalid-response", reason=str(error), task_key=task_key, rule=rule,
            work_type=spec["label"], work_type_conf=work_type_conf, complexity=complexity,
            components=components, complexity_conf=complexity_conf, band=None, stale=stale,
            uncertain=uncertain, chosen_worker=None, chosen_validator=None, effort=None,
            raw_payload=body,
            raw_support=json.dumps([b.decode("utf-8", "replace") for _, b in responses[:-1]]).encode("utf-8"),
            candidate_version=candidate_version, gates=gates_base, pareto=pareto_pruned,
            spend=spend, snapshot_age=snapshot_age)
        record(row)
        return 0

    by_id = {c["id"]: c for c in candidates}
    worker = by_id.get(picked["worker"]["choice"])
    chosen_validator = {c["id"]: c for c in validators}.get(picked["validator"]["choice"])
    unknown_validator = chosen_validator is None
    effort = pick_effort(picked["effort"]["score"])
    band = confidence_band(picked["worker"]["confidence"])
    validator_reason = None
    if chosen_validator is not None and worker is not None \
            and chosen_validator.get("family") == worker.get("family"):
        alternatives = [c for c in validators if c.get("family") != worker.get("family")]
        if not alternatives:
            chosen_validator = None
            validator_reason = "no cross-family validator route exists"
        else:
            fallback = validator_request(task_text, worker, alternatives)
            body2, error2 = jev_call(fallback, key, never_send_path(args),
                                     helper, args["scratch"])
            if body2 is not None:
                responses.append(("validator-fallback", body2))
            if error2:
                chosen_validator = None
                validator_reason = "cross-family validator fallback failed: %s" % error2
            else:
                try:
                    picked2, _ = parse_answers(body2, fallback)
                    chosen_validator = {c["id"]: c for c in alternatives}.get(
                        picked2["validator"]["choice"])
                    unknown_validator = chosen_validator is None
                except ValueError as error3:
                    chosen_validator = None
                    validator_reason = "cross-family validator fallback malformed: %s" % error3

    pruned_routes = {p["route"] for p in pruned} | {p["route"] for p in pareto_pruned}
    problems = recheck(worker, chosen_validator, effort, pruned_routes, spec, complexity)
    if unknown_validator:
        problems.append("validator answer names no listed route")
    if worker is not None and worker["route"] not in {c["route"] for c in kept}:
        problems.append("worker %s is not a survivor of the authoritative mix" % worker["route"])
    result_status = "rejected" if problems else "accepted"
    result_reason = "; ".join(problems) if problems else validator_reason
    gates = dict(gates_base)
    gates["recheck"] = {"accepted": not problems, "problems": problems,
                        "worker": picked["worker"]["choice"],
                        "validator": picked["validator"]["choice"], "effort": effort}
    gates["validator_reason"] = validator_reason
    gates["stale"] = stale
    payload = next((b for kind, b in responses if kind == "pick"), None)
    support = [b for kind, b in responses if kind != "pick"]
    row = row_from_pick(
        status=result_status, reason=result_reason, task_key=task_key, rule=rule,
        work_type=spec["label"], work_type_conf=work_type_conf, complexity=complexity,
        components=components, complexity_conf=complexity_conf, band=band, stale=stale,
        uncertain=uncertain, chosen_worker=worker["route"] if not problems else None,
        chosen_validator=(chosen_validator["route"] if not problems and chosen_validator else None),
        effort=effort if not problems else None, raw_payload=payload,
        raw_support=(json.dumps([b.decode("utf-8", "replace") for b in support]).encode("utf-8")
                     if support else None),
        candidate_version=candidate_version, gates=gates, pareto=pareto_pruned,
        spend=spend, snapshot_age=snapshot_age)
    record(row)
    return 0


def report(data_root):
    db_path = Path(data_root) / "aa.sqlite"
    if not db_path.is_file():
        print("0 shadow dispatches logged")
        return 0
    try:
        # A Phase-1 store predates the picker's columns; run the same additive
        # migration the write path runs before reading them.
        conn = aadb.connect(str(db_path))
        aadb.init_calibration(conn)
        conn.row_factory = sqlite3.Row
        rows = [dict(r) for r in conn.execute(
            "SELECT work_type, chosen_worker, chosen_validator, effort, rule_worker, "
            "rule_validator, rule_effort, confidence_band, snapshot_stale, "
            "classification_uncertain, picker_status, gates FROM dispatch_log WHERE mode='shadow'")]
        conn.close()
    except sqlite3.Error as error:
        warn("could not read the shadow log: %s" % error)
        return 2
    rows = [r for r in rows if "superseded_by" not in parse_gates(r.pop("gates"))]
    if not rows:
        print("0 shadow dispatches logged")
        return 0
    counters = ("runs", "rule", "no_rule_route", "no_pick", "worker_den", "worker_diff",
                "validator_den", "validator_diff", "effort_den", "effort_diff", "dispatch",
                "ask", "escalate", "unknown_band", "stale", "none_fit", "rejected")
    compared = (("worker_den", "worker_diff", "rule_worker", "chosen_worker"),
                ("validator_den", "validator_diff", "rule_validator", "chosen_validator"),
                ("effort_den", "effort_diff", "rule_effort", "effort"))
    groups = {}
    for row in rows:
        key = row.get("work_type") or "unclassified"
        group = groups.setdefault(key, dict.fromkeys(counters, 0))
        group["runs"] += 1
        if row.get("rule_worker"):
            group["rule"] += 1
        else:
            group["no_rule_route"] += 1
        if not row.get("chosen_worker"):
            group["no_pick"] += 1
        for den, diff, rule_col, pick_col in compared:
            if row.get(rule_col) and row.get(pick_col):
                group[den] += 1
                if row[pick_col] != row[rule_col]:
                    group[diff] += 1
        group[row.get("confidence_band") or "unknown_band"] += 1
        if row.get("snapshot_stale"):
            group["stale"] += 1
        if key == "none-fit":
            group["none_fit"] += 1
        if row.get("picker_status") == "rejected":
            group["rejected"] += 1
    print("Shadow disagreement report - routing evidence, not outcome labels.")
    print("These rows show what the picker would have chosen; they cannot show how an unrun pick would have performed.")
    print("%-34s %5s %5s %5s %6s %5s %5s %5s %5s %5s %5s %8s %5s %5s %5s"
          % ("work_type", "runs", "rule", "noRte", "noPick", "wDen", "wDiff", "vDen", "vDiff",
             "eDen", "eDiff", "dispatch", "ask", "escal", "stale"))
    totals = dict.fromkeys(counters, 0)
    for key in sorted(groups):
        g = groups[key]
        for name in totals:
            totals[name] += g[name]
        print("%-34s %5d %5d %5d %6d %5d %5d %5d %5d %5d %5d %8d %5d %5d %5d"
              % (key, g["runs"], g["rule"], g["no_rule_route"], g["no_pick"], g["worker_den"],
                 g["worker_diff"], g["validator_den"], g["validator_diff"], g["effort_den"],
                 g["effort_diff"], g["dispatch"], g["ask"], g["escalate"], g["stale"]))
    print("Denominators: worker disagreement over %d rows where both the rule and the picker named "
          "a worker; validator disagreement over %d rows where both named a validator; effort "
          "disagreement over %d rows where both named an effort. %d rows have no picker pick; "
          "%d rows have no rule route."
          % (totals["worker_den"], totals["validator_den"], totals["effort_den"],
             totals["no_pick"], totals["no_rule_route"]))
    print("Bands: dispatch=%d ask=%d escalate=%d unknown=%d; stale snapshots=%d; none-fit=%d; rejected picks=%d."
          % (totals["dispatch"], totals["ask"], totals["escalate"], totals["unknown_band"],
             totals["stale"], totals["none_fit"], totals["rejected"]))
    return 0


def check_routes(data_root, rules_path, bin_dir, table_path):
    table = load_table(table_path)
    if rules_path:
        rules_doc = load_json(rules_path)
    else:
        config_dir = Path(os.environ.get("FM_CONFIG_OVERRIDE")
                          or (Path(os.environ.get("FM_HOME") or os.getcwd()) / "config"))
        rules_file = config_dir / "crew-dispatch.json"
        proc = subprocess.run(
            ["bash", str(Path(bin_dir) / "fm-model-index.sh"), "profiles", str(rules_file)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=dict(os.environ, FM_CONFIG_OVERRIDE=str(config_dir)))
        if proc.returncode != 0:
            warn("could not resolve %s against the model index" % rules_file)
            return 2
        rules_doc = json.loads(proc.stdout.decode("utf-8"))
    routes = routes_from_rules(rules_doc)
    ok = True
    print("route                              family     currency      projection                         asserted")
    for route in sorted(routes):
        entry = table_entry(table, route)
        profile = routes[route]
        if entry is None:
            print("%-34s %-10s %-13s %-34s %s"
                  % (route, "?", "?", "-", "UNMAPPED (stays a candidate with UNKNOWN facts)"))
            ok = False
            continue
        chosen, why = projection_for(entry, profile["effort"])
        if chosen is None:
            print("%-34s %-10s %-13s %-34s %s"
                  % (route, entry.get("family"), entry.get("currency"), "-", "REFUSED: %s" % why))
            ok = False
            continue
        projection, why = asserted_projection(table, entry, chosen, data_root)
        print("%-34s %-10s %-13s %-34s %s"
              % (route, entry.get("family"), entry.get("currency"), chosen["slug"],
                 "yes" if projection is not None else "REFUSED: %s" % why))
        ok = ok and projection is not None
    return 0 if ok else 1


HELP = """usage: fm-model-picker-shadow.sh --observe [options]
       fm-model-picker-shadow.sh --report
       fm-model-picker-shadow.sh --check-routes [--rules PATH]

Observe one dispatch in shadow mode. Never prints or returns a dispatch route.
  --brief PATH       brief file used only for the task join key
  --task-text PATH   sanitized task text already produced by the never-send filter
  --rules PATH       resolved crew-dispatch rules snapshot
  --result PATH      resolver result JSON carrying the rule's chosen profile
  --quota PATH       the resolver's one quota-axi JSON snapshot
  --status STATUS    resolver status (clear, ambiguous, escalate, error, withheld)
  --reason TEXT      a coarse reason, never brief text
  --never-send PATH  never-send policy (default <FM_CONFIG_OVERRIDE or FM_HOME/config>/dispatch-never-send)
  --project NAME     project name
  --hook spawn       launch-path observation: when the resolver logged this task within
                     the last hour from the same brief, consume its marker and set that
                     row's rule route to the launched route instead of writing a row;
                     a stale marker's row is superseded by the launch's own row; a run
                     without it leaves that marker and supersedes the task's earlier
                     resolver row
  --data-root PATH   data root overriding FM_MODEL_PICKER_DATA

The data root is FM_MODEL_PICKER_DATA, else <FM_DATA_OVERRIDE>/model-picker, else
<FM_HOME>/data/model-picker. Exit 0 for every observe run: the dispatch is unchanged
whatever happens here. --check-routes exits 1 when a mapped projection is missing or its
asserted name or creator does not match. --report exits 2 only when the log cannot be read.
Under FM_TEST_SEAM=1 only, --table PATH replaces bin/fm_model_picker/routes.json.
"""


def main(argv):
    action = None
    args = {}
    i = 0
    while i < len(argv):
        token = argv[i]
        if token in ("-h", "--help"):
            print(HELP, end="")
            return 0
        if token == "--observe":
            action = "observe"
        elif token == "--report":
            action = "report"
        elif token == "--check-routes":
            action = "check-routes"
        elif token.startswith("--"):
            if i + 1 >= len(argv):
                warn("flag %s needs a value" % token)
                return 2
            args[token[2:].replace("-", "_")] = argv[i + 1]
            i += 1
        else:
            warn("unexpected argument")
            return 2
        i += 1
    if action is None:
        print(HELP, end="")
        return 2
    if "table" in args and os.environ.get("FM_TEST_SEAM") != "1":
        warn("--table is a test seam honored only under FM_TEST_SEAM=1")
        return 2
    args["table"] = args.get("table") or str(Path(__file__).with_name("routes.json"))
    data_root = args.get("data_root") or resolve_data_root()
    if action == "report":
        return report(data_root)
    if action == "check-routes":
        return check_routes(data_root, args.get("rules"),
                            Path(__file__).resolve().parent.parent, args["table"])
    helper = str(Path(__file__).resolve().parent.parent / "fm-model-picker-jev.sh")
    scratch = tempfile.mkdtemp(prefix="fm-model-picker-shadow.")
    args["scratch"] = scratch
    try:
        return observe(args, read_key(), helper, data_root)
    finally:
        for name in os.listdir(scratch):
            try:
                os.unlink(os.path.join(scratch, name))
            except OSError:
                pass
        try:
            os.rmdir(scratch)
        except OSError:
            pass


def read_key():
    try:
        data = os.read(3, 65536)
        os.close(3)
    except OSError:
        return ""
    return data.decode("utf-8", "replace").strip()


def resolve_data_root():
    explicit = os.environ.get("FM_MODEL_PICKER_DATA")
    if explicit:
        return explicit
    data_dir = os.environ.get("FM_DATA_OVERRIDE")
    if data_dir:
        return os.path.join(data_dir, "model-picker")
    home = os.environ.get("FM_HOME") or os.getcwd()
    return os.path.join(home, "data", "model-picker")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
