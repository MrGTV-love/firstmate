#!/usr/bin/env bash
# Open-work reconciler behavior through bin/fm-open-loops.sh: every owned-work category
# from real Git repos, status logs and a forge double, age limits, one degraded row for an
# unreadable source, the atomically published ledger, and the real
# fleet snapshot's home-input contract for a large inventory and a captain drop.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-open-loops)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import base64, datetime as dt, json, os, shutil, subprocess, sys, time
from pathlib import Path

root, world = map(Path, sys.argv[1:])
code, home, fake = world / 'code', world / 'home', world / 'fakebin'
shutil.copytree(root / 'bin', code / 'bin')
for name in ('state', 'data', 'config', 'projects'):
    (home / name).mkdir(parents=True)
fake.mkdir()
now = int(time.time())
hours = lambda n: now - n * 3600
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
env = dict(os.environ, FM_HOME=str(home), NM_HOME=str(world / 'nm'), FM_OPEN_LOOPS_NOW=str(now),
           PATH=f'{fake}:{os.environ["PATH"]}', GH_DOUBLE=str(world / 'gh.json'))
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
    env.pop(key, None)

def run(args, **kw):
    return subprocess.run([str(a) for a in args], env=kw.pop('env', env), text=True, capture_output=True, **kw)
def out(args, **kw):
    done = run(args, **kw)
    assert done.returncode == 0, (args, done.stderr, done.stdout)
    return done.stdout.strip()
def git(path, *args):
    return out(['git', '-C', path, *args])
def script(path, text):
    path.write_text(text)
    path.chmod(0o755)
def ledger(*extra):
    return json.loads(out([code / 'bin/fm-open-loops.sh', '--json', *extra]))
def rows(report, category=None):
    return {r['subject']: r for r in report['rows'] if category in (None, r['category'])}

script(code / 'bin/fm-peek.sh', '#!/usr/bin/env bash\nprintf "Codex usage limit reached; retrying\\n"\n')
script(code / 'bin/fm-fleet-snapshot.sh', '#!/usr/bin/env bash\n[ "$1" = --home-input ] || exit 2\n'
       '[ -f "$FM_HOME/snapshot-fails" ] && { echo snapshot unavailable >&2; exit 1; }\ncat "$FM_HOME/snapshot.json"\n')
script(fake / 'gh-axi', r'''#!/usr/bin/env python3
import base64, json, os, re, sys
double = json.load(open(os.environ['GH_DOUBLE']))
if double.get('fail'):
    sys.exit(1)
path = sys.argv[2]
if '/check-runs' in path:
    value = {'check_runs': double['checks'].get(path.split('/commits/')[1].split('/')[0], [])}
elif '/statuses' in path:
    value = []
elif re.search(r'/pulls\?', path):
    value = double['pulls']
else:
    value = double['single'][path.rsplit('/', 1)[1]]
print('api_response:\n  body: ' + base64.b64encode(json.dumps(value).encode()).decode() + '\n  truncated: false')
''')

# Git: an origin with one landed baseline, plus separate task copies.
origin = world / 'origin.git'
out(['git', 'init', '-q', '--bare', origin])
git(origin, 'symbolic-ref', 'HEAD', 'refs/heads/main')
seed = world / 'seed'
out(['git', 'init', '-q', '-b', 'main', seed])
(seed / 'base').write_text('base\n')
git(seed, 'add', 'base'); git(seed, 'commit', '-q', '-m', 'baseline')
git(seed, 'remote', 'add', 'origin', 'https://github.com/test/project.git')
env['GIT_CONFIG_COUNT'] = '1'
env['GIT_CONFIG_KEY_0'] = f'url.{origin}.insteadOf'
env['GIT_CONFIG_VALUE_0'] = 'https://github.com/test/project.git'
git(seed, 'push', '-q', 'origin', 'main')
shutil.copytree(seed, home / 'projects/project')

def task_copy(name, commit_age=None, message='work'):
    path = world / name
    out(['git', 'clone', '-q', origin, path])
    git(path, 'checkout', '-q', '-b', 'fm/' + name)
    if commit_age is not None:
        (path / name).write_text(name)
        git(path, 'add', name)
        stamp = f'{hours(commit_age)} +0000'
        subprocess.run(['git', '-C', str(path), 'commit', '-q', '-m', message], check=True,
                       env=dict(env, GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp))
    return path

