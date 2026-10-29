"""Live drive: real profile builder + real sandbox-exec + real git, disposable repo."""
import os, subprocess, sys, tempfile, shutil
from pathlib import Path

builder = sys.argv[1]       # path to fm-write-confinement.py to test
label = sys.argv[2]
root = Path(tempfile.mkdtemp(prefix="fmlive-")).resolve()
env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
           GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
def sh(*a, cwd=None, e=None, check=True):
    r = subprocess.run(list(a), cwd=cwd, env=e or env, capture_output=True, text=True)
    if check and r.returncode: raise SystemExit(f"setup failed {a}: {r.stderr}")
    return r
home = root / "fmhome"
for d in ("config", "projects", "data/task", "state"): (home / d).mkdir(parents=True)
(home / "state/task.meta").write_text("x\n"); (home / "state/other.meta").write_text("x\n")
origin = root / "origin.git"; sh("git", "init", "-q", "--bare", "-b", "main", str(origin))
primary = home / "projects/proj"; sh("git", "init", "-q", "-b", "main", str(primary))
(primary / "f").write_text("1\n"); sh("git", "-C", str(primary), "add", "f"); sh("git", "-C", str(primary), "commit", "-qm", "c1")
real = sh("git", "-C", str(primary), "rev-parse", "HEAD").stdout.strip()
(primary / "f").write_text("2\n"); sh("git", "-C", str(primary), "commit", "-qam", "c2")
forged = sh("git", "-C", str(primary), "rev-parse", "HEAD").stdout.strip()
sh("git", "-C", str(primary), "reset", "-q", "--hard", real)
sh("git", "-C", str(primary), "branch", "fm/other", real)
sh("git", "-C", str(primary), "branch", "doomed", real)
sh("git", "-C", str(primary), "remote", "add", "origin", str(origin))
sh("git", "-C", str(primary), "push", "-q", "origin", "main", "doomed")
sh("git", "-C", str(primary), "fetch", "-q", "origin")
wt = home / "worktrees/task"; wt.parent.mkdir()
sh("git", "-C", str(primary), "worktree", "add", "-q", "-b", "fm/task", str(wt), real)
sh("git", "-C", str(primary), "pack-refs", "--all")
sh("git", "-C", str(primary), "config", "fetch.prune", "true")   # host-like prune setting
# origin deletes 'doomed' so a pruning fetch would need a packed-refs rewrite
sh("git", "--git-dir", str(origin), "update-ref", "-d", "refs/heads/doomed")
common = primary / ".git"
print(f"[{label}] packed-refs has fm/other:", "refs/heads/fm/other" in (common/"packed-refs").read_text(),
      "| loose fm/other file:", (common/"refs/heads/fm/other").exists())
profile = root / "profile.sb"
b = sh(sys.executable, builder, "--worktree", str(wt), "--home", str(home), "--config", str(home/"config"),
       "--projects", str(home/"projects"), "--data", str(home/"data/task"), "--state", str(home/"state"),
       "--task", "task", "--branch", "fm/task", "--harness", "omp", "--profile", str(profile), check=False)
