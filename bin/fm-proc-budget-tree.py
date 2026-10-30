#!/usr/bin/env python3
"""Private own-tree process supervisor for fm-proc-budget.sh --own-procs.

Usage: python3 fm-proc-budget-tree.py LIMIT -- COMMAND...
The shell wrapper owns the public interface, the kernel process limit, and the
exit statuses; fm-proc-budget.sh's header owns the contract.
The command leads its own process group. The tree is that group plus every
descendant of the command in any group or session. A member that has been
seen stays owned by its kernel start identity after it is orphaned, so a
recycled PID is never signalled. A process that leaves the group (setsid) and
is orphaned before any sample saw it is not found.
The count is the number of tree members, zombies included because an
unreaped zombie still holds a process slot. Threads are not counted. Nothing
outside the tree is counted, so neighbours cannot spend this tree's budget.
A sample that cannot be read means "unknown, try again next sample", never a
verdict: only the first one, taken before the command starts, refuses the
launch, because a tree that can never be watched must not run as if it were.
The table comes from /proc on Linux and from libproc through fm-proc-info.py
on Darwin; neither needs ps, which a confined worker's sandbox may refuse.
The dead-man link is fm-proc-budget-memory.py's: its gate holds the command
until a Reader has joined the command's group, and that Reader reads a pipe
only this supervisor writes. It is never sampled here and is neither counted
nor ended by this supervisor; a stop of the whole group resumes it at once. If this supervisor dies, the Reader sees the
end of its stdin and ends the group: on Darwin it sends TERM, then KILL after
at most one second, to the group and its descendants; on Linux, where its
libproc read cannot run, it KILLs the group at once.
"""
import os
from pathlib import Path
import re
import runpy
import signal
import struct
import subprocess
import sys
import time
from types import SimpleNamespace

# Cadence between samples, not a bound on any work: the tree is counted this
# often and nothing is decided by waiting. A runaway forks a few hundred
# processes in this interval, far inside the kernel limit this mode keeps.
SAMPLE_INTERVAL = 0.2
# The supervisor spends at most one tenth of a core on sampling: the wait
# between samples grows to ten times the last scan, so a slow host with a big
# process table is sampled less often, never starved of CPU by its own guard.
SCAN_DUTY = 10
# Cadence of the cleanup rescans.
RESCAN_INTERVAL = 0.01
# Grace between TERM and KILL for what a finished command leaves behind.
# Harm: a leftover that ignores TERM would hold the wrapper, and the caller
# waiting on it, open. Observable: the leftover is still alive after TERM.
# Expiry: KILL for that leftover only; the command has already finished.
# measured: value=1 date=2026-10-29 host=Mac-Studio.local margin=277 (forty bash leftovers with a TERM trap exited in at most 0.0036 s at load 19; same grace as the memory supervisor's TERM_SECONDS)
LEFTOVER_GRACE = 1


class SampleError(Exception):
    pass


class Table:
    """The user's process table as {pid: (ppid, pgid, identity, zombie)}."""

    def __init__(self):
        self.proc = None
        if sys.platform == "darwin":
            helper = Path(__file__).with_name("fm-proc-info.py")
            self.proc = SimpleNamespace(**runpy.run_path(str(helper)))

    def read(self):
        rows = {}
        try:
            if self.proc is None:
                for name in os.listdir("/proc"):
                    if not name.isdigit():
                        continue
                    row = self.linux_row(name)
                    if row is not None:
                        rows[int(name)] = row
            else:
                proc = self.proc
                for record in proc.kinfos():
                    pid = struct.unpack_from("i", record, proc.P_PID)[0]
                    rows[pid] = (struct.unpack_from("i", record, proc.E_PPID)[0],
                                 struct.unpack_from("i", record, proc.E_PGID)[0],
                                 proc.process_identity(record), record[proc.P_STAT] == proc.SZOMB)
        except (OSError, LookupError, struct.error) as error:
            raise SampleError(f"cannot read the process table ({error})") from error
        if not rows:
            raise SampleError("the process table is empty")
        return rows

    @staticmethod
    def parse_stat(data):
        """(ppid, pgid, start identity, zombie) from a Linux /proc/PID/stat, or None."""
        # The command name may hold spaces and parentheses; the last ")" ends it.
        rest = data.rpartition(b")")[2].split()
        try:
            return int(rest[1]), int(rest[2]), int(rest[19]), rest[0] in (b"Z", b"X")
        except (IndexError, ValueError):
            return None  # a half-read row of a process that is exiting

    @classmethod
    def linux_row(cls, name):
        try:
            with open(f"/proc/{name}/stat", "rb") as handle:
                return cls.parse_stat(handle.read())
        except OSError:
            return None  # exited between the listing and the read

    def identity(self, pid):
        """The kernel start identity of a live PID, or LookupError."""
        if self.proc is None:
            row = self.linux_row(str(pid))
            if row is None:
                raise LookupError(pid)
            return row[2]
        return self.proc.process_identity(self.proc.kinfo(pid))


def members_of(rows, root, known, skip):
    """Select the tree: root, its group, and descendants; keep orphans by identity."""
    rows = {pid: row for pid, row in rows.items() if pid not in skip}
    children = {}
    for pid, (ppid, _, _, _) in rows.items():
        children.setdefault(ppid, []).append(pid)
    group_owned = root not in rows or root not in known or rows[root][2] == known[root]
    queue = [pid for pid, (_, pgid, identity, _) in rows.items()
             if known.get(pid) == identity
             or pid == root and (root not in known or known[root] == identity)
             or group_owned and pgid == root]
    selected = {}
    while queue:
        pid = queue.pop()
        if pid in selected:
            continue
        selected[pid] = rows[pid]
        queue.extend(children.get(pid, []))
    original_root = known.get(root)
    known.clear()
    known.update((pid, row[2]) for pid, row in selected.items())
    if original_root is not None:
        known[root] = original_root
    return selected


