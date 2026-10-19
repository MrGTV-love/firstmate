from pathlib import Path
import os, subprocess, json, datetime, sys
root = Path.cwd()
work = root / '.local-procevent-validation'
evidence = Path('/Users/charlesabrooker/.no-mistakes/evidence/01M5AMRV9YCEP5976Y6H3ABHJ7')
env = os.environ.copy()
for key in ('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_DURATION_HOME', 'FM_TASK_ID', 'FM_CPU_PASS_HELD', 'FM_TEST_SLOT_HELD'):
    env.pop(key, None)
env.update(HOME=str(work/'home'), TMPDIR=str(work/'tmp'), FM_DURATION_FILE='off', FM_CPU_POOL_DIR=str(work/'cpu-pool'), FM_TEST_SLOT_DIR=str(work/'slots'), PYTHONDONTWRITEBYTECODE='1')
results = {}
for version in ('baseline', 'target'):
    view = work/version
    command = ['nice','-n','20','bash','bin/fm-test-run.sh','--jobs','1','tests/fm-procevent-runner-custody.test.sh']
    print('Running '+version+': '+ ' '.join(command), flush=True)
    proc = subprocess.Popen(command, cwd=view, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    with (evidence/(version+'-runner-custody.log')).open('w') as log:
        log.write('Source view: '+version+'\nCommand: '+' '.join(command)+'\nRunner default orphan sweep restricted to '+str(work/'tmp')+'; explicit owner-scoped cleanup unchanged.\n')
        for line in proc.stdout:
            log.write(line)
            log.flush()
            print(line, end='', flush=True)
        code = proc.wait()
        log.write('\nObserved exit status: '+str(code)+'\n')
    results[version] = code
(evidence/'targeted-run-results.json').write_text(json.dumps(results, indent=2)+'\n')
print('Observed results: '+json.dumps(results), flush=True)
sys.exit(0 if results['baseline'] != 0 and results['target'] == 0 else 1)
