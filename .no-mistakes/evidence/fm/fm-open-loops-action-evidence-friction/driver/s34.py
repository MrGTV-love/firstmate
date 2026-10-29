# Live driver: real bin/fm-open-loops.sh and bin/fm-wake-drain.sh against a marked lab FM_HOME.
import datetime as dt, json, os, re, subprocess, sys, time
from pathlib import Path
bin_dir, home, scenario = Path(sys.argv[1]), Path(os.environ['FM_HOME']), sys.argv[2]
now = int(time.time()); clock = dict(now=now)
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
state = home / 'state'; ledger = state / 'open-loops.json'
for p in state.glob('*'):
    if p.is_file() and not p.name.startswith('.fm-lab'): p.unlink()
for sub in ('pending-replies',):
    if (state / sub).exists():
        for p in (state / sub).iterdir(): p.unlink()
def show(args, r):
    print('$ ' + ' '.join(str(a).replace(str(bin_dir) + '/', 'bin/') for a in args) + f'   [clock now+{clock["now"]-now}]')
    print((r.stdout + r.stderr).rstrip()); print(f'exit={r.returncode}'); return r
def call(*args, quiet=False):
    r = subprocess.run([str(a) for a in args], env=dict(os.environ, FM_OPEN_LOOPS_NOW=str(clock['now'])), text=True, capture_output=True)
    return r if quiet else show(args, r)
def wake(label):
    call('bash', '-c', f'. "$1"; fm_wake_append check report "check: {label}"', '_', bin_dir / 'fm-wake-lib.sh', quiet=True)
def drain(label):
    wake(label); r = call(bin_dir / 'fm-wake-drain.sh', quiet=True)
    print(f'$ bin/fm-wake-drain.sh   [clock now+{clock["now"]-now}]')
    print('\n'.join(l for l in r.stdout.splitlines() if l.startswith(('OVERDUE', 'STANDING', '  "')) ))
    m = re.search(r'--ack-through (\d+) --recovery-generation (\S+)', r.stderr); return m.groups()
def ack(b): return call(bin_dir / 'fm-wake-drain.sh', '--ack-through', b[0], '--recovery-generation', b[1])
def act(ident, kind, ev, *extra): return call(bin_dir / 'fm-open-loops.sh', 'action', ident, kind, '--evidence', ev, *extra)
def stored(): return json.loads(ledger.read_text())
def seed(*rows): ledger.write_text(json.dumps(dict(schema='fm-open-loops.v1', generated_epoch=now, complete=True, rows=list(rows))))
base = dict(category='stalled_worker', subject='worker', owner='worker:worker', next_action='follow up on lint.full.whole',
            age_seconds=7200, limit_seconds=3600, overdue=True, evidence='waiting for lint.full.whole; declaration age 7200s')
if scenario == 's3':
    print('### S3a: stalled_worker row: deferral lapses -> printed captain_visible, stored value and second-deferral refusal agree')
    seed(dict(base, id='row-visibility'))
    b = drain('first'); act('row-visibility', 'deferred', 'lint running', '--recheck', iso(now + 600)); ack(b)
    print('## While the first deferral stands, a repeat is refused for that reason and marks nothing')
    act('row-visibility', 'deferred', 'lint still running', '--recheck', iso(now + 900))
    print('stored action:', {k: stored()['handling']['actions']['row-visibility'].get(k) for k in ('captain_visible', 'requires_followup')})
    clock['now'] = now + 700
    print('## Deferral lapsed (now+700): re-presented row')
    b = drain('lapsed')
    act('row-visibility', 'deferred', 'still running', '--recheck', iso(now + 1300))
    s = stored(); print('stored action captain_visible:', s['handling']['actions']['row-visibility']['captain_visible'],
                       '| stored row captain_visible:', next(r for r in s['rows'] if r['id'] == 'row-visibility').get('captain_visible'))
    act('row-visibility', 'escalated', 'second deferral escalated'); ack(b)
    print('\n### S3b: review_pass_not_merged row: a deferral never stands, so the printed row, stored row and refusal agree')
    seed(dict(base, id='row-review', category='review_pass_not_merged', subject='https://github.com/test/project/pull/9',
              next_action='merge through bin/fm-pr-merge.sh under AGENTS.md section 7', evidence='independent review PASS at live head',
              limit_seconds=600))
    clock['now'] = now
    b = drain('review first'); act('row-review', 'deferred', 'waiting', '--recheck', iso(now + 600)); ack(b)
    b = drain('review again')
    act('row-review', 'deferred', 'still waiting', '--recheck', iso(now + 600))
    s = stored(); a = s['handling']['actions']['row-review']
    print('stored action:', {k: a.get(k) for k in ('captain_visible', 'requires_followup')},
          '| stored row captain_visible:', next(r for r in s['rows'] if r['id'] == 'row-review').get('captain_visible'))
