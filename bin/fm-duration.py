#!/usr/bin/env python3
"""Host-local command timing and timeout ownership.

Usage: fm-duration.py record KEY MILLISECONDS EXIT [--sample-id ID] [--uncalibrated] [--timed-out] [--load-start LOAD]
       fm-duration.py record-batch < KEY<TAB>MS<TAB>EXIT<TAB>CALIBRATION<TAB>LOAD_START<TAB>LOAD_END<TAB>TIMED_OUT lines
       fm-duration.py limit KEY [--percentile 95|99] [--margin N] [--fallback SECONDS]
       fm-duration.py run KEY -- COMMAND [ARGS...]
       fm-duration.py gate [--log-fd N] [--wait-file PATH] KEY -- COMMAND [ARGS...]
       fm-duration.py slots KEY
       fm-duration.py import-nm DATABASE RUN_ID
       fm-duration.py timeout KEY MILLISECONDS [--event-id ID]
       fm-duration.py path
       fm-duration.py check-literals [--base REF | --report]

The JSONL table is FM_DURATION_FILE, otherwise FM_DURATION_HOME/data/command-durations.jsonl
(the owning home fm-spawn exports to ship and scout workers), otherwise
FM_DATA_OVERRIDE/command-durations.jsonl, otherwise FM_HOME/data/command-durations.jsonl.
With no home supplied the code root is the home; a write there reports once that
the record is checkout-local and not durable. path prints the resolved table.
FM_DURATION_FILE=off disables recording (fixture copies should use off or their
own isolated file). Writers hold an exclusive flock on the sibling .lock file
and readers a shared one.

A variable that is set but empty names nothing and counts as unset. A location
variable must be an absolute path, so the table never resolves against the
caller's directory. The table, its .lock and .compact siblings, and the
calibration scratch file are never written inside a git work tree unless the
table sits under the home's data directory and that work tree is a firstmate
checkout (it holds bin/fm-duration.py): a firstmate tool must not
change a project copy. A refused location prints one stderr line, records
nothing and exits 0 (path prints off, limit keeps the caller's fallback);
gitignore is never relied on to hide a misplaced write. Recording and
process-group execution require POSIX Python; pure literal lint works on native
Windows Python, while limit explicitly preserves the existing fallback when
POSIX locks are absent.

Every row, limit and filing is scoped to host and repository: the helper derives
the repository from the origin remote of the working directory (owner/name), else
the top-level directory name, so one repository's samples never set another's
ceiling; rows without a repository are not used for limits. Keys stay short.
Rows carry host, repository, command key, wall milliseconds, exit, timestamp, the 1-minute
load at start and at end (data only, never a selection rule) and CPU count;
optional sample ids deduplicate imported no-mistakes steps, whose historical
load is unknown; import-nm records them under no-mistakes-step.<step>, apart from
the no-mistakes.<step> key of a wrapped drive call, and they are record-only: no
run or limit for another key ever reads them. Only successful completed calibration-eligible samples enter
nearest-rank percentiles. Cache hits, partial lint selections and memory-fallback
successes remain recorded with calibration=false and cannot shrink a
cold-analysis deadline. --uncalibrated records other successful work that is not
evidence for that command's ceiling. Timeout rows are censored lower bounds, not
completed latency.

A limit is max(caller's explicit or fallback bound, percentile x the stated
margin), rounded up to whole seconds, so measurement can raise an operator bound
but never lower it. Sample-count policy: a host/key needs MIN_SAMPLES eligible
samples before its measured value applies; below that, limit reports the missing
calibration and returns the caller's fallback, or zero (no destructive deadline
while gathering calibration). A shell caller whose fallback is 0 had no deadline
before this table existed, so fm_duration_limit keeps it record-only and never
applies a measured kill. Retention policy: compaction keeps the newest
KEEP_SAMPLES samples per host, repository and key once any of them exceeds
COMPACT_AT sample rows; timeout and filed rows are always kept.

The default margin is 3; run uses p99 x 3 for its outer ceiling. Polling cadence
is observation, not a failure deadline. Output growth and cumulative process-tree
CPU time report progress; neither an idle or failed sample nor an elapsed read
wait kills work. Completion of the command's leader, signal, or the measured
outer ceiling ends the run; descendants that outlive the leader and still hold
its output streams are neither awaited nor counted as live work.
A ceiling expiry or the first forwarded signal sends SIGTERM to the process group
and then waits for the leader to exit, with no guessed grace number. SIGKILL goes
to the group only when the leader has exited and group members remain, on a
second forwarded signal, or when a further full measured ceiling passes with the
leader still alive, so a leader's own TERM cleanup always gets to run.
run exports FM_DURATION_MANAGED_KEY so a self-instrumented command with the same
key leaves its one complete wall-time sample to the outer runner.
It also exports a task-local FM_DURATION_CALIBRATION_FILE: self-instrumented
commands write 0 there to exclude a warm/partial run, or 1 for eligible work.
The runner propagates the classification to its own sample and removes the file.

Per-key slot gate. A test.* key admits at most FM_TEST_KEY_SLOTS concurrent
copies (default 2; 0 turns the gate off; whole numbers up to 16) host-wide, so
the same heavy suite started in several worktrees takes turns instead of
multiplying its process churn. run takes a slot before it starts its clock, so
the wait is in neither the recorded sample nor the measured ceiling; gate is for
a caller that times COMMAND itself (bin/fm-test-run.sh wraps each script in it):
it runs COMMAND with this process's stdio and the --log-fd descriptor, and
writes the milliseconds it waited for the slot to --wait-file before COMMAND
starts, so that caller can leave the wait out of its sample. Slots are exclusive
non-blocking flock files in a per-key directory under FM_TEST_SLOT_DIR, else
$HOME/.cache/fm-test-slots, created mode 0700 and owned by the caller. The
kernel releases a flock on every exit, SIGKILL included, so no lock directory
needs repair and a killed run frees its slot at once; the lock is held by this
process alone and never inherited by COMMAND, so a test's own leftover daemon
can never hold a slot for good. Each holder writes a record of its pid, its
process start time, its working directory and its start epoch; a waiter's
notice names the key it waits on and each holder, and flags a record whose pid
is gone or whose start time changed, so a reused pid is never taken for the
holder. A waiter prints
its first notice after 2 seconds and another every 60, waits at most
FM_TEST_SLOT_WAIT_SECONDS (default 7200, the longest fm-teardown run measured in
the last 24 hours was 6884), and then runs without a slot and says so: the gate
shapes throughput and is not a safety boundary, so it never blocks a test for
good and never stops one when the slot directory or a slot file is unusable or
this Python has no POSIX file locks: it runs without a slot and says so. A command run
under a slot exports FM_TEST_SLOT_HELD (the keys it holds, tab separated), so the
same key nested inside it takes no second slot. A malformed FM_TEST_KEY_SLOTS or
FM_TEST_SLOT_WAIT_SECONDS refuses the command by name (exit 125 from gate).
slots prints one key's directory, its limit and each holder; it changes nothing.
docs/configuration.md "Test slots per key" owns the sizing rationale.

A timeout is a real limit that stopped a command, reported by the owner of that
limit (run's ceiling, fm_run_timed, the lint root bound, the per-script bound,
or record --timed-out); an exit code of 124 or 137 alone never counts. The second timeout for a
host/key files a deterministic ship item through the owning home's
fm-tasks-axi.sh (FM_HOME set to FM_DURATION_HOME when present) with the observed
lower bounds, for the project registered in that home's data/projects.md under the
repository's name, else for firstmate; later events update the ledger without duplicating an open item.
When that item is done or gone and a timeout recurs, a new item naming the old
one is filed. A self-imposed read wait that ended while its command continued is
not a timeout and is never recorded as one. Filing failure
remains retryable and is reported, never silently marked filed. Manual-backlog
homes use compatible tasks-axi for this automated addition as well.

check-literals compares bin/ against the merge-base with origin/main (main if
no remote ref exists). Existing literals are grandfathered by path and exact
statement, not line number; existing limits that were only moved are listed in
bin/fm-duration-existing-limits.tsv (path, value, exact statement). Added or
changed bounds need an adjacent measured: note with value, ISO date, host and
margin. --report lists all current literals without enforcing or changing them.
It recognizes shell bound calls including fm_duration_limit/fm_duration_timed
fallbacks, timeout flags with optional unit suffixes, timeout/deadline/budget
assignments and Python/JS timeout keyword values.
"""
import argparse
import collections
import contextlib
import datetime
import functools
try:
    import fcntl
