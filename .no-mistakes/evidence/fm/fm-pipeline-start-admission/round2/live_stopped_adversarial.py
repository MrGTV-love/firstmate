#!/usr/bin/env python3
"""Adversarial cases for the stopped-WAL read. Real CLI, native cores and load, private HOME.
Writers use the real-schema file through sqlite3. argv: LAB REPO TEMPLATE PY"""
import hashlib, json, os, pathlib, shutil, signal, sqlite3, subprocess, sys, time
lab, repo, tmpl, py = pathlib.Path(sys.argv[1]) / 'adv', sys.argv[2], sys.argv[3], sys.argv[4]
shutil.rmtree(lab, ignore_errors=True); lab.mkdir()
cores = os.cpu_count(); limit = max(1, cores // 3)
print('native cores', cores, 'limit', limit, 'load5', os.getloadavg()[1], 'python', py)
fails = []
def check(name, ok, detail=''):
    print(('PASS ' if ok else 'FAIL ') + name + (' :: ' + detail if detail else ''), flush=True)
    if not ok: fails.append(name)
class C:
    def __init__(s, name):
        s.d = lab / name; s.d.mkdir(); s.home = s.d / 'home'; s.nm = s.home / '.no-mistakes'; s.nm.mkdir(parents=True)
        s.db = s.nm / 'state.sqlite'; shutil.copy(tmpl, s.db); s.rows = 0
        s.env = {'HOME': str(s.home), 'PATH': str(pathlib.Path(py).parent) + ':/usr/bin:/bin', 'FM_DURATION_FILE': 'off'}
        w = sqlite3.connect(s.db, isolation_level=None); w.execute("INSERT OR IGNORE INTO repos (id, working_path, upstream_url, created_at) VALUES ('r','/l','u',1)"); s.stop(w)
    def stop(s, w):
        w.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall(); w.close()
        for x in ('-wal', '-shm'): pathlib.Path(str(s.db) + x).unlink(missing_ok=True)
    def ins(s, w, n, status='running'):
        for _ in range(n):
            s.rows += 1
            w.execute("INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at) VALUES (?, 'r','b','h','b',?,1,1)", ('x%d' % s.rows, status))
    def seed(s, n):
        w = sqlite3.connect(s.db, isolation_level=None); s.ins(w, n); s.stop(w)
    def go(s, m, *pre):
        return subprocess.Popen(['bash', repo + '/bin/fm-cpu-pass.sh', 'pipeline-start', '--', *pre, 'touch', str(s.d / m)], env=s.env, stderr=subprocess.PIPE, text=True, start_new_session=True)
    def files(s): return sorted(p.name for p in s.nm.iterdir())
def ran(c, m, timeout=30):
    p = c.go(m); err = p.communicate(timeout=timeout)[1]; return p.returncode, (c.d / m).exists(), err.strip().splitlines()[-1] if err.strip() else ''
def queued(p, c, m, secs=3):
    time.sleep(secs); return p.poll() is None and not (c.d / m).exists()
def kill(p):
    try: os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError: pass
    p.wait()

c = C('below'); c.seed(limit - 1); h = hashlib.sha256(c.db.read_bytes()).hexdigest(); f = c.files()
r = ran(c, 'm'); check('stopped database, count below limit: admits with the true count', r[0] == 0 and r[1] and 'counted=%d limit=%d ' % (limit - 1, limit) in r[2], str(r))
check('stopped database read writes no byte and adds no state file', hashlib.sha256(c.db.read_bytes()).hexdigest() == h and c.files() == f, str(c.files()))

c = C('at'); c.seed(limit); p = c.go('m'); q = queued(p, c, 'm'); check('stopped database, count at limit: queues', q)
w = sqlite3.connect(c.db, isolation_level=None); w.execute("UPDATE runs SET status='completed' WHERE id='x1'"); 
rc = p.wait(timeout=30); check('live writer frees one count: queued start admits', rc == 0 and (c.d / 'm').exists(), p.stderr.read().strip().splitlines()[-1]); w.close()

c = C('walonly'); w = sqlite3.connect(c.db, isolation_level=None); w.execute('PRAGMA wal_autocheckpoint=0').fetchall(); c.ins(w, limit)
main_rows = subprocess.run(['true']); p = c.go('m'); q = queued(p, c, 'm'); check('rows only in a live -wal file count: start queues, main file not used alone', q); kill(p); w.close()

c = C('unreadwal'); w = sqlite3.connect(c.db, isolation_level=None); w.execute('PRAGMA wal_autocheckpoint=0').fetchall(); c.ins(w, limit)
wal = pathlib.Path(str(c.db) + '-wal'); wal.chmod(0); r = ran(c, 'm'); wal.chmod(0o600); check('unreadable -wal holding the rows: refuses, no work', r[0] == 125 and not r[1], str(r)); w.close()

c = C('dangling'); os.symlink('/nonexistent/x', str(c.db) + '-wal'); r = ran(c, 'm'); check('dangling -wal symlink: refuses, no work', r[0] == 125 and not r[1], str(r))

c = C('wal-no-shm'); w = sqlite3.connect(c.db, isolation_level=None); w.execute('PRAGMA wal_autocheckpoint=0').fetchall(); c.ins(w, limit)
# Copy the crash shape: -wal with rows, no -shm, no live connection.
crash = C('wal-no-shm-copy'); shutil.copy(c.db, crash.db); shutil.copy(str(c.db) + '-wal', str(crash.db) + '-wal'); w.close()
r = None; p = crash.go('m'); time.sleep(3)
if p.poll() is None: outcome = 'queued'; kill(p)
else: outcome = 'exit %d' % p.returncode
check('-wal with no -shm (crash shape), unread rows: never a start from the main file', not (crash.d / 'm').exists(), outcome + ' files ' + str(crash.files()))

c = C('missing'); c.db.unlink(); r = ran(c, 'm'); check('missing database: refuses, creates nothing', r[0] == 125 and not r[1] and not c.db.exists() and 'state.sqlite' not in c.files(), str(r))
c = C('missing-wal'); c.db.unlink(); pathlib.Path(str(c.db) + '-wal').write_bytes(b''); r = ran(c, 'm'); check('missing database with stray -wal: refuses', r[0] == 125 and not r[1], str(r))
c = C('garbage'); c.db.write_text('not a database at all, nothing here'); r = ran(c, 'm'); check('garbage database with no side files: refuses', r[0] == 125 and not r[1], str(r))
c = C('noread'); c.db.chmod(0); r = ran(c, 'm'); c.db.chmod(0o644); check('unreadable database with no side files: immutable read also refuses', r[0] == 125 and not r[1], str(r))
c = C('dir'); c.db.unlink(); c.db.mkdir(); r = ran(c, 'm'); check('database path is a directory: refuses', r[0] == 125 and not r[1], str(r))
c = C('norows'); c.db.unlink(); x = sqlite3.connect(c.db); x.execute('PRAGMA journal_mode=WAL'); x.execute('CREATE TABLE other (id TEXT)'); x.close()
for s in ('-wal', '-shm'): pathlib.Path(str(c.db) + s).unlink(missing_ok=True)
r = ran(c, 'm'); check('stopped WAL database with no runs table: refuses', r[0] == 125 and not r[1], str(r))
c = C('oldschema'); c.db.unlink(); x = sqlite3.connect(c.db); x.execute('PRAGMA journal_mode=WAL'); x.execute('CREATE TABLE runs (id TEXT, status TEXT)'); x.close()
for s in ('-wal', '-shm'): pathlib.Path(str(c.db) + s).unlink(missing_ok=True)
r = ran(c, 'm'); check('stopped WAL database with old schema: refuses', r[0] == 125 and not r[1], str(r))

c = C('rodir'); c.seed(limit); c.nm.chmod(0o555); p = c.go('m'); q = queued(p, c, 'm'); kill(p); c.nm.chmod(0o755); check('read-only state directory, stopped database, full count: queues on the true count', q)

c = C('symlink'); c.seed(limit); real = c.d / 'real'; real.mkdir(); shutil.move(str(c.db), real / 'state.sqlite'); os.symlink(real / 'state.sqlite', c.db)
p = c.go('m'); q = queued(p, c, 'm'); kill(p); check('symlinked stopped database, full count: queues', q)
w = sqlite3.connect(real / 'state.sqlite', isolation_level=None); w.execute('PRAGMA wal_autocheckpoint=0').fetchall(); w.execute("UPDATE runs SET status='completed'")
wal = pathlib.Path(str(real / 'state.sqlite') + '-wal'); wal.chmod(0); r = ran(c, 'm2'); wal.chmod(0o600); check('symlinked database, unreadable -wal at the real path: refuses', r[0] == 125 and not r[1], str(r)); w.close()

# Starts with a stopped daemon cannot overrun: each client registers then holds a real open connection or closes it.
for keep in (True, False):
    c = C('burst-keep' if keep else 'burst-close'); shim = c.d / 'client.py'
    shim.write_text('''import os, sqlite3, sys, time, pathlib
d = pathlib.Path(sys.argv[1]); n = sys.argv[2]; keep = sys.argv[3] == '1'
time.sleep(0.3)
w = sqlite3.connect(os.path.expanduser('~/.no-mistakes/state.sqlite'), timeout=20, isolation_level=None)
w.execute("INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at) VALUES (?, 'r','b','h','b','running',1,1)", (n,))
(d / (n + '.started')).touch()
if not keep: w.close()
while not (d / (n + '.go')).exists(): time.sleep(0.05)
''')
    procs = {('n%d' % i): subprocess.Popen(['bash', repo + '/bin/fm-cpu-pass.sh', 'pipeline-start', '--', py, str(shim), str(c.d), 'n%d' % i, '1' if keep else '0'], env=c.env, stderr=subprocess.DEVNULL, start_new_session=True) for i in range(limit + 4)}
    time.sleep(6)
    started = sorted(p.stem for p in c.d.glob('*.started'))
    check('burst of %d starts from a stopped database, client %s connection: exactly limit start, none refused' % (limit + 4, 'keeps' if keep else 'closes'),
          len(started) == limit and all(p.poll() is None for p in procs.values()), str(started))
    # Drain in order; all must end 0 with count staying within limit at each grant.
    done = set()
    while len(done) < len(procs):
        now = sorted(p.stem for p in c.d.glob('*.started'))
        for n in now:
            if n not in done:
                (c.d / (n + '.go')).touch(); procs[n].wait(timeout=30); done.add(n)
                x = sqlite3.connect(c.db, timeout=20, isolation_level=None); x.execute("UPDATE runs SET status='completed' WHERE id=?", (n,)); x.close()
        time.sleep(0.2)
    check('burst drains to all exit 0', all(p.returncode == 0 for p in procs.values()), str({k: p.returncode for k, p in procs.items()}))
print('FAILED:', fails or 'none'); sys.exit(1 if fails else 0)
