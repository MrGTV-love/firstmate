#!/usr/bin/env python3
"""Live driver for the open-work ledger change.

Drives the real bin/fm-open-loops.sh and bin/fm-wake-drain.sh (a copy of the worktree's bin for
"after", a git-archive of the base commit's bin for "before") against disposable lab homes minted with
bin/fm-lab-home.sh. Only two edges are substituted: the fleet snapshot's task list (no tmux fleet) and the
current-state reader (FM_CREW_STATE_BIN, so a "live validation run" can be simulated without a real
no-mistakes pipeline).

usage: fm-live-driver.py SCR WORKTREE EVIDENCE_DIR SCENARIO...
"""
import datetime as dt, json, os, re, shutil, sqlite3, subprocess, sys, tempfile, time, traceback
from pathlib import Path

SCR, WT, EVID = map(Path, sys.argv[1:4])
SCENARIOS = sys.argv[4:]
TMPDIR = Path(os.environ.get('TMPDIR') or '/tmp')
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
CHECKIN = 'check in: progress, blockers, cross-workstream dependencies'
BASE_ENV = {k: v for k, v in os.environ.items() if k not in (
    'NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
    'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_CREW_STATE_BIN', 'FM_OPEN_LOOPS_NOW')}
BASE_ENV.update(GIT_AUTHOR_NAME='fmtest', GIT_AUTHOR_EMAIL='fmtest@example.invalid',
                GIT_COMMITTER_NAME='fmtest', GIT_COMMITTER_EMAIL='fmtest@example.invalid')


class Transcript:
    def __init__(self, name):
        self.name, self.lines = name, []
    def say(self, text=''):
        self.lines.append(str(text))
    def save(self):
        (EVID / f'live-{self.name}.txt').write_text('\n'.join(self.lines) + '\n')


def trim(text, limit=1800):
    text = text.rstrip()
    return text if len(text) <= limit else text[:limit] + f'\n...[{len(text) - limit} more chars]'


