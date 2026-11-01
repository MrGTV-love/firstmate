#!/usr/bin/env bash
# Synthetic registered-home mirror/poll roundtrip; no credentials or network.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v tasks-axi >/dev/null || { printf 'skip: tasks-axi not found\n'; exit 0; }
TMP=$(fm_test_tmproot fm-slack-secondmates)
python3 - "$ROOT" "$TMP" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root, tmp = map(Path, sys.argv[1:])
env = dict(os.environ, SLACK_BOT_TOKEN='fixture', FM_SLACK_DM_USER='U0TESTOWNER',
           FM_SLACK_ALLOWED_AUTHORS='U0TESTOWNER', FM_SLACK_POLL_MAX_ANSWERS='20')
for key in ('FM_ROOT_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_SLACK_FAULT'):
    env.pop(key, None)

def home_env(home):
    return dict(env, FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / 'state'),
                FM_DATA_OVERRIDE=str(home / 'data'), FM_CONFIG_OVERRIDE=str(home / 'config'))

def call(home, script, *args, text=None, code=0, extra=None):
    result = subprocess.run(['bash', str(root / 'bin' / script), *args], input=text,
                            text=True, capture_output=True, env=dict(home_env(home), **(extra or {})))
    assert result.returncode == code, (script, result.returncode, result.stdout, result.stderr)
    return result.stdout

main, local, remote = [tmp / name for name in ('main', 'local', 'remote')]
for home in (main, local, remote):
    subprocess.run(['bash', str(root / 'tests/fixtures/slack/make-home.sh'), 'config', str(home)],
                   env=home_env(home), check=True, capture_output=True)
    call(home, 'fm-captain-hold.sh', 'answers', '--any-origin', '--source', 'fixture',
         text='config-call\tconfiguration fixture complete\t\tdone\n')
    # Identical keys intentionally prove routing cannot be inferred from the task id.
    call(home, 'fm-captain-hold.sh', 'hold', 'shared-call', '--title', 'Choose the release',
         '--reason', 'Which release?', extra={'FM_CAPTAIN_HOLD_NOW': '2026-10-01T00:00:00Z'})

registry = main / 'data/secondmates.md'
registry.write_text(f'- local - Local lane (home: {local}; scope: local; projects: sample; added 2026-10-01)\n'
                    f'- remote - Remote lane (host: fixture-host; root: {root}; home: {remote}; scope: remote; projects: sample; added 2026-10-01)\n')
ssh = tmp / 'ssh'
ssh.write_text('''#!/usr/bin/env python3
import base64, json, os
from pathlib import Path
import sys
args = sys.argv[1:]
i = args.index('fm-remote-entrypoint.sh')
assert args[i-1] == 'fixture-host'
root = base64.b64decode(args[i+2]).decode()
home = base64.b64decode(args[i+3]).decode()
argv = base64.b64decode(args[i+4]).decode().rstrip('\\0').split('\\0')
assert argv[0] in ('fm-fleet-snapshot.sh', 'fm-remote-file.sh', 'fm-captain-hold.sh'), argv
assert not any(key.startswith('SLACK_') for key in os.environ)
with open(Path(home).parent / 'routes.jsonl', 'a') as log:
    log.write(json.dumps({'root': root, 'home': home, 'argv': argv}) + '\\n')
if os.environ.get('FIXTURE_REMOTE_BANNER'):
    sys.stderr.write('Authorized users only. Activity may be monitored.\\n')
if not os.path.isdir(home):
    sys.stderr.write('error: remote home is not a safe directory\\n')
    sys.exit(64)
if os.environ.get('FIXTURE_REMOTE_ANSWERS_FAIL') and argv[:2] == ['fm-captain-hold.sh', 'answers']:
    sys.stderr.write('error: remote job did not complete\\n')
    sys.exit(70)
env = dict(os.environ, FM_HOME=home, FM_STATE_OVERRIDE=home+'/state',
           FM_DATA_OVERRIDE=home+'/data', FM_CONFIG_OVERRIDE=home+'/config')
os.execve('/bin/bash', ['bash', root+'/bin/'+argv[0], *argv[1:]], env)
''')
ssh.chmod(0o700)
env['FM_SSH_BIN'] = str(ssh)
transcript = root / 'tests/fixtures/slack/card-payload/transcript.json'
args = ('--replay', str(transcript))
call(main, 'fm-slack-mirror.sh', *args)
state_path = main / 'state/slack-watch/state.json'
state = json.loads(state_path.read_text())
records = [row for row in state['threads'].values() if row['key'] == 'shared-call']
assert len(records) == 3, ('expected main, local and remote cards', records)
call(main, 'fm-slack-mirror.sh', *args)
assert len(json.loads(state_path.read_text())['threads']) == 3, ('duplicate cards', json.loads(state_path.read_text())['threads'])
replay_path = next((main / 'state/slack-watch').glob('replay-state-*.json'))
replay = json.loads(replay_path.read_text())
for record in records:
    card = next(m['text'] for m in replay['messages'] if m['ts'] == record['ts'])
    for field in ('Task: shared-call', 'Decision: ', 'Recommendation: ', 'Evidence: '):
        assert field in card, (field, card)
