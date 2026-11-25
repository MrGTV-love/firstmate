#!/usr/bin/env bash
# Exercise only the resume CLI and its scoped event writer, never a launcher.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
python3 -IBS - "$ROOT/bin/fm-dsh.py" <<'PY'
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

assert os.geteuid() != 0, 'run this permission regression as an unprivileged user'
assert shutil.which('jq'), 'the existing guard-event writer requires jq'
owner = sys.argv[1]
uid = '11111111-1111-4111-8111-111111111111'
with tempfile.TemporaryDirectory(prefix='fm-dsh-resume-') as temp:
    cwd = Path(temp).resolve()
    state = cwd / 'state'
    runtime = state / 'task.dsh/g1'
    session = runtime / 'dsh/sessions/workspace/session/session.v4.jsonl'
    session.parent.mkdir(parents=True)
    session.write_text(json.dumps({'type': 'session', 'cwd': str(cwd), 'delegationDepth': 0, 'id': uid}) + '\n')
    binding = state / 'task.dsh-session'
    event_log = state / 'guard-events.jsonl'
    overlay = runtime / 'launch.yml'
    overlay.write_bytes(b'[]\n')
    decoy_log = cwd / 'not-the-guard-log'
    decoy_log.write_bytes(b'untouched\n')
    env = {'PATH': os.environ['PATH'], 'HOME': temp, 'TMPDIR': temp, 'LC_ALL': 'C',
           'FM_HOME': temp, 'FM_GUARD_EVENT_LOG': str(decoy_log)}

    def resume(model='v4', *, record=True):
        argv = [sys.executable, '-IBS', owner, 'resume', str(state), 'task', f'deepseek/{model}', 'high', str(cwd)]
        if record:
            argv.append('--record-binding-decision')
        result = subprocess.run(argv, env=env, cwd=cwd, capture_output=True, text=True, check=False)
        assert decoy_log.read_bytes() == b'untouched\n', 'resume wrote outside its state log'
        return result.returncode, result.stdout, result.stderr

    def events():
        return [(row['guard'], row['task'], row['decision'], row['source_ok'], row['opportunity'])
                for row in map(json.loads, event_log.read_text().splitlines())]

    assert resume() == (0, '', '') and not event_log.exists(), 'absent binding is not a read opportunity'
    binding.write_text('{not json}')
    assert resume(record=False) == (0, '', '') and not event_log.exists(), 'standalone parse fallback stays quiet'
    binding.write_text(json.dumps({'root': str(runtime), 'cwd': str(cwd), 'model': 'v4', 'effort': 'high'}))
    binding.chmod(0o600)
    assert resume('other', record=False) == (0, '', '') and not event_log.exists(), 'standalone mismatch stays quiet'
    original = binding.stat().st_ino, binding.read_bytes(), session.stat().st_ino, session.read_bytes()
    before = set(state.rglob('*'))
    binding.chmod(0)
    try:
        try:
            binding.read_bytes()
        except PermissionError as error:
            assert error.errno == errno.EACCES
        else:
            raise AssertionError('expected kernel EACCES on the same binding')
        rc, out, diagnostic = resume(record=False)
        assert rc == 1 and not out and not event_log.exists(), 'standalone refusal must not write a receipt'
        assert str(binding) in diagnostic and 'restore read access to the same saved record' in diagnostic, diagnostic
        assert 'without removing or replacing it' in diagnostic, diagnostic
        assert resume() == (rc, out, diagnostic), 'recording must not alter the CLI result'
        assert events() == [('dsh-resume-binding-read', 'task', 'deny', False, True)]
        assert overlay.read_bytes() == b'[]\n' and set(state.rglob('*')) == before | {event_log}
    finally:
        binding.chmod(0o600)

    assert resume() == (0, f'{runtime}\n', ''), 'restoring access must resume the recorded generation'
    assert events() == [('dsh-resume-binding-read', 'task', 'deny', False, True),
                        ('dsh-resume-binding-read', 'task', 'allow', True, True)]
    assert json.loads(overlay.read_text())[0]['config']['sessionId'] == uid
    assert (binding.stat().st_ino, binding.read_bytes(), session.stat().st_ino, session.read_bytes()) == original
    assert set(state.rglob('*')) == before | {event_log}, 'resume left a new generation or temporary file'
    event_log.unlink()
    event_log.symlink_to(decoy_log)
    assert resume('other') == (0, '', ''), 'an unsafe log target must not change readable mismatch'
    assert event_log.is_symlink(), 'resume replaced the unsafe log target'
print('ok - saved DSH read refusal records one decision, stays quiet outside relaunch, and restores the same session')
PY
