#!/usr/bin/env python3
"""Check lines that staged or outgoing commits add, using conservative credential shapes.

Usage: fm-git-secrets.py pre-commit
       fm-git-secrets.py pre-push <remote-name> <remote-location>
Only content new relative to every parent is inspected: the lines the staged
index adds against HEAD and each MERGE_HEAD, and the lines each outgoing commit
adds against all of its parents. Within one such diff, each removed copy of a
line cancels one added copy anywhere, so moved or renamed content is not new.
Outgoing commits are those reachable from the pushed tips but not from an
advertised old tip or any remote-tracking ref, so history already on a remote
is not inspected again. That exclusion follows commits, not content: a
cherry-pick, revert or squash of a commit already on a remote makes a new
commit, so its lines are inspected and can be falsely refused. Pre-push
consumes Git's ref-update records on stdin; the hook wrapper preserves those
bytes for the repository's own hook. No file content or match is printed, no
provider is called, and no working-tree file is read. Each decision appends one event through fm-guard-event.sh carrying
the highest consecutive refusal count for the same credential-shaped line,
identified by its content hash. Different content starts at one. A failed
inspection is counted under the reserved inspection-failed key and keeps the
per-line counts; only an allowed decision clears them. Past the budget of one,
the refusal also escalates to a human decision, and the operation stays
refused. Exit 1 refuses the Git operation, including when inspection fails;
exit 2 indicates invalid arguments.
"""

import codecs
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter


