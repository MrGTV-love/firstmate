#!/usr/bin/env python3
import argparse, fcntl, json, os, pathlib, shutil, signal, subprocess, sys, tempfile, time

BASE = pathlib.Path('/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4XFRRHNM6DGKRMTRZQB0YPJ')
GATE = BASE / 'bin/fm-lint-cache.pl'
parser = argparse.ArgumentParser()
parser.add_argument('--evidence', required=True)
args = parser.parse_args()
evidence = pathlib.Path(args.evidence)
evidence.mkdir(parents=True, exist_ok=True)
fixture = pathlib.Path(tempfile.mkdtemp(prefix='.lint-live-', dir=BASE))
processes = []
results = []
transcript = []
PAYLOAD = '''import pathlib,sys,time
p=pathlib.Path(sys.argv[1]); name=sys.argv[2]
(p/(name+'.started')).write_text(str(time.time()))
print('cold command started '+name,flush=True)
deadline=time.monotonic()+45
while not (p/(name+'.release')).exists():
    if time.monotonic()>deadline: sys.exit(71)
    time.sleep(.01)
print('cold command completed '+name,flush=True)
'''

def say(text):
    print(text, flush=True)
    transcript.append(text)

def await_(check, message, seconds=10):
    deadline = time.monotonic()+seconds
    while not check():
        if time.monotonic()>deadline: raise AssertionError(message)
        time.sleep(.01)

def case_dir(name):
    d=fixture/name
    (d/'slots').mkdir(parents=True)
    return d

def spawn(d, name, run, cap=None, ncpu=18, command=None):
    env = dict(os.environ)
    env.pop('PERL5OPT',None)
    env.pop('FM_TEST_SEAM',None)
    env.pop('FM_LINT_SLOT_LOAD',None)
    if cap is None: env.pop('FM_LINT_HOST_SLOTS',None)
    else: env['FM_LINT_HOST_SLOTS']=str(cap)
    cmd=['perl',str(GATE),'gate',str(d/'slots'),str(ncpu),run,str(d/(name+'.wait')),'--']
    cmd += command or [sys.executable,'-c',PAYLOAD,str(d),name]
    p=subprocess.Popen(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,cwd=BASE)
    processes.append(p)
    return p

def queued(d,p):
    return any('.'+str(p.pid)+'.' in f.name for f in (d/'slots').glob('queue.*') if f.name!='queue.next')

def started(d,name): return (d/(name+'.started')).exists()
def release(d,name): (d/(name+'.release')).touch()

def finish(p):
    out,err=p.communicate(timeout=10)
    if out.strip(): say(out.strip())
    if err.strip(): say(err.strip())
    if p.returncode!=0: raise AssertionError('gate pid %s returned %s'%(p.pid,p.returncode))

def holds(d, count):
    holders=[]
    for i in range(count):
        f=open(d/'slots'/('slot.'+str(i)),'a+')
        fcntl.flock(f,fcntl.LOCK_EX)
        holders.append(f)
    return holders

def scenario(name,fn):
    say('\nSCENARIO '+name)
    t=time.monotonic()
    try:
        detail=fn()
        result={'name':name,'result':'pass','live':True,'detail':detail,'wall_seconds':round(time.monotonic()-t,3)}
    except Exception as e:
        result={'name':name,'result':'fail','live':True,'detail':str(e),'wall_seconds':round(time.monotonic()-t,3)}
    results.append(result)
    say(json.dumps(result))
    # Finish every disposable command even when an assertion fails.
    for f in fixture.rglob('*.started'):
        f.with_suffix('.release').touch()
    for p in processes:
        if p.poll() is None:
            p.send_signal(signal.SIGCONT)
            try: p.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                p.terminate()
                try: p.communicate(timeout=3)
                except subprocess.TimeoutExpired: p.kill(); p.communicate()


def capacity():
    observed=[]
    for ncpu,cap,expected in [(18,None,9),(4,None,2),(1,None,2),(18,1,1),(18,2,2)]:
        d=case_dir('cap-%s-%s'%(ncpu,cap))
        ps=[spawn(d,'p'+str(i),'capacity',cap,ncpu) for i in range(expected+2)]
        await_(lambda: sum(started(d,'p'+str(i)) for i in range(len(ps)))>=expected,'capacity never filled')
        time.sleep(.4)
        actual=sum(started(d,'p'+str(i)) for i in range(len(ps)))
        say('ncpu=%s override=%s started=%s expected=%s queued=%s'%(ncpu,cap,actual,expected,sum(queued(d,p) for p in ps)))
        assert actual==expected,'CPU cap breached or reduced: '+str(actual)
        observed.append({'ncpu':ncpu,'override':cap,'active':actual})
        for i in range(len(ps)): release(d,'p'+str(i))
        for p in ps: finish(p)
    return observed

