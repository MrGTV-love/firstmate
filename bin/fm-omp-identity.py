#!/usr/bin/env python3
"""Recognize the installed omp's Bun runtime as the omp interactive agent.

Usage: fm-omp-identity.py interactive (PID | --facts FILE)
       fm-omp-identity.py writer (PID | --facts FILE)
       fm-omp-identity.py facts PID
       fm-omp-identity.py holds (PID | --facts FILE) SESSION-FILE

Why this exists. The host's `omp` can be a /bin/sh launcher that `exec`s the Bun
runtime on the installed omp entry script, so the live process is named `bun`
and only its argument vector names omp. A name match cannot recognize that
process, and a bare `bun` match would admit every Bun program. This helper is
the single owner of that identity rule. bin/fm-launch-proof-lib.sh calls
`interactive` and `holds`; bin/fm-agent-process-lib.sh calls `writer` for the
record-owner check and the Herdr descendant walk.

Identity. Every input is one of two kinds, and the rule is kept in one place.
Held by the kernel for this PID, unchangeable after launch: the start identity, the
raw argument vector (argv[0] and argv[1] exactly as exec received them), the standard-
input type and the open-descriptor table. Read from the filesystem NOW, so anything
may have changed since the process loaded it: every realpath, lstat and package.json,
the marker files, and the path string the kernel reports for the executable (it follows
a rename of any directory above the file). "Positively another program" (Foreign, and
so `writer` exit 1, "unrelated" and "agent-free") rests only on the first kind: argv[0]
whose basename is not bun, no script argument, or a raw argv[1] that is lexically not a
cli.ts in a src directory. A script path resolved after launch can never prove it:
a link retargeted after the process loaded its script changes what the path resolves to,
not what the process loaded. The named residual is the opposite case: a process that
loaded the entry through a link with another name (raw argv[1] `/x/foo.ts`) reads as
unrelated, because the raw arguments are all the kernel holds; it is never admitted
either way, and the installed launcher always passes the canonical entry path.
Admission (`interactive`) needs every filesystem input tied to launch time, and
otherwise fails closed. One trusted installed identity is held in one place
(INSTALLED_RUNTIME and INSTALLED_SCRIPT below, resolved by installed_identity(); the
root is always the fixed one under the account's home, and no environment variable or
argument can move it). The tests reach a replacement root only through the `root`
parameter of installed_identity(), which tests/lib.sh fm_test_omp_root_shim passes from
its own runner; nothing in bin/ passes it. It is its own canonical path: the root must be a real
directory (a link there redefines nothing) and neither the runtime nor the script may
be reached through a link. It never consults a launcher or PATH, so an `omp update`
that replaces a launcher cannot change the verdict on a process that is already
running, and no version is pinned. A process is the installed omp's interactive agent
only when ALL of these hold: its raw argv[1] is, byte for byte, the installed script
path; its kernel executable path resolves to the installed runtime; the structural
checks pass, kept as extra proof (a regular executable named bun in a directory named
bin whose parent holds a package.json named @oven/bun-*; a regular file named cli.ts in
a directory named src whose parent holds a regular package.json named
@oh-my-pi/pi-coding-agent and the regular files src/cli-commands.ts and src/main.ts);
every inode from the installed root down to the installed runtime and to the installed
script has an inode-change time at or before the process start (tree_settled: a path
swapped, retargeted, edited or renamed into place after launch moves the changed
inode's time past the start, which is measured on this host for ln -sfn, mv of an older
file, link or directory, replace-by-rename and in-place edit; an unrelated write into
one of those directories also moves it, which fails closed); its role is the
interactive agent; and its standard input is a terminal. A complete omp-shaped tree at
any other path is refused for `interactive` but is never "positively another program"
for `writer`: it may own a session record. Anything that cannot be read, or an
executable or script path that no longer exists, or an installed identity that cannot
be derived, or an installed tree that changed after the process started, is
unresolved, never interactive. `facts` stores what it read, including the installed
pair it compared with and tree_settled, in the record, and every verdict on a `--facts`
record is judged from that record alone, so a capture replays without the tree; a live
PID never takes its identity from input.

Role. The role is decided by a port of the installed CLI's own dispatch, over
the argument ARRAY so boundaries survive: profile-flag extraction
(src/cli/profile-bootstrap.ts), the `__omp_worker_` selector prefix
(pi-utils/src/worker-host.ts), the reserved words and subcommand hoisting of
src/cli-commands.ts, `acp` and --acp-terminal-auth (src/commands/acp.ts,
src/modes/acp/terminal-auth.ts), then --print, -p and --mode with its `=` form
(src/cli/args.ts), and finally the type of standard input, because the CLI runs
a launch without a terminal on standard input as print mode (src/main.ts).
Only a launch or an `acp --acp-terminal-auth` with terminal standard input is
the interactive role. Anything the port cannot settle is unresolved, never
interactive. The flag and command tables below are a copy of the installed
CLI's; tests/fm-omp-identity.test.sh pins them to a fixture and the live guard
(tests/fm-omp-identity-live-e2e.test.sh) compares them to the installed source.

Session binding. An unpinned process has no publication of the session it runs, and a
registration or a resume argument is not proof of it (a conversation can switch
after launch). `holds` reports whether the process holds a given regular file open for
writing, by device and inode, read from the kernel (fm-proc-info.py writable). Whether
the installed omp keeps writing its session file after a switch, and whether it releases
the old descriptor, is UNVERIFIED here: nothing in this repository observed the real
harness switching a session (the live guard runs with --no-session), so that fact is
owned by Main's live guard (E3). `holds` therefore fails closed when the process holds
the file AND another writable `.jsonl` outside that session's own artifact directory
(the session file's name without `.jsonl`, where omp keeps its advisor file): it then
cannot tell which session is current, and exit 2 refuses adoption. Exit 0 holds it and
no other session file, 1 does not hold it, 2 unreadable or ambiguous. Adoption of a
Bun-shaped process requires exit 0, so a process that is not positively tied to the
task's preserved session stays unadopted.

Exit status. interactive: 0 the process is the installed omp's interactive
agent (stdout is JSON carrying the incarnation `start`), 1 refused (a foreign
executable or script, or another role), 2 unresolved (evidence unavailable).
writer: 0 the process may own an omp session record (the installed omp in any
role, a complete omp-shaped tree that is not the installed one, anything whose
identity cannot be read, or any unexpected failure of this helper), 1 it is
positively another program. Reasons go to stderr. Nothing here
reads a process environment, sends a signal, or reads any file but the package
files beside the process's own executable and script (the installed identity is
resolved by path only, and nothing in it is opened).
"""
import json
import os
import pwd
import stat
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROC_INFO = os.path.join(HERE, "fm-proc-info.py")

