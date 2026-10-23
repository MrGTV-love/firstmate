import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

ROOT = Path.cwd()
EVIDENCE = Path('/Users/charlesabrooker/.no-mistakes/evidence/01M5N5Q8PNB502P4JC898857HN')
SCRATCH = ROOT / '.gate-test-scratch'
EVIDENCE.mkdir(parents=True, exist_ok=True)
SCRATCH.mkdir(exist_ok=True)
ENV = os.environ.copy()
for key in ('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_DURATION_HOME', 'FM_DURATION_CALIBRATION_FILE'):
    ENV.pop(key, None)
ENV.update(FM_DURATION_FILE='off', FM_TEST_SLOT_DIR=str(SCRATCH / 'slots'), FM_CPU_POOL_DIR=str(SCRATCH / 'cpu-pool'), TMPDIR=str(SCRATCH))
DURATION = '/Users/charlesabrooker/fleet/fm-mini-home/bin/fm-duration.py'
BUDGET = '/Users/charlesabrooker/fleet/fm-mini-home/bin/fm-proc-budget.sh'

def run(command, log):
    log.write('$ ' + shlex.join(command) + '\n')
    log.write('environment: FM_DURATION_FILE=off; FM_TEST_SLOT_DIR, FM_CPU_POOL_DIR, TMPDIR isolated inside worktree; fleet path overrides removed\n')
    log.flush()
    start = time.monotonic()
    process = subprocess.Popen(command, cwd=ROOT, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        print(line, end='', flush=True)
        log.write(line)
        log.flush()
    code = process.wait()
    log.write(f'COMMAND_EXIT={code}; elapsed_seconds={time.monotonic() - start:.3f}\n')
    log.flush()
    return code

if sys.argv[1] == 'suite':
    command = ['python3', DURATION, 'run', 'test.tests/fm-pi-watch-extension.test.sh', '--', 'nice', '-n', '20', 'bash', 'bin/fm-test-run.sh', '--jobs', '1', 'tests/fm-pi-watch-extension.test.sh']
    with (EVIDENCE / 'targeted-serial-suite.txt').open('w') as log:
        log.write('Current target commit: 9bd991e33e050c0bf9ccffefc06f85f4f3b54e8a\nOnly the targeted file is selected; no other tests run concurrently by this driver.\n')
        sys.exit(run(command, log))

if sys.argv[1] == 'regression':
    import json
    import signal
    source = (ROOT / 'tests/fm-pi-watch-extension.test.sh').read_text()
    function = source.split('test_opencode_healthy_arm_output_does_not_suppress_guard() {', 1)[1].split('\n\ntest_watch_instance_rebind_releases_predecessors()', 1)[0]
    function = 'test_opencode_healthy_arm_output_does_not_suppress_guard() {' + function
    fixture_start = "  cat > \"$repo/bin/fm-turnend-guard.sh\" <<'SH'\n"
    fixture = function.split(fixture_start, 1)[1].split('\nSH\n', 1)[0]
    old_fixture = """#!/usr/bin/env bash
printf 'guard\\n' >> "${FM_GUARD_LOG:?}"
printf 'guard ran after external healthy watcher\\n' >&2
exit 2"""
    old = function.replace(fixture, old_fixture, 1)
    allowed = function.replace(fixture, fixture.replace('exit 2', 'exit 0'), 1)
    header = '#!/usr/bin/env bash\nset -u\n. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"\nexport NODE_NO_WARNINGS=1\nBASE=$(fm_test_tmproot fm-guard-regression)\n'
    def script(body, cases, expected):
        result = header + body + '\n'
        result += 'failures=0\n'
        for mode, count in cases:
            result += f'for attempt in $(seq 1 {count}); do\n'
            result += f'  TMP_ROOT="$BASE/{mode}-$attempt"\n  mkdir -p "$TMP_ROOT"\n'
            result += f'  output=$( (test_opencode_healthy_arm_output_does_not_suppress_guard {mode}) 2>&1)\n'
            result += '  status=$?\n'
            result += f'  printf "CASE mode={mode} attempt=%s exit=%s\\n%s\\n" "$attempt" "$status" "$output"\n'
            if expected == 'epipe':
                result += '  if [ "$status" -eq 0 ] || [[ "$output" != *"write EPIPE"* ]] || [[ "$output" != *"Unhandled"* ]]; then failures=$((failures + 1)); fi\n'
            elif expected == 'blocked':
                result += '  if [ "$status" -eq 0 ] || [[ "$output" != *"missing blind-turn prompt"* ]]; then failures=$((failures + 1)); fi\n'
            else:
                result += '  if [ "$status" -ne 0 ]; then failures=$((failures + 1)); fi\n'
            result += 'done\n'
        result += 'printf "Unexpected outcomes=%s\\n" "$failures"\n[ "$failures" -eq 0 ]\n'
        return result
    variants = [
        ('old-nondraining', script(old, [('delayed', 5)], 'epipe')),
        ('drained', script(function, [('delayed', 60), ('immediate', 60)], 'pass')),
        ('adversarial-exit0', script(allowed, [('immediate', 1), ('delayed', 1)], 'blocked')),
    ]
    workers = []
    scripts = []
    total_code = 0
    with (EVIDENCE / 'synchronized-regression.txt').open('w') as log:
        log.write('Test-only fixture validation, NOT live product evidence. No historical CI attribution.\n')
        log.write('Old fixture restored byte-for-byte to original log/stderr/exit-2 stub, without cat, EXIT trap, or explicit fd-3 close. FIFO parent hook retained; no artificial EPIPE injected.\n')
        log.write('Fixed case uses the complete committed test function unchanged. Adversarial case changes only fixture exit 2 to exit 0.\n')
        log.write('Controlled load: two CPU workers at nice 20; all tests run serially, one runner at a time at nice 20.\n')
        log.write(f'load_start={os.getloadavg()}; logical_cpus={os.cpu_count()}\n')
        try:
            for _ in range(2):
                workers.append(subprocess.Popen(['nice', '-n', '20', 'python3', '-c', 'import hashlib\nwhile True: hashlib.sha256(b"x" * 65536).digest()'], env=ENV))
            for name, content in variants:
                path = ROOT / 'tests' / f'.gate-{name}.test.sh'
                path.write_text(content)
                scripts.append(path)
                (EVIDENCE / f'{name}-driver.sh').write_text(content)
                log.write(f'\nVARIANT {name}; load={os.getloadavg()}\n')
                command = ['python3', DURATION, 'run', f'test.guard-regression.{name}', '--', 'nice', '-n', '20', 'bash', 'bin/fm-test-run.sh', '--jobs', '1', str(path.relative_to(ROOT))]
                code = run(command, log)
                total_code = total_code or code
        finally:
            for worker in workers:
                worker.terminate()
            for worker in workers:
                worker.wait()
            for path in scripts:
                path.unlink()
            log.write(f'load_end={os.getloadavg()}; all load workers stopped and disposable test scripts removed\n')
    (EVIDENCE / 'validation-driver.py').write_text(Path(__file__).read_text())
    sys.exit(total_code)
