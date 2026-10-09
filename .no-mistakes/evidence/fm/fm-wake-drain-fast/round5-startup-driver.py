import os, pathlib, subprocess, time, json, sys, shlex, resource, shutil
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4F9B87M5A8ZB6B0YDWF5A7V')
if '--hook' in sys.argv:
    home=pathlib.Path(os.environ['FM_HOME']); state=home/'state'
    before={'logs':len(list(state.glob('*.status'))),'decision_checkpoints':len(list(state.glob('.*.open-decisions-cursor'))),'presentation_manifest_exists':(state/'.status-presentation-cursor').exists()}
    payload=sys.stdin.read()
    load=os.getloadavg(); t=time.monotonic()
    p=subprocess.run([str(ROOT/'bin/fm-session-start.sh'),'--source','startup'],input=payload,text=True,capture_output=True,timeout=160)
    elapsed=time.monotonic()-t; end_load=os.getloadavg()
    (EVID/'round5-locked-startup-digest.txt').write_text(p.stdout+'\nSTDERR:\n'+p.stderr)
    lock=(state/'.lock').read_text().strip() if (state/'.lock').exists() else None
    completed=(state/'.session-start-complete').read_text().strip() if (state/'.session-start-complete').exists() else None
    proc=subprocess.run(['ps','-p',lock or '0','-o','pid=,ppid=,comm='],capture_output=True,text=True).stdout
    usage=resource.getrusage(resource.RUSAGE_CHILDREN)
    data=dict(elapsed_seconds=elapsed,acceptance_bound_seconds=20,returncode=p.returncode,lock_pid=lock,completion_pid=completed,lock_process=proc.strip(),initial_state=before,load_before=load,load_after=end_load,child_user_seconds=usage.ru_utime,child_system_seconds=usage.ru_stime,truncated=any(line.startswith('●  STARTUP TRUNCATED - ') for line in p.stdout.splitlines()),complete_digest='The digest above is complete for this session start.' in p.stdout)
    data['result']='pass' if elapsed<20 and lock and lock==completed and data['complete_digest'] and not data['truncated'] and before['logs']==25 and before['decision_checkpoints']==0 and not before['presentation_manifest_exists'] else 'fail'
    (EVID/'round5-locked-startup-metrics.json').write_text(json.dumps(data,indent=2))
    print(p.stdout,end='',flush=True)
    subprocess.run(['tmux','wait-for','-S','round5-startup-finished'],check=True)
    sys.exit(0)
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE','NO_MISTAKES_GATE','CLAUDECODE')}
env['TMPDIR']=str(EVID)
# The evidence directory is the only permitted out-of-worktree write location.
# A short lab basename also keeps Darwin's private Unix socket under 104 bytes.
lab=pathlib.Path(subprocess.check_output(['mktemp','-d',str(EVID/'l.XXXXXX')],env=env,text=True).strip())
server=False; notes=[]
def tmux(*args,check=True,timeout=30):
    p=subprocess.run(['tmux','-L','fm-lab',*args],env=dict(env,TMUX_TMPDIR=str(lab/'tmux')),text=True,capture_output=True,timeout=timeout)
    if check and p.returncode: raise RuntimeError(f'tmux {args}: {p.stderr}')
    return p
try:
    subprocess.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(lab)],env=env,check=True)
    (lab/'tmux').mkdir(); (lab/'config/supervision-host').touch()
    for t in range(25):
        (lab/f'state/fleet{t}.status').write_text(f'working: starting task {t}\n'+''.join(f'resolved [key=side-{i}]: routine close {i}\nworking: step {i}\n' for i in range(60)))
    hook=shlex.join([sys.executable,str(EVID/'round5-startup-driver.py'),'--hook'])
    settings=json.dumps({'hooks':{'SessionStart':[{'hooks':[{'type':'command','command':hook,'timeout':180}]}]}})
    command=shlex.join(['claude','--setting-sources','','--settings',settings,'--strict-mcp-config','--tools','','--no-session-persistence','--max-budget-usd','0.10','-p','Reply exactly LAB_STARTUP_OK. Do not use tools.'])
    notes.append('Disposable lab: '+str(lab)+'; 25 cold status logs, 60 routine close/working pairs per log; no pre-primed cursor or checkpoint.')
    notes.append('Launch (inherited gate, override, task-file, multiplexer, and nested Claude markers removed): TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" '+command)
    tmux('new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'-e',f'FM_HOME={lab}',command); server=True
    tmux('set-window-option','-t','primary','remain-on-exit','on')
    try: tmux('wait-for','round5-startup-finished',timeout=195)
    except Exception as e: notes.append('Hook completion wait failed: '+str(e))
    pane=tmux('capture-pane','-p','-t','primary',check=False)
    (EVID/'round5-claude-primary-pane.txt').write_text(pane.stdout+pane.stderr)
    notes.append('Primary pane:\n'+pane.stdout+pane.stderr)
    metrics=EVID/'round5-locked-startup-metrics.json'
    if metrics.exists(): print(metrics.read_text(),flush=True)
    p=subprocess.run([str(ROOT/'bin/fm-startup-network.sh'),'wait','150'],env=dict(env,FM_HOME=str(lab)),capture_output=True,text=True,timeout=170)
    notes.append(f'Deferred worker wait exit={p.returncode}\n{p.stdout}\n{p.stderr}')
    p=subprocess.run([str(ROOT/'bin/fm-startup-network.sh'),'report'],env=dict(env,FM_HOME=str(lab)),capture_output=True,text=True,timeout=30)
    notes.append('Deferred worker report:\n'+p.stdout+p.stderr)
finally:
    if server:
        p=tmux('kill-server',check=False); notes.append(f'Private fm-lab kill-server exit={p.returncode}: {p.stderr}')
    shutil.rmtree(lab)
    notes.append('Disposable home and its private tmux socket removed in this evidence turn. Default tmux/Herdr sessions were not controlled.')
    (EVID/'round5-startup-launch-and-teardown.txt').write_text('\n'.join(notes))