INSTALLED_ROOT = os.path.join(".local", "share", "omp-promax-fix")  # relative to the user's home
INSTALLED_RUNTIME = os.path.join("runtime", "node_modules", "@oven", "bun-darwin-aarch64", "bin", "bun")
INSTALLED_SCRIPT = os.path.join("src", "node_modules", "@oh-my-pi", "pi-coding-agent", "src", "cli.ts")
RUNTIME_PACKAGE_PREFIX = "@oven/bun-"
SCRIPT_PACKAGE = "@oh-my-pi/pi-coding-agent"
SCRIPT_MARKERS = (os.path.join("src", "cli-commands.ts"), os.path.join("src", "main.ts"))
SELECTOR_PREFIX = "__omp_worker_"
BOUNDARY_ARG = "--omp-profile-boundary"
STRING_VALUE_FLAGS = frozenset("""--cwd --config --add-dir --mode --fork --provider --model --smol --slow --goal
--plan --prewalk-into --plan-yolo-into --max-time --warn-cost --max-cost --service-tier --api-key --system-prompt
--system-prompt-template --append-system-prompt --provider-session-id --prompt-cache-key --session-dir --models
--tools --thinking --export --hook --extension -e --trusted-extension --plugin-dir --skills --approval-mode""".split())
OPTIONAL_VALUE_FLAGS = frozenset(("--resume", "-r", "--restore", "--session"))
SHADOWABLE_STRING_FLAGS = frozenset(("--plan",))
VALUELESS_FLAGS = frozenset("""--help --version --allow-home --continue --from-claude --from-codex --no-session
--no-tools --no-lsp --no-pty --hide-thinking --advisor --wait-async --external-thinking --prewalk --no-prewalk
--plan-yolo --print --print-thoughts --no-extensions --no-skills --no-rules --no-context-files --no-title --no-ui
--auto-approve --yolo""".split())
SUBCOMMANDS = frozenset("""launch acp auth auth-broker auth-gateway agents anonymize bench browser-relay cleanse
collab commit completions __complete compress config dry-balance find gc grep gallery git grievances images if-bench
install join login models plugin predict ps say clip play share session setup shell read render skill ssh stats
stream update usage tiny-models token toks ttsr worktree search img plugins skills wt q web-search""".split())
LAUNCH_FLAG_COMMANDS = frozenset(("launch", "acp"))
RESERVED_WORDS = frozenset("extensions list remove uninstall marketplace discover upgrade enable disable".split())
MARKETPLACE_SUBCOMMANDS = frozenset(("add", "remove", "rm", "update", "list"))
ACP_TERMINAL_AUTH_FLAG = "--acp-terminal-auth"
HELP_WORDS = frozenset(("--help", "-h", "--version", "-v", "help"))


