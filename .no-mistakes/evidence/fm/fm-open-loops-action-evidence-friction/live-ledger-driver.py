#!/usr/bin/env python3
"""Live driver for the open-work ledger action verbs (fm-open-loops-action-evidence-friction).

Usage: live-ledger-driver.py BIN_DIR WORK_DIR LABEL
Copies BIN_DIR into WORK_DIR, builds disposable FM_HOMEs there, and drives the real
bin/fm-open-loops.sh and bin/fm-wake-drain.sh. Only tmux, no-mistakes and the forge read
are stand-ins (external tools). Prints a transcript; never asserts, so the same script
can be run against the base commit's bin to show the old behaviour.
"""
import datetime as dt, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

bin_src, world, label = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
code = world / 'code'
shutil.copytree(bin_src, code / 'bin')
now = int(time.time())
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
WAKE = '. "$1"; fm_wake_append check report "check: %s"'
LOOPS = code / 'bin/fm-open-loops.sh'
DRAIN = code / 'bin/fm-wake-drain.sh'
results = []

def say(text=''):
    print(text, flush=True)

def show(step, result):
    out = (result.stdout or '').strip().replace(str(world), '<work>')
    say(f'  $ {step}\n    exit={result.returncode}')
    for line in out.splitlines()[:6]:
        say('    | ' + line[:230])
    return result

def verdict(name, good):
    results.append((name, good))
    say(f'  ==> {"PASS" if good else "FAIL"}: {name}\n')

class Home:
    def __init__(self, name, extra_env=None, rows=None, **fields):
        self.home = world / ('home-' + name)
        for d in ('state', 'config', 'data', 'projects'):
            (self.home / d).mkdir(parents=True)
        self.clock = now
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(self.home),
                        FM_SUPERVISION_ACTOR='main', FM_TEST_SEAM='1', FM_TEST_HARNESS='codex')
        for k in ('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE',
                  'NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS'):
            self.env.pop(k, None)
        self.env.update(extra_env or {})
        self.ledger = self.home / 'state/open-loops.json'
        if rows is None:
            row = dict(id='row-' + name, category='stalled_worker', subject='worker', owner='worker:worker',
                       next_action='follow up on lint.full.whole', age_seconds=7200, limit_seconds=3600,
                       overdue=True, evidence='waiting for lint.full.whole; declaration age 7200s')
            row.update(fields)
            self.row = row
            self.ledger.write_text(json.dumps(dict(schema='fm-open-loops.v1', generated_epoch=now,
                                                   complete=True, rows=[row])))
    def call(self, *args):
        return subprocess.run([str(a) for a in args], env=dict(self.env, FM_OPEN_LOOPS_NOW=str(self.clock)),
                              text=True, capture_output=True, timeout=180)
    def wake(self, text='board report'):
        self.call('bash', '-c', WAKE % text, '_', code / 'bin/fm-wake-lib.sh')
    def drain(self):
        self.wake()
        r = self.call(DRAIN)
        m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', r.stderr)
        return r, (m.groups() if m else None)
    def ack(self, b):
        return self.call(DRAIN, '--ack-through', b[0], '--recovery-generation', b[1])
    def act(self, rid, kind, evidence, *extra):
        return self.call(LOOPS, 'action', rid, kind, '--evidence', evidence, *extra)
    def inbox(self, record, offset, task='worker'):
        p = self.home / 'state' / (task + '.inbox') / record
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f'schema=fm-task-inbox.v1\nat={iso(self.clock + offset)}\n--\nfollow up\n')
    def stored(self):
        return json.loads(self.ledger.read_text())

say(f'#### open-work ledger live driver: {label}  (now={iso(now)})\n')

# --- S1 / intent 1 / M1 ------------------------------------------------------------
say('## S1a  A steer sent minutes before the drain re-presents an unchanged reviewed green PR row still counts')
PR = 'https://github.com/test/project/pull/9'
h = Home('s1a', category='review_pass_not_merged', subject=PR, owner='firstmate', source=dict(task='worker'),
         limit_seconds=600, next_action='merge through bin/fm-pr-merge.sh', evidence='PASS on head')
