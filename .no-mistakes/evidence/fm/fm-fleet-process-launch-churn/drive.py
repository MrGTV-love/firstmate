#!/usr/bin/env python3
"""Drive the real bin/fm-watch.sh in a disposable marked lab home.

Usage: python3 -I drive.py REPO LABHOME_HELPER_REPO OUTDIR SCENARIO [noperl]
Scenarios: slow, startup, complete, descendant, timeout
PATH shims log "<pid>\t<ppid>\t<name>" for every PATH-resolved external start.
"""
import json, os, pathlib, shlex, shutil, signal, subprocess, sys, time

repo = pathlib.Path(sys.argv[1]).resolve()
helper_repo = pathlib.Path(sys.argv[2]).resolve()
out = pathlib.Path(sys.argv[3]).resolve(); out.mkdir(parents=True, exist_ok=True)
scenario = sys.argv[4]
noperl = len(sys.argv) > 5 and sys.argv[5] == 'noperl'
real_path = os.environ['PATH']

shim = out / 'shim'; shim.mkdir(exist_ok=True)
names = set()
for d in real_path.split(':'):
    try:
        names.update(p.name for p in pathlib.Path(d).iterdir() if p.is_file() and os.access(p, os.X_OK))
    except OSError:
        pass
for name in names:
    if noperl and name.startswith('perl'):
        continue
    real = shutil.which(name, path=real_path)
    if not real:
        continue
    p = shim / name
    p.write_text('#!/bin/bash\nprintf \'%s\\t%s\\t%s\\n\' "$$" "$PPID" ' + shlex.quote(name)
                 + ' >> "$FM_COST_LOG"\nexec ' + shlex.quote(real) + ' "$@"\n')
    p.chmod(0o700)

tmp = os.environ.get('TMPDIR', '/tmp')
lab = pathlib.Path(subprocess.run(['mktemp', '-d', f'{tmp.rstrip("/")}/fm-lab.XXXXXX'],
                                  check=True, capture_output=True, text=True).stdout.strip())
subprocess.run(['/bin/bash', str(helper_repo / 'bin/fm-lab-home.sh'), 'create', str(lab)],
               check=True, stdout=subprocess.DEVNULL)
state = lab / 'state'
log = out / 'launches.tsv'; log.write_text('')

env = {k: v for k, v in os.environ.items()
       if k not in ('NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE',
                    'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_ROOT')}
env.update(FM_HOME=str(lab), FM_POLL='15', FM_COST_LOG=str(log), FM_LAB_STATE=str(state))
env['PATH'] = str(shim) if noperl else str(shim) + ':' + real_path

checks = {
    'slow': ('printf started > "$FM_LAB_STATE/started"\nsleep 90\nprintf completed\n', '120'),
    'complete': ('printf started > "$FM_LAB_STATE/started"\nsleep 5\n'
                 '/usr/bin/python3 -I -c "import time; print(repr(time.time()))" > "$FM_LAB_STATE/finished"\n'
                 'printf check-output-ok\n', '30'),
    'descendant': ('printf started > "$FM_LAB_STATE/started"\n'
                   '( trap "" TERM; exec /bin/sleep 60 ) &\nprintf "%s\\n" "$!" > "$FM_LAB_STATE/descendant-pid"\n'
                   '/usr/bin/python3 -I -c "import time; print(repr(time.time()))" > "$FM_LAB_STATE/finished"\n'
                   'printf leader-finished\n', '30'),
    'timeout': ('printf "%s\\n" "$$" > "$FM_LAB_STATE/started"\ntrap "" TERM\n/bin/sleep 60\nprintf must-not-complete\n', '3'),
}
if scenario in checks:
    body, tmo = checks[scenario]
    c = state / f'{scenario}.check.sh'
    c.write_text('#!/bin/bash\n' + body); c.chmod(0o700)
    subprocess.run(['/bin/bash', str(repo / 'bin/fm-check-register.sh'), scenario], env=env, check=True,
                   stdout=subprocess.DEVNULL)
    env['FM_CHECK_TIMEOUT'] = tmo
for marker in ('.last-check', '.last-heartbeat', '.last-home-summary', '.last-open-loops', '.last-procevent-reconcile'):
    if marker == '.last-check' and scenario in checks:
        continue
    (state / marker).touch()
(state / 'home-summary.json').write_text('{}\n')
(state / 'open-loops.json').write_text(json.dumps(dict(schema='fm-open-loops.v1', generated_epoch=int(time.time()),
                                                      home=str(lab), complete=True, rows=[])) + '\n')