class Refused(Exception):
    """The process is positively not the installed omp's interactive agent."""


class Foreign(Refused):
    """The readable executable or script is positively another program."""


class Unresolved(Exception):
    """The evidence cannot settle the question; the caller must not admit."""


# --- the CLI's own dispatch, ported ----------------------------------------

def _is_unknown_long(arg):
    return (arg.startswith("--") and "=" not in arg and arg not in STRING_VALUE_FLAGS
            and arg not in OPTIONAL_VALUE_FLAGS and arg not in VALUELESS_FLAGS)


def _flag_consumes_value(flag, following):
    if flag.startswith("--") and "=" in flag:
        return False
    if following is None:
        return False
    if flag in STRING_VALUE_FLAGS:
        return True
    value_like = not following.startswith("-")
    if flag in SHADOWABLE_STRING_FLAGS:
        return value_like
    if flag in OPTIONAL_VALUE_FLAGS:
        return value_like and following != ""
    if _is_unknown_long(flag):
        return value_like
    return False


def _is_subcommand(first):
    return bool(first) and not first.startswith(("-", "@")) and first in SUBCOMMANDS


def extract_profile_flags(argv):
    """Port of extractProfileFlags. Raises Refused where the CLI exits with an error."""
    stripped, alias = [], False
    pass_through = saw_subcommand = False
    can_dispatch = True
    boundary_next = False

    def needs_boundary():
        previous = stripped[-1] if stripped else None
        return previous is not None and (previous in OPTIONAL_VALUE_FLAGS or previous in SHADOWABLE_STRING_FLAGS
                                         or _is_unknown_long(previous))

    index = 0
    while index < len(argv):
        arg = argv[index]
        if pass_through or saw_subcommand:
            stripped.append(arg)
            index += 1
            continue
        if boundary_next:
            if not arg.startswith("-"):
                stripped.append(BOUNDARY_ARG)
            boundary_next = False
        if arg == "--":
            pass_through = True
            stripped.append(arg)
        elif arg in ("--profile", "--alias"):
            following = argv[index + 1] if index + 1 < len(argv) else None
            if not following or following.startswith("-"):
                raise Refused("the CLI exits: a global flag lacks its value")
            alias = alias or arg == "--alias"
            boundary_next = needs_boundary()
            index += 1
        elif arg.startswith(("--profile=", "--alias=")):
            if not arg.split("=", 1)[1]:
                raise Refused("the CLI exits: a global flag lacks its value")
            alias = alias or arg.startswith("--alias=")
            boundary_next = needs_boundary()
        elif arg in SHADOWABLE_STRING_FLAGS:
            can_dispatch = False
            stripped.append(arg)
            following = argv[index + 1] if index + 1 < len(argv) else None
            if following is not None and not following.startswith("-"):
                stripped.append(following)
                index += 1
        elif arg in STRING_VALUE_FLAGS:
            can_dispatch = False
            stripped.append(arg)
            if index + 1 < len(argv):
                stripped.append(argv[index + 1])
                index += 1
        elif arg in OPTIONAL_VALUE_FLAGS:
            can_dispatch = False
            stripped.append(arg)
            following = argv[index + 1] if index + 1 < len(argv) else None
            if following is not None and not following.startswith("-") and following != "":
                stripped.append(following)
                index += 1
        elif _is_unknown_long(arg):
            can_dispatch = False
            stripped.append(arg)
            following = argv[index + 1] if index + 1 < len(argv) else None
            if following is not None and not following.startswith("-"):
                stripped.append(following)
                index += 1
        else:
            if can_dispatch and _is_subcommand(arg) and arg not in LAUNCH_FLAG_COMMANDS:
                saw_subcommand = True
            can_dispatch = False
            stripped.append(arg)
        index += 1
    if alias:
        raise Refused("--alias installs a profile alias and exits")
    return stripped