def task(name, path, state='working', alive='alive', exists=True, pr=None, kind='ship'):
    return dict(id=name, kind=kind, project=str(home / 'projects/project'), branch='fm/' + name, backend='tmux',
                current_state=dict(state=state, source='pane'),
                endpoint=dict(exists=exists, agent_alive=alive, target=name),
                pr=dict(url=pr), paths=dict(worktree=dict(path=str(path))), hints={})

lost = task_copy('lost', commit_age=60, message='reviewed launcher; push failed')
stalled = task_copy('stalled', commit_age=5)
fresh = task_copy('fresh', commit_age=0)
merged = task_copy('merged', commit_age=50)
covered = task_copy('covered', commit_age=50)
merged_head = git(merged, 'rev-parse', 'HEAD')
covered_head = git(covered, 'rev-parse', 'HEAD')
for name, path in (('stalled', stalled), ('fresh', fresh)):
    (home / f'state/{name}.status').write_text(f'working [at={hours(5 if name == "stalled" else 0)}]: building\n')
os.utime(home / 'state/stalled.status', (hours(5), hours(5)))
logs = Path(git(stalled, 'rev-parse', '--absolute-git-dir')) / 'logs/HEAD'
os.utime(logs, (hours(5), hours(5)))

PR_URL = 'https://github.com/test/project/pull/'
tasks = [task('lost', lost), task('stalled', stalled), task('fresh', fresh),
         task('merged', merged, pr=PR_URL + '5'), task('covered', covered, pr=PR_URL + '7'),
         task('gone', world / 'nowhere', exists=False, alive='dead'),
         task('broken', world / 'nowhere', state='failed')]
backlog = [
    dict(id='orphan', structured=True, state='in_flight', requires_child_metadata=True, since=iso(hours(9))),
    dict(id='ready', structured=True, state='queued', since=iso(hours(9)), unresolved_blocker_ids=[]),
    dict(id='waiting', structured=True, state='queued', since=iso(hours(9)), unresolved_blocker_ids=['orphan']),
    dict(id='held', structured=True, state='queued', since=iso(hours(9)), hold_kind='captain'),
    dict(id='deferred', structured=True, state='queued', since=iso(hours(9)), hold_until='2999-01-01'),
]
(home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=tasks,
                                                    backlog=dict(present=True, records=backlog))))
# Questions: an old keyed one, a quoted-time one (no real stamp), and a closed one.
(home / 'state/asker.status').write_text(
    f'needs-decision [at={hours(10)}] [key=engine]: production engine upgrade question\n'
    f'needs-decision [key=approval]: diagnostic mentioned [at={now}]\n'
    f'needs-decision [at={hours(8)}] [key=closed]: asked and answered\n'
    f'resolved [at={hours(7)}] [key=closed]: answered\n')
double = dict(
    pulls=[dict(number=7, html_url=PR_URL + '7', head=dict(sha=covered_head), state='open', draft=False, updated_at=iso(hours(3))),
           dict(number=8, html_url=PR_URL + '8', head=dict(sha='b' * 40), draft=False, updated_at=iso(hours(2)),
                requested_reviewers=[dict(login='reviewer')]),
           dict(number=9, html_url=PR_URL + '9', head=dict(sha='c' * 40), draft=False, updated_at=iso(hours(1)))],
    checks={covered_head: [dict(id=1, name='unit', app=dict(id=3), status='completed', conclusion='failure',
                           completed_at=iso(hours(4)))],
            'b' * 40: [dict(id=1, name='unit', app=dict(id=3), status='completed', conclusion='failure',
                           completed_at=iso(hours(4))),
                       dict(id=2, name='unit', app=dict(id=3), status='completed', conclusion='success',
                           completed_at=iso(hours(3)))],
            'c' * 40: [dict(id=4, name='unit', app=dict(id=3), status='completed', conclusion='success')]},
    single={'5': dict(merged_at=iso(hours(1)), head=dict(sha=merged_head)), '7': dict(merged_at=None)})
(world / 'gh.json').write_text(json.dumps(double))

