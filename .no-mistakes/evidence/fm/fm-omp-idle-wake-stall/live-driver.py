import os, sys, json, time, subprocess, threading, shlex, shutil, re, html, tempfile
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT=Path.cwd(); LAB=Path(tempfile.mkdtemp(prefix='.idle-wake-lab-',dir=ROOT)); E=Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4DSW07B1PZ3X8NVQ78NGN8P'); E.mkdir(parents=True,exist_ok=True)
BASE='--baseline' in sys.argv
if BASE:
    E=E/'baseline'; E.mkdir(exist_ok=True)
LOG=E/'idle-wake-live.log'; EVENTS=[]; advised=set(); handled=set(); busy=threading.Event()
env=dict(os.environ)
for k in list(env):
    if k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_HOME','FM_WAKE_QUEUE','FM_WAKE_QUEUE_LOCK','TMUX','TMUX_PANE'] or (k.startswith('FM_') and k.endswith('_OVERRIDE')): env.pop(k,None)
env.update(FM_HOME=str(LAB),PI_CODING_AGENT_DIR=str(LAB/'agent'),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_HEARTBEAT='600',TMUX_TMPDIR='.idle-wake-lab/tmux')
def record(s):
    print(s,flush=True)
    with LOG.open('a') as f: f.write(s+'\n')