def _reserved_word(argv):
    first = argv[0] if argv else None
    if not first or first.startswith(("-", "@")) or first not in RESERVED_WORDS:
        return False
    if len(argv) < 2:
        return True
    if first == "marketplace" and argv[1] in MARKETPLACE_SUBCOMMANDS:
        return True
    return any(not arg.startswith("-") and "@" in arg for arg in argv[1:])


def _leading_subcommand_index(argv):
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--":
            return -1
        if not arg.startswith("-"):
            return index if _is_subcommand(arg) else -1
        if _flag_consumes_value(arg, argv[index + 1] if index + 1 < len(argv) else None):
            index += 1
        index += 1
    return -1


def _strip_launch_global_flags(leading):
    kept, index = [], 0
    while index < len(leading):
        arg = leading[index]
        name = arg.split("=", 1)[0] if arg.startswith("--") and "=" in arg else arg
        known = (name in STRING_VALUE_FLAGS or name in OPTIONAL_VALUE_FLAGS or name in VALUELESS_FLAGS
                 or name in SHADOWABLE_STRING_FLAGS)
        if known:
            if _flag_consumes_value(arg, leading[index + 1] if index + 1 < len(leading) else None):
                index += 1
        else:
            kept.append(arg)
        index += 1
    return kept


def _resolve_cli_argv(argv):
    if _reserved_word(argv):
        raise Refused("the CLI exits: a reserved management word")
    first = argv[0] if argv else None
    if first in HELP_WORDS:
        return argv
    if _is_subcommand(first):
        return argv
    sub = _leading_subcommand_index(argv)
    if sub >= 0:
        leading, trailing = argv[:sub], argv[sub + 1:]
        forwarded = leading if argv[sub] in LAUNCH_FLAG_COMMANDS else _strip_launch_global_flags(leading)
        return [argv[sub], *forwarded, *trailing]
    return ["launch", *argv]


def _prepare_terminal_auth(raw):
    without = [arg for arg in raw if arg != ACP_TERMINAL_AUTH_FLAG]
    if len(without) == len(raw):
        return without, False
    args, index = [], 0
    while index < len(without):
        arg = without[index]
        if arg == "--mode":
            index += 2
            continue
        if not arg.startswith("--mode="):
            args.append(arg)
        index += 1
    return args, True


def _launch_flags(args):
    """The slice of parseArgs that decides the run mode: print, mode, help, version, export."""
    args = list(args)
    found = {"print": False, "mode": False, "help": False, "version": False, "export": False}
    index, separator = 0, False
    while index < len(args):
        arg = args[index]
        if separator or arg == BOUNDARY_ARG:
            index += 1
            continue
        if arg.startswith("--") and "=" in arg:
            name, value = arg.split("=", 1)
            args[index] = name
            args.insert(index + 1, value)
            arg = name
        if arg in STRING_VALUE_FLAGS:
            if index + 1 < len(args) and args[index + 1] != BOUNDARY_ARG:
                if arg == "--mode":
                    found["mode"] = True
                if arg == "--export":
                    found["export"] = True
                index += 1
        elif arg in OPTIONAL_VALUE_FLAGS:
            following = args[index + 1] if index + 1 < len(args) else None
            if following is not None and not following.startswith("-") and following != "":
                index += 1
        elif arg in ("--help", "-h"):
            found["help"] = True
        elif arg in ("--version", "-v"):
            found["version"] = True
        elif arg in ("--print", "-p"):
            found["print"] = True
        elif arg == "--":
            separator = True
        index += 1
    return found


