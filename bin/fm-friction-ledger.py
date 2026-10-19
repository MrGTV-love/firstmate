#!/usr/bin/env python3
"""Optional fm-friction.v1 telemetry; never a policy engine.

Usage: FM_HOME=/absolute/home python3 bin/fm-friction-ledger.py < event.json
       ... fm-friction-ledger.py refusal GUARD RULE KIND SUBJECT EXIT_KIND TASK REVISION_FILE
       ... fm-friction-ledger.py outcome OUTCOME GUARD KIND SUBJECT TASK
The stdin interface validates a complete event; refusal constructs a blocked event
with hashed subject/task identities and source-file revision, never raw payloads.
FM_FRICTION_OPERATION_ID/EPISODE_ID, when supplied, are used instead of the event id.
outcome appends a follow-up only for the supplied FM_FRICTION_OPERATION_ID, only when
that operation already holds a blocked event for the same guard, task and subject
(an empty SUBJECT means the whole operation), and a terminal outcome only once.
Only explicit FM_HOME selects state/friction.jsonl; overrides and cwd cannot redirect it.
One locked O_APPEND write publishes a bounded line. Duplicate event_id is a no-op.
Lock contention is bounded. A corrupt/partial history is retained, never repaired or
truncated automatically. Diagnose and preserve it for reconciliation before retrying.
All telemetry errors print a payload-free diagnostic and return 0, not a new refusal.
See docs/configuration.md "Friction ledger" for the schema and envelope contract.
"""
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import uuid

MAX_LINE_BYTES = 8192
# Optional telemetry latency budget, not a correctness or guarded-operation timeout.
LOCK_TRIES = 10
LOCK_PAUSE = 0.02
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
OUTCOMES = {"blocked", "worked-around", "bypassed", "retried", "retry-succeeded", "completed", "abandoned", "escalated"}
TERMINAL = {"retry-succeeded", "completed", "abandoned"}
FIELDS = {"schema", "event_id", "at", "guard_id", "rule_id", "guard_revision", "task_id", "actor", "execution_kind", "subject", "attempt_id", "operation_id", "episode_id", "outcome", "reason", "exit_printed", "exit_kind", "proof_digest", "theater", "new_information", "first_block_at", "elapsed_ms", "adjudication"}


class LedgerError(Exception):
    """Payload-free diagnostic suitable for stderr."""


def digest(value):
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()


def timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z", value):
        raise LedgerError("invalid UTC timestamp")
    try:
        dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise LedgerError("invalid UTC timestamp") from exc


