#!/usr/bin/env python3
"""Standing GitHub quota and caller observer (no caller control or attribution verdict).

Usage: fm-github-accounting.py {start,run,status,stop,prune,records}
       fm-github-accounting.py run [--duration SECONDS]
       fm-github-accounting.py records [--kind KIND]

State: FM_STATE_OVERRIDE, else <FM_HOME or FM_ROOT_OVERRIDE or code root>/state,
under github-accounting/. Private observations.sqlite holds timestamped JSON
records. Only this database's records strictly older than 48 hours expire,
on startup, every quota tick and prune. Existing unrelated state is untouched.
start detaches one owner, run stays foreground, status reports its lock ownership,
and stop requests that owner's shutdown and awaits release. No launchd agent or
shared service is installed. Repeating start is idempotent. run refuses a second
owner. --duration is an optional observation window, not a request timeout.
A primary home's watcher runs start each cycle (github_accounting_tick in
bin/fm-watch.sh), so a reboot, a crash or a plain stop recovers at its next cycle.
A detached owner's stderr appends to owner.log, which start trims to its newest
bytes before a launch once it passes LOG_LIMIT.
Only run holds owner.lock exclusively, so an exclusive holder is a live owner;
records and prune hold it shared. start, run, records and prune exit BUSY (75)
when the lock they need is unavailable; a busy start started nothing and may
retry, and any other failed start exits 1. A stop during startup exits 1. A second
concurrent reader can exit 1 after the SQLite wait.

Quota source: gh-axi api rate_limit --full, unchanged inherited authentication,
every 15 seconds. Records identify REST resources.graphql, not GraphQL response
headers. This observer intentionally uses the REST counter rather than spending
points on a GraphQL accounting query. REST shard agreement is not established.
A slow request is not overlapped or retried in a burst; pending ticks are recorded.

Process source: one LC_ALL=C ps table every 0.2 seconds in the root home's
watcher context, not a confined worker. run's process_source callable is a test
seam returning {pid: (ppid, start_identity, argv_words)}; the default is ps.
Injected rows prove output behavior, not actual host observations. New gh/gh-axi
PID/start identities retain sanitized argv and the observed ancestor chain. Payloads and
arbitrary argument values are withheld, as in the process census's safe logging
convention. Executable/script basenames, command words and recognized option
names are retained; no environment, headers, prompts or free text is logged.
ps does not preserve argv boundaries, so recorded argv is explicitly a sanitized
command-line projection, not a lossless reconstruction. Missing, unreadable,
short-lived, non-gh and off-host callers remain unknown. Temporal correlation
with a quota interval is not causal proof. Sampling summaries report actual scan
counts/gaps and failures, not an assurance that every requested tick ran on time.
"""
import argparse
from contextlib import contextmanager
import fcntl
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
import uuid

QUOTA_INTERVAL = 15.0
PROCESS_INTERVAL = 0.2
RETENTION = 48 * 60 * 60
APPLICATION_ID = 0x464D4748
LOG_LIMIT = 64 * 1024
BUSY = 75
QUOTA_JQ = '.resources.graphql | "used=\\(.used) reset=\\(.reset) limit=\\(.limit) remaining=\\(.remaining)"'
QUOTA_BODY = re.compile(r'''^  body: ["']?used=(\d+) reset=(\d+) limit=(\d+|null) remaining=(\d+|null)["']?$''', re.MULTILINE)
ROW = re.compile(r"\s*(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d\d:\d\d:\d\d\s+\d{4})\s+(.*)")
COMMANDS = frozenset("api graphql rate_limit pr issue run workflow repo release gist auth view list checks status create edit comment merge close reopen ready checkout diff watch download upload delete search get POST GET PATCH PUT HEAD DELETE".split())
OPTIONS = frozenset("--repo -R --hostname --json --jq --template --field -f -F --header -H --input --body --body-file --title --message -m -c --eval --paginate --include -i --full --state --limit -L --head --base --author --label --help -h --version".split())
INTERPRETERS = frozenset(("bash", "sh", "zsh", "dash", "python", "python3", "node", "ruby", "perl"))