except ImportError:
    fcntl = None  # Native Windows Python cannot use the POSIX timing runner.
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import shlex
import selectors
import sqlite3
import stat
import struct
import subprocess
import sys
import time
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
HOST = platform.node()
MIN_SAMPLES = 5  # sample-count policy: eligible samples before a measured limit applies
KEEP_SAMPLES = 100  # sample-count policy: newest samples kept per host and key
COMPACT_AT = 200  # sample-count policy: host/key sample rows that trigger compaction
EVENTS = ('timeout', 'filed')
LOCAL_NOTED = []
REFUSED = []


def scalar(key, value, stream=sys.stdout):
    print(f'{key}: {json.dumps(value, ensure_ascii=False)}', file=stream)


def absolute(name, value):
    if not os.path.isabs(value):
        raise ValueError(f'{name}={value!r} is not an absolute path')
    return Path(os.path.realpath(value))


def data_dir():
    """The owning home's data directory; an empty variable is unset."""
    for name in ('FM_DURATION_HOME', 'FM_DATA_OVERRIDE'):
        value = os.environ.get(name)
        if value:
            path = absolute(name, value)
            return path / 'data' if name == 'FM_DURATION_HOME' else path
    value = os.environ.get('FM_HOME')
    return (absolute('FM_HOME', value) if value else ROOT) / 'data'


def work_tree_root(directory):
    """The nearest enclosing git work tree top level, or None outside any."""
    return next((parent for parent in (directory, *directory.parents) if (parent / '.git').exists()), None)


def contained(path, directory):
    try:
        path.relative_to(directory)
    except ValueError:
        return False
    return True


def may_write(path, home):
    """A table may sit outside every work tree, or under the home's data
    directory when the work tree holding it is a firstmate checkout; any other
    work tree is a project copy."""
    root = work_tree_root(path.parent)
    return root is None or (contained(path, home) and (root / 'bin' / 'fm-duration.py').exists())


def refuse(reason):
    if not REFUSED:
        REFUSED.append(reason)
        scalar('ledger', f'refused, nothing recorded: {reason}', sys.stderr)
    return None


def ledger_path():
    value = os.environ.get('FM_DURATION_FILE')
    if value == 'off':
        return None
    try:
        home = data_dir()
        if value:
            # Resolve the directory only: the table itself is opened with O_NOFOLLOW.
            path = absolute('FM_DURATION_FILE', str(Path(value).parent)) / Path(value).name
        else:
            path = home / 'command-durations.jsonl'
    except ValueError as error:
        return refuse(str(error))
    if not may_write(path, home):
        return refuse(f'{path} is inside a git work tree that is not a firstmate checkout data directory')
    return path


def checkout_local():
    return not any(os.environ.get(name) for name in ('FM_DURATION_FILE', 'FM_DURATION_HOME', 'FM_HOME', 'FM_DATA_OVERRIDE'))


def note_local(path):
    if checkout_local() and not LOCAL_NOTED:
        LOCAL_NOTED.append(path)
        scalar('ledger', f'{path} is checkout-local and not durable: FM_DURATION_HOME is unset', sys.stderr)


def load_now():
    try:
        return os.getloadavg()[0]
    except (AttributeError, OSError):
        return None


