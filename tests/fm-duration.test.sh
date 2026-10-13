#!/usr/bin/env bash
# Public CLI regressions for measured limits, progress-based command lifetime,
# durable repeated-timeout ownership, and the new-literal lint guard.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-duration)
export FM_DURATION_TEST_ROOT="$ROOT" FM_DURATION_TEST_TMP="$TMP_ROOT"
"$ROOT/bin/fm-proc-budget.sh" -- python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import subprocess
import sys

root = Path(os.environ['FM_DURATION_TEST_ROOT'])
tmp = Path(os.environ['FM_DURATION_TEST_TMP'])
helper = root / 'bin/fm-duration.py'
ledger = tmp / 'durations.jsonl'
env = dict(os.environ, FM_DURATION_FILE=str(ledger), FM_HOME=str(tmp), FM_DATA_OVERRIDE=str(tmp / 'data'), FM_CONFIG_OVERRIDE=str(tmp / 'config'), FM_STATE_OVERRIDE=str(tmp / 'state'))
for name in ('data', 'config', 'state'):
    (tmp / name).mkdir()
(tmp / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')


def cli(*args, expected=0, tool=helper):
    result = subprocess.run([sys.executable, str(tool), *map(str, args)], env=env, capture_output=True, text=True)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result


def rows():
    return [json.loads(line) for line in ledger.read_text().splitlines()]


cold = cli('limit', 'lint.full.whole', '--fallback', 30)
assert cold.stdout.strip() == '30' and 'missing idle, loaded' in cold.stderr
assert cli('limit', 'uncalibrated').stdout.strip() == '0'
cli('record', 'sample', 42, 0, '--sample-id', 'once')
cli('record', 'sample', 42, 0, '--sample-id', 'once')
assert len([r for r in rows() if r.get('sample_id') == 'once']) == 1
assert rows()[0]['host'] == platform.node() and rows()[0]['duration_ms'] == 42

# Independent timing-table fixture: two distinct load regimes, exact ranks,
# failed/censored samples, and another host must not bias this host's limits.
observations = []
for regime, multiplier in [('idle', 1), ('loaded', 2)]:
    for index in range(1, 101):
        observations.append(dict(host=platform.node(), key='rank', regime=regime, duration_ms=index * multiplier * 1000, exit=0))
observations.extend([
    dict(host='another-host', key='rank', regime='loaded', duration_ms=999999999, exit=0),
    dict(host=platform.node(), key='rank', regime='loaded', duration_ms=999999999, exit=124),
    dict(host=platform.node(), key='rank', regime='loaded', duration_ms=1, exit=1),
])
with ledger.open('a') as output:
    for row in observations:
        output.write(json.dumps(row) + '\n')
assert cli('limit', 'rank', '--margin', 2).stdout.strip() == '380'
assert cli('limit', 'rank', '--percentile', 99, '--margin', 2).stdout.strip() == '396'
cli('limit', 'rank', '--margin', 'nan', expected=2)
cli('limit', 'rank', '--fallback', -1, expected=2)

failed = cli('run', 'consumer.failure', '--', sys.executable, '-c', 'import sys; print("stdout-result"); print("stderr-result", file=sys.stderr); sys.exit(7)', expected=7)
assert failed.stdout == 'stdout-result\n' and 'stderr-result' in failed.stderr
assert 'output_bytes=' in failed.stderr and rows()[-1]['exit'] == 7

# Simulate a read returning while a real background command remains alive.
# A sentinel controls completion, not a guessed sleep duration.
release = tmp / 'release'
code = 'import pathlib,sys; print("started", flush=True); p=pathlib.Path(sys.argv[1]);\nwhile not p.exists(): pass\nprint("completed", flush=True)'
job = subprocess.Popen([sys.executable, str(helper), 'run', 'progress.handshake', '--', sys.executable, '-c', code, str(release)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
assert job.stdout.readline() == 'started\n'
assert job.poll() is None, 'the initial read must not stop the running job'
release.touch()
out, err = job.communicate()
assert job.returncode == 0 and out == 'completed\n' and 'progress:' in err
assert rows()[-1]['key'] == 'progress.handshake' and rows()[-1]['exit'] == 0

# Cancellation is a real signal result, not a telemetry or dead-group error.
cancel = subprocess.Popen([sys.executable, str(helper), 'run', 'consumer.cancel', '--', sys.executable, '-c', 'print("started", flush=True)\nwhile True: pass'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
assert cancel.stdout.readline() == 'started\n'
cancel.terminate()
cancel_out, cancel_err = cancel.communicate()
assert cancel.returncode == 143 and cancel_out == '', (cancel.returncode, cancel_out, cancel_err)

# A calibrated outer ceiling, derived from measured-table fixtures, really
# terminates an ongoing command rather than just returning from a read wait.
with ledger.open('a') as output:
    for regime in ('idle', 'loaded'):
        output.write(json.dumps(dict(host=platform.node(), key='outer', regime=regime, duration_ms=1, exit=0)) + '\n')
cli('run', 'outer', '--', sys.executable, '-c', 'while True: pass', expected=124)
assert any(r.get('event') == 'timeout' and r['key'] == 'outer' for r in rows())

# Completed no-mistakes step imports are idempotent and historical load is
# explicitly unknown, never relabeled as today's calibration evidence.
database = tmp / 'nm.sqlite'
with sqlite3.connect(database) as db:
    db.execute('CREATE TABLE step_results(id TEXT, run_id TEXT, step_name TEXT, duration_ms INTEGER, exit_code INTEGER, completed_at INTEGER)')
    db.executemany('INSERT INTO step_results VALUES(?,?,?,?,?,?)', [('s1','r1','review',10000,0,1), ('s2','r2','review',50000,0,1), ('s3','r1','test',10000,0,None)])
cli('import-nm', database, 'r1')
cli('import-nm', database, 'r1')
imports = [r for r in rows() if r.get('key') == 'no-mistakes.review']
assert len(imports) == 1 and imports[0]['duration_ms'] == 10000 and imports[0]['regime'] == 'unknown'
assert cli('limit', 'no-mistakes.review', '--fallback', 30).stdout.strip() == '30'

if shutil.which('tasks-axi'):
    key = 'repeat.consumer'
    task = 'fm-timeout-' + hashlib.sha256((platform.node() + '\0' + key).encode()).hexdigest()[:16]
    wrapper = root / 'bin/fm-tasks-axi.sh'
    cli('timeout', key, 120000, '--event-id', 'first')
    before = subprocess.run([str(wrapper), 'show', task, '--full'], env=env, capture_output=True, text=True)
    assert before.returncode != 0
    cli('timeout', key, 120000, '--event-id', 'first')
    cli('timeout', key, 1200000, '--event-id', 'second')
    cli('timeout', key, 1300000, '--event-id', 'third')
    after = subprocess.run([str(wrapper), 'show', task, '--full'], env=env, capture_output=True, text=True, check=True)
    assert '120000' in after.stdout and '1200000' in after.stdout
    assert len([r for r in rows() if r.get('event') == 'filed' and r.get('key') == key]) == 1
    assert len([r for r in rows() if r.get('event') == 'timeout' and r.get('key') == key]) == 3
    print('ok - real backlog owns the second timeout exactly once')
else:
    print('skip: tasks-axi not found (repeated-timeout publication)')

# An interrupted publication must remain retryable after samples were imported.
# Use a real incompatible backlog path, then repair that prerequisite; no
# fake tasks-axi response can hide the durable retry bug.
if shutil.which('tasks-axi'):
    retry_home = tmp / 'retry-home'
    for directory in ('data', 'config', 'state'):
        (retry_home / directory).mkdir(parents=True)
    retry_backlog = retry_home / 'data/backlog.md'
    retry_backlog.mkdir()
    original_env = env
    env = dict(env, FM_HOME=str(retry_home), FM_DATA_OVERRIDE=str(retry_home / 'data'), FM_CONFIG_OVERRIDE=str(retry_home / 'config'), FM_STATE_OVERRIDE=str(retry_home / 'state'))
    with sqlite3.connect(database) as db:
        db.executemany('INSERT INTO step_results VALUES(?,?,?,?,?,?)', [('retry1','retry-run','retry',10000,124,1), ('retry2','retry-run','retry',20000,124,1)])
    cli('import-nm', database, 'retry-run', expected=1)
    assert len([r for r in rows() if r.get('key') == 'no-mistakes.retry' and 'exit' in r]) == 2
    assert not any(r.get('key') == 'no-mistakes.retry' and r.get('event') == 'filed' for r in rows())
    retry_backlog.rmdir()
    retry_backlog.write_text('## In flight\n\n## Queued\n\n## Done\n')
    cli('import-nm', database, 'retry-run')
    assert len([r for r in rows() if r.get('key') == 'no-mistakes.retry' and 'exit' in r]) == 2
    assert len([r for r in rows() if r.get('key') == 'no-mistakes.retry' and r.get('event') == 'timeout']) == 2
    assert len([r for r in rows() if r.get('key') == 'no-mistakes.retry' and r.get('event') == 'filed']) == 1
    assert retry_backlog.read_text().count('- [ ] fm-timeout-') == 1
    env = original_env
    print('ok - repeated pipeline imports recover failed backlog publication without duplicating samples or events')

# The guard runs as a real CLI over a committed baseline and current files.
repo = tmp / 'literal-repo'
(repo / 'bin').mkdir(parents=True)
guard = repo / 'bin/fm-duration.py'
shutil.copyfile(helper, guard)
source = repo / 'bin/example.sh'
source.write_text('#!/bin/bash\nEXISTING_TIMEOUT=15\n')
subprocess.run(['git','init','-q',str(repo)], check=True)
subprocess.run(['git','-C',str(repo),'add','.'], check=True)
subprocess.run(['git','-C',str(repo),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','baseline'], check=True)
source.write_text('#!/bin/bash\n# relocated existing limit\nEXISTING_TIMEOUT=15\nNEW_TIMEOUT=12\n')
assert 'new time limit 12' in cli('check-literals','--base','HEAD',expected=1,tool=guard).stdout
source.write_text('#!/bin/bash\nEXISTING_TIMEOUT=15\n# measured: value=12 date=2026-10-12 host=fixture margin=3\nNEW_TIMEOUT=12\n')
cli('check-literals','--base','HEAD',tool=guard)
source.write_text('#!/bin/bash\n# measured: value=11 date=2026-10-12 host=fixture margin=3\nNEW_TIMEOUT=12\n')
cli('check-literals','--base','HEAD',expected=1,tool=guard)
source.write_text('#!/bin/bash\nEXISTING_TIMEOUT=15\nEXISTING_TIMEOUT=15\n')
cli('check-literals','--base','HEAD',expected=1,tool=guard)
source.write_text('#!/bin/bash\nEXISTING_TIMEOUT=16\n')
cli('check-literals','--base','HEAD',expected=1,tool=guard)
report = cli('check-literals','--report',tool=guard).stdout
assert 'bin/example.sh:2\t16\t' in report
print('ok - measured ranks, cold fallback, progress, outer ceiling, pipeline imports and literal guard')
PY
pass "measured command behavior"
