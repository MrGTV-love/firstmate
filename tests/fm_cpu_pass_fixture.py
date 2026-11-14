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
            info.processes = unreadable
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
base = dict(os.environ, PATH=str(shim) + os.pathsep + os.environ['PATH'], FM_DURATION_FILE='off')
base.pop('FM_CPU_PASS_HELD', None)
children = []
records = []


def write_json(path, value):
    temp = path.with_suffix('.new')
    temp.write_text(json.dumps(value))
    temp.replace(path)


def wait_for(predicate, description):
    until = time.monotonic() + 30
    while not predicate():
        if time.monotonic() >= until:
            raise AssertionError('fixture observation fence: ' + description)
        time.sleep(0.025)


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


def case(name, cores=18, running=0, load=0, measured=False, available=40 * GIB):
    folder = root / name
    folder.mkdir()
    db = folder / 'state.sqlite'
    with sqlite3.connect(db) as connection:
        connection.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER, repo_id TEXT, worktree_dir TEXT, branch TEXT)')
        # The daemon's step_results columns this owner reads (PRAGMA table_info of the host database).
        connection.execute('CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL, step_order INTEGER NOT NULL, status TEXT NOT NULL, agent_pid INTEGER, round_started_at INTEGER)')
        connection.execute('CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL)')
        connection.executemany('INSERT INTO runs (id, status) VALUES (?, ?)', [('baseline-' + str(i), 'running') for i in range(running)])
    load_file = folder / 'load.json'
    write_json(load_file, [0, load, 0])
    facts(folder, available=available)
    procs(folder)
    if measured:
        calibrate(folder)
    (folder / 'fmhome').mkdir(exist_ok=True)
    env = dict(base, CASE_LOAD=str(load_file), CASE_DB=str(db), CASE_FOLDER=str(folder), FM_CPU_POOL_DIR=str(folder / 'pool'),
               CASE_CORES=str(cores), CASE_PROCS=str(folder / 'procs.json'), FM_MEMORY_FIXTURE_DIR=str(folder / 'native'),
               FM_HOME=str(folder / 'fmhome'))
    return folder, db, env


def change(db, sql, parameters=()):
    with sqlite3.connect(db) as connection:
        connection.execute(sql, parameters)


def launch(command, env, log):
    out = open(str(log) + '.stdout', 'w')
    err = open(str(log) + '.stderr', 'w')
    child = subprocess.Popen(command, env=env, stdout=out, stderr=err, start_new_session=True)
    out.close()
    err.close()
    children.append(child)
    records.append(dict(command=command, stdout=str(log) + '.stdout', stderr=str(log) + '.stderr'))
    return child


def finish(child, code=0):
    actual = child.wait(timeout=30)
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


worker = root / 'start.py'
worker.write_text('''import os, pathlib, sqlite3, sys, time
folder, name = pathlib.Path(sys.argv[1]), sys.argv[2]
# Test-only: a delay before this fake start registers, while the admission lock is held.
time.sleep(float(os.environ.get('CASE_LAUNCH_DELAY', '0')))
with sqlite3.connect(folder / 'state.sqlite') as db:
    db.execute('INSERT INTO runs (id, status) VALUES (?, ?)', (name, 'running'))
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
agent.write_text("""import json, os, pathlib, signal, sys, time
folder, run = pathlib.Path(os.environ['CASE_FOLDER']), sys.argv[1]
mode = os.environ.get('CASE_AGENT', 'wait')
if mode == 'trap':  # installed before the marker that tells the test to signal
    signal.signal(signal.SIGTERM, lambda *a: (folder / (run + '.got-term')).touch() or sys.exit(0))
(folder / (run + '.agent')).write_text(json.dumps(dict(pid=os.getpid(), pgid=os.getpgid(0), started_ns=time.time_ns(),
    cwd=os.getcwd(), argv=sys.argv[2:], stdin=sys.stdin.read() if mode not in ('wait', 'trap') else '')))
if mode.startswith('exit-'): sys.exit(int(mode[5:]))
if mode == 'self-term': os.kill(os.getpid(), signal.SIGTERM)
while not (folder / (run + '.release')).exists(): time.sleep(0.025)
""")

def gate_case(name, available=40 * GIB, runs=(('x', 'ci', 'running', None),), timeout='240m', ci_ms=(60000,), round_age=0):
    """One launch-gate host: runs are (id, open step or None, step status, recorded agent pid).

    The daemon's columns this gate reads (PRAGMA table_info of the host database): agent_invocations
    run_id, step_name, started_at, completed_at, duration_ms, exit_status; step_results round_started_at
    (epoch seconds, written at the step's or fix round's start, round_age seconds ago here); repos working_path.
    """
    folder, db, env = case(name, measured=True, available=available)
    home = folder / 'home'
    (home / '.no-mistakes').mkdir(parents=True)
    if timeout is not None:
        (home / '.no-mistakes' / 'config.yaml').write_text('agent: [claude]\nagent_timeout: "%s"\n' % timeout)
    with sqlite3.connect(db) as connection:
        connection.execute('CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, purpose TEXT,'
                           ' started_at INTEGER, completed_at INTEGER, duration_ms INTEGER, exit_status TEXT)')
        connection.executemany('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
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
    env.update(HOME=str(home))
    return folder, db, env


def gate(folder, env, run, mode='wait', stdin=b'', cwd=None, log=None):
    log = folder / (log or ('gate-' + run))
    out, err = open(str(log) + '.stdout', 'w'), open(str(log) + '.stderr', 'w')
    child = subprocess.Popen(['bash', str(repo / 'bin/fm-cpu-pass.sh'), 'launch-gate', '--', python, str(agent), run, '-p', '--flag'],
                             env=dict(env, CASE_AGENT=mode), stdin=subprocess.PIPE, stdout=out, stderr=err,
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

def cleanup():
    """Release and reap every fixture process this script started, and keep the command record."""
    for file in root.glob('*/release-children'):
        file.touch()
    for folder in root.glob('*'):
        if folder.is_dir(): (folder / 'release-children').touch()
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
