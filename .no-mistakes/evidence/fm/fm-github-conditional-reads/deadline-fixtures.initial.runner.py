#!/usr/bin/env python3
import json, os, shutil, subprocess, sys, time
from pathlib import Path
root, world, evidence = map(Path, sys.argv[1:])
source = (root / 'tests/fm-open-loops.test.sh').read_text().splitlines(keepends=True)
code, home = world / 'code', world / 'empty-home'
shutil.copytree(root / 'bin', code / 'bin')
home.mkdir()
(world / 'tmp').mkdir()
env = dict(PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(home),
           TMPDIR=str(world / 'tmp'), LANG='en_US.UTF-8', FM_HOME=str(home),
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
PR_URL = 'https://github.com/test/project/pull/'
helpers = ''.join(source[30:37] + source[39:42] + source[44:46] + source[116:121])
exec(compile(helpers, str(root / 'tests/fm-open-loops.test.sh') + ':minimal-helpers', 'exec'))
original_run = run
calls = []
def run(args, **kw):
    done = original_run(args, **kw)
    reader = kw.get('env', env).get('DEADLINE_READER', 'unknown')
    record = dict(reader=reader, command=[str(a) for a in args], returncode=done.returncode,
                  stdout=done.stdout, stderr=done.stderr)
    calls.append(record)
    (evidence / ('deadline-' + reader + '.fixture.stdout.json')).write_text(done.stdout)
    (evidence / ('deadline-' + reader + '.fixture.stderr.log')).write_text(done.stderr)
    return done
block = ''.join(source[1114:1189])
(evidence / 'deadline-fixtures.extracted-block.py').write_text(block)
try:
    exec(compile(block, str(root / 'tests/fm-open-loops.test.sh') + ':1115-1189', 'exec'))
finally:
    (evidence / 'deadline-fixtures.calls.json').write_text(json.dumps(calls, indent=2) + '\n')
    for reader in ('origins', 'pr-checks', 'pr-state', 'questions'):
        reader_home = world / ('deadline-' + reader) / 'home'
        capture = dict(kind='supplemental fixture deadline regression (not live)', reader=reader)
        for key, name in [('attempts', 'attempts'), ('trigger', 'deadline-trigger'), ('degraded_report', 'state/open-loops.json')]:
            path = reader_home / name
            if path.exists():
                capture[key] = ([json.loads(line) for line in path.read_text().splitlines()]
                                if key == 'attempts' else json.loads(path.read_text()))
        (evidence / ('deadline-' + reader + '.fixture.evidence.json')).write_text(json.dumps(capture, indent=2) + '\n')
        print(json.dumps(capture, sort_keys=True), flush=True)
