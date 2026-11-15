#!/usr/bin/env python3
"""Attribution and pending-start decisions from host facts, for fm-cpu-pass.test.sh (Main 1683, 1712, 1727, 1759, 1761).

Every case builds one world of facts at the engine's lowest read boundary and asks the engine's own decide() (or
live_pending() and claim_round() for pending starts) for the answer: a run database (a real sqlite file the engine
opens read-only), a pool of real attempt, pending, claim, waiter and activation files, the kernel answers the
engine's own bin/fm-proc-info.py reads (its sysctl and proc_pidinfo, replaced in a private copy of that module), and
a fixed memory reading (R = 3, S = 8, A = 1 GiB, 8.5 GiB available unless stated). So the same file decides through
any engine that has these functions: the head and the earlier engines a failing-first run uses. The assertion that
guards a case's harm raises "harm:<id>: ..."; a compliant twin's raises "control: ...", so a red can be told from an
error. The perturbation group takes every base world that waits and changes one fact toward less evidence; each such
world must still wait, and its projected demand must not fall. Usage: fm-cpu-pass-attribution.py REPO SCRATCH;
prints JSON; exits 1 on any failure. Starts no process, sends no signal and makes no process group (Main 1845): the
kernel, the run database and the pool are the case's own facts, and one case runs the engine's launch gate in this
process with its agent start replaced by a probe.
"""
import ctypes
import importlib.util
import json
import os
import sqlite3
import struct
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

repo, scratch = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
scratch.mkdir(parents=True, exist_ok=True)
GIB = 2 ** 30
R, S, A = 3 * GIB, 8 * GIB, GIB
DEAD_PID = 999999  # above Darwin's largest pid (kern.maxproc's pid range ends at 99999): a pid no process has
NOW = int(time.time())


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


engine = load('fm_cpu_pass_under_test', repo / 'bin' / 'fm-cpu-pass.py')
proc = load('fm_proc_info_under_test', repo / 'bin' / 'fm-proc-info.py')
REAL_SYSCTL, REAL_LIBC = proc.sysctl, proc.libc


class BarredProcessCall(BaseException):
    """Raised by any attempt of the code under test to start, signal or kill a process (Main 1850): a guard, so
    the file can never cross the host's test limit, whatever an engine under test tries."""


def barred(name):
    def call(*args, **kwargs):
        raise BarredProcessCall('%s%r' % (name, args[:2]))
    return call


# No process is started, signalled or killed from here on: process starts fail in the engine's and the process
# reader's own subprocess module and in os, signals fail in os, and the engine's liveness check reads a fact.
_barred_subprocess = SimpleNamespace(run=barred('subprocess.run'), Popen=barred('subprocess.Popen'), call=barred('subprocess.call'),
                                     check_output=barred('subprocess.check_output'), DEVNULL=-3, PIPE=-1, STDOUT=-2,
                                     TimeoutExpired=__import__('subprocess').TimeoutExpired,
                                     SubprocessError=__import__('subprocess').SubprocessError,
                                     CalledProcessError=__import__('subprocess').CalledProcessError)
engine.subprocess = proc.subprocess = _barred_subprocess
for _name in ('fork', 'forkpty', 'kill', 'killpg', 'setsid', 'setpgid', 'execv', 'execve', 'execvp', 'posix_spawn', 'posix_spawnp',
              'spawnv', 'spawnve', 'system'):
    if hasattr(os, _name):
        setattr(os, _name, barred('os.' + _name))
DEAD_PIDS = set()


def pid_fact(pid):
    """The engine's pid_dead, from facts: a pid in DEAD_PIDS or at least DEAD_PID is gone; any other is alive."""
    if type(pid) is not int or pid <= 0:
        return None
    return pid >= DEAD_PID or pid in DEAD_PIDS


engine.pid_dead = pid_fact
COALITION_FLAVOR = getattr(proc, 'PROC_PIDCOALITIONINFO', 20)


class HarmError(AssertionError):
    pass


def harm(ident, condition, *detail):
    if not condition:
        raise HarmError(('harm:%s: %r' % (ident, detail))[:1500])


def control(condition, *detail):
    if not condition:
        raise AssertionError(('control: %r' % (detail,))[:1500])


