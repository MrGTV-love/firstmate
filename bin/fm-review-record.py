#!/usr/bin/env python3
"""Record independent review evidence and explicit captain merge words.

Usage (FM_HOME must name the absolute home holding the PR task record):
  fm-review-record.py review --pr URL --head SHA --verdict PASS|FAIL
    --reader-model MODEL --author-groups '{"commit-group":["model",...]}'
    --loosens-deny-allow-list yes|no --widens-guard yes|no
    --customer-data-billing-spend yes|no --report PATH
    [--covered-groups '["ship"]']
  fm-review-record.py captain-word --pr URL --head SHA --words 'Exact captain merge instruction'
  fm-review-record.py latest --pr URL
  fm-review-record.py verify --pr URL --head SHA --task TASK --base BASE_SHA

The relay lane stages the reader report on the receiving host before recording
into the receiving home by setting FM_HOME explicitly.
FM_STATE_OVERRIDE selects its state directory, as in the PR merge/poll helpers.
state/review-records.jsonl uses the friction ledger's locked O_APPEND JSONL shape:
records are never replaced; append order, not wall-clock time, selects the newest
review and captain-word for each canonical PR URL. Reads share the same lock.
verify derives authors anew from the exact head's commits outside the merge base,
with replacement objects disabled. fm-pr-merge.sh supplies --base as the live
forge's exact full 40- or 64-hex base SHA, never a stale local target ref. verify requires
--task selecting state/<task>.meta and --base; fetch the exact base and full head
locally first. Non-pipeline commits form group ship, using the current meta,
any state/<task>.control-relaunch.meta-prior, and every model in the
append-only state/<task>.launch-models history reached from the current meta's
spawn_gen through prior links, so a reused task id never inherits an earlier
incarnation. fm-spawn.sh owns history publication. Legacy tasks without
history use the available meta evidence; default stays unknown. Subjects
starting exactly no-mistakes( form no-mistakes:<family> groups. Their models
come from matching runs and agent_invocations in <NM_HOME>/state.sqlite
(default ~/.no-mistakes), opened with SQLite mode=ro; a relative NM_HOME is
never resolved and leaves the pipeline commits unknown. A matching run must
contain the pipeline commit in its recorded base-to-head/pushed range and name
this PR or this task's repository and branch. All its invocation models are conservative author evidence. A recorded provider
can resolve an otherwise unknown model alias; conflicting provider/model families
are unknown. Unattributed commits remain unknown: today's agent configuration
cannot prove who authored an earlier commit. It never creates a database.
review records only the reader's declaration, not an attribution snapshot;
verify always rereads authoritative evidence, including for historical records.
A typed model id exactly matching a model derived for that same named group
takes its derived family; any other typed unknown-family id, including one
under all, stays unknown.
--author-groups remains a required declaration of exact author models, not an
authority to remove or relabel derived groups. Named declarations must include the
derived family; an all declaration must include every derived family. Additional
typed named groups add constraints to that group; typed all families outside the
derived ones form group declared:all, the one owner of those extra constraints. --covered-groups is a JSON list naming only
the groups the reader actually read, or ["all"]; omitted, author-groups keys name
the covered groups. Historical records use those same keys. A PASS covers one
author family of a group only when it names that group or all, declares its
derived authors, and its known reader family differs from that author family.
Every author family of every group, ship and no-mistakes alike, needs at least
one such exact-head PASS. Unknown is never covered. Multiple reads can
collectively cover a group; one reader outside every family is not required.
This tests the harm directly: every author's blind spots must receive an
independent read, without forcing a third family for mixed-family work.
Exact-head binding, report validation, captain-word/away rules and every live
forge/hold check remain mandatory.
Model families are rederived from ids into anthropic, openai, google, deepseek,
xai, moonshot, meta (aliases claude, gpt, chatgpt, codex, oN, gemini, gemma, grok,
kimi, llama); route prefixes ending in / are dropped. Stored typed family fields
never decide independence. Uncovered-group refusals name each uncovered family,
reporting any group with an unknown author family before known-family groups.
For known families they print a review recording command; substitute the actual
reader, local report and trigger answers. A PASS never covers unknown, so an
unknown-family refusal instead asks for repaired author evidence or prints the
exact-head captain-word command, whose words must be the captain's actual fresh
instruction. When every group is covered but the newest reader is unknown, the
refusal names that reader and prints a known-family reread command.
verify accepts the newest captain-word only at the exact live head, unless a FAIL
at that head was appended after it. Any exact-head FAIL blocks regardless of later
PASS reads until fresh exact-head captain words are recorded. Reviews of other
heads do not clear it. Without captain words, the newest review must also name the
live head and have a known reader family. Trigger answers remain required, recorded
and printed by latest, but yes answers alone do not require captain words.
Captain words waive no existing forge/hold guard. The caller records as captain-word only a
current explicit captain merge instruction naming the concrete PR, given in the
captain's own turn. captain-word itself refuses (exit 2) while the state directory
holds an away-posture record (fm_afk_contract_away_present in fm-afk-contract.sh),
so away words are never recorded as captain-word and the captain gives the word
after return; a quiet record does not refuse, because the captain is present, and
a captain-word recorded before /afk stays valid.
latest emits the complete newest review and captain-word as JSON for relay reads.
Missing/invalid input exits 2; missing/mismatched evidence or unreadable history
exits 1. Corrupt/partial history is preserved for reconciliation, never repaired.
review requires --report to name a regular, non-symlink, readable local file whose
first line is exactly VERDICT: <PASS|FAIL> head=<head>, matching --verdict and --head.
It records the report path and whole-file report_sha256 at record time; verification
uses the recorded evidence, so later report changes do not rewrite history.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import stat
import subprocess
import sys
import time

BIN = Path(__file__).resolve().parent
TRIGGERS = ("loosens_deny_allow_list", "widens_guard", "customer_data_billing_spend")
FAMILIES = {"anthropic": "anthropic", "claude": "anthropic",
            "openai": "openai", "gpt": "openai", "chatgpt": "openai", "codex": "openai",
            "google": "google", "gemini": "google", "gemma": "google",
            "deepseek": "deepseek", "xai": "xai", "grok": "xai",
            "moonshot": "moonshot", "kimi": "moonshot", "meta": "meta", "llama": "meta"}
RECORDED_FAMILIES = set(FAMILIES.values()) | {"unknown"}


class RecordError(Exception):
    """An actionable invalid field or unavailable record."""


def nonempty(value, field):
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        raise RecordError(f"{field} must be non-empty")
    return value


def model(value, field):
    if not isinstance(value, str) or not re.fullmatch(r"[^\s\x00]+", value):
        raise RecordError(f"{field} must be an exact model id")
    name = re.match(r"([a-z]*)(\d*)", value.casefold().rsplit("/", 1)[-1])
    if name.group(1) == "o" and name.group(2):
        return "openai"
    return FAMILIES.get(name.group(1), "unknown")


def modelled(value, field):
    return {"model": value, "family": model(value, field)}


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
    model(row.get("reader_model"), "reader_model")
    if row.get("reader_family") not in RECORDED_FAMILIES:
        raise RecordError("reader_family must be a known family or unknown")
    groups = row.get("author_groups")
    if not isinstance(groups, dict) or not groups:
        raise RecordError("author_groups must map each commit group to non-empty author models")
    for group, authors in groups.items():
        nonempty(group, "author_groups commit group")
        if not isinstance(authors, list) or not authors:
            raise RecordError("author_groups must contain non-empty author models for every commit group")
        for author in authors:
            if not isinstance(author, dict):
                raise RecordError("author_groups must list author model records")
            model(author.get("model"), "author_groups model")
            if author.get("family") not in RECORDED_FAMILIES:
                raise RecordError("author_groups family must be a known family or unknown")
    if "covered_groups" in row:
        covered = row["covered_groups"]
        if not isinstance(covered, list) or not covered or any(not isinstance(g, str) or not g.strip() for g in covered):
            raise RecordError("covered_groups must be a non-empty list of commit groups read")
    for trigger in TRIGGERS:
        if row.get(trigger) not in ("yes", "no"):
            raise RecordError(f"{trigger} must be yes or no")
    nonempty(row.get("report"), "report")


def report_digest(path, verdict, head):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise RecordError("report must be a regular, non-symlink, readable file on the recording host")
            first = stream.readline()
            if first.removesuffix(b"\n") != f"VERDICT: {verdict} head={head}".encode("ascii"):
                raise RecordError("report first line must be exactly VERDICT: <PASS|FAIL> head=<head> matching --verdict and --head")
            digest = hashlib.sha256(first)
            for block in iter(lambda: stream.read(65536), b""):
                digest.update(block)
            return digest.hexdigest()
    except OSError as exc:
        raise RecordError("report must be a regular, non-symlink, readable file on the recording host; stage it locally before recording") from exc


def task_home():
    home = os.environ.get("FM_HOME", "")
    if not home or not Path(home).is_absolute():
        raise RecordError("FM_HOME must explicitly name the absolute home holding the PR task record")
    if not Path(home).is_dir():
        raise RecordError(f"FM_HOME {home} does not exist; name the existing home holding the PR task record")
    return Path(home)


def state_dir(home):
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or home / "state")
    if not state.is_absolute() or state.is_symlink():
        raise RecordError("state directory must be absolute and not a symlink")
    return state


def refuse_away(state):
    result = subprocess.run(["bash", "-c", '. "$1/fm-afk-contract.sh" || exit 2; fm_afk_contract_away_present "$2" || exit 1',
                             "fm-review-record", str(BIN), str(state)], capture_output=True, text=True, check=False)
    if result.returncode == 0:
        raise RecordError(f"captain-word refused: the away-posture record {state / '.afk-contract'} exists, so the captain is away and away words are never captain words; the captain must give the merge word after return")
    if result.returncode != 1:
        raise RecordError(f"captain-word refused: the away-posture record under {state} could not be read")


@contextlib.contextmanager
def ledger(write, home):
    state = state_dir(home)
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
    rows = []
    if fd is None:
        return result, rows
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
                rows.append(row)
    return result, rows


def git(worktree, *args):
    result = subprocess.run(["git", "-C", str(worktree), *args], capture_output=True,
                            text=True, check=False, env={**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"})
    if result.returncode:
        raise RecordError(f"cannot read author commit evidence: git {' '.join(args)} in {worktree}")
    return result.stdout.strip()


def task_metadata(home, task):
    state = state_dir(home)
    valid = subprocess.run(["bash", "-c", '. "$1/fm-pr-lib.sh"; fm_pr_task_id_valid "$2"',
                            "fm-review-record", str(BIN), task], capture_output=True, check=False)
    if valid.returncode:
        raise RecordError("task must be a supported path-safe task id, not a path")
    path = state / f"{task}.meta"
    try:
        fields = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
    except (OSError, UnicodeError) as exc:
        raise RecordError(f"cannot read task metadata {path}") from exc
    return task, fields


def derived_authors(home, pr, head, task, base):
    task, meta = task_metadata(home, task)
    worktree = Path(nonempty(meta.get("worktree"), "task worktree"))
    # The merge helper already binds the forge head; independently require the
    # actual objects and base locally, rather than trusting a typed commit list.
    try:
        git(worktree, "cat-file", "-e", f"{head}^{{commit}}")
        base_ref = git(worktree, "rev-parse", "--verify", f"{base}^{{commit}}")
    except RecordError as exc:
        fetch = shlex.join(["git", "-C", str(worktree), "fetch", "origin", base, head])
        raise RecordError(f"{exc}; fetch the exact forge base and head with: {fetch}, then retry the merge") from exc
    base_sha = git(worktree, "merge-base", head, base_ref)
    commits = [line.split("\x00", 1) for line in git(worktree, "log", "--format=%H%x00%s", f"{base_sha}..{head}").splitlines()]
    if not commits:
        raise RecordError("author commit group is empty; fetch the PR base and exact head before recording a read")
    groups = {}
    if any(not subject.startswith("no-mistakes(") for _, subject in commits):
        models = [meta.get("model") or "unknown"]
        state = state_dir(home)
        history = state / f"{task}.launch-models"
        prior = state / f"{task}.control-relaunch.meta-prior"
        try:
            if history.exists():
                entries = [line.split("\t") for line in history.read_text(encoding="utf-8").splitlines()]
                pending, seen = [meta.get("spawn_gen")], set()
                while pending:
                    gen = pending.pop()
                    if not gen or gen in seen:
                        continue
                    seen.add(gen)
                    for fields in entries:
                        if len(fields) == 3 and fields[0] == gen:
                            models.append(fields[2] or "unknown")
                            pending.append(fields[1])
            if prior.exists():
                fields = dict(line.split("=", 1) for line in prior.read_text(encoding="utf-8").splitlines() if "=" in line)
                models.append(fields.get("model") or "unknown")
        except (OSError, UnicodeError) as exc:
            raise RecordError(f"cannot read ship launch-model evidence for {task}") from exc
        groups["ship"] = [modelled(value or "unknown", "ship model") for value in sorted(set(models))]
    pipeline = [sha for sha, subject in commits if subject.startswith("no-mistakes(")]
    if pipeline:
        root = Path(os.environ.get("NM_HOME") or Path.home() / ".no-mistakes")
        models = []
        covered = set()
        try:
            if not root.is_absolute():
                raise OSError(f"relative NM_HOME {root} is not author evidence")
            with contextlib.closing(sqlite3.connect(root.resolve().as_uri() + "/state.sqlite?mode=ro", uri=True)) as db:
                runs = db.execute("SELECT id, base_sha, head_sha, last_pushed_sha FROM runs WHERE pr_url = ? "
                                  "OR (branch = ? AND repo_id IN (SELECT id FROM repos WHERE working_path IN (?, ?)))",
                                  (pr, meta.get("branch", ""), str(worktree), meta.get("project", ""))).fetchall()
                for run_id, run_base, run_head, pushed in runs:
                    run_commits = set()
                    for tip in (run_head, pushed):
                        if not tip or not run_base:
                            continue
                        try:
                            run_commits.update(git(worktree, "rev-list", f"{run_base}..{tip}").splitlines())
                        except RecordError:
                            continue
                    owned = set(pipeline) & run_commits
                    if not owned:
                        continue
                    invocations = db.execute("SELECT agent, model, model_provider FROM agent_invocations WHERE run_id = ?", (run_id,)).fetchall()
                    if not invocations:
                        continue
                    covered.update(owned)
                    for agent, exact_model, provider in invocations:
                        item = modelled(exact_model or "unknown", "pipeline model")
                        # Only fresh database evidence supplies a provider; typed
                        # declarations and historical family fields never do.
                        if provider in RECORDED_FAMILIES - {"unknown"}:
                            if item["family"] == "unknown":
                                item["family"] = provider
                            elif item["family"] != provider:
                                item["family"] = "unknown"
                        item.update(agent=agent, evidence_provider=provider)
                        models.append(item)
        except (sqlite3.Error, OSError):
            covered.clear()
            models.clear()
        if set(pipeline) - covered:
            models.append(modelled("unknown", "pipeline model"))
        for item in {(item["model"], item["family"]): item for item in models}.values():
            groups.setdefault(f"no-mistakes:{item['family']}", []).append(item)
    return task, groups


def verify(records, rows, head, home, pr, task, base):
    word = records["captain-word"]
    review = records["review"]
    if word is not None and word["head"] == head:
        last_word = max(i for i, row in enumerate(rows) if row["kind"] == "captain-word")
        after_word = rows[last_word + 1:]
    else:
        after_word = rows
    failed = next((row for row in reversed(after_word) if row["kind"] == "review"
                   and row["head"] == head and row["verdict"] == "FAIL"), None)
    if failed is not None:
        raise RecordError(f"verdict is FAIL at live head {head} (reader {failed['reader_model']}, report {failed['report']}); a PASS never clears an exact-head FAIL; record fresh captain words with fm-review-record.py captain-word --pr {pr} --head {head} --words WORDS, then retry the merge")
    if word is not None and word["head"] == head:
        return "captain-word"
    if review is None:
        raise RecordError("review record is missing; relay the review with fm-review-record.py review --pr URL, or record explicit captain merge words at the live head with fm-review-record.py captain-word (see --help), then retry the merge")
    if review["head"] != head:
        raise RecordError(f"head mismatch: review names {review['head']}, live head is {head}; review the live head and record its PASS with fm-review-record.py review, then retry the merge")
    task, derived = derived_authors(home, pr, head, task, base)
    groups = {group: list(authors) for group, authors in derived.items()}
    derived_families = {a["family"] for authors in derived.values() for a in authors}

    def declared(group, authors):
        # A typed id takes a family from evidence only by exactly matching a
        # model derived for that same group; anything else is read from its id.
        known = {a["model"]: a["family"] for a in derived.get(group, [])}
        return [{"model": a["model"], "family": known[a["model"]] if a["model"] in known
                 else model(a["model"], "author_groups model")} for a in authors]

    unknown_reader = model(review["reader_model"], "reader_model") == "unknown"
    passes = [row for row in rows if row["kind"] == "review" and row["head"] == head and row["verdict"] == "PASS"]
    # Typed groups can only add author constraints, never erase the derived ones.
    for row in passes:
        for group, authors in row["author_groups"].items():
            authors = declared(group, authors)
            if group == "all":
                extras = [a for a in authors if a["family"] not in derived_families]
                if extras:
                    groups.setdefault("declared:all", []).extend(extras)
            else:
                target = groups.setdefault(group, [])
                target.extend(a for a in authors if a not in target)
    env = f"FM_HOME={shlex.quote(str(home))} FM_STATE_OVERRIDE={shlex.quote(str(state_dir(home)))}"

    def review_command(reader, covered):
        models = {key: sorted({a["model"] for a in values}) for key, values in groups.items()}
        return shlex.join([str(BIN / "fm-review-record.py"), "review", "--pr", pr, "--head", head,
                           "--verdict", "PASS", "--reader-model", reader,
                           "--author-groups", json.dumps(models, separators=(",", ":")),
                           "--covered-groups", json.dumps(covered),
                           "--loosens-deny-allow-list", "no", "--widens-guard", "no",
                           "--customer-data-billing-spend", "no", "--report", "LOCAL_READER_REPORT"])

    for group, authors in sorted(groups.items(), key=lambda item: ("unknown" not in {a["family"] for a in item[1]}, item[0])):
        families = {a["family"] for a in authors}
        readers = set()
        for row in passes:
            named = row.get("covered_groups", list(row["author_groups"]))
            key = group if group in row["author_groups"] else "all"
            declared_families = {a["family"] for a in declared(key, row["author_groups"].get(key, []))}
            reader = model(row["reader_model"], "reader_model")
            # An 'all' read is usable only when its typed evidence includes every
            # derived family; the old OpenAI-only declaration cannot hide Claude.
            required = derived_families if "all" in row["author_groups"] else families
            if (group in named or "all" in named) and required <= declared_families and reader != "unknown":
                readers.add(reader)
        # Every author family needs some reading PASS from a different family.
        uncovered = sorted(f for f in families if f == "unknown" or not readers - {f})
        if not uncovered:
            continue
        reason = f"model family unknown for newest reader {review['reader_model']}; " if unknown_reader else ""
        if "unknown" in uncovered:
            captain = shlex.join([str(BIN / "fm-review-record.py"), "captain-word", "--pr", pr, "--head", head,
                                  "--words", "FRESH_CAPTAIN_WORDS"])
            raise RecordError(f"{reason}uncovered commit group {group}, family {','.join(uncovered)}; model family unknown is never covered by a PASS; repair the author evidence so every author model has a known family, or obtain a fresh explicit captain merge instruction for this PR at this exact head and record the captain's actual words (never fabricated ones) in place of FRESH_CAPTAIN_WORDS with: {env} {captain}")
        raise RecordError(f"{reason}uncovered commit group {group}, family {','.join(uncovered)}; each author family needs an exact-head PASS reading this group whose reader_family is known and different from it (model family unknown is never covered); obtain the named read, set its actual trigger answers and local report, then record it with: {env} {review_command('OUTSIDE_FAMILY_MODEL', [group])}")
    if unknown_reader:
        raise RecordError(f"model family unknown for newest reader {review['reader_model']}; every group is covered by known-family reads, but the newest review must name a known reader family; obtain a reread from a known-family reader, set its actual trigger answers and local report, then record it with: {env} {review_command('KNOWN_FAMILY_MODEL', sorted(groups))}")
    return "PASS"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("review", "captain-word", "latest", "verify"):
        command = commands.add_parser(name, description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
        command.add_argument("--pr", required=True)
        if name != "latest":
            command.add_argument("--head", required=True)
        if name == "verify":
            command.add_argument("--task", required=True)
            command.add_argument("--base", required=True)
        if name == "review":
            command.add_argument("--covered-groups", help='JSON list of groups read, or ["all"]; defaults to author-groups keys')
            for flag in ("verdict", "reader-model", "author-groups", "report", *(t.replace("_", "-") for t in TRIGGERS)):
                command.add_argument("--" + flag, required=True)
        if name == "captain-word":
            command.add_argument("--words", required=True)
    args = parser.parse_args()
    try:
        home = task_home()
        if args.command == "verify" and not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", args.base):
            raise RecordError("author evidence requires --base with the forge's exact full base commit SHA (40 or 64 hex)")
        pr = canonical_pr(args.pr)
        row = {"schema": "fm-review-record.v1", "kind": args.command, "pr": pr, "at": int(time.time())}
        if args.command == "review":
            try:
                groups = json.loads(args.author_groups)
            except ValueError as exc:
                raise RecordError("author_groups must be a JSON object of commit groups and model lists") from exc
            if isinstance(groups, dict):
                groups = {group: [modelled(a, "author_groups model") for a in authors] if isinstance(authors, list) else authors
                          for group, authors in groups.items()}
            row.update(head=args.head, verdict=args.verdict, reader_model=args.reader_model,
                       reader_family=model(args.reader_model, "reader_model"), author_groups=groups, report=args.report, **{t: getattr(args, t) for t in TRIGGERS})
            if args.covered_groups:
                try:
                    row["covered_groups"] = json.loads(args.covered_groups)
                except ValueError as exc:
                    raise RecordError("covered_groups must be a JSON list of commit groups read") from exc
        elif args.command == "captain-word":
            row.update(head=args.head, words=args.words)
        write = args.command in ("review", "captain-word")
        if write:
            validate(row)
        if args.command == "review":
            row.setdefault("covered_groups", list(groups))
            if any(g != "all" and g not in groups for g in row["covered_groups"]):
                raise RecordError("covered_groups must name author groups or all")
            row["report_sha256"] = report_digest(args.report, args.verdict, args.head)
        if args.command == "captain-word":
            refuse_away(state_dir(home))
    except RecordError as exc:
        print(f"error: {exc}")
        return 2
    try:
        with ledger(write, home) as fd:
            records, rows = newest(fd, pr)
            if write:
                data = (json.dumps(row, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")
                if os.write(fd, data) != len(data):
                    raise RecordError("partial review record append; preserve history for reconciliation before retrying")
                os.fsync(fd)
                print(f"recorded: {args.command}")
            elif args.command == "latest":
                print(json.dumps(records, separators=(",", ":")))
            else:
                print(f"review: {verify(records, rows, args.head, home, pr, args.task, args.base)}")
    except (RecordError, OSError) as exc:
        print(f"error: {exc}; inspect review-records.jsonl in the PR task home before retrying")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
