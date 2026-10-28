"""Live driver: real bin/fm-open-loops.sh and bin/fm-wake-drain.sh against a marked lab FM_HOME."""
import datetime as dt, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

wt = Path(sys.argv[1]); home = Path(sys.argv[2]); base_bin = Path(sys.argv[3]); count_bin = Path(sys.argv[4])
log = open(sys.argv[5], 'w')
def say(*a):
    print(*a, file=log, flush=True); print(*a, flush=True)
loops, drain_cli = wt / 'bin/fm-open-loops.sh', wt / 'bin/fm-wake-drain.sh'
ledger = home / 'state/open-loops.json'
backlog = home / 'data/backlog.md'
backlog.write_text('## In flight\n\n## Queued\n\n## Done\n')
now = int(time.time()); clock = now
def env():
    e = dict(os.environ, FM_HOME=str(home), FM_OPEN_LOOPS_NOW=str(clock), FM_SUPERVISION_ACTOR='main')
    for k in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE',
              'FM_PROJECTS_OVERRIDE', 'NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS'):
        e.pop(k, None)
    return e
def run(cmd, inp=None, show=True):
    t = time.monotonic()
    r = subprocess.run([str(c) for c in cmd], env=env(), text=True, capture_output=True, input=inp, timeout=600)
    el = time.monotonic() - t
    if show:
        say(f'$ {" ".join(Path(str(c)).name if i == 0 else str(c) for i, c in enumerate(cmd))}  [exit {r.returncode}, {el:.2f}s, clock=+{clock-now}]')
        for line in (r.stdout.strip().splitlines()[:12]):
            say('  out| ' + line)
        if len(r.stdout.strip().splitlines()) > 12:
            say(f'  out| ... ({len(r.stdout.strip().splitlines())} lines)')
        for line in r.stderr.strip().splitlines()[:6]:
            say('  err| ' + line)
    r.elapsed = el
    return r
def row(i, **kw):
    d = dict(id=f'row-{i}', category='unanswered_question', subject=f'job:question-{i}', owner='firstmate',
             next_action='obtain decision', evidence='decision pending', age_seconds=7200, limit_seconds=1800, overdue=True)
    d.update(kw); return d
def publish(items):
    old = json.loads(ledger.read_text()) if ledger.exists() else {}
    rec = dict(schema='fm-open-loops.v1', generated_epoch=clock, home=str(home), complete=True, rows=items)
    if 'handling' in old: rec['handling'] = old['handling']
    ledger.write_text(json.dumps(rec))
def drain():
    r = run([drain_cli])
    m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', r.stderr)
    return r, (m.groups() if m else None)
def ack(b):
    return run([drain_cli, '--ack-through', b[0], '--recovery-generation', b[1]])
def act(ident, kind='escalated', evidence='reported decision', *extra):
    return run([loops, 'action', ident, kind, '--evidence', evidence, *extra])
def check(): return run([loops, '--check-actions'])
results = {}
def verdict(name, ok):
    results[name] = ok; say(f'==> {name}: {"PASS" if ok else "FAIL"}\n')

say(f'lab FM_HOME={home}\nload: {os.getloadavg()}')

# S1 batch of 50 + 2 bad lines, real snapshot, counted on a copied bin
say('### S1 batch of 50 rows: one snapshot, per-row refusals, then ack')
rows = [row(i) for i in range(50)]
publish(rows)
r, b = drain()
ok = b is not None and 'action --batch' in r.stdout
batch_lines = ''.join(json.dumps(dict(row_id=x['id'], kind='escalated', evidence='reported decision')) + '\n' for x in rows)
bad = json.dumps(dict(row_id='absent', kind='escalated', evidence='x')) + '\n' + json.dumps(dict(row_id='row-0', kind='bogus', evidence='x')) + '\n'
runs = home / 'snapshot-runs'; runs.unlink(missing_ok=True)
rb = run([count_bin / 'fm-open-loops.sh', 'action', '--batch', '-'], inp=batch_lines + bad)
snaps = len(runs.read_text().splitlines()) if runs.exists() else 0
say(f'  snapshot invocations during 52-line batch: {snaps}')
acts = json.loads(ledger.read_text())['handling']['actions']
ok &= rb.returncode == 1 and snaps == 1 and len(acts) == 50 and rb.stdout.count('"refused"') == 2 and rb.stdout.count('"recorded"') == 50
ok &= check().returncode == 0 and ack(b).returncode == 0
verdict('S1 batch one snapshot + per-row refusal + ack', ok)