def kinfo(pid, parent, start_us, traced=False):
    data = bytearray(proc.KINFO_SIZE)
    struct.pack_into('qq', data, proc.P_START, start_us // 1000000, start_us % 1000000)
    struct.pack_into('i', data, proc.P_PID, pid)
    struct.pack_into('i', data, proc.E_PPID, parent)
    struct.pack_into('i', data, proc.P_FLAG, 0x800 if traced else 0)
    data[proc.P_STAT] = 2
    return bytes(data)


class World:
    """One host: runs, steps, invocation rows, pool files, processes and a memory reading."""

    def __init__(self, name, available=8.5, activated=True):
        self.dir = Path(tempfile.mkdtemp(prefix=name[:40] + '-', dir=str(scratch)))
        self.pool = self.dir / 'pool'
        self.pool.mkdir()
        self.db = self.dir / 'state.sqlite'
        with sqlite3.connect(self.db) as c:
            c.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER,'
                      ' repo_id TEXT, worktree_dir TEXT, branch TEXT, intent TEXT, created_at INTEGER, launch_nonce TEXT)')
            c.execute('CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,'
                      ' step_order INTEGER NOT NULL, status TEXT NOT NULL, agent_pid INTEGER, round_started_at INTEGER)')
            c.execute('CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, purpose TEXT, started_at INTEGER,'
                      ' completed_at INTEGER, duration_ms INTEGER, exit_status TEXT, session_key TEXT, agent TEXT)')
            c.execute('CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL)')
        self.available = available
        self.processes = {200: dict(parent=1, start=50000000, coalition=9)}  # one unrelated process older than every attempt
        self.rss = {}
        self.own = {}  # pid -> resident GiB of an attempt's process in the reading (its exact start, a task figure)
        self.tail = b''
        self.fds = []
        self.rows = 0
        if activated:
            self.activate(NOW - 1000)

    def sql(self, statement, parameters=()):
        with sqlite3.connect(self.db) as c:
            c.execute(statement, parameters)
        return self

    def activate(self, at):
        (self.pool / 'gate-activation.json').write_text(json.dumps(dict(activated_at=at, gate_sha256='0' * 64)))

    def run(self, run, step=('ci', 'running', None), counted=True, created=None, nonce=None):
        self.sql('INSERT INTO runs (id, status, repo_id, created_at, ci_ready_at, launch_nonce) VALUES (?, ?, ?, ?, ?, ?)',
                 (run, 'running', 'repo', NOW - 500 if created is None else created, None if counted else NOW, nonce))
        if step:
            self.sql('INSERT INTO step_results (id, run_id, step_name, step_order, status, agent_pid, round_started_at)'
                     ' VALUES (?, ?, ?, 1, ?, ?, ?)', (run + '-s', run, step[0], step[1], step[2], NOW - 10))
        return self

    def row(self, run, key, agent='claude', started=1, completed=2):
        self.rows += 1
        return self.sql("INSERT INTO agent_invocations (id, run_id, step_name, purpose, started_at, completed_at, duration_ms, exit_status,"
                        " session_key, agent) VALUES (?, ?, 'ci', 'ci', ?, ?, 1, 'ok', ?, ?)",
                        ('i%d' % self.rows, run, started, completed, key, agent))

    def record(self, name, run, raw=None, drop=(), **fields):
        record = dict(id=name, run=run, repo='repo', step='ci', reserves=True, t0_us=100000000, root=[10, 100100000], gate=None,
                      watcher=None, coalition=7, session_key='key-' + name, members=[], ended_us=None,
                      quiet_us=None)  # quiet_us: a field the gate wrote before Main 1812 (ignored since), so earlier engines read these records
        record.update(fields)
        for field in drop:
            record.pop(field, None)
        (self.pool / ('attempt-%s.json' % name)).write_text(raw if raw is not None else json.dumps(record))
        return self

    def proved(self, run, name=None):
        # An earlier launch of RUN shown ended: its own row and its ended record carry one key.
        name = name or 'proof-' + run
        return self.row(run, 'key-' + name).record(name, run, ended_us=1)

    def process(self, pid, parent=1, start=101000000, coalition=7, **extra):
        self.processes[pid] = dict(parent=parent, start=start, coalition=coalition, **extra)
        return self

    def pending(self, entry=None, raw=None, claim=None):
        fd, path = engine.publish_locked(str(self.pool), 'pending-', entry or {})
        self.fds.append(fd)
        if raw is not None:
            os.pwrite(fd, raw, 0)
            os.ftruncate(fd, len(raw))
        if claim is not None:
            Path(path + '.claimed').write_text(claim if isinstance(claim, str) else json.dumps(claim))
        return path

    def waiter(self, run, pid):
        fd, _ = engine.publish_locked(str(self.pool), 'pipeline-waiter-', dict(priority='other', queued_ns=1, run=run, pid=pid))
        self.fds.append(fd)
        return self

    def sysctl(self, *mib):
        mib = tuple(mib)
        if mib[:3] == (proc.CTL_KERN, proc.KERN_PROC, proc.KERN_PROC_ALL):
            self.table_reads = getattr(self, 'table_reads', 0) + 1
            for pid, (from_read, facts) in getattr(self, 'scheduled', {}).items():
                if self.table_reads >= from_read:
                    self.processes[pid] = facts  # a process that exists from that census on
            return b''.join(kinfo(pid, p['parent'], p['start'], p.get('traced', False)) for pid, p in self.processes.items()) + self.tail
        if mib[:3] == (proc.CTL_KERN, proc.KERN_PROC, proc.KERN_PROC_PID) and mib[3] in self.processes:
            p = self.processes[mib[3]]
            confirm = p.get('confirm')
            if confirm == 'gone':
                return b''
            if confirm == 'short':
                return b'X'
            return kinfo(mib[3], p['parent'], p['start'] + (1 if confirm == 'other' else 0), p.get('traced', False))
        if mib[:2] == (proc.CTL_KERN, proc.KERN_PROCARGS2) and mib[2] in self.processes:
            marker = self.processes[mib[2]].get('marker')
            environment = ('FM_LAUNCH_ATTEMPT=%s\0' % marker).encode() if marker else b''
            return struct.pack('i', 1) + b'/bin/fake\0\0fake\0' + environment
        return REAL_SYSCTL(*mib)

    def proc_pidinfo(self, pid, flavor, arg, buffer, size):
        if pid in self.processes and flavor == COALITION_FLAVOR:
            p = self.processes[pid]
            if p['coalition'] is None:
                return 0
            data = struct.pack('Q', p['coalition']) + bytes(32)
            length = p.get('coalition_len', len(data))
            ctypes.memmove(buffer, data, min(length, len(data)))
            return length
        if pid in self.processes:
            return 0
        return REAL_LIBC.proc_pidinfo(pid, flavor, arg, buffer, size)

    def install(self):
        proc.sysctl = self.sysctl
        proc.libc = SimpleNamespace(proc_pidinfo=self.proc_pidinfo, strvis=REAL_LIBC.strvis)
        engine.sibling = lambda module, filename: proc
        engine.HOST_STATE_DB = str(self.db)
        engine.process_argv = lambda pid: ['fake']

    def decide(self, self_run=None, waiting=(), cores=18, fallback=False):
        self.install()
        report = dict(available_bytes=int(self.available * GIB), errors=[],
                      processes=[dict(pid=pid, start_us=self.processes[pid]['start'], rss_bytes=int(size * GIB), rss_source='task')
                                 for pid, size in self.own.items()],
                      runs={'no-mistakes:repo/%s' % run: dict(rss_bytes=int(size * GIB), processes=1) for run, size in self.rss.items()})
        if getattr(self, 'decide_hook', None):
            self.decide_hook(report)
        # The count fallback: the memory reading reads, but no qualifying run records give R and S (the engine's own
        # fallback trigger), so the step table is still read.
        engine.host_observation = lambda fresh=False: dict(reasons=[], memory=report)
        engine.measured_reservations = lambda report, running: None if fallback else (R, S, 2)
        engine.active_term = lambda report: (A, 2)
        real_listdir, real_scandir, pool = os.listdir, os.scandir, str(self.pool)

        def denied(real):
            def call(path='.', *rest):
                if getattr(self, 'deny_listing', False) and os.fspath(path) == pool:
                    raise PermissionError(13, 'Permission denied', pool)
                return real(path, *rest)
            return call
        os.listdir, os.scandir = denied(real_listdir), denied(real_scandir)
        import glob as _glob
        globber = getattr(_glob, '_StringGlobber', None)
        real_globber = globber.__dict__.get('scandir') if globber else None
        if real_globber is not None:
            globber.scandir = staticmethod(denied(real_scandir))  # Path.glob's own bound scandir (Python 3.13)
        try:
            running = engine.running_runs()
            counted = {run: repo_id for run, (repo_id, is_counted, _) in running.items() if is_counted}
            admit, line = engine.decide(running, counted, cores, 'other', directory=str(self.pool), self_run=self_run,
                                        waiting=frozenset(waiting))
        finally:
            proc.sysctl, proc.libc = REAL_SYSCTL, REAL_LIBC
            os.listdir, os.scandir = real_listdir, real_scandir
            if real_globber is not None:
                globber.scandir = real_globber
        projected = None
        for word in line.split():
            if word.startswith('projected='):
                projected = int(word.split('=')[1]) / GIB
        return dict(admit=admit, projected=projected, line=line[:500])

    def close(self):
        for fd in self.fds:
            os.close(fd)
        self.fds = []


def settle(world, **kw):
    # Two decisions, so an engine that ends an attempt only at a later decision has had its chance to.
    world.decide(**kw)
    return world.decide(**kw)


def waits(ident, world, projected=None, unknown=None, **kw):
    # The harm is an admission; the projection (or the unknown fact a forced wait names) is the case's control.
    out = settle(world, **kw)
    world.close()
    harm(ident, not out['admit'], out)
    if unknown is not None:
        control(out['line'].startswith('unknown:') and unknown in out['line'], 'a forced wait naming', unknown, out)
    elif projected is not None:
        control(out['projected'] is not None and abs(out['projected'] - projected) < 1e-6, 'projected', projected, out)
    return out


def admits(world, projected=None, **kw):
    out = settle(world, **kw)
    world.close()
    control(out['admit'] and (projected is None or abs(out['projected'] - projected) < 1e-6), out)
    return out


