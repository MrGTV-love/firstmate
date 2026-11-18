#!/usr/bin/env python3
"""
fm-mem-guard.py - Local host memory-pressure and top-RSS diagnostic.

No model, API, or network call is made; the guard only reports host readings.
Linux uses /proc/meminfo and /proc/<pid>/{statm,comm}.
macOS uses memory_pressure -Q, sysctl -n hw.memsize vm.swapusage, and ps ucomm.
On macOS MemAvailable is estimated from the native memory-pressure free percentage,
not vm_stat's raw free pages: reclaimable/compressed memory must not be counted
as exhausted RAM. SwapTotal is the currently allocated swap pool, not a fixed cap;
macOS swap occupancy is telemetry only and never classifies pressure, because
the OS can grow that pool. Linux swap utilization still classifies the verdict.

Recorded admission modes (sample, baseline, admit, probe; wrapper also owns run):
  - Admission tests the harm itself: starting work that exhausts host memory
    and makes the host thrash or crash (the 2026-10-09 crash). The kernel
    memory-pressure level is recorded as telemetry and is never an input:
    in the recorded readings it flagged 331 of 3,753 readings at 10.9 to
    39.0 GiB available while readings that were admitted ran down to
    18.2 GiB, so it does not track the bytes. Admit defers with 75 when:
      1. any required memory or process reading is missing or inconsistent
         (a level below 1 is also an unreadable measurement; the legacy
         diagnostic below stays fail-open);
      2. fit: the projected resident size of the run does not fit in
         available memory minus the reserve, where the projection is the
         PROJECTION_QUANTILE (nearest rank) of this host's recorded per-run
         peaks for the run's kind (task or no-mistakes; no kind uses the
         larger of the two), and the reserve is the RESERVE_QUANTILE of the
         recorded drops in available memory between consecutive probe
         readings no further apart than the window;
      3. swap used grew since the last probe reading, or the compressor grew
         by more than the RISE_QUANTILE of its recorded rises.
    Window is the WINDOW_QUANTILE of the recorded gaps between probe readings,
    so a comparison reading older than it is not evidence of a trend. Swap
    growth has no floor: any increase counts, since in the recorded probes
    the positive swap changes split into 3 of at most 14.9 MiB and 9 of at
    least 185.6 MiB with nothing between, and refusing on the 3 costs 0.14%
    of probe steps. Each quantile is a named policy over measured values:
    every byte value and time is derived from this host's own record at the
    moment of the decision, and a missing, short (fewer than 1 / (1 -
    quantile) values, the fewest for which the quantile differs from the
    largest) or other-host record leaves that part not judged and says why in
    the reading's "harm" object; it is never seeded or guessed. The
    measurement of the record held on 2026-11-18 (3,753 readings, 2,213
    probes, 556 runs, one 10-hour swap-growth episode), its script and its
    replay are saved with the change that introduced them (PR body); it
    produced a projection of 8.27 GiB (task) and 10.37 GiB (no-mistakes), a
    reserve of 13.20 GiB, a compressor-rise limit of 6.19 GiB and a window of
    2,325 s, and replayed against the recorded decisions it admitted 160 of
    331 recorded defers and deferred 85 of 3,183 recorded admits (2.67%).
    Peaks are snapshots of a run's resident tree and so are lower bounds.
    Raw free + speculative pages (PhysMem unused), available pages, occupied
    compressor pages, swap, each run's resident tree, each reading's largest
    non-fleet RSS and the largest residents are recorded.
  - Available memory is free plus reclaimable pages: Pages free, File-backed
    pages (the page cache, speculative pages included) and Pages purgeable,
    never compressed or swapped memory.
  - A run is a Firstmate task (paired markers) or a no-mistakes run (kernel
    cwd in its run worktree), with its PPID descendants; fm-proc-info.py owns
    that identity. probe records, in --calibration, each run's largest
    resident-tree sum with its sample count, first/last time, largest gap
    between samples, and samples with unreadable RSS (lower bounds), plus the
    most available memory seen at native pressure 2 or higher. Processes of
    a run outside both identities, such as other users' unreadable RSS, are
    omissions. A different host or RAM size starts a new record.
  - Every reading shows this host's one-run peak (the largest peak of any run
    seen in at least two readings) and headroom margin (the most available
    memory recorded under pressure) derived from that record, or the missing
    inputs. admit never refuses work on them: one pressured sample sets the
    margin until the host or RAM size changes, so admit chooses no statistic
    from them. bin/fm-cpu-pass.py pipeline-start reads the record's
    no-mistakes run peaks as its slack (all of them) and reservation (leaving
    out runs short of CI-ready). No peak or margin is ever seeded or guessed.
  - The non-fleet RSS alarm is separate from admission: a missing, invalid or
    other-host baseline never defers work and is reported as calibration.
    A reading with errors judges neither record.
  - baseline derives that alarm boundary only from the root home's probe
    readings beside the baseline file with no errors, native pressure 1, and
    this host/RAM/fixture. Admission, run, sample and baseline readings never
    count: a confined worker's admission cannot read other users' RSS, so its
    lower maximum would fake spread and lower the episode floor.
    Across those readings the boundary is the largest non-fleet RSS, and the
    record keeps the sample count, time span, smallest per-reading maximum,
    share of RAM, and readings with unreadable RSS (lower bounds). The
    readings must show variation: fewer than two, or maxima that are all
    equal, return that missing input, and a baseline without spread is
    unusable, so the alarm waits for real spread. An alarm episode starts above
    the boundary and holds until the process is at or below the smallest
    per-reading maximum, the low end of the same measured variation. No RSS
    fraction, multiplier, hysteresis, swap cutoff, or unused-memory cutoff is
    guessed. A matching baseline is retained unchanged; an invalid, spreadless
    or other-host baseline is replaced.
  - Readings must cover a known-healthy workload. A process already oversized
    when measured is part of the envelope; it is empirical, not a safe
    allocation bound, and an alarm is an observation, not a leak diagnosis.
  - Every mode appends one JSONL reading to --state. No daemon restart, process
    signal, or work cancellation is performed. The wrapper owns home placement
    and the existing durable wake transport.

Legacy diagnostic thresholds (run --help for defaults):
  - --warn-mem-pct / --crit-mem-pct: percent of total memory not available.
  - --warn-swap-pct / --crit-swap-pct: Linux-only percent of swap capacity in use.

Invariants:
  - Read-only diagnostics, not OOM prevention or an automatic intervention.
  - Missing memory readings yield UNKNOWN, a reason, null summary measurements,
    and a 0 --check exit. Missing swap never classifies the verdict.
  - A failed top-process listing degrades to an empty list.
  - macOS memory reads share a 400ms budget and the ps top-RSS listing has its
    own 400ms budget; unavailable commands/timeouts withhold the affected
    measurement rather than blocking the caller.
  - Status is OK, WARNING, CRITICAL, or UNKNOWN; recommendation is diagnostic
    text for the operator, and a WARNING names the rerun probe without running
    it.
"""

