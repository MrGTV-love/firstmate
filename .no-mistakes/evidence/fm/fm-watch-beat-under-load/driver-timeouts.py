import os,pathlib,subprocess,time,json,shutil
R=pathlib.Path.cwd();D=R/'.live-validation/timeouts';E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M49EFWAFD5KHQ0BH54TSPC8T');D.mkdir();logs=[];jobs=[]
e={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','NO_MISTAKES_GATE')}
e['TMPDIR']=str(R/'.live-validation/tmp')
try:
 for fallback in ('0','1'):
  for runtime in ('1','4'):
   L=D/f'fallback-{fallback}-runtime-{runtime}'
   subprocess.run(['bash','bin/fm-lab-home.sh','create',str(L)],env=e,check=True,capture_output=True)
   ee=e|{'FM_HOME':str(L),'FM_CHECK_TIMEOUT':'02','FM_CHECK_FORCE_FALLBACK':fallback,'FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999','FM_POLL':'1'}
   check=L/'state/timed.check.sh';check.write_text(f'#!/usr/bin/env bash\ntouch "$FM_HOME/state/started"\nsleep {runtime}\ntouch "$FM_HOME/state/finished"\nprintf "timed-check-completed\\n"\n');check.chmod(0o700)
   reg=subprocess.run(['bash','bin/fm-check-register.sh','timed'],env=ee,capture_output=True,text=True,check=True)
   out=open(L/'stdout','w');err=open(L/'stderr','w')
   p=subprocess.Popen(['bash','bin/fm-watch.sh'],env=ee,stdout=out,stderr=err);jobs.append(p)
   start=time.monotonic();deadline=start+50
   while not (L/'state/.last-check').exists() and p.poll() is None and time.monotonic()<deadline:time.sleep(.1)
   assert (L/'state/.last-check').exists(),'sweep not completed'
   assert (L/'state/started').exists()
   if p.poll() is None:p.terminate()
   p.wait(timeout=15);out.close();err.close()
   queue=(L/'state/.wake-queue').read_text() if (L/'state/.wake-queue').exists() else ''
   finished=(L/'state/finished').exists()
   assert finished==(runtime=='1')
   assert ('timed-check-completed' in queue)==(runtime=='1')
   logs.append({'fallback':fallback,'configured_timeout':'02','runtime_seconds':runtime,'sweep_elapsed_seconds':round(time.monotonic()-start,3),'finished':finished,'wake_queue':queue,'stdout':(L/'stdout').read_text(),'stderr':(L/'stderr').read_text()})
 print(json.dumps(logs,indent=2))
finally:
 for p in jobs:
  if p.poll() is None:
   p.terminate()
   try:p.wait(timeout=15)
   except subprocess.TimeoutExpired:p.kill();p.wait()
 (E/'check-timeout-live-transcript.json').write_text(json.dumps(logs,indent=2)+'\n')
 shutil.rmtree(D)
