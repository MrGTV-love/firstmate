#!/usr/bin/env python3
"""Live driver: run the real fm-open-loops.sh / fm-wake-drain.sh CLIs against a throwaway FM_HOME.

Usage: drive_receipts.py BIN_DIR LABEL
BIN_DIR is copied into a disposable world; the real fm-fleet-snapshot.sh is wrapped only to
count how many times it runs. Every step prints a transcript line. Exits 0 always; the
transcript states each scenario's observed result.
"""
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

src, label = Path(sys.argv[1]).resolve(), sys.argv[2]
world = Path(tempfile.mkdtemp(prefix=f'fm-live-{label}-'))
code = world / 'code'
shutil.copytree(src, code / 'bin')
shutil.copy2(code / 'bin/fm-fleet-snapshot.sh', code / 'bin/real-fleet-snapshot.sh')
snap = code / 'bin/fm-fleet-snapshot.sh'
snap.write_text('#!/usr/bin/env bash\nprintf "snapshot\\n" >> "$FM_HOME/snapshot-runs"\n'
                'exec "$(dirname "$0")/real-fleet-snapshot.sh" "$@"\n')
snap.chmod(0o755)
loops, drain_cli = code / 'bin/fm-open-loops.sh', code / 'bin/fm-wake-drain.sh'
NOW = int(time.time())
clock = NOW
home = None
HAS_BATCH = '--batch' in (code / 'bin/fm-open-loops.sh').read_text()


def new_home(name):
    global home
    home = world / name
    for d in ('state', 'config', 'data', 'projects'):
        (home / d).mkdir(parents=True)
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')


def env():
    e = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_OPEN_LOOPS_NOW=str(clock),
             FM_TEST_SEAM='1', FM_TEST_HARNESS='codex', FM_SUPERVISION_ACTOR='main', FM_DURATION_FILE='off')
    for k in ('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE',
              'NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS'):
        e.pop(k, None)
    return e


def run(binary, *args, stdin=None, shell=None):
    cmd = shell if shell else [str(binary), *map(str, args)]
    return subprocess.run(cmd, env=env(), text=True, capture_output=True, input=stdin, timeout=600,
                          shell=bool(shell))


def say(msg):
    print(msg, flush=True)


def rows_of(n, **over):
    return [dict(dict(id=f'row-{i}', category='unanswered_question', subject=f'job:question-{i}', owner='firstmate',
                      next_action='obtain decision', evidence='decision pending', age_seconds=7200,
                      limit_seconds=1800, overdue=True), **over) for i in range(n)]


def publish(items):
    (home / 'state/open-loops.json').write_text(json.dumps(dict(
        schema='fm-open-loops.v1', generated_epoch=NOW, home=str(home), complete=True, rows=items)))


def stored():
    return json.loads((home / 'state/open-loops.json').read_text())


def drain(note='drain'):
    r = run(drain_cli)
    m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', r.stderr)
    overdue = len(re.findall(r'^  "row-\d+"', r.stdout.split('STANDING')[0], re.M)) if 'OVERDUE' in r.stdout else 0
    say(f'$ fm-wake-drain.sh            [{note}] exit={r.returncode} overdue_rows_shown={overdue}'
        f' ack_required={"yes" if m else "no"}')
    return r, (m.groups() if m else None)


def ack(boundary, note='ack'):
    r = run(drain_cli, '--ack-through', boundary[0], '--recovery-generation', boundary[1])
    tail = (r.stdout + r.stderr).strip().splitlines()
    say(f'$ fm-wake-drain.sh --ack-through {boundary[0]} ...   [{note}] exit={r.returncode}'
        f' -> {"ACCEPTED" if r.returncode == 0 else "REFUSED"}'
        + (f' | {tail[-1][:150]}' if r.returncode and tail else ''))
    return r


def check(note='check'):
    r = run(loops, '--check-actions')
    missing = len(re.findall(r'"row-\d+"', r.stdout))
    say(f'$ fm-open-loops.sh --check-actions   [{note}] exit={r.returncode} rows_listed={missing}')
    return r


def act(ident, kind='escalated', evidence='reported decision', *extra):
    return run(loops, 'action', ident, kind, '--evidence', evidence, *extra)


def batch_lines(items):
    return ''.join(json.dumps(i) + '\n' for i in items)


