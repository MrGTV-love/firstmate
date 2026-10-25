"""Bounded live reproduction of the pyenv-prefix/pyenv-which recursion.

Runs the real installed pyenv shim (python3 on PATH) and pyenv-prefix with the
exclusion-fixture BASH_ENV hook taken verbatim from the base commit (old) and
the target commit (new). Safety (G1): every case runs in a new session with a
hard RLIMIT_NPROC of user baseline + 150, inside bin/fm-proc-budget.sh 80, with
a Bash-entry depth fuse of 25 and a 12 s watchdog; the exact process group is
SIGKILLed and reaped on every path.
Usage: python3 -I bounded_pyenv_repro.py <worktree> <outdir>
"""
import json, os, pathlib, resource, signal, subprocess, sys, time

WT = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(sys.argv[2])
BASE, TARGET = '2f6bb0a21e1749c80f1ccb4c02b867e92f0418c5', '82886e4907e8d68c1bcae545abb845595bb87ffa'
PREFIX = '/opt/homebrew/Cellar/pyenv/2.6.6/libexec/pyenv-prefix'
FUSE = 25


def hook_from(commit):
    text = subprocess.check_output(['git', '-C', str(WT), 'show', f'{commit}:tests/fm-spawn-dispatch-profile.test.sh'], text=True)
    start = text.index('test_pi_exclude_tools_read_failure_refuses_before_launch() {')
    start = text.index('cat > "$bash_env" <<\'SH\'\n', start) + len('cat > "$bash_env" <<\'SH\'\n')
    return text[start:text.index('\nSH\n', start) + 1]


fuse = ('FM_REPRO_DEPTH=$(( ${FM_REPRO_DEPTH:-0} + 1 )); export FM_REPRO_DEPTH\n'
        'printf \'depth=%s cmd=%s\\n\' "$FM_REPRO_DEPTH" "$(/bin/ps -o args= -p $$)" >> "$FM_REPRO_LOG"\n'
        f'if builtin [ "$FM_REPRO_DEPTH" -gt {FUSE} ]; then exit 98; fi\n')
hooks = {}
for name, commit in (('old', BASE), ('new', TARGET)):
    body = hook_from(commit)
    (OUT / f'hook-{name}.verbatim.bash').write_text(body)
    hooks[name] = OUT / f'hook-{name}.fused.bash'
    hooks[name].write_text(fuse + body)
# Counting-only hook for the no-exclusion-hook control.
hooks['none'] = OUT / 'hook-none.fused.bash'
hooks['none'].write_text(fuse)

baseline = len(subprocess.check_output(['/bin/ps', '-U', str(os.getuid()), '-o', 'pid=']).splitlines())
cap = min(baseline + 150, resource.getrlimit(resource.RLIMIT_NPROC)[0])

def constrain():
    resource.setrlimit(resource.RLIMIT_NPROC, (cap, cap))

route = ['python3', str(WT / 'bin/fm-dsh.py'), 'route', 'deepseek/test-model']
cases = [
    ('shim-route-old-hook', route, 'old'),
    ('shim-route-new-hook', route, 'new'),
    ('shim-route-no-hook', route, 'none'),
    ('pyenv-prefix-old-hook', [PREFIX, '3.13.6'], 'old'),
    ('pyenv-prefix-new-hook', [PREFIX, '3.13.6'], 'new'),
]
results = []
for name, argv, hook in cases:
    log = OUT / f'{name}.depth.log'
    log.write_text('')
    env = dict(os.environ, FM_REPRO_LOG=str(log), BASH_ENV=str(hooks[hook]))
    env.pop('PYENV_VERSION', None)
    # The driver itself runs under `pyenv exec`, which prepends the version bin
    # dir; drop it so python3 resolves to the real shim as in the incident.
    env['PATH'] = ':'.join(d for d in env['PATH'].split(':') if '/.pyenv/versions/' not in d)
    if argv[0] == PREFIX:
        # pyenv's front end puts its libexec first before running subcommands.
        env['PATH'] = os.path.dirname(PREFIX) + ':' + env['PATH']
    outf = OUT / f'{name}.out'
    with outf.open('w') as output:
        p = subprocess.Popen([str(WT / 'bin/fm-proc-budget.sh'), '80', '--', *argv], env=env,
                             stdout=output, stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=constrain)
        peak, watchdog = 0, False
        try:
            until = time.monotonic() + 12
            while p.poll() is None and time.monotonic() < until:
                rows = {}
                for row in subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid='], text=True).splitlines():
                    a = row.split()
                    if len(a) == 2:
                        rows[int(a[0])] = int(a[1])
                tree = {p.pid}
                while True:
                    grown = tree | {pid for pid, ppid in rows.items() if ppid in tree}
                    if grown == tree:
                        break
                    tree = grown
                peak = max(peak, len(tree))
                time.sleep(0.02)
            watchdog = p.poll() is None
        finally:
            for sig in (signal.SIGSTOP, signal.SIGKILL):
                try:
                    os.killpg(p.pid, sig)
                except ProcessLookupError:
                    pass
            p.wait()
    entries = log.read_text().splitlines()
    depths = [int(l.split('depth=')[1].split()[0]) for l in entries if 'depth=' in l]
    results.append(dict(
        case=name, argv=argv, hook=hook, hard_nproc_cap=cap, user_baseline=baseline,
        returncode=p.returncode, watchdog_fired=watchdog, sampled_peak_tree=peak,
        bash_entries=len(entries), max_bash_depth=max(depths, default=0), fuse_reached=any(d > FUSE for d in depths),
        pyenv_prefix_entries=sum('pyenv-prefix' in l for l in entries),
        pyenv_which_entries=sum('pyenv-which' in l for l in entries),
        path_head=env['PATH'].split(':')[:3], output=outf.read_text()[-600:]))
    print(json.dumps(results[-1]))
(OUT / 'bounded-pyenv-results.json').write_text(json.dumps(results, indent=2))