def fairness(cap):
    if cap == 2:
        return two_slot_fairness()
    d=case_dir('fair-'+str(cap))
    holders=holds(d,cap)
    a=[]
    for i in range(9):
        p=spawn(d,'A'+str(i),'nine-worker-run',cap)
        a.append(p)
        await_(lambda:queued(d,p),'nine-worker request did not queue')
    b=spawn(d,'B0','one-worker-run',cap)
    await_(lambda:queued(d,b),'one-worker request did not queue')
    demand_since=time.time()
    for f in holders: f.close()
    order=[]; completed=set(); bindex=0; gap=0; maxgap=0
    pending_b=True
    deadline=time.monotonic()+20
    while len(completed)<12:
        if time.monotonic()>deadline: raise AssertionError('fairness commands did not complete; order='+str(order))
        new=[f.stem for f in sorted(d.glob('*.started'),key=lambda f:float(f.read_text())) if f.stem not in completed]
        if not new: time.sleep(.01); continue
        # Keep each command admitted until the controller records its service.
        for name in new:
            order.append(name)
            say('admitted '+name+' pending-one-worker='+str(pending_b))
            if name.startswith('A'):
                if bindex>0 and pending_b and float((d/(name+'.started')).read_text()) >= demand_since:
                    gap+=1; maxgap=max(maxgap,gap)
                release(d,name); finish(a[int(name[1:])])
            else:
                gap=0
                release(d,name); finish(b)
                bindex+=1
                pending_b=bindex<3
                if pending_b:
                    b=spawn(d,'B'+str(bindex),'one-worker-run',cap)
                    await_(lambda:queued(d,b) or started(d,'B'+str(bindex)),'new one-worker demand never appeared')
                    demand_since=time.time()
            completed.add(name)
    say('service order='+','.join(order)+' max nine-worker starts while later one-worker demand waits='+str(maxgap))
    assert maxgap<=1,'per-run fairness violated: '+str(maxgap)+' nine-worker turns while one-worker demand waited; order='+','.join(order)
    return {'capacity':cap,'service_order':order,'max_competing_turns':maxgap}

def two_slot_fairness():
    d=case_dir('fair-two-controlled')
    holders=holds(d,2)
    a=[]
    for i in range(9):
        p=spawn(d,'A'+str(i),'nine-worker-run',2)
        a.append(p)
        await_(lambda:queued(d,p),'nine-worker request did not queue')
    holders[0].close()
    await_(lambda:started(d,'A0'),'first worker did not fill free slot')
    b=spawn(d,'B0','one-worker-run',2)
    await_(lambda:queued(d,b),'one-worker demand not queued')
    holders[1].close()
    await_(lambda:started(d,'B0'),'one-worker did not get its fair slot')
    assert not started(d,'A1'),'older backlog bypassed lower-occupancy run'
    order=['A0','B0']
    for i in range(1,3):
        release(d,'B'+str(i-1)); finish(b)
        # The nine-worker run may use spare capacity while the one-worker run
        # has no demand. Keep that admitted command live before adding demand.
        await_(lambda:started(d,'A'+str(i)),'spare capacity was not used')
        b=spawn(d,'B'+str(i),'one-worker-run',2)
        await_(lambda:queued(d,b),'later one-worker demand did not queue')
        release(d,'A'+str(i)); finish(a[i])
        await_(lambda:started(d,'B'+str(i)),'older nine-worker backlog blocked fair progress')
        assert not started(d,'A'+str(i+1)),'older backlog took another turn ahead of queued lower-occupancy run'
        order+=['A'+str(i),'B'+str(i)]
    release(d,'B2'); finish(b)
    for i in range(9): release(d,'A'+str(i))
    for i,p in enumerate(a):
        if i not in [1,2]: finish(p)
    say('two-slot fair service='+','.join(order)+'; each release served queued one-worker demand before older backlog, while spare capacity was used between demands')
    return {'capacity':2,'controlled_service_order':order,'all_nine_worker_requests_finished':True}

