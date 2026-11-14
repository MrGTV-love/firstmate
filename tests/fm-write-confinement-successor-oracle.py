#!/usr/bin/env python3
"""F7: the kernel validator must tell a confinement refusal from an unrelated failure.

Usage: fm-write-confinement-successor-oracle.py <repo-root> <scratch-dir>

tests/fm-write-confinement-successor.py `kernel` mode runs git under a real
sandbox-exec profile, which only macOS CI can do. Its judgment is exercised here with
the confinement stubbed, so the judgment itself is tested anywhere:
  - an ideal confinement (refused writes fail with an operation-not-permitted error and
    change nothing) must pass, and the successor must never be judged while the ref it
    would collide with still exists;
  - a confinement whose refusals are really unrelated git failures (the command is
    wrong, the ref is unchanged) must fail the validator;
  - no confinement at all must fail it.
No kernel and no sandbox are used.
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
from unittest import mock

repo = Path(sys.argv[1]).resolve()
scratch = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("successor_tests", repo / "tests/fm-write-confinement-successor.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.REPO = repo


# The successor tests/fm-write-confinement-successor.py `kernel` mode grants on its Scott fixture.
SUCCESSOR = "fm/fm-scott-fixture-task-v2"


def ref_name(argv):
    if argv[3] == "branch" and argv[4] == "-D":
        return argv[5]
    if argv[3] == "branch":
        return argv[4]
    return argv[-2].replace("refs/heads/", "", 1)


def run_kernel(label, style):
    """Run the module's kernel validator with the confinement stubbed in the given style."""
    calls = []

    def fake_confined(profile, manifest, *argv):
        name = ref_name(argv)
        copy = argv[2]
        exists = subprocess.run(["git", "-C", copy, "rev-parse", "--verify", "-q", "refs/heads/" + name.rsplit("/child", 1)[0]],
                                capture_output=True).returncode == 0
        calls.append((Path(profile).name, name, exists))
        permitted = style == "none" or (Path(profile).name == "new.sb" and name == SUCCESSOR)
        if permitted:
            return subprocess.run(list(argv), capture_output=True, text=True, env=dict(os.environ, **module.GIT_ENV))
        if style == "ideal":
            return subprocess.CompletedProcess(argv, 1, "", f"error: unable to create 'refs/heads/{name}': Operation not permitted\n")
        return subprocess.CompletedProcess(argv, 128, "", "fatal: bad object 0000000000000000000000000000000000000000\n")

    with mock.patch.object(module.sys, "platform", "darwin"), \
            mock.patch.object(module, "sandbox_applies", lambda: None), \
            mock.patch.object(module, "confined", fake_confined):
        try:
            result = module.kernel(repo, scratch / label)
        except AssertionError as error:
            return "failed", str(error), calls
    return ("passed" if result == 0 else "failed"), "", calls


outcome, detail, calls = run_kernel("ideal", "ideal")
assert outcome == "passed", f"an ideal confinement must pass the kernel validator: {detail}"
for profile, name, exists in calls:
    assert not (name.endswith("/child") and exists), \
        f"{profile}: {name!r} was judged while the ref it collides with still existed, so git would refuse it with or without confinement"
print("ok - the kernel validator passes an ideal confinement and judges every refusal on a valid command")

outcome, detail, _ = run_kernel("unrelated", "unrelated")
assert outcome == "failed", "the kernel validator passed refusals that were unrelated git failures"
print("ok - the kernel validator fails when a refusal is an unrelated git failure")

outcome, detail, _ = run_kernel("none", "none")
assert outcome == "failed", "the kernel validator passed a run with no confinement at all"
print("ok - the kernel validator fails when nothing is confined")
