"""Run one command under a hard process cap and watch its tree for pyenv cycles.

Safety (G1): new session, hard RLIMIT_NPROC = user baseline + <extra>, the
repository's bin/fm-proc-budget.sh, a watchdog, and an exact-group SIGKILL on
every path. Records the sampled peak tree and the largest number of live
pyenv-prefix/pyenv-which Bash processes seen inside the tree.
Usage: python3 -I capped_run.py <worktree> <label> <extra> <timeout-s> <out.json> -- <cmd...>
"""
import json, os, resource, signal, subprocess, sys, time

wt, label, extra, timeout, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
cmd = sys.argv[sys.argv.index('--') + 1:]
env = dict(os.environ)
for k in ('BASH_ENV', 'PYENV_VERSION'):
    env.pop(k, None)
env['PATH'] = ':'.join(d for d in env['PATH'].split(':') if '/.pyenv/versions/' not in d)
if os.environ.get('CAPPED_DROP_PYENV') == '1':
    env['PATH'] = ':'.join(d for d in env['PATH'].split(':') if '.pyenv' not in d and 'Cellar/pyenv' not in d)
baseline = len(subprocess.check_output(['/bin/ps', '-U', str(os.getuid()), '-o', 'pid=']).splitlines())
cap = min(baseline + extra, resource.getrlimit(resource.RLIMIT_NPROC)[0])

def constrain():
    resource.setrlimit(resource.RLIMIT_NPROC, (cap, cap))

logf = out[:-5] + '.log'
start = time.monotonic()
with open(logf, 'w') as log:
    p = subprocess.Popen([os.path.join(wt, 'bin/fm-proc-budget.sh'), str(extra), '--', *cmd], cwd=wt, env=env,
                         stdout=log, stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=constrain)
    peak = peak_pyenv = 0
    pyenv_cmds = set()
    try:
        until = time.monotonic() + timeout
        while p.poll() is None and time.monotonic() < until:
            rows = {}
            for row in subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,args='], text=True).splitlines():
                a = row.split(None, 2)
                if len(a) == 3:
                    rows[int(a[0])] = (int(a[1]), a[2])
            tree = {p.pid}
            while True:
                grown = tree | {pid for pid, (ppid, _) in rows.items() if ppid in tree}
                if grown == tree:
                    break
                tree = grown
            live = [rows[x][1] for x in tree if x in rows and any(
                w.endswith(('/pyenv-prefix', '/pyenv-which')) for w in rows[x][1].split()[:2])]
            pyenv_cmds.update(live)
            peak, peak_pyenv = max(peak, len(tree)), max(peak_pyenv, len(live))
            time.sleep(0.05)
        watchdog = p.poll() is None
    finally:
        for sig in (signal.SIGSTOP, signal.SIGKILL):
            try:
                os.killpg(p.pid, sig)
            except ProcessLookupError:
                pass
        p.wait()
res = dict(label=label, cmd=cmd, hard_nproc_cap=cap, user_baseline=baseline, budget_extra=extra,
           returncode=p.returncode, watchdog_fired=watchdog, seconds=round(time.monotonic() - start, 1),
           sampled_peak_tree=peak, max_live_pyenv_prefix_or_which=peak_pyenv,
           pyenv_commands_seen=sorted(pyenv_cmds)[:20], python3_on_path=subprocess.run(
               ['/usr/bin/which', 'python3'], env=env, capture_output=True, text=True).stdout.strip(), log=logf)
open(out, 'w').write(json.dumps(res, indent=2))
print(json.dumps(res))
