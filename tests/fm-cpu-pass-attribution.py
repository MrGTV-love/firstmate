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
import contextlib
import ctypes
import importlib.util
import io
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
REAL_PROCESS_ARGV = engine.process_argv
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
        self.unstable = {}  # pid -> resident GiB read with a start time that changed during the read (rss_source unstable)
        self.argv = {}  # pid -> (declared argc, words) its KERN_PROCARGS2 answer carries
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
            if confirm == 'oversize':
                return kinfo(mib[3], p['parent'], p['start']) + b'\0' * 16  # a longer answer than one record
            return kinfo(mib[3], p['parent'], p['start'] + (1 if confirm == 'other' else 0), p.get('traced', False))
        if mib[:2] == (proc.CTL_KERN, proc.KERN_PROCARGS2) and mib[2] in self.argv:
            argc, words = self.argv[mib[2]]
            return struct.pack('i', argc) + b'/bin/fake\0\0' + b''.join(w.encode() + b'\0' for w in words)
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
        engine.process_argv = REAL_PROCESS_ARGV if getattr(self, 'real_argv', False) else (lambda pid: ['fake'])

    def observe(self, fallback=False):
        # The memory reading and record facts a decision reads, installed for a caller that decides on its own.
        self.install()
        report = dict(available_bytes=int(self.available * GIB), errors=[], processes=[], runs={})
        engine.host_observation = lambda fresh=False: dict(reasons=[], memory=report)
        engine.measured_reservations = lambda report, running: None if fallback else (R, S, 2)
        engine.active_term = lambda report: (A, 2)

    def decide(self, self_run=None, waiting=(), cores=18, fallback=False):
        self.install()
        report = dict(available_bytes=int(self.available * GIB), errors=[],
                      processes=[dict(pid=pid, start_us=self.processes[pid]['start'], rss_bytes=int(size * GIB), rss_source='task')
                                 for pid, size in self.own.items()]
                      + [dict(pid=pid, start_us=self.processes[pid]['start'], rss_bytes=int(size * GIB), rss_source='unstable')
                         for pid, size in self.unstable.items()],
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
    waits('f1-unreadable-confirm', w, unknown="could be run x")  # a possible orphan, its memory unjoined (Main 1876 J)
    admits(quiet_world('f1-control'), 8)


def f2_unreadable_record():
    # An unreadable record is unknown: the decision waits, naming it (Main 1812 B, Main 1819).
    waits('f2-unreadable-record', World('f2').run('x').proved('x').record('live', 'x', raw='{not json'), unknown='attempt-live.json')
    waits('f2-unreadable-record-parked', World('f2-parked').record('live', 'p', raw='{not json'), unknown='attempt-live.json')


def f6_unknown_launch_coalition():
    w = orphan_world('f6'); w.record('x', 'x', coalition=None)
    waits('f6-unknown-coalition', w, unknown="could be run x")
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
    out = waits('f8-every-owner', w, 14)
    # Each owner on its own (Main 1876 E): X's attempt and Y's are each charged R once, unseen, and neither history
    # adds a charge (S 8 + 3 + 3 = 14). A total of 14 from any other split fails here.
    control('x:launched:3221225472:unseen' in out['line'] and 'y:launched:3221225472:unseen' in out['line']
            and 'counted_runs=[x:0,y:0]' in out['line'], 'each owner charged R once', out)
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
    waits('i4-possible-descendant', w, unknown="could be run x")


def item5_reads():
    w = orphan_world('i5-short'); w.processes[42].update(coalition=9, confirm='short')
    waits('i5-short-confirm', w, unknown="could be run x")
    w = orphan_world('i5-generation'); w.processes[42].update(coalition=9, confirm='other')
    waits('i5-coalition-generation', w, unknown="could be run x")
    waits('i5-malformed-field', World('i5-malformed').run('x').proved('x').record('x', 'x', root='garbage'), unknown='attempt-x.json')


def item6_run_status():
    w = World('i6', available=13).run('y', step=('review', 'running', None)).proved('y').record('x', 'gone-run')
    w.sql("INSERT INTO runs (id, status, repo_id, created_at) VALUES ('gone-run', 'completed', 'repo', ?)", (NOW - 500,))
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
    # Main 2422 (R12-2): a counted run's passive attempts are charged once, as the active run, never each alone: seen at
    # 3 GiB with two passive attempts of 0.4 GiB each, it is charged max(3, 0.8, A) = 3, plus 8: 11 against 8.5 + 3
    # admits; each attempt alone would be 1 + 1 + 2.2 + 8 = 12.2 and wait. Control: the same attempts of an uncounted
    # run are each charged alone (A each, beside the run's other 2.2 GiB): 12.2.
    def world(name, counted):
        w = World(name, available=8.5).run('x', step=('review', 'running', None), counted=counted).proved('x')
        w.process(10, parent=200, start=100100000).process(11, parent=200, start=100100000)
        w.record('a', 'x', reserves=False, step='review').record('b', 'x', reserves=False, step='review', root=[11, 100100000])
        w.rss['x'], w.own[10], w.own[11] = 3, 0.4, 0.4
        return w
    w = world('m1759-passive', True)
    out = settle(w)
    w.close()
    harm('m1759-two-passive', out['admit'] and abs(out['projected'] - 11) < 1e-6, 'passive attempts charged alone', out)
    w = world('m1759-passive-uncounted', False)
    out = settle(w)
    w.close()
    control(out['projected'] is not None and abs(out['projected'] - 12.2) < 1e-6, 'an uncounted run\'s attempts are each charged', out)


def m1759_fallback_counts_attempts():
    w = World('m1759-fb').run('x').proved('x').record('a', 'x').record('b', 'x', root=[11, 100100000])
    waits('m1759-fallback-two-attempts', w.process(10, parent=200, start=100100000).process(11, parent=200, start=100100000), self_run='x',
          cores=6, fallback=True)
    admits(World('m1759-fb-control').run('x').proved('x').record('a', 'x').process(10, start=100100000), self_run='x', cores=6,
           fallback=True)


def m1759_uncounted_self():
    waits('m1759-uncounted-self', World('m1759-uncounted').run('x', counted=False).row('x', None), 11, self_run='x')
    waits('m1759-uncounted-self-fallback', World('m1759-uncounted-fb').run('x', counted=False).row('x', None), self_run='x',
          cores=3, fallback=True)


def m1759_partial_bulk():
    w = quiet_world('m1759-partial')  # X's root's record is the read's truncated tail: the read is not whole
    w.tail = kinfo(10, 1, 100100000)[:16]
    waits('m1759-partial-bulk', w, unknown='process table unreadable')


def m1759_short_coalition():
    w = orphan_world('m1759-coalition'); w.record('x', 'x', coalition=263); w.processes[42].update(coalition=263, coalition_len=1)
    waits('m1759-short-coalition', w, unknown="could be run x")
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
    waits('m1656-escape-fact', orphan_world('m1656-escape'), unknown="could be run x")
    admits(quiet_world('m1656-escape-control'), 8)


def m1683_copied_identity():
    # X's orphan (pid 42) carries Y's attempt identity in its environment (FM_LAUNCH_ATTEMPT=y, as the kernel reports
    # it); Y's own attempt has ended. The identity never moves the orphan to Y: X holds (11 against 8.5).
    w = orphan_world('m1683-copied').run('y').proved('y').row('y', 'key-y').record('y', 'y', root=[11, 100100000], ended_us=1)
    w.processes[42]['marker'] = 'y'
    control(b'FM_LAUNCH_ATTEMPT=y' in w.sysctl(proc.CTL_KERN, proc.KERN_PROCARGS2, 42), 'the copied identity is on the orphan')
    waits('m1683-copied-identity-fact', w, unknown="could be run x")


def m1683_foreign_in_coalition():
    # Y's orphan (pid 43) inside the launch coalition outlives X and Y: both held, 3 + 3 + 8 = 14 against 12.
    w = World('m1683-foreign-in', available=12).run('x').run('y').proved('x').proved('y').row('x', 'key-x').row('y', 'key-y')
    w.record('x', 'x').record('y', 'y', t0_us=100500000, root=[11, 100600000]).process(43, start=101000000)
    out = waits('m1683-foreign-in-fact', w, unknown="could be run x")
    # Each owner on its own (Main 1876 E): the orphan is a possible process of X's attempt and of Y's, each named.
    control("could be run x's attempt" in out['line'] and "could be run y's attempt" in out['line'], 'each owner holds', out)


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
    waits('m1683-p1f-own-live-fact', orphan_world('m1683-p1f'), unknown="could be run x")
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
            got = engine.claim_pending(str(w.pool), args)
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


# Main 1876 (outside review of 899dee770): each a red at 899dee770 and green at the head, with its control.

def failing_writes(match):
    """update_attempt failing (None) for the changes MATCH picks, as a failed write of the record does."""
    real = engine.update_attempt

    def update(path, change):
        probe = {'members': [], 'ended_us': None}
        change(probe)
        if match(probe):
            return None
        return real(path, change)
    return real, update


def m1876_membership_write():
    # Finding 1: X's live root (pid 10) has a child (pid 50) the census proves X's; writing it into X's record fails.
    # A descendant seen and not recorded could be forgotten once its lineage is lost: the decision waits, naming the
    # record. An engine ignoring the failed write admits at 11 against 12. Control: the write succeeds, 11 admits.
    for label, fail in (('fails', True), ('written', False)):
        w = quiet_world('m1876-members-' + label, available=12).process(10, start=100100000).process(50, parent=10, start=100200000, coalition=9)
        real, update = failing_writes(lambda probe: bool(probe['members']))
        if fail:
            engine.update_attempt = update
        try:
            out = w.decide()
        finally:
            engine.update_attempt = real
            w.close()
        if fail:
            harm('m1876-membership-write-ignored', not out['admit'], out)
            control(out['line'].startswith('unknown:') and 'members could not be written' in out['line'], out)
        else:
            control(out['admit'] and out['projected'] == 11, out)


def m1876_end_write():
    # Finding 1: X is quiet at both censuses and writing its end fails: a host-wide unknown (Main 1819), the decision
    # waits naming the record. An engine that only keeps X held (and charges it) admits at 11 against 12. Control:
    # the end is written, X ends, 8 admits.
    for label, fail in (('fails', True), ('written', False)):
        w = quiet_world('m1876-end-' + label, available=12)
        real, update = failing_writes(lambda probe: probe['ended_us'] is not None)
        if fail:
            engine.update_attempt = update
        try:
            out = w.decide()
        finally:
            engine.update_attempt = real
            w.close()
        if fail:
            harm('m1876-end-write-unnoted', not out['admit'], out)
            control(out['line'].startswith('unknown:') and 'end could not be written' in out['line'], out)
        else:
            control(out['admit'] and out['projected'] == 8, out)


def m1876_stopped_history():
    # Finding 2: stopped X keeps a live held attempt (root 10) and an earlier keyless row; Y is a healthy counted run.
    # X's history is built though X stopped: X's attempt R and its incomplete history R: 3 + 3 + 8 = 14 against 13
    # waits (fit), and 3 starts against the limit 3 (fallback, 9 cores). Omitting X's history admits at 11 / 2 starts.
    # Control: the same, X's history complete (its row bound to its own ended record), 11 admits.
    for label, fallback in (('fit', False), ('fallback', True)):
        w = World('m1876-stopped-' + label, available=13).run('y').proved('y')  # y waits on CI, shown ended: 0
        w.sql("INSERT INTO runs (id, status, repo_id, created_at) VALUES ('x', 'completed', 'repo', ?)", (NOW - 500,))
        w.row('x', None).record('x', 'x').process(10, parent=200, start=100100000)
        waits('m1876-stopped-history-' + label, w, None if fallback else 14, cores=9, fallback=fallback)
    w = World('m1876-stopped-control', available=13).run('y').proved('y')
    w.sql("INSERT INTO runs (id, status, repo_id, created_at) VALUES ('x', 'completed', 'repo', ?)", (NOW - 500,))
    w.proved('x').record('x', 'x').process(10, parent=200, start=100100000)
    admits(w, 11)


def m1908_stopped_run_without_attempt():
    # Main 1908, the recorded narrowing of Main 1876 H: a stopped run is charged its history only while it holds a live
    # attempt record (every gated launch writes its record before its agent runs, held until two censuses prove it
    # ended). Stopped X with an incomplete (keyless) row and no attempt record holds nothing: 8 against 10 admits
    # (the review's H-1 world). The same X holding a live attempt waits: its attempt R and its history R, 3 + 3 + 8 =
    # 14 against 13 (the review's 28/26 in half-GiB units).
    for label, attempt in (('no-attempt', False), ('live-attempt', True)):
        w = World('m1908-stopped-' + label, available=10 if not attempt else 13).run('y').proved('y')
        w.sql("INSERT INTO runs (id, status, repo_id, created_at) VALUES ('x', 'completed', 'repo', ?)", (NOW - 500,))
        w.row('x', None)
        if attempt:
            w.record('x', 'x').process(10, parent=200, start=100100000)
            waits('m1908-stopped-live-attempt', w, 14)
        else:
            admits(w, 8)


def m1876_unjoined_possible():
    # Finding 3: X's root (pid 10) joins at 1 GiB; a lineage-lost process in X's coalition (pid 42) that could be X's has
    # only an unstable 20 GiB figure. It is unknown memory: the decision waits. Treating the attempt as seen at 1 GiB
    # admits at 29 against 29.5. Control: pid 42's figure joins too: seen at 21 GiB, 21 + 8 = 29 admits.
    for label, joined in (('unstable', False), ('joined', True)):
        w = quiet_world('m1876-join-' + label).process(10, parent=200, start=100100000).process(42)
        w.rss['x'], w.own[10] = 21, 1
        (w.own if joined else w.unstable)[42] = 20
        if joined:
            admits(w, 29)
        else:
            waits('m1876-unjoined-possible', w, unknown='memory is not joined')


def as_client(w, pid, chain, args, **kw):
    import inspect
    real = os.getpid
    os.getpid = lambda: pid
    engine.ancestors = lambda _: list(chain)
    if 'direct' not in inspect.signature(engine.claim_round).parameters:
        kw.pop('direct', None)
    try:
        with engine.start_lock(str(w.pool)):
            found = engine.claim_round(str(w.pool), args, True, **kw)
            return found if found is not None else engine.claim_round(str(w.pool), args, False, **kw)
    finally:
        os.getpid = real


def m1876_nested_shell_subtree():
    # Finding 4: shell 202 claims for its one client; a nested shell 250 below it binds the claim; two live clients 301
    # and 303 below 250 are not that client: each is decided on its own. An engine accepting the bound client's
    # subtree gives both the holder. Control: 250 itself, through one more route, gets the holder.
    args = ['axi', 'run', '--intent', 'x']
    w = pending_world('m1876-subtree')
    w.pending(dict(holder=4242, args=args, before=[], created_ns=1, client_nonce=None))
    real = dict(ancestors=engine.ancestors, process_table=engine.process_table, process_argv=engine.process_argv)
    engine.process_table = lambda: {202: 4242, 250: 202, 301: 250, 303: 250}
    engine.process_argv = lambda pid: ['bash']
    try:
        shell = as_client(w, 202, [4242, 1], args, direct=False)
        nested = as_client(w, 250, [202, 4242, 1], args)
        again = as_client(w, 250, [250, 202, 4242, 1], args)
        first = as_client(w, 301, [250, 202, 4242, 1], args)
        second = as_client(w, 303, [250, 202, 4242, 1], args)
    finally:
        for name, value in real.items():
            setattr(engine, name, value)
        w.close()
    control(shell == 4242 and nested == 4242 and again == 4242, shell, nested, again)
    harm('m1876-subtree-shares-reservation', first is None and second is None, first, second)


def m1876_binding_nonce():
    # Finding 4: the shell's parsed command carries nonce N; its first actual client carries M and binds the claim. A
    # delayed row carrying N is not that client's: it releases nothing; the client's own M row releases it.
    args_n = ['axi', 'run', '--intent', 'x', '--launch-nonce', 'N']
    args_m = ['axi', 'run', '--intent', 'y', '--launch-nonce', 'M']
    results = {}
    for label, row_nonce in (('N row', 'N'), ('M row', 'M')):
        w = pending_world('m1876-nonce-' + label.split()[0])
        path = w.pending(dict(holder=4242, args=args_n, before=[], created_ns=1, client_nonce=None))
        real = dict(ancestors=engine.ancestors, process_table=engine.process_table, process_argv=engine.process_argv)
        engine.process_table = lambda: {202: 4242, 301: 202}
        engine.process_argv = lambda pid: ['bash']
        try:
            as_client(w, 202, [4242, 1], args_n, direct=False)
            as_client(w, 301, [202, 4242, 1], args_m)
        finally:
            for name, value in real.items():
                setattr(engine, name, value)
        w.sql("INSERT INTO runs (id, status, repo_id, created_at, launch_nonce) VALUES ('late', 'running', 'repo', ?, ?)", (NOW, row_nonce))
        results[label] = pending_released(w, {'late'})
    harm('m1876-binding-keeps-old-nonce', results['N row'] == [(False, None)], results)
    control(results['M row'] == [(True, 'late')], results)


def m1876_k7_bound_client():
    # Finding 4: K7 ends a shell claim by its bound client: with the shell gone and its client alive the reservation is
    # kept; with the client gone it ends.
    out = {}
    for label, shell, client in (('shell gone', DEAD_PID, os.getpid()), ('client gone', os.getpid(), DEAD_PID)):
        w = pending_world('m1876-k7-' + label.split()[0])
        w.pending(dict(holder=4242, args=['axi', 'run'], before=[], created_ns=1, client_nonce=None),
                  claim=dict(pid=shell, nonce=None, seen=[], direct=False, client=client, provisional=False))
        out[label] = pending_released(w, set())
    harm('m1876-k7-by-shell-pid', out['shell gone'] == [(False, None)], out)
    control(out['client gone'] == [(True, None)], out)


def m1876_registration_under_lock():
    # Finding 5 (L): a start's registration release is proven and applied while it holds the start lock. Through the
    # engine's own cmd_pipeline_start, in this process, with COMMAND replaced (no process): the release's pending census
    # is read while the lock is held. Control: the start is admitted and its own row releases it.
    import argparse
    w = World('m1876-registered')
    w.observe()
    probe = {}
    real = dict(run_child=engine.run_child, pending_census=engine.pending_census, start_binding=engine.start_binding,
                with_intercept=engine.with_intercept)

    def census(directory, running):
        if probe.get('armed'):
            fd = engine.open_lock(os.path.join(directory, 'pipeline-start.lock'))
            try:
                probe['held'] = not engine.try_lock(fd)
            finally:
                os.close(fd)
        return real['pending_census'](directory, running)

    def child(command, environment, fd, on_poll=None, cancellable=False):
        w.sql("INSERT INTO runs (id, status, repo_id, created_at, launch_nonce) VALUES ('own', 'running', 'repo', ?, 'N')", (NOW,))
        probe['armed'] = True
        probe['released'] = on_poll()
        return 0
    engine.pending_census, engine.run_child = census, child
    engine.start_binding = lambda cwd, words: None
    engine.with_intercept = lambda env, priority: None
    saved = dict(os.environ)
    os.environ['FM_CPU_POOL_DIR'] = str(w.pool)
    try:
        code = engine.cmd_pipeline_start(argparse.Namespace(command=['no-mistakes', 'axi', 'run', '--intent', 'x', '--launch-nonce', 'N'],
                                                            only_fresh=False, priority='other'))
    finally:
        os.environ.clear()
        os.environ.update(saved)
        for name, value in real.items():
            setattr(engine, name, value)
        proc.sysctl, proc.libc = REAL_SYSCTL, REAL_LIBC
        w.close()
    control(code == 0 and probe.get('released') is True, 'admitted and released by its own row', code, probe)
    harm('m1876-registration-outside-lock', probe.get('held') is True, probe)


def noted_unknowns():
    # The engine's unknown collector, cleared, or None at an engine without one.
    found = getattr(engine, '_unknown', None)
    if isinstance(found, list):
        found.clear()
        return found
    return None


def m1876_claim_stat():
    # Finding 6: this start's own enclosing entry has a claim whose stat fails: unknown, never "unclaimed". Read as
    # unclaimed, the entry is skipped as this start's own (no pending start counted, so the decision fits 8 against 10:
    # the review's review_claim_stat_falsifier.py). At the census (the real kernel, so the holder is this process's
    # parent): the entry is counted and the stat failure noted; the decision then waits naming the claim. Control: the
    # claim is readable: counted, 11 against 10 waits.
    for label, denied in (('denied', True), ('readable', False)):
        real_lstat, real_lexists = os.lstat, os.path.lexists
        w = pending_world('m1876-stat-' + label)
        path = w.pending(dict(holder=os.getppid(), args=['axi', 'run'], before=[], created_ns=1, client_nonce=None),
                         claim=dict(pid=os.getpid(), nonce=None, seen=[], direct=True, client=os.getpid(), provisional=False))

        def lstat(target, *a, **k):
            if denied and str(target) == path + '.claimed':
                raise PermissionError(13, 'Permission denied', str(target))
            return real_lstat(target, *a, **k)
        os.lstat = lstat
        os.path.lexists = lambda target: (False if denied and str(target) == path + '.claimed' else real_lexists(target))
        try:
            noted = noted_unknowns()
            count = engine.counted_pending(str(w.pool), set())
            if denied:
                harm('m1876-claim-stat-unclaimed', count == 1, count)
                control(noted is not None and any('.claimed' in line for line in noted), 'the stat failure is noted', noted)
            else:
                control(count == 1, 'the readable claim is counted', count)
            w.close()
            w = World('m1876-stat-decision-' + label, available=10)
            path = w.pending(dict(holder=os.getppid(), args=['axi', 'run'], before=[], created_ns=1, client_nonce=None),
                             claim=dict(pid=os.getpid(), nonce=None, seen=[], direct=True, client=os.getpid(), provisional=False))
            if denied:
                waits('m1876-claim-stat-decision', w, unknown='.claimed')
            else:
                waits('m1876-claim-stat-control', w, 11)
        finally:
            os.lstat, os.path.lexists = real_lstat, real_lexists


def m1876_short_pending_read():
    # Finding 6: a pending entry read shorter than its file is unknown, never the prefix's entry (the review's
    # review_claim_transitions_falsifier.py: a prefix ending at valid JSON was accepted). At the census the entry is
    # unknown; the decision then waits naming it.
    entry = json.dumps(dict(holder=1, args=None, before=[], created_ns=1, client_nonce=None))
    real_pread = os.pread
    for build in (pending_world, World):
        w = build('m1876-short-read-' + build.__name__.lower())
        w.pending(raw=(entry + ' trailing').encode())
        os.pread = lambda fd, size, offset: real_pread(fd, size, offset)[:len(entry)]
        try:
            if build is pending_world:
                item = engine.pending_census(str(w.pool), set())[0]
                w.close()
                harm('m1876-short-pending-read-accepted', item['entry'] is None and not item['known'],
                     {k: item.get(k) for k in ('entry', 'known')})
            else:
                waits('m1876-short-pending-read', w, unknown='pending start')
        finally:
            os.pread = real_pread


def below_holder(holder, check):
    # Runs CHECK with this process's ancestry read as HOLDER's line, so the enclosing entry of HOLDER is this start's
    # own and reaches the own-entry skip (the admitted-client check); restored after.
    real = engine.ancestors
    engine.ancestors = lambda _: [holder, 1]
    try:
        return check()
    finally:
        engine.ancestors = real


def m1876_partial_process_table():
    # Finding 6: the process table read for the admitted-client check ends in a partial record (pid 777 below the
    # holder 4242, running the admitted client): unknown, so the enclosing entry is counted: 3 + 8 = 11 against 10
    # waits. Reading the table without that record skips the entry and admits 8 (the review's
    # review_process_read_falsifier.py). Controls: the record whole, the client found: 11 waits; no child: skipped, 8.
    args = ['axi', 'run', '--intent', 'x']
    for label in ('partial', 'whole', 'none'):
        w = World('m1876-table-' + label, available=10)
        w.pending(dict(holder=4242, args=args, before=[], created_ns=1, client_nonce=None))
        if label != 'none':
            w.real_argv = True
            w.argv[777] = (5, ['no-mistakes'] + args)
        if label == 'partial':
            w.tail = kinfo(777, 4242, 101000000)[:16]
            below_holder(4242, lambda: waits('m1876-partial-process-table', w, 11))
        elif label == 'whole':
            w.process(777, parent=4242, start=101000000)
            below_holder(4242, lambda: waits('m1876-partial-table-control', w, 11))
        else:
            below_holder(4242, lambda: admits(w, 8))


def m1876_short_argv():
    # Finding 6: a process below the holder 4242 whose argument record declares 5 words and carries 2 is unknown (it
    # could be the admitted client): the enclosing entry is counted, 11 against 10 waits. Read as a shorter, nonmatching
    # list, the entry is skipped and 8 admits. Controls: its whole record, not the client: skipped, 8 admits; the whole
    # record of the client: counted, 11 waits.
    args = ['axi', 'run', '--intent', 'x']
    for label, record in (('short', (5, ['no-mistakes', 'axi'])), ('other', (1, ['bash'])),
                          ('client', (5, ['no-mistakes'] + args))):
        w = World('m1876-argv-' + label, available=10).process(777, parent=4242, start=101000000)
        w.real_argv = True
        w.argv[777] = record
        w.pending(dict(holder=4242, args=args, before=[], created_ns=1, client_nonce=None))
        if label == 'short':
            below_holder(4242, lambda: waits('m1876-short-argv', w, 11))
        elif label == 'other':
            below_holder(4242, lambda: admits(w, 8))
        else:
            below_holder(4242, lambda: waits('m1876-short-argv-control', w, 11))


def m1892_atomic_record_write():
    # Main 1892: an attempt record's update that fails while its new text is made (no space) leaves the old record
    # whole: an in-place write truncates first and leaves it empty, so every later decision waits on an unreadable
    # record for good. Helper level: the engine's own update_attempt on a real pool file. Controls: the failed update
    # returns None and leaves no temporary file; a good update writes the member, the record still valid.
    import types
    w = quiet_world('m1892-atomic')
    path = w.pool / 'attempt-x.json'
    before = path.read_text()

    def dumps(*a, **k):
        raise OSError(28, 'No space left on device')
    real = engine.json
    engine.json = types.SimpleNamespace(loads=json.loads, dumps=dumps, JSONDecodeError=json.JSONDecodeError)
    try:
        got = engine.update_attempt(str(path), lambda r: r['members'].append([50, 100200000]))
    finally:
        engine.json = real
    after = path.read_text()
    leftovers = sorted(q.name for q in w.pool.iterdir() if q.name.startswith('.'))
    if after != before:
        w.close()
    harm('m1892-failed-write-empties-record', after == before, len(before), len(after))
    good = engine.update_attempt(str(path), lambda r: r['members'].append([50, 100200000]))
    final = json.loads(path.read_text())
    w.close()
    control(got is None and not leftovers, 'the failed update returns None and leaves nothing', got, leftovers)
    control(good is not None and final['members'] == [[50, 100200000]] and engine.valid_attempt(final), good, final)
    # Control: another writer (the gate's session-key relay, outside the start lock) replaces the record while this
    # update waits for its lock: this update reads the replaced record, and neither change is lost.
    w = quiet_world('m1892-concurrent')
    path = str(w.pool / 'attempt-x.json')
    real_fcntl, fired = engine.fcntl, []
    real_flock = real_fcntl.flock

    def flock(fd, operation):
        if not fired:
            fired.append(None)  # once: the other writer's own lock call goes straight through
            fired[0] = engine.update_attempt(path, lambda r: r.__setitem__('session_key', 'key-late'))
        return real_flock(fd, operation)
    engine.fcntl = types.SimpleNamespace(flock=flock, LOCK_EX=real_fcntl.LOCK_EX, LOCK_UN=real_fcntl.LOCK_UN)
    try:
        mine = engine.update_attempt(path, lambda r: r['members'].append([50, 100200000]))
    finally:
        engine.fcntl = real_fcntl
    both = json.loads(Path(path).read_text())
    w.close()
    control(fired and fired[0] is not None and mine is not None and both['session_key'] == 'key-late'
            and both['members'] == [[50, 100200000]], 'no update lost', fired, both)


def start_in_process(w, read_host_db=None, db=None):
    """cmd_pipeline_start of the engine, in this process, with COMMAND replaced (no process starts): (exit code, the
    log lines, whether COMMAND ran). READ_HOST_DB replaces the engine's run-database reader; DB the database path."""
    import argparse
    lines, ran = [], []
    real = dict(run_child=engine.run_child, start_binding=engine.start_binding, with_intercept=engine.with_intercept,
                log=engine.log, read_host_db=engine.read_host_db, FIRST_NOTICE_SECS=engine.FIRST_NOTICE_SECS,
                HOST_STATE_DB=engine.HOST_STATE_DB)

    def child(command, environment, fd, on_poll=None, cancellable=False):
        ran.append(True)
        return 0
    engine.run_child, engine.start_binding, engine.with_intercept = child, (lambda cwd, words: None), (lambda env, priority: None)
    engine.log = lambda fd, message: lines.append(message)
    engine.FIRST_NOTICE_SECS = 0.0  # the first wait is logged at once
    if read_host_db is not None:
        engine.read_host_db = read_host_db
    if db is not None:
        engine.HOST_STATE_DB = str(db)
    saved = dict(os.environ)
    os.environ['FM_CPU_POOL_DIR'] = str(w.pool)
    try:
        code = engine.cmd_pipeline_start(argparse.Namespace(command=['touch', str(w.pool / 'started')],
                                                            only_fresh=False, priority='other'))
    finally:
        os.environ.clear()
        os.environ.update(saved)
        for name, value in real.items():
            setattr(engine, name, value)
        proc.sysctl, proc.libc = REAL_SYSCTL, REAL_LIBC
    return code, lines, bool(ran)


def m1903_census_read_error():
    # Main 1903 U-1: the start's own census read of the run rows fails ('database is locked') on a database that opens:
    # unknown, so the start waits with a named reason and is admitted once the rows read; never 125. Through the
    # engine's own cmd_pipeline_start. An engine that lets the error reach the entrypoint refuses with 125.
    w = World('m1903-locked', available=40)
    real, failures = engine.read_host_db, []

    def read(sql, parameters=()):
        if "FROM runs WHERE status = 'running'" in sql and len(failures) < 3:
            failures.append(sql)
            raise sqlite3.OperationalError('database is locked')
        return real(sql, parameters)
    code, lines, ran = start_in_process(w, read_host_db=read)
    w.close()
    harm('m1903-census-read-refuses-125', code != 125, code, lines)
    control(code == 0 and ran and len(failures) == 3, 'admitted once the rows read', code, ran, failures, lines)
    control(any('waiting: unknown:' in line and 'database is locked' in line for line in lines), 'the wait names the read', lines)


def m1903_unopenable_database():
    # Main 1903: P5.errors.db stays: a run database that cannot be opened at all (missing, or not an SQLite file)
    # refuses with 125 and runs nothing, distinct from a failed read of a database that opens (m1903_census_read_error).
    for label in ('missing', 'garbage'):
        w = World('m1903-unopenable-' + label)
        bad = w.pool.parent / (label + '.sqlite')
        if label == 'garbage':
            bad.write_text('not a database')
        code, lines, ran = start_in_process(w, db=bad)
        w.close()
        control(code == 125 and not ran and any('refused' in line for line in lines), label, code, ran, lines)
        if label == 'missing':
            control(not bad.exists(), 'no database is created', bad)


def m1876_oversized_confirmation():
    # Finding 6: the confirming read of a possible orphan of X (pid 42, its coalition read as foreign) is longer than
    # one record: unknown, so its coalition is not taken as its own: X holds and the decision waits. Truncated and taken
    # as exact, the foreign coalition ends X and 8 admits. Control: an exact confirmation: X ends, 8 admits.
    for label, confirm in (('oversized', 'oversize'), ('exact', None)):
        w = orphan_world('m1876-oversize-' + label)
        w.processes[42].update(coalition=9, confirm=confirm)
        if confirm:
            waits('m1876-oversized-confirmation', w, unknown='could be run x')
        else:
            admits(w, 8)


def m1876_row_read_error():
    # Finding 6: the run-row read for pending releases fails (OperationalError): unknown, the decision waits, never an
    # escaping error (which the entrypoint turns into 125). Control: the rows read: the entry is counted, 11 against 10.
    for label, broken in (('broken', True), ('readable', False)):
        w = World('m1876-row-error-' + label, available=10).run('own', step=('review', 'running', None), nonce='N')
        w.proved('own')
        w.pending(dict(holder=1, args=None, before=[], created_ns=1, client_nonce='M'))
        real = engine.read_host_db

        def read(sql, parameters=(), real=real):
            if broken and 'launch_nonce FROM runs' in sql:
                raise sqlite3.OperationalError('database is locked')
            return real(sql, parameters)
        engine.read_host_db = read
        try:
            try:
                out = settle(w)
            except sqlite3.Error as exc:
                out = dict(admit=None, error=repr(exc))
        finally:
            engine.read_host_db = real
            w.close()
        if broken:
            harm('m1876-row-read-error-escapes', out.get('admit') is False and out.get('line', '').startswith('unknown:'), out)
        else:
            control(out['admit'] is False and out['projected'] == 14, out)


# The perturbation generator (Main 1759): less evidence never admits, and never lowers the projected demand.

BASES = {
    'held orphan': lambda: orphan_world('p-orphan'),
    'live root': lambda: quiet_world('p-root').process(10, start=100100000),
    'unproven row': lambda: World('p-row').run('x').row('x', None),
    'shared key': lambda: World('p-shared').run('x').row('x', 's').row('x', 's')
    .record('a', 'x', session_key='s', ended_us=1).record('b', 'x', session_key='s', ended_us=1),
    'no activation': lambda: World('p-noact', activated=False).run('x').proved('x'),
    'two live attempts': lambda: World('p-two', available=13).run('x').proved('x').record('a', 'x').record('b', 'x', root=[11, 100100000])
    .process(10, parent=200, start=100100000).process(11, parent=200, start=100100000),
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


def activation_before(w, created):
    """Whether the world's activation record is well formed and older than CREATED (Main 1876 E): an epoch-second
    activated_at, a 64-hex gate digest and an integer creation time after it. A missing, unreadable or malformed
    record is no proof."""
    try:
        record = json.loads((w.pool / 'gate-activation.json').read_text())
    except (OSError, ValueError):
        return False
    if not isinstance(record, dict):
        return False
    at, sha = record.get('activated_at'), record.get('gate_sha256')
    return (type(at) is int and isinstance(sha, str) and len(sha) == 64 and all(ch in '0123456789abcdef' for ch in sha)
            and type(created) is int and at < created)


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
                        created = c.execute("SELECT created_at FROM runs WHERE id = 'x'").fetchone()
                    recorded = any(json.loads(p.read_text()).get('run') == 'x' for p in w.pool.glob('attempt-*.json'))
                    ok = rows == 0 and not recorded and activation_before(w, created[0] if created else None)
                harm_id = ident.replace(':', '/')  # a harm id carries no colon
                results[ident] = 'pass' if ok else ('FAIL: HarmError: harm:%s: %r' % (harm_id, (reference['projected'], out)))[:900]
            except (Exception, BarredProcessCall) as exc:  # noqa: BLE001 - an error is reported, never counted red
                results[ident] = 'FAIL: %s: %s' % (type(exc).__name__, str(exc)[:600])
            finally:
                w.close()
                proc.sysctl, proc.libc = REAL_SYSCTL, REAL_LIBC


def activation_writer():
    """The deployment step's writer: one well-formed record, never replaced, and nothing written on a refusal."""
    gate_file = scratch / 'activation-gate.sh'
    gate_file.write_bytes(b'#!/bin/sh\nexec true\n')
    w = World('activation-write', activated=False)
    try:
        written, text = engine.write_activation(str(w.pool), str(gate_file))
        harm('activation-written', written and activation_before(w, int(time.time()) + 10), text)
        first = (w.pool / 'gate-activation.json').read_bytes()
        harm('activation-digest', json.loads(first)['gate_sha256'] == __import__('hashlib').sha256(gate_file.read_bytes()).hexdigest(), first)
        again, reason = engine.write_activation(str(w.pool), str(gate_file))
        harm('activation-never-replaced', not again and 'record exists' in reason
             and (w.pool / 'gate-activation.json').read_bytes() == first, reason)
    finally:
        w.close()
    w = World('activation-unreadable-gate', activated=False)
    written, reason = engine.write_activation(str(w.pool), str(scratch / 'no-such-gate'))
    harm('activation-unreadable-gate', not written and 'gate file unreadable' in reason
         and sorted(os.listdir(w.pool)) == [], reason)
    w = World('activation-old-waiter', activated=False)
    try:
        fd, _ = engine.publish_locked(str(w.pool), 'pipeline-waiter-', dict(priority='other', queued_ns=1))
        w.fds.append(fd)
        written, reason = engine.write_activation(str(w.pool), str(gate_file))
        harm('activation-old-waiter', not written and 'earlier engine' in reason
             and not (w.pool / 'gate-activation.json').exists(), reason)
    finally:
        w.close()
    w = World('activation-new-waiter', activated=False).waiter('x', DEAD_PID)
    try:
        written, text = engine.write_activation(str(w.pool), str(gate_file))
        control(written and activation_before(w, int(time.time()) + 10), text)
    finally:
        w.close()
    # The subcommand itself, against this world's pool only: 0 and a record, then 1 with the record unchanged, and 125
    # without its gate file. Its success line goes to stdout, which carries this file's JSON result, so it is caught.
    w = World('activation-command', activated=False)
    saved = os.environ.get('FM_CPU_POOL_DIR')
    os.environ['FM_CPU_POOL_DIR'] = str(w.pool)
    try:
        with contextlib.redirect_stdout(io.StringIO()) as out:
            first_code = engine.main(['activate', '--gate', str(gate_file)])
        record = (w.pool / 'gate-activation.json').read_bytes() if first_code == 0 else b''
        harm('activation-command-writes', first_code == 0 and activation_before(w, int(time.time()) + 10)
             and record.decode() in out.getvalue(), first_code, out.getvalue())
        with contextlib.redirect_stdout(io.StringIO()):
            second_code = engine.main(['activate', '--gate', str(gate_file)])
            usage_code = engine.main(['activate'])
        harm('activation-command-refuses', second_code == 1 and (w.pool / 'gate-activation.json').read_bytes() == record
             and usage_code == 125, second_code, usage_code)
    finally:
        if saved is None:
            os.environ.pop('FM_CPU_POOL_DIR', None)
        else:
            os.environ['FM_CPU_POOL_DIR'] = saved


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
         ('Main 2422 a counted run\'s passive attempts are charged once', m1759_two_passive_attempts),
         ('Main 1759 the fallback counts attempts', m1759_fallback_counts_attempts),
         ('Main 1759 an uncounted requesting run keeps its history', m1759_uncounted_self),
         ('Main 1759 a partial bulk read holds', m1759_partial_bulk),
         ('Main 1759 a short coalition read is unknown', m1759_short_coalition),
         ('Main 1759 a missing members field holds', m1759_missing_members),
         ('Main 1759 a root that exits during the census holds', m1759_root_exits_during_census),
         ('Main 1759 two records on one shared-key row hold', m1759_shared_key_one_row),
         ('Main 1761 history completeness needs the activation record and gated agents', m1761_history_completeness),
         ('the activation record is written once, and never on a refusal', activation_writer),
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
         ('Main 1876 a failed membership write waits', m1876_membership_write),
         ('Main 1876 a failed end write waits', m1876_end_write),
         ("Main 1876 a stopped run's history is built", m1876_stopped_history),
         ('Main 1876 an unjoined possible process waits', m1876_unjoined_possible),
         ("Main 1876 a binding names one client, never its subtree", m1876_nested_shell_subtree),
         ('Main 1876 a binding takes its client nonce', m1876_binding_nonce),
         ('Main 1876 K7 ends a shell claim by its bound client', m1876_k7_bound_client),
         ('Main 1876 a registration release is proven under the lock', m1876_registration_under_lock),
         ('Main 1876 an unreadable claim stat waits', m1876_claim_stat),
         ('Main 1876 a short pending read waits', m1876_short_pending_read),
         ('Main 1876 a partial process table counts the entry', m1876_partial_process_table),
         ('Main 1876 a short argument record counts the entry', m1876_short_argv),
         ('Main 1892 a failed record write leaves the old record whole', m1892_atomic_record_write),
         ('Main 1908 a stopped run is charged only while it holds an attempt', m1908_stopped_run_without_attempt),
         ('Main 1903 a failed census read waits, never 125', m1903_census_read_error),
         ('Main 1903 an unopenable run database still refuses with 125', m1903_unopenable_database),
         ('Main 1876 an oversized confirmation is unknown', m1876_oversized_confirmation),
         ('Main 1876 a row read error waits', m1876_row_read_error),
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