print(f"[{label}] builder rc={b.returncode} {b.stderr.strip()}")
# The confined launch env, as fm-spawn.sh sets it (fetch.prune=false via GIT_CONFIG_*)
cenv = dict(env, GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="fetch.prune", GIT_CONFIG_VALUE_0="false", TMPDIR=str(root/"wtmp"))
(root/"wtmp").mkdir()
def confined(script, e=None):
    r = subprocess.run(["sandbox-exec", "-f", str(profile), "/bin/sh", "-c", script], cwd=str(wt), env=e or cenv, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()
def primary_sees():
    return sh("git", "-C", str(primary), "rev-parse", "fm/other", check=False).stdout.strip()
def verdict(name):
    s = primary_sees()
    print(f"[{label}] {name}: primary rev-parse fm/other = {s[:12]} -> {'FORGED' if s == forged else 'REAL' if s == real else 'OTHER'}")
    return s
P = common / "packed-refs"; orig = P.read_bytes()
# 1. The exact intent attack: forged line written into packed-refs in place
rc, out = confined(f"sed 's/{real} refs\\/heads\\/fm\\/other/{forged} refs\\/heads\\/fm\\/other/' '{P}' > \"$TMPDIR/p\" && cat \"$TMPDIR/p\" > '{P}'")
print(f"[{label}] 1 in-place write rc={rc} {out}"); verdict("1 in-place write"); P.write_bytes(orig)
# 2. Rename a forged file over packed-refs
rc, out = confined(f"sed 's/{real} refs\\/heads\\/fm\\/other/{forged} refs\\/heads\\/fm\\/other/' '{P}' > '{common}/forged.tmp' && mv '{common}/forged.tmp' '{P}'")
print(f"[{label}] 2 rename-over rc={rc} {out}"); verdict("2 rename-over"); P.write_bytes(orig); (common/"forged.tmp").unlink(missing_ok=True)
# 3. Git command rewriting packed-refs: update-ref on packed remote-tracking delete; pack-refs
rc, out = confined("git update-ref -d refs/remotes/origin/main")
print(f"[{label}] 3a update-ref -d packed remote ref rc={rc} {out}")
print(f"[{label}]    origin/main still resolves:", sh("git","-C",str(primary),"rev-parse","-q","--verify","refs/remotes/origin/main",check=False).returncode == 0)
P.write_bytes(orig)
# 4. commondir attack
fake = root / "fakecommon"; (fake/"refs/heads/fm").mkdir(parents=True); (fake/"refs/heads/fm/other").write_text(forged+"\n")
(fake/"HEAD").write_text("ref: refs/heads/main\n"); (fake/"objects").symlink_to(common/"objects"); (fake/"config").write_text((common/"config").read_text())
rc, out = confined(f"printf '%s\\n' '{fake}' > '{common}/commondir'")
print(f"[{label}] 4 commondir write rc={rc} {out}"); verdict("4 commondir"); (common/"commondir").unlink(missing_ok=True)
# 5. default reftable switch with forged reftable/
ft = root / "ftrepo"; sh("git", "init", "-q", "--ref-format=reftable", "-b", "main", str(ft))
sh("git", "-C", str(ft), "config", "core.repositoryformatversion", "1")
shutil.rmtree(ft/".git/objects"); (ft/".git/objects").symlink_to(common/"objects")
sh("git", "-C", str(ft), "update-ref", "refs/heads/main", real); sh("git", "-C", str(ft), "update-ref", "refs/heads/fm/other", forged)
cfg = (common/"config").read_bytes()
rc, out = confined(f"git config core.repositoryformatversion 1 && git config extensions.refStorage reftable && cp -R '{ft}/.git/reftable' '{common}/reftable'")
print(f"[{label}] 5 reftable switch rc={rc} {out}"); verdict("5 reftable switch")
(common/"config").write_bytes(cfg); shutil.rmtree(common/"reftable", ignore_errors=True)
# 6. Confined fetch with host fetch.prune=true and fm-spawn's injected fetch.prune=false
rc, out = confined("git fetch origin")
print(f"[{label}] 6 confined fetch (with fm-spawn env) rc={rc} {out}")
rc, out = confined("git fetch origin", e=dict(env, TMPDIR=str(root/"wtmp")))
print(f"[{label}] 6b confined fetch WITHOUT fm-spawn env rc={rc} {out}")
# 7. Normal worker work still runs: commit on own branch, push it, own branch reads correct
rc, out = confined("echo w > g && git add g && git commit -qm worker && git push -q origin fm/task && git rev-parse --abbrev-ref HEAD")
print(f"[{label}] 7 own commit+push rc={rc} {out}")
# 8. Loose write to another branch still refused (pre-existing guard intact)
rc, out = confined(f"git update-ref refs/heads/fm/other {forged}")
print(f"[{label}] 8 update-ref other branch rc={rc} {out}"); verdict("8 loose other branch")
# 9. Open documented route: refStorage payload (expected still open, informational)
pay = root / "payload"; (pay/"refs/heads/fm").mkdir(parents=True); (pay/"refs/heads/fm/other").write_text(forged+"\n"); (pay/"HEAD").write_text("ref: refs/heads/main\n")
(pay/"refs/heads/main").write_text(real+"\n")
rc, out = confined(f"git config core.repositoryformatversion 1 && git config extensions.refStorage 'files://{pay}'")
print(f"[{label}] 9 payload refStorage (documented open) rc={rc} {out}"); verdict("9 payload refStorage")
(common/"config").write_bytes(cfg)
print(f"[{label}] packed-refs unchanged at end:", P.read_bytes() == orig)
shutil.rmtree(root)
