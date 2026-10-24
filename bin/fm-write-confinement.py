#!/usr/bin/env python3
"""Build a macOS Seatbelt profile for one isolated ship/scout worker.

Usage: fm-write-confinement.py --worktree DIR --home DIR --config DIR
       --projects DIR --data DIR --state DIR --task ID
       --harness {omp,claude} --profile FILE
       [--agent-dir DIR] [--branch NAME] [--protect DIR ...]

Writes are allowed by default; the profile denies writes to named protected
assets: project primary checkouts, other task worktrees, other task state and
data, Main-owned records of this task, this home's config and .env, harness
config homes, other Firstmate homes (--protect) and other projects' no-mistakes
gate repositories. --data is this task's directory below the home data root.
The caller wraps its final launch with sandbox-exec -f FILE. Linux launch
selection belongs to fm-spawn.sh and deliberately does not invoke this builder.
No credentials are copied.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

# Harness config homes below HOME. The running harness regains only its
# measured state roots below; every other harness home stays protected.
HARNESS_HOMES = (".claude", ".claude.json", ".omp", ".codex", ".dsh", ".pi", ".grok", ".kimi", ".kimi-code",
                 ".cursor", ".gemini", ".rovo", ".rovodev", ".config/opencode", ".local/share/opencode")
# The only state/<task>.* records the worker tree itself writes; every other
# record of this task is Main-authored and stays protected.
WORKER_RECORDS = (
    r"(status|turn-ended|busy-state|live-model|jev-guard\.jsonl|omp-session\.json|claude-diagnostics\.jsonl)",
    r"inbox(/.*)?",
    r"busy-state\.lock(/.*)?",
    r"busy-state\.tmp\.[0-9]+",
    r"live-model\.[0-9]+\.tmp",
    r"omp-session\.json\.[0-9]+\.[0-9]+\.tmp",
)


def canonical(value):
    return str(Path(value).expanduser().resolve())


def quoted(value):
    return json.dumps(str(value), ensure_ascii=False)


def regex(pattern):
    # Seatbelt #"..." regex literals preserve backslashes, unlike ordinary
    # quoted Scheme strings. JSON's doubled backslashes would match the wrong
    # path and silently disable legitimate status/busy writes.
    return "(regex #" + quoted(pattern).replace("\\\\", "\\") + ")"


def git_lines(*args):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    return result.stdout.splitlines() if result.returncode == 0 else []


def build(args):
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}", args.task):
        raise ValueError("invalid task id")
    home = Path.home()
    worktree = canonical(args.worktree)
    gitdir = canonical(subprocess.check_output(
        ["git", "-C", worktree, "rev-parse", "--absolute-git-dir"], text=True).strip())
    common = canonical(subprocess.check_output(
        ["git", "-C", worktree, "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True).strip())
    if gitdir == common:
        raise ValueError("worker must use an isolated linked worktree")
    data = canonical(args.data)
    data_root = str(Path(data).parent)
    state = canonical(args.state)
    deny = [canonical(home / name) for name in HARNESS_HOMES]
    deny += [canonical(args.home), state, canonical(args.config)]
    deny += [canonical(path) for path in args.protect]
    primaries = [canonical(path) for path in Path(args.projects).iterdir() if path.is_dir()] if Path(args.projects).is_dir() else []
    if Path(common).name == ".git":
        primaries.append(str(Path(common).parent))
    deny += primaries
    for primary in dict.fromkeys(primaries):
        for line in git_lines("-C", primary, "worktree", "list", "--porcelain"):
            if line.startswith("worktree ") and canonical(line[9:]) != worktree:
                deny.append(canonical(line[9:]))
    # Gate repositories are named as no-mistakes names them: the first 12 hex
    # digits of the SHA-256 of the project's primary checkout path.
    gates = Path(os.environ.get("NM_HOME") or home / ".no-mistakes") / "repos"
    own_gate = hashlib.sha256(str(Path(common).parent).encode()).hexdigest()[:12] + ".git"
    if gates.is_dir():
        deny += [canonical(gate) for gate in gates.iterdir() if gate.name.endswith(".git") and gate.name != own_gate]

    harness_roots, harness_protected = [], []
    if args.harness == "omp":
        # Match omp's macOS resolver: XDG applies only on Linux; a named
        # profile selects its own agent directory instead of the override.
        profile = os.environ.get("OMP_PROFILE", os.environ.get("PI_PROFILE", "")).strip()
        if profile == "default":
            profile = ""
        if profile and (
            not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", profile)
            or profile.endswith(".")
            or re.fullmatch(r"(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\..*)?", profile, re.IGNORECASE)
        ):
            raise ValueError("invalid omp profile spelling")
        # Node path.join keeps a leading slash in this suffix under HOME;
        # pathlib's / operator would instead discard HOME for that spelling.
        config = Path(str(home) + "/" + (os.environ.get("PI_CONFIG_DIR") or ".omp"))
        deny.append(canonical(config))
        if profile:
            config = config / "profiles" / profile
        agent = canonical(config / "agent" if profile else (args.agent_dir or os.environ.get("PI_CODING_AGENT_DIR") or config / "agent"))
        key = subprocess.check_output([
            "bun", "-e", "console.log(Bun.hash.wyhash(require('path').resolve(process.argv[1])).toString(16).padStart(16,'0'))",
            worktree,
        ], text=True).strip()
        if not re.fullmatch(r"[0-9a-f]{16}", key):
            raise ValueError("invalid omp daemon scope hash")
        harness_roots += [f"(subpath {quoted(agent)})", f"(subpath {quoted(canonical(config / 'run/daemons' / key))})"]
        harness_protected += [f"(literal {quoted(agent + '/' + name)})" for name in ("config.yml", "models.yml", "auth.json", ".env")]
    else:
        claude = canonical(args.agent_dir or os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
        harness_roots.append(f"(subpath {quoted(claude)})")
        # Default Claude stores config beside, not inside, its .claude directory.
        if not (args.agent_dir or os.environ.get("CLAUDE_CONFIG_DIR")):
            harness_roots.append(f"(literal {quoted(home / '.claude.json')})")
        harness_protected += [f"(literal {quoted(claude + '/' + name)})" for name in ("settings.json", "settings.local.json", ".credentials.json")]
        harness_protected.append(regex("^" + re.escape(claude) + "/projects/[^/]+/memory(/.*)?$"))

    lines = ["(version 1)", "(allow default)"]
    lines += [f"(deny file-write* (subpath {quoted(path)}))" for path in dict.fromkeys(deny)]
    # Shared roots inside protected assets that the worker's ordinary tools
    # write: the home data root (duration ledger) and its own repository's
    # shared Git directory (objects, remote-tracking refs, stash, config).
    lines.append(f"(allow file-write* (subpath {quoted(data_root)}))")
    lines.append(f"(allow file-write* (subpath {quoted(common)}))")
    lines += [f"(allow file-write* {root})" for root in harness_roots]
    lines.append("(deny file-write* " + regex("^" + re.escape(data_root) + "/[^/]+/") + ")")
    for name in ("worktrees", "refs/heads", "logs/refs/heads"):
        lines.append(f"(deny file-write* (subpath {quoted(Path(common) / name)}))")
    # The primary checkout's own HEAD and index live in the shared Git directory.
    for name in ("HEAD", "HEAD.lock", "index", "index.lock"):
        lines.append(f"(deny file-write* (literal {quoted(Path(common) / name)}))")
    for root in (worktree, gitdir, data):
        lines.append(f"(allow file-write* (subpath {quoted(root)}))")
    for record in WORKER_RECORDS:
        lines.append("(allow file-write* " + regex("^" + re.escape(state + "/" + args.task + ".") + record + "$") + ")")
    # A task's declared branch and its atomic lock/reflog are separate from
    # other tasks' branches in the same shared refs directory.
    if args.branch:
        subprocess.run(["git", "check-ref-format", "--branch", args.branch],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ref = "refs/heads/" + args.branch
        for path in (Path(common) / ref, Path(common) / "logs" / ref):
            # Git must create only the declared ref and atomic lock, not gain
            # write permission to the shared parent of other tasks' refs.
            path.parent.mkdir(parents=True, exist_ok=True)
            for suffix in ("", ".lock"):
                lines.append(f"(allow file-write* (literal {quoted(str(path) + suffix)}))")
    lines += [f"(deny file-write* {item})" for item in harness_protected]
    Path(args.profile).write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("worktree", "home", "config", "projects", "data", "state", "task", "profile"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--harness", choices=("omp", "claude"), required=True)
    parser.add_argument("--agent-dir")
    parser.add_argument("--branch", default="")
    parser.add_argument("--protect", action="append", default=[])
    args = parser.parse_args()
    try:
        build(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: cannot prepare worker write confinement: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
