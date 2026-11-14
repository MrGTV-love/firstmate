#!/usr/bin/env python3
"""Executable fixtures for fm-cpu-pass.test.sh; never use fleet state, load or the live host."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fm_cpu_pass_fixture import *  # noqa: E402,F401,F403
from fm_cpu_pass_fixture import cleanup  # noqa: E402

try:
    # Native core scaling: 18 cores admit six counted runs and 10 cores three.
    # One below the limit admits at once; at the limit the next start queues
    # without running until a counted run is released.
    for cores, limit in ((18, 6), (10, 3)):
        folder, db, env = case('scaling-' + str(cores), cores=cores, running=limit - 1)
        marker = folder / 'below.marker'
        finish(launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'below'))
        assert marker.exists()
        change(db, "INSERT INTO runs (id, status) VALUES ('at-limit', 'running')")
        marker = folder / 'at.marker'
        child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'at')
        pending(folder, 1)
        wait_for(lambda: 'waiting: ' in (folder / 'at.stderr').read_text(), str(cores) + '-core start queued at the limit')
        assert not marker.exists() and child.poll() is None
        change(db, "UPDATE runs SET status='completed' WHERE id='at-limit'")
        finish(child)
        assert marker.exists()

    # Load average is not an admission input. With too little recorded history the
    # start falls back to the counted-run limit, and a high load5 neither blocks a
    # start below it nor admits one at it.
    folder, db, env = case('fallback-ignores-load', running=5, load=500)
    marker, log = folder / 'high-load.marker', folder / 'high-load.stderr'
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'high-load'))
    assert marker.exists() and 'admitted: counted=5 limit=6 basis=fallback' in log.read_text(), log.read_text()
    folder, db, env = case('fallback-full-low-load', running=6, load=0)
    marker = folder / 'low-load.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'low-load')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=6 limit=6 basis=fallback' in (folder / 'low-load.stderr').read_text(), 'full fallback count')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    finish(child)
    assert marker.exists()
    # One qualifying recorded run, a record for another host and unreadable text fall back (the base's three
    # triggers); none refuses and none reads as an empty host.
    for name, record in (('one-run', lambda f: calibrate(f, peaks=[3.0])), ('other-host', lambda f: calibrate(f, host='other-host')),
                         ('other-ram', lambda f: calibrate(f, total=64 * GIB)),
                         ('garbage', lambda f: (f / 'fmhome/state').mkdir(parents=True, exist_ok=True) or (f / 'fmhome/state/.memory-calibration.json').write_text('{')),
                         ('walk-fails', lambda f: calibrate(f) or (f / 'fmhome/.fm-secondmate-parent').write_text('garbage\n'))):
        folder, db, env = case('fallback-' + name, running=6)
        record(folder)
        child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm')], env, folder / 'f')
        pending(folder, 1)
        wait_for(lambda: 'waiting: counted=6 limit=6 basis=fallback' in (folder / 'f.stderr').read_text(), name + ' fallback count')
        assert child.poll() is None
        change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
        finish(child)
    # A secondmate home reads its parent's record (the root home owns the calibration).
    folder, db, env = case('root-home', running=6)
    calibrate(folder)
    (folder / 'fmhome').rename(folder / 'rootfm')
    (folder / 'childfm').mkdir()
    (folder / 'childfm/.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' % (folder / 'rootfm'))
    env['FM_HOME'] = str(folder / 'childfm')
    log = folder / 'root.stderr'
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'root.marker')], env, folder / 'root'))
    # Six registered runs the reading cannot see yet reserve R each: 6 x 3 + 8 = 26 GiB of 40.
    assert 'admitted: counted=6 projected=%d ' % (26 * GIB) in log.read_text() and \
        'reservation=%d active_term=%d slack=%d runs_measured=13 readings_measured=1 ' % (3 * GIB, GIB, 8 * GIB) in log.read_text(), log.read_text()

    # A worker has FM_DURATION_HOME and no FM_HOME; it still finds the root home's record.
    folder, db, env = case('worker-env', running=6, measured=True)
    env.pop('FM_HOME')
    env['FM_DURATION_HOME'] = str(folder / 'fmhome')
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'worker.marker')], env, folder / 'worker'))
    assert 'admitted: counted=6 projected=' in (folder / 'worker.stderr').read_text(), (folder / 'worker.stderr').read_text()

    # A running run's peak so far is not a per-run peak: six young runs at 0.2 GiB would pull
    # the 75th percentile down to 1 GiB, but R stays 3 GiB from the 13 finished runs.
    folder, db, env = case('live-runs', running=6, measured=True)
    calibrate(folder, live=['baseline-%d' % i for i in range(6)])
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'live.marker')], env, folder / 'live'))
    text = (folder / 'live.stderr').read_text()
    assert 'admitted: counted=6 projected=%d ' % (6 * 3 * GIB + 8 * GIB) in text and 'reservation=%d active_term=%d slack=%d runs_measured=13 ' % (3 * GIB, GIB, 8 * GIB) in text, text

    # S takes every qualifying peak: a CI-ready running run holds the largest (20 GiB), and
    # a peak so far can only be too low. R ranks that CI-ready run (14 peaks: 4 GiB) but
    # leaves out a parked run short of CI-ready (12 GiB), which would make the 12th rank 5.8 GiB.
    folder, db, env = case('ci-ready-peak', measured=True)
    calibrate(folder, extra={'ci-done': 20 * GIB, 'parked': 12 * GIB})
    change(db, "INSERT INTO runs (id, status, ci_ready_at) VALUES ('ci-done', 'running', 1)")
    change(db, "INSERT INTO runs (id, status, awaiting_agent_since) VALUES ('parked', 'running', 1)")
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'ci.marker')], env, folder / 'ci'))
    text = (folder / 'ci.stderr').read_text()
    # Nothing counted: the new run alone reserves S.
    assert 'admitted: counted=0 projected=%d ' % (20 * GIB) in text and 'reservation=%d active_term=%d slack=%d runs_measured=14 ' % (4 * GIB, GIB, 20 * GIB) in text, text

    # One-start minimum: with nothing counted, one start is admitted although S = 8 GiB
    # exceeds the 7 GiB budget, unless the backstop reports an overload.
    folder, db, env = case('floor', measured=True, available=7 * GIB)
    facts(folder, available=7 * GIB, pressure=2)
    marker = folder / 'floor.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'floor')
    pending(folder, 1)
    wait_for(lambda: 'waiting: overload: memory: native memory pressure level 2' in (folder / 'floor.stderr').read_text(), 'floor still pauses on overload')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    facts(folder, available=7 * GIB)
    finish(child)
    assert marker.exists() and 'admitted: counted=0 projected=%d budget=%d' % (8 * GIB, 7 * GIB) in (folder / 'floor.stderr').read_text()

    # Measured mode. R = 3 GiB (75th percentile of the 13 recorded peaks), S = 8 GiB
    # (the largest) and A = 1 GiB; the task:crewmate record is not a no-mistakes run and is ignored.
    # Each registered run the reading cannot see yet reserves R, the new run S; admit while
    # n x R + S <= available + held. 37 GiB admits n = 0..9 (9 x 3 + 8 = 35) and refuses n = 10 (38).
    folder, db, env = case('burst', cores=3, measured=True, available=37 * GIB)
    names = ['burst-%d' % i for i in range(11)]
    clients = {name: launch(cli + ['pipeline-start', '--'] + client_start(folder, db, env, name)[0], env, folder / name, cwd=folder / 'checkout') for name in names[:10]}
    for name in names[:10]:
        wait_for(lambda: (folder / (name + '.started')).exists(), name + ' grant')
    # All ten run together, none waited for capacity, and three cores' fallback of one never applied.
    assert all(c.poll() is None for c in clients.values())
    for name in names[:10]:
        text = (folder / (name + '.stderr')).read_text()
        # A ready start may queue behind the registration handshake of the starts
        # before it; it is never told to wait for capacity, overload or spacing.
        waits = [line for line in text.splitlines() if 'waiting' in line]
        assert all('projected=' not in line and 'overload' not in line and 'limit=' not in line for line in waits), text
        assert 'admitted: counted=' in text and 'basis=fallback' not in text, text
    assert any('projected=%d budget=%d' % (3 * GIB * 9 + 8 * GIB, 37 * GIB) in (folder / (name + '.stderr')).read_text() for name in names[:10])
    # No artificial wait: the grants follow each other by the registration handshake alone.
    burst_gaps = assert_no_spacing(folder, names[:10])
    # The eleventh projects 38 GiB of 37 and waits; releasing one run lets it start.
    clients[names[10]] = launch(cli + ['pipeline-start', '--'] + client_start(folder, db, env, names[10])[0], env, folder / names[10], cwd=folder / 'checkout')
    pending(folder, 1)
    wait_for(lambda: 'waiting: overload' not in (folder / (names[10] + '.stderr')).read_text() and
             'waiting: counted=10 projected=%d budget=%d' % (3 * GIB * 10 + 8 * GIB, 37 * GIB) in (folder / (names[10] + '.stderr')).read_text(),
             'eleventh start waits for reservations')
    assert not (folder / (names[10] + '.started')).exists()
    (folder / 'burst-0.release').touch()
    finish(clients['burst-0'])
    wait_for(lambda: (folder / (names[10] + '.started')).exists(), 'eleventh grant after a release')
    for name in names[1:]:
        (folder / (name + '.release')).touch()
        finish(clients[name])

    # A registration delay no longer spaces grants: the start lock covers only each decision and the publication of
    # its pending reservation, so four starts whose fake registers 2 s after its launch are admitted back to back,
    # each counted at its full R by the next decision (37 GiB: 3 x 3 + 8 fits).
    folder, db, env = case('spacing-registration-delay', cores=3, measured=True, available=37 * GIB)
    env['CASE_LAUNCH_DELAY'] = '2'
    names = ['slow-%d' % i for i in range(4)]
    clients = {name: launch(cli + ['pipeline-start', '--'] + client_start(folder, db, env, name)[0], env, folder / name, cwd=folder / 'checkout') for name in names}
    for name in names:
        wait_for(lambda: (folder / (name + '.started')).exists(), name + ' delayed grant')
    for name in names:
        text = (folder / (name + '.stderr')).read_text()
        waits = [line for line in text.splitlines() if 'waiting' in line]
        assert all('projected=' not in line and 'overload' not in line and 'limit=' not in line for line in waits), text
        assert 'admitted: counted=' in text and 'basis=fallback' not in text, text
    assert all(c.poll() is None for c in clients.values())
    injected_gaps = assert_no_spacing(folder, names)
    assert any(':pending:%d:unseen' % (3 * GIB) in (folder / (name + '.stderr')).read_text() for name in names), 'no pending start was counted'
    for name in names:
        (folder / (name + '.release')).touch()
        finish(clients[name])
    # The check still rejects spacing: grants 2 s apart fail it.
    folder = root / 'spacing-control'
    folder.mkdir()
    for index, name in enumerate(names):
        (folder / (name + '.started')).touch()
        os.utime(folder / (name + '.started'), ns=(10 ** 18 + index * 2 * 10 ** 9,) * 2)
    try:
        assert_no_spacing(folder, names)
    except AssertionError as rejected:
        injected_rejection = str(rejected)
    else:
        raise AssertionError('grants 2 s apart were not rejected: %r' % grant_gaps(folder, names))

    # Load5 alone decides nothing: the same full reservations with idle load admit nothing
    # extra, and fitting reservations under a load of 500 are admitted.
    folder, db, env = case('load-both-ways', cores=18, running=1, measured=True, available=10 * GIB, load=0)
    # one counted run the reading cannot see yet: projected = 3 + 8 = 11 GiB > 10 GiB
    marker = folder / 'idle-full.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'idle-full')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=1 projected=%d budget=%d' % (11 * GIB, 10 * GIB) in (folder / 'idle-full.stderr').read_text(), 'idle load, full reservations')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    # Once visible, the counted run reserves its resident memory or A, whichever is larger,
    # and what it holds is part of the budget: 1 + 8 = 9 GiB of 10 + 1.
    facts(folder, available=10 * GIB, runs=[(None, 'baseline-0', GIB)])
    finish(child)
    assert marker.exists() and 'admitted: counted=1 projected=%d budget=%d' % (9 * GIB, 11 * GIB) in (folder / 'idle-full.stderr').read_text()
    # A counted run's memory is never capped at R or S: 7 GiB held counts 7 GiB in the projection
    # and 7 GiB in the budget, so it nets to nothing free. 7 GiB available: 15 > 14 waits; 8 GiB fits.
    folder, db, env = case('never-capped', cores=18, running=1, measured=True, available=7 * GIB)
    facts(folder, available=7 * GIB, runs=[(None, 'baseline-0', 7 * GIB)])
    marker = folder / 'over.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'over')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=1 projected=%d budget=%d' % (15 * GIB, 14 * GIB) in (folder / 'over.stderr').read_text(), 'resident memory above R is counted')
    time.sleep(0.6)
    assert not marker.exists() and child.poll() is None
    facts(folder, available=8 * GIB, runs=[(None, 'baseline-0', 7 * GIB)])
    finish(child)
    assert marker.exists() and 'admitted: counted=1 projected=%d budget=%d' % (15 * GIB, 15 * GIB) in (folder / 'over.stderr').read_text()
    # Above the largest recorded peak: a run at 10 GiB (above S = 8 GiB) counts 10 GiB, so 7.5 GiB available waits
    # (10 + 8 = 18 > 17.5); a rule capped at S would count 8 and admit (16 <= 17.5). 8 GiB available fits (18 <= 18).
    folder, db, env = case('above-peak', cores=18, running=1, measured=True, available=int(7.5 * GIB))
    facts(folder, available=int(7.5 * GIB), runs=[(None, 'baseline-0', 10 * GIB)])
    marker = folder / 'above.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'above')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=1 projected=%d budget=%d' % (18 * GIB, int(17.5 * GIB)) in (folder / 'above.stderr').read_text(), 'memory above S is counted')
    assert not marker.exists() and child.poll() is None
    facts(folder, available=8 * GIB, runs=[(None, 'baseline-0', 10 * GIB)])
    finish(child)
    assert marker.exists() and 'admitted: counted=1 projected=%d budget=%d' % (18 * GIB, 18 * GIB) in (folder / 'above.stderr').read_text()
    folder, db, env = case('busy-but-fits', cores=18, running=0, measured=True, available=40 * GIB, load=500)
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'busy.marker')], env, folder / 'busy'))
    assert (folder / 'busy.marker').exists()

    # The fleet's recorded healthy states are admitted at the first poll, and a fit that fails still waits.
    # Inputs: R 5.77 GiB and S 13.39 GiB (Main's live diagnosis), A = 1953340270 bytes (the largest
    # per-run concurrent demand of every run but the largest in the copied readings record).
    diag_peaks = [1.0, 2.0, 5.77, 13.39]
    diag_active = 1953340270

    def steps(db, rows):
        for run, name, status, pid in rows:
            change(db, 'INSERT INTO step_results (id, run_id, step_name, step_order, status, agent_pid) VALUES (?, ?, ?, ?, ?, ?)',
                   (run + '-' + name, run, name, 1, status, pid))

    def counted_case(name, available, active, waiting_ci=(), invisible=()):
        """Counted runs: active is (id, rss) at an agent step; waiting_ci and invisible list runs the reading cannot see."""
        folder, db, env = case(name, measured=True, available=available)
        calibrate(folder, peaks=diag_peaks, active=diag_active)
        for run, _ in active:
            change(db, "INSERT INTO runs (id, status, repo_id) VALUES (?, 'running', 'repo')", (run,))
        for run in list(waiting_ci) + list(invisible):
            change(db, "INSERT INTO runs (id, status, repo_id) VALUES (?, 'running', 'repo')", (run,))
        steps(db, [(run, 'review', 'fixing', 4000 + i) for i, (run, _) in enumerate(active)] +
              [(run, 'ci', 'running', None) for run in waiting_ci])
        facts(folder, available=available, runs=[('repo', run, rss) for run, rss in active])
        return folder, db, env

    # (a) Main's live case: 11 counted, 4 waiting on remote CI with no agent and no memory.
    live = [('test-fixing', int(0.70 * GIB)), ('review-a', int(0.43 * GIB)), ('lint', int(2.22 * GIB)),
            ('review-b', int(0.13 * GIB)), ('pr', int(0.13 * GIB)), ('test', int(0.43 * GIB)), ('review-c', int(0.73 * GIB))]
    folder, db, env = counted_case('p1-live', 32.82 * GIB // 16384 * 16384, live, waiting_ci=['ci-361', 'ci-367', 'ci-369', 'ci-3609'])
    finish(launch(cli + ['pipeline-start', '--priority', 'machinery', '--', 'sh', '-c', 'exit 3'], env, folder / 'p1a'), 3)
    text = (folder / 'p1a.stderr').read_text()
    assert 'admitted: counted=11 ' in text and 'start waiting' not in text and 'ci-361:ci-waiting:0:unseen' in text \
        and 'lint:active:%d' % int(2.22 * GIB) in text and 'review-b:active:%d' % diag_active in text, text
    # (b) the 2026-11-03 14:14Z record: 12 runs holding 20.1 GiB together, 25.27 GiB available.
    recorded = [21299200, 118226944, 491290624, 545144832, 574226432, 652591104, 673792000, 1083260928,
                1926561792, 3074097152, 5121441792, 7301611520]
    shape = [('run-%02d' % i, rss) for i, rss in enumerate(recorded)]
    folder, db, env = counted_case('p1-recorded', 27132805120, shape)
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'p1b')], env, folder / 'p1b'))
    text = (folder / 'p1b.stderr').read_text()
    assert 'admitted: counted=12 ' in text and 'start waiting' not in text, text
    projected = 9 * diag_active + 3074097152 + 5121441792 + 7301611520 + int(13.39 * GIB)
    threshold = projected - sum(recorded)
    assert 'projected=%d budget=%d' % (projected, 27132805120 + sum(recorded)) in text, (projected, text)
    # (c) control: the same state with available memory one page below the fit waits and names its inputs.
    folder, db, env = counted_case('p1-control', threshold // 16384 * 16384 - 16384, shape)
    child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'p1c')], env, folder / 'p1c')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=12 projected=%d ' % projected in (folder / 'p1c.stderr').read_text(), 'fit fails at healthy pressure')
    assert not (folder / 'p1c').exists() and 'reserved=[run-00:active:' in (folder / 'p1c.stderr').read_text()
    os.killpg(child.pid, signal.SIGTERM)
    finish(child, -signal.SIGTERM)

    # Which counted runs reserve: with R = 3, S = 8 and 10 GiB available, a counted run that reserves
    # R makes 11 GiB and waits, while one that holds only its resident memory admits.
    for label, rows, visible, admitted in (
            ('ci-waiting', [('x', 'ci', 'running', None)], [], True),
            ('ci-waiting-raised', [('x', 'ci', 'running', None)], [('repo', 'x', 4 * GIB)], True),
            ('ci-agent-resumed', [('x', 'ci', 'fixing', 4321)], [], False),
            # A recorded agent pid that is alive keeps the reservation; a dead one with nothing visible releases (review-f1 cases).
            ('ci-agent-pid', [('x', 'ci', 'running', os.getpid())], [], False),
            ('just-registered', [], [], False),
            ('step-unreadable', None, [], False),
            ('other-step', [('x', 'review', 'running', None)], [], False)):
        folder, db, env = case('p2-' + label, measured=True, available=10 * GIB)
        change(db, "INSERT INTO runs (id, status, repo_id) VALUES ('x', 'running', 'repo')")
        if rows is None:
            change(db, 'DROP TABLE step_results')
        else:
            steps(db, rows)
        facts(folder, available=10 * GIB, runs=visible)
        log = folder / 'p2.stderr'
        child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'p2')], env, folder / 'p2')
        if admitted:
            finish(child)
            held_now = visible[0][2] if visible else 0
            # Unseen, the CI waiter reserves nothing; a visible tree of it at 4 GiB (above A) with no recorded pid is
            # no proof that no agent lives (F1, Main 021), so it counts as active at what it holds, uncapped.
            entry = 'holding_only=[x:ci-waiting:0:unseen' if not visible else 'reserved=[x:active:%d]' % held_now
            assert 'admitted: counted=1 projected=%d ' % (held_now + 8 * GIB) in log.read_text() and \
                entry in log.read_text(), (label, log.read_text())
        else:
            pending(folder, 1)
            wait_for(lambda: 'waiting: counted=1 projected=%d ' % (11 * GIB) in log.read_text(), label + ' keeps its reservation')
            assert not (folder / 'p2').exists() and 'reserved=[x:' in log.read_text(), (label, log.read_text())
            os.killpg(child.pid, signal.SIGTERM)
            finish(child, -signal.SIGTERM)

    # Pause-only backstop (M3). Fitting reservations never override it, it stops nothing
    # that runs, and an unreadable observation never reads as an empty host.
    folder, db, env = case('backstop', measured=True, available=100 * GIB)
    running = launch(cli + ['pipeline-start', '--'] + client_start(folder, db, env, 'already-running')[0], env, folder / 'already', cwd=folder / 'checkout')
    wait_for(lambda: (folder / 'already-running.started').exists(), 'a run already started')
    before_hash = hashlib.sha256(db.read_bytes()).hexdigest()
    for label, bad, good, expected in (
            ('pressure', lambda: facts(folder, available=100 * GIB, pressure=2, runs=[(None, 'already-running', GIB)]),
             lambda: facts(folder, available=100 * GIB, runs=[(None, 'already-running', GIB)]), 'memory: native memory pressure level 2'),
            ('pressure-3', lambda: facts(folder, available=100 * GIB, pressure=3, runs=[(None, 'already-running', GIB)]),
             lambda: facts(folder, available=100 * GIB, runs=[(None, 'already-running', GIB)]), 'memory: native memory pressure level 3'),
            ('pileup', lambda: procs(folder, count=6400), lambda: procs(folder, count=6399), 'process pile-up: 6400 of 10666'),
            ('memory-unreadable', lambda: facts(folder, broken=True), lambda: facts(folder, available=100 * GIB), 'memory: '),
            ('procs-unreadable', lambda: procs(folder, error=True), lambda: procs(folder), 'process count unreadable'),
            ('limit-unreadable', lambda: procs(folder, limit=None), lambda: procs(folder), 'process limit unreadable: case')):
        bad()
        marker = folder / (label + '.marker')
        child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / label)
        pending(folder, 1)
        wait_for(lambda: 'waiting: overload: ' + expected in (folder / (label + '.stderr')).read_text(), label + ' pauses the start')
        time.sleep(0.6)
        assert not marker.exists() and child.poll() is None and running.poll() is None
        assert hashlib.sha256(db.read_bytes()).hexdigest() == before_hash
        good()
        finish(child)
        assert marker.exists(), label
    (folder / 'already-running.release').touch()
    finish(running)

    # A platform with no native memory source and no fixture has no memory hold: the absent source
    # never holds a start, and the count fallback decides (3 cores: limit 1). Below the limit a start
    # is admitted; at the limit it waits and is admitted by itself when the counted run ends.
    folder, db, env = case('no-native-source', cores=3, measured=True)
    env.pop('FM_MEMORY_FIXTURE_DIR')
    env['CASE_PLATFORM'] = 'linux'
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'below')], env, folder / 'below'))
    assert 'admitted: counted=0 limit=1 basis=fallback' in (folder / 'below.stderr').read_text(), (folder / 'below.stderr').read_text()
    change(db, "INSERT INTO runs (id, status) VALUES ('held', 'running')")
    child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'at')], env, folder / 'at')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=1 limit=1 basis=fallback' in (folder / 'at.stderr').read_text(), 'count limit without a memory source')
    assert 'memory' not in (folder / 'at.stderr').read_text() and not (folder / 'at').exists()
    change(db, "UPDATE runs SET status='completed' WHERE id='held'")
    finish(child)
    assert (folder / 'at').exists()

    # A reading that was healthy a moment ago cannot admit a start after the signal turns bad:
    # the grant takes a new reading. Each case first lets a waiter see healthy inputs (it waits
    # at the full counted limit), then changes the signal and frees the slot together, so the old
    # cached reading is the only thing that could grant. It must keep waiting, then start once clear.
    for label, bad, good in (
            ('pressure', lambda f: facts(f, pressure=2), lambda f: facts(f)),
            ('pileup', lambda f: procs(f, count=6400), lambda f: procs(f, count=100)),
            ('memory-unreadable', lambda f: facts(f, broken=True), lambda f: facts(f)),
            ('procs-unreadable', lambda f: procs(f, error=True), lambda f: procs(f))):
        folder, db, env = case('transition-' + label, cores=3, running=1)
        marker, log = folder / 'transition.marker', folder / 'transition.stderr'
        child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'transition')
        pending(folder, 1)
        wait_for(lambda: 'waiting: counted=1 limit=1 basis=fallback' in log.read_text(), label + ' healthy reading seen while full')
        bad(folder)
        change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
        time.sleep(1.2)  # several polls inside the old 2-second reuse window
        assert not marker.exists() and child.poll() is None and 'admitted' not in log.read_text(), (label, log.read_text())
        good(folder)
        finish(child)
        assert marker.exists() and 'admitted: counted=0 limit=1 basis=fallback' in log.read_text(), (label, log.read_text())

    # A host whose counted runs are not CI-ready yet, so their peak may still rise (little memory left), pauses new starts
    # although a lull in load would allow them. Their resident memory is part of the budget,
    # so the pause comes from what the host really has left.
    # Startup memory alone is not a run's reservation: four visible runs at 0.5 GiB each reserve A = 1 GiB.
    folder, db, env = case('test-peak', measured=True, running=4, available=int(9.5 * GIB), load=0)
    facts(folder, available=int(9.5 * GIB), runs=[(None, 'baseline-%d' % i, GIB // 2) for i in range(4)])
    # budget = 9.5 + 2 = 11.5 GiB; projected = 4 x 1 + 8 = 12 GiB. A fifth start waits; one run finishing frees 1 GiB.
    marker = folder / 'peak.marker'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'peak')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=4 projected=%d budget=%d' % (12 * GIB, int(11.5 * GIB)) in (folder / 'peak.stderr').read_text(), 'test peak pauses')
    time.sleep(0.6)
    assert not marker.exists()
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    facts(folder, available=int(9.5 * GIB), runs=[(None, 'baseline-%d' % i, GIB // 2) for i in range(1, 4)])
    finish(child)
    assert marker.exists()

    # Class order still decides who gets scarce capacity (exactly one start fits at a time).
    folder, db, env = case('measured-priority', cores=3, measured=True, running=1, available=10 * GIB)
    classes = ['other', 'vernant-build', 'machinery', 'merge-train']
    clients = {}
    for priority in classes:
        clients[priority] = launch(cli + ['pipeline-start', '--priority', priority, '--'] + client_start(folder, db, env, priority)[0],
            env, folder / priority, cwd=folder / 'checkout')
        pending(folder, len(clients))
    time.sleep(0.6)
    assert not (folder / 'order').exists()
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    expected = list(reversed(classes))
    for index, priority in enumerate(expected):
        wait_for(lambda: (folder / (priority + '.started')).exists(), priority + ' grant')
        assert (folder / 'order').read_text().splitlines() == expected[:index + 1]
        (folder / (priority + '.release')).touch()
        finish(clients[priority])

    # Only status running rows with neither ci_ready_at nor awaiting_agent_since
    # count. Every excluded state is seeded; included rows alone fill the limit,
    # and each daemon-recorded exclusion releases a count when it is set.
    folder, db, env = case('count-definition', cores=3)
    limit = 1
    for row in (('ci-ready', 'running', 1, None), ('parked', 'running', None, 1), ('ci-ready-parked', 'running', 1, 1),
                ('pending', 'pending', None, None), ('completed', 'completed', None, None), ('failed', 'failed', None, None)):
        change(db, 'INSERT INTO runs (id, status, ci_ready_at, awaiting_agent_since) VALUES (?, ?, ?, ?)', row)
    for i in range(limit): change(db, "INSERT INTO runs (id, status) VALUES (?, 'running')", ('active-' + str(i),))
    for name, release in (('parked-start', "UPDATE runs SET awaiting_agent_since=1 WHERE id='active-0'"),
                          ('ci-ready-start', "UPDATE runs SET ci_ready_at=1 WHERE id='active-new'")):
        if name == 'ci-ready-start': change(db, "INSERT INTO runs (id, status) VALUES ('active-new', 'running')")
        marker, log = folder / (name + '.marker'), folder / (name + '.stderr')
        child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / name)
        pending(folder, 1)
        wait_for(lambda: 'waiting: counted=%d limit=%d ' % (limit, limit) in log.read_text(), name + ' full count')
        assert not marker.exists()
        change(db, release)
        finish(child)
        assert marker.exists() and 'admitted: counted=%d limit=%d ' % (limit - 1, limit) in log.read_text(), log.read_text()

    # Queue all classes while at capacity, then release one slot at a time.
    # The startup lock bridges registration even while earlier clients remain
    # alive. All requests initially observe the same full database.
    folder, db, env = case('priority-race', cores=3, running=1)
    limit = 1
    classes = ['other', 'vernant-build', 'machinery', 'merge-train']
    clients = {}
    for priority in classes:
        clients[priority] = launch(cli + ['pipeline-start', '--priority', priority, '--'] + client_start(folder, db, env, priority)[0],
            env, folder / priority, cwd=folder / 'checkout')
        pending(folder, len(clients))
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    expected = list(reversed(classes))
    for index, priority in enumerate(expected):
        wait_for(lambda: (folder / (priority + '.started')).exists(), priority + ' grant')
        assert (folder / 'order').read_text().splitlines() == expected[:index + 1]
        with sqlite3.connect(db) as connection:
            assert connection.execute("SELECT count(*) FROM runs WHERE status='running'").fetchone()[0] == limit
        (folder / (priority + '.release')).touch()
        finish(clients[priority])
    assert (folder / 'order').read_text().splitlines() == expected

    # Unreadable/malformed sources never manufacture headroom or create a DB.
    folder, db, env = case('invalid')
    for bad in (folder / 'missing.sqlite', folder / 'garbage.sqlite'):
        if bad.name == 'garbage.sqlite': bad.write_text('not a database')
        child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'bad-start')], dict(env, CASE_DB=str(bad)), folder / bad.stem)
        finish(child, 125)
        assert not (folder / 'bad-start').exists()
    assert not (folder / 'missing.sqlite').exists()
    # The host database is in WAL mode. After its last writer stops cleanly it has
    # no side files, and mode=ro alone cannot read it. A fresh start still reads
    # the count, and a queued start keeps its place through the stop. The private
    # HOME holds the database at the fixed host path, where the -wal check looks.
    folder, db, env = case('wal', cores=3)
    host = folder / 'home/.no-mistakes/state.sqlite'
    host.parent.mkdir(parents=True)
    db.replace(host)
    db = host
    env.update(HOME=str(folder / 'home'), CASE_DB=str(db))
    writer = sqlite3.connect(db, isolation_level=None)
    writer.execute('PRAGMA journal_mode=WAL').fetchall()
    clean_stop(db, writer)
    before_hash = hashlib.sha256(db.read_bytes()).hexdigest()
    marker, log = folder / 'stopped.marker', folder / 'stopped.stderr'
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'stopped'))
    assert marker.exists() and 'admitted: counted=0 limit=1 ' in log.read_text(), log.read_text()
    assert hashlib.sha256(db.read_bytes()).hexdigest() == before_hash
    # The live writer's row is in the WAL file only, so this queue also proves a
    # live database is not read from its main file alone.
    writer = sqlite3.connect(db, isolation_level=None)
    writer.execute("INSERT INTO runs (id, status) VALUES ('wal-active', 'running')")
    marker, log = folder / 'queued.marker', folder / 'queued.stderr'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'queued')
    pending(folder, 1)
    wait_for(lambda: 'waiting: counted=1 limit=1 ' in log.read_text(), 'queued at full count on a live WAL database')
    clean_stop(db, writer)
    # Longer than two maximum poll delays: the queue reads the stopped state.
    time.sleep(1.2)
    assert child.poll() is None and not marker.exists(), log.read_text()
    writer = sqlite3.connect(db, isolation_level=None)
    writer.execute("UPDATE runs SET status='completed'")
    clean_stop(db, writer)
    finish(child)
    assert marker.exists() and 'admitted: counted=0 limit=1 ' in log.read_text(), log.read_text()
    # A -wal file can hold rows that the main file does not. If it exists but
    # cannot be read, no start may proceed from the main file alone.
    writer = sqlite3.connect(db, isolation_level=None)
    writer.execute('PRAGMA wal_autocheckpoint=0').fetchall()
    writer.execute("INSERT INTO runs (id, status) VALUES ('wal-unread', 'running')")
    wal = Path(str(db) + '-wal')
    wal.chmod(0)
    marker, log = folder / 'unread.marker', folder / 'unread.stderr'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'unread')
    # A superuser can still read the file, so that start queues instead of refusing.
    wait_for(lambda: child.poll() is not None or 'waiting: counted=1 ' in log.read_text(), 'unread WAL outcome')
    assert not marker.exists() and child.poll() in (125, None), log.read_text()
    wal.chmod(0o600)
    writer.close()

    # Queue interruption cannot launch work, strand priority, or release another
    # request's CPU reservation. Failed commands preserve their actual status.
    folder, db, env = case('interrupt', cores=3, running=20)
    marker = folder / 'interrupted-start'
    child = launch(cli + ['pipeline-start', '--', 'touch', str(marker)], env, folder / 'queued')
    pending(folder, 1)
    os.killpg(child.pid, signal.SIGTERM)
    finish(child, -signal.SIGTERM)
    assert not marker.exists()
    # Waiters cancelled by SIGINT remove their own records while another queued
    # start scans them; that scan must never refuse the surviving start.
    survivor = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'survivor')], env, folder / 'survivor')
    pending(folder, 1)
    for i in range(20):
        cancelled = launch(cli + ['pipeline-start', '--priority', 'merge-train', '--', 'touch', str(folder / 'cancelled')],
                           env, folder / ('cancelled-' + str(i)))
        pending(folder, 2)
        os.killpg(cancelled.pid, signal.SIGINT)
        finish(cancelled, 130)
        assert survivor.poll() is None, (folder / 'survivor.stderr').read_text()
    assert not (folder / 'cancelled').exists()
    # A SIGINT whose KeyboardInterrupt a callee swallows still ends the waiting start with 130, without its COMMAND.
    swallowed = launch(cli + ['pipeline-start', '--priority', 'merge-train', '--', 'touch', str(folder / 'swallowed')],
                       dict(env, CASE_SWALLOW_INTERRUPT='1'), folder / 'swallowed')
    pending(folder, 2)
    time.sleep(0.3)
    os.killpg(swallowed.pid, signal.SIGINT)
    finish(swallowed, 130)
    assert not (folder / 'swallowed').exists() and survivor.poll() is None
    change(db, "UPDATE runs SET status='completed'")
    finish(survivor)
    assert (folder / 'survivor').exists()
    child = launch(cli + ['pipeline-start', '--', 'sh', '-c', 'exit 7'], env, folder / 'failure')
    finish(child, 7)
    child = launch(cli + ['pipeline-start', '--', 'true'], env, folder / 'after-failure')
    finish(child)

    # Six real child processes retain their markers but must inherit no slot
    # descriptors. Parent/master completion frees six passes while all remain
    # alive; this catches the pre-fix leak, not just a copied numeric marker.
    folder, db, env = case('descriptors', cores=10)
    master = folder / 'master.py'
    master.write_text('''import json, os, pathlib, subprocess, sys, time
folder = pathlib.Path(sys.argv[1]); pool = pathlib.Path(os.environ['FM_CPU_POOL_DIR'])
if len(sys.argv) > 2:
    inodes = {p.stat().st_ino for p in pool.glob('slot-*.lock')}
    descriptors = []
    for fd in range(3, 256):
        try:
            if os.fstat(fd).st_ino in inodes: descriptors.append(fd)
        except OSError: pass
    # Publish whole: the parent may read the file the moment its name exists.
    (folder / (str(os.getpid()) + '.partial')).write_text(json.dumps(dict(pid=os.getpid(), fds=descriptors, marker=os.environ['FM_CPU_PASS_HELD'])))
    (folder / (str(os.getpid()) + '.partial')).rename(folder / (str(os.getpid()) + '.child'))
    while not (folder / 'release-children').exists(): time.sleep(0.025)
else:
    children = [subprocess.Popen([sys.executable, __file__, str(folder), 'child'], close_fds=False) for _ in range(6)]
    while not (folder / 'release-master').exists(): time.sleep(0.025)
''')
    child = launch(cli + ['run', '--passes', '6', '--', python, str(master), str(folder)], env, folder / 'master')
    wait_for(lambda: len(list(folder.glob('*.child'))) == 6, 'six children')
    observations = [json.loads(p.read_text()) for p in folder.glob('*.child')]
    assert held(env) == 6
    assert all(item['fds'] == [] and item['marker'] == '6' for item in observations), observations
    (folder / 'release-master').touch()
    finish(child)
    assert held(env) == 0
    for item in observations: os.kill(item['pid'], 0)
    (folder / 'release-children').touch()
    (folder / 'observations.json').write_text(json.dumps(observations, indent=2))

    # Actual measured CLI: fresh input goes through admission BEFORE its bound;
    # wait-only reattachment does not requeue. A fresh start launched by the
    # admitted client is a descendant and must queue like any other start. This
    # fake native start writes only the private DB, never the shared daemon.
    folder, db, env = case('duration', cores=3, running=20)
    fake_nm = shim / 'no-mistakes'
    fake_nm.write_text('#!' + python + '\n' + """import os, pathlib, sqlite3, subprocess, sys
