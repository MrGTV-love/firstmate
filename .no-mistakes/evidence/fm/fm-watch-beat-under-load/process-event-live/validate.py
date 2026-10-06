#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import traceback

repo = Path(sys.argv[1]).resolve()
fixture = Path(sys.argv[2]).resolve()
evidence = Path(sys.argv[3]).resolve()
assert fixture == repo / '.live-validation' / 'ProcessEventLive'
assert evidence == Path('/Users/charlesabrooker/.no-mistakes/evidence/01M48YDAJ274FP0KSXR35TAEYY/process-event-live')
for path in (fixture / 'tmp', fixture / 'operator-home', evidence / 'commands', evidence / 'snapshots'):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
os.umask(0o077)
base = dict(os.environ)
scrubbed = sorted(k for k in base if k.startswith('FM_') or k.startswith('TASKS_AXI_') or k in ('BASH_ENV', 'ENV', 'TMUX', 'TMUX_PANE', 'TMUX_TMPDIR'))
for key in scrubbed:
    del base[key]
base.update(HOME=str(fixture / 'operator-home'), TMPDIR=str(fixture / 'tmp'),
            PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
            FM_PROCEVENT_CLAIM_ROOT=str(fixture / 'claims'),
            TMUX_TMPDIR=str(fixture / 'tmp' / 'private-tmux-sockets'))
claim_root = fixture / 'claims'
homes = [fixture / 'home-local', fixture / 'home-foreign']
(fixture / 'tmp' / 'private-tmux-sockets').mkdir(mode=0o700)
for home in homes:
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
(evidence / 'environment.json').write_text(json.dumps({'scrubbed_variable_names': scrubbed,
    'isolated_variables': {k: base[k] for k in ('HOME', 'TMPDIR', 'PATH', 'FM_PROCEVENT_CLAIM_ROOT')},
    'live_test_seams': False}, indent=2) + '\n')
shutil.copy2(__file__, evidence / 'validate.py')
logfile = (evidence / 'run.log').open('w', buffering=1)
command_file = (evidence / 'commands.jsonl').open('w', buffering=1)
children = []
results = []
command_index = 0
known_runner_pids = set()
watcher = None
watcher_reconcile_pid = None


def emit(message):
    print(message, flush=True)
    logfile.write(message + '\n')


def record_result(name, details):
    results.append({'scenario': name, 'status': 'passed', **details})
    emit('PASS ' + name + ': ' + json.dumps(details, sort_keys=True))


def start(name, argv, home=None, extra=None, stream_to_file=False):
    global command_index
    command_index += 1
    env = dict(base)
    if home is not None:
        env['FM_HOME'] = str(home)
    if extra:
        env.update(extra)
    relevant = {k: env[k] for k in ('HOME', 'TMPDIR', 'FM_HOME', 'FM_PROCEVENT_CLAIM_ROOT',
        'FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS', 'FM_TEST_ONLY', 'FM_TEST_SKIP_ORPHAN_REAP',
        'FM_POLL', 'FM_GUARD_GRACE', 'TMUX_TMPDIR', 'PS4') if k in env}
    prefix = f'{command_index:02d}-{name}'
    emit('COMMAND ' + ' '.join(shlex.quote(k + '=' + v) for k, v in relevant.items()) + ' ' + shlex.join(argv))
    output_path = evidence / 'commands' / (prefix + '.log')
    output_handle = output_path.open('w') if stream_to_file else subprocess.PIPE
    proc = subprocess.Popen(argv, cwd=repo, env=env, stdout=output_handle, stderr=subprocess.STDOUT, text=True)
    if stream_to_file:
        output_handle.close()
    metadata = {'index': command_index, 'name': name, 'argv': argv, 'environment': relevant,
                'pid': proc.pid, 'started_monotonic': time.monotonic(), 'log': str(output_path),
                'stream_to_file': stream_to_file}
    children.append((proc, metadata))
    return proc, metadata


def finish(item, timeout=100):
    proc, metadata = item
    output, _ = proc.communicate(timeout=timeout)
    if metadata['stream_to_file']:
        output = Path(metadata['log']).read_text()
    else:
        Path(metadata['log']).write_text(output)
    metadata.update(returncode=proc.returncode, finished_monotonic=time.monotonic())
    command_file.write(json.dumps(metadata) + '\n')
    detail = output.rstrip() if len(output) < 12000 else f'{len(output)} bytes preserved in {metadata["log"]}'
    emit(f'EXIT {metadata["name"]} rc={proc.returncode}: ' + detail)
    return proc.returncode, output


