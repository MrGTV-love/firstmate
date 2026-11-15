#!/usr/bin/env python3
"""Attribution and pending-start decision cases for fm-cpu-pass.test.sh: the engine's own functions on fixed facts.

Each case feeds bin/fm-cpu-pass.py's kernel_snapshot, judge_attempts, attempt_reservations, bound_runs, project,
admission, live_pending and claim_round with in-memory facts (a fake process table at the fm-proc-info boundary,
a fake run database at read_host_db, real attempt and pending files in a scratch pool), the shape of the outside
reviews' falsifiers (Main 1683, Main 1712), and asserts the decision at an admit-versus-wait boundary: R = 3, S = 8
and A = 1 GiB, 8.5 GiB available unless stated. The assertion that guards against the harm a case names raises
"harm: ..."; a compliant twin's assertion raises "control: ...", so a red run can be told from an error.
Usage: fm-cpu-pass-attribution.py REPO SCRATCH; prints JSON; exits 1 on any failure. Starts no process and sends
no signal.
"""
import importlib.util
import json
import os
import struct
import sys
import tempfile
from pathlib import Path

repo, scratch = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
GIB = 2 ** 30
R, S, A = 3 * GIB, 8 * GIB, GIB


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


info = load('fm_proc_info', repo / 'bin' / 'fm-proc-info.py')
engine = load('fm_cpu_pass_under_test', repo / 'bin' / 'fm-cpu-pass.py')
REAL = {name: getattr(info, name) for name in ('kinfos', 'kinfo', 'coalition', 'sysctl') if hasattr(info, name)}
if hasattr(info, 'kinfo_exact'):
    REAL['kinfo_exact'] = info.kinfo_exact
engine.sibling = lambda module, filename: info
GONE = getattr(info, 'NoSuchProcess', LookupError)


def harm(condition, *detail):
    if not condition:
        raise AssertionError('harm: ' + repr(detail))


def control(condition, *detail):
    if not condition:
        raise AssertionError('control: ' + repr(detail))


