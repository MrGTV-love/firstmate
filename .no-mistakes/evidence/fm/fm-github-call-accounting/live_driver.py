#!/usr/bin/env python3
"""Live driver: real bin/fm-github-accounting.py, real ps, disposable fm-lab homes.
Usage: live_driver.py <worktree> <evidence-dir> <scenario...>   (smoke quotaerr clock retention dbguard)
Fixture callers are task-owned #!/bin/sh scripts named gh that only sleep; they never reach GitHub."""
import json, os, re, shutil, signal, sqlite3, stat, subprocess, sys, tempfile, time
from pathlib import Path

WT, EV = Path(sys.argv[1]), Path(sys.argv[2])
OWNER, LAB = WT / "bin/fm-github-accounting.py", WT / "bin/fm-lab-home.sh"
STRIP = ("NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE "
         "FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE").split()
SECRETS = ("fixture-secret-body", "ghp_FIXTURETOKEN", "fixture-secret-parent", "fixture-secret-payload")


class Scenario:
    def __init__(self, name):
        self.name, self.lines, self.failed, self.groups = name, [], 0, []
        self.dir = Path(tempfile.mkdtemp(prefix="fm-lab.", dir=os.environ.get("TMPDIR", "/tmp")))
        out = subprocess.run([str(LAB), "create", str(self.dir)], capture_output=True, text=True, check=True)
        self.home = Path(out.stdout.strip())
        self.env = {k: v for k, v in os.environ.items() if k not in STRIP}
        self.env.update(FM_HOME=str(self.home), PYTHONDONTWRITEBYTECODE="1")
        self.fix = self.home / "data/fixtures"
        self.fix.mkdir(parents=True, exist_ok=True)
        self.state = self.home / "state/github-accounting"
        self.log(f"lab home: {self.home} (marker: {(self.home / '.fm-lab-home').exists()})")
        self.log(f"FM_HOME-only env; stripped: {' '.join(STRIP)}")

    def log(self, text=""):
        print(f"[{self.name}] {text}", flush=True)
        self.lines.append(str(text))

    def check(self, label, ok, detail=""):
        self.log(f"{'PASS' if ok else 'FAIL'}: {label}" + (f" -- {detail}" if detail else ""))
        self.failed += 0 if ok else 1
        return ok

    def owner(self, *args, env=None, launcher=None):
        cmd = [sys.executable, str(launcher), str(OWNER), *args] if launcher else [sys.executable, str(OWNER), *args]
        reply = subprocess.run(cmd, env=env or self.env, capture_output=True, text=True, timeout=300)
        self.log(f"$ fm-github-accounting.py {' '.join(args)} -> exit {reply.returncode}"
                 + (f" stdout={reply.stdout.strip()[:300]}" if args[0] != "records" and reply.stdout.strip() else "")
                 + (f" stderr={reply.stderr.strip()[:300]}" if reply.stderr.strip() else ""))
        return reply

    def rows(self, kind=None, env=None, launcher=None):
        args = ["records"] + (["--kind", kind] if kind else [])
        reply = self.owner(*args, env=env, launcher=launcher)
        return [json.loads(line) for line in reply.stdout.splitlines()] if reply.returncode == 0 else None

    def script(self, name, body):
        path = self.fix / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o700)
        return path

    def spawn(self, argv, env=None):
        child = subprocess.Popen(argv, start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, env=env or self.env)
        self.groups.append(child)
        return child

    def kill(self, child, sig=signal.SIGKILL):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass
        child.wait()

    def callers(self):
        """gh fixture plus a parent carrying secrets; returns (parent, script-owned gh is found by rows)."""
        gh = self.script("gh", "sleep 100000\n")
        parent = self.script("caller-parent", f'"{gh}" "$@" --body fixture-secret-body -H "Authorization: token ghp_FIXTURETOKEN"\n')
        return gh, parent

    def finish(self, extra=None):
        for child in self.groups:
            self.kill(child)
        stopped = subprocess.run([sys.executable, str(OWNER), "stop"], env=self.env, capture_output=True, text=True, timeout=120)
        self.log(f"teardown owner stop -> exit {stopped.returncode} {stopped.stdout.strip()}")
        left = subprocess.run(["pgrep", "-f", str(self.home)], capture_output=True, text=True).stdout.split()
        self.log(f"leftover processes naming the lab: {left}")
        down = subprocess.run([str(LAB), "teardown", str(self.home)], capture_output=True, text=True)
        self.log(f"lab teardown -> exit {down.returncode}")
        shutil.rmtree(self.home, ignore_errors=True)
        self.log(f"lab removed: {not self.home.exists()}")
        self.log(f"RESULT {'PASS' if not self.failed else 'FAIL'} failures={self.failed}")
        (EV / f"scenario-{self.name}.log").write_text("\n".join(self.lines) + "\n")
        return self.failed


