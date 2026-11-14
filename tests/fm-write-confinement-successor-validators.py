#!/usr/bin/env python3
"""F7: the profile validators must see a changed deny line, not only the allow lines.

Usage: fm-write-confinement-successor-validators.py <repo-root> <scratch-dir>

The unit validator of tests/fm-write-confinement-successor.py compares the profile
built with a successor to the profile built without one. Here the production
generator is wrapped so that the successor build loses one protected-ref deny
line, the defect a deny-blind comparison cannot see, and the validator must fail on
it. The control builds the profile unchanged and the validator must pass.
Runs anywhere; no kernel and no sandbox are used.
"""
import importlib.util
from pathlib import Path
import sys

repo = Path(sys.argv[1]).resolve()
scratch = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("successor_tests", repo / "tests/fm-write-confinement-successor.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.REPO = repo

control = module.unit(scratch / "control")
assert control == 0, "the validator must pass on the unchanged generator"
print("ok - the profile validator passes on the unchanged generator")

real_build = module.build


def build_without_a_deny_line(manifest, name, **kwargs):
    """The generator with a defect: a successor build also loses the deny of the refs/heads folder."""
    text = real_build(manifest, name, **kwargs)
    if kwargs.get("successor"):
        lines = text.splitlines()
        victims = [line for line in lines if line.startswith("(deny file-write* (subpath ") and "/refs/heads" in line and "/logs/" not in line]
        assert victims, "the fixture profile must hold the refs/heads deny line this defect removes"
        text = "\n".join(line for line in lines if line not in victims) + "\n"
        (manifest["base"] / name).write_text(text)
    return text


module.build = build_without_a_deny_line
try:
    module.unit(scratch / "mutated")
except AssertionError as error:
    print("ok - the profile validator fails when the successor build loses a protected-ref deny line: " + str(error)[:120])
else:
    raise AssertionError("the profile validator passed a successor build that lost a protected-ref deny line")
finally:
    module.build = real_build
