#!/usr/bin/env python3
"""Standalone PR landing loop: reconcile, update stale bases serially, and let carried PASSes merge.

Usage (FM_HOME names the absolute home; FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE select state/config):
  fm-landing-loop.py step [--no-reconcile] [--include-stale-red]   one bounded pass (launchd entrypoint)
  fm-landing-loop.py plan [--include-stale-red] [--json]           read-only plan of candidates and trains
  fm-landing-loop.py train [--repo O/R] [--prs N,M] [--max K] [--build --worktree DIR --branch B]
                                                                   plan or build a non-conflicting Train-member batch branch
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
GH_TIMEOUT = int(os.environ.get("FM_LANDING_LOOP_GH_TIMEOUT", "60") or 60)
GIT_TIMEOUT = int(os.environ.get("FM_LANDING_LOOP_GIT_TIMEOUT", "120") or 120)
RECONCILE_TIMEOUT = int(os.environ.get("FM_LANDING_LOOP_RECONCILE_TIMEOUT", "300") or 300)
DEFAULT_CMD_TIMEOUT = int(os.environ.get("FM_LANDING_LOOP_CMD_TIMEOUT", "120") or 120)
UPDATE_TIMEOUT = int(os.environ.get("FM_LANDING_LOOP_UPDATE_TIMEOUT", "7200") or 7200)

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


def run(command, home=None, cwd=None, timeout=DEFAULT_CMD_TIMEOUT):
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


def emit_wake_once(home, state_doc, task, pr, head, key, text, state_path=None):
    emitted = state_doc.setdefault("emitted_wakes", {})
    dedup = f"{task}:{head or ''}"
    if dedup in emitted:
        return False
    # Persist the dedup marker BEFORE appending to the wake queue so a crash
    # after append cannot emit a duplicate wake on restart.
    emitted[dedup] = int(time.time())
    if state_path is not None:
        write_atomic(state_path, json.dumps(state_doc, sort_keys=True, indent=1) + "\n")
    script = '. "$1/fm-wake-lib.sh" && fm_wake_append check "$2" "$3"'
    sent = run(
        ["bash", "-c", script, "fm-landing-loop", str(BIN), f"landing-loop:{dedup}",
         f"check: landing-loop {task}: {text}"],
        home,
        timeout=30,
    )
    if sent.returncode == 0:
        append_event(home, task, pr, head, f"wake:{key}", text)
        return True
    emitted.pop(dedup, None)
    if state_path is not None:
        write_atomic(state_path, json.dumps(state_doc, sort_keys=True, indent=1) + "\n")
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
    res = run(["gh", "pr", "view", url, "--json", fields], timeout=GH_TIMEOUT)
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
    res = run(["gh", "api", f"repos/{owner}/{repo}/compare/{seg}...{head}?per_page=1"], timeout=GH_TIMEOUT)
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
    try:
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
                capture_output=True, text=True, check=False, env=env, timeout=GIT_TIMEOUT,
            )
            if made.returncode != 0:
                return False, "could not initialize scratch merge-tree repo", None
            with open(os.path.join(repo, "objects", "info", "alternates"), "w", encoding="utf-8") as handle:
                handle.write(objects.stdout.strip() + "\n")
            env["GIT_DIR"] = repo
            merged = subprocess.run(
                ["git", "-c", f"core.attributesFile={os.devnull}", "merge-tree", "--write-tree", "--no-messages", base_tip, head],
                capture_output=True, text=True, check=False, env=env, timeout=GIT_TIMEOUT,
            )
            if merged.returncode == 1:
                return False, "conflicts with current base tip", None
            if merged.returncode != 0:
                return False, f"git merge-tree failed (exit {merged.returncode})", None
            lines = merged.stdout.splitlines()
            if len(lines) != 1 or not SHA.fullmatch(lines[0]):
                return False, "unexpected git merge-tree output", None
            return True, "clean", lines[0]
    except subprocess.TimeoutExpired:
        return False, "git merge-tree timed out", None


def worktree_is_clean(worktree):
    res = run(["git", "-C", worktree, "status", "--porcelain"])
    return res.returncode == 0 and res.stdout.strip() == ""


def no_mistakes_run_state(worktree):
    """Return (busy_or_unreadable, reason). Fails closed on timeout or non-zero exit."""
    res = run(["no-mistakes", "axi", "status"], cwd=worktree, timeout=GH_TIMEOUT)
    if res.returncode != 0:
        return True, f"no-mistakes axi status unreadable or timed out (exit {res.returncode})"
    seen_status = None
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("status:"):
            seen_status = stripped.split(":", 1)[1].strip().strip('"').lower()
            break
    if seen_status is None or seen_status in ("", "none", "idle", "completed", "passed", "failed", "aborted", "cancelled", "canceled"):
        return False, "idle"
    return True, f"no-mistakes run already active in worktree (status: {seen_status})"


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


def reap_inflight(home, state_doc, state_path=None):
    inflight = state_doc.setdefault("inflight", {})
    backoff = state_doc.setdefault("backoff", {})
    completed = state_doc.setdefault("completed_heads", {})
    still_running = {}
    tracked_dirs = set()
    for task, entry in list(inflight.items()):
        tracked_dirs.add(str(Path(entry["run_dir"]).resolve()))
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
            completed[task] = {"head": entry["head"], "at": int(time.time())}
        else:
            backoff[task] = {"until": int(time.time()) + RETRY_SECS, "head": entry["head"], "reason": detail}
            append_event(home, task, entry["pr"], entry["head"], "update-failed", detail)
            emit_wake_once(
                home, state_doc, task, entry["pr"], entry["head"], "update-failed",
                f"base update for {entry['pr']} failed: {detail[:200]} (log: {run_dir / 'output.log'})",
                state_path=state_path,
            )
    # Also detect any live detached updater whose state.json write was interrupted
    # before persisting, so serial admission (MAX_INFLIGHT) holds even across SIGKILL.
    runs_dir = home.root / "runs"
    if runs_dir.is_dir():
        for run_dir in sorted(runs_dir.iterdir()):
            if not run_dir.is_dir():
                continue
            resolved = str(run_dir.resolve())
            if resolved in tracked_dirs or (run_dir / "result.json").exists():
                continue
            if inflight_status({"run_dir": str(run_dir)}) == "running":
                req = read_json(run_dir / "request.json", {})
                task = str(req.get("task") or run_dir.name)
                if task not in still_running:
                    still_running[task] = {
                        "task": task,
                        "pr": str(req.get("pr") or ""),
                        "head": str(req.get("head") or ""),
                        "base_tip": str(req.get("base_tip") or ""),
                        "mode": str(req.get("mode") or ""),
                        "run_dir": str(run_dir),
                        "started_at": int(req.get("at") or time.time()),
                    }
    state_doc["inflight"] = still_running
    return still_running


def launch_update(home, item, base_name, base_tip, expected_tree, state_doc, state_path):
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
        "expected_tree": expected_tree,
        "at": int(time.time()),
    }
    req_text = json.dumps(request, indent=1) + "\n"
    write_atomic(run_dir / "request.json", req_text)
    lock = open(run_dir / "lock", "a+")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    # Persist admission BEFORE spawning so an interruption right after Popen cannot
    # break serial admission on the next pass.
    inflight_entry = {
        "task": task,
        "pr": item["pr"],
        "head": head,
        "base_tip": base_tip,
        "mode": mode,
        "run_dir": str(run_dir),
        "started_at": request["at"],
    }
    state_doc.setdefault("inflight", {})[task] = inflight_entry
    write_atomic(state_path, json.dumps(state_doc, sort_keys=True, indent=1) + "\n")
    req_r, req_w = os.pipe()
    try:
        os.write(req_w, req_text.encode("utf-8"))
        os.close(req_w)
        req_w = -1
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "_update", str(run_dir), str(lock.fileno()), str(req_r)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            pass_fds=(lock.fileno(), req_r),
            start_new_session=True,
            env=home.env(),
        )
    except Exception:
        state_doc.get("inflight", {}).pop(task, None)
        write_atomic(state_path, json.dumps(state_doc, sort_keys=True, indent=1) + "\n")
        raise
    finally:
        if req_w >= 0:
            os.close(req_w)
        os.close(req_r)
        lock.close()
    append_event(home, task, item["pr"], head, "update-started", f"updating onto {base_name} ({base_tip[:10]}) via {mode}")


def update_worker(run_dir_str, fd_str, req_fd_str):
    run_dir = Path(run_dir_str)
    with os.fdopen(int(req_fd_str), "r", encoding="utf-8") as req_stream:
        req = json.load(req_stream)
    worktree = req["worktree"]
    mode = req["mode"]
    base_name = req["base_name"]
    base_tip = req["base_tip"]
    expected_head = req["head"]
    expected_tree = req.get("expected_tree") or ""
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
            proc = subprocess.Popen(
                cmd,
                cwd=worktree,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            try:
                stdout, stderr = proc.communicate(timeout=UPDATE_TIMEOUT)
                rc = proc.returncode
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, 9)
                except OSError:
                    proc.kill()
                stdout, stderr = proc.communicate()
                rc = 124
            log_path.write_text((stdout or "") + (stderr or ""), encoding="utf-8")
            tail = [
                line.strip()
                for line in ((stderr or "") + "\n" + (stdout or "")).splitlines()
                if line.strip() and not line.strip().startswith(("progress:", "calibration:", "fallback:", "fm-cpu-pass:"))
            ]
            if rc == 124:
                detail = f"no-mistakes rerun timed out after {UPDATE_TIMEOUT}s"
            else:
                detail = "no-mistakes rerun completed" if rc == 0 else (tail[-1][:200] if tail else f"no-mistakes rerun exited {rc}")
        elif mode == "direct-PR":
            # Build the exact merge commit in an isolated bare scratch repo so the
            # task worktree is never mutated or hard-reset, and push that exact
            # immutable commit SHA rather than a mutable HEAD.
            logs = []
            local_head = run(["git", "-C", worktree, "rev-parse", "HEAD"], timeout=GIT_TIMEOUT)
            if local_head.returncode != 0 or local_head.stdout.strip() != expected_head:
                rc = 1
                detail = f"direct-PR update stopped: local HEAD {(local_head.stdout.strip() or '(unreadable)')[:12]} differs from proved forge head {expected_head[:12]}"
            elif not worktree_is_clean(worktree):
                rc = 1
                detail = "direct-PR update stopped: worktree has uncommitted changes"
            else:
                if run(["git", "-C", worktree, "cat-file", "-e", f"{base_tip}^{{commit}}"], timeout=GIT_TIMEOUT).returncode != 0:
                    ft = run(["git", "-C", worktree, "fetch", "origin", base_tip], timeout=GIT_TIMEOUT)
                    logs.append(f"$ git -C {worktree} fetch origin {base_tip}\n{ft.stdout}{ft.stderr}\n")
                    if run(["git", "-C", worktree, "cat-file", "-e", f"{base_tip}^{{commit}}"], timeout=GIT_TIMEOUT).returncode != 0:
                        ft2 = run(["git", "-C", worktree, "fetch", "origin", base_name], timeout=GIT_TIMEOUT)
                        logs.append(f"$ git -C {worktree} fetch origin {base_name}\n{ft2.stdout}{ft2.stderr}\n")
                if run(["git", "-C", worktree, "cat-file", "-e", f"{base_tip}^{{commit}}"], timeout=GIT_TIMEOUT).returncode != 0:
                    rc = 1
                    detail = f"proved base commit {base_tip[:12]} unavailable after fetch"
                else:
                    objects = run(["git", "-C", worktree, "rev-parse", "--path-format=absolute", "--git-path", "objects"], timeout=GIT_TIMEOUT)
                    obj_fmt = run(["git", "-C", worktree, "rev-parse", "--show-object-format"], timeout=GIT_TIMEOUT)
                    author_name = run(["git", "-C", worktree, "config", "user.name"], timeout=GIT_TIMEOUT).stdout.strip() or "Firstmate Landing Loop"
                    author_email = run(["git", "-C", worktree, "config", "user.email"], timeout=GIT_TIMEOUT).stdout.strip() or "landing-loop@local.invalid"
                    if objects.returncode != 0 or obj_fmt.returncode != 0:
                        rc = 1
                        detail = "could not locate worktree object store for direct-PR merge"
                    else:
                        with tempfile.TemporaryDirectory(prefix="fm-direct-merge-") as scratch:
                            env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
                            repo = os.path.join(scratch, "merge.git")
                            env.update({
                                "GIT_CONFIG_NOSYSTEM": "1",
                                "GIT_CONFIG_GLOBAL": os.devnull,
                                "GIT_ATTR_NOSYSTEM": "1",
                                "GIT_NO_REPLACE_OBJECTS": "1",
                                "GIT_GRAFT_FILE": os.devnull,
                                "XDG_CONFIG_HOME": scratch,
                                "HOME": scratch,
                                "GIT_TERMINAL_PROMPT": "0",
                                "GIT_AUTHOR_NAME": author_name,
                                "GIT_AUTHOR_EMAIL": author_email,
                                "GIT_COMMITTER_NAME": author_name,
                                "GIT_COMMITTER_EMAIL": author_email,
                            })
                            made = subprocess.run(
                                ["git", "init", "-q", "--bare", "--template=", f"--object-format={obj_fmt.stdout.strip()}", repo],
                                capture_output=True, text=True, check=False, env=env, timeout=GIT_TIMEOUT,
                            )
                            if made.returncode != 0:
                                rc = 1
                                detail = "could not initialize scratch merge repo"
                            else:
                                with open(os.path.join(repo, "objects", "info", "alternates"), "w", encoding="utf-8") as handle:
                                    handle.write(objects.stdout.strip() + "\n")
                                env["GIT_DIR"] = repo
                                mt = subprocess.run(
                                    ["git", "-c", f"core.attributesFile={os.devnull}", "merge-tree", "--write-tree", "--no-messages", expected_head, base_tip],
                                    capture_output=True, text=True, check=False, env=env, timeout=GIT_TIMEOUT,
                                )
                                tree_lines = mt.stdout.splitlines()
                                merged_tree = tree_lines[0] if mt.returncode == 0 and len(tree_lines) == 1 and SHA.fullmatch(tree_lines[0]) else ""
                                if not merged_tree:
                                    rc = 1
                                    detail = f"scratch merge-tree failed (exit {mt.returncode})"
                                elif expected_tree and merged_tree != expected_tree:
                                    rc = 1
                                    detail = f"merged tree {merged_tree[:12]} diverged from proved tree {expected_tree[:12]}"
                                else:
                                    ct = subprocess.run(
                                        ["git", "commit-tree", merged_tree, "-p", expected_head, "-p", base_tip,
                                         "-m", f"Merge {base_name} ({base_tip[:10]}) into {branch}"],
                                        capture_output=True, text=True, check=False, env=env, timeout=GIT_TIMEOUT,
                                    )
                                    merged_sha = ct.stdout.strip()
                                    if ct.returncode != 0 or not SHA.fullmatch(merged_sha):
                                        rc = 1
                                        detail = "commit-tree failed in scratch merge repo"
                                    else:
                                        # Expose the immutable merge commit via a scratch ref so any Git version
                                        # can fetch it into the worktree object store without touching HEAD, index,
                                        # or working tree, then push that exact commit SHA.
                                        ur = subprocess.run(
                                            ["git", "update-ref", "refs/heads/fm-landing-merge", merged_sha],
                                            capture_output=True, text=True, check=False, env=env, timeout=GIT_TIMEOUT,
                                        )
                                        if ur.returncode != 0:
                                            rc = ur.returncode
                                            detail = f"failed to stage scratch ref for {merged_sha[:12]}"
                                        else:
                                            imp = run(["git", "-C", worktree, "fetch", "--no-tags", repo, "refs/heads/fm-landing-merge"], timeout=GIT_TIMEOUT)
                                            logs.append(f"$ git -C {worktree} fetch --no-tags {repo} refs/heads/fm-landing-merge\n{imp.stdout}{imp.stderr}\n")
                                            if imp.returncode != 0:
                                                rc = imp.returncode
                                                detail = f"failed to import scratch merge commit {merged_sha[:12]}"
                                            else:
                                                ps = run(["git", "-C", worktree, "push", "origin", f"{merged_sha}:refs/heads/{branch}"], timeout=GIT_TIMEOUT)
                                                logs.append(f"$ git -C {worktree} push origin {merged_sha}:refs/heads/{branch}\n{ps.stdout}{ps.stderr}\n")
                                                rc = ps.returncode
                                                if rc == 0:
                                                    detail = f"merged {base_name} ({base_tip[:10]}) into {merged_sha[:10]} and pushed {branch}"
                                                else:
                                                    detail = f"push failed (exit {rc}): {(ps.stderr or ps.stdout).strip()[:160]}"
            log_path.write_text("".join(logs), encoding="utf-8")
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
        if done_head and done_head.get("head") == head:
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
        if meta["mode"] == "direct-PR":
            lh = run(["git", "-C", worktree, "rev-parse", "HEAD"], timeout=GIT_TIMEOUT)
            local_head = lh.stdout.strip() if lh.returncode == 0 else ""
            if local_head != head:
                entry["action"] = "held"
                entry["reason"] = f"local HEAD {(local_head or '(unreadable)')[:12]} differs from forge head {head[:12]}; reconcile custody"
                rows.append(entry)
                continue
        if meta["mode"] == "no-mistakes":
            nm_busy, nm_reason = no_mistakes_run_state(worktree)
            if nm_busy:
                entry["action"] = "busy"
                entry["reason"] = nm_reason
                rows.append(entry)
                continue
        clean, detail, expected_tree = check_clean_merge_tree(worktree, cmp["base_tip"], head)
        if not clean:
            entry["action"] = "conflict" if "conflict" in detail else "held"
            entry["reason"] = detail
            rows.append(entry)
            continue
        entry["expected_tree"] = expected_tree
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
            rec = run([str(BIN / "fm-pr-ready-reconcile.sh")], home, timeout=RECONCILE_TIMEOUT)
            state_doc["last_reconcile"] = {"at": int(time.time()), "rc": rec.returncode}
        # Phase 2: collect finished detached base-update workers.
        inflight = reap_inflight(home, state_doc, state_path=state_path)
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
                               f"{row['pr']} has merge conflicts against {row['base_name']}; needs conflict resolution",
                               state_path=state_path)
            elif row["action"] == "held":
                emit_wake_once(home, state_doc, task, row["pr"], row["head"], "held",
                               f"{row['pr']} held: {row['reason']}",
                               state_path=state_path)
            elif row["action"] == "update" and admitted < MAX_INFLIGHT:
                launch_update(home, row, row["base_name"], row["base_tip"], row.get("expected_tree") or "", state_doc, state_path)
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


def plan_train_batch(worktree, base_tip, candidates, max_members=5):
    """Greedily select up to max_members PRs that merge cleanly onto base_tip cumulatively.

    Uses an isolated bare scratch repository borrowing objects from worktree so no worktree
    config, hooks, or files are touched while proving conflict-free composition.
    Returns (selected, excluded, final_tree).
    """
    wt = Path(worktree)
    if not wt.is_dir():
        return [], [{"pr": c["pr"], "reason": f"worktree {worktree} missing"} for c in candidates], None
    objects = run(["git", "-C", str(wt), "rev-parse", "--path-format=absolute", "--git-path", "objects"])
    obj_fmt = run(["git", "-C", str(wt), "rev-parse", "--show-object-format"])
    if objects.returncode != 0 or obj_fmt.returncode != 0:
        return [], [{"pr": c["pr"], "reason": "could not locate git object store"} for c in candidates], None
    missing = [sha for sha in [base_tip, *(c["head"] for c in candidates)]
               if run(["git", "-C", str(wt), "cat-file", "-e", f"{sha}^{{commit}}"]).returncode != 0]
    if missing:
        run(["git", "-C", str(wt), "fetch", "--quiet", "origin", *missing])
    selected, excluded = [], []
    final_tree = None
    with tempfile.TemporaryDirectory(prefix="fm-train-plan-") as scratch:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        repo = os.path.join(scratch, "train.git")
        env.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_NO_GRAFT_FILE": "1",
            "GIT_GRAFT_FILE": os.devnull,
            "XDG_CONFIG_HOME": scratch,
            "HOME": scratch,
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Firstmate Train",
            "GIT_AUTHOR_EMAIL": "train@local.invalid",
            "GIT_COMMITTER_NAME": "Firstmate Train",
            "GIT_COMMITTER_EMAIL": "train@local.invalid",
        })
        made = subprocess.run(
            ["git", "init", "-q", "--bare", "--template=", f"--object-format={obj_fmt.stdout.strip()}", repo],
            capture_output=True, text=True, check=False, env=env, timeout=GIT_TIMEOUT,
        )
        if made.returncode != 0:
            return [], [{"pr": c["pr"], "reason": "could not initialize scratch train repo"} for c in candidates], None
        with open(os.path.join(repo, "objects", "info", "alternates"), "w", encoding="utf-8") as handle:
            handle.write(objects.stdout.strip() + "\n")
        env["GIT_DIR"] = repo
        cur_commit = base_tip
        for cand in candidates:
            if len(selected) >= max_members:
                excluded.append({"pr": cand["pr"], "head": cand["head"], "reason": f"batch cap ({max_members}) reached"})
                continue
            head = cand["head"]
            if subprocess.run(["git", "cat-file", "-e", f"{head}^{{commit}}"], capture_output=True, env=env, timeout=GIT_TIMEOUT).returncode != 0:
                excluded.append({"pr": cand["pr"], "head": head, "reason": "commit unavailable in object store"})
                continue
            merged = subprocess.run(
                ["git", "-c", f"core.attributesFile={os.devnull}", "merge-tree", "--write-tree", "--no-messages", cur_commit, head],
                capture_output=True, text=True, check=False, env=env, timeout=GIT_TIMEOUT,
            )
            if merged.returncode == 1:
                excluded.append({"pr": cand["pr"], "head": head, "reason": "conflicts with train batch"})
                continue
            if merged.returncode != 0:
                excluded.append({"pr": cand["pr"], "head": head, "reason": f"merge-tree failed (exit {merged.returncode})"})
                continue
            tree_lines = merged.stdout.splitlines()
            if len(tree_lines) != 1 or not SHA.fullmatch(tree_lines[0]):
                excluded.append({"pr": cand["pr"], "head": head, "reason": "unexpected merge-tree output"})
                continue
            tree = tree_lines[0]
            ct = subprocess.run(
                ["git", "commit-tree", tree, "-p", cur_commit, "-p", head, "-m", f"train member {cand['pr']}"],
                capture_output=True, text=True, check=False, env=env, timeout=GIT_TIMEOUT,
            )
            if ct.returncode != 0 or not SHA.fullmatch(ct.stdout.strip()):
                excluded.append({"pr": cand["pr"], "head": head, "reason": "commit-tree failed in scratch repo"})
                continue
            cur_commit = ct.stdout.strip()
            final_tree = tree
            selected.append(cand)
    return selected, excluded, final_tree


def format_train_closes_block(members):
    lines = ["<!-- firstmate-backlog-closes:begin -->"]
    for member in members:
        lines.append(f"Train-member: {member['pr']}")
    lines.append("<!-- firstmate-backlog-closes:end -->")
    return "\n".join(lines) + "\n"


def cmd_train(home, repo_filter=None, prs_csv=None, max_members=5, include_stale_red=False,
              worktree=None, branch=None, base_name="main", build=False, as_json=False):
    wt = worktree or str(home.home)
    candidates = []
    excluded_pre = []
    if prs_csv:
        if not repo_filter or "/" not in repo_filter:
            print("error: --prs requires --repo <owner/repo>", file=sys.stderr)
            return 2
        for tok in [t.strip() for t in prs_csv.split(",") if t.strip()]:
            if not re.fullmatch(r"[1-9][0-9]*", tok):
                print(f"error: invalid PR number: {tok}", file=sys.stderr)
                return 2
            url = f"https://github.com/{repo_filter}/pull/{tok}"
            view = gh_pr_view(url)
            if not view or str(view.get("state", "")).upper() != "OPEN" or view.get("isDraft") is not False:
                continue
            cand_base = view.get("baseRefName") or ""
            if cand_base != base_name:
                excluded_pre.append({"pr": url, "head": view["headRefOid"], "reason": f"targets base {cand_base or '(unknown)'}, not {base_name}"})
                continue
            candidates.append({
                "task": f"pr-{tok}",
                "pr": url,
                "number": int(tok),
                "head": view["headRefOid"],
                "base_name": cand_base,
            })
        owner, repo = repo_filter.split("/", 1)
    else:
        state_doc = read_json(home.root / "state.json", {"inflight": {}, "backoff": {}})
        rows = assess_candidates(home, include_stale_red=include_stale_red,
                                 inflight=state_doc.get("inflight"), backoff=state_doc.get("backoff"),
                                 completed_heads=state_doc.get("completed_heads"), repo_filter=repo_filter)
        for r in rows:
            if r["action"] in ("update", "at-tip"):
                cand_base = r["base_name"] or ""
                if cand_base != base_name:
                    excluded_pre.append({"pr": r["pr"], "head": r["head"], "reason": f"targets base {cand_base or '(unknown)'}, not {base_name}"})
                    continue
                candidates.append({
                    "task": r["task"],
                    "pr": r["pr"],
                    "number": r["number"],
                    "head": r["head"],
                    "base_name": cand_base,
                })
        if not candidates:
            out = {"ok": True, "selected": [], "excluded": excluded_pre, "closes_block": ""}
            print(json.dumps(out, indent=1) if as_json else "landing-loop train: no eligible PRs")
            return 0
        match = PR_URL.fullmatch(candidates[0]["pr"])
        owner, repo = match.group(1), match.group(2)
    if not candidates:
        out = {"ok": True, "selected": [], "excluded": excluded_pre, "closes_block": ""}
        print(json.dumps(out, indent=1) if as_json else "landing-loop train: no eligible PRs")
        return 0
    cmp = gh_compare(owner, repo, base_name, candidates[0]["head"])
    if not cmp:
        print(f"error: could not resolve live tip of {owner}/{repo} {base_name}", file=sys.stderr)
        return 1
    base_tip = cmp["base_tip"]
    selected, excluded_plan, final_tree = plan_train_batch(wt, base_tip, candidates, max_members=max_members)
    excluded = excluded_pre + excluded_plan
    closes_block = format_train_closes_block(selected) if selected else ""
    built_head = None
    intent_path = None
    if build:
        if not selected:
            print("error: no conflict-free PRs selected for train", file=sys.stderr)
            return 1
        if not worktree or not branch:
            print("error: --build requires --worktree DIR and --branch NAME", file=sys.stderr)
            return 2
        if not worktree_is_clean(worktree):
            print(f"error: train worktree {worktree} is not clean", file=sys.stderr)
            return 1
        if run(["git", "-C", worktree, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"], timeout=GIT_TIMEOUT).returncode == 0:
            print(f"error: branch {branch} already exists; pick a new branch name to preserve existing commits", file=sys.stderr)
            return 1
        run(["git", "-C", worktree, "fetch", "--quiet", "origin", base_name, *(m["head"] for m in selected)], timeout=GIT_TIMEOUT)
        co = run(["git", "-C", worktree, "checkout", "-b", branch, base_tip], timeout=GIT_TIMEOUT)
        if co.returncode != 0:
            print(f"error: could not checkout {branch} at {base_tip}: {co.stderr.strip()}", file=sys.stderr)
            return 1
        for member in selected:
            mg = run(
                ["git", "-C", worktree, "-c", "merge.ff=false", "merge", "--no-ff", "--no-edit",
                 "-m", f"train: merge PR #{member['number']} ({member['head'][:10]})", member["head"]],
                timeout=GIT_TIMEOUT,
            )
            if mg.returncode != 0:
                run(["git", "-C", worktree, "merge", "--abort"], timeout=GIT_TIMEOUT)
                print(f"error: merge failed for {member['pr']}: {mg.stderr.strip()}", file=sys.stderr)
                return 1
        built_tree = run(["git", "-C", worktree, "rev-parse", "HEAD^{tree}"], timeout=GIT_TIMEOUT).stdout.strip()
        if final_tree and built_tree != final_tree:
            print(f"error: built train tree {built_tree[:12]} diverged from proven final_tree {final_tree[:12]}", file=sys.stderr)
            return 1
        built_head = run(["git", "-C", worktree, "rev-parse", "HEAD"], timeout=GIT_TIMEOUT).stdout.strip()
        trains_dir = home.root / "trains"
        trains_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        slug_name = re.sub(r"[^A-Za-z0-9._-]", "_", branch)
        intent_file = trains_dir / f"{slug_name}.intent.txt"
        nums = ", ".join(f"#{m['number']}" for m in selected)
        intent_text = (
            f"Compound merge train landing {len(selected)} conflict-free PRs ({nums}) onto {base_name} ({base_tip[:10]}).\n\n"
            f"Include this closes block at the very top of the PR body:\n{closes_block}"
        )
        write_atomic(intent_file, intent_text)
        intent_path = str(intent_file)
        append_event(home, f"train:{slug_name}", selected[0]["pr"], built_head, "train-built",
                     f"built {branch} with {len(selected)} members ({nums})")
    result = {
        "ok": True,
        "base": base_name,
        "base_tip": base_tip,
        "selected": selected,
        "excluded": excluded,
        "final_tree": final_tree,
        "branch": branch if build else None,
        "built_head": built_head,
        "intent_file": intent_path,
        "closes_block": closes_block,
    }
    if as_json:
        print(json.dumps(result, indent=1))
        return 0
    print(f"train base={base_name} ({base_tip[:10]}) selected={len(selected)} excluded={len(excluded)}")
    for m in selected:
        print(f"  + #{m['number']} {m['head'][:10]} {m['pr']}")
    for e in excluded:
        print(f"  - {e['pr']} ({e['reason']})")
    if build:
        print(f"built branch={branch} head={built_head[:10]} intent={intent_path}")
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
    if len(argv) == 5 and argv[1] == "_update":
        update_worker(argv[2], argv[3], argv[4])
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
    p_train = sub.add_parser("train")
    p_train.add_argument("--repo", default=None)
    p_train.add_argument("--prs", default=None)
    p_train.add_argument("--max", dest="max_members", type=int, default=5)
    p_train.add_argument("--include-stale-red", action="store_true")
    p_train.add_argument("--worktree", default=None)
    p_train.add_argument("--branch", default=None)
    p_train.add_argument("--base", default="main")
    p_train.add_argument("--build", action="store_true")
    p_train.add_argument("--json", action="store_true")
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
    if args.cmd == "train":
        return cmd_train(
            home,
            repo_filter=args.repo,
            prs_csv=args.prs,
            max_members=max(1, args.max_members),
            include_stale_red=args.include_stale_red,
            worktree=args.worktree,
            branch=args.branch,
            base_name=args.base,
            build=args.build,
            as_json=args.json,
        )
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
