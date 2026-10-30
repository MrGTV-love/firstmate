#!/usr/bin/env python3
"""Select the behavior tests a change can affect, from real file dependencies.

Usage: fm-test-select.py [--repo DIR] [--base REV] [--head REV]
                         [--paths-from FILE] [--explain] [--full REASON]

Prints one decision on stdout, as "key=value" lines a shell can read:
  mode=full|selected
  reason=<one line>
  changed=<n>            changed paths considered
  total=<n>              tests/*.test.sh in the tree
  selected=<n>           tests the change can affect (mode=selected only)
  test=tests/<name>.test.sh   one line per selected test, sorted
With --explain, "why=<changed path> <- ... <- <test>" lines follow the tests.

The decision is always printed and the exit status is 0, so a caller cannot
mistake a crash for "run nothing": any error while reading the tree or the diff
prints mode=full with the error as the reason (fail closed). Exit 2 is for bad
usage only.

The changed paths come from "git diff --name-status --no-renames BASE HEAD"
(HEAD defaults to the checked-out commit), or one path per line from
--paths-from (- reads stdin). A rename therefore counts as a deletion plus an
addition.

How a test is judged affected. Every tracked file is a node, and file A depends
on file B when A runs, sources, copies, reads or lists B:
  - shell code: B is a whole word of a command, spelled as a path or as an
    unambiguous file name: the command itself, the file given to source or ".",
    the script handed to an interpreter, an argument, or the value of an
    assignment. A glob over a repository directory names every file it matches,
    and cp -R, rsync, tar, find, ls, git ls-files and for-loops name every file
    of a repository directory they walk. A name with a variable inside it
    ("backends/$name.sh") names the files it could mean, up to sixteen. A
    root-level file ("AGENTS.md") or a whole directory counts only when it is
    named through a repository-root variable ($ROOT, $FM_ROOT, ...) or a command
    substitution, because the same name under $home or $repo is a fixture's own;
  - a "bash -c CODE _ args" call passes an argument on only where CODE runs it;
  - a longer string that merely mentions B (a message, a usage text), a comment,
    a here-document that is only text, a file test ([ -f B ]) and a production
    script's mention of a file under tests/ name nothing;
  - tests/*.test.sh also depend on every file their text mentions, because a
    test may assert on a file it never runs;
  - Python, JavaScript and TypeScript depend on every whole string literal that
    names a file.
A test is affected by a changed file when that file is reachable from the test
through code files. Documents, data and other non-code files are leaves,
because mentioning a script inside a document never runs it. Tests are
tests/*.test.sh; every other tests/ file is a helper node. Reachability, not a
name pattern or a directory, decides, so a change to a sourced library selects
every test whose chain of sourced or invoked scripts reaches it, while a change
nothing reaches selects nothing.

A shared tests/ helper that at least half of the tests load (tests/lib.sh) is
infrastructure: past it only sourced libraries are followed, so the scripts it
starts for its own setup and teardown are dependencies of every test, but the
scripts those start are not, or one teardown call would tie the whole tree to
every test.

Fail-closed rules, each printing mode=full with its reason:
  - the infrastructure that runs or defines the tests changed: tests/lib.sh,
    bin/fm-test-run.sh, this selector, anything under .github/;
  - the base, the head, the diff or any file cannot be read;
  - a changed path is in neither the head tree nor the base tree;
  - the change affects at least nine tenths of the tests, where selecting buys
    little and a partial run would only hide that the change is widely shared;
  - --full REASON was given.

What it cannot see: a path built at run time from pieces the code does not
spell out (for example "$dir/$name" with $name read from input), a file named
only inside a longer string that a program later parses, a script passed to a
shell function that runs it, a file reached only through a program's own search
path or an environment variable's value, a directory listed from a bare name
with no path around it, what a shared test helper's teardown starts beyond the
libraries it loads, and behavior that depends on a file's content but not on
its name or location. A full suite runs on every push to main, so a miss is
caught there; docs/fm-test-portable-shards.md "Change-based test selection"
owns this list and how to force a full run.
"""
import argparse
import os
import re
import subprocess
import sys

