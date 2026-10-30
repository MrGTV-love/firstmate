#!/usr/bin/env python3
"""Live drive of the open-work ledger CLI in a disposable lab home (FM_HOME from bin/fm-lab-home.sh env).

argv: W CODE_ROOT LABEL SCENARIO TRANSCRIPT
"""
import datetime as dt, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

W, code, label, scenario, transcript = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
home = Path(os.environ['FM_HOME'])
bin_ = code / 'bin'
now = int(time.time())
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
PR283 = 'https://github.com/test/project/pull/283'
PR284 = 'https://github.com/test/project/pull/284'
REASON = 'PR is red because main is red; parked until repair-owner merges'
log = open(transcript, 'a')
results = []

env = dict(os.environ, PATH=f'{W}/fakebin:{os.environ["PATH"]}', NM_HOME=str(W / ('nm-' + label + '-' + scenario)),
           GH_DOUBLE=str(home / 'gh.json'), GH_REQUESTS=str(home / 'gh-requests'), FM_SUPERVISION_ACTOR='main',
           FM_TEST_SEAM='1', FM_TEST_HARNESS='claude', FM_OPEN_LOOPS_NOW=str(now))
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE',
            'TMUX', 'TMUX_PANE'):
    env.pop(key, None)


def say(text):
    log.write(text + '\n'); log.flush()


def run(*args, quiet=False, at=None):
    e = dict(env)
    if at is not None:
        e['FM_OPEN_LOOPS_NOW'] = str(at)
    shown = ' '.join(str(a).replace(str(bin_), 'bin') for a in args)
    r = subprocess.run([str(a) for a in args], env=e, text=True, capture_output=True, timeout=300)
    if not quiet:
        say(f'$ {"FM_OPEN_LOOPS_NOW=now+" + str(at - now) + " " if at not in (None, now) else ""}{shown}')
        for stream in (r.stdout, r.stderr):
            if stream.strip():
                say('\n'.join('  ' + l for l in stream.rstrip().splitlines()[-25:]))
        say(f'  -> exit {r.returncode}')
    return r


def ok(*args, **kw):
    r = run(*args, **kw)
    assert r.returncode == 0, (args, r.stdout, r.stderr)
    return r


def check(name, cond, detail=''):
    results.append((name, bool(cond)))
    say(f'CHECK [{label}] {name}: {"PASS" if cond else "FAIL"} {detail}')


def git(*args):
    return ok('git', *args, quiet=True).stdout.strip()


def tmux(*args):
    return run('tmux', *args, quiet=True)


def tmux_ok(*args):
    r = tmux(*args)
    assert r.returncode == 0, (args, r.stderr)
    return r