def state_root():
    home = Path(os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", Path(__file__).resolve().parent.parent)))
    return Path(os.environ.get("FM_STATE_OVERRIDE", home / "state")) / "github-accounting"


def private_root():
    root = state_root()
    if root.is_symlink():
        raise RuntimeError("unsafe observer state directory")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    for name in ("owner.lock", "observations.sqlite", "stop", "observations.sqlite-journal"):
        if (root / name).is_symlink():
            raise RuntimeError("unsafe observer state file")
    return root


def open_private(path):
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    os.fchmod(descriptor, 0o600)
    return os.fdopen(descriptor, "r+")


def owner_log(root):
    descriptor = os.open(root / "owner.log", os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    os.fchmod(descriptor, 0o600)
    size = os.fstat(descriptor).st_size
    if size > LOG_LIMIT:
        newest = os.pread(descriptor, LOG_LIMIT // 2, size - LOG_LIMIT // 2)
        os.ftruncate(descriptor, 0)
        os.write(descriptor, newest)
    return descriptor


class OwnerLockHeld(RuntimeError):
    pass


@contextmanager
def ownership(root, mode):
    with open_private(root / "owner.lock") as lock:
        try:
            fcntl.flock(lock, mode | fcntl.LOCK_NB)
        except BlockingIOError:
            raise OwnerLockHeld from None
        yield lock


def database(root):
    path = root / "observations.sqlite"
    existed = path.exists()
    if not existed:
        with open_private(path):
            pass
    db = sqlite3.connect(path)
    if existed and db.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
        db.close()
        raise RuntimeError("refusing database not owned by the observer")
    db.execute("PRAGMA auto_vacuum=FULL")
    db.execute("PRAGMA secure_delete=ON")
    db.execute(f"PRAGMA application_id={APPLICATION_ID}")
    db.execute("CREATE TABLE IF NOT EXISTS observations (observed REAL NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL)")
    db.execute("CREATE INDEX IF NOT EXISTS observations_time ON observations(observed)")
    db.commit()
    return db


def record(db, kind, payload, observed=None):
    stamp = time.time() if observed is None else observed
    payload = dict(payload, observed_at=stamp, kind=kind)
    db.execute("INSERT INTO observations VALUES (?,?,?)", (stamp, kind, json.dumps(payload, sort_keys=True)))


def prune(db, now):
    changed = db.execute("DELETE FROM observations WHERE observed < ?", (now - RETENTION,)).rowcount
    db.commit()
    # auto_vacuum reclaims expired payload pages at commit, without a full
    # database rewrite on the sampler's critical path.
    return changed


def words(command):
    # ps renders a command line, not an argv protocol. Do not interpret shell
    # syntax or treat a quote as proof that a payload can safely be disclosed.
    return command.split()


def executable(argv):
    if not argv:
        return "", None
    name = Path(argv[0]).name
    script = None
    if (name in INTERPRETERS or re.fullmatch(r"python\d+(?:\.\d+)*", name)) and len(argv) > 1 and not argv[1].startswith("-"):
        script = Path(argv[1]).name
    return name, script


def safe_argv(argv):
    """Withhold arbitrary values, including unknown options and shell fragments."""
    name, script = executable(argv)
    if not name:
        return []
    result = [name]
    start = 1
    if script:
        result.append(script)
        start = 2
    command_prefix = (script or name) in ("gh", "gh-axi")
    for word in argv[start:]:
        if command_prefix and word in COMMANDS:
            result.append(word)
            continue
        command_prefix = False
        option = word.split("=", 1)[0]
        if option in OPTIONS:
            result.append(option + ("=[REDACTED]" if "=" in word else ""))
        else:
            result.append("[REDACTED]")
    return result


def process_table():
    reply = subprocess.run(["ps", "-axo", "pid=,ppid=,lstart=,command="],
                           env=dict(os.environ, LC_ALL="C", COLUMNS="100000"),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=True)
    rows = {}
    for line in reply.stdout.splitlines():
        match = ROW.fullmatch(line)
        if match:
            pid, ppid, start, command = match.groups()
            rows[int(pid)] = (int(ppid), " ".join(start.split()), words(command))
    if not rows:
        raise RuntimeError("process table unavailable")
    return rows


def process_records(rows, seen):
    current = set()
    found = []
    for pid, (ppid, start, argv) in rows.items():
        name, script = executable(argv)
        if (script or name) not in ("gh", "gh-axi"):
            continue
        identity = (pid, start)
        current.add(identity)
        if identity in seen:
            continue
        chain, visited, parent = [], {pid}, ppid
        while parent in rows and parent not in visited:
            visited.add(parent)
            ancestor, born, args = rows[parent]
            chain.append({"pid": parent, "ppid": ancestor, "start": born, "argv": safe_argv(args)})
            parent = ancestor
        found.append({"pid": pid, "ppid": ppid, "start": start, "argv": safe_argv(argv),
                      "argv_source": "ps-command-line-projection", "ancestors": chain,
                      "ancestor_end": "root" if parent == 0 else "cycle" if parent in visited else "unobserved"})
    return found, current


def owner_status(root):
    with open_private(root / "owner.lock") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            try:
                lock.seek(0)
                return json.load(lock)
            except (ValueError, OSError):
                return {"state": "starting"}
    return {"state": "stopped"}


def quota_result(db, child, stream, began, run_id):
    stream.seek(0)
    try:
        projection = stream.read(1024 * 1024).decode("utf-8", "replace")
        match = QUOTA_BODY.search(projection)
        if child.returncode or match is None:
            raise ValueError("unavailable")
        fields = {key: int(value) for key, value in zip(("used", "reset", "limit", "remaining"), match.groups())
                  if value != "null"}
        status = "observed"
    except (ValueError, KeyError, TypeError):
        fields, status = {}, "unavailable"
    record(db, "quota", {"run_id": run_id, "status": status, "source": "REST rate_limit resources.graphql",
                         "endpoint": "rate_limit", "host": os.environ.get("GH_HOST", "github.com"),
                         "request_started_at": began, "request_pid": child.pid,
                         "exit_code": child.returncode, "graphql": fields})
    stream.close()


def run(root, duration=None, ready=None, *, process_source=None):
    # Root-home execution uses ps; deterministic callers inject the same table
    # shape without changing filtering, ancestry, identity or storage behavior.
    source = process_table if process_source is None else process_source
    with ownership(root, fcntl.LOCK_EX) as lock:
        lock.truncate(0)
        db = database(root)
        run_id = uuid.uuid4().hex
        metadata = {"state": "running", "pid": os.getpid(), "run_id": run_id, "started_at": time.time()}
        json.dump(metadata, lock)
        lock.flush()
        stopped = False

        def stop_requested(_number, _frame):
            nonlocal stopped
            stopped = True

        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, stop_requested)
        child = stream = None
        seen = set()
        scans = failures = 0
        max_gap = 0.0
        previous = None
        started = next_process = next_quota = time.monotonic()
        try:
            prune(db, time.time())
            record(db, "owner", dict(metadata, action="start", process_interval=PROCESS_INTERVAL, quota_interval=QUOTA_INTERVAL))
            db.commit()
            if ready is not None:
                os.write(ready, b"ready\n")
                os.close(ready)
                ready = None
            while not stopped:
                now = time.monotonic()
                if duration is not None and now - started >= duration:
                    break
                try:
                    if (root / "stop").read_text() == run_id:
                        break
                except FileNotFoundError:
                    pass
                if child is not None and child.poll() is not None:
                    quota_result(db, child, stream, began, run_id)
                    child = stream = None
                    db.commit()
                if now >= next_process:
                    if previous is not None:
                        max_gap = max(max_gap, now - previous)
                    previous = now
                    scans += 1
                    try:
                        found, seen = process_records(source(), seen)
                        for item in found:
                            record(db, "process", dict(item, run_id=run_id))
                    except (OSError, subprocess.SubprocessError, RuntimeError):
                        failures += 1
                    next_process = now + PROCESS_INTERVAL
                    db.commit()
                if now >= next_quota:
                    record(db, "sampling", {"run_id": run_id, "scans": scans, "failures": failures,
                                             "max_gap_seconds": max_gap, "process_interval": PROCESS_INTERVAL})
                    scans = failures = 0
                    max_gap = 0.0
                    prune(db, time.time())
                    if child is None:
                        began = time.time()
                        stream = tempfile.TemporaryFile(dir=root)
                        try:
                            child = subprocess.Popen(["gh-axi", "api", "rate_limit", "--jq", QUOTA_JQ, "--full"],
                                                     stdout=stream, stderr=subprocess.DEVNULL,
                                                     stdin=subprocess.DEVNULL, start_new_session=True)
                        except OSError:
                            stream.close()
                            stream = None
                            record(db, "quota", {"run_id": run_id, "status": "unavailable", "endpoint": "rate_limit",
                                                 "source": "REST rate_limit resources.graphql", "reason": "command_unavailable"})
                    else:
                        record(db, "quota", {"run_id": run_id, "status": "pending", "endpoint": "rate_limit",
                                             "source": "REST rate_limit resources.graphql", "request_pid": child.pid})
                    db.commit()
                    next_quota = time.monotonic() + QUOTA_INTERVAL
                time.sleep(max(0, min(next_process, next_quota) - time.monotonic()))
        finally:
            if ready is not None:
                os.close(ready)
            if child is not None:
                if child.poll() is None:
                    # The unreaped quota child owns a fresh session/group, so
                    # its numeric group cannot be reused by an unrelated caller.
                    os.killpg(child.pid, signal.SIGKILL)
                child.wait()
                stream.close()
            record(db, "sampling", {"run_id": run_id, "scans": scans, "failures": failures,
                                     "max_gap_seconds": max_gap, "process_interval": PROCESS_INTERVAL})
            record(db, "owner", {"run_id": run_id, "action": "stop"})
            db.commit()
            db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("start", "run", "status", "stop", "prune", "records"))
    parser.add_argument("--duration", type=float)
    parser.add_argument("--kind")
    parser.add_argument("--ready-fd", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.duration is not None and (args.command != "run" or not 0 < args.duration < float("inf")):
        parser.error("--duration must be finite, positive and used with run")
    if args.kind is not None and args.command != "records":
        parser.error("--kind is for records")
    os.umask(0o077)
    root = private_root()
    if args.command == "status":
        print(json.dumps(owner_status(root)))
    elif args.command == "run":
        run(root, args.duration, args.ready_fd)
    elif args.command == "start":
        with open_private(root / "start.lock") as starting:
            try:
                fcntl.flock(starting, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise OwnerLockHeld from None
            status = owner_status(root)
            if status["state"] == "starting":
                raise OwnerLockHeld
            if status["state"] != "stopped":
                print(json.dumps(status))
                return
            log = owner_log(root)
            read_fd, write_fd = os.pipe()
            try:
                child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "run", "--ready-fd", str(write_fd)],
                                         pass_fds=(write_fd,), start_new_session=True, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.DEVNULL, stderr=log)
                os.close(write_fd)
                write_fd = None
                if os.read(read_fd, 32) != b"ready\n":
                    if child.wait() == BUSY:
                        raise OwnerLockHeld
                    raise RuntimeError("observer failed to start")
            finally:
                os.close(log)
                os.close(read_fd)
                if write_fd is not None:
                    os.close(write_fd)
            print(json.dumps(owner_status(root)))
    elif args.command == "stop":
        status = owner_status(root)
        if status.get("run_id"):
            with open_private(root / "stop") as marker:
                marker.seek(0)
                marker.truncate()
                marker.write(status["run_id"])
            while owner_status(root).get("run_id") == status["run_id"]:
                time.sleep(PROCESS_INTERVAL)
        elif status["state"] != "stopped":
            raise RuntimeError("owner is starting; retry stop after readiness")
        print(json.dumps({"state": "stopped"}))
    else:
        with ownership(root, fcntl.LOCK_SH):
            db = database(root)
            try:
                if args.command == "prune":
                    print(json.dumps({"removed": prune(db, time.time())}))
                else:
                    query = "SELECT payload FROM observations"
                    parameters = ()
                    if args.kind is not None:
                        query += " WHERE kind=?"
                        parameters = (args.kind,)
                    for row in db.execute(query + " ORDER BY observed,rowid", parameters):
                        print(row[0])
            finally:
                db.close()


if __name__ == "__main__":
    try:
        main()
    except OwnerLockHeld:
        print("fm-github-accounting: busy (owner lock held); retry", file=sys.stderr)
        sys.exit(BUSY)
    except (OSError, RuntimeError, sqlite3.Error):
        # No exception text: command output/path arguments can contain secrets.
        print("fm-github-accounting: operation unavailable (check owner status/state permissions)", file=sys.stderr)
        sys.exit(1)
