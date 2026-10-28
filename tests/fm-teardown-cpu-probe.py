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
                emit(event='boundary', **row)
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
                try:
                    acknowledgements.write(b'sampled\n')
                except BrokenPipeError:
                    emit(event='instrumentation_error', error='ack_reader_closed')
        # EOF alone does not establish target completion either.
        code = child.wait()
    ended = time.monotonic_ns()
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