def setup():
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    project = home / 'projects/project'
    git('init', '-q', '-b', 'main', project)
    git('-C', project, 'commit', '-q', '--allow-empty', '-m', 'baseline')
    git('-C', project, 'remote', 'add', 'origin', 'https://github.com/test/project.git')
    R = W / ('run-' + label + '-' + scenario)
    shutil.rmtree(R, ignore_errors=True)
    R.mkdir()
    origin = R / 'origin.git'
    git('init', '-q', '--bare', '-b', 'main', origin)
    git('-C', project, 'push', '-q', str(origin), 'main')
    trees = {}
    for task in ('repair-owner', 'parked-job', 'green-job'):
        tree = R / ('tree-' + task)
        git('clone', '-q', str(origin), tree)
        git('-C', tree, 'checkout', '-q', '-b', 'fm/' + task)
        trees[task] = tree
    tree = trees['repair-owner']
    state = home / 'state'
    (state / 'parked-job.meta').write_text(f'kind=ship\nspawn_gen=s-parked\npr={PR283}\nworktree={trees["parked-job"]}\nwindow=fm:fm-parked-job\n')
    (state / 'parked-job.status').write_text(f'working [at={now}]: parked on purpose until repair-owner merges\n')
    (state / 'green-job.meta').write_text(f'kind=ship\nspawn_gen=s-green\npr={PR284}\nworktree={trees["green-job"]}\nwindow=fm:fm-green-job\n')
    (state / 'green-job.status').write_text(f'working [at={now}]: PR 284 green, awaiting review routing\n')
    meta = f'kind=ship\nspawn_gen=s-repair\nworktree={tree}\nharness=claude\nwindow=fm:fm-repair-owner\n'
    (state / 'repair-owner.meta').write_text(meta)
    (state / 'repair-owner.status').write_text(f'working [at={now}]: fixing the red main\n')
    ok(bin_ / 'fm-busy-event.sh', 'arm', state, 'repair-owner', quiet=True)
    ok(bin_ / 'fm-busy-event.sh', 'apply', state, 'repair-owner', 'busy', '--current-gen', '--source', 'claude-hook',
       '--event', 'lab', quiet=True)
    # Real tmux on the lab's private TMUX_TMPDIR socket: the workers' windows exist.
    assert tmux('new-session', '-d', '-s', 'fm', '-n', 'fm-repair-owner', 'sleep 7200').returncode == 0
    for w in ('fm-parked-job', 'fm-green-job'):
        tmux_ok('new-window', '-d', '-t', 'fm:', '-n', w, 'sleep 7200')
    forge(red_check='Behavior portable serial 17')
    return meta, tree


def forge(red_check):
    pulls = [dict(html_url=PR283, number=283, state='open', draft=False, head=dict(sha='a' * 40, ref='fm/parked-job'),
                  updated_at=iso(now - 3 * 86400), requested_reviewers=[], requested_teams=[]),
             dict(html_url=PR284, number=284, state='open', draft=False, head=dict(sha='b' * 40, ref='fm/green-job'),
                  updated_at=iso(now - 3 * 86400), requested_reviewers=[], requested_teams=[])]
    checks = {'a' * 40: [dict(name=red_check, status='completed', conclusion='failure', id=1, app=dict(id=1),
                              completed_at=iso(now - 1800))],
              'b' * 40: [dict(name='ci', status='completed', conclusion='success', id=2, app=dict(id=1),
                              completed_at=iso(now - 3 * 86400))]}
    (home / 'gh.json').write_text(json.dumps(dict(pulls=pulls, checks=checks)))


def heartbeat(at=None):
    r = run(bin_ / 'fm-open-loops.sh', '--heartbeat', '--json', quiet=True, at=at)
    assert r.returncode == 0, (r.stdout, r.stderr)
    return json.loads(r.stdout)


def wake(text, at=None):
    ok('bash', '-c', '. "$1"; fm_wake_append check report "check: $2"', '_', bin_ / 'fm-wake-lib.sh', text,
       quiet=True, at=at)


def drain(at=None):
    r = run(bin_ / 'fm-wake-drain.sh', at=at)
    m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', r.stderr)
    return r, (m.groups() if m else None)


def ack(boundary, at=None):
    return run(bin_ / 'fm-wake-drain.sh', '--ack-through', boundary[0], '--recovery-generation', boundary[1], at=at)


def act(row, *args, at=None):
    return run(bin_ / 'fm-open-loops.sh', 'action', row, *args, at=at)


def ledger():
    return json.loads((home / 'state/open-loops.json').read_text())


def row_of(report, subject, category):
    return next(r for r in report['rows'] if r['subject'] == subject and r['category'] == category)


def inbox_send(task, text):
    """A real steer: fm-task-inbox-lib.sh writes the worker's NNN.msg delivery record."""
    r = ok('bash', '-c', '. "$1"; fm_task_inbox_write "$2" "$3" "$4"', '_', bin_ / 'fm-task-inbox-lib.sh',
           home / 'state', task, text, quiet=True)
    name = Path(r.stdout.strip()).name if r.stdout.strip() else sorted((home / 'state' / (task + '.inbox')).glob('*.msg'))[-1].name
    say(f'# steer delivered to {task}: {name}')
    return name


