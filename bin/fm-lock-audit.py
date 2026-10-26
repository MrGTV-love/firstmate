#!/usr/bin/env python3
"""Audit literal shell lock intervals for slow work, including local callees.

Usage: fm-lock-audit.py [--base REF] [--report] [PATH ...]
Default: bin/*.sh and bin/backends/*.sh, compared with the merge base against
origin/main (or main). Existing findings are printed as follow-ups; only new
findings fail. --report inventories all findings without grandfathering any in
silence. --base is explicit in fixtures and release review.

This is a conservative static check, not a shell interpreter: it follows named
shell functions and literal commands, not eval, dynamic dispatch or external
program internals. Runtime hold measurements remain the authority for those.
Heredoc data and comments are not shell commands. Acquisition failure arms and
lock primitive retry loops do not mean that a lock has been acquired.
"""
import argparse
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
import re
import shlex
import subprocess
import sys

ACQUIRE = {"fm_lock_acquire_wait", "fm_lock_try_acquire", "fm_lock_try_create",
           "fm_lock_acquire_wait_max", "fm_lock_acquire_wait_bounded",
           "fm_project_lock_acquire", "fm_project_lock_try"}
RELEASE = {"fm_lock_release", "fm_project_lock_release"}
SLOW = {"gh", "gh-axi", "curl", "no-mistakes", "fm-send", "fm-send.sh", "sleep",
        "claude", "codex", "pi", "omp", "opencode", "kimi", "gemini", "grok",
        "fm-hyper-jev.sh", "fm-model-call.sh"}
FUNCTION = re.compile(r"^\s*(?:function\s+)?([\w-]+)\s*\(\s*\)\s*\{")
CASE_WORD = r'''(?:[^\s|()'"`]|'[^']*'|"(?:[^"\\]|\\.)*")+'''
CASE_LABEL = re.compile(rf"^\s*{CASE_WORD}(?:\s*\|\s*{CASE_WORD})*\s*\)\s*")


@dataclass(frozen=True)
class Command:
    path: str
    line: int
    function: str
    words: tuple
    text: str
    failure: bool = False

    @property
    def name(self):
        return self.words[0].rsplit("/", 1)[-1]


def commands(path, text):
    function = "<top>"
    heredoc = None
    case_depth = 0
    for number, raw in enumerate(text.splitlines(), 1):
        if heredoc is not None:
            if raw.strip() == heredoc:
                heredoc = None
            continue
        found = FUNCTION.match(raw)
        if found:
            function = found[1]
            case_depth = 0
            raw = raw[found.end():]
        if raw == "}":
            function = "<top>"
            case_depth = 0
            continue
        # Existing scripts use literal heredoc delimiters for data and child
        # programs. Child shell entry points are audited in their own source.
        here = re.search(r"<<-?\s*['\"]?([A-Za-z_][\w]*)['\"]?", raw)
        if here:
            heredoc = here[1]
            raw = raw[:here.start()]
        # A case pattern names alternatives, not commands. Retain an inline
        # arm body, so `curl) sleep 1 ;;` still audits the sleep.
        if case_depth:
            raw = CASE_LABEL.sub("", raw)
        try:
            lexer = shlex.shlex(raw, posix=True, punctuation_chars=";&|(){}")
            lexer.whitespace_split = True
            words = list(lexer)
        except ValueError:
            # Multiline quoted payloads are data to this lexical pass. They
            # must not accidentally become commands in the enclosing scope.
            continue
        chunk = []
        failure = bool(re.search(r"\b(?:while|until|if)\s+!\s+fm_(?:lock|project_lock)_", raw))
        for word in words + [";"]:
            if word and all(c in ";&|(){}" for c in word):
                while chunk and (chunk[0] in {"if", "then", "elif", "else", "while", "until", "do", "!", "command", "exec", "env", "time"} or re.match(r"^[A-Za-z_]\w*=", chunk[0])):
                    chunk.pop(0)
                if chunk:
                    if chunk[0] == "case":
                        case_depth += 1
                    elif chunk[0] == "esac":
                        case_depth = max(0, case_depth - 1)
                    yield Command(path, number, function, tuple(chunk), raw.strip(), failure)
                chunk = []
            else:
                chunk.append(word)


