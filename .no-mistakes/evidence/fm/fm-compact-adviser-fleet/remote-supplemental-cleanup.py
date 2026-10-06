#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

EVIDENCE = Path('/Users/charlesabrooker/.no-mistakes/evidence/01M490SW8TBFGK32KKDYZNRWDW')
WORKSPACE = Path('/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M490SW8TBFGK32KKDYZNRWDW')

def ps(pid, field):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', field + '='], capture_output=True, text=True, timeout=10)
    return result.stdout.strip() if result.returncode == 0 else ''

def cleanup(fixture, source, label):
    fixture = Path(fixture).resolve()
    source = Path(source).resolve()
    permitted = [WORKSPACE / '.test-phase-remote-check/tmp', WORKSPACE / '.test-phase-lab/remote-test-tmp']
    if not any(fixture.parent == parent for parent in permitted):
        raise RuntimeError('refusing unowned fixture ' + str(fixture))
    if not fixture.exists():
        return []
    records = []
    remote_root = fixture / 'remote-root'
    worker_script = str(remote_root / 'bin/fm-remote-job-worker.sh')
    state = fixture / 'remote-jobs'
    pid_file = state / 'worker.pid'
    for name, origin in [('herdr.log', fixture / 'remote-herdr.log'), ('worker.log', state / 'logs/dev.firstmate.remote-job.log')]:
        if origin.is_file():
            shutil.copyfile(origin, EVIDENCE / ('remote-supplemental-' + label + '-' + name))
    jobs = state / 'jobs'
    if jobs.is_dir():
        for job in jobs.iterdir():
            if job.is_dir() and job.name.startswith('job-'):
                snapshot = {}
                for item in ['state', 'argv', 'stdout', 'stderr', 'exit', 'home', 'deadline', 'queue_deadline']:
                    p = job / item
                    if p.is_file() and p.stat().st_size <= 1048576:
                        snapshot[item] = p.read_bytes().decode('utf-8', 'backslashreplace').replace('\x00', '\\0')
                records.append({'job': job.name, 'snapshot': snapshot})
    if pid_file.is_file():
        pid_text = pid_file.read_text().strip()
        if not pid_text.isdigit() or int(pid_text) <= 1:
            raise RuntimeError('invalid fixture worker pid')
        pid = int(pid_text)
        command = ps(pid, 'command')
        if command:
            if worker_script not in command.split():
                raise RuntimeError('PID argv does not own fixture: ' + command)
            recorded_start = state / 'worker.lock/start'
            recorded_command = state / 'worker.lock/command'
            if recorded_start.is_file() and ps(pid, 'lstart') != recorded_start.read_text().strip():
                raise RuntimeError('fixture worker PID start identity mismatch')
            if recorded_command.is_file() and command != recorded_command.read_text().strip():
                raise RuntimeError('fixture worker recorded argv mismatch')
            group_text = ps(pid, 'pgid')
            group = int(group_text)
            leader = ps(group, 'command')
            if worker_script not in leader.split() or group in (0, 1, os.getpgrp()):
                raise RuntimeError('fixture worker lacks owned isolated process group')
            records.append({'worker_pid': pid, 'worker_argv': command, 'worker_group': group, 'supervisor_argv': leader})
            command_line = ['/bin/bash', '-c', '. "$1"; fm_remote_job_stop_worker_tree "$2"', '_', str(source / 'bin/fm-remote-job-lib.sh'), str(pid)]
            result = subprocess.run(command_line, capture_output=True, text=True, timeout=25)
            records.append({'cleanup_command': command_line, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
            if result.returncode != 0 or ps(pid, 'command') or ps(group, 'command'):
                raise RuntimeError('owned fixture worker tree did not stop')
    home = fixture / 'parent'
    claims = fixture / 'claims'
    sweep = [str(source / 'bin/fm-procevent.sh'), 'sweep-home']
    env = dict(os.environ, FM_HOME=str(home), FM_PROCEVENT_CLAIM_ROOT=str(claims), FM_GATE_REFUSE_BYPASS='1')
    result = subprocess.run(sweep, env=env, capture_output=True, text=True, timeout=20)
    records.append({'cleanup_command': sweep, 'FM_HOME': str(home), 'FM_PROCEVENT_CLAIM_ROOT': str(claims), 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
    if result.returncode != 0:
        raise RuntimeError('owned fixture process-event sweep failed')
    remote_home = str(fixture / 'remote-home')
    for staging_home in [remote_home, str(remote_root)]:
        token = hashlib.sha256(staging_home.encode()).hexdigest()
        staging = Path('/tmp') / ('fm-ios+' + token)
        if staging.exists():
            if staging.is_symlink() or staging.stat().st_uid != os.getuid():
                raise RuntimeError('unsafe fixture launch staging ownership')
            for item in staging.iterdir():
                if not item.is_file() or item.is_symlink() or remote_home not in item.read_text():
                    raise RuntimeError('unproven launch staging file: ' + str(item))
            shutil.rmtree(staging)
            records.append({'removed_fixture_launch_staging': str(staging)})
    (EVIDENCE / ('remote-supplemental-' + label + '-cleanup.json')).write_text(json.dumps(records, indent=2) + '\n')
    return records

if __name__ == '__main__':
    try:
        records = cleanup(sys.argv[1], sys.argv[2], sys.argv[3])
        print(json.dumps({'cleanup': 'complete', 'records': records}))
    except Exception as exc:
        print('cleanup failure: ' + str(exc), file=sys.stderr)
        sys.exit(1)
