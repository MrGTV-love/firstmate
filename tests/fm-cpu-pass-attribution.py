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
prints JSON; exits 1 on any failure. Starts no process and sends no signal.
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

    def row(self, run, key, agent='claude'):
        self.rows += 1
        return self.sql("INSERT INTO agent_invocations (id, run_id, step_name, purpose, started_at, completed_at, duration_ms, exit_status,"
                        " session_key, agent) VALUES (?, ?, 'ci', 'ci', 1, 2, 1, 'ok', ?, ?)", ('i%d' % self.rows, run, key, agent))

    def record(self, name, run, raw=None, drop=(), **fields):
        record = dict(id=name, run=run, repo='repo', step='ci', reserves=True, t0_us=100000000, root=[10, 100100000], gate=None,
                      watcher=None, coalition=7, session_key='key-' + name, members=[], quiet_us=None, ended_us=None)
        record.update(fields)
        for field in drop:
            record.pop(field, None)
        (self.pool / ('attempt-%s.json' % name)).write_text(raw if raw is not None else json.dumps(record))
        return self

    def proved(self, run, name=None):
        # An earlier launch of RUN shown ended: its own row and its ended record carry one key.
        name = name or 'proof-' + run
        return self.row(run, 'key-' + name).record(name, run, quiet_us=1, ended_us=1)

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
            return struct.pack('i', 1) + b'/bin/fake\0\0fake\0'
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
        engine.host_observation = lambda fresh=False: dict(reasons=[], memory=None if fallback else report)
        engine.measured_reservations = lambda report, running: (R, S, 2)
        engine.active_term = lambda report: (A, 2)
        try:
            running = engine.running_runs()
            counted = {run: repo_id for run, (repo_id, is_counted, _) in running.items() if is_counted}
            admit, line = engine.decide(running, counted, cores, 'other', directory=str(self.pool), self_run=self_run,
                                        waiting=frozenset(waiting))
        finally:
            proc.sysctl, proc.libc = REAL_SYSCTL, REAL_LIBC
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
    # Two decisions: an attempt with nothing left of it ends only at a second quiet census (Main 1759).
    world.decide(**kw)
    return world.decide(**kw)


def waits(ident, world, projected=None, **kw):
    out = settle(world, **kw)
    world.close()
    harm(ident, not out['admit'] and (projected is None or abs(out['projected'] - projected) < 1e-6), out)
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
    waits('f2-unreadable-record', World('f2').run('x').proved('x').record('live', 'x', raw='{not json'), 14)
    waits('f2-unreadable-record-parked', World('f2-parked').record('live', 'p', raw='{not json'), 11)


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
    for step in (('ci', 'running', None), ('ci', 'fixing', 4242)):
        for queued in ((), ('x',)):
            waits('i1-ci-state', World('i1').run('x', step=step).row('x', None), 11, waiting=queued)
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
    waits('i5-malformed-field', World('i5-malformed').run('x').proved('x').record('x', 'x', root='garbage'), 14)


def item6_run_status():
    w = World('i6', available=13).run('y', step=('review', 'running', None)).proved('y').record('x', 'gone-run')
    waits('i6-live-attempt-run-stopped', w.process(10, start=100100000), 14)


def item7_no_history_before_activation():
    waits('i7-no-history-before-activation', World('i7', activated=False).run('x'), 11)
    admits(World('i7-control').run('x'), 8)


def m1759_missing_step_row():
    waits('m1759-missing-step-row', World('m1759-step').run('x', step=None).row('x', None), 14, self_run='x', waiting=('x',))
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
    waits('m1759-missing-members', World('m1759-members').run('x').proved('x').record('x', 'x', drop=('members',)), 14)


def m1759_root_exits_during_census():
    w = quiet_world('m1759-race').process(10, start=100100000, confirm='gone')
    out = w.decide()
    w.close()
    harm('m1759-root-exits-during-census', not out['admit'], out)


def m1759_shared_key_one_row():
    w = World('m1759-shared').run('x').row('x', 'same')
    w.record('a', 'x', session_key='same', quiet_us=1, ended_us=1).record('b', 'x', session_key='same', quiet_us=1, ended_us=1)
    waits('m1759-shared-key-one-row', w, 17, self_run='x')  # one row and two records, none bound: three launches
    admits(World('m1759-unique').run('x').proved('x', 'a').proved('x', 'b'), 8, self_run='x')