_, b = h.drain()
h.inbox('001.msg', 1)
show('action <row> steered --evidence 001.msg', h.act(h.row['id'], 'steered', '001.msg'))
show('fm-wake-drain.sh --ack-through ...', h.ack(b))
h.clock = now + 120
_, b = h.drain()
same = show('(t+120s, row re-presented) action <row> steered --evidence 001.msg  # the SAME message, no new one',
            h.act(h.row['id'], 'steered', '001.msg'))
same_ack = show('fm-wake-drain.sh --ack-through ...', h.ack(b))
verdict('S1a-same re-presented row accepts the steer it already had, no re-steer', same.returncode == 0
        and same_ack.returncode == 0)
h.clock = now + 300
_, b = h.drain()
h.inbox('002.msg', -30)  # sent 30 s before this re-presentation
r = show('(t+300s, re-presented again) action <row> steered --evidence 002.msg  # sent 30 s before this re-presentation',
         h.act(h.row['id'], 'steered', '002.msg'))
a = show('fm-wake-drain.sh --ack-through ...', h.ack(b))
verdict('S1a steer sent minutes before re-presentation accepted, no new message needed',
        r.returncode == 0 and a.returncode == 0)

say('## S1b  The same unchanged stalled row, already steered, needs no second message when re-presented')
h = Home('s1b')
_, b = h.drain()
h.inbox('001.msg', 1)
show('action <row> steered --evidence 001.msg', h.act(h.row['id'], 'steered', '001.msg'))
show('ack', h.ack(b))
h.clock = now + 120
_, b = h.drain()
a = show('(t+120s, re-presented) ack with no new action', h.ack(b))
c = show('fm-open-loops.sh --check-actions', h.call(LOOPS, '--check-actions'))
verdict('S1b an unchanged steered row is still covered on re-presentation', a.returncode == 0 and c.returncode == 0)

say('## S1c  (guard) A steer sent before the row went overdue, or older than four hours, is refused')
h = Home('s1c', age_seconds=100000)
_, b = h.drain()
h.inbox('001.msg', 1)
h.inbox('002.msg', -96500)  # before the overdue moment (now - 100000 + 3600)
r1 = show('action <row> steered --evidence 002.msg  # sent before the row became overdue',
          h.act(h.row['id'], 'steered', '002.msg'))
h.clock = now + 5 * 3600
r2 = show('(t+5h) action <row> steered --evidence 001.msg  # now five hours old',
          h.act(h.row['id'], 'steered', '001.msg'))
verdict('S1c stale steers refused', r1.returncode == 1 and r2.returncode == 1)

# --- S3 / intent 4 / M4 --------------------------------------------------------------
say("## S2  A remote secondmate's delivered pending-reply id is accepted as steered evidence")
h = Home('s2', category='silent_report', subject='mini', owner='firstmate',
         next_action='check in: progress, blockers, cross-workstream dependencies', evidence='last heard')
_, b = h.drain()
pend = h.home / 'state/pending-replies'
LIB = code / 'bin/fm-pending-reply-lib.sh'
def reply(task='mini', delivered=None):
    # The real producer: fm_pending_reply_create, then fm_pending_reply_mark_delivered.
    corr = h.call('bash', '-c', '. "$1"; fm_pending_reply_create "$2" "$3" "$4" "status please"', '_',
                  LIB, h.home, h.home / 'state', task).stdout.strip()
    if delivered is not None:
        h.call('bash', '-c', '. "$1"; fm_pending_reply_mark_delivered "$2" "$3" "$4"', '_', LIB,
               h.home / 'state', corr, str(delivered))
    return corr
und = reply()
r_und = show(f'action <row> steered --evidence {und}  # pending reply not delivered', h.act(h.row['id'], 'steered', und))
forn = reply(task='other', delivered=now + 5)
r_for = show(f'action <row> steered --evidence {forn}  # delivered, but to another task',
             h.act(h.row['id'], 'steered', forn))
