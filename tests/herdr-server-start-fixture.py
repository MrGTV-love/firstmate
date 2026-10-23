#!/usr/bin/env python3
"""Exercise the real adapter with intercepted Herdr launches, never the real CLI."""

import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(sys.argv.pop(1)).resolve()
EVIDENCE = os.environ.get("FM_HERDR_START_EVIDENCE")

STUB = r'''
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ["START_FIXTURE"])
args = sys.argv[1:]
with (root / "argv.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\n")
if "--session" not in args or args[args.index("--session") + 1] != root.name:
    sys.exit("refusing an unscoped or different-session invocation")
cmd = args[0]
if cmd == "status":
    mode = os.environ.get("START_STATUS", "false")
    if not (root / "pid").exists():
        if mode == "error": sys.exit(1)
        if mode == "timeout": sys.exit(124)
        if mode == "empty": sys.exit(0)
    print(json.dumps({"server": {"running": (root / "pid").exists(),
        "socket": str(root / "herdr.sock"), "session": root.name}}))
elif cmd == "session":
    print(json.dumps({"sessions": [{"name": root.name, "running": False,
        "socket_path": str(root / "herdr.sock")}]}))
elif cmd == "server":
    with (root / "servers").open("a") as servers:
        servers.write(str(os.getpid()) + "\n")
    (root / "pid").write_text(str(os.getpid()))
    time.sleep(60)
else:
    print('{"error":{"code":"server_not_running"}}')
    sys.exit(1)
'''


