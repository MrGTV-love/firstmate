#!/usr/bin/env python3
"""
fm-cpu-pass.py - host-wide CPU pass pool for CPU-heavy test bursts.

Usage:
  fm-cpu-pass.sh run [--passes K] [--label TEXT] [--log-fd N] [--wait-file PATH] -- COMMAND [ARGS...]
  fm-cpu-pass.sh pipeline-start [--priority CLASS] [--only-fresh] -- COMMAND [ARGS...]
  fm-cpu-pass.sh launch-gate -- AGENT [ARGS...]
  fm-cpu-pass.sh activate --gate GATE_FILE
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
    The guard is started before COMMAND and has said it is ready before COMMAND
    starts, never after: no moment exists in which COMMAND runs and nothing but its
    starter holds the passes. COMMAND writes its own pid into the pipe the guard
    reads, between fork and exec, so the guard knows it whatever happens to the
    starter or to COMMAND's descriptors. When the guard cannot be started or dies
    before it is ready, or the token directory cannot be created, the passes are
    returned and COMMAND runs without one with FM_CPU_PASS_HELD=0, said once. A nested
    request that cannot lease (no file locks) runs under the inherited marker and says so once.
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
    in running, no held attempt record, and positive proof that no agent
    lives: no process of it is visible, and its recorded agent pid is absent
    or dead; a visible tree keeps A whatever its processes are named and
    whatever its recorded pid) or while its launch gate waits in
    this queue with no held attempt record; its resident memory or A,
    whichever is larger, when the reading sees it; R while the reading cannot see it.
    Beside that, each run created after activation whose launch history is not
    shown complete is charged one more R (history_units). A history is complete only when the pool's
    gate-activation.json (activated_at and gate_sha256, written once by
    `activate`) is dated before the run's creation, every invocation row of the
    run names a gated agent, and its rows and attempt records bind one to one by
    session key. A run created before activation (every run while no record
    exists) is instead charged the larger of its demand and R while it is
    counted, queued or holds an attempt. Until activation exists and every such
    run has left the census, a start is also admitted when the base rule admits
    it (base_rule: (counted + pending + 1) x R + S against available plus each
    counted run's resident memory up to R), so the interim is never stricter
    than the base rule; after that the projection stands alone. S is the largest per-run peak of every recorded
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
    of a grant (both backstop signals included). With no qualifying reading for A,
    A is R, so every visible active run counts at least R. With fewer than 2
    recorded runs left to rank for R, or no native memory facts on this platform,
    the start falls back to counted < max(1, floor(logical CPUs / 3)); a missing
    record never refuses a start and never reads as an empty host.
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
    first on PATH (fm-mem-guard.sh run, and fm-duration.py run under any
    key): a
    private 0700 directory in the user's temporary directory holding one
    symlink named no-mistakes to fm-cpu-pass.sh, which runs exec-intercept: it
    judges the client's own argv by the same facts, admits a new run in the
    route's class (FM_PIPELINE_START_PRIORITY), and runs the real client with
    every such directory removed from PATH. An admitted command keeps the
    interception unless it runs the client directly (runs_client_directly), so
    each further fresh client in it is admitted on its own. When the directory
    cannot be placed the route says why; a command no word of which names
    no-mistakes, and the no-mistakes client itself on a call that is no new
    run, runs at once, and any other command is held as one start. Limit: a fresh start no wrapper here can see, the real client called
    by its absolute path past the interception, a PATH reset (sudo, env -i) or a
    start outside every route, is admitted only by run-creation admission in
    the no-mistakes fork (backlog task nm-run-creation-admission).
  - The start lock serializes each decision with the publication of its
    admitted start's pending reservation (a locked pending-*.lock naming the
    admitting pid, the admitted no-mistakes arguments and where they were
    read from: real arguments, a shell's command string, which the shell
    expands later, or an env -S string (ENV_SPLIT), the running run IDs of the decision and the start's
    binding, read from the directory its client runs in: the admitting one, or
    the one env -C/--chdir names), then is released. Every later decision counts each
    admitted start at the full R, and as one run in the count fallback and the
    one-start minimum (live_pending), except while a run that decision counts
    as active is on the repository and branch the start was bound to when it
    was admitted or claimed (start_binding; pending_census). The daemon keeps
    one active run per repository and branch (it cancels the old run and waits
    for it to end before it writes the new row), and a client with no launch
    nonce reattaches to that branch's active run, so that run is the one the
    start's client drives or replaces. A covered start adds nothing only when
    it is a proven reattach (proven_reattach): `axi run` with no --launch-nonce
    whose recorded HEAD is the run's head_sha or submitted_head_sha. Every other
    covered start (a rerun, a caller's own --launch-nonce, a HEAD that differs
    or is not known, a word read from a shell's command string that the shell
    expands later, which may hide a nonce, and every start through env -S,
    whose escapes and ${VAR} the admission does not read as env does, whatever
    its words hold; a word of a real argument vector is never refused for its
    characters) may replace the run, whose own charge can be far below R
    (a CI waiter is charged what it holds), so the branch carries the larger
    of the run's demand and R, once per branch however many such starts it
    has. The cost: while such a start's command runs, a run it only drives is
    charged R rather than the larger of its size and A, an overcharge, never
    an undercount; the exact rule needs a launch identity in the no-mistakes
    fork. Coverage is read again at every decision: in the gap between a
    replaced run's end and its replacement's row, or once the run is CI-ready,
    parked or ended, the start counts at R again. A start with no binding (a directory that is no registered
    repository's, a detached HEAD) is covered by no run; its client starts no
    run there, so it is charged once, by its reservation. A pending start ends
    when its COMMAND returns, or when the client that claimed it through the
    interception has exited (K7; its run, if any, is then in the run database).
    It does not reserve a run's lifetime; status changes release capacity. A
    registered run whose process tree the reading cannot
    see yet reserves its full R in the next decision.
    The admitted client itself, reached through a nested route or the
    interception, claims its own pending start (claim_pending): same arguments,
    (same_start_args), the admitting pid among its ancestors, and either unclaimed or claimed by
    itself or an ancestor, and every run created since its admission covers
    another start; it runs
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
  - A run database that cannot be opened at all (missing, unreadable or not
    SQLite) or an unreadable CPU count refuses with 125 instead of guessing
    headroom; a failed read of the run rows of a database that opens, such as
    a locked one, waits with a named reason (pipeline_observation). If a read
    fails after launch, keep the pending
    reservation until COMMAND returns; never stop running work because the
    observer lost its source.

Launch gate:
  - `launch-gate -- AGENT [ARGS...]` is the no-mistakes agent launcher's final
    exec. It first maps its working directory to exactly one runs.worktree_dir
    (the directory or its real path). A directory that is no run's worktree but
    a registered repository's checkout (repos.working_path, the attach wizard)
    execs AGENT unchanged; none, more than one, or an unreadable database
    refuses. A step it cannot establish (step facts unreadable, no open step,
    an unrecognized step name) refuses. A counted run's launch at a step other
    than ci starts AGENT at once with no hold, as a watched child whose passive
    attempt record is published under the start lock. Every other launch (ci,
    or any step of a run that is not counted) queues as a pipeline-start waiter
    in class other and asks the same rule for one more active run, its own run
    counted as a waiter. On a grant, still under the start lock, it publishes
    the attempt's record (attempt-*.json in the pool, rewritten whole through a
    temporary file), starts AGENT at once as its child in its own process group,
    then releases the lock; it never waits for AGENT to appear in memory. An
    attempt is held while a process of it is proven or possibly alive, and ends
    only when two successive censuses in one decision show none. Held records of
    one run that share one session key (a resumed session) are one attempt and
    are charged once; each other held attempt reserves its own R (A once
    visible). A refusal also comes from an attempt that cannot be recorded
    (process facts unreadable) and a first hold whose wake cannot be written
    (hold line not recorded).
  - Hold bound: the daemon's per-invocation budget (agent_timeout in
    ~/.no-mistakes/config.yaml, else the daemon's 30-minute default) minus the
    nearest-rank 99th percentile of completed (exit_status ok) agent_invocations
    durations of step ci; no hold when that is not positive or either input is
    unreadable. Only completed invocations count (Main 3210): the daemon also
    records refused and held launches and timed-out runs as step ci, and
    counting them would let holds shrink their own bound and pull it to zero
    (on this host 2026-11-03: ok rows p99 152.45 min, bound about 87.5 min of
    240; all rows 156.83 min, about 83.2 min). At the bound, or on any refusal, it does not start AGENT,
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

Activation:
  - `activate --gate GATE_FILE` is the deployment step that follows the
    launcher line. It writes the pool's gate-activation.json once, with
    activated_at (now, epoch seconds) and gate_sha256 (the sha256 of
    GATE_FILE), through a temporary file hard-linked into place, so it never
    replaces a record. It writes nothing and exits 1 with one "activate
    refused: <reason>" line when the record exists, GATE_FILE cannot be read,
    the waiters cannot be read, a live waiter of the earlier engine (an entry
    with no pid) is queued, or the pool cannot be used or written; on success
    it prints the record.

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
import shutil
import signal
import sqlite3
import stat
import tempfile
import subprocess
import sys
import time
from typing import Dict, List, Optional, Tuple, Union

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

    It is started BEFORE the command and has said it is ready before the command is started, so no moment
    exists in which a command runs and nothing but its starter holds the passes. The command inherits the
    write end of a pipe the guard reads and writes its OWN pid into it (announce, run in the command's
    process between fork and exec), so the guard knows the command no matter what happens to the starter
    or to the command's descriptors afterwards. The guard then polls that pid. A command that was never
    heard from leaves the guard reading a pipe only the command still holds, so the guard keeps the passes
    until the command, and any process that inherited the pipe, ends: never shorter than the command lives.
    """

    def __init__(self, child: "subprocess.Popen", write_fd: int) -> None:
        self.child = child
        self.write_fd = write_fd

    def inherit(self) -> Tuple[int, ...]:
        return (self.write_fd,) if self.write_fd >= 0 else ()

    def announce(self) -> None:
        """Runs in the command's own process before its exec: tell the guard which pid it keeps the passes for."""
        try:
            os.write(self.write_fd, ("%d\n" % os.getpid()).encode())
        except OSError:
            pass  # the guard then waits for the pipe to close, which is when the command and its inheritors end

    def close_write(self) -> None:
        if self.write_fd >= 0:
            try:
                os.close(self.write_fd)
            except OSError:
                pass
            self.write_fd = -1

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
    """Start the guard of the passes FDS before their command exists and wait until it is ready; None when there is nothing to hold.

    The guard is `fm-cpu-pass.py guard`: a fresh interpreter that inherits only FDS and its two pipes, ignores
    TERM, INT and HUP, tells the starter it is ready, and removes TOKENS (the reservation's token directory)
    once the command is gone. It raises OSError when the guard cannot be started or exits before it is ready;
    the caller then does not run the command under the passes (the protocol's degrade rule) and never leaves
    the command running with nothing keeping them.
    """
    if not fds:
        return None
    read_fd, write_fd = os.pipe()
    ready_read, ready_write = os.pipe()
    try:
        child = subprocess.Popen(
            [sys.executable or "python3", os.path.abspath(__file__), "guard", "--fd", str(read_fd), "--ready-fd", str(ready_write), "--tokens", tokens],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            close_fds=True, pass_fds=tuple(fds) + (read_fd, ready_write), preexec_fn=_ignore_signals)
    except BaseException:
        for fd in (read_fd, write_fd, ready_read, ready_write):
            os.close(fd)
        raise
    os.close(read_fd)
    os.close(ready_write)
    try:
        ready = os.read(ready_read, 1) == b"R"  # the guard's word, or the end of the pipe when it died first
    finally:
        os.close(ready_read)
    if not ready:
        os.close(write_fd)
        child.wait()
        raise OSError(errno.EIO, "the pass guard exited before it was ready")
    return Guard(child, write_fd)


def stop_guard(guard: Optional[Guard]) -> None:
    if guard is not None:
        guard.stop()


def cmd_guard(args: argparse.Namespace) -> int:
    """Internal: say ready, then hold the inherited pass descriptors until the command named on the pipe ends."""
    try:
        os.write(args.ready_fd, b"R")
        os.close(args.ready_fd)
    except OSError:
        return 1
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


def spawn_after_go(command: List[str], env: dict) -> Tuple[int, int, int]:
    """Fork COMMAND's child, which waits for one go byte before it execs; return (pid, go pipe, error pipe).

    Closing the go pipe without the byte makes the child exit 125 without
    starting COMMAND. FileNotFoundError or PermissionError when it cannot be
    executed (reported after go).
    """
    go_read, go_write = os.pipe()
    error_read, error_write = os.pipe()
    os.set_inheritable(error_write, False)
    child = os.fork()
    if child == 0:  # pragma: no cover - exercised through the executable
        try:
            os.close(go_write)
            os.close(error_read)
            _restore_default_signals()
            if os.read(go_read, 1) != b"g":
                os._exit(125)
            os.closerange(3, error_write)
            os.closerange(error_write + 1, 65536)
            os.execvpe(command[0], command, env)
        except OSError as exc:
            with contextlib.suppress(OSError):
                os.write(error_write, str(exc.errno).encode())
        finally:
            os._exit(127)
    os.close(go_read)
    os.close(error_write)
    return child, go_write, error_read