good = reply(delivered=now + 5)
(pend / '2211221122112211').symlink_to(pend / good)
r_lnk = show('action <row> steered --evidence 2211221122112211  # symbolic link to a delivered record',
             h.act(h.row['id'], 'steered', '2211221122112211'))
r_ok = show(f'action <row> steered --evidence {good}  # delivered to mini after the episode began',
            h.act(h.row['id'], 'steered', good))
a = show('ack', h.ack(b))
verdict('S2 delivered remote id accepted; undelivered, foreign and symlinked ids refused',
        r_ok.returncode == 0 and a.returncode == 0 and r_und.returncode == 1 and r_for.returncode == 1
        and r_lnk.returncode == 1)

# --- S4 / intent 2 second half / M3 --------------------------------------------------
def printed_visibility(result, rid):
    # The drain prints a table: a header naming the fields, then one indented line per row; captain_visible is last.
    lines = result.stdout.splitlines()
    head = next((l for l in lines if 'captain_visible' in l), None)
    row = next((l for l in lines if rid in l and l.startswith('  ')), None)
    say(f'    drain header: {head}\n    drain row:    {row}')
    return row.rsplit(',', 1)[1].strip() if row else None
say('## S3  One owner decides captain_visible: the deferral refusal and the printed row agree')
h = Home('s3')
_, b = h.drain()
show('action <row> deferred --evidence "lint running" --recheck +600s',
     h.act(h.row['id'], 'deferred', 'lint running', '--recheck', iso(now + 600)))
show('ack', h.ack(b))
h.clock = now + 700
res, b = h.drain()
shown_before = printed_visibility(res, h.row['id'])
say(f'  (t+700s, deferral lapsed) drain prints captain_visible={shown_before}')
r = show('action <row> deferred --evidence "still running" --recheck +1300s',
         h.act(h.row['id'], 'deferred', 'still running', '--recheck', iso(now + 1300)))
stored_row = [x for x in h.stored()['rows'] if x['id'] == h.row['id']][0]
say(f'  stored row captain_visible={stored_row.get("captain_visible")}')
verdict('S3 refused second deferral and printed row both say captain-visible',
        r.returncode == 1 and shown_before == 'true' and stored_row.get('captain_visible') is True)

# --- S5 / intent 2 / M2 -------------------------------------------------------------
fake = world / 'fakebin'
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
for task in snap['tasks']:
    task.update(current_state={'state': 'working', 'source': 'status-log'},
                endpoint={'exists': True, 'agent_alive': 'alive'}, paths={'worktree': {'path': None}}, hints={})