@functools.lru_cache(maxsize=None)
def repo():
    def query(*args):
        try:
            done = subprocess.run(['git', *args], capture_output=True, text=True)
        except OSError:
            return ''
        return done.stdout.strip() if done.returncode == 0 else ''
    parts = [part for part in re.split(r'[/:]', query('remote', 'get-url', 'origin')) if part]
    if len(parts) >= 2:
        return re.sub(r'\.git$', '', '/'.join(parts[-2:]))
    return Path(query('rev-parse', '--show-toplevel') or os.getcwd()).name


def mine(row, key=None):
    return row.get('host') == HOST and row.get('repo') == repo() and (key is None or row.get('key') == key)


def sample_rows(rows):
    return [r for r in rows if r.get('event') not in EVENTS]


def compact(path, rows):
    counts = collections.Counter((r.get('host'), r.get('repo'), r.get('key')) for r in sample_rows(rows))
    if not counts or max(counts.values()) <= COMPACT_AT:
        return
    kept, seen = [], collections.Counter()
    for row in reversed(rows):
        identity = row.get('host'), row.get('repo'), row.get('key')
        if row.get('event') not in EVENTS:
            seen[identity] += 1
            if seen[identity] > KEEP_SAMPLES:
                continue
        kept.append(row)
    scratch = path.with_name(path.name + '.compact')
    fd = os.open(scratch, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as output:
        output.writelines(json.dumps(row, separators=(',', ':')) + '\n' for row in reversed(kept))
        output.flush()
        os.fsync(output.fileno())
    os.replace(scratch, path)


@contextlib.contextmanager
def ledger(write=True):
    path = ledger_path()
    if path is None or (not write and not path.exists()):
        yield None, []
        return
    if fcntl is None:
        raise RuntimeError('duration recording requires POSIX Python file locks; use Python from the Firstmate POSIX shell')
    if write:
        path.parent.mkdir(parents=True, exist_ok=True)
    lock = os.open(str(path) + '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX if write else fcntl.LOCK_SH)
        flags = os.O_RDWR | os.O_CREAT | os.O_APPEND if write else os.O_RDONLY
        fd = os.open(path, flags | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'r+' if write else 'r', encoding='utf-8') as handle:
            rows = [json.loads(line) for line in handle if line.strip()]
            existing = len(rows)
            yield (handle if write else None), rows
        if write and len(rows) > existing:
            note_local(path)
            compact(path, rows)
    finally:
        os.close(lock)


def append(handle, rows, row):
    if handle is not None:
        handle.write(json.dumps(row, separators=(',', ':')) + '\n')
        handle.flush()
        os.fsync(handle.fileno())
        rows.append(row)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def observation(key, milliseconds, code, sample_id=None, calibration=True, load_start=None, load_end=None, timed_out=False):
    return dict(host=HOST, repo=repo(), key=key, duration_ms=milliseconds, exit=code, recorded_at=now_iso(),
                load_start=load_start, load_end=load_end,
                cpus=os.cpu_count() or 1, sample_id=sample_id, calibration=calibration, timed_out=timed_out)


def record_many(entries):
    entries = [e for e in entries if os.environ.get('FM_DURATION_MANAGED_KEY') != e['key']]
    with ledger() as (handle, rows):
        for entry in entries:
            sample_id = entry.get('sample_id')
            if not sample_id or not any(r.get('host') == HOST and r.get('sample_id') == sample_id for r in rows):
                append(handle, rows, observation(**entry))
    for entry in entries:
        if entry.get('timed_out'):
            own_timeout(entry['key'], entry['milliseconds'], entry.get('sample_id'))


def record(key, milliseconds, code, sample_id=None, calibration=True, load_start=None, timed_out=False):
    record_many([dict(key=key, milliseconds=milliseconds, code=code, sample_id=sample_id,
                      calibration=calibration, load_start=load_start, load_end=load_now(), timed_out=timed_out)])


def optional_load(value):
    return float(value) if value else None


def record_batch(lines):
    entries = []
    for line in lines:
        if not line.strip():
            continue
        key, milliseconds, code, calibration, load_start, load_end, timed_out = line.rstrip('\n').split('\t')
        if int(milliseconds) < 0 or int(code) < 0:
            raise ValueError(f'negative duration or exit for {key}')
        entries.append(dict(key=key, milliseconds=int(milliseconds), code=int(code),
                            calibration=calibration == '1', load_start=optional_load(load_start),
                            load_end=optional_load(load_end), timed_out=timed_out == '1'))
    record_many(entries)


def limit(key, percentile, margin, fallback, verbose=True):
    if fcntl is None:
        scalar('calibration', 'POSIX Python file locks unavailable', sys.stderr)
        scalar('fallback', f'{fallback}s existing caller limit' if fallback else 'no destructive deadline; use the Firstmate POSIX shell to collect samples', sys.stderr)
        return fallback
    with ledger(write=False) as (_, rows):
        samples = sorted(r['duration_ms'] for r in sample_rows(rows) if mine(r, key)
                         and r.get('exit') == 0 and r.get('calibration', True))
    if len(samples) < MIN_SAMPLES:
        if verbose:
            scalar('calibration', f'{len(samples)} of {MIN_SAMPLES} samples for {key} on {HOST}', sys.stderr)
            scalar('fallback', f'{fallback}s existing caller limit' if fallback else 'no destructive deadline; collect samples', sys.stderr)
        return fallback
    rank = samples[math.ceil(len(samples) * percentile / 100) - 1]
    measured = max(1, math.ceil(rank * margin / 1000))
    seconds = max(fallback, measured)
    if verbose:
        scalar('measured', f'{key} host={HOST} p{percentile}={rank}ms margin={margin} samples={len(samples)} measured={measured}s bound={fallback}s', sys.stderr)
    return seconds


def backlog():
    owner = os.environ.get('FM_DURATION_HOME')
    if not owner:
        return [str(ROOT / 'bin/fm-tasks-axi.sh')], None
    env = {name: value for name, value in os.environ.items() if name != 'FM_DATA_OVERRIDE'}
    env['FM_HOME'] = owner
    return [str(Path(owner) / 'bin/fm-tasks-axi.sh')], env


def filing_project():
    try:
        lines = (data_dir() / 'projects.md').read_text().splitlines()
    except (OSError, ValueError):
        return 'firstmate'
    registered = {re.split(r' \[| - ', line[2:], maxsplit=1)[0].strip() for line in lines if line.startswith('- ')}
    name = repo().rsplit('/', 1)[-1]
    return name if name in registered else 'firstmate'


def task_closed(cmd, env, task):
    shown = subprocess.run(cmd + ['show', task], capture_output=True, text=True, env=env)
    if shown.returncode == 0:
        return any(line.strip() == 'state: done' for line in shown.stdout.splitlines())
    if 'NOT_FOUND' in shown.stdout + shown.stderr:
        return True
    raise RuntimeError(f'timeout work {task} could not be inspected: ' + shown.stderr.strip() + shown.stdout.strip())


def note_timeout(key, milliseconds, event_id):
    with ledger() as (handle, rows):
        if handle is None:
            return None
        if not event_id or not any(mine(r, key) and r.get('event') == 'timeout'
                                   and r.get('event_id') == event_id for r in rows):
            append(handle, rows, dict(host=HOST, repo=repo(), key=key, event='timeout', duration_ms=milliseconds,
                                      event_id=event_id, recorded_at=now_iso()))
        return [r for r in rows if mine(r, key) and r.get('event') in EVENTS]


def own_timeout(key, milliseconds, event_id=None):
    history = note_timeout(key, milliseconds, event_id)
    if history is None:
        return
    timeouts = [i for i, r in enumerate(history) if r['event'] == 'timeout']
    filed = [i for i, r in enumerate(history) if r['event'] == 'filed']
    if len(timeouts) < 2 or (filed and timeouts[-1] < filed[-1]):
        return
    cmd, env = backlog()
    base = 'fm-timeout-' + hashlib.sha256((HOST + '\0' + repo() + '\0' + key).encode()).hexdigest()[:16]
    previous = history[filed[-1]]['task'] if filed else None
    if previous and not task_closed(cmd, env, previous):
        return
    task = base if not filed else f'{base}-{len(filed) + 1}'
    body = f'Repeated timeout for command key {key} in repository {repo()} on host {HOST}. Observed lower bounds (ms): ' + ', '.join(str(history[i]['duration_ms']) for i in timeouts)
    if previous:
        body += f'. The timeout recurred after {previous} was closed'
    body += '. Measure completion latency across host load, then repair the limit with an explicit margin. A read wait ending is not command failure.'
    # Inspect before retrying an interrupted publication, using the deterministic id.
    if subprocess.run(cmd + ['show', task], capture_output=True, text=True, env=env).returncode:
        result = subprocess.run(cmd + ['add', task, f'Measure and repair repeated timeout: {repo()} {key}', '--kind', 'ship', '--repo', filing_project(), '--body', body], capture_output=True, text=True, env=env)
        if result.returncode and subprocess.run(cmd + ['show', task], capture_output=True, text=True, env=env).returncode:
            raise RuntimeError('timeout work could not be filed: ' + result.stderr.strip() + result.stdout.strip())
    with ledger() as (handle, rows):
        if not any(mine(r, key) and r.get('event') == 'filed' and r.get('task') == task for r in rows):
            append(handle, rows, dict(host=HOST, repo=repo(), key=key, event='filed', task=task, previous=previous, recorded_at=now_iso()))
    scalar('timeout_work', task, sys.stderr)


def import_nm(database, run_id):
    with contextlib.closing(sqlite3.connect(Path(database).absolute().as_uri() + '?mode=ro', uri=True)) as db:
        steps = db.execute('SELECT id, step_name, duration_ms, exit_code FROM step_results WHERE run_id = ? AND completed_at IS NOT NULL AND duration_ms > 0 AND exit_code IS NOT NULL', (run_id,)).fetchall()
    with ledger() as (handle, rows):
        known = {r.get('sample_id') for r in rows}
        for identity, name, duration, code in steps:
            sample_id = 'nm:' + str(Path(database).absolute()) + ':' + str(identity)
            if sample_id not in known:
                # Imported timings have no historical load evidence.
                append(handle, rows, dict(host=HOST, repo=repo(), key='no-mistakes-step.' + name, duration_ms=duration,
                                          exit=code, sample_id=sample_id, load_start=None, load_end=None,
                                          cpus=None, recorded_at=now_iso()))


def tree_cpu(pid, observed):
    try:
        result = subprocess.run(['ps', '-axo', 'pid=,ppid=,time=,lstart='], capture_output=True, text=True,
                                env=dict(os.environ, LC_ALL='C'))
        if result.returncode:
            return None
        children = collections.defaultdict(list)
        times = {}
        for line in result.stdout.splitlines():
            fields = line.split()
            if len(fields) < 4:
                continue
            child, parent = map(int, fields[:2])
            days, separator, clock = fields[2].rpartition('-')
            seconds = float(days) * 86400 if separator else 0.0
            parts = (clock if separator else fields[2]).split(':')
            clock_seconds = 0.0
            for part in parts:
                clock_seconds = clock_seconds * 60 + float(part)
            seconds += clock_seconds
            children[parent].append(child)
            times[child] = (seconds, tuple(fields[3:]))
    except (OSError, ValueError):
        return None  # A failed telemetry sample is no progress sample, never a stop reason.
    todo = [pid]
    while todo:
        child = todo.pop()
        if child in times:
            seconds, identity = times[child]
            observed[(child, identity)] = max(observed.get((child, identity), 0), seconds)
        todo.extend(children[child])
    return sum(observed.values())


def signal_group(child, sig):
    child.poll()  # Reap a completed leader before signalling its remaining group.
    try:
        os.killpg(child.pid, sig)
    except ProcessLookupError:
        pass  # The owned group has already gone.
    except PermissionError:
        # A repeated cleanup signal returned EPERM after cancellation on
        # Darwin. Accept completion only after the leader is reaped AND the
        # kernel inventory proves that no live group member remains.
        if child.poll() is None:
            raise
        inventory = subprocess.run(['ps', '-axo', 'pgid=,stat='], capture_output=True, text=True)
        if inventory.returncode:
            raise
        for line in inventory.stdout.splitlines():
            fields = line.split()
            if len(fields) != 2:
                raise ValueError('cannot verify completed process group')
            if fields[0] == str(child.pid) and not fields[1].startswith(('Z', 'X')):
                raise


@contextlib.contextmanager
def calibration_scratch():
    """A task-local calibration file path, never inside a git work tree."""
    for base in dict.fromkeys((tempfile.gettempdir(), '/tmp', '/var/tmp')):
        if os.path.isdir(base) and work_tree_root(Path(os.path.realpath(base))) is None:
            with tempfile.TemporaryDirectory(prefix='fm-duration-', dir=base) as scratch:
                yield Path(scratch) / 'calibration'
            return
    scalar('calibration', 'no scratch directory outside a git work tree; running without a calibration file', sys.stderr)
    yield None


SLOT_PREFIX = 'test.'
SLOT_DEFAULT = 2  # sizing: docs/configuration.md "Test slots per key"
SLOT_MAX = 16
# measured: value=7200 date=2026-10-17 host=Mac-Studio.local margin=1.05 (longest fm-teardown run in the last 24 hours was 6884 s)
SLOT_WAIT_DEFAULT_SECONDS = 7200
SLOT_FIRST_NOTICE = 2.0
SLOT_NOTICE_EVERY = 60.0
SLOT_HELD_ENV = 'FM_TEST_SLOT_HELD'


def slot_limit():
    value = os.environ.get('FM_TEST_KEY_SLOTS', '')
    if not value:
        return SLOT_DEFAULT
    if not (value.isascii() and value.isdecimal()) or int(value) > SLOT_MAX:
        raise ValueError(f'FM_TEST_KEY_SLOTS={value!r} must be a whole number from 0 (off) to {SLOT_MAX}')
    return int(value)


def slot_wait():
    value = os.environ.get('FM_TEST_SLOT_WAIT_SECONDS', '')
    if not value:
        return SLOT_WAIT_DEFAULT_SECONDS
    if not (value.isascii() and value.isdecimal()) or int(value) < 1:
        raise ValueError(f'FM_TEST_SLOT_WAIT_SECONDS={value!r} must be a whole number of seconds of at least 1')
    return int(value)


def slot_directory(key):
    """The per-key slot directory; created private and checked owned by the caller."""
    explicit = os.environ.get('FM_TEST_SLOT_DIR')
    if explicit:
        root = absolute('FM_TEST_SLOT_DIR', explicit)
    elif os.environ.get('HOME'):
        root = Path(os.environ['HOME']) / '.cache' / 'fm-test-slots'
    else:
        raise OSError('HOME and FM_TEST_SLOT_DIR are both unset')
    name = re.sub(r'[^A-Za-z0-9._-]', '_', key)[:80] + '-' + hashlib.sha1(key.encode()).hexdigest()[:10]
    directory = root / name
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode):
        raise OSError(f'{directory} is not a directory')
    if hasattr(os, 'getuid') and info.st_uid != os.getuid():
        raise OSError(f'{directory} is owned by another user')
    return directory


def process_start(pid):
    """A process's start time as ps prints it, or '' when no such process exists."""
    result = subprocess.run(['ps', '-o', 'lstart=', '-p', str(pid)], capture_output=True, text=True,
                            env=dict(os.environ, LC_ALL='C'))
    return ' '.join(result.stdout.split()) if result.returncode == 0 else ''


def slot_holders(directory, limit):
    """(index, record text) for each slot whose lock is held, probed without keeping any."""
    held = []
    for index in range(limit):
        path = directory / f'slot-{index}.lock'
        try:
            fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        except OSError:
            continue
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                try:
                    record = json.loads(path.read_text() or '{}')
                except (OSError, ValueError):
                    record = {}
                held.append((index, describe_holder(record)))
        finally:
            os.close(fd)
    return held


def describe_holder(record):
    pid = record.get('pid')
    if not isinstance(pid, int) or not record.get('start'):
        return 'holder unknown'
    stale = process_start(pid) != record['start']
    age = max(0, int(time.time() - record.get('since', time.time())))
    state = 'record does not match a live process (pid gone or reused)' if stale else 'alive'
    return f'pid={pid} {state} held {age}s cwd={record.get("cwd", "?")}'


def slot_log(log_fd, message):
    try:
        os.write(log_fd, ('fm-duration: ' + message + '\n').encode('utf-8', 'replace'))
    except OSError:
        pass


def acquire_slot(key, log_fd=2):
    """An open fd holding one of the key's slots, or None when this key takes none."""
    if not key.startswith(SLOT_PREFIX):
        return None
    limit = slot_limit()
    wait = slot_wait()
    if limit == 0 or key in os.environ.get(SLOT_HELD_ENV, '').split('\t'):
        return None
    if fcntl is None or os.name != 'posix':
        slot_log(log_fd, f'running {key} without a slot: this Python has no POSIX file locks')
        return None
    try:
        return queue_for_slot(key, slot_directory(key), limit, wait, log_fd)
    except (OSError, ValueError) as error:
        slot_log(log_fd, f'running {key} without a slot: {error}')
        return None


def queue_for_slot(key, directory, limit, wait, log_fd):
    started = time.monotonic()
    next_notice = started + SLOT_FIRST_NOTICE
    delay = 0.05
    while True:
        for index in range(limit):
            path = directory / f'slot-{index}.lock'
            fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                os.close(fd)
                continue
            try:
                record = dict(pid=os.getpid(), start=process_start(os.getpid()), since=int(time.time()), key=key, cwd=os.getcwd())
                os.ftruncate(fd, 0)
                os.pwrite(fd, json.dumps(record).encode(), 0)
            except OSError:
                pass  # The record is for display only; the lock is the slot.
            held = [item for item in os.environ.get(SLOT_HELD_ENV, '').split('\t') if item]
            os.environ[SLOT_HELD_ENV] = '\t'.join(held + [key])
            waited = int(time.monotonic() - started)
            if waited >= SLOT_FIRST_NOTICE:
                slot_log(log_fd, f'got a slot of {key} after {waited}s')
            return fd
        now = time.monotonic()
        expired = now - started >= wait
        if now >= next_notice or (expired and next_notice == started + SLOT_FIRST_NOTICE):
            holders = '; '.join(text for _, text in slot_holders(directory, limit)) or 'holders unknown'
            slot_log(log_fd, f'waiting {int(now - started)}s for a free slot of {key} (limit {limit}, FM_TEST_KEY_SLOTS; gives up after {wait}s); holders: {holders}')
            next_notice = now + SLOT_NOTICE_EVERY
        if expired:
            slot_log(log_fd, f'waited {int(now - started)}s for a free slot of {key} (limit {limit}); running it without a slot')
            return None
        time.sleep(min(delay, max(0.0, wait - (now - started))))
        delay = min(2.0, delay * 2)


def release_slot(fd):
    if fd is not None:
        os.close(fd)


def gate(key, command, log_fd, wait_file=None):
    """Run COMMAND while holding one of KEY's slots; exit with its status."""
    kept = ()
    if log_fd > 2:
        try:
            os.fstat(log_fd)
            kept = (log_fd,)
        except OSError:
            log_fd = 2
    began = time.monotonic()
    try:
        fd = acquire_slot(key, log_fd)
    except ValueError as error:
        slot_log(log_fd, str(error))
        return 125
    except KeyboardInterrupt:
        return 130
    if wait_file:
        try:
            Path(wait_file).write_text(f'{round((time.monotonic() - began) * 1000)}\n')
        except OSError as error:
            slot_log(log_fd, f'cannot report the slot wait to {wait_file}: {error}')
    posix = os.name == 'posix'
    guarded = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP) if posix else ()
    ignored = {}
    def restore_defaults():
        for sig in guarded:
            signal.signal(sig, signal.SIG_DFL)
    try:
        # A group signal reaches COMMAND directly; this process keeps the slot until it exits.
        for sig in guarded:
            ignored[sig] = signal.signal(sig, signal.SIG_IGN)
        options = dict(pass_fds=kept, preexec_fn=restore_defaults) if posix else {}
        try:
            child = subprocess.Popen(command, close_fds=True, **options)
        except FileNotFoundError:
            slot_log(log_fd, f'command not found: {command[0]}')
            return 127
        except PermissionError:
            slot_log(log_fd, f'command not executable: {command[0]}')
            return 126
        code = child.wait()
        return 128 - code if code < 0 else code
    finally:
        for sig, handler in ignored.items():
            signal.signal(sig, handler)
        release_slot(fd)


