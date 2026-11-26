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

outside_orphans = []  # (pid, start time) of each outside orphan this script started and has not yet killed

try:
    if not KERNEL_FACTS:
        # Off macOS the gate has no kernel facts to record an attempt with: a mapped ci launch that fits refuses with
        # exit 75 and a durable line, and its agent never runs. Every other case here needs an admission, so none runs.
        folder, db, env = gate_case('gate-no-kernel-facts')
        child, log = gate(folder, env, 'x', mode='exit-0')
        finish(child, 75)
        text = log.with_suffix('.stderr').read_text()
        assert 'launch-gate refused: process facts unreadable: run x' in text and not (folder / 'x.agent').exists(), text
        assert 'process facts unreadable' in wakes(folder), wakes(folder)
        skipped_without_kernel_facts('every other launch-gate case')
        print(json.dumps(dict(result='pass', artifacts=str(root), invocations=records)), flush=True)
        sys.exit(0)
    # CASE_NAMED_ONLY (a failing-first run against an earlier engine, harness/r29_prior_heads.py): only the named
    # groups below run, so an engine that predates the main fixtures still records each named case's outcome.
    if not os.environ.get('CASE_NAMED_ONLY'):
        # First proof: one mapped run is gated and admitted; an unmapped, ambiguous or unreadable mapping refuses.
        folder, db, env = gate_case('gate-map')
        child, log = gate(folder, env, 'x', mode='exit-0', stdin=b'prompt text')
        finish(child)
        text = log.with_suffix('.stderr').read_text()
        seen = agent_info(folder / 'x.agent')
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
        holder = subprocess.Popen(['bash', '-c', '. "$1" && fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" && touch "$2" && sleep 3600', 'bash',
                                   str(repo / 'bin/fm-wake-lib.sh'), str(folder / 'queue-held')], env=env, start_new_session=True)
        children.append(holder)
        wait_for(lambda: (folder / 'queue-held').exists(), 'wake-queue lock held')
        before = wakes(folder)
        child, log = gate(folder, env, 'nowhere', cwd=folder / 'elsewhere', log='unmapped-busy')
        finish(child, 75)
        # The refusal ended while the holder still held the queue lock: the gate never waited for it.
        assert holder.poll() is None and wakes(folder) == before
        spilled = ''.join(p.read_text() for p in (folder / 'fmhome' / 'state').glob('.wake-spill.[0-9]*'))
        assert 'launch-gate-unmapped' in spilled and 'unmapped worktree' in spilled, spilled
        # Gates that spill at the same moment each keep their own spill file: none is overwritten.
        burst = []
        (folder / 'spill-barrier').mkdir()
        burst_env = dict(env, CASE_SPILL_BARRIER=str(folder / 'spill-barrier'), CASE_SPILL_COUNT='3')
        for i in range(3):
            (folder / ('elsewhere-%d' % i)).mkdir()
            burst.append(gate(folder, burst_env, 'nowhere', cwd=folder / ('elsewhere-%d' % i), log='unmapped-burst-%d' % i)[0])
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
            run_to_exit(command + probe, 'the SIGPIPE probe to exit', env=env, cwd=str(cwd), stdin=subprocess.DEVNULL, check=True)
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
            child, log = gate(folder, env, run, mode='exit-0', session=False)  # an agent that prints nothing
            finish(child)
            assert log.with_suffix('.stderr').read_text() == '' and log.with_suffix('.stdout').read_text() == '', run
            assert (folder / (run + '.agent')).exists() and settled_held(folder, ['x', 'g']) == 0, run

        # Exit codes and signal deaths pass through; a signal sent to the gate reaches the agent.
        for mode, code in (('exit-0', 0), ('exit-1', 1), ('exit-75', 75), ('self-term', -signal.SIGTERM)):
            folder, db, env = gate_case('gate-exit-' + mode)
            child, log = gate(folder, env, 'x', mode=mode)
            finish(child, code)
            held = settled_held(folder, ['x'])
            assert held == 0, (mode, repr(held))
        folder, db, env = gate_case('gate-forward')
        child, log = gate(folder, dict(env, CASE_TERM_BEFORE_FORWARD='1'), 'x', mode='trap')
        agent_info(folder / 'x.agent', log=log, child=child)
        began = time.monotonic()
        while not (folder / 'x.got-term').exists() and child.poll() is None:
            if time.monotonic() - began >= HANG_BACKSTOP_SECS:
                hang_backstop_expired('the gate to forward SIGTERM to its agent', began, log)
            os.kill(child.pid, signal.SIGTERM)
            time.sleep(0.2)
        finish(child, 0)
        assert (folder / 'x.got-term').exists()
        assert agent_info(folder / 'x.agent')['term_default'], 'the agent started with SIGTERM not at its default action'
        # An agent that cannot be launched gives the shell's statuses unchanged and keeps no reservation.
        for missing, code in ((str(folder / 'no-such-agent'), 127), (str(folder / 'wt-x'), 126)):
            out = subprocess.run(['bash', str(repo / 'bin/fm-cpu-pass.sh'), 'launch-gate', '--', missing], env=env, cwd=str(folder / 'wt-x'),
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True)
            assert out.returncode == code and settled_held(folder, ['x']) == 0, (out.returncode, out.stderr)

        # Admission-to-launch order: the reservation is published under the start lock before the agent
        # starts and the lock is released after both; the agent's start waits on no observation.
        folder, db, env = gate_case('gate-order')
        child, log = gate(folder, env, 'x')
        wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
        import re
        stamps = dict(re.findall(r'(admitted_ns|published_ns|agent_started_ns|unlocked_ns)=(\d+)', log.with_suffix('.stderr').read_text()))
        started = agent_info(folder / 'x.agent')['started_ns']
        assert int(stamps['admitted_ns']) <= int(stamps['published_ns']) <= int(stamps['agent_started_ns']) <= int(stamps['unlocked_ns']), stamps
        assert int(stamps['published_ns']) <= started, (stamps, started)
        assert reserving_held(folder, ['x']) == 1
        (folder / 'x.release').touch()
        finish(child)
        wait_for(lambda: reserving_held(folder, ['x']) == 0, 'the attempt ends with its agent')

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
        wait_for(lambda: 'launch-gate waiting: counted=3 projected=%d ' % (14 * GIB) in (folder / 'gate-c.stderr').read_text(),
                 'third holds')
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
        # The reading shows the agent's own process (pid and exact start time, as the census reports it).
        agent_pid = agent_info(folder / 'x.agent')['pid']
        facts(folder, available=int(8.5 * GIB), runs=[('repo', 'x', GIB // 5, agent_pid, start_us(agent_pid))])
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

        # Ended attempts and retries: an attempt record whose root no longer lives, and no process of which could
        # remain, reserves nothing; each live attempt of one run reserves its own R.
        folder, db, env = gate_case('gate-holders', available=12 * GIB, runs=[('x', 'ci', 'running', None)])
        (folder / 'pool').mkdir(exist_ok=True)
        gone = subprocess.Popen(['true']); gone.wait()
        me = engine().kernel_snapshot()[os.getpid()]
        (folder / 'pool' / 'attempt-dead.json').write_text(json.dumps(dict(
            id='dead', run='x', repo='repo', step='ci', reserves=True, t0_us=int(time.time() * 1000000), root=[gone.pid, 1],
            gate=None, watcher=None, coalition=me[2], session_key='dead-key', members=[], ended_us=None)))
        # The daemon's row for that launch, carrying its own key: once the record ends, the launch is shown ended.
        change(db, "INSERT INTO agent_invocations (id, run_id, step_name, purpose, started_at, completed_at, duration_ms, exit_status,"
                   " session_key) VALUES ('dead', 'x', 'ci', 'ci', 1, 2, 1, 'launched', 'dead-key')")
        finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm1')], env, folder / 'dead'))
        assert 'holding_only=[x:ci-waiting:0:unseen]' in (folder / 'dead.stderr').read_text(), (folder / 'dead.stderr').read_text()
        first, _ = gate(folder, env, 'x', log='attempt-1')
        wait_for(lambda: reserving_held(folder, ['x']) == 1, 'first attempt reserved')
        (folder / 'x.agent').unlink(missing_ok=True)
        second, _ = gate(folder, env, 'x', log='attempt-2')
        wait_for(lambda: reserving_held(folder, ['x']) == 2, 'second attempt reserved')
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
        # These bound cases start the round after any healthy case ends (the gate clamps a future start's elapsed time to
        # 0), so the bound is the budget less the percentile however long the host takes to start the gate; the round's
        # elapsed time is the subject of P9.bound below.
        folder, db, env = gate_case('gate-bound', available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)],
                                    timeout='3s', ci_ms=(500, 1000), round_age=-HANG_BACKSTOP_SECS)
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
        assert not live_entries(folder) and settled_held(folder, ['x', 'y']) == 0
        # The real bound, driven by the clock: the host's 240-minute budget with a completed CI-fix p99 of 152.45 min
        # (9147000 ms) gives 14400 - 9147 = 5253 s; the omitted budget (30 min default) with a p99 of 10 min gives 1200 s.
        # Five seconds before the bound the gate still holds; a fit read before the bound is admitted; past it, it refuses.
        for label, timeout, ci_ms, bound, budget, p99 in (('override-240m', '240m', (9147000,), 5253, 14400, 9147),
                                                          ('default-30m', None, (600000,), 1200, 1800, 600)):
            for outcome in ('fits-before', 'refused-at'):
                folder, db, env = gate_case('gate-real-bound-%s-%s' % (label, outcome), available=GIB, timeout=timeout, ci_ms=ci_ms,
                                            runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)],
                                            round_age=-HANG_BACKSTOP_SECS)
                if timeout is None:
                    # The key omitted from an existing config: the daemon's built-in 30 minutes apply.
                    (folder / 'home' / '.no-mistakes' / 'config.yaml').write_text('agent: [claude]\n')
                clock = folder / 'clock'
                drive(clock, 0)
                child, log = gate(folder, dict(env, CASE_CLOCK_FILE=str(clock)), 'x')
                pending(folder, 1)
                drive(clock, bound - 5)
                time.sleep(1.5)
                assert child.poll() is None and not (folder / 'x.agent').exists(), (label, log.with_suffix('.stderr').read_text())
                if outcome == 'fits-before':
                    facts(folder, available=40 * GIB)
                    drive(clock, bound - 2)
                    wait_for(lambda: (folder / 'x.agent').exists(), label + ': admitted before the bound', log=log, child=child)
                    (folder / 'x.release').touch()
                    finish(child)
                else:
                    drive(clock, bound + 1)
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
            agent_pid = agent_info(folder / 'x.agent')['pid']
            kill(child)
            finish(child, -signal.SIGKILL)
            wait_for(lambda: not alive(agent_pid), label + ': no agent left')
            wait_for(lambda: reserving_held(folder, ['x']) == 0, label + ': the attempt ends')
            assert live_entries(folder, 'pipeline-start.lock') == 0
        folder, db, env = gate_case('gate-raise')
        child, log = gate(folder, dict(env, CASE_GATE_RAISE='1'), 'x')
        wait_for(lambda: (folder / 'x.agent').exists(), 'agent started')
        agent_pid = agent_info(folder / 'x.agent')['pid']
        finish(child, 1)
        wait_for(lambda: not alive(agent_pid), 'no agent after an internal error')
        wait_for(lambda: reserving_held(folder, ['x']) == 0, 'the attempt ends after an internal error')
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
            wait_for(lambda: (folder / 'x.agent').exists(), label + ': admitted by itself', log=log, child=child)
            assert 'launch-gate admitted: ' in stderr_of(log) and reserving_held(folder, ['x']) == 1, label
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
        assert (folder / 'wizard.agent').exists() and stderr_of(log) == '' and not [
            path for path in (folder / 'pool').glob('attempt-*.json') if not path.name.startswith('attempt-proof-')]  # no record of its own
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
        clock = folder / 'clock'
        drive(clock, 0, wall=round_started + 3.5)
        child, log = gate(folder, dict(env, CASE_CLOCK_FILE=str(clock)), 'x')
        wait_for(lambda: 'held for capacity' in wakes(folder), 'held', log=log, child=child)
        drive(clock, 2, wall=round_started + 5.5)
        finish(child, 75)
        text = stderr_of(log)
        # The gate reads the round 3.5 s old, so it holds 1.5 s; the clock then reads 5.5 s into the round.
        assert 'hold bound reached' in text and re.search(r'hold_bound=[012]s budget=6s round_elapsed=[34]s ci_fix_p99=1s', text), text
        elapsed, held_for = int(re.search(r'round_elapsed=(\d+)s', text).group(1)), int(re.search(r'; held (\d+)s;', text).group(1))
        assert elapsed + held_for < 6 and not (folder / 'x.agent').exists(), (elapsed, held_for, text)
        # An immediate launch with capacity arriving in time is admitted.
        folder, db, env = gate_case('gate-bound-round-fit', available=GIB, timeout='6s', ci_ms=(1000,), round_age=1,
                                    runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
        with sqlite3.connect(db) as connection:
            round_started = connection.execute("SELECT round_started_at FROM step_results WHERE run_id = 'x'").fetchone()[0]
        clock = folder / 'clock'
        drive(clock, 0, wall=round_started + 1.5)
        child, log = gate(folder, dict(env, CASE_CLOCK_FILE=str(clock)), 'x')
        wait_for(lambda: 'held for capacity' in wakes(folder), 'held', log=log, child=child)
        assert 'hold_bound=3s budget=6s round_elapsed=1s ci_fix_p99=1s' in wakes(folder), wakes(folder)
        drive(clock, 0)
        facts(folder, available=40 * GIB)
        drive(clock, 2.5)
        wait_for(lambda: (folder / 'x.agent').exists(), 'admitted inside its bound', log=log, child=child)
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
            connection.executemany('INSERT INTO agent_invocations (id, run_id, step_name, purpose, started_at, completed_at, duration_ms, exit_status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
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
        launched_at = time.time()
        child, log = gate(folder, env, 'x')
        wait_for(lambda: 'held for capacity' in wakes(folder), 'held')
        records_seen = [json.loads(line) for line in (folder / 'pool' / 'launch-holds.jsonl').read_text().splitlines()]
        assert len(records_seen) == 1 and records_seen[0]['run'] == 'x' and records_seen[0]['step'] == 'ci', records_seen
        assert launched_at <= records_seen[0]['gate_started'] <= time.time() and re.match(r'\d+:\d+$', records_seen[0]['attempt']), records_seen
        os.killpg(child.pid, signal.SIGKILL)
        finish(child, -signal.SIGKILL)

    def storage_case(name, first_writable, status_writable, available=GIB):
        """A refusal fixture for the P9 storage table: run x of task x (branch fm/x, state/x.meta present).

        The first record (the root home's wake queue) is made unwritable through the wake library's own
        FM_STATE_OVERRIDE, pointed at a 0500 directory, so neither the append nor a spill can land; the status log is
        made unwritable as a 0400 file. A zero hold (a 1 s budget below the 2000 s percentile) on a full host refuses at once.
        """
        folder, db, env = gate_case(name, available=available, timeout='1s', ci_ms=(2000000,),
                                    runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
        state = folder / 'fmhome' / 'state'
        state.mkdir(parents=True, exist_ok=True)
        (state / 'x.meta').write_text('kind=ship\n')
        (state / 'x.status').write_text('working [at=1]: fixture\n')
        if not status_writable:
            (state / 'x.status').chmod(0o400)
        if not first_writable:
            locked = folder / 'locked-state'
            locked.mkdir()
            locked.chmod(0o500)
            env = dict(env, FM_STATE_OVERRIDE=str(locked))
        return folder, db, env

    def storage_read(folder):
        status = (folder / 'fmhome' / 'state' / 'x.status').read_text()
        return [l for l in status.splitlines() if l.startswith('launch-gate ')], wakes(folder)

    def storage_rows():
        # P9 storage table: each row judges no start, the visible refusal and each line whose destination is writable;
        # nothing is claimed at an unwritable destination (rows 3 and 4: not claimed: destination unwritable).
        for row, first, status in ((1, True, True), (2, False, True), (3, False, False), (4, True, False)):
            folder, db, env = storage_case('gate-storage-row-%d' % row, first, status)
            child, log = gate(folder, env, 'x', mode='exit-0')
            finish(child, 75)
            text = stderr_of(log)
            assert 'launch-gate refused: hold bound reached: run x' in text and 'next action: ' in text, (row, text)
            assert not (folder / 'x.agent').exists(), (row, 'agent started')
            lines, queue = storage_read(folder)
            if first:
                assert 'launch-gate refused: hold bound reached: run x' in queue and 'next action: ' in queue, (row, queue)
            if status:
                assert len(lines) == 1 and 'hold bound reached' in lines[0] and 'next action: ' in lines[0], (row, lines)
                # Retention: with the first record drained (row 1) or unavailable (row 2), the status-log line keeps
                # the cause and the next action.
                (folder / 'fmhome' / 'state' / '.wake-queue').unlink(missing_ok=True)
                kept = storage_read(folder)[0]
                assert kept == lines and 'hold bound reached' in kept[0] and 'next action: ' in kept[0], (row, kept)
            if row in (3, 4):
                # Not claimed at the unwritable destination: no status-log line exists to judge.
                assert lines == [], (row, lines)
            (folder / 'fmhome' / 'state' / 'x.status').chmod(0o600)
            if not first:
                (folder / 'locked-state').chmod(0o700)

    def hold_without_first_record():
        # P9.visible: a hold that cannot write its line does not wait silently: with the first record unwritable on a
        # full host and a positive bound, the gate refuses visibly at once and the agent never starts; its status-log
        # line (row 2) carries the cause and the next action.
        folder, db, env = storage_case('gate-hold-unwritable', False, True)
        (folder / 'home' / '.no-mistakes' / 'config.yaml').write_text('agent: [claude]\nagent_timeout: "240m"\n')
        change(db, "UPDATE agent_invocations SET duration_ms = 60000, completed_at = started_at + 60")
        child, log = gate(folder, env, 'x')
        # A gate that held silently would hold to its bound, 14400 - 60 s, far past the hang backstop finish waits.
        finish(child, 75)
        text = stderr_of(log)
        assert 'launch-gate refused: hold line not recorded: run x' in text, text
        assert not (folder / 'x.agent').exists()
        lines = storage_read(folder)[0]
        assert len(lines) == 1 and 'hold line not recorded' in lines[0] and 'next action: ' in lines[0], lines
        (folder / 'locked-state').chmod(0o700)

    def hold_then_admit_lines():
        # P9.visible pair (7): on a normal hold and then admission with the first record writable, the hold line and the
        # admission-after-hold line are both written.
        folder, db, env = gate_case('gate-hold-admit-lines', available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
        child, log = gate(folder, env, 'x')
        wait_for(lambda: 'run x (fm/x) held for capacity before its ci agent starts' in wakes(folder), 'hold line')
        facts(folder, available=40 * GIB)
        wait_for(lambda: 'run x (fm/x) admitted after' in wakes(folder), 'admission-after-hold line')
        (folder / 'x.release').touch()
        finish(child)

    def outside_counted_refusal_text():
        # P9.disposition (Main 1838): a gated launch of a run outside the counted set refused at its hold bound says that
        # its run fails and that the owner restarts it, with both records written.
        folder, db, env = storage_case('gate-outside-counted-refusal', True, True)
        change(db, "UPDATE runs SET ci_ready_at = 1 WHERE id = 'x'")
        child, log = gate(folder, env, 'x', mode='exit-0')
        finish(child, 75)
        text = stderr_of(log)
        assert 'its run fails with it' in text and 'restart the run once capacity has returned' in text, text
        assert 'its run fails with it' in wakes(folder) and 'its run fails with it' in storage_read(folder)[0][0]

    def dispatcher_forwarding():
        # P9.hygiene: through a dispatcher (the agent command's own child, as tc run's spawnSync child is claude), a
        # SIGINT, SIGTERM or SIGHUP sent to the gate reaches the agent below the dispatcher: the gate signals its agent's
        # process group, not only its direct child (a gate that signals only the dispatcher leaves the agent running).
        dispatcher = root / 'dispatcher.py'
        dispatcher.write_text("""import os, pathlib, signal, sys, time
folder = pathlib.Path(os.environ['CASE_FOLDER'])
child = os.fork()
if child == 0:
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda n, f: (folder / ('below.got-%d' % n)).touch() or os._exit(0))
    (folder / 'below.ready').touch()
    while True: time.sleep(0.05)
os.waitpid(child, 0)
""")
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            folder, db, env = gate_case('gate-dispatcher-%d' % number)
            out, err = open(str(folder / 'gate.stdout'), 'w'), open(str(folder / 'gate.stderr'), 'w')
            child = subprocess.Popen(['bash', str(repo / 'bin/fm-cpu-pass.sh'), 'launch-gate', '--', python, str(dispatcher)],
                                     env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err, cwd=str(folder / 'wt-x'), start_new_session=True)
            out.close(); err.close()
            children.append(child)
            wait_for(lambda: (folder / 'below.ready').exists(), 'the agent below the dispatcher runs')
            os.kill(child.pid, number)
            wait_for(lambda: (folder / ('below.got-%d' % number)).exists(), 'signal %d reached the agent below the dispatcher' % number)
            wait_exit(child, 'the gate to exit after signal %d' % number, log=folder / 'gate')

    def outside_orphan(folder):
        # An unrelated orphan outside the launch coalition: started in its own session by a shell that exits, so its
        # parent becomes launchd and it is neither the test root's descendant nor a registered case process.
        # It lives until killed (orphan_present, or the finally below on a failure), so a slow decision cannot outlast it.
        marker = folder / 'outside.pid'
        subprocess.Popen(['/bin/sh', '-c', '(sleep 86400 & echo $! > %s) ; exit 0' % marker], start_new_session=True).wait()
        wait_for(lambda: marker.exists() and marker.read_text().strip(), 'the outside orphan started')
        pid = int(marker.read_text())
        orphan = (pid, start_us(pid))
        outside_orphans.append(orphan)
        return orphan

    def orphan_present(folder, orphan):
        # The control's own premise, checked after the decision: the orphan is alive, the same process, lineage lost and
        # outside the case's coalition (not registered), so the admission happened beside it.
        pid, started = orphan
        snapshot = engine().kernel_snapshot()
        registered = (folder.parent / 'coalition.pids').read_text().split() if (folder.parent / 'coalition.pids').exists() else []
        assert pid in snapshot and snapshot[pid][1] == started and snapshot[pid][0] == 1 and str(pid) not in registered, (
            'control premise: the outside orphan lives at the decision', pid, snapshot.get(pid))
        # Its coalition as the decision saw it, known and outside X's launch coalition: this test's engine() reads
        # coalitions through the same scope as the engine under test (fm_cpu_pass_fixture scope_coalition), so the
        # snapshot's value is already the scoped one, compared as it is.
        launch = {json.loads(path.read_text()).get('coalition') for path in (folder / 'pool').glob('attempt-*.json')
                  if not path.name.startswith('attempt-proof-')}
        seen = snapshot[pid][2]
        assert seen is not None and launch and None not in launch and seen not in launch, (
            'control premise: the orphan is in another coalition than the launch', seen, launch)
        os.kill(pid, signal.SIGKILL)
        outside_orphans.remove(orphan)

    def same_run_never_passes_its_live_attempt():
        # Main 1712 item 2 (review finding 2): X's first launch is live and unseen; a second launch of X decides with X as
        # its own run, nothing else counted. It waits (3 + 8 = 11 against 8.5) while the first lives, and starts by
        # itself once the first ends. Control: with no earlier attempt the same launch starts at once (8 against 8.5).
        folder, db, env = gate_case('m1712-same-run', available=int(8.5 * GIB), runs=[('x', 'ci', 'running', None)])
        facts(folder, available=int(8.5 * GIB))
        first, _ = gate(folder, env, 'x', log='first')
        wait_for(lambda: (folder / 'x.agent').exists(), 'the first launch runs')
        (folder / 'x.agent').unlink()
        second, _ = gate(folder, env, 'x', log='second')
        wait_for(lambda: 'waiting' in (folder / 'second.stderr').read_text() or (folder / 'x.agent').exists(), 'the second decides')
        time.sleep(1)
        harm('m1712-same-run-live', not (folder / 'x.agent').exists(), 'the second launch passed its own live first attempt', (folder / 'second.stderr').read_text())
        wait_for(lambda: 'x:launched:%d:unseen' % (3 * GIB) in (folder / 'second.stderr').read_text(), 'the first attempt counted at R')
        (folder / 'x.release').touch()
        finish(first)
        finish(second)
        folder, db, env = gate_case('m1712-same-run-first', available=int(8.5 * GIB), runs=[('x', 'ci', 'running', None)])
        facts(folder, available=int(8.5 * GIB))
        (folder / 'x.release').touch()
        finish(gate(folder, env, 'x')[0])
        # Main 1727: an earlier launch of X that is not shown ended (no row binds it) is no genuine first start either:
        # the launch waits (3 + 8 = 11 against 8.5), and starts once that launch is shown ended (8 against 8.5).
        folder, db, env = gate_case('m1712-same-run-unproven', available=int(8.5 * GIB), runs=[('x', 'ci', 'running', None)], proven=False)
        facts(folder, available=int(8.5 * GIB))
        child, log = gate(folder, env, 'x')
        wait_for(lambda: 'waiting' in log.with_suffix('.stderr').read_text() or (folder / 'x.agent').exists(), 'the launch decides')
        time.sleep(1)
        harm('m1727-same-run-unproven', not (folder / 'x.agent').exists(), 'the launch passed its own unproven earlier launch', log.with_suffix('.stderr').read_text())
        wait_for(lambda: 'x:ci-unproven:%d' % (3 * GIB) in log.with_suffix('.stderr').read_text(), 'the unproven launch counted at R')
        activate(folder, at=int(time.time()) - 1000)  # the activation record predates the run, and its launch is shown ended
        prove(folder, db, 'x')
        (folder / 'x.release').touch()
        finish(child)

    def live_attempt_after_run_stops():
        # Main 1712 item 6 (review finding 6): X's launch leaves a live orphan, then X's run stops running. The orphan
        # still holds X: a start that fits only without X's R (8 of 10 GiB) waits, X's record stays, and the start is
        # admitted by itself once the orphan exits (X's record is then removed). The orphan is a possible process of X
        # whose memory the reading does not join, so the wait names it as unknown (Main 1876 J); the fact twin holds
        # the numbers.
        folder, db, env = gate_case('m1712-run-stopped', available=40 * GIB, runs=[('x', 'ci', 'running', None)])
        child, _ = gate(folder, env, 'x', mode='escape')
        finish(child)
        change(db, "UPDATE runs SET status = 'completed' WHERE id = 'x'")
        facts(folder, available=10 * GIB)
        later = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later')
        wait_for(lambda: (folder / 'later').exists() or "could be run x's attempt and its memory is not joined" in (folder / 'later.stderr').read_text(),
                 'X held while its orphan lives', log=folder / 'later', child=later)
        harm('m1712-run-stopped', not (folder / 'later').exists(), 'a live attempt was dropped when its run stopped', (folder / 'later.stderr').read_text())
        (folder / 'x.escapee-release').touch()
        finish(later)
        wait_for(lambda: not [p for p in (folder / 'pool').glob('attempt-*.json') if 'proof' not in p.name], 'the ended record is removed')

    # Main 1656 (hold on anything short of proof): the outside review's counterexamples as failing-first cases.
    def escaped_descendant_holds():
        # F1 / the review's escape: X's agent leaves an orphaned descendant (own session, descriptors closed, an empty
        # environment) and exits. The descendant keeps X held, so a start that fits only without X's R waits; once it
        # exits, X ends and the start is admitted by itself. R = 3, S = 8: 10 GiB fits 8 and not 11. The escapee's
        # memory is not in the reading, so the wait names it as unknown (Main 1876 J).
        folder, db, env = gate_case('m1656-escape', available=10 * GIB, runs=[('x', 'ci', 'running', None)])
        child, log = gate(folder, env, 'x', mode='escape')
        finish(child)
        held = reserving_held(folder, ['x'])
        assert held == 1 and 'could be its' in held.reasons[0], repr(held)
        later = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later')
        held_back('m1656-escape', folder / 'later', folder / 'later.stderr')
        wait_for(lambda: "could be run x's attempt and its memory is not joined" in (folder / 'later.stderr').read_text(), 'X held while its escapee lives')
        (folder / 'x.escapee-release').touch()
        finish(later)
        wait_for(lambda: reserving_held(folder, ['x']) == 0, 'X ends once its escapee exits')

    def invocation_binding():
        # F2/F3 of the review, A3: rows A [10,40] and B [20,40] of run x with no session keys and two ended records: the
        # run is not released (it stays counted at R); the same rows with their own keys carried by ended records
        # release it; a key shared by two rows does not bind.
        for label, keys, records, released in (('no-keys', (None, None), (None, None), False),
                                               ('own-keys', ('aaaa', 'bbbb'), ('aaaa', 'bbbb'), True),
                                               ('shared-key', ('aaaa', 'aaaa'), ('aaaa', 'aaaa'), False),
                                               ('missing-record', ('aaaa', 'bbbb'), ('aaaa', None), False)):
            folder, db, env = gate_case('m1656-binding-' + label, available=10 * GIB, runs=[('x', 'ci', 'running', None)])
            with sqlite3.connect(db) as connection:
                connection.executemany('INSERT INTO agent_invocations (id, run_id, step_name, purpose, started_at, completed_at,'
                                       ' duration_ms, exit_status, session_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                                       [('A', 'x', 'ci', 'ci', 10, 40, 30000, 'ok', keys[0]), ('B', 'x', 'ci', 'ci', 20, 40, 20000, 'ok', keys[1])])
            (folder / 'pool').mkdir(exist_ok=True)
            gone = subprocess.Popen(['true']); gone.wait()
            for index, key in enumerate(records):
                (folder / 'pool' / ('attempt-r%d.json' % index)).write_text(json.dumps(dict(
                    id='r%d' % index, run='x', repo='repo', step='ci', reserves=True, t0_us=15000000 + index * 10000000,
                    root=[gone.pid, 1], gate=None, watcher=None, coalition=0, session_key=key, members=[], ended_us=1)))
            finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm')], env, folder / 'm'), 0) if released else None
            if released:
                assert 'x:ci-waiting:0' in (folder / 'm.stderr').read_text(), (label, (folder / 'm.stderr').read_text())
            else:
                child = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'm')], env, folder / 'm')
                held_back('m1656-key-binding-' + label, folder / 'm', folder / 'm.stderr')
                wait_for(lambda: 'x:ci-unproven' in (folder / 'm.stderr').read_text(), label + ': x stays counted, R per unproven launch')
                os.killpg(child.pid, signal.SIGKILL); child.wait()

    def copied_identity_holds():
        # Review F4 / r2 F1: X's orphan carries Y's attempt identity copied into its environment while Y is live; the
        # identity never moves it to Y: X stays held after Y ends, so a start that fits only without X's R waits
        # (R 3 + S 8 = 11 against 10 GiB), and is admitted by itself once the orphan exits. The orphan's memory is not
        # in the reading, so the wait names it as X's unknown (Main 1876 J).
        folder, db, env = gate_case('m1683-copied', available=40 * GIB, runs=[('x', 'ci', 'running', None), ('y', 'ci', 'running', None)])
        gate_y, _ = gate(folder, env, 'y')
        wait_for(lambda: (folder / 'y.agent').exists(), 'y runs')
        y_id = json.loads(next((folder / 'pool').glob('attempt-*.json')).read_text())['id']
        gate_x, _ = gate(folder, dict(env, CASE_COPIED_IDENTITY=y_id), 'x', mode='escape')
        finish(gate_x)
        (folder / 'y.release').touch()
        finish(gate_y)
        facts(folder, available=10 * GIB)
        later = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later')
        held_back('m1683-copied-identity', folder / 'later', folder / 'later.stderr')
        wait_for(lambda: "could be run x's attempt and its memory is not joined" in (folder / 'later.stderr').read_text(), 'X held while its orphan lives')
        (folder / 'x.escapee-release').touch()
        finish(later)

    def foreign_orphan_in_coalition_by_admission():
        # Amended x/y (Main 1656): Y's orphan inside the launch coalition outlives X. The oracle is the admission alone:
        # with room for one new start beside nothing (8 of 12 GiB), the start waits while both X and Y are counted
        # (3 + 3 + 8 = 14) and is admitted once the orphan exits. The orphan's memory is not in the reading: the wait
        # names it as unknown for X and for Y, each owner on its own (Main 1876 J, E).
        folder, db, env = gate_case('m1683-foreign-in', available=40 * GIB, runs=[('x', 'ci', 'running', None), ('y', 'ci', 'running', None)])
        gate_x, _ = gate(folder, env, 'x')
        wait_for(lambda: (folder / 'x.agent').exists(), 'x runs')
        gate_y, _ = gate(folder, env, 'y', mode='escape')
        finish(gate_y)
        (folder / 'x.release').touch()
        finish(gate_x)
        facts(folder, available=12 * GIB)
        later = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later')
        wait_for(lambda: "could be run y's attempt and its memory is not joined" in (folder / 'later.stderr').read_text(), 'Y held')
        text = (folder / 'later.stderr').read_text()
        harm('m1683-foreign-in', not (folder / 'later').exists() and "could be run x's attempt and its memory is not joined" in text
             and "could be run y's attempt and its memory is not joined" in text, 'each of X and Y holds', text)
        (folder / 'y.escapee-release').touch()
        finish(later)

    def outside_orphan_fitting_start():
        # Control: an orphan outside the launch coalition, started after X, holds nothing: a start that fits only
        # without X's R (8 of 10 GiB) is admitted at once after X's agent ends.
        folder, db, env = gate_case('m1683-foreign-out', available=40 * GIB, runs=[('x', 'ci', 'running', None)])
        gate_x, _ = gate(folder, env, 'x')
        wait_for(lambda: (folder / 'x.agent').exists(), 'x runs')
        orphan = outside_orphan(folder)
        (folder / 'x.release').touch()
        finish(gate_x)
        facts(folder, available=10 * GIB)
        finish(launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later'))
        assert (folder / 'later').exists()
        orphan_present(folder, orphan)

    def reuse_join_boundary():
        # Review F4b: X's run shows 10 GiB in the reading under X's own pid but another generation's start time (same
        # second). The refused join counts X unseen at R beside the 10 GiB of its run: 3 + 10 + 8 = 21 against
        # 8.5 + 10 = 18.5, wait. A second-rounded join would credit the 10 GiB to the attempt: 10 + 8 = 18, admit.
        # Control: the exact start time joins, 18 against 18.5, admit.
        for label, offset, admits in (('reused', 500000, False), ('same-generation', 0, True)):
            folder, db, env = gate_case('m1683-join-' + label, available=40 * GIB, runs=[('x', 'ci', 'running', None)])
            child, log = gate(folder, env, 'x')
            wait_for(lambda: (folder / 'x.agent').exists(), 'x runs')
            agent_pid = agent_info(folder / 'x.agent')['pid']
            exact = start_us(agent_pid)
            started = exact - exact % 1000000 + (exact % 1000000 + offset) % 1000000
            facts(folder, available=int(8.5 * GIB), runs=[('repo', 'x', 10 * GIB, agent_pid, started)])
            later = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later')
            if admits:
                finish(later)
            else:
                held_back('m1683-pid-reuse', folder / 'later', folder / 'later.stderr')
                wait_for(lambda: 'projected=%d ' % (21 * GIB) in (folder / 'later.stderr').read_text(), label + ': unseen, 21 GiB')
                os.killpg(later.pid, signal.SIGKILL); later.wait()
            (folder / 'x.release').touch()
            finish(child)

    def p1f_own_live_versus_foreign():
        # P1(f) pair (Main 1645 F5): CI run x's launch printed its own session id, which the gate recorded and the
        # daemon's row carries. Own-live: the launch left a live orphan, so x stays counted at R and a start that fits
        # only without it (8 of 10 GiB) waits. Foreign: the launch ended cleanly and only an unrelated orphan outside the
        # coalition lives: x is released and the start is admitted.
        import hashlib
        for label, mode in (('own-live', 'escape'), ('foreign', 'exit-0')):
            folder, db, env = gate_case('m1683-p1f-' + label, available=40 * GIB, runs=[('x', 'ci', 'running', None)])
            key = hashlib.sha256(('session-' + label).encode()).hexdigest()[:16]
            change(db, "INSERT INTO agent_invocations (id, run_id, step_name, purpose, started_at, completed_at, duration_ms,"
                       " exit_status, session_key) VALUES ('own', 'x', 'ci', 'ci', 1, 2, 1000, 'ok', ?)", (key,))
            gate_x, _ = gate(folder, dict(env, CASE_SESSION_ID='session-' + label), 'x', mode=mode)
            finish(gate_x)
            if label == 'foreign':
                orphan = outside_orphan(folder)
            facts(folder, available=10 * GIB)
            later = launch(cli + ['pipeline-start', '--', 'touch', str(folder / 'later')], env, folder / 'later')
            if label == 'foreign':
                finish(later)
                assert 'x:ci-waiting:0' in (folder / 'later.stderr').read_text(), (folder / 'later.stderr').read_text()
                orphan_present(folder, orphan)
            else:
                held_back('m1683-p1f-own-live', folder / 'later', folder / 'later.stderr')
                wait_for(lambda: "could be run x's attempt and its memory is not joined" in (folder / 'later.stderr').read_text(), 'x held while its orphan lives')
                (folder / 'x.escapee-release').touch()
                finish(later)

    for name, body in (('P9.scope unknown steps refuse', unknown_steps), ('P9.scope uncounted runs are gated', uncounted_gated),
                       ('P9.map identified shape', identified_shape), ('P9.bound round start and zero hold', bound_from_round_start),
                       ('P9.bound held rows', held_row_cases), ('P9.bound hold record', hold_record_written),
                       ('P9 storage table rows 1-4 with retention', storage_rows),
                       ('P9.visible a hold with no first record refuses visibly', hold_without_first_record),
                       ('P9.visible hold and admission-after-hold lines', hold_then_admit_lines),
                       ('P9.disposition outside-counted refusal names the run failing', outside_counted_refusal_text),
                       ('P9.hygiene a signal reaches the agent below a dispatcher', dispatcher_forwarding),
                       ('Main 1656 an escaped descendant holds its attempt', escaped_descendant_holds),
                       ('Main 1683 a copied identity never moves X\'s orphan to Y', copied_identity_holds),
                       ('Main 1683 a foreign in-coalition orphan delays admission (amended x/y)', foreign_orphan_in_coalition_by_admission),
                       ('Main 1683 an orphan outside the coalition leaves a fitting start admitted', outside_orphan_fitting_start),
                       ('Main 1656 only a row\'s own session key binds it', invocation_binding),
                       ('Main 1683 a reused pid never credits another generation', reuse_join_boundary),
                       ('Main 1683 P1(f) own-live waits, foreign admits', p1f_own_live_versus_foreign),
                       ('Main 1712 a same-run launch never passes its live or unproven attempt', same_run_never_passes_its_live_attempt),
                       ('Main 1712 a live attempt counts after its run stops running', live_attempt_after_run_stops)):
        r28_case(name, body)
    (root / 'r28-gate.json').write_text(json.dumps(r28, indent=2))
    print(json.dumps(dict(r28=r28)), flush=True)
    group_done(r28)

    print(json.dumps(dict(result='pass', artifacts=str(root), invocations=records)), flush=True)
finally:
    try:
        for pid, started in outside_orphans:
            if start_us(pid) == started:
                os.kill(pid, signal.SIGKILL)
    finally:
        cleanup()
