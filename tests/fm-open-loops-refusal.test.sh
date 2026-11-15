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
import subprocess as _sp
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
#    text with the new time (Main 1820 F7, Main 1871): the reaper publishes A, the
#    prune publishes B later, and the reaper's memo is replaced by C just after the
#    reader opens it. The hook sits on the reader's own path (os.open, os.fdopen) and
#    must fire. Replacing a file also changes the replaced file's time, so the reader
#    checks the path still names what it read and reads again: C, published last,
#    is chosen. A mutant that reads by path and then stats the path pairs A with C's
#    newer time and chooses A: the same race makes this test reject it.
case_ok = True
def race_world(name):
    c = collector(name)
    memo = c.state / ".idle-reap" / "t1.refused"
    publish(memo, memo_text("REFUSED: reaper reason A"))
    time.sleep(0.02)
    publish(c.state / "t1.merge-prune", prune_text("REFUSED: prune reason B"))
    time.sleep(0.02)
    return c, memo
real_open, real_fdopen = os.open, os.fdopen
fired = {"open": 0, "fdopen": 0}
def hooked_open(path, *a, **k):
    fd = real_open(path, *a, **k)
    if str(path) == str(hook_target) and not fired["open"]:
        fired["open"] += 1
        publish(hook_target, memo_text("REFUSED: reaper reason C"))
    return fd
def hooked_fdopen(*a, **k):
    fired["fdopen"] += 1
    return real_fdopen(*a, **k)
c, hook_target = race_world("order-interleave")
with mock.patch.object(module.os, "open", hooked_open), mock.patch.object(module.os, "fdopen", hooked_fdopen):
    reason, producer = c.teardown_refusal_record("t1")
case_ok &= check(fired["open"] == 1 and fired["fdopen"] >= 1, "the hook on the reader's own path did not fire: " + repr(fired))
case_ok &= check(reason == "REFUSED: reaper reason C", "the reader did not choose the record published last: " + reason)
def path_then_stat(path):
    text = Path(path).read_text()
    if str(path) == str(hook_target):
        publish(hook_target, memo_text("REFUSED: reaper reason C"))
    return os.stat(path).st_ctime_ns, text
c, hook_target = race_world("order-mutant")
with mock.patch.object(module, "read_with_ctime", path_then_stat):
    reason, producer = c.teardown_refusal_record("t1")
case_ok &= check(reason == "REFUSED: reaper reason A", "control: the path-then-stat mutant was not caught by this race: " + reason)
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
    print("ok - a memo replaced just after the reader opens it never pairs old text with a newer time (hook on os.open and os.fdopen fired; a path-then-stat mutant is caught)")

# 2b. An unreadable newer record is reported as unknown, never replaced by an older
#     one, and the ledger's coverage is degraded (Main 1871 P-A). Controls: an
#     absent record is absence; two records published at the same instant name both.
case_ok = True
c = collector("unreadable")
publish(c.state / "t1.merge-prune", prune_text("REFUSED: prune reason B"))
time.sleep(0.02)
memo = c.state / ".idle-reap" / "t1.refused"
publish(memo, memo_text("REFUSED: reaper reason A"))
os.chmod(memo, 0)
try:
    reason, producer = c.teardown_refusal_record("t1")
finally:
    os.chmod(memo, 0o600)
case_ok &= check(reason.startswith("the last recorded refusal is unknown") and str(memo) in reason,
                 "an unreadable newer record was replaced: " + reason)
case_ok &= check(producer == "unreadable refusal record", "the producer did not say unreadable: " + producer)
case_ok &= check(any("refusal record of t1" in d for d in c.degraded), "coverage was not degraded: " + repr(c.degraded))
c = collector("absent")
publish(c.state / "t1.merge-prune", prune_text("REFUSED: prune reason B"))
reason, producer = c.teardown_refusal_record("t1")
case_ok &= check(reason == "REFUSED: prune reason B" and not c.degraded, "control: an absent record was not plain absence: " + reason)
c = collector("same-instant")
publish(c.state / "t1.merge-prune", prune_text("REFUSED: prune reason B"))
publish(c.state / ".idle-reap" / "t1.refused", memo_text("REFUSED: reaper reason A"))
real_read = module.read_with_ctime
with mock.patch.object(module, "read_with_ctime", lambda path: (1, real_read(path)[1])):
    reason, producer = c.teardown_refusal_record("t1")
case_ok &= check("REFUSED: prune reason B" in reason and "REFUSED: reaper reason A" in reason, "control: a tie did not name both: " + reason)
if case_ok:
    print("ok - an unreadable refusal record makes the last refusal unknown and degrades coverage; absence and a tie are controls")

# 2c. A merged task whose cleanup is refused is an owned, overdue-eligible
#     pending_cleanup row carrying the refusal, never only an informational
#     check-in (Main 1871 P-D). The copy is a scratch git repository with an
#     uncommitted file, which stays. Controls: the same merged task with a clean copy
#     and no refusal is not blocked; a declared wait adds no such row.
case_ok = True
def scratch_copy(path, dirty):
    path.mkdir(parents=True)
    git = lambda *a: _sp.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-C", str(path)] + list(a), check=True,
                             stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)
    git("init", "-q")
    (path / "work.txt").write_text("work\n"); git("add", "work.txt"); git("commit", "-q", "-m", "work")
    if dirty:
        (path / "work.txt").write_text("uncommitted\n")
