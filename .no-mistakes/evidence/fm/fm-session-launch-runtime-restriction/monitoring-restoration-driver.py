import os, pathlib, subprocess, tempfile, json, time, shutil, signal
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M48YHW4X1N5R5ANWST7WZR3J')
SHA = 'b6998beb2ed31a5c324941f4f73d3c06bf2ff71f'
report = {'head': SHA, 'scenario': 'ordinary monitoring restoration', 'commands': [], 'phases': [], 'cleanup': {}}
scratch = None; source = None; home = None; socket = None; created = False
base = os.environ.copy()
# Retain the gate marker. Remove ambient routing, never disable a protection.
for key in list(base):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in ('FM_GATE_REFUSE_BYPASS','FM_HOME','TMUX','TMUX_TMPDIR','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_TAB_ID','HERDR_WORKSPACE_ID'):
        base.pop(key, None)
env = base.copy()
def run(args, cwd=ROOT, timeout=30, required=True):
    p = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    report['commands'].append({'args': list(map(str,args)), 'cwd': str(cwd), 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    if required and p.returncode: raise RuntimeError('command refused: '+repr(args)+'\n'+p.stderr)
    return p

def frames():
    result=[]
    if (home/'acp.jsonl').exists():
        for line in (home/'acp.jsonl').read_text().splitlines():
            try: result.append(json.loads(line))
            except ValueError: pass
    return result

handled_permissions=set()
def send(identifier, method, params):
    message={'jsonrpc':'2.0','id':identifier,'method':method,'params':params}
    run(['tmux','-L','fm-lab','send-keys','-t','primary','-l',json.dumps(message)])
    run(['tmux','-L','fm-lab','send-keys','-t','primary','Enter'])
    deadline=time.monotonic()+90
    while time.monotonic()<deadline:
        for request in frames():
            if request.get('method')!='session/request_permission' or request['id'] in handled_permissions:
                continue
            call=request['params']['toolCall']
            command=call.get('rawInput',{}).get('command')
            allowed=command==f'bash {source}/bin/fm-lock.sh'
            outcome={'outcome':'selected','optionId':'allow_once' if allowed else 'reject_once'}
            reply={'jsonrpc':'2.0','id':request['id'],'result':{'outcome':outcome}}
            run(['tmux','-L','fm-lab','send-keys','-t','primary','-l',json.dumps(reply)])
            run(['tmux','-L','fm-lab','send-keys','-t','primary','Enter'])
            handled_permissions.add(request['id'])
            report.setdefault('scoped_permissions',[]).append({'call':call,'outcome':outcome})
        response=next((x for x in frames() if x.get('id')==identifier),None)
        if response:
            report.setdefault('acp_responses',[]).append(response)
            if 'error' in response: raise RuntimeError('ACP error: '+json.dumps(response))
            return response.get('result',{})
        time.sleep(.2)
    raise RuntimeError('ACP response timeout: '+method)

def snapshot(label):
    result={'label':label,'state':{}}
    for name in ('.watch.lock/pid','.watch.lock/pid-identity','.watch.lock/fm-home','.watch.lock/watcher-path','.last-watcher-beat','.omp-watch-extension-loaded','.supervision-host.log','.watch-cycle-exits.log','.watcher-down'):
        path=home/'state'/name
        result['state'][name]=path.read_text(errors='replace') if path.is_file() else None
    result['pending']=(home/'state/extensions/omp-primary-watch/session-replacement-actionable.json').read_text() if (home/'state/extensions/omp-primary-watch/session-replacement-actionable.json').exists() else None
    result['engine_attempts']=(home/'forbidden-invocations').read_text() if (home/'forbidden-invocations').exists() else ''
    pid=result['state'].get('.watch.lock/pid')
    result['watcher_alive']=bool(pid and subprocess.run(['kill','-0',pid.strip()],capture_output=True).returncode==0)
    beat=home/'state/.last-watcher-beat'
    result['beacon_age']=time.time()-beat.stat().st_mtime if beat.exists() else None
    health=run(['bash','-c','. "$1"; fm_watcher_healthy "$2" "$3" 15 "$4"', '_',str(source/'bin/fm-wake-lib.sh'),str(home/'state'),str(source/'bin/fm-watch.sh'),str(home)],cwd=source,required=False)
    result['ready']=health.returncode==0
    report['phases'].append(result)
    return result

try:
    assert run(['git','rev-parse','HEAD']).stdout.strip()==SHA
    # Cleanup is installed by this enclosing try/finally before any creation.
    scratch=pathlib.Path(tempfile.mkdtemp(prefix='monitoring-scratch-',dir=EVIDENCE))
    scratch.chmod(0o700); source=scratch/'source'; home=scratch/'home'
    report['scratch']=str(scratch); report['source']=str(source); report['home']=str(home)
    assert '/.no-mistakes/worktrees/' not in str(source)
    assert scratch.stat().st_uid==os.getuid() and scratch.stat().st_mode & 0o777==0o700
    assert not source.exists() and not home.exists()
    run(['git','worktree','add','--detach',str(source),SHA],timeout=60)
    created=True
    assert run(['git','rev-parse','HEAD'],cwd=source).stdout.strip()==SHA
    run(['bash',str(source/'bin/fm-lab-home.sh'),'create',str(home)],cwd=source)
    socket=run(['bash',str(source/'bin/fm-lab-home.sh'),'tmux-dir',str(home)],cwd=source).stdout.strip()
    env.update(FM_HOME=str(home),TMUX_TMPDIR=socket)
    (home/'.omp/extensions').mkdir(parents=True)
    (home/'.pi/extensions/lib').mkdir(parents=True)
    (home/'.omp/extensions/fm-primary-omp-watch.ts').symlink_to(source/'.omp/extensions/fm-primary-omp-watch.ts')
    (home/'.pi/extensions/lib/fm-operational-input.ts').symlink_to(source/'.pi/extensions/lib/fm-operational-input.ts')
    (home/'bin').symlink_to(source/'bin',target_is_directory=True)
    observer=home/'.omp/extensions/evidence-observer.ts'
    observer.write_text('import { appendFileSync } from "node:fs";\nexport default function(api: any) { for (const event of ["session_start", "session_shutdown", "message_start", "before_agent_start"]) api.on(event, (value: any) => { appendFileSync(process.env.FM_HOME + "/events.jsonl", JSON.stringify({event, value}) + "\\n"); }); }\n')
    (home/'config/session-launch-policy').write_text('omp-or-tc\n')
    (home/'config/supervision-host').write_text('omp\n')
    sentinel=home/'forbidden-engine'
    sentinel.write_text('#!/bin/sh\nprintf "invoked\\n" >> "$FM_HOME/forbidden-invocations"\nexit 97\n'); sentinel.chmod(0o700)
    env['FM_SUPERVISION_ENGINE_CLAUDE_BIN']=str(sentinel)
    # Replay the retained production-generated current-head record, not fabricated state.
    pending=EVIDENCE/'targeted-replay-current-head-pending.json'
    generated=json.loads(pending.read_text())
    assert generated['pending'] and 'not a verified supervision engine' in generated['pending'][0]['message']
    directory=home/'state/extensions/omp-primary-watch'; directory.mkdir(parents=True)
    (directory/'session-replacement-actionable.json').write_text(pending.read_text())
    report['pending_provenance']=str(pending)
    command='exec omp acp > "$FM_HOME/acp.jsonl" 2> "$FM_HOME/acp.stderr"'
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(home),command],cwd=source)
    send(1,'initialize',{'protocolVersion':1,'clientCapabilities':{'fs':{'readTextFile':False,'writeTextFile':False},'terminal':False},'clientInfo':{'name':'fm-monitoring-evidence','version':'1'}})
    session=send(2,'session/new',{'cwd':str(home),'mcpServers':[]})
    sid=session['sessionId']
    model='openai-codex/gpt-6.1-sol'
    configured=send(3,'session/set_config_option',{'sessionId':sid,'configId':'model','value':model})
    assert next(c['currentValue'] for c in configured['configOptions'] if c['id']=='model')==model
    send(30,'session/prompt',{'sessionId':sid,'prompt':[{'type':'text','text':f'This is an isolated marked lab. Run only bash {source}/bin/fm-lock.sh and call fm_watch_arm_omp once. Do not run any other tools or launch runtimes. Reply ARMED.'}]})
    deadline=time.monotonic()+45
    while time.monotonic()<deadline:
        if run(['bash','-c','. "$1"; fm_watcher_healthy "$2" "$3" 15 "$4"', '_',str(source/'bin/fm-wake-lib.sh'),str(home/'state'),str(source/'bin/fm-watch.sh'),str(home)],cwd=source,required=False).returncode==0: break
        time.sleep(.2)
    denied=snapshot('unchanged denied engine configuration')
    send(4,'session/prompt',{'sessionId':sid,'prompt':[{'type':'text','text':'This is an isolated evidence lab. Do not run tools, launch sessions, repair or re-arm. Briefly report any Firstmate watcher refusal already delivered in your context; otherwise reply NO_NOTIFICATION.'}]})
    snapshot('after actual model prompt')
    # Legitimate disposable transition removes only host config, preserving policy.
    (home/'config/supervision-host').unlink()
    send(5,'session/close',{'sessionId':sid})
    session=send(6,'session/new',{'cwd':str(home),'mcpServers':[]}); sid=session['sessionId']
    send(7,'session/set_config_option',{'sessionId':sid,'configId':'model','value':model})
    deadline=time.monotonic()+45
    while time.monotonic()<deadline:
        if run(['bash','-c','. "$1"; fm_watcher_healthy "$2" "$3" 15 "$4"', '_',str(source/'bin/fm-wake-lib.sh'),str(home/'state'),str(source/'bin/fm-watch.sh'),str(home)],cwd=source,required=False).returncode==0: break
        time.sleep(.2)
    transitioned=snapshot('after legitimate host configuration removal')
    send(8,'session/prompt',{'sessionId':sid,'prompt':[{'type':'text','text':'Do not run tools or launch sessions. Reply MONITORING_LAB_COMPLETE.'}]})
    snapshot('transitioned watcher after actual model prompt')
    send(9,'session/close',{'sessionId':sid})
    report['enabled_policy_retained']=(home/'config/session-launch-policy').read_text()=='omp-or-tc\n'
    events=[json.loads(line) for line in (home/'events.jsonl').read_text().splitlines()]
    refusal_events=[event for event in events if event['event']=='message_start' and event.get('value',{}).get('message',{}).get('role')=='user' and generated['pending'][0]['message'] in json.dumps(event,ensure_ascii=False)]
    report['actual_refusal_delivery_count']=len(refusal_events)
    report['pending_consumed_after_close']=not (directory/'session-replacement-actionable.json').exists()
    report['no_forbidden_engine_invocations']=not (home/'forbidden-invocations').exists()
    report['no_denied_host_retries']=all(phase['state']['.supervision-host.log'] is None for phase in report['phases'])
    report['result']='pass' if denied['ready'] and transitioned['ready'] and len(refusal_events)==1 and report['pending_consumed_after_close'] and report['no_forbidden_engine_invocations'] and report['no_denied_host_retries'] else 'inconclusive'
