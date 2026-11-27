#!/usr/bin/env python3
"""Live driver: real bin/fm-open-loops.sh + real fm-fleet-snapshot.sh + real fm-send.sh
against disposable lab homes (bin/fm-lab-home.sh create) whose tasks are real tmux
windows on the private fm-lab socket. No product script is stubbed.

usage: live-driver.py <bin-dir-under-test> <label> <lab-helper-bin>
Requires TMUX_TMPDIR and TMUX (fm-lab socket) in the environment.
"""
import json, os, re, subprocess, sys, tempfile, time
from pathlib import Path

BIN, LABEL, HELPER = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
TMPBASE = Path(os.environ.get('TMPDIR', '/tmp'))
results = []


def sh(args, env, expected=0, now=None):
    e = dict(env)
    if now is not None:
        e['FM_OPEN_LOOPS_NOW'] = str(now)
    r = subprocess.run([str(a) for a in args], env=e, text=True, capture_output=True)
    if expected is not None and r.returncode != expected:
        raise RuntimeError(f'{args} rc={r.returncode}\n{r.stdout}\n{r.stderr}')
    return r


class Lab:
    def __init__(self, name, kind='ship', inflight=True):
        d = tempfile.mkdtemp(prefix=f'fm-lab-{LABEL}-{name}.', dir=TMPBASE)
        self.home = Path(subprocess.check_output([HELPER / 'fm-lab-home.sh', 'create', d], text=True).strip())
        self.name, self.kind, self.id = name, kind, 'w' + re.sub(r'[^a-z0-9]', '', name)[:20]
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in (
            'NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS')}
        self.env.update(FM_HOME=str(self.home), NM_HOME=str(self.home / 'nm'), FM_SUPERVISION_ACTOR='main',
                        FM_DURATION_FILE='off', PYTHONDONTWRITEBYTECODE='1')
        window = f'{LABEL}-{self.id}'
        subprocess.check_call(['tmux', '-L', 'fm-lab', 'new-window', '-d', '-t', 'primary:', '-n', window,
                               'sleep 7200'])
        self.window = window
        (self.home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        meta = f'kind={kind}\nbackend=tmux\nwindow=primary:{window}\nharness=claude\nspawn_gen=lab-{self.id}\n'
        if kind == 'secondmate':
            mate = self.home / 'mate'
            for part in ('state', 'data', 'config', 'projects'):
                (mate / part).mkdir(parents=True)
            rows = '- [ ] routed - Routed work (repo: firstmate) (kind: ship)\n' if inflight else ''
            (mate / 'data/backlog.md').write_text(f'## In flight\n{rows}\n## Queued\n\n## Done\n')
            meta += f'home={mate}\n'
        else:
            wt = self.home / 'projects/proj'
            subprocess.check_call(['git', 'init', '-q', '-b', 'main', str(wt)])
            subprocess.check_call(['git', '-C', str(wt), '-c', 'user.email=lab@lab', '-c', 'user.name=lab',
                                   'commit', '-q', '--allow-empty', '-m', 'init'])
            subprocess.check_call(['git', '-C', str(wt), 'checkout', '-q', '-b', 'fm/' + self.id])
            meta += f'worktree={wt}\nbranch=fm/{self.id}\nproject={wt}\n'
        (self.home / f'state/{self.id}.meta').write_text(meta)
        self.status = self.home / f'state/{self.id}.status'
        self.base = int(time.time())
        self.line(f'working [at={self.base - 7200}]: started lab validation')
        os.utime(self.home / f'state/{self.id}.meta', (self.base - 7200, self.base - 7200))
        self.row = None

    def line(self, text):
        with self.status.open('a') as s:
            s.write(text + '\n')

    def cli(self, *args, now, expected=0):
        return sh([BIN / 'fm-open-loops.sh', *args], self.env, expected, now)

    def collect(self, now):
        report = json.loads(self.cli('--heartbeat', '--json', now=now).stdout)
        rows = [r for r in report['rows'] if r['category'] == 'silent_report' and r['subject'] == self.id]
        self.row = rows[0] if rows else None
        return self.row

    def presented(self, now):
        out = self.cli('--present-overdue', now=now).stdout
        checked = self.cli('--check-actions', now=now, expected=None)
        rid = self.row['id']
        return (rid in out, rid in checked.stdout, 'steered, result not observed' in out, out)

    def send_steer(self):
        r = sh([BIN / 'fm-send.sh', self.id, '--answers-none', '--',
                'Report the validation result now.'], self.env, expected=None)
        msgs = sorted((self.home / f'state/{self.id}.inbox').glob('[0-9]*.msg'))
        if r.returncode != 0 or not msgs:
            raise RuntimeError(f'fm-send failed rc={r.returncode}\n{r.stdout}\n{r.stderr}')
        msg = msgs[-1]
        at = re.search(r'^at=(.*)$', msg.read_text(), re.M).group(1)
        import datetime as dt
        sent = int(dt.datetime.fromisoformat(at.replace('Z', '+00:00')).timestamp())
        return msg, sent

    def steer(self, msg, now):
        return self.cli('action', self.row['id'], 'steered', '--evidence', msg.name, now=now)

    def ack(self, msg, at):
        handled = msg.parent / 'handled'
        handled.mkdir(exist_ok=True)
        msg.rename(handled / msg.name)
        os.utime(handled, (at, at))

    def close(self):
        subprocess.call(['tmux', '-L', 'fm-lab', 'kill-window', '-t', f'primary:{self.window}'])
        subprocess.call([HELPER / 'fm-lab-home.sh', 'teardown', self.home], stderr=subprocess.DEVNULL)
        subprocess.call(['rm', '-rf', str(self.home)])


def record(name, expected_presented, observed, detail):
    results.append(dict(scenario=name, label=LABEL, presented_at_limit=observed,
                        head_expectation=expected_presented, matches_head_expectation=observed == expected_presented,
                        detail=detail))
    print(f'[{LABEL}] {name}: presented_at_limit={observed} head_expects={expected_presented} '
          f'{"OK" if observed == expected_presented else "DIFFERS"} | {detail}', flush=True)


def steered(name, kind='ship', setup=None, after_ack=None, expect=True):
    lab = Lab(name, kind)
    try:
        now = lab.base
        lab.collect(now)
        assert lab.presented(now)[0], 'row must be overdue and presented before the steer'
        if setup:
            setup(lab)
        msg, sent = lab.send_steer()
        now = max(now, sent)
        if setup:
            setup(lab, sent)
        lab.steer(msg, now)
        t800 = sent + 800
        lab.ack(msg, t800)
        if after_ack:
            after_ack(lab, sent)
        early = lab.presented(sent + 899) if lab.collect(sent + 899) else None
        row = lab.collect(sent + 900)
        p = lab.presented(sent + 900) if row else (False, False, False, '')
        detail = (f'sent={sent} at+899 presented={early[0] if early else None}; at+900 row overdue='
                  f'{row and row["overdue"]} check-actions-lists={p[1]} label-steered-not-observed={p[2]} '
                  f'evidence="{row and row["evidence"]}"')
        record(name, expect, p[0], detail)
    finally:
        lab.close()


def cadence(name, kind, verb):
    lab = Lab(name, kind)
    try:
        b = lab.base
        lab.line(f'{verb} [at={b}]: reported the validation outcome')
        r899 = lab.collect(b + 899)
        r900 = lab.collect(b + 900)
        p = lab.presented(b + 900)
        ci = lab.cli('--check-in', lab.id, '--json', now=b + 900, expected=None)
        try:
            ci_state = json.loads(ci.stdout).get('check_in')
        except Exception:
            if ci.returncode != 0 and 'the one permitted escape is a disposable lab home' in ci.stdout + ci.stderr:
                # check_in found the row overdue and called fm-send; the gate guard then refused the send
                # because the collector passes FM_DATA_OVERRIDE/FM_PROJECTS_OVERRIDE (unchanged base code).
                ci_state = 'eligible: reached fm-send, send refused by gate guard (lab override allowance)'
            else:
                ci_state = 'unparsed rc=%s %s %s' % (ci.returncode, ci.stdout[-200:], ci.stderr[-200:])
        inbox = sorted((lab.home / f'state/{lab.id}.inbox').glob('[0-9]*.msg'))
        ok = (not r899['overdue']) and r900['overdue'] and not r900.get('informational') and p[0] \
            and (ci_state == 'sent' and bool(inbox) or ci_state.startswith('eligible:'))
        detail = (f'at+899 overdue={r899["overdue"]}; at+900 overdue={r900["overdue"]} informational='
                  f'{r900.get("informational")} presented={p[0]} check_in={ci_state} inbox_records={len(inbox)} '
                  f'evidence="{r900["evidence"]}"')
        results.append(dict(scenario=name, label=LABEL, cadence_ok=ok, detail=detail))
        print(f'[{LABEL}] {name}: cadence_ok={ok} | {detail}', flush=True)
    finally:
        lab.close()


def reply(lab, sent=None, resolved_offset=0):
    d = lab.home / 'state/pending-replies'
    d.mkdir(exist_ok=True)
    q = f'corr_id=0123456789abcdef\ntask_id={lab.id}\ndelivered_epoch={lab.base - 60}\n'
    path = d / '0123456789abcdef'
    if sent is None:
        path.write_text(q + 'phase=delivered\n')
    else:
        path.write_text(q + f'phase=resolved\nresolved_epoch={sent + resolved_offset}\n')


only = set(sys.argv[4].split(',')) if len(sys.argv) > 4 else None
S = [
    ('plain-working-after-ack', lambda: steered('plain-working-after-ack',
        after_ack=lambda l, s: l.line(f'working [at={s + 801}]: acknowledged the inbox; no report yet'), expect=True)),
    ('typed-blocked-after-working', lambda: steered('typed-blocked-after-working',
        after_ack=lambda l, s: (l.line(f'working [at={s + 800}]: acknowledged'),
                                l.line(f'blocked [at={s + 850}]: reported the validation outcome')), expect=False)),
    ('reply-same-second', lambda: steered('reply-same-second',
        setup=lambda l, s=None: reply(l, s, 0), expect=True)),
    ('reply-later-second', lambda: steered('reply-later-second',
        setup=lambda l, s=None: reply(l, None) if s is None else None,
        after_ack=lambda l, s: reply(l, s, 1), expect=False)),
    ('failed-later-second-ship', lambda: steered('failed-later-second-ship',
        after_ack=lambda l, s: l.line(f'failed [at={s + 800}]: tests broke, cannot continue'), expect=False)),
    ('failed-same-second-ship', lambda: steered('failed-same-second-ship',
        setup=lambda l, s=None: l.line(f'failed [at={s}]: written in the delivery second') if s else None,
        expect=True)),
    ('secondmate-done-later-second', lambda: steered('secondmate-done-later-second', kind='secondmate',
        after_ack=lambda l, s: l.line(f'done [at={s + 800}]: routed work finished'), expect=False)),
    ('secondmate-working-later-second-control', lambda: steered('secondmate-working-later-second-control',
        kind='secondmate', after_ack=lambda l, s: l.line(f'working [at={s + 800}]: still busy'), expect=True)),
    ('cadence-failed-ship', lambda: cadence('cadence-failed-ship', 'ship', 'failed')),
    ('cadence-done-secondmate-with-work', lambda: cadence('cadence-done-secondmate-with-work', 'secondmate', 'done')),
]
for name, fn in S:
    if only and name not in only:
        continue
    try:
        fn()
    except Exception as exc:
        results.append(dict(scenario=name, label=LABEL, error=str(exc)[:2000]))
        print(f'[{LABEL}] {name}: ERROR {str(exc)[:2000]}', flush=True)
print(json.dumps(results, indent=1))
