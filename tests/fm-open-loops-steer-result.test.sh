#!/usr/bin/env bash
# Result-follow-through through the public collector, presentation and action interfaces.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-open-loops-steer-result)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

root, world = map(Path, sys.argv[1:])
code, fake = world / 'code', world / 'fakebin'
shutil.copytree(root / 'bin', code / 'bin')
fake.mkdir()
for name in ('ssh', 'gh', 'gh-axi', 'claude', 'codex', 'dsh', 'omp', 'ps'):
    tool = fake / name
    # Existing command-progress telemetry samples slow local children on macOS.
    # Stub only that exact sample; an endpoint or worker process probe still fails.
    telemetry = ('if [ "$#" -eq 3 ] && [ "$1" = -S ] && [ "$2" = -axo ] && '
                 '[ "$3" = "pid=,ppid=,time=,stat=,lstart=" ]; then exit 0; fi\n') if name == 'ps' else ''
    tool.write_text('#!/bin/sh\n' + telemetry + 'printf "%s\\n" "$0 $*" >> "$FORBIDDEN_CALLS"\nexit 97\n')
    tool.chmod(0o755)
snapshot = code / 'bin/fm-fleet-snapshot.sh'
snapshot.write_text('#!/usr/bin/env python3\nimport os, sys\nfrom pathlib import Path\n'
                    'if sys.argv[1:] == ["--contribution-input"]:\n'
                    '    print(\'{"backlog":{"present":true,"records":[{"state":"in_flight"}]}}\')\n'
                    'else:\n'
                    '    print((Path(os.environ["FM_HOME"])/"snapshot.json").read_text())\n')
snapshot.chmod(0o755)
peek = code / 'bin/fm-peek.sh'
peek.write_text('#!/bin/sh\nprintf "waiting for validation\\n"\n')
peek.chmod(0o755)
send = code / 'bin/fm-send.sh'
send.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FM_HOME/sent"\n')
send.chmod(0o755)
base = int(time.time())
iso = lambda stamp: dt.datetime.fromtimestamp(stamp, dt.timezone.utc).isoformat()

class Case:
    def __init__(self, name, limit=None, category='unanswered_question', kind='ship'):
        self.home = (world / name).resolve()
        for part in ('state', 'data', 'config', 'projects', 'user', 'tmp'):
            (self.home / part).mkdir(parents=True)
        self.now = base
        self.status = self.home / 'state/worker.status'
        opened = base - max(7200, 2 * (limit or 0))
        line = (f'needs-decision [at={opened}] [key=question]: apply the original decision\n'
                if category == 'unanswered_question' else f'working [at={opened}]: continue validation\n')
        self.status.write_text(line)
        meta = self.home / 'state/worker.meta'
        meta.write_text(f'kind={kind}\nspawn_gen=result-generation\n')
        for path in (self.status, meta):
            stamp = opened if category == 'stalled_worker' and path == self.status else base
            os.utime(path, (stamp, stamp))
        if limit is not None:
            (self.home / 'config/open-loops.json').write_text(json.dumps(dict(age_limits_seconds={category: limit})))
        self.task = dict(id='worker', kind=kind, project='', branch='', backend='fixture',
                         spawn_gen='result-generation', current_state=dict(
                             state='blocked' if category == 'unanswered_question' else 'working', source='fixture'),
                         endpoint=dict(exists=True, agent_alive='alive', target='fixture'),
                         pr=dict(url=None), paths=dict(worktree=dict(path=None)), hints={})
        if kind == 'secondmate':
            self.task['paths']['home'] = dict(path=str(self.home / 'secondmate'))
            (self.home / 'secondmate').mkdir()
        self.save_snapshot()
        self.env = dict(os.environ, HOME=str(self.home / 'user'), TMPDIR=str(self.home / 'tmp'),
                        FM_HOME=str(self.home), NM_HOME=str(self.home / 'nm'), FM_DURATION_FILE='off',
                        FM_SUPERVISION_ACTOR='main', PYTHONDONTWRITEBYTECODE='1',
                        FORBIDDEN_CALLS=str(world / 'forbidden-calls'), PATH=str(fake)+':'+os.environ['PATH'])
        for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
            self.env.pop(key, None)
        self.report = self.collect()
        self.row = next(row for row in self.report['rows'] if row['category'] == category)
        self.ident = self.row['id']
        assert self.ident in self.cli('--present-overdue').stdout

    def save_snapshot(self):
        (self.home / 'snapshot.json').write_text(json.dumps(dict(
            schema='fm-fleet-home-input.v1', tasks=[self.task], backlog=dict(present=True, records=[]))))

    def cli(self, *args, expected=0):
        result = subprocess.run([str(code / 'bin/fm-open-loops.sh'), *args],
                                env=dict(self.env, FM_OPEN_LOOPS_NOW=str(self.now)), text=True, capture_output=True)
        if expected is not None:
            assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        return result

    def collect(self):
        self.report = json.loads(self.cli('--heartbeat', '--json').stdout)
        return self.report

    def current(self):
        return next(row for row in self.report['rows'] if row['id'] == self.ident)

    def delivery(self, name='001.msg', at=None):
        inbox = self.home / 'state/worker.inbox'
        inbox.mkdir(exist_ok=True)
        path = inbox / name
        path.write_text(f'schema=fm-task-inbox.v1\nat={iso(self.now if at is None else at)}\n--\nApply the original decision.\n')
        return path

    def steer(self, name='001.msg', expected=0):
        return self.cli('action', self.ident, 'steered', '--evidence', name, expected=expected)

    def actionable(self, wanted, refresh=True):
        if refresh:
            self.collect()
        presented = self.cli('--present-overdue').stdout
        checked = self.cli('--check-actions', expected=None)
        assert (self.ident in presented) is wanted, (self.home.name, wanted, presented)
        assert (self.ident in checked.stdout) is wanted, (wanted, checked.stdout)
        if wanted:
            assert 'steered, result not observed' in presented, presented
        return self.current()

    def unavailable(self, generation='result-generation'):
        self.task.update(spawn_gen=generation, current_state=dict(
            state='unknown', source='fixture', detail='backend target gone: fixture'))
        self.task['endpoint'] = dict(exists=False, agent_alive='dead', target='fixture')
        self.save_snapshot()

    def available(self):
        self.task.update(spawn_gen='result-generation', current_state=dict(state='blocked', source='fixture'))
        self.task['endpoint'] = dict(exists=True, agent_alive='alive', target='fixture')
        self.save_snapshot()

