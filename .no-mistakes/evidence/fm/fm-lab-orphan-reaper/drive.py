import os, pathlib, subprocess, time, shutil, signal, json
ROOT = pathlib.Path(__file__).resolve().parents[1]
WORK = pathlib.Path(__file__).resolve().parent
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith('FM_') or key in ('STATE', 'TMUX', 'BASH_ENV', 'NO_MISTAKES_GATE'):
        ENV.pop(key, None)
ENV.update(TMPDIR=str(WORK), GOCACHE=str(WORK/'go-cache'), GOENV='off', GOTOOLCHAIN='local')
PROCS = {}
SOCKET_DIR = ROOT/'.v'
SOCKET = SOCKET_DIR/f'tmux-{os.getuid()}'/'x'
SCAN = WORK/'manual-scan'
SCAN.mkdir()

def command(args, env=None, cwd=ROOT, expected=0, timeout=90):
    e = ENV.copy()
    e.update(env or {})
    print('$', ' '.join(map(str, args)), flush=True)
    result = subprocess.run(list(map(str,args)), env=e, cwd=cwd, text=True, capture_output=True, timeout=timeout)
    print(result.stdout, end='', flush=True)
    print(result.stderr, end='', flush=True)
    print('exit=', result.returncode, flush=True)
    if expected is not None:
        assert result.returncode == expected, result
    return result

def snapshot(pid):
    result = subprocess.run(['ps','-p',str(pid),'-ww','-o','lstart=','-o','command='],env={**ENV,'LC_ALL':'C','COLUMNS':'10000'},capture_output=True,text=True)
    return result.stdout.strip() if result.returncode == 0 else ''

def register(pid, expected=None):
    deadline = time.monotonic()+8
    while time.monotonic()<deadline:
        identity = snapshot(pid)
        if identity and (expected is None or identity.endswith(expected)):
            PROCS[pid] = identity
            return identity
        time.sleep(.05)
    raise AssertionError(f'process {pid} did not initialize: {identity}')

def alive(pid):
    return snapshot(pid) == PROCS[pid]

def status(label,pid):
    current = snapshot(pid)
    ps = subprocess.run(['ps','-p',str(pid),'-o','pid=,ppid=,stat=,command='],capture_output=True,text=True)
    print(f'{label}: pid={pid} same_identity={current == PROCS[pid]}\n{ps.stdout.strip()}', flush=True)

def wait_until(predicate, timeout=15):
    deadline = time.monotonic()+timeout
    while time.monotonic()<deadline:
        if predicate(): return
        time.sleep(.05)
    raise AssertionError('condition not reached')

def detached(args, env=None, cwd=ROOT, log=None):
    pidfile = WORK/f'detach-{time.monotonic_ns()}.pid'
    e = ENV.copy(); e.update(env or {})
    launch = 'import subprocess,sys; p=subprocess.Popen(sys.argv[2:],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); open(sys.argv[1],"w").write(str(p.pid))'
    subprocess.run(['python3','-c',launch,str(pidfile),*map(str,args)],cwd=cwd,env=e,check=True)
    pid=int(pidfile.read_text())
    register(pid, ' '.join(map(str,args)))
    wait_until(lambda: subprocess.run(['ps','-p',str(pid),'-o','ppid='],capture_output=True,text=True).stdout.strip()=='1')
    return pid

def owner():
    proc=subprocess.Popen(['sleep','240'],env=ENV)
    register(proc.pid,'sleep 240')
    return proc

def end(proc):
    assert alive(proc.pid)
    proc.kill(); proc.wait()

def marker(path, proc, lab=False):
    path.mkdir(parents=True,exist_ok=True)
    identity=PROCS[proc.pid]
    if lab: (path/'.fm-lab-home').write_text(f'fm-lab-home v1\nowner_pid={proc.pid}\nowner_identity={identity}\n')
    else: (path/'.fm-test-fixture').write_text(f'{proc.pid}\n{identity}\n')

def sweep():
    return command([ROOT/'bin/fm-test-reap-orphans.sh','--tmpdir',SCAN])

