#!/usr/bin/env python3
"""Independent live probe: shared Git program-file denies, head vs base builder.

Usage: live_probe.py REPO BASE_BUILDER OUTDIR
Builds a disposable Firstmate home, project, task worktree and user home under
a fresh temp folder, builds a seatbelt profile with the head builder
(REPO/bin/fm-write-confinement.py) and with BASE_BUILDER, then for each
profile runs /usr/bin/sandbox-exec children that (1) ask the kernel
sandbox_check for write denies, (2) try a real write, (3) do ordinary Git
work, and (4) try to plant an fsmonitor program that an unconfined
`git status` would run. Prints JSON results.
"""
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

REPO, BASE_BUILDER, OUT = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
ROOT = Path(tempfile.mkdtemp(prefix="nmlive-", dir="/private/tmp")).resolve()
UHOME = ROOT / "uhome"
HOME = ROOT / "fmhome"
NM = ROOT / "nm"
PROJ = HOME / "projects/proj"
WT = PROJ / ".claude/worktrees/fm-task"
REMOTE = ROOT / "remote.git"
HOOKS_ABS = ROOT / "abs-hooks"
TASK_HOOKS = HOME / "state/task.git-hooks"
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(UHOME), "NM_HOME": str(NM), "LC_ALL": "C",
       "TMPDIR": "/private/tmp"}


def sh(*cmd, env=None, check=True, cwd=None):
    r = subprocess.run(list(map(str, cmd)), env=env or ENV, capture_output=True, text=True, cwd=cwd)
    if check and r.returncode:
        raise SystemExit(f"setup failed: {cmd}: {r.stderr}")
    return r


def git(*args, **kw):
    return sh("git", *args, **kw)


def setup():
    for d in (UHOME / ".config/git", HOME / "config", HOME / "data/task", HOME / "state", NM / "repos", TASK_HOOKS, HOOKS_ABS):
        d.mkdir(parents=True, exist_ok=True)
    (UHOME / ".gitconfig").write_text("[user]\n\tname = Live Probe\n\temail = probe@example.invalid\n")
    (UHOME / ".config/git/config").write_text("# xdg user config\n")
    git("init", "-q", "--bare", "-b", "main", REMOTE)
    git("init", "-q", "-b", "main", PROJ)
    (PROJ / "README").write_text("x\n")
    git("-C", PROJ, "add", "README")
    git("-C", PROJ, "commit", "-q", "-m", "init")
    git("-C", PROJ, "remote", "add", "origin", REMOTE)
    git("-C", PROJ, "push", "-q", "origin", "main")
    git("-C", PROJ, "worktree", "add", "-q", "-b", "fm/task", WT)
    common = PROJ / ".git"
    # Program files the measuring names: an include, an absolute hooksPath
    # folder in an included file, a hook, a submodule git dir, remotes and
    # branches files, the shared config.worktree, the worktree's config.worktree.
    (ROOT / "inc.cfg").write_text(f"[core]\n\thooksPath = {HOOKS_ABS}\n")
    git("-C", PROJ, "config", "include.path", ROOT / "inc.cfg")
    (HOOKS_ABS / "pre-commit").write_text("#!/bin/sh\nexit 0\n")
    (common / "hooks/post-checkout").write_text("#!/bin/sh\nexit 0\n")
    (common / "modules/sub").mkdir(parents=True)
    (common / "modules/sub/config").write_text("[core]\n")
    (common / "remotes").mkdir(exist_ok=True)
    (common / "remotes/old").write_text("URL: " + str(REMOTE) + "\n")
    (common / "branches").mkdir(exist_ok=True)
    (common / "branches/old").write_text(str(REMOTE) + "\n")
    (common / "config.worktree").write_text("# shared config.worktree\n")
    gitdir = Path(git("-C", WT, "rev-parse", "--absolute-git-dir").stdout.strip())
    git("-C", PROJ, "config", "extensions.worktreeConfig", "true")
    (gitdir / "config.worktree").write_text("# own config.worktree\n[live]\n\twt = own\n")
    (HOME / "state/task.meta").write_text(f"window=fmtest:fm-task\nworktree={WT}\nproject=fmtest\n")
    (HOME / "state/task.status").write_text("")
    (TASK_HOOKS / "pre-commit").write_text(f"#!/bin/sh\necho ran > {ROOT}/task-hook-ran\n")
    (TASK_HOOKS / "pre-commit").chmod(0o755)
    (ROOT / "fsmon.sh").write_text(f"#!/bin/sh\necho ran >> {ROOT}/FSMONITOR-RAN\nexit 1\n")
    (ROOT / "fsmon.sh").chmod(0o755)
    return common, gitdir


