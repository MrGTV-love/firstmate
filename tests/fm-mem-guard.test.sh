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
report = verdict(audit("linux", meminfo=linux, thresholds=("--warn-mem-pct", "50")), "WARNING", 1)
assert "bin/fm-mem-guard.py --json" in report["recommendation"], report
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
ps = " 101 10240 Worker One      \n 102 40960 big-worker      \n 103 10239 small-worker\nmalformed\n"
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

# Exercise the real shell entrypoint, append-only records, and existing wake
# queue with native-command fixtures. Existing work is a real live child.
python3 - "$SCRIPT_DIR/../bin/fm-mem-guard.sh" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

wrapper = str(Path(sys.argv[1]).resolve())
gib = 1024 ** 3
if sys.platform == "darwin":
    with tempfile.TemporaryDirectory(prefix="fm-memory-ownership-") as temp:
        fleet_home = (Path(temp)/"home").resolve()
        outside = (Path(temp)/"home-unrelated").resolve()
        fleet_home.mkdir(); outside.mkdir()
        clean = dict(os.environ)
        for key in ("FM_TASK_ID", "FM_TASK_INBOX", "FM_MEMORY_FLEET_ROOT"):
            clean.pop(key,None)
        children = []
        try:
            for cwd, extra in ((fleet_home,{}),(outside,{}),
                    (outside,{"FM_TASK_ID":"owned", "FM_TASK_INBOX":str(fleet_home/"state/owned.inbox")})):
                children.append(subprocess.Popen([sys.executable,"-c","import time; time.sleep(120)"],
                                                cwd=cwd,env={**clean,**extra}))
            result = subprocess.run([sys.executable,str(Path(wrapper).with_name("fm-proc-info.py")),"memory"],
                                    capture_output=True,text=True,check=True,
                                    env={**clean,"FM_MEMORY_FLEET_ROOT":str(fleet_home)})
            by_pid = {row["pid"]:row for row in json.loads(result.stdout)}
            assert [by_pid[child.pid]["fleet"] for child in children] == [True,False,True], by_pid
            assert all("cwd" not in by_pid[child.pid] for child in children)
            print("ok - actual native census independently attributes kernel home cwd and paired markers without claiming a sibling-prefix process")
        finally:
            for child in children:
                child.terminate(); child.wait()
else:
    print("skip - native kernel fleet attribution requires macOS; portable alarm/ancestry fixtures still run")
