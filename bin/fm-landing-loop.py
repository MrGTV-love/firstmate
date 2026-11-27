#!/usr/bin/env python3
"""Standalone PR landing loop: reconcile, update stale bases serially, and let carried PASSes merge.

Usage (FM_HOME names the absolute home; FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE select state/config):
  fm-landing-loop.py step [--no-reconcile] [--include-stale-red]   one bounded pass (launchd entrypoint)
  fm-landing-loop.py plan [--include-stale-red] [--json]           read-only plan of candidates and trains
  fm-landing-loop.py status [--json]                               print durable landing-loop state
  fm-landing-loop.py events [--limit N]                            print recent landing-loop events
  fm-landing-loop.py run [--interval N] [--include-stale-red]      foreground loop calling step every N seconds

This program decouples PR landing from Main's chat and watcher lifecycle without adding a second
merge gate or weakening any guard:
  1. It invokes bin/fm-pr-ready-reconcile.sh so registered ready ship PRs continue stepping through
     bin/fm-pr-auto-review.py (independent review + carried PASS verification + bin/fm-pr-merge.sh)
     even while Main's watcher is down.
  2. It scans this home's registered kind=ship GitHub PRs (mode no-mistakes or direct-PR) that are
     open, non-draft, mergeable, and behind their base branch. Before launching any update, it checks
     that merging the live base tip with the PR head is conflict-free via an isolated git merge-tree.
  3. Up to FM_LANDING_LOOP_MAX_INFLIGHT (default 1, strict serial) clean stale-base PRs are updated
     at a time, ordered oldest-first by PR number so concurrent PRs do not race each other in an
     O(N^2) rebase loop:
       - mode=no-mistakes: launches `python3 bin/fm-duration.py run --pipeline-priority merge-train
         fm-landing-update-<task> -- no-mistakes rerun` detached in the task worktree, only when
         `no-mistakes axi status` shows no run active there. Never passes --yes.
       - mode=direct-PR: merges origin/<base> cleanly and pushes HEAD:<branch> only when the
         worktree is clean and merge-tree proved conflict-free.
  4. Every merge still goes through bin/fm-pr-merge.sh (never gh pr merge directly, never
     --attended-override). Main is woken via a deduplicated `check: landing-loop <task>: ...` wake
     only on actionable failures (conflicts, dirty worktrees, failed updates), never on routine
     updates or landings.

Durable state lives under <state>/.landing-loop/: lock, state.json, events.jsonl, inflight.json,
and per-update logs/results under runs/.
Exit status: 0 on normal pass/command, 2 on usage or configuration error.
"""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse

BIN = Path(__file__).resolve().parent
PR_URL = re.compile(r"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)/pull/([1-9][0-9]*)")
SHA = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
MAX_INFLIGHT = int(os.environ.get("FM_LANDING_LOOP_MAX_INFLIGHT", "1") or 1)
RETRY_SECS = int(os.environ.get("FM_LANDING_LOOP_RETRY_SECS", "1800") or 1800)
DEFAULT_INTERVAL = int(os.environ.get("FM_LANDING_LOOP_INTERVAL", "120") or 120)

_AUTO_REVIEW_MOD = []


def load_auto_review():
    if not _AUTO_REVIEW_MOD:
        spec = importlib.util.spec_from_file_location("fm_pr_auto_review", BIN / "fm-pr-auto-review.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _AUTO_REVIEW_MOD.append(mod)
    return _AUTO_REVIEW_MOD[0]


class Home:
    def __init__(self):
        home = os.environ.get("FM_HOME", "")
        if not home or not os.path.isabs(home):
            raise SystemExit("error: FM_HOME must name the absolute home")
        self.home = Path(home)
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE") or self.home / "state")
        self.config = Path(os.environ.get("FM_CONFIG_OVERRIDE") or self.home / "config")
        self.data = Path(os.environ.get("FM_DATA_OVERRIDE") or self.home / "data")
        self.root = self.state / ".landing-loop"

    def env(self):
        return {
            **os.environ,
            "FM_HOME": str(self.home),
            "FM_STATE_OVERRIDE": str(self.state),
            "FM_CONFIG_OVERRIDE": str(self.config),
            "FM_DATA_OVERRIDE": str(self.data),
        }


def run(command, home=None, cwd=None, timeout=None):
    try:
        return subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            check=False,
            env=home.env() if home else None,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(command, 127, "", str(exc))


def write_atomic(path, text):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_json(path, default):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, type(default)) else default
    except (OSError, ValueError):
        return default