def run(name, args, home=None, extra=None, timeout=100):
    return finish(start(name, ['/bin/bash', str(repo / 'bin/fm-procevent.sh'), *args], home, extra), timeout)


def pe_start(name, args, home, extra=None):
    return start(name, ['/bin/bash', str(repo / 'bin/fm-procevent.sh'), *args], home, extra)


def wait_for(predicate, description, seconds=30):
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError('Timed out waiting for ' + description)
        time.sleep(0.05)


def identity(path):
    stat = path.stat()
    return f'{stat.st_dev}:{stat.st_ino}'


def replace_fixture_bytes(path, content, expected_identity):
    # Intentional registration damage/repair is disposable test input only.
    # Truncating the existing inode preserves the product's registration identity.
    with path.open('r+b') as stream:
        stream.write(content)
        stream.truncate()
    assert identity(path) == expected_identity


def failure_keys(home):
    queue = home / 'state/.wake-queue'
    rows = queue.read_text().splitlines() if queue.exists() else []
    return [row.split('\t')[3] for row in rows if len(row.split('\t')) >= 5 and ':launch-failed:' in row.split('\t')[3]]


def snapshot(name):
    destination = evidence / 'snapshots' / name
    destination.mkdir()
    facts = {'claims': {}, 'homes': {}}
    if claim_root.exists():
        shutil.copytree(claim_root, destination / 'claims', symlinks=True)
        for claim in claim_root.glob('*.claim'):
            content = claim.read_text()
            facts['claims'][claim.name] = content
            lines = content.splitlines()
            if len(lines) >= 2 and lines[1].isdigit():
                known_runner_pids.add(int(lines[1]))
    for home in homes:
        if home.exists():
            shutil.copytree(home, destination / home.name, symlinks=True)
        source = home / 'state/procevent/process-event-live.source'
        marker = home / 'state/procevent/.process-event-live.launch-failed'
        queue = home / 'state/.wake-queue'
        facts['homes'][home.name] = {
            'source_identity': identity(source) if source.exists() else None,
            'launch_failed_marker': marker.read_text() if marker.exists() else None,
            'launch_failed_keys': failure_keys(home),
            'wake_queue': queue.read_text() if queue.exists() else None,
            'results': {str(p.relative_to(home)): p.read_text() for p in home.glob('state/procevent-inbox/*.result')},
            'launch_stamps': {p.name: p.read_text() for p in home.glob('state/procevent/*.last-launch')},
        }
    (destination / 'facts.json').write_text(json.dumps(facts, indent=2) + '\n')
    emit('STATE ' + name + ': ' + json.dumps(facts, sort_keys=True))
    return facts


def concurrent_failures(name, count, expected_wakes):
    pending = [pe_start(f'{name}-{n + 1}', ['reconcile'], homes[0],
               {'FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS': '2'}) for n in range(count)]
    outcomes = [finish(item) for item in pending]
    assert all(rc != 0 and 'failed=1' in output for rc, output in outcomes), outcomes
    keys = failure_keys(homes[0])
    assert len(keys) == expected_wakes and len(set(keys)) == expected_wakes, keys
    assert marker.exists() and marker.stat().st_size > 0
    assert identity(source) == source_identity
    return keys