SHELL_SUFFIXES = (".sh", ".bash")
OTHER_CODE_SUFFIXES = (".py", ".mjs", ".js", ".ts", ".rb")
INFRASTRUCTURE_FILES = (
    "tests/lib.sh",
    "bin/fm-test-run.sh",
    "bin/fm-test-select.py",
)
INFRASTRUCTURE_PREFIXES = (".github/",)
# At or above this share of the tests, a selection is not worth its risk.
FULL_FRACTION = 0.9
# A shared test helper that this share of the tests load is infrastructure.
AMBIENT_FRACTION = 0.5
# A root-level file ("AGENTS.md") or a whole directory is named by one of these
# variables, a command substitution ("$(dirname ...)/..") or a trailing slash. A
# fixture variable ($home, $repo, $dir) names some other tree, so a root-level
# file under it is that tree's own file, not this repository's.
REPO_ROOT_VARIABLES = frozenset(("ROOT", "FM_ROOT", "REPO_ROOT", "FM_REPO_ROOT", "SCRIPT_ROOT"))
MAX_READ_BYTES = 2 * 1024 * 1024
# A name with a variable in it that could be more files than this is too
# ambiguous to follow.
MAX_DYNAMIC_MATCHES = 16

LEADING_VARIABLE = re.compile(r"^(?:\$\{[^}]*\}|\$\(…\)|\$[A-Za-z_][A-Za-z0-9_]*)")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
PATHLIKE = re.compile(r"[A-Za-z0-9_.@+~/${}*?-]+")
POSITIONAL = re.compile(r"^\$\{?([0-9])\}?$")
SYSTEM_ROOTS = frozenset(("usr", "bin", "sbin", "etc", "var", "opt", "tmp", "dev", "proc",
                          "lib", "private", "Library", "System", "Users", "home", "Applications"))
WRAPPERS = frozenset(("exec", "command", "env", "nohup", "time", "timeout", "nice", "setsid",
                      "stdbuf", "sudo", "then", "do", "else", "elif", "if", "while", "until",
                      "!", "builtin", "caffeinate", "xargs"))
INTERPRETERS = frozenset(("bash", "sh", "zsh", "dash", "ksh", "python", "python3", "node",
                          "ruby", "perl", "tsx", "bun"))
ENUMERATORS = frozenset(("rsync", "tar", "find", "ls", "du", "tree", "zip", "unzip"))
# A printed or logged line names nothing; these lines in Python and JavaScript
# are messages.
MESSAGE_LINE = re.compile(r"^\s*(?:print|raise|throw|console\.|logging\.|logger\.|sys\.std(?:err|out)\.write)")


class Fail(Exception):
    """Any condition under which the selection cannot be trusted."""


def git(repo, *args):
    try:
        done = subprocess.run(["git", "-C", repo, *args], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False)
    except OSError as err:
        raise Fail("cannot run git: %s" % err)
    if done.returncode != 0:
        detail = done.stderr.decode("utf-8", "replace").strip().splitlines()
        raise Fail("git %s failed: %s" % (args[0], detail[-1] if detail else done.returncode))
    return done.stdout


def is_shell(path):
    return path.endswith(SHELL_SUFFIXES) or (
        path.startswith("bin/") and "." not in os.path.basename(path))


def is_code(path):
    return is_shell(path) or path.endswith(OTHER_CODE_SUFFIXES)


def is_test(path):
    return re.fullmatch(r"tests/[^/]+\.test\.sh", path) is not None


def glob_regex(pattern):
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
            continue
        ch = pattern[i]
        out.append("[^/]*" if ch == "*" else "[^/]" if ch == "?" else re.escape(ch))
        i += 1
    return "".join(out)


# --- A small reader for shell, enough to tell a command from a message --------