print('M1: main/local/remote shared-call each has one four-part card; repeat mirror adds none')

before_main = (main / 'data/backlog.md').read_bytes()
for owner in ('local', 'remote'):
    state = json.loads(state_path.read_text())
    record = next(r for r in state['threads'].values() if r.get('owner', {}).get('id') == owner)
    replay = json.loads(replay_path.read_text())
    replay['messages'].append({'ts': '999.00000' + ('1' if owner == 'local' else '2'),
                               'thread_ts': record['ts'], 'user': 'U0TESTOWNER', 'text': 'ship this release'})
    replay_path.write_text(json.dumps(replay))
    call(main, 'fm-slack-poll.sh', *args, extra={'FM_SLACK_FAULT': 'after-stage'}, code=75)
    pending = json.loads(state_path.read_text())['pending']
    assert pending and pending[0]['owner']['id'] == owner, pending
    out = call(main, 'fm-slack-poll.sh', *args)
    assert 'closed: shared-call' in out, out
    owner_home = local if owner == 'local' else remote
    call(owner_home, 'fm-captain-hold.sh', 'open', 'shared-call', code=1)
    call(main, 'fm-captain-hold.sh', 'open', 'shared-call')
    assert (main / 'data/backlog.md').read_bytes() == before_main, 'main record changed'
    assert 'ship this release' in (owner_home / 'data/backlog.md').read_text()
    print(f'M2: {owner} shared-call open -> closed after persisted-answer reload; main shared-call open and byte-identical')
routes = [json.loads(line) for line in (tmp / 'routes.jsonl').read_text().splitlines()]
assert any(r['home'] == str(remote) and r['argv'][:2] == ['fm-captain-hold.sh', 'answers'] for r in routes), routes
print('M2: remote answers used existing fm-on route and fm-captain-hold.sh answers')

registered = registry.read_text()
with registry.open('a') as handle:
    handle.write(f'- unreadable - Missing lane (home: {tmp}/missing; scope: missing; projects: sample; added 2026-10-01)\n')
out = call(main, 'fm-slack-mirror.sh', *args, code=1)
assert 'unreadable' in out and str(tmp / 'missing') in out, out
print('M3 local: ' + out.strip())
registry.write_text(registered + f'- remote-unreadable - Missing remote lane (host: fixture-host; root: {root}; home: {tmp}/remote-missing; scope: missing; projects: sample; added 2026-10-01)\n')
out = call(main, 'fm-slack-mirror.sh', *args, code=1)
assert 'remote-unreadable' in out and str(tmp / 'remote-missing') in out, out
print('M3 remote: ' + out.strip())
main_record = next(r for r in records if not r.get('owner'))
replay = json.loads(replay_path.read_text())
replay['messages'].append({'ts': '999.000003', 'thread_ts': main_record['ts'],
                           'user': 'U0TESTOWNER', 'text': 'main release'})
