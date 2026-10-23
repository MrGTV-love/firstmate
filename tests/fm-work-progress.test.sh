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

def omp_readiness():
    home, env = fixture('omp-readiness')
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
    env.update(FM_OMP_ARM_READY_TIMEOUT_MS='50', FM_WATCH_REARM_RETRY_LIMIT='1')
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
  for (let i = 0; i < 500 && sent.length === 0; i++) await new Promise(r=>setTimeout(r,100));
  if (!result.details.ok || !existsSync(`${process.env.FM_HOME}/ready-completed`)
      || sent.length !== 1 || !sent[0].includes('signal: slow readiness wake')
      || sent[0].includes('did not confirm'))
    throw new Error('productive readiness was retired: '+JSON.stringify({result,sent}));
} finally {await handlers.get('session_shutdown')({}, {});}
process.exit(0);
'''
    result = run(['node', '--input-type=module', '-e', js], env)
    require(result.returncode == 0, result.stdout + result.stderr)
case('omp_slow_readiness_is_not_retired', omp_readiness)

def claude_readiness():
    home, env = fixture('claude-readiness')
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
    until = time.monotonic() + 5
    while time.monotonic() < until: sum(i*i for i in range(1000))
    print(f'watcher: started pid={os.getpid()} (beacon fresh)', flush=True)
    (home / 'successor-completed').touch()
else:
    print(f'watcher: attached pid={os.getpid()} (beacon 2s)', flush=True)
    (home / 'state/.watcher-down').write_text('pending:downtime:fixture-generation\\n')
    print('signal: task.status done: fixture peer cycle ended', flush=True)
'''
    script(home / 'bin/fm-watch-arm.sh', 'exec python3 -c ' + __import__('shlex').quote(source) + '\n')
    env['FM_ARM_CONFIRM_TIMEOUT'] = '1'
    try:
        result = subprocess.run([str(fakeclaude), '-c',
            'printf "%s\\n" "$$" > "$FM_HOME/state/.lock"; "$FM_HOME/bin/fm-claude-stop-autoarm.sh"'],
            env=env, input='{"session_id":"slow-successor","stop_hook_active":false}\n',
            capture_output=True, text=True)
        require(result.returncode == 2 and (home / 'successor-completed').exists()
                and 'did not confirm' not in result.stderr,
                f'rc={result.returncode} completed={(home / "successor-completed").exists()} ' + result.stdout + result.stderr)
    finally:
        pidfile = home / 'successor-pid'
        if pidfile.exists():
            import signal
            try: os.kill(int(pidfile.read_text()), signal.SIGKILL)
            except ProcessLookupError: pass
case('claude_slow_successor_confirms_before_rewake', claude_readiness)

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

# Git Bash/MSYS: a /proc-only host whose ps cannot sample. Each fixture process
# publishes its own stat line (fields 4, 14+15 and 22) under FM_PROC_ROOT_OVERRIDE.
proc_stat = ('my $d = "$ENV{FM_PROC_ROOT_OVERRIDE}/$$"; mkdir $d;'
             'sub stat_line { open my $f, ">", "$d/stat.tmp" or die; '
             'print $f "$$ (fixture) S 1 0 0 0 0 0 0 0 0 0 $_[0] 0 0 0 20 0 1 0 777\\n"; close $f; '
             'rename "$d/stat.tmp", "$d/stat" or die; }')
proc_programs = {
    'still': proc_stat + 'stat_line(0); sleep 30;',
    'growing': proc_stat + 'for my $i (1..16) { stat_line($i * 10); sleep 0.25; } exit 0;',
    'blind': 'sleep 3; exit 0;',
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
        result, elapsed = proc_runner('blind', runner, proc_programs['blind'])
        warnings = [line for line in result.stderr.splitlines() if line.startswith('cpu_telemetry_unavailable:')]
        require(result.returncode == 0 and elapsed >= 3, f'{runner}: work with no CPU sampler was stopped: '
                f'{result.returncode} {elapsed:.1f}s {result.stderr}')
        require(len(warnings) == 1 and 'hung work cannot be recovered' in warnings[0]
                and ' on ' + sys.platform + ';' in warnings[0],
                f'{runner}: missing one loud platform warning: {result.stderr}')
case('proc_only_sampler_cuts_still_keeps_growing_and_warns_when_blind', proc_sampler)

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
waitpid($pid,0); print "subtree completed\\n";'''
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
