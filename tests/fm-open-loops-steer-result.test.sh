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
    tool.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$FORBIDDEN_CALLS"\nexit 97\n')
    tool.chmod(0o755)
snapshot = code / 'bin/fm-fleet-snapshot.sh'
snapshot.write_text('#!/usr/bin/env python3\nimport os\nfrom pathlib import Path\nprint((Path(os.environ["FM_HOME"])/"snapshot.json").read_text())\n')
snapshot.chmod(0o755)
peek = code / 'bin/fm-peek.sh'
peek.write_text('#!/bin/sh\nprintf "waiting for validation\\n"\n')
peek.chmod(0o755)
base = int(time.time())
iso = lambda stamp: dt.datetime.fromtimestamp(stamp, dt.timezone.utc).isoformat()

class Case:
    def __init__(self, name, limit=None, category='unanswered_question'):
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
        meta.write_text('kind=ship\nspawn_gen=result-generation\n')
        for path in (self.status, meta):
            stamp = opened if category == 'stalled_worker' and path == self.status else base
            os.utime(path, (stamp, stamp))
        if limit is not None:
            (self.home / 'config/open-loops.json').write_text(json.dumps(dict(age_limits_seconds={category: limit})))
        self.task = dict(id='worker', kind='ship', project='', branch='', backend='fixture',
                         spawn_gen='result-generation', current_state=dict(
                             state='blocked' if category == 'unanswered_question' else 'working', source='fixture'),
                         endpoint=dict(exists=True, agent_alive='alive', target='fixture'),
                         pr=dict(url=None), paths=dict(worktree=dict(path=None)), hints={})
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
        assert (self.ident in presented) is wanted, (wanted, presented)
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
print('PASS: ordinary non-question steering also returns for result follow-up at its own limit', flush=True)

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
    c.now = base + (limit if limit else 1)
    c.actionable(True, refresh=False)
    c.steer(expected=1)
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
