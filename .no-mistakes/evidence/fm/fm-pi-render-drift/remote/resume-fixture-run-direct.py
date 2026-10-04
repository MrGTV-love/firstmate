import base64
import datetime
import hashlib
import json
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import time

ROOT = pathlib.Path.cwd().resolve()
OWN = ROOT / '.live-validation' / 'remote'
EVIDENCE = pathlib.Path('/Users/charlesabrooker/tmp/fm-pi-render-drift-main016.mYxnxr/nm/evidence/01M445ME32DXNHDANAED5TJK7X/remote')
PRODUCT = ROOT / 'bin/fm-remote-home-provision.sh'
GIT = '/usr/bin/git'
BASE = dict(os.environ)
for name in list(BASE):
    if name.startswith(('GIT_', 'FM_', 'DYLD_')):
        BASE.pop(name)
BASE.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(OWN / 'home'), TMPDIR=str(OWN / 'tmp'),
            GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', LC_ALL='C')
COMMANDS = EVIDENCE / 'commands.log'
shutil.copy2(EVIDENCE / 'outcomes.json', EVIDENCE / 'initial-instrument-failure.outcomes.json')
OUTCOMES = json.loads((EVIDENCE / 'outcomes.json').read_text())['outcomes']
PROCESSES = []
COUNTER = 0


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def record(command, env, stdin=None, output=None):
    settings = {key: value for key, value in env.items() if BASE.get(key) != value}
    parts = ['env'] + [f'{key}={value}' for key, value in sorted(settings.items())] + [str(v) for v in command]
    line = shlex.join(parts)
    if stdin:
        line += ' < ' + shlex.quote(str(stdin))
    if output:
        line += ' > ' + shlex.quote(str(output)) + ' 2>&1'
    with COMMANDS.open('a') as fh:
        fh.write(timestamp() + ' ' + line + '\n')


