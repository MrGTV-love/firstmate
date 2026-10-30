# Drive the real bin/fm-open-loops.sh ledger in a lab FM_HOME; print a transcript.
import datetime as dt, json, os, re, subprocess, sys, time
from pathlib import Path
code = Path(sys.argv[1]); home = Path(os.environ['FM_HOME']); state = home / 'state'
LOG = []
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
def run(*args, show=True):
    r = subprocess.run([str(a) for a in args], text=True, capture_output=True, timeout=180)
    if show:
        print(f'$ {" ".join(str(a).replace(str(code)+"/", "") for a in args)}\n  rc={r.returncode}')
        for line in (r.stdout.strip() + '\n' + r.stderr.strip()).strip().splitlines():
            if 'SUPERVISION' in line or line.startswith('●') or 'queued wakes pending' in line:
                continue
            print('  | ' + line[:400])
    return r
loops = code / 'bin/fm-open-loops.sh'
def step(title): print(f'\n=== {title} ===', flush=True)
def publish():
    r = subprocess.run([str(loops), '--heartbeat', '--json'], text=True, capture_output=True, timeout=180)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)
def drain():
    subprocess.run(['bash', '-c', '. "$1"; fm_wake_append check report "check: open-loops overdue"', '_',
                    str(code / 'bin/fm-wake-lib.sh')], check=True)
    r = run(code / 'bin/fm-wake-drain.sh')
    m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', r.stderr)
    return m.groups() if m else None
def ack(b): return run(code / 'bin/fm-wake-drain.sh', '--ack-through', b[0], '--recovery-generation', b[1])
def row(report, subject, category):
    return next(x for x in report['rows'] if x['subject'] == subject and x['category'] == category)
RED, GREEN = 'https://github.com/test/project/pull/283', 'https://github.com/test/project/pull/284'
reason = 'PR 283 is red because main is red; parked until repair-owner merges'
now = lambda: int(time.time())
rep = publish(); red = row(rep, RED, 'red_check'); green = row(rep, GREEN, 'open_pr')
print('red row', red['id'], 'green row', green['id'])

step('S5: green PR next_action points at AGENTS.md section 7, never asks for merge approval')
print('  green next_action:', green['next_action'])
assert 'approval' not in green['next_action'] and 'AGENTS.md section 7' in green['next_action']

step('S6: a row with no handling stays overdue and blocks acknowledgement')
b = drain()
r = run(loops, '--check-actions'); assert r.returncode == 1
r = ack(b); assert r.returncode != 0, 'ack must refuse while an overdue row has no action'

step('S1: steer once with a real fm-send delivery; re-presentation still counts it, no new message')
r = run(code / 'bin/fm-send.sh', 'parked-job', 'Hold PR 283 until repair-owner lands the main fix; then rebase.')
assert r.returncode == 0
msgs = sorted(p.name for p in (state / 'parked-job.inbox').glob('*.msg')); print('  inbox records:', msgs)
rec = msgs[-1]
r = run(loops, 'action', red['id'], 'steered', '--evidence', rec); assert r.returncode == 0
r = run(loops, 'action', green['id'], 'deferred', '--evidence', 'review lane still running', '--recheck', iso(now() + 75))
assert r.returncode == 0
assert ack(b).returncode == 0
time.sleep(5); publish()
b = drain()
r = run(loops, '--check-actions'); assert r.returncode == 1, 'a worker-owned row needs an action each handling turn'
assert len(sorted((state / 'parked-job.inbox').glob('*.msg'))) == 1
r = run(loops, 'action', red['id'], 'steered', '--evidence', rec); assert r.returncode == 0, 'same pre-re-presentation steer must be accepted'
assert run(loops, '--check-actions').returncode == 0
assert ack(b).returncode == 0
print('  -> re-presented red row accepted as steered with the same', rec, '(no new message sent)')
step('S1-neg: a delivery sent BEFORE the row went overdue is refused as steer evidence')
old = state / 'parked-job.inbox' / '000.msg'
old.write_text(f'schema=fm-task-inbox.v1\nat={iso(now() - 3 * 3600)}\n--\nold instruction\n'); old.chmod(0o600)
r = run(loops, 'action', red['id'], 'steered', '--evidence', '000.msg'); assert r.returncode == 1
old.unlink()

