#!/usr/bin/env python3
"""Lab stand-in for Vernant's scripts/git-stability/closeout_pr.py.
Contract used by the sweep: --cleanup-worktree <copy> [--execute-cleanup].
Plan mode prints a JSON verdict. Execute mode unlocks and plainly removes the copy.
It re-checks landing (HEAD merged into origin/main), as the real driver does.
Per-copy overrides come from $LAB_CTL/<basename>.plan and .exec files."""
import argparse, json, os, subprocess, sys, time
GIT = os.environ.get("LAB_REAL_GIT", "/usr/bin/git")
ctl = os.environ["LAB_CTL"]
ap = argparse.ArgumentParser()
ap.add_argument("--cleanup-worktree", required=True)
ap.add_argument("--execute-cleanup", action="store_true")
a = ap.parse_args()
copy = a.cleanup_worktree
name = os.path.basename(copy)
with open(os.path.join(ctl, "driver.log"), "a") as f:
    f.write(f"pid={os.getpid()} cwd={os.getcwd()} mode={'EXECUTE' if a.execute_cleanup else 'PLAN'} copy={copy}\n")
def override(kind):
    p = os.path.join(ctl, f"{name}.{kind}")
    return open(p).read() if os.path.exists(p) else None
def git(*args):
    return subprocess.run([GIT, "-C", copy, *args], capture_output=True, text=True)
if not a.execute_cleanup:
    o = override("plan")
    if o is not None:
        if o.startswith("HANG"):
            subprocess.Popen(["sleep", "300"])      # grandchild that must not outlive the sweep
            time.sleep(300)
        sys.stdout.write(o.split("\n@@EXIT=")[0])
        sys.exit(int(o.split("@@EXIT=")[1]) if "@@EXIT=" in o else 0)
    landed = git("merge-base", "--is-ancestor", "HEAD", "origin/main").returncode == 0
    if landed:
        print(json.dumps({"allowed": True, "reason": "landed_on_origin_main"}))
        sys.exit(0)
    print(json.dumps({"allowed": False, "reason": "pull_request_not_merged: HEAD is on a remote branch but not in origin/main"}))
    sys.exit(3)
o = override("exec")
if o is not None:
    sys.stderr.write(o)
    sys.exit(3)
if git("merge-base", "--is-ancestor", "HEAD", "origin/main").returncode != 0:
    print("refused: not landed"); sys.exit(3)
for step in (["worktree", "unlock", copy], ["worktree", "remove", copy]):
    r = subprocess.run([GIT, "-C", os.getcwd(), *step], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr); sys.exit(4)
print(json.dumps({"cleaned": True, "copy": copy}))
