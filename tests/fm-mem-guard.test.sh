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
              "rss_bytes":gib, "fleet":False, "run":None}
    fleet = {"pid":201, "ppid":1, "comm":"node", "started":"start-201",
             "rss_bytes":6*gib, "fleet":True, "run":None}
    child = {"pid":202, "ppid":201, "comm":"python3", "started":"start-202",
             "rss_bytes":5*gib, "fleet":False, "run":None}

    def facts(pressure=1, rss=None, total=32*gib, available=8*gib):
        (fixture / "sysctl").write_text(f"{total}\n{pressure}\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n")
        (fixture / "vm_stat").write_text(
            "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
            "Pages free: 1000.\nPages speculative: 100.\n"
            f"Anonymous pages: 1048576.\nFile-backed pages: {available//16384 - 1100}.\n"
            "Pages purgeable: 100.\nPages occupied by compressor: 32768.\n")
        rows = [dict(daemon), dict(fleet), dict(child)] if rss is None else rss
        (fixture / "processes.json").write_text(json.dumps(rows))

    def call(mode, *args, code=0, environ=None):
        result = subprocess.run(["bash",wrapper,mode,*args],capture_output=True,text=True,env=environ or env)
        assert result.returncode == code, (mode,result.returncode,result.stdout,result.stderr)
        return json.loads(result.stdout) if result.stdout else None

    def queue(where=state):
        path = where / ".wake-queue"
        return path.read_text() if path.exists() else ""

    def rows(key, where=state):
        return queue(where).count(f"\t{key}\t")

    facts()
    report = call("baseline",code=75)
    assert any("at least two readings" in r and "has 1" in r for r in report["reasons"]), report
    assert not (state / ".memory-baseline.json").exists()
    report = call("admit")
    assert report["admission"] == "admit" and report["baseline"] is None
    assert "no baseline" in report["calibration"] and "no calibration" in report["headroom_calibration"], report
    assert report["headroom"] is None and report["available_bytes"] == 8*gib and queue() == ""
    call("probe")
    call("probe")
    assert rows("memory-health-uncalibrated") == 1 and rows("memory-health-headroom-uncalibrated") == 1
    assert "admission is unaffected" in queue() and "no reading at native pressure 2" in queue()
    facts(rss=[{**daemon,"rss_bytes":gib//2},dict(fleet),dict(child)])
    call("sample")
    facts()
    baseline = call("baseline")["baseline"]
    assert baseline["non_fleet_max_bytes"] == gib and baseline["smallest_reading_max_bytes"] == gib//2, baseline
    assert baseline["samples"] == 6 and baseline["first_checked_at"] < baseline["last_checked_at"], baseline
    report = call("admit")
    assert report["anonymous_bytes"] == 16*gib and report["compressor_bytes"] == gib//2
    assert report["unused_bytes"] == 1100*16384 and report["swap_used_bytes"] > 0
    assert report["alarms"] == [] and report["calibration"] is None  # equality does not alarm
    original = (state / ".memory-baseline.json").read_bytes()
    call("baseline",code=75)
    assert (state / ".memory-baseline.json").read_bytes() == original
    print("ok - a missing alarm baseline never defers admission; only the probe reports calibration once; baseline needs two healthy readings and never silently grows")

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
        facts(pressure=0)
        report = call("admit",code=75)
        assert any("unexpected native pressure level 0" in e for e in report["errors"]), report
        assert worker.poll() is None
        print("ok - real run-start exec admits healthy work, refuses pressure 2/4 and an unreadable level with 75 and preserves existing work")
    finally:
        worker.terminate()
        worker.wait()

    facts()
    call("probe")
    before = rows("memory-health")
    facts(rss=[{**daemon,"rss_bytes":gib+1},dict(fleet),dict(child)])
    report = call("probe")
    assert len(report["alarms"]) == 1 and report["alarms"][0]["pid"] == 101
    assert rows("memory-health") == before+1
    assert "xprotectd PID 101" in queue() and "across 6 healthy readings" in queue()
    assert "restarting any system daemon requires" in queue()
    facts(rss=[{**daemon,"pid":102,"started":"start-102","rss_bytes":gib+2},dict(fleet),dict(child)])
    call("probe")
    facts(rss=[{**daemon,"rss_bytes":gib*3//4},dict(fleet),dict(child)])
    assert call("probe")["alarm_hold"] == ["xprotectd"]
    facts(rss=[{**daemon,"rss_bytes":gib+1},dict(fleet),dict(child)])
    call("probe")
    assert rows("memory-health") == before+1
    facts(rss=[{**daemon,"rss_bytes":gib//2},dict(fleet),dict(child)])
    call("probe")
    facts(rss=[{**daemon,"rss_bytes":gib+1},dict(fleet),dict(child)])
    call("probe")
    assert rows("memory-health") == before+2
    print("ok - a named non-fleet outlier wakes once per episode, held until it falls to the low end of measured healthy variation; fleet children never masquerade as leaks")

    facts()
    (fixture / "vm_stat").unlink()
    report = call("admit",code=75)
    assert report["errors"] and "anonymous_bytes" not in report and report["admission"] == "defer"
    assert report["calibration"] == "not judged: this reading has errors", report
    uncalibrated = rows("memory-health-uncalibrated")
    call("probe")
    assert "admission measurements are unavailable (memory:" in queue()
    assert rows("memory-health-uncalibrated") == uncalibrated
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
    print("ok - unreadable facts fail closed and judge no calibration; an unusable or other-host baseline only reports calibration and is replaced; every observation is parseable JSONL")

    # A local secondmate home (and any confined worker in it) records only its
    # own admission readings and reads the root's baseline; the root alone probes.
    sub = home / "secondmate"
    (sub / "state").mkdir(parents=True)
    (sub / ".fm-secondmate-parent").write_text(f"schema=fm-secondmate-parent.v1\nroute=local\nparent_home={home}\n")
    sub_env = {**env, "FM_HOME":str(sub)}
    root_queue, root_readings = queue(), (state / "memory-readings.jsonl").read_bytes()
    facts(rss=[{**daemon,"rss_bytes":2*gib},dict(fleet),dict(child)])
    report = call("admit",environ=sub_env)
    assert report["baseline"]["host"] == replaced["host"] and report["alarms"][0]["pid"] == 101
    assert call("probe",environ=sub_env) is None
    assert queue() == root_queue and (state / "memory-readings.jsonl").read_bytes() == root_readings
    assert sorted(path.name for path in (sub / "state").iterdir()) == ["memory-readings.jsonl"]
    assert json.loads((sub / "state/memory-readings.jsonl").read_text())["source"] == "admit"
    print("ok - a secondmate home records only its own admission reading; periodic probes and alarms belong to the root home")

    # Run records come from real run trees: a task's paired-marker process with
    # its unattributed descendants, and a no-mistakes run's worktree process.
    calib = home / "calib"
    (calib / "state").mkdir(parents=True)
    calib_env = {**env, "FM_HOME":str(calib)}
    def run_rows(child_rss):
        return [dict(daemon),
                {"pid":401, "ppid":1, "comm":"omp", "started":"s401", "rss_bytes":2*gib, "fleet":True, "run":"task:a"},
                {"pid":402, "ppid":401, "comm":"bash", "started":"s402", "rss_bytes":child_rss, "fleet":False, "run":None},
                {"pid":501, "ppid":1, "comm":"claude", "started":"s501", "rss_bytes":gib, "fleet":True, "run":"no-mistakes:repo/r1"}]
    facts(rss=run_rows(gib), available=20*gib)
    report = call("probe",environ=calib_env)
    assert report["runs"] == {"task:a":{"rss_bytes":3*gib,"processes":2,"unreadable":0},
                              "no-mistakes:repo/r1":{"rss_bytes":gib,"processes":1,"unreadable":0}}, report["runs"]
    assert "at least two readings" in report["headroom_calibration"] and "pressure 2" in report["headroom_calibration"]
    facts(rss=run_rows(None), available=20*gib)
    call("probe",environ=calib_env)
    facts(rss=run_rows(gib*3//2), available=20*gib)
    report = call("probe",environ=calib_env)
    assert "at least two readings" not in report["headroom_calibration"], report
    facts(pressure=2, rss=run_rows(gib), available=6*gib)
    report = call("probe",environ=calib_env)
    assert report["headroom"] == {"run_peak_bytes":gib*7//2, "run":"task:a", "run_samples":4,
                                  "run_incomplete_samples":1, "runs_measured":2,
                                  "headroom_bytes":6*gib, "pressured_samples":1}, report["headroom"]
    record = json.loads((calib / "state/.memory-calibration.json").read_text())
    assert record["runs"]["task:a"]["first_seen"] < record["runs"]["task:a"]["last_seen"]
    assert record["runs"]["task:a"]["max_gap_seconds"] > 0 and record["pressured"]["highest_level"] == 2
    facts(rss=run_rows(gib), available=6*gib + gib*7//2 - 1)
    report = call("admit",code=75,environ=calib_env)
    assert any("below this host's measured headroom margin" in r for r in report["reasons"]), report
    facts(rss=run_rows(gib), available=6*gib + gib*7//2)
    call("admit",environ=calib_env)
    print("ok - probes record each run's resident-tree peak, samples, span, gaps and omissions, and derive the one-run peak and pressured margin used by admission")

    # Studio fixture from JetsamEvent-2026-10-27-113941.ips (sha256
    # 907ef8e738586a5434f9884c3f928dcadc8c075711de979db5bc75614684d8f7),
    # 16384-byte pages. Recorded there: xprotectd 2910176 resident pages; all
    # listed processes 6586830; the terminal coalition holding the 12 runs
    # 701024; wired 450714; compressor 440477; 7912 low-swap kills. It does not
    # record RAM size (128 GiB is from the incident report), a native pressure
    # level, process parents, run identity, or any run's peak. So this fixture
    # splits that coalition evenly into 12 runs, estimates available memory
    # before the kills as RAM minus all listed resident, wired and compressor
    # pages (shared pages make that a lower bound), and represents the kills as
    # level-4 readings. It proves the incident-shaped decision only; it is not
    # recorded whole-run telemetry or a deployed calibration.
    page = 16384
    studio = home / "studio"
    (studio / "state").mkdir(parents=True)
    studio_env = {**env, "FM_HOME":str(studio)}
    run_bytes = 701024*page//12
    available = (128*gib//page - 6586830 - 450714 - 440477)*page
    runs = [{"pid":300+n, "ppid":1, "comm":"no-mistakes", "started":f"start-{300+n}",
             "rss_bytes":run_bytes, "fleet":True, "run":f"no-mistakes:studio/run-{n}"} for n in range(12)]
    def studio_facts(outlier, pressure=1):
        facts(pressure=pressure, total=128*gib, available=available + 2910176*page - outlier,
              rss=[{**daemon,"rss_bytes":outlier}] + [dict(row) for row in runs])
    studio_facts(2910176*page)
    report = call("admit",environ=studio_env)
    assert report["admission"] == "admit" and "no calibration" in report["headroom_calibration"]
    studio_facts(2910176*page, pressure=4)
    call("probe",environ=studio_env)
    call("probe",environ=studio_env)
    studio_facts(2910176*page)
    report = call("admit",code=75,environ=studio_env)
    assert report["headroom"]["run_peak_bytes"] == run_bytes and report["headroom"]["headroom_bytes"] == available
    assert any("below this host's measured headroom margin" in r for r in report["reasons"]), report
    ran = home / "studio-run"
    launch = ("--",sys.executable,"-c","from pathlib import Path; import sys; Path(sys.argv[1]).touch()",str(ran))
    call("run",*launch,code=75,environ=studio_env)
    assert not ran.exists()
    # The daily reports put xprotectd at 0.01 GiB on 2026-10-21.
    studio_facts(gib//100)
    assert call("admit",environ=studio_env)["reasons"] == []
    call("run",*launch,environ=studio_env)
    assert ran.exists()
    studio_facts(gib//100, pressure=2)
    call("admit",code=75,environ=studio_env)
    print("ok - 113941 Studio fixture: uncalibrated admits on pressure alone; once recorded, the 44 GiB outlier refuses the 13th start only through headroom; ample headroom admits; pressure 2 still refuses")
PY