step('S3: second deferral while first stands, then after it lapses; printed captain_visible matches refusal')
r = run(loops, 'action', green['id'], 'deferred', '--evidence', 'again', '--recheck', iso(now() + 3600))
assert r.returncode == 1 and 'already stands' in r.stdout
time.sleep(max(0, 80 - 5)); publish()
b = drain()
printed = [l for l in run(loops, '--present-overdue', show=False).stdout.splitlines() if green['id'] in l]
print('  printed green row after lapse:', printed)
r = run(loops, 'action', green['id'], 'deferred', '--evidence', 'again', '--recheck', iso(now() + 3600))
assert r.returncode == 1 and 'captain-visible' in r.stdout
b2 = b
vis = json.loads((state / 'open-loops.json').read_text())
print('  published captain_visible for green row:', row(vis, GREEN, 'open_pr').get('captain_visible'))
r = run(loops, 'action', green['id'], 'escalated', '--evidence', 'deferral lapsed; captain sees PR 284')
assert r.returncode == 0

step('S2a: waiting on a task that is not live is refused (no session; unknown task)')
(state / 'gone-task.meta').write_text('kind=ship\nspawn_gen=s-gone\nharness=claude\nwindow=fm:fm-gone-task\n')
(state / 'gone-task.status').write_text(f'working [at={now()}]: was fixing\n')
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'gone-task', '--recheck', iso(now() + 3600))
assert r.returncode == 1 and 'not live' in r.stdout
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'no-such-task', '--recheck', iso(now() + 3600))
assert r.returncode == 1
(state / 'gone-task.meta').unlink(); (state / 'gone-task.status').unlink()

step('S2b: waiting --prerequisite-task on a live task is accepted and stands across a re-presentation')
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-owner', '--recheck', iso(now() + 3600))
assert r.returncode == 0
assert ack(b2).returncode == 0
publish(); b = drain(); assert run(loops, '--check-actions').returncode == 0; assert ack(b).returncode == 0

step('S2c: prerequisite reports done with a PR; wait stands until the merge record lands, then the row resurfaces')
with open(state / 'repair-owner.status', 'a') as f: f.write(f'done [at={now()}]: PR https://github.com/test/project/pull/290\n')
run(code / 'bin/fm-crew-state.sh', 'repair-owner')
assert run(loops, '--check-actions').returncode == 0
run('bash', '-c', '. "$1"; fm_pr_poll_merge_mark_notified "$2" repair-owner github github.com test/project 290', '_', code / 'bin/fm-pr-lib.sh', state)
r = run(loops, '--check-actions'); assert r.returncode == 1
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-owner', '--recheck', iso(now() + 3600))
assert r.returncode == 1 and 'merged' in r.stdout

def fresh(name):
    t = Path('/tmp/fm-live-drv/trees') / name
    run('git', 'clone', '-q', home / 'projects/project', t, show=False); run('git', '-C', t, 'checkout', '-q', '-b', 'fm/' + name, show=False)
    (state / f'{name}.meta').write_text(f'kind=ship\nspawn_gen=s-{name}\nworktree={t}\nharness=claude\nwindow=fm:fm-{name}\n')
    (state / f'{name}.status').write_text(f'working [at={now()}]: fixing\n')
    run('tmux', 'new-window', '-d', '-a', '-t', 'fm:fm-repair-owner', '-n', f'fm-{name}', '/tmp/fm-live-drv/workers/claude-standin 7200', show=False)
    run(code / 'bin/fm-busy-event.sh', 'arm', state, name, show=False)
    run(code / 'bin/fm-busy-event.sh', 'apply', state, name, 'busy', '--current-gen', '--source', 'claude-hook', '--event', 'UserPromptSubmit', show=False)
    publish(); b = drain()
    r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', name, '--recheck', iso(now() + 3600))
    assert r.returncode == 0; assert ack(b).returncode == 0
    assert run(loops, '--check-actions').returncode == 0

step('S2d: prerequisite fails -> the wait ends and the row resurfaces')
fresh('repair-two')
with open(state / 'repair-two.status', 'a') as f: f.write(f'failed [at={now()}]: could not fix main\n')
run(code / 'bin/fm-busy-event.sh', 'apply', state, 'repair-two', 'idle', '--current-gen', '--source', 'claude-hook', '--event', 'Stop')
run(code / 'bin/fm-crew-state.sh', 'repair-two')
assert run(loops, '--check-actions').returncode == 1

step('S2e: prerequisite session dies (stall/gone) -> the wait ends and the row resurfaces')
fresh('repair-three')
run('tmux', 'kill-window', '-t', 'fm:fm-repair-three')
run(code / 'bin/fm-crew-state.sh', 'repair-three')
assert run(loops, '--check-actions').returncode == 1

