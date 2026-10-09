#!/Users/charlesabrooker/.pyenv/versions/3.13.6/bin/python3
import os,sys,subprocess,signal,time,json,fcntl,pathlib
real='/Users/charlesabrooker/.local/bin/shellcheck'
if sys.argv[1:] == ['--version']:
    os.execv(real,[real,*sys.argv[1:]])
case=pathlib.Path(os.environ['FM_LIVE_CASE'])
child=subprocess.Popen([real,*sys.argv[1:]],close_fds=False)
os.kill(child.pid, signal.SIGSTOP)
with open(case/'events.lock','a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    (case/f'active.{child.pid}').write_text(str(os.getpid()))
    with open(case/'events.jsonl','a') as log:
        log.write(json.dumps(dict(event='started',pid=child.pid,wrapper=os.getpid(),time=time.time(),args=sys.argv[1:]))+'\n')
try:
    until=time.monotonic()+90
    while not (case/'release').exists():
        if time.monotonic()>until: raise RuntimeError('controller did not release actual ShellCheck')
        time.sleep(.02)
    os.kill(child.pid,signal.SIGCONT)
    rc=child.wait(timeout=30)
finally:
    if child.poll() is None:
        os.kill(child.pid,signal.SIGCONT)
        child.kill(); child.wait()
    (case/f'active.{child.pid}').unlink(missing_ok=True)
    with open(case/'events.jsonl','a') as log:
        log.write(json.dumps(dict(event='finished',pid=child.pid,time=time.time(),rc=child.returncode))+'\n')
sys.exit(rc)