except Exception as error:
    report['result']='blocked'; report['error']=str(error)
    if created and home and home.exists():
        snapshot('failure observation')
finally:
    if home and home.exists():
        for name in ('acp.jsonl','acp.stderr','events.jsonl'):
            path=home/name
            if path.exists(): shutil.copyfile(path,EVIDENCE/('monitoring-restoration-'+name))
        if socket:
            run(['tmux','-L','fm-lab','kill-server'],cwd=source if created else ROOT,required=False)
        if created:
            run(['bash',str(source/'bin/fm-watch-arm.sh'),'--stop'],cwd=source,required=False)
        # Signal only processes naming this exact newly owned home/source.
        rows=subprocess.run(['ps','-axo','pid=,command='],capture_output=True,text=True).stdout.splitlines()
        owned=[]
        for row in rows:
            fields=row.strip().split(None,1)
            if len(fields)==2 and (str(home) in fields[1] or str(source) in fields[1]):
                pid=int(fields[0])
                if pid!=os.getpid():
                    owned.append(pid)
                    try: os.kill(pid,signal.SIGTERM)
                    except ProcessLookupError: pass
        time.sleep(1)
        report['cleanup']['signalled_owned_pids']=owned
        if socket:
            teardown=run(['bash',str(source/'bin/fm-lab-home.sh'),'teardown',str(home)],cwd=source,required=False)
            report['cleanup']['socket_removed']=teardown.returncode==0 and not pathlib.Path(socket).exists()
        if not socket or report['cleanup'].get('socket_removed'):
            shutil.rmtree(home)
            report['cleanup']['home_removed']=not home.exists()
    if created:
        removal=run(['git','worktree','remove',str(source)],required=False,timeout=60)
        report['cleanup']['worktree_removed']=removal.returncode==0 and not source.exists()
    if scratch and scratch.exists() and not any(scratch.iterdir()):
        scratch.rmdir(); report['cleanup']['scratch_removed']=True
    (EVIDENCE/'monitoring-restoration-result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ('commands','acp_responses')},indent=2))