# S1b timing at same load: base single-row x N vs new batch x 50
say('### S1b timing (same host, back-to-back)')
clock += 14400 * 3  # expire receipts so rows need action again
publish(rows); r, b = drain()
say(f'  load before timing: {os.getloadavg()}')
r1 = run([loops, 'action', 'row-0', 'escalated', '--evidence', 'reported decision'])
single_new = r1.elapsed
rb = run([loops, 'action', '--batch', '-'], inp=''.join(batch_lines.splitlines(True)[1:]))
batch_new = rb.elapsed
ok = rb.returncode == 0 and check().returncode == 0 and ack(b).returncode == 0
# base code: 10 single-row actions with the pre-change bin, measure per-row cost
clock += 14400 * 3
bh = home  # same home; base code reads/writes same ledger schema
publish(rows); r, b = drain()
base_times = []
for x in rows[:10]:
    rr = run([base_bin / 'fm-open-loops.sh', 'action', x['id'], 'escalated', '--evidence', 'reported decision'], show=False)
    base_times.append(rr.elapsed)
say(f'  load after timing: {os.getloadavg()}')
say(f'  NEW single-row action: {single_new:.2f}s; NEW 49-row batch: {batch_new:.2f}s; ratio batch/single = {batch_new/single_new:.2f}')
say(f'  BASE single-row actions (10 rows): mean {sum(base_times)/len(base_times):.2f}s, total {sum(base_times):.2f}s -> 50-row projection {50*sum(base_times)/len(base_times):.1f}s')
verdict('S1b batch wall time < 2x single-row action', ok and batch_new < 2 * single_new)
# finish the base-turn so the queue is clean
run([loops, 'action', '--batch', '-'], inp=''.join(batch_lines.splitlines(True)[10:]), show=False)
ack(b)

# S2 reads do not reset: action, drain, refused ack, then finish and ack
say('### S2 read stability: drain + refused ack do not void recorded actions')
clock += 14400 * 3
publish([row(0), row(1)])
r, b = drain()
act('row-0')
r2, _ = drain()
ok = 'row-0' not in r2.stdout.split('STANDING')[0] if 'OVERDUE' in r2.stdout else True
ref = ack(b); ok &= ref.returncode != 0
act('row-1')
ok &= check().returncode == 0 and ack(b).returncode == 0
verdict('S2 drain and refused ack preserve recorded action', ok)

say('### S2b adversarial: evidence change after action still needs new action')
clock += 14400 * 3
publish([row(0)]); r, b = drain(); act('row-0')
publish([row(0, evidence='decision pending; captain asked a follow-up question')])
ok = check().returncode == 1 and ack(b).returncode != 0
act('row-0'); ok &= check().returncode == 0 and ack(b).returncode == 0
verdict('S2b changed evidence invalidates receipt', ok)

say('### S2c stalled worker pane timer change only does not void receipt')
clock += 14400 * 3
st = row(0, category='stalled_worker', subject='job', owner='worker:job', next_action='recover the worker',
         evidence='Running lint… (3m 12s · esc to interrupt); 3600s without progress')
publish([st]); r, b = drain(); act('row-0')
clock += 60
publish([dict(st, evidence='Running lint… (3m 13s · esc to interrupt); 3660s without progress')])
ok = check().returncode == 0
r2, _ = drain()
ok &= ack(b).returncode == 0
verdict('S2c timer-only change keeps receipt', ok)

# S3 cross-turn standing and expiry
say('### S3 unbound firstmate escalation stands next turn within 4h, re-presents at 4h')
clock += 14400 * 3
publish([row(0)]); r, b = drain(); act('row-0'); ack(b)
t0 = clock
clock = t0 + 14399
r, b = drain()
ok = 'row-0' not in r.stdout.split('STANDING')[0] and 'WAKE_ACK_REQUIRED' not in r.stderr
clock = t0 + 14400
r, b = drain()
ok &= 'row-0' in r.stdout and b is not None and ack(b).returncode != 0
act('row-0'); ok &= ack(b).returncode == 0
verdict('S3 4h cross-turn standing then re-present', ok)

say('### S3b review_pass_not_merged has no cross-turn standing')
clock += 14400 * 3
publish([row(0, category='review_pass_not_merged', subject='https://github.com/test/project/pull/9')])
r, b = drain(); act('row-0'); ok = ack(b).returncode == 0
r, b = drain(); ok &= b is not None and 'row-0' in r.stdout and ack(b).returncode != 0
act('row-0'); ok &= ack(b).returncode == 0
verdict('S3b reviewed PR needs action every turn', ok)

