#!/usr/bin/env python3
"""Retire Vernant slot declarations through Vernant's own entry point.

Usage: fm-slot-manifest-retire.py --project PATH --firstmate-state PATH
       [--state-dir PATH] [--apply]
Report-only by default. Lists durable and legacy records with owner and landing
status. --apply retires a record only when its owner has no live Firstmate task
record (state/<owner>.meta), its recorded PR is forge-merged, and the slot's
HEAD has no commit outside origin/main; every other record is listed and kept.
For teardown: add --slot PATH --owner-id ID --owner-branch BRANCH --apply after
its landed-work proof, or --keep REASON to leave the slot's records in place.
A slot with no record, no entry point, or no recorded merged PR keeps the old
teardown behavior. No record is removed here. The Vernant command owns locking
and both removals.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


class Refusal(Exception):
    pass


def run(args, project):
    result = subprocess.run(args, cwd=project, text=True, capture_output=True, check=False)
    if result.returncode:
        raise Refusal(f"command failed: {' '.join(args[:3])}: {result.stderr.strip()}")
    return result.stdout.strip()


def owner_meta(state, owner):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", owner):
        raise Refusal("invalid owner identity")
    return state / (owner + ".meta")


def recorded_pr(state, owner):
    meta = owner_meta(state, owner)
    if meta.is_file():
        urls = [line[3:] for line in meta.read_text().splitlines() if line.startswith("pr=")]
        if urls:
            return urls[-1]
    marker = state / (owner + ".pr-poll-merge-notified")
    if marker.is_file():
        lines = marker.read_text().splitlines()
        if len(lines) == 5 and lines[:3] == ["fm-pr-poll-merge-notified-v1", "github", "github.com"]:
            return f"https://github.com/{lines[3]}/pull/{lines[4]}"
    raise Refusal("no Firstmate-recorded PR; landing unproven")


def landing_proof(project, state, owner, fetch=False):
    url = recorded_pr(state, owner)
    match = re.fullmatch(r"https://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)", url)
    if not match:
        raise Refusal("invalid Firstmate-recorded PR URL")
    # Read the same merged-PR identities used by teardown's archive proof. The
    # API spelling avoids presentation parsing and preserves both immutable IDs.
    raw = run(["gh-axi", "api", f"/repos/{match[1]}/pulls/{match[2]}", "--jq",
               '{merged: .merged, head: .head.sha, merge: .merge_commit_sha}'], project)
    # gh-axi serializes API objects as TOON, including caller-shaped objects.
    # This projection has only three scalar fields, so reject anything outside
    # that exact flat shape instead of interpreting general presentation text.
    lines = raw.splitlines()
    if len(lines) != 3 or any(": " not in line for line in lines):
        raise Refusal("unexpected merged-PR response shape")
    data = dict(line.split(": ", 1) for line in lines)
    data = {key: json.loads(value) if value.startswith('"') else value for key, value in data.items()}
    if set(data) != {"merged", "head", "merge"}:
        raise Refusal("unexpected merged-PR response fields")
    if data["merged"] != "true":
        raise Refusal("recorded PR is not MERGED; landing unproven")
    proof = {"pr_url": url, "merged_pr_head_sha": data.get("head"), "merge_commit_sha": data.get("merge")}
    for sha in (proof["merged_pr_head_sha"], proof["merge_commit_sha"]):
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise Refusal("merged PR lacks valid immutable SHAs")
        try:
            run(["git", "cat-file", "-e", sha + "^{commit}"], project)
        except Refusal:
            if not fetch:
                raise Refusal("merged PR commit is not present locally; report mode will not fetch") from None
            run(["git", "fetch", "--quiet", "--no-tags", "origin", sha], project)
            run(["git", "cat-file", "-e", sha + "^{commit}"], project)
    return proof


def stores(project, state_dir):
    common = Path(run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], project)).resolve()
    default = Path(f"/tmp/vernant-codex-hooks-{os.getuid()}")
    durable = Path(os.environ.get("WORKTREE_LIFECYCLE_STORE_DIR", common / "vernant-worktree-lifecycle"))
    if "WORKTREE_LIFECYCLE_STORE_DIR" not in os.environ and state_dir.resolve() != default.resolve():
        durable = state_dir / "worktree-lifecycle"
    return common, durable, state_dir / "worktree-lifecycle"


def retire(args, slot, owner, branch, paths, proof):
    script = args.project / "scripts/git-stability/retire_slot_manifest.py"
    if not script.is_file():
        print(f"missing entry point: {script}; lifecycle records unchanged")
        return
    python = args.project / ".venv/bin/python"
    interpreter = str(python) if python.is_file() else sys.executable
    with tempfile.TemporaryDirectory(prefix="fm-slot-proof-") as temp:
        proof_file = Path(temp) / "proof.json"
        proof_file.write_text(json.dumps(proof) + "\n")
        result = subprocess.run([interpreter, str(script), "retire", "--slot-path", str(slot),
                                 "--repo-root", str(args.project), "--owner-id", owner,
                                 "--owner-branch", branch, "--proof-file", str(proof_file),
                                 "--state-dir", str(args.state_dir)], cwd=args.project, text=True,
                                capture_output=True, check=False)
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="")
        if result.returncode:
            raise Refusal(f"Vernant retirement exited {result.returncode}; branch preserved; resolve reason/next_step above")
        report = json.loads(result.stdout)
        if report.get("status") not in ("retired", "already_retired"):
            raise Refusal("entry point did not attest retirement")
        if any(os.path.lexists(path) for path in paths):
            raise Refusal("entry point returned success but an active record remains")


def retire_slot(args):
    slot = args.slot.resolve()
    existing = []
    try:
        _, durable, legacy = stores(args.project, args.state_dir)
        name = hashlib.sha256(str(slot).encode()).hexdigest()[:16] + ".json"
        paths = {durable / name, legacy / name}
        existing = sorted(str(path) for path in paths if os.path.lexists(path))
        if not existing:
            return 0
        script = args.project / "scripts/git-stability/retire_slot_manifest.py"
        if not script.is_file():
            print(f"missing entry point: {script}; lifecycle records unchanged")
            return 0
        if args.keep:
            raise Refusal(args.keep)
        proof = landing_proof(args.project, args.firstmate_state, args.owner_id, fetch=True)
    except (Refusal, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"lifecycle record {' and '.join(existing) or 'of ' + str(slot)} stayed: {exc}")
        return 0
    retire(args, slot, args.owner_id, args.owner_branch, paths, proof)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--firstmate-state", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, default=Path(os.environ.get("CODEX_HOOK_STATE_DIR", f"/tmp/vernant-codex-hooks-{os.getuid()}")))
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--slot", type=Path)
    parser.add_argument("--owner-id")
    parser.add_argument("--owner-branch")
    parser.add_argument("--keep")
    args = parser.parse_args()
    args.project = args.project.resolve()
    if args.slot and not (args.owner_id and args.owner_branch and args.apply):
        parser.error("--slot requires --owner-id, --owner-branch and --apply")
    if args.keep and not args.slot:
        parser.error("--keep requires --slot")
    try:
        if args.slot:
            return retire_slot(args)
        common, durable, legacy = stores(args.project, args.state_dir)
        names = sorted({p.name for directory in {durable, legacy} for p in directory.glob("*.json")})
        failed = False
        for name in names:
            paths = {durable / name, legacy / name}
            source = durable / name if (durable / name).exists() else legacy / name
            record = {}
            try:
                record = json.loads(source.read_text())
                # The legacy directory is shared across repositories. Never
                # attribute another repository's declarations to this one.
                if source.parent != durable and Path(record["repo_root"]).resolve() != common.parent:
                    continue
                owner, branch, slot = record["owner_id"], record["branch"], Path(record["worktree_path"])
                if os.path.lexists(owner_meta(args.firstmate_state, owner)):
                    print(f"{name} owner={owner} slot={slot} landing=LIVE: {owner}.meta is a live Firstmate task record; both copies kept")
                    continue
                proof = landing_proof(args.project, args.firstmate_state, owner, fetch=args.apply)
                outside = run(["git", "-C", str(slot), "rev-list", "--count", "HEAD", "--not", "refs/remotes/origin/main"], args.project)
                if outside != "0":
                    print(f"{name} owner={owner} slot={slot} landing=UNLANDED: slot HEAD has {outside} commit(s) outside origin/main; both copies kept")
                    continue
                print(f"{name} owner={owner} slot={slot} landing=MERGED recorded_pr={proof['pr_url']}")
                if args.apply:
                    retire(args, slot, owner, branch, paths, proof)
            except (Refusal, OSError, ValueError, KeyError, TypeError) as exc:
                print(f"{name} owner={record.get('owner_id', 'unknown') if isinstance(record, dict) else 'unknown'} landing=UNPROVEN: {exc}")
                failed = failed or args.apply
        return 1 if failed else 0
    except (Refusal, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"REFUSED: {exc}; next_step: verify Firstmate landing record and Vernant retirement output", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
