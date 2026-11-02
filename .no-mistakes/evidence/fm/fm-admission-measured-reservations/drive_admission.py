#!/usr/bin/env python3
"""Live drive of bin/fm-duration.py -> bin/fm-cpu-pass.py pipeline-start on a throwaway HOME and lab FM_HOME.

Real parts: the CLI, the run-database reader, fm-mem-guard.sh probe, the process census, proc guard.
Disposable parts: HOME (its .no-mistakes/state.sqlite, worktrees, pool dir), the lab FM_HOME.
Stand-in: the `no-mistakes` client on PATH, because this gate phase must never call the real axi run.
It only registers a run row, the way the daemon does. FM_MEMORY_FIXTURE_DIR (the product's own fixture
boundary) is used only where a scenario says so, for values a live host cannot be pushed to safely.
Usage: drive_admission.py WORKTREE SCRATCH   (FM_HOME must already be the lab home)
"""
import json, os, signal, socket, sqlite3, subprocess, sys, time
from pathlib import Path

repo, scratch = Path(sys.argv[1]), Path(sys.argv[2])
lab = Path(os.environ['FM_HOME'])
GIB = 2 ** 30
HOST = socket.gethostname()
TOTAL = int(subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.memsize']))
base = {k: v for k, v in os.environ.items()
        if k not in ('NM_HOME', 'NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_CPU_PASS_HELD', 'FM_CPU_POOL_DIR', 'FM_DURATION_HOME')
        and not k.endswith('_OVERRIDE')}
base['PATH'] = os.pathsep.join([str(scratch / 'bin'), os.path.dirname(sys.executable), base['PATH']])
(scratch / 'bin').mkdir(exist_ok=True)
client = scratch / 'bin/no-mistakes'
client.write_text('''#!/usr/bin/env python3
import os, sqlite3, sys, time
home = os.environ['HOME']
if '--intent' not in sys.argv:
    print('reattach client ran', flush=True); sys.exit(0)
name = sys.argv[sys.argv.index('--intent') + 1]
with sqlite3.connect(home + '/.no-mistakes/state.sqlite') as db:
    db.execute("INSERT INTO runs (id, repo_id, status) VALUES (?, 'repo', 'running')", (name,))
with open(home + '/order', 'a') as out: out.write('%s %.3f\\n' % (name, time.time()))
''')
client.chmod(0o755)
results, ballast, waiting = [], [], []


def say(text=''):
    print(text, flush=True)


def scenario(title):
    say('\n=== ' + title)
    say('load averages (real host): %.2f %.2f %.2f; old rule limit 36' % os.getloadavg())


def check(name, ok, detail=''):
    results.append((name, bool(ok)))
    say('%s  %s%s' % ('PASS' if ok else 'FAIL', name, (' :: ' + str(detail)) if detail != '' else ''))


class Case:
    def __init__(self, name, counted=0, rows=()):
        self.home = scratch / name
        (self.home / '.no-mistakes').mkdir(parents=True)
        self.db = self.home / '.no-mistakes/state.sqlite'
        with sqlite3.connect(self.db) as db:
            db.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER)')
            for i in range(counted):
                db.execute("INSERT INTO runs (id, repo_id, status) VALUES (?, 'repo', 'running')", ('counted-%d' % i,))
            for row in rows:
                db.execute('INSERT INTO runs (id, repo_id, status, ci_ready_at, awaiting_agent_since) VALUES (?,?,?,?,?)', row)
        self.env = dict(base, HOME=str(self.home), FM_HOME=str(lab), FM_DURATION_FILE='off')
        self.n = 0

    def fixture(self, available=40 * GIB, pressure=1, runs=(), broken=False):
        folder = self.home / 'native'
        folder.mkdir(exist_ok=True)
        self.env['FM_MEMORY_FIXTURE_DIR'] = str(folder)
        for name in ('sysctl', 'vm_stat', 'processes.json'):
            (folder / name).unlink(missing_ok=True)
        if broken:
            return
        (folder / 'sysctl').write_text('%d\n%d\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' % (TOTAL, pressure))
        (folder / 'vm_stat').write_text(
            'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages speculative: 100.\n'
            'Anonymous pages: 1048576.\nFile-backed pages: %d.\nPages purgeable: 100.\nPages occupied by compressor: 32768.\n'
            % (available // 16384 - 1100))
        rows = [dict(pid=101, ppid=1, comm='daemon', started='s', rss_bytes=GIB, fleet=False, run=None)]
        for i, (key, rss) in enumerate(runs):
            rows.append(dict(pid=200 + i, ppid=1, comm='node', started='s%d' % i, rss_bytes=rss, fleet=True, run=key))
        (folder / 'processes.json').write_text(json.dumps(rows))

    def sql(self, statement, *parameters):
        with sqlite3.connect(self.db) as db:
            db.execute(statement, parameters)

    def start(self, name, priority='other', env=None, intent=True):
        """A fresh start the way a worker issues it: fm-duration.py run ... -- no-mistakes axi run --intent ..."""
        self.n += 1
        err = self.home / ('%s.stderr' % name)
        command = [sys.executable, str(repo / 'bin/fm-duration.py'), 'run', '--pipeline-priority', priority, 'key-' + name,
                   '--', 'no-mistakes', 'axi', 'run'] + (['--intent', name] if intent else [])
        child = subprocess.Popen(command, env=env or self.env, cwd=str(repo), stdout=subprocess.DEVNULL, stderr=open(err, 'w'), start_new_session=True)
        child.err = err
        child.name = name
        waiting.append(child)
        return child

    def order(self):
        path = self.home / 'order'
        return [line.split()[0] for line in path.read_text().splitlines()] if path.exists() else []


def text(child):
    return child.err.read_text()


def wait_notice(child, secs=8):
    until = time.monotonic() + secs
    while time.monotonic() < until:
        if child.poll() is not None:
            return False
        if 'pipeline-start waiting' in text(child):
            return True
        time.sleep(0.05)
    return False


def done(child, secs=40):
    try:
        return child.wait(timeout=secs)
    except subprocess.TimeoutExpired:
        return None


def stop(child):
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=10)


def line(child, word):
    found = [l for l in text(child).splitlines() if word in l]
    return found[-1] if found else ''


def field(row, key):
    return int(row.split(key + '=')[1].split()[0])


def record(peaks, host=HOST, total=TOTAL, repo_id='repo', samples=2, raw=None):
    state = lab / 'state'
    state.mkdir(parents=True, exist_ok=True)
    path = state / '.memory-calibration.json'
    if raw is not None:
        path.write_text(raw)
        return
    runs = {'no-mistakes:%s/%s' % (repo_id, name): dict(peak_bytes=int(peak), samples=samples, incomplete_samples=0, first_seen='2026-11-01T00:00:00+00:00', last_seen='2026-11-01T00:00:00+00:00', max_gap_seconds=0)
            for name, peak in peaks.items()}
    runs['task:crewmate'] = dict(peak_bytes=100 * GIB, samples=9, incomplete_samples=0, first_seen='2026-11-01T00:00:00+00:00', last_seen='2026-11-01T00:00:00+00:00', max_gap_seconds=0)
    path.write_text(json.dumps(dict(schema='fm-memory-calibration.v1', host=host, total_bytes=total, runs=runs, pressured=None)))


def peaks(*gib):
    return {'old-%d' % i: value * GIB for i, value in enumerate(gib)}


def hold(case, repo_id, run, mib):
    """A real process in a real run worktree path, holding real resident memory."""
    cwd = case.home / '.no-mistakes/worktrees' / repo_id / run
    cwd.mkdir(parents=True)
    child = subprocess.Popen([sys.executable, '-c', '''
import sys, time
block = bytearray(%d * 1048576)
for i in range(0, len(block), 4096): block[i] = 1
print('up', flush=True)
time.sleep(3600)
''' % mib], cwd=str(cwd), stdout=subprocess.PIPE, text=True, env=case.env)
    child.stdout.readline()
    ballast.append(child)
    return child


def real_available():
    code = ("import importlib.util as u; s=u.spec_from_file_location('g',%r); m=u.module_from_spec(s); s.loader.exec_module(m);"
            "print(m.admission_sample()['available_bytes'])") % str(repo / 'bin/fm-mem-guard.py')
    return int(subprocess.check_output([sys.executable, '-c', code], env=dict(base, HOME=str(scratch))))


def real_host_probe_then_admit():
    scenario('S1 real probe writes the record, real reading admits on the measured basis')
    (lab / 'state/.memory-calibration.json').unlink(missing_ok=True)
    case = Case('s1')
    for run, mib in (('r64', 64), ('r128', 128), ('r256', 256)):
        hold(case, 'repoA', run, mib)
    env = dict(case.env)
    for _ in range(2):
        out = subprocess.run(['bash', str(repo / 'bin/fm-mem-guard.sh'), 'probe'], env=env, cwd=str(repo), capture_output=True, text=True)
        say('probe rc=%d %s' % (out.returncode, out.stderr.strip()[:200]))
        time.sleep(1)
    saved = json.loads((lab / 'state/.memory-calibration.json').read_text())
    entries = {k: (v['peak_bytes'], v['samples']) for k, v in saved['runs'].items() if k.startswith('no-mistakes:')}
    say('record: host=%s total=%d entries=%s' % (saved['host'], saved['total_bytes'], entries))
    check('real probe recorded 3 run trees with 2 samples', len(entries) == 3 and all(s == 2 for _, s in entries.values()))
    expected = sorted(p for p, _ in entries.values())
    child = case.start('first')
    rc = done(child)
    row = line(child, 'admitted')
    say(row)
    check('fresh start admitted on measured basis, real reading', rc == 0 and 'basis=fallback' not in row and 'reservation=' in row)
    check('R is nearest-rank p75 of the 3 peaks, S the largest', field(row, 'reservation') == expected[2] and field(row, 'slack') == expected[2] and field(row, 'runs_measured') == 3, expected)
    # A counted run in the real census: its live tree adds at most R to the budget.
    case.sql("INSERT INTO runs (id, repo_id, status) VALUES ('r256', 'repoA', 'running')")
    child = case.start('second')
    rc = done(child)
    row = line(child, 'admitted')
    say(row)
    check('live run row and live tree are read together: counted=2 (r256 + first), runs_measured drops to 2', rc == 0 and 'counted=2' in row and field(row, 'runs_measured') == 2)
    for proc in ballast:
        proc.kill()
    ballast.clear()


def full_while_load_is_low():
    scenario('S2 load under the old limit and count under the old limit, but reservations full: waits')
    available = real_available()
    say('real available_bytes=%d' % available)
    record(peaks(*[0.45 * available / GIB] * 4))
    case = Case('s2', counted=1)
    child = case.start('blocked')
    check('start waits with the real reading (old rule: counted 1 < 6 and load <= 36 would admit)', wait_notice(child), line(child, 'waiting'))
    time.sleep(6)
    check('still waiting after 6 more seconds, no run created', child.poll() is None and case.order() == [])
    case.sql("UPDATE runs SET status='completed' WHERE id='counted-0'")
    start = time.monotonic()
    rc = done(child)
    say(line(child, 'admitted'))
    check('admitted when the counted run ends, with no spacing', rc == 0 and case.order() == ['blocked'], 'after %.2fs' % (time.monotonic() - start))


def burst():
    scenario('S3 burst of 8 ready starts, above the old limit of 6 on 18 CPUs: all admitted back to back')
    record(peaks(0.05, 0.05, 0.1, 0.1))
    case = Case('s3')
    start = time.time()
    children = [case.start('b%d' % i) for i in range(8)]
    codes = [done(c, 120) for c in children]
    elapsed = time.time() - start
    times = [float(l.split()[1]) for l in (case.home / 'order').read_text().splitlines()]
    gaps = [round(b - a, 2) for a, b in zip(times, times[1:])]
    say('return codes %s; gaps between registrations (s): %s; total %.2fs' % (codes, gaps, elapsed))
    for child in children:
        say(line(child, 'admitted'))
    check('8 of 8 admitted and registered', codes == [0] * 8 and len(case.order()) == 8)
    check('counted reached 7 at the last admission (old limit 6)', any('counted=7' in text(c) for c in children))
    check('no gap near the old 10-minute spacing', max(gaps) < 10, max(gaps))


def class_order():
    scenario('S4 capacity short: classes leave the queue in merge-train, machinery, vernant-build, other order')
    record(peaks(1, 1, 1, 1))  # R=1, S=1
    case = Case('s4', counted=2)
    case.fixture(available=3 * GIB)  # fits only at counted <= 1
    children = []
    for name, priority in (('o', 'other'), ('v', 'vernant-build'), ('m', 'machinery'), ('t', 'merge-train')):
        children.append(case.start(name, priority))
        time.sleep(0.4)
    check('all 4 wait while 2 runs are counted', wait_notice(children[0]) and case.order() == [])
    case.sql("UPDATE runs SET status='completed' WHERE id='counted-0'")
    for expected in ('t', 'm', 'v', 'o'):
        until = time.monotonic() + 15
        while expected not in case.order() and time.monotonic() < until:
            time.sleep(0.05)
        time.sleep(1.5)
        check('next admitted is ' + expected + ' and no other slipped past', case.order()[-1:] == [expected], case.order())
        case.sql("UPDATE runs SET status='completed' WHERE id=?", expected)
    check('all return 0', [done(c) for c in children] == [0] * 4)


def overload():
    scenario('S5 overload pauses and running work is never stopped')
    record(peaks(1, 1, 1, 1))
    case = Case('s5')
    held = hold(case, 'repo', 'still-running', 32)
    case.fixture(available=100 * GIB, pressure=2)
    child = case.start('p2')
    check('native pressure 2 pauses even with no counted run (floor does not override)', wait_notice(child) and 'native memory pressure level 2' in text(child), line(child, 'waiting'))
    case.fixture(available=100 * GIB, pressure=1)
    rc = done(child)
    check('pressure back to 1: admitted', rc == 0, line(child, 'admitted'))
    check('running process untouched', held.poll() is None)
    case.fixture(broken=True)
    child = case.start('unreadable')
    check('unreadable memory facts pause, never read as an empty host', wait_notice(child) and 'memory' in line(child, 'waiting'), line(child, 'waiting'))
    time.sleep(3)
    check('no run created while unreadable', 'unreadable' not in case.order())
    case.fixture(available=100 * GIB)
    check('facts readable again: admitted', done(child) == 0, line(child, 'admitted'))
    check('running process still untouched', held.poll() is None)
    held.kill()
    ballast.remove(held)


def exact_budget():
    scenario('S6 adversarial: run holding above R gets only R of credit; exact byte boundary')
    record(peaks(0.02, 0.1, 0.69, 0.75, 0.79, 0.8, 0.82, 0.96, 1.0, 3.0, 4.0, 5.8, 8.0))  # R=3, S=8, as a hand-ranked p75 of 13
    case = Case('s6', counted=1)
    key = 'no-mistakes:repo/counted-0'
    case.fixture(available=8 * GIB, runs=[(key, 7 * GIB)])
    child = case.start('capped')
    ok = wait_notice(child)
    row = line(child, 'waiting')
    say(row)
    check('need 14 GiB, B = 8 + min(3, 7) = 11 GiB: waits (uncapped B = 15 would admit)', ok and field(row, 'need') == 14 * GIB and field(row, 'budget') == 11 * GIB)
    case.fixture(available=11 * GIB - 16384, runs=[(key, 7 * GIB)])
    time.sleep(3)
    check('one page short of the boundary: still waits', child.poll() is None)
    case.fixture(available=11 * GIB, runs=[(key, 7 * GIB)])
    rc = done(child)
    row = line(child, 'admitted')
    say(row)
    check('exact fit need == B: admitted', rc == 0 and field(row, 'need') == field(row, 'budget') == 14 * GIB)


def r_and_s_filters():
    scenario('S7 adversarial: young running runs do not dilute R; a CI-ready peak stays in R and S')
    # Ranked finished peaks 1..8 GiB: p75 of 8 is the 6th, 6 GiB.
    table = peaks(1, 2, 3, 4, 5, 6, 7, 8)
    table.update({'young1': 0.1 * GIB, 'young2': 0.1 * GIB, 'young3': 0.1 * GIB, 'young4': 0.1 * GIB, 'parked': 0.1 * GIB, 'ciready': 20 * GIB})
    record(table)
    rows = [(n, 'repo', 'running', None, None) for n in ('young1', 'young2', 'young3', 'young4')]
    rows += [('parked', 'repo', 'running', None, 123), ('ciready', 'repo', 'running', 123, None)]
    case = Case('s7', rows=rows)
    case.fixture(available=100 * GIB)
    child = case.start('filter')
    rc = done(child)
    row = line(child, 'admitted')
    say(row)
    # Ranked: 1..8 plus ciready=20 -> 9 values; nearest rank ceil(6.75)=7th = 7 GiB. Young and parked left out.
    check('R = 7 GiB: the 4 young and 1 parked 0.1 GiB rows left out, CI-ready ranked', rc == 0 and field(row, 'reservation') == 7 * GIB and field(row, 'runs_measured') == 9)
    check('S = 20 GiB from the CI-ready running run', field(row, 'slack') == 20 * GIB)
    check('counted = 4 young only (parked and CI-ready do not count)', 'counted=4' in row)


def floor_and_fallback():
    scenario('S8 one-start floor, and every fallback shape')
    record(peaks(3, 3, 3, 8))
    case = Case('s8floor')
    case.fixture(available=GIB)
    child = case.start('floor')
    rc = done(child)
    row = line(child, 'admitted')
    say(row)
    check('idle host with need > B: one start still admitted', rc == 0 and field(row, 'need') > field(row, 'budget'))
    case2 = Case('s8floor2', counted=1)
    case2.fixture(available=GIB)
    child = case2.start('notfloor')
    check('one counted run with need > B: floor does not apply', wait_notice(child), line(child, 'waiting'))
    stop(child)
    good = json.dumps(dict(schema='fm-memory-calibration.v1', host=HOST, total_bytes=TOTAL, pressured=None, runs={
        'no-mistakes:repo/a': 'garbage', 'no-mistakes:repo/b': dict(peak_bytes=GIB, samples=2)}))
    shapes = [
        ('missing record', lambda: (lab / 'state/.memory-calibration.json').unlink(missing_ok=True)),
        ('other host', lambda: record(peaks(1, 1, 1, 1), host='other-host')),
        ('other RAM size', lambda: record(peaks(1, 1, 1, 1), total=TOTAL // 2)),
        ('garbage JSON', lambda: record({}, raw='{not json')),
        ('wrong schema', lambda: record({}, raw=json.dumps(dict(schema='x', host=HOST, total_bytes=TOTAL, runs={})))),
        ('one qualifying run', lambda: record(peaks(1))),
        ('one-sample runs only', lambda: record(peaks(1, 1, 1, 1), samples=1)),
        ('runs is a list', lambda: record({}, raw=json.dumps(dict(schema='fm-memory-calibration.v1', host=HOST, total_bytes=TOTAL, runs=[], pressured=None)))),
        ('corrupt run entry', lambda: record({}, raw=good)),
    ]
    limit = max(1, os.cpu_count() // 3)
    for label, prepare in shapes:
        prepare()
        case = Case('s8-' + label.replace(' ', '-'), counted=limit)
        child = case.start('full')
        full = wait_notice(child) and 'basis=fallback' in line(child, 'waiting') and 'limit=%d' % limit in line(child, 'waiting')
        stop(child)
        case = Case('s8b-' + label.replace(' ', '-'), counted=limit - 1)
        child = case.start('room')
        rc = done(child)
        check('%s: fallback waits at counted=%d, admits at %d' % (label, limit, limit - 1),
              full and rc == 0 and 'basis=fallback' in line(child, 'admitted'), line(child, 'admitted'))


def refusals():
    scenario('S9 unreadable run database refuses with 125 and starts nothing')
    record(peaks(1, 1, 1, 1))
    case = Case('s9')
    case.db.unlink()
    child = case.start('nodb')
    rc = done(child)
    check('missing database: 125, no client ran', rc == 125 and not (case.home / 'order').exists(), line(child, 'refused'))
    check('reader did not create a database', not case.db.exists())
    case = Case('s9b')
    case.db.write_bytes(b'this is not sqlite' * 100)
    child = case.start('badb')
    rc = done(child)
    check('garbage database: 125, no client ran', rc == 125 and not (case.home / 'order').exists(), line(child, 'refused'))


def homes():
    scenario('S10 a worker with FM_DURATION_HOME and a secondmate home read the root record')
    record(peaks(1, 2, 3, 4))
    case = Case('s10a', counted=7)
    case.fixture(available=100 * GIB)
    env = dict(case.env, FM_DURATION_HOME=str(lab))
    env.pop('FM_HOME')
    child = case.start('worker', env=env)
    rc = done(child)
    say(line(child, 'admitted'))
    check('worker env: measured basis at counted=7, R=3 GiB (3rd of 4) S=4 GiB', rc == 0 and 'reservation=%d slack=%d' % (3 * GIB, 4 * GIB) in line(child, 'admitted'))
    second = scratch / 'secondmate'
    second.mkdir()
    (second / '.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' % lab)
    case = Case('s10b', counted=7)
    case.fixture(available=100 * GIB)
    child = case.start('child', env=dict(case.env, FM_HOME=str(second)))
    rc = done(child)
    say(line(child, 'admitted'))
    check('secondmate home: root record used', rc == 0 and 'reservation=%d slack=%d' % (3 * GIB, 4 * GIB) in line(child, 'admitted'))
    (second / '.fm-secondmate-parent').write_text('schema=wrong\n')
    case = Case('s10c', counted=7)
    case.fixture(available=100 * GIB)
    child = case.start('badlink', env=dict(case.env, FM_HOME=str(second)))
    full = wait_notice(child)
    say(line(child, 'waiting'))
    check('broken parent link: fallback, never an empty host', full and 'basis=fallback' in line(child, 'waiting'))
    stop(child)


def reattach():
    scenario('S11 a reattach does not queue while the host is full')
    record(peaks(50, 50, 50, 50))
    case = Case('s11', counted=20)
    case.fixture(available=GIB)
    child = case.start('attach', intent=False)
    rc = done(child, 20)
    check('flagless axi run passes straight through', rc == 0 and 'pipeline-start' not in text(child), text(child)[:200])


try:
    for step in (real_host_probe_then_admit, full_while_load_is_low, burst, class_order, overload, exact_budget,
                 r_and_s_filters, floor_and_fallback, refusals, homes, reattach):
        try:
            step()
        except Exception as exc:
            check(step.__name__ + ' crashed', False, repr(exc))
finally:
    for child in waiting:
        stop(child)
    for proc in ballast:
        proc.kill()
failed = [name for name, ok in results if not ok]
say('\n%d checks, %d failed' % (len(results), len(failed)))
for name in failed:
    say('FAILED: ' + name)
sys.exit(1 if failed else 0)
