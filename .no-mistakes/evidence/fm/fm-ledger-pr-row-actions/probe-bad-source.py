#!/usr/bin/env python3
"""Probe: a hand-damaged ledger row whose `source` is not an object. Usage: probe-bad-source.py LABEL BIN_DIR"""
import datetime as dt, json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path
label, bin_dir = sys.argv[1], Path(sys.argv[2])
world = Path(tempfile.mkdtemp(prefix='fm-bad-source.'))
code, home = world / 'code', world / 'home'
shutil.copytree(bin_dir, code / 'bin')
for d in ('state', 'config', 'data'):
    (home / d).mkdir(parents=True)
now = int(time.time())
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_SUPERVISION_ACTOR='main',
           FM_TEST_SEAM='1', FM_TEST_HARNESS='codex')
for k in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_OPEN_LOOPS_NOW'):
    env.pop(k, None)
for bad in ('a string', None, ['x'], 7, {'task': 5}, {'task': ['w']}):
    row = dict(id='row-x', category='open_pr', subject='worker:q', owner='worker:worker', next_action='go',
               age_seconds=7200, limit_seconds=3600, overdue=True, evidence='e', source=bad)
    (home / 'state/open-loops.json').write_text(json.dumps(dict(schema='fm-open-loops.v1', generated_epoch=now,
                                                                complete=True, rows=[row])))
    run = lambda *a: subprocess.run([str(x) for x in a], env=dict(env, FM_OPEN_LOOPS_NOW=str(now)), text=True, capture_output=True)
    run('bash', '-c', '. "$1"; fm_wake_append check report "check: r"', '_', code / 'bin/fm-wake-lib.sh')
    presented = run(code / 'bin/fm-wake-drain.sh')
    assert presented.stdout.startswith('OVERDUE:'), (presented.stdout, presented.stderr)
    sent = dt.datetime.fromtimestamp(now + 5, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    inbox = home / 'state/worker.inbox'
    inbox.mkdir(exist_ok=True)
    (inbox / '001.msg').write_text(f'schema=fm-task-inbox.v1\nat={sent}\n--\nhi\n')
    done = subprocess.run([str(code / 'bin/fm-open-loops.sh'), 'action', 'row-x', 'steered', '--evidence', '001.msg'],
                          env=dict(env, FM_OPEN_LOOPS_NOW=str(now + 10)), text=True, capture_output=True)
    tb = 'Traceback' in done.stderr
    print(f'{label}: source={bad!r:14} rc={done.returncode} traceback={tb} out={(done.stdout + done.stderr).strip().splitlines()[-1][:120] if (done.stdout + done.stderr).strip() else ""}')
shutil.rmtree(world, ignore_errors=True)
