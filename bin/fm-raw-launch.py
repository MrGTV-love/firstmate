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
A claude argument that needs shell expansion ($, unquoted *, ?, a closed
[...] bracket pattern or brace characters) or that sets its own --session-id refuses too.

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
# Claude Code 2.1.310 options whose value is required: its parser takes the next
# word as that value even when it starts with "-".
CLAUDE_VALUE_OPTIONS = frozenset("""
    --ablation --accept-command --add-dir --advisor --agent --agent-color
    --agent-id --agent-name --agent-type --agents --allow-tools --allowedTools
    --allowed-tools --append-subagent-system-prompt
    --append-subagent-system-prompt-file --append-system-prompt
    --append-system-prompt-file --attach-serve --author --author-email
    --autocompact --betas --callback-port --case --channels --client-data-url
    --client-id --concurrency --config --correlation-id --cwd
    --dangerously-load-development-channels --debug-file --deep-link-cwd-b64
    --deep-link-last-fetch --deep-link-repo --description --disallow-tools
    --disallowedTools --disallowed-tools --effort --email --env --environment
    --eval-dir --fallback-model --fast-mode --file --forward-home-settings
    --header --id-token --inherit-permission-mode --input-format --issuer
    --json-schema --judge-model --label --managed-settings --marketplace
    --max-budget-usd --max-cost-usd --max-thinking-tokens --max-turns
    --mcp-config --message --messaging-socket-path --mocks --model --name
    --on-branch --output-dir --output-format --parent-session-id
    --permission-mode --permission-prompt-tool --permission-prompts
    --plan-mode-instructions --plugin-dir --plugin-dir-no-mcp --plugin-url
    --pool --port --prefill --prefill-b64 --proactivity --profile
    --project-config-root --ref --registry
    --remote-control-session-name-prefix --report --result-format
    --resume-drops-turn --resume-session-at --rewind-files --runner-declares
    --runs --scope --sdk-url --session-id --setting-sources --settings --sparse
    --system-prompt --system-prompt-file --system-prompt-snapshot --tag
    --task-budget --team-name --teammate-mode --thinking --thinking-display
    --threshold --timeout --tools --transport --watch-artifact
    --watch-artifact-no-autoreact --with --workload
""".split())
CLAUDE_SHORT_VALUES = "Hejmnst"
CLAUDE_SHORT_OPTIONAL_VALUES = "drw"
RESUME_OPTIONS = {"--resume", "-r", "--continue", "-c"}


def refuse(construct):
    raise ValueError(f"{construct}; use a named harness or simplify the raw launch to literal shell commands")


def word(text, i):
    """Read one literal/expanded word, without executing shell text."""
    start, value, expands, pattern, bracket = i, [], False, False, False
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
            # A bracket is a pattern only when a later unquoted ] closes it.
            pattern = pattern or char in "*?{" or (bracket and char == "]")
            bracket = bracket or char == "["
            value.append(char)
            i += 1
    # Assignments are not glob- or brace-expanded; every other word is.
    expands = expands or (pattern and not ASSIGNMENT.match(text[start:i]))
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


def claude_options(arguments):
    """Return the option names Claude's parser reads, skipping option values."""
    names, operand = set(), False
    for argument in arguments:
        if operand:
            operand = False
        elif argument == "--":
            break
        elif argument.startswith("--"):
            name, attached, _ = argument.partition("=")
            names.add(name)
            operand = not attached and name in CLAUDE_VALUE_OPTIONS
        elif argument.startswith("-") and argument != "-":
            for index, flag in enumerate(argument[1:], 1):
                names.add("-" + flag)
                if flag in CLAUDE_SHORT_VALUES:
                    operand = index == len(argument) - 1
                    break
                if flag in CLAUDE_SHORT_OPTIONAL_VALUES:
                    break
    return names


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
                arguments = command[position + 1:]
                if any(argument[4] for argument in arguments):
                    refuse("shell expansion in a claude argument, which can produce options such as --resume that this check cannot see")
                options = claude_options(argument[3] for argument in arguments)
                if "--session-id" in options:
                    refuse("--session-id in the raw claude command; the confinement profile grants only the session id Firstmate injects")
                suffix = session
                if session and options & RESUME_OPTIONS and "--fork-session" not in options:
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