report = ledger()
by = rows(report)
cat = lambda c: rows(report, c)
assert report['schema'] == 'fm-open-loops.v1' and report['complete'] is True, report

# Workers: a dead endpoint, an orphan in-flight item, a failed task, and the stalled-but-alive worker.
assert {'gone', 'orphan'} <= set(cat('missing_worker')), cat('missing_worker')
assert 'broken' in cat('failed_task')
stall = cat('stalled_worker')
assert set(stall) == {'stalled'} and 'usage limit' in stall['stalled']['evidence'] and stall['stalled']['overdue'], stall
assert 'fresh' not in stall, 'recent progress must not read as stalled'
# Backlog: only dependency-cleared, unheld work is ready; historical Done records are not audited.
assert set(cat('ready_not_started')) == {'ready'}, cat('ready_not_started')
# Commits: default-branch or actual PR-head coverage suppresses only represented work.
unlanded = cat('unlanded_commit')
assert set(unlanded) == {'lost', 'stalled', 'fresh'}, unlanded
assert [s for s, r in unlanded.items() if r['overdue']] == ['lost'], 'only the day-old work is past its limit'
assert 'reviewed launcher' in unlanded['lost']['evidence'] and 'origin/main' in unlanded['lost']['evidence']
# Questions age from the canonical stamp; a quoted [at=] tag never sets an age, and a closed key is gone.
questions = cat('unanswered_question')
assert set(questions) == {'asker:engine', 'asker:approval'}, questions
assert questions['asker:engine']['age_seconds'] == 10 * 3600 and questions['asker:engine']['overdue']
assert questions['asker:approval']['age_seconds'] is None and questions['asker:approval']['overdue']
# Pull requests: the latest run of a check decides; red is a diagnosis row, never a waiver.
red = cat('red_check')
assert set(red) == {PR_URL + '7'} and red[PR_URL + '7']['next_action'] == 'diagnose: code or test', red
assert red[PR_URL + '7']['owner'] == 'worker:covered' and 'unit' in red[PR_URL + '7']['evidence'], red
open_prs = cat('open_pr')
assert set(open_prs) == {PR_URL + '8', PR_URL + '9'}, open_prs
assert open_prs[PR_URL + '8']['owner'] == 'reviewer' and open_prs[PR_URL + '9']['owner'] == 'firstmate', open_prs
assert open_prs[PR_URL + '9']['age_seconds'] == 3600 and open_prs[PR_URL + '9']['overdue'], open_prs
# Every row names an owner, a next action and an age (or an unknown age that stays overdue).
for row in report['rows']:
    assert row['owner'] and row['next_action'] and 'age_seconds' in row and row['id'], row
    assert row['overdue'] == (row['age_seconds'] is None or row['age_seconds'] >= row['limit_seconds']), row

# Age limits live in config; the boundary is inclusive.
(home / 'config/open-loops.json').write_text(json.dumps(dict(age_limits_seconds=dict(open_pr=3600, ready_not_started=9 * 3600 + 1))))
tuned = ledger()
assert rows(tuned, 'open_pr')[PR_URL + '9']['overdue'] is True, 'age equal to the limit is overdue'
assert rows(tuned, 'ready_not_started')['ready']['overdue'] is False, 'age below the limit is not overdue'
(home / 'config/open-loops.json').write_text(json.dumps(dict(age_limits_seconds=dict(nonsense=1))))
bad = run([code / 'bin/fm-open-loops.sh', '--json'])
assert bad.returncode == 1 and 'unknown open-loop age category' in bad.stdout, bad
(home / 'config/open-loops.json').unlink()

# A PR for A cannot hide a local correction B, whether the PR is open or merged.
def correction(path):
    (path / 'correction').write_text('B\n')
    git(path, 'add', 'correction'); git(path, 'commit', '-q', '-m', 'local correction B')
correction(covered)
correction(merged)
tasks[3]['current_state']['state'] = 'failed'
tasks[4]['current_state']['state'] = 'failed'
(home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=tasks,
                                                    backlog=dict(present=True, records=backlog))))
