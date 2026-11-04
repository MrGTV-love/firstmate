#!/usr/bin/env python3
"""Live driver: runs the real bin/fm-cpu-pass.sh, bin/fm-mem-guard.sh and bin/fm-duration.py
against a throwaway sandbox. HOME points at the sandbox, so ~/.no-mistakes/state.sqlite and
~/.no-mistakes/config.yaml are fixture files; FM_HOME is a sandbox home with copied-shape
records; FM_MEMORY_FIXTURE_DIR is the product's own native-facts fixture input; FM_CPU_POOL_DIR
is a private pool. No monkeypatching of the product. The no-mistakes binary on PATH is a stand-in
COMMAND that registers a run row in the sandbox database (a real start is prohibited here).

usage: live_driver.py REPO SANDBOX SCENARIO...
"""
import json, os, signal, socket, sqlite3, subprocess, sys, time
from pathlib import Path

GIB = 2 ** 30
repo, sb = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
scenarios = sys.argv[3:]
out_lines = []


def say(text=''):
    print(text, flush=True)


def fresh(name):
    case = sb / name
    home = case / 'home'
    (home / '.no-mistakes').mkdir(parents=True)
    (case / 'fmhome' / 'state').mkdir(parents=True)
    (case / 'native').mkdir()
    (case / 'bin').mkdir()
    db = home / '.no-mistakes' / 'state.sqlite'
    with sqlite3.connect(db) as c:
        c.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, worktree_dir TEXT, status TEXT NOT NULL,'
                  ' ci_ready_at INTEGER, awaiting_agent_since INTEGER)')
        c.execute('CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,'
                  ' step_order INTEGER NOT NULL, status TEXT NOT NULL, agent_pid INTEGER)')
        c.execute('CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,'
                  ' duration_ms INTEGER NOT NULL, exit_status TEXT NOT NULL)')
    nm = case / 'bin' / 'no-mistakes'
    nm.write_text('''#!/bin/bash
# stand-in for the no-mistakes CLI: a fresh start registers a run row; anything else is a reattach.
fresh=0
[ "$1" = rerun ] && fresh=1
if [ "$1 $2" = "axi run" ]; then for a in "$@"; do case "$a" in --intent|--intent=*|--intent-file|--intent-file=*) fresh=1;; esac; done; fi
id="nm-${CASE_RUN_ID:-$$}"
if [ $fresh = 1 ]; then
  sqlite3 "$HOME/.no-mistakes/state.sqlite" "INSERT INTO runs (id, repo_id, status) VALUES ('$id','repo','running')"
  echo "$id" >> "$CASE_DIR/order"
  echo "stand-in no-mistakes: started fresh run $id args=[$*] FM_PIPELINE_START_ADMITTED=${FM_PIPELINE_START_ADMITTED:-unset}"
else
  echo "stand-in no-mistakes: reattach/other args=[$*]"
fi
exit ${CASE_EXIT:-0}
''')
    nm.chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'NO_MISTAKES'))}
    env.update(HOME=str(home), FM_HOME=str(case / 'fmhome'), FM_MEMORY_FIXTURE_DIR=str(case / 'native'),
               FM_CPU_POOL_DIR=str(case / 'pool'), CASE_DIR=str(case), FM_DURATION_FILE='off',
               PATH=str(case / 'bin') + os.pathsep + os.environ['PATH'])
    facts(case)
    return case, db, env


