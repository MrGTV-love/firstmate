#!/usr/bin/env python3
"""Live driver: run the real bin/fm-open-loops.sh and bin/fm-wake-drain.sh against disposable lab homes.

Usage: drive-ledger.py <worktree> <lab-root>
Each scenario mints its own lab home with bin/fm-lab-home.sh create, copies the worktree's bin/ (so a forge and
fleet double can stand in for GitHub and the live fleet), then prints every CLI call and its output.
"""
import datetime as dt, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

root, lab = Path(sys.argv[1]), Path(sys.argv[2])
code = lab / 'code'
shutil.copytree(root / 'bin', code / 'bin')
now = int(time.time())
iso = lambda s: dt.datetime.fromtimestamp(s, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
WAKE = '. "$1"; fm_wake_append check report "check: %s"'
RESULTS = []


def say(text):
    print(text, flush=True)


def show(label, result):
    say(f'$ {label}\n  exit={result.returncode}')
    for stream in (result.stdout, result.stderr):
        for line in stream.strip().splitlines():
            say('  | ' + line)


def verdict(name, ok, detail=''):
    RESULTS.append((name, ok))
    say(f'==> {"PASS" if ok else "FAIL"}: {name} {detail}\n')


def mint(name):
    home = lab / name
    subprocess.run([str(root / 'bin/fm-lab-home.sh'), 'create', str(home)], check=True, capture_output=True)
    return home


def base_env(home):
    env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_OPEN_LOOPS_NOW=str(now),
               FM_SUPERVISION_ACTOR='main', FM_TEST_SEAM='1', FM_TEST_HARNESS='codex')
    for key in ('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
        env.pop(key, None)
    return env


class Home:
    def __init__(self, name, env_extra=None, row=None):
        self.home = mint(name)
        self.env = base_env(self.home)
        self.env.update(env_extra or {})
        self.ledger = self.home / 'state/open-loops.json'
        if row is not None:
            self.row = row
            self.ledger.write_text(json.dumps(dict(schema='fm-open-loops.v1', generated_epoch=now, complete=True,
                                                   rows=[row])))

    def at(self, stamp):
        self.env['FM_OPEN_LOOPS_NOW'] = str(stamp)

    def call(self, *args, label=None, quiet=False):
        r = subprocess.run([str(a) for a in args], env=self.env, text=True, capture_output=True, timeout=120)
        if not quiet:
            show(label or ' '.join(str(a).replace(str(code) + '/', '') for a in args), r)
        return r

    def wake(self, text):
        self.call('bash', '-c', WAKE % text, '_', code / 'bin/fm-wake-lib.sh', quiet=True)

    def drain(self, text='board report'):
        self.wake(text)
        r = self.call(code / 'bin/fm-wake-drain.sh', label='bin/fm-wake-drain.sh')
        m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', r.stderr)
        return r, m.groups()

    def ack(self, b):
        return self.call(code / 'bin/fm-wake-drain.sh', '--ack-through', b[0], '--recovery-generation', b[1],
                         label='bin/fm-wake-drain.sh --ack-through ... (acknowledge the drain)')

    def act(self, ident, kind, evidence, *extra):
        return self.call(code / 'bin/fm-open-loops.sh', 'action', ident, kind, '--evidence', evidence, *extra)

    def loops(self, *args):
        return self.call(code / 'bin/fm-open-loops.sh', *args)

    def stored(self):
        return json.loads(self.ledger.read_text())

    def inbox(self, task, record, sent, body='follow up'):
        p = self.home / 'state' / (task + '.inbox') / record
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f'schema=fm-task-inbox.v1\nat={iso(sent)}\n--\n{body}\n')


STALLED = dict(id='row-stalled', category='stalled_worker', subject='worker', owner='worker:worker',
               next_action='follow up on lint.full.whole', age_seconds=7200, limit_seconds=3600, overdue=True,
               evidence='waiting for lint.full.whole; declaration age 7200s')