TOKEN = re.compile(r"""
    (?P<ws>[ \t]+)
  | (?P<nl>\n)
  | (?P<heredoc><<-?[ \t]*(?:'[^']*'|"[^"]*"|\\?[A-Za-z_][A-Za-z0-9_]*))
  | (?P<sq>'[^']*')
  | (?P<esc>\\.)
  | (?P<arith>\$\(\()
  | (?P<subst>\$\()
  | (?P<bt>`[^`]*`)
  | (?P<brace>(?<![^\s;&|(])[{}](?=[\s;&|)]|$))
  | (?P<op>&&|\|\||;;|\|&|[;&|()])
  | (?P<redir>[0-9]*(?:>>?|<)&?[0-9-]*|&>>?)
  | (?P<run>[^\s'"\\$`;&|()<>]+|\$[A-Za-z_0-9@*#?!$-]*|\$)
""", re.X | re.S)


def match_paren(text, start):
    """Index of the ')' that closes the '(' at text[start]."""
    depth = 0
    i = start
    quote = ""
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\" and quote == '"':
                i += 1
            elif ch == quote:
                quote = ""
        elif ch in "'\"":
            quote = ch
        elif ch == "\\":
            i += 1
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(text) - 1


def skip_quoted(text, i):
    """Index just past the quoted string that starts at text[i]."""
    quote = text[i]
    i += 1
    while i < len(text) and text[i] != quote:
        if quote == '"' and text[i] == "\\":
            i += 2
        elif quote == '"' and text.startswith("${", i):
            i = match_brace(text, i) + 1
        else:
            i += 1
    return i + 1


def match_brace(text, start):
    """Index of the '}' that closes the "${" at text[start]."""
    depth = 0
    i = start + 1
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            i += 2
            continue
        if ch in "'\"":
            i = skip_quoted(text, i)
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(text) - 1


def double_quoted(text, start, commands, bodies):
    """Read "..." from text[start] == '"'; return (content, next index)."""
    i = start + 1
    out = []
    while i < len(text) and text[i] != '"':
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            out.append(text[i + 1])
            i += 2
        elif text.startswith("${", i):
            close = match_brace(text, i)
            out.append(text[i:close + 1])
            i = close + 1
        elif text.startswith("$(", i) and not text.startswith("$((", i):
            close = match_paren(text, i + 1)
            commands.extend(scan(text[i + 2:close], bodies))
            out.append("$(…)")
            i = close + 1
        elif ch == "`":
            close = text.find("`", i + 1)
            close = len(text) - 1 if close < 0 else close
            commands.extend(scan(text[i + 1:close], bodies))
            out.append("$(…)")
            i = close + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out), i + 1