status = 'failed'
failure = None
cleanup = {}
try:
    # All live inputs are now created before the selected validation starts.
    for home in homes:
        rc, _ = finish(start('mark-' + home.name, ['/bin/bash', str(repo / 'bin/fm-lab-home.sh'),
                              'create', str(home)], home))
        assert rc == 0
    rc, _ = run('register-local', ['register', 'lavish', 'process-event-live', '--',
        '/bin/bash', '-c', 'printf "real local completion\\n"'], homes[0])
    assert rc == 0
    started = fixture / 'foreign-source.started'
    released = fixture / 'foreign-source.release'
    foreign_command = 'printf "%s\\n" "$$" > "$1"; while [ ! -e "$2" ] && [ "$SECONDS" -lt 45 ]; do /bin/sleep 0.05; done; [ -e "$2" ] || exit 75; printf "real foreign-home completion\\n"'
    rc, _ = run('register-foreign', ['register', 'lavish', 'process-event-live', '--',
        '/bin/bash', '-c', foreign_command, '_', str(started), str(released)], homes[1])
    assert rc == 0
    source = homes[0] / 'state/procevent/process-event-live.source'
    marker = homes[0] / 'state/procevent/.process-event-live.launch-failed'
    source_identity = identity(source)
    good = source.read_bytes()
    damaged = good.split(b'argv:\n', 1)[0] + b'argv:\n'
    (evidence / 'local-good.source').write_bytes(good)
    (evidence / 'local-damaged.source').write_bytes(damaged)
    replace_fixture_bytes(source, damaged, source_identity)
    foreign_source = homes[1] / 'state/procevent/process-event-live.source'
    foreign_identity = identity(foreign_source)
    foreign_good = foreign_source.read_bytes()
    foreign_damaged = foreign_good.split(b'argv:\n', 1)[0] + b'argv:\n'
    replace_fixture_bytes(foreign_source, foreign_damaged, foreign_identity)

    watcher = start('watcher-slow-detached-reconcile',
        ['/bin/bash', '-x', str(repo / 'bin/fm-watch.sh')], homes[1],
        {'FM_POLL': '1', 'FM_GUARD_GRACE': '6', 'FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS': '12',
         'FM_SIGNAL_GRACE': '0', 'FM_CHECK_INTERVAL': '999999', 'FM_HEARTBEAT': '999999',
         'PS4': '+fmwatch:${BASHPID:-$$}:${LINENO}: '}, stream_to_file=True)
    lock_pid_file = homes[1] / 'state/.watch.lock/pid'
    beat = homes[1] / 'state/.last-watcher-beat'
    wait_for(lambda: lock_pid_file.exists() and beat.exists(), 'watcher real lock and beacon')
    assert int(lock_pid_file.read_text().strip()) == watcher[0].pid
    samples = []
    sample_start = time.monotonic()
    while time.monotonic() - sample_start < 8.2:
        child_inventory = subprocess.run(['/usr/bin/pgrep', '-P', str(watcher[0].pid)], env=base,
                                         capture_output=True, text=True)
        child_pids = child_inventory.stdout.split()
        ps_output = ''
        reconcile_pids = []
        if child_pids:
            ps_output = subprocess.run(['/bin/ps', '-o', 'pid=,ppid=,stat=,command=', '-p',
                                         ','.join(child_pids)], env=base,
                                        capture_output=True, text=True).stdout
            for line in ps_output.splitlines():
                fields = line.split(None, 3)
                if len(fields) == 4 and str(repo / 'bin/fm-procevent.sh') + ' reconcile' in fields[3]:
                    reconcile_pids.append(int(fields[0]))
        assert len(reconcile_pids) <= 1, ps_output
        if reconcile_pids:
            if watcher_reconcile_pid is None:
                watcher_reconcile_pid = reconcile_pids[0]
            assert reconcile_pids == [watcher_reconcile_pid], ps_output
        assert watcher[0].poll() is None, 'watcher exited during pending confirmation'
        samples.append({'elapsed_seconds': time.monotonic() - sample_start,
                        'watcher_pid': watcher[0].pid, 'reconcile_pids': reconcile_pids,
                        'beacon_mtime_ns': beat.stat().st_mtime_ns,
                        'beacon_age_seconds': time.time() - beat.stat().st_mtime,
                        'scoped_child_ps': ps_output})
        time.sleep(0.4)
    (evidence / 'watcher-pending-samples.json').write_text(json.dumps(samples, indent=2) + '\n')
    with_child = [sample for sample in samples if sample['reconcile_pids']]
    assert with_child[-1]['elapsed_seconds'] - with_child[0]['elapsed_seconds'] > 6
    assert len({sample['beacon_mtime_ns'] for sample in with_child}) >= 4
    assert all(sample['beacon_age_seconds'] < 6 for sample in with_child)
    trace_so_far = Path(watcher[1]['log']).read_text()
    main_cycle_lines = [line for line in trace_so_far.splitlines()
                        if line.startswith(f'+fmwatch:{watcher[0].pid}:') and line.endswith(': event_wait_or_sleep')]
    assert len(main_cycle_lines) >= 4, main_cycle_lines
    snapshot('00-watcher-pending-reconcile')
    rc, _ = finish(start('stop-exact-home-watcher', ['/bin/bash', str(repo / 'bin/fm-watch-arm.sh'),
                           '--stop'], homes[1]))
    assert rc == 0
    finish(watcher)
    watcher = None
    wait_for(lambda: subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(watcher_reconcile_pid)],
             env=base, capture_output=True, text=True).stdout.strip() in ('', 'Z'),
             'exact detached reconcile completion', seconds=20)
    replace_fixture_bytes(foreign_source, foreign_good, foreign_identity)
    record_result('slow real reconciliation stays detached from watcher progress',
                  {'pending_seconds_observed': with_child[-1]['elapsed_seconds'] - with_child[0]['elapsed_seconds'],
                   'watcher_pid': samples[0]['watcher_pid'], 'same_reconcile_pid': watcher_reconcile_pid,
                   'max_direct_reconcile_children': max(len(sample['reconcile_pids']) for sample in samples),
                   'beacon_versions': len({sample['beacon_mtime_ns'] for sample in with_child}),
                   'completed_main_cycle_trace_entries': len(main_cycle_lines),
                   'poll_seconds': 1, 'guard_grace_seconds': 6,
                   'confirmation_window_seconds': 12, 'trace_changes_timing': True})

    first_keys = concurrent_failures('concurrent-initial-failure', 4, 1)
    snapshot('01-concurrent-initial-failure')
    record_result('four concurrent real reconcilers announce one failure episode',
                  {'reconcilers': 4, 'failure_wakes': 1, 'keys': first_keys, 'registration_identity': source_identity})

    local = pe_start('local-confirming-foreign-recovery', ['reconcile'], homes[0],
                     {'FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS': '6'})
    time.sleep(1.25)
    assert local[0].poll() is None, 'local reconcile ended before foreign owner was launched'
    assert marker.exists()
    snapshot('02-local-pending-before-foreign')
    foreign = pe_start('foreign-attached-start', ['start', 'process-event-live'], homes[1])
    wait_for(started.exists, 'real foreign source command to execute')
    rc, output = finish(local)
    assert rc == 0 and 'started=1' in output and 'failed=0' in output, output
    assert not marker.exists()
    assert failure_keys(homes[0]) == first_keys
    owner = (claim_root / 'process-event-live.claim').read_text().splitlines()[0]
    assert owner == str(homes[1]), owner
    live_state = snapshot('03-foreign-live-clears-local-episode')
    record_result('two-home live ownership closes same-registration local episode',
                  {'reconcile_output': output.strip(), 'foreign_owner': owner,
                   'local_marker_present': False, 'local_failure_wakes': 1,
                   'registration_identity': source_identity})

    released.touch()
    rc, output = finish(foreign)
    assert rc == 0 and 'captured: process-event-live 1' in output, output
    wait_for(lambda: not (claim_root / 'process-event-live.claim').exists(), 'foreign claim release')
    foreign_results = list(homes[1].glob('state/procevent-inbox/*.result'))
    assert len(foreign_results) == 1 and foreign_results[0].read_text() == 'real foreign-home completion\n'
    snapshot('04-foreign-real-result-captured')
    record_result('foreign command completes with durable real result and check wake',
                  {'result': foreign_results[0].read_text(), 'capture_output': output.strip()})

    rc, output = run('local-attached-genuine-refusal', ['start', 'process-event-live'], homes[0])
    assert rc != 0 and 'registration argv is unreadable' in output, output
    second_keys = concurrent_failures('concurrent-failure-after-foreign-recovery', 4, 2)
    snapshot('05-new-genuine-failure-after-foreign-recovery')
    assert first_keys[0].rsplit('-', 1)[0] == second_keys[1].rsplit('-', 1)[0]
    record_result('new genuine failure after foreign recovery announces a distinct episode once',
                  {'attached_refusal': output.strip(), 'reconcilers': 4, 'failure_wakes': 2,
                   'keys': second_keys, 'registration_identity': source_identity})

    replace_fixture_bytes(source, good, source_identity)
    rc, output = run('local-fast-success', ['start', 'process-event-live'], homes[0])
    assert rc == 0 and 'captured: process-event-live 1' in output, output
    assert not marker.exists()
    assert (homes[0] / 'state/procevent-inbox/process-event-live.1.result').read_text() == 'real local completion\n'
    assert list(homes[0].glob('state/procevent/*.last-launch'))
    snapshot('06-local-fast-success-retains-stamp')
    replace_fixture_bytes(source, damaged, source_identity)
    third_keys = concurrent_failures('concurrent-new-failure-after-local-stamp', 4, 3)
    newer_marker = marker.read_text()
    rc, output = run('repeated-failure-with-historical-stamp', ['reconcile'], homes[0],
                     {'FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS': '2'})
    assert rc != 0 and 'failed=1' in output
    assert marker.read_text() == newer_marker and failure_keys(homes[0]) == third_keys
    snapshot('07-newer-episode-survives-existing-success-stamp')
    record_result('existing historical success stamp does not hide or duplicate a newer failure',
                  {'failure_wakes': 3, 'keys': third_keys, 'newer_marker_preserved': True,
                   'registration_identity': source_identity})
    for home in homes:
        rc, _ = run('list-' + home.name, ['list'], home)
        assert rc == 0

    # Only this exact existing targeted regression is permitted, never the suite.
    supplement = start('supplement-launch-episodes', ['/bin/bash', str(repo / 'tests/fm-procevent.test.sh')],
                       extra={'FM_TEST_ONLY': 'launch-episodes', 'FM_TEST_SKIP_ORPHAN_REAP': '1',
                              'FM_PROCEVENT_CLAIM_ROOT': str(fixture / 'supplement-claims')})
    rc, output = finish(supplement, timeout=240)
    assert rc == 0, output
    record_result('supplemental existing launch-episodes regression',
                  {'selector': 'FM_TEST_ONLY=launch-episodes', 'returncode': rc,
                   'output': output.strip(), 'note': 'Existing test-only timing hooks are supplemental, not live proof.'})
    status = 'passed'
