#!/usr/bin/env bash
# Exercise DoD validation and exact-commit fail-first proof in isolated git repos.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot dod-check)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root, temp = map(Path, sys.argv[1:])
checker = root / 'bin/fm-dod-check.py'
dod = temp / 'dod.md'
repo = temp / 'repo'
repo.mkdir()

def call(*args, expected=0, env=None):
    result = subprocess.run(list(map(str, args)), text=True, capture_output=True, env=env)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout

def git(*args):
    return call('git', '-C', repo, *args).strip()

def criteria(command='test "$(cat value)" = fixed', authority='gate', verify='inspect output'):
    return f'''## Definition Of Done
### Mandatory items
- **C1** The regression is repaired. *(mandatory)*
  - Verify: {verify}
  - Check: `{command}`
  - Authority: {authority}
'''

def validate(text, expected=0):
    dod.write_text(text)
    return call(sys.executable, checker, 'validate', '--dod', dod, expected=expected)

git('init', '-q')
git('config', 'user.email', 'test@example.invalid')
git('config', 'user.name', 'test')
(repo / 'tests').mkdir()
(repo / 'tests/changed.test.sh').write_text('exit 0\n')
(repo / 'value').write_text('broken\n')
git('add', '.')
git('commit', '-qm', 'base behavior')
base = git('rev-parse', 'HEAD')
(repo / 'value').write_text('fixed\n')
(repo / 'tests/regression.test.sh').write_text('#!/usr/bin/env bash\nset -eu\ntest "$(cat value)" = fixed\n')
(repo / 'tests/changed.test.sh').write_text('test "$(cat value)" = fixed\n')
git('add', '.')
git('commit', '-qm', 'fix with regression')
head = git('rev-parse', 'HEAD')

validate(criteria())
missing = criteria().replace('  - Check: `test "$(cat value)" = fixed`\n', '')
assert 'C1' in validate(missing, 1) and 'exact Check' in validate(missing, 1)
for authority in ('grader', 'agent'):
    validate(missing.replace('Authority: gate', 'Authority: ' + authority))
assert 'Verify' in validate(criteria(verify=''), 1)
assert 'scaffold' in validate(criteria() + '\n{DOD_HARD_GATES}\n', 1)
assert 'mandatory' in validate('## Definition Of Done\n', 1)
assert 'duplicate DoD id' in validate(criteria() + criteria(), 1)
assert 'C1' in validate(criteria().replace('Authority: gate', 'Authority: maybe'), 1)
print('ok - gate items require exact commands and all mandatory items require Verify')

# The worker cannot satisfy a criterion by putting fields inside a fenced sample.
assert 'requires Verify' in validate(criteria().replace('  - Verify:', '```\n  - Verify:') + '\n```\n', 1)
validate(criteria() + '\n```\n{DOD_EXAMPLE}\n```\n')
print('ok - fenced examples do not supply commands, authority or Verify')

def run(name, text, expected=0, supplied_head=head, environment=None):
    dod.write_text(text)
    output = temp / name
    stdout = call(sys.executable, checker, 'run', '--dod', dod, '--repo', repo,
                  '--base', base, '--head', supplied_head, '--output', output,
                  expected=expected, env=environment)
    manifest = json.loads((output / 'results.json').read_text())
    assert manifest['head'] == supplied_head
    assert manifest['base'] == base
    assert manifest['dod_sha256'] == hashlib.sha256(dod.read_bytes()).hexdigest()
    for result in manifest['items'] + [r[p] for r in manifest['tests'] for p in ('base', 'head')]:
        assert result['sha256'] == hashlib.sha256((output / result['log']).read_bytes()).hexdigest()
        assert f"exit: {result['exit']}" in (output / result['log']).read_text()
    return manifest, stdout

# A dirty working file must not make the exact-head command pass or fail.
(repo / 'value').write_text('dirty\n')
environment = os.environ.copy()
environment.update(GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='2', GITHUB_TOKEN='must-not-leak', GH_TOKEN='must-not-leak')
text = criteria(command='test "$(cat value)" = fixed && test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GITHUB_OUTPUT:-}"',
                verify='bash tests/regression.test.sh and bash tests/changed.test.sh')
manifest, stdout = run('valid', text, environment=environment)
assert manifest['passed'] is True
assert manifest['run_id'] == '123' and manifest['run_attempt'] == '2'
assert manifest['items'][0]['commit'] == head
assert {row['path'] for row in manifest['tests']} == {'tests/changed.test.sh', 'tests/regression.test.sh'}
assert all(row['base']['exit'] != 0 and row['head']['exit'] == 0 for row in manifest['tests'])
assert 'command:' in stdout and 'exit: 0' in stdout and head in stdout
print('ok - exact-head gate runs and overlaid new regression fails on base, passes on head, with hashed logs')

manifest, _ = run('nonzero', criteria(command='exit 7'), 1)
assert manifest['items'][0]['exit'] == 7 and manifest['passed'] is False
manifest, _ = run('pipefail', criteria(command='false | true'), 1)
assert manifest['items'][0]['exit'] != 0
print('ok - nonzero commands and failed pipeline components make the check fail')

(repo / 'value').write_text('fixed\n')
(repo / 'tests/already.test.sh').write_text('exit 0\n')
git('add', '.')
git('commit', '-qm', 'regression that fails to prove the fix')
passing_head = git('rev-parse', 'HEAD')
manifest, stdout = run('already-pass', criteria(verify='bash tests/already.test.sh'), 1, passing_head)
assert manifest['tests'][0]['base']['exit'] == 0
assert manifest['passed'] is False and 'fail_first: fail' in stdout
print('ok - a newly named test that already passes on base is rejected')
supporting = criteria() + '''### Supporting items
- **S1** Supporting evidence.
  - Verify: bash tests/already.test.sh
'''
manifest, _ = run('supporting-test', supporting, 1, passing_head)
assert manifest['tests'][0]['path'] == 'tests/already.test.sh' and manifest['passed'] is False
print('ok - changed tests named by supporting items also require fail-first proof')

(repo / 'tests/already.test.sh').write_text('exit 9\n')
git('add', '.')
git('commit', '-qm', 'broken head regression')
failing_head = git('rev-parse', 'HEAD')
manifest, _ = run('head-fails', criteria(verify='bash tests/already.test.sh'), 1, failing_head)
assert manifest['tests'][0]['head']['exit'] == 9 and manifest['passed'] is False
print('ok - a named regression that fails on head cannot pass fail-first proof')

out = call(sys.executable, checker, 'run', '--dod', dod, '--repo', repo,
           '--base', 'HEAD~1', '--head', head, '--output', temp / 'invalid-ref', expected=1)
assert 'exact full commit' in out
assert not (temp / 'invalid-ref').exists()
print('ok - mutable refs are rejected before running any command')
PY