# ---------------------------------------------------------------- S1 / M1
say('#### S1 (M1): a steer sent after the overdue episode began still counts when the unchanged row is re-presented')
h = Home('s1-steer', row=dict(STALLED))
_, b = h.drain()
h.inbox('worker', '001.msg', now + 1)
first = h.act('row-stalled', 'steered', '001.msg')
h.ack(b)
h.at(now + 600)
_, b = h.drain('again ten minutes later')
represented = h.ack(b)
again = h.act('row-stalled', 'steered', '001.msg')
acked = h.ack(b)
verdict('S1 same 001.msg accepted again on re-presentation, no new message needed',
        first.returncode == 0 and represented.returncode == 1 and again.returncode == 0 and acked.returncode == 0)
say('#### S1b (M1 adversarial): a delivery from before the episode, or older than four hours, is refused')
h.inbox('worker', '000.msg', now - 3700)
before = h.act('row-stalled', 'steered', '000.msg')
h.at(now + 5 * 3600)
stale = h.act('row-stalled', 'steered', '001.msg')
verdict('S1b pre-episode and >4h deliveries refused',
        before.returncode == 1 and 'became overdue' in before.stdout
        and stale.returncode == 1 and 'four hours' in stale.stdout)

say('#### S1c (M1): a firstmate-owned steer message shows the time left from the delivery, not a fixed 14400')
fm_row = dict(STALLED, id='row-fm', category='silent_report', subject='worker', owner='firstmate',
              next_action='check in: progress, blockers, cross-workstream dependencies', evidence='last heard')
h = Home('s1c-remaining', row=fm_row)
_, b = h.drain()
h.inbox('worker', '001.msg', now - 1200)
msg = h.act('row-fm', 'steered', '001.msg')
verdict('S1c message says 13200 seconds remain (delivery was 1200 s ago)',
        msg.returncode == 0 and 're-present after 13200 seconds' in msg.stdout)

# ---------------------------------------------------------------- S4 / M4
say('#### S4 (M4): a remote secondmate delivered pending-reply id is accepted as steered evidence')
h = Home('s4-remote', row=dict(fm_row, id='row-remote', subject='mini'))
_, b = h.drain()
d = h.home / 'state/pending-replies'
d.mkdir()
def reply(corr, task='mini', delivered=''):
    (d / corr).write_text(f'schema=fm-pending-reply.v1\ncorr_id={corr}\ntask_id={task}\ncreated_epoch={now}\n'
                          f'delivered_epoch={delivered}\nphase=awaiting_report\n')
reply('0123456789abcdef', delivered='')
undelivered = h.act('row-remote', 'steered', '0123456789abcdef')
reply('fedcba9876543210', task='other', delivered=str(now + 5))
foreign = h.act('row-remote', 'steered', 'fedcba9876543210')
reply('aabbccddeeff0011', delivered=str(now + 5))
accepted = h.act('row-remote', 'steered', 'aabbccddeeff0011')
ackd = h.ack(b)
verdict('S4 delivered id accepted and acknowledges; undelivered and foreign ids refused',
        undelivered.returncode == 1 and foreign.returncode == 1 and accepted.returncode == 0 and ackd.returncode == 0
        and h.stored()['handling']['actions']['row-remote']['evidence'] == 'aabbccddeeff0011')

# ---------------------------------------------------------------- S3 / M3
say('#### S3 (M3): printed captain_visible and the deferral refusal agree')
h = Home('s3-visibility', row=dict(STALLED, id='row-vis', category='red_check', subject='https://github.com/t/p/pull/9',
                                   owner='worker:worker', next_action='diagnose: code or test', limit_seconds=0))
_, b = h.drain()
d1 = h.act('row-vis', 'deferred', 'lint running', '--recheck', iso(now + 600))
h.ack(b)
repeat = h.act('row-vis', 'deferred', 'lint still running', '--recheck', iso(now + 900))
standing_ok = repeat.returncode == 1 and 'already stands' in repeat.stdout and 'captain-visible' not in repeat.stdout
h.at(now + 700)
r, b = h.drain('lapsed')
line = next(l for l in r.stdout.splitlines() if 'row-vis' in l and l.startswith('  '))
printed = line.rsplit(',', 1)[1]
second = h.act('row-vis', 'deferred', 'still running', '--recheck', iso(now + 1300))
stored_row = next(x for x in h.stored()['rows'] if x['id'] == 'row-vis')
verdict('S3 standing deferral refuses repeat without marking; after lapse printed=true, refusal, stored=true',
        d1.returncode == 0 and standing_ok and printed == 'true' and second.returncode == 1
        and 'second deferral refused' in second.stdout and stored_row['captain_visible'] is True,
        f'(printed captain_visible={printed})')

