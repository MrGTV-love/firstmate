#!/usr/bin/env python3
"""Live driver for fm-pipeline-start-admission (Test phase).

Drives the REAL bin/fm-cpu-pass.sh and bin/fm-duration.py from the run worktree.
Isolation: every case has its own disposable HOME, so the product's fixed
~/.no-mistakes/state.sqlite and default ~/.cache/fm-cpu-pool resolve inside the
lab. The database file is the real no-mistakes schema in WAL mode, created by the
real binary (`NM_HOME=<lab> no-mistakes stats`), never the operator's database.
`no-mistakes` itself is a lab stub: this gate phase must not start real pipelines.
Cases marked inject=True patch only os.cpu_count/os.getloadavg, the native
observation boundary, because the host cannot be given 18 cores or forced load.
"""
import json, os, re, shutil, signal, sqlite3, stat, subprocess, sys, time
from pathlib import Path

REPO = Path(sys.argv[1]).resolve()
LAB = Path(sys.argv[2]).resolve()
EVID = Path(sys.argv[3]).resolve()
ONLY = set(sys.argv[4:])
PY = sys.executable
TEMPLATE = LAB / 'home/.no-mistakes/state.sqlite'
CASES = LAB / 'cases'
CASES.mkdir(exist_ok=True)
children, results = [], []
LOG = open(EVID / 'live-admission.log', 'a')


def say(*parts):
    line = ' '.join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + '\n'); LOG.flush()


_c = sqlite3.connect(TEMPLATE, isolation_level=None)
_c.execute("INSERT OR IGNORE INTO repos (id, working_path, upstream_url, created_at) VALUES ('r','/lab','u',1)")
_c.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall()
_c.close()

STUB = r'''#!%s
"""Lab stand-in for the no-mistakes client. Registers one real-schema run row."""
import os, pathlib, sqlite3, sys, time
home = pathlib.Path(os.environ['HOME'])
case = pathlib.Path(os.environ['CASE'])
args = sys.argv[1:]
(case / 'calls.log').open('a').write(' '.join(args) + '\n')
name = os.environ.get('STUB_NAME') or 'n%%d' %% os.getpid()
fresh = args[:1] == ['rerun'] or '--intent' in ' '.join(args) or '--intent-file' in ' '.join(args)
if fresh and os.environ.get('STUB_REGISTER', '1') == '1':
    time.sleep(float(os.environ.get('STUB_REGISTER_DELAY', '0')))
    with sqlite3.connect(home / '.no-mistakes/state.sqlite', timeout=15) as db:
        db.execute("INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at) VALUES (?, 'r', 'b', 'h', 'b', 'running', 1, 1)", (name,))
(case / (name + '.started')).write_text(str(time.time()))
while (case / 'hold').exists() and not (case / (name + '.release')).exists():
    time.sleep(0.05)
sleep = float(os.environ.get('STUB_SLEEP', '0'))
if sleep: time.sleep(sleep)
(case / (name + '.done')).write_text(str(time.time()))
''' % PY


def scenario(name):
    def wrap(fn):
        fn.scenario = name
        return fn
    return wrap


class Case:
    def __init__(self, name, cores=None, load=None, counted=0):
        self.dir = CASES / name
        if self.dir.exists(): shutil.rmtree(self.dir)
        self.dir.mkdir(parents=True)
        self.home = self.dir / 'home'
        (self.home / '.no-mistakes').mkdir(parents=True)
        shutil.copy(TEMPLATE, self.db_path())
        # Stand in for a live daemon's open connection: real WAL side files exist.
        # live-real-daemon*.log drive the real daemon and the no-side-file state.
        self.keeper = sqlite3.connect(self.db_path(), isolation_level=None)
        self.keeper.execute('SELECT count(*) FROM runs').fetchall()
        self.shim = self.dir / 'shim'
        self.shim.mkdir()
        self.injected = cores is not None or load is not None
        self.loadfile = self.dir / 'load.json'
        if self.injected:
            self.loadfile.write_text(json.dumps([0, 0 if load is None else load, 0]))
            proxy = self.shim / 'python3'
            proxy.write_text('#!%s\n' % PY + '''import json, os, runpy, sys
real = sys.executable
if len(sys.argv) > 1 and os.path.basename(sys.argv[1]) in ('fm-cpu-pass.py', 'fm-duration.py'):
    if os.environ.get('CASE_CORES'): os.cpu_count = lambda: int(os.environ['CASE_CORES'])
    os.getloadavg = lambda: tuple(json.load(open(os.environ['CASE_LOAD'])))
    sys.executable = __file__
    sys.argv = sys.argv[1:]
    runpy.run_path(sys.argv[0], run_name='__main__')
else:
    os.execv(real, [real] + sys.argv[1:])
''')
            proxy.chmod(0o755)
        stub = self.shim / 'no-mistakes'
        stub.write_text(STUB)
        stub.chmod(0o755)
        self.env = {
            'HOME': str(self.home), 'CASE': str(self.dir), 'TMPDIR': os.environ.get('TMPDIR', '/tmp'),
            'PATH': os.pathsep.join([str(self.shim), str(Path(PY).parent), '/usr/bin', '/bin']),
            'FM_DURATION_FILE': str(self.dir / 'durations.jsonl'),
        }
        if cores is not None: self.env['CASE_CORES'] = str(cores)
        if self.injected: self.env['CASE_LOAD'] = str(self.loadfile)
        self.pool = self.home / '.cache/fm-cpu-pool'
        self.add(counted)

    def db_path(self):
        return self.home / '.no-mistakes/state.sqlite'

    def sql(self, statement, params=()):
        with sqlite3.connect(self.db_path(), timeout=15) as db:
            return db.execute(statement, params).fetchall()

    def add(self, count, **cols):
        for _ in range(count):
            self.n = getattr(self, 'n', 0) + 1
            self.row('base%d' % self.n, 'running', **cols)

    def row(self, rid, status='running', ci_ready_at=None, awaiting_agent_since=None):
        self.sql("INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, ci_ready_at, awaiting_agent_since, created_at, updated_at) VALUES (?, 'r','b','h','b',?,?,?,1,1)",
                 (rid, status, ci_ready_at, awaiting_agent_since))

    def counted(self):
        return self.sql("SELECT count(*) FROM runs WHERE status='running' AND ci_ready_at IS NULL AND awaiting_agent_since IS NULL")[0][0]

    def set_load(self, value):
        tmp = self.loadfile.with_suffix('.new')
        tmp.write_text(json.dumps([0, value, 0]))
        tmp.replace(self.loadfile)

    def spawn(self, label, argv, **extra):
        env = dict(self.env, **{k: str(v) for k, v in extra.items()})
        out = open(self.dir / (label + '.stdout'), 'w')
        err = open(self.dir / (label + '.stderr'), 'w')
        child = subprocess.Popen(argv, env=env, stdout=out, stderr=err, start_new_session=True, cwd=str(self.dir))
        out.close(); err.close()
        children.append(child)
        say('  $', label, ':', ' '.join(map(str, argv)))
        return child

    def start(self, label, command, priority=None, **extra):
        argv = ['bash', str(REPO / 'bin/fm-cpu-pass.sh'), 'pipeline-start']
        if priority: argv += ['--priority', priority]
        return self.spawn(label, argv + ['--'] + command, **extra)

    def err(self, label):
        return (self.dir / (label + '.stderr')).read_text()

    def waiters(self):
        return sorted(p.name for p in self.pool.glob('pipeline-waiter-*.lock'))

    def marker(self, name):
        return self.dir / name

    def status(self):
        return json.loads(subprocess.check_output(['bash', str(REPO / 'bin/fm-cpu-pass.sh'), 'status', '--json'], env=self.env, text=True))


