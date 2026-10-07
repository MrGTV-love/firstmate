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
    dict(id='shipped', structured=True, state='done', kind='ship', completion=dict(verb='merged'), pr_url=PR_URL + '1'),
    dict(id='no-proof', structured=True, state='done', kind='ship', since=iso(hours(3))),
    dict(id='reported', structured=True, state='done', kind='scout', report_path='data/reported/report.md'),
    dict(id='dropped-ok', structured=True, state='done', kind='ship', captain_drop=True),
    dict(id='dropped-lost-words', structured=True, state='done', kind='ship', captain_drop=True),
]
(home / 'data/dropped-ok').mkdir()
(home / 'data/dropped-ok/captain-drop.md').write_text('Drop it; the premise is gone.\n')
(home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=tasks,
                                                    backlog=dict(present=True, records=backlog))))
# Questions: an old keyed one, a quoted-time one (no real stamp), and a closed one.
(home / 'state/asker.status').write_text(
    f'needs-decision [at={hours(10)}] [key=engine]: production engine upgrade question\n'
    f'needs-decision [key=approval]: diagnostic mentioned [at={now}]\n'
    f'needs-decision [at={hours(8)}] [key=closed]: asked and answered\n'
    f'resolved [at={hours(7)}] [key=closed]: answered\n')
double = dict(
    pulls=[dict(number=7, html_url=PR_URL + '7', head=dict(sha='a' * 40), draft=False, updated_at=iso(hours(3))),
           dict(number=8, html_url=PR_URL + '8', head=dict(sha='b' * 40), draft=False, updated_at=iso(hours(2)),
                requested_reviewers=[dict(login='reviewer')]),
           dict(number=9, html_url=PR_URL + '9', head=dict(sha='c' * 40), draft=False, updated_at=iso(hours(1)))],
    checks={'a' * 40: [dict(id=1, name='unit', app=dict(id=3), status='completed', conclusion='failure',
                           completed_at=iso(hours(4)))],
            'b' * 40: [dict(id=1, name='unit', app=dict(id=3), status='completed', conclusion='failure',
                           completed_at=iso(hours(4))),
                       dict(id=2, name='unit', app=dict(id=3), status='completed', conclusion='success',
                           completed_at=iso(hours(3)))],
            'c' * 40: [dict(id=4, name='unit', app=dict(id=3), status='completed', conclusion='success')]},
    single={'5': dict(merged_at=iso(hours(1))), '7': dict(merged_at=None)})
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
# Backlog: only dependency-cleared, unheld work is ready; Done needs a landed deliverable or the drop words.
assert set(cat('ready_not_started')) == {'ready'}, cat('ready_not_started')
assert set(cat('completion_unproved')) == {'no-proof', 'dropped-lost-words'}, cat('completion_unproved')
# Commits: only work with neither a landed PR nor an open PR is unlanded.
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
print('PASS: owned-work categories, owners, ages, degraded row, and atomic publication')
PY

# The real snapshot's home-input contract: large inventories travel by file, secondmates are
# excluded, and a captain drop is read back from the stored completion note.
SNAP_HOME=$TMP_ROOT/snapshot-home
mkdir -p "$SNAP_HOME/state" "$SNAP_HOME/data" "$SNAP_HOME/config" "$SNAP_HOME/projects"
{
  printf '## In flight\n- [ ] mate-lane - Domain lane (repo: firstmate) (kind: secondmate) (since 2026-07-11)\n\n## Queued\n'
  for i in $(seq 1 2500); do
    printf -- '- [ ] bulk-%s - A queued item with enough text to make this inventory larger than a single argument (repo: firstmate) (kind: ship) (since 2026-07-11)\n' "$i"
  done
  printf '\n## Done\n- [x] dropped-one - Dropped (repo: firstmate) (kind: ship) (done 2026-07-12)\n  dropped\n'
  printf -- '- [x] landed-one - Landed https://github.com/test/project/pull/3 (repo: firstmate) (kind: ship) (merged 2026-07-12)\n'
} > "$SNAP_HOME/data/backlog.md"
fm_write_meta "$SNAP_HOME/state/mate-lane.meta" "kind=secondmate" "window=firstmate:fm-mate-lane" "mode=secondmate"
fm_write_meta "$SNAP_HOME/state/worker.meta" "kind=ship" "window=firstmate:fm-worker" "project=$SNAP_HOME" "mode=no-mistakes"
INPUT=$(FM_HOME="$SNAP_HOME" bash "$ROOT/bin/fm-fleet-snapshot.sh" --home-input)
printf '%s' "$INPUT" | jq -e '.schema == "fm-fleet-home-input.v1" and (.backlog.records | length) > 2500
  and (.tasks | map(.id) == ["worker"])
  and (.backlog.records[] | select(.id == "dropped-one") | .captain_drop == true)
  and (.backlog.records[] | select(.id == "landed-one") | .captain_drop == false)' >/dev/null \
  || { echo "FAIL: home-input contract" >&2; exit 1; }
echo "PASS: home-input carries a large inventory, skips secondmates, and marks a captain drop"
echo "ok - open-work reconciliation reports owned obligations from live records"