import argparse
import json
import math
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone
from time import monotonic
from typing import Any, Dict, List, Optional

# Named policy quantiles over this host's recorded values; the engine header
# owns what each one derives and why. Nearest rank, as bin/fm-cpu-pass.py ranks.
PROJECTION_QUANTILE = 0.95
RESERVE_QUANTILE = 0.99
RISE_QUANTILE = 0.95
WINDOW_QUANTILE = 0.99
TRAIL_STEPS = 5000  # consecutive probe-to-probe steps kept in the calibration record
RUN_KINDS = ("task", "no-mistakes")


def rank_quantile(values, quantile):
    """Nearest-rank quantile of a nonempty list."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(quantile * len(ordered)) - 1)]


def enough_for(quantile):
    """The fewest values for which the quantile can differ from the largest."""
    return math.ceil(1 / (1 - quantile))


def read_meminfo() -> Dict[str, int]:
    """Reads and parses /proc/meminfo in kB."""
    info: Dict[str, int] = {}
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                parts = line.split(":")
                if len(parts) == 2:
                    key = parts[0].strip()
                    val_parts = parts[1].strip().split()
                    if val_parts and val_parts[0].isdigit():
                        info[key] = int(val_parts[0])
    except Exception:
        pass
    return info


def native_output(command: List[str], deadline: float) -> str:
    """Reads a native utility within the remaining shared budget."""
    remaining = deadline - monotonic()
    if remaining <= 0:
        return ""
    try:
        return subprocess.run(
            command, capture_output=True, text=True, check=True,
            timeout=remaining, env={**os.environ, "LC_ALL": "C"},
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def read_macos_memory(deadline: float) -> Dict[str, int]:
    """Maps native pressure and swap readings to the existing kB metric contract."""
    host = native_output(
        ["/usr/sbin/sysctl", "-n", "hw.memsize", "vm.swapusage"], deadline,
    )
    pressure = native_output(["/usr/bin/memory_pressure", "-Q"], deadline)
    total = re.search(r"^(\d+)$", host, re.MULTILINE)
    free = re.search(r"^System-wide memory free percentage:\s*(\d+)%$", pressure, re.MULTILINE)
    info: Dict[str, int] = {}
    if total and free and int(total[1]) > 0 and 0 <= int(free[1]) <= 100:
        info["MemTotal"] = int(total[1]) // 1024
        info["MemAvailable"] = info["MemTotal"] * int(free[1]) // 100

    swap = re.search(
        r"total\s*=\s*([\d.]+)([KMG])\s+used\s*=\s*([\d.]+)([KMG])"
        r"\s+free\s*=\s*([\d.]+)([KMG])", host,
    )
    if swap:
        try:
            units = {"K": 1, "M": 1024, "G": 1024 * 1024}
            total_kb = float(swap[1]) * units[swap[2]]
            used_kb = float(swap[3]) * units[swap[4]]
            free_kb = float(swap[5]) * units[swap[6]]
            if 0 <= used_kb <= total_kb and 0 <= free_kb <= total_kb:
                info["SwapTotal"] = int(total_kb)
                info["SwapFree"] = int(free_kb)
        except ValueError:
            pass
    return info


def get_macos_rss_processes(top_n: int = 10) -> List[Dict[str, Any]]:
    """Reads ps RSS in KiB within its own budget, applying the Linux listing's cutoff and ordering."""
    procs: List[Dict[str, Any]] = []
    output = native_output(["/bin/ps", "-axo", "pid=,rss=,ucomm="], monotonic() + 0.4)
    for line in output.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        rss_kb = int(parts[1])
        if rss_kb >= 10240:
            procs.append({
                "pid": int(parts[0]), "comm": parts[2].rstrip(),
                "rss_mb": round(rss_kb / 1024.0, 1),
            })
    procs.sort(key=lambda p: p["rss_mb"], reverse=True)
    return procs[:top_n]


