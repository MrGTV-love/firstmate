import os, pathlib, subprocess, time, json, shutil
ROOT = pathlib.Path.cwd()
EVID = pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4F9B87M5A8ZB6B0YDWF5A7V')
EVID.mkdir(parents=True, exist_ok=True)
BASE = ROOT / '.live-validation' / 'homes'
BASE.mkdir(parents=True, exist_ok=True)
ENV = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION')}
ENV['PATH'] = '/usr/bin:/bin:/opt/homebrew/bin:' + ENV['PATH']
ENV['TMPDIR'] = str(BASE)
log = []
results = []
def home(name):
    h=BASE/name
    for d in ('state','data','config','projects'): (h/d).mkdir(parents=True,exist_ok=True)
    (h/'config/supervision-host-off').touch()
    return h
def run(h,label,extra=None):
    env=dict(ENV,FM_HOME=str(h)); env.update(extra or {})
    t=time.monotonic()
    p=subprocess.run(['/bin/bash',str(ROOT/'bin/fm-wake-drain.sh')],env=env,text=True,capture_output=True,timeout=180)
    log.append(f'\n### {label}\n$ FM_HOME=<isolated {h.name}> /bin/bash bin/fm-wake-drain.sh\nelapsed={time.monotonic()-t:.3f}s exit={p.returncode}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}')
    assert p.returncode==0, f'{label}: drain exit {p.returncode}'
    return p.stdout
def scenario(name,fn):
    try:
        detail=fn(); results.append(dict(name=name,result='pass',live=True,evidence='drain-live-transcript.txt',reason=detail))
    except Exception as e:
        results.append(dict(name=name,result='fail',live=True,evidence='drain-live-transcript.txt',reason=str(e)))
    (EVID/'drain-live-transcript.txt').write_text('\n'.join(log))
    (EVID/'drain-live-results.json').write_text(json.dumps(results,indent=2))
    print(json.dumps(results[-1]),flush=True)
def presentation():
    h=home('presentation'); f=h/'state/task.status'
    f.write_text('needs-decision [key=api]: choose REST or RPC\nblocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=task pending-reply-id=abcdef0123456789 request=ship it\nnote: captain answer is REST\nnote: routine acknowledgement\n')
    a=run(h,'Present buried answers and independent keyed decisions')
    assert 'task note: captain answer is REST' in a and 'task note: routine acknowledgement' in a
    assert '[key=api] needs-decision: choose REST or RPC' in a and '[key=pending-reply-' in a
    b=run(h,'Keep decisions open without replaying presented notes')
    assert 'captain answer is REST' not in b and '[key=api] needs-decision' in b
    with f.open('a') as s:s.write('resolved [key=api]: picked REST\nresolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=task pending-reply-id=abcdef0123456789 via=status\nnote: new answer after acknowledgement\n')
    c=run(h,'Resolve both keyed decisions and present reserved close exactly once')
    assert 'OPEN DECISIONS' not in c and 'pending-reply-resolved:' in c and 'new answer after acknowledgement' in c
    d=run(h,'No replay after reserved close')
    assert 'pending-reply-resolved:' not in d and 'new answer after acknowledgement' not in d
    return 'Both buried notes surfaced once; independent keys remained open until explicit closes; reserved close surfaced once.'
def cursor():
    h=home('cursor'); f=h/'state/task.status'
    f.write_text('needs-decision [key=api]: choose API\n'+'working: padding\n'*400)
    assert 'choose API' in run(h,'Fold cold buried decision')
    with f.open('a') as s:s.write('working: new padding\n'*20)
    assert 'choose API' in run(h,'Retain buried decision after history growth')
    cf=h/'state/.task.open-decisions-cursor'
    cf.write_text('version=garbage\n')
    assert 'choose API' in run(h,'Rebuild invalid decision checkpoint')
    f.write_text('blocked [key=release]: truncated new blocker\n')
    a=run(h,'Refold truncated status without old decision')
    assert 'truncated new blocker' in a and 'choose API' not in a
    replacement=f.with_suffix('.new'); replacement.write_text('needs-decision [key=deploy]: replaced log decision\n'); replacement.replace(f)
    b=run(h,'Detect inode replacement and surface new decision')
    assert 'replaced log decision' in b and 'truncated new blocker' not in b
    with f.open('a') as s:s.write('resolved [key=deploy]: answered\nworking: later padding\n')
    assert 'OPEN DECISIONS' not in run(h,'Explicit resolution durably clears replacement decision')
    return 'Cold, incremental, damaged-checkpoint, truncated-file, and replacement-file folds preserved current keyed state.'
