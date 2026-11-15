#!/usr/bin/env python3
"""Executable fixtures for fm-cpu-pass.test.sh: how many CPU-bound test workers run together.

Usage: fm-cpu-pass-concurrency.py REPO TMPDIR PYTHON

Every case drives bin/fm-cpu-pass.sh, bin/fm-test-run.sh, bin/fm-duration.py or bin/fm-lint.sh as
separate processes against a private pool directory and a private slot directory, so the host's
real pool is never touched. The pool size is shrunk at the process boundary by a python3 shim
(never a production override). A synthetic worker is a fixed busy loop that holds a flock on a
marker file for as long as it lives; a sampler process counts the markers whose lock is held every
20 ms, so it sees grandchildren and a SIGKILLed worker leaves no phantom. The sampled maxima are
printed per case. Settings: FM_CONC_N (pool size, default 4), FM_CONC_LANES and FM_CONC_ROUNDS
(soak lanes, default 2 x N lanes and 5 rounds), FM_CONC_BURNERS (background burners, default 3), FM_CONC_WORK (CPU
seconds of a soak worker, default 0.3).
"""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

repo, parent, python = Path(sys.argv[1]).resolve(), Path(sys.argv[2]), sys.argv[3]
N = int(os.environ.get('FM_CONC_N', '4'))
LANES = int(os.environ.get('FM_CONC_LANES', str(2 * N)))
ROUNDS = int(os.environ.get('FM_CONC_ROUNDS', '5'))
BURNERS = int(os.environ.get('FM_CONC_BURNERS', '3'))
WORK = os.environ.get('FM_CONC_WORK', '0.3')  # CPU seconds of each soak worker
assert N >= 2 and N % 2 == 0, 'FM_CONC_N must be an even number of at least 2'
root = Path(tempfile.mkdtemp(prefix='concurrency-', dir=parent))
shim = root / 'bin'
shim.mkdir()
GIB = 2 ** 30

# Test-only injection at the process boundary: the pool size, a fake load average, a fake
# process-count source and a redirected run database. The same executable owners run underneath.
proxy = shim / 'python3'
proxy.write_text('#!' + python + '\n' + '''import json, os, runpy, sys
real = sys.executable
if len(sys.argv) > 1 and os.path.basename(sys.argv[1]) in ('fm-cpu-pass.py', 'fm-duration.py'):
    if os.environ.get('CASE_CORES'): os.cpu_count = lambda: int(os.environ['CASE_CORES'])
    if os.environ.get('CASE_LOAD'): os.getloadavg = lambda: tuple(json.load(open(os.environ['CASE_LOAD'])))
    import importlib.util, pathlib, sqlite3
    # Process-count, run-database and admission-log injection serves the pipeline-start path, which lives in fm-cpu-pass.py only.
    start_path = os.path.basename(sys.argv[1]) == 'fm-cpu-pass.py' and sys.argv[2:3] == ['pipeline-start']
    if start_path and os.environ.get('CASE_PROCS'):
        spec = importlib.util.spec_from_file_location('fm_proc_guard', os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), 'fm-proc-guard.py'))
        guard = importlib.util.module_from_spec(spec)
        sys.modules['fm_proc_guard'] = guard
        spec.loader.exec_module(guard)
        class Fake:
            name = 'darwin'
            def reading(self): return json.load(open(os.environ['CASE_PROCS']))
            def limit(self): return self.reading()['limit'], 'case'
            def count(self): return self.reading()['count']
        guard.open_source = lambda: Fake()
    if start_path and os.environ.get('CASE_ADMISSION_LOG'):
        import time as _time
        _sleep = _time.sleep
        def _logged(seconds):
            frame = sys._getframe(1)
            if frame.f_code.co_name == 'cmd_pipeline_start':
                with open(os.environ['CASE_ADMISSION_LOG'], 'a') as log:
                    log.write(str(frame.f_locals.get('reason', '?')) + '\\n')
            _sleep(seconds)
        _time.sleep = _logged
    if start_path and os.environ.get('CASE_DB'):
        connect = sqlite3.connect
        host = pathlib.Path('~/.no-mistakes/state.sqlite').expanduser().resolve().as_uri()
        def isolated(database, *args, **kwargs):
            path, separator, query = str(database).partition('?')
            if path != host:
                raise AssertionError('unexpected database ' + str(database))
            return connect(pathlib.Path(os.environ['CASE_DB']).resolve().as_uri() + separator + query, *args, **kwargs)
        sqlite3.connect = isolated
    if os.environ.get('CASE_GUARD_FAIL'):
        import subprocess as _sp
        _popen = _sp.Popen
        class _Popen(_popen):
            def __init__(self, args, *a, **k):
                if isinstance(args, (list, tuple)) and 'guard' in args and any(str(x).endswith('fm-cpu-pass.py') for x in args):
                    raise OSError(35, 'injected: the guard cannot be started')
                super().__init__(args, *a, **k)
        _sp.Popen = _Popen
    if os.environ.get('CASE_NO_FCNTL'):
        sys.modules['fcntl'] = None
    if os.environ.get('CASE_FOREIGN_OWNER'):
        _uid = os.getuid()
        os.getuid = lambda: _uid + 1
    if os.environ.get('CASE_BIND_HOLD'):
        import time as _t
        _write = os.write
        def _hold(fd, data):
            if data.endswith(b'\\n') and data[:-1].isdigit():
                open(os.environ['CASE_BIND_HOLD'] + '.reached', 'w').close()
                while not os.path.exists(os.environ['CASE_BIND_HOLD'] + '.release'):
                    _t.sleep(0.05)
            return _write(fd, data)
        os.write = _hold
    sys.executable = __file__
    sys.argv = sys.argv[1:]
    runpy.run_path(sys.argv[0], run_name='__main__')
else:
    os.execv(real, [real] + sys.argv[1:])
''')
proxy.chmod(0o700)
pyshim = str(proxy)  # the interpreter every pool participant runs under, so its pool is the shrunk one

worker = root / 'worker.py'
worker.write_text('''import fcntl, os, sys, time
alive, group, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
temporary = os.path.join(alive, '.tmp.%d' % os.getpid())
fd = os.open(temporary, os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
final = os.path.join(alive, '%s.%d' % (group, os.getpid()))
os.rename(temporary, final)
with open(os.path.join(alive, 'starts.log'), 'a') as log:
    log.write('%s %d %.6f\\n' % (group, os.getpid(), time.time()))
end = time.process_time() + seconds
while time.process_time() < end:
    pass
with open(os.path.join(alive, 'ends.log'), 'a') as log:
    log.write('%s %d %.6f\\n' % (group, os.getpid(), time.time()))
os.unlink(final)
''')

sampler = root / 'sampler.py'
sampler.write_text('''import fcntl, json, os, sys, time
alive, stop, out, pool, size = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
def locked(path):
    try:
        fd = os.open(path, os.O_RDWR)
    except OSError:
        return False, ''
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
            return False, ''
        except OSError:
            return True, os.pread(fd, 400, 0).decode('utf-8', 'replace').strip()
    finally:
        os.close(fd)
peak_total, peak_group, peak_held, samples, gaps, labels = 0, {}, 0, 0, [], set()
last = time.monotonic()
while not os.path.exists(stop):
    now = time.monotonic()
    gaps.append(now - last)
    last = now
    groups = {}
    for name in os.listdir(alive):
        if name.startswith('.') or '.' not in name or name.endswith('.log'):
            continue
        if locked(os.path.join(alive, name))[0]:
            groups[name.split('.')[0]] = groups.get(name.split('.')[0], 0) + 1
    held = 0
    for index in range(size):
        is_held, text = locked(os.path.join(pool, 'slot-%d.lock' % index))
        if is_held:
            held += 1
            if ' label=' in text:
                labels.add(text.split(' label=', 1)[1])
    total = sum(groups.values())
    peak_total = max(peak_total, total)
    peak_held = max(peak_held, held)
    for group, count in groups.items():
        peak_group[group] = max(peak_group.get(group, 0), count)
    samples += 1
    time.sleep(0.02)
gaps.sort()
json.dump(dict(peak_total=peak_total, peak_group=peak_group, peak_held=peak_held, samples=samples,
               gap_p99_ms=round(gaps[int(len(gaps) * 0.99) - 1] * 1000) if gaps else 0,
               gap_max_ms=round(gaps[-1] * 1000) if gaps else 0, labels=sorted(labels)), open(out, 'w'))
''')

burner = root / 'burner.py'
burner.write_text('''import os, sys, time
os.nice(10)
end = time.time() + float(sys.argv[1])
while time.time() < end:
    pass
''')

children = []
results = []


def tool(name):
    return str(repo / 'bin' / name)


class World:
    """One case's private pool, slot directory and worker marker directory."""

    def __init__(self, name, cores=N, extra=None):
        self.name = name
        self.folder = root / name
        self.folder.mkdir()
        self.pool, self.slots, self.alive = self.folder / 'pool', self.folder / 'slots', self.folder / 'alive'
        self.slots.mkdir()
        self.alive.mkdir()
        self.cores = cores
        self.env = dict(os.environ, PATH=str(shim) + os.pathsep + os.environ['PATH'], CASE_CORES=str(cores),
                        FM_CPU_POOL_DIR=str(self.pool), FM_TEST_SLOT_DIR=str(self.slots), FM_DURATION_FILE='off',
                        FM_CONC_PYTHON=python, FM_CONC_WORKER=str(worker), FM_CONC_ALIVE=str(self.alive))
        for name_ in ('FM_CPU_PASS_HELD', 'FM_CPU_PASS_TOKENS', 'FM_TEST_SLOT_WAIT_SECONDS', 'FM_TEST_KEY_SLOTS', 'FM_TEST_SLOT_HELD', 'FM_TEST_SLOT_PIDS',
                      'FM_DURATION_HOME', 'FM_HOME', 'FM_DATA_OVERRIDE'):
            self.env.pop(name_, None)
        self.env.update(extra or {})
        self.sampling = None

    def launch(self, label, command, extra=None):
        out = open(self.folder / (label + '.out'), 'w')
        err = open(self.folder / (label + '.err'), 'w')
        child = subprocess.Popen(command, env=dict(self.env, **(extra or {})), stdout=out, stderr=err, start_new_session=True)
        out.close()
        err.close()
        children.append(child)
        child.label = label
        child.world = self
        return child

    def text(self, label, stream='err'):
        path = self.folder / (label + '.' + stream)
        return path.read_text() if path.exists() else ''

    def work(self, group, seconds):
        return [python, str(worker), str(self.alive), group, str(seconds)]

    def sample_start(self):
        stop = self.folder / 'sampler.stop'
        stop.unlink(missing_ok=True)
        self.sampling = subprocess.Popen([python, str(sampler), str(self.alive), str(stop), str(self.folder / 'sampler.json'),
                                          str(self.pool), str(self.cores)])
        time.sleep(0.15)

    def sample_stop(self):
        (self.folder / 'sampler.stop').touch()
        self.sampling.wait(timeout=30)
        return json.loads((self.folder / 'sampler.json').read_text())

    def status_labels(self):
        status = subprocess.run(['bash', tool('fm-cpu-pass.sh'), 'status'], env=self.env, capture_output=True, text=True, timeout=30)
        return status.stdout


def wait_all(procs, timeout=180):
    codes = []
    for child in procs:
        try:
            codes.append(child.wait(timeout=timeout))
        except subprocess.TimeoutExpired:
            kill_group(child)
            codes.append('timeout')
    return codes


def kill_group(child):
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass


def sampling_valid(case, seen, label):
    """A sampler that saw no worker, or that slept longer than a worker lives, proves nothing about a cap."""
    case.measure(**{'sampler_gap_p99_max_ms[%s]' % label: '%d/%d' % (seen['gap_p99_ms'], seen['gap_max_ms'])})
    case.check(seen['peak_total'] > 0, '%s: the sampler never saw a worker, so a cap that held proves nothing' % label)
    # The contract asks for a sample at least every 50 ms: the p99 gap enforces that cadence, and a maximum gap of 250 ms is the
    # point where the sampler is declared invalid (a worker lives at least 300 ms), reported as invalid sampling, not a product failure.
    case.check(seen['gap_p99_ms'] <= 50 and seen['gap_max_ms'] <= 250,
               '%s: the sampler skipped too long (p99 gap %d ms, max gap %d ms): it may have missed a short-lived worker' % (label, seen['gap_p99_ms'], seen['gap_max_ms']))


def ends(world):
    log = world.alive / 'ends.log'
    rows = [line.split() for line in log.read_text().splitlines()] if log.exists() else []
    return [(group, int(pid), float(stamp)) for group, pid, stamp in rows]


