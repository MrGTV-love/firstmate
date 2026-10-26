#!/usr/bin/env python3
"""Read a raw launch command's shell words without evaluating or expanding them.

Usage: fm-raw-launch.py render-claude COMMAND SESSION_ID PREFIX
       fm-raw-launch.py runs-claude COMMAND
       fm-raw-launch.py root NAME COMMAND CWD

A command's program is its first word after leading assignments, or, behind
a named wrapper (env, command, exec, nohup, time, timeout, nice, caffeinate,
arch, stdbuf), the word after that wrapper's own options and operands; the -c
text of sh, bash or zsh is read again by the same rules. A quoted expansion
("$T") is one word, so it fills an option value, operand or env assignment the
way a literal would; an unquoted one can split into any number of words, so a
program behind it is not decided.

render-claude inserts the session argument after each literal claude program
word, forks resumed or continued sessions into that id and prefixes only the
first claude invocation; empty SESSION_ID and PREFIX only validate the command.
It splices original source spans, preserving
quoted data, comments and here-document bodies; a shell -c text that runs
claude is replaced by the same text, rendered and quoted again. Here-documents
support literal, single/double-quoted delimiters and <<- tab stripping,
including multiple bodies.
Command/process substitutions, here-strings and shell control structures refuse
with a remedy rather than guessing; unterminated quotes/documents also refuse.
A plain parameter expansion ($NAME, ${NAME}) is read as ordinary argument text;
an expanded program word, wrapper argument or shell -c text refuses, because it
can name a program this check cannot see. Expansion flags,
a forced pattern and the forced `$~`, `$=` or `$^` forms refuse everywhere,
because zsh globs such a value and a glob qualifier in it runs a command.
A claude argument that needs shell expansion ($, unquoted *, ?, a closed
[...] bracket pattern or brace characters) or that sets its own --session-id refuses too.

runs-claude exits 0 when any command, not only the first, runs claude as its
program (past assignments, shell keywords and named wrappers), even when text
after that program word cannot be read, 1 when no command it reads does, and 2
when it cannot read the text before finding one.

root prints the absolute path a single leading NAME=value assignment of the
first command sets, with its quotes removed and a relative value resolved
against CWD. It exits 1 when NAME is not assigned that way and 3, naming NAME on
stderr, when the value needs shell expansion ($, a backquote or a leading ~),
is empty, or NAME is assigned again by a later command.
Malformed or unsupported shell text exits 2 without emitting a rewritten command.
"""
import os
import re
import shlex
import sys