replay_path.write_text(json.dumps(replay))
out = call(main, 'fm-slack-poll.sh', *args, code=1)
assert 'closed: shared-call' in out, out
call(main, 'fm-captain-hold.sh', 'open', 'shared-call', code=1)
print('M4: main answer still closes main despite unreadable registered remote home')
def owned(key, owner_id):
    return [r for r in json.loads(state_path.read_text())['threads'].values()
            if r['key'] == key and r.get('owner', {}).get('id') == owner_id]

def reply(record, ts, text):
    replay = json.loads(replay_path.read_text())
    replay['messages'].append({'ts': ts, 'thread_ts': record['ts'], 'user': 'U0TESTOWNER', 'text': text})
    replay_path.write_text(json.dumps(replay))

def posted(needle):
    return [m for m in json.loads(replay_path.read_text())['messages'] if needle in m.get('text', '')]

registry.write_text(registered)
call(remote, 'fm-captain-hold.sh', 'hold', 'moved-call', '--title', 'Pick the target',
     '--reason', 'Which target?', extra={'FM_CAPTAIN_HOLD_NOW': '2026-10-02T00:00:00Z'})
call(main, 'fm-slack-mirror.sh', *args)
assert len(owned('moved-call', 'remote')) == 1, owned('moved-call', 'remote')
moved_root = tmp / 'moved-root'
moved_root.symlink_to(root)
registry.write_text(registered.replace(f'root: {root};', f'root: {moved_root};'))
call(main, 'fm-slack-mirror.sh', *args)
moved = owned('moved-call', 'remote')
assert len(moved) == 1 and len(posted('Task: moved-call')) == 1, ('root move duplicated the card', moved)
reply(moved[0], '999.000004', 'target a')
out = call(main, 'fm-slack-poll.sh', *args)
assert 'closed: moved-call' in out, out
call(remote, 'fm-captain-hold.sh', 'open', 'moved-call', code=1)
routes = [json.loads(line) for line in (tmp / 'routes.jsonl').read_text().splitlines()]
answer = [r for r in routes if r['argv'][:2] == ['fm-captain-hold.sh', 'answers']][-1]
assert answer['root'] == str(moved_root) and answer['home'] == str(remote), answer
print('F3 root move: one moved-call card; its answer closed remote through the moved code root')

call(local, 'fm-captain-hold.sh', 'hold', 'orphan-call', '--title', 'Pick the lane',
     '--reason', 'Which lane?', extra={'FM_CAPTAIN_HOLD_NOW': '2026-10-03T00:00:00Z'})
call(main, 'fm-slack-mirror.sh', *args)
orphan = owned('orphan-call', 'local')
assert len(orphan) == 1, orphan
reply(orphan[0], '999.000005', 'lane a')
call(main, 'fm-slack-poll.sh', *args, extra={'FM_SLACK_FAULT': 'after-stage'}, code=75)
pending = json.loads(state_path.read_text())['pending']
assert pending and pending[0]['owner']['id'] == 'local', pending
remote_line = next(line for line in registered.splitlines(True) if line.startswith('- remote '))
main_before = (main / 'data/backlog.md').read_bytes()
registry.write_text(remote_line + f'- unreadable - Missing lane (home: {tmp}/missing; scope: missing; projects: sample; added 2026-10-01)\n')
out = call(main, 'fm-slack-poll.sh', *args, code=1)
assert 'secondmate_home_unavailable: unreadable (%s/missing)' % tmp in out, out
assert out.count('orphaned thread: orphan-call from unregistered secondmate local') == 1, out
assert 'reply for an unregistered secondmate home: orphan-call' in out and 'closed: orphan-call' not in out, out
assert not json.loads(state_path.read_text())['pending'], 'refused answer stayed journaled'
assert posted('Answer not applied') and len(posted('Orphaned: orphan-call')) == 1, 'missing thread refusal'
call(local, 'fm-captain-hold.sh', 'open', 'orphan-call')
assert (main / 'data/backlog.md').read_bytes() == main_before, 'main record changed'
print('F3 removed home: answer refused, local orphan-call still open, one orphan report beside the unreadable-home refusal')
registry.write_text(remote_line)
out = call(main, 'fm-slack-poll.sh', *args)
assert 'orphaned thread' not in out and 'secondmate_home_unavailable' not in out, out
print('F3 orphan: reported once; later polls succeed without a lasting error')
def held(home, key, at):
    call(home, 'fm-captain-hold.sh', 'hold', key, '--title', 'Decide ' + key,
         '--reason', 'Which way for ' + key + '?', extra={'FM_CAPTAIN_HOLD_NOW': at})