# Default limit: delivery and acknowledgement buy time, not permanent silence.
c = Case('default')
assert c.row['limit_seconds'] == 1800
c.steer('999.msg', expected=1)
c.delivery(at=base+1)
c.steer(expected=1)  # future timestamps cannot create a perpetual freshness window
message = c.delivery()
c.steer()
c.cli('--check-actions')
c.now = base + 1
handled = c.home / 'state/worker.inbox/handled'
handled.mkdir()
assert message.resolve() == (c.home / 'state/worker.inbox/001.msg').resolve()
destination = handled / '001.msg'
assert destination.resolve() == (c.home / 'state/worker.inbox/handled/001.msg').resolve() and not destination.exists()
message.rename(destination)
with c.status.open('a') as stream:
    stream.write(f'working [at={c.now}]: acknowledged the inbox; the original decision is still open\n')
c.now = base + 900
c.steer()  # reciting the same proof must not start a new deadline
c.now = base + 1799
before = c.actionable(False)['current_identity']
c.now = base + 1800
c.actionable(True, refresh=False)
c.steer(expected=1)
due = c.actionable(True)['current_identity']
assert due != before
c.now += 1
with c.status.open('a') as stream:
    stream.write(f'working [at={c.now}]: unrelated progress does not apply the original decision\n')
assert c.actionable(True)['current_identity'] == due
c.steer(expected=1)
c.delivery('002.msg')
c.steer('002.msg')
assert c.actionable(False)['current_identity'] == due, 'renewal itself must not replay its notification'
c.now += 1800
assert c.actionable(True)['current_identity'] != due, 'the next unanswered delivery needs its own notification'
with c.status.open('a') as stream:
    stream.write(f'resolved [at={c.now}] [key=question]: original decision applied\n')
assert not any(row['id'] == c.ident for row in c.collect()['rows'])
print('PASS: default result deadline, no-refresh checking, acknowledgement, retry origin and actual resolution', flush=True)

# A non-question producer category reaches the same bounded receipt and current-turn rule.
c = Case('ordinary-stalled-work', category='stalled_worker')
assert c.row['limit_seconds'] == 3600
c.delivery(); c.steer()
c.now = base + 3599
c.actionable(False, refresh=False)
c.now = base + 3600
c.actionable(True, refresh=False)
c = Case('ordinary-work-resumed', category='stalled_worker')
c.delivery(); c.steer()
c.now = base + 3500
with c.status.open('a') as stream:
    stream.write(f'working [at={c.now}]: resumed the requested validation step\n')
