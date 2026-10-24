#!/usr/bin/env bash
# Slow productive commands must survive the former wall-clock limits.
# All processes and records belong to disposable homes, never a live home.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-work-progress)
export ROOT TMP_ROOT
python3 - <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

root = Path(os.environ['ROOT'])
tmp = Path(os.environ['TMP_ROOT'])
failures = []
# Sustained CPU work makes the progress observable even with buffered stdout.
busy = '''import time
until = time.monotonic() + 4
while time.monotonic() < until:
    sum(i*i for i in range(1000))
'''

def script(path, body):
    path.write_text('#!/usr/bin/env bash\n' + body)
    path.chmod(0o755)

def fixture(name):
    home = tmp / name
    for child in ('state', 'data', 'config', 'projects', 'fakebin'):
        (home / child).mkdir(parents=True, exist_ok=True)
    shutil.copytree(root / 'bin', home / 'bin')
    env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home),
               FM_STATE_OVERRIDE=str(home / 'state'), FM_DATA_OVERRIDE=str(home / 'data'),
               FM_CONFIG_OVERRIDE=str(home / 'config'), FM_PROJECTS_OVERRIDE=str(home / 'projects'),
               FM_DURATION_FILE='off', FM_CREW_STATE_META_OVERRIDE='', FM_CREW_STATE_STATUS_OVERRIDE='',
               PATH=str(home / 'fakebin') + ':' + os.environ['PATH'])
    return home, env

def run(command, env):
    return subprocess.run(list(map(str, command)), env=env, capture_output=True, text=True)

def require(condition, detail):
    if not condition:
        raise AssertionError(detail)

def case(name, test):
    try:
        test()
        print('ok - ' + name, flush=True)
    except Exception as error:
        failures.append(name)
        print('not ok - ' + name + ': ' + str(error), flush=True)

def arm():
    home, env = fixture('arm')
    script(home / 'bin/fm-watch.sh', "python3 - <<'SLOW'\n" + busy + "SLOW\nprintf 'signal: productive-start-finished\\n'\n")
    env['FM_ARM_CONFIRM_TIMEOUT'] = '1'
    result = run([home / 'bin/fm-watch-arm.sh'], env)
    require(result.returncode == 0 and 'signal: productive-start-finished' in result.stdout,
            f'productive startup was refused: rc={result.returncode} {result.stdout} {result.stderr}')
case('arm_slow_cpu_start_completes', arm)