def run_child(command: List[str], env: dict, log_fd: int, on_poll=None, cancellable: bool = False, guard: Optional[Guard] = None) -> int:
    """Run COMMAND as a child, keep it in the caller's group, and return its exit status.

    While the child runs, SIGTERM, SIGINT and SIGHUP are ignored here, so running
    work is never cut short. With cancellable (a pipeline start), a signal that
    arrives before COMMAND begins cancels it instead: the signals are recorded
    from before the child is forked, the child waits for a go byte before it
    execs, and a signal recorded by then closes the pipe, so the child exits
    without starting COMMAND and this returns 128+n.
    """
    previous = {}
    received: List[int] = []
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        previous[signum] = signal.signal(signum, (lambda number, _frame: received.append(number)) if cancellable else signal.SIG_IGN)
    try:
        if cancellable:
            if received:
                return 128 + received[0]
            pid, go_write, error_read = spawn_after_go(command, env)
            if received:
                os.close(go_write)
                os.close(error_read)
                os.waitpid(pid, 0)
                return 128 + received[0]
            for signum in previous:
                signal.signal(signum, signal.SIG_IGN)
            os.write(go_write, b"g")
            os.close(go_write)
            failure = os.read(error_read, 32)
            os.close(error_read)
            if failure:
                os.waitpid(pid, 0)
                missing = int(failure) == errno.ENOENT
                log(log_fd, "command %s: %s" % ("not found" if missing else "not executable", command[0]))
                return 127 if missing else 126
            polled = 0.0
            while True:
                if on_poll is not None and polled <= 0 and on_poll():
                    on_poll = None
                finished, status = os.waitpid(pid, 0 if on_poll is None else os.WNOHANG)
                if finished:
                    return exit_code_for(os.waitstatus_to_exitcode(status))
                # The registration poll runs every POLL_MAX_SECS; the exit is seen within POLL_MIN_SECS.
                polled = polled - POLL_MIN_SECS if polled > 0 else POLL_MAX_SECS - POLL_MIN_SECS
                time.sleep(POLL_MIN_SECS)
        try:
            def start_command() -> None:
                if guard is not None:
                    guard.announce()
                _restore_default_signals()
            child = subprocess.Popen(
                command, env=env, close_fds=True,
                pass_fds=guard.inherit() if guard is not None else (),
                preexec_fn=start_command)
        except FileNotFoundError:
            log(log_fd, "command not found: %s" % command[0])
            return 127
        except PermissionError:
            log(log_fd, "command not executable: %s" % command[0])
            return 126
        if guard is not None:
            guard.close_write()  # the command has told the guard its pid; only the command holds the pipe now
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
    if fcntl is None:
        # Rule 7 for a nested request too: no file locks, so no lease; the work runs and the one notice is said.
        log(log_fd, "running %s without leasing from its reservation: this platform has no fcntl file locks" % label)
        write_wait(wait_file, queued_at)
        return exec_direct(command, env, log_fd)
    try:
        leased = acquire(tokens, held_count, passes, label, log_fd)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:  # OSError, or any failure of the token directory: the work still runs, said once
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
INTENT_OPTIONS = ("--intent", "--intent-file")
SHELLS = ("sh", "bash", "zsh", "dash", "ksh")
ENV_SPLIT = "env-S"  # where a start's arguments were read from: an env -S string (start_route; proven_reattach)
SHELL_OPERATOR_CHARS = "();<>|&\n"


# Wrappers that run their operand as the program: (short options that take a value, long options that do).
# env -S/--split-string's value is a command line whose words take its place; env -C/--chdir's value is the directory
# the program runs in.
TRANSPARENT = {"env": ("uCPS", ("--unset", "--chdir", "--split-string")), "nice": ("n", ("--adjustment",)),
               "nohup": ("", ()), "command": ("", ()), "exec": ("a", ()), "time": ("of", ("--output", "--format")),
               "stdbuf": ("ioe", ("--input", "--output", "--error"))}
ROUTES = ("fm-mem-guard.sh", "fm-duration.py", "fm-cpu-pass.sh", "fm-cpu-pass.py")


def wrapper_operands(name: str, rest: List[str]) -> Optional[Tuple[List[str], Optional[str], Optional[str]]]:
    """(the words wrapper NAME runs as its program, an env split string to read first, the env -C directory it runs
    them in), or None when it runs none.

    Short options may be clustered and a valued one takes the rest of its word
    or the next word; a long option takes its =value or the next word. env also
    skips NAME=value words and a lone -. command -v and -V only print where the
    program is, so they run nothing.
    """
    short, valued = TRANSPARENT[name]
    chdir = None
    while rest:
        word = rest[0]
        if word == "--":
            return rest[1:], None, chdir
        if name == "env" and (word == "-" or not word.startswith("-") and "=" in word):
            rest = rest[1:]
            continue
        if not word.startswith("-") or word == "-":
            return rest, None, chdir
        rest = rest[1:]
        if word.startswith("--"):
            option, equals, value = word.partition("=")
            if option in valued and not equals:
                value, rest = (rest[0] if rest else ""), rest[1:]
            if option == "--split-string":
                return rest, value, chdir
            if name == "env" and option == "--chdir":
                chdir = value
            continue
        for index, letter in enumerate(word[1:], 1):
            if name == "command" and letter in "vV":
                return None
            if letter in short:
                value = word[index + 1:]
                if not value:
                    value, rest = (rest[0] if rest else ""), rest[1:]
                if name == "env" and letter == "S":
                    return rest, value, chdir
                if name == "env" and letter == "C":
                    chdir = value
                break
    return rest, None, chdir


def fresh_pipeline_start(command: List[str]) -> bool:
    """Whether COMMAND begins a new no-mistakes run (see start_route)."""
    return start_route(command) is not None


def start_route(command: List[str]) -> Optional[Tuple[List[str], bool, Union[bool, str], Optional[str]]]:
    """(no-mistakes arguments, whether another admission route sits in between, where the arguments were read from
    (False: real arguments; True: a shell's command string, which the shell expands later; ENV_SPLIT: an env -S
    string, which env reads with its own escapes and ${VAR}, at any depth), the directory the client runs in relative
    to this one (env -C/--chdir), or None for this one) of the new run COMMAND begins, or None.

    Only the executable position counts: leading VAR=value words, the
    transparent wrappers env, nice, nohup, command, exec, time and stdbuf with
    their options (wrapper_operands; env -S/--split-string's words read in its
    place, env -C/--chdir's directory joined onto the client's), a Python
    interpreter or a shell running a script, a shell's -c string
    (read as a command line, see shell_string_start) and the admission routes
    fm-mem-guard.sh run --, fm-duration.py run KEY -- and fm-cpu-pass pipeline-start --
    are followed to the program they run. Any other program's arguments are data,
    so `printf no-mistakes axi run --intent x` is not a start. `no-mistakes rerun`
    always creates a new run; `no-mistakes axi run` creates one only with an intent
    input (--intent TEXT, --intent -, --intent-file PATH or their = forms). The
    route flag is true when an admission route other than this admission's own
    measured runner (fm-duration.py run --pipeline-admitted) runs the start.
    """
    routed = expanded = False
    chdir: Optional[str] = None
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
            return (rest, routed, ENV_SPLIT if expanded else False, chdir) if fresh else None
        if name in TRANSPARENT:
            operands = wrapper_operands(name, rest)
            if operands is None:
                return None
            words, split, into = operands
            if into is not None:
                chdir = os.path.join(chdir or "", into)
            if split is not None:
                import shlex
                try:
                    words = ["env"] + shlex.split(split) + words
                except ValueError:
                    return None  # env refuses an unbalanced split string and runs nothing
                expanded = True
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
            if found is None:
                return None
            source = ENV_SPLIT if expanded or found[2] == ENV_SPLIT else True
            return found[0], routed or found[1], source, os.path.join(chdir or "", found[3] or "") or None
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


def shell_string_start(string: str) -> Optional[Tuple[List[str], bool, Union[bool, str], Optional[str]]]:
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
        if str(exc) != "unable to open database file":
            raise
        try:
            os.lstat(str(path) + "-wal")
            raise  # a -wal file exists: its rows cannot be read here
        except FileNotFoundError:
            pass  # no -wal file: the main file holds every committed row (any other lstat error propagates)
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


# One bound for the engine's local reads: the root-home walk and start_binding's git reads.
# Ten real fm_firstmate_root_home calls from a worker checkout: maximum 0.035 s (private task evidence); fifteen
# start_binding git reads (rev-parse --show-toplevel, rev-parse --git-common-dir, symbolic-ref) on 2026-11-15: maximum 0.01 s.
# measured: value=10 date=2026-11-01 host=Mac-Studio.local margin=285
LOCAL_READ_TIMEOUT_SECS = 10


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
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=LOCAL_READ_TIMEOUT_SECS, check=True)
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
    """Whether this CI step's recorded agent pid is dead (project() also requires that nothing of the run is visible).

    The daemon records an agent's pid when the agent starts and clears it when
    it exits, so a dead recorded pid is an agent that has ended; a live or
    unjudgeable pid is not proof. No time window applies: the run database
    gives no measured start-to-visible interval to derive one from, and a
    visible process of the run keeps the active term whatever its pid.
    """
    return step[2] is not None and pid_dead(step[2]) is True


def project(available: int, rss: dict, counted: dict, steps: Optional[dict], launches: dict,
            reservation: int, slack: int, term: int, self_run: Optional[str] = None,
            waiting: frozenset = frozenset(), now: Optional[float] = None, pending: int = 0,
            held_runs: frozenset = frozenset(), history: Optional[dict] = None,
            queued_pids: Optional[dict] = None, replaced: frozenset = frozenset(),
            before_activation: frozenset = frozenset()) -> dict:
    """The one projection (Main 1759): every demand from one census's facts, each fact a proof or unknown.

    counted maps each counted run ID to its repo ID; rss is the reading's run map (keyed
    no-mistakes:<repo>/<run>); steps is open_steps() or None; launches maps run IDs to their
    held attempts (attempt_reservations); history maps each run to its unproven launches
    (history_units; a run absent from it, or history None, has one); queued_pids maps a run to
    the pids of its queued launch gates (a step's recorded agent pid that is one of them is
    the queued launch itself). The population is every counted run, every run with a held
    attempt, the requesting run (self_run) and every queued run, whatever their status.
    Each run's demand is the sum of:
      its held attempts, each counted alone: R while unseen, the larger of its own resident
        memory and A once seen, and the run's other resident memory beside them (a counted
        run's passive attempts, its passed-through non-CI launches, are not counted alone:
        the run is active, the larger of what it and they hold and A once seen, R unseen);
      or, with no held attempt, its current state while counted: no step facts or no open
        step row, R beside what it holds (at least A); queued at CI with no live agent but its
        own gate (no pid, a dead one, or its queued gate's), what it holds; waiting on CI (status
        running) with no live agent (no pid or a dead one) and nothing visible, what it holds; otherwise
        the larger of what it holds and A once seen, R unseen; an uncounted run, what it holds;
      and R for each of its unproven launches, so a later attempt never masks an earlier one; a run in
        before_activation (created before the gate's activation: history_units) is charged the larger
        of that demand and R instead of R beside it.
    The new run reserves S; each pending admitted start that no counted run covers reserves R; and the
    branch of each run in replaced (a covering run with a replacing start: counted_pending) carries the
    larger of that run's demand and R, by one replacing entry of the shortfall per run, however many starts.
    While before_activation names any run, the base rule (base_rule) also admits: the need is
    the smaller of the two, each against its own budget (base, else None).
    Budget is available memory plus what the runs held. The one-start minimum admits only
    when nothing else is counted: every other counted run counts at least one, and the
    requesting run's own held attempts and unproven launches count (Main 1727).
    """
    entries = []
    clock = time.time() if now is None else now
    queued_pids = queued_pids or {}
    population = set(counted) | set(launches) | set(waiting) | ({self_run} if self_run else set())
    held = 0
    others = pending
    for run in sorted(population):
        repo = counted.get(run) or (launches.get(run) or {}).get("repo")
        seen = rss.get("no-mistakes:%s/%s" % (repo, run))
        size = seen["rss_bytes"] if seen and type(seen.get("rss_bytes")) is int else 0
        visible = bool(seen) and seen.get("processes", 0) > 0
        attempts = (launches.get(run) or {}).get("attempts") or []
        passive = [a for a in attempts if a.get("passive")] if run in counted else []
        attempts = [a for a in attempts if not (run in counted and a.get("passive"))]
        # A run whose history was not built is never zero (Main 1876 H): one charge.
        units = history[run] if history is not None and type(history.get(run)) is int else 1
        held += size
        step = None if steps is None else steps.get(run)
        if attempts:
            kind = "launched"
            demand = sum(max(a["own"], term) if a["seen"] else max(a["own"], reservation) for a in attempts)
            demand += max(0, size - sum(a["own"] for a in attempts))
            visible = visible or any(a["seen"] for a in attempts)
        elif run not in counted:
            kind, demand = "uncounted", size
        elif step is None:
            kind, demand = "step-unknown", max(reservation + size, term)
        elif passive:
            kind = "active"
            demand = max(size, sum(a["own"] for a in passive), term) \
                if visible or all(a["seen"] for a in passive) else reservation
            visible = visible or all(a["seen"] for a in passive)
        elif step[0] == CI_STEP and (run == self_run or run in waiting) and (
                step[2] is None or proven_agentless(step, clock)
                or step[2] in queued_pids.get(run, ()) or (run == self_run and step[2] == os.getpid())):
            # Queued: its launch is the one decided (S); what is seen of it is its gate and what it holds.
            kind, demand = "waiter", size
        elif step[0] == CI_STEP and step[1] == "running" and not visible and (step[2] is None or proven_agentless(step, clock)):
            kind, demand = "ci-waiting", size
        else:
            kind, demand = "active", (max(size, term) if visible else reservation)
        if units:
            kind = ("ci-unproven" if step is not None and step[0] == CI_STEP and not attempts else kind) + (
                "+%d" % units if units > 1 or attempts else "")
            demand = max(demand, reservation) if run in before_activation else demand + reservation * units
        entries.append((run, kind, demand, visible))
        starts = len(attempts) + units
        others += starts if run == self_run else max(1 if run in counted else 0, starts)
    demands = {run: demand for run, _, demand, _ in entries}
    for run in sorted(replaced):
        entries.append(("replace-" + run, "replacing", max(0, reservation - demands.get(run, 0)), False))
    for index in range(pending):
        entries.append(("start-%d" % (index + 1), "pending", reservation, False))
    projected = sum(demand for _, _, demand, _ in entries) + slack
    budget = available + held
    counted_rss = {run: (rss.get("no-mistakes:%s/%s" % (repo, run)) or {}).get("rss_bytes") or 0
                   for run, repo in sorted(counted.items())}
    base = base_rule(available, counted_rss, reservation, slack, pending) if before_activation else None
    return dict(admit=projected <= budget or others == 0 or base is not None and base[0] <= base[1],
                projected=projected, budget=budget, held=held, available=available, entries=entries,
                counted=len(counted), others=others, counted_rss=counted_rss, base=base)