SHAPES = tuple(re.compile(pattern) for pattern in (
    rb"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY(?: BLOCK)?-----",
    rb"(?<![A-Za-z0-9_-])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{16,})",
    # Consume a complete scheme-character run without restarting at hyphens.
    rb'''(?i)(?<![a-z0-9+.-])[a-z0-9+.-]+://[^\s/:@?#"'`<>()\[\]{}\\,;|]*:[^\s/@?#"'`<>()\[\]{}\\,;|]{8,}@''',
))
OID = re.compile(rb"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
GUARDS = {"pre-commit": "git-commit-credential-shapes", "pre-push": "git-push-credential-shapes"}
EVENT_WRITER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-guard-event.sh")
BUDGET = 1
INSPECTION_FAILED = "inspection-failed"
# Whole-line patches with fixed prefixes, independent of user diff settings.
DIFF = ("-p", "--text", "-U0", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
        "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/")


def git(*args, data=None):
    return subprocess.run(["git", *args], input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, check=True).stdout


def added_lines(*args):
    added, removed, path, body = {}, Counter(), None, False
    for line in git(*args, *DIFF).split(b"\n"):
        if line.startswith(b"diff --git "):
            path, body = None, False
        elif body:
            if line.startswith(b"+") and path is not None:
                added.setdefault(path, Counter())[line[1:]] += 1
            elif line.startswith(b"-"):
                removed[line[1:]] += 1
        elif line.startswith(b"@@ "):
            body = True
        elif line.startswith(b"+++ "):
            # Git appends a tab to a name containing a space and C-quotes others.
            name = line[4:].removesuffix(b"\t")
            if name.startswith(b'"'):
                name = codecs.escape_decode(name[1:-1])[0]
            path = name[2:] if name.startswith(b"b/") else None
    for path in sorted(added):
        moved = added[path] & removed
        added[path] -= moved
        removed -= moved
    return added


def new_lines(diffs):
    first, *rest = diffs
    for other in rest:
        first = {path: lines & other.get(path, Counter()) for path, lines in first.items()}
    return first


def staged_lines():
    try:
        parents = [git("rev-parse", "-q", "--verify", "HEAD^{commit}").strip()]
    except subprocess.CalledProcessError:
        yield added_lines("diff", "--cached")  # An unborn branch adds everything staged.
        return
    try:
        with open(git("rev-parse", "--git-path", "MERGE_HEAD").rstrip(b"\n"), "rb") as merge_head:
            parents += merge_head.read().split()
    except FileNotFoundError:
        pass
    if not all(OID.fullmatch(parent) for parent in parents):
        raise ValueError("invalid merge parent")
    yield new_lines([added_lines("diff", "--cached", parent.decode()) for parent in parents])


def outgoing_lines():
    tips, excluded = set(), set()
    for line in sys.stdin.buffer:
        fields = line.split()
        if len(fields) != 4 or not OID.fullmatch(fields[1]) or not OID.fullmatch(fields[3]):
            raise ValueError("invalid pre-push record")
        local, previous = fields[1], fields[3]
        if not local.strip(b"0"):  # Ref deletion transfers no content.
            continue
        tips.add(local)
        if previous.strip(b"0"):
            # A remote tip need not exist locally after a forced update.
            try:
                git("cat-file", "-e", previous.decode() + "^{commit}")
            except subprocess.CalledProcessError:
                continue
            excluded.add(previous)
    if not tips:
        return
    revisions = b"\n".join(sorted(tips) + [b"^" + oid for oid in sorted(excluded)]) + b"\n"
    # Skip commits reachable from any remote-tracking ref, whichever remote this push names; content is not matched.
    for entry in git("rev-list", "--parents", "--stdin", "--not", "--remotes", data=revisions).splitlines():
        commit, *parents = entry.decode().split()
        if parents:
            yield new_lines([added_lines("diff-tree", "-r", parent, commit) for parent in parents])
        else:
            yield added_lines("diff-tree", "-r", "--root", "--no-commit-id", commit)


def refused(added):
    for path, lines in added.items():
        for line in lines:
            if any(shape.search(line) for shape in SHAPES):
                yield path, hashlib.sha256(line).hexdigest()


def repeat(guard, fingerprints):
    try:
        state = git("rev-parse", "--git-path", "fm-" + guard + ".refusals").rstrip(b"\n")
        if fingerprints is not None and not fingerprints:
            if os.path.exists(state):
                os.remove(state)
            return 1
        try:
            with open(state, "r", encoding="utf-8") as counter:
                previous = json.load(counter)
            if not isinstance(previous, dict):
                previous = {}
        except (OSError, ValueError):
            previous = {}
        if fingerprints is None:
            counts, fingerprints = dict(previous), {INSPECTION_FAILED}
        else:
            counts = {}
        for fingerprint in fingerprints:
            count = previous.get(fingerprint, 0)
            counts[fingerprint] = count + 1 if type(count) is int and count >= 0 else 1
        with open(state, "w", encoding="utf-8") as counter:
            json.dump(counts, counter, sort_keys=True)
            counter.write("\n")
        return max(counts[fingerprint] for fingerprint in fingerprints)
    except (OSError, subprocess.SubprocessError):
        return 1


def record(guard, decision, source_ok, started, count):
    elapsed = str(int((time.monotonic() - started) * 1000))
    try:
        subprocess.run([EVENT_WRITER, guard, decision, "--source-ok", source_ok, "--elapsed-ms", elapsed,
                        "--repeat", str(count)],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, check=False)
    except OSError:
        pass


def main():
    args = sys.argv[1:]
    if args in (["--help"], ["-h"]):
        print(__doc__)
        return 0
    if args == ["pre-commit"]:
        inspections = staged_lines
    elif len(args) == 3 and args[0] == "pre-push":
        inspections = outgoing_lines
    else:
        print("error: expected pre-commit or pre-push <remote-name> <remote-location>")
        return 2
    guard, started = GUARDS[args[0]], time.monotonic()
    try:
        paths, fingerprints = set(), set()
        for added in inspections():
            for path, fingerprint in refused(added):
                paths.add(path)
                fingerprints.add(fingerprint)
        paths, source_ok = sorted(paths), "true"
    except (OSError, ValueError, subprocess.SubprocessError):
        paths, fingerprints, source_ok = None, None, "false"
    denied = paths is None or bool(paths)
    count = repeat(guard, fingerprints)
    record(guard, "deny" if denied else "allow", source_ok, started, count)
    if not denied:
        return 0
    if paths is None:
        print("error: credential inspection failed; commit or push refused")
        print("help: Restore readable Git objects and an available python3 runtime, then retry.")
    else:
        print("error: credential-shaped content in lines that staged or outgoing commits add")
        print(f"files[{len(paths)}]: " + ", ".join(json.dumps(path.decode('utf-8', 'surrogateescape'), ensure_ascii=True) for path in paths))
        print("help: Remove credentials from the added lines; keep local secrets in ignored files or a secret store.")
        print("cause: if a named line came from a cherry-pick, revert or squash of a commit already on a remote, "
              "this refusal is false: only commits reachable from a remote-tracking ref are skipped, not content.")
        print("next: in that case, escalate to Firstmate naming the file and line; Firstmate can confirm the line is already on origin.")
    if count > BUDGET:
        print(f"escalate: this check refused {count} times in a row, past its budget of {BUDGET}; "
              "stop retrying and report the refusal to Firstmate for a human decision. "
              "The commit or push stays refused until inspection succeeds and finds no new credential-shaped line.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
