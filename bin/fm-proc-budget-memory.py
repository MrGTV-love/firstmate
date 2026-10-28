#!/usr/bin/env python3
"""Private opt-in memory supervisor for fm-proc-budget.sh.

Usage: python3 fm-proc-budget-memory.py LIMIT_KIB -- COMMAND...
The shell wrapper owns the public interface, process limit, and exit statuses.
The persistent libproc reader and process-group cleanup follow the lint watch;
this path never falls back to ps or tolerates an unreadable live sample.
"""
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time

# Reuse the lint reader's allowances, not a command-runtime deadline.
# Ten real libproc starts: maximum 0.017522 s (private task evidence).
# measured: value=2 date=2026-10-28 host=Mac-Studio.local margin=114
STARTUP_SECONDS = 2
# One hundred real libproc replies: maximum 0.000430 s.
# measured: value=0.5 date=2026-10-28 host=Mac-Studio.local margin=1162
REPLY_SECONDS = 0.5
# The same reply measurements leave headroom within the lint watch's cadence.
# measured: value=1 date=2026-10-28 host=Mac-Studio.local margin=2325
SAMPLE_SECONDS = 1


class SampleError(Exception):
    pass


class Reader:
    def __init__(self, group):
        helper = Path(__file__).with_name("fm-proc-info.py")
        self.process = subprocess.Popen(
            [sys.executable, str(helper), "rss-tree", str(group)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.first = True

    def sample(self):
        deadline = time.monotonic() + (STARTUP_SECONDS if self.first else REPLY_SECONDS)
        self.first = False
        try:
            self.process.stdin.write(b"\n")
            self.process.stdin.flush()
            answer = b""
            while b"\n" not in answer and len(answer) < 128:
                left = deadline - time.monotonic()
                if left <= 0 or not select.select([self.process.stdout], [], [], left)[0]:
                    raise SampleError("reader timed out")
                chunk = os.read(self.process.stdout.fileno(), 128)
                if not chunk:
                    raise SampleError("reader exited")
                answer += chunk
        except (OSError, ValueError) as error:
            raise SampleError("reader failed") from error
        match = re.fullmatch(rb"([0-9]+) ([0-9]+)\n", answer)
        if not match:
            raise SampleError("reader returned an unreadable sample")
        return max(int(match[1]), int(match[2]))

    def close(self):
        self.process.kill()
        self.process.wait()
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass  # A failed reader may have closed its input before cleanup.
        self.process.stdout.close()


def reason(message):
    print(f"fm-proc-budget: {message}", file=sys.stderr)


def end_group(group):
    try:
        os.killpg(group, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run(limit, command):
    reader, child = None, None
    caught = 0
    ended = False
    owner = os.getppid()

    def end_child():
        nonlocal ended
        if child is not None and not ended:
            end_group(child.pid)
            ended = True

    def interrupted(number, _frame):
        nonlocal caught
        caught = number
        end_child()

    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interrupted)
    try:
        # Verify the real reader before any command-side effects. In particular,
        # non-Darwin hosts fail here instead of launching an unwatched command.
        reader = Reader(os.getpgrp())
        reader.sample()
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
            rss = reader.sample()
            if rss > limit:
                end_child()
                reason(f"command tree exceeded {limit} KiB memory limit at {rss} KiB; ended")
                return 99
            status = child.poll()
            # Keep watching orphaned children after their original root exits.
            if status is not None and rss == 0:
                ended = True
                return status if status >= 0 else 128 - status
            time.sleep(SAMPLE_SECONDS)
    except (SampleError, OSError) as error:
        if child is None:
            reason(f"cannot start memory reader ({error}); command not started")
        else:
            end_child()
            reason(f"cannot sample command-tree memory ({error}); ended")
        return 125
    finally:
        if child is not None:
            # Also cover unexpected exceptions and signals during a read.
            end_child()
            child.wait()
        if reader is not None:
            reader.close()


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[2] != "--" or not re.fullmatch(r"[1-9][0-9]*", sys.argv[1]):
        reason("invalid private memory supervisor invocation")
        sys.exit(2)
    sys.exit(run(int(sys.argv[1]), sys.argv[3:]))