def wait(predicate, seconds, step=0.2):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


def db_rows(s, kind):
    # Read-only peek while the owner runs; `records` refuses then by design.
    db = sqlite3.connect(f"file:{s.state / 'observations.sqlite'}?mode=ro", uri=True, timeout=5)
    try:
        return [json.loads(r[0]) for r in db.execute("SELECT payload FROM observations WHERE kind=? ORDER BY rowid", (kind,))]
    finally:
        db.close()


def assert_redacted(s, rows):
    text = json.dumps(rows)
    s.check("no fixture secret in public records", not any(sec in text for sec in SECRETS))
    db = s.state / "observations.sqlite"
    raw = db.read_bytes() if db.exists() else b""
    s.check("no fixture secret in raw database bytes", not any(sec.encode() in raw for sec in SECRETS))


def smoke():
    """Real gh-axi (REST rate_limit, read-only, costs no GraphQL points), real ps, full lifecycle."""
    s = Scenario("smoke-real-gh-axi")
    gh, parent = s.callers()
    py_parent = s.script("py-parent", f'exec python3 -c "import subprocess,sys; subprocess.run([sys.argv[1],\'pr\',\'checks\',\'77\',\'--watch\',\'--body\',\'fixture-secret-body\'])  # fixture-secret-payload" "{gh}"\n')
    survivor = s.spawn(["/bin/sh", str(parent), "pr", "checks", "42", "--watch"])
    ender = s.spawn(["/bin/sh", str(py_parent)])
    time.sleep(0.5)
    s.check("status before start reports stopped", json.loads(s.owner("status").stdout)["state"] == "stopped")
    first = json.loads(s.owner("start").stdout)
    s.check("start leaves a running owner", first.get("state") == "running", json.dumps(first))
    again = json.loads(s.owner("start").stdout)
    s.check("second start is idempotent (same run id, same pid)", again.get("run_id") == first.get("run_id") and again.get("pid") == first.get("pid"))
    s.check("second run refuses busy=75", s.owner("run", "--duration", "1").returncode == 75)
    s.check("records while the owner runs is busy=75", s.owner("records").returncode == 75)
    s.check("prune while the owner runs is busy=75", s.owner("prune").returncode == 75)
    mode = stat.S_IMODE(s.state.stat().st_mode), stat.S_IMODE((s.state / "observations.sqlite").stat().st_mode)
    s.check("private state modes", mode == (0o700, 0o600), oct(mode[0]) + " " + oct(mode[1]))
    time.sleep(20)
    s.log("killing the ending caller's group at about 20 s")
    s.kill(ender)
    time.sleep(27)
    s.check("stop exits 0", s.owner("stop").returncode == 0)
    s.check("status after stop reports stopped", json.loads(s.owner("status").stdout)["state"] == "stopped")
    try:
        os.kill(first["pid"], 0)
        s.check("owner pid gone after stop", False)
    except ProcessLookupError:
        s.check("owner pid gone after stop", True)
    rows = s.rows()
    keep = lambda r: r["kind"] not in ("process", "process_end") or r.get("ppid") in (survivor.pid, ender.pid) or (r["kind"] == "process" and r["argv"][:2] == ["node", "gh-axi"] and r["ppid"] == first["pid"]) or (r["kind"] == "process_end" and any(p["pid"] == r["pid"] and p["start"] == r["start"] and p.get("ppid") in (survivor.pid, ender.pid) for p in rows if p["kind"] == "process"))
    (EV / "smoke-records.jsonl").write_text("\n".join(json.dumps(r) for r in rows if keep(r)) + "\n")
    quota = [r for r in rows if r["kind"] == "quota"]
    seen = [r for r in quota if r["status"] == "observed"]
    s.check("at least 3 observed REST rows", len(seen) >= 3, f"{len(seen)} observed of {len(quota)}")
    for r in seen:
        s.log(f"  quota request_started_at={r['request_started_at']:.3f} source={r['source']!r} endpoint={r['endpoint']} graphql={r['graphql']}")
    s.check("rows carry used, reset, limit, remaining", all(set(r["graphql"]) == {"used", "reset", "limit", "remaining"} for r in seen))
    s.check("rows say REST rate_limit resources.graphql", all(r["source"] == "REST rate_limit resources.graphql" and r["endpoint"] == "rate_limit" for r in seen))
    gaps = [b["request_started_at"] - a["request_started_at"] for a, b in zip(seen, seen[1:])]
    s.check("request gap is about 15 s", all(14.5 <= g <= 16.5 for g in gaps), json.dumps([round(g, 3) for g in gaps]))
    sampling = [r for r in rows if r["kind"] == "sampling"]
    full = sampling[1:-1]
    s.log("  sampling rows: " + json.dumps([{k: (round(r[k], 3) if k == "max_gap_seconds" else r[k]) for k in ("scans", "failures", "max_gap_seconds")} for r in sampling]))
    s.check("real ps scans ran with 0 failures", sum(r["failures"] for r in sampling) == 0 and sum(r["scans"] for r in sampling) > 30)
    s.check("largest real scan gap inside the filed 0.5 s range in full intervals", all(r["max_gap_seconds"] <= 0.5 for r in full),
            json.dumps([round(r["max_gap_seconds"], 3) for r in full]))
    process = [r for r in rows if r["kind"] == "process"]
    ends = [r for r in rows if r["kind"] == "process_end"]
    named = lambda rs, word: [r for r in rs if r["argv"][:2] == ["sh", "gh"] and word in r["argv"]]
    long_rows = [r for r in process if r["argv"][:2] == ["sh", "gh"] and r["ppid"] == survivor.pid]
    s.check("survivor has a first sighting row and a stop row", len(long_rows) == 2, str(len(long_rows)))
    if long_rows:
        row = long_rows[0]
        s.log("  survivor row: " + json.dumps(row)[:900])
        s.check("survivor argv is sanitized", row["argv"] == ["sh", "gh", "pr", "checks", "[REDACTED]", "[REDACTED]", "--body", "[REDACTED]", "-H", "[REDACTED]", "[REDACTED]", "[REDACTED]"], json.dumps(row["argv"]))
        s.check("survivor ancestors name its real parent", row["ancestors"][0]["pid"] == survivor.pid and row["ancestors"][0]["argv"][:2] == ["sh", "caller-parent"])
        s.check("survivor row holds pid, start, timestamps, source, run id", all(row.get(k) for k in ("pid", "start", "observed_at", "first_observed_at", "run_id")) and row["argv_source"] == "ps-command-line-projection")
        s.check("stop row keeps first_observed_at and a later observed_at", long_rows[1]["first_observed_at"] == row["first_observed_at"] and long_rows[1]["observed_at"] > row["observed_at"])
        s.check("survivor has no end row", not [e for e in ends if e["pid"] == row["pid"] and e["start"] == row["start"]])
    ended_rows = [r for r in process if r["argv"][:2] == ["sh", "gh"] and r["ppid"] == ender.pid]
    s.check("ended caller has a process row", bool(ended_rows))
    if ended_rows:
        row = ended_rows[0]
        s.log("  python-parent ancestor argv: " + json.dumps(row["ancestors"][0]["argv"]))
        s.check("python -c payload withheld", "fixture-secret-payload" not in json.dumps(row))
        match = [e for e in ends if (e["pid"], e["start"], e["run_id"]) == (row["pid"], row["start"], row["run_id"])]
        s.check("ended caller has one joined end row", len(match) == 1, json.dumps(match)[:300])
        latest = [r for r in ended_rows]
        s.check("departure rows repeat the same projection", all(r["argv"] == row["argv"] and r["ancestors"] == row["ancestors"] for r in latest), f"{len(latest)} rows")
    axi = [r for r in process if "gh-axi" in " ".join(r["argv"][:2])]
    s.check("owner's own real gh-axi child is observed as a caller with its value withheld", bool(axi) and "[REDACTED]" in axi[0]["argv"], json.dumps(axi[0]["argv"]) if axi else "")
    assert_redacted(s, rows)
    owner_rows = [r for r in rows if r["kind"] == "owner"]
    s.check("owner rows mark start and stop with cadence", [r["action"] for r in owner_rows] == ["start", "stop"] and owner_rows[0]["quota_interval"] == 15.0 and owner_rows[0]["process_interval"] == 0.2)
    # A crash, then recovery by start.
    second = json.loads(s.owner("start").stdout)
    s.log(f"killing owner pid {second['pid']} with SIGKILL")
    os.kill(second["pid"], signal.SIGKILL)
    time.sleep(0.5)
    s.check("status after SIGKILL reports stopped", json.loads(s.owner("status").stdout)["state"] == "stopped")
    third = json.loads(s.owner("start").stdout)
    s.check("start after SIGKILL gives a new owner", third.get("run_id") not in (second["run_id"], None), third.get("run_id", ""))
    s.owner("stop")
    return s.finish()


