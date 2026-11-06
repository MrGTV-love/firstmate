#!/usr/bin/env python3
"""
fm-cpu-pass.py - host-wide CPU pass pool for CPU-heavy test bursts.

Usage:
  fm-cpu-pass.sh run [--passes K] [--label TEXT] [--log-fd N] -- COMMAND [ARGS...]
  fm-cpu-pass.sh pipeline-start [--priority CLASS] [--only-fresh] -- COMMAND [ARGS...]
  fm-cpu-pass.sh launch-gate -- AGENT [ARGS...]
  fm-cpu-pass.sh status [--json]
  fm-cpu-pass.sh size

`run` waits for K passes from the pool, runs COMMAND while holding them, and
exits with COMMAND's status (128+n when a signal n ended it).
`status` reports how many passes are held and by whom; `size` prints the pool
size so a caller can size its own worker count (for example pytest -n).

The pool bounds CPU-heavy bursts (test suites and their workers), not agents
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
  - K must be a positive integer no larger than size; otherwise exit 125.
  - SIGTERM or SIGHUP while waiting ends the waiter with 128+n; SIGINT with 130.

Running:
  - COMMAND runs as a child in the caller's process group, so a group signal
    reaches it directly. The holder ignores SIGTERM, SIGINT and SIGHUP while
    the child runs and keeps the passes until the child exits: passes stay with
    running work and are never forwarded or doubled.
  - The child's environment gains FM_CPU_PASS_HELD=<K> (0 when degraded).
  - Nested work takes no new passes and may request at most the inherited count.
    FM_CPU_PASS_HELD must be a nonnegative decimal integer or run exits 125,
    including without Python; 0 denotes degraded work and imposes no budget.
  - Only this owner retains slot descriptors; close-on-exec/close_fds prevents
    COMMAND and its descendants retaining passes after COMMAND exits.
    Killing this owner with SIGKILL releases its slots even if work survives;
    ordinary TERM/INT/HUP still keep the owner until COMMAND ends.
    The log fd is closed; stdout and stderr carry only COMMAND's own output.
  - A degraded run (the protocol's rule 7) writes one notice to the log fd.

Pipeline starts:
  - `pipeline-start` uses this pool directory's pipeline-start.lock and locked
    priority waiter files. The start policy, rule and class order are owned
    by docs/cpu-pass-pool.md. The counted runs always come from the host's
    ~/.no-mistakes/state.sqlite, opened only with mode=ro (plus immutable=1 when
    mode=ro cannot open a stopped WAL database with no -wal file): status = 'running'
    AND ci_ready_at IS NULL AND awaiting_agent_since IS NULL. Each run's open
    step is its highest-ordered step_results row in running or fixing; an
    unreadable step table reads no run as idle. Notices go to stderr.
  - Admission is by measured memory, never by load average. The first waiter is
    admitted when the projection fits the budget, available memory plus the
    resident memory the counted runs hold (never capped), or when no other run
    is counted (a one-start minimum). The projection is S for the new run plus,
    per counted run: only what it holds when it waits on remote CI (open step ci
    in running, no live launch reservation, and positive proof that no agent
    lives: either no process of it is visible and no agent pid is recorded, or
    its recorded agent pid is dead and its round began more than
    NO_PID_WINDOW_SECS ago; a visible tree with no recorded pid keeps A,
    whatever its processes are named) or while its launch gate waits in
    this queue with no live launch reservation; its resident memory or A,
    whichever is larger, when the reading sees it; R while the reading cannot see it. S is the largest per-run peak of every recorded
    no-mistakes run with at least 2 readings, and R the 75th percentile (nearest
    rank) of those peaks leaving out runs that are status-running with
    ci_ready_at IS NULL, read from the root home's .memory-calibration.json
    (written by fm-mem-guard.sh probe). A is the largest (sum - largest) /
    (count - 1) of no-mistakes run memory over the error-free readings of this
    host and RAM size with at least 2 runs in the root home's
    memory-readings.jsonl, so k x A + S covers every recorded k-run total. The
    root home comes from fm_firstmate_root_home in fm-secondmate-parent-lib.sh,
    kept once resolved, and a failed walk falls back. available and each run's
    resident memory come from one fm-mem-guard.py admission_sample reading,
    re-taken at most every 2 s while waiting and always taken anew at the moment
    of a grant (both backstop signals included). With fewer than 2 recorded runs
    left to rank for R, no qualifying reading for A, or no native memory facts on
    this platform, the start falls back to counted < max(1, floor(logical CPUs /
    3)); a missing record never refuses a start and never reads as an empty host.
  - Pause-only backstop: while that reading is unreadable or reports a reason to
    defer (the same list that makes fm-mem-guard.sh admit exit 75, such as native
    pressure level 2 or higher) or fm-proc-guard.py reports a pile-up (user
    process count above its warning line) or cannot be read, no start is
    admitted. Nothing running is stopped, and waiting here only delays the start.
  - Admission is before COMMAND (including any measured execution wrapper).
    No burst passes or FM_CPU_PASS_HELD budget are assigned to pipeline starts.
    With --only-fresh, a COMMAND that start_route does not judge a new run runs
    at once without admission. start_route follows only the executable
    position (transparent wrappers with their options, env -S strings, an
    interpreter or shell running a script, a shell's -c command line and the
    admission routes themselves); any other program's arguments are data.
    A COMMAND it does not judge a new run runs with the exec interception
    first on PATH (fm-mem-guard.sh run, and fm-duration.py run under a
    no-mistakes. key or when a word of the command names no-mistakes): a
    private 0700 directory in the user's temporary directory holding one
    symlink named no-mistakes to fm-cpu-pass.sh, which runs exec-intercept: it
    judges the client's own argv by the same facts, admits a new run in the
    route's class (FM_PIPELINE_START_PRIORITY), and runs the real client with
    every such directory removed from PATH. An admitted command keeps the
    interception unless it runs the client directly (runs_client_directly), so
    each further fresh client in it is admitted on its own. When the directory
    cannot be placed the route says why and holds the whole command as one
    start. Limit: a fresh start no wrapper here can see, the real client called
    by its absolute path past the interception, a PATH reset (sudo, env -i) or a
    start outside every route, is admitted only by run-creation admission in
    the no-mistakes fork (backlog task nm-run-creation-admission).
  - The start lock serializes each decision with the publication of its
    admitted start's pending reservation (a locked pending-*.lock naming the
    admitting pid, the admitted no-mistakes arguments and the running run IDs
    of the decision), then is released. Every later decision counts each
    admitted start that has not registered a run yet at the full R, and as one
    run in the count fallback and the one-start minimum (live_pending). Each
    new running run ID releases one pending start, the oldest still unreleased;
    a pending start also ends when its COMMAND returns, or when the client that
    claimed it through the interception has exited (its run, if any, is then in
    the run database). It does not reserve a run's lifetime; status changes
    release capacity. A registered run whose process tree the reading cannot
    see yet reserves its full R in the next decision.
    The admitted client itself, reached through a nested route or the
    interception, claims its own pending start (claim_pending): same arguments,
    (same_start_args), the admitting pid among its ancestors, and either unclaimed or claimed by
    itself or an ancestor, and no new run has registered for it yet; it runs
    without queueing again. Every other start, a sibling, a second client or
    the same arguments run again, is decided on its own with the pending start
    counted, except that a start nested in the admitted command does not count
    that command's own pending start while it is unclaimed and no process in
    the command runs the admitted client (counted_pending): that client ended
    without a run, so counting it could hold the nested start until the
    command it runs in ends.
    Bypassing this owner or external daemon status changes cannot be made
    atomic with a read-only external database; deployment must route starts here.
  - A SIGINT while a start waits ends it with 130 and never runs COMMAND,
    also when it lands inside a Python callback that drops the
    KeyboardInterrupt: the signal is recorded and every round, and the grant
    itself, checks it.
  - An unreadable run database or CPU count refuses with 125 instead of
    guessing headroom. If a read fails after launch, keep the pending
    reservation until COMMAND returns; never stop running work because the
    observer lost its source.

Launch gate:
  - `launch-gate -- AGENT [ARGS...]` is the no-mistakes agent launcher's final
    exec. It first maps its working directory to exactly one runs.worktree_dir
    (the directory or its real path); none, more than one, or an unreadable
    database refuses. A launch whose run's open step is not ci execs AGENT at
    once, unchanged. Any other launch (ci, or a step it cannot read) queues as
    a pipeline-start waiter in class other and asks the same rule for one more
    active run, its own run counted as a waiter. On a grant, still under the start lock, it publishes the run's
    reservation (a locked launch-*.lock entry it holds while AGENT lives),
    starts AGENT at once as its child in its own process group, then releases
    the lock; it never waits for AGENT to appear in memory. A launch entry
    whose holder is gone reserves nothing and is removed by the next scan;
    several live attempts of one run count once.
  - Hold bound: the daemon's per-invocation budget (agent_timeout in
    ~/.no-mistakes/config.yaml, else the daemon's 30-minute default) minus the
    nearest-rank 99th percentile of completed (exit_status ok) agent_invocations
    durations of step ci; no hold when that is not positive or either input is
    unreadable. Only completed invocations count (Main 3210): the daemon also
    records refused and held launches and timed-out runs as step ci, and
    counting them would let holds shrink their own bound and pull it to zero
    (on this host 2026-11-03: ok rows p99 152.45 min, bound about 87.5 min of
    240; all rows 156.83 min, about 83.2 min). At the bound, or on a mapping refusal, it does not start AGENT,
    prints one "launch-gate refused: <cause>: run <id>; <detail>; next action:
    <action>" line and exits 75; every number in it carries a unit suffix and
    it uses none of the daemon's retry or fallback phrases. A fit reached only
    after a wait past the bound is refused too; a fit at the very first decision
    is admitted, so a bound of 0 holds not at all. A hold (the first time the
    gate is not admitted, whatever the cause: a decision that does not fit, a
    start ahead of it, or start-lock contention however short), an admission
    after a hold and every refusal each append one check wake
    (launch-gate-<run>, naming the run, the reason and the time waited) to the
    root home's wake queue through fm_wake_pending_settle, which never waits
    for the queue lock: when it is busy the wake is spilled to the root home's
    state/.wake-spill.<seq>, never over another producer's spill, and the next
    append to that queue, or the watcher's next start, replays it.
  - AGENT keeps stdin, stdout and stderr; SIGTERM, SIGINT and SIGHUP sent to the
    gate are forwarded to it; its exit status is returned and a death by signal
    is re-raised. A missing or non-executable AGENT returns 127 or 126. A
    forked watcher, holding only a pipe the gate writes, SIGKILLs AGENT (and the
    process group the gate leads) if the gate dies without finishing; the agent's
    process execs only after the watcher holds its pid, so a gate that dies at
    the handoff leaves no agent; an internal error after the start kills AGENT
    before the gate exits.

Exit status of `run`, `pipeline-start` and `launch-gate`: COMMAND's own status; 126 when
COMMAND cannot be executed, 127 when it is not found, 125 for a usage error; launch-gate
returns 75 when it refuses.
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
import signal
import sqlite3
import stat
import tempfile
import subprocess
import sys
import time
from typing import Dict, List, Optional, Tuple

try:
    import fcntl  # type: ignore
except ImportError:  # pragma: no cover - platform without POSIX locks
    fcntl = None  # type: ignore

HELD_ENV = "FM_CPU_PASS_HELD"
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


def exit_code_for(returncode: int) -> int:
    if returncode < 0:
        return 128 + (-returncode)
    return returncode


def run_child(command: List[str], env: dict, log_fd: int, on_poll=None) -> int:
    previous = {}
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        previous[signum] = signal.signal(signum, signal.SIG_IGN)
    try:
        try:
            child = subprocess.Popen(
                command, env=env, close_fds=True,
                preexec_fn=_restore_default_signals)
        except FileNotFoundError:
            log(log_fd, "command not found: %s" % command[0])
            return 127
        except PermissionError:
            log(log_fd, "command not executable: %s" % command[0])
            return 126
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
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def _restore_default_signals() -> None:
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, signal.SIG_DFL)


def _restore_exec_signals() -> None:
    for name in ("SIGPIPE", "SIGXFSZ"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), signal.SIG_DFL)


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
        return exec_direct(command, env, log_fd)
    label = args.label or os.path.basename(command[0])
    try:
        directory = pool_dir()
        ensure_pool_dir(directory)
    except PoolUnavailable as exc:
        log(log_fd, "running %s without a CPU pass: %s" % (label, exc))
        env[HELD_ENV] = "0"
        return exec_direct(command, env, log_fd)
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, signal.SIG_DFL)
    try:
        held = acquire(directory, size, passes, label, log_fd)
    except KeyboardInterrupt:
        return 130
    except OSError as exc:
        log(log_fd, "running %s without a CPU pass: %s" % (label, exc))
        env[HELD_ENV] = "0"
        return exec_direct(command, env, log_fd)
    env[HELD_ENV] = str(passes)
    try:
        return run_child(command, env, log_fd)
    finally:
        for fd in held:
            try:
                os.close(fd)
            except OSError:
                pass


PIPELINE_PRIORITIES = ("merge-train", "machinery", "vernant-build", "other")
HOST_STATE_DB = "~/.no-mistakes/state.sqlite"
INTENT_OPTIONS = ("--intent", "--intent-file")
SHELLS = ("sh", "bash", "zsh", "dash", "ksh")
SHELL_OPERATOR_CHARS = "();<>|&\n"


# Wrappers that run their operand as the program: (short options that take a value, long options that do).
# env -S/--split-string's value is a command line whose words take its place.
TRANSPARENT = {"env": ("uCPS", ("--unset", "--chdir", "--split-string")), "nice": ("n", ("--adjustment",)),
               "nohup": ("", ()), "command": ("", ()), "exec": ("a", ()), "time": ("of", ("--output", "--format")),
               "stdbuf": ("ioe", ("--input", "--output", "--error"))}
ROUTES = ("fm-mem-guard.sh", "fm-duration.py", "fm-cpu-pass.sh", "fm-cpu-pass.py")


def wrapper_operands(name: str, rest: List[str]) -> Optional[Tuple[List[str], Optional[str]]]:
    """(the words wrapper NAME runs as its program, an env split string to read first), or None when it runs none.

    Short options may be clustered and a valued one takes the rest of its word
    or the next word; a long option takes its =value or the next word. env also
    skips NAME=value words and a lone -. command -v and -V only print where the
    program is, so they run nothing.
    """
    short, valued = TRANSPARENT[name]
    while rest:
        word = rest[0]
        if word == "--":
            return rest[1:], None
        if name == "env" and (word == "-" or not word.startswith("-") and "=" in word):
            rest = rest[1:]
            continue
        if not word.startswith("-") or word == "-":
            return rest, None
        rest = rest[1:]
        if word.startswith("--"):
            option, equals, value = word.partition("=")
            if option in valued and not equals:
                value, rest = (rest[0] if rest else ""), rest[1:]
            if option == "--split-string":
                return rest, value
            continue
        for index, letter in enumerate(word[1:], 1):
            if name == "command" and letter in "vV":
                return None
            if letter in short:
                value = word[index + 1:]
                if not value:
                    value, rest = (rest[0] if rest else ""), rest[1:]
                if name == "env" and letter == "S":
                    return rest, value
                break
    return rest, None


def fresh_pipeline_start(command: List[str]) -> bool:
    """Whether COMMAND begins a new no-mistakes run (see start_route)."""
    return start_route(command) is not None


def start_route(command: List[str]) -> Optional[Tuple[List[str], bool]]:
    """(no-mistakes arguments, whether another admission route sits in between) of the new run COMMAND begins, or None.

    Only the executable position counts: leading VAR=value words, the
    transparent wrappers env, nice, nohup, command, exec, time and stdbuf with
    their options (wrapper_operands; env -S/--split-string's words read in its
    place), a Python interpreter or a shell running a script, a shell's -c string
    (read as a command line, see shell_string_start) and the admission routes
    fm-mem-guard.sh run --, fm-duration.py run KEY -- and fm-cpu-pass pipeline-start --
    are followed to the program they run. Any other program's arguments are data,
    so `printf no-mistakes axi run --intent x` is not a start. `no-mistakes rerun`
    always creates a new run; `no-mistakes axi run` creates one only with an intent
    input (--intent TEXT, --intent -, --intent-file PATH or their = forms). The
    route flag is true when an admission route other than this admission's own
    measured runner (fm-duration.py run --pipeline-admitted) runs the start.
    """
    routed = False
    words = list(command)
    while words:
        while words and "=" in words[0] and words[0].split("=", 1)[0].isidentifier():
            words = words[1:]
        if not words:
            return None
        name = os.path.basename(words[0])
        rest = words[1:]
        if name == "no-mistakes":
            fresh = rest[:1] == ["rerun"] or rest[:2] == ["axi", "run"] and any(
                option in INTENT_OPTIONS or option.startswith(tuple(intent + "=" for intent in INTENT_OPTIONS))
                for option in rest[2:])
            return (rest, routed) if fresh else None
        if name in TRANSPARENT:
            operands = wrapper_operands(name, rest)
            if operands is None:
                return None
            words, split = operands
            if split is not None:
                import shlex
                try:
                    words = ["env"] + shlex.split(split) + words
                except ValueError:
                    return None  # env refuses an unbalanced split string and runs nothing
            continue
        if name.rstrip("0123456789.").lower() == "python":
            while rest and rest[0].startswith("-"):
                if rest[0] in ("-c", "-m"):
                    return None
                rest = rest[1:]
            words = rest
            continue
        if name in SHELLS:
            string = shell_command_string(words, 0)
            if string is None:
                # A shell running a script file: the script is the program.
                while rest and rest[0].startswith(("-", "+")) and rest[0] not in ("-", "--"):
                    rest = rest[2:] if rest[0] in ("-o", "+o", "--rcfile", "--init-file") else rest[1:]
                words = rest[1:] if rest[:1] == ["--"] else rest
                continue
            found = shell_string_start(string)
            return None if found is None else (found[0], routed or found[1])
        if name in ROUTES:
            if name == "fm-mem-guard.sh" and rest[:2] == ["run", "--"]:
                words, routed = rest[2:], True
                continue
            if name == "fm-duration.py" and rest[:1] == ["run"] and "--" in rest:
                own = "--pipeline-admitted" in rest[:rest.index("--")]
                words, routed = rest[rest.index("--") + 1:], routed or not own
                continue
            if name.startswith("fm-cpu-pass.") and rest[:1] == ["pipeline-start"] and "--" in rest:
                words, routed = rest[rest.index("--") + 1:], True
                continue
        return None
    return None


def shell_command_string(command: List[str], index: int) -> Optional[str]:
    """The -c command string of the shell at command[index], after its other options; None when it has none."""
    position = index + 1
    while position < len(command):
        option = command[position]
        if option in ("-", "--") or option[:1] not in ("-", "+"):
            return None
        if option.startswith("-") and not option.startswith("--") and "c" in option[1:]:
            return command[position + 1] if position + 1 < len(command) else None
        takes_value = option in ("--rcfile", "--init-file") or (not option.startswith("--") and option[-1] in "oO")
        position += 2 if takes_value else 1
    return None


def without_shell_comments(string: str) -> str:
    """STRING without its comments: an unquoted # that begins a word, up to the next newline."""
    kept: List[str] = []
    quote, index, word_start = "", 0, True
    while index < len(string):
        char = string[index]
        if char == "#" and word_start:
            end = string.find("\n", index)
            index = len(string) if end < 0 else end
            continue
        step = 2 if char == "\\" and quote != "'" else 1
        kept.append(string[index:index + step])
        if char in "'\"" and quote in ("", char):
            quote = "" if quote else char
        word_start = not quote and char in " \t\r" + SHELL_OPERATOR_CHARS
        index += step
    return "".join(kept)


