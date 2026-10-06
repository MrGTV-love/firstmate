import os,pathlib,subprocess,time,signal,json,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M49EFWAFD5KHQ0BH54TSPC8T'); D=R/'.live-validation/pe'
D.mkdir(); logs=[]; jobs=[]
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','NO_MISTAKES_GATE')}
env.update(TMPDIR=str(R/'.live-validation/tmp'),FM_PROCEVENT_CLAIM_ROOT=str(D/'claims'),FM_PROCEVENT_LAUNCH_FLOOR_SECONDS='1')
def run(home,args,confirm='2',allow=(0,),timeout=60):
 e=env|{'FM_HOME':str(home),'FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS':confirm}
 p=subprocess.run(['bash','bin/fm-procevent.sh',*args],env=e,text=True,capture_output=True,timeout=timeout)
 logs.append({'home':home.name,'args':args,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 assert p.returncode in allow,(args,p.returncode,p.stdout,p.stderr)
 return p
def waitfor(fn,limit=30):
 end=time.monotonic()+limit
 while time.monotonic()<end:
  if fn(): return
  time.sleep(.1)
 raise RuntimeError('condition deadline exceeded')
def queues(h):
 p=h/'state/.wake-queue'
 return p.read_text().splitlines() if p.exists() else []
def failures(h):return [x for x in queues(h) if '\tprocevent:episode-src:launch-failed:' in x]
def mkhome(name):
 h=D/name
 subprocess.run(['bash','bin/fm-lab-home.sh','create',str(h)],env=env,check=True,capture_output=True)
 return h
try:
 A=mkhome('a'); B=mkhome('b'); W=mkhome('watch')
 src=D/'source.sh'
 src.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$$" > "$1"\nwhile [ ! -e "$2" ]; do sleep .1; done\nprintf "lab process result\\n"\n')
 src.chmod(0o700)
 args=['register','lavish','episode-src','--',str(src),str(D/'started'),str(D/'release')]
 run(A,args); reg=A/'state/procevent/episode-src.source'; good=reg.read_bytes(); bad=good.split(b'argv:\n')[0]+b'argv:\n';reg.write_bytes(bad)
 # Real overlapping public reconciliations, no execution hooks.
 ee=env|{'FM_HOME':str(A),'FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS':'3'}
 recs=[subprocess.Popen(['bash','bin/fm-procevent.sh','reconcile'],env=ee,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(2)];jobs+=recs
 for p in recs:
  out,err=p.communicate(timeout=60); logs.append({'concurrent_reconcile_pid':p.pid,'rc':p.returncode,'stdout':out,'stderr':err});assert p.returncode==1
 assert len(failures(A))==1
 logs.append({'scenario':'overlapping failure publication','wake_rows':failures(A)})
 # A delayed confirmation must notice B acquiring the same canonical source.
 ee['FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS']='20'
 late=subprocess.Popen(['bash','bin/fm-procevent.sh','reconcile'],env=ee,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);jobs.append(late)
 time.sleep(2)
 run(B,args)
 run(B,['ensure-listening','episode-src'],confirm='10')
 waitfor(lambda:(D/'started').exists())
 out,err=late.communicate(timeout=60);logs.append({'scenario':'foreign-home recovery during confirmation','rc':late.returncode,'stdout':out,'stderr':err,'local_failure_marker_present':(A/'state/procevent/.episode-src.launch-failed').exists()});assert late.returncode==0
 assert not (A/'state/procevent/.episode-src.launch-failed').exists()
 run(B,['retire','episode-src'])
 run(A,['reconcile'],allow=(1,))
 assert len(failures(A))==2
 assert failures(A)[0].split('\t')[3]!=failures(A)[1].split('\t')[3]
 logs.append({'scenario':'fresh failure episode after foreign recovery','wake_rows':failures(A)})
 run(A,['retire','episode-src'])
 # While a long confirmation is pending, the real watcher must cycle and keep
 # exactly one direct reconcile child in flight.
 run(W,args); wr=W/'state/procevent/episode-src.source';wr.write_bytes(wr.read_bytes().split(b'argv:\n')[0]+b'argv:\n')
 we=env|{'FM_HOME':str(W),'FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS':'30','FM_POLL':'1','FM_GUARD_GRACE':'6','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999','FM_HOME_SUMMARY_INTERVAL':'999999'}
 wo=open(E/'reconcile-watcher.stdout.log','w');wer=open(E/'reconcile-watcher.stderr.log','w')
 watcher=subprocess.Popen(['bash','bin/fm-watch.sh'],env=we,stdout=wo,stderr=wer);jobs.append(watcher)
 waitfor(lambda:(W/'state/.last-watcher-beat').exists())
 samples=[]
 for i in range(10):
  time.sleep(1)
  kids=subprocess.run(['pgrep','-P',str(watcher.pid)],text=True,capture_output=True).stdout.split()
  reconciles=[]
  for kid in kids:
   cmd=subprocess.run(['ps','-p',kid,'-o','command='],text=True,capture_output=True).stdout.strip()
   if 'fm-procevent.sh reconcile' in cmd: reconciles.append({'pid':int(kid),'command':cmd})
  samples.append({'sample':i,'age_seconds':round(time.time()-(W/'state/.last-watcher-beat').stat().st_mtime,3),'reconcile_children':reconciles})
  assert watcher.poll() is None
  assert len(reconciles)<=1
 assert any(s['reconcile_children'] for s in samples)
 pids={c['pid'] for s in samples for c in s['reconcile_children']}
 assert len(pids)==1, pids
 assert max(s['age_seconds'] for s in samples)<6
 logs.append({'scenario':'long confirmation does not block main watcher; single flight','samples':samples})
 watcher.terminate();watcher.wait(timeout=15)
 # Reconcile is deliberately detached; retain its ownership until it finishes.
 waitfor(lambda:not any(subprocess.run(['kill','-0',str(pid)],capture_output=True).returncode==0 for pid in pids),limit=60)
 run(W,['sweep-home'])
 print(json.dumps(logs,indent=2))
finally:
 for p in jobs:
  if p.poll() is None:
   p.terminate()
   try:p.wait(timeout=15)
   except subprocess.TimeoutExpired:p.kill();p.wait()
 for h in (D/'a',D/'b',D/'watch'):
  if h.exists():
   try:run(h,['sweep-home'])
   except Exception as exc:logs.append({'cleanup_error':str(exc)})
 (E/'procevent-live-transcript.json').write_text(json.dumps(logs,indent=2)+'\n')
 shutil.rmtree(D)