def fake_axi_env(s, body):
    axi_dir = Path(tempfile.mkdtemp(prefix="fakebin.", dir=s.fix))
    path = axi_dir / "gh-axi"
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o700)
    return dict(s.env, PATH=f"{axi_dir}:{s.env['PATH']}")


def quotaerr():
    s = Scenario("quota-unavailable")
    cases = [
        ("missing gh-axi", dict(s.env, PATH="/usr/bin:/bin"), "unavailable", "command_unavailable"),
        ("gh-axi exits 1", fake_axi_env(s, "echo fail\nexit 1\n"), "unavailable", None),
        ("malformed body", fake_axi_env(s, "printf 'api_response:\\n  body: nonsense\\n'\n"), "unavailable", None),
        ("exhausted fixture", fake_axi_env(s, "printf 'api_response:\\n  body: used=5000 reset=1794000000 limit=5000 remaining=0\\n'\n"), "observed", None),
    ]
    for label, env, status, reason in cases:
        s.log(f"--- case: {label}")
        before = len(s.rows("quota"))
        reply = s.owner("run", "--duration", "16.5", env=env)
        s.check(f"{label}: owner run exits 0", reply.returncode == 0)
        rows = s.rows("quota")[before:]
        s.log("  " + json.dumps([{k: r.get(k) for k in ("status", "reason", "exit_code", "graphql")} for r in rows]))
        s.check(f"{label}: 2 ticks recorded {status}", len(rows) == 2 and all(r["status"] == status for r in rows))
        if reason:
            s.check(f"{label}: reason={reason}", all(r.get("reason") == reason for r in rows))
        if status == "unavailable":
            s.check(f"{label}: no zero or stale counter", all(not r.get("graphql") for r in rows))
        else:
            s.check(f"{label}: exhausted counters stored as read", all(r["graphql"] == {"used": 5000, "reset": 1794000000, "limit": 5000, "remaining": 0} for r in rows))
    sampling = s.rows("sampling")
    s.check("process sampling continued in every case", sum(r["scans"] for r in sampling) > 40 and sum(r["failures"] for r in sampling) == 0, f"scans={sum(r['scans'] for r in sampling)}")
    return s.finish()


