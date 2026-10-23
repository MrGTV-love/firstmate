#!/usr/bin/env python3
"""Cold-start a Herdr session only after proving process and socket absence.

Usage: herdr-server-start.py <session> <client-binary>
Read the successful stopped status JSON on stdin. Serialize Firstmate starters
beside that status's canonical socket, then re-read status under the lock.
Unknown status, process inventory, socket identity, or socket errors refuse.
The lock file stays in place so competing starters cannot lock different inodes.
The detached server inherits neither this lock nor any caller pipe descriptor.
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


def socket_path(body, session):
    server = body["server"]
    if server.get("session", session) != session:
        raise ValueError("status names a different session")
    path = server.get("socket")
    if not isinstance(path, str) or not os.path.isabs(path):
        raise ValueError("status did not identify an absolute session socket")
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
        # An unscoped server could depend on inherited session selection;
        # without its environment it cannot prove absence for any session.
        selected = None
        for index, arg in enumerate(options):
            if arg in ("--session", "-s"):
                if index + 1 >= len(options):
                    raise ValueError("Herdr process has an unreadable session option")
                selected = options[index + 1]
            elif arg.startswith("--session="):
                selected = arg.split("=", 1)[1]
        if selected is None or selected == session:
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


def main():
    session, client = sys.argv[1:]
    initial = json.load(sys.stdin)
    if initial["server"].get("running") is not False:
        raise ValueError("startup requires a successful stopped status")
    path = socket_path(initial, session)
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path + ".firstmate-start.lock", "a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        current = status(client, session)
        if socket_path(current, session) != path:
            raise ValueError("the session socket changed during startup")
        running = current["server"].get("running")
        if running is True:
            return
        if running is not False:
            raise ValueError("server status is unknown")
        prove_process_absence(session, client)
        prove_socket_absence(path)
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
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"error: refusing Herdr server startup: {error}", file=sys.stderr)
        sys.exit(1)
