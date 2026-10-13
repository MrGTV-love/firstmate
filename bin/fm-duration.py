#!/usr/bin/env python3
"""Host-local command timing and timeout ownership.

Usage: fm-duration.py record KEY MILLISECONDS EXIT [--sample-id ID] [--uncalibrated]
       fm-duration.py limit KEY [--percentile 95|99] [--margin N] [--fallback SECONDS]
       fm-duration.py run KEY -- COMMAND [ARGS...]
       fm-duration.py import-nm DATABASE RUN_ID
       fm-duration.py timeout KEY MILLISECONDS [--event-id ID]
       fm-duration.py check-literals [--base REF] [--report]

The append-only, flock-serialized JSONL table is FM_DURATION_FILE, otherwise
FM_DATA_OVERRIDE/command-durations.jsonl, otherwise FM_HOME/data/command-durations.jsonl.
With no home supplied the code root is the home. Recording and process-group
execution require POSIX Python; pure literal lint works on native Windows Python,
while limit explicitly preserves the existing fallback when POSIX locks are absent.
FM_DURATION_FILE=off disables
recording (fixture copies should use off or their own isolated file).
Rows carry host, command key, wall milliseconds, exit, timestamp, load and CPU
count; optional sample ids deduplicate imported no-mistakes steps. Only successful
completed calibration-eligible samples enter nearest-rank percentiles. Cache hits,
partial lint selections and memory-fallback successes remain recorded with
calibration=false and cannot shrink a cold-analysis deadline. --uncalibrated
records other successful work that is not evidence for that command's ceiling.
Timeout rows are censored
lower bounds, not completed latency. A limit uses max(idle percentile, loaded
percentile) times the stated margin, rounded up to whole seconds; idle means
load <= CPU count, loaded means load > CPU count. Until BOTH regimes exist,
limits explicitly report missing calibration and preserve a caller's existing
fallback, or return zero (no destructive deadline while gathering calibration).
The default margin is 3; run uses p99 x 3 for its outer ceiling. Polling cadence
is observation, not a failure deadline. Output growth and cumulative process-tree
CPU time report progress; neither an idle sample nor an elapsed read wait kills
work. Completion, signal, or the measured outer ceiling ends the run.
run exports FM_DURATION_MANAGED_KEY so a self-instrumented command with the same
key leaves its one complete wall-time sample to the outer runner.
It also exports a task-local FM_DURATION_CALIBRATION_FILE: self-instrumented
commands write 0 there to exclude a warm/partial run, or 1 for eligible work.
The runner propagates the classification to its own sample and removes the file.

The second timeout for a host/key files a deterministic ship item through
fm-tasks-axi.sh with the observed lower bounds; subsequent events update the
ledger without duplicating the item. Filing failure remains retryable and is
reported, never silently marked filed. Manual-backlog homes use compatible
tasks-axi for this automated addition as well (no separate markdown writer).

check-literals compares bin/ against the merge-base with origin/main (main if
no remote ref exists). Existing literals are grandfathered by path and exact
statement, not line number. Added/changed bounds need an adjacent measured:
note with value, ISO date, host and margin. --report lists all current literals
without enforcing or changing them; --report --base REF inventories that revision. It recognizes shell bound calls, timeout
flags, timeout/deadline/budget assignments and Python/JS timeout keyword values.
"""
import argparse
import collections
import contextlib
import datetime
try:
    import fcntl
except ImportError:
    fcntl = None  # Native Windows Python cannot use the POSIX timing runner.
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import shlex
import selectors
import sqlite3
import subprocess
import sys
import time
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
HOST = platform.node()


def scalar(key, value, stream=sys.stdout):
    print(f'{key}: {json.dumps(value, ensure_ascii=False)}', file=stream)


def ledger_path():
    value = os.environ.get('FM_DURATION_FILE')
    if value == 'off':
        return None
    if value:
        return Path(value)
    home = Path(os.environ.get('FM_HOME', ROOT))
    return Path(os.environ.get('FM_DATA_OVERRIDE', home / 'data')) / 'command-durations.jsonl'


@contextlib.contextmanager
def ledger(read_rows=True):
    path = ledger_path()
    if path is None:
        yield None, []
        return
    if fcntl is None:
        raise RuntimeError('duration recording requires POSIX Python file locks; use Python from the Firstmate POSIX shell')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+', encoding='utf-8') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        rows = [json.loads(line) for line in handle if line.strip()] if read_rows else []
        yield handle, rows


def append(handle, row):
    if handle is not None:
        handle.write(json.dumps(row, separators=(',', ':')) + '\n')
        handle.flush()
        os.fsync(handle.fileno())


