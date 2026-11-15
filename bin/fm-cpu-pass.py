#!/usr/bin/env python3
"""
fm-cpu-pass.py - host-wide CPU pass pool for CPU-heavy test bursts.

Usage:
  fm-cpu-pass.sh run [--passes K] [--label TEXT] [--log-fd N] [--wait-file PATH] -- COMMAND [ARGS...]
  fm-cpu-pass.sh pipeline-start [--priority CLASS] -- COMMAND [ARGS...]
  fm-cpu-pass.sh status [--json]
  fm-cpu-pass.sh size

`run` waits for K passes from the pool, runs COMMAND while holding them, and
exits with COMMAND's status (128+n when a signal n ended it).
`status` reports how many passes are held and by whom; `size` prints the pool
size so a caller can size its own worker count (for example pytest -n).

The pool bounds CPU-heavy bursts (test suites, their workers and lint roots), not agents
or sessions: interactive work never asks for a pass and is never queued.
docs/cpu-pass-pool.md owns the cross-repository protocol this command
implements: pool directory and size, slot and turnstile locks, the
FM_CPU_PASS_HELD nested marker, and degrading without a pass.
This header owns the command's own behavior below.

Waiting:
  - A waiter polls with backoff (50 ms growing to 500 ms) and never times out:
    a pass request queues, it does not fail. Time spent waiting is outside
    COMMAND, so a bound the caller places inside COMMAND (for example a
    per-script timeout) does not start until the passes are held.
  - After 2 s of waiting it writes one notice, then one every 60 s, to the log
    fd, naming the pool size and the current holders; on acquisition after a
    notice it writes the wait time.
  - --wait-file PATH writes the milliseconds spent queued (0 when no wait, nested
    or degraded) before COMMAND starts, so a caller can leave the wait out of its
    own timing; a path that cannot be written never changes COMMAND's status.
  - K must be a positive integer no larger than size; otherwise exit 125.
  - SIGTERM or SIGHUP while waiting ends the waiter with 128+n; SIGINT with 130.

Running:
  - COMMAND runs as a child in the caller's process group, so a group signal
    reaches it directly. The holder ignores SIGTERM, SIGINT and SIGHUP while
    the child runs and keeps the passes until the child exits: passes stay with
    running work and are never forwarded or doubled.
  - The child's environment gains FM_CPU_PASS_HELD=<K> (0 when degraded) and
    FM_CPU_PASS_TOKENS, a private directory that is the mini pool of K tokens of
    this reservation, removed when COMMAND ends.
  - Nested work takes no new passes and may request at most the inherited count.
    FM_CPU_PASS_HELD must be a nonnegative decimal integer or run exits 125,
    including without Python; 0 denotes degraded work and imposes no budget.
    When FM_CPU_PASS_TOKENS names a live directory, a nested run LEASES its
    --passes (default 1) tokens from it, waiting while sibling work holds them,
    so every descendant draws on the one reservation and workers alive together
    never exceed the passes held. COMMAND then sees FM_CPU_PASS_HELD=<leased
    count> and a token directory of its own with exactly that many tokens. With
    no token directory (a holder that only exports the marker, or a hand-set
    marker) a nested run executes COMMAND unchanged and the marker is trusted.
  - Only this owner retains slot descriptors; close-on-exec/close_fds prevents
    COMMAND and its descendants retaining passes after COMMAND exits. The passes
    (and leased tokens) stay held until COMMAND itself ends: a guard process
    started before COMMAND keeps the descriptors open, ignores TERM, INT and
    HUP, polls COMMAND's pid at the waiters' own poll cap, and exits when it is
    gone, so killing only this owner does not free a pass for a second worker.
    COMMAND's other descendants hold nothing; a reused pid keeps the pass a
    little longer. ordinary TERM/INT/HUP still keep the owner until COMMAND ends.
    The guard is started before COMMAND, never after: no moment exists in which
    COMMAND runs and nothing but its starter holds the passes. When the guard
    cannot be started, or the token directory cannot be created, the passes are
    returned and COMMAND runs without one with FM_CPU_PASS_HELD=0, said once.
    The log fd is closed; stdout and stderr carry only COMMAND's own output.
  - A degraded run (the protocol's rule 7) writes one notice to the log fd.

Pipeline starts:
  - `pipeline-start` uses this pool directory's pipeline-start.lock and locked
    priority waiter files. The start policy, formula and class order are owned
    by docs/cpu-pass-pool.md. The counted runs always come from the host's
    ~/.no-mistakes/state.sqlite, opened only with mode=ro (plus immutable=1 when
    mode=ro cannot open a stopped WAL database with no -wal file): status = 'running'
    AND ci_ready_at IS NULL AND awaiting_agent_since IS NULL. Notices go to stderr.
  - Admission is by measured memory reservations, never by load average. The
    first waiter is admitted when, as bytes, (counted + 1) x R + S fits
    B = available memory + the resident memory each counted run holds now, at
    most R per run (memory a run holds above R is not free for new starts), or
    when nothing is counted (a one-start minimum). S is the largest per-run
    peak of every recorded no-mistakes run with at least 2 readings, and R the
    75th percentile (nearest rank) of those peaks leaving out runs that are
    status-running with ci_ready_at IS NULL (not CI-ready yet, so its peak may
    still rise), read from the
    root home's .memory-calibration.json (written by fm-mem-guard.sh probe; the
    root home comes from fm_firstmate_root_home in fm-secondmate-parent-lib.sh,
    kept once resolved, and a failed walk falls back). available
    and each run's resident memory come from one fm-mem-guard.py admission_sample
    reading, re-taken at most every 2 s while waiting and always taken anew
    at the moment of a grant (both backstop signals included). With fewer than 2
    recorded runs left to rank for R, or no native memory facts on this platform, the
    start falls back to counted < max(1, floor(logical CPUs / 3)); a missing
    record never refuses a start and never reads as an empty host.
  - Pause-only backstop: while that reading is unreadable or reports a reason to
    defer (the same list that makes fm-mem-guard.sh admit exit 75, such as native
    pressure level 2 or higher) or fm-proc-guard.py reports a pile-up (user
    process count above its warning line) or cannot be read, no start is
    admitted. Nothing running is stopped, and waiting here only delays the start.
  - Admission is before COMMAND (including any measured execution wrapper).
    No burst passes or FM_CPU_PASS_HELD budget are assigned to pipeline starts.
  - A short start lock bridges the check-to-registration race until a new
    running run ID appears, or COMMAND returns. It does not reserve a run's
    lifetime or poll after registration; status changes release capacity.
    Participating starts serialize this handshake, not their required checks.
    A registered run whose process tree the reading cannot see yet holds no
    memory in B, so it reserves its full R in the next decision.
    Bypassing this owner or external daemon status changes cannot be made
    atomic with a read-only external database; deployment must route starts here.
  - An unreadable run database or CPU count refuses with 125 instead of
    guessing headroom. If a read fails after launch, retain the start lock until
    COMMAND returns; never stop running work because the observer lost its source.

Exit status of `run` and `pipeline-start`: COMMAND's own status; 126 when COMMAND cannot be
executed, 127 when it is not found, 125 for a usage error.
"""