snap['schema'] = 'fm-fleet-home-input.v1'
print(json.dumps(snap))
''')
exe(code / 'bin/fm-gh-rest.sh', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = json.loads((Path(os.environ['FM_HOME']) / 'forge.json').read_text())
url = sys.argv[2]
if '/pulls?' in url: value = [p]
elif '/check-runs' in url:
    value = {'check_runs': [{'name': 'Behavior portable serial 17', 'status': 'completed', 'conclusion': 'failure',
                             'completed_at': '2026-10-28T00:00:00Z', 'id': 1, 'app': {'id': 1}}]}
elif '/statuses?' in url: value = []
else: raise AssertionError(url)
print(json.dumps([value]))
''')
PR283 = 'https://github.com/test/project/pull/283'
def wait_home(name):
    h = Home(name, rows=[], extra_env=dict(PATH=str(fake) + os.pathsep + os.environ['PATH'],
                                           NM_HOME=str(world / 'nm'), FM_ROOT_OVERRIDE=''))
    h.env['FM_ROOT_OVERRIDE'] = str(h.home)
    (h.home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (h.home / 'forge.json').write_text(json.dumps(dict(html_url=PR283, number=283, state='open', draft=False,
                                                       head={'sha': 'a' * 40}, updated_at=iso(now - 7200))))
    (h.home / 'state/parked-job.meta').write_text(f'kind=ship\nspawn_gen=s-parked\npr={PR283}\n')
    (h.home / 'state/parked-job.status').write_text(f'working [at={now}]: parked on purpose until repair-owner merges\n')
    tree = world / ('tree-' + name)
    h.call('git', 'init', '-q', '-b', 'fm/repair-owner', tree)
    h.call('git', '-C', tree, '-c', 'user.name=t', '-c', 'user.email=t@e.invalid', 'commit', '-q', '--allow-empty', '-m', 'f')
    h.meta = f'kind=ship\nspawn_gen=s-repair\nworktree={tree}\nharness=claude\nwindow=fm:fm-repair-owner\n'
    (h.home / 'state/repair-owner.meta').write_text(h.meta)
    (h.home / 'state/repair-owner.status').write_text(f'working [at={now}]: fixing the red main\n')
    h.call(code / 'bin/fm-busy-event.sh', 'arm', h.home / 'state', 'repair-owner')
    h.call(code / 'bin/fm-busy-event.sh', 'apply', h.home / 'state', 'repair-owner', 'busy',
           '--current-gen', '--source', 'claude-hook', '--event', 'fixture')
    for p in (h.home / 'state').glob('*.status'):
        os.utime(p, (now, now))
    rep = h.call(LOOPS, '--heartbeat', '--json')
    report = json.loads(rep.stdout)
    h.red = next(r for r in report['rows'] if r['subject'] == PR283)
    say(f'  collected row: category={h.red["category"]} owner={h.red["owner"]} overdue={h.red["overdue"]}')
    return h
REASON = 'PR is red because main is red; parked until repair-owner merges'
def wait(h, task='repair-owner', recheck=3600):
    return h.act(h.red['id'], 'waiting', REASON, '--prerequisite-task', task, '--recheck', iso(now + recheck))

say('## S4a  A red PR row parked on purpose can wait on a named live task (no captain escalation)')
h = wait_home('s4a')
_, b = h.drain()
r = show(f'action <red_check row> waiting --evidence "{REASON}" --prerequisite-task repair-owner --recheck +1h', wait(h))
a = show('ack', h.ack(b))
_, b2 = h.drain()
a2 = show('(next drain) ack with no new action', h.ack(b2))
rep = show('fm-open-loops.sh --report  # row stays visible', h.call(LOOPS, '--report'))
verdict('S4a wait on live task accepted, stands across presentations, row stays visible',
        r.returncode == 0 and a.returncode == 0 and a2.returncode == 0 and h.red['id'] in rep.stdout)

for name, desc, mutate in (
        ('merged', 'the prerequisite PR merges', lambda h: (
            (h.home / 'state/repair-owner.meta').write_text(h.meta + 'pr=https://github.com/test/project/pull/290\n'),
            (h.home / 'state/repair-owner.pr-poll-merge-notified').write_text(
                'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\ntest/project\n290\n'),
            (h.home / 'state/repair-owner.pr-poll-merge-notified').chmod(0o600))),
        ('failed', 'the prerequisite fails', lambda h: (
            (h.home / 'state/repair-owner.status').write_text(f'failed [at={now}]: tests still red\n'),
            h.call(code / 'bin/fm-busy-event.sh', 'apply', h.home / 'state', 'repair-owner', 'idle',
                   '--current-gen', '--source', 'claude-hook', '--event', 'fixture'))),
        ('stalled', 'the prerequisite stalls (overdue stalled_worker row)', lambda h: (
            h.ledger.write_text(json.dumps(dict(h.stored(), rows=h.stored()['rows'] + [dict(
                id='stalled-repair', category='stalled_worker', subject='repair-owner', owner='worker:repair-owner',
                next_action='follow up', age_seconds=7200, limit_seconds=3600, overdue=True,
                evidence='no progress')])))))):
    say(f'## S4-{name}  The waiting row resurfaces when {desc}')
    h = wait_home('s4-' + name)
    _, b = h.drain()
    w = show('action ... waiting --prerequisite-task repair-owner', wait(h))
    h.ack(b)
    before = show('--check-actions before the change', h.call(LOOPS, '--check-actions'))
    mutate(h)
    after = show(f'--check-actions after {desc}', h.call(LOOPS, '--check-actions'))
    renew = show('renew the wait', wait(h, recheck=7200))
    verdict(f'S4-{name} wait ends and cannot be renewed when {desc}',
            w.returncode == 0 and before.returncode == 0 and after.returncode == 1 and renew.returncode == 1)

say('## S3b  Intent 2: a deferred red PR row whose worker is parked on a task can be answered truthfully with a wait')
h = wait_home('s3b')
_, b = h.drain()
show('action <red_check row> deferred --evidence "parked until repair-owner merges" --recheck +600s',
     h.act(h.red['id'], 'deferred', 'parked until repair-owner merges', '--recheck', iso(now + 600)))
show('ack', h.ack(b))
h.clock = now + 120
res, b = h.drain()
standing = printed_visibility(res, h.red['id'])
say(f'  (t+120s, first deferral still stands) drain prints captain_visible={standing}')
second = show('second deferral', h.act(h.red['id'], 'deferred', 'still parked', '--recheck', iso(now + 900)))
res2, b2 = h.drain()
after = printed_visibility(res2, h.red['id'])
stored_row = [x for x in h.stored()['rows'] if x['id'] == h.red['id']][0]
say(f'  after refusal: drain prints captain_visible={after}; stored row captain_visible={stored_row.get("captain_visible")}')
w = show(f'action <red_check row> waiting --evidence "{REASON}" --prerequisite-task repair-owner --recheck +1h',
         h.act(h.red['id'], 'waiting', REASON, '--prerequisite-task', 'repair-owner', '--recheck', iso(now + 3600)))
a = show('ack (no captain escalation recorded)', h.ack(b2))
kind = h.stored()['handling']['actions'][h.red['id']]['kind']
say(f'  recorded action kind: {kind}')
verdict('S3b refusal names the wait; printed and stored visibility agree after it; the wait is accepted and acks',
        second.returncode == 1 and 'wait on a named live task' in second.stdout and after == 'true'
        and stored_row.get('captain_visible') is True and w.returncode == 0 and a.returncode == 0
        and kind == 'waiting')

say('## S4g  (guard) A wait on a task that is not live, or on the row\'s own task, is refused; recheck must be <=24h')
h = wait_home('s4g')
_, b = h.drain()
r1 = show('waiting --prerequisite-task no-such-task', wait(h, task='no-such-task'))
r2 = show('waiting --prerequisite-task parked-job  # the row\'s own worker', wait(h, task='parked-job'))
r3 = show('waiting --prerequisite-task repair-owner --recheck +25h', wait(h, recheck=25 * 3600))
c = show('--check-actions (nothing recorded)', h.call(LOOPS, '--check-actions'))
verdict('S4g bad waits refused and the row stays actionable',
        r1.returncode == 1 and r2.returncode == 1 and r3.returncode == 1 and c.returncode == 1)

say('## S4h  (guard) A standing wait never outlives its recheck')
h = wait_home('s4h')
_, b = h.drain()
show('waiting ... --recheck +1h', wait(h))
h.ack(b)
h.clock = now + 3600
c = show('(t+1h) --check-actions', h.call(LOOPS, '--check-actions'))
verdict('S4h due recheck restores the action requirement', c.returncode == 1)

# --- S6 / M6 -------------------------------------------------------------------------
say('## S5  (guard) A row with no real handling still goes overdue and is re-presented every drain')
h = Home('s5')
r1, b = h.drain()
a1 = show('drain then ack with no action', h.ack(b))
h.clock = now + 120
r2, b = h.drain()
a2 = show('(t+120s) drain then ack with no action', h.ack(b))
c = show('--check-actions', h.call(LOOPS, '--check-actions'))
shown = h.row['id'] in r1.stdout and h.row['id'] in r2.stdout
say(f'  row printed by both drains: {shown}')
verdict('S5 unhandled overdue row blocks ack and re-presents', a1.returncode == 1 and a2.returncode == 1
        and c.returncode == 1 and shown)

say('#### summary')
for name, good in results:
    say(f'{"PASS" if good else "FAIL"}  {name}')