def observation(key, milliseconds, code, sample_id=None, calibration=True):
    cpus = os.cpu_count() or 1
    load = os.getloadavg()[0]
    return dict(host=HOST, key=key, duration_ms=milliseconds, exit=code,
                recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                load=load, cpus=cpus, regime='loaded' if load > cpus else 'idle',
                sample_id=sample_id, calibration=calibration)


def record(key, milliseconds, code, sample_id=None, calibration=True):
    if os.environ.get('FM_DURATION_MANAGED_KEY') == key:
        return  # The outer run owns this command's complete wall time.
    with ledger(read_rows=bool(sample_id)) as (handle, rows):
        if not sample_id or not any(r.get('host') == HOST and r.get('sample_id') == sample_id for r in rows):
            append(handle, observation(key, milliseconds, code, sample_id, calibration))
    if code in (124, 137):
        own_timeout(key, milliseconds, sample_id)


def limit(key, percentile, margin, fallback, verbose=True):
    if fcntl is None:
        scalar('calibration', 'POSIX Python file locks unavailable', sys.stderr)
        scalar('fallback', f'{fallback}s existing caller limit' if fallback else 'no destructive deadline; use the Firstmate POSIX shell to collect samples', sys.stderr)
        return fallback
    with ledger() as (_, rows):
        samples = [r for r in rows if r.get('host') == HOST and r.get('key') == key
                   and r.get('exit') == 0 and r.get('calibration', True)]
    groups = [[r['duration_ms'] for r in samples if r.get('regime') == regime]
              for regime in ('idle', 'loaded')]
    if not all(groups):
        seconds = fallback
        reason = 'missing ' + ', '.join(regime for regime, values in zip(('idle', 'loaded'), groups) if not values)
        if verbose:
            scalar('calibration', reason, sys.stderr)
            scalar('fallback', f'{seconds}s existing caller limit' if seconds else 'no destructive deadline; collect idle and loaded samples', sys.stderr)
    else:
        ranks = [sorted(g)[math.ceil(len(g) * percentile / 100) - 1] for g in groups]
        seconds = max(1, math.ceil(max(ranks) * margin / 1000))
        if verbose:
            scalar('measured', f'{key} host={HOST} p{percentile}={max(ranks)}ms margin={margin} samples={len(samples)}', sys.stderr)
    return seconds