def decide_role(args, stdin):
    """args is argv after the script path. Raises Refused or Unresolved, else returns."""
    stripped = extract_profile_flags(args)
    if stripped and stripped[0].startswith(SELECTOR_PREFIX):
        raise Refused("an omp worker-role invocation, not the interactive agent")
    if stripped and stripped[0] in ("--license", "--smoke-test"):
        raise Refused("a one-shot omp command, not the interactive agent")
    resolved = _resolve_cli_argv(stripped)
    command = resolved[0] if resolved else ""
    if command not in LAUNCH_FLAG_COMMANDS:
        raise Refused(f"omp runs `{command}` as a command or help, not as the interactive agent")
    cleaned, terminal_auth = _prepare_terminal_auth(resolved[1:])
    if command == "acp" and not terminal_auth:
        raise Refused("`acp` without terminal auth is the ACP protocol role")
    flags = _launch_flags(cleaned)
    for key, why in (("mode", "a --mode run is a protocol or text role"), ("print", "print mode is not interactive"),
                     ("help", "help exits"), ("version", "version exits"), ("export", "--export exits")):
        if flags[key]:
            raise Refused(why)
    if stdin is None:
        raise Unresolved("the standard-input type of the process cannot be read")
    if stdin != "tty":
        raise Refused(f"standard input is {stdin}, not a terminal: omp runs this as headless print mode")


# --- facts and the decision --------------------------------------------------

