import os,pathlib,subprocess,time,signal,shutil,json
R=pathlib.Path.cwd();L=R/'.live-validation/guard-home';E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M49EFWAFD5KHQ0BH54TSPC8T');log=[];w=None;s=None
e={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','NO_MISTAKES_GATE')}
e.update(FM_HOME=str(L),TMPDIR=str(R/'.live-validation/tmp'),FM_POLL='1',FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999')
try:
 subprocess.run(['bash','bin/fm-lab-home.sh','create',str(L)],env=e,check=True,capture_output=True)
 w=subprocess.Popen(['bash','bin/fm-watch.sh'],env=e,stdout=open(E/'guard-watcher.stdout.log','w'),stderr=open(E/'guard-watcher.stderr.log','w'))
 end=time.monotonic()+30
 while not (L/'state/.watch.lock/pid').exists() and time.monotonic()<end:time.sleep(.1)
 assert (L/'state/.watch.lock/pid').read_text().strip()==str(w.pid)
 s=subprocess.Popen(['sleep','120'],env=e)
 exact=f'if ps -p {w.pid} -o command= | grep -q fm-watch.sh; then kill -TERM {w.pid}; fi'
 cases=[('read-only diagnostic and own PID stop',exact,0),('broad watcher pattern kill','pkill -f fm-watch.sh',2),('foreign PID with watcher diagnostic',f'if pgrep -fl fm-watch.sh; then kill {s.pid}; fi',2),('multiple PID kill with watcher diagnostic',f'if pgrep -fl fm-watch.sh; then kill {w.pid} {s.pid}; fi',2),('opaque interpreter companion',f"""if python3 -c 'print("fm-watch.sh")'; then kill {w.pid}; fi""",2),('redirection companion',f'if pgrep -fl fm-watch.sh > {L}/capture; then kill {w.pid}; fi',2),('substitution target','if pgrep -fl fm-watch.sh; then kill "$(pgrep -f fm-watch.sh)"; fi',2)]
 for name,cmd,expected in cases:
  p=subprocess.run(['bash','bin/fm-arm-pretool-check.sh','--claude','--command',cmd],env=e,text=True,capture_output=True,timeout=20)
  log.append({'scenario':name,'submitted_command':cmd,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
  assert p.returncode==expected,(name,p.returncode,p.stdout,p.stderr)
  assert w.poll() is None and s.poll() is None
 # Only the positively permitted exact PID command is actually executed.
 p=subprocess.run(['bash','-c',exact],env=e,text=True,capture_output=True,timeout=20)
 w.wait(timeout=15)
 assert p.returncode==0 and s.poll() is None
 log.append({'scenario':'permitted command stops only the registered watcher','command_exit':p.returncode,'watcher_exit':w.returncode,'unrelated_process_alive':s.poll() is None,'watcher_lock_removed':not (L/'state/.watch.lock').exists()})
 assert not (L/'state/.watch.lock').exists()
 print(json.dumps(log,indent=2))
finally:
 for p in (w,s):
  if p is not None and p.poll() is None:
   p.terminate()
   try:p.wait(timeout=15)
   except subprocess.TimeoutExpired:p.kill();p.wait()
 (E/'command-guard-live-transcript.json').write_text(json.dumps(log,indent=2)+'\n')
 shutil.rmtree(L,ignore_errors=True)
