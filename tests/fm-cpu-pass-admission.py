#!/usr/bin/env python3
"""Executable fixtures for fm-cpu-pass.test.sh; never use fleet state, load or the live host."""
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import sqlite3
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


def calibrate(folder, peaks=PEAKS, total=128 * GIB, host=None, live=(), extra=None):
    """The root home's recorded calibration: one no-mistakes run per peak, 2 readings each.

    live names runs (repo_id NULL) whose young, low peak the probe has folded in already;
    extra maps more runs (repo_id NULL) to their recorded peak in bytes.
    """
    state = folder / 'fmhome' / 'state'
    state.mkdir(parents=True, exist_ok=True)
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
        connection.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER, repo_id TEXT)')
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


SPACING_LIMIT = 5.0  # Allow scheduling delays while still detecting artificial spacing.


def grant_gaps(folder, names):
    """Seconds between consecutive grants, from the nanosecond times the fake starts touched."""
    stamps = sorted((folder / (name + '.started')).stat().st_mtime_ns for name in names)
    return [(later - earlier) / 1e9 for earlier, later in zip(stamps, stamps[1:])]


def assert_no_spacing(folder, names):
    """Reject artificial spacing: ready starts follow each other by the registration handshake only."""
    gaps = grant_gaps(folder, names)
    assert max(gaps) < SPACING_LIMIT, ('artificial wait between grants', [round(gap, 2) for gap in gaps])
    return gaps


