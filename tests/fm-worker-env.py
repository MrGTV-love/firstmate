"""Fake-only portable acceptance of both shared source-boundary interfaces."""
import json
import os
from pathlib import Path
import subprocess
import shlex
import sys
import tempfile

root = Path(sys.argv[1])
helper = root / "bin/fm-worker-env.py"
python = sys.executable
with tempfile.TemporaryDirectory(prefix="fm-worker-env-") as temporary:
    home = Path(temporary)
    fake = "sentinel-not-a-secret"
    environment = {"HOME": str(home), "PATH": os.defpath, "TERM": "xterm",
                   "FM_TASK_ID": "fake-worker", "FM_TEST_FAKE_API_KEY": fake,
                   "FM_TEST_EMPTY": "", "FM_GUARD_EVENT_LOG": str(home / "state/guard-events.jsonl")}
    def launch(command, *options):
        return subprocess.run([python, str(helper), *options, "--", *command],
                              env=environment, capture_output=True, text=True)

    probe = "import os,json; print(json.dumps(dict(os.environ)))"
    observed = launch([python, "-c", probe])
    assert observed.returncode == 0, observed.stderr
    child = json.loads(observed.stdout)
    assert "FM_TEST_FAKE_API_KEY" not in child
    assert child["TERM"] == "xterm" and child["FM_TASK_ID"] == "fake-worker"
    dumped = launch(["/usr/bin/env"])
    assert dumped.returncode == 0 and fake not in dumped.stdout
    assert "TERM=xterm" in dumped.stdout
    nested = launch(["/bin/sh", "-c", 'exec "$1" -c "$2"', "probe", python, probe])
    assert nested.returncode == 0 and "FM_TEST_FAKE_API_KEY" not in json.loads(nested.stdout)

    kept = launch([python, "-c", probe], "--keep", "FM_TEST_FAKE_API_KEY", "--keep", "FM_TEST_EMPTY", "--keep", "FM_TEST_ABSENT")
    assert kept.returncode == 0, kept.stderr
    parent = json.loads(kept.stdout)
    assert parent["FM_TEST_FAKE_API_KEY"] == fake and parent["FM_TEST_EMPTY"] == ""
    assert "FM_TEST_ABSENT" not in parent
    # A retained credential is deliberately NOT claimed child-isolated.
    retained_child = launch(["/bin/sh", "-c", 'exec "$1" -c "$2"', "probe", python, probe], "--keep", "FM_TEST_FAKE_API_KEY")
    assert json.loads(retained_child.stdout)["FM_TEST_FAKE_API_KEY"] == fake
    prefix = subprocess.run([python, str(helper), "--shell-prefix", "--keep", "FM_TEST_LOCAL", "--keep", "FM_TEST_EMPTY", "--keep", "FM_TEST_ABSENT"],
                            env=environment, capture_output=True, text=True)
    assert prefix.returncode == 0 and fake not in prefix.stdout
    local_value = 'fake local value; $(false) "quoted"'
    shell = 'FM_TEST_LOCAL=$1; FM_TEST_EMPTY=; unset FM_TEST_ABSENT; ' + prefix.stdout.strip() + ' ' + shlex.quote(python) + ' -c ' + shlex.quote(probe)
    generated = subprocess.run(["/bin/sh", "-c", shell, "probe", local_value], env=environment, capture_output=True, text=True)
    assert generated.returncode == 0, generated.stderr
    actual = json.loads(generated.stdout)
    assert actual["FM_TEST_LOCAL"] == local_value and actual["FM_TEST_EMPTY"] == ""
    assert "FM_TEST_ABSENT" not in actual and "FM_TEST_FAKE_API_KEY" not in actual
    invalid = subprocess.run([python, str(helper), "--shell-prefix", "--keep", "NAME;false"], env=environment, capture_output=True, text=True)
    assert invalid.returncode == 2 and invalid.stdout == ""
    print("PASS source boundary: env, Python and child shell lose fake credential; operational floor survives; explicit auth retention preserves empty/absent semantics")
    print("PASS generated source boundary: destination-only unexported values and quoted data survive; fake credential absent; invalid names emit no executable source")