def append_event(home, task, pr, head, kind, detail):
    home.root.mkdir(mode=0o700, parents=True, exist_ok=True)
    row = {
        "at": int(time.time()),
        "task": task,
        "pr": pr,
        "head": (head or "")[:12],
        "kind": kind,
        "detail": detail,
    }
    path = home.root / "events.jsonl"
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, separators=(",", ":")) + "\n")


def emit_wake_once(home, state_doc, task, pr, head, key, text):
    emitted = state_doc.setdefault("emitted_wakes", {})
    dedup = f"{task}:{(head or '')[:12]}:{key}"
    if dedup in emitted:
        return False
    script = '. "$1/fm-wake-lib.sh" && fm_wake_append check "$2" "$3"'
    sent = run(
        ["bash", "-c", script, "fm-landing-loop", str(BIN), f"landing-loop:{dedup}",
         f"check: landing-loop {task}: {text}"],
        home,
    )
    if sent.returncode == 0:
        emitted[dedup] = int(time.time())
        append_event(home, task, pr, head, "wake", text)
        return True
    return False


def read_meta(path):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None
    return dict(line.split("=", 1) for line in lines if "=" in line)


def ship_tasks(home, repo_filter=None):
    if not home.state.is_dir():
        return []
    want_repo = (repo_filter or os.environ.get("FM_LANDING_LOOP_REPO", "")).strip().lower()
    found = []
    for meta_path in sorted(home.state.glob("*.meta")):
        if meta_path.is_symlink() or not meta_path.is_file():
            continue
        task = meta_path.stem
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", task):
            continue
        meta = read_meta(meta_path)
        if not meta:
            continue
        if meta.get("kind") != "ship":
            continue
        if meta.get("mode") not in ("no-mistakes", "direct-PR"):
            continue
        pr = meta.get("pr", "")
        match = PR_URL.fullmatch(pr)
        if not match:
            continue
        if want_repo and f"{match.group(1)}/{match.group(2)}".lower() != want_repo:
            continue
        found.append({
            "task": task,
            "meta": meta,
            "pr": pr,
            "owner": match.group(1),
            "repo": match.group(2),
            "number": int(match.group(3)),
        })
    found.sort(key=lambda item: (item["number"], item["task"]))
    return found


def gh_pr_view(url):
    fields = "state,isDraft,mergeable,mergeStateStatus,headRefOid,headRefName,baseRefName,baseRefOid,statusCheckRollup"
    res = run(["gh", "pr", "view", url, "--json", fields])
    if res.returncode != 0:
        return None
    try:
        data = json.loads(res.stdout)
    except ValueError:
        return None
    if not isinstance(data, dict) or not SHA.fullmatch(str(data.get("headRefOid", ""))):
        return None
    return data


def gh_compare(owner, repo, base, head):
    seg = urllib.parse.quote(base, safe="")
    res = run(["gh", "api", f"repos/{owner}/{repo}/compare/{seg}...{head}?per_page=1"])
    if res.returncode != 0:
        return None
    try:
        data = json.loads(res.stdout)
    except ValueError:
        return None
    tip = (data.get("base_commit") or {}).get("sha", "")
    behind = data.get("behind_by")
    if not SHA.fullmatch(str(tip)) or not isinstance(behind, int) or behind < 0:
        return None
    return {"base_tip": tip, "behind_by": behind}


