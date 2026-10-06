import os, pathlib, subprocess, time, signal, json, shutil
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M49EFWAFD5KHQ0BH54TSPC8T')
LAB=ROOT/'.live-validation/watch-home'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','NO_MISTAKES_GATE')}
env.update(FM_HOME=str(LAB),TMPDIR=str(ROOT/'.live-validation/tmp'),FM_POLL='1',FM_GUARD_GRACE='6',FM_CHECK_TIMEOUT='60',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_HOME_SUMMARY_INTERVAL='999999')
def run(args,timeout=20):
 p=subprocess.run(args,env=env,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
 transcript.append({'command':args,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 return p
transcript=[]; w=None
try:
 assert run(['bash','bin/fm-lab-home.sh','create',str(LAB)]).returncode==0
 check=LAB/'state/slow.check.sh'
 check.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$$" > "$FM_HOME/state/check-started"\nwhile [ ! -e "$FM_HOME/state/check-release" ]; do sleep 0.1; done\ntouch "$FM_HOME/state/check-finished"\nprintf "slow-check-completed\\n"\n')
 check.chmod(0o700)
 assert run(['bash','bin/fm-check-register.sh','slow']).returncode==0
 out=open(E/'watcher-product.stdout.log','w'); err=open(E/'watcher-product.stderr.log','w')
 w=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,cwd=ROOT,stdout=out,stderr=err)
 deadline=time.monotonic()+25
 while not (LAB/'state/check-started').exists() and time.monotonic()<deadline:
  if w.poll() is not None: raise RuntimeError('watcher exited before check')
  time.sleep(.1)
 assert (LAB/'state/check-started').exists(),'slow check never started'
 beat=LAB/'state/.last-watcher-beat'
 def health():
  return run(['bash','-c','. "$1"; fm_watcher_healthy "$2" "$3" 6 "$4"; rc=$?; printf "strict watcher health rc=%s\\n" "$rc"; exit "$rc"','_',str(ROOT/'bin/fm-wake-lib.sh'),str(LAB/'state'),str(ROOT/'bin/fm-watch.sh'),str(LAB)])
 samples=[]
 for i in range(9):
  time.sleep(1); samples.append({'elapsed':i+1,'age_seconds':round(time.time()-beat.stat().st_mtime,3),'watcher_alive':w.poll() is None,'check_finished':(LAB/'state/check-finished').exists()})
 assert all(x['watcher_alive'] and not x['check_finished'] for x in samples)
 assert samples[-1]['age_seconds']<6
 assert health().returncode==0
 transcript.append({'scenario':'bounded slow check remains healthy beyond grace','watcher_pid':w.pid,'check_pid':(LAB/'state/check-started').read_text().strip(),'samples':samples})
 os.kill(w.pid,signal.SIGSTOP)
 frozen=beat.stat().st_mtime
 time.sleep(8)
 age=time.time()-beat.stat().st_mtime
 assert beat.stat().st_mtime==frozen and age>=6
 assert health().returncode!=0
 transcript.append({'scenario':'stopped main poll cannot publish liveness','beacon_age_seconds':round(age,3),'mtime_unchanged':beat.stat().st_mtime==frozen,'check_still_unfinished':not (LAB/'state/check-finished').exists()})
 os.kill(w.pid,signal.SIGCONT); (LAB/'state/check-release').touch()
 deadline=time.monotonic()+20
 while w.poll() is None and time.monotonic()<deadline: time.sleep(.1)
 assert w.poll()==0, f'watcher did not deliver check result: {w.poll()}'
 queue=(LAB/'state/.wake-queue').read_text()
 assert 'slow-check-completed' in queue
 transcript.append({'scenario':'resumed poll delivers durable check wake','watcher_exit':w.returncode,'wake_queue':queue})
 print(json.dumps(transcript,indent=2))
finally:
 if w is not None and w.poll() is None:
  os.kill(w.pid,signal.SIGCONT); w.terminate()
  try: w.wait(timeout=12)
  except subprocess.TimeoutExpired: w.kill();w.wait()
 (E/'watcher-live-transcript.json').write_text(json.dumps(transcript,indent=2)+'\n')
 shutil.rmtree(LAB,ignore_errors=True)