def lifecycle(kind):
    d=case_dir('owner-'+kind)
    holder=holds(d,1)[0]
    old=spawn(d,'older','same-run',1)
    await_(lambda:queued(d,old),'older request never queued')
    if kind=='stopped':
        coordinator=open(d/'slots/admission.lock','a+')
        deadline=time.monotonic()+5
        while True:
            old.send_signal(signal.SIGSTOP)
            try: fcntl.flock(coordinator,fcntl.LOCK_EX|fcntl.LOCK_NB); break
            except BlockingIOError:
                old.send_signal(signal.SIGCONT)
                if time.monotonic()>deadline: raise AssertionError('cannot stop outside short coordinator critical section')
                time.sleep(.01)
        fcntl.flock(coordinator,fcntl.LOCK_UN); coordinator.close()
    elif kind=='dead': old.kill(); old.communicate(timeout=5)
    younger=spawn(d,'younger','same-run',1)
    await_(lambda:queued(d,younger),'younger request never queued')
    holder.close()
    first='older' if kind=='live' else 'younger'
    second='younger' if kind=='live' else 'older'
    await_(lambda:started(d,first),'eligible waiter did not start',6)
    assert not started(d,second),'ineligible command started or live FIFO was bypassed'
    release(d,first); finish(old if kind=='live' else younger)
    if kind=='stopped': old.send_signal(signal.SIGCONT)
    if kind!='dead':
        await_(lambda:started(d,second),'next/resumed waiter did not start')
        release(d,second); finish(younger if kind=='live' else old)
    waits={f.name:int(f.read_text()) for f in d.glob('*.wait')}
    say('owner='+kind+' admission order='+first+(' -> '+second if kind!='dead' else '')+' queue_ms='+str(waits))
    assert not [f for f in (d/'slots').glob('queue.*') if f.name!='queue.next'],'stale ticket remained'
    return {'owner_state':kind,'first':first,'wait_milliseconds':waits}

def inheritance():
    d=case_dir('inheritance')
    p=spawn(d,'protected','protected-run',1)
    await_(lambda:started(d,'protected'),'protected command never started')
    p.kill(); p.wait(timeout=5)
    later=spawn(d,'later','later-run',1)
    await_(lambda:queued(d,later),'later command not queued')
    time.sleep(.5)
    assert not started(d,'later'),'gate death released a still-inherited slot'
    release(d,'protected')
    p.communicate(timeout=5)
    await_(lambda:started(d,'later'),'last descendant exit did not release slot')
    release(d,'later'); finish(later)
    say('gate killed; descendant retained slot; queued command started only after descendant exit')
    return 'Inherited flock survived SIGKILL of gate and was released by the real descendant exit.'

def stopped_coordinator():
    d=case_dir('stopped-coordinator')
    holder=holds(d,1)[0]
    old=spawn(d,'older','older-run',1)
    await_(lambda:queued(d,old),'older request never queued')
    coordinator=open(d/'slots/admission.lock','a+')
    deadline=time.monotonic()+10
    attempts=0
    while True:
        try:
            fcntl.flock(coordinator,fcntl.LOCK_EX|fcntl.LOCK_NB)
            fcntl.flock(coordinator,fcntl.LOCK_UN)
        except BlockingIOError:
            attempts+=1
            old.send_signal(signal.SIGSTOP)
            time.sleep(.01)
            try:
                fcntl.flock(coordinator,fcntl.LOCK_EX|fcntl.LOCK_NB)
                fcntl.flock(coordinator,fcntl.LOCK_UN)
                old.send_signal(signal.SIGCONT)
            except BlockingIOError:
                break
        if time.monotonic()>deadline: raise AssertionError('could not synchronize STOP inside admission critical section')
    state=subprocess.check_output(['ps','-o','pid=,stat=','-p',str(old.pid)],text=True).strip()
    say('Stopped real queued gate while it owns admission.lock: '+state+' synchronization_attempts='+str(attempts))
    younger=spawn(d,'younger','younger-run',1)
    holder.close()
    time.sleep(3)
    blocked=not started(d,'younger')
    say('after 3 seconds with a free slot: younger_started='+str(started(d,'younger'))+' younger_has_ticket='+str(queued(d,younger)))
    old.send_signal(signal.SIGCONT)
    release(d,'older'); release(d,'younger')
    finish(old); finish(younger)
    coordinator.close()
    assert not blocked,'stopped admission.lock owner blocks all later waiters even with the analyzer slot free; resuming owner restored progress'
    return 'A stopped coordinator owner did not block later waiters.'