folder = pathlib.Path(os.environ['CASE_FOLDER'])
name = sys.argv[sys.argv.index('--intent') + 1] if '--intent' in sys.argv else 'reattach'
if name != 'reattach':
    with sqlite3.connect(folder / 'state.sqlite') as db: db.execute("INSERT INTO runs (id, status) VALUES (?, 'running')", (name,))
if name == 'outer':
    out = open(folder / 'nested.stdout', 'w'); err = open(folder / 'nested.stderr', 'w')
    nested = subprocess.Popen(['python3', %r, 'run', 'no-mistakes.nested', '--', sys.argv[0], 'axi', 'run', '--intent', 'nested'],
                              stdout=out, stderr=err, start_new_session=True)
    (folder / 'nested.pid').write_text(str(nested.pid))
(folder / (name + '.started')).touch()
""" % str(repo / 'bin/fm-duration.py'))
    fake_nm.chmod(0o700)
    env['FM_DURATION_FILE'] = str(folder / 'durations.jsonl')
    env['FM_DURATION_ABSOLUTE_SECS'] = '3'
    duration = [str(proxy), str(repo / 'bin/fm-duration.py'), 'run', '--pipeline-priority', 'machinery', 'no-mistakes.run', '--', str(fake_nm)]
    child = launch(duration + ['axi', 'run', '--intent', 'outer'], env, folder / 'fresh')
    pending(folder, 1)
    time.sleep(3.5)
    assert not (folder / 'outer.started').exists()
    change(db, "UPDATE runs SET status='completed'")
    finish(child)
    assert (folder / 'outer.started').exists()
    samples = lambda key='no-mistakes.run': [row for row in map(json.loads, Path(env['FM_DURATION_FILE']).read_text().splitlines())
                                             if row.get('key') == key and 'event' not in row]
    assert len(samples()) == 1 and samples()[0]['exit'] == 0 and not samples()[0]['timed_out'] \
        and samples()[0]['duration_ms'] < 3000, samples()
    wait_for(lambda: (folder / 'nested.pid').exists(), 'nested start launched')
    pending(folder, 1)
    time.sleep(0.6)
    assert not (folder / 'nested.started').exists()
    change(db, "UPDATE runs SET status='completed' WHERE id='outer'")
    wait_for(lambda: len(samples('no-mistakes.nested')) == 1, 'nested start admitted and measured')
    assert (folder / 'nested.started').exists() and samples('no-mistakes.nested')[0]['exit'] == 0, samples('no-mistakes.nested')
    assert 'pipeline-start admitted' in (folder / 'nested.stderr').read_text()
    change(db, "UPDATE runs SET status='running'")
    child = launch(duration + ['axi', 'run'], env, folder / 'reattach')
    finish(child)
    assert (folder / 'reattach.started').exists()
    # Every genuinely new run joins the one queue, whatever its command formatting; reattachment,
    # responses and status reads never queue. The fake client follows the real CLI's facts: a
    # rerun or an axi run with an intent input starts a run; axi run without one reattaches an
    # active run or exits 2 when none is active (internal/cli/axi_drive.go).
    nm_bin = root / 'nmbin'
    nm_bin.mkdir()
    fake = nm_bin / 'no-mistakes'
    fake.write_text('#!' + python + '\n' + """import os, pathlib, sqlite3, sys