def run(command, name=None, env=None, input_bytes=None, check=True):
    global COUNTER
    COUNTER += 1
    env = env or BASE
    output = EVIDENCE / (name or f'resume-setup-{COUNTER:03d}.log')
    record(command, env, output=output)
    started = timestamp()
    result = subprocess.run([str(v) for v in command], env=env, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output.write_bytes(result.stdout)
    with COMMANDS.open('a') as fh:
        fh.write(f'{timestamp()} exit={result.returncode} output={output.name} started={started}\n')
    if check and result.returncode != 0:
        raise RuntimeError(f'{command!r} exited {result.returncode}: {result.stdout.decode(errors="replace")}')
    return result


def git(repo, *args, **kwargs):
    return run([GIT, '-C', repo, *args], **kwargs)


def configure(repo):
    git(repo, 'config', 'user.name', 'Disposable live validation')
    git(repo, 'config', 'user.email', 'live-validation@example.invalid')
    git(repo, 'config', 'maintenance.auto', 'false')
    git(repo, 'config', 'gc.auto', '0')
    git(repo, 'config', 'pack.threads', '1')


def clone(source, destination):
    run([GIT, 'clone', '--quiet', '--no-local', '--', source, destination])
    configure(destination)


def b64(value):
    return base64.b64encode(value.encode()).decode()


def manifest(name, identity, charter, projects=()):
    path = OWN / (name + '.manifest')
    lines = ['schema=fm-remote-home-provision.v1', 'id_b64=' + b64(identity), 'charter_b64=' + b64(charter),
             'parent_host_b64=' + b64('parent-live-validation'), 'project_count=' + str(len(projects))]
    for project, origin in projects:
        registry = f'- {project} ({origin}) — direct-PR'
        lines.append('project=' + '|'.join(b64(item) for item in (project, origin, registry, 'direct-PR')))
    path.write_text('\n'.join(lines) + '\n')
    shutil.copy2(path, EVIDENCE / path.name)
    return path


def start_provision(name, source, home, manifest_path, extra=None):
    env = dict(BASE, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(source), GIT_TRACE2_EVENT=str(EVIDENCE / (name + '.trace2.jsonl')))
    env.update(extra or {})
    output = EVIDENCE / (name + '.product.log')
    record([PRODUCT], env, stdin=manifest_path, output=output)
    with manifest_path.open('rb') as stdin, output.open('wb') as stdout:
        process = subprocess.Popen([str(PRODUCT)], env=env, stdin=stdin, stdout=stdout, stderr=subprocess.STDOUT, start_new_session=True)
    PROCESSES.append(process)
    return dict(name=name, process=process, started=timestamp(), home=home, source=source, output=output)


def finish(item, expected=0):
    code = item['process'].wait(timeout=180)
    item['finished'] = timestamp()
    item['exit'] = code
    with COMMANDS.open('a') as fh:
        fh.write(f'{item["finished"]} product={item["name"]} exit={code} started={item["started"]}\n')
    if code != expected:
        raise RuntimeError(f'{item["name"]}: expected exit {expected}, got {code}: {item["output"].read_text()}')
    return code


def stages(parent):
    return sorted(str(p) for p in parent.glob('.fm-home-provisioning.*'))


def assert_no_staging(parent):
    assert not stages(parent), stages(parent)


def hash_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_checkout(name, source, home, identity, expected_head=None):
    source_head = expected_head or git(source, 'rev-parse', 'HEAD').stdout.decode().strip()
    actual_head = git(home, 'rev-parse', 'HEAD', name=name + '.head.log').stdout.decode().strip()
    assert actual_head == source_head, (source_head, actual_head)
    assert git(home, 'rev-parse', '--show-toplevel').stdout.decode().strip() == str(home)
    git(home, 'fsck', '--full', '--no-progress', name=name + '.fsck.log')
    git(home, 'diff', '--exit-code', 'HEAD', name=name + '.tracked-diff.log')
    paths = git(source, 'ls-files', '-z').stdout.split(b'\0')
    digest = hashlib.sha256()
    count = 0
    for raw in paths:
        if not raw:
            continue
        relative = os.fsdecode(raw)
        src, dest = source / relative, home / relative
        if src.is_symlink():
            assert dest.is_symlink() and os.readlink(src) == os.readlink(dest), relative
            content = os.readlink(src).encode()
        else:
            assert dest.is_file(), relative
            content = src.read_bytes()
            assert content == dest.read_bytes(), relative
            assert (src.stat().st_mode & 0o111) == (dest.stat().st_mode & 0o111), relative
        digest.update(raw + b'\0' + hashlib.sha256(content).digest())
        count += 1
    assert (home / '.fm-secondmate-home').read_text() == identity + '\n'
    assert (home / '.fm-secondmate-parent').read_text() == 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=parent-live-validation\n'
    for directory in ('data', 'state', 'config', 'projects'):
        assert (home / directory).is_dir() and not (home / directory).is_symlink()
    assert (home / 'data/backlog.md').read_text() == '## In flight\n\n## Queued\n\n## Done\n'
    assert (home / 'data/charter.md').stat().st_mode & 0o777 == 0o600
    assert_no_staging(home.parent)
    state = dict(home=str(home), head=actual_head, tracked_files_compared=count, tracked_tree_sha256=digest.hexdigest(),
                 marker=(home / '.fm-secondmate-home').read_text(), parent_record=(home / '.fm-secondmate-parent').read_text(),
                 charter=(home / 'data/charter.md').read_text(), charter_mode=oct((home / 'data/charter.md').stat().st_mode & 0o777),
                 registry=(home / 'data/projects.md').read_text(), backlog=(home / 'data/backlog.md').read_text(),
                 fsck_exit=0, tracked_diff_exit=0, staging_paths=[])
    (EVIDENCE / (name + '.persisted-state.json')).write_text(json.dumps(state, indent=2) + '\n')
    return state


def events(path):
    if not path.exists():
        return []
    result = []
    for line in path.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return result


def reader_intervals(name):
    entries = events(EVIDENCE / (name + '.trace2.jsonl'))
    reader_sids = {e['sid'] for e in entries if e.get('event') == 'cmd_name' and e.get('name') == 'pack-objects'}
    intervals = []
    for sid in reader_sids:
        group = [e for e in entries if e.get('sid') == sid]
        starts = [e['time'] for e in group if e.get('event') == 'start']
        exits = [e['time'] for e in group if e.get('event') == 'exit']
        if starts and exits:
            intervals.append(dict(start=min(starts), end=max(exits), sid=sid))
    return intervals


def dt(value):
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))


