#!/usr/bin/env python3
"""Shared executable fixtures for the fm-cpu-pass admission and launch-gate scripts; never fleet state, load or the live host.

Imported by tests/fm-cpu-pass-admission.py and tests/fm-cpu-pass-gate.py, each called as SCRIPT REPO TMP PYTHON.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import socket
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time

repo, parent, python = Path(sys.argv[1]).resolve(), Path(sys.argv[2]), sys.argv[3]
root = Path(tempfile.mkdtemp(prefix='admission-', dir=parent))
shim = root / 'bin'
shim.mkdir()
# Test-only injection at the native observation boundary, never a production
# environment override. The same executable owners run normally underneath it.
proxy = shim / 'python3'
proxy.write_text('#!' + python + '\n' + '''import json, os, runpy, sys
real = sys.executable
def scope_coalition(info, registry, root):
    import time as _time
    real_coalition = info.coalition
    cache = {}
    def in_case(pid):
        if _time.monotonic() - cache.get('at', -1.0) > 0.2:  # one table and registry read per snapshot, not per pid
            try:
                cache['registered'] = {int(word) for word in open(registry).read().split()}
            except (OSError, ValueError):
                cache['registered'] = set()
            cache['table'], cache['at'] = dict(info.processes()), _time.monotonic()
        registered, table = cache['registered'], cache['table']
        cursor, steps = pid, 0
        while cursor not in (0, 1) and steps < 4096:
            if cursor == root or cursor in registered:
                return True
            cursor, steps = table.get(cursor, 1), steps + 1
        return False
    def scoped(pid):
        # A case process keeps its real answer, unknown included; every other process is another coalition's.
        if in_case(pid):
            return real_coalition(pid)
        return (real_coalition(pid) or 0) + 1000000
    info.coalition = scoped
    # A process outside the case that exits between the table read and its confirming read stays another
    # coalition's, as the scope reports every process outside the case (production pays that cost: the
    # census-churn measurement in the task evidence); a case process gets the real confirming read.
    real_table, real_exact, listed = getattr(info, 'kinfo_table', None), getattr(info, 'kinfo_exact', None), {}
    if real_table and real_exact:
        import struct as _struct
        def table():
            records = real_table()
            listed.clear()
            listed.update({_struct.unpack_from('i', r, info.P_PID)[0]: r for r in records})
            return records
        def exact(pid):
            try:
                return real_exact(pid)
            except (info.NoSuchProcess, OSError):
                if pid in listed and not in_case(pid):
                    return listed[pid]
                raise
        info.kinfo_table, info.kinfo_exact = table, exact
if len(sys.argv) > 1 and os.path.basename(sys.argv[1]) in ('fm-cpu-pass.py', 'fm-duration.py'):
    if os.environ.get('CASE_CORES'): os.cpu_count = lambda: int(os.environ['CASE_CORES'])
    if os.environ.get('CASE_LOAD'): os.getloadavg = lambda: tuple(json.load(open(os.environ['CASE_LOAD'])))
    import importlib.util, pathlib, sqlite3
    if os.environ.get('CASE_PROCS'):
        spec = importlib.util.spec_from_file_location('fm_proc_guard', os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), 'fm-proc-guard.py'))
        guard = importlib.util.module_from_spec(spec)
        sys.modules['fm_proc_guard'] = guard
        spec.loader.exec_module(guard)
        class Fake:
            name = 'darwin'
            def reading(self):
                value = json.load(open(os.environ['CASE_PROCS']))
                if value.get('error'): raise guard.ReadError('case count unreadable')
                return value
            def limit(self): return self.reading()['limit'], 'case'
            def count(self): return self.reading()['count']
        guard.open_source = lambda: Fake()
    if os.environ.get('CASE_PLATFORM'):
        sys.platform = os.environ['CASE_PLATFORM']
    if os.environ.get('CASE_GATE_RAISE'):
        import subprocess
        import glob, time
        real_waitpid, real_fork, forked, raised = os.waitpid, os.fork, [], []
        def recording_fork():
            pid = real_fork()
            if pid:
                forked.append(pid)
            return pid
        def broken_waitpid(pid, options):
            # The gate's first wait on its agent (its second fork; the first is the watcher)
            # raises once the agent has started, as an internal gate error would.
            if not raised and len(forked) >= 2 and pid == forked[1]:
                raised.append(pid)
                while not glob.glob(os.path.join(os.environ['CASE_FOLDER'], '*.agent')): time.sleep(0.025)
                raise RuntimeError('injected gate error after the agent started')
            return real_waitpid(pid, options)
        os.fork = recording_fork
        os.waitpid = broken_waitpid
        import subprocess
        real_wait = subprocess.Popen.wait
        def broken_wait(self, timeout=None):
            # A gate that waits through subprocess.Popen (as 5d51fa8be did) meets the same injected error.
            if not raised and any('agent.py' in str(part) for part in self.args):
                raised.append(self.pid)
                while not glob.glob(os.path.join(os.environ['CASE_FOLDER'], '*.agent')): time.sleep(0.025)
                raise RuntimeError('injected gate error after the agent started')
            return real_wait(self, timeout)
        subprocess.Popen.wait = broken_wait
    if os.environ.get('CASE_SLEEP_BARRIER'):
        import time, pathlib
        real_sleep = time.sleep
        def barrier_sleep(seconds):
            # The first queue sleep holds until the test releases it, so a wait can cross the hold bound
            # exactly while the start lock frees (independent review F6 probe seam).
            marker = pathlib.Path(os.environ['CASE_FOLDER']) / 'sleeping'
            if not marker.exists():
                marker.touch()
                while not (marker.parent / 'release-sleep').exists(): real_sleep(0.01)
            else:
                real_sleep(seconds)
        time.sleep = barrier_sleep
    if os.environ.get('CASE_SPILL_BARRIER'):
        import subprocess, time, pathlib
        real_run = subprocess.run
        def barrier_run(args, *rest, **kw):
            # Every gate of a burst reaches its wake append, then all of them run it at once.
            if any('fm_wake_pending_settle' in str(part) for part in args):
                gather = pathlib.Path(os.environ['CASE_SPILL_BARRIER'])
                (gather / ('arrived-%d' % os.getpid())).touch()
                while len(list(gather.glob('arrived-*'))) < int(os.environ['CASE_SPILL_COUNT']): time.sleep(0.005)
            return real_run(args, *rest, **kw)
        subprocess.run = barrier_run
    if os.environ.get('CASE_KILL_BEFORE_PID'):
        import signal
        real_write = os.write
        def write_until_killed(fd, data):
            # The gate dies at its pid handoff to the watcher (independent review F5 probe seam).
            if len(data) == 32 and data.strip().isdigit():
                os.kill(os.getpid(), signal.SIGKILL)
            return real_write(fd, data)
        os.write = write_until_killed
    if os.environ.get('CASE_SIGNAL_AT_SPAWN'):
        # A cancel lands at the start of COMMAND's child: just before its fork ('before:INT') or just after it, before
        # the child is told to go ('after:TERM'). Only the engine's own os.fork is wrapped; subprocess does not use it.
        import signal
        when, name = os.environ['CASE_SIGNAL_AT_SPAWN'].split(':')
        number = getattr(signal, 'SIG' + name)
        real_fork = os.fork
        def signalled_fork():
            if when == 'before':
                os.kill(os.getpid(), number)
            pid = real_fork()
            if pid and when == 'after':
                os.kill(os.getpid(), number)
            return pid
        os.fork = signalled_fork
    if os.environ.get('CASE_COALITION_FILE'):
        # Test-only coalition scope at the observation boundary: the case's own processes (descendants of the test
        # process, or pids the case registered in CASE_COALITION_FILE, which its escaped fixtures do) keep their real
        # coalition; every other process of the host is reported in another coalition, so other sessions sharing this
        # terminal's coalition cannot hold the case's attempts. The real kernel facts are shown by the coalition probes.
        import importlib.util as _u
        _spec = _u.spec_from_file_location('fm_proc_info', os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), 'fm-proc-info.py'))
        _info = _u.module_from_spec(_spec); sys.modules['fm_proc_info'] = _info; _spec.loader.exec_module(_info)
        scope_coalition(_info, os.environ['CASE_COALITION_FILE'], int(os.environ['CASE_COALITION_ROOT']))
    if os.environ.get('CASE_CLOCK_FILE'):
        # The engine's monotonic clock runs ahead by the seconds in this file, so a test drives a real constant
        # (the production hold bound) to its boundary without shortening it.
        import time
        real_monotonic = time.monotonic
        def driven_monotonic():
            try:
                with open(os.environ['CASE_CLOCK_FILE']) as handle:
                    return real_monotonic() + float(handle.read() or 0)
            except (OSError, ValueError):
                return real_monotonic()
        time.monotonic = driven_monotonic
    if os.environ.get('CASE_SWALLOW_INTERRUPT'):
        # A KeyboardInterrupt raised inside a callee is lost there (as one raised in an import's module-lock
        # callback is printed as ignored): the queue's sleep swallows it, so only a recorded signal can stop the wait.
        import time
        real_sleep = time.sleep
        def swallowing_sleep(seconds):
            try:
                real_sleep(seconds)
            except KeyboardInterrupt:
                pass
        time.sleep = swallowing_sleep
    if os.environ.get('CASE_PROCESS_TABLE_UNREADABLE'):
        # The process table cannot be read (both readers the engine uses), so no running client can be seen.
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location('fm_proc_info', os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), 'fm-proc-info.py'))
            info = importlib.util.module_from_spec(spec)
            sys.modules['fm_proc_info'] = info
            spec.loader.exec_module(info)
            def unreadable(*selector): raise OSError('injected: process table unreadable')
            info.kinfo_table = unreadable
        except Exception:
            sys.modules.pop('fm_proc_info', None)
        real_listdir = os.listdir
        def listdir(path='.'):
            if str(path) == '/proc': raise OSError('injected: process table unreadable')
            return real_listdir(path)
        os.listdir = listdir
    connect = sqlite3.connect
    host = pathlib.Path('~/.no-mistakes/state.sqlite').expanduser().resolve().as_uri()
    def isolated(database, *args, **kwargs):
        path, separator, query = str(database).partition('?')
        if path != host:
            raise AssertionError('unexpected database ' + str(database))
        return connect(pathlib.Path(os.environ['CASE_DB']).resolve().as_uri() + separator + query, *args, **kwargs)
    sqlite3.connect = isolated
    sys.executable = __file__
    sys.argv = sys.argv[1:]
    runpy.run_path(sys.argv[0], run_name='__main__')
else:
    os.execv(real, [real] + sys.argv[1:])
''')
proxy.chmod(0o700)
cli = ['bash', str(repo / 'bin/fm-cpu-pass.sh')]
coalition_registry = root / 'coalition.pids'
coalition_registry.write_text('')
base = dict(os.environ, PATH=str(shim) + os.pathsep + os.environ['PATH'], FM_DURATION_FILE='off',
            CASE_COALITION_FILE=str(coalition_registry), CASE_COALITION_ROOT=str(os.getpid()))
base.pop('FM_CPU_PASS_HELD', None)
children = []
records = []


def write_json(path, value):
    temp = path.with_suffix('.new')
    temp.write_text(json.dumps(value))
    temp.replace(path)


class HarmError(AssertionError):
    """The assertion that guards the harm a case names (a red), as against any other failure (an error)."""


def harm(ident, condition, *detail):
    """The assertion that guards the harm a case names; its message starts with "harm:<ident>:", so a run against an
    earlier engine can tell this case's own red from any other failure."""
    if not condition:
        raise HarmError(('harm:%s: %r' % (ident, detail))[:1200])


