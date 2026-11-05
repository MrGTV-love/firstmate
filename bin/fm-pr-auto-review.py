#!/usr/bin/env python3
"""Request the missing independent exact-head reads of a green registered PR and merge on a covering PASS.

Usage (FM_HOME names the absolute home; FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE select state and config):
  fm-pr-auto-review.py step TASK    one bounded pass for one registered ship task
  fm-pr-auto-review.py state TASK   print the task's current review-lane state on one line
  fm-pr-auto-review.py events TASK  print the task's review-lane events, oldest first, one `<epoch> <head> <text>` line each

The single caller is bin/fm-pr-ready-reconcile.sh, the watcher's bounded housekeeping pass, so no new
daemon, watcher check, schedule or poll exists. The merge poll (bin/fm-pr-poll.sh) is a static program
that prints only `merged`, so it cannot request anything. A pass takes at most one forward step per
head and never waits: a read runs detached and a later pass collects it.

A pass for a kind=ship task in mode no-mistakes or direct-PR that records a GitHub pr=:
  1. reads the PR once through `gh pr view`; a closed or merged PR ends the work, an unreadable forge
     changes nothing, and a new head starts a new sequence, so a PASS recorded for an older head is
     never counted (bin/fm-review-record.py binds every record to its exact head);
  2. collects the reads it requested earlier for the live head: a finished report is recorded through
     `fm-review-record.py review`, an INCOMPLETE report is held, a FAIL that cannot be recorded still
     ends the head at fail, and a crashed, unusable or nonzero-exit read burns that model for the head
     (a runner that exited nonzero is a failed read even when it left a PASS report; a reported FAIL still
     ends the head). A read of an
     older head never stops the live head from being read; once it ends it is marked returned and is
     never recorded, planned or reported;
  3. stops unless the PR is open, not a draft, mergeable and reported CLEAN or HAS_HOOKS by the forge,
     every check is green as bin/fm-pr-merge.sh judges one (each check run and each status context on its
     own, never the aggregate state alone) and every check the base branch requires has reported. This is
     a fail-closed prefilter for spending a read, never the merge gate: bin/fm-pr-merge.sh re-reads every
     condition live and stays the only authority;
  4. asks `fm-review-record.py verify --json`. A qualifying independent-review PASS goes to
     bin/fm-pr-merge.sh <task> <url> with no other argument, never an override, waiver or captain word,
     and a captain-word basis is left to Main. Otherwise `fm-review-record.py plan` names the author
     families still uncovered and one read is requested for them. While the PR sits in a merge
     queue that fm-pr-merge.sh reported, nothing is called again while the forge reports it queued; once
     the forge reports it out of the queue and still open, the head is held for Main once with one wake and
     fm-pr-merge.sh is never called again for that head, and a merged PR still ends merged.
Counting rule: for one head and one reader model there is at most one request, whether it is
outstanding, finished or failed, so a repeat pass, a restart or a second caller makes no duplicate.
While a read is outstanding no further read is requested for that head. A model whose read failed
without a usable report is never asked again for that head; the next eligible model is.

Reader models come from the single rule in config/crew-dispatch.json whose `when` starts with
"Isolated independent quality review" (the rule bin/fm-review-agent-select.sh reads): its `use`
entries in order, then its `fallback` entries. A model covers every uncovered family but its own;
the model that covers most is taken (rule order breaks a tie), and a model of an uncovered family
is never taken to cover that family. An unknown author family is never asked for: it is reported once
per head as `author family unknown`.
The review runner is a home setting, never a path in this script: FM_REVIEW_RUNNER, else the first
non-comment line of config/review-runner. Unset, relative or not executable makes no request and records one
`review runner unavailable: <why>` line per head.

Everything durable is under <state>/.pr-auto-review/: <task>.json is the sidecar (request, outstanding
read, verdict, merge attempt, events, next due time) and <task>.d/ holds one directory per request with
the review pack the runner reads, its lock and its report. The pack's diff is used only when the PR
head fm-review-diff.sh fetched is the head being read. The reader runs detached under a flock the
sidecar test can probe, so a restart neither loses a read nor repeats it. Outcomes are sidecar events
(read requested, verdict recorded, queued, merged with the full PR URL, fail, held with its reason, no
eligible reader, runner unavailable) and, for every lasting hold, one check wake per head and reason;
the merge itself also writes the merge outcome and fleet-ledger record that bin/fm-pr-merge.sh owns.
`state` prints reading, waiting: <reason>, queued, merged, fail, held: <reason> or idle, and `events` prints the history. Nothing is written to the task's status log,
because a `note:` there would replace the worker's `done:` as the latest event.

A report is accepted only when its raw first line is exactly `VERDICT: <PASS|FAIL|INCOMPLETE> head=<head>`
(the rule `fm-review-record.py review` applies), its last line is `VERDICT: <same word>`, and the three
facts each stand on a line that names the fact followed by yes or no: `loosens a deny or allow list`,
`widens what a guard permits`, `touches customer data, billing or spend`. A PASS missing a fact is
unusable. The runner asks the reader for one line exactly `Protected class: yes - <why>` or
`Protected class: no - <why>`: yes, a missing line or a malformed one holds the merge for Main, and only
no lets a covering PASS merge; a `protected=<class>` field in the task's meta also holds it. The model
that served a read is read only from one runner stdout line exactly `served-model: <model id>`; with
none the read is never recorded, the head is held as `served model unknown` for Main, and no further
read is requested for it. Main's runner prints that line only when one model served every reply and
prints nothing otherwise, so a read it cannot vouch for holds for Main.
Before any reader is dispatched the contract must be complete: a non-empty brief.md, at least one
non-empty Definition Of Done (the brief's `## Definition Of Done (task)` section, the file its unfenced in-section
`DoD file:` line names under data/, or data/dod/<task>.md, all read through bin/fm-dod-lib.sh's section reader) and
that named file; otherwise the head is held as `review pack not built: contract source missing: <names>` and nothing runs.
The protected-class decision reads every review row recorded for the exact head, whoever recorded it:
any yes, missing or malformed answer, any report that is gone or no longer matches its recorded digest,
and any unreadable history holds the merge, and a later `no` never clears an earlier answer. A recorded
routine PASS that verify accepts, with every exact-head report answering `no`, goes to the merge gate
whether or not this lane requested it. A wake that could not be appended is kept pending in the sidecar,
is not counted as emitted, and every pass retries it. A local-only task never reaches this script's merge
path, and an away record is left to bin/fm-pr-merge.sh's own away handling.
Exit status: 0 for every pass that ran, 2 for a usage error.
"""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.parse

