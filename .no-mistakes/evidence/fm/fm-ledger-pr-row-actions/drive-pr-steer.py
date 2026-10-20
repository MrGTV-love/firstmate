#!/usr/bin/env python3
"""Live driver: record a steer on a worker's overdue PR row through the real ledger CLI.

Usage: drive-pr-steer.py LABEL BIN_DIR
Builds a disposable home (own origin repo, task copies, GitHub double on PATH), runs the
real collector (bin/fm-open-loops.sh --heartbeat), the real wake drain/ack gate, the real
steering-inbox writer (bin/fm-task-inbox-lib.sh) and the real `action` command from BIN_DIR.
Only the fleet snapshot input and the forge HTTP layer are doubled (same seams the test suite uses).
"""
import datetime as dt, json, os, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path

label, bin_dir = sys.argv[1], Path(sys.argv[2])
here = Path(__file__).resolve().parent
world = Path(tempfile.mkdtemp(prefix='fm-pr-steer-live.'))
code, home, fake = world / 'code', world / 'home', world / 'fakebin'
shutil.copytree(bin_dir, code / 'bin')
for name in ('state', 'data', 'config', 'projects'):
    (home / name).mkdir(parents=True)
fake.mkdir()
shutil.copy(here / 'fake-gh', fake / 'gh')
(fake / 'gh').chmod(0o755)
now = int(time.time())
hours = lambda n: now - n * 3600
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), NM_HOME=str(world / 'nm'),
           FM_SUPERVISION_ACTOR='main', FM_TEST_SEAM='1', FM_TEST_HARNESS='codex',
           PATH=f'{fake}:{os.environ["PATH"]}', GH_DOUBLE=str(world / 'gh.json'),
           GH_REQUESTS=str(world / 'gh-requests'),
           GIT_AUTHOR_NAME='live', GIT_AUTHOR_EMAIL='live@example.invalid',
           GIT_COMMITTER_NAME='live', GIT_COMMITTER_EMAIL='live@example.invalid')
for key in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE',
            'FM_OPEN_LOOPS_NOW', 'NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS'):
    env.pop(key, None)

results = []
def say(text=''):
    print(text, flush=True)
def check(name, condition, detail=''):
    results.append((name, bool(condition)))
    say(f"  [{'PASS' if condition else 'FAIL'}] {name}" + (f"  -- {detail}" if detail and not condition else ''))
def run(args, **kw):
    return subprocess.run([str(a) for a in args], env=kw.pop('env', env), text=True, capture_output=True, timeout=120, **kw)
def out(args, **kw):
    done = run(args, **kw)
    assert done.returncode == 0, (args, done.stderr, done.stdout)
    return done.stdout.strip()
def script(path, text):
    path.write_text(text)
    path.chmod(0o755)
def one_line(done):
    return (done.stdout + done.stderr).strip().replace('\n', ' | ')[:230]

# Disposable git world: origin with one baseline, the project clone and one copy per ship.
origin = world / 'origin.git'
out(['git', 'init', '-q', '--bare', origin])
out(['git', '-C', origin, 'symbolic-ref', 'HEAD', 'refs/heads/main'])
seed = world / 'seed'
out(['git', 'init', '-q', '-b', 'main', seed])
(seed / 'base').write_text('base\n')
out(['git', '-C', seed, 'add', 'base'])
out(['git', '-C', seed, 'commit', '-q', '-m', 'baseline'])
out(['git', '-C', seed, 'remote', 'add', 'origin', 'https://github.com/test/project.git'])
env['GIT_CONFIG_COUNT'] = '1'
env['GIT_CONFIG_KEY_0'] = f'url.{origin}.insteadOf'
env['GIT_CONFIG_VALUE_0'] = 'https://github.com/test/project.git'
out(['git', '-C', seed, 'push', '-q', 'origin', 'main'])
shutil.copytree(seed, home / 'projects/project')

def task_copy(name):
    path = world / name
    out(['git', 'clone', '-q', origin, path])
    out(['git', '-C', path, 'checkout', '-q', '-b', 'fm/' + name])
    reflog = Path(out(['git', '-C', path, 'rev-parse', '--absolute-git-dir'])) / 'logs/HEAD'
    os.utime(reflog, (now, now))
    return path

PR_URL = 'https://github.com/test/project/pull/'
SHIPS = {'fm-prune-copy-on-merge': 175, 'fm-second-ship': 176, 'fm-third-ship': 181}
tasks = []
for ship, number in SHIPS.items():
    path = task_copy(ship)
    tasks.append(dict(id=ship, kind='ship', project=str(home / 'projects/project'), branch='fm/' + ship,
                      backend='tmux', current_state=dict(state='working', source='pane'),
                      endpoint=dict(exists=True, agent_alive='alive', target=ship),
                      pr=dict(url=PR_URL + str(number)), paths=dict(worktree=dict(path=str(path))), hints={}))
    (home / f'state/{ship}.status').write_text(f'working [at={now}]: building\n')
