import os, pathlib, subprocess, json, time, threading, re, html, shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.wake-live'; HOME=LAB/'home'; AGENT=LAB/'agent'
EVIDENCE=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4E0VV43ZJ2E8B08ZQ717KFV'); EVIDENCE.mkdir(parents=True,exist_ok=True)
BASELINE=os.environ.get('TEST_BASELINE')=='1'
if BASELINE:
 EVIDENCE=EVIDENCE/'baseline'; EVIDENCE.mkdir(exist_ok=True)
EXTENSION=(LAB/'baseline' if BASELINE else ROOT)/'.omp/extensions/fm-primary-omp-watch.ts'
AGENT.mkdir(exist_ok=True); (HOME/'tmux').mkdir(exist_ok=True)
requests=[]; events=[]; lock=threading.Lock(); advised=set()

def texts(m):
 c=m.get('content'); return ' '.join(p.get('text','') for p in c if isinstance(p,dict)) if isinstance(c,list) else c if isinstance(c,str) else ''
def record(event, **data):
 item=dict(at=time.time(),event=event,**data); events.append(item); print(json.dumps(item),flush=True)
class Model(BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_POST(self):
  global advised
  req=json.loads(self.rfile.read(int(self.headers.get('content-length',0)))); msgs=req.get('messages',[]); tools=[t.get('function',{}).get('name') for t in req.get('tools',[])]; last=msgs[-1] if msgs else {}; alltext=' '.join(texts(m) for m in msgs)
  user=next((texts(m) for m in reversed(msgs) if m.get('role')=='user'),'')
  tooltext=texts(last); call=None; delay=0
  if 'advise' in tools:
   markers=[m for m in ['LIVE-ADVISE-1','LIVE-ADVISE-2'] if m in alltext and m not in advised]
   if markers:
    advised.add(markers[-1]); call=('advise',{'note':'LIVE-ADVISOR-TAIL '+markers[-1]+' verify before finishing.','severity':'concern'})
  elif 'LIVE-INIT' in user and 'FIRSTMATE WATCHER WAKE' not in user:
   if last.get('role')=='user': call=('bash',{'command':'bin/fm-lock.sh'})
   elif last.get('role')=='tool' and 'watcher:' not in tooltext: call=('fm_watch_arm_omp',{})
  elif 'FIRSTMATE WATCHER WAKE' in user:
   if last.get('role')=='user': call=('bash',{'command':'bin/fm-wake-drain.sh'})
   elif last.get('role')=='tool':
    ack=re.search(r'WAKE_ACK_REQUIRED: after handling completes run (bin/fm-wake-drain.sh --ack-through \d+ --recovery-generation \S+)',tooltext)
    if ack: call=('bash',{'command':ack.group(1)})
  elif 'LIVE-BUSY' in user and last.get('role')=='user': delay=60
  with lock:
   requests.append({'at':time.time(),'user':user,'last_role':last.get('role'),'last_name':last.get('name'),'tool_output':tooltext if last.get('role')=='tool' else '', 'call':call, 'advisor':'advise' in tools})
  self.send_response(200); self.send_header('content-type','text/event-stream'); self.end_headers()
  if call:
   delta={'role':'assistant','tool_calls':[{'index':0,'id':'call_'+str(len(requests)), 'type':'function','function':{'name':call[0],'arguments':json.dumps(call[1])}}]}; finish='tool_calls'
  else: delta={'role':'assistant','content':'ack'}; finish='stop'
  for d in [delta,{}]:
   body={'id':'lab','object':'chat.completion.chunk','created':int(time.time()),'model':'m1','choices':[{'index':0,'delta':d,'finish_reason':None if d else finish}]}
   self.wfile.write(b'data: '+json.dumps(body).encode()+b'\n\n')
   self.wfile.flush()
   if d and delay:
    (HOME/'state/busy-running').touch(); record('stream_started',seconds=delay)
    time.sleep(delay); (HOME/'state/busy-done').touch(); record('stream_finished')
  self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
server=ThreadingHTTPServer(('127.0.0.1',0),Model); threading.Thread(target=server.serve_forever,daemon=True).start()
(AGENT/'config.yml').write_text('setupVersion: 2\nmodelRoles:\n  default: lab/m1\n  tiny: lab/m1\n  advisor: lab/m1\n  vision: lab/m1\nadvisor:\n  enabled: true\n')
(AGENT/'models.yml').write_text(f'providers:\n  lab:\n    baseUrl: http://127.0.0.1:{server.server_port}/v1\n    apiKey: lab-key\n    api: openai-completions\n    models:\n      - id: m1\n        contextWindow: 200000\n        maxTokens: 4096\n')
env=dict(os.environ)
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_WAKE_QUEUE','FM_WAKE_QUEUE_LOCK','TMUX','TMUX_PANE','HERDR_SESSION','HERDR_ENV','HERDR_PANE_ID']:
 env.pop(k,None)
env['TMUX_TMPDIR']='.wake-live/home/tmux'
env['PATH']=str(LAB/'bin')+os.pathsep+env['PATH']
def tmux(*args,check=True):
 result=subprocess.run(['tmux','-S','.wake-live/socket',*args],env=env,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if check and result.returncode: raise RuntimeError(result.stderr)
 return result.stdout

def screen(): return tmux('capture-pane','-p','-t','primary','-S','-100')
def send(s): tmux('send-keys','-t','primary','-l',s); time.sleep(.4); tmux('send-keys','-t','primary','Enter')
def wait(label,fn,seconds=60):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if fn(): record('observed',label=label); return
  time.sleep(.5)
 raise RuntimeError('timeout: '+label+'\n'+screen())
def snapshot(label):
 s=screen(); (EVIDENCE/(label+'.txt')).write_text(s)
 (EVIDENCE/(label+'.html')).write_text('<!doctype html><meta charset="utf-8"><title>'+label+'</title><body style="background:#151515;color:#ddd"><pre style="font:14px monospace;white-space:pre-wrap">'+html.escape(s)+'</pre></body>')
 record('capture',label=label)
def queue():
 p=HOME/'state/.wake-queue'; return p.read_text() if p.exists() else ''
def trigger(name):
 (HOME/'state'/f'{name}.meta').write_text('')
 (HOME/'state'/f'{name}.status').write_text('done: isolated wake '+name+'\n')
 record('status_written',name=name)
def wake_seen(name): return any(name+'.status' in r['user'] and 'FIRSTMATE WATCHER WAKE' in r['user'] and not r['advisor'] for r in requests)
try:
 command=f'env PATH={env["PATH"]} FM_HOME={HOME} PI_CODING_AGENT_DIR={AGENT} FM_ARM_CONFIRM_TIMEOUT=90 FM_OMP_ARM_READY_TIMEOUT_MS=100000 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=10000 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=3600 omp --model lab/m1 --no-extensions -e {EXTENSION} --no-skills --no-rules --no-lsp --no-title --tools bash --auto-approve'
 tmux('new-session','-d','-s','primary','-x','160','-y','45','-c',str(ROOT),command)
 wait('omp ready',lambda:' m1 ' in screen(),90)
 send('LIVE-INIT reply ack and arrange advisor note')
 wait('real watcher armed and beating',lambda:(HOME/'state/.last-watcher-beat').exists(),180)
 wait('startup check fully acknowledged before advisor stimulus',lambda:not queue().strip() and any(r['call'] and r['call'][0]=='bash' and '--ack-through' in r['call'][1].get('command','') for r in requests),180)
 time.sleep(10)
 send('LIVE-ADVISE-1 reply ack')
 wait('advisor note posted after settled startup',lambda:'LIVE-ADVISOR-TAIL LIVE-ADVISE-1' in screen(),90)
 time.sleep(5); snapshot('01-idle-advisor-before')
 trigger('idleempty')
 if BASELINE:
  wait('baseline own wake durably queued',lambda:'idleempty.status' in queue(),90)
  time.sleep(45)
  assert not wake_seen('idleempty'), 'baseline did not reproduce stall'
  assert 'idleempty.status' in queue(), 'baseline wake was unexpectedly drained'
  snapshot('baseline-idle-stalled')
  record('baseline_failure_reproduced',unread_wake=True,model_received_wake=False)
  send('LIVE-RELEASE reply ack')
  wait('manual prompt releases baseline wake',lambda:wake_seen('idleempty'),90)
  snapshot('baseline-manual-prompt-releases')
  raise SystemExit(0)
 wait('empty-composer idle wake reached model',lambda:wake_seen('idleempty'),180)
 wait('idleempty own queue acknowledged',lambda:not queue().strip(),120)
 snapshot('02-idle-empty-drained')
 time.sleep(5)
 send('LIVE-ADVISE-2 reply ack')
 wait('fresh advisor tail before operator draft',lambda:'LIVE-ADVISOR-TAIL LIVE-ADVISE-2' in screen(),90)
 time.sleep(5)
 tmux('send-keys','-t','primary','-l','operator draft kept'); time.sleep(2)
 snapshot('03-operator-draft-before')
 trigger('idledraft')
 wait('draft-composer idle wake reached model',lambda:wake_seen('idledraft'),120)
 wait('idledraft own queue acknowledged',lambda:not queue().strip(),120)
 time.sleep(2)
 assert 'operator draft kept' in screen(), 'draft disappeared'
 assert not any('operator draft kept' in r['user'] for r in requests), 'draft submitted'
 snapshot('04-idle-draft-preserved')
 record('scenario_pass',name='idle wake preserves unsent operator draft')
 tmux('send-keys','-t','primary','C-u'); time.sleep(1)
 send('LIVE-BUSY stream slowly')
 wait('real omp streaming turn running',lambda:(HOME/'state/busy-running').exists() and not (HOME/'state/busy-done').exists(),60)
 trigger('busywake')
 wait('busy own wake durable while stream remains open',lambda:'busywake.status' in queue() and not wake_seen('busywake') and not (HOME/'state/busy-done').exists(),50)
 time.sleep(20)
 assert not (HOME/'state/busy-done').exists() and not wake_seen('busywake'), 'busy wake did not stay queued'
 snapshot('05-busy-followup-queued')
 wait('busy followup reached model',lambda:wake_seen('busywake'),180)
 wait('busy own queue acknowledged',lambda:not queue().strip(),120)
 snapshot('06-busy-followup-drained')
 record('scenario_pass',name='wake during streaming queues then drains')
 for name in ['repeatone','repeattwo']:
  time.sleep(3); trigger(name); wait(name+' received',lambda n=name:wake_seen(n),180); wait(name+' acknowledged',lambda:not queue().strip(),120)
 snapshot('07-repeated-idle-wakes')
 record('scenario_pass',name='successor watcher drains consecutive idle wakes')
except Exception as e:
 record('failure',error=str(e)); snapshot('failure')
 raise
finally:
 (EVIDENCE/'live-model-requests.json').write_text(json.dumps(requests,indent=2))
 for fname in ['.wake-queue','.watch-cycle-exits.log','.watch-deliveries.log','.watcher-down','.lock']:
  p=HOME/'state'/fname
  if p.is_file(): (EVIDENCE/('final-'+fname.lstrip('.'))).write_text(p.read_text())
 tmux('kill-server',check=False)
 subprocess.run(['bin/fm-watch-arm.sh','--stop'],env={**env,'FM_HOME':str(HOME)},cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 server.shutdown(); record('teardown',private_tmux_stopped=True)
 (EVIDENCE/'live-events.json').write_text(json.dumps(events,indent=2))