def shell_string_start(string: str) -> Optional[Tuple[List[str], bool]]:
    """The first new run one of the simple commands of a shell command string begins, as start_route returns it.

    Comments and redirections (an operator with < or >, a file-descriptor number
    just before it and its target word) are not arguments; a control operator or
    newline ends a simple command.
    """
    import shlex
    try:
        lexer = shlex.shlex(without_shell_comments(string), posix=True, punctuation_chars=SHELL_OPERATOR_CHARS)
        lexer.whitespace = " \t\r"
        lexer.whitespace_split = True
        lexer.commenters = ""
        words = list(lexer)
    except ValueError:
        return None
    simple: List[str] = []
    target = False
    for word in words + [";"]:
        operator = bool(word) and not word.strip(SHELL_OPERATOR_CHARS)
        if operator and ("<" in word or ">" in word):
            if simple and simple[-1].isdigit():
                simple.pop()
            target = True
        elif operator:
            found = start_route(simple)
            if found is not None:
                return found
            simple, target = [], False
        elif target:
            target = False
        else:
            simple.append(word)
    return None


def read_host_db(sql: str, parameters: tuple = ()) -> list:
    """Rows of one query on the host's run database, opened read-only; never creates or changes it."""
    path = Path(HOST_STATE_DB).expanduser().resolve()

    def read(query: str) -> list:
        with contextlib.closing(sqlite3.connect(path.as_uri() + query, uri=True)) as connection:
            return connection.execute(sql, parameters).fetchall()

    try:
        return read("?mode=ro")
    except sqlite3.OperationalError as exc:
        # A cleanly stopped WAL database has no side files and mode=ro cannot
        # create them. With no -wal file, the main file holds every committed row.
        if str(exc) != "unable to open database file" or os.path.lexists(str(path) + "-wal"):
            raise
    return read("?mode=ro&immutable=1")