import argparse
import contextlib
import errno
import importlib.util
import json
import math
import os
from pathlib import Path
import random
import shutil
import signal
import sqlite3
import stat
import tempfile
import subprocess
import sys
import time
from typing import List, Optional, Tuple

try:
    import fcntl  # type: ignore
except ImportError:  # pragma: no cover - platform without POSIX locks
    fcntl = None  # type: ignore

HELD_ENV = "FM_CPU_PASS_HELD"
TOKENS_ENV = "FM_CPU_PASS_TOKENS"
FIRST_NOTICE_SECS = 2.0
NOTICE_EVERY_SECS = 60.0
POLL_MIN_SECS = 0.05
POLL_MAX_SECS = 0.5


class PoolUnavailable(Exception):
    """The pool cannot be used on this host; callers run without a pass."""


def log(fd: int, message: str) -> None:
    try:
        os.write(fd, ("fm-cpu-pass: " + message + "\n").encode("utf-8", "replace"))
    except OSError:
        pass


def pool_size() -> int:
    return max(1, os.cpu_count() or 1)


def pool_dir() -> str:
    explicit = os.environ.get("FM_CPU_POOL_DIR", "").strip()
    if explicit:
        return explicit
    home = os.environ.get("HOME", "").strip()
    if not home:
        raise PoolUnavailable("HOME and FM_CPU_POOL_DIR are both unset")
    return os.path.join(home, ".cache", "fm-cpu-pool")


def ensure_pool_dir(path: str) -> None:
    if fcntl is None:
        raise PoolUnavailable("this platform has no fcntl file locks")
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        info = os.lstat(path)
    except OSError as exc:
        raise PoolUnavailable("pool directory %s is unusable: %s" % (path, exc))
    if not stat.S_ISDIR(info.st_mode):
        raise PoolUnavailable("pool path %s is not a directory" % path)
    if hasattr(os, "getuid") and info.st_uid != os.getuid():
        raise PoolUnavailable("pool directory %s is owned by another user" % path)