say('#### S3b (M3 adversarial): a deferral on review_pass_not_merged never stands, and printed/stored/refusal agree')
h = Home('s3b-review-pass', row=dict(STALLED, id='row-rp', category='review_pass_not_merged',
                                     subject='https://github.com/t/p/pull/10', owner='firstmate',
                                     next_action='merge through bin/fm-pr-merge.sh under AGENTS.md section 7'))
_, b = h.drain()
h.act('row-rp', 'deferred', 'awaiting slot', '--recheck', iso(now + 600))
h.ack(b)
h.at(now + 60)
r, b = h.drain('again')
line = next(l for l in r.stdout.splitlines() if 'row-rp' in l and l.startswith('  '))
printed = line.rsplit(',', 1)[1]
second = h.act('row-rp', 'deferred', 'awaiting slot', '--recheck', iso(now + 900))
verdict('S3b printed captain_visible=true and second deferral refused as captain-visible (no false "already stands")',
        printed == 'true' and second.returncode == 1 and 'already stands' not in second.stdout
        and 'second deferral refused' in second.stdout, f'(printed={printed})')

# ---------------------------------------------------------------- S2 / M2 (red PR waits on live task)
say('#### S2 (M2): a red PR row parked until another task merges is recorded as waiting on that named live task')
fake = lab / 'fakebin'
fake.mkdir()
def exe(p, t):
    p.write_text(t); p.chmod(0o755)
