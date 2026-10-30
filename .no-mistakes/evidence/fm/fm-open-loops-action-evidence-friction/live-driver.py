#!/usr/bin/env python3
"""Live driver: run the real bin/fm-open-loops.sh and bin/fm-wake-drain.sh in disposable lab homes.

Usage: live-driver.py HEAD_BIN BASE_BIN SCRATCH
Every home is minted by HEAD_BIN/fm-lab-home.sh create and removed at the end.
External services are local doubles: gh (forge), tmux (session endpoints), no-mistakes (run store).
"""
import datetime as dt, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

head_bin, base_bin, scratch = map(Path, sys.argv[1:])
now = int(time.time())
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
labs = []
results = []

def say(*parts):
    print(*parts, flush=True)

def lab():
    base = Path(subprocess.check_output(['mktemp', '-d', '/tmp/fm-lab.XXXXXX'], text=True).strip())
    home = Path(subprocess.check_output([str(head_bin / 'fm-lab-home.sh'), 'create', str(base)], text=True).strip())
    labs.append(home)
    return home

def env_for(home, clock, **extra):
    env = dict(os.environ, FM_HOME=str(home), FM_OPEN_LOOPS_NOW=str(clock), FM_SUPERVISION_ACTOR='main',
               FM_TEST_SEAM='1', FM_TEST_HARNESS='codex', NM_HOME=str(home / 'nm'),
               PATH=f'{scratch / "fakebin"}{os.pathsep}{os.environ["PATH"]}', GH_DOUBLE=str(home / 'gh.json'))
    for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE',
                'FM_PROJECTS_OVERRIDE', 'NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS'):
        env.pop(key, None)
    env.update(extra)
    return env

def run(bin_dir, home, clock, *args, show=True):
    cmd = [str(bin_dir / args[0]), *map(str, args[1:])]
    done = subprocess.run(cmd, env=env_for(home, clock), text=True, capture_output=True, timeout=180)
    if show:
        label = 'BASE' if bin_dir == base_bin else 'HEAD'
        say(f'$ [{label} now+{clock - now}s] {args[0]} ' + ' '.join(map(str, args[1:])))
        for line in (done.stdout.rstrip() + '\n' + done.stderr.rstrip()).strip().splitlines():
            if 'ack-through' in line or line.strip():
                say('    ' + line)
        say(f'    -> exit {done.returncode}')
    return done

def check(name, cond, detail=''):
    results.append((name, bool(cond)))
    say(('PASS' if cond else 'FAIL') + ': ' + name + (f' ({detail})' if detail and not cond else ''))

def wake(bin_dir, home, clock, label='report'):
    subprocess.run(['bash', '-c', '. "$1"; fm_wake_append check report "check: %s"' % label, '_',
                    str(bin_dir / 'fm-wake-lib.sh')], env=env_for(home, clock), check=True, capture_output=True)

def drain(bin_dir, home, clock):
    wake(bin_dir, home, clock)
    done = run(bin_dir, home, clock, 'fm-wake-drain.sh')
    match = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', done.stderr)
    assert match, (done.stdout, done.stderr)
    return done, match.groups()

def ack(bin_dir, home, clock, boundary):
    return run(bin_dir, home, clock, 'fm-wake-drain.sh', '--ack-through', boundary[0],
               '--recovery-generation', boundary[1])

def seeded(row):
    home = lab()
    (home / 'state/open-loops.json').write_text(json.dumps(dict(schema='fm-open-loops.v1', generated_epoch=now,
                                                                complete=True, rows=[row])))
    return home

def inbox(home, task, record, sent, body='follow up\n'):
    path = home / 'state' / (task + '.inbox') / record
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f'schema=fm-task-inbox.v1\nat={iso(sent)}\n--\n{body}')

def stalled_row(name, **fields):
    row = dict(id='row-' + name, category='stalled_worker', subject='worker', owner='worker:worker',
               next_action='follow up on lint.full.whole', age_seconds=7200, limit_seconds=3600,
               overdue=True, evidence='waiting for lint.full.whole; declaration age 7200s')
    row.update(fields)
    return row

