#!/usr/bin/env bash
# Recurring status questions through the public collector, presentation and action
# CLI. Clockless and same-clock openings are different work after a resolution;
# unchanged work, real authority holds and live prerequisites keep their receipts.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-open-loops-episodes)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, world = map(Path, sys.argv[1:])
code = world / 'code'
shutil.copytree(root / 'bin', code / 'bin', ignore=lambda _path, _names: {'fm-fleet-snapshot.sh'})
snapshot = code / 'bin/fm-fleet-snapshot.sh'
snapshot.write_text('#!/usr/bin/env python3\nimport os,pathlib,sys\n'
                    'assert sys.argv[1:] in [["--home-input"],["--contribution-input"]]\n'
                    'sys.stdout.write((pathlib.Path(os.environ["FM_HOME"])/"snapshot.json").read_text())\n')
snapshot.chmod(0o755)
crew = world / 'crew-state'
crew.write_text('#!/usr/bin/env python3\nimport os,pathlib,sys\n'
                'p=pathlib.Path(os.environ["FM_HOME"])/"prerequisite-state"\n'
                'print("state: "+p.read_text().strip()+" · source: pane · synthetic prerequisite")\n')
crew.chmod(0o755)
now = 1800000000
iso = lambda value: dt.datetime.fromtimestamp(value, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


class Home:
    def __init__(self, name, opening='stamped'):
        self.path = world / name
        for directory in ('state', 'data', 'config', 'projects', 'user', 'tmp'):
            (self.path / directory).mkdir(parents=True)
        self.clock = now
        self.env = {key: value for key, value in os.environ.items() if key in ('PATH', 'SYSTEMROOT')}
        self.env.update(HOME=str(self.path / 'user'), TMPDIR=str(self.path / 'tmp'),
                        NM_HOME=str(self.path / 'nm'), FM_HOME=str(self.path), FM_ROOT_OVERRIDE=str(self.path),
                        FM_CREW_STATE_BIN=str(crew), PYTHONDONTWRITEBYTECODE='1',
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', FM_DURATION_FILE='off')
        for key, directory in (('STATE', 'state'), ('DATA', 'data'), ('CONFIG', 'config'), ('PROJECTS', 'projects')):
            self.env['FM_' + key + '_OVERRIDE'] = str(self.path / directory)
        self.snapshot = dict(schema='fm-fleet-home-input.v1', tasks=[], backlog=dict(present=True, records=[]))
        self.save_snapshot()
        self.status = self.path / 'state/job.status'
        (self.path / 'state/job.meta').write_text('kind=scout\nspawn_gen=synthetic-job\n')
        self.open(opening)
        self.collect()
        self.row = self.question()
        assert self.row['overdue'], self.row
        self.present(True)

    def call(self, *args, expected=0):
        run = subprocess.run([str(code / 'bin/fm-open-loops.sh'), *map(str, args)],
                             env=dict(self.env, FM_OPEN_LOOPS_NOW=str(self.clock)), cwd=self.path,
                             stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=60)
        assert run.returncode == expected, (self.path.name, args, run.returncode, run.stdout, run.stderr)
        return run

    def append(self, text):
        with self.status.open('a') as stream:
            stream.write(text + '\n')

    def open(self, stamp):
        tag = f'[at={now - 7200}] ' if stamp == 'stamped' else '[at=unreadable] ' if stamp == 'malformed' else ''
        self.append('needs-decision ' + tag + '[key=gate]: choose validation action')

    def save_snapshot(self):
        (self.path / 'snapshot.json').write_text(json.dumps(self.snapshot))

    def collect(self):
        report = json.loads(self.call('--heartbeat', '--json').stdout)
        assert report['complete'], report
        return report

    def ledger(self):
        return json.loads((self.path / 'state/open-loops.json').read_text())

    def question(self, key='gate'):
        return next(row for row in self.ledger()['rows'] if row['subject'] == 'job:' + key)

    def present(self, needed):
        shown = self.call('--present-overdue')
        assert (self.question()['id'] in shown.stdout) == needed, (self.path.name, needed, shown.stdout)

    def check(self, needed):
        self.call('--check-actions', expected=int(needed))

    def message(self, task='job', name='001.msg', body='follow up', handled=True):
        inbox = self.path / ('state/' + task + '.inbox')
        if handled:
            inbox /= 'handled'
        inbox.mkdir(parents=True, exist_ok=True)
        (inbox / name).write_text('schema=fm-task-inbox.v1\nat=' + iso(self.clock) + '\n--\n' + body + '\n')
        return name

    def act(self, kind='steered'):
        ident = self.question()['id']
        if kind == 'steered':
            args = ('steered', '--evidence', self.message())
        elif kind == 'deferred':
            args = ('deferred', '--evidence', 'bounded wait', '--recheck', iso(now + 7200))
        elif kind == 'bound':
            hold = dict(id='owner-choice', structured=True, state='in_flight', hold_kind='captain',
                        hold_bucket='live', hold_set=iso(now - 7200), since=iso(now - 7200),
                        hold_reason='genuine human choice', requires_child_metadata=False)
            self.snapshot['backlog']['records'] = [hold]
            self.save_snapshot()
            self.collect()
            self.call('--present-overdue')
            captain = next(row for row in self.ledger()['rows'] if row['owner'] == 'captain')
            self.call('action', captain['id'], 'escalated', '--evidence', 'genuine choice remains with owner')
            args = ('escalated', '--evidence', 'decision requested', '--hold', 'owner-choice')
        elif kind == 'waiting':
            self.append(f'needs-decision [at={now - 7200}] [key=prerequisite]: another genuine question')
            self.collect()
            self.call('--present-overdue')
            dependency = self.question('prerequisite')
            self.call('action', dependency['id'], 'escalated', '--evidence', 'prerequisite routed')
            args = ('waiting', '--prerequisite', dependency['id'], '--evidence', 'requires that answer',
                    '--recheck', iso(now + 7200))
        elif kind == 'task-wait':
            (self.path / 'state/helper.meta').write_text('kind=ship\nspawn_gen=synthetic-helper\n')
            (self.path / 'state/helper.status').write_text(f'working [at={now}]: producing prerequisite\n')
            (self.path / 'prerequisite-state').write_text('working\n')
            args = ('waiting', '--prerequisite-task', 'helper', '--evidence',
                    self.message('helper', body='open-loop-row: ' + ident), '--recheck', iso(now + 7200))
        else:
            args = ('escalated', '--evidence', 'question routed')
        self.call('action', ident, *args)
        self.check(False)

    def reopen(self, stamp='unstamped'):
        self.append(f'resolved [at={self.clock}]: [key=gate] earlier gate answered')
        self.open(stamp)
        self.clock += 1801
        self.collect()


# E1: every supported question receipt form must refer to the surviving opening.
# The same stamped value deliberately appears on both sides of one close/reopen;
# timestamp precision is not event identity. Unstamped input is supported as-is.
for kind in ('steered', 'escalated', 'deferred', 'bound', 'waiting', 'task-wait'):
    for opening, successor in (('stamped', 'unstamped'), ('unstamped', 'unstamped'),
                               ('stamped', 'stamped'), ('stamped', 'malformed')):
        home = Home('reopen-' + kind + '-' + opening + '-' + successor, opening)
        home.act(kind)
        old = home.question()
        home.reopen(successor)
        new = home.question()
        assert old['id'] == new['id'], 'a new episode must not duplicate the durable question row'
        assert new['age_seconds'] is None if successor != 'stamped' else new['age_seconds'] == 9001, new
        home.present(True)
        home.check(True)
        print('ok - new ' + opening + '/' + successor + ' question rejects predecessor ' + kind, flush=True)

# E2: fresh processes, no-op publication and unrelated appends cannot reset a receipt.
for kind in ('steered', 'escalated', 'deferred', 'bound', 'waiting', 'task-wait'):
    home = Home('unchanged-' + kind, 'unstamped')
    home.act(kind)
    original = home.question()['source']
    home.clock += 300
    home.collect()
    home.append('working: unrelated progress continues')
    home.collect()
    assert home.question()['source'] == original
    home.present(False)
    home.check(False)
    print('ok - current unstamped ' + kind + ' survives restart, no-op and unrelated progress', flush=True)

# Default lifetimes remain unchanged: a steer covers unchanged work, but stale
# deliveries cannot be recorded again; bounded waits/deferrals expire on time.
home = Home('steer-lifetime')
home.act()
home.clock += 5 * 3600
home.collect()
home.present(False)
home.check(False)
assert 'older than four hours' in home.call('action', home.row['id'], 'steered', '--evidence', '001.msg', expected=1).stdout
for kind in ('deferred', 'waiting', 'task-wait'):
    home = Home('expires-' + kind)
    home.act(kind)
    home.clock = now + 7200
    home.present(True)
    home.check(True)
print('ok - production steer evidence age and wait/deferral deadlines are unchanged', flush=True)

# Prerequisite truth is rechecked without publication: its end must not be
# hidden by the unchanged source question or the still-future recheck deadline.
for kind, ending in (('waiting', 'resolved'), ('task-wait', 'failed')):
    home = Home('ended-' + ending)
    home.act(kind)
    before = (home.path / 'state/open-loops.json').read_bytes()
    home.clock += 1
    if kind == 'waiting':
        home.append('resolved [key=prerequisite]: answered')
    else:
        (home.path / 'prerequisite-state').write_text('failed\n')
        (home.path / 'state/helper.status').write_text('failed: prerequisite could not be produced\n')
    assert (home.path / 'state/open-loops.json').read_bytes() == before
    home.present(True)
    home.check(True)
    print('ok - ' + ending + ' prerequisite reopens follow-up before recollection', flush=True)

# Ending an actual authority hold restores follow-up, never grants authority.
home = Home('hold-release')
home.act('bound')
home.snapshot['backlog']['records'] = []
home.save_snapshot()
home.present(True)
home.check(True)
print('ok - ended authority hold restores the existing reconciliation path', flush=True)

# Migration: reproduce the historical five-field action digest in an otherwise
# real published ledger, not a fabricated source. Recollection must retain the
# unresolved question but stop accepting that unbound legacy action as current.
home = Home('legacy-status', 'unstamped')
home.act()
ledger = home.ledger()
row = home.question()
fields = [row.get(key) for key in ('category', 'subject', 'owner', 'next_action', 'evidence')]
ledger['handling']['actions'][row['id']]['digest'] = hashlib.sha256(json.dumps(fields).encode()).hexdigest()[:24]
(home.path / 'state/open-loops.json').write_text(json.dumps(ledger))
home.collect()
home.present(True)
home.check(True)
home.clock += 1
home.message(name='002.msg')
home.call('action', row['id'], 'steered', '--evidence', '002.msg')
home.collect()
home.present(False)
home.check(False)
print('ok - a legacy status receipt needs one safe refresh without losing its question', flush=True)

# Preserve the historical captain_hold schema-addition compatibility case.
# These are canonical backlog inputs, not status-origin question identities.
home = Home('legacy-captain-hold')
home.snapshot['backlog']['records'] = [dict(id='choice', structured=True, state='in_flight', hold_kind='captain',
    hold_bucket='live', hold_set=iso(now - 7200), since=iso(now - 7200), hold_reason='genuine human choice',
    requires_child_metadata=False)]
home.save_snapshot()
home.collect()
ledger = home.ledger()
captain = next(row for row in ledger['rows'] if row['owner'] == 'captain')
captain.pop('source')
(home.path / 'state/open-loops.json').write_text(json.dumps(ledger))
home.call('--present-overdue')
home.call('action', captain['id'], 'escalated', '--evidence', 'asked the owner')
home.act()
home.clock += 2 * 86400
home.collect()
home.present(False)
home.check(False)
assert home.snapshot['backlog']['records'][0]['hold_kind'] == 'captain'
print('ok - unchanged captain_hold survives provenance addition without releasing the hold', flush=True)

home = Home('inapplicable-merged')
refused = home.call('action', home.row['id'], 'merged', '--evidence', 'https://github.com/test/project/pull/1', expected=1)
assert 'merged evidence' in refused.stdout
home.check(True)
print('ok - a merge receipt cannot be fabricated for a status question', flush=True)
PY