log.write_text('')

def launches(lines, ppid=None):
    by = {}
    for line in lines:
        pid, pp, name = line.split('\t')
        if ppid is None or pp == str(ppid):
            by[pid] = name
    counts = {}
    for n in by.values():
        counts[n] = counts.get(n, 0) + 1
    return dict(total=len(by), commands=dict(sorted(counts.items())))

result = dict(repo=str(repo), scenario=scenario, noperl=noperl, lab=str(lab))
stdout_f = (out / 'stdout').open('w'); stderr_f = (out / 'stderr').open('w')
started = time.monotonic()
p = subprocess.Popen(['/bin/bash', str(repo / 'bin/fm-watch.sh')], env=env, stdout=stdout_f, stderr=stderr_f,
                     start_new_session=True, cwd=str(lab))
result['watcher_pid'] = p.pid
beat = state / '.last-watcher-beat'
try:
    if scenario == 'startup':
        while not beat.exists():
            if p.poll() is not None:
                raise RuntimeError('watcher exited during startup')
            time.sleep(0.02)
        result['startup_seconds'] = round(time.monotonic() - started, 3)
        result['startup_launches'] = launches(log.read_text().splitlines())
    else:
        marker = state / 'started'
        while not marker.exists():
            if p.poll() is not None:
                raise RuntimeError('watcher exited before check started')
            time.sleep(0.02)
        check_started = time.time()
        base_lines = len(log.read_text().splitlines())
        if scenario == 'slow':
            stale = 0.0
            end = time.monotonic() + 60
            while time.monotonic() < end:
                if p.poll() is not None:
                    raise RuntimeError('watcher exited during slow window')
                stale = max(stale, time.time() - beat.stat().st_mtime)
                time.sleep(0.5)
            window = log.read_text().splitlines()[base_lines:]
            result['window_seconds'] = 60
            result['max_beacon_age_seconds'] = round(stale, 2)
            result['window_all'] = launches(window)
            result['window_direct_children_of_watcher'] = launches(window, p.pid)
            result['watcher_alive_after_window'] = p.poll() is None
        elif scenario == 'timeout':
            check_pid = int(marker.read_text().strip())
            gone_at = None
            stale = 0.0
            end = time.monotonic() + 30
            while time.monotonic() < end:
                if p.poll() is not None:
                    break
                stale = max(stale, time.time() - beat.stat().st_mtime)
                if gone_at is None:
                    try:
                        os.kill(check_pid, 0)
                    except ProcessLookupError:
                        gone_at = time.time() - check_started
                time.sleep(0.1)
            window = log.read_text().splitlines()[base_lines:]
            result['check_timeout_seconds'] = 3
            result['check_pid_gone_after_seconds'] = None if gone_at is None else round(gone_at, 2)
            sl = subprocess.run(['pgrep', '-f', '/bin/sleep 60'], capture_output=True, text=True).stdout.split()
            leftover = []
            for s in sl:
                pp = subprocess.run(['ps', '-o', 'ppid=', '-p', s], capture_output=True, text=True).stdout.strip()
                if pp == str(check_pid):
                    leftover.append(s)
            result['check_children_left'] = leftover
            result['watcher_alive_30s_after_check_start'] = p.poll() is None
            result['max_beacon_age_seconds'] = round(stale, 2)
            result['window_direct_children_of_watcher'] = launches(window, p.pid)
        else:
            rc = p.wait(timeout=90)
            exited = time.time()
            result['watcher_exit_status'] = rc
            fin = float((state / 'finished').read_text().strip())
            result['check_finish_to_watcher_exit_seconds'] = round(exited - fin, 3)
            result['stdout'] = (out / 'stdout').read_text()
            window = log.read_text().splitlines()[base_lines:]
            result['window_direct_children_of_watcher'] = launches(window, p.pid)
            if scenario == 'descendant':
                dpid = int((state / 'descendant-pid').read_text().strip())
                time.sleep(0.5)
                try:
                    os.kill(dpid, 0); alive = True
                except ProcessLookupError:
                    alive = False
                result['term_ignoring_descendant_alive_after_exit'] = alive
finally:
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL); p.wait()
    result['stderr_tail'] = (out / 'stderr').read_text()[-1500:]
    (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    shutil.rmtree(lab, ignore_errors=True)
    shutil.rmtree(shim, ignore_errors=True)
print(json.dumps(result, indent=2))