results = {}


def case(name, body):
    try:
        body()
        results[name] = 'pass'
    except HarmError as exc:
        results[name] = 'FAIL: HarmError: %s' % str(exc)[:900]
    except BarredProcessCall as exc:  # the code under test tried to start or signal a process: an error, never run
        results[name] = 'FAIL: BarredProcessCall: %s' % str(exc)[:600]
    except Exception as exc:  # noqa: BLE001 - every case is reported; only a HarmError is a red
        results[name] = 'FAIL: %s: %s' % (type(exc).__name__, str(exc)[:900])
    finally:
        proc.sysctl, proc.libc = REAL_SYSCTL, REAL_LIBC


# Worlds. X's attempt record has root pid 10 (start 100.1 s), t0 100 s, coalition 7; a possible orphan of X is pid 42,
# parent launchd, started at 101 s, coalition 7. Each run also has an earlier launch shown ended (proved).

def orphan_world(name, **kw):
    return quiet_world(name, **kw).process(42)


def quiet_world(name, **kw):
    # X's launch with its own row (the daemon writes it as the invocation returns) and its record.
    return World(name, **kw).run('x').proved('x').row('x', 'key-x').record('x', 'x')


def f1_unreadable_confirming_read():
    w = orphan_world('f1'); w.processes[42].update(coalition=None, confirm='short')
    waits('f1-unreadable-confirm', w, 11)
    admits(quiet_world('f1-control'), 8)


def f2_unreadable_record():
    # An unreadable record is unknown: the decision waits, naming it (Main 1812 B, Main 1819).
    waits('f2-unreadable-record', World('f2').run('x').proved('x').record('live', 'x', raw='{not json'), unknown='attempt-live.json')
    waits('f2-unreadable-record-parked', World('f2-parked').record('live', 'p', raw='{not json'), unknown='attempt-live.json')


def f6_unknown_launch_coalition():
    w = orphan_world('f6'); w.record('x', 'x', coalition=None)
    waits('f6-unknown-coalition', w, 11)
    w = orphan_world('f6-control'); w.processes[42]['coalition'] = 9
    admits(w, 8)


def f7_queued_fix_keeps_unproven():
    for queued in ((), ('x',)):
        waits('f7-queued', World('f7').run('x').row('x', None), 11, waiting=queued)
    admits(World('f7-control').run('x').proved('x'), 8, waiting=('x',))


def f8_every_owner_kept():
    # X records pid 42 as a member; Y records it as its root. Both held: 3 + 3 + 8 = 14 against 12 waits; with only Y
    # (X never had it), 11 against 12 admits.
    w = World('f8', available=12).run('x').run('y').proved('x').proved('y').process(42, start=200000000)
    w.record('x', 'x', t0_us=100, members=[[42, 200000000]]).record('y', 'y', t0_us=150, root=[42, 200000000])
    waits('f8-every-owner', w, 14)
    w = World('f8-control', available=12).run('x').run('y').proved('x').proved('y').process(42, start=200000000, coalition=8)
    w.record('y', 'y', t0_us=150, root=[42, 200000000], coalition=8)
    admits(w, 11)


def item1_every_ci_state():
    # A recorded agent pid proven dead: above Darwin's largest pid (99999), so no process has it. The world that
    # admits at an engine without this rule (fixing, queued) comes first, so no earlier control hides its red.
    for step in (('ci', 'fixing', DEAD_PID), ('ci', 'running', None)):
        for queued in (('x',), ()):
            # R for the unproven launch beside S; a fixing step not queued also keeps R for its current state.
            expected = 14 if step[1] == 'fixing' and not queued else 11
            waits('i1-ci-state', World('i1').run('x', step=step).row('x', None), expected, waiting=queued)
    w = World('i1-visible', available=8.25).run('x').row('x', None); w.rss['x'] = 0.5
    waits('i1-visible', w, 11.5, waiting=('x',))  # R for the unproven launch beside what the queued run holds, S
    w = World('i1-visible-control', available=8.25).run('x').proved('x'); w.rss['x'] = 0.5
    admits(w, 8.5, waiting=('x',))


def item2_same_run():
    waits('i2-live', World('i2-live').run('x').proved('x').record('x', 'x').process(10, start=100100000), 11, self_run='x')
    waits('i2-live-fallback', World('i2-live-fb').run('x').proved('x').record('x', 'x').process(10, start=100100000),
          self_run='x', cores=3, fallback=True)
    waits('i2-unproven', World('i2-unproven').run('x').row('x', None), 11, self_run='x')
    admits(World('i2-control').run('x').proved('x'), 8, self_run='x')


def item4_another_owner():
    w = World('i4', available=11.5).run('x').run('y').proved('x').proved('y').process(42, start=200000000)
    w.record('x', 'x', t0_us=100, root=[10, 110]).record('y', 'y', t0_us=150, root=[42, 200000000])
    waits('i4-possible-descendant', w, 14)


def item5_reads():
    w = orphan_world('i5-short'); w.processes[42].update(coalition=9, confirm='short')
    waits('i5-short-confirm', w, 11)
    w = orphan_world('i5-generation'); w.processes[42].update(coalition=9, confirm='other')
    waits('i5-coalition-generation', w, 11)
    waits('i5-malformed-field', World('i5-malformed').run('x').proved('x').record('x', 'x', root='garbage'), unknown='attempt-x.json')


def item6_run_status():
    w = World('i6', available=13).run('y', step=('review', 'running', None)).proved('y').record('x', 'gone-run')
    waits('i6-live-attempt-run-stopped', w.process(10, start=100100000), 14)


def item7_no_history_before_activation():
    waits('i7-no-history-before-activation', World('i7', activated=False).run('x'), 11)
    admits(World('i7-control').run('x'), 8)


def m1759_missing_step_row():
    waits('m1759-missing-step-row', World('m1759-step').run('x', step=None).row('x', None), 14, self_run='x', waiting=('x',))


def m1759_missing_step_row_fallback():
    waits('m1759-missing-step-row-fallback', World('m1759-step-fb').run('x', step=None).row('x', None), self_run='x',
          waiting=('x',), cores=3, fallback=True)


def m1759_live_unrecorded_agent_waiter():
    # The step's recorded agent pid lives (this test's own pid, a live process to the engine's check) and is no queued
    # gate's: a live unrecorded agent, not a waiter. Control: the same pid is the run's queued gate.
    live = os.getpid()
    waits('m1759-live-agent-waiter', World('m1759-live-agent').run('x', step=('ci', 'running', live)).proved('x'), 11, waiting=('x',))
    admits(World('m1759-live-agent-control').run('x', step=('ci', 'running', live)).proved('x').waiter('x', live), 8, waiting=('x',))


def m1759_visible_attempt_masks_predecessor():
    # X has an earlier unproven launch (a row with no key) and a live later attempt seen at 0.5 GiB: 1 (A) + 3 (R for the
    # earlier) + 8 = 12 against 8.5 + 0.5 waits; dropping the earlier gives 9 against 9.
    w = World('m1759-mask').run('x').row('x', None).row('x', 'key-x').record('x', 'x').process(10, start=100100000)
    w.rss['x'], w.own[10] = 0.5, 0.5
    waits('m1759-visible-masks-predecessor', w, 12)