os.utime(c.status, (c.now, c.now))
c.now = base + 3600
assert not any(row['id'] == c.ident for row in c.collect()['rows'])
assert c.ident not in c.cli('--present-overdue').stdout
print('PASS: stalled work returns at its own limit unless existing progress evidence shows it resumed', flush=True)

# A check-in acknowledgement or a pending delivery is not the requested report.
for mode in ('ack-only', 'actual-report', 'pending-reply'):
    c = Case('silence-' + mode, category='silent_report', kind='secondmate' if mode == 'pending-reply' else 'ship')
    assert c.row['limit_seconds'] == 900
    if mode == 'pending-reply':
        reply_dir = c.home / 'state/pending-replies'
        reply_dir.mkdir()
        proof = 'abcd0123456789ef'
        reply = reply_dir / proof
        delivery = f'task_id=worker\ndelivered_epoch={base}\n'
        reply.write_text(delivery + 'phase=delivered\n')
        c.steer(proof)
    else:
        message = c.delivery(); c.steer()
        c.now = base + 800
        handled = c.home / 'state/worker.inbox/handled'
        handled.mkdir()
        destination = handled / '001.msg'
        assert message.resolve() == c.home / 'state/worker.inbox/001.msg'
        assert destination.resolve() == c.home / 'state/worker.inbox/handled/001.msg' and not destination.exists()
        message.rename(destination)
        os.utime(handled, (c.now, c.now))
        if mode == 'actual-report':
            with c.status.open('a') as stream:
                stream.write(f'blocked [at={c.now}]: reported the validation outcome; waiting on the original decision\n')
    c.now = base + 899
    c.actionable(False)
    c.now = base + 900
    row = c.actionable(mode != 'actual-report', refresh=False)
    assert (row['id'], row['owner'], row['next_action']) == (c.ident, c.row['owner'], c.row['next_action'])
    c.actionable(mode != 'actual-report')
    if mode == 'pending-reply':
        c.now = base + 901
        reply.write_text(delivery + f'phase=resolved\nresolved_epoch={c.now}\n')
        c.actionable(False)
print('PASS: formal silence steers ignore transport-only activity but keep genuine reports and resolved replies', flush=True)

# A plain working line is not a result: only a typed status or a resolved reply settles a silence steer,
# whatever second the line carries relative to the delivery.
for mode in ('ack-and-working-same-second', 'working-after-ack', 'working-before-steer-same-second'):
    c = Case('plain-working-' + mode, category='silent_report')
    assert c.row['limit_seconds'] == 900
    if mode == 'working-before-steer-same-second':
        with c.status.open('a') as stream:
            stream.write(f'working [at={base}]: status written in the second the steer is delivered\n')
    message = c.delivery(); c.steer()
    c.now = base + 800
    handled = c.home / 'state/worker.inbox/handled'
    handled.mkdir()
    message.rename(handled / '001.msg')
    os.utime(handled, (c.now, c.now))
    if mode != 'working-before-steer-same-second':
        later = c.now + (1 if mode == 'working-after-ack' else 0)
        with c.status.open('a') as stream:
            stream.write(f'working [at={later}]: acknowledged the inbox; no report yet\n')
    c.now = base + 899
    c.actionable(False)
    c.now = base + 900
    c.actionable(True, refresh=False)
    c.actionable(True)
print('PASS: an acknowledgement-only or pre-steer plain working status never settles a silence steer', flush=True)

# Control: a typed report that follows the acknowledgement and a plain working line still settles the steer.
c = Case('plain-working-then-typed-report', category='silent_report')
message = c.delivery(); c.steer()
c.now = base + 800
handled = c.home / 'state/worker.inbox/handled'
handled.mkdir()
message.rename(handled / '001.msg')
os.utime(handled, (c.now, c.now))
with c.status.open('a') as stream:
    stream.write(f'working [at={c.now}]: acknowledged the inbox; no report yet\n')
c.now = base + 850
with c.status.open('a') as stream:
    stream.write(f'blocked [at={c.now}]: reported the validation outcome; waiting on the original decision\n')
c.now = base + 900
c.actionable(False)
print('PASS: a typed report after an acknowledgement and a plain working line still settles a silence steer', flush=True)