try:
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    (EVIDENCE / 'environment.json').write_text(json.dumps(dict(worktree=str(ROOT), product=str(PRODUCT), product_sha256=hash_file(PRODUCT),
        isolated_environment={key: BASE[key] for key in ('PATH', 'HOME', 'TMPDIR', 'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'LC_ALL')}), indent=2) + '\n')
    for relative in ('run-direct.py', 'instruments/repack-race.c', 'bin/git', 'bin/git-upload-pack', 'bin/git-pack-objects', 'hold-bin/git'):
        shutil.copy2(OWN / relative, EVIDENCE / ('resume-fixture-' + relative.replace('/', '-')))
    run(['/usr/bin/uname', '-a'], name='platform.log')
    run([GIT, '--version'], name='git-version.log')
    source = OWN / 'source'
    clone(ROOT, source)
    working_diff = git(ROOT, 'diff', '--binary', 'HEAD', name='source-working-tree.patch').stdout
    if working_diff:
        git(source, 'apply', '--binary', input_bytes=working_diff)
        git(source, 'add', '-A')
        git(source, 'commit', '-qm', 'Disposable snapshot of current tracked worktree')
    source_head = git(source, 'rev-parse', 'HEAD').stdout.decode().strip()
    assert (source / 'bin/fm-remote-home-provision.sh').read_bytes() == PRODUCT.read_bytes()
    projects = []
    project_heads = {}
    for name in ('alpha', 'beta'):
        repo = OWN / ('project-' + name)
        repo.mkdir()
        git(repo, 'init', '--quiet')
        configure(repo)
        (repo / 'payload.txt').write_text('Real project clone payload for ' + name + '.\n')
        git(repo, 'add', 'payload.txt')
        git(repo, 'commit', '-qm', 'Disposable project origin')
        bare = OWN / ('origin-' + name + '.git')
        run([GIT, 'clone', '--quiet', '--bare', '--no-local', '--', repo, bare])
        origin = bare.as_uri() if name == 'alpha' else str(bare)
        projects.append((name, origin))
        project_heads[name] = git(repo, 'rev-parse', 'HEAD').stdout.decode().strip()
    repack_source = OWN / 'source-exact-repack'
    clone(source, repack_source)
    (repack_source / 'repack-content.bin').write_bytes(os.urandom(256 * 1024))
    git(repack_source, 'add', 'repack-content.bin')
    git(repack_source, 'commit', '-qm', 'Disposable loose-object repack fixture')
    repack_blob = git(repack_source, 'rev-parse', 'HEAD:repack-content.bin').stdout.decode().strip()
    repack_object = repack_source / '.git/objects' / repack_blob[:2] / repack_blob[2:]
    assert repack_object.is_file()
    stress_source = OWN / 'source-stress'
    clone(source, stress_source)
    stress_data = stress_source / 'live-repack-payload'
    stress_data.mkdir()
    for i in range(24):
        (stress_data / f'{i:02d}.bin').write_bytes(os.urandom(1024 * 1024))
    git(stress_source, 'add', 'live-repack-payload')
    git(stress_source, 'commit', '-qm', 'Disposable concurrent transport and repack payload')
    stress_head = git(stress_source, 'rev-parse', 'HEAD').stdout.decode().strip()
    stress_blob = git(stress_source, 'rev-parse', 'HEAD:live-repack-payload/00.bin').stdout.decode().strip()
    stress_object = stress_source / '.git/objects' / stress_blob[:2] / stress_blob[2:]
    object_backup = OWN / 'stress-loose-object.backup'
    shutil.copy2(stress_object, object_backup)
    success_manifest = manifest('success', 'live-success', 'Successful live provisioning charter.\n', projects)
    race_manifest = manifest('race', 'live-race', 'Real source-repack provisioning charter.\n')
    competing_manifest = manifest('competing', 'live-competing', 'Competing home must not be adopted.\n')
    # All initial repositories and timing instruments are ready before product execution.
    # Darwin interposition changes timing only; real Git and real repack own all object data.
    repack_marker = EVIDENCE / 'exact-repack-native.marker.log'
    instrument_env = dict(PATH=str(OWN / 'bin') + ':' + BASE['PATH'], GIT_EXEC_PATH=str(OWN / 'bin'),
        FM_LIVE_REAL_GIT=str(OWN / 'instruments/git'), FM_LIVE_DYLIB=str(OWN / 'instruments/repack-race.dylib'),
        FM_LIVE_REPACK_OBJECT=str(repack_object), FM_LIVE_REPACK_MARKER=str(repack_marker), FM_LIVE_REPACK_ROOT=str(repack_source),
        FM_LIVE_COMMAND_LOG=str(EVIDENCE / 'exact-repack-native.instrument-commands.log'))
    exact_home = OWN / 'home-exact-repack'
    exact = start_provision('exact-repack-native', repack_source, exact_home, race_manifest, instrument_env)
    exact_exit = exact['process'].wait(timeout=180)
    exact_observed = repack_marker.exists() and 'loose_object_removed=1' in repack_marker.read_text()
    if exact_exit != 0:
        raise RuntimeError('Instrumented exact repack product failed: ' + exact['output'].read_text())
    verify_checkout('exact-repack-native', repack_source, exact_home, 'live-race')
    if exact_observed:
        assert not repack_object.exists()
        git(repack_source, 'cat-file', '-e', repack_blob, name='exact-repack-native.source-object-retained.log')
    OUTCOMES.append(dict(scenario='Darwin selected-object before-read repack', exit=exact_exit, exact_before_read_race_observed=exact_observed,
        selected_loose_object_exists_after=repack_object.exists(), characterization='real selected-object repack before reader open' if exact_observed else 'instrumented provision succeeded but interposer did not observe selected-object read; concurrent stress is authoritative'))
    # Three actual repacks each overlap two public provisions; no Git wrappers in this stress leg.
    for round_number in range(1, 4):
        if not stress_object.exists():
            stress_object.parent.mkdir(exist_ok=True)
            shutil.copy2(object_backup, stress_object)
        assert stress_object.is_file()
        attempts = [start_provision(f'stress-{round_number}-{i}', stress_source, OWN / f'home-stress-{round_number}-{i}', race_manifest) for i in (1, 2)]
        deadline = time.monotonic() + 30
        while True:
            active_readers = []
            for item in attempts:
                entries = events(EVIDENCE / (item['name'] + '.trace2.jsonl'))
                if any(e.get('event') == 'cmd_name' and e.get('name') == 'pack-objects' for e in entries) and item['process'].poll() is None:
                    active_readers.append(item['name'])
            if active_readers:
                break
            if all(item['process'].poll() is not None for item in attempts) or time.monotonic() > deadline:
                raise RuntimeError('Stress fixture did not reach live source pack-objects before provisions completed')
            time.sleep(0.005)
        repack_started = timestamp()
        repack = run([GIT, '-C', stress_source, 'repack', '-adf'], name=f'stress-{round_number}.repack.log')
        repack_finished = timestamp()
        assert not stress_object.exists()
        git(stress_source, 'cat-file', '-e', stress_blob, name=f'stress-{round_number}.source-object-retained.log')
        round_states = []
        for item in attempts:
            finish(item)
            verify_checkout(item['name'], stress_source, item['home'], 'live-race', stress_head)
            intervals = reader_intervals(item['name'])
            overlap = [r for r in intervals if dt(r['start']) < dt(repack_finished) and dt(r['end']) > dt(repack_started)]
            round_states.append(dict(product=item['name'], exit=0, source_pack_objects_intervals=intervals, overlap_intervals=overlap))
        assert any(item['overlap_intervals'] for item in round_states), round_states
        OUTCOMES.append(dict(scenario=f'real concurrent repack stress round {round_number}', repack_command=[GIT, '-C', str(stress_source), 'repack', '-adf'],
            repack_exit=repack.returncode, repack_started=repack_started, repack_finished=repack_finished, active_readers_at_start=active_readers,
            selected_loose_object_removed=True, source_object_retained=True, provisions=round_states,
            characterization='trace2 proves source pack-objects process/repack interval overlap, not a particular object disappearing between selection and read'))
    # Pause a real clone only after its real staging object directory exists.
    marker = OWN / 'competing-clone.held'
    release = OWN / 'competing-clone.release'
    competing_home = OWN / 'home-competing'
    competing = start_provision('competing-home', stress_source, competing_home, competing_manifest,
        dict(PATH=str(OWN / 'hold-bin') + ':' + BASE['PATH'], FM_LIVE_HOLD_PARENT=str(OWN), FM_LIVE_HOLD_MARKER=str(marker), FM_LIVE_HOLD_RELEASE=str(release)))
    deadline = time.monotonic() + 30
    while not marker.exists():
        if competing['process'].poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Competing-home fixture could not hold a real live clone: ' + competing['output'].read_text())
        time.sleep(0.005)
    assert not competing_home.exists()
    held = dict(line.split('=', 1) for line in marker.read_text().splitlines())
    assert pathlib.Path(held['stage'], '.git/objects').is_dir() and held['state'].startswith('T')
    run(['/bin/ps', '-p', held['clone_pid'], '-o', 'pid=,stat=,command='], name='competing-home.stopped-real-clone.log')
    competing_home.mkdir()
    foreign = competing_home / 'foreign'
    foreign.write_bytes(b'foreign owner data survives unchanged\n')
    foreign.chmod(0o640)
    before = dict(sha256=hash_file(foreign), inode=foreign.stat().st_ino, mode=foreign.stat().st_mode & 0o777, mtime_ns=foreign.stat().st_mtime_ns,
                  entries=sorted(p.name for p in competing_home.iterdir()))
    release.touch()
    finish(competing, expected=1)
    assert 'remote home appeared while it was being provisioned' in competing['output'].read_text()
    after = dict(sha256=hash_file(foreign), inode=foreign.stat().st_ino, mode=foreign.stat().st_mode & 0o777, mtime_ns=foreign.stat().st_mtime_ns,
                 entries=sorted(p.name for p in competing_home.iterdir()))
    assert before == after, (before, after)
    assert not (competing_home / '.fm-secondmate-home').exists()
    assert not list(competing_home.glob('.fm-home-provisioning.*'))
    assert_no_staging(OWN)
    persisted = dict(held_clone=held, public_home_absent_while_clone_stopped=True, before=before, after=after, stage_removed=not pathlib.Path(held['stage']).exists(),
                     nested_stages=[], public_home_preserved=True, home_marker_exists=False)
    (EVIDENCE / 'competing-home.persisted-state.json').write_text(json.dumps(persisted, indent=2) + '\n')
    OUTCOMES.append(dict(scenario='competing home appears while real clone is stopped in private staging', exit=1, expected_refusal=True, rollback_removed_only_owned_staging=True,
                         foreign_home_contents_inode_mode_mtime_unchanged=True))
    # The same unowned home is also refused on a later ordinary entrypoint call.
    refusal = start_provision('preexisting-home-refusal', source, competing_home, competing_manifest)
    finish(refusal, expected=1)
    assert 'existing remote home is not a safe Firstmate checkout' in refusal['output'].read_text()
    assert hash_file(foreign) == before['sha256'] and sorted(p.name for p in competing_home.iterdir()) == ['foreign']
    assert_no_staging(OWN)
    OUTCOMES.append(dict(scenario='preexisting foreign home refusal', exit=1, expected_refusal=True, foreign_home_preserved=True))
    (EVIDENCE / 'outcomes.json').write_text(json.dumps(dict(success=True, outcomes=OUTCOMES), indent=2) + '\n')
    print(json.dumps(dict(success=True, exact_before_read_race_observed=exact_observed, successful_provisions=8, successful_project_clones=2,
        repack_stress_rounds=3, expected_refusals=2, evidence=str(EVIDENCE)), indent=2))
except BaseException as exc:
    (EVIDENCE / 'outcomes.json').write_text(json.dumps(dict(success=False, error=str(exc), outcomes=OUTCOMES), indent=2) + '\n')
    raise
finally:
    release = OWN / 'competing-clone.release'
    if OWN.exists():
        release.touch()
    for process in PROCESSES:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGCONT)
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
    shutil.rmtree(OWN)
    cleanup = dict(owned_fixture=str(OWN), exists_after_cleanup=OWN.exists(), finished=timestamp(),
                   product_processes_remaining=[p.pid for p in PROCESSES if p.poll() is None])
    (EVIDENCE / 'cleanup.json').write_text(json.dumps(cleanup, indent=2) + '\n')
