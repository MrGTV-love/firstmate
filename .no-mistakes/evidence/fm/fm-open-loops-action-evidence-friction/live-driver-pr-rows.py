#!/usr/bin/env python3
"""Live driver part 2: PR rows from a real collection (local forge stand-in), real lab tmux, real busy events."""
import datetime as dt, json, os, re, subprocess, sys, time, tempfile
from pathlib import Path

WT, OUT = Path(sys.argv[1]), Path(sys.argv[2])
CODES = dict(new=Path('/tmp/fm-live-driver/code-new/bin'), old=Path('/tmp/fm-live-driver/code-old/bin'))
log = open(OUT, 'w')
homes, results = [], {}
iso = lambda s: dt.datetime.fromtimestamp(s, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
NOW = int(time.time())
REASON = 'PR is red because main is red; parked until repair-owner merges'


def say(t=''):
    print(t, file=log, flush=True)


def record(name, code, value):
    results.setdefault(name, {})[code] = value
    say(f'>>> RESULT {name} [{code}]: {value}')


class Home:
    def __init__(self, code, label, pr_number, checks, extra_tasks=True):
        self.code = CODES[code]
        d = tempfile.mkdtemp(prefix='fm-lab.', dir='/tmp')
        self.home = Path(subprocess.run([str(WT / 'bin/fm-lab-home.sh'), 'create', d], text=True,
                                        capture_output=True, check=True).stdout.strip())
        homes.append(self.home)
        self.label = f'[{code}] {label}'
        self.env = {k: v for k, v in os.environ.items() if not k.endswith('_OVERRIDE')}
        self.env.update(FM_HOME=str(self.home), FM_SUPERVISION_ACTOR='main', NM_HOME=str(self.home / 'nm'))
        self.clock = None
        say(f'\n===== {self.label}  FM_HOME={self.home}')
        st = self.home / 'state'
        (self.home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        self.pr = f'https://github.com/test/project/pull/{pr_number}'
        (self.home / 'forge.json').write_text(json.dumps(dict(
            pr=dict(html_url=self.pr, number=pr_number, state='open', draft=False, head={'sha': 'a' * 40},
                    updated_at=iso(NOW - 7200), requested_reviewers=[], requested_teams=[]),
            checks=checks)))
        trees = {}
        for task in ('parked-job', 'repair-owner'):
            origin = Path(tempfile.mkdtemp(prefix='fm-live-origin.', dir='/tmp'))
            subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(origin)], check=True)
            seed = Path(tempfile.mkdtemp(prefix='fm-live-seed.', dir='/tmp'))
            subprocess.run(['git', 'clone', '-q', str(origin), str(seed / 'c')], check=True, capture_output=True)
            subprocess.run(['git', '-C', str(seed / 'c'), 'commit', '-q', '--allow-empty', '-m', 'base'], check=True)
            subprocess.run(['git', '-C', str(seed / 'c'), 'push', '-q', 'origin', 'HEAD:main'], check=True)
            tree = Path(tempfile.mkdtemp(prefix='fm-live-tree.', dir='/tmp')) / 'w'
            subprocess.run(['git', 'clone', '-q', str(origin), str(tree)], check=True, capture_output=True)
            subprocess.run(['git', '-C', str(tree), 'checkout', '-q', '-b', 'fm/' + task], check=True)
            trees[task] = tree
        (st / 'parked-job.meta').write_text(f'kind=ship\nspawn_gen=s-parked\nworktree={trees["parked-job"]}\n'
                                            f'harness=claude\nwindow=fm:fm-parked-job\npr={self.pr}\n')
        (st / 'parked-job.status').write_text(f'working [at={NOW}]: parked on purpose until repair-owner merges\n')
        self.meta = (f'kind=ship\nspawn_gen=s-repair\nworktree={trees["repair-owner"]}\nharness=claude\n'
                     'window=fm:fm-repair-owner\n')
        (st / 'repair-owner.meta').write_text(self.meta)
        (st / 'repair-owner.status').write_text(f'working [at={NOW}]: fixing the red main\n')
        self.bin('fm-busy-event.sh', 'arm', st, 'repair-owner', quiet=True)
        self.activity('busy')

    def run(self, *args, quiet=False):
        env = dict(self.env)
        if self.clock is not None:
            env['FM_OPEN_LOOPS_NOW'] = str(self.clock)
        r = subprocess.run([str(a) for a in args], env=env, text=True, capture_output=True, timeout=240)
        if not quiet:
            shown = ' '.join(str(a).replace(str(self.code), '$BIN') for a in args)
            say(f'$ {shown}' + (f'   # clock=+{self.clock - NOW}s' if self.clock else ''))
            for line in (r.stdout + r.stderr).strip().splitlines()[:14]:
                say('  | ' + line[:220])
            say(f'  -> exit {r.returncode}')
        return r

    def bin(self, name, *args, **kw):
        return self.run(self.code / name, *args, **kw)

    def activity(self, state):
        r = self.bin('fm-busy-event.sh', 'apply', self.home / 'state', 'repair-owner', state, '--current-gen',
                     '--source', 'claude-hook', '--event', 'live', quiet=True)
        say(f'# repair-owner harness hook event: {state} (exit {r.returncode})')

    def publish(self):
        r = self.bin('fm-open-loops.sh', '--heartbeat', '--json', quiet=True)
        say('$ $BIN/fm-open-loops.sh --heartbeat --json   -> exit %d' % r.returncode)
        report = json.loads(r.stdout)
        for row in report['rows']:
            say(f'  | row {row["category"]:<24} owner={row["owner"]:<22} subject={row["subject"]}')
            say(f'  |     next_action={row["next_action"]!r} overdue={row.get("overdue")}')
        return report

    def drain(self):
        self.run('bash', '-c', '. "$1"; fm_wake_append check report "check: dependency followup"', '_',
                 self.code / 'fm-wake-lib.sh', quiet=True)
        r = self.bin('fm-wake-drain.sh')
        m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', r.stderr)
        overdue = r.stdout.split('STANDING')[0]
        for ident in re.findall(r'^  "([0-9a-f]+)","firstmate","ledger degraded"', overdue, re.M):
            say('# fixture degradation row: escalate it truthfully so it does not mask the row under test')
            self.bin('fm-open-loops.sh', 'action', ident, 'escalated', '--evidence', 'lab fixture: worker liveness of a sleep pane is inconclusive')
        return r, (m.groups() if m else None)

    def ack(self, b):
        return self.bin('fm-wake-drain.sh', '--ack-through', b[0], '--recovery-generation', b[1])

    def wait(self, ident, task='repair-owner', recheck=3600):
        return self.bin('fm-open-loops.sh', 'action', ident, 'waiting', '--evidence', REASON,
                        '--prerequisite-task', task, '--recheck', iso(int(time.time()) + recheck))

    def check(self):
        return self.bin('fm-open-loops.sh', '--check-actions').returncode


