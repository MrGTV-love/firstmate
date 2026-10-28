#!/usr/bin/env python3
"""Live driver: run the real open-work ledger CLI in fresh marked lab homes, new code and base code side by side."""
import datetime as dt, json, os, re, subprocess, sys, time, tempfile
from pathlib import Path

WT = Path(sys.argv[1])
OUT = Path(sys.argv[2])
CODES = dict(new=Path('/tmp/fm-live-driver/code-new/bin'), old=Path('/tmp/fm-live-driver/code-old/bin'))
log = open(OUT, 'w')
homes = []
results = {}
iso = lambda s: dt.datetime.fromtimestamp(s, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def say(text=''):
    print(text, file=log, flush=True)


def mint():
    d = tempfile.mkdtemp(prefix='fm-lab.', dir='/tmp')
    path = subprocess.run([str(WT / 'bin/fm-lab-home.sh'), 'create', d], text=True, capture_output=True, check=True)
    home = Path(path.stdout.strip())
    homes.append(home)
    return home


class Home:
    def __init__(self, code, label):
        self.code, self.home, self.clock = CODES[code], mint(), None
        self.label = f'[{code}] {label}'
        self.env = {k: v for k, v in os.environ.items() if not k.endswith('_OVERRIDE')}
        self.env.update(FM_HOME=str(self.home), FM_SUPERVISION_ACTOR='main', NM_HOME=str(self.home / 'nm'))
        say(f'\n===== {self.label}  FM_HOME={self.home}')

    def run(self, *args, quiet=False):
        env = dict(self.env)
        if self.clock is not None:
            env['FM_OPEN_LOOPS_NOW'] = str(self.clock)
        shown = ' '.join(str(a).replace(str(self.code), '$BIN') for a in args)
        r = subprocess.run([str(a) for a in args], env=env, text=True, capture_output=True, timeout=180)
        if not quiet:
            say(f'$ {shown}' + (f'   # clock=+{self.clock - T0}s' if self.clock else ''))
            for line in (r.stdout + r.stderr).strip().splitlines()[:14]:
                say('  | ' + line)
            say(f'  -> exit {r.returncode}')
        return r

    def bin(self, name, *args, **kw):
        return self.run(self.code / name, *args, **kw)

    def seed(self, **fields):
        row = dict(id='row-' + re.sub(r'\W', '', self.label)[:20], category='stalled_worker', subject='worker',
                   owner='worker:worker', next_action='follow up on lint.full.whole', age_seconds=7200,
                   limit_seconds=3600, overdue=True, evidence='waiting for lint.full.whole; declaration age 7200s')
        row.update(fields)
        (self.home / 'state/open-loops.json').write_text(json.dumps(dict(
            schema='fm-open-loops.v1', generated_epoch=int(time.time()), complete=True, rows=[row])))
        self.row = row
        return row

    def wake(self, label):
        return self.run('bash', '-c', f'. "$1"; fm_wake_append check report "check: {label}"', '_',
                        self.code / 'fm-wake-lib.sh', quiet=True)

    def drain(self):
        r = self.bin('fm-wake-drain.sh')
        m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', r.stderr)
        return r, (m.groups() if m else None)

    def ack(self, b):
        return self.bin('fm-wake-drain.sh', '--ack-through', b[0], '--recovery-generation', b[1])

    def act(self, kind, evidence, *extra):
        return self.bin('fm-open-loops.sh', 'action', self.row['id'], kind, '--evidence', evidence, *extra)

    def inbox(self, record, at, task='worker'):
        p = self.home / 'state' / (task + '.inbox') / record
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f'schema=fm-task-inbox.v1\nat={iso(at)}\n--\nfollow up on lint\n')
        say(f'# wrote {task}.inbox/{record} at={iso(at)}')

    def stored(self):
        return json.loads((self.home / 'state/open-loops.json').read_text())


def printed_visible(r, ident):
    lines = [l for l in r.stdout.splitlines() if ident in l and l.startswith('  ')]
    return lines[0].rsplit(',', 1)[1] if lines else None


def record(name, code, value):
    results.setdefault(name, {})[code] = value
    say(f'>>> RESULT {name} [{code}]: {value}')


T0 = int(time.time())
ONLY = os.environ.get('ONLY')

# S1: re-presented steer
for code in ('new', 'old'):
    h = Home(code, 'S1 re-presented steer')
    h.seed()
    h.wake('first'); _, b = h.drain()
    time.sleep(1)
    h.inbox('001.msg', int(time.time()))
    first = h.act('steered', '001.msg')
    h.ack(b)
    time.sleep(2)
    h.wake('again'); _, b = h.drain()
    gate = h.ack(b)
    again = h.act('steered', '001.msg')
    acked = h.ack(b)
    record('S1 steer re-presented', code, dict(first=first.returncode, ack_without_action=gate.returncode,
                                                re_steer_same_record=again.returncode, ack_after=acked.returncode))

# S1b adversarial steers (new code only)
h = Home('new', 'S1b steer guards')
h.seed()
h.wake('first'); _, b = h.drain()
h.inbox('002.msg', int(time.time()) - 120)
before = h.act('steered', '002.msg')
h.inbox('001.msg', int(time.time()) + 1)
time.sleep(2)
ok = h.act('steered', '001.msg'); h.ack(b)
data = h.stored(); data['rows'][0]['evidence'] = 'waiting for lint.full.whole and a new failing step'
(h.home / 'state/open-loops.json').write_text(json.dumps(data)); h.row = data['rows'][0]
say('# row evidence changed materially')
time.sleep(1)
h.wake('changed'); _, b = h.drain()
changed = h.act('steered', '001.msg')
h.clock = int(time.time()) + 5 * 3600
h.inbox('003.msg', int(time.time()) + 2)
old4h = h.act('steered', '003.msg')
h.clock = None
record('S1b steer guards', 'new', dict(before_episode=before.returncode, after_episode=ok.returncode,
                                       after_changed_evidence=changed.returncode, older_than_4h=old4h.returncode))

