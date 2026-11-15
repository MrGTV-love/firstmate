#!/usr/bin/env bash
# Method-level tests for the ledger's recorded-refusal reading (Main 1820 F7):
# bin/fm_open_loops.py is loaded as a module and only teardown_refusal_record and
# attach_refusal are called, on records written here. No collection pass, no
# subprocess and no timed or killed process runs.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-open-loops-refusal.XXXXXX") || exit 1
trap 'rm -rf -- "${WORK:?}"' EXIT
python3 -I - "$ROOT/bin/fm_open_loops.py" "$WORK" <<'PY'
import importlib.util, os, sys, time
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location("fm_open_loops_refusal", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
work = Path(sys.argv[2])
failed = False

def check(ok, message):
    global failed
    if not ok:
        print("not ok - " + message)
        failed = True
    return ok

def collector(name):
    home = work / name
    (home / "config").mkdir(parents=True)
    (home / "state" / ".idle-reap").mkdir(parents=True)
    return module.Collector(home, int(time.time()))

def publish(path, text):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)

def prune_text(reason):
    return f"version=fm-merge-prune-v1\npr=https://github.com/o/r/pull/7\nstate=retained\nreason={reason}\n"

def memo_text(reason):
    return f"fm-idle-reap-refused-v1\n{int(time.time())}\ndone [at=1]: x\n{reason}\n"

# 1. A working ship with a dirty copy whose only row is its check-in keeps the last
#    recorded refusal on that row; a covering row, when present, takes it instead.
case_ok = True
c = collector("dirty-working")
c.add("silent_report", "t1", "check in: progress, blockers, cross-workstream dependencies", None, evidence="quiet")
refused = "the last recorded cleanup refusal (recorded by bin/fm-merge-prune.sh): REFUSED: uncommitted changes"
c.attach_refusal("t1", None, "REFUSED: uncommitted changes", refused)
row = next(r for r in c.rows.values() if r["category"] == "silent_report" and r["subject"] == "t1")
case_ok &= check(refused in row["next_action"], "a dirty working ship's only row lost the recorded refusal: " + row["next_action"])
case_ok &= check("REFUSED: uncommitted changes" in row["evidence"], "the check-in row's evidence does not name the refusal")
c = collector("dirty-covered")
c.add("silent_report", "t1", "check in", None, evidence="quiet")
c.add("unlanded_commit", "t1", "land this work through its PR, or obtain the captain's drop", None, evidence="1 commit")
c.attach_refusal("t1", None, "REFUSED: x", "the last recorded cleanup refusal: REFUSED: x")
silent = next(r for r in c.rows.values() if r["category"] == "silent_report")
covering = next(r for r in c.rows.values() if r["category"] == "unlanded_commit")
case_ok &= check("REFUSED: x" in covering["next_action"], "control: the covering row did not take the refusal")
case_ok &= check("REFUSED: x" not in silent["next_action"], "control: the check-in row took the refusal although a covering row exists")
if case_ok:
    print("ok - a working ship with a dirty copy and only a check-in row keeps the last recorded refusal; a covering row takes it when present")

# 2. A record replaced between its read and its time read can never pair the old
#    text with the new time: the reaper publishes A, the prune publishes B later,
#    and the reaper replaces its memo while it is being read.
case_ok = True
c = collector("order-interleave")
memo = c.state / ".idle-reap" / "t1.refused"
prune = c.state / "t1.merge-prune"
publish(memo, memo_text("REFUSED: reaper reason A"))
time.sleep(0.02)
publish(prune, prune_text("REFUSED: prune reason B"))
real_stat = Path.stat
real_read = Path.read_text
def racing_read(self, *a, **k):
    text = real_read(self, *a, **k)
    if self == memo:
        time.sleep(0.02)
        publish(memo, memo_text("REFUSED: reaper reason C"))
    return text
with mock.patch.object(Path, "read_text", racing_read):
    reason, producer = c.teardown_refusal_record("t1")
case_ok &= check(reason != "REFUSED: reaper reason A",
                 "an old memo text was paired with the replacement's later time: " + reason)
c2 = collector("order-stable")
publish(c2.state / ".idle-reap" / "t1.refused", memo_text("REFUSED: reaper reason A"))
time.sleep(0.02)
publish(c2.state / "t1.merge-prune", prune_text("REFUSED: prune reason B"))
reason, producer = c2.teardown_refusal_record("t1")
case_ok &= check(reason == "REFUSED: prune reason B", "control: the record published last was not chosen: " + reason)
c3 = collector("order-reverse")
publish(c3.state / "t1.merge-prune", prune_text("REFUSED: prune reason B"))
time.sleep(0.02)
publish(c3.state / ".idle-reap" / "t1.refused", memo_text("REFUSED: reaper reason A"))
reason, producer = c3.teardown_refusal_record("t1")
case_ok &= check(reason == "REFUSED: reaper reason A", "control: the reaper's later record was not chosen: " + reason)
if case_ok:
    print("ok - each recorded refusal's text and time come from one opened file, so a replacement mid-read never pairs old text with a newer time")
# 3. Kind (d) of Main 1813's V4 amendment: a scout whose report is delivered and whose
#    last report is done, while its pane still reads working, has no completed_task
#    row (that row needs the done state), so its completion row is pending_cleanup,
#    owned by the home, with the scout action. report_status and the copy probe are
#    stubbed, so no process runs.
case_ok = True
c = collector("scout-working")
(c.data / "t-scout").mkdir(parents=True)
(c.data / "t-scout" / "report.md").write_text("Delivered investigation report.\n")
task = dict(id="t-scout", kind="scout", pr={}, mode="direct-PR",
            current_state=dict(state="working", detail=""), endpoint=dict(exists=True, agent_alive="alive"))
c.tasks = [task]
c.backlog = []
with mock.patch.object(module.Collector, "report_status", lambda self, ident: (None, "done", False, False, None, None)), \
     mock.patch.object(module.Collector, "teardown_refusal_record", lambda self, ident: ("", "")):
    c.completion_row(task, "home:" + c.home_label())
rows = [r for r in c.rows.values() if r["subject"] == "t-scout"]
case_ok &= check([r["category"] for r in rows] == ["pending_cleanup"], "kind (d): rows were " + repr([r["category"] for r in rows]))
if rows:
    case_ok &= check(rows[0]["owner"] == "home:" + c.home_label(), "kind (d): owner was " + rows[0]["owner"])
    case_ok &= check(rows[0]["next_action"].startswith("accept the delivered report, then run plain bin/fm-teardown.sh t-scout"),
                     "kind (d): next action was " + rows[0]["next_action"])
    case_ok &= check("scout report is delivered" in rows[0]["evidence"], "kind (d): evidence was " + rows[0]["evidence"])
if case_ok:
    print("ok - kind (d): a scout with a delivered report and a done report whose pane reads working gets an owned pending_cleanup row with the scout action")
sys.exit(1 if failed else 0)
PY
