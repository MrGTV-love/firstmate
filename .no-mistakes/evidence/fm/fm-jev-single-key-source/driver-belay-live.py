import os,pathlib,json,subprocess,time,shutil
ROOT=pathlib.Path.cwd();V=ROOT/'.live-validation';E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4C9C1P6TN97HD7NAANKCK9T')
service=json.loads((V/'service.json').read_text())
base=os.environ.copy()
for k in ['TYPESAFE_API_KEY','TYPESAFE_API_KEY_PRIVATE','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_GATE_REFUSE_BYPASS']:base.pop(k,None)
base.update(HTTPS_PROXY=service['proxy_url'],https_proxy=service['proxy_url'],NODE_USE_ENV_PROXY='1',NODE_EXTRA_CA_CERTS=service['ca_path'],CURL_CA_BUNDLE=service['ca_path'],TMPDIR=str(V),HOME=str(V/'belay-user'))
primary=V/'belay-primary';home=V/'stop-fixture/home';state=home/'state';id='live-stop';turn=state/(id+'.turn-ended')
(home/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={primary}\n')
settings=json.loads((V/'generated-settings.json').read_text())
transcript=V/'belay-transcript.jsonl';initial=transcript.read_text();logs=[];results=[]
def requests():
 return [json.loads(x) for x in (V/'requests.jsonl').read_text().splitlines() if json.loads(x).get('authorization')=='Bearer belay-fixture-primary']
def classify():
 p=subprocess.run(['bash','-c','. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux fixture claude live-stop "$2"','_',str(ROOT),str(state)],env=base,text=True,capture_output=True)
 return p.stdout.strip()
def hook(event,payload,envextra={}):
 command=settings['hooks'][event][0]['hooks'][0]['command']
 start=time.monotonic();p=subprocess.run(['sh','-c',command],input=json.dumps(payload),env=base|envextra,text=True,capture_output=True,timeout=26)
 return p,round(time.monotonic()-start,3)
def drive(name,mode='reject',expected_rc=0,expected_class='idle claude-hook',expected_requests=None,payloadextra={},envextra={},before=None):
 (V/'mode.json').write_text(json.dumps({'mode':mode}));transcript.write_text(initial)
 if before: before()
 hook('UserPromptSubmit',{})
 turn.unlink(missing_ok=True)
 count=len(requests())
 payload={'hook_event_name':'Stop','stop_hook_active':False,'session_id':'live-'+name,'transcript_path':str(transcript),'cwd':str(V)}|payloadextra
 p,elapsed=hook('Stop',payload,envextra)
 got=classify();new=requests()[count:];marker=turn.exists()
 passed=p.returncode==expected_rc and got==expected_class and marker==(expected_rc!=2) and elapsed<25 and (expected_requests is None or len(new)==expected_requests)
 row={'name':name,'pass':passed,'status':p.returncode,'elapsed_seconds':elapsed,'classification':got,'turn_ended':marker,'network_requests':len(new),'stdout':p.stdout,'stderr':p.stderr,'receipts':new}
 results.append(row);print(json.dumps({k:v for k,v in row.items() if k!='receipts'}),flush=True)
 return row
try:
 drive('edited-unverified-stop-rejected',expected_rc=2,expected_class='busy claude-hook',expected_requests=1)
 # No new UserPromptSubmit: same resumed turn accepts stop_hook_active and closes it.
 p,t=hook('Stop',{'hook_event_name':'Stop','stop_hook_active':True,'session_id':'live-edited-unverified-stop-rejected','transcript_path':str(transcript)})
 row={'name':'same-turn-resumed-stop-accepted','pass':p.returncode==0 and classify()=='idle claude-hook' and turn.exists(),'status':p.returncode,'elapsed_seconds':t,'classification':classify(),'turn_ended':turn.exists(),'stdout':p.stdout,'stderr':p.stderr};results.append(row);print(json.dumps(row),flush=True)
 drive('service-nonblocking-http-failure-completes',mode='error',expected_requests=1)
 drive('node-nonblocking-startup-failure-completes',expected_requests=0,envextra={'NODE_OPTIONS':'--firstmate-invalid-option'})
 # Each native outgoing field is actively forbidden, including a failed check after mutation.
 policy=home/'config/dispatch-never-send'
 for field in ['task','final_message','checks_run']:
  def setup(field=field):
   policy.write_text('classified phrase\n');r=[json.loads(x) for x in initial.splitlines()]
   if field=='task':r[0]['message']['content']='Implement CLASSIFIED \n\t PHRASE code.'
   elif field=='final_message':r[-1]['message']['content'][0]['text']='Done with CLASSIFIED \n\t PHRASE.'
   else:
    r.insert(-1,{'type':'assistant','message':{'content':[{'type':'tool_use','id':'check-1','name':'Bash','input':{'command':'npm test # CLASSIFIED \n\t PHRASE'}}]}})
    r.insert(-1,{'type':'user','toolUseResult':{'stdout':'Tests: 1 failed, 0 passed','stderr':''},'message':{'content':[{'type':'tool_result','tool_use_id':'check-1','is_error':True,'content':'failed'}]}})
   transcript.write_text(''.join(json.dumps(x)+'\n' for x in r))
  drive('withhold-'+field,expected_requests=0,before=setup)
 policy.write_text('# dispatch-never-send malformed directive\n')
 drive('invalid-policy-withholds',expected_requests=0)
 policy.unlink()
 # Large real literal policy forces actual jq/loop work rather than a mock hung checker.
 policy.write_text('unmatched ordinary phrase\n'*300000)
 drive('large-policy-work-is-bounded-and-withheld',expected_requests=0)
 policy.unlink()
 # Unresponsive real loopback HTTPS server under ambient upstream 60-second budget.
 drive('unresponsive-service-internal-deadline-completes',mode='stall',expected_requests=1,envextra={'JEV_BELAY_TIMEOUT_MS':'60000'})
 (V/'mode.json').write_text('{"mode":"reject"}')
 vendor=primary/'data/vendor/jev-belay/belay.mjs';original=vendor.read_bytes()
 vendor.write_bytes(original+b'\n// tampered\n')
 drive('tampered-vendor-refused',expected_requests=0)
 vendor.write_bytes(original)
 vendor.rename(vendor.with_suffix('.off'))
 drive('missing-vendor-fails-open',expected_requests=0)
 vendor.with_suffix('.off').rename(vendor)
 (primary/'.env').rename(primary/'.env.off')
 drive('missing-key-fails-open',expected_requests=0)
 (primary/'.env.off').rename(primary/'.env')
finally:
 (V/'mode.json').write_text('{"mode":"reject"}')
 transcript.write_text(initial)
 (E/'belay-live.json').write_text(json.dumps(results,indent=2)+'\n')
 (E/'belay-live-transcript.log').write_text('\n'.join(json.dumps({k:v for k,v in r.items() if k!='receipts'},indent=2) for r in results)+'\n')
print('All live checks passed:',all(x['pass'] for x in results),flush=True)