def record_all(ids, note):
    runs = home / 'snapshot-runs'
    runs.unlink(missing_ok=True)
    t0 = time.monotonic()
    if HAS_BATCH:
        r = run(loops, 'action', '--batch', '-', stdin=batch_lines(
            [dict(row_id=i, kind='escalated', evidence='reported decision') for i in ids]))
        ok = r.stdout.count('"recorded"')
        how = 'action --batch - (one call)'
        code_ = r.returncode
    else:
        codes = [act(i).returncode for i in ids]
        ok, code_ = codes.count(0), max(codes)
        how = f'action ROW escalated x{len(ids)} (one call per row)'
    took = time.monotonic() - t0
    n = len(runs.read_text().splitlines()) if runs.exists() else 0
    say(f'$ fm-open-loops.sh {how}   [{note}] exit={code_} recorded={ok}/{len(ids)}'
        f' snapshot_reads={n} wall={took:.2f}s')


def scenario(title):
    say('')
    say(f'=== [{label}] {title}')


try:
    # S1: the captain's literal ask: log all 50 actions, then clear the queue in one step, no reads between.
    scenario('S1 log 50 actions in one step, then acknowledge with no read in between')
    new_home('s1')
    publish(rows_of(50))
    _, b = drain('presents 50 overdue rows')
    record_all([f'row-{i}' for i in range(50)], '50 escalations')
    ack(b, 'clear the queue')

    # S2: the incident: a drain run (just to read the ack command) after logging all 50.
    scenario('S2 log 50 actions, re-read the queue (drain + --check-actions), then acknowledge')
    new_home('s2')
    publish(rows_of(50))
    _, b = drain('presents 50 overdue rows')
    record_all([f'row-{i}' for i in range(50)], '50 escalations')
    clock += 30
    drain('re-read to find the ack command')
    check('read-only check')
    ack(b, 'clear the queue after reads')

    # S3: refused ack keeps progress for the rows already actioned.
    scenario('S3 refused acknowledgement does not reset recorded progress')
    new_home('s3')
    publish(rows_of(10))
    _, b = drain('presents 10 rows')
    for i in range(5):
        act(f'row-{i}')
    say('$ fm-open-loops.sh action row-0..row-4 escalated   (5 of 10 recorded)')
    ack(b, 'ack with 5 missing (must refuse)')
    check('after refused ack: only the 5 unactioned rows should be listed')
    for i in range(5, 10):
        act(f'row-{i}')
    say('$ fm-open-loops.sh action row-5..row-9 escalated   (remaining 5 recorded, first 5 NOT re-recorded)')
    ack(b, 'ack after finishing the rest')

    # S4: firstmate escalations stand across later handling turns on unchanged rows, bounded at 4h.
    scenario('S4 unchanged firstmate-owned escalations stand next turn, re-required after 4 h')
    new_home('s4')
    publish(rows_of(50))
    _, b = drain('turn 1 presents 50')
    record_all([f'row-{i}' for i in range(50)], 'turn 1 actions')
    clock += 60
    drain('turn 1 re-read')
    ack(b, 'turn 1 ack')
    t1 = clock
    clock = t1 + 3600
    r, b2 = drain('turn 2 at +1h, rows unchanged')
    if b2:
        ack(b2, 'turn 2 ack with no new actions')
    clock = t1 + 4 * 3600 + 120
    r, b3 = drain('turn 3 at +4h02m')
    if b3:
        ack(b3, 'turn 3 ack with no new actions (must refuse: 4h bound)')

    # S5: adversarial: the gate still refuses a missing action; batch refusals are per row.
    scenario('S5 gate still refuses missing actions; bad batch lines refuse alone')
    new_home('s5')
    publish(rows_of(50))
    _, b = drain('presents 50')
    if HAS_BATCH:
        items = [dict(row_id=f'row-{i}', kind='escalated', evidence='reported decision') for i in range(49)]
        r = run(loops, 'action', '--batch', '-', stdin=batch_lines(items) + 'not-json\n'
                + batch_lines([dict(row_id='absent', kind='escalated', evidence='x'),
                               dict(row_id='row-49', kind='bogus', evidence='x'),
                               dict(row_id='row-49', kind='deferred', evidence='x', recheck='2000-01-01T00:00:00Z')]))
        say(f'$ fm-open-loops.sh action --batch - (49 good + 4 bad lines) exit={r.returncode}'
            f' recorded={r.stdout.count(chr(34)+"recorded"+chr(34))} refused={r.stdout.count(chr(34)+"refused"+chr(34))}')
        for line in r.stdout.splitlines():
            if '"refused"' in line:
                say('    ' + line.strip()[:170])
        say(f'    stored actions in ledger: {len(stored()["handling"]["actions"])}')
    else:
        for i in range(49):
            act(f'row-{i}')
    c = check('row-49 has no action')
    say('    listed: ' + ', '.join(re.findall(r'"(row-\d+)"', c.stdout)))
    ack(b, 'ack with row-49 missing (must refuse)')
    act('row-49')
    ack(b, 'ack after row-49 recorded')

    # S6: a changed obligation still needs fresh evidence.
    scenario('S6 a changed row (new evidence text) voids the old receipt')
    new_home('s6')
    publish(rows_of(1))
    _, b = drain('presents row-0')
    act('row-0')
    rec = stored()
    rec['rows'][0]['evidence'] = 'captain replied: needs a new plan'
    (home / 'state/open-loops.json').write_text(json.dumps(rec))
    say('   (heartbeat republishes row-0 with different evidence)')
    check('changed row (must refuse)')
    ack(b, 'ack on changed row (must refuse)')

    # S7: reviewed-green PRs never stand into the next turn.
    scenario('S7 review_pass_not_merged row needs a new action every turn')
    new_home('s7')
    publish(rows_of(1, category='review_pass_not_merged'))
    _, b = drain('turn 1')
    act('row-0')
    drain('re-read in turn 1')
    ack(b, 'turn 1 ack')
    clock += 60
    _, b = drain('turn 2')
    if b:
        ack(b, 'turn 2 ack without new action (must refuse)')

    # S8: second deferral still refused and needs follow-up.
    scenario('S8 a second deferral is refused and needs real follow-up')
    new_home('s8')
    publish(rows_of(1))
    _, b = drain('turn 1')
    recheck = dt.datetime.fromtimestamp(clock + 600, dt.timezone.utc).isoformat()
    r = act('row-0', 'deferred', 'short wait', '--recheck', recheck)
    say(f'$ fm-open-loops.sh action row-0 deferred   exit={r.returncode}')
    ack(b, 'turn 1 ack')
    r = act('row-0', 'deferred', 'another wait', '--recheck', recheck)
    say(f'$ fm-open-loops.sh action row-0 deferred (2nd)   exit={r.returncode} | {(r.stdout+r.stderr).strip()[:150]}')
    check('after 2nd deferral (must refuse)')

    # S9: stalled worker pane timer ticking does not void; a different task does.
    scenario('S9 stalled worker: pane timer tick keeps the action; a real change voids it')
    new_home('s9')
    stalled = rows_of(1, category='stalled_worker', subject='job', owner='worker:job',
                      next_action='follow up on the recorded wait and recover the worker')
    stalled[0]['evidence'] = 'Running lint… (3m 12s · esc to interrupt); 3600s without progress'
    publish(stalled)
    _, b = drain('presents stalled row')
    act('row-0')
    for ev, note in (('Running lint… (3m 13s · esc to interrupt); 3660s without progress', 'timer ticked'),
                     ('Running tests… (3m 13s · esc to interrupt); 3660s without progress', 'different task')):
        rec = stored()
        rec['rows'][0]['evidence'] = ev
        (home / 'state/open-loops.json').write_text(json.dumps(rec))
        say(f'   (heartbeat: evidence -> {ev!r})')
        check(note)

    # S10: the pipeline --report | filter | action --batch - must not deadlock on the ledger lock.
    if HAS_BATCH:
        scenario('S10 pipe --report straight into action --batch - (no deadlock)')
        new_home('s10')
        publish(rows_of(5))
        _, b = drain('presents 5')
        filt = ("python3 -c 'import sys,json,re\n"
                "[print(json.dumps(dict(row_id=m,kind=\"escalated\",evidence=\"reported decision\")))"
                " for m in re.findall(r\"^  \\\"(row-[0-9]+)\\\"\", sys.stdin.read(), re.M)]'")
        pipe = f'"{loops}" --report | {filt} | "{loops}" action --batch -'
        t0 = time.monotonic()
        try:
            r = run(None, shell=pipe)
            say(f'$ fm-open-loops.sh --report | <filter> | fm-open-loops.sh action --batch -   exit={r.returncode}'
                f' recorded={r.stdout.count(chr(34)+"recorded"+chr(34))} wall={time.monotonic()-t0:.2f}s')
        except subprocess.TimeoutExpired:
            say('$ pipeline HUNG (timeout 600s)')
        ack(b, 'ack after piped batch')
finally:
    shutil.rmtree(world)
