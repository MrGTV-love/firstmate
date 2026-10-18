#!/usr/bin/env bash
# Public CLI regressions for measured limits, progress-based command lifetime,
# durable repeated-timeout ownership, and the new-literal lint guard.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-duration)
export FM_DURATION_TEST_ROOT="$ROOT" FM_DURATION_TEST_TMP="$TMP_ROOT"
"$ROOT/bin/fm-proc-budget.sh" -- python3 - <<'PY'
import contextlib
import hashlib
import json
import os
import signal
from pathlib import Path
import platform
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import time

root = Path(os.environ['FM_DURATION_TEST_ROOT'])
tmp = Path(os.environ['FM_DURATION_TEST_TMP'])
helper = root / 'bin/fm-duration.py'
ledger = tmp / 'durations.jsonl'
env = dict(os.environ, FM_DURATION_FILE=str(ledger), FM_HOME=str(tmp), FM_DATA_OVERRIDE=str(tmp / 'data'), FM_CONFIG_OVERRIDE=str(tmp / 'config'), FM_STATE_OVERRIDE=str(tmp / 'state'))
for name in ('data', 'config', 'state'):
    (tmp / name).mkdir()
(tmp / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')


def make_repo(name, origin=None):
    path = tmp / name
    path.mkdir()
    subprocess.run(['git', 'init', '-q', str(path)], check=True)
    if origin:
        subprocess.run(['git', '-C', str(path), 'remote', 'add', 'origin', origin], check=True)
    return path


workrepo = make_repo('work-x', 'git@github.com:acme/widgets.git')
REPO = 'acme/widgets'


def cli(*args, expected=0, tool=helper, cwd=None):
    result = subprocess.run([sys.executable, str(tool), *map(str, args)], env=env, cwd=cwd or workrepo, capture_output=True, text=True)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result


def rows():
    return [json.loads(line) for line in ledger.read_text().splitlines()]


def write_rows(rows_to_add, path=None):
    with (path or ledger).open('a') as output:
        for row in rows_to_add:
            output.write(json.dumps(row) + '\n')


def sample(key, duration, code=0, **extra):
    row = dict(host=platform.node(), repo=REPO, key=key, duration_ms=duration, exit=code)
    row.update(extra)
    return row


cold = cli('limit', 'lint.full.whole', '--fallback', 30)
assert cold.stdout.strip() == '30' and '0 of 5 samples' in cold.stderr
assert cli('limit', 'uncalibrated').stdout.strip() == '0'
cli('record', 'sample', 42, 0, '--sample-id', 'once', '--load-start', '1.5')
cli('record', 'sample', 42, 0, '--sample-id', 'once')
assert len([r for r in rows() if r.get('sample_id') == 'once']) == 1
assert rows()[0]['host'] == platform.node() and rows()[0]['duration_ms'] == 42
assert rows()[0]['load_start'] == 1.5 and isinstance(rows()[0]['load_end'], float)
assert cli('path').stdout.strip() == str(ledger)

# Sample-count policy: fewer than five eligible samples keep the caller's bound.
write_rows([sample('few', 1000 * index) for index in range(1, 5)])
few = cli('limit', 'few', '--fallback', 30)
assert few.stdout.strip() == '30' and '4 of 5 samples' in few.stderr

# Independent timing-table fixture: exact ranks over every eligible sample, while
# failed/censored/uncalibrated samples and another host do not bias this host.
write_rows([sample('rank', index * 1000) for index in range(1, 101)] + [
    dict(sample('rank', 999999999), host='another-host'),
    sample('rank', 999999999, 124),
    sample('rank', 1, 1),
    sample('rank', 999999999, calibration=False),
])
assert cli('limit', 'rank', '--margin', 2).stdout.strip() == '190'
assert cli('limit', 'rank', '--percentile', 99, '--margin', 2).stdout.strip() == '198'
# A measured value can raise an explicit bound but never lower it.
assert cli('limit', 'rank', '--margin', 2, '--fallback', 30).stdout.strip() == '190'
assert cli('limit', 'rank', '--margin', 2, '--fallback', 500).stdout.strip() == '500'
cli('limit', 'rank', '--margin', 'nan', expected=2)
cli('limit', 'rank', '--fallback', -1, expected=2)

# The shell adapter keeps the caller's bound when the helper cannot read its table.
corrupt = tmp / 'corrupt.jsonl'
corrupt.write_text('{"host":\n')
adapter = subprocess.run(['bash', '-c', '. "$1/bin/fm-duration-lib.sh"; fm_duration_limit corrupt.key 30', '_', str(root)],
                         env=dict(env, FM_DURATION_FILE=str(corrupt)), capture_output=True, text=True)
assert adapter.returncode == 0 and adapter.stdout == '30\n' and 'existing fallback 30s' in adapter.stderr, adapter

sentinel = tmp / 'corrupt-ran'
unread = subprocess.run([sys.executable, str(helper), 'run', 'corrupt.run', '--', 'bash', '-c', 'echo ran > "$1"; echo child-out', '_', str(sentinel)],
                        env=dict(env, FM_DURATION_FILE=str(corrupt)), cwd=workrepo, capture_output=True, text=True)
assert unread.returncode == 0 and unread.stdout == 'child-out\n' and sentinel.read_text() == 'ran\n', unread
assert 'calibration_error' in unread.stderr and 'no deadline' in unread.stderr, unread

batch = subprocess.run([sys.executable, str(helper), 'record-batch'], env=env, cwd=workrepo, input='batch.a\t100\t0\t1\t1.5\t2.5\t0\nbatch.b\t200\t3\t0\t\t\t0\n', capture_output=True, text=True)
assert batch.returncode == 0, batch
batched = {r['key']: r for r in rows() if r.get('key', '').startswith('batch.')}
assert (batched['batch.a']['duration_ms'], batched['batch.a']['load_start'], batched['batch.a']['load_end'], batched['batch.a']['calibration']) == (100, 1.5, 2.5, True)
assert (batched['batch.b']['exit'], batched['batch.b']['load_end'], batched['batch.b']['calibration']) == (3, None, False)

failed = cli('run', 'consumer.failure', '--', sys.executable, '-c', 'import sys; print("stdout-result"); print("stderr-result", file=sys.stderr); sys.exit(7)', expected=7)
assert failed.stdout == 'stdout-result\n' and 'stderr-result' in failed.stderr
assert 'output_bytes=' in failed.stderr and rows()[-1]['exit'] == 7
assert rows()[-1]['load_start'] is not None and rows()[-1]['load_end'] is not None

# Simulate a read returning while a real background command remains alive.
# A sentinel controls completion, not a guessed sleep duration.
release = tmp / 'release'
code = 'import pathlib,sys; print("started", flush=True); p=pathlib.Path(sys.argv[1]);\nwhile not p.exists(): pass\nprint("completed", flush=True)'
job = subprocess.Popen([sys.executable, str(helper), 'run', 'progress.handshake', '--', sys.executable, '-c', code, str(release)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
assert job.stdout.readline() == 'started\n'
assert job.poll() is None, 'the initial read must not stop the running job'
release.touch()
out, err = job.communicate()
assert job.returncode == 0 and out == 'completed\n' and 'progress:' in err, (job.returncode, out, err)
assert rows()[-1]['key'] == 'progress.handshake' and rows()[-1]['exit'] == 0

# Cancellation is a real signal result, not a telemetry or dead-group error.
cancel = subprocess.Popen([sys.executable, str(helper), 'run', 'consumer.cancel', '--', sys.executable, '-c', 'print("started", flush=True)\nwhile True: pass'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
assert cancel.stdout.readline() == 'started\n'
cancel.terminate()
cancel_out, cancel_err = cancel.communicate()
assert cancel.returncode == 143 and cancel_out == '', (cancel.returncode, cancel_out, cancel_err)

# A calibrated outer ceiling, derived from measured-table fixtures, really
# terminates an ongoing command rather than just returning from a read wait.
write_rows([sample('outer', 1) for _ in range(5)])
cli('run', 'outer', '--', sys.executable, '-c', 'while True: pass', expected=124)
assert any(r.get('event') == 'timeout' and r['key'] == 'outer' for r in rows())

# The leader's exit is the result even while a descendant still holds its
# streams: no wait for the descendant and no false ceiling expiry.
write_rows([sample('orphan', 20000) for _ in range(5)])
for key in ('orphan', 'orphan.cold'):
    gate = tmp / (key + '.fifo')
    os.mkfifo(gate)
    leader = cli('run', key, '--', 'bash', '-c', '(read -r _ < "$1") & echo leader-done; exit 0', '_', gate)
    assert leader.stdout == 'leader-done\n'
    assert rows()[-1]['key'] == key and rows()[-1]['exit'] == 0
    assert not any(r.get('event') == 'timeout' and r['key'] == key for r in rows())
    with open(gate, 'w') as opener:
        opener.write('release\n')

# A timeout is reported by the owner of the limit, never inferred from an exit code.
for code in (124, 137, 124, 137):
    cli('record', 'inferred', 5, code)
assert not any(r.get('event') for r in rows() if r.get('key') == 'inferred')
cli('run', 'sigkilled', '--', 'bash', '-c', 'kill -9 $$', expected=137)
cli('run', 'sigkilled', '--', 'bash', '-c', 'kill -9 $$', expected=137)
assert rows()[-1]['exit'] == 137 and not any(r.get('event') for r in rows() if r.get('key') == 'sigkilled')
cli('record', 'flagged', 5, 124, '--timed-out')
assert [r['key'] for r in rows() if r.get('event') == 'timeout'].count('flagged') == 1

# Keys are scoped to the repository: another repository's slow samples, or rows
# that carry no repository, never set this repository's limit.
other = make_repo('work-y', 'https://github.com/acme/other.git')
norepo = make_repo('no-origin')
write_rows([sample('scope.lint', 40000, repo='acme/other') for _ in range(5)] + [sample('scope.lint', 40000, repo=None) for _ in range(5)])
scoped = cli('limit', 'scope.lint', '--fallback', 30)
assert scoped.stdout.strip() == '30' and '0 of 5 samples' in scoped.stderr, scoped
assert cli('limit', 'scope.lint', '--fallback', 30, cwd=other).stdout.strip() == '120'
cli('record', 'scope.lint', 7, 0, cwd=norepo)
assert rows()[-1]['repo'] == 'no-origin' and rows()[-1]['key'] == 'scope.lint'
cli('record', 'scope.lint', 7, 0, cwd=other)
assert rows()[-1]['repo'] == 'acme/other'

# A command that had no deadline keeps none: fallback 0 records and never kills.
write_rows([sample('zero.key', 1) for _ in range(5)])
assert cli('limit', 'zero.key').stdout.strip() == '1'
zero = subprocess.run(['bash', '-c', '. "$1/bin/fm-duration-lib.sh"; fm_duration_limit zero.key 0; fm_duration_timed zero.key 0 bash -c "sleep 2; echo finished"', '_', str(root)],
                      env=env, cwd=workrepo, capture_output=True, text=True)
assert zero.returncode == 0 and zero.stdout == '0\nfinished\n', zero
assert rows()[-1]['key'] == 'zero.key' and rows()[-1]['exit'] == 0 and not any(r.get('event') for r in rows() if r.get('key') == 'zero.key')

# A command's own exit 124 well inside its bound is a failed sample, never a
# timeout, in each shell caller; only a bound that actually expired is one.
self124 = subprocess.run(['bash', '-c', '. "$1/bin/fm-duration-lib.sh"; fm_duration_timed self.124 30 bash -c "exit 124"', '_', str(root)],
                         env=env, cwd=workrepo, capture_output=True, text=True)
assert self124.returncode == 124, self124
assert [(r.get('event'), r.get('timed_out')) for r in rows() if r.get('key') == 'self.124'] == [(None, False)]
runrepo = make_repo('run-x', 'git@github.com:acme/widgets.git')
(runrepo / 'bin').mkdir()
(runrepo / 'tests').mkdir()
for name in ('bin/fm-test-run.sh', 'bin/fm-duration-lib.sh', 'bin/fm-duration.py', 'bin/fm-timeout-lib.sh', 'tests/git-config-helpers.sh'):
    shutil.copy2(root / name, runrepo / name)
(runrepo / 'tests/fm-self124.test.sh').write_text('exit 124\n')
(runrepo / 'tests/fm-hang.test.sh').write_text('sleep 30\n')
for _ in range(2):
    run = subprocess.run([str(runrepo / 'bin/fm-test-run.sh'), '--per-script-timeout-secs', '1', 'tests/fm-self124.test.sh', 'tests/fm-hang.test.sh'],
                         env=env, cwd=runrepo, capture_output=True, text=True)
    assert run.returncode != 0 and 'FM_TEST_SUMMARY total=2 failed=2' in run.stdout, run
suite_rows = [(r['key'], r['exit'], r['timed_out']) for r in rows() if r.get('key', '').startswith('test.tests/fm-') and 'event' not in r]
assert suite_rows == [('test.tests/fm-self124.test.sh', 124, False), ('test.tests/fm-hang.test.sh', 124, True)] * 2, suite_rows
events = [r['key'] for r in rows() if r.get('event') == 'timeout' and r.get('key', '').startswith('test.tests/fm-')]
assert events == ['test.tests/fm-hang.test.sh'] * 2, events

# bin/fm-test-run.sh takes the same per-key slot around every script it runs: with the key's
# only slot held elsewhere it names the key and the holder, and a bounded wait still runs it.
(runrepo / 'tests/fm-slot.test.sh').write_text('echo slot-script-ran\n')
slot_run_env = dict(env, FM_TEST_SLOT_DIR=str(tmp / 'runner-slots'), FM_TEST_KEY_SLOTS='1', FM_TEST_SLOT_WAIT_SECONDS='3')
slot_holder = subprocess.Popen([sys.executable, str(helper), 'gate', 'test.tests/fm-slot.test.sh', '--', 'sleep', '20'], env=slot_run_env, cwd=runrepo)
for _ in range(100):
    if 'held[1]' in subprocess.run([sys.executable, str(helper), 'slots', 'test.tests/fm-slot.test.sh'], env=slot_run_env, cwd=runrepo, capture_output=True, text=True).stdout:
        break
    subprocess.run(['sleep', '0.1'])
slot_run_started = time.monotonic()
slot_run = subprocess.run([str(runrepo / 'bin/fm-test-run.sh'), 'tests/fm-slot.test.sh'], env=slot_run_env, cwd=runrepo, capture_output=True, text=True, timeout=120)
slot_run_elapsed_ms = (time.monotonic() - slot_run_started) * 1000
slot_holder.kill()
slot_holder.communicate()
assert slot_run.returncode == 0 and 'slot-script-ran' in slot_run.stdout, slot_run
assert 'waiting' in slot_run.stderr and 'test.tests/fm-slot.test.sh' in slot_run.stderr and f'pid={slot_holder.pid}' in slot_run.stderr, slot_run.stderr
assert 'running it without a slot' in slot_run.stderr, slot_run.stderr
# The 3 seconds it queued are in neither the FM_TEST_END duration nor the test.* sample.
slot_end = re.search(r'FM_TEST_END \S+ tests/fm-slot\.test\.sh exit=0 duration_ms=(\d+)', slot_run.stdout)
slot_sample = [r for r in rows() if r.get('key') == 'test.tests/fm-slot.test.sh' and 'event' not in r][-1]
assert slot_end and int(slot_end.group(1)) <= slot_run_elapsed_ms - 2900, (slot_end, slot_run_elapsed_ms)
assert slot_sample['duration_ms'] <= slot_run_elapsed_ms - 2900, (slot_sample, slot_run_elapsed_ms)
print('ok - the test runner waits on a held per-key slot, names the holder, runs once the bounded wait ends, and leaves the wait out of the sample')

# A stop sends TERM and waits for the leader: its own TERM cleanup of a child in
# a separate process group runs and leaves no survivor. The leader reports
# readiness only after installing its handler, so no startup race is possible.
def reap_owned(runner, *pid_files):
    runner.kill()
    for pid_file in pid_files:
        with contextlib.suppress(FileNotFoundError, ValueError, ProcessLookupError, PermissionError):
            os.killpg(int(pid_file.read_text()), signal.SIGKILL)
    runner.communicate()


trap_dir = tmp / 'trap'
trap_dir.mkdir()
leader = r'''
import os, pathlib, signal, subprocess, sys, time
home = pathlib.Path(sys.argv[1])
(home / 'leader.pid').write_text(str(os.getpid()))
child = subprocess.Popen([sys.executable, '-c', 'import time\nwhile True: time.sleep(1)'], start_new_session=True)
(home / 'child.pid').write_text(str(child.pid))
def on_term(sig, frame):
    os.killpg(child.pid, signal.SIGKILL)
    child.wait()
    (home / 'trap-ran').write_text('yes')
    sys.exit(0)
signal.signal(signal.SIGTERM, on_term)
print('started', flush=True)
while True:
    time.sleep(0.1)
'''
trapped = subprocess.Popen([sys.executable, str(helper), 'run', 'trapped', '--', sys.executable, '-c', leader, str(trap_dir)], env=env, cwd=workrepo, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    assert trapped.stdout.readline() == 'started\n'
    trapped.send_signal(signal.SIGTERM)
    trapped.communicate()
    assert trapped.returncode == 143, trapped.returncode
    assert (trap_dir / 'trap-ran').read_text() == 'yes'
    try:
        os.kill(int((trap_dir / 'child.pid').read_text()), 0)
        raise AssertionError('the leader\'s child group survived the runner kill')
    except ProcessLookupError:
        pass
except BaseException:
    reap_owned(trapped, trap_dir / 'leader.pid', trap_dir / 'child.pid')
    raise

# A leader that ignores TERM is killed only by a second forwarded signal.
stubborn = tmp / 'stubborn.pid'
code = 'import os, pathlib, signal, sys, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\npathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\nprint("started", flush=True)\nwhile True: time.sleep(0.1)'
job = subprocess.Popen([sys.executable, str(helper), 'run', 'stubborn', '--', sys.executable, '-c', code, str(stubborn)], env=env, cwd=workrepo, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    assert job.stdout.readline() == 'started\n'
    job.send_signal(signal.SIGTERM)
    job.send_signal(signal.SIGINT)
    job.communicate()
    assert job.returncode in (130, 143), job.returncode
    try:
        os.kill(int(stubborn.read_text()), 0)
        raise AssertionError('the second signal did not kill the TERM-ignoring leader')
    except ProcessLookupError:
        pass
except BaseException:
    reap_owned(job, stubborn)
    raise

# Completed no-mistakes step imports are idempotent samples whose historical
# load is unknown; after five samples the step key has a measured limit.
database = tmp / 'nm.sqlite'
with sqlite3.connect(database) as db:
    db.execute('CREATE TABLE step_results(id TEXT, run_id TEXT, step_name TEXT, duration_ms INTEGER, exit_code INTEGER, completed_at INTEGER)')
    db.executemany('INSERT INTO step_results VALUES(?,?,?,?,?,?)', [(f's{n}', f'r{n}', 'review', n * 10000, 0, 1) for n in range(1, 6)] + [('s0', 'r1', 'test', 10000, 0, None)])
cli('import-nm', database, 'r1')
cli('import-nm', database, 'r1')
imports = [r for r in rows() if r.get('key') == 'no-mistakes-step.review']
assert len(imports) == 1 and imports[0]['duration_ms'] == 10000 and imports[0]['load_start'] is None
assert not any(r.get('key') == 'no-mistakes.review' for r in rows())
for n in range(2, 6):
    cli('import-nm', database, f'r{n}')
assert len([r for r in rows() if r.get('key') == 'no-mistakes-step.review']) == 5
# Imported step samples are record-only: a wrapped drive call under its own key never inherits them.
drive = cli('limit', 'no-mistakes.review', '--fallback', 30)
assert drive.stdout.strip() == '30' and '0 of 5 samples' in drive.stderr, drive
cli('run', 'no-mistakes.review', '--', 'bash', '-c', 'sleep 2')
assert rows()[-1]['key'] == 'no-mistakes.review' and rows()[-1]['exit'] == 0 and not any(r.get('event') for r in rows() if r.get('key') == 'no-mistakes.review')

# Retention: once a host/key exceeds the compaction threshold, only its newest
# samples survive; timeout and filed rows are always kept.
compact_ledger = tmp / 'compact.jsonl'
write_rows([sample('busy', n) for n in range(1, 201)] + [sample('quiet', n) for n in range(1, 51)]
           + [dict(host=platform.node(), key='busy', event=event, duration_ms=1) for event in ('timeout', 'filed')], compact_ledger)
subprocess.run([sys.executable, str(helper), 'record', 'busy', '201', '0'], env=dict(env, FM_DURATION_FILE=str(compact_ledger)), cwd=workrepo, check=True, capture_output=True)
kept = [json.loads(line) for line in compact_ledger.read_text().splitlines()]
assert [r['duration_ms'] for r in kept if r['key'] == 'busy' and 'exit' in r] == list(range(102, 202))
assert len([r for r in kept if r['key'] == 'quiet']) == 50
assert sorted(r['event'] for r in kept if 'event' in r) == ['filed', 'timeout']

# The helper has no read-wait record: only a real limit is a timeout, and one alone files nothing.
cli('read-wait', 'waited', 600000, expected=2)
cli('timeout', 'waited', 600000, '--event-id', 'real')
assert [r['event'] for r in rows() if r['key'] == 'waited' and 'event' in r] == ['timeout']

# Without an owning home the code root's table is checkout-local; say so once.
checkout = tmp / 'checkout'
(checkout / 'bin').mkdir(parents=True)
shutil.copyfile(helper, checkout / 'bin/fm-duration.py')
bare = {name: value for name, value in env.items() if name not in ('FM_DURATION_FILE', 'FM_DURATION_HOME', 'FM_HOME', 'FM_DATA_OVERRIDE')}
local = subprocess.run([sys.executable, str(checkout / 'bin/fm-duration.py'), 'record', 'local', '5', '0'], env=bare, capture_output=True, text=True, check=True)
assert local.stderr.count('checkout-local and not durable') == 1
assert (checkout / 'data/command-durations.jsonl').exists()

# A firstmate tool never writes into a project copy. The caller's directory is a
# project-like git repository whose .gitignore hides *.jsonl but not the .lock,
# exactly as the reported tree was; any file the helper leaves there is a failure.
project = make_repo('project-like', 'git@github.com:acme/project.git')
(project / '.gitignore').write_text('*.jsonl\n')
subprocess.run(['git', '-C', str(project), 'add', '.gitignore'], check=True)
subprocess.run(['git', '-C', str(project), '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'init'], check=True)


def project_dirty():
    return subprocess.run(['git', '-C', str(project), 'status', '--porcelain', '--ignored', '-uall'],
                          capture_output=True, text=True, check=True).stdout


def from_project(*args, extra=None, **kwargs):
    environment = dict(bare, **(extra or {}))
    return subprocess.run([sys.executable, str(checkout / 'bin/fm-duration.py'), *map(str, args)],
                          env=environment, cwd=project, capture_output=True, text=True, **kwargs)


assert project_dirty() == ''
for empty in ('FM_DATA_OVERRIDE', 'FM_HOME', 'FM_DURATION_FILE', 'FM_DURATION_HOME'):
    shutil.rmtree(checkout / 'data')
    done = from_project('record', 'empty.' + empty, 7, 0, extra={empty: ''})
    assert done.returncode == 0 and 'refused' not in done.stderr, (empty, done.stdout, done.stderr)
    assert project_dirty() == '', (empty, 'an empty variable wrote into the project', project_dirty())
    assert (checkout / 'data/command-durations.jsonl').exists(), (empty, 'an empty variable is unset, so the code root records')
everything_empty = from_project('record', 'empty.all', 7, 0, extra={name: '' for name in ('FM_DATA_OVERRIDE', 'FM_HOME', 'FM_DURATION_FILE', 'FM_DURATION_HOME')})
assert everything_empty.returncode == 0 and project_dirty() == '', (everything_empty.stderr, project_dirty())
print('ok - empty home variables are unset and never resolve against the caller directory')

# A relative or in-project location refuses once, records nothing, and leaves the tree clean.
for name, value in (('FM_DATA_OVERRIDE', 'data'), ('FM_HOME', '.'), ('FM_DURATION_HOME', 'owner'), ('FM_DURATION_FILE', 'command-durations.jsonl'),
                    ('FM_DURATION_FILE', str(project / 'command-durations.jsonl')),
                    ('FM_DURATION_FILE', str(project / 'nested/dir/command-durations.jsonl'))):
    for args in (('record', 'refused', 5, 0), ('limit', 'refused', '--fallback', 9), ('timeout', 'refused', 5), ('path',)):
        done = from_project(*args, extra={name: value})
        assert done.returncode == 0, (name, value, args, done.stdout, done.stderr)
        assert done.stderr.count('refused, nothing recorded') == 1, (name, value, args, done.stderr)
        assert project_dirty() == '', (name, value, args, 'a refused location still wrote into the project', project_dirty())
        if args[0] == 'limit':
            assert done.stdout.strip() == '9'
        if args[0] == 'path':
            assert done.stdout.strip() == 'off'
print('ok - a ledger or lock location inside a project work tree is refused without writing')

# A declared home that is a plain git work tree or a project copy is refused, whichever variable names it.
for name, value in (('FM_DURATION_HOME', str(project)), ('FM_HOME', str(project)), ('FM_DATA_OVERRIDE', str(project)),
                    ('FM_DATA_OVERRIDE', str(project / 'data')), ('FM_DURATION_HOME', str(project / 'nested/home'))):
    for args in (('record', 'plain', 5, 0), ('limit', 'plain', '--fallback', 9), ('timeout', 'plain', 5), ('path',)):
        done = from_project(*args, extra={name: value})
        assert done.returncode == 0, (name, value, args, done.stdout, done.stderr)
        assert done.stderr.count('refused, nothing recorded') == 1, (name, value, args, done.stderr)
        assert project_dirty() == '' and not (project / 'data').exists(), (name, value, args, 'a plain work tree home was written', project_dirty())
        if args[0] == 'limit':
            assert done.stdout.strip() == '9'
        if args[0] == 'path':
            assert done.stdout.strip() == 'off'
print('ok - a declared home that is a project work tree is refused without writing')

# Normal recording is unchanged: a home that is itself a firstmate git checkout keeps its table under its own data/.
git_home = make_repo('git-home')
(git_home / 'bin').mkdir()
(git_home / 'bin/fm-duration.py').write_text('')
(git_home / 'data').mkdir()
for extra in ({'FM_DURATION_HOME': str(git_home)}, {'FM_HOME': str(git_home)}, {'FM_HOME': str(git_home), 'FM_DATA_OVERRIDE': str(git_home / 'data')}):
    (git_home / 'data/command-durations.jsonl').unlink(missing_ok=True)
    done = from_project('record', 'home.key', 11, 0, extra=extra)
    assert done.returncode == 0 and 'refused' not in done.stderr, (extra, done.stderr)
    assert json.loads((git_home / 'data/command-durations.jsonl').read_text().splitlines()[0])['key'] == 'home.key'
    assert project_dirty() == ''
spread = from_project('record', 'file.key', 11, 0, extra={'FM_DURATION_FILE': str(tmp / 'explicit-outside.jsonl')})
assert spread.returncode == 0 and 'refused' not in spread.stderr and (tmp / 'explicit-outside.jsonl').exists()

# The calibration scratch file follows the same rule: a TMPDIR inside a project work tree is skipped.
inside = project / 'scratch-inside'
inside.mkdir()
calibration = from_project('run', 'calibration.key', '--', sys.executable, '-c', 'import os; print(os.environ.get("FM_DURATION_CALIBRATION_FILE", "none"))',
                           extra={'FM_DURATION_FILE': str(tmp / 'explicit-outside.jsonl'), 'TMPDIR': str(inside)})
assert calibration.returncode == 0, calibration.stderr
assert not calibration.stdout.strip().startswith(str(project)) and not calibration.stdout.strip().startswith(str(project.resolve())), calibration.stdout
assert project_dirty() == '' and not any(inside.iterdir()), (project_dirty(), list(inside.iterdir()))
print('ok - the calibration scratch file never lands in a project work tree')

if shutil.which('tasks-axi'):
    key = 'repeat.consumer'
    task = 'fm-timeout-' + hashlib.sha256((platform.node() + '\0' + REPO + '\0' + key).encode()).hexdigest()[:16]
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

# A worker-shaped call: the helper runs from a disposable checkout while the
# spawn-exported owning home receives the samples and the owned backlog work.
# Closing that work and seeing the timeout recur files new work naming it.
if shutil.which('tasks-axi'):
    owner = tmp / 'owner-home'
    (owner / 'data').mkdir(parents=True)
    (owner / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (owner / 'bin').symlink_to(root / 'bin')
    worktree = tmp / 'worker-worktree'
    (worktree / 'bin').mkdir(parents=True)
    shutil.copyfile(helper, worktree / 'bin/fm-duration.py')
    worker_env = {name: value for name, value in env.items() if name not in ('FM_DURATION_FILE', 'FM_HOME', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_STATE_OVERRIDE')}
    worker_env['FM_DURATION_HOME'] = str(owner)

    def worker(*args):
        result = subprocess.run([sys.executable, str(worktree / 'bin/fm-duration.py'), *map(str, args)], env=worker_env, cwd=workrepo, capture_output=True, text=True)
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        assert 'not durable' not in result.stderr
        return result

    key = 'worker.lint'
    first = 'fm-timeout-' + hashlib.sha256((platform.node() + '\0' + REPO + '\0' + key).encode()).hexdigest()[:16]
    for event_id in ('w1', 'w2', 'w3'):
        worker('timeout', key, 1200000, '--event-id', event_id)
    owner_rows = [json.loads(line) for line in (owner / 'data/command-durations.jsonl').read_text().splitlines()]
    assert [r['task'] for r in owner_rows if r.get('event') == 'filed'] == [first]
    assert (owner / 'data/backlog.md').read_text().count('- [ ] fm-timeout-') == 1
    assert not (worktree / 'data').exists()
    subprocess.run(['tasks-axi', 'done', first, '--note', 'limit repaired', '--keep', '5'], cwd=owner, env=dict(worker_env, TASKS_AXI_FILE=str(owner / 'data/backlog.md')), check=True, capture_output=True)
    worker('timeout', key, 1300000, '--event-id', 'w4')
    worker('timeout', key, 1300000, '--event-id', 'w5')
    owner_rows = [json.loads(line) for line in (owner / 'data/command-durations.jsonl').read_text().splitlines()]
    assert [r['task'] for r in owner_rows if r.get('event') == 'filed'] == [first, first + '-2']
    shown = subprocess.run([str(owner / 'bin/fm-tasks-axi.sh'), 'show', first + '-2', '--full'], env=dict(worker_env, FM_HOME=str(owner)), capture_output=True, text=True, check=True)
    assert 'state: queued' in shown.stdout and first in shown.stdout
    print('ok - worker timings and repeated-timeout work reach the owning home, and a recurrence after closure files new work')

# Repeated-timeout work goes to the project registered under the repository's name in
# the owning home's data/projects.md, and to firstmate when there is no such project.
if shutil.which('tasks-axi'):
    registry = '# Projects\n\n- widgets [no-mistakes] - fixture project (added 2026-10-13)\n- other thing - second project (added 2026-10-13)\n'
    unregistered = make_repo('work-z', 'git@github.com:acme/unregistered.git')

    def filed_item(name, cwd_repo, identity, key):
        home = tmp / name
        (home / 'data').mkdir(parents=True)
        (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        (home / 'data/projects.md').write_text(registry)
        (home / 'bin').symlink_to(root / 'bin')
        route_env = {n: v for n, v in env.items() if n not in ('FM_DURATION_FILE', 'FM_HOME', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_STATE_OVERRIDE')}
        route_env['FM_DURATION_HOME'] = str(home)
        for event_id in ('a', 'b'):
            subprocess.run([sys.executable, str(helper), 'timeout', key, '1000', '--event-id', event_id], env=route_env, cwd=cwd_repo, check=True, capture_output=True)
        task = 'fm-timeout-' + hashlib.sha256((platform.node() + '\0' + identity + '\0' + key).encode()).hexdigest()[:16]
        return subprocess.run([str(home / 'bin/fm-tasks-axi.sh'), 'show', task, '--full'], env=dict(route_env, FM_HOME=str(home)), capture_output=True, text=True, check=True).stdout

    registered_item = filed_item('route-registered', workrepo, REPO, 'route.key')
    assert 'repo: widgets' in registered_item and 'acme/widgets route.key' in registered_item, registered_item
    fallback_item = filed_item('route-unregistered', unregistered, 'acme/unregistered', 'route.key')
    assert 'repo: firstmate' in fallback_item and 'acme/unregistered route.key' in fallback_item, fallback_item
    print('ok - repeated-timeout work routes to the registered project, else to firstmate')

# The recovery command printed when run() cannot record keeps timeout provenance only
# when the runner's own ceiling expired, and replaying it records exactly one occurrence.
def recovery(key, leader_tail, samples):
    table = tmp / (key + '.jsonl')
    table.write_text('')
    write_rows([sample(key, 1000) for _ in range(samples)], table)
    swap = 'mv "$L" "$L.bak"; mkdir "$L"; ' + leader_tail
    failed = subprocess.run([sys.executable, str(helper), 'run', key, '--', 'bash', '-c', swap, '_'], env=dict(env, FM_DURATION_FILE=str(table), L=str(table)), cwd=workrepo, capture_output=True, text=True)
    assert 'recording_error' in failed.stderr, failed
    line = next(l for l in failed.stderr.splitlines() if l.startswith('help: '))
    printed = json.loads(line[len('help: '):]).split('; command result preserved')[0]
    table.rmdir()
    (tmp / (key + '.jsonl.bak')).rename(table)
    replay_env = dict(env, FM_DURATION_FILE=str(table))
    # Replay verbatim from the work repo and from the firstmate checkout; both
    # must record under the repository where the command ran.
    for cwd in (workrepo, root):
        subprocess.run(['bash', '-c', printed], env=replay_env, cwd=cwd, check=True, capture_output=True)
    recorded = [json.loads(l) for l in table.read_text().splitlines()]
    assert {r.get('repo') for r in recorded if r['key'] == key} == {REPO}, recorded
    return failed, shlex.split(printed), [r for r in recorded if r['key'] == key and r.get('sample_id')], [r for r in recorded if r.get('event') == 'timeout']

failed, command, sample_rows, timeouts = recovery('recover.ceiling', 'while :; do sleep 1; done', 5)
assert failed.returncode == 124 and '--timed-out' in command, command
assert len(sample_rows) == 1 and sample_rows[0]['exit'] == 124 and len(timeouts) == 1, (sample_rows, timeouts)
failed, command, sample_rows, timeouts = recovery('recover.exit124', 'exit 124', 0)
assert failed.returncode == 124 and '--timed-out' not in command, command
assert len(sample_rows) == 1 and sample_rows[0]['exit'] == 124 and timeouts == [], (sample_rows, timeouts)

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
        db.executemany('INSERT INTO step_results VALUES(?,?,?,?,?,?)', [('retry1','retry-run','retry',10000,124,1), ('retry2','retry-run','retry',20000,137,1)])
    cli('import-nm', database, 'retry-run')
    assert len([r for r in rows() if r.get('key') == 'no-mistakes-step.retry' and 'exit' in r]) == 2
    assert not any(r.get('key') == 'no-mistakes-step.retry' and 'event' in r for r in rows()), 'an imported exit code was guessed to be a timeout'
    cli('timeout', 'retry.key', 10000, '--event-id', 'retry1')
    cli('timeout', 'retry.key', 20000, '--event-id', 'retry2', expected=1)
    assert len([r for r in rows() if r.get('key') == 'retry.key' and r.get('event') == 'timeout']) == 2
    assert not any(r.get('key') == 'retry.key' and r.get('event') == 'filed' for r in rows())
    retry_backlog.rmdir()
    retry_backlog.write_text('## In flight\n\n## Queued\n\n## Done\n')
    cli('timeout', 'retry.key', 20000, '--event-id', 'retry2')
    assert len([r for r in rows() if r.get('key') == 'retry.key' and r.get('event') == 'timeout']) == 2
    assert len([r for r in rows() if r.get('key') == 'retry.key' and r.get('event') == 'filed']) == 1
    assert retry_backlog.read_text().count('- [ ] fm-timeout-') == 1
    env = original_env
    print('ok - a failed backlog publication is retried without duplicating events, and imports never guess a timeout')

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
cli('check-literals','--report','--base','HEAD',expected=2,tool=guard)
for added in ('fm_duration_timed key.x 5 cmd', 'fm_duration_limit "key.$h" 7', 'cmd --wait 8m', 'curl --timeout 30s'):
    source.write_text('#!/bin/bash\nEXISTING_TIMEOUT=15\n' + added + '\n')
    assert 'new time limit' in cli('check-literals','--base','HEAD',expected=1,tool=guard).stdout, added
    assert added in cli('check-literals','--report',tool=guard).stdout, added
source.write_text('#!/bin/bash\nEXISTING_TIMEOUT=15\nbound=$(fm_duration_limit "key.$h" 30)\nscript=$(fm_duration_limit "test.$s" "$fallback" 99)\n')
cli('check-literals','--base','HEAD',expected=1,tool=guard)
(repo / 'bin/fm-duration-existing-limits.tsv').write_text('# moved\nbin/example.sh\t30\tbound=$(fm_duration_limit "key.$h" 30)\n')
cli('check-literals','--base','HEAD',tool=guard)
print('ok - sample-count limits, retention, progress, leader exit, outer ceiling, pipeline imports and literal guard')

# Per-key slot gate: at most FM_TEST_KEY_SLOTS concurrent copies of one test.* key, a clear
# waiter notice, release on every exit path, a bounded wait, and no gate for other keys.
slot_dir = tmp / 'slots'
slot_env = dict(env, FM_TEST_SLOT_DIR=str(slot_dir), FM_TEST_KEY_SLOTS='2')
hold_code = ('import os,pathlib,sys\n'
             'pathlib.Path(sys.argv[2]).write_text(str(os.getpid()))\n'
             'print("started", flush=True)\n'
             'p = pathlib.Path(sys.argv[1])\n'
             'while not p.exists(): pass\n'
             'print("finished", flush=True)')


def hold(key, name, extra=None, tool_args=('run',)):
    """Start `fm-duration.py run KEY` around a command that waits for a release file."""
    release, pidfile = tmp / f'{name}.release', tmp / f'{name}.pid'
    job = subprocess.Popen([sys.executable, str(helper), *tool_args, key, '--', sys.executable, '-c', hold_code, str(release), str(pidfile)],
                           env=dict(slot_env, **(extra or {})), cwd=workrepo, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return job, release, pidfile


def finish(job, release):
    release.touch()
    return job.communicate(timeout=60)


first, first_release, first_pid = hold('test.slot.key', 'slot-a')
second, second_release, _ = hold('test.slot.key', 'slot-b')
assert first.stdout.readline() == 'started\n' and second.stdout.readline() == 'started\n', 'two copies fit the default limit of two'
third_launched = time.monotonic()
third, third_release, _ = hold('test.slot.key', 'slot-c')
notice = third.stderr.readline()
assert 'waiting' in notice and 'test.slot.key' in notice and f'pid={first.pid}' in notice and f'pid={second.pid}' in notice, notice
assert 'limit 2' in notice and 'FM_TEST_KEY_SLOTS' in notice, notice
shown = subprocess.run([sys.executable, str(helper), 'slots', 'test.slot.key'], env=slot_env, cwd=workrepo, capture_output=True, text=True).stdout
assert 'held[2]' in shown and f'pid={first.pid} alive' in shown, shown
assert third.poll() is None, 'a third copy must wait, not run beside the other two'
finish(first, first_release)
assert third.stdout.readline() == 'started\n', 'a released slot goes to the waiter'
third_waited = time.monotonic() - third_launched
finish(second, second_release)
third_out, third_err = finish(third, third_release)
assert 'got a slot of test.slot.key' in third_err and third_out == 'finished\n', third_err
third_total = time.monotonic() - third_launched
third_sample = [r for r in rows() if r['key'] == 'test.slot.key' and 'event' not in r][-1]
assert third_waited >= 2 and third_sample['duration_ms'] / 1000 <= third_total - third_waited + 1.5, (third_waited, third_total, third_sample)

# Other keys take no slot, and the gate can be turned off.
free = [hold('consumer.slot.key', f'free-{i}', dict(FM_TEST_KEY_SLOTS='1')) for i in range(2)]
assert all(job.stdout.readline() == 'started\n' for job, _, _ in free), 'only test.* keys are gated'
for job, release, _ in free:
    finish(job, release)
off = [hold('test.slot.off', f'off-{i}', dict(FM_TEST_KEY_SLOTS='0')) for i in range(3)]
assert all(job.stdout.readline() == 'started\n' for job, _, _ in off), 'FM_TEST_KEY_SLOTS=0 turns the gate off'
for job, release, _ in off:
    finish(job, release)

# A killed holder frees its slot at once: the kernel drops the lock with the process.
one = dict(FM_TEST_KEY_SLOTS='1')
victim, victim_release, victim_pid = hold('test.slot.kill', 'kill-a', one)
assert victim.stdout.readline() == 'started\n'
waiter, waiter_release, _ = hold('test.slot.kill', 'kill-b', one)
assert 'waiting' in waiter.stderr.readline()
victim.kill()
victim.communicate()
assert waiter.stdout.readline() == 'started\n', 'a SIGKILLed holder must release its slot'
os.kill(int(victim_pid.read_text()), signal.SIGKILL)
finish(waiter, waiter_release)

# A bounded wait ends, says so, and runs the command; a record that names a gone pid is flagged.
stale_holder = subprocess.Popen([sys.executable, '-c', (
    'import fcntl,json,os,sys,time\n'
    'sys.path.insert(0, sys.argv[1])\n'
    'import importlib.util as u\n'
    's = u.spec_from_file_location("d", sys.argv[2]); d = u.module_from_spec(s); s.loader.exec_module(d)\n'
    'directory = d.slot_directory("test.slot.stale")\n'
    'fd = os.open(directory / "slot-0.lock", os.O_RDWR | os.O_CREAT, 0o600)\n'
    'fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n'
    'os.write(fd, json.dumps(dict(pid=999999, start="Thu Jan  1 00:00:00 1970", since=int(time.time()), cwd="/gone")).encode())\n'
    'print("held", flush=True)\n'
    'time.sleep(60)'), str(root), str(helper)], env=slot_env, stdout=subprocess.PIPE, text=True)
assert stale_holder.stdout.readline() == 'held\n'
bounded = subprocess.run([sys.executable, str(helper), 'run', 'test.slot.stale', '--', sys.executable, '-c', 'print("ran anyway")'],
                         env=dict(slot_env, FM_TEST_KEY_SLOTS='1', FM_TEST_SLOT_WAIT_SECONDS='3'), cwd=workrepo, capture_output=True, text=True, timeout=60)
stale_holder.kill()
stale_holder.communicate()
assert bounded.returncode == 0 and bounded.stdout == 'ran anyway\n', bounded
assert 'does not match a live process' in bounded.stderr and 'cwd=/gone' in bounded.stderr, bounded.stderr
assert 'waited' in bounded.stderr and 'running it without a slot' in bounded.stderr, bounded.stderr

# The same key nested inside a held slot takes no second slot, so a limit of one cannot deadlock.
nested = subprocess.run([sys.executable, str(helper), 'run', 'test.slot.nest', '--', sys.executable, str(helper), 'run', 'test.slot.nest', '--', 'true'],
                        env=dict(slot_env, FM_TEST_KEY_SLOTS='1', FM_TEST_SLOT_WAIT_SECONDS='30'), cwd=workrepo, capture_output=True, text=True, timeout=60)
assert nested.returncode == 0 and 'waiting' not in nested.stderr, nested

# gate runs a command under a slot with its exit status and output; bad settings are refused by name.
gated = subprocess.run([sys.executable, str(helper), 'gate', 'test.slot.gate', '--', 'bash', '-c', 'echo out; echo err >&2; exit 7'],
                       env=slot_env, cwd=workrepo, capture_output=True, text=True, timeout=60)
assert gated.returncode == 7 and gated.stdout == 'out\n' and gated.stderr == 'err\n', gated
missing = subprocess.run([sys.executable, str(helper), 'gate', 'test.slot.gate', '--', str(tmp / 'no-such-command')], env=slot_env, cwd=workrepo, capture_output=True, text=True)
assert missing.returncode == 127, missing
for variable, value in (('FM_TEST_KEY_SLOTS', 'many'), ('FM_TEST_KEY_SLOTS', '17'), ('FM_TEST_SLOT_WAIT_SECONDS', '0')):
    refused = subprocess.run([sys.executable, str(helper), 'gate', 'test.slot.gate', '--', 'true'], env=dict(slot_env, **{variable: value}), cwd=workrepo, capture_output=True, text=True)
    assert refused.returncode == 125 and variable in refused.stderr, (variable, value, refused)
    refused = subprocess.run([sys.executable, str(helper), 'run', 'test.slot.gate', '--', 'true'], env=dict(slot_env, **{variable: value}), cwd=workrepo, capture_output=True, text=True)
    assert refused.returncode == 125 and variable in refused.stdout, (variable, value, refused)

# gate reports the wait it spent, so a caller that times COMMAND itself can leave it out.
wait_env = dict(slot_env, FM_TEST_KEY_SLOTS='1', FM_TEST_SLOT_WAIT_SECONDS='3')
wait_holder = subprocess.Popen([sys.executable, str(helper), 'gate', 'test.slot.wait', '--', 'sleep', '20'], env=wait_env, cwd=workrepo)
for _ in range(100):
    if 'held[1]' in subprocess.run([sys.executable, str(helper), 'slots', 'test.slot.wait'], env=wait_env, cwd=workrepo, capture_output=True, text=True).stdout:
        break
    time.sleep(0.1)
waited_file, unwaited_file = tmp / 'waited.ms', tmp / 'unwaited.ms'
queued = subprocess.run([sys.executable, str(helper), 'gate', '--wait-file', str(waited_file), 'test.slot.wait', '--', 'true'], env=wait_env, cwd=workrepo, capture_output=True, text=True, timeout=60)
wait_holder.kill()
wait_holder.communicate()
assert queued.returncode == 0 and 2900 <= int(waited_file.read_text()) < 60000, (queued, waited_file.read_text())
subprocess.run([sys.executable, str(helper), 'gate', '--wait-file', str(unwaited_file), 'test.slot.wait', '--', 'true'], env=wait_env, cwd=workrepo, check=True, capture_output=True, timeout=60)
assert int(unwaited_file.read_text()) < 2900, unwaited_file.read_text()
unwritable = subprocess.run([sys.executable, str(helper), 'gate', '--wait-file', str(tmp / 'no-such-dir/waited.ms'), 'test.slot.wait', '--', 'echo', 'ran'], env=wait_env, cwd=workrepo, capture_output=True, text=True, timeout=60)
assert unwritable.returncode == 0 and unwritable.stdout == 'ran\n', unwritable

# gate hands COMMAND its --log-fd descriptor, so a notice the command's own wrapper writes there is not lost.
log_file = tmp / 'log-fd.out'
passed = subprocess.run(['bash', '-c', 'exec 8>"$1"; shift; exec "$@"', '_', str(log_file), sys.executable, str(helper), 'gate', '--log-fd', '8', 'test.slot.logfd', '--', 'bash', '-c', 'echo from-command >&8'],
                        env=slot_env, cwd=workrepo, capture_output=True, text=True, timeout=60)
assert passed.returncode == 0 and log_file.read_text() == 'from-command\n', (passed, log_file.read_text())
# A --log-fd that is not open falls back to stderr instead of stopping the command.
closed = subprocess.run([sys.executable, str(helper), 'gate', '--log-fd', '57', 'test.slot.logfd', '--', 'echo', 'ran'], env=slot_env, cwd=workrepo, capture_output=True, text=True, timeout=60)
assert closed.returncode == 0 and closed.stdout == 'ran\n', closed

# An unusable slot file, or a Python with no POSIX file locks, runs the command without a slot and says so.
fault_directory = json.loads(subprocess.run([sys.executable, str(helper), 'slots', 'test.slot.fault'], env=slot_env, cwd=workrepo, capture_output=True, text=True, check=True).stdout.split('directory: ')[1].splitlines()[0])
for index in range(2):
    (Path(fault_directory) / f'slot-{index}.lock').unlink(missing_ok=True)
    (Path(fault_directory) / f'slot-{index}.lock').mkdir()
for action in ('gate', 'run'):
    faulted = subprocess.run([sys.executable, str(helper), action, 'test.slot.fault', '--', 'echo', 'ran'], env=slot_env, cwd=workrepo, capture_output=True, text=True, timeout=60)
    assert faulted.returncode == 0 and faulted.stdout == 'ran\n' and 'running test.slot.fault without a slot' in faulted.stderr, (action, faulted)
no_locks = subprocess.run([sys.executable, '-c', (
    'import sys\n'
    'sys.modules["fcntl"] = None\n'
    'import importlib.util as u\n'
    's = u.spec_from_file_location("d", sys.argv[1]); d = u.module_from_spec(s); s.loader.exec_module(d)\n'
    'sys.argv = ["fm-duration.py", "gate", "test.slot.nolocks", "--", "echo", "ran"]\n'
    'sys.exit(d.main())'), str(helper)], env=slot_env, cwd=workrepo, capture_output=True, text=True, timeout=60)
assert no_locks.returncode == 0 and no_locks.stdout == 'ran\n' and 'without a slot' in no_locks.stderr and 'POSIX file locks' in no_locks.stderr, no_locks
print('ok - a test.* key admits at most the configured copies, names its holders while waiting, frees a killed holder, reports its wait, keeps the log descriptor, never stops a command, and stays out of the sample')
PY
pass "measured command behavior"
