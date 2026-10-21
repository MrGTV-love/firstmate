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
script(fake / 'gh', r'''#!/usr/bin/env python3
# `gh api -i` double: the helper bin/fm-gh-rest.sh sends conditional GETs and reads the HTTP response.
# GH_REQUESTS logs every request; GH_REQUESTS_304 additionally logs those answered 304 (uncounted).
import hashlib, json, os, re, sys, time
args = sys.argv[1:]
assert args[:2] == ['api', '-i'], args
double = json.load(open(os.environ['GH_DOUBLE']))
path = '/' + args[-1].lstrip('/')
conditional = next((args[i + 1].split(':', 1)[1].strip() for i, a in enumerate(args) if a == '-H'), None)
with open(os.environ['GH_REQUESTS'], 'a') as stream:
    stream.write(path + '\n')
if double.get('fail'):
    sys.exit(1)
if '/check-runs' in path:
    value = {'check_runs': double['checks'].get(path.split('/commits/')[1].split('/')[0], [])}
elif '/statuses' in path:
    value = double.get('statuses', {}).get(path.split('/commits/')[1].split('/')[0], [])
elif re.search(r'/pulls\?', path):
    value = double.get('pulls_by_repo', {}).get(path.split('/pulls?')[0], double['pulls'])
elif '/rules/branches/' in path:
    value = double.get('rules', [])
elif '/branches/' in path:
    value = double.get('protection', {'protected': False})
else:
    value = double['single'][path.rsplit('/', 1)[1]]
body = json.dumps(value)
etag = '"' + hashlib.sha1(body.encode()).hexdigest()[:16] + '"'
rate = (f"X-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: {os.environ.get('GH_REMAINING', '4000')}\r\n"
        f"X-Ratelimit-Reset: {os.environ.get('GH_RESET', str(int(time.time()) + 3600))}\r\nX-Ratelimit-Resource: core\r\n")
link = ''
if os.environ.get('GH_NEXT_LINK') and 'page=2' not in path:
    link = 'Link: <https://api.github.com' + os.environ['GH_NEXT_LINK'] + '>; rel="next"\r\n'
if conditional == etag:
    with open(os.environ['GH_REQUESTS'] + '_304', 'a') as stream:
        stream.write(path + '\n')
    sys.stdout.write('HTTP/2.0 304 Not Modified\r\nEtag: ' + etag + '\r\n' + rate + link + '\r\n')
    sys.stderr.write('gh: HTTP 304\n')
    sys.exit(1)
sys.stdout.write('HTTP/2.0 200 OK\r\nEtag: ' + etag + '\r\n' + rate + link + '\r\n' + body)
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

# Independent review must bind the exact live head; absent required checks prevent readiness.
review_path = home / 'state/review-lane.status'
review_url, review_head = PR_URL + '9', 'c' * 40
review_path.write_text(f'done [at={now - 601}]: review PASS head={review_head} PR {review_url}\n')
config_path = home / 'config/open-loops.json'
config_path.write_text(json.dumps(dict(review_lanes={'test/project': ['review-lane']},
                                     age_limits_seconds={'review_pass_not_merged': 600})))
double['pulls'][2]['base'] = dict(ref='main')
double['checks'][review_head][0]['completed_at'] = iso(now - 700)
(world / 'gh.json').write_text(json.dumps(double))
reviewed = ledger('--heartbeat')
assert rows(reviewed, 'review_pass_not_merged')[review_url]['overdue'], reviewed
assert review_url not in rows(reviewed, 'open_pr'), 'one actionable obligation per reviewed PR'
review_path.write_text(f'done [at={now - 601}]: review PASS head={"d" * 40} PR {review_url}\n')
assert not rows(ledger(), 'review_pass_not_merged'), 'replaced-head review is stale'
review_path.write_text(f'done [at={now - 601}]: review FAIL head={review_head} PR {review_url}\n')
assert not rows(ledger(), 'review_pass_not_merged'), 'latest review rejection supersedes PASS'
review_path.write_text(f'done [at={now - 599}]: review PASS head={review_head} PR {review_url}\n')
assert not rows(ledger(), 'review_pass_not_merged')[review_url]['overdue'], 'one interval grace boundary'
review_path.write_text(f'done [at={now - 601}]: review PASS head={review_head} PR {review_url}\n')
double['rules'] = [dict(type='required_status_checks', parameters=dict(required_status_checks=[
    dict(context='missing', integration_id=3)]))]
(world / 'gh.json').write_text(json.dumps(double))
assert not rows(ledger(), 'review_pass_not_merged'), 'a required check that never reports is not green'
double['rules'][0]['parameters']['required_status_checks'][0]['context'] = 'unit'
double['rules'][0]['parameters']['required_status_checks'][0]['integration_id'] = 77
(world / 'gh.json').write_text(json.dumps(double))
assert not rows(ledger(), 'review_pass_not_merged'), 'a wrong producer cannot satisfy an app-bound check'
double['statuses'] = {review_head: [dict(context='unit', state='success', updated_at=iso(now - 700))]}
(world / 'gh.json').write_text(json.dumps(double))
assert not rows(ledger(), 'review_pass_not_merged'), 'a same-named status cannot satisfy an app-bound check'
double['rules'][0]['parameters']['required_status_checks'][0]['integration_id'] = 3
(world / 'gh.json').write_text(json.dumps(double))
assert rows(ledger(), 'review_pass_not_merged')[review_url]['overdue'], 'the required producer satisfies its check'
double['rules'][0]['parameters']['required_status_checks'][0] = dict(context='deploy')
double['statuses'][review_head][0]['context'] = 'deploy'
(world / 'gh.json').write_text(json.dumps(double))
assert rows(ledger(), 'review_pass_not_merged')[review_url]['overdue'], 'an unbound status requirement matches by name'
double['statuses'] = {}
double['rules'] = []
review_pr = double['pulls'].pop(2)
double['single']['9'] = dict(merged_at=iso(now), head=dict(sha=review_head))
(world / 'gh.json').write_text(json.dumps(double))
merged_report = ledger('--heartbeat')
assert not rows(merged_report, 'review_pass_not_merged'), 'merge resolves the obligation'
assert 'completions' not in merged_report, 'no completions projection is published'
double['pulls'].append(review_pr)
double['single'].pop('9')
(world / 'gh.json').write_text(json.dumps(double))
config_path.unlink()
review_path.unlink()
print('PASS: independent live-head review, interval boundary, missing and app-bound checks, merge completion', flush=True)

# Unseen presented rows stay stale and not overdue until a complete sweep; resolved rows drop their receipts.
def loops(*args, **kw):
    return run([code / 'bin/fm-open-loops.sh', *args], **kw)
ledger_file = home / 'state/open-loops.json'
ledger_file.write_text('{"schema": "fm-open-loops.v1", "rows": [')
published = ledger('--heartbeat')
assert published['complete'] and json.loads(ledger_file.read_text()) == published, 'publication replaces a corrupt ledger'
engine = rows(published, 'unanswered_question')['asker:engine']['id']
pr_nine = rows(published, 'open_pr')[PR_URL + '9']['id']
assert loops('--present-overdue').returncode == 0
too_late = iso(now + 86401)
refused = loops('action', engine, 'deferred', '--evidence', 'awaiting vendor', '--recheck', too_late)
assert refused.returncode == 1 and 'within 24 hours' in refused.stdout, refused
recheck = iso(now + 3600)
assert loops('action', engine, 'deferred', '--evidence', 'awaiting vendor', '--recheck', recheck).returncode == 0
asker_text = (home / 'state/asker.status').read_text()
(home / 'state/asker.status').write_text(asker_text + f'resolved [at={hours(1)}] [key=engine]: answered\n')
unsupported = home / 'projects/gitlab'
out(['git', 'init', '-q', '-b', 'main', unsupported])
git(unsupported, 'remote', 'add', 'origin', 'https://gitlab.com/test/project.git')
double['fail'] = True
(world / 'gh.json').write_text(json.dumps(double))
blind = ledger('--heartbeat')
assert not blind['complete'], blind
for unseen in (rows(blind, 'unanswered_question')['asker:engine'], rows(blind, 'open_pr')[PR_URL + '9']):
    assert unseen['stale'] and unseen['informational'] and not unseen['overdue'], unseen
presented = loops('--present-overdue').stdout
assert engine not in presented and pr_nine not in presented, 'an unseen row needs no receipt'
assert engine in blind['handling']['actions'], 'an unseen row keeps its receipts'
shutil.rmtree(unsupported)
double.pop('fail')
(world / 'gh.json').write_text(json.dumps(double))
resolved = ledger('--heartbeat')
assert resolved['complete'] and 'asker:engine' not in rows(resolved, 'unanswered_question'), resolved
assert engine not in resolved['handling']['actions'], 'a resolved row drops its receipts'
(home / 'state/asker.status').write_text(asker_text)
assert rows(ledger('--heartbeat'), 'unanswered_question')['asker:engine']['overdue']
assert loops('--present-overdue').returncode == 0
again = loops('action', engine, 'deferred', '--evidence', 'awaiting vendor again', '--recheck', recheck)
assert again.returncode == 0, ('a recurring obligation starts without earlier deferrals', again.stdout)
ledger_file.unlink()
print('PASS: stale non-overdue retention, receipt pruning, corrupt-ledger replacement, deferral bound', flush=True)

for name in ('a', 'b'):
    (home / f'state/{name}.status').write_text(f'blocked [at={hours(10)}] [key=answer]: {name} needs an answer\n')
    (home / f'state/{name}.meta').write_text(f'kind=scout\nspawn_gen={name}-generation\n')
a_meta = home / 'state/a.meta'
lost_meta, pr_meta = home / 'state/lost.meta', home / 'state/route-9.meta'
for refresh in (False, True):
    if refresh:
        ledger('--heartbeat')
        assert loops('--present-overdue').returncode == 0
    a_meta.unlink()
    a_meta.symlink_to(home / 'missing-meta')
    lost_meta.symlink_to(home / 'missing-meta')
    pr_meta.symlink_to(home / 'missing-meta')
    degraded = ledger('--heartbeat')
    assert not degraded['complete'], degraded
    obligations = [rows(degraded, 'unanswered_question')[name + ':answer'] for name in ('a', 'b')]
    obligations += [rows(degraded, 'unlanded_commit')['lost'], rows(degraded, 'open_pr')[PR_URL + '9']]
    for obligation in obligations:
        assert obligation['overdue'] and not obligation.get('stale') and not obligation.get('informational'), obligation
    assert 'source' not in obligations[0] and obligations[1].get('source'), obligations
    assert all('source' not in obligation for obligation in obligations[2:]), obligations
    assert 'a.meta' in rows(degraded, 'coverage')['ledger degraded']['evidence'], degraded
    assert loops('--present-overdue').returncode == 0
    refused = loops('--check-actions')
    assert refused.returncode == 1 and all(r['id'] in refused.stdout for r in obligations), refused
    for obligation in (obligations[0], *obligations[2:]):
        refused = loops('action', obligation['id'], 'waiting', '--evidence', 'unproved binding',
                        '--prerequisite-task', 'b', '--recheck', iso(now + 600))
        assert refused.returncode == 1, refused
        assert obligation['id'] not in json.loads(ledger_file.read_text())['handling']['actions']
    for path in (a_meta, lost_meta, pr_meta):
        path.unlink()
    a_meta.write_text('kind=scout\nspawn_gen=a-generation\n')
a_meta.chmod(0)
degraded = ledger('--heartbeat')
assert not degraded['complete'], degraded
assert 'a.meta' in rows(degraded, 'coverage')['ledger degraded']['evidence'], degraded
for name in ('a', 'b'):
    obligation = rows(degraded, 'unanswered_question')[name + ':answer']
    assert obligation['overdue'] and not obligation.get('stale') and not obligation.get('informational'), obligation
a_meta.chmod(0o600)
real_bash = shutil.which('bash')
script(fake / 'bash', f'''#!/usr/bin/env python3
import subprocess, sys
from pathlib import Path
result = subprocess.run([{real_bash!r}, *sys.argv[1:]], capture_output=True)
if any('status_open_decisions_dated' in arg for arg in sys.argv[1:]) and sys.argv[-1].endswith('/a.status'):
    Path(sys.argv[-1]).unlink()
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
''')
degraded = ledger('--heartbeat')
(fake / 'bash').unlink()
assert not degraded['complete'], degraded
for name in ('a', 'b'):
    obligation = rows(degraded, 'unanswered_question')[name + ':answer']
    assert obligation['overdue'] and not obligation.get('stale') and not obligation.get('informational'), obligation
assert 'source' not in rows(degraded, 'unanswered_question')['a:answer'], degraded
(home / 'state/a.status').write_text(f'blocked [at={hours(10)}] [key=answer]: a needs an answer\n')
for name in ('a', 'b'):
    (home / f'state/{name}.status').unlink()
    (home / f'state/{name}.meta').unlink()
ledger_file.unlink()
print('PASS: failed question, PR and commit provenance preserves confirmed acknowledgement obligations on collection and refresh', flush=True)

# Captured answers stay firstmate's obligation independently of the board owner's lifecycle.
answer_inbox = home / 'state/procevent-inbox'
answer_inbox.mkdir()
def captured_answer(inbox, name, age, owner=None, handled=False, adapter='lavish'):
    result = inbox / (name + '.result')
    result.write_text('captured board answer\n')
    result.with_suffix('.adapter').write_text(adapter + '\n')
    os.utime(result, (now - age, now - age))
    if owner is not None:
        result.with_suffix('.owner-task').write_text(owner + '\n')
    if handled:
        result.with_suffix('.handled').touch()
    return result
answers = [captured_answer(answer_inbox, 'lavish-overdue.1', 301, 'gone'),
           captured_answer(answer_inbox, 'lavish-boundary.1', 300, 'gone'),
           captured_answer(answer_inbox, 'lavish-fresh.1', 299, 'gone'),
           captured_answer(answer_inbox, 'lavish-dead.1', 601, 'gone'),
           captured_answer(answer_inbox, 'lavish-parked.1', 301, 'parked-board'),
           captured_answer(answer_inbox, 'lavish-missing.1', 301, 'missing-board'),
           captured_answer(answer_inbox, 'lavish-unowned.1', 301),
           captured_answer(answer_inbox, 'lavish-parked-live.1', 301, 'parked-live'),
           captured_answer(answer_inbox, 'lavish-blocked-live.1', 301, 'blocked-live'),
           captured_answer(answer_inbox, 'lavish-live.1', 9000, 'fresh'),
           captured_answer(answer_inbox, 'lavish-handled.1', 601, 'gone', handled=True)]
foreign = [captured_answer(answer_inbox, name + '-foreign.1', 9000, 'gone', adapter=name)
           for name in ('proc', 'quota', 'when', 'remote-reply')]
parked_board = task('parked-board', world / 'absent-board', state='parked', exists=False, alive='dead')
parked_live = task('parked-live', world / 'absent-board', state='parked', exists=True, alive='alive')
blocked_live = task('blocked-live', world / 'absent-board', state='blocked', exists=True, alive='alive')
(home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1',
                                                    tasks=[*tasks, parked_board, parked_live, blocked_live],
                                                    backlog=dict(present=True, records=backlog))))
answer_report = ledger('--heartbeat')
answer_rows = rows(answer_report, 'unhandled_board_answer')
assert set(answer_rows) == {p.name for p in answers[:-1]}, answer_report
assert not any(p.name in answer_rows for p in foreign), 'only lavish board answers are listed'
live_row = answer_rows['lavish-live.1.result']
assert live_row.get('informational') and not live_row['overdue'], live_row
assert live_row['owner'] == 'worker:fresh' and live_row['next_action'].startswith('informational:'), live_row
assert 'read and route' not in live_row['next_action'], live_row
for live_owner in ('parked-live', 'blocked-live'):
    row = answer_rows[f'lavish-{live_owner}.1.result']
    assert row['overdue'] and not row.get('informational') and row['owner'] == 'firstmate', row
for result in answers[:-2]:
    row = answer_rows[result.name]
    assert row['owner'] == 'firstmate' and row['limit_seconds'] == 300, row
    assert str(result) in row['next_action'], row
    assert row['age_seconds'] == now - int(result.stat().st_mtime), row
    assert row['overdue'] == (row['age_seconds'] >= 300), row
    owner_file = result.with_suffix('.owner-task')
    assert (owner_file.read_text().strip() if owner_file.exists() else 'unknown') in row['next_action'], row
assert json.loads((home / 'state/open-loops.json').read_text()) == answer_report
(home / 'config/open-loops.json').write_text(json.dumps(dict(age_limits_seconds=dict(unhandled_board_answer=600))))
tuned_answers = rows(ledger(), 'unhandled_board_answer')
assert not tuned_answers['lavish-overdue.1.result']['overdue'], tuned_answers
assert tuned_answers['lavish-dead.1.result']['overdue'], tuned_answers
assert not tuned_answers['lavish-live.1.result']['overdue'], tuned_answers
assert tuned_answers['lavish-overdue.1.result']['limit_seconds'] == 600, tuned_answers
(home / 'config/open-loops.json').unlink()
answers[0].with_suffix('.handled').touch()
assert answers[0].name not in rows(ledger(), 'unhandled_board_answer'), 'handling removes the obligation'

# A secondmate collects and publishes only its own captured answers, without consulting the owner task.
answer_lane = world / 'answer-secondmate'
for name in ('state/procevent-inbox', 'data', 'config', 'projects'):
    (answer_lane / name).mkdir(parents=True)
(answer_lane / '.fm-secondmate-home').write_text('answer-lane\n')
(answer_lane / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=[],
                                                        backlog=dict(present=True, records=[]))))
lane_answer = captured_answer(answer_lane / 'state/procevent-inbox', 'lavish-lane.6', 301, 'parked-owner')
lane_report = json.loads(out([code / 'bin/fm-open-loops.sh', '--json', '--heartbeat'],
                             env=dict(env, FM_HOME=str(answer_lane))))
lane_rows = rows(lane_report, 'unhandled_board_answer')
assert lane_report['complete'] and set(lane_rows) == {lane_answer.name}, lane_report
assert lane_rows[lane_answer.name]['overdue'] and lane_rows[lane_answer.name]['owner'] == 'firstmate', lane_report
assert str(lane_answer) in lane_rows[lane_answer.name]['next_action'], lane_report
assert 'parked-owner' in lane_rows[lane_answer.name]['next_action'], lane_report
assert json.loads((answer_lane / 'state/open-loops.json').read_text()) == lane_report
assert lane_answer.name not in rows(ledger(), 'unhandled_board_answer'), 'primary must not sweep secondmate answers'
shutil.rmtree(answer_inbox)
(home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=tasks,
                                                    backlog=dict(present=True, records=backlog))))
print('PASS: board answer ages, handling, live and dead parked missing owners, non-board captures, and home-local secondmate publication', flush=True)

# A teardown that closed a pool task but could not return its slot leaves a record bound to the task's
# spawn generation; only a record naming the current task record is open work.
def pending_return(task_id, marker_gen, meta_gen=None, child=None, age=0):
    marker = home / 'state' / (task_id + '.teardown-return-pending')
    marker.write_text(f'spawn_gen={marker_gen}\nslot=/pool/{task_id}/project\n' + (f'child={child}\n' if child else ''))
    os.utime(marker, (now - age, now - age))
    if meta_gen is not None:
        (home / 'state' / (task_id + '.meta')).write_text(f'kind=ship\nspawn_gen={meta_gen}\n')
    return marker
pending = [pending_return('closed-pool', 'g1', 'g1', age=1800),
           pending_return('closed-domain', 'g2', 'g2', child='child-1', age=60),
           pending_return('respawned-pool', 'g1', 'g9', age=1800),
           pending_return('retired-pool', 'g1', age=1800)]
teardown_rows = rows(ledger(), 'interrupted_teardown')
assert set(teardown_rows) == {'closed-pool', 'closed-domain'}, teardown_rows
closed = teardown_rows['closed-pool']
assert closed['overdue'] and closed['limit_seconds'] == 1800 and closed['age_seconds'] == 1800, closed
assert 'fm-teardown.sh closed-pool' in closed['next_action'] and closed['evidence'] == '/pool/closed-pool/project', closed
domain = teardown_rows['closed-domain']
assert not domain['overdue'] and 'child child-1' in domain['next_action'], domain
pending[0].unlink()
assert 'closed-pool' not in rows(ledger(), 'interrupted_teardown'), 'a completed teardown is no longer open work'
for marker in pending[1:]:
    marker.unlink(missing_ok=True)
for task_id in ('closed-pool', 'closed-domain', 'respawned-pool'):
    (home / 'state' / (task_id + '.meta')).unlink()
print('PASS: interrupted teardown records bound to the current task record', flush=True)

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

# A PR head that is not a local object cannot be read, so its coverage is skipped for that one task: the
# task keeps its own row naming the absent head, and the ledger stays complete instead of degrading whole.
absent_head = 'd' * 40
present_head = double['single']['5']['head']['sha']
double['single']['5']['head']['sha'] = absent_head
(world / 'gh.json').write_text(json.dumps(double))
missing_head = ledger()
assert missing_head['complete'] is True and 'ledger degraded' not in rows(missing_head), missing_head
missing_evidence = rows(missing_head, 'unlanded_commit')['merged']['evidence']
assert f'PR head {absent_head[:8]} is not in this copy, so PR coverage was not applied' in missing_evidence, missing_evidence
assert '2 commit(s)' in missing_evidence and 'local correction B' in missing_evidence, missing_evidence
assert 'merged' in rows(missing_head, 'failed_task'), missing_head
assert 'PR head' not in rows(missing_head, 'unlanded_commit')['covered']['evidence'], missing_head
double['single']['5']['head']['sha'] = present_head
(world / 'gh.json').write_text(json.dumps(double))
assert ledger()['complete'] is True

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
step_store = world / 'active-step-proof'
step_store.mkdir()
with sqlite3.connect(step_store / 'state.sqlite') as db:
    db.executescript('CREATE TABLE repos (id INTEGER, working_path TEXT);'
                    'CREATE TABLE runs (id INTEGER, repo_id INTEGER, branch TEXT, created_at TEXT, status TEXT);'
                    'CREATE TABLE step_results (run_id INTEGER, step TEXT, started_at TEXT, completed_at TEXT);')
    db.execute('INSERT INTO repos VALUES (?, ?)', (1, tasks[0]['project']))
    db.execute('INSERT INTO runs VALUES (?, ?, ?, ?, ?)', (1, 1, 'fm/stalled', iso(hours(5)), 'running'))
    db.execute('INSERT INTO step_results VALUES (?, ?, ?, ?)', (1, 'lint.full.whole', iso(hours(4)), None))
step_report = json.loads(out([code / 'bin/fm-open-loops.sh', '--json'], env=dict(env, NM_HOME=str(step_store))))
step_evidence = rows(step_report, 'stalled_worker')['stalled']['evidence']
assert 'lint.full.whole' in step_evidence and str(4 * 3600) in step_evidence, step_report
for last_error in ('Error: ENOSPC: no space left on device, write', 'Exception: worker exploded',
                   'Fatal: unable to proceed', 'Error: generic failure', 'network connection timed out',
                   'ENOSPC'):
    pane = 'usage limit earlier\n' + last_error + '\nordinary progress-looking output\n'
    script(code / 'bin/fm-peek.sh', '#!/usr/bin/env python3\nprint(' + repr(pane) + ')\n')
    diagnosed = ledger()
    evidence = rows(diagnosed, 'stalled_worker')['stalled']['evidence']
    assert last_error in evidence and 'usage limit earlier' not in evidence, diagnosed
    human = out([code / 'bin/fm-open-loops.sh'])
    assert last_error in human, human
script(code / 'bin/fm-peek.sh', '#!/usr/bin/env bash\nprintf "Waiting for lint.full.whole\\n"\n')
wait_row = rows(ledger(), 'stalled_worker')['stalled']
assert 'lint.full.whole' in wait_row['evidence'] and str(5 * 3600) in wait_row['evidence'], wait_row
script(code / 'bin/fm-peek.sh', '#!/usr/bin/env python3\nprint("waiting " + "x" * 500)\nprint("Error: " + "y" * 500)\n')
long_row = rows(ledger(), 'stalled_worker')['stalled']
assert f'{5 * 3600}s without progress' in long_row['evidence'] and 'Error: yyy' in long_row['evidence'], long_row
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
assert unsupported_report['complete'], unsupported_report
assert 'ledger degraded' not in rows(unsupported_report, 'coverage'), unsupported_report
skipped = rows(unsupported_report, 'coverage')['no forge coverage: gitlab']
assert skipped['informational'] and not skipped['overdue'] and 'non-GitHub' in skipped['evidence'], skipped
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
    assert hostname_report['complete'], (origin_url, hostname_report)
    skipped = rows(hostname_report, 'coverage')['no forge coverage: no-origin']
    assert skipped['informational'] and 'non-GitHub' in skipped['evidence'], hostname_report
    assert '/repos/test/lookalike/' not in (world / 'gh-requests').read_text(), origin_url
    assert rows(hostname_report, 'open_pr'), 'unsupported hosts must not hide healthy peers'
git(no_origin, 'config', '--unset', 'remote.origin.url')

# A project whose origin is a local filesystem path has no forge pull requests to collect: it is disclosed
# by name as informational coverage and never degrades the ledger; a real read error still does.
local_origin = home / 'projects/local-origin'
out(['git', 'init', '-q', '-b', 'main', local_origin])
for origin_url in (str(world / 'origin.git'), 'file://' + str(world / 'origin.git'), '../../origin.git'):
    git(local_origin, 'config', 'remote.origin.url', origin_url)
    (world / 'gh-requests').write_text('')
    local_report = ledger()
    assert local_report['complete'], (origin_url, local_report)
    assert 'ledger degraded' not in rows(local_report, 'coverage'), (origin_url, local_report)
    disclosed = rows(local_report, 'coverage')['no forge coverage: local-origin']
    assert disclosed['informational'] and not disclosed['overdue'], disclosed
    assert str(local_origin) in disclosed['evidence'] and origin_url in disclosed['evidence'], disclosed
    assert rows(local_report, 'open_pr'), 'a local origin must not hide healthy GitHub peers'
broken_peer = home / 'projects/broken-peer'
broken_peer.mkdir(); (broken_peer / '.git').write_text('gitdir: /missing/open-loops-repository\n')
still_blind = ledger()
assert not still_blind['complete'], still_blind
blind_evidence = rows(still_blind, 'coverage')['ledger degraded']['evidence']
assert 'broken-peer' in blind_evidence and 'local-origin' not in blind_evidence, blind_evidence
assert 'no forge coverage: local-origin' in rows(still_blind, 'coverage'), still_blind
shutil.rmtree(broken_peer)
shutil.rmtree(local_origin)
print('PASS: local-path origins are disclosed without degrading the ledger', flush=True)
unsupported_pr = dict(number=90, html_url='https://evilgithub.com/test/project/pull/90',
                      head=dict(sha='b' * 40), state='open', updated_at=iso(hours(2)))
double['pulls'].append(unsupported_pr)
(world / 'gh.json').write_text(json.dumps(double))
projection_report = ledger()
assert projection_report['complete'], projection_report
assert rows(projection_report, 'coverage')['no forge coverage: ' + unsupported_pr['html_url']]['informational']
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
assert admission_report['complete'], admission_report
skipped = rows(admission_report, 'coverage')['no forge coverage: https://github.com.evil/test/project/pull/91']
assert skipped['informational'] and 'unsupported PR forge' in skipped['evidence'], admission_report
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
# A byte cap can cut a multibyte character; an invalid UTF-8 byte must not blind the questions source.
cut = home / 'state/cut.status'
cut.write_bytes(f'needs-decision [at={hours(1)}] [key=cut]: caf\xe9 question\n'.encode('latin-1'))
cut_report = ledger()
assert cut_report['complete'] and not rows(cut_report, 'coverage'), cut_report
assert 'cut:cut' in rows(cut_report, 'unanswered_question'), cut_report
cut.unlink()
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
    # The named reader injects SIGALRM; allow normal REST-helper startup on loaded hosts.
    (deadline_home / 'config/open-loops.json').write_text(json.dumps(dict(command_timeout_seconds=30)))
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
if command == 'gh' and '/pulls?' in sys.argv[-1]:
    pulls = [] if reader == 'pr-state' else [dict(number=i, html_url='https://github.com/test/project/pull/' + str(i),
                  head=dict(sha='a' * 40), state='open') for i in range(24)]
    sys.stdout.write('HTTP/2.0 200 OK\r\n\r\n' + json.dumps(pulls))
    sys.exit(0)
attempts = Path(os.environ['FM_HOME']) / 'attempts'
with attempts.open('a') as stream:
    stream.write(json.dumps([command, *sys.argv[1:]]) + '\n')
if len(attempts.read_text().splitlines()) == 2:
    (attempts.parent / 'deadline-trigger').write_text(json.dumps([command, *sys.argv[1:]]))
    os.kill(int((attempts.parent / 'collector-pid').read_text()), signal.SIGALRM)
time.sleep(0.7)
print('source command failure', file=sys.stderr)
sys.exit(1)
'''
    for command in (('git', 'gh', 'cat') if reader == 'questions' else ('git', 'gh')):
        script(deadline_bin / command, driver)
    deadline_env = dict(env, FM_HOME=str(deadline_home), DEADLINE_READER=reader,
                        PATH=f'{deadline_bin}:{env["PATH"]}')
    deadline_report = json.loads(out([deadline_code / 'bin/fm-open-loops.sh', '--heartbeat', '--json'],
                                    env=deadline_env, timeout=120))
    assert not deadline_report['complete'] and len(rows(deadline_report, 'coverage')) == 1, deadline_report
    assert 'collection exceeded its deadline' in rows(deadline_report, 'coverage')['ledger degraded']['evidence'], (reader, deadline_report)
    attempts = [json.loads(line) for line in (deadline_home / 'attempts').read_text().splitlines()]
    expected_requests = {
        'origins': [['git', '-C', str(deadline_home / 'projects' / str(i)),
                     'config', '--get', 'remote.origin.url'] for i in range(24)],
        'pr-checks': [['gh', 'api', '-i',
                       'repos/test/project/commits/' + 'a' * 40 + '/check-runs?per_page=100']],
        'pr-state': [['gh', 'api', '-i', 'repos/test/project/pulls/' + str(i)] for i in range(24)],
        'questions': [['cat', str(deadline_home / 'state' / (str(i) + '.status'))] for i in range(24)],
    }
    assert len(attempts) == 2 and all(request in expected_requests[reader] for request in attempts), (reader, attempts)
    assert json.loads((deadline_home / 'deadline-trigger').read_text()) == attempts[-1], (reader, attempts)
    assert json.loads((deadline_home / 'state/open-loops.json').read_text()) == deadline_report
    print('PASS: deadline escapes ' + reader + ' source recovery', flush=True)
# Conditional reads and the quota floor: a repeated run over unchanged forge data is answered with 304s, and a run
# that finds the recorded quota below the floor publishes the last rows marked stale with the reset time.
double.pop('pulls_by_repo', None)
(world / 'gh.json').write_text(json.dumps(double))
requests, not_modified = world / 'gh-requests', world / 'gh-requests_304'
state_dir = home / 'state'
shutil.rmtree(state_dir / 'gh-rest-cache', ignore_errors=True)
for record in state_dir.glob('gh-ratelimit.*.json'):
    record.unlink()
requests.write_text('')
not_modified.unlink(missing_ok=True)
first = json.loads(out([code / 'bin/fm-open-loops.sh', '--json']))
first_requests = requests.read_text().splitlines()
assert first_requests and not not_modified.exists(), 'the first run must read the forge normally'
requests.write_text('')
second = json.loads(out([code / 'bin/fm-open-loops.sh', '--json']))
second_requests = requests.read_text().splitlines()
assert second_requests == first_requests, (first_requests, second_requests)
assert not_modified.read_text().splitlines() == second_requests, 'unchanged reads were not answered with 304'
assert second == first, 'a cached read changed the ledger'

low = dict(env, GH_REMAINING='500', GH_NEXT_LINK='/repos/test/project/pulls?per_page=100&page=2')
published = json.loads(out([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json']))
assert published['complete'] is True and 'stale' not in published, published
# A run whose own responses report 500 of 5000 left crosses the floor mid-sweep: it stops reading and keeps the
# last published rows instead of publishing a partial set.
requests.write_text('')
crossing = json.loads(out([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json'], env=low))
assert crossing['stale'] is True and len(requests.read_text().splitlines()) == 1, (crossing, requests.read_text())
reset = json.loads((state_dir / 'gh-ratelimit.core.json').read_text())['reset']
requests.write_text('')
held = json.loads(out([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json']))
assert requests.read_text() == '', 'a run below the floor still read the forge'
assert held['stale'] is True and held['complete'] is False and held['stale_until_epoch'] == reset, held
assert 'quota low (500 of 5000' in held['stale_reason'] and iso(reset) in held['stale_reason'], held['stale_reason']
assert held['generated_epoch'] == published['generated_epoch']
kept = {r['id']: r for r in held['rows'] if r['subject'] != 'ledger stale'}
assert set(kept) == {r['id'] for r in published['rows']} and all(r['stale'] is True for r in kept.values()), held['rows']
marker_row = rows(held, 'coverage')['ledger stale']
assert marker_row['informational'] is True and marker_row['overdue'] is False and iso(reset) in marker_row['evidence'], marker_row
assert json.loads((state_dir / 'open-loops.json').read_text()) == held, 'the stale ledger was not published'
again = json.loads(out([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json']))
assert again['rows'] == held['rows'], 'a second stale run must not stack stale rows'

(state_dir / 'open-loops.json').unlink()
orphaned = json.loads(out([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json']))
degraded = rows(orphaned, 'coverage')['ledger degraded']
assert orphaned['complete'] is False and 'quota low' in degraded['evidence'] and iso(reset) in degraded['evidence'], orphaned
assert requests.read_text() == ''

(state_dir / 'gh-ratelimit.core.json').write_text(json.dumps(dict(resource='core', limit=5000, remaining=0, reset=now - 5,
                                                                 observed=now - 3600)))
recovered = json.loads(out([code / 'bin/fm-open-loops.sh', '--heartbeat', '--json']))
assert recovered['complete'] is True and 'stale' not in recovered and not any(r.get('stale') for r in recovered['rows'])
assert requests.read_text(), 'the sweep did not resume after the window reset'
print('PASS: unchanged forge reads are 304s and a run below the quota floor publishes stale rows with the reset time')
print('PASS: owned-work categories, owners, ages, degraded row, and atomic publication')
PY

# Report silence through the real snapshot, ledger, inbox send and pending-reply store.
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import datetime as dt, json, os, shutil, subprocess, sys, time
from pathlib import Path
root, world = map(Path, sys.argv[1:])
code, home, fake = (world / name for name in ('silence-code', 'silence-home', 'silence-fake'))
shutil.copytree(root / 'bin', code / 'bin')
for name in ('state', 'data', 'config', 'projects'):
    (home / name).mkdir(parents=True)
fake.mkdir()
now = int(time.time())
def script(path, text):
    path.write_text(text); path.chmod(0o755)
script(code / 'bin/fm-crew-state.sh', '#!/usr/bin/env bash\nprintf "state: %s · source: %s · %s\\n" "${FM_SILENCE_TEST_CREW_STATE:-working}" "${FM_SILENCE_TEST_CREW_SOURCE:-pane}" "${FM_SILENCE_TEST_CREW_DETAIL:-building}"\n')
# This fixture supplies endpoint observations, not a rendered vendor-process classifier.
backend = code / 'bin/fm-backend.sh'
backend.write_text(backend.read_text() + '\nfm_backend_agent_state() { printf "%s" "${FM_SILENCE_TEST_LIVENESS:-alive}"; }\n'
                   'fm_backend_agent_alive() { printf "%s" "${FM_SILENCE_TEST_LIVENESS:-alive}"; }\n')
script(fake / 'tmux', '''#!/usr/bin/env bash
case "$1" in
  capture-pane) printf '╭────╮\\n│    │\\n╰────╯\\n' ;;
  list-windows) printf 'fm-worker\\nfm-scout\\nfm-mate\\n' ;;
  display-message) printf 'fakepane\\n' ;;
  send-keys) printf '%s\\n' "$*" >> "$FM_SEND_LOG" ;;
esac
''')
(home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
env = dict(os.environ, FM_HOME=str(home), FM_OPEN_LOOPS_NOW=str(now), FM_PENDING_REPLY_NOW=str(now),
           FM_PAUSE_RESURFACE_SECS='14400', NM_HOME=str(world / 'silence-nm'), FM_SEND_LOG=str(world / 'silence-send.log'),
           PATH=f'{fake}:{os.environ["PATH"]}')
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE',
            'FM_PENDING_REPLY_DIR_OVERRIDE', 'FM_PENDING_REPLY_EXISTING_CORR'):
    env.pop(key, None)
def call(*args, extra=None):
    done = subprocess.run([str(code / 'bin/fm-open-loops.sh'), *args], env=dict(env, **(extra or {})),
                          text=True, capture_output=True, timeout=120)
    assert done.returncode == 0, (args, done.stdout, done.stderr)
    return done.stdout

def rows(extra=None):
    report = json.loads(call('--json', extra=extra))
    assert report['complete'], report
    return {r['subject']: r for r in report['rows'] if r['category'] == 'silent_report'}
def status(name, text, at):
    path = home / f'state/{name}.status'
    path.write_text(text)
    os.utime(path, (at, at))
for name, kind in (('worker', 'ship'), ('scout', 'scout')):
    (home / f'state/{name}.meta').write_text(f'kind={kind}\nbackend=tmux\nwindow=sess:fm-{name}\nharness=claude\n')
    status(name, f'working [at={now - 901}]: building\n', now - 901)
silent = rows()
assert silent['worker']['overdue'] and silent['worker']['age_seconds'] == 901, silent
assert silent['worker']['limit_seconds'] == 900 and silent['scout']['overdue'], silent
assert not rows(extra={'FM_SILENCE_TEST_LIVENESS': 'dead'}), 'confirmed dead endpoints are recovery, not silent live reports'
# Canonical status stamp wins over an old mtime; an unstamped legacy event falls back to mtime.
status('worker', f'working [at={now - 7}]: building\n', now - 2000)
assert rows()['worker']['age_seconds'] == 7
status('worker', 'working: building\n', now - 8)
assert rows()['worker']['age_seconds'] == 8
# Handled move resets the clock, not message creation or terminal/transport activity.
status('worker', f'working [at={now - 901}]: building\n', now - 901)
inbox = home / 'state/worker.inbox'; handled = inbox / 'handled'; handled.mkdir(parents=True)
message = inbox / '001.msg'; message.write_text('schema=fm-task-inbox.v1\n\nold steer\n')
os.utime(message, (now - 2000, now - 2000)); message.rename(handled / message.name)
os.utime(handled, (now - 9, now - 9))
assert rows()['worker']['age_seconds'] == 9
shutil.rmtree(inbox)
# Only a resolved reply counts; delivered_epoch and an unresolved request do not reset age.
pending = home / 'state/pending-replies'; pending.mkdir()
record = pending / 'abcdef0123456789'
record.write_text(f'task_id=worker\nphase=resolved\nresolved_epoch={now - 10}\n')
assert rows()['worker']['age_seconds'] == 10
future_reply = pending / 'fedcba9876543210'
future_reply.write_text(f'task_id=worker\nphase=resolved\nresolved_epoch={now + 10}\n')
assert rows()['worker']['age_seconds'] == 10, 'a future reply cannot hide an older valid report'
future_reply.unlink()
record.write_text(f'task_id=worker\nphase=awaiting_report\ndelivered_epoch={now}\n')
r = rows()['worker']; assert r['age_seconds'] == 901 and not r['overdue'] and r['informational'], r
record.unlink()
# Named pauses are excluded from the short cadence, not forgotten forever; elapsed deadlines restore it.
status('worker', f'paused [at={now - 901}]: awaiting CI to finish\n', now - 901)
r = rows()['worker']; assert not r['overdue'] and r['limit_seconds'] == 14400 and 'declared wait' in r['evidence'], r
status('worker', f'paused [at={now - 14400}]: awaiting CI to finish\n', now - 14400)
assert rows()['worker']['overdue']
clearing = dt.datetime.fromtimestamp(now - 1, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
status('worker', f'paused [at={now - 901}]: awaiting CI until {clearing}\n', now - 901)
r = rows()['worker']; assert r['overdue'] and r['limit_seconds'] == 900, r
# A verified captain-held wait gets the same long cadence as a named pause.
status('worker', f'captain-held [at={now - 901}]: awaiting captain approval\n', now - 901)
r = rows()['worker']; assert not r['overdue'] and r['limit_seconds'] == 14400 and 'declared wait' in r['evidence'], r
status('worker', f'captain-held [at={now - 14400}]: awaiting captain approval\n', now - 14400)
assert rows()['worker']['overdue']
# Firstmate owes the next move on its own open decision or blocker, so the silence check-in stays out.
for line in (f'needs-decision [at={now - 901}] [key=k]: pick A or B', f'blocked [at={now - 901}] [key=k]: waiting on answer'):
    status('worker', line + '\n', now - 901)
    r = rows()['worker']
    assert not r['overdue'] and r['informational'] and 'waiting on firstmate' in r['evidence'], r
# Keys a supervisor raised about other work are not this report's own wait: a quiet report stays eligible.
for key in ('captain-hold-child-1', 'remote-reply-continuity-abc', 'pending-reply-abc'):
    status('worker', f'needs-decision [at={now - 901}] [key={key}]: relayed decision\n', now - 901)
    r = rows()['worker']
    assert r['overdue'] and not r.get('informational') and 'waiting on firstmate' not in r['evidence'], (key, r)
status('worker', f'working [at={now - 901}]: building\n', now - 901)
# A parked gate is firstmate-owed only when its verdict says a human owes the answer; otherwise the worker owes it.
human = {'FM_SILENCE_TEST_CREW_STATE': 'parked', 'FM_SILENCE_TEST_CREW_SOURCE': 'run-step',
         'FM_SILENCE_TEST_CREW_DETAIL': 'parked at fix_review: 1 finding(s) · ask-user: authority decision · run: r1'}
r = rows(extra=human)['worker']
assert not r['overdue'] and r['informational'] and 'waiting on firstmate' in r['evidence'], r
for gate in ('awaiting_agent', 'fix_review'):
    own = dict(human, FM_SILENCE_TEST_CREW_DETAIL=f'parked at {gate}: 1 finding(s) · run: r1')
    r = rows(extra=own)['worker']
    assert r['overdue'] and not r.get('informational'), (gate, r)
assert rows()['worker']['overdue']
# A worker with no status line yet starts its clock at dispatch (task record mtime).
status_file = home / 'state/worker.status'; meta_file = home / 'state/worker.meta'
status_file.rename(home / 'state/worker.status.hold')
os.utime(meta_file, (now - 5, now - 5))
r = rows()['worker']; assert r['age_seconds'] == 5 and not r['overdue'] and 'clock starts at dispatch' in r['evidence'], r
os.utime(meta_file, (now - 901, now - 901))
r = rows()['worker']; assert r['age_seconds'] == 901 and r['overdue'], r
os.utime(meta_file, (now, now))
(home / 'state/worker.status.hold').rename(status_file)
status('worker', f'done [at={now - 2000}]: ready in branch\n', now - 2000)
r = rows()['worker']; assert not r['overdue'] and r['informational'] and 'done/ready' in r['evidence'], r
# Ordinary check-in uses the real inbox, requests a report before ack, never types payload or interrupts.
status('worker', f'working [at={now - 901}]: building\n', now - 901)
call('--check-in', 'worker')
messages = list(inbox.glob('*.msg')); assert len(messages) == 1, messages
body = messages[0].read_text(); assert 'report progress, blockers, and cross-workstream dependencies' in body
call('--check-in', 'worker'); assert len(list(inbox.glob('*.msg'))) == 1
sent = Path(env['FM_SEND_LOG']).read_text()
assert 'report progress' not in sent and 'C-c' not in sent and 'instruction waiting' in sent, sent
# A real secondmate-shaped home uses the same tracker for its direct workers.
(home / '.fm-secondmate-home').write_text('domain-mate\n')
assert rows()['scout']['overdue']
(home / '.fm-secondmate-home').unlink()
# Persistent secondmate idle/active distinction uses its own canonical backlog, not pane activity.
mate_home = world / 'silence-mate'
for name in ('state', 'data', 'config', 'projects'):
    (mate_home / name).mkdir(parents=True)
(mate_home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
(home / 'state/mate.meta').write_text(f'kind=secondmate\nbackend=tmux\nwindow=sess:fm-mate\nharness=claude\nhome={mate_home}\n')
status('mate', f'working [at={now - 2000}]: idle\n', now - 2000)
r = rows()['mate']; assert not r['overdue'] and 'idle secondmate' in r['evidence'], r
# Idle remains healthy even after an old named wait reaches the pause recheck cadence.
status('mate', f'paused [at={now - 14401}]: waiting for routed work\n', now - 14401)
r = rows()['mate']
assert r['age_seconds'] == 14401 and r.get('informational') and not r['overdue'] and 'idle secondmate' in r['evidence'], r
call('--check-in', 'mate')
assert not list((home / 'state/mate.inbox').glob('*.msg')), 'idle secondmate must not receive a silence check-in'
status('mate', f'working [at={now - 2000}]: idle\n', now - 2000)
(mate_home / 'data/backlog.md').write_text('## In flight\n- [ ] routed - Routed work (repo: firstmate) (kind: ship)\n\n## Queued\n\n## Done\n')
assert rows()['mate']['overdue']
call('--check-in', 'mate')
records = [p for p in pending.iterdir() if not p.name.startswith('.')]
assert len(records) == 1, records
fields = dict(line.split('=', 1) for line in records[0].read_text().splitlines() if '=' in line)
assert fields['task_id'] == 'mate' and fields['phase'] == 'awaiting_report' and fields['delivered_epoch'], fields
mate_messages = list((home / 'state/mate.inbox').glob('*.msg'))
assert len(mate_messages) == 1 and f'corr={fields["corr_id"]}' in mate_messages[0].read_text()
call('--check-in', 'mate'); assert len(list((home / 'state/mate.inbox').glob('*.msg'))) == 1
r = rows()['mate']; assert r['age_seconds'] == 2000 and not r['overdue'] and 'pending' in r['evidence'], r
# A correlated report resolves through the same library the watcher runs and restarts the silence clock.
status('mate', f'working [at={now - 11}] corr={fields["corr_id"]}: progress reported\n', now - 11)
resolved = subprocess.run(['bash', '-c', '. "$1"; fm_pending_reply_try_resolve "$2" "$3"', '_',
                           str(code / 'bin/fm-pending-reply-lib.sh'), str(home / 'state'), fields['corr_id']],
                          env=env, text=True, capture_output=True, timeout=120)
assert resolved.returncode == 0, (resolved.stdout, resolved.stderr)
assert rows()['mate']['age_seconds'] == 0
# Per-category override and inclusive boundary.
(home / 'config/open-loops.json').write_text('{"age_limits_seconds":{"silent_report":902}}')
r = rows()['scout']; assert not r['overdue'] and r['limit_seconds'] == 902, r
(home / 'config/open-loops.json').write_text('{"age_limits_seconds":{"silent_report":901}}')
assert rows()['scout']['overdue']
refused = subprocess.run([str(code / 'bin/fm-open-loops.sh'), '--check-in', 'worker'],
                         env=dict(env, FM_HOME=''), text=True, capture_output=True, timeout=120)
assert refused.returncode == 1 and 'FM_HOME is required' in refused.stdout
print('PASS: silence clock resets, exclusions, check-in inbox/correlation deduplication, and secondmate-home run', flush=True)
PY

# The real snapshot's home-input contract: large inventories travel by file, direct secondmates
# are retained, and a captain drop is read back from the stored completion note.
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
  and (.tasks | map(.id) == ["mate-lane", "worker"])
  and (.backlog.records[] | select(.id == "dropped-one") | .captain_drop == true)
  and (.backlog.records[] | select(.id == "held-drop") | .state == "queued" and .captain_drop == true)
  and (.backlog.records[] | select(.id == "landed-one") | .captain_drop == false)' >/dev/null \
  || { echo "FAIL: home-input contract" >&2; exit 1; }
echo "PASS: home-input carries a large inventory, retains direct secondmates, and marks a captain drop"
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
printf '%s' "$INPUT" | jq -e '.tasks[] | select(.id == "worker")
  | .endpoint.exists == null and .endpoint.agent_alive == "unreadable"
  and .current_state.state == "unknown"' >/dev/null \
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
printf '%s' "$INPUT" | jq -e '.tasks[] | select(.id == "worker")
  | .current_state.state == "unknown"
  and (.current_state.detail | startswith("current-state command failed (exit "))' >/dev/null \
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
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import datetime as dt, json, os, re, shutil, subprocess, sys, time
from pathlib import Path
root, world = map(Path, sys.argv[1:])
code = world / 'action-code'
shutil.copytree(root / 'bin', code / 'bin')
now = int(time.time())
clock = dict(now=now)
PR = 'https://github.com/test/project/pull/9'

def inbox(home, record, handled=False, offset=0):
    path = home / 'state/worker.inbox' / ('handled' if handled else '') / record
    path.parent.mkdir(parents=True, exist_ok=True)
    sent = dt.datetime.fromtimestamp(clock['now'] + offset, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    path.write_text(f'schema=fm-task-inbox.v1\nat={sent}\n--\nfollow up\n')
    return path

def loops_as(home, actor, *args):
    actor_env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home),
                     FM_OPEN_LOOPS_NOW=str(clock['now']), FM_SUPERVISION_ACTOR=actor)
    for key in ('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
        actor_env.pop(key, None)
    return subprocess.run([str(code / 'bin/fm-open-loops.sh'), *args], env=actor_env, text=True, capture_output=True)

def case(name, actor='main', empty=False, **fields):
    home = world / ('action-' + name)
    for directory in ('state', 'config', 'data'):
        (home / directory).mkdir(parents=True)
    env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home),
               FM_OPEN_LOOPS_NOW=str(now), FM_SUPERVISION_ACTOR=actor,
               FM_TEST_SEAM='1', FM_TEST_HARNESS='codex')
    for key in ('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
        env.pop(key, None)
    row = dict(id='row-' + name, category='stalled_worker', subject='worker', owner='worker:worker',
               next_action='follow up on lint.full.whole', age_seconds=7200, limit_seconds=3600,
               overdue=True, evidence='waiting for lint.full.whole; declaration age 7200s')
    row.update(fields)
    ledger = home / 'state/open-loops.json'
    ledger.write_text(json.dumps(dict(schema='fm-open-loops.v1', generated_epoch=now, complete=True,
                                     rows=[] if empty else [row])))
    def call(*args):
        return subprocess.run([str(a) for a in args], env=dict(env, FM_OPEN_LOOPS_NOW=str(clock['now'])),
                              text=True, capture_output=True)
    def ok(*args):
        result = call(*args)
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return result
    ok('bash', '-c', '. "$1"; fm_wake_append check report "check: board report"',
       '_', code / 'bin/fm-wake-lib.sh')
    if actor == 'branch':
        (home / 'config/supervision-host').write_text('claude\n')
        ok(code / 'bin/fm-wake-grant.sh', 'activate', os.getpid(), 'engine-turn')
        ok(code / 'bin/fm-wake-grant.sh', 'publish', 'engine-turn', '1')
    def drain():
        result = ok(code / 'bin/fm-wake-drain.sh')
        match = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', result.stderr)
        assert match, (result.stdout, result.stderr)
        return result, match.groups()
    def ack(boundary):
        return call(code / 'bin/fm-wake-drain.sh', '--ack-through', boundary[0],
                    '--recovery-generation', boundary[1])
    return home, ledger, row, call, ok, drain, ack

for kind in ('steered', 'merged', 'escalated', 'deferred'):
    pr_row = dict(category='review_pass_not_merged', subject=PR, owner='firstmate', limit_seconds=600)
    home, ledger, row, call, ok, drain, ack = case(kind, **(pr_row if kind == 'merged' else {}))
    os.utime(ledger, (now - 7200, now - 7200))
    publication_mtime = ledger.stat().st_mtime_ns
    result, boundary = drain()
    assert ledger.stat().st_mtime_ns == publication_mtime, 'presentation cannot conceal a stopped collector'
    assert result.stdout.startswith('OVERDUE:'), result.stdout
    assert 'lint.full.whole' in result.stdout and '7200' in result.stdout and row['owner'] in result.stdout
    queue = (home / 'state/.wake-queue').read_bytes()
    refused = ack(boundary)
    assert refused.returncode == 1 and 'no action recorded' in refused.stdout, refused
    assert (home / 'state/.wake-queue').read_bytes() == queue, 'refusal must preserve queued work'
    evidence = {'steered': '001.msg', 'merged': 'https://github.com/test/project/pull/9',
                'escalated': 'reported missing credential to captain', 'deferred': 'lint still producing output'}[kind]
    args = [code / 'bin/fm-open-loops.sh', 'action', row['id'], kind, '--evidence', evidence]
    if kind == 'deferred':
        args += ['--recheck', dt.datetime.fromtimestamp(now + 600, dt.timezone.utc).isoformat()]
    if kind == 'steered':
        unverified = call(*args)
        assert unverified.returncode == 1 and "task inbox" in unverified.stdout, unverified
        inbox(home, evidence)
    if kind == 'merged':
        other = call(*args[:-1], PR[:-1] + '8')
        assert other.returncode == 1 and "this row's PR URL" in other.stdout, other
        unrecorded = call(*args)
        assert unrecorded.returncode == 1 and 'merge recorded' in unrecorded.stdout, unrecorded
        marker = home / 'state/worker.pr-poll-merge-notified'
        marker.write_text('fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\ntest/project\n9\n')
    ok(*args)
    assert ledger.stat().st_mtime_ns == publication_mtime, 'action receipts cannot refresh ledger publication age'
    assert ack(boundary).returncode == 0
    assert not (home / 'state/.wake-queue').read_text(), 'recorded action must permit consumption'
    if kind == 'deferred':
        refused = call(*args)
        assert refused.returncode == 1 and 'second deferral refused' in refused.stdout, refused
        assert json.loads(ledger.read_text())['rows'][0]['captain_visible'] is True
        assert call(code / 'bin/fm-open-loops.sh', '--check-actions').returncode == 1
        ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'escalated', '--evidence', 'second deferral escalated')
        ok(code / 'bin/fm-open-loops.sh', '--check-actions')

# The actual supervision-host actor and secondmate home use the same executable gate.
for name, actor in (('host', 'branch'), ('secondmate', 'main')):
    home, ledger, row, call, ok, drain, ack = case(name, actor)
    if name == 'secondmate':
        (home / '.fm-secondmate-home').write_text('mate\n')
    result, boundary = drain()
    assert ack(boundary).returncode == 1
    inbox(home, '002.msg', handled=True)
    ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence', '002.msg')
    assert ack(boundary).returncode == 0
    report = ok(code / 'bin/fm-open-loops.sh', '--report').stdout
    assert row['id'] in report and '7200' in report and 'COMPLETIONS' not in report, report

# Re-presentation is idempotent while an action is still missing. A later turn requires a new action.
home, ledger, row, call, ok, drain, ack = case('repeat')
_, boundary = drain()
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'escalated', '--evidence', 'reported the wait')
assert ack(boundary).returncode == 0
ok('bash', '-c', '. "$1"; fm_wake_append check report "check: followup"', '_', code / 'bin/fm-wake-lib.sh')
_, boundary = drain()
_, again = drain()
assert boundary == again
assert ack(boundary).returncode == 1, 'old action cannot discharge a later turn'
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'escalated', '--evidence', 'needs intervention')
assert ack(boundary).returncode == 0

# A steer must be a new delivery sent after the row's presentation, and each record is cited once.
home, ledger, row, call, ok, drain, ack = case('steer-fresh')
_, boundary = drain()
inbox(home, '003.msg', handled=True, offset=-60)
stale = call(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence', '003.msg')
assert stale.returncode == 1 and 'new delivery' in stale.stdout, stale
inbox(home, '004.msg')
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence', '004.msg')
assert ack(boundary).returncode == 0
ok('bash', '-c', '. "$1"; fm_wake_append check report "check: next turn"', '_', code / 'bin/fm-wake-lib.sh')
_, boundary = drain()
assert ack(boundary).returncode == 1, 'a steer answers only the turn it followed'
reused = call(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence', '004.msg')
assert reused.returncode == 1 and 'new delivery' in reused.stdout, reused
inbox(home, '005.msg')
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence', '005.msg')
assert ack(boundary).returncode == 0

# PR URLs do not encode the owning task; provenance selects its inbox in both delivery locations.
for handled in (False, True):
    home, ledger, row, call, ok, drain, ack = case(
        'pr-steer-' + str(handled), category='open_pr', subject=PR, owner='firstmate',
        source=dict(task='worker'))
    _, boundary = drain()
    args = [code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence']
    foreign = home / 'state/another-task.inbox/001.msg'
    foreign.parent.mkdir()
    foreign.write_text(inbox(home, '001.msg').read_text())
    (home / 'state/worker.inbox/001.msg').unlink()
    refused = call(*args, '001.msg')
    assert refused.returncode == 1 and 'task inbox' in refused.stdout, refused
    inbox(home, '002.msg', handled=handled, offset=-60)
    refused = call(*args, '002.msg')
    assert refused.returncode == 1 and 'new delivery' in refused.stdout, refused
    inbox(home, '003.msg', handled=handled, offset=1)
    ok(*args, '003.msg')
    action = json.loads(ledger.read_text())['handling']['actions'][row['id']]
    assert action['kind'] == 'steered' and action['evidence'] == '003.msg', action
    assert ack(boundary).returncode == 0
    reused = call(*args, '003.msg')
    assert reused.returncode == 1 and 'new delivery' in reused.stdout, reused
print('PASS: PR provenance steers use own inbox or handled records, reject foreign, old and reused evidence, and permit acknowledgement', flush=True)

# A damaged ledger row whose source is not an object still steers through its owner.
for index, damaged in enumerate(('a string', None, ['worker'], 7)):
    home, ledger, row, call, ok, drain, ack = case('damaged-source-' + str(index), source=damaged)
    _, boundary = drain()
    inbox(home, '001.msg', offset=1)
    ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence', '001.msg')
    action = json.loads(ledger.read_text())['handling']['actions'][row['id']]
    assert action['kind'] == 'steered' and action['evidence'] == '001.msg', (damaged, action)
    assert ack(boundary).returncode == 0
print('PASS: a steer on a row with a non-object source falls back to its owner inbox', flush=True)

# Steering evidence is judged against the acting actor's own presentation, not another actor's later one.
home, ledger, row, call, ok, drain, ack = case('actors')
assert loops_as(home, 'main', '--present-overdue').returncode == 0
clock['now'] = now + 10
inbox(home, '010.msg')
clock['now'] = now + 20
assert loops_as(home, 'branch', '--present-overdue').returncode == 0
accepted = loops_as(home, 'main', 'action', row['id'], 'steered', '--evidence', '010.msg')
assert accepted.returncode == 0, ('a later presentation by another actor refused main steer', accepted.stdout)
clock['now'] = now

# A message sent before a deferral cannot answer the row when that deferral lapses.
home, ledger, row, call, ok, drain, ack = case('deferral-boundary')
assert loops_as(home, 'main', '--present-overdue').returncode == 0
inbox(home, '020.msg')
clock['now'] = now + 100
recheck = dt.datetime.fromtimestamp(now + 700, dt.timezone.utc).isoformat()
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'deferred', '--evidence', 'lint active', '--recheck', recheck)
clock['now'] = now + 800
assert call(code / 'bin/fm-open-loops.sh', '--check-actions').returncode == 1
old_message = call(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence', '020.msg')
assert old_message.returncode == 1 and 'new delivery' in old_message.stdout, old_message
inbox(home, '021.msg')
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence', '021.msg')
clock['now'] = now

# A reviewed green PR is firstmate's to merge: an escalation never stands on it, so each presentation needs an action.
home, ledger, row, call, ok, drain, ack = case('approval', category='review_pass_not_merged', subject=PR,
                                               next_action='merge with existing authority or escalate for approval',
                                               evidence='independent review PASS at live head', limit_seconds=600)
_, boundary = drain()
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'escalated', '--evidence', 'asked the captain to approve')
assert ack(boundary).returncode == 0
ok('bash', '-c', '. "$1"; fm_wake_append check report "check: approval pending"', '_', code / 'bin/fm-wake-lib.sh')
_, boundary = drain()
assert ack(boundary).returncode == 1, 'an escalation cannot silence a mergeable reviewed PR'
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'escalated', '--evidence', 'asked the captain again')
assert ack(boundary).returncode == 0

home, ledger, row, call, ok, drain, ack = case('approval-deferred', category='review_pass_not_merged', subject=PR,
                                               next_action='merge with existing authority or escalate for approval',
                                               evidence='independent review PASS at live head', limit_seconds=600)
_, boundary = drain()
future = dt.datetime.fromtimestamp(now + 600, dt.timezone.utc).isoformat()
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'deferred', '--evidence', 'waiting', '--recheck', future)
assert ack(boundary).returncode == 0
ok('bash', '-c', '. "$1"; fm_wake_append check report "check: deferred approval row"', '_', code / 'bin/fm-wake-lib.sh')
result, boundary = drain()
assert row['id'] in result.stdout and 'STANDING' not in result.stdout, result
assert ack(boundary).returncode == 1, 'a deferral cannot hold a mergeable reviewed PR across turns'

# One escalation of a captain-owned row stands until the row changes.
home, ledger, row, call, ok, drain, ack = case('captain', category='unanswered_question', subject='hold:captain-hold',
                                               owner='captain', next_action='resolve the captain hold',
                                               evidence='awaiting budget approval', limit_seconds=1800)
_, boundary = drain()
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'escalated', '--evidence', 'asked the captain')
assert ack(boundary).returncode == 0
clock['now'] = now + 2 * 86400
ok('bash', '-c', '. "$1"; fm_wake_append check report "check: unchanged"', '_', code / 'bin/fm-wake-lib.sh')
_, boundary = drain()
assert ack(boundary).returncode == 0, 'an unchanged captain row needs no new escalation'
clock['now'] = now
record = json.loads(ledger.read_text())
record['rows'][0]['source'] = dict(kind='captain_hold', home=str(home), task='hold', decision='same hold')
ledger.write_text(json.dumps(record))
ok('bash', '-c', '. "$1"; fm_wake_append check report "check: source provenance added"', '_', code / 'bin/fm-wake-lib.sh')
_, boundary = drain()
assert ack(boundary).returncode == 0, 'a collector schema addition must not require replaying an unchanged escalation'
record = json.loads(ledger.read_text())
record['rows'][0]['evidence'] = 'captain asked for a revised budget'
ledger.write_text(json.dumps(record))
ok('bash', '-c', '. "$1"; fm_wake_append check report "check: changed"', '_', code / 'bin/fm-wake-lib.sh')
_, boundary = drain()
assert ack(boundary).returncode == 1, 'a changed captain row needs a new escalation'

# An idle drain whose only overdue rows stand opens no handling episode and demands no acknowledgement.
home, ledger, row, call, ok, drain, ack = case('idle-standing', category='unanswered_question', subject='hold:captain-hold',
                                               owner='captain', next_action='resolve the captain hold',
                                               evidence='awaiting budget approval', limit_seconds=1800)
(home / 'state/.wake-queue').write_text('')
_, boundary = drain()
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'escalated', '--evidence', 'asked the captain')
assert ack(boundary).returncode == 0
idle = ok(code / 'bin/fm-wake-drain.sh')
assert 'OVERDUE' not in idle.stdout and 'STANDING' not in idle.stdout and 'WAKE_ACK_REQUIRED' not in idle.stderr, idle
ok('bash', '-c', '. "$1"; fm_wake_append check report "check: standing beside new work"', '_', code / 'bin/fm-wake-lib.sh')
record = json.loads(ledger.read_text())
record['rows'].append(dict(row, id='row-fresh', subject='other-worker', category='stalled_worker', owner='worker:other-worker'))
ledger.write_text(json.dumps(record))
mixed = ok(code / 'bin/fm-wake-drain.sh')
assert 'row-fresh' in mixed.stdout and 'STANDING' in mixed.stdout and mixed.stdout.index('row-fresh') < mixed.stdout.index('STANDING'), mixed

# An unreadable ledger never blocks a drain or an acknowledgement; it names the exact repair command.
for label in ('corrupt', 'symlink'):
    home, ledger, row, call, ok, drain, ack = case('unreadable-' + label)
    if label == 'corrupt':
        ledger.write_text('{"schema": "fm-open-loops.v1", "rows": [')
    else:
        target = home / 'elsewhere.json'
        target.write_text(ledger.read_text())
        ledger.unlink()
        ledger.symlink_to(target)
    result, boundary = drain()
    assert 'ledger unreadable' in result.stderr and f'rm {ledger.parent.resolve() / ledger.name}' in result.stderr, result
    assert 'OVERDUE' not in result.stdout, result
    assert ack(boundary).returncode == 0, 'an unreadable ledger must not refuse an acknowledgement'
    assert not (home / 'state/.wake-queue').read_text(), 'the acknowledged wake was consumed'
    assert call(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'escalated', '--evidence', 'x').returncode == 1
    if label == 'corrupt':
        rebuilt = json.loads(ok(code / 'bin/fm-open-loops.sh', '--heartbeat', '--json').stdout)
        assert rebuilt['schema'] == 'fm-open-loops.v1' and json.loads(ledger.read_text()) == rebuilt
    else:
        ledger.unlink()
        assert ok(code / 'bin/fm-open-loops.sh', '--check-actions').returncode == 0

# A collector's long-lived exclusion must not hold up the short publication/receipt boundary.
import fcntl
home, ledger, row, call, ok, drain, ack = case('collecting')
with (home / 'state/.open-loops.lock').open('a') as collecting:
    fcntl.lockf(collecting, fcntl.LOCK_EX, 1, 0)
    receipt_env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_OPEN_LOOPS_NOW=str(now))
    for key in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
        receipt_env.pop(key, None)
    presented = subprocess.run([str(code / 'bin/fm-open-loops.sh'), '--present-overdue'],
                               env=receipt_env, text=True, capture_output=True, timeout=15)
    assert presented.returncode == 0 and row['id'] in presented.stdout, presented

# A degraded refresh keeps an unseen presented row and its receipts, shown stale and not overdue.
home, ledger, row, call, ok, drain, ack = case('refresh')
_, boundary = drain()
inbox(home, '004.msg')
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence', '004.msg')
sequence = json.loads(ledger.read_text())['handling']['actions'][row['id']]['sequence']
refreshed = json.loads(ok(code / 'bin/fm-open-loops.sh', '--heartbeat', '--json').stdout)
kept = next(r for r in refreshed['rows'] if r['id'] == row['id'])
assert not refreshed['complete'] and kept['stale'] and not kept['overdue'], refreshed
assert refreshed['handling']['actions'][row['id']]['sequence'] == sequence, 'publication must retain action receipts'
assert ack(boundary).returncode == 0

# An unseen presented row is retained for 24 hours after it was last seen; then it and its receipts are dropped.
home, ledger, row, call, ok, drain, ack = case('retention')
_, boundary = drain()
inbox(home, '030.msg')
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'steered', '--evidence', '030.msg')
clock['now'] = now + 3600
first = json.loads(ok(code / 'bin/fm-open-loops.sh', '--heartbeat', '--json').stdout)
kept = next(r for r in first['rows'] if r['id'] == row['id'])
assert kept['stale'] and kept['last_seen'] == now and row['id'] in first['handling']['actions'], first
clock['now'] = now + 86400
second = json.loads(ok(code / 'bin/fm-open-loops.sh', '--heartbeat', '--json').stdout)
assert row['id'] not in {r['id'] for r in second['rows']}, second
assert row['id'] not in second['handling']['actions'], 'a returning stall starts a fresh row history'
assert row['id'] not in second['handling']['presentations']['main'], second
clock['now'] = now

home, ledger, row, call, ok, drain, ack = case('recheck')
_, boundary = drain()
future = dt.datetime.fromtimestamp(now + 600, dt.timezone.utc).isoformat()
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'deferred', '--evidence', 'lint active', '--recheck', future)
assert ack(boundary).returncode == 0
record = json.loads(ledger.read_text())
record['handling']['actions'][row['id']]['recheck_epoch'] = now
ledger.write_text(json.dumps(record))
assert call(code / 'bin/fm-open-loops.sh', '--check-actions').returncode == 1, 'a due deferral needs renewed followup'

# Empty queue still presents overdue work and requires its action; no overdue work is unchanged.
home, ledger, row, call, ok, drain, ack = case('no-wake')
(home / 'state/.wake-queue').write_text('')
_, boundary = drain()
assert boundary[0] == '0' and ack(boundary).returncode == 1
ok(code / 'bin/fm-open-loops.sh', 'action', row['id'], 'escalated', '--evidence', 'reported overdue work')
assert ack(boundary).returncode == 0
home, ledger, row, call, ok, drain, ack = case('empty', empty=True)
result, boundary = drain()
assert 'OVERDUE:' not in result.stdout
assert ack(boundary).returncode == 0
assert 'handling' not in json.loads(ledger.read_text()), 'empty presentation need not mutate the ledger'
print('PASS: refused acknowledgement, four verified action kinds, second deferral escalation, host and secondmate gates,'
      ' repeat, fresh steers, standing captain receipts, and empty turns')
PY
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
# Explicit dependency receipts through the collector, drain and generation-bound acknowledgement.
import datetime as dt, json, os, re, shutil, subprocess, sys, time
from pathlib import Path
root, world = map(Path, sys.argv[1:])
code, home = world / 'wait-code', world / 'wait-home'
shutil.copytree(root / 'bin', code / 'bin')
for name in ('state', 'data', 'config', 'projects'):
    (home / name).mkdir(parents=True)
now = int(time.time())
iso = lambda stamp: dt.datetime.fromtimestamp(stamp, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_TEST_SEAM='1',
           FM_TEST_HARNESS='codex', FM_SUPERVISION_ACTOR='main', FM_OPEN_LOOPS_NOW=str(now),
           NM_HOME=str(world / 'wait-nm'))
for key in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
    env.pop(key, None)
def call(*args):
    return subprocess.run([str(x) for x in args], env=env, text=True, capture_output=True, timeout=120)
def ok(*args):
    result = call(*args)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result

def executable(path, text):
    path.write_text(text); path.chmod(0o755)
fake = world / 'wait-fakebin'
fake.mkdir()
env['PATH'] = str(fake) + os.pathsep + env['PATH']
executable(fake / 'tmux', '''#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'fm-repair-owner\\n' ;;
  display-message) printf '%%1\\n' ;;
  capture-pane) printf 'all quiet\\n' ;;
  *) exit 1 ;;
esac
''')
executable(fake / 'no-mistakes', '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args=sys.argv[1:]
if args in (['axi'], ['axi','status'], ['axi','status','--run','01WAIT']):
    path=Path(os.environ['FM_HOME'])/'run.toon'
    if path.exists(): print(path.read_text())
elif args[:2] == ['daemon','status']:
    pass
elif args[:1] == ['runs']:
    path=Path(os.environ['FM_HOME'])/'runs.txt'
    if path.exists(): print(path.read_text())
else:
    raise AssertionError(args)
''')
# Only worker observation and the forge are doubled; holds use the real canonical backlog parser.
shutil.copy2(code / 'bin/fm-fleet-snapshot.sh', code / 'bin/real-fleet-snapshot.sh')
executable(code / 'bin/fm-fleet-snapshot.sh', '''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
p=Path(__file__).parent
if sys.argv[1]=='--contribution-input':
    os.execv(str(p/'real-fleet-snapshot.sh'),[str(p/'real-fleet-snapshot.sh'),*sys.argv[1:]])
assert sys.argv[1]=='--home-input'
snap=json.loads(subprocess.check_output([str(p/'real-fleet-snapshot.sh'),'--contribution-input']))
for task in snap['tasks']:
    task.update(current_state={'state':'paused' if task['id']=='held-job' else 'working','source':'status-log'},
                endpoint={'exists':True,'agent_alive':'alive'},paths={'worktree':{'path':None}},hints={})
snap['schema']='fm-fleet-home-input.v1'
print(json.dumps(snap))
''')
executable(code / 'bin/fm-gh-rest.sh', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=json.loads((Path(os.environ['FM_HOME'])/'forge.json').read_text())
url=sys.argv[2]
if '/pulls?' in url: value=[p]
elif '/check-runs' in url: value={'check_runs':[{'status':'completed','conclusion':'success'}]}
elif '/statuses?' in url: value=[]
else: raise AssertionError(url)
print(json.dumps([value]))
''')
pr='https://github.com/test/project/pull/140'
forge=dict(html_url=pr,number=140,state='open',draft=False,head={'sha':'a'*40},updated_at=iso(now-7200))
(home / 'forge.json').write_text(json.dumps(forge))
meta=home / 'state/held-job.meta'
meta.write_text('kind=ship\nspawn_gen=s-held\npr='+pr+'\n')
status=home / 'state/held-job.status'
original=f'blocked [at={now-7200}] [key=ci-control]: supported recovery control is missing\npaused [at={now}]: awaiting the recorded recovery decision\n'
status.write_text(original)
backlog=home / 'data/backlog.md'
held='## In flight\n- [ ] held-job - Recover the run (repo: firstmate) (kind: ship) (hold: exact run recovery) (hold-kind: captain)\n  Captain hold set: '+iso(now-7200)+'\n\n## Queued\n\n## Done\n'
backlog.write_text(held)
ledger=home / 'state/open-loops.json'
loops=code / 'bin/fm-open-loops.sh'
def publish():
    # Keep real file mtimes on the fixture clock, so freshly written workers are not future-dated.
    stamp=int(env['FM_OPEN_LOOPS_NOW'])
    for path in (home/'state').glob('*.status'):
        os.utime(path,(stamp,stamp))
    return json.loads(ok(loops,'--heartbeat','--json').stdout)
def row(report,subject):
    return next(r for r in report['rows'] if r['subject']==subject)
def action(ident,kind,evidence,*extra):
    return ok(loops,'action',ident,kind,'--evidence',evidence,*extra)
def drain():
    ok('bash','-c','. "$1"; fm_wake_append check report "check: dependency followup"','_',code/'bin/fm-wake-lib.sh')
    if env['FM_SUPERVISION_ACTOR'] == 'branch':
        (home/'config/supervision-host').write_text('claude\n')
        ok(code/'bin/fm-wake-grant.sh','activate',os.getpid(),'wait-turn')
        sequences=[line.split('\t')[1] for line in (home/'state/.wake-queue').read_text().splitlines()]
        ok(code/'bin/fm-wake-grant.sh','publish','wait-turn',*sequences)
    result=ok(code/'bin/fm-wake-drain.sh')
    boundary=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',result.stderr)
    assert boundary,(result.stdout,result.stderr)
    return boundary.groups()
def ack(boundary):
    return call(code/'bin/fm-wake-drain.sh','--ack-through',boundary[0],'--recovery-generation',boundary[1])
report=publish()
assert report['complete'],report
p=row(report,pr); question=row(report,'held-job:ci-control'); hold=row(report,'held-job:captain-hold')
boundary=drain()
assert ack(boundary).returncode==1
action(hold['id'],'escalated','existing exact recovery decision was routed')
for obligation in (p,question):
    action(obligation['id'],'waiting','this exact obligation awaits the recorded recovery question',
           '--prerequisite',hold['id'],'--recheck',iso(now+600))
assert ack(boundary).returncode==0
assert row(json.loads(ledger.read_text()),pr)['owner']=='firstmate'
assert row(json.loads(ledger.read_text()),'held-job:ci-control')['owner']=='firstmate'
assert status.read_text()==original and backlog.read_text()==held
boundary=drain()
assert ack(boundary).returncode==0,'unchanged bound PR/status waits must not need a fictitious second action'
assert p['id'] in ok(loops,'--report').stdout,'a standing wait must remain visible'
# A quota-stale ledger records no provenance wait and lets none stand, even though every source is otherwise current.
fresh_ledger=ledger.read_text(); stale_ledger=json.loads(fresh_ledger)
stale_ledger.update(stale=True,stale_reason='quota low (500 of 5000)',complete=False)
ledger.write_text(json.dumps(stale_ledger))
refused=call(loops,'action',question['id'],'waiting','--evidence','stale ledger','--prerequisite',hold['id'],'--recheck',iso(now+1200))
assert refused.returncode==1 and 'requires a current ledger' in refused.stdout,refused
assert call(loops,'--check-actions').returncode==1,'a stale ledger must not let a provenance wait stand'
ledger.write_text(fresh_ledger)
assert call(loops,'--check-actions').returncode==0
refused=call(loops,'action',question['id'],'waiting','--evidence','self-loop','--prerequisite',question['id'],'--recheck',iso(now+600))
assert refused.returncode==1 and 'distinct current unanswered question' in refused.stdout,refused
# Exercise the published row protocol's protected reviewed-green transition.
saved_ledger=ledger.read_text(); reviewed=json.loads(saved_ledger)
next(r for r in reviewed['rows'] if r['id']==p['id'])['category']='review_pass_not_merged'
ledger.write_text(json.dumps(reviewed))
refused=call(loops,'action',p['id'],'waiting','--evidence','must not park a reviewed green PR','--prerequisite',hold['id'],'--recheck',iso(now+600))
assert refused.returncode==1 and 'cannot have a standing dependency wait' in refused.stdout,refused
assert call(loops,'--check-actions').returncode==1
ledger.write_text(saved_ledger)
# Immediate source transitions invalidate the wait even before another collection or presentation.
for text in (held.replace('exact run recovery','different recovery'),held.replace(' (hold-kind: captain)',''),
             held.replace('- [ ] held-job','- [x] held-job').replace('## In flight','## Done')):
    backlog.write_text(text)
    assert call(loops,'--check-actions').returncode==1,'changed/released/answered hold must reopen followup'
    backlog.write_text(held)
status.write_text(original+f'resolved [at={now}] [key=ci-control]: answered elsewhere\n')
assert call(loops,'--check-actions').returncode==1,'an answered source key cannot retain its wait'
status.write_text(original)
backlog.unlink(); backlog.symlink_to(home/'missing-backlog')
assert call(loops,'--check-actions').returncode==1,'unreadable binding must not buy acknowledgement'
backlog.unlink(); backlog.write_text(held)
# A changed observed PR head or full evidence beyond the 400-character display bound reactivates the row.
forge['head']['sha']='b'*40; (home/'forge.json').write_text(json.dumps(forge)); publish()
assert call(loops,'--check-actions').returncode==1,'a new head must not inherit the old standing receipt'
forge['head']['sha']='a'*40; (home/'forge.json').write_text(json.dumps(forge)); publish()
status.write_text(original+f'blocked [at={now-7200}] [key=unrelated]: another same-task subject\n')
report=publish(); unrelated=row(report,'held-job:unrelated')
# Presenting an unrelated question must not inherit the task's other binding.
boundary=drain(); assert ack(boundary).returncode==1
assert unrelated['id'] in call(loops,'--check-actions').stdout
status.write_text(original); publish()
env['FM_OPEN_LOOPS_NOW']=str(now+600)
assert call(loops,'--check-actions').returncode==1,'concrete recheck must restore followup'
refused=call(loops,'action',question['id'],'waiting','--evidence','renew unchanged wait','--prerequisite',hold['id'],
             '--recheck',iso(now+1200))
assert refused.returncode==1 and 'cannot be renewed' in refused.stdout,refused
env['FM_OPEN_LOOPS_NOW']=str(now)
# A Main-owned dependency wait must prove a new, exact routed delivery to a distinct assigned worker.
# A pause alone is deliberately insufficient; the prerequisite must actually report working.
ledger.unlink(); backlog.write_text('## In flight\n\n## Queued\n\n## Done\n')
meta.write_text('kind=ship\nspawn_gen=s-held\n')
(home/'forge.json').write_text(json.dumps(dict(forge,html_url=pr)))
long_note='preserve original work; '+('evidence '*70)
status.write_text(f'blocked [at={now-7200}] [key=archive-prerequisite]: {long_note}A\npaused [at={now}]: awaiting custody-owner repair\n')
repair_tree=world/'wait-repair-tree'
ok('git','init','-q','-b','fm/repair-owner',repair_tree)
ok('git','-C',repair_tree,'commit','-q','--allow-empty','-m','fixture')
repair_head=ok('git','-C',repair_tree,'rev-parse','HEAD').stdout.strip()
repair_meta=f'kind=scout\nspawn_gen=s-repair\nworktree={repair_tree}\nharness=claude\nwindow=fm:fm-repair-owner\n'
repair=home/'state/repair-owner.meta'; repair.write_text(repair_meta)
ok(code/'bin/fm-busy-event.sh','arm',home/'state','repair-owner')
def repair_activity(state):
    ok(code/'bin/fm-busy-event.sh','apply',home/'state','repair-owner',state,
       '--current-gen','--source','claude-hook','--event','fixture')
repair_status=home/'state/repair-owner.status'; working=f'working [at={now}]: repairing the admitted custody prerequisite\n'
repair_status.write_text(working)
report=publish(); obligation=row(report,'held-job:archive-prerequisite')
boundary=drain()
inbox=home/'state/repair-owner.inbox'; inbox.mkdir()
message=inbox/'001.msg'
message.write_text('schema=fm-task-inbox.v1\nat='+iso(now)+'\n--\nUnrelated instruction without an obligation marker.\n')
refused=call(loops,'action',obligation['id'],'waiting','--evidence','001.msg','--prerequisite-task','repair-owner','--recheck',iso(now+600))
assert refused.returncode==1 and 'explicitly name open-loop-row' in refused.stdout,refused
message.write_text('schema=fm-task-inbox.v1\nat='+iso(now)+'\n--\nopen-loop-row: '+obligation['id']+'\nRepair only this routed prerequisite.\n')
blocked=f'blocked [at={now}] [key=credentials]: credentials missing\n'+working
repair_activity('idle')
for inactive in (f'paused [at={now}]: another subject is held\n', blocked, working):
    repair_status.write_text(inactive)
    refused=call(loops,'action',obligation['id'],'waiting','--evidence','001.msg',
                 '--prerequisite-task','repair-owner','--recheck',iso(now+600))
    assert refused.returncode==1,refused
    assert obligation['id'] not in json.loads(ledger.read_text())['handling']['actions']
repair_status.write_text(working)
repair_activity('busy')
action(obligation['id'],'waiting','001.msg','--prerequisite-task','repair-owner','--recheck',iso(now+600))
assert ack(boundary).returncode==0
boundary=drain(); assert ack(boundary).returncode==0
assert status.read_text().startswith('blocked') and row(json.loads(ledger.read_text()),obligation['subject'])['owner']=='firstmate'
for changed in (f'paused [at={now}]: waiting on somebody else\n',f'done [at={now}]: delivered repair\n',f'working [at={now}]: scope or evidence changed\n'):
    repair_status.write_text(changed)
    assert call(loops,'--check-actions').returncode==1,'changed prerequisite must reopen followup'
repair_status.write_text(working)
repair_activity('idle'); repair_status.write_text(blocked)
assert call(loops,'--check-actions').returncode==1,'an unresolved blocker survives unrelated working events'
repair_status.write_text(working); repair_activity('busy')
repair.write_text(repair_meta.replace('s-repair','s-replacement'))
assert call(loops,'--check-actions').returncode==1,'replacement worker cannot inherit the routed binding'
repair.write_text(repair_meta)
status.write_text(f'blocked [at={now-7200}] [key=archive-prerequisite]: {long_note}B\npaused [at={now}]: awaiting custody-owner repair\n')
assert call(loops,'--check-actions').returncode==1,'full evidence identity must survive display truncation'
# Pending original correlations remain actionable even with another valid wait in the same stream.
status.write_text(f'blocked [at={now-7200}] [key=pending-reply-0123456789abcdef]: pending-reply-missed: task=held-job pending-reply-id=0123456789abcdef request=original reply not received\n')
report=publish(); pending=row(report,'held-job:pending-reply-0123456789abcdef'); boundary=drain()
message.write_text('schema=fm-task-inbox.v1\nat='+iso(now)+'\n--\nopen-loop-row: '+pending['id']+'\n')
refused=call(loops,'action',pending['id'],'waiting','--evidence','001.msg','--prerequisite-task','repair-owner','--recheck',iso(now+600))
assert refused.returncode==1 and 'correlated replies' in refused.stdout,refused
assert ack(boundary).returncode==1 and 'original reply not received' in ok(loops,'--report').stdout

ledger.unlink(); status.write_text(original); repair_status.write_text(working)
repair.write_text(repair_meta.replace('kind=scout','kind=ship'))
run_file=home/'run.toon'
def run_state(state):
    run_file.write_text(f'run:\n  id: "01WAIT"\n  branch: fm/repair-owner\n  status: {state}\n'
                        f'  head: "{repair_head}"\n  pr: ""\n  findings: none\n')
report=publish(); obligation=row(report,'held-job:ci-control'); boundary=drain()
message.write_text('schema=fm-task-inbox.v1\nat='+iso(now)+'\n--\nopen-loop-row: '+obligation['id']+'\n')
run_state('awaiting_approval')
refused=call(loops,'action',obligation['id'],'waiting','--evidence','001.msg',
             '--prerequisite-task','repair-owner','--recheck',iso(now+600))
assert refused.returncode==1,refused
run_state('running')
action(obligation['id'],'waiting','001.msg','--prerequisite-task','repair-owner','--recheck',iso(now+600))
assert ack(boundary).returncode==0
boundary=drain()
run_state('awaiting_approval')
assert repair_status.read_text()==working
refused=ack(boundary)
assert refused.returncode==1 and obligation['id'] in refused.stdout,refused
assert obligation['id'] in ok(loops,'--present-overdue').stdout

gerrit='https://gerrit.example/c/test/project/+/140'
gerrit_meta=repair_meta.replace('kind=scout','kind=ship')+'mode=direct-PR\n'
forge_calls=home/'gerrit-requests.jsonl'
executable(fake/'gerrit-axi', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
home=Path(os.environ['FM_HOME'])
with (home/'gerrit-requests.jsonl').open('a') as log:
    log.write(json.dumps(sys.argv[1:])+'\\n')
assert sys.argv[1:]==['show','140','--host','gerrit.example','--json'],sys.argv
print((home/'gerrit.json').read_text())
''')
(home/'gerrit.json').write_text(json.dumps({'ok':True,'changes':[{'change':140,'revision':repair_head}]}))
for route in ('status-log','full-run','coarse-run'):
    ledger.unlink()
    repair.write_text(gerrit_meta)
    repair_activity('idle')
    if route=='status-log':
        run_file.unlink()
    else:
        run_state('running')
        if route=='coarse-run':
            run_file.write_text(run_file.read_text().replace('branch: fm/repair-owner','branch: fm/another'))
            (home/'runs.txt').write_text(f'  running  fm/repair-owner {repair_head}  2026-10-15 12:00\n')
    completed=f'done [at={now}]: PR {gerrit} published for review'+(
        '; checks green\n' if route!='status-log' else '\n')
    repair_status.write_text(completed)
    report=publish(); obligation=row(report,'held-job:ci-control'); boundary=drain()
    message.write_text('schema=fm-task-inbox.v1\nat='+iso(now)+'\n--\nopen-loop-row: '+obligation['id']+'\n')
    forge_calls.write_text('')
    env['FM_CREW_STATE_NO_FORGE']='1'
    state=ok(code/'bin/fm-crew-state.sh','repair-owner').stdout
    assert state.startswith('state: blocked '),(route,state)
    assert forge_calls.read_text()=='',(route,'local completion queried the forge')
    env.pop('FM_CREW_STATE_NO_FORGE')
    refused=call(loops,'action',obligation['id'],'waiting','--evidence','001.msg',
                 '--prerequisite-task','repair-owner','--recheck',iso(now+600))
    assert refused.returncode==1 and obligation['id'] not in json.loads(ledger.read_text())['handling']['actions'],(route,refused)
    assert forge_calls.read_text()=='',(route,'receipt admission queried the forge')
    state=ok(code/'bin/fm-crew-state.sh','repair-owner').stdout
    assert state.startswith('state: done '),(route,state)
    assert [json.loads(line) for line in forge_calls.read_text().splitlines()]==[
        ['show','140','--host','gerrit.example','--json']],route
    forge_calls.write_text('')
    repair.write_text(gerrit_meta+'pr='+gerrit+'\n')
    env['FM_CREW_STATE_NO_FORGE']='1'
    state=ok(code/'bin/fm-crew-state.sh','repair-owner').stdout
    assert state.startswith('state: done '),(route,state)
    assert forge_calls.read_text()=='',(route,'recorded completion queried the forge')
    env.pop('FM_CREW_STATE_NO_FORGE')
    repair.write_text(gerrit_meta)
    repair_status.write_text(working); repair_activity('busy')
    state=ok(code/'bin/fm-crew-state.sh','repair-owner').stdout
    expected_source='pane' if route=='status-log' else 'run-step'
    assert state.startswith(f'state: working · source: {expected_source} ·'),(route,state)
    action(obligation['id'],'waiting','001.msg','--prerequisite-task','repair-owner','--recheck',iso(now+600))
    assert ack(boundary).returncode==0,route
    boundary=drain(); assert ack(boundary).returncode==0,route
    boundary=drain()
    repair_status.write_text(completed); repair_activity('idle')
    queued=(home/'state/.wake-queue').read_bytes()
    refused=ack(boundary)
    assert refused.returncode==1 and obligation['id'] in refused.stdout,(route,refused)
    assert (home/'state/.wake-queue').read_bytes()==queued,route
    presented=ok(loops,'--present-overdue').stdout
    assert obligation['id'] in presented and 'STANDING' not in presented,(route,presented)
    assert forge_calls.read_text()=='',(route,'standing receipt revalidation queried the forge')
    current=row(json.loads(ledger.read_text()),obligation['subject'])
    assert current['owner']=='firstmate' and current['overdue'] and not current.get('informational'),current
    action(obligation['id'],'escalated','published prerequisite requires followup')
    assert ack(boundary).returncode==0,route
print('PASS: local-only Gerrit completion keeps unproved prerequisites actionable without forge reads across receipt paths and completion callers')

for producer, consumer in (('main','branch'),('branch','main')):
    for dependency in ('question','task'):
        for transition in ('changed','answered','due'):
            home=world/f'wait-{producer}-{dependency}-{transition}'
            for name in ('state','data','config','projects'):
                (home/name).mkdir(parents=True)
            env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(home),
                       FM_SUPERVISION_ACTOR=producer,FM_OPEN_LOOPS_NOW=str(now))
            ledger=home/'state/open-loops.json'
            (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
            (home/'state/held-job.meta').write_text('kind=ship\nspawn_gen=s-held\n')
            target_status=home/'state/held-job.status'
            target_text=f'blocked [at={now-7200}] [key=obligation]: original obligation\n'
            dependency_line=f'blocked [at={now-7200}] [key=dependency]: prerequisite answer needed\n'
            target_status.write_text(target_text+(dependency_line if dependency=='question' else ''))
            if dependency=='task':
                (home/'state/repair-owner.meta').write_text(repair_meta)
                (home/'state/repair-owner.status').write_text(working)
                ok(code/'bin/fm-busy-event.sh','arm',home/'state','repair-owner')
            report=publish(); obligation=row(report,'held-job:obligation')
            boundary=drain()
            if dependency=='question':
                prerequisite=row(report,'held-job:dependency')
                action(prerequisite['id'],'escalated','prerequisite question routed')
                options=('--prerequisite',prerequisite['id'])
                evidence='explicit prerequisite question'
            else:
                delivery=home/'state/repair-owner.inbox/001.msg'
                delivery.parent.mkdir()
                delivery.write_text('schema=fm-task-inbox.v1\nat='+iso(now)+
                                    '\n--\nopen-loop-row: '+obligation['id']+'\n')
                options=('--prerequisite-task','repair-owner')
                evidence='001.msg'
            action(obligation['id'],'waiting',evidence,*options,'--recheck',iso(now+600))
            assert ack(boundary).returncode==0
            if producer=='branch':
                ok(code/'bin/fm-wake-grant.sh','deactivate',os.getpid(),'wait-turn')
            env['FM_SUPERVISION_ACTOR']=consumer
            boundary=drain()
            if dependency=='question':
                action(prerequisite['id'],'escalated','prerequisite followup routed')
            assert call(loops,'--check-actions').returncode==0
            if transition=='due':
                env['FM_OPEN_LOOPS_NOW']=str(now+600)
            elif dependency=='question':
                event=(f'blocked [at={now}] [key=dependency]: changed prerequisite\n' if transition=='changed'
                       else f'resolved [at={now}] [key=dependency]: answered\n')
                target_status.write_text(target_text+dependency_line+event)
            else:
                event=(f'working [at={now}]: changed prerequisite scope\n' if transition=='changed'
                       else f'done [at={now}]: delivered prerequisite\n')
                (home/'state/repair-owner.status').write_text(event)
            queued=(home/'state/.wake-queue').read_bytes()
            refused=ack(boundary)
            assert refused.returncode==1 and obligation['id'] in refused.stdout,(producer,dependency,transition,refused)
            assert (home/'state/.wake-queue').read_bytes()==queued
            action(obligation['id'],'escalated','invalidated dependency followup routed')
            assert ack(boundary).returncode==0
            current=row(json.loads(ledger.read_text()),obligation['subject'])
            assert current['owner']=='firstmate' and current['overdue'] and not current.get('informational'),current
print('PASS: bound PR/status and Main-owned routed waits survive unchanged presentations; real obligations remain visible; changed, answered, released, unreadable, due and unanswered-reply boundaries reactivate followup')
PY
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
# A firstmate-owned row parked behind a live captain hold takes a standing escalation, like a captain-owned row.
import datetime as dt, json, os, re, shutil, subprocess, sys, time
from pathlib import Path
root, world = map(Path, sys.argv[1:])
code = world / 'park-code'
shutil.copytree(root / 'bin', code / 'bin')
now = int(time.time())
iso = lambda stamp: dt.datetime.fromtimestamp(stamp, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
loops = code / 'bin/fm-open-loops.sh'
HELD = ('## In flight\n- [ ] held-job - Recover the run (repo: firstmate) (kind: ship) '
        '(hold: exact run recovery) (hold-kind: captain)\n  Captain hold set: ' + iso(now - 7200) + '\n\n## Queued\n\n## Done\n')
RELEASED = HELD.replace(' (hold-kind: captain)', '')
ANSWERED = HELD.replace('- [ ] held-job', '- [x] held-job').replace('## In flight', '## Done')
DEFERRED = HELD.replace('(hold-kind: captain)', '(hold-kind: captain) (hold-until: 2999-01-01)')
BLOCKED = HELD.replace('(hold-kind: captain)', '(hold-kind: captain) (blocked-by: unfinished-prerequisite)')
REHELD = HELD.replace(iso(now - 7200), iso(now - 3600))
PR = 'https://github.com/test/project/pull/9'

def park(name, **fields):
    home = world / ('park-' + name)
    for directory in ('state', 'config', 'data', 'projects'):
        (home / directory).mkdir(parents=True)
    backlog = home / 'data/backlog.md'
    backlog.write_text(HELD)
    clock = dict(now=now)
    env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_SUPERVISION_ACTOR='main',
               FM_TEST_SEAM='1', FM_TEST_HARNESS='codex')
    for key in ('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
        env.pop(key, None)
    row = dict(id='row-' + name, category='unanswered_question', subject='held-job:ci-control', owner='firstmate',
               next_action='answer or close this question, or record why it no longer applies',
               age_seconds=7200, limit_seconds=1800, overdue=True, evidence='blocked: supported recovery control is missing',
               source=dict(kind='status', task='held-job', key='ci-control'))
    row.update(fields)
    ledger = home / 'state/open-loops.json'
    def publish(rows):
        ledger.write_text(json.dumps(dict(schema='fm-open-loops.v1', generated_epoch=now, complete=True,
                                          home=str(home.resolve()), rows=rows)))
    publish([row])
    def call(*args):
        run_env = dict(env, FM_OPEN_LOOPS_NOW=str(clock['now']))
        return subprocess.run([str(a) for a in args], env=run_env, text=True, capture_output=True, timeout=120)
    def ok(*args):
        result = call(*args)
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return result
    def wake(label):
        ok('bash', '-c', '. "$1"; fm_wake_append check report "check: $2"', '_', code / 'bin/fm-wake-lib.sh', label)
    def drain(label='turn'):
        wake(label)
        result = ok(code / 'bin/fm-wake-drain.sh')
        match = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', result.stderr)
        assert match, (result.stdout, result.stderr)
        return result, match.groups()
    def ack(boundary):
        return call(code / 'bin/fm-wake-drain.sh', '--ack-through', boundary[0], '--recovery-generation', boundary[1])
    def act(kind, evidence, *extra):
        return call(loops, 'action', row['id'], kind, '--evidence', evidence, *extra)
    def stored():
        return json.loads(ledger.read_text())
    return home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored

# (a) One escalation of the parked row stands: later drains neither present it nor refuse the acknowledgement.
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('stands')
result, boundary = drain('first')
assert result.stdout.startswith('OVERDUE:') and row['id'] in result.stdout, result
assert ack(boundary).returncode == 1, 'an unreceipted overdue row refuses acknowledgement'
recorded = act('escalated', 'asked the captain to decide the recovery')
assert recorded.returncode == 0 and 'standing: captain hold held-job' in recorded.stdout, recorded
assert stored()['handling']['actions'][row['id']]['hold']['task'] == 'held-job'
assert ack(boundary).returncode == 0
for label, later in (('same-day', 0), ('two-days', 2 * 86400)):
    clock['now'] = now + later
    result, boundary = drain(label)
    assert 'OVERDUE' not in result.stdout and row['id'] not in result.stdout, (label, result.stdout)
    assert ack(boundary).returncode == 0, (label, 'an unchanged parked row needs no second receipt')
assert row['id'] in ok(loops, '--report').stdout, 'a standing receipt never resolves the obligation'
assert call(loops, '--check-actions').returncode == 0
# With no queued wake the same standing row opens no handling episode and demands nothing.
(home / 'state/.wake-queue').write_text('')
idle = ok(code / 'bin/fm-wake-drain.sh')
assert 'OVERDUE' not in idle.stdout and 'WAKE_ACK_REQUIRED' not in idle.stderr, idle
# Beside new work it is listed under STANDING, after the row that needs an action.
record = stored()
record['rows'].append(dict(row, id='row-fresh', subject='other-worker', category='stalled_worker',
                           owner='worker:other-worker', source=None))
ledger.write_text(json.dumps(record))
mixed, boundary = drain('mixed')
assert 'row-fresh' in mixed.stdout and 'STANDING' in mixed.stdout, mixed
assert mixed.stdout.index('row-fresh') < mixed.stdout.index('STANDING') and mixed.stdout.count(row['id']) == 1, mixed
assert ack(boundary).returncode == 1, 'the fresh row still needs its own action'

# One receipt binds exactly one held task: the explicit --hold, else the first held of the row's key, its legacy
# <task>-decision-<key> task and its own task. Task ids written in the evidence never bind.
KEY, ORIGIN = 'd1-expired-preservation-ledger', 'vernant-d1-intake'
LEGACY = ORIGIN + '-decision-' + KEY
KEYED = dict(subject=ORIGIN + ':' + KEY, source=dict(kind='status', task=ORIGIN, key=KEY))
ENTRY = HELD.split('## In flight\n')[1].split('\n\n## Queued')[0]
def held(*tasks):
    return '## In flight\n' + '\n'.join(ENTRY.replace('held-job', task) for task in tasks) + '\n\n## Queued\n\n## Done\n'
def bound_to(label, tasks, expected):
    home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park(label, **KEYED)
    backlog.write_text(held(*tasks))
    _, boundary = drain()
    recorded = act('escalated', 'asked the captain')
    assert recorded.returncode == 0 and 'standing: captain hold ' + expected + ';' in recorded.stdout, (label, recorded)
    action = stored()['handling']['actions'][row['id']]
    assert action['hold']['task'] == expected and 'holds' not in action, (label, action)
    assert ack(boundary).returncode == 0
    result, boundary = drain(label + '-later')
    assert row['id'] not in result.stdout and ack(boundary).returncode == 0, (label, result.stdout)
    return home, backlog, row, drain, ack, stored
bound_to('key-named', [KEY], KEY)
bound_to('origin-task', [ORIGIN], ORIGIN)
bound_to('legacy-name', [LEGACY], LEGACY)
bound_to('order-legacy-first', [ORIGIN, LEGACY], LEGACY)
home, backlog, row, drain, ack, stored = bound_to('order-key-first', [ORIGIN, LEGACY, KEY], KEY)
backlog.write_text(held(KEY))
result, boundary = drain('other-candidates-ended')
assert row['id'] not in result.stdout and ack(boundary).returncode == 0, 'only the bound hold ends the receipt'
backlog.write_text(held(ORIGIN, LEGACY))
result, boundary = drain('bound-ended')
assert row['id'] in result.stdout and ack(boundary).returncode == 1, 'the bound hold ending re-presents the row'

home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('explicit', **KEYED)
backlog.write_text(held(KEY, ORIGIN, 'elsewhere'))
_, boundary = drain()
mentioned = act('escalated', 'tracked as elsewhere; captain notified.', '--hold', 'not-held')
assert mentioned.returncode == 1 and 'still held for the captain' in mentioned.stdout, mentioned
assert row['id'] not in stored()['handling']['actions'], 'a refused --hold records no receipt'
named = act('escalated', 'asked the captain', '--hold', ORIGIN)
assert named.returncode == 0 and 'standing: captain hold ' + ORIGIN + ';' in named.stdout, named
assert stored()['handling']['actions'][row['id']]['hold']['task'] == ORIGIN, 'an explicit --hold outranks the row key'
wrong_kind = act('deferred', 'still waiting', '--hold', ORIGIN, '--recheck', iso(now + 600))
assert wrong_kind.returncode == 1 and 'only valid for escalated' in wrong_kind.stdout, wrong_kind
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('evidence-only', **KEYED)
backlog.write_text(held('elsewhere'))
_, boundary = drain()
mentioned = act('escalated', 'tracked as elsewhere; captain notified.')
assert mentioned.returncode == 0, mentioned
assert 'hold' not in stored()['handling']['actions'][row['id']], 'free text in the evidence must not bind a hold'
assert ack(boundary).returncode == 0
result, boundary = drain('unbound-next-turn')
assert row['id'] not in result.stdout and ack(boundary).returncode == 0, 'unbound firstmate escalation has bounded standing'

# (b) A changed row, or a hold that is answered, released, blocked on an unresolved task, or re-held, restores the requirement.
def changed_row(record):
    record['rows'][0]['evidence'] = 'blocked: the captain asked for a revised plan'
    return record
transitions = (('digest', None), ('released', RELEASED), ('answered', ANSWERED), ('blocked', BLOCKED), ('reheld', REHELD))
for label, text in transitions:
    home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('change-' + label)
    _, boundary = drain()
    assert 'standing: captain hold held-job' in act('escalated', 'asked the captain').stdout
    assert ack(boundary).returncode == 0
    _, boundary = drain('quiet')
    assert ack(boundary).returncode == 0
    if text is None:
        ledger.write_text(json.dumps(changed_row(stored())))
    else:
        backlog.write_text(text)
    result, boundary = drain('after-' + label)
    assert row['id'] in result.stdout and result.stdout.startswith('OVERDUE:'), (label, result.stdout)
    assert 'STANDING' not in result.stdout, (label, result.stdout)
    refused = ack(boundary)
    assert refused.returncode == 1 and row['id'] in refused.stdout, (label, refused)
    renewed = act('escalated', 'asked the captain again')
    assert renewed.returncode == 0, (label, renewed)
    if text in (None, REHELD):
        # A changed row or a fresh hold lifecycle is bound again by the new escalation.
        assert 'standing: captain hold held-job' in renewed.stdout, renewed
    else:
        # A fresh escalation after following up is bounded, not still bound to the ended hold.
        assert 'hold' not in stored()['handling']['actions'][row['id']], label
    assert ack(boundary).returncode == 0
    if text not in (None, REHELD):
        result, boundary = drain('next-' + label)
        assert row['id'] not in result.stdout and ack(boundary).returncode == 0, label
        clock['now'] += 14400
        result, boundary = drain('expired-' + label)
        assert row['id'] in result.stdout and ack(boundary).returncode == 1, label
# A hold the captain defers to a date is still held for the captain: the receipt keeps standing until the hold ends.
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('dated')
_, boundary = drain()
assert 'standing: captain hold held-job' in act('escalated', 'asked the captain').stdout
assert ack(boundary).returncode == 0
backlog.write_text(DEFERRED)
for label in ('deferred', 'next-turn'):
    result, boundary = drain(label)
    assert row['id'] not in result.stdout and ack(boundary).returncode == 0, (label, result.stdout)
assert call(loops, '--check-actions').returncode == 0
assert row['id'] in ok(loops, '--report').stdout, 'a standing receipt never resolves the obligation'
backlog.write_text(RELEASED)
result, boundary = drain('released-after-dated')
assert row['id'] in result.stdout and ack(boundary).returncode == 1, 'a deferred hold that is then released needs a new action'
# An escalation recorded while the hold is already deferred to a date binds it as well.
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('dated-record')
backlog.write_text(DEFERRED)
_, boundary = drain()
recorded = act('escalated', 'asked the captain')
assert recorded.returncode == 0 and 'standing: captain hold held-job' in recorded.stdout, recorded
assert stored()['handling']['actions'][row['id']]['hold']['task'] == 'held-job'
assert ack(boundary).returncode == 0
result, boundary = drain('after-dated-record')
assert row['id'] not in result.stdout and ack(boundary).returncode == 0, result.stdout
# An unreadable backlog never buys standing acknowledgement.
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('unreadable')
_, boundary = drain()
assert 'standing: captain hold' in act('escalated', 'asked the captain').stdout
assert ack(boundary).returncode == 0
backlog.unlink(); backlog.symlink_to(home / 'missing-backlog')
result, boundary = drain('unreadable')
assert row['id'] in result.stdout and ack(boundary).returncode == 1, result

# Other categories cannot bind a captain hold; firstmate ownership still permits bounded standing.
for category, fields in (('red_check', dict(subject=PR, next_action='diagnose: code or test', limit_seconds=0)),
                         ('stalled_worker', dict(subject='held-job', owner='worker:held-job',
                                                 source=dict(kind='task', task='held-job')))):
    home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('cat-' + category,
                                                                                         category=category, **fields)
    _, boundary = drain()
    recorded = act('escalated', 'asked the captain about held-job')
    assert recorded.returncode == 0 and 'hold' not in stored()['handling']['actions'][row['id']], recorded
    assert ack(boundary).returncode == 0
    result, boundary = drain('again')
    if row['owner'] == 'firstmate':
        assert row['id'] not in result.stdout and ack(boundary).returncode == 0, (category, result.stdout)
        clock['now'] += 14400
        result, boundary = drain('bounded-receipt-expired')
    assert row['id'] in result.stdout and ack(boundary).returncode == 1, (category, result.stdout)
    refused = act('escalated', 'asked the captain', '--hold', 'held-job')
    assert refused.returncode == 1 and 'only a firstmate-owned' in refused.stdout, (category, refused)

# (c) A reviewed green PR has no standing receipt of any kind, however it is held.
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park(
    'review', category='review_pass_not_merged', subject=PR, next_action='merge with existing authority or escalate for approval',
    evidence='independent review PASS at live head', limit_seconds=600, source=dict(kind='pr', task='held-job'))
_, boundary = drain()
refused = act('escalated', 'asked the captain', '--hold', 'held-job')
assert refused.returncode == 1 and 'only a firstmate-owned' in refused.stdout, refused
recorded = act('escalated', 'asked the captain to approve held-job')
assert recorded.returncode == 0 and 'standing:' not in recorded.stdout, recorded
assert ack(boundary).returncode == 0
result, boundary = drain('again')
assert row['id'] in result.stdout and ack(boundary).returncode == 1, 'an escalation cannot silence a mergeable reviewed PR'
assert 'hold' not in stored()['handling']['actions'][row['id']]
# Even a forged binding on the stored receipt cannot make it stand.
record = stored()
record['handling']['actions'][row['id']]['hold'] = dict(task='held-job', marker=iso(now - 7200))
ledger.write_text(json.dumps(record))
result, boundary = drain('forged')
assert row['id'] in result.stdout and ack(boundary).returncode == 1, result

# (d) The first deferral still stands to its recheck, the second is refused and captain-visible, and escalation clears it.
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('deferral')
_, boundary = drain()
recheck = iso(now + 600)
deferred = act('deferred', 'waiting on a verification run', '--recheck', recheck)
assert deferred.returncode == 0 and 'standing:' not in deferred.stdout, deferred
assert ack(boundary).returncode == 0
result, boundary = drain('during-deferral')
assert row['id'] not in result.stdout and ack(boundary).returncode == 0, 'a first deferral stands until its recheck'
clock['now'] = now + 700
result, boundary = drain('after-recheck')
assert row['id'] in result.stdout and ack(boundary).returncode == 1, 'a lapsed deferral needs a new action'
second = act('deferred', 'still waiting', '--recheck', iso(now + 1300))
assert second.returncode == 1 and 'second deferral refused' in second.stdout, second
assert stored()['handling']['actions'][row['id']]['captain_visible'] is True
assert [r for r in stored()['rows'] if r['id'] == row['id']][0]['captain_visible'] is True
assert call(loops, '--check-actions').returncode == 1
escalated = act('escalated', 'asked the captain to decide')
assert escalated.returncode == 0 and 'standing: captain hold held-job' in escalated.stdout, escalated
assert ack(boundary).returncode == 0
result, boundary = drain('settled')
assert row['id'] not in result.stdout and ack(boundary).returncode == 0
# (e) Hold standing reads only the local backlog and the row, so a quota-stale ledger neither voids it nor blocks recording it.
def go_stale(ledger):
    record = json.loads(ledger.read_text())
    record.update(stale=True, stale_reason='quota low (500 of 5000); resets in an hour', complete=False)
    for each in record['rows']:
        each['stale'] = True
    ledger.write_text(json.dumps(record))

home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('stale-stands')
_, boundary = drain()
assert 'standing: captain hold held-job' in act('escalated', 'asked the captain').stdout
assert ack(boundary).returncode == 0
go_stale(ledger)
result, boundary = drain('stale')
assert row['id'] not in result.stdout and ack(boundary).returncode == 0, ('a live hold stands on a stale ledger', result)
assert call(loops, '--check-actions').returncode == 0
backlog.write_text(ANSWERED)
result, boundary = drain('stale-answered')
assert row['id'] in result.stdout and result.stdout.startswith('OVERDUE:'), result
assert ack(boundary).returncode == 1, 'a hold that ended is presented again on a stale ledger'
for label, hold_args in (('explicit', ('--hold', 'held-job')), ('automatic', ())):
    home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('stale-record-' + label)
    _, boundary = drain()
    go_stale(ledger)
    recorded = act('escalated', 'asked the captain', *hold_args)
    assert recorded.returncode == 0 and 'standing: captain hold held-job' in recorded.stdout, (label, recorded)
    assert stored()['handling']['actions'][row['id']]['hold']['task'] == 'held-job', label
    assert ack(boundary).returncode == 0
    result, boundary = drain('stale-after')
    assert row['id'] not in result.stdout and ack(boundary).returncode == 0, (label, result.stdout)
    renewed = act('escalated', 'asked the captain again', *hold_args)
    assert renewed.returncode == 0 and 'standing: captain hold held-job' in renewed.stdout, (label, renewed)
    assert stored()['handling']['actions'][row['id']]['hold']['task'] == 'held-job', label

# An unreadable backlog is reported as an unverifiable hold, never as a hold that nobody named.
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('unverified')
_, boundary = drain()
backlog.unlink(); backlog.symlink_to(home / 'missing-backlog')
recorded = act('escalated', 'asked the captain')
assert recorded.returncode == 0, recorded
assert 'hold' not in stored()['handling']['actions'][row['id']]
refused = act('escalated', 'asked the captain', '--hold', 'held-job')
assert refused.returncode == 1, refused
assert ack(boundary).returncode == 0
result, boundary = drain('unverified-after')
assert row['id'] not in result.stdout and ack(boundary).returncode == 0, 'an unbound firstmate receipt has bounded standing'
clock['now'] += 14400
result, boundary = drain('unverified-expired')
assert row['id'] in result.stdout and ack(boundary).returncode == 1, 'unverified holds never buy indefinite standing'

# (f) Only a row owned by firstmate can be parked: a reviewer-owned open_pr stays presented under a live captain hold.
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('marker')
_, boundary = drain()
assert 'standing: captain hold held-job' in act('escalated', 'asked the captain').stdout
marker = stored()['handling']['actions'][row['id']]['hold']['marker']
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park(
    'reviewer', category='open_pr', subject=PR, owner='alice', next_action='complete the requested PR review',
    evidence='', limit_seconds=600, source=dict(kind='pr', task='held-job'))
_, boundary = drain()
recorded = act('escalated', 'asked the captain about held-job')
assert recorded.returncode == 0 and 'standing:' not in recorded.stdout, recorded
assert ack(boundary).returncode == 0
result, boundary = drain('again')
assert row['id'] in result.stdout and ack(boundary).returncode == 1, 'a reviewer-owned row must keep being presented'
refused = act('escalated', 'asked the captain', '--hold', 'held-job')
assert refused.returncode == 1 and 'only a firstmate-owned' in refused.stdout, refused
# Even a receipt carrying a live, matching hold binding cannot make a reviewer-owned row stand.
record = stored()
assert 'hold' not in record['handling']['actions'][row['id']]
record['handling']['actions'][row['id']]['hold'] = dict(task='held-job', marker=marker)
ledger.write_text(json.dumps(record))
result, boundary = drain('forged')
assert row['id'] in result.stdout and ack(boundary).returncode == 1, result
# (g) One presentation reads the backlog at most once, however many standing rows depend on it, and a failed read fails closed.
shutil.copy2(code / 'bin/fm-fleet-snapshot.sh', code / 'bin/real-fleet-snapshot.sh')
counting = code / 'bin/fm-fleet-snapshot.sh'
counting.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$FM_HOME/snapshot-runs"\n'
                    'exec "$(dirname "$0")/real-fleet-snapshot.sh" "$@"\n')
counting.chmod(0o755)
home, backlog, row, ledger, clock, publish, call, ok, drain, ack, act, stored = park('read-once')
standing = [row] + [dict(row, id=f'row-read-once-{n}', subject=f'held-job:ci-control-{n}',
                         source=dict(kind='status', task='held-job', key=f'ci-control-{n}')) for n in (2, 3)]
publish(standing)
runs = home / 'snapshot-runs'
snapshot_runs = lambda: len(runs.read_text().splitlines()) if runs.exists() else 0
_, boundary = drain()
for each in standing:
    recorded = call(loops, 'action', each['id'], 'escalated', '--evidence', 'asked the captain')
    assert recorded.returncode == 0 and 'standing: captain hold held-job' in recorded.stdout, recorded
assert ack(boundary).returncode == 0
runs.unlink(missing_ok=True)
healthy = ok(loops, '--present-overdue')
assert not any(each['id'] in healthy.stdout for each in standing) and snapshot_runs() == 1, (healthy, snapshot_runs())
runs.unlink()
backlog.unlink(); backlog.symlink_to(home / 'missing-backlog')
broken = ok(loops, '--present-overdue')
assert all(each['id'] in broken.stdout for each in standing) and 'STANDING' not in broken.stdout, broken
assert snapshot_runs() == 1, ('an unreadable backlog was read again for each standing row', snapshot_runs())
print('PASS: a firstmate-owned row parked behind a live captain hold takes one standing escalation, also on a quota-stale ledger;'
      ' a changed row or an answered, released, blocked or re-held hold re-presents it while a hold deferred to a date keeps it standing; evidence text, other owners, reviewed'
      ' PRs, other categories and the deferral limit never bind or stand; one presentation reads the backlog once, failed or not')
PY
# Batched receipts and read-stable, bounded handling through the real CLI.
python3 - "$ROOT" <<'PY'
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1]).resolve()
world = Path(tempfile.mkdtemp(prefix='ledger-receipts-'))
code = world / 'code'
shutil.copytree(root / 'bin', code / 'bin')
# Count the actual local snapshot reader, not a fabricated snapshot.
shutil.copy2(code / 'bin/fm-fleet-snapshot.sh', code / 'bin/real-fleet-snapshot.sh')
snapshot = code / 'bin/fm-fleet-snapshot.sh'
snapshot.write_text('#!/usr/bin/env bash\nprintf "snapshot\\n" >> "$FM_HOME/snapshot-runs"\nexec "$(dirname "$0")/real-fleet-snapshot.sh" "$@"\n')
snapshot.chmod(0o755)
now = int(time.time())
clock = now
home = world / 'home'
for directory in ('state', 'config', 'data', 'projects'):
    (home / directory).mkdir(parents=True)
(home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
rows = [dict(id=f'row-{i}', category='unanswered_question', subject=f'job:question-{i}',
             owner='firstmate', next_action='obtain decision', evidence='decision pending',
             age_seconds=7200, limit_seconds=1800, overdue=True) for i in range(50)]
ledger = home / 'state/open-loops.json'
loops = code / 'bin/fm-open-loops.sh'
drain_cli = code / 'bin/fm-wake-drain.sh'
def publish(items):
    ledger.write_text(json.dumps(dict(schema='fm-open-loops.v1', generated_epoch=now,
                                     home=str(home), complete=True, rows=items)))
def call(binary, *args, good=True, input_text=None):
    env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home),
               FM_OPEN_LOOPS_NOW=str(clock), FM_TEST_SEAM='1', FM_TEST_HARNESS='codex',
               FM_SUPERVISION_ACTOR='main', FM_DURATION_FILE='off')
    for key in ('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
        env.pop(key, None)
    result = subprocess.run([str(binary), *map(str,args)], env=env, text=True, capture_output=True, input=input_text)
    if good:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result

def drain():
    result = call(drain_cli)
    match = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', result.stderr)
    assert match, result
    return result, match.groups()
def ack(boundary, good=True):
    return call(drain_cli, '--ack-through', boundary[0], '--recovery-generation', boundary[1], good=good)
def act(ident, kind='escalated', evidence='reported decision'):
    return call(loops, 'action', ident, kind, '--evidence', evidence)
def stored():
    return json.loads(ledger.read_text())
def batch(items):
    path = home / 'actions.jsonl'
    path.write_text(''.join(json.dumps(item) + '\n' for item in items))
    return call(loops, 'action', '--batch', path, good=False)

try:
    publish(rows)
    _, boundary = drain()
    # Each failed batch row reports its own result without rolling back valid actions.
    runs = home / 'snapshot-runs'
    runs.unlink(missing_ok=True)
    result = batch([dict(row_id=row['id'], kind='escalated', evidence='reported decision') for row in rows]
                   + [dict(row_id='absent', kind='escalated', evidence='not a row'),
                      dict(row_id='row-0', kind='unknown', evidence='invalid kind')])
    assert result.returncode == 1, result
    assert len(runs.read_text().splitlines()) == 1, 'a 50-row batch must read one snapshot'
    assert len(stored()['handling']['actions']) == 50, result
    assert 'absent' in result.stdout and 'unknown' in result.stdout, result
    assert len(result.stdout.splitlines()) == 53, result.stdout
    call(loops, '--check-actions')
    ack(boundary)
    print('PASS: batch validates per row, preserves valid actions and uses one real snapshot', flush=True)

    # Reads and a refused ack cannot throw away another row's completed work.
    publish([dict(rows[0], owner='worker:job'), rows[1]])
    _, boundary = drain()
    act('row-0')
    prior = stored()['handling']['presented_at']['main']['row-0']
    clock += 1
    drain()
    assert ack(boundary, good=False).returncode == 1
    assert stored()['handling']['presented_at']['main']['row-0'] == prior
    act('row-1')
    call(loops, '--check-actions')
    ack(boundary)
    print('PASS: drain and refused acknowledgement preserve unchanged recorded work', flush=True)

    # Malformed stdin rows do not prevent a later valid action from being recorded.
    publish([rows[0]])
    _, boundary = drain()
    result = call(loops, 'action', '--batch', '-', good=False,
                  input_text='not-json\n' + json.dumps(dict(row_id='row-0', kind='escalated', evidence='followed up')) + '\n')
    assert result.returncode == 1 and len(result.stdout.splitlines()) == 3, result
    assert stored()['handling']['actions']['row-0']['kind'] == 'escalated'
    ack(boundary)

    # A partial acknowledgement must not restart action requirements for the remaining queue.
    publish([dict(rows[0], owner='worker:job')])
    for label in ('first', 'second'):
        call('bash', '-c', '. "$1"; fm_wake_append check "$2" "check: $2"', '_', code / 'bin/fm-wake-lib.sh', label)
    _, boundary = drain()
    act('row-0')
    ack((str(int(boundary[0]) - 1), boundary[1]))
    drain()
    call(loops, '--check-actions')
    ack(boundary)
    print('PASS: stdin batch recovery and partial acknowledgements preserve completed actions', flush=True)

    # All five identity fields invalidate a receipt even before another presentation.
    for field in ('category', 'subject', 'owner', 'next_action', 'evidence'):
        publish([rows[0]])
        _, boundary = drain()
        act('row-0')
        record = stored()
        record['rows'][0][field] += '-changed'
        ledger.write_text(json.dumps(record))
        assert call(loops, '--check-actions', good=False).returncode == 1, field
        assert ack(boundary, good=False).returncode == 1, field
    print('PASS: every obligation identity change requires new evidence', flush=True)

    # Firstmate escalations and steers stand across turns, not just across reads.
    for kind in ('escalated', 'steered'):
        publish([rows[0]])
        _, boundary = drain()
        if kind == 'steered':
            delivery = home / 'state/job.inbox/001.msg'
            delivery.parent.mkdir(exist_ok=True)
            delivery.write_text(f'schema=fm-task-inbox.v1\nat={dt.datetime.fromtimestamp(clock, dt.timezone.utc).isoformat()}\n--\nfollow up\n')
        act('row-0', kind, '001.msg' if kind == 'steered' else 'reported decision')
        ack(boundary)
        receipt_time = clock
        clock += 14399
        result = call(drain_cli)
        assert 'row-0' not in result.stdout and 'WAKE_ACK_REQUIRED' not in result.stderr, result
        clock = receipt_time + 14400
        _, boundary = drain()
        assert ack(boundary, good=False).returncode == 1, kind
        act('row-0')
        ack(boundary)
    print('PASS: firstmate escalation and steer stand for four hours, then require action', flush=True)

    # An action recorded since the current presentation answers it however long the handling turn lasts.
    publish([rows[0]])
    _, boundary = drain()
    act('row-0')
    clock += 5 * 3600
    call(loops, '--check-actions')
    ack(boundary)
    print('PASS: a recorded action answers its own turn at any age', flush=True)

    # A heartbeat that changes only a stalled worker's elapsed-time counters changes no obligation.
    stalled = dict(rows[0], category='stalled_worker', subject='job', owner='worker:job',
                   next_action='follow up on the recorded wait and recover the worker')
    def heartbeat(seconds, wait='lint still producing output'):
        record = stored()
        record['rows'][0]['evidence'] = (f'{wait}; {seconds}s without progress; step age {seconds}s;'
                                         f' declaration age {seconds}s')
        ledger.write_text(json.dumps(record))
    recheck_at = lambda seconds: dt.datetime.fromtimestamp(clock + seconds, dt.timezone.utc).isoformat()
    for kind in ('escalated', 'steered', 'deferred'):
        publish([stalled])
        heartbeat(3600)
        _, boundary = drain()
        if kind == 'steered':
            delivery = home / 'state/job.inbox/001.msg'
            delivery.parent.mkdir(exist_ok=True)
            delivery.write_text(f'schema=fm-task-inbox.v1\nat={dt.datetime.fromtimestamp(clock, dt.timezone.utc).isoformat()}\n--\nfollow up\n')
        if kind == 'deferred':
            call(loops, 'action', 'row-0', 'deferred', '--evidence', 'lint still producing output',
                 '--recheck', recheck_at(3600))
        else:
            act('row-0', kind, '001.msg' if kind == 'steered' else 'reported decision')
        clock += 600
        heartbeat(4200)
        call(loops, '--check-actions')
        if kind == 'escalated':
            heartbeat(4200, wait='lint failed: 3 errors')
            assert call(loops, '--check-actions', good=False).returncode == 1, 'a changed wait is a changed obligation'
            heartbeat(4200)
            call(loops, '--check-actions')
        ack(boundary)
        if kind == 'deferred':
            clock += 600
            heartbeat(4800)
            result = call(drain_cli)
            assert 'row-0' not in result.stdout and 'WAKE_ACK_REQUIRED' not in result.stderr, result
            call(loops, '--check-actions')
            heartbeat(4800, wait='lint failed: 3 errors')
            result, boundary = drain()
            assert 'row-0' in result.stdout and ack(boundary, good=False).returncode == 1
    print('PASS: elapsed-time counters never void a deferral, steer or escalation; real evidence changes do', flush=True)

    # A malformed or unsupported config file never blocks a presentation, a check or an acknowledgement.
    for text in ('{"age_limits_seconds": {', json.dumps(dict(receipt_interval_seconds=120))):
        (home / 'config/open-loops.json').write_text(text)
        publish([rows[0]])
        presented = call(loops, '--present-overdue')
        assert 'row-0' in presented.stdout, presented
        result, boundary = drain()
        assert 'row-0' in result.stdout and 'error' not in result.stderr, result
        assert call(loops, '--check-actions', good=False).returncode == 1
        act('row-0')
        call(loops, '--check-actions')
        call(loops, '--report')
        ack(boundary)
    (home / 'config/open-loops.json').unlink()
    print('PASS: an unreadable config file never blocks the receipt gate', flush=True)

    # The repeated-deferral refusal cannot be covered by an earlier standing escalation.
    publish([rows[0]])
    _, boundary = drain()
    recheck = dt.datetime.fromtimestamp(clock + 60, dt.timezone.utc).isoformat()
    call(loops, 'action', 'row-0', 'deferred', '--evidence', 'short wait', '--recheck', recheck)
    ack(boundary)
    act('row-0')
    refused = call(loops, 'action', 'row-0', 'deferred', '--evidence', 'another wait',
                   '--recheck', recheck, good=False)
    assert refused.returncode == 1
    assert call(loops, '--check-actions', good=False).returncode == 1
    assert ack(boundary, good=False).returncode == 1
    act('row-0')
    call(loops, '--check-actions')
    print('PASS: second deferral requires new follow-up even after a standing escalation', flush=True)

    publish([dict(rows[0], category='review_pass_not_merged')])
    _, boundary = drain()
    act('row-0')
    # A repeated read within this turn still preserves the action.
    drain()
    call(loops, '--check-actions')
    ack(boundary)
    _, boundary = drain()
    assert ack(boundary, good=False).returncode == 1
    print('PASS: reviewed PRs keep their next-turn action requirement', flush=True)
finally:
    shutil.rmtree(world)
PY
echo "ok - open-work reconciliation reports owned obligations from live records"