def base_rule(available: int, counted_rss: Dict[str, int], reservation: int, slack: int, pending: int = 0) -> Tuple[int, int]:
    """(need, budget) of the base rule: (counted + 1) x R + S against available plus each counted run's resident memory
    up to R. PENDING admitted starts are counted runs holding nothing, as the base rule counted each start once it
    registered under the start lock it held until then."""
    need = (len(counted_rss) + pending + 1) * reservation + slack
    return need, available + sum(min(reservation, size) for size in counted_rss.values())


def projection_text(fit: dict, reservation: int, slack: int, term: int, runs_measured: int, readings: int) -> str:
    def items(selected):
        return ",".join("%s:%s:%d%s" % (run, kind, demand, "" if visible else ":unseen")
                        for run, kind, demand, visible in fit["entries"] if selected(kind)) or "none"
    reserved = items(lambda kind: kind not in ("ci-waiting", "waiter"))
    unreserved = items(lambda kind: kind in ("ci-waiting", "waiter"))
    # counted_runs names each counted run with its resident memory in this reading, so the base rule's decision
    # (base_rule) is recomputable from the line; base_need and base_budget are that decision while it also admits.
    counted_runs = ",".join("%s:%d" % item for item in fit.get("counted_rss", {}).items()) or "none"
    base = fit.get("base")
    return ("counted=%d projected=%d budget=%d available=%d held=%d reservation=%d active_term=%d slack=%d"
            " runs_measured=%d readings_measured=%d reserved=[%s] holding_only=[%s] counted_runs=[%s]"
            " base_need=%s base_budget=%s"
            % (fit["counted"], fit["projected"], fit["budget"], fit["available"], fit["held"], reservation,
               term, slack, runs_measured, readings, reserved, unreserved, counted_runs,
               "none" if base is None else base[0], "none" if base is None else base[1]))


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
              waiting: frozenset = frozenset(), pending: int = 0, held_runs: frozenset = frozenset(),
              history: Optional[dict] = None, queued_pids: Optional[dict] = None,
              replaced: frozenset = frozenset(), before_activation: frozenset = frozenset()) -> Tuple[bool, str]:
    """The complete admission rule over one census's facts: holds first, then the fit or the count fallback.

    measured, when given, supplies ((R, S, runs measured), (A, readings measured))
    instead of reading the records; the P4 replay passes the copied records here.
    The count fallback counts what the projection's one-start minimum counts
    (project()'s others: each counted run at least once, each held attempt and each
    unproven launch alone, the requesting run's own attempts and unproven launches,
    each pending start), so both paths count the same starts.
    """
    if reasons:
        return False, "overload: %s counted=%d priority=%s" % ("; ".join(reasons), len(counted), priority)
    if measured is None and report is not None:
        reserved, term = measured_reservations(report, running), active_term(report)
        # No qualifying reading for A is not a fallback trigger: every visible active run then counts at R,
        # the base's per-run term, so only the base's three triggers fall back (Main 4930 Q5).
        measured = (reserved, term if term is not None else (reserved[0], 0)) if reserved is not None else None
    if measured is None:
        limit = max(1, cores // 3)
        others = project(0, {}, counted, steps, launches, 0, 0, 0, self_run, waiting, pending=pending,
                         held_runs=held_runs, history=history, queued_pids=queued_pids)["others"]
        launched = len([run for run in launches if run not in counted and run != self_run])
        return others < limit, "counted=%d limit=%d basis=fallback launched=%d pending=%d starts=%d priority=%s" % (
            len([run for run in counted if run != self_run]), limit, launched, pending, others, priority)
    (reservation, slack, qualifying), (term, readings) = measured
    fit = project(report["available_bytes"], report["runs"], counted, steps, launches, reservation, slack, term, self_run,
                  waiting, pending=pending, held_runs=held_runs, history=history, queued_pids=queued_pids,
                  replaced=replaced, before_activation=before_activation)
    return fit["admit"], projection_text(fit, reservation, slack, term, qualifying, readings) + " priority=%s" % priority


def decide(running: dict, counted: dict, cores: int, priority: str, fresh: bool = False,
           directory: Optional[str] = None, self_run: Optional[str] = None,
           waiting: frozenset = frozenset()) -> Tuple[bool, str]:
    """(admit, one-line reason) for the first waiter: one census of the host, its runs, attempts and pending starts.

    Taken under the start lock (Main 1812 A). Every reader returns a proof or unknown (Main
    1759); a process fact that is unknown holds its attempt at full charge, and a pool
    listing, record, pending entry, claim or row that cannot be read is noted unknown, and
    then the decision waits, naming it (Main 1812 B).
    """
    _unknown.clear()
    seen = host_observation(fresh)
    states = judge_attempts(directory, set(running)) if directory else {}
    launches, held_runs = attempt_reservations(states, seen["memory"])
    pending, replaced = counted_pending(directory, set(running)) if directory else (0, frozenset())
    steps = open_steps() if seen["memory"] is not None else None
    if seen["memory"] is not None and steps is None:
        note_unknown("step table unreadable")  # Main 1876 U: the decision waits
    # Every run the projection charges: counted, queued, requesting, and every run with a held attempt whatever its
    # status, a stopped one included (Main 1876 H).
    population = set(counted) | set(waiting) | ({self_run} if self_run else set()) | set(launches)
    history, before = history_units(directory, states, population) if directory else ({run: 1 for run in population}, frozenset())
    queued = waiting_pids(directory) if directory else {}
    for key, row in ((seen["memory"] or {}).get("runs") or {}).items():
        if not isinstance(row, dict) or type(row.get("rss_bytes")) is not int:
            note_unknown("memory reading row %s malformed" % key)  # never read as holding nothing
    if _unknown:
        return False, "unknown: %s; counted=%d priority=%s (a decision waits until every fact reads)" % (
            "; ".join(sorted(set(_unknown)))[:1500], len(counted), priority)
    return admission(seen["reasons"], seen["memory"], running, counted, steps, launches, cores, priority, self_run,
                     waiting=waiting, pending=pending, held_runs=held_runs, history=history, queued_pids=queued,
                     replaced=replaced, before_activation=before)


class CensusUnknown(Exception):
    """The start's own census could not be read whole, though its database opens: the decision waits (Main 1876 U)."""


def database_opens() -> bool:
    """Whether the host run database can be opened at all: it exists, reads, begins with SQLite's header, and its
    -wal file, when one exists, reads.

    A file fact, never an error message: a missing, unreadable or non-SQLite file cannot be opened (P5.errors.db,
    exit 125 as before); any other failed read of an opened database is unknown (Main 1903 U-1). The file judged is
    the one SQLite itself opens for the read (PRAGMA database_list, which reads no page and takes no lock).
    """
    path = Path(HOST_STATE_DB).expanduser().resolve()
    try:
        with contextlib.closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as connection:
            files = [row[2] for row in connection.execute("PRAGMA database_list") if row[1] == "main"]
        with open(files[0], "rb") as handle:
            if handle.read(16) != b"SQLite format 3\x00":
                return False
        with contextlib.suppress(FileNotFoundError):
            open(files[0] + "-wal", "rb").close()
        return True
    except (OSError, sqlite3.Error, IndexError):
        return False


def pipeline_observation() -> Tuple[dict, int]:
    """(running runs, native cores) for one decision.

    An unreadable core count, or a run database that cannot be opened at all, raises (exit 125, P5.errors.db); a
    failed or partial read of the run rows of a database that opens, such as a locked one, is CensusUnknown: the
    decision waits with a named reason, never 125 (Main 1876 U, Main 1903).
    """
    cores = os.cpu_count()
    if not isinstance(cores, int) or cores < 1:
        raise ValueError("cannot read a positive native CPU count")
    try:
        runs = running_runs()
    except sqlite3.Error as exc:
        if not database_opens():
            raise
        raise CensusUnknown("run rows of %s unreadable: %s" % (HOST_STATE_DB, exc)) from exc
    return runs, cores


ATTEMPT_PREFIX = "attempt-"
# How long the gate keeps relaying the agent's output after the agent exits, for a descendant that holds it open:
# the daemon's own pipe backstop (no-mistakes fork internal/shellenv/shell_command_unix.go:20, defaultWaitDelay).
# measured: value=5.0 date=2026-11-15 host=Mac-Studio.local margin=1 (copies the daemon's documented constant; not timed here)
RELAY_AFTER_EXIT_SECS = 5.0
# Reads of one process's coalition before it counts as unreadable (and so holds every attempt it could belong to);
# a process caught mid-creation answers on a later read. Not a measured limit: three reads, 0, 10 and 20 ms apart.
COALITION_READ_TRIES = 3


def kernel_snapshot() -> Dict[int, Tuple[Optional[int], int, Optional[int]]]:
    """pid -> (parent pid or None, exact start time in microseconds, resource coalition or None) for every process
    the process table lists alive.

    One whole read of the process table (kinfo_table: a read that is not a whole number of
    records is refused), then for each listed process its resource coalition
    (PROC_PIDCOALITIONINFO, exactly its full size) and a confirming read of that pid
    (kinfo_exact). The coalition is the process's own only when the confirming read shows
    the table's start time: the pid then held one process from the table read to after the
    coalition read. Otherwise, or when either read fails or is short, it is None (unknown),
    so the process holds every attempt it could belong to. A process the table lists alive
    stays in this snapshot even when it exits before its confirming read: it was alive at
    the table read and may have forked a child the table does not list (Main 1759), so it is
    never proof of anything's end. A zombie in the table has ended. A traced process carries
    parent None, so no lineage is read through it. OSError when the table cannot be read;
    on a platform without these facts the table is unreadable, so every attempt stays held.
    """
    if sys.platform != "darwin":
        raise OSError("no kernel process identity and coalition facts on %s" % sys.platform)
    info = sibling("fm_proc_info", "fm-proc-info.py")
    import struct
    found = {}
    for record in info.kinfo_table():
        pid = struct.unpack_from("i", record, info.P_PID)[0]
        if pid <= 0 or record[info.P_STAT] == info.SZOMB:
            continue  # a zombie has ended; only its exit status remains
        seconds, micros = info.process_identity(record)
        traced = struct.unpack_from("i", record, info.P_FLAG)[0] & info.P_TRACED
        parent = None if traced else struct.unpack_from("i", record, info.E_PPID)[0]
        found[pid] = [parent, seconds * 1000000 + micros, info.coalition(pid)]
    for retry in range(1, COALITION_READ_TRIES):
        missing = [pid for pid, entry in found.items() if entry[2] is None]
        if not missing:
            break
        time.sleep(0.01)  # a process in the middle of its own creation or exec is briefly unreadable
        for pid in missing:
            found[pid][2] = info.coalition(pid)
    table = {}
    for pid, (parent, start, coalition) in found.items():
        try:
            again = info.kinfo_exact(pid)
            seconds, micros = info.process_identity(again)
            same = seconds * 1000000 + micros == start
        except (info.NoSuchProcess, OSError, struct.error):
            same = False  # gone or unreadable since the table read: listed alive, its coalition not shown its own
        table[pid] = (parent, start, coalition if same else None)
    if not table:
        raise OSError("empty kernel process table")
    return table


def process_identity_of(pid: int) -> Optional[Tuple[int, Optional[int]]]:
    """(exact start time in microseconds, resource coalition) of one live process, or None when it cannot be read."""
    try:
        table = kernel_snapshot()
    except (OSError, ValueError, AttributeError):
        return None
    entry = table.get(pid)
    return None if entry is None else (entry[1], entry[2])


# Facts a decision could not read (Main 1812 B): each one makes the decision wait, its line naming it.
_unknown: List[str] = []


def note_unknown(text: str) -> None:
    _unknown.append(text)


def list_pool(directory: str, pattern: str) -> List[str]:
    """The pool's entries matching PATTERN, sorted; OSError when the directory cannot be listed (never an empty list)."""
    import fnmatch
    return sorted(os.path.join(directory, name) for name in os.listdir(directory) if fnmatch.fnmatch(name, pattern))


def attempt_paths(directory: str) -> List[str]:
    return list_pool(directory, ATTEMPT_PREFIX + "*.json")


def read_attempt(path: str) -> Optional[dict]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_SH)
            return json.loads(handle.read())
    except (OSError, ValueError):
        return None


def update_attempt(path: str, change) -> Optional[dict]:
    """Apply change(record) to the record at PATH under its lock; returns the new record, None when it fails.

    The new record is written whole to a temporary file in the same folder and renamed over PATH, so a failed write
    leaves the old record whole, never an empty or partial one (Main 1892). Writers lock the file they opened and
    then check PATH still names it: one renamed in meanwhile is reopened, so no update is lost to a concurrent one.
    """
    try:
        for _ in range(64):
            with open(path, "r", encoding="utf-8") as handle:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
                opened = os.fstat(handle.fileno())
                current = os.stat(path)
                if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
                    continue  # replaced since it was opened: read the record now at PATH
                record = json.loads(handle.read())
                change(record)
                fd, temporary = tempfile.mkstemp(prefix="." + ATTEMPT_PREFIX, dir=os.path.dirname(path) or ".")
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as out:
                        out.write(json.dumps(record, sort_keys=True))
                        out.flush()
                        os.fsync(out.fileno())
                    os.rename(temporary, path)
                except BaseException:
                    with contextlib.suppress(OSError):
                        os.unlink(temporary)
                    raise
                return record
        return None
    except (OSError, ValueError):
        return None


def write_attempt(directory: str, record: dict) -> str:
    """Publish a new attempt record atomically (written whole, then renamed into place)."""
    fd, temporary = tempfile.mkstemp(prefix="." + ATTEMPT_PREFIX, dir=directory)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True))
    final = os.path.join(directory, "%s%s.json" % (ATTEMPT_PREFIX, record["id"]))
    os.rename(temporary, final)
    return final


ATTEMPT_FIELDS = ("id", "run", "repo", "step", "reserves", "t0_us", "root", "gate", "watcher", "coalition",
                  "session_key", "members", "ended_us")


