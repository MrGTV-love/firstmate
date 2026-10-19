from pathlib import Path
import os, subprocess, json, sys
root=Path.cwd()
work=root/'.local-procevent-validation'
evidence=Path('/Users/charlesabrooker/.no-mistakes/evidence/01M5AMRV9YCEP5976Y6H3ABHJ7')
env=os.environ.copy()
for key in ('FM_HOME','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_DURATION_HOME','FM_TASK_ID','FM_CPU_PASS_HELD','FM_TEST_SLOT_HELD'):
    env.pop(key,None)
env.update(HOME=str(work/'home'),TMPDIR=str(work/'tmp'),FM_DURATION_FILE='off',FM_CPU_POOL_DIR=str(work/'cpu-pool'),FM_TEST_SLOT_DIR=str(work/'slots'),PYTHONDONTWRITEBYTECODE='1')
command=['nice','-n','20','bash','bin/fm-test-run.sh','--jobs','1','tests/fm-procevent-runner-custody.test.sh']
proc=subprocess.Popen(command,cwd=work/'target',env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
with (evidence/'target-runner-custody.log').open('w') as log:
    log.write('Command: '+' '.join(command)+'\nTarget source view: unchanged regular-file copies of worktree product scripts; adapter symlinks removed to satisfy relisten ownership contract. Only the test reaper entry point scopes no-argument sweeping to this run private TMPDIR; explicit owner-scoped cleanup unchanged.\n')
    for line in proc.stdout:
        log.write(line)
        log.flush()
        print(line,end='',flush=True)
    code=proc.wait()
    log.write('\nObserved exit status: '+str(code)+'\n')
results=json.loads((evidence/'targeted-run-results.json').read_text())
results['target_initial_symlink_setup']=results['target']
results['target']=code
(evidence/'targeted-run-results.json').write_text(json.dumps(results,indent=2)+'\n')
sys.exit(code)
