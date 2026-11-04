#!/usr/bin/env python3
"""Recognize the installed omp's Bun runtime as the omp interactive agent.

Usage: fm-omp-identity.py interactive (PID | --facts FILE) [--launcher PATH]
       fm-omp-identity.py writer PID [--launcher PATH]
       fm-omp-identity.py facts PID [--launcher PATH]
       fm-omp-identity.py holds (PID | --facts FILE) SESSION-FILE
       fm-omp-identity.py startid PID

Why this exists. The host's `omp` can be a /bin/sh launcher that `exec`s the Bun
runtime on the installed omp entry script, so the live process is named `bun`
and only its argument vector names omp. A name match cannot recognize that
process, and a bare `bun` match would admit every Bun program. This helper is
the single owner of that identity rule; bin/fm-launch-proof-lib.sh is its only
production caller.

Identity. The installed omp is derived from the launcher: `omp` on PATH, or
the file named by FM_OMP_LAUNCHER (or --launcher), must be a text launcher whose
only command is `exec "<runtime>" "<entry script>" "$@"`, optionally after plain
NAME=value assignments the exec line expands. A launcher in any other form, a
file that cannot be read, a runtime or script that does not exist, or a path
whose real location leaves the launcher's own root is underivable, so nothing
is recognized (fail closed). No version is pinned. A process is the installed
omp only when ALL of these hold: its kernel executable path (fm-proc-info.py
exe, never an argument word) resolves to the installed runtime; the argument
after argv[0] resolves to the installed entry script; and its role is the
interactive agent.

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
after launch). The installed omp's session writer opens its session file for
append once and keeps the descriptor for the life of the session
(session/session-storage.ts, FileSessionStorageWriter), so `holds` reports whether the
process holds a given regular file open for writing, by device and inode, read from
the kernel (fm-proc-info.py writable). Exit 0 holds it, 1 does not, 2 unreadable.
Adoption of a Bun-shaped process requires it, so a process that is not positively
tied to the task's preserved session stays unadopted.

Exit status. interactive: 0 the process is the installed omp's interactive
agent (stdout is JSON carrying the incarnation `start`), 1 refused (a foreign
executable or script, or another role), 2 unresolved (evidence unavailable).
writer: 0 the process may own an omp session record (the installed omp in any
role, or anything whose identity cannot be read), 1 it is positively another
program. Reasons go to stderr. Nothing here reads a process environment, sends
a signal, or touches any file but the launcher and the paths it names.
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROC_INFO = os.path.join(HERE, "fm-proc-info.py")

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


class Underivable(Unresolved):
    """The installed omp identity cannot be derived."""


# --- the installed identity -------------------------------------------------

def _expand(text, assigned):
    def sub(match):
        name = match.group(1) or match.group(2)
        if name not in assigned:
            raise Underivable("launcher expands an unknown variable")
        return assigned[name]
    out = re.sub(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))", sub, text)
    if "$" in out or "`" in out or "\\" in out:
        raise Underivable("launcher uses an unsupported expansion")
    return out


def installed_identity(launcher=None):
    """Return (runtime_real, script_real) derived from the omp launcher."""
    launcher = launcher or os.environ.get("FM_OMP_LAUNCHER") or shutil.which("omp")
    if not launcher:
        raise Underivable("no omp launcher is available")
    try:
        with open(launcher, "rb") as handle:
            text = handle.read(65536).decode("utf-8")
    except (OSError, UnicodeDecodeError):
        raise Underivable("the omp launcher is not a readable text file") from None
    assigned, command = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", line)
        if match and command is None:
            value = match.group(2)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            assigned[match.group(1)] = _expand(value, assigned)
        elif line.startswith("exec ") and command is None:
            command = line
        else:
            raise Underivable("the omp launcher has a line this rule does not read")
    if command is None:
        raise Underivable("the omp launcher has no exec line")
    try:
        words = shlex.split(command, posix=True)
    except ValueError:
        raise Underivable("the omp launcher exec line cannot be split") from None
    if len(words) != 4 or words[0] != "exec" or words[3] != "$@":
        raise Underivable("the omp launcher exec line is not `exec <runtime> <script> \"$@\"`")
    runtime, script = _expand(words[1], assigned), _expand(words[2], assigned)
    if not (os.path.isabs(runtime) and os.path.isabs(script)):
        raise Underivable("the omp launcher paths are not absolute")
    try:
        runtime_real, script_real = os.path.realpath(runtime, strict=True), os.path.realpath(script, strict=True)
        root = os.path.commonpath((runtime, script))
        root_real = os.path.realpath(root, strict=True)
    except (OSError, ValueError):
        raise Underivable("the omp launcher names a runtime or script that does not exist") from None
    if not (os.path.isfile(runtime_real) and os.path.isfile(script_real)):
        raise Underivable("the omp launcher runtime or script is not a file")
    # A link at an installed path that leaves the installed tree would let the
    # identity follow it to an attacker-chosen file.
    for real in (runtime_real, script_real):
        if root_real == os.sep or not real.startswith(root_real + os.sep):
            raise Underivable("the omp launcher paths resolve outside the installed tree")
    return runtime_real, script_real


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


def live_facts(pid):
    facts = {"pid": int(pid), "start": _read_fact("startid", pid), "exe": _read_fact("exe", pid),
             "stdin": _read_fact("stdin", pid)}
    raw = _read_fact("argv", pid)
    try:
        facts["argv"] = json.loads(raw) if raw else None
    except ValueError:
        facts["argv"] = None
    return facts


def holds_file(writable, path):
    """True when one of the process's writable regular files is the file at path."""
    try:
        target = os.stat(path)
    except OSError:
        return False
    if not isinstance(writable, list):
        raise Unresolved("the process's open files cannot be read")
    return any(isinstance(entry, dict) and entry.get("ino") == target.st_ino
               and entry.get("dev") == (target.st_dev & 0xFFFFFFFF) for entry in writable)


