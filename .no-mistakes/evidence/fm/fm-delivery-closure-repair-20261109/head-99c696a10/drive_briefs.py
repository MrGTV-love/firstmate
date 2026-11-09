#!/usr/bin/env python3
"""Live drive of the real fm-brief.sh output and fm-captain-hold.sh owner gate in marked lab homes.
Usage: drive_briefs.py <candidate-root> <base-root> <evidence-dir>
"""
import json, os, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path

CAND, BASE, EV = (Path(p).resolve() for p in sys.argv[1:4])
results = {}


class Lab:
    def __init__(self, name, source=CAND):
        self.name, self.source = name, source
        self.dir = Path(tempfile.mkdtemp(prefix='fm-lab.', dir=os.environ.get('TMPDIR', '/tmp'))).resolve()
        self.home = Path(subprocess.check_output([str(CAND / 'bin/fm-lab-home.sh'), 'create', str(self.dir)], text=True).strip())
        (self.home / 'tmp').mkdir()
        (self.home / '.tasks.toml').write_text('backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
        (self.home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        self.state = self.home / 'state'
        self.env = {'PATH': '%s:%s' % (Path(sys.executable).parent, os.environ['PATH']), 'HOME': str(self.home),
                    'TMPDIR': str(self.home / 'tmp'), 'FM_HOME': str(self.home), 'PYTHONDONTWRITEBYTECODE': '1',
                    'NO_MISTAKES_GATE': '1', 'FM_SECONDMATE_CHARTER': 'Supervise only assigned synthetic fixture work.'}
        self.log = []

    def run(self, label, argv):
        p = subprocess.run([str(a) for a in argv], env=self.env, cwd=self.home, text=True, capture_output=True, timeout=120)
        rec = {'label': label, 'argv': [str(a) for a in argv], 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr}
        self.log.append(rec)
        return rec

    def hold(self, label, *args):
        return self.run(label, [self.source / 'bin/fm-captain-hold.sh', *args])

    def fold(self, label, sid):
        return self.run(label, ['bash', '-c', '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"', '_', self.source, self.state / (sid + '.status')])['stdout']

    def status(self, line, sid):
        return self.run('status: ' + line[:40], [self.source / 'bin/fm-status-append.sh', self.state / (sid + '.status'), line])

    def brief(self, sid, flags):
        r = self.run('scaffold-' + sid, [self.source / 'bin/fm-brief.sh', sid, *flags])
        assert r['exit'] == 0, r
        return (self.home / 'data' / sid / 'brief.md').read_text()

    def finish(self, a, extra=None):
        passed = all(a.values())
        out = {'scenario': self.name, 'passed': passed, 'assertions': a, 'extra': extra or {}, 'transcript': self.log}
        (EV / (self.name + '.json')).write_text(json.dumps(out, indent=2))
        results[self.name] = passed
        print(json.dumps({'scenario': self.name, 'passed': passed, 'assertions': a}, indent=1), flush=True)
        shutil.rmtree(self.dir, ignore_errors=True)


now = lambda: str(int(time.time()))


def scout_none():
    lab = Lab('r5a-scout-no-choices')
    sid = 'fixture-scout-none'
    brief = lab.brief(sid, ['sample', '--scout'])
    (EV / 'r5-emitted-scout-brief.md').write_text(brief)
    meta = lab.state / (sid + '.meta')
    meta.write_text('kind=scout\nmode=scout\nspawn_gen=fixture\n')
    before = meta.read_bytes()
    report = lab.home / 'data' / sid / 'report.md'
    report.write_text('# Fixture\nUnresolved captain choices: none.\n')
    done = lab.status('done [at=%s]: report ready at %s; Unresolved captain choices: none.' % (now(), report), sid)
    v1 = lab.hold('verify-before-owner', 'verify', sid)
    unchanged = meta.read_bytes() == before
    c = lab.hold('owner-complete-none', 'complete', sid, '--none')
    v2 = lab.hold('verify-after-owner', 'verify', sid)
    a = {'worker_status_ok': done['exit'] == 0, 'worker_left_metadata_alone': unchanged,
         'report_ready_does_not_pass_gate': v1['exit'] != 0, 'owner_none_ok': c['exit'] == 0,
         'owner_attested_verifies': v2['exit'] == 0,
         'metadata_attested': 'decisions_reviewed=1' in meta.read_text(),
         'brief_tells_worker_not_to_mutate': 'Do not invoke the captain-hold mutation commands' in brief,
         'brief_gives_owner_complete': 'complete %s --none' % sid in brief}
    lab.finish(a, {'verify_before': v1['stderr'], 'meta_after': meta.read_text()})


def scout_choice():
    lab = Lab('r5b-scout-open-choice')
    sid = 'fixture-scout-choice'
    lab.brief(sid, ['sample', '--scout'])
    meta = lab.state / (sid + '.meta')
    meta.write_text('kind=scout\nmode=scout\nspawn_gen=fixture\n')
    before = meta.read_bytes()
    report = lab.home / 'data' / sid / 'report.md'
    report.write_text('# Fixture\nUnresolved captain choice: route north or south.\n')
    lab.status('needs-decision [key=route] [at=%s]: report ready at %s; route north or south' % (now(), report), sid)
    open_before = lab.fold('fold-open', sid)
    v1 = lab.hold('verify-before-owner', 'verify', sid)
    none = lab.hold('none-refuses-open-key', 'complete', sid, '--none')
    unchanged = meta.read_bytes() == before
    call = sid + '-route-call'
    h = lab.hold('owner-hold', 'hold', call, '--title', 'Choose route', '--reason', 'Question: route? Options: north; south', '--repo', 'sample', '--origin', sid)
    c = lab.hold('owner-complete-inventory', 'complete', sid, call)
    v2 = lab.hold('owner-attested-verifies', 'verify', sid)
    a = {'key_open_before_owner': open_before.startswith('route\t'), 'verify_refuses_before_owner': v1['exit'] != 0,
         'none_refused_with_open_key': none['exit'] != 0, 'refusal_left_metadata_unchanged': unchanged,
         'hold_ok': h['exit'] == 0, 'complete_with_held_id_ok': c['exit'] == 0, 'verify_ok_after_owner': v2['exit'] == 0,
         'held_id_recorded': call in meta.read_text(), 'task_in_backlog': call in (lab.home / 'data/backlog.md').read_text()}
    lab.finish(a, {'none_stderr': none['stderr'], 'meta_after': meta.read_text()})


def terminal_fold():
    # Why the brief forbids done/failed while a key is open: the existing fold retires it for scout and ship, not for secondmate.
    out = {}
    for kind, sid in (('scout', 's-scout'), ('ship', 's-ship'), ('secondmate', 's-mate')):
        lab = Lab('r5c-fold-' + kind)
        (lab.state / (sid + '.meta')).write_text('kind=%s\nspawn_gen=fixture\n' % kind)
        lab.status('needs-decision [key=route] [at=%s]: choose' % now(), sid)
        before = lab.fold('before', sid)
        lab.status('done [at=%s]: other work finished' % now(), sid)
        after = lab.fold('after-done', sid)
        out[kind] = {'before': before, 'after': after}
        lab.finish({'key_open_before': before.startswith('route\t')}, out[kind])
    a = {'scout_done_retires_key': out['scout']['after'].strip() == '', 'ship_done_retires_key': out['ship']['after'].strip() == '',
         'secondmate_done_keeps_key': out['secondmate']['after'].startswith('route\t')}
    results['r5c-summary'] = all(a.values())
    (EV / 'r5c-summary.json').write_text(json.dumps({'assertions': a, 'observed': out}, indent=2))
    print(json.dumps({'r5c': a}, indent=1), flush=True)


def roles():
    # Emitted briefs on base and candidate: ship keeps its delivery contract; secondmate escalation text is restored (F3).
    def emit(source, flags, sid):
        lab = Lab('tmp-role', source)
        text = lab.brief(sid, flags).replace(str(lab.home), '<HOME>').replace(str(source), '<ROOT>')
        shutil.rmtree(lab.dir, ignore_errors=True)
        return text
    base_mate, cand_mate = emit(BASE, ['--secondmate', '--no-projects'], 'mate'), emit(CAND, ['--secondmate', '--no-projects'], 'mate')
    base_ship, cand_ship = emit(BASE, ['sample', '--mode', 'no-mistakes'], 'shp'), emit(CAND, ['sample', '--mode', 'no-mistakes'], 'shp')
    base_scout, cand_scout = emit(BASE, ['sample', '--scout'], 'sct'), emit(CAND, ['sample', '--scout'], 'sct')
    (EV / 'r5-emitted-ship-brief.md').write_text(cand_ship)
    (EV / 'r5-emitted-secondmate-brief.md').write_text(cand_mate)
    a = {'secondmate_brief_unchanged_from_base': base_mate == cand_mate,
         'ship_forbids_terminal_while_key_open': 'terminal ship status retires open keys' in cand_ship and 'terminal ship status retires' not in base_ship,
         'scout_forbids_terminal_while_key_open': 'terminal scout status retires open keys' in cand_scout,
         'scout_no_longer_self_gates': 'pass its shared completion gate' not in cand_scout and 'pass its shared completion gate' in base_scout,
         'scout_loads_policy': 'captain-hold-lifecycle/SKILL.md' in cand_scout}
    results['r5d-role-briefs'] = all(a.values())
    (EV / 'r5d-role-briefs.json').write_text(json.dumps(a, indent=2))
    print(json.dumps({'r5d': a}, indent=1), flush=True)


for f in (scout_none, scout_choice, terminal_fold, roles):
    try:
        f()
    except Exception as exc:
        results[f.__name__ + '-error'] = False
        print('ERROR', f.__name__, repr(exc), flush=True)
(EV / 'brief-summary.json').write_text(json.dumps(results, indent=2))
print('SUMMARY', results)
