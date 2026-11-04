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
    in running, no recorded agent pid, no live launch reservation); its resident
    memory or A, whichever is larger, when the reading sees it; R while the
    reading cannot see it. S is the largest per-run peak of every recorded
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
    With --only-fresh, a COMMAND that fresh_pipeline_start does not judge a new
    run runs at once without admission. An admitted COMMAND receives
    FM_PIPELINE_START_ADMITTED, a digest of the new run's no-mistakes arguments
    as pipeline_start_arguments reads them; an inner route that would admit the
    identical invocation again runs it at once, and any other start still queues.
    Limit: a nested start the outer reading cannot see as the same one queues
    behind the outer start's lock: a -c string whose words the shell changes in
    a way this reading does not follow (an expansion such as ~, $VAR, $(...) or
    a glob, a here-document, an alias or a function), or a script that starts
    the run.
    When that nested start is the outer start's only run, the outer never
    registers a run, so the wait never ends until someone stops it, and every
    later fresh start on the host waits behind it.
  - A short start lock bridges the check-to-registration race until a new
    running run ID appears, or COMMAND returns. It does not reserve a run's
    lifetime or poll after registration; status changes release capacity.
    Participating starts serialize this handshake, not their required checks.
    A registered run whose process tree the reading cannot see yet reserves its
    full R in the next decision.
    Bypassing this owner or external daemon status changes cannot be made
    atomic with a read-only external database; deployment must route starts here.
  - An unreadable run database or CPU count refuses with 125 instead of
    guessing headroom. If a read fails after launch, retain the start lock until
    COMMAND returns; never stop running work because the observer lost its source.

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
    it uses none of the daemon's retry or fallback phrases. The first hold, an
    admission after a hold and every refusal also append one check wake
    (launch-gate-<run>) to the root home's wake queue through fm_wake_append.
  - AGENT keeps stdin, stdout and stderr; SIGTERM, SIGINT and SIGHUP sent to the
    gate are forwarded to it; its exit status is returned and a death by signal
    is re-raised. A missing or non-executable AGENT returns 127 or 126. A
    forked watcher, holding only a pipe the gate writes, SIGKILLs AGENT (and the
    process group the gate leads) if the gate dies without finishing; an
    internal error after the start kills AGENT before the gate exits.

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
from typing import List, Optional, Tuple

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


ADMITTED_ENV = "FM_PIPELINE_START_ADMITTED"


def start_digest(command: List[str]) -> Optional[str]:
    """A digest of the new run COMMAND begins (its no-mistakes arguments), or None when it begins none."""
    import hashlib
    arguments = pipeline_start_arguments(command)
    if arguments is None:
        return None
    return hashlib.sha256("\0".join(arguments).encode("utf-8", "replace")).hexdigest()


def already_admitted(command: List[str], env: dict) -> bool:
    """Whether an enclosing admission already admitted this same start.

    pipeline-start exports a digest of the start it admitted to COMMAND. A wrapper
    inside that COMMAND which routes the identical no-mistakes invocation to
    admission again (for example fm-mem-guard.sh run inside fm-duration.py run)
    is that one start, not a second, so it runs without queueing again; any other
    fresh start, nested or not, has another digest and still queues.
    """
    marker = env.get(ADMITTED_ENV)
    return marker is not None and marker == start_digest(command)


def fresh_pipeline_start(command: List[str]) -> bool:
    """Whether COMMAND begins a new no-mistakes run (see pipeline_start_arguments)."""
    return pipeline_start_arguments(command) is not None


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


