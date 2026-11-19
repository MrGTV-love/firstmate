"""Drive bin/fm-open-loops.sh (from a given bin tree) in scratch FM_HOMEs and report whether a
steered silent_report row stays presented overdue at the delivery deadline."""
import datetime as dt, json, os, shutil, subprocess, sys, time
from pathlib import Path
src, world = Path(sys.argv[1]), Path(sys.argv[2])
code, fake = world / 'code', world / 'fakebin'
shutil.copytree(src, code / 'bin'); fake.mkdir()
for name in ('ssh', 'gh', 'gh-axi', 'claude', 'codex', 'dsh', 'omp', 'ps'):
    t = fake / name
    tel = ('if [ "$#" -eq 3 ] && [ "$1" = -S ] && [ "$2" = -axo ]; then exit 0; fi\n') if name == 'ps' else ''
    t.write_text('#!/bin/sh\n' + tel + 'exit 97\n'); t.chmod(0o755)
snap = code / 'bin/fm-fleet-snapshot.sh'
snap.write_text('#!/usr/bin/env python3\nimport os, sys\nfrom pathlib import Path\n'
    'if sys.argv[1:] == ["--contribution-input"]:\n    print(\'{"backlog":{"present":true,"records":[{"state":"in_flight"}]}}\')\n'
    'else:\n    print((Path(os.environ["FM_HOME"])/"snapshot.json").read_text())\n'); snap.chmod(0o755)
(code / 'bin/fm-peek.sh').write_text('#!/bin/sh\necho waiting\n'); (code / 'bin/fm-peek.sh').chmod(0o755)
base = int(time.time())
iso = lambda s: dt.datetime.fromtimestamp(s, dt.timezone.utc).isoformat()

class H:
    def __init__(s, name):
        s.home = world / name
        for p in ('state', 'data', 'config', 'projects', 'user', 'tmp'): (s.home / p).mkdir(parents=True)
        s.now = base; s.status = s.home / 'state/worker.status'
        s.status.write_text(f'working [at={base-7200}]: continue validation\n')
        (s.home / 'state/worker.meta').write_text('kind=ship\nspawn_gen=g1\n')
        for p in (s.status, s.home / 'state/worker.meta'): os.utime(p, (base, base))
        task = dict(id='worker', kind='ship', project='', branch='', backend='fixture', spawn_gen='g1',
                    current_state=dict(state='working', source='fixture'),
                    endpoint=dict(exists=True, agent_alive='alive', target='fixture'),
                    pr=dict(url=None), paths=dict(worktree=dict(path=None)), hints={})
        (s.home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1', tasks=[task],
                                                               backlog=dict(present=True, records=[]))))
        s.env = dict(os.environ, HOME=str(s.home / 'user'), TMPDIR=str(s.home / 'tmp'), FM_HOME=str(s.home),
                     NM_HOME=str(s.home / 'nm'), FM_DURATION_FILE='off', FM_SUPERVISION_ACTOR='main',
                     PYTHONDONTWRITEBYTECODE='1', PATH=str(fake) + ':' + os.environ['PATH'])
        for k in [k for k in s.env if k.endswith('_OVERRIDE') or k in ('NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS')]: s.env.pop(k)
        rep = s.collect()
        s.ident = next(r['id'] for r in rep['rows'] if r['category'] == 'silent_report')
        assert s.ident in s.cli('--present-overdue').stdout
    def cli(s, *a, ok=True):
        r = subprocess.run([str(code / 'bin/fm-open-loops.sh'), *a], env=dict(s.env, FM_OPEN_LOOPS_NOW=str(s.now)),
                           text=True, capture_output=True)
        if ok: assert r.returncode == 0, (a, r.returncode, r.stdout, r.stderr)
        return r
    def collect(s): return json.loads(s.cli('--heartbeat', '--json').stdout)
    def inbox_msg(s):
        d = s.home / 'state/worker.inbox'; d.mkdir(exist_ok=True); p = d / '001.msg'
        p.write_text(f'schema=fm-task-inbox.v1\nat={iso(s.now)}\n--\nPlease report.\n'); return p
    def ack(s, msg, at):
        h = s.home / 'state/worker.inbox/handled'; h.mkdir(); msg.rename(h / '001.msg'); os.utime(h, (at, at))
    def line(s, text): s.status.open('a').write(text + '\n')
    def reply(s, corr, delivered, resolved=None):
        d = s.home / 'state/pending-replies'; d.mkdir(exist_ok=True)
        body = f'corr_id={corr}\ntask_id=worker\ndelivered_epoch={delivered}\n'
        body += 'phase=delivered\n' if resolved is None else f'phase=resolved\nresolved_epoch={resolved}\n'
        (d / corr).write_text(body)
    def overdue(s):
        s.collect(); out = s.cli('--present-overdue').stdout
        return s.ident in out, out

