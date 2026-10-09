# Test driver used from /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4EXCFFXV5ZVRXQ95RXK339W/.validation; not a product stub.
import pathlib, os, subprocess, json, time, shlex, signal, shutil, html
root=pathlib.Path(__file__).resolve().parent.parent
lab=root/'.validation/dialog-lab'
evidence=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4EXCFFXV5ZVRXQ95RXK339W')
socket='fm-lab-dialog-proof-'+str(os.getpid())
(root/'.validation/dialog-socket.txt').write_text(socket)
env=os.environ.copy()
for k in list(env):
    if k.startswith(('CLAUDE','ANTHROPIC','FM_','HERDR')) or k in ('TMUX','TMUX_PANE'): env.pop(k,None)
env.update(DISABLE_AUTOUPDATER='1',TMPDIR=str(root/'.validation/tmp'))
def run(a,**kw): return subprocess.run(a,cwd=root,env=env,text=True,capture_output=True,**kw)
def tmux(*a): return run(['tmux','-L',socket,*a])
def stop(sig,frame): raise KeyboardInterrupt('interrupted')
signal.signal(signal.SIGTERM,stop)
results=[]; panes=[]
try:
    project=lab/'project'; project.mkdir(parents=True)
    run(['git','-C',str(project),'init','-q'])
    fragment=run(['bash','-c','. "$1"; fm_claude_md_excludes_json "$2"','_',str(root/'bin/fm-claude-memory-lib.sh'),str(project)]).stdout
    settings=shlex.split("'{"+fragment.lstrip(',')+"}'")[0]
    for name,expected,flags,approved in [
        ('bypass-permissions','WARNING: Claude Code running in Bypass Permissions mode',['--dangerously-skip-permissions'],True),
        ('custom-api-key','Do you want to use this API key?',[],False),
        ('workspace-trust','Quick safety check:',[],True)]:
        cfg=lab/name; cfg.mkdir()
        key='sk-ant-fm-start-dialog-throwaway'
        store={'hasCompletedOnboarding':True,'theme':'dark','numStartups':5,
               'customApiKeyResponses':{'approved':[key[-20:]] if approved else [],'rejected':[]},
               'projects':{str(p):{'hasTrustDialogAccepted':True,'hasCompletedProjectOnboarding':True} for p in [project,*project.parents]} if name!='workspace-trust' else {}}
        (cfg/'.claude.json').write_text(json.dumps(store))
        command=shlex.join(['env',f'CLAUDE_CONFIG_DIR={cfg}',f'ANTHROPIC_API_KEY={key}','DISABLE_AUTOUPDATER=1','claude','--setting-sources','project,local','--settings',settings,*flags])
        started=tmux('new-session','-d','-s',name,'-x','160','-y','48','-c',str(project),command)
        if started.returncode: raise RuntimeError(started.stderr)
        pane=''
        for _ in range(100):
            pane=tmux('capture-pane','-p','-t',name).stdout
            if expected in pane: break
            time.sleep(.2)
        path=evidence/(name+'-live.txt'); path.write_text('COMMAND: '+command+'\n\n'+pane)
        state=cfg/'state'; state.mkdir()
        arm=run([str(root/'bin/fm-busy-event.sh'),'arm',str(state),'probe'])
        classify=run(['bash','-c','. "$1"; fm_busy_classify tmux "$2" claude probe "$3" "$(cat "$4")"','_',str(root/'bin/fm-busy-lib.sh'),name,str(state),str(path)])
        named=run(['bash','-c','. "$1"; fm_busy_claude_launch_prompt_name < "$2"','_',str(root/'bin/fm-busy-lib.sh'),str(path)])
        ok=expected in pane and classify.stdout.strip()=='unknown launch-prompt'
        results.append({'name':name,'passed':ok,'classification':classify.stdout.strip(),'dialog':named.stdout.strip(),'command':command})
        print(name,'PASS' if ok else 'FAIL',classify.stdout.strip(),named.stdout.strip(),flush=True)
        if not ok: print(pane,flush=True)
        panes.append((name,pane))
        tmux('kill-session','-t',name)
finally:
    tmux('kill-server')
    (evidence/'dialog-live-results.json').write_text(json.dumps(results,indent=2))
    (evidence/'real-startup-dialogs.html').write_text('<!doctype html><meta charset="utf-8"><title>Genuine Claude startup dialogs</title><style>body{background:#121212;color:#eee;font:15px monospace;margin:24px}pre{padding:20px;background:#191919;overflow:auto}</style>'+''.join('<h2>'+html.escape(n)+'</h2><pre>'+html.escape(p)+'</pre>' for n,p in panes))
    shutil.rmtree(lab,ignore_errors=True)
if any(not x['passed'] for x in results): raise SystemExit(1)