def show_slots(key):
    limit = slot_limit()
    scalar('key', key)
    scalar('limit', limit)
    if not key.startswith(SLOT_PREFIX) or limit == 0:
        scalar('gate', 'off for this key')
        return
    directory = slot_directory(key)
    scalar('directory', str(directory))
    held = slot_holders(directory, limit)
    print(f'held[{len(held)}]{{slot,holder}}:')
    for index, text in held:
        print(f'  {index},{json.dumps(text)}')


def run(key, command, calibration_file):
    if os.name != 'posix':
        raise RuntimeError('progress runner requires the Firstmate POSIX shell and POSIX Python process groups')
    import termios
    try:
        ceiling = limit(key, 99, 3, 0)
    except (OSError, ValueError) as error:
        scalar('calibration_error', f'{error}; running {key} with no deadline', sys.stderr)
        ceiling = 0
    started = time.monotonic()
    load_start = load_now()
    child_env = dict(os.environ, FM_DURATION_MANAGED_KEY=key)
    if calibration_file is not None:
        child_env['FM_DURATION_CALIBRATION_FILE'] = str(calibration_file)
    child = subprocess.Popen(command, env=child_env, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    streams = selectors.DefaultSelector()
    streams.register(child.stdout, selectors.EVENT_READ, sys.stdout.buffer)
    streams.register(child.stderr, selectors.EVENT_READ, sys.stderr.buffer)
    output_bytes = 0
    interrupted = []
    stopping_since = []
    def begin_stop():
        if not stopping_since:
            stopping_since.append(time.monotonic())
            signal_group(child, signal.SIGTERM)
    def forward(sig, _frame):
        interrupted.append(sig)
        if len(interrupted) > 1:
            signal_group(child, signal.SIGKILL)
        else:
            begin_stop()
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, forward)
    def relay(stream, sink, size):
        nonlocal output_bytes
        chunk = os.read(stream.fileno(), size)
        if chunk:
            sink.write(chunk)
            sink.flush()
            output_bytes += len(chunk)
        return len(chunk)
    previous_cpu, previous_bytes = -1, -1
    next_cpu_sample = started
    observed_cpu = {}
    occurrence_id = str(uuid.uuid4())
    expired = False
    try:
        while child.poll() is None:
            if not streams.get_map():
                with contextlib.suppress(subprocess.TimeoutExpired):
                    child.wait(1)  # observation cadence, not a deadline
            for ready, _ in streams.select(1) if streams.get_map() else ():
                if not relay(ready.fileobj, ready.data, 65536):
                    streams.unregister(ready.fileobj)
            elapsed = time.monotonic() - started
            cpu = max(0, previous_cpu)
            if child.poll() is None and time.monotonic() >= next_cpu_sample:
                sample = tree_cpu(child.pid, observed_cpu)
                cpu = cpu if sample is None else sample
                next_cpu_sample = time.monotonic() + 1  # observation cadence, not a deadline
            if cpu > previous_cpu or output_bytes > previous_bytes:
                scalar('progress', f'{key} elapsed={elapsed:.1f}s output_bytes={output_bytes} tree_cpu={cpu:.2f}s', sys.stderr)
                previous_cpu, previous_bytes = max(previous_cpu, cpu), output_bytes
            if ceiling and elapsed >= ceiling and not stopping_since and child.poll() is None:
                expired = True
                begin_stop()
            elif stopping_since and ceiling and time.monotonic() - stopping_since[0] >= ceiling:
                signal_group(child, signal.SIGKILL)  # a second full measured ceiling with the leader alive
        if stopping_since:
            signal_group(child, signal.SIGKILL)  # the leader is gone; sweep any remaining group members
        # The leader's exit is the result. Relay the output buffered by then,
        # but do not wait for descendants that outlive the leader and still
        # hold its streams; they are not live work under the ceiling.
        for stream, sink in ((child.stdout, sys.stdout.buffer), (child.stderr, sys.stderr.buffer)):
            remaining = struct.unpack('i', fcntl.ioctl(stream.fileno(), termios.FIONREAD, bytes(4)))[0]
            while remaining > 0:
                copied = relay(stream, sink, min(remaining, 65536))
                if not copied:
                    break
                remaining -= copied
        code = 124 if expired else child.returncode
        if code < 0:
            code = 128 - code
        if interrupted:
            code = 128 + interrupted[-1]
        duration_ms = round((time.monotonic() - started) * 1000)
        calibration = calibration_file is None or not calibration_file.exists() or calibration_file.read_text().strip() == '1'
        timed_out = expired and not interrupted
        try:
            record(key, duration_ms, code, occurrence_id, calibration, load_start, timed_out)
        except (OSError, ValueError, RuntimeError) as error:
            scalar('recording_error', str(error), sys.stderr)
            # Absolute paths: the replay must derive this command's repo() from any directory.
            scalar('help', f'cd {shlex.quote(os.getcwd())} && python3 {shlex.quote(str(Path(__file__).resolve()))} record {shlex.quote(key)} {duration_ms} {code} --sample-id {occurrence_id}{"" if calibration else " --uncalibrated"}{"" if load_start is None else f" --load-start {load_start}"}{" --timed-out" if timed_out else ""}; command result preserved', sys.stderr)
        return code
    finally:
        streams.close()
        child.stdout.close()
        child.stderr.close()
        if child.poll() is None:
            signal_group(child, signal.SIGKILL)
            child.wait()