def slow(command):
    name = command.name
    if name in SLOW or re.search(r"(?:model|provider).*(?:call|invoke|request)|(?:call|invoke|request).*(?:model|provider)", name):
        return name
    if name == "git":
        arguments = iter(command.words[1:])
        for word in arguments:
            if word in {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"}:
                next(arguments, None)
            elif not word.startswith("-"):
                return "git fetch/push" if word in {"fetch", "push"} else None
    return None


def findings(sources):
    entries = [c for path, text in sources.items() for c in commands(path, text)]
    functions = {}
    for c in entries:
        if c.function != "<top>":
            functions.setdefault((c.path, c.function), []).append(c)
    # A callee that manages locks is checked in its own intervals rather than
    # flattened into every caller: its acquisition retry sleep is not evidence
    # that its successful critical section sleeps. Plain local wrappers still
    # propagate their slow work. This is a lexical audit, not an interprocedural
    # proof of dynamic lock nesting; measurements cover that boundary.
    manages = {name for name, body in functions.items() if any(c.name in ACQUIRE or c.name in RELEASE for c in body)}
    for _ in range(len(functions) + 1):
        expanded = manages | {name for name, body in functions.items() if any((c.path, c.name) in manages for c in body)}
        if expanded == manages:
            break
        manages = expanded
    summaries = {name: set(filter(None, (slow(c) for c in body))) for name, body in functions.items() if name not in manages}
    for _ in range(len(functions) + 1):
        changed = False
        for name, body in functions.items():
            if name not in summaries:
                continue
            before = len(summaries[name])
            for c in body:
                summaries[name].update(summaries.get((c.path, c.name), ()))
            changed |= before != len(summaries[name])
        if not changed:
            break
    result = []
    held = {}
    for c in entries:
        scope = (c.path, c.function)
        locks = held.setdefault(scope, set())
        name = c.name
        if name in RELEASE:
            if len(c.words) > 1:
                locks.discard(c.words[1])
            continue
        if locks:
            reasons = {slow(c)} if slow(c) else summaries.get((c.path, name), set())
            for reason in sorted(reasons):
                result.append((c, reason))
        if name in ACQUIRE and not c.failure and len(c.words) > 1:
            locks.add(c.words[1])
    return result


def git(*args):
    return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base")
    parser.add_argument("--report", action="store_true")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    paths = args.paths or sorted(str(p) for pattern in ("bin/*.sh", "bin/backends/*.sh") for p in Path().glob(pattern))
    paths = [str(Path(p).resolve().relative_to(Path.cwd().resolve())) if Path(p).resolve().is_relative_to(Path.cwd().resolve()) else p for p in paths]
    sources = {p: Path(p).read_text() for p in paths}
    base = args.base
    if not base and not args.report:
        for candidate in ("origin/main", "main"):
            try:
                base = git("merge-base", "HEAD", candidate)
                break
            except subprocess.CalledProcessError:
                pass
    old = {}
    if base:
        for p in paths:
            try:
                old[p] = git("show", f"{base}:{p}")
            except subprocess.CalledProcessError:
                pass
    def key(c, reason):
        return (c.path, c.function, c.text, reason)
    baseline = Counter(key(c, reason) for c, reason in findings(old))
    failed = False
    for c, reason in findings(sources):
        identity = key(c, reason)
        existing = baseline[identity] > 0
        baseline[identity] -= existing
        label = "existing follow-up" if existing else "locked slow work"
        print(f"{c.path}:{c.line}: {label}: {c.name} -> {reason} ({c.function})")
        failed |= not existing
    return 0 if args.report else int(failed)


if __name__ == "__main__":
    sys.exit(main())
