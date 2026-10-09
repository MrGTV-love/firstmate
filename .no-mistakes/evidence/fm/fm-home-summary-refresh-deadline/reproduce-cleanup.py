import os,json,pathlib,subprocess,sys,time,signal
ROOT=pathlib.Path.cwd();WORK=ROOT/'.lv';HOME=WORK/'cleanup-home';E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4EXCPRHTRH93K0CGS9YW44Y')
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX','BASH_ENV','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):env.pop(k,None)
env.update(FM_HOME=str(HOME),FM_ROOT_OVERRIDE=str(ROOT),TMPDIR=str(WORK/'tmp'),FM_CONTRIBUTIONS_NOW='2026-10-09T12:00:00Z')
for d in ('state','data/owned','config','projects'):(HOME/d).mkdir(parents=True,exist_ok=True)
(HOME/'data/owned/contributions.json').write_text('{"schema":"fm-contributions.v1","task":"owned","records":[]}\n')
tools=WORK/'cleanup-tools';tools.mkdir(exist_ok=True)
audit=WORK/'audit.bash'
audit.write_text('''kill() {
  case "${1:-}" in -0) ;; *) printf '%s\\n' "$*" >> "$AUDIT_LOG" ;; esac
  builtin kill "$@"
}
''')
head=tools/'head'
head.write_text('''#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "$FM_HOME/data/owned/contributions.json" ]; then
    printf '%s\\n' "$PPID" > "$FM_HOME/contribution-pid"
    [ "$CLEANUP_CASE" != active-early ] || sleep 2
  fi
done
exec /usr/bin/head "$@"
''');head.chmod(0o755)
cp=tools/'cp'
cp.write_text('''#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "$FM_HOME/state/task.meta" ]; then
    deadline=$((SECONDS+30))
    while [ ! -s "$FM_HOME/contribution-pid" ]; do
      [ "$SECONDS" -lt "$deadline" ] || exit 90
      sleep 0.02
    done
    pid=$(cat "$FM_HOME/contribution-pid")
    if [ "$CLEANUP_CASE" = completed-early ]; then
      while kill -0 "$pid" 2>/dev/null; do
        [ "$SECONDS" -lt "$deadline" ] || exit 91
        sleep 0.02
      done
    fi
    exit 7
  fi
done
exec /bin/cp "$@"
''');cp.chmod(0o755)
log=[];results=[]
for name,mode in [('active-early','--secondmate-home-summary'),('completed-early','--secondmate-home-summary'),('success','--json'),('success','--secondmate-home-summary')]:
    pid_file=HOME/'contribution-pid';pid_file.unlink(missing_ok=True)
    if name=='success':(HOME/'state/task.meta').unlink(missing_ok=True)
    else:(HOME/'state/task.meta').write_text('kind=ship\n')
    audit_file=HOME/'kill-audit';audit_file.write_text('')
    ee=dict(env,PATH=str(tools)+':'+env['PATH'],BASH_ENV=str(audit),AUDIT_LOG=str(audit_file),CLEANUP_CASE=name)
    p=subprocess.run([str(ROOT/'bin/fm-fleet-snapshot.sh'),mode],cwd=ROOT,env=ee,capture_output=True,text=True,timeout=40,start_new_session=True)
    pid=int(pid_file.read_text().strip())
    signals=audit_file.read_text().splitlines()
    if name=='active-early':
        assert p.returncode==1 and signals==[str(pid)]
        try:os.kill(pid,0);alive=True
        except ProcessLookupError:alive=False
        assert not alive
    elif name=='completed-early':assert p.returncode==1 and not signals
    else:
        assert p.returncode==0 and not signals
        doc=json.loads(p.stdout)
        assert doc['contributions']['known']==0
    log.append(f'$ bin/fm-fleet-snapshot.sh {mode}\ncase={name} exit={p.returncode} contribution_pid={pid} signalled_pids={signals}\nstdout={p.stdout}\nstderr={p.stderr}')
    results.append({'case':name,'mode':mode,'exit':p.returncode,'contribution_pid':pid,'signalled_pids':signals})
    print(json.dumps(results[-1]),flush=True)
(E/'cleanup-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
(E/'cleanup-live-transcript.txt').write_text('\n\n'.join(log)+'\n')