try:
    SOCKET.parent.mkdir(parents=True)
    command(['tmux','-f','/dev/null','-S',SOCKET,'new-session','-d','-s','fm-lab-orphan-reaper','sleep 240'])
    private_tmux = command(['tmux','-S',SOCKET,'display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
    # Real scratch-copy watcher, not a replacement script. A protocol fixture
    # supplies provenance; no lifecycle calls, operator homes, or fleet panes.
    creator=owner()
    home=SCAN/'fm-lab-nested'/'home'
    marker(home,creator,lab=True)
    shutil.copytree(ROOT/'bin',home/'bin')
    for name in ('state','data','config','projects'): (home/name).mkdir()
    (home/'state/home-summary.json').write_text('{}')
    (home/'state/open-loops.json').write_text('{"loops":[]}')
    watch=detached(['bash',home/'bin/fm-watch.sh'],{'FM_HOME':str(home),'FM_POLL':'1','TMUX':private_tmux,'FM_BACKEND':'tmux'})
    wait_until(lambda: (home/'state/.last-watcher-beat').exists())
    status('real scratch watcher armed',watch)
    sweep(); assert alive(watch)
    print('Live lab creator retained its detached real watcher.',flush=True)
    end(creator)
    sweep(); wait_until(lambda:not alive(watch))
    status('ended nested lab watcher after sweep',watch)
    command(['tmux','-S',SOCKET,'kill-server'])
    # Runtime ownership uses a real isolated tmux server, not a mocked probe.
    creator=owner()
    serverhome=SCAN/'fm-lab-runtime'/'home'
    marker(serverhome,creator,lab=True)
    command(['tmux','-f','/dev/null','-S',SOCKET,'new-session','-d','-s','fm-lab-orphan-reaper','sleep 240'])
    (serverhome/'state').mkdir()
    (serverhome/'state/.fm-lab-tmux-dir').write_text(str(SOCKET_DIR)+'\n')
    watch2=detached(['sleep','240'],cwd=serverhome)
    end(creator)
    sweep(); assert alive(watch2)
    status('dead creator but real private runtime active',watch2)
    command(['tmux','-S',SOCKET,'list-sessions'])
    command(['tmux','-S',SOCKET,'kill-server'])
    sweep(); wait_until(lambda:not alive(watch2))
    status('runtime ended and detached lab process reaped',watch2)

    # Grant release blocks behind a live holder and exits on missing state.
    state=WORK/'grant-state'; state.mkdir()
    holder=owner()
    command([ROOT/'bin/fm-wake-grant.sh','activate',holder.pid,'live-proof'],{'FM_STATE_OVERRIDE':str(state)})
    command(['bash','-c','. "$1"; fm_wake_append signal key payload','_',ROOT/'bin/fm-wake-lib.sh'],{'FM_STATE_OVERRIDE':str(state)})
    command([ROOT/'bin/fm-wake-grant.sh','publish','live-proof','1'],{'FM_STATE_OVERRIDE':str(state)})
    lock=state/'.wake-queue.lock'; lock.mkdir(); (lock/'pid').write_text(str(holder.pid)+'\n')
    grant=subprocess.Popen(['bash',str(ROOT/'bin/fm-wake-grant.sh'),'release','live-proof'],env={**ENV,'FM_STATE_OVERRIDE':str(state)},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    register(grant.pid,f'bash {ROOT}/bin/fm-wake-grant.sh release live-proof')
    time.sleep(6)
    assert grant.poll() is None
    status('release still blocked after six seconds behind live holder',grant.pid)
    gone=WORK/'grant-state.gone'
    state.rename(gone)
    start=time.monotonic()
    out,err=grant.communicate(timeout=12)
    print(f'release after atomically removed state: exit={grant.returncode} elapsed={time.monotonic()-start:.2f}s stdout={out!r} stderr={err!r}',flush=True)
    assert grant.returncode==1 and out==''
    assert (gone/'.branch-eligible-rows').read_text()=='1\n'
    gone.rename(state)
    shutil.rmtree(lock)
    lock.mkdir(); (lock/'pid').write_text(str(holder.pid)+'\n')
    grant=subprocess.Popen(['bash',str(ROOT/'bin/fm-wake-grant.sh'),'release','live-proof'],env={**ENV,'FM_STATE_OVERRIDE':str(state)},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    register(grant.pid,f'bash {ROOT}/bin/fm-wake-grant.sh release live-proof')
    time.sleep(.5); state.rename(gone); time.sleep(1); gone.rename(state)
    time.sleep(.5); assert grant.poll() is None
    assert (state/'.branch-eligible-rows').read_text()=='1\n'
    shutil.rmtree(lock)
    out,err=grant.communicate(timeout=12)
    print(f'release after one-second state absence and holder unlock: exit={grant.returncode} rows_exist={(state/".branch-eligible-rows").exists()} owner_exists={(state/".branch-eligible-owner").exists()}',flush=True)
    assert grant.returncode==0 and not (state/'.branch-eligible-rows').exists() and (state/'.branch-eligible-owner').exists()
    end(holder)
    print('LIVE PROOFS COMPLETE',flush=True)
finally:
    if SOCKET.exists(): subprocess.run(['tmux','-S',str(SOCKET),'kill-server'],env=ENV,capture_output=True)
    for pid,identity in PROCS.items():
        if snapshot(pid)==identity:
            try: os.kill(pid,signal.SIGKILL)
            except ProcessLookupError: pass
    if SOCKET_DIR.exists(): shutil.rmtree(SOCKET_DIR)
