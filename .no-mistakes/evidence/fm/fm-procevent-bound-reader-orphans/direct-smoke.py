from pathlib import Path
import os, sys, subprocess, signal, time, json, hashlib, re
root = Path.cwd()
work = root/'.local-procevent-validation/direct'
work.mkdir()
home=work/'home'
(home/'state').mkdir(parents=True)
claims=work/'claims'
claims.mkdir()
evidence=Path('/Users/charlesabrooker/.no-mistakes/evidence/01M5AMRV9YCEP5976Y6H3ABHJ7')
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE','LAVISH_AXI_STATE_DIR'):
        env.pop(key,None)
env.update(FM_HOME=str(home), FM_PROCEVENT_CLAIM_ROOT=str(claims), HOME=str(root/'.local-procevent-validation/home'), TMPDIR=str(work), FM_DURATION_FILE='off', PYTHONDONTWRITEBYTECODE='1')
log=[]
def record(message):
    log.append(message)
    print(message,flush=True)
def pe(*args, limit=None):
    localenv=env.copy()
    if limit is not None:
        localenv['FM_PROCEVENT_MAX_OUTPUT_BYTES']=str(limit)
    cp=subprocess.run(['bash',str(root/'bin/fm-procevent.sh'),*args],env=localenv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=40)
    record('$ bin/fm-procevent.sh '+' '.join(args)+'\nexit='+str(cp.returncode)+'\nstdout='+cp.stdout+'stderr='+cp.stderr)
    if cp.returncode:
        raise RuntimeError('Product command failed')
    return cp

def rows():
    result={}
    for line in subprocess.check_output(['ps','-axww','-o','pid=,ppid=,pgid=,lstart=,command='],text=True).splitlines():
        m=re.match(r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+\S+\s+\d+)\s+(.*)$',line)
        if m:
            pid,parent,group,birth,command=m.groups()
            result[int(pid)]={'parent':int(parent),'group':int(group),'birth':birth,'command':command}
    return result

def waitfor(fn, seconds=10):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        value=fn()
        if value:
            return value
        time.sleep(.05)
    raise RuntimeError('Timed out waiting for live product observation')

source=work/'holding-source.py'
source.write_text('import os,time\nfrom pathlib import Path\nPath('+repr(str(work/'source.pid'))+').write_text(str(os.getpid()))\nprint("holding stdout open", flush=True)\ntime.sleep(120)\n')
runner=None
source_pid=None
source_identity=None
try:
    pe('register','lavish','direct-kill','--detach','--',sys.executable,str(source))
    waitfor(lambda:(work/'source.pid').exists())
    source_pid=int((work/'source.pid').read_text())
    waitfor(lambda:(claims/'direct-kill.claim').exists())
    runner=int((claims/'direct-kill.claim').read_text().splitlines()[1])
    before=rows()
    source_identity=before[source_pid]
    assert source_identity['group']==runner and str(source) in source_identity['command']
    assert str(root/'bin/fm-procevent.sh') in before[runner]['command'] and '_start direct-kill' in before[runner]['command']
    def reader_ready():
        return [(pid,row) for pid,row in rows().items() if row['parent']==runner and 'sysread(STDIN' in row['command'] and re.match(r'^\S*perl\s+-e\s',row['command'])]
    reader_pid,reader_identity=waitfor(reader_ready)[0]
    record('Before SIGKILL: '+json.dumps({'runner_pid':runner,'source_pid':source_pid,'source_pgid':source_identity['group'],'reader_pid':reader_pid,'reader_ppid':reader_identity['parent']}))
    started=time.monotonic()
    os.kill(runner,signal.SIGKILL)
    def reader_gone():
        row=rows().get(reader_pid)
        return row is None or row['birth']!=reader_identity['birth']
    waitfor(reader_gone,5)
    after=rows()
    assert source_pid in after and after[source_pid]['birth']==source_identity['birth']
    record('After runner-only SIGKILL: reader absent in %.3f seconds; source PID %d still alive in group %d and holding stdout open.'%(time.monotonic()-started,source_pid,after[source_pid]['group']))
finally:
    if source_pid and source_identity:
        current=rows().get(source_pid)
        if current and current['birth']==source_identity['birth'] and current['group']==runner and str(source) in current['command']:
            os.killpg(runner,signal.SIGKILL)
            record('Cleanup: signalled only the identity-checked process group belonging to this disposable source.')
    (evidence/'direct-product-smoke.log').write_text('\n'.join(log)+'\n')
pe('retire','direct-kill')

binary=work/'binary-source.py'
binary.write_text('import sys,time\nsys.stdout.buffer.write(b"prefix\\0"); sys.stdout.buffer.flush()\ntime.sleep(2)\nsys.stdout.buffer.write(bytes(range(256))*512+b"tail"); sys.stdout.buffer.flush()\nsys.exit(7)\n')
payload=b'prefix\0'+bytes(range(256))*512+b'tail'
for bound in (0,65541,len(payload)):
    source_id='direct-binary-'+str(bound)
    pe('register','lavish',source_id,'--',sys.executable,str(binary))
    pe('start',source_id,limit=bound)
    actual=(home/'state/procevent-inbox'/(source_id+'.1.result')).read_bytes()
    assert actual==payload[:bound], (bound,len(actual))
    record('Durable captured output: '+json.dumps({'source_id':source_id,'bound':bound,'bytes':len(actual),'sha256':hashlib.sha256(actual).hexdigest(),'exact_expected_bytes':True,'source_exit':7,'idle_seconds':2}))
    (evidence/(source_id+'.result')).write_bytes(actual)
    pe('retire',source_id)
(evidence/'direct-product-smoke.log').write_text('\n'.join(log)+'\n')
record('Direct public-interface smoke complete: no Perl/PATH shims and no harness or backend substitutes.')
(evidence/'direct-product-smoke.log').write_text('\n'.join(log)+'\n')