def pending(folder, count):
    wait_for(lambda: len(list((folder / 'pool').glob('pipeline-waiter-*.lock'))) == count,
             str(count) + ' registered waiters')


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
    # One qualifying recorded run, a record for another host, and unreadable text all
    # fall back; none refuses and none reads as an empty host.
    for name, record in (('one-run', lambda f: calibrate(f, peaks=[3.0])), ('other-host', lambda f: calibrate(f, host='other-host')),
                         ('other-ram', lambda f: calibrate(f, total=64 * GIB)),
                         ('garbage', lambda f: (f / 'fmhome/state').mkdir(parents=True, exist_ok=True) or (f / 'fmhome/state/.memory-calibration.json').write_text('{')),
                         ('walk-fails', lambda f: calibrate(f) or (f / 'fmhome/.fm-secondmate-parent').write_text('garbage\n'))):
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
    assert 'admitted: counted=6 need=' in log.read_text() and 'reservation=%d slack=%d runs_measured=13' % (3 * GIB, 8 * GIB) in log.read_text(), log.read_text()

    # A worker has FM_DURATION_HOME and no FM_HOME; it still finds the root home's record.
    folder, db, env = case('worker-env', running=6, measured=True)
    env.pop('FM_HOME')
    env['FM_DURATION_HOME'] = str(folder / 'fmhome')
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'worker.marker')], env, folder / 'worker'))
    assert 'admitted: counted=6 need=' in (folder / 'worker.stderr').read_text(), (folder / 'worker.stderr').read_text()

    # A running run's peak so far is not a per-run peak: six young runs at 0.2 GiB would pull
    # the 75th percentile down to 1 GiB, but R stays 3 GiB from the 13 finished runs.
    folder, db, env = case('live-runs', running=6, measured=True)
    calibrate(folder, live=['baseline-%d' % i for i in range(6)])
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'live.marker')], env, folder / 'live'))
    text = (folder / 'live.stderr').read_text()
    assert 'admitted: counted=6 need=%d ' % (7 * 3 * GIB + 8 * GIB) in text and 'reservation=%d slack=%d runs_measured=13 ' % (3 * GIB, 8 * GIB) in text, text

    # S takes every qualifying peak: a CI-ready running run holds the largest (20 GiB), and
    # a peak so far can only be too low. R ranks that CI-ready run (14 peaks: 4 GiB) but
    # leaves out a parked run short of CI-ready (12 GiB), which would make the 12th rank 5.8 GiB.
    folder, db, env = case('ci-ready-peak', measured=True)
    calibrate(folder, extra={'ci-done': 20 * GIB, 'parked': 12 * GIB})
    change(db, "INSERT INTO runs (id, status, ci_ready_at) VALUES ('ci-done', 'running', 1)")
    change(db, "INSERT INTO runs (id, status, awaiting_agent_since) VALUES ('parked', 'running', 1)")
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'ci.marker')], env, folder / 'ci'))
    text = (folder / 'ci.stderr').read_text()
    assert 'admitted: counted=0 need=%d ' % (24 * GIB) in text and 'reservation=%d slack=%d runs_measured=14 ' % (4 * GIB, 20 * GIB) in text, text

    # One-start minimum: with nothing counted, one start is admitted although R + S = 11 GiB
    # exceeds the 10 GiB budget, unless the backstop reports an overload.
    folder, db, env = case('floor', measured=True, available=10 * GIB)
    facts(folder, available=10 * GIB, pressure=2)
    marker = folder / 'floor.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'floor')
    pending(folder, 1)
    wait_for(lambda: 'waiting: overload: memory: native memory pressure level 2' in (folder / 'floor.stderr').read_text(), 'floor still pauses on overload')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    facts(folder, available=10 * GIB)
    finish(child)
    assert marker.exists() and 'admitted: counted=0 need=%d budget=%d' % (11 * GIB, 10 * GIB) in (folder / 'floor.stderr').read_text()

    # Measured mode. R = 3 GiB (75th percentile of the 13 recorded peaks) and S = 8 GiB
    # (the largest); the task:crewmate record is not a no-mistakes run and is ignored.
    # Budget B = available + resident memory of counted runs; admit while (n+1) R + S <= B.
    # 40 GiB admits n = 0..9 (3 x 10 + 8 = 38) and refuses n = 10 (41).
    folder, db, env = case('burst', cores=3, measured=True, available=40 * GIB)
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
    assert any('need=%d budget=%d' % (3 * GIB * 10 + 8 * GIB, 40 * GIB) in (folder / (name + '.stderr')).read_text() for name in names[:10])
    # No artificial wait: the grants follow each other by the registration handshake alone.
    burst_gaps = assert_no_spacing(folder, names[:10])
    # The eleventh needs 41 GiB of 40 and waits; releasing one run lets it start.
    clients[names[10]] = launch(cli + ['pipeline-start', '--', python, str(worker), str(folder), names[10]], env, folder / names[10])
    pending(folder, 1)
    wait_for(lambda: 'waiting: overload' not in (folder / (names[10] + '.stderr')).read_text() and
             'waiting: counted=10 need=%d budget=%d' % (3 * GIB * 11 + 8 * GIB, 40 * GIB) in (folder / (names[10] + '.stderr')).read_text(),
             'eleventh start waits for reservations')
    assert not (folder / (names[10] + '.started')).exists()
    (folder / 'burst-0.release').touch()
    finish(clients['burst-0'])
    wait_for(lambda: (folder / (names[10] + '.started')).exists(), 'eleventh grant after a release')
    for name in names[1:]:
        (folder / (name + '.release')).touch()
        finish(clients[name])

    # The check must reject spacing. The same burst shape with a 5-second delay injected before
    # each fake start registers (the admission lock is held across it) passes the earlier
    # assertions but fails assert_no_spacing; the undelayed burst above passed it.
    folder, db, env = case('spacing-injected', cores=3, measured=True, available=40 * GIB)
    env['CASE_LAUNCH_DELAY'] = '5'
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
    else:
        raise AssertionError('the injected 5-second per-launch delay was not rejected: %r' % grant_gaps(folder, names))
    for name in names:
        (folder / (name + '.release')).touch()
        finish(clients[name])

    # Load5 alone decides nothing: the same full reservations with idle load admit nothing
    # extra, and fitting reservations under a load of 500 are admitted.
    folder, db, env = case('load-both-ways', cores=18, running=1, measured=True, available=13 * GIB, load=0)
    # one counted run: need = 2 x 3 + 8 = 14 GiB > 13 GiB
    marker = folder / 'idle-full.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'idle-full')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=1 need=%d budget=%d' % (14 * GIB, 13 * GIB) in (folder / 'idle-full.stderr').read_text(), 'idle load, full reservations')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    # The counted run's own resident memory is part of B: 1 GiB held makes 14 of 14.
    facts(folder, available=13 * GIB, runs=[(None, 'baseline-0', GIB)])
    finish(child)
    assert marker.exists() and 'admitted: counted=1 need=%d budget=%d' % (14 * GIB, 14 * GIB) in (folder / 'idle-full.stderr').read_text()
    # A counted run holding more than R adds only R to B: its excess is not free memory.
    # 7 GiB held, 10 GiB available: B = 10 + 3 = 13 GiB < need 14 GiB, so the start waits.
    folder, db, env = case('over-reservation', cores=18, running=1, measured=True, available=10 * GIB)
    facts(folder, available=10 * GIB, runs=[(None, 'baseline-0', 7 * GIB)])
    marker = folder / 'over.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'over')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=1 need=%d budget=%d' % (14 * GIB, 13 * GIB) in (folder / 'over.stderr').read_text(), 'excess over R is not credited')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    facts(folder, available=11 * GIB, runs=[(None, 'baseline-0', 7 * GIB)])
    finish(child)
    assert marker.exists() and 'admitted: counted=1 need=%d budget=%d' % (14 * GIB, 14 * GIB) in (folder / 'over.stderr').read_text()
    folder, db, env = case('busy-but-fits', cores=18, running=0, measured=True, available=40 * GIB, load=500)
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'busy.marker')], env, folder / 'busy'))
    assert (folder / 'busy.marker').exists()

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
    folder, db, env = case('test-peak', measured=True, running=4, available=14 * GIB, load=0)
    facts(folder, available=14 * GIB, runs=[(None, 'baseline-%d' % i, 2 * GIB) for i in range(4)])
    # B = 14 + 8 = 22 GiB; need = 5 x 3 + 8 = 23 GiB. A fifth start waits; one run finishing frees 3 GiB.
    marker = folder / 'peak.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'peak')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=4 need=%d budget=%d' % (23 * GIB, 22 * GIB) in (folder / 'peak.stderr').read_text(), 'test peak pauses')
    time.sleep(0.6)
    assert not marker.exists()
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    facts(folder, available=14 * GIB, runs=[(None, 'baseline-%d' % i, 2 * GIB) for i in range(1, 4)])
    finish(child)
    assert marker.exists()

    # Class order still decides who gets scarce capacity (exactly one start fits at a time).
    folder, db, env = case('measured-priority', cores=3, measured=True, running=1, available=12 * GIB)
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
    print(json.dumps(dict(result='pass', spacing=dict(limit=SPACING_LIMIT, burst_gaps=[round(g, 3) for g in burst_gaps], injected_rejection=injected_rejection), artifacts=str(root), native_cpu_count=os.cpu_count(), invocations=records)), flush=True)
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
