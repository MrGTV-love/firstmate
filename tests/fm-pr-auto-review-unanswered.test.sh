#!/usr/bin/env bash
# Helper-level test of one rule in bin/fm-pr-auto-review.py (Main 1849): a pass
# whose `gh pr view` gets no answer records the step state "waiting: the forge did
# not answer the PR read", merges nothing and emits no wake, whatever state was
# shown before (Main 1871 F9); a queued, held, failed or merged state is kept aside
# and shown again once the forge answers. Only that file is imported; its forge read and
# every subprocess runner are replaced in-process, so no process starts.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-auto-review-unanswered.XXXXXX") || exit 1
trap 'rm -rf -- "${WORK:?}"' EXIT
FM_HOME="$WORK/home" FM_PR_AUTO_REVIEW_INTERVAL=0 python3 -I - "$ROOT/bin/fm-pr-auto-review.py" <<'PY'
import importlib.util, os, subprocess, sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("fm_pr_auto_review_unanswered", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def no_process(*args, **kwargs):
    raise AssertionError("a process was started: " + repr(args[:1]))
for name in ("run", "Popen", "call", "check_call", "check_output"):
    if hasattr(module.subprocess, name):
        setattr(module.subprocess, name, no_process)
if hasattr(module, "run"):
    module.run = no_process
module.gh_view = lambda url: None
module.emit = lambda *a, **k: (_ for _ in ()).throw(AssertionError("a wake or event was emitted"))

home = module.Home()
home.root.mkdir(parents=True, exist_ok=True)
url = "https://github.com/acme/widget/pull/9"
failed = False

def check(ok, message):
    global failed
    if not ok:
        print("not ok - " + message)
        failed = True
    return ok

def case(task, prior):
    side = module.Sidecar(home, task, url)
    if prior:
        side.data["phase"] = dict(prior)
        side.save()
    side = module.Sidecar(home, task, url)
    module.advance(home, task, url, {}, side)
    return module.state_line(home, task)

ok = True
line = case("t-none", None)
ok &= check(line == "waiting: the forge did not answer the PR read", "no prior state: " + line)
line = case("t-waiting", {"head": "a" * 40, "state": "waiting", "detail": "forge merge state is BEHIND, not green"})
ok &= check(line == "waiting: the forge did not answer the PR read", "an earlier waiting reason was kept over the unanswered read: " + line)
for state, detail in (("queued", url), ("held", "left the merge queue and is still open"), ("fail", "review FAIL"), ("merged", url)):
    prior = {"head": "b" * 40, "state": state, "detail": detail}
    line = case("t-" + state, prior)
    ok &= check(line == "waiting: the forge did not answer the PR read", f"a {state} state hid the unanswered read: {line}")
    side = module.Sidecar(home, "t-" + state, url)
    ok &= check(side.data.get("standing") == prior, f"the {state} state was not kept aside: {side.data.get('standing')}")
    module.answered(side)
    ok &= check(side.data.get("phase") == prior and "standing" not in side.data, f"the {state} state was not shown again once the forge answered")
for closed_state, outcome in (("CLOSED", None), ("OPEN", {"kind": "fail", "detail": "review FAIL"})):
    task = "t-answered-" + closed_state.lower()
    sha = "c" * 40
    line = case(task, {"head": sha, "state": "reading", "detail": "review of " + sha[:12]})
    ok &= check(line == "waiting: the forge did not answer the PR read", f"{task}: the unanswered read was not shown: {line}")
    if outcome:
        side = module.Sidecar(home, task, url)
        side.head(sha)["outcome"] = outcome
        side.save()
    module.gh_view = lambda url, state=closed_state, sha=sha: {"headRefOid": sha, "baseRefOid": "d" * 40, "state": state}
    side = module.Sidecar(home, task, url)
    module.advance(home, task, url, {}, side)
    line = module.state_line(home, task)
    ok &= check(line != "waiting: the forge did not answer the PR read",
                f"{task}: the forge answered ({closed_state}) but the unanswered read was still shown")
    module.gh_view = lambda url: None
if ok:
    print("ok - once the forge answers again, a closed PR or a head with an outcome no longer shows the unanswered read")
if ok:
    print("ok - an unanswered PR read shows 'waiting: the forge did not answer the PR read' over any state, with no merge, no wake and no process; a queued, held, failed or merged state is kept aside and shown again once the forge answers")
sys.exit(1 if failed else 0)
PY