def shell_string_start(string: str) -> Optional[List[str]]:
    """The first new run that one of the simple commands of a shell command string begins, if any.

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
            arguments = pipeline_start_arguments(simple)
            if arguments is not None:
                return arguments
            simple, target = [], False
        elif target:
            target = False
        else:
            simple.append(word)
    return None


def pipeline_start_arguments(command: List[str]) -> Optional[List[str]]:
    """The no-mistakes arguments of the new run COMMAND begins, or None, judged by the facts the CLI itself uses.

    `no-mistakes rerun` always creates a new run. `no-mistakes axi run` creates one
    only with an intent input (--intent TEXT, --intent -, --intent-file PATH or
    their = forms); without one it reattaches an active run or exits 2. The
    no-mistakes binary is found at any position and by basename, so a wrapper
    prefix (env, fm-mem-guard.sh run --, an absolute path) does not hide it; a
    shell's -c string, after the shell's other options, is read as a command line
    without its comments and redirections, split at its control operators and
    newlines; other arguments are data. respond, status
    and every other subcommand are not starts. This one reading decides both
    whether a command is a start and the digest of the start an admission exports.
    """
    for index, part in enumerate(command):
        name = os.path.basename(part)
        if name == "no-mistakes":
            rest = command[index + 1:]
            fresh = rest[:1] == ["rerun"] or rest[:2] == ["axi", "run"] and any(
                option in INTENT_OPTIONS or option.startswith(tuple(intent + "=" for intent in INTENT_OPTIONS))
                for option in rest[2:])
            return rest if fresh else None
        if name in SHELLS:
            string = shell_command_string(command, index)
            if string is not None:
                # A shell's -c string is a command line; any other argument is data, such as a commit message.
                return shell_string_start(string)
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
    """Each running run's open step as (step name, status, recorded agent pid), or None when unreadable.

    The open step is the highest-ordered step_results row in running or fixing.
    A run with no such row is absent. None never reads as idle: every run then
    keeps its full reservation.
    """
    try:
        rows = read_host_db(
            "SELECT s.run_id, s.step_name, s.status, s.agent_pid FROM step_results s JOIN runs r ON r.id = s.run_id"
            " WHERE r.status = 'running' AND s.status IN ('running', 'fixing') ORDER BY s.run_id, s.step_order")
    except (OSError, sqlite3.Error, ValueError):
        return None
    return {run: (name, status, pid) for run, name, status, pid in rows}


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


def project(available: int, rss: dict, counted: dict, steps: Optional[dict], launches: dict,
            reservation: int, slack: int, term: int, self_run: Optional[str] = None) -> dict:
    """The reservation fit for one more active run; a pure function of its facts.

    counted maps each counted run ID to its repo ID; rss is the reading's run map
    (keyed no-mistakes:<repo>/<run>); steps is open_steps() or None; launches maps
    run IDs to their live launch-gate reservations. A run waiting on remote CI
    (open step ci, status running, no recorded agent pid, no live launch) reserves
    only the memory it holds. Every other counted or launched run reserves its
    resident memory or the active-run term A, whichever is larger, once its tree
    is visible, and its full R while the reading cannot see it yet. The new run
    reserves S. The waiting launch's own run (self_run) is a waiter: it adds only
    what it holds. Budget is available memory plus what the counted runs hold.
    """
    entries = []
    runs = dict(counted)
    for run, entry in launches.items():
        runs.setdefault(run, entry.get("repo"))
    held = 0
    for run in sorted(runs):
        seen = rss.get("no-mistakes:%s/%s" % (runs[run], run))
        size = seen["rss_bytes"] if seen and type(seen.get("rss_bytes")) is int else 0
        visible = bool(seen) and seen.get("processes", 0) > 0
        step = None if steps is None else steps.get(run)
        held += size
        if run == self_run:
            kind, demand = "waiter", size
        elif run in launches:
            kind = "launched"
            demand = max(size, term) if visible else reservation
        elif steps is not None and step is not None and step[0] == CI_STEP and step[1] == "running" and step[2] is None:
            kind, demand = "ci-waiting", size
        else:
            kind = "step-unreadable" if steps is None else ("no-open-step" if step is None else "active")
            demand = max(size, term) if visible else reservation
        entries.append((run, kind, demand, visible))
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
              measured: Optional[Tuple[Tuple[int, int, int], Tuple[int, int]]] = None) -> Tuple[bool, str]:
    """The complete admission rule over one reading's facts: holds first, then the fit or the count fallback.

    measured, when given, supplies ((R, S, runs measured), (A, readings measured))
    instead of reading the records; the P4 replay passes the copied records here.
    """
    others = len([run for run in set(counted) | set(launches) if run != self_run])
    if reasons:
        return False, "overload: %s counted=%d priority=%s" % ("; ".join(reasons), len(counted), priority)
    if measured is None and report is not None:
        reserved, term = measured_reservations(report, running), active_term(report)
        measured = (reserved, term) if reserved is not None and term is not None else None
    if measured is None:
        limit = max(1, cores // 3)
        return others < limit, "counted=%d limit=%d basis=fallback priority=%s" % (others, limit, priority)
    (reservation, slack, qualifying), (term, readings) = measured
    fit = project(report["available_bytes"], report["runs"], counted, steps, launches, reservation, slack, term, self_run)
    return fit["admit"], projection_text(fit, reservation, slack, term, qualifying, readings) + " priority=%s" % priority


def decide(running: dict, counted: dict, cores: int, priority: str, fresh: bool = False,
           directory: Optional[str] = None, self_run: Optional[str] = None) -> Tuple[bool, str]:
    """(admit, one-line reason) for the first waiter, from the running and counted runs and the host reading."""
    seen = host_observation(fresh)
    launches = live_launches(directory) if directory else {}
    steps = open_steps() if seen["memory"] is not None else None
    return admission(seen["reasons"], seen["memory"], running, counted, steps, launches, cores, priority, self_run)


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


def publish_locked(directory: str, prefix: str, entry: dict) -> Tuple[int, str]:
    """Write a locked JSON entry and rename it into place, so no reader sees it unlocked or partial."""
    fd, temporary = tempfile.mkstemp(prefix="." + prefix, dir=directory)
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.set_inheritable(fd, False)
    os.write(fd, json.dumps(entry).encode())
    final = str(Path(directory) / (Path(temporary).name[1:] + ".lock"))
    os.rename(temporary, final)
    return fd, final


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


class HoldBound(Exception):
    """A launch reached its hold bound without a fit."""


def wait_for_admission(directory: str, priority: str, self_run: Optional[str] = None,
                       bound: Optional[float] = None, on_wait=None):
    """Queue one locked waiter entry in class order until admitted; return (start lock fd, before, reason, waited).

    The start lock is held on return. A bound in seconds raises HoldBound with the
    last reason once that long passed without a grant; None waits without limit.
    on_wait(reason) is called once, at the first wait that is not the registration handshake.
    """
    waiter_fd = admission_fd = None
    waiter_path = None
    started = time.monotonic()
    try:
        # Publish a fully written, locked entry atomically; no reader sees a
        # partial priority record. These are startup waiters, not CPU passes.
        waiter_fd, waiter_path = publish_locked(directory, "pipeline-waiter-", {
            "priority": priority, "queued_ns": time.time_ns(), "run": self_run})
        admission_fd = open_lock(os.path.join(directory, "pipeline-start.lock"))
        next_notice = started + FIRST_NOTICE_SECS
        delay = POLL_MIN_SECS
        while True:
            reason = "another start is registering"
            if try_lock(admission_fd):
                before, cores = pipeline_observation()
                counted = {run: repo for run, (repo, is_counted, _) in before.items() if is_counted}
                first = first_pipeline_waiter(directory)
                if first == waiter_path:
                    admit, reason = decide(before, counted, cores, priority, directory=directory, self_run=self_run)
                    if admit:
                        # A cached healthy reading may be stale: confirm with a new reading at the grant.
                        admit, reason = decide(before, counted, cores, priority, fresh=True, directory=directory,
                                               self_run=self_run)
                    if admit:
                        result = (admission_fd, before, reason, time.monotonic() - started)
                        admission_fd = None
                        return result
                else:
                    reason = "counted=%d priority=%s behind a higher-priority or earlier start" % (len(counted), priority)
                fcntl.flock(admission_fd, fcntl.LOCK_UN)
                if on_wait is not None:
                    on_wait(reason)
                    on_wait = None
            now = time.monotonic()
            if bound is not None and now - started >= bound:
                raise HoldBound(reason)
            if now >= next_notice:
                log(2, "%s waiting: %s" % ("launch-gate" if self_run else "pipeline-start", reason))
                next_notice = now + NOTICE_EVERY_SECS
            time.sleep(delay)
            delay = min(POLL_MAX_SECS, delay * 2)
    finally:
        if waiter_path is not None:
            try:
                os.unlink(waiter_path)
            except FileNotFoundError:
                pass
        for fd in (waiter_fd, admission_fd):
            if fd is not None:
                os.close(fd)


def cmd_pipeline_start(args: argparse.Namespace) -> int:
    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        log(2, "pipeline-start needs a command after --")
        return 125
    environment = dict(os.environ)
    if already_admitted(command, environment) or (args.only_fresh and not fresh_pipeline_start(command)):
        # Already admitted by an enclosing owner, or (with --only-fresh) a
        # reattachment, response, status read or other command that is no new run.
        return exec_direct(command, environment, 2)
    digest = start_digest(command)
    if digest is not None:
        environment[ADMITTED_ENV] = digest
    admission_fd = None
    try:
        directory = pool_dir()
        ensure_pool_dir(directory)
        admission_fd, before, reason, _ = wait_for_admission(directory, args.priority)
        log(2, "pipeline-start admitted: " + reason)
        registration_error = False

        def registered() -> bool:
            nonlocal registration_error
            try:
                running = running_runs()
                new_runs = running.keys() - before.keys()
                if new_runs:
                    # Serialize only the check-to-registration gap. The daemon
                    # owns status after this handoff; no lifetime watcher remains.
                    fcntl.flock(admission_fd, fcntl.LOCK_UN)
                    return True
            except (OSError, sqlite3.Error, ValueError) as exc:
                if not registration_error:
                    log(2, "cannot confirm startup registration; retaining start lock until command returns: %s" % exc)
                    registration_error = True
            return False

        return run_child(command, environment, 2, registered)
    except KeyboardInterrupt:
        return 130
    except (PoolUnavailable, OSError, sqlite3.Error, ValueError, KeyError) as exc:
        # Unlike a burst's optional throughput pool, an unreadable start source
        # cannot stand in for proof of headroom under the explicit start policy.
        log(2, "pipeline-start refused: %s" % exc)
        return 125
    finally:
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
    """Append one check wake to the root home's queue, which supervision drains; never blocks the launch decision."""
    try:
        home = root_home()
        subprocess.run(["bash", "-c", '. "$1" && fm_wake_append check "$2" "$3"', "bash",
                        str(Path(__file__).with_name("fm-wake-lib.sh")), key, "check: launch-gate: " + text],
                       env=dict(os.environ, FM_HOME=str(home)), stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        log(2, "launch-gate: durable line not recorded (%s): %s" % (exc, text))


def start_watched(command: List[str]) -> Tuple[subprocess.Popen, int]:
    """Start the agent as this gate's child in its process group, with a watcher that kills it if the gate dies.

    macOS has no parent-death signal: a forked watcher blocks on a pipe only this
    gate can write. A normal gate exit writes one byte first; end-of-file without
    it means the gate died, and the watcher kills the agent at once (its whole
    process group when the gate leads that group, as the daemon's launch does).
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
            if os.read(read_end, 1) != b"d" and agent:
                with contextlib.suppress(OSError):
                    os.kill(agent, signal.SIGKILL)
                if os.getpgid(0) == gate:
                    with contextlib.suppress(OSError):
                        os.killpg(gate, signal.SIGKILL)
        finally:
            os._exit(0)
    os.close(read_end)
    try:
        child = subprocess.Popen(command, close_fds=True, preexec_fn=_restore_default_signals)
    except OSError:
        os.write(write_end, b"0".ljust(32) + b"d")
        os.close(write_end)
        raise
    os.write(write_end, str(child.pid).encode().ljust(32))
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
            return exec_direct(command, dict(os.environ), 2)
        directory = pool_dir()
        ensure_pool_dir(directory)
        bound, bound_text = hold_bound()
        held = []

        def on_wait(reason: str) -> None:
            held.append(reason)
            durable_line("run %s (%s) held for capacity before its CI fix agent starts: %s; %s" % (
                run, branch, reason, bound_text), "launch-gate-" + run)

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
            except (FileNotFoundError, PermissionError) as exc:
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
            durable_line("run %s (%s) admitted after %ds held: %s" % (run, branch, waited, reason), "launch-gate-" + run)
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


def wait_agent(child: subprocess.Popen, watch_fd: int, reservation_fd: int) -> int:
    """Forward signals to the agent, keep its reservation while it lives, and return or re-raise its own ending."""
    def forward(signum, _frame):
        with contextlib.suppress(OSError):
            os.kill(child.pid, signum)

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, forward)
    try:
        while True:
            try:
                code = child.wait()
                break
            except InterruptedError:  # pragma: no cover - PEP 475 retries
                continue
    except BaseException:
        with contextlib.suppress(OSError):
            child.kill()
        child.wait()
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