BIN = Path(__file__).resolve().parent
RULE_PREFIX = "Isolated independent quality review"
PR_URL = re.compile(r"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)/pull/([1-9][0-9]*)")
SHA = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
GREEN_STATES = ("CLEAN", "HAS_HOOKS")
CLASSES = ("destructive", "irreversible", "security-sensitive")
FACTS = (("loosens_deny_allow_list", r"loosens\s+a\s+deny\s+or\s+allow[\s-]*list"),
         ("widens_guard", r"widens\s+what\s+a\s+guard\s+permits"),
         ("customer_data_billing_spend", r"touches\s+customer\s+data,?\s+billing\s+or\s+spend"))
# A cadence, not a bound on any work: a head with nothing to do costs one forge read per interval.
INTERVAL = int(os.environ.get("FM_PR_AUTO_REVIEW_INTERVAL", "120") or 0)
MERGE_RETRY = int(os.environ.get("FM_PR_AUTO_REVIEW_MERGE_RETRY", "600") or 0)


_RECORD_MODULE = []


def load_record_module():
    if not _RECORD_MODULE:
        spec = importlib.util.spec_from_file_location("fm_review_record", BIN / "fm-review-record.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _RECORD_MODULE.append(module)
    return _RECORD_MODULE[0]


def family(model_id):
    return load_record_module().model(model_id, "model")


class Home:
    def __init__(self):
        home = os.environ.get("FM_HOME", "")
        if not home or not os.path.isabs(home):
            raise SystemExit("error: FM_HOME must name the absolute home")
        self.home = Path(home)
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE") or self.home / "state")
        self.config = Path(os.environ.get("FM_CONFIG_OVERRIDE") or self.home / "config")
        self.data = Path(os.environ.get("FM_DATA_OVERRIDE") or self.home / "data")
        self.root = self.state / ".pr-auto-review"

    def env(self):
        return {**os.environ, "FM_HOME": str(self.home), "FM_STATE_OVERRIDE": str(self.state),
                "FM_CONFIG_OVERRIDE": str(self.config)}


def run(command, home=None, **kwargs):
    try:
        return subprocess.run(command, capture_output=True, text=True, check=False,
                              env=home.env() if home else None, **kwargs)
    except OSError as exc:  # a missing tool is a failed read, never a crash of the pass
        return subprocess.CompletedProcess(command, 127, "", str(exc))


def read_meta(home, task):
    try:
        lines = (home.state / f"{task}.meta").read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None
    return dict(line.split("=", 1) for line in lines if "=" in line)


def write_atomic(path, text):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def slug(text):
    return re.sub(r"[^A-Za-z0-9._-]", "_", text)


class Sidecar:
    def __init__(self, home, task, url):
        self.path = home.root / f"{task}.json"
        self.data = {"v": 1, "pr": url, "heads": {}}
        try:
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict) and loaded.get("pr") == url and isinstance(loaded.get("heads"), dict):
                self.data = loaded
        except (OSError, ValueError):
            pass

    def head(self, sha):
        return self.data["heads"].setdefault(sha, {"attempts": {}, "emitted": [], "outcome": None, "seen": time.time()})

    def prune(self, current):
        """Keep the five most recently seen heads, the current and phase heads, and every head with a read out."""
        heads = self.data["heads"]
        keep = {current, self.data.get("phase", {}).get("head")}
        for old in sorted(heads, key=lambda sha: heads[sha].get("seen", 0), reverse=True)[5:]:
            if old not in keep and not any(a["state"] == "requested" for a in heads[old]["attempts"].values()):
                del heads[old]

    def save(self):
        write_atomic(self.path, json.dumps(self.data, sort_keys=True, indent=1) + "\n")


def phase(side, sha, name, detail=""):
    side.data["phase"] = {"head": sha, "state": name, "detail": detail}


def emit(home, task, side, sha, key, text, wake=None):
    """One durable event per distinct occurrence, plus one check wake when Main must act.

    Events live in the sidecar, never in the worker's own status log: a trailing `note:` there would
    replace the worker's `done:` as the latest event and change how bin/fm-crew-state.sh reads a ship
    whose PR is in review. An event whose wake could not be appended is pending, not emitted, until
    flush_wakes delivers it.
    """
    head = side.head(sha)
    if key in head["emitted"]:
        return
    pending = side.data.setdefault("pending", [])
    if wake:
        script = '. "$1/fm-wake-lib.sh" && fm_wake_append check "$2" "$3"'
        sent = run(["bash", "-c", script, "fm-pr-auto-review", str(BIN), f"pr-review:{task}:{sha[:12]}:{key}",
                    f"check: pr-review {task}: {wake}"], home)
        if sent.returncode != 0:
            # Not delivered, so not emitted: the event and its key wait in the sidecar and every pass retries them.
            if not any(item["sha"] == sha and item["key"] == key for item in pending):
                pending.append({"sha": sha, "key": key, "text": text, "wake": wake})
            side.save()
            return
    side.data["pending"] = [item for item in pending if not (item["sha"] == sha and item["key"] == key)]
    events = side.data.setdefault("events", [])
    events.append({"at": int(time.time()), "head": sha[:12], "text": text})
    del events[:-100]
    head["emitted"].append(key)
    side.save()


def flush_wakes(home, task, side):
    """Retry every wake that could not be appended, before any early return of the pass."""
    for item in list(side.data.get("pending", [])):
        emit(home, task, side, item["sha"], item["key"], item["text"], item["wake"])


def gh_view(url):
    fields = "state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,baseRefOid,statusCheckRollup"
    result = run(["gh", "pr", "view", url, "--json", fields])
    try:
        view = json.loads(result.stdout) if result.returncode == 0 else None
    except ValueError:
        view = None
    return view if isinstance(view, dict) and SHA.fullmatch(str(view.get("headRefOid", ""))) else None


