from pathlib import Path
import os, subprocess, time, json, shutil, signal
root = Path.cwd()
evidence = Path('/Users/charlesabrooker/.no-mistakes/evidence/01M48YDAJ274FP0KSXR35TAEYY')
home = root / '.live-validation/default-grace'
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_')) and k != 'TMUX'}
env.update(FM_HOME=str(home), TMPDIR=str(root / '.live-validation'), FM_CHECK_TIMEOUT='340', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999')
watch = None
samples = []
try:
    r = subprocess.run(['bash', 'bin/fm-lab-home.sh', 'create', str(home)], env=env, capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr)
    check = home / 'state/slow.check.sh'
    check.write_text('#!/usr/bin/env bash\ntouch "$FM_HOME/state/check-started"\nsleep 311\ntouch "$FM_HOME/state/check-finished"\nprintf "default-grace-slow-check-completed\\n"\n')
    check.chmod(0o700)
    r = subprocess.run(['bash', 'bin/fm-check-register.sh', 'slow'], env=env, capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr)
    with (evidence / 'default-grace-watcher.stdout.log').open('w') as out, (evidence / 'default-grace-watcher.stderr.log').open('w') as err:
        watch = subprocess.Popen(['bash', 'bin/fm-watch.sh'], env=env, stdout=out, stderr=err, start_new_session=True)
        deadline = time.monotonic() + 30
        while not (home / 'state/check-started').exists() and watch.poll() is None and time.monotonic() < deadline: time.sleep(.1)
        if not (home / 'state/check-started').exists(): raise RuntimeError('check did not start')
        started = time.monotonic()
        while time.monotonic() - started < 306:
            time.sleep(min(15, 306 - (time.monotonic() - started)))
            samples.append({'elapsed_seconds': round(time.monotonic() - started, 3), 'watcher_alive': watch.poll() is None, 'check_finished': (home / 'state/check-finished').exists(), 'beacon_age_seconds': round(time.time() - (home / 'state/.last-watcher-beat').stat().st_mtime, 3)})
        health = subprocess.run(['bash', '-c', '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"', '_', str(root / 'bin/fm-wake-lib.sh'), str(home / 'state'), str(root / 'bin/fm-watch.sh'), str(home)], env=env, capture_output=True, text=True)
        samples.append({'stage': 'one-pass-beyond-default-300-second-grace', 'elapsed_seconds': round(time.monotonic() - started, 3), 'health_exit': health.returncode, 'finished': (home / 'state/check-finished').exists(), 'grace_override_present': 'FM_GUARD_GRACE' in env or 'FM_WATCHER_STALE_GRACE' in env})
        rc = watch.wait(timeout=40)
    output = (evidence / 'default-grace-watcher.stdout.log').read_text()
    queue = (home / 'state/.wake-queue').read_text()
    samples.append({'stage': 'completed', 'exit': rc, 'stdout': output, 'wake_queue': queue})
    passed = health.returncode == 0 and rc == 0 and all(x.get('watcher_alive', True) for x in samples) and 'default-grace-slow-check-completed' in output
    result = {'passed': passed, 'samples': samples}
except Exception as exc:
    result = {'passed': False, 'error': str(exc), 'samples': samples}
finally:
    if watch is not None and watch.poll() is None:
        watch.terminate()
        try: watch.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(watch.pid, signal.SIGKILL)
            watch.wait()
    shutil.rmtree(home, ignore_errors=True)
(evidence / 'default-grace-progress.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
raise SystemExit(0 if result['passed'] else 1)
