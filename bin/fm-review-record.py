#!/usr/bin/env python3
"""Record independent review evidence and explicit captain merge words.

Usage (FM_HOME must name the absolute home holding the PR task record):
  fm-review-record.py review --pr URL --head SHA --verdict PASS|FAIL
    --reader-family FAMILY --author-groups '{"commit-group":["family",...]}'
    --loosens-deny-allow-list yes|no --widens-guard yes|no
    --customer-data-billing-spend yes|no --report PATH
  fm-review-record.py captain-word --pr URL --head SHA --words 'Exact captain merge instruction'
  fm-review-record.py latest --pr URL
  fm-review-record.py verify --pr URL --head SHA

The relay lane writes into the receiving home by setting FM_HOME explicitly.
FM_STATE_OVERRIDE selects its state directory, as in the PR merge/poll helpers.
state/review-records.jsonl uses the friction ledger's locked O_APPEND JSONL shape:
records are never replaced; append order, not wall-clock time, selects the newest
review and captain-word for each canonical PR URL. Reads share the same lock.
Author groups name commit ranges/groups with their author model families; every
family must differ from the reader. Families come from a closed set (anthropic,
openai, deepseek, google; aliases claude, codex, gpt, gemini), match case-
insensitively, and are stored by canonical name; any other family is refused.
verify accepts the newest captain-word when it names the exact live head; it then
stands in for the review and every trigger. Otherwise the newest review must be
PASS at the exact live head with an independent reader, and any yes trigger is
refused. Captain words waive no existing forge/hold guard. captain-word records only
a current explicit captain merge instruction naming the concrete PR, given in the
captain's own turn; away words are never recorded as captain-word.
latest emits the complete newest review and captain-word as JSON for relay reads.
Missing/invalid input exits 2; missing/mismatched evidence or unreadable history
exits 1. Corrupt/partial history is preserved for reconciliation, never repaired.
The report path records provenance; the report need not be on the receiving host.
"""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

BIN = Path(__file__).resolve().parent
TRIGGERS = ("loosens_deny_allow_list", "widens_guard", "customer_data_billing_spend")
FAMILIES = {"anthropic": "anthropic", "openai": "openai", "deepseek": "deepseek", "google": "google",
            "claude": "anthropic", "codex": "openai", "gpt": "openai", "gemini": "google"}


class RecordError(Exception):
    """An actionable invalid field or unavailable record."""


def nonempty(value, field):
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        raise RecordError(f"{field} must be non-empty")
    return value


def family(value):
    if not isinstance(value, str) or value.casefold() not in FAMILIES:
        raise RecordError(f"reader_family/author_groups family must be one of {', '.join(FAMILIES)}")
    return FAMILIES[value.casefold()]


def head_sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value):
        raise RecordError("head must be an exact full commit sha")
    return value


def canonical_pr(url):
    # Reuse the forge parser rather than introduce a second URL grammar.
    result = subprocess.run(["bash", "-c", '. "$1/fm-pr-lib.sh"; fm_pr_url_parse "$2" || exit 1; printf "%s" "$FM_PR_URL"',
                             "fm-review-record", str(BIN), url], capture_output=True, text=True, check=False)
    if result.returncode or not result.stdout:
        raise RecordError("pr must be a parseable canonical PR URL; supply --pr URL")
    return result.stdout


def validate(row):
    if not isinstance(row, dict) or row.get("schema") != "fm-review-record.v1":
        raise RecordError("review record schema is invalid")
    nonempty(row.get("pr"), "pr")
    if type(row.get("at")) is not int or row["at"] < 0:
        raise RecordError("at must be an epoch integer")
    if row.get("kind") not in ("review", "captain-word"):
        raise RecordError("review record kind is invalid")
    head_sha(row.get("head"))
    if row["kind"] == "captain-word":
        nonempty(row.get("words"), "words")
        return
    if row.get("verdict") not in ("PASS", "FAIL"):
        raise RecordError("verdict must be PASS or FAIL")
    if family(row.get("reader_family")) != row["reader_family"]:
        raise RecordError("reader_family must be a canonical family")
    groups = row.get("author_groups")
    if not isinstance(groups, dict) or not groups:
        raise RecordError("author_groups must map each commit group to non-empty author families")
    for group, authors in groups.items():
        nonempty(group, "author_groups commit group")
        if not isinstance(authors, list) or not authors:
            raise RecordError("author_groups must contain non-empty author families for every commit group")
        for author in authors:
            if family(author) != author:
                raise RecordError("author_groups families must be canonical families")
    for trigger in TRIGGERS:
        if row.get(trigger) not in ("yes", "no"):
            raise RecordError(f"{trigger} must be yes or no")
    nonempty(row.get("report"), "report")


