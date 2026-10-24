#!/usr/bin/env python3
"""Live smoke for the removed work-killing time limits.

Drives the real firstmate scripts (real fm-watch-arm.sh, real fm-watch.sh
watcher processes, real fm-watchdog-check.sh, real fm-crew-state.sh) against a
disposable marked lab home. Run once with the change's bin and once with the
base commit's bin to show the before/after behavior.

usage: live-smoke.py <bin-dir> <label> <worktree-bin-for-lab-helper> [scenario...]
"""
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BIN = Path(sys.argv[1]).resolve()
LABEL = sys.argv[2]
LAB_HELPER = Path(sys.argv[3]).resolve() / 'fm-lab-home.sh'
ONLY = set(sys.argv[4:])
results = []


def log(msg):
    print(f'[{LABEL}] {msg}', flush=True)


def lab():
    d = tempfile.mkdtemp(prefix='fm-lab.', dir=os.environ.get('TMPDIR', '/tmp'))
    subprocess.run(['bash', str(LAB_HELPER), 'create', d], check=True, capture_output=True)
    home = Path(d).resolve()
    for c in ('state', 'data', 'config', 'projects'):
        (home / c).mkdir(exist_ok=True)
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    env = {k: v for k, v in os.environ.items()
           if not (k.endswith('_OVERRIDE') and k.startswith('FM_'))}
    for k in ('FM_ARM_CONFIRM_TIMEOUT', 'FM_GATE_REFUSE_BYPASS'):
        env.pop(k, None)
    env.update(FM_HOME=str(home), FM_DURATION_FILE='off', FM_POLL='1', FM_SIGNAL_GRACE='0',
               FM_CHECK_INTERVAL='999999', FM_REVIEW_AGENT_SELECT_BIN='/usr/bin/true')
    return home, env


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False
    except PermissionError:
        return True


def lock_pid(home):
    try:
        return int((home / 'state/.watch.lock/pid').read_text().strip())
    except Exception:
        return None


def start_arm(home, env):
    """Real arm forks a real watcher; return (arm process, first stdout line, seconds)."""
    t0 = time.monotonic()
    p = subprocess.Popen(['bash', str(BIN / 'fm-watch-arm.sh')], env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, start_new_session=True)
    first = p.stdout.readline()
    return p, first.rstrip(), time.monotonic() - t0


def teardown(home, procs=()):
    for p in procs:
        if p is not None and p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except Exception:
                pass
            p.wait()
    pid = lock_pid(home)
    if pid and alive(pid):
        try:
            os.kill(pid, signal.SIGCONT)
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
    shutil.rmtree(home, ignore_errors=True)


def record(name, ok, detail):
    results.append((name, ok))
    log(('PASS ' if ok else 'FAIL ') + name + ' :: ' + detail)


def age_beacon(home, seconds):
    t = time.time() - seconds
    os.utime(home / 'state/.last-watcher-beat', (t, t))


def scenario_slow_start():
    """Watcher startup on a starved host, with the DEFAULT confirmation window.

    The arm's whole process group is duty-cycled (SIGCONT 0.6% / SIGSTOP 99.4%),
    which is what a load-40..100 host does to a startup: it still advances,
    slowly. Old code: TERM the still-starting watcher after 10 s
    (reason=confirmation-timeout). New code: the start completes.
    """
    import threading
    home, env = lab()
    env['FM_HEARTBEAT'] = '999999'
    arm = None
    stop = threading.Event()
    try:
        t0 = time.monotonic()
        arm = subprocess.Popen(['bash', str(BIN / 'fm-watch-arm.sh')], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               start_new_session=True)
        def throttle():
            while not stop.is_set():
                try:
                    os.killpg(arm.pid, signal.SIGCONT)
                    time.sleep(0.006)
                    if stop.is_set():
                        break
                    os.killpg(arm.pid, signal.SIGSTOP)
                    time.sleep(0.994)
                except (ProcessLookupError, PermissionError):
                    break
            try:
                os.killpg(arm.pid, signal.SIGCONT)
            except (ProcessLookupError, PermissionError):
                pass
        th = threading.Thread(target=throttle)
        th.start()
        first = arm.stdout.readline().rstrip()
        took = time.monotonic() - t0
        stop.set()
        th.join()
        ok = first.startswith('watcher: started pid=')
        if ok:
            st = home / 'state/smoke.status'
            st.write_text('done: smoke\n')
            out, err = arm.communicate(timeout=120)
            ok = arm.returncode == 0 and f'signal: {st}' in out
            first += ' | ' + out.strip().replace('\n', ' / ')
        else:
            out, err = arm.communicate(timeout=60)
            first += ' | ' + out.strip().replace('\n', ' / ') + ' | rc=' + str(arm.returncode)
        ledger = (home / 'state/.watch-cycle-exits.log').read_text() if (home / 'state/.watch-cycle-exits.log').exists() else ''
        reasons = sorted({w for line in ledger.splitlines() for w in line.split() if w.startswith('reason=')})
        record('starved_start_under_default_window_completes', ok and 'reason=confirmation-timeout' not in ledger,
               f'first-line-after={took:.1f}s {first} ledger-reasons={reasons}')
    finally:
        stop.set()
        teardown(home, [arm])