CLOCK = """import os,runpy,sys,time
real=time.time
path=os.environ["CLOCK_OFFSET_FILE"]
def shifted():
    try:
        return real()+float(open(path).read() or 0)
    except (OSError,ValueError):
        return real()
time.time=shifted
script=sys.argv[1]
sys.argv=[script]+sys.argv[2:]
runpy.run_path(script,run_name="__main__")
"""


def cold_reader(rows):
    """Docs rule only: overlap = first_observed_at <= interval_end and (end >= interval_start or no end)."""
    quota = [r for r in rows if r["kind"] == "quota" and r["status"] == "observed"]
    process, ends = {}, {}
    for r in rows:
        key = (r.get("pid"), r.get("start"), r.get("run_id"))
        if r["kind"] == "process":
            process.setdefault(key, []).append(r)
        elif r["kind"] == "process_end":
            ends[key] = r
    report = []
    for a, b in zip(quota, quota[1:]):
        interval = {"start": a["observed_at"], "end": b["observed_at"], "used_delta": b["graphql"]["used"] - a["graphql"]["used"], "callers": []}
        for key, group in process.items():
            first = group[0]["first_observed_at"]
            end = ends.get(key)
            if first <= interval["end"] and (end is None or end["observed_at"] >= interval["start"]):
                interval["callers"].append({"pid": key[0], "argv": group[-1]["argv"], "parent": (group[-1]["ancestors"] or [{}])[0].get("argv"), "first_observed_at": first, "end": end and end["observed_at"], "ended": bool(end)})
        report.append(interval)
    return report