def valid_attempt(record) -> bool:
    """Whether a decoded attempt record has every field the gate writes, each present and of its own type.

    A missing or mistyped field is never read as its empty value (Main 1759, Main 1812 B): such a record is unknown.
    """
    def ident(value):
        return isinstance(value, list) and len(value) == 2 and all(type(part) is int for part in value)

    def optional(value, kind):
        return value is None or type(value) is kind

    return (isinstance(record, dict) and all(name in record for name in ATTEMPT_FIELDS)
            and isinstance(record["id"], str) and isinstance(record["run"], str) and isinstance(record["repo"], str)
            and isinstance(record["step"], str) and type(record["t0_us"]) is int
            and ident(record["root"]) and (record["gate"] is None or ident(record["gate"]))
            and (record["watcher"] is None or ident(record["watcher"]))
            and isinstance(record["members"], list) and all(ident(m) for m in record["members"])
            and optional(record["coalition"], int) and optional(record["ended_us"], int)
            and (record["session_key"] is None or isinstance(record["session_key"], str))
            and type(record["reserves"]) is bool)


def judge_once(pending: List[Tuple[str, dict]], snapshot) -> Dict[str, Tuple[list, Optional[str], list]]:
    """path -> (its proven processes, the reason it is held or None, every process that could be its) from one census.

    Every listed process is judged for every attempt: finding a proven process never stops the search for possible
    ones (Main 1876 J), so the memory join covers every process that could be the attempt's.
    """
    alive = lambda ident: snapshot.get(ident[0]) is not None and snapshot[ident[0]][1] == ident[1]  # noqa: E731
    own: Dict[int, set] = {}
    for path, record in pending:
        for ident in [record["root"]] + list(record["members"]):
            if alive(ident):
                own.setdefault(ident[0], set()).add(path)
    changed = True
    while changed:
        changed = False
        for pid, (parent, _, _) in snapshot.items():
            if parent in own and not own[parent] <= own.get(pid, set()):
                own.setdefault(pid, set()).update(own[parent])
                changed = True
    out = {}
    for path, record in pending:
        mine = sorted((pid, snapshot[pid][1]) for pid, owners in own.items() if path in owners)
        mine_pids = {pid for pid, _ in mine}
        t0, coalition = record["t0_us"], record["coalition"]
        possible, first = [], None
        for pid, (parent, start, where) in snapshot.items():
            if pid in mine_pids or pid == 1 or start < t0:
                continue  # its own, launchd, or started before the attempt: never a possible descendant
            if where is not None and coalition is not None and where != coalition:
                continue  # outside the launch coalition: proven not its (an unknown coalition proves nothing)
            cursor, steps, anchored = parent, 0, False
            while cursor is not None and cursor not in (0, 1) and steps < 4096:
                entry = snapshot.get(cursor)
                if entry is None:
                    break
                if entry[1] < t0:
                    anchored = True  # its line reaches a listed process older than the attempt
                    break
                cursor, steps = entry[0], steps + 1
            if anchored:
                continue
            possible.append((pid, start))
            if first is None:
                if where is None or coalition is None:
                    first = "process %d could be its (%s coalition unknown)" % (pid, "its" if where is None else "the launch")
                else:
                    words = process_argv(pid) or ["unreadable"]
                    first = "process %d (%s; parent %s) could be its (launch coalition, started after it, no older ancestor)" % (
                        pid, " ".join(words[:3])[:120], parent)
        reason = ("its process %d lives" % mine[0][0]) if mine else first
        out[path] = (mine, reason, sorted(possible))
    return out


def judge_attempts(directory: str, running: set, snapshot=None, second=None) -> Dict[str, dict]:
    """Each attempt record's state under Main 1656's rule: hold on anything short of proof.

    Returns path -> dict(record, path, state in held|ended, reason, processes) for every
    record, whatever its run's status (Main 1712: a live attempt stays counted when its run
    stops running). A listing of the pool that cannot be read, or a record that cannot be
    read or lacks a field of its type, is unknown: it is held with record None and noted
    (note_unknown), so the decision waits (Main 1812 B). An attempt is held while one of its
    proven processes lives (its root, a recorded member, or a listed process whose parent
    chain reaches one, matched by pid and exact start time; each newly reached one is
    recorded), or while any listed process could be its: started at or after its t0, not
    shown outside its launch coalition (an unknown coalition on either side shows nothing),
    and whose parent chain does not reach a listed process started before t0. Being another
    attempt's process is no proof it is not this one's too. The chain proof rests on Darwin's
    reparenting: an orphan's parent becomes launchd (pid 1), never another process; a traced
    process carries no parent (kernel_snapshot). It is ended only when two successive
    censuses taken in this one decision each show neither (a child forked during the first
    census's read is listed by the second), its end then written to its own record under its
    lock; a record that cannot be reread to write it stays held. A marker, a missing marker
    or a lost lineage never ends an attempt. An ended record of a run no longer running is
    removed. SNAPSHOT and SECOND, when given, are the two censuses (a test's facts).
    """
    states: Dict[str, dict] = {}
    try:
        paths = attempt_paths(directory)
    except OSError as exc:
        note_unknown("attempt listing of %s unreadable: %s" % (directory, exc))
        unknown_path = os.path.join(directory, ATTEMPT_PREFIX + "*.json")
        return {unknown_path: dict(record=None, path=unknown_path, state="held", reason="attempt listing unreadable", processes=[])}
    records = {}
    for path in paths:
        record = read_attempt(path)
        records[path] = record if valid_attempt(record) else None
        if records[path] is None:
            note_unknown("attempt record %s unreadable or malformed" % path)
            states[path] = dict(record=None, path=path, state="held", reason="attempt record unreadable", processes=[])
    pending = [(path, record) for path, record in records.items() if record is not None and record["ended_us"] is None]
    if pending:
        try:
            first = kernel_snapshot() if snapshot is None else snapshot
            judged = judge_once(pending, first)
            quiet = [(path, record) for path, record in pending if judged[path][1] is None]
            if quiet:
                again = judge_once(quiet, kernel_snapshot() if second is None else second)
                for path, (mine, reason, possible) in again.items():
                    judged[path] = (sorted(set(judged[path][0]) | set(mine)), reason, sorted(set(judged[path][2]) | set(possible)))
        except (OSError, ValueError, AttributeError) as exc:
            note_unknown("process table unreadable: %s" % exc)  # Main 1876 U: the decision waits
            judged = {path: ([], "process table unreadable: %s" % exc, []) for path, _ in pending}
        now_us = int(time.time() * 1000000)
        for path, record in pending:
            mine, reason, possible = judged[path]
            if mine:
                new = [list(item) for item in mine if list(item) not in record["members"] and list(item) != record["root"]]
                if new:
                    written = update_attempt(path, lambda r: r["members"].extend(new))
                    if written is None:
                        # A descendant seen and not recorded could be forgotten once its lineage is lost: unknown, and the
                        # decision waits (Main 1876 U).
                        note_unknown("attempt record %s: its members could not be written" % path)
                    else:
                        record = written
            if reason is None:
                written = update_attempt(path, lambda r: r.__setitem__("ended_us", r["ended_us"] or now_us))
                if written is None or not valid_attempt(written):
                    note_unknown("attempt record %s: its end could not be written" % path)  # host-wide unknown (Main 1819)
                    states[path] = dict(record=record, path=path, state="held", processes=[],
                                        reason="attempt record could not be reread to write its end")
                    continue
                states[path] = dict(record=written, path=path, state="ended", processes=[],
                                    reason="no process of it, none could be, at two successive censuses")
            else:
                states[path] = dict(record=record, path=path, state="held", reason=reason, processes=mine, possible=possible)
    for path, record in records.items():
        if record is not None and record["ended_us"] is not None and path not in states:
            states[path] = dict(record=record, path=path, state="ended", reason="ended", processes=[])
    # An ended record of a run no longer running is removed, unless that run still has a held attempt: its history
    # is then still built (Main 1876 H), and its ended records are part of it.
    still_held = {state["record"]["run"] for state in states.values() if state["state"] == "held" and state["record"]}
    for path, state in list(states.items()):
        if state["state"] == "ended" and state["record"]["run"] not in running and state["record"]["run"] not in still_held:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(path)
            del states[path]
    return states


def attempt_reservations(states: Dict[str, dict], report: Optional[dict]) -> Tuple[dict, set]:
    """(run -> {repo, attempts: [{seen, own, passive}]} for held attempts, every run with a held attempt).

    One charge per owner (run) and attempt key (Main 1876): the held records of one run that share one nonempty
    session key are one attempt (a resumed session), charged once; a record with no key is an attempt of its own. Its
    processes are every proven and every possible process of its records (judge_once). Its resident memory joins the
    reading by pid and exact start time, from a figure of that same read only (rss_source task, Main 1656, P3); the
    attempt is seen only when every one of those processes joins, and a possible process left unjoined is unknown:
    noted, so the decision waits (Main 1876 J). A passed-through attempt (a counted run's non-CI launch) is marked
    passive: project() counts it alone only when its run is not counted; a counted run with passive attempts is
    charged once, as an active run.
    """
    rows = {}
    for row in (report or {}).get("processes", []) or []:
        if isinstance(row, dict) and type(row.get("start_us")) is int and row.get("rss_source") == "task" \
                and type(row.get("rss_bytes")) is int:
            rows[(row["pid"], row["start_us"])] = row["rss_bytes"]
    groups: Dict[Tuple[str, str], dict] = {}
    held_runs = set()
    for state in states.values():
        record = state["record"]
        if state["state"] != "held" or record is None:
            continue  # an unreadable record is unknown: the decision waits (judge_attempts noted it)
        held_runs.add(record["run"])
        key = record["session_key"] if record["session_key"] else "record:" + state["path"]
        group = groups.setdefault((record["run"], key), dict(repo=record["repo"], proven=set(), possible=set(), passive=True))
        group["proven"].update(tuple(ident) for ident in state["processes"])
        group["possible"].update(tuple(ident) for ident in state.get("possible", ()))
        group["passive"] = group["passive"] and not record["reserves"]
    launches: dict = {}
    for (run, _), group in sorted(groups.items()):
        processes = group["proven"] | group["possible"]
        unjoined = sorted(ident for ident in group["possible"] if ident not in rows)
        if unjoined:
            note_unknown("process %d could be run %s's attempt and its memory is not joined" % (unjoined[0][0], run))
        joined = [rows[ident] for ident in processes if ident in rows]
        entry = launches.setdefault(run, dict(repo=group["repo"], attempts=[]))
        entry["attempts"].append(dict(seen=bool(processes) and len(joined) == len(processes), own=sum(joined),
                                      passive=group["passive"]))
    return launches, held_runs


# The pinned gate's activation record in the pool (written by the activation step, P9.deploy): its time and the
# gate's sha256. A run created after it, whose every agent row names a gated agent, has a launch history the gate
# recorded whole (Main 1761 amendment of the Main 1712 invariant).
ACTIVATION_RECORD = "gate-activation.json"
# Agents whose launcher is the gated one (the daemon's `agent: [claude]`, launched through claude-teamclaude).
GATED_AGENTS = ("claude",)


def read_activation(directory: str) -> Optional[int]:
    """The gate activation time (epoch seconds), or None when the record is missing, unreadable or malformed."""
    try:
        record = json.loads(Path(directory, ACTIVATION_RECORD).read_text())
    except FileNotFoundError:
        return None  # no activation: no history is complete
    except (OSError, ValueError) as exc:
        note_unknown("activation record unreadable: %s" % exc)  # Main 1876 U
        return None
    sha = record.get("gate_sha256") if isinstance(record, dict) else None
    activated = record.get("activated_at") if isinstance(record, dict) else None
    if type(activated) is not int or not isinstance(sha, str) or len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
        note_unknown("activation record malformed")  # Main 1876 U
        return None
    return activated


def write_activation(directory: str, gate: str) -> Tuple[bool, str]:
    """Write DIRECTORY's activation record once: (True, its JSON) or (False, the reason nothing was written).

    Nothing is written when a record already exists (activation never moves later),
    when GATE cannot be read, or when the pool holds a live waiter of the earlier
    engine, which writes no run and no pid (it predates this rule and must be
    re-issued by its owner first), or a waiter that cannot be read.
    """
    import hashlib
    final = os.path.join(directory, ACTIVATION_RECORD)
    if os.path.lexists(final):
        return False, "record exists: %s" % final
    try:
        digest = hashlib.sha256(Path(gate).read_bytes()).hexdigest()
    except OSError as exc:
        return False, "gate file unreadable: %s" % exc
    try:
        old = [entry["path"] for entry in waiter_census(directory) if "pid" not in entry]
    except (OSError, ValueError) as exc:
        return False, "waiters unreadable: %s" % exc
    if old:
        return False, "a waiter of the earlier engine is queued: %s; its owner re-issues that start first" % old[0]
    text = json.dumps(dict(activated_at=int(time.time()), gate_sha256=digest))
    fd, temporary = tempfile.mkstemp(prefix="." + ACTIVATION_RECORD + ".", dir=directory)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
        os.link(temporary, final)
    except FileExistsError:
        return False, "record exists: %s" % final
    finally:
        os.unlink(temporary)
    return True, text


def cmd_activate(args: argparse.Namespace) -> int:
    try:
        directory = pool_dir()
        ensure_pool_dir(directory)
        written, text = write_activation(directory, args.gate)
    except PoolUnavailable as exc:
        written, text = False, "pool unavailable: %s" % exc
    except OSError as exc:
        written, text = False, "record write failed: %s" % exc
    if not written:
        log(2, "activate refused: %s; no record written" % text)
        return 1
    print("fm-cpu-pass: activate wrote %s: %s" % (os.path.join(directory, ACTIVATION_RECORD), text))
    return 0