corrected = ledger()
assert {'covered', 'merged'} <= set(rows(corrected, 'unlanded_commit')), corrected
assert {'covered', 'merged', 'broken'} <= set(rows(corrected, 'failed_task')), corrected
for name in ('covered', 'merged'):
    assert '1 commit(s)' in rows(corrected, 'unlanded_commit')[name]['evidence'], corrected
    assert 'local correction B' in rows(corrected, 'unlanded_commit')[name]['evidence'], corrected

# Failed deliverables actually landed in the current PR head, in default, or dropped are not owed.
double['single']['5']['head']['sha'] = git(merged, 'rev-parse', 'HEAD')
(world / 'gh.json').write_text(json.dumps(double))
default_failed = task_copy('default-failed')
squashed = task_copy('squashed', commit_age=2)
correction(squashed)
git(squashed, 'checkout', '-q', 'main')
git(squashed, 'merge', '--squash', 'fm/squashed')
git(squashed, 'commit', '-q', '-m', 'landed squash')
git(squashed, 'update-ref', 'refs/remotes/origin/main', git(squashed, 'rev-parse', 'HEAD'))
git(squashed, 'checkout', '-q', 'fm/squashed')
dropped = task_copy('dropped', commit_age=2)
held_drop = task_copy('held-drop', commit_age=2)
tasks += [task('default-failed', default_failed, state='failed'),
          task('squashed', squashed, state='failed'), task('dropped', dropped, state='failed'),
          task('held-drop', held_drop, state='failed')]
backlog += [dict(id='dropped', structured=True, state='done', kind='ship', captain_drop=True),
            dict(id='held-drop', structured=True, state='queued', kind='ship', hold_kind='captain',
                 captain_drop=True)]
(home / 'state/held-drop.status').write_text(
    f'needs-decision [at={hours(1)}] [key=retained]: decide the remaining policy question\n')
(home / 'data/covered').mkdir()
(home / 'data/covered/captain-drop.md').write_text('Retained old drop words, not a drop completion.\n')
(home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=tasks,
                                                    backlog=dict(present=True, records=backlog))))
landed = ledger()
assert set(rows(landed, 'failed_task')) == {'broken', 'covered'}, landed
assert not {'merged', 'default-failed', 'squashed', 'dropped', 'held-drop'} & set(rows(landed, 'unlanded_commit')), landed
assert 'held-drop:retained' in rows(landed, 'unanswered_question'), landed

# Recovery-unverified adapters still have live working endpoints; ambiguous endpoints degrade.
live_tasks = [task('live-' + backend, stalled, alive='unknown') for backend in ('orca', 'zellij', 'cmux')]
for live_task, backend in zip(live_tasks, ('orca', 'zellij', 'cmux')):
    live_task['backend'] = backend
ambiguous = task('ambiguous', world / 'nowhere', state='unknown', alive='unknown')
ambiguous['backend'] = 'orca'
tasks += live_tasks + [ambiguous]
(home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=tasks,
                                                    backlog=dict(present=True, records=backlog))))
liveness = ledger()
assert {t['id'] for t in live_tasks} <= set(rows(liveness, 'stalled_worker')), liveness
assert not liveness['complete'] and len(rows(liveness, 'coverage')) == 1, liveness
assert 'worker liveness ambiguous' in rows(liveness, 'coverage')['ledger degraded']['evidence'], liveness
tasks = tasks[:-4]
(home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=tasks,
                                                    backlog=dict(present=True, records=backlog))))

# Missing origins are legitimate; malformed Git and unsupported forges are disclosed without hiding peers.
no_origin = home / 'projects/no-origin'
out(['git', 'init', '-q', '-b', 'main', no_origin])
assert ledger()['complete'], 'a real repository without origin is not degraded'
unsupported = home / 'projects/gitlab'
out(['git', 'init', '-q', '-b', 'main', unsupported])
git(unsupported, 'remote', 'add', 'origin', 'https://gitlab.com/test/project.git')
unsupported_report = ledger()
assert not unsupported_report['complete'] and len(rows(unsupported_report, 'coverage')) == 1, unsupported_report
assert 'non-GitHub' in rows(unsupported_report, 'coverage')['ledger degraded']['evidence'], unsupported_report
shutil.rmtree(unsupported)
broken_repo = home / 'projects/broken-repo'
broken_repo.mkdir(); (broken_repo / '.git').write_text('gitdir: /missing/open-loops-repository\n')
broken_config = home / 'projects/broken-config'
out(['git', 'init', '-q', '-b', 'main', broken_config])
(broken_config / '.git/config').write_text('[broken configuration\n')
origins = ledger()
assert not origins['complete'] and len(rows(origins, 'coverage')) == 1, origins
evidence = rows(origins, 'coverage')['ledger degraded']['evidence']
assert 'project origin' in evidence and 'broken-' in evidence, evidence
assert rows(origins, 'open_pr'), 'healthy GitHub peers still reconcile'
for path in (broken_repo, broken_config):
    shutil.rmtree(path)