def m1759_two_passive_attempts():
    w = World('m1759-passive', available=13).run('x').proved('x').process(10, start=100100000).process(11, start=100100000)
    w.record('a', 'x', reserves=False).record('b', 'x', reserves=False, root=[11, 100100000])
    waits('m1759-two-passive', w, 14)


def m1759_fallback_counts_attempts():
    w = World('m1759-fb').run('x').proved('x').record('a', 'x').record('b', 'x', root=[11, 100100000])
    waits('m1759-fallback-two-attempts', w.process(10, start=100100000).process(11, start=100100000), self_run='x', cores=6, fallback=True)
    admits(World('m1759-fb-control').run('x').proved('x').record('a', 'x').process(10, start=100100000), self_run='x', cores=6,
           fallback=True)


def m1759_uncounted_self():
    waits('m1759-uncounted-self', World('m1759-uncounted').run('x', counted=False).row('x', None), 11, self_run='x')
    waits('m1759-uncounted-self-fallback', World('m1759-uncounted-fb').run('x', counted=False).row('x', None), self_run='x',
          cores=3, fallback=True)


def m1759_partial_bulk():
    w = quiet_world('m1759-partial')  # X's root's record is the read's truncated tail: the read is not whole
    w.tail = kinfo(10, 1, 100100000)[:16]
    waits('m1759-partial-bulk', w, 11)


def m1759_short_coalition():
    w = orphan_world('m1759-coalition'); w.record('x', 'x', coalition=263); w.processes[42].update(coalition=263, coalition_len=1)
    waits('m1759-short-coalition', w, 11)
    w = orphan_world('m1759-coalition-control'); w.record('x', 'x', coalition=263); w.processes[42]['coalition'] = 7
    admits(w, 8)


def m1759_missing_members():
    # Only X's recorded member (pid 42, alive, outside the launch coalition) holds X; with its members field missing the
    # record is unknown: the decision waits. Read as an empty member list it would end X and admit at 8.
    w = quiet_world('m1759-members').process(42, coalition=9)
    w.record('x', 'x', members=[[42, 101000000]], drop=('members',))
    waits('m1759-missing-members', w, unknown='attempt-x.json')
    w = quiet_world('m1759-members-control').process(42, coalition=9).record('x', 'x', members=[[42, 101000000]])
    waits('m1759-members-control', w, 11)


def m1759_root_exits_during_census():
    w = quiet_world('m1759-race').process(10, start=100100000, confirm='gone')
    out = w.decide()
    w.close()
    harm('m1759-root-exits-during-census', not out['admit'], out)


def m1759_shared_key_one_row():
    w = World('m1759-shared').run('x').row('x', 'same')
    w.record('a', 'x', session_key='same', ended_us=1).record('b', 'x', session_key='same', ended_us=1)
    waits('m1759-shared-key-one-row', w, 11, self_run='x')  # one row and two records, none bound: one history charge (Main 1818)
    admits(World('m1759-unique').run('x').proved('x', 'a').proved('x', 'b'), 8, self_run='x')


def m1761_history_completeness():
    waits('m1761-no-activation', World('m1761-noact', activated=False).run('x').proved('x'), 11, self_run='x')
    waits('m1761-created-before-activation', World('m1761-before').run('x', created=NOW - 2000).proved('x'), 11, self_run='x')
    w = World('m1761-ungated').run('x').proved('x').row('x', 'key-o', agent='codex').record('o', 'x', ended_us=1)
    waits('m1761-ungated-agent', w, 11, self_run='x')
    admits(World('m1761-control').run('x').proved('x'), 8, self_run='x')


# Main 1656/1683 real-process cases as fact-level twins (Main 1761: their red engine is cff47cc2e, the last engine
# before attribution, whose gate cannot run the real-process fixtures' launches, so their reds are shown here).

def m1656_escaped_descendant():
    # X's root is gone and its escaped descendant (pid 42: own session, lineage lost, X's coalition) lives: X holds.
    waits('m1656-escape-fact', orphan_world('m1656-escape'), 11)
    admits(quiet_world('m1656-escape-control'), 8)


def m1683_copied_identity():
    # X's orphan (pid 42) carries Y's attempt identity in its environment (FM_LAUNCH_ATTEMPT=y, as the kernel reports
    # it); Y's own attempt has ended. The identity never moves the orphan to Y: X holds (11 against 8.5).
    w = orphan_world('m1683-copied').run('y').proved('y').row('y', 'key-y').record('y', 'y', root=[11, 100100000], ended_us=1)
    w.processes[42]['marker'] = 'y'
    control(b'FM_LAUNCH_ATTEMPT=y' in w.sysctl(proc.CTL_KERN, proc.KERN_PROCARGS2, 42), 'the copied identity is on the orphan')
    waits('m1683-copied-identity-fact', w, 11)


def m1683_foreign_in_coalition():
    # Y's orphan (pid 43) inside the launch coalition outlives X and Y: both held, 3 + 3 + 8 = 14 against 12.
    w = World('m1683-foreign-in', available=12).run('x').run('y').proved('x').proved('y').row('x', 'key-x').row('y', 'key-y')
    w.record('x', 'x').record('y', 'y', t0_us=100500000, root=[11, 100600000]).process(43, start=101000000)
    waits('m1683-foreign-in-fact', w, 14)


def m1683_pid_reuse_join():
    # X's root lives (pid 10); the reading shows X's run at 10 GiB and a 10 GiB figure under pid 10 with another
    # generation's start (the same second, 0.5 s later): the join is refused, the attempt is unseen: 3 + 10 + 8 = 21
    # against 8.5 + 10 = 18.5 waits; crediting the figure to the attempt would give 10 + 8 = 18, admitted.
    w = quiet_world('m1683-reuse').process(10, start=100100000)
    w.rss['x'], w.own[10] = 10, 10
    w.decide_hook = lambda report: [row.update(start_us=row['start_us'] + 500000) for row in report['processes']]
    waits('m1683-pid-reuse-fact', w, 21)


def m1683_p1f_own_live():
    # P1(f): X's launch, bound by its own key, left a live orphan: X holds at R (11 against 8.5); foreign control admits.
    waits('m1683-p1f-own-live-fact', orphan_world('m1683-p1f'), 11)
    w = orphan_world('m1683-p1f-foreign'); w.processes[42]['coalition'] = 9
    admits(w, 8)


def m1656_key_binding():
    # Rows A [10, 40] and B [20, 40] with no keys and two ended records starting at 15 and 25 s (each start inside a row,
    # one unique interval matching): not shown ended, held; own keys with their records bind.
    w = World('m1656-keys').run('x').row('x', None, started=10, completed=40).row('x', None, started=20, completed=40)
    w.record('r0', 'x', session_key=None, t0_us=15000000, ended_us=1).record('r1', 'x', session_key=None, t0_us=25000000, ended_us=1)
    waits('m1656-key-binding-fact', w, 11)
    admits(World('m1656-keys-control').run('x').proved('x', 'r0').proved('x', 'r1'), 8)


def pending_released(world, running):
    world.install()
    try:
        return [(row[2], row[3]) for row in engine.live_pending(str(world.pool), set(running))]
    finally:
        proc.sysctl, proc.libc = REAL_SYSCTL, REAL_LIBC
        world.close()