BOUND = re.compile(r'''(?ix)
    (?:\bfm_(?:run|exec)_timed\s+|\b(?:fm_nm_(?:bounded|run_bounded|run_checked|run)|fm_duration_(?:limit|timed))\s+(?:"(?!\$@)[^"]*"|'[^']*'|[^\s"']+)\s+)["']?(?P<call>\d+(?:\.\d+)?)(?:["']|\b)(?![>\d])
    |\b(?:g?timeout)\s+(?:-\w+\s+\d+\s+)?(?P<external>\d+(?:\.\d+)?)(?:ms|[smhd])?\b
    |--(?:[\w-]*timeout[\w-]*|max-time|connect-timeout|wait|deadline)(?:[=\s]+)(?P<flag>\d+(?:\.\d+)?)(?:ms|[smhd])?\b
    |\b[\w]*(?:TIMEOUT|DEADLINE|SECONDS|_SECS|_MS|_GRACE)[\w]*\s*=\s*["']?(?:\$\{[^}\n]*:-)?["']?(?P<assignment>\d+(?:\.\d+)?)\b
    |\b(?:timeout|deadline)["']?\s*[:=]\s*(?P<keyword>\d+(?:\.\d+)?)\b
    |\bread\s+(?:-[A-Za-z]+\s+)*-t\s+["']?(?P<read>\d+(?:\.\d+)?)\b
    |\balarm\s*\(?\s*(?P<alarm>\d+(?:\.\d+)?)\b
    |\b(?:AbortSignal\.timeout|setTimeout|setInterval)\s*\([^\n]*?\b(?P<timer>\d+(?:\.\d+)?)\s*\)
''')
NOTE = re.compile(r'measured:.*value=([^\s,]+).*date=\d{4}-\d{2}-\d{2}.*host=\S+.*margin=\S+')


