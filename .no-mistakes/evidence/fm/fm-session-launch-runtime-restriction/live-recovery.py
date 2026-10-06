import os,pathlib,subprocess,shutil,json,hashlib
ROOT=pathlib.Path.cwd(); BASE=ROOT/'.gate-test-runtime/recovery'; LAB=BASE/'home'
EVIDENCE=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M48YHW4X1N5R5ANWST7WZR3J')
env=os.environ.copy(); lines=[]; socket=None
for key in ('FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_TAB_ID','HERDR_WORKSPACE_ID','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
    env.pop(key,None)
def run(args,timeout=45):
    p=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,timeout=timeout)
    lines.append('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+f'exit={p.returncode}\n'); return p
def digest(paths): return {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
def denied(p):
    if p.returncode==0 or 'session-launch-policy' not in p.stdout+p.stderr: raise AssertionError(lines[-1])
    if (LAB/'effects').exists(): raise AssertionError((LAB/'effects').read_text())
try:
    BASE.mkdir(parents=True)
    assert run(['bash','bin/fm-lab-home.sh','create',str(LAB)]).returncode==0
    socket=run(['bash','bin/fm-lab-home.sh','tmux-dir',str(LAB)]).stdout.strip()
    env.update(FM_HOME=str(LAB),TMUX_TMPDIR=socket,FM_BACKEND='tmux')
    tools=LAB/'forbidden-bin'; tools.mkdir()
    for name in ('codex','claude','omp','treehouse','ssh','herdr'):
        p=tools/name; p.write_text('#!/bin/sh\necho "$0 $*" >> "$FM_HOME/effects"\nexit 97\n'); p.chmod(0o755)
    (tools/'treehouse').write_text('#!/bin/sh\nif [ "$1 $2" = "get --help" ]; then printf "fixture help\\n"; exit 0; fi\necho "$0 $*" >> "$FM_HOME/effects"\nexit 97\n')
    env['PATH']=str(tools)+os.pathsep+env['PATH']
    (LAB/'config/session-launch-policy').write_text('omp-or-tc\n')
    (LAB/'config/crew-harness').write_text('codex\n')
    (LAB/'config/secondmate-harness').write_text('codex explicit-model high\n')
    (LAB/'state/.last-watcher-beat').touch()
    assert run(['tmux','-L','fm-lab','new-session','-d','-s','firstmate','-n','fm-sm1','-x','120','-y','40','/bin/zsh -f']).returncode==0
    pane=run(['tmux','-L','fm-lab','display-message','-p','-t','firstmate:fm-sm1','#{pane_id} #{pane_pid} #{pane_current_command}']).stdout.strip()
    env['TMUX']=socket+'/tmux-'+str(os.getuid())+'/fm-lab,0,0'
    sm=LAB/'sm1'
    for d in ('bin','data','state','config','projects'): (sm/d).mkdir(parents=True)
    (sm/'.fm-secondmate-home').write_text('sm1\n')
    shutil.copyfile(ROOT/'AGENTS.md',sm/'AGENTS.md')
    (sm/'data/charter.md').write_text('Unchanged secondmate charter\n')
    (sm/'unpublished').write_text('Unpublished work\n')
    meta=LAB/'state/sm1.meta'
    meta.write_text('window=firstmate:fm-sm1\nkind=secondmate\nharness=omp\nhome='+str(sm)+'\n')
    ledger=LAB/'state/.secondmate-relaunch-sm1'; ledger.write_text('1\tattempt\n1\tfailed\n')
    files=[meta,ledger,sm/'data/charter.md',sm/'unpublished']; before=digest(files)
    p=run(['bash','bin/fm-bootstrap.sh'])
    if 'SECONDMATE_LIVENESS: secondmate sm1: skipped: error: config/session-launch-policy' not in p.stdout+p.stderr: raise AssertionError(lines[-1])
    current=run(['tmux','-L','fm-lab','display-message','-p','-t','firstmate:fm-sm1','#{pane_id} #{pane_pid} #{pane_current_command}']).stdout.strip()
    if current!=pane or digest(files)!=before: raise AssertionError('automatic refusal altered endpoint or durable records')
    if (LAB/'effects').exists(): raise AssertionError((LAB/'effects').read_text())
    lines.append('OBSERVED automatic bootstrap recovery: real empty zsh endpoint unchanged; metadata, attempt ledger, charter and unpublished work unchanged.\n'+json.dumps(before,indent=2)+'\n')
    rmeta=LAB/'state/remote-sm.meta'; rmeta.write_text('kind=secondmate\nremote_host=unreachable-fixture-host\nharness=omp\nwindow=remote:remote-sm\n')
    remote_before=rmeta.read_bytes()
    denied(run(['bash','bin/fm-remote-secondmate-relaunch.sh','remote-sm','codex','default','default']))
    if rmeta.read_bytes()!=remote_before: raise AssertionError('parent route altered')
    lines.append('OBSERVED parent policy denied remote replacement before any SSH transport; parent route unchanged.\n')
    target=LAB/'remote-home'
    for d in ('state/parent-route','data/.parent-route','config'): (target/d).mkdir(parents=True)
    (target/'.fm-secondmate-home').write_text('remote-sm\n')
    shutil.copyfile(ROOT/'AGENTS.md',target/'AGENTS.md')
    (target/'bin').symlink_to(ROOT/'bin',target_is_directory=True)
    (target/'config/session-launch-policy').write_text('omp-or-tc\n')
    endpoint=target/'state/parent-route/remote-sm.meta'
    endpoint.write_text('window=fm-remote:fixture-dead-pane\nbackend=herdr\nkind=secondmate\nharness=codex\nherdr_session=fm-remote\nendpoint_task_id=remote-sm\n')
    endpoint_before=endpoint.read_bytes()
    env['FM_HOME']=str(target)
    denied(run(['bash','bin/fm-remote-secondmate-control.sh','launch','remote-sm','codex','explicit-model','high','herdr']))
    if endpoint.read_bytes()!=endpoint_before or rmeta.read_bytes()!=remote_before: raise AssertionError('destination or initiating route altered')
    if (target/'effects').exists(): raise AssertionError('host-local launch accessed backend')
    lines.append('OBSERVED destination policy denied host-local launch before backend access or endpoint removal; both route records unchanged. No Herdr session was accessed.\n')
finally:
    env['FM_HOME']=str(LAB)
    if socket:
        run(['tmux','-L','fm-lab','kill-server'])
        run(['bash','bin/fm-lab-home.sh','teardown',str(LAB)])
    shutil.rmtree(BASE,ignore_errors=True)
    lines.append('Private tmux server and all disposable recovery fixtures removed.\n')
    (EVIDENCE/'live-recovery-policy.txt').write_text('\n'.join(lines))
print('\n'.join(lines))
