#!/usr/bin/env python3
"""Live drive of bin/fm-open-loops.sh action verbs against disposable FM_HOME labs.

Usage: python3 -I live-ledger-drive.py <worktree> <scratch-dir>
The product (bin/ copied from the worktree) runs unmodified. Only external services are stood in:
GitHub REST (bin/fm-gh-rest.sh), tmux sessions, and the fleet snapshot's live-session probe. The
uninitialized-repo scenario uses the REAL installed no-mistakes binary with a private NM_HOME.
"""
import datetime as dt, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

root, world = Path(sys.argv[1]), Path(sys.argv[2])
code = world / 'code'
shutil.copytree(root / 'bin', code / 'bin')
now = int(time.time())
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
WAKE = '. "$1"; fm_wake_append check report "check: %s"'
REAL_NM = shutil.which('no-mistakes')
results = []

def say(*parts):
    print(*parts, flush=True)

def executable(path, text):
    path.write_text(text); path.chmod(0o755)

fake = world / 'fakebin'; fake.mkdir()
executable(fake / 'tmux', '''#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'fm-repair-owner\\n' ;;
  display-message) printf '%%1\\n' ;;
  capture-pane) printf 'all quiet\\n' ;;
  *) exit 1 ;;
esac
''')
# Stand-in no-mistakes used only for the stall scenarios: a ledger read stalls N times, then answers with a PR.
stallbin = world / 'stallbin'; stallbin.mkdir()
executable(stallbin / 'no-mistakes', '''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
home = os.environ.get('FM_HOME', '')
ledger_read = args == ['axi', 'status'] and os.environ.get('FM_CREW_STATE_NO_FORGE') != '1'
stall = os.path.join(home, 'run-stall')
if ledger_read and os.path.exists(stall):
    left = open(stall).read().strip()
    if left == '1': os.unlink(stall)
    elif left: open(stall, 'w').write(str(int(left) - 1))
    sys.exit(1)
if ledger_read and os.path.exists(os.path.join(home, 'run-pr')):
    print('run:\\n  id: run-1\\n  branch: fm/repair-owner\\n  pr: ' + open(os.path.join(home, 'run-pr')).read().strip())
''')
shutil.copy2(code / 'bin/fm-fleet-snapshot.sh', code / 'bin/real-fleet-snapshot.sh')
executable(code / 'bin/fm-fleet-snapshot.sh', '''#!/usr/bin/env python3
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
executable(code / 'bin/fm-gh-rest.sh', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
home = Path(os.environ['FM_HOME'])
p = json.loads((home / 'forge.json').read_text())
url = sys.argv[2]
if '/pulls?' in url: value = [p]
elif '/check-runs' in url and (home / 'checks-green').exists():
    value = {'check_runs': [{'name': 'ci', 'status': 'completed', 'conclusion': 'success',
                             'completed_at': '2026-10-28T00:00:00Z', 'id': 1, 'app': {'id': 1}}]}
elif '/check-runs' in url:
    value = {'check_runs': [{'name': 'Behavior portable serial 17', 'status': 'completed', 'conclusion': 'failure',
                             'completed_at': '2026-10-28T00:00:00Z', 'id': 1, 'app': {'id': 1}}]}
elif '/statuses?' in url: value = []
else: raise AssertionError(url)
print(json.dumps([value]))
''')
pr = 'https://github.com/test/project/pull/283'
base_env = dict(os.environ, FM_TEST_SEAM='1', FM_TEST_HARNESS='codex', FM_SUPERVISION_ACTOR='main',
                NM_HOME=str(world / 'nm'))
for key in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE',
            'NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS'):
    base_env.pop(key, None)

