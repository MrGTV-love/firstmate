import os, pathlib, subprocess, time, signal
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path(__file__).resolve().parent
SCAN=WORK/'identity-scan'; SCAN.mkdir()
ENV=os.environ.copy()
for k in list(ENV):
    if k.startswith('FM_') or k in ('STATE','TMUX','BASH_ENV','NO_MISTAKES_GATE'): ENV.pop(k,None)
ENV['TMPDIR']=str(WORK)
TRACKED={}
def identity(pid):
    return subprocess.run(['ps','-p',str(pid),'-ww','-o','lstart=','-o','command='],env={**ENV,'LC_ALL':'C','COLUMNS':'10000'},capture_output=True,text=True).stdout.strip()
def wait_until(fn,seconds=15):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        value=fn()
        if value: return value
        time.sleep(.01)
    raise AssertionError('synchronization timed out')
def register(pid,cmd):
    got=wait_until(lambda: identity(pid) if identity(pid).endswith(cmd) else None)
    TRACKED[pid]=got
    return got
def detached(args):
    pidfile=WORK/f'identity-pid-{time.monotonic_ns()}'
    launcher='import subprocess,sys; p=subprocess.Popen(sys.argv[2:],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); open(sys.argv[1],"w").write(str(p.pid))'
    subprocess.run(['python3','-c',launcher,str(pidfile),*map(str,args)],env=ENV,check=True)
    pid=int(pidfile.read_text()); register(pid,' '.join(map(str,args)))
    return pid
try:
    for mode in ('direct','descendant'):
        home=SCAN/f'fm-{mode}'; home.mkdir()
        owner=subprocess.Popen(['sleep','240'],env=ENV)
        oid=register(owner.pid,'sleep 240')
        (home/'.fm-test-fixture').write_text(f'{owner.pid}\n{oid}\n')
        owner.kill(); owner.wait()
        fifo=home/'transition'; os.mkfifo(fifo)
        script=home/'replacement.sh'
        script.write_text('#!/usr/bin/env bash\nprintf ready > "$2"\nread -r line < "$1"\nexec sleep 240\n')
        if mode=='direct':
            target=detached(['bash',script,fifo,home/'ready'])
            parent=None
        else:
            parent_script=home/'parent.sh'
            parent_script.write_text('#!/usr/bin/env bash\nbash "$1" "$2" "$3" &\nprintf "%s\\n" "$!" > "$4"\nsleep 240\n')
            parent=detached(['bash',parent_script,script,fifo,home/'ready',home/'child.pid'])
            wait_until(lambda:(home/'child.pid').exists())
            target=int((home/'child.pid').read_text())
            register(target,f'bash {script} {fifo} {home}/ready')
        wait_until(lambda:(home/'ready').exists())
        original=TRACKED[target]
        before=set(WORK.glob('fm-test-reap.*'))
        reaper=subprocess.Popen([str(ROOT/'bin/fm-test-reap-orphans.sh'),'--tmpdir',str(SCAN)],env=ENV,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        TRACKED[reaper.pid]=register(reaper.pid,f'bash {ROOT}/bin/fm-test-reap-orphans.sh --tmpdir {SCAN}')
        state=wait_until(lambda:next((d for d in WORK.glob('fm-test-reap.*') if d not in before and (d/'lsof').exists()),None),30)
        # Stop the actual reaper after its real process snapshot, before selection
        # and signaling. No ps/kill/lsof shims or invented process responses.
        os.kill(reaper.pid,signal.SIGSTOP)
        wait_until(lambda:'T' in subprocess.run(['ps','-p',str(reaper.pid),'-o','stat='],capture_output=True,text=True).stdout)
        lines=(state/'ps').read_text().splitlines()
        row=next(line for line in lines if line.strip().split()[0]==str(target))
        assert str(script) in row
        print(f'{mode}: actual ownership snapshot: {row.strip()}',flush=True)
        with fifo.open('w') as f: f.write('replace\n')
        replacement=register(target,'sleep 240')
        assert replacement!=original
        print(f'{mode}: same PID after exec: {replacement}',flush=True)
        os.kill(reaper.pid,signal.SIGCONT)
        out,err=reaper.communicate(timeout=90)
        print('$ bin/fm-test-reap-orphans.sh --tmpdir '+str(SCAN),flush=True)
        print(out,end='',flush=True); print(err,end='',flush=True)
        print(f'{mode}: reaper_exit={reaper.returncode} replacement_still_alive={identity(target)==replacement}',flush=True)
        assert reaper.returncode==0 and identity(target)==replacement
        assert f'reaped pid={target} ' not in out
        if parent:
            wait_until(lambda:identity(parent)!=TRACKED[parent])
            assert f'reaped pid={parent} ' in out
        if identity(target)==replacement: os.kill(target,signal.SIGKILL)
    print('REAL IDENTITY TRANSITIONS PRESERVED',flush=True)
finally:
    for pid,original in TRACKED.items():
        if identity(pid)==original:
            try: os.kill(pid,signal.SIGCONT); os.kill(pid,signal.SIGKILL)
            except ProcessLookupError: pass