def cover_others(at=None, keep=None):
    """Rows outside the scenario (the lab's degraded-liveness coverage row, the green PR) get an escalation."""
    for r in ledger()['rows']:
        if r['id'] != (keep or red['id']) and r.get('overdue') and not r.get('informational'):
            run(bin_ / 'fm-open-loops.sh', 'action', r['id'], 'escalated', '--evidence', 'lab: outside this scenario',
                quiet=True, at=at)


def gate(at=None):
    """--check-actions with every other row covered: returns (exit, whether the red row is named)."""
    cover_others(at)
    r = run(bin_ / 'fm-open-loops.sh', '--check-actions', at=at)
    return r.returncode, red['id'] in (r.stdout + r.stderr)


meta, tree = setup()
say(f'\n===== [{label}] scenario {scenario}: code={code} FM_HOME={home} =====')
report = heartbeat()
say('# collected rows: ' + json.dumps([(r['category'], r['subject'], r['owner'], r['overdue'], r['next_action'])
                                       for r in report['rows'] if not r.get('informational')], indent=None))
red = row_of(report, PR283, 'red_check')
say(f'# red row {red["id"]}: evidence={red["evidence"]!r} source.kind={(red.get("source") or {}).get("kind")}')

try:
    if scenario == 'merge-text':
        green = row_of(report, PR284, 'open_pr')
        say(f'# green PR row next_action: {green["next_action"]!r}')
        check('green PR next_action does not ask for merge approval', 'approv' not in green['next_action'].lower(),
              repr(green['next_action']))
        check('green PR next_action points at AGENTS.md section 7', 'AGENTS.md section 7' in green['next_action'])
        wake('green pr')
        r, b = drain()
        check('drain prints the green PR next_action without approval', 'approv' not in r.stdout.lower())

    elif scenario == 'steer-represent':
        wake('red check')
        _, b = drain()
        msg = inbox_send('parked-job', 'main is red; stay parked until repair-owner merges, then rebase')
        first = act(red['id'], 'steered', '--evidence', msg)
        check('first steer accepted', first.returncode == 0)
        cover_others()
        check('first turn acknowledges', ack(b).returncode == 0)
        later = now + 300
        heartbeat(at=later)
        wake('again', at=later)
        r, b = drain(at=later)
        check('the unchanged red row is re-presented (needs an action again)', red['id'] in r.stdout.split('STANDING')[0])
        again = act(red['id'], 'steered', '--evidence', msg, at=later)
        check('same steer accepted on re-presentation of the unchanged row (no new message)', again.returncode == 0,
              again.stdout.strip()[-200:])
        cover_others(later)
        check('re-presentation turn acknowledges', again.returncode == 0 and ack(b, at=later).returncode == 0)
        # Adversarial: materially changed evidence opens a new episode; the old steer must not answer it.
        forge(red_check='Behavior portable serial 17; and a new failing check')
        changed = now + 600
        heartbeat(at=changed)
        wake('changed', at=changed)
        _, b = drain(at=changed)
        stale = act(red['id'], 'steered', '--evidence', msg, at=changed)
        check('old steer refused after the row evidence changed', stale.returncode == 1, stale.stdout.strip()[-200:])
        # Adversarial: a delivery from before the row became overdue never counts.

    elif scenario == 'task-wait':
        wake('red check')
        _, b = drain()
        waited = act(red['id'], 'waiting', '--prerequisite-task', 'repair-owner', '--evidence', REASON,
                     '--recheck', iso(now + 6 * 3600))
        check('red PR row waits on live task repair-owner by reason', waited.returncode == 0, waited.stdout.strip()[-200:])
        cover_others()
        check('turn acknowledges under the wait', ack(b).returncode == 0)
        wake('again', at=now + 120)
        r, b = drain(at=now + 120)
        check('next drain demands no action for the waiting red row', red['id'] not in r.stdout.split('STANDING')[0])
        cover_others(now + 120)
        check('unchanged wait stands across the next presentation', b is not None and ack(b, at=now + 120).returncode == 0)
        check('--check-actions passes while prerequisite is live', gate() == (0, False))
        rep = run(bin_ / 'fm-open-loops.sh', '--report')
        check('row stays visible in --report while waiting', red['id'] in rep.stdout)
        # Adversarial: a wait on a task that is not live is refused.
        nolive = act(red['id'], 'waiting', '--prerequisite-task', 'no-such-task', '--evidence', REASON,
                     '--recheck', iso(now + 3600))
        check('wait on an absent task refused', nolive.returncode == 1, nolive.stdout.strip()[-200:])
        # 1) prerequisite fails
        status = home / 'state/repair-owner.status'
        status.write_text(status.read_text() + f'failed [at={now}]: tests still red\n')
        ok(bin_ / 'fm-busy-event.sh', 'apply', home / 'state', 'repair-owner', 'idle', '--current-gen', '--source',
           'claude-hook', '--event', 'lab', quiet=True)
        check('wait ends when prerequisite fails', gate() == (1, True))
        failed = act(red['id'], 'waiting', '--prerequisite-task', 'repair-owner', '--evidence', REASON,
                     '--recheck', iso(now + 3600))
        check('new wait on a failed prerequisite refused', failed.returncode == 1, failed.stdout.strip()[-200:])
        status.write_text(f'working [at={now}]: fixing the red main again\n')
        ok(bin_ / 'fm-busy-event.sh', 'apply', home / 'state', 'repair-owner', 'busy', '--current-gen', '--source',
           'claude-hook', '--event', 'lab', quiet=True)
        # 2) prerequisite session gone (missing)
        re_wait = act(red['id'], 'waiting', '--prerequisite-task', 'repair-owner', '--evidence', REASON,
                      '--recheck', iso(now + 6 * 3600))
        check('wait re-recorded once prerequisite is working again', re_wait.returncode == 0, re_wait.stdout.strip()[-200:])
        ok(bin_ / 'fm-busy-event.sh', 'apply', home / 'state', 'repair-owner', 'idle', '--current-gen', '--source',
           'claude-hook', '--event', 'lab', quiet=True)
        tmux('kill-window', '-t', 'fm:fm-repair-owner')
        check('wait ends when prerequisite session is gone', gate() == (1, True))
        gone = act(red['id'], 'waiting', '--prerequisite-task', 'repair-owner', '--evidence', REASON,
                   '--recheck', iso(now + 3600))
        check('new wait on a gone prerequisite refused', gone.returncode == 1, gone.stdout.strip()[-200:])
        tmux_ok('new-window', '-d', '-t', 'fm:', '-n', 'fm-repair-owner', 'sleep 7200')
        ok(bin_ / 'fm-busy-event.sh', 'apply', home / 'state', 'repair-owner', 'busy', '--current-gen', '--source',
           'claude-hook', '--event', 'lab', quiet=True)
        # 3) prerequisite stalls: two hours with no progress, seen by a real collection
        re_wait = act(red['id'], 'waiting', '--prerequisite-task', 'repair-owner', '--evidence', REASON,
                      '--recheck', iso(now + 6 * 3600))
        check('wait re-recorded once prerequisite session is back', re_wait.returncode == 0, re_wait.stdout.strip()[-200:])
        # The lab pane runs `sleep`, not a harness, so the collector judges liveness ambiguous and never runs its
        # stall probe. Publish the stalled_worker row the collector writes for a stalled worker (same schema).
        check('wait stands before the stall', gate() == (0, False))
        published = ledger()
        published['rows'].append(dict(id='lab-stalled-repair', category='stalled_worker', subject='repair-owner',
                                      owner='worker:repair-owner', next_action='follow up', age_seconds=3590,
                                      limit_seconds=3600, overdue=False, evidence='no progress; 3590s without progress'))
        (home / 'state/open-loops.json').write_text(json.dumps(published))
        say('# published a stalled_worker row for repair-owner at 3590s (limit 3600s), not yet overdue')
        check('wait stands while the stall row is under its limit', gate() == (0, False))
        check('wait ends once the stall row crosses its limit (20s later, no recollection)', gate(now + 20) == (1, True))
        stalled_new = act(red['id'], 'waiting', '--prerequisite-task', 'repair-owner', '--evidence', REASON,
                          '--recheck', iso(now + 3600), at=now + 20)
        check('new wait on a stalled prerequisite refused', stalled_new.returncode == 1, stalled_new.stdout.strip()[-200:])
        heartbeat()
        # 4) prerequisite PR merges (merge recorded by the canonical marker writer)
        meta_path = home / 'state/repair-owner.meta'
        meta_path.write_text(meta + 'pr=https://github.com/test/project/pull/290\n')
        status.write_text(f'working [at={now}]: fixing\ndone [at={now}]: PR 290 opened; awaiting review\n')
        ok(bin_ / 'fm-busy-event.sh', 'apply', home / 'state', 'repair-owner', 'idle', '--current-gen', '--source',
           'claude-hook', '--event', 'lab', quiet=True)
        heartbeat()
        done_wait = act(red['id'], 'waiting', '--prerequisite-task', 'repair-owner', '--evidence', REASON,
                        '--recheck', iso(now + 6 * 3600))
        check('done prerequisite with unmerged PR 290 carries the wait', done_wait.returncode == 0, done_wait.stdout.strip()[-200:])
        check('--check-actions passes before merge', gate() == (0, False))
        ok('bash', '-c', '. "$1"; fm_pr_poll_merge_mark_notified "$2" repair-owner github github.com test/project 290',
           '_', bin_ / 'fm-pr-lib.sh', home / 'state')
        check('wait ends when prerequisite PR merges', gate() == (1, True))
        merged = act(red['id'], 'waiting', '--prerequisite-task', 'repair-owner', '--evidence', REASON,
                     '--recheck', iso(now + 3600))
        check('new wait after the prerequisite merged refused', merged.returncode == 1, merged.stdout.strip()[-200:])
        wake('after merge', at=now + 60)
        r, _ = drain(at=now + 60)
        check('drain re-presents the red row after the merge', red['id'] in r.stdout)

    elif scenario == 'visibility':
        wake('red check')
        _, b = drain()
        d1 = act(red['id'], 'deferred', '--evidence', 'main is red; repair in flight', '--recheck', iso(now + 600))
        check('first deferral accepted', d1.returncode == 0)
        cover_others()
        check('turn acknowledges', ack(b).returncode == 0)
        later = now + 700
        heartbeat(at=later)
        wake('lapsed', at=later)
        r, b = drain(at=later)
        line = next((l for l in r.stdout.splitlines() if red['id'] in l and l.startswith('  ')), '')
        shown = line.rsplit(',', 1)[-1] if line else '?'
        say(f'# printed row captain_visible field: {shown!r}')
        d2 = act(red['id'], 'deferred', '--evidence', 'still red', '--recheck', iso(later + 600), at=later)
        refused = d2.returncode == 1 and 'second deferral refused' in d2.stdout
        check('second deferral refused', refused)
        check('printed captain_visible agrees with the refusal (true)', shown == 'true', f'printed={shown}')
        stored = ledger()
        check('stored row captain_visible true', row_of(stored, PR283, 'red_check').get('captain_visible') is True)
        check('refusal offers the truthful wait verb for a red_check row', 'wait on a named live task' in d2.stdout)
        waited = act(red['id'], 'waiting', '--prerequisite-task', 'repair-owner', '--evidence', REASON,
                     '--recheck', iso(later + 3600), at=later)
        check('after the refusal, a wait on the live task answers the row', waited.returncode == 0, waited.stdout.strip()[-200:])

    if scenario == 'remote-steer':
        (home / 'state/mini.meta').write_text('kind=secondmate\nspawn_gen=s-mini\nremote_host=lab-remote.invalid\n')
        published = ledger()
        silent = dict(id='lab-silent-mini', category='silent_report', subject='mini', owner='firstmate',
                      next_action='check in: progress, blockers, cross-workstream dependencies', age_seconds=1800,
                      limit_seconds=900, overdue=True, evidence=f'last heard: status={now - 1800}')
        published['rows'].append(silent)
        (home / 'state/open-loops.json').write_text(json.dumps(published))
        say('# published an overdue silent_report row for remote secondmate mini (remote_host set; its inbox is remote)')
        wake('silent secondmate')
        r, b = drain()
        check('drain presents the remote secondmate row', silent['id'] in r.stdout)
        def reply(task, delivered):
            corr = ok('bash', '-c', '. "$1"; fm_pending_reply_create "$2" "$3" "$4" "check in please"', '_',
                      bin_ / 'fm-pending-reply-lib.sh', home, home / 'state', task, quiet=True).stdout.strip()
            if delivered:
                ok('bash', '-c', '. "$1"; fm_pending_reply_mark_delivered "$2" "$3"', '_',
                   bin_ / 'fm-pending-reply-lib.sh', home / 'state', corr, quiet=True)
            say(f'# pending-reply {corr} for {task} delivered={delivered}')
            return corr
        undelivered = act(silent['id'], 'steered', '--evidence', reply('mini', False))
        check('undelivered pending-reply id refused', undelivered.returncode == 1, undelivered.stdout.strip()[-160:])
        foreign = act(silent['id'], 'steered', '--evidence', reply('other', True))
        check('delivered reply for another task refused', foreign.returncode == 1, foreign.stdout.strip()[-160:])
        corr = reply('mini', True)
        accepted = act(silent['id'], 'steered', '--evidence', corr)
        check('delivered pending-reply id accepted as steered evidence', accepted.returncode == 0, accepted.stdout.strip()[-160:])
        check('stored evidence is the correlation id',
              ledger()['handling']['actions'].get(silent['id'], {}).get('evidence') == corr)
        cover_others(keep=silent['id'])
        check('turn acknowledges after the remote steer', ack(b).returncode == 0)

    if scenario == 'debug-crew':
        def crew(tag):
            r = run('bash', '-c', '. "$1/fm-classify-lib.sh"; export FM_CREW_STATE_NO_FORGE=1; "$FM_CREW_STATE_BIN" repair-owner', '_', bin_, quiet=True)
            say(f'# crew {tag}: {r.stdout.strip()[:300]!r} {r.stderr.strip()[-300:]!r}')
        crew('initial')
        tmux('kill-window', '-t', 'fm:fm-repair-owner'); crew('killed')
        tmux_ok('new-window', '-d', '-t', 'fm:', '-n', 'fm-repair-owner', 'sleep 7200'); crew('recreated')
        ok(bin_ / 'fm-busy-event.sh', 'apply', home / 'state', 'repair-owner', 'busy', '--current-gen', '--source', 'claude-hook', '--event', 'lab', quiet=True); crew('busy')
        say(tmux('list-windows', '-a', '-F', '#{session_name}:#{window_name} #{pane_id} #{pane_current_command}').stdout)

except Exception as error:
    say(f'# [{label}] driver stopped: {type(error).__name__}: {str(error)[:300]}')
    results.append(('driver completed', False))

say(f'# [{label}] {scenario} summary: ' + ', '.join(f'{n}={"PASS" if c else "FAIL"}' for n, c in results))
print(json.dumps(results))