def scenario(name, fn):
    h = H(name); fn(h); h.now = base + 900
    flag, out = h.overdue()
    print(json.dumps(dict(scenario=name, still_overdue_at_deadline=flag,
                          presented=[l for l in out.splitlines() if h.ident in l or 'steered' in l][:3])), flush=True)

def s1(h):  # ack + plain working line in the ack second
    m = h.inbox_msg(); h.cli('action', h.ident, 'steered', '--evidence', '001.msg')
    h.now = base + 800; h.ack(m, h.now); h.line(f'working [at={h.now}]: got the inbox; no report yet')
def s2(h):  # plain working line written in the delivery second, before the steer
    h.line(f'working [at={base}]: line written in the steer second'); m = h.inbox_msg()
    h.cli('action', h.ident, 'steered', '--evidence', '001.msg'); h.now = base + 800; h.ack(m, h.now)
def s3(h):  # Finding witness: question answered in the same second T as the steer
    h.reply('0123456789abcdef', base - 60); m = h.inbox_msg(); h.reply('0123456789abcdef', base - 60, base)
    h.cli('action', h.ident, 'steered', '--evidence', '001.msg'); h.now = base + 800; h.ack(m, h.now)
def s4(h):  # reply resolved one second after the steer
    h.reply('0123456789abcdef', base - 60); m = h.inbox_msg()
    h.cli('action', h.ident, 'steered', '--evidence', '001.msg')
    h.reply('0123456789abcdef', base - 60, base + 1); h.now = base + 800; h.ack(m, h.now)
def s5(h):  # typed blocked report after ack
    m = h.inbox_msg(); h.cli('action', h.ident, 'steered', '--evidence', '001.msg')
    h.now = base + 800; h.ack(m, h.now); h.line(f'blocked [at={h.now}]: report: waiting on decision X')
def s6(h):  # steer delivered as a pending reply; that same reply resolves in the delivery second
    h.reply('abcd0123456789ef', base); h.cli('action', h.ident, 'steered', '--evidence', 'abcd0123456789ef')
    h.reply('abcd0123456789ef', base, base)
def s7(h):  # steer delivered as reply A; a different reply B resolves in the same second
    h.reply('abcd0123456789ef', base); h.reply('fedcba9876543210', base - 60)
    h.cli('action', h.ident, 'steered', '--evidence', 'abcd0123456789ef')
    h.reply('fedcba9876543210', base - 60, base)
def s8(h):  # no formal steer: a plain working line still resets the ordinary silence clock
    h.now = base + 800; h.line(f'working [at={h.now}]: progress')

for n, f in [('S1-ack-plus-working-same-second', s1), ('S2-working-before-steer-same-second', s2),
             ('S3-reply-same-second-as-steer', s3), ('S4-reply-later-second', s4),
             ('S5-typed-blocked-report', s5), ('S6-named-delivery-reply-same-second', s6),
             ('S7-other-reply-same-second-as-named-delivery', s7), ('S8-no-steer-working-line-resets-clock', s8)]:
    scenario(n, f)
