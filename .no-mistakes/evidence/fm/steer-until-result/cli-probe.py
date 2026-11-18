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

def show(label, r):
    print(f'$ {label}\n  exit={r.returncode}\n  ' + (r.stdout+r.stderr).strip().replace('\n','\n  ')[:900], flush=True)
print('=== S1 steer + ack-only; hidden before limit, back at limit')
c = Case('s1')
print('row', c.ident, 'limit', c.row['limit_seconds'])
c.delivery(); show('action steered --evidence 001.msg', c.steer())
c.now = base + 60
with c.status.open('a') as s: s.write(f'working [at={c.now}]: got your message, thanks\n')
c.now = base + 1799; c.collect(); r = c.cli('--present-overdue'); print('t+1799 row presented:', c.ident in r.stdout)
c.now = base + 1800; r = c.cli('--present-overdue'); print('t+1800 row presented:', c.ident in r.stdout); show('--present-overdue', r)
show('re-steer same proof at deadline', c.steer(expected=None))
print('=== S2 genuine resolution clears the row')
with c.status.open('a') as s: s.write(f'resolved [at={c.now}] [key=question]: original decision applied\n')
print('row still present after resolved:', any(x['id']==c.ident for x in c.collect()['rows']))
print('=== S3 future and missing delivery refused')
c = Case('s3')
show('steer missing 999.msg', c.steer('999.msg', expected=None))
c.delivery(at=base+600); show('steer future-dated 001.msg', c.steer(expected=None))
print('=== S4 unavailable consumer reopens immediately')
c = Case('s4'); c.delivery(); c.steer(); c.collect(); print('presented after steer:', c.ident in c.cli('--present-overdue').stdout)
c.now = base + 5; c.unavailable(); c.collect(); r = c.cli('--present-overdue'); print('presented at t+5 after worker gone:', c.ident in r.stdout); show('--present-overdue', r)
print('=== S5 zero-limit second deferral remedy text')
for lim in (0, 17):
    c = Case(f's5-{lim}', limit=lim)
    c.cli('action', c.ident, 'deferred', '--evidence', 'awaiting vendor', '--recheck', iso(c.now+3600))
    show(f'limit={lim} second deferred', c.cli('action', c.ident, 'deferred', '--evidence', 'awaiting vendor', '--recheck', iso(c.now+3600), expected=None))
print('forbidden external calls:', (world/'forbidden-calls').read_text() if (world/'forbidden-calls').exists() else 'none')
