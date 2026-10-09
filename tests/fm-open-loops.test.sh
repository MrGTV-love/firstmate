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
import base64, datetime as dt, json, os, shutil, signal, sqlite3, subprocess, sys, time
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
           PATH=f'{fake}:{os.environ["PATH"]}', GH_DOUBLE=str(world / 'gh.json'),
           GH_REQUESTS=str(world / 'gh-requests'))
env['GIT_AUTHOR_DATE'] = env['GIT_COMMITTER_DATE'] = f'{now} +0000'
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
    env.pop(key, None)

def run(args, **kw):
    kw.setdefault('timeout', 120)
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
with open(os.environ['GH_REQUESTS'], 'a') as stream:
    stream.write(sys.argv[2] + '\n')
if double.get('fail'):
    sys.exit(1)
path = sys.argv[2]
if '/check-runs' in path:
    value = {'check_runs': double['checks'].get(path.split('/commits/')[1].split('/')[0], [])}
elif '/statuses' in path:
    value = []
elif re.search(r'/pulls\?', path):
    value = double.get('pulls_by_repo', {}).get(path.split('/pulls?')[0], double['pulls'])
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
    reflog = Path(git(path, 'rev-parse', '--absolute-git-dir')) / 'logs/HEAD'
    os.utime(reflog, (now, now))
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
os.utime(home / 'state/fresh.status', (now, now))
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
    dict(id='review-8', structured=True, state='done', links=[PR_URL + '8'], pr_url=PR_URL + '8'),
    dict(id='route-9', structured=True, state='done', links=[PR_URL + '9'], pr_url=PR_URL + '9'),
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
    assert row['overdue'] == (not row.get('informational')
                              and (row['age_seconds'] is None or row['age_seconds'] >= row['limit_seconds'])), row

# Age limits live in config; the boundary is inclusive.
(home / 'config/open-loops.json').write_text(json.dumps(dict(age_limits_seconds=dict(open_pr=3600, ready_not_started=9 * 3600 + 1))))
tuned = ledger()
assert rows(tuned, 'open_pr')[PR_URL + '9']['overdue'] is True, 'age equal to the limit is overdue'
assert rows(tuned, 'ready_not_started')['ready']['overdue'] is False, 'age below the limit is not overdue'
(home / 'config/open-loops.json').write_text(json.dumps(dict(age_limits_seconds=dict(nonsense=1))))
bad = run([code / 'bin/fm-open-loops.sh', '--json'])
assert bad.returncode == 1 and 'unknown open-loop age category' in bad.stdout, bad
(home / 'config/open-loops.json').unlink()
print('PASS: ordinary categories, PR proof, ages and configuration', flush=True)

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
assert 'covered' in rows(landed, 'unlanded_commit'), 'retained captain-drop.md must not suppress resumed work'
assert 'local correction B' in rows(landed, 'unlanded_commit')['covered']['evidence'], landed
assert (home / 'data/covered/captain-drop.md').read_text() == 'Retained old drop words, not a drop completion.\n'
assert not {'merged', 'default-failed', 'squashed', 'dropped', 'held-drop'} & set(rows(landed, 'unlanded_commit')), landed
assert 'held-drop:retained' in rows(landed, 'unanswered_question'), landed
print('PASS: correction coverage and landed/drop exclusions', flush=True)

saved_tasks, saved_backlog = tasks, backlog
saved_pulls, saved_checks = double['pulls'], double['checks']
double['pulls'], double['checks'] = [], {}
(world / 'gh.json').write_text(json.dumps(double))
def fixture(items, records=None):
    (home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=items,
        backlog=dict(present=True, records=records or []))))

fork_red, fork_green = task_copy('fork-red', commit_age=50), task_copy('fork-green', commit_age=50)
fork_url = 'https://github.com/delivery/project/pull/'
fork_heads = [git(path, 'rev-parse', 'HEAD') for path in (fork_red, fork_green)]
fork_pulls = [dict(number=17 + i, html_url=fork_url + str(17 + i), head=dict(sha=head),
                   state='open', draft=False, updated_at=iso(hours(3)))
              for i, head in enumerate(fork_heads)]
double['pulls_by_repo'] = {'/repos/delivery/project': fork_pulls}
double['checks'] = {head: [dict(id=1, name='unit', app=dict(id=3), status='completed',
                              conclusion='failure' if i == 0 else 'success', completed_at=iso(hours(2)))]
                    for i, head in enumerate(fork_heads)}
double['single']['18'] = dict(state='closed', merged_at=iso(hours(1)), head=dict(sha=fork_heads[1]))
(world / 'gh.json').write_text(json.dumps(double))
fork_tasks = [task('fork-red' if i == 0 else 'fork-green', path, state='failed', pr=fork_url + str(17 + i))
              for i, path in enumerate((fork_red, fork_green))]
for item in fork_tasks:
    item['project'] = None
project_path, parked_project = home / 'projects/project', world / 'parked-project'
project_path.rename(parked_project)
try:
    fixture(fork_tasks)
    fork_open = ledger()
    assert fork_open['complete'], fork_open
    assert set(rows(fork_open, 'red_check')) == {fork_url + '17'}, fork_open
    assert set(rows(fork_open, 'open_pr')) == {fork_url + '18'}, fork_open
    assert set(rows(fork_open, 'failed_task')) == {'fork-red', 'fork-green'}, fork_open
    assert not rows(fork_open, 'unlanded_commit'), fork_open
    projects_mode = (home / 'projects').stat().st_mode & 0o777
    (home / 'projects').chmod(0o300)
    try:
        fork_blind_origin = ledger()
        assert not fork_blind_origin['complete'], fork_blind_origin
        assert 'projects inventory' in rows(fork_blind_origin, 'coverage')['ledger degraded']['evidence'], fork_blind_origin
        assert set(rows(fork_blind_origin, 'red_check')) == {fork_url + '17'}, fork_blind_origin
        assert set(rows(fork_blind_origin, 'open_pr')) == {fork_url + '18'}, fork_blind_origin
    finally:
        (home / 'projects').chmod(projects_mode)
    double['pulls_by_repo']['/repos/delivery/project'] = [fork_pulls[0]]
    (world / 'gh.json').write_text(json.dumps(double))
    fork_merged = ledger()
    assert set(rows(fork_merged, 'failed_task')) == {'fork-red'}, fork_merged
    assert not rows(fork_merged, 'unlanded_commit'), fork_merged
    for path in (fork_red, fork_green):
        correction(path)
    fork_corrected = ledger()
    assert set(rows(fork_corrected, 'unlanded_commit')) == {'fork-red', 'fork-green'}, fork_corrected
    assert set(rows(fork_corrected, 'failed_task')) == {'fork-red', 'fork-green'}, fork_corrected
finally:
    parked_project.rename(project_path)
    double.pop('pulls_by_repo')
    double['checks'] = {}
    (world / 'gh.json').write_text(json.dumps(double))
print('PASS: recorded task-only PR classification, fork landing, and correction coverage', flush=True)

equivalent = task_copy('patch-equivalent', commit_age=3)
equivalent_head = git(equivalent, 'rev-parse', 'HEAD')
git(equivalent, 'checkout', '-q', 'main')
(equivalent / 'default-only').write_text('default-only\n')
git(equivalent, 'add', 'default-only'); git(equivalent, 'commit', '-q', '-m', 'default advanced')
git(equivalent, 'cherry-pick', equivalent_head)
git(equivalent, 'update-ref', 'refs/remotes/origin/main', git(equivalent, 'rev-parse', 'HEAD'))
git(equivalent, 'checkout', '-q', 'fm/patch-equivalent')
fixture([task('patch-equivalent', equivalent, state='failed')])
settled = ledger()
assert not rows(settled, 'failed_task') and not rows(settled, 'unlanded_commit'), settled
print('PASS: patch-equivalent delivery', flush=True)

