#!/usr/bin/env python3
"""Drive the real open-work ledger CLI (bin/fm-open-loops.sh, bin/fm-wake-drain.sh) in a marked lab FM_HOME.

Real parts: the worktree's bin/ unmodified, the real fleet snapshot, the real fm-crew-state.sh, real tmux on the
lab's private socket, the real inbox writer (fm_task_inbox_write) and pending-reply library.
Doubles at the PATH boundary only: `gh` (GitHub REST, a local JSON double) and `no-mistakes` (no run store).
"""
import datetime as dt, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

WT, SCRATCH, E = map(Path, sys.argv[1:])
HOME = Path(os.environ['FM_HOME'])
STATE = HOME / 'state'
LOOPS, DRAIN = WT / 'bin/fm-open-loops.sh', WT / 'bin/fm-wake-drain.sh'
FAKE = SCRATCH / 'fakebin'
FAKE.mkdir(parents=True)
T0 = int(time.time())
clock = dict(now=T0)
iso = lambda s: dt.datetime.fromtimestamp(s, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
transcript = open(E / 'lab-transcript.txt', 'w')
results = []

ENV = dict(os.environ, NM_HOME=str(SCRATCH / 'nm'), FM_SUPERVISION_ACTOR='main', GH_DOUBLE=str(SCRATCH / 'gh.json'),
           PATH=f'{FAKE}:{os.environ["PATH"]}')


def log(text):
    transcript.write(text + '\n')
    transcript.flush()


def run(*args, quiet=False):
    env = dict(ENV, FM_OPEN_LOOPS_NOW=str(clock['now']))
    shown = ' '.join(str(a).replace(str(WT) + '/', '').replace(str(HOME), '$FM_HOME') for a in args)
    r = subprocess.run([str(a) for a in args], env=env, text=True, capture_output=True, timeout=600)
    if not quiet:
        log(f'$ [now=T0+{clock["now"] - T0}] {shown}\n  exit={r.returncode}')
        for name, text in (('stdout', r.stdout), ('stderr', r.stderr)):
            text = text.strip()
            if text:
                lines = text.splitlines()
                body = '\n'.join('    ' + l for l in lines[:40]) + ('\n    ...' if len(lines) > 40 else '')
                log(f'  {name}:\n{body}')
    return r


def check(scenario, name, ok, detail=''):
    results.append((scenario, name, bool(ok)))
    line = f'{"PASS" if ok else "FAIL"} [{scenario}] {name}' + (f' -- {detail}' if detail and not ok else '')
    log('>>> ' + line)
    print(line, flush=True)


def wake(label):
    return run('bash', '-c', '. "$1"; fm_wake_append check report "check: $2"', '_', WT / 'bin/fm-wake-lib.sh', label)


def drain():
    r = run(DRAIN)
    m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', r.stderr)
    return r, (m.groups() if m else None)


def ack(boundary):
    return run(DRAIN, '--ack-through', boundary[0], '--recovery-generation', boundary[1])


def act(ident, kind, evidence, *extra):
    return run(LOOPS, 'action', ident, kind, '--evidence', evidence, *extra)


def stored():
    return json.loads((STATE / 'open-loops.json').read_text())


def lib(script, *args):
    return run('bash', '-c', script, '_', *args)


def section(title):
    log('\n' + '=' * 100 + f'\n{title}\n' + '=' * 100)


# --------------------------------------------------------------------------------------------------------------
# Part A: rows collected from real sources (real fleet snapshot, real tmux, forge double).
# --------------------------------------------------------------------------------------------------------------
(FAKE / 'gh').write_text(r'''#!/usr/bin/env python3
import hashlib, json, os, sys, time
args = sys.argv[1:]
assert args[:2] == ['api', '-i'], args
double = json.load(open(os.environ['GH_DOUBLE']))
path = '/' + args[-1].lstrip('/')
if '/check-runs' in path:
    value = {'check_runs': double['checks'].get(path.split('/commits/')[1].split('/')[0], [])}
elif '/statuses' in path:
    value = []
elif '/pulls?' in path:
    value = double['pulls']
elif '/rules/branches/' in path:
    value = []
elif '/branches/' in path:
    value = {'protected': False}
else:
    sys.stderr.write('gh double: unexpected ' + path + '\n'); sys.exit(1)
body = json.dumps(value)
etag = '"' + hashlib.sha1(body.encode()).hexdigest()[:16] + '"'
sys.stdout.write('HTTP/2.0 200 OK\r\nEtag: ' + etag + '\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4000\r\n'
                 'X-Ratelimit-Reset: ' + str(int(time.time()) + 3600) + '\r\nX-Ratelimit-Resource: core\r\n\r\n' + body)
''')
(FAKE / 'no-mistakes').write_text('#!/usr/bin/env bash\n# no run store in this lab\nexit 0\n')
for f in FAKE.iterdir():
    f.chmod(0o755)

PR283, PR284 = 'https://github.com/test/project/pull/283', 'https://github.com/test/project/pull/284'
pull = lambda n, url, sha, ref, upd: dict(number=n, html_url=url, state='open', draft=False, updated_at=iso(upd),
                                     head=dict(sha=sha, ref=ref, repo=dict(full_name='test/project')),
                                     base=dict(sha='0' * 40, ref='main'), requested_reviewers=[], requested_teams=[])
(SCRATCH / 'gh.json').write_text(json.dumps(dict(
    pulls=[pull(283, PR283, 'a' * 40, 'fm/parked-job', T0 - 7200), pull(284, PR284, 'b' * 40, 'fm/green-job', T0)],
    checks={'a' * 40: [dict(name='Behavior portable serial 17', status='completed', conclusion='failure',
                             completed_at=iso(T0 - 7200), id=1, app=dict(id=1))],
            'b' * 40: [dict(name='ci', status='completed', conclusion='success', completed_at=iso(T0 - 7200),
                            id=2, app=dict(id=1))]})))

section('Part A setup: real tmux on the lab socket, three ship tasks, forge double')
AGENT = "bash -c 'exec -a claude sleep 7200'"  # pane process standing in for the worker harness (argv0 claude)
tm = run('tmux', '-f', '/dev/null', 'new-session', '-d', '-s', 'fm', '-n', 'fm-repair-owner', AGENT)
for w in ('fm-parked-job', 'fm-green-job'):
    run('tmux', 'new-window', '-d', '-t', 'fm:', '-n', w, AGENT)
sock = run('tmux', 'display-message', '-p', '-t', 'fm', '#{socket_path}').stdout.strip()
if not os.path.realpath(sock).startswith(os.path.realpath(os.environ['TMUX_TMPDIR'])):
    log('ABORT: tmux socket is not the lab socket: ' + sock)
    run('tmux', 'kill-server')
    sys.exit(3)
log('tmux socket (lab-private): ' + sock)
(HOME / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
G = ['-c', 'user.name=lab', '-c', 'user.email=lab@example.invalid']
origin, seed = SCRATCH / 'origin.git', SCRATCH / 'seed'
run('git', 'init', '-q', '--bare', '-b', 'main', origin)
run('git', 'init', '-q', '-b', 'main', seed)
run('git', '-C', seed, *G, 'commit', '-q', '--allow-empty', '-m', 'baseline')
run('git', '-C', seed, 'push', '-q', str(origin), 'main')
trees = {}
for task in ('parked-job', 'green-job', 'repair-owner'):
    trees[task] = SCRATCH / (task + '-tree')
    run('git', 'clone', '-q', str(origin), trees[task])
    run('git', '-C', trees[task], 'checkout', '-q', '-b', 'fm/' + task)
tree = trees['repair-owner']
metas = dict(
    **{'parked-job': f'kind=ship\nspawn_gen=s-parked\nworktree={trees["parked-job"]}\nharness=claude\nwindow=fm:fm-parked-job\npr={PR283}\n',
       'green-job': f'kind=ship\nspawn_gen=s-green\nworktree={trees["green-job"]}\nharness=claude\nwindow=fm:fm-green-job\npr={PR284}\n',
       'repair-owner': f'kind=ship\nspawn_gen=s-repair\nworktree={tree}\nharness=claude\nwindow=fm:fm-repair-owner\n'})
working = {t: f'working [at={T0}]: {t} working\n' for t in metas}
working['parked-job'] = f'working [at={T0}]: parked on purpose until repair-owner merges\n'
for task, meta in metas.items():
    (STATE / f'{task}.meta').write_text(meta)
    (STATE / f'{task}.status').write_text(working[task])
    run(WT / 'bin/fm-busy-event.sh', 'arm', STATE, task)
    run(WT / 'bin/fm-busy-event.sh', 'apply', STATE, task, 'busy', '--current-gen', '--source', 'claude-hook',
        '--event', 'lab')


def activity(task, state):
    run(WT / 'bin/fm-busy-event.sh', 'apply', STATE, task, state, '--current-gen', '--source', 'claude-hook',
        '--event', 'lab')


def publish():
    r = run(LOOPS, '--heartbeat', '--json', quiet=True)
    log(f'$ [now=T0+{clock["now"] - T0}] bin/fm-open-loops.sh --heartbeat --json  exit={r.returncode}')
    try:
        return json.loads(r.stdout)
    except ValueError:
        log('  stdout: ' + r.stdout[:2000] + '\n  stderr: ' + r.stderr[:2000])
        return dict(rows=[])


report = publish()
for row in report['rows']:
    log('  row: ' + json.dumps({k: row.get(k) for k in ('id', 'category', 'subject', 'owner', 'next_action',
                                                         'overdue', 'age_seconds', 'limit_seconds')}))
(E / 'lab-collected-ledger.json').write_text(json.dumps(report, indent=1))
crew = run(WT / 'bin/fm-crew-state.sh', 'repair-owner')
red = next((r for r in report['rows'] if r['subject'] == PR283 and r['category'] == 'red_check'), None)
green = next((r for r in report['rows'] if r['subject'] == PR284 and r['category'] == 'open_pr'), None)
check('M5', 'green PR row next_action points at AGENTS.md section 7 and asks no approval',
      green and 'AGENTS.md section 7' in green['next_action'] and 'approv' not in green['next_action'].lower(),
      json.dumps(green))
log('  green PR next_action: ' + json.dumps(green and green['next_action']))
check('M2', 'collector publishes a red_check row for PR 283 owned by its parked worker',
      red and red['owner'] == 'worker:parked-job' and red.get('overdue'), json.dumps(red))
if not red:
    log('ABORT part A: no red row')
else:
    RID = red['id']
    section('M6: an unhandled overdue row is presented and gates acknowledgement')
    wake('red PR overdue')
    r, b = drain()
    check('M6', 'drain presents the unhandled overdue red row', RID in r.stdout, r.stdout[:500])
    check('M6', '--check-actions exits 1 while the row has no action', run(LOOPS, '--check-actions').returncode == 1)
    check('M6', 'acknowledgement is refused while the row has no action', b and ack(b).returncode != 0)

    section('M2: wait on a named live task')
    reason = 'PR is red because main is red; parked until repair-owner merges'
    nolive = act(RID, 'waiting', reason, '--prerequisite-task', 'no-such-task', '--recheck', iso(clock['now'] + 3600))
    check('M2', 'a wait on a task that does not exist is refused', nolive.returncode == 1, nolive.stdout)
    waited = act(RID, 'waiting', reason, '--prerequisite-task', 'repair-owner', '--recheck', iso(clock['now'] + 3600))
    check('M2', 'a red PR row is accepted as waiting on live task repair-owner', waited.returncode == 0,
          waited.stdout + waited.stderr)
    check('M2', 'acknowledgement passes once the wait is recorded', b and ack(b).returncode == 0)
    check('M2', '--check-actions exits 0 while the wait stands', run(LOOPS, '--check-actions').returncode == 0)
    wake('again')
    r, b = drain()
    check('M2', 'the next drain does not re-present the standing wait', RID not in r.stdout and b and ack(b).returncode == 0,
          r.stdout[:500])
    digest = run(LOOPS, '--report')
    check('M2', 'the standing wait stays visible in --report', RID in digest.stdout)

    def rewait(label):
        publish()
        again = act(RID, 'waiting', reason, '--prerequisite-task', 'repair-owner', '--recheck',
                    iso(clock['now'] + 3600))
        check('M2', f'after {label} is undone, a new wait on the live task is accepted', again.returncode == 0,
              again.stdout)
        check('M2', f'after {label} is undone, --check-actions exits 0', run(LOOPS, '--check-actions').returncode == 0)

    section('M2: the wait ends when the prerequisite merges')
    (STATE / 'repair-owner.meta').write_text(metas['repair-owner'] + 'pr=https://github.com/test/project/pull/290\n')
    marker = STATE / 'repair-owner.pr-poll-merge-notified'
    lib('. "$1"; fm_pr_poll_merge_mark_notified "$2" repair-owner github github.com test/project 290',
        WT / 'bin/fm-pr-lib.sh', STATE)
    check('M2', 'merge record written by fm_pr_poll_merge_mark_notified exists', marker.exists())
    check('M2', 'a merged prerequisite resurfaces the row (--check-actions exits 1)',
          run(LOOPS, '--check-actions').returncode == 1)
    landed = act(RID, 'waiting', reason, '--prerequisite-task', 'repair-owner', '--recheck', iso(clock['now'] + 3600))
    check('M2', 'a new wait on the merged prerequisite is refused', landed.returncode == 1 and 'merged' in landed.stdout,
          landed.stdout)
    marker.unlink()
    (STATE / 'repair-owner.meta').write_text(metas['repair-owner'])
    rewait('the merge')

    section('M2: the wait ends when the prerequisite fails')
    (STATE / 'repair-owner.status').write_text(working['repair-owner'] + f'failed [at={T0}]: tests still red\n')
    activity('repair-owner', 'idle')
    check('M2', 'a failed prerequisite resurfaces the row (--check-actions exits 1)',
          run(LOOPS, '--check-actions').returncode == 1)
    (STATE / 'repair-owner.status').write_text(working['repair-owner'])
    activity('repair-owner', 'busy')
    rewait('the failure')

    section('M2: the wait ends when the prerequisite session is gone (real tmux window killed)')
    activity('repair-owner', 'idle')
    run('tmux', 'kill-window', '-t', 'fm:fm-repair-owner')
    check('M2', 'a gone prerequisite session resurfaces the row (--check-actions exits 1)',
          run(LOOPS, '--check-actions').returncode == 1)
    gone = act(RID, 'waiting', reason, '--prerequisite-task', 'repair-owner', '--recheck', iso(clock['now'] + 3600))
    check('M2', 'a new wait on a gone prerequisite is refused as not live',
          gone.returncode == 1 and 'not live' in gone.stdout, gone.stdout)
    run('tmux', 'new-window', '-d', '-t', 'fm:', '-n', 'fm-repair-owner', AGENT)
    activity('repair-owner', 'busy')
    rewait('the gone session')

    section('M2: the wait ends when the prerequisite stalls (stalled_worker row injected into the published ledger)')
    led = stored()
    led['rows'].append(dict(id='stalled-repair', category='stalled_worker', subject='repair-owner',
                            owner='worker:repair-owner', next_action='follow up', age_seconds=7200,
                            limit_seconds=3600, overdue=True, evidence='no progress'))
    (STATE / 'open-loops.json').write_text(json.dumps(led))
    check('M2', 'a stalled prerequisite resurfaces the row (--check-actions exits 1)',
          run(LOOPS, '--check-actions').returncode == 1)
    stalled = act(RID, 'waiting', reason, '--prerequisite-task', 'repair-owner', '--recheck', iso(clock['now'] + 3600))
    check('M2', 'a new wait on a stalled prerequisite is refused', stalled.returncode == 1 and 'stalled' in stalled.stdout,
          stalled.stdout)

    section('M2: the wait never stands past its recheck')
    publish()
    act(RID, 'waiting', reason, '--prerequisite-task', 'repair-owner', '--recheck', iso(clock['now'] + 600))
    check('M2', 'wait with 600s recheck stands now', run(LOOPS, '--check-actions').returncode == 0)
    clock['now'] = T0 + 700
    check('M2', 'the same wait no longer stands after its recheck (--check-actions exits 1)',
          run(LOOPS, '--check-actions').returncode == 1)
    clock['now'] = T0

# --------------------------------------------------------------------------------------------------------------
# Part B: one-row ledgers written as persisted state; every action, drain and gate runs through the real CLI.
# --------------------------------------------------------------------------------------------------------------
def case(name, generated=None, keep_inbox=False, **fields):
    for p in ([] if keep_inbox else STATE.glob('*.inbox')):
        shutil.rmtree(p)
    shutil.rmtree(STATE / 'pending-replies', ignore_errors=True)
    row = dict(id='row-' + name, category='stalled_worker', subject='worker', owner='worker:worker',
               next_action='follow up on lint.full.whole', age_seconds=7200, limit_seconds=3600, overdue=True,
               evidence='waiting for lint.full.whole; declaration age 7200s')
    row.update(fields)
    (STATE / 'open-loops.json').write_text(json.dumps(dict(
        schema='fm-open-loops.v1', generated_epoch=generated or clock['now'], complete=True, rows=[row])))
    section(f'Part B case {name}: row {json.dumps(row)}')
    return row


def deliver(task='worker', text='follow up on the lint step'):
    r = lib('. "$1"; fm_task_inbox_write "$2" "$3" "$4"', WT / 'bin/fm-task-inbox-lib.sh', STATE, task, text)
    path = Path(r.stdout.strip())
    at = re.search(r'^at=(.*)$', path.read_text(), re.M)[1]
    log(f'  delivery {path.name} at={at}')
    return path.name, int(dt.datetime.strptime(at, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc).timestamp())


def printed_visibility(result, ident):
    line = next((l for l in result.stdout.splitlines() if ident in l and l.startswith('  ')), '')
    return line.rsplit(',', 1)[-1] if line else None


# M1: a steer delivered after the episode began keeps counting on re-presentation.
clock['now'] = T0 + 10
row = case('m1-steer-ordinary')
wake('first'); r, b = drain()
rec1, at1 = deliver()
s = act(row['id'], 'steered', rec1)
check('M1', 'steer with a delivery made inside the overdue episode is accepted', s.returncode == 0, s.stdout)
check('M1', 'ack passes after the steer', ack(b).returncode == 0)
clock['now'] = T0 + 130
wake('again'); r, b = drain()
check('M1', 'unchanged steered row is not re-presented and needs no new message (ack passes)',
      row['id'] not in r.stdout and ack(b).returncode == 0, r.stdout[:400])

clock['now'] = T0 + 10
row = case('m1-steer-reviewed', category='review_pass_not_merged', subject='https://github.com/test/project/pull/9',
           owner='firstmate', source=dict(task='worker'), limit_seconds=600,
           next_action='merge through bin/fm-pr-merge.sh under AGENTS.md section 7')
wake('first'); r, b = drain()
rec1, at1 = deliver()
check('M1', 'reviewed-green PR row: first steer accepted', act(row['id'], 'steered', rec1).returncode == 0)
check('M1', 'reviewed-green PR row: ack passes', ack(b).returncode == 0)
clock['now'] = T0 + 130
wake('again'); r, b = drain()
check('M1', 'reviewed-green PR row is re-presented after a steer', row['id'] in r.stdout and ack(b).returncode == 1)
again = act(row['id'], 'steered', rec1)
check('M1', 're-presentation accepts the SAME earlier delivery as steered (no new message demanded)',
      again.returncode == 0, again.stdout)
check('M1', 'ack passes after citing the same delivery', ack(b).returncode == 0)

# M1 adversarial: a delivery made before the row became overdue is refused.
rec_old, at_old = deliver()
clock['now'] = at_old + 4000
row = case('m1-before-overdue', keep_inbox=True, age_seconds=3700)  # became overdue at now-100, after rec_old
wake('first'); r, b = drain()
before = act(row['id'], 'steered', rec_old)
check('M1-adv', 'a delivery made before the row became overdue is refused', before.returncode == 1
      and 'became overdue' in before.stdout, before.stdout)
check('M1-adv', 'ack stays refused with no valid action', ack(b).returncode == 1)
esc = act(row['id'], 'escalated', 'lab cleanup')
ack(b)
clock['now'] = at_old + 5 * 3600
row = case('m1-older-than-4h', keep_inbox=True, age_seconds=100000)
wake('first'); r, b = drain()
old = act(row['id'], 'steered', rec_old)
check('M1-adv', 'a delivery older than four hours is refused', old.returncode == 1, old.stdout)
act(row['id'], 'escalated', 'lab cleanup'); ack(b)

# Target commit: the age clock restarts on unchanged text -> a new episode; the old delivery no longer answers.
clock['now'] = T0 + 20
row = case('clock-restart')
wake('first'); r, b = drain()
rec1, at1 = deliver()
time.sleep(2.2)
rec2, at2 = deliver()
check('restart', 'first steer with delivery 1 accepted', act(row['id'], 'steered', rec1).returncode == 0)
check('restart', 'ack passes', ack(b).returncode == 0)
clock['now'] = T0 + 600
boundary = at1 + 1  # the restarted clock's overdue moment: after delivery 1, before delivery 2
led = stored()
led['generated_epoch'] = clock['now']
led['rows'][0]['age_seconds'] = clock['now'] - boundary + 3600  # same text, later clock start
(STATE / 'open-loops.json').write_text(json.dumps(led))
log(f'  rewrote row age to {led["rows"][0]["age_seconds"]} (clock restarted; evidence text unchanged)')
wake('restarted'); r, b = drain()
check('restart', 'the restarted row is presented again', row['id'] in r.stdout, r.stdout[:400])
stale_steer = act(row['id'], 'steered', rec1)
check('restart', 'the delivery from the earlier episode is refused', stale_steer.returncode == 1, stale_steer.stdout)
check('restart', 'acknowledgement stays gated', ack(b).returncode == 1)
ep = stored()['handling'].get('episodes', {}).get(row['id'], {})
log('  stored episode: ' + json.dumps(ep))
check('restart', 'the stored episode starts at the restarted overdue moment', ep.get('start') == boundary, json.dumps(ep))
fresh = act(row['id'], 'steered', rec2)
check('restart', 'a delivery after the new boundary answers it', fresh.returncode == 0, fresh.stdout)
check('restart', 'ack passes after the fresh steer', ack(b).returncode == 0)

# M4: a remote secondmate's delivered pending-reply correlation id is steered evidence.
clock['now'] = T0 + 30
row = case('m4-remote', category='silent_report', subject='mini', owner='firstmate',
           next_action='check in: progress, blockers, cross-workstream dependencies', evidence='last heard')
wake('first'); r, b = drain()
mk = '. "$1"; fm_pending_reply_create "$2" "$3" "$4" "progress check"'
undelivered = lib(mk, WT / 'bin/fm-pending-reply-lib.sh', HOME, STATE, 'mini').stdout.strip()
foreign = lib(mk, WT / 'bin/fm-pending-reply-lib.sh', HOME, STATE, 'other').stdout.strip()
lib('. "$1"; fm_pending_reply_mark_delivered "$2" "$3"', WT / 'bin/fm-pending-reply-lib.sh', STATE, foreign)
delivered = lib(mk, WT / 'bin/fm-pending-reply-lib.sh', HOME, STATE, 'mini').stdout.strip()
lib('. "$1"; fm_pending_reply_mark_delivered "$2" "$3"', WT / 'bin/fm-pending-reply-lib.sh', STATE, delivered)
log(f'  corr ids: undelivered={undelivered} foreign={foreign} delivered={delivered}')
u = act(row['id'], 'steered', undelivered)
check('M4', 'an undelivered pending-reply id is refused', u.returncode == 1, u.stdout)
f = act(row['id'], 'steered', foreign)
check('M4', "another task's delivered pending-reply id is refused", f.returncode == 1, f.stdout)
d = act(row['id'], 'steered', delivered)
check('M4', "the remote secondmate's delivered pending-reply id is accepted as steered", d.returncode == 0, d.stdout)
check('M4', 'stored action cites the correlation id',
      stored()['handling']['actions'][row['id']]['evidence'] == delivered)
check('M4', 'ack passes', ack(b).returncode == 0)

# M3 (as amended by the recorded decision): one visibility owner; a second deferral is refused even while the
# first stands, the refusal sets the mark, and the printed and stored rows agree.
clock['now'] = T0 + 40
row = case('m3-standing-deferral')
wake('first'); r, b = drain()
check('M3', 'printed row is captain_visible false before any deferral', printed_visibility(r, row['id']) == 'false',
      r.stdout[:400])
first = act(row['id'], 'deferred', 'lint running', '--recheck', iso(clock['now'] + 600))
check('M3', 'first deferral accepted', first.returncode == 0, first.stdout)
check('M3', 'ack passes', ack(b).returncode == 0)
repeat = act(row['id'], 'deferred', 'lint still running', '--recheck', iso(clock['now'] + 900))
check('M3', 'second deferral on the unchanged row is refused while the first stands',
      repeat.returncode == 1 and 'second deferral refused' in repeat.stdout, repeat.stdout)
action = stored()['handling']['actions'][row['id']]
check('M3', 'the refusal stores captain_visible and requires_followup',
      action.get('captain_visible') is True and action.get('requires_followup') is True, json.dumps(action))
check('M3', 'stored published row is captain_visible true', stored()['rows'][0].get('captain_visible') is True)
check('M3', '--check-actions exits 1 after the refusal', run(LOOPS, '--check-actions').returncode == 1)
wake('refused'); r, b = drain()
check('M3', 'the next drain prints the row captain_visible true', printed_visibility(r, row['id']) == 'true',
      r.stdout[:400])
act(row['id'], 'escalated', 'lab cleanup'); ack(b)

clock['now'] = T0 + 40
row = case('m3-red-remedy', category='red_check', subject='https://github.com/test/project/pull/283',
           owner='worker:parked-job')
wake('first'); r, b = drain()
act(row['id'], 'deferred', 'main red', '--recheck', iso(clock['now'] + 600)); ack(b)
clock['now'] = T0 + 700
wake('lapsed'); r, b = drain()
shown = printed_visibility(r, row['id'])
second = act(row['id'], 'deferred', 'main still red', '--recheck', iso(clock['now'] + 600))
check('M3', 'a lapsed deferral row prints captain_visible true and the second deferral is refused',
      shown == 'true' and second.returncode == 1, f'shown={shown} {second.stdout}')
check('M3', 'the refusal for a red PR names the live-task wait remedy', 'wait on a named live task' in second.stdout,
      second.stdout)
act(row['id'], 'escalated', 'lab cleanup'); ack(b)

# M6: a row with no real handling still goes overdue and re-presents on every drain.
clock['now'] = T0 + 50
row = case('m6-unhandled')
for n in range(2):
    wake(f'pass {n}'); r, b = drain()
    check('M6', f'drain {n + 1} presents the unhandled overdue row', row['id'] in r.stdout, r.stdout[:300])
    check('M6', f'drain {n + 1}: ack is refused without an action', ack(b).returncode == 1)
    clock['now'] += 600

failed = [r for r in results if not r[2]]
log(f'\nSUMMARY: {len(results) - len(failed)} passed, {len(failed)} failed')
print(f'SUMMARY: {len(results) - len(failed)} passed, {len(failed)} failed', flush=True)
sys.exit(1 if failed else 0)