def scan(text, bodies):
    """Split shell text into simple commands, each a list of words.

    Quotes are removed from words and expansions are left as written. A word
    that came from inside quotes keeps its spaces, which is how a message is told
    from a path. bodies decides which here-documents are read as shell:
    "all", "redirected" (only one whose command writes a file, such as a stub
    script) or "none".
    """
    commands = []
    words = []
    buf = []
    have = False
    pending = []
    redirected = False
    i = 0
    size = len(text)

    def end_word():
        nonlocal have
        if have:
            words.append("".join(buf))
        buf.clear()
        have = False

    def end_command():
        nonlocal redirected
        end_word()
        redirected = False
        if words:
            commands.append(list(words))
            words.clear()

    while i < size:
        ch = text[i]
        if ch == '"':
            content, i = double_quoted(text, i, commands, bodies)
            buf.append(content)
            have = True
            continue
        if ch == "#" and not have:
            j = text.find("\n", i)
            i = size if j < 0 else j
            continue
        if ch == "$" and text.startswith("${", i):
            close = match_brace(text, i)
            buf.append(text[i:close + 1])
            have = True
            i = close + 1
            continue
        match = TOKEN.match(text, i)
        if match is None:
            buf.append(ch)
            have = True
            i += 1
            continue
        kind = match.lastgroup
        token = match.group(0)
        i = match.end()
        if kind == "ws":
            end_word()
        elif kind == "nl":
            writes_file = redirected
            end_command()
            for delimiter, strip in pending:
                lines = []
                while i < size:
                    j = text.find("\n", i)
                    line = text[i:size if j < 0 else j]
                    i = size if j < 0 else j + 1
                    if (line.strip("\t") if strip else line) == delimiter:
                        break
                    lines.append(line)
                if bodies == "all" or (bodies == "redirected" and writes_file):
                    commands.extend(scan("\n".join(lines), bodies))
            pending = []
        elif kind == "heredoc":
            end_word()
            strip = token.startswith("<<-")
            delimiter = token.lstrip("<-").strip().strip("'\"").lstrip("\\")
            pending.append((delimiter, strip))
        elif kind == "sq":
            buf.append(token[1:-1])
            have = True
        elif kind == "esc":
            if token != "\\\n":
                buf.append(token[1:])
                have = True
        elif kind == "arith":
            close = text.find("))", i)
            i = size if close < 0 else close + 2
            buf.append("$((…))")
            have = True
        elif kind == "subst":
            close = match_paren(text, i - 1)
            commands.extend(scan(text[i:close], bodies))
            buf.append("$(…)")
            have = True
            i = close + 1
        elif kind == "bt":
            commands.extend(scan(token[1:-1], bodies))
            buf.append("$(…)")
            have = True
        elif kind in ("op", "brace"):
            end_command()
        elif kind == "redir":
            end_word()
            if ">" in token and ">&" not in token:
                redirected = True
        else:
            buf.append(token)
            have = True
    end_command()
    return commands


def positional_roles(commands, args):
    """Words of CODE, run with positional parameters args ($0 first), that name files.

    A parameter reaches a file only where the code runs it: as the command, the
    file to source or the script handed to an interpreter. A parameter merely
    passed on to another command is data and names nothing. Returns the
    (words, sourced words).
    """
    out, sourced = [], []
    for words in commands:
        runs, reads, sources = command_words(words, [])
        for word in runs:
            match = POSITIONAL.match(word)
            if match:
                index = int(match.group(1))
                if 0 < index < len(args):
                    out.append(args[index])
                    if word in sources:
                        sourced.append(args[index])
            else:
                out.append(word)
        out.extend(w for w in reads if not POSITIONAL.match(w))
        sourced.extend(w for w in sources if not POSITIONAL.match(w))
    return out, sourced


def command_words(words, enumerating):
    """Split one simple command's words into what it runs, reads and sources.

    runs: the command itself, a sourced file, the script given to an
    interpreter, and values assigned for later use. reads: every other whole
    word. sources: the files loaded into the shell, a subset of runs. A longer
    string is a message and is left out by the caller's whole-word test.
    enumerating collects True when the command walks a whole directory.
    """
    runs, reads, sources = [], [], []
    i = 0
    while i < len(words) and ASSIGNMENT.match(words[i]):
        runs.append(words[i].split("=", 1)[1])
        i += 1
    while i < len(words) and words[i] in WRAPPERS:
        if words[i] == "command" and i + 1 < len(words) and words[i + 1] in ("-v", "-V"):
            return runs, reads, sources
        i += 1
        while i < len(words) and (words[i].startswith("-") or ASSIGNMENT.match(words[i])
                                  or re.fullmatch(r"[0-9.]+[smhd]?", words[i])):
            i += 1
    if i >= len(words):
        return runs, reads, sources
    command = words[i]
    args = words[i + 1:]
    base = os.path.basename(command)
    if command in ("type", "which", "hash"):
        return runs, reads, sources
    if command in ("[", "[[", "test"):
        # A file test asks whether a file exists; it does not run or read it.
        return runs, reads, sources
    runs.append(command)
    if base in INTERPRETERS:
        for k, arg in enumerate(args):
            if arg == "-c" or (arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:]):
                code = args[k + 1] if k + 1 < len(args) else ""
                inner, inner_sources = positional_roles(scan(code, "all"), args[k + 2:])
                runs.extend(inner)
                sources.extend(inner_sources)
                return runs, reads, sources
        for arg in args:
            if not arg.startswith("-"):
                runs.append(arg)
                break
        return runs, reads, sources
    if command in ("source", "."):
        runs.extend(args[:1])
        sources.extend(args[:1])
        return runs, reads, sources
    if command == "for":
        if len(args) > 2 and args[1] == "in":
            reads.extend(args[2:])
            enumerating.append(True)
        return runs, reads, sources
    flags = [a for a in args if a.startswith("-")]
    for arg in args:
        if arg.startswith("-"):
            if "=" in arg:
                reads.append(arg.split("=", 1)[1])
            continue
        reads.append(arg.split("=", 1)[1] if ASSIGNMENT.match(arg) else arg)
    if (base in ENUMERATORS
            or (base == "cp" and any(set(f[1:]) & set("rRa") for f in flags))
            or (base == "grep" and any("r" in f[1:].lower() for f in flags))
            or (base == "git" and any(a in ("ls-files", "grep", "archive", "clone") for a in args))):
        enumerating.append(True)
    return runs, reads, sources