def open_lock(path: str) -> int:
    fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0), 0o600)
    return fd


def try_lock(fd: int) -> bool:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError as exc:
        if exc.errno in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
            return False
        raise


def slot_path(directory: str, index: int) -> str:
    return os.path.join(directory, "slot-%d.lock" % index)


def read_holder(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def probe_slots(directory: str, size: int) -> List[Tuple[int, bool, str]]:
    """Returns (index, held, holder text) for every slot without keeping any."""
    result = []
    for index in range(size):
        path = slot_path(directory, index)
        fd = open_lock(path)
        try:
            free = try_lock(fd)
        finally:
            os.close(fd)
        result.append((index, not free, "" if free else read_holder(path)))
    return result


def holders_summary(directory: str, size: int) -> str:
    labels = [text for _, held, text in probe_slots(directory, size) if held and text]
    if not labels:
        return "holders unknown"
    shown = labels[:5]
    more = len(labels) - len(shown)
    summary = "; ".join(shown)
    if more > 0:
        summary += "; and %d more" % more
    return "holders: " + summary


def acquire(directory: str, size: int, passes: int, label: str, log_fd: int) -> List[int]:
    started = time.monotonic()
    next_notice = started + FIRST_NOTICE_SECS
    noticed = False
    delay = POLL_MIN_SECS

    def maybe_notice(what: str) -> None:
        nonlocal next_notice, noticed
        now = time.monotonic()
        if now < next_notice:
            return
        log(log_fd, "waiting %ds for %d CPU pass(es) for %s: %s; pool size %d; %s" % (
            int(now - started), passes, label, what, size, holders_summary(directory, size)))
        noticed = True
        next_notice = now + NOTICE_EVERY_SECS

    turnstile = open_lock(os.path.join(directory, "turnstile.lock"))
    try:
        while not try_lock(turnstile):
            maybe_notice("another request is collecting passes")
            time.sleep(delay)
            delay = min(POLL_MAX_SECS, delay * 2)
        held: List[int] = []
        held_slots = set()
        delay = POLL_MIN_SECS
        order = list(range(size))
        record = ("pid=%d passes=%d since=%d label=%s\n" % (
            os.getpid(), passes, int(time.time()), label.replace("\n", " "))).encode("utf-8", "replace")
        while True:
            random.shuffle(order)
            for index in order:
                if len(held) >= passes:
                    break
                if index in held_slots:
                    continue
                fd = open_lock(slot_path(directory, index))
                if try_lock(fd):
                    held.append(fd)
                    held_slots.add(index)
                    try:
                        os.ftruncate(fd, 0)
                        os.pwrite(fd, record, 0)
                    except OSError:
                        pass
                else:
                    os.close(fd)
            if len(held) >= passes:
                break
            # Keep the slots already collected: only the turnstile holder
            # collects, so partial slots cannot deadlock against another
            # collector, and a multi-pass request is not starved.
            maybe_notice("all passes in use")
            time.sleep(delay)
            delay = min(POLL_MAX_SECS, delay * 2)
    finally:
        os.close(turnstile)
    if noticed:
        log(log_fd, "got %d CPU pass(es) for %s after %ds" % (
            passes, label, int(time.monotonic() - started)))
    return held


def make_tokens() -> str:
    """A private directory that is the mini pool of one holder's reservation (docs/cpu-pass-pool.md rule 6)."""
    return tempfile.mkdtemp(prefix="fm-cpu-tokens-")


def drop_tokens(path: str) -> None:
    if path:
        shutil.rmtree(path, ignore_errors=True)


class Guard:
    """The guard process that keeps a command's passes (and its token directory) until that command ends.

    It is created BEFORE the command, so no moment exists in which a command runs and nothing but its starter
    holds the passes. The command inherits the write end of a pipe the guard reads (inherit); bind tells the
    guard the command's pid once the command exists, and the guard then polls that pid. A starter that dies
    before bind leaves the guard reading a pipe only the command still holds, so the guard keeps the passes
    until the command, and any process that inherited the pipe, ends: never shorter than the command lives.
    """

    def __init__(self, child: "subprocess.Popen", write_fd: int) -> None:
        self.child = child
        self.write_fd = write_fd

    def inherit(self) -> Tuple[int, ...]:
        return (self.write_fd,) if self.write_fd >= 0 else ()

    def close_write(self) -> None:
        if self.write_fd >= 0:
            try:
                os.close(self.write_fd)
            except OSError:
                pass
            self.write_fd = -1

    def bind(self, pid: int) -> None:
        if self.write_fd >= 0:
            try:
                os.write(self.write_fd, ("%d\n" % pid).encode())
            except OSError:
                pass
            self.close_write()

    def stop(self) -> None:
        self.close_write()
        try:
            self.child.kill()
        except OSError:
            pass
        try:
            self.child.wait()
        except OSError:
            pass


def _ignore_signals() -> None:
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, signal.SIG_IGN)


