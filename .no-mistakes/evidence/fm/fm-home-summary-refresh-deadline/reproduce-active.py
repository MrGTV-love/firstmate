import os,json,time,pathlib,subprocess
ROOT=pathlib.Path.cwd();WORK=ROOT/'.lv';HOME=WORK/'home';SOCKET=WORK/'a';E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4EXCPRHTRH93K0CGS9YW44Y')
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX','BASH_ENV','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):env.pop(k,None)
env.update(FM_HOME=str(HOME),FM_ROOT_OVERRIDE=str(ROOT),TMPDIR=str(WORK/'tmp'),GIT_CEILING_DIRECTORIES=str(WORK),FM_SNAPSHOT_NOW='2026-10-09T12:00:00Z',FM_CONTRIBUTIONS_NOW='2026-10-09T12:00:00Z')
log=[];workers=[]
def run(args):
    start=time.monotonic();p=subprocess.run([str(a) for a in args],cwd=ROOT,env=env,capture_output=True,text=True,timeout=90)
    elapsed=time.monotonic()-start
    log.append('$ '+' '.join(str(a).replace(str(ROOT)+'/', '') for a in args)+f'\nexit={p.returncode} elapsed={elapsed:.3f}s\nstdout={p.stdout}\nstderr={p.stderr}')
    assert p.returncode==0,p.stderr
    return p,elapsed
try:
    run(['tmux','-S',SOCKET,'-f','/dev/null','new-session','-d','-s','fm-lab-summary','-x','120','-y','40','-n','anchor','-c',ROOT,'sleep 600'])
    p,_=run(['tmux','-S',SOCKET,'display-message','-p','-t','fm-lab-summary:anchor','#{socket_path},#{pid},0']);env['TMUX']=p.stdout.strip()
    run(['tmux','-S',SOCKET,'set-window-option','-g','automatic-rename','off'])
    for n in range(1,28):
        ident=f'task-{n:02d}'
        run(['tmux','-S',SOCKET,'new-window','-d','-t','fm-lab-summary:','-n','fm-'+ident,'-c',ROOT,'sleep 600'])
        meta=HOME/'state'/f'{ident}.meta';meta.write_text(meta.read_text().replace('harness=codex','harness=claude'))
        p,_=run([ROOT/'bin/fm-busy-event.sh','arm',HOME/'state',ident,'--state','busy','--source','claude-hook','--event','user-prompt-submit'])
    # This intentionally seeds persisted lifecycle records, not a fake harness executable.
    # The real snapshot classifies these through its real semantic-state reader and tmux backend.
    workers=[subprocess.Popen([os.sys.executable,'-c','import time; end=time.monotonic()+90\nx=1\nwhile time.monotonic()<end: x=(x*1664525+1013904223)&0xffffffff'],env=env) for _ in range(4)]
    p,elapsed=run([ROOT/'bin/fm-home-summary-refresh.sh','--best-effort'])
    ledger=json.loads((HOME/'state/home-summary.json').read_text())
    (E/'active-published-home-summary.json').write_text(json.dumps(ledger,indent=2)+'\n')
    assert ledger['valid']
    assert ledger['counts']['active_children']==27 and ledger['counts']['endpoints']==27
    assert ledger['contributions']['known']==53 and elapsed<60
    results={'elapsed_seconds':elapsed,'deadline_seconds':60,'cpu_pressure_workers':4,'valid':ledger['valid'],'state':ledger['state'],'counts':ledger['counts'],'contribution_records':ledger['contributions']['known'],'fixture_inputs':'27 real tmux windows; semantic busy lifecycle records seeded through real fm-busy-event.sh; no harness substituted or logged in'}
    (E/'active-refresh-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(results,indent=2),flush=True)
finally:
    for w in workers:w.terminate()
    for w in workers:w.wait()
    p=subprocess.run(['tmux','-S',str(SOCKET),'kill-server'],capture_output=True,text=True)
    log.append('Private tmux teardown exit='+str(p.returncode))
    (E/'active-refresh-transcript.txt').write_text('\n\n'.join(log)+'\n')