if scenario == 's4':
    print('### S4: a remote secondmate (task mini) is steered; the parent pending-reply correlation id is the delivery id')
    seed(dict(base, id='row-remote', category='silent_report', subject='mini', owner='firstmate',
              next_action='check in: progress, blockers, cross-workstream dependencies', evidence='last heard'))
    def reply(corr, task='mini', delivered=''):
        d = state / 'pending-replies'; d.mkdir(exist_ok=True)
        (d / corr).write_text(f'schema=fm-pending-reply.v1\ncorr_id={corr}\ntask_id={task}\ncreated_epoch={now}\n'
                              f'delivered_epoch={delivered}\nphase=awaiting_report\n')
    b = drain('remote')
    print('## Adversarial: undelivered id'); reply('0123456789abcdef'); act('row-remote', 'steered', '0123456789abcdef')
    print('## Adversarial: delivered id for another task'); reply('fedcba9876543210', task='other', delivered=str(now + 5)); act('row-remote', 'steered', 'fedcba9876543210')
    print('## Adversarial: delivered before the overdue episode'); reply('0011223344556677', delivered=str(now - 3700)); act('row-remote', 'steered', '0011223344556677')
    print('## Adversarial: symlinked id'); reply('aabbccddeeff0011', delivered=str(now + 5))
    (state / 'pending-replies/2211221122112211').symlink_to(state / 'pending-replies/aabbccddeeff0011'); act('row-remote', 'steered', '2211221122112211')
    print('## Happy path: delivered id for mini after the episode began'); act('row-remote', 'steered', 'aabbccddeeff0011')
    print('stored evidence:', stored()['handling']['actions']['row-remote']['evidence'])
    ack(b)
if scenario == 's6':
    print('### S6: an overdue row with no real handling still re-presents and blocks acknowledgement')
    seed(dict(base, id='row-unhandled'))
    b = drain('unhandled')
    print('## No action recorded: acknowledgement is refused'); ack(b)
    call(bin_dir / 'fm-open-loops.sh', '--check-actions')
    print('## Next turn: the same row is presented again')
    clock['now'] = now + 600; b2 = drain('unhandled again')
    print('## Report still lists it with its current age'); call(bin_dir / 'fm-open-loops.sh', '--report')
    print('\n### S1b: a firstmate-owned steer delivered 10 minutes ago reports the time it actually still stands')
    seed(dict(base, id='row-fm-steer', category='silent_report', subject='worker', owner='firstmate',
              next_action='check in: progress, blockers, cross-workstream dependencies', evidence='last heard'))
    clock['now'] = now
    b = drain('fm steer')
    inbox = state / 'worker.inbox'; inbox.mkdir(exist_ok=True)
    (inbox / '005.msg').write_text(f'schema=fm-task-inbox.v1\nat={iso(now - 600)}\n--\ncheck in please\n')
    act('row-fm-steer', 'steered', '005.msg')
