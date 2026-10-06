import os,pathlib,subprocess,shutil,json,time,signal
ROOT=pathlib.Path.cwd(); EVIDENCE=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M48YHW4X1N5R5ANWST7WZR3J'); logs=[]
base_env=os.environ.copy()
for k in list(base_env):
    if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ('FM_GATE_REFUSE_BYPASS','NO_MISTAKES_GATE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_TAB_ID','HERDR_WORKSPACE_ID','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND'): base_env.pop(k,None)
for policy in ('denied',):
    LAB=ROOT/('.gate-test-runtime/acp-'+policy); env=base_env.copy(); socket=None
    def run(args,log=True):
        p=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,timeout=30)
        if log: logs.append('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+f'exit={p.returncode}\n')
        return p
    try:
        assert run(['bash','bin/fm-lab-home.sh','create',str(LAB)]).returncode==0
        socket=run(['bash','bin/fm-lab-home.sh','tmux-dir',str(LAB)]).stdout.strip()
        env.update(FM_HOME=str(LAB),TMUX_TMPDIR=socket)
        for d in ('.omp/extensions','.pi/extensions/lib','bin','state/extensions/omp-primary-watch'): (LAB/d).mkdir(parents=True)
        shutil.copyfile(ROOT/'.omp/extensions/fm-primary-omp-watch.ts',LAB/'.omp/extensions/fm-primary-omp-watch.ts')
        shutil.copyfile(ROOT/'.pi/extensions/lib/fm-operational-input.ts',LAB/'.pi/extensions/lib/fm-operational-input.ts')
        shutil.copyfile(ROOT/'AGENTS.md',LAB/'AGENTS.md')
        for path in (ROOT/'bin').iterdir(): (LAB/'bin'/path.name).symlink_to(path,target_is_directory=path.is_dir())
        # Normalize only redundant lab-stock paths inserted by the extension so
        # the existing gate's stock-layout permission applies without any bypass.
        for name in ('fm-watch-arm.sh','fm-supervision-host.sh'):
            wrapper=LAB/'bin'/name; wrapper.unlink()
            wrapper.write_text('#!/bin/bash\nset -eu\n[ "${FM_HOME:-}" = '+repr(str(LAB))+' ] || exit 98\nfor field in ROOT STATE CONFIG DATA PROJECTS; do\n key="FM_${field}_OVERRIDE"; value=${!key-}\n case "$field:$value" in ROOT:"$FM_HOME"|STATE:"$FM_HOME/state"|CONFIG:"$FM_HOME/config"|DATA:"$FM_HOME/data"|PROJECTS:"$FM_HOME/projects"|*:"") unset "$key" ;; *) echo "unexpected lab relocation" >&2; exit 98 ;; esac\ndone\nexec /bin/bash '+repr(str(ROOT/'bin'/name))+' "$@"\n')
            wrapper.chmod(0o755)
        (LAB/'config/supervision-host').write_text('claude sonnet\n')
        if policy=='denied': (LAB/'config/session-launch-policy').write_text('omp-or-tc\n')
        pending={'version':2,'pending':[{'version':1,'token':'123-456-1','message':'supervision-host: launch policy refused: historical session-launch-policy refusal; predecessor custody is unchanged','predecessorArmPid':''}]}
        # No pending fixture: the real configured host must generate its refusal.
        engine=LAB/'forbidden-engine'
        engine.write_text('#!/bin/sh\necho "native Claude engine invocation refused by validation sentinel" >> "$FM_HOME/engine-attempts"\nexit 97\n'); engine.chmod(0o755)
        env['FM_SUPERVISION_ENGINE_CLAUDE_BIN']=str(engine)
        command='printf "%s\\n" "$$" > "$FM_HOME/state/.lock"; exec omp acp > "$FM_HOME/acp.jsonl" 2> "$FM_HOME/acp.stderr"'
        assert run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(LAB),'-e','FM_HOME='+str(LAB),'-e','FM_SUPERVISION_ENGINE_CLAUDE_BIN='+str(engine),command]).returncode==0
        def frames():
            f=LAB/'acp.jsonl'
            if not f.exists(): return []
            result=[]
            for row in f.read_text().splitlines():
                try: result.append(json.loads(row))
                except json.JSONDecodeError: pass
            return result
        def send(data):
            assert run(['tmux','-L','fm-lab','send-keys','-t','primary','-l',json.dumps(data)]).returncode==0
            assert run(['tmux','-L','fm-lab','send-keys','-t','primary','Enter']).returncode==0
            for _ in range(600):
                response=next((f for f in frames() if f.get('id')==data['id']),None)
                if response: return response
                time.sleep(.1)
            raise AssertionError('ACP response missing '+str(data['id']))
        init=send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':1,'clientCapabilities':{'fs':{'readTextFile':False,'writeTextFile':False},'terminal':False},'clientInfo':{'name':'fm-gate-live','version':'1'}}})
        logs.append('REAL ACP initialize response: '+json.dumps(init)+'\n')
        response=send({'jsonrpc':'2.0','id':2,'method':'session/new','params':{'cwd':str(LAB),'mcpServers':[]}})
        logs.append('REAL ACP session/new: '+json.dumps({k:v for k,v in response.items() if k!='result'} | {'result':{k:v for k,v in response.get('result',{}).items() if k not in ('models','availableModels','configOptions')}})+'\n')
        for _ in range(300):
            if (LAB/'state/.watch.lock').exists() and (LAB/'state/.last-watcher-beat').exists(): break
            time.sleep(.1)
        logs.append('CASE='+policy+'\n')
        for name in ('.watch.lock/pid','.watch.lock/identity','.last-watcher-beat','.omp-watch-extension-loaded','.supervision-host','.supervision-host.log','.watch.lock','.watcher-down','.watch-cycle-exits.log','.watch-recovery-ledger'):
            f=LAB/'state'/name
            logs.append('STATE '+name+'\n'+(f.read_text(errors='replace') if f.exists() and f.is_file() else 'ABSENT')+'\n')
        attempts=LAB/'engine-attempts'; logs.append('ENGINE '+(attempts.read_text() if attempts.exists() else 'no invocation')+'\n')
        logs.append('RUNTIME stderr:\n'+(LAB/'acp.stderr').read_text(errors='replace')+'\n')
        updates=[f for f in frames() if f.get('method')=='session/update' and f.get('params',{}).get('update',{}).get('sessionUpdate') not in ('available_commands_update','session_info_update')]
        logs.append('ACTUAL SESSION UPDATES:\n'+json.dumps(updates,indent=2)+'\n')
        handoff=LAB/'state/extensions/omp-primary-watch/session-replacement-actionable.json'
        closed=send({'jsonrpc':'2.0','id':3,'method':'session/close','params':{'sessionId':response['result']['sessionId']}})
        logs.append('REAL ACP session/close: '+json.dumps(closed)+'\n')
        logs.append('PERSISTED HANDOFF:\n'+(handoff.read_text() if handoff.exists() else 'ABSENT')+'\n')
    finally:
        if socket:
            run(['tmux','-L','fm-lab','kill-server'])
            run(['bash',str(ROOT/'bin/fm-watch-arm.sh'),'--stop'])
            # Stop only processes whose command line names this exact disposable home.
            ps=subprocess.run(['ps','-axo','pid=,command='],capture_output=True,text=True).stdout
            for row in ps.splitlines():
                if str(LAB) in row:
                    pid=int(row.strip().split(None,1)[0])
                    try: os.kill(pid,signal.SIGTERM)
                    except ProcessLookupError: pass
            time.sleep(.5)
            run(['bash','bin/fm-lab-home.sh','teardown',str(LAB)])
        shutil.rmtree(LAB,ignore_errors=True)
        logs.append('CASE '+policy+': private primary, lab watcher and disposable home removed.\n')
        (EVIDENCE/'live-omp-initial-refusal.txt').write_text('\n'.join(logs))
print('\n'.join(logs))
