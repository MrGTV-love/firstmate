#!/usr/bin/env python3
"""Open-work reconciler. bin/fm-open-loops.sh owns the CLI; docs/configuration.md owns the schemas.

The CLI owner's configuration reference describes collection sources, quota refusal, and degraded coverage.
"""
import argparse
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
GH_REST = BIN / "fm-gh-rest.sh"  # conditional REST reads and the shared quota floor
DEFAULT_AGES = {
    "missing_worker": 600, "ready_not_started": 1800, "unanswered_question": 1800,
    "unhandled_board_answer": 300, "interrupted_teardown": 1800,
    "failed_task": 1800, "stalled_worker": 3600, "unlanded_commit": 86400,
    "open_pr": 3600, "review_pass_not_merged": 600, "red_check": 0, "coverage": 0, "silent_report": 900,
}
CHECK_IN_TEXT = ("Check in: report progress, blockers, and cross-workstream dependencies that need resolution. "
                 "Reply through your supervised status/report channel before acknowledging this inbox message; "
                 "secondmates must preserve the request correlation in their parent-channel reply. "
                 "Handle this at your next safe checkpoint; do not interrupt a running step.")
RED_CONCLUSIONS = {"failure", "timed_out", "cancelled", "action_required", "startup_failure"}
GITHUB_PR = re.compile(r"https://github[.]com/([^/]+/[^/]+)/pull/(\d+)")
DAY_SECONDS = int(dt.timedelta(days=1).total_seconds())  # policy: longest deferral, unseen-row retention
# Categories a captain decision can park: the same set a dependency wait may bind.
CAPTAIN_PARKABLE = ("open_pr", "unanswered_question", "unlanded_commit")
GITHUB_ORIGIN = re.compile(r"(?:https?://github[.]com/|git://github[.]com/"
                           r"|ssh://(?:git@)?github[.]com/|git@github[.]com:)"
                           r"([^/]+/[^/]+?)(?:[.]git)?")
PIPELINE_ENDED = {"completed", "failed", "cancelled", "aborted"}
STOP_STATES = {"done", "parked", "paused"}
SIGNATURE = re.compile(r"usage.?limit|rate.?limit|quota|auth|unauthorized|login|network|connection"
                       r"|timed? ?out|ECONN|ENOTFOUND|\b(?:error|failure|failed|exception|fatal)\b"
                       r"|\b(?-i:E[A-Z][A-Z0-9_]{2,})\b", re.I)


def is_local_origin(origin):
    """Git's own rule for a filesystem remote: a file:// URL, or neither a scheme URL nor scp-style host:path."""
    if origin.startswith("file://"):
        return True
    if "://" in origin:
        return False
    colon, slash = origin.find(":"), origin.find("/")
    return colon < 0 or 0 <= slash < colon


SOURCE_ERRORS = (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.TimeoutExpired,
                 sqlite3.Error, json.JSONDecodeError)


class CollectionDeadline(Exception):
    pass


class PrHeadMissing(Exception):
    """The PR's recorded head commit is not an object in the task's copy, so its coverage cannot be read."""


class QuotaLow(Exception):
    """The recorded GitHub quota is below the floor; the sweep stops instead of publishing partial rows."""


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


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