# A case that sends kill signals or injects faults into a pass holder is CI-only: no host runs it (Main 1288, 1292).
ON_CI = bool(os.environ.get('CI') or os.environ.get('GITHUB_ACTIONS') or os.environ.get('FM_CONC_RUN_CI_ONLY'))


def ci_only(factory):
    factory.ci_only = True
    return factory


def starts(world):
    log = world.alive / 'starts.log'
    rows = [line.split() for line in log.read_text().splitlines()] if log.exists() else []
    return [(group, int(pid), float(stamp)) for group, pid, stamp in rows]


class Case:
    def __init__(self, ident, title):
        self.ident, self.title, self.measures, self.violations = ident, title, {}, []

    def measure(self, **values):
        self.measures.update(values)

    def check(self, condition, message):
        if not condition:
            self.violations.append(message)

    def report(self):
        print('CASE %s: %s' % (self.ident, self.title))
        for key, value in self.measures.items():
            print('  %s = %s' % (key, value))
        for message in self.violations:
            print('  VIOLATION: ' + message)
        print('  RESULT: %s' % ('FAIL' if self.violations else 'PASS'))
        sys.stdout.flush()


def runner_repo(world, scripts, seconds, group_env=None):
    """A fixture repository holding the real runner, whose scripts each run one synthetic worker."""
    path = world.folder / 'repo'
    (path / 'bin').mkdir(parents=True, exist_ok=True)
    (path / 'tests').mkdir(exist_ok=True)
    for name in ('fm-test-run.sh', 'fm-cpu-pass.sh', 'fm-cpu-pass.py', 'fm-timeout-lib.sh', 'fm-duration.py'):
        shutil.copy(repo / 'bin' / name, path / 'bin' / name)
    shutil.copy(repo / 'tests' / 'git-config-helpers.sh', path / 'tests')
    for name in scripts:
        (path / 'tests' / name).write_text('#!/usr/bin/env bash\nexec "$FM_CONC_PYTHON" "$FM_CONC_WORKER" "$FM_CONC_ALIVE" "${FM_CONC_GROUP:-script}" %s\n' % seconds)
    return path


def isolated_scripts(count):
    listing = subprocess.run(['bash', tool('fm-test-isolation-proof.sh'), '--list'], capture_output=True, text=True, check=True).stdout.split()
    names = [os.path.basename(item) for item in listing if item.endswith('.test.sh')]
    assert count is None or len(names) >= count, names
    return names if count is None else names[:count]


def nested_repo(world, outer, inner, seconds):
    """A fixture repository whose OUTER scripts each run the real runner over the INNER worker scripts: two levels of runner."""
    path = runner_repo(world, inner, seconds)
    for name in outer:
        (path / 'tests' / name).write_text('#!/usr/bin/env bash\ncd "$(dirname "$0")/.." || exit 1\n'
                                           'exec bin/fm-test-run.sh --jobs 2 %s\n' % ' '.join('tests/' + item for item in inner))
    return path


# --------------------------------------------------------------------------------------
def case_nested():
    """H3 a-c: K outer runners holding p passes each, each running an inner runner that asks for more."""
    case = Case('H3abc', 'nested runners: K outer runners x p passes, inner --jobs 6 over 8 scripts, pool size %d' % N)
    world = World('nested')
    p, K = N // 2, 3
    names = isolated_scripts(8)
    path = runner_repo(world, names, 0.35)
    world.sample_start()
    outers = [world.launch('outer%d' % i, ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', str(p), '--label', 'outer%d' % i, '--',
                                          'bash', '-c', 'cd "$1" && shift && exec bin/fm-test-run.sh --jobs 6 "$@"', '_', str(path)]
                           + ['tests/' + name for name in names], extra=dict(FM_CONC_GROUP='outer%d' % i)) for i in range(K)]
    codes = wait_all(outers)
    seen = world.sample_stop()
    case.measure(outer_runners=K, passes_each=p, pool_size=N, inner_jobs_requested=6, scripts_each=len(names),
                 sampled_max_workers_total=seen['peak_total'], sampled_max_per_outer=seen['peak_group'],
                 sampled_max_passes_held=seen['peak_held'], samples=seen['samples'], sampler_gap_p99_ms=seen['gap_p99_ms'],
                 sampler_gap_max_ms=seen['gap_max_ms'])
    case.check(codes == [0] * K, 'an outer runner failed: %s %s' % (codes, [world.text('outer%d' % i) for i in range(K)]))
    sampling_valid(case, seen, 'nested')
    case.check(seen['peak_total'] <= N, 'workers alive together %d exceed the pool size %d' % (seen['peak_total'], N))
    case.check(seen['peak_total'] > 0 and sum(1 for g in seen['peak_group'] if g.startswith('outer')) == K, 'a sampler that saw no worker of some outer runner proves nothing: %s' % seen)
    for group, peak in seen['peak_group'].items():
        case.check(peak <= p, '%s ran %d workers together inside %d passes' % (group, peak, p))
    case.check(seen['peak_held'] <= N, 'passes held together %d exceed the pool size %d' % (seen['peak_held'], N))
    case.check(K * p > N, 'the case must ask for more passes than the pool holds')
    for i in range(K):
        reduced = world.text('outer%d' % i).count('reducing --jobs 6 to inherited FM_CPU_PASS_HELD=%d' % p)
        case.check(reduced == 1, 'outer%d printed %d reduction notices instead of 1' % (i, reduced))
        case.check(world.text('outer%d' % i, 'out').count('exit=0') == len(names), 'outer%d did not finish every script' % i)
    return case