def get_top_rss_processes(top_n: int = 10) -> List[Dict[str, Any]]:
    """Inspects /proc to find top memory-consuming processes by RSS; a listing failure degrades to []."""
    procs: List[Dict[str, Any]] = []
    try:
        page_size_kb = os.sysconf("SC_PAGE_SIZE") // 1024
    except Exception:
        return []

    try:
        entries = os.listdir("/proc")
    except Exception:
        return []

    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        try:
            with open(f"/proc/{pid}/statm", "r") as f:
                parts = f.read().strip().split()
            if len(parts) < 2 or not parts[1].isdigit():
                continue
            rss_kb = int(parts[1]) * page_size_kb
            if rss_kb < 10240:  # Skip procs using < 10MB
                continue

            comm = f"pid_{pid}"
            try:
                with open(f"/proc/{pid}/comm", "r", errors="replace") as f:
                    comm = f.read().strip()
            except Exception:
                pass

            procs.append({
                "pid": pid,
                "comm": comm,
                "rss_mb": round(rss_kb / 1024.0, 1),
            })
        except Exception:
            continue

    procs.sort(key=lambda p: p["rss_mb"], reverse=True)
    return procs[:top_n]


def audit_memory(
    warn_mem_pct: float,
    crit_mem_pct: float,
    warn_swap_pct: float,
    crit_swap_pct: float,
) -> Dict[str, Any]:
    """Audits system memory and swap usage, failing open to status UNKNOWN when unmeasurable."""
    if sys.platform == "darwin":
        mem = read_macos_memory(monotonic() + 0.4)
        unavailable_reason = "macos-memory-unavailable"
        unavailable_source = "Native macOS memory-pressure readings are unavailable or incomplete"
    elif sys.platform.startswith("linux"):
        mem = read_meminfo()
        unavailable_reason = "meminfo-unavailable"
        unavailable_source = "/proc/meminfo is unreadable or incomplete"
    else:
        mem = {}
        unavailable_reason = "unsupported-platform"
        unavailable_source = "Memory readings for this platform are unsupported"
    mem_total_kb = mem.get("MemTotal")
    mem_avail_kb = mem.get("MemAvailable")
    swap_total_kb = mem.get("SwapTotal")
    swap_free_kb = mem.get("SwapFree")

    reason: Optional[str] = None
    mem_total_gb: Optional[float] = None
    mem_available_gb: Optional[float] = None
    mem_used_pct: Optional[float] = None
    swap_total_gb: Optional[float] = None
    swap_used_gb: Optional[float] = None
    swap_used_pct: Optional[float] = None

    if mem_total_kb is None or mem_total_kb <= 0 or mem_avail_kb is None:
        status = "UNKNOWN"
        reason = unavailable_reason
        recommendation = (
            f"{unavailable_source} on this host; "
            "the verdict is withheld rather than fabricated."
        )
    else:
        mem_used_kb = max(0, mem_total_kb - mem_avail_kb)
        mem_total_gb = round(mem_total_kb / (1024.0 * 1024.0), 2)
        mem_available_gb = round(mem_avail_kb / (1024.0 * 1024.0), 2)
        mem_used_pct = round((mem_used_kb / mem_total_kb) * 100.0, 1)

        if swap_total_kb is not None:
            swap_total_gb = round(swap_total_kb / (1024.0 * 1024.0), 2)
            if swap_total_kb == 0:
                swap_used_gb = 0.0
                swap_used_pct = 0.0
            elif swap_free_kb is not None:
                swap_used_kb = max(0, swap_total_kb - swap_free_kb)
                swap_used_gb = round(swap_used_kb / (1024.0 * 1024.0), 2)
                swap_used_pct = round((swap_used_kb / swap_total_kb) * 100.0, 1)

        swap_classifies = sys.platform.startswith("linux")
        crit = mem_used_pct >= crit_mem_pct or (
            swap_classifies and swap_used_pct is not None and swap_used_pct >= crit_swap_pct
        )
        warn = mem_used_pct >= warn_mem_pct or (
            swap_classifies and swap_used_pct is not None and swap_used_pct >= warn_swap_pct
        )
        condition = "Native memory pressure" if sys.platform == "darwin" else "Memory or swap utilization"
        if crit:
            status = "CRITICAL"
            recommendation = (
                f"{condition} is at or above a critical threshold; "
                "this host condition can explain worker silence while it holds."
            )
        elif warn:
            status = "WARNING"
            recommendation = (
                f"{condition} is above a warning threshold but below a "
                "critical one; degraded but explained, see the top RSS processes. "
                "Rerun bin/fm-mem-guard.py --json to print the measured pressure "
                "and the verdict the recovery playbook uses."
            )
        else:
            status = "OK"
            recommendation = (
                ("Native memory pressure is within thresholds; swap is telemetry only; "
                 if sys.platform == "darwin" else "Memory and swap utilization are within thresholds; ") +
                "the caller should continue unchanged."
            )

    if sys.platform == "darwin":
        top_procs = get_macos_rss_processes()
    elif sys.platform.startswith("linux"):
        top_procs = get_top_rss_processes()
    else:
        top_procs = []

    return {
        "name": "fm-mem-guard",
        "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": status,
        "recommendation": recommendation,
        "reason": reason,
        "summary": {
            "mem_total_gb": mem_total_gb,
            "mem_available_gb": mem_available_gb,
            "mem_used_pct": mem_used_pct,
            "swap_total_gb": swap_total_gb,
            "swap_used_gb": swap_used_gb,
            "swap_used_pct": swap_used_pct,
        },
        "top_processes": top_procs,
    }