def arm_late_failure(waiter_left):
    home, env = fixture('arm-late-failure-' + ('left' if waiter_left else 'waiting'))
    script(home / 'bin/fm-watch.sh', "sleep 2\nprintf 'watcher: FAILED - fixture late startup failure\\n'\nexit 1\n")
    mark = home / 'state/successor.unattended'
    env['FM_WATCH_LATE_FAILURE_MARK'] = str(mark)
    arm_process = subprocess.Popen([str(home / 'bin/fm-watch-arm.sh')], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if waiter_left:
        time.sleep(0.5)
        mark.touch()
    output = arm_process.communicate()[0]
    queue = home / 'state/.wake-queue'
    rows = queue.read_text() if queue.exists() else ''
    require(arm_process.returncode != 0 and 'fixture late startup failure' in output,
            f'the fixture arm did not fail: {arm_process.returncode} {output}')
    if waiter_left:
        require('watcher-successor-failed' in rows and 'fixture late startup failure' in rows
                and 'still starting when its wake went out' in rows and not mark.exists(),
                f'a late failure was not queued durably: {rows!r} mark={mark.exists()}')
    else:
        require('watcher-successor-failed' not in rows, f'a failure its waiter saw was queued again: {rows!r}')
case('arm_late_failure_reaches_the_wake_queue_once_its_waiter_left', lambda: arm_late_failure(True))
case('arm_failure_seen_by_its_waiter_is_not_queued_again', lambda: arm_late_failure(False))

def omp_readiness(mode):
    home, env = fixture('omp-readiness-' + mode)
    for name in ('.omp/extensions', '.pi/extensions/lib'):
        shutil.copytree(root / name, home / name)
    package = home / 'node_modules/typebox'
    package.mkdir(parents=True)
    (package / 'package.json').write_text('{"name":"typebox","type":"module","exports":"./index.js"}')
    (package / 'index.js').write_text('export const Type = {Object(properties) {return {type:"object",properties};}};')
    source = busy + '''import os, signal
from pathlib import Path
home = Path(os.environ['FM_HOME'])
signal.signal(signal.SIGTERM, lambda *_: exit(0))
if os.environ['FM_TEST_SUCCESSOR_MODE'] == 'late-failed':
    (home / 'late-failed').touch()
    print('watcher: FAILED - fixture late startup failure', flush=True)
    raise SystemExit(1)
print(f'watcher: started pid={os.getpid()} (beacon fresh)', flush=True)
(home / 'ready-completed').touch()
while True: time.sleep(0.1)
'''
    script(home / 'bin/fm-watch-arm.sh', '''[ "${1:-}" != --handling-delivered ] || exit 0
if [ ! -e "$FM_HOME/fired" ]; then
  touch "$FM_HOME/fired"
  printf 'watcher: started pid=%s (beacon fresh)\\n' "$$"
  . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
  fm_wake_append signal slow-readiness 'signal: slow readiness wake' || exit 1
  printf 'signal: slow readiness wake\\n'
  exit 0
fi
exec python3 -c ''' + __import__('shlex').quote(source) + '\n')
    env.update(FM_OMP_ARM_READY_TIMEOUT_MS='50', FM_WATCH_REARM_RETRY_LIMIT='1', FM_TEST_SUCCESSOR_MODE=mode)
    js = '''import {pathToFileURL} from 'node:url';
import {writeFileSync, existsSync} from 'node:fs';
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\\n`);
const handlers = new Map(); let tool; const sent = [];
const api = {on(e,h){handlers.set(e,h)},registerTool(t){tool=t},registerCommand(){},sendUserMessage(m){sent.push(m)}};
const mod = await import(pathToFileURL(`${process.env.FM_HOME}/.omp/extensions/fm-primary-omp-watch.ts`).href);
mod.default(api);
try {
  await handlers.get('before_agent_start')({}, {isIdle:()=>true});
  const result = await tool.execute();
  const delivered = () => sent.some(m=>m.includes('signal: slow readiness wake')) && sent.some(m=>m.includes('still starting'));
  for (let i = 0; i < 500 && !delivered(); i++) await new Promise(r=>setTimeout(r,100));
  if (!result.details.ok || !delivered() || sent.some(m=>m.includes('FAILED')))
    throw new Error('slow readiness held or failed the wake: '+JSON.stringify({result,sent}));
  if (existsSync(`${process.env.FM_HOME}/ready-completed`) || existsSync(`${process.env.FM_HOME}/late-failed`))
    throw new Error('the wake waited for the successor to report');
  if (process.env.FM_TEST_SUCCESSOR_MODE === 'late-failed') {
    for (let i = 0; i < 300 && !sent.some(m=>m.includes('fixture late startup failure')); i++) await new Promise(r=>setTimeout(r,100));
    if (!sent.some(m=>m.includes('fixture late startup failure')))
      throw new Error('the late successor failure was not surfaced: '+JSON.stringify(sent));
  } else {
    for (let i = 0; i < 300 && !existsSync(`${process.env.FM_HOME}/ready-completed`); i++) await new Promise(r=>setTimeout(r,100));
    if (!existsSync(`${process.env.FM_HOME}/ready-completed`))
      throw new Error('the still-starting successor was not left to become ready');
  }
} finally {await handlers.get('session_shutdown')({}, {});}
process.exit(0);
'''
    result = run(['node', '--input-type=module', '-e', js], env)
    require(result.returncode == 0, result.stdout + result.stderr)
case('omp_slow_readiness_does_not_hold_the_wake', lambda: omp_readiness('slow'))
case('omp_late_successor_failure_is_surfaced', lambda: omp_readiness('late-failed'))

def claude_readiness(mode):
    home, env = fixture('claude-readiness-' + mode)
    subprocess.run(['git', 'init', '-q', str(home)], check=True)
    (home / 'AGENTS.md').write_text('')
    (home / 'config/supervision-host-off').touch()
    (home / 'state/task.meta').write_text('window=fm:fm-task\nkind=ship\n')
    fakeclaude = home / 'fakebin/claude'
    fakeclaude.symlink_to('/bin/bash')
    source = '''import os, time
from pathlib import Path
home = Path(os.environ['FM_HOME'])
if os.environ.get('FM_WATCH_PREDECESSOR_ARM_PID'):
    (home / 'successor-pid').write_text(str(os.getpid()))
    if os.environ['FM_TEST_SUCCESSOR_MODE'] == 'failed':
        print('watcher: FAILED - fixture startup failure', flush=True)
        raise SystemExit(1)
    if os.environ['FM_TEST_SUCCESSOR_MODE'] == 'late-failed':
        time.sleep(5)
        os.execv('/bin/bash', ['bash', str(home / 'bin/fm-watch-arm-real.sh')])
    until = time.monotonic() + 5
    while time.monotonic() < until: sum(i*i for i in range(1000))
    print(f'watcher: started pid={os.getpid()} (beacon fresh)', flush=True)
    (home / 'successor-completed').touch()
else:
    print(f'watcher: attached pid={os.getpid()} (beacon 2s)', flush=True)
    (home / 'state/.watcher-down').write_text('pending:downtime:fixture-generation\\n')
    print('signal: task.status done: fixture peer cycle ended', flush=True)
'''
    shutil.copy2(home / 'bin/fm-watch-arm.sh', home / 'bin/fm-watch-arm-real.sh')
    script(home / 'bin/fm-watch.sh', "printf 'watcher: FAILED - fixture late startup failure\\n'\nexit 1\n")
    script(home / 'bin/fm-watch-arm.sh', 'exec python3 -c ' + __import__('shlex').quote(source) + '\n')
    env.update(FM_ARM_CONFIRM_TIMEOUT='1', FM_TEST_SUCCESSOR_MODE=mode)
    try:
        # The trailing exit keeps bash 5.1+ from exec-ing the hook in place of
        # the fake Claude, which would remove the harness from its ancestry.
        result = subprocess.run([str(fakeclaude), '-c',
            'printf "%s\\n" "$$" > "$FM_HOME/state/.lock"; "$FM_HOME/bin/fm-claude-stop-autoarm.sh"; '
            'status=$?; exit "$status"'],
            env=env, input='{"session_id":"slow-successor","stop_hook_active":false}\n',
            capture_output=True, text=True)
        detail = f'rc={result.returncode} completed={(home / "successor-completed").exists()} ' + result.stdout + result.stderr
        require(result.returncode == 2, 'the wake was not delivered: ' + detail)
        if mode == 'failed':
            require('did not confirm' in result.stderr and 'fixture startup failure' in result.stderr,
                    'the successor failure was not reported: ' + detail)
            return
        if mode == 'late-failed':
            require('still starting' in result.stderr and 'fixture late startup failure' not in result.stderr,
                    'the wake waited on the slow successor: ' + detail)
            queue = home / 'state/.wake-queue'
            for _ in range(200):
                if queue.exists() and 'fixture late startup failure' in queue.read_text(): break
                time.sleep(0.1)
            rows = queue.read_text() if queue.exists() else ''
            require('watcher-successor-failed' in rows and 'still starting when its wake went out' in rows,
                    'the late successor failure was not queued durably: ' + repr(rows) + detail)
            return
        require('still starting' in result.stderr and 'did not confirm' not in result.stderr
                and not (home / 'successor-completed').exists(), 'the wake waited on the slow successor: ' + detail)
        for _ in range(200):
            if (home / 'successor-completed').exists(): break
            time.sleep(0.1)
        require((home / 'successor-completed').exists(), 'the still-starting successor was not left to finish: ' + detail)
    finally:
        pidfile = home / 'successor-pid'
        if pidfile.exists():
            import signal
            try: os.kill(int(pidfile.read_text()), signal.SIGKILL)
            except ProcessLookupError: pass
case('claude_slow_successor_does_not_hold_the_rewake', lambda: claude_readiness('slow'))
case('claude_failed_successor_is_reported_in_the_rewake', lambda: claude_readiness('failed'))
case('claude_late_successor_failure_reaches_the_wake_queue', lambda: claude_readiness('late-failed'))

def watchdog():
    home, env = fixture('watchdog')
    (home / 'state/task.meta').write_text('window=fm:fm-task\nkind=ship\n')
    session = subprocess.Popen(['bash', '-c', 'exec -a claude /bin/sleep 120'])
    holder = subprocess.Popen([sys.executable, '-c', '''import time
from pathlib import Path
home = Path(__import__('sys').argv[1])
while not (home / 'stall').exists(): sum(i*i for i in range(1000))
(home / 'stalled').touch()
time.sleep(120)
''', str(home)])
    try:
        (home / 'state/.lock').write_text(str(session.pid) + '\n')
        lock = home / 'state/.watch.lock'
        lock.mkdir()
        identity = run(['bash', '-c', '. "$1"; fm_pid_identity "$2"', '_',
                        home / 'bin/fm-wake-lib.sh', str(holder.pid)], env).stdout.strip()
        require(bool(identity), 'watcher identity could not be recorded')
        for name, value in {'pid': str(holder.pid), 'pid-identity': identity, 'fm-home': str(home),
                            'watcher-path': str(home / 'bin/fm-watch.sh')}.items():
            (lock / name).write_text(value + '\n')
        beat = home / 'state/.last-watcher-beat'
        beat.touch()
        os.utime(beat, (1, 1))
        script(home / 'arm.sh', 'echo "$*" >> "$FM_HOME/arm.calls"\ntouch "$FM_HOME/state/.last-watcher-beat"\n')
        (home / 'config/watchdog-resume').write_text('echo resumed >> "$FM_HOME/resume.calls"\n')
        env.update(FM_WATCHDOG_ARM=str(home / 'arm.sh'), FM_WATCHDOG_STALE_SECS='1',
                   FM_WATCHDOG_VERIFY_SECS='1', FM_WATCHDOG_STEP_SECS='20')
        for _ in range(3):
            result = run([home / 'bin/fm-watchdog-check.sh'], env)
            require(result.returncode == 0 and result.stdout.strip() == 'watchdog: healthy',
                    'old beacon overrode productive CPU: ' + result.stdout + result.stderr)
            require(not (home / 'arm.calls').exists() and not (home / 'resume.calls').exists(),
                    'productive watcher was stopped or its session resumed')
            time.sleep(1.1)
        # The signal owner must reject proof for another identity, and must
        # resample a holder that has resumed progress since the watchdog read.
        guarded = dict(env, FM_WATCH_STOP_PID=str(holder.pid + 1),
                       FM_WATCH_STOP_IDENTITY=identity, FM_WATCH_STOP_IDLE_SECS='1')
        result = run([home / 'bin/fm-watch-arm.sh', '--stop'], guarded)
        require('retained' in result.stdout and holder.poll() is None,
                'stop request signalled a different lock holder: ' + result.stdout)
        guarded['FM_WATCH_STOP_PID'] = str(holder.pid)
        result = run([home / 'bin/fm-watch-arm.sh', '--stop'], guarded)
        require('retained' in result.stdout and holder.poll() is None,
                'stop owner ignored resumed CPU progress: ' + result.stdout)
        # The exact same process now parks without output or CPU growth, but
        # still responds to TERM. The real arm, not a recorder, must stop it.
        (home / 'stall').touch()
        for _ in range(100):
            if (home / 'stalled').exists(): break
            time.sleep(0.05)
        require((home / 'stalled').exists(), 'holder did not enter its controlled stall')
        env['FM_WATCHDOG_ARM'] = str(home / 'bin/fm-watch-arm.sh')
        (home / 'config/watchdog-resume').write_text('touch "$FM_HOME/state/.last-watcher-beat"\n')
        run([home / 'bin/fm-watchdog-check.sh'], env)
        time.sleep(1.1)
        result = run([home / 'bin/fm-watchdog-check.sh'], env)
        require(holder.poll() is not None, 'real arm left the proven stalled holder alive')
        log = (home / 'state/.watchdog.log').read_text()
        require('no CPU or beacon progress' in log and 'identity reverified' in log,
                'watchdog did not record the evidence authorizing the stop: ' + log)
    finally:
        import signal
        for child in (holder, session):
            child.send_signal(signal.SIGKILL)
            child.wait()
case('watchdog_old_beacon_preserves_progress_but_stops_proven_stall', watchdog)

def summary():
    home, env = fixture('summary')
    document = dict(schema='fm-secondmate-home-summary.v1', hold_classifier_schema='fm-captain-hold-buckets.v1',
                    home=str(home), generated='2026-10-23T00:00:00Z', generated_epoch=1792713600,
                    valid=True, state='working', invalidity={}, active_children=[], decisions_open=[],
                    holds=[], queued=[], landed=[], endpoints=[], counts={}, omitted=[])
    script(home / 'bin/fm-fleet-snapshot.sh', "python3 - <<'SLOW'\n" + busy +
           'print(' + repr(json.dumps(document)) + ')\nSLOW\n')
    env['FM_HOME_SUMMARY_TIMEOUT'] = '1'
    result = run([home / 'bin/fm-home-summary-refresh.sh'], env)
    require(result.returncode == 0, f'productive refresh stopped: {result.returncode} {result.stderr}')
    require(json.loads((home / 'state/home-summary.json').read_text()) == document,
            'the slow complete summary was not published')
case('summary_slow_cpu_producer_publishes', summary)

def crew():
    home, env = fixture('crew')
    wt = home / 'projects/task'
    wt.mkdir()
    for args in (['init', '-q'], ['-c', 'user.name=test', '-c', 'user.email=test@example.invalid',
                                'commit', '--allow-empty', '-qm', 'fixture'], ['checkout', '-qb', 'fm/slow']):
        subprocess.run(['git', '-C', str(wt), *args], check=True, capture_output=True)
    head = subprocess.check_output(['git', '-C', str(wt), 'rev-parse', 'HEAD'], text=True).strip()
    (home / 'state/slow.meta').write_text(f'window=fm:fm-slow\nkind=ship\nharness=claude\nworktree={wt}\n')
    answer = f'''run:
  id: "01SLOW"
  branch: fm/slow
  status: running
  head: "{head}"
  pr: ""
  findings: none
  steps[2]{{step,status,findings,duration_ms}}:
    intent,completed,0,0
    review,running,0,0
'''
    script(home / 'fakebin/no-mistakes', "python3 - <<'SLOW'\n" + busy +
           'print(' + repr(answer) + ')\nSLOW\n')
    script(home / 'fakebin/tmux', 'exit 1\n')
    env['FM_CREW_STATE_NM_TIMEOUT'] = '1'
    result = run([home / 'bin/fm-crew-state.sh', 'slow'], env)
    require('state: working' in result.stdout and 'source: run-step' in result.stdout,
            'slow authoritative read was discarded: ' + result.stdout + result.stderr)
    require('skipped' not in result.stdout, 'productive read was reported skipped')
case('crew_slow_cpu_read_is_authoritative', crew)

def fleet():
    home, env = fixture('fleet')
    (home / 'state/slow.meta').write_text('window=fm:fm-slow\nkind=scout\nharness=claude\n')
    (home / 'data/backlog.md').write_text('## In flight\n- [ ] slow - Slow task (repo: firstmate) (kind: scout)\n\n## Queued\n\n## Done\n')
    script(home / 'bin/fm-crew-state.sh', "python3 - <<'SLOW'\n" + busy +
           "print('state: working · source: pane · productive read completed')\nSLOW\n")
    script(home / 'fakebin/tmux', "printf 'fm-slow\\n'\n")
    env['FM_SNAPSHOT_CREW_STATE_TIMEOUT'] = '1'
    result = run([home / 'bin/fm-fleet-snapshot.sh', '--home-input'], env)
    require(result.returncode == 0, result.stderr)
    document = json.loads(result.stdout)
    # Inspect the consumer-visible observation, independent of task ordering.
    require('productive read completed' in json.dumps(document),
            'slow task observation was discarded: ' + result.stdout)
case('fleet_slow_cpu_task_observation_is_included', fleet)

def summary_hung_lane():
    home, env = fixture('summary-hung-lane')
    for lane in ('quick', 'hung'):
        (home / f'state/{lane}.meta').write_text(f'window=fm:fm-{lane}\nkind=scout\nharness=claude\n')
    (home / 'data/backlog.md').write_text('## In flight\n- [ ] quick - Quick lane (repo: firstmate) (kind: scout)\n'
                                          '- [ ] hung - Hung lane (repo: firstmate) (kind: scout)\n\n## Queued\n\n## Done\n')
    # The hung lane's read never returns and does no work.
    script(home / 'bin/fm-crew-state.sh', 'case "$1" in hung) exec sleep 600 ;; esac\n'
           'printf "state: working · source: pane · %s lane observed\\n" "$1"\n')
    script(home / 'fakebin/tmux', "printf 'fm-quick\\nfm-hung\\n'\n")
    # The refresh worker's own owner is far longer than the lane bound.
    env.update(FM_SNAPSHOT_CREW_STATE_TIMEOUT='2', FM_HOME_SUMMARY_TIMEOUT='60')
    result = run([home / 'bin/fm-home-summary-refresh.sh'], env)
    require(result.returncode == 0, f'one hung lane lost the publication: {result.returncode} {result.stderr}')
    document = json.loads((home / 'state/home-summary.json').read_text())
    states = {endpoint['id']: endpoint['state'] for endpoint in document['endpoints']}
    require(states == {'quick': 'working', 'hung': 'unknown'}, 'lane states: ' + json.dumps(document['endpoints']))
    require(document['invalidity'].get('ids') == ['hung'], 'only the hung lane is unavailable: ' + json.dumps(document))
case('summary_worker_cuts_only_the_hung_lane', summary_hung_lane)

def reaped_between_samples():
    home, env = fixture('reaped-between-samples')
    record = home / 'state/progress.json'
    # The observer sees the shell before and after a whole CPU-producing child
    # lifetime, never the child itself. The shell blocks on stdin between events.
    child = subprocess.Popen(['bash', '-c',
        'printf "ready\\n"; read -r _; python3 -c "$1"; printf "reaped\\n"; read -r _',
        '_', 'import time\nstart = time.process_time()\n'
             'while time.process_time() - start < 1.1: sum(i*i for i in range(1000))'],
        env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    def check():
        return run([sys.executable, home / 'bin/fm-duration.py', 'progress-check',
                    record, str(child.pid), '1'], env)
    try:
        require(child.stdout.readline() == 'ready\n', 'shell did not reach its input wait')
        require(check().returncode == 0, 'the baseline sample was refused')
        time.sleep(1.2)
        child.stdin.write('work\n')
        child.stdin.flush()
        require(child.stdout.readline() == 'reaped\n', 'CPU child did not finish and get reaped')
        result = check()
        require(result.returncode == 0, 'CPU completed between samples was lost: ' + result.stderr)
        time.sleep(1.2)
        result = check()
        require(result.returncode == 124, 'a subsequently idle tree was not proven idle: ' + result.stderr)
    finally:
        child.terminate()
        child.wait()
case('reaped_child_cpu_between_observations_prevents_false_idle_then_true_idle_is_detected', reaped_between_samples)

def unavailable_ctypes():
    home, env = fixture('unavailable-ctypes')
    modules = home / 'modules'
    modules.mkdir()
    (modules / 'ctypes.py').write_text('raise ImportError("fixture: ctypes unavailable")\n')
    # Exercise the Darwin-only import boundary portably, before any native call.
    (modules / 'sitecustomize.py').write_text('import sys\nsys.platform = "darwin"\n')
    env.update(PYTHONPATH=str(modules), FM_PROC_ROOT_OVERRIDE=str(home / 'no-proc'))
    result = run([sys.executable, home / 'bin/fm-duration.py', 'keep-going', '1', '--',
                  sys.executable, '-c', busy + 'print("productive source completed")'], env)
    require(result.returncode == 0 and result.stdout == 'productive source completed\n',
            f'missing ctypes killed productive work: {result.returncode} {result.stdout} {result.stderr}')
    require(result.stderr.count('cpu_telemetry_unavailable:') == 1,
            'missing ctypes did not enter the one-warning blind-telemetry path: ' + result.stderr)
case('unavailable_ctypes_preserves_productive_work_with_blind_telemetry', unavailable_ctypes)

# Git Bash/MSYS: a /proc-only host whose ps cannot sample. Each fixture process
# publishes its own stat line (fields 3, 4, 14+15, 16 and 22) under FM_PROC_ROOT_OVERRIDE.
proc_stat = ('my $d = "$ENV{FM_PROC_ROOT_OVERRIDE}/$$"; mkdir $d;'
             'sub stat_line { open my $f, ">", "$d/stat.tmp" or die; '
             'my $state = $_[1] || "S"; my $waited = $_[2] || 0; '
             'print $f "$$ (fixture) $state 1 0 0 0 0 0 0 0 0 0 $_[0] 0 $waited 0 20 0 1 0 777\\n"; close $f; '
             'rename "$d/stat.tmp", "$d/stat" or die; }')
proc_programs = {
    'still': proc_stat + 'stat_line(0); sleep 30;',
    'growing': proc_stat + 'for my $i (1..16) { stat_line($i * 10); sleep 0.25; } exit 0;',
    # A stable one-process tree whose only growing CPU is its waited children's.
    'reaped': proc_stat + 'for my $i (1..16) { stat_line(0, "S", $i * 10); sleep 0.25; } exit 0;',
    # Short sleeping children keep changing tree membership without any CPU.
    'churn': proc_stat + 'stat_line(0); while (1) { my $c = fork; die unless defined $c; '
             'if (!$c) { my $e = "$ENV{FM_PROC_ROOT_OVERRIDE}/$$"; mkdir $e; open my $f, ">", "$e/stat" or die; '
             'print $f "$$ (fixture) S " . getppid() . " 0 0 0 0 0 0 0 0 0 0 0 0 0 20 0 1 0 $$\\n"; close $f; '
             'sleep 0.1; unlink "$e/stat"; rmdir $e; exit 0; } waitpid $c, 0; }',
    'blind': 'sleep 3; exit 0;',
    # Deliberately hold the exported counter below one accounting tick while
    # the real process burns CPU. Runnable state must prevent false idle proof.
    'rounded': proc_stat + 'stat_line(0, "R"); my $until = time + 4; '
               'while (time < $until) { my $n = 0; $n += $_*$_ for 1..1000; } print "completed\\n";',
}

def proc_runner(name, runner, program):
    home, env = fixture(f'proc-{runner}-{name}')
    proc = home / 'proc'
    proc.mkdir()
    tools = home / 'tools'
    tools.mkdir()
    script(tools / 'ps', 'exit 1\n')
    env['FM_PROC_ROOT_OVERRIDE'] = str(proc)
    if runner == 'python':
        env['PATH'] = str(tools) + ':' + env['PATH']
        command = [sys.executable, home / 'bin/fm-duration.py', 'keep-going', '1', '--',
                   'perl', '-MTime::HiRes=sleep', '-e', program]
    else:
        for tool in ('bash', 'perl', 'dirname'):
            (tools / tool).symlink_to(shutil.which(tool))
        env['PATH'] = str(tools)
        command = ['bash', '-c', '. "$1"; command -v python3 && exit 99; '
                   'fm_run_progress 1 perl -MTime::HiRes=sleep -e "$2"',
                   '_', home / 'bin/fm-timeout-lib.sh', program]
    started = time.monotonic()
    result = run(command, env)
    return result, time.monotonic() - started

def proc_sampler():
    for runner in ('python', 'perl'):
        result, elapsed = proc_runner('still', runner, proc_programs['still'])
        require(result.returncode == 124 and elapsed < 25,
                f'{runner}: a /proc-only tree with still CPU was not cut: {result.returncode} {elapsed:.1f}s {result.stderr}')
        result, _ = proc_runner('growing', runner, proc_programs['growing'])
        require(result.returncode == 0,
                f'{runner}: a /proc-only tree with growing CPU was cut: {result.returncode} {result.stderr}')
        result, elapsed = proc_runner('churn', runner, proc_programs['churn'])
        require(result.returncode == 124 and elapsed < 25,
                f'{runner}: a /proc-only tree changing only membership was not cut: {result.returncode} {elapsed:.1f}s {result.stderr}')
        result, _ = proc_runner('reaped', runner, proc_programs['reaped'])
        require(result.returncode == 0,
                f'{runner}: a /proc-only tree with growing waited-child CPU was cut: {result.returncode} {result.stderr}')
        result, _ = proc_runner('rounded', runner, proc_programs['rounded'])
        require(result.returncode == 0 and result.stdout == 'completed\n',
                f'{runner}: runnable work with rounded CPU was stopped: {result.returncode} {result.stderr}')
        result, elapsed = proc_runner('blind', runner, proc_programs['blind'])
        warnings = [line for line in result.stderr.splitlines() if line.startswith('cpu_telemetry_unavailable:')]
        require(result.returncode == 0 and elapsed >= 3, f'{runner}: work with no CPU sampler was stopped: '
                f'{result.returncode} {elapsed:.1f}s {result.stderr}')
        require(len(warnings) == 1 and 'hung work cannot be recovered' in warnings[0]
                and ' on ' + sys.platform + ';' in warnings[0],
                f'{runner}: missing one loud platform warning: {result.stderr}')
case('proc_only_sampler_cuts_still_keeps_growing_and_warns_when_blind', proc_sampler)

def host_sampler_run(name, runner, sampler, program):
    home, env = fixture(f'host-{runner}-{sampler}-{name}')
    if sampler == 'ps':
        env['FM_PROC_ROOT_OVERRIDE'] = str(home / 'no-proc')
    if runner == 'python':
        command = [sys.executable, home / 'bin/fm-duration.py', 'keep-going', '1', '--', *program]
    else:
        tools = home / 'no-python'
        tools.mkdir()
        for tool in ('bash', 'perl', 'ps', 'dirname'):
            (tools / tool).symlink_to(shutil.which(tool))
        env['PATH'] = str(tools)
        command = ['bash', '-c', '. "$1"; shift; command -v python3 && exit 99; fm_run_progress 1 "$@"',
                   '_', home / 'bin/fm-timeout-lib.sh', *program]
    child = subprocess.Popen(list(map(str, command)), env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = child.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        child.terminate()
        child.communicate(timeout=10)
        raise AssertionError(f'{runner}/{sampler}: {name} was still running after 30s')
    return child.returncode, stdout, stderr

def host_samplers():
    # Each real host sampler (/proc or native Darwin by default, ps when /proc
    # is hidden) judges CPU at the same 0.01 s resolution.
    poll = [sys.executable, '-c', 'import time\nwhile True: time.sleep(0.05)']
    burst = ['bash', '-c', '"$1" -c "$2"; sleep 0.5; echo completed', '_', sys.executable, busy]
    for runner in ('python', 'perl'):
        for sampler in ('host', 'ps'):
            code, _, stderr = host_sampler_run('poll', runner, sampler, poll)
            require(code == 124, f'{runner}/{sampler}: a timed-poll idle process was not stopped: {code} {stderr}')
            code, stdout, stderr = host_sampler_run('burst', runner, sampler, burst)
            require(code == 0 and stdout == 'completed\n',
                    f'{runner}/{sampler}: a reaped CPU burst was stopped: {code} {stdout} {stderr}')
case('host_samplers_stop_timed_poll_idle_and_keep_reaped_cpu_burst', host_samplers)

import select

def holder_fixture(name, stale, program='while True: sum(i*i for i in range(1000))'):
    home, env = fixture(name)
    env.update(FM_GUARD_GRACE='1', FM_WATCHER_STALE_GRACE='1', FM_WATCHER_STALL_BOUND='1',
               FM_ARM_CONFIRM_TIMEOUT='1', FM_ARM_ATTACH_POLL='0.1', FM_POLL='1',
               FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999',
               FM_WATCH_HANDLING_SUCCESSOR='1')
    # A watcher busy in a long handling turn: identity-matched, CPU advancing.
    holder = subprocess.Popen([sys.executable, '-c', program, str(home)])
    lock = home / 'state/.watch.lock'
    lock.mkdir()
    identity = run(['bash', '-c', '. "$1"; fm_pid_identity "$2"', '_', home / 'bin/fm-wake-lib.sh',
                    str(holder.pid)], env).stdout.strip()
    require(bool(identity), 'holder identity missing')
    for key, value in {'pid': str(holder.pid), 'pid-identity': identity, 'fm-home': str(home),
                       'watcher-path': str(home / 'bin/fm-watch.sh')}.items():
        (lock / key).write_text(value + '\n')
    beat = home / 'state/.last-watcher-beat'
    beat.touch()
    if stale:
        os.utime(beat, (1, 1))
    return home, env, holder, beat

def stop_process(child):
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()

def contender():
    home, env, holder, beat = holder_fixture('contender', True)
    child = None
    try:
        child = subprocess.Popen([str(home / 'bin/fm-watch.sh')], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        until = time.monotonic() + 20
        while child.poll() is None and holder.poll() is None and time.monotonic() < until:
            time.sleep(0.05)
        require(holder.poll() is None, 'contender terminated a productive identity-matched old-beacon holder')
        out, err = child.communicate()
        require(child.returncode == 0 and 'already running pid ' + str(holder.pid) in out,
                'contender did not preserve the existing cycle: ' + out + err)
    finally:
        stop_process(child)
        stop_process(holder)
case('contender_preserves_productive_old_beacon_holder', contender)

def attached(stale):
    home, env, holder, beat = holder_fixture('attached-old' if stale else 'attached-aging', stale)
    import threading
    stop_beacon = threading.Event()
    def fresh_until_attached():
        while not stop_beacon.is_set():
            beat.touch()
            stop_beacon.wait(0.05)
    publisher = None if stale else threading.Thread(target=fresh_until_attached)
    if publisher:
        publisher.start()
    arm_process = None
    try:
        arm_process = subprocess.Popen([str(home / 'bin/fm-watch-arm.sh')], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        until = time.monotonic() + 20
        first = ''
        while time.monotonic() < until:
            if select.select([arm_process.stdout], [], [], 0.1)[0]:
                first = arm_process.stdout.readline()
                break
            if arm_process.poll() is not None:
                break
        require(first.startswith('watcher: attached pid=' + str(holder.pid)),
                'productive holder was not followed: ' + first + ' holder-exit=' + str(holder.poll()))
        stop_beacon.set()
        if publisher:
            publisher.join()
        os.utime(beat, (1, 1))
        time.sleep(3)
        require(holder.poll() is None, 'attached arm terminated productive holder')
        require(arm_process.poll() is None, 'attached arm refused productive holder solely because its beacon aged')
    finally:
        stop_beacon.set()
        if publisher:
            publisher.join()
        stop_process(arm_process)
        stop_process(holder)
case('attached_arm_follows_productive_holder_after_beacon_ages', lambda: attached(False))
case('attached_arm_admits_productive_already_old_holder', lambda: attached(True))

def progress_check(home, env, pid):
    return run([sys.executable, home / 'bin/fm-duration.py', 'progress-check', home / 'state/.watchdog-progress',
                str(pid), '1', home / 'state/.last-watcher-beat'], env).returncode

def term_survivor():
    # Proven to make no progress, and it ignores TERM: the eviction fails, so the
    # contender keeps its refusal and nonzero exit instead of calling it running.
    home, env, holder, beat = holder_fixture('term-survivor', True,
        'import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(300)')
    try:
        first = run([home / 'bin/fm-watch.sh'], env)
        require(first.returncode == 0 and 'already running pid ' + str(holder.pid) in first.stdout,
                'a first sample must not prove a stall: ' + first.stdout + first.stderr)
        time.sleep(1.5)
        second = run([home / 'bin/fm-watch.sh'], env)
        require(holder.poll() is None, 'the TERM-ignoring holder exited')
        require(second.returncode != 0 and 'heartbeat is stale' in second.stderr
                and 'already running' not in second.stdout,
                'a proven-stalled holder that survived TERM was reported running: '
                + str(second.returncode) + second.stdout + second.stderr)
    finally:
        holder.kill()
        holder.wait()
case('contender_refuses_a_proven_stalled_holder_that_survives_term', term_survivor)

def resumed_holder():
    # Proven idle when the arm samples it, then working again before the arm's
    # child samples: the child stands down and the arm attaches, not FAILED.
    # The holder marks that its CPU advanced, and the child's real watcher waits
    # for that mark, so the child always samples after the holder resumed.
    program = ('import os, sys, time\nhome = sys.argv[1]\n'
               'fifo = os.path.join(home, "holder-resume.fifo")\nos.mkfifo(fifo)\n'
               'fd = os.open(fifo, os.O_RDWR)\n'
               'open(os.path.join(home, "holder-idle"), "w").close()\n'
               'os.read(fd, 1)\nos.close(fd)\n'
               'start = time.process_time()\n'
               'while time.process_time() - start < 0.1: sum(i*i for i in range(1000))\n'
               'open(os.path.join(sys.argv[1], "holder-resumed"), "w").close()\n'
               'while True: sum(i*i for i in range(1000))')
    home, env, holder, beat = holder_fixture('resumed-holder', True, program)
    shutil.copy2(home / 'bin/fm-watch.sh', home / 'bin/fm-watch-real.sh')
    # A FIFO read consumes no CPU while idle; the arm's child releases it only
    # after the arm has sampled the stall and created its output file.
    script(home / 'bin/fm-watch.sh', 'printf x > "$FM_HOME/holder-resume.fifo"\n'
           'for _ in $(seq 250); do [ -e "$FM_HOME/holder-resumed" ] && break; sleep 0.02; done\n'
           'exec bash "$FM_HOME/bin/fm-watch-real.sh" "$@"\n')
    arm_process = None
    try:
        until = time.monotonic() + 20
        while not (home / 'holder-idle').exists() and time.monotonic() < until:
            time.sleep(0.02)
        require((home / 'holder-idle').exists(), 'the holder never reached its blocking FIFO read')
        progress_check(home, env, holder.pid)
        time.sleep(1.5)
        require(progress_check(home, env, holder.pid) == 124, 'the idle holder was not proven stalled first')
        arm_process = subprocess.Popen([str(home / 'bin/fm-watch-arm.sh')], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        until = time.monotonic() + 20
        lines = []
        while time.monotonic() < until and arm_process.poll() is None:
            if select.select([arm_process.stdout], [], [], 0.1)[0]:
                line = arm_process.stdout.readline()
                lines.append(line)
                if line.startswith('watcher: attached pid=') or line.startswith('watcher: FAILED'):
                    break
        require(any(line.startswith('watcher: attached pid=' + str(holder.pid)) for line in lines),
                'the arm did not attach to the resumed holder: ' + ''.join(lines))
        require(not any('FAILED' in line for line in lines), 'the arm failed a resumed holder: ' + ''.join(lines))
        time.sleep(2)
        require(holder.poll() is None and arm_process.poll() is None,
                'the resumed holder or its attached arm ended')
    finally:
        stop_process(arm_process)
        stop_process(holder)
case('arm_attaches_to_a_holder_that_resumed_while_its_child_started', resumed_holder)

def load_collector():
    spec = importlib.util.spec_from_file_location('progress_collector', root / 'bin/fm_open_loops.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module

def collector_read():
    home, env = fixture('collector-read')
    (home / 'config/open-loops.json').write_text('{"command_timeout_seconds":1}')
    os.environ.update(env)
    module = load_collector()
    collector = module.Collector(home, int(time.time()))
    answer = collector.run([sys.executable, '-c', busy + 'print("slow source returned")'])
    require(answer.strip() == 'slow source returned', 'collector lost the slow source')
case('collector_slow_cpu_source_returns', collector_read)

def collector_total():
    home, env = fixture('collector-total')
    (home / 'config/open-loops.json').write_text('{"command_timeout_seconds":1}')
    os.environ.update(env)
    module = load_collector()
    # Exercise the actual CLI's collection/publication boundary beyond its old
    # overall alarm. No subprocess wait is involved in this productive phase.
    def productive_collect(self):
        until = time.monotonic() + 11
        while time.monotonic() < until:
            sum(i*i for i in range(1000))
        self.add('coverage', 'completed slow collection', 'inspect evidence', None)
    module.Collector.collect = productive_collect
    sys.argv = ['fm-open-loops', '--json']
    import contextlib
    import io
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        code = module.main()
    require(code == 0 and 'completed slow collection' in output.getvalue()
            and 'ledger degraded' not in output.getvalue(), output.getvalue())
case('collector_productive_total_outlives_old_alarm', collector_total)

def perl_progress():
    home, env = fixture('perl-progress')
    tools = home / 'no-python'
    tools.mkdir()
    for name in ('bash', 'perl', 'ps', 'dirname'):
        executable = shutil.which(name)
        require(executable is not None, 'required progress fallback tool missing: ' + name)
        (tools / name).symlink_to(executable)
    env['PATH'] = str(tools)
    cpu = '''my $pid = fork; die unless defined $pid;
if (!$pid) { my $until = time + 4; while (time < $until) { my $n = 0; $n += $_*$_ for 1..1000; } exit 0; }
waitpid($pid,0); sleep 0.5; print "subtree completed\\n";'''
    output = '''$|=1; for (1..12) { print "tick\\n"; sleep 0.25; } print "stream completed\\n";'''
    for program, expected in ((cpu, 'subtree completed\n'),
                              (output, 'tick\n' * 12 + 'stream completed\n')):
        result = run(['bash', '-c', '. "$1"; command -v python3 && exit 99; fm_run_progress 1 perl -MTime::HiRes=time,sleep -e "$2"',
                      '_', home / 'bin/fm-timeout-lib.sh', program], env)
        require(result.returncode == 0 and result.stdout == expected,
                'Python-free progress was discarded: ' + str(result.returncode) + result.stdout + result.stderr)
case('python_free_runner_preserves_subtree_cpu_and_output_progress', perl_progress)

def perl_stall():
    home, env = fixture('perl-stall')
    tools = home / 'no-python'
    tools.mkdir()
    for name in ('bash', 'perl', 'ps', 'dirname'):
        (tools / name).symlink_to(shutil.which(name))
    env['PATH'] = str(tools)
    program = '$|=1; my $pid=fork; die unless defined $pid; if (!$pid) {sleep 120;exit;} print "$pid\\n"; sleep 120;'
    result = run(['bash', '-c', '. "$1"; command -v python3 && exit 99; fm_run_progress 1 perl -e "$2"',
                  '_', home / 'bin/fm-timeout-lib.sh', program], env)
    require(result.returncode == 124, 'silent source was not stopped for inactivity: ' + str(result.returncode) + result.stderr)
    pid = int(result.stdout.strip())
    for _ in range(100):
        process = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
        if process.returncode == 1 or process.stdout.strip().startswith('Z'):
            break
        time.sleep(0.05)
    else:
        raise AssertionError('Python-free no-progress stop left a live descendant')
case('python_free_runner_stops_true_inactivity_and_reaps_descendants', perl_stall)

sys.exit(bool(failures))
PY