def own_timeout(key, milliseconds, event_id=None):
    with ledger() as (handle, rows):
        if handle is None:
            return
        matching = [r for r in rows if r.get('host') == HOST and r.get('key') == key and r.get('event') == 'timeout']
        if not event_id or not any(r.get('event_id') == event_id for r in matching):
            event = dict(host=HOST, key=key, event='timeout', duration_ms=milliseconds, event_id=event_id)
            append(handle, event)
            matching.append(event)
        filed = any(r.get('host') == HOST and r.get('key') == key and r.get('event') == 'filed' for r in rows)
        if len(matching) < 2 or filed:
            return
        task = 'fm-timeout-' + hashlib.sha256((HOST + '\0' + key).encode()).hexdigest()[:16]
        body = f'Repeated timeout for command key {key} on host {HOST}. Observed lower bounds (ms): ' + ', '.join(str(r['duration_ms']) for r in matching)
        body += '. Measure idle and heavy-load completion latency, then repair the limit with an explicit margin. A read wait ending is not command failure.'
        cmd = [str(ROOT / 'bin/fm-tasks-axi.sh')]
        # Inspect before retrying an interrupted publication, using the deterministic id.
        shown = subprocess.run(cmd + ['show', task], capture_output=True, text=True)
        if shown.returncode:
            result = subprocess.run(cmd + ['add', task, f'Measure and repair repeated timeout: {key}', '--kind', 'ship', '--repo', 'firstmate', '--body', body], capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError('timeout work could not be filed: ' + result.stderr.strip() + result.stdout.strip())
        append(handle, dict(host=HOST, key=key, event='filed', task=task))
        scalar('timeout_work', task, sys.stderr)


def import_nm(database, run_id):
    with contextlib.closing(sqlite3.connect(Path(database).absolute().as_uri() + '?mode=ro', uri=True)) as db:
        rows = db.execute('SELECT id, step_name, duration_ms, exit_code FROM step_results WHERE run_id = ? AND completed_at IS NOT NULL AND duration_ms > 0 AND exit_code IS NOT NULL', (run_id,)).fetchall()
    for identity, name, duration, code in rows:
        # Imported timings have no historical load evidence. Do not mislabel them
        # with the current host load, or use them for a calibrated ceiling.
        with ledger() as (handle, existing):
            sample_id = 'nm:' + str(Path(database).absolute()) + ':' + str(identity)
            if not any(r.get('sample_id') == sample_id for r in existing):
                append(handle, dict(host=HOST, key='no-mistakes.' + name, duration_ms=duration,
                                    exit=code, sample_id=sample_id, regime='unknown', load=None,
                                    cpus=None, recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat()))
        if code in (124, 137):
            own_timeout('no-mistakes.' + name, duration, sample_id)


def tree_cpu(pid, observed):
    result = subprocess.run(['ps', '-axo', 'pid=,ppid=,time=,lstart='], capture_output=True, text=True)
    children = collections.defaultdict(list)
    times = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        child, parent = map(int, fields[:2])
        days, separator, clock = fields[2].rpartition('-')
        seconds = float(days) * 86400 if separator else 0.0
        parts = (clock if separator else fields[2]).split(':')
        clock_seconds = 0.0
        for part in parts:
            clock_seconds = clock_seconds * 60 + float(part)
        seconds += clock_seconds
        children[parent].append(child)
        times[child] = (seconds, tuple(fields[3:]))
    todo = [pid]
    while todo:
        child = todo.pop()
        if child in times:
            seconds, identity = times[child]
            observed[(child, identity)] = max(observed.get((child, identity), 0), seconds)
        todo.extend(children[child])
    return sum(observed.values())


def signal_group(child, sig):
    child.poll()  # Reap a completed leader before signalling its remaining group.
    try:
        os.killpg(child.pid, sig)
    except ProcessLookupError:
        pass  # The owned group has already gone.
    except PermissionError:
        # A repeated cleanup signal returned EPERM after cancellation on
        # Darwin. Accept completion only after the leader is reaped AND the
        # kernel inventory proves that no live group member remains.
        if child.poll() is None:
            raise
        inventory = subprocess.run(['ps', '-axo', 'pgid=,stat='], capture_output=True, text=True)
        if inventory.returncode:
            raise
        for line in inventory.stdout.splitlines():
            fields = line.split()
            if len(fields) != 2:
                raise ValueError('cannot verify completed process group')
            if fields[0] == str(child.pid) and not fields[1].startswith(('Z', 'X')):
                raise


def run(key, command, calibration_file):
    if os.name != 'posix':
        raise RuntimeError('progress runner requires the Firstmate POSIX shell and POSIX Python process groups')
    ceiling = limit(key, 99, 3, 0)
    started = time.monotonic()
    child_env = dict(os.environ, FM_DURATION_MANAGED_KEY=key,
                     FM_DURATION_CALIBRATION_FILE=str(calibration_file))
    child = subprocess.Popen(command, env=child_env, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    streams = selectors.DefaultSelector()
    streams.register(child.stdout, selectors.EVENT_READ, sys.stdout.buffer)
    streams.register(child.stderr, selectors.EVENT_READ, sys.stderr.buffer)
    output_bytes = 0
    interrupted = []
    def forward(sig, _frame):
        interrupted.append(sig)
        signal_group(child, sig)
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, forward)
    previous_cpu, previous_bytes = -1, -1
    next_cpu_sample = started
    observed_cpu = {}
    occurrence_id = str(uuid.uuid4())
    expired = False
    try:
        while child.poll() is None or streams.get_map():
            for ready, _ in streams.select(1):
                chunk = os.read(ready.fileobj.fileno(), 65536)
                if not chunk:
                    streams.unregister(ready.fileobj)
                    ready.fileobj.close()
                else:
                    ready.data.write(chunk)
                    ready.data.flush()
                    output_bytes += len(chunk)
            elapsed = time.monotonic() - started
            cpu = max(0, previous_cpu)
            if child.poll() is None and time.monotonic() >= next_cpu_sample:
                cpu = tree_cpu(child.pid, observed_cpu)
                next_cpu_sample = time.monotonic() + 1  # observation cadence, not a deadline
            if cpu > previous_cpu or output_bytes > previous_bytes:
                scalar('progress', f'{key} elapsed={elapsed:.1f}s output_bytes={output_bytes} tree_cpu={cpu:.2f}s', sys.stderr)
                previous_cpu, previous_bytes = max(previous_cpu, cpu), output_bytes
            if interrupted or (ceiling and elapsed >= ceiling and (child.poll() is None or streams.get_map())):
                expired = not interrupted
                # The command may have exited while descendants still hold its
                # streams. The ceiling covers those owned group members too.
                # Cleanup escalation is immediate; no additional guessed grace.
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    signal_group(child, sig)
                child.wait()
                break
        code = 124 if expired else child.returncode
        if code < 0:
            code = 128 - code
        if interrupted:
            code = 128 + interrupted[-1]
        duration_ms = round((time.monotonic() - started) * 1000)
        calibration = not calibration_file.exists() or calibration_file.read_text().strip() == '1'
        try:
            record(key, duration_ms, code, occurrence_id, calibration)
        except (OSError, ValueError, RuntimeError) as error:
            scalar('recording_error', str(error), sys.stderr)
            scalar('help', f'python3 bin/fm-duration.py record {shlex.quote(key)} {duration_ms} {code} --sample-id {occurrence_id}{"" if calibration else " --uncalibrated"}; command result preserved', sys.stderr)
        return code
    finally:
        streams.close()
        child.stdout.close()
        child.stderr.close()
        if child.poll() is None:
            signal_group(child, signal.SIGKILL)
            child.wait()


BOUND = re.compile(r'''(?ix)
    (?:\bfm_(?:run|exec)_timed\s+|\bfm_nm_(?:bounded|run_bounded|run_checked|run)\s+(?:"(?!\$@)[^"]*"|'[^']*'|[^\s"']+)\s+)["']?(?P<call>\d+(?:\.\d+)?)(?:["']|\b)(?![>\d])
    |\b(?:g?timeout)\s+(?:-\w+\s+\d+\s+)?(?P<external>\d+(?:\.\d+)?)[smhd]?\b
    |--(?:[\w-]*timeout[\w-]*|max-time|connect-timeout|wait|deadline)(?:[=\s]+)(?P<flag>\d+(?:\.\d+)?)\b
    |\b[\w]*(?:TIMEOUT|DEADLINE|SECONDS|_SECS|_MS|_GRACE)[\w]*\s*=\s*["']?(?:\$\{[^}\n]*:-)?["']?(?P<assignment>\d+(?:\.\d+)?)\b
    |\b(?:timeout|deadline)["']?\s*[:=]\s*(?P<keyword>\d+(?:\.\d+)?)\b
    |\bread\s+(?:-[A-Za-z]+\s+)*-t\s+["']?(?P<read>\d+(?:\.\d+)?)\b
    |\balarm\s*\(?\s*(?P<alarm>\d+(?:\.\d+)?)\b
    |\b(?:AbortSignal\.timeout|setTimeout|setInterval)\s*\([^\n]*?\b(?P<timer>\d+(?:\.\d+)?)\s*\)
''')
NOTE = re.compile(r'measured:.*value=([^\s,]+).*date=\d{4}-\d{2}-\d{2}.*host=\S+.*margin=\S+')


def literals(text):
    lines = text.splitlines()
    consumed_through = -1
    for index, line in enumerate(lines):
        if index <= consumed_through or line.lstrip().startswith(('#', '//', '*')):
            continue
        end = index
        while line.rstrip().endswith('\\') and end + 1 < len(lines):
            end += 1
            line = line.rstrip()[:-1] + ' ' + lines[end].lstrip()
        consumed_through = end
        for match in BOUND.finditer(line):
            value = next(v for v in match.groupdict().values() if v is not None)
            if float(value) == 0:
                continue  # zero disables a deadline, not a time limit
            note = NOTE.search('\n'.join(lines[max(0, index - 1):end + 2]))
            annotated = False
            if note and note.group(1).rstrip('s') == value:
                fields = dict(re.findall(r'(date|margin)=([^\s,]+)', note.group(0)))
                try:
                    datetime.date.fromisoformat(fields['date'])
                    margin = float(fields['margin'].rstrip('x'))
                    annotated = math.isfinite(margin) and margin >= 1
                except (ValueError, KeyError):
                    pass
            yield index + 1, line.strip(), value, annotated


def git(*args):
    return subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True, check=True).stdout