# S4 harm fix: unclosed turn bound at 14399/14400
say('### S4 current-turn ordinary receipt (away-daemon text) expires at +14400 without new presentation')
clock += 14400 * 3
publish([row(0)]); r, b = drain()
act('row-0', 'escalated', 'away supervisor escalation digest')
t0 = clock
clock = t0 + 14399
ok = check().returncode == 0
clock = t0 + 14400
ok &= check().returncode == 1 and ack(b).returncode != 0
r, b2 = drain(); ok &= 'row-0' in r.stdout
act('row-0', 'escalated', 'followed up'); ok &= ack(b2).returncode == 0
verdict('S4 unclosed turn cannot hide expired receipt', ok)

# S5 captain hold answered within same turn
say('### S5 bound captain hold answered in the same turn restores requirement')
clock += 14400 * 3
held_at = dt.datetime.fromtimestamp(clock - 7200, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
held = ('## In flight\n- [ ] job - Recover the run (repo: firstmate) (kind: ship) (hold: exact run recovery)'
        f' (hold-kind: captain)\n  Captain hold set: {held_at}\n\n## Queued\n\n## Done\n')
backlog.write_text(held)
publish([row(0)]); r, b = drain()
ra = act('row-0', 'escalated', 'asked captain', '--hold', 'job')
ok = 'standing: captain hold job' in ra.stdout and check().returncode == 0
backlog.write_text(held.replace('- [ ] job', '- [x] job').replace('## In flight', '## Done', 1))
clock += 60
ok &= check().returncode == 1 and ack(b).returncode != 0
act('row-0'); ok &= ack(b).returncode == 0
backlog.write_text('## In flight\n\n## Queued\n\n## Done\n')
verdict('S5 hold answered same turn re-gates', ok)

say('### S5b bound captain hold unreadable in the same turn restores requirement')
clock += 14400 * 3
backlog.write_text(held.replace(held_at, dt.datetime.fromtimestamp(clock - 7200, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')))
publish([row(0)]); r, b = drain()
ra = act('row-0', 'escalated', 'asked captain', '--hold', 'job')
ok = 'standing: captain hold job' in ra.stdout
backlog.unlink(); backlog.symlink_to(home / 'missing-backlog')
ok &= check().returncode == 1 and ack(b).returncode != 0
backlog.unlink(); backlog.write_text('## In flight\n\n## Queued\n\n## Done\n')
act('row-0'); ok &= ack(b).returncode == 0
verdict('S5b hold unreadable same turn re-gates', ok)

# S6 gate kept
say('### S6 row with no action refuses acknowledgement')
clock += 14400 * 3
publish([row(0), row(1)]); r, b = drain()
ok = 'row-0' in r.stdout and check().returncode == 1 and ack(b).returncode != 0
act('row-0'); ok &= ack(b).returncode != 0
act('row-1'); ok &= ack(b).returncode == 0
verdict('S6 unactioned row still refuses ack', ok)

# S7 pipeline --report | filter | action --batch - does not hang
say('### S7 pipeline report | batch - with no lock deadlock')
clock += 14400 * 3
publish([row(0), row(1), row(2)]); r, b = drain()
pipe = (f'"{loops}" --report | sed -n \'s/^  "\\(row-[0-9]*\\)".*/{{"row_id":"\\1","kind":"escalated","evidence":"reported decision"}}/p\''
        f' | head -2 | "{loops}" action --batch -')
t = time.monotonic()
rp = subprocess.run(['bash', '-c', pipe], env=env(), text=True, capture_output=True, timeout=120)
say(f'$ fm-open-loops.sh --report | sed | head -2 | fm-open-loops.sh action --batch -  [exit {rp.returncode}, {time.monotonic()-t:.2f}s]')
for line in rp.stdout.splitlines(): say('  out| ' + line)
ok = rp.returncode == 0 and rp.stdout.count('"recorded"') == 2
c = check(); ok &= c.returncode == 1 and 'row-2' in c.stdout
act('row-2'); ok &= ack(b).returncode == 0
verdict('S7 pipeline does not deadlock; unactioned row still gated', ok)

say('SUMMARY ' + json.dumps(results))
sys.exit(0 if all(results.values()) else 1)
