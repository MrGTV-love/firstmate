#!/usr/bin/env python3
"""Temporary cleanup-suite CI attribution, removed with the measured optimization.

Usage: python3 tests/fm-teardown-cpu-probe.py [cleanup case selectors ...]
Raw FM_TEARDOWN_CPU JSON goes to ordinary test stdout, not a new artifact.
Snapshots reuse fm-duration.tree_cpu with a fresh map and fixed suite PID.
They show CPU growth, not additive usage: visibility, reaping and reparenting
can change totals. The outer runner includes observer overhead; snapshots do
not include it. No overhead is subtracted. Startup and inter-case gaps are
unattributed; post-case tail CPU is missing because the original EXIT cleanup
is untouched and a reaped root cannot supply a final snapshot.
"""

import importlib.util
import json
import math
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time


def emit(**record):
    print('FM_TEARDOWN_CPU ' + json.dumps(record, sort_keys=True), flush=True)


def load_duration():
    path = Path(__file__).resolve().parents[1] / 'bin' / 'fm-duration.py'
    spec = importlib.util.spec_from_file_location('fm_duration', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PHASE_CASES = frozenset({
    'test_local_only_force_overrides_unpushed',
    'test_docker_all_failure_channels_retain_forced_tasks_until_retry',
})


class PhaseLedger:
    """Diagnostic root-tree intervals, never mixed into case/gap bookkeeping."""

    def __init__(self):
        self.serial = 0
        self.helpers = {}
        self.products = {}
        self.helper_product_counts = {}
        self.open = {}

    def interval(self, invocation, region, start, end, reason=None):
        cpu = None
        if reason is None:
            if start is None or end is None or start['cpu_seconds'] is None or end['cpu_seconds'] is None:
                reason = 'missing_endpoint'
            else:
                cpu = end['cpu_seconds'] - start['cpu_seconds']
                if cpu < 0:
                    cpu, reason = None, 'negative_delta'
        emit(event='phase_interval', **invocation, region=region,
             start_mark=None if start is None else start['mark'],
             end_mark=None if end is None else end['mark'],
             cpu_seconds=cpu, valid=reason is None, invalid_reason=reason,
             wall_ns=None if start is None or end is None else end['monotonic_ns'] - start['monotonic_ns'])

    def begin(self, scope, pid, ppid, case, helper=None):
        self.serial += 1
        invocation = dict(invocation_id=self.serial, scope=scope, sender_pid=pid,
                          sender_ppid=ppid, case=case,
                          helper_invocation_id=None if helper is None else helper['invocation_id'])
        emit(event='phase_invocation', **invocation,
             helper_relation=('not_applicable' if scope == 'helper' else
                              'direct_parent_matches_open_helper' if helper else
                              'unmatched_or_bypassed_helper'))
        return invocation

    def finish(self, invocation, reason):
        for key, (owner, start) in list(self.open.items()):
            if owner['invocation_id'] == invocation['invocation_id']:
                self.interval(owner, key[1], start, None, 'missing_end:' + reason)
                del self.open[key]
        emit(event='phase_invocation_closed', **invocation, closure_reason=reason,
             product_entries_observed=self.helper_product_counts.pop(invocation['invocation_id'], None),
             product_exit_observed=False)

    def finish_case(self, case, reason):
        for table in (self.helpers, self.products):
            for key, owner in list(table.items()):
                if owner['case'] == case:
                    self.finish(owner, reason)
                    del table[key]

    def finish_all(self):
        for table in (self.helpers, self.products):
            for owner in table.values():
                self.finish(owner, 'target_exit')
            table.clear()

    def handle(self, mark, row, case):
        if case not in PHASE_CASES:
            emit(event='phase_unavailable', case=case, mark=mark,
                 reason='outside_source_proven_serial_scope', cpu_seconds=None, valid=False)
            return
        parts = mark.split('|')
        if len(parts) == 6 and not parts[2]:
            emit(event='phase_unavailable', case=case, mark=mark,
                 reason='shell_sender_pid_unavailable', cpu_seconds=None, valid=False)
            return
        if (len(parts) != 6 or parts[0] != 'phase' or parts[1] not in ('helper', 'product') or
                not all(value.isascii() and value.isdecimal() and len(value) <= 20 for value in parts[2:4])):
            emit(event='instrumentation_error', error='malformed_phase_mark', mark=mark)
            return
        _, scope, pid, ppid, edge, status = parts
        pid, ppid = int(pid), int(ppid)
        allowed = {'helper': {'setup.start', 'setup.end', 'cli.start', 'cli.end'},
                   'product': {'entry', 'startup.end', 'backend.end', 'safety.start', 'safety.end',
                               'runtime.start', 'runtime.end', 'docker.start', 'docker.end'}}
        if edge not in allowed[scope] or (status and (
                scope != 'helper' or edge != 'cli.end' or not status.isascii() or
                not status.isdecimal() or len(status) > 3 or int(status) > 255)):
            emit(event='instrumentation_error', error='unknown_phase_edge_or_status', mark=mark)
            return
        if scope == 'helper':
            region, action = edge.rsplit('.', 1)
            key = (pid, region)
            if action == 'start':
                if key in self.helpers:
                    self.finish(self.helpers.pop(key), 'repeated_helper_start')
                owner = self.begin(scope, pid, ppid, case)
                self.helpers[key] = owner
                if region == 'cli':
                    self.helper_product_counts[owner['invocation_id']] = 0
                self.open[(owner['invocation_id'], region)] = (owner, row)
                return
            owner = self.helpers.get(key)
            if owner is None or owner['case'] != case:
                emit(event='instrumentation_error', error='helper_end_without_same_case_start', mark=mark)
                return
            del self.helpers[key]
            _, start = self.open.pop((owner['invocation_id'], region), (owner, None))
            self.interval(owner, region, start, row)
            if region == 'cli':
                emit(event='helper_return', **owner, returncode=int(status) if status else None,
                     product_entries_observed=self.helper_product_counts.pop(owner['invocation_id'], 0))
                for product_pid, product in list(self.products.items()):
                    if product['helper_invocation_id'] == owner['invocation_id']:
                        self.finish(product, 'helper_returned_no_product_phase_end')
                        del self.products[product_pid]
            self.finish(owner, 'helper_end')
            return
        if edge == 'entry':
            if pid in self.products:
                self.finish(self.products.pop(pid), 'repeated_entry_or_pid_reuse')
            helper = self.helpers.get((ppid, 'cli'))
            if helper is not None and helper['case'] != case:
                helper = None
            owner = self.begin(scope, pid, ppid, case, helper)
            if helper is not None:
                self.helper_product_counts[helper['invocation_id']] += 1
            self.products[pid] = owner
            self.open[(owner['invocation_id'], 'startup')] = (owner, row)
            return
        owner = self.products.get(pid)
        if owner is None:
            emit(event='instrumentation_error', error='product_phase_without_entry', mark=mark)
            return
        if owner['case'] != case:
            emit(event='instrumentation_error', error='product_crossed_case_boundary', mark=mark)
            return
        region, action = edge.rsplit('.', 1)
        key = (owner['invocation_id'], region)
        if action == 'start':
            if key in self.open:
                _, old = self.open.pop(key)
                self.interval(owner, region, old, None, 'missing_end:repeated_start')
            self.open[key] = (owner, row)
        else:
            _, start = self.open.pop(key, (owner, None))
            self.interval(owner, region, start, row)
            if region == 'startup' and start is not None:
                self.open[(owner['invocation_id'], 'backend')] = (owner, row)


def run(command):
    duration = load_duration()
    mark_read, mark_write = os.pipe()
    ack_read, ack_write = os.pipe()
    env = dict(os.environ, FM_TEARDOWN_CPU_CHILD='1',
               FM_TEARDOWN_CPU_MARK_FD=str(mark_write),
               FM_TEARDOWN_CPU_ACK_FD=str(ack_read))
    child = subprocess.Popen(command, env=env, pass_fds=(mark_write, ack_read))
    os.close(mark_write)
    os.close(ack_read)
    launched = time.monotonic_ns()
    emit(event='launch', root_pid=child.pid, platform=sys.platform,
         monotonic_ns=launched, selectors=command[2:],
         outer_cpu_includes_observer=True)
    pending = b''
    previous = None
    active = {}
    phases = PhaseLedger()
    current_case = None
    pipe_eof = False
    with os.fdopen(mark_read, 'rb', buffering=0) as marks, os.fdopen(ack_write, 'wb', buffering=0) as acknowledgements:
        # Never wait for inherited-writer EOF before observing our owned child.
        while child.poll() is None:
            if not select.select([marks], [], [], 0.25)[0]:
                continue
            chunk = os.read(marks.fileno(), 4096)
            if not chunk:
                pipe_eof = True
                break
            pending += chunk
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                mark = line.decode('utf-8', errors='replace')
                observed = {}
                error = None
                try:
                    cpu, runnable = duration.tree_cpu(child.pid, observed)
                    if cpu is None:
                        error = 'cpu_telemetry_unavailable'
                    elif not any(pid == child.pid for pid, _ in observed):
                        cpu, error = None, 'root_not_observed'
                    elif not math.isfinite(cpu) or cpu < 0:
                        cpu, error = None, 'nonfinite_or_negative_cpu'
                except Exception as exc:
                    cpu, runnable, error = None, None, type(exc).__name__ + ': ' + str(exc)
                row = dict(mark=mark, root_pid=child.pid, cpu_seconds=cpu,
                           monotonic_ns=time.monotonic_ns(), runnable=runnable,
                           telemetry_error=error)
                is_phase = mark.startswith('phase|')
                emit(event='phase_boundary' if is_phase else 'boundary', **row)
                if is_phase:
                    phases.handle(mark, row, current_case)
                else:
                    if mark.endswith('.start') and mark != 'suite.start':
                        active[mark[:-6]] = row
                        start, region = previous, 'unattributed_startup' if previous and previous['mark'] == 'suite.start' else 'unattributed_gap'
                    elif mark.endswith('.end'):
                        start, region = active.pop(mark[:-4], None), mark[:-4]
                    else:
                        start, region = None, 'unattributed_launch'
                    delta = None
                    reason = 'missing_endpoint'
                    if start is not None and cpu is not None and start['cpu_seconds'] is not None:
                        delta = cpu - start['cpu_seconds']
                        reason = 'negative_delta' if delta < 0 else None
                    emit(event='interval', region=region,
                         start_mark=None if start is None else start['mark'], end_mark=mark,
                         cpu_seconds=delta, valid=reason is None, invalid_reason=reason,
                         wall_ns=None if start is None else row['monotonic_ns'] - start['monotonic_ns'])
                    previous = row
                    if mark.endswith('.start') and mark != 'suite.start':
                        current_case = mark[:-6]
                        emit(event='phase_scope', case=current_case,
                             enabled=current_case in PHASE_CASES,
                             measurement='eligible' if current_case in PHASE_CASES else 'unmeasured',
                             scope='source_proven_serial_helpers_and_direct_product_only',
                             excluded='other_cases,nested_or_unmatched_products,unsupported_sender_identity',
                             cpu_seconds=None)
                    elif mark.endswith('.end'):
                        phases.finish_case(mark[:-4], 'case_end_without_phase_end')
                        current_case = None
                try:
                    acknowledgements.write(b'sampled\n')
                except BrokenPipeError:
                    emit(event='instrumentation_error', error='ack_reader_closed')
        # EOF alone does not establish target completion either.
        code = child.wait()
    ended = time.monotonic_ns()
    phases.finish_all()
    for case, start in active.items():
        emit(event='interval', region=case, start_mark=start['mark'], end_mark=None,
             cpu_seconds=None, valid=False, invalid_reason='missing_end')
    emit(event='interval', region='unattributed_tail' if not active else 'unattributed_incomplete_case_and_tail',
         start_mark=None if previous is None else previous['mark'], end_mark='target.exit',
         cpu_seconds=None, valid=False, invalid_reason='root_reaped_no_cpu_endpoint',
         wall_ns=ended - (launched if previous is None else previous['monotonic_ns']))
    emit(event='target_exit', returncode=code, monotonic_ns=ended,
         pipe_eof_observed=pipe_eof, partial_mark_bytes=len(pending),
         boundaries_missing=previous is None)
    return code


def main():
    suite = Path(__file__).with_name('fm-teardown-cleanup.test.sh')
    code = run(['bash', str(suite), *sys.argv[1:]])
    if code < 0:
        if -code not in (signal.SIGKILL, signal.SIGSTOP):
            signal.signal(-code, signal.SIG_DFL)
        os.kill(os.getpid(), -code)
    return code


if __name__ == '__main__':
    sys.exit(main())