with tempfile.TemporaryDirectory(prefix="fm-memory-admission-") as temp:
    home = Path(temp)
    fixture = home / "native"
    fixture.mkdir()
    env = {**os.environ, "FM_HOME":str(home), "FM_ROOT_OVERRIDE":"",
           "FM_STATE_OVERRIDE":"", "FM_MEMORY_FIXTURE_DIR":str(fixture)}
    state = home / "state"
    daemon = {"pid":101, "ppid":1, "comm":"xprotectd", "started":"start-101",
              "rss_bytes":gib, "fleet":False}
    fleet = {"pid":201, "ppid":1, "comm":"node", "started":"start-201",
             "rss_bytes":6*gib, "fleet":True}
    child = {"pid":202, "ppid":201, "comm":"python3", "started":"start-202",
             "rss_bytes":5*gib, "fleet":False}

    def facts(pressure=1, rss=None):
        (fixture / "sysctl").write_text(f"{32*gib}\n{pressure}\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n")
        (fixture / "vm_stat").write_text(
            "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
            "Pages free: 1000.\nPages speculative: 100.\n"
            "Anonymous pages: 1048576.\nPages occupied by compressor: 32768.\n")
        rows = [dict(daemon), dict(fleet), dict(child)] if rss is None else rss
        (fixture / "processes.json").write_text(json.dumps(rows))

    def call(mode, *args, code=0, environ=None):
        result = subprocess.run(["bash",wrapper,mode,*args],capture_output=True,text=True,env=environ or env)
        assert result.returncode == code, (mode,result.returncode,result.stdout,result.stderr)
        return json.loads(result.stdout) if result.stdout else None

    def queue():
        return (state / ".wake-queue").read_text()

    facts()
    report = call("baseline",code=75)
    assert any("at least two readings" in r and "has 1" in r for r in report["reasons"]), report
    assert not (state / ".memory-baseline.json").exists()
    report = call("admit")
    assert report["admission"] == "admit" and report["baseline"] is None
    assert "no baseline" in report["calibration"], report
    assert "alarm is uncalibrated" in queue() and "admission is unaffected" in queue()
    call("admit")
    assert queue().count("\tmemory-health-uncalibrated\t") == 1
    facts(rss=[{**daemon,"rss_bytes":gib//2},dict(fleet),dict(child)])
    call("sample")
    facts()
    baseline = call("baseline")["baseline"]
    assert baseline["non_fleet_max_bytes"] == gib and baseline["smallest_reading_max_bytes"] == gib//2, baseline
    assert baseline["samples"] == 5 and baseline["first_checked_at"] < baseline["last_checked_at"], baseline
    report = call("admit")
    assert report["anonymous_bytes"] == 16*gib and report["compressor_bytes"] == gib//2
    assert report["unused_bytes"] == 1100*16384 and report["swap_used_bytes"] > 0
    assert report["alarms"] == [] and report["calibration"] is None  # equality does not alarm
    original = (state / ".memory-baseline.json").read_bytes()
    call("baseline",code=75)
    assert (state / ".memory-baseline.json").read_bytes() == original
    print("ok - a missing alarm baseline never defers admission; baseline needs two healthy readings, excludes fleet ancestry and never silently grows")

    worker = subprocess.Popen(["sleep","120"])
    try:
        ran = home / "new-run"
        # This represents the actual new-run entrypoint; its work must not start
        # on pressure, while an already running process must remain alive.
        launch = ("--",sys.executable,"-c","from pathlib import Path; import sys; Path(sys.argv[1]).touch()",str(ran))
        call("run",*launch)
        assert ran.exists()
        ran.unlink()
        facts(pressure=2)
        call("run",*launch,code=75)
        assert not ran.exists() and worker.poll() is None
        facts(pressure=4)
        call("admit",code=75)
        assert worker.poll() is None
        print("ok - real run-start exec admits healthy work, refuses warning/critical pressure with 75 and preserves existing work")
    finally:
        worker.terminate()
        worker.wait()

    facts()
    call("probe")
    before = queue().count("\n")
    facts(rss=[{**daemon,"rss_bytes":gib+1},dict(fleet),dict(child)])
    report = call("probe")
    assert len(report["alarms"]) == 1 and report["alarms"][0]["pid"] == 101
    assert queue().count("\n") == before+1
    assert "xprotectd PID 101" in queue() and "across 5 healthy readings" in queue()
    assert "restarting any system daemon requires" in queue()
    call("probe")
    facts(rss=[{**daemon,"pid":102,"started":"start-102","rss_bytes":gib+2},dict(fleet),dict(child)])
    call("probe")
    assert queue().count("\n") == before+1
    facts()
    call("probe")
    facts(rss=[{**daemon,"rss_bytes":gib+1},dict(fleet),dict(child)])
    call("probe")
    assert queue().count("\n") == before+2
    print("ok - a named non-fleet outlier raises one durable check per episode, including after recovery or a restart; fleet children never masquerade as leaks")

    facts()
    (fixture / "vm_stat").unlink()
    report = call("admit",code=75)
    assert report["errors"] and "anonymous_bytes" not in report
    assert report["admission"] == "defer" and "admission measurements are unavailable (memory:" in queue()
    facts()
    (fixture / "processes.json").write_text('[{"pid":101,"rss_bytes":"unknown"}]')
    report = call("admit",code=75)
    assert any("processes:" in e for e in report["errors"])
    facts()
    (state / ".memory-baseline.json").write_text('{"invalid":true}')
    report = call("admit")
    assert "unusable" in report["calibration"] and report["admission"] == "admit"
    (state / ".memory-baseline.json").write_text(json.dumps({**baseline, "host":"other-host"}))
    report = call("admit")
    assert "not host" in report["calibration"] and report["admission"] == "admit"
    replaced = call("baseline")["baseline"]
    assert replaced["host"] == report["host"] and replaced["samples"] > baseline["samples"]
    records = [json.loads(line) for line in (state / "memory-readings.jsonl").read_text().splitlines()]
    assert all(row["fixture"] == str(fixture) for row in records)
    assert any(row["source"] == "probe" and row["alarms"] for row in records)
    print("ok - unreadable facts fail closed, an unusable or other-host baseline only reports calibration and is replaced by baseline; every observation is parseable JSONL")

    # A local secondmate home (and any confined worker in it) records its own
    # readings, alarm episodes and wake rows, and reads the root's one baseline.
    sub = home / "secondmate"
    (sub / "state").mkdir(parents=True)
    (sub / ".fm-secondmate-parent").write_text(f"schema=fm-secondmate-parent.v1\nroute=local\nparent_home={home}\n")
    sub_env = {**env, "FM_HOME":str(sub)}
    root_queue, root_readings = queue(), (state / "memory-readings.jsonl").read_bytes()
    facts(rss=[{**daemon,"rss_bytes":2*gib},dict(fleet),dict(child)])
    report = call("admit",environ=sub_env)
    assert report["baseline"]["host"] == replaced["host"] and report["alarms"][0]["pid"] == 101
    assert queue() == root_queue and (state / "memory-readings.jsonl").read_bytes() == root_readings
    sub_rows = [line.split("\t") for line in (sub / "state/.wake-queue").read_text().splitlines()]
    assert [row[1] for row in sub_rows] == ["1"] and "xprotectd PID 101" in sub_rows[0][4], sub_rows
    assert (sub / "state/.wake-queue.seq").read_text().strip() == "1"
    assert json.loads((sub / "state/memory-readings.jsonl").read_text())["source"] == "admit"
    print("ok - a secondmate home's admission writes only its own readings and queue sequence while reading the root baseline")
PY