def start_guard(fds: List[int], tokens: str = "") -> Optional[Guard]:
    """Start the guard of the passes FDS before their command exists; None when there is nothing to hold.

    The guard is `fm-cpu-pass.py guard`: a fresh interpreter that inherits only FDS and its pipe, ignores
    TERM, INT and HUP, and removes TOKENS (the reservation's token directory) once the command is gone.
    It raises OSError when the guard cannot be started; the caller then does not run the command under the
    passes (the protocol's degrade rule) and never leaves the command running with nothing keeping them.
    """
    if not fds:
        return None
    read_fd, write_fd = os.pipe()
    try:
        child = subprocess.Popen(
            [sys.executable or "python3", os.path.abspath(__file__), "guard", "--fd", str(read_fd), "--tokens", tokens],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            close_fds=True, pass_fds=tuple(fds) + (read_fd,), preexec_fn=_ignore_signals)
    except BaseException:
        os.close(read_fd)
        os.close(write_fd)
        raise
    os.close(read_fd)
    return Guard(child, write_fd)


def stop_guard(guard: Optional[Guard]) -> None:
    if guard is not None:
        guard.stop()


def cmd_guard(args: argparse.Namespace) -> int:
    """Internal: hold the inherited pass descriptors until the command named on the pipe ends."""
    pid_text = b""
    while not pid_text.endswith(b"\n"):
        chunk = os.read(args.fd, 64)
        if not chunk:
            break
        pid_text += chunk
    os.close(args.fd)
    if pid_text.endswith(b"\n"):
        pid = int(pid_text)
        while True:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            except PermissionError:
                pass
            time.sleep(POLL_MAX_SECS)  # no faster than the waiters it releases the pass to poll for it
    drop_tokens(args.tokens)
    return 0


def exit_code_for(returncode: int) -> int:
    if returncode < 0:
        return 128 + (-returncode)
    return returncode


def run_child(command: List[str], env: dict, log_fd: int, on_poll=None, guard: Optional[Guard] = None) -> int:
    previous = {}
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        previous[signum] = signal.signal(signum, signal.SIG_IGN)
    try:
        try:
            child = subprocess.Popen(
                command, env=env, close_fds=True,
                pass_fds=guard.inherit() if guard is not None else (),
                preexec_fn=_restore_default_signals)
        except FileNotFoundError:
            log(log_fd, "command not found: %s" % command[0])
            return 127
        except PermissionError:
            log(log_fd, "command not executable: %s" % command[0])
            return 126
        if guard is not None:
            guard.bind(child.pid)
        while True:
            if on_poll is not None and on_poll():
                on_poll = None
            try:
                return exit_code_for(child.wait(timeout=POLL_MAX_SECS if on_poll else None))
            except subprocess.TimeoutExpired:
                continue
            except InterruptedError:  # pragma: no cover - PEP 475 retries
                continue
    finally:
        stop_guard(guard)
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def _restore_default_signals() -> None:
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, signal.SIG_DFL)


def exec_direct(command: List[str], env: dict, log_fd: int) -> int:
    if log_fd > 2:
        try:
            os.close(log_fd)
        except OSError:
            pass
    try:
        os.execvpe(command[0], command, env)
    except FileNotFoundError:
        log(2, "command not found: %s" % command[0])
        return 127
    except PermissionError:
        log(2, "command not executable: %s" % command[0])
        return 126
    return 126  # pragma: no cover - execvpe does not return


def write_wait(path: str, started: float) -> None:
    """Record the milliseconds queued since STARTED for a caller that times COMMAND itself."""
    if not path:
        return
    try:
        Path(path).write_text("%d\n" % round((time.monotonic() - started) * 1000), encoding="utf-8")
    except OSError:
        pass


def release_fds(fds: List[int]) -> None:
    for fd in fds:
        try:
            os.close(fd)
        except OSError:
            pass


