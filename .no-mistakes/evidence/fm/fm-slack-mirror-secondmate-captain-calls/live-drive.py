#!/usr/bin/env python3
"""Independent live drive of the real fm-slack-mirror.sh / fm-slack-poll.sh CLIs.
Disposable homes, Slack replay transcript (no network), fake ssh transport only.
Usage: live-drive.py <firstmate-root> <tmpdir> <mode: full|main-only>"""
import json, os, subprocess, sys, shutil
from pathlib import Path

root, tmp, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
env = dict(os.environ, SLACK_BOT_TOKEN='fixture', FM_SLACK_DM_USER='U0TESTOWNER',
           FM_SLACK_ALLOWED_AUTHORS='U0TESTOWNER', FM_SLACK_POLL_MAX_ANSWERS='20')
for k in ('FM_ROOT_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_SLACK_FAULT', 'FM_STATE_OVERRIDE',
          'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'NO_MISTAKES_GATE'):
    env.pop(k, None)

def henv(h):
    return dict(env, FM_HOME=str(h), FM_STATE_OVERRIDE=str(h/'state'),
                FM_DATA_OVERRIDE=str(h/'data'), FM_CONFIG_OVERRIDE=str(h/'config'))

def sh(h, script, *a, text=None, extra=None, show=True):
    r = subprocess.run(['bash', str(root/'bin'/script), *a], input=text, text=True,
                       capture_output=True, env=dict(henv(h), **(extra or {})))
    if show:
        print('$ %s %s   [home=%s]' % (script, ' '.join(a).replace(str(tmp), '$TMP'), h.name))
        for line in (r.stdout + r.stderr).splitlines():
            print('  | ' + line.replace(str(tmp), '$TMP'))
        print('  exit=%d' % r.returncode)
    return r

def hold(h, key, reason, at):
    sh(h, 'fm-captain-hold.sh', 'hold', key, '--title', 'Decide ' + key, '--reason', reason,
       extra={'FM_CAPTAIN_HOLD_NOW': at}, show=False)

def is_open(h, key):
    return sh(h, 'fm-captain-hold.sh', 'open', key, show=False).returncode == 0

names = ('main',) if mode == 'main-only' else ('main', 'local', 'remote')
homes = {n: tmp/n for n in names}
for n, h in homes.items():
    subprocess.run(['bash', str(root/'tests/fixtures/slack/make-home.sh'), 'config', str(h)],
                   env=henv(h), check=True, capture_output=True)
    sh(h, 'fm-captain-hold.sh', 'answers', '--any-origin', '--source', 'fixture',
       text='config-call\tconfiguration fixture complete\t\tdone\n', show=False)

hold(homes['main'], 'main-call', 'Ship v2 or wait for QA?', '2026-10-01T00:00:00Z')
transcript = tmp/'transcript.json'
shutil.copy(root/'tests/fixtures/slack/card-payload/transcript.json', transcript)
R = ('--replay', str(transcript))
main = homes['main']
state_path = main/'state/slack-watch/state.json'

def replay():
    p = next((main/'state/slack-watch').glob('replay-state-*.json'))
    return p, json.loads(p.read_text())

def reply(record, ts, text):
    p, r = replay()
    r['messages'].append({'ts': ts, 'thread_ts': record['ts'], 'user': 'U0TESTOWNER', 'text': text})
    p.write_text(json.dumps(r))

def cards():
    _, r = replay()
    return [m['text'] for m in r['messages'] if m.get('text', '').startswith(('Task', '*Task', 'Secondmate')) or 'Task:' in m.get('text', '')]

if mode == 'main-only':
    print('== main-only mirror ==')
    sh(main, 'fm-slack-mirror.sh', *R)
    for c in cards():
        print('--- CARD ---\n' + c)
    rec = next(r for r in json.loads(state_path.read_text())['threads'].values() if r['key'] == 'main-call')
    reply(rec, '999.000001', 'ship v2')
    print('== main-only poll after typed reply ==')
    sh(main, 'fm-slack-poll.sh', *R)
    print('main-call open after answer:', is_open(main, 'main-call'))
    _, r = replay()
    print('== all bot messages in DM ==')
    for m in r['messages']:
        if m.get('user') != 'U0TESTOWNER':
            print('--- MSG ---\n' + m.get('text', ''))
    sys.exit(0)

local, remote = homes['local'], homes['remote']
hold(local, 'lane-call', 'Use Postgres or SQLite for the lane store?', '2026-10-01T00:00:00Z')
hold(remote, 'remote-call', 'Deploy to us-east or eu-west?', '2026-10-01T00:00:00Z')
# Same id in main and local: routing must not be inferred from task id.
hold(main, 'dup-call', 'Main dup decision?', '2026-10-01T00:00:00Z')
hold(local, 'dup-call', 'Local dup decision?', '2026-10-01T00:00:00Z')
reg = main/'data/secondmates.md'
base_reg = (f'- local - Local lane (home: {local}; scope: local; projects: sample; added 2026-10-01)\n'
            f'- remote - Remote lane (host: fixture-host; root: {root}; home: {remote}; scope: remote; projects: sample; added 2026-10-01)\n')
reg.write_text(base_reg)
ssh = tmp/'ssh'
ssh.write_text('''#!/usr/bin/env python3
import base64, json, os, sys
from pathlib import Path
a = sys.argv[1:]; i = a.index('fm-remote-entrypoint.sh')
assert a[i-1] == 'fixture-host'
root = base64.b64decode(a[i+2]).decode(); home = base64.b64decode(a[i+3]).decode()
argv = base64.b64decode(a[i+4]).decode().rstrip('\\0').split('\\0')
with open(Path(home).parent / 'ssh-routes.jsonl', 'a') as f:
    f.write(json.dumps({'home': home, 'argv': argv, 'slack_env': [k for k in os.environ if k.startswith('SLACK_')]}) + '\\n')
if not os.path.isdir(home):
    sys.stderr.write('error: remote home is not a safe directory\\n'); sys.exit(64)
e = dict(os.environ, FM_HOME=home, FM_STATE_OVERRIDE=home+'/state', FM_DATA_OVERRIDE=home+'/data', FM_CONFIG_OVERRIDE=home+'/config')
os.execve('/bin/bash', ['bash', root+'/bin/'+argv[0], *argv[1:]], e)
''')
ssh.chmod(0o700)
env['FM_SSH_BIN'] = str(ssh)

print('== M1: mirror from main with local+remote registered ==')
sh(main, 'fm-slack-mirror.sh', *R)
threads = json.loads(state_path.read_text())['threads']
for occ, r in threads.items():
    print('thread key=%s owner=%s' % (r['key'], (r.get('owner') or {}).get('id', 'main')))
for c in cards():
    print('--- CARD ---\n' + c.replace(str(tmp), '$TMP'))
print('== M1: repeat mirror (must add no card) ==')
sh(main, 'fm-slack-mirror.sh', *R)
print('thread count before/after:', len(threads), len(json.loads(state_path.read_text())['threads']))

def owned(key, oid):
    return next(r for r in json.loads(state_path.read_text())['threads'].values()
                if r['key'] == key and (r.get('owner') or {}).get('id') == oid)

main_before = (main/'data/backlog.md').read_bytes()
print('== M2 local: typed answer to local dup-call card ==')
print('before: local dup-call open=%s main dup-call open=%s' % (is_open(local, 'dup-call'), is_open(main, 'dup-call')))
reply(owned('dup-call', 'local'), '999.000001', 'use the local answer')
sh(main, 'fm-slack-poll.sh', *R)
print('after: local dup-call open=%s main dup-call open=%s main backlog byte-identical=%s' % (
    is_open(local, 'dup-call'), is_open(main, 'dup-call'), (main/'data/backlog.md').read_bytes() == main_before))
print('local backlog has answer text:', 'use the local answer' in (local/'data/backlog.md').read_text())
print('== M2 remote: typed answer to remote-call card ==')
print('before: remote remote-call open=%s' % is_open(remote, 'remote-call'))
reply(owned('remote-call', 'remote'), '999.000002', 'eu-west')
sh(main, 'fm-slack-poll.sh', *R)
print('after: remote remote-call open=%s; main backlog byte-identical=%s' % (
    is_open(remote, 'remote-call'), (main/'data/backlog.md').read_bytes() == main_before))
routes = [json.loads(l) for l in (tmp/'ssh-routes.jsonl').read_text().splitlines()]
print('ssh route argv[0:2] seen:', sorted({' '.join(r['argv'][:2]) for r in routes}))
print('SLACK_* env leaked to ssh child:', any(r['slack_env'] for r in routes))

print('== M3a: registered local home that does not exist ==')
reg.write_text(base_reg + f'- ghost - Ghost lane (home: {tmp}/ghost; scope: g; projects: sample; added 2026-10-01)\n')
sh(main, 'fm-slack-mirror.sh', *R)
print('== M3b: registered local home that exists but is permission-denied (chmod 000) ==')
locked = tmp/'locked'
subprocess.run(['bash', str(root/'tests/fixtures/slack/make-home.sh'), 'config', str(locked)],
               env=henv(locked), check=True, capture_output=True)
hold(locked, 'locked-call', 'Locked?', '2026-10-01T00:00:00Z')
reg.write_text(base_reg + f'- locked - Locked lane (home: {locked}; scope: l; projects: sample; added 2026-10-01)\n')
os.chmod(locked, 0)
try:
    sh(main, 'fm-slack-mirror.sh', *R)
finally:
    os.chmod(locked, 0o700)
print('== M3c: registered remote home that is missing on the remote ==')
reg.write_text(base_reg + f'- far - Far lane (host: fixture-host; root: {root}; home: {tmp}/far-missing; scope: f; projects: sample; added 2026-10-01)\n')
sh(main, 'fm-slack-mirror.sh', *R)
print('== M3 + M4: main answer still lands while a secondmate home is unreadable ==')
reply(owned('main-call', None), '999.000003', 'ship v2')
sh(main, 'fm-slack-poll.sh', *R)
print('main main-call open after answer:', is_open(main, 'main-call'))
reg.write_text(base_reg)
print('== secret check: token value in any output/state? ==')
blob = ''.join(p.read_text(errors='ignore') for p in (main/'state').rglob('*') if p.is_file())
print('token "fixture" as SLACK token in main state:', 'SLACK_BOT_TOKEN' in blob)