OPERATORS = "\n;&|()"
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
# Programs that run the rest of their command as another program: the short
# flags each takes, its short options that take a value, and the operands it
# reads before that program. arch's own options are read in wrapped().
WRAPPERS = {
    "env": ("i", "u", 0),
    "command": ("p", "", 0),
    "exec": ("cl", "a", 0),
    "nohup": ("", "", 0),
    "time": ("p", "", 0),
    "timeout": ("fpv", "ks", 1),
    "nice": ("", "n", 0),
    "caffeinate": ("dimsu", "tw", 0),
    "arch": ("", "", 0),
    "stdbuf": ("", "ioe", 0),
}
ARCH_VALUE_OPTIONS = ("-arch", "-d", "-e")
SHELLS = ("sh", "bash", "zsh")
SHELL_VALUE_LONG_OPTIONS = ("--rcfile", "--init-file", "--emulate")
# What a word's expansion can produce: one word, or any number of words.
ONE_WORD, SPLITS = 1, 2
PARAMETER_FLAGS_REFUSAL = (
    "a forced pattern or splitting form, which makes zsh glob the value, so a glob qualifier in it runs a command"
)
# A forced-glob, forced-splitting or forced-quoting `$` form.
FORCED_EXPANSION_START = frozenset("~=^")
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
KEYWORDS = ("if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "{", "}", "!", "eval", "builtin", "source", ".")


def refuse(construct):
    raise ValueError(f"{construct}; use a named harness or simplify the raw launch to literal shell commands")


def word(text, i):
    """Read one literal/expanded word, without executing shell text.

    A forced pattern or splitting form refuses, because zsh turns such a value
    into a glob whose qualifiers run commands. The expansion field is false,
    ONE_WORD for a quoted expansion, or SPLITS when an unquoted expansion,
    pattern or "$@" can produce any number of words.
    """
    start, value, expands, splits, pattern, bracket = i, [], False, False, False, False
    n = len(text)
    while i < n and text[i] not in " \t\n;&|()<>":
        char = text[i]
        if text.startswith("$(", i):
            refuse("command substitution")
        if text.startswith("${", i):
            if text[i + 2:i + 3] in ("(", "~", "=", "^"):
                refuse(PARAMETER_FLAGS_REFUSAL)
            expands = splits = True
            value.append("${")
            i += 2
            continue
        if char == "`":
            refuse("backtick command substitution")
        if char == "$" and i + 1 < n and text[i + 1] in "'\"":
            refuse("dollar-quoted string")
        if char == "$" and i + 1 < n and text[i + 1] in FORCED_EXPANSION_START:
            refuse(PARAMETER_FLAGS_REFUSAL)
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
                if text.startswith("$(", i):
                    refuse("command substitution in double quote")
                if text.startswith("${", i):
                    if text[i + 2:i + 3] in ("(", "~", "=", "^"):
                        refuse(PARAMETER_FLAGS_REFUSAL)
                    expands = True
                    splits = splits or "@" in text[i + 2:text.find("}", i)]
                    value.append("${")
                    i += 2
                    continue
                if text[i] == "`":
                    refuse("backtick command substitution in double quote")
                if text[i] == "$" and i + 1 < n and text[i + 1] in FORCED_EXPANSION_START:
                    refuse(PARAMETER_FLAGS_REFUSAL)
                expands = expands or text[i] == "$"
                splits = splits or text.startswith("$@", i)
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
            splits = splits or char == "$"
            # A bracket is a pattern only when a later unquoted ] closes it.
            pattern = pattern or char in "*?{" or (bracket and char == "]")
            bracket = bracket or char == "["
            value.append(char)
            i += 1
    # Assignments are not glob- or brace-expanded; every other word is.
    splits = splits or (pattern and not ASSIGNMENT.match(text, start))
    expands = SPLITS if splits else ONE_WORD if expands else False
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


def wrapped(name, command, position):
    """Return the position after a named wrapper's own options and operands,
    or None when it takes an option this check does not know."""
    flags, values, operands = WRAPPERS[name]
    while position < len(command):
        argument, expands = command[position][3], command[position][4]
        if name == "env" and expands != SPLITS and (argument == "-" or ASSIGNMENT.match(argument)):
            position += 1
            continue
        if expands or not argument.startswith("-") or argument == "-":
            break
        if argument == "--":
            position += 1
            break
        if name == "arch":
            position += 2 if argument in ARCH_VALUE_OPTIONS else 1
            continue
        for index, flag in enumerate(argument[1:], 2):
            if flag in values:
                position += index == len(argument)
                break
            if flag not in flags:
                return None
        position += 1
    if name == "env":
        while position < len(command) and command[position][4] != SPLITS and ASSIGNMENT.match(command[position][3]):
            position += 1
    return position + operands


def shell_text(command, position):
    """Return the position of the text a named shell runs with -c, or None."""
    reads_text = False
    while position < len(command) and not command[position][4]:
        argument = command[position][3]
        if argument == "--":
            position += 1
            break
        if argument[:1] not in ("-", "+") or argument in ("-", "+"):
            break
        if argument.startswith("--"):
            position += 2 if argument in SHELL_VALUE_LONG_OPTIONS else 1
            continue
        reads_text = reads_text or (argument[0] == "-" and "c" in argument)
        position += 2 if "o" in argument or "O" in argument else 1
    return position if reads_text and position < len(command) else None


def program(text, command):
    """Return (position, shell) for the word a command runs as its program, past
    leading assignments, shell keywords and named wrappers; shell is true when
    that word is a named shell's -c text. An expanded word in a program or
    option position is that program, because it can name one, and so is a
    skipped word that can split; (None, False) when none is known."""
    position = 0
    while position < len(command) and (ASSIGNMENT.match(text, command[position][1]) or command[position][3] in KEYWORDS):
        position += 1
    while position < len(command):
        name = os.path.basename(command[position][3])
        if command[position][4] or name not in WRAPPERS and name not in SHELLS:
            return position, False
        start = position + 1
        position = shell_text(command, start) if name in SHELLS else wrapped(name, command, start)
        if position is None:
            return None, False
        for skipped in range(start, min(position, len(command))):
            if command[skipped][4] == SPLITS:
                return skipped, False
        if name in SHELLS:
            return position, True
    return None, False


def render_claude(text, session, prefix):
    """Return text with the session after each claude program word and prefix
    before the first one, and whether any command runs claude."""
    edits, found = [], False
    for command in commands(text):
        first = next((token for token in command if not ASSIGNMENT.match(text, token[1])), None)
        if first is None:
            continue
        if first[3] in KEYWORDS:
            refuse("shell control structure")
        position, shell = program(text, command)
        if position is None:
            continue
        kind, start, end, value, expands = command[position]
        if expands:
            refuse("expanded program word, wrapper argument or shell -c text")
        if shell:
            rendered, inner = render_claude(value, session, "" if found else prefix)
            found = found or inner
            if rendered != value:
                edits.append((start, end, shlex.quote(rendered)))
            continue
        if os.path.basename(value) != "claude":
            continue
        arguments = command[position + 1:]
        if any(argument[4] for argument in arguments):
            refuse("shell expansion in a claude argument, which can produce options such as --resume that this check cannot see")
        options = claude_options(argument[3] for argument in arguments)
        if "--session-id" in options:
            refuse("--session-id in the raw claude command; the confinement profile grants only the session id Firstmate injects")
        suffix = session
        if session and options & RESUME_OPTIONS and "--fork-session" not in options:
            suffix += " --fork-session"
        if not found:
            edits.append((start, start, prefix))
        edits.append((end, end, suffix))
        found = True
    for start, end, replacement in reversed(edits):
        text = text[:start] + replacement + text[end:]
    return text, found


def runs_claude(text):
    """Return whether a command runs claude as its program, judged as each word
    is read, so a claude before text this check cannot read still counts."""
    command = []
    for token in words(text):
        if token[0] == "op":
            command = []
        elif token[0] == "word":
            command.append(token)
            position, shell = program(text, command)
            if position is None or command[position][4] == SPLITS:
                continue
            value = command[position][3]
            if runs_claude(value) if shell else os.path.basename(value) == "claude":
                return True
    return False


def root(name, text, cwd):
    found, index, leading = [], 0, True
    try:
        for kind, start, end, value, expands in words(text):
            if kind == "op":
                index, leading = index + 1, True
            elif kind == "word" and leading:
                raw = text[start:end]
                leading = ASSIGNMENT.match(raw) is not None
                if leading and raw.startswith(name + "="):
                    found.append((index, raw[len(name) + 1:], value[len(name) + 1:], expands))
    except ValueError:
        # Text after the first command's assignments that this check cannot
        # read cannot change the root they set, unless it names NAME again.
        if not found or (index == 0 and leading) or text.count(name + "=") > 1:
            raise
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
            print(render_claude(argv[2], " --session-id " + argv[3] if argv[3] else "", argv[4])[0], end="")
            return 0
        if len(argv) == 3 and argv[1] == "runs-claude":
            return 0 if runs_claude(argv[2]) else 1
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