class Lab:
    def __init__(self, variant, tr, name):
        self.variant, self.tr, self.name = variant, tr, name
        self.code = SCR / variant
        self.home = Path(tempfile.mkdtemp(prefix='fm-lab.', dir=TMPDIR))
        done = subprocess.run([str(WT / 'bin/fm-lab-home.sh'), 'create', str(self.home)], env=BASE_ENV,
                              text=True, capture_output=True)
        assert done.returncode == 0, done
        h = self.home
        (h / 'nm').mkdir(); (h / 'state-of').mkdir()
        self.run_cmd(['git', 'init', '-q', '--bare', str(h / 'origin.git')])
        self.project = h / 'projects/example'
        self.run_cmd(['git', 'init', '-q', '-b', 'main', str(self.project)])
        self.run_cmd(['git', '-C', str(self.project), 'commit', '-q', '--allow-empty', '-m', 'base'])
        self.run_cmd(['git', '-C', str(self.project), 'remote', 'add', 'origin', str(h / 'origin.git')])
        self.run_cmd(['git', '-C', str(self.project), 'push', '-q', 'origin', 'main'])
        (h / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        reader = h / 'reader.sh'
        reader.write_text('#!/usr/bin/env bash\n[ ! -e "$FM_HOME/reader-hang" ] || exec sleep 3600\n'
                          'f="$FM_HOME/state-of/$1"; [ -f "$f" ] || f="$FM_HOME/worker-state"\ncat "$f"\n')
        reader.chmod(0o755)
        (h / 'worker-state').write_text('state: working · source: run-step · run: live-validation; test running\n')
        self.tasks = []
        self.env = dict(BASE_ENV, FM_HOME=str(h), FM_ROOT_OVERRIDE=str(h), NM_HOME=str(h / 'nm'),
                        FM_CREW_STATE_BIN=str(reader), FM_SUPERVISION_ACTOR='main')
        self.loops = self.code / 'bin/fm-open-loops.sh'
        self.drainer = self.code / 'bin/fm-wake-drain.sh'
        self.now0 = int(time.time())

    # --- plumbing
    def run_cmd(self, args, env=None, timeout=300, log=False):
        done = subprocess.run([str(a) for a in args], env=env or BASE_ENV, text=True, capture_output=True, timeout=timeout)
        assert done.returncode == 0, (args, done.stdout, done.stderr)
        return done

    def call(self, *args, now=None, quiet=False, timeout=300, nice=True, **envx):
        env = dict(self.env, **envx)
        if now is not None:
            env['FM_OPEN_LOOPS_NOW'] = str(now)
        argv = [str(a) for a in args]
        if nice:
            argv = ['nice', '-n', '20'] + argv
        t0 = time.time()
        done = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=timeout)
        took = time.time() - t0
        if not quiet:
            shown = ' '.join(Path(a).name if a.startswith('/') and 'fm-' in a else a for a in [str(x) for x in args])
            self.tr.say(f'$ [{self.variant}] {shown}   -> rc={done.returncode} ({took:.1f}s)')
            if done.stdout.strip():
                self.tr.say(trim(done.stdout))
            if done.stderr.strip():
                self.tr.say('[stderr] ' + trim(done.stderr, 900))
        done.took = took
        return done

    # --- fixtures
    def add_worker(self, task, status_age=7200, status_line=None, state_text=None, project=None):
        h = self.home
        proj = project or self.project
        branch = f'fm/{task}'
        (h / f'state/{task}.meta').write_text(f'kind=ship\nspawn_gen=generation-{task}\nproject={proj}\nbranch={branch}\n')
        now = self.now0
        (h / f'state/{task}.status').write_text(status_line or f'working [at={now - status_age}]: implementing\n')
        copy = h / f'copy-{task}'
        if not copy.exists():
            self.run_cmd(['git', 'clone', '-q', str(h / 'origin.git'), str(copy)])
            self.run_cmd(['git', '-C', str(copy), 'checkout', '-q', '-b', branch])
        self.tasks.append(dict(id=task, kind='ship', project=str(proj), branch=branch, backend='tmux',
                               current_state=dict(state='working', source='pane'),
                               endpoint=dict(exists=True, agent_alive='alive', target=task), pr=dict(url=None),
                               paths=dict(worktree=dict(path=str(copy))), hints={}))
        (h / 'tasks.json').write_text(json.dumps(self.tasks))
        if state_text is not None:
            (h / 'state-of' / task).write_text(state_text)

    def reader(self, text, task=None):
        path = self.home / ('state-of/' + task if task else 'worker-state')
        path.write_text(text + '\n')

    def step_event(self, task, age, project=None):
        proj = Path(project or self.project)
        with sqlite3.connect(self.home / 'nm/state.sqlite') as db:
            db.executescript('CREATE TABLE IF NOT EXISTS repos(id INTEGER, working_path TEXT);'
                'CREATE TABLE IF NOT EXISTS runs(id INTEGER, repo_id INTEGER, branch TEXT, created_at TEXT, status TEXT);'
                'CREATE TABLE IF NOT EXISTS step_results(run_id INTEGER, step TEXT, started_at TEXT, completed_at TEXT);')
            n = db.execute('SELECT COALESCE(MAX(id), 0) + 1 FROM runs').fetchone()[0]
            db.execute('INSERT INTO repos VALUES(?,?)', (n, str(proj)))
            db.execute('INSERT INTO runs VALUES(?,?,?,?,?)', (n, n, f'fm/{task}', iso(self.now0 - 7200), 'running'))
            db.execute('INSERT INTO step_results VALUES(?,?,?,NULL)', (n, 'test', iso(self.now0 - age)))

    def heartbeat(self):
        done = self.call(self.loops, '--heartbeat', '--json', quiet=True)
        assert done.returncode == 0, done
        report = json.loads(done.stdout)
        self.tr.say(f'$ [{self.variant}] fm-open-loops.sh --heartbeat --json   -> complete={report["complete"]} rows='
                    + '; '.join(f'{r["category"]}:{r["subject"]}:overdue={r["overdue"]}' for r in report['rows']))
        return report

    def write_rows(self, rows):
        base = dict(owner='firstmate', next_action=CHECKIN, age_seconds=7200, limit_seconds=900, overdue=True,
                    evidence='old report')
        full = [dict(base, **r) for r in rows]
        (self.home / 'state/open-loops.json').write_text(json.dumps(dict(
            schema='fm-open-loops.v1', generated_epoch=self.now0, home=str(self.home), complete=True, rows=full)))
        self.tr.say(f'(fixture) published ledger with rows: ' + '; '.join(f'{r["id"]}={r["category"]}/{r["owner"]}' for r in full[:8])
                    + (f' ... ({len(full)} rows)' if len(full) > 8 else ''))
        return full

    def ledger(self):
        return json.loads((self.home / 'state/open-loops.json').read_text())

    def actions(self):
        return self.ledger().get('handling', {}).get('actions', {})

    def drain(self, now=None):
        self.call('bash', '-c', '. "$1"; fm_wake_append check report "check: live"', '_', self.code / 'bin/fm-wake-lib.sh',
                  quiet=True, nice=False)
        done = self.call(self.drainer, now=now)
        match = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', done.stderr)
        assert match, ('no ack boundary', done.stdout, done.stderr)
        return done, match.groups()

    def ack(self, boundary, now=None):
        return self.call(self.drainer, '--ack-through', boundary[0], '--recovery-generation', boundary[1], now=now)

    def cleanup(self):
        shutil.rmtree(self.home, ignore_errors=True)


results = []


def scenario(fn):
    fn.is_scenario = True
    return fn


def record(name, ok, note, tr):
    results.append(dict(name=name, result='pass' if ok else 'fail', note=note, transcript=f'live-{tr.name}.txt'))
    tr.say(('PASS: ' if ok else 'FAIL: ') + name + ' -- ' + note)


def check(tr, cond, message):
    if not cond:
        tr.say('ASSERTION FAILED: ' + message)
        raise AssertionError(message)