def review_verified(home, task, pr, head, base):
    res = run(
        [sys.executable, str(BIN / "fm-review-record.py"), "verify",
         "--pr", pr, "--head", head, "--task", task, "--base", base, "--json"],
        home,
    )
    try:
        out = json.loads(res.stdout)
    except ValueError:
        return False, None
    return out.get("ok") is True and out.get("basis") == "independent-review", out


def check_clean_merge_tree(worktree, base_tip, head):
    """Return (ok, detail, tree_sha) using an isolated bare scratch repo so worktree config never interferes."""
    wt = Path(worktree)
    if not wt.is_dir():
        return False, f"worktree {worktree} is missing", None
    missing = [sha for sha in (base_tip, head)
               if run(["git", "-C", str(wt), "cat-file", "-e", f"{sha}^{{commit}}"]).returncode != 0]
    if missing:
        run(["git", "-C", str(wt), "fetch", "--quiet", "origin", *missing])
    for sha in (base_tip, head):
        if run(["git", "-C", str(wt), "cat-file", "-e", f"{sha}^{{commit}}"]).returncode != 0:
            return False, f"commit {sha[:12]} unavailable in worktree", None
    objects = run(["git", "-C", str(wt), "rev-parse", "--path-format=absolute", "--git-path", "objects"])
    obj_fmt = run(["git", "-C", str(wt), "rev-parse", "--show-object-format"])
    if objects.returncode != 0 or obj_fmt.returncode != 0:
        return False, "could not locate worktree object store", None
    with tempfile.TemporaryDirectory(prefix="fm-land-mt-") as scratch:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        repo = os.path.join(scratch, "proof.git")
        env.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_GRAFT_FILE": os.devnull,
            "XDG_CONFIG_HOME": scratch,
            "HOME": scratch,
            "GIT_TERMINAL_PROMPT": "0",
        })
        made = subprocess.run(
            ["git", "init", "-q", "--bare", "--template=", f"--object-format={obj_fmt.stdout.strip()}", repo],
            capture_output=True, text=True, check=False, env=env,
        )
        if made.returncode != 0:
            return False, "could not initialize scratch merge-tree repo", None
        with open(os.path.join(repo, "objects", "info", "alternates"), "w", encoding="utf-8") as handle:
            handle.write(objects.stdout.strip() + "\n")
        env["GIT_DIR"] = repo
        merged = subprocess.run(
            ["git", "-c", f"core.attributesFile={os.devnull}", "merge-tree", "--write-tree", "--no-messages", base_tip, head],
            capture_output=True, text=True, check=False, env=env,
        )
        if merged.returncode == 1:
            return False, "conflicts with current base tip", None
        if merged.returncode != 0:
            return False, f"git merge-tree failed (exit {merged.returncode})", None
        lines = merged.stdout.splitlines()
        if len(lines) != 1 or not SHA.fullmatch(lines[0]):
            return False, "unexpected git merge-tree output", None
        return True, "clean", lines[0]


def worktree_is_clean(worktree):
    res = run(["git", "-C", worktree, "status", "--porcelain"])
    return res.returncode == 0 and res.stdout.strip() == ""


def no_mistakes_run_active(worktree):
    """True when no-mistakes axi status reports a live/active run in this worktree."""
    res = run(["no-mistakes", "axi", "status"], cwd=worktree)
    if res.returncode != 0:
        return False
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("status:"):
            val = stripped.split(":", 1)[1].strip().strip('"').lower()
            if val in ("running", "pending", "queued", "waiting", "waiting_approval", "fixing", "in_progress"):
                return True
    return False


