"""P6 adversarial shapes + cross-wrapper class order. argv: REPO PARENT PYTHON."""
import os, sys, signal, time
sys.path.insert(0, os.environ['FIXTURE_DIR'])
import fm_cpu_pass_fixture as fx
from fm_cpu_pass_fixture import *  # noqa
GIB = fx.GIB
fx.HANG_BACKSTOP_SECS = 90
import atexit; atexit.register(fx.cleanup)
nm = fx.root / 'nmbin'; nm.mkdir()
(nm / 'no-mistakes').write_text('#!/bin/sh\necho "client ran: no-mistakes $*" >> "$CASE_FOLDER/client.log"\nexit ${CLIENT_EXIT:-0}\n')
(nm / 'no-mistakes').chmod(0o755)
intent = fx.root / 'intent.txt'; intent.write_text('goal\n')
repo = fx.repo
dur = lambda *pre: [str(fx.proxy), str(repo / 'bin/fm-duration.py'), 'run'] + list(pre) + ['no-mistakes.x', '--']
guard = ['bash', str(repo / 'bin/fm-mem-guard.sh'), 'run', '--']
absnm = str(nm / 'no-mistakes')
shapes = [
  ('fresh: absolute client path via fm-mem-guard', True, guard + [absnm, 'axi', 'run', '--intent', 'goal']),
  ('fresh: reordered args (--verification-plan before --intent-file=)', True, dur() + ['no-mistakes', 'axi', 'run', '--verification-plan', str(intent), '--intent-file=' + str(intent)]),
  ('fresh: wrapped in env + absolute path via fm-duration', True, dur() + ['env', 'A=1', absnm, 'axi', 'run', '--intent', 'goal']),
  ('reattach: absolute path axi run --wait via fm-duration', False, dur() + [absnm, 'axi', 'run', '--wait', '5m']),
]
for i, (name, fresh, cmd) in enumerate(shapes):
    folder, db, env = case('x-%d' % i, measured=True, available=10 * GIB)
    change(db, "INSERT INTO runs (id, status, repo_id) VALUES ('x', 'running', 'repo')")
    env.update(PATH=str(nm) + os.pathsep + env['PATH'])
    child = launch(cmd, env, folder / 'p6')
    t0 = time.monotonic()
    while child.poll() is None and time.monotonic() - t0 < 8: time.sleep(0.1)
    first = 'ran at once, exit %d' % child.returncode if child.poll() is not None else 'WAITING after 8 s'
    released = ''
    if child.poll() is None:
        change(db, "UPDATE runs SET status='completed' WHERE id='x'")
        t1 = time.monotonic()
        while child.poll() is None and time.monotonic() - t1 < 30: time.sleep(0.1)
        if child.poll() is None:
            released = '; still waiting (SIGTERM)'; os.killpg(child.pid, signal.SIGTERM); child.wait()
        else:
            released = '; after counted run x completed: exit %d in %.1fs' % (child.returncode, time.monotonic() - t1)
    lines = [l[:220] for l in (folder / 'p6.stderr').read_text().splitlines() if 'pipeline-start' in l]
    print('=== %s (expected: %s)' % (name, 'queue then admit' if fresh else 'no queue, run at once'))
    print('outcome: %s%s' % (first, released)); print('gate lines:'); print('\n'.join(lines) if lines else '  (none)'); print()

# exit status pass-through of a no-intent fresh-looking call that the real CLI would reject (exit 2)
folder, db, env = case('x-exit', measured=True)
env.update(PATH=str(nm) + os.pathsep + env['PATH'], CLIENT_EXIT='2')
c = launch(guard + ['no-mistakes', 'axi', 'run'], env, folder / 'p6'); c.wait()
print('=== no-intent axi run through fm-mem-guard, client exits 2 (expected: no queue, exit 2 passes through)')
print('exit=%d gate lines=%s' % (c.returncode, [l for l in (folder / 'p6.stderr').read_text().splitlines() if 'pipeline-start' in l] or '(none)')); print()

# class order across wrappers: 'other' via fm-mem-guard queues first, 'machinery' via fm-duration queues second
folder, db, env = case('x-order', measured=True, available=10 * GIB)
change(db, "INSERT INTO runs (id, status, repo_id) VALUES ('x', 'running', 'repo')")
env.update(PATH=str(nm) + os.pathsep + env['PATH'])
a = launch(guard + ['no-mistakes', 'axi', 'run', '--intent', 'other-run'], env, folder / 'a')
wait_for(lambda: 'waiting' in (folder / 'a.stderr').read_text(), 'other waiting')
b = launch(dur('--pipeline-priority', 'machinery') + ['no-mistakes', 'axi', 'run', '--intent', 'machinery-run'], env, folder / 'b')
wait_for(lambda: 'waiting' in (folder / 'b.stderr').read_text(), 'machinery waiting')
time.sleep(1.5)
change(db, "UPDATE runs SET status='completed' WHERE id='x'")
a.wait(); b.wait()
print('=== class order across wrappers (other queued first via fm-mem-guard; machinery second via fm-duration)')
print('exits: other=%d machinery=%d' % (a.returncode, b.returncode))
print('client order:'); print((folder / 'client.log').read_text().rstrip())
for n in 'ab':
    for l in (folder / (n + '.stderr')).read_text().splitlines():
        if 'pipeline-start' in l: print('  %s: %s' % (n, l[:200]))
fx.cleanup()