def held_watcher(extra=None):
    home, env = lab()
    env.update(FM_HEARTBEAT='999999', FM_WATCHER_STALE_GRACE='1', FM_GUARD_GRACE='1',
               FM_WATCHER_STALL_BOUND='2', FM_ARM_ATTACH_POLL='0.2')
    if extra:
        env.update(extra)
    arm, first, took = start_arm(home, env)
    pid = lock_pid(home)
    return home, env, arm, first, pid


def beacon_age(home):
    return int(time.time() - (home / 'state/.last-watcher-beat').stat().st_mtime)


def scenario_contender_old_beacon():
    """A contender meets a live, running real watcher whose beacon is an hour old.

    Grace 300 s keeps the real watcher's own beat interval at 15 s, so the old
    beacon is what each contender reads (its age is logged right before each
    run). Stall bound 2 s, three contenders 2.5 s apart, so later samples span
    more than the bound. Old code: TERM on beacon age alone. New code: the
    watcher's process tree keeps using CPU, so no sample proves a stall.
    """
    home, env, arm, first, pid = held_watcher({'FM_WATCHER_STALE_GRACE': '300', 'FM_GUARD_GRACE': '300'})
    try:
        if not (first.startswith('watcher: started') and pid and alive(pid)):
            record('contender_keeps_running_old_beacon_watcher', False, 'setup: ' + first)
            return
        old = time.time() - 3600
        runs = []
        ok = True
        for i in range(3):
            os.utime(home / 'state/.last-watcher-beat', (old, old))
            before = beacon_age(home)
            r = subprocess.run(['bash', str(BIN / 'fm-watch.sh')], env=env, capture_output=True, text=True, timeout=60)
            after = beacon_age(home)
            runs.append(f'run{i+1}: beacon {before}s->{after}s rc={r.returncode} out={r.stdout.strip()!r} '
                        f'err={r.stderr.strip()[-160:]!r} holder-alive={alive(pid)}')
            ok = ok and before >= 300 and alive(pid) and r.returncode == 0 and 'already running' in r.stdout
            if not alive(pid):
                break
            time.sleep(2.5)
        record('contender_keeps_running_old_beacon_watcher', ok and lock_pid(home) == pid,
               f'holder pid={pid}; ' + ' ; '.join(runs) + f' ; lock-pid={lock_pid(home)}')
    finally:
        teardown(home, [arm])


def scenario_term_survivor_then_recovery():
    """A real watcher frozen with SIGSTOP (no CPU, no beacon) and an old beacon.

    First contender sample: no proof yet, reported running. After the bound the
    second sample proves the stall and sends TERM; a stopped process cannot act
    on TERM, so it survives and the contender must refuse with a nonzero exit.
    After SIGCONT the pending TERM ends it and a fresh arm starts a new watcher.
    """
    home, env, arm, first, pid = held_watcher()
    arm2 = None
    try:
        if not (first.startswith('watcher: started') and pid and alive(pid)):
            record('term_survivor_refused_then_recovered', False, 'setup: ' + first)
            return
        os.kill(pid, signal.SIGSTOP)
        age_beacon(home, 3600)
        r1 = subprocess.run(['bash', str(BIN / 'fm-watch.sh')], env=env, capture_output=True, text=True, timeout=60)
        time.sleep(2.5)
        r2 = subprocess.run(['bash', str(BIN / 'fm-watch.sh')], env=env, capture_output=True, text=True, timeout=120)
        survived_term = alive(pid)
        os.kill(pid, signal.SIGCONT)
        for _ in range(100):
            if not alive(pid):
                break
            time.sleep(0.1)
        died = not alive(pid)
        if arm.poll() is None:
            try:
                arm.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                pass
        arm2, first2, _ = start_arm(home, env)
        new_pid = lock_pid(home)
        if first2 == 'check: rearm-resurface':
            # The fresh watcher ran and immediately woke the session about the
            # predecessor's downtime; its cycle ledger row names its pid.
            arm2.communicate(timeout=60)
            ledger = (home / 'state/.watch-cycle-exits.log').read_text()
            first2 += ' | ledger tail: ' + ledger.strip().splitlines()[-1]
            fresh = f'pid={pid} ' not in ledger.strip().splitlines()[-1] and 'reason=actionable-signal' in ledger.strip().splitlines()[-1]
        else:
            fresh = first2.startswith('watcher: started') and new_pid and new_pid != pid
        ok = (r1.returncode == 0 and 'already running' in r1.stdout
              and r2.returncode != 0 and 'already running' not in r2.stdout
              and survived_term and died and fresh)
        record('term_survivor_refused_then_recovered', ok,
               f'sample1 rc={r1.returncode} out={r1.stdout.strip()!r}; '
               f'sample2 rc={r2.returncode} out={r2.stdout.strip()!r} err={r2.stderr.strip()[-200:]!r}; '
               f'survived-TERM-while-stopped={survived_term} ended-after-SIGCONT={died}; '
               f'fresh arm: {first2!r} new-pid={new_pid}')
    finally:
        teardown(home, [arm, arm2])


