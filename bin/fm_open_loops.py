#!/usr/bin/env python3
"""Open-work reconciler. bin/fm-open-loops.sh owns the CLI; docs/configuration.md owns the schemas.

Every row is computed from live records already kept for this home: the fleet snapshot (backlog and
ordinary tasks), status logs, task worktrees, the no-mistakes run store, and open pull requests.
A source that cannot be read becomes one degraded row; it never reads as "nothing owed".
"""
import argparse
import base64
import fcntl
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).resolve().parent
DEFAULT_AGES = {
    "missing_worker": 600, "ready_not_started": 1800, "unanswered_question": 1800,
    "failed_task": 1800, "stalled_worker": 3600, "unlanded_commit": 86400,
    "open_pr": 3600, "red_check": 0, "coverage": 0,
}
RED_CONCLUSIONS = {"failure", "timed_out", "cancelled", "action_required", "startup_failure"}
PIPELINE_ENDED = {"completed", "failed", "cancelled", "aborted"}
SIGNATURE = re.compile(r"usage.?limit|rate.?limit|quota|auth|unauthorized|login|network|connection"
                       r"|timed? ?out|ECONN|ENOTFOUND|\b(?:error|failure|failed|exception|fatal)\b"
                       r"|\b(?-i:E[A-Z][A-Z0-9_]{2,})\b", re.I)
SOURCE_ERRORS = (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.TimeoutExpired,
                 sqlite3.Error, json.JSONDecodeError)


class CollectionDeadline(Exception):
    pass


def epoch(value):
    if isinstance(value, (int, float)):
        return int(value)
    if not value or not isinstance(value, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return int((parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)).timestamp())


def mtime(path):
    try:
        return int(Path(path).stat().st_mtime)
    except OSError:
        return None