# A question row on the first ship, to confirm the long-standing subject-prefix path still works.
(home / 'state/fm-prune-copy-on-merge.status').write_text(
    f'working [at={now}]: building\nneeds-decision [at={hours(10)}] [key=engine]: which engine?\n')
script(code / 'bin/fm-peek.sh', '#!/usr/bin/env bash\nprintf "ok\\n"\n')
script(code / 'bin/fm-fleet-snapshot.sh', '#!/usr/bin/env bash\n[ "$1" = --home-input ] || exit 2\ncat "$FM_HOME/snapshot.json"\n')
(home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=tasks,
                                                    backlog=dict(present=True, records=[]))))
heads = {n: chr(ord('a') + i) * 40 for i, n in enumerate(SHIPS.values())}
double = dict(pulls=[dict(number=n, html_url=PR_URL + str(n), head=dict(sha=heads[n]), draft=False,
                          updated_at=iso(hours(6))) for n in SHIPS.values()],
              checks={heads[n]: [dict(id=i, name='unit', app=dict(id=3), status='completed', conclusion='success')]
                      for i, n in enumerate(SHIPS.values(), 1)},
              single={})
(world / 'gh.json').write_text(json.dumps(double))

def cli(*args):
    return run([code / 'bin/fm-open-loops.sh', *args])
def wake_append(text):
    return out(['bash', '-c', '. "$1"; fm_wake_append check report "$2"', '_', code / 'bin/fm-wake-lib.sh', text])
def drain():
    done = run([code / 'bin/fm-wake-drain.sh'])
    match = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', done.stderr)
    assert match, (done.stdout, done.stderr)
    return done, match.groups()
def ack(boundary):
    return run([code / 'bin/fm-wake-drain.sh', '--ack-through', boundary[0], '--recovery-generation', boundary[1]])
def deliver(task, text='please rebase and report'):
    """Real steering-inbox writer: returns the record file name (NNN.msg)."""
    path = out(['bash', '-c', '. "$1"; fm_task_inbox_write "$2" "$3" "$4"', '_',
                code / 'bin/fm-task-inbox-lib.sh', home / 'state', task, text])
    return Path(path).name
def ledger_rows():
    return {r['subject']: r for r in json.loads((home / 'state/open-loops.json').read_text())['rows']}

say(f'===== {label}: {bin_dir} =====')
say('-- collector: real heartbeat builds the PR rows')
hb = cli('--heartbeat')
check('heartbeat publishes the ledger', hb.returncode == 0 and (home / 'state/open-loops.json').exists(), one_line(hb))
rows = ledger_rows()
pr_rows = {n: rows[PR_URL + str(n)] for n in SHIPS.values()}
q_row = rows['fm-prune-copy-on-merge:engine']
for n, row in pr_rows.items():
    say(f"  PR row {n}: id={row['id']} category={row['category']} owner={row['owner']} overdue={row['overdue']} "
        f"source.task={row.get('source', {}).get('task')} next_action={row['next_action']!r}")
say(f"  question row: id={q_row['id']} category={q_row['category']} owner={q_row['owner']} overdue={q_row['overdue']} "
    f"source.task={q_row.get('source', {}).get('task')}")
check('PR rows are overdue open_pr rows whose subject is the URL and source.task is the owning ship',
      all(r['category'] == 'open_pr' and r['overdue'] and r['source']['task'] == s
          for (n, r), s in zip(pr_rows.items(), SHIPS)))

# Stale delivery: written before the row is presented to the wake drain.
stale_a = deliver('fm-prune-copy-on-merge', 'old steer before presentation')
time.sleep(2)
wake_append('check: board report')
result, boundary = drain()
check('wake drain presents the overdue PR rows', result.stdout.startswith('OVERDUE:') and PR_URL + '175' in result.stdout, result.stdout[:200])
refused = ack(boundary)
check('wake acknowledgement is refused while no action is recorded', refused.returncode == 1 and 'no action recorded' in refused.stdout, one_line(refused))
time.sleep(1)

id175, id176, id181 = (pr_rows[n]['id'] for n in SHIPS.values())
say('-- adversarial: evidence that must be refused')
none = cli('action', id175, 'steered', '--evidence', '099.msg')
check('record that exists nowhere is refused', none.returncode == 1 and 'task inbox' in none.stdout, one_line(none))
say('     ' + one_line(none))
stale = cli('action', id175, 'steered', '--evidence', stale_a)
check('record sent before the presentation is refused (not a new delivery)',
      stale.returncode == 1 and ('new delivery' in stale.stdout or 'task inbox' in stale.stdout), one_line(stale))
say('     ' + one_line(stale))
for filler in range(2):  # push the other ship's numbering past anything in this ship's own inbox
    deliver('fm-second-ship', f'filler {filler}')
