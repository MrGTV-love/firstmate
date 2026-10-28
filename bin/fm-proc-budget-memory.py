#!/usr/bin/env python3
"""Private opt-in memory supervisor for fm-proc-budget.sh.

Usage: python3 fm-proc-budget-memory.py LIMIT_KIB -- COMMAND...
The shell wrapper owns the public interface, process limit, and exit statuses.
Both sampling and cleanup reuse fm-proc-info.py's libproc tree identities.
Descendants remain owned across process-group and session changes.
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


class Reader:
    def __init__(self, root):
        helper = Path(__file__).with_name("fm-proc-info.py")
        self.process = subprocess.Popen(
            [sys.executable, str(helper), "rss-tree", str(root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.first = True
        self.root = root
        # The wrapper has sealed a finite process limit. Bound a malformed
        # response while allowing one identity tuple per possible descendant.
        self.max_bytes = max(1024, resource.getrlimit(resource.RLIMIT_NPROC)[0] * 128)

    def sample(self, known):
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
            rss = data["rss_kib"]
            if type(rss) is not int or rss < 0:
                raise ValueError("unreadable memory")
            return rss
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise SampleError("reader returned an unreadable sample") from error

    def close(self):
        self.process.kill()
        self.process.wait()
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        self.process.stdout.close()


def reason(message):
    print(f"fm-proc-budget: {message}", file=sys.stderr)


def end_tree(proc, root, known):
    """Freeze parents before killing them so detached children cannot orphan.

    Cleanup does not depend on the memory reader: a dead, stalled, or broken
    reader cannot prevent a fresh libproc descendant sweep. Each PID is checked
    against its kernel start timestamp before a signal is sent.
    """
    def signal_member(pid, identity, number):
        try:
            if proc.process_identity(proc.kinfo(pid)) == identity:
                os.kill(pid, number)
        except (LookupError, ProcessLookupError):
            pass

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
    try:
        while True:
            records = proc.tree_snapshot(root, known)
            live = {pid: record for pid, record in records.items()
                    if record[proc.P_STAT] != proc.SZOMB}
            for pid, record in live.items():
                signal_member(pid, proc.process_identity(record), signal.SIGSTOP)
            if all(record[proc.P_STAT] == proc.SSTOP for record in live.values()):
                break
            if time.monotonic() >= deadline:
                break
            time.sleep(0.01)
    finally:
        # The last-known set is still swept if enumeration itself fails.
        # KILL works on stopped processes without a separate CONT signal.
        for pid, identity in reversed(list(known.items())):
            signal_member(pid, identity, signal.SIGKILL)


def run(limit, command):
    reader, child, proc = None, None, None
    known = {}
    caught = 0
    ended = False
    cleanup_error = None
    owner = os.getppid()

    def end_child():
        nonlocal ended, cleanup_error
        if child is not None and not ended:
            ended = True
            try:
                end_tree(proc, child.pid, known)
            except (OSError, LookupError) as error:
                cleanup_error = error
            finally:
                # Popen retains ownership of the unreaped root even when a
                # kernel tree enumeration fails during emergency cleanup.
                try:
                    child.kill()
                except OSError as error:
                    cleanup_error = error

    def interrupted(number, _frame):
        nonlocal caught
        caught = number

    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interrupted)
    try:
        # run_path shares the existing kernel readers without importing a
        # hyphenated module or creating bytecode files in the checkout.
        helper = Path(__file__).with_name("fm-proc-info.py")
        proc = SimpleNamespace(**runpy.run_path(str(helper)))
        reader = Reader(os.getpid())
        reader.sample({})
        reader.close()
        reader = None
        if caught:
            return 128 + caught
        child = subprocess.Popen(command, start_new_session=True)
        reader = Reader(child.pid)
        while True:
            if caught:
                return 128 + caught
            if os.getppid() != owner:
                raise SampleError("supervisor lost its parent")
            rss = reader.sample(known)
            if rss > limit:
                end_child()
                if cleanup_error is not None:
                    raise SampleError(f"tree cleanup failed: {cleanup_error}")
                reason(f"command tree exceeded {limit} KiB memory limit at {rss} KiB; ended")
                return 99
            # Do not reap a finished root while descendants remain: retaining
            # its zombie also prevents reuse of the original PID/group id.
            if rss == 0:
                status = child.poll()
                if status is not None:
                    ended = True
                    return status if status >= 0 else 128 - status
            time.sleep(SAMPLE_SECONDS)
    except (SampleError, OSError) as error:
        if child is None:
            reason(f"cannot start memory reader ({error}); command not started")
        else:
            end_child()
            outcome = "ended" if cleanup_error is None else f"tree cleanup failed: {cleanup_error}"
            reason(f"cannot sample command-tree memory ({error}); {outcome}")
        return 125
    finally:
        if child is not None:
            end_child()
            child.wait()
        if reader is not None:
            reader.close()


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[2] != "--" or not re.fullmatch(r"[1-9][0-9]*", sys.argv[1]):
        reason("invalid private memory supervisor invocation")
        sys.exit(2)
    sys.exit(run(int(sys.argv[1]), sys.argv[3:]))
