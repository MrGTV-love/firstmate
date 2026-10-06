import os, pathlib, subprocess, json, hashlib, shutil
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M48YHW4X1N5R5ANWST7WZR3J')
LAB = ROOT / '.gate-test-runtime/live-home'
PROJECT = ROOT / '.gate-test-runtime/project'
lines = []
env = os.environ.copy()
for name in ('FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_TAB_ID','HERDR_WORKSPACE_ID','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
    env.pop(name, None)
def run(args, expected=None, extra=None):
    active = env.copy()
    if extra: active.update(extra)
    p = subprocess.run(args, cwd=ROOT, env=active, text=True, capture_output=True, timeout=35)
    lines.append('$ ' + ' '.join(map(str,args)) + '\n' + p.stdout + p.stderr + f'exit={p.returncode}\n')
    if expected is not None and p.returncode != expected: raise AssertionError(lines[-1])
    return p
socket = None
try:
    run(['bash','bin/fm-lab-home.sh','create',str(LAB)],0)
    # The supported lab-home helper provides a short private socket path on macOS.
    socket = run(['bash','bin/fm-lab-home.sh','tmux-dir',str(LAB)],0).stdout.strip()
    env.update(FM_HOME=str(LAB), TMUX_TMPDIR=socket)
    PROJECT.mkdir(parents=True)
    run(['git','init','-q',str(PROJECT)],0)
    (PROJECT/'work.txt').write_text('unpublished operator work\n')
    (LAB/'config/session-launch-policy').write_text('omp-or-tc\n')
    (LAB/'config/crew-harness').write_text('codex\n')
    (LAB/'config/backlog-backend').write_text('manual\n')
    (LAB/'state/.last-watcher-beat').touch()
    binpath = LAB/'forbidden-bin'
    binpath.mkdir()
    for name in ['codex','claude','pi','treehouse']:
        f=binpath/name
        f.write_text('#!/bin/sh\nprintf "forbidden executable invoked: %s\\n" "$0" >> "$FM_HOME/forbidden-effects"\nexit 97\n')
        f.chmod(0o755)
    env['PATH']=str(binpath)+os.pathsep+env['PATH']
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-n','fm-prior','-x','120','-y','40','-c',str(ROOT),'/bin/zsh -f'],0)
    pane = run(['tmux','-L','fm-lab','display-message','-p','-t','primary:fm-prior','#{pane_id} #{pane_pid} #{window_width}x#{window_height} #{socket_path}'],0).stdout.strip()
    pane_id, pane_pid = pane.split()[:2]
    env['TMUX']=socket+'/tmux-'+str(os.getuid())+'/fm-lab,0,0'
    env['TMUX_PANE']=pane_id
    def refuse(args,label):
        p=run(['bash',*args])
        if p.returncode == 0 or 'session-launch-policy' not in p.stdout+p.stderr:
            raise AssertionError('Expected actionable policy refusal: '+label+'\n'+lines[-1])
        if (LAB/'forbidden-effects').exists(): raise AssertionError((LAB/'forbidden-effects').read_text())
        lines.append('OBSERVED '+label+': policy refusal; forbidden executables not invoked\n')
    for kind,args in [('ship',[]),('scout',['--scout']),('secondmate',['--secondmate'])]:
        ident='fresh-'+kind
        d=LAB/'data'/ident; d.mkdir()
        (d/'brief.md').write_text('# Task\n## Captain\nIsolated launch policy proof.\n')
        posture = ['--mode','no-mistakes','--yolo','off'] if kind == 'ship' else []
        refuse(['bin/fm-spawn.sh',ident,str(PROJECT),*args,*posture],kind+' default')
        if (LAB/'state'/f'{ident}.meta').exists(): raise AssertionError('allocated task metadata')
    refuse(['bin/fm-spawn.sh','fresh-ship='+str(PROJECT),'--mode','no-mistakes','--yolo','off'],'batch default')
    for harness in ['claude','pi','env codex','omp --model arbitrary']:
        refuse(['bin/fm-spawn.sh','fresh-ship',str(PROJECT),'--harness',harness,'--mode','no-mistakes','--yolo','off'],'explicit '+harness)
    (LAB/'config/claude-launcher').write_text('teamclaude\n')
    refuse(['bin/fm-spawn.sh','fresh-ship',str(PROJECT),'--harness','claude','--mode','no-mistakes','--yolo','off'],'TeamClaude proxy is not native tc run')
    (LAB/'state/prior.meta').write_text('window=primary:fm-prior\nendpoint_task_id=prior\nkind=ship\nharness=codex\nworktree='+str(PROJECT)+'\nproject='+str(PROJECT)+'\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\n')
    (LAB/'state/prior.validation').write_text('validation custody\n')
    (LAB/'data/prior').mkdir()
    (LAB/'data/prior/brief.md').write_text('Existing task instructions\n')
    owned=[LAB/'state/prior.meta',LAB/'state/prior.validation',LAB/'data/prior/brief.md',PROJECT/'work.txt']
    before={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in owned}
    refuse(['bin/fm-control.sh','prior','relaunch','--note','continue preserved work'],'manual recorded Codex recovery')
    refuse(['bin/fm-spawn.sh','prior','--relaunch'],'direct recorded Codex recovery')
    after={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in owned}
    if before != after: raise AssertionError('refusal changed durable state')
    if (LAB/'state/prior.control-relaunch').exists(): raise AssertionError('replacement custody was checkpointed')
    os.kill(int(pane_pid),0)
    current=run(['tmux','-L','fm-lab','display-message','-p','-t','primary:fm-prior','#{pane_id} #{pane_pid} #{pane_current_command}'],0).stdout.strip()
    if current.split()[:2] != [pane_id,pane_pid]: raise AssertionError('endpoint replaced')
    lines.append('OBSERVED prior endpoint and process remain alive; work, brief, metadata and validation SHA-256 unchanged:\n'+json.dumps(after,indent=2)+'\n')
    run(['bash','bin/fm-busy-event.sh','arm',str(LAB/'state'),'prior','--state','idle','--source','claude-hook','--event','launch-brief'],0)
    generation=(LAB/'state/prior.busy-gen').read_text().strip()
    run(['bash','bin/fm-busy-event.sh','apply',str(LAB/'state'),'prior','idle','--gen',generation,'--source','claude-hook','--event','session-end'],0)
    control=LAB/'lab-stock-control'
    control.write_text('#!/bin/bash\n[ "$FM_STATE_OVERRIDE" = "$FM_HOME/state" ] || exit 98\nunset FM_STATE_OVERRIDE\n/bin/bash '+repr(str(ROOT/'bin/fm-control.sh'))+' "$@" > "$FM_HOME/control-output" 2>&1\nrc=$?\ncat "$FM_HOME/control-output"\nexit "$rc"\n')
    control.chmod(0o755)
    lines.append('Lab control shim clears only the redundant stock FM_STATE_OVERRIDE inserted by automatic recovery; actual fm-control.sh owns the replacement, with no gate bypass.\n')
    watcher=run(['bash','bin/fm-watch.sh'],extra={'FM_POLL':'1','FM_HEARTBEAT':'5','FM_TEST_SEAM':'1','FM_SESSION_END_CONTROL':str(control)})
    control_output=(LAB/'control-output').read_text()
    lines.append('ACTUAL automatic fm-control.sh output (watcher caps its reason at the first line):\n'+control_output+'\n')
    if 'session-launch-policy' not in control_output or 'auto-relaunch failed after session-end' not in watcher.stdout:
        raise AssertionError('automatic watcher did not refuse replacement\n'+lines[-1])
    if before!={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in owned}:
        raise AssertionError('automatic watcher changed durable task custody')
    os.kill(int(pane_pid),0)
    lines.append('OBSERVED real watcher processed a session-end event, refused automatic replacement, and preserved endpoint, work, metadata and validation custody.\n')
    for value in ['', 'unknown', 'omp-or-tc\n\n','omp-or-tc ']:
        (LAB/'config/session-launch-policy').write_text(value)
        refuse(['bin/fm-spawn.sh','fresh-ship',str(PROJECT),'--harness','omp','--mode','no-mistakes','--yolo','off'],'malformed opt-in '+repr(value))
    (LAB/'config/session-launch-policy').unlink()
    (LAB/'config/session-launch-policy').symlink_to(LAB/'absent')
    refuse(['bin/fm-spawn.sh','fresh-ship',str(PROJECT),'--harness','omp','--mode','no-mistakes','--yolo','off'],'dangling opt-in')
    lines.append('All driven CLI refusal scenarios passed against the tracked product and real private tmux endpoint. No model CLI was launched.\n')
finally:
    if socket:
        run(['tmux','-L','fm-lab','kill-server'])
        run(['bash','bin/fm-lab-home.sh','teardown',str(LAB)],0)
    shutil.rmtree(LAB,ignore_errors=True)
    shutil.rmtree(PROJECT,ignore_errors=True)
    lines.append('Disposable home, project, and private tmux server removed.\n')
    (EVIDENCE/'live-cli-policy.txt').write_text('\n'.join(lines))
print('\n'.join(lines))