def history_units(directory: Optional[str], states: Dict[str, dict], runs: set) -> Tuple[Dict[str, int], frozenset]:
    """(run -> 1 when its launch history is not shown complete, else 0 (Main 1712, 1727, 1759, 1761, 1812); the runs
    of those created before the gate's activation, every one when there is no activation record).

    A run's history is proven complete only when the gate's activation record predates the
    run's creation, every invocation row of the run names a gated agent, each row binds one
    to one to its own record by its own nonempty session key, and every ended record of the
    run is bound to a row the same way (a held record is counted as an attempt of its own, its
    row not written until its invocation returns). Otherwise its history charges
    one R beside its held attempts, each counted alone: invocation rows are written after an
    invocation returns, so a row marks a returned launch whose unrecorded remainder may
    linger, and R is the measured peak of a whole run. One charge per history, never one per
    row, keeps the projection from falling when a row is lost (the daemon gives no way to
    detect a missing row; Main 1812 E). A run created before activation is instead charged
    the larger of its demand and R (project; the captain, 2026-11-26). Any unreadable attempt
    record leaves no history complete; rows or runs that cannot be read are unknown (note_unknown): the decision waits.
    """
    if not runs:
        return {}, frozenset()
    doubt = any(state["record"] is None for state in states.values())
    activated = read_activation(directory) if directory else None
    marks = ",".join("?" * len(runs))
    try:
        rows = read_host_db("SELECT run_id, session_key, agent FROM agent_invocations WHERE run_id IN (%s)" % marks,
                            tuple(sorted(runs)))
        created = dict(read_host_db("SELECT id, created_at FROM runs WHERE id IN (%s)" % marks, tuple(sorted(runs))))
    except (OSError, sqlite3.Error, ValueError) as exc:
        note_unknown("invocation rows unreadable: %s" % exc)
        return {run: 1 for run in runs}, frozenset()
    units, before = {}, set()
    for run in runs:
        keys = [key for owner, key, _ in rows if owner == run]
        agents = [agent for owner, _, agent in rows if owner == run]
        records = [state for state in states.values() if state["record"] is not None and state["record"]["run"] == run]
        record_keys = [state["record"]["session_key"] for state in records]

        def one_to_one(key):
            return isinstance(key, str) and bool(key) and keys.count(key) == 1 and record_keys.count(key) == 1
        if run not in created:
            note_unknown("run %s has no run row: its history cannot be built" % run)  # Main 1876 H: the decision waits
        complete = (not doubt and activated is not None and type(created.get(run)) is int and activated < created[run]
                    and all(agent in GATED_AGENTS for agent in agents) and all(one_to_one(key) for key in keys)
                    and all(one_to_one(state["record"]["session_key"]) for state in records if state["state"] == "ended"))
        units[run] = 0 if complete else 1
        if not complete and (activated is None or type(created.get(run)) is int and created[run] <= activated):
            before.add(run)
    return units, frozenset(before)


def start_binding(cwd: str) -> Optional[dict]:
    """The repository, branch and HEAD a fresh client in CWD starts its run on, or None when repository or branch is not told.

    The repository follows the client's own rule (no-mistakes fork
    internal/cli/root.go findRepo, line 112): the git root, else the main
    worktree root, matched to repos.working_path. A start whose repository or
    branch cannot be told has no binding and is covered by no run (pending_census).
    head is the commit HEAD names, or None when it cannot be read (an unborn
    branch): such a start is never a proven reattach (proven_reattach).
    """
    def git(*words) -> Optional[str]:
        try:
            done = subprocess.run(["git", "-C", cwd] + list(words), stdin=subprocess.DEVNULL,
                                  capture_output=True, text=True, timeout=LOCAL_READ_TIMEOUT_SECS)
        except (OSError, subprocess.SubprocessError):
            return None
        return done.stdout.strip() if done.returncode == 0 and done.stdout.strip() else None

    top, common, branch = git("rev-parse", "--show-toplevel"), git("rev-parse", "--path-format=absolute", "--git-common-dir"), \
        git("symbolic-ref", "--quiet", "--short", "HEAD")
    if top is None or branch is None:
        return None
    roots = [top] + ([os.path.dirname(common)] if common and os.path.basename(common) == ".git" else [])
    try:
        repos = read_host_db("SELECT id, working_path FROM repos")
    except (OSError, sqlite3.Error, ValueError):
        return None
    for root in roots:
        for repo, path in repos:
            if isinstance(path, str) and os.path.realpath(path) == os.path.realpath(root):
                return dict(repo=repo, branch=branch, head=git("rev-parse", "--verify", "--quiet", "HEAD"))
    return None


def claim_record(path: str) -> Optional[dict]:
    """The claim of the pending start at PATH, decoded, or None when there is none or it cannot be read or decoded.

    A caller tells "none" from "unreadable" by whether the claim file exists (pending_census).
    """
    try:
        value = json.loads(Path(path + ".claimed").read_bytes().decode("utf-8"))
    except (OSError, ValueError):  # UnicodeDecodeError is a ValueError: an undecodable claim is unknown, never a refusal
        return None
    return value if isinstance(value, dict) else None


def valid_claim(claim) -> bool:
    """Whether a claim has every field claim_round writes, each of its own type (Main 1812 B)."""
    return (isinstance(claim, dict) and type(claim.get("pid")) is int
            and type(claim.get("direct")) is bool and (claim.get("client") is None or type(claim.get("client")) is int)
            and "client" in claim)


def valid_pending(entry) -> bool:
    """Whether a pending entry has every field cmd_pipeline_start publishes, each of its own type (Main 1812 B)."""
    return (isinstance(entry, dict) and type(entry.get("holder")) is int and type(entry.get("created_ns")) is int
            and isinstance(entry.get("before"), list) and all(isinstance(run, str) for run in entry["before"])
            and "args" in entry and (entry["args"] is None or (isinstance(entry["args"], list)
                                                               and all(isinstance(word, str) for word in entry["args"]))))


def read_pending(fd: int) -> Optional[dict]:
    """The pending entry held open at FD, read whole, or None when it cannot be read or decoded."""
    try:
        size = os.fstat(fd).st_size
        data = os.pread(fd, max(size, 1), 0)
        if len(data) != size:
            return None  # a read shorter than the file is unknown, never the entry (Main 1876 U)
        entry = json.loads(data)
    except (OSError, ValueError):
        return None
    return entry if isinstance(entry, dict) else None


