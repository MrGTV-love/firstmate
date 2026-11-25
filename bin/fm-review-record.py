#!/usr/bin/env python3
"""Record independent review evidence and explicit captain merge words.

Usage (FM_HOME must name the absolute home holding the PR task record):
  fm-review-record.py review --pr URL --head SHA --verdict PASS|FAIL
    --reader-model MODEL --author-groups '{"commit-group":["model",...]}'
    --loosens-deny-allow-list yes|no --widens-guard yes|no
    --customer-data-billing-spend yes|no --report PATH
    [--covered-groups '["ship"]']
  fm-review-record.py captain-word --pr URL --head SHA --words 'Exact captain merge instruction'
  fm-review-record.py correction --pr URL --head SHA --effect exclude-review|supersede-author-group
    --target-at EPOCH --target-reader-model MODEL [--target-report-sha256 HEX]
    [--group NAME] --authority-words 'Exact captain words' --authority-at EPOCH --reason TEXT
  fm-review-record.py latest --pr URL
  fm-review-record.py verify --pr URL --head SHA --task TASK --base BASE_SHA [--review-only] [--json]
  fm-review-record.py plan --pr URL --head SHA --task TASK --base BASE_SHA

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
locally first. Group ship exists whenever any commit lacks the no-mistakes(
prefix or the current incarnation has a ship model, even when every subject
starts no-mistakes(. It uses the current meta,
any state/<task>.control-relaunch.meta-prior, and every model in the
append-only state/<task>.launch-models history reached from the current meta's
spawn_gen through prior links, so a reused task id never inherits an earlier
incarnation. fm-spawn.sh owns history publication. Legacy tasks without
history use the available meta evidence; default stays unknown.
Pipeline authorship has one rule for the whole PR, whatever the commit
subjects, ranges or step names: every no-mistakes run matching this PR (its
pr_url) or this task's repository and branch contributes the model of every
agent invocation it recorded, and those models form no-mistakes:<family>
groups. Attribution is conservative; a rebase or later clean replay never
drops an earlier run's author family. Runs and agent_invocations are read from
<NM_HOME>/state.sqlite (default ~/.no-mistakes), opened with SQLite mode=ro. A
database that exists but cannot be opened or queried, or a relative NM_HOME,
adds an unreadable family unknown and never clears evidence already read. A
proven-absent database adds an absent family unknown when any subject starts exactly no-mistakes( or the task's
recorded delivery mode is no-mistakes (an unrecorded mode counts as
no-mistakes); a direct-PR or local-only task without either has no pipeline
group. When a subject starts no-mistakes( but no matching run recorded any
invocation, the pipeline group is absent unknown.
A recorded provider can resolve an otherwise unknown model alias; conflicting
provider/model families are unreadable unknown. An invocation that records no
model and no provider is absent unknown unless its agent is exactly claude. Every invocation counts, including
cancelled and errored ones. An invocation with an empty model takes a family
from its agent only when the agent is exactly claude (anthropic); any other
agent, such as acp:omp, stays unknown. It never creates a database.
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
Every known author family of every group needs at least one such exact-head
PASS. Unknown ship authors and other unknown constraints require exact-head
PASS reads of their group from at least two different known reader families:
whatever that unknown family really is, at least one reader differs from it.
Only the derived no-mistakes:unknown group may instead use one such PASS whose
known reader family differs from EVERY ship family, provided every derived
item of that group is absent evidence (no state database, no matching run or
invocation, or an invocation with no model and no provider), the ship group
has at least one derived family and every ship family, derived or typed, is
known. A ship group with no derived family or with any unknown family gives
the pipeline group no relief, so it keeps the two-reader rule. Unreadable,
corrupt or schema-changed databases, a relative NM_HOME, conflicting
provider/model families and recorded models of unknown family are evidence
present but unusable: they give no relief and keep the two-reader rule, so a
read fault is never easier than a successful read. Unknown ship
constraints still need two different known reader families. Multiple reads may
collectively cover known author families; a third family is not required for mixed-family work.
An accepted verify, independent review or captain-word, prints 'pipeline
author family not recorded' when the single-reader rule above was needed to cover the derived
no-mistakes:unknown group in any window verify checks: the PASS reads after an
exact-head FAIL that read the group, or all exact-head PASS reads. In that
window the rule applies and fewer than two different known reader families read
the group, so a second family read before the FAIL never suppresses the fact; --json includes that string in optional
facts. fm-pr-merge.sh writes it into its merge-authority record from the same
verification read. That record is short-lived: the merge poll in fm-watch.sh
deletes it when it records the merge outcome, whose ledger does not keep the
fact, and fm-teardown.sh deletes any record left at teardown.
An unknown pipeline group read by two different known reader families in every
window that checks it, and every known pipeline group, emit no fact.
This preserves known-builder independence but not the former guarantee for
all possible pipeline authors: the unrecorded pipeline family may actually
match the sole reader. Local invocation evidence and ship launch history
narrow, but do not eliminate, that risk. See docs/configuration.md's
'Unrecorded pipeline author families' harm-model reassessment.
Exact-head binding, report validation, captain-word/away rules and every live
forge/hold check remain mandatory.
Model families are rederived from ids into anthropic, openai, google, deepseek,
xai, moonshot, meta (aliases claude, gpt, chatgpt, codex, oN, gemini, gemma, grok,
kimi, llama, and the exact native Claude names opus, sonnet, haiku, which are
deliberately anthropic because Claude records bare model names); route prefixes
ending in / are dropped. Stored typed family fields
never decide independence. Uncovered-group refusals name each uncovered family,
reporting any group with an unknown author family before known-family groups.
For known families they print a review recording command; substitute the actual
reader, local report and trigger answers. An unknown-family refusal prints
that command with the same substitutions and asks for two different known
reader families; when the pipeline-only rule above applies to the group, it
names the ship families and says one PASS from a known reader family outside
all of them is enough instead. It also offers repaired author evidence or the
exact-head captain-word command, whose words must be the captain's actual fresh
instruction. When every group is covered but the newest reader is unknown, the
refusal names that reader and prints a known-family reread command.
verify accepts the newest captain-word when it names the exact live head, unless
a FAIL at that head was appended after it. An exact-head FAIL, with or without
captain words, stands until PASS reads at that head appended after it cover every
group the FAIL read (its covered groups, or every group for all), each author
family by a known reader of a different family as above; otherwise only fresh
exact-head captain words appended after it clear it. Reviews of other heads never
clear it. Without captain words, the newest review must also name the
live head and have a known reader family. Trigger answers remain required, recorded
and printed by latest, but yes answers alone do not require captain words.
Captain words waive no existing forge/hold guard. The caller records as captain-word only a
current explicit captain merge instruction naming the concrete PR, given in the
captain's own turn. captain-word itself refuses (exit 2) while the state directory
holds an away-posture record (fm_afk_contract_away_present in fm-afk-contract.sh),
so away words are never recorded as captain-word and the captain gives the word
after return; a quiet record does not refuse, because the captain is present, and
a captain-word recorded before /afk stays valid.
By default verify also accepts that captain-word precedence; --review-only does
not. It applies the same exact-head, derived-author coverage and FAIL rules
without any captain-word, also refuses a newest PASS with any yes trigger
answer, and never treats a captain-word as a substitute.
verify --json prints one fm-review-verification.v1 object built from the same
lock-held read that decides the result: success carries ok true, and either basis
independent-review (pr, exact head, review epoch at, reader_model, both families
re-derived from the recorded model ids, the recorded author groups with families
re-derived, report, and report_sha256 when the record carries that digest) or
basis captain-word (pr, head, at, words), each with optional facts. Failures carry ok false and
error {kind, message}, where kind not-qualified means no recorded evidence
satisfies the request, unavailable means stored history, task metadata or author
commit evidence cannot be read,
and invalid-input means a caller field, URL or path is invalid. Missing review
history is not-qualified; corrupt or unreadable history is unavailable. Failure
JSON keeps the existing exit status (1 evidence/unavailable, 2 input) and never
looks like a success object. Without --json, a successful verify prints
review: PASS (plus review: pipeline author family not recorded when applicable)
or review: captain-word (plus the same fact line when applicable); a refusal prints an error: line and exits 1.
plan prints one fm-review-plan.v1 object and decides nothing: the derived author groups of the exact head
with each model's family, and every group family that the recorded exact-head PASS reads leave uncovered under
the same coverage rule verify applies, including its one-reader relief for an unrecorded pipeline author family,
whether or not any review or captain-word exists. An uncovered item whose families include unknown
also names reader_outside, the families a known reader must lie outside for its exact-head PASS of that
group to count toward that rule: the known readers already counted, or with none counted every ship family
under the one-reader relief and no family under the two-reader rule. An unknown item without reader_outside
is one no known reader can count toward. It ignores a
captain-word and a FAIL, so a caller that asks which reads are still owed (bin/fm-pr-auto-review.py) gets the
families without parsing a refusal message, and it writes nothing. Failures carry the failure object and exit
status verify uses.
latest emits the complete newest review and captain-word as JSON for relay reads.
Missing/invalid input exits 2; missing/mismatched evidence or unreadable history
exits 1. Corrupt/partial history is preserved for reconciliation, never repaired.
correction appends one record that makes ONE existing review row count for less;
no row is ever edited or deleted. --effect exclude-review makes the named row count
for no coverage and its typed author_groups add no constraint. --effect
supersede-author-group with --group NAME removes only that typed author_groups
entry from the named row: the entry adds no constraint and no coverage, while the
row's other entries, covered_groups, verdict and report digest stay in force.
A correction names its target exactly: the PR and head it is recorded for, the
row's at, reader_model and, when the row has one, report_sha256 (a row without a
digest is named without one). It is recorded only when exactly one review row
before it matches, that row is a PASS with no yes trigger answer (a FAIL, or an
escalation trigger, is never cleared), and a supersede names an entry the row holds.
A correction carries its OWN authority inside the row: --authority-words, the
captain's authorizing words verbatim, and --authority-at, the epoch they were
given; both are required and the words must be non-empty. It cites no captain-word
row and is never merge authority: verify without --review-only returns
captain-word only for a captain-word row, so a ledger with a correction and no
captain-word is judged by review coverage alone, and corrections never change
which captain-word is newest or what a FAIL after it does. Like captain-word,
a correction is not recorded while an away-posture record exists. A correction
can only remove what a typed row declared, so it never adds coverage and never
removes a derived group: derived groups come from task meta, launch-models and
the pipeline database on every verify, and a superseded entry stops covering
its group too.
verify and plan apply a correction only when it still resolves against the rows
before it and its authority holds non-empty words and an epoch (the strict
direction), so a correction can never block or loosen the rest of a ledger; one
applied at the verified head adds the fact 'corrections applied: N' followed by
one fact per applied correction that prints its authority words (JSON-quoted) and
epoch.
Code from before correction rows existed treats the kind as an invalid record:
every command reading the ledger, writes included, fails for every PR in that
home with 'review record history is invalid', so such code fails closed rather
than ignoring a correction.
Ledgers without correction rows read exactly as before. See docs/configuration.md
'Review record corrections' for the guard's harm-model reassessment.
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
            "opus": "anthropic", "sonnet": "anthropic", "haiku": "anthropic",
            "openai": "openai", "gpt": "openai", "chatgpt": "openai", "codex": "openai",
            "google": "google", "gemini": "google", "gemma": "google",
            "deepseek": "deepseek", "xai": "xai", "grok": "xai",
            "moonshot": "moonshot", "kimi": "moonshot", "meta": "meta", "llama": "meta"}
RECORDED_FAMILIES = set(FAMILIES.values()) | {"unknown"}
CORRECTION_EFFECTS = ("exclude-review", "supersede-author-group")


class RecordError(Exception):
    """An actionable invalid field or unavailable record."""


class VerificationError(RecordError):
    """No qualifying recorded evidence satisfies the verification request."""


class UnavailableError(RecordError):
    """The record store or a required evidence field cannot be read."""


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


def is_sha256(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def validate(row):
    if not isinstance(row, dict) or row.get("schema") != "fm-review-record.v1":
        raise RecordError("review record schema is invalid")
    nonempty(row.get("pr"), "pr")
    if type(row.get("at")) is not int or row["at"] < 0:
        raise RecordError("at must be an epoch integer")
    if row.get("kind") not in ("review", "captain-word", "correction"):
        raise RecordError("review record kind is invalid")
    head_sha(row.get("head"))
    if row["kind"] == "captain-word":
        nonempty(row.get("words"), "words")
        return
    if row["kind"] == "correction":
        if row.get("effect") not in CORRECTION_EFFECTS:
            raise RecordError("correction effect must be exclude-review or supersede-author-group")
        target = row.get("target")
        if not isinstance(target, dict) or type(target.get("at")) is not int or target["at"] < 0:
            raise RecordError("correction target must name the review row's epoch at")
        model(target.get("reader_model"), "correction target reader_model")
        if "report_sha256" in target and not is_sha256(target["report_sha256"]):
            raise RecordError("correction target report_sha256 must be a sha256 hex digest")
        if (row["effect"] == "supersede-author-group") != ("group" in row):
            raise RecordError("correction group names the author_groups entry to supersede, and only supersede-author-group takes one")
        if "group" in row:
            nonempty(row["group"], "correction group")
        # The authority is judged where a correction applies, not here: a correction whose
        # authority is missing or empty must read as a row that does nothing, never as a ledger
        # that no command can read.
        nonempty(row.get("reason"), "reason")
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


def refuse_away(state, kind):
    result = subprocess.run(["bash", "-c", '. "$1/fm-afk-contract.sh" || exit 2; fm_afk_contract_away_present "$2" || exit 1',
                             "fm-review-record", str(BIN), str(state)], capture_output=True, text=True, check=False)
    if result.returncode == 0:
        if kind == "correction":
            raise RecordError(f"the away-posture record {state / '.afk-contract'} exists, so the captain is away and away words never carry correction authority; the captain must give the correction authority after return")
        raise RecordError(f"captain-word refused: the away-posture record {state / '.afk-contract'} exists, so the captain is away and away words are never captain words; the captain must give the merge word after return")
    if result.returncode != 1:
        if kind == "correction":
            raise RecordError(f"the away-posture record under {state} could not be read, so correction authority cannot be checked")
        raise RecordError(f"captain-word refused: the away-posture record under {state} could not be read")


@contextlib.contextmanager
def ledger(write, home, create=True):
    # A correction needs history to name, so it never creates the ledger or its state directory.
    state = state_dir(home)
    if write and create:
        state.mkdir(mode=0o700, exist_ok=True)
    flags = os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(state / "review-records.jsonl", flags | (os.O_CREAT if write and create else 0), 0o600)
    except FileNotFoundError:
        if write and create:
            raise
        yield None
        return
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise UnavailableError("review record history must be an ordinary single-link file")
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
                raise UnavailableError("review record history is incomplete; preserve and reconcile it before retrying")
            try:
                row = json.loads(line)
                validate(row)
            except (ValueError, TypeError, RecordError) as exc:
                raise UnavailableError(f"review record history is invalid ({exc}); preserve and reconcile it before retrying") from exc
            if row["pr"] == pr:
                if row["kind"] in result:
                    result[row["kind"]] = row
                rows.append(row)
    return result, rows


def correction_authority(correction):
    """The (words, at) authority a correction carries inside its own row, else RecordError.

    The words are the captain's authorizing words verbatim and at is the epoch they were given.
    A correction never cites a captain-word row, so it can never be merge authority.
    """
    authority = correction.get("authority")
    if not isinstance(authority, dict):
        raise RecordError("correction must carry its authority: the captain's authorizing words and the epoch they were given")
    nonempty(authority.get("words"), "correction authority words")
    if type(authority.get("at")) is not int or authority["at"] < 0:
        raise RecordError("correction authority at must be the epoch the words were given")
    return authority["words"], authority["at"]


def named_row(prior, correction):
    """Index in `prior` of the one review row `correction` names, else RecordError.

    Only rows recorded before the correction count, so a row appended later can never
    make an older correction ambiguous or move it onto another row.
    """
    target = correction["target"]
    hits = [i for i, row in enumerate(prior)
            if row["kind"] == "review" and row["pr"] == correction["pr"] and row["head"] == correction["head"]
            and row["at"] == target["at"] and row["reader_model"] == target["reader_model"]
            and row.get("report_sha256") == target.get("report_sha256")]
    if len(hits) != 1:
        raise RecordError(f"correction must name exactly one review row at head {correction['head']} (at {target['at']}, reader_model {target['reader_model']}, "
                          f"report_sha256 {target.get('report_sha256', 'none')}); {len(hits)} rows match")
    row = prior[hits[0]]
    if row["verdict"] != "PASS":
        raise RecordError("a correction only makes a PASS row count for less; a FAIL row stands")
    yes = [trigger for trigger in TRIGGERS if row[trigger] == "yes"]
    if yes:
        raise RecordError(f"a correction cannot clear an escalation trigger; {', '.join(yes)} is yes in the named row")
    if correction["effect"] == "supersede-author-group" and correction["group"] not in row["author_groups"]:
        raise RecordError(f"the named row holds no author_groups entry {correction['group']}")
    return hits[0]


def correction_target(prior, correction):
    """Index in `prior` of the review row a recorded `correction` still resolves to, else RecordError."""
    correction_authority(correction)
    return named_row(prior, correction)


def apply_corrections(records, rows, head):
    """(records, rows, applied) as verification judges them: each correction applied to a copy.

    The ledger rows are never touched. A correction that no longer resolves against the rows
    before it is ignored, the strict direction, so it can neither block nor loosen anything.
    `applied` lists the corrections at `head` that took effect, in ledger order. The newest
    captain-word is passed through untouched: a correction is never merge authority.
    """
    if not any(row["kind"] == "correction" for row in rows):
        return records, rows, []
    excluded, superseded, applied = set(), {}, []
    for index, row in enumerate(rows):
        if row["kind"] != "correction":
            continue
        try:
            target = correction_target(rows[:index], row)
        except RecordError:
            continue
        if row["head"] == head:
            applied.append(row)
        if row["effect"] == "exclude-review":
            excluded.add(target)
        else:
            superseded.setdefault(target, set()).add(row["group"])
    judged = []
    for index, row in enumerate(rows):
        if row["kind"] == "correction" or index in excluded:
            continue
        if index in superseded:
            row = {**row, "_superseded": superseded[index],
                   "author_groups": {group: authors for group, authors in row["author_groups"].items()
                                     if group not in superseded[index]}}
        judged.append(row)
    reviews = [row for row in judged if row["kind"] == "review"]
    return {"review": reviews[-1] if reviews else None, "captain-word": records["captain-word"]}, judged, applied


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
    if meta.get("model") or len(models) > 1 or any(not subject.startswith("no-mistakes(") for _, subject in commits):
        groups["ship"] = [modelled(value or "unknown", "ship model") for value in sorted(set(models))]
    prefixed = any(subject.startswith("no-mistakes(") for _, subject in commits)
    root = Path(os.environ.get("NM_HOME") or Path.home() / ".no-mistakes")
    unknown = modelled("unknown", "pipeline model")
    absent = {**unknown, "origin": "absent"}
    models = []
    try:
        if not root.is_absolute():
            raise OSError(f"relative NM_HOME {root} is not author evidence")
        try:
            os.lstat(root / "state.sqlite")
        except FileNotFoundError:
            if prefixed or (meta.get("mode") or "no-mistakes") == "no-mistakes":
                models.append(absent)
        else:
            with contextlib.closing(sqlite3.connect(root.resolve().as_uri() + "/state.sqlite?mode=ro", uri=True)) as db:
                runs = db.execute("SELECT id FROM runs WHERE pr_url = ? "
                                  "OR (branch = ? AND repo_id IN (SELECT id FROM repos WHERE working_path IN (?, ?)))",
                                  (pr, meta.get("branch", ""), str(worktree), meta.get("project", ""))).fetchall()
                for (run_id,) in runs:
                    for agent, exact_model, provider in db.execute("SELECT agent, model, model_provider FROM agent_invocations WHERE run_id = ?", (run_id,)).fetchall():
                        if not exact_model and not provider and agent != "claude":
                            models.append(absent)
                            continue
                        item = modelled(exact_model or ("claude" if agent == "claude" else "unknown"), "pipeline model")
                        # Only fresh database evidence supplies a provider; typed
                        # declarations and historical family fields never do.
                        if provider in RECORDED_FAMILIES - {"unknown"}:
                            if item["family"] == "unknown":
                                item["family"] = provider
                            elif item["family"] != provider:
                                item["family"] = "unknown"
                        models.append(item)
    except (sqlite3.Error, OSError):
        models.append(unknown)
    if prefixed and not models:
        models.append(absent)
    for item in {(item["model"], item["family"], item.get("origin")): item for item in models}.values():
        groups.setdefault(f"no-mistakes:{item['family']}", []).append(item)
    return task, groups


def correction_facts(applied):
    """The facts verify prints for the corrections it applied: the count, then each one's own authority."""
    if not applied:
        return []
    facts = [f"corrections applied: {len(applied)}"]
    for row in applied:
        words, at = correction_authority(row)
        # JSON quoting keeps a verbatim authority on one line and escapes control characters.
        facts.append(f"correction {row['effect']} of the review row at {row['target']['at']} (reader {row['target']['reader_model']}): "
                     f"authority given at {at}: {json.dumps(words)}")
    return facts