def m1759_claim_read_once():
    # The claim names run-old as present when it was made; a second read of the claim fails. Read once, its seen rows
    # stand: run-old never releases it. (claim_record, the claim file's reader, gives the claim once, then nothing.)
    w = World('m1759-claim').run('run-old', step=('review', 'running', None), nonce='N')
    w.pending(dict(holder=1, args=None, before=[], created_ns=1, client_nonce=None),
              claim=dict(pid=os.getpid(), nonce='N', seen=['run-old'], direct=True, client=os.getpid(), provisional=False))
    real, reads = engine.claim_record, []

    def once(path):
        reads.append(path)
        return real(path) if len(reads) == 1 else None
    engine.claim_record = once
    try:
        got = pending_released(w, {'run-old'})
    finally:
        engine.claim_record = real
    harm('m1759-claim-seen-row', got == [(False, None)], got)


def m1759_undecodable_pending():
    w = World('m1759-undecodable').run('run-own', nonce='N')
    w.pending(raw=b'{', claim=dict(pid=os.getpid(), nonce='N', seen=[], direct=True, client=os.getpid(), provisional=False))
    got = pending_released(w, {'run-own'})
    harm('m1759-undecodable-released', got == [(False, None)], got)


def m1759_unknown_claimant():
    w = World('m1759-unknown-claimant').run('run-B', nonce='N')
    w.pending(dict(holder=1, args=None, before=[], created_ns=1, client_nonce=None), claim=dict(pid=os.getpid(), nonce='N', seen=[], direct=True, client=os.getpid(), provisional=False))
    w.pending(dict(holder=1, args=None, before=[], created_ns=2, client_nonce=None), claim='{unreadable')
    got = pending_released(w, {'run-B'})
    harm('m1759-unknown-claimant-collision', not any(released for released, _ in got), got)


def m1712_claimant_nonce():
    w = World('m1712-nonce').run('run-A', nonce='nonce-A')
    w.pending(dict(holder=1, args=['axi', 'run', '--launch-nonce', 'nonce-A'], before=[], created_ns=1, client_nonce=None),
              claim=dict(pid=os.getpid(), nonce='nonce-B', seen=[], direct=True, client=os.getpid(), provisional=False))
    got = pending_released(w, {'run-A'})
    harm('m1712-outer-nonce', got == [(False, None)], got)
    w = World('m1712-nonce-control').run('run-B', nonce='nonce-B')
    w.pending(dict(holder=1, args=['axi', 'run', '--launch-nonce', 'nonce-A'], before=[], created_ns=1, client_nonce=None),
              claim=dict(pid=os.getpid(), nonce='nonce-B', seen=[], direct=True, client=os.getpid(), provisional=False))
    got = pending_released(w, {'run-B'})
    control(got == [(True, 'run-B')], got)


def m1759_completed_first_run():
    # An admitted command's first no-nonce client created a run that has completed; an identical second client must not
    # claim the admission. Control: with no run created since the admission, the unused reservation is claimed.
    args = ['axi', 'run', '--intent', 'reg-x']
    for label, completed in (('completed', True), ('none', False)):
        w = pending_world('m1759-completed-' + label)
        w.pending(dict(holder=os.getppid(), args=args, before=[], created_ns=time.time_ns() - 10 ** 9, client_nonce=None))
        if completed:
            w.sql("INSERT INTO runs (id, status, repo_id, created_at) VALUES ('first', 'completed', 'repo', ?)", (NOW,))
        engine.HOST_STATE_DB = str(w.db)
        engine.sibling = lambda module, filename: proc
        got = engine.claim_round(str(w.pool), args, True)
        w.close()
        if completed:
            harm('m1759-completed-first-reuse', got is None, got)
        else:
            control(got == os.getppid(), got)


def m1759_row_between_census_and_claim():
    # A delayed row carrying the claimant's nonce N arrives after claim_round's census and before its claim is linked
    # (here: while the claim's binding is read). The claim is withdrawn (decided on its own), never made final over that
    # row. Control: with no row arriving, the unused reservation is claimed and its claim made final.
    args = ['axi', 'run', '--intent', 'x', '--launch-nonce', 'N']
    for label, arrives in (('arrives', True), ('none', False)):
        w = World('m1759-window-' + label)
        path = w.pending(dict(holder=os.getppid(), args=args, before=[], created_ns=time.time_ns() - 10 ** 9, client_nonce=None))
        engine.HOST_STATE_DB = str(w.db)
        engine.sibling = lambda module, filename: proc
        real_binding = engine.start_binding

        def binding(cwd, words, w=w, arrives=arrives):
            if arrives:
                w.sql("INSERT INTO runs (id, status, repo_id, created_at, launch_nonce) VALUES ('late', 'running', 'repo', ?, 'N')", (NOW,))
            return None
        engine.start_binding = binding
        try:
            got = engine.claim_round(str(w.pool), args, True)
        finally:
            engine.start_binding = real_binding
        claim = Path(path + '.claimed')
        final = json.loads(claim.read_text()) if claim.exists() else None
        w.close()
        if arrives:
            harm('m1759-row-in-claim-window', got is None and final is None, got, final)
        else:
            control(got == os.getppid() and final and final.get('seen') == [], got, final)


# Main 1812 (outside review of 8de219173): each a red at 8de219173 and green at the head, with its control.

def m1812_listing_unreadable():
    # Finding 1: the pool's attempt listing fails (PermissionError). It is unknown, never an empty pool: the decision
    # waits. At an engine that read it as empty, X's live attempt disappears and its run's empty history looks complete.
    w = World('m1812-listing').run('x').record('x', 'x').process(10, start=100100000)
    w.deny_listing = True
    waits('m1812-listing-unreadable', w, unknown='listing')
    admits(World('m1812-listing-control').run('x'), 8)  # a genuinely empty pool and history: admitted


class Stop(BaseException):
    """Ends an in-process gate run at the moment it would start its agent."""


def m1812_passive_under_lock():
    # Finding 2: a counted run's non-CI launch publishes its attempt record while holding the start lock, so no
    # decision's census can be taken between its read and its publication (Main 1812 A). Through the engine's own
    # cmd_launch_gate, in this process, with the agent start replaced by a probe of the lock; control: the gated path
    # holds it too.
    import argparse
    for label, step in (('passive', ('review', 'running', None)), ('gated', ('ci', 'running', None))):
        w = World('m1812-lock-' + label, available=40).proved('x') if label == 'gated' else World('m1812-lock-' + label, available=40)
        worktree = w.dir / 'wt-x'
        worktree.mkdir()
        w.sql("INSERT INTO runs (id, status, repo_id, worktree_dir, branch, created_at) VALUES ('x', 'running', 'repo', ?, 'fm/x', ?)",
              (str(worktree), NOW - 500))
        w.sql("INSERT INTO step_results (id, run_id, step_name, step_order, status, agent_pid, round_started_at) VALUES"
              " ('x-s', 'x', ?, 1, ?, NULL, ?)", (step[0], step[1], NOW - 10))
        w.install()
        seen = {}

        def probe(command, directory, base):
            fd = engine.open_lock(os.path.join(directory, 'pipeline-start.lock'))
            try:
                seen['held'] = not engine.try_lock(fd)
            finally:
                os.close(fd)
            raise Stop()
        real = dict(start_watched=engine.start_watched, host_observation=engine.host_observation)
        engine.start_watched = probe
        report = dict(available_bytes=40 * GIB, errors=[], processes=[], runs={})
        engine.host_observation = lambda fresh=False: dict(reasons=[], memory=report)
        engine.measured_reservations = lambda report, running: (R, S, 2)
        engine.active_term = lambda report: (A, 2)
        saved = dict(os.environ), os.getcwd()
        os.environ.update(FM_CPU_POOL_DIR=str(w.pool), HOME=str(w.dir), FM_HOME=str(w.dir))
        os.chdir(str(worktree))
        try:
            engine.cmd_launch_gate(argparse.Namespace(command=['--', 'agent']))
        except Stop:
            pass
        except BarredProcessCall:
            raise
        finally:
            os.chdir(saved[1])
            os.environ.clear()
            os.environ.update(saved[0])
            engine.start_watched, engine.host_observation = real['start_watched'], real['host_observation']
            proc.sysctl, proc.libc = REAL_SYSCTL, REAL_LIBC
            w.close()
        control('held' in seen, label, 'the gate reached its agent start')
        if label == 'passive':
            harm('m1812-passive-unlocked', seen['held'], 'a passive launch published outside the start lock')
        else:
            control(seen['held'], 'the gated launch holds the start lock')


