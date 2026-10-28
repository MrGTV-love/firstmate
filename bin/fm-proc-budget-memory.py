#!/usr/bin/env python3
"""Private opt-in memory supervisor for fm-proc-budget.sh.

Usage: python3 fm-proc-budget-memory.py LIMIT_KIB -- COMMAND...
The shell wrapper owns the public interface, process limit, and exit statuses.
Both sampling and cleanup reuse fm-proc-info.py's libproc tree identities.
The command leads its own process group, which the cleanup always covers; a
descendant outside it stays owned once a sample has observed it. The reader
joins that group as a dead-man link: if this supervisor dies, the reader sees
the end of its stdin and ends the group and every member it has seen. A bash
gate holds the command until the reader has answered a first sample, then
runs `exec "$@"` as the plain wrapper does; if this supervisor dies first, the
gate sees the end of its release pipe and exits without running the command.
"""
import json
import os
from pathlib import Path
import re
import resource
import runpy
import select
import signal
import subprocess
import sys
import time
from types import SimpleNamespace

# Reuse the lint reader's allowances, not a command-runtime deadline.
# Ten real full-tree libproc starts: maximum 0.023698 s (private task evidence).
# measured: value=2 date=2026-10-28 host=Mac-Studio.local margin=84
STARTUP_SECONDS = 2
# One hundred real full-tree libproc replies: maximum 0.002800 s.
# measured: value=0.5 date=2026-10-28 host=Mac-Studio.local margin=178
REPLY_SECONDS = 0.5
# The same reply measurements leave headroom within the lint watch's cadence.
# measured: value=1 date=2026-10-28 host=Mac-Studio.local margin=357
SAMPLE_SECONDS = 1


class SampleError(Exception):
    pass


def join_group(group):
    os.setpgid(0, group)
    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(number, signal.SIG_IGN)