# S2: remote secondmate pending-reply id
for code in ('new', 'old'):
    h = Home(code, 'S2 remote delivery id')
    h.seed(category='silent_report', subject='mini', owner='firstmate',
           next_action='check in: progress, blockers, cross-workstream dependencies', evidence='last heard')
    h.wake('first'); _, b = h.drain()
    d = h.home / 'state/pending-replies'; d.mkdir(exist_ok=True)

    def reply(corr, task='mini', delivered=''):
        (d / corr).write_text(f'schema=fm-pending-reply.v1\ncorr_id={corr}\ntask_id={task}\n'
                              f'created_epoch={int(time.time())}\ndelivered_epoch={delivered}\nphase=awaiting_report\n')
        say(f'# wrote pending-replies/{corr} task_id={task} delivered_epoch={delivered or "(unset)"}')
    time.sleep(1)
    reply('0123456789abcdef')
    undelivered = h.act('steered', '0123456789abcdef')
    reply('fedcba9876543210', task='other', delivered=str(int(time.time())))
    foreign = h.act('steered', 'fedcba9876543210')
    reply('aabbccddeeff0011', delivered=str(int(time.time())))
    accepted = h.act('steered', 'aabbccddeeff0011')
    (d / '2211221122112211').symlink_to(d / 'aabbccddeeff0011'); say('# symlinked 2211221122112211 -> aabbccddeeff0011')
    linked = h.act('steered', '2211221122112211')
    acked = h.ack(b)
    record('S2 remote delivery id', code, dict(undelivered=undelivered.returncode, foreign=foreign.returncode,
                                               delivered=accepted.returncode, symlink=linked.returncode,
                                               ack=acked.returncode))

# S3: captain_visible consistency after a lapsed deferral
for code in ('new', 'old'):
    h = Home(code, 'S3 visibility')
    h.seed()
    h.wake('first'); _, b = h.drain()
    base = int(time.time())
    first = h.act('deferred', 'lint running', '--recheck', iso(base + 600))
    repeat = h.act('deferred', 'lint still running', '--recheck', iso(base + 900))
    standing = h.bin('fm-open-loops.sh', '--check-actions')
    h.ack(b)
    h.clock = base + 700
    h.wake('lapsed'); r, b = h.drain()
    shown = printed_visible(r, h.row['id'])
    second = h.act('deferred', 'still running', '--recheck', iso(base + 1300))
    stored = h.stored()['rows'][0].get('captain_visible')
    gate = h.bin('fm-open-loops.sh', '--check-actions')
    esc = h.act('escalated', 'lint wedged; needs a look')
    gate2 = h.bin('fm-open-loops.sh', '--check-actions')
    h.clock = None
    record('S3 visibility', code, dict(first_defer=first.returncode, repeat_while_standing=repeat.returncode,
                                       repeat_msg=(repeat.stdout.strip().splitlines() or [''])[-1][:110],
                                       check_actions_while_standing=standing.returncode,
                                       printed_after_lapse=shown, second_defer=second.returncode,
                                       stored_visible=stored, check_actions=gate.returncode,
                                       after_escalation=gate2.returncode))

# S3c: the exact reported sequence: one deferral, it lapses, the row is printed, then a second deferral.
for code in ('new', 'old'):
    h = Home(code, 'S3c visibility, no repeat')
    h.seed()
    h.wake('first'); _, b = h.drain()
    base = int(time.time())
    h.act('deferred', 'lint running', '--recheck', iso(base + 600))
    h.ack(b)
    h.clock = base + 700
    h.wake('lapsed'); r, b = h.drain()
    shown = printed_visible(r, h.row['id'])
    second = h.act('deferred', 'still running', '--recheck', iso(base + 1300))
    h.clock = None
    record('S3c printed vs refusal', code, dict(printed_captain_visible=shown, second_defer=second.returncode,
                                               msg=(second.stdout.strip().splitlines() or [''])[-1][:120]))

# S6: a row nobody handles still blocks acknowledgement and stays overdue
for code in ('new',):
    h = Home(code, 'S6 unhandled row still surfaces')
    h.seed()
    h.wake('first'); r, b = h.drain()
    presented = h.row['id'] in r.stdout
    a1 = h.ack(b)
    ca = h.bin('fm-open-loops.sh', '--check-actions')
    rep = h.bin('fm-open-loops.sh', '--report')
    record('S6 unhandled row', code, dict(presented=presented, ack=a1.returncode, check_actions=ca.returncode,
                                          in_report=h.row['id'] in rep.stdout))
    # A steer older than the episode never answers a re-presentation.
    h.inbox('009.msg', int(time.time()) - 3600)
    st = h.act('steered', '009.msg')
    record('S6 old steer cannot clear it', code, st.returncode)

json.dump(results, open(str(OUT) + '.json', 'w'), indent=1)
say('\nHOMES ' + ' '.join(map(str, homes)))
print(json.dumps(results, indent=1))
print('HOMES', ' '.join(map(str, homes)))