def build(builder, profile):
    r = sh(sys.executable, builder, "--worktree", WT, "--home", HOME, "--config", HOME / "config",
           "--projects", HOME / "projects", "--data", HOME / "data/task", "--state", HOME / "state",
           "--task", "task", "--branch", "fm/task", "--harness", "claude", "--claude-session", "11111111-2222-4333-8444-555555555555", "--profile", profile, check=False)
    return {"exit": r.returncode, "stderr": r.stderr.strip()[-400:]}


CHILD = r'''
import ctypes, json, os, sys
lib = ctypes.CDLL("/usr/lib/libSystem.dylib")
lib.sandbox_check.restype = ctypes.c_int
lib.sandbox_check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]  # variadic: fixed args only
out = {}
for path in json.loads(sys.argv[1]):
    row = {op: lib.sandbox_check(os.getpid(), op.encode(), 1, ctypes.c_char_p(path.encode()))
           for op in ("file-write-data", "file-write-create", "file-write-unlink")}
    before = open(path, "rb").read() if os.path.exists(path) else None
    try:
        with open(path, "a") as s:
            s.write("\n# live probe write\n")
        row["write"] = "succeeded"
    except PermissionError as e:
        row["write"] = "refused: " + e.strerror
    after = open(path, "rb").read() if os.path.exists(path) else None
    if row["write"] == "succeeded" and before is not None:
        with open(path, "wb") as s:
            s.write(before)  # put the file back for the next case
    out[path] = row
print(json.dumps(out))
'''


def launch_env():
    return dict(ENV, GIT_CONFIG_COUNT="3",
                GIT_CONFIG_KEY_0="core.hooksPath", GIT_CONFIG_VALUE_0=str(TASK_HOOKS),
                GIT_CONFIG_KEY_1="fetch.prune", GIT_CONFIG_VALUE_1="false",
                GIT_CONFIG_KEY_2="branch.autoSetupMerge", GIT_CONFIG_VALUE_2="false")


def confined(profile, *cmd, env=None):
    prefix = ["/usr/bin/sandbox-exec", "-f", str(profile)] if profile else []
    return subprocess.run(prefix + list(map(str, cmd)), env=env or launch_env(), capture_output=True, text=True, cwd=WT)


def checks(profile, targets):
    r = confined(profile, sys.executable, "-c", CHILD, json.dumps([str(t) for t in targets]))
    if r.returncode:
        return {"error": r.stderr[-600:]}
    return json.loads(r.stdout)


def ordinary(profile):
    rows = []
    def run(label, *args):
        r = confined(profile, "git", "-C", WT, *args)
        rows.append({"command": "git " + " ".join(map(str, args)), "label": label, "exit": r.returncode,
                     "stderr": r.stderr.strip().splitlines()[-2:]})
    (WT / "live-file").write_text(f"live {profile.name}\n")
    (ROOT / "task-hook-ran").unlink(missing_ok=True)
    run("status", "status", "--porcelain")
    run("add", "add", "live-file")
    run("commit (task hook via GIT_CONFIG_COUNT core.hooksPath)", "commit", "-q", "-m", "live ordinary")
    rows[-1]["task_hook_ran"] = (ROOT / "task-hook-ran").exists()
    tip = git("-C", WT, "rev-parse", "HEAD").stdout.strip()
    run("checkout --detach", "checkout", "-q", "--detach")
    run("branch -D own branch", "branch", "-D", "fm/task")
    run("checkout -b own branch", "checkout", "-q", "-b", "fm/task")
    run("branch --list", "branch", "--list")
    clone = ROOT / f"pusher-{profile.name}"
    git("clone", "-q", REMOTE, clone)
    (clone / "pushed").write_text(profile.name)
    git("-C", clone, "add", "pushed"); git("-C", clone, "commit", "-q", "-m", "pushed " + profile.name); git("-C", clone, "push", "-q", "origin", "main")
    new_tip = git("-C", clone, "rev-parse", "HEAD").stdout.strip()
    run("fetch origin (remote has a new commit)", "fetch", "-q", "origin")
    rows[-1]["origin_main_is_new_tip"] = git("-C", WT, "rev-parse", "origin/main").stdout.strip() == new_tip
    run("checkout -B own branch from remote-tracking ref (launch autoSetupMerge=false)", "checkout", "-q", "-B", "fm/task", "origin/main")
    rows[-1]["upstream_recorded"] = git("-C", WT, "config", "--get", "branch.fm/task.remote", check=False).stdout.strip()
    run("checkout -B own branch from remote-tracking ref (Git default autoSetupMerge=true)", "-c", "branch.autoSetupMerge=true", "checkout", "-q", "-B", "fm/task", "origin/main")
    rows[-1]["upstream_recorded"] = git("-C", WT, "config", "--get", "branch.fm/task.remote", check=False).stdout.strip()
    git("-C", PROJ, "config", "--unset", "branch.fm/task.remote", check=False)
    git("-C", PROJ, "config", "--unset", "branch.fm/task.merge", check=False)
    git("-C", PROJ, "config", "--remove-section", "branch.fm/task", check=False)
    run("checkout -B own branch back to tip", "checkout", "-q", "-B", "fm/task", tip)
    run("config --local read", "config", "--local", "--get", "remote.origin.url")
    run("config --worktree read (own config.worktree key, extensions.worktreeConfig=true)", "config", "--worktree", "--get", "live.wt")
    rows[-1]["value"] = confined(profile, "git", "-C", WT, "config", "--worktree", "--get", "live.wt").stdout.strip()
    run("log", "log", "-1", "--format=%s")
    run("diff", "diff", "HEAD~1", "--stat")
    run("stash list", "stash", "list")
    # Writes whose whole purpose is a shared config write: printed, expected refused at head.
    run("config --local write (shared config write)", "config", "--local", "live.probe", "1")
    git("-C", PROJ, "config", "--unset", "live.probe", check=False)
    return rows