# A status with no metadata must be readable; symbolic-link statuses stay excluded.
unreadable = home / 'state/unreadable.status'
unreadable.write_text(f'needs-decision [at={hours(1)}] [key=bad]: unreadable\n')
unreadable.chmod(0)
status_blind = ledger()
assert not status_blind['complete'] and len(rows(status_blind, 'coverage')) == 1, status_blind
assert 'questions unreadable.status' in rows(status_blind, 'coverage')['ledger degraded']['evidence'], status_blind
unreadable.chmod(0o600); unreadable.unlink()
(home / 'state/symlink.status').symlink_to(home / 'state/asker.status')
assert ledger()['complete'], 'symlink status exclusion is not coverage failure'

# An unreadable source is one degraded row and complete:false; healthy sources still report.
(home / 'snapshot-fails').write_text('')
double['fail'] = True
(world / 'gh.json').write_text(json.dumps(double))
blind = ledger()
degraded = rows(blind, 'coverage')
assert list(degraded) == ['ledger degraded'] and blind['complete'] is False, blind
assert 'fleet snapshot' in degraded['ledger degraded']['evidence']
assert 'asker:engine' in rows(blind, 'unanswered_question'), 'an unreadable source must not hide another source'
(home / 'snapshot-fails').unlink()
double['fail'] = False
(world / 'gh.json').write_text(json.dumps(double))

