from pathlib import Path
import subprocess, os, sys, hashlib, json
root=Path.cwd()
work=root/'.local-procevent-validation/binary'
(work/'home/state').mkdir(parents=True)
(work/'claims').mkdir()
evidence=Path('/Users/charlesabrooker/.no-mistakes/evidence/01M5AMRV9YCEP5976Y6H3ABHJ7')
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_'):
        env.pop(key,None)
env.update(FM_HOME=str(work/'home'), FM_PROCEVENT_CLAIM_ROOT=str(work/'claims'), HOME=str(root/'.local-procevent-validation/home'), TMPDIR=str(work), FM_DURATION_FILE='off', PYTHONDONTWRITEBYTECODE='1')
source=work/'binary-source.py'
source.write_text('import sys,time\nsys.stdout.buffer.write(b"prefix\\0"); sys.stdout.buffer.flush()\ntime.sleep(2)\nsys.stdout.buffer.write(bytes(range(256))*512+b"tail"); sys.stdout.buffer.flush()\nsys.exit(int(sys.argv[1]))\n')
payload=b'prefix\0'+bytes(range(256))*512+b'tail'
log=['Direct public-interface binary capture proof: unmodified worktree scripts; normal Perl/PATH.', 'Fixture correction: an initial zero-bound source exited 7 and correctly produced no-result, not a captured result. Successful zero-byte capture below uses source exit 0, matching the product contract.']
try:
    for bound,status in ((0,0),(65541,7),(len(payload),7),(0,7)):
        id='direct-binary-'+str(bound)+'-exit'+str(status)
        for args in (['register','lavish',id,'--',sys.executable,str(source),str(status)], ['start',id]):
            localenv=env.copy()
            localenv['FM_PROCEVENT_MAX_OUTPUT_BYTES']=str(bound)
            cp=subprocess.run(['bash',str(root/'bin/fm-procevent.sh'),*args],env=localenv,capture_output=True,text=True,timeout=40)
            log.append('$ bin/fm-procevent.sh '+' '.join(args)+'\nexit='+str(cp.returncode)+'\nstdout='+cp.stdout+'stderr='+cp.stderr)
            assert cp.returncode==0
        result=work/'home/state/procevent-inbox'/(id+'.1.result')
        if bound==0 and status!=0:
            assert not result.exists() and 'no-result:' in cp.stdout
            log.append('Observed nonzero source exit with zero retained bytes: no durable result, registration remains available for reconciliation.')
        else:
            actual=result.read_bytes()
            assert actual==payload[:bound], (bound,len(actual))
            assert ('truncated:' in cp.stderr)==(bound<len(payload))
            log.append('Persisted exact capture: '+json.dumps({'source_id':id,'bound':bound,'bytes':len(actual),'sha256':hashlib.sha256(actual).hexdigest(),'exact_expected_bytes':True,'source_exit':status,'idle_seconds':2}))
            (evidence/(id+'.result')).write_bytes(actual)
        retired=subprocess.run(['bash',str(root/'bin/fm-procevent.sh'),'retire',id],env=env,capture_output=True,text=True,timeout=15)
        assert retired.returncode==0
        log.append(retired.stdout.strip())
finally:
    text='\n'.join(log)+'\n'
    (evidence/'direct-binary-capture.log').write_text(text)
    print(text)