def runs_since(running: set, since_ns: int) -> set:
    """Every run in RUNNING and every run created since SINCE_NS, whatever its status now."""
    return {row[0] for row in read_host_db(
        "SELECT id FROM runs WHERE status = 'running' OR created_at >= ?", (since_ns // 1000000000 - 1,))} | set(running)


def counted_places(running: set) -> Dict[str, Tuple[tuple, frozenset]]:
    """run -> ((repo ID, branch), the heads it records) for every run in RUNNING that a decision counts as active
    (running_runs' rule); the heads are its head_sha and submitted_head_sha, each when set."""
    if not running:
        return {}
    marks = ",".join("?" * len(running))
    return {row[0]: ((row[1], row[2]), frozenset(head for head in row[3:] if isinstance(head, str) and head))
            for row in read_host_db(
                "SELECT id, repo_id, branch, head_sha, submitted_head_sha FROM runs WHERE status = 'running'"
                " AND ci_ready_at IS NULL AND awaiting_agent_since IS NULL AND id IN (%s)" % marks, tuple(sorted(running)))}


def binding_key(binding) -> Optional[tuple]:
    """(repo, branch) of a start's binding (start_binding), or None when either is not told."""
    if not isinstance(binding, dict):
        return None
    repo, branch = binding.get("repo"), binding.get("branch")
    if not (isinstance(repo, str) and repo and isinstance(branch, str) and branch):
        return None
    return repo, branch


def proven_reattach(args, shell, binding, heads: frozenset) -> bool:
    """Whether a covered start is proven to reattach to its covering run rather than replace it.

    Proof is `axi run` with no --launch-nonce (in either form) whose binding
    records the HEAD the run records (its head_sha or submitted_head_sha). A
    start through env -S (SHELL is ENV_SPLIT) is never proof, whatever its words
    hold: env reads the string with escapes and ${VAR} the admission does not
    read as env does. When SHELL is otherwise not False (the arguments were read
    from a shell's command string, or the entry does not say), a word holding a
    character the shell expands later ($X, a glob, ~) may hide a nonce and is no
    proof; a word of a real argument vector is never refused for its characters.
    A rerun, a start whose arguments or HEAD are not known, and a HEAD that
    differs are no proof.
    """
    if not isinstance(args, list) or args[:2] != ["axi", "run"] or shell == ENV_SPLIT:
        return False
    if any(word == "--launch-nonce" or word.startswith("--launch-nonce=")
           or (shell is not False and any(char in word for char in SHELL_EXPANSION_CHARS)) for word in args[2:]):
        return False
    head = binding.get("head") if isinstance(binding, dict) else None
    return isinstance(head, str) and head in heads


def pending_census(directory: str, running: set) -> List[dict]:
    """One read of every pending admitted start, its claim and whether it counts, oldest first (Main 1759, 1812, 3852).

    Each item: path, entry (None when unreadable), claim (None when none or unreadable),
    known (its claimant's identity is read), claimed, key (the repository and branch the
    start is bound to, or None), ended, covered (the counted run on that repository and
    branch, or None), released (ended or covered: this decision does not count it at R
    on its own) and replacing (covered, and not a proven reattach: proven_reattach).
    The binding is the claimant's: a final claim's binding, or, with no claim, the binding
    the admission took from its own directory (start_binding). An entry or a claim that
    cannot be read or lacks a field of its type is unknown: noted (the decision waits),
    counted, never covered, and while any claimant is unknown no start is covered.
    A start is covered while a run in RUNNING that a decision counts as active (not
    CI-ready, not awaiting an agent) is on its repository and branch (Main 3852). The
    daemon keeps one active run per repository and branch: before it creates a row it
    cancels every pending or running run there and waits for each to end (no-mistakes fork
    internal/daemon/manager.go cancelActiveRuns); and a client with no launch nonce on a
    branch with an active run reattaches to it (internal/cli/axi_drive.go). So that run is
    the run the start's client drives or the run it is replacing. A covered start adds
    nothing only when it is a proven reattach (proven_reattach): it then drives that run,
    and that run's own charge is its charge. Every other covered start may replace the run,
    and the run's charge can be far below R (a CI waiter holds what it holds), so its branch
    carries the larger of the covering run's demand and R, once per branch however many
    such starts it has (counted_pending, project()). The cost: while such a start's command
    runs, a run it only drives is charged R rather than the larger of its size and A, an
    overcharge, never an undercount; the exact rule needs a launch identity in the
    no-mistakes fork. Coverage is read again at every decision, never kept: in the gap
    between a replaced run's end and its replacement's row, and once the run leaves the
    counted set (CI-ready, parked or ended), the start counts at R again. A start with no
    binding (a directory that is no registered repository's, a detached HEAD) is never
    covered; its client starts no run there (the client refuses), so it is charged once,
    by its reservation, until its COMMAND returns. A stale running row that an earlier
    daemon left, which no cancel reaches, covers its branch's starts too; it is charged
    as any counted run is (a CI waiter at what it holds), and a replacing start on its
    branch still makes the branch carry at least R. K7 ends a start whose known
    claimant's pid is dead. A locked file is a live start; an unlocked one belongs to a
    start that no longer exists and is removed. OSError when the pool cannot be listed.
    """
    found = []
    for path in list_pool(directory, "pending-*.lock"):
        try:
            fd = os.open(path, os.O_RDWR | getattr(os, "O_CLOEXEC", 0))
        except FileNotFoundError:
            continue
        try:
            if try_lock(fd):
                for stale in (path, path + ".claimed"):
                    with contextlib.suppress(FileNotFoundError):
                        os.unlink(stale)
                continue
            entry = read_pending(fd)
        finally:
            os.close(fd)
        entry = entry if valid_pending(entry) else None
        try:
            os.lstat(path + ".claimed")
            claimed = True
        except FileNotFoundError:
            claimed = False
        except OSError as exc:
            claimed = None  # cannot tell a claim from none: unknown (Main 1876 U), never "unclaimed"
            note_unknown("claim %s.claimed unreadable: %s" % (path, exc))
        claim = claim_record(path) if claimed else None
        if entry is None:
            note_unknown("pending start %s unreadable or malformed" % path)
            known = False
        elif claimed is None:
            known = False
        elif claimed:
            known = valid_claim(claim)
            if not known:
                note_unknown("claim %s.claimed unreadable or malformed" % path)
        else:
            known = True
        binding = (claim.get("binding") if claimed else entry.get("binding")) if known else None
        found.append(dict(path=path, entry=entry, claim=claim if known else None, known=known, claimed=claimed,
                          key=binding_key(binding), binding=binding, order=(entry["created_ns"] if entry else 0, path)))
    found.sort(key=lambda item: item["order"])
    all_known = all(item["known"] for item in found)
    places = counted_places(running) if all_known and any(item["key"] for item in found) else {}
    cover: Dict[tuple, str] = {}
    for run, (place, _) in sorted(places.items()):
        cover.setdefault(place, run)
    for item in found:
        claim = item["claim"]
        item["covered"] = cover.get(item["key"]) if item["key"] else None
        item["replacing"] = item["covered"] is not None and not proven_reattach(
            item["entry"]["args"], item["entry"].get("shell"), item["binding"], places[item["covered"]][1])
        # K7 by the claim's bound client, the one client the reservation is for (Main 1876 C); a shell claim with no
        # client bound yet ends with the shell.
        item["ended"] = item["known"] and claim is not None and pid_dead(
            claim["client"] if claim["client"] is not None else claim["pid"]) is True
        item["released"] = item["ended"] or item["covered"] is not None
    return found


def live_pending(directory: str, running: set) -> List[Tuple[str, dict, bool, Optional[str]]]:
    """(path, entry, released, covering run) for each pending admitted start (pending_census), oldest first."""
    return [(item["path"], item["entry"] or dict(unreadable=True), item["released"], item["covered"])
            for item in pending_census(directory, running)]


def counted_pending(directory: str, running: set) -> Tuple[int, frozenset]:
    """(how many pending admitted starts this decision counts at the full R, the covering runs whose branch carries R).

    Every unreleased pending start counts, and every replacing covered start
    (pending_census) names its covering run, whose branch then carries at least R
    (project()), except, on positive proof only, this process's
    own enclosing start: its entry and claimant are read, it has not been claimed, its
    holder is this process's ancestor, its admitted arguments are known, and no process in
    the holder's tree outside this process's own line runs the admitted client (so this
    start's own S, or the first client's own row, already counts what it reserved). A pool
    that cannot be listed is unknown: noted, and the decision waits.
    """
    try:
        census = pending_census(directory, running)
    except (OSError, sqlite3.Error, ValueError) as exc:
        note_unknown("pending starts of %s unreadable: %s" % (directory, exc))  # a decision waits, never 125 (Main 1876 U)
        return 0, frozenset()
    mine = None
    count = 0
    replaced = set()
    for item in census:
        if item["ended"] or (item["covered"] is not None and not item["replacing"]):
            continue
        entry = item["entry"]
        if entry is not None and item["known"] and item["claim"] is None and item["claimed"] is False \
                and isinstance(entry["args"], list):
            if mine is None:
                mine = ancestors(os.getpid())
            if entry["holder"] in mine and not admitted_client_running(entry["holder"], entry["args"],
                                                                       exclude=frozenset(mine) | {os.getpid()}):
                continue
        if item["covered"] is not None:
            replaced.add(item["covered"])
        else:
            count += 1
    return count, frozenset(replaced)


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
    import struct
    # One whole read of the table (kinfo_table refuses a partial one: Main 1876 U), never a table with a record missing.
    return {struct.unpack_from("i", r, info.P_PID)[0]: struct.unpack_from("i", r, info.E_PPID)[0] for r in info.kinfo_table()}


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
            if argc < 1 or len(words) < argc:
                return None  # fewer words than its own count says: unknown, never a shorter argument list (Main 1876 U)
    except (OSError, LookupError, IndexError, ValueError, AttributeError, struct.error):
        return None
    return [word.decode("utf-8", "surrogateescape") for word in words]


def admitted_client_running(holder: int, admitted, exclude: frozenset = frozenset()) -> bool:
    """Whether a process in HOLDER's tree, other than those in EXCLUDE, runs the no-mistakes client with the ADMITTED arguments.

    The client may be the binary itself or a script whose interpreter carries it
    as its first argument. True when the process table, or a live process's
    arguments, cannot be read, so an unreadable fact never stops a start being
    counted (Main 1712).
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
            if child in exclude:
                continue
            words = process_argv(child)
            if words is None:
                if pid_dead(child) is not True:
                    return True  # a live process whose arguments cannot be read could be the client
                continue
            if words and os.path.basename(words[0]) != "no-mistakes" and len(words) > 1 and os.path.basename(words[1]) == "no-mistakes":
                words = words[1:]
            if words and os.path.basename(words[0]) == "no-mistakes" and same_start_args(admitted, words[1:]):
                return True
    return False


@contextlib.contextmanager
def start_lock(directory: str):
    """Hold the pool's start lock (the lock every admission decision holds) for one short step."""
    fd = open_lock(os.path.join(directory, "pipeline-start.lock"))
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def publish_locked(directory: str, prefix: str, entry: dict) -> Tuple[int, str]:
    """Write a locked JSON entry and rename it into place, so no reader sees it unlocked or partial."""
    fd, temporary = tempfile.mkstemp(prefix="." + prefix, dir=directory)
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.set_inheritable(fd, False)
    os.write(fd, json.dumps(entry).encode())
    final = str(Path(directory) / (Path(temporary).name[1:] + ".lock"))
    os.rename(temporary, final)
    return fd, final


def waiter_census(directory: str) -> List[dict]:
    """Every live waiter entry, read once; OSError when the pool cannot be listed, ValueError when a live entry cannot
    be read or lacks a field of its type (an unknown waiter: the decision waits, Main 1812 B)."""
    found = []
    for path in list_pool(directory, "pipeline-waiter-*.lock"):
        try:
            fd = os.open(path, os.O_RDWR | getattr(os, "O_CLOEXEC", 0))
        except FileNotFoundError:
            continue
        try:
            if try_lock(fd):
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(path)
                continue
            entry = read_pending(fd)
        finally:
            os.close(fd)
        if (entry is None or entry.get("priority") not in PIPELINE_PRIORITIES or type(entry.get("queued_ns")) is not int
                or not (entry.get("run") is None or isinstance(entry.get("run"), str))
                or not (entry.get("pid") is None or type(entry.get("pid")) is int)):
            raise ValueError("waiter %s unreadable or malformed" % path)
        found.append(dict(entry, path=path))
    return found


def first_pipeline_waiter(directory: str) -> Tuple[str, frozenset]:
    """The first live waiter's path and the run IDs of every live launch-gate waiter (waiter_census).

    Locked entries are live waiters; a dead waiter's unlocked file is removed.
    """
    found = waiter_census(directory)
    first = min(((PIPELINE_PRIORITIES.index(e["priority"]), e["queued_ns"], e["path"]) for e in found), default=(0, 0, ""))
    return first[2], frozenset(e["run"] for e in found if e.get("run"))


def waiting_pids(directory: str) -> Dict[str, set]:
    """run -> the pids of its live queued launch gates (each gate execs in the launcher process the daemon started, so
    the step's recorded agent pid of a queued launch is its gate's). An unreadable pool or waiter is unknown: noted."""
    found: Dict[str, set] = {}
    try:
        census = waiter_census(directory)
    except (OSError, ValueError) as exc:
        note_unknown("waiter listing of %s unreadable: %s" % (directory, exc))
        return found
    for entry in census:
        if entry.get("run") and type(entry.get("pid")) is int:
            found.setdefault(entry["run"], set()).add(entry["pid"])
    return found


class HoldBound(Exception):
    """A launch reached its hold bound without a fit."""


def decision_context(directory: str, repo_id, branch) -> str:
    """Words every decision line carries: the deciding checkout (the admission owner), the pool, and the start's run."""
    return "checkout=%s pool=%s start_repo=%s start_branch=%s" % (
        Path(__file__).resolve().parent.parent, directory, repo_id or "unknown", branch or "unknown")


def wait_for_admission(directory: str, priority: str, self_run: Optional[str] = None,
                       bound: Optional[float] = None, on_wait=None, context: str = ""):
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
            "priority": priority, "queued_ns": time.time_ns(), "run": self_run, "pid": os.getpid()})
        admission_fd = open_lock(os.path.join(directory, "pipeline-start.lock"))
        next_notice = started + FIRST_NOTICE_SECS
        delay = POLL_MIN_SECS
        waited = decided = False
        while True:
            if interrupted:
                raise KeyboardInterrupt
            reason = "another start is registering"
            if try_lock(admission_fd):
                decided = True
                first, waiting = None, frozenset()
                try:
                    before, cores = pipeline_observation()
                    census_read = True
                except CensusUnknown as exc:
                    before, cores, census_read = {}, 0, False
                    reason = "unknown: %s; priority=%s (a decision waits until every fact reads)" % (exc, priority)
                counted = {run: repo for run, (repo, is_counted, _) in before.items() if is_counted}
                if census_read:
                    try:
                        first, waiting = first_pipeline_waiter(directory)
                    except (OSError, ValueError) as exc:
                        first, waiting = None, frozenset()
                        reason = "unknown: %s; counted=%d priority=%s (a decision waits until every fact reads)" % (
                            exc, len(counted), priority)
                if first is None:
                    pass
                elif first == waiter_path:
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
            if bound == 0 and decided:
                raise HoldBound(reason)  # a zero hold is one decision: no hold begins, so no hold line is written
            if on_wait is not None:
                on_wait(reason, time.monotonic() - started)
                on_wait = None
            now = time.monotonic()
            # A zero bound is one decision: start-lock contention alone, before any decision, is not one.
            if bound is not None and now - started >= bound and (bound > 0 or decided):
                raise HoldBound(reason)
            if now >= next_notice:
                log(2, "%s waiting: %s%s" % ("launch-gate" if self_run else "pipeline-start", reason, " " + context if context else ""))
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


def claim_pending(directory: str, args: List[str], direct: bool = True, cwd: Optional[str] = None) -> Optional[int]:
    """The pid of the enclosing admitted start whose pending reservation is this very start, or None.

    Under the pool's start lock (Main 1812 A), so no other decision or claim reads or
    publishes in between. An admitted start publishes a locked pending-*.lock naming its own
    pid and the no-mistakes arguments of the start it admitted. A later start is that start,
    reached through a nested route or the exec interception, only when that pid is one of
    its ancestors and claim_round finds the reservation unused or already its own. A record
    with the same arguments is claimed first; otherwise the first fresh client inside the
    admitted command claims its unclaimed record whatever its arguments (P5.lock). DIRECT:
    this start's COMMAND is the client itself; CWD: the directory its client runs in (this process's
    when None), which a claim binds (start_binding). Every other start is decided on its own, with
    that pending start counted unless it is this start's own enclosing one (counted_pending).
    """
    with start_lock(directory):
        _last_claim.clear()
        found = claim_round(directory, args, True, direct, cwd)
        if found is None:
            found = claim_round(directory, args, False, direct, cwd)
        claimed = _last_claim[0] if _last_claim else None
        _last_claim.clear()
        if found is None or claimed is None:
            return found
        # The final read of the run rows, the last step before the lock is released (Main 1876 L): a row that has
        # appeared since the claim's own read is no row of this client's (it has not run), so the claim is withdrawn
        # and this start is decided on its own. A row arriving after the unlock belongs to the next decision.
        path, rows, running, created_ns = claimed
        try:
            again = runs_since(running, created_ns)
        except (OSError, sqlite3.Error, ValueError):
            again = None
        if again is None or set(again) - set(rows):
            with contextlib.suppress(FileNotFoundError):
                os.unlink(path + ".claimed")
            return None
        return found


# The claim claim_round made in this call, for claim_pending's final read: (path, rows read, running, admitted ns).
_last_claim: List[tuple] = []


def claim_round(directory: str, args: List[str], same_args: bool, direct: bool = True,
                cwd: Optional[str] = None) -> Optional[int]:
    """One claim_pending pass: records with the same arguments, or any unclaimed one of an ancestor.

    Taken under the start lock. A claim already made by this process, or by an ancestor whose
    COMMAND is the client itself (direct), is this start passing one more route: its holder.
    A claim by an ancestor whose COMMAND is not the client (a shell) covers one client only
    (Main 1812 C): the first client below it binds it (client), later ones are decided on their
    own. A new claim is refused when any start's claimant is unknown, when a process in the
    holder's tree outside this client's own line runs the admitted client, or when a run row
    created since the admission, whatever its status now, covers no other start (pending_census:
    a counted run on that start's repository and branch; Main 1812 D, Main 3852): such a row may
    be this reservation's first client's. The rows are read once, after the client check: a
    first client that exited made its row before it exited, so its row is read. The rows are
    read again once the claim is published, and any new row withdraws it.
    """
    try:
        running = set(running_runs())
        census = pending_census(directory, running)
    except (OSError, sqlite3.Error, ValueError):
        return None  # without the run database or the pool listing nothing is known: no reservation is claimed
    if not all(item["known"] for item in census):
        return None
    covering: Dict[str, set] = {}
    for item in census:
        if item["covered"] is not None:
            covering.setdefault(item["covered"], set()).add(item["path"])
    me = os.getpid()
    cwd = os.getcwd() if cwd is None else cwd
    mine = None
    for item in census:
        entry, path = item["entry"], item["path"]
        if item["ended"] or entry is None:
            continue
        holder, admitted = entry["holder"], entry["args"]
        if same_args != same_start_args(admitted, list(args)):
            continue
        if mine is None:
            mine = ancestors(me)
        if holder not in mine:
            continue
        claim = item["claim"]
        if claim is not None:
            if claim["pid"] == me or claim["client"] == me:
                return holder  # this client passing one more route (one client pid, never its subtree: Main 1876 C)
            if claim["pid"] in mine and claim["direct"]:
                return holder  # an ancestor that is the client itself, one more route below it
            if claim["pid"] in mine and claim["client"] is None:
                # The first client below a shell its claimant admitted: it binds the claim, the shell's one client.
                try:
                    publish_claim(path, dict(claim, client=me, binding=start_binding(cwd)))  # client and binding together
                except OSError:
                    return None
                return holder
            continue  # claimed by another client: this one is decided on its own
        if item["claimed"] is not False:
            continue  # claimed, or its claim cannot be told from none
        if not isinstance(admitted, list) or admitted_client_running(holder, admitted, exclude=frozenset(mine) | {me}):
            continue  # the admitted client itself may run on that reservation: one client, one reservation
        try:
            rows = runs_since(running, entry["created_ns"])
        except (OSError, sqlite3.Error, ValueError):
            return None
        before = set(entry["before"])
        if any(run not in before and not covering.get(run, set()) - {path} for run in rows):
            continue  # a run that may be this reservation's own client's appeared: its admission may be used
        claim = dict(pid=me, direct=direct, client=me if direct else None, binding=start_binding(cwd))
        try:
            published = publish_claim(path, claim, new=True)
        except OSError:
            return None
        if not published:
            continue  # another client claimed it first
        _last_claim[:] = [(path, rows, running, entry["created_ns"])]  # claim_pending reads the rows again last
        return holder
    return None


def publish_claim(path: str, claim: dict, new: bool = False) -> bool:
    """Write CLAIM whole as PATH's claim: with NEW, only when none exists (False when one does); else replace it."""
    temporary = "%s.claimed.%d" % (path, os.getpid())
    try:
        with open(temporary, "w") as handle:
            handle.write(json.dumps(claim))
        if new:
            try:
                os.link(temporary, path + ".claimed")
            except FileExistsError:
                return False
        else:
            os.replace(temporary, path + ".claimed")
            temporary = None
        return True
    finally:
        if temporary is not None:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)


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
            words, split, _ = operands
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

    It lives in the user's temporary directory, never in the pool and never inside
    a git work tree (a TMPDIR inside a project copy is passed over for the user's
    default temporary directory, then /tmp), is created 0700 and used only when it
    is a real directory this user owns.
    """
    import hashlib
    digest = hashlib.sha256(INTERCEPT_TARGET.encode()).hexdigest()[:12]
    candidates = [tempfile.gettempdir()]
    with contextlib.suppress(ValueError, OSError, AttributeError):
        candidates.append(os.confstr("CS_DARWIN_USER_TEMP_DIR") or "")
    candidates.append("/tmp")
    outside = [path for path in candidates if path and not any(
        os.path.exists(os.path.join(parent, ".git")) for parent in [os.path.realpath(path)] + list(map(str, Path(os.path.realpath(path)).parents)))]
    if not outside:
        raise OSError("every temporary directory is inside a git work tree")
    directory = os.path.join(outside[0], "fm-exec-intercept-%d-%s" % (os.getuid(), digest))
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
    interception cannot be placed: the reason is printed and recorded in the root
    home's wake queue, so the degraded state is visible, and the caller holds a
    command naming no-mistakes as a start (intercept_unavailable_passes).
    """
    out = without_intercept(env)
    try:
        directory = intercept_dir()
    except OSError as exc:
        text = ("the no-mistakes exec interception is unavailable in this home (%s): a command naming no-mistakes is "
                "admitted as one fresh start; any other command runs at once, and a fresh start inside it is admitted "
                "only by run-creation admission (nm-run-creation-admission)" % exc)
        log(2, "pipeline-start: " + text)
        record_check("exec-interception-unavailable", "pipeline-start: " + text)
        return None
    out["PATH"] = directory + (os.pathsep + out["PATH"] if out.get("PATH") else "")
    out[INTERCEPT_PRIORITY_ENV] = priority
    return out


