#!/usr/bin/env python3
"""Exercise the real adapter with intercepted Herdr launches, never the real CLI."""

import fcntl
import importlib.util
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
from unittest.mock import patch

ROOT = Path(sys.argv.pop(1)).resolve()

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
    failures = root / "post-launch-failures"
    if (root / "pid").exists() and os.environ.get("START_STATUS_FAILS_AFTER_LAUNCH"):
        failed = int(failures.read_text()) if failures.exists() else 0
        if failed < int(os.environ["START_STATUS_FAILS_AFTER_LAUNCH"]):
            failures.write_text(str(failed + 1))
            sys.exit(1)
    server = {"running": (root / "pid").exists(), "session": root.name}
    if not os.environ.get("START_NO_STATUS_SOCKET"):
        server["socket"] = os.environ.get("START_SOCKET", str(root / "herdr.sock"))
    print(json.dumps({"server": server}))
elif cmd == "session":
    entry = {"name": root.name, "running": False}
    if not os.environ.get("START_NO_LIST_SOCKET"):
        entry["socket_path"] = str(root / "herdr.sock")
    print(json.dumps({"sessions": [entry]}))
elif cmd == "server" and args[1:2] == ["--session"]:
    if os.environ.get("START_SERVER_FAILS"):
        sys.exit(1)
    with (root / "servers").open("a") as servers:
        servers.write(str(os.getpid()) + "\n")
    (root / "pid").write_text(str(os.getpid()))
    time.sleep(60)
else:
    print('{"error":{"code":"server_not_running"}}')
    sys.exit(1)