def sources(base, historical=False):
    process = None
    if base:
        process = subprocess.Popen(['git', '-C', str(ROOT), 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        paths = [ROOT / name for name in git('ls-tree', '-r', '--name-only', base, '--', 'bin').splitlines()] if historical else sorted((ROOT / 'bin').rglob('*'))
        for path in paths:
            if (not historical and not path.is_file()) or path.suffix not in ('.sh', '.py', '.js', '.ts', '.pl'):
                continue
            relative = str(path.relative_to(ROOT))
            previous = ''
            if process:
                process.stdin.write((base + ':' + relative + '\n').encode())
                process.stdin.flush()
                header = process.stdout.readline().decode().split()
                if len(header) == 3 and header[1] == 'blob':
                    previous = process.stdout.read(int(header[2])).decode()
                    process.stdout.read(1)  # batch frame terminator
                elif not header or header[-1] != 'missing':
                    raise ValueError('cannot read literal baseline for ' + relative)
            yield relative, previous if historical else path.read_text(), previous
    finally:
        if process:
            process.stdin.close()
            process.stdout.close()
            process.wait()


def check_literals(base, report):
    if not report:
        if not base:
            for ref in ('origin/main', 'main'):
                try:
                    base = git('merge-base', 'HEAD', ref).strip()
                    break
                except subprocess.CalledProcessError:
                    continue
        if not base:
            raise ValueError('no comparison base; pass --base REF')
    if base:
        base = git('rev-parse', '--verify', base + '^{commit}').strip()
    failures = []
    for relative, current, original in sources(base, historical=bool(report and base)):
        previous = collections.Counter((statement, value) for _, statement, value, _ in literals(original))
        for line, statement, value, annotated in literals(current):
            identity = statement, value
            if report:
                print(f'{relative}:{line}\t{value}\t{statement}')
            elif previous[identity]:
                previous[identity] -= 1
            elif not annotated:
                failures.append(f'{relative}:{line}: new time limit {value}; add adjacent measured: value={value} date=YYYY-MM-DD host=<host> margin=<factor> with empirical evidence, or use fm-duration.py limit')
    for failure in failures:
        scalar('error', failure)
    return int(bool(failures))


def nonnegative(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError('must be nonnegative')
    return number


class Parser(argparse.ArgumentParser):
    def error(self, message):
        scalar('error', message)
        scalar('help', 'python3 bin/fm-duration.py --help')
        self.exit(2)


def main():
    if len(sys.argv) == 2 and sys.argv[1] in ('-v', '-V', '--version'):
        print('1.0.0')
        return 0
    if len(sys.argv) == 1:
        scalar('bin', str(Path(__file__).resolve()))
        scalar('description', 'Measure host command latency and own repeated timeouts')
        with ledger() as (_, rows):
            counts = collections.Counter(r['key'] for r in rows if r.get('host') == HOST and 'exit' in r)
        print(f'durations[{len(counts)}]{{key,samples}}:')
        for key, count in sorted(counts.items()):
            print(f'  {json.dumps(key)},{count}')
        if not counts:
            scalar('durations', '0 recorded command samples on this host')
        scalar('help', 'python3 bin/fm-duration.py run <key> -- <command>; python3 bin/fm-duration.py limit <key>')
        return 0
    parser = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='action', required=True)
    rec = commands.add_parser('record')
    rec.add_argument('key'); rec.add_argument('milliseconds', type=nonnegative); rec.add_argument('exit', type=nonnegative)
    rec.add_argument('--sample-id')
    rec.add_argument('--uncalibrated', action='store_true')
    lim = commands.add_parser('limit')
    lim.add_argument('key'); lim.add_argument('--percentile', type=int, choices=(95, 99), default=95)
    lim.add_argument('--margin', type=float, default=3); lim.add_argument('--fallback', type=nonnegative, default=0)
    runner = commands.add_parser('run')
    runner.add_argument('key'); runner.add_argument('command', nargs=argparse.REMAINDER)
    nm = commands.add_parser('import-nm')
    nm.add_argument('database'); nm.add_argument('run_id')
    timeout = commands.add_parser('timeout')
    timeout.add_argument('key'); timeout.add_argument('milliseconds', type=nonnegative); timeout.add_argument('--event-id')
    check = commands.add_parser('check-literals')
    check.add_argument('--base'); check.add_argument('--report', action='store_true')
    args = parser.parse_args()
    if args.action == 'record':
        record(args.key, args.milliseconds, args.exit, args.sample_id, not args.uncalibrated)
    elif args.action == 'limit':
        if not math.isfinite(args.margin) or args.margin < 1:
            parser.error('--margin must be finite and >= 1')
        print(limit(args.key, args.percentile, args.margin, args.fallback))
    elif args.action == 'timeout':
        own_timeout(args.key, args.milliseconds, args.event_id)
    elif args.action == 'import-nm':
        import_nm(args.database, args.run_id)
    elif args.action == 'check-literals':
        return check_literals(args.base, args.report)
    elif args.action == 'run':
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if not command:
            parser.error('run requires -- COMMAND')
        with tempfile.TemporaryDirectory(prefix='fm-duration-') as scratch:
            return run(args.key, command, Path(scratch) / 'calibration')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, sqlite3.Error, subprocess.CalledProcessError) as error:
        scalar('error', str(error))
        sys.exit(1)
