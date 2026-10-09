import os,sys,json,pathlib,subprocess,time
ROOT=pathlib.Path.cwd();WORK=ROOT/'.lv';HOME=WORK/'rolling-home';SOCKET=WORK/'r'
E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4EXCPRHTRH93K0CGS9YW44Y')
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX','BASH_ENV','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):env.pop(k,None)
env.update(FM_HOME=str(HOME),FM_ROOT_OVERRIDE=str(ROOT),TMPDIR=str(WORK/'tmp'),GIT_CEILING_DIRECTORIES=str(WORK),FM_SNAPSHOT_NOW='2026-10-09T12:00:00Z')
LOG=[];results={}
def run(args,extra=None,check=True):
    start=time.monotonic()
    p=subprocess.run([str(a) for a in args],cwd=ROOT,env=dict(env,**(extra or {})),capture_output=True,text=True,timeout=150)
    LOG.append(f'$ {" ".join(str(a).replace(str(ROOT)+"/","") for a in args)}\nexit={p.returncode} elapsed={time.monotonic()-start:.3f}s\nstderr={p.stderr}')
    if check:assert p.returncode==0,p.stderr
    return p
try:
    for d in ('state','data','config','projects','wt'):(HOME/d).mkdir(parents=True,exist_ok=True)
    run(['tmux','-S',SOCKET,'-f','/dev/null','new-session','-d','-s','fm-lab-window','-x','120','-y','40','-n','anchor','-c',ROOT,'sleep 600'])
    env['TMUX']=run(['tmux','-S',SOCKET,'display-message','-p','-t','fm-lab-window:anchor','#{socket_path},#{pid},0']).stdout.strip()
    for n in range(1,10):
        ident=f'task-{n:02d}'
        run(['tmux','-S',SOCKET,'new-window','-d','-t','fm-lab-window:','-n','fm-'+ident,'-c',ROOT,'sleep 600'])
        run(['tmux','-S',SOCKET,'set-window-option','-t','fm-lab-window:fm-'+ident,'automatic-rename','off'])
        (HOME/'state'/f'{ident}.meta').write_text(f'window=fm-lab-window:fm-{ident}\nworktree={HOME}/wt\nproject=alpha\nharness=codex\nkind=ship\nmode=ship\nspawn_gen=fixture\nbranch=worker-{n}\n'+ ('project=α-beta\nyolo=off\npr_head=0123456789abcdef\n' if n==2 else ''))
        (HOME/'state'/f'{ident}.status').write_text(f'working [at=1791547100]: task {n}\n'+ ('needs-decision [at=1791547150]: [key=api] choose API https://github.com/o/r/pull/23\n\n  \n' if n==2 else ''))
    tools=WORK/'window-tools';tools.mkdir(exist_ok=True)
    hooks=WORK/'window-hooks.sh'
    hooks.write_text('''read_start() {
  local phase=$1 id=$2 deadline=$((SECONDS+60))
  [ -n "${READ_TRACE:-}" ] || return 0
  printf 'start %s\\n' "$id" >> "$READ_TRACE/$phase.log"
  if [ "$id" = task-01 ]; then
    : > "$READ_TRACE/$phase.first-started"
    while [ ! -e "$READ_TRACE/$phase.ninth-started" ]; do
      [ "$SECONDS" -lt "$deadline" ] || return 90
      sleep 0.05
    done
  else
    while [ ! -e "$READ_TRACE/$phase.first-started" ]; do
      [ "$SECONDS" -lt "$deadline" ] || return 91
      sleep 0.05
    done
    if [ "$id" = task-09 ]; then
      [ -e "$READ_TRACE/$phase.first-ended" ] || : > "$READ_TRACE/$phase.overlap"
      : > "$READ_TRACE/$phase.ninth-started"
    fi
  fi
}
read_end() {
  [ -n "${READ_TRACE:-}" ] || return 0
  printf 'end %s\\n' "$2" >> "$READ_TRACE/$1.log"
  [ "$2" != task-01 ] || : > "$READ_TRACE/$1.first-ended"
  return 0
}
''')
    for name in ('cp','jq'):
        phase='observations' if name=='cp' else 'composition';real='/bin/cp' if name=='cp' else '/usr/bin/jq'
        detect='''for arg in "$@"; do
  case "$arg" in "$FM_HOME"/state/task-??.status) id=${arg##*/}; id=${id%.status} ;; esac
done
''' if name=='cp' else '''previous=''
for arg in "$@"; do
  if [ "$previous" = id ]; then case "$arg" in task-??) id=$arg ;; esac; fi
  previous=$arg
done
'''
        content=f'#!/bin/bash\n. "{hooks}"\nid=\n'+detect+f'''[ -n "$id" ] || exec {real} "$@"
read_start {phase} "$id" || exit $?
rc=0
if [ "${{FAIL_PHASE:-}}" = {phase} ] && [ "$id" = task-02 ]; then rc=7
else {real} "$@" || rc=$?
fi
read_end {phase} "$id"
exit "$rc"
'''
        (tools/name).write_text(content);(tools/name).chmod(0o755)
    serial=run([ROOT/'bin/fm-fleet-snapshot.sh','--home-input'],{'FM_SNAPSHOT_LOCAL_READ_CONCURRENCY':'1'})
    (E/'window-serial.json').write_text(serial.stdout)
    baseline=run([WORK/'baseline/bin/fm-fleet-snapshot.sh','--home-input'],{'FM_SNAPSHOT_LOCAL_READ_CONCURRENCY':'8'})
    (E/'window-base.json').write_text(baseline.stdout)
    trace=WORK/'window-trace';trace.mkdir(exist_ok=True)
    for old_trace in trace.iterdir(): old_trace.unlink()
    parallel=run([ROOT/'bin/fm-fleet-snapshot.sh','--home-input'],{'PATH':str(tools)+':'+env['PATH'],'FM_SNAPSHOT_LOCAL_READ_CONCURRENCY':'8','READ_TRACE':str(trace)})
    (E/'window-parallel.json').write_text(parallel.stdout)
    for phase in ('observations','composition'):
        text=(trace/(phase+'.log')).read_text()
        (E/(phase+'-live-window.log')).write_text(text)
        active=peak=0;starts=[];ends=[]
        for row in text.splitlines():
            event,ident=row.split();active+=1 if event=='start' else -1
            peak=max(peak,active);assert 0<=active<=8
            (starts if event=='start' else ends).append(ident)
        assert active==0 and len(starts)==9 and len(set(starts))==9 and sorted(starts)==sorted(ends)
        assert (trace/(phase+'.overlap')).exists()
        results[phase]={'peak_active':peak,'tasks_started':9,'ninth_started_before_first_ended':True}
    if serial.stdout!=parallel.stdout:
        a=json.loads(serial.stdout);b=json.loads(parallel.stdout)
        results['differences']=[{'id':x['id'],'serial':x,'parallel':y} for x,y in zip(a['tasks'],b['tasks']) if x!=y]
    assert serial.stdout==parallel.stdout,'serial/parallel output differs: '+json.dumps(results.get('differences'))
    assert serial.stdout==baseline.stdout,'base/target mixed metadata output differs'
    results['byte_identical_serial_parallel_and_base']=True
    assert [t['id'] for t in json.loads(parallel.stdout)['tasks']]==[f'task-{n:02d}' for n in range(1,10)]
    for phase in ('observations','composition'):
        p=run([ROOT/'bin/fm-fleet-snapshot.sh','--home-input'],{'PATH':str(tools)+':'+env['PATH'],'FAIL_PHASE':phase},check=False)
        assert p.returncode==1 and not p.stdout
        assert ('task observation failed' if phase=='observations' else 'task snapshot failed') in p.stderr
        results['failure_'+phase]={'exit':p.returncode,'stdout_bytes':len(p.stdout),'stderr':p.stderr.strip()}
    print(json.dumps(results,indent=2),flush=True)
finally:
    p=subprocess.run(['tmux','-S',str(SOCKET),'kill-server'],capture_output=True,text=True)
    LOG.append('Private tmux teardown exit='+str(p.returncode))
    (E/'window-live-transcript.txt').write_text('\n\n'.join(LOG)+'\n')
    (E/'window-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