folder = pathlib.Path(os.environ['CASE_FOLDER']); args = sys.argv[1:]
fresh = args[:1] == ['rerun'] or (args[:2] == ['axi', 'run'] and any(
    a in ('--intent', '--intent-file') or a.startswith(('--intent=', '--intent-file=')) for a in args[2:]))
with sqlite3.connect(folder / 'state.sqlite') as db:
    active = db.execute("SELECT count(*) FROM runs WHERE status = 'running'").fetchone()[0]
    if fresh:
        db.execute("INSERT INTO runs (id, status) VALUES (?, 'running')", (os.environ['CASE_NAME'],))
if args[:2] == ['axi', 'run'] and not fresh and not active:
    print('error: --intent or --intent-file is required to start a run'); sys.exit(2)
with (folder / 'order').open('a') as out: out.write(os.environ['CASE_NAME'] + '\\n')
""")
    fake.chmod(0o700)
    intent = root / 'intent.txt'
    intent.write_text('goal\n')
    measured_run = [str(proxy), str(repo / 'bin/fm-duration.py'), 'run', '--pipeline-priority', 'machinery', 'no-mistakes.p6', '--']
    mem_guard = ['bash', str(repo / 'bin/fm-mem-guard.sh'), 'run', '--']
    fresh_shapes = {
        'intent': ['no-mistakes', 'axi', 'run', '--intent', 'goal'],
        'intent-equals': ['no-mistakes', 'axi', 'run', '--intent=goal'],
        'intent-file': ['no-mistakes', 'axi', 'run', '--intent-file', str(intent)],
        'intent-file-equals': ['no-mistakes', 'axi', 'run', '--intent-file=' + str(intent)],
        'intent-stdin': ['no-mistakes', 'axi', 'run', '--intent', '-'],
        'reordered': ['no-mistakes', 'axi', 'run', '--verification-plan', str(intent), '--intent', 'goal'],
        'absolute': [str(fake), 'axi', 'run', '--intent', 'goal'],
        'env-wrapped': ['env', 'A=B', 'no-mistakes', 'axi', 'run', '--intent', 'goal'],
        'shell-string': ['sh', '-c', 'no-mistakes axi run --intent goal'],
        'shell-flags': ['bash', '-ec', 'no-mistakes axi run --intent goal'],
        'shell-options': ['bash', '--noprofile', '--norc', '-o', 'pipefail', '-e', '-c', 'no-mistakes axi run --intent goal'],
        'shell-operator': ['sh', '-c', 'cd .&&no-mistakes axi run --intent goal'],
        'shell-lines': ['sh', '-c', 'no-mistakes axi status\nno-mistakes axi run --intent "two\nlines"'],
        # A route nested in an admitted route's shell string is that one start: it never queues behind itself.
        'nested-mem-guard': ['sh', '-c', 'bash MEMGUARD_PLACEHOLDER run -- no-mistakes axi run --intent goal'],
        # The inner measured route runs under the test's python3 shim too, so it reads the same fixture run database.
        'nested-measured': ['sh', '-c', 'PYTHON_PLACEHOLDER DURATION_PLACEHOLDER run no-mistakes.inner -- no-mistakes axi run --intent goal'],
        # Redirections and comments are not the client's arguments, so the nested route still sees the one start.
        'nested-redirect': ['sh', '-c', 'bash MEMGUARD_PLACEHOLDER run -- no-mistakes axi run --intent goal 2>&1 | cat # note'],
        'nested-quoted-hash': ['sh', '-c', "bash MEMGUARD_PLACEHOLDER run -- no-mistakes axi run --intent '#1 goal' x#y 2>/dev/null"],
        'rerun': ['no-mistakes', 'rerun'],
        # PR 366's recorded fresh start (nm-r2-1.log): fm-duration around env around fm-mem-guard.sh run.
        'pr-366': ['env', 'FM_HOME=HOME_PLACEHOLDER'] + mem_guard[1:] + ['no-mistakes', 'axi', 'run', '--intent-file', str(intent),
                                                                     '--verification-plan', str(intent)],
    }
    not_starts = {
        'reattach': (['no-mistakes', 'axi', 'run'], 0, True),
        'reattach-wait': (['no-mistakes', 'axi', 'run', '--wait', '1m'], 0, True),
        'respond': (['no-mistakes', 'axi', 'respond', '--action', 'approve'], 0, True),
        'status': (['no-mistakes', 'axi', 'status'], 0, True),
        'no-intent-no-run': (['no-mistakes', 'axi', 'run'], 2, False),
        'other-command': (['true'], 0, True),
        # Data that mentions a start, such as a commit message, is not a start.
        'start-as-data': (['echo', 'no-mistakes axi run --intent goal'], 0, True),
        # A later simple command's words are not the reattachment's arguments.
        'shell-later-command': (['sh', '-c', 'no-mistakes axi run; echo --intent'], 0, True),
        'shell-later-line': (['sh', '-c', 'no-mistakes axi run\necho --intent'], 0, True),
        'shell-commented-start': (['sh', '-c', 'true # no-mistakes axi run --intent goal'], 0, True),
    }
    for route_name, route in (('measured', measured_run), ('mem-guard', mem_guard)):
        for name, shape in list(fresh_shapes.items()) + [(n, v[0]) for n, v in not_starts.items()]:
            folder, db, env = case('p6-%s-%s' % (route_name, name), cores=3)
            env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], CASE_NAME=name, FM_DURATION_FILE='off')
            shape = [part.replace('HOME_PLACEHOLDER', str(folder / 'fmhome')).replace('MEMGUARD_PLACEHOLDER', str(repo / 'bin/fm-mem-guard.sh'))
                     .replace('PYTHON_PLACEHOLDER', str(proxy)).replace('DURATION_PLACEHOLDER', str(repo / 'bin/fm-duration.py')) for part in shape]
            code, active = (0, False) if name in fresh_shapes else not_starts[name][1:]
            if active:
                change(db, "INSERT INTO runs (id, status) VALUES ('existing', 'running')")
                change(db, "UPDATE runs SET ci_ready_at = 1 WHERE id = 'existing'")  # active but not counted
            child = launch(route + shape, dict(env, CASE_STDIN='goal'), folder / 'p6')
            finish(child, code)
            text = (folder / 'p6.stderr').read_text() + (folder / 'p6.stdout').read_text()
            admitted = text.count('pipeline-start admitted')
            assert admitted == (1 if name in fresh_shapes else 0), (route_name, name, admitted, text)
            if name == 'no-intent-no-run':
                assert '--intent or --intent-file is required to start a run' in text, text
            with sqlite3.connect(db) as connection:
                new_rows = connection.execute("SELECT count(*) FROM runs WHERE id = ?", (name,)).fetchone()[0]
            assert new_rows == (1 if name in fresh_shapes else 0), (route_name, name)
            assert not list((folder / 'pool').glob('pipeline-waiter-*.lock')), (route_name, name)
    # One queue in class order across routes: a fresh start through fm-mem-guard.sh run (class other)
    # queued first still follows a machinery start through fm-duration.py run.
    folder, db, env = case('p6-order', cores=3, running=1)
    env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off')
    first = launch(mem_guard + fresh_shapes['intent'], dict(env, CASE_NAME='mem-guard-other'), folder / 'first')
    pending(folder, 1)
    second = launch(measured_run + fresh_shapes['intent'], dict(env, CASE_NAME='measured-machinery'), folder / 'second')
    pending(folder, 2)
    change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
    finish(second)
    assert (folder / 'order').read_text().splitlines() == ['measured-machinery'] and first.poll() is None
    change(db, "UPDATE runs SET status='completed' WHERE id='measured-machinery'")
    finish(first)
    assert (folder / 'order').read_text().splitlines() == ['measured-machinery', 'mem-guard-other']
    # Independent review of 5d51fa8be (F1-F7): each case fails on that head and passes on the fix.
    # Every case runs; the failures are collected and reported together.
    fixround = {}

    def fix_case(name, body):
        try:
            body()
            fixround[name] = 'pass'
        except Exception as exc:  # a hang or a refused assertion fails this case only
            fixround[name] = 'FAIL: %s: %s' % (type(exc).__name__, str(exc)[:600])

    stay_bin = root / 'staybin'
    stay_bin.mkdir()
    (stay_bin / 'no-mistakes').write_text('#!' + python + '\n' + """import os, pathlib, sqlite3, sys, time
