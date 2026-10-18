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
for n in range(8):
    value = dict(event, event_id=f'concurrent-{n}')
    proc = subprocess.Popen(['python3', str(writer)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    workers.append((proc, value))
for proc, value in workers:
    stdout, stderr = proc.communicate(json.dumps(value))
    assert proc.returncode == 0 and not stdout and not stderr, stderr
assert {row['event_id'] for row in rows()} == {f'concurrent-{n}' for n in range(8)}
run(dict(event, event_id='concurrent-1'))
assert len(rows()) == 8
raw = (home / 'state/friction.jsonl').read_text()
assert 'path-canary' not in raw and 'task-canary' not in raw
print('PASS concurrent complete lines, duplicate event id counted once, hashed context')

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
PY
pass "friction ledger and refusal envelope behavioral contracts"
