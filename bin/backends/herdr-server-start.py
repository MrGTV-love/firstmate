#!/usr/bin/env python3
"""Prove Herdr session process and socket absence, and cold-start only after it.

Usage: herdr-server-start.py [--prove-absent] <session> <client-binary>
       herdr-server-start.py --hold-for-exec <session> <client-binary> <pid>
Read the successful stopped status JSON on stdin. --prove-absent only proves
absence and starts nothing. Otherwise wait for the start lock beside that
status's canonical socket, then re-read status under the lock; a server that a
competing starter brought up is reused, never launched twice.
--hold-for-exec serves a starter that execs the server itself as <pid>: under
the lock it prints `running` for a server already up, or proves absence and
prints `go`, then keeps holding the lock in this process until that session
reports running or <pid> is gone.
The socket comes from status `.server.socket`, else from `session list --json`
`.socket_path`, the adapter's own socket lookup.
Unknown status, process inventory, socket identity, or socket errors refuse.
The lock file stays in place so competing starters cannot lock different inodes.
The server inherits neither this lock nor any caller pipe descriptor.
"""

import errno
import fcntl
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import time

# Retain server_ensure's existing readiness cap; five intercepted cold starts
# took at most 1.215s on this host, not a live-Herdr startup measurement.
# measured: value=10 date=2026-10-23 host=Mac-Studio.local margin=3
STARTUP_SECONDS = 10
# Retain the poll cadence; 15 real local socket probes took at most 0.017ms.
# measured: value=0.5 date=2026-10-23 host=Mac-Studio.local margin=3
POLL_SECONDS = 0.5


def status(client, session):
    result = subprocess.run([client, "status", "--json", "--session", session],
                            check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, timeout=STARTUP_SECONDS,
                            env=dict(os.environ, HERDR_SESSION=session))
    return json.loads(result.stdout)


def socket_path(body, session, client):
    server = body["server"]
    if server.get("session", session) != session:
        raise ValueError("status names a different session")
    path = server.get("socket")
    if not isinstance(path, str) or not os.path.isabs(path):
        listed = subprocess.run([client, "session", "list", "--json", "--session", session],
                                check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, timeout=STARTUP_SECONDS,
                                env=dict(os.environ, HERDR_SESSION=session))
        path = next((entry.get("socket_path") for entry in json.loads(listed.stdout).get("sessions", [])
                     if isinstance(entry, dict) and entry.get("name") == session), None)
    if not isinstance(path, str) or not os.path.isabs(path):
        raise ValueError("neither status nor session list identified an absolute session socket")
    return os.path.realpath(path)


def process_table(column):
    table = subprocess.run(["ps", "-axww", "-o", f"pid=,{column}="], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, timeout=STARTUP_SECONDS).stdout
    if not table.strip():
        raise ValueError("empty process inventory")
    rows = {}
    for line in table.splitlines():
        pid, value = line.strip().split(None, 1)
        if not pid.isdecimal():
            raise ValueError("unreadable process inventory")
        rows[pid] = value
    return rows


def environment_session(pid, command):
    """Session an unscoped server inherited, or None when it cannot be read."""
    if sys.platform.startswith("linux"):
        try:
            entries = Path(f"/proc/{pid}/environ").read_bytes().decode(errors="replace").split("\0")
        except OSError:
            return None
    else:
        shown = subprocess.run(["ps", "-E", "-ww", "-p", pid, "-o", "command="],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True, timeout=STARTUP_SECONDS).stdout.strip()
        # ps appends the environment to the unquoted argv; macOS shows nothing
        # after argv for a process whose environment it withholds.
        if not shown.startswith(command) or not shown[len(command):].strip():
            return None
        entries = shown[len(command):].split()
    values = {entry.split("=", 1)[1] for entry in entries if entry.startswith("HERDR_SESSION=")}
    if len(values) > 1:
        return None
    return (values.pop() if values else "") or "default"


