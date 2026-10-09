import os, sys, json, time, subprocess, pathlib, shutil, concurrent.futures
ROOT=pathlib.Path.cwd()
WORK=ROOT/'.lv'
EVIDENCE=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4EXCPRHTRH93K0CGS9YW44Y')
HOME=WORK/'home'
SOCKET=WORK/'s'
LOG=[]
RESULT={}
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND','BASH_ENV'):
        env.pop(k,None)
env.update(FM_HOME=str(HOME),FM_ROOT_OVERRIDE=str(ROOT),TMPDIR=str(WORK/'tmp'),FM_CREW_STATE_NO_FORGE='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_CEILING_DIRECTORIES=str(WORK))
NOW='2026-10-09T12:00:00Z'
env.update(FM_SNAPSHOT_NOW=NOW,FM_CONTRIBUTIONS_NOW=NOW)
def record(text):
    print(text,flush=True); LOG.append(text)
def run(args, extra=None, timeout=100, check=True):
    e=env.copy(); e.update(extra or {})
    start=time.monotonic()
    process=subprocess.Popen([str(a) for a in args],env=e,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try:
        stdout,stderr=process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        import signal
        os.killpg(process.pid,signal.SIGTERM)
        process.communicate(timeout=10)
        raise
    p=subprocess.CompletedProcess(args,process.returncode,stdout,stderr)
    elapsed=time.monotonic()-start
    record(f'$ {" ".join(str(a).replace(str(ROOT)+"/", "") for a in args)}\nexit={p.returncode} elapsed={elapsed:.3f}s'+ ('\nstderr='+p.stderr if p.stderr else ''))
    if check and p.returncode: raise RuntimeError(p.stderr or p.stdout)
    return p,elapsed

def save(name,data):
    (EVIDENCE/name).write_text(data if isinstance(data,str) else json.dumps(data,indent=2)+'\n')

def w(path,text):
    path.parent.mkdir(parents=True,exist_ok=True); path.write_text(text)

def trace_summary(path):
    events=[json.loads(s) for s in path.read_text().splitlines()]
    active=peak=0
    starts={};ends={}
    for ev in events:
        active+=1 if ev['event']=='start' else -1
        peak=max(peak,active)
        assert 0<=active<=8
        (starts if ev['event']=='start' else ends)[ev['id']]=ev['time']
    assert active==0 and len(starts)==27 and len(ends)==27
    assert starts['task-09']<ends['task-01']
    return {'peak_active':peak,'tasks_started':len(starts),'task_09_start':starts['task-09'],'task_01_end':ends['task-01'],'task_09_starts_before_task_01_ends':True}

try:
    for d in ('state','data','config','projects','wt'):(HOME/d).mkdir(parents=True,exist_ok=True)
    # Read-only snapshot/refresh surfaces need no lifecycle authorization or primary login.
    run(['tmux','-S',SOCKET,'-f','/dev/null','new-session','-d','-s','fm-lab-summary','-x','120','-y','40','-n','anchor','-c',ROOT,'sleep 600'])
    p,_=run(['tmux','-S',SOCKET,'display-message','-p','-t','fm-lab-summary:anchor','#{socket_path},#{pid},0'])
    env['TMUX']=p.stdout.strip()
    backlog='## In flight\n'
    for n in range(1,28):
        ident=f'task-{n:02d}'
        run(['tmux','-S',SOCKET,'new-window','-d','-t','fm-lab-summary:','-n','fm-'+ident,'-c',ROOT,'sleep 600'])
        run(['tmux','-S',SOCKET,'set-window-option','-t','fm-lab-summary:fm-'+ident,'automatic-rename','off'])
        kind='scout' if n%4==0 else 'ship'
        backlog+=f'- [ ] {ident} - Task {n} (repo: alpha) (kind: {kind}) (since 2026-10-01)\n'
        w(HOME/'state'/f'{ident}.meta',f'window=fm-lab-summary:fm-{ident}\nworktree={HOME}/wt\nproject=alpha\nharness=codex\nkind={kind}\nmode=ship\nyolo=off\nspawn_gen=live-fixture\n')
        w(HOME/'state'/f'{ident}.status',''.join(f'working [at={1791000000+i}]: step {i} of {ident}\n' for i in range(1,41)))
    w(HOME/'data/backlog.md',backlog)
    for n in range(1,54):
        ident=f'contrib-{n:02d}'
        data={'schema':'fm-contributions.v1','task':ident,'records':[{'url':f'https://github.com/o/r/pull/{n}','kind':'pr','checked_at':NOW,'error':None,'pending':[],'seen':[],'verdict':None,'observation':{'head':'0123456789abcdef0123456789abcdef01234567','state':'merged','draft':False,'mergeable':'unknown','review_decision':'APPROVED','can_merge':False,'checks':[{'name':'test','id':1,'status':'completed','conclusion':'success','started_at':NOW}],'reviews':[],'events':[]}}]}
        w(HOME/'data'/ident/'contributions.json',json.dumps(data))
    # Wrappers retain the real tools; only observe starts and optionally delay a chosen task.
    instrument=WORK/'instrument'
    instrument.mkdir(exist_ok=True)
    wrapper='''#!/usr/bin/env python3
import os, sys, time, json, subprocess
from pathlib import Path
name=sys.argv[1]
args=sys.argv[2:]
real={'jq':'/usr/bin/jq','cp':'/bin/cp'}[name]
if name=='jq' and os.environ.get('JQ_STARTS'):
    with open(os.environ['JQ_STARTS'],'a') as f: f.write('x\\n')
ident=''
if name=='cp':
    for arg in args:
        if arg.startswith(os.environ['FM_HOME']+'/state/task-') and arg.endswith('.status'): ident=Path(arg).stem
else:
    for i,arg in enumerate(args[:-1]):
        if arg=='id' and i and args[i-1]=='--arg' and args[i+1].startswith('task-'): ident=args[i+1]
phase='observations' if name=='cp' else 'composition'
trace=os.environ.get('READ_TRACE')
if ident and trace:
    def event(kind):
        with open(trace+'/'+phase+'.jsonl','a') as f: f.write(json.dumps({'event':kind,'id':ident,'time':time.monotonic()})+'\\n')
    event('start')
    if ident=='task-01': time.sleep(3)
    if os.environ.get('FAIL_PHASE')==phase and ident=='task-02': rc=7
    else: rc=subprocess.call([real]+args)
    event('end')
    sys.exit(rc)
os.execv(real,[real]+args)
'''
    w(WORK/'trace-tool.py',wrapper)
    for name in ('jq','cp'):
        real='/usr/bin/jq' if name=='jq' else '/bin/cp'
        shell=f'''#!/bin/bash
if [ -n "${{READ_TRACE:-}}" ]; then
  exec "{sys.executable}" "{WORK}/trace-tool.py" "{name}" "$@"
fi
'''
        if name=='jq': shell+='[ -z "${JQ_STARTS:-}" ] || printf "x\\n" >> "$JQ_STARTS"\n'
        shell+=f'exec "{real}" "$@"\n'
        w(instrument/name,shell); (instrument/name).chmod(0o755)
    starts=WORK/'jq-starts'; starts.write_text('')
    observed={'PATH':str(instrument)+':'+env['PATH'],'JQ_STARTS':str(starts)}
    # Run before/after on the same real local fleet using base executables plus unchanged helpers.
    basebin=WORK/'baseline/bin'; basebin.mkdir(parents=True,exist_ok=True)
    for f in (ROOT/'bin').iterdir():
        if f.name not in ('fm-fleet-snapshot.sh','fm-contributions.sh'):
            if not (basebin/f.name).exists(): (basebin/f.name).symlink_to(f)
    for name in ('fm-fleet-snapshot.sh','fm-contributions.sh'):
        p=subprocess.run(['git','show','fd9b8b020201a029880b3980b545f352ae357a39:bin/'+name],capture_output=True,text=True,check=True)
        w(basebin/name,p.stdout); (basebin/name).chmod(0o755)
    before,bt=run([basebin/'fm-fleet-snapshot.sh','--secondmate-home-summary'],observed,timeout=300)
    bc=len(starts.read_text().splitlines()); starts.write_text('')
    after,at=run([ROOT/'bin/fm-fleet-snapshot.sh','--secondmate-home-summary'],observed)
    ac=len(starts.read_text().splitlines())
    assert before.stdout==after.stdout,'baseline summary output changed'
    summary=json.loads(after.stdout)
    assert summary['counts']['endpoints']==27 and summary['contributions']['known']==53 and ac<=200
    save('home-summary.json',summary)
    RESULT['fleet_cost']={'baseline_seconds':bt,'target_seconds':at,'baseline_jq_starts':bc,'target_jq_starts':ac,'jq_bound':200,'byte_identical':True,'endpoints':27,'contribution_records':53}
    record(json.dumps(RESULT['fleet_cost']))
    # Refresh actual ledger with default sixty-second deadline while four disposable CPU workers run.
    workers=[subprocess.Popen([sys.executable,'-c','import time; end=time.monotonic()+90\nx=1\nwhile time.monotonic()<end: x=(x*1664525+1013904223)&0xffffffff'],env=env) for _ in range(4)]
    try:
        w(HOME/'state/home-summary.json','{"sentinel":"old-ledger"}\n')
        w(HOME/'state/.home-summary-refresh.streak','count=5\nfirst=2026-10-08T16:45:00Z\nclass=timeout\nescalated=1\n')
        p,elapsed=run([ROOT/'bin/fm-home-summary-refresh.sh','--best-effort'])
        ledger=json.loads((HOME/'state/home-summary.json').read_text())
        assert ledger==summary and elapsed<60
        assert not (HOME/'state/.home-summary-refresh.streak').exists()
        assert (HOME/'state/home-summary.json').stat().st_mode & 0o777==0o600
        RESULT['refresh']={'elapsed_seconds':elapsed,'deadline_seconds':60,'cpu_pressure_workers':4,'published_schema':ledger['schema'],'endpoints':ledger['counts']['endpoints'],'contribution_records':ledger['contributions']['known'],'failure_streak_cleared':True,'ledger_mode':'0600'}
        save('published-home-summary.json',ledger)
        record(json.dumps(RESULT['refresh']))
        # Detached user trigger returns promptly and republishes after a changed contribution cache.
        w(HOME/'data/contrib-54/contributions.json',json.dumps({'schema':'fm-contributions.v1','task':'contrib-54','records':[]}))
        old=(HOME/'state/home-summary.json').stat().st_mtime_ns
        p,elapsed=run([ROOT/'bin/fm-home-summary-refresh.sh','--detach'])
        deadline=time.monotonic()+65
        while (HOME/'state/home-summary.json').stat().st_mtime_ns==old and time.monotonic()<deadline:time.sleep(.1)
        assert (HOME/'state/home-summary.json').stat().st_mtime_ns!=old
        assert elapsed<2
        RESULT['detach']={'trigger_seconds':elapsed,'republished':True}
        record(json.dumps(RESULT['detach']))
    finally:
        for worker in workers:worker.terminate()
        for worker in workers:worker.wait()
    # Real CLI output remains exact at serial and parallel concurrency.
    serial,_=run([ROOT/'bin/fm-fleet-snapshot.sh','--home-input'],{'FM_SNAPSHOT_LOCAL_READ_CONCURRENCY':'1'})
    traces=WORK/'traces';traces.mkdir(exist_ok=True)
    parallel,_=run([ROOT/'bin/fm-fleet-snapshot.sh','--home-input'],{'PATH':str(instrument)+':'+env['PATH'],'READ_TRACE':str(traces),'FM_SNAPSHOT_LOCAL_READ_CONCURRENCY':'8'})
    assert serial.stdout==parallel.stdout
    doc=json.loads(parallel.stdout)
    assert [t['id'] for t in doc['tasks']]==[f'task-{i:02d}' for i in range(1,28)]
    RESULT['rolling_window']={p:trace_summary(traces/(p+'.jsonl')) for p in ('observations','composition')}
    RESULT['rolling_window']['byte_identical_serial_parallel']=True
    save('home-input.json',doc)
    for phase in ('observations','composition'):shutil.copyfile(traces/(phase+'.jsonl'),EVIDENCE/(phase+'-trace.jsonl'))
    record(json.dumps(RESULT['rolling_window']))
    for phase in ('observations','composition'):
        ft=WORK/('failure-'+phase); ft.mkdir(exist_ok=True)
        p,elapsed=run([ROOT/'bin/fm-fleet-snapshot.sh','--home-input'],{'PATH':str(instrument)+':'+env['PATH'],'READ_TRACE':str(ft),'FAIL_PHASE':phase},check=False)
        assert p.returncode==1 and not p.stdout
        assert ('task observation failed' if phase=='observations' else 'task snapshot failed') in p.stderr
        RESULT['failure_'+phase]={'exit':p.returncode,'stdout_bytes':len(p.stdout),'stderr':p.stderr.strip()}
    save('live-results.json',RESULT)
finally:
    p=subprocess.run(['tmux','-S',str(SOCKET),'kill-server'],capture_output=True,text=True)
    record(f'Private tmux server teardown exit={p.returncode}')
    save('live-cli-transcript.txt','\n\n'.join(LOG)+'\n')