def harm(profile):
    """A confined worker plants core.fsmonitor; then an unconfined supervisor git status runs."""
    marker = ROOT / "FSMONITOR-RAN"
    marker.unlink(missing_ok=True)
    plant = confined(profile, "git", "-C", WT, "config", "--local", "core.fsmonitor", ROOT / "fsmon.sh")
    hook = confined(profile, "/bin/sh", "-c", f"printf '#!/bin/sh\\necho hook >> {ROOT}/HOOK-RAN\\n' > {PROJ}/.git/hooks/post-index-change && chmod +x {PROJ}/.git/hooks/post-index-change")
    sup = subprocess.run(["git", "-C", str(WT), "status", "--porcelain"], env=ENV, capture_output=True, text=True)
    sup2 = subprocess.run(["git", "-C", str(PROJ), "status", "--porcelain"], env=ENV, capture_output=True, text=True)
    res = {"plant_fsmonitor_exit": plant.returncode, "plant_stderr": plant.stderr.strip()[-200:],
           "plant_hook_exit": hook.returncode, "plant_hook_stderr": hook.stderr.strip()[-200:],
           "supervisor_status_exit": sup.returncode, "fsmonitor_program_ran": marker.exists(),
           "primary_status_exit": sup2.returncode}
    # clean up for next profile
    git("-C", PROJ, "config", "--unset", "core.fsmonitor", check=False)
    (PROJ / ".git/hooks/post-index-change").unlink(missing_ok=True)
    marker.unlink(missing_ok=True)
    return res


def main():
    common, gitdir = setup()
    targets = {
        "shared config": common / "config",
        "shared config.worktree": common / "config.worktree",
        "shared hooks/post-checkout (existing)": common / "hooks/post-checkout",
        "shared hooks/pre-push (new)": common / "hooks/pre-push",
        "shared modules/sub/config": common / "modules/sub/config",
        "shared remotes/old": common / "remotes/old",
        "shared branches/old": common / "branches/old",
        "own worktree config.worktree": gitdir / "config.worktree",
        "file the shared config includes": ROOT / "inc.cfg",
        "absolute core.hooksPath folder file": HOOKS_ABS / "pre-commit",
        "user ~/.gitconfig": UHOME / ".gitconfig",
        "user ~/.config/git/config": UHOME / ".config/git/config",
        "control-protected packed-refs": common / "packed-refs",
        "control-protected HEAD": common / "HEAD",
        "control-allowed worktree file": WT / "README",
        "control-allowed own branch ref": common / "refs/heads/fm/task",
        "control-allowed shared objects folder file": common / "objects/live-probe-new",
    }
    (common / "packed-refs").write_text("# pack-refs with: peeled fully-peeled sorted \n") if not (common / "packed-refs").exists() else None
    results = {"root": str(ROOT), "git": sh("git", "--version").stdout.strip(),
               "system_config": sh("git", "var", "GIT_CONFIG_SYSTEM").stdout.strip()}
    head_p, base_p = OUT / "head.sb", OUT / "base.sb"
    results["build_head"] = build(REPO / "bin/fm-write-confinement.py", head_p)
    results["build_base"] = build(BASE_BUILDER, base_p)
    paths = [str(t) for t in targets.values()]
    for name, prof in (("unconfined", None), ("base", base_p), ("head", head_p)):
        got = checks(prof, paths) if prof is None or prof.exists() else {"error": "no profile"}
        results[f"policy_{name}"] = {label: got.get(str(p), got.get("error")) for label, p in targets.items()} if "error" not in got else got
        (common / "objects/live-probe-new").unlink(missing_ok=True)
        (common / "hooks/pre-push").unlink(missing_ok=True)
    for name, prof in (("unconfined", None), ("base", base_p), ("head", head_p)):
        results[f"harm_{name}"] = harm(prof)
    results["ordinary_base"] = ordinary(base_p)
    results["ordinary_head"] = ordinary(head_p)
    results["shared_config_after"] = (common / "config").read_text()
    print(json.dumps(results, indent=1))
    shutil.rmtree(ROOT)


main()
