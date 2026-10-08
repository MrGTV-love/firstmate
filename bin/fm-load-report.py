#!/usr/bin/env python3
"""
fm-load-report.py - record host load and judge it with pipeline agent durations.

Usage:
  fm-load-report.sh record [--out FILE]
  fm-load-report.sh watch [--interval SECONDS] [--out FILE]
  fm-load-report.sh report [--samples FILE] [--since EPOCH] [--runs N]
                           [--nm-db PATH] [--json]

`record` appends one tab-separated sample line:
  epoch  load1  load5  load15  cpus  pool_size  pool_held
from os.getloadavg(), os.cpu_count() and `fm-cpu-pass.sh status --json`
(pool fields are empty when the pool is unavailable).
`watch` records one sample every --interval seconds (default 60) until it is
stopped; it is the long-running recorder for a measurement window.
The default samples file is FM_LOAD_SAMPLES, else load-samples.tsv in the CPU
pass pool directory (FM_CPU_POOL_DIR, else $HOME/.cache/fm-cpu-pool), so one
host-wide file serves every home.

`report` prints the window's facts and two verdicts:
  - load: sample count, cpus, load1 p50/p95/max, the share of samples above
    2x cpus, and pool use. Verdict load_within_2x_cpus is true when load1 p95
    is at most 2x cpus.
  - pipeline: from the no-mistakes state database (read-only; default
    ~/.no-mistakes/state.sqlite), the first --runs (default 10) eligible runs
    created since --since, ordered oldest first (then by run id for ties).
    Eligible runs have completed, failed or cancelled and reached review, each with
    its review-fix and test-fix round counts, agent minutes, and whether
    it converged: completed successfully with at most 2 review-fix rounds and
    no timeout-class run error (wall-clock limit, WaitDelay, did not reply, timed out);
    per-purpose agent duration p50/p95; agent failures by category; and every
    timeout-class run error in the window. Verdict
    converged_within_2_fix_rounds is true when --runs such runs exist and all
    converged; null when fewer exist. Later-created runs do not change the cohort
    or its verdict once it is full.
--since defaults to the first sample's epoch.

Read-only toward everything except the samples file; no network or model call.
Exit status: 0 on a report or recorded sample, 1 when the samples file or
database cannot be read, 2 for a usage error.
"""

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TIMEOUT_MARKERS = ("wall-clock", "WaitDelay", "did not reply", "timed out")


def default_samples_path() -> str:
    explicit = os.environ.get("FM_LOAD_SAMPLES", "").strip()
    if explicit:
        return explicit
    pool = os.environ.get("FM_CPU_POOL_DIR", "").strip()
    if not pool:
        pool = os.path.join(os.environ.get("HOME", ""), ".cache", "fm-cpu-pool")
    return os.path.join(pool, "load-samples.tsv")


def pool_status() -> Dict[str, Any]:
    try:
        done = subprocess.run(
            [os.path.join(SCRIPT_DIR, "fm-cpu-pass.sh"), "status", "--json"],
            capture_output=True, text=True, timeout=10, check=False)
        return json.loads(done.stdout or "{}")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}


def record(out: str) -> int:
    load1, load5, load15 = os.getloadavg()
    status = pool_status()
    size = status.get("size", "") if status.get("available") else ""
    held = status.get("held", "") if status.get("available") else ""
    line = "%d\t%.2f\t%.2f\t%.2f\t%d\t%s\t%s\n" % (
        int(time.time()), load1, load5, load15, os.cpu_count() or 1, size, held)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "a", encoding="utf-8") as handle:
        handle.write(line)
    return 0


def watch(out: str, interval: float) -> int:
    while True:
        record(out)
        time.sleep(interval)


def percentile(values: List[float], fraction: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round(fraction * (len(ordered) - 1)))))
    return ordered[index]


def read_samples(path: str) -> List[List[str]]:
    rows = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 5 and parts[0].isdigit():
                rows.append(parts)
    return rows