def merged_task(c, name, copy):
    url = "https://github.com/o/r/pull/7"
    c.prs[url] = {"merged_at": "2026-11-15T00:00:00Z", "state": "closed", "head": {"sha": "0" * 40}}
    return dict(id=name, kind="ship", pr={"url": url}, mode="direct-PR", paths={"worktree": {"path": str(copy)}},
                current_state=dict(state="working", detail=""), endpoint=dict(exists=True, agent_alive="alive"))
c = collector("merged-dirty")
copy = c.home / "copy"
scratch_copy(copy, True)
task = merged_task(c, "t-dirty", copy)
c.tasks, c.backlog = [task], []
refusal = "REFUSED: worktree has uncommitted changes"
with mock.patch.object(module.Collector, "report_status", lambda self, ident: (None, "done", False, False, None, None)), \
     mock.patch.object(module.Collector, "teardown_refusal_record", lambda self, ident: (refusal, "recorded by bin/fm-merge-prune.sh")):
    c.completion_row(task, "home:" + c.home_label())
rows = [r for r in c.rows.values() if r["subject"] == "t-dirty"]
case_ok &= check([r["category"] for r in rows] == ["pending_cleanup"], "merged dirty: rows were " + repr([r["category"] for r in rows]))
if rows:
    case_ok &= check(rows[0]["owner"] == "home:" + c.home_label() and not rows[0].get("informational"),
                     "merged dirty: the row is not owned or is informational: " + repr(rows[0]))
    case_ok &= check(refusal in rows[0]["next_action"], "merged dirty: the row does not carry the refusal: " + rows[0]["next_action"])
case_ok &= check((copy / "work.txt").read_text() == "uncommitted\n", "merged dirty: the dirty bytes changed")
c = collector("merged-clean")
copy = c.home / "copy"
scratch_copy(copy, False)
task = merged_task(c, "t-clean", copy)
c.tasks, c.backlog = [task], []
with mock.patch.object(module.Collector, "delivered", lambda self, t: True):
    case_ok &= check(not c.merged_cleanup_blocked(task, "t-clean", c.prs[task["pr"]["url"]], "", ""),
                     "control: a clean merged task with no refusal was taken as blocked")
c = collector("merged-wait")
copy = c.home / "copy"
scratch_copy(copy, True)
task = merged_task(c, "t-wait", copy)
c.tasks, c.backlog = [task], []
with mock.patch.object(module.Collector, "report_status", lambda self, ident: (None, "paused", False, True, None, None)), \
     mock.patch.object(module.Collector, "teardown_refusal_record", lambda self, ident: ("", "")):
    c.completion_row(task, "home:" + c.home_label())
case_ok &= check(not [r for r in c.rows.values() if r["subject"] == "t-wait" and r["category"] == "pending_cleanup"],
                 "control: a declared wait got a cleanup row")
if case_ok:
    print("ok - a merged task whose cleanup is refused (dirty copy) is an owned pending_cleanup row carrying the refusal; a clean copy and a declared wait are controls")

# 2d. The ledger's landing check is the same blob proof (Main 1871 P-B): a repository
#     merge driver that keeps the default's side cannot make a differing line landed;
#     a squash of the copy's change is landed.
case_ok = True
def g(path, *a):
    return _sp.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main", "-C", str(path)] + list(a),
                   check=True, capture_output=True, text=True).stdout
c = collector("ledger-blobs")
repo = c.home / "repo"
repo.mkdir()
g(repo, "init", "-q"); (repo / "base.txt").write_text("base\n"); g(repo, "add", "base.txt"); g(repo, "commit", "-q", "-m", "base")
g(repo, "branch", "default")
(repo / "base.txt").write_text("one\n"); g(repo, "commit", "-q", "-am", "copy edits")
g(repo, "checkout", "-q", "default"); (repo / "base.txt").write_text("two\n"); g(repo, "commit", "-q", "-am", "default edits")
g(repo, "checkout", "-q", "main")
(repo / ".git" / "info" / "attributes").write_text("* merge=keep-default\n"); g(repo, "config", "merge.keep-default.driver", "true")
default_tree = g(repo, "rev-parse", "default^{tree}").strip()
merged = g(repo, "merge-tree", "--write-tree", "default", "HEAD").splitlines()[0]
case_ok &= check(merged == default_tree, "fixture: the merge driver did not make merge-tree return the default's tree")
case_ok &= check(not c.content_in_default(str(repo), "default"), "a differing line was landed by the merge driver")
g(repo, "checkout", "-q", "default"); (repo / "base.txt").write_text("one\n"); g(repo, "commit", "-q", "-am", "squash the copy's edit")
g(repo, "checkout", "-q", "main")
case_ok &= check(c.content_in_default(str(repo), "default"), "control: the default's squash of the copy's edit was not landed")
if case_ok:
    print("ok - the ledger's landing check compares blobs: a merge driver cannot land a differing line; a squash is landed")

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