def inflight_status(entry):
    run_dir = Path(entry["run_dir"])
    if (run_dir / "result.json").exists():
        return "done"
    try:
        with open(run_dir / "lock", "a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return "done" if (run_dir / "result.json").exists() else "crashed"
    except BlockingIOError:
        return "running"
    except OSError:
        return "crashed"


def reap_inflight(home, state_doc):
    inflight = state_doc.setdefault("inflight", {})
    backoff = state_doc.setdefault("backoff", {})
    completed = state_doc.setdefault("completed_heads", {})
    still_running = {}
    for task, entry in list(inflight.items()):
        st = inflight_status(entry)
        if st == "running":
            still_running[task] = entry
            continue
        run_dir = Path(entry["run_dir"])
        result = read_json(run_dir / "result.json", {})
        rc = result.get("rc", 1 if st == "crashed" else 0)
        detail = result.get("detail") or (f"exited {rc}" if st == "done" else "update worker exited without result")
        if rc == 0:
            append_event(home, task, entry["pr"], entry["head"], "update-completed", detail)
            backoff.pop(task, None)
            completed[task] = {"head": entry["head"], "until": int(time.time()) + RETRY_SECS}
        else:
            backoff[task] = {"until": int(time.time()) + RETRY_SECS, "head": entry["head"], "reason": detail}
            append_event(home, task, entry["pr"], entry["head"], "update-failed", detail)
            emit_wake_once(
                home, state_doc, task, entry["pr"], entry["head"], "update-failed",
                f"base update for {entry['pr']} failed: {detail[:200]} (log: {run_dir / 'output.log'})",
            )
    state_doc["inflight"] = still_running
    return still_running


def launch_update(home, item, base_name, base_tip, state_doc):
    task = item["task"]
    meta = item["meta"]
    mode = meta["mode"]
    worktree = meta.get("worktree", "")
    branch = meta.get("branch", "") or item["view"].get("headRefName", "")
    head = item["view"]["headRefOid"]
    run_id = f"{task}-{head[:10]}-{int(time.time())}"
    run_dir = home.root / "runs" / run_id
    run_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    request = {
        "task": task,
        "pr": item["pr"],
        "mode": mode,
        "worktree": worktree,
        "branch": branch,
        "head": head,
        "base_name": base_name,
        "base_tip": base_tip,
        "at": int(time.time()),
    }
    write_atomic(run_dir / "request.json", json.dumps(request, indent=1) + "\n")
    lock = open(run_dir / "lock", "a+")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "_update", str(run_dir), str(lock.fileno())],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        pass_fds=(lock.fileno(),),
        start_new_session=True,
        env=home.env(),
    )
    lock.close()
    state_doc.setdefault("inflight", {})[task] = {
        "task": task,
        "pr": item["pr"],
        "head": head,
        "base_tip": base_tip,
        "mode": mode,
        "run_dir": str(run_dir),
        "started_at": request["at"],
    }
    append_event(home, task, item["pr"], head, "update-started", f"updating onto {base_name} ({base_tip[:10]}) via {mode}")


