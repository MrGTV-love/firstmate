#!/usr/bin/env python3
"""Adversarial timing: real admission CLI polling while the REAL binary opens and
closes the real-schema WAL database (real daemon stop/start, real stats).
Any 125 here is a fresh start that loses its turn without a real source problem.
argv: LAB REPO PYDIR SECONDS"""
import collections, os, pathlib, shutil, subprocess, sys, threading, time
lab, repo, pydir, secs = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], float(sys.argv[4])
BIN = '/Users/charlesabrooker/.no-mistakes/bin/no-mistakes'
t = lab / 'stress'; shutil.rmtree(t, ignore_errors=True)
h = t / 'home'; nm = h / '.no-mistakes'; nm.mkdir(parents=True); (t / 'repo').mkdir()
subprocess.run(['git', 'init', '-q', '.'], cwd=t / 'repo')
env = {'HOME': str(h), 'NM_HOME': str(nm), 'PATH': pydir + ':/usr/bin:/bin'}
def real(*a, **k): return subprocess.run([BIN, *a], env=env, cwd=t / 'repo', capture_output=True, text=True, **k)
real('stats')
stop = threading.Event()
tally, msgs = collections.Counter(), collections.Counter()
def attempts():
    n = 0
    while not stop.is_set():
        n += 1
        m = t / ('m%d' % (n % 7))
        p = subprocess.run(['bash', repo + '/bin/fm-cpu-pass.sh', 'pipeline-start', '--', 'touch', str(m)], env=env, capture_output=True, text=True)
        tally[p.returncode] += 1
        for line in p.stderr.splitlines():
            if 'refused' in line: msgs[line] += 1
threads = [threading.Thread(target=attempts) for _ in range(1)]
[x.start() for x in threads]
cycles = stats = 0
until = time.monotonic() + secs
while time.monotonic() < until:
    d = subprocess.Popen(['perl', '-e', 'alarm 30; exec @ARGV', BIN, 'daemon', 'run'], env=env, cwd=t / 'repo', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if 'daemon running' in real('daemon', 'status').stdout: break
        time.sleep(0.05)
    real('daemon', 'stop', '--force'); d.wait(); cycles += 1
    for _ in range(3):
        real('stats'); stats += 1
stop.set(); [x.join() for x in threads]
print('daemon stop/start cycles', cycles, 'real stats calls', stats)
print('admission exit tally', dict(tally))
print('refusals', dict(msgs) or 'none')
print('state files', sorted(p.name for p in nm.glob('state*')))