def lab(name, nm='real'):
    home = world / ('home-' + name)
    for d in ('state', 'data', 'config', 'projects'):
        (home / d).mkdir(parents=True)
    path = os.pathsep.join([str(fake)] + ([str(stallbin)] if nm == 'stall' else []) + [os.environ['PATH']])
    env = dict(base_env, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_OPEN_LOOPS_NOW=str(now), PATH=path)
    def call(*args, stdin=None):
        r = subprocess.run([str(a) for a in args], env=env, text=True, capture_output=True, timeout=180, input=stdin)
        shown = ' '.join(str(a) for a in args).replace(str(code) + '/', '')
        say(f'$ {shown}\n  exit={r.returncode}')
        for line in (r.stdout + r.stderr).strip().splitlines()[:12]:
            say('  | ' + line[:400])
        return r
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (home / 'forge.json').write_text(json.dumps(dict(html_url=pr, number=283, state='open', draft=False,
                                                     head={'sha': 'a' * 40}, updated_at=iso(now - 7200))))
    (home / 'state/parked-job.meta').write_text(f'kind=ship\nspawn_gen=s-parked\npr={pr}\n')
    (home / 'state/parked-job.status').write_text(f'working [at={now}]: parked on purpose until repair-owner merges\n')
    tree = world / ('tree-' + name)
    subprocess.run(['git', 'init', '-q', '-b', 'fm/repair-owner', str(tree)], check=True)
    subprocess.run(['git', '-C', str(tree), '-c', 'user.name=t', '-c', 'user.email=t@e.invalid', 'commit', '-q',
                    '--allow-empty', '-m', 'fixture'], check=True)
    meta = f'kind=ship\nspawn_gen=s-repair\nworktree={tree}\nharness=claude\nwindow=fm:fm-repair-owner\n'
    (home / 'state/repair-owner.meta').write_text(meta)
    (home / 'state/repair-owner.status').write_text(f'working [at={now}]: fixing the red main\n')
    subprocess.run([str(code / 'bin/fm-busy-event.sh'), 'arm', str(home / 'state'), 'repair-owner'], env=env, check=True,
                   capture_output=True)
    subprocess.run([str(code / 'bin/fm-busy-event.sh'), 'apply', str(home / 'state'), 'repair-owner', 'busy',
                    '--current-gen', '--source', 'claude-hook', '--event', 'fixture'], env=env, check=True,
                   capture_output=True)
    subprocess.run(['git', '-C', str(tree), 'update-ref', 'refs/remotes/origin/fm/repair-owner', 'HEAD'], check=True)
    working = f'working [at={now}]: fixing the red main\n'
    def finish(line):
        # The worker writes its final status line and its harness hook marks the session idle.
        (home / 'state/repair-owner.status').write_text(working + line + '\n')
        subprocess.run([str(code / 'bin/fm-busy-event.sh'), 'apply', str(home / 'state'), 'repair-owner', 'idle',
                        '--current-gen', '--source', 'claude-hook', '--event', 'fixture'], env=env, check=True,
                       capture_output=True)
    loops = code / 'bin/fm-open-loops.sh'
    def publish():
        stamp = int(env['FM_OPEN_LOOPS_NOW'])
        for p in (home / 'state').glob('*.status'):
            os.utime(p, (stamp, stamp))
        r = subprocess.run([str(loops), '--heartbeat', '--json'], env=env, text=True, capture_output=True, timeout=180)
        assert r.returncode == 0, r
        return json.loads(r.stdout)
    def drain():
        subprocess.run(['bash', '-c', WAKE % 'dependency followup', '_', str(code / 'bin/fm-wake-lib.sh')], env=env,
                       check=True)
        r = subprocess.run([str(code / 'bin/fm-wake-drain.sh')], env=env, text=True, capture_output=True, timeout=180)
        assert r.returncode == 0, r
        m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', r.stderr)
        return m.groups()
    def ack(b):
        return call(code / 'bin/fm-wake-drain.sh', '--ack-through', b[0], '--recovery-generation', b[1])
    return dict(finish=finish, home=home, env=env, call=call, loops=loops, publish=publish, drain=drain, ack=ack, meta=meta, tree=tree)

def record(name, ok, detail=''):
    results.append((name, ok, detail))
    say(f'==> {"PASS" if ok else "FAIL"}: {name} {detail}\n')

reason = 'PR is red because main is red; parked until repair-owner merges'

# A. M2: a red PR row waits on a named live task; a second drain stands; not-live and self prerequisites are refused.
say('### A. red PR row waits on a named live task (real no-mistakes on PATH)')
fx = lab('wait-live')
report = fx['publish']()
red = next(r for r in report['rows'] if r['subject'] == pr)
say(f'row: id={red["id"]} category={red["category"]} owner={red["owner"]} overdue={red["overdue"]} '
    f'captain_visible={red.get("captain_visible")} next_action={red["next_action"]!r}')
b = fx['drain']()
w = fx['call'](fx['loops'], 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-owner',
               '--recheck', iso(now + 3600))
a1 = fx['ack'](b)
b = fx['drain']()
a2 = fx['ack'](b)
ca = fx['call'](fx['loops'], '--check-actions')
record('M2 wait on live task accepted and stands across a re-presentation',
       w.returncode == 0 and a1.returncode == 0 and a2.returncode == 0 and ca.returncode == 0)
gone = fx['call'](fx['loops'], 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task',
                  'no-such-task', '--recheck', iso(now + 3600))
own = fx['call'](fx['loops'], 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task',
                 'parked-job', '--recheck', iso(now + 3600))
record('M2 wait on a task that is not live (or the row\'s own task) is refused', gone.returncode == 1 and own.returncode == 1)

# B. M2 resurfacing: the prerequisite fails.
say('### B. the prerequisite fails -> the standing wait stops counting')
fx['finish'](f'failed [at={now}]: tests still red')
ca = fx['call'](fx['loops'], '--check-actions')
record('M2 standing wait resurfaces when the prerequisite fails', ca.returncode == 1)

