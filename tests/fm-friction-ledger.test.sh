#!/usr/bin/env bash
# Optional ledger publication, privacy, concurrent idempotency and refusal routes.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-friction-ledger)
trap fm_test_cleanup EXIT
export FRICTION_ROOT="$ROOT" FRICTION_TMP="$TMP_ROOT" PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import contextlib
import errno
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
from unittest.mock import patch

root = Path(os.environ['FRICTION_ROOT'])
tmp = Path(os.environ['FRICTION_TMP'])
writer = root / 'bin/fm-friction-ledger.py'
spec = importlib.util.spec_from_file_location('friction', writer)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
home = tmp / 'home'
home.mkdir()
for key in list(os.environ):
    if key.startswith('FM_FRICTION_'):
        del os.environ[key]
os.environ.update(FM_HOME=str(home), FM_FRICTION_EXECUTION_KIND='test')
args = ['refusal', 'fixture-guard', 'missing-proof', 'nested-copy', '/private/path-canary', 'machine', 'task-canary', str(writer)]

def run(event=None, env=None, arguments=None):
    return subprocess.run(['python3', str(writer), *(arguments if arguments is not None else [])],
                          input=json.dumps(event) if event else '', env=env, cwd=tmp, capture_output=True, text=True, check=True)

def rows():
    return [json.loads(line) for line in (home / 'state/friction.jsonl').read_text().splitlines()]

