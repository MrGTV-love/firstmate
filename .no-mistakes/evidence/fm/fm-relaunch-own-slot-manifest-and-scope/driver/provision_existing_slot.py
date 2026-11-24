# Lab stand-in for a Vernant-style create-only slot provisioner (stdlib only).
# Fresh-admission rules: create-only manifest, scope tracked at the base, every
# changed path inside the scope. Each real run is appended to the sentinel.
import argparse, hashlib, json, os, subprocess, sys
from pathlib import Path
SENTINEL = "__SENTINEL__"
p = argparse.ArgumentParser()
for flag in ("repo-root", "worktree-path", "owner-id", "branch", "base-sha"):
    p.add_argument("--" + flag, required=True)
p.add_argument("--owned-path", action="append", required=True)
p.add_argument("--base-source")
p.add_argument("--check-manifest-only", action="store_true")
a = p.parse_args()
def git(*args):
    return subprocess.run(["git", "-C", a.worktree_path, *args], capture_output=True, text=True, check=True).stdout
common = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir").strip()).resolve()
copy = os.path.realpath(a.worktree_path)
manifest = common / "vernant-worktree-lifecycle" / (hashlib.sha256(copy.encode()).hexdigest()[:16] + ".json")
def blocked(reason, **extra):
    print(json.dumps(dict(state="BLOCKED", reason=reason, blocked_reasons=[reason], manifest_path=str(manifest), **extra)))
    raise SystemExit(2)
if a.check_manifest_only:
    if manifest.exists():
        blocked("manifest_exists")
    print(json.dumps({"state": "PASS"}))
    raise SystemExit(0)
with open(SENTINEL, "a", encoding="utf-8") as s:
    s.write(json.dumps(sys.argv[1:]) + "\n")
if manifest.exists():
    blocked("manifest_exists")
for path in a.owned_path:
    if not git("ls-tree", "-r", "--name-only", a.base_sha, "--", path.rstrip("/")).strip():
        blocked("scope_not_tracked", path=path)
changed = set(filter(None, git("diff", "--name-only", a.base_sha, "HEAD").splitlines()))
def inside(path):
    return any(path == s.rstrip("/") or path.startswith(s.rstrip("/") + "/") for s in a.owned_path)
outside = sorted(x for x in changed if not inside(x))
if outside:
    blocked("scope_mismatch", outside=outside)
record = dict(worktree_path=copy, owner_id=a.owner_id, branch=a.branch, base_sha=a.base_sha,
              owned_paths=a.owned_path, lifecycle_state="worktree_active", repo_root=os.path.realpath(a.repo_root))
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps(record, sort_keys=True), encoding="utf-8")
print(json.dumps(dict(state="PASS", manifest_path=str(manifest), **record)))
