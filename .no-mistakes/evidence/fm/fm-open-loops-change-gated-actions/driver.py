#!/usr/bin/env python3
"""Live driver: runs the real bin/fm-wake-drain.sh, bin/fm-open-loops.sh and bin/fm-watch.sh
against disposable marked lab homes (bin/fm-lab-home.sh env), one per scenario.
Rows are published into state/open-loops.json the way a heartbeat publishes them.
Writes a transcript per scenario next to this script and prints PASS/FAIL lines."""
import datetime as dt, json, os, re, shlex, subprocess, sys, time
from pathlib import Path

REPO = Path(sys.argv[1]).resolve()
OUT = Path(__file__).resolve().parent
BIN = REPO / "bin"
LOOPS, DRAIN, WATCH = BIN / "fm-open-loops.sh", BIN / "fm-wake-drain.sh", BIN / "fm-watch.sh"
STRIP = ("NO_MISTAKES_GATE", "FM_GATE_REFUSE_BYPASS", "FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE",
         "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE", "FM_OPEN_LOOPS_NOW",
         "FM_SUPERVISION_ACTOR", "FM_WAKE_ACK_AWAY_DAEMON", "FM_OPEN_LOOPS_RESURFACE")
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
results = []


class Lab:
    def __init__(self, name):
        self.name = name
        base = {k: v for k, v in os.environ.items() if k not in STRIP}
        minted = subprocess.run([str(BIN / "fm-lab-home.sh"), "env"], text=True, capture_output=True, env=base)
        assert minted.returncode == 0, minted.stderr
        exports = dict(re.findall(r"export (\w+)=(\S+)", minted.stdout))
        self.home = Path(exports["FM_HOME"])
        self.env = dict(base, FM_HOME=str(self.home), TMUX_TMPDIR=exports["TMUX_TMPDIR"])
        self.log = open(OUT / f"{name}.transcript.txt", "w")
        self.say(f"# scenario {name}\n# lab FM_HOME={self.home}\n# repo={REPO} (gate worktree at target commit)")
        (self.home / "data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
        self.ledger = self.home / "state/open-loops.json"
        self.now = int(time.time())

    def say(self, text):
        self.log.write(text + "\n")
        self.log.flush()

    def run(self, *args, env=None, quiet=False):
        e = dict(self.env, **(env or {}))
        shown = " ".join(f"{k}={v}" for k, v in (env or {}).items())
        cmd = [str(a) for a in args]
        pretty = " ".join(shlex.quote(c.replace(str(REPO) + "/", "")) for c in cmd)
        r = subprocess.run(cmd, env=e, text=True, capture_output=True, cwd=REPO, timeout=300)
        if not quiet:
            self.say(f"\n$ {shown + ' ' if shown else ''}{pretty}\n[exit {r.returncode}]")
            if r.stdout.strip():
                self.say(r.stdout.rstrip())
            err = "\n".join(l for l in r.stderr.splitlines() if l.startswith(("WAKE_ACK", "error", "fm-", "Traceback"))
                            or "refused" in l)
            if err:
                self.say("[stderr] " + err)
        return r

    def publish(self, rows, generated=None):
        report = json.loads(self.ledger.read_text()) if self.ledger.exists() else {}
        rows = age_forward(rows, report.get("generated_epoch"), generated or self.now)
        report.update(schema="fm-open-loops.v1", generated_epoch=generated or self.now, complete=True,
                      home=str(self.home.resolve()), rows=rows)
        self.ledger.write_text(json.dumps(report))

    def rows(self):
        return json.loads(self.ledger.read_text())["rows"]

    def wake(self, key="report", reason=None):
        self.run("bash", "-c", '. "$1"; fm_wake_append check "$2" "$3"', "_", BIN / "fm-wake-lib.sh", key,
                 reason or f"check: {key}", quiet=True)
        self.say(f"\n# queued wake: check {key}")

    def drain(self, **env):
        r = self.run(DRAIN, env=env)
        m = re.search(r"--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)", r.stderr)
        return r, (m.groups() if m else None)

    def ack(self, boundary, **env):
        return self.run(DRAIN, "--ack-through", boundary[0], "--recovery-generation", boundary[1], env=env)

    def act(self, ident, kind, evidence, *extra, **env):
        return self.run(LOOPS, "action", ident, kind, "--evidence", evidence, *extra, env=env)

    def sequence(self):
        return json.loads(self.ledger.read_text()).get("handling", {}).get("sequence", 0)

    def close(self):
        self.log.close()
        subprocess.run([str(BIN / "fm-lab-home.sh"), "teardown", str(self.home)], env=self.env,
                       capture_output=True)
        subprocess.run(["rm", "-rf", str(self.home)])


def age_forward(rows, old, new):
    """A real heartbeat republishes an unchanged row with its age grown by the elapsed time."""
    if old is None or new <= old:
        return rows
    return [dict(r, age_seconds=r["age_seconds"] + (new - old)) if r.get("age_seconds") is not None
            and not r.get("_new") else {k: v for k, v in r.items() if k != "_new"} for r in rows]


def section_ids(text, header):
    ids, on = [], False
    for line in text.splitlines():
        if line.startswith(header):
            on = True
            continue
        if on and line.startswith("rows["):
            continue
        if on and line.startswith('  "'):
            ids.append(line[3:].split('"', 1)[0])
            continue
        on = False
    return ids


def g1(lab, drain_out):
    """Hard gate G1: every overdue row is in the gate (OVERDUE) or in the periodic digest, never both, never neither."""
    report = lab.run(LOOPS, "--report", quiet=True).stdout
    overdue = set(re.findall(r'^  "([^"]+)",', report, re.M))
    gated = set(section_ids(drain_out, "OVERDUE:"))
    digest = set(section_ids(lab.run(LOOPS, "--digest", quiet=True).stdout, "WAITING OPEN WORK"))
    ok = overdue == gated | digest and not gated & digest
    lab.say(f"\n# G1 check: overdue={sorted(overdue)} gate={sorted(gated)} digest={sorted(digest)} -> {'ok' if ok else 'VIOLATED'}")
    return ok


def scenario(fn):
    lab = Lab(fn.__name__)
    try:
        fn(lab)
        results.append((fn.__name__, "PASS", ""))
        lab.say("\n# RESULT: PASS")
    except AssertionError as error:
        results.append((fn.__name__, "FAIL", str(error)[:400]))
        lab.say(f"\n# RESULT: FAIL {error}")
    finally:
        lab.close()


def fleet_rows(now):
    """A paused-fleet shape: the intent's row categories, owned by firstmate, captain and workers."""
    q = lambda i, owner: dict(id=f"q{i}-{owner}", category="unanswered_question", subject=f"lane{i}:decision",
                              owner=owner, next_action="answer or close this question, or record why it no longer applies",
                              age_seconds=90000, limit_seconds=1800, overdue=True,
                              evidence="blocked: waiting on the fleet pause")
    rows = [q(i, "firstmate") for i in range(1, 5)] + [q(i, "captain") for i in range(5, 7)]
    rows += [dict(id=f"pr{i}", category="open_pr", subject=f"https://github.com/test/p/pull/{i}", owner="firstmate",
                  next_action="route the green PR's review", age_seconds=80000, limit_seconds=3600, overdue=True,
                  evidence="", source=dict(kind="pr", head=f"sha{i}")) for i in (1, 2)]
    rows += [dict(id="commit1", category="unlanded_commit", subject="lane3", owner="firstmate",
                  next_action="land or drop the commit", age_seconds=70000, limit_seconds=3600, overdue=True,
                  evidence="abc123 not in default branch"),
             dict(id="silent1", category="silent_report", subject="lane4", owner="worker:lane4",
                  next_action="request a progress report", age_seconds=60000, limit_seconds=3600, overdue=True,
                  evidence="no report since pause"),
             dict(id="stalled1", category="stalled_worker", subject="lane5", owner="worker:lane5",
                  next_action="follow up on the recorded wait", age_seconds=50000, limit_seconds=3600, overdue=True,
                  evidence="paused by captain; last progress at 1"),
             dict(id="cov1", category="coverage", subject="forge", owner="firstmate", next_action="restore coverage",
                  age_seconds=40000, limit_seconds=3600, overdue=True, evidence="forge read degraded")]
    return rows


def first_turn(lab, rows):
    lab.publish(rows)
    lab.wake("open-loop-ledger", f"check: open-loop-ledger ({len(rows)} overdue)")
    out, boundary = lab.drain()
    assert set(section_ids(out.stdout, "OVERDUE:")) == {r["id"] for r in rows}, "first turn did not gate every new row"
    assert g1(lab, out.stdout), "G1 violated on first turn"
    refused = lab.ack(boundary)
    assert refused.returncode == 1 and "acknowledgement refused" in refused.stdout, "new rows did not refuse the ack"
    return boundary


def s1_unchanged_rows_need_no_fresh_actions(lab):
    rows = fleet_rows(lab.now)
    boundary = first_turn(lab, rows)
    for row in rows:
        r = lab.act(row["id"], "escalated", f"asked the captain about {row['subject']} during the pause")
        assert r.returncode == 0, ("action refused", row["id"], r.stdout, r.stderr)
    assert lab.ack(boundary).returncode == 0, "ack refused after acting once on every new row"
    seq = lab.sequence()
    for turn in range(1, 4):
        lab.wake("report", f"check: unrelated worker report {turn}")
        out, boundary = lab.drain()
        assert "OVERDUE:" not in out.stdout, f"turn {turn}: unchanged rows were gated again"
        assert g1(lab, out.stdout), f"G1 violated on turn {turn}"
        assert lab.ack(boundary).returncode == 0, f"turn {turn}: ack refused on unchanged rows"
    assert lab.sequence() == seq, "acknowledgements needed new action records"
    lab.say(f"\n# 3 later turns acknowledged with 0 new actions (handling.sequence stayed {seq}); "
            f"base code needed {len(rows)} fresh actions per acknowledgement")


def s2_periodic_digest_lists_unchanged_rows(lab):
    rows = fleet_rows(lab.now)
    boundary = first_turn(lab, rows)
    for row in rows:
        assert lab.act(row["id"], "escalated", "asked the captain").returncode == 0
    assert lab.ack(boundary).returncode == 0
    lab.wake("open-loop-ledger", "check: open-loop-ledger (12 overdue)")
    change, boundary = lab.drain()
    assert "WAITING OPEN WORK" not in change.stdout, "a change wake carried the full waiting list"
    assert lab.ack(boundary).returncode == 0
    lab.wake("open-loop-ledger-resurface", "check: open-loop-ledger-resurface (12 overdue; periodic waiting list)")
    out, boundary = lab.drain()
    listed = section_ids(out.stdout, "WAITING OPEN WORK")
    assert sorted(listed) == sorted(r["id"] for r in rows), ("digest is missing rows", listed)
    for row in rows:
        line = next(l for l in out.stdout.splitlines() if l.startswith('  "' + row["id"] + '",'))
        assert '"at_epoch"' in line and '"evidence": "asked the captain"' in line, ("no last action", line)
        assert re.search(r',(\d+),', line) and int(re.search(r',(\d{4,}),', line).group(1)) >= row["age_seconds"], line
        want = "escalated, waiting on the captain" if row["owner"] == "captain" \
            else "escalated, no proof it reached the captain"
        assert want in line, (row["id"], line)
    assert lab.ack(boundary).returncode == 0, "the resurface wake refused acknowledgement"


def s3_rubber_stamp_is_not_captain_waiting(lab):
    rows = fleet_rows(lab.now)
    boundary = first_turn(lab, rows)
    out = lab.run(LOOPS, "--check-actions", quiet=True).stdout
    for ident in re.findall(r'^  "([^"]+)",', out, re.M):  # the intent's stamping script
        lab.act(ident, "escalated", "escalated")
    assert lab.ack(boundary).returncode == 0
    digest = lab.run(LOOPS, "--digest").stdout
    for row in rows:
        line = next(l for l in digest.splitlines() if l.startswith('  "' + row["id"] + '",'))
        if row["owner"] == "captain":
            assert "escalated, waiting on the captain" in line, line
        else:
            assert "waiting on the captain" not in line and "no proof it reached the captain" in line, line
    stored = json.loads(lab.ledger.read_text())["handling"]["actions"]
    assert all("hold" not in stored[r["id"]] for r in rows), "a stamp bound a hold"


def s4_unpause_changes_regate_with_no_manual_revert(lab):
    rows = fleet_rows(lab.now)
    boundary = first_turn(lab, rows)
    for row in rows:
        assert lab.act(row["id"], "escalated", "asked the captain").returncode == 0
    assert lab.ack(boundary).returncode == 0
    # Lanes resume: a new status line, a new commit, and a new PR head whose text is unchanged but whose age clock restarted.
    changed = json.loads(lab.ledger.read_text())
    current = int(time.time())
    changed["rows"] = age_forward(changed["rows"], changed["generated_epoch"], current)
    for row in changed["rows"]:
        if row["id"] == "stalled1":
            row["evidence"] = "working [at=200]: resumed the paused lane"
        if row["id"] == "commit1":
            row["evidence"] = "def456 not in default branch"
        if row["id"] == "pr1":
            row["age_seconds"] = 3700  # updated_at reset by the new head; next_action/evidence identical
            row["source"]["head"] = "sha1-new"
    changed["generated_epoch"] = current
    lab.ledger.write_text(json.dumps(changed))
    lab.say("\n# lanes resumed: stalled1 evidence changed, commit1 new commit, pr1 new head (same text, age clock restarted)")
    lab.wake("open-loop-ledger", "check: open-loop-ledger (12 overdue)")
    out, boundary = lab.drain()
    gated = set(section_ids(out.stdout, "OVERDUE:"))
    assert gated == {"stalled1", "commit1", "pr1"}, ("wrong rows re-gated", gated)
    assert "STANDING" in out.stdout
    assert g1(lab, out.stdout), "G1 violated after unpause"
    digest = set(section_ids(lab.run(LOOPS, "--digest").stdout, "WAITING OPEN WORK"))
    assert not digest & gated, "changed rows stayed in the waiting list"
    refused = lab.ack(boundary)
    assert refused.returncode == 1 and set(re.findall(r'^  "([^"]+)",', refused.stdout, re.M)) == gated, refused.stdout
    for ident in sorted(gated):
        assert lab.act(ident, "escalated", f"asked the captain about resumed {ident}").returncode == 0
    assert lab.ack(boundary).returncode == 0, "ack refused after acting on the changed rows only"


def s5_bound_captain_hold_is_proof_and_its_end_regates(lab):
    stamp = "  Captain hold set: " + iso(lab.now - 7200) + "\n"
    held = ("## In flight\n- [ ] held-job - Recover the run (repo: firstmate) (kind: ship) "
            "(hold: exact run recovery) (hold-kind: captain)\n" + stamp + "\n## Queued\n\n## Done\n")
    (lab.home / "data/backlog.md").write_text(held)
    row = dict(id="qheld", category="unanswered_question", subject="held-job:ci-control", owner="firstmate",
               next_action="answer or close this question, or record why it no longer applies", age_seconds=7200,
               limit_seconds=1800, overdue=True, evidence="blocked: supported recovery control is missing",
               source=dict(kind="status", task="held-job", key="ci-control"))
    boundary = first_turn(lab, [row])
    r = lab.act("qheld", "escalated", "asked the captain about the recovery control")
    assert r.returncode == 0 and "standing: captain hold held-job" in r.stdout, r.stdout
    assert lab.ack(boundary).returncode == 0
    lab.wake("open-loop-ledger-resurface")
    out, boundary = lab.drain()
    assert "escalated, waiting on the captain" in out.stdout and "OVERDUE:" not in out.stdout, out.stdout
    assert lab.ack(boundary).returncode == 0
    (lab.home / "data/backlog.md").write_text(held.replace("- [ ] held-job", "- [x] held-job")
                                              .replace("## In flight", "## Done"))
    lab.say("\n# the captain answered: held-job moved to Done")
    lab.wake("report")
    out, boundary = lab.drain()
    assert "qheld" in section_ids(out.stdout, "OVERDUE:"), "the ended hold did not return the row to the gate"
    assert g1(lab, out.stdout)
    assert lab.ack(boundary).returncode == 1, "the ended hold did not refuse the ack"
    assert "waiting on the captain" not in lab.run(LOOPS, "--digest").stdout


def s6_deferral_allowance_resets_on_changed_work(lab):
    row = dict(id="d1", category="stalled_worker", subject="lane9", owner="worker:lane9",
               next_action="follow up on the recorded wait", age_seconds=7200, limit_seconds=3600, overdue=True,
               evidence="waiting for CI run 1")
    boundary = first_turn(lab, [row])
    later = iso(int(time.time()) + 3600)
    assert lab.act("d1", "deferred", "CI run 1 still going", "--recheck", later).returncode == 0
    assert lab.ack(boundary).returncode == 0
    second = lab.act("d1", "deferred", "still going", "--recheck", later)
    assert second.returncode == 1 and "second deferral refused" in second.stdout, second.stdout
    assert lab.run(LOOPS, "--check-actions").returncode == 1, "a refused second deferral left the row covered"
    assert lab.act("d1", "escalated", "asked the captain about CI run 1").returncode == 0
    assert lab.run(LOOPS, "--check-actions").returncode == 0
    record = json.loads(lab.ledger.read_text())
    record["rows"][0]["evidence"] = "waiting for CI run 2"
    lab.ledger.write_text(json.dumps(record))
    lab.say("\n# lane resumed: new CI run")
    lab.wake("open-loop-ledger")
    out, boundary = lab.drain()
    assert "d1" in section_ids(out.stdout, "OVERDUE:")
    fresh = lab.act("d1", "deferred", "waiting for CI run 2", "--recheck", later)
    assert fresh.returncode == 0 and "kind: deferred" in fresh.stdout, fresh.stdout
    assert lab.ack(boundary).returncode == 0, "the fresh deferral on changed work did not cover the row"


def s7_unpresented_new_row_waits_for_next_drain(lab):
    rows = fleet_rows(lab.now)[:2]
    boundary = first_turn(lab, rows)
    for row in rows:
        assert lab.act(row["id"], "escalated", "asked the captain").returncode == 0
    lab.wake("report")
    out, boundary = lab.drain()
    newrow = dict(rows[0], id="late", subject="late-lane:decision", _new=True)
    lab.publish(lab.rows() + [newrow], generated=int(time.time()))
    lab.say("\n# heartbeat published a new overdue row 'late' after this drain")
    assert lab.ack(boundary).returncode == 0, "an unpresented new row blocked the handled wakes"
    lab.wake("open-loop-ledger")
    out, boundary = lab.drain()
    assert section_ids(out.stdout, "OVERDUE:") == ["late"], out.stdout
    assert g1(lab, out.stdout)
    assert lab.ack(boundary).returncode == 1, "the presented new row did not gate"
    assert lab.act("late", "escalated", "asked the captain").returncode == 0
    assert lab.ack(boundary).returncode == 0


def s8_away_daemon_ack_does_not_bypass_firstmate(lab):
    rows = fleet_rows(lab.now)[:1]
    boundary = first_turn(lab, rows)
    daemon = lab.ack(boundary, FM_WAKE_ACK_AWAY_DAEMON="1")
    assert daemon.returncode == 1, "the daemon marker bypassed the gate outside away mode"
    (lab.home / "state/.afk").write_text(str(lab.now) + "\n")
    lab.say("\n# captain away: state/.afk written")
    assert lab.ack(boundary, FM_WAKE_ACK_AWAY_DAEMON="1").returncode == 0, "away daemon could not ack its wakes"
    assert json.loads(lab.ledger.read_text())["handling"]["actions"] == {}, "the daemon wrote a receipt"
    assert lab.run(LOOPS, "--check-actions").returncode == 1, "firstmate's own gate was lifted"


def s9_watcher_change_vs_periodic_wake(lab):
    rows = fleet_rows(lab.now)[:3]
    lab.publish(rows)
    env = dict(FM_POLL="1", FM_SIGNAL_GRACE="1", FM_CHECK_INTERVAL="99999999", FM_HEARTBEAT="99999999",
               FM_HOME_SUMMARY_INTERVAL="99999999", FM_SECONDMATE_LIVENESS_SECS="99999999",
               FM_OPEN_LOOPS_INTERVAL="999999", FM_OPEN_LOOPS_RESURFACE="3600")
    queue = lab.home / "state/.wake-queue"
    def watch():
        r = lab.run("timeout", "60", WATCH, env=env)
        q = queue.read_text() if queue.exists() else ""
        lab.say("# queue: " + " | ".join(l.split("\t", 3)[3] for l in q.splitlines()))
        return r, q
    r, q = watch()
    assert "\topen-loop-ledger\t" in q and "resurface" not in q, ("first wake", q, r.stderr[-500:])
    _, boundary = lab.drain()
    for row in rows:
        lab.act(row["id"], "escalated", "asked the captain")
    assert lab.ack(boundary).returncode == 0
    resurfaced = lab.home / "state/.open-loops-resurfaced"
    old = time.time() - 3700
    os.utime(resurfaced, (old, old))
    lab.say("\n# resurface marker backdated 3700s (interval 3600s); ledger unchanged")
    r, q = watch()
    assert "open-loop-ledger-resurface" in q, ("periodic wake missing", q)
    out, boundary = lab.drain()
    assert sorted(section_ids(out.stdout, "WAITING OPEN WORK")) == sorted(r["id"] for r in rows), out.stdout
    assert lab.ack(boundary).returncode == 0
    record = json.loads(lab.ledger.read_text())
    current = int(time.time())
    record["rows"] = age_forward(record["rows"], record["generated_epoch"], current)
    record["rows"][0]["evidence"] = "resumed: new status line"
    record["generated_epoch"] = current
    lab.ledger.write_text(json.dumps(record))
    os.utime(lab.ledger, None)
    lab.say("\n# one row changed after the unpause")
    r, q = watch()
    assert "\topen-loop-ledger\t" in q and "resurface" not in q, ("change wake", q)
    out, boundary = lab.drain()
    assert section_ids(out.stdout, "OVERDUE:") == [rows[0]["id"]] and "WAITING OPEN WORK" not in out.stdout, out.stdout


for fn in (s1_unchanged_rows_need_no_fresh_actions, s2_periodic_digest_lists_unchanged_rows,
           s3_rubber_stamp_is_not_captain_waiting, s4_unpause_changes_regate_with_no_manual_revert,
           s5_bound_captain_hold_is_proof_and_its_end_regates, s6_deferral_allowance_resets_on_changed_work,
           s7_unpresented_new_row_waits_for_next_drain, s8_away_daemon_ack_does_not_bypass_firstmate,
           s9_watcher_change_vs_periodic_wake):
    if len(sys.argv) > 2 and fn.__name__ not in sys.argv[2:]:
        continue
    scenario(fn)
with open(OUT / "summary.txt", "a") as s:
    for name, verdict, why in results:
        line = f"{verdict}: {name}" + (f" -- {why}" if why else "")
        print(line)
        s.write(line + "\n")
