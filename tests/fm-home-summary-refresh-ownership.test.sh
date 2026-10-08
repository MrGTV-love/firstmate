#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-summary-ownership)
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

ROOT="$ROOT" TMP_ROOT="$TMP_ROOT" python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

root = Path(os.environ["ROOT"])
tmp = Path(os.environ["TMP_ROOT"])
writer = root / "bin/fm-home-summary-refresh.sh"
fakebin = tmp / "fakebin"
fakebin.mkdir()
real = {name: shutil.which(name) for name in ("jq", "mv", "rm")}
shim = '''#!/usr/bin/env bash
name=${0##*/}
match=0
for arg in "$@"; do
  case "$name:$arg" in
    jq:*/.home-summary.json.*) [ "${FM_TEST_GATE_PHASE:-}" != validation ] || match=1
      [ "${FM_TEST_FAIL_VALIDATE:-0}" != 1 ] || exit 7 ;;
    mv:*/home-summary.json) [ "${FM_TEST_GATE_PHASE:-}" != publication ] || match=1 ;;
    mv:*/.home-summary-refresh.streak) [ "${FM_TEST_GATE_PHASE:-}" != accounting ] || match=1 ;;
    rm:*/.home-summary-refresh.lock) [ "${FM_TEST_GATE_PHASE:-}" != release ] || match=1 ;;
  esac
done
if [ "$match" = 1 ]; then
  printf '%s %s\\n' "$$" "$PPID" > "$FM_TEST_GATE.entered"
  while [ -e "$FM_TEST_GATE" ]; do sleep 0.05; done
fi
case "$name" in
  jq) exec "$FM_TEST_REAL_JQ" "$@" ;;
  mv) exec "$FM_TEST_REAL_MV" "$@" ;;
  rm) exec "$FM_TEST_REAL_RM" "$@" ;;
esac
'''
for name in real:
    path = fakebin / name
    path.write_text(shim)
    path.chmod(0o755)
(fakebin / "tmux").write_text("#!/usr/bin/env bash\nexit 1\n")
(fakebin / "tmux").chmod(0o755)
processes = []
groups = set()
gates = []
outputs = []