exe(fake / 'tmux', '''#!/usr/bin/env bash
if [ -e "$FM_HOME/session-gone" ]; then [ "$1" = list-windows ] && exit 0; exit 1; fi
case "$1" in list-windows) printf 'fm-repair-owner\\n' ;; display-message) printf '%%1\\n' ;;
  capture-pane) printf 'all quiet\\n' ;; *) exit 1 ;; esac
''')
exe(fake / 'no-mistakes', '#!/usr/bin/env bash\nexit 0\n')
shutil.copy2(code / 'bin/fm-fleet-snapshot.sh', code / 'bin/real-fleet-snapshot.sh')
exe(code / 'bin/fm-fleet-snapshot.sh', '''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
p = Path(__file__).parent
if sys.argv[1] == '--contribution-input':
    os.execv(str(p / 'real-fleet-snapshot.sh'), [str(p / 'real-fleet-snapshot.sh'), *sys.argv[1:]])
snap = json.loads(subprocess.check_output([str(p / 'real-fleet-snapshot.sh'), '--contribution-input']))
for t in snap['tasks']:
    t.update(current_state={'state': 'working', 'source': 'status-log'},
             endpoint={'exists': True, 'agent_alive': 'alive'}, paths={'worktree': {'path': None}}, hints={})
snap['schema'] = 'fm-fleet-home-input.v1'
print(json.dumps(snap))
''')
exe(code / 'bin/fm-gh-rest.sh', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
h = Path(os.environ['FM_HOME'])
p = json.loads((h / 'forge.json').read_text())
url = sys.argv[2]
if '/pulls?' in url: value = [p]
elif '/check-runs' in url and (h / 'checks-green').exists():
    value = {'check_runs': [{'name': 'ci', 'status': 'completed', 'conclusion': 'success',
                             'completed_at': '2026-10-28T00:00:00Z', 'id': 1, 'app': {'id': 1}}]}
elif '/check-runs' in url:
    value = {'check_runs': [{'name': 'Behavior portable serial 17', 'status': 'completed', 'conclusion': 'failure',
                             'completed_at': '2026-10-28T00:00:00Z', 'id': 1, 'app': {'id': 1}}]}
elif '/statuses?' in url: value = []
elif '/reviews' in url or '/comments' in url: value = []
else: value = {}
print(json.dumps([value]))
''')
PR = 'https://github.com/test/project/pull/283'
REASON = 'PR 283 is red because main is red; worker parked until fm-test-serial-shard-rebalance merges'


class Fleet(Home):
    def __init__(self, name, green=False):
        super().__init__(name, env_extra=dict(FM_ROOT_OVERRIDE='', NM_HOME=str(lab / 'nm'),
                                              PATH=str(fake) + os.pathsep + os.environ['PATH']))
        self.env['FM_ROOT_OVERRIDE'] = str(self.home)
        st = self.home / 'state'
        (self.home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        if green:
            (self.home / 'checks-green').write_text('')
        (self.home / 'forge.json').write_text(json.dumps(dict(html_url=PR, number=283, state='open', draft=False,
                                                              head={'sha': 'a' * 40}, updated_at=iso(now - 7200))))
        (st / 'parked-job.meta').write_text(f'kind=ship\nspawn_gen=s-parked\npr={PR}\n')
        (st / 'parked-job.status').write_text(f'working [at={now}]: parked on purpose until shard fix merges\n')
        tree = lab / ('tree-' + name)
        subprocess.run(['git', 'init', '-q', '-b', 'fm/fm-test-serial-shard-rebalance', str(tree)], check=True)
        subprocess.run(['git', '-C', str(tree), '-c', 'user.name=t', '-c', 'user.email=t@e.invalid', 'commit', '-q',
                        '--allow-empty', '-m', 'fixture'], check=True)
        self.meta = (f'kind=ship\nspawn_gen=s-repair\nworktree={tree}\nharness=claude\n'
                     'window=fm:fm-repair-owner\n')
        (st / 'fm-test-serial-shard-rebalance.meta').write_text(self.meta)
        self.working = f'working [at={now}]: fixing the red main\n'
        (st / 'fm-test-serial-shard-rebalance.status').write_text(self.working)
        self.call(code / 'bin/fm-busy-event.sh', 'arm', st, 'fm-test-serial-shard-rebalance', quiet=True)
        self.activity('busy')

    def activity(self, s):
        self.call(code / 'bin/fm-busy-event.sh', 'apply', self.home / 'state', 'fm-test-serial-shard-rebalance', s,
                  '--current-gen', '--source', 'claude-hook', '--event', 'fixture', quiet=True)

    def publish(self):
        stamp = int(self.env['FM_OPEN_LOOPS_NOW'])
        for p in (self.home / 'state').glob('*.status'):
            os.utime(p, (stamp, stamp))
        return json.loads(self.call(code / 'bin/fm-open-loops.sh', '--heartbeat', '--json', quiet=True).stdout)

    def wait(self, task='fm-test-serial-shard-rebalance', recheck=3600):
        return self.act(self.red['id'], 'waiting', REASON, '--prerequisite-task', task, '--recheck', iso(now + recheck))


def fleet(name):
    f = Fleet(name)
    f.red = next(r for r in f.publish()['rows'] if r['subject'] == PR)
    return f

f = fleet('s2-live')
say(f'published row: category={f.red["category"]} owner={f.red["owner"]} id={f.red["id"]}')
_, b = f.drain()
w = f.wait()
a1 = f.ack(b)
_, b = f.drain('next drain')
a2 = f.ack(b)
chk = f.loops('--check-actions')
verdict('S2 wait recorded on live task; it stands across a later drain and --check-actions is satisfied',
        w.returncode == 0 and a1.returncode == 0 and a2.returncode == 0 and chk.returncode == 0)

say('#### S2b (M2): the row resurfaces when the prerequisite merges')
f = fleet('s2b-merged'); _, b = f.drain(); f.wait(); f.ack(b)
st = f.home / 'state'
(st / 'fm-test-serial-shard-rebalance.meta').write_text(f.meta + 'pr=https://github.com/test/project/pull/290\n')
before = f.loops('--check-actions')
(st / 'fm-test-serial-shard-rebalance.pr-poll-merge-notified').write_text(
    'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\ntest/project\n290\n')
after = f.loops('--check-actions')
_, b = f.drain('after merge')
needs = f.ack(b)
verdict('S2b wait stands before merge, then --check-actions exits 1 and ack is refused after merge',
        before.returncode == 0 and after.returncode == 1 and needs.returncode == 1)

say('#### S2c (M2): the row resurfaces when the prerequisite fails')
f = fleet('s2c-failed'); _, b = f.drain(); f.wait(); f.ack(b)
(f.home / 'state/fm-test-serial-shard-rebalance.status').write_text(f'failed [at={now}]: tests still red\n')
f.activity('idle')
failed = f.loops('--check-actions')
verdict('S2c --check-actions exits 1 after prerequisite fails', failed.returncode == 1)

say('#### S2d (M2): the row resurfaces when the prerequisite stalls')
f = fleet('s2d-stalled'); _, b = f.drain(); f.wait(); f.ack(b)
led = f.stored()
led['rows'].append(dict(id='stalled-repair', category='stalled_worker', subject='fm-test-serial-shard-rebalance',
                        owner='worker:fm-test-serial-shard-rebalance', next_action='follow up', age_seconds=7200,
                        limit_seconds=3600, overdue=True, evidence='no progress'))
f.ledger.write_text(json.dumps(led))
stalled = f.loops('--check-actions')
verdict('S2d --check-actions exits 1 after prerequisite gets an overdue stalled_worker row', stalled.returncode == 1)

say('#### S2e (M2 adversarial): a wait on a task that is not live is refused')
f = fleet('s2e-refuse'); _, b = f.drain()
(f.home / 'session-gone').write_text('')
f.activity('idle')
gone = f.wait()
missing = f.wait(task='no-such-task')
own = f.wait(task='parked-job')
(f.home / 'session-gone').unlink()
(f.home / 'state/fm-test-serial-shard-rebalance.status').write_text(f.working + f'done [at={now}]: findings reported\n')
done = f.wait()
verdict('S2e dead session, unknown task, own task, and done-with-no-PR task are all refused',
        gone.returncode == 1 and 'not live' in gone.stdout and missing.returncode == 1
        and own.returncode == 1 and 'distinct' in own.stdout and done.returncode == 1 and 'done with no PR' in done.stdout)

say('#### S2f (M2 adversarial): the wait never stands past its recheck')
f = fleet('s2f-recheck'); _, b = f.drain(); f.wait(recheck=600); f.ack(b)
f.at(now + 600)
due = f.loops('--check-actions')
verdict('S2f --check-actions exits 1 once the recheck is due', due.returncode == 1)

# ---------------------------------------------------------------- S5 / M5
say('#### S5 (M5): a green PR row with no review requested points at AGENTS.md section 7, never asks for approval')
g = Fleet('s5-green', green=True)
rep = g.publish()
row = next(r for r in rep['rows'] if r['subject'] == PR)
say(f'published row: category={row["category"]} owner={row["owner"]} next_action={row["next_action"]!r}')
txt = g.loops()
na = [r['next_action'] for r in rep['rows']]
verdict('S5 open_pr next_action names AGENTS.md section 7 and no row says approval',
        row['category'] == 'open_pr' and row['owner'] == 'firstmate' and 'AGENTS.md section 7' in row['next_action']
        and not any('approv' in n.lower() for n in na))

# ---------------------------------------------------------------- S6 / M6
say('#### S6 (M6): a row nobody handled still goes overdue and is re-presented on every drain')
h = Home('s6-unhandled', row=dict(STALLED, id='row-unhandled'))
r1, b = h.drain()
n1 = h.ack(b)
chk = h.loops('--check-actions')
h.at(now + 600)
r2, b = h.drain('later')
n2 = h.ack(b)
verdict('S6 overdue row printed on both drains; ack refused and --check-actions exits 1 while unanswered',
        'row-unhandled' in r1.stdout and 'row-unhandled' in r2.stdout and n1.returncode == 1 and n2.returncode == 1
        and chk.returncode == 1)

say('SUMMARY')
for name, ok in RESULTS:
    say(f'  {"PASS" if ok else "FAIL"}  {name}')
sys.exit(0 if all(ok for _, ok in RESULTS) else 1)