# A typed failed status, or a secondmate typed done status, keeps the ordinary silence cadence and check-in.
for kind, verb in (('ship', 'failed'), ('secondmate', 'done')):
    c = Case('cadence-' + verb + '-' + kind, category='silent_report', kind=kind)
    with c.status.open('a') as stream:
        stream.write(f'{verb} [at={base}]: reported the validation outcome\n')
    c.now = base + 899
    c.collect()
    assert not c.current()['overdue'], (c.home.name, c.current())
    c.now = base + 900
    c.collect()
    row = c.current()
    assert row['overdue'] and not row.get('informational'), (c.home.name, row)
    assert c.ident in c.cli('--present-overdue').stdout, c.home.name
    assert json.loads(c.cli('--check-in', 'worker', '--json').stdout).get('check_in') == 'sent', c.home.name
    assert (c.home / 'sent').read_text().startswith('worker --answers-none '), c.home.name
print('PASS: a typed failed or secondmate done status keeps the silence row visible and allows a check-in', flush=True)

# A typed failed or secondmate done line settles a silence steer only in a later second than the delivery.
for kind, verb, same in (('ship', 'failed', False), ('secondmate', 'done', False), ('ship', 'failed', True)):
    c = Case('typed-' + verb + '-' + kind + ('-same-second' if same else ''), category='silent_report', kind=kind)
    if same:
        with c.status.open('a') as stream:
            stream.write(f'{verb} [at={base}]: status written in the second the steer is delivered\n')
    message = c.delivery(); c.steer()
    c.now = base + 800
    handled = c.home / 'state/worker.inbox/handled'
    handled.mkdir()
    message.rename(handled / '001.msg')
    os.utime(handled, (c.now, c.now))
    if not same:
        with c.status.open('a') as stream:
            stream.write(f'{verb} [at={c.now}]: reported the validation outcome\n')
    c.now = base + 899
    c.actionable(False)
    c.now = base + 900
    c.actionable(same, refresh=False)
    c.actionable(same)
print('PASS: a later-second typed failed or secondmate done line settles a silence steer; a same-second one does not',
      flush=True)

# A reply resolved in the delivery's own second cannot be ordered after it; only a later-second reply settles.
for mode in ('reply-same-second', 'reply-later-second'):
    c = Case('silence-' + mode, category='silent_report')
    reply_dir = c.home / 'state/pending-replies'
    reply_dir.mkdir()
    reply = reply_dir / '0123456789abcdef'
    question = 'corr_id=0123456789abcdef\ntask_id=worker\ndelivered_epoch=' + str(base - 60) + '\n'
    reply.write_text(question + 'phase=delivered\n')
    message = c.delivery()
    if mode == 'reply-same-second':
        reply.write_text(question + f'phase=resolved\nresolved_epoch={base}\n')
    c.steer()
    if mode == 'reply-later-second':
        c.now = base + 1
        reply.write_text(question + f'phase=resolved\nresolved_epoch={c.now}\n')
    c.now = base + 800
    handled = c.home / 'state/worker.inbox/handled'
    handled.mkdir()
    message.rename(handled / '001.msg')
    os.utime(handled, (c.now, c.now))
    c.now = base + 899
    c.actionable(False)
    c.now = base + 900
    c.actionable(mode == 'reply-same-second')
print('PASS: a reply resolved in the steer second never settles it; a later-second reply still does', flush=True)

# Loss of a source that requires a live worker is not evidence that the steer succeeded.
for category, kind in (('stalled_worker', 'ship'), ('silent_report', 'ship'), ('silent_report', 'secondmate')):
    c = Case('worker-loss-' + category + '-' + kind, category=category, kind=kind)
    c.delivery(); c.steer()
    c.now += 1
    os.utime(c.status, (c.now, c.now))  # missing-worker age alone will not wake the owner yet
    c.unavailable()
    for _ in range(2):
        row = c.actionable(True)
        assert (row['id'], row['owner'], row['next_action']) == (c.ident, c.row['owner'], c.row['next_action'])
        assert not any(row['overdue'] for row in c.report['rows'] if row['category'] == 'missing_worker')
        c.now += 1
    c.task['current_state'] = dict(state='done', source='fixture')
    c.save_snapshot()
    assert not any(row['id'] == c.ident and row['overdue'] for row in c.collect()['rows'])
print('PASS: live-only steered obligations remain actionable on endpoint loss, but are not resurrected after completion', flush=True)

