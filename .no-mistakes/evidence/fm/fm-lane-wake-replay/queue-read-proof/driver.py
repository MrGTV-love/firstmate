#!/usr/bin/env python3
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time

ROOT = Path.cwd()
FIXTURE = ROOT / '.queue-read-proof-01M4FKBPP79Q9T9PVBFG7F1ETZ'
EVIDENCE = Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4FKBPP79Q9T9PVBFG7F1ETZ') / 'queue-read-proof'
EVIDENCE.mkdir(parents=True, exist_ok=True)
DRAIN = ROOT / 'bin/fm-wake-drain.sh'
GRANT = ROOT / 'bin/fm-wake-grant.sh'
LIB = ROOT / 'bin/fm-wake-lib.sh'
BASE = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') or k.startswith('PI_') or k in ('STATE', 'CONFIG', 'BASH_ENV', 'ENV', 'HERDR_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'TMPDIR'))}
BASE['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
BASE['LC_ALL'] = 'en_US.UTF-8'
BASE['TMPDIR'] = str(FIXTURE / 'tmp')
(FIXTURE / 'tmp').mkdir()
LOG = (EVIDENCE / 'transcript.log').open('w', encoding='utf-8')
commands = []
results = []
sequence = 0
owners = []


def emit(text):
    LOG.write(text + '\n')
    LOG.flush()


def home(name):
    path = FIXTURE / name
    for child in ('user-home', 'config', 'data'):
        (path / child).mkdir(parents=True)
    return path


def env_for(path, state=None, actor='main'):
    return {'HOME': str(path / 'user-home'), 'FM_HOME': str(path), 'FM_ROOT_OVERRIDE': str(path), 'FM_STATE_OVERRIDE': str(state or path / 'state'), 'FM_CONFIG_OVERRIDE': str(path / 'config'), 'FM_SUPERVISION_ACTOR': actor, 'XDG_CONFIG_HOME': str(path / 'user-home/.config'), 'XDG_DATA_HOME': str(path / 'user-home/.local/share'), 'XDG_STATE_HOME': str(path / 'user-home/.local/state'), 'XDG_CACHE_HOME': str(path / 'user-home/.cache')}


def run(label, args, env, timeout=10):
    global sequence
    sequence += 1
    stem = f'{sequence:03d}-{label}'
    command = 'env ' + ' '.join(shlex.quote(k + '=' + v) for k, v in {'PATH': BASE['PATH'], 'LC_ALL': BASE['LC_ALL'], 'TMPDIR': BASE['TMPDIR'], **env}.items()) + ' ' + shlex.join([str(a) for a in args])
    emit(f'\n### {label}\n$ {command}')
    start = time.monotonic()
    process = subprocess.run([str(a) for a in args], env={**BASE, **env}, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    elapsed = time.monotonic() - start
    (EVIDENCE / (stem + '.stdout')).write_bytes(process.stdout)
    (EVIDENCE / (stem + '.stderr')).write_bytes(process.stderr)
    emit(f'exit={process.returncode} elapsed={elapsed:.3f}s stdout_bytes={len(process.stdout)} stderr_bytes={len(process.stderr)}')
    emit('stdout:\n' + process.stdout.decode('utf-8', errors='backslashreplace'))
    emit('stderr:\n' + process.stderr.decode('utf-8', errors='backslashreplace'))
    commands.append({'label': label, 'command': command, 'exit': process.returncode, 'elapsed_seconds': elapsed, 'stdout': str(EVIDENCE / (stem + '.stdout')), 'stderr': str(EVIDENCE / (stem + '.stderr'))})
    return process


def expect(condition, message):
    if not condition:
        raise AssertionError(message)
    emit('CHECK PASS: ' + message)


def snapshot(path, label):
    records = {}
    def visit(p):
        try:
            st = p.lstat()
        except FileNotFoundError:
            records[str(p.relative_to(path))] = {'missing': True}
            return
        row = {'mode': stat.S_IMODE(st.st_mode), 'type': stat.S_IFMT(st.st_mode), 'inode': st.st_ino, 'mtime_ns': st.st_mtime_ns, 'size': st.st_size}
        if p.is_symlink():
            row['target'] = os.readlink(p)
        elif stat.S_ISREG(st.st_mode):
            try:
                data = p.read_bytes()
                row.update(sha256=hashlib.sha256(data).hexdigest(), bytes_base64=base64.b64encode(data).decode(), text=data.decode('utf-8', errors='backslashreplace'))
            except PermissionError:
                row['read_error'] = 'PermissionError'
        records[str(p.relative_to(path))] = row
        if stat.S_ISDIR(st.st_mode):
            try:
                children = sorted(p.iterdir())
            except PermissionError:
                row['list_error'] = 'PermissionError'
                return
            for child in children:
                visit(child)
    visit(path)
    (EVIDENCE / (label + '.snapshot.json')).write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding='utf-8')
    return records


def query(path, label, actor='main', state=None):
    return run(label, [DRAIN, '--queued'], env_for(path, state, actor), timeout=5)


def append(path, label, kind, key, payload):
    process = run(label, ['/bin/bash', '-c', '. "$1"; fm_wake_append "$2" "$3" "$4"', '_', LIB, kind, key, payload], env_for(path))
    expect(process.returncode == 0, label + ' production append succeeds')


def ack(path, label, drain):
    match = re.search(rb'^WAKE_ACK_REQUIRED:.*--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)$', drain.stderr, re.M)
    expect(match is not None, label + ' drain prints executable acknowledgement')
    process = run(label, [DRAIN, '--ack-through', match[1].decode(), '--recovery-generation', match[2].decode()], env_for(path))
    expect(process.returncode == 0, label + ' acknowledgement succeeds')


def scenario(name, fn):
    emit('\n===== SCENARIO: ' + name + ' =====')
    try:
        fn()
        results.append({'name': name, 'result': 'PASS', 'live': True, 'evidence': str(EVIDENCE / 'transcript.log'), 'reason': 'All recorded scenario assertions passed.'})
    except Exception as exc:
        emit('SCENARIO FAIL: ' + repr(exc))
        results.append({'name': name, 'result': 'FAIL', 'live': True, 'evidence': str(EVIDENCE / 'transcript.log'), 'reason': str(exc)})


def lifecycle():
    path = home('lifecycle')
    key = 'literal "quote" [.*] $dollar; `backtick` \\key ☃.status'
    payload = 'signal: UTF-8 café 雪 🧭; literal \\n \\t \\123 "quote" [.*] $dollar $(touch NEVER) `echo nope`\\end\tTAB\rCR\nLINE'
    (EVIDENCE / 'literal-input.json').write_text(json.dumps({'key': key, 'payload': payload}, ensure_ascii=False, indent=2), encoding='utf-8')
    append(path, 'literal-append', 'signal', key, payload)
    append(path, 'same-key-newer-append', 'signal', key, 'signal: newer same-key row — naïve')
    queue = (path / 'state/.wake-queue').read_bytes()
    rows = queue.splitlines()
    parsed = [r.decode('utf-8').split('\t') for r in rows]
    clean = payload.translate(str.maketrans({'\t': ' ', '\r': ' ', '\n': ' '}))
    expect(len(parsed) == 2 and all(len(r) == 5 for r in parsed), 'appends produce exactly two five-column rows')
    expect(parsed[0][1:] == ['1', 'signal', key, clean], 'serialized key/payload preserve UTF-8 and metacharacters; only actual TAB/CR/LF become spaces')
    expect(parsed[1][1] == '2' and parsed[1][3] == key, 'same-key second row receives next sequence')
    lock = path / 'state/.wake-queue.lock'
    lock.mkdir()
    (lock / 'pid').write_text(str(os.getpid()) + '\n')
    (path / 'state/.wake-queue.retire.abandoned').write_text('leftover scratch\n')
    before = snapshot(path, 'lifecycle-before-queued-live-lock')
    q = query(path, 'queued-live-lock')
    expect(q.returncode == 0 and q.stdout == queue and not q.stderr, '--queued returns exact queue bytes, append order and duplicates despite live lock')
    expect(before == snapshot(path, 'lifecycle-after-queued-live-lock'), '--queued changes no home/state bytes, modes, inode, mtime, recovery marker, lock or scratch')
    shutil.rmtree(lock)
    d = run('lifecycle-drain', [DRAIN], env_for(path), timeout=30)
    expect(d.returncode == 0, 'public drain succeeds')
    expect(parsed[1][4].encode() in d.stdout, 'public presentation includes newest same-key wake')
    before = snapshot(path, 'lifecycle-before-queued-presented')
    q = query(path, 'queued-after-presentation')
    expect(q.returncode == 0 and q.stdout == queue and not q.stderr, 'presentation leaves both unacknowledged rows visible to --queued')
    expect(before == snapshot(path, 'lifecycle-after-queued-presented'), 'post-presentation --queued leaves handling generation and claim untouched')
    append(path, 'late-append', 'check', 'late-key', 'check: arrived after presentation 雪')
    late = (path / 'state/.wake-queue').read_bytes().splitlines(keepends=True)[-1]
    ack(path, 'first-cutoff-ack', d)
    before = snapshot(path, 'lifecycle-before-queued-partial-ack')
    q = query(path, 'queued-after-partial-ack')
    expect(q.returncode == 0 and q.stdout == late and not q.stderr, 'ack consumes only original cutoff and --queued returns exact late row')
    expect(before == snapshot(path, 'lifecycle-after-queued-partial-ack'), 'partial-ack query leaves newer recovery episode untouched')
    d2 = run('late-row-drain', [DRAIN], env_for(path), timeout=30)
    expect(d2.returncode == 0 and late.rstrip(b'\n') in d2.stdout, 'second drain presents remaining late row')
    ack(path, 'late-row-ack', d2)
    expect((path / 'state/.wake-queue').read_bytes() == b'', 'final acknowledgement empties durable queue')
    expect((path / 'state/.watcher-down').read_text().startswith('acked:'), 'final acknowledgement retires recovery generation')
    before = snapshot(path, 'lifecycle-before-final-queued')
    q = query(path, 'queued-after-final-ack')
    expect(q.returncode == 0 and not q.stdout and not q.stderr, '--queued is empty after all rows acknowledged')
    expect(before == snapshot(path, 'lifecycle-after-final-queued'), 'empty --queued leaves acked recovery and queue untouched')


def missing_and_empty():
    path = home('missing-empty')
    missing = path / 'never-created/nested/state'
    before = snapshot(path, 'missing-state-before')
    for actor in ('main', 'branch'):
        q = query(path, 'missing-state-' + actor, actor, missing)
        expect(q.returncode == 0 and not q.stdout and not q.stderr, actor + ' missing-state query succeeds empty')
    expect(not (path / 'never-created').exists(), 'missing-state queries create no ancestor/state directory')
    expect(before == snapshot(path, 'missing-state-after'), 'missing-state queries perform no isolated-home writes')
    (path / 'state').mkdir()
    before = snapshot(path, 'missing-queue-before')
    q = query(path, 'missing-queue')
    expect(q.returncode == 0 and not q.stdout and not q.stderr and not (path / 'state/.wake-queue').exists(), 'missing queue succeeds empty without creating queue')
    expect(before == snapshot(path, 'missing-queue-after'), 'missing-queue query performs no home/state writes')
    (path / 'state/.wake-queue').write_bytes(b'')
    for i, marker in enumerate(('pending:downtime:g1', 'announced:downtime:g2', 'pending:handling:g3', 'announced:handling:g4', 'acked:downtime:g5', 'not a marker')):
        (path / 'state/.watcher-down').write_text(marker + '\n')
        before = snapshot(path, f'empty-marker-{i}-before')
        for actor in ('main', 'branch'):
            q = query(path, f'empty-marker-{i}-{actor}', actor)
            expect(q.returncode == 0 and not q.stdout and not q.stderr, actor + ' marker-only query succeeds empty for ' + marker)
        expect(before == snapshot(path, f'empty-marker-{i}-after'), 'marker-only query does not transition/repair marker ' + marker)


def actor_grants():
    path = home('actor-grants')
    append(path, 'grant-branch-row-append', 'signal', 'same.status', 'signal: reserved branch 雪')
    owner = subprocess.Popen(['/bin/sleep', '60'], env=BASE, cwd=ROOT)
    owners.append(owner)
    emit('$ /bin/sleep 60 &  # isolated identity-matched live grant owner pid=' + str(owner.pid))
    p = run('grant-activate', [GRANT, 'activate', str(owner.pid), 'queued-public-proof'], env_for(path))
    expect(p.returncode == 0, 'public grant activate succeeds with real live process identity')
    p = run('grant-publish', [GRANT, 'publish', 'queued-public-proof', '1'], env_for(path))
    expect(p.returncode == 0, 'public grant publish reserves sequence 1')
    q = query(path, 'held-only-main-queued')
    expect(q.returncode == 0 and not q.stdout and not q.stderr, 'main is empty when all owed rows belong to live branch')
    append(path, 'grant-main-row-append', 'signal', 'same.status', 'signal: main same-key newer 🧭')
    queue = (path / 'state/.wake-queue').read_bytes()
    rows = queue.splitlines(keepends=True)
    before = snapshot(path, 'live-grant-before')
    main = query(path, 'live-grant-main')
    branch = query(path, 'live-grant-branch', 'branch')
    expect(main.returncode == 0 and main.stdout == rows[1] and not main.stderr, 'main reads exactly unreserved sequence 2 even with same-key branch row')
    expect(branch.returncode == 0 and branch.stdout == rows[0] and not branch.stderr, 'branch reads exactly granted sequence 1, not main row')
    expect(before == snapshot(path, 'live-grant-after'), 'live-grant --queued reads do not mutate owner, rows, queue or recovery')
    owner.terminate()
    owner.wait(timeout=5)
    emit('Grant owner terminated and reaped; grant files intentionally remain for stale-owner read.')
    before = snapshot(path, 'stale-grant-before')
    main = query(path, 'stale-grant-main')
    branch = query(path, 'stale-grant-branch', 'branch')
    expect(main.returncode == 0 and main.stdout == queue and not main.stderr, 'dead-owner grant returns every durable row to main')
    expect(branch.returncode == 0 and not branch.stdout and not branch.stderr, 'dead-owner branch query succeeds empty')
    expect(before == snapshot(path, 'stale-grant-after'), 'stale-owner --queued does not repair or reclaim grant files')


def failures():
    path = home('failures')
    append(path, 'failure-valid-prefix-append', 'signal', 'valid.status', 'signal: valid UTF-8 雪')
    queue_path = path / 'state/.wake-queue'
    valid = queue_path.read_bytes()
    malformed = [('nonnumeric-sequence', b'1\tbad\tsignal\tkey\tpayload\n'), ('truncated', b'invalid\n'), ('missing-field', b'1\t9\tsignal\tkey\n'), ('extra-field', b'1\t9\tsignal\tkey\tpayload\textra\n'), ('nonnumeric-epoch', b'bad\t9\tsignal\tkey\tpayload\n'), ('unknown-kind', b'1\t9\tunknown\tkey\tpayload\n')]
    for name, bad in malformed:
        queue_path.write_bytes(valid + bad)
        before = snapshot(path, name + '-before')
        for actor in ('main', 'branch'):
            q = query(path, name + '-' + actor, actor)
            expect(q.returncode == 1 and not q.stdout, name + ' ' + actor + ' fails closed with no valid prefix leakage')
        expect(before == snapshot(path, name + '-after'), name + ' query does not repair/mutate malformed queue or recovery')
    queue_path.write_bytes(valid)
    for name, chmod_path, restore_mode in [('unreadable-queue', queue_path, 0o600), ('inaccessible-state', path / 'state', 0o700)]:
        chmod_path.chmod(0)
        try:
            before = snapshot(path, name + '-before')
            for actor in ('main', 'branch'):
                q = query(path, name + '-' + actor, actor)
                expect(q.returncode == 1 and not q.stdout, name + ' ' + actor + ' fails closed with empty stdout under real permissions')
            expect(before == snapshot(path, name + '-after'), name + ' queries perform no repair/writes')
        finally:
            chmod_path.chmod(restore_mode)
        expect(queue_path.read_bytes() == valid, name + ' retains exact durable queue after restoring fixture permissions')
    queue_path.unlink()
    queue_path.mkdir()
    before = snapshot(path, 'queue-directory-before')
    q = query(path, 'queue-path-is-directory')
    expect(q.returncode == 1 and not q.stdout, 'queue path directory fails closed')
    expect(before == snapshot(path, 'queue-directory-after'), 'invalid queue path query performs no writes')
    queue_path.rmdir()
    queue_path.symlink_to(path / 'state/absent-target')
    before = snapshot(path, 'queue-broken-symlink-before')
    q = query(path, 'queue-broken-symlink')
    expect(q.returncode == 1 and not q.stdout, 'broken queue symlink fails closed rather than reporting missing queue')
    expect(before == snapshot(path, 'queue-broken-symlink-after'), 'broken symlink query performs no writes')
    queue_path.unlink()
    queue_path.write_bytes(valid)
    before = snapshot(path, 'invalid-arguments-before')
    for extra in ('extra', '--reemit'):
        p = run('queued-invalid-extra-' + extra.replace('--', ''), [DRAIN, '--queued', extra], env_for(path))
        expect(p.returncode == 2 and not p.stdout, 'extra --queued argument is refused: ' + extra)
    p = run('queued-invalid-actor', [DRAIN, '--queued'], env_for(path, actor='invalid'))
    expect(p.returncode == 2 and not p.stdout, 'invalid actor is refused with exit 2')
    expect(before == snapshot(path, 'invalid-arguments-after'), 'argument refusals perform no home/state writes')


try:
    emit('Direct real production CLI proof. No product substitutions, model processes, Herdr, tmux, or suite execution. PATH restricted to system tools; HOME/FM_HOME/STATE/config/XDG/TMPDIR isolated under fixture. Append calls production fm_wake_append via /bin/bash; reads, presentation, acknowledgement and grants invoke real public executables.')
    emit('cwd=' + str(ROOT) + '\nuid=' + str(os.getuid()))
    scenario('queued_exact_payload_read_only_and_ack_lifecycle', lifecycle)
    scenario('queued_missing_state_queue_and_marker_only_no_writes', missing_and_empty)
    scenario('queued_live_and_stale_actor_ownership', actor_grants)
    scenario('queued_malformed_unreadable_paths_and_arguments_fail_closed', failures)
finally:
    for owner in owners:
        if owner.poll() is None:
            owner.terminate()
            owner.wait(timeout=5)
    for directory, dirs, files in os.walk(FIXTURE):
        os.chmod(directory, 0o700)
        for file in files:
            p = Path(directory) / file
            if not p.is_symlink():
                p.chmod(0o600)
    shutil.rmtree(FIXTURE)
    emit('CLEANUP: dedicated fixture removed=' + str(not FIXTURE.exists()))
    summary = {'results': results, 'commands': commands, 'fixture': str(FIXTURE), 'fixture_removed': not FIXTURE.exists(), 'evidence': str(EVIDENCE), 'issues': [r for r in results if r['result'] != 'PASS']}
    (EVIDENCE / 'results.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    LOG.close()
print(json.dumps({'results': results, 'fixture_removed': not FIXTURE.exists(), 'commands_executed': len(commands), 'evidence': str(EVIDENCE)}, ensure_ascii=False, indent=2))
sys.exit(1 if any(r['result'] != 'PASS' for r in results) else 0)
