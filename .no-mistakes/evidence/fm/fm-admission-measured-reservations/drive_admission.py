#!/usr/bin/env python3
"""Live driver: runs the real bin/fm-cpu-pass.sh, fm-duration.py and fm-mem-guard.sh against this host's real
memory and process readings, with a disposable HOME (run database, pool dir) and a marked lab FM_HOME.
Usage: drive_admission.py HEAD_ROOT BASE_ROOT LAB_FM_HOME SCRATCH SCENARIO..."""
import json, os, signal, socket, sqlite3, subprocess, sys, time, uuid, importlib.util
from pathlib import Path

HEAD, BASE, LAB, SCRATCH = map(Path, sys.argv[1:5])
WANT = sys.argv[5:]
GIB = 2 ** 30
children = []
os.environ.pop('NM_HOME', None)  # the agent shell's own value must not point the census at the real run root

spec = importlib.util.spec_from_file_location('fm_mem_guard', HEAD / 'bin/fm-mem-guard.py')
guard = importlib.util.module_from_spec(spec); sys.modules['fm_mem_guard'] = guard; spec.loader.exec_module(guard)

def say(text=''):
    print(text, flush=True)

def reading():
    env = dict(os.environ)
    return guard.admission_sample()

class Lab:
    def __init__(self, name, home=LAB):
        self.dir = SCRATCH / name
        self.home = self.dir / 'home'
        (self.home / '.no-mistakes').mkdir(parents=True)
        self.db = self.home / '.no-mistakes/state.sqlite'
        self.logs = self.dir / 'logs'; self.logs.mkdir()
        self.bin = self.dir / 'bin'; self.bin.mkdir()
        self.fmhome = home
        self.starts = self.dir / 'starts.log'
        with sqlite3.connect(self.db) as c:
            c.execute('PRAGMA journal_mode=WAL')
            c.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER)')
        c.close()
        shim = self.bin / 'no-mistakes'
        shim.write_text('#!/usr/bin/env python3\n'
            'import os, sqlite3, sys, time, uuid\n'
            'args = sys.argv[1:]\n'
            'tag = os.environ.get("LAB_TAG", "?")\n'
            'open(os.environ["LAB_STARTS"], "a").write("%.3f %s %s\\n" % (time.time(), tag, " ".join(args)))\n'
            'if any(a.startswith("--intent") for a in args):\n'
            '    c = sqlite3.connect(os.path.expanduser("~/.no-mistakes/state.sqlite"), timeout=10)\n'
            '    c.execute("INSERT INTO runs (id, repo_id, status) VALUES (?, ?, ?)", (uuid.uuid4().hex, "labrepo", "running")); c.commit(); c.close()\n'
            'time.sleep(float(os.environ.get("LAB_HOLD", "0")))\n')
        shim.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('NO_MISTAKES_', 'FM_')) and k != 'NM_HOME'}
        self.env.update(HOME=str(self.home), FM_HOME=str(home), LAB_STARTS=str(self.starts),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'])

    def seed(self, n, repo='seedrepo', prefix='seed'):
        with sqlite3.connect(self.db) as c:
            c.executemany('INSERT INTO runs (id, repo_id, status) VALUES (?, ?, ?)',
                          [('%s-%d' % (prefix, i), repo, 'running') for i in range(n)])
        c.close()

    def sql(self, statement, *params):
        with sqlite3.connect(self.db) as c:
            c.execute(statement, params)
        c.close()

    def counted(self):
        c = sqlite3.connect(self.db)
        n = c.execute("SELECT COUNT(*) FROM runs WHERE status='running' AND ci_ready_at IS NULL AND awaiting_agent_since IS NULL").fetchone()[0]
        c.close(); return n

    def start_lines(self):
        return self.starts.read_text().splitlines() if self.starts.exists() else []

    def launch(self, tag, argv, prefix=(), **extra):
        log = open(self.logs / (tag + '.log'), 'w')
        env = dict(self.env, LAB_TAG=tag, **{k: str(v) for k, v in extra.items()})
        p = subprocess.Popen(list(prefix) + argv, env=env, cwd=str(self.dir), stdin=subprocess.DEVNULL,
                             stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        p.tag = tag; p.logpath = self.logs / (tag + '.log')
        children.append(p); return p

    def duration(self, tag, priority='other', root=HEAD, prefix=(), intent=True, **extra):
        cmd = ['python3', str(root / 'bin/fm-duration.py'), 'run', '--pipeline-priority', priority, 'lab.' + tag,
               '--', 'no-mistakes', 'axi', 'run'] + (['--intent', 'lab'] if intent else [])
        return self.launch(tag, cmd, prefix, **extra)

    def direct(self, tag, priority='other', root=HEAD, prefix=(), **extra):
        cmd = ['bash', str(root / 'bin/fm-cpu-pass.sh'), 'pipeline-start', '--priority', priority, '--',
               'no-mistakes', 'axi', 'run', '--intent', 'lab']
        return self.launch(tag, cmd, prefix, **extra)

def log_text(p):
    return p.logpath.read_text()

def wait_log(p, text, secs=40):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if text in log_text(p):
            return True
        if p.poll() is not None and text not in log_text(p):
            return text in log_text(p)
        time.sleep(0.1)
    return False

def calibrate(fmhome, peaks, host=None, total=None, samples=2):
    now = reading() if total is None else None
    state = Path(fmhome) / 'state'; state.mkdir(parents=True, exist_ok=True)
    runs = {'no-mistakes:histrepo/old-%d' % i: dict(peak_bytes=int(p), samples=samples, incomplete_samples=0,
            first_seen='x', last_seen='x', max_gap_seconds=0) for i, p in enumerate(peaks)}
    runs['task:crewmate'] = dict(peak_bytes=500 * GIB, samples=9)
    path = state / '.memory-calibration.json'
    path.write_text(json.dumps(dict(schema='fm-memory-calibration.v1', host=host or socket.gethostname(),
                    total_bytes=total or now['total_bytes'], runs=runs, pressured=None)))
    return path

def peaks_for(R, S):
    """13 peaks: nearest-rank 75th percentile (10th) is R, largest is S."""
    return [R * 0.2] * 9 + [R, S * 0.9 if S * 0.9 > R else R, S * 0.95 if S * 0.95 > R else R, S]

def kill(p):
    if p.poll() is None:
        try: os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        p.wait()

def check(label, ok):
    say('  CHECK %-4s %s' % ('PASS' if ok else 'FAIL', label))
    RESULTS.append((label, ok))
    return ok

RESULTS = []

def fields(line):
    return {k: v for k, _, v in (w.partition('=') for w in line.split()) if v}

def show(p, label=None):
    say('  [%s] %s' % (label or p.tag, ' | '.join(l for l in log_text(p).splitlines() if 'fm-cpu-pass' in l or 'mem' in l.lower()) or '(no admission line)'))

# ---- scenarios
def burst():
    say('== burst: 8 ready starts through fm-duration.py, real memory reading, low reservations')
    m = reading(); say('  real reading: available=%.1f GiB pressure=%s load=%s' % (m['available_bytes'] / GIB, m['pressure_level'], os.getloadavg()))
    calibrate(LAB, peaks_for(0.25 * GIB, 1 * GIB))
    lab = Lab('burst')
    ps = [lab.duration('b%d' % i, LAB_HOLD=45) for i in range(8)]
    end = time.monotonic() + 40
    while time.monotonic() < end and len(lab.start_lines()) < 8: time.sleep(0.1)
    times = sorted(float(l.split()[0]) for l in lab.start_lines())
    gaps = [round(b - a, 2) for a, b in zip(times, times[1:])]
    for p in ps: show(p)
    say('  starts=%d counted=%d span=%.1fs gaps=%s' % (len(times), lab.counted(), times[-1] - times[0] if times else 0, gaps))
    check('all 8 starts admitted; 7 and 8 exceed the old fixed limit of 6', len(times) == 8 and lab.counted() == 8)
    check('no 10-minute spacing: whole burst inside 40 s', times and times[-1] - times[0] < 40)
    check('admission line is measured, names no load', all('basis=fallback' not in log_text(p) and 'load' not in ' '.join(l for l in log_text(p).splitlines() if 'admitted' in l) for p in ps))
    for p in ps: kill(p)
    say('== burst-base: same 8 starts on the base commit (the old rule)')
    labb = Lab('burst-base')
    ps = [labb.duration('b%d' % i, root=BASE, LAB_HOLD=45) for i in range(8)]
    end = time.monotonic() + 25
    while time.monotonic() < end and len(labb.start_lines()) < 6: time.sleep(0.2)
    time.sleep(6)
    for p in ps: show(p)
    say('  base starts=%d counted=%d' % (len(labb.start_lines()), labb.counted()))
    check('base commit stops at 6 with the same host and record (the new rule is what changed)', len(labb.start_lines()) == 6)
    for p in ps: kill(p)

def budget():
    say('== budget: wait when reservations do not fit, release on real status change, class order, running work untouched')
    a = reading()['available_bytes']
    R, S = int(a * 0.25), int(a * 0.35)  # counted=1 needs 0.85 x available; counted=2 needs 1.10 x available
    calibrate(LAB, peaks_for(R, S))
    lab = Lab('budget'); lab.seed(2)
    say('  available=%.1f GiB R=%.1f S=%.1f counted=2 need=%.1f' % (a / GIB, R / GIB, S / GIB, (3 * R + S) / GIB))
    work = subprocess.Popen(['sleep', '120'], start_new_session=True); children.append(work)
    other = lab.direct('other', 'other', LAB_HOLD=60)
    check('other start waits with need > budget notice', wait_log(other, 'pipeline-start waiting'))
    show(other)
    time.sleep(0.3)
    train = lab.direct('train', 'merge-train', LAB_HOLD=60)
    wait_log(train, 'pipeline-start waiting', 10)
    check('no start launched while over budget', lab.start_lines() == [])
    check('running work untouched during the wait', work.poll() is None)
    lab.sql("UPDATE runs SET ci_ready_at = 1 WHERE id = 'seed-0'")
    check('CI-ready release admits the later merge-train start first', wait_log(train, 'pipeline-start admitted', 20))
    show(train)
    time.sleep(3)
    check('other still waits: the new run took the room', 'admitted' not in log_text(other))
    lab.sql("UPDATE runs SET status = 'completed' WHERE id = 'seed-1'")
    check('a finished run admits the other start', wait_log(other, 'pipeline-start admitted', 20))
    show(other)
    order = [l.split()[1] for l in lab.start_lines()]
    say('  launch order: %s' % order)
    check('class order holds', order == ['train', 'other'])
    check('running work still alive at the end', work.poll() is None)
    for p in (other, train, work): kill(p)

def held():
    say('== held: real resident memory of real run trees counts, capped at R per run')
    R = 1 * GIB
    lab = Lab('held'); hogs = []
    for run, size in (('heavy', 4), ('light', 2)):
        wt = lab.home / '.no-mistakes/worktrees/labrepo' / run; wt.mkdir(parents=True)
        hog = subprocess.Popen(['python3', '-c', 'import time\nb=bytearray(%d*2**30)\nfor i in range(0,len(b),4096): b[i]=1\nprint("ready",flush=True)\ntime.sleep(150)' % size],
                               cwd=wt, stdout=subprocess.PIPE, text=True, start_new_session=True, env=lab.env)
        children.append(hog); hogs.append(hog); hog.stdout.readline()
        lab.sql("INSERT INTO runs (id, repo_id, status) VALUES (?, 'labrepo', 'running')", run)
    env_backup = dict(os.environ); os.environ.update(HOME=str(lab.home))
    m = reading(); os.environ.clear(); os.environ.update(env_backup)
    seen = {k: round(v['rss_bytes'] / GIB, 2) for k, v in m['runs'].items() if 'labrepo' in k}
    say('  census sees trees: %s available=%.1f GiB' % (seen, m['available_bytes'] / GIB))
    check('real process trees attributed to their runs', seen.get('no-mistakes:labrepo/heavy', 0) > 3.5 and seen.get('no-mistakes:labrepo/light', 0) > 1.5)
    A = m['available_bytes']
    # Capped B = A + 2 GiB; uncapped B = A + 6 GiB. need sits at A + 4 GiB: only a capped rule waits.
    S = A + 4 * GIB - 3 * R
    calibrate(LAB, peaks_for(R, S))
    p = lab.direct('capped', LAB_HOLD=60)
    check('start waits: excess above R is not free memory', wait_log(p, 'pipeline-start waiting', 15))
    show(p)
    line = [l for l in log_text(p).splitlines() if 'waiting' in l][-1]
    f = fields(line)
    say('  need=%.2f budget=%.2f GiB; budget - available at census = %.2f GiB (capped credit is 2.0, uncapped 6+)' % (int(f['need']) / GIB, int(f['budget']) / GIB, (int(f['budget']) - A) / GIB))
    check('no start launched', lab.start_lines() == [])
    kill(p)
    # Now put need 2 GiB under the capped budget: real held memory is what lets it in.
    fresh = reading()['available_bytes']
    calibrate(LAB, peaks_for(R, fresh + 1 * GIB - 3 * R))
    q = lab.direct('credited', LAB_HOLD=60)
    check('start admitted when held credit makes it fit (need above bare available)', wait_log(q, 'pipeline-start admitted', 15))
    show(q)
    for x in hogs + [q]: kill(x)

def floor():
    say('== floor: idle host with a runaway recorded peak still starts one; backstop line is separate')
    calibrate(LAB, peaks_for(2 * GIB, 900 * GIB))
    lab = Lab('floor')
    p = lab.direct('one', LAB_HOLD=60)
    check('one start admitted with counted=0 although need > budget', wait_log(p, 'pipeline-start admitted', 15))
    show(p)
    line = [l for l in log_text(p).splitlines() if 'admitted' in l][-1]; f = fields(line)
    check('reason shows need above budget', int(f['need']) > int(f['budget']))
    q = lab.direct('two', LAB_HOLD=60)
    check('next start waits once a run is counted', wait_log(q, 'pipeline-start waiting', 15))
    show(q)
    for x in (p, q): kill(x)

def fallback():
    say('== fallback: no usable record uses the old count limit and never refuses')
    a = reading()
    for name, write in (('missing', lambda: (LAB / 'state/.memory-calibration.json').unlink(missing_ok=True)),
                        ('otherhost', lambda: calibrate(LAB, peaks_for(GIB, GIB), host='other-host')),
                        ('otherram', lambda: calibrate(LAB, peaks_for(GIB, GIB), total=a['total_bytes'] * 2)),
                        ('corrupt', lambda: (LAB / 'state/.memory-calibration.json').write_text('{nope')),
                        ('onepeak', lambda: calibrate(LAB, [GIB])),
                        ('onesample', lambda: calibrate(LAB, peaks_for(GIB, GIB), samples=1))):
        write()
        lab = Lab('fb-' + name); lab.seed(5)
        p = lab.direct('fifth', LAB_HOLD=60)
        ok1 = wait_log(p, 'pipeline-start admitted', 15); show(p, name + ' counted=5')
        q = lab.direct('sixth', LAB_HOLD=60)
        ok2 = wait_log(q, 'pipeline-start waiting', 15); show(q, name + ' counted=6')
        check('%s: admitted at 5, waits at 6, basis=fallback' % name, ok1 and ok2 and 'basis=fallback' in log_text(p) and 'limit=6' in log_text(q))
        for x in (p, q): kill(x)

def refuse():
    say('== refuse: unreadable run database refuses with 125 and starts nothing')
    calibrate(LAB, peaks_for(GIB, GIB))
    lab = Lab('refuse-missing'); lab.db.unlink(); [Path(str(lab.db) + s).unlink(missing_ok=True) for s in ('-wal', '-shm')]
    p = lab.duration('missing'); p.wait(30); show(p)
    check('missing db: exit 125, no start', p.returncode == 125 and lab.start_lines() == [])
    lab = Lab('refuse-garbage'); [Path(str(lab.db) + s).unlink(missing_ok=True) for s in ('-wal', '-shm')]; lab.db.write_bytes(b'not a database' * 100)
    p = lab.duration('garbage'); p.wait(30); show(p)
    check('garbage db: exit 125, no start', p.returncode == 125 and lab.start_lines() == [])

def unreadable():
    say('== unreadable: the macOS sandbox really blocks a native reading; the start pauses, even with counted=0')
    calibrate(LAB, peaks_for(GIB, GIB))
    for name, rule, text in (
        ('vm_stat', '(deny process-exec (literal "/usr/bin/vm_stat"))', 'memory:'),
        ('sysctl-tool', '(deny process-exec (literal "/usr/sbin/sysctl"))', 'memory:'),
        ('proc-limit', '(deny sysctl-read (sysctl-name "kern.maxprocperuid"))', 'process limit unreadable')):
        lab = Lab('unread-' + name)
        prefix = ['sandbox-exec', '-p', '(version 1)(allow default)' + rule]
        p = lab.direct('w', prefix=prefix, LAB_HOLD=60)
        ok = wait_log(p, 'pipeline-start waiting', 15); show(p, name)
        check('%s blocked: pauses with named reason, no start' % name, ok and text in log_text(p) and lab.start_lines() == [] and 'admitted' not in log_text(p))
        time.sleep(3)
        check('%s blocked: still paused 3 s later' % name, p.poll() is None and lab.start_lines() == [])
        kill(p)
        # killed while queued: no run; same start reissued without the block admits
        q = lab.duration('again', LAB_HOLD=1)
        check('%s: reissued start after a queued kill admits' % name, wait_log(q, 'pipeline-start admitted', 20))
        kill(q)

def noload():
    say('== noload: the load average really cannot be read (sandbox); head admits, base refuses')
    calibrate(LAB, peaks_for(GIB, GIB))
    prefix = ['sandbox-exec', '-p', '(version 1)(allow default)(deny sysctl-read (sysctl-name "vm.loadavg"))']
    probe = subprocess.run(prefix + ['python3', '-c', 'import os; os.getloadavg()'], capture_output=True, text=True)
    say('  proof the block works: %s' % probe.stderr.strip().splitlines()[-1])
    lab = Lab('noload-head'); p = lab.direct('head', prefix=prefix, LAB_HOLD=1)
    check('head admits with no load reading', wait_log(p, 'pipeline-start admitted', 15)); show(p); kill(p)
    labb = Lab('noload-base'); q = labb.direct('base', root=BASE, prefix=prefix, LAB_HOLD=1); q.wait(20); show(q)
    check('base refuses the same start: exit %s' % q.returncode, q.returncode == 125 and labb.start_lines() == [])
    say('  real host load right now: %s (old limit 36)' % (os.getloadavg(),))

def reattach():
    say('== reattach: a flagless reattach is never queued, even when the host is full')
    calibrate(LAB, peaks_for(200 * GIB, 200 * GIB))
    lab = Lab('reattach'); lab.seed(8)
    w = lab.duration('fresh', LAB_HOLD=1)
    check('a fresh start queues at this reading', wait_log(w, 'pipeline-start waiting', 15))
    p = lab.duration('re', intent=False); p.wait(30)
    check('reattach ran at once and queued nothing: exit %s' % p.returncode, p.returncode == 0 and any(l.split()[1] == 're' for l in lab.start_lines()) and 'pipeline-start' not in log_text(p))
    check('reattach added no run', lab.counted() == 8)
    r = lab.launch('rerun', ['python3', str(HEAD / 'bin/fm-duration.py'), 'run', 'lab.rerun', '--', 'no-mistakes', 'rerun'])
    check('no-mistakes rerun queues as a fresh start', wait_log(r, 'pipeline-start waiting', 15)); show(r); kill(r)
    kill(w)

def roots():
    say('== roots: a secondmate home and a worker with only FM_DURATION_HOME read the root home record')
    calibrate(LAB, peaks_for(1.5 * GIB, 3 * GIB))
    child = SCRATCH / 'child-home'; (child / 'state').mkdir(parents=True)
    (child / '.fm-secondmate-parent').write_text('schema=%s\nroute=local\nparent_home=%s\n' % (os.environ['PARENT_SCHEMA'], LAB))
    lab = Lab('root-child'); lab.env['FM_HOME'] = str(child)
    p = lab.direct('child', LAB_HOLD=1)
    check('secondmate home is measured from the root record', wait_log(p, 'pipeline-start admitted', 15) and 'basis=fallback' not in log_text(p) and 'runs_measured=13' in log_text(p)); show(p, 'secondmate'); kill(p)
    lab = Lab('root-worker'); del lab.env['FM_HOME']; lab.env['FM_DURATION_HOME'] = str(child)
    p = lab.direct('worker', LAB_HOLD=1)
    check('worker without FM_HOME is measured from the root record', wait_log(p, 'pipeline-start admitted', 15) and 'runs_measured=13' in log_text(p)); show(p, 'worker'); kill(p)
    (child / '.fm-secondmate-parent').write_text('schema=broken\n')
    lab = Lab('root-broken'); lab.env['FM_HOME'] = str(child)
    p = lab.direct('broken', LAB_HOLD=1)
    check('broken parent binding takes the fallback', wait_log(p, 'pipeline-start admitted', 15) and 'basis=fallback' in log_text(p)); show(p, 'broken'); kill(p)

def young():
    say('== young: a run still before CI-ready does not pull R down; a large CI-ready peak still sets S')
    state = LAB / 'state'
    path = calibrate(LAB, peaks_for(2 * GIB, 3 * GIB))
    base_runs = json.loads(path.read_text())
    lab = Lab('young'); lab.seed(0)
    q = lab.direct('before', LAB_HOLD=1); wait_log(q, 'pipeline-start admitted', 15); f0 = fields([l for l in log_text(q).splitlines() if 'admitted' in l][-1]); kill(q)
    lab.sql("DELETE FROM runs")
    young_rows = {'y%d' % i: 0 for i in range(8)}
    for run in young_rows:
        lab.sql("INSERT INTO runs (id, repo_id, status) VALUES (?, 'yr', 'running')", run)
        base_runs['runs']['no-mistakes:yr/' + run] = dict(peak_bytes=GIB // 5, samples=2)
    lab.sql("INSERT INTO runs (id, repo_id, status, ci_ready_at) VALUES ('ready', 'yr', 'running', 5)")
    base_runs['runs']['no-mistakes:yr/ready'] = dict(peak_bytes=7 * GIB, samples=2)
    path.write_text(json.dumps(base_runs))
    p = lab.direct('after', LAB_HOLD=1)
    wait_log(p, 'pipeline-start', 15); time.sleep(0.2)
    line = [l for l in log_text(p).splitlines() if 'pipeline-start' in l][-1]; f = fields(line); show(p)
    say('  before: reservation=%.2f slack=%.2f GiB; after: reservation=%.2f slack=%.2f GiB' % (int(f0['reservation']) / GIB, int(f0['slack']) / GIB, int(f['reservation']) / GIB, int(f['slack']) / GIB))
    check('R is not diluted by 8 young low peaks (it may only rise from the CI-ready peak)', int(f['reservation']) >= int(f0['reservation']))
    check('S rises to the CI-ready 7 GiB peak', int(f['slack']) == 7 * GIB)
    kill(p)

def routes():
    say('== routes: worker brief route skips the pool and can defer 75; fm-duration route uses the pool')
    calibrate(LAB, peaks_for(200 * GIB, 200 * GIB))
    lab = Lab('routes'); lab.seed(8)
    cmd = ['bash', str(HEAD / 'bin/fm-mem-guard.sh'), 'run', '--', 'no-mistakes', 'axi', 'run', '--intent', 'lab']
    p = lab.launch('memguard', cmd); p.wait(60)
    say('  memguard route exit=%s output: %s' % (p.returncode, log_text(p).strip()[:200]))
    check('real reading, full host: the mem-guard route still launched, no pool line', p.returncode == 0 and 'pipeline-start' not in log_text(p) and any(l.split()[1] == 'memguard' for l in lab.start_lines()))
    pool = lab.duration('pool', LAB_HOLD=1)
    check('same host: the fm-duration route queues in the pool', wait_log(pool, 'pipeline-start waiting', 15)); show(pool); kill(pool)
    # exit 75: pressure 2 cannot be made safely on this host, so this one line uses the native fixture boundary.
    fx = lab.dir / 'native'; fx.mkdir()
    (fx / 'sysctl').write_text('%d\n2\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' % (128 * GIB))
    (fx / 'vm_stat').write_text('Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages speculative: 100.\nAnonymous pages: 1048576.\nFile-backed pages: 2000000.\nPages purgeable: 100.\nPages occupied by compressor: 32768.\n')
    (fx / 'processes.json').write_text(json.dumps([dict(pid=101, ppid=1, comm='d', started='s', rss_bytes=GIB, fleet=False, run=None)]))
    before = len(lab.start_lines())
    q = lab.launch('memguard75', cmd, FM_MEMORY_FIXTURE_DIR=fx); q.wait(60)
    say('  FIXTURE pressure=2 memguard exit=%s: %s' % (q.returncode, log_text(q).strip()[:220]))
    check('FIXTURE pressure 2: mem-guard route exits 75 and launches nothing', q.returncode == 75 and len(lab.start_lines()) == before)
    r = lab.direct('fixture-pause', FM_MEMORY_FIXTURE_DIR=fx, LAB_HOLD=1)
    check('FIXTURE pressure 2: pool pauses with the reason named', wait_log(r, 'pipeline-start waiting', 15) and 'overload' in log_text(r)); show(r)
    (fx / 'sysctl').write_text('%d\n1\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' % (128 * GIB))
    calibrate(LAB, peaks_for(GIB, GIB))
    time.sleep(0.2)
    lab.sql("UPDATE runs SET status='completed'")
    check('FIXTURE pressure back to 1: the paused start admits with no restart', wait_log(r, 'pipeline-start admitted', 20)); show(r); kill(r)

def highload():
    say('== highload: real load5 above the old limit of 36; head admits a burst of 3, base waits')
    calibrate(LAB, peaks_for(GIB, 2 * GIB))
    for attempt in range(3):
        say('  real load now: %s' % (os.getloadavg(),))
        lab = Lab('hl-head-%d' % attempt); ps = [lab.direct('h%d' % i, LAB_HOLD=30) for i in range(3)]
        labb = Lab('hl-base-%d' % attempt); q = labb.direct('base', root=BASE, LAB_HOLD=30)
        ok = all(wait_log(p, 'pipeline-start admitted', 20) for p in ps)
        waited = wait_log(q, 'pipeline-start waiting', 8)
        for p in ps: show(p, 'head')
        show(q, 'base')
        say('  real load after: %s' % (os.getloadavg(),))
        check('attempt %d: head admitted 3 starts at real load5 above 36' % attempt, ok and all('load' not in log_text(p) for p in ps))
        check('attempt %d: base waited on the same host: %s' % (attempt, waited), waited and 'load5=' in log_text(q) and labb.start_lines() == [])
        for p in ps + [q]: kill(p)
        break

ALL = dict(highload=highload, burst=burst, budget=budget, held=held, floor=floor, fallback=fallback, refuse=refuse, unreadable=unreadable,
           noload=noload, reattach=reattach, roots=roots, young=young, routes=routes)
try:
    for name in WANT or ALL:
        try:
            ALL[name]()
        except Exception as exc:
            import traceback; traceback.print_exc(file=sys.stdout)
            check('%s driver error %s' % (name, exc), False)
        finally:
            for c in children: kill(c)
            children.clear()
finally:
    for c in children: kill(c)
say(); say('SUMMARY: %d checks, %d failed' % (len(RESULTS), sum(not ok for _, ok in RESULTS)))
for label, ok in RESULTS:
    if not ok: say('  FAILED: ' + label)
