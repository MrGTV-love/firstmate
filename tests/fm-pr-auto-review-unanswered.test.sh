#!/usr/bin/env bash
# Helper-level test of one rule in bin/fm-pr-auto-review.py (Main 1849): a pass
# whose `gh pr view` gets no answer records the step state "waiting: the forge did
# not answer the PR read", merges nothing and emits no wake, while a queued, held,
# failed or merged state stands. Only that file is imported; its forge read and
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
    line = case("t-" + state, {"head": "b" * 40, "state": state, "detail": detail})
    ok &= check(not line.startswith("waiting: the forge did not answer"), f"a {state} state was replaced by the unanswered read: {line}")
if ok:
    print("ok - an unanswered PR read records 'waiting: the forge did not answer the PR read' with no merge, no wake and no process; a queued, held, failed or merged state stands")
sys.exit(1 if failed else 0)
PY
