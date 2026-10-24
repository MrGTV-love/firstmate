#!/usr/bin/env python3
"""Drive the real progress runners (fm-duration.py keep-going and the Python-free
Perl fm_run_progress) against real process trees and print one JSON line per run.

Usage: live-cli.py REPO [--load N] [--reps N] [--duration PATH] [--only NAMES]
REPO is the checkout whose bin/ is exercised. --duration swaps in another
fm-duration.py (e.g. the base commit's) for a before/after comparison.
"""
import argparse, json, os, platform, shutil, subprocess, sys, tempfile, time

p = argparse.ArgumentParser()
p.add_argument('repo')
p.add_argument('--load', type=int, default=0)
p.add_argument('--reps', type=int, default=1)
p.add_argument('--duration')
p.add_argument('--only', default='')
p.add_argument('--runners', default='python,perl')
p.add_argument('--nice', type=int, default=0)
p.add_argument('--hide-proc', action='store_true', help='force the ps sampler')
args = p.parse_args()

PY = sys.executable
SLEEP = shutil.which('sleep')
BUSY = ('import time\nuntil = time.monotonic() + 4\n'
        'while time.monotonic() < until:\n    sum(i*i for i in range(1000))\n')
PROGRAMS = {
    # The original flake shape: a 4 s CPU child, reaped, then a short completion phase.
    'burst': ['bash', '-c', f'"$1" -c "$2" && {SLEEP} 0.5 && echo completed', '_', PY, BUSY],
    # Timed-poll idle: tiny timer wakeups only.
    'poll': [PY, '-c', 'import time\nwhile True: time.sleep(0.05)'],
    # Fully idle.
    'sleep': [SLEEP, '120'],
    # A loop that keeps spawning short sleeping children (classification only).
    'spawnloop': ['bash', '-c', f'while :; do {SLEEP} 0.2; done'],
}
EXPECT = {'burst': 0, 'poll': 124, 'sleep': 124, 'spawnloop': None}
names = [n for n in PROGRAMS if not args.only or n in args.only.split(',')]

tmp = tempfile.mkdtemp(prefix='fm-live-cli.')
home = os.path.join(tmp, 'repo')
shutil.copytree(os.path.join(args.repo, 'bin'), os.path.join(home, 'bin'), symlinks=True)
if args.duration:
    shutil.copy(args.duration, os.path.join(home, 'bin/fm-duration.py'))
tools = os.path.join(tmp, 'no-python')
os.mkdir(tools)
for tool in ('bash', 'perl', 'ps', 'dirname', 'sleep'):
    os.symlink(shutil.which(tool), os.path.join(tools, tool))

load = [subprocess.Popen([PY, '-c', 'while True: pass']) for _ in range(args.load)]
print(json.dumps({'host': platform.platform(), 'python': platform.python_version(),
                  'load_workers': args.load, 'nice': args.nice, 'hide_proc': args.hide_proc, 'loadavg_start': os.getloadavg(),
                  'duration_override': args.duration}), flush=True)
try:
    for rep in range(args.reps):
        for runner in args.runners.split(','):
            for name in names:
                env = dict(os.environ)
                for key in ('FM_PROC_ROOT_OVERRIDE',):
                    env.pop(key, None)
                if args.hide_proc:
                    env['FM_PROC_ROOT_OVERRIDE'] = os.path.join(tmp, 'no-proc')
                if runner == 'python':
                    cmd = [PY, os.path.join(home, 'bin/fm-duration.py'), 'keep-going', '1', '--', *PROGRAMS[name]]
                else:
                    env['PATH'] = tools
                    cmd = ['bash', '-c', '. "$1"; shift; command -v python3 && exit 99; fm_run_progress 1 "$@"',
                           '_', os.path.join(home, 'bin/fm-timeout-lib.sh'), *PROGRAMS[name]]
                if args.nice:
                    cmd = [shutil.which('nice'), '-n', str(args.nice), *cmd]
                start = time.monotonic()
                child = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         text=True, start_new_session=True)
                try:
                    out, err = child.communicate(timeout=25)
                    rc = child.returncode
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, 9)
                    out, err = child.communicate()
                    rc = 'outer-timeout-25s'
                elapsed = round(time.monotonic() - start, 2)
                expected = EXPECT[name]
                verdict = 'info' if expected is None else ('pass' if rc == expected and
                          (name != 'burst' or out == 'completed\n') else 'FAIL')
                print(json.dumps({'rep': rep, 'runner': runner, 'case': name, 'rc': rc, 'expected': expected,
                                  'verdict': verdict, 'elapsed_s': elapsed, 'stdout': out[-200:],
                                  'stderr': err[-300:], 'loadavg': os.getloadavg()}), flush=True)
finally:
    for w in load:
        w.kill()
    shutil.rmtree(tmp, ignore_errors=True)