def queue_state(url):
    """`open` only when the forge answers that the PR is open, unmerged and out of the merge queue; otherwise `wait`.

    The query is bin/fm-pr-merge.sh's. An unreadable answer, a PR still queued and a PR that has merged
    since the pass read it all wait: the next pass reads the forge again and finds the real state.
    """
    owner, repo, number = PR_URL.fullmatch(url).groups()
    result = run(["gh", "api", "graphql", "-f",
                  "query=query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo)"
                  "{pullRequest(number:$number){state merged isInMergeQueue baseRefName}}}",
                  "-F", f"owner={owner}", "-F", f"repo={repo}", "-F", f"number={number}", "--jq",
                  '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), '
                  '"queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // "")'])
    answer = result.stdout.splitlines() if result.returncode == 0 else []
    return "open" if {"state=OPEN", "merged=false", "queued=false"} <= set(answer) else "wait"


def checks_not_green(rollup):
    """(state, name) for each check that is not green, judged as bin/fm-pr-merge.sh judges it; None when unreadable.

    A status context is green only as SUCCESS. A check run is green as SUCCESS, NEUTRAL or SKIPPED; a
    non-green run of a name stays red unless every such run is completed, dated to the whole second and
    started before a green run of the same name.
    """
    problems, runs = [], {}
    for index, entry in enumerate(rollup):
        if not isinstance(entry, dict):
            return None
        if entry.get("__typename") == "CheckRun":
            name = entry.get("name") or ""
            started = entry.get("startedAt")
            runs.setdefault((name, -1) if name else ("", index), []).append({
                "name": name or "(unnamed check)", "completed": entry.get("status") == "COMPLETED",
                "ok": entry.get("status") == "COMPLETED" and entry.get("conclusion") in ("SUCCESS", "NEUTRAL", "SKIPPED"),
                "at": started if isinstance(started, str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", started) else None})
        elif entry.get("state") != "SUCCESS":
            problems.append(("pending" if entry.get("state") in ("PENDING", "EXPECTED") else "failed",
                             entry.get("context") or "(unnamed check)"))
    for group in runs.values():
        reds = [run_ for run_ in group if not run_["ok"]]
        greens = [run_["at"] for run_ in group if run_["ok"] and run_["at"]]
        if reds and (not greens or any(not r["completed"] or r["at"] is None for r in reds) or max(r["at"] for r in reds) >= max(greens)):
            problems.append(("pending" if any(not r["completed"] for r in reds) else "failed", reds[0]["name"]))
    return problems


def required_contexts(url, base):
    """(names, why): the contexts the base branch requires, from classic protection and active rulesets; why when unreadable."""
    owner, repo, _ = PR_URL.fullmatch(url).groups()
    segment = urllib.parse.quote(base, safe="")
    names, why = set(), ""

    def add(context):
        nonlocal why
        if isinstance(context, str) and context:
            names.add(context)
        else:
            why = "a required check name is unreadable"

    branch = run(["gh", "api", f"repos/{owner}/{repo}/branches/{segment}"])
    try:
        payload = json.loads(branch.stdout) if branch.returncode == 0 else None
    except ValueError:
        payload = None
    if not isinstance(payload, dict) or not isinstance(payload.get("protected"), bool):
        why = "the branch protection summary could not be read"
    elif payload["protected"]:
        required = (payload.get("protection") or {}).get("required_status_checks")
        if not isinstance(required, dict):
            why = "the branch protection summary could not be read"
        else:
            for item in required.get("checks") or []:
                add(item.get("context") if isinstance(item, dict) else None)
            for context in required.get("contexts") or []:
                add(context)
    rules = run(["gh", "api", "--paginate", f"repos/{owner}/{repo}/rules/branches/{segment}"])
    if rules.returncode != 0:
        if "Upgrade to GitHub Pro or make this repository public" not in rules.stderr:
            why = "the branch rules could not be read"
        return names, why
    decoder, text, index = json.JSONDecoder(), rules.stdout, 0
    try:
        while index < len(text):
            if text[index].isspace():
                index += 1
                continue
            page, index = decoder.raw_decode(text, index)
            for rule in page if isinstance(page, list) else [None]:
                if not isinstance(rule, dict):
                    raise ValueError("rules payload is unreadable")
                if rule.get("type") == "required_status_checks":
                    for item in (rule.get("parameters") or {}).get("required_status_checks") or []:
                        add(item.get("context") if isinstance(item, dict) else None)
    except ValueError:
        why = "the branch rules could not be read"
    return names, why


def ready_reason(url, view):
    """None when the forge reports the head ready to be read, else why not."""
    if str(view.get("state", "")).upper() != "OPEN":
        return "pull request is not open"
    if view.get("isDraft") is not False:
        return "pull request is a draft"
    if view.get("mergeable") != "MERGEABLE":
        return f"pull request is {view.get('mergeable') or 'not mergeable'}"
    if view.get("mergeStateStatus") not in GREEN_STATES:
        return f"forge merge state is {view.get('mergeStateStatus') or 'unreadable'}, not green"
    rollup = view.get("statusCheckRollup")
    problems = checks_not_green(rollup) if isinstance(rollup, list) else None
    if problems is None:
        return "check rollup unreadable"
    for state, name in problems:
        return f"a check is still pending: {name}" if state == "pending" else f"check {name} is not green"
    required, why = required_contexts(url, view.get("baseRefName") or "main")
    if why:
        return f"required checks unreadable: {why}"
    reported = {entry.get("name") or entry.get("context") for entry in rollup if isinstance(entry, dict)}
    for context in sorted(required - reported):
        return f"required check {context} has not reported"
    return None


def runner_path(home):
    path = os.environ.get("FM_REVIEW_RUNNER", "").strip()
    if not path:
        try:
            for line in (home.config / "review-runner").read_text(encoding="utf-8").splitlines():
                if line.strip() and not line.lstrip().startswith("#"):
                    path = line.strip()
                    break
        except (OSError, UnicodeError):
            pass
    if not path:
        return None, "FM_REVIEW_RUNNER and config/review-runner are both unset"
    if not os.path.isabs(path):
        return None, f"{path} is not an absolute path"
    if not (os.path.isfile(path) and os.access(path, os.X_OK)):
        return None, f"{path} is not an executable file"
    return path, ""


def candidate_models(home):
    try:
        rules = json.loads((home.config / "crew-dispatch.json").read_text(encoding="utf-8")).get("rules", [])
    except (OSError, ValueError, AttributeError):
        return None, "config/crew-dispatch.json is unreadable"
    matching = [r for r in rules if isinstance(r, dict) and str(r.get("when", "")).startswith(RULE_PREFIX)]
    if len(matching) != 1:
        return None, f"config/crew-dispatch.json has {len(matching)} rules for '{RULE_PREFIX}', not exactly one"
    tiers = []
    for tier in ("use", "fallback"):
        entries = matching[0].get(tier) or []
        tiers.append([e["model"] for e in entries if isinstance(e, dict) and isinstance(e.get("model"), str)])
    return tiers, ""


def choose_reader(tiers, tried, owed):
    """The first tier's model covering most owed families, rule order breaking a tie; None when none covers any."""
    for models in tiers:
        best = None
        for model_id in models:
            fam = family(model_id)
            if model_id in tried or fam == "unknown":
                continue
            covers = sorted(f for f in owed if f != fam)
            if covers and (best is None or len(covers) > len(best[1])):
                best = (model_id, covers)
        if best:
            return best
    return None


def author_plan(home, task, url, sha, base):
    result = run([sys.executable, str(BIN / "fm-review-record.py"), "plan", "--pr", url, "--head", sha,
                  "--task", task, "--base", base], home)
    try:
        plan = json.loads(result.stdout)
    except ValueError:
        return None, "the review record owner returned no plan"
    if not isinstance(plan, dict) or plan.get("ok") is not True:
        message = (plan.get("error") or {}).get("message") if isinstance(plan, dict) else None
        return None, f"review plan unavailable: {str(message or result.stdout.strip())[:200]}"
    return plan, ""


def ensure_objects(meta, sha, base):
    worktree = meta.get("worktree", "")
    if not worktree or not os.path.isdir(worktree):
        return
    missing = [ref for ref in (base, sha)
               if run(["git", "-C", worktree, "cat-file", "-e", f"{ref}^{{commit}}"]).returncode]
    if missing:
        run(["git", "-C", worktree, "fetch", "--quiet", "origin", *missing])


def verify(home, task, url, sha, base):
    result = run([sys.executable, str(BIN / "fm-review-record.py"), "verify", "--pr", url, "--head", sha,
                  "--task", task, "--base", base, "--json"], home)
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"ok": False, "error": {"kind": "unavailable", "message": result.stdout.strip() or result.stderr.strip()}}


def latest_review(home, url):
    result = run([sys.executable, str(BIN / "fm-review-record.py"), "latest", "--pr", url], home)
    try:
        return (json.loads(result.stdout) or {}).get("review")
    except ValueError:
        return None


def parse_report(path, sha):
    """(verdict, facts, protected, problem): problem is None for a usable report.

    A report whose exact first line names this head keeps its verdict even when a later part is
    unusable, so a FAIL is never mistaken for a read that said nothing. protected is "no",
    "yes - <why>", "missing" or "malformed".
    """
    try:
        raw = Path(path).read_bytes()
    except OSError:
        return None, {}, None, "no readable report"
    first = re.fullmatch(rb"VERDICT: (PASS|FAIL|INCOMPLETE) head=([0-9a-f]{40}|[0-9a-f]{64})", raw.partition(b"\n")[0])
    if not first:
        return None, {}, None, "first line is not exactly 'VERDICT: <PASS|FAIL|INCOMPLETE> head=<head>'"
    verdict, named = first.group(1).decode(), first.group(2).decode()
    if named != sha:
        return None, {}, None, f"report names head {named}, not {sha}"
    try:
        lines = [line for line in raw.partition(b"\n")[2].decode("utf-8").splitlines() if line.strip()]
    except UnicodeError:
        return verdict, {}, None, "the report is not UTF-8"
    if not lines or lines[-1].strip() != f"VERDICT: {verdict}":
        return verdict, {}, None, "last line does not repeat the first line's verdict"
    facts = {}
    for key, phrase in FACTS:
        answers = set()
        for line in lines[:-1]:
            match = re.search(phrase + r"[\s:|*_`()=\-–—]*\b(yes|no)\b", line, re.IGNORECASE)
            if match:
                answers.add(match.group(1).lower())
        if len(answers) == 1:
            facts[key] = answers.pop()
    named_lines = [line.strip() for line in lines[:-1] if re.match(r"\W*protected class\b", line, re.IGNORECASE)]
    answer = re.fullmatch(r"Protected class: (yes|no) - (\S.*)", named_lines[0]) if len(named_lines) == 1 else None
    if answer:
        protected = "no" if answer.group(1) == "no" else f"yes - {answer.group(2)}"
    else:
        protected = "malformed" if named_lines else "missing"
    return verdict, facts, protected, None


def read_status(att):
    """'running' while the detached reader holds its lock, 'done' once it wrote its result, else why it ended without one."""
    adir = Path(att["dir"]).parent / (Path(att["dir"]).name + ".run")
    if (adir / "result.json").exists():
        return "done"
    try:
        with open(adir / "lock", "a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # The reader writes its result before it lets go of the lock, so look again.
            return "done" if (adir / "result.json").exists() else "the read ended without a result"
    except BlockingIOError:
        return "running"
    except OSError:
        return "the read left no lock or result"


def retire(side, live):
    """Mark every ended read of a head that is no longer live as returned, unrecorded and unreported."""
    for sha, head in side.data["heads"].items():
        for att in head["attempts"].values() if sha != live else ():
            if att["state"] == "requested" and read_status(att) != "running":
                att.update(state="returned", reason="the head was superseded before the read ended")


def collect(home, task, url, sha, base, side, meta):
    """Fold the live head's finished reads into the sidecar and record their verdicts; True while one is still outstanding."""
    head = side.head(sha)
    outstanding = False

    def burn(att, model_id, text, reason, key=None, wake=None):
        att.update(state="failed", reason=reason)
        emit(home, task, side, sha, key or f"failed:{model_id}", text, wake)

    def stand_failed(att, actual, report, why=""):
        att["state"] = "returned" if why else "recorded"
        head["outcome"] = {"kind": "fail", "detail": report}
        phase(side, sha, "fail", f"report {report}")
        ran = f"; the runner exited {att['exited']}" if att.get("exited") else ""
        emit(home, task, side, sha, "fail", f"fail: {sha[:12]} read by {actual}, report {report}" + (f" (not recorded: {why})" if why else "") + ran,
             f"FAIL at {sha[:12]} read by {actual}; findings are in {report}{ran}")

    for model_id, att in sorted(head["attempts"].items(), key=lambda item: item[1]["at"]):
        if att["state"] != "requested":
            continue
        status = read_status(att)
        if status == "running":
            outstanding = True
            phase(side, sha, "reading", f"{sha[:12]} by {model_id}")
            continue
        if status != "done":
            att.update(state="failed", reason=status)
            emit(home, task, side, sha, f"failed:{model_id}", f"read of {sha[:12]} by {model_id} failed: {status}")
            continue
        result_path = Path(att["dir"]).parent / (Path(att["dir"]).name + ".run") / "result.json"
        try:
            outcome = json.loads(result_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            outcome = {}
        served = outcome.get("served_model")
        named = served or model_id
        report = outcome.get("report") or ""
        verdict, facts, _, problem = parse_report(report, sha) if report else (None, {}, None, "the runner wrote no report")
        quota = " (usage limit reached)" if "usage_limit_reached" in str(outcome.get("tail", "")) else ""
        exited = outcome.get("rc", 0)
        att["exited"] = exited
        if exited != 0 and verdict != "FAIL":
            # A failed run is a failed read even when it left a report: burn the model, the next one is asked.
            burn(att, model_id, f"read of {sha[:12]} by {named} failed: the runner exited {exited}{quota}", f"the runner exited {exited}{quota}")
            continue
        if problem and verdict == "FAIL":
            stand_failed(att, named, report, problem)
            continue
        if problem:
            burn(att, model_id, f"read of {sha[:12]} by {named} unusable: {problem}{quota}", problem + quota)
            continue
        if not served:
            att.update(state="returned", report=report, verdict=verdict)
            head["outcome"] = {"kind": "served-model-unknown", "detail": report}
            phase(side, sha, "held", f"served model unknown for the read requested from {model_id}, report {report}")
            emit(home, task, side, sha, "served-model-unknown",
                 f"held: served model unknown at {sha[:12]}: the runner printed no 'served-model:' line for the read requested from {model_id}, report {report}",
                 f"served model unknown for the read of {sha[:12]} requested from {model_id}; not recorded, report {report}, the merge is Main's")
            continue
        att.update(report=report, verdict=verdict, actual_model=served, exited=exited)
        if verdict == "INCOMPLETE":
            att["state"] = "returned"
            head["outcome"] = {"kind": "incomplete", "detail": report}
            phase(side, sha, "held", f"review INCOMPLETE, report {report}")
            emit(home, task, side, sha, "incomplete", f"held: review INCOMPLETE at {sha[:12]} by {served}, report {report}",
                 f"INCOMPLETE read of {sha[:12]} by {served}; missing evidence or decision is in {report}")
            continue
        if len(facts) < 3:
            if verdict == "FAIL":
                stand_failed(att, served, report, "the report states no clear yes or no for every fact")
            else:
                names = ", ".join(k for k, _ in FACTS if k not in facts)
                reason = f"PASS report states no clear yes or no for: {names}"
                burn(att, model_id, f"read of {sha[:12]} by {served} unusable: {reason}", reason)
            continue
        plan, why = author_plan(home, task, url, sha, base)
        if plan is None:
            if verdict == "FAIL":
                stand_failed(att, served, report, why)
            else:
                burn(att, model_id, f"held: cannot record the PASS of {sha[:12]}: {why}", why, f"plan:{why}", f"cannot record the PASS of {sha[:12]}: {why}")
            continue
        reader_family = family(served)
        covered = sorted(g for g, authors in plan["groups"].items() if any(a["family"] != reader_family for a in authors))
        if not covered and verdict == "PASS":
            reason = f"reader family {reader_family} covers none of the author groups"
            burn(att, model_id, f"read of {sha[:12]} by {served} covers nothing: {reason}", reason)
            continue
        # A FAIL counts whatever the reader's family, so it names every group it read.
        covered = covered or sorted(plan["groups"])
        newest = latest_review(home, url)
        if not (newest and newest.get("head") == sha and newest.get("report") == report and newest.get("verdict") == verdict):
            groups = {g: sorted({a["model"] for a in authors}) for g, authors in plan["groups"].items()}
            command = [sys.executable, str(BIN / "fm-review-record.py"), "review", "--pr", url, "--head", sha,
                       "--verdict", verdict, "--reader-model", served, "--author-groups", json.dumps(groups),
                       "--covered-groups", json.dumps(covered), "--report", report]
            for key, _ in FACTS:
                command += [f"--{key.replace('_', '-')}", facts[key]]
            recorded = run(command, home)
            if recorded.returncode != 0:
                why = f"the record owner did not record it: {(recorded.stdout or recorded.stderr).strip()[:200]}"
                if verdict == "FAIL":
                    stand_failed(att, served, report, why)
                else:
                    burn(att, model_id, f"read of {sha[:12]} by {served} unusable: {why}", why, "record:PASS",
                         f"could not record the PASS of {sha[:12]} by {served}: {why}")
                continue
        if verdict == "FAIL":
            stand_failed(att, served, report)
        else:
            att["state"] = "recorded"
            emit(home, task, side, sha, f"recorded:{served}", f"verdict recorded: PASS for {sha[:12]} by {served}, report {report}")
    side.save()
    return outstanding


def brief_dod(brief):
    """(present, span, pointer) for the brief's Definition Of Done, read by bin/fm-dod-lib.sh, the one owner of that section.

    present: the `## Definition Of Done (task)` heading exists outside a fence. span: the lines through
    `## How You're Graded`. pointer: the unfenced `DoD file: <absolute path>` line inside that span, if any.
    Returns None when the reader itself failed, which the caller reports as a missing source.
    """
    script = ('. "$1/fm-dod-lib.sh" || exit 3; fm_brief_heading_present "$2" "$FM_TASK_DOD_SECTION_TITLE" || exit 4; '
              'fm_brief_task_dod_file "$2"; printf "\\0"; '
              'fm_brief_heading_span "$2" "$FM_TASK_DOD_SECTION_TITLE" "$FM_TASK_DOD_GRADED_TITLE"')
    done = run(["bash", "-c", script, "fm-pr-auto-review", str(BIN), str(brief)])
    if done.returncode == 4:
        return False, "", ""
    if done.returncode != 0 or "\0" not in done.stdout:
        return None
    pointer, span = done.stdout.split("\0", 1)
    return True, span, pointer.strip()


def contract_text(home, task):
    """(text, absent): the brief, its Definition Of Done and every steering message, which is what the reader judges against.

    absent names each required source that is missing or empty: the brief, at least one Definition Of
    Done and the file a DoD pointer names. A Definition Of Done is the brief's own section, or the file
    its unfenced in-section `DoD file: <absolute path>` line names (which then replaces the section, as
    bin/fm-dod-lib.sh reads it), or data/dod/<task>.md. A pointer outside data/ is never read.
    Steering messages are optional.
    """
    brief = home.data / task / "brief.md"
    data_root = Path(os.path.realpath(home.data))
    text = brief.read_text(encoding="utf-8", errors="replace") if brief.is_file() else ""
    parts, absent, dod, pointer, seen = [], [], False, "", set()
    sources = [(f"dod/{task}.md", home.data / "dod" / f"{task}.md")]
    if text.strip():
        parts.append(f"<!-- brief.md -->\n{text}")
        seen.add(text)
        section = brief_dod(brief)
        if section is None:
            absent.append("the Definition Of Done reader (bin/fm-dod-lib.sh) failed")
        else:
            present, span, pointer = section
            dod = present and not pointer and bool(span.strip())
            target = Path(os.path.realpath(pointer)) if pointer else None
            if target is not None and data_root in target.parents:
                sources.insert(0, (f"DoD file {target.name}", target))
    else:
        absent.append("brief.md")
    for name, path in sources:
        body = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""
        if not body.strip():
            if name.startswith("DoD file "):
                absent.append(name)
            continue
        dod = True
        if body not in seen:
            seen.add(body)
            parts.append(f"<!-- {name} -->\n{body}")
    if not dod:
        absent.append("a Definition Of Done (the brief's section, a DoD file it names, or dod/<task>.md)")
    for folder in (home.state / f"{task}.inbox" / "handled", home.state / f"{task}.inbox"):
        for message in sorted(folder.glob("*.msg")) if folder.is_dir() else []:
            body = message.read_text(encoding="utf-8", errors="replace").split("\n--\n", 1)[-1]
            parts.append(f"## Main ruling {message.name}\n{body}")
    return "\n\n".join(parts), absent


def ci_text(sha, view):
    rows = [f"# CI evidence: check runs at head {sha}"]
    for entry in view.get("statusCheckRollup") or []:
        name = entry.get("name") or entry.get("context") or "(unnamed)"
        rows.append(f"- {name}: status={entry.get('status') or entry.get('state')} conclusion={entry.get('conclusion')}")
    return "\n".join(rows) + "\n"


def request_read(home, task, url, sha, base, side, meta, view, plan, model_id, covers):
    contract, absent = contract_text(home, task)
    if absent:
        return f"contract source missing: {', '.join(absent)}"
    runner, _ = runner_path(home)
    review_dir = home.root / f"{task}.d" / f"{sha[:12]}-{slug(model_id)}"
    review_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    worktree, number = meta.get("worktree", ""), PR_URL.fullmatch(url).group(3)
    if not os.path.isabs(worktree):
        return "diff unavailable: the task records no absolute worktree"
    pulled = f"refs/fm-review/pull/{number}/head"
    run(["git", "-C", worktree, "update-ref", "-d", pulled])
    diff = run([str(BIN / "fm-review-diff.sh"), task], home)
    if diff.returncode != 0 or not diff.stdout.strip():
        errors = [line for line in diff.stderr.splitlines() if line.startswith("error:")]
        return f"diff unavailable: {(errors[-1] if errors else 'fm-review-diff.sh printed no diff')[:160]}"
    fetched = run(["git", "-C", worktree, "rev-parse", "--verify", "--quiet", f"{pulled}^{{commit}}"]).stdout.strip()
    if fetched != sha:
        return f"diff unavailable: the PR head fm-review-diff.sh fetched is {fetched[:12] or 'none'}, not {sha[:12]}"
    (review_dir / "pr.diff").write_text(diff.stdout, encoding="utf-8")
    (review_dir / "contract.md").write_text(contract, encoding="utf-8")
    (review_dir / "ci-evidence.md").write_text(ci_text(sha, view), encoding="utf-8")
    again = gh_view(url)
    if not again or again["headRefOid"] != sha:
        return "the head moved while the review pack was built"
    run_dir = review_dir.parent / (review_dir.name + ".run")
    run_dir.mkdir(mode=0o700, exist_ok=True)
    request = {"at": int(time.time()), "model": model_id, "dir": str(review_dir), "head": sha, "covers": covers,
               "runner": runner, "pr": url, "root": meta.get("project", ""), "argv_model": model_id}
    write_atomic(run_dir / "request.json", json.dumps(request, indent=1) + "\n")
    head = side.head(sha)
    head["attempts"][model_id] = {"state": "requested", "at": request["at"], "dir": str(review_dir), "covers": covers}
    side.save()
    lock = open(run_dir / "lock", "a+")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "_read", str(run_dir), str(lock.fileno())],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     pass_fds=(lock.fileno(),), start_new_session=True, env=home.env())
    lock.close()
    phase(side, sha, "reading", f"{sha[:12]} by {model_id}")
    emit(home, task, side, sha, f"requested:{model_id}", f"reading {sha[:12]} by {model_id} for {','.join(covers)}")
    return None


def read_worker(run_dir, fd):
    """The detached reader: holds the inherited lock for as long as the runner runs, then writes result.json."""
    run_dir = Path(run_dir)
    request = json.loads((run_dir / "request.json").read_text(encoding="utf-8"))
    command = [request["runner"], request["dir"], request["pr"], request["head"], "pr.diff",
               request["root"], request["argv_model"]]
    done = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False,
                          pass_fds=(int(fd),))
    out = (done.stdout or "") + (done.stderr or "")
    served = re.findall(r"(?m)^served-model: (\S+)$", done.stdout or "")
    report = Path(request["dir"]) / "review.md"
    write_atomic(run_dir / "result.json", json.dumps({
        "rc": done.returncode, "served_model": served[0] if len(served) == 1 else None, "tail": out[-3000:],
        "report": str(report) if report.is_file() and report.stat().st_size else ""}) + "\n")


def step(home, task):
    meta = read_meta(home, task)
    url = (meta or {}).get("pr", "")
    if (meta is None or meta.get("kind") != "ship" or meta.get("mode") not in ("no-mistakes", "direct-PR")
            or not PR_URL.fullmatch(url)):
        return
    home.root.mkdir(mode=0o700, parents=True, exist_ok=True)
    guard = open(home.root / f"{task}.lock", "a+")
    try:
        fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        guard.close()
        return  # another pass for this task is running
    side = Sidecar(home, task, url)
    try:
        advance(home, task, url, meta, side)
    finally:
        side.save()
        guard.close()


def advance(home, task, url, meta, side):
    flush_wakes(home, task, side)
    head_sha = side.data.get("phase", {}).get("head")
    prior = side.head(head_sha) if head_sha else None
    if prior and prior.get("outcome") and prior["outcome"]["kind"] == "merged":
        return
    if time.time() < side.data.get("next_at", 0):
        return
    # A forge read that fails is spaced like one that answers, so an outage is not hammered.
    side.data["next_at"] = int(time.time()) + INTERVAL
    view = gh_view(url)
    if view is None:
        return
    sha, base = view["headRefOid"], view["baseRefOid"]
    side.data["base"] = base
    head = side.head(sha)
    retire(side, sha)
    side.prune(sha)
    if str(view.get("state", "")).upper() == "MERGED":
        if not head.get("outcome"):
            head["outcome"] = {"kind": "merged", "detail": url}
            phase(side, sha, "merged", url)
            emit(home, task, side, sha, "merged", f"merged: {url} at {sha[:12]}")
        side.save()
        return
    if head.get("outcome") or str(view.get("state", "")).upper() != "OPEN":
        side.save()
        return
    if head.get("left_queue"):
        return  # held for Main once: fm-pr-merge.sh is not called again for this head
    if side.data.get("phase", {}).get("head") == sha and side.data["phase"]["state"] == "queued":
        if queue_state(url) == "wait":
            return
        head["left_queue"] = True
        phase(side, sha, "held", "left the merge queue and is still open")
        emit(home, task, side, sha, "left-queue", f"held: {url} at {sha[:12]} left the merge queue and is still open; the merge is Main's",
             f"{url} left the merge queue at {sha[:12]} and is still open; not queued again, Main decides why and whether to merge it")
        return
    ensure_objects(meta, sha, base)
    if collect(home, task, url, sha, base, side, meta) or head.get("outcome"):
        return
    reason = ready_reason(url, view)
    if reason:
        phase(side, sha, "waiting", reason)
        side.save()
        return
    outcome = verify(home, task, url, sha, base)
    error = outcome.get("error") or {}
    if outcome.get("ok") is True:
        if outcome.get("basis") != "independent-review":
            phase(side, sha, "held", "a captain merge word is recorded for this head")
            emit(home, task, side, sha, "captain-word", f"held: a captain merge word is recorded at {sha[:12]}; the merge is Main's",
                 f"a captain merge word is recorded at {sha[:12]}; the merge is Main's")
            return
        merge(home, task, url, sha, side, meta)
        return
    standing = latest_review(home, url)
    if standing and standing.get("head") == sha and standing.get("verdict") == "FAIL":
        head["outcome"] = {"kind": "fail", "detail": standing.get("report", "")}
        phase(side, sha, "fail", f"report {standing.get('report', '')}")
        emit(home, task, side, sha, "fail", f"fail: {sha[:12]}, report {standing.get('report', '')}",
             f"FAIL standing at {sha[:12]}; report {standing.get('report', '')}")
        return
    if error.get("kind") != "not-qualified":
        reason = f"review record {error.get('kind') or 'unavailable'}: {str(error.get('message', ''))[:160]}"
        phase(side, sha, "held", reason)
        emit(home, task, side, sha, f"verify:{reason}", f"held: {reason}", f"{reason} at {sha[:12]}")
        return
    plan, why = author_plan(home, task, url, sha, base)
    if plan is None:
        phase(side, sha, "held", why)
        emit(home, task, side, sha, f"plan:{why}", f"held: {why}", f"{why} at {sha[:12]}")
        return
    owed = sorted({f for item in plan["uncovered"] for f in item["families"]})
    if "unknown" in owed:
        phase(side, sha, "held", "author family unknown")
        emit(home, task, side, sha, "unknown-family", f"held: author family unknown at {sha[:12]}",
             f"author family unknown at {sha[:12]}; no read can cover it, repair the author evidence or give the merge word")
        return
    if not owed:
        reason = "review record leaves nothing to read"
        phase(side, sha, "held", reason)
        emit(home, task, side, sha, "nothing-to-read", f"held: {reason} at {sha[:12]}",
             f"{reason} at {sha[:12]}, yet verify does not accept it: {str(error.get('message', ''))[:160]}")
        return
    runner, why = runner_path(home)
    if not runner:
        phase(side, sha, "held", f"review runner unavailable: {why}")
        emit(home, task, side, sha, "runner-unavailable", f"review runner unavailable: {why}",
             f"review runner unavailable: {why}; set FM_REVIEW_RUNNER or config/review-runner")
        return
    tiers, why = candidate_models(home)
    pick = choose_reader(tiers, set(head["attempts"]), owed) if tiers else None
    if not pick:
        if tiers:
            # Only an exhaustion of the eligible models ends the head; a config read that fails is retried.
            why = f"no model outside {','.join(owed)} is left for {sha[:12]}"
            head["outcome"] = {"kind": "no-eligible-reader", "detail": why}
        phase(side, sha, "held", f"no eligible reader: {why}")
        emit(home, task, side, sha, f"no-eligible-reader:{why}", f"held: no eligible reader: {why}", f"no eligible reader at {sha[:12]}: {why}")
        return
    problem = request_read(home, task, url, sha, base, side, meta, view, plan, pick[0], pick[1])
    if problem:
        phase(side, sha, "held", f"review pack not built: {problem}")
        emit(home, task, side, sha, f"pack:{problem}", f"held: review pack not built for {sha[:12]}: {problem}",
             f"review pack not built for {sha[:12]}: {problem}")
    side.save()


def protected_reasons(url, sha, meta):
    """Why this head is not a routine merge; empty only when every exact-head recorded review answers `Protected class: no`.

    Every review row recorded for the head counts, whoever wrote it and in whatever order: an answer of yes,
    a missing or malformed answer, a report that is gone, changed since it was recorded or does not match
    its row, and a history that cannot be read each hold the merge. A later `no` never clears an earlier answer.
    """
    classes = sorted({c for c in meta.get("protected", "").split(",") if c in CLASSES})
    reasons = [f"protected class {','.join(classes)}"] if classes else []
    record = load_record_module()
    try:
        with record.ledger(False, record.task_home()) as fd:
            _, rows = record.newest(fd, record.canonical_pr(url))
    except (record.RecordError, OSError, ValueError) as exc:
        return reasons + [f"the review record history cannot be read: {str(exc)[:120]}"]
    rows = [row for row in rows if row["kind"] == "review" and row["head"] == sha]
    if not rows:
        reasons.append("no review record for the head answers the protected-class question")
    for row in rows:
        who = f"the {row['verdict']} review by {row['reader_model']}"
        try:
            intact = record.report_digest(row["report"], row["verdict"], sha) == row.get("report_sha256")
        except record.RecordError:
            intact = False
        if not intact:
            reasons.append(f"{who} cannot be verified: its report is missing or changed since it was recorded")
            continue
        verdict, _, protected, problem = parse_report(row["report"], sha)
        if problem or verdict != row["verdict"]:
            reasons.append(f"{who} cannot be verified: {problem or 'its report names another verdict'}")
        elif protected != "no":
            reasons.append(f"protected class {protected}" if protected.startswith("yes") else f"protected class line {protected} in a report")
    return sorted(set(reasons))


def merge(home, task, url, sha, side, meta):
    head = side.head(sha)
    reasons = protected_reasons(url, sha, meta)
    if reasons:
        # Not terminal: the evidence is read again every pass, so a readable report or a repaired history is judged anew.
        reason = "; ".join(reasons)
        phase(side, sha, "held", reason)
        emit(home, task, side, sha, f"protected:{hashlib.sha256(reason.encode()).hexdigest()[:12]}",
             f"held: {reason} at {sha[:12]}; the merge is Main's",
             f"{url} held: {reason}; not merged, Main decides it and takes a protected class to the captain")
        return
    attempt = head.get("merge") or {}
    if time.time() < attempt.get("next_at", 0):
        return
    done = run([str(BIN / "fm-pr-merge.sh"), task, url], home)
    if done.returncode == 0 and re.search(rf"(?m)^verified: {re.escape(url)} is queued ", done.stdout):
        phase(side, sha, "queued", url)
        emit(home, task, side, sha, "queued", f"queued: {url} at {sha[:12]} is in the merge queue")
        return
    if done.returncode == 0:
        head["outcome"] = {"kind": "merged", "detail": url}
        phase(side, sha, "merged", url)
        emit(home, task, side, sha, "merged", f"merged: {url} at {sha[:12]}")
        return
    output = [line.strip() for line in (done.stderr + done.stdout).splitlines() if line.strip()]
    errors = [line for line in output if line.startswith("error:")]
    reason = (errors[0][6:].strip() if errors else output[-1] if output else f"fm-pr-merge.sh exited {done.returncode}")[:240]
    head["merge"] = {"next_at": int(time.time()) + MERGE_RETRY, "reason": reason}
    phase(side, sha, "held", f"merge not landed: {reason}")
    emit(home, task, side, sha, f"merge:{hashlib.sha256(reason.encode()).hexdigest()[:12]}", f"held: merge not landed at {sha[:12]}: {reason}",
         f"merge of {url} at {sha[:12]} did not land: {reason}")


def sweep(home):
    if not home.root.is_dir():
        return
    for path in home.root.glob("*.json"):
        if not (home.state / f"{path.stem}.meta").exists():
            path.unlink(missing_ok=True)
            (home.root / f"{path.stem}.lock").unlink(missing_ok=True)
            shutil.rmtree(home.root / f"{path.stem}.d", ignore_errors=True)


def state_line(home, task):
    try:
        data = json.loads((home.root / f"{task}.json").read_text(encoding="utf-8"))
        current = data["phase"]
    except (OSError, ValueError, KeyError):
        return "idle"
    name, detail = current["state"], current.get("detail", "")
    return {"reading": f"reading {detail}", "queued": f"queued {detail}", "merged": f"merged {detail}",
            "fail": f"fail {detail}", "held": f"held: {detail}"}.get(name, f"waiting: {detail}")


def events_text(home, task):
    try:
        data = json.loads((home.root / f"{task}.json").read_text(encoding="utf-8"))
        rows = data.get("events", [])
    except (OSError, ValueError):
        return ""
    return "".join(f"{row['at']} {row['head']} {row['text']}\n" for row in rows)


def main(argv):
    if len(argv) == 4 and argv[1] == "_read":
        read_worker(argv[2], argv[3])
        return 0
    if len(argv) != 3 or argv[1] not in ("step", "state", "events") or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", argv[2]):
        print("usage: fm-pr-auto-review.py step|state|events <task-id>", file=sys.stderr)
        return 2
    home = Home()
    if argv[1] == "state":
        print(state_line(home, argv[2]))
        return 0
    if argv[1] == "events":
        sys.stdout.write(events_text(home, argv[2]))
        return 0
    sweep(home)
    try:
        step(home, argv[2])
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        print(f"pr-auto-review: {argv[2]}: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