# C. M2 resurfacing: the prerequisite merges.
say('### C. the prerequisite PR merges -> the standing wait stops counting')
fx = lab('wait-merged')
red = next(r for r in fx['publish']()['rows'] if r['subject'] == pr)
b = fx['drain']()
fx['call'](fx['loops'], 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-owner',
           '--recheck', iso(now + 3600))
fx['ack'](b)
before = fx['call'](fx['loops'], '--check-actions')
(fx['home'] / 'state/repair-owner.meta').write_text(fx['meta'] + 'pr=https://github.com/test/project/pull/290\n')
(fx['home'] / 'state/repair-owner.pr-poll-merge-notified').write_text(
    'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\ntest/project\n290\n')
after = fx['call'](fx['loops'], '--check-actions')
record('M2 standing wait resurfaces when the prerequisite PR merges', before.returncode == 0 and after.returncode == 1)

# D. Round-1 fix: a done ship with no PR in a repo with NO no-mistakes setup. The REAL no-mistakes answers
# "repo not initialized" (exit 1). That is an answer: the task landed. Not "PR source could not be read".
say('### D. done ship, no PR, repo not initialized -- REAL no-mistakes binary')
say(f'real no-mistakes: {REAL_NM}')
fx = lab('uninit')
probe = subprocess.run([REAL_NM, 'axi', 'status'], cwd=fx['tree'], env=fx['env'], text=True, capture_output=True,
                       timeout=60)
say(f'$ (cd tree && no-mistakes axi status)\n  exit={probe.returncode}\n  | ' + (probe.stdout + probe.stderr).strip()
    .replace('\n', '\n  | '))
red = next(r for r in fx['publish']()['rows'] if r['subject'] == pr)
b = fx['drain']()
w = fx['call'](fx['loops'], 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-owner',
               '--recheck', iso(now + 3600))
fx['ack'](b)
standing = fx['call'](fx['loops'], '--check-actions')
fx['finish'](f'done [at={now}]: no change needed')
landed = fx['call'](fx['loops'], '--check-actions')
fx['publish']()
renew = fx['call'](fx['loops'], 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task',
                   'repair-owner', '--recheck', iso(now + 3600))
record('uninitialized repo: done ship with no PR counts as landed (wait resurfaces; new wait refused as done-with-no-PR)',
       probe.returncode == 1 and 'repo not initialized' in probe.stdout + probe.stderr and w.returncode == 0
       and standing.returncode == 0 and landed.returncode == 1 and renew.returncode == 1
       and 'done with no PR' in renew.stdout and 'could not be read' not in renew.stdout)

# E. A stalled run read stays unknown: the wait is refused with "try again next pass", never "done with no PR".
say('### E. done ship, run read stalls (exit 1, no answer) -> unknown, not landed')
fx = lab('stall', nm='stall')
red = next(r for r in fx['publish']()['rows'] if r['subject'] == pr)
fx['finish'](f'done [at={now}]: checks green on PR #290')
b = fx['drain']()
(fx['home'] / 'run-stall').write_text('')
stalled = fx['call'](fx['loops'], 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task',
                     'repair-owner', '--recheck', iso(now + 3600))
record('stalled run read is unknown, never a done-with-no-PR verdict',
       stalled.returncode == 1 and 'could not be read' in stalled.stdout and 'done with no PR' not in stalled.stdout)

# F. Round-1 fix: one batch, the first read stalls and the second answers with the run PR -> the unread mark clears.
say('### F. one batch: stall then answering read -> second line accepted')
(fx['home'] / 'run-stall').write_text('1')
(fx['home'] / 'run-pr').write_text('https://github.com/test/project/pull/290')
line = json.dumps(dict(row_id=red['id'], kind='waiting', evidence=reason, prerequisite_task='repair-owner',
                       recheck=iso(now + 3600)))
batch = fx['call'](fx['loops'], 'action', '--batch', '-', stdin=line + '\n' + line + '\n')
outs = batch.stdout
record('batch: stalled first line refused, answering second line accepted (unread mark cleared)',
       batch.returncode == 1 and re.search(r'^  1,.*"refused",.*could not be read', outs, re.M) is not None
       and re.search(r'^  2,.*"recorded"', outs, re.M) is not None,
       '')

# G. M5: a green PR's next_action points at AGENTS.md section 7 and never asks for merge approval.
say('### G. green PR row next_action')
fx = lab('green')
(fx['home'] / 'checks-green').write_text('')
rows = [r for r in fx['publish']()['rows'] if r['subject'] == pr]
for r in rows:
    say(f'row: category={r["category"]} owner={r["owner"]} next_action={r["next_action"]!r}')
toon = fx['call'](fx['loops'])
record('M5 green PR next_action names AGENTS.md section 7, no merge approval ask',
       rows and all('AGENTS.md section 7' in r['next_action'] and 'approval' not in r['next_action'] for r in rows))

say('### SUMMARY')
for name, ok, detail in results:
    say(f'{"PASS" if ok else "FAIL"}  {name}')
sys.exit(0 if all(ok for _, ok, _ in results) else 1)