def load_section(rows: List[List[str]], since: int) -> Dict[str, Any]:
    window = [row for row in rows if int(row[0]) >= since]
    if not window:
        return {"samples": 0, "load_within_2x_cpus": None}
    cpus = int(window[-1][4])
    load1 = [float(row[1]) for row in window]
    held = [int(row[6]) for row in window if len(row) > 6 and row[6].isdigit()]
    p95 = percentile(load1, 0.95)
    return {
        "samples": len(window),
        "first": int(window[0][0]),
        "last": int(window[-1][0]),
        "cpus": cpus,
        "load1_p50": percentile(load1, 0.50),
        "load1_p95": p95,
        "load1_max": max(load1),
        "share_above_2x_cpus": round(sum(1 for v in load1 if v > 2 * cpus) / len(load1), 4),
        "pool_held_max": max(held) if held else None,
        "pool_held_mean": round(sum(held) / len(held), 2) if held else None,
        "load_within_2x_cpus": p95 is not None and p95 <= 2 * cpus,
    }


def pipeline_section(db_path: str, since: int, runs: int) -> Dict[str, Any]:
    conn = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=10)
    try:
        cur = conn.cursor()
        run_rows = cur.execute(
            "SELECT id, status, created_at, COALESCE(error, '') FROM runs "
            "WHERE created_at >= ? AND status IN ('completed', 'failed', 'cancelled') AND EXISTS ("
            "SELECT 1 FROM agent_invocations a WHERE a.run_id = runs.id "
            "AND a.purpose = 'review') "
            "ORDER BY created_at ASC, id ASC LIMIT ?", (since, runs)).fetchall()
        cohort = []
        for run_id, status, created_at, error in run_rows:
            purposes = dict(cur.execute(
                "SELECT purpose, COUNT(*) FROM agent_invocations WHERE run_id = ? "
                "GROUP BY purpose", (run_id,)).fetchall())
            minutes = cur.execute(
                "SELECT COALESCE(SUM(duration_ms), 0) FROM agent_invocations WHERE run_id = ?",
                (run_id,)).fetchone()[0] / 60000.0
            review_fix = purposes.get("review-fix", 0)
            timed_out = any(marker in error for marker in TIMEOUT_MARKERS)
            cohort.append({
                "run": run_id,
                "status": status,
                "created_at": created_at,
                "review_fix_rounds": review_fix,
                "test_fix_rounds": purposes.get("test-fix", 0),
                "agent_minutes": round(minutes, 1),
                "timed_out": timed_out,
                "converged": status == "completed" and review_fix <= 2 and not timed_out,
            })
        durations: Dict[str, List[float]] = {}
        for purpose, duration_ms in cur.execute(
                "SELECT purpose, duration_ms FROM agent_invocations WHERE started_at >= ?",
                (since,)):
            durations.setdefault(purpose, []).append(duration_ms / 60000.0)
        by_purpose = {
            purpose: {
                "count": len(values),
                "minutes_p50": round(percentile(values, 0.50) or 0, 1),
                "minutes_p95": round(percentile(values, 0.95) or 0, 1),
            }
            for purpose, values in sorted(durations.items())
        }
        failures = [
            {"exit_status": exit_status, "category": category or "", "count": count}
            for exit_status, category, count in cur.execute(
                "SELECT exit_status, failure_category, COUNT(*) FROM agent_invocations "
                "WHERE started_at >= ? AND exit_status != 'ok' GROUP BY 1, 2 ORDER BY 3 DESC",
                (since,))
        ]
        timeout_errors = []
        for run_id, error in cur.execute(
                "SELECT id, error FROM runs WHERE created_at >= ? AND error IS NOT NULL", (since,)):
            for marker in TIMEOUT_MARKERS:
                if marker in error:
                    timeout_errors.append({"run": run_id, "class": marker})
                    break
    finally:
        conn.close()
    verdict: Optional[bool] = None
    if len(cohort) >= runs:
        verdict = all(item["converged"] for item in cohort)
    return {
        "runs_considered": len(cohort),
        "runs_wanted": runs,
        "cohort_runs": cohort,
        "agent_minutes_by_purpose": by_purpose,
        "agent_failures": failures,
        "timeout_class_run_errors": timeout_errors,
        "converged_within_2_fix_rounds": verdict,
    }


