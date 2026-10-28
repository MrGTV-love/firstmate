#!/usr/bin/env python3
"""Bounded representative execution of the hsr check
'best-effort failure reporting was not fully bounded'
(tests/fm-home-summary-refresh.test.sh), with phase start stamps.

Usage: hsr-bound-phases.py TREE LABEL HOGS RUNS OUT_JSONL

Same inputs as the test: --best-effort writer, FM_TIMEOUT_MECHANISM_OVERRIDE=bash,
FM_HOME_SUMMARY_TIMEOUT=1, an env stub whose first call exits 143, the error log
path as a directory, and stderr on a full pipe. A registry file exists as
tests/lib.sh would export it. The env stub only adds a stamp line per call.
HOGS busy-loop children are started and killed by handle (no name-based kill).
Each run uses a fresh owned root under ~/tmp; it is removed only when empty of
live work (the writer has exited) - roots that fail to remove are kept.
"""
import json, os, shutil, subprocess, sys, tempfile, time

tree, label, hogs, runs, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
real_env = shutil.which('env')
HOG_KIND = os.environ.get('R7_HOG_KIND', 'cpu')
HOG = {'cpu': [sys.executable, '-c', 'while True: pass'],
       # fork/exec pressure like the teardown CLI's identity probes: ps and short shells
       'fork': ['/bin/bash', '-c', 'while :; do /bin/ps -o lstart= -p $$ >/dev/null 2>&1; /bin/sh -c : ; done'],
       # real product work: back-to-back summary refreshes of a private seeded home
       'refresh': ['/bin/bash', '-c', 'h=$(mktemp -d "$HOME/tmp/nm-r7-load.XXXXXX"); mkdir -p "$h/state" "$h/data" "$h/projects"; '
                   'printf "## In flight\\n\\n## Queued\\n\\n## Done\\n" > "$h/data/backlog.md"; echo load > "$h/.fm-secondmate-home"; '
                   'trap \'rm -rf "$h"\' EXIT; trap \'exit 0\' TERM; '
                   'while :; do env -u FM_TEST_PROCESS_REGISTRY FM_ROOT_OVERRIDE="$1" FM_HOME="$h" "$1/bin/fm-home-summary-refresh.sh" >/dev/null 2>&1; done', '_', tree]}[HOG_KIND]
hog_procs = [subprocess.Popen(HOG) for _ in range(hogs)]
try:
    time.sleep(1 if hogs else 0)
    for run in range(runs):
        root = tempfile.mkdtemp(prefix=f'nm-r7-hsr-{label}.', dir=os.path.expanduser('~/tmp'))
        home = os.path.join(root, 'home')
        os.makedirs(os.path.join(home, 'state', '.home-summary-refresh.log'))
        os.makedirs(os.path.join(home, 'data'))
        with open(os.path.join(home, '.fm-secondmate-home'), 'w') as f:
            f.write('bound-home\n')
        stubbin = os.path.join(root, 'stubbin'); os.makedirs(stubbin)
        stamps = os.path.join(root, 'stamps')
        marker = os.path.join(root, 'signal-marker')
        with open(os.path.join(stubbin, 'env'), 'w') as f:
            f.write('''#!/usr/bin/env bash
mode=worker
for a in "$@"; do case "$a" in --_*) mode=$a ;; esac; done
perl -MTime::HiRes=time -e 'printf "%.3f %s %s\\n", time, $ARGV[0], $ARGV[1]' -- "$mode" "$$" >> "$FM_R7_STAMPS"
if [ ! -e "$FM_TEST_SIGNAL_MARKER" ]; then
  : > "$FM_TEST_SIGNAL_MARKER"
  exit 143
fi
exec "$FM_TEST_REAL_ENV" "$@"
''')
        os.chmod(os.path.join(stubbin, 'env'), 0o755)
        registry = os.path.join(root, '.fm-test-process.registry')
        open(registry, 'w').close()
        env = dict(os.environ, PATH=f'{stubbin}:{os.environ["PATH"]}', FM_TEST_REAL_ENV=real_env,
                   FM_TEST_SIGNAL_MARKER=marker, FM_TIMEOUT_MECHANISM_OVERRIDE='bash',
                   FM_ROOT_OVERRIDE=tree, FM_HOME=home, FM_HOME_SUMMARY_TIMEOUT='1',
                   FM_R7_STAMPS=stamps, FM_TEST_PROCESS_REGISTRY=registry, TMPDIR=root)
        env.pop('FM_TEST_PROCESS_RECORD', None)
        read_fd, write_fd = os.pipe()
        os.set_blocking(write_fd, False)
        try:
            while True:
                os.write(write_fd, b'x' * 4096)
        except BlockingIOError:
            pass
        os.set_blocking(write_fd, True)
        started = time.time()
        proc = subprocess.Popen([os.path.join(tree, 'bin/fm-home-summary-refresh.sh'), '--best-effort'],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=write_fd, env=env)
        try:
            rc = proc.wait(timeout=60)  # observation bound only; the test's own is 21 s
        except subprocess.TimeoutExpired:
            proc.kill(); rc = proc.wait()
            rc = f'killed-after-60s({rc})'
        ended = time.time()
        os.close(write_fd); os.close(read_fd)
        time.sleep(1)
        phases = []
        if os.path.exists(stamps):
            for line in open(stamps):
                ts, mode, pid = line.split()
                phases.append({'mode': mode, 'at': round(float(ts) - started, 3)})
        row = {'label': label, 'hogs': hogs, 'hog_kind': HOG_KIND, 'run': run, 'rc': rc, 'elapsed': round(ended - started, 3),
               'phases': phases, 'root': root}
        try:
            shutil.rmtree(root)
            row['root_removed'] = True
        except OSError as error:
            row['root_removed'] = f'kept: {error}'
        with open(out, 'a') as f:
            f.write(json.dumps(row) + '\n')
        print(json.dumps(row), flush=True)
finally:
    for p in hog_procs:
        p.terminate() if HOG_KIND == 'refresh' else p.kill()
    for p in hog_procs:
        p.wait()
