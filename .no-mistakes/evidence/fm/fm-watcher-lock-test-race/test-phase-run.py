#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

repo = Path('/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M5AKQ3DA9DCN4CJ5CF9EBF6S')
work = repo / '.no-mistakes/test-phase-watcher'
evidence = Path('/Users/charlesabrooker/.no-mistakes/evidence/01M5AKQ3DA9DCN4CJ5CF9EBF6S')
old = Path('/Users/charlesabrooker/fleet/fm-mini-home/data/fm-watcher-lock-test-race/evidence')
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(TMPDIR=str(work/'tmp'), FM_CPU_POOL_DIR=str(work/'cpu-pool'),
           FM_TEST_SLOT_DIR=str(work/'test-slots'), FM_DURATION_FILE='off')
mode = sys.argv[1]
if mode == 'stress':
    command = ['python3','bin/fm-duration.py','run','test.tests/fm-watcher-lock.test.sh','--',
               'bash','bin/fm-proc-budget.sh','--','python3',str(old/'stress.py'),str(repo),
               str(evidence/'after-one-shot-stress.txt'),'--iterations','40','--load','40','--schedule']
    filename = 'stress-launch.txt'
else:
    command = ['nice','-n','20','bash','bin/fm-test-run.sh','--jobs','1','tests/fm-watcher-lock.test.sh']
    filename = 'targeted-watcher-lock-isolated.txt'
    if mode == 'probe':
        env.update(FM_TEST_ONLY='test_stopped_watcher_is_live_but_stale_then_exit_is_classified',
                   FM_PROBE_LOG=str(evidence/'resume-before-term-product.jsonl'), FM_PROBE_BIN=str(work),
                   BASH_ENV=str(work/'probe-env.sh'), PATH=str(work)+os.pathsep+env['PATH'])
        filename = 'resume-before-term-runner.txt'
with (evidence/filename).open('w') as log:
    log.write('COMMAND: ' + ' '.join(command) + '\n')
    log.write('ISOLATION: worktree-local TMPDIR, CPU pool, test slots; no inherited FM_* overrides; timing persistence off\n')
    log.flush()
    result = subprocess.run(command, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT)
    log.write(f'COMMAND_EXIT={result.returncode}\n')
print(f'{mode} exit={result.returncode}; log={evidence/filename}', flush=True)
print((evidence/filename).read_text(), end='', flush=True)
if mode == 'probe' and result.returncode == 0:
    rows = [json.loads(line) for line in (evidence/'resume-before-term-product.jsonl').read_text().splitlines()]
    resumed = [r for r in rows if r['event'] == 'resumed-watcher-after-next-beacon']
    ledger = [r for r in rows if r['event'] == 'production-cycle-exit-ledger']
    assert resumed and all('T' not in r['process_state'] for r in resumed), rows
    assert ledger and all(r['grep_exit'] == 0 for r in ledger), rows
    print(json.dumps(rows, indent=2))
sys.exit(result.returncode)
