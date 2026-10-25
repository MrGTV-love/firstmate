#!/usr/bin/env python3
"""Record independent review evidence and explicit captain merge words.

Usage (FM_HOME must name the absolute home holding the PR task record):
  fm-review-record.py review --pr URL --head SHA --verdict PASS|FAIL
    --reader-model MODEL --author-groups '{"commit-group":["model",...]}'
    --loosens-deny-allow-list yes|no --widens-guard yes|no
    --customer-data-billing-spend yes|no --report PATH
    [--task TASK --base SHA_OR_BRANCH] [--covered-groups '["ship"]']
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
forge's exact base SHA, never a stale local target ref. A manual review snapshot
also accepts a target branch name resolved under refs/remotes/origin/; fetch the
base and full head locally first. --task selects state/<task>.meta; without it the PR
must match exactly one meta pr= record. Non-pipeline commits form group ship,
using that task's recorded model. Subjects starting exactly no-mistakes( form
no-mistakes:<family> groups. Their models come from matching runs and
agent_invocations in <NM_HOME>/state.sqlite (default ~/.no-mistakes), opened with
SQLite mode=ro. A matching run must contain the pipeline commit in its recorded
base-to-head/pushed range and name this PR or this task's repository and branch.
All its invocation models are conservative author evidence. A recorded provider
can resolve an otherwise unknown model alias; conflicting provider/model families
are unknown. Unattributed commits fall back to the configured agent, never to the
ship model. The fallback recognizes simple scalar/inline-list agent settings in
config.yaml and the worktree's .no-mistakes.yaml, and only native claude/codex/grok
identities without model/argument/custom-route overrides; unsupported or unreadable
configuration and unresolved agents remain unknown. It never creates a database.
review optionally accepts --task TASK --base BRANCH to record an author snapshot;
verify always rereads authoritative evidence, including for historical records.
--author-groups remains a required declaration of exact author models, not an
authority to remove or relabel derived groups. Named declarations must include the
derived family; an all declaration must include every derived family. Additional
typed groups/families add constraints. --covered-groups is a JSON list naming only
the groups the reader actually read, or ["all"]; omitted, author-groups keys name
the covered groups. Historical records use those same keys. A PASS can cover a
group only when it names that group or all, declares its derived authors, and its
known reader family is outside that group's known author families. Unknown is
never covered. Multiple exact-head PASS reads can collectively cover every group;
one reader outside every family is no longer required. This tests the harm directly:
every author's blind spots must receive an independent read, without forcing a
third family for mixed-family work. Exact-head binding, report validation,
captain-word/away rules and every live forge/hold check remain mandatory.
Model families are rederived from ids into anthropic, openai, google, deepseek,
xai, moonshot, meta (aliases claude, gpt, chatgpt, codex, oN, gemini, gemma, grok,
kimi, llama); route prefixes ending in / are dropped. Stored typed family fields
never decide independence. Uncovered-group refusals name its family and print a
recording command; substitute the actual reader, local report and trigger answers.
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


def task_metadata(home, pr, task):
    state = state_dir(home)
    if task:
        valid = subprocess.run(["bash", "-c", '. "$1/fm-pr-lib.sh"; fm_pr_task_id_valid "$2"',
                                "fm-review-record", str(BIN), task], capture_output=True, check=False)
        if valid.returncode:
            raise RecordError("task must be a supported path-safe task id, not a path")
    candidates = [state / f"{task}.meta"] if task else sorted(state.glob("*.meta"))
    matches = []
    for path in candidates:
        try:
            fields = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
            if not task and fields.get("pr") != pr:
                continue
            matches.append((path.stem, fields))
        except OSError as exc:
            raise RecordError(f"cannot read task metadata {path}") from exc
    if len(matches) != 1:
        raise RecordError("author evidence needs exactly one PR task; supply --task TASK with its recorded worktree and model")
    return matches[0]


def configured_pipeline_models(root, worktree):
    # Recognize only unambiguous native agents in the simple YAML agent setting.
    # ACP/auto/custom routes and model/argument overrides cannot prove a family.
    # Unsupported YAML is unknown, never guessed from an executable's name.
    value = None
    for path in (root / "config.yaml", worktree / ".no-mistakes.yaml"):
        try:
            lines = path.read_text().splitlines()
        except FileNotFoundError:
            continue
        except OSError:
            return [modelled("unknown", "pipeline agent")]
        if any(re.match(r"^(agent_config|agent_args_override|acp_registry_overrides):", line) for line in lines):
            return [modelled("unknown", "pipeline agent")]
        settings = [line.split(":", 1)[1].split("#", 1)[0].strip()
                    for line in lines if re.match(r"^agent:", line)]
        if settings:
            if len(settings) != 1:
                return [modelled("unknown", "pipeline agent")]
            value = settings[0]
    if value is None:
        return [modelled("unknown", "pipeline agent")]
    agents = value[1:-1].split(",") if value.startswith("[") and value.endswith("]") else [value]
    native = {"claude": "claude", "codex": "codex", "grok": "grok"}
    return [modelled(native.get(agent.strip().strip("\"'"), "unknown"), "pipeline agent") for agent in agents]


def derived_authors(home, pr, head, task, base):
    task, meta = task_metadata(home, pr, task)
    worktree = Path(nonempty(meta.get("worktree"), "task worktree"))
    # The merge helper already binds the forge head; independently require the
    # actual objects and base locally, rather than trusting a typed commit list.
    git(worktree, "cat-file", "-e", f"{head}^{{commit}}")
    if not base:
        raise RecordError("author evidence requires --base with the forge's current target branch")
    base_ref = base if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", base) else f"refs/remotes/origin/{base}"
    base_ref = git(worktree, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
    base_sha = git(worktree, "merge-base", head, base_ref)
    commits = [line.split("\x00", 1) for line in git(worktree, "log", "--format=%H%x00%s", f"{base_sha}..{head}").splitlines()]
    if not commits:
        raise RecordError("author commit group is empty; fetch the PR base and exact head before recording a read")
    groups = {}
    if any(not subject.startswith("no-mistakes(") for _, subject in commits):
        groups["ship"] = [modelled(meta.get("model") or "unknown", "ship model")]
    pipeline = [sha for sha, subject in commits if subject.startswith("no-mistakes(")]
    if pipeline:
        root = Path(os.environ.get("NM_HOME") or Path.home() / ".no-mistakes")
        if not root.is_absolute():
            root = worktree / root
        models = []
        covered = set()
        try:
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
            models.extend(configured_pipeline_models(root, worktree))
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
    task, groups = derived_authors(home, pr, head, task or review.get("task"), base)
    derived_families = {a["family"] for authors in groups.values() for a in authors}
    identities = {}
    for authors in groups.values():
        for author in authors:
            identities.setdefault(author["model"], set()).add(author["family"])

    def identified(author):
        result = modelled(author["model"], "author_groups model")
        known = identities.get(author["model"], set())
        if result["family"] == "unknown" and len(known) == 1:
            result["family"] = next(iter(known))
        return result

    unknown_reader = model(review["reader_model"], "reader_model") == "unknown"
    passes = [row for row in rows if row["kind"] == "review" and row["head"] == head and row["verdict"] == "PASS"]
    # Typed groups can only add author constraints, never erase the derived ones.
    for row in passes:
        for group, authors in row["author_groups"].items():
            authors = [identified(a) for a in authors]
            if group == "all":
                extras = [a for a in authors if a["family"] not in derived_families]
                if extras:
                    groups.setdefault("declared:all", []).extend(extras)
            else:
                target = groups.setdefault(group, [])
                target.extend(a for a in authors if a not in target)
    for group, authors in sorted(groups.items()):
        families = {a["family"] for a in authors}
        covered = False
        for row in passes:
            named = row.get("covered_groups", list(row["author_groups"]))
            declared = row["author_groups"].get(group, row["author_groups"].get("all", []))
            declared_families = {identified(a)["family"] for a in declared}
            reader = model(row["reader_model"], "reader_model")
            # An 'all' read is usable only when its typed evidence includes every
            # derived family; the old OpenAI-only declaration cannot hide Claude.
            all_declared = {identified(a)["family"] for a in row["author_groups"].get("all", [])}
            required = derived_families if "all" in row["author_groups"] else families
            constraints = families | (all_declared - derived_families)
            if (group in named or "all" in named) and required <= declared_families:
                if reader != "unknown" and "unknown" not in constraints and reader not in constraints:
                    covered = True
        if not covered or unknown_reader:
            reason = f"model family unknown for {review['reader_model']}; " if unknown_reader else ""
            models = {key: sorted({a["model"] for a in values}) for key, values in groups.items()}
            command = shlex.join([str(BIN / "fm-review-record.py"), "review", "--task", task,
                                  "--pr", pr, "--head", head, "--base", base,
                                  "--verdict", "PASS", "--reader-model", "OUTSIDE_FAMILY_MODEL",
                                  "--author-groups", json.dumps(models, separators=(",", ":")),
                                  "--covered-groups", json.dumps([group]),
                                  "--loosens-deny-allow-list", "no", "--widens-guard", "no",
                                  "--customer-data-billing-spend", "no", "--report", "LOCAL_READER_REPORT"])
            raise RecordError(f"{reason}uncovered commit group {group}, family {','.join(sorted(families))}; reader_family must be known and outside this group (model family unknown is never covered); obtain the named read, set its actual trigger answers and local report, then record it with: FM_HOME={shlex.quote(str(home))} FM_STATE_OVERRIDE={shlex.quote(str(state_dir(home)))} {command}")
    return "PASS"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("review", "captain-word", "latest", "verify"):
        command = commands.add_parser(name, description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
        command.add_argument("--pr", required=True)
        if name != "latest":
            command.add_argument("--head", required=True)
        if name in ("review", "verify"):
            command.add_argument("--task")
            command.add_argument("--base")
        if name == "review":
            command.add_argument("--covered-groups", help='JSON list of groups read, or ["all"]; defaults to author-groups keys')
            for flag in ("verdict", "reader-model", "author-groups", "report", *(t.replace("_", "-") for t in TRIGGERS)):
                command.add_argument("--" + flag, required=True)
        if name == "captain-word":
            command.add_argument("--words", required=True)
    args = parser.parse_args()
    try:
        home = task_home()
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
        elif args.command == "captain-word":
            row.update(head=args.head, words=args.words)
        write = args.command in ("review", "captain-word")
        if write:
            validate(row)
        if args.command == "review":
            row["report_sha256"] = report_digest(args.report, args.verdict, args.head)
            if args.base:
                row["task"], row["derived_author_groups"] = derived_authors(home, pr, args.head, args.task, args.base)
                row["base"] = args.base
            elif args.task:
                row["task"] = args.task
            try:
                row["covered_groups"] = json.loads(args.covered_groups) if args.covered_groups else list(groups)
            except ValueError as exc:
                raise RecordError("covered_groups must be a JSON list of commit groups read") from exc
            if (not isinstance(row["covered_groups"], list) or not row["covered_groups"]
                    or any(not isinstance(g, str) or not g for g in row["covered_groups"])
                    or any(g != "all" and g not in groups and g not in row.get("derived_author_groups", {}) for g in row["covered_groups"])):
                raise RecordError("covered_groups must name author groups or all")
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
                print(f"review: {verify(records, rows, args.head, home, pr, args.task, args.base or (records['review'] or {}).get('base'))}")
    except (RecordError, OSError) as exc:
        print(f"error: {exc}; inspect review-records.jsonl in the PR task home before retrying")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