def home(name):
    path = tmp / name
    for directory in ("state", "data", "config", "projects"):
        (path / directory).mkdir(parents=True)
    (path / "data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
    return path

def environment(path, generation="2026-08-28T10:02:00Z", **extra):
    result = dict(os.environ, PATH=f"{fakebin}:{os.environ['PATH']}",
                  FM_ROOT_OVERRIDE=str(root), FM_HOME=str(path),
                  FM_STATE_OVERRIDE=str(path / "state"), FM_DATA_OVERRIDE=str(path / "data"),
                  FM_CONFIG_OVERRIDE=str(path / "config"), FM_PROJECTS_OVERRIDE=str(path / "projects"),
                  FM_HOME_SUMMARY_IF_IDLE="0",
                  FM_SNAPSHOT_NOW=generation, FM_SNAPSHOT_NOW_EPOCH="1787911320",
                  FM_HOME_SUMMARY_TIMEOUT="30", FM_TIMEOUT_MECHANISM_OVERRIDE="bash")
    for name, executable in real.items():
        result[f"FM_TEST_REAL_{name.upper()}"] = executable
    result.update(extra)
    return result

def launch(path, args=(), stderr=None, **extra):
    output = (tmp / f"output-{len(processes)}").open("wb")
    outputs.append(output)
    process = subprocess.Popen([str(writer), *args], env=environment(path, **extra),
                               stdin=subprocess.DEVNULL, stdout=output,
                               stderr=output if stderr is None else stderr,
                               start_new_session=True)
    processes.append(process)
    return process

def finish(process, timeout=20):
    result = process.wait(timeout=timeout)
    assert result == 0, f"writer exited {result}"

def await_gate(gate, process):
    deadline = time.monotonic() + 15
    marker = Path(str(gate) + ".entered")
    while not marker.exists():
        assert process.poll() is None, "writer exited before controlled operation"
        assert time.monotonic() < deadline, "writer never reached controlled operation"
        time.sleep(0.05)
    pid, worker = map(int, marker.read_text().split())
    groups.add(os.getpgid(pid))
    return worker

def generation(path):
    return json.loads((path / "state/home-summary.json").read_text())["generated"]

def released(path):
    for suffix in (".lock", ".lock.steal"):
        lock = path / f"state/.home-summary-refresh{suffix}"
        assert not os.path.lexists(lock), f"refresh left {suffix} held"

def wake_count(path):
    queue = path / "state/.wake-queue"
    return sum(row.split("\t")[2:4] == ["check", "home-summary-refresh"]
               for row in queue.read_text().splitlines()) if queue.exists() else 0

try:
    for idle in ("0", "1"):
        path = home(f"stale-validation-{idle}")
        gate = tmp / f"validation-{idle}"
        gate.touch()
        gates.append(gate)
        old = launch(path, generation="2026-08-28T10:01:00Z",
                     FM_HOME_SUMMARY_IF_IDLE=idle, FM_TEST_GATE_PHASE="validation",
                     FM_TEST_GATE=str(gate))
        worker = await_gate(gate, old)
        old.kill()
        old.wait()
        finish(launch(path))
        finish(launch(path, ("--best-effort",), FM_TEST_FAIL_VALIDATE="1"))
        streak = path / "state/.home-summary-refresh.streak"
        before = streak.read_bytes()
        gate.unlink()
        deadline = time.monotonic() + 5
        while True:
            try:
                os.kill(worker, 0)
            except ProcessLookupError:
                break
            assert time.monotonic() < deadline, "orphaned worker failed to finish"
            time.sleep(0.05)
        assert generation(path) == "2026-08-28T10:02:00Z", "stale worker overwrote new ledger"
        assert streak.read_bytes() == before, "stale worker erased newer failure streak"
        released(path)
    print("ok - parent cancellation fences both acquisition paths after validation", flush=True)

    for phase in ("publication", "accounting", "release"):
        path = home(f"fenced-{phase}")
        if phase == "accounting":
            for _ in range(2):
                finish(launch(path, ("--best-effort",), FM_TEST_FAIL_VALIDATE="1"))
        gate = tmp / phase
        gate.touch()
        gates.append(gate)
        extra = dict(generation="2026-08-28T10:01:00Z", FM_TEST_GATE_PHASE=phase,
                     FM_TEST_GATE=str(gate))
        args = ()
        if phase == "accounting":
            extra["FM_TEST_FAIL_VALIDATE"] = "1"
            args = ("--best-effort",)
        old = launch(path, args, **extra)
        await_gate(gate, old)
        old.kill()
        old.wait()
        newer = launch(path)
        time.sleep(0.8)
        assert newer.poll() is None, f"new writer bypassed active {phase} fence"
        gate.unlink()
        finish(newer)
        assert generation(path) == "2026-08-28T10:02:00Z", f"{phase} corrupted final ledger"
        assert not (path / "state/.home-summary-refresh.streak").exists(), "old streak survived success"
        assert wake_count(path) == (1 if phase == "accounting" else 0), "unexpected escalation"
        released(path)
    print("ok - reclaim waits for publication, accounting, and release critical sections", flush=True)

    path = home("blocked-logger")
    (path / "state/.home-summary-refresh.log").mkdir()
    read_fd, write_fd = os.pipe()
    try:
        os.set_blocking(write_fd, False)
        try:
            while True:
                os.write(write_fd, b"x" * 4096)
        except BlockingIOError:
            pass
        os.set_blocking(write_fd, True)
        # Allow the configured 30s refresh plus bounded logging (4s), accounting
        # (10s), and release (4s); incidental producer speed is not the contract.
        for count in range(1, 4):
            finish(launch(path, ("--best-effort",), stderr=write_fd,
                          FM_TEST_FAIL_VALIDATE="1"), timeout=50)
            streak = dict(line.split("=", 1) for line in
                          (path / "state/.home-summary-refresh.streak").read_text().splitlines())
            assert int(streak["count"]) == count, "logger timeout suppressed acquired failure"
            assert wake_count(path) == (1 if count == 3 else 0), "wrong three-failure escalation"
            released(path)
    finally:
        os.close(write_fd)
        os.close(read_fd)
    finish(launch(path))
    assert not (path / "state/.home-summary-refresh.streak").exists(), "success failed to clear streak"
    released(path)
    print("ok - three acquired failures escalate and release despite blocked logging", flush=True)
finally:
    for gate in gates:
        gate.unlink(missing_ok=True)
    for process in processes:
        if process.poll() is None:
            process.kill()
            process.wait()
    for group in groups:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for output in outputs:
        output.close()
PY