def verify(records, rows, head, home, pr, task, base, review_only=False, plan=False, corrections=()):
    word = records["captain-word"]
    review = records["review"]
    at_word = not (review_only or plan) and word is not None and word["head"] == head
    start = max(i for i, row in enumerate(rows) if row["kind"] == "captain-word") + 1 if at_word else 0
    fails = [i for i in range(start, len(rows)) if rows[i]["kind"] == "review"
             and rows[i]["head"] == head and rows[i]["verdict"] == "FAIL"]
    if at_word and not fails:
        return "captain-word", word
    if not at_word and not plan:
        if review is None and review_only:
            raise VerificationError(f"no independent review record at live head {head}; --review-only requires a PASS recorded with fm-review-record.py review, and a captain-word is not a substitute")
        if review is None:
            raise VerificationError("review record is missing; relay the review with fm-review-record.py review --pr URL, or record explicit captain merge words at the live head with fm-review-record.py captain-word (see --help), then retry the merge")
        if review["head"] != head:
            raise VerificationError(f"head mismatch: review names {review['head']}, live head is {head}; review the live head and record its PASS with fm-review-record.py review, then retry the merge")
    _, derived = derived_authors(home, pr, head, task, base)
    groups = {group: list(authors) for group, authors in derived.items()}
    derived_families = {a["family"] for authors in derived.values() for a in authors}

    def declared(group, authors):
        # A typed id takes a family from evidence only by exactly matching a
        # model derived for that same group; anything else is read from its id.
        known = {a["model"]: a["family"] for a in derived.get(group, [])}
        return [{"model": a["model"], "family": known[a["model"]] if a["model"] in known
                 else model(a["model"], "author_groups model")} for a in authors]

    def passes_at_head(window):
        return [row for row in window if row["kind"] == "review" and row["head"] == head and row["verdict"] == "PASS"]

    passes = passes_at_head(rows)
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
    captain = shlex.join([str(BIN / "fm-review-record.py"), "captain-word", "--pr", pr, "--head", head,
                          "--words", "FRESH_CAPTAIN_WORDS"])
    captain_help = f"obtain a fresh explicit captain merge instruction for this PR at this exact head and record the captain's actual words (never fabricated ones) in place of FRESH_CAPTAIN_WORDS with: {env} {captain}"
    if review_only:
        captain_help = "--review-only requires recorded independent PASS coverage, and a captain-word is not a substitute"

    def review_command(reader, covered, source):
        models = {key: sorted({a["model"] for a in values}) for key, values in source.items()}
        return shlex.join([str(BIN / "fm-review-record.py"), "review", "--pr", pr, "--head", head,
                           "--verdict", "PASS", "--reader-model", reader,
                           "--author-groups", json.dumps(models, separators=(",", ":")),
                           "--covered-groups", json.dumps(covered),
                           "--loosens-deny-allow-list", "no", "--widens-guard", "no",
                           "--customer-data-billing-spend", "no", "--report", "LOCAL_READER_REPORT"])

    ship_families = {a["family"] for a in groups.get("ship", [])}
    pipeline_relief = (derived.get("no-mistakes:unknown") and derived.get("ship") and "unknown" not in ship_families
                       and all(a.get("origin") == "absent" for a in derived["no-mistakes:unknown"]))

    def unknown_need(group, later):
        two = f"{later}exact-head PASS reads of {'that' if later else 'this'} group from two different known reader families"
        if group == "no-mistakes:unknown" and pipeline_relief:
            return (f"model family unknown needs one {later}exact-head PASS of {'that' if later else 'this'} group from a known reader family "
                    f"outside every ship family ({','.join(sorted(ship_families))}), or {two}; obtain the reads one of those rules needs")
        return f"model family unknown needs {two}; obtain reads until both families count"

    def unknown_reader_placeholder(group):
        return "OUTSIDE_SHIP_FAMILY_MODEL" if group == "no-mistakes:unknown" and pipeline_relief else "SECOND_KNOWN_FAMILY_MODEL"

    relief_used = []
    unknown_outside = {}

    def with_facts(row):
        return {**row, "facts": (["pipeline author family not recorded"] if relief_used else [])
                + correction_facts(corrections)}

    def uncovered(group, authors, reads):
        families = {a["family"] for a in authors}
        readers = set()
        for row in reads:
            named = row.get("covered_groups", list(row["author_groups"]))
            key = group if group in row["author_groups"] else "all"
            if group in row.get("_superseded", ()) or key in row.get("_superseded", ()):
                continue  # a superseded declaration covers nothing for its group
            declared_families = {a["family"] for a in declared(key, row["author_groups"].get(key, []))}
            reader = model(row["reader_model"], "reader_model")
            # An 'all' read is usable only when its typed evidence includes every
            # derived family; the old OpenAI-only declaration cannot hide Claude.
            required = derived_families if "all" in row["author_groups"] else families
            if (group in named or "all" in named) and required <= declared_families and reader != "unknown":
                readers.add(reader)
        # Known authors retain different-family coverage. Unknown builders and
        # other unknown groups retain the two-reader guarantee; only a derived
        # unknown pipeline group whose ship families are all known may use
        # builder-independent single coverage.
        pipeline_read = group == "no-mistakes:unknown" and pipeline_relief and readers - ship_families
        if "unknown" in families and pipeline_read and len(readers) < 2:
            relief_used.append(group)
        missing = sorted(f for f in families if (len(readers) < 2 and not pipeline_read
                                                 if f == "unknown" else not readers - {f}))
        if "unknown" in missing:
            unknown_outside[group] = readers or (ship_families if group == "no-mistakes:unknown" and pipeline_relief else set())
        return missing

    # A FAIL stands until later exact-head PASS reads cover every group it read.
    for index in ([] if plan else fails):
        failed = rows[index]
        named = failed.get("covered_groups", list(failed["author_groups"]))
        for group in sorted(groups) if "all" in named else named:
            authors = groups.get(group) or declared(group, failed["author_groups"].get(group, []))
            missing = uncovered(group, authors, passes_at_head(rows[index + 1:]))
            if not missing:
                continue
            reason = (f"verdict is FAIL at live head {head} (reader {failed['reader_model']}, report {failed['report']}); "
                      f"no later exact-head PASS covers group {group}, family {','.join(missing)}, that this FAIL read; ")
            if "unknown" in missing:
                raise VerificationError(f"{reason}{unknown_need(group, 'later ')}, set each read's actual trigger answers and local report, then record each with: {env} {review_command(unknown_reader_placeholder(group), [group], {**groups, group: authors})}; or {captain_help}")
            raise VerificationError(f"{reason}record later exact-head PASS reads of that group from readers outside each of its families with: {env} {review_command('OUTSIDE_FAMILY_MODEL', [group], {**groups, group: authors})}; or {captain_help}")
    if at_word:
        return "captain-word", with_facts(word)
    if plan:
        owed = []
        for group, authors in sorted(groups.items(), key=lambda item: ("unknown" not in {a["family"] for a in item[1]}, item[0])):
            missing = uncovered(group, authors, passes)
            if not missing:
                continue
            item = {"group": group, "families": missing}
            if "unknown" in missing and RECORDED_FAMILIES - {"unknown"} - unknown_outside[group]:
                item["reader_outside"] = sorted(unknown_outside[group])
            owed.append(item)
        return "plan", {"groups": {group: [{"model": a["model"], "family": a["family"]} for a in authors]
                                  for group, authors in groups.items()}, "uncovered": owed}
    unknown_reader = model(review["reader_model"], "reader_model") == "unknown"
    for group, authors in sorted(groups.items(), key=lambda item: ("unknown" not in {a["family"] for a in item[1]}, item[0])):
        missing = uncovered(group, authors, passes)
        if not missing:
            continue
        reason = f"model family unknown for newest reader {review['reader_model']}; " if unknown_reader else ""
        if "unknown" in missing:
            raise VerificationError(f"{reason}uncovered commit group {group}, family {','.join(missing)}; {unknown_need(group, '')}, set each read's actual trigger answers and local report, then record each with: {env} {review_command(unknown_reader_placeholder(group), [group], groups)}; or repair the author evidence so every author model has a known family, or {captain_help}")
        raise VerificationError(f"{reason}uncovered commit group {group}, family {','.join(missing)}; each author family needs an exact-head PASS reading this group whose reader_family is known and different from it (see --help for unknown-pipeline coverage); obtain the named read, set its actual trigger answers and local report, then record it with: {env} {review_command('OUTSIDE_FAMILY_MODEL', [group], groups)}")
    if unknown_reader:
        raise VerificationError(f"model family unknown for newest reader {review['reader_model']}; every group is covered by known-family reads, but the newest review must name a known reader family; obtain a reread from a known-family reader, set its actual trigger answers and local report, then record it with: {env} {review_command('KNOWN_FAMILY_MODEL', sorted(groups), groups)}")
    yes = [trigger for trigger in TRIGGERS if review[trigger] == "yes"]
    if yes and review_only:
        raise VerificationError(f"{', '.join(yes)} is yes at live head {head}; --review-only requires an independent PASS with no escalation trigger, and a captain-word is not a substitute")
    return "independent-review", with_facts(review)


