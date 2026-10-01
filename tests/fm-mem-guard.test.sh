#!/usr/bin/env bash
# fm-mem-guard.test.sh - Memory/pressure parsing, verdicts, wrapper, and CLI exit semantics.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../bin/fm-mem-guard.py" <<'PY'
import contextlib
import io
import json
import runpy
import subprocess
import sys
from unittest.mock import mock_open, patch

engine = sys.argv[1]


class Output(io.StringIO):
    def reconfigure(self, **kwargs):
        pass


def audit(platform, meminfo="", host="", pressure="", ps="", failure=None,
          thresholds=(), clock=None):
    def native(command, **kwargs):
        if failure == command[0]:
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])
        text = {"/usr/sbin/sysctl": host, "/usr/bin/memory_pressure": pressure,
                "/bin/ps": ps}[command[0]]
        return subprocess.CompletedProcess(command, 0, text, "")

    output = Output()
    with contextlib.ExitStack() as stack:
        stack.enter_context(patch.object(sys, "platform", platform))
        stack.enter_context(patch.object(sys, "argv", [engine, "--json", "--check", *thresholds]))
        stack.enter_context(patch.object(sys, "stdout", output))
        stack.enter_context(patch("builtins.open", mock_open(read_data=meminfo)))
        stack.enter_context(patch("os.listdir", side_effect=PermissionError))
        stack.enter_context(patch("subprocess.run", side_effect=native))
        if clock is not None:
            stack.enter_context(patch("time.monotonic", side_effect=clock))
        code = 0
        try:
            runpy.run_path(engine, run_name="__main__")
        except SystemExit as exc:
            code = exc.code
    return json.loads(output.getvalue()), code


def verdict(result, status, code):
    report, actual_code = result
    assert report["status"] == status, report
    assert actual_code == code, (actual_code, report)
    return report


# Linux fixtures preserve MemAvailable semantics and inclusive threshold boundaries.
linux = "MemTotal: 33554432 kB\nMemAvailable: 16777216 kB\nSwapTotal: 4194304 kB\nSwapFree: 3145728 kB\n"
report = verdict(audit("linux", meminfo=linux), "OK", 0)
assert report["summary"] == {"mem_total_gb": 32.0, "mem_available_gb": 16.0,
                             "mem_used_pct": 50.0, "swap_total_gb": 4.0,
                             "swap_used_gb": 1.0, "swap_used_pct": 25.0}
verdict(audit("linux", meminfo=linux, thresholds=("--warn-mem-pct", "50")), "WARNING", 1)
verdict(audit("linux", meminfo=linux, thresholds=("--crit-mem-pct", "50")), "CRITICAL", 1)
verdict(audit("linux", meminfo=linux, thresholds=("--crit-swap-pct", "25")), "CRITICAL", 1)
report = verdict(audit("linux", meminfo=linux.replace("SwapFree: 3145728 kB\n", "")), "OK", 0)
assert report["summary"]["swap_used_pct"] is None
report = verdict(audit("linux", meminfo="MemTotal: 33554432 kB\n"), "UNKNOWN", 0)
assert report["reason"] == "meminfo-unavailable"
assert all(value is None for value in report["summary"].values())
report = verdict(audit("linux", meminfo="MemTotal: 1024 kB\nMemAvailable: 1024 kB\nSwapTotal: 0 kB\n"), "OK", 0)
assert report["summary"]["swap_used_pct"] == 0.0
print("ok - Linux fixtures, thresholds, incomplete readings, and zero swap")

# Native macOS pressure accounts for reclaimable memory, unlike raw vm_stat free pages.
host = "34359738368\ntotal = 4096.00M  used = 1024.00M  free = 3072.00M  (encrypted)\n"
pressure = "The system has 34359738368 (2097152 pages with a page size of 16384).\nSystem-wide memory free percentage: 50%\n"
ps = " 101 10240 Worker One\n 102 40960 big-worker\n 103 10239 small-worker\nmalformed\n"
report = verdict(audit("darwin", host=host, pressure=pressure, ps=ps), "OK", 0)
assert report["summary"] == {"mem_total_gb": 32.0, "mem_available_gb": 16.0,
                             "mem_used_pct": 50.0, "swap_total_gb": 4.0,
                             "swap_used_gb": 1.0, "swap_used_pct": 25.0}