def intercept_unavailable_passes(command: List[str]) -> bool:
    """Whether a command runs at once, unadmitted, when the interception cannot be placed (Main 4938).

    A command no word of which names no-mistakes runs as on the base; so does the
    no-mistakes client itself when its own argv is no new run (a reattachment,
    response or status read). Any other command naming no-mistakes is held as one
    fresh start. A script with no such word that starts a fresh run is the
    disclosed residual of an unplaceable interception, owned by run-creation
    admission.
    """
    if not any("no-mistakes" in word for word in command):
        return True
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
            # Under the start lock, so a decision sees this start either counted or its run registered, never neither.
            with start_lock(directory):
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
        # The directory its client runs in: this one, or the one an env -C/--chdir names.
        cwd = None if route is None else os.path.join(os.getcwd(), route[3]) if route[3] else os.getcwd()
        if route is not None:
            holder = claim_pending(directory, route[0], direct=runs_client_directly(command), cwd=cwd)
            if holder is not None:
                log(2, "pipeline-start: this start was admitted by its enclosing start (pid %d); not queued again" % holder)
                _restore_exec_signals()
                return exec_direct(command, child_environment, 2)
        # The reservation is bound now to the repository and branch its client starts from: this directory, or the one
        # an env -C/--chdir names. A client reached through the interception binds it again from its own directory when
        # it claims (claim_pending). Until then, a COMMAND that changes directory another way (a shell's cd) is bound
        # to this directory, and a counted run on this directory's branch may cover it although its client starts
        # elsewhere.
        binding = start_binding(cwd) if route is not None else None
        context = decision_context(directory, (binding or {}).get("repo"), (binding or {}).get("branch"))
        admission_fd, before, reason, _ = wait_for_admission(directory, args.priority, context=context)
        log(2, "pipeline-start admitted: %s %s" % (reason, context))
        # In the same locked step as the admit, publish this start's pending reservation: every later decision
        # counts it at the full R until its COMMAND returns or its client exits (K7), except while a counted run is
        # on its repository and branch (pending_census).
        pending_fd, pending_path = publish_locked(directory, "pending-", {
            "holder": os.getpid(), "args": None if route is None else list(route[0]), "shell": route is None or route[2],
            "before": sorted(before), "created_ns": time.time_ns(), "binding": binding})
        fcntl.flock(admission_fd, fcntl.LOCK_UN)
        os.close(admission_fd)
        admission_fd = None
        return run_child(command, child_environment, 2, cancellable=True)
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


HOLDS_RECORD = "launch-holds.jsonl"


def held_launches(directory: str) -> List[dict]:
    """Every held launch the gate recorded in this pool (run, step, gate start epoch, attempt); OSError when unreadable."""
    path = os.path.join(directory, HOLDS_RECORD)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        return []
    found = []
    for line in lines:
        try:
            entry = json.loads(line)
            found.append(dict(run=str(entry["run"]), step=str(entry["step"]), gate_started=float(entry["gate_started"])))
        except (ValueError, KeyError, TypeError):
            raise OSError("unreadable hold record line in %s" % path)
    return found


def record_hold(directory: str, run: str, step: str, gate_started: float, attempt: str) -> None:
    """Append one held launch, so a later bound can leave the invocation it spent out of its percentile."""
    line = json.dumps(dict(run=run, step=step, gate_started=gate_started, attempt=attempt)) + "\n"
    fd = os.open(os.path.join(directory, HOLDS_RECORD), os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_CLOEXEC", 0), 0o600)
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)


def step_p99(step: str, holds: List[dict]) -> Tuple[Optional[float], int, int, int]:
    """(nearest-rank 99th percentile seconds or None, rows counted, rows left out as held, ambiguous holds).

    The rows are this step's completed invocations (exit_status ok, duration_ms > 0):
    a refused, timed-out or cancelled launch is recorded too, and counting it would
    let refusals shrink the next bound. A held launch spent its own invocation's
    clock waiting, so its row is left out. A hold's candidates are the rows of its
    run and step that began no later than the gate and ended no earlier: one
    candidate is that hold's row; with several the association is ambiguous, and
    each ambiguous hold leaves out its smallest candidate not already left out, which
    gives the largest feasible percentile (removing a smaller row never lowers an
    order statistic); a hold with no candidate (its row not written yet) leaves
    nothing out. Rows recorded before the gate existed match no hold.
    """
    rows = read_host_db(
        "SELECT rowid, run_id, started_at, completed_at, duration_ms FROM agent_invocations"
        " WHERE step_name = ? AND exit_status = 'ok' AND duration_ms > 0", (step,))
    excluded: set = set()
    ambiguous = 0
    choices = []
    for hold in holds:
        if hold["step"] != step:
            continue
        candidates = sorted((row[4], row[0]) for row in rows if row[1] == hold["run"]
                            and type(row[2]) is int and type(row[3]) is int
                            and row[2] <= math.ceil(hold["gate_started"]) and row[3] >= math.floor(hold["gate_started"]))
        if len(candidates) > 1:
            ambiguous += 1
        if candidates:
            choices.append(candidates)
    for candidates in sorted(choices, key=lambda found: (len(found) > 1, found[0])):
        for _, rowid in candidates:
            if rowid not in excluded:
                excluded.add(rowid)
                break
    values = [row[4] for row in rows if row[0] not in excluded]
    p99 = rank_quantile(values, CI_FIX_QUANTILE) / 1000.0 if values else None
    return p99, len(values), len(excluded), ambiguous


def hold_bound(directory: str, step: str, round_started) -> Tuple[float, str]:
    """How long a launch may wait for capacity inside what remains of its agent's budget, and its inputs.

    The daemon's invocation deadline starts before the launcher runs and no earlier
    than the current round's start (step_results.round_started_at), so the remaining
    budget is the budget less the time since that start; the hold leaves the
    step's 99th percentile of unheld completed invocations for the agent. Any
    unreadable input, or a difference that is not positive, holds not at all.
    """
    budget = agent_budget_secs()
    elapsed = None if type(round_started) is not int else max(0.0, time.time() - round_started)
    try:
        p99, counted, held, ambiguous = step_p99(step, held_launches(directory))
    except (OSError, sqlite3.Error, ValueError):
        p99, counted, held, ambiguous = None, 0, 0, 0
    label = "ci_fix_p99" if step == CI_STEP else "%s_p99" % step
    show = lambda value: "unreadable" if value is None else "%ds" % value  # noqa: E731
    text = "budget=%s round_elapsed=%s %s=%s n=%d held=%d ambiguous=%d" % (
        show(budget), show(elapsed), label, show(p99), counted, held, ambiguous)
    if budget is None or elapsed is None or p99 is None or budget - elapsed - p99 <= 0:
        return 0.0, "hold_bound=0s " + text
    return budget - elapsed - p99, "hold_bound=%ds %s" % (budget - elapsed - p99, text)


# The step names the daemon can write (no-mistakes fork internal/types/types.go: AllSteps, line 131-132;
# custom gates "gate.<anchor>.<label>", decodeCustomGate and ValidCustomGateLabel, lines 166-224).
CORE_STEPS = ("intent", "rebase", "review", "test", "document", "lint", "push", "pr", "ci")
GATE_ANCHORS = ("rebase", "review", "test", "document", "lint")
GATE_LABEL_MAX = 40


def recognized_step(name) -> bool:
    """Whether NAME is a step the daemon can write: a core step or a well-formed custom gate."""
    if not isinstance(name, str):
        return False
    if name in CORE_STEPS:
        return True
    anchor, _, label = name[len("gate."):].partition(".") if name.startswith("gate.") else ("", "", "")
    return (anchor in GATE_ANCHORS and 0 < len(label) <= GATE_LABEL_MAX
            and all(c.islower() and c.isascii() or c.isdigit() or (c == "-" and 0 < i < len(label) - 1)
                    for i, c in enumerate(label)))


class PassThrough(Exception):
    """The launch is not gated work: exec the agent at once, unchanged."""


def map_worktree(cwd: str) -> Tuple[str, str, str, bool]:
    """(run ID, repo ID, branch, counted) of the one run whose worktree_dir is this directory.

    A directory that is no run's worktree but is a registered repository's
    checkout (repos.working_path) is the attach wizard's call and raises
    PassThrough; every other outcome that is not exactly one run raises
    LaunchRefused.
    """
    paths = sorted({cwd, os.path.realpath(cwd)})
    marks = ",".join("?" * len(paths))
    try:
        rows = read_host_db("SELECT DISTINCT id, repo_id, branch, status = 'running' AND ci_ready_at IS NULL"
                            " AND awaiting_agent_since IS NULL FROM runs WHERE worktree_dir IN (%s)" % marks, tuple(paths))
        checkout = [] if rows else read_host_db("SELECT id FROM repos WHERE working_path IN (%s)" % marks, tuple(paths))
    except (OSError, sqlite3.Error, ValueError) as exc:
        raise LaunchRefused("run database unreadable", str(exc),
                            "restore read access to the run database; the next fix round enters the gate again")
    if checkout:
        raise PassThrough()
    if not rows:
        raise LaunchRefused("unmapped worktree", "no run records %s" % cwd,
                            "launch the agent from a run worktree; a launch outside any run is not gated work")
    if len(rows) > 1:
        raise LaunchRefused("ambiguous worktree", "runs %s all record %s" % (",".join(r[0] for r in rows), cwd),
                            "resolve which run owns this worktree; the next fix round enters the gate again")
    run, repo, branch, counted = rows[0]
    return run, repo, branch, bool(counted)