local = task_copy('local-delivery', commit_age=3)
local_head = git(local, 'rev-parse', 'HEAD')
local_base = git(local, 'rev-parse', 'main')
git(local, 'checkout', '-q', 'main')
local_worker = world / 'local-worker'
git(local, 'worktree', 'add', '-q', local_worker, 'fm/local-delivery')
local_task = task('local-delivery', local_worker, state='failed')
local_task['mode'] = 'local-only'
local_task['project'] = str(local)
(home / 'state/local-delivery.meta').write_text(
    f'kind=ship\nmode=local-only\nproject={local}\nbranch=fm/local-delivery\n')
(home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
out([code / 'bin/fm-merge-local.sh', 'local-delivery'])
assert git(local, 'rev-parse', 'refs/heads/main') == local_head
for pushed in (False, True):
    if pushed:
        git(local_worker, 'push', '-q', 'origin', 'HEAD:refs/heads/fm/local-delivery')
    fixture([local_task])
    delivered = ledger()
    assert not rows(delivered, 'failed_task') and not rows(delivered, 'unlanded_commit'), delivered
local_task['mode'] = 'no-mistakes'
fixture([local_task])
assert 'local-delivery' in rows(ledger(), 'failed_task')
local_task['mode'] = 'local-only'
git(local, 'update-ref', 'refs/heads/main', local_base)
fixture([local_task])
assert 'local-delivery' in rows(ledger(), 'unlanded_commit')
git(local, 'update-ref', 'refs/heads/trunk', local_head)
git(local, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/trunk')
git(local, 'update-ref', 'refs/remotes/origin/trunk', local_base)
fixture([local_task])
settled = ledger()
assert not rows(settled, 'failed_task') and not rows(settled, 'unlanded_commit'), settled
(home / 'state/local-delivery.meta').unlink()
(home / 'data/backlog.md').unlink()
print('PASS: approved local landing and qualified defaults', flush=True)

for exists, alive in ((False, 'dead'), (True, 'dead'), (True, 'missing'), (True, 'alive'), (True, 'unknown')):
    failed_axes = [
        task('axis-pending', lost, state='failed', exists=exists, alive=alive),
        task('axis-landed', default_failed, state='failed', exists=exists, alive=alive),
        task('axis-pr', merged, state='failed', exists=exists, alive=alive, pr=PR_URL + '5'),
        task('axis-missing-pr', world / 'missing-pr-copy', state='failed', exists=exists, alive=alive,
             pr=PR_URL + '5'),
        task('axis-drop', lost, state='failed', exists=exists, alive=alive),
        task('axis-report', lost, state='failed', exists=exists, alive=alive, kind='scout')]
    (home / 'data/axis-report').mkdir(exist_ok=True)
    (home / 'data/axis-report/report.md').write_text('Delivered findings\n')
    fixture(failed_axes, [dict(id='axis-drop', structured=True, state='done', captain_drop=True)])
    (home / 'config/open-loops.json').write_text(json.dumps(dict(age_limits_seconds=dict(failed_task=123))))
    axes = ledger()
    assert set(rows(axes, 'failed_task')) == {'axis-pending'}, axes
    assert rows(axes, 'failed_task')['axis-pending']['limit_seconds'] == 123
    if not exists or alive in ('dead', 'missing'):
        assert set(rows(axes, 'missing_worker')) == {t['id'] for t in failed_axes}, axes
    else:
        assert not rows(axes, 'missing_worker'), axes
    if alive == 'unknown':
        assert not axes['complete'] and 'worker liveness axis-pending' in rows(axes, 'coverage')['ledger degraded']['evidence'], axes
    else:
        assert axes['complete'], axes
(home / 'config/open-loops.json').unlink()
print('PASS: independent failed delivery and worker liveness axes', flush=True)

for alive in ('alive', 'dead', 'missing', 'unreadable'):
    unknown = task('unknown-state', world / 'absent-unknown', state='unknown', alive=alive,
                   exists=False if alive == 'missing' else None)
    unknown['current_state']['detail'] = 'current-state command failed (exit 124)'
    fixture([unknown])
    observed = ledger()
    assert not observed['complete'], observed
    assert 'worker current state unknown-state' in rows(observed, 'coverage')['ledger degraded']['evidence'], observed
    assert ('unknown-state' in rows(observed, 'missing_worker')) == (alive in ('dead', 'missing')), observed
print('PASS: unknown current state degrades independently of live verdict', flush=True)

future = task_copy('future-progress', commit_age=-2)
future_task = task('future-progress', future)
future_status = home / 'state/future-progress.status'
future_status.write_text('working: future stamp\n')
os.utime(future_status, (now + 7200, now + 7200))
future_reflog = Path(git(future, 'rev-parse', '--absolute-git-dir')) / 'logs/HEAD'
os.utime(future_reflog, (now + 7200, now + 7200))
fixture([future_task])
future_report = ledger()
assert rows(future_report, 'stalled_worker')['future-progress']['age_seconds'] is None, future_report
assert rows(future_report, 'stalled_worker')['future-progress']['overdue'], future_report
(world / 'nm').mkdir(exist_ok=True)
with sqlite3.connect(world / 'nm/state.sqlite') as db:
    db.executescript('CREATE TABLE repos (id INTEGER, working_path TEXT);'
                    'CREATE TABLE runs (id INTEGER, repo_id INTEGER, branch TEXT, created_at TEXT);'
                    'CREATE TABLE step_results (run_id INTEGER, started_at TEXT, completed_at TEXT);')
    db.execute('INSERT INTO repos VALUES (?, ?)', (1, future_task['project']))
    db.execute('INSERT INTO runs VALUES (?, ?, ?, ?)', (1, 1, future_task['branch'], iso(hours(5))))
    db.execute('INSERT INTO step_results VALUES (?, ?, ?)', (1, iso(hours(4)), iso(now + 7200)))
pipeline_report = ledger()
assert rows(pipeline_report, 'stalled_worker')['future-progress']['age_seconds'] == 4 * 3600, pipeline_report
(world / 'nm/state.sqlite').unlink()
print('PASS: future pipeline stamps do not mask older valid progress', flush=True)
print('PASS: future status commit and reflog cannot hide unknown-age stalls', flush=True)

progress_tasks = []
for index in range(2):
    name = 'store-worker-' + str(index)
    original = task_copy(name, commit_age=5)
    lane = world / ('progress-lane-' + str(index))
    lane.mkdir()
    copy = lane / 'wt'
    original.rename(copy)
    progress_tasks.append(task(name, copy))
    status = home / ('state/' + name + '.status')
    status.write_text('working: building\n')
    os.utime(status, (hours(5), hours(5)))
    reflog = Path(git(copy, 'rev-parse', '--absolute-git-dir')) / 'logs/HEAD'
    os.utime(reflog, (hours(5), hours(5)))
fixture(progress_tasks)
progress_user, progress_cwd = world / 'progress-user', world / 'progress-cwd'
progress_user.mkdir()
progress_cwd.mkdir()

def progress_store(path, stamps):
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as db:
        db.executescript('CREATE TABLE repos (id INTEGER, working_path TEXT);'
                        'CREATE TABLE runs (id INTEGER, repo_id INTEGER, branch TEXT, created_at TEXT);'
                        'CREATE TABLE step_results (run_id INTEGER, started_at TEXT, completed_at TEXT);')
        db.execute('INSERT INTO repos VALUES (?, ?)', (1, progress_tasks[0]['project']))
        for index, stamp in enumerate(stamps):
            db.execute('INSERT INTO runs VALUES (?, ?, ?, ?)',
                       (index, 1, progress_tasks[index]['branch'], iso(hours(5))))
            db.execute('INSERT INTO step_results VALUES (?, ?, ?)', (index, iso(stamp), iso(stamp)))

absolute_store = world / 'absolute-progress'
default_store = progress_user / '.no-mistakes'
progress_store(absolute_store / 'state.sqlite', [now - 60, hours(4)])
progress_store(default_store / 'state.sqlite', [now - 60, hours(4)])
for index, item in enumerate(progress_tasks):
    local_store = Path(item['paths']['worktree']['path']).parent / 'nm/state.sqlite'
    progress_store(local_store, [now - 60, hours(4) if index == 1 else now - 60])
progress_store(progress_cwd.parent / 'nm/state.sqlite', [now - 60, now - 60])
for selection in (str(absolute_store), '../nm', '', None):
    progress_env = dict(env, HOME=str(progress_user))
    if selection is None:
        progress_env.pop('NM_HOME', None)
    else:
        progress_env['NM_HOME'] = selection
    progress_report = json.loads(out([code / 'bin/fm-open-loops.sh', '--json'],
                                    env=progress_env, cwd=progress_cwd))
    assert progress_report['complete'], (selection, progress_report)
    progress_stalls = rows(progress_report, 'stalled_worker')
    assert set(progress_stalls) == {'store-worker-1'}, (selection, progress_report)
    assert progress_stalls['store-worker-1']['age_seconds'] == 4 * 3600, (selection, progress_report)
missing_store = json.loads(out([code / 'bin/fm-open-loops.sh', '--json'],
                              env=dict(env, NM_HOME='../absent-nm'), cwd=progress_cwd))
assert missing_store['complete'], missing_store
assert set(rows(missing_store, 'stalled_worker')) == {'store-worker-0', 'store-worker-1'}, missing_store
for index, item in enumerate(progress_tasks):
    store = Path(item['paths']['worktree']['path']).parent / 'nm/state.sqlite'
    store.unlink()
    store.write_text('not a database\n')
    unreadable_store = json.loads(out([code / 'bin/fm-open-loops.sh', '--json'],
                                     env=dict(env, NM_HOME='../nm'), cwd=progress_cwd))
    assert not unreadable_store['complete'], unreadable_store
    assert 'no-mistakes run store ' + item['id'] in rows(unreadable_store, 'coverage')['ledger degraded']['evidence']
    assert item['id'] in rows(unreadable_store, 'stalled_worker'), unreadable_store
print('PASS: absolute relative empty and default pipeline stores preserve task-scoped progress', flush=True)

readonly = task_copy('readonly-proof', commit_age=2)
git(readonly, 'checkout', '-q', 'main')
(readonly / 'default-progress').write_text('advanced\n')
git(readonly, 'add', 'default-progress'); git(readonly, 'commit', '-q', '-m', 'default progress')
git(readonly, 'update-ref', 'refs/remotes/origin/main', git(readonly, 'rev-parse', 'HEAD'))
git(readonly, 'checkout', '-q', 'fm/readonly-proof')
readonly_git = Path(git(readonly, 'rev-parse', '--absolute-git-dir'))
index_before = (readonly_git / 'index').read_bytes()
objects_before = {str(p.relative_to(readonly_git / 'objects')): p.read_bytes()
                  for p in (readonly_git / 'objects').rglob('*') if p.is_file()}
fixture([task('readonly-proof', readonly, state='failed')])
readonly_report = ledger()
assert 'readonly-proof' in rows(readonly_report, 'failed_task'), readonly_report
assert 'readonly-proof' in rows(readonly_report, 'unlanded_commit'), readonly_report
assert (readonly_git / 'index').read_bytes() == index_before
assert {str(p.relative_to(readonly_git / 'objects')): p.read_bytes()
        for p in (readonly_git / 'objects').rglob('*') if p.is_file()} == objects_before
print('PASS: collection leaves Git index and object inventory unchanged', flush=True)

fixture([task('stalled', stalled)])
for last_error in ('Error: ENOSPC: no space left on device, write', 'Exception: worker exploded',
                   'Fatal: unable to proceed', 'Error: generic failure', 'network connection timed out',
                   'ENOSPC'):
    pane = 'usage limit earlier\n' + last_error + '\nordinary progress-looking output\n'
    script(code / 'bin/fm-peek.sh', '#!/usr/bin/env python3\nprint(' + repr(pane) + ')\n')
    diagnosed = ledger()
    assert rows(diagnosed, 'stalled_worker')['stalled']['evidence'] == last_error, diagnosed
    human = out([code / 'bin/fm-open-loops.sh'])
    assert last_error in human and 'overdue,evidence' in human and 'for evidence' not in human, human
script(code / 'bin/fm-peek.sh', '#!/usr/bin/env bash\nprintf "Everything normal\\n"\n')
assert rows(ledger(), 'stalled_worker')['stalled']['evidence'] == 'no commit, status line, or pipeline progress'
script(code / 'bin/fm-peek.sh', '#!/usr/bin/env bash\nprintf "Codex usage limit reached; retrying\\n"\n')
print('PASS: last-error JSON and human representations', flush=True)
tasks, backlog = saved_tasks, saved_backlog
double['pulls'], double['checks'] = saved_pulls, saved_checks
(world / 'gh.json').write_text(json.dumps(double))
fixture(tasks, backlog)

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
for origin_url in ('https://github.com/test/project.git', 'git@github.com:test/project.git',
                   'ssh://git@github.com/test/project.git', 'git://github.com/test/project.git'):
    git(no_origin, 'config', 'remote.origin.url', origin_url)
    assert ledger()['complete'], origin_url
for origin_url in ('https://evilgithub.com/test/lookalike.git',
                   'https://github.com.evil/test/lookalike.git',
                   'ssh://git@evilgithub.com/test/lookalike.git',
                   'git@evilgithub.com:test/lookalike.git',
                   'https://github.com@evil.invalid/test/lookalike.git'):
    git(no_origin, 'config', 'remote.origin.url', origin_url)
    (world / 'gh-requests').write_text('')
    hostname_report = ledger()
    assert not hostname_report['complete'], (origin_url, hostname_report)
    assert 'non-GitHub' in rows(hostname_report, 'coverage')['ledger degraded']['evidence'], hostname_report
    assert '/repos/test/lookalike/' not in (world / 'gh-requests').read_text(), origin_url
    assert rows(hostname_report, 'open_pr'), 'unsupported hosts must not hide healthy peers'
git(no_origin, 'config', '--unset', 'remote.origin.url')
unsupported_pr = dict(number=90, html_url='https://evilgithub.com/test/project/pull/90',
                      head=dict(sha='b' * 40), state='open', updated_at=iso(hours(2)))
double['pulls'].append(unsupported_pr)
(world / 'gh.json').write_text(json.dumps(double))
projection_report = ledger()
assert not projection_report['complete'], projection_report
assert unsupported_pr['html_url'] not in rows(projection_report), projection_report
assert rows(projection_report, 'open_pr') and rows(projection_report, 'red_check'), projection_report
double['pulls'].pop()
(world / 'gh.json').write_text(json.dumps(double))
unsupported_task = task('unsupported-pr', world / 'absent-unsupported', state='done',
                        pr='https://github.com.evil/test/project/pull/91')
unsupported_task['project'] = None
fixture(tasks + [unsupported_task], backlog)
(world / 'gh-requests').write_text('')
admission_report = ledger()
assert not admission_report['complete'], admission_report
assert 'unsupported PR forge' in rows(admission_report, 'coverage')['ledger degraded']['evidence'], admission_report
assert '/pulls/91' not in (world / 'gh-requests').read_text(), admission_report
assert rows(admission_report, 'open_pr') and rows(admission_report, 'red_check'), admission_report
fixture(tasks, backlog)
print('PASS: exact GitHub host admission and PR projection', flush=True)
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
state_mode = (home / 'state').stat().st_mode & 0o777
(home / 'state').chmod(0o300)
try:
    inventory_blind = ledger('--heartbeat')
    assert not inventory_blind['complete'] and len(rows(inventory_blind, 'coverage')) == 1, inventory_blind
    assert 'state inventory' in rows(inventory_blind, 'coverage')['ledger degraded']['evidence'], inventory_blind
    assert rows(inventory_blind, 'open_pr'), 'state inventory failure must not hide independent PRs'
    assert json.loads((home / 'state/open-loops.json').read_text()) == inventory_blind
finally:
    (home / 'state').chmod(state_mode)
assert ledger()['complete'], 'restored readable inventory must recover coverage'
print('PASS: unreadable shared state inventory cannot publish complete empty coverage', flush=True)

# Ownership scoping: a home is accountable only for work its own records name.
def greens(sha, status='completed', conclusion='success'):
    return [dict(id=1, name='unit', app=dict(id=3), status=status, conclusion=conclusion, completed_at=iso(hours(2)))]
scope_saved = (double['pulls'], double['checks'], double.get('pulls_by_repo'))
scope_pr = lambda number, sha, ref=None, head_repo='test/project', **extra: dict(
    number=number, html_url=PR_URL + str(number),
    head=dict(sha=sha, ref=ref, repo=dict(full_name=head_repo) if head_repo else None), state='open', draft=False,
    updated_at=iso(hours(3)), **extra)
shas = {n: chr(ord('a') + n - 31) * 40 for n in range(31, 40)}
double['pulls'] = [scope_pr(31, shas[31], 'fm/branch-owned', head_repo='contributor/project'),
                   scope_pr(32, shas[32], 'fm/branch-owned', head_repo='contributor/project'),
                   scope_pr(33, shas[33], 'fm/branch-owned'),
                   scope_pr(34, shas[34]), scope_pr(35, shas[35], requested_teams=[dict(slug='reviewers')]),
                   scope_pr(36, shas[36], 'fm/other'),
                   scope_pr(37, shas[37], 'fm/branch-owned', head_repo='contributor/project'),
                   scope_pr(38, shas[38], 'fm/branch-owned', head_repo=None),
                   scope_pr(39, shas[39], 'fm/branch-owned')]
double['pulls'][-1]['head'].pop('repo')
double['checks'] = {shas[31]: greens(shas[31]), shas[32]: greens(shas[32], conclusion='failure'),
                    shas[33]: greens(shas[33]), shas[34]: greens(shas[34], conclusion='failure'),
                    shas[35]: greens(shas[35]), shas[36]: greens(shas[36], conclusion='failure')}
double['checks'].update({shas[n]: greens(shas[n], conclusion='failure') for n in (37, 38, 39)})
other = home / 'projects/other'
out(['git', 'init', '-q', '-b', 'main', other])
git(other, 'remote', 'add', 'origin', 'https://github.com/test/other.git')
other_url = 'https://github.com/test/other/pull/'
double['pulls_by_repo'] = {'/repos/test/other': [
    dict(scope_pr(40, 'f' * 40, 'fm/branch-owned', head_repo='test/other'), html_url=other_url + '40'),
    dict(scope_pr(41, '1' * 40, 'fm/other', head_repo='test/other'), html_url=other_url + '41'),
    dict(scope_pr(42, '2' * 40, 'fm/unrelated', head_repo='test/other'), html_url=other_url + '42')]}
double['checks']['f' * 40] = greens('f' * 40, conclusion='failure')
double['checks']['1' * 40] = greens('1' * 40)
double['checks']['2' * 40] = greens('2' * 40, conclusion='failure')
(world / 'gh.json').write_text(json.dumps(double))
scope_tasks = [task('owns-31', fresh, pr=PR_URL + '31'), task('owns-branch', fresh)]
scope_tasks[1]['branch'] = 'fm/branch-owned'
scope_backlog = [dict(id='owns-32', structured=True, state='done', links=[PR_URL + '32'], pr_url=None)]
fixture(scope_tasks, scope_backlog)
marker_file = home / '.fm-secondmate-home'
def scoped(lane):
    marker_file.unlink(missing_ok=True)
    if lane:
        marker_file.write_text('lane-1\n')
    (world / 'gh-requests').write_text('')
    return ledger(), (world / 'gh-requests').read_text()
try:
    main_scope, main_requests = scoped(False)
    assert set(rows(main_scope, 'red_check')) == {PR_URL + '32'}, main_scope
    assert set(rows(main_scope, 'open_pr')) == {PR_URL + '31', PR_URL + '33'}, main_scope
    assert all(sha not in main_requests for sha in (*[shas[n] for n in range(34, 40)], 'f' * 40, '1' * 40, '2' * 40)), main_requests
    lane_scope, lane_requests = scoped(True)
    assert set(rows(lane_scope, 'red_check')) == {PR_URL + '32'}, lane_scope
    assert {s for s in rows(lane_scope, 'open_pr')} == {PR_URL + '31', PR_URL + '33'}, lane_scope
    assert not any(r.get('informational') for r in lane_scope['rows'] if r['category'] == 'open_pr'), lane_scope
    assert '/repos/test/other' not in lane_requests, 'a lane does not survey repositories it has no task in'
    assert all(shas[n] not in lane_requests for n in range(34, 40)), lane_requests
    marker_file.write_text('not a valid id!\n')
    (world / 'gh-requests').write_text('')
    malformed_scope = ledger()
    assert set(rows(malformed_scope, 'open_pr')) == {PR_URL + '31', PR_URL + '33'}, malformed_scope
    assert '/repos/test/other/pulls?' in (world / 'gh-requests').read_text(), 'a malformed marker is not a lane home'
    other_task = task('owns-other-branch', fresh)
    other_task['project'] = str(other)
    other_task['branch'] = 'fm/other'
    fixture([*scope_tasks, other_task],
            [*scope_backlog, dict(id='owns-other-url', structured=True, state='done', pr_url=other_url + '42')])
    for lane in (False, True):
        cross_repo, requests = scoped(lane)
        assert set(rows(cross_repo, 'open_pr')) == {PR_URL + '31', PR_URL + '33', other_url + '41'}, cross_repo
        assert set(rows(cross_repo, 'red_check')) == {PR_URL + '32', other_url + '42'}, cross_repo
        assert all(shas[n] not in requests for n in range(36, 40)) and 'f' * 40 not in requests, requests
        assert '1' * 40 in requests and '2' * 40 in requests, requests
    double['pulls_by_repo']['/repos/test/other'].append(
        dict(scope_pr(43, '3' * 40, 'fm/branch-owned'), html_url=other_url + '43'))
    double['checks']['3' * 40] = greens('3' * 40)
    (world / 'gh.json').write_text(json.dumps(double))
    for lane in (False, True):
        fork_owned, requests = scoped(lane)
        assert set(rows(fork_owned, 'open_pr')) == {PR_URL + '31', PR_URL + '33', other_url + '41', other_url + '43'}, fork_owned
        assert set(rows(fork_owned, 'red_check')) == {PR_URL + '32', other_url + '42'}, fork_owned
        assert '3' * 40 in requests, requests
    double['pulls'][2]['head']['repo']['full_name'] = 'Test/Project'
    double['pulls_by_repo']['/repos/test/other'][1]['head']['repo']['full_name'] = 'Test/Other'
    double['pulls'].extend([
        scope_pr(44, '4' * 40, 'FM/branch-owned'),
        dict(scope_pr(31, '5' * 40, 'fm/unrelated', head_repo='contributor/project'),
             html_url='https://github.com/Test/Project/pull/31'),
    ])
    double['checks'].update({sha: greens(sha, conclusion='failure') for sha in ('4' * 40, '5' * 40)})
    (world / 'gh.json').write_text(json.dumps(double))
    for origin_slug in ('test/project', 'TEST/PROJECT'):
        git(home / 'projects/project', 'remote', 'set-url', 'origin', f'https://github.com/{origin_slug}.git')
        for lane in (False, True):
            case_scope, requests = scoped(lane)
            assert set(rows(case_scope, 'open_pr')) == {PR_URL + '31', PR_URL + '33', other_url + '41', other_url + '43'}, case_scope
            assert set(rows(case_scope, 'red_check')) == {PR_URL + '32', other_url + '42'}, case_scope
            assert all(sha in requests for sha in (shas[33], '1' * 40, '3' * 40)), requests
            assert all(sha not in requests for sha in ('4' * 40, '5' * 40)), requests
finally:
    git(home / 'projects/project', 'remote', 'set-url', 'origin', 'https://github.com/test/project.git')
    marker_file.unlink(missing_ok=True)
    shutil.rmtree(other)
    double['pulls'], double['checks'] = scope_saved[0], scope_saved[1]
    double.pop('pulls_by_repo')
    if scope_saved[2] is not None:
        double['pulls_by_repo'] = scope_saved[2]
    (world / 'gh.json').write_text(json.dumps(double))
print('PASS: PR ownership matches the head repository and branch or an exact recorded URL; unowned checks are not fetched', flush=True)

# A worker that recorded its own stop is not missing, and an unreadable live state does not degrade the ledger.
def stopped_task(name, last_event, state='unknown', detail='backend target gone: gone', exists=False, alive='missing',
                 status_text=None):
    item = task(name, world / 'nowhere', state=state, exists=exists, alive=alive)
    item['current_state']['detail'] = detail
    item['paths']['status_log'] = dict(last_event=dict(state=last_event) if last_event else None)
    if status_text is None:
        status_text = f'{last_event}: stopped\n' if last_event else ''
    (home / 'state' / (name + '.status')).write_text(status_text)
    return item
recorded = [stopped_task('stopped-done', 'done'),
            stopped_task('stopped-paused-gone', 'paused', alive='dead'),
            stopped_task('stopped-paused-live', 'paused', detail='unrecognized run status', exists=True, alive='alive'),
            stopped_task('stopped-parked', None, state='parked', exists=False, alive='dead'),
            stopped_task('lost-silently', 'working', alive='dead'),
            stopped_task('stopped-multiline', None, status_text='paused: waiting for CI\nThe check is still running.\n'),
            stopped_task('resumed-after-pause', 'working', status_text='paused: waiting\nworking: resumed\n'),
            stopped_task('lost-prose', None, status_text='The worker was paused while waiting.\n')]
recorded.extend([
    stopped_task('stopped-unrelated-answer', 'resolved', detail='observation unavailable',
                 status_text='needs-decision [key=choice]: choose\npaused: waiting for CI\n'
                             'resolved [key=choice]: answered\n'),
    stopped_task('stopped-keyed-unrelated-answer', 'resolved', exists=True, alive='unverified',
                 detail='unrecognized run status',
                 status_text='paused [key=ci]: waiting\nresolved [key=choice]: answered\n'),
    stopped_task('resumed-default-phase', 'resolved', status_text='paused: waiting\nresolved: resumed\n'),
    stopped_task('resumed-keyed-phase', 'resolved',
                 status_text='paused [key=ci]: waiting\nresolved [key=ci]: resumed\n'),
    stopped_task('blocked-after-pause', 'blocked', status_text='paused: waiting\nblocked: needs help\n'),
    stopped_task('stopped-done-after-pause', 'done', status_text='paused: waiting\ndone: delivered\n'),
])
for state in ('working', 'blocked', 'failed'):
    for event in ('done', 'paused', 'resolved'):
        text = 'paused: waiting\nresolved [key=choice]: answered\n' if event == 'resolved' else None
        recorded.append(stopped_task(state + '-after-' + event, event, state=state, alive='dead', status_text=text))
for state in ('working', 'blocked'):
    item = stopped_task(state + '-unverified-after-pause', 'paused', state=state, exists=True, alive='unverified')
    item['backend'] = None
    recorded.append(item)
fixture(recorded, [dict(id=t['id'], structured=True, state='in_flight', requires_child_metadata=True,
                        since=iso(hours(9))) for t in recorded])
stopped_report = ledger()
expected_missing = {'lost-silently', 'resumed-after-pause', 'lost-prose', 'resumed-default-phase',
                    'resumed-keyed-phase', 'blocked-after-pause',
                    *(state + '-after-' + event for state in ('working', 'blocked', 'failed') for event in ('done', 'paused', 'resolved'))}
assert set(rows(stopped_report, 'missing_worker')) == expected_missing, stopped_report
assert {'failed-after-done', 'failed-after-paused'} <= set(rows(stopped_report, 'failed_task')), stopped_report
degraded_text = ' '.join(r['evidence'] for r in rows(stopped_report, 'coverage').values())
assert not any(t['id'] in degraded_text for t in recorded if t['id'].startswith('stopped-')), stopped_report
assert all(state + '-unverified-after-pause' in degraded_text for state in ('working', 'blocked')), stopped_report
for item in recorded:
    (home / 'state' / (item['id'] + '.status')).unlink()
custom_paused = stopped_task('custom-paused', 'resolved',
                            status_text='awaiting: waiting for CI\nThe check is still running.\n'
                                        'resolved [key=choice]: answered\n')
literal_paused = stopped_task('literal-paused', 'paused')
fixture([custom_paused, literal_paused],
        [dict(id=t['id'], structured=True, state='in_flight', requires_child_metadata=True) for t in (custom_paused, literal_paused)])
try:
    custom_report = json.loads(out([code / 'bin/fm-open-loops.sh', '--json'],
                                  env=dict(env, FM_CLASSIFY_PAUSED_VERB='awaiting')))
    assert set(rows(custom_report, 'missing_worker')) == {'literal-paused'}, custom_report
    assert custom_report['complete'], custom_report
finally:
    for item in (custom_paused, literal_paused):
        (home / 'state' / (item['id'] + '.status')).unlink()
fixture(tasks, backlog)
print('PASS: standing pauses survive unrelated answers; resumption and authoritative current states override them', flush=True)

for event, status_text in (
        ('done', 'done: delivered\n'),
        ('paused', 'paused: waiting for CI\n'),
        ('resolved', 'paused [key=ci]: waiting\nresolved [key=choice]: answered\n')):
    item = stopped_task('generation-' + event, event, exists=None, alive='unknown',
                        detail='task generation changed during snapshot', status_text=status_text)
    item['current_state']['source'] = 'none'
    records = [dict(id=item['id'], structured=True, state='in_flight', requires_child_metadata=True)]
    try:
        fixture([item], records)
        invalidated = ledger('--heartbeat')
        assert not invalidated['complete'], invalidated
        evidence = rows(invalidated, 'coverage')['ledger degraded']['evidence']
        assert 'worker liveness ' + item['id'] in evidence, invalidated
        assert 'worker current state ' + item['id'] + ': task generation changed during snapshot' in evidence, invalidated
        assert not rows(invalidated, 'missing_worker'), invalidated
        assert json.loads((home / 'state/open-loops.json').read_text()) == invalidated
        item['current_state']['detail'] = 'backend target gone: gone'
        item['endpoint'].update(exists=False, agent_alive='missing')
        fixture([item], records)
        coherent_stop = ledger()
        assert coherent_stop['complete'] and not rows(coherent_stop, 'missing_worker'), coherent_stop
    finally:
        (home / 'state' / (item['id'] + '.status')).unlink()
fixture(tasks, backlog)
print('PASS: generation-invalidated snapshots retain coverage failures despite live stop events', flush=True)

# Unselected ready items are visible backlog, not overdue obligations; dispatched ones still are.
(home / 'state/started-ready.status').write_text(f'working [at={hours(1)}]: spawned\n')
selected_task = task('selected-ready', fresh)
fixture([selected_task], [
    dict(id='idle-ready', structured=True, state='queued', since=iso(hours(9))),
    dict(id='selected-ready', structured=True, state='queued', since=iso(hours(9))),
    dict(id='started-ready', structured=True, state='queued', since=iso(hours(9)))])
ready_report = ledger()
ready_rows = rows(ready_report, 'ready_not_started')
assert set(ready_rows) == {'idle-ready', 'selected-ready', 'started-ready'}, ready_report
assert ready_rows['idle-ready']['overdue'] is False and ready_rows['idle-ready']['informational'], ready_rows
assert ready_rows['idle-ready']['next_action'].startswith('informational'), ready_rows
for name in ('selected-ready', 'started-ready'):
    assert ready_rows[name]['overdue'] is True and 'informational' not in ready_rows[name], ready_rows
(home / 'state/started-ready.status').unlink()
fixture(tasks, backlog)
print('PASS: only dispatched ready work is overdue', flush=True)

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
print('PASS: ordinary recovery adapters and source degradation', flush=True)

# Heartbeat mode publishes the ledger atomically; a symbolic link in its place is refused.
stale_marker = home / 'state/.open-loops-stale-surfaced'
overdue_marker = home / 'state/.open-loops-surfaced'
stale_marker.write_text('stale incident\n')
overdue_marker.write_text('overdue digest\n')
overdue_stat = overdue_marker.stat().st_mtime_ns
ledger()
assert stale_marker.read_text() == 'stale incident\n', 'read-only collection must not reset stale suppression'
published = json.loads(out([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json']))
assert json.loads((home / 'state/open-loops.json').read_text())['rows'] == published['rows']
assert not stale_marker.exists(), 'successful publication must reset stale suppression'
assert overdue_marker.read_text() == 'overdue digest\n' and overdue_marker.stat().st_mtime_ns == overdue_stat
json.loads(out([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json']))
stale_marker.write_text('retain failed incident\n')
(home / 'state/open-loops.json').unlink()
(home / 'state/open-loops.json').symlink_to(world / 'elsewhere')
refused = run([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json'])
assert refused.returncode == 1 and 'symbolic link' in refused.stdout, refused
assert stale_marker.read_text() == 'retain failed incident\n'
(home / 'state/open-loops.json').unlink()
(home / 'state/open-loops.json').mkdir()
replace_failed = run([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json'])
assert replace_failed.returncode == 1, replace_failed
assert stale_marker.read_text() == 'retain failed incident\n', 'failed atomic replacement must not reset stale suppression'
assert overdue_marker.read_text() == 'overdue digest\n' and overdue_marker.stat().st_mtime_ns == overdue_stat
(home / 'state/open-loops.json').rmdir()
print('PASS: publication suppression reset success/failure/skip', flush=True)

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
first = subprocess.Popen(flight_command, env=flight_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, start_new_session=True)
fresh = None
def finish_flight(child):
    if child is None:
        return '', ''
    try:
        return child.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        raise
try:
    until = time.monotonic() + 60
    while not (flight_home / 'entered').exists() and time.monotonic() < until:
        time.sleep(0.01)
    assert (flight_home / 'entered').exists(), 'first scan must reach its source'
    assert (flight_state / '.open-loops.lock').is_file()
    assert not (flight_home / 'state/.open-loops.lock').exists()
    flight_snapshot('newer')
    flight_marker = flight_state / '.open-loops-stale-surfaced'
    flight_marker.write_text('pending incident\n')
    second = run(flight_command, env=dict(flight_env, FM_OPEN_LOOPS_NOW=str(now)), timeout=60)
    assert second.returncode == 0 and not second.stdout, second
    assert flight_marker.read_text() == 'pending incident\n', 'contended heartbeat must not reset stale suppression'
    fresh = subprocess.Popen(flight_command[:-2] + ['--json'],
        env=dict(flight_env, FM_OPEN_LOOPS_NOW=str(now)), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True)
    time.sleep(0.1)
    assert fresh.poll() is None, 'fresh CLI waits instead of returning empty JSON output'
    assert (flight_home / 'entries').read_text().splitlines() == ['entered']
    assert not (flight_state / 'open-loops.json').exists()
finally:
    (flight_home / 'release').touch()
    try:
        first_stdout, first_stderr = finish_flight(first)
    finally:
        fresh_stdout, fresh_stderr = finish_flight(fresh)
assert first.returncode == 0, (first_stdout, first_stderr)
assert set(rows(json.loads(first_stdout), 'ready_not_started')) == {'older'}, first_stdout
assert not flight_marker.exists(), 'only completed publication resets the incident'
assert fresh.returncode == 0, (fresh_stdout, fresh_stderr)
fresh_report = json.loads(fresh_stdout)
assert set(rows(fresh_report, 'ready_not_started')) == {'newer'}, fresh_report
assert fresh_report['generated_epoch'] == now, fresh_report
last = json.loads(out(flight_command, env=dict(flight_env, FM_OPEN_LOOPS_NOW=str(now))))
assert set(rows(last, 'ready_not_started')) == {'newer'}, last
assert json.loads((flight_state / 'open-loops.json').read_text()) == last
assert (flight_home / 'entries').read_text().splitlines() == ['entered', 'entered', 'entered']
print('PASS: held-gate singleflight and child cleanup', flush=True)

address_root = world / 'address-boundary'
address_code, address_home, decoy = (address_root / name for name in ('code', 'home', 'decoy'))
shutil.copytree(code / 'bin', address_code / 'bin')
decoy.mkdir()
decoy_record = '{"age_limits_seconds":{"wrong":1}}\n'
(decoy / 'open-loops.json').write_text(decoy_record)
address_url = 'https://github.com/test/address/pull/1'
double['pulls_by_repo'] = {'/repos/test/address': [
    dict(number=1, html_url=address_url, head=dict(sha='b' * 40), state='open', updated_at=iso(hours(2)))]}
(world / 'gh.json').write_text(json.dumps(double))
for address in (address_home, address_code):
    for name in ('state', 'data', 'config', 'projects'):
        (address / name).mkdir(parents=True)
    (address / 'state/address.status').write_text(f'needs-decision [at={hours(1)}] [key=home]: answer\n')
    (address / 'data/address-report').mkdir()
    (address / 'data/address-report/report.md').write_text('Delivered report\n')
    (address / 'config/open-loops.json').write_text(json.dumps(
        dict(age_limits_seconds=dict(ready_not_started=77))))
    address_repo = address / 'projects/address'
    out(['git', 'init', '-q', '-b', 'main', address_repo])
    git(address_repo, 'remote', 'add', 'origin', 'https://github.com/test/address.git')
    report_task = task('address-report', address_root / 'absent', state='failed', kind='scout')
    report_task['project'] = None
    (address / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1',
        tasks=[report_task], backlog=dict(present=True, records=[
            dict(id='address-ready', structured=True, state='queued'),
            dict(id='address-pr', structured=True, state='done', links=[address_url])]))))
empty_keys = ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE')
address_cases = [(dict(FM_HOME=str(address_home), **{key: ''}), address_home) for key in empty_keys]
address_cases += [
    (dict(FM_HOME=str(address_home), **{key: '' for key in empty_keys}), address_home),
    (dict(FM_HOME='', FM_ROOT_OVERRIDE=str(address_home)), address_home),
    (dict(FM_HOME=str(address_home), FM_ROOT_OVERRIDE=''), address_home),
    (dict(FM_HOME='', FM_ROOT_OVERRIDE=''), address_code),
    (dict(FM_ROOT_OVERRIDE=''), address_code),
    (dict(FM_HOME=''), address_code),
    ({}, address_code),
]
for overrides, expected_home in address_cases:
    address_env = dict(env)
    for key in (*empty_keys, 'FM_HOME', 'FM_ROOT_OVERRIDE'):
        address_env.pop(key, None)
    address_env.update(overrides)
    addressed = json.loads(out([address_code / 'bin/fm-open-loops.sh', '--heartbeat', '--json'],
                              env=address_env, cwd=decoy))
    assert addressed['complete'] and addressed['home'] == str(expected_home.resolve()), (overrides, addressed)
    assert set(rows(addressed, 'ready_not_started')) == {'address-ready'}, addressed
    assert rows(addressed, 'ready_not_started')['address-ready']['limit_seconds'] == 77, addressed
    assert set(rows(addressed, 'unanswered_question')) == {'address:home'}, addressed
    assert not rows(addressed, 'failed_task'), addressed
    assert set(rows(addressed, 'open_pr')) == {address_url}, addressed
    assert (expected_home / 'state/.open-loops.lock').is_file(), overrides
    assert json.loads((expected_home / 'state/open-loops.json').read_text()) == addressed
    assert not (decoy / '.open-loops.lock').exists(), overrides
    assert (decoy / 'open-loops.json').read_text() == decoy_record, overrides
double.pop('pulls_by_repo')
(world / 'gh.json').write_text(json.dumps(double))
print('PASS: unset and empty address overrides share shell defaults before collection', flush=True)

def process_alive(pid, identity):
    observed = run(['ps', '-p', str(pid), '-o', 'stat=', '-o', 'lstart='])
    if observed.returncode == 1 and not observed.stdout.strip() and not observed.stderr.strip():
        return False
    assert observed.returncode == 0, (pid, observed.stdout, observed.stderr)
    state, current = observed.stdout.strip().split(None, 1)
    return current.strip() == identity and not state.startswith('Z')

for expiry in ('command', 'collection'):
    timeout_root = world / ('descendants-' + expiry)
    timeout_home, timeout_code = timeout_root / 'home', timeout_root / 'code'
    for name in ('state', 'data', 'config', 'projects'):
        (timeout_home / name).mkdir(parents=True)
    shutil.copytree(code / 'bin', timeout_code / 'bin')
    (timeout_home / 'config/open-loops.json').write_text(json.dumps(dict(command_timeout_seconds=30)))
    script(timeout_code / 'bin/fm-fleet-snapshot.sh', r'''#!/usr/bin/env python3
import os, signal, subprocess, sys, time
from pathlib import Path
home = Path(os.environ['FM_HOME'])
identity = subprocess.check_output(['ps', '-p', str(os.getpid()), '-o', 'lstart='], text=True).strip()
assert identity
(home / 'source-identity').write_text(identity)
(home / 'source-pid').write_text(str(os.getpid()))
body = "import os,signal,subprocess,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);home=Path(os.environ['FM_HOME']);identity=subprocess.check_output(['ps','-p',str(os.getpid()),'-o','lstart='],text=True).strip();assert identity;home.joinpath('descendant-identity').write_text(identity);home.joinpath('descendant-pid').write_text(str(os.getpid()));time.sleep(120)"
subprocess.Popen([sys.executable, '-c', body], start_new_session=True)
until = time.monotonic() + 20
while not (home / 'descendant-pid').exists() and time.monotonic() < until:
    time.sleep(0.01)
if os.environ['EXPIRY'] == 'collection':
    os.kill(os.getppid(), signal.SIGALRM)
time.sleep(120)
''')
    try:
        timed = json.loads(out([timeout_code / 'bin/fm-open-loops.sh', '--heartbeat', '--json'],
                              env=dict(env, FM_HOME=str(timeout_home), EXPIRY=expiry), timeout=60))
        assert not timed['complete'] and len(rows(timed, 'coverage')) == 1, timed
        evidence = rows(timed, 'coverage')['ledger degraded']['evidence']
        if expiry == 'collection':
            assert 'collection exceeded its deadline' in evidence, timed
        else:
            assert 'fleet snapshot' in evidence or 'collection exceeded its deadline' in evidence, timed
        assert json.loads((timeout_home / 'state/open-loops.json').read_text()) == timed
        pids = [(int((timeout_home / (role + '-pid')).read_text()),
                 (timeout_home / (role + '-identity')).read_text().strip())
                for role in ('source', 'descendant')]
        until = time.monotonic() + 2
        while any(process_alive(pid, identity) for pid, identity in pids) and time.monotonic() < until:
            time.sleep(0.01)
        assert not any(process_alive(pid, identity) for pid, identity in pids), (expiry, pids)
    finally:
        for role in ('source', 'descendant'):
            pid_path, identity_path = (timeout_home / (role + suffix) for suffix in ('-pid', '-identity'))
            if pid_path.exists() and identity_path.exists():
                pid, identity = int(pid_path.read_text()), identity_path.read_text().strip()
                if process_alive(pid, identity):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
    print('PASS: ' + expiry + ' deadline owns resistant descendant cleanup', flush=True)

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
    (deadline_home / 'attempts').write_text('')
    (deadline_home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1',
        tasks=deadline_tasks, backlog=dict(present=True, records=(
            [dict(id='owns-prs', structured=True, state='done', links=[PR_URL + str(i) for i in range(24)])]
            if reader == 'pr-checks' else [])))))  # owned PRs are the ones whose checks are fetched
    script(deadline_code / 'bin/fm-fleet-snapshot.sh', '#!/usr/bin/env python3\n'
           'import os\nfrom pathlib import Path\nhome = Path(os.environ["FM_HOME"])\n'
           '(home / "collector-pid").write_text(str(os.getppid()))\nprint((home / "snapshot.json").read_text())\n')
    driver = r'''#!/usr/bin/env python3
import base64, json, os, signal, sys, time
from pathlib import Path
reader, command = os.environ['DEADLINE_READER'], Path(sys.argv[0]).name
if command == 'git' and reader != 'origins':
    print('https://github.com/test/project.git' if '--get' in sys.argv else '.git')
    sys.exit(0)
if command == 'git' and '--get' not in sys.argv:
    print('.git')
    sys.exit(0)
if command == 'gh-axi' and '/pulls?' in sys.argv[2]:
    pulls = [] if reader == 'pr-state' else [dict(number=i, html_url='https://github.com/test/project/pull/' + str(i),
                  head=dict(sha='a' * 40), state='open') for i in range(24)]
    print('api_response:\n  body: ' + base64.b64encode(json.dumps(pulls).encode()).decode()
          + '\n  truncated: false')
    sys.exit(0)
attempts = Path(os.environ['FM_HOME']) / 'attempts'
with attempts.open('a') as stream:
    stream.write(command + '\n')
if len(attempts.read_text().splitlines()) == 2:
    os.kill(int((attempts.parent / 'collector-pid').read_text()), signal.SIGALRM)
time.sleep(0.7)
print('source command failure', file=sys.stderr)
sys.exit(1)
'''
    for command in ('git', 'gh-axi', 'cat'):
        script(deadline_bin / command, driver)
    deadline_env = dict(env, FM_HOME=str(deadline_home), DEADLINE_READER=reader,
                        PATH=f'{deadline_bin}:{env["PATH"]}')
    deadline_report = json.loads(out([deadline_code / 'bin/fm-open-loops.sh', '--heartbeat', '--json'],
                                    env=deadline_env, timeout=60))
    assert not deadline_report['complete'] and len(rows(deadline_report, 'coverage')) == 1, deadline_report
    assert 'collection exceeded its deadline' in rows(deadline_report, 'coverage')['ledger degraded']['evidence']
    attempts = (deadline_home / 'attempts').read_text().splitlines()
    # The real overall deadline may expire before the injected second-attempt
    # alarm on a loaded host; neither path may start a third source command.
    assert len(attempts) <= 2, (reader, attempts)
    assert json.loads((deadline_home / 'state/open-loops.json').read_text()) == deadline_report
    print('PASS: deadline escapes ' + reader + ' source recovery', flush=True)
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

HOLD_HOME=$TMP_ROOT/captain-question-home
mkdir -p "$HOLD_HOME/state" "$HOLD_HOME/data" "$HOLD_HOME/config" "$HOLD_HOME/projects"
cat > "$HOLD_HOME/data/backlog.md" <<'BACKLOG'
## In flight
- [ ] live-hold - Decide rollout (repo: firstmate) (kind: ship) (hold: approve rollout) (hold-kind: captain)
  Captain hold set: 2026-07-11T00:00:00Z

## Queued
- [ ] aged-hold - Decide migration (repo: firstmate) (kind: program) (hold: approve migration) (hold-kind: captain)
  Captain hold set: 2026-06-01T00:00:00Z
- [ ] blocked-hold - Blocked decision (repo: firstmate) (kind: ship) (hold: blocked) (hold-kind: captain) blocked-by: live-hold
- [ ] dated-hold - Deferred decision (repo: firstmate) (kind: ship) (hold: deferred) (hold-kind: captain) (hold-until: 2999-01-01)
- [ ] other-hold - Worker dependency (repo: firstmate) (kind: ship) (hold: worker) (hold-kind: worker)

## Done
- [x] closed-hold - Closed decision (repo: firstmate) (kind: ship) (hold: resolved) (hold-kind: captain) (done 2026-07-11)
BACKLOG
printf 'needs-decision [at=1783728000] [key=separate]: decide the remaining policy question\n' > "$HOLD_HOME/state/aged-hold.status"
LEDGER=$(FM_HOME="$HOLD_HOME" FM_OPEN_LOOPS_NOW=1783814400 bash "$ROOT/bin/fm-open-loops.sh" --json)
printf '%s' "$LEDGER" | jq -e '
  .complete == true
  and ([.rows[] | select(.category == "unanswered_question") | .subject] | sort)
      == ["aged-hold:captain-hold", "aged-hold:separate", "live-hold:captain-hold"]
  and any(.rows[]; .subject == "live-hold:captain-hold" and .owner == "captain"
      and .age_seconds == 86400 and .overdue and .evidence == "approve rollout")
  and any(.rows[]; .subject == "aged-hold:captain-hold" and .owner == "captain"
      and .age_seconds > 14 * 86400 and .overdue and .evidence == "approve migration")
  and all(.rows[]; .category != "ready_not_started" and .category != "missing_worker")' >/dev/null \
  || { echo "FAIL: shared question boundary must include live and aged captain holds only" >&2; exit 1; }
echo "PASS: live and aged captain holds share unresolved-question coverage with status decisions"
mkdir -p "$TMP_ROOT/unreadable-bin"
cat > "$TMP_ROOT/unreadable-bin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'inventory transport failed\n' >&2
exit 2
SH
chmod +x "$TMP_ROOT/unreadable-bin/tmux"
INPUT=$(PATH="$TMP_ROOT/unreadable-bin:$PATH" FM_HOME="$SNAP_HOME" bash "$ROOT/bin/fm-fleet-snapshot.sh" --home-input)
printf '%s' "$INPUT" | jq -e '.tasks[0].endpoint.exists == null
  and .tasks[0].endpoint.agent_alive == "unreadable"
  and .tasks[0].current_state.state == "unknown"' >/dev/null \
  || { echo "FAIL: unreadable tmux is not authoritative absence" >&2; exit 1; }
LEDGER=$(PATH="$TMP_ROOT/unreadable-bin:$PATH" FM_HOME="$SNAP_HOME" bash "$ROOT/bin/fm-open-loops.sh" --json)
printf '%s' "$LEDGER" | jq -e '.complete == false
  and any(.rows[]; .category == "coverage")
  and all(.rows[]; .subject != "worker" or .category != "missing_worker")' >/dev/null \
  || { echo "FAIL: unreadable tmux must degrade collector coverage" >&2; exit 1; }
echo "PASS: unreadable tmux degrades coverage without fabricating missing worker"
cp -R "$ROOT/bin" "$TMP_ROOT/timeout-bin"
cat > "$TMP_ROOT/timeout-bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
sleep 10
SH
chmod +x "$TMP_ROOT/timeout-bin/fm-crew-state.sh"
INPUT=$(PATH="$TMP_ROOT/unreadable-bin:$PATH" FM_HOME="$SNAP_HOME" FM_SNAPSHOT_CREW_STATE_TIMEOUT=1 \
  bash "$TMP_ROOT/timeout-bin/fm-fleet-snapshot.sh" --home-input)
printf '%s' "$INPUT" | jq -e '.tasks[0].current_state.state == "unknown"
  and (.tasks[0].current_state.detail | startswith("current-state command failed (exit "))' >/dev/null \
  || { echo "FAIL: current-state timeout must retain failure evidence" >&2; exit 1; }
echo "PASS: current-state timeout retains independent observation failure"
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json, os, shutil, signal, subprocess, sys, time
from pathlib import Path

root, world = map(Path, sys.argv[1:])
home, code, temporary = (world / name for name in ('real-timeout-home', 'real-timeout-code', 'real-timeout-tmp'))
shutil.copytree(root / 'bin', code / 'bin')
for name in ('state', 'data', 'config', 'projects'):
    (home / name).mkdir(parents=True)
temporary.mkdir()
(home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
(home / 'state/worker.meta').write_text('kind=ship\nbackend=tmux\nwindow=firstmate:fm-worker\nmode=no-mistakes\n')
(home / 'state/worker.status').write_text('needs-decision [key=owed]: answer this\n')
env = dict(os.environ, FM_HOME=str(home), NM_HOME=str(world / 'real-timeout-nm'),
           TMPDIR=str(temporary), FM_SNAPSHOT_CREW_STATE_TIMEOUT='120',
           PATH=f'{world / "unreadable-bin"}:{os.environ["PATH"]}')
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
    env.pop(key, None)
def process_alive(pid, identity):
    observed = subprocess.run(['ps', '-p', str(pid), '-o', 'stat=', '-o', 'lstart='],
                              capture_output=True, text=True)
    if observed.returncode == 1 and not observed.stdout.strip() and not observed.stderr.strip():
        return False
    assert observed.returncode == 0, (pid, observed.stdout, observed.stderr)
    state, current = observed.stdout.strip().split(None, 1)
    return current.strip() == identity and not state.startswith('Z')

mode = (home / 'state').stat().st_mode & 0o777
(home / 'state').chmod(0o300)
try:
    scanned = subprocess.run([str(code / 'bin/fm-open-loops.sh'), '--heartbeat', '--json'],
                             env=env, text=True, capture_output=True, timeout=30)
    assert scanned.returncode == 0, (scanned.stdout, scanned.stderr)
    inventory = json.loads(scanned.stdout)
    assert not inventory['complete'], inventory
    coverage = [row for row in inventory['rows'] if row['category'] == 'coverage']
    assert len(coverage) == 1 and 'state inventory' in coverage[0]['evidence'], inventory
    assert not any(row['category'] == 'unanswered_question' for row in inventory['rows']), inventory
    assert json.loads((home / 'state/open-loops.json').read_text()) == inventory
finally:
    (home / 'state').chmod(mode)
print('PASS: real snapshot unreadable metadata/status inventory stays degraded', flush=True)
(home / 'config/open-loops.json').write_text(json.dumps(dict(command_timeout_seconds=30)))
(code / 'bin/fm-crew-state.sh').write_text(r'''#!/usr/bin/env python3
import os, subprocess, time
from pathlib import Path
home = Path(os.environ['FM_HOME'])
identity = subprocess.check_output(['ps', '-p', str(os.getpid()), '-o', 'lstart='], text=True).strip()
assert identity
(home / 'crew-identity').write_text(identity)
(home / 'crew-pid').write_text(str(os.getpid()))
time.sleep(120)
''')
(code / 'bin/fm-crew-state.sh').chmod(0o755)
try:
    expired = subprocess.run([str(code / 'bin/fm-open-loops.sh'), '--heartbeat', '--json'],
                             env=env, text=True, capture_output=True, timeout=60)
    assert expired.returncode == 0, (expired.stdout, expired.stderr)
    report = json.loads(expired.stdout)
    assert not report['complete'], report
    coverage = [row for row in report['rows'] if row['category'] == 'coverage']
    assert len(coverage) == 1 and 'fleet snapshot' in coverage[0]['evidence'], report
    assert (home / 'crew-pid').exists(), 'real snapshot must reach its nested bounded worker read'
    pid = int((home / 'crew-pid').read_text())
    identity = (home / 'crew-identity').read_text().strip()
    until = time.monotonic() + 2
    while True:
        alive = process_alive(pid, identity)
        if not alive or time.monotonic() >= until:
            break
        time.sleep(0.01)
    assert not alive, 'snapshot nested timeout group must not outlive collector cancellation'
    assert not list(temporary.glob('fm-fleet-*')), list(temporary.iterdir())
    assert json.loads((home / 'state/open-loops.json').read_text()) == report
finally:
    if (home / 'crew-pid').exists() and (home / 'crew-identity').exists():
        pid, identity = int((home / 'crew-pid').read_text()), (home / 'crew-identity').read_text().strip()
        if process_alive(pid, identity):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
print('PASS: real snapshot cancellation reaps nested groups and removes temporary inventory', flush=True)
PY
echo "ok - open-work reconciliation reports owned obligations from live records"