def case_nested_two_level():
    """H3 a-c, two levels: suites that each launch an inner runner share, not duplicate, the inherited passes."""
    case = Case('H3 two-level', 'outer runner inside p passes -> suites that each run an inner runner --jobs 2 -> workers')
    rows = {}
    for label, cores, K, p in (('pool2-one-outer-2-passes', 2, 1, 2), ('pool%d-two-outers-%d-passes' % (N, N // 2), N, 2, N // 2)):
        world = World('two-level-' + label, cores=cores)
        names = isolated_scripts(4)
        path = nested_repo(world, names[:2], names[2:], 0.5)
        world.sample_start()
        outers = [world.launch('outer%d' % i, ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', str(p), '--label', 'outer%d' % i, '--',
                                              'bash', '-c', 'cd "$1" && shift && exec bin/fm-test-run.sh --jobs 2 "$@"', '_', str(path)]
                               + ['tests/' + name for name in names[:2]], extra=dict(FM_CONC_GROUP='outer%d' % i)) for i in range(K)]
        codes = wait_all(outers)
        seen = world.sample_stop()
        began = len(starts(world))
        rows[label] = dict(outer_runners=K, passes_each=p, pool_size=cores, workers_started=began, sampled_max_workers_total=seen['peak_total'],
                           sampled_max_per_outer=seen['peak_group'], sampled_max_passes_held=seen['peak_held'], samples=seen['samples'])
        case.check(codes == [0] * K, '%s: an outer runner failed: %s %s' % (label, codes, [world.text('outer%d' % i) for i in range(K)]))
        sampling_valid(case, seen, label)
        case.check(began == 4 * K, '%s: only %d of %d workers started' % (label, began, 4 * K))
        case.check(seen['peak_total'] <= cores, '%s: %d workers alive together on a pool of %d' % (label, seen['peak_total'], cores))
        for group, peak in seen['peak_group'].items():
            case.check(peak <= p, '%s: %s ran %d workers together inside %d passes' % (label, group, peak, p))
        case.check(seen['peak_held'] <= cores, '%s: %d passes held together on a pool of %d' % (label, seen['peak_held'], cores))
    case.measure(**rows)
    return case


def case_padded_marker():
    """H3 d / nested-marker protocol: a valid decimal marker with leading zeros means the same count as its canonical form."""
    case = Case('H3 padded marker', 'FM_CPU_PASS_HELD=001 inside one genuinely held pass limits every participant to one worker')
    world = World('padded', cores=2)
    holder = ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', '1', '--label', 'outer', '--', 'env', 'FM_CPU_PASS_HELD=001']
    # The isolation proof.
    family = proof_family_repo(world, ['fm-fam-%d.test.sh' % index for index in range(4)])
    world.sample_start()
    proof = world.launch('proof', holder + ['bash', str(family / 'bin' / 'fm-test-isolation-proof.sh'), '--pool', 'fam', '--jobs', '4'])
    code = wait_all([proof])
    seen = world.sample_stop()
    case.measure(proof_markers=proof_markers(world.text('proof', 'out')), proof_sampled_max_workers=seen['peak_total'])
    case.check(code == [0], 'the proof failed: %s %s' % (code, world.text('proof')[-300:]))
    case.check(seen['peak_total'] == 1, 'the proof ran %d workers together inside one pass (marker 001)' % seen['peak_total'])
    case.check(proof_markers(world.text('proof', 'out')) == ['FM_ISOLATION_BEGIN concurrency=1', 'FM_ISOLATION_SUMMARY concurrency=1'],
               'the proof did not record the one worker it ran: %s' % proof_markers(world.text('proof', 'out')))
    # Lint.
    lint = World('padded-lint', cores=2)
    required = subprocess.run(['bash', tool('fm-lint.sh'), '--required-version'], capture_output=True, text=True, check=True).stdout.strip()
    fakebin = lint.folder / 'fakebin'
    fakebin.mkdir()
    (fakebin / 'shellcheck').write_text('#!/bin/sh\nif [ "$1" = "--version" ]; then printf "ShellCheck\\nversion: %s\\n" "' + required + '"; exit 0; fi\n'
                                        'exec "$FM_CONC_PYTHON" "$FM_CONC_WORKER" "$FM_CONC_ALIVE" lint 0.4\n')
    (fakebin / 'shellcheck').chmod(0o755)
    roots = []
    for index in range(4):
        script = lint.folder / ('root%d.sh' % index)
        script.write_text('#!/usr/bin/env bash\nexit 0\n')
        roots.append(str(script))
    lint.sample_start()
    run = lint.launch('lint', holder + ['bash', tool('fm-lint.sh'), '--jobs', '2'] + roots,
                      extra=dict(PATH=str(fakebin) + os.pathsep + lint.env['PATH'], FM_LINT_CACHE_DIR='off', FM_LINT_SLOT_DIR='off', FM_LINT_JOBS='2'))
    lint_code = wait_all([run])
    lint_seen = lint.sample_stop()
    case.measure(lint_sampled_max_shellchecks=lint_seen['peak_total'])
    case.check(lint_code == [0], 'lint failed: %s' % lint.text('lint')[-300:])
    case.check(lint_seen['peak_total'] == 1, 'lint ran %d ShellChecks together inside one pass (marker 001)' % lint_seen['peak_total'])
    # The runner.
    runner = World('padded-runner', cores=2)
    names = isolated_scripts(4)
    path = runner_repo(runner, names, 0.4)
    runner.sample_start()
    job = runner.launch('runner', holder + ['bash', str(path / 'bin' / 'fm-test-run.sh'), '--jobs', '4'] + ['tests/' + name for name in names],
                        extra=dict(FM_CONC_GROUP='runner'))
    runner_code = wait_all([job])
    runner_seen = runner.sample_stop()
    case.measure(runner_sampled_max_workers=runner_seen['peak_total'])
    case.check(runner_code == [0], 'runner failed: %s' % runner.text('runner')[-300:])
    case.check(runner_seen['peak_total'] == 1, 'the runner ran %d workers together inside one pass (marker 001)' % runner_seen['peak_total'])
    return case


def case_key_guard():
    """H8 guard widening: a claimed marker never skips the per-key slot, and degraded or genuine work still waits for it."""
    case = Case('H8 key guard', 'an unverified FM_CPU_PASS_HELD, or an isolation proof that holds no pass, still waits for a held key slot')
    world = World('key-guard')
    only_one = dict(FM_TEST_KEY_SLOTS='1')
    for mode, claim in (('gate', '3'), ('run', '3'), ('gate-padded', '003')):
        ready = world.folder / (mode + '.ready')
        holder = world.launch(mode + '-holder', [pyshim, tool('fm-duration.py'), 'gate', 'test.claim.' + mode, '--', 'bash', '-c', 'touch "$1"; sleep 4', '_', str(ready)], extra=only_one)
        for _ in range(300):
            if ready.exists():
                break
            time.sleep(0.05)
        marker = world.folder / (mode + '.ran')
        action = 'run' if mode == 'run' else 'gate'
        waiter = world.launch(mode + '-waiter', [pyshim, tool('fm-duration.py'), action, 'test.claim.' + mode, '--', 'touch', str(marker)],
                              extra=dict(only_one, FM_CPU_PASS_HELD=claim))
        holder.wait(timeout=60)
        ended = time.time()
        wait_all([waiter])
        ran = marker.stat().st_mtime if marker.exists() else None
        case.measure(**{mode + '_waiter_ran_after_holder_end_s': None if ran is None else round(ran - ended, 2)})
        case.check(ran is not None and ran >= ended - 0.05, '%s: a claimed FM_CPU_PASS_HELD=%s ran %.2f s before the key slot holder ended' % (mode, claim, ended - (ran or 0)))
    # An isolation proof that holds no pass (pool unusable) or a real one: a candidate's nested gate waits for the held key.
    blocker = world.folder / 'not-a-directory'
    blocker.write_text('x')
    for mode, extra in (('degraded-proof', dict(FM_CPU_POOL_DIR=str(blocker))), ('genuine-proof', {})):
        probe = world.folder / (mode + '-probe')
        probe.mkdir()
        body = ('printf "%s\\n" "${FM_CPU_PASS_HELD-unset}" >"$FM_CONC_PROBE/marker"\n'
                '"$FM_CONC_SHIM" "$FM_CONC_DURATION" gate test.proofkey.' + mode + ' -- touch "$FM_CONC_PROBE/ran"\n')
        family = proof_family_repo(world, ['fm-fam-%d.test.sh' % index for index in range(2)], body=body, folder=mode + '-repo')
        ready = world.folder / (mode + '.ready')
        holder = world.launch(mode + '-holder', [pyshim, tool('fm-duration.py'), 'gate', 'test.proofkey.' + mode, '--', 'bash', '-c', 'touch "$1"; sleep 4', '_', str(ready)], extra=only_one)
        for _ in range(300):
            if ready.exists():
                break
            time.sleep(0.05)
        proof = world.launch(mode, ['bash', str(family / 'bin' / 'fm-test-isolation-proof.sh'), '--pool', 'fam', '--jobs', '2'],
                             extra=dict(only_one, **extra, FM_CONC_PROBE=str(probe), FM_CONC_SHIM=pyshim, FM_CONC_DURATION=tool('fm-duration.py')))
        holder.wait(timeout=60)
        ended = time.time()
        code = wait_all([proof], timeout=120)
        ran = (probe / 'ran').stat().st_mtime if (probe / 'ran').exists() else None
        seen_marker = (probe / 'marker').read_text().strip() if (probe / 'marker').exists() else None
        case.measure(**{mode + '_candidate_marker': seen_marker, mode + '_ran_after_holder_end_s': None if ran is None else round(ran - ended, 2)})
        case.check(code == [0], '%s: the proof failed: %s' % (mode, world.text(mode)[-300:]))
        case.check(ran is not None and ran >= ended - 0.05, '%s: a candidate gate ran %.2f s before the key slot holder ended' % (mode, ended - (ran or 0)))
        case.check(seen_marker == ('0' if mode == 'degraded-proof' else '1'),
                   '%s: the candidate saw FM_CPU_PASS_HELD=%s, but the proof holds %s' % (mode, seen_marker, 'no pass' if mode == 'degraded-proof' else 'one pass per worker'))
    return case


def case_cross_key():
    """H4/H5: two gates that each hold one key and nest the other finish without any timeout, in every pass mode."""
    case = Case('H4/H5 cross-key', 'gate A nests gate B while gate B nests gate A, one slot per key: neither waits for the other forever')
    blocker_world = World('cross-blocker')
    blocker = blocker_world.folder / 'not-a-directory'
    blocker.write_text('x')
    script = 'touch "$1"; while [ ! -e "$2" ]; do sleep 0.05; done; exec "$3" "$4" gate "$5" -- touch "$6"'
    for mode, wrap, extra in (('no-pass-marker', [], {}), ('degraded-marker-0', ['bash', tool('fm-cpu-pass.sh'), 'run', '--'], dict(FM_CPU_POOL_DIR=str(blocker))),
                              ('genuine-marker-1', ['bash', tool('fm-cpu-pass.sh'), 'run', '--'], {})):
        world = World('cross-' + mode)
        env = dict(FM_TEST_KEY_SLOTS='1', **extra)
        a_ready, b_ready, a_done, b_done = (world.folder / name for name in ('a.ready', 'b.ready', 'a.done', 'b.done'))
        gate_a = world.launch('a', wrap + [pyshim, tool('fm-duration.py'), 'gate', 'test.cross.a', '--', 'bash', '-c', script, '_',
                                           str(a_ready), str(b_ready), pyshim, tool('fm-duration.py'), 'test.cross.b', str(a_done)], extra=env)
        gate_b = world.launch('b', wrap + [pyshim, tool('fm-duration.py'), 'gate', 'test.cross.b', '--', 'bash', '-c', script, '_',
                                           str(b_ready), str(a_ready), pyshim, tool('fm-duration.py'), 'test.cross.a', str(b_done)], extra=env)
        began = time.monotonic()
        codes = wait_all([gate_a, gate_b], timeout=90)
        case.measure(**{mode + '_exit_codes': codes, mode + '_seconds': round(time.monotonic() - began, 1)})
        case.check(codes == [0, 0] and a_done.exists() and b_done.exists(),
                   '%s: the two gates did not both finish: %s %s %s' % (mode, codes, world.text('a')[-200:], world.text('b')[-200:]))
    return case


def case_malformed():
    """H3 d: a malformed FM_CPU_PASS_HELD is refused by every participant."""
    case = Case('H3d', 'a malformed FM_CPU_PASS_HELD fails the participant that finds it')
    world = World('malformed')
    scripts = runner_repo(world, ['a.test.sh'], 0.1)
    rows = {
        'fm-cpu-pass.sh run': ['bash', tool('fm-cpu-pass.sh'), 'run', '--', 'true'],
        'fm-test-run.sh': ['bash', str(scripts / 'bin' / 'fm-test-run.sh'), 'tests/a.test.sh'],
        'fm-duration.py gate': [pyshim, tool('fm-duration.py'), 'gate', 'test.malformed', '--', 'true'],
        'fm-duration.py run': [pyshim, tool('fm-duration.py'), 'run', 'test.malformed', '--', 'true'],
        'fm-lint.sh': ['bash', tool('fm-lint.sh'), '--list-files'],
        'fm-test-run.sh --check-coverage': ['bash', tool('fm-test-run.sh'), '--check-coverage'],
    }
    codes = {}
    for name, command in rows.items():
        for value in ('many', ''):
            run = subprocess.run(command, env=dict(world.env, FM_CPU_PASS_HELD=value), capture_output=True, text=True, timeout=120, cwd=repo)
            codes['%s [%s]' % (name, value or 'empty')] = run.returncode
            case.check(run.returncode == 125 and 'FM_CPU_PASS_HELD' in run.stderr + run.stdout,
                       '%s with FM_CPU_PASS_HELD=%r exited %d: %s' % (name, value, run.returncode, (run.stderr + run.stdout)[-200:]))
    case.measure(exit_codes=codes)
    return case


def case_brief_route():
    """H2/H3: different suites started the way the generated worker brief starts them share the pool."""
    case = Case('H2/H3 brief route', '3 x pool size different suites started as fm-duration.py run test.<suite> -- <command>, pool size %d' % N)
    world = World('brief-route')
    count = 3 * N
    world.sample_start()
    jobs = [world.launch('suite%d' % i, [pyshim, tool('fm-duration.py'), 'run', 'test.suite%d' % i, '--'] + world.work('suite%d' % i, 0.4))
            for i in range(count)]
    codes = wait_all(jobs)
    seen = world.sample_stop()
    case.measure(requests=count, pool_size=N, sampled_max_workers_total=seen['peak_total'], sampled_max_passes_held=seen['peak_held'],
                 holder_labels=seen['labels'])
    case.check(codes == [0] * count, 'a request failed: %s' % codes)
    case.check(seen['peak_total'] <= N, 'different suites ran %d workers together on a pool of %d' % (seen['peak_total'], N))
    case.check(any(label.startswith('fm-duration run test.suite') for label in seen['labels']),
               'the limiter holder list never named fm-duration run: %s' % seen['labels'])
    return case


def case_runner_holder():
    """H2: bin/fm-test-run.sh, unnested, shows up in the holder list while its script runs."""
    case = Case('H2 runner', 'an unnested fm-test-run.sh script takes a pass named in the holder list')
    world = World('runner-holder')
    names = isolated_scripts(2)
    path = runner_repo(world, names, 1.2)
    world.sample_start()
    run = world.launch('runner', ['bash', str(path / 'bin' / 'fm-test-run.sh'), '--jobs', '2'] + ['tests/' + name for name in names],
                       extra=dict(FM_CONC_GROUP='runner'))
    codes = wait_all([run])
    seen = world.sample_stop()
    case.measure(sampled_max_workers_total=seen['peak_total'], sampled_max_passes_held=seen['peak_held'], holder_labels=seen['labels'])
    case.check(codes == [0], 'runner failed: %s' % world.text('runner'))
    case.check(any(label.startswith('fm-test-run tests/') for label in seen['labels']), 'holder list never named fm-test-run: %s' % seen['labels'])
    slot_dirs = sorted(path_.name for path_ in world.slots.iterdir())
    case.measure(per_key_slot_directories_created=len(slot_dirs))
    case.check(len(slot_dirs) == len(names), 'the runner did not take its passes through the joint gate --cpu-pass route (per-key slot directories: %s)' % slot_dirs)
    return case


def case_lint():
    """H2: cold ShellCheck roots of two lint runs share the pool, and the holder list names fm-lint."""
    case = Case('H2 lint', 'two lint runs (--jobs 2) of 4 cold roots each, ShellCheck stub is a busy loop, pool size 2')
    world = World('lint', cores=2)
    required = subprocess.run(['bash', tool('fm-lint.sh'), '--required-version'], capture_output=True, text=True, check=True).stdout.strip()
    fakebin = world.folder / 'fakebin'
    fakebin.mkdir()
    (fakebin / 'shellcheck').write_text('#!/bin/sh\nif [ "$1" = "--version" ]; then printf "ShellCheck\\nversion: %s\\n" "' + required + '"; exit 0; fi\n'
                                        'exec "$FM_CONC_PYTHON" "$FM_CONC_WORKER" "$FM_CONC_ALIVE" lint 0.5\n')
    (fakebin / 'shellcheck').chmod(0o755)
    roots = []
    for run in range(2):
        for index in range(4):
            script = world.folder / ('root%d-%d.sh' % (run, index))
            script.write_text('#!/usr/bin/env bash\nexit 0\n')
            roots.append(script)
    extra = dict(PATH=str(fakebin) + os.pathsep + world.env['PATH'], FM_LINT_CACHE_DIR='off', FM_LINT_SLOT_DIR='off', FM_LINT_JOBS='2')
    world.sample_start()
    runs = [world.launch('lint%d' % i, ['bash', tool('fm-lint.sh'), '--jobs', '2', '--telemetry', str(world.folder / ('t%d.tsv' % i))]
                         + [str(path) for path in roots[i * 4:(i + 1) * 4]], extra=extra) for i in range(2)]
    codes = wait_all(runs)
    seen = world.sample_stop()
    case.measure(lint_runs=2, jobs_each=2, pool_size=2, sampled_max_workers_total=seen['peak_total'],
                 sampled_max_passes_held=seen['peak_held'], holder_labels=seen['labels'])
    case.check(codes == [0, 0], 'a lint run failed: %s %s' % (codes, [world.text('lint%d' % i) + world.text('lint%d' % i, 'out') for i in range(2)]))
    case.check(seen['peak_total'] <= 2, 'cold ShellChecks ran %d together on a pool of 2' % seen['peak_total'])
    case.check(any(label.startswith('fm-lint ') for label in seen['labels']), 'holder list never named fm-lint: %s' % seen['labels'])
    # A lint run inside a pass takes none and runs at most that many ShellChecks.
    inner = World('lint-nested', cores=2)
    (inner.folder / 'fakebin').mkdir()
    shutil.copy(fakebin / 'shellcheck', inner.folder / 'fakebin' / 'shellcheck')
    inner.sample_start()
    nested = inner.launch('nested', ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', '1', '--', 'bash', tool('fm-lint.sh'), '--jobs', '2'] + [str(p) for p in roots[:4]],
                          extra=dict(extra, PATH=str(inner.folder / 'fakebin') + os.pathsep + inner.env['PATH']))
    nested_code = wait_all([nested])
    nested_seen = inner.sample_stop()
    case.measure(nested_lint_inside_one_pass_max_workers=nested_seen['peak_total'])
    case.check(nested_code == [0] and nested_seen['peak_total'] <= 1, 'a lint run inside one pass ran %d ShellChecks together: %s' % (nested_seen['peak_total'], inner.text('nested')))
    case.check('reducing --jobs 2 to inherited FM_CPU_PASS_HELD=1' in inner.text('nested'), 'lint did not say it reduced its jobs')
    return case


def proof_family_repo(world, scripts, body=None, folder='family-repo'):
    """A fixture repository whose stub runner names one concurrent-safe family of SCRIPTS, jobs max 4.

    Each candidate runs BODY when given, else it checks it holds one pass and runs one synthetic worker."""
    path = world.folder / folder
    (path / 'bin').mkdir(parents=True)
    (path / 'tests').mkdir()
    for name in ('fm-test-isolation-proof.sh', 'fm-cpu-pass.sh', 'fm-cpu-pass.py'):
        shutil.copy(repo / 'bin' / name, path / 'bin' / name)
    (path / 'bin' / 'fm-test-run.sh').write_text('#!/usr/bin/env bash\n'
                                                 'case "$1:${2:-}:${3:-}" in\n'
                                                 '  --list-scheduled:--family:fam) printf "tests/%s\\n" ' + ' '.join(scripts) + ' ;;\n'
                                                 '  --list-concurrent-safe-families::) echo fam ;;\n'
                                                 '  --concurrent-safe-family-jobs-max:fam:) echo 4 ;;\n'
                                                 '  *) exit 2 ;;\n'
                                                 'esac\n')
    (path / 'bin' / 'fm-test-run.sh').chmod(0o755)
    for name in scripts:
        (path / 'tests' / name).write_text('#!/usr/bin/env bash\n' + (body if body is not None else
                                           '[ "$FM_CPU_PASS_HELD" = 1 ] || exit 3\n'
                                           'exec "$FM_CONC_PYTHON" "$FM_CONC_WORKER" "$FM_CONC_ALIVE" proof 0.2\n'))
    return path


def proof_markers(text):
    return [line.split()[0] + ' ' + next(word for word in line.split() if word.startswith('concurrency='))
            for line in text.splitlines() if line.startswith(('FM_ISOLATION_BEGIN ', 'FM_ISOLATION_SUMMARY '))]


def case_isolation_proof():
    """H2: the isolation proof holds min(--jobs, pool size) passes and records only the concurrency it ran."""
    case = Case('H2 proof', 'bin/fm-test-isolation-proof.sh --jobs 4 over its candidate set, pool size 2')
    world = World('proof', cores=2)
    names = isolated_scripts(None)
    path = runner_repo(world, names, 0.2)
    shutil.copy(repo / 'bin' / 'fm-test-isolation-proof.sh', path / 'bin' / 'fm-test-isolation-proof.sh')
    world.sample_start()
    run = world.launch('proof', ['bash', str(path / 'bin' / 'fm-test-isolation-proof.sh'), '--jobs', '4'], extra=dict(FM_CONC_GROUP='proof'))
    codes = wait_all([run], timeout=300)
    seen = world.sample_stop()
    case.measure(proof_jobs_requested=4, pool_size=2, candidates=len(names), sampled_max_workers_total=seen['peak_total'],
                 sampled_max_passes_held=seen['peak_held'], holder_labels=seen['labels'][:2])
    case.check(codes == [0], 'the proof failed: %s %s' % (codes, world.text('proof')[-300:]))
    case.check(seen['peak_total'] <= 2, 'the proof ran %d workers together on a pool of 2' % seen['peak_total'])
    case.check(any(label.startswith('fm-test-isolation-proof ') for label in seen['labels']), 'holder list never named the proof: %s' % seen['labels'][:3])
    case.check(proof_markers(world.text('proof', 'out')) == ['FM_ISOLATION_BEGIN concurrency=2', 'FM_ISOLATION_SUMMARY concurrency=2'],
               'the proof did not record the concurrency it ran: %s' % proof_markers(world.text('proof', 'out')))
    # A family proof enables runner jobs only when it ran the --jobs it was asked for.
    family = proof_family_repo(world, ['fm-fam-%d.test.sh' % index for index in range(4)])
    for jobs, enabled in (('4', False), ('2', True)):
        label = 'family%s' % jobs
        artifact = world.folder / (label + '.json')
        code = wait_all([world.launch(label, ['bash', str(family / 'bin' / 'fm-test-isolation-proof.sh'), '--pool', 'fam',
                                              '--jobs', jobs, '--json', str(artifact)])])
        recorded = json.loads(artifact.read_text()) if artifact.exists() else {}
        case.measure(**{'family_jobs_%s_markers' % jobs: proof_markers(world.text(label, 'out')),
                        'family_jobs_%s_jobs_enabled' % jobs: recorded.get('fm_test_run_jobs_enabled')})
        case.check(code == [0], 'family proof --jobs %s failed: %s %s' % (jobs, code, world.text(label)[-300:]))
        case.check(proof_markers(world.text(label, 'out')) == ['FM_ISOLATION_BEGIN concurrency=2', 'FM_ISOLATION_SUMMARY concurrency=2'],
                   'family proof --jobs %s did not record concurrency=2: %s' % (jobs, world.text(label, 'out')[-300:]))
        case.check(recorded.get('concurrency') == 2 and recorded.get('fm_test_run_jobs_enabled') is enabled,
                   'family proof --jobs %s on a pool of 2 recorded %s' % (jobs, recorded))
    return case


# --------------------------------------------------------------------------------------
FAKE_CLOCK = '''
import importlib.util, os, sys, types, fcntl
spec = importlib.util.spec_from_file_location('duration', sys.argv[1])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
directory = d.slot_directory('test.fake')
holder = os.open(directory / 'slot-0.lock', os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
clock, sleeps = [0.0], [0]
def fake_sleep(seconds):
    sleeps[0] += 1
    clock[0] += 600.0
    if sleeps[0] == 60:
        os.close(holder)
d.time = types.SimpleNamespace(monotonic=lambda: clock[0], sleep=fake_sleep, time=__import__('time').time)
fd = d.acquire_slot('test.fake', 2)
print('admitted=%s sleeps=%d fake_hours=%.1f' % (fd is not None, sleeps[0], clock[0] / 3600))
'''


def case_waiting():
    """H4: waiting is by capacity, never by elapsed time; a broken limiter does not stop work."""
    case = Case('H4', 'a waiter starts when a holder ends, not when time passes; an unusable pool runs the command and says so')
    world = World('waiting')
    only_one = dict(FM_TEST_KEY_SLOTS='1')
    # (a) The wait variable set to one second, the holder running for six: the waiter starts at release.
    ready = world.folder / 'holder.ready'
    holder = world.launch('holder', [pyshim, tool('fm-duration.py'), 'gate', 'test.waiting', '--', 'bash', '-c', 'touch "$1"; sleep 6', '_', str(ready)], extra=only_one)
    for _ in range(300):
        if ready.exists():
            break
        time.sleep(0.05)
    waiter_started = time.time()
    marker = world.folder / 'waiter.ran'
    waiter = world.launch('waiter', [pyshim, tool('fm-duration.py'), 'gate', 'test.waiting', '--', 'touch', str(marker)],
                          extra=dict(only_one, FM_TEST_SLOT_WAIT_SECONDS='1'))
    holder.wait(timeout=60)
    holder_ended = time.time()
    wait_all([waiter])
    ran_at = marker.stat().st_mtime if marker.exists() else None
    case.measure(wait_variable_seconds=1, holder_seconds=6, waiter_ran_after_start_s=None if ran_at is None else round(ran_at - waiter_started, 2),
                 waiter_ran_after_holder_end_s=None if ran_at is None else round(ran_at - holder_ended, 2))
    case.check(ran_at is not None and ran_at >= holder_ended - 0.05, 'the waiter was admitted %.2f s before its holder ended' % ((holder_ended - (ran_at or 0))))
    # (b) The default setting, with a faked clock: ten hours pass and the waiter is still waiting for the holder.
    clock = subprocess.run([python, '-c', FAKE_CLOCK, tool('fm-duration.py')], env=dict(world.env, FM_TEST_KEY_SLOTS='1', FM_TEST_SLOT_DIR=str(world.folder / 'clock-slots')),
                           capture_output=True, text=True, timeout=60)
    case.measure(fake_clock_default_setting=clock.stdout.strip() or clock.stderr.strip()[-200:])
    case.check('admitted=True' in clock.stdout and 'sleeps=60' in clock.stdout and 'fake_hours=10.0' in clock.stdout,
               'a waiter was admitted by elapsed time under the default setting: %s' % (clock.stdout + clock.stderr)[-300:])
    # (c) An unusable pool directory: the command runs, with one notice, through each pool participant.
    blocker = world.folder / 'not-a-directory'
    blocker.write_text('x')
    bad = dict(FM_CPU_POOL_DIR=str(blocker))
    runs = {
        'fm-cpu-pass.sh run': ['bash', tool('fm-cpu-pass.sh'), 'run', '--', 'bash', '-c', 'echo held=$FM_CPU_PASS_HELD'],
        'fm-duration.py run': [pyshim, tool('fm-duration.py'), 'run', 'test.unusable', '--', 'bash', '-c', 'echo held=$FM_CPU_PASS_HELD'],
        'fm-duration.py gate --cpu-pass': [pyshim, tool('fm-duration.py'), 'gate', '--cpu-pass', 'unusable-gate', 'test.unusable', '--', 'bash', '-c', 'echo held=$FM_CPU_PASS_HELD'],
    }
    notices = {}
    for name, command in runs.items():
        run = subprocess.run(command, env=dict(world.env, **bad), capture_output=True, text=True, timeout=60)
        notices[name] = (run.returncode, run.stdout.strip(), (run.stderr + run.stdout).count('without a CPU pass'))
        case.check(run.returncode == 0 and 'held=0' in run.stdout and (run.stderr + run.stdout).count('without a CPU pass') == 1,
                   '%s with an unusable pool: rc=%d out=%r notices=%d' % (name, run.returncode, run.stdout.strip(), (run.stderr + run.stdout).count('without a CPU pass')))
    case.measure(unusable_pool=notices)
    # (d) The off switch keeps its meaning: it turns the per-key slots off, and the pool (here of 4 passes, so three copies fit)
    # still bounds the workers; with one slot the same three copies take turns.
    off_world = World('waiting-off', cores=4)
    off_world.sample_start()
    copies = [off_world.launch('off%d' % i, [pyshim, tool('fm-duration.py'), 'gate', 'test.off', '--'] + off_world.work('off', 1.0), extra=dict(FM_TEST_KEY_SLOTS='0')) for i in range(3)]
    wait_all(copies)
    off_seen = off_world.sample_stop()
    case.measure(off_switch_copies_alive_together=off_seen['peak_group'].get('off'))
    case.check(off_seen['peak_group'].get('off') == 3, 'FM_TEST_KEY_SLOTS=0 must leave the key ungated: %s' % off_seen)
    on_world = World('waiting-on', cores=4)
    on_world.sample_start()
    taking_turns = [on_world.launch('on%d' % i, [pyshim, tool('fm-duration.py'), 'gate', 'test.on', '--'] + on_world.work('on', 0.6), extra=dict(FM_TEST_KEY_SLOTS='1')) for i in range(3)]
    wait_all(taking_turns)
    on_seen = on_world.sample_stop()
    case.measure(one_slot_copies_alive_together=on_seen['peak_group'].get('on'))
    case.check(on_seen['peak_group'].get('on') == 1, 'one slot must keep three copies of the key to one at a time (the control for the off switch): %s' % on_seen)
    # (e) A pass holder never waits behind a slot whose holder waits for the pass: no timeout is needed to break the cycle.
    cycle = World('waiting-cycle', cores=1)
    flag = cycle.folder / 'go'
    done = cycle.folder / 'nested.done'
    holder_pass = cycle.launch('holder', ['bash', tool('fm-cpu-pass.sh'), 'run', '--label', 'pass-holder', '--', 'bash', '-c',
                                          'while [ ! -e "$1" ]; do sleep 0.05; done; exec "$2" "$3" gate test.cycle -- touch "$4"', '_',
                                          str(flag), pyshim, tool('fm-duration.py'), str(done)], extra=dict(only_one, FM_TEST_SLOT_WAIT_SECONDS='30'))
    for _ in range(200):
        if cycle.status_labels().count('pass-holder'):
            break
        time.sleep(0.05)
    queued = cycle.launch('queued', [pyshim, tool('fm-duration.py'), 'run', 'test.cycle', '--', 'true'], extra=dict(only_one, FM_TEST_SLOT_WAIT_SECONDS='30'))
    for _ in range(200):
        if any(path.name.startswith('slot-') and path.stat().st_size for path in (cycle.slots.glob('*/slot-*.lock'))):
            break
        time.sleep(0.05)
    time.sleep(0.5)
    flag.touch()
    started = time.monotonic()
    codes = wait_all([holder_pass, queued], timeout=90)
    case.measure(slot_pass_cycle_exit_codes=codes, slot_pass_cycle_seconds=round(time.monotonic() - started, 1))
    case.check(codes == [0, 0] and done.exists(), 'a pass holder waited behind a slot whose holder waits for the pass: %s %s' % (codes, cycle.text('holder')))
    case.check('waiting' not in cycle.text('holder'), 'the pass holder queued for a slot: %s' % cycle.text('holder'))
    return case


@ci_only
def case_drain():
    """H5: a burst three or more times the pool drains by itself; a killed holder or waiter leaves nothing stuck."""
    case = Case('H5', 'burst of 3 x pool size + 2 one-pass requests drains; SIGKILLed holder and waiters free the queue')
    world = World('drain')
    burst = 3 * N + 2
    world.sample_start()
    order = []
    jobs = []
    for i in range(burst):
        jobs.append(world.launch('q%02d' % i, ['bash', tool('fm-cpu-pass.sh'), 'run', '--label', 'q%02d' % i, '--'] + world.work('q%02d' % i, 0.3)))
        order.append('q%02d' % i)
        time.sleep(0.01)
    codes = wait_all(jobs)
    seen = world.sample_stop()
    started = [group for group, _, _ in sorted(starts(world), key=lambda row: row[2])]
    sampling_valid(case, seen, 'drain')
    case.measure(requests=burst, pool_size=N, sampled_max_workers_total=seen['peak_total'], sampled_max_passes_held=seen['peak_held'],
                 arrival_order=' '.join(order), start_order=' '.join(started), completed=sum(1 for code in codes if code == 0))
    case.check(codes == [0] * burst, 'a burst request did not complete: %s' % codes)
    case.check(seen['peak_total'] <= N, 'burst ran %d workers together on a pool of %d' % (seen['peak_total'], N))
    case.check(sorted(started) == sorted(order), 'some burst request never started: %s' % started)
    # A holder killed with SIGKILL frees its pass at once and the next waiter starts.
    kill_world = World('drain-kill', cores=2)
    held = [kill_world.launch('hold%d' % i, ['bash', tool('fm-cpu-pass.sh'), 'run', '--label', 'hold%d' % i, '--'] + kill_world.work('hold%d' % i, 30)) for i in range(2)]
    for _ in range(300):
        if len(starts(kill_world)) == 2:
            break
        time.sleep(0.05)
    waiting = kill_world.launch('waiting', ['bash', tool('fm-cpu-pass.sh'), 'run', '--label', 'waiting', '--'] + kill_world.work('waiting', 0.2))
    time.sleep(0.6)
    case.check(waiting.poll() is None and not any(group == 'waiting' for group, _, _ in starts(kill_world)), 'the waiter ran while both passes were held')
    killed_at = time.time()
    kill_group(held[0])
    wait_all([waiting], timeout=30)
    latency = None
    for group, _, stamp in starts(kill_world):
        if group == 'waiting':
            latency = stamp - killed_at
    case.measure(sigkill_holder_to_next_start_s=None if latency is None else round(latency, 2))
    case.check(latency is not None and latency < 5, 'the next waiter did not start promptly after the holder was killed: %s' % latency)
    # A collector killed while it holds the turnstile and one slot does not block the request behind it.
    collector = kill_world.launch('collector', ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', '2', '--label', 'collector', '--', 'true'])
    time.sleep(0.5)
    behind = kill_world.launch('behind', ['bash', tool('fm-cpu-pass.sh'), 'run', '--label', 'behind', '--'] + kill_world.work('behind', 0.2))
    time.sleep(0.5)
    case.check(behind.poll() is None, 'the request behind a collector ran before the collector was killed')
    kill_group(collector)
    kill_group(held[1])
    behind_code = wait_all([behind], timeout=30)
    case.measure(behind_killed_collector_exit=behind_code)
    case.check(behind_code == [0], 'the request behind a killed collector never finished: %s' % kill_world.text('behind'))
    # Nothing is left: no pass held, no waiter entry, and every pass can be collected at once.
    status = subprocess.run(['bash', tool('fm-cpu-pass.sh'), 'status', '--json'], env=kill_world.env, capture_output=True, text=True, timeout=30)
    final = json.loads(status.stdout)
    leftovers = sorted(path.name for path in kill_world.pool.glob('pipeline-waiter-*'))
    everything = subprocess.run(['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', '2', '--', 'true'], env=kill_world.env, capture_output=True, text=True, timeout=30)
    case.measure(final_status='held=%d free=%d size=%d' % (final['held'], final['free'], final['size']), final_queue_entries=leftovers,
                 all_passes_collectable_at_once=everything.returncode == 0)
    case.check(final['held'] == 0 and not leftovers and everything.returncode == 0, 'the pool was not empty at the end: %s %s' % (final, leftovers))
    return case


def facts(folder, available=40 * GIB, total=128 * GIB):
    """Native memory facts at the fm-mem-guard fixture boundary, so a light start reads no real host state."""
    fixture = folder / 'native'
    fixture.mkdir(exist_ok=True)
    (fixture / 'sysctl').write_text('%d\n%d\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' % (total, 1))
    (fixture / 'vm_stat').write_text(
        'Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'
        'Pages free: 1000.\nPages speculative: 100.\n'
        'Anonymous pages: 1048576.\nFile-backed pages: %d.\n'
        'Pages purgeable: 100.\nPages occupied by compressor: 32768.\n' % (available // 16384 - 1100))
    (fixture / 'processes.json').write_text(json.dumps([dict(pid=101, ppid=1, comm='daemon', started='s101', rss_bytes=GIB, fleet=False, run=None)]))


def case_soak():
    """H7 a: lanes repeatedly submit heavy, brief-route and light requests while pass-less burners keep the sandbox busy."""
    import sqlite3
    case = Case('H7a', 'sandbox soak: %d lanes x %d rounds, pool size %d, %d pass-less burners, forced load 500' % (LANES, ROUNDS, N, BURNERS))
    world = World('soak')
    p = N // 2
    names = isolated_scripts(4)
    path = runner_repo(world, names, WORK)
    database = world.folder / 'state.sqlite'
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER, repo_id TEXT)')
    (world.folder / 'load.json').write_text(json.dumps([500, 500, 500]))
    (world.folder / 'procs.json').write_text(json.dumps(dict(count=100, limit=10666, error=False)))
    (world.folder / 'fmhome').mkdir()
    facts(world.folder)
    admission_log = world.folder / 'admission-waits.log'
    world.env.update(CASE_ADMISSION_LOG=str(admission_log), CASE_LOAD=str(world.folder / 'load.json'), CASE_DB=str(database), CASE_PROCS=str(world.folder / 'procs.json'),
                     FM_MEMORY_FIXTURE_DIR=str(world.folder / 'native'), FM_HOME=str(world.folder / 'fmhome'))
    burners = [subprocess.Popen([python, str(burner), str(60 + ROUNDS * 20)]) for _ in range(BURNERS)]
    completed = {'heavy': 0, 'brief': 0, 'light': 0}
    decisions = []
    failures = []
    lock = threading.Lock()

    def run(command, extra=None, label=''):
        done = subprocess.run(command, env=dict(world.env, **(extra or {})), capture_output=True, text=True, timeout=300, start_new_session=True)
        return done

    def lane(index):
        for round_ in range(ROUNDS):
            # One heavy nested request and two brief-route requests of different suites, submitted together.
            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as requests:
                heavy_future = requests.submit(
                    run, ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', str(p), '--label', 'soak-lane%d-r%d' % (index, round_), '--', 'bash', '-c',
                          'cd "$1" && shift && exec bin/fm-test-run.sh --jobs 4 "$@"', '_', str(path)] + ['tests/' + name for name in names],
                    dict(FM_CONC_GROUP='heavy%d' % index))
                brief_futures = [requests.submit(
                    run, [pyshim, tool('fm-duration.py'), 'run', 'test.soak.lane%d.r%d.%d' % (index, round_, which), '--'] + world.work('brief%d' % index, WORK))
                    for which in range(2)]
                heavy, briefs = heavy_future.result(), [future.result() for future in brief_futures]
            light = run(['bash', tool('fm-cpu-pass.sh'), 'pipeline-start', '--', 'true'])
            with lock:
                for kind, done in [('heavy', heavy)] + [('brief', done) for done in briefs] + [('light', light)]:
                    if done.returncode == 0:
                        completed[kind] += 1
                    else:
                        ends = [line[line.find('tests/'):][:60] for line in done.stdout.splitlines() if line.startswith('FM_TEST_END') and 'exit=0' not in line]
                        failures.append((kind, index, round_, done.returncode, done.stderr[-500:], ends[:3]))
                decisions.append(((index, round_), light.stderr.strip()))

    world.sample_start()
    began = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=LANES) as pool:
        for future in [pool.submit(lane, index) for index in range(LANES)]:
            future.result()
    elapsed = time.monotonic() - began
    seen = world.sample_stop()
    for burn in burners:
        burn.kill()
        burn.wait()
    expected = LANES * ROUNDS
    waits = [item for item in decisions if 'waiting' in item[1]]
    admitted = [item for item in decisions if 'pipeline-start admitted: counted=0' in item[1]]
    status = json.loads(subprocess.run(['bash', tool('fm-cpu-pass.sh'), 'status', '--json'], env=world.env, capture_output=True, text=True, timeout=30).stdout)
    leftovers = sorted(path_.name for path_ in world.pool.glob('pipeline-waiter-*'))
    sample_decision = decisions[0][1] if decisions else ''
    # Every sleep of the admission loop is recorded with its cause at the process boundary, so a wait shorter than
    # the first notice (2 s) is seen too. Waiting for another start's registration or for an earlier start in the
    # queue is ordering among starts; any other cause is a wait for capacity, memory, processes or load.
    causes = admission_log.read_text().splitlines() if admission_log.exists() else []
    ordering = [cause for cause in causes if cause == 'another start is registering' or 'behind a higher-priority or earlier start' in cause]
    capacity = [cause for cause in causes if cause not in ordering]
    case.measure(lanes=LANES, rounds_per_lane=ROUNDS, pool_size=N, background_burners_without_passes=BURNERS, forced_load_average=500,
                 window_seconds=round(elapsed, 1), sampled_max_workers_total=seen['peak_total'], sampled_max_passes_held=seen['peak_held'],
                 samples=seen['samples'], sampler_gap_p99_ms=seen['gap_p99_ms'], sampler_gap_max_ms=seen['gap_max_ms'],
                 heavy_completed='%d of %d' % (completed['heavy'], expected), brief_route_completed='%d of %d' % (completed['brief'], 2 * expected),
                 light_starts_completed='%d of %d' % (completed['light'], expected), light_starts_admitted_at_once_counted_0=len(admitted),
                 light_starts_with_a_wait_line=len(waits), admission_sleeps_waiting_for_another_start=len(ordering),
                 admission_sleeps_waiting_for_capacity_or_load=len(capacity), sample_light_start_record=sample_decision,
                 final_status='held=%d free=%d' % (status['held'], status['free']), final_queue_entries=leftovers)
    case.check(not failures, 'requests failed: %s' % failures[:3])
    case.check(seen['peak_total'] <= N, 'the soak ran %d workers together on a pool of %d' % (seen['peak_total'], N))
    case.check(completed == dict(heavy=expected, brief=2 * expected, light=expected), 'not every request completed: %s' % completed)
    sampling_valid(case, seen, 'soak')
    case.check(len(admitted) == expected and not waits, 'a light start waited or was not admitted at once under load 500: %s' % waits[:2])
    case.check(not capacity, 'a light start slept for capacity or load although the count was below the limit: %s' % capacity[:3])
    case.check(status['held'] == 0 and not leftovers, 'the queue was not empty at the end: %s %s' % (status, leftovers))
    case.check(LANES >= 2 * N and ROUNDS >= 5, 'the soak must have at least 2 x N lanes and 5 rounds per lane for H7(a); this run is reduced')
    return case


def case_wait_cause_control():
    """H7 a control: the soak's recorder does name a short wait for capacity, so a soak that finds none is not blind."""
    import sqlite3
    case = Case('H7a control', 'a light start held back by a process pile-up for about a second is recorded with a capacity cause')
    world = World('cause-control')
    database = world.folder / 'state.sqlite'
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER, repo_id TEXT)')
    (world.folder / 'fmhome').mkdir()
    facts(world.folder)
    procs = world.folder / 'procs.json'
    procs.write_text(json.dumps(dict(count=20000, limit=10666, error=False)))
    log = world.folder / 'admission-waits.log'
    world.env.update(CASE_ADMISSION_LOG=str(log), CASE_DB=str(database), CASE_PROCS=str(procs),
                     FM_MEMORY_FIXTURE_DIR=str(world.folder / 'native'), FM_HOME=str(world.folder / 'fmhome'))
    start = world.launch('start', ['bash', tool('fm-cpu-pass.sh'), 'pipeline-start', '--', 'true'])
    time.sleep(1.0)
    procs.write_text(json.dumps(dict(count=100, limit=10666, error=False)))
    code = wait_all([start], timeout=60)
    causes = log.read_text().splitlines() if log.exists() else []
    notices = world.text('start').count('pipeline-start waiting')
    case.measure(exit_code=code, recorded_causes=sorted(set(causes))[:3], sleeps=len(causes), first_notice_lines_printed_on_this_host=notices)
    case.check(code == [0], 'the held-back start never ran: %s' % world.text('start')[-300:])
    case.check(any(cause.startswith('overload:') for cause in causes), 'the recorder did not name the wait for capacity: %s' % causes[:3])
    return case


def case_sampler_control():
    """Controls for the validators the other cases rely on: each one must reject the input it exists to reject."""
    case = Case('validator controls', 'sampling_valid rejects a blind or slow sampler')
    blind = Case('x', 'x')
    sampling_valid(blind, dict(peak_total=0, gap_p99_ms=20, gap_max_ms=30), 'blind')
    slow = Case('x', 'x')
    sampling_valid(slow, dict(peak_total=3, gap_p99_ms=400, gap_max_ms=2500), 'slow')
    cadence = Case('x', 'x')
    sampling_valid(cadence, dict(peak_total=3, gap_p99_ms=80, gap_max_ms=120), 'sparse')
    sound = Case('x', 'x')
    sampling_valid(sound, dict(peak_total=3, gap_p99_ms=31, gap_max_ms=44), 'sound')
    case.measure(blind_sampler_violations=len(blind.violations), slow_sampler_violations=len(slow.violations), sound_sampler_violations=len(sound.violations))
    case.check(len(blind.violations) == 1, 'a sampler that saw no worker was accepted')
    case.check(len(slow.violations) == 1, 'a sampler that skipped for seconds was accepted')
    case.check(len(cadence.violations) == 1, 'a sampler slower than the 50 ms cadence the contract asks for was accepted')
    case.check(not sound.violations, 'a sound sampler was rejected: %s' % sound.violations)
    return case


def case_same_class_order():
    """H5: pipeline starts of one class are admitted in arrival order, and a higher class that arrives later goes first."""
    import sqlite3
    case = Case('H5 start order', 'three same-class starts and one later machinery start wait behind a pile-up, then run in class and arrival order')
    world = World('start-order')
    database = world.folder / 'state.sqlite'
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER, repo_id TEXT)')
    (world.folder / 'fmhome').mkdir()
    facts(world.folder)
    procs = world.folder / 'procs.json'
    procs.write_text(json.dumps(dict(count=20000, limit=10666, error=False)))
    world.env.update(CASE_DB=str(database), CASE_PROCS=str(procs), FM_MEMORY_FIXTURE_DIR=str(world.folder / 'native'), FM_HOME=str(world.folder / 'fmhome'))
    order = world.folder / 'order.log'
    arrivals = (('other-1', 'other'), ('other-2', 'other'), ('other-3', 'other'), ('machinery-4', 'machinery'))
    waiters = []
    for name, priority in arrivals:
        waiters.append(world.launch(name, ['bash', tool('fm-cpu-pass.sh'), 'pipeline-start', '--priority', priority, '--', 'bash', '-c', 'echo "$1" >>"$2"', '_', name, str(order)]))
        time.sleep(0.4)
    time.sleep(1.0)
    case.check(not order.exists(), 'a start ran while the pile-up still held every start back')
    procs.write_text(json.dumps(dict(count=100, limit=10666, error=False)))
    codes = wait_all(waiters, timeout=90)
    ran = order.read_text().split() if order.exists() else []
    case.measure(arrival_order=' '.join(name for name, _ in arrivals), exit_codes=codes, admitted_order=' '.join(ran))
    case.check(codes == [0] * len(arrivals), 'a start never ran: %s' % codes)
    case.check(ran == ['machinery-4', 'other-1', 'other-2', 'other-3'], 'admission did not follow class and then arrival order: %s' % ran)
    return case