# --- The tree ------------------------------------------------------------------

class Tree:
    """The tracked files, plus paths deleted by the change, and how to name them."""

    def __init__(self, repo, extra_paths):
        self.repo = repo
        tracked = git(repo, "ls-files", "-z").decode("utf-8", "replace").split("\0")
        self.files = sorted({p for p in tracked if p} | set(extra_paths))
        self.fileset = set(self.files)
        self.live = {p for p in self.files if os.path.lexists(os.path.join(repo, p))}
        self.by_base = {}
        self.dir_files = {}
        for p in self.files:
            self.by_base.setdefault(os.path.basename(p), []).append(p)
            d = os.path.dirname(p)
            while d:
                self.dir_files.setdefault(d, set()).add(p)
                d = os.path.dirname(d)
        self.dir_suffix = {}
        for d in self.dir_files:
            parts = d.split("/")
            for i in range(len(parts)):
                self.dir_suffix.setdefault("/".join(parts[i:]), set()).add(d)
        self.symlinks = {}
        for p in self.live:
            full = os.path.join(repo, p)
            if os.path.islink(full):
                target = os.path.normpath(os.path.join(os.path.dirname(p), os.readlink(full)))
                if not target.startswith(".."):
                    self.symlinks[p] = target
        self.word_cache = {}
        self.glob_cache = {}
        self.reference_cache = {}

    def read(self, path):
        full = os.path.join(self.repo, path)
        if path not in self.live or os.path.islink(full) or os.path.isdir(full):
            return ""
        try:
            if os.path.getsize(full) > MAX_READ_BYTES:
                return ""
            with open(full, "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError as err:
            raise Fail("cannot read %s: %s" % (path, err))

    def files_named(self, trimmed, qualified):
        """Tracked files one path-like word names (not directories)."""
        key = (trimmed, qualified)
        if key in self.word_cache:
            return self.word_cache[key]
        found = set()
        if trimmed in self.fileset and ("/" in trimmed or qualified):
            found.add(trimmed)
        base = os.path.basename(trimmed)
        cands = self.by_base.get(base, ())
        if "/" in trimmed:
            found.update(c for c in cands if c.endswith("/" + trimmed))
        else:
            for cand in cands:
                if "/" in cand:
                    found.add(cand)
                elif qualified:
                    # A root-level file is named only by a qualified path
                    # ("$ROOT/README.md"); a bare "README.md" is a fixture name.
                    found.add(cand)
        for link, target in self.symlinks.items():
            if trimmed == link or trimmed.endswith("/" + link):
                # A symlinked directory stands for its files only when it is
                # named through the repository root; ".claude/skills" under some
                # other home is that home's own.
                if target in self.dir_files and not qualified:
                    continue
                found.update(p for p in self.dir_files.get(target, set()) | {target} if p in self.fileset)
            elif trimmed.startswith(link + "/"):
                real = target + trimmed[len(link):]
                if real in self.fileset:
                    found.add(real)
        self.word_cache[key] = found
        return found

    def dirs_named(self, trimmed, qualified):
        out = set()
        if not qualified:
            return out
        for d in self.dir_suffix.get(trimmed.rstrip("/"), ()):
            out |= self.dir_files[d]
        return out

    def glob_files(self, pattern):
        """Files a glob over a repository directory expands to."""
        if pattern in self.glob_cache:
            return self.glob_cache[pattern]
        found = set()
        tail = pattern.lstrip("/")
        while tail.startswith("./"):
            tail = tail[2:]
        directory = os.path.dirname(tail)
        # Only a glob inside a repository directory names repository files;
        # one with no directory ("fm-*") or an unresolved one ("*/x") is a
        # search of some other place and is not followed.
        if directory and "*" not in directory and "?" not in directory and directory in self.dir_suffix:
            regex = re.compile(r"(?:^|.*/)%s$" % glob_regex(tail))
            found = {c for c in self.files if regex.match(c)}
        self.glob_cache[pattern] = found
        return found


def word_references(tree, raw, enumerating):
    """Tracked files one whole word names, or nothing for a message."""
    key = (raw, enumerating)
    cached = tree.reference_cache.get(key)
    if cached is None:
        cached = tree.reference_cache[key] = _word_references(tree, raw, enumerating)
    return cached


def normal_path(word):
    """A word as a path relative to some repository root, or "" if it names none.

    Leading "/", "./" and "../" only say where the word was written from, so
    they are dropped; the rest is normalized. A leading "-" is an option.
    """
    if word.startswith("-"):
        return ""
    parts = []
    for part in word.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if parts:
                parts.pop()
            continue
        parts.append(part)
    return "/".join(parts).rstrip(".")


def _word_references(tree, raw, enumerating):
    variable = LEADING_VARIABLE.match(raw)
    qualified = False
    if variable:
        name = re.sub(r"[${}()…]", "", variable.group(0))
        qualified = name in REPO_ROOT_VARIABLES or variable.group(0).startswith("$(")
    word = raw[variable.end():] if variable else raw
    if not word or re.search(r"\s", word) or ":" in word:
        return set()
    dynamic = "$" in word
    if dynamic:
        # A variable inside the name ("backends/$name.sh") can be any file of
        # that directory that fits the rest of the name. A name that could be
        # one of many files says nothing about which, so it is not followed.
        word = re.sub(r"\$\{[^}]*\}|\$\(…\)|\$[A-Za-z_][A-Za-z0-9_]*", "*", word)
        if "$" in word:
            return set()
    if not variable and word.startswith("/") and word.lstrip("/").split("/", 1)[0] in SYSTEM_ROOTS:
        return set()
    trimmed = normal_path(word)
    if not trimmed:
        return set()
    if "*" in trimmed or "?" in trimmed:
        matched = tree.glob_files(trimmed)
        return matched if not dynamic or len(matched) <= MAX_DYNAMIC_MATCHES else set()
    found = set(tree.files_named(trimmed.rstrip("/"), qualified))
    if enumerating:
        found |= tree.dirs_named(trimmed, qualified or word.endswith("/"))
    return found


def mention_references(tree, text):
    """Files a text mentions anywhere, in any string or word (generous)."""
    found = set()
    for word in set(PATHLIKE.findall(text)):
        found |= word_references(tree, word, False)
    return found


STRING_LITERAL = re.compile(r"\"([^\"\\\n]*)\"|'([^'\\\n]*)'|`([^`]*)`")


def literal_references(tree, text):
    """Files named by a whole string literal (Python, JavaScript, TypeScript).

    A literal that is a path or a file name names it; a sentence that mentions
    one is a message.
    """
    found = set()
    for match in STRING_LITERAL.finditer(text):
        found |= word_references(tree, next(g for g in match.groups() if g is not None), False)
    return found


VARIABLE_NAME = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")


def assigned_values(commands):
    """name -> the first value the file assigns it, for names that hold a path."""
    values = {}
    for words in commands:
        for word in words:
            if ASSIGNMENT.match(word):
                name, _, value = word.partition("=")
                if value and "/" in value and name not in values:
                    values[name.rstrip("+")] = value
    return values


def expand_assigned(word, values):
    """Replace variables the file itself assigns a path to, up to two levels deep."""
    for _ in range(2):
        replaced = VARIABLE_NAME.sub(
            lambda m: values.get(m.group(1) or m.group(2), m.group(0)), word)
        if replaced == word:
            break
        word = replaced
    return word


def shell_references(tree, text, bodies):
    found, sourced = set(), set()
    commands = scan(text, bodies)
    values = assigned_values(commands)
    for words in commands:
        enumerating = []
        runs, reads, sources = command_words(words, enumerating)
        for word in runs + reads:
            found |= word_references(tree, expand_assigned(word, values), bool(enumerating))
        for word in sources:
            sourced |= word_references(tree, expand_assigned(word, values), False)
    return found, sourced


def strip_foreign_comments(path, text):
    if path.endswith((".py", ".rb")):
        text = re.sub(r'"""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'', "", text)
        return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
    text = re.sub(r"/\*[\s\S]*?\*/", "", text)
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("//"))


def references(tree, path):
    """(files path depends on, the subset it loads into its own shell)."""
    text = tree.read(path)
    if not text or not is_code(path):
        return set(), set()
    sourced = set()
    if is_shell(path):
        refs, sourced = shell_references(tree, text, "all" if path.startswith("tests/") else "redirected")
        if is_test(path):
            refs |= mention_references(tree, "\n".join(
                l for l in text.split("\n") if not l.lstrip().startswith("#")))
    else:
        lines = [l for l in strip_foreign_comments(path, text).split("\n") if not MESSAGE_LINE.match(l)]
        refs = literal_references(tree, "\n".join(lines))
    refs.discard(path)
    sourced.discard(path)
    if not path.startswith("tests/"):
        # Production code names test files in tables and messages but never
        # runs them: the test runner and the linter are driven by tests, which
        # name them, not the other way round.
        refs = {r for r in refs if not r.startswith("tests/")}
        sourced = {r for r in sourced if not r.startswith("tests/")}
    return refs, sourced & refs


class Graph:
    def __init__(self, tree):
        self.tree = tree
        self.edges = {}
        self.source_edges = {}
        for p in tree.files:
            self.edges[p], self.source_edges[p] = references(tree, p)
        self.tests = sorted(p for p in tree.files if is_test(p) and p in tree.live)
        self.ambient = self.find_ambient()

    def reach(self, test, ambient=frozenset()):
        """Everything a test can run or read, with the path that reaches it.

        A file in ambient is infrastructure that most tests share. What it runs
        for its own setup and teardown is included, with the libraries those
        files load, but the other scripts they start are not followed, so every
        test does not inherit the whole tree through it.
        """
        parent = {test: None}
        expanded = set()
        queue = [(test, False)]
        while queue:
            node, loaded_only = queue.pop(0)
            if node in expanded:
                continue
            expanded.add(node)
            edges = self.source_edges if loaded_only else self.edges
            for nxt in sorted(edges.get(node, ())):
                if nxt not in parent:
                    parent[nxt] = node
                if nxt not in expanded:
                    # Past an ambient file only loaded libraries are followed.
                    queue.append((nxt, loaded_only or node in ambient))
        return parent

    def find_ambient(self):
        """Shared tests/ helpers that at least half of the tests load."""
        counts = {}
        for test in self.tests:
            for node in self.reach_helpers(test):
                counts[node] = counts.get(node, 0) + 1
        return frozenset(n for n, c in counts.items() if c >= AMBIENT_FRACTION * len(self.tests))

    def reach_helpers(self, test):
        seen = {test}
        queue = [test]
        while queue:
            node = queue.pop()
            for nxt in self.edges.get(node, ()):
                if nxt not in seen and nxt.startswith("tests/") and is_shell(nxt) and not is_test(nxt):
                    seen.add(nxt)
                    queue.append(nxt)
        seen.discard(test)
        return seen

    def dependents(self):
        reverse = {}
        chains = {}
        for test in self.tests:
            chains[test] = self.reach(test, self.ambient)
            for node in chains[test]:
                reverse.setdefault(node, set()).add(test)
        return reverse, chains


def changed_paths(args):
    if args.paths_from:
        raw = sys.stdin.read() if args.paths_from == "-" else open(args.paths_from).read()
        return sorted({line.strip() for line in raw.splitlines() if line.strip()}), set()
    if not args.base:
        raise Fail("no --base and no --paths-from")
    head = args.head or "HEAD"
    for rev in (args.base, head):
        git(args.repo, "rev-parse", "--verify", "--quiet", rev + "^{commit}")
    out = git(args.repo, "diff", "--name-status", "--no-renames", "-z", args.base, head)
    fields = out.decode("utf-8", "replace").split("\0")
    paths, deleted = set(), set()
    for i in range(0, len(fields) - 1, 2):
        status, path = fields[i], fields[i + 1]
        if path:
            paths.add(path)
            if status.startswith("D"):
                deleted.add(path)
    return sorted(paths), deleted


def decide(args):
    if args.full:
        return {"mode": "full", "reason": args.full, "changed": 0}
    paths, deleted = changed_paths(args)
    result = {"changed": len(paths)}
    for path in paths:
        if path in INFRASTRUCTURE_FILES or path.startswith(INFRASTRUCTURE_PREFIXES):
            result.update(mode="full", reason="infrastructure changed: %s" % path)
            return result
    tree = Tree(os.path.abspath(args.repo), deleted)
    for path in paths:
        if path not in tree.fileset:
            result.update(mode="full", reason="unknown path (in neither tree): %s" % path)
            return result
    graph = Graph(tree)
    result["total"] = len(graph.tests)
    if not graph.tests:
        result.update(mode="full", reason="no tests/*.test.sh found")
        return result
    reverse, chains = graph.dependents()
    selected, via = set(), {}
    for path in paths:
        for test in reverse.get(path, ()):
            selected.add(test)
            via.setdefault(test, path)
    if len(selected) >= FULL_FRACTION * len(graph.tests):
        result.update(mode="full", selected=len(selected),
                      reason="widely shared: %d of %d tests are affected"
                      % (len(selected), len(graph.tests)))
        return result
    result.update(mode="selected", tests=sorted(selected),
                  reason="%d of %d tests are affected by %d changed paths"
                  % (len(selected), len(graph.tests), len(paths)))
    if args.explain:
        result["why"] = []
        for test in sorted(selected):
            chain, node = [], via[test]
            while node is not None:
                chain.append(node)
                node = chains[test].get(node)
            result["why"].append(" <- ".join(chain))
    return result


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-test-select.py")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base")
    parser.add_argument("--head")
    parser.add_argument("--paths-from")
    parser.add_argument("--explain", action="store_true")
    parser.add_argument("--full", metavar="REASON")
    try:
        args = parser.parse_args(argv)
    except SystemExit as err:
        return 2 if err.code else 0
    try:
        result = decide(args)
    except Fail as err:
        result = {"mode": "full", "reason": "selector error: %s" % err, "changed": 0}
    except Exception as err:  # noqa: BLE001 - every failure must fail closed
        result = {"mode": "full", "reason": "selector error: %s: %s" % (type(err).__name__, err),
                  "changed": 0}
    out = ["mode=%s" % result["mode"], "reason=%s" % result["reason"].replace("\n", " "),
           "changed=%d" % result.get("changed", 0)]
    if "total" in result:
        out.append("total=%d" % result["total"])
    if result["mode"] == "selected":
        out.append("selected=%d" % len(result["tests"]))
        out.extend("test=%s" % t for t in result["tests"])
        out.extend("why=%s" % w for w in result.get("why", ()))
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
