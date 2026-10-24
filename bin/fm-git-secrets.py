#!/usr/bin/env python3
"""Check lines that staged or outgoing commits add, using conservative credential shapes.

Usage: fm-git-secrets.py pre-commit
       fm-git-secrets.py pre-push <remote-name> <remote-location>
Only content new relative to every parent is inspected: the lines the staged
index adds against HEAD and each MERGE_HEAD, and the lines each outgoing commit
adds against all of its parents. Outgoing commits are those reachable from the
pushed tips but not from an advertised old tip or any remote-tracking ref, so
history already on a remote is not inspected again. Pre-push consumes Git's
ref-update records on stdin; the hook wrapper preserves those bytes for the
repository's own hook. No file content or match is printed, no provider is
called, and no working-tree file is read. Each decision appends one event
through fm-guard-event.sh. Exit 1 refuses the Git operation, including when
inspection fails; exit 2 indicates invalid arguments.
"""

import codecs
import json
import os
import re
import subprocess
import sys
import time


SHAPES = tuple(re.compile(pattern) for pattern in (
    rb"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY(?: BLOCK)?-----",
    rb"(?<![A-Za-z0-9_-])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{16,})",
    # Consume a complete scheme-character run without restarting at hyphens.
    rb'''(?i)(?<![a-z0-9+.-])[a-z0-9+.-]+://[^\s/:@?#"'`<>()\[\]{}\\,;|]*:[^\s/@?#"'`<>()\[\]{}\\,;|]{8,}@''',
))
OID = re.compile(rb"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
GUARDS = {"pre-commit": "git-commit-credential-shapes", "pre-push": "git-push-credential-shapes"}
EVENT_WRITER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-guard-event.sh")
# Whole-line patches with fixed prefixes, independent of user diff settings.
DIFF = ("-p", "--text", "-U0", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
        "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--diff-filter=ACMT")


def git(*args, data=None):
    return subprocess.run(["git", *args], input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, check=True).stdout


def added_lines(*args):
    added, path, body = {}, None, False
    for line in git(*args, *DIFF).split(b"\n"):
        if line.startswith(b"diff --git "):
            path, body = None, False
        elif body:
            if line.startswith(b"+") and path is not None:
                added.setdefault(path, set()).add(line[1:])
        elif line.startswith(b"@@ "):
            body = True
        elif line.startswith(b"+++ "):
            # Git appends a tab to a name containing a space and C-quotes others.
            name = line[4:].removesuffix(b"\t")
            if name.startswith(b'"'):
                name = codecs.escape_decode(name[1:-1])[0]
            path = name[2:] if name.startswith(b"b/") else None
    return added


def new_lines(diffs):
    first, *rest = diffs
    return {path: lines.intersection(*(other.get(path, ()) for other in rest))
            for path, lines in first.items()}


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
    # Content already on any remote is not new exposure, whichever remote this push names.
    for entry in git("rev-list", "--parents", "--stdin", "--not", "--remotes", data=revisions).splitlines():
        commit, *parents = entry.decode().split()
        if parents:
            yield new_lines([added_lines("diff-tree", "-r", parent, commit) for parent in parents])
        else:
            yield added_lines("diff-tree", "-r", "--root", "--no-commit-id", commit)


def refused(added):
    return {path for path, lines in added.items()
            if any(shape.search(b"\n".join(lines)) for shape in SHAPES)}


def record(guard, decision, source_ok, started):
    elapsed = str(int((time.monotonic() - started) * 1000))
    try:
        subprocess.run([EVENT_WRITER, guard, decision, "--source-ok", source_ok, "--elapsed-ms", elapsed],
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
        paths = sorted(set().union(*(refused(added) for added in inspections())))
    except (OSError, ValueError, subprocess.SubprocessError):
        record(guard, "deny", "false", started)
        print("error: credential inspection failed; commit or push refused")
        print("help: Restore readable Git objects and an available python3 runtime, then retry.")
        return 1
    record(guard, "deny" if paths else "allow", "true", started)
    if paths:
        print("error: credential-shaped content in lines that staged or outgoing commits add")
        print(f"files[{len(paths)}]: " + ", ".join(json.dumps(path.decode('utf-8', 'surrogateescape'), ensure_ascii=True) for path in paths))
        print("help: Remove credentials from the added lines; keep local secrets in ignored files or a secret store.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