folder = pathlib.Path(os.environ['CASE_FOLDER']); name = os.environ.get('CASE_RUN', 'run') + '-' + str(os.getpid())
with sqlite3.connect(folder / 'state.sqlite') as db:
    db.execute("INSERT INTO runs (id, status) VALUES (?, 'running')", (name,))
(folder / (name + '.started')).touch()
while not (folder / 'release').exists(): time.sleep(0.025)
with sqlite3.connect(folder / 'state.sqlite') as db:
    db.execute("UPDATE runs SET status = 'completed' WHERE id = ?", (name,))
""")
    (stay_bin / 'no-mistakes').chmod(0o700)
    guard_route = str(repo / 'bin/fm-mem-guard.sh')

    def started(folder):
        return sorted(p.name for p in folder.glob('*.started'))

    def nested_expanded():
        # F1: an outer measured start whose shell string runs the memory route with an expanded intent.
        folder, db, env = case('fix-f1', cores=3)
        env.update(PATH=str(stay_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off')
        child = launch(measured_run + ['bash', '-c', 'X=goal; %s run -- no-mistakes axi run --intent "$X"' % guard_route], env, folder / 'outer')
        wait_for_or = time.monotonic() + 15
        while time.monotonic() < wait_for_or and not started(folder):
            time.sleep(0.05)
        text = (folder / 'outer.stderr').read_text()
        assert started(folder), ('nested start never ran', text, live_entries(folder))
        assert text.count('pipeline-start admitted') == 1 and 'admitted by its enclosing start' in text, text
        # An unrelated later start is not held behind it for good: it waits only for capacity (limit 1).
        (folder / 'release').touch()
        finish(child)

    def identical_sibling():
        # F2 control: a second start with identical arguments from outside the first queues (also on 5d51fa8be).
        folder, db, env = case('fix-f2-sibling', cores=3)
        env.update(PATH=str(stay_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off')
        first = launch(measured_run + ['env', 'A=1', guard_route, 'run', '--'] + fresh_shapes['intent'], env, folder / 'first')
        wait_for(lambda: len(started(folder)) == 1, 'first start')
        second = launch(measured_run + ['env', 'A=1', guard_route, 'run', '--'] + fresh_shapes['intent'], env, folder / 'second')
        time.sleep(2.5)
        assert len(started(folder)) == 1 and second.poll() is None, ('second identical start was not held', started(folder))
        (folder / 'release').touch()
        finish(first); finish(second)

    def explicit_reuse():
        # F2: an explicit pipeline-start of the same arguments inside an admitted start queues too.
        folder, db, env = case('fix-f2-explicit', cores=3)
        env.update(PATH=str(stay_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off')
        both = 'no-mistakes axi run --intent goal & %s pipeline-start -- no-mistakes axi run --intent goal; wait' % (repo / 'bin/fm-cpu-pass.sh')
        outer = launch(cli + ['pipeline-start', '--', 'bash', '-c', both], env, folder / 'outer')
        wait_for(lambda: len(started(folder)) >= 1, 'first start')
        time.sleep(2.5)
        assert len(started(folder)) == 1, ('a second start inside one admission was not held', started(folder))
        (folder / 'release').touch()
        finish(outer)

    def second_descendant():
        # F2: two nested routes inside one admitted shell string: one consumes the grant, the other queues.
        folder, db, env = case('fix-f2-descendant', cores=3)
        env.update(PATH=str(stay_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off')
        # Identical arguments, so 5d51fa8be's inherited digest exempted both.
        two = '%s run -- no-mistakes axi run --intent goal & %s run -- no-mistakes axi run --intent goal; wait' % (guard_route, guard_route)
        outer = launch(measured_run + ['bash', '-c', two], env, folder / 'outer')
        wait_for(lambda: len(started(folder)) >= 1, 'first nested start')
        time.sleep(2.5)
        assert len(started(folder)) == 1, ('the second nested start did not queue', started(folder))
        (folder / 'release').touch()
        finish(outer)

    def data_words():
        # F3: words of data that spell a start are not a start; the memory route runs the command unchanged.
        folder, db, env = case('fix-f3', cores=3, running=1)
        child = launch(mem_guard + ['printf', '%s ', 'no-mistakes', 'axi', 'run', '--intent', 'goal'], env, folder / 'data')
        try:
            code = child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL); child.wait()
            raise AssertionError('printf of start words waited at pipeline-start')
        assert code == 0 and (folder / 'data.stdout').read_text() == 'no-mistakes axi run --intent goal ', (code, (folder / 'data.stderr').read_text())

    def visible_agent():
        # F4: a visible process in a ci:running run with no recorded pid may be an agent the daemon has not
        # recorded yet, so it reserves A, not its startup memory; the unseen CI waiter still reserves nothing.
        for label, launched_by_daemon, admitted in (('agent', True, False), ('no-agent', False, True)):
            folder, db, env = case('fix-f4-' + label, measured=True, available=int(8.5 * GIB))
            change(db, "INSERT INTO runs (id, status, repo_id) VALUES ('x', 'running', 'repo')")
            change(db, "INSERT INTO step_results (id, run_id, step_name, step_order, status, agent_pid) VALUES ('x-ci', 'x', 'ci', 1, 'running', NULL)")
            facts(folder, available=int(8.5 * GIB), runs=[('repo', 'x', GIB // 5, True)] if launched_by_daemon else [])
            child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm')], env, folder / 'f4')
            if admitted:
                finish(child)
                assert 'x:ci-waiting:' in (folder / 'f4.stderr').read_text(), (folder / 'f4.stderr').read_text()
            else:
                line = 'waiting: counted=1 projected=%d ' % (9 * GIB)
                until = time.monotonic() + 10
                while time.monotonic() < until and child.poll() is None and line not in (folder / 'f4.stderr').read_text():
                    time.sleep(0.05)
                running = child.poll() is None
                if running:
                    os.killpg(child.pid, signal.SIGTERM)
                child.wait()
                assert running and not (folder / 'm').exists(), ('a live agent at ci:running was read as idle',
                                                                 (folder / 'f4.stderr').read_text())

    def handoff_kill():
        # F5: the gate dies at its pid handoff to the watcher; no agent may run on without it.
        folder, db, env = gate_case('fix-f5')
        child, log = gate(folder, dict(env, CASE_KILL_BEFORE_PID='1'), 'x')
        child.wait(timeout=30)
        time.sleep(1.5)
        if (folder / 'x.agent').exists():
            pid = json.loads((folder / 'x.agent').read_text())['pid']
            if alive(pid):
                os.kill(pid, signal.SIGKILL)
                raise AssertionError('agent %d kept running after the gate died at the handoff' % pid)
        assert live_entries(folder, 'launch-*.lock') == 0

    def late_grant():
        # F6: a fit reached only after a wait past the hold bound (budget 3 s - p99 0.8 s = 2.2 s) refuses;
        # a fit after a short wait admits. The first queue sleep is held at a barrier while the lock is busy.
        # The bound covers the gate's own start and two decisions; a 0.2 s bound refused the timely case
        # on a host at load 55 of 18 cores, so the bound leaves room for that overhead.
        import fcntl
        for label, pause, admitted in (('late', 2.6, False), ('timely', 0.05, True)):
            folder, db, env = gate_case('fix-f6-' + label, timeout='3s', ci_ms=(800,))
            (folder / 'pool').mkdir(exist_ok=True)
            lock = os.open(str(folder / 'pool' / 'pipeline-start.lock'), os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            child, log = gate(folder, dict(env, CASE_SLEEP_BARRIER='1'), 'x', mode='exit-0')
            wait_for(lambda: (folder / 'sleeping').exists(), 'gate reached its first queue sleep')
            time.sleep(pause)
            fcntl.flock(lock, fcntl.LOCK_UN); os.close(lock)
            (folder / 'release-sleep').touch()
            code = child.wait(timeout=30)
            text = log.with_suffix('.stderr').read_text()
            if admitted:
                assert code == 0 and (folder / 'x.agent').exists(), (label, code, text)
            else:
                assert code == 75 and 'hold bound reached' in text and not (folder / 'x.agent').exists(), (label, code, text)

    def lock_contention_record():
        # F7: a hold on start-lock contention and the admission after it are both durably recorded.
        import fcntl
        folder, db, env = gate_case('fix-f7')
        (folder / 'pool').mkdir(exist_ok=True)
        lock = os.open(str(folder / 'pool' / 'pipeline-start.lock'), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        child, log = gate(folder, env, 'x', mode='exit-0')
        wait_for(lambda: 'launch-gate waiting: another start is registering' in log.with_suffix('.stderr').read_text(), 'contention notice')
        fcntl.flock(lock, fcntl.LOCK_UN); os.close(lock)
        assert child.wait(timeout=30) == 0
        queue = wakes(folder)
        assert 'held for capacity before its CI fix agent starts, waited ' in queue and 'another start is registering' in queue, queue
        assert 'run x (fm/x) admitted after ' in queue, queue

    for name, body in (('F1 nested expanded start', nested_expanded), ('F2 control: identical start from elsewhere', identical_sibling),
                       ('F2 explicit reuse inside one admission', explicit_reuse), ('F2 second nested descendant', second_descendant),
                       ('F3 start words as data', data_words), ('F4 visible process at ci:running with no recorded pid', visible_agent),
                       ('F5 gate killed at the pid handoff', handoff_kill), ('F6 grant after the hold bound', late_grant),
                       ('F7 start-lock contention record', lock_contention_record)):
        fix_case(name, body)
    (root / 'fixround.json').write_text(json.dumps(fixround, indent=2))
    print(json.dumps(dict(fixround=fixround)), flush=True)
    assert all(value == 'pass' for value in fixround.values()), fixround

    # Independent review of 5e36d93ab (R1-R4): each case fails on that head and passes on the fix.
    review = {}

    def review_case(name, body):
        try:
            body()
            review[name] = 'pass'
        except Exception as exc:  # a hang or a refused assertion fails this case only
            review[name] = 'FAIL: %s: %s' % (type(exc).__name__, str(exc)[:600])

    def idle_leftover():
        # A CI waiter is released to the bytes it holds only on positive proof that no agent lives: nothing of it is
        # visible, and its recorded agent pid is absent or dead (no time window). A visible tree keeps A whatever its
        # processes are named or parented and whatever its recorded pid; so does a live pid.
        held = GIB // 5
        ended = subprocess.Popen(['true'])
        ended.wait()
        old, recent = int(time.time()) - 3600, int(time.time())
        for label, comm, parent, pid, started, admitted in (
                ('no-pid-sleep-reparented', 'sleep', 1, None, old, False), ('no-pid-sleep-live-parent', 'sleep', 50, None, old, False),
                ('no-pid-node-agent', 'node', 50, None, old, False), ('no-pid-named-agent', '2.1.318', 50, None, old, False),
                ('no-pid-unknown-round', 'sleep', 1, None, None, False), ('live-pid', 'node', 50, os.getpid(), old, False),
                ('dead-pid-recent-visible', 'sleep', 1, ended.pid, recent, False),
                ('dead-pid-recent-invisible', None, None, ended.pid, recent, True),
                # A visible tree keeps A even when the recorded launcher pid is dead: a reparented agent can outlive it.
                ('dead-pid-visible-reparented-agent', 'node', 1, ended.pid, old, False), ('dead-pid-proof', None, None, ended.pid, old, True)):
            folder, db, env = case('review-f1-' + label, measured=True, available=int(8.5 * GIB))
            change(db, "INSERT INTO runs (id, status, repo_id) VALUES ('x', 'running', 'repo')")
            change(db, "INSERT INTO step_results (id, run_id, step_name, step_order, status, agent_pid, round_started_at) "
                       "VALUES ('x-ci', 'x', 'ci', 1, 'running', ?, ?)", (pid, started))
            facts(folder, available=int(8.5 * GIB), runs=[('repo', 'x', held)] if comm else [])
            if comm:
                rows = json.loads((folder / 'native' / 'processes.json').read_text())
                rows[-1].update(comm=comm, ppid=parent)
                (folder / 'native' / 'processes.json').write_text(json.dumps(rows))
            log = folder / 'r1.stderr'
            child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm')], env, folder / 'r1')
            if admitted:
                finish(child)
                assert 'admitted: counted=1 projected=%d ' % (8 * GIB) in log.read_text() and \
                    'holding_only=[x:ci-waiting:0:unseen]' in log.read_text(), (label, log.read_text())
            else:
                line = 'waiting: counted=1 projected=%d ' % (9 * GIB)
                until = time.monotonic() + 10
                while time.monotonic() < until and child.poll() is None and line not in log.read_text():
                    time.sleep(0.05)
                running = child.poll() is None
                if running:
                    os.killpg(child.pid, signal.SIGTERM)
                child.wait()
                assert running and line in log.read_text() and not (folder / 'm').exists(), (label, log.read_text())

    def gate_node_agent():
        # F1 at the launch gate: while run x shows a live node agent with no recorded pid, run y's fix agent
        # holds (x keeps A); the same with a named agent, and with x's launcher pid dead but its tree still visible;
        # with x proven agentless (nothing visible, a dead pid with an old round) y's agent starts.
        ended = subprocess.Popen(['true'])
        ended.wait()
        old = int(time.time()) - 3600
        for label, comm, pid, holds in (('node', 'node', None, True), ('named', '2.1.318', None, True),
                                        ('dead-pid-visible', 'node', ended.pid, True), ('proven', None, ended.pid, False)):
            folder, db, env = gate_case('review-f1-gate-' + label, available=int(8.5 * GIB),
                                        runs=[('x', 'ci', 'running', pid), ('y', 'ci', 'running', None)])
            change(db, "UPDATE step_results SET round_started_at = ?", (old,))
            facts(folder, available=int(8.5 * GIB), runs=[('repo', 'x', GIB // 5)] if comm else [])
            if comm:
                rows = json.loads((folder / 'native' / 'processes.json').read_text())
                rows[-1].update(comm=comm, ppid=50)
                (folder / 'native' / 'processes.json').write_text(json.dumps(rows))
            child, log = gate(folder, env, 'y')
            if holds:
                wait_for(lambda: 'x:active:%d' % GIB in (folder / 'gate-y.stderr').read_text(), label + ': x keeps A at the gate')
                time.sleep(0.5)
                assert not (folder / 'y.agent').exists() and child.poll() is None, (label, (folder / 'gate-y.stderr').read_text())
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=30)
            else:
                wait_for(lambda: (folder / 'y.agent').exists(), label + ': y starts once x is proven agentless')
                assert 'x:ci-waiting:0:unseen' in (folder / 'gate-y.stderr').read_text(), (folder / 'gate-y.stderr').read_text()
                (folder / 'y.release').touch()
                finish(child)

    def intercept_unplaceable():
        # F4: when the exec interception cannot be placed (its directory exists but is 0777), a command the parser
        # finds no start in is held as a start through both routes instead of running unjudged; a plain reattachment
        # still passes. Control: the private 0700 directory, where the xargs start waits and runs once admitted.
        import hashlib
        target = os.path.realpath(str(repo / 'bin' / 'fm-cpu-pass.sh'))
        name = 'fm-exec-intercept-%d-%s' % (os.getuid(), hashlib.sha256(target.encode()).hexdigest()[:12])
        fed = lambda route: ['bash', '-c', 'printf "input\\n" | "$@"', 'feed'] + route + ['xargs', '-I', '{}', 'no-mistakes', 'axi', 'run', '--intent', 'goal']
        for mode in (0o777, 0o700):
            for route_name, route in (('mem-guard', mem_guard), ('measured', measured_run)):
                label = '%s-%o' % (route_name, mode)
                folder, db, env = case('review-f4-' + label, cores=3, running=1)
                (folder / 'tmp' / name).mkdir(parents=True)
                os.chmod(folder / 'tmp' / name, mode)
                env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off', TMPDIR=str(folder / 'tmp'), CASE_NAME='xargs-' + label)
                child = launch(fed(route), env, folder / 'x')
                pending(folder, 1)
                time.sleep(0.3)
                assert child.poll() is None and not (folder / 'order').exists(), (label, (folder / 'x.stderr').read_text())
                if mode == 0o777:
                    assert 'cannot place the no-mistakes exec interception' in (folder / 'x.stderr').read_text(), (folder / 'x.stderr').read_text()
                change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
                finish(child)
                assert (folder / 'order').read_text().splitlines() == ['xargs-' + label], label
                assert (folder / 'x.stderr').read_text().count('pipeline-start admitted') == 1, (label, (folder / 'x.stderr').read_text())
                if mode == 0o777:
                    # A plain reattachment still passes at once while the interception cannot be placed.
                    change(db, "UPDATE runs SET ci_ready_at = 1 WHERE id = ?", ('xargs-' + label,))
                    reattach = launch(route + ['no-mistakes', 'axi', 'run'], dict(env, CASE_NAME='reattach'), folder / 'r')
                    assert reattach.wait(timeout=30) == 0 and 'pipeline-start admitted' not in (folder / 'r.stderr').read_text(), (folder / 'r.stderr').read_text()

    def wrapper_shapes():
        # R2: every wrapper form the parser models joins the queue once through each route; reattachment,
        # data and command -v do not. A form this host's binaries refuse is skipped and listed.
        line = 'no-mistakes axi run --intent goal'

        def accepted(command):
            return subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

        fresh = {
            'env-S': ['env', '-S', line], 'env-S-attached': ['env', '-S' + line], 'env-u-S': ['env', '-u', 'UNSET_X', '-S', line],
            'env-S-quoted': ['env', '-S', "no-mistakes axi run --intent 'a goal'"],
            'env-S-nested-route': ['env', '-S', 'bash %s run -- %s' % (repo / 'bin/fm-mem-guard.sh', line)],
            'env-C': ['env', '-C', '/', 'no-mistakes', 'axi', 'run', '--intent', 'goal'],
            'exec-a': ['bash', '-c', 'exec -a nm ' + line], 'nice-n': ['nice', '-n', '5'] + line.split(),
        }
        if accepted(['env', '--split-string=true']):
            fresh['env-split-string'] = ['env', '--split-string=' + line]
        if accepted(['env', '-P', '/bin', 'true']):
            fresh['env-P'] = ['env', '-P', str(nm_bin), 'no-mistakes', 'axi', 'run', '--intent', 'goal']
        if accepted(['time', '-o', os.devnull, 'true']):
            fresh['time-o'] = ['time', '-o', os.devnull] + line.split()
        if accepted(['stdbuf', '-oL', 'true']):
            fresh['stdbuf-oL'] = ['stdbuf', '-oL'] + line.split()
        others = {'env-S-reattach': ['env', '-S', 'no-mistakes axi run'],
                  'env-S-data': ['env', '-S', 'echo no-mistakes axi run --intent x']}
        if accepted(['command', '-v', 'true']):
            others['command-v'] = ['command', '-v', 'no-mistakes']
        import shlex
        for route_name, wrap in (('measured', lambda shape: measured_run + shape), ('mem-guard', lambda shape: mem_guard + shape),
                                 ('shell', lambda shape: ['bash', '-c', shlex.join(mem_guard + shape)])):
            for name, shape in list(fresh.items()) + list(others.items()):
                folder, db, env = case('review-r2-%s-%s' % (route_name, name), cores=3)
                env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], CASE_NAME=name, FM_DURATION_FILE='off')
                change(db, "INSERT INTO runs (id, status) VALUES ('existing', 'running')")
                change(db, "UPDATE runs SET ci_ready_at = 1 WHERE id = 'existing'")  # active but not counted
                child = launch(wrap(shape), env, folder / 'r2')
                code = child.wait(timeout=30)
                text = (folder / 'r2.stderr').read_text() + (folder / 'r2.stdout').read_text()
                assert code == 0, (route_name, name, code, text)
                with sqlite3.connect(db) as connection:
                    new_rows = connection.execute("SELECT count(*) FROM runs WHERE id = ?", (name,)).fetchone()[0]
                expected = 1 if name in fresh else 0
                assert text.count('pipeline-start admitted') == expected and new_rows == expected, (route_name, name, text)

    def split_held_order():
        # R2 held path and class order: env -S starts through all three routes wait behind a full pool, and
        # when it frees the machinery start (measured route) goes first, then the class-other starts in queue order.
        import shlex
        folder, db, env = case('review-r2-held-order', cores=3, running=1)
        env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off')
        split = ['env', '-S', 'no-mistakes axi run --intent goal']
        first = launch(mem_guard + split, dict(env, CASE_NAME='split-mem-guard-other'), folder / 'first')
        pending(folder, 1)
        second = launch(['bash', '-c', shlex.join(mem_guard + split)], dict(env, CASE_NAME='split-shell-other'), folder / 'second')
        pending(folder, 2)
        third = launch(measured_run + split, dict(env, CASE_NAME='split-measured-machinery'), folder / 'third')
        pending(folder, 3)
        assert not (folder / 'order').exists() and None is first.poll() is second.poll() is third.poll(), 'a split start ran past a full pool'
        order = []
        for name, child in (('split-measured-machinery', third), ('split-mem-guard-other', first), ('split-shell-other', second)):
            change(db, "UPDATE runs SET status='completed' WHERE id=?", (order[-1] if order else 'baseline-0',))
            finish(child)
            order.append(name)
            assert (folder / 'order').read_text().splitlines() == order, ((folder / 'order').read_text(), order)

    def xargs_interception():
        # D2 (delta review of fadebacc4): a fresh start the parser cannot see (xargs) meets the exec interception
        # through every route: all three wait behind a full pool and are admitted once each in class order;
        # through xargs a reattachment, a data command and an ordinary command are not queued.
        import shlex
        fed = lambda route: ['bash', '-c', 'printf "input\\n" | "$@"', 'feed'] + route + ['xargs', '-I', '{}', 'no-mistakes', 'axi', 'run', '--intent', 'goal']
        folder, db, env = case('review-d2-xargs-held-order', cores=3, running=1)
        env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off')
        first = launch(fed(mem_guard), dict(env, CASE_NAME='xargs-mem-guard-other'), folder / 'first')
        pending(folder, 1)
        second = launch(['bash', '-c', 'printf "input\\n" | ' + shlex.join(mem_guard + ['xargs', '-I', '{}', 'no-mistakes', 'axi', 'run', '--intent', 'goal'])],
                        dict(env, CASE_NAME='xargs-shell-other'), folder / 'second')
        pending(folder, 2)
        third = launch(fed(measured_run), dict(env, CASE_NAME='xargs-measured-machinery'), folder / 'third')
        pending(folder, 3)
        assert not (folder / 'order').exists() and None is first.poll() is second.poll() is third.poll(), 'an xargs start ran past a full pool'
        order = []
        for name, child, log in (('xargs-measured-machinery', third, 'third'), ('xargs-mem-guard-other', first, 'first'),
                                 ('xargs-shell-other', second, 'second')):
            change(db, "UPDATE runs SET status='completed' WHERE id=?", (order[-1] if order else 'baseline-0',))
            finish(child)
            order.append(name)
            assert (folder / 'order').read_text().splitlines() == order, ((folder / 'order').read_text(), order)
            assert (folder / (log + '.stderr')).read_text().count('pipeline-start admitted') == 1, (name, (folder / (log + '.stderr')).read_text())
        for name, words in (('reattach', ['no-mistakes', 'axi', 'run']), ('data', ['echo', 'no-mistakes', 'axi', 'run', '--intent', 'x']),
                            ('ordinary', ['true'])):
            for route_name, route in (('mem-guard', mem_guard), ('measured', measured_run)):
                folder, db, env = case('review-d2-xargs-%s-%s' % (name, route_name), cores=3)
                env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off', CASE_NAME=name)
                change(db, "INSERT INTO runs (id, status) VALUES ('existing', 'running')")
                change(db, "UPDATE runs SET ci_ready_at = 1 WHERE id = 'existing'")  # active but not counted
                child = launch(['bash', '-c', 'printf "input\\n" | "$@"', 'feed'] + route + ['xargs', '-I', '{}'] + words, env, folder / 'x')
                code = child.wait(timeout=30)
                text = (folder / 'x.stderr').read_text() + (folder / 'x.stdout').read_text()
                with sqlite3.connect(db) as connection:
                    new_rows = connection.execute("SELECT count(*) FROM runs WHERE id = ?", (name,)).fetchone()[0]
                assert code == 0 and 'pipeline-start admitted' not in text and new_rows == 0, (name, route_name, code, text)
                assert not list((folder / 'pool').glob('pipeline-waiter-*.lock')), (name, route_name)

    def any_key_interception():
        # bin/fm-duration.py run routes a fresh start by the command's content, whatever the measurement key:
        # the reviewer's xargs shape under the key task.pipeline waits behind a full pool and is admitted once;
        # under that key a reattachment through xargs and an ordinary command are not queued.
        task_run = measured_run[:-2] + ['task.pipeline', '--']
        folder, db, env = case('review-any-key-held', cores=3, running=1)
        env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off', CASE_NAME='xargs-task-key')
        child = launch(task_run + ['sh', '-c', "printf 'x\\n' | xargs -n1 no-mistakes axi run --intent goal"], env, folder / 'x')
        pending(folder, 1)
        assert not (folder / 'order').exists() and child.poll() is None, 'a fresh start under a non-pipeline key ran past a full pool'
        change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
        finish(child)
        assert (folder / 'order').read_text().splitlines() == ['xargs-task-key'], (folder / 'order').read_text()
        assert (folder / 'x.stderr').read_text().count('pipeline-start admitted') == 1, (folder / 'x.stderr').read_text()
        for name, words in (('reattach', ['sh', '-c', "printf 'x\\n' | xargs -I {} no-mistakes axi run"]), ('ordinary', ['true'])):
            folder, db, env = case('review-any-key-%s' % name, cores=3)
            env.update(PATH=str(nm_bin) + os.pathsep + env['PATH'], FM_DURATION_FILE='off', CASE_NAME=name)
            change(db, "INSERT INTO runs (id, status) VALUES ('existing', 'running')")
            change(db, "UPDATE runs SET ci_ready_at = 1 WHERE id = 'existing'")  # active but not counted
            child = launch(task_run + words, env, folder / 'x')
            code = child.wait(timeout=30)
            text = (folder / 'x.stderr').read_text() + (folder / 'x.stdout').read_text()
            assert code == 0 and 'pipeline-start admitted' not in text, (name, code, text)
            assert not list((folder / 'pool').glob('pipeline-waiter-*.lock')), name

    def nest_client(folder, env):
        # A fake no-mistakes client: it logs "<cwd name> :: <args>"; an intent beginning reg registers a running run,
        # one beginning hold waits for folder/release-<intent> and then exits without registering, any other exits
        # without registering.
        nest = folder / 'nestbin'
        nest.mkdir()
        (nest / 'no-mistakes').write_text('#!' + python + '\n' + """import os, pathlib, sqlite3, sys, time
