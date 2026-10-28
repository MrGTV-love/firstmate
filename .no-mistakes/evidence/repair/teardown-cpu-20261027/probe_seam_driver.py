"""Drive tests/fm-teardown-cpu-probe.py through its internal run()/main() seam.
Usage: python3 probe_seam_driver.py <worktree> <fake-ps-dir>"""
import contextlib, importlib.util, io, json, math, os, subprocess, sys, time
wt, fakeps = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('probe', os.path.join(wt, 'tests', 'fm-teardown-cpu-probe.py'))
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)
real_load = probe.load_duration
MARK = 'mark(){ printf "%s\\n" "$1" >&"$FM_TEARDOWN_CPU_MARK_FD"; IFS= read -r a <&"$FM_TEARDOWN_CPU_ACK_FD"; }; '
results = []

def capture(cmd):
    buf = io.StringIO()
    t0 = time.monotonic()
    with contextlib.redirect_stdout(buf):
        code = probe.run(cmd)
    recs = [json.loads(l.split(' ', 1)[1]) for l in buf.getvalue().splitlines() if l.startswith('FM_TEARDOWN_CPU ')]
    return code, recs, time.monotonic() - t0

def check(name, ok, detail):
    results.append((name, ok)); print(('PASS' if ok else 'FAIL'), name, '::', detail)

class Fake:
    def __init__(self, fn): self.fn = fn
    def tree_cpu(self, pid, observed): return self.fn(pid, observed)

def with_fake(fn, cmd):
    probe.load_duration = lambda: Fake(fn)
    try: return capture(cmd)
    finally: probe.load_duration = real_load

cmd = ['bash', '-c', MARK + 'mark suite.start; mark c.start; mark c.end; exit 0']
def boundaries(recs): return [r for r in recs if r['event'] == 'boundary']

# 1. cpu=None from fake tree_cpu (observed empty) -> unavailable, not root_not_observed
code, recs, _ = with_fake(lambda p, o: (None, False), cmd)
b = boundaries(recs)
check('fake None -> cpu_telemetry_unavailable', code == 0 and len(b) == 3 and all(r['telemetry_error'] == 'cpu_telemetry_unavailable' and r['cpu_seconds'] is None for r in b),
      [(r['mark'], r['cpu_seconds'], r['telemetry_error']) for r in b])
iv = [r for r in recs if r['event'] == 'interval' and r['region'] == 'c']
check('unavailable case interval null+invalid', iv and iv[0]['cpu_seconds'] is None and iv[0]['valid'] is False and iv[0]['invalid_reason'] == 'missing_endpoint', iv)

# 2. Real tree_cpu with ps failing (EPERM text, rc 1) on PATH -> unavailable (real fm-duration code path)
old = os.environ['PATH']; os.environ['PATH'] = fakeps + os.pathsep + old
try:
    code, recs, _ = capture(cmd)
finally:
    os.environ['PATH'] = old
b = boundaries(recs)
check('real tree_cpu + failing ps -> cpu_telemetry_unavailable', code == 0 and b and all(r['telemetry_error'] == 'cpu_telemetry_unavailable' and r['cpu_seconds'] is None for r in b),
      [(r['mark'], r['cpu_seconds'], r['telemetry_error']) for r in b])

# 3. CPU present but root absent from observed -> root_not_observed, cpu nulled
def no_root(p, o): o[(p + 999999, ('x',))] = 1.5; return 1.5, False
code, recs, _ = with_fake(no_root, cmd)
b = boundaries(recs)
check('root missing -> root_not_observed', b and all(r['telemetry_error'] == 'root_not_observed' and r['cpu_seconds'] is None for r in b),
      [(r['mark'], r['cpu_seconds'], r['telemetry_error']) for r in b])

# 4. nan and negative with root observed -> nonfinite_or_negative_cpu
for label, val in (('nan', math.nan), ('inf', math.inf), ('negative', -1.0)):
    def bad(p, o, v=val): o[(p, ('x',))] = 0; return v, False
    code, recs, _ = with_fake(bad, cmd)
    b = boundaries(recs)
    check(f'{label} -> nonfinite_or_negative_cpu', b and all(r['telemetry_error'] == 'nonfinite_or_negative_cpu' and r['cpu_seconds'] is None for r in b),
          [(r['mark'], r['cpu_seconds'], r['telemetry_error']) for r in b])

# 5. exception -> type: message, row still emitted, run completes
def boom(p, o): raise RuntimeError('sampler broke')
code, recs, _ = with_fake(boom, cmd)
b = boundaries(recs)
check('exception -> error text, run completes', code == 0 and b and all(r['telemetry_error'] == 'RuntimeError: sampler broke' and r['cpu_seconds'] is None for r in b),
      [(r['mark'], r['telemetry_error']) for r in b])

# 6. Valid real telemetry still classified clean
code, recs, _ = capture(['bash', '-c', MARK + 'mark suite.start; mark c.start; i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done; mark c.end'])
b = boundaries(recs); iv = [r for r in recs if r['event'] == 'interval' and r['region'] == 'c']
check('real telemetry -> no error, positive case delta', all(r['telemetry_error'] is None and isinstance(r['cpu_seconds'], (int, float)) for r in b) and iv[0]['valid'] and iv[0]['cpu_seconds'] > 0,
      (iv[0]['cpu_seconds'], iv[0]['valid']))

# 7. Exact nonzero exit propagation
code, recs, _ = capture(['bash', '-c', MARK + 'mark suite.start; mark c.start; exit 7'])
ex = [r for r in recs if r['event'] == 'target_exit'][0]
inc = [r for r in recs if r['event'] == 'interval' and r.get('invalid_reason') == 'missing_end']
check('exit 7 propagated; open case reported missing_end', code == 7 and ex['returncode'] == 7 and inc and inc[0]['region'] == 'c', (code, ex, inc))

# 8. Descendant holding inherited mark/ack pipes does not block completion
code, recs, el = capture(['bash', '-c', MARK + 'mark suite.start; (sleep 30) & exit 0'])
ex = [r for r in recs if r['event'] == 'target_exit'][0]
check('background pipe holder does not block (<5s)', code == 0 and el < 5 and ex['pipe_eof_observed'] is False, (code, round(el, 2), ex))
subprocess.run(['pkill', '-f', '^sleep 30$'])

# 9. Signal death re-raised by main() (main's real re-raise path, child killed by SIGTERM)
drv = ("import importlib.util,sys;s=importlib.util.spec_from_file_location('p',sys.argv[1]);p=importlib.util.module_from_spec(s);"
       "s.loader.exec_module(p);r=p.run;p.run=lambda c:r(['bash','-c','kill -TERM $$']);sys.exit(p.main())")
pr = subprocess.run([sys.executable, '-c', drv, os.path.join(wt, 'tests', 'fm-teardown-cpu-probe.py')], capture_output=True, text=True)
tex = [json.loads(l.split(' ', 1)[1]) for l in pr.stdout.splitlines() if 'target_exit' in l]
check('SIGTERM child -> probe process dies by SIGTERM', pr.returncode == -15 and tex and tex[0]['returncode'] == -15, (pr.returncode, tex))

print('SUMMARY', sum(ok for _, ok in results), '/', len(results), 'passed')
sys.exit(0 if all(ok for _, ok in results) else 1)