def clock():
    s = Scenario("clock-shift-attribution")
    launcher = s.fix / "clock.py"
    launcher.write_text(CLOCK)
    offset = s.fix / "offset"
    offset.write_text("0")
    used = s.fix / "used"
    used.write_text("100")
    env = fake_axi_env(s, f"printf 'api_response:\\n  body: used=%s reset=1794000000 limit=5000 remaining=1\\n' \"$(cat '{used}')\"\n")
    env["CLOCK_OFFSET_FILE"] = str(offset)
    gh, parent = s.callers()
    go = s.fix / "go-exec"
    continuous = s.spawn(["/bin/sh", str(parent), "pr", "checks", "1", "--watch"])
    execing = s.spawn(["/bin/sh", "-c", f'while [ ! -e "{go}" ]; do sleep 0.1; done; exec /bin/sh "{gh}" issue list --body fixture-secret-body'])
    time.sleep(0.5)
    owner = s.spawn([sys.executable, str(launcher), str(OWNER), "run"], env=env)
    start_row = lambda r: r["argv"][:2] == ["sh", "gh"] and r["ppid"] == continuous.pid
    first = wait(lambda: [r for r in db_rows(s, "process") if start_row(r)] if (s.state / "observations.sqlite").exists() else None, 10)
    s.check("continuous caller first sighted", bool(first))
    F = first[0]["first_observed_at"]
    offset.write_text("36000")
    s.log("clock moved to +36000 s; used fixture = 100")
    observed = lambda minimum: [r for r in db_rows(s, "quota") if r["status"] == "observed" and r["observed_at"] > F + minimum]
    wait(lambda: observed(36000), 20)
    used.write_text("4999")
    s.log("labeled quota transition: used fixture = 4999")
    wait(lambda: len(observed(36000)) >= 2, 20)
    in_window = observed(36000)[:2]
    s.check("two quota rows inside the later interval", len(in_window) == 2 and in_window[1]["graphql"]["used"] == 4999, json.dumps([(round(r["observed_at"] - F), r["graphql"]["used"]) for r in in_window]))
    offset.write_text("86500")
    s.log("clock moved to +86500 s: renewal is due; exec caller goes now")
    go.touch()
    renew = wait(lambda: [r for r in db_rows(s, "process") if start_row(r) and r["observed_at"] > F + 86000], 5)
    s.check("renewal row written for the caller alive past 24 h", len(renew or []) == 1)
    exec_row = wait(lambda: [r for r in db_rows(s, "process") if r["argv"][:2] == ["sh", "gh"] and "issue" in r["argv"]], 5)
    s.check("exec caller row appears after exec", bool(exec_row))
    offset.write_text("172901")
    s.log("clock moved to +172901 s: second renewal; next quota tick prunes the first sighting")
    wait(lambda: not [r for r in db_rows(s, "process") if start_row(r) and r["observed_at"] < F + 1000], 20)
    now_rows = [r for r in db_rows(s, "process") if start_row(r)]
    s.log("  continuous process rows now (offset from first sighting): " + json.dumps([round(r["observed_at"] - F) for r in now_rows]))
    s.check("first sighting expired by the owner's own 48 h prune", all(r["observed_at"] > F + 86000 for r in now_rows) and len(now_rows) == 2)
    s.check("no per-scan rows: exactly 2 renewals retained", len(now_rows) == 2)
    s.check("every renewal keeps first_observed_at and same projection", all(r["first_observed_at"] == F and r["argv"] == first[0]["argv"] and r["ancestors"] == first[0]["ancestors"] for r in now_rows))
    s.log("kill the continuous caller; keep the exec caller alive through stop")
    s.kill(continuous)
    wait(lambda: db_rows(s, "process_end") and [e for e in db_rows(s, "process_end") if e["pid"] == first[0]["pid"]], 5)
    s.log("send SIGTERM to the owner: a normal stop")
    owner.send_signal(signal.SIGTERM)
    s.check("owner exits 0 on SIGTERM", owner.wait(timeout=30) == 0)
    rows = s.rows(env=env, launcher=launcher)
    report = cold_reader(rows)
    fixture_pids = {first[0]["pid"], exec_row[0]["pid"]}
    (EV / "clock-records.jsonl").write_text("\n".join(json.dumps(r) for r in rows if r["kind"] not in ("process", "process_end") or r["pid"] in fixture_pids) + "\n")
    other = [{"interval": [round(i["start"] - F), round(i["end"] - F)], "used_delta": i["used_delta"], "fixture_callers": [c for c in i["callers"] if c["pid"] in fixture_pids], "other_host_callers_count": sum(c["pid"] not in fixture_pids for c in i["callers"])} for i in report]
    (EV / "clock-cold-reader.json").write_text(json.dumps(other, indent=1) + "\n")
    target = [i for i in report if i["start"] == in_window[0]["observed_at"] and i["end"] == in_window[1]["observed_at"]]
    s.check("cold reader finds the 4899-point interval", len(target) == 1 and target[0]["used_delta"] == 4899)
    if target:
        t = target[0]
        s.log("  interval (+%d..+%d) used_delta=%d" % (t["start"] - F, t["end"] - F, t["used_delta"]))
        for c in [c for c in t["callers"] if c["pid"] in fixture_pids]:
            s.log("    caller " + json.dumps({"argv": c["argv"], "parent": c["parent"], "first_offset": round(c["first_observed_at"] - F), "ended": c["ended"]}))
        pids = [c["pid"] for c in t["callers"]]
        retained = [r for r in rows if r["kind"] == "process" and r["pid"] == first[0]["pid"] and r["start"] == first[0]["start"]]
        s.check("every retained process timestamp is later than the interval", all(r["observed_at"] > t["end"] for r in retained), json.dumps([round(r["observed_at"] - F) for r in retained]))
        s.check("continuous caller overlaps through first_observed_at", first[0]["pid"] in pids)
        s.check("exec caller does not overlap the earlier interval", exec_row[0]["pid"] not in pids, f"exec pid {exec_row[0]['pid']} first offset {round(exec_row[0]['first_observed_at'] - F)}")
    end = [e for e in rows if e["kind"] == "process_end" and e["pid"] == first[0]["pid"]]
    s.check("continuous caller has one end row that joins a retained row", len(end) == 1 and any(r["kind"] == "process" and (r["pid"], r["start"], r["run_id"]) == (end[0]["pid"], end[0]["start"], end[0]["run_id"]) for r in rows))
    survivor_end = [e for e in rows if e["kind"] == "process_end" and e["pid"] == exec_row[0]["pid"]]
    survivor_rows = [r for r in rows if r["kind"] == "process" and r["pid"] == exec_row[0]["pid"]]
    s.check("exec caller still alive at stop has no end row and a stop row", not survivor_end and survivor_rows[-1]["observed_at"] > F + 172901 - 5, f"{len(survivor_rows)} rows")
    os_start = time.mktime(time.strptime(exec_row[0]["start"], "%a %b %d %H:%M:%S %Y"))
    s.check("exec caller: OS start predates first sighting of the run, first_observed_at follows the exec", os_start <= F and F + 86500 <= exec_row[0]["first_observed_at"] <= F + 86500 + 120,
            f"os_start-F={round(os_start - F)} first-F={round(exec_row[0]['first_observed_at'] - F)}")
    assert_redacted(s, rows)
    # Expiry through the public prune with the clock moved on.
    offset.write_text(str(172901 + 172800 + 60))
    pruned = s.owner("prune", env=env, launcher=launcher)
    after = s.rows(env=env, launcher=launcher)
    s.check("everything expires once all rows pass 48 h", pruned.returncode == 0 and after == [], f"{len(after)} rows left")
    return s.finish()