folder = pathlib.Path(os.environ['CASE_FOLDER']); args = sys.argv[1:]
intent = args[args.index('--intent') + 1] if '--intent' in args else ''
with (folder / 'calls.log').open('a') as out: out.write('%s :: %s\\n' % (os.path.basename(os.getcwd()), intent))
(folder / ('pid-' + intent)).write_text(str(os.getpid()))
if intent.startswith('hold'):
    while not (folder / ('release-' + intent)).exists(): time.sleep(0.05)
if intent.startswith('reg'):
    with sqlite3.connect(folder / 'state.sqlite') as db:
        db.execute("INSERT INTO runs (id, status, repo_id, branch, intent, created_at) VALUES (?, 'running', 'repo', 'main', ?, ?)",
                   ('run-%s-%d' % (intent, os.getpid()), intent, int(time.time())))
""")
        (nest / 'no-mistakes').chmod(0o700)
        env.update(PATH=str(nest) + os.pathsep + env['PATH'], FM_DURATION_FILE='off')
        return nest / 'no-mistakes'

    def calls(folder):
        log = folder / 'calls.log'
        return [line.split(' :: ')[1] for line in log.read_text().splitlines()] if log.exists() else []

    def ended(child, folder, what, timeout=30):
        try:
            return child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL); child.wait()
            raise AssertionError('%s hung: calls %r' % (what, calls(folder)))

    def nested_second_client():
        # A second fresh client inside an admitted command is admitted on its own, whether the first client went
        # through the interception or by its absolute path, registered a run or not; nothing hangs.
        # With 3 cores the count fallback admits one run: a first client called by its absolute path that ends
        # without a run must not leave its enclosing start counted against the second (no hang); a first that did
        # create a run releases its pending start, so a second with the same arguments is admitted on its own.
        # A first client with the same arguments that created no run leaves its admission to the second: one
        # admission for the one start that ran.
        for label, cores, line, admissions in (
                ('path-unregistered', 18, 'no-mistakes axi run --intent a; no-mistakes axi run --intent b', 2),
                ('abs-first-unregistered', 18, '{abs} axi run --intent a; no-mistakes axi run --intent b', 2),
                ('tight-abs-first-unregistered', 3, '{abs} axi run --intent a; no-mistakes axi run --intent b', 2),
                ('abs-first-same-args-registered', 18, '{abs} axi run --intent reg-x; no-mistakes axi run --intent reg-x', 2),
                ('abs-first-same-args-unregistered', 18, '{abs} axi run --intent x; no-mistakes axi run --intent x', 1),
                ('both-register', 18, 'no-mistakes axi run --intent reg-a; no-mistakes axi run --intent reg-b', 2),
                ('reviewer-two-repositories', 18, 'cd {r1} && no-mistakes axi run --intent first; cd {r2} && no-mistakes axi run --intent second', 2)):
            folder, db, env = case('nested-' + label, cores=cores)
            client = nest_client(folder, env)
            for repository in ('repo1', 'repo2'):
                (folder / repository).mkdir()
            # The command runs in a registered checkout, so a client's own run row is its start's own (P5.lock).
            child = launch(mem_guard + ['bash', '-c', line.format(abs=client, r1=folder / 'repo1', r2=folder / 'repo2')], env, folder / 'x',
                           cwd=registered_checkout(folder, db))
            code = ended(child, folder, label)
            text = (folder / 'x.stderr').read_text()
            assert code == 0 and len(calls(folder)) == 2, (label, code, calls(folder), text)
            assert text.count('pipeline-start admitted') == admissions, (label, text)
            assert not list((folder / 'pool').glob('pending-*.lock')), label

    def killed_client():
        # A claiming client killed before its run appears ends its pending start (its client exited), so a start in that
        # gap is decided without it (the stated residual); once the daemon writes the run's row, it is counted.
        folder, db, env = case('nested-killed-client', cores=3)
        nest_client(folder, env)
        child = launch(mem_guard + ['bash', '-c', 'no-mistakes axi run --intent hold-k; sleep 60'], env, folder / 'x')
        wait_for(lambda: (folder / 'pid-hold-k').exists(), 'the client runs')
        os.kill(int((folder / 'pid-hold-k').read_text()), signal.SIGKILL)
        gap = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'gap')], env, folder / 'gap')
        finish(gap)
        assert (folder / 'gap').exists(), 'a start in the gap was not admitted'
        change(db, "INSERT INTO runs (id, status) VALUES ('late-run', 'running')")
        later = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later')
        pending(folder, 1)
        wait_for(lambda: 'waiting: counted=1 ' in (folder / 'later.stderr').read_text(), 'the late run is counted')
        assert not (folder / 'later').exists(), (folder / 'later.stderr').read_text()
        change(db, "UPDATE runs SET status = 'completed' WHERE id = 'late-run'")
        finish(later)
        os.killpg(child.pid, signal.SIGKILL); child.wait()

    def nested_enclosing_counted():
        # The enclosing start's unclaimed reservation keeps counting while a process in its command runs the
        # admitted client, and when the process table cannot be read: with 3 cores (one run) the second waits.
        for label, line, extra in (('client-running', '{abs} axi run --intent hold-a & sleep 0.3; no-mistakes axi run --intent b; wait', {}),
                                   ('table-unreadable', '{abs} axi run --intent a; no-mistakes axi run --intent b', {'CASE_PROCESS_TABLE_UNREADABLE': '1'})):
            folder, db, env = case('nested-enclosing-' + label, cores=3)
            client = nest_client(folder, env)
            env.update(extra)
            child = launch(mem_guard + ['bash', '-c', line.format(abs=client)], env, folder / 'x')
            pending(folder, 1)
            time.sleep(2)
            assert 'b' not in calls(folder) and child.poll() is None, (label, 'the second ran without the enclosing start counted', calls(folder))
            if label == 'client-running':
                (folder / 'release-hold-a').touch()
                assert ended(child, folder, label) == 0
                assert sorted(calls(folder)) == ['b', 'hold-a'], calls(folder)
                assert (folder / 'x.stderr').read_text().count('pipeline-start admitted') == 2, (folder / 'x.stderr').read_text()
            else:
                os.killpg(child.pid, signal.SIGKILL); child.wait()

    def nested_class_order():
        # A higher-class start queued elsewhere while a nested second client waits: no hang, and class order holds.
        import fcntl
        folder, db, env = case('nested-class-order', cores=18)
        client = nest_client(folder, env)
        go = folder / 'go'
        line = '{abs} axi run --intent first; while [ ! -e {go} ]; do sleep 0.05; done; no-mistakes axi run --intent second'
        outer = launch(mem_guard + ['bash', '-c', line.format(abs=client, go=go)], env, folder / 'outer')
        wait_for(lambda: calls(folder) == ['first'], 'the first client ran')
        lock = os.open(str(folder / 'pool' / 'pipeline-start.lock'), os.O_RDWR | os.O_CREAT, 0o600)
        until = time.monotonic() + 15
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= until:
                    os.close(lock); go.touch()
                    raise AssertionError('the admitted command still holds the start lock after its first client ended')
                time.sleep(0.05)
        try:
            elsewhere = launch(cli + ['pipeline-start', '--priority', 'merge-train', '--', str(client), 'axi', 'run', '--intent', 'elsewhere'],
                               env, folder / 'elsewhere')
            pending(folder, 1)
            go.touch()
            pending(folder, 2)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN); os.close(lock)
        assert ended(elsewhere, folder, 'the elsewhere start') == 0
        assert ended(outer, folder, 'the outer command') == 0
        assert calls(folder) == ['first', 'elsewhere', 'second'], calls(folder)

    def nested_parallel_counted():
        # Two nested clients started together: the second is decided with the first, admitted and not registered,
        # counted at its full R. R = 3 GiB and S = 8 GiB: at 10 GiB available the second (3 + 8 = 11) waits until
        # the first client ends, at 12 GiB it is admitted while the first still runs.
        for available, admitted in ((10 * GIB, False), (12 * GIB, True)):
            folder, db, env = case('nested-parallel-%d' % (available // GIB), cores=3, measured=True, available=available)
            nest_client(folder, env)
            line = 'no-mistakes axi run --intent hold-a & no-mistakes axi run --intent b; wait'
            child = launch(mem_guard + ['bash', '-c', line], env, folder / 'x')
            wait_for(lambda: 'hold-a' in calls(folder), 'the first client runs')
            if admitted:
                wait_for(lambda: 'b' in calls(folder), 'the second client admitted with the first counted')
            else:
                wait_for(lambda: 'start-1:pending:%d:unseen' % (3 * GIB) in (folder / 'x.stderr').read_text(), 'the second waits with the first counted')
                time.sleep(1)
                assert 'b' not in calls(folder), ('the second ran without the first counted', calls(folder))
            (folder / 'release-hold-a').touch()
            assert ended(child, folder, 'the parallel pair') == 0
            assert sorted(calls(folder)) == ['b', 'hold-a'], calls(folder)
            assert (folder / 'x.stderr').read_text().count('pipeline-start admitted') == 2, (folder / 'x.stderr').read_text()

    def nested_unplaceable():
        # When the interception cannot be placed (a 0777 directory), a shell with two fresh clients is held as one
        # start with the printed reason: it waits behind a full pool and runs once admitted.
        folder, db, env = case('nested-unplaceable', cores=3, running=1)
        nest_client(folder, env)
        tmp = folder / 'tmp'
        tmp.mkdir()
        digest = hashlib.sha256(os.path.realpath(str(repo / 'bin' / 'fm-cpu-pass.sh')).encode()).hexdigest()[:12]
        unsafe = tmp / ('fm-exec-intercept-%d-%s' % (os.getuid(), digest))
        unsafe.mkdir(); unsafe.chmod(0o777)
        env.update(TMPDIR=str(tmp))
        child = launch(mem_guard + ['bash', '-c', 'no-mistakes axi run --intent a; no-mistakes axi run --intent b'], env, folder / 'x')
        pending(folder, 1)
        assert calls(folder) == [] and child.poll() is None, 'a shell ran past a full pool with no interception'
        assert 'cannot place the no-mistakes exec interception' in (folder / 'x.stderr').read_text()
        change(db, "UPDATE runs SET status='completed' WHERE id='baseline-0'")
        assert ended(child, folder, 'the held shell') == 0
        assert calls(folder) == ['a', 'b'], calls(folder)

    def wake_holder(env, folder):
        held, release = folder / 'held', folder / 'release-queue'
        holder = subprocess.Popen(['bash', '-c', '. "$1" && fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" && touch "$2" && '
                                   'while [ ! -e "$3" ]; do sleep 0.05; done; fm_lock_release "$FM_WAKE_QUEUE_LOCK"',
                                   'bash', str(repo / 'bin/fm-wake-lib.sh'), str(held), str(release)],
                                  env=env, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        children.append(holder)
        wait_for(lambda: held.exists(), 'wake-queue lock held')
        return holder, release

    def refuse(env, folder, extra=None):
        gate = subprocess.run(['bash', str(repo / 'bin/fm-cpu-pass.sh'), 'launch-gate', '--', '/bin/true'], env=dict(env, **(extra or {})),
                              cwd=str(folder), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        assert gate.returncode == 75 and 'unmapped worktree' in gate.stderr, gate.stderr
        return gate

    def spills(folder):
        return [p.read_text() for p in sorted((folder / 'fmhome' / 'state').glob('.wake-spill.[0-9]*'))]

    def watcher_collision():
        # R3: the watcher's real fm_wake_pending_settle takes the gate's spill number first; both records survive.
        # The shim fires on whichever command publishes a spill (mv before the fix, ln after), so it tests the outcome.
        folder, db, env = case('review-r3-collision', measured=True)
        env['HOME'] = str(folder)
        shim = folder / 'race-bin'
        shim.mkdir()
        script = ('#!/bin/sh\nreal=/bin/$(basename "$0")\nfor last do :; done\ncase "$last" in\n  */.wake-spill.[0-9]*)\n'
                  '    if [ -z "${IN_WATCHER:-}" ] && mkdir "$CASE_FOLDER/first-publication" 2>/dev/null; then\n'
                  '      IN_WATCHER=1 bash -c \'. "$1" && FM_WAKE_PENDING_KIND=check FM_WAKE_PENDING_KEY=watcher-test '
                  'FM_WAKE_PENDING_PAYLOAD=watcher-test-event && fm_wake_pending_settle\' bash "$CASE_WAKE_LIB" || touch "$CASE_FOLDER/watcher-failed"\n'
                  '    fi;;\nesac\nexec "$real" "$@"\n')
        for name in ('mv', 'ln'):
            (shim / name).write_text(script)
            (shim / name).chmod(0o700)
        holder, release = wake_holder(env, folder)
        refuse(env, folder, dict(PATH=str(shim) + os.pathsep + env['PATH'], CASE_WAKE_LIB=str(repo / 'bin/fm-wake-lib.sh')))
        release.touch()
        holder.wait(timeout=30)
        found = spills(folder)
        assert (folder / 'first-publication').exists() and not (folder / 'watcher-failed').exists(), 'the collision never happened'
        assert len(found) == 2 and sum('launch-gate-unmapped' in s for s in found) == 1 and sum('watcher-test-event' in s for s in found) == 1, found

    def collision_then_replay():
        # D3 (delta review of fadebacc4): the watcher takes the gate's spill number, the gate's link fails, and the
        # queue is freed and replayed (removing that spill) before the failed link returns; the gate row still survives.
        folder, db, env = case('review-d3-collision-replay', measured=True)
        env['HOME'] = str(folder)
        shim = folder / 'race-bin'
        shim.mkdir()
        (shim / 'ln').write_text(r"""#!/bin/bash