class Collector:
    def __init__(self, home, now):
        self.home = Path(home).resolve()
        self.now = now
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE") or self.home / "state")
        self.data = Path(os.environ.get("FM_DATA_OVERRIDE") or self.home / "data")
        self.config = Path(os.environ.get("FM_CONFIG_OVERRIDE") or self.home / "config")
        self.projects_dir = Path(os.environ.get("FM_PROJECTS_OVERRIDE") or self.home / "projects")
        self.load_config()
        self.required = {}
        self.pipeline_waits = {}
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_STATE_OVERRIDE=str(self.state),
                        FM_DATA_OVERRIDE=str(self.data), FM_CONFIG_OVERRIDE=str(self.config),
                        FM_PROJECTS_OVERRIDE=str(self.projects_dir), FM_SNAPSHOT_NOW_EPOCH=str(now),
                        GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
        self.env["FM_SNAPSHOT_NOW"] = dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.rows = {}
        self.stale_reason = None
        self.stale_generated = None
        self.degraded = []
        self.tasks = []
        self.direct_reports = []
        self.reply_by_task = None
        self.backlog = []
        self.prs = {}
        self.missing_heads = {}
        self.state_files = []
        self.owned_urls = set()
        self.owned_branches = set()
        self.lane = self.is_secondmate_home()

    def is_secondmate_home(self):
        """A genuine secondmate-home marker: a regular file holding a valid id (fm-primary-scope-lib.sh)."""
        marker = self.home / ".fm-secondmate-home"
        try:
            if marker.is_symlink() or not marker.is_file():
                return False
            first = marker.read_text().splitlines()[:1]
        except (OSError, UnicodeDecodeError):
            return False
        ident = re.sub(r"\s", "", first[0]) if first else ""
        return bool(ident) and re.fullmatch(r"[A-Za-z0-9._-]+", ident) is not None

    def load_config(self):
        path = self.config / "open-loops.json"
        config = json.loads(path.read_text()) if path.exists() else {}
        if not isinstance(config, dict) or set(config) - {"age_limits_seconds", "command_timeout_seconds", "review_lanes"}:
            raise ValueError("open-loops configuration supports age_limits_seconds, command_timeout_seconds and review_lanes")
        self.review_lanes = config.get("review_lanes", {})
        if not isinstance(self.review_lanes, dict) or any(
                not isinstance(slug, str) or not re.fullmatch(r"[^/\s]+/[^/\s]+", slug)
                or not isinstance(lanes, list) or not lanes
                or any(not isinstance(lane, str) or not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", lane)
                       for lane in lanes) for slug, lanes in self.review_lanes.items()):
            raise ValueError("review_lanes must map owner/repository to nonempty lists of local review task ids")
        self.review_lanes = {slug.casefold(): lanes for slug, lanes in self.review_lanes.items()}
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

    def process_table(self, pids=None):
        if pids is not None and not pids:
            return {}
        selection = ["-A"] if pids is None else ["-p", ",".join(str(pid) for pid in pids)]
        done = subprocess.run(["ps", *selection, "-o", "pid=", "-o", "ppid=", "-o", "lstart="],
                              env=self.env, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL)
        if done.returncode:
            if pids is not None and done.returncode == 1 and not done.stdout.strip() and not done.stderr.strip():
                return {}
            raise RuntimeError("cannot enumerate command process tree: "
                               + (done.stderr or "ps failed").strip()[:200])
        return {int(pid): (int(parent), identity.strip())
                for pid, parent, identity in (line.split(None, 2) for line in done.stdout.splitlines())}

    def signal_command_group(self, child, sig):
        if child.poll() is not None:
            return
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            if child.poll() is None:
                raise

    def stop_command(self, child):
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
        descendants = {}
        try:
            try:
                self.signal_command_group(child, signal.SIGSTOP)
                table = self.process_table()
                children = {}
                for pid, (parent, _identity) in table.items():
                    children.setdefault(parent, []).append(pid)
                pending = list(children.get(child.pid, []))
                while pending:
                    pid = pending.pop()
                    if pid not in descendants:
                        descendants[pid] = table[pid][1]
                        pending.extend(children.get(pid, []))
                self.signal_command_group(child, signal.SIGTERM)
                self.signal_command_group(child, signal.SIGCONT)
                for pid in descendants:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                try:
                    child.communicate(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
            finally:
                try:
                    self.signal_command_group(child, signal.SIGKILL)
                finally:
                    if descendants:
                        current = self.process_table(descendants)
                        for pid, identity in descendants.items():
                            if current.get(pid, (None, None))[1] == identity:
                                try:
                                    os.kill(pid, signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
        finally:
            child.wait()
            child.stdout.close()
            child.stderr.close()
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    def run(self, args, cwd=None, missing_ok=False, env=None):
        command = [str(a) for a in args]
        child = subprocess.Popen(command, cwd=cwd, env=self.env if env is None else env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace",
                                 stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            stdout, stderr = child.communicate(timeout=self.timeout)
        except (subprocess.TimeoutExpired, CollectionDeadline):
            self.stop_command(child)
            raise
        if child.returncode == 75 and command[0] == str(GH_REST):
            raise QuotaLow(stderr.strip())
        if missing_ok and child.returncode == 1 and not stderr:
            return ""
        if child.returncode:
            raise RuntimeError((stderr or stdout or "command failed").strip()[:300])
        return stdout

    def git(self, repo, *args):
        return self.run(["git", "-C", repo, *args]).strip()

    def bash(self, script, *args):
        return self.run(["bash", "-c", script, "open-loops", *args])

    def add(self, category, subject, action, since=None, owner="firstmate", evidence="", informational=False,
            source=None):
        """An informational row is visible context, never an obligation: it is not overdue at any age."""
        identity = hashlib.sha256(f"{self.home}\0{category}\0{subject}".encode()).hexdigest()[:24]
        age = None if since is None or since > self.now else self.now - since
        limit = self.ages[category]
        row = dict(id=identity, category=category, subject=str(subject), owner=owner,
                   next_action=action, age_seconds=age, limit_seconds=limit,
                   overdue=not informational and (age is None or age >= limit), evidence=str(evidence)[:400])
        if informational:
            row["informational"] = True
        if source is not None:
            row["source"] = source
        self.rows[identity] = row

    def source(self, name, reader, *args):
        """Run one reader; its failure marks the ledger partly blind and never aborts the others."""
        try:
            return reader(*args)
        except SOURCE_ERRORS as error:
            self.degraded.append(f"{name}: {str(error)[:160]}")
            return None

    # -- sources ---------------------------------------------------------------------------------

    def read_state_inventory(self):
        self.state_files = sorted(self.state.iterdir())

    def read_snapshot(self):
        snap = json.loads(self.run([BIN / "fm-fleet-snapshot.sh", "--home-input"]))
        if snap.get("schema") != "fm-fleet-home-input.v1":
            raise ValueError("unsupported fleet snapshot")
        self.direct_reports = snap["tasks"]
        self.tasks = [t for t in self.direct_reports if t["kind"] != "secondmate"]
        self.backlog = [r for r in snap["backlog"]["records"] if r.get("structured")]
        if snap["backlog"].get("present") is False:
            raise ValueError("backlog is unavailable")
        for record in snap["backlog"]["records"]:
            if not record.get("structured") and record.get("state") != "done":
                self.degraded.append("unstructured backlog row: " + str(record.get("raw", ""))[:100])

    def reply_records(self, task_id):
        if self.reply_by_task is None:
            directory = self.state / "pending-replies"
            grouped = {}
            for path in directory.iterdir() if directory.exists() else ():
                if re.fullmatch(r"[a-fA-F0-9]{16}", path.name) and path.is_file():
                    record = self.read_fields(path)
                    grouped.setdefault(record.get("task_id"), []).append(record)
            self.reply_by_task = grouped
        return self.reply_by_task.get(task_id, [])

    @staticmethod
    def read_fields(path):
        return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)

    def report_status(self, task_id):
        # The shared parser owns stamps, logical events and standing pause declarations.
        path = self.state / (task_id + ".status")
        out = self.bash('. "$1/fm-classify-lib.sh"; last=$(last_status_line "$2"); '
                        'printf "%s\\n" "$(status_line_at_epoch "$last" || :)" '
                        '"$(status_line_verb "$last")"; '
                        'status_own_open_decisions "$2" | awk -F"\\t" \'$2 == "needs-decision" || $2 == "blocked" '
                        '{ n = 1 } END { print n + 0 }\'; '
                        'wait=$(status_declared_wait_line "$2"); '
                        'if status_is_paused_or_captain_held "$wait" && [ -n "$(status_line_note "$wait")" ]; then '
                        'printf "%s\\n%s\\n%s\\n" "${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}" '
                        '"$(status_paused_until "$wait" || :)" "$(status_line_note "$wait")"; fi', BIN, path)
        fields = out.splitlines()
        fields += [""] * (6 - len(fields))
        stamp, verb, open_decision, cadence, until, note = fields[:6]
        return (int(stamp) if stamp.isdigit() else mtime(path), verb, open_decision == "1",
                int(cadence) if cadence.isdigit() and int(cadence) > 0 else None,
                int(until) if until.isdigit() else None, note)

    def secondmate_has_work(self, task):
        if task.get("remote"):
            output = self.run([BIN / "fm-on.sh", task["id"], "fm-fleet-snapshot.sh", "--contribution-input"])
        else:
            home = task.get("paths", {}).get("home", {}).get("path")
            if not home:
                raise ValueError("secondmate home is unavailable")
            env = dict(self.env, FM_HOME=home)
            for key in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE"):
                env.pop(key, None)
            output = self.run([BIN / "fm-fleet-snapshot.sh", "--contribution-input"], env=env)
        snapshot = json.loads(output)
        if not isinstance(snapshot.get("backlog"), dict) or not snapshot["backlog"].get("present"):
            raise ValueError("secondmate backlog is unavailable")
        return any(row.get("state") == "in_flight" for row in snapshot["backlog"]["records"])

    def gate_awaits_human(self, task):
        state = task["current_state"]
        if state.get("state") != "parked" or state.get("source") != "run-step":
            return False
        return bool(self.bash('. "$1/fm-classify-lib.sh"; crew_gate_awaits_human_decision "$2" || :',
                              BIN, task["id"]).strip())

    def silent_report(self, task):
        ident = task["id"]
        if task["current_state"].get("detail") == "task generation changed during snapshot":
            raise ValueError("task generation changed during snapshot")
        if task["endpoint"].get("exists") is False or task["endpoint"].get("agent_alive") in ("dead", "missing"):
            return
        status_at, verb, open_decision, pause_limit, until, pause_note = self.report_status(ident)
        records = self.reply_records(ident)
        open_replies = [r for r in records if r.get("phase") != "resolved"]
        inbox = self.state / (ident + ".inbox")
        handled = inbox / "handled"
        # rename preserves the message's send mtime; directory mtime records the acknowledgement move.
        ack_at = mtime(handled) if any(handled.glob("[0-9]*.msg")) else None
        reply_at = max((int(r["resolved_epoch"]) for r in records
                        if r.get("phase") == "resolved" and r.get("resolved_epoch", "").isdigit()
                        and int(r["resolved_epoch"]) <= self.now), default=None)
        stamps = [s for s in (status_at, ack_at, reply_at) if s is not None and s <= self.now]
        dispatched = mtime(self.state / (ident + ".meta"))
        since = max(stamps, default=dispatched if dispatched is not None and dispatched <= self.now else None)
        evidence = f"last heard: status={status_at}; inbox acknowledgement={ack_at}; resolved reply={reply_at}"
        excluded = None
        long_wait = False
        if task["kind"] != "secondmate" and (verb == "done" or task["current_state"].get("state") == "done"):
            excluded = "excluded: done/ready task is covered by PR or landing evidence"
        elif task["kind"] == "secondmate" and not open_replies and not self.secondmate_has_work(task):
            excluded = "excluded: idle secondmate has no routed work in flight"
        elif open_decision or self.gate_awaits_human(task):
            excluded = "excluded: waiting on firstmate; its unanswered question or human-owned gate owns the next move"
        elif pause_limit and (until is None or until > self.now):
            # Keep the declared wait visible on the watcher's long cadence, not the ordinary check-in cadence.
            excluded = "declared wait uses long cadence: " + pause_note
            long_wait = True
        pending = bool(open_replies) or any(CHECK_IN_TEXT in path.read_text()
                                           for path in inbox.glob("[0-9]*.msg"))
        informational = bool(excluded and not long_wait) or pending
        if pending:
            evidence += "; pending reply/check-in: do not repeat; existing reply or inbox escalation owns recovery"
        if excluded:
            evidence += "; " + excluded
        if not stamps:
            evidence += "; no report yet: clock starts at dispatch"
        self.add("silent_report", ident, "check in: progress, blockers, cross-workstream dependencies",
                 since, evidence=evidence, informational=informational)
        if long_wait:
            row = next(r for r in self.rows.values() if r["category"] == "silent_report" and r["subject"] == ident)
            row["limit_seconds"] = pause_limit
            row["overdue"] = not informational and (row["age_seconds"] is None or row["age_seconds"] >= pause_limit)

    def silent_reports(self):
        for task in self.direct_reports:
            self.source("report silence " + task["id"], self.silent_report, task)

    def check_in(self, task_id):
        row = next((r for r in self.rows.values() if r["category"] == "silent_report"
                    and r["subject"] == task_id), None)
        if not row:
            raise ValueError("no live direct report eligible for a check-in: " + task_id)
        if not row["overdue"]:
            return dict(check_in="not_sent", subject=task_id,
                        reason="report is fresh, excluded, or already has a pending request")
        task = next(t for t in self.direct_reports if t["id"] == task_id)
        env = dict(self.env)
        if task.get("spawn_gen"):
            env["FM_SEND_EXPECTED_SPAWN_GEN"] = task["spawn_gen"]
        self.run([BIN / "fm-send.sh", task_id, CHECK_IN_TEXT], env=env)
        return dict(check_in="sent", subject=task_id)

    def recorded_stop(self, task):
        """True when the worker's own durable record says it stopped on purpose, so its endpoint
        being gone or its live state being unreadable is expected rather than a loss."""
        if task["current_state"].get("detail") == "task generation changed during snapshot":
            return False
        state = task["current_state"].get("state")
        if state in ("working", "blocked", "failed"):
            return False
        if state in STOP_STATES:
            return True
        return self.bash('. "$1"; last=$(last_status_line "$2"); '
                         'if [ "$(status_line_verb "$last")" = done ] || '
                         'status_is_paused "$(status_declared_wait_line "$2")"; then printf stopped; fi',
                         BIN / "fm-status-event-lib.sh", self.state / (task["id"] + ".status")).strip() == "stopped"

    def backlog_rows(self):
        by_id = {t["id"]: t for t in self.tasks}
        dispatched = {p.name.rsplit(".", 1)[0] for p in self.state_files if p.name.endswith((".meta", ".status"))}
        today = dt.datetime.fromtimestamp(self.now, dt.timezone.utc).strftime("%Y-%m-%d")
        for record in self.backlog:
            since = epoch(record.get("since"))
            task = by_id.get(record["id"])
            if record["state"] == "in_flight" and record.get("requires_child_metadata"):
                if not task or (task["endpoint"].get("exists") is False and not self.recorded_stop(task)):
                    self.add("missing_worker", record["id"], "recover the assigned worker without discarding work",
                             since)
            elif (record["state"] == "queued" and not record.get("hold_kind")
                  and not record.get("unresolved_blocker_ids")
                  and (not record.get("hold_until") or record["hold_until"] <= today)):
                # Only work whose dispatch began (a task record or status log exists) is an obligation;
                # the rest of the queue is the captain's backlog, shown but never overdue.
                selected = record["id"] in by_id or record["id"] in dispatched
                self.add("ready_not_started", record["id"],
                         "dispatch the dependency-cleared work" if selected
                         else "informational: queued and not selected for dispatch",
                         since, informational=not selected)

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
        for task in self.tasks:
            stopped = self.source("worker stop " + task["id"], self.recorded_stop, task)
            if stopped:  # a recorded stop explains an unreadable endpoint; it never degrades coverage
                try:
                    alive = self.liveness(task)
                except SOURCE_ERRORS:
                    alive = None
            else:
                alive = self.source("worker liveness " + task["id"], self.liveness, task)
            # Silence tracking shares this observation rather than probing again or counting a dead worker as live.
            task["endpoint"]["agent_alive"] = alive
            if (task["current_state"].get("state") == "unknown" and not stopped
                    and not (alive in ("dead", "missing")
                             and task["current_state"].get("detail", "").startswith("backend target gone:"))):
                self.degraded.append("worker current state " + task["id"] + ": "
                                     + (task["current_state"].get("detail") or "observation unavailable"))
            if not stopped and (task["endpoint"].get("exists") is False or alive in ("dead", "missing")):
                self.add("missing_worker", task["id"], "recover the assigned worker without discarding work",
                         mtime(self.state / (task["id"] + ".status")) or mtime(self.state / (task["id"] + ".meta")))
            if task["current_state"].get("state") == "failed":
                if not self.source("failed deliverable " + task["id"], self.deliverable_landed, task):
                    self.add("failed_task", task["id"], "recover the failed work or record why it ends",
                             mtime(self.state / (task["id"] + ".status")))
            elif task["current_state"].get("state") == "working" and alive == "alive":
                self.source("progress " + task["id"], self.stalled, task)
            self.source("unlanded work " + task["id"], self.unlanded, task)

    def pipeline_progress(self, worktree):
        """Latest recorded pipeline step time per (project, branch); no store is not a failure."""
        self.pipeline_waits.clear()
        root = Path(os.environ.get("NM_HOME") or Path.home() / ".no-mistakes")
        if not root.is_absolute():
            if not worktree:
                raise ValueError("relative NM_HOME requires a task worktree")
            root = Path(worktree) / root
        database = root.resolve() / "state.sqlite"
        if not database.exists():
            return {}
        out = {}
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=2) as db:
            db.row_factory = sqlite3.Row
            columns = {c[1] for c in db.execute("PRAGMA table_info(step_results)")}
            fields = [k for k in ("started_at", "round_started_at", "completed_at", "last_activity_at") if k in columns]
            if not fields:
                raise ValueError("pipeline step progress fields unavailable")
            step = next((name for name in ("step", "step_name", "name") if name in columns), None)
            selected = fields + ([step] if step else [])
            run_status = "status" in {c[1] for c in db.execute("PRAGMA table_info(runs)")}
            query = ("SELECT runs.branch, repos.working_path, runs.created_at, "
                     + ("runs.status AS run_status, " if run_status else "")
                     + ", ".join("step_results." + f for f in selected)
                     + " FROM runs JOIN repos ON runs.repo_id = repos.id"
                     " LEFT JOIN step_results ON step_results.run_id = runs.id")
            for row in db.execute(query):
                stamps = [epoch(row["created_at"])] + [epoch(row[f]) for f in fields]
                key = (str(Path(row["working_path"]).resolve()), row["branch"])
                valid = [s for s in stamps if s is not None and s <= self.now]
                if valid:
                    out[key] = max([out[key]] + valid) if key in out else max(valid)
                started = epoch(row["started_at"]) if "started_at" in fields else None
                if run_status and row["run_status"] in ("running", "fixing", "pending") \
                        and step and "completed_at" in fields and row["completed_at"] is None \
                        and row[step] and started is not None and started <= self.now:
                    previous = self.pipeline_waits.get(key)
                    if previous is None or started > previous[1]:
                        self.pipeline_waits[key] = (row[step], started)
        return out

    def stalled(self, task):
        stamps = [mtime(self.state / (task["id"] + ".status"))]
        worktree = self.task_worktree(task)
        if worktree:
            stamps.append(int(self.git(worktree, "show", "-s", "--format=%ct", "HEAD")))
            # The reflog stamps when a commit was observed, not when it was authored.
            stamps.append(mtime(Path(self.git(worktree, "rev-parse", "--absolute-git-dir")) / "logs/HEAD"))
        if task.get("project") and task.get("branch"):
            runs = self.source("no-mistakes run store " + task["id"], self.pipeline_progress,
                               task["paths"]["worktree"].get("path")) or {}
            stamps.append(runs.get((str(Path(task["project"]).resolve()), task["branch"])))
        since = max((s for s in stamps if s is not None and s <= self.now), default=None)
        if since is not None and self.now - since < self.ages["stalled_worker"]:
            return
        pane = self.run([BIN / "fm-peek.sh", task["id"], "80"])
        signatures = [line.strip() for line in pane.splitlines() if SIGNATURE.search(line)]
        declaration = self.bash('. "$1"; last_status_line "$2"', BIN / "fm-status-event-lib.sh",
                                self.state / (task["id"] + ".status")).strip()
        waits = [line.strip() for line in pane.splitlines()
                 if re.search(r"\b(waiting|awaiting|lint|background job|step)\b", line, re.I)]
        wait = (waits[-1] if waits else declaration)[:150]
        if re.fullmatch(r"(?:harness |agent )?busy[.!]?", declaration.split(":", 1)[-1].strip(), re.I) and not waits:
            wait = ""
        pipeline_key = (str(Path(task["project"]).resolve()), task["branch"]) \
            if task.get("project") and task.get("branch") else None
        active_step = self.pipeline_waits.get(pipeline_key)
        if active_step:
            wait = f"pipeline step {str(active_step[0])[:100]}; step age {self.now - active_step[1]}s"
        age = "unknown age" if since is None else f"{self.now - since}s without progress"
        evidence = f"{wait or 'worker has not recorded its concrete wait'}; {age}"
        declared_at = re.search(r"\[at=([0-9]+)\]", declaration.split(":", 1)[0])
        if declaration and declared_at and int(declared_at[1]) <= self.now:
            evidence += f"; declaration age {self.now - int(declared_at[1])}s"
        if signatures:
            evidence += "; " + signatures[-1][:150]
        self.add("stalled_worker", task["id"], "follow up on the recorded wait and recover the worker", since,
                 owner="worker:" + task["id"], evidence=evidence)

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
        # rev-parse --verify --quiet exits 1 without output only for an absent object; any other failure still raises.
        if not self.run(["git", "-C", worktree, "rev-parse", "--verify", "--quiet", head + "^{commit}"],
                        missing_ok=True).strip():
            raise PrHeadMissing(head)
        uncovered = self.pending_commits(worktree, head)
        if pending is None:
            return uncovered
        uncovered = set(uncovered)
        return [commit for commit in pending if commit in uncovered]

    def pr_head_pending(self, task, worktree, pending, pr):
        """pr_pending, except that a PR head absent from this copy is a note on this task's own row.

        None means PR coverage could not be applied; the caller then judges the task without it. The ledger is
        not degraded: every other source is still read, and the task's own rows say why coverage was skipped.
        """
        try:
            return self.source("PR head " + task["id"], self.pr_pending, worktree, pending, pr)
        except PrHeadMissing as missing:
            self.missing_heads[task["id"]] = str(missing)
            return None

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
            uncovered = self.pr_head_pending(task, worktree, None, pr)
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
            covered = self.pr_head_pending(task, worktree, pending, pr)
            if covered is not None:
                pending = covered
        if not pending:
            return
        oldest = min(int(self.git(worktree, "show", "-s", "--format=%ct", c)) for c in pending)
        title = self.git(worktree, "show", "-s", "--format=%s", pending[-1])
        head = self.missing_heads.get(task["id"])
        coverage = f"; PR head {head[:8]} is not in this copy, so PR coverage was not applied" if head else ""
        self.add("unlanded_commit", task["id"], "land this work through its PR, or obtain the captain's drop",
                 oldest, evidence=f"{len(pending)} commit(s) not on {base}{coverage}; newest: {title}",
                 source=self.source("commit provenance " + task["id"], lambda: dict(
                     self.task_source(task["id"]), kind="commits", worktree=str(Path(worktree).resolve()),
                     head=self.git(worktree, "rev-parse", "HEAD"), commits=fingerprint(pending))))

    def forge(self, path):
        """Pages of one conditional REST read, flattened; fm-gh-rest.sh owns the ETag cache and quota headers."""
        pages = json.loads(self.run([GH_REST, "get", path, "--paginate", "--slurp"]))
        return [row for page in pages for row in (page if isinstance(page, list) else [page])]

    def quota_reset(self):
        try:
            return int(json.loads((self.state / "gh-ratelimit.core.json").read_text())["reset"])
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def pr_state(self, url):
        if url in self.prs:
            return self.prs[url]
        match = GITHUB_PR.fullmatch(url)
        if not match:
            self.add("coverage", "no forge coverage: " + url,
                     "none: this pull request is not on GitHub, so it is outside this ledger's scope",
                     None, evidence="unsupported PR forge: " + url, informational=True)
            self.prs[url] = None
            return None
        pr = self.source("PR state " + url, lambda: self.forge(f"/repos/{match[1]}/pulls/{match[2]}")[0])
        self.prs[url] = pr
        return pr

    def load_ownership(self):
        """PRs this home owns: recorded on its tasks or backlog, or opened from a task's branch."""
        self.owned_urls = {t["pr"]["url"] for t in self.tasks if t["pr"].get("url")}
        for record in self.backlog:
            for link in [record.get("pr_url"), *(record.get("links") or [])]:
                if isinstance(link, str) and GITHUB_PR.fullmatch(link):
                    self.owned_urls.add(link)

    def owns_pr(self, pr):
        head = pr.get("head") or {}
        return pr["html_url"] in self.owned_urls or \
            (((head.get("repo") or {}).get("full_name") or "").casefold(), head.get("ref")) in self.owned_branches

    def repo_slugs(self):
        paths = {t["project"] for t in self.tasks if t.get("project")}
        if not self.lane:  # a lane's shared clones are not its obligations; only the main home surveys them
            if (self.home / ".git").exists():
                paths.add(str(self.home))
            if self.projects_dir.is_dir():
                projects = self.source("projects inventory", lambda: list(self.projects_dir.iterdir())) or []
                paths |= {str(p) for p in projects if (p / ".git").exists()}
        slugs = set()
        for url in self.owned_urls:
            match = GITHUB_PR.fullmatch(url)
            if match:
                slugs.add(match[1])
        for task in self.tasks:
            url = task["pr"].get("url")
            if not url:
                continue
            match = GITHUB_PR.fullmatch(url)
            if match:
                slugs.add(match[1])
            else:
                self.pr_state(url)
        for path in sorted(paths):
            origin = self.source("project origin " + path, self.repo_origin, path)
            if not origin:
                continue
            match = GITHUB_ORIGIN.fullmatch(origin)
            if match:
                slugs.add(match[1])
                self.owned_branches.update((match[1].casefold(), t["branch"]) for t in self.tasks
                                           if t.get("project") == path and t.get("branch"))
            elif is_local_origin(origin):  # a local path has no forge to read
                self.add("coverage", "no forge coverage: " + Path(path).name,
                         "none: this project's origin is a local path, so it has no forge pull requests to collect",
                         None, evidence=f"{path}: local origin {origin}", informational=True)
            else:
                self.add("coverage", "no forge coverage: " + Path(path).name,
                         "none: this project's origin is not GitHub, so its pull requests are outside this ledger's scope",
                         None, evidence=f"{path}: unsupported non-GitHub origin {origin}", informational=True)
        return sorted(slugs)

    def repo_origin(self, path):
        self.git(path, "rev-parse", "--git-dir")
        return self.run(["git", "-C", path, "config", "--get", "remote.origin.url"], missing_ok=True).strip()

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

    def review_pass(self, slug, url, sha, task):
        for lane in self.review_lanes.get(slug.casefold(), []):
            if task and lane == task["id"]:
                continue  # a worker's own PASS is not an independent review
            path = self.state / (lane + ".status")
            if not path.exists():
                continue
            if path.is_symlink():
                raise ValueError("review lane status must not be a symbolic link")
            events = self.bash('. "$1"; while IFS= read -r line || [ -n "$line" ]; do '
                               'if _fm_status_line_is_event "$line" "$FM_CLASSIFY_CAPTAIN_RE_DEFAULT"; '
                               'then printf "%s\\n" "$line"; fi; done < <(fm_status_window_cat "$2")',
                               BIN / "fm-status-event-lib.sh", path)
            # Exact URL tokens, not prefix matches on PR numbers.
            lines = [line for line in events.splitlines()
                     if any(match[0] == url for match in GITHUB_PR.finditer(line))]
            if not lines:
                continue
            line = lines[-1]
            if not re.search(r"\bPASS\b", line) or re.search(r"\b(?:FAIL|REJECTED)\b", line):
                continue
            if not re.search(r"(?<![0-9a-f])" + re.escape(sha) + r"(?![0-9a-f])", line):
                continue
            stamp = re.search(r"\[at=([0-9]+)\]", line.split(":", 1)[0])
            if not stamp or int(stamp[1]) > self.now:
                continue
            return int(stamp[1]), lane
        return None

    def required_checks_green(self, slug, pr, checks, statuses):
        base = pr["base"]["ref"]
        key = (slug, base)
        if key not in self.required:
            from urllib.parse import quote
            branch = quote(base, safe="")
            summary = self.forge(f"/repos/{slug}/branches/{branch}")[0]
            requirements = []
            if summary["protected"]:
                protection = summary["protection"]["required_status_checks"]
                requirements += [(r["context"], r.get("app_id")) for r in protection.get("checks", [])]
                requirements += [(context, None) for context in protection.get("contexts", [])]
            for rule in self.forge(f"/repos/{slug}/rules/branches/{branch}"):
                if rule["type"] == "required_status_checks":
                    requirements += [(r["context"], r.get("integration_id"))
                                     for r in rule["parameters"]["required_status_checks"]]
            self.required[key] = [(name, None if app == -1 else app) for name, app in requirements]
        # Match app-bound requirements to the actual producer; missing checks never count as green.
        # A commit status names no producing app, so only a matching check run satisfies an app binding.
        for name, app in self.required[key]:
            runs = [c for c in checks if c.get("name") == name and
                    (app is None or c.get("app", {}).get("id") == app)]
            contexts = [s for s in statuses if s.get("context") == name] if app is None else []
            if not runs and not contexts:
                return False
            if any(c.get("status") != "completed" or c.get("conclusion") not in
                   ("success", "neutral", "skipped") for c in runs):
                return False
            if any(s.get("state") != "success" for s in contexts):
                return False
        return True

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
        review = self.review_pass(slug, url, sha, task)
        green = not pending and all(c.get("conclusion") in ("success", "neutral", "skipped") for c in checks) \
            and all(s.get("state") == "success" for s in statuses)
        if review and green and not pr.get("draft") and self.required_checks_green(slug, pr, checks, statuses):
            finished = [epoch(c.get("completed_at")) for c in checks] \
                + [epoch(s.get("updated_at") or s.get("created_at")) for s in statuses]
            since = max([review[0]] + [stamp for stamp in finished if stamp is not None])
            self.add("review_pass_not_merged", url, "merge with existing authority or escalate for approval", since,
                     evidence=f"independent review PASS by {review[1]} at live head {sha}; required checks green")
            return
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
        task_id = task["id"] if task else next((r["id"] for r in self.backlog
                    if url == r.get("pr_url") or url in (r.get("links") or [])), None)
        source = self.source("PR provenance " + url, self.task_source, task_id) if task_id else self.source_context()
        self.add("open_pr", url, action, epoch(pr.get("updated_at")), owner,
                 source=dict(source, kind="pr", url=url, head=sha) if source is not None else None)

    def pr_rows(self, slug):
        pulls = self.forge(f"/repos/{slug}/pulls?state=open&per_page=100")
        for pr in pulls:
            url = pr["html_url"]
            if not GITHUB_PR.fullmatch(url):
                self.pr_state(url)
                continue
            self.prs[url] = pr
            if self.owns_pr(pr):
                self.source(f"PR {slug}#{pr.get('number', '?')}", self.pr_row, slug, pr)

    def source_context(self):
        return {name: str(path.resolve()) for name, path in
                (("home", self.home), ("state", self.state), ("data", self.data), ("config", self.config))}

    def task_source(self, task):
        source = dict(self.source_context(), task=task)
        meta = self.state / (task + ".meta")
        if meta.is_symlink():
            raise ValueError(f"task metadata {meta.name} must not be a symbolic link")
        source["generation"] = fingerprint(meta.read_text()) if meta.exists() else None
        return source

    def decision_source(self, task, key, decision, observed_pr=None):
        path = self.state / (task + ".status")
        if path.is_symlink() or not path.is_file():
            raise ValueError("decision status must be a regular file")
        stat = path.stat()
        source = dict(self.task_source(task), kind="status", key=key, decision=fingerprint(decision),
                      stream=[stat.st_dev, stat.st_ino])
        if observed_pr is None:
            assigned = next((t for t in self.tasks if t["id"] == task), {})
            pr = self.prs.get(assigned.get("pr", {}).get("url"))
            if pr and pr.get("head", {}).get("sha"):
                observed_pr = dict(url=pr["html_url"], head=pr["head"]["sha"])
        if observed_pr is not None:
            source["pr"] = observed_pr
        return source

    def hold_source(self, record):
        # The canonical backlog projection, not hold-reason prose, owns eligibility.
        return dict(self.source_context(), kind="captain_hold", task=record["id"],
                    decision=fingerprint({key: record.get(key) for key in
                        ("id", "state", "hold_kind", "hold_bucket", "hold_set", "hold_reason",
                         "hold_until", "unresolved_blocker_ids", "body_lines")}))

    def question_rows(self):
        for record in self.backlog:
            if record.get("hold_kind") == "captain" and record.get("hold_bucket") in ("live", "aged"):
                self.add("unanswered_question", record["id"] + ":captain-hold",
                         "resolve the captain hold or record its next decision date",
                         epoch(record.get("hold_set") or record.get("since")), owner="captain",
                         evidence=record.get("hold_reason") or record.get("title") or "",
                         source=self.hold_source(record))
        for status in (p for p in self.state_files if p.name.endswith(".status")):
            if status.is_symlink():
                continue
            try:
                out = self.bash('[ -r "$2" ] || exit 1; '
                                '. "$1/fm-status-decision-lib.sh"; status_open_decisions_dated "$2"', BIN, status)
            except SOURCE_ERRORS as error:
                self.degraded.append(f"questions {status.name}: {str(error)[:120]}")
                continue
            for line in out.splitlines():
                key, verb, opened, summary = (line.split("\t", 3) + ["", "", "", ""])[:4]
                self.add("unanswered_question", f"{status.stem}:{key}",
                         "answer or close this question, or record why it no longer applies",
                         int(opened) if opened.isdigit() else None, evidence=f"{verb}: {summary}",
                         source=self.source("question provenance " + status.name,
                                            self.decision_source, status.stem, key, line))

    def board_answer_rows(self):
        inbox = self.state / "procevent-inbox"
        try:
            results = sorted(inbox.iterdir())
        except FileNotFoundError:
            return
        for result in results:
            if result.suffix != ".result" or result.is_symlink() or not result.is_file():
                continue
            handled = result.with_suffix(".handled")
            if handled.exists() or handled.is_symlink():
                continue
            adapter_file = result.with_suffix(".adapter")
            if not adapter_file.is_file() or adapter_file.is_symlink():
                continue
            adapter = self.source("board answer adapter " + result.name, adapter_file.read_text)
            if adapter is None or adapter.strip() != "lavish":
                continue
            owner_file = result.with_suffix(".owner-task")
            task = None
            if owner_file.is_file() and not owner_file.is_symlink():
                task = self.source("board answer owner " + result.name, owner_file.read_text)
            owner_task = task.strip() if task and task.strip() else ""
            if self.owner_working(owner_task):
                self.add("unhandled_board_answer", result.name,
                         f"informational: live working owner task {owner_task} holds this board round",
                         mtime(result), owner="worker:" + owner_task, evidence=result, informational=True)
                continue
            self.add("unhandled_board_answer", result.name,
                     f"read and route the captured board answer {result}; owner task: "
                     + (owner_task or "unknown (no owner task recorded)"),
                     mtime(result), evidence=result)

    @staticmethod
    def spawn_gen(path):
        """The last spawn_gen= value, as bin/fm-wake-lib.sh's fm_teardown_return_pending reads it."""
        value = ""
        for line in path.read_text().splitlines():
            if line.startswith("spawn_gen="):
                value = line[len("spawn_gen="):]
        return value

    def interrupted_teardown_rows(self):
        """A teardown that closed a pool task but has not returned its slot leaves a record naming that task."""
        for marker in self.state_files:
            if not marker.name.endswith(".teardown-return-pending") or marker.is_symlink() or not marker.is_file():
                continue
            task_id = marker.name[:-len(".teardown-return-pending")]
            meta = self.state / (task_id + ".meta")
            if meta.is_symlink() or not meta.is_file():
                continue
            if self.spawn_gen(marker) != self.spawn_gen(meta):
                continue
            fields = dict(line.split("=", 1) for line in marker.read_text().splitlines() if "=" in line)
            child = f" for child {fields['child']}" if fields.get("child") else ""
            self.add("interrupted_teardown", task_id,
                     f"re-run bin/fm-teardown.sh {task_id} to finish returning its pool slot{child}; "
                     "its processes and endpoint may already be closed",
                     mtime(marker), evidence=fields.get("slot", ""))

    def owner_working(self, owner_task):
        """A board round held by a live, working owner task is the worker's to finish, not an overdue answer."""
        task = next((t for t in self.tasks if t["id"] == owner_task), None)
        if task is None or task["current_state"].get("state") != "working":
            return False
        try:
            return self.liveness(task) == "alive"
        except SOURCE_ERRORS:
            return False

    # -- run -------------------------------------------------------------------------------------

    def collect(self):
        self.source("state inventory", self.read_state_inventory)
        self.source("fleet snapshot", self.read_snapshot)
        self.source("backlog", self.backlog_rows)
        self.source("ownership", self.load_ownership)
        slugs = self.source("project origins", self.repo_slugs) or []
        for slug in slugs:
            self.source("open PRs " + slug, self.pr_rows, slug)
        self.source("workers", self.worker_rows)
        self.source("report silence", self.silent_reports)
        self.source("questions", self.question_rows)
        self.source("board answers", self.board_answer_rows)
        self.source("interrupted teardowns", self.interrupted_teardown_rows)
        if self.degraded:
            self.add("coverage", "ledger degraded", "restore the unreadable sources and rerun the reconciler",
                     None, evidence="; ".join(self.degraded))

    def hold_last(self, reason):
        """Quota is below the floor: keep the last published rows, each marked stale, and say when it resets."""
        self.stale_reason = reason
        self.rows = {}
        self.degraded = []
        previous = None
        try:
            target = self.state / "open-loops.json"
            if not target.is_symlink():
                previous = json.loads(target.read_text())
            if not (isinstance(previous, dict) and previous.get("schema") == "fm-open-loops.v1"
                    and isinstance(previous.get("rows"), list) and isinstance(previous.get("generated_epoch"), int)):
                previous = None
        except (OSError, ValueError):
            previous = None
        if previous is None:  # nothing to hold: say so rather than read as "nothing owed"
            self.degraded.append(reason)
            self.add("coverage", "ledger degraded", "restore the unreadable sources and rerun the reconciler",
                     None, evidence=reason)
            return
        self.stale_generated = previous["generated_epoch"]
        for row in previous["rows"]:
            if isinstance(row, dict) and isinstance(row.get("id"), str) and row.get("subject") != "ledger stale":
                self.rows[row["id"]] = dict(row, stale=True)
        self.add("coverage", "ledger stale", "wait for the GitHub quota window to reset; the next run refreshes every row",
                 None, evidence=reason, informational=True)

    def result(self):
        rows = sorted(self.rows.values(), key=lambda r: (r["category"], r["subject"]))
        report = dict(schema="fm-open-loops.v1", generated_epoch=self.stale_generated or self.now,
                      home=str(self.home), complete=not self.degraded and not self.stale_reason,
                      rows=rows)
        if self.stale_reason:
            report.update(stale=True, stale_reason=self.stale_reason,
                          stale_until_epoch=self.quota_reset())
        return report

    def publish(self):
        self.state.mkdir(parents=True, exist_ok=True)
        lock_fd = os.open(self.state / ".open-loops.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.lockf(lock_fd, fcntl.LOCK_EX, 1, 1)
            return self.publish_locked()
        finally:
            os.close(lock_fd)

    def publish_locked(self):
        target = self.state / "open-loops.json"
        if target.is_symlink():
            raise ValueError("open-loop ledger must not be a symbolic link")
        report = self.result()
        try:
            previous = read_ledger(self.state)
        except (OSError, ValueError):  # an unreadable ledger has no handling to keep; this publication replaces it
            previous = None
        if previous and "handling" in previous:
            handling = report["handling"] = previous["handling"]
            if not report["complete"]:
                current = {row["id"] for row in report["rows"]}
                presented = {ident for actor in handling["presentations"].values() for ident in actor}
                for row in previous["rows"]:
                    # Unconfirmed either way: shown stale, never an overdue obligation needing a receipt.
                    seen = row.get("last_seen", previous["generated_epoch"])
                    if row["id"] in presented and row["id"] not in current and self.now - seen < DAY_SECONDS:
                        retained = dict(row, stale=True, overdue=False, informational=True, last_seen=seen)
                        if retained.get("age_seconds") is not None:
                            retained["age_seconds"] += max(0, self.now - previous["generated_epoch"])
                        report["rows"].append(retained)
            published = {row["id"] for row in report["rows"]}
            handling["actions"] = {ident: action for ident, action in handling["actions"].items()
                                   if ident in published}
            handling["presentations"] = {actor: {ident: sequence for ident, sequence in pending.items()
                                                 if ident in published}
                                         for actor, pending in handling["presentations"].items()}
            handling["presented_at"] = {actor: {ident: stamp for ident, stamp in stamps.items() if ident in published}
                                        for actor, stamps in handling.get("presented_at", {}).items()}
            for row in report["rows"]:
                if handling["actions"].get(row["id"], {}).get("captain_visible"):
                    row["captain_visible"] = True
        write_ledger(self.state, report)
        try:
            (self.state / ".open-loops-stale-surfaced").unlink()
        except FileNotFoundError:
            pass
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


def read_ledger(state):
    path = state / "open-loops.json"
    if path.is_symlink():
        raise ValueError("open-loop ledger must not be a symbolic link")
    if not path.exists():
        return None
    report = json.loads(path.read_text())
    handling = report.get("handling", {}) if isinstance(report, dict) else None
    if not isinstance(report, dict) or report.get("schema") != "fm-open-loops.v1" \
            or type(report.get("generated_epoch")) is not int or not isinstance(report.get("rows"), list) \
            or any(not isinstance(row, dict) or not isinstance(row.get("id"), str) for row in report["rows"]) \
            or not isinstance(handling, dict) or handling and (
                type(handling.get("sequence")) is not int
                or not isinstance(handling.get("actions"), dict) or not isinstance(handling.get("presentations"), dict)
                or not isinstance(handling.get("presented_at", {}), dict)
                or any(not isinstance(v, dict) for v in handling.get("presented_at", {}).values())
                or any(not isinstance(v, dict) for v in [*handling["actions"].values(),
                                                         *handling["presentations"].values()])):
        raise ValueError("unsupported open-loop ledger")
    return report


def write_ledger(state, report, receipt=False):
    target = state / "open-loops.json"
    if target.is_symlink():
        raise ValueError("open-loop ledger must not be a symbolic link")
    publication = target.stat() if receipt else None
    fd, temp = tempfile.mkstemp(prefix=".open-loops-", dir=state)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(report, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if publication is not None:
            # The watcher dates reconciler freshness from the heartbeat's mtime;
            # recording an action must not conceal a stopped collector.
            os.utime(temp, ns=(publication.st_atime_ns, publication.st_mtime_ns))
        os.replace(temp, target)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def overdue_rows(report, now):
    rows = []
    for original in report.get("rows", []):
        row = dict(original)
        age = row.get("age_seconds")
        if age is not None:
            row["age_seconds"] = age + max(0, now - report["generated_epoch"])
        if not row.get("informational") and (age is None or row["age_seconds"] >= row["limit_seconds"]):
            rows.append(row)
    return rows


def row_digest(row):
    # Preserve the original escalation/deferral receipt identity. A waiting receipt
    # separately compares its full collected source and authoritative dependency.
    fields = [row.get(f) for f in ("category", "subject", "owner", "next_action", "evidence")]
    return hashlib.sha256(json.dumps(fields).encode()).hexdigest()[:24]


def parkable(row):
    """A firstmate-owned row a captain decision can park: the only rows an escalation may bind to a hold."""
    return row.get("category") in CAPTAIN_PARKABLE and row.get("owner") == "firstmate"


class WaitVerifier:
    """Verify explicit per-obligation dependencies against this home's existing source owners."""
    def __init__(self, report, state, now):
        home = Path(os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or BIN.parent).resolve()
        self.collector = Collector(home, now)
        if self.collector.state.resolve() != state.resolve() or report.get("home") != str(home):
            raise ValueError("waiting requires a current ledger collected for the effective home and state directory")
        self.stale = bool(report.get("stale"))
        self.rows = {row["id"]: row for row in report["rows"]}
        self.actions = report.get("handling", {}).get("actions", {})
        self.backlog = None
        self.backlog_error = None
        self.decisions = {}

    def backlog_records(self):
        """This home's canonical backlog records, read once, or the first read's error when it is unavailable."""
        if self.backlog_error is not None:
            raise self.backlog_error
        if self.backlog is None:
            try:
                snapshot = json.loads(self.collector.run([BIN / "fm-fleet-snapshot.sh", "--contribution-input"]))
                if not snapshot["backlog"].get("present"):
                    raise ValueError("prerequisite backlog is unavailable")
                self.backlog = snapshot["backlog"]["records"]
            except SOURCE_ERRORS as error:
                self.backlog_error = error
                raise
        return self.backlog

    def captain_hold(self, task, buckets=("live", "aged")):
        """The canonical backlog record of a task still held for the captain, or ValueError."""
        record = next((r for r in self.backlog_records() if r.get("structured") and r["id"] == task
                       and r.get("hold_kind") == "captain" and r.get("hold_bucket") in buckets), None)
        if record is None:
            raise ValueError("captain prerequisite was answered, released, or is no longer actionable")
        return record

    def hold_marker(self, task):
        """Identity of one hold lifecycle: a re-hold restamps it, while a note, aging or a deferral date does not."""
        record = self.captain_hold(task, ("live", "aged", "dated"))
        return str(record.get("hold_set") or record.get("since") or "")

    def named_hold(self, row, explicit):
        """The one captain hold an escalation of this row waits on, as a {task, marker} record, or None.

        An explicit --hold must be held for the captain. Otherwise the first of the row's key (a keyed
        question's captain-held task id), its legacy <task>-decision-<key> task and its own task that
        is held binds; an unreadable backlog raises instead of naming none.
        """
        if explicit:
            return dict(task=explicit, marker=self.hold_marker(explicit))
        source = row.get("source") if isinstance(row.get("source"), dict) else {}
        subject = str(row.get("subject", ""))
        task = source.get("task") or (subject.split(":", 1)[0] if row.get("category") == "unanswered_question" else "")
        key = source.get("key") or (subject.split(":", 1)[1] if ":" in subject else "")
        names = [name for name in (key, f"{task}-decision-{key}" if task and key else "", task) if name]
        if names:
            self.backlog_records()
        for name in names:
            try:
                return dict(task=name, marker=self.hold_marker(name))
            except SOURCE_ERRORS:
                continue
        return None

    def hold_stands(self, action, row):
        """An escalation bound to a captain hold stands until the row changes or that hold ends.

        Only the local backlog and the row's own digest decide it, so a quota-stale ledger does not end it.
        """
        hold = action.get("hold")
        if not parkable(row) or action.get("digest") != row_digest(row) or not isinstance(hold, dict):
            return False
        try:
            return self.hold_marker(hold["task"]) == hold["marker"]
        except SOURCE_ERRORS:
            return False  # an answered, released, blocked, or unreadable hold restores the action requirement

    def current_source(self, source):
        c = self.collector
        if not isinstance(source, dict) or any(source.get(k) != v for k, v in c.source_context().items()):
            raise ValueError("waiting source does not belong to the effective home")
        task = source.get("task")
        if task is not None and not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", task):
            raise ValueError("invalid prerequisite task identity")
        kind = source.get("kind")
        if kind == "captain_hold":
            return c.hold_source(self.captain_hold(task))
        if not task:
            raise ValueError("waiting source has no task identity; recollect before binding it")
        if kind == "status":
            if task not in self.decisions:
                path = c.state / (task + ".status")
                if path.is_symlink() or not path.is_file():
                    raise ValueError("prerequisite status is unavailable")
                self.decisions[task] = c.bash('. "$1/fm-status-decision-lib.sh"; '
                    'status_open_decisions_dated "$2"', BIN, path).splitlines()
            decision = next((line for line in self.decisions[task]
                             if line.split("\t", 1)[0] == source.get("key")), None)
            if decision is None:
                raise ValueError("prerequisite decision is no longer open")
            # PR identity is the collector's latest forge observation; full source
            # comparisons invalidate a changed head on publication, while this read rechecks the live local key.
            return c.decision_source(task, source["key"], decision, source.get("pr"))
        if kind in ("pr", "commits"):
            current = dict(source, **c.task_source(task))
            if kind == "commits":
                current["head"] = c.git(source["worktree"], "rev-parse", "HEAD")
            return current
        if kind == "task":
            meta = c.state / (task + ".meta")
            current = c.task_source(task)
            fields = c.read_fields(meta)
            if fields.get("kind") not in ("ship", "scout") or not fields.get("spawn_gen"):
                raise ValueError("prerequisite must be an assigned ship or scout with a launch generation")
            path = c.state / (task + ".status")
            if path.is_symlink() or not path.is_file():
                raise ValueError("prerequisite status is unavailable")
            status = c.bash('. "$1/fm-classify-lib.sh"; export FM_CREW_STATE_NO_FORGE=1; '
                            'if crew_is_provably_working "$3"; then last_status_line "$2"; fi',
                            BIN, path, task).strip()
            if not status:
                raise ValueError("routed prerequisite is no longer working; follow up on its result or wait")
            stat = path.stat()
            return dict(current, kind="task", status=fingerprint(status), stream=[stat.st_dev, stat.st_ino])
        raise ValueError("unsupported waiting source; recollect before binding it")

    def verify_source(self, source):
        if isinstance(source, dict) and source.get("kind") != "captain_hold" and not source.get("generation"):
            raise ValueError("waiting requires existing task metadata; recollect after assignment")
        if self.current_source(source) != source:
            raise ValueError("prerequisite identity or evidence changed")

    def binding(self, row, prerequisite, task, evidence, boundary):
        if self.stale:
            raise ValueError("waiting requires a current ledger; this one is held stale until the quota window resets")
        if row["category"] not in CAPTAIN_PARKABLE \
                or row.get("stale") or row.get("owner") == "captain":
            raise ValueError("this obligation cannot have a standing dependency wait")
        source = row.get("source")
        self.verify_source(source)
        if source.get("key", "").startswith(("pending-reply-", "remote-reply-continuity-")):
            raise ValueError("unanswered correlated replies cannot have a standing wait")
        if prerequisite:
            dependency = self.rows.get(prerequisite)
            if dependency is None or prerequisite == row["id"] or dependency.get("stale") \
                    or dependency.get("informational") or dependency["category"] != "unanswered_question" \
                    or self.actions.get(prerequisite, {}).get("kind") == "waiting":
                raise ValueError("prerequisite must be a distinct current unanswered question, not another wait")
            dep_source = dependency.get("source", {})
            if dep_source.get("key", "").startswith(("pending-reply-", "remote-reply-continuity-")):
                raise ValueError("an unanswered correlated reply is not a standing-wait prerequisite")
            if dep_source.get("task") != source.get("task"):
                raise ValueError("cross-task dependencies require a new explicitly routed task delivery")
            self.verify_source(dep_source)
            return dict(source=source, prerequisite=prerequisite, dependency=dep_source,
                        digest=row_digest(dependency))
        if not task or task == source.get("task") or not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", task):
            raise ValueError("waiting requires a distinct assigned prerequisite task")
        c = self.collector
        dep_source = self.current_source(dict(c.source_context(), kind="task", task=task))
        proof_row = dict(owner="worker:" + task, subject=task)
        inbox = c.state / (task + ".inbox")
        if inbox.is_symlink() or (inbox / "handled").is_symlink():
            raise ValueError("prerequisite delivery namespace must not be redirected")
        sent = steer_record_epoch(c.state, proof_row, evidence)
        if sent is None or sent < boundary:
            raise ValueError("waiting requires a new prerequisite-task delivery after presentation")
        proof = next((p for p in (inbox / evidence, inbox / "handled" / evidence) if p.is_file()), None)
        if proof is None or proof.is_symlink():
            raise ValueError("waiting delivery is unavailable")
        text = proof.read_text()
        if "open-loop-row: " + row["id"] not in text.split("\n--\n", 1)[-1].splitlines():
            raise ValueError("prerequisite delivery must explicitly name open-loop-row: " + row["id"])
        return dict(source=source, dependency=dep_source, delivery=evidence, proof=fingerprint(text))

    def stands(self, action, row, now):
        if self.stale or row.get("stale") or action.get("recheck_epoch", 0) <= now \
                or action.get("digest") != row_digest(row):
            return False
        try:
            binding = action["binding"]
            if binding["source"] != row.get("source"):
                return False
            self.verify_source(binding["source"])
            self.verify_source(binding["dependency"])
            prerequisite = binding.get("prerequisite")
            if prerequisite:
                dependency = self.rows.get(prerequisite)
                return bool(dependency and not dependency.get("stale") and not dependency.get("informational")
                            and self.actions.get(prerequisite, {}).get("kind") != "waiting"
                            and dependency.get("source") == binding["dependency"]
                            and binding["digest"] == row_digest(dependency))
            task, record = binding["dependency"]["task"], binding["delivery"]
            inbox = self.collector.state / (task + ".inbox")
            if not re.fullmatch(r"[0-9]+[.]msg", record) or inbox.is_symlink() \
                    or (inbox / "handled").is_symlink():
                return False
            proof = next((p for p in (inbox / record, inbox / "handled" / record)
                          if p.is_file() and not p.is_symlink()), None)
            return proof is not None and fingerprint(proof.read_text()) == binding["proof"]
        except (KeyError, *SOURCE_ERRORS):
            return False  # unreadable or changed evidence never buys standing acknowledgement


def receipt_stands(action, row, now, waits=None):
    """A standing receipt also answers later turns; any other receipt answers only the turn it followed."""
    kind = action.get("kind")
    if row.get("category") == "review_pass_not_merged":
        return False
    if kind == "waiting":
        return waits is not None and waits.stands(action, row, now)
    if kind == "deferred":
        return action.get("recheck_epoch", 0) > now and not action.get("captain_visible")
    if kind == "escalated" and row.get("owner") == "captain":
        return action.get("digest") == row_digest(row)  # only the captain can move it; stands until the row changes
    if kind == "escalated":
        # A firstmate-owned row parked behind a live captain hold waits on the same single mover.
        return waits is not None and waits.hold_stands(action, row)
    return False


def steer_record_epoch(state, row, record):
    """When the row's task steering inbox (bin/fm-task-inbox-lib.sh) recorded this delivery, or None."""
    if not re.fullmatch(r"[0-9]+[.]msg", record):
        return None
    owner = str(row.get("owner", ""))
    source = row.get("source") if isinstance(row.get("source"), dict) else {}
    tasks = [str(source.get("task", ""))]
    if owner.startswith("worker:"):
        tasks.append(owner[len("worker:"):])
    tasks.append(str(row.get("subject", "")).split(":", 1)[0])
    for task in tasks:
        if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", task):
            continue
        inbox = state / (task + ".inbox")
        for path in (inbox / record, inbox / "handled" / record):
            if path.is_file() and not path.is_symlink():
                header = path.read_text(errors="replace").split("\n--\n", 1)[0].splitlines()
                return next((epoch(line[3:]) for line in header if line.startswith("at=")), None)
    return None


def merge_recorded(state, row, url):
    """The row's own PR has a merge recorded by bin/fm-merge-outcome-lib.sh (fm-pr-poll-merge-notified-v1)."""
    match = GITHUB_PR.fullmatch(url)
    if not match or url != row.get("subject"):
        return False
    expected = ["fm-pr-poll-merge-notified-v1", "github", "github.com", match[1], match[2]]
    return any(marker.is_file() and not marker.is_symlink() and marker.read_text().splitlines() == expected
               for marker in state.glob("*.pr-poll-merge-notified"))


def render_overdue(rows):
    fields = ["id", "owner", "subject", "next_action", "age_seconds", "evidence", "captain_visible"]
    lines = ["OVERDUE:", f"rows[{len(rows)}]{{{','.join(fields)}}}:"]
    lines += ["  " + ",".join(json.dumps(r.get(f), ensure_ascii=False) for f in fields) for r in rows]
    return "\n".join(lines)


def ledger_action(args, state, now):
    """Receipts and per-actor presentations share the ledger's short publication lock range."""
    try:
        report = read_ledger(state)
    except (OSError, ValueError) as error:
        if args.command == "action" or args.report:
            raise
        print(f"error: open-loops ledger unreadable ({str(error)[:120]}); this drain is not gated on overdue rows."
              f" Repair: rm {state / 'open-loops.json'} (the next heartbeat rebuilds it)", file=sys.stderr)
        return 0
    if report is None:
        if args.command == "action":
            raise ValueError("no published ledger; run bin/fm-open-loops.sh --heartbeat first")
        return 0
    if args.present_overdue and not overdue_rows(report, now):
        return 0
    controls = report.setdefault("handling", dict(sequence=0, presentations={}, presented_at={}, actions={}))
    stamps = controls.setdefault("presented_at", {})
    actor = os.environ.get("FM_SUPERVISION_ACTOR") or "main"
    if actor not in ("main", "branch"):
        raise ValueError("unknown supervision actor")
    rows = overdue_rows(report, now)
    by_id = {r["id"]: r for r in rows}
    actions = controls["actions"]
    waits, waits_error = None, ""
    recorded = getattr(args, "kind", None)
    pending_waits = any(a.get("kind") == "waiting" or a.get("hold") for a in actions.values())
    parks = recorded == "escalated" and getattr(args, "row_id", None) in by_id and parkable(by_id[args.row_id])
    if recorded == "waiting" or pending_waits or parks:
        try:
            waits = WaitVerifier(report, state, now)
        except SOURCE_ERRORS as error:
            if recorded == "waiting":
                raise
            waits_error = str(error)[:120]
            if pending_waits:
                print(f"error: standing evidence unavailable ({waits_error}); its obligations need follow-up",
                      file=sys.stderr)
    for row in rows:
        row["captain_visible"] = bool(actions.get(row["id"], {}).get("captain_visible"))
    pending = controls["presentations"].setdefault(actor, {})
    if args.present_overdue:
        needing, standing = [], []
        for row in rows:
            ident = row["id"]
            action = actions.get(ident, {})
            if receipt_stands(action, row, now, waits):
                standing.append(row)
                continue
            needing.append(row)
            if ident not in pending or action.get("sequence", 0) > pending[ident]:
                pending[ident] = controls["sequence"]
                stamps.setdefault(actor, {})[ident] = now
        write_ledger(state, report, receipt=True)
        if needing:
            print(render_overdue(needing))
            if standing:
                print(render_overdue(standing).replace("OVERDUE:", "STANDING (a receipt stands; no action needed):", 1))
            print("help: Run bin/fm-open-loops.sh action <id> <steered|merged|escalated|deferred|waiting>"
                  " --evidence <delivery-id|PR-URL|escalation|reason> [--recheck <UTC-time>]"
                  " [--prerequisite <row-id> | --prerequisite-task <task-id>]"
                  " [--hold <captain-held-task-id>]")
        return 0
    if args.check_actions:
        missing = [row for ident, row in by_id.items()
                   if (ident in pending and (actions.get(ident, {}).get("sequence", 0) <= pending[ident]
                       or (actions.get(ident, {}).get("kind") == "deferred"
                           and actions[ident].get("recheck_epoch", 0) <= now)))
                   or (actions.get(ident, {}).get("kind") == "waiting"
                       and not receipt_stands(actions[ident], row, now, waits))]
        if missing:
            print("error: overdue rows have no action recorded since presentation; acknowledgement refused")
            print(render_overdue(missing))
            return 1
        return 0
    if args.report:
        print(f"generated_epoch: {report['generated_epoch']}")
        print("complete: " + str(report.get("complete", False)).lower())
        print(render_overdue(rows) if rows else "OVERDUE: none")
        return 0
    if args.row_id not in by_id:
        raise ValueError("row is not currently overdue in the published ledger")
    ident = args.row_id
    if not any(ident in presented for presented in controls["presentations"].values()):
        raise ValueError("row has not been presented; run bin/fm-wake-drain.sh first")
    old = actions.get(ident, {})
    if not args.evidence or not args.evidence.strip():
        raise ValueError("--evidence is required for every action")
    cited = old.get("cited", [])
    if args.kind == "steered":
        sent = steer_record_epoch(state, by_id[ident], args.evidence)
        if sent is None:
            raise ValueError("steered evidence must be a delivery record name (NNN.msg) in this row's task inbox")
        boundary = stamps.get(actor, {}).get(ident)
        if boundary is None:
            boundary = min((marked[ident] for marked in stamps.values() if ident in marked), default=now)
        if sent < boundary or args.evidence in cited:
            raise ValueError("steered evidence must be a new delivery sent after this row's presentation")
        cited = cited + [args.evidence]
    if args.kind == "merged" and not merge_recorded(state, by_id[ident], args.evidence):
        raise ValueError("merged evidence must be this row's PR URL with its merge recorded by bin/fm-pr-merge.sh")
    recheck = epoch(args.recheck)
    binding = None
    wait_history = old.get("waits", [])
    if args.kind == "waiting":
        if recheck is None or recheck <= now or recheck > now + DAY_SECONDS:
            raise ValueError("waiting requires --recheck at a future UTC time within 24 hours")
        boundary = stamps.get(actor, {}).get(ident)
        if boundary is None:
            boundary = min((marked[ident] for marked in stamps.values() if ident in marked), default=now)
        binding = waits.binding(by_id[ident], args.prerequisite, args.prerequisite_task, args.evidence, boundary)
        if args.prerequisite_task:
            delivery = f"waiting:{args.prerequisite_task}:{args.evidence}"
            if delivery in cited:
                raise ValueError("waiting delivery has already been cited for this obligation")
            cited = cited + [delivery]
        proof = fingerprint(binding)
        if proof in wait_history:
            raise ValueError("unchanged dependency wait cannot be renewed; follow up on its prerequisite")
        wait_history = wait_history + [proof]
    elif args.prerequisite or args.prerequisite_task:
        raise ValueError("prerequisite options are only valid for waiting actions")
    if args.kind == "deferred":
        if old.get("deferrals", 0):
            old["captain_visible"] = True
            actions[ident] = old
            for row in report["rows"]:
                if row["id"] == ident:
                    row["captain_visible"] = True
            # Reopen the requirement even if the first deferral had already cleared this presentation.
            for presented in controls["presentations"].values():
                if ident in presented:
                    presented[ident] = controls["sequence"]
            for marked in stamps.values():
                if ident in marked:
                    marked[ident] = now
            write_ledger(state, report, receipt=True)
            raise ValueError("second deferral refused; row is captain-visible; steer, merge or escalate it")
        if recheck is None or recheck <= now or recheck > now + DAY_SECONDS:
            raise ValueError("deferral requires --recheck at a future UTC time within 24 hours")
    elif args.recheck and args.kind != "waiting":
        raise ValueError("--recheck is only valid for deferred or waiting actions")
    if args.kind == "deferred":
        for marked in stamps.values():
            if ident in marked:
                marked[ident] = now
    hold, parked, unverified = None, False, ""
    if args.hold and args.kind != "escalated":
        raise ValueError("--hold is only valid for escalated actions")
    if args.kind == "escalated" and parkable(by_id[ident]):
        parked = True
        if waits is not None:
            try:
                hold = waits.named_hold(by_id[ident], args.hold)
            except SOURCE_ERRORS as error:
                if args.hold:
                    raise ValueError("--hold must name a task still held for the captain: " + str(error)[:120])
                unverified = str(error)[:120] or "backlog unreadable"
        elif args.hold:
            raise ValueError("--hold needs a current ledger and readable backlog to verify the captain hold")
        else:
            unverified = waits_error or "standing evidence unavailable"
    elif args.hold:
        raise ValueError("only a firstmate-owned open_pr, unanswered_question or unlanded_commit row can wait on a hold")
    controls["sequence"] += 1
    actions[ident] = dict(kind=args.kind, evidence=args.evidence, at_epoch=now,
                         sequence=controls["sequence"], deferrals=old.get("deferrals", 0)
                         + int(args.kind == "deferred"), captain_visible=old.get("captain_visible", False),
                         digest=row_digest(by_id[ident]), cited=cited)
    if wait_history:
        actions[ident]["waits"] = wait_history
    if binding is not None:
        actions[ident]["binding"] = binding
    if hold:
        actions[ident]["hold"] = hold
    if recheck is not None:
        actions[ident]["recheck_epoch"] = recheck
    write_ledger(state, report, receipt=True)
    print("action: " + json.dumps(ident) + "\nkind: " + args.kind)
    if parked:
        if hold:
            print("standing: captain hold " + hold["task"] + "; stands until this row changes"
                  " or that hold is answered or released")
        elif unverified:
            print(f"standing: no; the captain hold could not be verified ({unverified}), so this receipt answers only"
                  " the turn it followed (record it again once the backlog is readable)")
        else:
            print("standing: no; no task held for the captain was named, so this receipt answers only the turn it"
                  " followed (name the hold with --hold TASK_ID)")
    return 0


class CliParser(argparse.ArgumentParser):
    def error(self, message):
        print("error: " + json.dumps(message))
        raise SystemExit(2)


def main():
    parser = CliParser(description="Reconcile assigned work against live reality")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--heartbeat", action="store_true", help="publish state/open-loops.json")
    parser.add_argument("--check-in", metavar="TASK_ID", help="send one inbox check-in for an overdue silent report")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--present-overdue", action="store_true", help="present and require actions before wake acknowledgement")
    modes.add_argument("--check-actions", action="store_true", help="refuse acknowledgement with unactioned presented rows")
    modes.add_argument("--report", action="store_true", help="report all overdue rows with current ages without collecting")
    commands = parser.add_subparsers(dest="command")
    action = commands.add_parser("action", help="record an action on a presented overdue row")
    action.add_argument("row_id")
    action.add_argument("kind", choices=("steered", "merged", "escalated", "deferred", "waiting"))
    action.add_argument("--evidence", required=True, help="delivery id, PR URL, escalation, deferral or dependency reason")
    action.add_argument("--recheck", help="future UTC ISO time (deferred or waiting)")
    action.add_argument("--hold", metavar="TASK_ID",
                        help="task held for the captain that this escalation waits on (escalated only)")
    dependency = action.add_mutually_exclusive_group()
    dependency.add_argument("--prerequisite", help="exact same-task unanswered-question row id (waiting only)")
    dependency.add_argument("--prerequisite-task", help="distinct routed ship or scout task id (waiting only)")
    args = parser.parse_args()
    receipt_mode = args.command == "action" or args.present_overdue or args.check_actions or args.report
    if args.command == "action" and (args.present_overdue or args.check_actions or args.report):
        parser.error("action cannot be combined with presentation, acknowledgement or report modes")
    if receipt_mode and (args.heartbeat or args.json or args.check_in):
        parser.error("receipt and report commands cannot collect or publish a heartbeat")
    if args.check_in and not os.environ.get("FM_HOME"):
        print('error: "FM_HOME is required for a check-in"')
        return 1
    home = Path(os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or BIN.parent).resolve()
    try:
        lock_dir = Path(os.environ.get("FM_STATE_OVERRIDE") or home / "state").resolve()
        lock_dir.mkdir(parents=True, exist_ok=True)
        lock_fd = os.open(lock_dir / ".open-loops.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        now = int(os.environ.get("FM_OPEN_LOOPS_NOW", time.time()))
        if receipt_mode:
            # Byte 0 excludes concurrent collections; byte 1 serializes only
            # atomic publication and receipts on the same existing lock file.
            fcntl.lockf(lock_fd, fcntl.LOCK_EX, 1, 1)
            return ledger_action(args, lock_dir, now)
        try:
            fcntl.lockf(lock_fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if args.heartbeat else 0), 1, 0)
        except (BlockingIOError, PermissionError):
            os.close(lock_fd)
            return 0
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
    except QuotaLow as low:
        collector.hold_last(str(low))
    except (CollectionDeadline, *SOURCE_ERRORS) as error:
        collector.degraded.insert(0, "reconciler: " + str(error)[:160])
        collector.add("coverage", "ledger degraded", "restore the unreadable sources and rerun the reconciler",
                      None, evidence="; ".join(collector.degraded))
    finally:
        signal.alarm(0)
    try:
        if args.check_in:
            if collector.stale_reason:
                raise ValueError("cannot send a check-in from retained stale ledger evidence")
            outcome = collector.check_in(args.check_in)
            print(json.dumps(outcome) if args.json else "\n".join(
                key + ": " + json.dumps(value) for key, value in outcome.items()))
            return 0
        report = collector.publish() if args.heartbeat else collector.result()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("error: " + json.dumps(str(error)))
        return 1
    print(json.dumps(report) if args.json else render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
