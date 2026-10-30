# Seed a lab FM_HOME (argv[1]) with a project, PR-owning tasks, and a forge double dir (argv[2]).
import json, os, subprocess, sys, time, datetime as dt
from pathlib import Path
home, fake = Path(sys.argv[1]), Path(sys.argv[2])
now = int(time.time())
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
fake.mkdir(parents=True, exist_ok=True)
def sh(*a, **k): subprocess.run([str(x) for x in a], check=True, capture_output=True, **k)
proj = home / 'projects/project'
sh('git', 'init', '-q', '-b', 'main', proj)
sh('git', '-C', proj, '-c', 'user.name=t', '-c', 'user.email=t@e.invalid', 'commit', '-q', '--allow-empty', '-m', 'base')
sh('git', '-C', proj, 'remote', 'add', 'origin', 'https://github.com/test/project.git')
(home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
red = 'https://github.com/test/project/pull/283'
green = 'https://github.com/test/project/pull/284'
old = iso(now - 7200)
pulls = [dict(html_url=red, number=283, state='open', draft=False, head={'sha': 'a'*40, 'ref': 'fm/parked-job', 'repo': {'full_name': 'test/project'}},
              base={'ref': 'main'}, updated_at=old, requested_reviewers=[], requested_teams=[]),
         dict(html_url=green, number=284, state='open', draft=False, head={'sha': 'b'*40, 'ref': 'fm/green-job', 'repo': {'full_name': 'test/project'}},
              base={'ref': 'main'}, updated_at=old, requested_reviewers=[], requested_teams=[])]
checks = {'a'*40: [dict(name='Behavior portable serial 17', status='completed', conclusion='failure', completed_at=old, id=1, app={'id': 1})],
          'b'*40: [dict(name='ci', status='completed', conclusion='success', completed_at=old, id=2, app={'id': 1})]}
(fake / 'gh.json').write_text(json.dumps(dict(pulls=pulls, checks=checks)))
gh = fake / 'gh'
gh.write_text(r'''#!/usr/bin/env python3
import hashlib, json, os, re, sys, time
args = sys.argv[1:]
assert args[:2] == ['api', '-i'], args
d = json.load(open(os.path.join(os.path.dirname(__file__), 'gh.json')))
path = '/' + args[-1].lstrip('/')
open(os.path.join(os.path.dirname(__file__), 'requests'), 'a').write(path + '\n')
if '/check-runs' in path: v = {'check_runs': d['checks'].get(path.split('/commits/')[1].split('/')[0], [])}
elif '/statuses' in path: v = []
elif '/pulls?' in path: v = d['pulls']
elif '/rules/branches/' in path: v = []
elif '/branches/' in path: v = {'protected': False}
else: v = next(p for p in d['pulls'] if str(p['number']) == path.rsplit('/', 1)[1])
body = json.dumps(v)
sys.stdout.write('HTTP/2.0 200 OK\r\nEtag: "' + hashlib.sha1(body.encode()).hexdigest()[:16] + '"\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4000\r\nX-Ratelimit-Reset: ' + str(int(time.time()) + 3600) + '\r\nX-Ratelimit-Resource: core\r\n\r\n' + body)
''')
gh.chmod(0o755)
st = home / 'state'
# Worker parked on purpose: owns red PR 283.
tree = fake.parent / 'trees'
for name in ('parked-job', 'green-job', 'repair-owner'):
    t = tree / name
    sh('git', 'clone', '-q', proj, t)
    sh('git', '-C', t, 'checkout', '-q', '-b', 'fm/' + name)
(st / 'parked-job.meta').write_text(f'kind=ship\nspawn_gen=s-parked\nworktree={tree/"parked-job"}\nharness=claude\nwindow=fm:fm-parked-job\npr={red}\n')
(st / 'parked-job.status').write_text(f'working [at={now}]: parked on purpose until repair-owner merges\n')
(st / 'green-job.meta').write_text(f'kind=ship\nspawn_gen=s-green\nworktree={tree/"green-job"}\nharness=claude\nwindow=fm:fm-green-job\npr={green}\n')
(st / 'green-job.status').write_text(f'working [at={now}]: waiting for review\n')
(st / 'repair-owner.meta').write_text(f'kind=ship\nspawn_gen=s-repair\nworktree={tree/"repair-owner"}\nharness=claude\nwindow=fm:fm-repair-owner\n')
(st / 'repair-owner.status').write_text(f'working [at={now}]: fixing the red main\n')
print(json.dumps(dict(now=now, red=red, green=green)))