def cache_scenarios():
    d=case_dir('cache [odd path]')
    one=d/'one'; two=d/'two'
    for root in [one,two]:
        (root/'bin').mkdir(parents=True)
        for name in ['fm-lint.sh','fm-lint-cache.pl']:
            shutil.copyfile(BASE/'bin'/name,root/'bin'/name)
        (root/'bin/library.sh').write_text('#!/bin/bash\nvalue=old\n')
        (root/'bin/consumer.sh').write_text('#!/bin/bash\n. bin/library.sh\nprintf \"%s\\n\" \"$value\"\n')
    counter=d/'executions.log'
    def check(name,root,delay=.1,rc=0):
        env=dict(os.environ,FM_LINT_CACHE_RESULT_FILE=str(d/(name+'.cache')),FM_LINT_HOST_SLOTS='1')
        env.pop('PERL5OPT',None)
        payload='import pathlib,time,sys; p=pathlib.Path(sys.argv[1]); p.open(\"a\").write(sys.argv[2]+\"\\n\"); print(\"cold payload \"+sys.argv[2],flush=True); time.sleep(float(sys.argv[3])); sys.exit(int(sys.argv[4]))'
        cmd=['perl',str(GATE),'check',str(d/'cache'),str(root),'/usr/bin/true','--','bin/consumer.sh','--execute',
             'perl',str(GATE),'gate',str(d/'slots'),'18','cache-run',str(d/(name+'.wait')),'--',
             sys.executable,'-c',payload,str(counter),name,str(delay),str(rc)]
        p=subprocess.Popen(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,cwd=BASE)
        processes.append(p)
        return p
    a=check('initial',one); finish(a)
    assert counter.read_text()=='initial\n'
    holder=holds(d,1)[0]
    b=check('cross-worktree-hit',two)
    finish(b)
    assert (d/'cross-worktree-hit.cache').read_text()=='cache-hit\n'
    assert not (d/'cross-worktree-hit.wait').exists(),'cache hit entered admission'
    assert counter.read_text()=='initial\n','cache hit executed cold command'
    holder.close()
    for root in [one,two]: (root/'bin/library.sh').write_text('#!/bin/bash\nvalue=changed\n')
    c=check('single-flight-first',one,1.5)
    await_(lambda:counter.exists() and 'single-flight-first' in counter.read_text(),'cold source change did not execute')
    e=check('single-flight-second',two)
    time.sleep(.4)
    assert not (d/'single-flight-second.wait').exists(),'duplicate waiter consumed a host slot'
    finish(c); finish(e)
    assert (d/'single-flight-second.cache').read_text()=='cache-hit\n'
    waitms=int((d/'single-flight-second.cache.wait').read_text())
    assert waitms>=900,'cache-key wait not recorded'
    assert counter.read_text().splitlines()==['initial','single-flight-first'],'identical concurrent miss executed twice'
    (one/'bin/library.sh').write_text('#!/bin/bash\nvalue=failed\n')
    f=check('failure-first',one,0,7)
    out,err=f.communicate(timeout=5); say(out.strip())
    assert f.returncode==7,'cold failure exit was not preserved'
    g=check('failure-second',one,0,7)
    out,err=g.communicate(timeout=5); say(out.strip())
    assert g.returncode==7 and (d/'failure-second.cache').read_text()=='analyzed\n','failure was incorrectly cached'
    say('Real cache/gate wrapper: cross-root hit bypassed occupied slot; changed source ran cold; identical concurrent miss reused one execution; cache key wait_ms='+str(waitms)+'; exit 7 replayed by fresh execution.')
    return {'cold_commands':counter.read_text().splitlines(),'key_queue_ms':waitms,'failure_exit_codes':[f.returncode,g.returncode],'payload':'/usr/bin/true identity with real Python --execute command; no ShellCheck invoked'}

try:
    say('Product: '+str(GATE))
    say('Host load snapshot: '+subprocess.check_output(['uptime'],text=True).strip())
    scenario('CPU-derived capacity fills under current load and never oversubscribes',capacity)
    scenario('Nine-worker and one-worker runs get fair service on one slot',lambda:fairness(1))
    scenario('Nine-worker and one-worker runs get fair service on two slots',lambda:fairness(2))
    for kind in ['live','dead','stopped']:
        scenario(kind+' head waiter preserves progress and queue correctness',lambda k=kind:lifecycle(k))
    scenario('Stopping the admission coordinator cannot freeze a free pool',stopped_coordinator)
    scenario('Cache wrappers bypass occupied slots and serialize identical misses across roots',cache_scenarios)
    scenario('Killing gate does not release a protected descendant slot',inheritance)
finally:
    for f in fixture.rglob('*.started'): f.with_suffix('.release').touch()
    for p in processes:
        if p.poll() is None:
            p.send_signal(signal.SIGCONT); p.terminate()
            try: p.communicate(timeout=5)
            except subprocess.TimeoutExpired: p.kill(); p.communicate()
    shutil.rmtree(fixture)
    (evidence/'gate-live-transcript.log').write_text('\n'.join(transcript)+'\n')
    (evidence/'gate-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.copyfile(__file__,evidence/'gate-live-driver.py')