assert report["top_processes"] == [{"pid": 102, "comm": "big-worker", "rss_mb": 40.0},
                                    {"pid": 101, "comm": "Worker One", "rss_mb": 10.0}]
verdict(audit("darwin", host=host, pressure=pressure.replace("50%", "10%")), "WARNING", 1)
verdict(audit("darwin", host=host, pressure=pressure.replace("50%", "5%")), "CRITICAL", 1)
# An expandable macOS swap pool can be nearly full while native pressure is healthy.
high_swap = "34359738368\ntotal = 1000.00M used = 967.00M free = 33.00M\n"
report = verdict(audit("darwin", host=high_swap, pressure=pressure), "OK", 0)
assert report["summary"]["swap_used_pct"] == 96.7
verdict(audit("darwin", host=high_swap, pressure=pressure,
              thresholds=("--warn-swap-pct", "0", "--crit-swap-pct", "0")), "OK", 0)
for swap in ("total = 4.00G used = 1.00G free = 3.00G", "total = 4194304K used = 1048576K free = 3145728K"):
    report = verdict(audit("darwin", host="34359738368\n" + swap, pressure=pressure), "OK", 0)
    assert report["summary"]["swap_used_pct"] == 25.0
report = verdict(audit("darwin", host="34359738368\ntotal = 0.00M used = 0.00M free = 0.00M", pressure=pressure), "OK", 0)
assert report["summary"]["swap_used_pct"] == 0.0
for bad_swap in ("", "total = 4096.00M used = 1024.00M", "total = 4M used = 5M free = 0M"):
    report = verdict(audit("darwin", host="34359738368\n" + bad_swap, pressure=pressure), "OK", 0)
    assert report["summary"]["swap_used_pct"] is None
print("ok - macOS native pressure, swap units, RSS ordering/cutoff, and verdicts")

# Broken native readings are unknown, not zero utilization or a check failure.
for broken in ("", "System-wide memory free percentage: 101%", "System-wide memory free percentage: nope"):
    report = verdict(audit("darwin", host=host, pressure=broken), "UNKNOWN", 0)
    assert report["reason"] == "macos-memory-unavailable"
    assert all(value is None for value in report["summary"].values())
for failure in ("/usr/sbin/sysctl", "/usr/bin/memory_pressure"):
    verdict(audit("darwin", host=host, pressure=pressure, failure=failure), "UNKNOWN", 0)
report = verdict(audit("darwin", host=host, pressure=pressure, failure="/bin/ps"), "OK", 0)
assert report["top_processes"] == []
# Total command budget exhausted before pressure query; no fabricated verdict.
verdict(audit("darwin", host=host, pressure=pressure, clock=[0.0, 0.0, 0.5, 0.5, 0.5]), "UNKNOWN", 0)
# Slow memory reads cannot starve the top-RSS listing, which has its own budget.
report = verdict(audit("darwin", host=host, pressure=pressure, ps=ps,
                       clock=[0.0, 0.0, 0.1, 0.45, 0.45]), "OK", 0)
assert [p["pid"] for p in report["top_processes"]] == [102, 101], report
report = verdict(audit("freebsd"), "UNKNOWN", 0)
assert report["reason"] == "unsupported-platform"
print("ok - native command failures, deadline exhaustion, and unsupported platform")
PY

# The public wrapper reaches the engine and passes --json/--check through on this host.
pass_args=(--json --check --warn-mem-pct 101 --crit-mem-pct 101 --warn-swap-pct 101 --crit-swap-pct 101)
wrapper_json="$("$SCRIPT_DIR/../bin/fm-mem-guard.sh" "${pass_args[@]}")"
python3 - "$wrapper_json" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
assert report["name"] == "fm-mem-guard", report
assert report["status"] in ("OK", "UNKNOWN"), report
assert (report["reason"] is None) == (report["status"] == "OK"), report
assert isinstance(report["top_processes"], list), report
PY
echo "ok - fm-mem-guard.sh wrapper --json --check exits 0 with a pass verdict"