def run(args,check=True):
    p=subprocess.run(args,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if check and p.returncode: raise RuntimeError(f'{args}: {p.stdout}')
    return p.stdout
def tm(*args): return run(['tmux','-L','fm-lab',*args])
def screen(): return tm('capture-pane','-p','-t','primary','-S','-200')
def wait(fn,limit=60):
    end=time.time()+limit
    while time.time()<end:
        if fn(): return
        time.sleep(.5)
    raise RuntimeError('Timed out: '+screen())
def txt(m):
    c=m.get('content'); return ' '.join(x.get('text','') for x in c if isinstance(x,dict)) if isinstance(c,list) else (c if isinstance(c,str) else '')
class Model(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        req=json.loads(self.rfile.read(int(self.headers.get('content-length',0))))
        messages=req.get('messages',[]); tools={t.get('function',{}).get('name'):t.get('function',{}) for t in req.get('tools',[])}
        users=[txt(m) for m in messages if m.get('role')=='user']; last=users[-1] if users else ''
        alltext=' '.join(txt(m) for m in messages)
        marker=next((x for x in ['DRAFT-ADVISE','EMPTY-ADVISE'] if x in alltext and x not in advised),'')
        call=None; action='ack'
        if 'advise' in tools and marker and marker not in advised:
            advised.add(marker); action='advisor-note'; call=('advise',{'note':marker+'-NOTE verify before finishing.','severity':'concern'})
        elif 'bash' in tools and 'FIRSTMATE WATCHER WAKE:' in last and last not in handled:
            handled.add(last); action='drain-and-ack'
            command='out=$(bin/fm-wake-drain.sh 2>&1); rc=$?; printf "%s\\n" "$out"; [ "$rc" -eq 0 ] || exit "$rc"; while IFS= read -r line; do case "$line" in WAKE_ACK_REQUIRED:*) cmd=${line#*run }; bash -c "$cmd" || exit $?;; esac; done <<< "$out"'
            schema=tools['bash'].get('parameters',{}); props=schema.get('properties',{}); args={}
            for k in schema.get('required',[]):
                if k in ['command','cmd','script']: args[k]=command
                elif k in ['timeout','timeout_ms']: args[k]=30000
                elif k in ['i','intent','description']: args[k]='Draining lab watcher wake'
                else: args[k]=None
            args['command']=command
            call=('bash',args)
        elif 'bash' in tools and 'BUSY-HOLD' in last and not any(txt(m) for m in messages if m.get('role')=='assistant' and 'busy-finished' in txt(m)):
            if 'BUSY-HOLD' not in handled:
                handled.add('BUSY-HOLD'); action='busy-hold'; busy.set(); time.sleep(14)
        event={'time':time.time(),'action':action,'last_user':last,'tool_results':[txt(m) for m in messages if m.get('role')=='tool'][-2:]}
        EVENTS.append(event)
        with (E/'model-events.jsonl').open('a') as f: f.write(json.dumps(event)+'\n')
        if call:
            delta={'role':'assistant','tool_calls':[{'index':0,'id':'call_'+str(len(EVENTS)),'type':'function','function':{'name':call[0],'arguments':json.dumps(call[1])}}]}; finish='tool_calls'
        else: delta={'role':'assistant','content':'busy-finished' if action=='busy-hold' else 'ack'}; finish='stop'
        try:
            self.send_response(200); self.send_header('content-type','text/event-stream'); self.end_headers()
            for d in [delta,{}]:
                chunk={'id':'lab','object':'chat.completion.chunk','created':int(time.time()),'model':'m1','choices':[{'index':0,'delta':d,'finish_reason':None if d else finish}]}
                self.wfile.write(b'data: '+json.dumps(chunk).encode()+b'\n\n')
            self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): pass
server=ThreadingHTTPServer(('127.0.0.1',0),Model)
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
    run(['bin/fm-lab-home.sh','create',str(LAB)])
    env['TMUX_TMPDIR']=run(['bin/fm-lab-home.sh','tmux-dir',str(LAB)]).strip()
    (LAB/'agent').mkdir()
    (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (LAB/'agent/config.yml').write_text('setupVersion: 2\nmodelRoles:\n  default: lab/m1\n  tiny: lab/m1\n  advisor: lab/m1\n  vision: lab/m1\nadvisor:\n  enabled: true\n')
    (LAB/'agent/models.yml').write_text(f'providers:\n  lab:\n    baseUrl: http://127.0.0.1:{server.server_address[1]}/v1\n    apiKey: lab-key\n    api: openai-completions\n    models:\n      - id: m1\n        contextWindow: 200000\n        maxTokens: 4096\n')
    for rel in ['.omp/extensions/fm-primary-omp-watch.ts','.pi/extensions/lib/fm-operational-input.ts','bin/fm-operational-input.sh']:
        dest=LAB/rel; dest.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(ROOT/rel,dest)
    if BASE:
        (LAB/'.omp/extensions/fm-primary-omp-watch.ts').write_text(run(['git','show','32fbe8edbbd9d7c75990c3c259b7fb4fbf80de6c:.omp/extensions/fm-primary-omp-watch.ts']))
    arm=LAB/'bin/fm-watch-arm.sh'
    arm.write_text('#!/usr/bin/env bash\nexec env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE '+shlex.quote(str(ROOT/'bin/fm-watch-arm.sh'))+' "$@"\n')
    arm.chmod(0o755)
    record('Lab arm adapter removes extension-injected path overrides before executing the unchanged real watcher arm; no gate bypass.')
    cmd='printf "%s\\n" $$ > '+shlex.quote(str(LAB/'state/.lock'))+'; exec omp --model lab/m1 --no-extensions -e '+shlex.quote(str(LAB/'.omp/extensions/fm-primary-omp-watch.ts'))+' --no-lsp --no-skills --no-rules --no-title --tools bash --approval-mode yolo --config '+shlex.quote(str(ROOT/'.omp/fm-session-overlay.yml'))
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'-e','FM_HOME='+str(LAB),'bash -c '+shlex.quote(cmd))
    wait(lambda:(LAB/'state/.omp-watch-extension-loaded').exists())
    wait(lambda:(LAB/'state/.watch.lock').exists())
    record('Real omp owns session lock; real watcher started on 120x40 private tmux grid.')
    def submit(t): tm('send-keys','-t','primary','-l',t); time.sleep(.5); tm('send-keys','-t','primary','Enter')
    def ready_note(marker):
        submit(marker+' reply ack'); wait(lambda:marker+'-NOTE' in screen()); time.sleep(4)
        (E/(marker.lower()+'.txt')).write_text(screen())
    def signal(name):
        (LAB/'state'/f'{name}.turn-ended').write_text(str(time.time())+'\n')
        record('Published real watcher signal: '+name)
    def drained(name):
        return any(name in e['last_user'] and e['action']=='drain-and-ack' for e in EVENTS) and not ((LAB/'state/.wake-queue').exists() and (LAB/'state/.wake-queue').stat().st_size)
    ready_note('EMPTY-ADVISE'); start=time.time(); signal('idle-empty')
    if BASE:
        time.sleep(20)
        assert (LAB/'state/.wake-queue').stat().st_size > 0, 'Base wake unexpectedly drained'
        assert not any(e['action']=='drain-and-ack' for e in EVENTS), 'Base started a wake turn'
        (E/'stranded-wake.txt').write_text(screen())
        shutil.copyfile(LAB/'state/.wake-queue',E/'stranded-wake-queue.tsv')
        record('REPRODUCED base regression: idle advisor-tail wake remained queued for 20s; no wake reached the model.')
        tm('send-keys','-t','primary','Enter'); wait(lambda:drained('idle-empty')); time.sleep(2)
        (E/'manual-enter-recovery.txt').write_text(screen())
        record('Base wake drained only after manual Enter, reproducing the operator workaround.')
        sys.exit(0)
    wait(lambda:drained('idle-empty')); time.sleep(3)
    record(f'PASS idle advisor tail / empty composer: durable wake consumed and acknowledged in {time.time()-start:.1f}s without Enter.'); (E/'idle-empty.txt').write_text(screen())
    ready_note('DRAFT-ADVISE'); tm('send-keys','-t','primary','-l','operator draft kept'); time.sleep(1)
    signal('idle-draft'); wait(lambda:drained('idle-draft')); time.sleep(3)
    assert 'operator draft kept' in screen(), 'Draft disappeared'
    assert not any('operator draft kept' in e['last_user'] for e in EVENTS), 'Draft submitted'
    record('PASS idle advisor tail / operator draft: wake acknowledged, draft still rendered and never sent to model.'); (E/'idle-draft.txt').write_text(screen())
    signal('idle-repeat'); wait(lambda:drained('idle-repeat')); time.sleep(3)
    assert 'operator draft kept' in screen()
    record('PASS successor watcher: another wake consumed without manual rearm; draft retained.'); (E/'idle-repeat.txt').write_text(screen())
    tm('send-keys','-t','primary','C-u'); submit('BUSY-HOLD reply busy-finished'); wait(lambda:busy.is_set()); signal('busy-wake')
    time.sleep(5); assert (LAB/'state/.wake-queue').exists() and (LAB/'state/.wake-queue').stat().st_size, 'Busy fixture did not queue a real wake'
    record('Busy-boundary observation: durable wake queued while original model response remained in flight.')
    wait(lambda:drained('busy-wake')); time.sleep(3)
    assert any(e['action']=='busy-hold' for e in EVENTS), 'Running turn cancelled'
    record('PASS busy boundary: original response completed, queued follow-up drained and acknowledged without cancellation.'); (E/'busy-wake.txt').write_text(screen())
    for name in ['.watch-cycle-exits.log','.wake-queue','.wake-queue.seq']:
        p=LAB/'state'/name
        if p.exists(): shutil.copyfile(p,E/name.lstrip('.'))
    # Reviewer-visible HTML is generated from captured real product terminal output.
    sections=[]
    for name in ['empty-advise','idle-empty','draft-advise','idle-draft','idle-repeat','busy-wake']:
        p=E/(name+'.txt')
        if p.exists(): sections.append('<h2>'+name+'</h2><pre>'+html.escape(p.read_text())+'</pre>')
    (E/'terminal-evidence.html').write_text('<!doctype html><meta charset="utf-8"><title>Live omp idle wake lab</title><style>body{background:#161616;color:#eee;font:14px monospace}pre{white-space:pre;line-height:1.2;border:1px solid #666;padding:16px}h2{color:#8ed}</style>'+''.join(sections))
except Exception as exc:
    record('FAIL '+str(exc))
    snapshots=[]
    if (LAB/'state').exists():
        for p in (LAB/'state').rglob('*'):
            if p.is_file() and p.stat().st_size < 30000:
                snapshots.append(str(p.relative_to(LAB))+'\n'+p.read_text(errors='replace'))
    (E/'failure-state.txt').write_text('\n\n'.join(snapshots))
    (E/'failure-processes.txt').write_text('\n'.join(x for x in run(['ps','-axo','pid=,ppid=,command=']).splitlines() if str(LAB) in x))
    try: (E/'failure-screen.txt').write_text(screen())
    except Exception: pass
    raise
finally:
    (E/'complete-run-model-events.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in EVENTS))
    try:
        record(tm('kill-server').strip() or 'Private tmux server stopped.')
    except Exception as exc: record('tmux teardown: '+str(exc))
    stop=run(['bin/fm-watch-arm.sh','--stop'],check=False); record(stop.strip())
    record(run(['bin/fm-lab-home.sh','teardown',str(LAB)],check=False).strip() or 'Private tmux socket directory removed.')
    server.shutdown()
    if LAB.exists(): shutil.rmtree(LAB)
    record('Disposable lab home removed.')
