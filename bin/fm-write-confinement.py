#!/usr/bin/env python3
"""Build a macOS Seatbelt profile for one isolated ship/scout worker.

Usage: fm-write-confinement.py --worktree DIR --home DIR --config DIR
       --projects DIR --data DIR --state DIR --task ID
       --harness {omp,claude} --profile FILE
       [--agent-dir DIR] [--branch NAME] [--protect DIR ...]

Writes are allowed by default; the profile denies writes to named protected
assets: project primary checkouts, other task worktrees, other tasks' state
records, data and temp roots, Main-owned records of this task, the shared
legacy Jev audit, this home's config and .env, harness config homes apart from
the running harness's measured runtime state, other Firstmate homes (--protect)
and other projects' no-mistakes gate repositories. Each protected folder and
every folder above it also refuses rename and deletion. --data is this task's
directory below the home data root. Task ids come from the state/<id>.meta
records of this home and every --protect home. The caller wraps its final
launch with sandbox-exec -f FILE. Linux launch selection belongs to
fm-spawn.sh and deliberately does not invoke this builder. No credentials are
copied.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

TASK_ID = r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}"
# Harness config homes below HOME. The running harness regains only its
# measured runtime state below; every other harness home stays protected.
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


def under(root, pattern):
    return regex("^" + re.escape(root) + "/" + pattern + "$")


def worktrees(primary):
    # A projects entry that is not a repository has no worktrees; any other
    # Git failure leaves the protect list underivable and refuses the launch.
    if subprocess.run(["git", "-C", primary, "rev-parse", "--git-dir"], capture_output=True).returncode:
        return []
    listing = subprocess.check_output(["git", "-C", primary, "worktree", "list", "--porcelain"], text=True)
    return [canonical(line[9:]) for line in listing.splitlines() if line.startswith("worktree ")]


def task_ids(state):
    return [path.name[:-5] for path in Path(state).glob("*.meta") if re.fullmatch(TASK_ID, path.name[:-5])]


def child_dirs(root, keep):
    return [canonical(path) for path in Path(root).iterdir() if path.is_dir() and canonical(path) not in keep] if Path(root).is_dir() else []


def build(args):
    if not re.fullmatch(TASK_ID, args.task):
        raise ValueError("invalid task id")
    home = canonical(Path.home())
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
    protect = [canonical(path) for path in args.protect]
    deny = [canonical(Path(home) / name) for name in HARNESS_HOMES]
    deny += [canonical(args.home), canonical(args.config)] + protect
    primaries = [canonical(path) for path in Path(args.projects).iterdir() if path.is_dir()] if Path(args.projects).is_dir() else []
    if Path(common).name == ".git":
        primaries.append(str(Path(common).parent))
    deny += primaries
    for primary in dict.fromkeys(primaries + [canonical(args.home)]):
        deny += [path for path in worktrees(primary) if path != worktree]
    # Gate repositories are named as no-mistakes names them: the first 12 hex
    # digits of the SHA-256 of the project's primary checkout path.
    gates = Path(os.environ.get("NM_HOME") or Path(home) / ".no-mistakes") / "repos"
    own_gate = hashlib.sha256(str(Path(common).parent).encode()).hexdigest()[:12] + ".git"
    if gates.is_dir():
        deny += [canonical(gate) for gate in gates.iterdir() if gate.name.endswith(".git") and gate.name != own_gate]
    others = [task for task in dict.fromkeys(task_ids(state) + [t for h in protect for t in task_ids(Path(h) / "state")]) if task != args.task]

    runtime = []
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
        config = Path(home + "/" + (os.environ.get("PI_CONFIG_DIR") or ".omp"))
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
        deny.append(agent)
        runtime += [under(agent, r"(agent|models)\.db(-wal|-shm|-journal)?"), f"(subpath {quoted(agent + '/sessions')})",
                    f"(subpath {quoted(canonical(config / 'run/daemons' / key))})"]
        harness_protected = []
    else:
        claude = canonical(args.agent_dir or os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
        deny.append(claude)
        runtime += [under(claude, r"\.claude\.json(\..+)?"), f"(subpath {quoted(claude + '/backups')})",
                    f"(subpath {quoted(claude + '/projects')})"]
        # Default Claude stores config beside, not inside, its .claude directory.
        if not (args.agent_dir or os.environ.get("CLAUDE_CONFIG_DIR")):
            runtime.append(f"(literal {quoted(home + '/.claude.json')})")
        harness_protected = [under(claude, r"projects/[^/]+/memory(/.*)?")]

    deny = list(dict.fromkeys(deny))
    lines = ["(version 1)", "(allow default)"]
    lines += [f"(deny file-write* (subpath {quoted(path)}))" for path in deny]
    # Shared roots inside protected assets that the worker's ordinary tools
    # write: the home data root (duration ledger), the home state directory
    # (procevent, friction and fleet ledgers) and its own repository's shared
    # Git directory (objects, remote-tracking refs, stash, config).
    for root in (data_root, state, common):
        lines.append(f"(allow file-write* (subpath {quoted(root)}))")
    data_children = child_dirs(data_root, {data})
    lines.append("(deny file-write* " + under(data_root, "[^/]+/.*") + ")")
    lines.append("(deny file-write* " + under(state, re.escape(args.task) + r"\..*") + ")")
    lines.append(f"(deny file-write* (literal {quoted(state + '/jev-guard.jsonl')}))")
    for name in ("worktrees", "refs/heads", "logs/refs/heads"):
        lines.append(f"(deny file-write* (subpath {quoted(Path(common) / name)}))")
    # The primary checkout's own HEAD and index live in the shared Git directory.
    for name in ("HEAD", "HEAD.lock", "index", "index.lock"):
        lines.append(f"(deny file-write* (literal {quoted(Path(common) / name)}))")
    # Other tasks' state records and temp roots: /tmp/fm-<id>, its launch
    # sibling /tmp/fm-<id>+<token>, and ~/tmp entries whose name carries the id.
    tmp = canonical("/tmp")
    for task in others:
        lines.append("(deny file-write* " + under(state, re.escape(task) + r"\..*") + ")")
        lines.append("(deny file-write* " + under(tmp, "fm-" + re.escape(task) + r"(\+[^/]*)?(/.*)?") + ")")
        lines.append("(deny file-write* " + under(home + "/tmp", "[^/]*" + re.escape(task) + "[^/]*(/.*)?") + ")")
    # Claude's shared per-user temp root holds one directory per session
    # working directory; only this worker's own directory stays writable.
    claude_tmp = tmp + "/claude-" + str(os.getuid())
    own_slugs = {claude_tmp + "/" + re.sub(r"[^A-Za-z0-9]", "-", path) for path in (worktree, os.path.abspath(args.worktree))}
    claude_children = child_dirs(claude_tmp, own_slugs)
    lines.append("(deny file-write* " + under(claude_tmp, "[^/]+/.*") + ")")
    for root in (worktree, gitdir, data, *sorted(own_slugs)):
        lines.append(f"(allow file-write* (subpath {quoted(root)}))")
    lines.append("(allow file-write* " + under(home + "/tmp", "[^/]*" + re.escape(args.task) + "[^/]*(/.*)?") + ")")
    for record in WORKER_RECORDS:
        lines.append("(allow file-write* " + under(state, re.escape(args.task + ".") + record) + ")")
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
    lines += [f"(allow file-write* {item})" for item in runtime]
    lines += [f"(deny file-write* {item})" for item in harness_protected]
    # A protected folder, a folder holding protected entries, and every folder
    # above them refuse rename and deletion; creating children stays allowed.
    anchors = deny + data_children + claude_children + [data_root, state, common, str(gates), home + "/tmp", claude_tmp]
    fixed = []
    for anchor in anchors:
        path = Path(anchor)
        fixed += ([str(path)] if path.is_dir() else []) + [str(parent) for parent in path.parents if str(parent) != "/"]
    lines += [f"(deny file-write* (literal {quoted(path)}))" for path in dict.fromkeys(fixed)]
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