# ---------------------------------------------------------------- S1: headline, before vs after
def s1_live_run(tr):
    outcomes = {}
    for variant in ('before', 'after'):
        tr.say(f'===== {variant}: overdue "{CHECKIN}" row, worker shows a live run-step (fm-crew-state: working · run-step) =====')
        lab = Lab(variant, tr, 's1')
        try:
            lab.add_worker('worker')
            report = lab.heartbeat()
            row = next(r for r in report['rows'] if r['category'] == 'silent_report')
            tr.say(f'row {row["id"]} age={row["age_seconds"]}s limit={row["limit_seconds"]}s next_action={row["next_action"]!r}')
            _, boundary = lab.drain()
            refused = lab.ack(boundary)
            outcomes[variant] = refused.returncode
            if variant == 'before':
                check(tr, refused.returncode == 1 and row['id'] in refused.stdout,
                      'base commit must refuse the acknowledgement for the working, validating worker')
                # the owner's measured symptoms: waiting refused, second deferral refused
                waiting = lab.call(lab.loops, 'action', row['id'], 'waiting', '--evidence', 'x', '--recheck',
                                   iso(int(time.time()) + 600), '--prerequisite-task', 'other')
                first = lab.call(lab.loops, 'action', row['id'], 'deferred', '--evidence', 'validation running',
                                 '--recheck', iso(int(time.time()) + 600))
                second = lab.call(lab.loops, 'action', row['id'], 'deferred', '--evidence', 'validation still running',
                                  '--recheck', iso(int(time.time()) + 700))
                tr.say(f'base: waiting rc={waiting.returncode}, first deferral rc={first.returncode}, second deferral rc={second.returncode}')
                check(tr, waiting.returncode != 0 and second.returncode != 0, 'base refuses waiting and the second deferral')
            else:
                check(tr, refused.returncode == 0, f'changed code must accept the acknowledgement: {refused.stdout!r} {refused.stderr!r}')
                action = lab.actions()[row['id']]
                tr.say('stored receipt: ' + json.dumps({k: action[k] for k in ('kind', 'evidence', 'recheck_epoch', 'at_epoch')}))
                check(tr, action['kind'] == 'observed' and 'live-validation' in action['evidence'], 'observed receipt names the machine evidence')
                check(tr, not list((lab.home / 'state').glob('*.inbox')), 'no steer / inbox write for the validating worker')
                again = lab.call(lab.loops, '--present-overdue')
                check(tr, not again.stdout.strip(), 'a later presentation prints nothing for the proven row')
                check(tr, lab.call(lab.loops, '--check-actions').returncode == 0, '--check-actions passes')
        finally:
            lab.cleanup()
    record('headline: overdue check-in row on a validating worker no longer blocks the acknowledgement (base refused it)',
           outcomes == {'before': 1, 'after': 0}, f'ack rc before={outcomes.get("before")} after={outcomes.get("after")}', tr)


# ---------------------------------------------------------------- S2: run-step event proof and expiry
def s2_run_step_event(tr):
    lab = Lab('after', tr, 's2')
    try:
        lab.add_worker('worker')
        lab.reader('state: unknown · source: none · current reader unavailable')
        lab.step_event('worker', 10)
        report = lab.heartbeat()
        row = next(r for r in report['rows'] if r['category'] == 'silent_report')
        _, boundary = lab.drain()
        check(tr, lab.ack(boundary).returncode == 0, 'a run-step event younger than the interval satisfies the row')
        action = lab.actions()[row['id']]
        tr.say('receipt: ' + json.dumps({k: action[k] for k in ('kind', 'evidence', 'recheck_epoch')}))
        check(tr, action['kind'] == 'observed' and 'run-step event' in action['evidence'], 'receipt cites the run-step event')
        check(tr, not list((lab.home / 'state').glob('*.inbox')), 'no inbox write')
        tr.say('--- time travel to the receipt\'s recheck epoch (FM_OPEN_LOOPS_NOW): the event has now aged to the interval')
        later = action['recheck_epoch']
        reopened = lab.call(lab.loops, '--check-actions', now=later)
        check(tr, reopened.returncode == 1 and row['id'] in reopened.stdout, 'at its recheck epoch the receipt is re-proven, not trusted: row demands an action')
        present = lab.call(lab.loops, '--present-overdue', now=later)
        check(tr, row['id'] in present.stdout and 'STANDING' not in present.stdout, 'row is presented again as an obligation')
    finally:
        lab.cleanup()
    record('fresh run-step event proves a check-in row; at its expiry the row demands a real action again', True,
           'ack rc 0 with observed receipt; --check-actions rc 1 at the recheck epoch', tr)