def scenario_watchdog_old_beacon():
    """Watchdog with its default 900 s policy sees a live real watcher, beacon 904+ s old.

    This is the 10-22/10-23 state/.watchdog.log stop. Old code: --stop the
    watcher. New code: an old beacon alone is not proof; the watcher stays.
    """
    home, env, arm, first, pid = held_watcher({'FM_WATCHER_STALE_GRACE': '300', 'FM_GUARD_GRACE': '300',
                                               'FM_WATCHER_STALL_BOUND': '2700'})
    session = subprocess.Popen(['bash', '-c', 'exec -a claude /bin/sleep 300'])
    try:
        if not (first.startswith('watcher: started') and pid and alive(pid)):
            record('watchdog_keeps_old_beacon_watcher', False, 'setup: ' + first)
            return
        (home / 'state/task.meta').write_text('window=fm:fm-task\nkind=ship\n')
        (home / 'state/.lock').write_text(f'{session.pid}\n')
        age_beacon(home, 976)
        wenv = dict(env, FM_SUPERVISION_MODEL='persistent', FM_WATCHDOG_VERIFY_SECS='2')
        before = beacon_age(home)
        r = subprocess.run(['bash', str(BIN / 'fm-watchdog-check.sh')], env=wenv, capture_output=True,
                           text=True, timeout=180)
        after = beacon_age(home)
        time.sleep(0.5)
        wlog = (home / 'state/.watchdog.log').read_text() if (home / 'state/.watchdog.log').exists() else ''
        tail = ' / '.join(wlog.strip().splitlines()[-4:])
        record('watchdog_keeps_old_beacon_watcher', before >= 900 and alive(pid) and lock_pid(home) == pid,
               f'watcher pid={pid} beacon {before}s before / {after}s after the check; watchdog rc={r.returncode} out={r.stdout.strip()!r}; '
               f'watcher alive={alive(pid)}; log tail: {tail[-500:]!r}')
    finally:
        session.kill()
        session.wait()
        teardown(home, [arm])