for last do :; done
case "$last" in
  */.wake-spill.[0-9]*)
    if [ -z "${IN_WATCHER:-}" ] && mkdir "$CASE_FOLDER/first-publication" 2>/dev/null; then
      IN_WATCHER=1 bash -c '. "$1" && FM_WAKE_PENDING_KIND=check FM_WAKE_PENDING_KEY=watcher-test FM_WAKE_PENDING_PAYLOAD=watcher-test-event && fm_wake_pending_settle' bash "$CASE_WAKE_LIB" || exit 91
      /bin/ln "$@"
      result=$?
      touch "$CASE_FOLDER/release-queue"
      bash -c '. "$1" && fm_wake_spill_replay' bash "$CASE_WAKE_LIB" || exit 92
      touch "$CASE_FOLDER/replayed"
      exit "$result"
    fi;;
esac
exec /bin/ln "$@"
""")
        (shim / 'ln').chmod(0o700)
        holder, release = wake_holder(env, folder)
        gate = refuse(env, folder, dict(PATH=str(shim) + os.pathsep + env['PATH'], CASE_WAKE_LIB=str(repo / 'bin/fm-wake-lib.sh')))
        holder.wait(timeout=30)
        assert (folder / 'replayed').exists(), 'the collision and replay never happened'
        kept = wakes(folder) + ''.join(spills(folder))
        assert 'watcher-test-event' in kept and 'launch-gate-unmapped' in kept and 'durable line not recorded' not in gate.stderr, (kept, gate.stderr)

    def spill_controls():
        # R3 controls: a free queue lock appends at once; a busy one spills one file; the next append replays it first.
        folder, db, env = case('review-r3-free', measured=True)
        env['HOME'] = str(folder)
        refuse(env, folder)
        assert 'launch-gate-unmapped' in wakes(folder) and not spills(folder), (wakes(folder), spills(folder))
        folder, db, env = case('review-r3-spill', measured=True)
        env['HOME'] = str(folder)
        holder, release = wake_holder(env, folder)
        refuse(env, folder)
        found = spills(folder)
        assert len(found) == 1 and 'launch-gate-unmapped' in found[0] and 'launch-gate-unmapped' not in wakes(folder), found
        release.touch()
        holder.wait(timeout=30)
        subprocess.run(['bash', '-c', '. "$1" && fm_wake_append check later-key later-event', 'bash', str(repo / 'bin/fm-wake-lib.sh')],
                       env=env, check=True, timeout=60)
        queue = wakes(folder)
        assert not spills(folder) and 0 <= queue.index('launch-gate-unmapped') < queue.index('later-event'), queue

    def short_hold_record():
        # R4: start-lock contention however short is a hold: the hold and the admission after it are recorded,
        # each with run, reason and waited time; an admission at the first decision records nothing.
        import fcntl
        import re
        for label, hold in (('short', 0.15), ('none', None)):
            folder, db, env = gate_case('review-r4-' + label)
            (folder / 'pool').mkdir(exist_ok=True)
            lock = None
            if hold is not None:
                lock = os.open(str(folder / 'pool' / 'pipeline-start.lock'), os.O_RDWR | os.O_CREAT, 0o600)
                fcntl.flock(lock, fcntl.LOCK_EX)
            child, log = gate(folder, env, 'x', mode='exit-0')
            if lock is not None:
                wait_for(lambda: list((folder / 'pool').glob('pipeline-waiter-*.lock')), 'the gate queued')
                time.sleep(hold)
                fcntl.flock(lock, fcntl.LOCK_UN); os.close(lock)
            assert child.wait(timeout=30) == 0, log.with_suffix('.stderr').read_text()
            queue = wakes(folder)
            if hold is None:
                assert 'launch-gate' not in queue, queue
            else:
                assert re.search(r'run x \(fm/x\) held for capacity before its CI fix agent starts, waited \d+\.\d\ds so far: '
                                 r'another start is registering', queue), queue
                assert re.search(r'run x \(fm/x\) admitted after \d+\.\d\ds held: ', queue), queue

    for name, body in (('F1 a CI waiter is released only on proof no agent lives', idle_leftover),
                       ('F1 a live agent with no recorded pid holds the launch gate', gate_node_agent),
                       ('F4 an unplaceable interception holds the start', intercept_unplaceable), ('R2 wrapper forms join the queue once', wrapper_shapes),
                       ('R2 env -S starts wait behind a full pool in class order', split_held_order),
                       ('D2 an xargs start meets the exec interception', xargs_interception),
                       ('a fresh start under any measurement key meets the interception', any_key_interception),
                       ('a second fresh client inside an admitted command is admitted on its own', nested_second_client),
                       ('an enclosing start counts while its client runs or the process table is unreadable', nested_enclosing_counted),
                       ('a killed client ends its pending start; its late run is counted once its row exists', killed_client),
                       ('a nested second client keeps class order behind a start queued elsewhere', nested_class_order),
                       ('two nested clients started together are each counted', nested_parallel_counted),
                       ('an unplaceable interception holds a shell of two starts as one start', nested_unplaceable),
                       ('R3 gate and watcher spills collide', watcher_collision),
                       ('D3 a collision replayed before the failed link returns', collision_then_replay), ('R3 controls: free lock, lone spill, replay', spill_controls),
                       ('R4 a short start-lock hold is recorded', short_hold_record)):
        review_case(name, body)
    (root / 'review-5e36d93a.json').write_text(json.dumps(review, indent=2))
    print(json.dumps(dict(review=review)), flush=True)
    assert all(value == 'pass' for value in review.values()), review


    # Contract revision 28 admission cases. Every case runs; failures are collected and reported together.
    r28 = {}

    def r28_case(name, body):
        try:
            body()
            r28[name] = 'pass'
        except Exception as exc:  # noqa: BLE001 - every case's failure is reported
            r28[name] = 'FAIL: %s: %s' % (type(exc).__name__, str(exc)[:1500])

    def no_term_counts_r():
        # No readings record of this host for A is not a fallback trigger (Main 4930 Q5): the fit runs with every
        # visible active run counted at R, as the base counted every run, so a visible 0.2 GiB run reserves 3 GiB.
        for name, record in (('no-readings', lambda f: calibrate(f, active=None)),
                             ('readings-other-host', lambda f: calibrate(f, active=None) or readings(f, host='other-host'))):
            folder, db, env = case('no-term-' + name, running=0)
            record(folder)
            change(db, "INSERT INTO runs (id, status, repo_id) VALUES ('v', 'running', 'repo')")
            change(db, "INSERT INTO step_results (id, run_id, step_name, step_order, status) VALUES ('v-s', 'v', 'review', 1, 'fixing')")
            facts(folder, available=40 * GIB, runs=[('repo', 'v', GIB // 5)])
            finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm')], env, folder / 'f'))
            text = (folder / 'f.stderr').read_text() if (folder / 'f.stderr').exists() else ''
            assert (folder / 'm').exists(), (name, text)
            folder, db, env = case('no-term-wait-' + name, running=0, available=11 * GIB)
            record(folder)
            change(db, "INSERT INTO runs (id, status, repo_id) VALUES ('v', 'running', 'repo')")
            change(db, "INSERT INTO step_results (id, run_id, step_name, step_order, status) VALUES ('v-s', 'v', 'review', 1, 'fixing')")
            facts(folder, available=11 * GIB, runs=[('repo', 'v', GIB // 5)])
            # 3 + 8 = 11 GiB fits 11 + 0.2; with one page less available the start waits and names the R term.
            facts(folder, available=11 * GIB - 16384 - GIB // 5, runs=[('repo', 'v', GIB // 5)])
            child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm')], env, folder / 'f')
            wait_for(lambda: 'v:active:%d' % (3 * GIB) in (folder / 'f.stderr').read_text(), name + ': visible run at R')
            text = (folder / 'f.stderr').read_text()
            assert 'basis=fallback' not in text and 'active_term=%d' % (3 * GIB) in text and child.poll() is None, (name, text)
            facts(folder, available=40 * GIB)
            finish(child)

    def cancel_before_command():
        # P5.preempt.cancel: a SIGINT or SIGTERM that lands after admission but before COMMAND begins (just before or just
        # after its child is forked) cancels the start: COMMAND never runs, the start exits 128+n, its pending
        # reservation ends, and a later fitting start is admitted and runs.
        for when, name, code in (('before', 'INT', 130), ('after', 'INT', 130), ('before', 'TERM', 143), ('after', 'TERM', 143)):
            folder, db, env = case('cancel-at-spawn-%s-%s' % (when, name.lower()), measured=True, available=10 * GIB)
            finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'cancelled')],
                          dict(env, CASE_SIGNAL_AT_SPAWN='%s:%s' % (when, name)), folder / 'cancelled'), code)
            assert not (folder / 'cancelled').exists() and not live_entries(folder, 'pending-*.lock'), (when, name)
            # 10 GiB holds one start (S = 8) beside nothing; a leftover pending reservation (3 + 8 = 11) would hold this one.
            finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later'))
            assert (folder / 'later').exists(), (when, name)

    def bound_repo(folder, db, env):
        """A registered git checkout on branch main, and a fake client that registers its own run from there.

        The fake client logs its pid as pid-<intent>; an intent beginning hold waits for release-<intent>, one beginning
        reg inserts a running row for its own run (repo, branch, intent) and then waits for release-<intent>.
        """
        checkout = folder / 'checkout'
        subprocess.run(['git', 'init', '-q', '-b', 'main', str(checkout)], check=True, stdin=subprocess.DEVNULL)
        change(db, "INSERT INTO repos (id, working_path) VALUES ('repo', ?)", (str(checkout),))
        nest = folder / 'bindbin'
        nest.mkdir()
        (nest / 'no-mistakes').write_text('#!' + python + '\n' + """import os, pathlib, sqlite3, sys, time
