import os, pathlib, subprocess, json, time, shlex, shutil
ROOT=pathlib.Path.cwd(); BASE=ROOT/'.fm-live-validation'; EVIDENCE=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4D34BGQE483Q5806J9GM9AX')
HOME=BASE/'worker-home-3'; PROJECT=BASE/'proof/project'; ORIGINAL_PATH=os.environ['PATH']; HELPER=ROOT/'bin/fm-herdr-lab.sh'
env=dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k.startswith('HERDR_') or k in ('TMUX','NODE_OPTIONS','TYPESAFE_API_KEY','TYPESAFE_API_KEY_PRIVATE','OPENROUTER_API_KEY','OPENROUTER_API_KEY_PRIVATE'):
        env.pop(k,None)
env['FM_HERDR_LAB_STATE_DIR']=str(BASE/'herdr-state')
logs=[]; results=[]
def run(args, timeout=120, checked=True, local_env=None, cwd=ROOT):
    p=subprocess.run([str(a) for a in args],cwd=cwd,env=local_env or env,text=True,capture_output=True,timeout=timeout)
    logs.append({'command':shlex.join([str(a) for a in args]),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    if checked and p.returncode: raise RuntimeError(json.dumps(logs[-1]))
    return p

def save(name,value): (EVIDENCE/name).write_text(value if isinstance(value,str) else json.dumps(value,indent=2)+'\n')
def check(name,values):
    row={'name':name,'pass':all(values)};results.append(row);print(json.dumps(row),flush=True)
PROJECT.parent.mkdir(exist_ok=True)
run(['git','clone','--quiet',BASE/'project',PROJECT])
run([ROOT/'bin/fm-lab-home.sh','create',HOME])
(HOME/'config/herdr-presentation-spaces').write_text('off\n')
(HOME/'config/supervision-host').touch()
SESSION=run([HELPER,'name','skill-picker']).stdout.strip();env['HERDR_SESSION']=SESSION;env['FM_HOME']=str(HOME);env['FM_SPAWN_NO_GUARD']='1'
print('SESSION='+SESSION,flush=True)
owned=False
try:
    # provision itself performs prepare and establishes the default-fleet tripwire.
    p=run([HELPER,'provision',SESSION],timeout=90)
    owned=True
    bindir=BASE/'lab-bin';bindir.mkdir(exist_ok=True)
    wrapper=bindir/'herdr'
    wrapper.write_text('#!/usr/bin/env bash\nset -eu\nargs=()\nwhile [[ $# -gt 0 ]]; do\n if [[ "$1" == --session ]]; then\n  [[ "${2:-}" == '+shlex.quote(SESSION)+' ]] || exit 98\n  shift 2\n else\n  args+=("$1"); shift\n fi\ndone\nexec env PATH='+shlex.quote(ORIGINAL_PATH)+' '+shlex.quote(str(HELPER))+' run '+shlex.quote(SESSION)+' "${args[@]}"\n')
    wrapper.chmod(0o755)
    worker_env=dict(env,PATH=str(bindir)+':'+ORIGINAL_PATH)
    def lab(*args): return run([HELPER,'run',SESSION,*args],checked=True)
    def prepare(id,scout=False):
        flags=['--scout'] if scout else ['--mode','local-only']
        run([ROOT/'bin/fm-brief.sh',id,'project',*flags,'--herdr-lab'],local_env=worker_env)
        brief=HOME/'data'/id/'brief.md'
        text=brief.read_text().replace('{TASK}',f'Validate the generated skill-selection instructions for {id}.').replace('{FIRSTMATE_SPEC}','Do not edit files or invoke lifecycle commands. Report the instructions delivered to this worker.')
        brief.write_text(text)
    def metadata(id):
        p=HOME/'state'/f'{id}.meta'
        return dict(line.split('=',1) for line in p.read_text().splitlines() if '=' in line)
    def capture(id,label):
        meta=metadata(id)
        pane=meta['herdr_pane_id']
        screen=lab('pane','read',pane,'--source','recent','--lines','500').stdout
        save(label,screen)
        return screen
    for id,scout in [('live-ship',False),('live-scout',True)]:
        prepare(id,scout)
        flags=['--scout'] if scout else ['--mode','local-only','--yolo','off']
        r=run([ROOT/'bin/fm-spawn.sh',id,PROJECT,"cat __BRIEF__; printf '\\nWORKER_DELIVERY_COMPLETE\\n'",'--backend','herdr',*flags],local_env=worker_env)
        meta=metadata(id)
        # Wait for a marker from the actual worker command, not from source text.
        screen=''
        for attempt in range(20):
            screen=capture(id,id+'-pane.txt')
            if 'WORKER_DELIVERY_COMPLETE' in screen: break
            time.sleep(0.2)
        save(id+'-launch-brief.md',(HOME/'data'/id/'launch-brief.md').read_text())
        save(id+'-metadata.txt',(HOME/'state'/f'{id}.meta').read_text())
        check(id+' automatic delivered selection', [meta.get('skill_selection')=='unavailable',meta.get('skill_selection_reason')=='no TypeSafe or OpenRouter key','# Skill selection' in screen,'your skill index' in screen,'WORKER_DELIVERY_COMPLETE' in screen,meta.get('kind')==('scout' if scout else 'ship')])
    # Relaunch the now agent-free scout through the real endpoint classifier.
    r=run([ROOT/'bin/fm-spawn.sh','live-scout','--relaunch','--harness',"cat __BRIEF__; printf '\\nRELAUNCH_DELIVERY_COMPLETE\\n'"],local_env=worker_env,checked=False)
    if r.returncode==0:
        screen=''
        for attempt in range(20):
            screen=capture('live-scout','live-scout-relaunch-pane.txt')
            if 'RELAUNCH_DELIVERY_COMPLETE' in screen: break
            time.sleep(0.2)
        meta=metadata('live-scout')
        check('scout relaunch delivers regenerated selection', [meta.get('kind')=='scout',meta.get('skill_selection')=='unavailable','# Skill selection' in screen,'RELAUNCH_DELIVERY_COMPLETE' in screen])
        save('live-scout-relaunch-metadata.txt',(HOME/'state/live-scout.meta').read_text())
    else:
        results.append({'name':'scout relaunch delivers regenerated selection','setup_error':r.stdout+r.stderr})
    prepare('live-raw')
    run([ROOT/'bin/fm-spawn.sh','live-raw',PROJECT,"printf 'RAW_COMMAND_UNCHANGED\\n'",'--backend','herdr','--mode','local-only','--yolo','off'],local_env=worker_env)
    screen=''
    for attempt in range(20):
        screen=capture('live-raw','live-raw-pane.txt')
        if 'RAW_COMMAND_UNCHANGED' in screen: break
        time.sleep(0.2)
    meta=metadata('live-raw')
    save('live-raw-metadata.txt',(HOME/'state/live-raw.meta').read_text())
    check('raw command without transport never claims a delivered pick', [meta.get('skill_selection')=='undelivered','skill_selection_picked' not in meta,'RAW_COMMAND_UNCHANGED' in screen,'# Skill selection' not in screen])
except Exception as e:
    results.append({'name':'worker scenario setup','setup_error':str(e)})
    print(str(e),flush=True)
finally:
    if owned or (BASE/'herdr-state'/f'{SESSION}.fleet-state.json').exists():
        p=run([HELPER,'teardown',SESSION],timeout=30,checked=False)
        results.append({'name':'isolated lab teardown and default fleet tripwire','pass':p.returncode==0})
    save('worker-commands.json',logs)
    save('worker-results.json',results)
    print(json.dumps(results),flush=True)
