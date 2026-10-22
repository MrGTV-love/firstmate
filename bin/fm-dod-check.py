#!/usr/bin/env python3
"""Validate and execute machine-checkable task criteria.

Usage:
  fm-dod-check.py validate --dod FILE
  fm-dod-check.py run --dod FILE --repo DIR --base SHA --head SHA --output DIR

The item format is owned by fm_task_dod_block in bin/fm-dod-lib.sh.
Check is a single-line bash command, optionally enclosed in one pair of backticks.
Test paths named anywhere in an item's fields use tests/<name>.test.sh.
For changed named tests, the HEAD test is overlaid onto an exported base tree:
absence of a new test on base is not fail-first proof. Other files stay at base.
Both trees are git archives of exact full commits, never the caller's dirty tree.
The output directory must not exist; it holds command logs and results.json,
bound to the DoD digest, commits and GitHub run. Logs include exit codes and
SHA-256 digests. Commands run without forge credentials on a disposable runner.
A nonzero base exit and zero head exit are required for every changed named test.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import tempfile


class CheckError(Exception):
    """Invalid criteria or unavailable commit evidence."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def items_from(text):
    items = []
    current = None
    mandatory = False
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if marker:
            token = marker[1]
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        if fence:
            continue
        if re.search(r"\{DOD_[A-Z_]+\}", line):
            raise CheckError("task DoD still holds scaffold placeholders")
        heading = re.match(r"^(#{1,6})\s+(.*)", line)
        if heading:
            current = None
            if len(heading[1]) <= 3:
                mandatory = heading[2].strip().casefold() == "mandatory items"
            continue
        item = re.match(r"^- \*\*([A-Za-z][A-Za-z0-9_.-]*)\*\*\s+(.+)", line)
        if item:
            current = {"id": item[1], "mandatory": mandatory or "*(mandatory)*" in item[2], "fields": {}, "text": line}
            items.append(current)
            continue
        if current is not None:
            current["text"] += "\n" + line
            field = re.match(r"^\s+- (Verify|Authority|Check):\s*(.*)$", line)
            if field:
                name, value = field.groups()
                if name in current["fields"]:
                    raise CheckError(f"{current['id']}: duplicate {name}")
                current["fields"][name] = value.strip()
    seen = set()
    required = []
    for item in items:
        if item["id"] in seen:
            raise CheckError(f"duplicate DoD id: {item['id']}")
        seen.add(item["id"])
        item["tests"] = sorted(set(re.findall(r"(?<![\w/.-])(tests/[A-Za-z0-9_./-]+\.test\.sh)(?![\w/.-])", item["text"])))
        for path in item["tests"]:
            if ".." in PurePosixPath(path).parts:
                raise CheckError(f"{item['id']}: unsafe test path {path}")
        if not item["mandatory"]:
            continue
        fields = item["fields"]
        if not fields.get("Verify"):
            raise CheckError(f"{item['id']}: mandatory item requires Verify")
        authority = fields.get("Authority")
        if authority not in ("agent", "gate", "grader"):
            raise CheckError(f"{item['id']}: Authority must be agent, gate, or grader")
        command = fields.get("Check", "")
        if command.startswith("`") and command.endswith("`"):
            command = command[1:-1]
        if authority == "gate" and not command.strip():
            raise CheckError(f"{item['id']}: Authority gate requires an exact Check command")
        item["command"] = command
        required.append(item)
    if not required:
        raise CheckError("task DoD requires at least one mandatory item with Verify")
    return items


def git(repo, *args):
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=False)
    if result.returncode:
        raise CheckError(f"git {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def commit(repo, value):
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value):
        raise CheckError("base and head must be exact full commit shas")
    resolved = git(repo, "rev-parse", "--verify", f"{value}^{{commit}}").decode().strip()
    if resolved != value:
        raise CheckError(f"commit did not resolve exactly: {value}")
    return resolved


def export(repo, sha, destination):
    destination.mkdir()
    with tarfile.open(fileobj=io.BytesIO(git(repo, "archive", sha))) as archive:
        # Git archives can contain repository-controlled symlinks. The data
        # filter rejects links escaping the exported tree before any execution.
        archive.extractall(destination, filter="data")