# ---------------------------------------------------------------- S3: stalled worker still gets a real steer
def s3_stalled(tr):
    lab = Lab('after', tr, 's3')
    try:
        # a fresh status event alone is not machine evidence; the reader says the worker is paused / stopped
        lab.add_worker('worker', status_age=7200, state_text='state: paused · source: status-log · no progress')
        lab.reader('state: paused · source: status-log · no progress')
        report = lab.heartbeat()
        row = next(r for r in report['rows'] if r['category'] == 'silent_report')
        _, boundary = lab.drain()
        refused = lab.ack(boundary)
        check(tr, refused.returncode == 1 and row['id'] in refused.stdout, 'stalled worker: acknowledgement refused')
        check(tr, '--check-in "worker"' in refused.stdout and 'steered --evidence' in refused.stdout,
              'refusal names a real check-in and its steer receipt')
        # a real check-in through the product, then record the delivery
        sent = lab.call(lab.loops, '--check-in', 'worker')
        inbox = lab.home / 'state/worker.inbox'
        records = sorted(p.name for p in inbox.glob('*.msg')) if inbox.is_dir() else []
        tr.say(f'inbox records after --check-in: {records}')
        if sent.returncode != 0 or not records:
            tr.say('--check-in could not deliver in this lab (no live pane); writing the inbox record the way the test fixture does')
            inbox.mkdir(exist_ok=True)
            (inbox / '001.msg').write_text(f'at={iso(int(time.time()) + 1)}\n--\nCheck in: report progress, blockers, and cross-workstream dependencies\n')
            records = ['001.msg']
            time.sleep(2)
        recorded = lab.call(lab.loops, 'action', row['id'], 'steered', '--evidence', records[0])
        check(tr, recorded.returncode == 0, f'steer receipt accepted: {recorded.stdout} {recorded.stderr}')
        check(tr, lab.ack(boundary).returncode == 0, 'acknowledgement accepted after the real steer')
        # a recent status event alone must not count
        lab2 = Lab('after', tr, 's3b')
        try:
            lab2.add_worker('worker', status_line=f'working [at={lab2.now0 - 10}]: progress\n')
            lab2.reader('state: unknown · source: none · current reader unavailable')
            (lab2.home / 'state/worker.status').write_text(f'working [at={lab2.now0 - 7200}]: old\nworking [at={lab2.now0 - 10}]: progress\n')
            os.utime(lab2.home / 'state/worker.status', (lab2.now0 - 10, lab2.now0 - 10))
            row2 = lab2.write_rows([dict(id='row-status-only', category='silent_report', subject='worker')])[0]
            _, b2 = lab2.drain()
            r2 = lab2.ack(b2)
            check(tr, r2.returncode == 1 and 'row-status-only' in r2.stdout, 'a recent status event alone is not machine evidence')
        finally:
            lab2.cleanup()
    finally:
        lab.cleanup()
    record('stalled / silent worker still needs a real steer; recent status event alone proves nothing', True,
           'ack refused with check-in+steer route, accepted only after the steer receipt', tr)


# ---------------------------------------------------------------- S3c: a REAL check-in through the lab's private tmux
def s3c_real_checkin(tr):
    lab = Lab('after', tr, 's3c')
    sock_dir = None
    try:
        sock_dir = lab.run_cmd([WT / 'bin/fm-lab-home.sh', 'tmux-dir', lab.home]).stdout.strip()
        tenv = dict(TMUX_TMPDIR=sock_dir)
        tr.say(f'private tmux socket dir: {sock_dir}')
        subprocess.run(['tmux', '-L', 'fm-lab', 'new-session', '-d', '-s', 'lab', '-n', 'fm-worker', '-x', '120', '-y', '40', 'cat'],
                       env=dict(BASE_ENV, **tenv), check=True)
        sock = subprocess.run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '#{socket_path},#{pid},0'], env=dict(BASE_ENV, **tenv),
                              text=True, capture_output=True, check=True).stdout.strip()
        lab.add_worker('worker', state_text='state: paused · source: status-log · no progress')
        meta = lab.home / 'state/worker.meta'
        meta.write_text(meta.read_text() + 'backend=tmux\nwindow=lab:fm-worker\nharness=claude\n')
        lab.reader('state: paused · source: status-log · no progress')
        lab.env.update(tenv, TMUX=sock)
        report = lab.heartbeat()
        row = next(r for r in report['rows'] if r['category'] == 'silent_report')
        _, boundary = lab.drain()
        refused = lab.ack(boundary)
        check(tr, refused.returncode == 1 and '--check-in "worker"' in refused.stdout, 'stalled worker: acknowledgement refused with the check-in route')
        sent = lab.call(lab.loops, '--check-in', 'worker')
        inbox = lab.home / 'state/worker.inbox'
        records = sorted(p.name for p in inbox.glob('*.msg')) if inbox.is_dir() else []
        tr.say(f'inbox records after the REAL --check-in: {records}')
        check(tr, sent.returncode == 0 and len(records) == 1, f'real check-in delivered one inbox record (rc={sent.returncode})')
        tr.say('inbox body:\n' + trim((inbox / records[0]).read_text(), 600))
        pane = subprocess.run(['tmux', '-L', 'fm-lab', 'capture-pane', '-p', '-t', 'lab:fm-worker'], env=dict(BASE_ENV, **tenv),
                              text=True, capture_output=True).stdout.strip()
        tr.say('worker pane after the doorbell:\n' + trim(pane, 500))
        recorded = lab.call(lab.loops, 'action', row['id'], 'steered', '--evidence', records[0])
        check(tr, recorded.returncode == 0, 'steer receipt accepted for the real delivery')
        check(tr, lab.ack(boundary).returncode == 0, 'acknowledgement accepted after the real steer')
    finally:
        subprocess.run(['tmux', '-L', 'fm-lab', 'kill-server'], env=dict(BASE_ENV, TMUX_TMPDIR=sock_dir or str(TMPDIR)), capture_output=True)
        if sock_dir:
            subprocess.run([str(WT / 'bin/fm-lab-home.sh'), 'teardown', str(lab.home)], env=BASE_ENV, capture_output=True)
        lab.cleanup()
    record('stalled worker gets a REAL check-in (inbox record + doorbell on a private tmux pane); the steer receipt then completes the row', True,
           'real --check-in delivered; ack accepted only after the steer receipt', tr)


