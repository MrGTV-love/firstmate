#!/usr/bin/env python3
"""Check staged or outgoing Git blobs using conservative credential shapes.

Usage: fm-git-secrets.py pre-commit
       fm-git-secrets.py pre-push <remote-name> <remote-location>
Pre-push consumes Git's ref-update records on stdin; the hook wrapper preserves
those bytes for the repository's own hook. No file content or match is printed,
no provider is called, and no working-copy file is read. Exit 1 refuses the Git
operation, including when inspection fails; exit 2 indicates invalid arguments.
"""

import json
import re
import subprocess
import sys


SHAPES = tuple(re.compile(pattern) for pattern in (
    rb"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY(?: BLOCK)?-----",
    rb"(?<![A-Za-z0-9_-])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{16,})",
    # Consume a complete scheme-character run without restarting at hyphens.
    rb'''(?i)(?<![a-z0-9+.-])[a-z0-9+.-]+://[^\s/:@?#"'`<>()\[\]{}\\,;|]*:[^\s/@?#"'`<>()\[\]{}\\,;|]{8,}@''',
))
OID = re.compile(rb"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")


def git(*args, data=None):
    return subprocess.run(["git", *args], input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, check=True).stdout


def changed_blobs(*args):
    fields = git(*args, "--raw", "-z", "--no-abbrev", "--no-renames",
                 "--no-ext-diff", "--no-textconv", "--diff-filter=ACMT").split(b"\0")
    for index in range(0, len(fields) - 1, 2):
        header, path = fields[index:index + 2]
        old_mode, mode, old_oid, oid, status = header.split()
        if mode != b"160000":  # A submodule points to a commit, not a blob.
            yield oid, path


def outgoing_commits(remote):
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
        return []
    revisions = b"\n".join(sorted(tips) + [b"^" + oid for oid in sorted(excluded)]) + b"\n"
    # Existing remote-tracking refs are the baseline for a new remote branch.
    return git("rev-list", "--stdin", "--not", "--remotes=" + remote,
               data=revisions).splitlines()


def scan(blobs):
    checked, refused = set(), set()
    process = subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        for oid, path in blobs:
            if oid not in checked:
                process.stdin.write(oid + b"\n")
                process.stdin.flush()
                header = process.stdout.readline().split()
                if len(header) != 3 or header[1] != b"blob":
                    raise ValueError("cannot inspect Git blob")
                size = int(header[2])
                content = process.stdout.read(size)
                if len(content) != size or process.stdout.read(1) != b"\n":
                    raise ValueError("incomplete Git blob")
                checked.add(oid)
                if any(shape.search(content) for shape in SHAPES):
                    refused.add(oid)
            if oid in refused:
                yield path
    finally:
        process.stdin.close()
        process.stdout.close()
        if process.wait() != 0:
            raise ValueError("Git blob inspection failed")


def main():
    args = sys.argv[1:]
    if args in (["--help"], ["-h"]):
        print(__doc__)
        return 0
    if args == ["pre-commit"]:
        blobs = changed_blobs("diff", "--cached")
    elif len(args) == 3 and args[0] == "pre-push":
        commits = outgoing_commits(args[1])
        blobs = (blob for commit in commits for blob in
                 changed_blobs("diff-tree", "--root", "-r", "-m", "--no-commit-id", commit.decode()))
    else:
        print("error: expected pre-commit or pre-push <remote-name> <remote-location>")
        return 2
    paths = sorted(set(scan(blobs)))
    if paths:
        print("error: credential-shaped content in staged or outgoing files")
        print(f"files[{len(paths)}]: " + ", ".join(json.dumps(path.decode('utf-8', 'surrogateescape'), ensure_ascii=True) for path in paths))
        print("help: Remove credentials from the staged content or outgoing commits; keep local secrets in ignored files or a secret store.")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError):
        print("error: credential inspection failed; commit or push refused")
        print("help: Restore readable Git objects and an available python3 runtime, then retry.")
        sys.exit(1)
