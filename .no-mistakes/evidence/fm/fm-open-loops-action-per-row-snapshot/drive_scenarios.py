#!/usr/bin/env python3
"""Live scenario driver for the open-work ledger receipt change.

Drives the real bin/fm-wake-drain.sh and bin/fm-open-loops.sh from a code tree
against a disposable lab home (bin/fm-lab-home.sh create). The published ledger
rows are seeded fixture state; every command under test is the real product.
Usage: drive_scenarios.py CODE_DIR LAB_HOME TRANSCRIPT [--base]
"""
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

code, lab, transcript_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
BASE = "--base" in sys.argv
loops, drain_cli = code / "bin/fm-open-loops.sh", code / "bin/fm-wake-drain.sh"
out = open(transcript_path, "w")
now = int(time.time())
clock = now
results = []


def log(text=""):
    out.write(text + "\n")
    out.flush()


def env():
    e = {k: v for k, v in os.environ.items()
         if k not in ("FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE",
                      "FM_PROJECTS_OVERRIDE", "NO_MISTAKES_GATE", "FM_GATE_REFUSE_BYPASS")}
    e.update(FM_HOME=str(lab), FM_OPEN_LOOPS_NOW=str(clock), FM_SUPERVISION_ACTOR="main", FM_DURATION_FILE="off")
    return e


def run(argv, input_text=None, show=True, shell=False):
    start = time.monotonic()
    r = subprocess.run(argv, env=env(), text=True, capture_output=True, input=input_text, shell=shell, timeout=600)
    took = time.monotonic() - start
    if show:
        shown = argv if shell else " ".join(str(a) for a in argv).replace(str(code) + "/", "")
        log(f"$ {shown}    # clock=+{clock - now}s rc={r.returncode} {took:.2f}s")
        for stream in (r.stdout, r.stderr):
            if stream.strip():
                lines = stream.rstrip().splitlines()
                for line in lines[:14]:
                    log("  | " + line)
                if len(lines) > 14:
                    log(f"  | ... ({len(lines) - 14} more lines)")
    r.took = took
    return r


ledger = lab / "state/open-loops.json"


def publish(rows):
    ledger.write_text(json.dumps(dict(schema="fm-open-loops.v1", generated_epoch=clock, home=str(lab),
                                      complete=True, rows=rows)))


def stored():
    return json.loads(ledger.read_text())


def drain():
    r = run([drain_cli])
    m = re.search(r"--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)", r.stderr)
    return r, (m.groups() if m else None)


def ack(b):
    return run([drain_cli, "--ack-through", b[0], "--recovery-generation", b[1]])


def act(ident, kind="escalated", evidence="reported decision", *extra):
    return run([loops, "action", ident, kind, "--evidence", evidence, *extra])


def batch_file(items, name="actions.jsonl"):
    path = lab / name
    path.write_text("".join(json.dumps(i) + "\n" for i in items))
    return path


def wake(label):
    run(["bash", "-c", '. "$1"; fm_wake_append check "$2" "check: $2"', "_", str(code / "bin/fm-wake-lib.sh"), label],
        show=False)


def scenario(name, fn):
    log("=" * 100)
    log("SCENARIO: " + name)
    log("=" * 100)
    try:
        fn()
        results.append((name, "PASS"))
        log("RESULT: PASS")
    except AssertionError as error:
        results.append((name, "FAIL: " + str(error)[:300]))
        log("RESULT: FAIL " + str(error)[:2000])
    log()


def q(i, **kw):
    return dict(dict(id=f"row-{i}", category="unanswered_question", subject=f"job:question-{i}", owner="firstmate",
                     next_action="obtain decision", evidence="decision pending", age_seconds=7200,
                     limit_seconds=1800, overdue=True), **kw)


ROWS = [q(i) for i in range(50)]


