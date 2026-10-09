import os, pathlib, subprocess, time, json, sys, shlex, resource, shutil
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4F9B87M5A8ZB6B0YDWF5A7V')
EVID.mkdir(parents=True,exist_ok=True)
if '--hook' in sys.argv:
    home=pathlib.Path(os.environ['FM_HOME']); state=home/'state'
    t=time.monotonic(); load=os.getloadavg()
    before={'logs':len(list(state.glob('*.status'))),'decision_checkpoints':len(list(state.glob('.*.open-decisions-cursor'))),'presentation_manifest_exists':(state/'.status-presentation-cursor').exists()}
    p=subprocess.run([str(ROOT/'bin/fm-session-start.sh'),'--source','startup'],input=sys.stdin.read(),text=True,capture_output=True,timeout=160)
    elapsed=time.monotonic()-t
    (EVID/'claude-locked-startup-digest.txt').write_text(p.stdout+'\nSTDERR:\n'+p.stderr)
    lock=(state/'.lock').read_text().strip() if (state/'.lock').exists() else None
    completed=(state/'.session-start-complete').read_text().strip() if (state/'.session-start-complete').exists() else None
    proc=subprocess.run(['ps','-p',lock or '0','-o','pid=,ppid=,comm='],capture_output=True,text=True).stdout
    usage=resource.getrusage(resource.RUSAGE_CHILDREN)
    data=dict(elapsed_seconds=elapsed,returncode=p.returncode,lock_pid=lock,completion_pid=completed,lock_process=proc.strip(),initial_state=before,load_before=load,load_after=os.getloadavg(),child_user_seconds=usage.ru_utime,child_system_seconds=usage.ru_stime,truncated='STARTUP TRUNCATED' in p.stdout,complete_digest='The digest above is complete for this session start.' in p.stdout)
    (EVID/'claude-locked-startup-metrics.json').write_text(json.dumps(data,indent=2))
    print(p.stdout,end='',flush=True)
    subprocess.run(['tmux','wait-for','-S','validation-startup-finished'],check=True)
    sys.exit(0)
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','NO_MISTAKES_GATE','CLAUDECODE')}
env['TMPDIR']='/tmp'
lab=pathlib.Path(subprocess.check_output(['mktemp','-d','/tmp/fm-lab.XXXXXX'],env=env,text=True).strip())
server=False
notes=[]
def tmux(*args,check=True,timeout=30):
    p=subprocess.run(['tmux','-L','fm-lab',*args],env=dict(env,TMUX_TMPDIR=str(lab/'tmux')),text=True,capture_output=True,timeout=timeout)
    if check and p.returncode: raise RuntimeError(f'tmux {args}: {p.stderr}')
    return p
try:
    subprocess.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(lab)],env=env,check=True)
    (lab/'tmux').mkdir()
    (lab/'config/supervision-host').touch()
    # Match the fleet shape used by the branch's cold-history regression, without priming any cursor.
    for t in range(25):
        (lab/f'state/fleet{t}.status').write_text(f'working: starting task {t}\n'+''.join(f'resolved [key=side-{i}]: routine close {i}\nworking: step {i}\n' for i in range(60)))
    hook=shlex.join([sys.executable,str(ROOT/'.live-validation/startup.py'),'--hook'])
    settings=json.dumps({'hooks':{'SessionStart':[{'hooks':[{'type':'command','command':hook,'timeout':180}]}]}})
    command=shlex.join(['claude','--setting-sources','','--settings',settings,'--strict-mcp-config','--tools','','--no-session-persistence','--max-budget-usd','0.10','-p','Reply exactly LAB_STARTUP_OK. Do not use tools.'])
    notes.append('Launch: env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" claude --setting-sources "" --settings <one invocation-local SessionStart measurement hook> --strict-mcp-config --tools "" --no-session-persistence --max-budget-usd 0.10 -p "Reply exactly LAB_STARTUP_OK. Do not use tools."')
    p=tmux('new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'-e',f'FM_HOME={lab}',command);server=True
    tmux('set-window-option','-t','primary','remain-on-exit','on')
    try: tmux('wait-for','validation-startup-finished',timeout=195)
    except Exception as e: notes.append('Hook completion wait failed: '+str(e))
    pane=tmux('capture-pane','-p','-t','primary',check=False)
    (EVID/'claude-primary-pane.txt').write_text(pane.stdout+pane.stderr)
    notes.append('Primary pane capture:\n'+pane.stdout+pane.stderr)
    if (EVID/'claude-locked-startup-metrics.json').exists():
        print((EVID/'claude-locked-startup-metrics.json').read_text(),flush=True)
    # The real deferred worker may still be writing the disposable home. Await its own bounded consumer before teardown.
    p=subprocess.run([str(ROOT/'bin/fm-startup-network.sh'),'wait','150'],env=dict(env,FM_HOME=str(lab)),capture_output=True,text=True,timeout=170)
    notes.append(f'Deferred stage wait exit={p.returncode}\n{p.stdout}\n{p.stderr}')
    p=subprocess.run([str(ROOT/'bin/fm-startup-network.sh'),'report'],env=dict(env,FM_HOME=str(lab)),capture_output=True,text=True,timeout=30)
    notes.append('Deferred stage report:\n'+p.stdout+p.stderr)
finally:
    if server:
        p=tmux('kill-server',check=False);notes.append(f'Private tmux kill-server exit={p.returncode}: {p.stderr}')
    shutil.rmtree(lab)
    notes.append('Disposable lab home removed; only the private fm-lab socket was controlled.')
    (EVID/'claude-startup-launch-and-teardown.txt').write_text('\n'.join(notes))
