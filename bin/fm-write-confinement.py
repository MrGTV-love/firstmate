#!/usr/bin/env python3
"""Build a macOS Seatbelt profile for one isolated ship/scout worker.

Usage: fm-write-confinement.py --worktree DIR --data DIR --state DIR
       --task ID --temp DIR --harness {omp,claude} --profile FILE
       [--agent-dir DIR] [--branch NAME]

The caller wraps its final launch with sandbox-exec -f FILE. Linux launch
selection belongs to fm-spawn.sh and deliberately does not invoke this builder.
No credentials are copied and no shared state-directory grant is made.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def canonical(value):
    return str(Path(value).expanduser().resolve())


def quoted(value):
    return json.dumps(str(value), ensure_ascii=False)


def build(args):
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}", args.task):
        raise ValueError("invalid task id")
    worktree = canonical(args.worktree)
    roots = [worktree, canonical(args.data), canonical(args.temp)]
    gitdir = canonical(subprocess.check_output(
        ["git", "-C", worktree, "rev-parse", "--absolute-git-dir"], text=True).strip())
    common = canonical(subprocess.check_output(
        ["git", "-C", worktree, "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True).strip())
    if gitdir == common:
        raise ValueError("worker must use an isolated linked worktree")
    roots.extend([gitdir, str(Path(common) / "objects")])
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
        config = Path(str(Path.home()) + "/" + (os.environ.get("PI_CONFIG_DIR") or ".omp"))
        if profile:
            config = config / "profiles" / profile
        agent = config / "agent" if profile else (args.agent_dir or os.environ.get("PI_CODING_AGENT_DIR") or config / "agent")
        roots.append(canonical(agent))
        key = subprocess.check_output([
            "bun", "-e", "console.log(Bun.hash.wyhash(require('path').resolve(process.argv[1])).toString(16).padStart(16,'0'))",
            worktree,
        ], text=True).strip()
        if not re.fullmatch(r"[0-9a-f]{16}", key):
            raise ValueError("invalid omp daemon scope hash")
        roots.append(canonical(config / "run/daemons" / key))
    else:
        roots.append(canonical(args.agent_dir or os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"))
    lines = ["(version 1)", "(allow default)", "(deny file-write*)"]
    for root in dict.fromkeys(roots):
        lines.append(f"(allow file-write* (subpath {quoted(root)}))")
    state = re.escape(canonical(args.state))
    task = re.escape(args.task)
    # A single suffix segment cannot alias a longer dotted task id. Only the
    # busy writer's numeric temporary siblings and lock directory add segments.
    for pattern in (
        rf"^{state}/{task}\.[^/.]+$",
        rf"^{state}/{task}\.(inbox|git-hooks)(/.*)?$",
        rf"^{state}/{task}\.busy-state\.lock(/.*)?$",
        rf"^{state}/{task}\.busy-(state|gen)\.tmp\.[0-9]+$",
        rf"^{state}/{task}\.jev-guard\.jsonl$",
        rf"^{state}/{task}\.omp-session\.json$",
        rf"^{state}/{task}\.omp-session\.json\.[0-9]+\.[0-9]+\.tmp$",
    ):
        # Seatbelt #"..." regex literals preserve backslashes, unlike ordinary
        # quoted Scheme strings. JSON's doubled backslashes would match the
        # wrong path and silently disable legitimate status/busy writes.
        regex_literal = quoted(pattern).replace("\\\\", "\\")
        lines.append(f"(allow file-write* (regex #{regex_literal}))")
    # A task's declared branch and its atomic lock/reflog are separate from the
    # shared object store. Never grant the common refs or logs parent.
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
    lines.append('(allow file-write-data (literal "/dev/null"))')
    # Default Claude stores config beside, not inside, its .claude directory.
    if args.harness == "claude" and not (args.agent_dir or os.environ.get("CLAUDE_CONFIG_DIR")):
        lines.append(f"(allow file-write* (literal {quoted(Path.home() / '.claude.json')}))")
    Path(args.profile).write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("worktree", "data", "state", "task", "temp", "profile"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--harness", choices=("omp", "claude"), required=True)
    parser.add_argument("--agent-dir")
    parser.add_argument("--branch", default="")
    args = parser.parse_args()
    try:
        build(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: cannot prepare worker write confinement: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