folder = pathlib.Path(os.environ['CASE_FOLDER']); args = sys.argv[1:]
intent = args[args.index('--intent') + 1] if '--intent' in args else ''
(folder / ('pid-' + intent)).write_text(str(os.getpid()))
if intent.startswith('reg'):
    with sqlite3.connect(folder / 'state.sqlite') as db:
        db.execute("INSERT INTO runs (id, status, repo_id, branch, intent, created_at) VALUES (?, 'running', 'repo', 'main', ?, ?)",
                   ('run-' + intent, intent, int(time.time())))
while not (folder / ('release-' + intent)).exists(): time.sleep(0.05)
""")
        (nest / 'no-mistakes').chmod(0o700)
        env.update(PATH=str(nest) + os.pathsep + env['PATH'], FM_DURATION_FILE='off')
        return checkout

    def row(db, run, intent, branch='main', repo_id='repo'):
        change(db, "INSERT INTO runs (id, status, repo_id, branch, intent, created_at) VALUES (?, 'running', ?, ?, ?, ?)",
               (run, repo_id, branch, intent, int(time.time())))

    def launch_in(command, env, log, cwd):
        out, err = open(str(log) + '.stdout', 'w'), open(str(log) + '.stderr', 'w')
        child = subprocess.Popen(command, env=env, stdout=out, stderr=err, start_new_session=True, cwd=str(cwd))
        out.close(); err.close()
        children.append(child)
        records.append(dict(command=command, stdout=str(log) + '.stdout', stderr=str(log) + '.stderr'))
        return child

    def own_row_binding():
        # P5.lock: a pending reservation is ended by its own run's row only. With 6 cores (limit 2), a live, unregistered
        # start A and a stranger's running row (same repository and branch, another intent) hold a probe start; A's own
        # row ends A, so once the stranger's run
        # ends the probe is admitted by itself while A's client is still alive.
        folder, db, env = case('bind-own-row', cores=6)
        checkout = bound_repo(folder, db, env)
        a = launch_in(cli + ['pipeline-start', '--', 'no-mistakes', 'axi', 'run', '--intent', 'hold-a'], env, folder / 'a', checkout)
        wait_for(lambda: (folder / 'pid-hold-a').exists(), 'A runs')
        row(db, 'stranger', 'something else')
        probe = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'probe')], env, folder / 'probe')
        wait_for(lambda: 'waiting: counted=1 limit=2 basis=fallback launched=0 pending=1' in (folder / 'probe.stderr').read_text(),
                 'a stranger row of the same repository and branch ends no reservation')
        assert not (folder / 'probe').exists()
        row(db, 'own', 'hold-a')
        time.sleep(1.0)
        assert not (folder / 'probe').exists(), 'two counted runs (the stranger, A own row) hold the probe'
        change(db, "UPDATE runs SET status = 'completed' WHERE id = 'stranger'")
        finish(probe)
        assert a.poll() is None, 'A is still alive: its own row ended its reservation'
        (folder / 'release-hold-a').touch()
        finish(a)

    def named_collision():
        # P5.lock's named collision (R = 3 GiB, S = 8 GiB, budget 12 GiB): B claims through the interception and is killed
        # after its push, so its reservation ends (K7); A is admitted and has not claimed; B's delayed row appears. The next
        # decision counts B's row and A: 3 + 3 + 8 = 14 against 12, and waits. After A's own row appears and A's run ends,
        # a start that fits is admitted by itself.
        folder, db, env = case('bind-named-collision', measured=True, available=12 * GIB)
        checkout = bound_repo(folder, db, env)
        b = launch_in(mem_guard + ['bash', '-c', 'no-mistakes axi run --intent hold-b; sleep 60'], env, folder / 'b', checkout)
        wait_for(lambda: (folder / 'pid-hold-b').exists(), 'B claims and runs')
        os.kill(int((folder / 'pid-hold-b').read_text()), signal.SIGKILL)
        a = launch_in(cli + ['pipeline-start', '--', 'bash', '-c', 'sleep 30; no-mistakes axi run --intent hold-a'], env, folder / 'a', checkout)
        wait_for(lambda: 'pipeline-start admitted' in (folder / 'a.stderr').read_text(), 'A admitted, not claimed')
        row(db, 'run-hold-b', 'hold-b')
        probe = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'probe')], env, folder / 'probe')
        wait_for(lambda: 'projected=%d ' % (14 * GIB) in (folder / 'probe.stderr').read_text(), 'B row and A both counted')
        assert not (folder / 'probe').exists(), (folder / 'probe.stderr').read_text()
        row(db, 'run-hold-a', 'hold-a')
        os.killpg(a.pid, signal.SIGKILL); a.wait()
        change(db, "UPDATE runs SET status = 'completed' WHERE id IN ('run-hold-a', 'run-hold-b')")
        finish(probe)
        os.killpg(b.pid, signal.SIGKILL); b.wait()

    def base_rule_from_line(text):
        """The base rule's decision recomputed from one admission or waiting line alone (P1, LIVE(a)).

        Base 012b72f34: need = (counted + 1) x R + S against budget = available + the sum of min(R, resident
        memory) over the counted runs; admitted when need fits or nothing is counted.
        """
        line = [l for l in text.splitlines() if 'counted_runs=[' in l][-1]
        value = lambda key: int(re.search(r'\b%s=(\d+)' % key, line).group(1))  # noqa: E731
        runs = re.search(r'counted_runs=\[([^\]]*)\]', line).group(1)
        rss = [] if runs == 'none' else [int(item.rsplit(':', 1)[1]) for item in runs.split(',')]
        reservation, slack, available = value('reservation'), value('slack'), value('available')
        need = (len(rss) + 1) * reservation + slack
        budget = available + sum(min(reservation, size) for size in rss)
        return dict(counted=len(rss), need=need, budget=budget, admit=need <= budget or not rss)

    def p1_old_rule_recomputed():
        # P1: the line names each counted run and its resident memory, so the old rule's decision is recomputable from
        # it alone; on case (a) it waits (the base's own decision on that fixture), while the new rule admits.
        folder, db, env = counted_case('p1-recompute', 32.82 * GIB // 16384 * 16384, live,
                                       waiting_ci=['ci-361', 'ci-367', 'ci-369', 'ci-3609'])
        finish(launch(cli + ['pipeline-start', '--priority', 'machinery', '--', 'sh', '-c', 'exit 3'], env, folder / 'p1a'), 3)
        text = (folder / 'p1a.stderr').read_text()
        old = base_rule_from_line(text)
        assert 'admitted: counted=11 ' in text and old['counted'] == 11 and not old['admit'], (old, text)
        named = re.search(r'counted_runs=\[([^\]]*)\]', text).group(1).split(',')
        assert 'ci-361:0' in named and 'lint:%d' % int(2.22 * GIB) in named and len(named) == 11, text

    for name, body in (('P5.errors.fallback no A counts visible runs at R', no_term_counts_r),
                       ('P5.preempt.cancel a cancel before COMMAND begins', cancel_before_command),
                       ('P5.lock a reservation ends by its own row only', own_row_binding),
                       ('P5.lock the named collision', named_collision),
                       ('P1 the line recomputes the base rule', p1_old_rule_recomputed)):
        r28_case(name, body)
    (root / 'r28-admission.json').write_text(json.dumps(r28, indent=2))
    print(json.dumps(dict(r28=r28)), flush=True)
    assert all(value == 'pass' for value in r28.values()), r28

    print(json.dumps(dict(result='pass', spacing=dict(limit=SPACING_LIMIT, burst_gaps=[round(g, 3) for g in burst_gaps], burst_median=round(statistics.median(burst_gaps), 3), injected_gaps=[round(g, 3) for g in injected_gaps], injected_median=round(statistics.median(injected_gaps), 3), injected_rejection=injected_rejection), artifacts=str(root), native_cpu_count=os.cpu_count(), invocations=records)), flush=True)
finally:
    cleanup()