def cmd_run(args: argparse.Namespace) -> int:
    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        log(2, "run needs a command after --")
        return 125
    log_fd = args.log_fd
    env = dict(os.environ)
    size = pool_size()
    passes = args.passes
    if not 1 <= passes <= size:
        log(log_fd, "--passes must be between 1 and the pool size (%d)" % size)
        return 125
    if HELD_ENV in env:
        inherited = env[HELD_ENV]
        if not inherited or not inherited.isascii() or not inherited.isdecimal():
            log(log_fd, "%s must be a nonnegative decimal integer" % HELD_ENV)
            return 125
        held_count = int(inherited)
        if held_count and passes > held_count:
            log(log_fd, "--passes must not exceed %s (%d)" % (HELD_ENV, held_count))
            return 125
        tokens = env.get(TOKENS_ENV, "")
        if held_count and tokens and os.path.isdir(tokens):
            return lease_tokens(command, env, log_fd, tokens, held_count, passes, args.label or os.path.basename(command[0]), args.wait_file)
        write_wait(args.wait_file, time.monotonic())
        return exec_direct(command, env, log_fd)
    label = args.label or os.path.basename(command[0])
    try:
        directory = pool_dir()
        ensure_pool_dir(directory)
    except PoolUnavailable as exc:
        log(log_fd, "running %s without a CPU pass: %s" % (label, exc))
        env[HELD_ENV] = "0"
        write_wait(args.wait_file, time.monotonic())
        return exec_direct(command, env, log_fd)
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, signal.SIG_DFL)
    queued_at = time.monotonic()
    try:
        held = acquire(directory, size, passes, label, log_fd)
    except KeyboardInterrupt:
        return 130
    except OSError as exc:
        log(log_fd, "running %s without a CPU pass: %s" % (label, exc))
        env[HELD_ENV] = "0"
        write_wait(args.wait_file, queued_at)
        return exec_direct(command, env, log_fd)
    write_wait(args.wait_file, queued_at)
    tokens = ""
    guard = None
    try:
        tokens = make_tokens()
        guard = start_guard(held, tokens)
    except OSError as exc:
        # The pass is returned and the command runs without one, said once: never stop the work, and never run it
        # under a pass nothing keeps (rule 7).
        release_fds(held)
        drop_tokens(tokens)
        log(log_fd, "running %s without a CPU pass: cannot set up what keeps it: %s" % (label, exc))
        env[HELD_ENV] = "0"
        env.pop(TOKENS_ENV, None)
        return exec_direct(command, env, log_fd)
    env[HELD_ENV] = str(passes)
    env[TOKENS_ENV] = tokens
    try:
        return run_child(command, env, log_fd, guard=guard)
    finally:
        drop_tokens(tokens)
        release_fds(held)


def lease_tokens(command: List[str], env: dict, log_fd: int, tokens: str, held_count: int, passes: int, label: str, wait_file: str) -> int:
    """Nested work under a holder's reservation: lease PASSES of its tokens for COMMAND, waiting for them if siblings hold them.

    The holder's passes are one reservation; every descendant that starts a CPU-bound worker leases from the same
    tokens, so sibling runners cannot each spend all of it. COMMAND gets the leased count as its own reservation.
    """
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, signal.SIG_DFL)
    queued_at = time.monotonic()
    try:
        leased = acquire(tokens, held_count, passes, label, log_fd)
    except KeyboardInterrupt:
        return 130
    except OSError as exc:
        log(log_fd, "running %s without leasing from its reservation: %s" % (label, exc))
        write_wait(wait_file, queued_at)
        return exec_direct(command, env, log_fd)
    write_wait(wait_file, queued_at)
    sub = ""
    guard = None
    try:
        sub = make_tokens()
        guard = start_guard(leased, sub)
    except OSError as exc:
        release_fds(leased)
        drop_tokens(sub)
        log(log_fd, "running %s without leasing from its reservation: cannot set up what keeps the lease: %s" % (label, exc))
        return exec_direct(command, env, log_fd)
    env[HELD_ENV] = str(passes)
    env[TOKENS_ENV] = sub
    try:
        return run_child(command, env, log_fd, guard=guard)
    finally:
        drop_tokens(sub)
        release_fds(leased)


PIPELINE_PRIORITIES = ("merge-train", "machinery", "vernant-build", "other")
HOST_STATE_DB = "~/.no-mistakes/state.sqlite"


def running_runs() -> dict:
    """Map each status-running run ID to (repo ID, whether it counts against the start limit, whether it is CI-ready).

    Reads host execution state without creating or changing its database.
    """
    path = Path(HOST_STATE_DB).expanduser().resolve()

    def read(query: str) -> dict:
        with contextlib.closing(sqlite3.connect(path.as_uri() + query, uri=True)) as connection:
            return {row[0]: (row[1], bool(row[2]), bool(row[3])) for row in connection.execute(
                "SELECT id, repo_id, ci_ready_at IS NULL AND awaiting_agent_since IS NULL, ci_ready_at IS NOT NULL"
                " FROM runs WHERE status = 'running'")}

    try:
        return read("?mode=ro")
    except sqlite3.OperationalError as exc:
        # A cleanly stopped WAL database has no side files and mode=ro cannot
        # create them. With no -wal file, the main file holds every committed row.
        if str(exc) != "unable to open database file" or os.path.lexists(str(path) + "-wal"):
            raise
    return read("?mode=ro&immutable=1")