RED = [{'name': 'Behavior portable serial 17', 'status': 'completed', 'conclusion': 'failure',
        'completed_at': iso(NOW - 7200), 'id': 1, 'app': {'id': 1}}]
GREEN = [{'name': 'Behavior', 'status': 'completed', 'conclusion': 'success',
          'completed_at': iso(NOW - 7200), 'id': 2, 'app': {'id': 1}}]

# S4: a green PR's next_action
for code in ('new', 'old'):
    h = Home(code, 'S4 green PR next action', 284, GREEN)
    rep = h.publish()
    rows = [r for r in rep['rows'] if r['subject'] == h.pr]
    record('S4 green PR next_action', code, [(r['category'], r['next_action']) for r in rows])

# S5: red PR wait on a named live task
for code in ('new', 'old'):
    h = Home(code, 'S5 red PR waits on live task', 283, RED)
    rep = h.publish()
    red = next((r for r in rep['rows'] if r['subject'] == h.pr and r['category'] == 'red_check'), None)
    if red is None:
        record('S5 red PR wait', code, 'no red_check row collected'); continue
    _, b = h.drain()
    w = h.wait(red['id'])
    out = dict(record_wait=w.returncode, msg=(w.stdout.strip().splitlines() or [''])[-1][:110])
    if w.returncode == 0:
        out['ack'] = h.ack(b).returncode
        _, b = h.drain()
        out['ack_next_turn'] = h.ack(b).returncode
        out['still_in_report'] = red['id'] in h.bin('fm-open-loops.sh', '--report').stdout
        h.clock = NOW + 3700
        out['check_after_recheck_due'] = h.check()
        h.clock = None
    record('S5 red PR wait', code, out)


