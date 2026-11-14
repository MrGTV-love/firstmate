"""PROFILE-COVERS: the profile bin/fm-write-confinement.py builds for a task with a
recorded successor branch permits exactly the task's branch, the recorded
successor and the task's archive names under refs/heads, and nothing more.

Usage: fm-write-confinement-successor.py REPO BASE (unit|kernel)

unit:   builds profiles with the production generator over a scratch repository
        under BASE and checks the profile text. It runs anywhere.
kernel: builds the profile for the Scott task fixture (REPO/tests/fixtures/
        fm-scott-task-shape.sh, or FM_SCOTT_FIXTURE_MAKER) and runs real git
        commands under /usr/bin/sandbox-exec with the new and the old profile.
        A process that is already sandboxed cannot apply a second profile
        (sandbox_apply: Operation not permitted, exit 71); there the mode prints
        SKIPPED-UNVERIFIED with that exact reason and exits 0, and with
        FM_REQUIRE_KERNEL_PROOF=1 (the macOS CI step) it fails instead. Off macOS
        it reports SKIPPED-UNVERIFIED too. Neither case is ever a pass.
Nothing here touches this home's .git.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

# What the confinement's refusal looks like in git's output; any other failure is not a refusal.
CONFINEMENT_REFUSAL = re.compile(r"(Operation not permitted|Permission denied)")
GIT_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Fixture",
           "GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_NAME": "Fixture",
           "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
SESSION = "11111111-2222-4333-8444-555555555555"
TASK = "task"
BRANCH = "fm/task"
SUCCESSOR = "fm/task-v2"


def git(*args, cwd=None, check=True):
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, env=dict(os.environ, **GIT_ENV))
    if check and result.returncode:
        raise AssertionError(f"git {args}: {result.stderr}")
    return result


def layout(base):
    """One scratch home, project and three work trees: the task, another task, a successor holder."""
    base.mkdir(parents=True)
    base = base.resolve()
    home = base / "home"
    project = home / "projects/project"
    for name in ("state", "data/task", "config"):
        (home / name).mkdir(parents=True)
    (home / "README").write_text("home\n")
    project.mkdir(parents=True)
    git("init", "-q", "-b", "main", str(project))
    (project / "README").write_text("project\n")
    git("-C", str(project), "add", "README")
    git("-C", str(project), "commit", "-q", "-m", "init")
    worktree = project / ".claude/worktrees/fm-task"
    other = project / ".claude/worktrees/fm-other"
    git("-C", str(project), "worktree", "add", "-q", "-b", BRANCH, str(worktree))
    git("-C", str(project), "worktree", "add", "-q", "-b", "fm/other", str(other))
    (other / "other.txt").write_text("other task work\n")
    git("-C", str(other), "add", "other.txt")
    git("-C", str(other), "commit", "-q", "-m", "other work")
    (home / "state/task.meta").write_text(f"window=fmtest:fm-task\nworktree={worktree}\nproject={project}\nbranch={BRANCH}\n")
    (home / "state/other.meta").write_text(f"window=fmtest:fm-other\nworktree={other}\nproject={project}\nbranch=fm/other\n")
    return {"base": base, "home": home, "project": project, "worktree": worktree, "other": other,
            "sha": git("-C", str(project), "rev-parse", "HEAD").stdout.strip(), "nm": base / "nm",
            "other_sha": git("-C", str(project), "rev-parse", "refs/heads/fm/other").stdout.strip()}


def build(manifest, name, *, successor=None, branch=BRANCH):
    """Run the production generator; returns its profile text."""
    home = manifest["home"]
    profile = manifest["base"] / name
    command = [sys.executable, str(REPO / "bin/fm-write-confinement.py"), "--worktree", str(manifest["worktree"]),
               "--home", str(home), "--config", str(home / "config"), "--projects", str(home / "projects"),
               "--data", str(home / "data/task"), "--state", str(home / "state"), "--task", TASK,
               "--harness", "claude", "--claude-session", SESSION, "--profile", str(profile)]
    if branch:
        command += ["--branch", branch]
    if successor:
        command += ["--successor-branch", successor]
    result = subprocess.run(command, capture_output=True, text=True,
                            env=dict(os.environ, NM_HOME=str(manifest["nm"]), CLAUDE_CONFIG_DIR=str(manifest["base"] / "claude")))
    assert result.returncode == 0, f"generator refused {command[-4:]}: {result.stderr.strip()}"
    return profile.read_text()


def refused_build(manifest, name, **kwargs):
    try:
        build(manifest, name, **kwargs)
    except AssertionError as error:
        return str(error)
    return None


def common_dir(manifest):
    return Path(git("-C", str(manifest["project"]), "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()).resolve()


def ref_allows(profile, common):
    """Classify every allow line under refs/heads or logs/refs/heads.

    Returns (literal lines, archive regex count, archive folder create count);
    any other allow line that names those folders fails the case.
    """
    literals, regexes, creates = [], 0, 0
    archive = re.compile(r'^\(allow file-write\* \(regex #"\^[^"]*/(logs/)?refs/heads/archive/' + TASK
                         + r'-\(submitted\|pipeline\)-(\[0-9a-f\]){8}\(\\\.lock\)\?\$"\)\)$')
    folder = re.compile(r'^\(allow file-write-create \(require-all \(literal "[^"]*/(logs/)?refs/heads/archive"\) \(vnode-type DIRECTORY\)\)\)$')
    for line in profile.splitlines():
        if not line.startswith("(allow") or not re.search(r"(refs/heads|refs\\/heads)", line):
            continue
        if line.startswith("(allow file-write* (literal ") and "regex" not in line and "subpath" not in line:
            literals.append(line)
        elif archive.match(line):
            regexes += 1
        elif folder.match(line):
            creates += 1
        else:
            raise AssertionError("an allow line under refs/heads is neither a literal nor an archive rule: " + line)
    return sorted(literals), regexes, creates


def comparable(profile):
    """The profile's lines, every allow and every deny line, minus the one volatile class.

    The generator denies each per-session folder that other sessions have created
    directly under Claude's shared temp root, by literal path, so those lines change
    between two builds whenever another session starts or ends. Every other line,
    deny lines included, must compare equal for equal inputs.
    """
    claude_tmp = os.path.realpath("/tmp") + "/claude-" + str(os.getuid())
    sibling = re.compile(r'^\(deny file-write\* \(literal "' + re.escape(claude_tmp) + r'/[^/"]+"\)\)$')
    return [line for line in profile.splitlines() if not sibling.match(line)]


def literal(path):
    return f'(allow file-write* (literal "{path}"))'


def expected_branch_lines(common, name):
    lines = []
    for folder in ("refs/heads", "logs/refs/heads"):
        path = f"{common}/{folder}/{name}"
        lines += [literal(path), literal(path + ".lock")]
    return lines


def sandbox_applies():
    """True when this process may apply a sandbox profile; otherwise the exact refusal."""
    probe = subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"],
                           capture_output=True, text=True)
    return None if probe.returncode == 0 else probe.stderr.strip()


def confined(profile, manifest, *argv):
    return subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile), *argv], capture_output=True, text=True,
                          env=dict(os.environ, **GIT_ENV))


def ref_exists(manifest, name):
    return git("-C", str(manifest["project"]), "rev-parse", "--verify", "-q", "refs/heads/" + name, check=False).returncode == 0


def unit(base):
    manifest = layout(base / "fixture")
    common = common_dir(manifest)
    results = {}

    # 1. The no-successor profile is the task's branch, its lock, its reflog and
    #    its archive names, and nothing else under refs/heads.
    before = build(manifest, "before.sb")
    assert ref_allows(before, common) == (sorted(expected_branch_lines(common, BRANCH)), 2, 2), \
        "a task with no successor must allow exactly its branch, lock, reflog and archive names: " + repr(ref_allows(before, common))
    results["no-successor-allows-exactly-the-branch"] = True
    # Every allow and deny line, minus the per-session sibling folders of Claude's shared
    # temp root (comparable); the run root is random and the profile names it three
    # ways: as written, as a regex-escaped path, and as the dash-encoded Claude project
    # folder name.
    whole = "\n".join(comparable(before))
    root = str(base.resolve())
    for form in (re.escape(root), root, re.sub(r"[^A-Za-z0-9]", "-", root)):
        whole = whole.replace(form, "<BASE>")
    digest = hashlib.sha256(whole.encode()).hexdigest()
    print(f"DIGEST no-successor-generator-profile={digest}")

    # 2. The same inputs plus a recorded successor differ by exactly the
    #    successor's four literal lines: ref, ref.lock, reflog, reflog.lock.
    after = build(manifest, "after.sb", successor=SUCCESSOR)
    before_lines, after_lines = before.splitlines(), after.splitlines()
    # Allow and deny lines alike: a successor build may add its four allow lines and
    # nothing else, and may drop no line, so a removed protected-ref deny is seen.
    before_cmp, after_cmp = comparable(before), comparable(after)
    added = [line for line in after_cmp if line not in before_cmp]
    removed = [line for line in before_cmp if line not in after_cmp]
    assert not removed, f"the successor profile dropped lines: {removed}"
    assert sorted(added) == sorted(expected_branch_lines(common, SUCCESSOR)), \
        "the profile may gain exactly the successor's four literal allow lines, got " + repr(sorted(added))
    assert ref_allows(after, common) == (sorted(expected_branch_lines(common, BRANCH) + expected_branch_lines(common, SUCCESSOR)), 2, 2), \
        "the successor profile must allow exactly the branch, the successor and the archive names under refs/heads"
    results["successor-adds-exactly-four-literals"] = True
    # No pattern, folder or prefix of the successor appears anywhere.
    for line in after_lines:
        if SUCCESSOR in line:
            assert line.startswith("(allow file-write* (literal ") and "regex" not in line and "subpath" not in line, \
                "the successor must appear only in literal allow lines: " + line
    assert after.count(SUCCESSOR) == 4, "the successor must appear in exactly its four literal lines"
    results["successor-only-in-literal-lines"] = True

    # 3. The generator refuses a successor it cannot grant as one exact literal.
    for bad in ("fm/*", "fm/task-v2 x", "fm/task-v2*", "fm/[a]", "fm/task-v2?", "x/", BRANCH, "-x", "a..b", 'fm/q"uote',
                "fm/back\\slash", "archive/task-submitted-0123abcd", "fm/task-v2.lock"):
        assert refused_build(manifest, "bad.sb", successor=bad), f"the generator accepted the inadmissible successor {bad!r}"
    assert refused_build(manifest, "nobranch.sb", successor=SUCCESSOR, branch=""), "a successor without a task branch must refuse"
    results["generator-refuses-inadmissible-successors"] = True

    for name in results:
        print(f"ok - {name}")
    return 0


def family(base):
    manifest = layout(base / "fixture")
    results = {}
    # C1: the generator repeats the name-family bound. A successor is the task's
    #    branch name, then '-', then one or more of letters, digits, '.', '_', '-'.
    for outside in ("develop", "fm/other", "fm/task-", "fm/task-a/b", "FM/task-v2", "fm/task2-v2", "release/1.x"):
        error = refused_build(manifest, "family.sb", successor=outside)
        assert error and ("name family" in error or "exact literal" in error), \
            f"the generator must refuse {outside!r} as outside the task's name family, got {error!r}"
    for inside in ("fm/task-v2.1", "fm/task-x_y-Z", "fm/task--2"):
        build(manifest, "family-ok.sb", successor=inside)
    results["generator-holds-the-name-family-bound"] = True

    for name in results:
        print(f"ok - {name}")
    return 0


def alias(base):
    manifest = layout(base / "fixture")
    results = {}
    # C5: the alias check runs on the successor's ref and reflog paths. A hard
    #    link or a symbolic link there makes the build refuse and name the path; the
    #    task's own branch keeps the base behaviour (exempt).
    project, common = manifest["project"], common_dir(manifest)
    git("-C", str(project), "branch", SUCCESSOR, manifest["sha"])
    ref, reflog = common / "refs/heads" / SUCCESSOR, common / "logs/refs/heads" / SUCCESSOR
    assert ref.is_file() and reflog.is_file(), "the scratch repository must hold the successor's ref and reflog files"
    assert build(manifest, "alias-clean.sb", successor=SUCCESSOR), "a clean successor must build"
    for path in (ref, reflog):
        alias = manifest["base"] / ("alias-" + path.parent.name + "-" + path.name)
        os.link(path, alias)
        error = refused_build(manifest, "alias.sb", successor=SUCCESSOR)
        assert error and str(path) in error and "links" in error, \
            f"a hard link at the successor's {path} must refuse the build and name the path, got {error!r}"
        alias.unlink()
        moved = path.with_name(path.name + ".real")
        path.rename(moved)
        os.symlink(moved, path)
        error = refused_build(manifest, "alias.sb", successor=SUCCESSOR)
        assert error and str(path) in error and "symbolic link" in error, \
            f"a symbolic link at the successor's {path} must refuse the build and name the path, got {error!r}"
        path.unlink()
        moved.rename(path)
    assert build(manifest, "alias-restored.sb", successor=SUCCESSOR), "removing every alias must let the build pass again"
    own = common / "refs/heads" / BRANCH
    own_alias = manifest["base"] / "alias-own"
    os.link(own, own_alias)
    assert build(manifest, "alias-own.sb", successor=SUCCESSOR), "a second link at the task's own branch keeps the base behaviour and builds"
    own_alias.unlink()
    results["alias-check-covers-the-successor-and-spares-the-own-branch"] = True
    for name in results:
        print(f"ok - {name}")
    return 0


def kernel(repo, base):
    """The real kernel confinement on the Scott fixture; see the module docstring."""
    required = os.environ.get("FM_REQUIRE_KERNEL_PROOF") == "1"

    def unverified(reason):
        print(f"SKIPPED-UNVERIFIED kernel proof of PROFILE-COVERS: {reason}")
        if required:
            print("not ok - FM_REQUIRE_KERNEL_PROOF=1 demands the kernel proof, which could not run")
            return 3
        return 0

    if sys.platform != "darwin":
        return unverified("Seatbelt confinement exists on macOS only")
    refusal = sandbox_applies()
    if refusal:
        return unverified(f"/usr/bin/sandbox-exec cannot apply a profile from this process ({refusal}; exit 71 when this process is already sandboxed)")
    maker = Path(os.environ.get("FM_SCOTT_FIXTURE_MAKER") or repo / "tests/fixtures/fm-scott-task-shape.sh")
    fx = base / "scott"
    fx.mkdir(parents=True)
    # Run the maker through a copy whose TASK line alone is renamed, so no live task's id is used.
    task = "fm-scott-fixture-task"
    text = maker.read_text()
    assert text.count("\nTASK=fm-slack-second-person-scott\n") == 1, "the fixture maker no longer has the one TASK line this test renames"
    renamed = base / "maker.sh"
    renamed.write_text(text.replace("\nTASK=fm-slack-second-person-scott\n", f"\nTASK={task}\n"))
    made = subprocess.run(["bash", str(renamed), str(fx)], capture_output=True, text=True)
    assert made.returncode == 0, "the Scott fixture maker failed: " + made.stderr
    old, succ = f"fm/{task}", f"fm/{task}-v2"
    project, copy, home = fx / "project", fx / "slots/22/project", fx / "home"
    (home / "config").mkdir(exist_ok=True)
    (home / "projects").mkdir(exist_ok=True)
    (home / "data").mkdir(exist_ok=True)
    p_tip = git("-C", str(project), "rev-parse", "refs/heads/" + succ).stdout.strip()
    s_tip = git("-C", str(project), "rev-parse", "refs/heads/" + old).stdout.strip()
    git("-C", str(project), "update-ref", "refs/heads/fm/other-task", s_tip)

    def profile_for(name, successor):
        profile = fx / name
        command = [sys.executable, str(repo / "bin/fm-write-confinement.py"), "--worktree", str(copy), "--home", str(home),
                   "--config", str(home / "config"), "--projects", str(home / "projects"), "--data", str(home / "data" / task),
                   "--state", str(home / "state"), "--task", task, "--harness", "claude", "--claude-session", SESSION,
                   "--branch", old, "--profile", str(profile)]
        if successor:
            command += ["--successor-branch", successor]
        built = subprocess.run(command, capture_output=True, text=True,
                               env=dict(os.environ, NM_HOME=str(fx / "nm"), CLAUDE_CONFIG_DIR=str(fx / "claude")))
        assert built.returncode == 0, "the generator refused the Scott fixture: " + built.stderr
        return profile

    old_profile, new_profile = profile_for("old.sb", None), profile_for("new.sb", succ)

    def ref(name):
        found = git("-C", str(project), "rev-parse", "--verify", "-q", "refs/heads/" + name, check=False)
        return found.stdout.strip() if found.returncode == 0 else None

    def argv_for(name, target, how):
        if how == "create":
            return ["git", "-C", str(copy), "branch", name, target]
        if how == "move":
            return ["git", "-C", str(copy), "update-ref", "-m", "kernel proof", "refs/heads/" + name, target]
        return ["git", "-C", str(copy), "branch", "-D", name]

    def restore(name, before):
        if before is None:
            git("-C", str(project), "update-ref", "-d", "refs/heads/" + name, check=False)
        else:
            git("-C", str(project), "update-ref", "refs/heads/" + name, before)

    def unconfined(name, target, how):
        return subprocess.run(argv_for(name, target, how), capture_output=True, text=True, env=dict(os.environ, **GIT_ENV))

    def allowed(profile, name, target, how, label):
        """The write must succeed under the profile: exit 0 and the ref moved where it was told to."""
        before = ref(name)
        result = confined(profile, None, *argv_for(name, target, how))
        after = ref(name)
        restore(name, before)
        assert result.returncode == 0, f"{label}: the confined git command must exit 0, got {result.returncode}: {result.stderr.strip()}"
        want = None if how == "delete" else target
        assert after == want, f"{label}: the ref must end at {want!r}, ended at {after!r}"

    def refused(profile, name, target, how, label):
        """The write must be refused by the confinement, and by nothing else.

        The same command is first run unconfined, so a command that is wrong in itself
        (a name that collides with an existing ref, a bad object) cannot pass as a
        refusal; then, confined, it must exit nonzero with the kernel's
        operation-not-permitted error and leave the ref where it was.
        """
        before = ref(name)
        control = unconfined(name, target, how)
        moved = ref(name)
        restore(name, before)
        assert control.returncode == 0 and moved != before, \
            f"{label}: the command must be valid when unconfined, or its refusal proves nothing: {control.stderr.strip()}"
        result = confined(profile, None, *argv_for(name, target, how))
        after = ref(name)
        restore(name, before)
        assert after == before, f"{label}: the confined write changed the ref"
        assert result.returncode != 0, f"{label}: the confined git command must exit nonzero"
        assert CONFINEMENT_REFUSAL.search(result.stderr or ""), \
            f"{label}: git failed for a reason other than the confinement refusing it: {(result.stderr or '').strip()}"

    # With the new profile the successor is allowed: moved, created after deletion, deleted.
    allowed(new_profile, succ, s_tip, "move", "new profile: moving the successor ref")
    git("-C", str(project), "update-ref", "-d", "refs/heads/" + succ)
    allowed(new_profile, succ, p_tip, "create", "new profile: git branch <successor> <sha>")
    git("-C", str(project), "update-ref", "refs/heads/" + succ, p_tip)
    allowed(new_profile, succ, None, "delete", "new profile: deleting the successor")
    # With the old profile the same writes are refused as today.
    refused(old_profile, succ, s_tip, "move", "old profile: moving the successor")
    git("-C", str(project), "update-ref", "-d", "refs/heads/" + succ)
    refused(old_profile, succ, p_tip, "create", "old profile: git branch <successor> <sha>")
    git("-C", str(project), "update-ref", "refs/heads/" + succ, p_tip)
    # With the new profile an unrelated name and names that share the successor as a prefix
    # or a suffix are refused; so is a folder under the successor, which is a valid name only
    # while the successor ref itself is absent.
    for label, name in (("unrelated", "fm/unrelated"), ("successor-as-prefix", succ + "-x"), ("successor-as-suffix", "fm/pre-" + succ),
                        ("old-branch-as-prefix", old + "-x")):
        refused(new_profile, name, p_tip, "create", f"new profile: creating {name!r} ({label})")
    git("-C", str(project), "update-ref", "-d", "refs/heads/" + succ)
    refused(new_profile, succ + "/child", p_tip, "create", f"new profile: creating {succ + '/child'!r} (successor-as-folder)")
    git("-C", str(project), "update-ref", "refs/heads/" + succ, p_tip)
    refused(new_profile, "fm/other-task", p_tip, "move", "new profile: moving another task's branch")
    refused(new_profile, "fm/other-task", None, "delete", "new profile: deleting another task's branch")
    assert ref("fm/other-task") == s_tip, "another task's branch must stay where it was"
    assert ref(succ) == p_tip and ref(old) == s_tip, "the fixture's refs must be back where they were"
    print("ok - kernel proof: the new profile allows the successor and refuses an unrelated name, another task's branch and prefix- or suffix-sharing names; the old profile refuses the successor")
    return 0


def main():
    global REPO
    REPO = Path(sys.argv[1]).resolve()
    base = Path(sys.argv[2])
    mode = sys.argv[3] if len(sys.argv) > 3 else "all"
    if mode == "all":
        return unit(base / "unit") or family(base / "family") or alias(base / "alias")
    if mode == "unit":
        return unit(base)
    if mode == "family":
        return family(base)
    if mode == "alias":
        return alias(base)
    if mode == "kernel":
        return kernel(REPO, base)
    raise SystemExit("mode must be all, unit, family, alias or kernel")


if __name__ == "__main__":
    sys.exit(main())