def retention():
    s = Scenario("retention-boundary")
    s.owner("prune")
    db = sqlite3.connect(s.state / "observations.sqlite")
    now = 1794000000.0
    cutoff = now - 48 * 3600
    seed = [("older", "quota", cutoff - 1, {}), ("at-boundary", "quota", cutoff, {}), ("newer", "quota", cutoff + 1, {}),
            ("older-owner", "owner", cutoff - 1, {}), ("older-sampling", "sampling", cutoff - 1, {}),
            ("plain-old-process", "process", cutoff - 1, {"pid": 1, "start": "a", "run_id": "r"}),
            ("old-process-end", "process_end", cutoff - 1, {"pid": 2, "start": "b", "run_id": "r"}),
            ("old-process-of-old-end", "process", cutoff - 2, {"pid": 2, "start": "b", "run_id": "r"}),
            ("ended-earlier-row", "process", cutoff - 5, {"pid": 3, "start": "c", "run_id": "r"}),
            ("ended-latest-row", "process", cutoff - 3, {"pid": 3, "start": "c", "run_id": "r"}),
            ("kept-end", "process_end", cutoff + 3, {"pid": 3, "start": "c", "run_id": "r"}),
            ("other-run-same-pid", "process", cutoff - 3, {"pid": 3, "start": "c", "run_id": "other"})]
    for label, kind, stamp, extra in seed:
        db.execute("INSERT INTO observations VALUES (?,?,?)", (stamp, kind, json.dumps(dict(extra, observed_at=stamp, kind=kind, label=label))))
    db.commit()
    db.close()
    sentinels = [s.state / "unrelated-sentinel", s.home / "state/unrelated-sentinel"]
    for path in sentinels:
        path.write_text("keep\n")
    launcher = s.fix / "clock.py"
    launcher.write_text(CLOCK)
    # Freeze at exactly now by offsetting; frozen launcher keeps the boundary exact.
    frozen = s.fix / "frozen.py"
    frozen.write_text(f"import runpy,sys,time\ntime.time=lambda:{now!r}\nscript=sys.argv[1]\nsys.argv=[script]+sys.argv[2:]\nrunpy.run_path(script,run_name='__main__')\n")
    before = sorted(r["label"] for r in s.rows(launcher=frozen))
    s.log("before: " + json.dumps(before))
    pruned = s.owner("prune", launcher=frozen)
    after = sorted(r["label"] for r in s.rows(launcher=frozen))
    s.log("after: " + json.dumps(after))
    s.check("removed count is 8 (the 8 rows older than the cutoff that no retained end row keeps)", json.loads(pruned.stdout)["removed"] == 8, pruned.stdout.strip())
    expected = sorted(["at-boundary", "newer", "kept-end", "ended-latest-row"])
    s.check("exact survivors", after == expected, f"want {expected}")
    s.check("unrelated state stays", all(path.read_text() == "keep\n" for path in sentinels))
    return s.finish()