def execute(command, cwd, output, name, context):
    log = output / f"{name}.log"
    # No token, credentials, or Actions control-file paths go to PR commands.
    environment = {key: value for key, value in os.environ.items()
                   if key in ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "SYSTEMROOT")}
    environment.update(FM_DOD_HEAD=context["head"], FM_DOD_BASE=context["base"])
    print(f"command: {json.dumps(command)}", flush=True)
    with log.open("wb") as stream:
        stream.write(f"command: {command}\ncommit: {context['commit']}\n".encode())
        stream.flush()
        result = subprocess.run(["bash", "-o", "pipefail", "-c", command], cwd=cwd,
                                env=environment, stdout=stream, stderr=subprocess.STDOUT, check=False)
        stream.write(f"\nexit: {result.returncode}\n".encode())
    print(f"exit: {result.returncode}\nlog: {json.dumps(log.name)}", flush=True)
    return {"command": command, "commit": context["commit"], "exit": result.returncode,
            "log": log.name, "sha256": digest(log.read_bytes())}


def run(args, raw, items):
    repo = args.repo.resolve()
    base, head = commit(repo, args.base), commit(repo, args.head)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    changed = set(git(repo, "diff", "--name-only", "-z", base, head, "--", "tests").decode().split("\0"))
    manifest = {"schema": "fm-dod-evidence.v1", "head": head, "base": base,
                "dod_sha256": digest(raw), "run_id": os.environ.get("GITHUB_RUN_ID", ""),
                "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""), "items": [], "tests": []}
    passed = True
    print(f"head: {head}\nbase: {base}\ndod_sha256: {manifest['dod_sha256']}", flush=True)
    with tempfile.TemporaryDirectory(prefix="fm-dod-") as scratch:
        scratch = Path(scratch)
        head_tree = scratch / "head"
        export(repo, head, head_tree)
        # Commands can mutate their tree. Each test receives a fresh base and
        # head export so a previous command cannot manufacture a pass/failure.
        for item in items:
            if item["mandatory"] and item["fields"]["Authority"] == "gate":
                tree = scratch / f"gate-{item['id']}"
                export(repo, head, tree)
                result = execute(item["command"], tree, output, f"gate-{item['id']}",
                                 {"head": head, "base": base, "commit": head})
                result["id"] = item["id"]
                manifest["items"].append(result)
                passed = result["exit"] == 0 and passed
        named = sorted({path for item in items for path in item["tests"] if path in changed})
        for index, path in enumerate(named):
            source = head_tree / path
            if source.is_symlink() or not source.is_file():
                raise CheckError(f"changed named test is absent or a symlink at head: {path}")
            result = {"path": path}
            for phase, sha in (("base", base), ("head", head)):
                tree = scratch / f"test-{index}-{phase}"
                export(repo, sha, tree)
                target = tree / path
                if target.is_symlink() or any(parent.is_symlink() for parent in target.parents):
                    raise CheckError(f"test path traverses a symlink: {path}")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read_bytes())
                result[phase] = execute(f"bash {path}", tree, output, f"test-{index}-{phase}",
                                        {"head": head, "base": base, "commit": sha})
            result["passed"] = result["base"]["exit"] != 0 and result["head"]["exit"] == 0
            passed = result["passed"] and passed
            manifest["tests"].append(result)
            print(f"test: {json.dumps(path)}\nfail_first: {'pass' if result['passed'] else 'fail'}", flush=True)
    manifest["passed"] = passed
    (output / "results.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"result: {'pass' if passed else 'fail'}", flush=True)
    return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("validate", "run"):
        command = sub.add_parser(action)
        command.add_argument("--dod", type=Path, required=True)
        if action == "run":
            command.add_argument("--repo", type=Path, required=True)
            command.add_argument("--base", required=True)
            command.add_argument("--head", required=True)
            command.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        raw = args.dod.read_bytes()
        items = items_from(raw.decode())
        if args.action == "run":
            return run(args, raw, items)
        print(f"result: valid\nmandatory_items: {sum(item['mandatory'] for item in items)}\ndod_sha256: {digest(raw)}")
        return 0
    except (CheckError, OSError, ValueError, tarfile.TarError) as exc:
        print(f"error: {json.dumps(str(exc))}\nhelp: Supply filled criteria with Verify and an exact Check for each gate item.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