def wait_for(predicate, what, seconds=30):
    until = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() > until:
            raise AssertionError('timed out waiting for: ' + what)
        time.sleep(0.02)


def finish(child, code=0, seconds=60):
    actual = child.wait(timeout=seconds)
    assert actual == code, 'exit %s, wanted %s' % (actual, code)


def killall():
    for child in children:
        if child.poll() is None:
            try: os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            child.wait()
    children.clear()


def slot_fds(pid):
    """External view: lock files the kernel says this process has open."""
    out = subprocess.run(['lsof', '-nP', '-p', str(pid)], capture_output=True, text=True).stdout
    return sorted(re.findall(r'((?:slot-\d+|pipeline-start|pipeline-waiter-\S+)\.lock)', out))


def queued_notice(case, label):
    wait_for(lambda: 'pipeline-start waiting: ' in case.err(label), label + ' waiting notice', 45)
    return [l for l in case.err(label).splitlines() if 'waiting:' in l][-1]


@scenario('native-10core-count-boundary-real-schema')
def native_boundary():
    # No injection at all: real cpu_count, real getloadavg, real daemon schema.
    cores, load5 = os.cpu_count(), os.getloadavg()[1]
    limit = max(1, cores // 3)
    say('  native cores', cores, 'load5', load5, 'ceiling', 2 * cores, 'independent limit', limit)
    assert load5 <= 2 * cores, 'native load5 is above the ceiling now; case cannot show count boundary'
    c = Case('native', counted=limit - 1)
    assert not c.injected
    db_before = c.db_path().read_bytes()
    rows_before = c.sql('SELECT * FROM runs ORDER BY id')
    p = c.start('below', ['touch', str(c.marker('below'))])
    finish(p)
    assert c.marker('below').exists()
    say('  ', c.err('below').strip())
    assert 'admitted: counted=%d limit=%d ' % (limit - 1, limit) in c.err('below')
    assert c.sql('SELECT * FROM runs ORDER BY id') == rows_before and c.db_path().read_bytes() == db_before
    c.add(1)
    p = c.start('at', ['touch', str(c.marker('at'))])
    say('  ', queued_notice(c, 'at'))
    assert 'counted=%d limit=%d ' % (limit, limit) in c.err('at') and not c.marker('at').exists() and p.poll() is None
    # A live daemon-like writer holds an open write transaction in WAL: readers go on.
    writer = sqlite3.connect(c.db_path(), timeout=15, isolation_level=None)
    writer.execute('BEGIN IMMEDIATE')
    writer.execute("UPDATE runs SET updated_at=2 WHERE id='base1'")
    time.sleep(1.2)
    assert p.poll() is None and 'refused' not in c.err('at')
    writer.execute('ROLLBACK'); writer.close()
    c.sql("UPDATE runs SET status='completed' WHERE id='base1'")
    finish(p)
    assert c.marker('at').exists()
    say('  ', c.err('at').strip().splitlines()[-1])
    assert 'admitted: counted=%d limit=%d ' % (limit - 1, limit) in c.err('at')
    assert c.sql('PRAGMA quick_check')[0][0] == 'ok'
    assert (c.home / '.cache/fm-cpu-pool/pipeline-start.lock').exists(), 'default pool dir under HOME used'
    return dict(cores=cores, load5=load5, limit=limit)


@scenario('core-scaling-table')
def scaling():
    table = {}
    for cores, limit in ((1, 1), (2, 1), (3, 1), (5, 1), (6, 2), (9, 3), (10, 3), (11, 3), (12, 4), (18, 6), (19, 6), (36, 12)):
        c = Case('scale-%d' % cores, cores=cores, load=0, counted=limit - 1)
        p = c.start('below', ['touch', str(c.marker('below'))])
        finish(p)
        assert 'limit=%d ' % limit in c.err('below') and c.marker('below').exists()
        c.add(1)
        p = c.start('at', ['touch', str(c.marker('at'))])
        queued_notice(c, 'at')
        assert not c.marker('at').exists() and p.poll() is None
        os.killpg(p.pid, signal.SIGKILL); p.wait()
        table[cores] = limit
    say('  cores->limit', table)
    return table


@scenario('both-thresholds-required-18core')
def thresholds():
    c = Case('thresholds', cores=18, load=36, counted=6)
    p = c.start('s', ['touch', str(c.marker('m'))])
    say('  count=6 load=36:', queued_notice(c, 's'))
    assert not c.marker('m').exists()
    # Count falls, load is over: still queued. Neither constraint alone grants.
    c.set_load(36.01)
    c.sql("UPDATE runs SET status='completed' WHERE id='base6'")
    t0 = time.time()
    while time.time() - t0 < 2.5:
        assert p.poll() is None and not c.marker('m').exists(), 'load above ceiling granted'
        time.sleep(0.1)
    # Load falls, count back at limit: still queued.
    c.sql("UPDATE runs SET status='running' WHERE id='base6'")
    c.set_load(36)
    t0 = time.time()
    while time.time() - t0 < 2.5:
        assert p.poll() is None and not c.marker('m').exists(), 'count at limit granted'
        time.sleep(0.1)
    # Both inside the boundary, on the exact load ceiling: grant.
    c.sql("UPDATE runs SET status='completed' WHERE id='base6'")
    finish(p)
    assert c.marker('m').exists()
    say('  ', c.err('s').strip().splitlines()[-1])
    assert 'admitted: counted=5 limit=6 load5=36.00 ceiling=36' in c.err('s')


@scenario('count-definition-real-schema')
def count_definition():
    c = Case('count', cores=9, load=0)   # limit 3
    # Every excluded state is present many times; none count.
    for i in range(4):
        c.row('ci%d' % i, 'running', ci_ready_at=1)
        c.row('parked%d' % i, 'running', awaiting_agent_since=1)
        c.row('both%d' % i, 'running', ci_ready_at=1, awaiting_agent_since=1)
        for status in ('pending', 'completed', 'failed', 'cancelled'):
            c.row('%s%d' % (status, i), status)
    p = c.start('none-counted', ['touch', str(c.marker('a'))])
    finish(p)
    say('  ', c.err('none-counted').strip())
    assert 'counted=0 limit=3' in c.err('none-counted')
    c.add(3)
    p = c.start('full', ['touch', str(c.marker('b'))])
    say('  ', queued_notice(c, 'full'))
    c.sql("UPDATE runs SET awaiting_agent_since=9 WHERE id=(SELECT id FROM runs WHERE id LIKE 'base%' LIMIT 1)")
    finish(p)   # parking releases
    say('  after park:', c.err('full').strip().splitlines()[-1])
    c.add(1)
    p = c.start('full2', ['touch', str(c.marker('c'))])
    queued_notice(c, 'full2')
    c.sql("UPDATE runs SET ci_ready_at=9 WHERE id=(SELECT id FROM runs WHERE id LIKE 'base%' AND ci_ready_at IS NULL AND awaiting_agent_since IS NULL LIMIT 1)")
    finish(p)   # CI-ready releases
    say('  after ci-ready:', c.err('full2').strip().splitlines()[-1])
    c.add(1)
    p = c.start('full3', ['touch', str(c.marker('d'))])
    queued_notice(c, 'full3')
    c.sql("UPDATE runs SET status='completed' WHERE id=(SELECT id FROM runs WHERE id LIKE 'base%' AND ci_ready_at IS NULL AND awaiting_agent_since IS NULL LIMIT 1)")
    finish(p)   # leaving running releases
    say('  after complete:', c.err('full3').strip().splitlines()[-1])


@scenario('priority-order-and-arrival-order')
def priority():
    c = Case('priority', cores=3, load=0, counted=1)  # limit 1
    (c.dir / 'hold').touch()
    arrival = [('o1', 'other'), ('v1', 'vernant-build'), ('m1', 'machinery'), ('t1', 'merge-train'), ('o2', 'other'), ('t2', 'merge-train')]
    procs = {}
    for name, cls in arrival:
        procs[name] = c.start(name, [str(c.shim / 'no-mistakes'), 'axi', 'run', '--intent', 'x'], priority=cls, STUB_NAME=name)
        wait_for(lambda: len(c.waiters()) == len(procs), 'waiter ' + name)
    c.sql("UPDATE runs SET status='completed' WHERE id LIKE 'base%'")
    want = ['t1', 't2', 'm1', 'v1', 'o1', 'o2']
    got = []
    for name in want:
        wait_for(lambda: (c.dir / (name + '.started')).exists(), name + ' start')
        got.append(name)
        started = [p.stem for p in c.dir.glob('*.started')]
        assert sorted(started) == sorted(got), 'order broke: %s vs %s' % (started, got)
        assert c.counted() == 1
        time.sleep(0.8)  # others have time to overtake while capacity is full
        assert sorted(p.stem for p in c.dir.glob('*.started')) == sorted(got)
        (c.dir / (name + '.release')).touch()
        c.sql("UPDATE runs SET status='completed' WHERE id=?", (name,))
        finish(procs[name])
    say('  arrival', [a for a, _ in arrival], '-> grant', got)
    return got


@scenario('simultaneous-starts-cannot-overrun-and-checks-stay-parallel')
def burst():
    c = Case('burst', cores=10, load=0)   # limit 3
    (c.dir / 'hold').touch()
    names = ['b%d' % i for i in range(12)]
    procs = {n: c.start(n, [str(c.shim / 'no-mistakes'), 'axi', 'run', '--intent', 'x'], STUB_NAME=n, STUB_REGISTER_DELAY=0.4) for n in names}
    peak = 0
    t0 = time.time()
    # Wait for the three grants, then hold a full window. A wrong fourth grant has time to appear.
    while time.time() - t0 < 60 and len(list(c.dir.glob('*.started'))) < 3:
        peak = max(peak, c.counted())
        time.sleep(0.02)
    grant_secs = round(time.time() - t0, 2)
    t1 = time.time()
    while time.time() - t1 < 6:
        peak = max(peak, c.counted())
        time.sleep(0.02)
    say('  three grants took', grant_secs, 's')
    started = sorted(p.stem for p in c.dir.glob('*.started'))
    live = [n for n, p in procs.items() if p.poll() is None]
    say('  after 6s: started', started, 'peak counted', peak, 'waiters', len(c.waiters()), 'live clients', len(live))
    assert peak == 3 and len(started) == 3, 'overrun or underrun'
    assert all(not (c.dir / (n + '.done')).exists() for n in started), 'admitted clients must overlap, not serialize'
    # Release one by one; never exceed the limit.
    order = list(started)
    while len(order) < len(names):
        done = order[-1] if False else order[len(order) - 3]
        (c.dir / (done + '.release')).touch()
        c.sql("UPDATE runs SET status='completed' WHERE id=?", (done,))
        finish(procs[done])
        wait_for(lambda: len(list(c.dir.glob('*.started'))) == len(order) + 1, 'next grant')
        now = {p.stem for p in c.dir.glob('*.started')}
        order += sorted(now - set(order))
        assert c.counted() <= 3, 'limit overrun'
    for n in order[-3:]:
        (c.dir / (n + '.release')).touch()
        c.sql("UPDATE runs SET status='completed' WHERE id=?", (n,))
        finish(procs[n])
    assert c.waiters() == []
    return dict(peak=peak, grants=len(order))


@scenario('queue-time-outside-execution-clock')
def clock():
    c = Case('clock', cores=3, load=0, counted=1)
    c.env['FM_DURATION_ABSOLUTE_SECS'] = '3'
    argv = [str(c.shim / 'python3'), str(REPO / 'bin/fm-duration.py'), 'run', '--pipeline-priority', 'machinery', 'no-mistakes.run', '--',
            str(c.shim / 'no-mistakes'), 'axi', 'run', '--intent', 'clock-test']
    # Queue well past the bound.
    p = c.spawn('queued', argv, STUB_NAME='q', STUB_SLEEP=1)
    wait_for(lambda: len(c.waiters()) == 1, 'queued')
    assert not (c.dir / 'durations.jsonl').exists(), 'no sample while queued'
    time.sleep(6)
    assert p.poll() is None and not (c.dir / 'q.started').exists(), 'queue ended early or the client ran'
    assert not (c.dir / 'durations.jsonl').exists(), 'no sample while queued'
    c.sql("UPDATE runs SET status='completed'")
    finish(p)
    rows = [json.loads(l) for l in (c.dir / 'durations.jsonl').read_text().splitlines()]
    samples = [r for r in rows if r.get('key') == 'no-mistakes.run' and 'event' not in r]
    say('  queued 6s against a 3s bound. sample:', samples, 'stderr-last:', c.err('queued').strip().splitlines()[-1:])
    assert len(samples) == 1 and samples[0]['exit'] == 0 and not samples[0]['timed_out'] and samples[0]['duration_ms'] < 3000
    # The bound still bites after the grant: admission grants no extra time.
    c2 = Case('clock-bound', cores=3, load=0, counted=0)
    c2.env['FM_DURATION_ABSOLUTE_SECS'] = '2'
    argv2 = [str(c2.shim / 'python3'), str(REPO / 'bin/fm-duration.py'), 'run', 'no-mistakes.run', '--',
             str(c2.shim / 'no-mistakes'), 'axi', 'run', '--intent', 'slow']
    t0 = time.time()
    p = c2.spawn('slow', argv2, STUB_NAME='slow', STUB_SLEEP=30)
    code = p.wait(timeout=40)
    elapsed = time.time() - t0
    rows = [json.loads(l) for l in (c2.dir / 'durations.jsonl').read_text().splitlines()]
    say('  genuine overrun: exit', code, 'elapsed %.1fs' % elapsed, rows)
    assert code != 0 and elapsed < 25, 'absolute bound must still stop a slow granted client'
    assert not (c2.dir / 'slow.done').exists()
    return dict(sample=samples[0], overrun_exit=code)


@scenario('fresh-starts-queue-and-reattach-does-not')
def routing():
    table = []
    run = lambda c, label, cmd, flags=(), **extra: c.spawn(label, [str(c.shim / 'python3'), str(REPO / 'bin/fm-duration.py'), 'run'] + list(flags) + ['no-mistakes.run', '--', str(c.shim / 'no-mistakes')] + cmd, **extra)
    intentfile = CASES / 'intent.txt'; intentfile.write_text('x')
    fresh = [['axi', 'run', '--intent', 'x'], ['axi', 'run', '--intent=x'], ['axi', 'run', '--intent-file', str(intentfile)],
             ['axi', 'run', '--intent-file=' + str(intentfile)], ['axi', 'run', '--intent', '-'],
             ['axi', 'run', '--skip', 'push,pr,ci', '--intent', 'x'], ['axi', 'run', '--wait', '1m', '--intent', 'x'],
             ['rerun'], ['rerun', '--intent', 'y']]
    other = [['axi', 'run'], ['axi', 'run', '--wait', '1m'], ['axi', 'respond', '--action', 'fix'], ['axi', 'status'], ['status'], ['runs']]
    for i, cmd in enumerate(fresh):
        c = Case('route-f%d' % i, cores=3, load=0, counted=1)
        p = run(c, 'x', cmd, STUB_NAME='x')
        wait_for(lambda: len(c.waiters()) == 1, 'queue for %s' % cmd)
        time.sleep(0.4)
        assert not (c.dir / 'x.started').exists() and p.poll() is None, 'ran without admission: %s' % cmd
        c.sql("UPDATE runs SET status='completed'")
        finish(p)
        assert (c.dir / 'x.started').exists()
        assert 'pipeline-start admitted' in c.err('x')
        table.append(('queued', ' '.join(cmd)))
    for i, cmd in enumerate(other):
        c = Case('route-o%d' % i, cores=3, load=0, counted=20)
        p = run(c, 'x', cmd, STUB_NAME='x')
        finish(p, seconds=20)
        assert (c.dir / 'x.started').exists() and c.waiters() == [] and 'pipeline-start' not in c.err('x'), 'queued: %s' % cmd
        table.append(('direct', ' '.join(cmd)))
    # Each flag spelling of the class reaches the owner.
    for label, flags, want in (('space', ['--pipeline-priority', 'merge-train'], 'merge-train'), ('equals', ['--pipeline-priority=vernant-build'], 'vernant-build'), ('default', [], 'other')):
        c = Case('route-p-' + label, cores=3, load=0)
        finish(run(c, 'x', ['axi', 'run', '--intent', 'x'], flags, STUB_NAME='x'))
        assert 'priority=' + want in c.err('x'), c.err('x')
        table.append(('priority', label + '->' + want))
    # Invalid class never reaches the client, on an empty host too.
    c = Case('route-bad', cores=3, load=0)
    finish(run(c, 'x', ['axi', 'run', '--intent', 'x'], ['--pipeline-priority', 'bogus'], STUB_NAME='x'), 125)
    assert not (c.dir / 'x.started').exists()
    table.append(('refused-125', '--pipeline-priority bogus'))
    # A nested fresh start under an admitted client also queues: no inherited pass.
    c = Case('route-nested', cores=3, load=0)
    nested = c.dir / 'nested.sh'
    nested.write_text('#!/bin/bash\n%s %s run no-mistakes.nested -- %s axi run --intent nested\n' % (c.shim / 'python3', REPO / 'bin/fm-duration.py', c.shim / 'no-mistakes'))
    nested.chmod(0o755)
    p = c.spawn('outer', [str(c.shim / 'python3'), str(REPO / 'bin/fm-duration.py'), 'run', 'no-mistakes.run', '--', str(c.shim / 'no-mistakes'), 'axi', 'run', '--intent', 'outer'], STUB_NAME='outer')
    finish(p)
    c.sql("UPDATE runs SET status='running' WHERE id='outer'")
    p = c.spawn('nested', [str(nested)], STUB_NAME='inner')
    wait_for(lambda: len(c.waiters()) == 1, 'nested queues')
    assert not (c.dir / 'inner.started').exists()
    c.sql("UPDATE runs SET status='completed'")
    finish(p)
    table.append(('queued', 'nested fresh start under an admitted client'))
    # Probes for spellings outside the generated template. Observed, not assumed.
    probes = []
    for cmd in (['--skip', 'x', 'rerun'], ['--skip', 'x', 'axi', 'run', '--intent', 'x']):
        c = Case('route-probe%d' % len(probes), cores=3, load=0, counted=20)
        p = run(c, 'x', cmd, STUB_NAME='x', STUB_REGISTER=0)
        time.sleep(1.0)
        probes.append((' '.join(cmd), 'queued' if c.waiters() else 'direct'))
        killall()
    say('  routing table:'); [say('   ', a, ':', b) for a, b in table]
    say('  probes outside the template:', probes)
    return dict(table=table, probes=probes)


@scenario('unusable-sources-refuse-and-never-start')
def refuse():
    seen = {}
    def expect(label, case, **extra):
        m = case.marker('m-' + label)
        p = case.start(label, ['touch', str(m)], **extra)
        finish(p, 125, 40)
        assert not m.exists(), label + ' started work'
        line = case.err(label).strip().splitlines()[-1]
        seen[label] = line
        say('  ', label, '->', line)
    c = Case('ref-missing'); c.db_path().unlink()
    for f in c.home.glob('.no-mistakes/state.sqlite-*'): f.unlink()
    expect('missing-db', c)
    assert not c.db_path().exists(), 'admission created the database'
    c = Case('ref-garbage'); c.db_path().write_text('not a database at all, nothing here')
    expect('garbage-db', c)
    c = Case('ref-noschema'); c.db_path().unlink()
    with sqlite3.connect(c.db_path()) as db: db.execute("CREATE TABLE other (id TEXT)")
    expect('no-runs-table', c)
    c = Case('ref-old')
    c.db_path().unlink()
    with sqlite3.connect(c.db_path()) as db: db.execute("CREATE TABLE runs (id TEXT, status TEXT)")
    expect('old-schema-no-columns', c)
    c = Case('ref-perm'); c.db_path().chmod(0)
    if os.geteuid() != 0:
        expect('unreadable-db', c)
    c.db_path().chmod(0o644)
    for label, val in (('negative-load', -1), ('nan-load', float('nan')), ('inf-load', float('inf'))):
        c = Case('ref-' + label, cores=3, load=val)
        expect(label, c)
    c = Case('ref-pool')
    (c.home / '.cache').mkdir()
    (c.home / '.cache/fm-cpu-pool').write_text('a file, not a directory')
    expect('pool-path-is-a-file', c)
    # The database cannot be selected by environment: a second DB with headroom is ignored.
    c = Case('ref-env', cores=3, load=0, counted=5)
    other = c.dir / 'empty.sqlite'; shutil.copy(TEMPLATE, other)
    p = c.start('env-select', ['touch', str(c.marker('env'))], NM_HOME=str(c.dir), NO_MISTAKES_DB=str(other), FM_STATE_DB=str(other), CASE_DB=str(other))
    queued_notice(c, 'env-select')
    assert not c.marker('env').exists()
    os.killpg(p.pid, signal.SIGKILL); p.wait()
    # A file with no write permission opened read-only still reads: mode=ro is real.
    c = Case('ref-ro', cores=3, load=0)
    before = c.db_path().read_bytes()
    finish(c.start('ro', ['touch', str(c.marker('ro'))]))
    assert c.db_path().read_bytes() == before
    return seen


@scenario('queue-and-owner-death-do-not-strand-the-queue')
def recovery():
    c = Case('rec', cores=3, load=0, counted=1)
    low = c.start('low', ['touch', str(c.marker('low'))], priority='other')
    wait_for(lambda: len(c.waiters()) == 1, 'low')
    high = c.start('high', ['touch', str(c.marker('high'))], priority='merge-train')
    wait_for(lambda: len(c.waiters()) == 2, 'high')
    os.killpg(high.pid, signal.SIGKILL); high.wait()
    assert len(c.waiters()) in (1, 2), 'dead waiter file is inert or already swept'
    time.sleep(1.2)
    assert low.poll() is None and not c.marker('low').exists(), 'full count still queues the live waiter'
    c.sql("UPDATE runs SET status='completed'")
    finish(low)
    assert c.marker('low').exists() and not c.marker('high').exists()
    assert c.waiters() == [], 'the stale file was swept: %s' % c.waiters()
    say('  stale merge-train waiter did not block other; file swept')

    # SIGTERM in queue: exit, no work. SIGINT in queue: 130, no work.
    c = Case('rec2', cores=3, load=0, counted=1)
    p = c.start('term', ['touch', str(c.marker('term'))])
    wait_for(lambda: len(c.waiters()) == 1, 'term')
    os.killpg(p.pid, signal.SIGTERM); p.wait(10)
    assert not c.marker('term').exists()
    p = c.start('int', ['touch', str(c.marker('int'))])
    wait_for(lambda: len([w for w in c.waiters()]) >= 1, 'int')
    time.sleep(0.3)
    os.killpg(p.pid, signal.SIGINT)
    finish(p, 130)
    assert not c.marker('int').exists()

    # Client that never registers: start lock holds, others wait, none overrun.
    c = Case('rec3', cores=10, load=0)
    (c.dir / 'hold').touch()
    a = c.start('a', [str(c.shim / 'no-mistakes'), 'status'], STUB_NAME='a')   # registers nothing, stays alive
    wait_for(lambda: (c.dir / 'a.started').exists(), 'a')
    b = c.start('b', ['touch', str(c.marker('b'))])
    notice = queued_notice(c, 'b')
    say('  unregistered client:', notice)
    assert 'another start is registering' in notice and not c.marker('b').exists()
    pool_fds = slot_fds(a.pid)
    # The client is the owner's child. The kernel view of the child holds no lock.
    kids = subprocess.check_output(['pgrep', '-P', str(a.pid)], text=True).split()
    assert kids, 'no client child'
    kid_fds = {k: slot_fds(int(k)) for k in kids}
    say('  owner fds', pool_fds, 'client fds', kid_fds)
    assert any('pipeline-start.lock' in f for f in pool_fds), 'owner holds the start lock'
    assert all(not f for f in kid_fds.values()), 'client inherited a lock: %s' % kid_fds
    # SIGKILL of the owner frees the start lock even though the client survives.
    os.kill(a.pid, signal.SIGKILL); a.wait()
    finish(b)
    assert c.marker('b').exists()
    for k in kids: os.kill(int(k), 0)   # client still alive
    (c.dir / 'a.release').touch()
    say('  owner SIGKILL freed the start lock with the client alive')

    # Client returns without registering: lock freed, status preserved.
    c = Case('rec4', cores=3, load=0)
    finish(c.start('fail', ['sh', '-c', 'exit 7']), 7)
    finish(c.start('after', ['touch', str(c.marker('after'))]))
    assert c.marker('after').exists()
    finish(c.start('missing', [str(c.dir / 'no-such-binary')]), 127)
    plain = c.dir / 'plain'; plain.write_text('x'); plain.chmod(0o644)
    finish(c.start('noexec', [str(plain)]), 126)
    finish(c.start('after2', ['touch', str(c.marker('after2'))]))
    finish(c.start('empty', []), 125)
    say('  exit status 7, 127, 126, 125 preserved; queue still usable')


MASTER = r'''import json, os, pathlib, subprocess, sys, time
case = pathlib.Path(os.environ['CASE'])
kids = [subprocess.Popen([sys.executable, '-c', """
import os, pathlib, time
case = pathlib.Path(os.environ['CASE'])
(case / ('kid-%d.pid' % os.getpid())).write_text(os.environ.get('FM_CPU_PASS_HELD',''))
while not (case / 'release-kids').exists(): time.sleep(0.05)
"""], close_fds=False, start_new_session=True) for _ in range(6)]
while not (case / 'release-master').exists(): time.sleep(0.05)
'''


def child_locks(tree, name):
    """Run the six-child master under one implementation; report the kernel view."""
    c = Case('kids-' + name)
    c.env['PATH'] = os.pathsep.join([str(Path(PY).parent), '/usr/bin', '/bin'])
    (c.dir / 'master.py').write_text(MASTER)
    cli = ['bash', str(tree / 'bin/fm-cpu-pass.sh')]
    status = lambda: json.loads(subprocess.check_output(cli + ['status', '--json'], env=c.env, text=True))
    master = c.spawn('master', cli + ['run', '--passes', '6', '--', PY, str(c.dir / 'master.py')])
    wait_for(lambda: len(list(c.dir.glob('kid-*.pid'))) == 6, 'six children')
    pids = [int(p.stem.split('-')[1]) for p in c.dir.glob('kid-*.pid')]
    markers = sorted({p.read_text() for p in c.dir.glob('kid-*.pid')})
    alive_held = status()['held']
    per_child = {pid: len([f for f in slot_fds(pid) if f.startswith('slot-')]) for pid in pids}
    (c.dir / 'release-master').touch()
    finish(master)
    time.sleep(0.3)
    after_master = status()['held']
    all_alive = all(os.kill(pid, 0) is None for pid in pids)
    # A new six-pass burst on the ten-slot pool while children of the dead master live.
    t0 = time.time()
    second = c.spawn('second', cli + ['run', '--passes', '6', '--', 'touch', str(c.marker('second'))])
    blocked = None
    try:
        second.wait(timeout=5)
        blocked = False
    except subprocess.TimeoutExpired:
        blocked = True
    waited = time.time() - t0
    (c.dir / 'release-kids').touch()
    finish(second, seconds=30)
    wait_for(lambda: status()['held'] == 0, 'pool empties', 15)
    out = dict(impl=name, passes=6, workers=6, marker=markers, held_while_master_alive=alive_held,
               slot_fds_per_child=sorted(per_child.values()), held_after_master_exit=after_master,
               children_alive_after_master=all_alive, second_burst_blocked_5s=blocked, second_burst_wait_s=round(waited, 2),
               second_stderr=c.err('second').strip()[:200])
    say('  ', json.dumps(out))
    return out


@scenario('six-children-cannot-hold-master-slots-before-vs-after')
def child_ownership():
    before = child_locks(LAB / 'base', 'before-base-8618f637')
    after = child_locks(REPO, 'final-a1dc28be')
    assert os.cpu_count() >= 7
    # The defect exists at base: this proves the scenario catches it.
    assert before['slot_fds_per_child'] == [6] * 6 and before['held_after_master_exit'] == 6 and before['second_burst_blocked_5s']
    assert after['slot_fds_per_child'] == [0] * 6 and after['held_after_master_exit'] == 0 and not after['second_burst_blocked_5s']
    assert after['held_while_master_alive'] == 6 and after['marker'] == ['6'] and after['children_alive_after_master']
    return dict(before=before, after=after)


XTEST = r'''import os, pathlib, subprocess, time, pytest
case = pathlib.Path(os.environ['CASE'])
@pytest.mark.parametrize('i', range(6))
def test_barrier(i):
    (case / ('w-%d.pid' % os.getpid())).write_text(os.environ.get('PYTEST_XDIST_WORKER', ''))
    # A CPU-using nested call inside the reservation takes no new pass.
    nested = subprocess.run(['bash', os.environ['CLI'], 'run', '--passes', '1', '--', 'sh', '-c', 'echo $FM_CPU_PASS_HELD'],
                            capture_output=True, text=True, timeout=120)
    (case / ('nested-%d.txt' % os.getpid())).write_text(nested.stdout + '|' + str(nested.returncode))
    until = time.time() + 90
    while not (case / 'release').exists():
        assert time.time() < until
        time.sleep(0.05)
'''


def xdist(tree, name):
    c = Case('xdist-' + name)
    venv = LAB / 'venv/bin'
    c.env['PATH'] = os.pathsep.join([str(venv), str(Path(PY).parent), '/usr/bin', '/bin'])
    c.env['CLI'] = str(tree / 'bin/fm-cpu-pass.sh')
    (c.dir / 'test_x.py').write_text(XTEST)
    cli = ['bash', str(tree / 'bin/fm-cpu-pass.sh')]
    status = lambda: json.loads(subprocess.check_output(cli + ['status', '--json'], env=c.env, text=True))
    p = c.spawn('pytest', cli + ['run', '--passes', '6', '--label', 'pytest -n 6', '--', str(venv / 'pytest'), '-n', '6', '-q', '-p', 'no:cacheprovider', str(c.dir / 'test_x.py')])
    wait_for(lambda: len(list(c.dir.glob('w-*.pid'))) == 6, 'six real xdist workers', 90)
    wait_for(lambda: len(list(c.dir.glob('nested-*.txt'))) == 6, 'six nested calls', 90)
    workers = [int(f.stem.split('-')[1]) for f in c.dir.glob('w-*.pid')]
    fds = sorted(len([x for x in slot_fds(w) if x.startswith('slot-')]) for w in workers)
    names = sorted(f.read_text() for f in c.dir.glob('w-*.pid'))
    nested = sorted(f.read_text() for f in c.dir.glob('nested-*.txt'))
    held = status()['held']
    masters = subprocess.check_output(['pgrep', '-P', str(p.pid)], text=True).split()
    master_fds = sorted(len([x for x in slot_fds(int(m)) if x.startswith('slot-')]) for m in masters)
    (c.dir / 'release').touch()
    finish(p, seconds=60)
    out = dict(impl=name, xdist_workers=names, slot_fds_per_real_worker=fds, slot_fds_pytest_master=master_fds, held=held, nested=nested,
               held_after=status()['held'], summary=(c.dir / 'pytest.stdout').read_text().strip().splitlines()[-1])
    say('  ', json.dumps(out))
    return out


@scenario('real-pytest-xdist-n6-worker-lock-inheritance-before-vs-after')
def real_xdist():
    before = xdist(LAB / 'base', 'before-base-8618f637')
    after = xdist(REPO, 'final-a1dc28be')
    # Observed, not assumed: execnet's own close_fds shields xdist 3.8 workers even at base.
    # The master is the process that inherited at base. The exec-child defect itself is
    # reproduced by the six-children scenario, whose children keep descriptors open.
    assert before['slot_fds_pytest_master'] == [6], before
    assert after['slot_fds_pytest_master'] == [0] and after['slot_fds_per_real_worker'] == [0] * 6
    assert after['held'] == 6 and len(after['xdist_workers']) == 6 and after['held_after'] == 0
    assert '6 passed' in after['summary']
    assert all(n.startswith('6\n|0') for n in after['nested']), after['nested']
    return dict(before=before, after=after)


@scenario('generated-brief-command-runs-as-written')
def brief():
    out = {}
    for forge in ('github', 'gerrit'):
        text = subprocess.check_output(['bash', '-c', 'source "$1"; fm_nm_driving_block "$2"', 'x', str(REPO / 'bin/fm-dod-lib.sh'), forge], text=True,
                                       env={'PATH': os.environ['PATH'], 'HOME': str(LAB / 'home')})
        (EVID / ('generated-brief-block-%s.txt' % forge)).write_text(text)
        fresh = re.search(r'`(python3 \S+ run --pipeline-priority <class> no-mistakes\.run -- no-mistakes axi run <new-run inputs>)`', text).group(1)
        rerun = re.search(r'`(python3 \S+ run --pipeline-priority <class> no-mistakes\.run -- no-mistakes rerun)`', text).group(1)
        out[forge] = fresh
        c = Case('brief-' + forge, cores=3, load=0, counted=1)
        c.env['PATH'] = os.pathsep.join([str(c.shim), str(Path(PY).parent), '/usr/bin', '/bin'])
        for label, cmd in (('fresh', fresh.replace('<class>', 'machinery').replace('<new-run inputs>', "--intent 'x'")), ('rerun', rerun.replace('<class>', 'machinery'))):
            say('  literal:', cmd)
            p = c.spawn(label, ['bash', '-c', cmd], STUB_NAME=label)
            wait_for(lambda: len(c.waiters()) == 1, forge + ' ' + label + ' queued')
            assert not (c.dir / (label + '.started')).exists()
            c.sql("UPDATE runs SET status='completed' WHERE status='running' AND id LIKE 'base%'")
            finish(p)
            assert (c.dir / (label + '.started')).exists() and 'priority=machinery' in c.err(label)
            c.add(1)
            c.sql("UPDATE runs SET status='completed' WHERE id=?", (label,))
    # The path stays usable when it holds a space.
    spaced = LAB / 'path with space/bin'
    spaced.mkdir(parents=True)
    for f in ('fm-dod-lib.sh', 'fm-duration.py', 'fm-cpu-pass.py', 'fm-cpu-pass.sh'):
        shutil.copy(REPO / 'bin' / f, spaced / f)
    text = subprocess.check_output(['bash', '-c', 'source "$1"; fm_nm_driving_block github', 'x', str(spaced / 'fm-dod-lib.sh')], text=True,
                                   env={'PATH': os.environ['PATH'], 'HOME': str(LAB / 'home')})
    m = re.search(r'`(python3 .+? run --pipeline-priority <class> no-mistakes\.run -- no-mistakes axi run <new-run inputs>)`', text)
    cmd = m.group(1).replace('<class>', 'other').replace('<new-run inputs>', '--intent x')
    c = Case('brief-space', cores=3, load=0)
    finish(c.spawn('spaced', ['bash', '-c', cmd], STUB_NAME='spaced'))
    assert (c.dir / 'spaced.started').exists()
    say('  spaced path literal:', cmd)
    return out


ALL = [native_boundary, scaling, thresholds, count_definition, priority, burst, clock, routing, refuse, recovery, child_ownership, real_xdist, brief]
failed = 0
for fn in ALL:
    if ONLY and fn.__name__ not in ONLY:
        continue
    say('\n=== SCENARIO', fn.scenario, time.strftime('%H:%M:%S'))
    t0 = time.time()
    try:
        data = fn()
        results.append(dict(scenario=fn.scenario, result='pass', seconds=round(time.time() - t0, 1), data=data))
        say('--- PASS', fn.scenario, '%.1fs' % (time.time() - t0))
    except Exception as exc:
        failed += 1
        results.append(dict(scenario=fn.scenario, result='fail', error=repr(exc)))
        say('--- FAIL', fn.scenario, repr(exc))
    finally:
        killall()
out = EVID / 'live-admission-results.json'
previous = json.loads(out.read_text()) if out.exists() else []
keep = [r for r in previous if r['scenario'] not in {x['scenario'] for x in results}]
out.write_text(json.dumps(keep + results, indent=2, default=str))
say('\nsummary:', [(r['scenario'], r['result']) for r in results])
sys.exit(1 if failed else 0)
