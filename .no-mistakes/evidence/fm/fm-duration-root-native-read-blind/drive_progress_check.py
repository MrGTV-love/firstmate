"""Drive the real fm-duration.py progress-check against a real process tree.

Usage: python3 -I drive_progress_check.py DURATION_PY MODE WORKLOAD SAMPLES RECORD
MODE: none     - real ps + real Darwin native reads, no fault
      root     - real native reads, except the ROOT pid read returns None (as EPERM does)
      nonroot  - real native reads for the root, None for every non-root member
WORKLOAD: reaped - root bash loop runs ~0.3 s CPU children, reaps them, sleeps 0.9 s
          live   - root bash runs one long-lived CPU-burning child
          idle   - root bash only sleeps
          pyreaped - root python runs ~0.25 s CPU children, reaps each, then sleeps
                     0.35 s in-process (no child alive during the sleep)
Prints one line per progress-check call: exit code and stderr.
"""
import contextlib
import importlib.util
import io
import subprocess
import sys
import time

path, mode, workload, samples, record = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
spec = importlib.util.spec_from_file_location('fm_duration_live', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

burn = "python3 -c 'import time\nt=time.time()\nwhile time.time()-t<{}: pass'"
scripts = {
    'reaped': 'while :; do ' + burn.format(0.3) + '; sleep 0.9; done',
    'live': burn.format(600),
    'idle': 'sleep 600',
}
# bash -c with a compound command stays the root; it forks and waits for children.
if workload == 'pyreaped':
    loop = ('import subprocess, sys, time\n'
            'while True:\n'
            '    subprocess.run([sys.executable, "-c", "import time\\nt=time.time()\\nwhile time.time()-t<0.25: pass"])\n'
            '    time.sleep(0.35)\n')
    root = subprocess.Popen([sys.executable, '-c', loop])
else:
    root = subprocess.Popen(['bash', '-c', scripts[workload] + '; :'])
real = module.darwin_cpu_reader()


def faulty(pid):
    if mode == 'root' and pid == root.pid:
        return None
    if mode == 'nonroot' and pid != root.pid:
        return None
    return real(pid)


module.darwin_cpu_reader = lambda: faulty
stops = 0
try:
    time.sleep(0.5)
    for index in range(samples):
        errors = io.StringIO()
        sys.argv = ['fm-duration.py', 'progress-check', record, str(root.pid), '1']
        with contextlib.redirect_stderr(errors):
            code = module.main()
        stops += code == 124
        print(f'sample {index + 1}: exit={code} stderr={errors.getvalue().strip() or "<none>"}', flush=True)
        time.sleep(1.2)
finally:
    subprocess.run(['pkill', '-TERM', '-P', str(root.pid)])
    root.terminate()
    root.wait()
print(f'SUMMARY mode={mode} workload={workload} samples={samples} false_or_true_stops(124)={stops}')