def _read_fact(command, pid):
    try:
        result = subprocess.run([sys.executable, "-I", PROC_INFO, command, str(pid)], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", "surrogateescape").rstrip("\n") or None


def _regular(path):
    """True for a regular file, False for anything else or nothing there, None when unreadable."""
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError:
        return None


def _existing_real(path):
    """The real path of a path that exists, None when it does not or cannot be read."""
    real = os.path.realpath(path)
    try:
        os.lstat(real)
    except OSError:
        return None
    return real


def _package_name(directory):
    """The name in directory's regular package.json; "" when it has none; None when unreadable."""
    path = os.path.join(directory, "package.json")
    regular = _regular(path)
    if not regular:
        return "" if regular is False else None
    try:
        with open(path, encoding="utf-8") as handle:
            name = json.load(handle).get("name")
    except (OSError, ValueError, AttributeError):
        return None
    return name if isinstance(name, str) else ""


def installed_identity(root=None):
    """The one trusted installed identity, or None.

    {"root", "runtime", "script"}, each a canonical path: the identity is its own
    canonical form, so no link inside it can be retargeted after a process starts and
    change which file the identity names. The root is the installed omp's root under the
    account's home directory (the passwd entry, never $HOME, and no environment variable,
    so the environment holds no override). The `root` parameter is the test-only seam: no
    code under bin/ passes it, and production reads it from nowhere. The root is anchored
    by resolving its PARENT and keeping its own final name; a root that is itself a link is
    not the trusted root. None when it cannot be derived: no home, a missing or linked
    root, a missing runtime or script, or a runtime or script reached through any link.
    """
    if root is None:
        try:
            home = pwd.getpwuid(os.getuid()).pw_dir
        except (KeyError, OSError):
            return None
        root = os.path.join(home, INSTALLED_ROOT)
    if not os.path.isabs(root):
        return None
    root = os.path.normpath(root)
    parent = _existing_real(os.path.dirname(root))
    if not parent or not os.path.basename(root):
        return None
    anchored = os.path.join(parent, os.path.basename(root))
    try:
        if not stat.S_ISDIR(os.lstat(anchored).st_mode):
            return None
    except OSError:
        return None
    runtime = os.path.join(anchored, INSTALLED_RUNTIME)
    script = os.path.join(anchored, INSTALLED_SCRIPT)
    if _existing_real(runtime) != runtime or _existing_real(script) != script:
        return None
    return {"root": anchored, "runtime": runtime, "script": script}


def _start_ns(start):
    """The process start identity "SECONDS.MICROSECONDS" as nanoseconds, or None."""
    try:
        seconds, _, micros = str(start).partition(".")
        return int(seconds) * 1_000_000_000 + int((micros + "000000")[:6]) * 1000
    except (TypeError, ValueError):
        return None


def tree_settled(installed, start):
    """True when every inode from the installed root down to the runtime and to the script
    has an inode-change time at or before the process start; False when any is later; None
    when that cannot be read. This is the launch-time tie for admission: what a process
    loaded through these paths cannot have been replaced since it started unless one of
    these inodes changed."""
    started = _start_ns(start)
    if started is None or not isinstance(installed, dict):
        return None
    root = installed.get("root")
    if not isinstance(root, str) or not root:
        return None
    paths = [root]
    for target in (installed.get("runtime"), installed.get("script")):
        if not isinstance(target, str) or os.path.commonpath([root, target]) != root:
            return None
        parts = os.path.relpath(target, root).split(os.sep)
        paths += [os.path.join(root, *parts[:n]) for n in range(1, len(parts) + 1)]
    try:
        return all(os.lstat(path).st_ctime_ns <= started for path in paths)
    except OSError:
        return None


def read_evidence(exe, argv):
    """What the tree around the process's own executable and script shows."""
    evidence = {}
    exe_real = _existing_real(exe) if exe else None
    if exe_real:
        regular = _regular(exe_real)
        evidence.update(exe_real=exe_real, exe_regular_executable=regular and os.access(exe_real, os.X_OK),
                        runtime_package=_package_name(os.path.dirname(os.path.dirname(exe_real))))
    script_real = None
    if isinstance(argv, list) and len(argv) > 1 and os.path.isabs(argv[1]):
        script_real = _existing_real(argv[1])
    if script_real:
        root = os.path.dirname(os.path.dirname(script_real))
        markers = [_regular(os.path.join(root, marker)) for marker in SCRIPT_MARKERS]
        evidence.update(script_real=script_real, script_regular=_regular(script_real),
                        script_package=_package_name(root),
                        script_markers=False if False in markers else None if None in markers else True)
    return evidence


def live_facts(pid):
    facts = {"pid": int(pid), "start": _read_fact("startid", pid), "exe": _read_fact("exe", pid),
             "stdin": _read_fact("stdin", pid)}
    raw = _read_fact("argv", pid)
    try:
        facts["argv"] = json.loads(raw) if raw else None
    except ValueError:
        facts["argv"] = None
    facts["evidence"] = read_evidence(facts["exe"], facts["argv"])
    facts["installed"] = installed_identity()
    facts["evidence"]["tree_settled"] = tree_settled(facts["installed"], facts["start"])
    return facts


def holds_file(writable, path):
    """True when one of the process's writable regular files is the file at path and it holds
    no other session file. Raises Unresolved when it holds the file AND another writable
    .jsonl outside that session's own artifact directory: which session is current cannot
    then be proved (a retained old descriptor and a legitimate second file look the same)."""
    try:
        target = os.stat(path)
    except OSError:
        return False
    if not isinstance(writable, list):
        raise Unresolved("the process's open files cannot be read")
    device = target.st_dev & 0xFFFFFFFF
    entries = [entry for entry in writable if isinstance(entry, dict)]

    def same(entry):
        return entry.get("ino") == target.st_ino and entry.get("dev") == device

    if not any(same(entry) for entry in entries):
        return False
    artifacts = os.path.splitext(os.path.realpath(path))[0] + os.sep
    for entry in entries:
        name = entry.get("path")
        if same(entry) or not isinstance(name, str) or not name.endswith(".jsonl"):
            continue
        if not (name.startswith(artifacts) or os.path.realpath(name).startswith(artifacts)):
            raise Unresolved("the process holds another session file open for writing, so which session is current cannot be proved")
    return True


def _settled(value, what):
    if value is None:
        raise Unresolved(f"{what} cannot be read")
    return value


def decide(facts):
    """Raise Refused or Unresolved unless facts are the installed omp's interactive agent.

    Foreign (positively another program) is raised only from the raw argument vector the
    kernel holds for the process. Everything read from the filesystem now (the executable's
    path, the script's resolution, package names, marker files, the installed identity and
    its change times) can only refuse adoption (Refused) or leave it unresolved, because a
    running process keeps what it loaded after those files change.
    """
    exe, argv, evidence = facts.get("exe"), facts.get("argv"), facts.get("evidence")
    if not facts.get("start"):
        raise Unresolved("the process start identity cannot be read")
    if not exe:
        raise Unresolved("the actual executable path cannot be read")
    if not isinstance(argv, list) or not argv or not all(isinstance(word, str) for word in argv):
        raise Unresolved("the argument vector cannot be read with its boundaries")
    if not isinstance(evidence, dict):
        raise Unresolved("the installed tree evidence cannot be read")
    exe_real = _settled(evidence.get("exe_real"), "the actual executable path")
    # Foreign: raw argument bytes only.
    if os.path.basename(argv[0]) != "bun":
        raise Foreign("argv[0] is not a bun")
    if len(argv) < 2:
        raise Foreign("the runtime runs no script")
    if not os.path.isabs(argv[1]):
        raise Unresolved("the script argument is not an absolute path")
    if os.path.basename(argv[1]) != "cli.ts" or os.path.basename(os.path.dirname(argv[1])) != "src":
        raise Foreign("the script argument is not a cli.ts in a src directory")
    # From here on only Refused or Unresolved: what the files say now never proves a program foreign.
    script_real = _settled(evidence.get("script_real"), "the script path")
    if os.path.basename(exe_real) != "bun" or os.path.basename(os.path.dirname(exe_real)) != "bin":
        raise Refused("the executable is not a bun in a bin directory now")
    if os.path.basename(script_real) != "cli.ts" or os.path.basename(os.path.dirname(script_real)) != "src":
        raise Refused("the script argument does not resolve to a cli.ts in a src directory now")
    if not _settled(evidence.get("exe_regular_executable"), "the executable file"):
        raise Refused("the executable is not a regular executable file now")
    if not _settled(evidence.get("runtime_package"), "the runtime package").startswith(RUNTIME_PACKAGE_PREFIX):
        raise Refused("the executable is not in a Bun runtime package now")
    if not _settled(evidence.get("script_regular"), "the script file"):
        raise Refused("the script is not a regular file now")
    if _settled(evidence.get("script_package"), "the script package") != SCRIPT_PACKAGE:
        raise Refused("the script is not in the omp package now")
    if not _settled(evidence.get("script_markers"), "the omp package files"):
        raise Refused("the omp package lacks its command and main files now")
    installed = facts.get("installed")
    if not isinstance(installed, dict):
        raise Unresolved("the installed identity cannot be read")
    runtime, script = installed.get("runtime"), installed.get("script")
    if not (isinstance(runtime, str) and isinstance(script, str) and runtime and script):
        raise Unresolved("the installed identity cannot be read")
    if argv[1] != script:
        raise Refused("the script argument is not, byte for byte, the installed omp's entry script")
    if exe_real != runtime:
        raise Refused("an omp-shaped program that is not the installed omp's runtime")
    # The role is judged from the raw arguments and the descriptor table the kernel holds, so a worker or
    # print role is refused whatever happened to the tree; the tie to launch time is the last gate.
    decide_role(argv[2:], facts.get("stdin"))
    if not _settled(evidence.get("tree_settled"), "whether the installed tree changed after the process started"):
        raise Unresolved("the installed tree changed after the process started, so what the process loaded through it cannot be proved")


def _valid_source(source):
    return (len(source) == 1 and source[0].isdigit()) or (len(source) == 2 and source[0] == "--facts")


def _load_facts(source):
    if source[0] == "--facts":
        with open(source[1], encoding="utf-8") as handle:
            return json.load(handle)
    return live_facts(source[0])


def _writer(source):
    try:
        decide(_load_facts(source))
    except Foreign as error:
        print(f"unrelated: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"may own: {error}", file=sys.stderr)
        return 0
    print("may own: the installed omp interactive agent", file=sys.stderr)
    return 0


def _interactive(source):
    try:
        facts = _load_facts(source)
        decide(facts)
    except Refused as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"unresolved: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"verdict": "interactive", "start": facts["start"], "pid": facts.get("pid")}))
    return 0


def main(argv):
    args = argv[1:]
    if args[:1] == ["holds"]:
        writable = None
        if len(args) == 3 and args[1].isdigit():
            raw = _read_fact("writable", args[1])
            try:
                writable = json.loads(raw) if raw else None
            except ValueError:
                writable = None
        elif len(args) == 4 and args[1] == "--facts":
            try:
                with open(args[2], encoding="utf-8") as handle:
                    writable = json.load(handle).get("writable")
            except (OSError, ValueError, AttributeError):
                writable = None
        else:
            print(__doc__.split("\n\n")[0], file=sys.stderr)
            return 64
        try:
            return 0 if holds_file(writable, args[-1]) else 1
        except Unresolved:
            return 2
    if len(args) == 2 and args[0] == "facts" and args[1].isdigit():
        facts = live_facts(args[1])
        raw = _read_fact("writable", args[1])
        try:
            facts["writable"] = json.loads(raw) if raw else None
        except ValueError:
            facts["writable"] = None
        print(json.dumps(facts))
        return 0
    source = args[1:]
    if args[:1] == ["writer"] and _valid_source(source):
        return _writer(source)
    if args[:1] == ["interactive"] and _valid_source(source):
        return _interactive(source)
    print(__doc__.split("\n\n")[0], file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
