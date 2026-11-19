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

    def facts(pressure=1, rss=None, total=32*gib, available=8*gib, compressor=gib//2):
        (fixture / "sysctl").write_text(f"{total}\n{pressure}\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n")
        (fixture / "vm_stat").write_text(
            "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
            "Pages free: 1000.\nPages speculative: 100.\n"
            f"Anonymous pages: 1048576.\nFile-backed pages: {available//16384 - 1100}.\n"
            f"Pages purgeable: 100.\nPages occupied by compressor: {compressor//16384}.\n")
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

    # The harm test needs a measured host: this home's record is written by hand with the shape the probe
    # leaves (25 task and 25 no-mistakes run peaks, 200 steps 300 s apart, a fresh last reading), so the
    # alarm-baseline cases below exercise their own outcomes and not the unmeasured-host deferral.
    import datetime as _dt0, socket as _socket0
    def seed(path):
        path.parent.mkdir(parents=True, exist_ok=True)
        stamp = _dt0.datetime.now(_dt0.timezone.utc)
        peaks = lambda kind, size: {f"{kind}:r{i}": {"peak_bytes": (i + 1) * size, "samples": 2, "incomplete_samples": 0,
                                                    "first_seen": stamp.isoformat(), "last_seen": stamp.isoformat(),
                                                    "max_gap_seconds": 0} for i in range(25)}
        path.write_text(json.dumps({
            "schema": "fm-memory-calibration.v1", "host": _socket0.gethostname(), "total_bytes": 32 * gib,
            "runs": {**peaks("task", 100 * 1024 ** 2), **peaks("no-mistakes", 200 * 1024 ** 2)}, "pressured": None,
            "trail": {"last": {"at": (stamp - _dt0.timedelta(seconds=60)).isoformat(), "available_bytes": 8 * gib,
                               "compressor_bytes": gib // 2, "swap_used_bytes": int(1565.88 * 1024 ** 2)},
                      "steps": [[300, k * 10 * 1024 ** 2, k * 5 * 1024 ** 2, 0] for k in range(1, 201)]}}))
    seed(state / ".memory-calibration.json")
    facts()
    report = call("baseline",code=75)
    assert any("at least two probe readings" in r and "has 0" in r for r in report["reasons"]), report
    assert not (state / ".memory-baseline.json").exists()
    report = call("admit")
    assert report["admission"] == "admit" and report["baseline"] is None
    assert "no baseline" in report["calibration"] and report["headroom_calibration"], report
    assert report["headroom"] is None and report["available_bytes"] == 8*gib and queue() == ""
    call("probe")
    call("probe")
    assert rows("memory-health-uncalibrated") == 1 and "admission is unaffected" in queue()
    # A confined worker's admission cannot read other users' RSS, so its lower
    # maximum must neither fake spread nor lower the episode floor.
    facts(rss=[{**daemon,"rss_bytes":gib//4},dict(fleet),dict(child)])
    call("admit")
    call("sample")
    facts()
    report = call("baseline",code=75)
    assert any("varies" in r and "all 2" in r for r in report["reasons"]), report
    assert not (state / ".memory-baseline.json").exists()
    facts(rss=[{**daemon,"rss_bytes":gib//2},dict(fleet),dict(child)])
    call("probe")
    facts()
    baseline = call("baseline")["baseline"]
    assert baseline["non_fleet_max_bytes"] == gib and baseline["smallest_reading_max_bytes"] == gib//2, baseline
    assert baseline["samples"] == 3 and baseline["first_checked_at"] < baseline["last_checked_at"], baseline
    report = call("admit")
    assert report["anonymous_bytes"] == 16*gib and report["compressor_bytes"] == gib//2
    assert report["unused_bytes"] == 1100*16384 and report["swap_used_bytes"] > 0
    assert report["alarms"] == [] and report["calibration"] is None  # equality does not alarm
    original = (state / ".memory-baseline.json").read_bytes()
    call("baseline",code=75)
    assert (state / ".memory-baseline.json").read_bytes() == original
    print("ok - a missing alarm baseline never defers admission; only the probe reports calibration once; baseline needs varying root probe readings, ignores confined admission samples and never silently grows")

    worker = subprocess.Popen(["sleep","120"])
    try:
        ran = home / "new-run"
        # This represents the actual new-run entrypoint; its work must not start
        # on pressure, while an already running process must remain alive.
        launch = ("--",sys.executable,"-c","from pathlib import Path; import sys; Path(sys.argv[1]).touch()",str(ran))
        call("run",*launch)
        assert ran.exists()
        ran.unlink()
        # The kernel pressure level is telemetry: it is recorded and never decides.
        for level in (2, 4):
            facts(pressure=level)
            call("run",*launch)
            assert ran.exists()
            ran.unlink()
            report = call("admit")
            assert report["pressure_level"] == level and report["admission"] == "admit" and report["reasons"] == [], report
        facts(pressure=0)
        report = call("admit",code=75)
        assert any("unexpected native pressure level 0" in e for e in report["errors"]), report
        assert worker.poll() is None
        print("ok - real run-start exec admits healthy work and records but ignores pressure 2/4; an unreadable level still refuses with 75 and existing work is preserved")
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
    assert "xprotectd PID 101" in queue() and "across 3 healthy readings" in queue()
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
    (state / ".memory-baseline.json").write_text(json.dumps({**baseline, "smallest_reading_max_bytes":gib}))
    report = call("admit")
    assert "no spread" in report["calibration"] and report["alarms"] == []
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
    facts(rss=run_rows(gib), available=gib)
    report = call("admit",code=75,environ=calib_env)
    assert report["headroom"]["headroom_bytes"] == 6*gib, report
    assert len(report["reasons"]) == 1 and report["reasons"][0].startswith("the harm cannot be judged: "), report["reasons"]
    print("ok - probes record each run's resident-tree peak, samples, span, gaps and omissions; the derived peak and margin are shown and never decide: the only deferral is the harm test's own unjudged record")

    # Studio fixture from JetsamEvent-2026-10-27-113941.ips (sha256
    # 907ef8e738586a5434f9884c3f928dcadc8c075711de979db5bc75614684d8f7),
    # 16384-byte pages. Recorded there: xprotectd 2910176 resident pages; all
    # listed processes 6586830; the terminal coalition holding the 12 runs
    # 701024; wired 450714; compressor 440477; 7912 low-swap kills; and
    # memoryStatus.memoryPages free 4488434, fileBacked 1306749, purgeable
    # 73987, anonymous 1831731 and speculative 181265. The report does not say
    # when memoryPages was taken relative to the kills, and those counters give
    # about 89.6 GiB available by this code's formula, so this fixture does not
    # use them. It does not record RAM size (128 GiB is from the incident
    # report), a native pressure level, process parents, run identity, or any
    # run's peak. So this fixture splits that coalition evenly into 12 runs,
    # ESTIMATES available memory before the kills as RAM minus all listed
    # resident, wired and compressor pages (shared pages make that a lower
    # bound), and represents the kills as level-4 readings. The estimate is not
    # the report's own available-memory reading, and nothing here is recorded
    # whole-run telemetry, a calibrated refusal, or live target-host proof.
    page = 16384
    studio = home / "studio"
    (studio / "state").mkdir(parents=True)
    studio_env = {**env, "FM_HOME":str(studio)}
    run_bytes = 701024*page//12
    available = (128*gib//page - 6586830 - 450714 - 440477)*page
    runs = [{"pid":300+n, "ppid":1, "comm":"no-mistakes", "started":f"start-{300+n}",
             "rss_bytes":run_bytes, "fleet":True, "run":f"no-mistakes:studio/run-{n}"} for n in range(12)]
    def studio_facts(pressure=1):
        facts(pressure=pressure, total=128*gib, available=available,
              rss=[{**daemon,"rss_bytes":2910176*page}] + [dict(row) for row in runs])
    studio_facts(pressure=4)
    call("probe",environ=studio_env)
    call("probe",environ=studio_env)
    studio_facts()
    ran = home / "studio-run"
    launch = ("--",sys.executable,"-c","from pathlib import Path; import sys; Path(sys.argv[1]).touch()",str(ran))
    report = call("admit",code=75,environ=studio_env)
    assert report["headroom"]["run_peak_bytes"] == run_bytes and report["headroom"]["headroom_bytes"] == available
    assert report["reasons"][0].startswith("the harm cannot be judged: "), report
    call("run",*launch,code=75,environ=studio_env)
    assert not ran.exists()
    studio_facts(pressure=2)
    call("run",*launch,code=75,environ=studio_env)
    assert not ran.exists()
    print("ok - estimated 113941 Studio shape with 12 runs running: the margin is recorded and shown, and a 13th start is deferred at pressure 1 or 2 because the record is too short to judge the harm")

    # The harm itself decides. A record is written by hand with exact derived
    # values: 200 steps 300 s apart whose available drops are k x 10 MiB (p99
    # 1980 MiB), and 25 task peaks of i x 100 MiB (p95 2400 MiB) and 25
    # no-mistakes peaks of i x 200 MiB (p95 4800 MiB). The previous probe
    # reading holds the swap and compressor the fixture reads unless a case
    # moves them. The fixture host runs no fleet run unless a case adds one.
    import datetime as _dt, socket as _socket
    mib = 1024 ** 2
    harm = home / "harm"
    (harm / "state").mkdir(parents=True)
    harm_env = {**env, "FM_HOME":str(harm)}
    swap_now = int(1565.88 * mib)
    compressor_now = gib // 2
    record_path = harm / "state/.memory-calibration.json"
    busy_rows = [dict(daemon), {"pid":601, "ppid":1, "comm":"omp", "started":"s601", "rss_bytes":gib,
                                "fleet":True, "run":"task:busy"}]

    def record(last_swap=swap_now, last_compressor=compressor_now, age=120, steps=200, host=None,
               kinds=("task", "no-mistakes")):
        stamp = _dt.datetime.now(_dt.timezone.utc)
        peaks = lambda kind, size: {f"{kind}:r{i}": {"peak_bytes": (i + 1) * size, "samples": 2, "incomplete_samples": 0,
                                                    "first_seen": stamp.isoformat(), "last_seen": stamp.isoformat(),
                                                    "max_gap_seconds": 0} for i in range(25)}
        runs = {}
        for kind, size in (("task", 100 * mib), ("no-mistakes", 200 * mib)):
            if kind in kinds:
                runs.update(peaks(kind, size))
        record_path.write_text(json.dumps({
            "schema": "fm-memory-calibration.v1", "host": host or _socket.gethostname(), "total_bytes": 32 * gib,
            "runs": runs, "pressured": None,
            "trail": {"last": {"at": (stamp - _dt.timedelta(seconds=age)).isoformat(), "available_bytes": 20 * gib,
                               "compressor_bytes": last_compressor, "swap_used_bytes": last_swap},
                      "steps": [[300, k * 10 * mib, k * 5 * mib, 0] for k in range(1, steps + 1)]}}))

    def decide(kind="task", code=0, mode="admit", pressure=1, available=20*gib, compressor=compressor_now,
               busy=False, recorded=True, **moves):
        facts(pressure=pressure, available=available, compressor=compressor, rss=busy_rows if busy else None)
        if recorded:
            record(**moves)
        else:
            record_path.unlink(missing_ok=True)
        return call(mode, *(("--kind", kind) if kind else ()), code=code, environ=harm_env)

    # fit: the projection is the run kind's p95 peak and the reserve the p99 drop
    report = decide(pressure=4, available=10*gib)
    detail = report["harm"]
    assert report["admission"] == "admit" and report["pressure_level"] == 4 and report["reasons"] == [], report
    assert detail["projected_bytes"] == 2400 * mib and detail["reserve_bytes"] == 1980 * mib, detail
    assert detail["window_seconds"] == 300 and "compressor_rise_bytes" not in detail, detail
    assert detail["projection_runs"] == 25 and detail["not_judged"] == [] and "bootstrap" not in detail, detail
    report = decide(pressure=1, available=4000*mib, code=75)
    assert report["reasons"][0].startswith("projected task run of 2.34 GiB (p95 of 25 recorded) does not fit in "
                                           "3.91 GiB available minus a 1.93 GiB reserve"), report["reasons"]
    decide(available=4380*mib)
    decide(available=4379*mib, code=75)
    report = decide("no-mistakes", available=6*gib, code=75)
    assert report["harm"]["projected_bytes"] == 4800 * mib, report["harm"]
    decide("task", available=6*gib)
    report = decide(None, available=6*gib, code=75)
    assert report["harm"]["projected_kind"] == "no-mistakes", report["harm"]
    decide("no-mistakes", available=6780*mib)
    # run defaults to the no-mistakes kind; admit --kind task is the spawn kind
    ran = home / "harm-run"
    launch = ("--",sys.executable,"-c","from pathlib import Path; import sys; Path(sys.argv[1]).touch()",str(ran))
    facts(available=6*gib); record()
    call("run",*launch,code=75,environ=harm_env)
    assert not ran.exists()
    facts(available=8*gib); record()
    call("run",*launch,environ=harm_env)
    assert ran.exists()
    ran.unlink()
    facts(available=6*gib); record()
    call("run","--kind","task",*launch,environ=harm_env)
    assert ran.exists()
    ran.unlink()
    for bad in (("admit","--kind","bogus"),("probe","--kind","task"),("admit","--kind")):
        result = subprocess.run(["bash",wrapper,*bad],capture_output=True,text=True,env=harm_env)
        assert result.returncode == 2, (bad, result)
    print("ok - fit: a run is deferred when its kind's p95 peak does not fit in available minus the p99 reserve and admitted when it does, at any pressure level, with the numbers in the reason")

    # an unspecified kind needs both kinds' projections; one kind absent leaves it unjudged
    report = decide(None, kinds=("task",), busy=True, code=75)
    assert report["reasons"][0].startswith("the harm cannot be judged: fit: 0 recorded no-mistakes runs"), report["reasons"]
    report = decide(None, kinds=("no-mistakes",), busy=True, code=75)
    assert "0 recorded task runs" in report["reasons"][0], report["reasons"]
    decide("task", kinds=("task",), busy=True)
    decide("no-mistakes", kinds=("task",), busy=True, code=75)
    report = decide(None, kinds=("task", "no-mistakes"), busy=True)
    assert report["harm"]["projected_kind"] == "no-mistakes" and report["reasons"] == [], report
    print("ok - an unspecified kind is judged only when both kinds' projections exist: one kind absent defers, both present judge the larger")

    # swap growth defers even with abundant memory; a shrink or no change does not
    report = decide(available=30*gib, last_swap=swap_now - 100*mib, code=75)
    assert report["reasons"][0].startswith(f"swap used grew by {100 * mib} bytes (0.098 GiB) in the 12"), report["reasons"]
    assert report["harm"]["swap_delta_bytes"] == 100 * mib, report["harm"]
    decide(available=30*gib, last_swap=swap_now + 100*mib)
    decide(available=30*gib)
    print("ok - swap growth since the last probe reading defers with 75 even when 30 GiB is available; a shrink or no change admits")

    # any compressor increase defers, however small; no change or a fall admits
    report = decide(available=30*gib, compressor=compressor_now + 16384, code=75)
    assert report["reasons"][0].startswith("compressor grew by 16384 bytes (0.000 GiB) in the 12"), report["reasons"]
    assert report["harm"]["compressor_delta_bytes"] == 16384, report["harm"]
    decide(available=30*gib, compressor=compressor_now + 950*mib, code=75)
    decide(available=30*gib, compressor=compressor_now + gib, code=75)
    decide(available=30*gib)
    decide(available=30*gib, last_compressor=compressor_now + gib)
    print("ok - a compressor increase of one page, 950 MiB or 1 GiB defers; no change or a fall admits")

    # what cannot be judged defers with its reason, the recovery and the calibration run. The one
    # bootstrap admit: an idle host whose available memory exceeds the largest peak recorded for ANY kind
    # (here 5000 MiB, the no-mistakes p100; 2500 MiB with task peaks only).
    for name, moves in (("a previous probe reading 2000 s old outside the 300 s window", dict(last_swap=swap_now - 100*mib, age=2000)),
                        ("a record of 50 steps", dict(steps=50))):
        report = decide(available=30*gib, busy=True, code=75, **moves)
        reason = report["reasons"][0]
        assert reason.startswith("the harm cannot be judged: ") and "bin/fm-mem-guard.sh probe" in reason, (name, reason)
        assert "bin/fm-mem-guard.sh calibrate --kind task -- <command>" in reason, (name, reason)
        assert report["harm"]["not_judged"] and "bootstrap" not in report["harm"], (name, report["harm"])
        idle = decide(available=30*gib, busy=False, **moves)
        assert idle["reasons"] == [] and "no fleet run is running" in idle["harm"]["bootstrap"], (name, idle["harm"])
        assert idle["harm"]["largest_peak_bytes"] == 5000 * mib, (name, idle["harm"])
    report = decide(available=30*gib, busy=True, age=2000, code=75, last_swap=swap_now - 100*mib)
    # the reading is stamped 2000 s before the decision, which runs a moment later: the age reads 2000 s plus the run time
    assert "outside the 300 s window" in report["reasons"][0] and any(f"{age} s old" in report["reasons"][0] for age in range(2000, 2010)), report["reasons"]
    report = decide(available=30*gib, busy=True, steps=50, code=75)
    assert "fit: 50 recorded probe steps; 100 are needed for a reserve" in report["reasons"][0], report["reasons"]
    # the task-only record's largest peak is 2500 MiB: an idle host above it admits, below it defers
    report = decide(None, available=3000*mib, busy=False, kinds=("task",), steps=50)
    assert report["harm"]["largest_peak_bytes"] == 2500 * mib and "bootstrap" in report["harm"], report["harm"]
    report = decide(None, available=2000*mib, busy=False, kinds=("task",), steps=50, code=75)
    assert "1.95 GiB available does not exceed the largest recorded run peak of 2.44 GiB" in report["reasons"][0], report["reasons"]
    assert "bootstrap" not in report["harm"], report["harm"]
    # no record, an unusable record, or one with no run peak: nothing was ever measured, so an idle host admits nothing
    # either, and the reading names the calibration run
    for name, moves in (("no calibration record", dict(recorded=False)),
                        ("another host's record", dict(host="another-host")),
                        ("a record without a run peak", dict(kinds=()))):
        for busy in (True, False):
            report = decide(available=30*gib, busy=busy, code=75, **moves)
            reason = report["reasons"][0]
            assert reason.startswith("the harm cannot be judged: ") and "bootstrap" not in report["harm"], (name, busy, report["harm"])
            assert "bin/fm-mem-guard.sh calibrate --kind task -- <command>" in reason, (name, busy, reason)
            assert ("no run peak has ever been recorded" in reason) == (not busy), (name, busy, reason)
    # a busy host never takes the bootstrap path, whatever is available or recorded
    report = decide(available=31*gib, busy=True, steps=50, code=75)
    assert "bootstrap" not in report["harm"] and "bin/fm-mem-guard.sh probe" in report["reasons"][0], report
    # a judged harm still defers an idle host with an incomplete record
    report = decide(None, available=30*gib, busy=False, kinds=("task",), last_swap=swap_now - 100*mib, code=75)
    assert report["reasons"][0].startswith("swap used grew") and "bootstrap" not in report["harm"], report
    print("ok - an unjudged fit or trend defers a busy host with its reason, the recovery and the calibration run; an idle host admits one start only above the largest recorded peak, and a host with no recorded peak admits nothing")

    # the calibration run is how a host with no measurement gets one, and how the deadlock case (a task
    # running, no no-mistakes run ever recorded) is resolved: each run is recorded as a measured run of its kind
    grow = ("--", sys.executable, "-c",
            "import time; b = bytearray(120 * 1024 * 1024)\nfor i in range(0, len(b), 4096): b[i] = 1\ntime.sleep(10)")
    def calibrate(kind, code=0, command=grow):
        result = subprocess.run(["bash", wrapper, "calibrate", "--kind", kind, *command], capture_output=True, text=True, env=harm_env)
        assert result.returncode == code, (kind, result.returncode, result.stdout, result.stderr)
        return result
    # nothing recorded and a fleet run running: refused; nothing recorded and idle: measured and recorded
    facts(available=30*gib, rss=busy_rows); record_path.unlink(missing_ok=True)
    refused = calibrate("task", code=75)
    assert "no run peak has ever been recorded" in refused.stderr and not record_path.exists(), refused.stderr
    facts(available=30*gib); record_path.unlink(missing_ok=True)
    done = calibrate("task")
    runs = json.loads(record_path.read_text())["runs"]
    assert list(runs) and all(name.startswith("task:calibration/") for name in runs), runs
    measured = next(iter(runs.values()))
    assert measured["peak_bytes"] >= 100 * mib and measured["samples"] >= 2, measured
    assert "calibration recorded: task:calibration/" in done.stderr, done.stderr
    # the deadlock case: a task is running, only task peaks exist, a no-mistakes start defers and names the route
    facts(available=30*gib, rss=busy_rows); record(kinds=("task",))
    refused = subprocess.run(["bash", wrapper, "run", "--kind", "no-mistakes", "--", sys.executable, "-c", "pass"],
                             capture_output=True, text=True, env=harm_env)
    report = json.loads(refused.stderr)
    assert refused.returncode == 75 and "0 recorded no-mistakes runs" in report["reasons"][0], refused.stderr
    assert "calibrate --kind no-mistakes -- <command>" in report["reasons"][0], report
    calibrate("no-mistakes")
    report = call("admit", "--kind", "no-mistakes", code=75, environ=harm_env)
    assert "1 recorded no-mistakes runs" in report["reasons"][0], report["reasons"]
    calibrate("no-mistakes")
    facts(available=30*gib, rss=busy_rows)
    report = call("admit", "--kind", "no-mistakes", environ=harm_env)
    assert report["admission"] == "admit" and report["harm"]["projection_runs"] == 2 and report["harm"]["not_judged"] == [], report
    # the run is refused while swap grows, and a command too short to read twice records nothing
    facts(available=30*gib, rss=busy_rows); record(last_swap=swap_now - 100*mib)
    refused = calibrate("task", code=75)
    assert "swap used grew by" in refused.stderr, refused.stderr
    facts(available=30*gib, rss=busy_rows); record(kinds=("task",))
    before = json.loads(record_path.read_text())["runs"]
    short = calibrate("task", code=1, command=("--", "true"))
    assert json.loads(record_path.read_text())["runs"] == before and "not recorded" in short.stderr, short.stderr
    print("ok - calibrate records a measured run of its kind (refused on a busy unmeasured host, while swap grows, or when too short to read twice), and two calibration runs resolve the task-running, no-mistakes-unmeasured deadlock")

    # a failed or inconsistent read keeps its fail-closed 75 whatever the record says
    facts(available=30*gib); record()
    (fixture / "vm_stat").unlink()
    report = call("admit","--kind","task",code=75,environ=harm_env)
    assert report["errors"] and report["harm"] is None, report
    facts(available=30*gib); record()
    (fixture / "sysctl").write_text(f"{32*gib}\nnot-a-number\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n")
    report = call("admit","--kind","task",code=75,environ=harm_env)
    assert report["errors"] and report["harm"] is None, report
    print("ok - an unreadable memory fact still defers with 75 and judges no harm")

    # a probe decides from the record before it folds in, then folds one step in
    facts(available=30*gib, compressor=compressor_now + gib); record()
    report = call("probe",environ=harm_env)
    assert report["admission"] == "defer" and f"compressor grew by {gib} bytes (1.000 GiB)" in report["reasons"][0], report
    folded = json.loads(record_path.read_text())
    assert len(folded["trail"]["steps"]) == 201 and folded["trail"]["steps"][-1][2] == gib, folded["trail"]["steps"][-1]
    assert folded["trail"]["last"]["compressor_bytes"] == compressor_now + gib
    report = call("probe",environ=harm_env)
    assert report["admission"] == "admit" and report["harm"]["compressor_delta_bytes"] == 0, report
    print("ok - a probe judges the previous probe reading, then records one step (gap, available drop, compressor and swap change) and the new last reading")

    # a short record (3 steps of 300 s, so a 300 s window and no reserve) still refuses growth against a fresh previous
    # reading, on the bootstrap admit and on the calibration run; every control below must keep admitting
    def short_record(prior="fresh", **moves):
        record(steps=3, **moves)
        saved = json.loads(record_path.read_text())
        if prior == "none":
            del saved["trail"]["last"]
        record_path.write_text(json.dumps(saved))
    rise = 16384
    for name, moves in (("a one-page compressor rise", dict(last_compressor=compressor_now - rise)),
                        ("swap growth", dict(last_swap=swap_now - 100*mib))):
        print(f"case - short record, {name}: admit")
        facts(available=20*gib); short_record(**moves)
        report = call("admit", "--kind", "no-mistakes", code=75, environ=harm_env)
        assert "bootstrap" not in report["harm"] and report["harm"]["window_seconds"] == 300, (name, report["harm"])
        assert report["reasons"][0].startswith(("compressor grew by 16384 bytes", "swap used grew by")), (name, report["reasons"])
        assert "reserve_bytes" not in report["harm"], (name, report["harm"])
        print(f"case - short record, {name}: calibrate")
        facts(available=20*gib); short_record(**moves)
        before = json.loads(record_path.read_text())["runs"]
        refused = calibrate("no-mistakes", code=75)
        assert "grew by" in refused.stderr and json.loads(record_path.read_text())["runs"] == before, refused.stderr
    for name, setup in (("flat readings", lambda: short_record()),
                        ("no previous reading", lambda: short_record(prior="none", last_compressor=compressor_now - rise)),
                        ("a previous reading 600 s old outside the 300 s window",
                         lambda: short_record(last_compressor=compressor_now - rise, age=600))):
        facts(available=20*gib); setup()
        report = call("admit", "--kind", "no-mistakes", environ=harm_env)
        assert report["reasons"] == [] and "no fleet run is running" in report["harm"]["bootstrap"], (name, report["harm"])
        facts(available=20*gib); setup()
        done = calibrate("no-mistakes")
        assert "calibration recorded: no-mistakes:calibration/" in done.stderr, (name, done.stderr)
    # one step names no window, so no previous reading counts as fresh: the one start admits on the bootstrap alone
    facts(available=20*gib); record(steps=1, last_compressor=compressor_now - rise)
    report = call("admit", "--kind", "no-mistakes", environ=harm_env)
    assert "window_seconds" not in report["harm"] and "bootstrap" in report["harm"], report["harm"]
    print("ok - a short record refuses swap or compressor growth against a fresh previous reading on admit and calibrate, and still admits flat readings, no previous reading and a stale one")
PY
