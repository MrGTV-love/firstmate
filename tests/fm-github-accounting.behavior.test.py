#!/usr/bin/env python3
"""Behavioral observer regressions with labeled local process/quota inputs only."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

OWNER = Path(__file__).resolve().parents[1] / "bin/fm-github-accounting.py"


class ObserverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fm-github-accounting-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        self.state = self.root / "state"
        self.state.mkdir()
        self.env = dict(os.environ, PATH=str(self.fakebin) + os.pathsep + os.environ["PATH"],
                        FM_STATE_OVERRIDE=str(self.state), PYTHONDONTWRITEBYTECODE="1",
                        FIXTURE_ROOT=str(self.root))
        self.tool("ps", "printf '%s\\n' '100 0 Sun Nov  1 13:00:00 2026 /fixture/parent'\n")
        self.tool("gh-axi", "printf 'api_response:\\n  body: used=23 reset=1794000000 limit=5000 remaining=4977\\n'\n")

    def tool(self, name, body):
        path = self.fakebin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o700)

    def cli(self, *args, check=True):
        reply = subprocess.run([sys.executable, str(OWNER), *args], env=self.env, capture_output=True, text=True)
        if check:
            self.assertEqual(reply.returncode, 0, (args, reply.stdout, reply.stderr))
        return reply

    def records(self, kind):
        return [json.loads(line) for line in self.cli("records", "--kind", kind).stdout.splitlines()]

    def scaled_owner(self, duration, hung_ps=False, setup="", source="lambda:{}"):
        # A labeled scaled clock runs the real 15 s cadence and a labeled 30 s
        # no-progress interval twenty times faster. The real ps samples CPU.
        env = dict(self.env, FM_DURATION_NO_PROGRESS_SECS="30")
        if hung_ps:
            env["FM_PROC_ROOT_OVERRIDE"] = str(self.root / "no-proc")
        else:
            (self.fakebin / "ps").unlink()
        launcher = self.root / "scaled-clock.py"
        launcher.write_text(f'''import os,runpy,signal,sys,time
{setup}
scale=20.0
real_monotonic,real_sleep=time.monotonic,time.sleep
base=real_monotonic()
time.monotonic=lambda: base+(real_monotonic()-base)*scale
time.sleep=lambda seconds: real_sleep(seconds/scale)
owner=runpy.run_path(sys.argv[1])
owner["run"](owner["private_root"](),duration={duration},process_source={source})
''')
        reply = subprocess.run([sys.executable, str(launcher), str(OWNER)], capture_output=True, text=True, timeout=120,
                               env=env)
        self.assertEqual(reply.returncode, 0, reply.stderr)
        return self.records("quota")

    def prune_at(self, now):
        launcher = self.root / "clock.py"
        launcher.write_text(f"import sys,time,runpy\ntime.time=lambda:{now!r}\nsys.argv=[sys.argv[1],'prune']\nrunpy.run_path(sys.argv[0],run_name='__main__')\n")
        reply = subprocess.run([sys.executable, str(launcher), str(OWNER)], env=self.env, capture_output=True, text=True)
        self.assertEqual(reply.returncode, 0, reply.stderr)
        return json.loads(reply.stdout)["removed"]

    def assertProcessGone(self, pid):
        # A killed orphan can briefly remain a zombie; /proc on Linux or the
        # existing native identity table on Darwin distinguishes it from live.
        import runpy
        from types import SimpleNamespace
        shared = SimpleNamespace(**runpy.run_path(str(OWNER.with_name("fm-proc-budget-tree.py"))))
        rows = shared.Table().read()
        self.assertTrue(pid not in rows or rows[pid][3], f"process {pid} survived")

    def test_reused_pid_ancestry_and_private_arguments(self):
        self.tool("ps", '''n=0
[ ! -e "$FIXTURE_ROOT/count" ] || n=$(cat "$FIXTURE_ROOT/count")
n=$((n+1)); printf '%s' "$n" > "$FIXTURE_ROOT/count"
case "$n" in 1) born=01 ;; *) born=02 ;; esac
printf '%s\n' "201 100 Sun Nov  1 13:00:$born 2026 /fixture/gh pr checks --body fixture-secret-one --header Authorization:fixture-secret-two" \
'202 999 Sun Nov  1 13:00:03 2026 /fixture/gh-axi api rate_limit --field payload=fixture-secret-three' \
'100 0 Sun Nov  1 13:00:00 2026 /bin/sh /fixture/caller.sh -c fixture-secret-four'
''')
        self.cli("run", "--duration", "1.8")
        rows = self.records("process")
        self.assertEqual([(row["pid"], row["start"]) for row in rows], [
            (201, "Sun Nov 1 13:00:01 2026"), (202, "Sun Nov 1 13:00:03 2026"),
            (201, "Sun Nov 1 13:00:02 2026")])
        self.assertEqual([(row["pid"], row["start"]) for row in self.records("process_end")],
                         [(201, "Sun Nov 1 13:00:01 2026")])
        first = rows[0]
        self.assertEqual(first["argv"][:3], ["gh", "pr", "checks"])
        self.assertEqual(first["ancestors"][0]["pid"], 100)
        self.assertEqual(first["ancestor_end"], "root")
        missing = rows[1]
        self.assertEqual(missing["ancestors"], [])
        self.assertEqual(missing["ancestor_end"], "unobserved")
        self.assertNotIn("fixture-secret", json.dumps(rows))
        self.assertEqual(self.records("quota")[0]["graphql"]["used"], 23)

    def test_injected_tables_filter_script_identity_and_ancestor_cycles(self):
        # Labeled table fixtures exercise the actual owner/filter/storage path,
        # not a subprocess stub claiming that these are observed OS processes.
        launcher = self.root / "injected-table.py"
        launcher.write_text('''import runpy,sys
owner=runpy.run_path(sys.argv[1])
scans=0
def source():
    global scans
    scans+=1
    born="fixture-start-one" if scans==1 else "fixture-start-two"
    return {
      21:(10,born,["/bin/sh","/fixture/gh","pr","checks","--body","fixture-secret"]),
      22:(10,"fixture-wrapper",["/bin/sh","-c","gh api graphql"]),
      23:(0,"fixture-noncaller",["/fixture/other","gh-axi"]),
      10:(9,"fixture-parent",["python3","/fixture/parent.py","fixture-secret"]),
      9:(10,"fixture-grandparent",["/bin/sh","/fixture/root.sh"])}
owner["run"](owner["private_root"](),duration=0.8,process_source=source)
''')
        reply = subprocess.run([sys.executable, str(launcher), str(OWNER)], env=self.env, capture_output=True, text=True)
        self.assertEqual(reply.returncode, 0, reply.stderr)
        rows = self.records("process")
        self.assertEqual([(row["pid"], row["start"]) for row in rows],
                         [(21, "fixture-start-one"), (21, "fixture-start-two")])
        for row in rows:
            self.assertEqual(row["argv"], ["sh", "gh", "pr", "checks", "--body", "[REDACTED]"])
            self.assertEqual([item["pid"] for item in row["ancestors"]], [10, 9])
            self.assertEqual(row["ancestors"][0]["argv"], ["python3", "parent.py", "[REDACTED]"])
            self.assertEqual(row["ancestor_end"], "cycle")
        self.assertNotIn("fixture-secret", json.dumps(rows))

    def test_caller_outliving_quota_intervals_has_an_end_row_and_a_survivor_has_none(self):
        # Labeled table: 71 lives until the fourth quota request starts, one scan
        # then fails, and later scans omit 71. 70 is listed until the owner stops.
        self.tool("gh-axi", '''printf 'x\\n' >> "$FIXTURE_ROOT/requests"
printf 'api_response:\\n  body: used=23 reset=1794000000 limit=5000 remaining=4977\\n'
''')
        setup = '''after=0
def source():
    global after
    requests=os.path.join(os.environ["FIXTURE_ROOT"],"requests")
    table={70:(0,"fixture-survivor",["/fixture/gh","pr","checks","--watch"])}
    if not os.path.exists(requests) or len(open(requests).readlines())<4:
        table[71]=(0,"fixture-ender",["/fixture/gh","pr","checks","--watch"])
        return table
    after+=1
    if after==1:
        raise RuntimeError("fixture scan failure")
    if after==4:
        os.kill(os.getpid(),signal.SIGTERM)
    return table
'''
        quota = [row for row in self.scaled_owner(None, setup=setup, source="source") if row["status"] == "observed"]
        rows = self.records("process")
        self.assertEqual(sorted(row["pid"] for row in rows), [70, 71])
        ended = self.records("process_end")
        self.assertEqual([(row["pid"], row["start"]) for row in ended], [(71, "fixture-ender")])
        end = ended[0]
        self.assertEqual(set(end), {"pid", "start", "run_id", "observed_at", "kind"})
        began = next(row for row in rows if row["pid"] == 71)
        self.assertEqual(end["run_id"], began["run_id"])
        self.assertLess(began["observed_at"], quota[1]["observed_at"])
        self.assertLess(quota[2]["observed_at"], end["observed_at"])
        self.assertGreaterEqual(sum(row["failures"] for row in self.records("sampling")), 1)
        self.assertEqual(self.records("owner")[-1]["action"], "stop")
        self.prune_at(end["observed_at"] + 172799)
        self.assertEqual(len(self.records("process_end")), 1)
        self.assertGreaterEqual(self.prune_at(end["observed_at"] + 172801), 1)
        self.assertEqual(self.records("process_end"), [])

    def test_live_caller_keeps_joinable_rows_across_retention_and_departure(self):
        # A controlled clock crosses 48 h while the same two caller identities
        # remain visible. Later argv/ancestor changes must not replace the saved
        # sanitized first-sighting projection when its process row is renewed.
        launcher = self.root / "retention-clock.py"
        launcher.write_text('''import os,runpy,signal,sys,time
base=1794000000
elapsed=0
real_monotonic=time.monotonic
time.time=lambda:base+elapsed
time.monotonic=lambda:real_monotonic()+elapsed
owner=runpy.run_path(sys.argv[1])
scans=0
def source():
    global scans,elapsed
    offsets=[0,1,86401,172801,172802,172803]
    elapsed=offsets[min(scans,len(offsets)-1)]
    scans+=1
    argv=["/fixture/gh","pr","checks","--body","fixture-secret"] if scans<3 else ["/fixture/gh","issue","list"]
    table={70:(10,"fixture-survivor",argv),
           10:(0,"fixture-parent",["python3","/fixture/original.py" if scans<3 else "/fixture/changed.py"])}
    if scans<5:
        table[71]=(10,"fixture-ender",argv)
    if scans>=6:
        os.kill(os.getpid(),signal.SIGTERM)
    return table
owner["run"](owner["private_root"](),process_source=source)
''')
        reply = subprocess.run([sys.executable, str(launcher), str(OWNER)], env=self.env, capture_output=True, text=True)
        self.assertEqual(reply.returncode, 0, reply.stderr)
        rows = self.records("process")
        self.assertEqual([(row["pid"], row["observed_at"] - 1794000000) for row in rows],
                         [(70, 86401), (71, 86401), (70, 172801), (71, 172801)])
        for row in rows:
            self.assertEqual(row["argv"], ["gh", "pr", "checks", "--body", "[REDACTED]"])
            self.assertEqual(row["ancestors"], [{"pid": 10, "ppid": 0, "start": "fixture-parent",
                                                  "argv": ["python3", "original.py"]}])
        self.assertNotIn("fixture-secret", json.dumps(rows))
        ended = self.records("process_end")
        self.assertEqual([(row["pid"], row["start"]) for row in ended], [(71, "fixture-ender")])
        end = ended[0]
        began = [row for row in rows if (row["pid"], row["start"], row["run_id"]) ==
                 (end["pid"], end["start"], end["run_id"])]
        self.assertEqual(end["observed_at"] - 1794000000, 172802)
        self.assertEqual(began[-1]["observed_at"] - 1794000000, 172801)
        self.assertEqual(self.records("owner")[-1]["action"], "stop")
        # Renewal does not exempt either row kind from the original retention.
        self.prune_at(end["observed_at"] + 172801)
        self.assertEqual(self.records("process"), [])
        self.assertEqual(self.records("process_end"), [])

    def test_cold_reader_distinguishes_continuous_caller_from_later_exec(self):
        # Labeled clock/table/quota inputs exercise the real owner and public
        # records. The same PID/start exists before it execs into gh at 86401.
        self.tool("gh-axi", '''while [ ! -e "$FIXTURE_ROOT/release-quota" ]; do sleep 0.01; done
printf 'api_response:\\n  body: used=23 reset=1794000000 limit=5000 remaining=4977\\n'
''')
        launcher = self.root / "cold-reader-clock.py"
        launcher.write_text('''import json,os,runpy,signal,sqlite3,sys,time
from pathlib import Path
base=1794000000
elapsed=0
real_monotonic=time.monotonic
time.time=lambda:base+elapsed
time.monotonic=lambda:real_monotonic()+elapsed
owner=runpy.run_path(sys.argv[1])
root=owner["private_root"]()
step=0
def source():
    global step,elapsed
    offsets=[35999,36000,36020,86401,122400,172802,172803,172804]
    elapsed=offsets[step]
    if elapsed>=36000:
        Path(os.environ["FIXTURE_ROOT"],"release-quota").touch()
    advance=True
    if elapsed in (36000,36020):
        with sqlite3.connect(root/"observations.sqlite") as db:
            quota=[json.loads(row[0]) for row in db.execute("SELECT payload FROM observations WHERE kind='quota'")]
        advance=any(row.get("status")=="observed" and row["observed_at"]==base+elapsed for row in quota)
    table={10:(0,"fixture-parent",["python3","/fixture/caller.py","fixture-secret"]),
           72:(10,"fixture-survivor",["/fixture/gh","pr","checks"])}
    if elapsed<172803:
        table[70]=(10,"fixture-continuous",["/fixture/gh","pr","checks"])
        table[71]=(10,"fixture-exec",["/fixture/other"] if elapsed<86401 else ["/fixture/gh","issue","list"])
    if step==len(offsets)-1:
        os.kill(os.getpid(),signal.SIGTERM)
    elif advance:
        step+=1
    return table
owner["run"](root,process_source=source)
''')
        reply = subprocess.run([sys.executable, str(launcher), str(OWNER)], env=self.env, capture_output=True, text=True)
        self.assertEqual(reply.returncode, 0, reply.stderr)
        base = 1794000000
        self.prune_at(base + 172804)
        quota = [row for row in self.records("quota") if row.get("status") == "observed"]
        interval_start, interval_end = base + 36000, base + 36020
        self.assertTrue(any(row["observed_at"] == interval_start for row in quota), quota)
        self.assertTrue(any(row["observed_at"] == interval_end for row in quota), quota)
        # At 172804 the original 35999 row is still within 48 h. Move to
        # cutoff=36000 too, when that row expires but both quota rows remain.
        self.prune_at(base + 208800)
        processes = self.records("process")
        self.assertTrue(all(row["observed_at"] > interval_end for row in processes), processes)
        ended = self.records("process_end")
        self.assertEqual(sorted(row["pid"] for row in ended), [70, 71])
        joined = []
        for end in ended:
            candidates = [row for row in processes if (row["pid"], row["start"], row["run_id"]) ==
                          (end["pid"], end["start"], end["run_id"])]
            self.assertTrue(candidates, end)
            first = {row["first_observed_at"] for row in candidates}
            self.assertEqual(first, {base + (35999 if end["pid"] == 70 else 86401)})
            if min(first) <= interval_end and end["observed_at"] >= interval_start:
                joined.append(end["pid"])
        self.assertEqual(joined, [70])
        self.assertNotIn("fixture-secret", json.dumps(processes))
        self.assertTrue(all(row["ancestors"][0]["argv"] == ["python3", "caller.py", "[REDACTED]"]
                            for row in processes))
        self.assertEqual(self.records("owner")[-1]["action"], "stop")
        self.prune_at(base + 172803 + 172801)
        self.assertEqual(self.records("process"), [])
        self.assertEqual(self.records("process_end"), [])

    def test_interpreter_flags_keep_script_names_and_withhold_payloads(self):
        launcher = self.root / "injected-forms.py"
        launcher.write_text('''import runpy,sys
owner=runpy.run_path(sys.argv[1])
forms=[
  ["/Library/Developer/MacOS/Python","/fixture/fm-caller.py","fixture-secret"],
  ["/fixture/bin/python","-u","/fixture/fm-caller.py"],
  ["/bin/bash","-eu","/fixture/fm-caller.sh"],
  ["/bin/bash","-eu","-c","fixture-secret"],
  ["/bin/bash","-ec","fixture-secret"],
  ["python3.11","-m","fixture-secret"],
  ["node","-e","fixture-secret"],
  ["perl","-E","fixture-secret"],
  ["ruby","-I","fixture-secret","/fixture/caller.rb"],
  ["bash","-s","fixture-secret"],
]
table={50:(100,"fixture-start",["node","--no-warnings","/opt/homebrew/bin/gh-axi","api","graphql"]),
       60:(0,"fixture-noncaller",["node","-e","gh-axi"]),
       61:(0,"fixture-noncaller",["python3","-c","gh"]),
       62:(0,"fixture-noncaller",["node","--inspect=9229","/fixture/gh"])}
for index,form in enumerate(forms):
    table[100+index]=(101+index if index+1<len(forms) else 0,"fixture-start",form)
owner["run"](owner["private_root"](),duration=0.5,process_source=lambda:table)
''')
        reply = subprocess.run([sys.executable, str(launcher), str(OWNER)], env=self.env, capture_output=True, text=True)
        self.assertEqual(reply.returncode, 0, reply.stderr)
        rows = self.records("process")
        self.assertEqual([row["pid"] for row in rows], [50])
        self.assertEqual(rows[0]["argv"], ["node", "--no-warnings", "gh-axi", "api", "graphql"])
        self.assertEqual([item["argv"] for item in rows[0]["ancestors"]], [
            ["Python", "fm-caller.py", "[REDACTED]"],
            ["python", "-u", "fm-caller.py"],
            ["bash", "-eu", "fm-caller.sh"],
            ["bash", "-eu", "-c", "[REDACTED]"],
            ["bash", "[REDACTED]", "[REDACTED]"],
            ["python3.11", "-m", "[REDACTED]"],
            ["node", "[REDACTED]", "[REDACTED]"],
            ["perl", "[REDACTED]", "[REDACTED]"],
            ["ruby", "[REDACTED]", "[REDACTED]", "[REDACTED]"],
            ["bash", "[REDACTED]", "[REDACTED]"],
        ])
        self.assertNotIn("fixture-secret", json.dumps(rows))

    def test_quiet_quota_request_is_killed_and_the_next_tick_sends_a_new_one(self):
        self.tool("gh-axi", '''n=0
[ ! -e "$FIXTURE_ROOT/count" ] || n=$(cat "$FIXTURE_ROOT/count")
n=$((n+1)); printf '%s' "$n" > "$FIXTURE_ROOT/count"
if [ -e "$FIXTURE_ROOT/request-pid" ] && kill -0 "$(cat "$FIXTURE_ROOT/request-pid")" 2>/dev/null; then
  : > "$FIXTURE_ROOT/overlap"
fi
printf '%s' "$$" > "$FIXTURE_ROOT/request-pid"
if [ "$n" = 1 ]; then
  sleep 600 &
  printf '%s' "$!" > "$FIXTURE_ROOT/quota-child"
  wait
fi
printf 'api_response:\\n  body: used=23 reset=1794000000 limit=5000 remaining=4977\\n'
''')
        rows = self.scaled_owner(100)
        expired = [index for index, row in enumerate(rows) if row.get("reason") == "timeout"]
        self.assertEqual(len(expired), 1, rows)
        timeout = rows[expired[0]]
        self.assertEqual((timeout["status"], timeout["graphql"], timeout["exit_code"]), ("unavailable", {}, -9))
        self.assertIn("pending", [row["status"] for row in rows[:expired[0]]])
        later = rows[expired[0] + 1:]
        self.assertEqual(later[0]["status"], "observed", rows)
        self.assertGreaterEqual(later[0]["request_started_at"] - timeout["request_started_at"], 30 / 20)
        self.assertFalse((self.root / "overlap").exists(), "a new request overlapped the timed-out one")
        self.assertProcessGone(int((self.root / "quota-child").read_text()))

    def test_quota_request_still_using_cpu_is_not_killed(self):
        self.tool("gh-axi", '''end=$(( $(date +%s) + 3 ))
while [ "$(date +%s)" -lt "$end" ]; do :; done
printf 'api_response:\\n  body: used=23 reset=1794000000 limit=5000 remaining=4977\\n'
''')
        rows = self.scaled_owner(200)
        self.assertEqual([row for row in rows if row.get("reason") == "timeout"], [], rows)
        self.assertIn("observed", [row["status"] for row in rows])

    def test_quiet_ps_is_killed_and_does_not_stop_the_quota_stream(self):
        # Only the owner's table read hangs; the shared CPU sampler reads the real ps.
        self.tool("ps", f'''[ "$1" != -axo ] || {{ printf '%s' "$$" > "$FIXTURE_ROOT/ps-pid"; exec sleep 600; }}
exec {shutil.which("ps")} "$@"
''')
        self.tool("gh-axi", ''': > "$FIXTURE_ROOT/quota-asked"
printf 'api_response:\\n  body: used=23 reset=1794000000 limit=5000 remaining=4977\\n'
''')
        reply = subprocess.run([sys.executable, str(OWNER), "run", "--duration", "6"], capture_output=True, text=True,
                               timeout=60, env=dict(self.env, FM_DURATION_NO_PROGRESS_SECS="1"))
        self.assertEqual(reply.returncode, 0, reply.stderr)
        self.assertGreaterEqual(sum(row["failures"] for row in self.records("sampling")), 1)
        self.assertTrue((self.root / "quota-asked").exists(), "the hung ps blocked the quota stream")
        self.assertProcessGone(int((self.root / "ps-pid").read_text()))

    def hung_ps_fixture(self):
        self.tool("ps", '''printf '%s\\n' "$$" >> "$FIXTURE_ROOT/ps-pids"
exec sleep 600
''')

    def assertHungPsEnded(self):
        pids = [int(line) for line in (self.root / "ps-pids").read_text().splitlines()]
        self.assertTrue(pids)
        for pid in pids:
            self.assertProcessGone(pid)
        return pids

    def test_ps_hung_for_the_cpu_sampler_too_leaves_quota_and_stop_working(self):
        self.hung_ps_fixture()
        reply = subprocess.run([sys.executable, str(OWNER), "run", "--duration", "3"], env=self.env,
                               capture_output=True, text=True, timeout=60)
        self.assertEqual(reply.returncode, 0, reply.stderr)
        self.assertIn("observed", [row["status"] for row in self.records("quota")])
        self.assertHungPsEnded()

    def test_hung_ps_does_not_grow_verdicts_across_repeated_requests(self):
        # A request lasting past the first CPU sample reaches the hung ps: the missing
        # proc root sends the sampler to ps on every host, and the injected table keeps
        # this count to the quota verdict's own samples.
        self.hung_ps_fixture()
        self.tool("gh-axi", '''printf 'x\\n' >> "$FIXTURE_ROOT/requests"
sleep 0.3
printf 'api_response:\\n  body: used=23 reset=1794000000 limit=5000 remaining=4977\\n'
''')
        rows = self.scaled_owner(100, hung_ps=True)
        requests = len((self.root / "requests").read_text().splitlines())
        self.assertGreaterEqual(requests, 3, rows)
        self.assertGreaterEqual([row["status"] for row in rows].count("observed"), 3, rows)
        self.assertEqual(len(self.assertHungPsEnded()), 1, f"{requests} requests")

    def test_malformed_quota_is_unavailable_not_zero(self):
        self.tool("gh-axi", "printf 'api_response:\\n  body: used=null reset=null limit=5000 remaining=0\\n'\n")
        self.cli("run", "--duration", "0.8")
        row = self.records("quota")[0]
        self.assertEqual(row["status"], "unavailable")
        self.assertEqual(row["graphql"], {})
        self.assertEqual(row["source"], "REST rate_limit resources.graphql")

    def test_retention_exact_boundary_and_unrelated_state(self):
        self.cli("prune")
        sentinel = self.state / "unrelated"
        sentinel.write_text("keep")
        db = sqlite3.connect(self.state / "github-accounting/observations.sqlite")
        now = 1794000000
        for delta in (-1, 0, 1):
            stamp = now - 172800 + delta
            db.execute("INSERT INTO observations VALUES (?,?,?)", (stamp, "fixture", json.dumps({"delta": delta})))
        db.commit()
        db.close()
        self.assertEqual(self.prune_at(now), 1)
        self.assertEqual([row["delta"] for row in self.records("fixture")], [0, 1])
        self.assertEqual(sentinel.read_text(), "keep")

    def test_single_owner_and_stop_private_quota_group(self):
        self.tool("gh-axi", '''sleep 60 &
printf '%s' "$!" > "$FIXTURE_ROOT/quota-child"
wait
''')
        try:
            first = json.loads(self.cli("start").stdout)
            second = json.loads(self.cli("start").stdout)
            self.assertEqual(first["run_id"], second["run_id"])
            self.assertNotEqual(self.cli("run", "--duration", "0.1", check=False).returncode, 0)
            # Wait for the fixture child to exist, not for a guessed warm-up.
            while not (self.root / "quota-child").exists():
                self.assertEqual(json.loads(self.cli("status").stdout)["state"], "running")
                time.sleep(0.01)
            sleeper = int((self.root / "quota-child").read_text())
        finally:
            self.cli("stop")
        self.assertEqual(json.loads(self.cli("status").stdout)["state"], "stopped")
        self.assertProcessGone(sleeper)

    def test_detached_failure_reaches_the_owner_log(self):
        root = self.state / "github-accounting"
        root.mkdir()
        db = sqlite3.connect(root / "observations.sqlite")
        db.execute("CREATE TABLE unrelated(value)")
        db.commit()
        db.close()
        self.assertEqual(self.cli("start", check=False).returncode, 1)
        self.assertIn("operation unavailable", (root / "owner.log").read_text())
        self.assertEqual(json.loads(self.cli("status").stdout)["state"], "stopped")

    def test_owner_log_is_trimmed_to_its_newest_bytes_at_launch(self):
        root = self.state / "github-accounting"
        root.mkdir()
        log = root / "owner.log"
        limit = 64 * 1024
        log.write_bytes(b"oldest" + b"x" * (limit * 2) + b"newest")
        try:
            self.cli("start")
        finally:
            self.cli("stop")
        kept = log.read_bytes()
        self.assertLessEqual(len(kept), limit)
        self.assertTrue(kept.endswith(b"newest"))
        self.assertNotIn(b"oldest", kept)

    def test_concurrent_starts_share_one_owner(self):
        starts = [subprocess.Popen([sys.executable, str(OWNER), "start"], env=self.env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(4)]
        try:
            replies = [(start.communicate(), start.returncode) for start in starts]
            codes = [code for _, code in replies]
            self.assertIn(0, codes, replies)
            self.assertLessEqual(set(codes), {0, 75}, replies)
            running = json.loads(self.cli("status").stdout)
            self.assertEqual(running["state"], "running")
        finally:
            self.cli("stop")
        owners = self.records("owner")
        self.assertEqual([row["run_id"] for row in owners if row["action"] == "start"], [running["run_id"]])

    def test_start_during_a_real_read_is_busy_never_stale_running(self):
        first = json.loads(self.cli("start").stdout)
        self.cli("stop")
        db = sqlite3.connect(self.state / "github-accounting/observations.sqlite")
        db.executemany("INSERT INTO observations VALUES (?,?,?)",
                       ((time.time() + row, "fixture", json.dumps({"row": row, "padding": "x" * 200})) for row in range(2000)))
        db.commit()
        db.close()
        # An unread pipe keeps this real reader inside its result loop, holding the lock.
        reader = subprocess.Popen([sys.executable, str(OWNER), "records"], env=self.env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            self.assertTrue(reader.stdout.readline())
            reply = self.cli("start", check=False)
            self.assertEqual(reply.returncode, 75, (reply.stdout, reply.stderr))
            self.assertNotIn("running", reply.stdout)
            self.assertNotIn("operation unavailable", reply.stderr)
            self.assertEqual(json.loads(self.cli("status").stdout)["state"], "stopped")
        finally:
            reader.kill()
            reader.communicate()
        try:
            second = json.loads(self.cli("start").stdout)
            self.assertEqual(second["state"], "running")
            self.assertNotEqual(second["run_id"], first["run_id"])
        finally:
            self.cli("stop")

    def test_start_meeting_a_held_start_or_claimed_owner_lock_is_busy(self):
        root = self.state / "github-accounting"
        root.mkdir()
        for name in ("start.lock", "owner.lock"):
            with open(root / name, "w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                reply = self.cli("start", check=False)
                self.assertEqual(reply.returncode, 75, (name, reply.stdout, reply.stderr))
                self.assertEqual(reply.stdout, "")

    def test_zero_size_database_is_treated_as_new(self):
        root = self.state / "github-accounting"
        root.mkdir()
        path = root / "observations.sqlite"
        for command in ("prune", "start"):
            with self.subTest(command=command):
                path.write_bytes(b"")
                self.assertEqual(self.cli(command, check=False).returncode, 0)
                if command == "start":
                    self.cli("stop")
                db = sqlite3.connect(path)
                self.assertEqual(db.execute("PRAGMA application_id").fetchone()[0], 0x464D4748)
                db.close()
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                path.unlink()

    def test_nonempty_non_database_file_is_refused_unchanged(self):
        root = self.state / "github-accounting"
        root.mkdir()
        path = root / "observations.sqlite"
        path.write_bytes(b"not a database")
        for command in ("start", "prune", "records"):
            with self.subTest(command=command):
                self.assertEqual(self.cli(command, check=False).returncode, 1)
                self.assertEqual(path.read_bytes(), b"not a database")

    def test_symlink_and_foreign_database_are_not_modified(self):
        root = self.state / "github-accounting"
        root.mkdir()
        target = self.root / "unrelated-target"
        target.write_text("untouched")
        (root / "observations.sqlite").symlink_to(target)
        self.assertNotEqual(self.cli("prune", check=False).returncode, 0)
        self.assertEqual(target.read_text(), "untouched")
        (root / "observations.sqlite").unlink()
        db = sqlite3.connect(root / "observations.sqlite")
        db.execute("CREATE TABLE unrelated(value)")
        db.execute("INSERT INTO unrelated VALUES ('keep')")
        db.commit()
        db.close()
        self.assertNotEqual(self.cli("prune", check=False).returncode, 0)
        db = sqlite3.connect(root / "observations.sqlite")
        self.assertEqual(db.execute("SELECT value FROM unrelated").fetchall(), [("keep",)])
        db.close()


if __name__ == "__main__":
    unittest.main()
