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

Thresholds (run --help for defaults):
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
    text for the operator, never a command.
"""

import argparse
import json
import os
import re
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
                "pid": int(parts[0]), "comm": parts[2],
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
                "critical one; degraded but explained, see the top RSS processes."
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


def main():
    sys.stdout.reconfigure(errors="replace")
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