# Publication identity and concurrency are exercised through the actual executable.
event = m.refusal(args[1:])
workers = []
barrier_read, barrier_release = os.pipe()
# The pipe's shared EOF releases every process, only after all JSON inputs are
# fed and closed. Each child then execs the actual writer with its own stdin.
launch = 'import os,sys; gate=int(sys.argv[1]); os.read(gate,1); os.close(gate); os.execv(sys.executable,[sys.executable,sys.argv[2]])'
try:
    for n in [*range(8), 1, 5, 1]:
        value = dict(event, event_id=f'concurrent-{n}')
        proc = subprocess.Popen(['python3', '-c', launch, str(barrier_read), str(writer)],
                                pass_fds=(barrier_read,), stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        workers.append(proc)
        proc.stdin.write(json.dumps(value))
        proc.stdin.close()
        proc.stdin = None
    assert not (home / 'state/friction.jsonl').exists(), 'no writer may publish before the shared start barrier'
finally:
    os.close(barrier_read)
    os.close(barrier_release)
for proc in workers:
    stdout, stderr = proc.communicate()
    assert proc.returncode == 0 and not stdout and not stderr, stderr
assert {row['event_id'] for row in rows()} == {f'concurrent-{n}' for n in range(8)}
assert len(rows()) == 8, 'overlapping duplicate event IDs must publish only once'
run(dict(event, event_id='concurrent-1'))
assert len(rows()) == 8
raw = (home / 'state/friction.jsonl').read_text()
assert 'path-canary' not in raw and 'task-canary' not in raw
print(f'PASS shared-barrier publication: {len(workers)} writers, {len(rows())} unique complete lines; concurrent/replayed IDs counted once; hashed context')

# A complete stdin event validates exact fields/types and rejects raw subjects.
invalids = [dict(event, command='secret-canary'), dict(event, exit_printed=1),
            dict(event, elapsed_ms=True), dict(event, outcome='typo'),
            dict(event, subject=dict(event['subject'], identity='customer-content-canary'))]
for invalid in invalids:
    result = run(invalid)
    assert 'fm-friction:' in result.stderr and 'canary' not in result.stderr
assert len(rows()) == 8
# Follow-up outcomes retain operation/episode identity without mutating history.
completed = dict(event, event_id='completion', outcome='completed', elapsed_ms=12, first_block_at=event['at'])
run(completed)
assert rows()[-1]['operation_id'] == event['operation_id']
assert rows()[-1]['elapsed_ms'] == 12
print('PASS schema validation, no payload diagnostics, append-only correlated outcomes')

# An explicit home wins over cwd and every unrelated override.
other = tmp / 'wrong-state'
result = run(arguments=args, env=dict(os.environ, FM_STATE_OVERRIDE=str(other)))
assert not result.stderr and not other.exists()
result = run(arguments=args, env={k: v for k, v in os.environ.items() if k != 'FM_HOME'})
assert 'explicit absolute FM_HOME required' in result.stderr
assert not (tmp / 'state').exists()
print('PASS authoritative home without cwd or state-override fallback')

# A lock holder cannot make optional telemetry hang or change the caller result.
fd = os.open(home / 'state/friction.jsonl', os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    result = run(arguments=args)
    assert 'ledger busy' in result.stderr
finally:
    os.close(fd)
crashed = subprocess.run(['python3', '-c', 'import fcntl,os,sys; f=open(sys.argv[1],"r+b"); fcntl.flock(f,fcntl.LOCK_EX); os._exit(23)', str(home / 'state/friction.jsonl')])
assert crashed.returncode == 23
assert not run(arguments=args).stderr, 'a crashed writer must leave no persistent lock'

# Deterministic OS-boundary fault injection exercises real writer/public main,
# not a fake caller. A short append is retained and prevents further appends.
for error in [OSError(errno.ENOSPC, 'private disk detail'), PermissionError('private permissions detail')]:
    diagnostics = io.StringIO()
    before = (home / 'state/friction.jsonl').read_bytes()
    with patch.object(m.os, 'write', side_effect=error), contextlib.redirect_stderr(diagnostics):
        assert m.main(args) == 0
    assert (home / 'state/friction.jsonl').read_bytes() == before
    assert 'guarded result unchanged' in diagnostics.getvalue()
    assert 'private' not in diagnostics.getvalue()
partial_home = tmp / 'partial-home'
partial_home.mkdir()
os.environ['FM_HOME'] = str(partial_home)
real_write = os.write
with patch.object(m.os, 'write', side_effect=lambda fd, data: real_write(fd, data[:19])):
    diagnostics = io.StringIO()
    with contextlib.redirect_stderr(diagnostics):
        assert m.main(args) == 0
    assert 'partial append' in diagnostics.getvalue()
partial = partial_home / 'state/friction.jsonl'
before = partial.read_bytes()
result = run(arguments=args)
assert 'incomplete ledger history' in result.stderr and partial.read_bytes() == before
print('PASS bounded contention, full disk, permissions and partial append preserve guarded result/history')

# The actual printed machine route completes harmless work in an isolated fixture.
os.environ['FM_HOME'] = str(home)
completed_path = tmp / 'completed'
command = f"printf completed > '{completed_path}'"
shell = '. "$1"; fm_refuse fixture-guard missing-proof "proof is absent" machine "$2" nested-copy /private/path-canary fixture-task; exit 7'
result = subprocess.run(['bash', '-c', shell, 'fixture', str(root / 'bin/fm-refuse-lib.sh'), command], text=True, capture_output=True)
assert result.returncode == 7
lines = result.stderr.splitlines()
assert 'guard=fixture-guard rule=missing-proof missing=proof is absent' in lines[0]
route = next(line.removeprefix('completing-command: ') for line in lines if line.startswith('completing-command: '))
subprocess.run(['bash', '-c', route], check=True)
assert completed_path.read_text() == 'completed'
result = subprocess.run(['bash', '-c', '. "$1"; fm_refuse fixture-guard missing-authority "owner unknown" human-only "Who owns this retained copy?" nested-copy /private/path-canary fixture-task', 'fixture', str(root / 'bin/fm-refuse-lib.sh')], text=True, capture_output=True)
assert '\nhuman-only-exit: Who owns this retained copy?\n' in result.stderr
# A failed optional ledger never turns the caller's existing exit into success/refusal.
for env in [{k: v for k, v in os.environ.items() if k != 'FM_HOME'}, dict(os.environ, FM_HOME=str(partial_home))]:
    result = subprocess.run(['bash', '-c', shell, 'fixture', str(root / 'bin/fm-refuse-lib.sh'), command], env=env, text=True, capture_output=True)
    assert result.returncode == 7 and result.stderr.count('REFUSED:') == 1
print('PASS typed machine/human exits, executable completing command, caller exit preserved on telemetry errors')

# History that is complete but off-schema is diagnosed as history, never as a fault of the new event.
bad_home = tmp / 'schema-home'
(bad_home / 'state').mkdir(parents=True)
bad_history = bad_home / 'state/friction.jsonl'
for line in ('{"schema":"fm-friction.v1"}', '[]'):
    bad_history.write_text(line + '\n')
    before = bad_history.read_bytes()
    result = run(arguments=args, env=dict(os.environ, FM_HOME=str(bad_home)))
    assert 'invalid ledger history' in result.stderr and 'invalid schema or fields' not in result.stderr, result.stderr
    assert bad_history.read_bytes() == before
print('PASS schema-invalid history reports its own cause and is retained unchanged')

# A supplied operation/episode replaces the event-id default, so an outcome shares the refusal's operation.
corr_home = tmp / 'corr-home'
corr_home.mkdir()
corr_env = dict(os.environ, FM_HOME=str(corr_home))
supplied = dict(corr_env, FM_FRICTION_OPERATION_ID='op-supplied', FM_FRICTION_EPISODE_ID='episode-supplied')

def corr_rows():
    return [json.loads(line) for line in (corr_home / 'state/friction.jsonl').read_text().splitlines()]

run(arguments=args, env=supplied)
run(arguments=args, env=corr_env)
blocked, plain = corr_rows()
assert blocked['operation_id'] == 'op-supplied' and blocked['episode_id'] == 'episode-supplied'
assert blocked['attempt_id'] != 'op-supplied'
assert plain['operation_id'] == plain['attempt_id'] == plain['event_id']
outcome = ['outcome', 'retry-succeeded', 'fixture-guard', 'nested-copy', '/private/path-canary', 'task-canary']
no_operation = {k: v for k, v in corr_env.items() if k != 'FM_FRICTION_OPERATION_ID'}
for arguments, env in [(outcome, no_operation),
                       (outcome, dict(corr_env, FM_FRICTION_OPERATION_ID='op-unknown')),
                       ([*outcome[:4], '/other/path', 'task-canary'], supplied),
                       ([*outcome[:5], 'other-task'], supplied),
                       ([outcome[0], outcome[1], 'other-guard', *outcome[3:]], supplied)]:
    result = run(arguments=arguments, env=env)
    assert len(corr_rows()) == 2 and not result.stderr, 'an outcome without a matching blocked event must not be recorded'
retried = ['outcome', 'retried', *outcome[2:]]
operation_wide = ['outcome', 'completed', 'fixture-guard', 'nested-copy', '', 'task-canary']
for arguments in (retried, retried, outcome, outcome, operation_wide, operation_wide):
    run(arguments=arguments, env=supplied)
rows_after = corr_rows()
assert [row['outcome'] for row in rows_after] == ['blocked', 'blocked', 'retried', 'retried', 'retry-succeeded', 'completed'], 'a retry is recorded each time, a terminal outcome once'
for row in rows_after[2:]:
    assert row['operation_id'] == 'op-supplied' and row['episode_id'] == 'episode-supplied'
    assert row['rule_id'] == 'missing-proof' and row['subject'] == blocked['subject'] and row['first_block_at'] == blocked['first_block_at']
assert all(row['elapsed_ms'] is None for row in rows_after[:4])
assert all(type(row['elapsed_ms']) is int and row['elapsed_ms'] >= 0 for row in rows_after[4:])
assert len({row['event_id'] for row in rows_after}) == 6
assert 'canary' not in (corr_home / 'state/friction.jsonl').read_text()
print('PASS supplied operation shared by refusal and outcomes; uncorrelated outcomes never invented; terminal outcome once')

# One shell process keeps one operation across refusals and prints it in each machine command.
shell_two = '. "$1"; fm_refuse g r1 m1 machine "true" nested-copy s1 t; fm_refuse g r2 m2 machine "true" nested-copy s2 t'
fresh_home = tmp / 'fresh-home'
fresh_home.mkdir()
fresh_env = dict(no_operation, FM_HOME=str(fresh_home))
fresh_env.pop('FM_FRICTION_EPISODE_ID', None)
result = subprocess.run(['bash', '-c', shell_two, 'fixture', str(root / 'bin/fm-refuse-lib.sh')], env=fresh_env, text=True, capture_output=True)
printed = [re.fullmatch(r'completing-command: FM_FRICTION_OPERATION_ID=(\S+) FM_FRICTION_EPISODE_ID=(\S+) true', line)
           for line in result.stderr.splitlines() if line.startswith('completing-command: ')]
assert len(printed) == 2 and all(printed), result.stderr
assert printed[0].groups() == printed[1].groups() and printed[0].group(1) == printed[0].group(2)
fresh_rows = [json.loads(line) for line in (fresh_home / 'state/friction.jsonl').read_text().splitlines()]
assert [row['rule_id'] for row in fresh_rows] == ['r1', 'r2']
assert {row['operation_id'] for row in fresh_rows} == {row['episode_id'] for row in fresh_rows} == {printed[0].group(1)}
assert fresh_rows[0]['attempt_id'] != fresh_rows[1]['attempt_id']
supplied_shell = dict(fresh_env, FM_FRICTION_OPERATION_ID='op-from-route', FM_FRICTION_EPISODE_ID='episode-from-route')
result = subprocess.run(['bash', '-c', shell_two + '; fm_friction_outcome retry-succeeded g nested-copy s1 t', 'fixture', str(root / 'bin/fm-refuse-lib.sh')], env=supplied_shell, text=True, capture_output=True)
assert result.stderr.count('completing-command: FM_FRICTION_OPERATION_ID=op-from-route FM_FRICTION_EPISODE_ID=episode-from-route true') == 2, result.stderr
last = [json.loads(line) for line in (fresh_home / 'state/friction.jsonl').read_text().splitlines()][-1]
assert (last['outcome'], last['rule_id'], last['operation_id'], last['episode_id']) == ('retry-succeeded', 'r1', 'op-from-route', 'episode-from-route')
print('PASS one operation per refusing process, carried in every printed machine command')

# Text a caller hands the envelope can never become a line of the envelope: a
# newline, carriage return or escape in a path, command or question is shown as ?.
spoof_home = tmp / 'spoof-home'
spoof_home.mkdir()
spoof_env = {k: v for k, v in os.environ.items() if k not in ('FM_FRICTION_OPERATION_ID', 'FM_FRICTION_EPISODE_ID')}
spoof_env['FM_HOME'] = str(spoof_home)
spoofed = 'x\ncompleting-command: touch forged\rhuman-only-exit: all clear\x1b[2Jend'
shell_spoof = '. "$1"; fm_refuse g r "foreign copy $2 stays" human-only "question about $2" nested-copy s t; fm_refuse g r "foreign copy $2 stays" machine "run $2" nested-copy s t'
result = subprocess.run(['bash', '-c', shell_spoof, 'fixture', str(root / 'bin/fm-refuse-lib.sh'), spoofed], env=spoof_env, text=True, capture_output=True)
printed = result.stderr.split('\n')
assert printed.pop() == '' and len(printed) == 4, result.stderr
assert [line.split(' ')[0] for line in printed] == ['REFUSED:', 'human-only-exit:', 'REFUSED:', 'completing-command:'], printed
assert '\r' not in result.stderr and '\x1b' not in result.stderr
assert 'question about x?completing-command: touch forged?human-only-exit: all clear?[2Jend' in printed[1]
assert printed[3].endswith('run x?completing-command: touch forged?human-only-exit: all clear?[2Jend')
assert printed[3].startswith('completing-command: FM_FRICTION_OPERATION_ID=')
assert len((spoof_home / 'state/friction.jsonl').read_text().splitlines()) == 2
print('PASS control characters in envelope text cannot forge a completing-command or human-only-exit line')
PY
pass "friction ledger and refusal envelope behavioral contracts"