def scenario_watchdog_proven_stall():
    """Watchdog still stops a real watcher that is proven frozen (SIGSTOP: no CPU, no beacon).

    Bound shrunk to 2 s so the proof fits the run. The frozen watcher cannot act
    on TERM until it is continued, so the smoke continues it shortly after the
    watchdog logs its evidence-based stop decision; the pending TERM then ends it.
    """
    home, env, arm, first, pid = held_watcher({'FM_WATCHER_STALE_GRACE': '300', 'FM_GUARD_GRACE': '300',
                                               'FM_WATCHER_STALL_BOUND': '2700'})
    session = subprocess.Popen(['bash', '-c', 'exec -a claude /bin/sleep 300'])
    try:
        if not (first.startswith('watcher: started') and pid and alive(pid)):
            record('watchdog_stops_proven_frozen_watcher', False, 'setup: ' + first)
            return
        (home / 'state/task.meta').write_text('window=fm:fm-task\nkind=ship\n')
        (home / 'state/.lock').write_text(f'{session.pid}\n')
        os.kill(pid, signal.SIGSTOP)
        age_beacon(home, 976)
        wenv = dict(env, FM_SUPERVISION_MODEL='persistent', FM_WATCHDOG_VERIFY_SECS='2',
                    FM_WATCHDOG_STALE_SECS='2')
        r1 = subprocess.run(['bash', str(BIN / 'fm-watchdog-check.sh')], env=wenv, capture_output=True,
                            text=True, timeout=180)
        alive_after_first = alive(pid)
        time.sleep(2.5)
        wlog_path = home / 'state/.watchdog.log'
        p2 = subprocess.Popen(['bash', str(BIN / 'fm-watchdog-check.sh')], env=wenv, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and p2.poll() is None:
            text = wlog_path.read_text() if wlog_path.exists() else ''
            if 'stopping watcher pid=' in text or 'stopping the stale watcher' in text:
                break
            time.sleep(0.05)
        time.sleep(1.5)
        os.kill(pid, signal.SIGCONT)
        out2, err2 = p2.communicate(timeout=180)
        for _ in range(50):
            if not alive(pid):
                break
            time.sleep(0.1)
        wlog = wlog_path.read_text() if wlog_path.exists() else ''
        evidence = [line for line in wlog.splitlines() if 'stopping' in line or 'stopped' in line
                    or 'retained' in line or 'preserving' in line]
        record('watchdog_stops_proven_frozen_watcher',
               alive_after_first and not alive(pid) and 'no CPU or beacon progress' in wlog,
               f'run1 rc={r1.returncode} out={r1.stdout.strip()!r} watcher-alive-after-run1={alive_after_first}; '
               f'run2 rc={p2.returncode} out={out2.strip()!r}; watcher alive now={alive(pid)}; '
               f'log: {" / ".join(evidence)[-600:]!r}')
    finally:
        try:
            os.kill(pid, signal.SIGCONT)
        except Exception:
            pass
        session.kill()
        session.wait()
        teardown(home, [arm])


def scenario_crew_state_slow_read():
    """Crew-state with its default no-mistakes read policy; the read takes ~14 s of CPU.

    Matches d3-analytical 10-21 (13.8 s / 15.2 s / 14.9 s against default 10 s).
    The no-mistakes CLI is a disposable stand-in for that external dependency;
    fm-crew-state.sh itself is real and unmodified.
    """
    home, env = lab()
    fake = home / 'fakebin'
    fake.mkdir()
    wt = home / 'projects/task'
    wt.mkdir(parents=True)
    for args in (['init', '-q'], ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                                'commit', '--allow-empty', '-qm', 'fixture'], ['checkout', '-qb', 'fm/slow']):
        subprocess.run(['git', '-C', str(wt), *args], check=True, capture_output=True)
    head = subprocess.check_output(['git', '-C', str(wt), 'rev-parse', 'HEAD'], text=True).strip()
    (home / 'state/slow.meta').write_text(f'window=fm:fm-slow\nkind=ship\nharness=claude\nworktree={wt}\n')
    answer = (f'run:\n  id: "01SLOW"\n  branch: fm/slow\n  status: running\n  head: "{head}"\n  pr: ""\n'
              '  findings: none\n  steps[2]{step,status,findings,duration_ms}:\n'
              '    intent,completed,0,0\n    review,running,0,0\n')
    (fake / 'no-mistakes').write_text('#!/usr/bin/env bash\npython3 - <<\'SLOW\'\nimport time\n'
                                      'until = time.monotonic() + 14\nwhile time.monotonic() < until:\n'
                                      '    sum(i*i for i in range(1000))\n'
                                      f'print({answer!r})\nSLOW\n')
    (fake / 'no-mistakes').chmod(0o755)
    (fake / 'tmux').write_text('#!/usr/bin/env bash\nexit 1\n')
    (fake / 'tmux').chmod(0o755)
    env.pop('FM_CREW_STATE_NM_TIMEOUT', None)
    env['PATH'] = str(fake) + ':' + env['PATH']
    try:
        t0 = time.monotonic()
        r = subprocess.run(['bash', str(BIN / 'fm-crew-state.sh'), 'slow'], env=env, capture_output=True,
                           text=True, timeout=300)
        took = time.monotonic() - t0
        ok = 'state: working' in r.stdout and 'source: run-step' in r.stdout and 'skipped' not in r.stdout
        record('crew_state_14s_read_is_authoritative', ok,
               f'{took:.1f}s rc={r.returncode} out={r.stdout.strip()!r} err={r.stderr.strip()[-200:]!r}')
    finally:
        teardown(home)


SCENARIOS = {
    'slow_start': scenario_slow_start,
    'contender': scenario_contender_old_beacon,
    'term_survivor': scenario_term_survivor_then_recovery,
    'watchdog': scenario_watchdog_old_beacon,
    'watchdog_stall': scenario_watchdog_proven_stall,
    'crew': scenario_crew_state_slow_read,
}
for key, fn in SCENARIOS.items():
    if ONLY and key not in ONLY:
        continue
    try:
        fn()
    except Exception as error:
        record(key, False, f'exception {type(error).__name__}: {error}')
log('summary: ' + ', '.join(f'{n}={"PASS" if ok else "FAIL"}' for n, ok in results))
