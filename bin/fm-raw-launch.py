#!/usr/bin/env python3
"""Read a raw launch command's shell words without evaluating or expanding them.

Usage: fm-raw-launch.py mark-claude COMMAND
       fm-raw-launch.py root NAME COMMAND CWD

mark-claude prints COMMAND with __CLAUDERAWSESSION__ inserted right after each
claude program word: the first word, after leading NAME=value assignments, of
every command the line starts, where commands are separated by an unquoted
newline, ;, &, |, &&, ||, ( or ). Quoted text is never marked, so a prompt that
mentions claude keeps its bytes. A program word may carry the
__CLAUDERAWPREFIX__ placeholder fm-spawn.sh splices before it.

root prints the absolute path a single leading NAME=value assignment of the
first command sets, with its quotes removed and a relative value resolved
against CWD. It exits 1 when NAME is not assigned that way and 3, naming NAME on
stderr, when the value needs shell expansion ($, a backquote or a leading ~),
is empty, or NAME is assigned again by a later command.
Malformed quoting exits 2.
"""
import os
import re
import sys

OPERATORS = "\n;&|()"
PREFIX = "__CLAUDERAWPREFIX__"
MARK = "__CLAUDERAWSESSION__"
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


def words(text):
    """Yield (kind, start, end, value, expands) for each word and operator."""
    i, n = 0, len(text)
    while i < n:
        if text[i] in " \t":
            i += 1
            continue
        if text[i] in OPERATORS:
            start = i
            while i < n and text[i] in OPERATORS:
                i += 1
            yield "op", start, i, text[start:i], False
            continue
        start, value, expands = i, [], False
        while i < n and text[i] not in " \t" + OPERATORS:
            char = text[i]
            if char == "'":
                end = text.find("'", i + 1)
                if end < 0:
                    raise ValueError("unterminated single quote")
                value.append(text[i + 1:end])
                i = end + 1
            elif char == '"':
                i += 1
                while i < n and text[i] != '"':
                    if text[i] == "\\" and i + 1 < n and text[i + 1] in '$`"\\\n':
                        value.append(text[i + 1])
                        i += 2
                        continue
                    expands = expands or text[i] in "$`"
                    value.append(text[i])
                    i += 1
                if i >= n:
                    raise ValueError("unterminated double quote")
                i += 1
            elif char == "\\":
                value.append(text[i + 1:i + 2])
                i += 2
            else:
                expands = expands or char in "$`"
                value.append(char)
                i += 1
        yield "word", start, i, "".join(value), expands


def commands(text):
    """Yield each command as its list of words, split at operators."""
    current = []
    for token in words(text):
        if token[0] == "op":
            yield current
            current = []
        else:
            current.append(token)
    yield current


def mark_claude(text):
    marks = []
    for command in commands(text):
        for kind, start, end, value, expands in command:
            if ASSIGNMENT.match(text[start:end]):
                continue
            if os.path.basename(value[len(PREFIX):] if value.startswith(PREFIX) else value) == "claude":
                marks.append(end)
            break
    for end in reversed(marks):
        text = text[:end] + MARK + text[end:]
    return text


def root(name, text, cwd):
    found = []
    for index, command in enumerate(commands(text)):
        for kind, start, end, value, expands in command:
            raw = text[start:end]
            if not ASSIGNMENT.match(raw):
                break
            if raw.startswith(name + "="):
                found.append((index, raw[len(name) + 1:], value[len(name) + 1:], expands))
    if not found:
        return 1, None
    index, raw_value, value, expands = found[0]
    if len(found) > 1 or index != 0 or expands or raw_value.startswith("~") or value == "":
        return 3, None
    return 0, os.path.abspath(os.path.join(cwd, value))


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "mark-claude":
            print(mark_claude(argv[2]), end="")
            return 0
        if len(argv) == 5 and argv[1] == "root":
            status, path = root(argv[2], argv[3], argv[4])
            if status == 3:
                print(f"{argv[2]} needs shell expansion or is not one leading literal assignment", file=sys.stderr)
            if path:
                print(path)
            return status
    except ValueError as error:
        print(f"malformed raw launch command: {error}", file=sys.stderr)
        return 2
    print(__doc__.split("\n\n")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