def waiting(label):
    h = Home('new', label, 283, RED)
    red = next(r for r in h.publish()['rows'] if r['category'] == 'red_check')
    _, b = h.drain()
    assert h.wait(red['id']).returncode == 0
    assert h.ack(b).returncode == 0
    before = h.check()
    return h, red, before


h, red, before = waiting('S5a prerequisite merges')
(h.home / 'state/repair-owner.meta').write_text(h.meta + 'pr=https://github.com/test/project/pull/290\n')
(h.home / 'state/repair-owner.pr-poll-merge-notified').write_text(
    'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\ntest/project\n290\n')
say('# recorded merge of repair-owner PR 290')
record('S5a resurfaces on merge', 'new', dict(before=before, after=h.check()))

h, red, before = waiting('S5b prerequisite fails')
(h.home / 'state/repair-owner.status').write_text(f'failed [at={int(time.time())}]: tests still red\n')
h.activity('idle')
record('S5b resurfaces on failure', 'new', dict(before=before, after=h.check()))

h, red, before = waiting('S5c prerequisite stalls')
led = json.loads((h.home / 'state/open-loops.json').read_text())
led['rows'].append(dict(id='stalled-repair', category='stalled_worker', subject='repair-owner',
                        owner='worker:repair-owner', next_action='follow up', age_seconds=7200, limit_seconds=3600,
                        overdue=True, evidence='no progress'))
(h.home / 'state/open-loops.json').write_text(json.dumps(led))
say('# published ledger now carries an overdue stalled_worker row for repair-owner')
record('S5c resurfaces on stall', 'new', dict(before=before, after=h.check()))

h, red, before = waiting('S5d prerequisite replaced')
(h.home / 'state/repair-owner.meta').write_text(h.meta.replace('s-repair', 's-replacement'))
say('# repair-owner relaunched with a new spawn generation')
record('S5d resurfaces on replacement', 'new', dict(before=before, after=h.check()))

h = Home('new', 'S5e refuse a prerequisite that is not live', 283, RED)
red = next(r for r in h.publish()['rows'] if r['category'] == 'red_check')
_, b = h.drain()
h.activity('idle')
idle = h.wait(red['id'])
missing = h.wait(red['id'], task='no-such-task')
own = h.wait(red['id'], task='parked-job')
far = None
h.activity('busy')
far = h.bin('fm-open-loops.sh', 'action', red['id'], 'waiting', '--evidence', REASON, '--prerequisite-task',
            'repair-owner', '--recheck', iso(int(time.time()) + 30 * 3600))
stored = json.loads((h.home / 'state/open-loops.json').read_text()).get('handling', {}).get('actions', {})
record('S5e refusals', 'new', dict(idle=idle.returncode, idle_msg=idle.stdout.strip()[-100:],
                                    missing=missing.returncode, self_task=own.returncode,
                                    recheck_30h=far.returncode, ack_without_action=h.ack(b).returncode))

json.dump(results, open(str(OUT) + '.json', 'w'), indent=1)
say('\nHOMES ' + ' '.join(map(str, homes)))
print(json.dumps(results, indent=1))
print('HOMES', ' '.join(map(str, homes)))