def m1812_malformed_fields():
    # Finding 3: a record with any one of repo, step, gate or watcher of the wrong type is unknown: the decision waits.
    # Read as valid, the quiet record would end and its bound row would admit at 8. Control: the same record well formed.
    for field, bad in (('repo', []), ('step', []), ('gate', 'garbled'), ('watcher', {'bad': 1})):
        w = quiet_world('m1812-field-' + field).record('x', 'x', **{field: bad})
        waits('m1812-malformed-' + field, w, unknown='attempt-x.json')
    admits(quiet_world('m1812-field-control'), 8)


def m1812_successive_censuses():
    # Finding 3: X's record carries a quiet stamp from an earlier census (quiet_us); this decision's first census shows
    # nothing of X, but a descendant (pid 42, lineage lost, X's coalition) appears at its next census. Two successive
    # censuses in one decision see it: X holds (11 against 8.5). An engine ending X on the stale stamp and one quiet
    # census admits at 8. Control: both censuses quiet: X ends and the start is admitted at 8.
    for label, appears in (('descendant', True), ('quiet', False)):
        w = quiet_world('m1812-census-' + label).record('x', 'x', quiet_us=1)
        if appears:
            w.scheduled = {42: (2, dict(parent=1, start=101000000, coalition=7))}
        out = w.decide()
        w.close()
        if appears:
            harm('m1812-non-successive-census', not out['admit'], out)
        else:
            control(out['admit'] and out['projected'] == 8, out)


def m1812_partial_join():
    # X's root (pid 10) and member (pid 42) live; the reading joins the root (1 GiB) but shows pid 42 under another start
    # time: the attempt is not seen whole, so it counts at least R: 3 + 20 + 8 = 31 against 8.5 + 21 = 29.5 waits. Counting
    # it as seen at its joined 1 GiB would give 1 + 20 + 8 = 29, admitted.
    w = quiet_world('m1812-partial').process(10, start=100100000).process(42, start=101000000)
    w.record('x', 'x', members=[[42, 101000000]])
    w.rss['x'], w.own[10], w.own[42] = 21, 1, 20
    w.decide_hook = lambda report: [row.update(start_us=row['start_us'] + 1) for row in report['processes'] if row['pid'] == 42]
    waits('m1812-partial-join', w, 31)


def pending_world(name):
    # The run database and pool only: the kernel stays real (the claim path reads this process's own ancestry).
    w = World(name)
    engine.sibling = lambda module, filename: proc
    engine.HOST_STATE_DB = str(w.db)
    engine.process_argv = lambda pid: ['fake']
    engine.start_binding = lambda cwd, args: None  # its git reads start processes; a claim's binding decides nothing
    return w


def claim_once(w, args, **kw):
    import inspect
    if 'direct' in inspect.signature(engine.claim_round).parameters and 'direct' in kw:
        return engine.claim_round(str(w.pool), args, True, kw['direct'])
    return engine.claim_round(str(w.pool), args, True)


def m1812_claim_boundaries():
    # Finding 4: a run row arriving at any boundary of the claim (during its pending census, after its rows read, while
    # the claim is published, after it is published) never lets a claim stand: a no-nonce first client's row, or a
    # delayed row carrying the claimant's nonce. Each injection is asserted to have fired. Control: none arrives, the
    # unused reservation is claimed and its claim names no row. (Their reds at 8de219173 are the review's
    # pending_route_probe.py and pending_late_row_probe.py, run unmodified.)
    args = ['axi', 'run', '--intent', 'x', '--launch-nonce', 'N']
    for row_nonce in (None, 'N'):
        for boundary in ('census', 'after-read', 'publish', 'after-publish', None):
            w = pending_world('m1812-boundary-%s-%s' % (row_nonce, boundary))
            path = w.pending(dict(holder=os.getppid(), args=args, before=[], created_ns=time.time_ns() - 10 ** 9, client_nonce=None))
            fired = []

            def inject(w=w, row_nonce=row_nonce, fired=fired):
                if not fired:
                    w.sql("INSERT INTO runs (id, status, repo_id, created_at, launch_nonce) VALUES ('late', 'running', 'repo', ?, ?)",
                          (NOW, row_nonce))
                    fired.append(True)
            real = dict(pending_census=engine.pending_census, start_binding=engine.start_binding, publish_claim=engine.publish_claim,
                        run_rows=engine.run_rows)
            if boundary == 'census':
                def census(*a, **k):
                    inject()
                    return real['pending_census'](*a, **k)
                engine.pending_census = census
            elif boundary == 'after-read':
                def binding(*a, **k):
                    inject()
                    return real['start_binding'](*a, **k)
                engine.start_binding = binding
            elif boundary == 'publish':
                def publishing(*a, **k):
                    inject()
                    return real['publish_claim'](*a, **k)
                engine.publish_claim = publishing
            elif boundary == 'after-publish':
                def published(*a, **k):
                    done = real['publish_claim'](*a, **k)
                    inject()
                    return done
                engine.publish_claim = published
            try:
                got = engine.claim_pending(str(w.pool), args)
            finally:
                for name, value in real.items():
                    setattr(engine, name, value)
            final = json.loads(Path(path + '.claimed').read_text()) if Path(path + '.claimed').exists() else None
            w.close()
            if boundary is None:
                control(got == os.getppid() and final and final['seen'] == [], 'an unused reservation is claimed', got, final)
            else:
                control(fired, boundary, 'the injected row arrived')
                harm('m1812-claim-boundary', got is None and final is None, boundary, row_nonce, got, final)


