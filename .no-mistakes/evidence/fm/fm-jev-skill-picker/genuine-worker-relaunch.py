import os,pathlib,subprocess,shutil,json,time,hashlib
ROOT=pathlib.Path('/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49BAACZ1ZHY95W7KK1JRVBK'); E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M49BAACZ1ZHY95W7KK1JRVBK'); B=ROOT/'.live-skill-validation/worker-lab'; H=B/'home'; C=B/'code'; W=B/'wrappers'; ID='genuine-worker'; D=H/'data'/ID; S=H/'state'; WT=B/'worktree'
iso=json.loads((E/'genuine-worker-isolation.json').read_text())
env={k:v for k,v in os.environ.items() if not(k.startswith('FM_') and k.endswith('_OVERRIDE')) and k not in ('TMUX','TMUX_PANE','FM_GATE_REFUSE_BYPASS','TYPESAFE_API_KEY','TYPESAFE_API_KEY_PRIVATE','FM_BACKEND','HERDR_SESSION')}; env.update(FM_HOME=str(H),PATH=str(W)+':'+env['PATH'],TMUX_TMPDIR=iso['tmux_tmpdir'],LIVE_WIRE=str(E/'genuine-worker-wire.jsonl'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args,name,check=True,timeout=180):
 p=subprocess.run([str(a) for a in args],env=env,text=True,capture_output=True,timeout=timeout,cwd=B); (E/('genuine-worker-'+name+'.txt')).write_text(p.stdout+p.stderr+f'\nexit={p.returncode}\n')
 if check and p.returncode: raise RuntimeError(f'{name}: {p.stdout}{p.stderr}')
 return p
def wait_report(n,baseline=0):
 deadline=time.monotonic()+900
 while time.monotonic()<deadline:
  status=S/(ID+'.status'); txt=status.read_text() if status.exists() else ''
  if txt.count('done [at=')>baseline and (S/(ID+'.turn-ended')).exists() and (WT/f'result-{n}.json').exists() and (D/('report.md' if n==1 else 'report-2.md')).exists(): return
  if 'blocked [at=' in txt or 'failed [at=' in txt: raise RuntimeError('worker reported unresolved block/failure: '+txt)
  time.sleep(2)
 raise RuntimeError(f'worker {n} report/completion not observed in 900 seconds')
def copy_phase(n):
 for src,dest in [(D/('report.md' if n==1 else 'report-2.md'),f'genuine-worker-report-{n}.md'),(WT/f'result-{n}.json',f'genuine-worker-result-{n}.json'),(S/(ID+'.status'),f'genuine-worker-status-{n}.txt'),(D/'launch-brief.md',f'genuine-worker-launch-{n}.md'),(D/'brief.md',f'genuine-worker-source-{n}.md'),(S/(ID+'.meta'),f'genuine-worker-meta-{n}.txt')]: shutil.copyfile(src,E/dest)
 run([W/'tmux','capture-pane','-p','-S','-1500','-t','firstmate:fm-genuine-worker'],f'pane-{n}')
 return run([W/'tmux','display-message','-p','-t','firstmate:fm-genuine-worker','#{window_id} #{pane_id} #{pane_current_path}'],f'endpoint-{n}').stdout.strip()
verdict={'scenario':'actual production spawn + control relaunch, real omp, genuine automatic picker','acquisition':iso['acquisition'],'model':iso['model'],'source':'b3b2ffe0ce1300038eaee445c8b0347ed00f0f18'}
try:
 wait_report(1); endpoint1=copy_phase(1)
 initial_wire=(E/'genuine-worker-wire.jsonl').read_text().splitlines(); (E/'genuine-worker-wire-1.jsonl').write_text('\n'.join(initial_wire)+'\n')
 baseline=(S/(ID+'.status')).read_text().count('done [at=')
 note=B/'relaunch-note.txt'
 note.write_text('The first report and result-1.json completed the original exact monetary task. Preserve SOURCE_INTENT_MONETARY_4_10_21 and every original Task/Captain intent/Firstmate spec requirement. This relaunch requests a fresh second independent receipt: read the complete fixture index, mandatory input-safety body, freshly appended automatic advice and relevant suggested bodies using ordinary read tools again. Agent discretion and all mandatory triggers remain authoritative. Re-read records.json and independently compute the same monetary fields; write result-2.json in the same worktree and a standalone second report at '+str(D/'report-2.md')+'. Do not overwrite result-1.json or the prior report. Record exact new advice source/model/fits/uncertainty, full seven-item index, body-read paths/instructions and any rejected/extra skills. Complete the mandatory captain-hold-lifecycle gate for the second report, append a second done status and stop. No tests, lint, formatters, pipeline, network, operator/shared state, lifecycle or worker spawning.\n')
 shutil.copyfile(note,E/'genuine-worker-relaunch-note.txt')
 run([C/'bin/fm-control.sh',ID,'relaunch','--note-file',note],'relaunch',timeout=240)
 shutil.copyfile(D/'launch-brief.md',E/'genuine-worker-launch-2.md'); shutil.copyfile(D/'brief.md',E/'genuine-worker-source-2.md')
 wait_report(2,baseline); endpoint2=copy_phase(2)
 wire=[json.loads(x) for x in (E/'genuine-worker-wire.jsonl').read_text().splitlines()]; (E/'genuine-worker-wire-2.jsonl').write_text('\n'.join(json.dumps(x) for x in wire[len(initial_wire):])+'\n')
 def task(text): return text.split('# Task\n',1)[1].split('\n# ',1)[0]
 s1=(E/'genuine-worker-source-1.md').read_text(); s2=(E/'genuine-worker-source-2.md').read_text()
 verdict.update(endpoint_1=endpoint1,endpoint_2=endpoint2,same_endpoint_worktree=endpoint1==endpoint2,original_task_exact=task(s1)==task(s2),source_only_progress_appended=s2.startswith(s1) and s2[len(s1):].lstrip().startswith('## Progress note ('),fresh_calls_initial=len(initial_wire),fresh_calls_relaunch=len(wire)-len(initial_wire),wire_model_all_jev=all(r['request']['model']=='jev-1.13.0' and r['response']['model']=='jev-1.13.0' for r in wire),same_minimal_picker_task=all(r['request']['state']['task']==wire[0]['request']['state']['task'] for r in wire),no_exported_credential=all(not r['credential_exported'] for r in wire))
 results=[json.loads((E/f'genuine-worker-result-{n}.json').read_text()) for n in (1,2)]
 verdict['observed_results']=results
except BaseException as ex:
 verdict['error']=str(ex)
finally:
 cleanup=[]
 for name,args in [('exit',[C/'bin/fm-control.sh',ID,'exit']),('kill-private-server',[W/'tmux','kill-server']),('confirm-private-stopped',[W/'tmux','list-sessions']),('helper-teardown',[C/'bin/fm-lab-home.sh','teardown',H])]:
  try:
   p=run(args,name,check=False,timeout=90); cleanup.append({'operation':name,'exit':p.returncode,'output':p.stdout+p.stderr})
  except BaseException as ex: cleanup.append({'operation':name,'error':str(ex)})
 verdict['cleanup']=cleanup
 receipts=[]; readlogs=[]; sessions=[]
 for p in sorted((B/'sessions').glob('*.jsonl')):
  records=[json.loads(x) for x in p.read_text().splitlines()]
  session=next((r for r in records if r.get('type')=='session'),{}); sessions.append(session)
  for r in records:
   m=r.get('message',{}); role=m.get('role')
   if r.get('type')=='message' and role in ('user','assistant','toolResult'):
    content=m.get('content',[])
    if role=='assistant': content=[x for x in content if x.get('type') in ('toolCall','text')]
    if content: receipts.append({'session':session.get('id'),'timestamp':r.get('timestamp'),'role':role,'toolCallId':m.get('toolCallId'),'toolName':m.get('toolName'),'isError':m.get('isError'),'content':content})
   elif r.get('type')=='custom' and str(r.get('customType','')).startswith('tool_execution'): receipts.append({'session':session.get('id'),'timestamp':r.get('timestamp'),'type':r['customType'],'data':r.get('data')})
  for log in p.with_suffix('').glob('*.eval.log'):
   dest=E/('genuine-worker-'+p.stem+'-'+log.name); shutil.copyfile(log,dest); readlogs.append(str(dest))
 (E/'genuine-worker-session-receipts.jsonl').write_text('\n'.join(json.dumps(r) for r in receipts)+'\n')
 (E/'genuine-worker-sessions.json').write_text(json.dumps(sessions,indent=2)+'\n')
 verdict['session_count']=len(sessions); verdict['eval_read_logs']=readlogs
 for p in S.glob(ID+'.*'):
  if p.is_file() and p.suffix in ('.captain-complete','.turn-ended'): shutil.copyfile(p,E/('genuine-worker-final-'+p.name))
 (E/'genuine-worker-verdict.json').write_text(json.dumps(verdict,indent=2)+'\n')
 for root,dirs,files in os.walk(B):
  os.chmod(root,0o700)
  for f in files:
   p=pathlib.Path(root)/f
   if not p.is_symlink(): os.chmod(p,0o600)
 shutil.rmtree(B)
 for p in pathlib.Path('/tmp').glob('fm-genuine-worker*'):
  if p.is_dir() and p.owner()==pathlib.Path.home().name: shutil.rmtree(p)
 print(json.dumps(verdict),flush=True)
