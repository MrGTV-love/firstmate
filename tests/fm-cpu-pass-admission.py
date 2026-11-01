#!/usr/bin/env python3
"""Executable fixtures for fm-cpu-pass.test.sh; never use fleet state or load."""
import hashlib
import json
import os
from pathlib import Path
import signal
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
    import pathlib, sqlite3
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


def case(name, cores=18, running=0, load=0):
    folder = root / name
    folder.mkdir()
    db = folder / 'state.sqlite'
    with sqlite3.connect(db) as connection:
        connection.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER)')
        connection.executemany('INSERT INTO runs (id, status) VALUES (?, ?)', [('baseline-' + str(i), 'running') for i in range(running)])
    load_file = folder / 'load.json'
    write_json(load_file, [0, load, 0])
    env = dict(base, CASE_LOAD=str(load_file), CASE_DB=str(db), CASE_FOLDER=str(folder), FM_CPU_POOL_DIR=str(folder / 'pool'),
               CASE_CORES=str(cores))
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
worker.write_text('''import pathlib, sqlite3, sys, time
folder, name = pathlib.Path(sys.argv[1]), sys.argv[2]
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

    # Count == limit blocks at the exact load boundary. Releasing count while
    # load is above the boundary still blocks; only both observations grant.
    folder, db, env = case('thresholds', running=6, load=36)
    cores = 18
    marker = folder / 'started'
    command = cli + ['pipeline-start', '--', python, '-c',
                     'import pathlib,sys; pathlib.Path(sys.argv[1]).touch()', str(marker)]
    before_hash = hashlib.sha256(db.read_bytes()).hexdigest()
    child = launch(command, env, folder / 'start')
    pending(folder, 1)
    wait_for(lambda: (folder / 'start.stderr').stat().st_size > 0, 'blocked admission notice')
    assert not marker.exists() and hashlib.sha256(db.read_bytes()).hexdigest() == before_hash
    write_json(Path(env['CASE_LOAD']), [0, cores * 2 + 0.1, 0])
    change(db, "UPDATE runs SET status='completed'")
    # Wait for a native observation rather than a timer standing for success.
    time.sleep(0.6)
    assert not marker.exists()
    write_json(Path(env['CASE_LOAD']), [0, cores * 2, 0])
    finish(child)
    assert marker.exists()

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
    write_json(Path(env['CASE_LOAD']), [0, -1, 0])
    child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'bad-load')], env, folder / 'bad-load')
    finish(child, 125)
    assert not (folder / 'bad-load').exists()

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
    print(json.dumps(dict(result='pass', artifacts=str(root), native_cpu_count=os.cpu_count(), invocations=records)), flush=True)
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
