#!/usr/bin/env python3
"""Flag potential test weakening for an independent reviewer's explicit ruling.

Usage: fm-test-weakening.py --repo DIR --base SHA --head SHA [--output FILE]

Reads an exact-commit git diff, with renames disabled so a move cannot hide a
removed test. Deliberately conservative: any deleted non-comment test/fixture
line is flagged, including data rows and test bodies without an assert keyword.
Assertion removals in other files and increased numeric time/retry/iteration
bounds are also flagged. This is a review signal, not a design-quality verdict.
Flags identify the base file:line and old/new content digest, so a ruling for a
different line or revision cannot cover them. JSON is only the artifact format;
stdout lists actionable file:line flags. Exit 1 means review rulings are needed,
2 means invalid input/unreadable diff, and 0 means no suspicious changes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ASSERTION = re.compile(r"\b(assert\w*|expect|should|fail|verify|check)\b|\[\[?|\btest\s", re.I)
BOUND = re.compile(r"\b(?:\w*(?:timeout|deadline|retry|retries|attempt|iteration|poll|limit|bound|duration|sleep|elapsed|interval)\w*|range|seq)\b|(?:-lt|-le|<=|<)\s*\d", re.I)
NUMBER = re.compile(r"(?<![\w.])\d+(?:\.\d+)?(?![\w.])")


def test_path(path):
    parts = Path(path).parts
    return any(part.casefold() in ("test", "tests", "fixture", "fixtures", "__tests__", "testdata") for part in parts) or bool(re.search(r"[._](test|spec)\.", path))


def code(line):
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith(("#", "//", "/*", "*", "<!--"))


def flags_from(patch):
    flags = []
    file = None
    old_line = new_line = 0
    in_hunk = False
    removed = []
    added = []

    def flush():
        for line_number, line in removed:
            reason = None
            replacement = ""
            if code(line) and test_path(file):
                reason = "removed test or fixture code/row"
            elif code(line) and ASSERTION.search(line):
                reason = "removed assertion/check"
            # Match a line's nonnumeric skeleton. This includes changes in
            # Python range(), shell seq, and loop comparison bounds.
            if code(line):
                old_values = [float(value) for value in NUMBER.findall(line)]
                skeleton = NUMBER.sub("<number>", line).strip().casefold()
                for _, candidate in added:
                    same_expression = NUMBER.sub("<number>", candidate).strip().casefold() == skeleton
                    # Also flag bound expressions rewritten into a different
                    # shape; a reviewer decides whether this really weakens it.
                    rewritten_bound = BOUND.search(line) and BOUND.search(candidate)
                    if not same_expression and not rewritten_bound:
                        continue
                    values = [float(value) for value in NUMBER.findall(candidate)]
                    if same_expression and len(values) == len(old_values):
                        raised = any(new > old for old, new in zip(old_values, values))
                    else:
                        raised = bool(values and old_values and max(values) > max(old_values))
                    if raised:
                        reason = "increased time/retry/iteration bound"
                        replacement = candidate
                        break
            if reason:
                identity = json.dumps([file, line_number, line, replacement], separators=(",", ":"))
                flags.append({"id": hashlib.sha256(identity.encode()).hexdigest(), "file": file,
                              "line": line_number, "reason": reason, "old": line, "new": replacement})
        removed.clear()
        added.clear()

    for line in patch.splitlines():
        if line.startswith("diff --git "):
            flush()
            file = None
            in_hunk = False
        elif line.startswith("--- ") and not in_hunk:
            source = line[4:].removesuffix("\t")
            if source != "/dev/null":
                if source.startswith('"'):
                    source = json.loads(source)
                file = source.removeprefix("a/")
        elif line.startswith("+++ ") and not in_hunk:
            if file is None:
                target = line[4:].removesuffix("\t")
                if target.startswith('"'):
                    target = json.loads(target)
                file = target.removeprefix("b/")
        elif line.startswith("@@ "):
            flush()
            match = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
            if not match:
                raise ValueError("invalid diff hunk")
            old_line, new_line = map(int, match.groups())
            in_hunk = True
        elif line.startswith("-") and file:
            removed.append((old_line, line[1:]))
            old_line += 1
        elif line.startswith("+") and file:
            added.append((new_line, line[1:]))
            new_line += 1
        elif line.startswith(" "):
            old_line += 1
            new_line += 1
    flush()
    return flags


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        for sha in (args.base, args.head):
            if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha):
                raise ValueError("base and head must be exact full commit shas")
        result = subprocess.run(["git", "-C", str(args.repo), "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                                 "--unified=3", args.base, args.head, "--"], capture_output=True, text=True, check=False)
        if result.returncode:
            raise ValueError(result.stderr.strip())
        flags = flags_from(result.stdout)
        record = {"schema": "fm-test-weakening.v1", "base": args.base, "head": args.head, "flags": flags}
        if args.output:
            args.output.write_text(json.dumps(record, indent=2) + "\n")
        print(f"flags: {len(flags)}")
        for flag in flags:
            print(f"flag: {json.dumps(flag['file'] + ':' + str(flag['line']))}\nreason: {json.dumps(flag['reason'])}\nid: {flag['id']}")
        return 1 if flags else 0
    except (OSError, ValueError) as exc:
        print(f"error: {json.dumps(str(exc))}\nhelp: Supply readable repository and exact base/head commits.")
        return 2


if __name__ == "__main__":
    sys.exit(main())