def admission_read(command):
    """Local, read-only native query; admission never wraps work in a timeout."""
    fixture = os.environ.get("FM_MEMORY_FIXTURE_DIR")
    if fixture:
        name = "processes.json" if command[-1] == "memory" else Path(command[0]).name
        return (Path(fixture) / name).read_text()
    return subprocess.run(command, capture_output=True, text=True, check=True,
                          env={**os.environ, "LC_ALL": "C"}).stdout


def admission_sample():
    """Complete native facts, distinct from the legacy diagnostic verdict."""
    report = {"schema": "fm-memory-reading.v1",
              "checked_at": datetime.now(timezone.utc).isoformat(),
              "platform": "darwin" if os.environ.get("FM_MEMORY_FIXTURE_DIR") else sys.platform,
              "host": socket.gethostname(),
              "fixture": os.environ.get("FM_MEMORY_FIXTURE_DIR"), "errors": [], "processes": []}
    if report["platform"] != "darwin":
        report["errors"].append("native admission is supported on macOS only")
        return report
    try:
        host = admission_read(["/usr/sbin/sysctl", "-n", "hw.memsize",
                               "kern.memorystatus_vm_pressure_level", "vm.swapusage"])
        lines = host.splitlines()
        report["total_bytes"] = int(lines[0])
        report["pressure_level"] = int(lines[1])
        if report["pressure_level"] < 1:
            raise ValueError(f"unexpected native pressure level {report['pressure_level']}")
        swap = re.search(r"total\s*=\s*([\d.]+)([KMG])\s+used\s*=\s*([\d.]+)([KMG])"
                         r"\s+free\s*=\s*([\d.]+)([KMG])", host)
        if not swap:
            raise ValueError("incomplete swap reading")
        units = {"K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}
        for name, value, unit in zip(("total", "used", "free"), swap.groups()[::2], swap.groups()[1::2]):
            report[f"swap_{name}_bytes"] = int(float(value) * units[unit])
        vm = admission_read(["/usr/bin/vm_stat"])
        page_size = int(re.search(r"page size of (\d+) bytes", vm)[1])
        def pages(name):
            match = re.search(r"^" + re.escape(name) + r":\s*(\d+)\.", vm, re.MULTILINE)
            if not match:
                raise ValueError(f"missing {name}")
            return int(match[1]) * page_size
        report["page_size_bytes"] = page_size
        report["unused_bytes"] = pages("Pages free") + pages("Pages speculative")
        report["available_bytes"] = pages("Pages free") + pages("File-backed pages") + pages("Pages purgeable")
        report["anonymous_bytes"] = pages("Anonymous pages")
        report["compressor_bytes"] = pages("Pages occupied by compressor")
        if (report["total_bytes"] <= 0 or page_size <= 0 or
                any(report[key] > report["total_bytes"] for key in
                    ("unused_bytes", "available_bytes", "anonymous_bytes", "compressor_bytes")) or
                report["swap_used_bytes"] > report["swap_total_bytes"] or
                report["swap_free_bytes"] > report["swap_total_bytes"]):
            raise ValueError("inconsistent native memory sizes")
    except (OSError, subprocess.SubprocessError, ValueError, IndexError, TypeError) as exc:
        report["errors"].append(f"memory: {exc}")
    try:
        rows = json.loads(admission_read([sys.executable, str(Path(__file__).with_name("fm-proc-info.py")), "memory"]))
        if not isinstance(rows, list) or any(
                not isinstance(p, dict) or type(p.get("pid")) is not int or p["pid"] <= 0 or
                type(p.get("ppid")) is not int or p["ppid"] < 0 or
                not isinstance(p.get("comm"), str) or not isinstance(p.get("started"), str) or
                type(p.get("fleet")) is not bool or "rss_bytes" not in p or
                "run" not in p or not (p["run"] is None or isinstance(p["run"], str)) or
                (p["rss_bytes"] is not None and
                 (type(p["rss_bytes"]) is not int or p["rss_bytes"] < 0)) for p in rows):
            raise ValueError("invalid process census")
        # Ownership propagates by PPID, not executable names or string matches
        # against unrelated node/python commands.
        owned = {p["pid"] for p in rows if p["fleet"]}
        while True:
            children = {p["pid"] for p in rows if p["ppid"] in owned}
            if children <= owned:
                break
            owned |= children
        by_pid = {p["pid"]: p for p in rows}
        inherited = True
        while inherited:
            inherited = False
            for row in rows:
                parent = by_pid.get(row["ppid"])
                if row["run"] is None and parent is not None and parent["run"] is not None:
                    row["run"], inherited = parent["run"], True
        runs = {}
        for row in rows:
            row["fleet"] = row["pid"] in owned
            if row["run"] is not None:
                run = runs.setdefault(row["run"], {"rss_bytes": 0, "processes": 0, "unreadable": 0})
                run["processes"] += 1
                if row["rss_bytes"] is None:
                    run["unreadable"] += 1
                else:
                    run["rss_bytes"] += row["rss_bytes"]
        report["processes"] = rows
        report["runs"] = runs
        report["rss_unreadable_pids"] = [p["pid"] for p in rows if p["rss_bytes"] is None]
        if not any(p["rss_bytes"] is not None for p in rows):
            raise ValueError("no resident processes readable")
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as exc:
        report["errors"].append(f"processes: {exc}")
    return report


def host_record(path, report, label, schema, fields):
    """A per-host measured record, or why it does not apply to this reading."""
    if report["errors"]:
        return None, "not judged: this reading has errors"
    try:
        loaded = json.loads(path.read_text())
        if (loaded["schema"] != schema or not isinstance(loaded["host"], str) or
                type(loaded["total_bytes"]) is not int or loaded["total_bytes"] <= 0 or
                any(type(loaded[f]) is not int or not 0 < loaded[f] <= loaded["total_bytes"] for f in fields)):
            raise ValueError(f"invalid {label} fields")
        if loaded["host"] != report["host"] or loaded["total_bytes"] != report["total_bytes"]:
            raise ValueError(f"recorded for host {loaded['host']} with {loaded['total_bytes']} bytes, "
                             f"not host {report['host']} with {report['total_bytes']} bytes")
        return loaded, None
    except FileNotFoundError:
        return None, f"no {label} at {path}"
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return None, f"{label} {path} unusable: {exc}"


def calibration_record(path, report):
    """Fold one complete probe reading into this host's measured run and pressure record."""
    now = report["checked_at"]

    def fold(calibration):
        for name, run in report["runs"].items():
            record = calibration["runs"].setdefault(name, {
                "peak_bytes": 0, "samples": 0, "incomplete_samples": 0,
                "first_seen": now, "last_seen": now, "max_gap_seconds": 0})
            gap = (datetime.fromisoformat(now) - datetime.fromisoformat(record["last_seen"])).total_seconds()
            record.update(peak_bytes=max(record["peak_bytes"], run["rss_bytes"]), samples=record["samples"] + 1,
                          incomplete_samples=record["incomplete_samples"] + (run["unreadable"] > 0),
                          last_seen=now, max_gap_seconds=max(record["max_gap_seconds"], gap))
        if report["pressure_level"] >= 2:
            pressured = calibration["pressured"] or {"max_available_bytes": 0, "samples": 0,
                                                     "highest_level": 0, "first_seen": now}
            pressured.update(max_available_bytes=max(pressured["max_available_bytes"], report["available_bytes"]),
                             samples=pressured["samples"] + 1, last_seen=now,
                             highest_level=max(pressured["highest_level"], report["pressure_level"]))
            calibration["pressured"] = pressured
        fold_trail(calibration, report)
        return calibration

    fresh = {"schema": "fm-memory-calibration.v1", "host": report["host"],
             "total_bytes": report["total_bytes"], "runs": {}, "pressured": None}
    calibration, _ = host_record(path, report, "calibration", "fm-memory-calibration.v1", ())
    try:
        calibration = fold(calibration or fresh)
    except (KeyError, TypeError, ValueError, AttributeError):
        calibration = fold(fresh)
    temp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    temp.write_text(json.dumps(calibration))
    os.replace(temp, path)


def fold_trail(calibration, report):
    """Append one probe-to-probe step (seconds apart, available drop, compressor change, swap change)."""
    trail = calibration.get("trail")
    if not (isinstance(trail, dict) and isinstance(trail.get("steps"), list)):
        trail = {"last": None, "steps": []}
    last = trail.get("last")
    now = {"at": report["checked_at"], "available_bytes": report["available_bytes"],
           "compressor_bytes": report["compressor_bytes"], "swap_used_bytes": report["swap_used_bytes"]}
    if isinstance(last, dict):
        try:
            gap = (datetime.fromisoformat(now["at"]) - datetime.fromisoformat(last["at"])).total_seconds()
            if gap > 0:
                trail["steps"].append([int(gap), last["available_bytes"] - now["available_bytes"],
                                       now["compressor_bytes"] - last["compressor_bytes"],
                                       now["swap_used_bytes"] - last["swap_used_bytes"]])
        except (KeyError, TypeError, ValueError):
            pass
    trail["steps"] = trail["steps"][-TRAIL_STEPS:]
    trail["last"] = now
    calibration["trail"] = trail


def projected_rss(calibration, kind):
    """(bytes, qualifying runs, kind) of the PROJECTION_QUANTILE of recorded run peaks, or (None, 0, why)."""
    kinds = (kind,) if kind else RUN_KINDS
    best = None
    notes = []
    for name in kinds:
        peaks = [run["peak_bytes"] for run_name, run in calibration["runs"].items()
                 if run_name.split(":", 1)[0] == name and type(run.get("samples")) is int and run["samples"] >= 2
                 and type(run.get("peak_bytes")) is int and run["peak_bytes"] > 0]
        if len(peaks) < enough_for(PROJECTION_QUANTILE):
            notes.append(f"{len(peaks)} recorded {name} runs seen in at least two readings; "
                         f"{enough_for(PROJECTION_QUANTILE)} are needed")
            continue
        value = rank_quantile(peaks, PROJECTION_QUANTILE)
        if best is None or value > best[0]:
            best = (value, len(peaks), name)
    if best is None:
        return None, 0, "; ".join(notes)
    return best


def trail_limits(calibration):
    """The reserve, compressor-rise limit and window from the recorded steps, or (None, why)."""
    trail = calibration.get("trail")
    if trail is None:
        return None, "no probe step record yet; the root home's probe has not folded one"
    try:
        steps = [list(step) for step in trail["steps"]]
        if any(len(step) != 4 or any(type(n) is not int for n in step) for step in steps):
            raise ValueError("a step is not four integers")
    except (KeyError, TypeError, ValueError) as exc:
        return None, f"no usable step record in the calibration ({exc})"
    if len(steps) < enough_for(WINDOW_QUANTILE):
        return None, f"{len(steps)} recorded probe steps; {enough_for(WINDOW_QUANTILE)} are needed"
    window = rank_quantile([step[0] for step in steps], WINDOW_QUANTILE)
    inside = [step for step in steps if step[0] <= window]
    drops = [step[1] for step in inside if step[1] > 0]
    rises = [step[2] for step in inside if step[2] > 0]
    limits = {"window_seconds": window, "steps": len(inside)}
    notes = []
    if len(drops) < enough_for(RESERVE_QUANTILE):
        notes.append(f"{len(drops)} recorded drops in available memory; {enough_for(RESERVE_QUANTILE)} are needed")
    else:
        limits.update(reserve_bytes=rank_quantile(drops, RESERVE_QUANTILE), drops=len(drops))
    if len(rises) < enough_for(RISE_QUANTILE):
        notes.append(f"{len(rises)} recorded compressor rises; {enough_for(RISE_QUANTILE)} are needed")
    else:
        limits.update(compressor_rise_bytes=rank_quantile(rises, RISE_QUANTILE), rises=len(rises))
    return limits, "; ".join(notes) or None


def harm_evaluate(report, calibration, fit, kind):
    """Reasons to defer from the harm itself, and the numbers and unjudged parts behind them."""
    record, missing = calibration
    gib = 1024 ** 3
    detail = {"kind": kind, "not_judged": []}
    reasons = []
    if record is None:
        detail["not_judged"].append(f"fit, swap and compressor: {missing}")
        return reasons, detail
    limits, why = trail_limits(record)
    if limits is None:
        detail["not_judged"].append(f"reserve, swap and compressor: {why}")
        limits = {}
    elif why:
        detail["not_judged"].append(why)
    detail.update({key: limits[key] for key in ("window_seconds", "reserve_bytes", "compressor_rise_bytes")
                   if key in limits})
    if fit:
        projected, runs, name = projected_rss(record, kind)
        if projected is None:
            detail["not_judged"].append(f"fit: {name}")
        elif "reserve_bytes" not in limits:
            detail["not_judged"].append("fit: no reserve")
        else:
            detail.update(projected_bytes=projected, projection_runs=runs, projected_kind=name)
            room = report["available_bytes"] - limits["reserve_bytes"]
            if projected > room:
                reasons.append(
                    f"projected {name} run of {projected / gib:.2f} GiB (p{PROJECTION_QUANTILE * 100:g} of {runs} "
                    f"recorded) does not fit in {report['available_bytes'] / gib:.2f} GiB available minus a "
                    f"{limits['reserve_bytes'] / gib:.2f} GiB reserve (p{RESERVE_QUANTILE * 100:g} of recorded drops)")
    last = (record.get("trail") or {}).get("last") if isinstance(record.get("trail"), dict) else None
    try:
        gap = (datetime.fromisoformat(report["checked_at"]) - datetime.fromisoformat(last["at"])).total_seconds()
        swap_delta = report["swap_used_bytes"] - last["swap_used_bytes"]
        compressor_delta = report["compressor_bytes"] - last["compressor_bytes"]
        if type(swap_delta) is not int or type(compressor_delta) is not int:
            raise TypeError("sizes are not integers")
    except (KeyError, TypeError, ValueError):
        detail["not_judged"].append("swap and compressor trend: no usable previous probe reading")
        return reasons, detail
    if "window_seconds" not in limits:
        return reasons, detail
    if not 0 <= gap <= limits["window_seconds"]:
        detail["not_judged"].append(
            f"swap and compressor trend: the previous probe reading is {gap:.0f} s old, outside the "
            f"{limits['window_seconds']} s window")
        return reasons, detail
    detail.update(compared_at=last["at"], swap_delta_bytes=swap_delta, compressor_delta_bytes=compressor_delta)
    if swap_delta > 0:
        reasons.append(f"swap used grew by {swap_delta / gib:.3f} GiB in the {gap:.0f} s since the last probe reading")
    rise = limits.get("compressor_rise_bytes")
    if rise is not None and compressor_delta > rise:
        reasons.append(
            f"compressor grew by {compressor_delta / gib:.2f} GiB in the {gap:.0f} s since the last probe reading, "
            f"above the {rise / gib:.2f} GiB p{RISE_QUANTILE * 100:g} of recorded rises")
    return reasons, detail


def headroom_derive(path, report):
    """This host's one-run peak and headroom margin from recorded runs, or the missing inputs."""
    calibration, missing = host_record(path, report, "calibration", "fm-memory-calibration.v1", ())
    if calibration is None:
        return None, missing
    try:
        runs = {name: run for name, run in calibration["runs"].items()
                if type(run["samples"]) is int and run["samples"] >= 2 and type(run["peak_bytes"]) is int}
        pressured = calibration["pressured"]
        missing = [text for text, absent in (
            ("no run has been recorded in at least two readings", not runs),
            ("no reading at native pressure 2 or higher has been recorded", pressured is None)) if absent]
        if missing:
            return None, f"calibration {path}: " + "; ".join(missing)
        name, run = max(runs.items(), key=lambda item: item[1]["peak_bytes"])
        return {"run_peak_bytes": run["peak_bytes"], "run": name, "run_samples": run["samples"],
                "run_incomplete_samples": run["incomplete_samples"], "runs_measured": len(runs),
                "headroom_bytes": pressured["max_available_bytes"],
                "pressured_samples": pressured["samples"]}, None
    except (KeyError, TypeError, AttributeError) as exc:
        return None, f"calibration {path} unusable: {exc}"


def admission_evaluate(report, baseline, calibration=None, fit=True, kind=None):
    """Unreadable facts and the harm itself defer new work; the pressure level, recorded margin and RSS alarm never do.

    calibration is (record, why-missing) as host_record returns it; without it the harm is not judged,
    and fit=False judges the swap and compressor trend only, for a caller that owns its own fit.
    """
    reasons = list(report["errors"])
    if calibration is not None and not reasons:
        harm_reasons, report["harm"] = harm_evaluate(report, calibration, fit, kind)
        reasons += harm_reasons
    alarms, hold = [], []
    if baseline is not None:
        for p in report["processes"]:
            if p["fleet"] or p["rss_bytes"] is None:
                continue
            if p["rss_bytes"] > baseline["non_fleet_max_bytes"]:
                alarms.append({**p, "boundary_bytes": baseline["non_fleet_max_bytes"], "samples": baseline["samples"]})
            if p["rss_bytes"] > baseline["smallest_reading_max_bytes"]:
                hold.append(p["comm"])
    return reasons, alarms, sorted(set(hold))


def baseline_derive(report, readings_path):
    """Observed non-fleet envelope across recorded healthy root probe readings, or the missing input."""
    def healthy(row):
        return (row.get("source") == "probe" and not row.get("errors") and row.get("pressure_level") == 1 and
                row.get("host") == report["host"] and row.get("total_bytes") == report["total_bytes"] and
                row.get("fixture") == report["fixture"] and type(row.get("non_fleet_max_bytes")) is int)
    rows = []
    if readings_path.exists():
        for line in readings_path.read_text().splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and healthy(row):
                rows.append(row)
    if len(rows) < 2:
        return None, (f"baseline needs at least two probe readings with no errors, native pressure 1, a "
                      f"readable non-fleet RSS and this host/RAM; {readings_path} has {len(rows)}")
    maxima = [row["non_fleet_max_bytes"] for row in rows]
    if min(maxima) == max(maxima):
        return None, (f"baseline needs healthy probe readings whose largest non-fleet RSS varies; all "
                      f"{len(rows)} in {readings_path} show {maxima[0]} bytes")
    return {"schema": "fm-memory-baseline.v1", "checked_at": report["checked_at"],
            "host": report["host"], "total_bytes": report["total_bytes"],
            "non_fleet_max_bytes": max(maxima), "non_fleet_max_share": max(maxima) / report["total_bytes"],
            "smallest_reading_max_bytes": min(maxima), "samples": len(rows),
            "first_checked_at": min(row["checked_at"] for row in rows),
            "last_checked_at": max(row["checked_at"] for row in rows),
            "incomplete_samples": sum(1 for row in rows if row.get("rss_unreadable_pids")),
            "derivation": "largest non-fleet RSS observed across recorded healthy root probe readings; "
                          "incomplete samples are lower bounds"}, None


def admission_main(argv):
    parser = argparse.ArgumentParser(description="Recorded macOS admission; never stops running work")
    parser.add_argument("mode", choices=("sample", "admit", "probe", "baseline"))
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--calibration", type=Path, required=True)
    parser.add_argument("--kind", choices=RUN_KINDS,
                        help="the kind of run being admitted; omitted, fit uses the larger kind's projection")
    args = parser.parse_args(argv)
    report = admission_sample()
    report["source"] = args.mode
    candidates = [p["rss_bytes"] for p in report["processes"] if not p["fleet"] and p["rss_bytes"] is not None]
    report["non_fleet_max_bytes"] = max(candidates) if candidates else None
    state = args.state
    state.mkdir(parents=True, exist_ok=True)
    # The decision reads the record as it stood before this probe folds into it,
    # so the previous probe reading is what the trend compares against.
    recorded = host_record(args.calibration, report, "calibration", "fm-memory-calibration.v1", ())
    if args.mode == "probe" and not report["errors"]:
        calibration_record(args.calibration, report)
    baseline, calibration = host_record(args.baseline, report, "baseline", "fm-memory-baseline.v1",
                                        ("non_fleet_max_bytes", "smallest_reading_max_bytes", "samples"))
    if baseline is not None and baseline["smallest_reading_max_bytes"] >= baseline["non_fleet_max_bytes"]:
        baseline, calibration = None, f"baseline {args.baseline} unusable: its readings show no spread"
    headroom, headroom_calibration = headroom_derive(args.calibration, report)
    reasons, alarms, hold = admission_evaluate(report, baseline, calibration=recorded, kind=args.kind)
    # Only an explicit baseline operation writes the envelope; a matching one is
    # never silently re-learned, so a growing process cannot hide in it.
    if args.mode == "baseline" and not reasons:
        if baseline is not None:
            reasons.append("baseline already exists for this host; retained unchanged")
        else:
            derived, missing = baseline_derive(report, args.baseline.with_name("memory-readings.jsonl"))
            if missing:
                reasons.append(missing)
            else:
                temp = args.baseline.with_name(f"{args.baseline.name}.tmp.{os.getpid()}")
                temp.write_text(json.dumps(derived))
                os.replace(temp, args.baseline)
                baseline, calibration = derived, None
    report["baseline"] = baseline
    report["calibration"] = calibration
    report["headroom"] = headroom
    report["headroom_calibration"] = headroom_calibration
    report.setdefault("harm", None)
    report["admission"] = "defer" if reasons else "admit"
    report["reasons"] = reasons
    report["alarms"] = alarms
    report["alarm_hold"] = hold
    report["top_processes"] = sorted((p for p in report["processes"] if p["rss_bytes"] is not None),
                                     key=lambda p: p["rss_bytes"], reverse=True)[:10]
    del report["processes"]
    payload = (json.dumps(report, ensure_ascii=True) + "\n").encode()
    # One append syscall per reading keeps concurrent starts' JSONL rows intact.
    fd = os.open(state / "memory-readings.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        if os.write(fd, payload) != len(payload):
            raise OSError("short memory reading append")
    finally:
        os.close(fd)
    print(payload.decode(), end="")
    return 75 if reasons and args.mode in ("admit", "baseline") else 0


def main():
    sys.stdout.reconfigure(errors="replace")
    if len(sys.argv) > 1 and sys.argv[1] in ("sample", "admit", "probe", "baseline"):
        try:
            sys.exit(admission_main(sys.argv[1:]))
        except (OSError, ValueError, KeyError, TypeError) as exc:
            print(f"memory admission unreadable: {exc}", file=sys.stderr)
            sys.exit(75)
    parser = argparse.ArgumentParser(
        description="Local host memory-pressure and top-RSS diagnostic (Linux and macOS; no API calls)"
    )
    parser.add_argument(
        "--warn-mem-pct",
        type=float,
        default=90.0,
        help="Warning threshold for memory utilization %% (default: %(default)s)",
    )
    parser.add_argument(
        "--crit-mem-pct",
        type=float,
        default=95.0,
        help="Critical threshold for memory utilization %% (default: %(default)s)",
    )
    parser.add_argument(
        "--warn-swap-pct",
        type=float,
        default=85.0,
        help="Linux-only warning threshold for swap utilization %% (default: %(default)s)",
    )
    parser.add_argument(
        "--crit-swap-pct",
        type=float,
        default=95.0,
        help="Linux-only critical threshold for swap utilization %% (default: %(default)s)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 0 for OK or unknown (fail-open), exit 1 for WARNING or CRITICAL",
    )

    args = parser.parse_args()
    report = audit_memory(
        warn_mem_pct=args.warn_mem_pct,
        crit_mem_pct=args.crit_mem_pct,
        warn_swap_pct=args.warn_swap_pct,
        crit_swap_pct=args.crit_swap_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"{report['name']} — {report['checked_at']}")
        if s["mem_used_pct"] is None:
            print("  • RAM: unavailable")
        else:
            print(f"  • RAM: {s['mem_used_pct']}% used ({s['mem_available_gb']} GB available / {s['mem_total_gb']} GB total)")
        if s["swap_used_pct"] is None:
            print("  • Swap: unknown (not measurable)")
        else:
            print(f"  • Swap: {s['swap_used_pct']}% used ({s['swap_used_gb']} GB used / {s['swap_total_gb']} GB total)")
        print(f"  • Status: {report['status']}")
        print(f"  • Recommendation: {report['recommendation']}")
        if report["top_processes"]:
            print(f"\n  Top {len(report['top_processes'])} RSS Processes:")
            for p in report["top_processes"]:
                print(f"    - PID {p['pid']} ({p['comm']}): {p['rss_mb']} MB")

    if args.check and report["status"] in ("WARNING", "CRITICAL"):
        sys.exit(1)


if __name__ == "__main__":
    main()