# Batch and single actions must enforce the same deadline and unchanged owner/action.
c = Case('batch-delivery')
c.delivery()
batch = c.home / 'actions.jsonl'
batch.write_text(json.dumps(dict(row_id=c.ident, kind='steered', evidence='001.msg'))+'\n')
c.cli('action', '--batch', str(batch))
c.now = base + 1799
c.actionable(False, refresh=False)
c.now = base + 1801
row = c.actionable(True)
assert (row['owner'], row['next_action'], row['subject']) == (c.row['owner'], c.row['next_action'], c.row['subject'])
c.cli('action', '--batch', str(batch), expected=1)
print('PASS: batch steering shares the row deadline and cannot renew expired evidence', flush=True)

# Refused delivery never covers the original obligation, even before its deadline.
c = Case('failed-delivery')
c.steer('missing.msg', expected=1)
c.delivery(at=base+1)
c.steer(expected=1)
for offset in (0, 1799):
    c.now = base + offset
    assert c.ident in c.cli('--present-overdue').stdout
    assert c.ident in c.cli('--check-actions', expected=1).stdout
print('PASS: failed and unconfirmed delivery cannot cover the original actionable row', flush=True)

# The existing shared collection notices an unavailable SAME-generation consumer early.
c = Case('unavailable')
c.delivery(); c.steer()
c.now += 1
c.unavailable()
row = c.actionable(True)
assert row['consumer']['available'] is False
assert not next(row for row in c.report['rows'] if row['category'] == 'missing_worker')['overdue']
c.steer(expected=1)
c.now += 1
c.available()
c.actionable(True)  # consumer recovery is not proof the original decision was applied
c.steer(expected=1)
c.delivery('002.msg'); c.steer('002.msg'); c.actionable(False)
print('PASS: authoritative unavailability reopens the original obligation before the missing-worker deadline; recovery cannot revive old proof', flush=True)

# A consumer already known unavailable cannot acquire standing cover from a delivery.
c = Case('already-unavailable')
c.unavailable(); c.collect(); c.delivery(); c.steer(expected=1)
c.collect()
assert c.ident in c.cli('--present-overdue').stdout
assert c.ident in c.cli('--check-actions', expected=1).stdout
print('PASS: already-known unavailability refuses steering cover without needing a healthy-to-dead transition', flush=True)

# A negative observation for another generation must never be attributed by name alone.
c = Case('foreign-generation')
c.delivery(); c.steer()
c.now += 1
c.unavailable('different-generation')
assert 'consumer' not in c.actionable(False)
c.now = base + 1800
c.actionable(True)
print('PASS: a foreign-generation negative cannot invalidate a current delivery, whose own deadline still applies', flush=True)

# Non-generation metadata updates must not mask unavailability of the same launched consumer.
c = Case('same-spawn-metadata-update')
c.delivery(); c.steer()
with (c.home / 'state/worker.meta').open('a') as stream:
    stream.write('pr_head=metadata-only-update\n')
c.now += 1
c.unavailable()
c.actionable(True)
print('PASS: unrelated metadata updates do not conceal same-spawn consumer unavailability', flush=True)

# The current verified successor launch, not a stale predecessor, owns current availability.
c = Case('verified-successor-launch')
c.delivery(); c.steer()
(c.home / 'state/worker.meta').write_text('kind=ship\nspawn_gen=successor-generation\n')
c.task['spawn_gen'] = 'successor-generation'
c.save_snapshot(); c.now += 1
c.actionable(False)
c.now += 1
c.unavailable('successor-generation')
c.actionable(True)
print('PASS: a verified current successor launch becoming unavailable cannot hide behind its predecessor delivery', flush=True)

# Missing generation and unknown liveness do not manufacture proof of a healthy consumer.
for mode in ('legacy', 'unknown'):
    c = Case(mode)
    c.delivery(); c.steer()
    c.now += 1
    if mode == 'legacy':
        c.task.pop('spawn_gen')
        c.unavailable(None)
    else:
        c.task['endpoint'] = dict(exists=None, agent_alive='unknown', target='')
        c.save_snapshot()
    row = c.actionable(False)
    assert row.get('consumer', {}).get('available') is not True
    c.now = base + 1800
    c.actionable(True)
print('PASS: legacy and unknown availability retain a bounded wait, never indefinite standing cover', flush=True)

