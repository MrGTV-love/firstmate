#!/usr/bin/env bash
# Flag real diff weakening cases through the detector's public CLI.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot test-weakening)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

root, temp = map(Path, sys.argv[1:])
repo = temp / 'repo'
repo.mkdir()
detector = root / 'bin/fm-test-weakening.py'

def call(*args, expected=0):
    result = subprocess.run(list(map(str, args)), text=True, capture_output=True)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout

def git(*args):
    return call('git', '-C', repo, *args).strip()

def put(path, text):
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)

git('init', '-q')
git('config', 'user.email', 'test@example.invalid')
git('config', 'user.name', 'test')
put('tests/subject.test.sh', '# comment\nassert_equal yes "$actual"\ntest_it() {\n  run_subject\n}\n')
put('fixtures/rows.csv', 'name,result\nfirst,pass\nsecond,fail\n')
put('bin/policy.py', 'timeout = 4\nretries = 2\nfor step in range(3):\n    check(step)\n')
put('src/guard.py', 'assert result == expected\n')
put('fixtures/space rows.csv', 'name\n-- row\n')
put('bin/loop.py', 'N = 4\n')
git('add', '.')
git('commit', '-qm', 'initial checks')
base = git('rev-parse', 'HEAD')

def inspect(name, expected):
    git('add', '.')
    git('commit', '-qm', name)
    head = git('rev-parse', 'HEAD')
    output = temp / (name + '.json')
    stdout = call(sys.executable, detector, '--repo', repo, '--base', base,
                  '--head', head, '--output', output, expected=expected)
    record = json.loads(output.read_text())
    assert record['base'] == base and record['head'] == head
    for flag in record['flags']:
        assert flag['file'] + ':' + str(flag['line']) in stdout
        assert len(flag['id']) == 64 and flag['id'] in stdout
    return record['flags']

put('tests/subject.test.sh', '# comment\n')
put('fixtures/rows.csv', 'name,result\nfirst,pass\n')
put('bin/policy.py', 'timeout = 8\nretries = 5\nfor step in range(9):\n    check(step)\n')
put('src/guard.py', '# removed\n')
put('fixtures/space rows.csv', 'name\n')
put('bin/loop.py', 'N = 8\n')
flags = inspect('weakening', 1)
assert any(f['file'] == 'fixtures/space rows.csv' and f['line'] == 2 for f in flags)
assert any(f['file'] == 'bin/loop.py' and f['line'] == 1 for f in flags)
assert any(f['file'] == 'tests/subject.test.sh' and f['line'] == 2 for f in flags)
assert any(f['file'] == 'tests/subject.test.sh' and f['line'] == 3 for f in flags)
assert any(f['file'] == 'fixtures/rows.csv' and f['line'] == 3 for f in flags)
assert any(f['file'] == 'src/guard.py' for f in flags)
for line in (1, 2, 3):
    assert any(f['file'] == 'bin/policy.py' and f['line'] == line and f['reason'] == 'increased time/retry/iteration bound' for f in flags)
assert len({f['id'] for f in flags}) == len(flags)
print('ok - assertion, test body, fixture row and raised time/retry/iteration bounds name exact lines')

# Restore committed base content without modifying unrelated work.
for path in ('tests/subject.test.sh', 'fixtures/rows.csv', 'fixtures/space rows.csv', 'bin/policy.py', 'bin/loop.py', 'src/guard.py'):
    put(path, git('show', base + ':' + path) + '\n')
put('tests/addition.test.sh', 'assert_equal 1 1\n')
put('bin/new-feature.py', 'new_behavior = True\n')
flags = inspect('additions', 0)
assert flags == []
print('ok - clean changes and added assertions do not need rulings')

# A renamed test still removes its original identity and needs a ruling.
(repo / 'tests/subject.test.sh').rename(repo / 'tests/renamed.test.sh')
flags = inspect('renamed-test', 1)
assert any(f['file'] == 'tests/subject.test.sh' for f in flags)
print('ok - renaming cannot hide removal of a test')

out = call(sys.executable, detector, '--repo', repo, '--base', 'main', '--head', base, expected=2)
assert 'exact full commit' in out
print('ok - invalid revision inputs are errors rather than clean verdicts')
PY
