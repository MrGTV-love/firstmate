import json, os, pathlib, signal, subprocess, sys, time, shutil
ROOT=pathlib.Path.cwd(); SCRATCH=ROOT/'.live-timeout-validation'
EVIDENCE=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4D23NV25Q1M1CFJV1KQS7TG')
BASH=sys.argv[1]
env=dict(os.environ)
for key in ['FM_HOME','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TMUX','HERDR_ENV','HERDR_SESSION']:
    env.pop(key,None)
env['PATH']=str(pathlib.Path(BASH).parent)+':'+env['PATH']; env['TMPDIR']=str(SCRATCH/'tmp'); env['FM_TEST_SKIP_ORPHAN_REAP']='1'
def alive(pid):
    p=subprocess.run(['/bin/ps','-o','stat=','-p',str(pid)],capture_output=True,text=True)
    return p.returncode==0 and bool(p.stdout.strip()) and not p.stdout.strip().startswith('Z')
def wait_file(p,owner):
    until=time.monotonic()+30
    while time.monotonic()<until:
        if p.exists() and p.stat().st_size: return
        if owner.poll() is not None: raise RuntimeError('fixture owner exited early')
        time.sleep(.1)
    raise RuntimeError('check did not start')
socket='./.live-timeout-validation/watcher.sock'
subprocess.run(['tmux','-S',socket,'new-session','-d','-s','fm-lab-cleanup','-c',str(ROOT),'sleep 180'],env=env,cwd=ROOT,check=True)
env['TMUX']=socket+',0,0'
rows=[]
try:
    for ending in ['normal','TERM','stopped-TERM']:
        lab=pathlib.Path(subprocess.check_output(['mktemp','-d',str(SCRATCH/'tmp'/'fm-lab.XXXXXX')],text=True).strip())
        subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],env=env,cwd=ROOT,check=True,capture_output=True,text=True)
        (lab/'config'/'supervision-host').touch()
        check=lab/'state'/'slow.check.sh'
        check.write_text('#!/usr/bin/env bash\ntrap "" TERM\necho $$ > "$FM_HOME/state/check.pid"\n(sleep 30) &\necho $! > "$FM_HOME/state/descendant.pid"\nwait\n')
        check.chmod(0o700)
        le=dict(env,FM_HOME=str(lab))
        subprocess.run(['bin/fm-check-register.sh','slow'],env=le,cwd=ROOT,check=True,capture_output=True,text=True)
        owner_script=r'''
. tests/lib.sh
fm_test_track_watcher_state "$FM_HOME/state"
FM_POLL=1 FM_CHECK_TIMEOUT=60 FM_CHECK_FORCE_FALLBACK=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 "$ROOT/bin/fm-watch.sh" > "$FM_HOME/state/watch.out" 2> "$FM_HOME/state/watch.err" &
printf '%s\n' "$!" > "$FM_HOME/state/watcher.pid"
while [ ! -e "$FM_HOME/finish" ]; do sleep .1; done
'''
        owner=subprocess.Popen([BASH,'-c',owner_script],env=le,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        tracked=[]
        try:
            wait_file(lab/'state'/'check.pid',owner); wait_file(lab/'state'/'descendant.pid',owner)
            wp=int((lab/'state'/'watcher.pid').read_text()); cp=int((lab/'state'/'check.pid').read_text()); dp=int((lab/'state'/'descendant.pid').read_text()); tracked=[wp,cp,dp]
            before=subprocess.run(['/bin/ps','-o','pid=,ppid=,pgid=,stat=,command=','-p',','.join(map(str,tracked))],capture_output=True,text=True).stdout
            if ending=='stopped-TERM': os.kill(wp,signal.SIGSTOP)
            start=time.monotonic()
            if ending=='normal': (lab/'finish').touch()
            else: os.kill(owner.pid,signal.SIGTERM)
            out,err=owner.communicate(timeout=25)
            until=time.monotonic()+5
            while any(alive(p) for p in tracked) and time.monotonic()<until: time.sleep(.1)
            row={'ending':ending,'owner_exit':owner.returncode,'before_process_tree':before,'cleanup_elapsed_seconds':round(time.monotonic()-start,3),'survivors':[p for p in tracked if alive(p)],'lock_remaining':(lab/'state'/'.watch.lock').exists(),'owner_stdout':out,'owner_stderr':err,'watcher_stdout':(lab/'state'/'watch.out').read_text(),'watcher_stderr':(lab/'state'/'watch.err').read_text()}
            rows.append(row); (EVIDENCE/('watcher-cleanup-'+ending+'.json')).write_text(json.dumps(row,indent=2)+'\n'); print(json.dumps(row))
            if row['survivors'] or row['lock_remaining']: raise RuntimeError('watcher teardown failed')
        finally:
            if owner.poll() is None: owner.terminate();
            try: owner.wait(timeout=15)
            except subprocess.TimeoutExpired: owner.kill(); owner.wait()
            for p in tracked:
                if alive(p):
                    try: os.kill(p,signal.SIGCONT); os.kill(p,signal.SIGKILL)
                    except ProcessLookupError: pass
            shutil.rmtree(lab)
finally:
    subprocess.run(['tmux','-S',socket,'kill-server'],env=env,cwd=ROOT,capture_output=True,text=True)
(EVIDENCE/'watcher-cleanup-summary.json').write_text(json.dumps(rows,indent=2)+'\n')