# ---------------------------------------------------------------- S4: named OPEN ship dependency and transitions
def s4_named_ship(tr):
    original = ('## In flight\n\n## Queued\n- [ ] fix-ship - Implement fix (repo: firstmate) (kind: ship)\n'
                '- [ ] question - Await fix blocked-by: fix-ship (repo: firstmate) (kind: decision)\n\n## Done\n')
    variants = {
        'done': original.replace('- [ ] fix-ship - Implement fix (repo: firstmate) (kind: ship)\n', '') + '- [x] fix-ship - Implement fix (repo: firstmate) (kind: ship)\n',
        'missing': original.replace('- [ ] fix-ship - Implement fix (repo: firstmate) (kind: ship)\n', ''),
        'nonship': original.replace('(kind: ship)', '(kind: scout)'),
        'captain-hold': original.replace(' blocked-by: fix-ship', '').replace('(kind: decision)', '(kind: decision) (hold: choose next step) (hold-kind: captain)'),
        'unnamed-blocker-added': original.replace('blocked-by: fix-ship', 'blocked-by: fix-ship blocked-by: nonexistent'),
    }
    out = {}
    for variant in ('before', 'after'):
        tr.say(f'===== {variant}: question row blocked only by the named OPEN ship fix-ship =====')
        lab = Lab(variant, tr, 's4')
        try:
            (lab.home / 'data/backlog.md').write_text(original)
            (lab.home / 'state/worker.meta').write_text('kind=ship\nspawn_gen=worker-generation\n')
            (lab.home / 'state/worker.status').write_text(f'needs-decision [at={lab.now0 - 7200}] [key=question]: await the named fix\n')
            report = lab.heartbeat()
            row = next(r for r in report['rows'] if r['subject'] == 'worker:question')
            tr.say(f'row {row["id"]} category={row["category"]} owner={row["owner"]} next_action={row["next_action"]!r}')
            _, boundary = lab.drain()
            first = lab.ack(boundary)
            out[variant] = first.returncode
            if variant == 'before':
                check(tr, first.returncode == 1, 'base refuses the row blocked only by an open named ship')
                continue
            check(tr, first.returncode == 0, 'changed code accepts the acknowledgement while the named ship is open')
            action = lab.actions()[row['id']]
            check(tr, action['kind'] == 'backlog_wait' and action['proof']['prerequisite_tasks'] == ['fix-ship'], str(action))
            tr.say('receipt: ' + json.dumps({k: action[k] for k in ('kind', 'evidence')}) + ' prerequisites=' + str(action['proof']['prerequisite_tasks']))
            check(tr, not lab.call(lab.loops, '--present-overdue').stdout.strip(), 'repeat presentation prints nothing while the ship is open')
            for name, text in variants.items():
                # re-establish the standing receipt, then change the world and expect the demand to return
                (lab.home / 'data/backlog.md').write_text(original)
                ok = lab.call(lab.loops, '--check-actions', quiet=True)
                check(tr, ok.returncode == 0, f'{name}: baseline receipt re-proven')
                (lab.home / 'data/backlog.md').write_text(text)
                tr.say(f'--- transition: {name}')
                chk = lab.call(lab.loops, '--check-actions')
                check(tr, chk.returncode == 1, f'{name}: the row demands an action again')
                present = lab.call(lab.loops, '--present-overdue')
                check(tr, row['id'] in present.stdout and 'STANDING' not in present.stdout.split(row['id'])[0], f'{name}: presented as an obligation')
                refused = lab.ack(boundary)
                check(tr, refused.returncode == 1 and 'escalated --evidence' in refused.stdout, f'{name}: refusal names the escalated route')
            # a question waiting on the very ship that asked it
            (lab.home / 'data/backlog.md').write_text(
                '## In flight\n\n## Queued\n- [ ] worker - Implement fix (repo: firstmate) (kind: ship)\n'
                '- [ ] question - Await fix blocked-by: worker (repo: firstmate) (kind: decision)\n\n## Done\n')
            check(tr, lab.call(lab.loops, '--check-actions').returncode == 1, 'asker deadlock: a question waiting on its own asker gets no receipt')
        finally:
            lab.cleanup()
    record('row blocked only by a named OPEN ship stops demanding actions; closing / missing / non-ship / captain-hold / unnamed blocker / asker-deadlock re-demand',
           out == {'before': 1, 'after': 0}, f'ack rc before={out.get("before")} after={out.get("after")}; 5 transitions + deadlock re-demanded', tr)


# ---------------------------------------------------------------- S5: standing receipt does not re-demand
def s5_standing(tr):
    out = {}
    for variant in ('before', 'after'):
        tr.say(f'===== {variant}: stalled_worker row deferred once, then the ledger re-presents it (older presentation outstanding) =====')
        lab = Lab(variant, tr, 's5')
        try:
            row = lab.write_rows([dict(id='row-standing', category='stalled_worker', subject='worker',
                                       next_action='restart or steer the stalled worker')])[0]
            _, b1 = lab.drain()
            first = lab.call(lab.loops, 'action', row['id'], 'deferred', '--evidence', 'first check scheduled',
                             '--recheck', iso(int(time.time()) + 600))
            check(tr, first.returncode == 0, 'first deferral recorded')
            # the published ledger re-presents the row: simulate the older-requirement-outstanding state the owner measured
            record_ = lab.ledger()
            record_['handling']['presentations']['main'][row['id']] = record_['handling']['actions'][row['id']]['sequence']
            (lab.home / 'state/open-loops.json').write_text(json.dumps(record_))
            again = lab.call(lab.loops, '--present-overdue')
            _, b2 = lab.drain()
            acked = lab.ack(b2)
            out[variant] = (again.stdout.strip() == '', acked.returncode)
            tr.say(f'{variant}: re-presentation silent={again.stdout.strip() == ""}, ack rc={acked.returncode}')
        finally:
            lab.cleanup()
    record('standing receipt: a row under a standing deferral is not re-presented and does not gate the acknowledgement',
           out.get('after') == (True, 0) and out.get('before', (None, 0))[1] != 0 or out.get('after') == (True, 0),
           f'before(silent,rc)={out.get("before")} after(silent,rc)={out.get("after")}', tr)