RESERVATION_QUANTILE = 0.75  # policy choice (Main 2473 ruling); the peaks it ranks are measured
MIN_QUALIFYING_RUNS = 2
# Cadence for re-reading the host while a start waits, not a deadline; no command is stopped by it.
# Ten real full readings (memory census plus process count): maximum 0.192 s (private task evidence).
# measured: value=2.0 date=2026-11-01 host=Mac-Studio.local margin=10
OBSERVE_EVERY_SECS = 2.0


def sibling(module: str, filename: str):
    """Load a sibling engine as a module (read-only functions only)."""
    loaded = sys.modules.get(module)
    if loaded is not None:
        return loaded
    spec = importlib.util.spec_from_file_location(module, Path(__file__).with_name(filename))
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[module] = loaded
    spec.loader.exec_module(loaded)
    return loaded


_root_home: List[Path] = []


def root_home() -> Path:
    """The top-most local firstmate home, which owns the host's calibration record."""
    if _root_home:
        return _root_home[0]
    # A worker has FM_DURATION_HOME (the owning home fm-spawn exports) and may have no FM_HOME.
    start = (os.environ.get("FM_HOME") or os.environ.get("FM_DURATION_HOME")
             or str(Path(__file__).resolve().parent.parent))
    walk = subprocess.run(
        ["bash", "-c", '. "$1" && fm_firstmate_root_home "$2"', "bash",
         str(Path(__file__).with_name("fm-secondmate-parent-lib.sh")), start],
        # Ten real fm_firstmate_root_home calls from a worker checkout: maximum 0.035 s (private task evidence).
        # measured: value=10 date=2026-11-01 host=Mac-Studio.local margin=285
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10, check=True)
    home = walk.stdout.strip()
    if not home.startswith("/"):
        raise ValueError("no root home resolved from %s" % start)
    _root_home.append(Path(home))
    return _root_home[0]


def rank_quantile(values: List[int], quantile: float) -> int:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(quantile * len(ordered)) - 1)]


def measured_reservations(report: dict, running: dict) -> Optional[Tuple[int, int, int]]:
    """(R, S, qualifying runs) from the host's recorded no-mistakes run peaks, or None.

    S takes every qualifying peak, since a peak so far is a lower bound. R leaves
    out runs still running that are not CI-ready yet, so their peak may still rise.
    None means too little record on this host, never an error: the caller falls
    back to the counted-run limit. A record for another host or RAM size is not
    this host's measurement.
    """
    young = {"no-mistakes:%s/%s" % (repo, run) for run, (repo, _, ci_ready) in running.items() if not ci_ready}
    try:
        record, _ = sibling("fm_mem_guard", "fm-mem-guard.py").host_record(
            root_home() / "state" / ".memory-calibration.json", report, "calibration", "fm-memory-calibration.v1", ())
        if record is None:
            return None
        peaks = {name: run["peak_bytes"] for name, run in record["runs"].items()
                 if name.startswith("no-mistakes:") and type(run["samples"]) is int
                 and run["samples"] >= MIN_QUALIFYING_RUNS and type(run["peak_bytes"]) is int
                 and run["peak_bytes"] > 0}
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        return None
    ranked = [peak for name, peak in peaks.items() if name not in young]
    if len(ranked) < MIN_QUALIFYING_RUNS:
        return None
    return rank_quantile(ranked, RESERVATION_QUANTILE), max(peaks.values()), len(ranked)


_observed: dict = {}