def record(pid, parent, start_us, zombie=False, traced=False):
    """A kinfo_proc record of the size and field offsets bin/fm-proc-info.py reads."""
    data = bytearray(info.KINFO_SIZE)
    struct.pack_into('qq', data, info.P_START, start_us // 1000000, start_us % 1000000)
    struct.pack_into('i', data, info.P_PID, pid)
    struct.pack_into('i', data, info.E_PPID, parent)
    struct.pack_into('i', data, info.P_FLAG, getattr(info, 'P_TRACED', 0x800) if traced else 0)
    data[info.P_STAT] = info.SZOMB if zombie else 2
    return bytes(data)


class Kernel:
    """Fake process facts at the fm-proc-info boundary.

    processes: pid -> (parent, start); coalitions: pid -> coalition; confirm: pid -> what the confirming per-pid
    read gives: an exception to raise, a (parent, start) pair for another generation, or bytes to return raw.
    """

    def __init__(self, processes, coalitions, confirm=None):
        self.processes, self.coalitions, self.confirm = processes, coalitions, confirm or {}

    def per_pid(self, pid):
        action = self.confirm.get(pid)
        if isinstance(action, BaseException):
            raise action
        if isinstance(action, tuple):
            return record(pid, *action)
        if pid not in self.processes:
            raise GONE(pid)
        return record(pid, *self.processes[pid])

    def install(self):
        info.kinfos = lambda *selector: iter([record(pid, parent, start) for pid, (parent, start) in self.processes.items()])
        info.coalition = lambda pid: self.coalitions.get(pid)
        info.kinfo = self.per_pid
        info.kinfo_exact = self.per_pid
        return self


def real_kernel():
    for name, value in REAL.items():
        setattr(info, name, value)


def database(invocations=(), runs=None):
    """Fake run database for read_host_db: agent_invocations rows (run_id, session_key); runs: id -> (nonce, repo)."""
    runs = runs or {}

    def read(sql, parameters=()):
        if 'FROM agent_invocations' in sql:
            wanted = set(parameters)
            return [(run, key) for run, key in invocations if run in wanted]
        if 'launch_nonce FROM runs' in sql:
            wanted = set(parameters)
            return [(run, value[0]) for run, value in runs.items() if run in wanted]
        if "FROM runs WHERE status = 'running'" in sql:
            return [(run, value[1], 1, 0) for run, value in runs.items()]
        if 'FROM runs' in sql or 'FROM repos' in sql:
            return []
        raise AssertionError('unexpected query ' + sql)
    engine.read_host_db = read


def pool(records, broken=()):
    directory = Path(tempfile.mkdtemp(prefix='pool-', dir=str(scratch)))
    for name, value in records.items():
        (directory / ('attempt-%s.json' % name)).write_text(json.dumps(value))
    for name in broken:
        (directory / ('attempt-%s.json' % name)).write_text('{not json')
    return str(directory)


def attempt(run='x', t0=100000000, root=(10, 90000000), coalition=7, key='own-key', ended=None, members=(), reserves=True):
    return dict(id=run, run=run, repo='repo', step='ci', reserves=reserves, t0_us=t0, root=list(root), gate=None, watcher=None,
                coalition=coalition, session_key=key, members=[list(m) for m in members], ended_us=ended)


def decide(directory, running, counted, steps, rows, available=8.5 * GIB, waiting=frozenset(), rss=None, processes=(),
           self_run=None):
    database(rows)
    states = engine.judge_attempts(directory, set(running))
    report = dict(processes=list(processes))
    launches, held_runs = engine.attempt_reservations(states, report)
    ci_runs = {run for run in counted if steps.get(run) and steps[run][0] == 'ci'}
    bound = engine.bound_runs(states, ci_runs)
    fit = engine.project(int(available), rss or {}, counted, steps, launches, R, S, A, self_run, frozenset(waiting),
                         held_runs=held_runs, bound=bound)
    return dict(admit=fit['admit'], projected=fit['projected'] / GIB, budget=fit['budget'] / GIB,
                kinds={run: kind for run, kind, _, _ in fit['entries']},
                states={os.path.basename(s['path']): s['state'] for s in states.values()})


CI = {'x': ('ci', 'running', None, None)}
results = {}


def case(name, body):
    try:
        body()
        results[name] = 'pass'
    except Exception as exc:  # noqa: BLE001 - every case is reported
        results[name] = 'FAIL: %s: %s' % (type(exc).__name__, str(exc)[:600])
    finally:
        real_kernel()


# Main 1683 cases, kept.

def f1_unreadable_confirming_read():
    # A live orphan (pid 42, born after X's t0) whose coalition is unreadable; the confirming read raises
    # PermissionError. Unreadable is not proof of exit: X stays held and the start waits (11 against 8.5).
    for label, confirm in (('readable', None), ('permission-error', PermissionError(1, 'denied'))):
        Kernel({42: (1, 101000000), 200: (1, 50000000)}, {200: 9}, {42: confirm} if confirm else {}).install()
        out = decide(pool({'x': attempt()}), {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
        harm(not out['admit'] and out['projected'] == 11, label, out)


def f2_unreadable_record():
    # An unreadable attempt record: a parked run's live gated attempt (outside the counted set), and a counted CI run
    # whose second, live attempt cannot be read beside an ended first attempt bound to its row. Both wait.
    Kernel({42: (1, 101000000)}, {42: 7}).install()
    out = decide(pool({}, broken=('live',)), {'x'}, {}, {}, [])
    harm(not out['admit'] and out['projected'] == 11, 'parked', out)
    out = decide(pool({'first': attempt(ended=1)}, broken=('second',)), {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
    harm(not out['admit'], 'counted', out)


def f6_unknown_launch_coalition():
    # X's launch coalition was unreadable when it was recorded; a possible orphan (pid 42, coalition 7, born after
    # t0) is not proven outside it: X stays held, the start waits (11 against 8.5); with coalition 7 recorded, the same.
    for label, coalition in (('recorded', 7), ('unknown', None)):
        Kernel({42: (1, 101000000)}, {42: 7}).install()
        out = decide(pool({'x': attempt(coalition=coalition)}), {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
        harm(not out['admit'] and out['projected'] == 11, label, out)


def f7_waiter_keeps_unproven():
    # A counted CI run whose earlier launch cannot be shown ended keeps its full R while a later fix of it waits.
    Kernel({}, {}).install()
    for waiting in (frozenset(), frozenset({'x'})):
        out = decide(pool({}), {'x'}, {'x': 'repo'}, CI, [('x', None)], waiting=waiting)
        harm(not out['admit'] and out['projected'] == 11, sorted(waiting), out)


def f8_every_owner_kept():
    # X records pid 42 (start 200) as a member; Y records the same identity as its root. Both stay held.
    Kernel({42: (1, 200)}, {42: 7}).install()
    out = decide(pool({'x': attempt(run='x', t0=100, members=[(42, 200)]), 'y': attempt(run='y', t0=150, root=(42, 200))}),
                 {'x', 'y'}, {'x': 'repo', 'y': 'repo'}, {}, [])
    harm(out['states'] == {'attempt-x.json': 'held', 'attempt-y.json': 'held'}, out)


def read_source_one_generation():
    # Main 1656 item 4: a memory figure is attributed to one process generation only when its start time is the same
    # before and after the memory read; a changed start marks the figure unstable, never task.
    load('fm_proc_info_read', repo / 'bin' / 'fm-proc-info.py')
    reader = sys.modules['fm_proc_info_read']
    mine = os.getpid()
    original = next(r for r in reader.kinfos() if struct.unpack_from('i', r, reader.P_PID)[0] == mine)
    reader.kinfos = lambda *selector: iter([original])
    seconds, micros = reader.process_identity(original)
    later = bytearray(original)
    struct.pack_into('qq', later, reader.P_START, seconds, (micros + 1) % 1000000)
    for label, after, expected in (('same', original, 'task'), ('changed', bytes(later), 'unstable')):
        reader.kinfo = lambda pid, after=after: after
        rows = [row for row in reader.memory_processes() if row['pid'] == mine]
        harm(rows and rows[0]['rss_source'] == expected and rows[0]['start_us'] == seconds * 1000000 + micros, label, rows)


# Main 1712 cases.

ACTIVE = {'test-fixing': 0.70, 'review-a': 0.43, 'lint': 2.22, 'review-b': 0.13, 'pr': 0.13, 'test': 0.43, 'review-c': 0.73}
FLEET_CI = ['ci-361', 'ci-367', 'ci-369', 'ci-3609']


def item1_every_ci_state_unproven():
    # Main 1712 item 1 (review finding 1): the review's fleet case with the four CI runs in ci/fixing and a recorded
    # gate pid: it waits (49.6 against 37.6) whether or not their later fixes are queued.
    Kernel({}, {}).install()
    counted = dict({run: 'repo' for run in ACTIVE}, **{run: 'repo' for run in FLEET_CI})
    steps = dict({run: ('review', 'fixing', 4000, None) for run in ACTIVE}, **{run: ('ci', 'fixing', 4242, None) for run in FLEET_CI})
    rss = {'no-mistakes:repo/%s' % run: dict(rss_bytes=int(size * GIB), processes=1) for run, size in ACTIVE.items()}
    database([(run, None) for run in FLEET_CI])
    for waiting in (frozenset(), frozenset(FLEET_CI)):
        fit = engine.project(int(32.82 * GIB), rss, counted, steps, {}, int(5.77 * GIB), int(13.39 * GIB), 1953340270, None,
                             waiting, held_runs=set(), bound=engine.bound_runs({}, set(FLEET_CI)))
        harm(not fit['admit'] and round(fit['projected'] / GIB, 1) == 49.6, 'fixing', sorted(waiting), fit['projected'] / GIB)
    # The visible pair: X visible at 0.5 GiB with an unproven earlier launch waits queued or not (3 + 0.5 + 8 = 11.5
    # against 8.75); control: with every launch of X shown ended, X queued is a waiter and the start is admitted
    # (0.5 + 8 = 8.5 against 8.75): the waiter's progress stays.
    visible = {'no-mistakes:repo/x': dict(rss_bytes=GIB // 2, processes=1)}
    for waiting in (frozenset(), frozenset({'x'})):
        for step in (('ci', 'running', None, None), ('ci', 'fixing', os.getpid(), None)):
            fit = engine.project(int(8.25 * GIB), visible, {'x': 'repo'}, {'x': step}, {}, R, S, A, None, waiting,
                                 held_runs=set(), bound=set())
            harm(not fit['admit'] and fit['projected'] == 11.5 * GIB, 'visible', step[1], sorted(waiting), fit['projected'] / GIB)
    fit = engine.project(int(8.25 * GIB), visible, {'x': 'repo'}, {'x': ('ci', 'fixing', os.getpid(), None)}, {}, R, S, A, None,
                         frozenset({'x'}), held_runs=set(), bound={'x'})
    control(fit['admit'] and fit['projected'] == 8.5 * GIB, 'bound waiter', fit['projected'] / GIB)


def item1_monotone():
    # Less evidence never counts less: for the same run facts, no step facts count at least what an unproven CI
    # launch counts, which counts at least what a bound run counts (seen and unseen).
    for seen in ({}, {'no-mistakes:repo/x': dict(rss_bytes=GIB // 2, processes=1)}):
        demand = {}
        for label, steps, bound in (('none', None, set()), ('unproven', CI, set()), ('bound', CI, {'x'})):
            fit = engine.project(int(8.5 * GIB), seen, {'x': 'repo'}, steps, {}, R, S, A, held_runs=set(), bound=bound)
            demand[label] = fit['projected']
        harm(demand['none'] >= demand['unproven'] >= demand['bound'], bool(seen), demand)


def item2_same_run_never_passes_its_live_attempt():
    # Main 1712 item 2 (review finding 2): X has one live, unseen attempt; a second launch of X decides with X as its
    # own run: 3 + 8 = 11 against 8.5 waits, by the fit and by the count fallback. Controls: the same launch with no
    # earlier attempt and every launch of X shown ended admits (8 against 8.5); a fresh start over the live attempt waits.
    launches = {'x': dict(repo='repo', attempts=[dict(seen=False, own=0, passive=False)])}
    report = dict(available_bytes=int(8.5 * GIB), runs={})
    measured = ((R, S, 2), (A, 2))
    out = engine.admission([], report, {'x': ('repo', True, False)}, {'x': 'repo'}, CI, launches, 6, 'other', self_run='x',
                           measured=measured, held_runs={'x'}, bound=set())
    harm(out[0] is False, 'second launch of X over its live attempt', out)
    fallback = engine.admission([], None, {'x': ('repo', True, False)}, {'x': 'repo'}, CI, launches, 3, 'other', self_run='x',
                                held_runs={'x'}, bound=set())
    harm(fallback[0] is False, 'fallback: the live attempt is counted', fallback)
    first = engine.admission([], report, {'x': ('repo', True, False)}, {'x': 'repo'}, CI, {}, 6, 'other', self_run='x',
                             measured=measured, held_runs=set(), bound={'x'})
    control(first[0] is True, 'no earlier attempt', first)
    fresh = engine.admission([], report, {'x': ('repo', True, False)}, {'x': 'repo'}, CI, launches, 6, 'other',
                             measured=measured, held_runs={'x'}, bound=set())
    control(fresh[0] is False, 'fresh start', fresh)
    # Main 1727 (option B): an earlier launch of X not shown ended (no record held, but X unbound: no own key, a shared
    # key, a record without its row) is no genuine first start either: R 3 + S 8 = 11 against 8.5 holds, by the fit and
    # the count fallback; control: every launch of X shown ended, 8 against 8.5 admits.
    unproven = engine.admission([], report, {'x': ('repo', True, False)}, {'x': 'repo'}, CI, {}, 6, 'other', self_run='x',
                                measured=measured, held_runs=set(), bound=set())
    harm(unproven[0] is False and 'projected=%d ' % (11 * GIB) in unproven[1], 'second launch over its unproven first', unproven)
    fallback = engine.admission([], None, {'x': ('repo', True, False)}, {'x': 'repo'}, CI, {}, 3, 'other', self_run='x',
                                held_runs=set(), bound=set())
    harm(fallback[0] is False, 'fallback: the unproven launch is counted', fallback)
    control(first[0] is True and 'projected=%d ' % (8 * GIB) in first[1], 'shown ended', first)


def item4_possible_unrecorded_descendant():
    # Main 1712 item 4 (review finding 4): X's root is gone and X recorded no member; Y's live root (pid 42) started
    # after X in the same coalition with no live older ancestor, so it could be an unrecorded X descendant: X and Y
    # both stay held, 3 + 3 + 8 = 14 against 11.5 waits. Control: Y's root under a live process started before X's
    # t0 (Y's own gate, pid 50) is proven not X's: X ends, 3 + 8 = 11 against 11.5 admits.
    for label, processes, admits in (('lineage lost', {42: (1, 200)}, False), ('older ancestor', {42: (50, 200), 50: (1, 90)}, True)):
        Kernel(processes, {42: 7, 50: 7}).install()
        x = attempt(run='x', t0=100, root=(10, 110), key='key-x')
        y = attempt(run='y', t0=150, root=(42, 200), key='key-y')
        out = decide(pool({'x': x, 'y': y}), {'x', 'y'}, {'x': 'repo', 'y': 'repo'},
                     {'x': ('ci', 'running', None, None), 'y': ('ci', 'running', None, None)}, [('x', 'key-x'), ('y', 'key-y')],
                     available=11.5 * GIB)
        if admits:
            control(out['admit'] and out['states'] == {'attempt-x.json': 'ended', 'attempt-y.json': 'held'}, label, out)
        else:
            harm(not out['admit'] and out['states'] == {'attempt-x.json': 'held', 'attempt-y.json': 'held'}, label, out)
    # A traced process's reported parent is no lineage: X's possible orphan under a debugger started before t0 holds X.
    Kernel({42: (50, 200), 50: (1, 90)}, {42: 7, 50: 7}).install()
    info.kinfos = lambda *selector: iter([record(42, 50, 200, traced=True), record(50, 1, 90)])
    out = decide(pool({'x': attempt(run='x', t0=100, root=(10, 110))}), {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
    harm(out['states'] == {'attempt-x.json': 'held'} and not out['admit'], 'traced', out)


def item5_short_confirming_read():
    # Main 1712 item 5 (review finding 5, F1): the confirming per-pid read answers with a short, nonempty record: not
    # proof the possible orphan (pid 42) is gone, so X holds (11 against 8.5). Control: the kernel answers with no
    # record at all, proof it is gone: X ends and the start is admitted (8 against 8.5).
    real_kernel()
    for label, answer, admits in (('short', b'X', False), ('other pid', None, False), ('absent', b'', True)):
        Kernel({42: (1, 101000000), 200: (1, 50000000)}, {200: 9}).install()
        info.kinfo_exact = REAL.get('kinfo_exact', REAL['kinfo'])  # the real per-pid read (an engine before it: kinfo)
        mismatched, other = record(43, 1, 101000000), record(200, 1, 50000000)
        info.sysctl = lambda *mib, answer=answer: other if mib[-1] == 200 else (mismatched if answer is None else answer)
        info.kinfo = REAL['kinfo']
        out = decide(pool({'x': attempt()}), {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
        if admits:
            control(out['admit'] and out['states'] == {'attempt-x.json': 'ended'}, label, out)
        else:
            harm(not out['admit'] and out['states'] == {'attempt-x.json': 'held'}, label, out)


def item5_failed_record_reread():
    # Main 1712 item 5 (F2): X is judged ended, but its record cannot be reread to write the end (it became unreadable
    # between the read and the locked reread): X stays held, 11 against 8.5 waits. Control: the reread succeeds, X ends.
    real_update = engine.update_attempt
    try:
        for label, corrupt, admits in (('reread fails', True, False), ('reread succeeds', False, True)):
            Kernel({200: (1, 50000000)}, {200: 9}).install()
            directory = pool({'x': attempt()})

            def update(path, change, corrupt=corrupt):
                if corrupt:
                    Path(path).write_text('{not json')
                return real_update(path, change)
            engine.update_attempt = update
            out = decide(directory, {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
            if admits:
                control(out['admit'], label, out)
            else:
                harm(not out['admit'] and out['states'] == {'attempt-x.json': 'held'}, label, out)
    finally:
        engine.update_attempt = real_update


def item5_coalition_generation():
    # Main 1712 item 5 (F6): the table shows pid 42 (born after X's t0) and its coalition read gives 9, outside X's
    # coalition 7; the confirming read shows another start time, so the pid now holds another process and the 9 may
    # be that one's: X holds (11 against 8.5). Control: the confirming read shows the same start, the 9 is pid 42's
    # own, X ends (8 against 8.5).
    for label, confirm, admits in (('reused pid', {42: (1, 102000000)}, False), ('same generation', {}, True)):
        Kernel({42: (1, 101000000)}, {42: 9}, confirm).install()
        out = decide(pool({'x': attempt()}), {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
        if admits:
            control(out['admit'] and out['states'] == {'attempt-x.json': 'ended'}, label, out)
        else:
            harm(not out['admit'] and out['states'] == {'attempt-x.json': 'held'}, label, out)


def item5_malformed_record_field():
    # A readable record with a malformed field (root not a pid and start) holds at R like an unreadable one, and
    # (as it could be any run's) leaves no run's launches shown ended: 3 + 3 + 8 = 14 against 8.5 waits.
    Kernel({200: (1, 50000000)}, {200: 9}).install()
    bad = attempt(); bad['root'] = 'garbage'
    out = decide(pool({'x': bad}), {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
    harm(not out['admit'] and out['projected'] == 14 and out['states'] == {'attempt-x.json': 'held'}, out)


def item6_live_attempt_whatever_status():
    # Main 1712 item 6 (review finding 6): X's recorded root (pid 42) lives while X's run is no longer running (Y is the
    # only counted run, 13 GiB available): X stays held and counted at R, 3 + 3 + 8 = 14 against 13 waits. The same
    # holds for a passive attempt (a passed-through launch) once its run is not counted. Control: X's root is gone and
    # nothing could be X's: its record ends and is removed, 3 + 8 = 11 against 13 admits.
    steps = {'y': ('review', 'running', None, None)}
    for label, reserves in (('reserving', True), ('passive', False)):
        Kernel({42: (1, 101000000)}, {42: 7}).install()
        directory = pool({'x': attempt(root=(42, 101000000), reserves=reserves)})
        out = decide(directory, {'y'}, {'y': 'repo'}, steps, [], available=13 * GIB)
        harm(not out['admit'] and out['projected'] == 14 and out['kinds'].get('x') == 'launched', label, out)
        harm(os.path.exists(os.path.join(directory, 'attempt-x.json')), label, 'record kept')
    Kernel({200: (1, 50000000)}, {200: 9}).install()
    directory = pool({'x': attempt(root=(42, 101000000))})
    out = decide(directory, {'y'}, {'y': 'repo'}, steps, [], available=13 * GIB)
    control(out['admit'] and out['projected'] == 11 and not os.path.exists(os.path.join(directory, 'attempt-x.json')), out)
    # A counted run's own passive attempt is left to the run's own term (unchanged pass-through accounting).
    Kernel({42: (1, 101000000)}, {42: 7}).install()
    out = decide(pool({'x': attempt(root=(42, 101000000), reserves=False)}), {'x'}, {'x': 'repo'},
                 {'x': ('review', 'running', None, None)}, [], available=13 * GIB)
    control(out['kinds'].get('x') == 'active' and out['projected'] == 11, out)


def item7_no_row_no_record():
    # Main 1712 item 7: the daemon writes an invocation row only after the invocation returns, best effort, so a launch
    # can exist with neither a row nor a record. A CI run with no row, or with an ended record whose row is missing,
    # is not shown ended: it stays counted at R (11 against 8.5, wait). Control: one row whose own key an ended record
    # carries binds the run: ci-waiting, 8 against 8.5 admits.
    for label, records, rows, admits in (('no row, no record', {}, [], False),
                                         ('record without its row', {'r1': attempt(ended=1, key='k1'), 'r2': attempt(ended=1, key='k2')}, [('x', 'k1')], False),
                                         ('row and record', {'r1': attempt(ended=1, key='k1')}, [('x', 'k1')], True)):
        Kernel({200: (1, 50000000)}, {200: 9}).install()
        records = {name: dict(value, id=name) for name, value in records.items()}
        out = decide(pool(records), {'x'}, {'x': 'repo'}, CI, rows)
        if admits:
            control(out['admit'] and out['kinds']['x'] == 'ci-waiting', label, out)
        else:
            harm(not out['admit'] and out['kinds']['x'] == 'ci-unproven', label, out)


def pending_case(entries, rows, claims=None):
    """Publish locked pending entries in a scratch pool; returns (pool, {name: path}, fds)."""
    directory = tempfile.mkdtemp(prefix='pending-', dir=str(scratch))
    paths, fds = {}, []
    for name, entry in entries.items():
        if entry is None:
            fd, path = engine.publish_locked(directory, 'pending-', {})
            os.pwrite(fd, b'{not json', 0)
            os.ftruncate(fd, len(b'{not json'))
        else:
            fd, path = engine.publish_locked(directory, 'pending-', dict(dict(holder=os.getpid(), args=None, before=[],
                                                                               created_ns=len(paths) + 1), **entry))
        paths[name], _ = path, fds.append(fd)
        if claims and name in claims:
            Path(path + '.claimed').write_text(json.dumps(claims[name]))
    database(runs=rows)
    return directory, paths, fds


def released(directory, rows):
    return {os.path.basename(path): (done, own) for path, _, done, own in engine.live_pending(directory, set(rows))}


def item3_claimant_nonce():
    # Main 1712 item 3 (review finding 3): the outer entry carries nonce A in its parsed arguments; the live nested
    # claimant B carries nonce B. Another client's A row never releases B; B's own row does. Twins: a nonce carried
    # by two live starts, or by a row that existed at admission, releases nothing; a claim with no nonce is released
    # by no row; an entry that cannot be decoded is counted.
    live_pid = os.getpid()
    for label, rows, expect in (('A row', {'run-A': ('nonce-A', 'repo')}, (False, None)),
                                ('B row', {'run-B': ('nonce-B', 'repo')}, (True, 'run-B'))):
        directory, paths, fds = pending_case({'outer': dict(args=['axi', 'run', '--launch-nonce', 'nonce-A'], client_nonce=None)}, rows,
                                             claims={'outer': dict(pid=live_pid, nonce='nonce-B', seen=[])})
        got = released(directory, rows)[os.path.basename(paths['outer'])]
        (harm if label == 'A row' else control)(got == expect, label, got)
        for fd in fds:
            os.close(fd)
    rows = {'run-n': ('nonce-n', 'repo')}
    directory, paths, fds = pending_case({'p': dict(client_nonce='nonce-n'), 'q': dict(client_nonce='nonce-n')}, rows)
    got = released(directory, rows)
    harm(all(value == (False, None) for value in got.values()), 'reused nonce', got)
    for fd in fds:
        os.close(fd)
    directory, paths, fds = pending_case({'p': dict(client_nonce='nonce-n', before=['run-n'])}, rows)
    harm(released(directory, rows)[os.path.basename(paths['p'])] == (False, None), 'row existed at admission')
    for fd in fds:
        os.close(fd)
    directory, paths, fds = pending_case({'p': dict(args=['axi', 'run', '--launch-nonce', 'nonce-n'])}, rows,
                                         claims={'p': dict(pid=live_pid, seen=[])})
    harm(released(directory, rows)[os.path.basename(paths['p'])] == (False, None), 'claim without nonce')
    for fd in fds:
        os.close(fd)
    directory, paths, fds = pending_case({'bad': None}, rows)
    harm(released(directory, rows)[os.path.basename(paths['bad'])] == (False, None), 'undecodable entry')
    for fd in fds:
        os.close(fd)


def item3_no_reuse_of_registered_admission():
    # Main 1712 item 3 (P6(g)): an admitted command's first client ran by its absolute path (no claim), registered a run
    # with no nonce and exited; the identical second client finds the still-present entry. The row may be the first
    # client's, so the claim is refused and the second client is decided on its own. Control: with no new row the
    # unused reservation is claimed; a row carrying another live start's own nonce does not block the claim.
    real_kernel()
    args = ['axi', 'run', '--intent', 'reg-x']
    holder = os.getppid()
    for label, rows, claims in (('unexplained row', {'run-first': (None, 'repo')}, False),
                                ('no new row', {}, True),
                                ('another start\'s own row', {'run-other': ('nonce-o', 'repo')}, True)):
        entries = {'outer': dict(holder=holder, args=args)}
        if label == "another start's own row":
            entries['other'] = dict(holder=1, args=['axi', 'run', '--intent', 'o'], client_nonce='nonce-o')
        directory, paths, fds = pending_case(entries, rows)
        got = engine.claim_round(directory, args, same_args=True)
        if claims:
            control(got == holder, label, got)
        else:
            harm(got is None, label, got)
        for fd in fds:
            os.close(fd)


for name, body in (('F1 an unreadable confirming read holds', f1_unreadable_confirming_read),
                   ('F2 an unreadable attempt record reserves', f2_unreadable_record),
                   ('F6 an unknown launch coalition excludes nothing', f6_unknown_launch_coalition),
                   ('F7 a queued later fix keeps an unproven launch counted', f7_waiter_keeps_unproven),
                   ('F8 every owner of a pid keeps it', f8_every_owner_kept),
                   ('read source: one process generation per memory figure', read_source_one_generation),
                   ('Main 1712 item 1 every CI state keeps an unproven launch counted', item1_every_ci_state_unproven),
                   ('Main 1712 item 1 less evidence never counts less', item1_monotone),
                   ('Main 1712 item 2 a same-run launch never passes its live or unproven attempt', item2_same_run_never_passes_its_live_attempt),
                   ('Main 1712 item 4 another owner is no proof a possible descendant is foreign', item4_possible_unrecorded_descendant),
                   ('Main 1712 item 5 a short confirming read holds', item5_short_confirming_read),
                   ('Main 1712 item 5 a failed record reread holds', item5_failed_record_reread),
                   ('Main 1712 item 5 a coalition read binds to its pid generation', item5_coalition_generation),
                   ('Main 1712 item 5 a malformed record field holds', item5_malformed_record_field),
                   ('Main 1712 item 6 a live attempt counts whatever its run status', item6_live_attempt_whatever_status),
                   ('Main 1712 item 7 a launch with no row and no record holds', item7_no_row_no_record),
                   ('Main 1712 item 3 a row ends only its claimant\'s own reservation', item3_claimant_nonce),
                   ('Main 1712 item 3 a registered no-nonce admission is never reused', item3_no_reuse_of_registered_admission)):
    case(name, body)
print(json.dumps(results, indent=1))
sys.exit(0 if all(value == 'pass' for value in results.values()) else 1)