foreign = deliver('fm-second-ship', 'steer for a different ship')
assert not (home / 'state/fm-prune-copy-on-merge.inbox' / foreign).exists(), foreign
cross = cli('action', id175, 'steered', '--evidence', foreign)
check("another ship's inbox record is refused for this ship's PR row (no cross-task borrowing)",
      cross.returncode == 1 and 'task inbox' in cross.stdout, one_line(cross))
say('     ' + one_line(cross))
# A forged provenance path must not escape the state directory.
outside = world / 'outside.inbox'
outside.mkdir()
(outside / '019.msg').write_text('schema=fm-task-inbox.v1\nat=' + iso(now + 3600) + '\n--\nforged\n')
ledger_path = home / 'state/open-loops.json'
saved = ledger_path.read_text()
tampered = json.loads(saved)
for r in tampered['rows']:
    if r['id'] == id175:
        r['source']['task'] = '../../outside'
ledger_path.write_text(json.dumps(tampered))
traversal = cli('action', id175, 'steered', '--evidence', '019.msg')
check('source.task with path separators is ignored (no path traversal)', traversal.returncode == 1, one_line(traversal))
say('     ' + one_line(traversal))
ledger_path.write_text(saved)

say('-- the reported case: steer a PR row from its owning ship inbox')
good = deliver('fm-prune-copy-on-merge', 'rebase on main and report')
say(f'  delivered {good} to state/fm-prune-copy-on-merge.inbox/')
steer = cli('action', id175, 'steered', '--evidence', good)
say('  action steered -> ' + one_line(steer))
check('PR row 175: action steered --evidence NNN.msg is accepted from source.task inbox', steer.returncode == 0, one_line(steer))
action = json.loads(ledger_path.read_text())['handling']['actions'].get(id175, {})
check('receipt recorded as steered with the cited record', action.get('kind') == 'steered' and action.get('evidence') == good, str(action))
reuse = cli('action', id175, 'steered', '--evidence', good)
check('same record cannot be cited twice', reuse.returncode == 1 and 'new delivery' in reuse.stdout, one_line(reuse))

say('-- handled/ variant on a second ship')
rec = deliver('fm-second-ship', 'second ship steer after presentation')
inbox = home / 'state/fm-second-ship.inbox'
shutil.move(str(inbox / rec), str(inbox / 'handled' / rec))
handled = cli('action', id176, 'steered', '--evidence', rec)
say('  action steered (record moved to handled/) -> ' + one_line(handled))
check('PR row 176: record found in handled/ is accepted', handled.returncode == 0, one_line(handled))

say('-- wake acknowledgement after answering both rows')
partial = ack(boundary)
say('  ack with row 181 still unanswered -> ' + one_line(partial))
check('ack still refused while a third PR row has no action', partial.returncode == 1 and 'no action recorded' in partial.stdout, one_line(partial))

say('-- deferred once, second deferral refused, steer is the truthful action left')
recheck = dt.datetime.fromtimestamp(now + 600, dt.timezone.utc).isoformat()
d1 = cli('action', id181, 'deferred', '--evidence', 'CI settling', '--recheck', recheck)
check('first deferral of PR row 181 accepted', d1.returncode == 0, one_line(d1))
d2 = cli('action', id181, 'deferred', '--evidence', 'CI settling again', '--recheck', recheck)
check('second deferral refused for the captain-visible row',
      d2.returncode == 1 and 'second deferral refused' in d2.stdout, one_line(d2))
say('     ' + one_line(d2))
time.sleep(2)
late = deliver('fm-third-ship', 'check CI and report')
s3 = cli('action', id181, 'steered', '--evidence', late)
say('  action steered after deferral -> ' + one_line(s3))
check('PR row 181: steer accepted after the deferral (row is no longer stuck)', s3.returncode == 0, one_line(s3))
say('-- regression: question row keeps working through its subject prefix')
qrec = deliver('fm-prune-copy-on-merge', 'answer: use engine v2')
qs = cli('action', q_row['id'], 'steered', '--evidence', qrec)
say('  question row action steered -> ' + one_line(qs))
check('question row steer still accepted (task id leading the subject)', qs.returncode == 0, one_line(qs))
done = ack(boundary)
say('  ack -> ' + one_line(done))
check('wake acknowledgement permitted once every overdue row has an action', done.returncode == 0, one_line(done))
queue = (home / 'state/.wake-queue').read_text()
check('acknowledged wake is consumed from the queue', queue == '', repr(queue[:80]))
check('--check-actions reports no unmet requirement', cli('--check-actions').returncode == 0)

say()
failed = [n for n, ok in results if not ok]
say(f'SUMMARY {label}: {len(results) - len(failed)} passed, {len(failed)} failed')
for n in failed:
    say('  FAILED: ' + n)
shutil.rmtree(world, ignore_errors=True)
sys.exit(0)
