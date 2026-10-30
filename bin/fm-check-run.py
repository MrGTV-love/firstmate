#!/usr/bin/env python3
"""Run a watcher check behind the shared process-budget dead-man link.

Usage: fm-check-run.py OWNER_FD -- COMMAND...
OWNER_FD reads a pipe whose only writer is the watcher. EOF means the owner
is gone, not that the check is slow. The shared start_gated/Reader pair holds
the command until its independent guardian is in place, and cleans the tree
on owner loss, launcher death, or normal completion. No wall-clock limit or
polling CPU is introduced: progress-check must observe work, not a supervisor.
The watcher owns the inactivity policy and closes all writer copies before
launch; this private bridge owns only lifetime and result propagation.
The guardian's TERM-then-KILL sweep reads the tree through libproc, so on any
other host the launcher first sends the tree TERM itself, reading /proc through
fm-proc-budget-tree.py's table, and KILLs what ignores it after that module's
LEFTOVER_GRACE; the guardian's KILL then covers the group.
"""
import os
from pathlib import Path
import runpy
import select
import signal
import sys
import time
from types import SimpleNamespace


def end_tree_portable(root, skip):
    """TERM the check tree, then KILL what ignores it, without libproc."""
    tree = SimpleNamespace(**runpy.run_path(str(Path(__file__).with_name("fm-proc-budget-tree.py"))))
    table, known = tree.Table(), {}

    def live():
        try:
            return {pid: row[2] for pid, row in tree.members_of(table.read(), root, known, skip).items()
                    if not row[3]}
        except tree.SampleError:
            return {}

    def send(members, number):
        for pid, identity in members.items():
            try:
                if table.identity(pid) == identity:
                    os.kill(pid, number)
            except (LookupError, OSError):
                pass

    send(live(), signal.SIGTERM)
    deadline = time.monotonic() + tree.LEFTOVER_GRACE
    while live() and time.monotonic() < deadline:
        time.sleep(tree.RESCAN_INTERVAL)
    send(live(), signal.SIGKILL)


def run(owner, command):
    shared = SimpleNamespace(**runpy.run_path(str(Path(__file__).with_name("fm-proc-budget-memory.py"))))
    os.set_inheritable(owner, False)
    wake_read, wake_write = os.pipe()
    os.set_blocking(wake_write, False)
    signal.set_wakeup_fd(wake_write)
    caught = []

    def changed(number, _frame):
        if number != signal.SIGCHLD:
            caught.append(number)

    for number in (signal.SIGCHLD, signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(number, changed)
    child = guardian = release = None
    try:
        child, release = shared.start_gated(command)
        guardian = shared.Reader(child.pid, child.pid)
        # Reader construction has joined the held command's group before Popen
        # returns. Its EOF cleanup is armed even if this launcher dies now.
        if not caught and not select.select([owner], [], [], 0)[0]:
            os.write(release, b"\n")
        os.close(release)
        release = None
        while child.poll() is None and not caught:
            ready, _, _ = select.select([owner, wake_read], [], [])
            if owner in ready and not os.read(owner, 1):
                break
            if wake_read in ready:
                os.read(wake_read, 4096)
            if guardian.process.poll() is not None:
                raise RuntimeError("check guardian exited before its command")
        status = child.poll()
    finally:
        if release is not None:
            os.close(release)
        if guardian is not None:
            if child.poll() is None and guardian.process.poll() is not None:
                # A failed guardian cannot be allowed to leave live work
                # without its independent cleanup link.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if sys.platform != "darwin":
                end_tree_portable(child.pid, {os.getpid(), guardian.process.pid})
            # EOF invokes the shared guardian's cleanup. Await that actual
            # completion, never kill the guardian on a guessed read deadline.
            guardian.process.stdin.close()
            guardian.process.wait()
            guardian.process.stdout.close()
        if child is not None:
            child.wait()
        signal.set_wakeup_fd(-1)
        os.close(wake_read)
        os.close(wake_write)
        os.close(owner)
    if caught:
        return 128 + caught[0]
    if status is None:
        return 125  # owner loss is not a completed check result
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    try:
        if len(sys.argv) < 4 or sys.argv[2] != "--":
            raise ValueError("expected OWNER_FD -- COMMAND...")
        sys.exit(run(int(sys.argv[1]), sys.argv[3:]))
    except (OSError, ValueError, RuntimeError, AttributeError) as error:
        print(f"fm-check-run: {error}", file=sys.stderr)
        sys.exit(125)