def running_runs() -> dict:
    """Map each status-running run ID to (repo ID, whether it counts against the start limit, whether it is CI-ready).

    Reads host execution state without creating or changing its database.
    """
    return {row[0]: (row[1], bool(row[2]), bool(row[3])) for row in read_host_db(
        "SELECT id, repo_id, ci_ready_at IS NULL AND awaiting_agent_since IS NULL, ci_ready_at IS NOT NULL"
        " FROM runs WHERE status = 'running'")}


CI_STEP = "ci"


def open_steps() -> Optional[dict]:
    """Each running run's open step as (step name, status, recorded agent pid, round start), or None when unreadable.

    The open step is the highest-ordered step_results row in running or fixing.
    A run with no such row is absent. None never reads as idle: every run then
    keeps its full reservation.
    """
    try:
        rows = read_host_db(
            "SELECT s.run_id, s.step_name, s.status, s.agent_pid, s.round_started_at FROM step_results s JOIN runs r ON r.id = s.run_id"
            " WHERE r.status = 'running' AND s.status IN ('running', 'fixing') ORDER BY s.run_id, s.step_order")
    except (OSError, sqlite3.Error, ValueError):
        return None
    return {run: (name, status, pid, started) for run, name, status, pid, started in rows}


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


_active_term_cache: dict = {}


