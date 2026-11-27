"""Drive P1 (a),(b),(c) against the real fm-cpu-pass.sh pipeline-start of REPO in a disposable sandbox.
argv: REPO PARENT PYTHON LABEL"""
import os, sys, signal, time
label = sys.argv.pop()
sys.path.insert(0, sys.argv[4] if len(sys.argv) > 4 else '')
sys.path.insert(0, os.environ['FIXTURE_DIR'])
import fm_cpu_pass_fixture as fx
from fm_cpu_pass_fixture import *  # noqa
GIB = fx.GIB
if label == 'base':
    fx.base.pop('CASE_COALITION_FILE', None); fx.base.pop('CASE_COALITION_ROOT', None)
diag_peaks = [1.0, 2.0, 5.77, 13.39]
diag_active = 1953340270
def steps(db, rows):
    for run, name, status, pid in rows:
        change(db, 'INSERT INTO step_results (id, run_id, step_name, step_order, status, agent_pid) VALUES (?, ?, ?, ?, ?, ?)',
               (run + '-' + name, run, name, 1, status, pid))
def counted_case(name, available, active, waiting_ci=()):
    folder, db, env = case(name, measured=True, available=available, activated=False)
    calibrate(folder, peaks=diag_peaks, active=diag_active)
    for run, _ in active:
        change(db, "INSERT INTO runs (id, status, repo_id) VALUES (?, 'running', 'repo')", (run,))
    for run in waiting_ci:
        change(db, "INSERT INTO runs (id, status, repo_id) VALUES (?, 'running', 'repo')", (run,))
    steps(db, [(run, 'review', 'fixing', 4000 + i) for i, (run, _) in enumerate(active)] +
          [(run, 'ci', 'running', None) for run in waiting_ci])
    for run in waiting_ci:
        try: prove(folder, db, run)
        except Exception as e: print('prove failed', e)
    facts(folder, available=available, runs=[('repo', run, rss) for run, rss in active])
    return folder, db, env
def drive(name, folder, env, cmd, wait=25):
    child = launch(cli + cmd, env, folder / name)
    t0 = time.monotonic()
    while child.poll() is None and time.monotonic() - t0 < wait:
        time.sleep(0.1)
    if child.poll() is None:
        outcome = 'STILL WAITING after %ds (start held; sent SIGTERM)' % wait
        os.killpg(child.pid, signal.SIGTERM); child.wait()
    else:
        outcome = 'exited %d after %.1fs' % (child.returncode, time.monotonic() - t0)
    err = (folder / (name + '.stderr')).read_text()
    print('=== [%s] %s: pipeline-start %s' % (label, name, ' '.join(cmd[1:])))
    print('outcome:', outcome)
    print('stderr:'); print(err.rstrip()); print()
live = [('test-fixing', int(0.70 * GIB)), ('review-a', int(0.43 * GIB)), ('lint', int(2.22 * GIB)),
        ('review-b', int(0.13 * GIB)), ('pr', int(0.13 * GIB)), ('test', int(0.43 * GIB)), ('review-c', int(0.73 * GIB))]
folder, db, env = counted_case('p1a', 32.82 * GIB // 16384 * 16384, live, waiting_ci=['ci-361', 'ci-367', 'ci-369', 'ci-3609'])
drive('p1a', folder, env, ['pipeline-start', '--priority', 'machinery', '--', 'sh', '-c', 'exit 3'])
recorded = [21299200, 118226944, 491290624, 545144832, 574226432, 652591104, 673792000, 1083260928,
            1926561792, 3074097152, 5121441792, 7301611520]
shape = [('run-%02d' % i, rss) for i, rss in enumerate(recorded)]
folder, db, env = counted_case('p1b', 27132805120, shape)
drive('p1b', folder, env, ['pipeline-start', '--', 'sh', '-c', 'exit 0'])
projected = 9 * diag_active + 3074097152 + 5121441792 + 7301611520 + int(13.39 * GIB)
threshold = projected - sum(recorded)
avail_c = threshold // 16384 * 16384 - 16384
print('control available (one page below fit) = %d bytes = %.3f GiB' % (avail_c, avail_c / GIB))
folder, db, env = counted_case('p1c', avail_c, shape)
drive('p1c', folder, env, ['pipeline-start', '--', 'sh', '-c', 'exit 0'], wait=12)
fx.cleanup() if hasattr(fx, 'cleanup') else None
