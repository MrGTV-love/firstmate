#!/usr/bin/env python3
"""Reproduce the P5(d) cancel case live: one survivor start queued, then N merge-train starts each
cancelled by SIGINT to its process group as soon as its waiter entry is live. Each must exit 130
within 10 s and the survivor must stay queued. usage: sigint_loop.py REPO SANDBOX N MODE(measured|fallback)"""
import fcntl, os, signal, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import importlib.util
spec = importlib.util.spec_from_file_location('drv', str(Path(__file__).with_name('live_driver.py')))
repo, sb, n, mode = Path(sys.argv[1]).resolve(), Path(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
sys.argv = [sys.argv[0], str(repo), str(sb)]
drv = importlib.util.module_from_spec(spec); spec.loader.exec_module(drv)
case, db, env = drv.fresh('sigint-' + mode)
if mode == 'measured':
    drv.calibrate(case)
    drv.sql(db, "INSERT INTO runs (id, repo_id, status) VALUES ('blocker', 'repo', 'running')")
    drv.facts(case, available=10 * drv.GIB)
else:
    for i in range(40):
        drv.sql(db, "INSERT INTO runs (id, repo_id, status) VALUES (?, 'repo', 'running')", ('b%d' % i,))


def live():
    c = 0
    for p in (case / 'pool').glob('pipeline-waiter-*') if (case / 'pool').exists() else []:
        try:
            fd = os.open(str(p), os.O_RDONLY)
        except FileNotFoundError:
            continue
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            c += 1
        finally:
            os.close(fd)
    return c


cli = ['bash', str(repo / 'bin/fm-cpu-pass.sh')]
surv = drv.start(cli + ['pipeline-start', '--', 'touch', str(case / 'survivor')], env, case, 'survivor')
assert drv.until(lambda: live() == 1, 20), 'survivor did not queue'
hangs, codes, worst = 0, {}, 0.0
for i in range(n):
    c = drv.start(cli + ['pipeline-start', '--priority', 'merge-train', '--', 'touch', str(case / 'cancelled')], env, case, 'c%d' % i)
    if not drv.until(lambda: live() == 2, 20):
        print('iteration %d: waiter never registered; exit=%s' % (i, c.poll())); drv.kill(c); continue
    os.killpg(c.pid, signal.SIGINT)
    t = time.monotonic()
    try:
        rc = c.wait(10)
    except subprocess.TimeoutExpired:
        hangs += 1
        ps = subprocess.run(['ps', '-o', 'pid,stat,command', '-g', str(c.pid)], capture_output=True, text=True).stdout
        print('iteration %d: HANG >10 s after SIGINT\n%s\nstderr: %s' % (i, ps, drv.text(case, 'c%d' % i)[-600:]))
        os.killpg(c.pid, signal.SIGKILL); c.wait()
        continue
    worst = max(worst, time.monotonic() - t)
    codes[rc] = codes.get(rc, 0) + 1
    if surv.poll() is not None:
        print('iteration %d: survivor ended early exit=%s' % (i, surv.poll()))
        break
print('repo=%s mode=%s iterations=%d hangs=%d exit_codes=%s worst_exit_secs=%.2f survivor_still_queued=%s cancelled_command_ran=%s' % (
    repo, mode, n, hangs, codes, worst, surv.poll() is None, (case / 'cancelled').exists()))
drv.kill(surv)
