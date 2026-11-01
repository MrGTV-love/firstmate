# Test-step adversarial probe. Builds a throwaway fixture home + git worktree,
# builds the real seatbelt profile with bin/fm-write-confinement.py from ROOT,
# then runs probe.mjs (the real installJevGuard hook / Claude adapter) in four
# confinement modes. Nothing outside a TemporaryDirectory is written.
import os, subprocess, sys, tempfile
from pathlib import Path
root = Path(sys.argv[1]).resolve()
script = Path(__file__).with_name('probe.mjs')
def run(args, **kw): return subprocess.run([str(a) for a in args], check=True, text=True, **kw)
with tempfile.TemporaryDirectory(prefix='fm-write-gate-probe-') as tmp:
    base = Path(tmp).resolve()
    env = {k: v for k, v in os.environ.items() if k not in ('TYPESAFE_API_KEY', 'TYPESAFE_API_KEY_PRIVATE', 'OPENROUTER_API_KEY', 'FM_GUARD_EVENT_LOG', 'FM_JEV_GUARD_BASE_URL', 'NO_MISTAKES_GATE')}
    env.update(HOME=str(base / 'user'), OMP_PROFILE='', PI_PROFILE='', PI_CONFIG_DIR='.omp', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
    (base / 'user').mkdir()
    primary, worktree, home = base / 'primary', base / 'worker', base / 'home'
    for name in ('state', 'config', 'projects', 'data/smoke'): (home / name).mkdir(parents=True)
    (home / 'state/smoke.meta').write_text('egress=["semantic-search","web","browser","provider","remote-storage"]\n')
    (home / 'config/protected').write_text('original')
    run(['git', 'init', '-q', primary], env=env)
    run(['git', '-C', primary, '-c', 'user.name=F', '-c', 'user.email=f@example.invalid', 'commit', '-qm', 'f', '--allow-empty'], env=env)
    run(['git', '-C', primary, 'worktree', 'add', '-qb', 'fm/smoke', worktree], env=env, stdout=subprocess.DEVNULL)
    print('root=' + str(root)); print('head=' + subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(), flush=True)
    permissive = base / 'permissive.sb'; permissive.write_text('(version 1)\n(allow default)\n')
    for host in ('omp', 'claude'):
        profile = base / f'{host}.sb'
        run(['python3', root / 'bin/fm-write-confinement.py', '--worktree', worktree, '--home', home, '--config', home / 'config', '--projects', home / 'projects',
             '--data', home / 'data/smoke', '--state', home / 'state', '--task', 'smoke', '--harness', host, '--profile', profile, '--branch', 'fm/smoke',
             '--agent-dir', base / 'agent', *(['--claude-session', '11111111-2222-4333-8444-555555555555'] if host == 'claude' else [])], env=env)
        for mode, sandbox, marker in (('confined', profile, True), ('unconfined', None, True), ('confined-no-marker', profile, False), ('permissive-sandbox', permissive, True)):
            e = dict(env, FM_GUARD_EVENT_LOG=str(base / f'events-{host}-{mode}.jsonl'))
            if marker: e['FM_WRITE_CONFINEMENT'] = 'seatbelt-v1'
            cmd = ['node', '--experimental-strip-types', '--no-warnings', script, root, home, worktree, host, mode]
            if sandbox: cmd = ['/usr/bin/sandbox-exec', '-f', sandbox, *cmd]
            run(cmd, env=e)