class Reader:
    def __init__(self, root, group=None):
        helper = Path(__file__).with_name("fm-proc-info.py")
        self.process = subprocess.Popen(
            [sys.executable, str(helper), "rss-tree", str(root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            preexec_fn=None if group is None else lambda: join_group(group),
        )
        self.first = True
        self.root = root
        # The wrapper has sealed a finite process limit. Bound a malformed
        # response while allowing one identity tuple per possible descendant.
        self.max_bytes = max(1024, resource.getrlimit(resource.RLIMIT_NPROC)[0] * 128)

    def sample(self, known, uncounted):
        deadline = time.monotonic() + (STARTUP_SECONDS if self.first else REPLY_SECONDS)
        self.first = False
        try:
            self.process.stdin.write(b"\n")
            self.process.stdin.flush()
            answer = bytearray()
            while b"\n" not in answer and len(answer) < self.max_bytes:
                left = deadline - time.monotonic()
                if left <= 0 or not select.select([self.process.stdout], [], [], left)[0]:
                    raise SampleError("reader timed out")
                chunk = os.read(self.process.stdout.fileno(), min(65536, self.max_bytes - len(answer)))
                if not chunk:
                    raise SampleError("reader exited")
                answer.extend(chunk)
            data = json.loads(answer)
            members = data["members"]
            if not isinstance(members, list) or any(
                not isinstance(row, list) or len(row) != 3
                or any(type(value) is not int or value < 0 for value in row)
                or row[0] <= 1 for row in members
            ):
                raise ValueError("invalid tree identities")
            root_identity = known.get(self.root)
            known.clear()
            known.update((pid, (seconds, micros)) for pid, seconds, micros in members)
            if root_identity is not None:
                known[self.root] = root_identity
            rows = data["uncounted"]
            if not isinstance(rows, list) or any(
                not isinstance(row, list) or len(row) != 2
                or type(row[0]) is not int or row[0] <= 1 or type(row[1]) is not str
                for row in rows
            ):
                raise ValueError("invalid uncounted members")
            uncounted[:] = rows
            rss = data["rss_kib"]
            if type(rss) is not int or rss < 0:
                raise ValueError("unreadable memory")
            return rss
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise SampleError("reader returned an unreadable sample") from error

    def close(self, cleanup_seconds=0):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        if cleanup_seconds:
            # A failed supervisor sweep must not disarm the independent
            # guardian. EOF invokes its existing TERM/KILL cleanup first.
            try:
                self.process.wait(cleanup_seconds)
            except subprocess.TimeoutExpired:
                pass
        self.process.kill()
        self.process.wait()
        self.process.stdout.close()


def reason(message):
    print(f"fm-proc-budget: {message}", file=sys.stderr)


def uncounted_note(rows):
    if not rows:
        return ""
    names = ", ".join(f"{name} (pid {pid})" for pid, name in rows)
    return f"; {len(rows)} other-user member(s) with unreadable memory not counted: {names}"


def end_tree(proc, root, known, grace=0, skip=()):
    """Freeze parents before killing them so detached children cannot orphan.

    With a grace, members first get TERM and up to that many seconds to exit.
    Cleanup does not depend on the memory reader: a dead, stalled, or broken
    reader cannot prevent a fresh libproc descendant sweep. A live reader, in
    skip, is neither signalled nor awaited, so its dead-man link still covers
    the tree until the caller ends it after this sweep. Each PID is checked
    against its kernel start timestamp before a signal is sent. A refused
    signal does not stop the sweep; the first refusal is raised after it.
    """
    errors = []

    def signal_member(pid, identity, number):
        try:
            if proc.process_identity(proc.kinfo(pid)) == identity:
                os.kill(pid, number)
        except (LookupError, ProcessLookupError):
            pass
        except OSError as error:
            errors.append(error)

    def live():
        return {pid: record for pid, record in proc.tree_snapshot(root, known, skip).items()
                if record[proc.P_STAT] != proc.SZOMB}

    try:
        if grace:
            for pid, record in live().items():
                signal_member(pid, proc.process_identity(record), signal.SIGTERM)
            deadline = time.monotonic() + grace
            while not errors and live() and time.monotonic() < deadline:
                time.sleep(0.01)
        # Stop the root before discovery, not after it can fork another session.
        try:
            root_record = proc.kinfo(root)
            identity = proc.process_identity(root_record)
            if root not in known or known[root] == identity:
                known[root] = identity
                signal_member(root, identity, signal.SIGSTOP)
        except LookupError:
            pass
        # Re-scan after STOP until every observed member is stopped or exiting;
        # this closes the fork race without killing an ancestor prematurely.
        deadline = time.monotonic() + STARTUP_SECONDS
        while True:
            members = live()
            for pid, record in members.items():
                signal_member(pid, proc.process_identity(record), signal.SIGSTOP)
            if errors or all(record[proc.P_STAT] == proc.SSTOP for record in members.values()):
                break
            if time.monotonic() >= deadline:
                break
            time.sleep(0.01)
    finally:
        # The last-known set is still swept if enumeration itself fails.
        # KILL works on stopped processes without a separate CONT signal.
        for pid, identity in reversed(list(known.items())):
            signal_member(pid, identity, signal.SIGKILL)
    if errors:
        raise errors[0]


def run(limit, command):
    reader, child, proc, release = None, None, None, None
    known = {}
    uncounted = []
    caught = 0
    ended = False
    cleanup_error = None

    def end_child(grace=0):
        nonlocal ended, cleanup_error, reader
        if child is not None and not ended:
            ended = True
            try:
                end_tree(proc, child.pid, known, grace, () if reader is None else (reader.process.pid,))
            except (OSError, LookupError) as error:
                cleanup_error = error
            finally:
                # Popen retains ownership of the unreaped root even when a
                # kernel tree enumeration fails during emergency cleanup.
                try:
                    child.kill()
                except OSError as error:
                    cleanup_error = error
                if reader is not None:
                    reader.close(proc.TERM_SECONDS + STARTUP_SECONDS if cleanup_error is not None else 0)
                    reader = None

    def outcome():
        return "ended" if cleanup_error is None else f"tree cleanup failed: {cleanup_error}"

    def interrupted(number, _frame):
        nonlocal caught
        caught = number

    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        if signal.getsignal(number) != signal.SIG_IGN:
            signal.signal(number, interrupted)
    try:
        # run_path shares the existing kernel readers without importing a
        # hyphenated module or creating bytecode files in the checkout.
        helper = Path(__file__).with_name("fm-proc-info.py")
        proc = SimpleNamespace(**runpy.run_path(str(helper)))
        reader = Reader(os.getpid())
        reader.sample({}, [])
        reader.close()
        reader = None
        if caught:
            return 128 + caught
        gate, release = os.pipe()
        try:
            os.set_inheritable(gate, True)
            child = subprocess.Popen(
                ["/bin/bash", "-c", f'read -r _ <&{gate} || exit 125; exec {gate}<&-; exec "$@"',
                 "fm-proc-budget", *command],
                preexec_fn=os.setpgrp, close_fds=False,
            )
        finally:
            os.close(gate)
        reader = Reader(child.pid, child.pid)
        reader.sample(known, uncounted)
        if caught:
            return 128 + caught
        os.write(release, b"\n")
        os.close(release)
        release = None
        while True:
            if caught:
                return 128 + caught
            rss = reader.sample(known, uncounted)
            if rss > limit:
                end_child()
                reason(f"command tree exceeded {limit} KiB memory limit at {rss} KiB; {outcome()}"
                       + uncounted_note(uncounted))
                return 99
            # The root's exit ends the run; leftover descendants get TERM,
            # then KILL, so a lingering daemon never holds the wrapper open.
            try:
                status = child.wait(SAMPLE_SECONDS)
            except subprocess.TimeoutExpired:
                continue
            end_child(proc.TERM_SECONDS)
            if cleanup_error is not None:
                reason(f"command exited; remaining command tree: {outcome()}")
                return 125
            return status if status >= 0 else 128 - status
    except (SampleError, OSError, subprocess.SubprocessError) as error:
        if child is None:
            reason(f"cannot start memory reader ({error}); command not started")
        else:
            end_child()
            ending = "command not started" if release is not None else outcome()
            reason(f"cannot sample command-tree memory ({error}); {ending}" + uncounted_note(uncounted))
        return 125
    finally:
        if child is not None:
            end_child()
            child.wait()
        if reader is not None:
            reader.close()
        if release is not None:
            os.close(release)


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[2] != "--" or not re.fullmatch(r"[1-9][0-9]*", sys.argv[1]):
        reason("invalid private memory supervisor invocation")
        sys.exit(2)
    sys.exit(run(int(sys.argv[1]), sys.argv[3:]))