def reason(message):
    print(f"fm-proc-budget: {message}", file=sys.stderr)


def run(limit, command):
    table = Table()
    memory = SimpleNamespace(**runpy.run_path(str(Path(__file__).with_name("fm-proc-budget-memory.py"))))
    skip = {os.getpid()}
    guardian = None
    known = {}
    caught = 0
    unreadable = 0
    errors = []

    def interrupted(number, _frame):
        nonlocal caught
        caught = number

    def snapshot(root):
        return members_of(table.read(), root, known, skip)

    def signal_member(pid, identity, number):
        try:
            if table.identity(pid) == identity:
                os.kill(pid, number)
        except (LookupError, ProcessLookupError):
            pass
        except OSError as error:
            errors.append(error)

    def live(root):
        try:
            return {pid: row[2] for pid, row in snapshot(root).items() if not row[3]}
        except SampleError as error:
            # An unreadable table ends the sweep as a reported failure; the
            # last-known members still get one identity-checked KILL.
            errors.append(error)
            return {}

    def end_tree(root):
        """Freeze, then KILL until no live member is left.

        Freezing parents first keeps a forking runaway from outrunning the
        sweep. While the command is unreaped its PID, and so its group, cannot
        be reused, so the whole group is stopped in one signal first: a
        member-by-member freeze from a table read lags a fork chain that is
        faster than the read and stops each leaf only after it has forked.
        The Reader shares that group and is resumed at once. The sweep ends
        when the tree is empty; a member the kernel is slow to reap is waited
        for, because hang protection belongs to the caller's progress runner
        and a still-living member is not a verdict.
        """
        if child.returncode is None:
            try:
                os.killpg(root, signal.SIGSTOP)
            except ProcessLookupError:
                pass
            except OSError as error:
                errors.append(error)
            os.kill(guardian.process.pid, signal.SIGCONT)
        frozen = set()
        while True:
            fresh = {pid: identity for pid, identity in live(root).items() if pid not in frozen}
            if not fresh:
                break
            for pid, identity in fresh.items():
                signal_member(pid, identity, signal.SIGSTOP)
            frozen.update(fresh)
        while True:
            members = live(root)
            if not members or errors:
                break
            for pid, identity in members.items():
                signal_member(pid, identity, signal.SIGKILL)
            time.sleep(RESCAN_INTERVAL)
        for pid, identity in list(known.items()):
            signal_member(pid, identity, signal.SIGKILL)

    def end_leftovers(root):
        """TERM what a finished command left behind, then KILL what ignores it."""
        for pid, identity in live(root).items():
            signal_member(pid, identity, signal.SIGTERM)
        deadline = time.monotonic() + LEFTOVER_GRACE
        while not errors and live(root) and time.monotonic() < deadline:
            time.sleep(RESCAN_INTERVAL)
        end_tree(root)

    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        if signal.getsignal(number) != signal.SIG_IGN:
            signal.signal(number, interrupted)
    try:
        table.read()
    except SampleError as error:
        reason(f"{error}; command not started")
        return 125
    # bash replaces itself with the command, so a command that cannot start
    # gets the status and message exec gives it without the option (126, 127,
    # a script with no shebang run under the shell), and no extra process stays.
    child = None
    try:
        child, release = memory.start_gated(command)
        try:
            guardian = memory.Reader(child.pid, child.pid)
            skip.add(guardian.process.pid)
            if not caught:
                os.write(release, b"\n")
        finally:
            os.close(release)
    except (OSError, subprocess.SubprocessError) as error:
        if guardian is not None:
            guardian.close()
        if child is not None:
            child.wait()
        reason(f"cannot start the command under its dead-man guardian ({error}); command not started")
        return 125
    try:
        while True:
            if caught:
                end_tree(child.pid)
                return 128 + caught
            scan_started = time.monotonic()
            try:
                count = len(snapshot(child.pid))
            except SampleError:
                unreadable += 1
            else:
                if count > limit:
                    end_tree(child.pid)
                    reason(f"command tree held {count} processes, over the own-tree limit of {limit}; "
                           + ("ended" if not errors else f"tree cleanup failed: {errors[0]}"))
                    return 98
            try:
                status = child.wait(max(SAMPLE_INTERVAL, SCAN_DUTY * (time.monotonic() - scan_started)))
            except subprocess.TimeoutExpired:
                continue
            end_leftovers(child.pid)
            if errors:
                reason(f"command exited; remaining command tree: tree cleanup failed: {errors[0]}")
                return 125
            if unreadable:
                reason(f"{unreadable} own-tree sample(s) were unreadable and skipped; "
                       "the kernel process limit stayed in force")
            return status if status >= 0 else 128 - status
    finally:
        if child.poll() is None:
            end_tree(child.pid)
            child.wait()
        guardian.close(memory.STARTUP_SECONDS + LEFTOVER_GRACE if errors else 0)


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[2] != "--" or not re.fullmatch(r"[1-9][0-9]*", sys.argv[1]):
        reason("invalid private own-tree supervisor invocation")
        sys.exit(2)
    sys.exit(run(int(sys.argv[1]), sys.argv[3:]))