def update_worker(run_dir_str, fd_str):
    run_dir = Path(run_dir_str)
    req = json.loads((run_dir / "request.json").read_text(encoding="utf-8"))
    worktree = req["worktree"]
    mode = req["mode"]
    base_name = req["base_name"]
    branch = req["branch"]
    log_path = run_dir / "output.log"
    rc = 1
    detail = ""
    try:
        if mode == "no-mistakes":
            duration_bin = str(BIN / "fm-duration.py")
            if os.environ.get("FM_TEST_SEAM") == "1" and os.environ.get("FM_LANDING_LOOP_DURATION_BIN"):
                duration_bin = os.environ["FM_LANDING_LOOP_DURATION_BIN"]
            cmd = [
                sys.executable,
                duration_bin,
                "run",
                "--pipeline-priority",
                "merge-train",
                f"fm-landing-update-{req['task']}",
                "--",
                "no-mistakes",
                "rerun",
            ]
            done = subprocess.run(cmd, cwd=worktree, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
            log_path.write_text((done.stdout or "") + (done.stderr or ""), encoding="utf-8")
            rc = done.returncode
            tail = ((done.stderr or "") + "\n" + (done.stdout or "")).strip().splitlines()
            detail = "no-mistakes rerun completed" if rc == 0 else (tail[-1][:200] if tail else f"no-mistakes rerun exited {rc}")
        elif mode == "direct-PR":
            steps = [
                ["git", "-C", worktree, "fetch", "origin", base_name],
                ["git", "-C", worktree, "merge", "--no-edit", f"origin/{base_name}"],
                ["git", "-C", worktree, "push", "origin", f"HEAD:{branch}"],
            ]
            logs = []
            rc = 0
            for cmd in steps:
                done = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
                logs.append(f"$ {' '.join(cmd)}\n{done.stdout}{done.stderr}\n")
                if done.returncode != 0:
                    rc = done.returncode
                    # Abort any partial merge so the worktree is never left conflicted.
                    subprocess.run(["git", "-C", worktree, "merge", "--abort"], capture_output=True, check=False)
                    detail = f"{cmd[2]} failed (exit {rc}): {(done.stderr or done.stdout).strip()[:160]}"
                    break
            log_path.write_text("".join(logs), encoding="utf-8")
            if rc == 0:
                detail = f"merged origin/{base_name} and pushed {branch}"
        else:
            detail = f"unsupported delivery mode: {mode}"
            rc = 2
    except Exception as exc:
        detail = f"{type(exc).__name__}: {exc}"
        rc = 1
    write_atomic(run_dir / "result.json", json.dumps({"rc": rc, "detail": detail, "at": int(time.time())}) + "\n")
    try:
        os.close(int(fd_str))
    except OSError:
        pass


def assess_candidates(home, include_stale_red=False, inflight=None, backoff=None, completed_heads=None, repo_filter=None):
    inflight = inflight or {}
    backoff = backoff or {}
    completed_heads = completed_heads or {}
    auto_review = load_auto_review()
    rows = []
    now = time.time()
    for item in ship_tasks(home, repo_filter=repo_filter):
        task = item["task"]
        pr = item["pr"]
        meta = item["meta"]
        entry = {
            "task": task,
            "pr": pr,
            "number": item["number"],
            "mode": meta["mode"],
            "action": "skip",
            "reason": "",
            "behind_by": None,
            "head": None,
            "base_name": None,
            "base_tip": None,
            "view": None,
            "meta": meta,
        }
        if task in inflight:
            entry["action"] = "inflight"
            entry["head"] = inflight[task]["head"]
            entry["reason"] = "base update already running"
            rows.append(entry)
            continue
        view = gh_pr_view(pr)
        if not view:
            entry["action"] = "unreadable"
            entry["reason"] = "could not read PR from forge"
            rows.append(entry)
            continue
        entry["view"] = view
        head = view["headRefOid"]
        base_name = view.get("baseRefName") or "main"
        entry["head"] = head
        entry["base_name"] = base_name
        if str(view.get("state", "")).upper() != "OPEN":
            entry["action"] = "closed"
            entry["reason"] = f"PR state is {view.get('state')}"
            rows.append(entry)
            continue
        if view.get("isDraft") is not False:
            entry["action"] = "draft"
            entry["reason"] = "PR is a draft"
            rows.append(entry)
            continue
        if view.get("mergeable") == "CONFLICTING" or view.get("mergeStateStatus") == "DIRTY":
            entry["action"] = "conflict"
            entry["reason"] = "PR has merge conflicts with base"
            rows.append(entry)
            continue
        cmp = gh_compare(item["owner"], item["repo"], base_name, head)
        if not cmp:
            entry["action"] = "unreadable"
            entry["reason"] = "could not compare PR head against base"
            rows.append(entry)
            continue
        entry["behind_by"] = cmp["behind_by"]
        entry["base_tip"] = cmp["base_tip"]
        if cmp["behind_by"] == 0:
            entry["action"] = "at-tip"
            entry["reason"] = "already contains base tip; handled by auto-review/merge lane"
            rows.append(entry)
            continue
        bo = backoff.get(task)
        if bo and bo.get("head") == head and now < bo.get("until", 0):
            entry["action"] = "backoff"
            entry["reason"] = f"waiting after failed update: {bo.get('reason', '')}"
            rows.append(entry)
            continue
        done_head = completed_heads.get(task)
        if done_head and done_head.get("head") == head and now < done_head.get("until", 0):
            entry["action"] = "updated"
            entry["reason"] = "update already ran for this head; waiting for forge head to advance"
            rows.append(entry)
            continue
        rollup = view.get("statusCheckRollup")
        problems = auto_review.checks_not_green(rollup) if isinstance(rollup, list) else None
        if problems is None:
            entry["action"] = "waiting"
            entry["reason"] = "check rollup unreadable"
            rows.append(entry)
            continue
        pending = [name for st, name in problems if st == "pending"]
        if pending:
            entry["action"] = "waiting-ci"
            entry["reason"] = f"checks still running: {', '.join(pending[:3])}"
            rows.append(entry)
            continue
        has_pass, _ = review_verified(home, task, pr, head, view.get("baseRefOid") or cmp["base_tip"])
        failed = [name for st, name in problems if st != "pending"]
        if failed and not (has_pass or include_stale_red):
            entry["action"] = "red-checks"
            entry["reason"] = f"red checks without PASS: {', '.join(failed[:3])}"
            rows.append(entry)
            continue
        worktree = meta.get("worktree", "")
        if not worktree or not os.path.isdir(worktree):
            entry["action"] = "held"
            entry["reason"] = f"worktree missing: {worktree or '(unset)'}"
            rows.append(entry)
            continue
        if not worktree_is_clean(worktree):
            entry["action"] = "held"
            entry["reason"] = "worktree has uncommitted changes"
            rows.append(entry)
            continue
        if meta["mode"] == "no-mistakes" and no_mistakes_run_active(worktree):
            entry["action"] = "busy"
            entry["reason"] = "no-mistakes run already active in worktree"
            rows.append(entry)
            continue
        clean, detail, _ = check_clean_merge_tree(worktree, cmp["base_tip"], head)
        if not clean:
            entry["action"] = "conflict" if "conflict" in detail else "held"
            entry["reason"] = detail
            rows.append(entry)
            continue
        entry["action"] = "update"
        entry["reason"] = f"behind {base_name} by {cmp['behind_by']} ({'PASS verified' if has_pass else 'checks green' if not failed else 'stale-red opt-in'})"
        rows.append(entry)
    return rows


def run_step(home, no_reconcile=False, include_stale_red=False, repo_filter=None):
    home.root.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_file = open(home.root / "lock", "a+")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_file.close()
        return 0
    try:
        state_path = home.root / "state.json"
        state_doc = read_json(state_path, {"v": 1, "inflight": {}, "backoff": {}, "emitted_wakes": {}, "tasks": {}})
        # Phase 1: run reconcile + auto-review/merge independently of Main's watcher.
        if not no_reconcile:
            rec = run([str(BIN / "fm-pr-ready-reconcile.sh")], home)
            state_doc["last_reconcile"] = {"at": int(time.time()), "rc": rec.returncode}
        # Phase 2: collect finished detached base-update workers.
        inflight = reap_inflight(home, state_doc)
        # Phase 3: assess stale-base PRs and admit up to MAX_INFLIGHT serial updates.
        rows = assess_candidates(home, include_stale_red=include_stale_red, inflight=inflight,
                                 backoff=state_doc.get("backoff"), completed_heads=state_doc.get("completed_heads"),
                                 repo_filter=repo_filter)
        admitted = len(inflight)
        summary = {}
        for row in rows:
            task = row["task"]
            summary[task] = {
                "pr": row["pr"],
                "head": row["head"],
                "behind_by": row["behind_by"],
                "action": row["action"],
                "reason": row["reason"],
                "at": int(time.time()),
            }
            if row["action"] == "conflict":
                emit_wake_once(home, state_doc, task, row["pr"], row["head"], "conflict",
                               f"{row['pr']} has merge conflicts against {row['base_name']}; needs conflict resolution")
            elif row["action"] == "update" and admitted < MAX_INFLIGHT:
                launch_update(home, row, row["base_name"], row["base_tip"], state_doc)
                summary[task]["action"] = "inflight"
                summary[task]["reason"] = f"launched {row['mode']} base update"
                admitted += 1
        state_doc["tasks"] = summary
        state_doc["last_step_at"] = int(time.time())
        write_atomic(state_path, json.dumps(state_doc, sort_keys=True, indent=1) + "\n")
        return 0
    finally:
        lock_file.close()


def cmd_plan(home, include_stale_red=False, as_json=False, repo_filter=None):
    state_doc = read_json(home.root / "state.json", {"inflight": {}, "backoff": {}})
    rows = assess_candidates(home, include_stale_red=include_stale_red,
                             inflight=state_doc.get("inflight"), backoff=state_doc.get("backoff"),
                             completed_heads=state_doc.get("completed_heads"), repo_filter=repo_filter)
    out = [{k: v for k, v in r.items() if k not in ("view", "meta")} for r in rows]
    if as_json:
        print(json.dumps({"tasks": out, "max_inflight": MAX_INFLIGHT}, indent=1))
        return 0
    if not out:
        print("landing-loop: no registered GitHub ship PRs")
        return 0
    for r in out:
        behind = "-" if r["behind_by"] is None else str(r["behind_by"])
        print(f"#{r['number']:4d} {r['action']:10s} behind={behind:3s} {r['task']} ({r['reason']})")
    return 0


def cmd_status(home, as_json=False):
    state_doc = read_json(home.root / "state.json", {})
    if as_json:
        print(json.dumps(state_doc, indent=1))
        return 0
    if not state_doc:
        print("landing-loop: idle (no passes recorded)")
        return 0
    print(f"last_step_at={state_doc.get('last_step_at', 0)} inflight={len(state_doc.get('inflight') or {})}")
    for task, info in sorted((state_doc.get("tasks") or {}).items()):
        print(f"  {task}: {info.get('action')} behind={info.get('behind_by')} {info.get('pr')} ({info.get('reason')})")
    return 0


def cmd_events(home, limit=50):
    path = home.root / "events.jsonl"
    if not path.is_file():
        return 0
    lines = path.read_text(encoding="utf-8").splitlines()[-limit:]
    for line in lines:
        try:
            row = json.loads(line)
            print(f"{row['at']} {row['task']} {row['head']} {row['kind']}: {row['detail']}")
        except (ValueError, KeyError):
            print(line)
    return 0


def main(argv):
    if len(argv) == 4 and argv[1] == "_update":
        update_worker(argv[2], argv[3])
        return 0
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_step = sub.add_parser("step")
    p_step.add_argument("--no-reconcile", action="store_true")
    p_step.add_argument("--include-stale-red", action="store_true")
    p_step.add_argument("--repo", default=None)
    p_plan = sub.add_parser("plan")
    p_plan.add_argument("--include-stale-red", action="store_true")
    p_plan.add_argument("--json", action="store_true")
    p_plan.add_argument("--repo", default=None)
    p_status = sub.add_parser("status")
    p_status.add_argument("--json", action="store_true")
    p_events = sub.add_parser("events")
    p_events.add_argument("--limit", type=int, default=50)
    p_run = sub.add_parser("run")
    p_run.add_argument("--interval", type=int, default=DEFAULT_INTERVAL)
    p_run.add_argument("--include-stale-red", action="store_true")
    p_run.add_argument("--repo", default=None)
    args = parser.parse_args(argv[1:])
    home = Home()
    if args.cmd == "step":
        return run_step(home, no_reconcile=args.no_reconcile, include_stale_red=args.include_stale_red, repo_filter=args.repo)
    if args.cmd == "plan":
        return cmd_plan(home, include_stale_red=args.include_stale_red, as_json=args.json, repo_filter=args.repo)
    if args.cmd == "status":
        return cmd_status(home, as_json=args.json)
    if args.cmd == "events":
        return cmd_events(home, limit=args.limit)
    if args.cmd == "run":
        interval = max(15, args.interval)
        while True:
            run_step(home, include_stale_red=args.include_stale_red, repo_filter=args.repo)
            time.sleep(interval)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
