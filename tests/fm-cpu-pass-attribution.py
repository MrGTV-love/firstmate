#!/usr/bin/env python3
"""Attribution decision cases for fm-cpu-pass.test.sh: the engine's own functions on fixed kernel and run facts.

Each case feeds bin/fm-cpu-pass.py's kernel_snapshot, judge_attempts, attempt_reservations, bound_runs and project
with in-memory facts (a fake process table at the fm-proc-info boundary and a fake run database), the shape of the
outside review's falsifiers (Main 1683), and asserts the decision at an admit-versus-wait boundary: R = 3, S = 8 and
A = 1 GiB, 8.5 GiB available unless stated. Usage: fm-cpu-pass-attribution.py REPO SCRATCH; prints JSON; exits 1 on
any failure. Starts no process and sends no signal.
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


def record(pid, parent, start_us, zombie=False):
    """A kinfo_proc record of the size and field offsets bin/fm-proc-info.py reads."""
    data = bytearray(info.KINFO_SIZE)
    struct.pack_into('qq', data, info.P_START, start_us // 1000000, start_us % 1000000)
    struct.pack_into('i', data, info.P_PID, pid)
    struct.pack_into('i', data, info.E_PPID, parent)
    data[info.P_STAT] = info.SZOMB if zombie else 2
    return bytes(data)


class Kernel:
    """Fake process facts at the fm-proc-info boundary: kinfos, kinfo, coalition and process_identity."""

    def __init__(self, processes, coalitions, confirm=None):
        self.processes, self.coalitions, self.confirm = processes, coalitions, confirm or {}

    def install(self):
        info.kinfos = lambda *selector: iter([record(pid, parent, start) for pid, (parent, start) in self.processes.items()])
        info.coalition = lambda pid: self.coalitions.get(pid)

        def kinfo(pid):
            action = self.confirm.get(pid)
            if isinstance(action, BaseException):
                raise action
            if pid not in self.processes:
                raise LookupError(pid)
            parent, start = self.processes[pid]
            return record(pid, parent, start)
        info.kinfo = kinfo
        engine.sibling = lambda module, filename: info


def database(rows):
    """Fake run database for read_host_db: agent_invocations rows (run_id, session_key)."""
    def read(sql, parameters=()):
        if 'FROM agent_invocations' in sql:
            wanted = set(parameters)
            return [(run, key) for run, key in rows if run in wanted]
        if 'FROM runs' in sql:
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


def decide(directory, running, counted, steps, rows, available=8.5 * GIB, waiting=frozenset(), rss=None, processes=()):
    database(rows)
    states = engine.judge_attempts(directory, set(running))
    report = dict(processes=list(processes))
    launches, held_runs = engine.attempt_reservations(states, report)
    ci_runs = {run for run in counted if steps.get(run) and steps[run][0] == 'ci'}
    bound = engine.bound_runs(states, ci_runs)
    fit = engine.project(int(available), rss or {}, counted, steps, launches, R, S, A, None, frozenset(waiting),
                         held_runs=held_runs, bound=bound)
    return dict(admit=fit['admit'], projected=fit['projected'] / GIB, budget=fit['budget'] / GIB,
                states={os.path.basename(s['path']): s['state'] for s in states.values()})


CI = {'x': ('ci', 'running', None, None)}
results = {}


def case(name, body):
    try:
        body()
        results[name] = 'pass'
    except Exception as exc:  # noqa: BLE001 - every case is reported
        results[name] = 'FAIL: %s: %s' % (type(exc).__name__, str(exc)[:600])


def f1_unreadable_confirming_read():
    # A live orphan (pid 42, born after X's t0) whose coalition is unreadable; the confirming read raises
    # PermissionError. Unreadable is not proof of exit: X stays held and the start waits (11 against 8.5).
    for label, confirm in (('readable', None), ('permission-error', PermissionError(1, 'denied'))):
        Kernel({42: (1, 101000000), 200: (1, 50000000)}, {200: 9}, {42: confirm} if confirm else {}).install()
        directory = pool({'x': attempt()})
        out = decide(directory, {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
        assert not out['admit'] and out['projected'] == 11, (label, out)


def f2_unreadable_record():
    # An unreadable attempt record: a parked run's live gated attempt (outside the counted set), and a counted CI run
    # whose second, live attempt cannot be read beside an ended first attempt bound to its row. Both wait.
    Kernel({42: (1, 101000000)}, {42: 7}).install()
    out = decide(pool({}, broken=('live',)), {'x'}, {}, {}, [])
    assert not out['admit'] and out['projected'] == 11, ('parked', out)
    out = decide(pool({'first': attempt(ended=1)}, broken=('second',)), {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
    assert not out['admit'], ('counted', out)


def f6_unknown_launch_coalition():
    # X's launch coalition was unreadable when it was recorded; a possible orphan (pid 42, coalition 7, born after
    # t0) is not proven outside it: X stays held, the start waits (11 against 8.5); with coalition 7 recorded, the same.
    for label, coalition in (('recorded', 7), ('unknown', None)):
        Kernel({42: (1, 101000000)}, {42: 7}).install()
        out = decide(pool({'x': attempt(coalition=coalition)}), {'x'}, {'x': 'repo'}, CI, [('x', 'own-key')])
        assert not out['admit'] and out['projected'] == 11, (label, out)


def f7_waiter_keeps_unproven():
    # A counted CI run whose earlier launch cannot be shown ended keeps its full R while a later fix of it waits.
    Kernel({}, {}).install()
    for waiting in (frozenset(), frozenset({'x'})):
        out = decide(pool({}), {'x'}, {'x': 'repo'}, CI, [('x', None)], waiting=waiting)
        assert not out['admit'] and out['projected'] == 11, (sorted(waiting), out)
    # The review's fleet-shaped case: seven active runs, four invisible CI runs with unproven earlier launches,
    # R 5.77, S 13.39, A 1953340270 bytes, 32.82 GiB available: it waits (49.6 against 37.6) whether or not the
    # four have later fixes queued.
    active = {'test-fixing': 0.70, 'review-a': 0.43, 'lint': 2.22, 'review-b': 0.13, 'pr': 0.13, 'test': 0.43, 'review-c': 0.73}
    ci = ['ci-361', 'ci-367', 'ci-369', 'ci-3609']
    counted = dict({run: 'repo' for run in active}, **{run: 'repo' for run in ci})
    steps = dict({run: ('review', 'fixing', 4000, None) for run in active}, **{run: ('ci', 'running', None, None) for run in ci})
    rss = {'no-mistakes:repo/%s' % run: dict(rss_bytes=int(size * GIB), processes=1) for run, size in active.items()}
    database([(run, None) for run in ci])
    for waiting in (frozenset(), frozenset(ci)):
        fit = engine.project(int(32.82 * GIB), rss, counted, steps, {}, int(5.77 * GIB), int(13.39 * GIB), 1953340270, None,
                             waiting, held_runs=set(), bound=engine.bound_runs({}, set(ci)))
        assert not fit['admit'] and round(fit['projected'] / GIB, 1) == 49.6, (sorted(waiting), fit['projected'] / GIB)


def f8_every_owner_kept():
    # X records pid 42 (start 200) as a member; Y records the same identity as its root. Both stay held.
    Kernel({42: (1, 200)}, {42: 7}).install()
    out = decide(pool({'x': attempt(run='x', t0=100, members=[(42, 200)]), 'y': attempt(run='y', t0=150, root=(42, 200))}),
                 {'x', 'y'}, {'x': 'repo', 'y': 'repo'}, {}, [])
    assert out['states'] == {'attempt-x.json': 'held', 'attempt-y.json': 'held'}, out


def read_source_one_generation():
    # Main 1656 item 4: a memory figure is attributed to one process generation only when its start time is the same
    # before and after the memory read; a changed start marks the figure unstable, never task.
    real_kinfos, real_kinfo = info.kinfos, info.kinfo
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
        assert rows and rows[0]['rss_source'] == expected and rows[0]['start_us'] == seconds * 1000000 + micros, (label, rows)
    info.kinfos, info.kinfo = real_kinfos, real_kinfo


for name, body in (('F1 an unreadable confirming read holds', f1_unreadable_confirming_read),
                   ('F2 an unreadable attempt record reserves', f2_unreadable_record),
                   ('F6 an unknown launch coalition excludes nothing', f6_unknown_launch_coalition),
                   ('F7 a queued later fix keeps an unproven launch counted', f7_waiter_keeps_unproven),
                   ('F8 every owner of a pid keeps it', f8_every_owner_kept),
                   ('read source: one process generation per memory figure', read_source_one_generation)):
    case(name, body)
print(json.dumps(results, indent=1))
sys.exit(0 if all(value == 'pass' for value in results.values()) else 1)