def m1761_history_completeness():
    waits('m1761-no-activation', World('m1761-noact', activated=False).run('x').proved('x'), 11, self_run='x')
    waits('m1761-created-before-activation', World('m1761-before').run('x', created=NOW - 2000).proved('x'), 11, self_run='x')
    w = World('m1761-ungated').run('x').proved('x').row('x', 'key-o', agent='codex').record('o', 'x', quiet_us=1, ended_us=1)
    waits('m1761-ungated-agent', w, 11, self_run='x')
    admits(World('m1761-control').run('x').proved('x'), 8, self_run='x')


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
              claim=dict(pid=os.getpid(), nonce='N', seen=['run-old'], provisional=False))
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
    w.pending(raw=b'{', claim=dict(pid=os.getpid(), nonce='N', seen=[], provisional=False))
    got = pending_released(w, {'run-own'})
    harm('m1759-undecodable-released', got == [(False, None)], got)


def m1759_unknown_claimant():
    w = World('m1759-unknown-claimant').run('run-B', nonce='N')
    w.pending(dict(holder=1, args=None, before=[], created_ns=1, client_nonce=None), claim=dict(pid=os.getpid(), nonce='N', seen=[], provisional=False))
    w.pending(dict(holder=1, args=None, before=[], created_ns=2, client_nonce=None), claim='{unreadable')
    got = pending_released(w, {'run-B'})
    harm('m1759-unknown-claimant-collision', not any(released for released, _ in got), got)


def m1712_claimant_nonce():
    w = World('m1712-nonce').run('run-A', nonce='nonce-A')
    w.pending(dict(holder=1, args=['axi', 'run', '--launch-nonce', 'nonce-A'], before=[], created_ns=1, client_nonce=None),
              claim=dict(pid=os.getpid(), nonce='nonce-B', seen=[], provisional=False))
    got = pending_released(w, {'run-A'})
    harm('m1712-outer-nonce', got == [(False, None)], got)
    w = World('m1712-nonce-control').run('run-B', nonce='nonce-B')
    w.pending(dict(holder=1, args=['axi', 'run', '--launch-nonce', 'nonce-A'], before=[], created_ns=1, client_nonce=None),
              claim=dict(pid=os.getpid(), nonce='nonce-B', seen=[], provisional=False))
    got = pending_released(w, {'run-B'})
    control(got == [(True, 'run-B')], got)


def m1759_completed_first_run():
    # An admitted command's first no-nonce client created a run that has completed; an identical second client must not
    # claim the admission. Control: with no run created since the admission, the unused reservation is claimed.
    args = ['axi', 'run', '--intent', 'reg-x']
    for label, completed in (('completed', True), ('none', False)):
        w = World('m1759-completed-' + label)
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
            control(got == os.getppid() and final and final.get('provisional') is False, got, final)


# The perturbation generator (Main 1759): less evidence never admits, and never lowers the projected demand.

BASES = {
    'held orphan': lambda: orphan_world('p-orphan'),
    'live root': lambda: quiet_world('p-root').process(10, start=100100000),
    'unproven row': lambda: World('p-row').run('x').row('x', None),
    'shared key': lambda: World('p-shared').run('x').row('x', 's').row('x', 's')
    .record('a', 'x', session_key='s', quiet_us=1, ended_us=1).record('b', 'x', session_key='s', quiet_us=1, ended_us=1),
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
    + [('drop record field ' + field, drop_field(field)) for field in ('members', 'root', 't0_us', 'coalition', 'session_key', 'quiet_us', 'ended_us')]
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
                if op_name == 'drop an invocation row' and not ok:
                    # Dropping a row removes the only evidence of a launch. The world then waits (its projection may
                    # fall with the evidence), or, with no row and no record of x left and the activation record
                    # before x, x's history is complete by the Main 1761 amendment: then an admission is the rule.
                    with sqlite3.connect(w.db) as c:
                        rows = c.execute("SELECT count(*) FROM agent_invocations WHERE run_id = 'x'").fetchone()[0]
                    recorded = any(json.loads(p.read_text()).get('run') == 'x' for p in w.pool.glob('attempt-*.json'))
                    ok = (not out['admit']) or (rows == 0 and not recorded and (w.pool / 'gate-activation.json').exists())
                results[ident] = 'pass' if ok else ('FAIL: HarmError: harm:%s: %r' % (ident, (reference['projected'], out)))[:900]
            except Exception as exc:  # noqa: BLE001 - an error is reported, never counted red
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
         ('Main 1759 a row inside the claim window withdraws the claim', m1759_row_between_census_and_claim))
for name, body in CASES:
    case(name, body)
case('perturbation group', perturbation_group)
print(json.dumps(results, indent=1))
sys.exit(0 if all(value == 'pass' for value in results.values()) else 1)
