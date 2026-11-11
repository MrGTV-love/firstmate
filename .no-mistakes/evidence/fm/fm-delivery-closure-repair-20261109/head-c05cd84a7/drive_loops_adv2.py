#!/usr/bin/env python3
"""Live drive of the real open-work ledger (bin/fm-open-loops.sh --json) in marked lab homes.
Real fleet snapshot, real tmux windows on the lab socket, real busy-state writer, real status
appender, real tasks-axi backlog, real fm-captain-hold.sh and fm-teardown.sh. No forge call:
network CLIs fail closed. Only the external treehouse CLI is a recording stub (teardown).
Usage: drive_loops.py <candidate-root> <base-root> <prefix-root> <evidence-dir> [scenario...]
  base-root   = tree at the PR base commit
  prefix-root = tree at the commit just before the R1 isolation fix
"""
import json, os, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

CAND, BASE, PREFIX, EV = (Path(p).resolve() for p in sys.argv[1:5])
EV.mkdir(parents=True, exist_ok=True)
SCENARIOS = sys.argv[5:]
results = {}
NOW = int(time.time())
OLD = NOW - 7200
CURRENT = None


class Lab:
    def __init__(self, name):
        self.name = name
        self.dir = Path(tempfile.mkdtemp(prefix='fm-lab.', dir=os.environ.get('TMPDIR', '/tmp'))).resolve()
        self.home = Path(subprocess.check_output([str(CAND / 'bin/fm-lab-home.sh'), 'create', str(self.dir)], text=True).strip())
        self.sock = subprocess.check_output([str(CAND / 'bin/fm-lab-home.sh'), 'tmux-dir', str(self.home)], text=True).strip()
        self.state = self.home / 'state'
        self.fakebin = self.home / 'fakebin'
        self.fakebin.mkdir()
        (self.home / 'tmp').mkdir()
        for tool in ('gh', 'gh-axi', 'slack-axi', 'curl'):
            p = self.fakebin / tool
            p.write_text('#!/bin/sh\necho "unexpected network CLI: $0" >&2\nexit 97\n')
            p.chmod(0o700)
        th = self.fakebin / 'treehouse'
        th.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$FM_HOME/treehouse.log"\nexit 0\n')
        th.chmod(0o700)
        # Process-liveness stand-in only: a link to /bin/sleep whose name the product's process classifier
        # reads as a harness agent. It is not a harness, takes no prompt and proves nothing about a model.
        self.agent = self.fakebin / 'claude-idle-stand-in'
        self.agent.symlink_to('/bin/sleep')
        (self.home / 'config' / 'backend').write_text('tmux\n')
        (self.home / '.tasks.toml').write_text('backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
        (self.home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        self.env = {
            'PATH': '%s:%s:%s' % (self.fakebin, Path(sys.executable).parent, os.environ['PATH']),
            'HOME': str(self.home), 'TMPDIR': str(self.home / 'tmp'), 'FM_HOME': str(self.home),
            'TMUX_TMPDIR': self.sock, 'FM_GITHUB_ACCOUNTING': '0', 'PYTHONDONTWRITEBYTECODE': '1',
            'NO_MISTAKES_GATE': '1', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
            'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
            'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'}
        self.log = []
        self.project = self.home / 'projects' / 'project-a'
        self.project.mkdir(parents=True)
        self.git(self.project, 'init', '-q', '-b', 'main')
        (self.project / 'base').write_text('base\n')
        self.git(self.project, 'add', 'base')
        self.git(self.project, 'commit', '-q', '-m', 'baseline')
        self.windows = 0
        global CURRENT
        CURRENT = self

    def git(self, path, *args):
        return subprocess.check_output(['git', '-C', str(path), *args], env=self.env, text=True).strip()

    def run(self, label, argv, timeout=120, env=None, quiet=False):
        merged = dict(self.env, **(env or {}))
        p = subprocess.Popen([str(a) for a in argv], env=merged, cwd=self.home, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
        timed_out = False
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(p.pid, signal.SIGKILL)
            out, err = p.communicate()
        rec = {'label': label, 'argv': [str(a) for a in argv], 'exit': p.returncode, 'timed_out': timed_out,
               'stdout': out, 'stderr': err}
        if env:
            rec['extra_env'] = env
        if not quiet:
            self.log.append(rec)
        return rec

    def task(self, tid, kind='scout', verb='done', window=True, idle=True, report=True, commit=False,
             mode=None, note='report ready for owner'):
        """One real task record: meta, backlog row, status line, optional live window, idle record, report, copy."""
        work = self.home / 'projects' / ('wt-' + tid)
        if kind == 'ship':
            self.git(self.project, 'worktree', 'add', '-q', '-b', 'fm/' + tid, str(work))
            if commit:
                (work / tid).write_text(tid + '\n')
                self.git(work, 'add', tid)
                self.git(work, 'commit', '-q', '-m', 'candidate work for ' + tid)
        else:
            work.mkdir(parents=True)
        mode = mode or ('scout' if kind == 'scout' else 'local-only')
        meta = 'kind=%s\nmode=%s\nharness=claude\nspawn_gen=fixture-%s\nwindow=isolated:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\n' % (
            kind, mode, tid, tid, tid, work, self.project)
        if kind == 'ship':
            meta += 'branch=fm/%s\n' % tid
        (self.state / (tid + '.meta')).write_text(meta)
        self.run('backlog-add-' + tid, ['tasks-axi', 'add', tid, 'fixture ' + kind, '--kind', kind, '--repo', 'sample'])
        self.run('backlog-start-' + tid, ['tasks-axi', 'start', tid])
        if report:
            (self.home / 'data' / tid).mkdir(parents=True, exist_ok=True)
            (self.home / 'data' / tid / 'report.md').write_text('# Fixture report\nUnresolved captain choices: none.\n')
        self.status(tid, '%s [at=%d]: %s' % (verb, OLD, note))
        os.utime(self.state / (tid + '.status'), (OLD, OLD))  # two hours pass; some rows age from the log mtime
        if window:
            self.window(tid)
        if idle:
            gen = self.run('busy-arm-' + tid, [CAND / 'bin/fm-busy-event.sh', 'arm', self.state, tid])['stdout'].strip()
            r = self.run('busy-idle-' + tid, [CAND / 'bin/fm-busy-event.sh', 'apply', self.state, tid, 'idle', '--gen', gen,
                                              '--source', 'claude-hook', '--event', 'stop'])
            assert r['exit'] == 0, r
        return work

    def window(self, tid):
        if self.windows == 0:
            argv = ['tmux', 'new-session', '-d', '-s', 'isolated', '-n', 'fm-' + tid, '%s 900' % self.agent]
        else:
            argv = ['tmux', 'new-window', '-d', '-t', 'isolated:', '-n', 'fm-' + tid, '%s 900' % self.agent]
        r = self.run('tmux-window-' + tid, argv)
        assert r['exit'] == 0, r
        self.windows += 1

    def status(self, tid, line):
        r = self.run('status-append ' + line[:50], [CAND / 'bin/fm-status-append.sh', self.state / (tid + '.status'), line])
        assert r['exit'] == 0, r
        return r

    def crew(self, tid, source=CAND):
        return self.run('crew-state-' + tid, ['bash', source / 'bin/fm-crew-state.sh', tid])['stdout'].strip()

    def ledger(self, label, source=CAND, env=None):
        rec = self.run(label, ['bash', source / 'bin/fm-open-loops.sh', '--json'], env=env)
        try:
            data = json.loads(rec['stdout'])
        except ValueError:
            data = {'complete': None, 'rows': [], 'parse_error': rec['stdout'][-400:] + rec['stderr'][-800:]}
        rec['rows_summary'] = sorted('%s %s overdue=%s' % (r['category'], r['subject'], r.get('overdue')) for r in data['rows'])
        return data

    def hold(self, label, *args, source=CAND):
        return self.run(label, [source / 'bin/fm-captain-hold.sh', *args])

    def finish(self, assertions, extra=None):
        passed = all(assertions.values())
        data = {'scenario': self.name, 'candidate': str(CAND), 'passed': passed, 'assertions': assertions,
                'extra': extra or {}, 'env': self.env, 'transcript': self.log}
        (EV / (self.name + '.json')).write_text(json.dumps(data, indent=2))
        results[self.name] = {'passed': passed, 'assertions': assertions}
        print(json.dumps({'scenario': self.name, 'passed': passed, 'assertions': assertions, 'extra': extra or {}}, indent=1), flush=True)
        subprocess.run(['tmux', 'kill-server'], env=self.env, capture_output=True)
        subprocess.run([str(CAND / 'bin/fm-lab-home.sh'), 'teardown', str(self.home)], capture_output=True, env=dict(os.environ))
        shutil.rmtree(self.dir, ignore_errors=True)
        shutil.rmtree(self.sock, ignore_errors=True)


def rows(report, category):
    return {r['subject']: r for r in report['rows'] if r['category'] == category}


def cats(report, subject):
    return sorted(r['category'] for r in report['rows'] if r['subject'] == subject)


def l1_done_scout_lifecycle():
    """Done scout, live idle pane, report, no PR: owner row until the real owner handoff and teardown."""
    lab = Lab('l1-done-scout-owner-handoff')
    tid = 'review-a'
    lab.task(tid)
    state = lab.crew(tid)
    base = lab.ledger('ledger-base', source=BASE)
    first = lab.ledger('ledger-candidate-1')
    row = rows(first, 'completed_task').get(tid, {})
    second = lab.ledger('ledger-candidate-fresh-process')
    td_early = lab.run('teardown-before-owner-complete', ['bash', CAND / 'bin/fm-teardown.sh', tid], timeout=90)
    after_refusal = lab.ledger('ledger-after-refused-teardown')
    comp = lab.hold('owner-complete-none', 'complete', tid, '--none')
    after_complete = lab.ledger('ledger-after-complete')
    ver = lab.hold('owner-verify', 'verify', tid)
    td = lab.run('teardown-after-owner-complete', ['bash', CAND / 'bin/fm-teardown.sh', tid], timeout=90)
    final = lab.ledger('ledger-after-teardown')
    a = {'snapshot_reads_done': state.startswith('state: done'),
         'base_has_no_owner_row': not cats(base, tid) or cats(base, tid) == ['silent_report'],
         'candidate_has_completed_task': bool(row),
         'row_is_overdue_and_firstmate_owned': row.get('overdue') is True and row.get('owner') == 'firstmate',
         'action_names_owner_handoff': 'consume the report' in row.get('next_action', ''),
         'fresh_process_recovers_same_row': tid in rows(second, 'completed_task'),
         'teardown_refused_before_owner_complete': td_early['exit'] != 0,
         'row_stays_after_refused_teardown': tid in rows(after_refusal, 'completed_task'),
         'owner_complete_ok': comp['exit'] == 0,
         'row_stays_after_inventory_attestation_only': tid in rows(after_complete, 'completed_task'),
         'verify_ok': ver['exit'] == 0,
         'teardown_ok_after_owner_complete': td['exit'] == 0,
         'row_gone_after_teardown': not cats(final, tid),
         'ledger_complete': first.get('complete') is True and final.get('complete') is True}
    lab.finish(a, {'crew_state': state, 'row': row, 'base_categories': cats(base, tid),
                   'teardown_early_stderr': td_early['stderr'][-600:], 'teardown_stderr': td['stderr'][-600:]})


def l2_failed_scout_with_report():
    """A failed scout that wrote a report stays a failed_task; the base commit shows nothing for it."""
    lab = Lab('l2-failed-scout-with-report')
    tid = 'review-failed'
    lab.task(tid, verb='failed', note='could not finish; partial report written')
    state = lab.crew(tid)
    base = lab.ledger('ledger-base', source=BASE)
    cand = lab.ledger('ledger-candidate')
    row = rows(cand, 'failed_task').get(tid, {})
    a = {'snapshot_reads_failed': state.startswith('state: failed'),
         'base_has_no_failed_task_row': tid not in rows(base, 'failed_task'),
         'candidate_has_failed_task_row': bool(row), 'row_overdue': row.get('overdue') is True,
         'no_completed_task_for_failed': tid not in rows(cand, 'completed_task')}
    lab.finish(a, {'crew_state': state, 'row': row, 'base_categories': cats(base, tid), 'candidate_categories': cats(cand, tid)})


def l3_done_ship():
    """Done ship, no PR: unlanded candidate gets completed_task + unlanded_commit; landed ship gets neither."""
    lab = Lab('l3-done-ship-candidate')
    tid = 'ship-a'
    work = lab.task(tid, kind='ship', commit=True, report=False, note='candidate committed')
    head = lab.git(work, 'rev-parse', 'HEAD')
    state = lab.crew(tid)
    base = lab.ledger('ledger-base-unlanded', source=BASE)
    pending = lab.ledger('ledger-candidate-unlanded')
    row = rows(pending, 'completed_task').get(tid, {})
    lab.git(lab.project, 'merge', '-q', '--ff-only', 'fm/' + tid)
    lab.log.append({'label': 'land: fast-forward project main to the candidate head', 'head': head,
                    'main': lab.git(lab.project, 'rev-parse', 'main')})
    state_landed = lab.crew(tid)
    landed = lab.ledger('ledger-candidate-landed')
    a = {'snapshot_reads_done': state.startswith('state: done'),
         'base_has_no_completed_task': tid not in rows(base, 'completed_task'),
         'unlanded_has_completed_task': bool(row),
         'action_names_delivery_path': 'selected delivery path' in row.get('next_action', ''),
         'unlanded_has_unlanded_commit': tid in rows(pending, 'unlanded_commit'),
         'landed_has_no_completed_task': tid not in rows(landed, 'completed_task'),
         'landed_has_no_unlanded_commit': tid not in rows(landed, 'unlanded_commit')}
    lab.finish(a, {'crew_state': state, 'crew_state_landed': state_landed, 'row': row,
                   'unlanded_categories': cats(pending, tid), 'landed_categories': cats(landed, tid),
                   'base_categories': cats(base, tid)})


def l4_captain_drop():
    """A recorded captain drop retires both the done and the failed scout rows; an undropped twin keeps its row."""
    lab = Lab('l4-captain-drop')
    for tid, verb in (('drop-done', 'done'), ('drop-failed', 'failed'), ('keep-done', 'done')):
        lab.task(tid, verb=verb)
    before = lab.ledger('ledger-before-drop')
    backlog = lab.home / 'data/backlog.md'
    text = backlog.read_text().splitlines()
    out = []
    for line in text:
        out.append(line)
        if line.startswith('- [ ] drop-done ') or line.startswith('- [ ] drop-failed '):
            out.append('  dropped')
    backlog.write_text('\n'.join(out) + '\n')
    lab.log.append({'label': 'record the captain drop as the backlog body line the snapshot reads', 'backlog': backlog.read_text()})
    snap = json.loads(lab.run('snapshot', ['bash', CAND / 'bin/fm-fleet-snapshot.sh', '--home-input'], quiet=True)['stdout'])
    drops = {r['id']: r.get('captain_drop') for r in snap['backlog']['records']}
    after = lab.ledger('ledger-after-drop')
    a = {'before_done_row': 'drop-done' in rows(before, 'completed_task'),
         'before_failed_row': 'drop-failed' in rows(before, 'failed_task'),
         'snapshot_records_drop': drops.get('drop-done') is True and drops.get('drop-failed') is True and not drops.get('keep-done'),
         'dropped_done_row_gone': 'drop-done' not in rows(after, 'completed_task'),
         'dropped_failed_row_gone': 'drop-failed' not in rows(after, 'failed_task'),
         'undropped_twin_keeps_row': 'keep-done' in rows(after, 'completed_task')}
    lab.finish(a, {'drops': drops, 'before': sorted((r['category'], r['subject']) for r in before['rows']),
                   'after': sorted((r['category'], r['subject']) for r in after['rows'])})


def l5_unreadable_status_isolated():
    """R1: a done task whose status log cannot be folded must not hide later tasks' rows.
    Seam (disclosed): the status log must be readable when the real snapshot runs and unreadable when the
    collector folds it, as when the log grows past the cap between the two reads. Each tree's bin/ is copied
    and only fm-fleet-snapshot.sh is replaced by a wrapper that runs that tree's REAL snapshot script without
    the cap variables. The collector, the fold, git reads and every other script are the tree's own."""
    lab = Lab('l5-unreadable-completion-status-isolated')
    lab.task('a-blind')
    lab.task('b-after', kind='ship', verb='failed', commit=True, report=False, note='push failed; commits are local only')
    lab.task('c-gone', verb='failed', window=False, idle=False, note='worker died mid-investigation')
    status = lab.state / 'a-blind.status'
    status.write_text(('working [at=%d]: %s\n' % (OLD - 3600, 'x' * 80)) * 40 + 'done [at=%d]: ready for owner\n' % OLD)
    os.utime(status, (OLD, OLD))
    lab.log.append({'label': 'a-blind status log is larger than the fold cap used below', 'bytes': status.stat().st_size})
    cap = {'FM_STATUS_CAP_BYTES': '2048', 'FM_STATUS_CAP_RESERVE_BYTES': '1'}
    seams = {}
    for name, tree in (('candidate', CAND), ('prefix', PREFIX)):
        root = lab.home / ('seam-' + name)
        shutil.copytree(tree / 'bin', root / 'bin')
        wrapper = root / 'bin' / 'fm-fleet-snapshot.sh'
        wrapper.write_text('#!/usr/bin/env bash\nexec env -u FM_STATUS_CAP_BYTES -u FM_STATUS_CAP_RESERVE_BYTES bash "%s/bin/fm-fleet-snapshot.sh" "$@"\n' % tree)
        wrapper.chmod(0o755)
        seams[name] = root
    lab.log.append({'label': 'snapshot wrapper (the only replaced file)', 'text': (seams['candidate'] / 'bin/fm-fleet-snapshot.sh').read_text()})
    normal = lab.ledger('ledger-candidate-real-tree-no-cap')
    cand = lab.ledger('ledger-candidate-capped-fold', source=seams['candidate'], env=cap)
    pre = lab.ledger('ledger-prefix-capped-fold', source=seams['prefix'], env=cap)
    coverage = ' | '.join(r.get('evidence') or '' for r in cand['rows'] if r['category'] == 'coverage')
    pre_coverage = ' | '.join(r.get('evidence') or '' for r in pre['rows'] if r['category'] == 'coverage')
    later = lambda rep: sorted(cats(rep, 'b-after') + cats(rep, 'c-gone'))
    want = ['failed_task', 'missing_worker', 'silent_report', 'unlanded_commit']
    a = {'control_without_cap_is_complete': normal.get('complete') is True,
         'control_has_all_rows': 'a-blind' in rows(normal, 'completed_task') and [c for c in later(normal) if c != 'silent_report'] == ['failed_task', 'missing_worker', 'unlanded_commit'],
         'candidate_reports_incomplete': cand.get('complete') is False,
         'candidate_names_the_unreadable_read': 'completion status a-blind' in coverage,
         'candidate_keeps_blind_task_row': rows(cand, 'completed_task').get('a-blind', {}).get('overdue') is True,
         'candidate_keeps_later_failed_task': 'b-after' in rows(cand, 'failed_task'),
         'candidate_keeps_later_unlanded_commit': 'b-after' in rows(cand, 'unlanded_commit'),
         'candidate_keeps_later_missing_worker': 'c-gone' in rows(cand, 'missing_worker'),
         'prefix_tree_loses_later_failed_task': 'b-after' not in rows(pre, 'failed_task'),
         'prefix_tree_loses_later_unlanded_commit': 'b-after' not in rows(pre, 'unlanded_commit'),
         'prefix_tree_degrades_all_workers_not_one_read': 'workers:' in pre_coverage and 'completion status a-blind' not in pre_coverage,
         'prefix_tree_also_loses_blind_row': 'a-blind' not in rows(pre, 'completed_task')}
    lab.finish(a, {'candidate_coverage': coverage, 'prefix_coverage': pre_coverage,
                   'control_later_rows': later(normal), 'candidate_later_rows': later(cand), 'prefix_later_rows': later(pre),
                   'candidate_a_blind': cats(cand, 'a-blind'), 'prefix_a_blind': cats(pre, 'a-blind')})


def l6_done_scout_pane_gone():
    """Adversarial: the done scout's pane is gone (closed window, crashed or restarted tmux). Its report is
    still unconsumed and nobody ran the owner handoff. Does any owner row remain? A failed twin is the control."""
    lab = Lab('l6-done-scout-pane-gone')
    tid, twin = 'review-gone', 'review-gone-failed'
    lab.task(tid)
    lab.task(twin, verb='failed', note='could not finish')
    live = lab.ledger('ledger-panes-live')
    kills = [lab.run('close-window-' + t, ['tmux', 'kill-window', '-t', 'isolated:fm-' + t])['exit'] for t in (tid, twin)]
    time.sleep(1)
    state, twin_state = lab.crew(tid), lab.crew(twin)
    gone = lab.ledger('ledger-panes-gone')
    gone_base = lab.ledger('ledger-base-panes-gone', source=BASE)
    a = {'row_present_while_pane_live': tid in rows(live, 'completed_task'),
         'windows_closed': kills == [0, 0],
         'failed_twin_keeps_an_owner_row': 'missing_worker' in cats(gone, twin),
         'done_scout_keeps_an_owner_row_after_pane_gone': bool([c for c in cats(gone, tid) if c != 'silent_report'])}
    lab.finish(a, {'crew_state_after': state, 'twin_crew_state_after': twin_state, 'categories_live': cats(live, tid),
                   'categories_gone': cats(gone, tid), 'twin_categories_gone': cats(gone, twin),
                   'base_categories_gone': cats(gone_base, tid), 'ledger_complete_after': gone.get('complete'),
                   'report_still_present': (lab.home / 'data' / tid / 'report.md').is_file(),
                   'meta_still_present': (lab.state / (tid + '.meta')).is_file(),
                   'decisions_reviewed_recorded': 'decisions_reviewed=1' in (lab.state / (tid + '.meta')).read_text()})


def l7_complete_keeps_pr_footer():
    """Owner runs complete after a PR is recorded: the PR identity lines must stay the last lines of the task record."""
    out = {}
    for name, tree in (('base', BASE), ('candidate', CAND)):
        lab = Lab('l7-complete-keeps-pr-footer-' + name)
        tid = 'ship-pr'
        lab.task(tid, kind='ship', commit=True, report=False, window=False, idle=False, note='candidate committed')
        meta = lab.state / (tid + '.meta')
        with meta.open('a') as f:
            f.write('pr=https://github.com/example/repo/pull/1\npr_head=1111111111111111111111111111111111111111\n')
        before = meta.read_text()
        lab.log.append({'label': 'meta-before', 'text': before})
        c = lab.hold('owner-complete-none', 'complete', tid, '--none', source=tree)
        after = meta.read_text()
        lab.log.append({'label': 'meta-after', 'text': after})
        v = lab.hold('owner-verify', 'verify', tid, source=tree)
        lines = after.splitlines()
        out[name] = {'complete_exit': c['exit'], 'verify_exit': v['exit'], 'last_two_lines': lines[-2:],
                     'footer_still_last': lines[-2:] == before.splitlines()[-2:],
                     'attested': 'decisions_reviewed=1' in lines,
                     'other_fields_kept_in_order': [l for l in lines if not l.startswith(('decisions_reviewed=', 'decision_keys='))] == before.splitlines(),
                     'mode': oct(meta.stat().st_mode & 0o777), 'stray_temp_files': sorted(p.name for p in lab.state.glob('.fm-captain-meta.*'))}
        ok = out[name]
        if name == 'candidate':
            a = {'complete_ok': ok['complete_exit'] == 0, 'verify_ok': ok['verify_exit'] == 0, 'attested': ok['attested'],
                 'pr_footer_still_last': ok['footer_still_last'], 'other_fields_kept_in_order': ok['other_fields_kept_in_order'],
                 'no_stray_temp_file': not ok['stray_temp_files'],
                 'base_put_inventory_after_the_footer': out['base']['footer_still_last'] is False}
        else:
            a = {'complete_ok': ok['complete_exit'] == 0, 'attested': ok['attested']}
        lab.finish(a, ok)


def l8_done_scout_pane_not_provably_idle():
    """Adversarial scope check: the done scout's pane is alive but the harness never recorded an idle turn end."""
    lab = Lab('l8-done-scout-pane-not-provably-idle')
    tid = 'review-noidle'
    lab.task(tid, idle=False)
    state = lab.crew(tid)
    rep = lab.ledger('ledger-live-pane-no-idle-record')
    silent = rows(rep, 'silent_report').get(tid, {})
    a = {'done_scout_has_completed_task_row': tid in rows(rep, 'completed_task')}
    lab.finish(a, {'crew_state': state, 'categories': cats(rep, tid), 'ledger_complete': rep.get('complete'),
                   'silent_report_evidence': silent.get('evidence'),
                   'coverage': [r.get('evidence') for r in rep['rows'] if r['category'] == 'coverage']})



def close(lab, *tids):
    codes = [lab.run('close-window-' + t, ['tmux', 'kill-window', '-t', 'isolated:fm-' + t])['exit'] for t in tids]
    time.sleep(1)
    return codes


def summary(rep):
    return sorted((r['category'], r['subject'], r.get('overdue')) for r in rep['rows'])


def l9_owner_lines_after_done():
    """Adversarial: pane closed after `done`; then real owner tools run. Does any later owner-written line or
    attestation retire the row before teardown or a drop?"""
    lab = Lab('l9-closed-pane-owner-actions-keep-row')
    none_id, held_id, live_held = 'review-none', 'review-held', 'review-held-live'
    lab.task(none_id)
    for tid in (held_id, live_held):
        lab.task(tid, verb='needs-decision [key=route]', note='route north or south')
        lab.status(tid, 'done [at=%d]: report ready for owner; one open choice' % OLD)
        os.utime(lab.state / (tid + '.status'), (OLD, OLD))
    kills = close(lab, none_id, held_id)
    states0 = {t: lab.crew(t) for t in (none_id, held_id, live_held)}
    before = lab.ledger('ledger-closed-before-owner')
    comp_none = lab.hold('owner-complete-none', 'complete', none_id, '--none')
    after_none = lab.ledger('ledger-after-complete-none')
    res = {}
    for tid in (held_id, live_held):
        call = tid + '-route-call'
        res[tid] = [lab.hold('owner-hold-' + tid, 'hold', call, '--title', 'Choose route', '--reason',
                             'Question: route? Options: north; south', '--repo', 'sample', '--origin', tid)['exit'],
                    lab.hold('owner-complete-held-' + tid, 'complete', tid, call)['exit'],
                    lab.hold('owner-verify-' + tid, 'verify', tid)['exit']]
    states1 = {t: lab.crew(t) for t in (none_id, held_id, live_held)}
    after_held = lab.ledger('ledger-after-held-transfer')
    tails = {t: (lab.state / (t + '.status')).read_text().splitlines()[-1] for t in (none_id, held_id, live_held)}
    def owner_row(rep, tid):
        return [c for c in cats(rep, tid) if c not in ('silent_report',)]
    a = {'windows_closed': kills == [0, 0],
         'closed_rows_before_owner': all(t in rows(before, 'completed_task') for t in (none_id, held_id)),
         'complete_none_ok': comp_none['exit'] == 0,
         'row_stays_after_complete_none_on_closed_pane': none_id in rows(after_none, 'completed_task'),
         'hold_complete_verify_ok': all(v == [0, 0, 0] for v in res.values()),
         'closed_pane_task_keeps_an_owner_row_after_held_transfer': bool(owner_row(after_held, held_id)),
         'live_pane_task_keeps_an_owner_row_after_held_transfer': bool(owner_row(after_held, live_held))}
    lab.finish(a, {'crew_before': states0, 'crew_after': states1, 'last_status_line': tails, 'owner_exits': res,
                   'rows_before': summary(before), 'rows_after_none': summary(after_none),
                   'rows_after_held': summary(after_held), 'complete': after_held.get('complete'),
                   'coverage': [r.get('evidence') for r in after_held['rows'] if r['category'] == 'coverage']})


def l10_closed_pane_no_false_rows():
    """Adversarial: pane closed. The row must not appear for work that is not a pending completion."""
    lab = Lab('l10-closed-pane-no-false-completion-rows')
    lab.task('resumed')
    lab.status('resumed', 'working [at=%d]: owner asked for one more pass' % (OLD + 60))
    lab.task('paused-x', verb='paused', note='waiting on an external dependency')
    lab.task('dropped-gone')
    lab.task('pr-ship', kind='ship', commit=True, report=False,
             note='candidate committed; PR https://github.com/example/sample/pull/7')
    landed = lab.task('landed-ship', kind='ship', commit=True, report=False, note='candidate committed')
    lab.task('unlanded-ship', kind='ship', commit=True, report=False, note='candidate committed')
    lab.git(lab.project, 'merge', '-q', '--ff-only', 'fm/landed-ship')
    backlog = lab.home / 'data/backlog.md'
    out = []
    for line in backlog.read_text().splitlines():
        out.append(line)
        if line.startswith('- [ ] dropped-gone '):
            out.append('  dropped')
    backlog.write_text('\n'.join(out) + '\n')
    ids = ('resumed', 'paused-x', 'dropped-gone', 'pr-ship', 'landed-ship', 'unlanded-ship')
    kills = close(lab, *ids)
    states = {t: lab.crew(t) for t in ids}
    snap = json.loads(lab.run('snapshot', ['bash', CAND / 'bin/fm-fleet-snapshot.sh', '--home-input'], quiet=True)['stdout'])
    prs = {t['id']: t['pr'].get('url') for t in snap['tasks']}
    rep = lab.ledger('ledger-all-panes-closed')
    done = rows(rep, 'completed_task')
    a = {'windows_closed': kills == [0] * len(ids),
         'resumed_work_has_no_completed_task': 'resumed' not in done,
         'resumed_work_is_a_missing_worker': 'missing_worker' in cats(rep, 'resumed'),
         'paused_has_no_completed_task': 'paused-x' not in done,
         'dropped_has_no_completed_task': 'dropped-gone' not in done,
         'snapshot_records_pr': bool(prs.get('pr-ship')),
         'recorded_pr_has_no_completed_task': 'pr-ship' not in done,
         'landed_ship_has_no_completed_task': 'landed-ship' not in done,
         'unlanded_ship_keeps_completed_task': 'unlanded-ship' in done,
         'unlanded_ship_keeps_unlanded_commit': 'unlanded-ship' in rows(rep, 'unlanded_commit')}
    lab.finish(a, {'crew': states, 'prs': prs, 'categories': {t: cats(rep, t) for t in ids},
                   'complete': rep.get('complete'),
                   'coverage': [r.get('evidence') for r in rep['rows'] if r['category'] == 'coverage']})


def l11_closed_pane_retirement():
    """The closed-pane row leaves through the real owner handoff and teardown, not before."""
    lab = Lab('l11-closed-pane-row-retires-at-teardown')
    tid = 'review-retire'
    lab.task(tid)
    kills = close(lab, tid)
    first = lab.ledger('ledger-closed')
    early = lab.run('teardown-before-owner-complete', ['bash', CAND / 'bin/fm-teardown.sh', tid], timeout=90)
    mid = lab.ledger('ledger-after-refused-teardown')
    comp = lab.hold('owner-complete-none', 'complete', tid, '--none')
    ver = lab.hold('owner-verify', 'verify', tid)
    td = lab.run('teardown-after-owner-complete', ['bash', CAND / 'bin/fm-teardown.sh', tid], timeout=90)
    final = lab.ledger('ledger-after-teardown')
    a = {'window_closed': kills == [0],
         'row_present_with_closed_pane': tid in rows(first, 'completed_task'),
         'teardown_refused_before_owner_complete': early['exit'] != 0,
         'row_stays_after_refused_teardown': tid in rows(mid, 'completed_task'),
         'owner_complete_and_verify_ok': comp['exit'] == 0 and ver['exit'] == 0,
         'teardown_ok': td['exit'] == 0,
         'no_rows_after_teardown': not cats(final, tid)}
    lab.finish(a, {'rows_first': summary(first), 'rows_final': summary(final), 'complete_final': final.get('complete'),
                   'teardown_early_stderr': early['stderr'][-600:], 'teardown_stderr': td['stderr'][-600:]})


def l12_other_live_states():
    """Observation: a task whose last line is `done` under each other state the real snapshot can report."""
    lab = Lab('l12-done-line-under-other-live-states')
    lab.task('busy-done', idle=False)
    gen = lab.run('busy-arm', [CAND / 'bin/fm-busy-event.sh', 'arm', lab.state, 'busy-done'])['stdout'].strip()
    busy = lab.run('busy-apply', [CAND / 'bin/fm-busy-event.sh', 'apply', lab.state, 'busy-done', 'busy', '--gen', gen,
                                  '--source', 'claude-hook', '--event', 'prompt'])
    lab.task('resolved-after-done', verb='needs-decision [key=route]', note='route north or south')
    lab.status('resolved-after-done', 'done [at=%d]: report ready for owner' % OLD)
    lab.status('resolved-after-done', 'resolved [key=route]: north')
    lab.task('resolved-closed', verb='needs-decision [key=route]', note='route north or south')
    lab.status('resolved-closed', 'done [at=%d]: report ready for owner' % OLD)
    lab.status('resolved-closed', 'resolved [key=route]: north')
    close(lab, 'resolved-closed')
    ids = ('busy-done', 'resolved-after-done', 'resolved-closed')
    states = {t: lab.crew(t) for t in ids}
    rep = lab.ledger('ledger')
    a = {'resolved_line_after_done_live_pane_keeps_an_owner_row':
             bool([c for c in cats(rep, 'resolved-after-done') if c != 'silent_report']),
         'resolved_line_after_done_closed_pane_keeps_an_owner_row':
             bool([c for c in cats(rep, 'resolved-closed') if c != 'silent_report'])}
    lab.finish(a, {'crew': states, 'busy_apply': [busy['exit'], busy['stderr'][-300:]],
                   'categories': {t: cats(rep, t) for t in ids}, 'rows': summary(rep), 'complete': rep.get('complete'),
                   'coverage': [r.get('evidence') for r in rep['rows'] if r['category'] == 'coverage'],
                   'note': 'the resolved lines are appended with the real fm-status-append.sh in the exact form fm-send.sh --resolve-key writes'})



def l13_real_answer_after_done():
    """Adversarial: a scout logs an open choice, then `done`. The owner answers the choice with the real
    fm-send.sh --resolve-key. Does the unconsumed report keep an owner row?"""
    lab = Lab('l13-owner-answer-after-done')
    live, gone = 'answered-live', 'answered-closed'
    for tid in (live, gone):
        lab.task(tid, verb='needs-decision [key=route]', note='route north or south')
        lab.status(tid, 'done [at=%d]: report ready for owner; one open choice' % OLD)
    before = lab.ledger('ledger-before-answer')
    sends = {t: lab.run('owner-answer-' + t, ['bash', CAND / 'bin/fm-send.sh', t, '--resolve-key', 'route', 'go north'],
                        timeout=150) for t in (live, gone)}
    tails = {t: (lab.state / (t + '.status')).read_text().splitlines()[-2:] for t in (live, gone)}
    close(lab, gone)
    states = {t: lab.crew(t) for t in (live, gone)}
    after = lab.ledger('ledger-after-answer')
    after_base = lab.ledger('ledger-base-after-answer', source=BASE)
    own = lambda rep, t: [c for c in cats(rep, t) if c != 'silent_report']
    a = {'rows_before_answer': all(t in rows(before, 'completed_task') for t in (live, gone)),
         'real_answer_delivered': all(s['exit'] == 0 for s in sends.values()),
         'answer_wrote_resolved_line': all('resolved' in ' '.join(v) for v in tails.values()),
         'live_pane_keeps_an_owner_row_after_answer': bool(own(after, live)),
         'closed_pane_keeps_an_owner_row_after_answer': bool(own(after, gone))}
    lab.finish(a, {'send': {t: [s['exit'], s['stdout'][-300:], s['stderr'][-600:]] for t, s in sends.items()},
                   'status_tail': tails, 'crew_after': states,
                   'categories_before': {t: cats(before, t) for t in (live, gone)},
                   'categories_after': {t: cats(after, t) for t in (live, gone)},
                   'base_categories_after': {t: cats(after_base, t) for t in (live, gone)},
                   'complete_after': after.get('complete'),
                   'coverage_after': [r.get('evidence') for r in after['rows'] if r['category'] == 'coverage']})


ALL = {'l13': l13_real_answer_after_done}
for key in (SCENARIOS or list(ALL)):
    try:
        ALL[key]()
    except Exception as exc:
        import traceback
        results[key + '-error'] = {'passed': False, 'error': repr(exc)}
        print('ERROR', key, traceback.format_exc(), flush=True)
        if CURRENT is not None and CURRENT.dir.exists():
            (EV / (CURRENT.name + '.error-transcript.json')).write_text(json.dumps(CURRENT.log, indent=2))
            subprocess.run(['tmux', 'kill-server'], env=CURRENT.env, capture_output=True)
            subprocess.run([str(CAND / 'bin/fm-lab-home.sh'), 'teardown', str(CURRENT.home)], capture_output=True, env=dict(os.environ))
            shutil.rmtree(CURRENT.dir, ignore_errors=True)
            shutil.rmtree(CURRENT.sock, ignore_errors=True)
prior = json.loads((EV / 'loops-summary.json').read_text()) if (EV / 'loops-summary.json').exists() else {}
prior.update(results)
(EV / 'loops-summary.json').write_text(json.dumps(prior, indent=2))
print('SUMMARY', json.dumps({k: v['passed'] for k, v in results.items()}))
