#!/usr/bin/env python3
"""Executable fixtures for fm-cpu-pass.test.sh; never use fleet state, load or the live host."""
import hashlib
import json
import os
from pathlib import Path
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
    if os.environ.get('CASE_GATE_RAISE'):
        import subprocess
        real_wait = subprocess.Popen.wait
        def broken_wait(self, timeout=None):
            if any('agent.py' in str(part) for part in self.args) and not getattr(self, 'raised', False):
                self.raised = True
                import glob, time
                while not glob.glob(os.path.join(os.environ['CASE_FOLDER'], '*.agent')): time.sleep(0.025)
                raise RuntimeError('injected gate error after the agent started')
            return real_wait(self, timeout)
        subprocess.Popen.wait = broken_wait
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
    rows = [dict(pid=101, ppid=1, comm='daemon', started='s101', rss_bytes=GIB, fleet=False, run=None)]
    for index, (repo, run, rss) in enumerate(runs):
        rows.append(dict(pid=200 + index, ppid=1, comm='node', started='s%d' % index, rss_bytes=rss, fleet=True,
                         run='no-mistakes:%s/%s' % (repo, run)))
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
        connection.execute('CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL, step_order INTEGER NOT NULL, status TEXT NOT NULL, agent_pid INTEGER)')
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