# A stale negative cannot prove present unavailability, but its delivery still expires.
c = Case('stale-availability')
c.delivery(); c.steer()
ledger = c.home / 'state/open-loops.json'
report = json.loads(ledger.read_text())
row = next(row for row in report['rows'] if row['id'] == c.ident)
row['consumer']['available'] = False
row['stale'] = True
report['stale'] = True
ledger.write_text(json.dumps(report))
c.now += 1
c.actionable(False, refresh=False)
c.now = base + 1800
c.actionable(True, refresh=False)
print('PASS: a stale negative is not a current consumer verdict and cannot extend the delivery deadline', flush=True)

# An omitted limit, a custom limit, and zero all use the collected policy rather than another timer.
for limit in (17, 0):
    c = Case('limit-' + str(limit), limit=limit)
    assert c.row['limit_seconds'] == limit
    c.delivery(); c.steer(); c.actionable(False)
    if limit:
        c.now = base + limit - 1
        c.actionable(False, refresh=False)
    c.now = base + (limit if limit else 1)
    c.actionable(True, refresh=False)
    c.steer(expected=1)
for limit in (17, 0):
    c = Case('deferral-remedy-' + str(limit), limit=limit)
    c.cli('action', c.ident, 'deferred', '--evidence', 'awaiting vendor', '--recheck', iso(c.now + 3600))
    refused = c.cli('action', c.ident, 'deferred', '--evidence', 'awaiting vendor', '--recheck', iso(c.now + 3600),
                    expected=1)
    assert 'second deferral refused' in refused.stdout, refused
    assert ('steer' in refused.stdout) is bool(limit), refused.stdout
    assert 'escalate it' in refused.stdout, refused.stdout
print('PASS: a zero-limit second deferral names only remedies that can stand, not an expiring steer', flush=True)
c = Case('long-row-limit', limit=86400)
c.delivery(); c.steer()
c.now = base + 14400
c.actionable(False, refresh=False)
c.steer(expected=1)  # existing four-hour input freshness is not a different standing-result deadline
c.now = base + 86400
c.actionable(True, refresh=False)
print('PASS: configured and zero result limits use the row policy while recording preserves four-hour delivery freshness', flush=True)

# A reviewed-green PR still has its independent four-hour current-presentation guard.
c = Case('reviewed-pr-answer-bound', limit=86400)
ledger = c.home / 'state/open-loops.json'
report = json.loads(ledger.read_text())
row = next(row for row in report['rows'] if row['id'] == c.ident)
row.update(category='review_pass_not_merged', subject='https://github.com/test/project/pull/1')
ledger.write_text(json.dumps(report))
c.cli('--present-overdue'); c.delivery(); c.steer()
c.now = base + 14399
c.cli('--check-actions')
c.now = base + 14400
assert c.ident in c.cli('--check-actions', expected=1).stdout
print('PASS: an extended row policy cannot widen the reviewed-PR current-turn freshness guard', flush=True)

# Legacy receipts and source-less/remote obligations still get bounded result follow-up.
for mode in ('source-less', 'legacy-receipt', 'remote'):
    c = Case(mode)
    if mode == 'source-less':
        ledger = c.home / 'state/open-loops.json'
        report = json.loads(ledger.read_text())
        next(row for row in report['rows'] if row['id'] == c.ident).pop('source', None)
        ledger.write_text(json.dumps(report))
    if mode == 'remote':
        pending = c.home / 'state/pending-replies'
        pending.mkdir()
        record = 'abcdef0123456789'
        (pending / record).write_text('task_id=worker\ndelivered_epoch=\n')
        c.steer(record, expected=1)
        (pending / record).write_text('task_id=worker\ndelivered_epoch='+str(base)+'\n')
        c.now = base + 900
        c.steer(record)
        c.now = base + 1799
        c.steer(record)
        c.actionable(False, refresh=False)
    else:
        c.delivery(); c.steer()
    if mode == 'legacy-receipt':
        ledger = c.home / 'state/open-loops.json'
        report = json.loads(ledger.read_text())
        report['handling']['actions'][c.ident].pop('sent_epoch')
        report['handling']['actions'][c.ident].pop('consumer_source', None)
        ledger.write_text(json.dumps(report))
    c.now = base + 1800
    c.actionable(True, refresh=False)
print('PASS: legacy, source-less and delivered remote receipts cannot hide unresolved work indefinitely', flush=True)

assert not (world / 'forbidden-calls').exists(), (world / 'forbidden-calls').read_text()
PY
pass 'result-follow-through retains the original owner and requires actual reconciliation'