def case_nested_other_key():
    """F1: a key requested under another key's slot still waits for an unnested holder of that key; only its own holder's chain is exempt."""
    case = Case('F1 nested key', 'gate test.K under fm-duration.py run test.other waits for an unnested test.K holder; under its own holder it runs at once')
    world = World('nested-other-key')
    only_one = dict(FM_TEST_KEY_SLOTS='1')
    ready = world.folder / 'holder.ready'
    holder = world.launch('holder', [pyshim, tool('fm-duration.py'), 'gate', 'test.K', '--', 'bash', '-c', 'touch "$1"; sleep 4', '_', str(ready)], extra=only_one)
    for _ in range(300):
        if ready.exists():
            break
        time.sleep(0.05)
    marker = world.folder / 'nested.ran'
    probe = world.launch('probe', [pyshim, tool('fm-duration.py'), 'run', 'test.other', '--', pyshim, tool('fm-duration.py'), 'gate', 'test.K', '--', 'touch', str(marker)], extra=only_one)
    holder.wait(timeout=60)
    ended = time.time()
    codes = wait_all([probe], timeout=60)
    ran = marker.stat().st_mtime if marker.exists() else None
    case.measure(probe_exit=codes, nested_ran_after_holder_end_s=None if ran is None else round(ran - ended, 2))
    case.check(codes == [0], 'the nested request never completed: %s' % world.text('probe')[-200:])
    case.check(ran is not None and ran >= ended - 0.05, 'a key requested under another key ran %.2f s before the unnested holder of that key ended' % (ended - (ran or 0)))
    # Control: the same key nested under its own holder takes no second slot and runs at once.
    own = world.folder / 'own.ran'
    began = time.monotonic()
    own_run = world.launch('own', [pyshim, tool('fm-duration.py'), 'gate', 'test.own', '--', pyshim, tool('fm-duration.py'), 'gate', 'test.own', '--', 'touch', str(own)], extra=only_one)
    own_code = wait_all([own_run], timeout=90)
    case.measure(own_ancestry_exit=own_code, own_ancestry_seconds=round(time.monotonic() - began, 1))
    case.check(own_code == [0] and own.exists(), 'a key nested under its own holder did not finish (it must take no second slot)')
    return case