try:
    # Native core scaling: 18 cores admit six counted runs and 10 cores three.
    # One below the limit admits at once; at the limit the next start queues
    # without running until a counted run is released.
    for cores, limit in ((18, 6), (10, 3)):
        folder, db, env = case('scaling-' + str(cores), cores=cores, running=limit - 1)
        marker = folder / 'below.marker'
        finish(launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'below'))
        assert marker.exists()
        change(db, "INSERT INTO runs (id, status) VALUES ('at-limit', 'running')")
        marker = folder / 'at.marker'
        child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'at')
        pending(folder, 1)
        wait_for(lambda: 'waiting: ' in (folder / 'at.stderr').read_text(), str(cores) + '-core start queued at the limit')
        assert not marker.exists() and child.poll() is None
        change(db, "UPDATE runs SET status='completed' WHERE id='at-limit'")
        finish(child)
        assert marker.exists()

    # Load average is not an admission input. With too little recorded history the
    # start falls back to the counted-run limit, and a high load5 neither blocks a
    # start below it nor admits one at it.
    folder, db, env = case('fallback-ignores-load', running=5, load=500)
    marker, log = folder / 'high-load.marker', folder / 'high-load.stderr'
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'high-load'))
    assert marker.exists() and 'admitted: counted=5 limit=6 basis=fallback' in log.read_text(), log.read_text()
    folder, db, env = case('fallback-full-low-load', running=6, load=0)
    marker = folder / 'low-load.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'low-load')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=6 limit=6 basis=fallback' in (folder / 'low-load.stderr').read_text(), 'full fallback count')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    finish(child)
    assert marker.exists()
    # One qualifying recorded run, a record for another host, unreadable text and no
    # readings record of this host for A all fall back; none refuses and none reads as an empty host.
    for name, record in (('one-run', lambda f: calibrate(f, peaks=[3.0])), ('other-host', lambda f: calibrate(f, host='other-host')),
                         ('other-ram', lambda f: calibrate(f, total=64 * GIB)),
                         ('garbage', lambda f: (f / 'fmhome/state').mkdir(parents=True, exist_ok=True) or (f / 'fmhome/state/.memory-calibration.json').write_text('{')),
                         ('walk-fails', lambda f: calibrate(f) or (f / 'fmhome/.fm-secondmate-parent').write_text('garbage\n')),
                         ('no-readings', lambda f: calibrate(f, active=None)),
                         ('readings-other-host', lambda f: calibrate(f, active=None) or readings(f, host='other-host'))):
        folder, db, env = case('fallback-' + name, running=6)
        record(folder)
        child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm')], env, folder / 'f')
        pending(folder, 1)
        wait_for(lambda: 'waiting: counted=6 limit=6 basis=fallback' in (folder / 'f.stderr').read_text(), name + ' fallback count')
        assert child.poll() is None
        change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
        finish(child)
    # A secondmate home reads its parent's record (the root home owns the calibration).
    folder, db, env = case('root-home', running=6)
    calibrate(folder)
    (folder / 'fmhome').rename(folder / 'rootfm')
    (folder / 'childfm').mkdir()
    (folder / 'childfm/.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' % (folder / 'rootfm'))
    env['FM_HOME'] = str(folder / 'childfm')
    log = folder / 'root.stderr'
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'root.marker')], env, folder / 'root'))
    # Six registered runs the reading cannot see yet reserve R each: 6 x 3 + 8 = 26 GiB of 40.
    assert 'admitted: counted=6 projected=%d ' % (26 * GIB) in log.read_text() and \
        'reservation=%d active_term=%d slack=%d runs_measured=13 readings_measured=1 ' % (3 * GIB, GIB, 8 * GIB) in log.read_text(), log.read_text()

    # A worker has FM_DURATION_HOME and no FM_HOME; it still finds the root home's record.
    folder, db, env = case('worker-env', running=6, measured=True)
    env.pop('FM_HOME')
    env['FM_DURATION_HOME'] = str(folder / 'fmhome')
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'worker.marker')], env, folder / 'worker'))
    assert 'admitted: counted=6 projected=' in (folder / 'worker.stderr').read_text(), (folder / 'worker.stderr').read_text()

    # A running run's peak so far is not a per-run peak: six young runs at 0.2 GiB would pull
    # the 75th percentile down to 1 GiB, but R stays 3 GiB from the 13 finished runs.
    folder, db, env = case('live-runs', running=6, measured=True)
    calibrate(folder, live=['baseline-%d' % i for i in range(6)])
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'live.marker')], env, folder / 'live'))
    text = (folder / 'live.stderr').read_text()
    assert 'admitted: counted=6 projected=%d ' % (6 * 3 * GIB + 8 * GIB) in text and 'reservation=%d active_term=%d slack=%d runs_measured=13 ' % (3 * GIB, GIB, 8 * GIB) in text, text

    # S takes every qualifying peak: a CI-ready running run holds the largest (20 GiB), and
    # a peak so far can only be too low. R ranks that CI-ready run (14 peaks: 4 GiB) but
    # leaves out a parked run short of CI-ready (12 GiB), which would make the 12th rank 5.8 GiB.
    folder, db, env = case('ci-ready-peak', measured=True)
    calibrate(folder, extra={'ci-done': 20 * GIB, 'parked': 12 * GIB})
    change(db, "INSERT INTO runs (id, status, ci_ready_at) VALUES ('ci-done', 'running', 1)")
    change(db, "INSERT INTO runs (id, status, awaiting_agent_since) VALUES ('parked', 'running', 1)")
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'ci.marker')], env, folder / 'ci'))
    text = (folder / 'ci.stderr').read_text()
    # Nothing counted: the new run alone reserves S.
    assert 'admitted: counted=0 projected=%d ' % (20 * GIB) in text and 'reservation=%d active_term=%d slack=%d runs_measured=14 ' % (4 * GIB, GIB, 20 * GIB) in text, text

    # One-start minimum: with nothing counted, one start is admitted although S = 8 GiB
    # exceeds the 7 GiB budget, unless the backstop reports an overload.
    folder, db, env = case('floor', measured=True, available=7 * GIB)
    facts(folder, available=7 * GIB, pressure=2)
    marker = folder / 'floor.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'floor')
    pending(folder, 1)
    wait_for(lambda: 'waiting: overload: memory: native memory pressure level 2' in (folder / 'floor.stderr').read_text(), 'floor still pauses on overload')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    facts(folder, available=7 * GIB)
    finish(child)
    assert marker.exists() and 'admitted: counted=0 projected=%d budget=%d' % (8 * GIB, 7 * GIB) in (folder / 'floor.stderr').read_text()

    # Measured mode. R = 3 GiB (75th percentile of the 13 recorded peaks), S = 8 GiB
    # (the largest) and A = 1 GiB; the task:crewmate record is not a no-mistakes run and is ignored.
    # Each registered run the reading cannot see yet reserves R, the new run S; admit while
    # n x R + S <= available + held. 37 GiB admits n = 0..9 (9 x 3 + 8 = 35) and refuses n = 10 (38).
    folder, db, env = case('burst', cores=3, measured=True, available=37 * GIB)
    names = ['burst-%d' % i for i in range(11)]
    clients = {name: launch(cli + ['pipeline-start', '--', python, str(worker), str(folder), name], env, folder / name) for name in names[:10]}
    for name in names[:10]:
        wait_for(lambda: (folder / (name + '.started')).exists(), name + ' grant')
    # All ten run together, none waited for capacity, and three cores' fallback of one never applied.
    assert all(c.poll() is None for c in clients.values())
    for name in names[:10]:
        text = (folder / (name + '.stderr')).read_text()
        # A ready start may queue behind the registration handshake of the starts
        # before it; it is never told to wait for capacity, overload or spacing.
        waits = [line for line in text.splitlines() if 'waiting' in line]
        assert all('need=' not in line and 'overload' not in line and 'limit=' not in line for line in waits), text
        assert 'admitted: counted=' in text and 'basis=fallback' not in text, text
    assert any('projected=%d budget=%d' % (3 * GIB * 9 + 8 * GIB, 37 * GIB) in (folder / (name + '.stderr')).read_text() for name in names[:10])
    # No artificial wait: the grants follow each other by the registration handshake alone.
    burst_gaps = assert_no_spacing(folder, names[:10])
    # The eleventh projects 38 GiB of 37 and waits; releasing one run lets it start.
    clients[names[10]] = launch(cli + ['pipeline-start', '--', python, str(worker), str(folder), names[10]], env, folder / names[10])
    pending(folder, 1)
    wait_for(lambda: 'waiting: overload' not in (folder / (names[10] + '.stderr')).read_text() and
             'waiting: counted=10 projected=%d budget=%d' % (3 * GIB * 10 + 8 * GIB, 37 * GIB) in (folder / (names[10] + '.stderr')).read_text(),
             'eleventh start waits for reservations')
    assert not (folder / (names[10] + '.started')).exists()
    (folder / 'burst-0.release').touch()
    finish(clients['burst-0'])
    wait_for(lambda: (folder / (names[10] + '.started')).exists(), 'eleventh grant after a release')
    for name in names[1:]:
        (folder / (name + '.release')).touch()
        finish(clients[name])

    # The check must reject spacing. The same burst shape with a 2-second delay injected before
    # each fake start registers (the admission lock is held across it) passes the earlier
    # assertions but fails assert_no_spacing; the undelayed burst above passed it.
    folder, db, env = case('spacing-injected', cores=3, measured=True, available=37 * GIB)
    env['CASE_LAUNCH_DELAY'] = '2'
    names = ['slow-%d' % i for i in range(4)]
    clients = {name: launch(cli + ['pipeline-start', '--', python, str(worker), str(folder), name], env, folder / name) for name in names}
    for name in names:
        wait_for(lambda: (folder / (name + '.started')).exists(), name + ' delayed grant')
    for name in names:
        text = (folder / (name + '.stderr')).read_text()
        waits = [line for line in text.splitlines() if 'waiting' in line]
        assert all('need=' not in line and 'overload' not in line and 'limit=' not in line for line in waits), text
        assert 'admitted: counted=' in text and 'basis=fallback' not in text, text
    assert all(c.poll() is None for c in clients.values())
    try:
        assert_no_spacing(folder, names)
    except AssertionError as rejected:
        injected_rejection = str(rejected)
        injected_gaps = grant_gaps(folder, names)
    else:
        raise AssertionError('the injected 2-second per-launch delay was not rejected: %r' % grant_gaps(folder, names))
    for name in names:
        (folder / (name + '.release')).touch()
        finish(clients[name])

    # Load5 alone decides nothing: the same full reservations with idle load admit nothing
    # extra, and fitting reservations under a load of 500 are admitted.
    folder, db, env = case('load-both-ways', cores=18, running=1, measured=True, available=10 * GIB, load=0)
    # one counted run the reading cannot see yet: projected = 3 + 8 = 11 GiB > 10 GiB
    marker = folder / 'idle-full.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'idle-full')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=1 projected=%d budget=%d' % (11 * GIB, 10 * GIB) in (folder / 'idle-full.stderr').read_text(), 'idle load, full reservations')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    # Once visible, the counted run reserves its resident memory or A, whichever is larger,
    # and what it holds is part of the budget: 1 + 8 = 9 GiB of 10 + 1.
    facts(folder, available=10 * GIB, runs=[(None, 'baseline-0', GIB)])
    finish(child)
    assert marker.exists() and 'admitted: counted=1 projected=%d budget=%d' % (9 * GIB, 11 * GIB) in (folder / 'idle-full.stderr').read_text()
    # A counted run's memory is never capped at R or S: 7 GiB held counts 7 GiB in the projection
    # and 7 GiB in the budget, so it nets to nothing free. 7 GiB available: 15 > 14 waits; 8 GiB fits.
    folder, db, env = case('never-capped', cores=18, running=1, measured=True, available=7 * GIB)
    facts(folder, available=7 * GIB, runs=[(None, 'baseline-0', 7 * GIB)])
    marker = folder / 'over.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'over')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=1 projected=%d budget=%d' % (15 * GIB, 14 * GIB) in (folder / 'over.stderr').read_text(), 'resident memory above R is counted')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    facts(folder, available=8 * GIB, runs=[(None, 'baseline-0', 7 * GIB)])
    finish(child)
    assert marker.exists() and 'admitted: counted=1 projected=%d budget=%d' % (15 * GIB, 15 * GIB) in (folder / 'over.stderr').read_text()
    folder, db, env = case('busy-but-fits', cores=18, running=0, measured=True, available=40 * GIB, load=500)
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'busy.marker')], env, folder / 'busy'))
    assert (folder / 'busy.marker').exists()

    # The fleet's recorded healthy states are admitted at the first poll, and a fit that fails still waits.
    # Inputs: R 5.77 GiB and S 13.39 GiB (Main's live diagnosis), A = 1953340270 bytes (the largest
    # per-run concurrent demand of every run but the largest in the copied readings record).
    diag_peaks = [1.0, 2.0, 5.77, 13.39]
    diag_active = 1953340270

    def steps(db, rows):
        for run, name, status, pid in rows:
            change(db, 'INSERT INTO step_results (id, run_id, step_name, step_order, status, agent_pid) VALUES (?, ?, ?, ?, ?, ?)',
                   (run + '-' + name, run, name, 1, status, pid))

    def counted_case(name, available, active, waiting_ci=(), invisible=()):
        """Counted runs: active is (id, rss) at an agent step; waiting_ci and invisible list runs the reading cannot see."""
        folder, db, env = case(name, measured=True, available=available)
        calibrate(folder, peaks=diag_peaks, active=diag_active)
        for run, _ in active:
            change(db, "INSERT INTO runs (id, status, repo_id) VALUES (?, 'running', 'repo')", (run,))
        for run in list(waiting_ci) + list(invisible):
            change(db, "INSERT INTO runs (id, status, repo_id) VALUES (?, 'running', 'repo')", (run,))
        steps(db, [(run, 'review', 'fixing', 4000 + i) for i, (run, _) in enumerate(active)] +
              [(run, 'ci', 'running', None) for run in waiting_ci])
        facts(folder, available=available, runs=[('repo', run, rss) for run, rss in active])
        return folder, db, env

    # (a) Main's live case: 11 counted, 4 waiting on remote CI with no agent and no memory.
    live = [('test-fixing', int(0.70 * GIB)), ('review-a', int(0.43 * GIB)), ('lint', int(2.22 * GIB)),
            ('review-b', int(0.13 * GIB)), ('pr', int(0.13 * GIB)), ('test', int(0.43 * GIB)), ('review-c', int(0.73 * GIB))]
    folder, db, env = counted_case('p1-live', 32.82 * GIB // 16384 * 16384, live, waiting_ci=['ci-361', 'ci-367', 'ci-369', 'ci-3609'])
    finish(launch(cli + ['pipeline-start', '--priority', 'machinery', '--', 'sh', '-c', 'exit 3'], env, folder / 'p1a'), 3)
    text = (folder / 'p1a.stderr').read_text()
    assert 'admitted: counted=11 ' in text and 'start waiting' not in text and 'ci-361:ci-waiting:0:unseen' in text \
        and 'lint:active:%d' % int(2.22 * GIB) in text and 'review-b:active:%d' % diag_active in text, text
    # (b) the 2026-11-03 14:14Z record: 12 runs holding 20.1 GiB together, 25.27 GiB available.
    recorded = [21299200, 118226944, 491290624, 545144832, 574226432, 652591104, 673792000, 1083260928,
                1926561792, 3074097152, 5121441792, 7301611520]
    shape = [('run-%02d' % i, rss) for i, rss in enumerate(recorded)]
    folder, db, env = counted_case('p1-recorded', 27132805120, shape)
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'p1b')], env, folder / 'p1b'))
    text = (folder / 'p1b.stderr').read_text()
    assert 'admitted: counted=12 ' in text and 'start waiting' not in text, text
    projected = 9 * diag_active + 3074097152 + 5121441792 + 7301611520 + int(13.39 * GIB)
    threshold = projected - sum(recorded)
    assert 'projected=%d budget=%d' % (projected, 27132805120 + sum(recorded)) in text, (projected, text)
    # (c) control: the same state with available memory one page below the fit waits and names its inputs.
    folder, db, env = counted_case('p1-control', threshold // 16384 * 16384 - 16384, shape)
    child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'p1c')], env, folder / 'p1c')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=12 projected=%d ' % projected in (folder / 'p1c.stderr').read_text(), 'fit fails at healthy pressure')
    assert not (folder / 'p1c').exists() and 'reserved=[run-00:active:' in (folder / 'p1c.stderr').read_text()
    os.killpg(child.pid, signal.SIGTERM)
    finish(child, -signal.SIGTERM)

    # Which counted runs reserve: with R = 3, S = 8 and 10 GiB available, a counted run that reserves
    # R makes 11 GiB and waits, while one that holds only its resident memory admits.
    for label, rows, visible, admitted in (
            ('ci-waiting', [('x', 'ci', 'running', None)], [], True),
            ('ci-waiting-raised', [('x', 'ci', 'running', None)], [('repo', 'x', 4 * GIB)], True),
            ('ci-agent-resumed', [('x', 'ci', 'fixing', 4321)], [], False),
            ('ci-agent-pid', [('x', 'ci', 'running', 4321)], [], False),
            ('just-registered', [], [], False),
            ('step-unreadable', None, [], False),
            ('other-step', [('x', 'review', 'running', None)], [], False)):
        folder, db, env = case('p2-' + label, measured=True, available=10 * GIB)
        change(db, "INSERT INTO runs (id, status, repo_id) VALUES ('x', 'running', 'repo')")
        if rows is None:
            change(db, 'DROP TABLE step_results')
        else:
            steps(db, rows)
        facts(folder, available=10 * GIB, runs=visible)
        log = folder / 'p2.stderr'
        child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'p2')], env, folder / 'p2')
        if admitted:
            finish(child)
            held_now = visible[0][2] if visible else 0
            assert 'admitted: counted=1 projected=%d ' % (held_now + 8 * GIB) in log.read_text() and \
                'holding_only=[x:ci-waiting:%d' % held_now in log.read_text(), (label, log.read_text())
        else:
            pending(folder, 1)
            wait_for(lambda: 'waiting: counted=1 projected=%d ' % (11 * GIB) in log.read_text(), label + ' keeps its reservation')
            assert not (folder / 'p2').exists() and 'reserved=[x:' in log.read_text(), (label, log.read_text())
            os.killpg(child.pid, signal.SIGTERM)
            finish(child, -signal.SIGTERM)

    # Pause-only backstop (M3). Fitting reservations never override it, it stops nothing
    # that runs, and an unreadable observation never reads as an empty host.
    folder, db, env = case('backstop', measured=True, available=100 * GIB)
    running = launch(cli + ['pipeline-start', '--', python, str(worker), str(folder), 'already-running'], env, folder / 'already')
    wait_for(lambda: (folder / 'already-running.started').exists(), 'a run already started')
    before_hash = hashlib.sha256(db.read_bytes()).hexdigest()
    for label, bad, good, expected in (
            ('pressure', lambda: facts(folder, available=100 * GIB, pressure=2, runs=[(None, 'already-running', GIB)]),
             lambda: facts(folder, available=100 * GIB, runs=[(None, 'already-running', GIB)]), 'memory: native memory pressure level 2'),
            ('pileup', lambda: procs(folder, count=6400), lambda: procs(folder, count=6399), 'process pile-up: 6400 of 10666'),
            ('memory-unreadable', lambda: facts(folder, broken=True), lambda: facts(folder, available=100 * GIB), 'memory: '),
            ('procs-unreadable', lambda: procs(folder, error=True), lambda: procs(folder), 'process count unreadable'),
            ('limit-unreadable', lambda: procs(folder, limit=None), lambda: procs(folder), 'process limit unreadable: case')):
        bad()
        marker = folder / (label + '.marker')
        child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / label)
        pending(folder, 1)
        wait_for(lambda: 'waiting: overload: ' + expected in (folder / (label + '.stderr')).read_text(), label + ' pauses the start')
        time.sleep(0.6)
        assert not marker.exists() and child.poll() is None and running.poll() is None
        assert hashlib.sha256(db.read_bytes()).hexdigest() == before_hash
        good()
        finish(child)
        assert marker.exists(), label
    (folder / 'already-running.release').touch()
    finish(running)

    # A reading that was healthy a moment ago cannot admit a start after the signal turns bad:
    # the grant takes a new reading. Each case first lets a waiter see healthy inputs (it waits
    # at the full counted limit), then changes the signal and frees the slot together, so the old
    # cached reading is the only thing that could grant. It must keep waiting, then start once clear.
    for label, bad, good in (
            ('pressure', lambda f: facts(f, pressure=2), lambda f: facts(f)),
            ('pileup', lambda f: procs(f, count=6400), lambda f: procs(f, count=100)),
            ('memory-unreadable', lambda f: facts(f, broken=True), lambda f: facts(f)),
            ('procs-unreadable', lambda f: procs(f, error=True), lambda f: procs(f))):
        folder, db, env = case('transition-' + label, cores=3, running=1)
        marker, log = folder / 'transition.marker', folder / 'transition.stderr'
        child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'transition')
        pending(folder, 1)
        wait_for(lambda: 'waiting: counted=1 limit=1 basis=fallback' in log.read_text(), label + ' healthy reading seen while full')
        bad(folder)
        change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
        time.sleep(1.2)  # several polls inside the old 2-second reuse window
        assert not marker.exists() and child.poll() is None and 'admitted' not in log.read_text(), (label, log.read_text())
        good(folder)
        finish(child)
        assert marker.exists() and 'admitted: counted=0 limit=1 basis=fallback' in log.read_text(), (label, log.read_text())

    # A host whose counted runs are not CI-ready yet, so their peak may still rise (little memory left), pauses new starts
    # although a lull in load would allow them. Their resident memory is part of the budget,
    # so the pause comes from what the host really has left.
    # Startup memory alone is not a run's reservation: four visible runs at 0.5 GiB each reserve A = 1 GiB.
    folder, db, env = case('test-peak', measured=True, running=4, available=int(9.5 * GIB), load=0)
    facts(folder, available=int(9.5 * GIB), runs=[(None, 'baseline-%d' % i, GIB // 2) for i in range(4)])
    # budget = 9.5 + 2 = 11.5 GiB; projected = 4 x 1 + 8 = 12 GiB. A fifth start waits; one run finishing frees 1 GiB.
    marker = folder / 'peak.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'peak')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=4 projected=%d budget=%d' % (12 * GIB, int(11.5 * GIB)) in (folder / 'peak.stderr').read_text(), 'test peak pauses')
    time.sleep(0.6)
    assert not marker.exists()
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    facts(folder, available=int(9.5 * GIB), runs=[(None, 'baseline-%d' % i, GIB // 2) for i in range(1, 4)])
    finish(child)
    assert marker.exists()

    # Class order still decides who gets scarce capacity (exactly one start fits at a time).
    folder, db, env = case('measured-priority', cores=3, measured=True, running=1, available=10 * GIB)
    classes = ['other', 'vernant-build', 'machinery', 'merge-train']
    clients = {}
    for priority in classes:
        clients[priority] = launch(cli + ['pipeline-start', '--priority', priority, '--',
            python, str(worker), str(folder), priority], env, folder / priority)
        pending(folder, len(clients))
    time.sleep(0.6)
    assert not (folder / 'order').exists()
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    expected = list(reversed(classes))
    for index, priority in enumerate(expected):
        wait_for(lambda: (folder / (priority + '.started')).exists(), priority + ' grant')
        assert (folder / 'order').read_text().splitlines() == expected[:index + 1]
        (folder / (priority + '.release')).touch()
        finish(clients[priority])

    # Only status running rows with neither ci_ready_at nor awaiting_agent_since
    # count. Every excluded state is seeded; included rows alone fill the limit,
    # and each daemon-recorded exclusion releases a count when it is set.
    folder, db, env = case('count-definition', cores=3)
    limit = 1
    for row in (('ci-ready', 'running', 1, None), ('parked', 'running', None, 1), ('ci-ready-parked', 'running', 1, 1),
                ('pending', 'pending', None, None), ('completed', 'completed', None, None), ('failed', 'failed', None, None)):
        change(db, 'INSERT INTO runs (id, status, ci_ready_at, awaiting_agent_since) VALUES (?, ?, ?, ?)', row)
    for i in range(limit): change(db, "INSERT INTO runs (id, status) VALUES (?, 'running')", ('active-' + str(i),))
    for name, release in (('parked-start', "UPDATE runs SET awaiting_agent_since=1 WHERE id='active-0'"),
                          ('ci-ready-start', "UPDATE runs SET ci_ready_at=1 WHERE id='active-new'")):
        if name == 'ci-ready-start': change(db, "INSERT INTO runs (id, status) VALUES ('active-new', 'running')")
        marker, log = folder / (name + '.marker'), folder / (name + '.stderr')
        child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / name)
        pending(folder, 1)
        wait_for(lambda: 'waiting: counted=%d limit=%d ' % (limit, limit) in log.read_text(), name + ' full count')
        assert not marker.exists()
        change(db, release)
        finish(child)
        assert marker.exists() and 'admitted: counted=%d limit=%d ' % (limit - 1, limit) in log.read_text(), log.read_text()

    # Queue all classes while at capacity, then release one slot at a time.
    # The startup lock bridges registration even while earlier clients remain
    # alive. All requests initially observe the same full database.
    folder, db, env = case('priority-race', cores=3, running=1)
    limit = 1
    classes = ['other', 'vernant-build', 'machinery', 'merge-train']
    clients = {}
    for priority in classes:
        clients[priority] = launch(cli + ['pipeline-start', '--priority', priority, '--',
            python, str(worker), str(folder), priority], env, folder / priority)
        pending(folder, len(clients))
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    expected = list(reversed(classes))
    for index, priority in enumerate(expected):
        wait_for(lambda: (folder / (priority + '.started')).exists(), priority + ' grant')
        assert (folder / 'order').read_text().splitlines() == expected[:index + 1]
        with sqlite3.connect(db) as connection:
            assert connection.execute("SELECT count(*) FROM runs WHERE status='running'").fetchone()[0] == limit
        (folder / (priority + '.release')).touch()
        finish(clients[priority])
    assert (folder / 'order').read_text().splitlines() == expected

    # Unreadable/malformed sources never manufacture headroom or create a DB.
    folder, db, env = case('invalid')
    for bad in (folder / 'missing.sqlite', folder / 'garbage.sqlite'):
        if bad.name == 'garbage.sqlite': bad.write_text('not a database')
        child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'bad-start')], dict(env, CASE_DB=str(bad)), folder / bad.stem)
        finish(child, 125)
        assert not (folder / 'bad-start').exists()
    assert not (folder / 'missing.sqlite').exists()
    # The host database is in WAL mode. After its last writer stops cleanly it has
    # no side files, and mode=ro alone cannot read it. A fresh start still reads
    # the count, and a queued start keeps its place through the stop. The private
    # HOME holds the database at the fixed host path, where the -wal check looks.
    folder, db, env = case('wal', cores=3)
    host = folder / 'home/.no-mistakes/state.sqlite'
    host.parent.mkdir(parents=True)
    db.replace(host)
    db = host
    env.update(HOME=str(folder / 'home'), CASE_DB=str(db))
    writer = sqlite3.connect(db, isolation_level=None)
    writer.execute('PRAGMA journal_mode=WAL').fetchall()
    clean_stop(db, writer)
    before_hash = hashlib.sha256(db.read_bytes()).hexdigest()
    marker, log = folder / 'stopped.marker', folder / 'stopped.stderr'
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'stopped'))
    assert marker.exists() and 'admitted: counted=0 limit=1 ' in log.read_text(), log.read_text()
    assert hashlib.sha256(db.read_bytes()).hexdigest() == before_hash
    # The live writer's row is in the WAL file only, so this queue also proves a
    # live database is not read from its main file alone.
    writer = sqlite3.connect(db, isolation_level=None)
    writer.execute("INSERT INTO runs (id, status) VALUES ('wal-active', 'running')")
    marker, log = folder / 'queued.marker', folder / 'queued.stderr'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'queued')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=1 limit=1 ' in log.read_text(), 'queued at full count on a live WAL database')
    clean_stop(db, writer)
    # Longer than two maximum poll delays: the queue reads the stopped state.
    time.sleep(1.2)
    assert child.poll() is None and not marker.exists(), log.read_text()
    writer = sqlite3.connect(db, isolation_level=None)
    writer.execute("UPDATE runs SET status='completed'")
    clean_stop(db, writer)
    finish(child)
    assert marker.exists() and 'admitted: counted=0 limit=1 ' in log.read_text(), log.read_text()
    # A -wal file can hold rows that the main file does not. If it exists but
    # cannot be read, no start may proceed from the main file alone.
    writer = sqlite3.connect(db, isolation_level=None)
    writer.execute('PRAGMA wal_autocheckpoint=0').fetchall()
    writer.execute("INSERT INTO runs (id, status) VALUES ('wal-unread', 'running')")
    wal = Path(str(db) + '-wal')
    wal.chmod(0)
    marker, log = folder / 'unread.marker', folder / 'unread.stderr'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'unread')
    # A superuser can still read the file, so that start queues instead of refusing.
    wait_for(lambda: child.poll() is not None or 'waiting: counted=1 ' in log.read_text(), 'unread WAL outcome')
    assert not marker.exists() and child.poll() in (125, None), log.read_text()
    wal.chmod(0o600)
    writer.close()

    # Queue interruption cannot launch work, strand priority, or release another
    # request's CPU reservation. Failed commands preserve their actual status.
    folder, db, env = case('interrupt', cores=3, running=20)
    marker = folder / 'interrupted-start'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'queued')
    pending(folder, 1)
    os.killpg(child.pid, signal.SIGTERM)
    finish(child, -signal.SIGTERM)
    assert not marker.exists()
    # Waiters cancelled by SIGINT remove their own records while another queued
    # start scans them; that scan must never refuse the surviving start.
    survivor = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'survivor')], env, folder / 'survivor')
    pending(folder, 1)
    for i in range(20):
        cancelled = launch(cli + ['pipeline-start', '--priority', 'merge-train', '--', 'touch', str(folder / 'cancelled')],
                           env, folder / ('cancelled-' + str(i)))
        pending(folder, 2)
        os.killpg(cancelled.pid, signal.SIGINT)
        finish(cancelled, 130)
        assert survivor.poll() is None, (folder / 'survivor.stderr').read_text()
    assert not (folder / 'cancelled').exists()
    change(db, "UPDATE runs SET status='completed'")
    finish(survivor)
    assert (folder / 'survivor').exists()
    child = launch(cli + ['pipeline-start', '--', 'sh', '-c', 'exit 7'], env, folder / 'failure')
    finish(child, 7)
    child = launch(cli + ['pipeline-start', '--', 'true'], env, folder / 'after-failure')
    finish(child)

    # Six real child processes retain their markers but must inherit no slot
    # descriptors. Parent/master completion frees six passes while all remain
    # alive; this catches the pre-fix leak, not just a copied numeric marker.
    folder, db, env = case('descriptors', cores=10)
    master = folder / 'master.py'
    master.write_text('''import json, os, pathlib, subprocess, sys, time
folder = pathlib.Path(sys.argv[1]); pool = pathlib.Path(os.environ['FM_CPU_POOL_DIR'])
if len(sys.argv) > 2:
    inodes = {p.stat().st_ino for p in pool.glob('slot-*.lock')}
    descriptors = []
    for fd in range(3, 256):
        try:
            if os.fstat(fd).st_ino in inodes: descriptors.append(fd)
        except OSError: pass
    (folder / (str(os.getpid()) + '.child')).write_text(json.dumps(dict(pid=os.getpid(), fds=descriptors, marker=os.environ['FM_CPU_PASS_HELD'])))
    while not (folder / 'release-children').exists(): time.sleep(0.025)
else:
    children = [subprocess.Popen([sys.executable, __file__, str(folder), 'child'], close_fds=False) for _ in range(6)]
    while not (folder / 'release-master').exists(): time.sleep(0.025)
''')
    child = launch(cli + ['run', '--passes', '6', '--', python, str(master), str(folder)], env, folder / 'master')
    wait_for(lambda: len(list(folder.glob('*.child'))) == 6, 'six children')
    observations = [json.loads(p.read_text()) for p in folder.glob('*.child')]
    assert held(env) == 6
    assert all(item['fds'] == [] and item['marker'] == '6' for item in observations), observations
    (folder / 'release-master').touch()
    finish(child)
    assert held(env) == 0
    for item in observations: os.kill(item['pid'], 0)
    (folder / 'release-children').touch()
    (folder / 'observations.json').write_text(json.dumps(observations, indent=2))

    # Actual measured CLI: fresh input goes through admission BEFORE its bound;
    # wait-only reattachment does not requeue. A fresh start launched by the
    # admitted client is a descendant and must queue like any other start. This
    # fake native start writes only the private DB, never the shared daemon.
    folder, db, env = case('duration', cores=3, running=20)
    fake_nm = shim / 'no-mistakes'
    fake_nm.write_text('#!' + python + '\n' + """import os, pathlib, sqlite3, subprocess, sys
folder = pathlib.Path(os.environ['CASE_FOLDER'])
name = sys.argv[sys.argv.index('--intent') + 1] if '--intent' in sys.argv else 'reattach'
if name != 'reattach':
    with sqlite3.connect(folder / 'state.sqlite') as db: db.execute("INSERT INTO runs (id, status) VALUES (?, 'running')", (name,))
if name == 'outer':
    out = open(folder / 'nested.stdout', 'w'); err = open(folder / 'nested.stderr', 'w')
    nested = subprocess.Popen(['python3', %r, 'run', 'no-mistakes.nested', '--', sys.argv[0], 'axi', 'run', '--intent', 'nested'],
                              stdout=out, stderr=err, start_new_session=True)
    (folder / 'nested.pid').write_text(str(nested.pid))
(folder / (name + '.started')).touch()
""" % str(repo / 'bin/fm-duration.py'))
    fake_nm.chmod(0o700)
    env['FM_DURATION_FILE'] = str(folder / 'durations.jsonl')
    env['FM_DURATION_ABSOLUTE_SECS'] = '3'
    duration = [str(proxy), str(repo / 'bin/fm-duration.py'), 'run', '--pipeline-priority', 'machinery', 'no-mistakes.run', '--', str(fake_nm)]
    child = launch(duration + ['axi', 'run', '--intent', 'outer'], env, folder / 'fresh')
    pending(folder, 1)
    time.sleep(3.5)
    assert not (folder / 'outer.started').exists()
    change(db, "UPDATE runs SET status='completed'")
    finish(child)
    assert (folder / 'outer.started').exists()
    samples = lambda key='no-mistakes.run': [row for row in map(json.loads, Path(env['FM_DURATION_FILE']).read_text().splitlines())
                                             if row.get('key') == key and 'event' not in row]
    assert len(samples()) == 1 and samples()[0]['exit'] == 0 and not samples()[0]['timed_out'] \
        and samples()[0]['duration_ms'] < 3000, samples()
    wait_for(lambda: (folder / 'nested.pid').exists(), 'nested start launched')
    pending(folder, 1)
    time.sleep(0.6)
    assert not (folder / 'nested.started').exists()
    change(db, "UPDATE runs SET status='completed' WHERE id='outer'")
    wait_for(lambda: len(samples('no-mistakes.nested')) == 1, 'nested start admitted and measured')
    assert (folder / 'nested.started').exists() and samples('no-mistakes.nested')[0]['exit'] == 0, samples('no-mistakes.nested')
    assert 'pipeline-start admitted' in (folder / 'nested.stderr').read_text()
    change(db, "UPDATE runs SET status='running'")
    child = launch(duration + ['axi', 'run'], env, folder / 'reattach')
    finish(child)
    assert (folder / 'reattach.started').exists()
    # Every genuinely new run joins the one queue, whatever its command formatting; reattachment,
    # responses and status reads never queue. The fake client follows the real CLI's facts: a
    # rerun or an axi run with an intent input starts a run; axi run without one reattaches an
    # active run or exits 2 when none is active (internal/cli/axi_drive.go).
    nm_bin = root / 'nmbin'
    nm_bin.mkdir()
    fake = nm_bin / 'no-mistakes'
    fake.write_text('#!' + python + '\n' + """import os, pathlib, sqlite3, sys
folder = pathlib.Path(os.environ['CASE_FOLDER']); args = sys.argv[1:]
fresh = args[:1] == ['rerun'] or (args[:2] == ['axi', 'run'] and any(
    a in ('--intent', '--intent-file') or a.startswith(('--intent=', '--intent-file=')) for a in args[2:]))
with sqlite3.connect(folder / 'state.sqlite') as db:
    active = db.execute("SELECT count(*) FROM runs WHERE status = 'running'").fetchone()[0]
    if fresh:
        db.execute("INSERT INTO runs (id, status) VALUES (?, 'running')", (os.environ['CASE_NAME'],))
if args[:2] == ['axi', 'run'] and not fresh and not active:
    print('error: --intent or --intent-file is required to start a run'); sys.exit(2)
with (folder / 'order').open('a') as out: out.write(os.environ['CASE_NAME'] + '\\n')
""")
    fake.chmod(0o700)
    intent = root / 'intent.txt'
    intent.write_text('goal\n')
    measured_run = [str(proxy), str(repo / 'bin/fm-duration.py'), 'run', '--pipeline-priority', 'machinery', 'no-mistakes.p6', '--']
    mem_guard = ['bash', str(repo / 'bin/fm-mem-guard.sh'), 'run', '--']
    fresh_shapes = {
        'intent': ['no-mistakes', 'axi', 'run', '--intent', 'goal'],
        'intent-equals': ['no-mistakes', 'axi', 'run', '--intent=goal'],
        'intent-file': ['no-mistakes', 'axi', 'run', '--intent-file', str(intent)],
        'intent-file-equals': ['no-mistakes', 'axi', 'run', '--intent-file=' + str(intent)],
        'intent-stdin': ['no-mistakes', 'axi', 'run', '--intent', '-'],
        'reordered': ['no-mistakes', 'axi', 'run', '--verification-plan', str(intent), '--intent', 'goal'],
        'absolute': [str(fake), 'axi', 'run', '--intent', 'goal'],
        'env-wrapped': ['env', 'A=B', 'no-mistakes', 'axi', 'run', '--intent', 'goal'],
        'shell-string': ['sh', '-c', 'no-mistakes axi run --intent goal'],
        'rerun': ['no-mistakes', 'rerun'],
        # PR 366's recorded fresh start (nm-r2-1.log): fm-duration around env around fm-mem-guard.sh run.
        'pr-366': ['env', 'FM_HOME=HOME_PLACEHOLDER'] + mem_guard[1:] + ['no-mistakes', 'axi', 'run', '--intent-file', str(intent),
                                                                     '--verification-plan', str(intent)],
    }
    not_starts = {
        'reattach': (['no-mistakes', 'axi', 'run'], 0, True),
        'reattach-wait': (['no-mistakes', 'axi', 'run', '--wait', '1m'], 0, True),
        'respond': (['no-mistakes', 'axi', 'respond', '--action', 'approve'], 0, True),
        'status': (['no-mistakes', 'axi', 'status'], 0, True),
        'no-intent-no-run': (['no-mistakes', 'axi', 'run'], 2, False),
        'other-command': (['true'], 0, True),
    }
    for route_name, route in (('measured', measured_run), ('mem-guard', mem_guard)):
        for name, shape in list(fresh_shapes.items()) + [(n, v[0]) for n, v in not_starts.items()]:
            folder, db, env = case('p6-%s-%s' % (route_name, name), cores=3)
            env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], CASE_NAME=name, FM_DURATION_FILE='off')
            shape = [part.replace('HOME_PLACEHOLDER', str(folder / 'fmhome')) for part in shape]
            code, active = (0, False) if name in fresh_shapes else not_starts[name][1:]
            if active:
                change(db, "INSERT INTO runs (id, status) VALUES ('existing', 'running')")
                change(db, "UPDATE runs SET ci_ready_at = 1 WHERE id = 'existing'")  # active but not counted
            child = launch(route + shape, dict(env, CASE_STDIN='goal'), folder / 'p6')
            finish(child, code)
            text = (folder / 'p6.stderr').read_text() + (folder / 'p6.stdout').read_text()
            admitted = text.count('pipeline-start admitted')
            assert admitted == (1 if name in fresh_shapes else 0), (route_name, name, admitted, text)
            if name == 'no-intent-no-run':
                assert '--intent or --intent-file is required to start a run' in text, text
            with sqlite3.connect(db) as connection:
                new_rows = connection.execute("SELECT count(*) FROM runs WHERE id = ?", (name,)).fetchone()[0]
            assert new_rows == (1 if name in fresh_shapes else 0), (route_name, name)
            assert not list((folder / 'pool').glob('pipeline-waiter-*.lock')), (route_name, name)
    # One queue in class order across routes: a fresh start through fm-mem-guard.sh run (class other)
    # queued first still follows a machinery start through fm-duration.py run.
    folder, db, env = case('p6-order', cores=3, running=1)
    env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off')
    first = launch(mem_guard + fresh_shapes['intent'], dict(env, CASE_NAME='mem-guard-other'), folder / 'first')
    pending(folder, 1)
    second = launch(measured_run + fresh_shapes['intent'], dict(env, CASE_NAME='measured-machinery'), folder / 'second')
    pending(folder, 2)
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    finish(second)
    assert (folder / 'order').read_text().splitlines() == ['measured-machinery'] and first.poll() is None
    change(db, "UPDATE runs SET status='completed' WHERE id='measured-machinery'")
    finish(first)
    assert (folder / 'order').read_text().splitlines() == ['measured-machinery', 'mem-guard-other']

    # The launch gate: the agent launcher's final exec. It maps its directory to one run, passes
    # every other step through, and before a CI fix agent starts it queues in class order, decides
    # with the same owner for one more active run, publishes the run's reservation under the start
    # lock, then starts the agent as its child.
    agent = root / 'agent.py'
    agent.write_text("""import json, os, pathlib, signal, sys, time
folder, run = pathlib.Path(os.environ['CASE_FOLDER']), sys.argv[1]
mode = os.environ.get('CASE_AGENT', 'wait')
(folder / (run + '.agent')).write_text(json.dumps(dict(pid=os.getpid(), pgid=os.getpgid(0), started_ns=time.time_ns(),
    cwd=os.getcwd(), argv=sys.argv[2:], stdin=sys.stdin.read() if mode != 'wait' else '')))
if mode == 'trap':
    signal.signal(signal.SIGTERM, lambda *a: (folder / (run + '.got-term')).touch() or sys.exit(0))
if mode.startswith('exit-'): sys.exit(int(mode[5:]))
if mode == 'self-term': os.kill(os.getpid(), signal.SIGTERM)
while not (folder / (run + '.release')).exists(): time.sleep(0.025)
""")

    def gate_case(name, available=40 * GIB, runs=(('x', 'ci', 'running', None),), timeout='240m', ci_ms=(60000,)):
        folder, db, env = case(name, measured=True, available=available)
        home = folder / 'home'
        (home / '.no-mistakes').mkdir(parents=True)
        if timeout is not None:
            (home / '.no-mistakes' / 'config.yaml').write_text('agent: [claude]\nagent_timeout: "%s"\n' % timeout)
        with sqlite3.connect(db) as connection:
            connection.execute('CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, purpose TEXT, duration_ms INTEGER, exit_status TEXT)')
            connection.executemany('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)',
                                   [('i%d' % i, 'old', 'ci', 'ci', ms, 'ok') for i, ms in enumerate(ci_ms)] +
                                   # A refused or timed-out invocation is recorded too, and never counts toward the bound.
                                   [('refused', 'old', 'ci', 'ci', 10 ** 9, 'error'), ('review', 'old', 'review', 'review', 10 ** 9, 'ok')])
        for run, step, status, pid in runs:
            (folder / ('wt-' + run)).mkdir()
            change(db, "INSERT INTO runs (id, status, repo_id, worktree_dir, branch) VALUES (?, 'running', 'repo', ?, ?)",
                   (run, str(folder / ('wt-' + run)), 'fm/' + run))
            if step:
                change(db, 'INSERT INTO step_results (id, run_id, step_name, step_order, status, agent_pid) VALUES (?, ?, ?, 1, ?, ?)',
                       (run + '-s', run, step, status, pid))
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

    # First proof: one mapped run is gated and admitted; an unmapped, ambiguous or unreadable mapping refuses.
    folder, db, env = gate_case('gate-map')
    child, log = gate(folder, env, 'x', mode='exit-0', stdin=b'prompt text')
    finish(child)
    text = log.with_suffix('.stderr').read_text()
    seen = json.loads((folder / 'x.agent').read_text())
    assert 'launch-gate run=x branch=fm/x step=ci:running' in text and 'launch-gate admitted: ' in text, text
    assert seen['stdin'] == 'prompt text' and seen['argv'] == ['-p', '--flag'] and seen['cwd'] == os.path.realpath(folder / 'wt-x'), seen
    (folder / 'elsewhere').mkdir()
    child, log = gate(folder, env, 'nowhere', cwd=folder / 'elsewhere', log='unmapped')
    finish(child, 75)
    assert not (folder / 'nowhere.agent').exists() and 'launch-gate refused: unmapped worktree' in log.with_suffix('.stderr').read_text()
    no_retry_phrase(log.with_suffix('.stderr').read_text())
    change(db, "INSERT INTO runs (id, status, repo_id, worktree_dir) VALUES ('twin', 'completed', 'repo', ?)", (str(folder / 'wt-x'),))
    child, log = gate(folder, env, 'x', log='ambiguous')
    finish(child, 75)
    assert 'launch-gate refused: ambiguous worktree' in log.with_suffix('.stderr').read_text()
    child, log = gate(folder, dict(env, CASE_DB=str(folder / 'missing.sqlite')), 'x', log='unreadable')
    finish(child, 75)
    assert 'launch-gate refused: run database unreadable' in log.with_suffix('.stderr').read_text()
    queue = wakes(folder)
    assert all(cause in queue for cause in ('unmapped worktree', 'ambiguous worktree', 'run database unreadable')), queue
    assert 'next action: ' in queue, queue

    # Scope: another step of a counted run passes through at once, even on a full host.
    folder, db, env = gate_case('gate-scope', available=GIB, runs=(('x', 'review', 'fixing', 77),))
    child, log = gate(folder, env, 'x', mode='exit-0')
    finish(child)
    assert 'admitted' not in log.with_suffix('.stderr').read_text() and (folder / 'x.agent').exists()

    # Exit codes and signal deaths pass through; a signal sent to the gate reaches the agent.
    for mode, code in (('exit-0', 0), ('exit-1', 1), ('exit-75', 75), ('self-term', -signal.SIGTERM)):
        folder, db, env = gate_case('gate-exit-' + mode)
        child, log = gate(folder, env, 'x', mode=mode)
        finish(child, code)
        assert not live_entries(folder, 'launch-*.lock')
    folder, db, env = gate_case('gate-forward')
    child, log = gate(folder, env, 'x', mode='trap')
    wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
    time.sleep(0.2)
    os.kill(child.pid, signal.SIGTERM)
    finish(child, 0)
    assert (folder / 'x.got-term').exists()
    # An agent that cannot be launched gives the shell's statuses unchanged and keeps no reservation.
    for missing, code in ((str(folder / 'no-such-agent'), 127), (str(folder / 'wt-x'), 126)):
        out = subprocess.run(['bash', str(repo / 'bin/fm-cpu-pass.sh'), 'launch-gate', '--', missing], env=env, cwd=str(folder / 'wt-x'),
                             stdin=subprocess.DEVNULL, capture_output=True, text=True)
        assert out.returncode == code and not live_entries(folder, 'launch-*.lock'), (out.returncode, out.stderr)

    # Admission-to-launch order: the reservation is published under the start lock before the agent
    # starts and the lock is released after both; the agent's start waits on no observation.
    folder, db, env = gate_case('gate-order')
    child, log = gate(folder, env, 'x')
    wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
    import re
    stamps = dict(re.findall(r'(admitted_ns|published_ns|agent_started_ns|unlocked_ns)=(\d+)', log.with_suffix('.stderr').read_text()))
    started = json.loads((folder / 'x.agent').read_text())['started_ns']
    assert int(stamps['admitted_ns']) <= int(stamps['published_ns']) <= int(stamps['agent_started_ns']) <= int(stamps['unlocked_ns']), stamps
    assert int(stamps['published_ns']) <= started, (stamps, started)
    assert live_entries(folder, 'launch-*.lock') == 1
    (folder / 'x.release').touch()
    finish(child)
    assert live_entries(folder, 'launch-*.lock') == 0

    # Simultaneous resumes with a lagging reading: room for exactly two (S = 8, R = 3, 12 GiB).
    # The first agent is never visible; the second is decided counting it at R, the third waits
    # and starts by itself once the first exits.
    folder, db, env = gate_case('gate-three', available=12 * GIB, runs=[(r, 'ci', 'running', None) for r in ('a', 'b', 'c')])
    gates = {}
    for run in ('a', 'b'):
        gates[run] = gate(folder, env, run)[0]
        wait_for(lambda: (folder / (run + '.agent')).exists(), run + ' admitted')
    gates['c'] = gate(folder, env, 'c')[0]
    wait_for(lambda: 'held for capacity' in wakes(folder), 'third decided')
    assert not (folder / 'c.agent').exists()
    text_b = (folder / 'gate-b.stderr').read_text()
    assert 'a:launched:%d:unseen' % (3 * GIB) in text_b and 'projected=%d ' % (11 * GIB) in text_b, text_b
    wait_for(lambda: 'launch-gate waiting: counted=3 projected=%d ' % (14 * GIB) in (folder / 'gate-c.stderr').read_text() or
             'held for capacity' in wakes(folder), 'third holds')
    assert 'run c (fm/c) held for capacity' in wakes(folder), wakes(folder)
    (folder / 'a.release').touch()
    finish(gates['a'])
    wait_for(lambda: (folder / 'c.agent').exists(), 'third starts by itself')
    wait_for(lambda: 'run c (fm/c) admitted after' in wakes(folder), 'admission after a hold is recorded')
    for run in ('b', 'c'):
        (folder / (run + '.release')).touch()
        finish(gates[run])

    # After first appearance: a visible agent at 0.2 GiB still reserves A = 1 GiB. A later start that
    # fits on startup memory alone (8.2 of 8.7 GiB) waits (9 > 8.7) and is admitted once the agent exits.
    folder, db, env = gate_case('gate-after-visible', available=int(8.5 * GIB), runs=[('x', 'ci', 'running', None)])
    child, log = gate(folder, env, 'x')
    wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
    facts(folder, available=int(8.5 * GIB), runs=[('repo', 'x', GIB // 5)])
    later = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later')
    wait_for(lambda: 'waiting: counted=1 projected=%d ' % (9 * GIB) in (folder / 'later.stderr').read_text(), 'A, not startup memory')
    assert 'x:launched:%d' % GIB in (folder / 'later.stderr').read_text()
    (folder / 'x.release').touch()
    finish(child)
    facts(folder, available=int(8.5 * GIB))
    finish(later)

    # Dead holders and retries: an unlocked launch record reserves nothing and is removed; two live
    # attempts of one run hold one reservation.
    folder, db, env = gate_case('gate-holders', available=12 * GIB, runs=[('x', 'ci', 'running', None)])
    (folder / 'pool').mkdir(exist_ok=True)
    (folder / 'pool' / 'launch-dead.lock').write_text(json.dumps(dict(run='x', repo='repo', pid=999999, started_ns=1)))
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm1')], env, folder / 'dead'))
    assert 'holding_only=[x:ci-waiting:0:unseen]' in (folder / 'dead.stderr').read_text() and not (folder / 'pool/launch-dead.lock').exists()
    first, _ = gate(folder, env, 'x', log='attempt-1')
    wait_for(lambda: live_entries(folder, 'launch-*.lock') == 1, 'first attempt reserved')
    (folder / 'x.agent').unlink(missing_ok=True)
    second, _ = gate(folder, env, 'x', log='attempt-2')
    wait_for(lambda: live_entries(folder, 'launch-*.lock') == 2, 'second attempt reserved')
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm2')], env, folder / 'two'))
    assert (folder / 'two.stderr').read_text().count('x:launched:') == 1, (folder / 'two.stderr').read_text()
    (folder / 'x.release').touch()
    finish(first); finish(second)

    # Hold bound: budget 3 s minus the CI-fix p99 of 1 s holds 2 s, then refuses visibly; the agent never starts.
    folder, db, env = gate_case('gate-bound', available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)],
                                timeout='3s', ci_ms=(500, 1000))
    began = time.monotonic()
    child, log = gate(folder, env, 'x')
    finish(child, 75)
    text = log.with_suffix('.stderr').read_text()
    assert time.monotonic() - began >= 2 and not (folder / 'x.agent').exists(), text
    assert 'launch-gate refused: hold bound reached: run x; hold_bound=2s budget=3s ci_fix_p99=1s; held ' in text, text
    assert 'next action: ' in text and 'auto_fix.ci' in text and 'ask-user decision' in text, text
    no_retry_phrase(text)
    assert 'refused: hold bound reached' in wakes(folder) and 'held for capacity' in wakes(folder)
    assert not live_entries(folder) and not live_entries(folder, 'launch-*.lock')
    # No positive bound (budget not above p99, or no config) refuses at once when nothing fits.
    for timeout in ('1s', None):
        folder, db, env = gate_case('gate-nobound-%s' % timeout, available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)],
                                    timeout=timeout, ci_ms=(2000000,))
        child, log = gate(folder, env, 'x')
        finish(child, 75)
        assert 'hold_bound=0s' in log.with_suffix('.stderr').read_text(), log.with_suffix('.stderr').read_text()

    # Cleanup: a group kill mid-hold and mid-run, the gate alone killed mid-run, and an internal gate
    # error after the admit each leave no agent, no live reservation and a free start lock.
    folder, db, env = gate_case('gate-kill-hold', available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
    child, log = gate(folder, env, 'x')
    wait_for(lambda: live_entries(folder) == 1, 'held')
    os.killpg(child.pid, signal.SIGKILL)
    finish(child, -signal.SIGKILL)
    assert not (folder / 'x.agent').exists() and live_entries(folder) == 0
    for label, kill in (('group', lambda c: os.killpg(c.pid, signal.SIGKILL)), ('gate-only', lambda c: os.kill(c.pid, signal.SIGKILL))):
        folder, db, env = gate_case('gate-kill-' + label)
        child, log = gate(folder, env, 'x')
        wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
        agent_pid = json.loads((folder / 'x.agent').read_text())['pid']
        kill(child)
        finish(child, -signal.SIGKILL)
        wait_for(lambda: not alive(agent_pid), label + ': no agent left')
        assert live_entries(folder, 'launch-*.lock') == 0 and live_entries(folder, 'pipeline-start.lock') == 0
    folder, db, env = gate_case('gate-raise')
    child, log = gate(folder, dict(env, CASE_GATE_RAISE='1'), 'x')
    wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
    agent_pid = json.loads((folder / 'x.agent').read_text())['pid']
    finish(child, 1)
    wait_for(lambda: not alive(agent_pid), 'no agent after an internal error')
    assert live_entries(folder, 'launch-*.lock') == 0

    print(json.dumps(dict(result='pass', spacing=dict(limit=SPACING_LIMIT, burst_gaps=[round(g, 3) for g in burst_gaps], burst_median=round(statistics.median(burst_gaps), 3), injected_gaps=[round(g, 3) for g in injected_gaps], injected_median=round(statistics.median(injected_gaps), 3), injected_rejection=injected_rejection), artifacts=str(root), native_cpu_count=os.cpu_count(), invocations=records)), flush=True)
finally:
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
