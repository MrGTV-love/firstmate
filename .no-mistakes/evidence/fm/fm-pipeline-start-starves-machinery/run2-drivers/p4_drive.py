"""P4(a) holds: each unhealthy fact holds a fresh start (COMMAND not run); turning it healthy admits it by itself."""
import os, sys, signal, time
sys.path.insert(0, os.environ['FIXTURE_DIR'])
import fm_cpu_pass_fixture as fx
from fm_cpu_pass_fixture import *  # noqa
GIB = fx.GIB
holds = [
  ('native pressure 2', lambda f: facts(f, pressure=2), lambda f: facts(f)),
  ('native pressure 4', lambda f: facts(f, pressure=4), lambda f: facts(f)),
  ('memory reading error', lambda f: facts(f, broken=True), lambda f: facts(f)),
  ('process count unreadable', lambda f: procs(f, error=True), lambda f: procs(f)),
  ('process count above warning line', lambda f: procs(f, count=10660, limit=10666), lambda f: procs(f)),
]
for i, (name, bad, good) in enumerate(holds):
    folder, db, env = case('hold-%d' % i, measured=True)
    bad(folder)
    marker = folder / 'ran'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'h')
    t = time.monotonic()
    while child.poll() is None and 'waiting' not in (folder / 'h.stderr').read_text() and time.monotonic() - t < 60: time.sleep(0.1)
    time.sleep(3)
    held = child.poll() is None and not marker.exists()
    waitline = next((l for l in (folder / 'h.stderr').read_text().splitlines() if 'waiting' in l), '(no waiting line)')
    good(folder)
    t = time.monotonic()
    while child.poll() is None and time.monotonic() - t < 60: time.sleep(0.1)
    rc = child.poll(); after = time.monotonic() - t
    if rc is None: os.killpg(child.pid, signal.SIGTERM); child.wait()
    print('=== hold: %s' % name)
    print('  held 3 s+ with COMMAND not run: %s' % held)
    print('  ' + waitline[:260])
    print('  fact made healthy -> exit=%s after %.1fs, COMMAND ran=%s (no signal or human act)' % (rc, after, marker.exists()))
    print()
# control: all healthy -> admitted at once
folder, db, env = case('control', measured=True)
c = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'ran')], env, folder / 'h'); c.wait()
print('=== control (all facts healthy): exit=%s COMMAND ran=%s' % (c.returncode, (folder / 'ran').exists()))
print('  ' + (folder / 'h.stderr').read_text().splitlines()[0][:200])
fx.cleanup()