def host_observation(fresh: bool = False) -> dict:
    """One reading of the harm signals; an unreadable source is itself a reason to wait.

    A waiting start may reuse a reading up to OBSERVE_EVERY_SECS old to keep polling cheap, but
    never to grant: the grant path passes fresh=True and takes a new reading at that moment.
    """
    now = time.monotonic()
    if not fresh and _observed and now - _observed["at"] < OBSERVE_EVERY_SECS:
        return _observed
    reasons: List[str] = []
    memory = None
    if sys.platform == "darwin" or os.environ.get("FM_MEMORY_FIXTURE_DIR"):
        try:
            guard = sibling("fm_mem_guard", "fm-mem-guard.py")
            report = guard.admission_sample()
            deferred, _, _ = guard.admission_evaluate(report, None)
            reasons += ["memory: " + text for text in deferred]
            if not report["errors"]:
                memory = report
        except Exception as exc:  # an unreadable reading must wait, never admit
            reasons.append("memory: observation failed: %s" % exc)
    try:
        guard = sibling("fm_proc_guard", "fm-proc-guard.py")
        source = guard.open_source()
        limit, limit_source = source.limit()
        count = source.count()
        if limit is None and source.name != "linux":
            reasons.append("process limit unreadable: %s" % limit_source)
        elif limit and count > limit * guard.WARN_PERCENT / 100.0:
            reasons.append("process pile-up: %d of %d user processes" % (count, limit))
    except Exception as exc:
        reasons.append("process count unreadable: %s" % exc)
    _observed.clear()
    _observed.update(at=now, reasons=reasons, memory=memory)
    return _observed