def record_check(key: str, text: str) -> bool:
    """Append one check wake to the root home's queue without waiting for its lock; False when it is not recorded.

    When the queue lock is busy the wake is spilled to state/.wake-spill.<seq>,
    which the next append to that queue, or the watcher's next start, replays;
    a spill never replaces another producer's spill (fm_wake_pending_settle).
    """
    try:
        home = root_home()
        subprocess.run(["bash", "-c", '. "$1" && FM_WAKE_PENDING_KIND=check FM_WAKE_PENDING_KEY=$2 FM_WAKE_PENDING_PAYLOAD=$3'
                        ' && fm_wake_pending_settle', "bash",
                        str(Path(__file__).with_name("fm-wake-lib.sh")), key, "check: " + text],
                       env=dict(os.environ, FM_HOME=str(home)), stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
        return True
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        log(2, "check not recorded (%s): %s" % (exc, text))
        return False


def durable_line(text: str, key: str) -> bool:
    """The first record of a gate line: one check wake in the root home's queue (record_check); False when not written."""
    return record_check(key, "launch-gate: " + text)


def status_log_line(branch, key: str, text: str) -> bool:
    """The second record of a refusal: one line in the run's own task status log (Main 4930 Q1); False when unwritable.

    The task is the one whose ship branch is the run's branch (fm/<task-id>) and whose
    state/<task-id>.meta exists in the root home; the line goes through the sanctioned
    bin/fm-status-append.sh. A run with no such task (an unmapped launch, another
    branch) has no status log: that record is unwritable for this refusal.
    """
    if not isinstance(branch, str) or not branch.startswith("fm/") or not branch[3:] or "/" in branch[3:]:
        return False
    try:
        state = root_home() / "state"
    except (OSError, ValueError, subprocess.SubprocessError):
        return False
    task = branch[3:]
    if not (state / (task + ".meta")).exists():
        return False
    line = "launch-gate [at=%d] [key=%s]: %s" % (int(time.time()), key, text)
    try:
        done = subprocess.run(["bash", str(Path(__file__).with_name("fm-status-append.sh")), str(state / (task + ".status")), line],
                              # fm-status-append.sh waits at most 10 s for the log's lock; five uncontended appends took at most 0.01 s.
                              # measured: value=30 date=2026-11-15 host=Mac-Studio.local margin=3
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        log(2, "launch-gate: status-log line not recorded (%s): %s" % (exc, text))
        return False
    if done.returncode != 0:
        log(2, "launch-gate: status-log line not recorded (exit %d): %s" % (done.returncode, text))
    return done.returncode == 0


def refuse_visibly(text: str, key: str, branch) -> None:
    """A refusal's records (the P9 storage table): the visible line on the caller's error output, then each record it can write."""
    log(2, text)
    durable_line(text, key)
    status_log_line(branch, key, text)


def resume_session_key(command: List[str]) -> Optional[str]:
    """The invocation's own session key when the launch resumes a session (--resume <id>), as the daemon writes it."""
    import hashlib
    for index, word in enumerate(command):
        if word == "--resume" and index + 1 < len(command) and command[index + 1]:
            return hashlib.sha256(command[index + 1].encode()).hexdigest()[:16]
        if word.startswith("--resume="):
            return hashlib.sha256(word.split("=", 1)[1].encode()).hexdigest()[:16]
    return None


def start_watched(command: List[str], directory: str, base: dict) -> Tuple[int, int, str, int, int]:
    """Start the agent as this gate's child, its attempt record published before it can run.

    The agent's child process waits for a go byte before it execs. Before go the gate
    records the attempt (P9.sequence(5), Main 1656): its root (the child, by pid and exact
    kernel start time), the gate and its watcher (never counted), the launch coalition and
    t0; so an agent can never run unrecorded, and a gate that dies before go leaves a child
    that exits without starting the agent. The agent's standard output goes to a pipe the
    gate relays byte for byte, so the invocation's own session key can be read (P2).
    A forked watcher, holding only a pipe the gate writes, kills the agent and the group the
    gate leads if the gate dies without finishing.
    Returns (agent pid, watcher pipe, record path, relay read end, published_ns);
    FileNotFoundError or PermissionError when the agent cannot be executed, LaunchRefused
    when the process facts cannot be read (the agent never starts).
    """
    gate = os.getpid()
    t0_us = int(time.time() * 1000000)
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
    relay_read, relay_write = os.pipe()
    go_read, go_write = os.pipe()
    error_read, error_write = os.pipe()
    child = os.fork()
    if child == 0:  # pragma: no cover - exercised through the executable
        try:
            os.close(go_write)
            os.close(error_read)
            os.close(write_end)
            os.close(relay_read)
            os.dup2(relay_write, 1)
            os.close(relay_write)
            _restore_default_signals()
            _restore_exec_signals()
            if os.read(go_read, 1) != b"g":
                os._exit(125)
            os.execvp(command[0], command)
        except OSError as exc:
            os.write(error_write, str(exc.errno).encode())
        finally:
            os._exit(127)
    for fd in (go_read, error_write, relay_write):
        os.close(fd)
    try:
        snapshot = kernel_snapshot()
        root, gate_entry, watcher_entry = snapshot[child], snapshot[gate], snapshot.get(watcher)
    except (OSError, ValueError, KeyError, AttributeError) as exc:
        os.close(go_write)
        os.waitpid(child, 0)
        os.write(write_end, b"d")
        os.close(write_end)
        raise LaunchRefused("process facts unreadable", "the attempt cannot be recorded before its agent runs: %s" % exc,
                            "restore read access to the kernel process table; the next launch enters the gate again")
    record = dict(base, id=os.urandom(16).hex(), t0_us=t0_us, root=[child, root[1]], gate=[gate, gate_entry[1]],
                  watcher=[watcher, watcher_entry[1]] if watcher_entry else None, coalition=gate_entry[2],
                  session_key=resume_session_key(command), members=[], ended_us=None)
    path = write_attempt(directory, record)
    published_ns = time.time_ns()
    os.write(write_end, str(child).encode().ljust(32))
    os.write(go_write, b"g")
    os.close(go_write)
    failure = os.read(error_read, 32)
    os.close(error_read)
    if failure:
        os.waitpid(child, 0)
        os.write(write_end, b"d")
        os.close(write_end)
        os.close(relay_read)
        code = int(failure)
        raise (FileNotFoundError if code == errno.ENOENT else PermissionError)(code, os.strerror(code), command[0])
    return child, write_end, path, relay_read, published_ns


def relay_output(relay_fd: int, record_path: str, known: bool) -> None:
    """Copy the agent's standard output to the gate's own, unchanged, until end of file.

    Until the session key is known, the first stream-json lines are read for a system
    line's session_id, and its key (sha256, 16 hex digits, as the daemon writes it) is put
    in the attempt record.
    """
    import hashlib
    pending = b""
    while True:
        try:
            chunk = os.read(relay_fd, 65536)
        except InterruptedError:  # pragma: no cover - PEP 475 retries
            continue
        except OSError:
            break
        if not chunk:
            break
        view = memoryview(chunk)
        while view:
            try:
                written = os.write(1, view)
            except OSError:
                written = len(view)  # the caller stopped reading: drain the agent as a closed pipe would not block it
            view = view[written:]
        if not known:
            pending += chunk
            while b"\n" in pending and not known:
                line, pending = pending.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if isinstance(message, dict) and message.get("type") == "system" and isinstance(message.get("session_id"), str):
                    key = hashlib.sha256(message["session_id"].encode()).hexdigest()[:16]
                    update_attempt(record_path, lambda record: record.__setitem__("session_key", key))
                    known = True
            if len(pending) > 1048576:
                known = True  # no session line in the first MiB: the key stays unknown, the run stays held
    os.close(relay_fd)


def cmd_launch_gate(args: argparse.Namespace) -> int:
    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        log(2, "launch-gate needs an agent command after --")
        return 125
    started = time.monotonic()
    run = branch = None
    cwd = "unknown"
    # This launch attempt's identity: the gate's pid and start time (a retry is a new attempt).
    attempt = "%d:%d" % (os.getpid(), time.time_ns())
    try:
        cwd = os.getcwd()
        try:
            run, repo, branch, counted = map_worktree(cwd)
        except PassThrough:
            # A registered checkout that is no run's worktree (the attach wizard): no run, no reservation.
            _restore_exec_signals()
            return exec_direct(command, dict(os.environ), 2)
        steps = open_steps()
        if steps is None:
            raise LaunchRefused("step not established: step facts unreadable", "run %s" % run,
                                "restore read access to the run database's step table; the next fix round enters the gate again")
        step = steps.get(run)
        if step is None:
            raise LaunchRefused("step not established: no open step for run %s" % run, "no running or fixing step row",
                                "check the run's step state in no-mistakes; a launch whose step cannot be established is never started")
        if not recognized_step(step[0]):
            raise LaunchRefused("step not established: unrecognized step %r" % step[0], "run %s" % run,
                                "update the gate's step list to the daemon's; a launch whose step cannot be established is never started")
        directory = pool_dir()
        ensure_pool_dir(directory)
        base = dict(run=run, repo=repo, step=step[0], round_started=step[3])
        if counted and step[0] != CI_STEP:
            # Another step of a run already counted as active: at once, unheld and unreserved, with no output of the
            # gate's own; its attempt is recorded so the run's release can be shown later (P2, Main 1656). The record
            # is published under the start lock, with the run's facts read again inside it, so no decision's census
            # misses it (Main 1812 A).
            passive = None
            with start_lock(directory):
                try:
                    again = map_worktree(cwd)
                except PassThrough:
                    again = None
                if again is None:
                    pass
                else:
                    steps = open_steps()
                    step_now = None if steps is None else steps.get(again[0])
                    if again[0] == run and again[3] and step_now is not None and recognized_step(step_now[0]) \
                            and step_now[0] != CI_STEP:
                        try:
                            passive = start_watched(command, directory, dict(base, step=step_now[0], round_started=step_now[3],
                                                                             reserves=False))
                        except (FileNotFoundError, PermissionError, NotADirectoryError) as exc:
                            log(2, "command %s: %s" % ("not found" if isinstance(exc, FileNotFoundError) else "not executable", command[0]))
                            return 127 if isinstance(exc, FileNotFoundError) else 126
            if again is None:
                # Its worktree became a registered checkout that is no run's (the attach wizard): passed through.
                _restore_exec_signals()
                return exec_direct(command, dict(os.environ), 2)
            if passive is not None:
                child, watch_fd, path, relay_fd, _ = passive
                return wait_agent(child, watch_fd, relay_fd, path, resume_session_key(command) is not None)
            # The run reached its CI step, left the counted set or lost its step meanwhile: it meets the gate below.
            if step_now is None or not recognized_step(step_now[0]):
                raise LaunchRefused("step not established: the run's step changed and cannot be read", "run %s" % run,
                                    "check the run's step state in no-mistakes; a launch whose step cannot be established is never started")
            run, repo, branch, counted = again
            step = step_now
            base = dict(run=run, repo=repo, step=step[0], round_started=step[3])
        log(2, "launch-gate run=%s branch=%s step=%s:%s counted=%s agent_pid=%s attempt=%s" % (
            run, branch, step[0], step[1], "yes" if counted else "no", step[2], attempt))
        bound, bound_text = hold_bound(directory, step[0], step[3])
        gate_started = time.time()
        held = []

        def on_wait(reason: str, waited: float) -> None:
            held.append(reason)
            record_hold(directory, run, step[0], gate_started, attempt)
            if not durable_line("run %s (%s) held for capacity before its %s agent starts, waited %.2fs so far: %s; %s" % (
                    run, branch, step[0], waited, reason, bound_text), "launch-gate-" + run):
                # A hold that cannot write its line does not wait silently (P9.visible): it refuses visibly.
                raise LaunchRefused("hold line not recorded", "the first record (the root home's wake queue) is unwritable",
                                    "restore the root home's state directory; the next launch enters the gate again")

        try:
            admission_fd, _, reason, waited = wait_for_admission(directory, "other", run, bound, on_wait,
                                                                 context=decision_context(directory, repo, branch))
        except HoldBound as reached:
            raise LaunchRefused("hold bound reached", "%s; held %ds; last reading: %s" % (
                bound_text, time.monotonic() - started, reached),
                "this fix attempt ends and the run keeps its CI step; the daemon retries while auto_fix.ci allows, then "
                "parks the CI findings as an ask-user decision; answer it once capacity has returned"
                if counted and step[0] == CI_STEP else
                "this launch fails and its run fails with it (Main 1838: the run is outside the counted set, so it is "
                "never started without capacity); restart the run once capacity has returned")
        admitted_ns = time.time_ns()
        try:
            # In the same locked step as the admit, the attempt's record is published before the agent can run.
            try:
                child, watch_fd, path, relay_fd, published_ns = start_watched(command, directory, dict(base, reserves=True))
            except (FileNotFoundError, PermissionError, NotADirectoryError) as exc:
                # The shell's statuses for an agent that cannot be launched, reported unchanged.
                log(2, "launch-gate: agent %s: %s" % ("not found" if isinstance(exc, FileNotFoundError) else "not executable", command[0]))
                return 127 if isinstance(exc, FileNotFoundError) else 126
            started_ns = time.time_ns()
        finally:
            os.close(admission_fd)
        unlocked_ns = time.time_ns()
        log(2, "launch-gate admitted: %s %s %s admitted_ns=%d published_ns=%d agent_started_ns=%d unlocked_ns=%d" % (
            reason, decision_context(directory, repo, branch), bound_text, admitted_ns, published_ns, started_ns, unlocked_ns))
        if held:
            durable_line("run %s (%s) admitted after %.2fs held: %s" % (run, branch, waited, reason), "launch-gate-" + run)
        return wait_agent(child, watch_fd, relay_fd, path, resume_session_key(command) is not None)
    except LaunchRefused as refused:
        # With no run identified (unmapped, ambiguous, unreadable database) the line names the worktree and attempt.
        text = "launch-gate refused: %s: %s; %s; next action: %s" % (
            refused.cause, "run %s" % run if run else "worktree %s, attempt %s" % (cwd, attempt), refused.detail, refused.action)
        refuse_visibly(text, "launch-gate-" + (run or "unmapped"), branch)
        return 75
    except KeyboardInterrupt:
        return 130
    except (PoolUnavailable, OSError, sqlite3.Error, ValueError, KeyError) as exc:
        text = "launch-gate refused: gate error: %s; %s; next action: repair the gate source named here; the next fix round enters the gate again" % (
            "run %s" % run if run else "worktree %s, attempt %s" % (cwd, attempt), exc)
        refuse_visibly(text, "launch-gate-" + (run or "unmapped"), branch)
        return 75


def wait_child(pid: int) -> int:
    """The agent's ending as subprocess reports it: its exit status, or minus the signal that ended it."""
    while True:
        _, status = os.waitpid(pid, 0)
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return -os.WTERMSIG(status)


def wait_agent(child: int, watch_fd: int, relay_fd: int, record_path: str, session_known: bool) -> int:
    """Forward signals to the agent, relay its output, and return or re-raise its own ending.

    The attempt record outlives this gate: the agent's reservation follows the attempt's
    processes (judge_attempts), never this gate's life. The gate returns after the agent
    exits and its standard output reaches end of file, or at most RELAY_AFTER_EXIT_SECS after
    the agent exits.
    """
    import threading
    relay = threading.Thread(target=relay_output, args=(relay_fd, record_path, session_known), daemon=True)
    relay.start()
    # The agent runs in the gate's process group (the daemon gives the launcher its own group). A signal sent to the
    # gate goes to that whole group, so it reaches the agent below a dispatcher (tc run's spawnSync child), not only
    # the gate's direct child; the gate ignores its own copy, and the watcher ignores these three. A gate that does not
    # lead its group signals its direct child only, so it never signals its caller.
    leads = os.getpgid(0) == os.getpid()

    def forward(signum, _frame):
        previous = signal.signal(signum, signal.SIG_IGN)
        try:
            with contextlib.suppress(OSError):
                if leads:
                    os.killpg(os.getpid(), signum)
                else:
                    os.kill(child, signum)
        finally:
            signal.signal(signum, previous)

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, forward)
    try:
        code = wait_child(child)
        # A descendant that kept the agent's output open would hold this relay without end; the daemon closes such
        # pipes RELAY_AFTER_EXIT_SECS after its launcher exits, so the gate drains for at most that long and returns.
        ends = time.monotonic() + RELAY_AFTER_EXIT_SECS
        while relay.is_alive() and time.monotonic() < ends:
            relay.join(0.2)
    except BaseException:
        with contextlib.suppress(OSError):
            os.kill(child, signal.SIGKILL)
        with contextlib.suppress(OSError):
            os.waitpid(child, 0)
        raise
    finally:
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
    run.add_argument("--wait-file", default="", help="file receiving the milliseconds spent queued before COMMAND starts")
    run.add_argument("command", nargs=argparse.REMAINDER, help="-- COMMAND [ARGS...]")
    start = sub.add_parser("pipeline-start", help="queue a fresh pipeline start before its execution clock")
    start.add_argument("--priority", choices=PIPELINE_PRIORITIES, default="other", help="start class in descending priority order")
    start.add_argument("--only-fresh", action="store_true", help="run COMMAND without admission unless it begins a new no-mistakes run")
    start.add_argument("command", nargs=argparse.REMAINDER, help="-- COMMAND [ARGS...]")
    intercept = sub.add_parser("exec-intercept", help="run as no-mistakes from a route's exec interception (internal)")
    intercept.add_argument("command", nargs=argparse.REMAINDER, help="-- ARGS of the no-mistakes client")
    gate = sub.add_parser("launch-gate", help="secure capacity for a CI fix agent before it starts (the agent launcher's final exec)")
    gate.add_argument("command", nargs=argparse.REMAINDER, help="-- AGENT [ARGS...]")
    activate = sub.add_parser("activate", help="write the pool's gate activation record once (the deployment step)")
    activate.add_argument("--gate", required=True, help="the gate file the agent launcher's final line names")
    status = sub.add_parser("status", help="report held and free passes")
    status.add_argument("--json", action="store_true", help="print one JSON object")
    sub.add_parser("size", help="print the pool size")
    guard = sub.add_parser("guard", help=argparse.SUPPRESS)  # internal: the process that keeps a command's passes
    guard.add_argument("--fd", type=int, required=True)
    guard.add_argument("--ready-fd", type=int, required=True)
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
    if args.action == "exec-intercept":
        return cmd_exec_intercept(args)
    if args.action == "launch-gate":
        return cmd_launch_gate(args)
    if args.action == "activate":
        return cmd_activate(args)
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