def facts(case, available=40 * GIB, pressure=1, runs=(), total=128 * GIB):
    f = case / 'native'
    (f / 'sysctl').write_text('%d\n%d\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' % (total, pressure))
    (f / 'vm_stat').write_text(
        'Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'
        'Pages free: 1000.\nPages speculative: 100.\n'
        'Anonymous pages: 1048576.\nFile-backed pages: %d.\n'
        'Pages purgeable: 100.\nPages occupied by compressor: 32768.\n' % (available // 16384 - 1100))
    rows = [dict(pid=101, ppid=1, comm='daemon', started='s101', rss_bytes=GIB, fleet=False, run=None)]
    for i, (rep, run, rss) in enumerate(runs):
        rows.append(dict(pid=200 + i, ppid=1, comm='node', started='s%d' % i, rss_bytes=rss, fleet=True,
                         run='no-mistakes:%s/%s' % (rep, run)))
    tmp = f / 'processes.json.new'
    tmp.write_text(json.dumps(rows))
    tmp.replace(f / 'processes.json')


def calibrate(case, peaks=(1.0, 2.0, 5.77, 13.39), active=1953340270, total=128 * GIB):
    state = case / 'fmhome' / 'state'
    host = socket.gethostname()
    lines = [dict(host=host, total_bytes=total, errors=[], runs={
        'no-mistakes:r/a': dict(rss_bytes=int(active)), 'no-mistakes:r/b': dict(rss_bytes=int(5 * active))})]
    (state / 'memory-readings.jsonl').write_text(''.join(json.dumps(l) + '\n' for l in lines))
    runs = {'no-mistakes:cal/run-%d' % i: dict(peak_bytes=int(p * GIB), samples=2, incomplete_samples=0,
                                                first_seen='x', last_seen='x', max_gap_seconds=0) for i, p in enumerate(peaks)}
    (state / '.memory-calibration.json').write_text(json.dumps(dict(
        schema='fm-memory-calibration.v1', host=host, total_bytes=total, runs=runs, pressured=None)))


def sql(db, q, p=()):
    with sqlite3.connect(db) as c:
        c.execute(q, p)


def counted(db, case, active, ci_waiting=(), extra_avail=None):
    for run, rss in active:
        sql(db, "INSERT INTO runs (id, repo_id, status) VALUES (?, 'repo', 'running')", (run,))
        sql(db, "INSERT INTO step_results VALUES (?, ?, 'review', 1, 'fixing', 4000)", (run + '-s', run))
    for run in ci_waiting:
        sql(db, "INSERT INTO runs (id, repo_id, status) VALUES (?, 'repo', 'running')", (run,))
        sql(db, "INSERT INTO step_results VALUES (?, ?, 'ci', 1, 'running', NULL)", (run + '-s', run))


CPU = None
def cli():
    return ['bash', str(repo / 'bin/fm-cpu-pass.sh')]


def start(cmd, env, case, tag, cwd=None, stdin=None):
    o = open(case / (tag + '.out'), 'w'); e = open(case / (tag + '.err'), 'w')
    p = subprocess.Popen(cmd, env=env, stdout=o, stderr=e, stdin=stdin if stdin is not None else subprocess.DEVNULL,
                         start_new_session=True, cwd=cwd)
    o.close(); e.close()
    p.tag = tag; p.case = case; p.t0 = time.monotonic()
    return p


def text(case, tag, kind='err'):
    try:
        return (case / (tag + '.' + kind)).read_text()
    except FileNotFoundError:
        return ''


def until(pred, secs=20, what=''):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


def show(p, kind='err', grep=None):
    for line in text(p.case, p.tag, kind).splitlines():
        if grep is None or any(g in line for g in grep):
            say('    [%s %s] %s' % (p.tag, kind, line[:900]))


def waiters(case):
    return sorted(x.name for x in (case / 'pool').glob('pipeline-waiter-*')) if (case / 'pool').exists() else []


def kill(p):
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); p.wait()


LIVE = [('test-fixing', int(0.70 * GIB)), ('review-a', int(0.43 * GIB)), ('lint', int(2.22 * GIB)),
        ('review-b', int(0.13 * GIB)), ('pr', int(0.13 * GIB)), ('test', int(0.43 * GIB)), ('review-c', int(0.73 * GIB))]
CIW = ['ci-361', 'ci-367', 'ci-369', 'ci-3609']
REC = [21299200, 118226944, 491290624, 545144832, 574226432, 652591104, 673792000, 1083260928,
       1926561792, 3074097152, 5121441792, 7301611520]


def p1_live():
    say('== P1(a) PR 365 live case: 11 counted (4 CI waiters, no agent, 0 RSS), R 5.77 GiB, S 13.39 GiB, available 32.82 GiB, pressure 1')
    case, db, env = fresh('p1-live')
    calibrate(case)
    counted(db, case, LIVE, CIW)
    facts(case, available=int(32.82 * GIB) // 16384 * 16384, runs=[('repo', r, s) for r, s in LIVE])
    p = start(cli() + ['pipeline-start', '--priority', 'machinery', '--', 'sh', '-c', 'echo command-ran; exit 3'], env, case, 'p1a')
    done = until(lambda: p.poll() is not None, 8)
    say('  finished_within_8s=%s exit=%s elapsed=%.2fs stdout=%r' % (done, p.poll(), time.monotonic() - p.t0, text(case, 'p1a', 'out').strip()))
    show(p)
    if not done:
        kill(p); say('  (killed after 8 s: it was still waiting)')


def p1_recorded():
    say('== P1(b) 2026-11-03 14:14Z record: 12 runs holding 20.1 GiB, 25.27 GiB available, pressure 1')
    case, db, env = fresh('p1-rec')
    calibrate(case)
    shape = [('run-%02d' % i, r) for i, r in enumerate(REC)]
    counted(db, case, shape)
    facts(case, available=27132805120, runs=[('repo', r, s) for r, s in shape])
    p = start(cli() + ['pipeline-start', '--', 'true'], env, case, 'p1b')
    done = until(lambda: p.poll() is not None, 8)
    say('  finished_within_8s=%s exit=%s elapsed=%.2fs' % (done, p.poll(), time.monotonic() - p.t0))
    show(p)
    if not done:
        kill(p); say('  (killed after 8 s: it was still waiting)')


def p1_control():
    say('== P1(c) control: same 12-run state, available lowered to 8 GiB: start waits and names its inputs; raised to 25.27 GiB: admitted by itself')
    case, db, env = fresh('p1-ctl')
    calibrate(case)
    shape = [('run-%02d' % i, r) for i, r in enumerate(REC)]
    counted(db, case, shape)
    facts(case, available=8 * GIB, runs=[('repo', r, s) for r, s in shape])
    marker = case / 'ran'
    p = start(cli() + ['pipeline-start', '--', 'touch', str(marker)], env, case, 'p1c')
    until(lambda: 'waiting' in text(case, 'p1c'), 10)
    time.sleep(1.5)
    say('  after wait: running=%s marker_exists=%s waiter_entries=%s' % (p.poll() is None, marker.exists(), waiters(case)))
    show(p)
    facts(case, available=27132805120, runs=[('repo', r, s) for r, s in shape])
    t = time.monotonic()
    done = until(lambda: p.poll() is not None, 10)
    say('  after available raised: exit=%s within=%.2fs marker_exists=%s waiter_entries_left=%s' % (p.poll(), time.monotonic() - t, marker.exists(), waiters(case)))
    show(p, grep=['admitted'])


def holds():
    say('== P4 holds: native pressure 2 holds a fitting start; pressure back to 1 admits it by itself (no signal, no human)')
    case, db, env = fresh('hold-p2')
    calibrate(case)
    facts(case, available=40 * GIB, pressure=2)
    marker = case / 'ran'
    p = start(cli() + ['pipeline-start', '--', 'touch', str(marker)], env, case, 'p2')
    until(lambda: 'waiting' in text(case, 'p2'), 10)
    time.sleep(1.5)
    say('  pressure 2: running=%s marker_exists=%s' % (p.poll() is None, marker.exists()))
    show(p)
    facts(case, available=40 * GIB, pressure=1)
    t = time.monotonic()
    until(lambda: p.poll() is not None, 10)
    say('  pressure 1: exit=%s within=%.2fs marker_exists=%s' % (p.poll(), time.monotonic() - t, marker.exists()))
    show(p, grep=['admitted'])
    say('== P4 holds: unreadable memory facts hold; restored facts admit')
    case, db, env = fresh('hold-broken')
    calibrate(case)
    for n in ('sysctl', 'vm_stat', 'processes.json'):
        (case / 'native' / n).unlink()
    marker = case / 'ran'
    p = start(cli() + ['pipeline-start', '--', 'touch', str(marker)], env, case, 'br')
    until(lambda: 'waiting' in text(case, 'br'), 10)
    time.sleep(1.0)
    say('  facts unreadable: running=%s marker_exists=%s' % (p.poll() is None, marker.exists()))
    show(p)
    facts(case)
    until(lambda: p.poll() is not None, 10)
    say('  facts restored: exit=%s marker_exists=%s' % (p.poll(), marker.exists()))


def class_order():
    say('== P5(a) class order: other, vernant-build, machinery, merge-train queue behind a failing fit; admitted merge-train, machinery, vernant-build, other')
    case, db, env = fresh('order')
    calibrate(case)
    facts(case, available=10 * GIB)
    sql(db, "INSERT INTO runs (id, repo_id, status) VALUES ('blocker', 'repo', 'running')")
    sql(db, "INSERT INTO step_results VALUES ('b-s', 'blocker', 'review', 1, 'fixing', 1)")
    ps = []
    for cls in ('other', 'vernant-build', 'machinery', 'merge-train'):
        e = dict(env, CASE_RUN_ID=cls)
        ps.append(start(cli() + ['pipeline-start', '--priority', cls, '--', 'no-mistakes', 'axi', 'run', '--intent', 'x'], e, case, 'q-' + cls))
        until(lambda: len(waiters(case)) >= len(ps), 10)
    time.sleep(1.0)
    say('  queued: waiter_entries=%d order_file_exists=%s' % (len(waiters(case)), (case / 'order').exists()))
    show(ps[0], grep=['behind', 'waiting'])
    facts(case, available=100 * GIB)
    until(lambda: all(p.poll() is not None for p in ps), 30)
    say('  admitted order: %s exits=%s' % ((case / 'order').read_text().split(), [p.poll() for p in ps]))


def routes():
    say('== P6(f) fresh starts through bin/fm-mem-guard.sh run join the pipeline-start queue; reattach and other commands do not')
    case, db, env = fresh('routes')
    calibrate(case)
    # A fit that fails at pressure 1: one counted run the reading cannot see (R 5.77) + S 13.39 > 12 GiB.
    sql(db, "INSERT INTO runs (id, repo_id, status) VALUES ('blocker', 'repo', 'running')")
    facts(case, available=12 * GIB)
    mg = ['bash', str(repo / 'bin/fm-mem-guard.sh'), 'run', '--']
    shapes = [
        ('plain-intent', ['no-mistakes', 'axi', 'run', '--intent', 'g']),
        ('intent-file-eq', ['no-mistakes', 'axi', 'run', '--intent-file=/tmp/f']),
        ('intent-stdin', ['no-mistakes', 'axi', 'run', '--intent', '-']),
        ('reordered-abs', ['/usr/bin/env', str(case / 'bin' / 'no-mistakes'), 'axi', 'run', '--wait', '--intent', 'g']),
        ('rerun', ['no-mistakes', 'rerun']),
        ('bash-l-c-redirect', ['bash', '-l', '-c', 'no-mistakes axi run --intent x 2>&1 | tee /dev/null']),
        ('sh-e-c-touching', ['sh', '-e', '-c', 'cd /tmp&&no-mistakes axi run --intent g # comment']),
    ]
    for name, cmd in shapes:
        p = start(mg + cmd, dict(env, CASE_RUN_ID=name), case, 'f-' + name)
        ok = until(lambda: 'pipeline-start waiting' in text(case, 'f-' + name), 10)
        say('  fresh %-18s queued=%s still_running=%s run_registered=%s' % (name, ok, p.poll() is None,
            name in (case / 'order').read_text() if (case / 'order').exists() else False))
        kill(p)
    for name, cmd in [('reattach-wait', ['no-mistakes', 'axi', 'run', '--wait']), ('respond', ['no-mistakes', 'axi', 'respond', '--action', 'approve']),
                      ('status', ['no-mistakes', 'axi', 'status']), ('other-command', ['echo', 'hello-unchanged']),
                      ('no-intent-exit2', ['sh', '-c', 'echo "--intent or --intent-file is required to start a run" >&2; exit 2'])]:
        before = set(waiters(case))
        p = start(mg + cmd, env, case, 'r-' + name)
        done = until(lambda: p.poll() is not None, 10)
        say('  not-a-start %-15s ran_at_once=%s exit=%s queued=%s stdout=%r' % (name, done, p.poll(),
            'pipeline-start waiting' in text(case, 'r-' + name), text(case, 'r-' + name, 'out').strip()))
        if not done:
            kill(p)


def duration_routes():
    say('== P6 PR 366 shape through bin/fm-duration.py run: fresh start enters pipeline-start (base printed no pipeline-start line)')
    case, db, env = fresh('pr366')
    calibrate(case)
    intent = case / 'intent.txt'; intent.write_text('goal\n')
    cmd = ['python3', str(repo / 'bin/fm-duration.py'), 'run', 'no-mistakes.run', '--', 'env', 'FM_HOME=' + env['FM_HOME'],
           'bash', str(repo / 'bin/fm-mem-guard.sh'), 'run', '--', 'no-mistakes', 'axi', 'run', '--intent-file', str(intent), '--verification-plan', str(intent)]
    p = start(cmd, dict(env, CASE_RUN_ID='pr366'), case, 'pr366')
    done = until(lambda: p.poll() is not None, 20)
    say('  finished=%s exit=%s' % (done, p.poll()))
    show(p, grep=['pipeline-start'])
    show(p, 'out')
    if not done:
        kill(p)
    say('== R2-1 nested route with a literal 2>&1 inside a shell -c string: no deadlock, one admission')
    case, db, env = fresh('nested')
    calibrate(case)
    cmd = ['python3', str(repo / 'bin/fm-duration.py'), 'run', 'k', '--', 'bash', '-c',
           'bash %s run -- no-mistakes axi run --intent-file %s 2>&1' % (repo / 'bin/fm-mem-guard.sh', intent)]
    p = start(cmd, dict(env, CASE_RUN_ID='nested'), case, 'nested')
    done = until(lambda: p.poll() is not None, 20)
    say('  finished_within_20s=%s exit=%s pipeline-start_admitted_lines=%d waiting_lines=%d' % (
        done, p.poll(), text(case, 'nested').count('pipeline-start admitted') + text(case, 'nested', 'out').count('pipeline-start admitted'),
        text(case, 'nested').count('pipeline-start waiting') + text(case, 'nested', 'out').count('pipeline-start waiting')))
    show(p, 'out')
    if not done:
        kill(p); say('  DEADLOCK: killed after 20 s')
    say('== R2-1 reverse nesting: fm-mem-guard.sh run -- bash -c "fm-duration.py run k -- no-mistakes axi run --intent x # c"')
    cmd = ['bash', str(repo / 'bin/fm-mem-guard.sh'), 'run', '--', 'bash', '-c',
           'python3 %s run k -- no-mistakes axi run --intent x # trailing comment' % (repo / 'bin/fm-duration.py')]
    p = start(cmd, dict(env, CASE_RUN_ID='reverse'), case, 'reverse')
    done = until(lambda: p.poll() is not None, 20)
    say('  finished_within_20s=%s exit=%s' % (done, p.poll()))
    show(p, 'out')
    if not done:
        kill(p); say('  DEADLOCK: killed after 20 s')


def gate_case(name, step='ci', worktree=True, extra_run_same_dir=False, avail=40 * GIB, timeout='240m', p99_ms=None):
    case, db, env = fresh(name)
    calibrate(case)
    wt = case / 'worktree'
    wt.mkdir()
    sql(db, "INSERT INTO runs (id, repo_id, branch, worktree_dir, status) VALUES ('run-x', 'repo', 'fm/x', ?, 'running')", (str(wt),))
    if extra_run_same_dir:
        sql(db, "INSERT INTO runs (id, repo_id, branch, worktree_dir, status) VALUES ('run-y', 'repo', 'fm/y', ?, 'running')", (str(wt),))
    if step:
        sql(db, "INSERT INTO step_results VALUES ('x-s', 'run-x', ?, 1, 'running', NULL)", (step,))
    (case / 'home' / '.no-mistakes' / 'config.yaml').write_text('agent_timeout: %s\n' % timeout)
    for i in range(10):
        sql(db, "INSERT INTO agent_invocations VALUES (?, 'old', 'ci', ?, 'ok')", ('i%d' % i, p99_ms or 60000))
    facts(case, available=avail)
    agent = case / 'claude'
    agent.write_text('#!/bin/bash\n# stand-in claude: reads its prompt on stdin, records start time, sleeps, exits with CASE_AGENT_EXIT\n'
                     'trap \'echo got-TERM > "$CASE_DIR/agent.signal"; exit 143\' TERM\n'
                     'python3 -c "import time;print(time.time_ns())" > "$CASE_DIR/agent.started"\n'
                     'read -r prompt; echo "agent got prompt: $prompt args=[$*] cwd=$PWD"\n'
                     'for i in $(seq 1 ${CASE_AGENT_SECS:-0}0); do sleep 0.1; done\n'
                     'exit ${CASE_AGENT_EXIT:-0}\n')
    agent.chmod(0o755)
    launcher = case / 'claude-teamclaude'
    launcher.write_text('#!/bin/bash\n# isolated launcher copy: only the final exec goes through the gate\n'
                        'exec %s -- %s "$@"\n' % ('bash ' + str(repo / 'bin/fm-cpu-pass.sh') + ' launch-gate', agent))
    launcher.chmod(0o755)
    return case, db, env, wt, launcher


def wake_lines(case):
    q = list((case / 'fmhome').rglob('*wake*'))
    lines = []
    for f in q:
        if f.is_file():
            lines += [l for l in f.read_text(errors='replace').splitlines() if 'launch-gate' in l]
    return lines


def launch_gate():
    say('== P9(a) first proof: unmapped, ambiguous and unreadable-database launches refuse with exit 75 and a cause line; never pass through')
    case, db, env, wt, launcher = gate_case('lg-unmapped')
    other = case / 'elsewhere'; other.mkdir()
    p = subprocess.run(['bash', str(launcher), '-p'], cwd=other, env=env, input='hi\n', capture_output=True, text=True, timeout=30)
    say('  unmapped: exit=%s agent_started=%s stderr=%r' % (p.returncode, (case / 'agent.started').exists(), p.stderr.strip()[-400:]))
    say('  durable wake lines: %s' % wake_lines(case))
    case, db, env, wt, launcher = gate_case('lg-ambiguous', extra_run_same_dir=True)
    p = subprocess.run(['bash', str(launcher), '-p'], cwd=wt, env=env, input='hi\n', capture_output=True, text=True, timeout=30)
    say('  ambiguous: exit=%s agent_started=%s stderr=%r' % (p.returncode, (case / 'agent.started').exists(), p.stderr.strip()[-400:]))
    case, db, env, wt, launcher = gate_case('lg-nodb')
    (case / 'home' / '.no-mistakes' / 'state.sqlite').unlink()
    p = subprocess.run(['bash', str(launcher), '-p'], cwd=wt, env=env, input='hi\n', capture_output=True, text=True, timeout=30)
    say('  unreadable db: exit=%s agent_started=%s stderr=%r' % (p.returncode, (case / 'agent.started').exists(), p.stderr.strip()[-400:]))

    say('== P9(b) non-CI step passes through at once, unchanged, exit code returned')
    case, db, env, wt, launcher = gate_case('lg-review', step='review')
    t = time.monotonic()
    p = subprocess.run(['bash', str(launcher), '-p', '--model', 'x'], cwd=wt, env=dict(env, CASE_AGENT_EXIT='7'), input='review prompt\n', capture_output=True, text=True, timeout=30)
    say('  review step: exit=%s secs=%.2f stdout=%r' % (p.returncode, time.monotonic() - t, p.stdout.strip()))
    say('  stderr=%r pool_launch_entries=%s' % (p.stderr.strip()[-300:], list((case / 'pool').glob('launch-*')) if (case / 'pool').exists() else []))

    say('== P9(c) CI step that fits: admitted, reservation published before the lock release, agent not waited on; stdin and exit status pass through')
    case, db, env, wt, launcher = gate_case('lg-ci-fit')
    p = start(['bash', str(launcher), '-p'], dict(env, CASE_AGENT_SECS='2', CASE_AGENT_EXIT='1'), case, 'fit', cwd=wt, stdin=subprocess.PIPE)
    p.stdin.write(b'fix the CI\n'); p.stdin.close()
    until(lambda: (case / 'agent.started').exists(), 10)
    time.sleep(0.3)
    live_entries = sorted(x.name for x in (case / 'pool').glob('launch-*'))
    say('  while agent lives: launch reservation entries=%s' % live_entries)
    p.wait(20)
    say('  exit=%s stdout=%r' % (p.returncode, text(case, 'fit', 'out').strip()))
    show(p)
    err = text(case, 'fit')
    try:
        vals = dict(kv.split('=') for kv in err.split('launch-gate admitted:')[1].split() if kv.endswith(tuple('0123456789')) and '_ns=' in kv)
        a, pub, st, un = (int(vals[k]) for k in ('admitted_ns', 'published_ns', 'agent_started_ns', 'unlocked_ns'))
        say('  order: admitted<=published<=agent_started<=unlocked: %s (published->unlocked %.1f ms)' % (a <= pub <= st <= un, (un - pub) / 1e6))
    except Exception as exc:
        say('  could not parse timestamps: %r' % exc)
    time.sleep(0.3)
    say('  after exit: launch entries left (live-locked)=%s' % locked(case, 'launch-*'))

    say('== P10(a) two CI-waiting runs resume together, room for one full R: first admitted, second waits, second admitted by itself when the first agent exits')
    case, db, env, wt, launcher = gate_case('lg-two', avail=int(16 * GIB))
    wt2 = case / 'worktree2'; wt2.mkdir()
    sql(db, "INSERT INTO runs (id, repo_id, branch, worktree_dir, status) VALUES ('run-z', 'repo', 'fm/z', ?, 'running')", (str(wt2),))
    sql(db, "INSERT INTO step_results VALUES ('z-s', 'run-z', 'ci', 1, 'running', NULL)")
    # budget 16 GiB: the first new run needs S 13.39 GiB and fits; the second needs the first at its full R 5.77 while invisible + S = 19.16 GiB and waits.
    a1 = start(['bash', str(launcher), '-p'], dict(env, CASE_AGENT_SECS='4'), case, 'g1', cwd=wt, stdin=subprocess.PIPE)
    a2 = start(['bash', str(launcher), '-p'], dict(env, CASE_AGENT_SECS='0'), case, 'g2', cwd=wt2, stdin=subprocess.PIPE)
    for a in (a1, a2):
        a.stdin.write(b'p\n'); a.stdin.close()
    until(lambda: 'launch-gate admitted' in text(case, 'g1') or 'launch-gate admitted' in text(case, 'g2'), 10)
    time.sleep(1.5)
    say('  t+1.5s: g1_admitted=%s g2_admitted=%s g2_waiting=%s g1_waiting=%s' % (
        'launch-gate admitted' in text(case, 'g1'), 'launch-gate admitted' in text(case, 'g2'),
        'waiting' in text(case, 'g2'), 'waiting' in text(case, 'g1')))
    until(lambda: a1.poll() is not None and a2.poll() is not None, 30)
    say('  both finished: g1 exit=%s g2 exit=%s' % (a1.poll(), a2.poll()))
    show(a1, grep=['admitted', 'waiting']); show(a2, grep=['admitted', 'waiting'])
    say('  durable wake lines: %s' % [l[:300] for l in wake_lines(case)])

    say('== P9(e) hold bound: agent_timeout 3m, completed CI-fix p99 2m55s -> bound 5 s; no fit -> refused at the bound with exit 75, agent never started')
    case, db, env, wt, launcher = gate_case('lg-bound', avail=4 * GIB, timeout='3m', p99_ms=175000)
    # another counted active run (review step, not yet visible: reserves its full R), so the one-start minimum does not apply
    sql(db, "INSERT INTO runs (id, repo_id, status) VALUES ('busy', 'repo', 'running')")
    sql(db, "INSERT INTO step_results VALUES ('busy-s', 'busy', 'review', 1, 'fixing', 77)")
    t = time.monotonic()
    p = subprocess.run(['bash', str(launcher), '-p'], cwd=wt, env=env, input='p\n', capture_output=True, text=True, timeout=60)
    say('  exit=%s held=%.1fs agent_started=%s' % (p.returncode, time.monotonic() - t, (case / 'agent.started').exists()))
    for line in p.stderr.splitlines():
        if 'refused' in line or 'waiting' in line:
            say('    [stderr] ' + line[:700])
    needles = ['rate_limited', 'rate limit', 'connection refused', 'i/o timeout', 'free usage limit', 'overloaded', ' exited:', 'timeout']
    refusal = [l for l in p.stderr.splitlines() if 'launch-gate refused' in l]
    say('  daemon retry/fallback phrases in refusal: %s' % [n for n in needles if refusal and n in refusal[0].lower()])
    say('  durable wake lines: %s' % [l[:400] for l in wake_lines(case)])
    say('  live entries left: waiters=%s launches=%s' % (locked(case, 'pipeline-waiter-*'), locked(case, 'launch-*')))

    say('== P9(g) signals: SIGTERM to the gate reaches the agent; its status comes back')
    case, db, env, wt, launcher = gate_case('lg-sig')
    p = start(['bash', str(launcher), '-p'], dict(env, CASE_AGENT_SECS='30'), case, 'sig', cwd=wt, stdin=subprocess.PIPE)
    p.stdin.write(b'p\n'); p.stdin.close()
    until(lambda: (case / 'agent.started').exists(), 10); time.sleep(0.5)
    os.kill(p.pid, signal.SIGTERM)
    p.wait(15)
    say('  gate exit=%s agent_saw=%r launch entries live after=%s' % (p.returncode, (case / 'agent.signal').read_text().strip() if (case / 'agent.signal').exists() else None, locked(case, 'launch-*')))

    say('== P9(g) gate SIGKILLed alone after the admit: the watcher kills the agent, nothing is left')
    case, db, env, wt, launcher = gate_case('lg-kill')
    p = start(['bash', str(launcher), '-p'], dict(env, CASE_AGENT_SECS='60'), case, 'kill', cwd=wt, stdin=subprocess.PIPE)
    p.stdin.write(b'p\n'); p.stdin.close()
    until(lambda: (case / 'agent.started').exists(), 10); time.sleep(0.5)
    agents = subprocess.run(['pgrep', '-f', str(case / 'claude')], capture_output=True, text=True).stdout.split()
    os.kill(p.pid, signal.SIGKILL)
    p.wait(5)
    gone = until(lambda: not subprocess.run(['pgrep', '-f', str(case / 'claude')], capture_output=True, text=True).stdout.split(), 5)
    say('  agents before kill=%d, agents gone within 5 s=%s, launch entries live=%s' % (len(agents), gone, locked(case, 'launch-*')))

    say('== P11(e) agent that cannot launch: missing agent returns 127, entries released')
    case, db, env, wt, launcher = gate_case('lg-missing')
    launcher.write_text('#!/bin/bash\nexec bash %s launch-gate -- %s "$@"\n' % (repo / 'bin/fm-cpu-pass.sh', case / 'no-such-claude'))
    p = subprocess.run(['bash', str(launcher)], cwd=wt, env=env, input='p\n', capture_output=True, text=True, timeout=30)
    say('  exit=%s stderr_tail=%r launch entries live=%s' % (p.returncode, p.stderr.strip()[-200:], locked(case, 'launch-*')))


def gate_extra():
    import hashlib
    say('== P11(a) isolated copy of the live launcher: TeamClaude env lines stubbed (no node, no proxy call), only the final exec routed through the gate')
    live = Path.home().parent / Path(os.environ.get('USER', '')) / '.no-mistakes/bin/claude-teamclaude'
    live = Path(os.path.expanduser('~/.no-mistakes/bin/claude-teamclaude'))
    before = hashlib.sha256(live.read_bytes()).hexdigest()
    case, db, env, wt, _ = gate_case('lg-copy')
    certs = case / 'ca.pem'; certs.write_text('stand-in\n')
    src = live.read_text().splitlines()
    out = []
    for line in src:
        if line.startswith('tc_env='):
            line = "tc_env='export HTTPS_PROXY=http://127.0.0.1:9; export NODE_EXTRA_CA_CERTS=%s'  # sandbox stub: no TeamClaude call" % certs
        elif line.startswith('exec /Users/charlesabrooker/.local/bin/claude'):
            line = 'exec bash %s launch-gate -- %s "$@"' % (repo / 'bin/fm-cpu-pass.sh', case / 'claude')
        out.append(line)
    copy = case / 'claude-teamclaude'
    copy.write_text('\n'.join(out) + '\n'); copy.chmod(0o755)
    d = subprocess.run(['diff', str(live), str(copy)], capture_output=True, text=True).stdout
    say('  diff live -> copy:')
    for l in d.splitlines():
        say('    ' + l)
    p = subprocess.run(['bash', str(copy), '-p', '--output-format', 'stream-json'], cwd=wt, env=dict(env, CASE_AGENT_EXIT='0'),
                       input='ci fix prompt\n', capture_output=True, text=True, timeout=60)
    say('  copy run (CI step): exit=%s stdout=%r' % (p.returncode, p.stdout.strip()))
    for l in p.stderr.splitlines():
        if 'admitted' in l: say('    [stderr] ' + l[:260] + ' ...' + l[-140:])
    after = hashlib.sha256(live.read_bytes()).hexdigest()
    say('  live launcher sha256 before=%s after=%s unchanged=%s' % (before, after, before == after))

    say('== P9(g)/P11(e) caller cancel mid-hold: group kill while the gate waits leaves no live waiter or lock; the next launch is admitted')
    case, db, env, wt, launcher = gate_case('lg-cancel', avail=4 * GIB)
    sql(db, "INSERT INTO runs (id, repo_id, status) VALUES ('busy', 'repo', 'running')")
    sql(db, "INSERT INTO step_results VALUES ('busy-s', 'busy', 'review', 1, 'fixing', 77)")
    g = start(['bash', str(launcher), '-p'], env, case, 'cancel', cwd=wt, stdin=subprocess.PIPE)
    g.stdin.write(b'p\n'); g.stdin.close()
    until(lambda: 'waiting' in text(case, 'cancel'), 15)
    say('  holding: running=%s live waiters=%d' % (g.poll() is None, locked(case, 'pipeline-waiter-*')))
    os.killpg(g.pid, signal.SIGKILL); g.wait(5)
    time.sleep(0.3)
    lock_free = True
    import fcntl
    lk = case / 'pool' / 'pipeline-start.lock'
    if lk.exists():
        fd = os.open(str(lk), os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            lock_free = False
        os.close(fd)
    say('  after group SIGKILL: live waiters=%d live launches=%d start lock free=%s agent started=%s' % (
        locked(case, 'pipeline-waiter-*'), locked(case, 'launch-*'), lock_free, (case / 'agent.started').exists()))
    sql(db, "UPDATE runs SET status='completed' WHERE id='busy'")
    t = time.monotonic()
    p = subprocess.run(['bash', str(launcher), '-p'], cwd=wt, env=env, input='p\n', capture_output=True, text=True, timeout=30)
    say('  next launch after cancel: exit=%s secs=%.2f admitted=%s' % (p.returncode, time.monotonic() - t, 'launch-gate admitted' in p.stderr))

    say('== P10(d) dead holder: a gate SIGKILLed mid-run (its agent killed by the watcher) leaves an inert launch entry that reserves nothing')
    case, db, env, wt, launcher = gate_case('lg-dead', avail=int(16 * GIB))
    wt2 = case / 'worktree2'; wt2.mkdir()
    sql(db, "INSERT INTO runs (id, repo_id, branch, worktree_dir, status) VALUES ('run-z', 'repo', 'fm/z', ?, 'running')", (str(wt2),))
    sql(db, "INSERT INTO step_results VALUES ('z-s', 'run-z', 'ci', 1, 'running', NULL)")
    g = start(['bash', str(launcher), '-p'], dict(env, CASE_AGENT_SECS='60'), case, 'dead', cwd=wt, stdin=subprocess.PIPE)
    g.stdin.write(b'p\n'); g.stdin.close()
    until(lambda: (case / 'agent.started').exists(), 15); time.sleep(0.5)
    say('  first gate admitted, live launch entries=%d' % locked(case, 'launch-*'))
    os.kill(g.pid, signal.SIGKILL); g.wait(5)
    until(lambda: not subprocess.run(['pgrep', '-f', str(case / 'claude')], capture_output=True, text=True).stdout.split(), 5)
    files = sorted(x.name for x in (case / 'pool').glob('launch-*'))
    say('  after SIGKILL of the gate alone: launch files on disk=%s live=%d agent processes=%s' % (
        files, locked(case, 'launch-*'), subprocess.run(['pgrep', '-f', str(case / 'claude')], capture_output=True, text=True).stdout.split()))
    t = time.monotonic()
    p = subprocess.run(['bash', str(launcher), '-p'], cwd=wt2, env=env, input='p\n', capture_output=True, text=True, timeout=30)
    say('  second run (would wait if the dead entry still reserved R): exit=%s secs=%.2f admitted_without_wait=%s' % (
        p.returncode, time.monotonic() - t, 'launch-gate admitted' in p.stderr and 'waiting' not in p.stderr))
    for l in p.stderr.splitlines():
        if 'admitted' in l: say('    [stderr] ' + l[:330])
    say('  launch files left after scan=%s' % sorted(x.name for x in (case / 'pool').glob('launch-*')))


def locked(case, pattern):
    import fcntl
    n = 0
    for path in (case / 'pool').glob(pattern) if (case / 'pool').exists() else []:
        try:
            fd = os.open(str(path), os.O_RDONLY)
        except FileNotFoundError:
            continue
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            n += 1
        finally:
            os.close(fd)
    return n


for s in scenarios:
    globals()[s]()
    say()
