import os, json, subprocess, pathlib, time
ROOT=pathlib.Path.cwd(); WORK=ROOT/'.lv'; HOME=WORK/'contribution-home'
E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4EXCPRHTRH93K0CGS9YW44Y')
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX','BASH_ENV','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):env.pop(k,None)
env.update(FM_HOME=str(HOME),FM_ROOT_OVERRIDE=str(ROOT),TMPDIR=str(WORK/'tmp'),FM_CONTRIBUTIONS_NOW='2026-10-09T12:00:00Z')
for d in ('data','state','config','projects'):(HOME/d).mkdir(parents=True,exist_ok=True)
input_path=HOME/'input.json'; input_path.write_text('{"backlog":{"present":true,"records":[]},"tasks":[]}\n')
rows=[]; log=[]
def record(task,size):
    d=HOME/'data'/task;d.mkdir(exist_ok=True)
    text=json.dumps({'schema':'fm-contributions.v1','task':task,'records':[]},separators=(',',':'))
    (d/'contributions.json').write_text(text+' '*(size-len(text)))
def call(mode,extra):
    args=[str(ROOT/'bin/fm-contributions.sh'),mode]+([str(input_path)] if mode=='snapshot' else [])
    p=subprocess.run(args,cwd=ROOT,env=dict(env,**extra),capture_output=True,text=True,timeout=30)
    log.append(f'$ bin/fm-contributions.sh {mode}'+(' .lv/contribution-home/input.json' if mode=='snapshot' else '')+f'\nexit={p.returncode}\nstdout={p.stdout}\nstderr={p.stderr}')
    return p

def case(name,refused,extra=None):
    pending=call('pending',extra or {});snapshot=call('snapshot',extra or {})
    assert snapshot.returncode==0
    data=json.loads(snapshot.stdout)
    if refused:
        assert pending.returncode!=0 and not pending.stdout
        assert data['unreadable_records']==1 and not data['complete'] and not data['proven_clear']
    else:
        assert pending.returncode==0 and json.loads(pending.stdout)==[]
        assert data['unreadable_records']==0 and data['complete'] and data['proven_clear']
    rows.append({'scenario':name,'pending_exit':pending.returncode,'pending_stdout':pending.stdout,'pending_stderr':pending.stderr,'snapshot':data})
    print(name, json.dumps({'pending_exit':pending.returncode,'unreadable_records':data['unreadable_records'],'complete':data['complete'],'proven_clear':data['proven_clear']}),flush=True)
    return data
try:
    clear=case('empty home proves clear coverage',False)
    record('visible',1048576)
    assert case('record exactly at 1 MiB accepted',False)==clear
    record('visible',1048577)
    case('record cap plus one refused',True)
    hidden=HOME/'data/visible';hidden.chmod(0o111)
    scan=subprocess.run(['find',str(HOME/'data'),'-mindepth','2','-maxdepth','2','-name','contributions.json','-print'],capture_output=True,text=True)
    assert scan.returncode!=0
    log.append('Permission fixture enumeration fails as intended:\n'+scan.stderr)
    case('oversized record in mode 0111 directory refused',True)
    hidden.chmod(0o755)
    record('visible',1048576);hidden.chmod(0o111)
    assert case('capped record in mode 0111 directory accepted',False)==clear
    (hidden/'contributions.json').chmod(0o000)
    case('unreadable record refuses verified inbox',True)
    (hidden/'contributions.json').chmod(0o644);hidden.chmod(0o755)
    (HOME/'data-link').symlink_to(HOME/'data',target_is_directory=True)
    for suffix in ('','/','////'):
        case('symlink data root refused '+repr(suffix),True,{'FM_DATA_OVERRIDE':str(HOME/'data-link')+suffix})
    assert case('normal data root with trailing slashes accepted',False,{'FM_DATA_OVERRIDE':str(HOME/'data')+'////'})==clear
    # Replace the listed capped record just before its real bounded read opens it.
    tools=WORK/'race-tools';tools.mkdir(exist_ok=True)
    head=tools/'head';head.write_text('''#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "$FM_HOME/data/visible/contributions.json" ] && [ -f "$FM_HOME/replacement.json" ]; then
    mv "$FM_HOME/replacement.json" "$arg" || exit 91
    printf 'replaced before bounded read\\n' >> "$FM_HOME/replacements.log"
  fi
done
exec /usr/bin/head "$@"
''');head.chmod(0o755)
    for mode in ('pending','snapshot'):
        record('visible',1048577);(hidden/'contributions.json').rename(HOME/'replacement.json')
        record('visible',1048576)
        p=call(mode,{'PATH':str(tools)+':'+env['PATH']})
        if mode=='pending':assert p.returncode!=0 and not p.stdout
        else:
            data=json.loads(p.stdout)
            assert p.returncode==0 and data['unreadable_records']==1 and not data['complete'] and not data['proven_clear']
        rows.append({'scenario':'oversized replacement after listing '+mode,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert len((HOME/'replacements.log').read_text().splitlines())==2
    (E/'contribution-cli-results.json').write_text(json.dumps(rows,indent=2)+'\n')
    (E/'contribution-cli-transcript.txt').write_text('\n\n'.join(log)+'\n')
finally:
    (HOME/'data/visible').chmod(0o755)
    if (HOME/'data/visible/contributions.json').exists():(HOME/'data/visible/contributions.json').chmod(0o644)