def literals(text):
    lines = text.splitlines()
    consumed_through = -1
    for index, line in enumerate(lines):
        if index <= consumed_through or line.lstrip().startswith(('#', '//', '*')):
            continue
        end = index
        while line.rstrip().endswith('\\') and end + 1 < len(lines):
            end += 1
            line = line.rstrip()[:-1] + ' ' + lines[end].lstrip()
        consumed_through = end
        for match in BOUND.finditer(line):
            value = next(v for v in match.groupdict().values() if v is not None)
            if float(value) == 0:
                continue  # zero disables a deadline, not a time limit
            note = NOTE.search('\n'.join(lines[max(0, index - 1):end + 2]))
            annotated = False
            if note and re.sub(r'(?:ms|[smhd])$', '', note.group(1)) == value:
                fields = dict(re.findall(r'(date|margin)=([^\s,]+)', note.group(0)))
                try:
                    datetime.date.fromisoformat(fields['date'])
                    margin = float(fields['margin'].rstrip('x'))
                    annotated = math.isfinite(margin) and margin >= 1
                except (ValueError, KeyError):
                    pass
            yield index + 1, line.strip(), value, annotated


def git(*args):
    return subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True, check=True).stdout


def sources(base):
    process = None
    if base:
        process = subprocess.Popen(['git', '-C', str(ROOT), 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for path in sorted((ROOT / 'bin').rglob('*')):
            if not path.is_file() or path.suffix not in ('.sh', '.py', '.js', '.ts', '.pl'):
                continue
            relative = str(path.relative_to(ROOT))
            previous = ''
            if process:
                process.stdin.write((base + ':' + relative + '\n').encode())
                process.stdin.flush()
                header = process.stdout.readline().decode().split()
                if len(header) == 3 and header[1] == 'blob':
                    previous = process.stdout.read(int(header[2])).decode()
                    process.stdout.read(1)  # batch frame terminator
                elif not header or header[-1] != 'missing':
                    raise ValueError('cannot read literal baseline for ' + relative)
            yield relative, path.read_text(), previous
    finally:
        if process:
            process.stdin.close()
            process.stdout.close()
            process.wait()


def moved_limits():
    moved = collections.Counter()
    listing = ROOT / 'bin/fm-duration-existing-limits.tsv'
    if listing.exists():
        for line in listing.read_text().splitlines():
            if line.strip() and not line.startswith('#'):
                relative, value, statement = line.split('\t', 2)
                moved[relative, statement, value] += 1
    return moved


def check_literals(base, report):
    if report:
        for relative, current, _ in sources(None):
            for line, statement, value, _ in literals(current):
                print(f'{relative}:{line}\t{value}\t{statement}')
        return 0
    if not base:
        for ref in ('origin/main', 'main'):
            try:
                base = git('merge-base', 'HEAD', ref).strip()
                break
            except subprocess.CalledProcessError:
                continue
    if not base:
        raise ValueError('no comparison base; pass --base REF')
    base = git('rev-parse', '--verify', base + '^{commit}').strip()
    moved = moved_limits()
    failures = []
    for relative, current, original in sources(base):
        previous = collections.Counter((statement, value) for _, statement, value, _ in literals(original))
        previous.update({(statement, value): count for (path, statement, value), count in moved.items() if path == relative})
        for line, statement, value, annotated in literals(current):
            identity = statement, value
            if previous[identity]:
                previous[identity] -= 1
            elif not annotated:
                failures.append(f'{relative}:{line}: new time limit {value}; add adjacent measured: value={value} date=YYYY-MM-DD host=<host> margin=<factor> with empirical evidence, or use fm-duration.py limit')
    for failure in failures:
        scalar('error', failure)
    return int(bool(failures))


def nonnegative(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError('must be nonnegative')
    return number


class Parser(argparse.ArgumentParser):
    def error(self, message):
        scalar('error', message)
        scalar('help', 'python3 bin/fm-duration.py --help')
        self.exit(2)


def main():
    if len(sys.argv) == 2 and sys.argv[1] in ('-v', '-V', '--version'):
        print('1.0.0')
        return 0
    if len(sys.argv) == 1:
        scalar('bin', str(Path(__file__).resolve()))
        scalar('description', 'Measure host command latency and own repeated timeouts')
        with ledger(write=False) as (_, rows):
            counts = collections.Counter(r['key'] for r in sample_rows(rows) if mine(r))
        print(f'durations[{len(counts)}]{{key,samples}}:')
        for key, count in sorted(counts.items()):
            print(f'  {json.dumps(key)},{count}')
        if not counts:
            scalar('durations', '0 recorded command samples on this host')
        scalar('help', 'python3 bin/fm-duration.py run <key> -- <command>; python3 bin/fm-duration.py limit <key>')
        return 0
    parser = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='action', required=True)
    rec = commands.add_parser('record')
    rec.add_argument('key'); rec.add_argument('milliseconds', type=nonnegative); rec.add_argument('exit', type=nonnegative)
    rec.add_argument('--sample-id')
    rec.add_argument('--uncalibrated', action='store_true')
    rec.add_argument('--load-start', type=float)
    rec.add_argument('--timed-out', action='store_true')
    commands.add_parser('record-batch')
    lim = commands.add_parser('limit')
    lim.add_argument('key'); lim.add_argument('--percentile', type=int, choices=(95, 99), default=95)
    lim.add_argument('--margin', type=float, default=3); lim.add_argument('--fallback', type=nonnegative, default=0)
    runner = commands.add_parser('run')
    runner.add_argument('key'); runner.add_argument('command', nargs=argparse.REMAINDER)
    gater = commands.add_parser('gate')
    gater.add_argument('key'); gater.add_argument('--log-fd', type=nonnegative, default=2); gater.add_argument('--wait-file'); gater.add_argument('command', nargs=argparse.REMAINDER)
    slots = commands.add_parser('slots')
    slots.add_argument('key')
    nm = commands.add_parser('import-nm')
    nm.add_argument('database'); nm.add_argument('run_id')
    timeout = commands.add_parser('timeout')
    timeout.add_argument('key'); timeout.add_argument('milliseconds', type=nonnegative); timeout.add_argument('--event-id')
    commands.add_parser('path')
    check = commands.add_parser('check-literals').add_mutually_exclusive_group()
    check.add_argument('--base'); check.add_argument('--report', action='store_true')
    args = parser.parse_args()
    if args.action == 'record':
        record(args.key, args.milliseconds, args.exit, args.sample_id, not args.uncalibrated, args.load_start, args.timed_out)
    elif args.action == 'record-batch':
        record_batch(sys.stdin)
    elif args.action == 'limit':
        if not math.isfinite(args.margin) or args.margin < 1:
            parser.error('--margin must be finite and >= 1')
        print(limit(args.key, args.percentile, args.margin, args.fallback))
    elif args.action == 'timeout':
        own_timeout(args.key, args.milliseconds, args.event_id)
    elif args.action == 'path':
        path = ledger_path()
        if path is not None:
            note_local(path)
        print(path or 'off')
    elif args.action == 'import-nm':
        import_nm(args.database, args.run_id)
    elif args.action == 'check-literals':
        return check_literals(args.base, args.report)
    elif args.action == 'run':
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if not command:
            parser.error('run requires -- COMMAND')
        try:
            slot = acquire_slot(args.key)
        except ValueError as error:
            scalar('error', str(error))
            return 125
        except KeyboardInterrupt:
            return 130
        try:
            with calibration_scratch() as calibration_file:
                return run(args.key, command, calibration_file)
        finally:
            release_slot(slot)
    elif args.action == 'gate':
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if not command:
            parser.error('gate requires -- COMMAND')
        return gate(args.key, command, args.log_fd, args.wait_file)
    elif args.action == 'slots':
        show_slots(args.key)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, sqlite3.Error, subprocess.CalledProcessError) as error:
        scalar('error', str(error))
        sys.exit(1)