def print_text(report: Dict[str, Any]) -> None:
    load = report["load"]
    print("window since %d" % report["since"])
    if load["samples"]:
        print("load: samples=%d cpus=%d load1 p50=%.1f p95=%.1f max=%.1f share>2x=%.1f%% "
              "pool_held max=%s mean=%s load_within_2x_cpus=%s" % (
                  load["samples"], load["cpus"], load["load1_p50"], load["load1_p95"],
                  load["load1_max"], 100 * load["share_above_2x_cpus"],
                  load["pool_held_max"], load["pool_held_mean"], load["load_within_2x_cpus"]))
    else:
        print("load: no samples in the window")
    pipe = report.get("pipeline")
    if pipe is None:
        print("pipeline: unavailable (%s)" % report.get("pipeline_error", "no database"))
        return
    print("pipeline: first eligible runs=%d of %d converged_within_2_fix_rounds=%s" % (
        pipe["runs_considered"], pipe["runs_wanted"], pipe["converged_within_2_fix_rounds"]))
    for item in pipe["cohort_runs"]:
        print("  run %s %s review_fix=%d test_fix=%d agent_minutes=%.1f converged=%s" % (
            item["run"], item["status"], item["review_fix_rounds"],
            item["test_fix_rounds"], item["agent_minutes"], item["converged"]))
    for purpose, stats in pipe["agent_minutes_by_purpose"].items():
        print("  %s: count=%d minutes p50=%.1f p95=%.1f" % (
            purpose, stats["count"], stats["minutes_p50"], stats["minutes_p95"]))
    for failure in pipe["agent_failures"]:
        print("  agent failure %s/%s: %d" % (
            failure["exit_status"], failure["category"], failure["count"]))
    for item in pipe["timeout_class_run_errors"]:
        print("  timeout-class run error %s: %s" % (item["run"], item["class"]))


def report(args: argparse.Namespace) -> int:
    try:
        rows = read_samples(args.samples)
    except OSError as exc:
        print("cannot read samples %s: %s" % (args.samples, exc), file=sys.stderr)
        return 1
    since = args.since if args.since is not None else (int(rows[0][0]) if rows else 0)
    result: Dict[str, Any] = {"since": since, "load": load_section(rows, since)}
    code = 0
    try:
        result["pipeline"] = pipeline_section(args.nm_db, since, args.runs)
    except sqlite3.Error as exc:
        result["pipeline"] = None
        result["pipeline_error"] = str(exc)
        code = 1
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print_text(result)
    return code


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-load-report.sh",
        description="Record host load and judge it with pipeline agent durations; see the engine header.")
    sub = parser.add_subparsers(dest="action")
    rec = sub.add_parser("record", help="append one load sample")
    rec.add_argument("--out", default=default_samples_path())
    wat = sub.add_parser("watch", help="record a sample every --interval seconds")
    wat.add_argument("--out", default=default_samples_path())
    wat.add_argument("--interval", type=float, default=60.0)
    rep = sub.add_parser("report", help="summarize load and pipeline agents")
    rep.add_argument("--samples", default=default_samples_path())
    rep.add_argument("--since", type=int, default=None)
    rep.add_argument("--runs", type=int, default=10)
    rep.add_argument("--nm-db", default=os.path.join(
        os.environ.get("HOME", ""), ".no-mistakes", "state.sqlite"))
    rep.add_argument("--json", action="store_true")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code == 0 else 2
    if args.action == "record":
        return record(args.out)
    if args.action == "watch":
        if args.interval <= 0:
            print("--interval must be positive", file=sys.stderr)
            return 2
        return watch(args.out, args.interval)
    if args.action == "report":
        if args.runs < 1:
            print("--runs must be at least 1", file=sys.stderr)
            return 2
        return report(args)
    parser.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