def decide(facts, identity):
    """Raise Refused or Unresolved unless facts are the installed omp's interactive agent."""
    runtime_real, script_real = identity
    exe, argv = facts.get("exe"), facts.get("argv")
    if not facts.get("start"):
        raise Unresolved("the process start identity cannot be read")
    if not exe:
        raise Unresolved("the actual executable path cannot be read")
    if not isinstance(argv, list) or not all(isinstance(word, str) for word in argv):
        raise Unresolved("the argument vector cannot be read with its boundaries")
    try:
        exe_real = os.path.realpath(exe, strict=True)
    except OSError:
        raise Unresolved("the actual executable path does not resolve") from None
    if exe_real != runtime_real:
        raise Foreign("the executable is not the installed omp runtime")
    if len(argv) < 2:
        raise Foreign("the installed runtime runs no script")
    if not os.path.isabs(argv[1]):
        raise Unresolved("the script argument is not an absolute path")
    try:
        script = os.path.realpath(argv[1], strict=True)
    except OSError:
        raise Foreign("the script argument does not resolve to the installed entry script") from None
    if script != script_real:
        raise Foreign("the script is not the installed omp entry script")
    decide_role(argv[2:], facts.get("stdin"))


def _identity_or_none(launcher):
    try:
        return installed_identity(launcher)
    except Underivable as error:
        return error


def main(argv):
    args = argv[1:]
    launcher = None
    if "--launcher" in args:
        at = args.index("--launcher")
        launcher = args[at + 1] if at + 1 < len(args) else None
        del args[at:at + 2]
    if len(args) == 2 and args[0] == "startid" and args[1].isdigit():
        value = _read_fact("startid", args[1])
        if not value:
            return 2
        print(value)
        return 0
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
        identity = _identity_or_none(launcher)
        if not isinstance(identity, Exception):
            facts["identity"] = {"runtime": identity[0], "script": identity[1]}
        print(json.dumps(facts))
        return 0
    valid = ((len(args) == 2 and args[0] in ("interactive", "writer") and args[1].isdigit())
             or (len(args) == 3 and args[:2] == ["interactive", "--facts"]))
    if not valid:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 64
    mode = args[0]
    if args[1] == "--facts":
        try:
            with open(args[2], encoding="utf-8") as handle:
                facts = json.load(handle)
        except (OSError, ValueError):
            print("unresolved: the captured facts cannot be read", file=sys.stderr)
            return 2
        captured = facts.get("identity") if isinstance(facts, dict) else None
        identity = (captured["runtime"], captured["script"]) if isinstance(captured, dict) \
            and captured.get("runtime") and captured.get("script") else _identity_or_none(launcher)
    else:
        facts = live_facts(args[1])
        identity = _identity_or_none(launcher)
    if mode == "writer":
        if isinstance(identity, Exception):
            print(f"may own: {identity}", file=sys.stderr)
            return 0
        try:
            decide(facts, identity)
        except Foreign as error:
            print(f"unrelated: {error}", file=sys.stderr)
            return 1
        except Refused as error:
            # Another role of the installed omp may still own the record.
            print(f"may own: {error}", file=sys.stderr)
            return 0
        except Unresolved as error:
            print(f"may own: {error}", file=sys.stderr)
            return 0
        print("may own: the installed omp interactive agent", file=sys.stderr)
        return 0
    if isinstance(identity, Exception):
        print(f"unresolved: {identity}", file=sys.stderr)
        return 2
    try:
        decide(facts, identity)
    except Refused as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    except Unresolved as error:
        print(f"unresolved: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"verdict": "interactive", "start": facts["start"], "pid": facts.get("pid")}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