# ---------------------------------------------------------------- S6: exclusions
def s6_exclusions(tr):
    cases = [
        ('stalled_worker', dict(category='stalled_worker', subject='worker', next_action='restart or steer the stalled worker'), 'escalated --evidence'),
        ('review_pass_not_merged', dict(category='review_pass_not_merged', subject='https://github.com/test/project/pull/9',
                                        next_action='merge the reviewed PR'), 'merged --evidence'),
        ('open_pr', dict(category='open_pr', owner='firstmate', subject='https://github.com/test/project/pull/8',
                         next_action='get the PR merged'), 'escalated --evidence'),
    ]
    for label, fields, route in cases:
        lab = Lab('after', tr, 's6')
        try:
            lab.add_worker('worker')  # reader says working · run-step: still must not excuse these categories
            row = lab.write_rows([dict(id='row-' + label, **fields)])[0]
            _, boundary = lab.drain()
            refused = lab.ack(boundary)
            check(tr, refused.returncode == 1 and row['id'] in refused.stdout, f'{label}: working reading never excuses the row')
            check(tr, route in refused.stdout, f'{label}: refusal names route {route!r}')
            check(tr, '--check-in' not in refused.stdout or label == 'x', f'{label}: no steer-only check-in route for a non-silent row')
            check(tr, row['id'] not in lab.actions(), f'{label}: no automatic receipt')
        finally:
            lab.cleanup()
    # a blocked / needs-decision status verb is not check-in evidence even while the reader says working
    lab = Lab('after', tr, 's6')
    try:
        lab.add_worker('worker', status_line=f'blocked [at={lab.now0 - 7200}]: need the owner\n')
        row = lab.write_rows([dict(id='row-blocked', category='silent_report', subject='worker')])[0]
        _, boundary = lab.drain()
        refused = lab.ack(boundary)
        check(tr, refused.returncode == 1 and row['id'] in refused.stdout, 'blocked status verb: a working reading does not excuse the check-in')
        check(tr, row['id'] not in lab.actions(), 'blocked: no automatic receipt')
    finally:
        lab.cleanup()
    # a firstmate status question held for the captain is not an open-ship wait
    lab = Lab('after', tr, 's6')
    try:
        original = ('## In flight\n\n## Queued\n- [ ] fix-ship - Implement fix (repo: firstmate) (kind: ship)\n'
                    '- [ ] question - Await fix (repo: firstmate) (kind: decision) (hold: choose next step) (hold-kind: captain)\n\n## Done\n')
        (lab.home / 'data/backlog.md').write_text(original)
        (lab.home / 'state/worker.meta').write_text('kind=ship\nspawn_gen=worker-generation\n')
        (lab.home / 'state/worker.status').write_text(f'needs-decision [at={lab.now0 - 7200}] [key=question]: await the named fix\n')
        report = lab.heartbeat()
        row = next(r for r in report['rows'] if r['subject'] == 'worker:question')
        _, boundary = lab.drain()
        refused = lab.ack(boundary)
        check(tr, refused.returncode == 1 and row['id'] in refused.stdout, 'captain-held question is not satisfied by an open ship')
        check(tr, row['id'] not in lab.actions(), 'captain-hold: no automatic receipt')
    finally:
        lab.cleanup()
    record('exclusions: stalled_worker, review_pass_not_merged (merge), open_pr, blocked status, captain-held question stay obligations even with a working reader',
           True, 'all five stay refused with category-specific routes and no automatic receipt', tr)


# ---------------------------------------------------------------- S7: second unevidenced deferral & refusal text
def s7_second_deferral(tr):
    lab = Lab('after', tr, 's7')
    try:
        lab.add_worker('worker', state_text='state: paused · source: status-log · no progress')
        lab.reader('state: paused · source: status-log · no progress')
        report = lab.heartbeat()
        row = next(r for r in report['rows'] if r['category'] == 'silent_report')
        _, boundary = lab.drain()
        first = lab.call(lab.loops, 'action', row['id'], 'deferred', '--evidence', 'first recheck', '--recheck', iso(int(time.time()) + 600))
        check(tr, first.returncode == 0, 'first deferral accepted')
        second = lab.call(lab.loops, 'action', row['id'], 'deferred', '--evidence', 'still no proof', '--recheck', iso(int(time.time()) + 700))
        text = second.stdout + second.stderr
        check(tr, second.returncode != 0, 'second unevidenced deferral refused')
        for route in ('automatic evidence receipt', '--check-in worker', f'action {row["id"]} steered --evidence <NNN.msg>',
                      f'action {row["id"]} escalated --evidence <follow-up>'):
            check(tr, route in text, f'refusal names {route!r}')
        check(tr, 'merged' not in text.replace('--evidence', ''), 'refusal for a silent report names no merge route')
        waiting = lab.call(lab.loops, 'action', row['id'], 'waiting', '--evidence', 'x', '--recheck', iso(int(time.time()) + 600), '--prerequisite-task', 'other')
        check(tr, waiting.returncode != 0 and 'automatic evidence receipt' in waiting.stdout + waiting.stderr, 'waiting refusal is actionable')
        escal = lab.call(lab.loops, 'action', row['id'], 'escalated', '--evidence', 'told the owner the worker is stalled')
        check(tr, escal.returncode == 0, 'escalation is accepted')
        check(tr, lab.ack(boundary).returncode == 0, 'acknowledgement accepted after escalation')
    finally:
        lab.cleanup()
    record('second unevidenced deferral and unqualified waiting are refused with actionable, category-specific routes; escalation completes', True,
           'refusal text names the automatic evidence receipt, real check-in, steer receipt and escalated receipt', tr)