class StartupSafety(unittest.TestCase):
    def setUp(self):
        # Keep Unix socket paths below Darwin's 104-byte sockaddr_un limit.
        self.tmp = tempfile.TemporaryDirectory(prefix="fm-lab-start-", dir="/tmp")
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        stub = self.bin / "herdr"
        stub.write_text(f"#!{sys.executable}\n" + STUB)
        stub.chmod(0o755)
        (self.bin / "no-mistakes").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "no-mistakes").chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        START_FIXTURE=str(self.dir), FM_HOME=str(self.dir),
                        FM_ROOT_OVERRIDE=str(ROOT), FM_STATE_OVERRIDE=str(self.dir / "state"),
                        FM_DATA_OVERRIDE=str(self.dir / "data"), FM_CONFIG_OVERRIDE=str(self.dir / "config"),
                        FM_PROJECTS_OVERRIDE=str(self.dir / "projects"),
                        FM_MODEL_FRESHNESS="0", FM_CREW_STATE_NO_FORGE="1")
        self.env.pop("FM_CREW_STATE_META_OVERRIDE", None)
        self.env.pop("FM_CREW_STATE_STATUS_OVERRIDE", None)
        self.listener = None
        self.children = []
        self.transcript = []

    def tearDown(self):
        servers = self.dir / "servers"
        if servers.exists():
            for pid in servers.read_text().splitlines():
                try:
                    os.kill(int(pid), signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            try:
                child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.communicate()
        if self.listener:
            self.listener.close()
        if EVIDENCE:
            dest = Path(EVIDENCE) / self._testMethodName
            dest.mkdir(parents=True, exist_ok=True)
            for filename in ("argv.jsonl", "pid"):
                if (self.dir / filename).exists():
                    shutil.copyfile(self.dir / filename, dest / filename)
            (dest / "observations.txt").write_text("\n".join(self.transcript) + "\n")
        self.tmp.cleanup()

    def listen(self):
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(self.dir / "herdr.sock"))
        self.listener.listen(128)

    def invoke(self, script, *, status="false", inherited_pipe=False):
        self.env["START_STATUS"] = status
        if inherited_pipe:
            script = "exec 3>&1; " + script
        child = subprocess.Popen(["bash", "-c", script, "fixture", str(ROOT), self.dir.name],
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True)
        self.children.append(child)
        try:
            out, err = child.communicate(timeout=4)
        except subprocess.TimeoutExpired:
            self.transcript.append("starter did not release its output pipe while the server was alive")
            self.fail("server retained a starter descriptor or the call did not return")
        self.transcript.append(f"rc={child.returncode} stdout={out!r} stderr={err!r}")
        return child.returncode, out

    def starts(self):
        log = self.dir / "argv.jsonl"
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return [call for call in calls if call[0] == "server"]

    def ensure(self, **kwargs):
        return self.invoke('. "$1/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure "$2"', **kwargs)

    def test_live_socket_failed_status_does_not_launch(self):
        self.listen()
        # A timed-out client exit and an empty successful read are both unknown.
        for mode in ("error", "timeout", "empty", "false"):
            with self.subTest(status=mode):
                rc, _ = self.ensure(status=mode)
                self.assertNotEqual(rc, 0, "contradictory/unknown status must refuse startup")
                self.assertEqual(self.starts(), [], "a live listener must never be replaced")

    def test_live_process_without_socket_does_not_launch(self):
        binary = self.dir / "server executable with several extra spaces" / "herdr"
        binary.parent.mkdir()
        shutil.copyfile(self.bin / "herdr", binary)
        binary.chmod(0o755)
        server = subprocess.Popen([str(binary), "server", "--session", self.dir.name],
                                  env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(server)
        for _ in range(100):
            if (self.dir / "pid").exists():
                break
            time.sleep(.01)
        self.assertTrue((self.dir / "pid").exists(), "fixture server failed to start")
        # Hide the stub's readiness marker, leaving its real server process alive.
        (self.dir / "pid").unlink()
        rc, _ = self.ensure()
        self.assertNotEqual(rc, 0)
        self.assertEqual(len(self.starts()), 1, "an unreachable live process must prevent a second start")

    def test_proven_absence_starts_once_and_reuses_server(self):
        rc, _ = self.ensure()
        self.assertEqual(rc, 0)
        self.assertEqual(len(self.starts()), 1)
        self.assertEqual(self.ensure()[0], 0)
        self.assertEqual(len(self.starts()), 1, "a second ensure must reuse the first server")

    def test_stale_socket_does_not_prevent_proven_absence_start(self):
        self.listen()
        self.listener.close()
        self.listener = None
        self.assertTrue((self.dir / "herdr.sock").exists())
        self.assertEqual(self.ensure()[0], 0)
        self.assertEqual(len(self.starts()), 1)

    def test_other_process_arguments_are_not_server_identity(self):
        payload = "herdr server 'an instruction, not an executable"
        fifo = self.dir / payload
        os.mkfifo(fifo)
        self.children.append(subprocess.Popen(["cat", str(fifo)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        waiter = self.dir / "waiter.py"
        waiter.write_text("import time; time.sleep(60)\n")
        self.children.append(subprocess.Popen([sys.executable, str(waiter), payload],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        self.assertEqual(self.ensure()[0], 0)
        self.assertEqual(len(self.starts()), 1)

    def test_unreadable_process_inventory_cannot_license_start(self):
        (self.bin / "ps").write_text("#!/bin/sh\nexit 1\n")
        (self.bin / "ps").chmod(0o755)
        self.assertNotEqual(self.ensure()[0], 0)
        self.assertEqual(self.starts(), [])

    def test_non_socket_path_is_not_proven_absence(self):
        (self.dir / "herdr.sock").write_text("not a socket")
        self.assertNotEqual(self.ensure()[0], 0)
        self.assertEqual(self.starts(), [])

    def test_concurrent_starters_launch_only_once(self):
        script = '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure "$2"'
        for _ in range(2):
            self.children.append(subprocess.Popen(
                ["bash", "-c", script, "fixture", str(ROOT), self.dir.name], env=self.env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        results = [child.communicate(timeout=4) for child in self.children]
        self.transcript.extend(repr(result) for result in results)
        self.assertIn(0, [child.returncode for child in self.children])
        self.assertEqual(len(self.starts()), 1)

    def test_starter_exits_and_closes_inherited_descriptors(self):
        rc, _ = self.ensure(inherited_pipe=True)
        self.assertEqual(rc, 0)
        self.assertEqual(len(self.starts()), 1)
        pid = int((self.dir / "pid").read_text())
        os.kill(pid, 0)
        parent = subprocess.check_output(["ps", "-p", str(pid), "-o", "ppid="], text=True).strip()
        command = subprocess.run(["ps", "-p", parent, "-o", "command="],
                                 capture_output=True, text=True).stdout
        self.transcript.append(f"server={pid} parent={parent} parent_command={command.strip()}")
        self.assertNotIn("fm_backend_herdr_server_ensure", command,
                         "a background Bash copy of the starter must not survive as the server's parent")

    def test_read_only_state_never_starts_unreachable_server(self):
        for mode in ("error", "timeout", "empty", "false"):
            for fn in ("fm_backend_agent_state herdr", "fm_backend_herdr_endpoint_absence_recheck"):
                with self.subTest(status=mode, entry=fn):
                    rc, out = self.invoke(f'. "$1/bin/fm-backend.sh"; fm_backend_source herdr; '
                                          f'{fn} "$2:w1:p2"', status=mode)
                    self.assertEqual(rc, 0)
                    self.assertEqual(out, "unreadable")
                    self.assertEqual(self.starts(), [])

    def test_crew_state_reports_unreadable_without_starting(self):
        (self.dir / "state").mkdir()
        (self.dir / "state" / "fixture.meta").write_text(
            f"backend=herdr\nwindow={self.dir.name}:w1:p2\nkind=scout\nharness=claude\nworktree={ROOT}\n")
        for mode in ("error", "timeout", "empty", "false"):
            with self.subTest(status=mode):
                rc, out = self.invoke('bash "$1/bin/fm-crew-state.sh" fixture', status=mode)
                self.assertEqual(rc, 0)
                self.assertIn("backend unreachable (herdr endpoint state: unreadable)", out)
                self.assertEqual(self.starts(), [], "a crew-state read must never launch a server")


if __name__ == "__main__":
    unittest.main()