def reset():
    global clock
    clock += 60
    (lab / "data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
    for p in ("state/open-loops.json",):
        (lab / p).unlink(missing_ok=True)


# ---------------------------------------------------------------- scenarios
def s_fifty_then_read_then_ack():
    """The captain's quoted flow: log all 50, read in between, then clear."""
    reset()
    publish(ROWS)
    r, b = drain()
    assert b and r.stdout.count('"row-') == 50, "drain presents 50 overdue rows"
    if BASE:
        t0 = time.monotonic()
        for row in ROWS:
            act(row["id"]) if row["id"] in ("row-0", "row-49") else run(
                [loops, "action", row["id"], "escalated", "--evidence", "reported decision"], show=False)
        log(f"  (50 single-row actions took {time.monotonic() - t0:.2f}s)")
    else:
        r = run([loops, "action", "--batch", batch_file([dict(row_id=x["id"], kind="escalated",
                                                             evidence="reported decision") for x in ROWS])])
        assert r.returncode == 0 and r.stdout.count('"recorded"') == 50, "one batch records 50 actions"
    log("  -- supervisor re-reads the queue to find the ack command (the step that used to void progress)")
    r2, b2 = drain()
    log("  -- second read printed OVERDUE block: " + str("OVERDUE:" in r2.stdout))
    chk = run([loops, "--check-actions"])
    a = ack(b)
    assert a.returncode == 0, "ack after 50 actions plus an in-between read must succeed"
    assert chk.returncode == 0, "--check-actions after read must pass"


def s_next_turn_standing():
    global clock
    reset()
    publish(ROWS)
    _, b = drain()
    run([loops, "action", "--batch", batch_file([dict(row_id=x["id"], kind="escalated",
                                                     evidence="reported decision") for x in ROWS])])
    assert ack(b).returncode == 0
    action_time = clock
    for offset in (3600, 14399):
        clock = action_time + offset
        wake(f"later-{offset}")
        r, b = drain()
        assert "OVERDUE:" not in r.stdout, f"unchanged rows must not need 50 new actions at +{offset}s"
        if b:
            assert ack(b).returncode == 0, f"next-turn ack at +{offset}s must succeed with no new actions"
    clock = action_time + 14400
    r, b = drain()
    assert "OVERDUE:" in r.stdout and r.stdout.count('"row-') == 50, "after four hours rows are re-presented"
    assert ack(b).returncode == 1, "after four hours ack refuses until new actions"
    run([loops, "action", "--batch", batch_file([dict(row_id=x["id"], kind="escalated",
                                                     evidence="re-reported") for x in ROWS])])
    assert ack(b).returncode == 0


def s_missing_row_and_bad_lines_stay_gated():
    reset()
    publish(ROWS)
    _, b = drain()
    items = [dict(row_id=x["id"], kind="escalated", evidence="reported decision") for x in ROWS[:49]]
    items += [dict(row_id="absent", kind="escalated", evidence="x"), dict(row_id="row-49", kind="bogus", evidence="x")]
    path = batch_file(items)
    with open(path, "a") as f:
        f.write("not json\n")
    r = run([loops, "action", "--batch", path])
    assert r.returncode == 1, "a batch with refused lines exits 1"
    assert r.stdout.count('"recorded"') == 49 and r.stdout.count('"refused"') == 3, "per-line results"
    assert len(stored()["handling"]["actions"]) == 49, "valid siblings persist"
    chk = run([loops, "--check-actions"])
    assert chk.returncode == 1 and "row-49" in chk.stdout, "the one unactioned row stays gated"
    assert ack(b).returncode == 1, "ack refuses while row-49 lacks an action"
    assert run([loops, "--check-actions"]).returncode == 1, "a refused ack does not reset the 49 recorded actions"
    act("row-49")
    assert ack(b).returncode == 0, "one more action clears the queue; the 49 survived the refusal"


def s_changed_row_invalidates():
    for field in ("category", "subject", "owner", "next_action", "evidence"):
        reset()
        publish([q(0)])
        _, b = drain()
        act("row-0")
        rec = stored()
        rec["rows"][0][field] += "-changed"
        ledger.write_text(json.dumps(rec))
        chk = run([loops, "--check-actions"])
        assert chk.returncode == 1, f"changed {field} must require new evidence"
        assert ack(b).returncode == 1, f"changed {field} must refuse ack"
        act("row-0")
        assert ack(b).returncode == 0


def s_stalled_timer():
    reset()
    stalled = q(0, category="stalled_worker", subject="job", owner="worker:job",
                next_action="follow up on the recorded wait and recover the worker",
                evidence="Running lint… (3m 12s · esc to interrupt); 3600s without progress")
    publish([stalled])
    _, b = drain()
    act("row-0")
    rec = stored()
    rec["rows"][0]["evidence"] = "Running lint… (3m 13s · esc to interrupt); 3601s without progress"
    ledger.write_text(json.dumps(rec))
    stamp = stored()["handling"]["presented_at"]["main"]["row-0"]
    assert run([loops, "--check-actions"]).returncode == 0, "a timer tick is not a changed obligation"
    drain()
    assert stored()["handling"]["presented_at"]["main"]["row-0"] == stamp, "a re-read must not restamp"
    rec = stored()
    rec["rows"][0]["evidence"] = "Running tests… (3m 13s · esc to interrupt); 3601s without progress"
    ledger.write_text(json.dumps(rec))
    assert run([loops, "--check-actions"]).returncode == 1, "a different task is a real change"
    act("row-0")
    assert ack(b).returncode == 0


def s_pipeline_report_into_batch():
    reset()
    publish(ROWS[:5])
    _, b = drain()
    filt = ("python3 -c 'import re,sys,json\n"
            "[print(json.dumps(dict(row_id=m,kind=\"escalated\",evidence=\"reported decision\")))"
            " for m in re.findall(r\"^  \\\"(row-[0-9]+)\\\"\", sys.stdin.read(), re.M)]'")
    cmd = f'"{loops}" --report | {filt} | "{loops}" action --batch -'
    r = run(cmd, shell=True)
    assert r.returncode == 0 and r.stdout.count('"recorded"') == 5, "report piped into batch completes"
    assert run([loops, "--check-actions"]).returncode == 0
    assert ack(b).returncode == 0


def s_partial_ack():
    reset()
    publish([q(0, owner="worker:job")])
    wake("first")
    wake("second")
    _, b = drain()
    act("row-0")
    part = ack((str(int(b[0]) - 1), b[1]))
    assert part.returncode == 0, "partial ack succeeds"
    drain()
    assert run([loops, "--check-actions"]).returncode == 0, "partial ack keeps the turn's receipts"
    assert ack(b).returncode == 0


def s_second_deferral_refused():
    reset()
    publish([q(0)])
    _, b = drain()
    recheck = dt.datetime.fromtimestamp(clock + 600, dt.timezone.utc).isoformat()
    assert act("row-0", "deferred", "short wait", "--recheck", recheck).returncode == 0
    assert ack(b).returncode == 0
    act("row-0")  # an escalation that would otherwise stand
    r = act("row-0", "deferred", "another wait", "--recheck", recheck)
    assert r.returncode == 1, "second deferral refuses"
    assert run([loops, "--check-actions"]).returncode == 1, "a refused second deferral requires follow-up"
    act("row-0")
    assert run([loops, "--check-actions"]).returncode == 0


def s_review_pass_next_turn():
    reset()
    publish([q(0, category="review_pass_not_merged", subject="https://github.com/o/r/pull/1")])
    _, b = drain()
    act("row-0")
    drain()
    assert run([loops, "--check-actions"]).returncode == 0, "same-turn read preserves the action"
    assert ack(b).returncode == 0
    wake("next")
    _, b = drain()
    assert ack(b).returncode == 1, "a reviewed-green PR still needs a new action each turn"
    act("row-0")
    assert ack(b).returncode == 0


ALL = [
    ("50 actions logged, queue re-read, then cleared in one ack", s_fifty_then_read_then_ack),
]
if not BASE:
    ALL += [
        ("next handling turn: unchanged firstmate escalations stand until four hours, then re-present", s_next_turn_standing),
        ("adversarial: bad batch lines and one unactioned row stay gated; refused ack keeps progress", s_missing_row_and_bad_lines_stay_gated),
        ("adversarial: each of five identity-field changes voids a receipt", s_changed_row_invalidates),
        ("stalled-worker pane timer tick keeps the receipt; a different task voids it", s_stalled_timer),
        ("--report piped into action --batch - completes without a lock hang", s_pipeline_report_into_batch),
        ("partial ack keeps the remaining rows' receipts", s_partial_ack),
        ("adversarial: second deferral still refuses and requires follow-up", s_second_deferral_refused),
        ("adversarial: review_pass_not_merged still requires a new action next turn", s_review_pass_next_turn),
    ]
for name, fn in ALL:
    scenario(name, fn)
log("SUMMARY")
for name, res in results:
    log(f"  {res[:4]}  {name}" + ("" if res == "PASS" else "  -- " + res))
print("\n".join(f"{r[:4]} {n}" + ("" if r == "PASS" else " -- " + r) for n, r in results))
sys.exit(int(any(r != "PASS" for _, r in results)))
