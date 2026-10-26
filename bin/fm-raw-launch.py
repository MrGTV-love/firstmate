#!/usr/bin/env python3
"""Read a raw launch command's shell words without evaluating or expanding them.

Usage: fm-raw-launch.py render-claude COMMAND SESSION_ID PREFIX
       fm-raw-launch.py root NAME COMMAND CWD

render-claude inserts the session argument after each literal claude program
word, forks resumed or continued sessions into that id and prefixes only the
first claude invocation; empty SESSION_ID and PREFIX only validate the command.
It splices original source spans, preserving
quoted data, comments and here-document bodies. Here-documents support literal,
single/double-quoted delimiters and <<- tab stripping, including multiple bodies.
Command/process substitutions, here-strings and shell control structures refuse
with a remedy rather than guessing; unterminated quotes/documents also refuse.

root prints the absolute path a single leading NAME=value assignment of the
first command sets, with its quotes removed and a relative value resolved
against CWD. It exits 1 when NAME is not assigned that way and 3, naming NAME on
stderr, when the value needs shell expansion ($, a backquote or a leading ~),
is empty, or NAME is assigned again by a later command.
Malformed or unsupported shell text exits 2 without emitting a rewritten command.
"""
import os
import re
import sys

OPERATORS = "\n;&|()"
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


def refuse(construct):
    raise ValueError(f"{construct}; use a named harness or simplify the raw launch to literal shell commands")


def word(text, i):
    """Read one literal/expanded word, without executing shell text."""
    start, value, expands = i, [], False
    n = len(text)
    while i < n and text[i] not in " \t\n;&|()<>":
        char = text[i]
        if text.startswith("$(", i) or text.startswith("${", i):
            refuse("command substitution or braced expansion")
        if char == "`":
            refuse("backtick command substitution")
        if char == "$" and i + 1 < n and text[i + 1] in "'\"":
            refuse("dollar-quoted string")
        if char == "'":
            end = text.find("'", i + 1)
            if end < 0:
                refuse("unterminated single quote")
            value.append(text[i + 1:end])
            i = end + 1
        elif char == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n and text[i + 1] in '$`"\\\n':
                    if text[i + 1] != "\n":
                        value.append(text[i + 1])
                    i += 2
                    continue
                if text.startswith("$(", i) or text.startswith("${", i):
                    refuse("command substitution or braced expansion in double quote")
                if text[i] == "`":
                    refuse("backtick command substitution in double quote")
                expands = expands or text[i] == "$"
                value.append(text[i])
                i += 1
            if i >= n:
                refuse("unterminated double quote")
            i += 1
        elif char == "\\":
            if i + 1 >= n:
                refuse("unterminated escape")
            if text[i + 1] != "\n":
                value.append(text[i + 1])
            i += 2
        else:
            expands = expands or char == "$"
            value.append(char)
            i += 1
    return "word", start, i, "".join(value), expands


def words(text):
    """Yield executable words/operators, skipping redirections and here-doc data."""
    i, n, documents = 0, len(text), []
    while i < n:
        if text[i] in " \t":
            i += 1
            continue
        if text.startswith("\\\n", i):
            i += 2
            continue
        if text[i] == "#":
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        if text[i] == "\n":
            yield "op", i, i + 1, "\n", False
            i += 1
            for delimiter, strip_tabs, quoted in documents:
                while True:
                    if i >= n:
                        refuse("unterminated here-document")
                    end = text.find("\n", i)
                    end = n if end < 0 else end
                    line = text[i:end]
                    i = min(end + 1, n)
                    if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                        break
                    if not quoted and line.endswith("\\"):
                        refuse("line continuation in here-document")
                    # Unquoted here-documents perform command substitution.
                    if not quoted and ("$(" in line or "`" in line):
                        refuse("command substitution in here-document")
            documents = []
            continue
        if text[i] in "<>":
            start = i
            if text.startswith(("<(", ">("), i):
                refuse("process substitution")
            if text.startswith("<<<", i):
                refuse("here-string")
            here = text.startswith("<<", i)
            strip_tabs = text.startswith("<<-", i)
            i += 3 if strip_tabs else 2 if here or text.startswith((">>", "<&", ">&", "<>", ">|"), i) else 1
            while i < n and text[i] in " \t":
                i += 1
            token = word(text, i)
            if token[2] == i:
                refuse("missing redirection operand")
            i = token[2]
            if here:
                raw = text[token[1]:token[2]]
                if "\\\n" in raw:
                    refuse("line continuation in here-document delimiter")
                if token[4]:
                    refuse("expanded here-document delimiter")
                documents.append((token[3], strip_tabs, any(c in raw for c in "'\"\\")))
            yield "redirect", start, i, "", False
            continue
        if text[i] in OPERATORS:
            if text[i] in "()":
                refuse("shell grouping or array syntax")
            start = i
            i += 1
            if i < n and text[start:i + 1] in ("&&", "||", ";;", ";&"):
                i += 1
            if text[start:i] in (";;", ";&"):
                refuse("case control operator")
            yield "op", start, i, text[start:i], False
            continue
        token = word(text, i)
        i = token[2]
        # A numeric fd immediately preceding a redirection is not a program.
        if token[3].isdigit() and i < n and text[i] in "<>":
            continue
        yield token
    if documents:
        refuse("unterminated here-document")


def commands(text):
    """Yield each command as its list of words, split at operators."""
    current = []
    for token in words(text):
        if token[0] == "op":
            yield current
            current = []
        elif token[0] == "word":
            current.append(token)
    yield current


def render_claude(text, session, prefix):
    marks = []
    for command in commands(text):
        for position, (kind, start, end, value, expands) in enumerate(command):
            if ASSIGNMENT.match(text[start:end]):
                continue
            if value in ("if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "{", "}", "!", "time", "eval", "exec", "command", "builtin", "source", "."):
                refuse("shell control structure")
            if expands:
                refuse("expanded program word")
            if os.path.basename(value) == "claude":
                options = []
                for argument in command[position + 1:]:
                    if argument[3] == "--":
                        break
                    options.append(argument[3])
                resumes = any(option in ("--resume", "-r", "--continue", "-c") for option in options)
                suffix = session
                if session and resumes and "--fork-session" not in options:
                    suffix += " --fork-session"
                marks.append((start, end, suffix))
            break
    for index in range(len(marks) - 1, -1, -1):
        start, end, suffix = marks[index]
        text = text[:end] + suffix + text[end:]
        if index == 0:
            text = text[:start] + prefix + text[start:]
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
        if len(argv) == 5 and argv[1] == "render-claude":
            if argv[3] and not re.fullmatch(r"[0-9a-fA-F-]{36}", argv[3]):
                refuse("invalid session id")
            print(render_claude(argv[2], " --session-id " + argv[3] if argv[3] else "", argv[4]), end="")
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