def prove_process_absence(session, client):
    if any(char.isspace() for char in session):
        raise ValueError("cannot prove process absence for a whitespace-containing session")
    # comm is kernel executable identity, not an agent's potentially enormous
    # argv containing instructions that happen to mention `herdr server`.
    names = process_table("comm")
    for pid, command in process_table("command").items():
        name = Path(names.get(pid, "")).name.lower()
        interpreter = name in ("bash", "sh", "zsh", "dash", "ksh") or name.startswith(("python", "pypy"))
        if name and name != "herdr" and name != Path(client).name.lower() and not interpreter:
            continue
        # ps flattens argv without quoting. For interpreters, only the actual
        # script can identify Herdr, never a later argument holding agent text.
        if interpreter:
            prefix = names[pid] + " "
            script = command[len(prefix):] if command.startswith(prefix) else command.split(None, 1)[-1]
            words = script.split()
            executable = next((index for index, arg in enumerate(words)
                               if Path(arg).name == "herdr"), None)
            if executable is None:
                continue
            if executable and not os.path.isfile(" ".join(words[:executable + 1])):
                continue
            options = words[executable + 1:]
        else:
            try:
                args = shlex.split(command)
            except ValueError:
                raise ValueError(f"unreadable Herdr process command for pid {pid}") from None
            executable = next((index for index, arg in enumerate(args)
                               if Path(arg).name == "herdr" or arg == client), None)
            if executable is None:
                continue
            options = args[executable + 1:]
        subcommand = 0
        while subcommand < len(options):
            arg = options[subcommand]
            if arg in ("--session", "-s"):
                subcommand += 2
            elif arg.startswith("--session="):
                subcommand += 1
            else:
                break
        if subcommand >= len(options) or options[subcommand] != "server":
            if subcommand < len(options) and options[subcommand].startswith("-") and "server" in options:
                raise ValueError(f"Herdr process {pid} has unrecognized server options")
            continue
        # An unscoped server serves its inherited HERDR_SESSION, else default;
        # an unreadable environment leaves its owner unknown.
        selected = None
        for index, arg in enumerate(options):
            if arg in ("--session", "-s"):
                if index + 1 >= len(options):
                    raise ValueError("Herdr process has an unreadable session option")
                selected = options[index + 1]
            elif arg.startswith("--session="):
                selected = arg.split("=", 1)[1]
        if selected is None:
            selected = environment_session(pid, command)
            if selected is None:
                raise ValueError(f"Herdr server process {pid} has an unreadable session environment")
        if selected == session:
            raise ValueError(f"Herdr server process {pid} is still alive")


def prove_socket_absence(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(POLL_SECONDS)
        try:
            probe.connect(path)
        except OSError as error:
            if error.errno in (errno.ENOENT, errno.ECONNREFUSED):
                return
            raise ValueError(f"socket absence is unknown: {error}") from error
    raise ValueError("the session socket still accepts connections")


def notice_after(started, noticed, message):
    if not noticed and time.monotonic() - started >= STARTUP_SECONDS:
        print(f"notice: {message}", file=sys.stderr, flush=True)
        return True
    return noticed


def process_alive(pid):
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    state = subprocess.run(["ps", "-o", "stat=", "-p", pid], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, timeout=STARTUP_SECONDS).stdout.strip()
    return bool(state) and not state.startswith("Z")


def lock_with_notice(session, lock):
    started, noticed = time.monotonic(), False
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            noticed = notice_after(started, noticed, f"still waiting for the Herdr start lock of session {session}")
            time.sleep(POLL_SECONDS)


def main(mode, session, client, pid=None):
    if (mode == "--hold-for-exec") != (pid is not None) or (pid is not None and not pid.isdecimal()):
        raise TypeError("invalid arguments")
    initial = json.load(sys.stdin)
    if initial["server"].get("running") is not False:
        raise ValueError("absence requires a successful stopped status")
    path = socket_path(initial, session, client)
    if mode == "--prove-absent":
        prove_process_absence(session, client)
        prove_socket_absence(path)
        return
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path + ".firstmate-start.lock", "a", encoding="utf-8") as lock:
        if mode == "--hold-for-exec":
            lock_with_notice(session, lock)
        else:
            fcntl.flock(lock, fcntl.LOCK_EX)
        current = status(client, session)
        if socket_path(current, session, client) != path:
            raise ValueError("the session socket changed during startup")
        running = current["server"].get("running")
        if running is True:
            if mode == "--hold-for-exec":
                print("running", flush=True)
            return
        if running is not False:
            raise ValueError("server status is unknown")
        prove_process_absence(session, client)
        prove_socket_absence(path)
        if mode == "--hold-for-exec":
            print("go", flush=True)
            with open(os.devnull, "wb") as null:
                os.dup2(null.fileno(), sys.stdout.fileno())
            started, noticed = time.monotonic(), False
            while True:
                if not process_alive(pid):
                    print(f"error: the Herdr server for session {session} exited before reporting running; "
                          "releasing the start lock", file=sys.stderr, flush=True)
                    sys.exit(1)
                try:
                    if status(client, session)["server"].get("running") is True:
                        return
                except (ValueError, KeyError, TypeError, subprocess.SubprocessError):
                    pass
                noticed = notice_after(started, noticed,
                                       f"the Herdr server for session {session} has not reported running yet; "
                                       "still holding the start lock")
                time.sleep(POLL_SECONDS)
        with open(os.devnull, "r+b") as null:
            subprocess.Popen([client, "server", "--session", session],
                             stdin=null, stdout=null, stderr=null, close_fds=True,
                             start_new_session=True, env=dict(os.environ, HERDR_SESSION=session))
        deadline = time.monotonic() + STARTUP_SECONDS
        while time.monotonic() < deadline:
            if status(client, session)["server"].get("running") is True:
                return
            time.sleep(POLL_SECONDS)
        raise ValueError("started server did not report running within 10s")


if __name__ == "__main__":
    mode = sys.argv[1] if sys.argv[1:2] in (["--prove-absent"], ["--hold-for-exec"]) else None
    try:
        main(mode, *sys.argv[1 + (mode is not None):])
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        action = "Herdr session absence is unproven" if mode == "--prove-absent" else "refusing Herdr server startup"
        print(f"error: {action}: {error}", file=sys.stderr)
        sys.exit(1)