class Collector:
    def __init__(self, home, now):
        self.home = Path(home).resolve()
        self.now = now
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE", self.home / "state"))
        self.data = Path(os.environ.get("FM_DATA_OVERRIDE", self.home / "data"))
        self.config = Path(os.environ.get("FM_CONFIG_OVERRIDE", self.home / "config"))
        self.projects_dir = Path(os.environ.get("FM_PROJECTS_OVERRIDE", self.home / "projects"))
        self.load_config()
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_STATE_OVERRIDE=str(self.state),
                        FM_DATA_OVERRIDE=str(self.data), FM_CONFIG_OVERRIDE=str(self.config),
                        FM_SNAPSHOT_NOW_EPOCH=str(now), GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
        self.env["FM_SNAPSHOT_NOW"] = dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.rows = {}
        self.degraded = []
        self.tasks = []
        self.backlog = []
        self.prs = {}

    def load_config(self):
        path = self.config / "open-loops.json"
        config = json.loads(path.read_text()) if path.exists() else {}
        if not isinstance(config, dict) or set(config) - {"age_limits_seconds", "command_timeout_seconds"}:
            raise ValueError("open-loops configuration must be an object with only age_limits_seconds"
                             " and command_timeout_seconds")
        self.ages = dict(DEFAULT_AGES)
        supplied = config.get("age_limits_seconds", {})
        if not isinstance(supplied, dict) or set(supplied) - set(self.ages):
            raise ValueError("unknown open-loop age category")
        self.ages.update(supplied)
        if any(type(v) is not int or v < 0 for v in self.ages.values()):
            raise ValueError("age limits must be non-negative integer seconds")
        self.timeout = config.get("command_timeout_seconds", 60)
        if type(self.timeout) is not int or not 1 <= self.timeout <= 300:
            raise ValueError("command_timeout_seconds must be 1..300")

    def run(self, args, cwd=None, missing_ok=False, env=None):
        done = subprocess.run([str(a) for a in args], cwd=cwd, env=self.env if env is None else env, capture_output=True,
                              text=True, stdin=subprocess.DEVNULL, timeout=self.timeout)
        if missing_ok and done.returncode == 1 and not done.stderr:
            return ""
        if done.returncode:
            raise RuntimeError((done.stderr or done.stdout or "command failed").strip()[:300])
        return done.stdout

    def git(self, repo, *args):
        return self.run(["git", "-C", repo, *args]).strip()

    def bash(self, script, *args):
        return self.run(["bash", "-c", script, "open-loops", *args])

    def add(self, category, subject, action, since=None, owner="firstmate", evidence=""):
        identity = hashlib.sha256(f"{self.home}\0{category}\0{subject}".encode()).hexdigest()[:24]
        age = None if since is None or since > self.now else self.now - since
        limit = self.ages[category]
        self.rows[identity] = dict(id=identity, category=category, subject=str(subject), owner=owner,
                                   next_action=action, age_seconds=age, limit_seconds=limit,
                                   overdue=age is None or age >= limit, evidence=str(evidence)[:400])

    def source(self, name, reader, *args):
        """Run one reader; its failure marks the ledger partly blind and never aborts the others."""
        try:
            return reader(*args)
        except SOURCE_ERRORS as error:
            self.degraded.append(f"{name}: {str(error)[:160]}")
            return None

    # -- sources ---------------------------------------------------------------------------------

    def read_snapshot(self):
        snap = json.loads(self.run([BIN / "fm-fleet-snapshot.sh", "--home-input"]))
        if snap.get("schema") != "fm-fleet-home-input.v1":
            raise ValueError("unsupported fleet snapshot")
        self.tasks = [t for t in snap["tasks"] if t["kind"] != "secondmate"]
        self.backlog = [r for r in snap["backlog"]["records"] if r.get("structured")]
        if snap["backlog"].get("present") is False:
            raise ValueError("backlog is unavailable")
        for record in snap["backlog"]["records"]:
            if not record.get("structured") and record.get("state") != "done":
                self.degraded.append("unstructured backlog row: " + str(record.get("raw", ""))[:100])

    def backlog_rows(self):
        by_id = {t["id"]: t for t in self.tasks}
        today = dt.datetime.fromtimestamp(self.now, dt.timezone.utc).strftime("%Y-%m-%d")
        for record in self.backlog:
            since = epoch(record.get("since"))
            task = by_id.get(record["id"])
            if record["state"] == "in_flight" and record.get("requires_child_metadata"):
                if not task or task["endpoint"].get("exists") is False:
                    self.add("missing_worker", record["id"], "recover the assigned worker without discarding work",
                             since)
            elif (record["state"] == "queued" and not record.get("hold_kind")
                  and not record.get("unresolved_blocker_ids")
                  and (not record.get("hold_until") or record["hold_until"] <= today)):
                self.add("ready_not_started", record["id"], "dispatch the dependency-cleared work", since)

    def liveness(self, task):
        alive = task["endpoint"].get("agent_alive")
        if task["endpoint"].get("exists") is True and alive not in ("alive", "dead", "missing") \
                and task.get("backend") and task["endpoint"].get("target"):
            state = self.bash('. "$1"; fm_backend_agent_state "$2" "$3"', BIN / "fm-backend.sh",
                              task["backend"], task["endpoint"]["target"]).strip()
            if state == "unverified" and task["current_state"].get("state") == "working":
                return "alive"
            alive = state
        if task["endpoint"].get("exists") is not False and alive not in ("alive", "dead", "missing"):
            raise ValueError("worker liveness is inconclusive: " + str(alive))
        return alive

    def worker_rows(self):
        runs = self.source("no-mistakes run store", self.pipeline_progress) or {}
        for task in self.tasks:
            alive = self.source("worker liveness " + task["id"], self.liveness, task)
            if (task["current_state"].get("state") == "unknown"
                    and not (alive in ("dead", "missing")
                             and task["current_state"].get("detail", "").startswith("backend target gone:"))):
                self.degraded.append("worker current state " + task["id"] + ": "
                                     + (task["current_state"].get("detail") or "observation unavailable"))
            if task["endpoint"].get("exists") is False or alive in ("dead", "missing"):
                self.add("missing_worker", task["id"], "recover the assigned worker without discarding work",
                         mtime(self.state / (task["id"] + ".status")) or mtime(self.state / (task["id"] + ".meta")))
            if task["current_state"].get("state") == "failed":
                if not self.source("failed deliverable " + task["id"], self.deliverable_landed, task):
                    self.add("failed_task", task["id"], "recover the failed work or record why it ends",
                             mtime(self.state / (task["id"] + ".status")))
            elif task["current_state"].get("state") == "working" and alive == "alive":
                self.source("progress " + task["id"], self.stalled, task, runs)
            self.source("unlanded work " + task["id"], self.unlanded, task)

    def pipeline_progress(self):
        """Latest recorded pipeline step time per (project, branch); no store is not a failure."""
        root = Path(os.environ.get("NM_HOME", Path.home() / ".no-mistakes"))
        database = root / "state.sqlite"
        if not database.exists():
            return {}
        out = {}
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=2) as db:
            db.row_factory = sqlite3.Row
            columns = {c[1] for c in db.execute("PRAGMA table_info(step_results)")}
            fields = [k for k in ("started_at", "round_started_at", "completed_at", "last_activity_at") if k in columns]
            if not fields:
                raise ValueError("pipeline step progress fields unavailable")
            query = ("SELECT runs.branch, repos.working_path, runs.created_at, "
                     + ", ".join("step_results." + f for f in fields)
                     + " FROM runs JOIN repos ON runs.repo_id = repos.id"
                     " LEFT JOIN step_results ON step_results.run_id = runs.id")
            for row in db.execute(query):
                stamps = [epoch(row["created_at"])] + [epoch(row[f]) for f in fields]
                key = (str(Path(row["working_path"]).resolve()), row["branch"])
                valid = [s for s in stamps if s is not None and s <= self.now]
                if valid:
                    out[key] = max([out[key]] + valid) if key in out else max(valid)
        return out

    def stalled(self, task, runs):
        stamps = [mtime(self.state / (task["id"] + ".status"))]
        worktree = self.task_worktree(task)
        if worktree:
            stamps.append(int(self.git(worktree, "show", "-s", "--format=%ct", "HEAD")))
            # The reflog stamps when a commit was observed, not when it was authored.
            stamps.append(mtime(Path(self.git(worktree, "rev-parse", "--absolute-git-dir")) / "logs/HEAD"))
        if task.get("project") and task.get("branch"):
            stamps.append(runs.get((str(Path(task["project"]).resolve()), task["branch"])))
        since = max((s for s in stamps if s is not None and s <= self.now), default=None)
        if since is not None and self.now - since < self.ages["stalled_worker"]:
            return
        pane = self.run([BIN / "fm-peek.sh", task["id"], "80"])
        signatures = [line.strip() for line in pane.splitlines() if SIGNATURE.search(line)]
        self.add("stalled_worker", task["id"], "inspect and recover the stalled-but-alive worker", since,
                 evidence=signatures[-1][:300] if signatures else "no commit, status line, or pipeline progress")

    def task_worktree(self, task):
        worktree = task["paths"]["worktree"].get("path")
        return worktree if worktree and Path(worktree).is_dir() else None

    def default_ref(self, worktree, mode=None):
        refs = ("refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master",
                "refs/heads/main", "refs/heads/master")
        if mode == "local-only":
            try:
                remote = self.git(worktree, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
            except RuntimeError:
                remote = ""
            refs = tuple(dict.fromkeys(
                ([remote.replace("refs/remotes/origin/", "refs/heads/", 1)]
                 if remote.startswith("refs/remotes/origin/") else [])
                + ["refs/heads/main", "refs/heads/master"]))
        for ref in refs:
            try:
                self.git(worktree, "rev-parse", "--verify", "--quiet", ref)
            except RuntimeError:
                continue
            try:
                return self.git(worktree, "symbolic-ref", "--quiet", ref)
            except RuntimeError:
                return ref
        raise ValueError("default branch is unknown")

    def pending_commits(self, worktree, base):
        return self.git(worktree, "rev-list", "--reverse", "--cherry-pick", "--right-only",
                        "--no-merges", base + "...HEAD").splitlines()

    def pr_pending(self, worktree, pending, pr):
        head = pr["head"]["sha"]
        self.git(worktree, "cat-file", "-e", head + "^{commit}")
        uncovered = self.pending_commits(worktree, head)
        if pending is None:
            return uncovered
        uncovered = set(uncovered)
        return [commit for commit in pending if commit in uncovered]

    def content_in_default(self, worktree, base):
        default_tree = self.git(worktree, "rev-parse", base + "^{tree}")
        try:
            objects = self.git(worktree, "rev-parse", "--path-format=absolute", "--git-path", "objects")
            with tempfile.TemporaryDirectory(prefix="fm-open-loops-objects-") as temporary:
                env = dict(self.env, GIT_OBJECT_DIRECTORY=temporary,
                           GIT_ALTERNATE_OBJECT_DIRECTORIES=objects)
                merged_tree = self.run(["git", "-C", worktree, "merge-tree", "--write-tree",
                                        base, "HEAD"], env=env).splitlines()[0]
        except RuntimeError:
            return False
        return merged_tree == default_tree

    def captain_dropped(self, task):
        return any(record["id"] == task["id"] and record.get("captain_drop") for record in self.backlog)

    def deliverable_landed(self, task):
        if self.captain_dropped(task):
            return True
        if task["kind"] == "scout":
            report = self.data / task["id"] / "report.md"
            return report.is_file() and not report.is_symlink() and report.stat().st_size > 0
        worktree = self.task_worktree(task)
        pr = self.pr_state(task["pr"]["url"]) if task["pr"].get("url") else None
        if not worktree:
            return bool(pr and pr.get("merged_at"))
        if self.git(worktree, "status", "--porcelain"):
            return False
        if pr and pr.get("merged_at"):
            uncovered = self.source("PR head " + task["id"], self.pr_pending, worktree, None, pr)
            if uncovered == []:
                return True
        base = self.default_ref(worktree, task.get("mode"))
        pending = self.pending_commits(worktree, base)
        return not pending or self.content_in_default(worktree, base)

    def unlanded(self, task):
        if task["kind"] != "ship" or self.captain_dropped(task):
            return
        worktree = self.task_worktree(task)
        if not worktree:
            return
        base = self.default_ref(worktree, task.get("mode"))
        pending = self.pending_commits(worktree, base)
        if not pending or self.content_in_default(worktree, base):
            return
        pr = self.pr_state(task["pr"]["url"]) if task["pr"].get("url") else None
        if pr and (pr.get("merged_at") or pr.get("state") == "open"):
            covered = self.source("PR head " + task["id"], self.pr_pending, worktree, pending, pr)
            if covered is not None:
                pending = covered
        if not pending:
            return
        oldest = min(int(self.git(worktree, "show", "-s", "--format=%ct", c)) for c in pending)
        title = self.git(worktree, "show", "-s", "--format=%s", pending[-1])
        self.add("unlanded_commit", task["id"], "land this work through its PR, or obtain the captain's drop",
                 oldest, evidence=f"{len(pending)} commit(s) not on {base}; newest: {title}")

    def forge(self, path):
        # gh-axi renders parsed JSON as TOON, so the body travels as base64 lines (one per page).
        raw = self.run(["gh-axi", "api", path, "--paginate", "--jq", "@base64", "--full"])
        match = re.search(r"^  body: (.+)$", raw, re.M)
        if not match or re.search(r"^  truncated: true$", raw, re.M):
            raise ValueError("forge response body unavailable or truncated")
        body = json.loads(match[1]) if match[1].startswith('"') else match[1]
        pages = [json.loads(base64.b64decode(line, validate=True)) for line in body.splitlines()]
        return [row for page in pages for row in (page if isinstance(page, list) else [page])]

    def pr_state(self, url):
        if url in self.prs:
            return self.prs[url]
        match = re.fullmatch(r"https://github[.]com/([^/]+/[^/]+)/pull/(\d+)", url)
        if not match:
            self.degraded.append("unsupported PR forge: " + url)
            self.prs[url] = None
            return None
        pr = self.source("PR state " + url, lambda: self.forge(f"/repos/{match[1]}/pulls/{match[2]}")[0])
        self.prs[url] = pr
        return pr

    def repo_slugs(self):
        paths = {t["project"] for t in self.tasks if t.get("project")}
        if (self.home / ".git").exists():
            paths.add(str(self.home))
        if self.projects_dir.is_dir():
            paths |= {str(p) for p in self.projects_dir.iterdir() if (p / ".git").exists()}
        slugs = set()
        for path in sorted(paths):
            origin = self.source("project origin " + path, self.repo_origin, path)
            if not origin:
                continue
            match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", origin)
            if match:
                slugs.add(match[1])
        return sorted(slugs)

    def repo_origin(self, path):
        self.git(path, "rev-parse", "--git-dir")
        origin = self.run(["git", "-C", path, "config", "--get", "remote.origin.url"], missing_ok=True).strip()
        if origin and not re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", origin):
            raise ValueError("unsupported non-GitHub origin: " + origin)
        return origin

    def latest_checks(self, slug, sha):
        runs = [c for page in self.forge(f"/repos/{slug}/commits/{sha}/check-runs?per_page=100")
                for c in page.get("check_runs", [])]
        newest = {}
        for run in runs:  # a re-run supersedes an older run of the same check
            key = (run.get("app", {}).get("id"), run.get("name"))
            if key not in newest or run.get("id", 0) > newest[key].get("id", 0):
                newest[key] = run
        statuses = {}
        for status in self.forge(f"/repos/{slug}/commits/{sha}/statuses?per_page=100"):
            statuses.setdefault(status["context"], status)  # newest first
        return list(newest.values()), list(statuses.values())

    def pr_row(self, slug, pr):
        url, sha = pr["html_url"], pr["head"]["sha"]
        task = next((t for t in self.tasks if t["pr"].get("url") == url), None)
        worker = "worker:" + task["id"] if task else "firstmate"
        checks, statuses = self.latest_checks(slug, sha)
        red = [c for c in checks if c.get("conclusion") in RED_CONCLUSIONS]
        red += [s for s in statuses if s["state"] in ("failure", "error")]
        if red:
            since = min((epoch(c.get("completed_at") or c.get("updated_at") or c.get("created_at")) or self.now)
                        for c in red)
            self.add("red_check", url, "diagnose: code or test", since, worker,
                     "; ".join(c.get("name") or c.get("context") or "check" for c in red))
            return
        pending = (not checks and not statuses) or any(c.get("status") != "completed" for c in checks) \
            or any(s["state"] == "pending" for s in statuses)
        if pr.get("draft"):
            owner, action = worker, "finish the PR and mark it ready"
        elif pending:
            owner, action = "firstmate", "monitor CI and route its result"
        elif pr.get("requested_reviewers") or pr.get("requested_teams"):
            people = [r["login"] for r in pr.get("requested_reviewers", [])]
            teams = ["team:" + t["slug"] for t in pr.get("requested_teams", [])]
            owner, action = ",".join(people + teams), "complete the requested PR review"
        else:
            owner, action = "firstmate", "route the green PR's review and obtain merge approval"
        self.add("open_pr", url, action, epoch(pr.get("updated_at")), owner)

    def pr_rows(self, slug):
        pulls = self.forge(f"/repos/{slug}/pulls?state=open&per_page=100")
        self.prs.update((pr["html_url"], pr) for pr in pulls)
        for pr in pulls:
            self.source(f"PR {slug}#{pr.get('number', '?')}", self.pr_row, slug, pr)

    def question_rows(self):
        for status in sorted(self.state.glob("*.status")):
            if status.is_symlink():
                continue
            try:
                out = self.bash('cat "$2" >/dev/null || exit 1; '
                                '. "$1/fm-status-decision-lib.sh"; status_open_decisions_dated "$2"', BIN, status)
            except SOURCE_ERRORS as error:
                self.degraded.append(f"questions {status.name}: {str(error)[:120]}")
                continue
            for line in out.splitlines():
                key, verb, opened, summary = (line.split("\t", 3) + ["", "", "", ""])[:4]
                self.add("unanswered_question", f"{status.stem}:{key}",
                         "answer or close this question, or record why it no longer applies",
                         int(opened) if opened.isdigit() else None, evidence=f"{verb}: {summary}")

    # -- run -------------------------------------------------------------------------------------

    def collect(self):
        self.source("fleet snapshot", self.read_snapshot)
        self.source("backlog", self.backlog_rows)
        slugs = self.source("project origins", self.repo_slugs) or []
        for slug in slugs:
            self.source("open PRs " + slug, self.pr_rows, slug)
        self.source("workers", self.worker_rows)
        self.source("questions", self.question_rows)
        if self.degraded:
            self.add("coverage", "ledger degraded", "restore the unreadable sources and rerun the reconciler",
                     None, evidence="; ".join(self.degraded))

    def result(self):
        rows = sorted(self.rows.values(), key=lambda r: (r["category"], r["subject"]))
        return dict(schema="fm-open-loops.v1", generated_epoch=self.now, home=str(self.home),
                    complete=not self.degraded, rows=rows)

    def publish(self):
        self.state.mkdir(parents=True, exist_ok=True)
        target = self.state / "open-loops.json"
        if target.is_symlink():
            raise ValueError("open-loop ledger must not be a symbolic link")
        report = self.result()
        fd, temp = tempfile.mkstemp(prefix=".open-loops-", dir=self.state)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(report, stream)
                stream.write("\n")
            os.replace(temp, target)
            try:
                (self.state / ".open-loops-stale-surfaced").unlink()
            except FileNotFoundError:
                pass
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
        return report


def render(report):
    lines = ["bin: " + str(BIN / "fm-open-loops.sh"),
             "description: Reconcile assigned work against live delivery evidence",
             "complete: " + str(report["complete"]).lower(), f"generated_epoch: {report['generated_epoch']}"]
    fields = ["category", "subject", "owner", "next_action", "age_seconds", "overdue", "evidence"]
    if report["rows"]:
        lines.append(f"rows[{len(report['rows'])}]{{{','.join(fields)}}}:")
        lines += ["  " + ",".join(json.dumps(r.get(f), ensure_ascii=False) for f in fields) for r in report["rows"]]
    else:
        lines.append("rows: []")
    lines.append("help: Run bin/fm-open-loops.sh --json for age limits and structured rows")
    return "\n".join(lines)


class CliParser(argparse.ArgumentParser):
    def error(self, message):
        print("error: " + json.dumps(message))
        raise SystemExit(2)


def main():
    parser = CliParser(description="Reconcile assigned work against live reality")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--heartbeat", action="store_true", help="publish state/open-loops.json")
    args = parser.parse_args()
    home = Path(os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", BIN.parent))).resolve()
    try:
        lock_dir = Path(os.environ.get("FM_STATE_OVERRIDE", home / "state")).resolve()
        lock_dir.mkdir(parents=True, exist_ok=True)
        lock_fd = os.open(lock_dir / ".open-loops.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if args.heartbeat else 0))
        except BlockingIOError:
            os.close(lock_fd)
            return 0
        now = int(os.environ.get("FM_OPEN_LOOPS_NOW", time.time()))
        collector = Collector(home, now)
    except (OSError, ValueError) as error:
        print("error: " + json.dumps(str(error)))
        return 1

    def deadline(_signum, _frame):
        raise CollectionDeadline("collection exceeded its deadline")
    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(collector.timeout * 10)
    try:
        collector.collect()
    except (CollectionDeadline, *SOURCE_ERRORS) as error:
        collector.degraded.insert(0, "reconciler: " + str(error)[:160])
        collector.add("coverage", "ledger degraded", "restore the unreadable sources and rerun the reconciler",
                      None, evidence="; ".join(collector.degraded))
    finally:
        signal.alarm(0)
    try:
        report = collector.publish() if args.heartbeat else collector.result()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("error: " + json.dumps(str(error)))
        return 1
    print(json.dumps(report) if args.json else render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
