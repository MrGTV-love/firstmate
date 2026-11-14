#!/usr/bin/env python3
"""Launch-gate fixtures for fm-cpu-pass.test.sh: the agent launcher's final exec; never fleet state or the live host."""
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fm_cpu_pass_fixture import *  # noqa: E402,F401,F403
from fm_cpu_pass_fixture import cleanup  # noqa: E402

try:
    # First proof: one mapped run is gated and admitted; an unmapped, ambiguous or unreadable mapping refuses.
    folder, db, env = gate_case('gate-map')
    child, log = gate(folder, env, 'x', mode='exit-0', stdin=b'prompt text')
    finish(child)
    text = log.with_suffix('.stderr').read_text()
    seen = json.loads((folder / 'x.agent').read_text())
    assert 'launch-gate run=x branch=fm/x step=ci:running' in text and 'launch-gate admitted: ' in text, text
    assert seen['stdin'] == 'prompt text' and seen['argv'] == ['-p', '--flag'] and seen['cwd'] == os.path.realpath(folder / 'wt-x'), seen
    (folder / 'elsewhere').mkdir()
    child, log = gate(folder, env, 'nowhere', cwd=folder / 'elsewhere', log='unmapped')
    finish(child, 75)
    assert not (folder / 'nowhere.agent').exists() and 'launch-gate refused: unmapped worktree' in log.with_suffix('.stderr').read_text()
    no_retry_phrase(log.with_suffix('.stderr').read_text())
    change(db, "INSERT INTO runs (id, status, repo_id, worktree_dir) VALUES ('twin', 'completed', 'repo', ?)", (str(folder / 'wt-x'),))
    child, log = gate(folder, env, 'x', log='ambiguous')
    finish(child, 75)
    assert 'launch-gate refused: ambiguous worktree' in log.with_suffix('.stderr').read_text()
    child, log = gate(folder, dict(env, CASE_DB=str(folder / 'missing.sqlite')), 'x', log='unreadable')
    finish(child, 75)
    assert 'launch-gate refused: run database unreadable' in log.with_suffix('.stderr').read_text()
    queue = wakes(folder)
    assert all(cause in queue for cause in ('unmapped worktree', 'ambiguous worktree', 'run database unreadable')), queue
    assert 'next action: ' in queue, queue
    # With no run identified, each durable refusal line names the worktree and the launch attempt, then the next action.
    for cause, where in (('unmapped worktree', folder / 'elsewhere'), ('ambiguous worktree', folder / 'wt-x'),
                         ('run database unreadable', folder / 'wt-x')):
        line = next(l for l in queue.splitlines() if 'launch-gate refused: ' + cause in l)
        assert re.search(r'launch-gate refused: %s: worktree %s, attempt \d+:\d+; .+; next action: \S' % (
            re.escape(cause), re.escape(os.path.realpath(where))), line), line

    # A busy wake-queue lock never holds the gate: the refusal exits at once and its wake is spilled to state/.wake-spill.<seq>,
    # which the next append to that queue, or the watcher's next start, replays.
    holder = subprocess.Popen(['bash', '-c', '. "$1" && fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" && touch "$2" && sleep 60', 'bash',
                               str(repo / 'bin/fm-wake-lib.sh'), str(folder / 'queue-held')], env=env, start_new_session=True)
    children.append(holder)
    wait_for(lambda: (folder / 'queue-held').exists(), 'wake-queue lock held')
    before = wakes(folder)
    started_at = time.monotonic()
    child, log = gate(folder, env, 'nowhere', cwd=folder / 'elsewhere', log='unmapped-busy')
    finish(child, 75)
    assert time.monotonic() - started_at < 10 and wakes(folder) == before
    spilled = ''.join(p.read_text() for p in (folder / 'fmhome' / 'state').glob('.wake-spill.[0-9]*'))
    assert 'launch-gate-unmapped' in spilled and 'unmapped worktree' in spilled, spilled
    # Gates that spill at the same moment each keep their own spill file: none is overwritten.
    burst = []
    for i in range(3):
        (folder / ('elsewhere-%d' % i)).mkdir()
        burst.append(gate(folder, env, 'nowhere', cwd=folder / ('elsewhere-%d' % i), log='unmapped-burst-%d' % i)[0])
    for child in burst:
        finish(child, 75)
    spills = [p.read_text() for p in (folder / 'fmhome' / 'state').glob('.wake-spill.[0-9]*')]
    assert len(spills) == 4, spills
    for i in range(3):
        assert len([text for text in spills if os.path.realpath(folder / ('elsewhere-%d' % i)) in text]) == 1, (i, spills)
    os.killpg(holder.pid, signal.SIGKILL)
    holder.wait()

    # The agent and every passthrough start with SIGPIPE at its default, as a shell's exec leaves it.
    def pipe_status(command, env, cwd):
        out = root / ('pipe-%d' % len(records))
        probe = ['bash', '-c', 'yes | head -1 >/dev/null; echo "${PIPESTATUS[0]}" > "$1"', 'probe', str(out)]
        records.append(dict(command=command + probe))
        subprocess.run(command + probe, env=env, cwd=str(cwd), stdin=subprocess.DEVNULL, timeout=30, check=True)
        return out.read_text().strip()
    folder, db, env = gate_case('gate-sigpipe', runs=(('x', 'ci', 'running', None), ('y', 'review', 'fixing', 77)))
    launch_gate = ['bash', str(repo / 'bin/fm-cpu-pass.sh'), 'launch-gate', '--']
    assert pipe_status(launch_gate, env, folder / 'wt-x') == '141'
    assert pipe_status(launch_gate, env, folder / 'wt-y') == '141'
    assert pipe_status(['bash', str(repo / 'bin/fm-mem-guard.sh'), 'run', '--'], env, folder) == '141'
    # The test-pass pool's direct execs keep the base disposition: SIGPIPE stays ignored, so yes exits 1 on EPIPE.
    pass_run = ['bash', str(repo / 'bin/fm-cpu-pass.sh'), 'run', '--']
    (folder / 'not-a-pool').write_text('')
    assert pipe_status(pass_run, dict(env, FM_CPU_PASS_HELD='1'), folder) == '1'
    assert pipe_status(pass_run, dict(env, FM_CPU_POOL_DIR=str(folder / 'not-a-pool')), folder) == '1'

    # Scope (P9.scope): a counted run's recognized non-CI step passes through at once, even on a full host,
    # with the same exit status and outputs as without the gate (the gate writes nothing of its own).
    folder, db, env = gate_case('gate-scope', available=GIB, runs=(('x', 'review', 'fixing', 77), ('g', 'gate.lint.check', 'running', None)))
    for run in ('x', 'g'):
        child, log = gate(folder, env, run, mode='exit-0')
        finish(child)
        assert log.with_suffix('.stderr').read_text() == '' and log.with_suffix('.stdout').read_text() == '', run
        assert (folder / (run + '.agent')).exists() and not live_entries(folder, 'launch-*.lock'), run

    # Exit codes and signal deaths pass through; a signal sent to the gate reaches the agent.
    for mode, code in (('exit-0', 0), ('exit-1', 1), ('exit-75', 75), ('self-term', -signal.SIGTERM)):
        folder, db, env = gate_case('gate-exit-' + mode)
        child, log = gate(folder, env, 'x', mode=mode)
        finish(child, code)
        assert not live_entries(folder, 'launch-*.lock')
    folder, db, env = gate_case('gate-forward')
    child, log = gate(folder, env, 'x', mode='trap')
    wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
    time.sleep(0.2)
    os.kill(child.pid, signal.SIGTERM)
    finish(child, 0)
    assert (folder / 'x.got-term').exists()
    # An agent that cannot be launched gives the shell's statuses unchanged and keeps no reservation.
    for missing, code in ((str(folder / 'no-such-agent'), 127), (str(folder / 'wt-x'), 126)):
        out = subprocess.run(['bash', str(repo / 'bin/fm-cpu-pass.sh'), 'launch-gate', '--', missing], env=env, cwd=str(folder / 'wt-x'),
                             stdin=subprocess.DEVNULL, capture_output=True, text=True)
        assert out.returncode == code and not live_entries(folder, 'launch-*.lock'), (out.returncode, out.stderr)

    # Admission-to-launch order: the reservation is published under the start lock before the agent
    # starts and the lock is released after both; the agent's start waits on no observation.
    folder, db, env = gate_case('gate-order')
    child, log = gate(folder, env, 'x')
    wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
    import re
    stamps = dict(re.findall(r'(admitted_ns|published_ns|agent_started_ns|unlocked_ns)=(\d+)', log.with_suffix('.stderr').read_text()))
    started = json.loads((folder / 'x.agent').read_text())['started_ns']
    assert int(stamps['admitted_ns']) <= int(stamps['published_ns']) <= int(stamps['agent_started_ns']) <= int(stamps['unlocked_ns']), stamps
    assert int(stamps['published_ns']) <= started, (stamps, started)
    assert live_entries(folder, 'launch-*.lock') == 1
    (folder / 'x.release').touch()
    finish(child)
    assert live_entries(folder, 'launch-*.lock') == 0

    # Simultaneous resumes with a lagging reading: room for exactly two (S = 8, R = 3, 12 GiB).
    # The first agent is never visible; the second is decided counting it at R, the third waits
    # and starts by itself once the first exits.
    folder, db, env = gate_case('gate-three', available=12 * GIB, runs=[(r, 'ci', 'running', None) for r in ('a', 'b', 'c')])
    gates = {}
    for run in ('a', 'b'):
        gates[run] = gate(folder, env, run)[0]
        wait_for(lambda: (folder / (run + '.agent')).exists(), run + ' admitted')
    gates['c'] = gate(folder, env, 'c')[0]
    wait_for(lambda: 'held for capacity' in wakes(folder), 'third decided')
    assert not (folder / 'c.agent').exists()
    text_b = (folder / 'gate-b.stderr').read_text()
    assert 'a:launched:%d:unseen' % (3 * GIB) in text_b and 'projected=%d ' % (11 * GIB) in text_b, text_b
    wait_for(lambda: 'launch-gate waiting: counted=3 projected=%d ' % (14 * GIB) in (folder / 'gate-c.stderr').read_text() or
             'held for capacity' in wakes(folder), 'third holds')
    assert 'run c (fm/c) held for capacity' in wakes(folder), wakes(folder)
    # A fix round waits in the one queue at class other.
    assert all('priority=other' in line for line in wakes(folder).splitlines() if 'held for capacity' in line), wakes(folder)
    (folder / 'a.release').touch()
    finish(gates['a'])
    wait_for(lambda: (folder / 'c.agent').exists(), 'third starts by itself')
    wait_for(lambda: 'run c (fm/c) admitted after' in wakes(folder), 'admission after a hold is recorded')
    for run in ('b', 'c'):
        (folder / (run + '.release')).touch()
        finish(gates[run])

    # Class: a fix round waits in class other, so a machinery fresh start that arrives after it is admitted first.
    folder, db, env = gate_case('gate-class', available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
    gate_x = gate(folder, env, 'x')[0]
    pending(folder, 1)
    fresh = launch(cli + ['pipeline-start', '--priority', 'machinery', '--', 'touch', str(folder / 'm')], env, folder / 'fresh')
    pending(folder, 2)
    facts(folder, available=12 * GIB)
    wait_for(lambda: (folder / 'x.agent').exists(), 'the fix round starts after the fresh start')
    assert (folder / 'm').exists() and (folder / 'm').stat().st_mtime_ns <= (folder / 'x.agent').stat().st_mtime_ns, \
        'the later machinery start was not admitted first'
    finish(fresh)
    (folder / 'x.release').touch()
    finish(gate_x)

    # After first appearance: a visible agent at 0.2 GiB still reserves A = 1 GiB. A later start that
    # fits on startup memory alone (8.2 of 8.7 GiB) waits (9 > 8.7) and is admitted once the agent exits.
    folder, db, env = gate_case('gate-after-visible', available=int(8.5 * GIB), runs=[('x', 'ci', 'running', None)])
    child, log = gate(folder, env, 'x')
    wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
    facts(folder, available=int(8.5 * GIB), runs=[('repo', 'x', GIB // 5)])
    later = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later')
    wait_for(lambda: 'waiting: counted=1 projected=%d ' % (9 * GIB) in (folder / 'later.stderr').read_text(), 'A, not startup memory')
    assert 'x:launched:%d' % GIB in (folder / 'later.stderr').read_text()
    (folder / 'x.release').touch()
    finish(child)
    facts(folder, available=int(8.5 * GIB))
    finish(later)

    # Gates that wait together, in the daemon's fix-time state: each run's ci step is fixing with the
    # gate's pid recorded and the gate visible at 0.1 GiB. Another run's waiting gate adds only what it
    # holds, so the first fits (8 + 0.4 of 8.9 GiB; counting the others at A would be 11.1) and each
    # later one starts by itself once the run before it is a CI waiter again.
    tenth = GIB // 10
    names = ('a', 'b', 'c', 'd')
    folder, db, env = gate_case('gate-waiters', available=int(8.5 * GIB), runs=[(r, 'ci', 'fixing', 4242) for r in names])
    facts(folder, available=int(8.5 * GIB), pressure=2, runs=[('repo', r, tenth) for r in names])
    gates = {}
    for run in names:
        gates[run] = gate(folder, env, run)[0]
        wait_for(lambda: live_entries(folder) == len(gates), run + ' queued')
    facts(folder, available=int(8.5 * GIB), runs=[('repo', r, tenth) for r in names])
    for index, run in enumerate(names):
        wait_for(lambda: (folder / (run + '.agent')).exists(), run + ' starts by itself')
        assert not any((folder / (later + '.agent')).exists() for later in names[index + 1:]), run
        text = (folder / ('gate-%s.stderr' % run)).read_text()
        assert all('%s:waiter:%d' % (later, tenth) in text for later in names[index + 1:]), text
        (folder / (run + '.release')).touch()
        finish(gates[run])
        change(db, "UPDATE step_results SET status = 'running', agent_pid = NULL WHERE run_id = ?", (run,))
        facts(folder, available=int(8.5 * GIB), runs=[('repo', r, tenth) for r in names[index + 1:]])

    # Dead holders and retries: an unlocked launch record reserves nothing and is removed; two live
    # attempts of one run hold one reservation.
    folder, db, env = gate_case('gate-holders', available=12 * GIB, runs=[('x', 'ci', 'running', None)])
    (folder / 'pool').mkdir(exist_ok=True)
    (folder / 'pool' / 'launch-dead.lock').write_text(json.dumps(dict(run='x', repo='repo', pid=999999, started_ns=1)))
    finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm1')], env, folder / 'dead'))
    assert 'holding_only=[x:ci-waiting:0:unseen]' in (folder / 'dead.stderr').read_text() and not (folder / 'pool/launch-dead.lock').exists()
    first, _ = gate(folder, env, 'x', log='attempt-1')
    wait_for(lambda: live_entries(folder, 'launch-*.lock') == 1, 'first attempt reserved')
    (folder / 'x.agent').unlink(missing_ok=True)
    second, _ = gate(folder, env, 'x', log='attempt-2')
    wait_for(lambda: live_entries(folder, 'launch-*.lock') == 2, 'second attempt reserved')
    # Two live attempts, both started and not yet visible, reserve 2 x R = 6 GiB: a start that would fit beside one
    # (3 + 8 = 11 of 12 GiB) waits beside two (6 + 8 = 14), and starts once one attempt ends.
    two = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm2')], env, folder / 'two')
    pending(folder, 1)
    wait_for(lambda: 'x:launched:%d:unseen' % (6 * GIB) in (folder / 'two.stderr').read_text(), 'two live attempts count twice')
    assert not (folder / 'm2').exists() and (folder / 'two.stderr').read_text().count('x:launched:') >= 1
    (folder / 'x.release').touch()
    finish(first); finish(second)
    finish(two)
    assert (folder / 'm2').exists()

    # Hold bound: budget 3 s minus the CI-fix p99 of 1 s holds 2 s, then refuses visibly; the agent never starts.
    folder, db, env = gate_case('gate-bound', available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)],
                                timeout='3s', ci_ms=(500, 1000))
    began = time.monotonic()
    child, log = gate(folder, env, 'x')
    finish(child, 75)
    text = log.with_suffix('.stderr').read_text()
    assert time.monotonic() - began >= 1.5 and not (folder / "x.agent").exists(), text
    assert re.search(r'launch-gate refused: hold bound reached: run x; hold_bound=[12]s budget=3s round_elapsed=[01]s ci_fix_p99=1s'
                     r' n=2 held=0 ambiguous=0; held ', text), text
    assert 'next action: ' in text and 'auto_fix.ci' in text and 'ask-user decision' in text, text
    no_retry_phrase(text)
    assert 'refused: hold bound reached' in wakes(folder) and 'held for capacity' in wakes(folder)
    assert not live_entries(folder) and not live_entries(folder, 'launch-*.lock')
    # The real bound, driven by the clock: the host's 240-minute budget with a completed CI-fix p99 of 152.45 min
    # (9147000 ms) gives 14400 - 9147 = 5253 s; the omitted budget (30 min default) with a p99 of 10 min gives 1200 s.
    # Five seconds before the bound the gate still holds; a fit then is admitted; at the bound it refuses.
    for label, timeout, ci_ms, bound, budget, p99 in (('override-240m', '240m', (9147000,), 5253, 14400, 9147),
                                                      ('default-30m', None, (600000,), 1200, 1800, 600)):
        for outcome in ('fits-before', 'refused-at'):
            folder, db, env = gate_case('gate-real-bound-%s-%s' % (label, outcome), available=GIB, timeout=timeout, ci_ms=ci_ms,
                                        runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
            if timeout is None:
                # The key omitted from an existing config: the daemon's built-in 30 minutes apply.
                (folder / 'home' / '.no-mistakes' / 'config.yaml').write_text('agent: [claude]\n')
            clock = folder / 'clock'
            clock.write_text('0')
            child, log = gate(folder, dict(env, CASE_CLOCK_FILE=str(clock)), 'x')
            pending(folder, 1)
            clock.write_text(str(bound - 5))
            time.sleep(1.5)
            assert child.poll() is None and not (folder / 'x.agent').exists(), (label, log.with_suffix('.stderr').read_text())
            if outcome == 'fits-before':
                facts(folder, available=40 * GIB)
                wait_for(lambda: (folder / 'x.agent').exists(), label + ': admitted before the bound')
                (folder / 'x.release').touch()
                finish(child)
            else:
                clock.write_text(str(bound + 1))
                finish(child, 75)
                text = log.with_suffix('.stderr').read_text()
                assert re.search(r'launch-gate refused: hold bound reached: run x; hold_bound=(%d|%d)s budget=%ds round_elapsed=[01]s'
                                 r' ci_fix_p99=%ds n=1 held=0 ambiguous=0; held ' % (bound, bound - 1, budget, p99), text), (label, text)
                assert not (folder / 'x.agent').exists()

    # No positive bound (budget not above p99, or no config) refuses at once when nothing fits.
    for timeout in ('1s', None):
        folder, db, env = gate_case('gate-nobound-%s' % timeout, available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)],
                                    timeout=timeout, ci_ms=(2000000,))
        child, log = gate(folder, env, 'x')
        finish(child, 75)
        assert 'hold_bound=0s' in log.with_suffix('.stderr').read_text(), log.with_suffix('.stderr').read_text()

    # Cleanup: a group kill mid-hold and mid-run, the gate alone killed mid-run, and an internal gate
    # error after the admit each leave no agent, no live reservation and a free start lock.
    folder, db, env = gate_case('gate-kill-hold', available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
    child, log = gate(folder, env, 'x')
    wait_for(lambda: live_entries(folder) == 1, 'held')
    os.killpg(child.pid, signal.SIGKILL)
    finish(child, -signal.SIGKILL)
    assert not (folder / 'x.agent').exists() and live_entries(folder) == 0
    for label, kill in (('group', lambda c: os.killpg(c.pid, signal.SIGKILL)), ('gate-only', lambda c: os.kill(c.pid, signal.SIGKILL))):
        folder, db, env = gate_case('gate-kill-' + label)
        child, log = gate(folder, env, 'x')
        wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
        agent_pid = json.loads((folder / 'x.agent').read_text())['pid']
        kill(child)
        finish(child, -signal.SIGKILL)
        wait_for(lambda: not alive(agent_pid), label + ': no agent left')
        assert live_entries(folder, 'launch-*.lock') == 0 and live_entries(folder, 'pipeline-start.lock') == 0
    folder, db, env = gate_case('gate-raise')
    child, log = gate(folder, dict(env, CASE_GATE_RAISE='1'), 'x')
    wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
    agent_pid = json.loads((folder / 'x.agent').read_text())['pid']
    finish(child, 1)
    wait_for(lambda: not alive(agent_pid), 'no agent after an internal error')
    assert live_entries(folder, 'launch-*.lock') == 0
    # Contract revision 28 cases. Every case runs; failures are collected and reported together.
    r28 = {}

    def r28_case(name, body):
        try:
            body()
            r28[name] = 'pass'
        except Exception as exc:  # noqa: BLE001 - every case's failure is reported
            r28[name] = 'FAIL: %s: %s' % (type(exc).__name__, str(exc)[:1500])

    def stderr_of(log):
        return log.with_suffix('.stderr').read_text()

    def unknown_steps():
        # P9.scope: a launch whose current step cannot be established refuses with its cause, on the
        # refusal line and in a durable line, never passed through and never admitted, even with room.
        for label, runs, prepare, cause in (
                ('no-open-step', (('x', None, None, None),), None, 'step not established: no open step for run x'),
                ('unrecognized', (('x', 'frobnicate', 'running', None),), None, "step not established: unrecognized step 'frobnicate'"),
                ('bad-gate-anchor', (('x', 'gate.push.check', 'running', None),), None, "step not established: unrecognized step 'gate.push.check'"),
                ('unreadable', (('x', 'ci', 'running', None),), lambda db: change(db, 'ALTER TABLE step_results RENAME TO hidden'),
                 'step not established: step facts unreadable')):
            folder, db, env = gate_case('gate-unknown-' + label, runs=runs)
            if prepare:
                prepare(db)
            child, log = gate(folder, env, 'x', mode='exit-0')
            finish(child, 75)
            text = stderr_of(log)
            assert 'launch-gate refused: ' + cause in text and 'next action: ' in text, (label, text)
            assert not (folder / 'x.agent').exists() and 'admitted' not in text, (label, text)
            assert cause in wakes(folder), (label, wakes(folder))
            no_retry_phrase(text)

    def uncounted_gated():
        # P9.scope: a mapped run outside the counted set (CI-ready, or parked) starts an agent only after admission:
        # on a host without room it waits, then is admitted by itself once capacity returns.
        for label, column in (('ci-ready', 'ci_ready_at'), ('parked', 'awaiting_agent_since')):
            folder, db, env = gate_case('gate-uncounted-' + label, available=GIB,
                                        runs=(('x', 'review', 'fixing', None), ('y', 'test', 'running', None)))
            change(db, 'UPDATE runs SET %s = 1 WHERE id = ?' % column, ('x',))
            # The bound uses the review step's own completed rows here: one of 60 s.
            change(db, "UPDATE agent_invocations SET duration_ms = 60000, completed_at = started_at + 60 WHERE step_name = 'review'")
            child, log = gate(folder, env, 'x')
            wait_for(lambda: 'held for capacity' in wakes(folder), label + ': held')
            time.sleep(0.5)
            assert not (folder / 'x.agent').exists() and child.poll() is None, (label, stderr_of(log))
            facts(folder, available=40 * GIB)
            wait_for(lambda: (folder / 'x.agent').exists(), label + ': admitted by itself')
            assert 'launch-gate admitted: ' in stderr_of(log) and live_entries(folder, 'launch-*.lock') == 1, label
            (folder / 'x.release').touch()
            finish(child)

    def identified_shape():
        # P9.map: a registered checkout's working_path that is no run's worktree passes through with no reservation;
        # an unmapped launch inside a run's worktree and one outside any registered checkout stay refused.
        folder, db, env = gate_case('gate-identified-shape', available=GIB)
        (folder / 'checkout').mkdir()
        change(db, 'INSERT INTO repos (id, working_path) VALUES (?, ?)', ('repo', str(folder / 'checkout')))
        child, log = gate(folder, env, 'wizard', mode='exit-0', cwd=folder / 'checkout')
        finish(child)
        assert (folder / 'wizard.agent').exists() and stderr_of(log) == '' and not live_entries(folder, 'launch-*.lock')
        for label, where in (('inside-run', folder / 'wt-x' / 'sub'), ('inside-checkout', folder / 'checkout' / 'sub'),
                             ('outside', folder / 'nowhere')):
            where.mkdir(parents=True)
            child, log = gate(folder, env, 'stray-' + label, mode='exit-0', cwd=where)
            finish(child, 75)
            assert 'launch-gate refused: unmapped worktree' in stderr_of(log) and not (folder / ('stray-' + label + '.agent')).exists(), label

    def bound_from_round_start():
        # P9.bound: the hold is the budget less the time the current round has run less the percentile. A retry born
        # 4 s into a 6 s deadline with a 1 s percentile holds 1 s and is refused before the deadline.
        folder, db, env = gate_case('gate-bound-round', available=GIB, timeout='6s', ci_ms=(1000,), round_age=4,
                                    runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
        with sqlite3.connect(db) as connection:
            round_started = connection.execute("SELECT round_started_at FROM step_results WHERE run_id = 'x'").fetchone()[0]
        child, log = gate(folder, env, 'x')
        finish(child, 75)
        ended = time.time()
        text = stderr_of(log)
        # round_started_at is whole seconds (the next second, less 4), so the round has run 3 to 4 s when the gate reads it.
        assert 'hold bound reached' in text and re.search(r'hold_bound=[012]s budget=6s round_elapsed=[34]s ci_fix_p99=1s', text), text
        assert ended < round_started + 6 and not (folder / 'x.agent').exists(), (ended - round_started, text)
        # An immediate launch with capacity arriving in time is admitted.
        folder, db, env = gate_case('gate-bound-round-fit', available=GIB, timeout='6s', ci_ms=(1000,), round_age=1,
                                    runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
        child, log = gate(folder, env, 'x')
        wait_for(lambda: 'held for capacity' in wakes(folder), 'held')
        facts(folder, available=40 * GIB)
        wait_for(lambda: (folder / 'x.agent').exists(), 'admitted inside its bound')
        (folder / 'x.release').touch()
        finish(child)
        # An unreadable round start, or one that leaves no positive bound, holds not at all: one immediate decision.
        for label, round_age, fits in (('unreadable', None, False), ('spent', 300, False), ('spent-fit', 300, True)):
            folder, db, env = gate_case('gate-bound-zero-' + label, available=40 * GIB if fits else GIB, timeout='6s',
                                        ci_ms=(1000,), round_age=round_age or 0,
                                        runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
            if round_age is None:
                change(db, 'UPDATE step_results SET round_started_at = NULL')
            child, log = gate(folder, env, 'x', mode='exit-0')
            finish(child, 0 if fits else 75)
            text = stderr_of(log)
            assert 'hold_bound=0s' in text, (label, text)
            if fits:
                assert (folder / 'x.agent').exists() and 'launch-gate admitted: ' in text, (label, text)
            else:
                assert not (folder / 'x.agent').exists() and 'launch-gate refused: hold bound reached' in text, (label, text)

    def held_rows(label, rows, holds, expect_p99, expect_n, expect_held, expect_ambiguous):
        # P9.bound's held-row rule: completed ci rows less the rows held launches spent; an ambiguous record
        # excludes its smallest candidate (the largest feasible percentile); the line prints n, held and ambiguous.
        folder, db, env = gate_case('gate-held-' + label, available=GIB, ci_ms=(), runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
        with sqlite3.connect(db) as connection:
            connection.execute('DELETE FROM agent_invocations')
            connection.executemany('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                                   [(str(i), run, 'ci', 'ci', start, end, ms, status) for i, (run, start, end, ms, status) in enumerate(rows)])
        (folder / 'pool').mkdir(exist_ok=True)
        (folder / 'pool' / 'launch-holds.jsonl').write_text(''.join(json.dumps(dict(run=run, step='ci', gate_started=at, attempt='a%d' % i)) + '\n'
                                                                    for i, (run, at) in enumerate(holds)))
        child, log = gate(folder, env, 'x')
        wait_for(lambda: 'held for capacity' in wakes(folder), label + ': held')
        line = next(l for l in wakes(folder).splitlines() if 'held for capacity' in l)
        assert 'ci_fix_p99=%ds n=%d held=%d ambiguous=%d' % (expect_p99, expect_n, expect_held, expect_ambiguous) in line, (label, line)
        os.killpg(child.pid, signal.SIGKILL)
        finish(child, -signal.SIGKILL)

    def held_row_cases():
        two, three = 2000, 3000
        # Attempt X (run p) from 12:00 held from 12:00:30 with an unheld attempt Y (run q) from 12:05, and the reverse order.
        held_rows('x-then-y', [('p', 43200, 43200 + 4000, 4000 * 1000, 'ok'), ('q', 43500, 43560, 60 * 1000, 'ok')],
                  [('p', 43230)], 60, 1, 1, 0)
        held_rows('y-then-x', [('q', 43200, 43260, 60 * 1000, 'ok'), ('p', 43500, 43500 + 4000, 4000 * 1000, 'ok')],
                  [('p', 43530)], 60, 1, 1, 0)
        # Two ambiguous holds of different runs, each matching one 2 s and one 3 s row, among 196 unambiguous 2 s rows: 3 s.
        rows = [('u%d' % i, 1, 3, two, 'ok') for i in range(196)]
        rows += [('p', 100, 102, two, 'ok'), ('p', 100, 103, three, 'ok'), ('q', 200, 202, two, 'ok'), ('q', 200, 203, three, 'ok')]
        held_rows('two-ambiguous', rows, [('p', 101), ('q', 201)], 3, 198, 2, 2)
        # One ambiguous 3 s row beside 98 rows of 2 s and one of 1000 s (the hold matches the 3 s and the 1000 s row): 1000 s.
        rows = [('u%d' % i, 1, 3, two, 'ok') for i in range(98)] + [('p', 100, 1100, 10 ** 6, 'ok'), ('p', 100, 103, three, 'ok')]
        held_rows('one-ambiguous', rows, [('p', 101)], 1000, 99, 1, 1)
        # Of two completed rows of equal duration the held one is excluded and the unheld one counted; refused and
        # review rows never count.
        held_rows('equal', [('p', 100, 160, 60 * 1000, 'ok'), ('q', 300, 360, 60 * 1000, 'ok'), ('r', 1, 9999, 10 ** 9, 'error')],
                  [('p', 130)], 60, 1, 1, 0)

    def hold_record_written():
        # Every held launch leaves the record the held-row rule reads: run, step, gate start, attempt.
        folder, db, env = gate_case('gate-hold-record', available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
        child, log = gate(folder, env, 'x')
        wait_for(lambda: 'held for capacity' in wakes(folder), 'held')
        records_seen = [json.loads(line) for line in (folder / 'pool' / 'launch-holds.jsonl').read_text().splitlines()]
        assert len(records_seen) == 1 and records_seen[0]['run'] == 'x' and records_seen[0]['step'] == 'ci', records_seen
        assert abs(records_seen[0]['gate_started'] - time.time()) < 30 and re.match(r'\d+:\d+$', records_seen[0]['attempt']), records_seen
        os.killpg(child.pid, signal.SIGKILL)
        finish(child, -signal.SIGKILL)

    for name, body in (('P9.scope unknown steps refuse', unknown_steps), ('P9.scope uncounted runs are gated', uncounted_gated),
                       ('P9.map identified shape', identified_shape), ('P9.bound round start and zero hold', bound_from_round_start),
                       ('P9.bound held rows', held_row_cases), ('P9.bound hold record', hold_record_written)):
        r28_case(name, body)
    (root / 'r28-gate.json').write_text(json.dumps(r28, indent=2))
    print(json.dumps(dict(r28=r28)), flush=True)
    assert all(value == 'pass' for value in r28.values()), r28

    print(json.dumps(dict(result='pass', artifacts=str(root), invocations=records)), flush=True)
finally:
    cleanup()