except BaseException as exc:
    failure = {'type': type(exc).__name__, 'message': str(exc), 'traceback': traceback.format_exc()}
    emit('FAIL ' + failure['traceback'])
finally:
    # Preserve product state before exact-home teardown and fixture deletion.
    try:
        snapshot('99-before-teardown')
    except BaseException as exc:
        cleanup['snapshot_error'] = repr(exc)
    if watcher is not None and watcher[0].poll() is None:
        try:
            rc, output = finish(start('cleanup-stop-exact-watcher',
                ['/bin/bash', str(repo / 'bin/fm-watch-arm.sh'), '--stop'], homes[1]))
            cleanup['watcher_stop'] = {'returncode': rc, 'output': output.strip()}
            finish(watcher)
        except BaseException as exc:
            cleanup['watcher_stop'] = {'error': repr(exc)}
    for home in homes:
        try:
            rc, output = run('sweep-' + home.name, ['sweep-home'], home)
            cleanup[home.name] = {'returncode': rc, 'output': output.strip()}
        except BaseException as exc:
            cleanup[home.name] = {'error': repr(exc)}
    remaining_claims = list(claim_root.glob('*.claim')) if claim_root.exists() else []
    remaining_registrations = [str(p) for home in homes for p in home.glob('state/procevent/*.source')]
    remaining_runner_records = [str(p) for home in homes for p in home.glob('state/procevent/*.runner')]
    unfinished = []
    for proc, metadata in children:
        if proc.poll() is None:
            try:
                output, _ = proc.communicate(timeout=8)
                Path(metadata['log']).write_text(output)
            except subprocess.TimeoutExpired:
                unfinished.append({'pid': proc.pid, 'name': metadata['name']})
    cleanup.update(remaining_claims=[str(p) for p in remaining_claims],
                   remaining_registrations=remaining_registrations,
                   remaining_runner_records=remaining_runner_records,
                   unfinished_started_commands=unfinished)
    if known_runner_pids:
        inspection = subprocess.run(['/bin/ps', '-o', 'pid=,ppid=,pgid=,stat=,command=', '-p',
                                     ','.join(str(pid) for pid in sorted(known_runner_pids))],
                                    env=base, capture_output=True, text=True)
        (evidence / 'runner-pids-after-sweep.log').write_text(inspection.stdout + inspection.stderr)
        cleanup['recorded_runner_pid_inspection'] = {'pids': sorted(known_runner_pids),
            'returncode': inspection.returncode, 'output': inspection.stdout + inspection.stderr}
    clean = (not remaining_claims and not remaining_registrations and not remaining_runner_records
             and not unfinished and all(cleanup[home.name].get('returncode') == 0 for home in homes))
    cleanup['exact_home_sweeps_successful'] = clean
    if clean:
        shutil.rmtree(fixture)
        cleanup['fixture_subtree_removed'] = not fixture.exists()
    else:
        status = 'failed'
        cleanup['fixture_subtree_removed'] = False
    report = {'status': status, 'failure': failure, 'scenarios': results, 'cleanup': cleanup,
        'limitations': ['Live orchestration uses public commands and real Bash/sleep inputs without product mocks or timing seams.',
            'The live foreign-owner recovery is naturally timed and not instrumented to distinguish every internal observation instruction.',
            'Exact final-revalidation, stale replaced-registration, delayed historical-success, and failed-append rollback races are covered by the supplemental targeted regression timing hooks only.',
            'No live Lavish editor/backend, operator home, tmux default server, Herdr endpoint, credentials, full suite, CI, lint, format, or build was touched; tmux clients are isolated to an empty socket directory under the fixture.']}
    (evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    emit('FINAL ' + json.dumps({'status': status, 'cleanup': cleanup}, sort_keys=True))
    command_file.close()
    logfile.close()
sys.exit(0 if status == 'passed' else 1)
