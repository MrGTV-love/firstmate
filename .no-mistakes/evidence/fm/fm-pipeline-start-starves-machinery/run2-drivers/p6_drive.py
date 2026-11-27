"""P6: which call shapes join the pipeline-start queue. argv: REPO PARENT PYTHON LABEL.
World: one counted run 'x' the reading cannot see (reserves full R), R=3 GiB S=8 GiB, 10 GiB available:
a fresh start does not fit and must WAIT; once 'x' completes it must be admitted by itself and run."""
import os, sys, signal, time
label = sys.argv.pop()
sys.path.insert(0, os.environ['FIXTURE_DIR'])
import fm_cpu_pass_fixture as fx
from fm_cpu_pass_fixture import *  # noqa
if label == 'base':
    fx.base.pop('CASE_COALITION_FILE', None); fx.base.pop('CASE_COALITION_ROOT', None)
GIB = fx.GIB
nm = fx.root / 'nmbin'; nm.mkdir()
(nm / 'no-mistakes').write_text('#!/bin/sh\necho "client ran: no-mistakes $*" >> "$CASE_FOLDER/client.log"\nexit 0\n')
(nm / 'no-mistakes').chmod(0o755)
intent = fx.root / 'intent.txt'; intent.write_text('goal\n')
repo = fx.repo
measured = lambda nodash=False: [str(fx.proxy), str(repo / 'bin/fm-duration.py'), 'run', 'no-mistakes.p6'] + ([] if nodash else ['--'])
guard = ['bash', str(repo / 'bin/fm-mem-guard.sh'), 'run', '--']
shapes = [
  ('fresh: fm-duration run K -- axi run --intent', True, measured() + ['no-mistakes', 'axi', 'run', '--intent', 'goal']),
  ('fresh: fm-duration run K (no --) axi run --intent', True, measured(True) + ['no-mistakes', 'axi', 'run', '--intent', 'goal']),
  ('fresh: fm-duration run K -- axi run --intent-file', True, measured() + ['no-mistakes', 'axi', 'run', '--intent-file', str(intent)]),
  ('fresh: fm-mem-guard run -- axi run --intent=goal', True, guard + ['no-mistakes', 'axi', 'run', '--intent=goal']),
  ('fresh: fm-mem-guard run -- axi run --intent - (stdin)', True, guard + ['no-mistakes', 'axi', 'run', '--intent', '-']),
  ('fresh: PR-366 shape fm-duration -- env FM_HOME bash fm-mem-guard.sh run -- axi run --intent-file', True,
       measured() + ['env', 'FM_HOME=HOME'] + guard + ['no-mistakes', 'axi', 'run', '--intent-file', str(intent), '--verification-plan', str(intent)]),
  ('fresh: fm-mem-guard run -- no-mistakes rerun', True, guard + ['no-mistakes', 'rerun']),
  ('reattach: fm-mem-guard run -- axi run --wait 1m', False, guard + ['no-mistakes', 'axi', 'run', '--wait', '1m']),
  ('reattach: fm-duration run K -- axi run', False, measured() + ['no-mistakes', 'axi', 'run']),
  ('other: fm-mem-guard run -- axi respond --action approve', False, guard + ['no-mistakes', 'axi', 'respond', '--action', 'approve']),
  ('other: fm-mem-guard run -- axi status', False, guard + ['no-mistakes', 'axi', 'status']),
  ('other: fm-mem-guard run -- true', False, guard + ['true']),
]
for i, (name, fresh, cmd) in enumerate(shapes):
    folder, db, env = case('p6-%d' % i, measured=True, available=10 * GIB)
    change(db, "INSERT INTO runs (id, status, repo_id) VALUES ('x', 'running', 'repo')")
    env.update(PATH=str(nm) + os.pathsep + env['PATH'])
    cmd = [c.replace('FM_HOME=HOME', 'FM_HOME=' + str(folder / 'fmhome')) for c in cmd]
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
            released = '; still waiting 30 s after x completed (SIGTERM)'; os.killpg(child.pid, signal.SIGTERM); child.wait()
        else:
            released = '; after counted run x completed: exit %d in %.1fs' % (child.returncode, time.monotonic() - t1)
    err = (folder / 'p6.stderr').read_text()
    client = (folder / 'client.log').read_text().strip() if (folder / 'client.log').exists() else '(client never ran)'
    print('=== [%s] %s (expected: %s)' % (label, name, 'queue then admit' if fresh else 'no queue, run at once'))
    print('outcome: %s%s' % (first, released))
    print('client: %s' % client)
    lines = [l[:260] for l in err.splitlines() if 'pipeline-start' in l or 'mem-guard' in l or 'launch' in l]
    print('gate lines:'); print('\n'.join(lines) if lines else '  (none)'); print()
