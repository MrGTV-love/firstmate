#!/usr/bin/env python3
"""R13-F2. Runs a real fm-watch.sh with a piped stderr, as Pi runs the arm. A shim holds only the detector
for 25 s. Reports when the watcher exits and when its stderr closes, for HEAD and the pre-fix tree."""
import os, subprocess, sys, tempfile, time, shutil, stat, pathlib, signal
wt, label, root = sys.argv[1:4]
real_py = shutil.which('python3')
home = tempfile.mkdtemp(prefix='fm-lab-probe.')
env_txt = subprocess.run([f'{wt}/bin/fm-lab-home.sh', 'create', home], capture_output=True, text=True).stdout.strip() or home
home = env_txt
state = pathlib.Path(home) / 'state'
fb = pathlib.Path(tempfile.mkdtemp(prefix='fm-fb.'))
started = fb / 'started'
(fb / 'python3').write_text(f'''#!/usr/bin/env bash
case "${{1:-}}" in */fm-guard-workarounds.py) : > "{started}"; sleep 25; exit 0;; esac
exec "{real_py}" "$@"
''')
(fb / 'python3').chmod(0o755)
hb = state / '.last-heartbeat'; hb.touch(); old = time.time() - 600; os.utime(hb, (old, old))
env = {k: v for k, v in os.environ.items() if k not in ('NO_MISTAKES_GATE', 'FM_TASK_ID', 'FM_GUARD_EVENT_LOG', 'FM_GATE_REFUSE_BYPASS') and not k.endswith('_OVERRIDE')}
env.update(FM_POLL='1', FM_HOME=home, FM_HEARTBEAT='1', FM_HEARTBEAT_MAX='1', PATH=f'{fb}:{env["PATH"]}', TMUX_TMPDIR=str(fb))
p = subprocess.Popen([f'{root}/bin/fm-watch.sh'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, cwd=home, start_new_session=True)
t0 = time.time(); os.set_blocking(p.stderr.fileno(), False)
while not started.exists() and time.time() - t0 < 12 and p.poll() is None: time.sleep(0.05)
det = time.time()
print(f'{label}: detector started={started.exists()} after {det-t0:.2f}s')
deadline = det + 6
while p.poll() is None and time.time() < deadline: time.sleep(0.05)
how = 'exited on its own' if p.poll() is not None else 'stopped with SIGTERM after 6 s'
if p.poll() is None: p.send_signal(signal.SIGTERM)
p.wait(); ex = time.time()
closed = None
time.sleep(0.3)
pg = subprocess.run(['ps','-axo','pid=,pgid=,etime=,command='],capture_output=True,text=True).stdout
print(f'{label}: processes left in the watcher group 0.3 s after exit:')
for line in pg.splitlines():
    f=line.split(None,3)
    if len(f)==4 and f[1]==str(p.pid): print('   ', f[0], f[2], f[3].replace(home,'<lab>').replace(str(fb),'<fb>')[:130])
while time.time() - ex < 28:
    try:
        b = p.stderr.read()
    except BlockingIOError:
        b = None
    if b == b'':
        closed = time.time(); break
    time.sleep(0.05)
print(f'{label}: watcher {how} rc={p.returncode}; stderr close {"%.2fs after exit" % (closed-ex) if closed else "not seen within 28 s"}')
try: os.killpg(p.pid, signal.SIGKILL)
except OSError: pass
subprocess.run([f'{wt}/bin/fm-lab-home.sh', 'teardown', home], capture_output=True); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(fb, ignore_errors=True)
