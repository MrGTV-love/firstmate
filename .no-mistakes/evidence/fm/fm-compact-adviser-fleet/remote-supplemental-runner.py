#!/usr/bin/env python3
import base64
import collections
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

from cleanup import cleanup, EVIDENCE, WORKSPACE

OWNED = WORKSPACE / '.test-phase-remote-check'
SOURCE = OWNED / 'source'
TEST = SOURCE / 'tests/fm-spawn-compact-adviser-disable-remote.test.sh'
ORIGINAL = WORKSPACE / '.test-phase-lab/source/tests/fm-spawn-compact-adviser-disable-remote.test.sh'
LOG = EVIDENCE / 'remote-supplemental-test.log'
TRANSPORT = EVIDENCE / 'remote-supplemental-transport.log'
PANES = EVIDENCE / 'remote-supplemental-pane-transcript.log'
FIXTURE_FILE = OWNED / 'fixture-path'
DEADLINE_SECONDS = 900
command = ['/bin/bash', '-x', str(TEST)]
env = dict(os.environ,
    TMPDIR=str(OWNED / 'tmp'),
    FM_REMOTE_SUBJECT_CLEANUP_SCRIPT=str(OWNED / 'cleanup.py'),
    FM_REMOTE_SUBJECT_FIXTURE_FILE=str(FIXTURE_FILE),
    FM_REMOTE_SUBJECT_TRANSPORT_LOG=str(TRANSPORT),
    FM_REMOTE_SUBJECT_PANE_LOG=str(PANES),
    PS4='+${SECONDS}s ${BASH_SOURCE}:${LINENO}: ')
metadata = {
    'classification': 'supplemental fake transport/probe test; NOT LIVE',
    'original_selector': str(ORIGINAL),
    'source_copy_selector': str(TEST),
    'command': command,
    'cwd': str(SOURCE),
    'deadline_seconds': DEADLINE_SECONDS,
    'environment_overrides': {key: env[key] for key in ['TMPDIR', 'FM_REMOTE_SUBJECT_CLEANUP_SCRIPT', 'FM_REMOTE_SUBJECT_FIXTURE_FILE', 'FM_REMOTE_SUBJECT_TRANSPORT_LOG', 'FM_REMOTE_SUBJECT_PANE_LOG', 'PS4']},
    'fixture_changes_only': [
        'Record fixture path and override signal traps to run complete EXIT cleanup before removing fixtures.',
        'Replace lone serving-child kill with path/start/argv-validated worker-group shutdown and exact-home process-event sweep.',
        'Collect launch-phase and fake-SSH entrypoint timestamps plus pane payload logs; assertions and production executables unchanged.',
        'Git-init independent TMPDIR ancestor for synthetic remote cwd; no remote gate bypass propagated.'
    ],
    'original_test_sha256': hashlib.sha256(ORIGINAL.read_bytes()).hexdigest(),
    'disposable_test_sha256': hashlib.sha256(TEST.read_bytes()).hexdigest(),
}
# Reproduction evidence retains only the disposable fixture seams, not a source staging tree.
shutil.copyfile(TEST, EVIDENCE / 'remote-supplemental-disposable-test.sh')
shutil.copyfile(OWNED / 'cleanup.py', EVIDENCE / 'remote-supplemental-cleanup.py')
shutil.copyfile(OWNED / 'run.py', EVIDENCE / 'remote-supplemental-runner.py')
started = time.monotonic()
metadata['start_unix'] = time.time()
process = None
cleanup_errors = []
try:
    with LOG.open('wb') as log:
        process = subprocess.Popen(command, cwd=SOURCE, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        metadata['test_pid_and_group'] = process.pid
        try:
            metadata['test_exit'] = process.wait(timeout=DEADLINE_SECONDS)
            metadata['timed_out'] = False
        except subprocess.TimeoutExpired:
            metadata['timed_out'] = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                metadata['test_exit'] = process.wait(timeout=35)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                metadata['test_exit'] = process.wait(timeout=10)
finally:
    metadata['elapsed_seconds'] = round(time.monotonic() - started, 3)
    if process is not None:
        # This is only the exact session created above, never a process-name/account-wide reap.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if FIXTURE_FILE.is_file():
        fixture = Path(FIXTURE_FILE.read_text().strip())
        if fixture.exists():
            try:
                metadata['fallback_cleanup_records'] = cleanup(fixture, SOURCE, 'fallback')
            except Exception as exc:
                cleanup_errors.append(str(exc))
    if process is not None:
        stop_limit = time.monotonic() + 5
        while time.monotonic() < stop_limit:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    metadata['cleanup_errors'] = cleanup_errors
    transport_summary = []
    calls = {}
    if TRANSPORT.is_file():
        for line in TRANSPORT.read_text().splitlines():
            parts = line.split()
            if len(parts) >= 7 and parts[2] == 'BEGIN':
                argv = base64.b64decode(parts[6]).decode('utf-8', 'backslashreplace').split('\x00')
                calls[parts[1]] = (int(parts[0]), argv)
            elif len(parts) >= 4 and parts[2] == 'END' and parts[1] in calls:
                start, argv = calls.pop(parts[1])
                transport_summary.append({'argv': argv, 'seconds': int(parts[0]) - start, 'exit': int(parts[3])})
        metadata['transport_incomplete_calls'] = [{'pid': pid, 'start': start, 'argv': argv} for pid, (start, argv) in calls.items()]
    metadata['transport_call_count'] = len(transport_summary)
    metadata['transport_calls'] = transport_summary
    phases = []
    phase_starts = {}
    if LOG.is_file():
        for line in LOG.read_text(errors='replace').splitlines():
            if line.startswith('phase begin '):
                stamp, label = line.removeprefix('phase begin ').split(': ', 1)
                phase_starts[label] = int(stamp)
            elif line.startswith('phase end '):
                stamp, label = line.removeprefix('phase end ').split(': ', 1)
                phases.append({'label': label, 'seconds': int(stamp) - phase_starts[label]})
        metadata['phase_durations'] = phases
        metadata['assertion_results'] = [line for line in LOG.read_text(errors='replace').splitlines() if line.startswith(('ok - ', 'not ok - ', 'ALL TESTS PASSED'))]
    if not cleanup_errors:
        shutil.rmtree(OWNED)
        metadata['owned_fixture_directory_removed'] = True
    else:
        metadata['owned_fixture_directory_removed'] = False
    (EVIDENCE / 'remote-supplemental-result.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps({key: metadata.get(key) for key in ['classification', 'test_exit', 'timed_out', 'elapsed_seconds', 'transport_call_count', 'phase_durations', 'assertion_results', 'cleanup_errors', 'owned_fixture_directory_removed']}))

sys.exit(0 if metadata.get('test_exit') == 0 and not metadata.get('timed_out') and not cleanup_errors else 1)