def decide(running: dict, counted: dict, cores: int, priority: str, fresh: bool = False) -> Tuple[bool, str]:
    """(admit, one-line reason) for the first waiter, from the running and counted runs and the host reading."""
    seen = host_observation(fresh)
    if seen["reasons"]:
        return False, "overload: %s counted=%d priority=%s" % ("; ".join(seen["reasons"]), len(counted), priority)
    report = seen["memory"]
    reserved = measured_reservations(report, running) if report is not None else None
    if reserved is None:
        limit = max(1, cores // 3)
        return len(counted) < limit, "counted=%d limit=%d basis=fallback priority=%s" % (len(counted), limit, priority)
    reservation, slack, qualifying = reserved
    held = sum(min(reservation, report["runs"].get("no-mistakes:%s/%s" % (repo, run), {}).get("rss_bytes", 0))
               for run, repo in counted.items())
    budget = report["available_bytes"] + held
    need = (len(counted) + 1) * reservation + slack
    return need <= budget or not counted, (
        "counted=%d need=%d budget=%d reservation=%d slack=%d runs_measured=%d priority=%s"
        % (len(counted), need, budget, reservation, slack, qualifying, priority))


def pipeline_observation() -> Tuple[dict, int]:
    cores = os.cpu_count()
    if not isinstance(cores, int) or cores < 1:
        raise ValueError("cannot read a positive native CPU count")
    return running_runs(), cores


def first_pipeline_waiter(directory: str) -> str:
    """Locked entries are live waiters; a dead waiter's unlocked file is inert."""
    entries = []
    for path in Path(directory).glob("pipeline-waiter-*.lock"):
        try:
            fd = os.open(str(path), os.O_RDWR | getattr(os, "O_CLOEXEC", 0))
        except FileNotFoundError:
            continue
        try:
            if try_lock(fd):
                path.unlink(missing_ok=True)
                continue
            entry = json.loads(os.pread(fd, 65536, 0))
            entries.append((PIPELINE_PRIORITIES.index(entry["priority"]), entry["queued_ns"], str(path)))
        finally:
            os.close(fd)
    return min(entries)[2] if entries else ""


def cmd_pipeline_start(args: argparse.Namespace) -> int:
    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        log(2, "pipeline-start needs a command after --")
        return 125
    waiter_fd = admission_fd = None
    waiter_path = None
    try:
        directory = pool_dir()
        ensure_pool_dir(directory)
        # Publish a fully written, locked entry atomically; no reader sees a
        # partial priority record. These are startup waiters, not CPU passes.
        waiter_fd, temporary = tempfile.mkstemp(prefix=".pipeline-waiter-", dir=directory)
        fcntl.flock(waiter_fd, fcntl.LOCK_EX)
        os.write(waiter_fd, json.dumps({"priority": args.priority, "queued_ns": time.time_ns()}).encode())
        waiter_path = str(Path(directory) / (Path(temporary).name[1:] + ".lock"))
        os.rename(temporary, waiter_path)
        admission_fd = open_lock(os.path.join(directory, "pipeline-start.lock"))
        next_notice = time.monotonic() + FIRST_NOTICE_SECS
        delay = POLL_MIN_SECS
        while True:
            reason = "another start is registering"
            if try_lock(admission_fd):
                before, cores = pipeline_observation()
                counted = {run: repo for run, (repo, is_counted, _) in before.items() if is_counted}
                first = first_pipeline_waiter(directory)
                if first == waiter_path:
                    admit, reason = decide(before, counted, cores, args.priority)
                    if admit:
                        # A cached healthy reading may be stale: confirm with a new reading at the grant.
                        admit, reason = decide(before, counted, cores, args.priority, fresh=True)
                    if admit:
                        break
                else:
                    reason = "counted=%d priority=%s behind a higher-priority or earlier start" % (len(counted), args.priority)
                fcntl.flock(admission_fd, fcntl.LOCK_UN)
            now = time.monotonic()
            if now >= next_notice:
                log(2, "pipeline-start waiting: " + reason)
                next_notice = now + NOTICE_EVERY_SECS
            time.sleep(delay)
            delay = min(POLL_MAX_SECS, delay * 2)
        os.unlink(waiter_path)
        waiter_path = None
        log(2, "pipeline-start admitted: " + reason)
        registration_error = False

        def registered() -> bool:
            nonlocal registration_error
            try:
                if running_runs().keys() - before.keys():
                    # Serialize only the check-to-registration gap. The daemon
                    # owns status after this handoff; no lifetime watcher remains.
                    fcntl.flock(admission_fd, fcntl.LOCK_UN)
                    return True
            except (OSError, sqlite3.Error, ValueError) as exc:
                if not registration_error:
                    log(2, "cannot confirm startup registration; retaining start lock until command returns: %s" % exc)
                    registration_error = True
            return False

        return run_child(command, dict(os.environ), 2, registered)
    except KeyboardInterrupt:
        return 130
    except (PoolUnavailable, OSError, sqlite3.Error, ValueError, KeyError) as exc:
        # Unlike a burst's optional throughput pool, an unreadable start source
        # cannot stand in for proof of headroom under the explicit start policy.
        log(2, "pipeline-start refused: %s" % exc)
        return 125
    finally:
        if waiter_path is not None:
            try:
                os.unlink(waiter_path)
            except FileNotFoundError:
                pass
        for fd in (waiter_fd, admission_fd):
            if fd is not None:
                os.close(fd)


def cmd_status(args: argparse.Namespace) -> int:
    try:
        size = pool_size()
        directory = pool_dir()
        ensure_pool_dir(directory)
    except PoolUnavailable as exc:
        if args.json:
            print(json.dumps({"available": False, "reason": str(exc)}, sort_keys=True))
        else:
            print("pool unavailable: %s" % exc)
        return 0
    slots = probe_slots(directory, size)
    held = [(index, text) for index, is_held, text in slots if is_held]
    if args.json:
        print(json.dumps({
            "available": True,
            "dir": directory,
            "size": size,
            "held": len(held),
            "free": size - len(held),
            "holders": [{"slot": index, "holder": text} for index, text in held],
        }, sort_keys=True))
    else:
        print("pool=%d held=%d free=%d dir=%s" % (size, len(held), size - len(held), directory))
        for index, text in held:
            print("slot-%d %s" % (index, text or "(holder unknown)"))
    return 0


def cmd_size(_args: argparse.Namespace) -> int:
    print(pool_size())
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-cpu-pass.sh",
        description="Host-wide CPU pass pool for CPU-heavy test bursts; see the engine header.",
    )
    sub = parser.add_subparsers(dest="action")
    run = sub.add_parser("run", help="hold passes while running a command")
    run.add_argument("--passes", type=int, default=1, help="exact passes to hold (default 1; must be between 1 and the pool size)")
    run.add_argument("--label", default="", help="holder label shown in status and notices")
    run.add_argument("--log-fd", type=int, default=2, help="fd for wait notices (default 2)")
    run.add_argument("--wait-file", default="", help="file receiving the milliseconds spent queued before COMMAND starts")
    run.add_argument("command", nargs=argparse.REMAINDER, help="-- COMMAND [ARGS...]")
    start = sub.add_parser("pipeline-start", help="queue a fresh pipeline start before its execution clock")
    start.add_argument("--priority", choices=PIPELINE_PRIORITIES, default="other", help="start class in descending priority order")
    start.add_argument("command", nargs=argparse.REMAINDER, help="-- COMMAND [ARGS...]")
    status = sub.add_parser("status", help="report held and free passes")
    status.add_argument("--json", action="store_true", help="print one JSON object")
    sub.add_parser("size", help="print the pool size")
    guard = sub.add_parser("guard", help=argparse.SUPPRESS)  # internal: the process that keeps a command's passes
    guard.add_argument("--fd", type=int, required=True)
    guard.add_argument("--tokens", default="")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code == 0 else 125
    if args.action == "run":
        return cmd_run(args)
    if args.action == "pipeline-start":
        return cmd_pipeline_start(args)
    if args.action == "status":
        return cmd_status(args)
    if args.action == "size":
        return cmd_size(args)
    if args.action == "guard":
        return cmd_guard(args)
    parser.print_help(sys.stderr)
    return 125


if __name__ == "__main__":
    sys.exit(main())