def held_back(ident, marker, log, seconds=3.0):
    """harm unless MARKER (a start's effect) stays absent for SECONDS: the start is held, not admitted."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline and not marker.exists():
        time.sleep(0.05)
    harm(ident, not marker.exists(), 'the start was admitted', log.read_text() if log.exists() else '')


def group_done(results):
    """End of a named case group: every case passed, or (CASE_KEEP_GOING, a run against an earlier engine recording
    each case's outcome) go on to the next group."""
    if not os.environ.get('CASE_KEEP_GOING'):
        assert all(value == 'pass' for value in results.values()), results


# The launch gate records a ci agent's attempt from kernel process facts only macOS gives (bin/fm-cpu-pass.py
# kernel_snapshot); on any other host it refuses every admitted ci launch with exit 75, as documented. A case that needs
# such an admission runs only on macOS. Elsewhere it is named as skipped and left out of its group's results.
KERNEL_FACTS = sys.platform == 'darwin'


def skipped_without_kernel_facts(name):
    """True, after naming the skip on stdout, when this host has no kernel process facts for NAME's admitted launch."""
    if KERNEL_FACTS:
        return False
    print('SKIP (needs macOS kernel process facts for an admitted ci launch): ' + name, flush=True)
    return True


# A wait for an expected event (a decision line, a marker, an exit) ends when the event happens. This backstop only
# catches a true hang: a decision on a loaded host can take minutes, so no healthy run comes near it. Read at call
# time, so a control may lower it on this module.
HANG_BACKSTOP_SECS = 600


def last_product_line(log=None):
    """The last line a fixture process wrote: LOG's stderr or stdout when given, else the newest recorded output."""
    paths = [Path(str(log) + suffix) for suffix in ('.stderr', '.stdout')] if log is not None else [
        Path(record[key]) for record in records for key in ('stderr', 'stdout') if record.get(key)]
    written = []
    for path in paths:
        try:
            lines = path.read_text(errors='replace').splitlines()
            if lines:
                written.append((path.stat().st_mtime_ns, path, lines[-1]))
        except OSError:
            pass
    if not written:
        return 'none'
    _, path, line = max(written, key=lambda item: item[0])
    return '%s: %s' % (path.name, line)


def hang_backstop_expired(description, began, log=None):
    raise AssertionError('fixture hang backstop (%d s) expired after %.1f s waiting for %s; last product line: %s' % (
        HANG_BACKSTOP_SECS, time.monotonic() - began, description, last_product_line(log)))


def wait_for(predicate, description, log=None, child=None):
    """Wait until PREDICATE holds; when CHILD (the launch whose effect it watches) has exited without it, fail at once."""
    began = time.monotonic()
    while not predicate():
        if child is not None and child.poll() is not None and not predicate():
            raise AssertionError('pid %d exited with %r after %.1f s before %s; last product line: %s' % (
                child.pid, child.returncode, time.monotonic() - began, description, last_product_line(log)))
        if time.monotonic() - began >= HANG_BACKSTOP_SECS:
            hang_backstop_expired(description, began, log)
        time.sleep(0.025)


def wait_exit(child, description, log=None):
    """CHILD's exit status, waiting only on its exit, bounded by the hang backstop."""
    began = time.monotonic()
    try:
        return child.wait(timeout=HANG_BACKSTOP_SECS)
    except subprocess.TimeoutExpired:
        hang_backstop_expired(description, began, log)


def run_to_exit(command, description, **options):
    """subprocess.run(COMMAND, **OPTIONS), waiting only on its exit, bounded by the hang backstop."""
    began = time.monotonic()
    try:
        return subprocess.run(command, timeout=HANG_BACKSTOP_SECS, **options)
    except subprocess.TimeoutExpired:
        hang_backstop_expired(description, began)


GIB = 2 ** 30
# Fixture per-run peaks (GiB) shaped like the measurements record, not its recorded
# values: 13 runs, so the nearest-rank 75th percentile is 3 GiB and the largest peak is 8 GiB.
PEAKS = [0.02, 0.1, 0.69, 0.75, 0.79, 0.8, 0.82, 0.96, 1.0, 3.0, 4.0, 5.8, 8.0]


def facts(folder, available=40 * GIB, pressure=1, runs=(), total=128 * GIB, broken=False):
    """Native memory facts at the fm-mem-guard fixture boundary: runs are (repo, id, rss_bytes)."""
    fixture = folder / 'native'
    fixture.mkdir(exist_ok=True)
    for name in ('sysctl', 'vm_stat', 'processes.json'):
        (fixture / name).unlink(missing_ok=True)
    if broken:
        return
    (fixture / 'sysctl').write_text('%d\n%d\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' % (total, pressure))
    (fixture / 'vm_stat').write_text(
        'Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'
        'Pages free: 1000.\nPages speculative: 100.\n'
        'Anonymous pages: 1048576.\nFile-backed pages: %d.\n'
        'Pages purgeable: 100.\nPages occupied by compressor: 32768.\n' % (available // 16384 - 1100))
    # pid 50 is the no-mistakes daemon; a run entry (repo, id, rss, True) is a process it started.
    rows = [dict(pid=101, ppid=1, comm='daemon', started='s101', rss_bytes=GIB, fleet=False, run=None),
            dict(pid=50, ppid=1, comm='no-mistakes', started='s50', rss_bytes=GIB // 8, fleet=False, run=None)]
    for index, entry in enumerate(runs):
        repo, run, rss = entry[:3]
        if len(entry) == 5:  # a real process: (repo, run, rss, pid, start_us), joined by pid and exact start time
            rows.append(dict(pid=entry[3], ppid=1, comm='node', started='s%d' % index, start_us=entry[4], rss_bytes=rss,
                             rss_source='task', fleet=True, run='no-mistakes:%s/%s' % (repo, run)))
            continue
        rows.append(dict(pid=200 + index, ppid=50 if entry[3:] == (True,) else 1, comm='2.1.318' if entry[3:] == (True,) else 'node',
                         started='s%d' % index, rss_bytes=rss, fleet=True, run='no-mistakes:%s/%s' % (repo, run)))
    (fixture / 'processes.json').write_text(json.dumps(rows))


def procs(folder, count=100, limit=10666, error=False):
    write_json(folder / 'procs.json', dict(count=count, limit=limit, error=error))


def readings(folder, active=GIB, total=128 * GIB, host=None):
    """The root home's recorded readings: one reading whose two run trees make the active-run term A.

    A is (sum - largest) / (count - 1) over recorded readings with at least two runs, so a
    reading holding A and 5 x A gives A; an error reading and another host's reading are ignored.
    """
    state = folder / 'fmhome' / 'state'
    state.mkdir(parents=True, exist_ok=True)
    name = host or socket.gethostname()
    lines = [dict(host=name, total_bytes=total, errors=[], runs={
                 'no-mistakes:r/a': dict(rss_bytes=int(active)), 'no-mistakes:r/b': dict(rss_bytes=int(5 * active)),
                 'task:crewmate': dict(rss_bytes=60 * GIB)}),
             dict(host=name, total_bytes=total, errors=['memory: unreadable'], runs={
                 'no-mistakes:r/c': dict(rss_bytes=40 * GIB), 'no-mistakes:r/d': dict(rss_bytes=40 * GIB)}),
             dict(host='other-host', total_bytes=total, errors=[], runs={
                 'no-mistakes:r/e': dict(rss_bytes=40 * GIB), 'no-mistakes:r/f': dict(rss_bytes=40 * GIB)})]
    (state / 'memory-readings.jsonl').write_text(''.join(json.dumps(line) + '\n' for line in lines))


def calibrate(folder, peaks=PEAKS, total=128 * GIB, host=None, live=(), extra=None, active=GIB):
    """The root home's recorded calibration: one no-mistakes run per peak, 2 readings each.

    live names runs (repo_id NULL) whose young, low peak the probe has folded in already;
    extra maps more runs (repo_id NULL) to their recorded peak in bytes. The readings
    record beside it sets the active-run term A (active, None for no record).
    """
    state = folder / 'fmhome' / 'state'
    state.mkdir(parents=True, exist_ok=True)
    if active is not None:
        readings(folder, active, total, host)
    runs = {'no-mistakes:repo/run-%d' % i: dict(peak_bytes=int(peak * GIB), samples=2, incomplete_samples=0,
                                                 first_seen='x', last_seen='x', max_gap_seconds=0)
            for i, peak in enumerate(peaks)}
    runs['task:crewmate'] = dict(peak_bytes=64 * GIB, samples=9)
    for run in live:
        runs['no-mistakes:None/' + run] = dict(peak_bytes=GIB // 5, samples=2, incomplete_samples=0,
                                                first_seen='x', last_seen='x', max_gap_seconds=0)
    for run, peak in (extra or {}).items():
        runs['no-mistakes:None/' + run] = dict(peak_bytes=peak, samples=2, incomplete_samples=0,
                                                first_seen='x', last_seen='x', max_gap_seconds=0)
    write_json(state / '.memory-calibration.json', dict(
        schema='fm-memory-calibration.v1', host=host or socket.gethostname(), total_bytes=total, runs=runs, pressured=None))


def activate(folder, at=None):
    """The pinned gate's pool activation record (Main 1761): its time, before every run the case creates, and its sha256."""
    (folder / 'pool').mkdir(exist_ok=True)
    write_json(folder / 'pool' / 'gate-activation.json', dict(activated_at=int(time.time()) - 10 if at is None else at,
                                                             gate_sha256='0' * 64))


def case(name, cores=18, running=0, load=0, measured=False, available=40 * GIB, activated=True):
    folder = root / name
    folder.mkdir()
    db = folder / 'state.sqlite'
    with sqlite3.connect(db) as connection:
        # created_at defaults to the insert's second, as the daemon writes it (epoch seconds).
        connection.execute("CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER, repo_id TEXT, worktree_dir TEXT, branch TEXT, intent TEXT, created_at INTEGER DEFAULT (CAST(strftime('%s', 'now') AS INTEGER)), launch_nonce TEXT, head_sha TEXT, submitted_head_sha TEXT)")
        # The daemon's step_results columns this owner reads (PRAGMA table_info of the host database).
        connection.execute('CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL, step_order INTEGER NOT NULL, status TEXT NOT NULL, agent_pid INTEGER, round_started_at INTEGER)')
        connection.execute('CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL)')
        # The daemon's agent_invocations columns this owner reads (PRAGMA table_info of the host database).
        connection.execute("CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, purpose TEXT,"
                           " started_at INTEGER, completed_at INTEGER, duration_ms INTEGER, exit_status TEXT, session_key TEXT,"
                           " agent TEXT DEFAULT 'claude')")
        connection.executemany('INSERT INTO runs (id, status) VALUES (?, ?)', [('baseline-' + str(i), 'running') for i in range(running)])
        # Each baseline run is at an agent step: a counted run with no open step row is unknown (Main 1759).
        connection.executemany("INSERT INTO step_results (id, run_id, step_name, step_order, status) VALUES (?, ?, 'review', 1, 'running')",
                               [('baseline-%d-s' % i, 'baseline-' + str(i)) for i in range(running)])
    load_file = folder / 'load.json'
    write_json(load_file, [0, load, 0])
    facts(folder, available=available)
    procs(folder)
    if measured:
        calibrate(folder)
    (folder / 'fmhome').mkdir(exist_ok=True)
    if activated:
        activate(folder)
    env = dict(base, CASE_LOAD=str(load_file), CASE_DB=str(db), CASE_FOLDER=str(folder), FM_CPU_POOL_DIR=str(folder / 'pool'),
               CASE_CORES=str(cores), CASE_PROCS=str(folder / 'procs.json'), FM_MEMORY_FIXTURE_DIR=str(folder / 'native'),
               FM_HOME=str(folder / 'fmhome'))
    return folder, db, env


def change(db, sql, parameters=()):
    with sqlite3.connect(db) as connection:
        connection.execute(sql, parameters)


def launch(command, env, log, cwd=None):
    out = open(str(log) + '.stdout', 'w')
    err = open(str(log) + '.stderr', 'w')
    child = subprocess.Popen(command, env=env, stdout=out, stderr=err, start_new_session=True, cwd=None if cwd is None else str(cwd))
    out.close()
    err.close()
    children.append(child)
    records.append(dict(command=command, stdout=str(log) + '.stdout', stderr=str(log) + '.stderr'))
    return child


def finish(child, code=0):
    actual = wait_exit(child, 'pid %d to exit with %r' % (child.pid, code))
    assert actual == code, (actual, code, records)


SPACING_LIMIT = 1.5  # seconds: the median gap between consecutive grants; the handshake gives about 1.0, a 2 s injected delay gives 2 or more


def grant_gaps(folder, names):
    """Seconds between consecutive grants, from the nanosecond times the fake starts touched."""
    stamps = sorted((folder / (name + '.started')).stat().st_mtime_ns for name in names)
    return [(later - earlier) / 1e9 for earlier, later in zip(stamps, stamps[1:])]


def assert_no_spacing(folder, names):
    """Reject artificial spacing: ready starts follow each other by the registration handshake only.

    The median gap decides, so one gap stretched by scheduling noise cannot fail a correct burst,
    while a delay on every launch moves the median itself.
    """
    gaps = grant_gaps(folder, names)
    assert statistics.median(gaps) < SPACING_LIMIT, ('artificial wait between grants', [round(gap, 2) for gap in gaps])
    return gaps


def live_entries(folder, pattern='pipeline-waiter-*.lock'):
    """Entries whose owner still holds its lock; a dead owner's inert file does not count."""
    import fcntl
    live = 0
    for path in (folder / 'pool').glob(pattern):
        try:
            fd = os.open(str(path), os.O_RDONLY)
        except FileNotFoundError:
            continue
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            live += 1
        finally:
            os.close(fd)
    return live


def pending(folder, count):
    wait_for(lambda: live_entries(folder) == count, str(count) + ' registered waiters')


def held(env):
    return json.loads(subprocess.check_output(cli + ['status', '--json'], env=env, text=True))['held']


def clean_stop(db, writer):
    """Leave the state a real last writer leaves: all checkpointed, no side files.

    Some SQLite builds keep the files on close, so the fixture removes them.
    """
    writer.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall()
    writer.close()
    for side in ('-wal', '-shm'):
        Path(str(db) + side).unlink(missing_ok=True)


def registered_checkout(folder, db):
    """FOLDER/checkout: a git checkout on branch main, registered as repository 'repo' (repos.working_path)."""
    checkout = folder / 'checkout'
    if not checkout.exists():
        subprocess.run(['git', 'init', '-q', '-b', 'main', str(checkout)], check=True, stdin=subprocess.DEVNULL)
        change(db, "INSERT INTO repos (id, working_path) VALUES ('repo', ?)", (str(checkout),))
    return checkout


def client_start(folder, db, env, name):
    """A fresh no-mistakes start whose own run this fixture registers: (command, cwd) for pipeline-start.

    The fake client (start.py, reached as no-mistakes on PATH) runs in its own worktree of the registered checkout,
    on its own branch NAME, so each run is the one active run of its repository and branch, as the daemon keeps it
    (Main 3852). It registers its own running row (repo, branch NAME, intent NAME) after CASE_LAUNCH_DELAY, touches
    NAME.started, waits for NAME.release, then completes its run, as a real client's run does.
    """
    checkout = registered_checkout(folder, db)
    own = folder / ('wt-' + name)
    if not own.exists():
        git = ['git', '-C', str(checkout), '-c', 'user.name=fixture', '-c', 'user.email=fixture@invalid']
        if subprocess.run(git + ['rev-parse', '-q', '--verify', 'HEAD'], stdin=subprocess.DEVNULL, capture_output=True).returncode:
            subprocess.run(git + ['commit', '-q', '--allow-empty', '--no-verify', '-m', 'fixture'], check=True, stdin=subprocess.DEVNULL)
        subprocess.run(git + ['worktree', 'add', '-q', '-b', name, str(own)], check=True, stdin=subprocess.DEVNULL)
    if not (folder / 'clientbin').exists():
        bin_dir = folder / 'clientbin'
        bin_dir.mkdir()
        (bin_dir / 'no-mistakes').write_text('#!' + python + '\n' + 'import runpy, sys\nrunpy.run_path(%r, run_name="__main__")\n' % str(worker))
        (bin_dir / 'no-mistakes').chmod(0o700)
        env.update(PATH=str(bin_dir) + os.pathsep + env['PATH'])
    return ['no-mistakes', 'axi', 'run', '--intent', name], own


worker = root / 'start.py'
worker.write_text('''import os, pathlib, sqlite3, sys, time
if sys.argv[1:3] == ['axi', 'run']:  # reached as the fake no-mistakes client (client_start)
    folder, name = pathlib.Path(os.environ['CASE_FOLDER']), sys.argv[sys.argv.index('--intent') + 1]
else:
    folder, name = pathlib.Path(sys.argv[1]), sys.argv[2]
# Test-only: a delay before this fake start registers, while the admission lock is held.
time.sleep(float(os.environ.get('CASE_LAUNCH_DELAY', '0')))
with sqlite3.connect(folder / 'state.sqlite') as db:
    db.execute('INSERT INTO runs (id, status, repo_id, branch, intent, created_at) VALUES (?, ?, ?, ?, ?, ?)',
               (name, 'running', 'repo', name, name, int(time.time())))
with (folder / 'order').open('a') as out: out.write(name + '\\n')
(folder / (name + '.started')).touch()
while not (folder / (name + '.release')).exists(): time.sleep(0.025)
with sqlite3.connect(folder / 'state.sqlite') as db:
    db.execute('UPDATE runs SET status=? WHERE id=?', ('completed', name))
''')

# The launch gate: the agent launcher's final exec. It maps its directory to one run, passes
# every other step through, and before a CI fix agent starts it queues in class order, decides
# with the same owner for one more active run, publishes the run's reservation under the start
# lock, then starts the agent as its child.
agent = root / 'agent.py'
agent.write_text("""import atexit, hashlib, json, os, pathlib, signal, sqlite3, sys, time
folder, run = pathlib.Path(os.environ['CASE_FOLDER']), sys.argv[1]
with open(os.environ['CASE_COALITION_FILE'], 'a') as registry: registry.write(str(os.getpid()) + ' ')
if os.environ.get('CASE_DAEMON_ROW') and os.environ.get('CASE_SESSION_ID'):
    # The daemon's invocation row, written as the invocation returns (no-mistakes fork internal/pipeline/instrument.go).
    def daemon_row(session=os.environ['CASE_SESSION_ID'], database=os.environ['CASE_DAEMON_ROWS']):
        with sqlite3.connect(database) as db:
            db.execute("INSERT INTO agent_invocations (id, run_id, step_name, purpose, started_at, completed_at, duration_ms,"
                       " exit_status, session_key) VALUES (?, ?, 'ci', 'ci', 1, 2, 1, 'launched', ?)",
                       (session, run, hashlib.sha256(session.encode()).hexdigest()[:16]))
    atexit.register(daemon_row)
mode = os.environ.get('CASE_AGENT', 'wait')
if os.environ.get('CASE_SESSION_ID'):  # a Claude-shaped first stream-json line naming this launch's session
    sys.stdout.write(json.dumps(dict(type='system', subtype='init', session_id=os.environ['CASE_SESSION_ID'])) + chr(10))
    sys.stdout.flush()
if mode == 'trap':  # installed before the marker that tells the test to signal
    signal.signal(signal.SIGTERM, lambda *a: (folder / (run + '.got-term')).touch() or sys.exit(0))
(folder / (run + '.agent')).write_text(json.dumps(dict(pid=os.getpid(), pgid=os.getpgid(0), started_ns=time.time_ns(),
    cwd=os.getcwd(), argv=sys.argv[2:], stdin=sys.stdin.read() if mode not in ('wait', 'trap') else '')))
if mode == 'escape':  # an orphaned descendant: own session, every descriptor closed, an empty environment, then the agent exits
    if os.fork() == 0:
        os.setsid()
        os.closerange(3, 65536)
        os.chdir('/')
        # An empty environment, or (CASE_COPIED_IDENTITY) one carrying another attempt's identity copied into it.
        copied = {'FM_LAUNCH_ATTEMPT': os.environ['CASE_COPIED_IDENTITY']} if os.environ.get('CASE_COPIED_IDENTITY') else {}
        os.execve(sys.executable, [sys.executable, '-I', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'escapee.py'),
                                   str(folder), run, os.environ['CASE_COALITION_FILE']], copied)
    while not (folder / (run + '.escapee')).exists(): time.sleep(0.02)
    sys.exit(0)
if mode.startswith('exit-'): sys.exit(int(mode[5:]))
if mode == 'self-term': os.kill(os.getpid(), signal.SIGTERM)
while not (folder / (run + '.release')).exists(): time.sleep(0.025)
""")

escapee = root / 'escapee.py'
escapee.write_text("""import os, pathlib, sys, time
folder, run, registry = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
with open(registry, 'a') as handle: handle.write(str(os.getpid()) + ' ')
(folder / (run + '.escapee')).write_text(str(os.getpid()))
while not (folder / (run + '.escapee-release')).exists(): time.sleep(0.05)
""")


def prove(folder, db, run, key=None):
    """Record that every earlier launch of RUN is shown ended (Main 1656, Main 1712): one daemon invocation row with
    its own session key and an ended attempt record carrying it. The row's exit status is not 'ok', so no hold bound
    or percentile counts it."""
    key = key or 'proof-' + run
    change(db, "INSERT INTO agent_invocations (id, run_id, step_name, purpose, started_at, completed_at, duration_ms,"
               " exit_status, session_key) VALUES (?, ?, 'ci', 'ci', 1, 2, 1, 'proof', ?)", ('proof-' + run, run, key))
    (folder / 'pool').mkdir(exist_ok=True)
    write_json(folder / 'pool' / ('attempt-proof-%s.json' % run), dict(
        id='proof-' + run, run=run, repo='repo', step='ci', reserves=True, t0_us=1, root=[1, 0], gate=None, watcher=None,
        coalition=None, session_key=key, members=[], ended_us=1))


def gate_case(name, available=40 * GIB, runs=(('x', 'ci', 'running', None),), timeout='240m', ci_ms=(60000,), round_age=0,
              proven=True):
    """One launch-gate host: runs are (id, open step or None, step status, recorded agent pid).

    The daemon's columns this gate reads (PRAGMA table_info of the host database): agent_invocations
    run_id, step_name, started_at, completed_at, duration_ms, exit_status; step_results round_started_at
    (epoch seconds, written at the step's or fix round's start, round_age seconds ago here); repos working_path.
    With proven, the gate's activation record predates every run and every earlier launch of each CI-step run is shown
    ended (prove); each gate launch then names its own session and the daemon's row for it is written (gate). Without
    it, no activation record exists, so no run's history is shown complete.
    """
    folder, db, env = case(name, measured=True, available=available, activated=proven)
    home = folder / 'home'
    (home / '.no-mistakes').mkdir(parents=True)
    if timeout is not None:
        (home / '.no-mistakes' / 'config.yaml').write_text('agent: [claude]\nagent_timeout: "%s"\n' % timeout)
    with sqlite3.connect(db) as connection:
        connection.executemany('INSERT INTO agent_invocations (id, run_id, step_name, purpose, started_at, completed_at,'
                               ' duration_ms, exit_status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                               [('i%d' % i, 'old', 'ci', 'ci', 1000, 1000 + ms // 1000, ms, 'ok') for i, ms in enumerate(ci_ms)] +
                               # A refused or timed-out invocation is recorded too, and never counts toward the bound.
                               [('refused', 'old', 'ci', 'ci', 1000, 2000, 10 ** 9, 'error'),
                                ('review', 'old', 'review', 'review', 1000, 2000, 10 ** 9, 'ok')])
    for run, step, status, pid in runs:
        (folder / ('wt-' + run)).mkdir()
        change(db, "INSERT INTO runs (id, status, repo_id, worktree_dir, branch) VALUES (?, 'running', 'repo', ?, ?)",
               (run, str(folder / ('wt-' + run)), 'fm/' + run))
        if step:
            change(db, 'INSERT INTO step_results (id, run_id, step_name, step_order, status, agent_pid, round_started_at)'
                   ' VALUES (?, ?, ?, 1, ?, ?, ?)', (run + '-s', run, step, status, pid, math.ceil(time.time()) - round_age))
        if step == 'ci' and proven:
            prove(folder, db, run)
    env.update(HOME=str(home))
    if proven:
        env['CASE_DAEMON_ROWS'] = str(db)
    return folder, db, env


def gate(folder, env, run, mode='wait', stdin=b'', cwd=None, log=None, session=True):
    log = folder / (log or ('gate-' + run))
    out, err = open(str(log) + '.stdout', 'w'), open(str(log) + '.stderr', 'w')
    env = dict(env, CASE_AGENT=mode)
    if session and env.get('CASE_DAEMON_ROWS') and not env.get('CASE_SESSION_ID'):
        # This launch names its own session, and the agent stand-in writes the daemon's invocation row carrying its
        # key as it exits (the daemon writes it when the invocation returns).
        env.update(CASE_SESSION_ID='session-%s-%d' % (os.path.basename(str(log)), len(records)), CASE_DAEMON_ROW='1')
    child = subprocess.Popen(['bash', str(repo / 'bin/fm-cpu-pass.sh'), 'launch-gate', '--', python, str(agent), run, '-p', '--flag'],
                             env=env, stdin=subprocess.PIPE, stdout=out, stderr=err,
                             cwd=str(cwd or folder / ('wt-' + run)), start_new_session=True)
    out.close(); err.close()
    child.stdin.write(stdin); child.stdin.close()
    children.append(child)
    records.append(dict(command=['launch-gate', run], stdout=str(log) + '.stdout', stderr=str(log) + '.stderr'))
    return child, log

def wakes(folder):
    queue = folder / 'fmhome' / 'state' / '.wake-queue'
    return queue.read_text() if queue.exists() else ''

def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True

retry_needles = [  # internal/agent/retry.go transientNeedles, terminalNeedles, usageLimitNeedles (fork 935aedf)
    'overloaded_error', '"type":"overloaded"', 'rate_limit_error', 'rate_limited', 'service_unavailable', 'connection refused',
    'connection reset', 'i/o timeout', 'no such host', 'temporary failure in name resolution', 'tls handshake', 'unexpected eof',
    'ended its turn with prose', 'declaring permissions', 'invalid tool call', "invalid character '<' after top-level value",
    'split bare json objects could not be fused into one valid object', 'freeusagelimit', 'free usage limit', 'free_usage_limit',
    'insufficient quota', 'insufficient_quota', 'exceeded your current quota', 'quota exceeded', 'quota_exceeded',
    'quota exhausted', 'quota_exhausted', 'usage_limit_reached', 'usage limit has been reached']

def no_retry_phrase(text):
    import re
    lowered = text.lower()
    assert not [n for n in retry_needles if n in lowered] and not re.search(r'\b(429|503|529)\b', lowered), text

_engine_module = []


def engine():
    """The tree's own engine, loaded in this test process for read-only kernel facts and attempt judgments.

    It sees the same coalition scope as the engine under test (the proxy's scope_coalition).
    """
    if not _engine_module:
        import importlib.util
        info_spec = importlib.util.spec_from_file_location('fm_proc_info', str(repo / 'bin' / 'fm-proc-info.py'))
        info = importlib.util.module_from_spec(info_spec)
        sys.modules['fm_proc_info'] = info
        info_spec.loader.exec_module(info)
        namespace = {}
        exec(proxy.read_text().split('\nif len(sys.argv) > 1', 1)[0].split('\n', 1)[1], namespace)  # the proxy's own scope_coalition
        namespace['scope_coalition'](info, str(coalition_registry), os.getpid())
        spec = importlib.util.spec_from_file_location('fm_cpu_pass_engine', str(repo / 'bin' / 'fm-cpu-pass.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _engine_module.append(module)
    return _engine_module[0]


class Held(int):
    """A count of held attempts that also carries their reasons, so a failed assertion names why each is held."""
    reasons: list = []

    def __repr__(self):
        return '%d held: %s' % (int(self), self.reasons)


def reserving_held(folder, runs):
    """How many attempt records of these runs reserve and are held (a decision's own judgment, P9.sequence(5))."""
    states = engine().judge_attempts(str(folder / 'pool'), set(runs)) if (folder / 'pool').is_dir() else {}
    held = [state['reason'] for state in states.values()
            if state['state'] == 'held' and state['record'] and state['record'].get('reserves', True)]
    count = Held(len(held))
    count.reasons = held
    return count


def agent_info(path):
    """The agent stand-in's marker, once it is written whole (the stand-in writes it in one call that is not atomic)."""
    found = {}

    def whole():
        try:
            found.update(json.loads(path.read_text()))
            return True
        except (OSError, ValueError):
            return False
    wait_for(whole, 'the agent marker %s written' % path.name)
    return found


def settled_held(folder, runs):
    """reserving_held after two censuses: an attempt with nothing left of it ends only at the second (Main 1759)."""
    reserving_held(folder, runs)
    return reserving_held(folder, runs)


def start_us(pid):
    """A live process's exact kernel start time in microseconds, as the memory reading reports it."""
    entry = engine().kernel_snapshot().get(pid)
    return None if entry is None else entry[1]


def cleanup():
    """Release and reap every fixture process this script started, and keep the command record."""
    for file in root.glob('*/release-children'):
        file.touch()
    for folder in root.glob('*'):
        if folder.is_dir(): (folder / 'release-children').touch()
    for marker in root.glob('*/*.escapee'):
        marker.with_name(marker.name + '-release').touch()
    for pid_file in root.glob('*/nested.pid'):
        if (pid_file.parent / 'nested.started').exists(): continue
        try: os.killpg(int(pid_file.read_text()), signal.SIGKILL)
        except (ProcessLookupError, ValueError): pass
    for child in children:
        if child.poll() is None:
            try: os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError: pass
        child.wait()
    (root / 'commands.json').write_text(json.dumps(records, indent=2) + '\n')
