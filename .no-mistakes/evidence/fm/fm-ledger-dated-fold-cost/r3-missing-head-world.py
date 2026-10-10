#!/usr/bin/env python3
"""r3-missing-head-world.py <lab-home> <world> <head-mode>: build a disposable fleet with one shipped task whose PR is
merged, a local origin standing in for GitHub git, and a gh-axi forge double. head-mode: absent | present."""
import base64, json, os, subprocess, sys
from pathlib import Path
home, world, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
world.mkdir(parents=True, exist_ok=True)
fake = world / 'fakebin'; fake.mkdir(exist_ok=True)
env = dict(os.environ, GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0=f'url.{world}/origin.git.insteadOf',
           GIT_CONFIG_VALUE_0='https://github.com/test/vernant.git', GIT_AUTHOR_NAME='lab', GIT_AUTHOR_EMAIL='lab@example.invalid',
           GIT_COMMITTER_NAME='lab', GIT_COMMITTER_EMAIL='lab@example.invalid')
def git(*a, cwd=None):
    return subprocess.run(['git', *map(str, a)], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()
origin, proj, task = world / 'origin.git', home / 'projects/vernant', world / 'vernant-lab'
if not origin.exists():
    git('init', '-q', '--bare', origin); git('-C', origin, 'symbolic-ref', 'HEAD', 'refs/heads/main')
    git('init', '-q', '-b', 'main', proj); (proj / 'base').write_text('base\n')
    git('-C', proj, 'add', 'base'); git('-C', proj, 'commit', '-q', '-m', 'baseline')
    git('-C', proj, 'remote', 'add', 'origin', 'https://github.com/test/vernant.git'); git('-C', proj, 'push', '-q', 'origin', 'main')
    git('clone', '-q', origin, task); git('-C', task, 'checkout', '-q', '-b', 'fm/vernant-lab')
    for i in (1, 2):
        (task / f'f{i}').write_text(str(i)); git('-C', task, 'add', f'f{i}'); git('-C', task, 'commit', '-q', '-m', f'vernant lab commit {i}')
    git('-C', task, 'remote', 'set-url', 'origin', 'https://github.com/test/vernant.git')
head = 'c8dea6ce' + '0' * 32 if mode == 'absent' else git('-C', task, 'rev-parse', 'HEAD')
url = 'https://github.com/test/vernant/pull/56'
pr = dict(number=56, html_url=url, state='closed', merged_at='2026-10-08T00:00:00Z', head=dict(sha=head, ref='fm/vernant-lab',
          repo=dict(full_name='test/vernant')), base=dict(ref='main'), title='vernant lab', updated_at='2026-10-08T00:00:00Z')
(world / 'gh.json').write_text(json.dumps(dict(single={'56': pr}, pulls=[])))
gh = fake / 'gh-axi'
gh.write_text('#!/usr/bin/env python3\nimport base64, json, os, re, sys\n'
  f'd = json.load(open({str(world / "gh.json")!r}))\np = sys.argv[2]\n'
  "v = {'check_runs': []} if '/check-runs' in p else [] if ('/statuses' in p or re.search(r'/pulls\\?', p)) else d['single'][p.rsplit('/',1)[1]]\n"
  "print('api_response:\\n  body: ' + base64.b64encode(json.dumps(v).encode()).decode() + '\\n  truncated: false')\n")
gh.chmod(0o755)
(home / 'state/vernant-lab.meta').write_text('\n'.join([
    'kind=ship', f'project={proj}', 'branch=fm/vernant-lab', f'worktree={task}', f'pr={url}',
    'backend=tmux', 'window=fm-lab:fm-vernant-lab', 'mode=no-mistakes', 'spawn_gen=1']) + '\n')
(home / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n- [ ] vernant-lab - Vernant lab work (repo: vernant) (kind: ship) (since 2026-10-07)\n\n## Queued\n\n## Done\n')
print(f'world ready: PR #56 head={head} ({mode}); task HEAD={git("-C", task, "rev-parse", "HEAD")}')
