#!/usr/bin/env python3
import os, sys, json, pathlib as pl, subprocess as sp, shutil, time, shlex
ROOT=pl.Path('/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M452J6VP26D8ZRCRHPMA51MM')
EVID=pl.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M452J6VP26D8ZRCRHPMA51MM')
LAB=ROOT/'.live-teardown-lab'
BASE='4dc0056a08e9c178dcf5561da0deb8cddb0debae'
run_suffix='landing-retry' if len(sys.argv)>1 else 'transcript'
log=(EVID/('live-teardown-'+run_suffix+'.log')).open('w')
results=[]; processes=[]; cases=[]
def emit(s):
 print(s,flush=True); log.write(s+'\n'); log.flush()
def run(cmd,cwd=ROOT,env=None,check=True,timeout=120):
 emit('$ '+shlex.join(map(str,cmd))+' [cwd='+str(cwd)+']')
 p=sp.run(list(map(str,cmd)),cwd=cwd,env=env,capture_output=True,text=True,timeout=timeout)
 emit('stdout:\n'+p.stdout+'stderr (complete):\n'+p.stderr+'exit='+str(p.returncode))
 if check and p.returncode: raise RuntimeError('command failed: '+shlex.join(map(str,cmd)))
 return p
ENV={k:v for k,v in os.environ.items() if not (k.startswith(('FM_','TREEHOUSE_','TASKS_AXI_','BD_')) or k in ('TMUX','TMUX_PANE','NO_MISTAKES_GATE'))}
ENV.update(NO_MISTAKES_GATE='test',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_AUTHOR_NAME='Disposable Lab',GIT_COMMITTER_NAME='Disposable Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_EMAIL='lab@example.invalid')
def need(ok,msg):
 emit(('OBSERVED OK: ' if ok else 'OBSERVED FAILURE: ')+msg)
 if not ok: raise AssertionError(msg)
def tmux(c,*args,check=True): return run(['tmux','-L','fm-lab',*args],env=c['env'],check=check)
def spawn(c,cwd,resistant=False):
 cmd=['bash','-c','trap "" TERM; printf ready > "$1"; exec sleep 600','_',str(c['dir']/'ready')] if resistant else ['sleep','600']
 p=sp.Popen(cmd,cwd=cwd,env=c['env'],stdout=sp.DEVNULL,stderr=sp.DEVNULL,start_new_session=True); processes.append(p)
 if resistant:
  for _ in range(100):
   if (c['dir']/'ready').exists(): break
   time.sleep(.02)
  need((c['dir']/'ready').exists(),'TERM-resistant process initialized')
 emit('started real process pid='+str(p.pid)+' cwd='+str(cwd)); return p

def new_case(name,kind='ship',base=False):
 d=LAB/name; d.mkdir(parents=True); home=d/'home'
 run(['bash',ROOT/'bin/fm-lab-home.sh','create',home],env=ENV)
 env=dict(ENV,FM_HOME=str(home),HOME=str(d/'toolhome'),TMPDIR=str(d/'tmp'))
 (d/'toolhome').mkdir(); (d/'tmp').mkdir()
 socketdir=run(['bash',ROOT/'bin/fm-lab-home.sh','tmux-dir',home],env=env).stdout.strip(); env['TMUX_TMPDIR']=socketdir
 c=dict(dir=d,home=home,env=env,id='task-'+name,product=LAB/('base-product' if base else 'target-product')); cases.append(c)
 project=d/'project'; project.mkdir(); c['project']=project
 run(['git','init','-q','-b','main',project],env=env)
 (project/'tracked.txt').write_text('initial\n')
 run(['git','-C',project,'add','tracked.txt'],env=env); run(['git','-C',project,'commit','-qm','initial'],env=env)
 env['TREEHOUSE_ROOT']=str(d/'pool')
 wt=pl.Path(run(['treehouse','get','--lease','--lease-holder',c['id'],'--no-fetch','--base','main'],cwd=project,env=env).stdout.strip()); c['wt']=wt
 run(['git','-C',wt,'checkout','-qb','fm/'+c['id']],env=env)
 need(run(['git','-C',project,'rev-parse','--path-format=absolute','--git-common-dir'],env=env).stdout==run(['git','-C',wt,'rev-parse','--path-format=absolute','--git-common-dir'],env=env).stdout,'project and owned pool slot share real Git common directory')
 c['claim']=wt.parent/'.fm-slot-owner'; c['claim'].write_text('task='+c['id']+'\nhome='+str(home)+'\n')
 c['tmp']=d/'tasktmp'; c['tmp'].mkdir()
 tmux(c,'new-session','-d','-s','fm-lab-teardown','-n','control','-c',str(d),'sleep 600')
 tmux(c,'new-window','-d','-t','fm-lab-teardown:','-n','fm-'+c['id'],'-c',str(d),'sleep 600')
 env['TMUX']=tmux(c,'display-message','-p','-t','fm-lab-teardown:control','#{socket_path},#{pid},0').stdout.strip()
 meta=home/'state'/(c['id']+'.meta'); c['meta']=meta
 meta.write_text('\n'.join(['window=fm-lab-teardown:fm-'+c['id'],'backend=tmux','endpoint_task_id='+c['id'],'worktree='+str(wt),'project='+str(project),'kind='+kind,'mode=local-only','spawn_gen=s1791171828.100.123','tasktmp='+str(c['tmp'])])+'\n')
 c['backlog']=home/'data/backlog.md'; c['backlog'].write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
 run(['tasks-axi','add',c['id'],'Disposable '+name,'--kind',kind,'--file',c['backlog']],env=env); run(['tasks-axi','start',c['id'],'--file',c['backlog']],env=env)
 c['controlmeta']=home/'state/control-task.meta'; c['controlmeta'].write_text('window=fm-lab-teardown:fm-control-task\nworktree='+str(d/'unrelated')+'\nproject='+str(project)+'\nkind=ship\nspawn_gen=s1791171828.101.124\n')
 (d/'unrelated').mkdir(); c['controlbytes']=c['controlmeta'].read_bytes()
 c['control']=spawn(c,d/'unrelated'); c['target']=spawn(c,wt); c['tempworker']=spawn(c,c['tmp']); time.sleep(.15)
 return c

def backlog(c,id=None): return run(['tasks-axi','show',id or c['id'],'--file',c['backlog']],env=c['env']).stdout

def preserved(c):
 need(c['control'].poll() is None,'unrelated process alive')
 need(c['controlmeta'].read_bytes()==c['controlbytes'],'unrelated task metadata byte-identical')
 need('control' in tmux(c,'list-windows','-t','fm-lab-teardown','-F','#{window_name}').stdout.splitlines(),'unrelated private tmux endpoint present')
 need(not (c['home']/'state/admin-reaper-intercept.log').exists(),'no account-wide administrative reaper invocation')

def teardown(c,label):
 p=run(['bash',c['product']/'bin/fm-teardown.sh',c['id']],env=c['env'],check=False,timeout=180)
 prefix=EVID/(c['dir'].name+'-'+label)
 pl.Path(str(prefix)+'.stdout').write_text(p.stdout); pl.Path(str(prefix)+'.stderr').write_text(p.stderr)
 return p

def refused(c,label):
 before=(c['meta'].read_bytes(),c['claim'].read_bytes(),c['backlog'].read_bytes(),(c['wt']/'tracked.txt').read_bytes())
 p=teardown(c,label)
 need(p.returncode!=0,'product refuses '+label+' before destructive cleanup')
 need(before==(c['meta'].read_bytes(),c['claim'].read_bytes(),c['backlog'].read_bytes(),(c['wt']/'tracked.txt').read_bytes()),'refusal preserves record, claim, backlog and worktree bytes')
 need(c['target'].poll() is None and c['tempworker'].poll() is None,'refusal preserves worktree and tasktmp processes')
 need('fm-'+c['id'] in tmux(c,'list-windows','-t','fm-lab-teardown','-F','#{window_name}').stdout.splitlines(),'refusal preserves target endpoint')
 preserved(c)

def success(c,label='success',retain=False):
 p=teardown(c,label)
 need(p.returncode==0,'normal teardown succeeds without force, bypass or overrides')
 need(not c['meta'].exists() and not c['claim'].exists(),'task metadata and owned claim retired')
 need(c['target'].wait(timeout=5)==-15 and c['tempworker'].wait(timeout=5)==-15,'real task worktree and tasktmp processes received TERM')
 need('fm-'+c['id'] not in tmux(c,'list-windows','-t','fm-lab-teardown','-F','#{window_name}').stdout.splitlines(),'exact task endpoint closed')
 shown=backlog(c); need(('state: queued' if retain else 'state: done') in shown,'backlog moved to '+('queued while captain-held' if retain else 'done'))
 need(not (c['home']/'state'/(c['id']+'.backlog-close')).exists(),'no pending backlog close left')
 status=run(['treehouse','status'],cwd=c['project'],env=c['env']).stdout; need('available' in status,'Treehouse slot returned to available pool')
 preserved(c); emit('PERSISTED BACKLOG:\n'+c['backlog'].read_text())

def scenario(name,fn):
 if len(sys.argv)>1 and sys.argv[1] not in name: return
 emit('\n=== SCENARIO: '+name+' ===')
 try: fn(); results.append(dict(name=name,result='pass',live=True))
 except Exception as e: emit('SCENARIO ERROR: '+repr(e)); results.append(dict(name=name,result='fail',live=True,error=repr(e)))

def report(c):
 p=c['home']/'data'/c['id']; p.mkdir(exist_ok=True)
 (p/'report.md').write_text('# Disposable scout result\n\nInvestigation completed; calls inventoried via public completion interface.\n')
def inventory(c,*ids): return run(['bash',c['product']/'bin/fm-captain-hold.sh','complete',c['id'],*(ids or ['--none'])],env=c['env'])

try:
 need(not LAB.exists(),'new disposable fixture root'); LAB.mkdir()
 for variant in ('base','target'):
  prod=LAB/(variant+'-product'); prod.mkdir()
  shutil.copytree(ROOT/'bin',prod/'bin',ignore=shutil.ignore_patterns('fm-remote-job-reap-orphans.sh'))
  intercept=prod/'bin/fm-remote-job-reap-orphans.sh'
  intercept.write_text('#!/usr/bin/env bash\nset -eu\nprintf "administrative reaper invocation intercepted; no account process scanned or changed\\n" >&2\nprintf "invoked task teardown admin sweep\\n" >> "${FM_HOME:?}/state/admin-reaper-intercept.log"\nexit 97\n'); intercept.chmod(0o755)
  if variant=='base':
   (prod/'bin/fm-teardown.sh').write_bytes(sp.check_output(['git','show',BASE+':bin/fm-teardown.sh'],cwd=ROOT))
 def baseline():
  c=new_case('baseline',base=True); p=teardown(c,'intercepted-before')
  need(p.returncode==0,'base ordinary cleanup completes with safe administrative interception')
  need((c['home']/'state/admin-reaper-intercept.log').read_text()=='invoked task teardown admin sweep\n','base normal teardown attempts forbidden account-wide command exactly once')
  need('administrative reaper invocation intercepted' in p.stderr,'complete baseline stderr records safe interception')
 scenario('Before-change normal task cleanup attempts an account-wide sweep (safely intercepted)',baseline)
 def confined():
  c=new_case('confined'); resistant=spawn(c,c['wt'],True); success(c)
  need(resistant.wait(timeout=5)==-9,'real TERM-resistant task process received scoped KILL')
 scenario('Clean ship cleanup reaps only owned processes, closes backlog and returns pool slot without account sweep',confined)
 def scout():
  c=new_case('scout',kind='scout'); refused(c,'no-report'); report(c)
  refused(c,'no-inventory')
  question='captain-choice'
  run(['bash',c['product']/'bin/fm-captain-hold.sh','hold',question,'--title','Choose route','--reason','Disposable unresolved design choice','--origin',c['id']],env=c['env'])
  inventory(c,question); success(c)
  q=backlog(c,question); need('state: queued' in q and 'held:' in q,'inventoried unresolved captain question survives scout cleanup')
  need('data/'+c['id']+'/report.md' in c['backlog'].read_text(),'closed scout backlog records report deliverable')
 scenario('Scout refuses missing report and inventory, then completes preserving inventoried captain call',scout)
 def collision():
  c=new_case('collision'); other=c['home']/'state/other-owner.meta'
  other.write_text('worktree='+str(c['wt'])+'\nproject='+str(c['project'])+'\nkind=ship\n'); b=other.read_bytes()
  refused(c,'duplicate-slot')
  need(other.read_bytes()==b,'competing owner record unchanged'); other.unlink(); success(c,'after-owner-reconciled')
 scenario('Duplicate task ownership refuses returning another task slot; reconciliation permits cleanup',collision)
 def landed():
  c=new_case('landed'); (c['wt']/'tracked.txt').write_text('unlanded task change\n')
  refused(c,'dirty-work')
  run(['git','-C',c['wt'],'add','tracked.txt'],env=c['env']); run(['git','-C',c['wt'],'commit','-qm','task change'],env=c['env'])
  refused(c,'unlanded-commit')
  run(['git','-C',c['project'],'merge','--ff-only','fm/'+c['id']],env=c['env']); success(c,'after-landed')
 scenario('Ship refuses dirty and unlanded work, then succeeds after real local-main landing',landed)
 def held():
  c=new_case('held-scout',kind='scout'); report(c); inventory(c)
  run(['bash',c['product']/'bin/fm-captain-hold.sh','hold',c['id'],'--reason','Captain must decide on completed investigation'],env=c['env'])
  success(c,'retain-captain-call',retain=True); need('held:' in backlog(c),'cleanup preserves captain hold on work item')
 scenario('Captain-held completed scout is cleaned up while its backlog item stays queued and held',held)
finally:
 for c in cases:
  try:
   tmux(c,'kill-server',check=False); run(['bash',ROOT/'bin/fm-lab-home.sh','teardown',c['home']],env=c['env'])
  except Exception as e: emit('CLEANUP ERROR: '+repr(e))
 for p in processes:
  if p.poll() is None: p.terminate()
 for p in processes:
  try: p.wait(timeout=3)
  except sp.TimeoutExpired: p.kill(); p.wait()
 if LAB.exists(): shutil.rmtree(LAB)
 emit('Disposable fixture root removed: '+str(not LAB.exists()))
 (EVID/('live-teardown-'+run_suffix+'-results.json')).write_text(json.dumps(results,indent=2)+'\n'); log.close()
if any(x['result']=='fail' for x in results): raise SystemExit(1)