# ---------------------------------------------------------------- doubles
fake = scratch / 'fakebin'
fake.mkdir(exist_ok=True)
def executable(path, text):
    path.write_text(text); path.chmod(0o755)
executable(fake / 'gh', r'''#!/usr/bin/env python3
import hashlib, json, os, re, sys
args = sys.argv[1:]
assert args[:2] == ['api', '-i'], args
d = json.load(open(os.environ['GH_DOUBLE']))
path = '/' + args[-1].lstrip('/')
if '/check-runs' in path: value = {'check_runs': d['checks']}
elif '/statuses' in path: value = []
elif re.search(r'/pulls\?', path): value = [d['pull']]
elif '/rules/branches/' in path: value = []
elif '/branches/' in path: value = {'protected': False}
elif re.search(r'/pulls/\d+/reviews', path): value = []
elif re.search(r'/pulls/\d+$', path): value = d['pull']
else: value = {}
body = json.dumps(value)
etag = '"' + hashlib.sha1(body.encode()).hexdigest()[:16] + '"'
sys.stdout.write('HTTP/2.0 200 OK\r\nEtag: ' + etag + '\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4000\r\n'
                 'X-Ratelimit-Reset: 9999999999\r\nX-Ratelimit-Resource: core\r\n\r\n' + body)
''')
executable(fake / 'tmux', '''#!/usr/bin/env bash
if [ -e "$FM_HOME/session-gone" ]; then [ "$1" = list-windows ] && exit 0; exit 1; fi
case "$1" in
  list-windows) printf 'fm-repair-owner\\n' ;;
  display-message) printf '%%1\\n' ;;
  capture-pane) printf 'all quiet\\n' ;;
  *) exit 1 ;;
esac
''')
executable(fake / 'no-mistakes', '#!/usr/bin/env bash\nexit 0\n')