'''


class EnvironmentOwnership(unittest.TestCase):
    """Flattened macOS ps output cannot identify environment entry boundaries."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "herdr_start_guard", ROOT / "bin/backends/herdr-server-start.py")
        self.guard = importlib.util.module_from_spec(spec)
        with patch.object(sys, "dont_write_bytecode", True):
            spec.loader.exec_module(self.guard)
        self.client = "/mock/herdr"
        self.command = self.client + " server"
        self.environment = "OTHER=x PATH=/mock"

    def ps(self, args, **_kwargs):
        outputs = {
            ("ps", "-axww", "-o", "pid=,command="): "424242 " + self.command,
            ("ps", "-axww", "-o", "pid=,comm="): "424242 " + self.client,
            ("ps", "-E", "-ww", "-p", "424242", "-o", "command="):
                self.command + " " + self.environment,
        }
        self.assertIn(tuple(args), outputs, "unexpected external operation")
        return subprocess.CompletedProcess(args, 0, stdout=outputs[tuple(args)] + "\n")

    def prove_absence(self, session):
        with patch.object(self.guard.sys, "platform", "darwin"), \
                patch.object(self.guard.subprocess, "run", self.ps), \
                patch.object(self.guard, "process_alive", return_value=True):
            self.guard.prove_process_absence(session, self.client)

    def test_embedded_session_assignment_cannot_prove_default_absent(self):
        # The actual environment is OTHER="x HERDR_SESSION=other", PATH=/mock.
        # It has no HERDR_SESSION entry: this live server belongs to default.
        self.environment = "OTHER=x HERDR_SESSION=other PATH=/mock"
        with self.assertRaisesRegex(ValueError, "unreadable session environment|still alive"):
            self.prove_absence("default")

    def test_unambiguous_default_server_blocks_default_not_other(self):
        with self.assertRaisesRegex(ValueError, "still alive"):
            self.prove_absence("default")
        self.prove_absence("other")

    def test_real_session_entry_is_indistinguishable_from_embedded_text(self):
        # OTHER=x, HERDR_SESSION=other produces the same flattened text.
        # Without entry boundaries, refusing is safer than picking an owner.
        self.environment = "OTHER=x HERDR_SESSION=other PATH=/mock"
        for session in ("default", "other"):
            with self.subTest(session=session), self.assertRaises(ValueError):
                self.prove_absence(session)


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
            self.fail("server retained a starter descriptor or the call did not return")
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

    def unscoped_server(self, session=None):
        binary = self.dir / "unscoped" / "herdr"
        binary.parent.mkdir()
        binary.write_text(f"#!{sys.executable}\nimport time; time.sleep(60)\n")
        binary.chmod(0o755)
        env = dict(self.env)
        env.pop("HERDR_SESSION", None)
        if session is not None:
            env["HERDR_SESSION"] = session
        self.children.append(subprocess.Popen([str(binary), "server"], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    def test_unscoped_default_server_does_not_block_other_session_start(self):
        self.unscoped_server()
        self.assertEqual(self.ensure()[0], 0)
        self.assertEqual(len(self.starts()), 1)

    def test_undecodable_process_text_does_not_block_other_session_start(self):
        undecodable = os.fsdecode(b"caf\xe9.log")
        quiet = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)",
                                               undecodable], **quiet))
        env = dict(self.env, FIXTURE_TEXT=undecodable)
        env.pop("HERDR_SESSION", None)
        self.children.append(subprocess.Popen([str(self.sleeper("undecodable")), "server"], env=env, **quiet))
        self.assertEqual(self.ensure()[0], 0)
        self.assertEqual(len(self.starts()), 1)

    def test_unscoped_server_inheriting_the_session_blocks_its_start(self):
        self.unscoped_server(self.dir.name)
        self.assertNotEqual(self.ensure()[0], 0)
        self.assertEqual(self.starts(), [])

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
        results = [child.communicate(timeout=8) for child in self.children]
        self.assertEqual([child.returncode for child in self.children], [0, 0], results)
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
        self.assertNotIn("fm_backend_herdr_server_ensure", command,
                         "a background Bash copy of the starter must not survive as the server's parent")

    def state(self, fn, status):
        return self.invoke(f'. "$1/bin/fm-backend.sh"; fm_backend_source herdr; {fn} "$2:w1:p2"',
                           status=status)

    def test_read_only_state_never_starts_unreachable_server(self):
        for mode in ("error", "timeout", "empty", "false"):
            for fn in ("fm_backend_agent_state herdr", "fm_backend_herdr_endpoint_absence_recheck"):
                with self.subTest(status=mode, entry=fn):
                    rc, out = self.state(fn, mode)
                    self.assertEqual(rc, 0)
                    expected = "missing" if (mode, fn) == ("false", "fm_backend_agent_state herdr") else "unreadable"
                    self.assertEqual(out, expected)
                    self.assertEqual(self.starts(), [])

    def test_stopped_server_reads_missing_only_with_proven_absence(self):
        self.assertEqual(self.state("fm_backend_agent_state herdr", "false"), (0, "missing"))
        self.listen()
        self.assertEqual(self.state("fm_backend_agent_state herdr", "false"), (0, "unreadable"),
                         "an accepting socket behind a stopped status is not proven absence")
        self.assertEqual(self.starts(), [])

    def servers(self):
        path = self.dir / "servers"
        return path.read_text().splitlines() if path.exists() else []

    def lock_path(self):
        return str(self.dir / "herdr.sock") + ".firstmate-start.lock"

    def lock_is_free(self):
        with open(self.lock_path(), "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            return True

    def guard(self, **env):
        child = subprocess.Popen([str(ROOT / "bin" / "fm-remote-herdr-guard.sh"), str(self.bin / "herdr"),
                                  self.dir.name],
                                 env=dict(self.env, FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS="5", **env),
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.children.append(child)
        return child

    def wait_for(self, predicate):
        for _ in range(200):
            if predicate():
                return
            time.sleep(.05)
        self.fail("condition never held")

    def test_guard_and_adapter_starts_race_to_one_server(self):
        with open(self.lock_path(), "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            self.guard()
            ensure = subprocess.Popen(
                ["bash", "-c", '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure "$2"',
                 "fixture", str(ROOT), self.dir.name], env=self.env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.children.append(ensure)
            time.sleep(2)
            self.assertEqual(self.servers(), [], "a starter launched while another held the start lock")
        out, err = ensure.communicate(timeout=20)
        self.assertEqual(ensure.returncode, 0, err)
        self.wait_for(lambda: (self.dir / "pid").exists())
        time.sleep(2)
        self.assertEqual(len(self.servers()), 1, "the guard and the adapter both launched a server")

    def test_guard_releases_the_start_lock_once_its_server_runs(self):
        self.guard()
        self.wait_for(lambda: (self.dir / "pid").exists())
        rc, _ = self.ensure()
        self.assertEqual(rc, 0, "a later ensure blocked on the guard's start lock")
        self.assertEqual(len(self.servers()), 1)
        self.wait_for(self.lock_is_free)

    def test_guard_releases_the_start_lock_when_its_server_fails(self):
        out, _ = self.guard(START_SERVER_FAILS="1").communicate(timeout=20)
        self.assertIn("exited before reporting running; releasing the start lock", out)
        self.assertEqual(self.servers(), [])
        self.assertTrue(self.lock_is_free())

    def sleeper(self, name):
        binary = self.dir / name / "herdr"
        binary.parent.mkdir()
        binary.write_text(f"#!{sys.executable}\nimport time; time.sleep(60)\n")
        binary.chmod(0o755)
        return binary

    def test_failed_status_after_launch_keeps_polling(self):
        self.env["START_STATUS_FAILS_AFTER_LAUNCH"] = "2"
        rc, out = self.invoke('. "$1/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure "$2" && echo continued')
        self.assertEqual((rc, out.strip()), (0, "continued"))
        self.assertEqual(len(self.servers()), 1)
        self.assertEqual((self.dir / "post-launch-failures").read_text(), "2")

    def test_launched_server_exit_is_distinct_from_a_refusal(self):
        self.env["START_SERVER_FAILS"] = "1"
        self.assertEqual(self.ensure()[0], 3)
        self.assertEqual(self.servers(), [])
        self.assertTrue(self.lock_is_free())

    def failure(self, extra=""):
        rc, out = self.invoke(f'{extra}. "$1/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure "$2"; '
                              'rc=$?; fm_backend_herdr_server_ensure_failure "$rc" "$2"')
        return out

    def test_start_failures_name_their_cause(self):
        self.listen()
        refused = self.failure()
        self.listener.close()
        self.listener = None
        tools = self.dir / "no-python"
        tools.mkdir()
        for tool in ("jq", "ps", "cat", "head", "sed", "awk", "grep", "tr", "dirname", "basename",
                     "mkdir", "rm", "env", "sh", "date", "printf", "sort", "cut", "wc", "uname", "id"):
            found = shutil.which(tool)
            if found:
                (tools / tool).symlink_to(found)
        no_python = self.failure(f'PATH="{self.bin}:{tools}"; ')
        locked = self.dir / "locked"
        locked.mkdir()
        locked.chmod(0o500)
        self.env["START_SOCKET"] = str(locked / "herdr.sock")
        try:
            launch = self.failure()
        finally:
            locked.chmod(0o700)
        session = self.dir.name
        self.assertEqual(refused, f"refused to start the herdr server for session {session} "
                                  "to protect a live or unknown server")
        self.assertEqual(no_python, f"the server start helper failed (exit 127) for session {session}")
        self.assertEqual(launch, f"the server start helper failed (exit 4) for session {session}")
        self.assertEqual(self.servers(), [])

    def test_unscoped_server_gone_before_its_environment_read_does_not_block(self):
        binary = self.sleeper("vanishing")
        pid = subprocess.run(["sh", "-c", f'"{binary}" server >/dev/null 2>&1 & echo $!'], env=self.env,
                             stdout=subprocess.PIPE, text=True, check=True).stdout.strip()
        (self.dir / "vanishing-pid").write_text(pid)
        self.wait_for(lambda: "vanishing/herdr server" in subprocess.run(
            ["ps", "-p", pid, "-o", "command="], stdout=subprocess.PIPE, text=True).stdout)
        (self.bin / "ps").write_text(f"""#!/bin/sh
out=$(/bin/ps "$@") || exit $?
case "$*" in
  *comm=*)
    pid=$(cat "{self.dir}/vanishing-pid")
    kill "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do sleep 0.05; done ;;
esac
printf '%s\n' "$out"
""")
        (self.bin / "ps").chmod(0o755)
        self.assertEqual(self.ensure()[0], 0)
        self.assertEqual(len(self.servers()), 1)

    def test_quoted_client_argv_does_not_block_cold_start(self):
        words = ["pane", "send-text", "w1:p2", "don't", "stop", "--session", self.dir.name]
        quiet = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(subprocess.Popen(["herdr", "-c", "import time; time.sleep(60)", *words],
                                              executable=sys.executable, **quiet))
        self.children.append(subprocess.Popen([str(self.sleeper("client")), *words], **quiet))
        self.assertEqual(self.ensure()[0], 0)
        self.assertEqual(len(self.servers()), 1)

    def test_server_with_unreadable_session_refuses(self):
        self.children.append(subprocess.Popen([str(self.sleeper("broken")), "server", "--session"],
                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        self.assertNotEqual(self.ensure()[0], 0)
        self.assertEqual(self.starts(), [])

    def test_session_list_supplies_a_missing_status_socket(self):
        self.env["START_NO_STATUS_SOCKET"] = "1"
        self.assertEqual(self.state("fm_backend_agent_state herdr", "false"), (0, "missing"))
        self.listen()
        self.assertEqual(self.state("fm_backend_agent_state herdr", "false"), (0, "unreadable"),
                         "the listed socket was not the one probed for absence")
        self.listener.close()
        self.listener = None
        self.assertEqual(self.ensure()[0], 0)
        self.assertEqual(len(self.servers()), 1)

    def test_no_socket_from_status_or_session_list_refuses(self):
        self.env["START_NO_STATUS_SOCKET"] = "1"
        self.env["START_NO_LIST_SOCKET"] = "1"
        self.assertEqual(self.state("fm_backend_agent_state herdr", "false"), (0, "unreadable"))
        self.assertNotEqual(self.ensure()[0], 0)
        self.assertEqual(self.starts(), [])

    def test_crew_state_reads_without_starting(self):
        (self.dir / "state").mkdir()
        (self.dir / "state" / "fixture.meta").write_text(
            f"backend=herdr\nwindow={self.dir.name}:w1:p2\nkind=scout\nharness=claude\nworktree={ROOT}\n")
        for mode in ("error", "timeout", "empty", "false"):
            with self.subTest(status=mode):
                rc, out = self.invoke('bash "$1/bin/fm-crew-state.sh" fixture', status=mode)
                self.assertEqual(rc, 0)
                if mode == "false":
                    self.assertIn(f"backend target gone: {self.dir.name}:w1:p2", out)
                else:
                    self.assertIn("backend unreachable (herdr endpoint state: unreadable)", out)
                self.assertEqual(self.starts(), [], "a crew-state read must never launch a server")


if __name__ == "__main__":
    unittest.main()