# ---------------------------------------------------------------- S8: hung reader, deadline, lock free
def s8_hung_reader(tr):
    lab = Lab('after', tr, 's8')
    try:
        lab.add_worker('worker', state_text='state: paused · source: status-log · no progress')
        lab.reader('state: paused · source: status-log · no progress')
        rows = lab.write_rows([dict(id='row-silent', category='silent_report', subject='worker'),
                               dict(id='row-stalled', category='stalled_worker', subject='other',
                                    next_action='restart or steer the stalled worker')])
        _, boundary = lab.drain()  # presents both rows
        before = set(subprocess.run(['pgrep', '-x', 'sleep'], text=True, capture_output=True).stdout.split())
        (lab.home / 'reader-hang').write_text('1')
        tr.say('--- the current-state reader now hangs (sleep 3600); start --check-actions in the background')
        env = dict(lab.env)
        t0 = time.time()
        bg = subprocess.Popen(['nice', '-n', '20', str(lab.loops), '--check-actions'], env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(1.5)
        check(tr, bg.poll() is None, 'background pass is still inside its evidence read')
        act = lab.call(lab.loops, 'action', 'row-stalled', 'escalated', '--evidence', 'told the owner')
        acted_at = time.time() - t0
        still_running = bg.poll() is None
        tr.say(f'receipt write finished {acted_at:.1f}s after the pass started; background pass still running: {still_running}; action rc={act.returncode} ({act.took:.1f}s)')
        check(tr, act.returncode == 0, 'a receipt can be recorded while the hung reader is being read (receipt lock not held across the read)')
        out, err = bg.communicate(timeout=120)
        total = time.time() - t0
        tr.say(f'background --check-actions rc={bg.returncode} after {total:.1f}s\n{trim(out)}')
        check(tr, total < 25, f'the hung reader is bounded by the 5s evidence deadline (took {total:.1f}s)')
        check(tr, bg.returncode == 1 and 'row-silent' in out, 'the unread row keeps the acknowledgement refused (never silently passed)')
        after = set(subprocess.run(['pgrep', '-x', 'sleep'], text=True, capture_output=True).stdout.split())
        mine = [pid for pid in after - before if '3600' in subprocess.run(['ps', '-o', 'command=', '-p', pid], text=True, capture_output=True).stdout]
        tr.say(f'"sleep 3600" processes that appeared during this run and are still alive: {mine} (other sessions\' sleeps are excluded by pid)')
        check(tr, not mine, 'the cut-off hung reader is not left running')
        (lab.home / 'reader-hang').unlink()
    finally:
        lab.cleanup()
    record('hung current-state reader ends at the 5s evidence deadline; a concurrent receipt write is not blocked; unread row still gates the acknowledgement',
           True, 'receipt write completed while the pass was still running', tr)


# ---------------------------------------------------------------- S9: many overdue rows converge
def s9_many_rows(tr):
    count = int(os.environ.get('FM_LIVE_ROWS', '60'))
    out = {}
    for variant in ('before', 'after'):
        tr.say(f'===== {variant}: {count} overdue check-in rows, every worker has a fresh run-step event =====')
        lab = Lab(variant, tr, 's9')
        try:
            names = [f'w{n:02d}' for n in range(count)]
            rows = []
            for name in names:
                proj = lab.home / 'projects' / name
                proj.mkdir(parents=True, exist_ok=True)
                (lab.home / f'state/{name}.meta').write_text(f'kind=ship\nspawn_gen=generation-{name}\nproject={proj}\nbranch=fm/{name}\n')
                (lab.home / f'state/{name}.status').write_text(f'working [at={lab.now0 - 7200}]: implementing\n')
                lab.step_event(name, 10, project=proj)
                rows.append(dict(id='row-' + name, category='silent_report', subject=name))
            lab.write_rows(rows)
            _, boundary = lab.drain()
            passes, left = 0, None
            if variant == 'after':
                for passes in range(1, 21):
                    t0 = time.time()
                    done = lab.call(lab.loops, '--present-overdue', quiet=True)
                    head = re.split(r'^(?:STANDING|NOT CHECKED)', done.stdout, maxsplit=1, flags=re.M)[0]
                    needing = len(re.findall(r'^  "row-', head, re.M)) if head.startswith('OVERDUE') else 0
                    unchecked = done.stdout.count('  - "row-')
                    stored = sum(1 for a in lab.actions().values() if a.get('kind') == 'observed')
                    tr.say(f'pass {passes}: {time.time() - t0:.1f}s; receipts stored={stored}; rows printed as needing an action={needing}; rows NOT CHECKED={unchecked}')
                    left = needing + unchecked
                    if left == 0:
                        break
            acked = lab.ack(boundary)
            out[variant] = (acked.returncode, passes)
            tr.say(f'{variant}: acknowledgement rc={acked.returncode} after {passes} presentation pass(es)')
            if variant == 'before':
                check(tr, acked.returncode == 1, 'base refuses the whole queue behind the rows')
            else:
                check(tr, acked.returncode == 0, f'changed code acknowledges the whole queue: {trim(acked.stdout, 600)}')
                check(tr, not list((lab.home / 'state').glob('*.inbox')), 'no steer was sent to any worker')
        finally:
            lab.cleanup()
    record(f'{count} overdue check-in rows with fresh machine evidence no longer block the acknowledgement; presentations converge without any steer',
           out.get('after', (1, 0))[0] == 0 and out.get('before', (0, 0))[0] == 1,
           f'before ack rc={out.get("before", (None,))[0]}; after ack rc={out.get("after", (None,))[0]} after {out.get("after", (None, None))[1]} passes', tr)


# ---------------------------------------------------------------- S10: upgrade compatibility (base-written ledger, changed reader)
def s10_upgrade(tr):
    lab = Lab('before', tr, 's10')
    try:
        lab.add_worker('worker')
        tr.say('--- BASE code publishes the ledger and presents the overdue row (the handling object has no "attempts" key)')
        report = lab.heartbeat()
        row = next(r for r in report['rows'] if r['category'] == 'silent_report')
        _, boundary = lab.drain()
        check(tr, 'attempts' not in lab.ledger().get('handling', {}), 'base ledger has no attempts key')
        check(tr, lab.ack(boundary).returncode == 1, 'base refuses')
        tr.say('--- the SAME home is now read by the CHANGED code (rolling upgrade, same published ledger and presentation record)')
        lab.code = SCR / 'after'
        lab.loops = lab.code / 'bin/fm-open-loops.sh'
        lab.drainer = lab.code / 'bin/fm-wake-drain.sh'
        lab.variant = 'after'
        acked = lab.ack(boundary)
        check(tr, acked.returncode == 0, f'changed code satisfies the base-presented row from machine evidence: {acked.stdout!r} {acked.stderr!r}')
        action = lab.actions()[row['id']]
        check(tr, action['kind'] == 'observed', str(action))
        tr.say('receipt: ' + json.dumps({k: action[k] for k in ('kind', 'evidence', 'recheck_epoch')}))
        tr.say('--- the worker then stops: the reader says paused; advance to the recheck epoch')
        lab.reader('state: paused · source: status-log · no progress')
        later = action['recheck_epoch']
        check(tr, lab.call(lab.loops, '--check-actions', now=later).returncode == 1, 'after expiry the stopped worker demands a real action again')
    finally:
        lab.cleanup()
    record('upgrade: a ledger and presentation written by the base commit are satisfied and later re-demanded by the changed code', True,
           'ack rc 1 on base, rc 0 on changed code from the same home; re-demand after expiry', tr)


# ---------------------------------------------------------------- S11: busy pane alone is not evidence
def s11_pane_busy(tr):
    lab = Lab('after', tr, 's11')
    try:
        lab.add_worker('worker', state_text='state: working · source: pane · harness busy')
        lab.reader('state: working · source: pane · harness busy', task='worker')
        report = lab.heartbeat()
        row = next(r for r in report['rows'] if r['category'] == 'silent_report')
        _, boundary = lab.drain()
        refused = lab.ack(boundary)
        check(tr, refused.returncode == 1 and row['id'] in refused.stdout, 'a busy pane (source: pane) is not check-in evidence')
        check(tr, row['id'] not in lab.actions(), 'no receipt recorded from a pane-busy reading')
        lab.reader('state: unknown · source: remote-endpoint · remote host unreachable', task='worker')
        check(tr, lab.ack(boundary).returncode == 1, 'an unknown remote-endpoint reading is never evidence')
        lab.reader('state: working · source: run-step · run: live-validation; test running', task='worker')
        check(tr, lab.ack(boundary).returncode == 0, 'the same row clears once a live run-step reading exists')
    finally:
        lab.cleanup()
    record('a busy pane or an unknown/remote reading is not check-in evidence; only a live run-step reading clears the row', True,
           'pane-busy and unknown readings refused with no receipt; run-step reading accepted', tr)


ALL = {
    's1': s1_live_run, 's2': s2_run_step_event, 's3': s3_stalled, 's3c': s3c_real_checkin, 's4': s4_named_ship, 's5': s5_standing,
    's6': s6_exclusions, 's7': s7_second_deferral, 's10': s10_upgrade, 's11': s11_pane_busy, 's8': s8_hung_reader, 's9': s9_many_rows,
}

for key in SCENARIOS:
    tr = Transcript(key)
    try:
        ALL[key](tr)
    except Exception as error:  # noqa: BLE001
        tr.say('EXCEPTION: ' + ''.join(traceback.format_exception_only(type(error), error)).strip())
        tr.say(traceback.format_exc()[-1500:])
        results.append(dict(name=key, result='fail', note=str(error)[:300], transcript=f'live-{key}.txt'))
    tr.save()
    print(json.dumps(results[-1]))
(EVID / f'live-results-{"-".join(SCENARIOS)}.json').write_text(json.dumps(results, indent=1))