def active_term_from_readings(lines, host: str, total: int) -> Optional[Tuple[int, int]]:
    """(A, readings used): the largest per-run concurrent demand the record shows for every run but its largest.

    For each error-free reading of this host and RAM size that saw at least 2
    no-mistakes run trees, (sum of their resident memory - the largest one) /
    (count - 1), rounded up; A is the largest such value. With S covering one run
    at the largest recorded peak, k x A + S is at least the summed run memory of
    every recorded reading with k runs. None means no qualifying reading.
    """
    best, used = None, 0
    for line in lines:
        try:
            reading = json.loads(line)
            if reading.get("errors") or reading.get("host") != host or reading.get("total_bytes") != total:
                continue
            sizes = [run["rss_bytes"] for name, run in reading["runs"].items() if name.startswith("no-mistakes:")]
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
        if len(sizes) < MIN_QUALIFYING_RUNS or any(type(size) is not int or size < 0 for size in sizes):
            continue
        value = -(-(sum(sizes) - max(sizes)) // (len(sizes) - 1))
        best = value if best is None else max(best, value)
        used += 1
    return None if best is None else (best, used)


def active_term(report: dict) -> Optional[Tuple[int, int]]:
    """A from the root home's state/memory-readings.jsonl, read-only and cached by size and mtime."""
    try:
        path = root_home() / "state" / "memory-readings.jsonl"
        info = path.stat()
        key = (str(path), info.st_size, info.st_mtime_ns, report["host"], report["total_bytes"])
        if _active_term_cache.get("key") != key:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                value = active_term_from_readings(handle, report["host"], report["total_bytes"])
            _active_term_cache.clear()
            _active_term_cache.update(key=key, value=value)
        return _active_term_cache["value"]
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return None


# The time a step's round must have run before its recorded agent pid is judged:
# the daemon records an agent's pid at the agent's start event and clears it at its
# exit (no-mistakes fork 935aedf, internal/pipeline/executor.go:952-960), and sets
# round_started_at when a step or fix round starts (internal/db/step.go:224-245).
# Evidence: in all 5 native fork-harness launches (p11 refuse3 and admit2) the gate's
# first database read already saw its own pid recorded as agent_pid, and that read
# follows the engine's start, which takes at most 0.113 s here (10 timed runs of
# fm-cpu-pass.py size); inside the window the run keeps A.
# measured: value=120 date=2026-11-04 host=Mac-Studio.local margin=1000
NO_PID_WINDOW_SECS = 120


def pid_dead(pid) -> Optional[bool]:
    """True when no process has this pid, False when one does, None when that cannot be judged."""
    if type(pid) is not int or pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    except OSError:
        return None
    return False


def proven_agentless(step, now: float) -> bool:
    """Positive proof that no agent of this CI step is alive: its recorded pid is dead, after the window.

    A step with no recorded pid, a live or unjudgeable pid, an unknown round
    start, or a round younger than NO_PID_WINDOW_SECS is not proof.
    """
    started = step[3] if len(step) > 3 else None
    return (step[2] is not None and type(started) is int and now - started > NO_PID_WINDOW_SECS
            and pid_dead(step[2]) is True)


def project(available: int, rss: dict, counted: dict, steps: Optional[dict], launches: dict,
            reservation: int, slack: int, term: int, self_run: Optional[str] = None,
            waiting: frozenset = frozenset(), now: Optional[float] = None, pending: int = 0) -> dict:
    """The reservation fit for one more active run; a pure function of its facts.

    counted maps each counted run ID to its repo ID; rss is the reading's run map
    (keyed no-mistakes:<repo>/<run>); steps is open_steps() or None; launches maps
    run IDs to their live launch-gate reservations; now is the decision's wall
    clock (time.time() when None). A run waiting on remote CI (open step ci,
    status running, no live launch) reserves only the resident memory it holds
    in two cases: the reading cannot see its tree and no agent pid is recorded
    (it holds nothing), or its recorded agent pid is dead and its round began
    more than NO_PID_WINDOW_SECS ago (proven_agentless: its bytes). Every other
    CI run keeps the active term: a visible tree with no recorded pid, a live or
    unjudgeable pid, an unknown round start or a round inside the window is not
    proof that no agent lives, whatever the processes are named. Every other counted or launched run reserves its
    resident memory or the active-run term A, whichever is larger, once its tree
    is visible, and its full R while the reading cannot see it yet. The new run
    reserves S. Each of the pending admitted starts that has not registered a run
    yet (pending, see live_pending) reserves the full R. With no live launch, the waiting launch's own run (self_run) and
    every run in waiting (a run whose launch gate is queued in the pool) are
    waiters: each adds only what it holds. Budget is available memory plus what
    the counted runs hold.
    """
    entries = []
    clock = time.time() if now is None else now
    runs = dict(counted)
    for run, entry in launches.items():
        runs.setdefault(run, entry.get("repo"))
    held = 0
    for run in sorted(runs):
        key = "no-mistakes:%s/%s" % (runs[run], run)
        seen = rss.get(key)
        size = seen["rss_bytes"] if seen and type(seen.get("rss_bytes")) is int else 0
        visible = bool(seen) and seen.get("processes", 0) > 0
        step = None if steps is None else steps.get(run)
        held += size
        if run in launches:
            kind = "launched"
            demand = max(size, term) if visible else reservation
        elif run == self_run or run in waiting:
            kind, demand = "waiter", size
        elif (steps is not None and step is not None and step[0] == CI_STEP and step[1] == "running"
              and ((step[2] is None and not visible) or proven_agentless(step, clock))):
            kind, demand = "ci-waiting", size
        else:
            kind = "step-unreadable" if steps is None else ("no-open-step" if step is None else "active")
            demand = max(size, term) if visible else reservation
        entries.append((run, kind, demand, visible))
    for index in range(pending):
        entries.append(("start-%d" % (index + 1), "pending", reservation, False))
    projected = sum(demand for _, _, demand, _ in entries) + slack
    budget = available + held
    others = [run for run, _, _, _ in entries if run != self_run]
    return dict(admit=projected <= budget or not others, projected=projected, budget=budget, held=held,
                available=available, entries=entries, counted=len(counted))


def projection_text(fit: dict, reservation: int, slack: int, term: int, runs_measured: int, readings: int) -> str:
    def items(selected):
        return ",".join("%s:%s:%d%s" % (run, kind, demand, "" if visible else ":unseen")
                        for run, kind, demand, visible in fit["entries"] if selected(kind)) or "none"
    reserved = items(lambda kind: kind not in ("ci-waiting", "waiter"))
    unreserved = items(lambda kind: kind in ("ci-waiting", "waiter"))
    return ("counted=%d projected=%d budget=%d available=%d held=%d reservation=%d active_term=%d slack=%d"
            " runs_measured=%d readings_measured=%d reserved=[%s] holding_only=[%s]"
            % (fit["counted"], fit["projected"], fit["budget"], fit["available"], fit["held"], reservation,
               term, slack, runs_measured, readings, reserved, unreserved))


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


def admission(reasons: List[str], report: Optional[dict], running: dict, counted: dict, steps: Optional[dict],
              launches: dict, cores: int, priority: str, self_run: Optional[str] = None,
              measured: Optional[Tuple[Tuple[int, int, int], Tuple[int, int]]] = None,
              waiting: frozenset = frozenset(), pending: int = 0) -> Tuple[bool, str]:
    """The complete admission rule over one reading's facts: holds first, then the fit or the count fallback.

    measured, when given, supplies ((R, S, runs measured), (A, readings measured))
    instead of reading the records; the P4 replay passes the copied records here.
    pending is the number of admitted starts that have not registered a run yet:
    each counts as one run in the count fallback and the one-start minimum and
    reserves R in the fit.
    """
    others = len([run for run in set(counted) | set(launches) if run != self_run]) + pending
    if reasons:
        return False, "overload: %s counted=%d priority=%s" % ("; ".join(reasons), len(counted), priority)
    if measured is None and report is not None:
        reserved, term = measured_reservations(report, running), active_term(report)
        measured = (reserved, term) if reserved is not None and term is not None else None
    if measured is None:
        limit = max(1, cores // 3)
        return others < limit, "counted=%d limit=%d basis=fallback priority=%s" % (others, limit, priority)
    (reservation, slack, qualifying), (term, readings) = measured
    fit = project(report["available_bytes"], report["runs"], counted, steps, launches, reservation, slack, term, self_run,
                  waiting, pending=pending)
    return fit["admit"], projection_text(fit, reservation, slack, term, qualifying, readings) + " priority=%s" % priority


def decide(running: dict, counted: dict, cores: int, priority: str, fresh: bool = False,
           directory: Optional[str] = None, self_run: Optional[str] = None,
           waiting: frozenset = frozenset()) -> Tuple[bool, str]:
    """(admit, one-line reason) for the first waiter, from the running and counted runs and the host reading."""
    seen = host_observation(fresh)
    launches = live_launches(directory) if directory else {}
    pending = counted_pending(directory, set(running)) if directory else 0
    steps = open_steps() if seen["memory"] is not None else None
    return admission(seen["reasons"], seen["memory"], running, counted, steps, launches, cores, priority, self_run,
                     waiting=waiting, pending=pending)


def pipeline_observation() -> Tuple[dict, int]:
    cores = os.cpu_count()
    if not isinstance(cores, int) or cores < 1:
        raise ValueError("cannot read a positive native CPU count")
    return running_runs(), cores


def live_launches(directory: str) -> dict:
    """Run ID -> entry for each launch-gate reservation whose gate still holds its lock.

    An unlocked file belongs to a gate that no longer exists: it reserves nothing
    and is removed. Several live attempts of one run count once.
    """
    found: dict = {}
    for path in Path(directory).glob("launch-*.lock"):
        try:
            fd = os.open(str(path), os.O_RDWR | getattr(os, "O_CLOEXEC", 0))
        except FileNotFoundError:
            continue
        try:
            if try_lock(fd):
                path.unlink(missing_ok=True)
                continue
            entry = json.loads(os.pread(fd, 65536, 0))
            found.setdefault(entry["run"], entry)
        except (ValueError, KeyError, TypeError):
            continue
        finally:
            os.close(fd)
    return found


def live_pending(directory: str, running: set) -> List[Tuple[str, dict, bool]]:
    """(path, entry, registered) for each pending admitted start whose start still holds its record, oldest first.

    An admitted start publishes a locked pending-*.lock naming the running run IDs
    of its decision (before). Each running run ID that is in none of those sets
    releases one pending start, the oldest one still unreleased, so a new run never
    releases two starts and release is never earlier than the first new run. A
    start whose client claimed it through the exec interception (claim_pending)
    and has since exited is released too: a run that client created is in the
    run database by then. An unlocked file belongs to a start that no longer
    exists and is removed.
    """
    found = []
    for path in Path(directory).glob("pending-*.lock"):
        try:
            fd = os.open(str(path), os.O_RDWR | getattr(os, "O_CLOEXEC", 0))
        except FileNotFoundError:
            continue
        try:
            if try_lock(fd):
                for stale in (str(path), str(path) + ".claimed"):
                    with contextlib.suppress(FileNotFoundError):
                        os.unlink(stale)
                continue
            entry = json.loads(os.pread(fd, 65536, 0))
            found.append((int(entry["created_ns"]), str(path), entry))
        except (ValueError, KeyError, TypeError):
            continue
        finally:
            os.close(fd)
    used: set = set()
    result = []
    for _, path, entry in sorted(found):
        if client_ended(path):
            result.append((path, entry, True))
            continue
        fresh = sorted(set(running) - set(entry.get("before", ())) - used)
        if fresh:
            used.add(fresh[0])
        result.append((path, entry, bool(fresh)))
    return result


def counted_pending(directory: str, running: set) -> int:
    """How many pending admitted starts this decision counts at the full R.

    Every unreleased pending start counts, except one that is this process's own
    enclosing start, has not been claimed, and whose admitted client no process
    in the holder's tree is running (admitted_client_running): its client ended
    without registering (it was called past the interception, by its absolute
    path) or never ran, so counting it would make a later start in the same
    command wait on capacity only that command's end frees.
    """
    mine = None
    count = 0
    for path, entry, registered in live_pending(directory, running):
        if registered:
            continue
        if not os.path.exists(path + ".claimed"):
            if mine is None:
                mine = ancestors(os.getpid())
            if entry.get("holder") in mine and not admitted_client_running(entry["holder"], entry.get("args")):
                continue
        count += 1
    return count


def process_table() -> Dict[int, int]:
    """pid -> parent pid for every process this user can see (OSError when unreadable)."""
    if os.path.isdir("/proc/self"):
        table = {}
        for name in os.listdir("/proc"):
            if name.isdigit():
                with contextlib.suppress(OSError, IndexError, ValueError):
                    with open("/proc/%s/stat" % name, "rb") as handle:
                        table[int(name)] = int(handle.read().rsplit(b")", 1)[1].split()[1])
        return table
    info = sibling("fm_proc_info", "fm-proc-info.py")
    return dict(info.processes())


def process_argv(pid: int) -> Optional[List[str]]:
    """PID's argument vector, unescaped, or None when it cannot be read (the process ended)."""
    try:
        if os.path.isdir("/proc/self"):
            with open("/proc/%d/cmdline" % pid, "rb") as handle:
                words = handle.read().split(b"\0")[:-1]
        else:
            import struct
            info = sibling("fm_proc_info", "fm-proc-info.py")
            data = info.sysctl(info.CTL_KERN, info.KERN_PROCARGS2, pid)
            argc = struct.unpack_from("i", data, 0)[0]
            words = data[4:].split(b"\0", 1)[1].lstrip(b"\0").split(b"\0")[:argc]
    except (OSError, LookupError, IndexError, ValueError, AttributeError):
        return None
    return [word.decode("utf-8", "surrogateescape") for word in words]


def admitted_client_running(holder: int, admitted) -> bool:
    """Whether a process in HOLDER's tree runs the no-mistakes client with the ADMITTED arguments.

    The client may be the binary itself or a script whose interpreter carries it
    as its first argument. True when the process table cannot be read, so an
    unreadable table never stops a start being counted.
    """
    if not isinstance(admitted, list):
        return False
    try:
        table = process_table()
    except (OSError, LookupError, ValueError, AttributeError):
        return True
    children: Dict[int, List[int]] = {}
    for pid, parent in table.items():
        children.setdefault(parent, []).append(pid)
    pending, seen = [holder], set()
    while pending:
        pid = pending.pop()
        for child in children.get(pid, ()):
            if child in seen:
                continue
            seen.add(child)
            pending.append(child)
            words = process_argv(child) or []
            if words and os.path.basename(words[0]) != "no-mistakes" and len(words) > 1 and os.path.basename(words[1]) == "no-mistakes":
                words = words[1:]
            if words and os.path.basename(words[0]) == "no-mistakes" and same_start_args(admitted, words[1:]):
                return True
    return False


def client_ended(path: str) -> bool:
    """Whether the client that claimed the pending start at PATH through the exec interception has exited."""
    try:
        claimer = int(Path(path + ".claimed").read_text())
    except (OSError, ValueError):
        return False
    try:
        os.kill(claimer, 0)
    except ProcessLookupError:
        return True
    except OSError:
        return False
    return False


def publish_locked(directory: str, prefix: str, entry: dict) -> Tuple[int, str]:
    """Write a locked JSON entry and rename it into place, so no reader sees it unlocked or partial."""
    fd, temporary = tempfile.mkstemp(prefix="." + prefix, dir=directory)
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.set_inheritable(fd, False)
    os.write(fd, json.dumps(entry).encode())
    final = str(Path(directory) / (Path(temporary).name[1:] + ".lock"))
    os.rename(temporary, final)
    return fd, final


def first_pipeline_waiter(directory: str) -> Tuple[str, frozenset]:
    """The first live waiter's path and the run IDs of every live launch-gate waiter.

    Locked entries are live waiters; a dead waiter's unlocked file is inert.
    """
    entries = []
    runs = set()
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
            if entry.get("run"):
                runs.add(entry["run"])
        finally:
            os.close(fd)
    return (min(entries)[2] if entries else ""), frozenset(runs)


class HoldBound(Exception):
    """A launch reached its hold bound without a fit."""


def wait_for_admission(directory: str, priority: str, self_run: Optional[str] = None,
                       bound: Optional[float] = None, on_wait=None):
    """Queue one locked waiter entry in class order until admitted; return (start lock fd, before, reason, waited).

    The start lock is held on return. A bound in seconds raises HoldBound with the
    last reason once that long passed without a grant, and also refuses a grant
    reached only after waiting past it (a fit at the very first decision, before
    any wait, is still admitted, so a bound of 0 holds not at all); None waits
    without limit. on_wait(reason, waited seconds) is called once, the first
    time this waiter is not admitted, whatever the cause: a decision that does
    not fit, a higher-priority or earlier start ahead of it, or start-lock
    contention however short.
    """
    waiter_fd = admission_fd = None
    waiter_path = None
    started = time.monotonic()
    # A SIGINT that lands while Python runs a callback (an import's module-lock
    # callback, a weakref finalizer) raises KeyboardInterrupt there, where it is
    # printed as ignored and lost; the waiter would then go on and could run its
    # COMMAND. The handler also records the signal, and every round checks it.
    interrupted: List[int] = []
    previous_handler = None
    if signal.getsignal(signal.SIGINT) is signal.default_int_handler:
        def on_interrupt(signum, frame):
            interrupted.append(signum)
            raise KeyboardInterrupt
        with contextlib.suppress(ValueError):  # not the main thread: keep the default
            previous_handler = signal.signal(signal.SIGINT, on_interrupt)
    try:
        # Publish a fully written, locked entry atomically; no reader sees a
        # partial priority record. These are startup waiters, not CPU passes.
        waiter_fd, waiter_path = publish_locked(directory, "pipeline-waiter-", {
            "priority": priority, "queued_ns": time.time_ns(), "run": self_run})
        admission_fd = open_lock(os.path.join(directory, "pipeline-start.lock"))
        next_notice = started + FIRST_NOTICE_SECS
        delay = POLL_MIN_SECS
        waited = False
        while True:
            if interrupted:
                raise KeyboardInterrupt
            reason = "another start is registering"
            if try_lock(admission_fd):
                before, cores = pipeline_observation()
                counted = {run: repo for run, (repo, is_counted, _) in before.items() if is_counted}
                first, waiting = first_pipeline_waiter(directory)
                if first == waiter_path:
                    admit, reason = decide(before, counted, cores, priority, directory=directory, self_run=self_run,
                                           waiting=waiting)
                    if admit:
                        # A cached healthy reading may be stale: confirm with a new reading at the grant.
                        admit, reason = decide(before, counted, cores, priority, fresh=True, directory=directory,
                                               self_run=self_run, waiting=waiting)
                    if admit and waited and bound is not None and time.monotonic() - started > bound:
                        raise HoldBound("a fit came only after the hold bound passed: " + reason)
                    if admit and interrupted:
                        raise KeyboardInterrupt
                    if admit:
                        result = (admission_fd, before, reason, time.monotonic() - started)
                        admission_fd = None
                        return result
                else:
                    reason = "counted=%d priority=%s behind a higher-priority or earlier start" % (len(counted), priority)
                fcntl.flock(admission_fd, fcntl.LOCK_UN)
            if on_wait is not None:
                on_wait(reason, time.monotonic() - started)
                on_wait = None
            now = time.monotonic()
            if bound is not None and now - started >= bound:
                raise HoldBound(reason)
            if now >= next_notice:
                log(2, "%s waiting: %s" % ("launch-gate" if self_run else "pipeline-start", reason))
                next_notice = now + NOTICE_EVERY_SECS
            waited = True
            time.sleep(delay)
            delay = min(POLL_MAX_SECS, delay * 2)
    finally:
        if previous_handler is not None:
            signal.signal(signal.SIGINT, previous_handler)
        if waiter_path is not None:
            try:
                os.unlink(waiter_path)
            except FileNotFoundError:
                pass
        for fd in (waiter_fd, admission_fd):
            if fd is not None:
                os.close(fd)


def parent_pid(pid: int) -> int:
    """PID's parent, from /proc where the platform has it, else from fm-proc-info.py's kernel reader."""
    try:
        with open("/proc/%d/stat" % pid, "rb") as handle:
            return int(handle.read().rsplit(b")", 1)[1].split()[1])
    except FileNotFoundError:
        if sys.platform != "darwin":
            raise
    info = sibling("fm_proc_info", "fm-proc-info.py")
    import struct
    return struct.unpack_from("i", info.kinfo(pid), info.E_PPID)[0]


def ancestors(pid: int) -> List[int]:
    """The parent chain of PID up to init; a process that cannot be read ends the chain."""
    chain: List[int] = []
    while pid > 1 and len(chain) < 256:
        try:
            pid = parent_pid(pid)
        except (OSError, LookupError, ValueError, IndexError, AttributeError):
            break
        chain.append(pid)
    return chain


def claim_pending(directory: str, args: List[str]) -> Optional[int]:
    """The pid of the enclosing admitted start whose pending reservation is this very start, or None.

    An admitted start publishes a locked pending-*.lock naming its own pid and the
    no-mistakes arguments of the start it admitted. A later start with the same
    arguments is that start, reached through a nested route or the exec
    interception, only when that pid is one of its ancestors and either nobody
    claimed the record before (an exclusive .claimed file then names this
    process) or the process that claimed it is this one or one of its ancestors
    (the same start passing one more route). Every other start, a sibling, a
    second client with other arguments or the same arguments run again, is
    decided on its own, with that pending start counted.
    """
    mine = None
    try:
        released = {path for path, _, registered in live_pending(directory, set(running_runs())) if registered}
    except (OSError, sqlite3.Error, ValueError):
        # Without the run database no release is known; the enclosing admission read it when it admitted.
        released = set()
    for path in Path(directory).glob("pending-*.lock"):
        if str(path) in released:
            continue  # a new run already registered for that start: this one is another start
        try:
            fd = os.open(str(path), os.O_RDWR | getattr(os, "O_CLOEXEC", 0))
        except FileNotFoundError:
            continue
        try:
            if try_lock(fd):
                for stale in (str(path), str(path) + ".claimed"):
                    with contextlib.suppress(FileNotFoundError):
                        os.unlink(stale)
                continue
            entry = json.loads(os.pread(fd, 65536, 0))
            holder, admitted = entry["holder"], entry.get("args")
        except (ValueError, KeyError, TypeError):
            continue
        finally:
            os.close(fd)
        if not same_start_args(admitted, list(args)):
            continue
        if mine is None:
            mine = ancestors(os.getpid())
        if holder not in mine:
            continue
        claim = str(path) + ".claimed"
        temporary = "%s.%d" % (claim, os.getpid())
        try:
            with open(temporary, "w") as handle:
                handle.write(str(os.getpid()))
            os.link(temporary, claim)
            return holder
        except FileExistsError:
            try:
                claimer = int(Path(claim).read_text())
            except (OSError, ValueError):
                continue
            if claimer == os.getpid() or claimer in mine:
                return holder
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)
    return None


SHELL_EXPANSION_CHARS = "$`*?[~{"


def same_start_args(admitted, args: List[str]) -> bool:
    """Whether ARGS are the arguments the pending start admitted, as its client sees them.

    The admission reads a shell's -c string before the shell expands it, so a
    word holding an expansion ($X, a glob, ~) becomes what the shell makes of
    it: the words up to the first such word must be equal, the rest are taken
    as expanded.
    """
    if not isinstance(admitted, list):
        return False
    if admitted == args:
        return True
    for index, word in enumerate(admitted):
        if any(char in word for char in SHELL_EXPANSION_CHARS):
            return args[:index] == admitted[:index]
    return False


def runs_client_directly(command: List[str]) -> bool:
    """Whether COMMAND runs the no-mistakes client as its one program, so nothing in it can begin a second run.

    Only leading VAR=value words, the transparent wrappers (env -S included) and
    the admission routes are followed; a shell, an interpreter running a script or
    any other program could start further clients, so it is not direct.
    """
    words = list(command)
    while words:
        while words and "=" in words[0] and words[0].split("=", 1)[0].isidentifier():
            words = words[1:]
        if not words:
            return False
        name, rest = os.path.basename(words[0]), words[1:]
        if name == "no-mistakes":
            return True
        if name in TRANSPARENT:
            operands = wrapper_operands(name, rest)
            if operands is None:
                return False
            words, split = operands
            if split is not None:
                import shlex
                try:
                    words = ["env"] + shlex.split(split) + words
                except ValueError:
                    return False
            continue
        if name == "fm-mem-guard.sh" and rest[:2] == ["run", "--"]:
            words = rest[2:]
            continue
        if name == "fm-duration.py" and rest[:1] == ["run"] and "--" in rest:
            words = rest[rest.index("--") + 1:]
            continue
        if name.startswith("fm-cpu-pass.") and rest[:1] == ["pipeline-start"] and "--" in rest:
            words = rest[rest.index("--") + 1:]
            continue
        if name.rstrip("0123456789.").lower() == "python" and rest and os.path.basename(rest[0]) in ("fm-duration.py", "fm-cpu-pass.py"):
            words = rest
            continue
        return False
    return False


INTERCEPT_PRIORITY_ENV = "FM_PIPELINE_START_PRIORITY"
INTERCEPT_TARGET = os.path.join(os.path.dirname(os.path.realpath(__file__)), "fm-cpu-pass.sh")


def _is_intercept_dir(entry: str) -> bool:
    link = os.path.join(entry, "no-mistakes")
    return os.path.islink(link) and os.path.basename(os.path.realpath(link)) == "fm-cpu-pass.sh"


def without_intercept(env: dict) -> dict:
    """env with every exec-interception directory (of any checkout) removed from PATH."""
    out = dict(env)
    out.pop(INTERCEPT_PRIORITY_ENV, None)
    if "PATH" in out:
        out["PATH"] = os.pathsep.join(entry for entry in out["PATH"].split(os.pathsep) if not (entry and _is_intercept_dir(entry)))
    return out


def intercept_dir() -> str:
    """This checkout's private directory holding one symlink named no-mistakes to fm-cpu-pass.sh.

    It lives in the user's temporary directory, never in the pool, is created
    0700 and used only when it is a real directory this user owns.
    """
    import hashlib
    digest = hashlib.sha256(INTERCEPT_TARGET.encode()).hexdigest()[:12]
    directory = os.path.join(tempfile.gettempdir(), "fm-exec-intercept-%d-%s" % (os.getuid(), digest))
    with contextlib.suppress(FileExistsError):
        os.mkdir(directory, 0o700)
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise OSError("%s is not a private directory of this user" % directory)
    link = os.path.join(directory, "no-mistakes")
    if not (os.path.islink(link) and os.readlink(link) == INTERCEPT_TARGET):
        temporary = "%s.%d" % (link, os.getpid())
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        os.symlink(INTERCEPT_TARGET, temporary)
        os.replace(temporary, link)
    return directory


def with_intercept(env: dict, priority: str) -> Optional[dict]:
    """COMMAND's environment for a route that admitted nothing: the interception first on PATH.

    A no-mistakes that COMMAND reaches through PATH, however it is wrapped
    (xargs, env -S, a shell variable, a script), then runs fm-cpu-pass.py
    exec-intercept, which judges the client's own argv by the fresh-run facts
    and admits a new run once, in this route's class. None when the
    interception cannot be placed (the reason is printed): the caller then
    holds the command as a start (intercept_unavailable_passes).
    """
    out = without_intercept(env)
    try:
        directory = intercept_dir()
    except OSError as exc:
        log(2, "pipeline-start: cannot place the no-mistakes exec interception (%s); the command is admitted as a "
               "fresh start, because a start inside it could not otherwise be judged" % exc)
        return None
    out["PATH"] = directory + (os.pathsep + out["PATH"] if out.get("PATH") else "")
    out[INTERCEPT_PRIORITY_ENV] = priority
    return out


def intercept_unavailable_passes(command: List[str]) -> bool:
    """Whether a command may still run unadmitted when the interception cannot be placed.

    Only the no-mistakes client itself, judged no new run by its own argv (a
    reattachment, response or status read), passes: whatever else a command
    runs could hide a fresh start that nothing can judge, so it is held.
    """
    return bool(command) and os.path.basename(command[0]) == "no-mistakes" and not fresh_pipeline_start(command)


def cmd_exec_intercept(args: argparse.Namespace) -> int:
    """Run as no-mistakes from the interception: admit a fresh start by its own argv, then exec the real client."""
    import shutil
    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    priority = os.environ.get(INTERCEPT_PRIORITY_ENV, "other")
    cleaned = without_intercept(dict(os.environ))
    real = shutil.which("no-mistakes", path=cleaned.get("PATH", ""))
    if real is None:
        log(2, "command not found: no-mistakes")
        return 127
    os.environ.clear()
    os.environ.update(cleaned)
    return cmd_pipeline_start(argparse.Namespace(
        command=[real] + command, only_fresh=True, intercepted=True,
        priority=priority if priority in PIPELINE_PRIORITIES else "other"))


def cmd_pipeline_start(args: argparse.Namespace) -> int:
    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        log(2, "pipeline-start needs a command after --")
        return 125
    environment = dict(os.environ)
    route = start_route(command)
    unplaced = False
    if args.only_fresh and route is None:
        # A reattachment, response, status read or other command that is no new run; a fresh start it
        # reaches through PATH in a form the parser does not model meets the exec interception.
        intercepted = environment if getattr(args, "intercepted", False) else with_intercept(environment, args.priority)
        if intercepted is not None or intercept_unavailable_passes(command):
            _restore_exec_signals()
            return exec_direct(command, without_intercept(environment) if intercepted is None else intercepted, 2)
        unplaced = True  # the interception cannot be placed (said once above): the command is held as one start
    # An admitted command that runs the client directly cannot begin a second run, so its client runs past the
    # interception; any other admitted command keeps the interception, so each further fresh client in it is
    # admitted on its own while the admitted client claims its own pending reservation (claim_pending).
    if unplaced or route is not None and runs_client_directly(command):
        child_environment = without_intercept(environment)
    else:
        child_environment = with_intercept(environment, args.priority) or without_intercept(environment)
    admission_fd = pending_fd = None
    pending_path = None

    def release_pending() -> None:
        nonlocal pending_fd, pending_path
        if pending_path is not None:
            for path in (pending_path, pending_path + ".claimed"):
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(path)
            pending_path = None
        if pending_fd is not None:
            os.close(pending_fd)
            pending_fd = None

    try:
        directory = pool_dir()
        ensure_pool_dir(directory)
        if route is not None:
            holder = claim_pending(directory, route[0])
            if holder is not None:
                log(2, "pipeline-start: this start was admitted by its enclosing start (pid %d); not queued again" % holder)
                _restore_exec_signals()
                return exec_direct(command, child_environment, 2)
        admission_fd, before, reason, _ = wait_for_admission(directory, args.priority)
        log(2, "pipeline-start admitted: " + reason)
        # In the same locked step as the admit, publish this start's pending reservation: every later decision
        # counts it at the full R until a new run registers for it or COMMAND returns. Then release the lock.
        pending_fd, pending_path = publish_locked(directory, "pending-", {
            "holder": os.getpid(), "args": None if route is None else list(route[0]),
            "before": sorted(before), "created_ns": time.time_ns()})
        fcntl.flock(admission_fd, fcntl.LOCK_UN)
        os.close(admission_fd)
        admission_fd = None
        registration_error = False

        def registered() -> bool:
            nonlocal registration_error
            try:
                running = set(running_runs())
                for path, _, done in live_pending(directory, running):
                    if path == pending_path:
                        if done:
                            # A new run registered for this start: the daemon's row now carries it.
                            release_pending()
                            return True
                        return False
                return False
            except (OSError, sqlite3.Error, ValueError) as exc:
                if not registration_error:
                    log(2, "cannot confirm startup registration; keeping the pending reservation until command returns: %s" % exc)
                    registration_error = True
            return False

        return run_child(command, child_environment, 2, registered)
    except KeyboardInterrupt:
        return 130
    except (PoolUnavailable, OSError, sqlite3.Error, ValueError, KeyError) as exc:
        # Unlike a burst's optional throughput pool, an unreadable start source
        # cannot stand in for proof of headroom under the explicit start policy.
        log(2, "pipeline-start refused: %s" % exc)
        return 125
    finally:
        release_pending()
        if admission_fd is not None:
            os.close(admission_fd)


NO_MISTAKES_CONFIG = "~/.no-mistakes/config.yaml"
# Not a limit of this gate: the daemon's own default budget when config.yaml sets no
# agent_timeout, read from config.DefaultAgentTimeout in the no-mistakes fork
# (internal/config/config.go:47; internal/pipeline/agent_run.go:23-27, fork commit 935aedf).
# measured: value=30m date=2026-11-03 host=Mac-Studio.local margin=1
DEFAULT_AGENT_TIMEOUT_SECS = 30 * 60
CI_FIX_QUANTILE = 0.99  # the contract's bound: budget minus the p99 of recorded CI-fix invocations


class LaunchRefused(Exception):
    """The gate cannot start the agent; the message names the cause and the next action."""

    def __init__(self, cause: str, detail: str, action: str):
        super().__init__(cause)
        self.cause, self.detail, self.action = cause, detail, action


def go_duration_secs(text: str) -> float:
    """Seconds in a Go duration such as 240m, 1h30m or 90s; ValueError otherwise."""
    import re
    units = {"h": 3600.0, "m": 60.0, "s": 1.0, "ms": 0.001}
    parts = re.findall(r"(\d+(?:\.\d+)?)(ms|h|m|s)", text)
    if not parts or "".join(number + unit for number, unit in parts) != text:
        raise ValueError("not a duration: %r" % text)
    return sum(float(number) * units[unit] for number, unit in parts)


def agent_budget_secs() -> Optional[float]:
    """The daemon's per-invocation agent budget from config.yaml, its default when unset, None when unreadable."""
    import re
    try:
        text = Path(NO_MISTAKES_CONFIG).expanduser().read_text()
        match = re.search(r'^agent_timeout:[ \t]*["\']?([^"\'\s#]+)', text, re.MULTILINE)
        return go_duration_secs(match.group(1)) if match else float(DEFAULT_AGENT_TIMEOUT_SECS)
    except (OSError, ValueError):
        return None


def ci_fix_p99_secs() -> Optional[float]:
    """The nearest-rank 99th percentile of completed CI-step agent invocation durations, or None.

    Only invocations that ended ok count: a refused launch, a timed-out or
    cancelled one is also recorded by the daemon, and counting it would let
    refusals and holds shrink the next bound.
    """
    try:
        values = [row[0] for row in read_host_db(
            "SELECT duration_ms FROM agent_invocations WHERE step_name = ? AND exit_status = 'ok' AND duration_ms > 0",
            (CI_STEP,))]
    except (OSError, sqlite3.Error, ValueError):
        return None
    return rank_quantile(values, CI_FIX_QUANTILE) / 1000.0 if values else None


def hold_bound() -> Tuple[float, str]:
    """How long a launch may wait for capacity inside the agent's own budget, and its inputs."""
    budget, p99 = agent_budget_secs(), ci_fix_p99_secs()
    if budget is None or p99 is None or budget - p99 <= 0:
        return 0.0, "hold_bound=0s budget=%s ci_fix_p99=%s" % (
            "unreadable" if budget is None else "%ds" % budget, "unreadable" if p99 is None else "%ds" % p99)
    return budget - p99, "hold_bound=%ds budget=%ds ci_fix_p99=%ds" % (budget - p99, budget, p99)


def map_worktree(cwd: str) -> Tuple[str, str, str]:
    """(run ID, repo ID, branch) of the one run whose worktree_dir is this directory, or LaunchRefused."""
    paths = sorted({cwd, os.path.realpath(cwd)})
    try:
        rows = read_host_db("SELECT DISTINCT id, repo_id, branch FROM runs WHERE worktree_dir IN (%s)"
                            % ",".join("?" * len(paths)), tuple(paths))
    except (OSError, sqlite3.Error, ValueError) as exc:
        raise LaunchRefused("run database unreadable", str(exc),
                            "restore read access to the run database; the next fix round enters the gate again")
    if not rows:
        raise LaunchRefused("unmapped worktree", "no run records %s" % cwd,
                            "launch the agent from a run worktree; a launch outside any run is not gated work")
    if len(rows) > 1:
        raise LaunchRefused("ambiguous worktree", "runs %s all record %s" % (",".join(r[0] for r in rows), cwd),
                            "resolve which run owns this worktree; the next fix round enters the gate again")
    return rows[0]


def durable_line(text: str, key: str) -> None:
    """Append one check wake to the root home's queue without waiting for its lock.

    When the queue lock is busy the wake is spilled to state/.wake-spill.<seq>,
    which the next append to that queue, or the watcher's next start, replays;
    a spill never replaces another producer's spill (fm_wake_pending_settle).
    """
    try:
        home = root_home()
        subprocess.run(["bash", "-c", '. "$1" && FM_WAKE_PENDING_KIND=check FM_WAKE_PENDING_KEY=$2 FM_WAKE_PENDING_PAYLOAD=$3'
                        ' && fm_wake_pending_settle', "bash",
                        str(Path(__file__).with_name("fm-wake-lib.sh")), key, "check: launch-gate: " + text],
                       env=dict(os.environ, FM_HOME=str(home)), stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        log(2, "launch-gate: durable line not recorded (%s): %s" % (exc, text))


def start_watched(command: List[str]) -> Tuple[int, int]:
    """Start the agent as this gate's child in its process group, with a watcher that kills it if the gate dies.

    macOS has no parent-death signal: a forked watcher blocks on a pipe only this
    gate can write. The agent's child process waits for a go byte before it
    execs, and the gate sends go only after the watcher holds the agent's pid, so
    there is no moment when an agent runs that the watcher cannot name: a gate
    that dies before go leaves a child that exits without starting the agent. A
    normal gate exit writes one byte to the watcher first; end-of-file without it
    means the gate died, and the watcher kills the agent at once, and the whole
    process group when the gate leads it, as the daemon's launch does.
    Returns (agent pid, watcher pipe); FileNotFoundError or PermissionError when
    the agent cannot be executed.
    """
    gate = os.getpid()
    read_end, write_end = os.pipe()
    watcher = os.fork()
    if watcher == 0:  # pragma: no cover - exercised through the executable
        try:
            os.close(write_end)
            null = os.open(os.devnull, os.O_RDWR)
            for fd in (0, 1, 2):
                os.dup2(null, fd)
            os.closerange(3, read_end)
            os.closerange(read_end + 1, 65536)
            for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(signum, signal.SIG_IGN)
            agent = int(os.read(read_end, 32).decode() or 0)
            if os.read(read_end, 1) != b"d":
                if agent:
                    with contextlib.suppress(OSError):
                        os.kill(agent, signal.SIGKILL)
                if os.getpgid(0) == gate:
                    with contextlib.suppress(OSError):
                        os.killpg(gate, signal.SIGKILL)
        finally:
            os._exit(0)
    os.close(read_end)
    go_read, go_write = os.pipe()
    error_read, error_write = os.pipe()
    child = os.fork()
    if child == 0:  # pragma: no cover - exercised through the executable
        try:
            os.close(go_write)
            os.close(error_read)
            os.close(write_end)
            _restore_default_signals()
            _restore_exec_signals()
            if os.read(go_read, 1) != b"g":
                os._exit(125)
            os.execvp(command[0], command)
        except OSError as exc:
            os.write(error_write, str(exc.errno).encode())
        finally:
            os._exit(127)
    for fd in (go_read, error_write):
        os.close(fd)
    os.write(write_end, str(child).encode().ljust(32))
    os.write(go_write, b"g")
    os.close(go_write)
    failure = os.read(error_read, 32)
    os.close(error_read)
    if failure:
        os.waitpid(child, 0)
        os.write(write_end, b"d")
        os.close(write_end)
        code = int(failure)
        raise (FileNotFoundError if code == errno.ENOENT else PermissionError)(code, os.strerror(code), command[0])
    return child, write_end


def cmd_launch_gate(args: argparse.Namespace) -> int:
    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        log(2, "launch-gate needs an agent command after --")
        return 125
    started = time.monotonic()
    run = branch = None
    try:
        cwd = os.getcwd()
        run, repo, branch = map_worktree(cwd)
        steps = open_steps()
        step = None if steps is None else steps.get(run)
        log(2, "launch-gate run=%s branch=%s step=%s agent_pid=%s attempt=%d:%d" % (
            run, branch, step[0] + ":" + step[1] if step else "unreadable" if steps is None else "none",
            step[2] if step else "none", os.getpid(), time.time_ns()))
        if step is not None and step[0] != CI_STEP:
            # Another step of a run already counted as active: unchanged, at once.
            _restore_exec_signals()
            return exec_direct(command, dict(os.environ), 2)
        directory = pool_dir()
        ensure_pool_dir(directory)
        bound, bound_text = hold_bound()
        held = []

        def on_wait(reason: str, waited: float) -> None:
            held.append(reason)
            durable_line("run %s (%s) held for capacity before its CI fix agent starts, waited %.2fs so far: %s; %s" % (
                run, branch, waited, reason, bound_text), "launch-gate-" + run)

        try:
            admission_fd, _, reason, waited = wait_for_admission(directory, "other", run, bound, on_wait)
        except HoldBound as reached:
            raise LaunchRefused("hold bound reached", "%s; held %ds; last reading: %s" % (
                bound_text, time.monotonic() - started, reached),
                "this fix attempt ends and the run keeps its CI step; the daemon retries while auto_fix.ci allows, then "
                "parks the CI findings as an ask-user decision; answer it once capacity has returned")
        admitted_ns = time.time_ns()
        reservation_fd = None
        try:
            reservation_fd, _ = publish_locked(directory, "launch-", {
                "run": run, "repo": repo, "pid": os.getpid(), "started_ns": admitted_ns})
            published_ns = time.time_ns()
            try:
                child, watch_fd = start_watched(command)
            except (FileNotFoundError, PermissionError, NotADirectoryError) as exc:
                # The shell's statuses for an agent that cannot be launched, reported unchanged.
                os.close(reservation_fd)
                log(2, "launch-gate: agent %s: %s" % ("not found" if isinstance(exc, FileNotFoundError) else "not executable", command[0]))
                return 127 if isinstance(exc, FileNotFoundError) else 126
            started_ns = time.time_ns()
        finally:
            os.close(admission_fd)
        unlocked_ns = time.time_ns()
        log(2, "launch-gate admitted: %s %s admitted_ns=%d published_ns=%d agent_started_ns=%d unlocked_ns=%d" % (
            reason, bound_text, admitted_ns, published_ns, started_ns, unlocked_ns))
        if held:
            durable_line("run %s (%s) admitted after %.2fs held: %s" % (run, branch, waited, reason), "launch-gate-" + run)
        return wait_agent(child, watch_fd, reservation_fd)
    except LaunchRefused as refused:
        text = "launch-gate refused: %s: run %s; %s; next action: %s" % (
            refused.cause, run or "unknown", refused.detail, refused.action)
        log(2, text)
        durable_line(text, "launch-gate-" + (run or "unmapped"))
        return 75
    except KeyboardInterrupt:
        return 130
    except (PoolUnavailable, OSError, sqlite3.Error, ValueError, KeyError) as exc:
        text = "launch-gate refused: gate error: run %s; %s; next action: repair the gate source named here; the next fix round enters the gate again" % (run or "unknown", exc)
        log(2, text)
        durable_line(text, "launch-gate-" + (run or "unmapped"))
        return 75


def wait_child(pid: int) -> int:
    """The agent's ending as subprocess reports it: its exit status, or minus the signal that ended it."""
    while True:
        _, status = os.waitpid(pid, 0)
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return -os.WTERMSIG(status)


def wait_agent(child: int, watch_fd: int, reservation_fd: int) -> int:
    """Forward signals to the agent, keep its reservation while it lives, and return or re-raise its own ending."""
    def forward(signum, _frame):
        with contextlib.suppress(OSError):
            os.kill(child, signum)

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, forward)
    try:
        code = wait_child(child)
    except BaseException:
        with contextlib.suppress(OSError):
            os.kill(child, signal.SIGKILL)
        with contextlib.suppress(OSError):
            os.waitpid(child, 0)
        raise
    finally:
        os.close(reservation_fd)
        with contextlib.suppress(OSError):
            os.write(watch_fd, b"d")
        os.close(watch_fd)
    if code < 0:
        signal.signal(-code, signal.SIG_DFL)
        os.kill(os.getpid(), -code)
    return code


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
    run.add_argument("command", nargs=argparse.REMAINDER, help="-- COMMAND [ARGS...]")
    start = sub.add_parser("pipeline-start", help="queue a fresh pipeline start before its execution clock")
    start.add_argument("--priority", choices=PIPELINE_PRIORITIES, default="other", help="start class in descending priority order")
    start.add_argument("--only-fresh", action="store_true", help="run COMMAND without admission unless it begins a new no-mistakes run")
    start.add_argument("command", nargs=argparse.REMAINDER, help="-- COMMAND [ARGS...]")
    intercept = sub.add_parser("exec-intercept", help="run as no-mistakes from a route's exec interception (internal)")
    intercept.add_argument("command", nargs=argparse.REMAINDER, help="-- ARGS of the no-mistakes client")
    gate = sub.add_parser("launch-gate", help="secure capacity for a CI fix agent before it starts (the agent launcher's final exec)")
    gate.add_argument("command", nargs=argparse.REMAINDER, help="-- AGENT [ARGS...]")
    status = sub.add_parser("status", help="report held and free passes")
    status.add_argument("--json", action="store_true", help="print one JSON object")
    sub.add_parser("size", help="print the pool size")
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
    if args.action == "exec-intercept":
        return cmd_exec_intercept(args)
    if args.action == "launch-gate":
        return cmd_launch_gate(args)
    if args.action == "status":
        return cmd_status(args)
    if args.action == "size":
        return cmd_size(args)
    parser.print_help(sys.stderr)
    return 125


if __name__ == "__main__":
    sys.exit(main())