def case_sibling_runners():
    """F2: independent sibling runners that inherit one reservation together run no more workers than the passes held."""
    case = Case('F2 siblings', 'an outer suite under p passes starts several nested fm-test-run.sh at once; workers alive together never exceed p')
    rows = {}
    for label, cores, p, siblings in (('one-pass-two-siblings', 1, 1, 2), ('two-passes-three-siblings', 2, 2, 3)):
        world = World('siblings-' + label, cores=cores)
        names = isolated_scripts(siblings)
        path = runner_repo(world, names, 0.8)
        world.sample_start()
        script = 'cd "$1" || exit 1; shift; for s in "$@"; do bin/fm-test-run.sh --jobs %d "tests/$s" & done; wait' % p
        outer = world.launch('outer', ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', str(p), '--label', 'outer', '--', 'bash', '-c', script, '_', str(path)] + names,
                             extra=dict(FM_CONC_GROUP='outer'))
        codes = wait_all([outer])
        seen = world.sample_stop()
        began = len(starts(world))
        rows[label] = dict(passes=p, sibling_runners=siblings, workers_started=began, sampled_max_workers_total=seen['peak_total'], sampled_max_passes_held=seen['peak_held'])
        sampling_valid(case, seen, label)
        case.check(codes == [0], '%s: the outer suite failed: %s' % (label, world.text('outer')[-300:]))
        case.check(began == siblings, '%s: %d of %d sibling workers started' % (label, began, siblings))
        case.check(seen['peak_total'] <= p, '%s: %d workers alive together under %d pass(es)' % (label, seen['peak_total'], p))
    case.measure(**rows)
    return case