empty, empty_remote = tmp / 'empty', tmp / 'empty-remote'
for home in (empty, empty_remote):
    for directory in ('data', 'state', 'config', 'projects'):
        (home / directory).mkdir(parents=True)
registry.write_text(registered
                    + f'- empty - Empty lane (home: {empty}; scope: empty; projects: sample; added 2026-10-01)\n'
                    + f'- empty-remote - Empty remote lane (host: fixture-host; root: {root}; home: {empty_remote}; scope: empty; projects: sample; added 2026-10-01)\n')
out = call(main, 'fm-slack-mirror.sh', *args)
assert 'secondmate_home_unavailable' not in out, out
print('R2-1: readable local and remote homes without data/backlog.md have no calls, not a refusal')

registry.write_text(registered)
held(local, 'snapshot-call', '2026-10-04T00:00:00Z')
backlog_file = main / 'data/backlog.md'
mode = backlog_file.stat().st_mode & 0o777
backlog_file.chmod(0)
try:
    out = call(main, 'fm-slack-mirror.sh', *args, code=1)
finally:
    backlog_file.chmod(mode)
assert 'backlog_unavailable' in out and len(owned('snapshot-call', 'local')) == 1, (out, owned('snapshot-call', 'local'))
print('R2-2: failed main snapshot is reported and the readable local snapshot-call still gets its card')

held(remote, 'routed-call', '2026-10-05T00:00:00Z')
call(main, 'fm-slack-mirror.sh', *args)
routed = owned('routed-call', 'remote')
assert len(routed) == 1, routed
out = call(main, 'fm-slack-poll.sh', *args, code=1, extra={'FM_SSH_ALIVE_INTERVAL': 'bad'})
assert 'secondmate_home_unavailable: remote (%s)' % remote in out, out
assert not owned('routed-call', 'remote')[0]['retired'] and not posted('Resolved: routed-call'), out
call(remote, 'fm-captain-hold.sh', 'open', 'routed-call')
reply(routed[0], '999.000006', 'route a')
out = call(main, 'fm-slack-poll.sh', *args)
assert 'closed: routed-call' in out, out
call(remote, 'fm-captain-hold.sh', 'open', 'routed-call', code=1)
print('F2: an fm-on.sh routing refusal left routed-call held and tracked; a later answer closed it in remote')

