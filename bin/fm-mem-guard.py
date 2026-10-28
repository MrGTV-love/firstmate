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
  - macOS native pressure level 1 is normal; any other measured level defers.
    A missing required memory or process reading also defers with 75, while
    the legacy diagnostic remains fail-open. Raw free + speculative pages
    (PhysMem unused), occupied compressor pages, swap, each reading's largest
    non-fleet RSS and the largest residents are recorded for later thresholds.
  - The non-fleet RSS alarm is separate from admission: a missing, invalid or
    other-host baseline never defers work and is reported as calibration.
  - baseline derives that alarm boundary from every recorded reading beside the
    baseline file with no errors, native pressure 1, and this host/RAM/fixture:
    the boundary is the largest non-fleet RSS observed across them, and the
    record keeps the sample count, time span, smallest per-reading maximum,
    share of RAM, and readings with unreadable RSS (lower bounds). At least two
    such readings are required to observe any variation; fewer returns that
    missing input. No RSS fraction, headroom, multiplier, swap cutoff, or
    unused-memory cutoff is guessed. A matching baseline is retained unchanged;
    an invalid or other-host baseline is replaced by the new derivation.
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
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone
from time import monotonic
from typing import Any, Dict, List, Optional


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
        report["anonymous_bytes"] = pages("Anonymous pages")
        report["compressor_bytes"] = pages("Pages occupied by compressor")
        if (report["total_bytes"] <= 0 or page_size <= 0 or
                any(report[key] > report["total_bytes"] for key in
                    ("unused_bytes", "anonymous_bytes", "compressor_bytes")) or
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
        for row in rows:
            row["fleet"] = row["pid"] in owned
        report["processes"] = rows
        report["rss_unreadable_pids"] = [p["pid"] for p in rows if p["rss_bytes"] is None]
        if not any(p["rss_bytes"] is not None for p in rows):
            raise ValueError("no resident processes readable")
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as exc:
        report["errors"].append(f"processes: {exc}")
    return report


def admission_evaluate(report, baseline):
    """Native pressure or unreadable facts defer new work; the RSS alarm never does."""
    reasons = list(report["errors"])
    if report.get("pressure_level") not in (None, 1):
        reasons.append(f"native memory pressure level {report['pressure_level']} (normal is 1)")
    alarms = []
    if baseline is not None:
        alarms = [{**p, "boundary_bytes": baseline["non_fleet_max_bytes"], "samples": baseline["samples"]}
                  for p in report["processes"] if not p["fleet"] and p["rss_bytes"] is not None and
                  p["rss_bytes"] > baseline["non_fleet_max_bytes"]]
    return reasons, alarms


def baseline_derive(report, readings_path):
    """Observed non-fleet envelope across recorded healthy readings, or the missing input."""
    def healthy(row):
        return (not row.get("errors") and row.get("pressure_level") == 1 and
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
    if healthy(report):
        rows.append(report)
    if len(rows) < 2:
        return None, (f"baseline needs at least two readings with no errors, native pressure 1, a readable "
                      f"non-fleet RSS and this host/RAM; {readings_path} plus this reading has {len(rows)}")
    maxima = [row["non_fleet_max_bytes"] for row in rows]
    return {"schema": "fm-memory-baseline.v1", "checked_at": report["checked_at"],
            "host": report["host"], "total_bytes": report["total_bytes"],
            "non_fleet_max_bytes": max(maxima), "non_fleet_max_share": max(maxima) / report["total_bytes"],
            "smallest_reading_max_bytes": min(maxima), "samples": len(rows),
            "first_checked_at": min(row["checked_at"] for row in rows),
            "last_checked_at": max(row["checked_at"] for row in rows),
            "incomplete_samples": sum(1 for row in rows if row.get("rss_unreadable_pids")),
            "derivation": "largest non-fleet RSS observed across recorded healthy readings; "
                          "incomplete samples are lower bounds"}, None


def admission_main(argv):
    parser = argparse.ArgumentParser(description="Recorded macOS admission; never stops running work")
    parser.add_argument("mode", choices=("sample", "admit", "probe", "baseline"))
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    args = parser.parse_args(argv)
    report = admission_sample()
    report["source"] = args.mode
    candidates = [p["rss_bytes"] for p in report["processes"] if not p["fleet"] and p["rss_bytes"] is not None]
    report["non_fleet_max_bytes"] = max(candidates) if candidates else None
    state = args.state
    state.mkdir(parents=True, exist_ok=True)
    baseline, calibration = None, None
    try:
        loaded = json.loads(args.baseline.read_text())
        if (loaded["schema"] != "fm-memory-baseline.v1" or not isinstance(loaded["host"], str) or
                type(loaded["total_bytes"]) is not int or loaded["total_bytes"] <= 0 or
                type(loaded["non_fleet_max_bytes"]) is not int or
                not 0 < loaded["non_fleet_max_bytes"] <= loaded["total_bytes"] or
                type(loaded["samples"]) is not int or loaded["samples"] < 2):
            raise ValueError("invalid baseline fields")
        if loaded["host"] != report["host"] or loaded["total_bytes"] != report.get("total_bytes"):
            raise ValueError(f"recorded for host {loaded['host']} with {loaded['total_bytes']} bytes, "
                             f"not host {report['host']} with {report.get('total_bytes')} bytes")
        baseline = loaded
    except FileNotFoundError:
        calibration = f"no baseline at {args.baseline}"
    except (OSError, ValueError, KeyError, TypeError) as exc:
        calibration = f"baseline {args.baseline} unusable: {exc}"
    reasons, alarms = admission_evaluate(report, baseline)
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
    report["admission"] = "defer" if reasons else "admit"
    report["reasons"] = reasons
    report["alarms"] = alarms
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