def case_mixed_cycle():
    """F3: a plain gate holder that calls run test.B and a pass holder that calls gate test.A both finish."""
    case = Case('F3 mixed cycle', 'gate test.A (holder) -> run test.B, while a pass holder calls gate test.A, pool of 1')
    world = World('mixed-cycle', cores=1)
    only_one = dict(FM_TEST_KEY_SLOTS='1')
    b_ready, a_done, b_done = (world.folder / name for name in ('b.ready', 'a.done', 'b.done'))
    pass_holder = world.launch('b', ['bash', tool('fm-cpu-pass.sh'), 'run', '--label', 'pass-holder', '--', 'bash', '-c',
                                     'touch "$1"; sleep 2; exec "$2" "$3" gate test.A -- touch "$4"', '_', str(b_ready), pyshim, tool('fm-duration.py'), str(b_done)], extra=only_one)
    for _ in range(300):
        if b_ready.exists():
            break
        time.sleep(0.05)
    plain = world.launch('a', [pyshim, tool('fm-duration.py'), 'gate', 'test.A', '--', pyshim, tool('fm-duration.py'), 'run', 'test.B', '--', 'touch', str(a_done)], extra=only_one)
    began = time.monotonic()
    codes = wait_all([pass_holder, plain], timeout=120)
    case.measure(exit_codes=codes, seconds=round(time.monotonic() - began, 1))
    case.check(codes == [0, 0] and a_done.exists() and b_done.exists(), 'the plain slot holder and the pass holder did not both finish: %s a=%s b=%s' % (codes, world.text('a')[-200:], world.text('b')[-200:]))
    return case


def case_lease_slot_cycle():
    """F3 one level down: a nested gate holder that calls a nested run, and a leaseholder that calls the gate's key, both finish."""
    case = Case('F3 lease cycle', 'under one pass: gate test.A -> fm-cpu-pass.sh run, while a sibling leaseholder calls gate test.A, pool of 1')
    world = World('lease-cycle', cores=1)
    only_one = dict(FM_TEST_KEY_SLOTS='1')
    b_ready, a_done, b_done = (world.folder / name for name in ('b.ready', 'a.done', 'b.done'))
    script = ('cd "$1" || exit 1\n'
              'bash "$2" run -- bash -c \'touch "$1"; sleep 2; exec "$2" "$3" gate test.A -- touch "$4"\' _ "$3" "$4" "$5" "$6" &\n'
              'while [ ! -e "$3" ]; do sleep 0.05; done\n'
              '"$4" "$5" gate test.A -- bash "$2" run -- touch "$8" &\n'
              'wait\n')
    outer = world.launch('outer', ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', '1', '--label', 'outer', '--', 'bash', '-c', script, '_',
                                   str(repo), tool('fm-cpu-pass.sh'), str(b_ready), pyshim, tool('fm-duration.py'), str(b_done), 'unused', str(a_done)], extra=only_one)
    began = time.monotonic()
    codes = wait_all([outer], timeout=120)
    case.measure(exit_codes=codes, seconds=round(time.monotonic() - began, 1))
    case.check(codes == [0] and a_done.exists() and b_done.exists(), 'the nested slot holder and the leaseholder did not both finish: %s %s' % (codes, world.text('outer')[-300:]))
    return case