def verification_json(pr, head, basis, row):
    evidence = {"schema": "fm-review-verification.v1", "ok": True, "basis": basis,
                "pr": pr, "head": head, "at": row["at"]}
    if basis == "captain-word":
        evidence["words"] = row["words"]
    else:
        evidence.update(
            reader_model=row["reader_model"],
            reader_family=model(row["reader_model"], "reader_model"),
            author_groups={group: [{"model": author["model"],
                                    "family": model(author["model"], "author_groups model")}
                                   for author in authors]
                           for group, authors in row["author_groups"].items()},
            report=row["report"])
        if isinstance(row.get("report_sha256"), str) and row["report_sha256"]:
            evidence["report_sha256"] = row["report_sha256"]
    if row.get("facts"):
        evidence["facts"] = row["facts"]
    return evidence


def failure_json(kind, message):
    return {"schema": "fm-review-verification.v1", "ok": False,
            "error": {"kind": kind, "message": message}}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("review", "captain-word", "correction", "latest", "verify", "plan"):
        command = commands.add_parser(name, description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
        command.add_argument("--pr", required=True)
        if name != "latest":
            command.add_argument("--head", required=True)
        if name in ("verify", "plan"):
            command.add_argument("--task", required=True)
            command.add_argument("--base", required=True)
        if name == "review":
            command.add_argument("--covered-groups", help='JSON list of groups read, or ["all"]; defaults to author-groups keys')
            for flag in ("verdict", "reader-model", "author-groups", "report", *(t.replace("_", "-") for t in TRIGGERS)):
                command.add_argument("--" + flag, required=True)
        if name == "captain-word":
            command.add_argument("--words", required=True)
        if name == "correction":
            command.add_argument("--effect", required=True, choices=CORRECTION_EFFECTS)
            command.add_argument("--target-at", required=True, type=int, help="epoch at of the review row to correct")
            command.add_argument("--target-reader-model", required=True)
            command.add_argument("--target-report-sha256", help="the row's report_sha256, when the row has one")
            command.add_argument("--group", help="the author_groups entry to supersede (supersede-author-group only)")
            command.add_argument("--authority-words", required=True, help="the captain's authorizing words, verbatim")
            command.add_argument("--authority-at", required=True, type=int, help="epoch the captain gave those words")
            command.add_argument("--reason", required=True)
        if name == "verify":
            command.add_argument("--review-only", action="store_true", help="require the recorded independent PASS itself; a captain-word is not a substitute")
            command.add_argument("--json", action="store_true", help="print one fm-review-verification.v1 object built from the same locked read")
    args = parser.parse_args()
    emit_json = getattr(args, "json", False) or args.command == "plan"
    try:
        home = task_home()
        if args.command in ("verify", "plan") and not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", args.base):
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
        elif args.command == "correction":
            target = {"at": args.target_at, "reader_model": args.target_reader_model}
            if args.target_report_sha256:
                target["report_sha256"] = args.target_report_sha256
            row.update(head=args.head, effect=args.effect, target=target,
                       authority={"words": args.authority_words, "at": args.authority_at}, reason=args.reason)
            if args.group is not None:
                row["group"] = args.group
        write = args.command in ("review", "captain-word", "correction")
        if write:
            validate(row)
            if args.command == "correction":
                try:
                    correction_authority(row)
                except RecordError as exc:
                    raise RecordError(f"correction not recorded; {exc}") from exc
        if args.command == "review":
            row.setdefault("covered_groups", list(groups))
            if any(g != "all" and g not in groups for g in row["covered_groups"]):
                raise RecordError("covered_groups must name author groups or all")
            row["report_sha256"] = report_digest(args.report, args.verdict, args.head)
        if args.command in ("captain-word", "correction"):
            try:
                refuse_away(state_dir(home), args.command)
            except RecordError as exc:
                if args.command == "captain-word":
                    raise
                raise RecordError(f"correction not recorded; {exc}") from exc
    except RecordError as exc:
        if emit_json:
            print(json.dumps(failure_json("invalid-input", str(exc)), separators=(",", ":")))
        else:
            print(f"error: {exc}")
        return 2
    try:
        with ledger(write, home, create=args.command != "correction") as fd:
            records, rows = newest(fd, pr)
            if write:
                if args.command == "correction":
                    named_row(rows, row)
                data = (json.dumps(row, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")
                if os.write(fd, data) != len(data):
                    raise UnavailableError("partial review record append; preserve history for reconciliation before retrying")
                os.fsync(fd)
                print(f"recorded: {args.command}")
            elif args.command == "latest":
                print(json.dumps(records, separators=(",", ":")))
            elif args.command == "plan":
                records, rows, applied = apply_corrections(records, rows, args.head)
                _, evidence = verify(records, rows, args.head, home, pr, args.task, args.base, plan=True, corrections=applied)
                print(json.dumps({"schema": "fm-review-plan.v1", "ok": True, "pr": pr, "head": args.head, **evidence},
                                 separators=(",", ":")))
            else:
                records, rows, applied = apply_corrections(records, rows, args.head)
                basis, evidence = verify(records, rows, args.head, home, pr, args.task, args.base, args.review_only, corrections=applied)
                if emit_json:
                    print(json.dumps(verification_json(pr, args.head, basis, evidence), separators=(",", ":")))
                else:
                    print(f"review: {'PASS' if basis == 'independent-review' else basis}")
                    for fact in evidence.get("facts", []):
                        print(f"review: {fact}")
    except VerificationError as exc:
        if emit_json:
            print(json.dumps(failure_json("not-qualified", str(exc)), separators=(",", ":")))
        else:
            print(f"error: {exc}; inspect review-records.jsonl in the PR task home before retrying")
        return 1
    except (UnavailableError, RecordError, OSError) as exc:
        if emit_json:
            print(json.dumps(failure_json("unavailable", str(exc)), separators=(",", ":")))
        else:
            print(f"error: {exc}; inspect review-records.jsonl in the PR task home before retrying")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