@contextlib.contextmanager
def ledger(write):
    home = os.environ.get("FM_HOME", "")
    if not home or not Path(home).is_absolute():
        raise RecordError("FM_HOME must explicitly name the absolute home holding the PR task record")
    if not Path(home).is_dir():
        raise RecordError(f"FM_HOME {home} does not exist; name the existing home holding the PR task record")
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or Path(home) / "state")
    if not state.is_absolute() or state.is_symlink():
        raise RecordError("state directory must be absolute and not a symlink")
    if write:
        state.mkdir(mode=0o700, exist_ok=True)
    flags = os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(state / "review-records.jsonl", flags | (os.O_CREAT if write else 0), 0o600)
    except FileNotFoundError:
        if write:
            raise
        yield None
        return
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise RecordError("review record history must be an ordinary single-link file")
        fcntl.flock(fd, fcntl.LOCK_EX if write else fcntl.LOCK_SH)
        yield fd
    finally:
        os.close(fd)


def newest(fd, pr):
    result = {"review": None, "captain-word": None}
    if fd is None:
        return result
    with os.fdopen(os.dup(fd), "rb") as stream:
        for line in stream:
            if not line.endswith(b"\n"):
                raise RecordError("review record history is incomplete; preserve and reconcile it before retrying")
            try:
                row = json.loads(line)
                validate(row)
            except (ValueError, TypeError, RecordError) as exc:
                raise RecordError(f"review record history is invalid ({exc}); preserve and reconcile it before retrying") from exc
            if row["pr"] == pr:
                result[row["kind"]] = row
    return result


def verify(records, head):
    word = records["captain-word"]
    if word is not None and word["head"] == head:
        return "captain-word"
    review = records["review"]
    if review is None:
        raise RecordError("review record is missing; relay the review with fm-review-record.py review --pr URL, or record explicit captain merge words at the live head with fm-review-record.py captain-word (see --help), then retry the merge")
    if review["verdict"] != "PASS":
        raise RecordError("verdict is FAIL; obtain and record a new PASS with fm-review-record.py review, then retry the merge")
    if review["head"] != head:
        raise RecordError(f"head mismatch: review names {review['head']}, live head is {head}; review the live head and record its PASS with fm-review-record.py review, then retry the merge")
    for group, authors in review["author_groups"].items():
        if review["reader_family"] in authors:
            raise RecordError(f"reader_family {review['reader_family']} matches author_groups {group}; record a PASS from a reader outside every author family with fm-review-record.py review, then retry the merge")
    yes = [trigger for trigger in TRIGGERS if review[trigger] == "yes"]
    if yes:
        raise RecordError(f"{', '.join(yes)} is yes but captain-word is missing at live head {head}; obtain explicit merge approval and record the exact words with fm-review-record.py captain-word --pr URL --head {head} --words WORDS, then retry the merge")
    return "PASS"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("review", "captain-word", "latest", "verify"):
        command = commands.add_parser(name, description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
        command.add_argument("--pr", required=True)
        if name != "latest":
            command.add_argument("--head", required=True)
        if name == "review":
            for flag in ("verdict", "reader-family", "author-groups", "report", *(t.replace("_", "-") for t in TRIGGERS)):
                command.add_argument("--" + flag, required=True)
        if name == "captain-word":
            command.add_argument("--words", required=True)
    args = parser.parse_args()
    try:
        pr = canonical_pr(args.pr)
        row = {"schema": "fm-review-record.v1", "kind": args.command, "pr": pr, "at": int(time.time())}
        if args.command == "review":
            try:
                groups = json.loads(args.author_groups)
            except ValueError as exc:
                raise RecordError("author_groups must be a JSON object of commit groups and family lists") from exc
            if isinstance(groups, dict):
                groups = {group: [family(a) for a in authors] if isinstance(authors, list) else authors
                          for group, authors in groups.items()}
            row.update(head=args.head, verdict=args.verdict, reader_family=family(args.reader_family),
                       author_groups=groups, report=args.report, **{t: getattr(args, t) for t in TRIGGERS})
        elif args.command == "captain-word":
            row.update(head=args.head, words=args.words)
        write = args.command in ("review", "captain-word")
        if write:
            validate(row)
    except RecordError as exc:
        print(f"error: {exc}")
        return 2
    try:
        with ledger(write) as fd:
            records = newest(fd, pr)
            if write:
                data = (json.dumps(row, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")
                if os.write(fd, data) != len(data):
                    raise RecordError("partial review record append; preserve history for reconciliation before retrying")
                os.fsync(fd)
                print(f"recorded: {args.command}")
            elif args.command == "latest":
                print(json.dumps(records, separators=(",", ":")))
            else:
                print(f"review: {verify(records, args.head)}")
    except (RecordError, OSError) as exc:
        print(f"error: {exc}; inspect review-records.jsonl in the PR task home before retrying")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