@ci_only
def case_holder_killed():
    """F6: a pass stays held until its command ends, so killing only the holder frees nothing for a second worker."""
    case = Case('F6 holder kill', 'SIGKILL of only the gate / pass-holder process: a queued request does not start until the worker ends')
    rows = {}
    for label, make in (('gate --cpu-pass', lambda w: [pyshim, tool('fm-duration.py'), 'gate', '--cpu-pass', 'killed-gate', 'test.killed'] + ['--'] + w.work('first', 5)),
                        ('fm-cpu-pass.sh run', lambda w: ['bash', tool('fm-cpu-pass.sh'), 'run', '--label', 'killed-run', '--'] + w.work('first', 5))):
        world = World('holder-killed-' + label.split()[0].replace('.', ''), cores=1)
        world.sample_start()
        first = world.launch('first', make(world), extra=dict(FM_TEST_KEY_SLOTS='1'))
        for _ in range(2400):  # a loaded host starts a worker slowly; its five CPU seconds then take longer than five seconds
            if any(group == 'first' for group, _, _ in starts(world)):
                break
            time.sleep(0.05)
        queued = world.launch('queued', ['bash', tool('fm-cpu-pass.sh'), 'run', '--label', 'queued', '--'] + world.work('queued', 0.3))
        time.sleep(0.6)
        try:
            os.kill(first.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        time.sleep(1.5)
        queued_early = any(group == 'queued' for group, _, _ in starts(world))
        codes = wait_all([queued], timeout=240)
        seen = world.sample_stop()
        queued_start = [stamp for group, _, stamp in starts(world) if group == 'queued']
        first_end = [stamp for group, _, stamp in ends(world) if group == 'first']
        rows[label] = dict(queued_started_before_the_worker_ended=queued_early, sampled_max_workers_total=seen['peak_total'], queued_exit=codes)
        case.check(codes == [0], '%s: the queued request never ran: %s' % (label, world.text('queued')[-200:]))
        case.check(not queued_early and seen['peak_total'] <= 1, '%s: killing only the holder let %d workers run under one pass (queued started early: %s)' % (label, seen['peak_total'], queued_early))
        case.check(queued_start and first_end and queued_start[0] >= first_end[0], '%s: the queued worker started (%s) before the first worker actually ended (%s)' % (label, queued_start[:1], first_end[:1]))
    case.measure(**rows)
    return case


def case_one_candidate_proof():
    """F7: a proof of one candidate records the one worker it ran, not the --jobs it was asked for."""
    case = Case('F7 one candidate', 'bin/fm-test-isolation-proof.sh --pool fam --jobs 2 over a single candidate, pool of 2')
    world = World('one-candidate', cores=2)
    family = proof_family_repo(world, ['fm-fam-0.test.sh'])
    artifact = world.folder / 'proof.json'
    run = world.launch('proof', ['bash', str(family / 'bin' / 'fm-test-isolation-proof.sh'), '--pool', 'fam', '--jobs', '2', '--json', str(artifact)])
    code = wait_all([run])
    recorded = json.loads(artifact.read_text()) if artifact.exists() else {}
    case.measure(markers=proof_markers(world.text('proof', 'out')), recorded_concurrency=recorded.get('concurrency'), jobs_enabled=recorded.get('fm_test_run_jobs_enabled'))
    case.check(code == [0], 'the proof failed: %s' % world.text('proof')[-300:])
    case.check(proof_markers(world.text('proof', 'out')) == ['FM_ISOLATION_BEGIN concurrency=1', 'FM_ISOLATION_SUMMARY concurrency=1'], 'the proof did not record the one worker it ran: %s' % proof_markers(world.text('proof', 'out')))
    case.check(recorded.get('concurrency') == 1 and recorded.get('fm_test_run_jobs_enabled') is False, 'the artifact overstated what ran: %s' % recorded)
    return case


ASYNC_INNER = r"""set -eu
if [ -e "$1/$2.end" ] || [ -e "$1/$3.end" ]; then echo after > "$1/$2.inner"; else echo before > "$1/$2.inner"; fi"""
ASYNC_OUTER = r"""set -eu
d=$1 self=$2 peer=$3 py=$4 dur=$5 mode=$6 inner=$7
: > "$d/$self.ready"
while [ ! -e "$d/$peer.ready" ]; do sleep 0.05; done
if [ "$mode" = async ]; then
  "$py" "$dur" gate "test.$peer" -- /bin/bash -c "$inner" _ "$d" "$self" "$peer" > "$d/$self.child.out" 2> "$d/$self.child.err" &
  sleep 6
  : > "$d/$self.end"
else
  "$py" "$dur" gate "test.$peer" -- /bin/bash -c "$inner" _ "$d" "$self" "$peer" > "$d/$self.child.out" 2> "$d/$self.child.err"
  : > "$d/$self.end"
fi"""


def case_async_cycle():
    """R1: a request registered by a background descendant, while its holder keeps running, is not a wait cycle."""
    case = Case('R1 async cycle', 'two outer gates each start the other key in the background and sleep: no extra copy while either outer runs')
    for label, modes in (('both-async', ('async', 'async')), ('one-sync-one-async', ('sync', 'async'))):
        world = World('async-cycle-' + label, cores=2)
        procs = []
        for (name, peer), mode in zip((('A', 'B'), ('B', 'A')), modes):
            procs.append(world.launch(name, [pyshim, tool('fm-duration.py'), 'gate', 'test.' + name, '--', '/bin/bash', '-c', ASYNC_OUTER, '_',
                                             str(world.folder), name, peer, pyshim, tool('fm-duration.py'), mode, ASYNC_INNER], extra=dict(FM_TEST_KEY_SLOTS='1')))
        codes = wait_all(procs, timeout=120)
        for _ in range(400):
            if all((world.folder / (name + '.inner')).exists() for name in 'AB'):
                break
            time.sleep(0.05)
        inner = {name: (world.folder / (name + '.inner')).read_text().strip() if (world.folder / (name + '.inner')).exists() else 'missing' for name in 'AB'}
        notices = {name: 'beside its limit' in (world.folder / (name + '.child.err')).read_text() if (world.folder / (name + '.child.err')).exists() else False for name in 'AB'}
        case.measure(**{label + '_outer_exit': codes, label + '_inner_started': inner, label + '_cycle_notices': notices})
        case.check(codes == [0, 0], '%s: an outer gate failed: %s' % (label, codes))
        case.check(inner == {'A': 'after', 'B': 'after'}, '%s: a request ran beside its limit while the other outer gate was still running: %s' % (label, inner))
        case.check(not any(notices.values()), '%s: a wait cycle was declared for requests that are not a cycle: %s' % (label, notices))
    return case


def reservation_env(world, tmp, group=None, **more):
    home = world.folder / 'home'
    home.mkdir(exist_ok=True)
    world.env = dict(world.env, HOME=str(home), TMPDIR=str(tmp), FM_TEST_KEY_SLOTS='1', FM_CONC_GROUP=group or 'one', **more)


def case_one_reservation():
    """R2: every nested admit draws on the one real reservation, whatever its key, and never asks for more than it holds."""
    case = Case('R2 one reservation', 'same-key sibling runners, sibling isolation proofs and an oversized gate request under one held pass')
    tmp = root / 'r2-tmp'
    tmp.mkdir(exist_ok=True)
    name = 'fm-arm-pretool-check.test.sh'
    other = 'fm-backend-herdr.test.sh'
    for label, selected, key in (('same-key', [name, name], 'test.tests/' + name), ('different-key-control', [name, other], 'test.other')):
        world = World('r2-siblings-' + label, cores=1)
        sandbox = runner_repo(world, sorted(set(selected)), 1.2)
        reservation_env(world, tmp, 'siblings')
        script = 'cd "$1" || exit 1; bin/fm-test-run.sh --jobs 1 "$2" >"$4/a.log" 2>&1 & bin/fm-test-run.sh --jobs 1 "$3" >"$4/b.log" 2>&1 & wait'
        world.sample_start()
        outer = world.launch('outer', [pyshim, tool('fm-duration.py'), 'gate', '--cpu-pass', 'r2-outer', key, '--', '/bin/bash', '-c', script, '_',
                                       str(sandbox), 'tests/' + selected[0], 'tests/' + selected[1], str(world.folder)])
        codes = wait_all([outer], timeout=180)
        seen = world.sample_stop()
        began = len(starts(world))
        sampling_valid(case, seen, label)
        case.measure(**{label + '_exit': codes, label + '_workers_started': began, label + '_peak_workers': seen['peak_total'], label + '_peak_passes': seen['peak_held']})
        case.check(codes == [0], '%s: the outer gate failed: %s' % (label, world.text('outer')[-300:]))
        case.check(began == 2, '%s: %d of 2 sibling workers started' % (label, began))
        case.check(seen['peak_total'] <= 1, '%s: %d workers alive together under one held pass' % (label, seen['peak_total']))
    world = World('r2-sibling-proofs', cores=1)
    family = proof_family_repo(world, ['fm-fam-0.test.sh'], body='exec "$FM_CONC_PYTHON" "$FM_CONC_WORKER" "$FM_CONC_ALIVE" proofs 1.2\n')
    reservation_env(world, tmp, 'proofs')
    script = 'cd "$1" || exit 1; bin/fm-test-isolation-proof.sh --pool fam --jobs 1 >"$2/a.log" 2>&1 & bin/fm-test-isolation-proof.sh --pool fam --jobs 1 >"$2/b.log" 2>&1 & wait'
    world.sample_start()
    outer = world.launch('outer', ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', '1', '--', '/bin/bash', '-c', script, '_', str(family), str(world.folder)])
    codes = wait_all([outer], timeout=180)
    seen = world.sample_stop()
    began = len(starts(world))
    sampling_valid(case, seen, 'sibling proofs')
    case.measure(proofs_exit=codes, proofs_workers_started=began, proofs_peak_workers=seen['peak_total'], proofs_peak_passes=seen['peak_held'])
    case.check(codes == [0], 'sibling proofs: the outer holder failed: %s' % world.text('outer')[-300:])
    case.check(began == 2, 'sibling proofs: %d of 2 candidate workers started' % began)
    case.check(seen['peak_total'] <= 1, 'sibling proofs: %d candidate workers alive together under one held pass' % seen['peak_total'])
    for requested, expect_ran in (('1', True), ('2', False)):
        world = World('r2-gate-passes-' + requested, cores=1)
        reservation_env(world, tmp)
        marker = world.folder / 'ran'
        boundary = world.launch('boundary', ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', '1', '--', pyshim, tool('fm-duration.py'), 'gate', '--passes', requested,
                                             'test.boundary', '--', '/usr/bin/touch', str(marker)])
        code = wait_all([boundary], timeout=120)
        case.measure(**{'gate_passes_%s_exit' % requested: code, 'gate_passes_%s_command_started' % requested: marker.exists()})
        case.check(code == ([0] if expect_ran else [125]), 'gate --passes %s inside one held pass exited %s: %s' % (requested, code, world.text('boundary')[-200:]))
        case.check(marker.exists() is expect_ran, 'gate --passes %s inside one held pass: command started = %s' % (requested, marker.exists()))
    # Single same-key nesting keeps working: the inner gate leases the one token of the reservation its ancestor holds.
    world = World('r2-single-nesting', cores=1)
    reservation_env(world, tmp)
    marker = world.folder / 'ran'
    nest = world.launch('nest', [pyshim, tool('fm-duration.py'), 'gate', 'test.same', '--', pyshim, tool('fm-duration.py'), 'gate', 'test.same', '--', '/usr/bin/touch', str(marker)])
    code = wait_all([nest], timeout=120)
    case.measure(single_nesting_exit=code)
    case.check(code == [0] and marker.exists(), 'a key nested under its own holder did not finish: %s' % world.text('nest')[-200:])
    return case


def case_jobs_clamp():
    """R3: the proof runs, prints and records no more workers than it has candidates and passes, for a --jobs value of any length."""
    case = Case('R3 jobs clamp', 'bin/fm-test-isolation-proof.sh --jobs of any length over one candidate, and over two candidates inside one held pass')
    tmp = root / 'r3-tmp'
    tmp.mkdir(exist_ok=True)
    for index, jobs in enumerate(('2', '1000000', '0001000000', '99999999999999999999999999')):
        world = World('r3-one-%d' % index, cores=2)
        family = proof_family_repo(world, ['fm-fam-0.test.sh'])
        artifact = world.folder / 'proof.json'
        run = world.launch('proof', ['bash', str(family / 'bin' / 'fm-test-isolation-proof.sh'), '--pool', 'fam', '--jobs', jobs, '--json', str(artifact)])
        code = wait_all([run], timeout=120)
        recorded = json.loads(artifact.read_text()) if artifact.exists() else {}
        markers = proof_markers(world.text('proof', 'out'))
        case.measure(**{'jobs_%d_markers' % index: markers, 'jobs_%d_recorded' % index: recorded.get('concurrency')})
        case.check(code == [0], '--jobs %s over one candidate failed: %s' % (jobs, world.text('proof')[-300:]))
        case.check(markers == ['FM_ISOLATION_BEGIN concurrency=1', 'FM_ISOLATION_SUMMARY concurrency=1'], '--jobs %s: the printed line is not the one worker that ran: %s' % (jobs, markers))
        case.check(recorded.get('concurrency') == 1 and recorded.get('fm_test_run_jobs_enabled') is False, '--jobs %s: the record is not the one worker that ran: %s' % (jobs, recorded))
    world = World('r3-held', cores=2)
    family = proof_family_repo(world, ['fm-fam-0.test.sh', 'fm-fam-1.test.sh'])
    reservation_env(world, tmp)
    artifact = world.folder / 'proof.json'
    world.sample_start()
    outer = world.launch('proof', ['bash', tool('fm-cpu-pass.sh'), 'run', '--passes', '1', '--', 'bash', str(family / 'bin' / 'fm-test-isolation-proof.sh'), '--pool', 'fam',
                                   '--jobs', '1000000', '--json', str(artifact)])
    code = wait_all([outer], timeout=120)
    seen = world.sample_stop()
    recorded = json.loads(artifact.read_text()) if artifact.exists() else {}
    markers = proof_markers(world.text('proof', 'out'))
    sampling_valid(case, seen, 'proof inside one held pass')
    case.measure(held_markers=markers, held_recorded=recorded.get('concurrency'), held_peak_workers=seen['peak_total'])
    case.check(code == [0], 'the proof inside one held pass failed: %s' % world.text('proof')[-300:])
    case.check(markers == ['FM_ISOLATION_BEGIN concurrency=1', 'FM_ISOLATION_SUMMARY concurrency=1'], 'inside one held pass the printed line is not the one worker that ran: %s' % markers)
    case.check(recorded.get('concurrency') == 1, 'inside one held pass the record is not the one worker that ran: %s' % recorded)
    case.check(seen['peak_total'] <= 1, 'inside one held pass %d candidate workers ran together' % seen['peak_total'])
    return case


def case_duration_sample():
    """R5: the test.<script> sample measures execution only: slot wait and pass wait are both left out, FM_TEST_END keeps the pass wait."""
    case = Case('R5 duration sample', 'a script that waited about 4 s for the one pass records a sample near its own time; FM_TEST_END still counts the wait')
    tmp = root / 'r5-tmp'
    tmp.mkdir(exist_ok=True)
    world = World('r5-sample', cores=1)
    name = 'fm-arm-pretool-check.test.sh'
    sandbox = runner_repo(world, [name], 0.2)
    shutil.copy(repo / 'bin' / 'fm-duration-lib.sh', sandbox / 'bin' / 'fm-duration-lib.sh')
    ledger = world.folder / 'durations.jsonl'
    reservation_env(world, tmp, 'duration', FM_DURATION_FILE=str(ledger))
    ready = world.folder / 'holder.ready'
    holder = world.launch('holder', ['bash', tool('fm-cpu-pass.sh'), 'run', '--', 'bash', '-c', ': > "$1"; sleep 4', '_', str(ready)])
    for _ in range(600):
        if ready.exists():
            break
        time.sleep(0.05)
    case.check(ready.exists(), 'the pass holder never started')
    held_from = time.monotonic()
    runner = world.launch('runner', ['bash', '-c', 'cd "$1" && exec bin/fm-test-run.sh --jobs 1 "$2"', '_', str(sandbox), 'tests/' + name])
    codes = wait_all([holder, runner], timeout=180)
    waited_ms = round((time.monotonic() - held_from) * 1000)
    rows = [json.loads(line) for line in ledger.read_text().splitlines()] if ledger.exists() else []
    samples = [row.get('duration_ms') for row in rows if row.get('key') == 'test.tests/' + name]
    ended = [int(word.split('=')[1]) for line in world.text('runner', 'out').splitlines() if line.startswith('FM_TEST_END ') for word in line.split() if word.startswith('duration_ms=')]
    case.measure(exit_codes=codes, ledger_samples_ms=samples, fm_test_end_ms=ended, run_time_ms=waited_ms)
    case.check(codes == [0, 0], 'the holder or the runner failed: %s %s' % (codes, world.text('runner')[-300:]))
    case.check(len(samples) == 1 and len(ended) == 1, 'expected one ledger sample and one FM_TEST_END line: %s %s' % (samples, ended))
    if len(samples) == 1 and len(ended) == 1:
        case.check(ended[0] - samples[0] >= 2000, 'the sample still counts the pass wait: sample %d ms, FM_TEST_END %d ms' % (samples[0], ended[0]))
        case.check(samples[0] < waited_ms - 2000, 'the sample %d ms is not near the script time (the run took %d ms with a 4 s holder)' % (samples[0], waited_ms))
    return case


@ci_only
def case_guard_unavailable():
    """R6a/b: a guard that cannot be started, or token storage that cannot be created, degrades and says so once; the work still runs."""
    case = Case('R6 guard and token faults', 'injected: the guard cannot start / the token directory cannot be created: the command runs without a pass, once-said, and the pass is free')
    blocker = root / 'r6-not-a-directory'
    blocker.write_text('x')
    notice = 'without a CPU pass: cannot'
    for label, extra in (('guard-fork', dict(CASE_GUARD_FAIL='1')), ('token-storage', dict(TMPDIR=str(blocker)))):
        for route, make in (('gate', lambda w, m: [pyshim, tool('fm-duration.py'), 'gate', 'test.r6.' + label, '--', 'bash', '-c', 'printf "%s\\n" "${FM_CPU_PASS_HELD-unset}" > "$1"', '_', str(m)]),
                            ('run', lambda w, m: ['bash', tool('fm-cpu-pass.sh'), 'run', '--', 'bash', '-c', 'printf "%s\\n" "${FM_CPU_PASS_HELD-unset}" > "$1"', '_', str(m)])):
            world = World('r6-%s-%s' % (label, route), cores=1)
            marker = world.folder / 'marker'
            codes = wait_all([world.launch('probe', make(world, marker), extra=extra)], timeout=120)
            text = world.text('probe')
            held = marker.read_text().strip() if marker.exists() else None
            status = subprocess.run(['bash', tool('fm-cpu-pass.sh'), 'status', '--json'], env=world.env, capture_output=True, text=True, timeout=30)
            case.measure(**{'%s_%s_exit' % (label, route): codes, '%s_%s_marker' % (label, route): held})
            case.check(codes == [0], '%s %s: the command did not run to the end: %s' % (label, route, text[-300:]))
            case.check(held == '0', '%s %s: the command saw FM_CPU_PASS_HELD=%s, but it holds no pass' % (label, route, held))
            case.check(text.count(notice) == 1, '%s %s: the degrade notice (%r) was said %d times: %s' % (label, route, notice, text.count(notice), text[-300:]))
            case.check(json.loads(status.stdout or '{}').get('held') == 0, '%s %s: a pass is still held after the command ended: %s' % (label, route, status.stdout[-200:]))
    return case


@ci_only
def case_holder_dies_at_guard_creation():
    """R6a: the holder killed after the command started and before it named the command: the pass stays held until that worker ends."""
    case = Case('R6 holder death at guard creation', 'SIGKILL of the holder between starting the command and naming it to the guard: a queued request starts only after the worker ended')
    rows = {}
    for label, make in (('gate', lambda w: [pyshim, tool('fm-duration.py'), 'gate', '--cpu-pass', 'bind-gate', 'test.bind', '--'] + w.work('first', 3)),
                        ('fm-cpu-pass.sh run', lambda w: ['bash', tool('fm-cpu-pass.sh'), 'run', '--label', 'bind-run', '--'] + w.work('first', 3))):
        world = World('bind-' + label.split()[0].replace('.', ''), cores=1)
        hold = world.folder / 'bind'
        first = world.launch('first', make(world), extra=dict(CASE_BIND_HOLD=str(hold), FM_TEST_KEY_SLOTS='1'))
        for _ in range(2400):
            if (world.folder / 'bind.reached').exists() and any(group == 'first' for group, _, _ in starts(world)):
                break
            time.sleep(0.05)
        queued = world.launch('queued', ['bash', tool('fm-cpu-pass.sh'), 'run', '--label', 'queued', '--'] + world.work('queued', 0.3))
        time.sleep(0.5)
        try:
            os.kill(first.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        codes = wait_all([queued], timeout=240)
        first_end = [stamp for group, _, stamp in ends(world) if group == 'first']
        queued_start = [stamp for group, _, stamp in starts(world) if group == 'queued']
        rows[label] = dict(queued_exit=codes, first_end=first_end[:1], queued_start=queued_start[:1])
        case.check(codes == [0], '%s: the queued request never ran: %s' % (label, world.text('queued')[-200:]))
        case.check(first_end and queued_start and queued_start[0] >= first_end[0], '%s: the queued worker started (%s) before the worker whose holder was killed ended (%s)' % (label, queued_start[:1], first_end[:1]))
    case.measure(**rows)
    return case


def case_unusable_modes():
    """H4: a gate or pool that cannot be used (no POSIX locks, a foreign-owned directory, no python3) still runs the command, once-said."""
    case = Case('H4 unusable modes', 'no POSIX locks, a foreign-owned slot and pool directory, and no python3: the command runs without a slot or pass and the cause is named')
    show = 'printf "%s\\n" "${FM_CPU_PASS_HELD-unset}" > "$1"'
    for label, extra, notices in (('no-flock', dict(CASE_NO_FCNTL='1'), ['POSIX file locks', 'without a CPU pass']),
                                  ('foreign-owner', dict(CASE_FOREIGN_OWNER='1'), ['without a slot', 'without a CPU pass', 'owned by another user'])):
        world = World('unusable-' + label, cores=1)
        marker = world.folder / 'marker'
        codes = wait_all([world.launch('probe', [pyshim, tool('fm-duration.py'), 'gate', 'test.unusable.' + label, '--', 'bash', '-c', show, '_', str(marker)], extra=extra)], timeout=120)
        text = world.text('probe')
        held = marker.read_text().strip() if marker.exists() else None
        case.measure(**{label + '_exit': codes, label + '_marker': held})
        case.check(codes == [0], '%s: the command did not run to the end: %s' % (label, text[-300:]))
        case.check(held == '0', '%s: the command saw FM_CPU_PASS_HELD=%s, but it holds no pass' % (label, held))
        for notice in notices:
            case.check(notice in text, '%s: the notice %r is missing: %s' % (label, notice, text[-300:]))
    world = World('unusable-no-python', cores=1)
    nopython = world.folder / 'no-python-bin'
    nopython.mkdir()
    for directory in ('/usr/bin', '/bin', '/usr/sbin', '/sbin'):
        for name in os.listdir(directory):
            if not name.startswith(('python', 'pip')) and not (nopython / name).exists():
                os.symlink(os.path.join(directory, name), nopython / name)
    marker = world.folder / 'marker'
    codes = wait_all([world.launch('pool', ['bash', tool('fm-cpu-pass.sh'), 'run', '--', 'bash', '-c', show, '_', str(marker)], extra=dict(PATH=str(nopython)))], timeout=120)
    held = marker.read_text().strip() if marker.exists() else None
    case.measure(no_python_run_exit=codes, no_python_run_marker=held)
    case.check(codes == [0] and held == '0' and 'python3 not found' in world.text('pool'), 'no python3: the pass tool did not run the command once-said with no pass: %s %s' % (codes, world.text('pool')[-300:]))
    sandbox = runner_repo(world, ['fm-arm-pretool-check.test.sh'], 0.2)
    codes = wait_all([world.launch('runner', ['bash', '-c', 'cd "$1" && exec bin/fm-test-run.sh --jobs 1 tests/fm-arm-pretool-check.test.sh', '_', str(sandbox)], extra=dict(PATH=str(nopython), FM_CONC_GROUP='nopython'))], timeout=180)
    ended = [line for line in world.text('runner', 'out').splitlines() if line.startswith('FM_TEST_END ')]
    case.measure(no_python_runner_exit=codes, no_python_runner_end=ended[:1])
    case.check(codes == [0] and len(ended) == 1 and ' exit=0 ' in ended[0], 'no python3: the runner did not run its script without a slot: %s %s' % (codes, world.text('runner')[-300:]))
    return case


CASES = [case_nested, case_nested_two_level, case_nested_other_key, case_sibling_runners, case_mixed_cycle, case_lease_slot_cycle, case_holder_killed, case_one_candidate_proof, case_unusable_modes, case_guard_unavailable, case_holder_dies_at_guard_creation, case_async_cycle, case_one_reservation, case_jobs_clamp, case_duration_sample, case_padded_marker, case_key_guard, case_cross_key, case_malformed, case_brief_route, case_runner_holder, case_lint, case_isolation_proof, case_waiting, case_drain, case_wait_cause_control, case_same_class_order, case_sampler_control, case_soak]


def main():
    failed = []
    skipped = []
    selected = [name for name in sys.argv[4:]]
    for factory in CASES:
        if selected and factory.__name__ not in selected:
            continue
        if getattr(factory, 'ci_only', False) and not ON_CI:
            print('CASE %s: SKIPPED - CI-only: it sends kill signals or injects faults, which no host runs (set CI, GITHUB_ACTIONS or FM_CONC_RUN_CI_ONLY to run it)' % factory.__name__)
            skipped.append(factory.__name__)
            continue
        try:
            case = factory()
        except Exception as error:  # a case that cannot run is a failure, reported with the others
            case = Case(factory.__name__, 'raised')
            case.violations.append('%s: %s' % (type(error).__name__, error))
        case.report()
        results.append(case)
        if case.violations:
            failed.append(case.ident)
    for child in children:
        if child.poll() is None:
            kill_group(child)
    print('SUMMARY: %d cases, %d failed%s%s' % (len(results), len(failed), (': ' + ', '.join(failed)) if failed else '', ', %d CI-only skipped (%s)' % (len(skipped), ', '.join(skipped)) if skipped else ''))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