def blocked_owner_answer(owner_home, owner_id, key, at, fail_registry=None, fail_env=None):
    held(owner_home, key + '-sm', at)
    held(main, key + '-main', at)
    call(main, 'fm-slack-mirror.sh', *args)
    reply(owned(key + '-sm', owner_id)[0], '999.1' + at[8:10] + '1', 'secondmate answer')
    call(main, 'fm-slack-poll.sh', *args, extra={'FM_SLACK_FAULT': 'after-stage'}, code=75)
    pending = json.loads(state_path.read_text())['pending']
    assert len(pending) == 1 and pending[0]['owner']['id'] == owner_id, pending
    reply(owned(key + '-main', None)[0], '999.1' + at[8:10] + '2', 'main answer')
    if fail_registry:
        registry.write_text(registered + fail_registry)
    out = call(main, 'fm-slack-poll.sh', *args, code=1, extra=fail_env)
    registry.write_text(registered)
    assert 'closed: %s-main' % key in out and 'closed: %s-sm' % key not in out, out
    call(main, 'fm-captain-hold.sh', 'open', key + '-main', code=1)
    call(owner_home, 'fm-captain-hold.sh', 'open', key + '-sm')
    assert len(json.loads(state_path.read_text())['pending']) == 1, 'secondmate answer left the journal'
    later = call(main, 'fm-slack-poll.sh', *args)
    assert 'closed: %s-sm' % key in later, later
    call(owner_home, 'fm-captain-hold.sh', 'open', key + '-sm', code=1)
    return out

out = blocked_owner_answer(local, 'local', 'registry', '2026-10-06T00:00:00Z',
                           fail_registry=f'- broken - Broken lane (home: {tmp}/no-parent/sm; scope: broken; projects: sample; added 2026-10-01)\n')
assert 'secondmate_registry_unavailable: unresolvable secondmate home for broken' in out, out
print('F1 registry: refused registry kept the local answer journaled, main answer closed; answer delivered after repair')
out = blocked_owner_answer(remote, 'remote', 'intake', '2026-10-07T00:00:00Z',
                           fail_env={'FIXTURE_REMOTE_ANSWERS_FAIL': '1'})
assert 'secondmate_answer_intake_failed: remote (%s)' % remote in out, out
print('F1 intake: failed remote intake kept its answer journaled, main answer closed; answer delivered after recovery')
held(remote, 'banner-call', '2026-10-08T00:00:00Z')
call(main, 'fm-slack-mirror.sh', *args)
assert len(owned('banner-call', 'remote')) == 1, owned('banner-call', 'remote')
call(remote, 'fm-captain-hold.sh', 'answers', '--any-origin', '--source', 'fixture',
     text='banner-call\tclosed in the remote home\t\tdone\n')
out = call(main, 'fm-slack-poll.sh', *args, extra={'FIXTURE_REMOTE_BANNER': '1'})
assert 'secondmate_home_unavailable' not in out, out
assert owned('banner-call', 'remote')[0]['retired'] and len(posted('Resolved: banner-call')) == 1, out
print('R3-1: SSH banner stderr on a closed remote probe still resolves and retires banner-call')

held(local, 'response-call', '2026-10-09T00:00:00Z')
identity = call(local, 'fm-captain-hold.sh', 'open', 'response-call', '--identity').strip()
owner = {'id': 'local', 'home': str(local), 'host': ''}
occurrence = json.dumps(owner, sort_keys=True) + ':response-call:' + identity
replay = json.loads(replay_path.read_text())
replay['messages'].append({'user': 'UBOT0123456', 'text': 'card without ts',
                           'metadata': {'event_type': 'slack-watch', 'event_payload': {
                               'id': hashlib.sha256(('card:' + occurrence).encode()).hexdigest()}}})
replay_path.write_text(json.dumps(replay))
out = call(main, 'fm-slack-mirror.sh', *args, code=1)
assert 'local_state_or_response_error' in out and 'secondmate_home_unavailable' not in out, out
replay = json.loads(replay_path.read_text())
replay['messages'] = [m for m in replay['messages'] if 'ts' in m]
replay_path.write_text(json.dumps(replay))
call(main, 'fm-slack-mirror.sh', *args)
assert len(owned('response-call', 'local')) == 1, owned('response-call', 'local')
print('R3-2: a Slack response without ts is reported as itself, not as an unreadable local home')
print('ok - registered-home cards and crash/reload owner-home answer roundtrip')
PY