def fault():
    h=home('fault'); f=h/'state/task.status'; f.write_text('note: bootstrap\n');run(h,'Prime presentation before read failure')
    with f.open('a') as s:s.write('note: must survive uncertain read\n')
    manifest=h/'state/.status-presentation-cursor'
    before={p.name:p.read_bytes() for p in (h/'state').iterdir() if 'presentation' in p.name and p.is_file()}
    reader=h/'fail-reader';reader.write_text('#!/bin/bash\nexit 1\n');reader.chmod(0o755)
    a=run(h,'Fail identity read without silently acknowledging pending bytes',{'FM_STATUS_IDENTITY_READER':str(reader)})
    assert 'STATUS PRESENTATION INCOMPLETE:' in a
    after={p.name:p.read_bytes() for p in (h/'state').iterdir() if 'presentation' in p.name and p.is_file()}
    assert before==after,'failed identity read changed presentation state'
    b=run(h,'Retry identity failure and recover unacknowledged note')
    assert 'must survive uncertain read' in b
    assert 'must survive uncertain read' not in run(h,'Recovered note is not replayed')
    return 'Read failure emitted incomplete-presentation warning, preserved cursor bytes, and retried pending note exactly once.'
def race():
    h=home('race'); f=h/'state/task.status';f.write_text('working: padding\n'*5000+'done: first completion\n')
    reader=h/'append-reader'
    reader.write_text('#!/usr/bin/env python3\nimport sys\np,s,n=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])\nwith open(p,"rb") as f:\n f.seek(s); b=f.read(n)\nif len(b)!=n: sys.exit(1)\nsys.stdout.buffer.write(b); sys.stdout.buffer.flush()\nif n==65536:\n with open(p,"ab") as f: f.write(b"done: completion appended during read\\n")\n')
    reader.chmod(0o755)
    a=run(h,'Append completion during bounded latest-event read',{'FM_STATUS_SPAN_READER':str(reader)})
    assert 'STATUS OUTCOME BACKSTOP (' not in a
    b=run(h,'Retry captures final completion instead of superseded completion')
    assert 'task done: completion appended during read' in b and 'task done: first completion' not in b
    return 'Fresh post-read metadata deferred changing latest-event snapshot; next drain presented final completion.'
def delayed():
    h=home('delayed'); f=h/'state/task.status';f.write_text('working: first routine event\nresolved [key=side-1]: ordinary close\nworking: latest routine event\n')
    assert not run(h,'Routine working and non-reserved close stay silent on empty queue').strip()
    env=dict(ENV,FM_HOME=str(h))
    p=subprocess.run(['/bin/bash','-c','. "$1"; fm_wake_append signal task.status "signal: task.status"','_',str(ROOT/'bin/fm-wake-lib.sh')],env=env,capture_output=True,text=True,timeout=30)
    assert p.returncode==0,p.stderr
    a=run(h,'Publish delayed signal after empty-queue scan')
    assert 'first routine event' in a and 'latest routine event' in a and '\tsignal\ttask.status\t' in a
    return 'Routine-only drain was silent, but later real durable wake retained all routine annotations and raw signal row.'
def growth():
    values={}
    for name,tasks,hist in [('small',3,3),('large',3,60),('many',11,3)]:
        h=home('growth-'+name)
        for t in range(tasks):
            (h/f'state/fleet{t}.status').write_text(f'working: starting task {t}\n'+''.join(f'resolved [key=side-{i}]: routine close {i}\nworking: step {i}\n' for i in range(hist)))
        count=h/'entries';count.touch()
        env=dict(ENV,FM_HOME=str(h),SUBSHELL_ENTRY_COUNT=str(count),SUBSHELL_ENTRY_DRAIN=str(ROOT/'bin/fm-wake-drain.sh'))
        script="set -T; seen_depth=0; trap 'if [ \"$BASH_SUBSHELL\" != \"$seen_depth\" ]; then seen_depth=$BASH_SUBSHELL; printf x >> \"$SUBSHELL_ENTRY_COUNT\"; fi' DEBUG; . \"$SUBSHELL_ENTRY_DRAIN\""
        p=subprocess.run(['/bin/bash','-c',script],env=env,capture_output=True,text=True,timeout=240)
        assert p.returncode==0,p.stderr
        values[name]=count.stat().st_size
        log.append(f'\n### Cold drain process instrumentation\ntasks={tasks} routine-pairs-per-task={hist} subshell_entries={values[name]} exit={p.returncode}\nstdout={p.stdout}\nstderr={p.stderr}')
    assert values['large']<=values['small']+40,values
    per=(values['many']-values['small'])//8
    assert per<=40,values
    log.append('Measured cold-history growth: '+json.dumps(dict(values,per_added_task=per)))
    return json.dumps(dict(values,per_added_task=per,history_growth=values['large']-values['small']))
try:
    scenario('Present buried notes and reserved replies once while keeping decisions open until explicitly answered',presentation)
    scenario('Recover keyed decisions across cold history, append growth, damaged checkpoints, truncation, and replacement',cursor)
    scenario('Preserve unacknowledged status and show an incomplete warning when metadata reads fail',fault)
    scenario('Defer a completion appended during the latest-event read and surface its final value on retry',race)
    scenario('Keep empty-queue routine history silent without losing a later signal annotation',delayed)
    scenario('Keep cold-drain subshell entries flat with history and bounded per added task on Bash 3.2',growth)
finally:
    shutil.rmtree(BASE)
print('RESULTS',json.dumps(results),flush=True)