def dbguard():
    s = Scenario("database-guard")
    path = s.state / "observations.sqlite"
    s.state.mkdir(parents=True, mode=0o700, exist_ok=True)
    env = fake_axi_env(s, "printf 'api_response:\\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\\n'\n")
    path.write_bytes(b"")
    s.log("--- zero-size file")
    reply = s.owner("start", env=env)
    s.check("zero-size database: start succeeds", reply.returncode == 0)
    s.owner("stop", env=env)
    app = sqlite3.connect(path).execute("PRAGMA application_id").fetchone()[0]
    s.check("zero-size database becomes this owner's database", app == 0x464D4748, hex(app))
    os.rename(path, s.fix / "owned.sqlite")
    s.log("--- nonempty non-database file")
    path.write_bytes(b"operator data, not sqlite\n" * 4)
    original = path.read_bytes()
    for command in ("start", "prune", "records"):
        reply = s.owner(command, env=env)
        s.check(f"text file: {command} exits 1", reply.returncode == 1)
    s.check("text file: bytes unchanged", path.read_bytes() == original)
    os.unlink(path)
    s.log("--- foreign sqlite database")
    foreign = sqlite3.connect(path)
    foreign.execute("CREATE TABLE theirs (x)")
    foreign.execute("INSERT INTO theirs VALUES ('keep')")
    foreign.commit()
    foreign.close()
    original = path.read_bytes()
    for command in ("start", "prune", "records"):
        reply = s.owner(command, env=env)
        s.check(f"foreign: {command} exits 1", reply.returncode == 1)
    s.check("foreign: bytes unchanged", path.read_bytes() == original)
    log = (s.state / "owner.log").read_text() if (s.state / "owner.log").exists() else ""
    s.log("owner.log: " + log.strip()[-200:])
    s.check("failed start names the fixed reason in owner.log and no path text", "operation unavailable" in log)
    os.unlink(path)
    s.log("--- symlink database")
    target = s.fix / "target.sqlite"
    target.write_bytes(b"")
    path.symlink_to(target)
    reply = s.owner("start", env=env)
    s.check("symlink: start exits 1 and target unchanged", reply.returncode == 1 and target.read_bytes() == b"")
    os.unlink(path)
    return s.finish()


fail = 0
for name in sys.argv[3:]:
    fail += {"smoke": smoke, "quotaerr": quotaerr, "clock": clock, "retention": retention, "dbguard": dbguard}[name]()
print("TOTAL FAILURES", fail)
sys.exit(1 if fail else 0)
