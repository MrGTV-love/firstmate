#!/usr/bin/env python3
import argparse, fcntl, json, os, pathlib, shutil, signal, subprocess, sys, tempfile, time
BASE=pathlib.Path('/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4XFRRHNM6DGKRMTRZQB0YPJ')
GATE=BASE/'bin/fm-lint-cache.pl'
OWNER=BASE/'bin/fm-lint.sh'
a=argparse.ArgumentParser(); a.add_argument('--evidence',required=True); args=a.parse_args()
evidence=pathlib.Path(args.evidence)
d=pathlib.Path(tempfile.mkdtemp(prefix='.lint-budget-',dir=BASE))
(d/'slots').mkdir(); (d/'root/bin').mkdir(parents=True)
for name in ['fm-lint.sh','fm-lint-cache.pl']: shutil.copyfile(BASE/'bin'/name,d/'root/bin'/name)
(d/'root/bin/root.sh').write_text('#!/bin/bash\nexit 0\n')
processes=[]; logs=[]; results=[]

def log(s): print(s,flush=True); logs.append(s)
def await_(check,msg):
    deadline=time.monotonic()+10
    while not check():
        if time.monotonic()>deadline: raise AssertionError(msg)
        time.sleep(.01)
def start(cmd,env=None):
    e=dict(os.environ,FM_LINT_INTERNAL='1',FM_LINT_HOST_SLOTS='1')
    e.pop('PERL5OPT',None)
    if env: e.update(env)
    p=subprocess.Popen(cmd,env=e,cwd=BASE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    processes.append(p); return p

def timed(command):
    return ['perl','-e','setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"',
            'bash',str(OWNER),'--internal-timed','1','1',*command]
def gate(name,command):
    return ['perl',str(GATE),'gate',str(d/'slots'),'18','budget-run',str(d/(name+'.wait')),'--',*command]
def finish(p,expected=0):
    out,err=p.communicate(timeout=10)
    log('exit='+str(p.returncode)+' stdout='+out.strip()+' stderr='+err.strip())
    assert p.returncode==expected,'unexpected product command exit'

def scenario(name,fn):
    log('\nSCENARIO '+name)
    try: detail=fn(); result={'name':name,'result':'pass','live':True,'detail':detail}
    except Exception as e: result={'name':name,'result':'fail','live':True,'detail':repr(e)}
    results.append(result); log(json.dumps(result))

def host_budget():
    holder=open(d/'slots/slot.0','a+'); fcntl.flock(holder,fcntl.LOCK_EX)
    command=timed([sys.executable,'-c','import time; time.sleep(.2); print("watchdog payload completed")'])
    t=time.monotonic(); p=start(gate('host',command))
    await_(lambda:any('.'+str(p.pid)+'.' in f.name for f in (d/'slots').glob('queue.*')),'host request did not queue')
    time.sleep(2); holder.close(); finish(p)
    elapsed=time.monotonic()-t; queued=int((d/'host.wait').read_text())
    assert queued>=1900 and elapsed>2,'host queue not longer than watchdog allowance'
    log('Host queue_ms='+str(queued)+' total_seconds='+str(round(elapsed,3))+' watchdog_seconds=1 payload_seconds=0.2')
    return {'host_wait_ms':queued,'total_seconds':round(elapsed,3),'watchdog_seconds':1}

def key_budget():
    marker=d/'first.started'
    def check(name,cmd):
        return start(['perl',str(GATE),'check',str(d/'cache'),str(d/'root'),'/usr/bin/true','--','bin/root.sh','--execute',*cmd],
                     {'FM_LINT_CACHE_RESULT_FILE':str(d/(name+'.cache'))})
    first=check('first',[sys.executable,'-c','import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(2); print("uncached exit 7"); sys.exit(7)',str(marker)])
    await_(marker.exists,'first cold command not running')
    t=time.monotonic()
    second=check('second',gate('key',timed([sys.executable,'-c','import time; time.sleep(.2); print("cold watchdog completed after cache-key wait")'])))
    finish(first,7); finish(second)
    queued=int((d/'second.cache.wait').read_text()); elapsed=time.monotonic()-t
    assert queued>=1800 and (d/'second.cache').read_text()=='analyzed\n','key wait was not real cold execution'
    log('Key queue_ms='+str(queued)+' total_seconds='+str(round(elapsed,3))+' watchdog_seconds=1 payload_seconds=0.2')
    return {'cache_key_wait_ms':queued,'total_seconds':round(elapsed,3),'watchdog_seconds':1,'cache_outcome':'analyzed'}

def explicit_operand():
    (d/'root/--execute').write_text('#!/bin/bash\nexit 0\n')
    p=start(['perl',str(GATE),'check','off',str(d/'root'),'/bin/echo','--','--execute'])
    out,err=p.communicate(timeout=5); log('literal operand stdout='+repr(out)+' exit='+str(p.returncode))
    assert p.returncode==0 and out=='-- --execute\n','literal --execute was interpreted as private marker'
    return {'stdout':out,'exit':p.returncode,'real_command':'/bin/echo'}

def cancellation():
    marker=d/'cancel.started'
    payload=[sys.executable,'-c','import pathlib,sys,time,os; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)',str(marker)]
    cmd=['perl',str(GATE),'check','off',str(d/'root'),'/usr/bin/true','--','bin/root.sh','--execute',*gate('cancel',payload)]
    p=start(cmd); await_(marker.exists,'cold command never started')
    child=int(marker.read_text()); p.terminate(); finish(p,143)
    try: os.kill(child,0); alive=True
    except ProcessLookupError: alive=False
    assert not alive,'cancelled cold descendant survived'
    later=start(gate('after-cancel',['/bin/echo','later request admitted after cancellation']))
    finish(later)
    log('Cancelled cache owner exit=143; protected child absent; next request admitted')
    return {'cancel_exit':143,'cold_child_alive':alive,'later_exit':later.returncode}

try:
    scenario('Host-slot waiting longer than watchdog budget still permits cold completion',host_budget)
    scenario('Cache-key waiting longer than watchdog budget still permits cold completion',key_budget)
    scenario('Literal --execute operand stays a root instead of becoming command metadata',explicit_operand)
    scenario('Cancelling cache owner reaps cold command and releases admission',cancellation)
finally:
    for p in processes:
        if p.poll() is None:
            p.terminate()
            try:p.communicate(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.communicate()
    shutil.rmtree(d)
    (evidence/'queue-budget-transcript.log').write_text('\n'.join(logs)+'\n')
    (evidence/'queue-budget-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.copyfile(__file__,evidence/'queue-budget-driver.py')