# Heartbeat mode publishes the ledger atomically; a symbolic link in its place is refused.
published = json.loads(out([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json']))
assert json.loads((home / 'state/open-loops.json').read_text())['rows'] == published['rows']
(home / 'state/open-loops.json').unlink()
(home / 'state/open-loops.json').symlink_to(world / 'elsewhere')
refused = run([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json'])
assert refused.returncode == 1 and 'symbolic link' in refused.stdout, refused

# Fresh CLI processes in the same home do not overlap or queue stale publications.
flight = world / 'singleflight'
flight_home, flight_code = flight / 'home', flight / 'code'
flight_state = flight / 'override-state'
for name in ('state', 'data', 'config', 'projects'):
    (flight_home / name).mkdir(parents=True)
shutil.copytree(code / 'bin', flight_code / 'bin')
script(flight_code / 'bin/fm-fleet-snapshot.sh', r'''#!/usr/bin/env python3
import json, os, time
from pathlib import Path
home = Path(os.environ['FM_HOME'])
payload = (home / 'snapshot.json').read_text()
with (home / 'entries').open('a') as stream:
    stream.write('entered\n')
(home / 'entered').touch()
while not (home / 'release').exists():
    time.sleep(0.01)
print(payload)
''')
def flight_snapshot(name):
    (flight_home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=[],
        backlog=dict(present=True, records=[dict(id=name, structured=True, state='queued')]))))
flight_snapshot('older')
flight_env = dict(env, FM_HOME=str(flight_home), FM_OPEN_LOOPS_NOW=str(now - 1), FM_STATE_OVERRIDE=str(flight_state))
flight_command = [str(flight_code / 'bin/fm-open-loops.sh'), '--heartbeat', '--json']
first = subprocess.Popen(flight_command, env=flight_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    until = time.monotonic() + 5
    while not (flight_home / 'entered').exists() and time.monotonic() < until:
        time.sleep(0.01)
    assert (flight_home / 'entered').exists(), 'first scan must reach its source'
    assert (flight_state / '.open-loops.lock').is_file()
    assert not (flight_home / 'state/.open-loops.lock').exists()
    flight_snapshot('newer')
    second = run(flight_command, env=dict(flight_env, FM_OPEN_LOOPS_NOW=str(now)), timeout=2)
    assert second.returncode == 0 and not second.stdout, second
    fresh = subprocess.Popen(flight_command[:-2] + ['--json'],
        env=dict(flight_env, FM_OPEN_LOOPS_NOW=str(now)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(0.1)
    assert fresh.poll() is None, 'fresh CLI waits instead of returning empty JSON output'
    assert (flight_home / 'entries').read_text().splitlines() == ['entered']
    assert not (flight_state / 'open-loops.json').exists()
finally:
    (flight_home / 'release').touch()
    first_stdout, first_stderr = first.communicate(timeout=5)
assert first.returncode == 0, (first_stdout, first_stderr)
assert set(rows(json.loads(first_stdout), 'ready_not_started')) == {'older'}, first_stdout
fresh_stdout, fresh_stderr = fresh.communicate(timeout=5)
assert fresh.returncode == 0, (fresh_stdout, fresh_stderr)
fresh_report = json.loads(fresh_stdout)
assert set(rows(fresh_report, 'ready_not_started')) == {'newer'}, fresh_report
assert fresh_report['generated_epoch'] == now, fresh_report
last = json.loads(out(flight_command, env=dict(flight_env, FM_OPEN_LOOPS_NOW=str(now))))
assert set(rows(last, 'ready_not_started')) == {'newer'}, last
assert json.loads((flight_state / 'open-loops.json').read_text()) == last
assert (flight_home / 'entries').read_text().splitlines() == ['entered', 'entered', 'entered']

# Overall deadlines escape every reader's normal error recovery and stop later work.
for reader in ('origins', 'pr-checks', 'pr-state', 'questions'):
    deadline_root = world / ('deadline-' + reader)
    deadline_home, deadline_code, deadline_bin = (deadline_root / n for n in ('home', 'code', 'fakebin'))
    for name in ('state', 'data', 'config', 'projects'):
        (deadline_home / name).mkdir(parents=True)
    deadline_bin.mkdir()
    shutil.copytree(code / 'bin', deadline_code / 'bin')
    (deadline_home / 'config/open-loops.json').write_text(json.dumps(dict(command_timeout_seconds=1)))
    deadline_tasks = []
    if reader == 'pr-state':
        deadline_tasks = [task('failed-' + str(i), deadline_root / 'absent', state='failed', pr=PR_URL + str(i))
                          for i in range(24)]
        for deadline_task in deadline_tasks:
            deadline_task['project'] = None
    if reader in ('origins', 'pr-checks'):
        for i in range(24 if reader == 'origins' else 1):
            (deadline_home / 'projects' / str(i) / '.git').mkdir(parents=True)
    if reader == 'questions':
        for i in range(24):
            (deadline_home / 'state' / (str(i) + '.status')).write_text('needs-decision [key=q]: question\n')
    (deadline_home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1',
        tasks=deadline_tasks, backlog=dict(present=True, records=[]))))
    script(deadline_code / 'bin/fm-fleet-snapshot.sh', '#!/usr/bin/env python3\n'
           'import os\nfrom pathlib import Path\nprint((Path(os.environ["FM_HOME"]) / "snapshot.json").read_text())\n')
    driver = r'''#!/usr/bin/env python3
import base64, json, os, sys, time
from pathlib import Path
reader, command = os.environ['DEADLINE_READER'], Path(sys.argv[0]).name
if command == 'git' and reader != 'origins':
    print('https://github.com/test/project.git' if '--get' in sys.argv else '.git')
    sys.exit(0)
if command == 'git' and '--get' not in sys.argv:
    print('.git')
    sys.exit(0)
if command == 'gh-axi' and '/pulls?' in sys.argv[2]:
    pulls = [dict(number=i, html_url='https://github.com/test/project/pull/' + str(i),
                  head=dict(sha='a' * 40), state='open') for i in range(24)]
    print('api_response:\n  body: ' + base64.b64encode(json.dumps(pulls).encode()).decode()
          + '\n  truncated: false')
    sys.exit(0)
with (Path(os.environ['FM_HOME']) / 'attempts').open('a') as stream:
    stream.write(command + '\n')
time.sleep(0.7)
print('source command failure', file=sys.stderr)
sys.exit(1)
'''
    for command in ('git', 'gh-axi', 'cat'):
        script(deadline_bin / command, driver)
    deadline_env = dict(env, FM_HOME=str(deadline_home), DEADLINE_READER=reader,
                        PATH=f'{deadline_bin}:{env["PATH"]}')
    started = time.monotonic()
    deadline_report = json.loads(out([deadline_code / 'bin/fm-open-loops.sh', '--heartbeat', '--json'],
                                    env=deadline_env, timeout=14))
    elapsed = time.monotonic() - started
    assert 9 <= elapsed < 12, (reader, elapsed, deadline_report)
    assert not deadline_report['complete'] and len(rows(deadline_report, 'coverage')) == 1, deadline_report
    assert 'collection exceeded its deadline' in rows(deadline_report, 'coverage')['ledger degraded']['evidence']
    attempts = (deadline_home / 'attempts').read_text().splitlines()
    assert 1 < len(attempts) < 24, (reader, attempts)
    assert json.loads((deadline_home / 'state/open-loops.json').read_text()) == deadline_report
print('PASS: owned-work categories, owners, ages, degraded row, and atomic publication')
PY

# The real snapshot's home-input contract: large inventories travel by file, secondmates are
# excluded, and a captain drop is read back from the stored completion note.
SNAP_HOME=$TMP_ROOT/snapshot-home
mkdir -p "$SNAP_HOME/state" "$SNAP_HOME/data" "$SNAP_HOME/config" "$SNAP_HOME/projects"
{
  printf '## In flight\n- [ ] mate-lane - Domain lane (repo: firstmate) (kind: secondmate) (since 2026-07-11)\n\n## Queued\n'
  printf -- '- [ ] held-drop - Remaining call (repo: firstmate) (kind: ship) (hold: decide the policy) (hold-kind: captain)\n  Deliverable of the finished work: dropped\n'
  for i in $(seq 1 2500); do
    printf -- '- [ ] bulk-%s - A queued item with enough text to make this inventory larger than a single argument (repo: firstmate) (kind: ship) (since 2026-07-11)\n' "$i"
  done
  printf '\n## Done\n- [x] dropped-one - Dropped (repo: firstmate) (kind: ship) (done 2026-07-12)\n  dropped\n'
  printf -- '- [x] landed-one - Landed https://github.com/test/project/pull/3 (repo: firstmate) (kind: ship) (merged 2026-07-12)\n'
} > "$SNAP_HOME/data/backlog.md"
fm_write_meta "$SNAP_HOME/state/mate-lane.meta" "kind=secondmate" "window=firstmate:fm-mate-lane" "mode=secondmate"
fm_write_meta "$SNAP_HOME/state/worker.meta" "kind=ship" "window=firstmate:fm-worker" "project=$SNAP_HOME" "mode=no-mistakes"
printf 'needs-decision [at=1783814400] [key=retained]: decide the remaining policy question\n' > "$SNAP_HOME/state/held-drop.status"
INPUT=$(FM_HOME="$SNAP_HOME" bash "$ROOT/bin/fm-fleet-snapshot.sh" --home-input)
printf '%s' "$INPUT" | jq -e '.schema == "fm-fleet-home-input.v1" and (.backlog.records | length) > 2500
  and (.tasks | map(.id) == ["worker"])
  and (.backlog.records[] | select(.id == "dropped-one") | .captain_drop == true)
  and (.backlog.records[] | select(.id == "held-drop") | .state == "queued" and .captain_drop == true)
  and (.backlog.records[] | select(.id == "landed-one") | .captain_drop == false)' >/dev/null \
  || { echo "FAIL: home-input contract" >&2; exit 1; }
echo "PASS: home-input carries a large inventory, skips secondmates, and marks a captain drop"
LEDGER=$(FM_HOME="$SNAP_HOME" bash "$ROOT/bin/fm-open-loops.sh" --json)
printf '%s' "$LEDGER" | jq -e '
  any(.rows[]; .category == "unanswered_question" and .subject == "held-drop:retained")
  and all(.rows[]; .subject != "held-drop" or (.category != "failed_task" and .category != "unlanded_commit"))' >/dev/null \
  || { echo "FAIL: retained dropped work must preserve only its unresolved question" >&2; exit 1; }
echo "ok - open-work reconciliation reports owned obligations from live records"