# ---------------------------------------------------------------- forge-collected PR rows (real heartbeat)
PR = 'https://github.com/test/project/pull/283'
def forge_home(checks):
    home = lab()
    origin = scratch / ('origin-' + home.name)
    subprocess.run(['git', 'init', '-q', '-b', 'main', str(home / 'projects/project')], check=True)
    subprocess.run(['git', '-C', str(home / 'projects/project'), 'commit', '-q', '--allow-empty', '-m', 'base'],
                   check=True, env=dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@e.invalid',
                                        GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@e.invalid'))
    subprocess.run(['git', '-C', str(home / 'projects/project'), 'remote', 'add', 'origin',
                    'https://github.com/test/project.git'], check=True)
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (home / 'gh.json').write_text(json.dumps(dict(
        pull=dict(html_url=PR, number=283, state='open', draft=False, head={'sha': 'a' * 40}, user={'login': 'x'},
                  requested_reviewers=[], requested_teams=[], updated_at=iso(now - 7200 * 24)),
        checks=checks)))
    (home / 'state/parked-job.meta').write_text(f'kind=ship\nspawn_gen=s-parked\npr={PR}\n')
    (home / 'state/parked-job.status').write_text(f'working [at={now}]: parked on purpose until repair-owner merges\n')
    tree = scratch / ('tree-' + home.name)
    subprocess.run(['git', 'init', '-q', '-b', 'fm/repair-owner', str(tree)], check=True)
    meta = (f'kind=ship\nspawn_gen=s-repair\nworktree={tree}\nharness=claude\nwindow=fm:fm-repair-owner\n')
    (home / 'state/repair-owner.meta').write_text(meta)
    (home / 'state/repair-owner.status').write_text(f'working [at={now}]: fixing the red main\n')
    for path in (home / 'state').glob('*.status'):
        os.utime(path, (now, now))
    e = env_for(home, now)
    subprocess.run([str(head_bin / 'fm-busy-event.sh'), 'arm', str(home / 'state'), 'repair-owner'], env=e, check=True)
    subprocess.run([str(head_bin / 'fm-busy-event.sh'), 'apply', str(home / 'state'), 'repair-owner', 'busy',
                    '--current-gen', '--source', 'claude-hook', '--event', 'fixture'], env=e, check=True)
    return home, meta

def publish(bin_dir, home, clock=now):
    done = run(bin_dir, home, clock, 'fm-open-loops.sh', '--heartbeat', '--json', show=False)
    assert done.returncode == 0, done.stderr
    return json.loads(done.stdout)

GREEN = [dict(name='ci', status='completed', conclusion='success', completed_at=iso(now - 7200 * 24), id=1, app={'id': 1})]
RED = [dict(name='Behavior portable serial 17', status='completed', conclusion='failure',
            completed_at=iso(now - 7200), id=1, app={'id': 1})]

say('=' * 100)
say('S5 (M5): a green PR row never asks for merge approval; it points at AGENTS.md section 7')
for label, bin_dir in (('BASE', base_bin), ('HEAD', head_bin)):
    home, _ = forge_home(GREEN)
    report = publish(bin_dir, home)
    row = next((r for r in report['rows'] if r['subject'] == PR), None)
    say(f'  [{label}] collected row: ' + json.dumps({k: row.get(k) for k in ('category', 'owner', 'next_action', 'overdue')} if row else None))
    shown = run(bin_dir, home, now, 'fm-open-loops.sh', '--report')
    if label == 'HEAD':
        check('S5 green PR next_action names AGENTS.md section 7 and no approval request',
              row and 'AGENTS.md section 7' in row['next_action'] and 'approval' not in row['next_action']
              and 'approval' not in shown.stdout, row)

say('=' * 100)
say('S6 (M6): a red PR row with no handling goes overdue, is presented, and blocks the acknowledgement')
home, _ = forge_home(RED)
report = publish(head_bin, home)
red = next(r for r in report['rows'] if r['subject'] == PR)
say('  collected row: ' + json.dumps({k: red.get(k) for k in ('id', 'category', 'owner', 'next_action', 'overdue')}))
d, boundary = drain(head_bin, home, now)
gated = ack(head_bin, home, now, boundary)
chk = run(head_bin, home, now, 'fm-open-loops.sh', '--check-actions')
check('S6 unhandled overdue row is presented and the acknowledgement is refused',
      red['overdue'] and red['id'] in d.stdout and gated.returncode != 0 and chk.returncode == 1)

say('=' * 100)
say('S2 (M2): a red PR whose worker is parked until a named live task lands; BASE refusal vs HEAD')
reason = 'PR is red because main is red; parked until repair-owner merges'
for label, bin_dir in (('BASE', base_bin), ('HEAD', head_bin)):
    home, meta = forge_home(RED)
    report = publish(bin_dir, home)
    red = next(r for r in report['rows'] if r['subject'] == PR)
    d, boundary = drain(bin_dir, home, now)
    w = run(bin_dir, home, now, 'fm-open-loops.sh', 'action', red['id'], 'waiting', '--evidence', reason,
            '--prerequisite-task', 'repair-owner', '--recheck', iso(now + 3600))
    if label == 'BASE':
        check('S2 BASE reproduces the reported refusal', w.returncode == 1 and 'standing dependency wait' in w.stdout + w.stderr)
        continue
    a = ack(bin_dir, home, now, boundary)
    c = run(bin_dir, home, now, 'fm-open-loops.sh', '--check-actions')
    d2, b2 = drain(bin_dir, home, now + 60)
    a2 = ack(bin_dir, home, now + 60, b2)
    check('S2 HEAD records the wait on a live task and it stands across presentations',
          w.returncode == 0 and a.returncode == 0 and c.returncode == 0 and a2.returncode == 0, w.stdout)
    rep = run(bin_dir, home, now + 60, 'fm-open-loops.sh', '--report')
    check('S2 a standing wait stays listed in --report', red['id'] in rep.stdout)
    # Resurface: the prerequisite's PR merges.
    (home / 'state/repair-owner.meta').write_text(meta + 'pr=https://github.com/test/project/pull/290\n')
    c = run(bin_dir, home, now + 60, 'fm-open-loops.sh', '--check-actions')
    check('S2 open prerequisite PR keeps the wait', c.returncode == 0)
    (home / 'state/repair-owner.pr-poll-merge-notified').write_text(
        'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\ntest/project\n290\n')
    c = run(bin_dir, home, now + 60, 'fm-open-loops.sh', '--check-actions')
    p = run(bin_dir, home, now + 60, 'fm-open-loops.sh', '--present-overdue')
    check('S2 resurfaces when the prerequisite PR merges', c.returncode == 1 and red['id'] in p.stdout)

def waited_home():
    home, meta = forge_home(RED)
    report = publish(head_bin, home)
    red = next(r for r in report['rows'] if r['subject'] == PR)
    d, boundary = drain(head_bin, home, now)
    w = run(head_bin, home, now, 'fm-open-loops.sh', 'action', red['id'], 'waiting', '--evidence', reason,
            '--prerequisite-task', 'repair-owner', '--recheck', iso(now + 3600), show=False)
    assert w.returncode == 0, w.stdout
    assert ack(head_bin, home, now, boundary).returncode == 0
    return home, meta, red

say('-- prerequisite fails')
home, meta, red = waited_home()
(home / 'state/repair-owner.status').write_text(f'working [at={now}]: fixing\nfailed [at={now}]: tests still red\n')
subprocess.run([str(head_bin / 'fm-busy-event.sh'), 'apply', str(home / 'state'), 'repair-owner', 'idle',
                '--current-gen', '--source', 'claude-hook', '--event', 'fixture'], env=env_for(home, now), check=True)
c = run(head_bin, home, now, 'fm-open-loops.sh', '--check-actions')
check('S2 resurfaces when the prerequisite fails', c.returncode == 1)
say('-- prerequisite stalls (its own stalled_worker row is overdue)')
home, meta, red = waited_home()
led = json.loads((home / 'state/open-loops.json').read_text())
led['rows'].append(dict(id='stalled-repair', category='stalled_worker', subject='repair-owner', owner='worker:repair-owner',
                        next_action='follow up', age_seconds=7200, limit_seconds=3600, overdue=True, evidence='no progress'))
(home / 'state/open-loops.json').write_text(json.dumps(led))
c = run(head_bin, home, now, 'fm-open-loops.sh', '--check-actions')
r = run(head_bin, home, now, 'fm-open-loops.sh', 'action', red['id'], 'waiting', '--evidence', reason,
        '--prerequisite-task', 'repair-owner', '--recheck', iso(now + 3600))
check('S2 resurfaces when the prerequisite stalls, and a new wait is refused',
      c.returncode == 1 and r.returncode == 1 and 'stalled' in r.stdout)
say('-- prerequisite recheck comes due')
home, meta, red = waited_home()
c = run(head_bin, home, now + 3600, 'fm-open-loops.sh', '--check-actions')
check('S2 never stands past its recheck', c.returncode == 1)

say('=' * 100)
say('S2b (M2 adversarial): a wait on a task that is not live is refused')
home, meta = forge_home(RED)
report = publish(head_bin, home)
red = next(r for r in report['rows'] if r['subject'] == PR)
drain(head_bin, home, now)
m = run(head_bin, home, now, 'fm-open-loops.sh', 'action', red['id'], 'waiting', '--evidence', reason,
        '--prerequisite-task', 'no-such-task', '--recheck', iso(now + 3600))
o = run(head_bin, home, now, 'fm-open-loops.sh', 'action', red['id'], 'waiting', '--evidence', reason,
        '--prerequisite-task', 'parked-job', '--recheck', iso(now + 3600))
(home / 'session-gone').write_text('')
subprocess.run([str(head_bin / 'fm-busy-event.sh'), 'apply', str(home / 'state'), 'repair-owner', 'idle',
                '--current-gen', '--source', 'claude-hook', '--event', 'fixture'], env=env_for(home, now), check=True)
g = run(head_bin, home, now, 'fm-open-loops.sh', 'action', red['id'], 'waiting', '--evidence', reason,
        '--prerequisite-task', 'repair-owner', '--recheck', iso(now + 3600))
(home / 'session-gone').unlink()
(home / 'state/repair-owner.status').write_text(f'working [at={now}]: x\ndone [at={now}]: findings reported\n')
dn = run(head_bin, home, now, 'fm-open-loops.sh', 'action', red['id'], 'waiting', '--evidence', reason,
         '--prerequisite-task', 'repair-owner', '--recheck', iso(now + 3600))
stored = json.loads((home / 'state/open-loops.json').read_text())['handling']['actions']
check('S2b unknown, own, session-gone and done-without-PR prerequisites are all refused and nothing is recorded',
      all(x.returncode == 1 for x in (m, o, g, dn)) and 'not live' in g.stdout and 'done with no PR' in dn.stdout
      and red['id'] not in stored)
say('-- a non-PR row cannot wait on a task by reason alone')
home, meta = forge_home(RED)
report = publish(head_bin, home)
led = json.loads((home / 'state/open-loops.json').read_text())
row = next(r for r in led['rows'] if r['subject'] == PR)
row.update(category='unanswered_question', owner='firstmate')   # a collected row that is not a PR row
(home / 'state/open-loops.json').write_text(json.dumps(led))
drain(head_bin, home, now)
q = run(head_bin, home, now, 'fm-open-loops.sh', 'action', row['id'], 'waiting', '--evidence', reason,
        '--prerequisite-task', 'repair-owner', '--recheck', iso(now + 3600))
check('S2b a non-PR row is refused a reason-only task wait', q.returncode == 1 and 'only a PR row' in q.stdout)

say('=' * 100)
say('S1 (M1): a steer sent minutes before a re-presentation still counts; BASE vs HEAD')
REV = 'https://github.com/test/project/pull/9'
for label, bin_dir in (('BASE', base_bin), ('HEAD', head_bin)):
    home = seeded(stalled_row('rev', category='review_pass_not_merged', subject=REV, owner='firstmate',
                              source=dict(task='worker'), limit_seconds=600))
    d, boundary = drain(bin_dir, home, now)
    inbox(home, 'worker', '001.msg', now + 1)
    s = run(bin_dir, home, now + 5, 'fm-open-loops.sh', 'action', 'row-rev', 'steered', '--evidence', '001.msg')
    ack(bin_dir, home, now + 5, boundary)
    inbox(home, 'worker', '002.msg', now + 90)   # sent 30 seconds before the next presentation
    d2, b2 = drain(bin_dir, home, now + 120)
    again = run(bin_dir, home, now + 120, 'fm-open-loops.sh', 'action', 'row-rev', 'steered', '--evidence', '002.msg')
    if label == 'BASE':
        check('S1 BASE reproduces the demand for a newer message', again.returncode == 1)
    else:
        a2 = ack(bin_dir, home, now + 120, b2)
        check('S1 HEAD accepts a steer sent before the re-presentation without a newer message',
              s.returncode == 0 and again.returncode == 0 and a2.returncode == 0, again.stdout)
say('-- ordinary steered row stays covered across a re-presentation')
home = seeded(stalled_row('cov'))
d, boundary = drain(head_bin, home, now)
inbox(home, 'worker', '001.msg', now + 1)
run(head_bin, home, now + 5, 'fm-open-loops.sh', 'action', 'row-cov', 'steered', '--evidence', '001.msg')
ack(head_bin, home, now + 5, boundary)
d2, b2 = drain(head_bin, home, now + 120)
a2 = ack(head_bin, home, now + 120, b2)
check('S1 an unchanged steered row needs no new message on the next drain', a2.returncode == 0)
say('-- adversarial: a delivery before the row became overdue, and one older than four hours')
home = seeded(stalled_row('old', age_seconds=100000))
drain(head_bin, home, now)
inbox(home, 'worker', '001.msg', now + 1)
inbox(home, 'worker', '002.msg', now - 96500)
b = run(head_bin, home, now + 5, 'fm-open-loops.sh', 'action', 'row-old', 'steered', '--evidence', '002.msg')
o = run(head_bin, home, now + 5 * 3600, 'fm-open-loops.sh', 'action', 'row-old', 'steered', '--evidence', '001.msg')
check('S1b a pre-episode steer and a steer older than four hours are both refused',
      b.returncode == 1 and o.returncode == 1 and 'four hours' in o.stdout)

say('=' * 100)
say('S3 (M3): the deferral check and the printed row agree on captain_visible; BASE vs HEAD')
def printed_visibility(text, ident):
    line = next((l for l in text.splitlines() if ident in l and l.startswith('  ')), '')
    return line.rsplit(',', 1)[-1] if line else '?'
for label, bin_dir in (('BASE', base_bin), ('HEAD', head_bin)):
    home = seeded(stalled_row('vis'))
    d, boundary = drain(bin_dir, home, now)
    run(bin_dir, home, now, 'fm-open-loops.sh', 'action', 'row-vis', 'deferred', '--evidence', 'lint running',
        '--recheck', iso(now + 600))
    ack(bin_dir, home, now, boundary)
    d2, b2 = drain(bin_dir, home, now + 700)
    shown = printed_visibility(d2.stdout, 'row-vis')
    second = run(bin_dir, home, now + 700, 'fm-open-loops.sh', 'action', 'row-vis', 'deferred', '--evidence',
                 'still running', '--recheck', iso(now + 1300))
    say(f'  [{label}] printed captain_visible before the refused second deferral: {shown}')
    if label == 'BASE':
        check('S3 BASE reproduces the contradiction (prints false, then refuses as captain-visible)',
              shown == 'false' and second.returncode == 1)
    else:
        check('S3 HEAD prints captain_visible true for the row the deferral check refuses',
              shown == 'true' and second.returncode == 1 and 'second deferral refused' in second.stdout)

say('=' * 100)
say('S4 (M4): a remote secondmate delivery id is accepted as steered evidence; BASE vs HEAD')
def reply(home, corr, delivered, task='mini'):
    p = home / 'state/pending-replies'
    p.mkdir(exist_ok=True)
    (p / corr).write_text(f'schema=fm-pending-reply.v1\ncorr_id={corr}\ntask_id={task}\ncreated_epoch={now}\n'
                          f'delivered_epoch={delivered}\nphase=awaiting_report\n')
for label, bin_dir in (('BASE', base_bin), ('HEAD', head_bin)):
    home = seeded(stalled_row('remote', category='silent_report', subject='mini', owner='firstmate',
                              next_action='check in: progress, blockers, cross-workstream dependencies',
                              evidence='last heard'))
    d, boundary = drain(bin_dir, home, now)
    reply(home, 'aabbccddeeff0011', now + 5)
    reply(home, '0123456789abcdef', '')
    reply(home, 'fedcba9876543210', now + 5, task='other')
    good = run(bin_dir, home, now + 10, 'fm-open-loops.sh', 'action', 'row-remote', 'steered', '--evidence', 'aabbccddeeff0011')
    if label == 'BASE':
        check('S4 BASE reproduces the refusal of a remote delivery id', good.returncode == 1)
        continue
    und = run(bin_dir, home, now + 10, 'fm-open-loops.sh', 'action', 'row-remote', 'steered', '--evidence', '0123456789abcdef')
    foreign = run(bin_dir, home, now + 10, 'fm-open-loops.sh', 'action', 'row-remote', 'steered', '--evidence', 'fedcba9876543210')
    a = ack(bin_dir, home, now + 10, boundary)
    check('S4 HEAD accepts a delivered remote id; undelivered and foreign ids are refused',
          good.returncode == 0 and a.returncode == 0 and und.returncode == 1 and foreign.returncode == 1)

say('=' * 100)
failed = [n for n, ok in results if not ok]
say(f'SUMMARY: {len(results) - len(failed)} of {len(results)} checks passed')
for n in failed:
    say('FAILED: ' + n)
for home in labs:
    subprocess.run([str(head_bin / 'fm-lab-home.sh'), 'teardown', str(home)], check=False)
    shutil.rmtree(home, ignore_errors=True)
say(f'teardown: removed {len(labs)} lab homes')
sys.exit(1 if failed else 0)