def validate(event):
    if not isinstance(event, dict) or set(event) != FIELDS or event["schema"] != "fm-friction.v1":
        raise LedgerError("invalid schema or fields")
    for field in ("event_id", "guard_id", "rule_id", "actor", "attempt_id", "operation_id", "episode_id", "reason", "new_information"):
        if not isinstance(event[field], str) or not TOKEN.fullmatch(event[field]):
            raise LedgerError("invalid typed identifier")
    for field in ("guard_revision", "task_id", "proof_digest"):
        if not isinstance(event[field], str) or not (DIGEST.fullmatch(event[field]) or event[field] == "unknown"):
            raise LedgerError("expected digest or unknown")
    timestamp(event["at"])
    if event["first_block_at"] is not None:
        timestamp(event["first_block_at"])
    subject = event["subject"]
    if not isinstance(subject, dict) or set(subject) != {"kind", "identity", "head"}:
        raise LedgerError("invalid subject")
    if not isinstance(subject["kind"], str) or not TOKEN.fullmatch(subject["kind"]):
        raise LedgerError("invalid subject kind")
    for field in ("identity", "head"):
        if not isinstance(subject[field], str) or not (DIGEST.fullmatch(subject[field]) or subject[field] == "unknown"):
            raise LedgerError("subject must contain digests only")
    enums = {"outcome": OUTCOMES, "execution_kind": {"live", "test"}, "exit_kind": {"machine", "human-only", "none"}, "theater": {"yes", "no", "unknown"}, "adjudication": {"legitimate-false-block", "harm-caught", "policy-changed", "unknown"}}
    for field, choices in enums.items():
        if event[field] not in choices:
            raise LedgerError("invalid event category")
    if type(event["exit_printed"]) is not bool or event["exit_printed"] != (event["exit_kind"] != "none"):
        raise LedgerError("inconsistent exit category")
    elapsed = event["elapsed_ms"]
    if elapsed is not None and (type(elapsed) is not int or elapsed < 0):
        raise LedgerError("invalid elapsed measurement")
    data = (json.dumps(event, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")
    if len(data) > MAX_LINE_BYTES:
        raise LedgerError("event exceeds ledger bound")
    return data


def utc_stamp(moment):
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def refusal(args):
    if len(args) != 7:
        raise LedgerError("usage: refusal GUARD RULE KIND SUBJECT EXIT_KIND TASK REVISION_FILE")
    guard, rule, kind, subject, exit_kind, task, revision_file = args
    now = utc_stamp(dt.datetime.now(dt.timezone.utc))
    event_id = os.environ.get("FM_FRICTION_EVENT_ID") or str(uuid.uuid4())
    attempt = os.environ.get("FM_FRICTION_ATTEMPT_ID") or event_id
    operation = os.environ.get("FM_FRICTION_OPERATION_ID") or attempt
    return {"schema": "fm-friction.v1", "event_id": event_id, "at": now,
            "guard_id": guard, "rule_id": rule, "guard_revision": digest(Path(revision_file).read_text()),
            "task_id": digest(task) if task else "unknown", "actor": os.environ.get("FM_FRICTION_ACTOR", "unknown"),
            "execution_kind": os.environ.get("FM_FRICTION_EXECUTION_KIND", "live"),
            "subject": {"kind": kind, "identity": digest(subject), "head": "unknown"},
            "attempt_id": attempt, "operation_id": operation,
            "episode_id": os.environ.get("FM_FRICTION_EPISODE_ID") or operation,
            "outcome": "blocked", "reason": rule, "exit_printed": exit_kind != "none", "exit_kind": exit_kind,
            "proof_digest": "unknown", "theater": "unknown", "new_information": "unknown",
            "first_block_at": now, "elapsed_ms": None, "adjudication": "unknown"}


def outcome(args):
    """Return a function building the follow-up event from history, or None when nothing correlates."""
    if len(args) != 5:
        raise LedgerError("usage: outcome OUTCOME GUARD KIND SUBJECT TASK")
    name, guard, kind, subject, task = args
    if name not in OUTCOMES - {"blocked"}:
        raise LedgerError("invalid event category")
    operation = os.environ.get("FM_FRICTION_OPERATION_ID")
    if not operation:
        return None
    identity = digest(subject) if subject else None
    task_id = digest(task) if task else "unknown"

    def derive(rows):
        same = [row for row in rows
                if (row["operation_id"], row["guard_id"], row["task_id"], row["subject"]["kind"]) == (operation, guard, task_id, kind)
                and identity in (None, row["subject"]["identity"])]
        blocked = [row for row in same if row["outcome"] == "blocked"]
        if not blocked or (name in TERMINAL and any(row["outcome"] == name for row in same)):
            return None
        first, last = blocked[0], blocked[-1]
        moment = dt.datetime.now(dt.timezone.utc)
        elapsed = None
        if name in TERMINAL and first["first_block_at"] is not None:
            began = dt.datetime.fromisoformat(first["first_block_at"][:-1] + "+00:00")
            elapsed = max(0, int((moment - began).total_seconds() * 1000))
        event_id = str(uuid.uuid4())
        return {"schema": "fm-friction.v1", "event_id": event_id, "at": utc_stamp(moment),
                "guard_id": guard, "rule_id": last["rule_id"], "guard_revision": last["guard_revision"],
                "task_id": task_id, "actor": os.environ.get("FM_FRICTION_ACTOR", "unknown"),
                "execution_kind": last["execution_kind"], "subject": last["subject"],
                "attempt_id": event_id, "operation_id": operation, "episode_id": last["episode_id"],
                "outcome": name, "reason": last["reason"], "exit_printed": last["exit_printed"],
                "exit_kind": last["exit_kind"], "proof_digest": "unknown", "theater": "unknown",
                "new_information": "unknown", "first_block_at": first["first_block_at"],
                "elapsed_ms": elapsed, "adjudication": "unknown"}

    return derive


def append_event(event=None, derive=None):
    """Validate and append once, or recognize an already published event id.

    With derive, the event is built from the validated history under the same lock.
    """
    data = validate(event) if event is not None else None
    home = os.environ.get("FM_HOME", "")
    if not home or not Path(home).is_absolute():
        raise LedgerError("explicit absolute FM_HOME required; no event recorded")
    state = Path(home) / "state"
    if state.is_symlink():
        raise LedgerError("state directory is a symlink; no event recorded")
    state.mkdir(mode=0o700, exist_ok=True)
    fd = os.open(state / "friction.jsonl", os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise LedgerError("ledger is not an ordinary single-link file")
        for attempt in range(LOCK_TRIES):
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if attempt + 1 == LOCK_TRIES:
                    raise LedgerError("ledger busy; preserve event identity and retry telemetry later") from None
                time.sleep(LOCK_PAUSE)
        duplicate = False
        rows = []
        with os.fdopen(os.dup(fd), "rb") as ledger:
            while True:
                line = ledger.readline(MAX_LINE_BYTES + 1)
                if not line:
                    break
                if len(line) > MAX_LINE_BYTES or not line.endswith(b"\n"):
                    raise LedgerError("incomplete ledger history; preserve it for reconciliation before retrying")
                try:
                    old = json.loads(line)
                    validate(old)
                except (LedgerError, ValueError, TypeError, KeyError) as exc:
                    raise LedgerError("invalid ledger history; preserve it for reconciliation before retrying") from exc
                if derive is None:
                    duplicate |= old["event_id"] == event["event_id"]
                else:
                    rows.append(old)
        if derive is not None:
            event = derive(rows)
            if event is None:
                return
            data = validate(event)
        elif duplicate:
            return
        # Do not retry a short/failed append: it may already have published bytes.
        if os.write(fd, data) != len(data):
            raise LedgerError("partial append; preserve ledger for reconciliation before retrying")
    finally:
        os.close(fd)


def main(argv=None):
    event = derive = None
    try:
        args = sys.argv[1:] if argv is None else argv
        if args == ["--help"]:
            print(__doc__)
            return 0
        if args and args[0] == "refusal":
            event = refusal(args[1:])
        elif args and args[0] == "outcome":
            derive = outcome(args[1:])
            if derive is None:
                return 0
        elif not args:
            raw = sys.stdin.buffer.read(MAX_LINE_BYTES + 1)
            if len(raw) > MAX_LINE_BYTES:
                raise LedgerError("event exceeds ledger bound")
            event = json.loads(raw)
        else:
            raise LedgerError("usage: fm-friction-ledger.py [refusal ...|outcome ...]")
        append_event(event, derive)
    except (LedgerError, OSError, ValueError, TypeError, KeyError) as exc:
        # Never echo exception text from the OS/JSON parser: it may contain input.
        message = str(exc) if isinstance(exc, LedgerError) else "telemetry unavailable; preserve event identity and retry telemetry later"
        identity = event.get("event_id") if isinstance(event, dict) else None
        generated = args and args[0] == "refusal" and not os.environ.get("FM_FRICTION_EVENT_ID")
        identity_note = f" event_id={identity};" if generated and isinstance(identity, str) and TOKEN.fullmatch(identity) else ""
        print("fm-friction: " + message + ";" + identity_note + " guarded result unchanged", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