step('S7: GitLab prerequisite: other-MR record keeps wait; record failing private-file check fails closed')
fresh('repair-four')
with open(state / 'repair-four.status', 'a') as f: f.write(f'done [at={now()}]: PR https://gitlab.com/test/project/-/merge_requests/290\n')
assert run(loops, '--check-actions').returncode == 0
run('bash', '-c', '. "$1"; fm_pr_poll_merge_mark_notified "$2" repair-four gitlab gitlab.com test/project 291', '_', code / 'bin/fm-pr-lib.sh', state)
marker = state / 'repair-four.pr-poll-merge-notified'
print('  marker mode', oct(marker.stat().st_mode & 0o777))
assert run(loops, '--check-actions').returncode == 0, 'validated record for another MR keeps the wait'
marker.chmod(0o644)
r = run(loops, '--check-actions'); assert r.returncode == 1, 'mode-644 record must fail closed'
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-four', '--recheck', iso(now() + 3600))
assert r.returncode == 1 and 'unreadable' in r.stdout
marker.chmod(0o600)
real = marker.read_text(); marker.unlink(); (state / 'elsewhere.txt').write_text(real); (state / 'elsewhere.txt').chmod(0o600)
marker.symlink_to(state / 'elsewhere.txt')
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-four', '--recheck', iso(now() + 3600))
assert r.returncode == 1 and 'unreadable' in r.stdout, 'symlinked record fails closed'
marker.unlink(); (state / 'elsewhere.txt').rename(marker)
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-four', '--recheck', iso(now() + 3600))
assert r.returncode == 0, 'restored valid other-MR record admits the wait again'
ack_b = None
step('S7b: the GitLab prerequisite MR 290 itself lands -> wait ends; a new wait is refused as merged')
run('bash', '-c', '. "$1"; fm_pr_poll_merge_mark_notified "$2" repair-four gitlab gitlab.com test/project 290', '_', code / 'bin/fm-pr-lib.sh', state)
print('  marker:', marker.read_text().splitlines(), oct(marker.stat().st_mode & 0o777))
assert run(loops, '--check-actions').returncode == 1
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-four', '--recheck', iso(now() + 3600))
assert r.returncode == 1 and 'merged' in r.stdout

step('S2g: adversarial - prerequisite ship reports done with no PR (uninitialized no-mistakes repo) -> wait refused')
fresh_name = 'repair-six'
t = Path('/tmp/fm-live-drv/trees') / fresh_name
run('git', 'clone', '-q', home / 'projects/project', t, show=False); run('git', '-C', t, 'checkout', '-q', '-b', 'fm/' + fresh_name, show=False)
(state / f'{fresh_name}.meta').write_text(f'kind=ship\nspawn_gen=s-{fresh_name}\nworktree={t}\nharness=claude\nwindow=fm:fm-{fresh_name}\n')
(state / f'{fresh_name}.status').write_text(f'working [at={now()}]: checking\ndone [at={now()}]: no change needed\n')
run('tmux', 'new-window', '-d', '-a', '-t', 'fm:fm-repair-owner', '-n', f'fm-{fresh_name}', '/tmp/fm-live-drv/workers/claude-standin 7200', show=False)
run(code / 'bin/fm-busy-event.sh', 'arm', state, fresh_name, show=False)
run(code / 'bin/fm-busy-event.sh', 'apply', state, fresh_name, 'idle', '--current-gen', '--source', 'claude-hook', '--event', 'Stop')
run(code / 'bin/fm-crew-state.sh', fresh_name)
run('no-mistakes', 'axi', 'status', cwd=None) if False else None
publish(); bb = drain()
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', fresh_name, '--recheck', iso(now() + 3600))
assert r.returncode == 1, 'a done ship with no PR has landed; a wait on it must be refused'

step('S2f: prerequisite stalls (stalled_worker row crosses its limit) -> wait ends; new wait refused as stalled')
fresh('repair-five')
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-five', '--recheck', iso(now() + 80000))
assert r.returncode == 0
assert run(loops, '--check-actions').returncode == 0
os.environ['FM_OPEN_LOOPS_NOW'] = str(now() + 3700)
rep = publish()
print('  stalled rows at clock+3700s:', [(x['subject'], x['overdue']) for x in rep['rows'] if x['category'] == 'stalled_worker'])
r = run(loops, '--check-actions'); assert r.returncode == 1 and red['id'] in r.stdout + r.stderr
r = run(loops, 'action', red['id'], 'waiting', '--evidence', reason, '--prerequisite-task', 'repair-five', '--recheck', iso(int(os.environ['FM_OPEN_LOOPS_NOW']) + 3600))
assert r.returncode == 1 and 'stalled' in r.stdout
print('\nALL LIVE LAB SCENARIOS PASSED')