def m1812_explained_by_admission_set():
    # Finding 5: row 'first' (nonce N) was running when Q (client nonce N) was admitted, so it is not Q's own; it is
    # unexplained for P, whose claim is refused. Control: Q admitted before it, so 'first' is Q's own row, and P's
    # unused reservation is claimed.
    args = ['axi', 'run', '--intent', 'x']
    for label, before in (('in-before', ['first']), ('owned', [])):
        w = pending_world('m1812-explained-' + label).run('first', step=('review', 'running', None), nonce='N', created=NOW)
        w.pending(dict(holder=os.getppid(), args=args, before=[], created_ns=time.time_ns() - 10 ** 9, client_nonce=None))
        w.pending(dict(holder=999999, args=['axi', 'run', '--intent', 'q'], before=before, created_ns=time.time_ns() - 10 ** 9,
                       client_nonce='N'))  # Q's holder is no ancestor of this client: only P's reservation is claimable
        got = engine.claim_pending(str(w.pool), args)
        w.close()
        if before:
            harm('m1812-explained-ignores-admission-set', got is None, got)
        else:
            control(got == os.getppid(), got)


def m1812_unknown_claimant():
    # Finding 6: B's claim carries a nonce of the wrong type, so B's claimant is unknown: A (nonce N) is not released by
    # the row carrying N, B is not released by K7 though its pid is dead, and the decision waits. Control: B's claim
    # readable with another nonce: A's own row releases A.
    for label, b_nonce in (('malformed', 123), ('readable', 'M')):
        w = pending_world('m1812-unknown-' + label).run('row-B', step=('review', 'running', None), nonce='N')
        dead = SimpleNamespace(pid=DEAD_PID)  # no process has it
        w.pending(dict(holder=1, args=None, before=[], created_ns=1, client_nonce=None),
                  claim=dict(pid=os.getpid(), nonce='N', seen=[], direct=True, client=os.getpid(), provisional=False))
        w.pending(dict(holder=1, args=None, before=[], created_ns=2, client_nonce=None),
                  claim=dict(pid=dead.pid, nonce=b_nonce, seen=[], direct=True, client=dead.pid, provisional=False))
        got = pending_released(w, {'row-B'})
        if b_nonce == 123:
            harm('m1812-unknown-claimant-released', not any(released for released, _ in got), got)
        else:
            control(got == [(True, 'row-B'), (True, None)], got)


def m1812_incomplete_own_entry():
    # Finding 6: this start's own enclosing entry lacks its admission set and arguments: it is unknown, so it is counted
    # (never skipped as this start's own) and the decision waits. Control: complete and unclaimed, with its admitted
    # client not running, it is skipped.
    for label, entry in (('incomplete', dict(holder=os.getppid(), created_ns=1, client_nonce=None)),
                         ('complete', dict(holder=os.getppid(), created_ns=1, client_nonce=None, before=[], args=['axi', 'run']))):
        w = pending_world('m1812-own-' + label)
        w.pending(entry)
        count = engine.counted_pending(str(w.pool), set())
        w.close()
        if label == 'incomplete':
            harm('m1812-incomplete-own-entry-skipped', count == 1, count)
        else:
            control(count == 0, count)
    w = World('m1812-own-decision')
    w.pending(dict(holder=os.getppid(), created_ns=1, client_nonce=None))
    waits('m1812-incomplete-own-entry-admitted', w, unknown='pending start')


def m1812_undecodable_claim():
    # Finding 6: a claim of invalid UTF-8 is unknown: the claim path returns no holder (the start is decided on its
    # own, and that decision waits), never an exception the entrypoint turns into 125.
    w = pending_world('m1812-utf8')
    path = w.pending(dict(holder=os.getppid(), args=['axi', 'run'], before=[], created_ns=1, client_nonce=None))
    Path(path + '.claimed').write_bytes(b'\xff')
    try:
        got = engine.claim_pending(str(w.pool), ['axi', 'run'])
        raised = None
    except ValueError as exc:
        got, raised = None, exc
    w.close()
    harm('m1812-undecodable-claim-raises', raised is None, repr(raised))
    control(got is None, got)


def m1812_nested_shell_two_clients():
    # Finding 7: an admitted shell (pid 202, below the holder 4242) claims the reservation for its one client. The first
    # client below it (301) binds the claim; a second live client (303) is decided on its own. Controls: 301 through
    # one more route gets the holder; a client below a claimant that is the client itself (direct) gets it.
    import inspect
    args = ['axi', 'run', '--intent', 'x']
    w = pending_world('m1812-nested')
    w.pending(dict(holder=4242, args=args, before=[], created_ns=1, client_nonce=None))
    real = dict(getpid=os.getpid, ancestors=engine.ancestors, process_table=engine.process_table, pid_dead=engine.pid_dead,
                process_argv=engine.process_argv, start_binding=engine.start_binding)
    table = {202: 4242}
    engine.process_table = lambda: dict(table)
    engine.process_argv = lambda pid: ['no-mistakes'] + args if pid in (301, 303) else ['bash']
    engine.pid_dead = lambda pid: False
    engine.start_binding = lambda cwd, words: None
    direct_kw = {'direct': False} if 'direct' in inspect.signature(engine.claim_round).parameters else {}

    def as_pid(pid, chain, **kw):
        os.getpid = lambda: pid
        engine.ancestors = lambda _: list(chain)
        try:
            with engine.start_lock(str(w.pool)):
                found = engine.claim_round(str(w.pool), args, True, **kw)
                return found if found is not None else engine.claim_round(str(w.pool), args, False, **kw)
        finally:
            os.getpid = real['getpid']
    try:
        shell = as_pid(202, [4242, 1], **direct_kw)
        table.update({301: 202})
        first = as_pid(301, [202, 4242, 1])
        again = as_pid(301, [301, 202, 4242, 1])
        table.update({303: 202})
        second = as_pid(303, [202, 4242, 1])
    finally:
        for name, value in real.items():
            if name == 'getpid':
                os.getpid = value
            else:
                setattr(engine, name, value)
        w.close()
    control(shell == 4242 and first == 4242 and again == 4242, shell, first, again)
    harm('m1812-second-live-client', second is None, second)


# The perturbation generator (Main 1759): less evidence never admits, and never lowers the projected demand.

BASES = {
    'held orphan': lambda: orphan_world('p-orphan'),
    'live root': lambda: quiet_world('p-root').process(10, start=100100000),
    'unproven row': lambda: World('p-row').run('x').row('x', None),
    'shared key': lambda: World('p-shared').run('x').row('x', 's').row('x', 's')
    .record('a', 'x', session_key='s', ended_us=1).record('b', 'x', session_key='s', ended_us=1),
    'no activation': lambda: World('p-noact', activated=False).run('x').proved('x'),
    'two live attempts': lambda: World('p-two', available=13).run('x').proved('x').record('a', 'x').record('b', 'x', root=[11, 100100000])
    .process(10, start=100100000).process(11, start=100100000),
}


def drop_field(field):
    def drop(w):
        for path in w.pool.glob('attempt-*.json'):
            record = json.loads(path.read_text())
            record.pop(field, None)
            path.write_text(json.dumps(record))
    return drop


