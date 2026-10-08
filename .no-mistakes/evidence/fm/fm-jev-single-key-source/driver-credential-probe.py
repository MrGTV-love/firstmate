import pathlib,subprocess,os,json,time
R=pathlib.Path.cwd();V=R/'.live-validation';E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4C9C1P6TN97HD7NAANKCK9T');S=json.loads((V/'service.json').read_text());D=V/'credential-probes';D.mkdir(exist_ok=True)
for name in ['dirname','git','jq','grep','tr','mktemp','rm','cat','node']:
 real=subprocess.check_output(['bash','-c','command -v "$1"','_',name],text=True).strip()
 script='#!/bin/bash\npublic=false; private=false; argv_key=false\n[ "${TYPESAFE_API_KEY+x}" != x ] || public=true\n[ "${TYPESAFE_API_KEY_PRIVATE+x}" != x ] || private=true\nif [ -n "${TYPESAFE_API_KEY:-}" ]; then case "$*" in *"$TYPESAFE_API_KEY"*) argv_key=true ;; esac; fi\nprintf \'{"command":"'+name+'","public":%s,"private":%s,"key_on_argv":%s}\\n\' "$public" "$private" "$argv_key" >> "$FM_CREDENTIAL_PROBE"\nexec '+real+' "$@"\n'
 (D/name).write_text(script);(D/name).chmod(0o755)
base=os.environ.copy()
for k in ['TYPESAFE_API_KEY','TYPESAFE_API_KEY_PRIVATE','FM_ROOT_OVERRIDE','FM_CONFIG_OVERRIDE','FM_STATE_OVERRIDE','FM_TEST_SEAM']:base.pop(k,None)
base.update(FM_HOME=str(V/'belay-lane'),HOME=str(V/'probe-user'),PATH=str(D)+':'+base['PATH'],FM_CREDENTIAL_PROBE=str(D/'calls.jsonl'),TMPDIR=str(V),HTTPS_PROXY=S['proxy_url'],https_proxy=S['proxy_url'],NODE_EXTRA_CA_CERTS=S['ca_path'],NODE_USE_ENV_PROXY='1')
results=[]
for label,keys,expected in [('public',{'TYPESAFE_API_KEY':'probe-public-key'},'probe-public-key'),('private',{'TYPESAFE_API_KEY_PRIVATE':'probe-private-key'},'probe-private-key'),('both',{'TYPESAFE_API_KEY':'probe-public-key','TYPESAFE_API_KEY_PRIVATE':'probe-private-key'},'probe-private-key')]:
 (D/'calls.jsonl').write_text('');before=len((V/'requests.jsonl').read_text().splitlines())
 payload={'hook_event_name':'Stop','stop_hook_active':False,'session_id':'credential-probe-'+label,'transcript_path':str(V/'belay-transcript.jsonl')}
 start=time.monotonic();p=subprocess.run([str(R/'bin/fm-jev-belay-hook.sh')],input=json.dumps(payload),env=base|keys,text=True,capture_output=True,timeout=26)
 calls=[json.loads(x) for x in (D/'calls.jsonl').read_text().splitlines()];receipts=[json.loads(x) for x in (V/'requests.jsonl').read_text().splitlines()[before:]]
 okay=p.returncode==2 and len(receipts)==1 and receipts[0]['authorization']=='Bearer '+expected and all((x['public'] and not x['private']) if x['command']=='node' else (not x['public'] and not x['private']) for x in calls) and not any(x['key_on_argv'] for x in calls)
 row={'case':label,'pass':okay,'exit':p.returncode,'seconds':round(time.monotonic()-start,3),'observed_commands':calls,'received_key_label':[x['authorization'].replace('Bearer ','') for x in receipts],'stdout':p.stdout,'stderr':p.stderr};results.append(row);print(json.dumps(row),flush=True)
(E/'credential-isolation-live.json').write_text(json.dumps(results,indent=2)+'\n')
print('All credential isolation cases passed:',all(x['pass'] for x in results))
