import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
mode = sys.argv[2] if len(sys.argv) > 2 else 'after'
base_commit = sys.argv[3] if len(sys.argv) > 3 and not sys.argv[3].startswith('--') else ''
unproved_only = '--unproved-only' in sys.argv[3:]
script = Path(__file__).with_suffix('.mjs')

def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, text=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='fm-write-gate-smoke-') as tmp:
    base = Path(tmp).resolve()
    env = {key: value for key, value in os.environ.items() if key not in
           ('TYPESAFE_API_KEY', 'TYPESAFE_API_KEY_PRIVATE', 'OPENROUTER_API_KEY', 'FM_GUARD_EVENT_LOG', 'FM_JEV_GUARD_BASE_URL')}
    env.update(HOME=str(base / 'user'), OMP_PROFILE='', PI_PROFILE='', PI_CONFIG_DIR='.omp',
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', FM_WRITE_CONFINEMENT='seatbelt-v1')
    (base / 'user').mkdir()
    primary, worktree, home = base / 'primary', base / 'worker', base / 'home'
    for name in ('state', 'config', 'projects', 'data/smoke'):
        (home / name).mkdir(parents=True)
    (home / 'state/smoke.meta').write_text('egress=["semantic-search","web","browser","provider","remote-storage"]\n')
    (home / 'config/protected').write_text('original')
    run(['git', 'init', '-q', primary], env=env)
    run(['git', '-C', primary, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture', '--allow-empty'], env=env)
    # Only a throwaway fixture repository, never a fleet pool or task copy.
    run(['git', '-C', primary, 'worktree', 'add', '-qb', 'fm/smoke', worktree], env=env, stdout=subprocess.DEVNULL)
    guard_dir = root / 'bin'
    if mode == 'before':
        guard_dir = base / 'baseline'
        guard_dir.mkdir()
        for name in ('fm-jev-guard.ts', 'fm-jev-guard-claude.ts'):
            source = subprocess.check_output(['git', '-C', str(root), 'show', f'{base_commit}:bin/{name}'], text=True)
            (guard_dir / name).write_text(source)
        for name in ('ten-levels', 'fm-jev-egress.ts', 'fm-guard-event.sh'):
            (guard_dir / name).symlink_to(root / 'bin' / name)
    print('root=' + str(root), flush=True)
    print('head=' + subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(), flush=True)
    for host in ('omp', 'claude'):
        profile = base / f'{host}.sb'
        run(['python3', root / 'bin/fm-write-confinement.py', '--worktree', worktree, '--home', home,
             '--config', home / 'config', '--projects', home / 'projects', '--data', home / 'data/smoke', '--state', home / 'state',
             '--task', 'smoke', '--harness', host, '--profile', profile, '--branch', 'fm/smoke', '--agent-dir', base / 'agent',
             *(['--claude-session', '11111111-2222-4333-8444-555555555555'] if host == 'claude' else [])], env=env)
        # Negative-only execution inherits the current boundary unchanged: its
        # synthetic metadata is writable, so it cannot prove T5 confinement.
        for confinement in (('unconfined',) if unproved_only else ('unconfined', 'confined')):
            command = ['node', '--experimental-strip-types', '--no-warnings', script, root, guard_dir, home, worktree, host, confinement, mode]
            if confinement == 'confined':
                command = ['/usr/bin/sandbox-exec', '-f', profile, *command]
            run(command, env=env)