OPERATORS = dict(
    [('drop the step row', lambda w: w.sql("DELETE FROM step_results WHERE run_id = 'x'")),
     ('drop an invocation row', lambda w: w.sql('DELETE FROM agent_invocations WHERE rowid = (SELECT max(rowid) FROM agent_invocations)'))]
    + [('drop record field ' + field, drop_field(field)) for field in ('members', 'root', 't0_us', 'coalition', 'session_key', 'ended_us', 'repo', 'step', 'gate', 'watcher')]
    + [('truncate a record', lambda w: [p.write_text(p.read_text()[:20]) for p in sorted(w.pool.glob('attempt-*.json'))[:1]]),
       ('a partial bulk read', lambda w: setattr(w, 'tail', kinfo(10, 1, 100100000)[:16])),
       ('short coalition reads', lambda w: [p.update(coalition_len=1) for p in w.processes.values()]),
       ('processes exit during the census', lambda w: [p.update(confirm='gone') for p in w.processes.values()]),
       ('drop the activation record', lambda w: (w.pool / 'gate-activation.json').unlink(missing_ok=True)),
       ('an agent not gated', lambda w: w.sql("UPDATE agent_invocations SET agent = 'codex' WHERE rowid = (SELECT min(rowid) FROM agent_invocations)")),
       ('queue the run', dict(waiting=('x',))),
       ('request as the run', dict(self_run='x')),
       ('request as the run, now uncounted', 'uncounted')])


def perturbation_group():
    for base_name, build in BASES.items():
        base = build()
        reference = settle(base)
        base.close()
        control(not reference['admit'], base_name, 'the base world waits', reference)
        for op_name, op in OPERATORS.items():
            w, kw = build(), {}
            if isinstance(op, dict):
                kw = op
            elif op == 'uncounted':
                w.sql("UPDATE runs SET ci_ready_at = ? WHERE id = 'x'", (NOW,))
                kw = dict(self_run='x')
            else:
                op(w)
            ident = 'perturb:%s:%s' % (base_name, op_name)
            try:
                out = settle(w, **kw)
                ok = not out['admit'] and (out['projected'] is None or reference['projected'] is None
                                           or out['projected'] >= reference['projected'] - 1e-6)
                if op_name == 'drop an invocation row' and out['admit']:
                    # The strict checker (Main 1812 E, Main 1818): a world that still waits must keep its projection,
                    # and the one admission allowed is a history the Main 1761 proof shows complete: no row and no
                    # record of x left, and the activation record before x.
                    with sqlite3.connect(w.db) as c:
                        rows = c.execute("SELECT count(*) FROM agent_invocations WHERE run_id = 'x'").fetchone()[0]
                    recorded = any(json.loads(p.read_text()).get('run') == 'x' for p in w.pool.glob('attempt-*.json'))
                    ok = rows == 0 and not recorded and (w.pool / 'gate-activation.json').exists()
                harm_id = ident.replace(':', '/')  # a harm id carries no colon
                results[ident] = 'pass' if ok else ('FAIL: HarmError: harm:%s: %r' % (harm_id, (reference['projected'], out)))[:900]
            except (Exception, BarredProcessCall) as exc:  # noqa: BLE001 - an error is reported, never counted red
                results[ident] = 'FAIL: %s: %s' % (type(exc).__name__, str(exc)[:600])
            finally:
                w.close()
                proc.sysctl, proc.libc = REAL_SYSCTL, REAL_LIBC


CASES = (('F1 an unreadable confirming read holds', f1_unreadable_confirming_read),
         ('F2 an unreadable attempt record reserves', f2_unreadable_record),
         ('F6 an unknown launch coalition excludes nothing', f6_unknown_launch_coalition),
         ('F7 a queued later fix keeps an unproven launch counted', f7_queued_fix_keeps_unproven),
         ('F8 every owner of a pid keeps it, at a fit boundary', f8_every_owner_kept),
         ('Main 1712 item 1 every CI state keeps an unproven launch counted', item1_every_ci_state),
         ('Main 1712 item 2 a same-run launch never passes its live or unproven attempt', item2_same_run),
         ('Main 1712 item 4 another owner is no proof a possible descendant is foreign', item4_another_owner),
         ('Main 1712 item 5 short, other-generation and malformed reads hold', item5_reads),
         ('Main 1712 item 6 a live attempt counts whatever its run status', item6_run_status),
         ('Main 1712 item 7 a run with no history before activation holds', item7_no_history_before_activation),
         ("Main 1712 item 3 a row ends only its claimant's own reservation", m1712_claimant_nonce),
         ('Main 1759 a missing step row holds', m1759_missing_step_row),
         ('Main 1759 a missing step row holds the count fallback too', m1759_missing_step_row_fallback),
         ('Main 1759 a live unrecorded agent is no waiter', m1759_live_unrecorded_agent_waiter),
         ('Main 1759 a visible attempt never masks an unproven predecessor', m1759_visible_attempt_masks_predecessor),
         ('Main 1759 two passive live attempts count twice', m1759_two_passive_attempts),
         ('Main 1759 the fallback counts attempts', m1759_fallback_counts_attempts),
         ('Main 1759 an uncounted requesting run keeps its history', m1759_uncounted_self),
         ('Main 1759 a partial bulk read holds', m1759_partial_bulk),
         ('Main 1759 a short coalition read is unknown', m1759_short_coalition),
         ('Main 1759 a missing members field holds', m1759_missing_members),
         ('Main 1759 a root that exits during the census holds', m1759_root_exits_during_census),
         ('Main 1759 two records on one shared-key row hold', m1759_shared_key_one_row),
         ('Main 1761 history completeness needs the activation record and gated agents', m1761_history_completeness),
         ('Main 1759 a claim is read once', m1759_claim_read_once),
         ('Main 1759 an undecodable pending entry is never released', m1759_undecodable_pending),
         ('Main 1759 an unknown claimant blocks a nonce release', m1759_unknown_claimant),
         ('Main 1759 a completed first run never lends its admission', m1759_completed_first_run),
         ('Main 1759 a row inside the claim window withdraws the claim', m1759_row_between_census_and_claim),
         ('Main 1812 an unreadable attempt listing waits', m1812_listing_unreadable),
         ('Main 1812 a passive launch publishes under the start lock', m1812_passive_under_lock),
         ('Main 1812 a malformed record field waits', m1812_malformed_fields),
         ('Main 1812 an attempt ends only at two successive censuses', m1812_successive_censuses),
         ('Main 1812 a partly joined attempt counts at least R', m1812_partial_join),
         ('Main 1812 a row at any claim boundary withdraws the claim', m1812_claim_boundaries),
         ("Main 1812 a row in another start's admission set is unexplained", m1812_explained_by_admission_set),
         ('Main 1812 an unknown claimant releases nothing', m1812_unknown_claimant),
         ('Main 1812 an incomplete own entry is counted', m1812_incomplete_own_entry),
         ('Main 1812 an undecodable claim is unknown, not a refusal', m1812_undecodable_claim),
         ('Main 1812 a shell admission covers one client', m1812_nested_shell_two_clients),
         ('Main 1656 an escaped descendant holds its attempt (facts)', m1656_escaped_descendant),
         ("Main 1683 a copied identity never moves X's orphan to Y (facts)", m1683_copied_identity),
         ('Main 1683 a foreign in-coalition orphan delays admission (facts)', m1683_foreign_in_coalition),
         ('Main 1683 a reused pid never credits another generation (facts)', m1683_pid_reuse_join),
         ('Main 1683 P1(f) own-live waits, foreign admits (facts)', m1683_p1f_own_live),
         ("Main 1656 only a row's own session key binds it (facts)", m1656_key_binding))
for name, body in CASES:
    case(name, body)
case('perturbation group', perturbation_group)
print(json.dumps(results, indent=1))
sys.exit(0 if all(value == 'pass' for value in results.values()) else 1)
