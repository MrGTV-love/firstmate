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
import time

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
C1 Source: repair request
  Expected: the regression is repaired
  Verify: {verify}
  Edge/negative: broken behavior is rejected
  Evidence place: CI artifact
  Authority: {authority}
  - Check: `{command}`
'''

def validate(text, expected=0):
    # The criteria owner's --items is the one parser CI and merge share.
    dod.write_text(text)
    result = subprocess.run(['bash', str(root / 'bin/fm-dod-lib.sh'), '--items', str(dod)],
                            text=True, capture_output=True)
    assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
    return result.stdout + result.stderr

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
validate(criteria().replace('\n', '\r\n'))
validate(criteria(command=''), 1)
validate(criteria(command='   '), 1)
missing = criteria().replace('  - Check: `test "$(cat value)" = fixed`\n', '')
assert 'C1' in validate(missing, 1) and 'exact Check' in validate(missing, 1)
for authority in ('grader', 'agent'):
    validate(missing.replace('Authority: gate', 'Authority: ' + authority))
assert 'Verify' in validate(criteria(verify=''), 1)
validate(criteria() + '\n{DOD_HARD_GATES}\n', 1)
assert 'mandatory' in validate('## Definition Of Done\n', 1)
validate(criteria() + criteria().split('### Mandatory items\n', 1)[1], 1)
assert 'C1' in validate(criteria().replace('Authority: gate', 'Authority: maybe'), 1)
print('ok - gate items require exact commands and all mandatory items require Verify')

# The worker cannot satisfy a criterion by putting fields inside a fenced sample.
validate(criteria().replace('  Verify:', '```\n  Verify:') + '\n```\n', 1)
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

# Shell command content is data, even when it mentions DoD field labels.
manifest, _ = run('opaque-source-check', criteria(command=r"printf '%s\n' 'x Source: y'"))
assert manifest['passed'] is True
assert 'x Source: y' in (temp / 'opaque-source-check' / manifest['items'][0]['log']).read_text().splitlines()
print('ok - Check commands containing Source labels execute as opaque shell content')

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
# The recorder's own wait supplies the exit, whatever the command prints, and a
# command's background writer ends with it before any evidence is written.
boundary = temp / 'recorder-boundary'
manifest, _ = run('recorder-boundary', criteria(command=f"(sleep 3; printf forged > {boundary / 'gate-C1.log'}) & printf 'exit: 0\\n'; exit 7"), 1)
assert manifest['items'][0]['exit'] == 7 and manifest['passed'] is False
time.sleep(4)
assert hashlib.sha256((boundary / 'gate-C1.log').read_bytes()).hexdigest() == manifest['items'][0]['sha256']
assert (boundary / 'gate-C1.log').read_text().endswith('\nexit: 7\n')
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

# Exit polarity is not semantic proof. Expected: `bash app.sh` prints exactly
# fixed. A marker-file test fails on base and passes on a head whose app still
# prints the wrong text; a test of the real output rejects that head and accepts
# the genuine repair.
oracle = temp / 'oracle'
oracle.mkdir()
def ogit(*args):
    return call('git', '-C', oracle, *args).strip()
ogit('init', '-q')
ogit('config', 'user.email', 'test@example.invalid')
ogit('config', 'user.name', 'test')
(oracle / 'app.sh').write_text('printf broken\n')
ogit('add', '.')
ogit('commit', '-qm', 'broken app')
oracle_base = ogit('rev-parse', 'HEAD')
(oracle / 'app.sh').write_text('printf wrong\n')
(oracle / '.fixed').write_text('marker\n')
(oracle / 'tests').mkdir()
(oracle / 'tests/marker.test.sh').write_text('test -f .fixed\n')
(oracle / 'tests/output.test.sh').write_text('observed=$(bash app.sh)\necho "observed=$observed expected=fixed"\ntest "$observed" = fixed\n')
ogit('add', '.')
ogit('commit', '-qm', 'planted wrong implementation')
wrong_head = ogit('rev-parse', 'HEAD')
(oracle / 'app.sh').write_text('printf fixed\n')
ogit('commit', '-qam', 'genuine repair')
repaired_head = ogit('rev-parse', 'HEAD')
assert call('bash', oracle / 'app.sh') == 'fixed'
def oracle_run(name, test, head_sha, expected):
    dod.write_text(criteria(command=f'bash {test}', verify=f'bash {test} shows bash app.sh prints exactly fixed'))
    stdout = call(sys.executable, checker, 'run', '--dod', dod, '--repo', oracle, '--base', oracle_base,
                  '--head', head_sha, '--output', temp / name, expected=expected)
    assert 'semantics: unassessed' in stdout
    assert 'semantics: unassessed' in (temp / name / 'summary.log').read_text()
    return json.loads((temp / name / 'results.json').read_text())
proxy = oracle_run('oracle-proxy', 'tests/marker.test.sh', wrong_head, 0)
assert proxy['passed'] is True and proxy['tests'][0]['base']['exit'] != 0 and proxy['tests'][0]['head']['exit'] == 0
real = oracle_run('oracle-wrong', 'tests/output.test.sh', wrong_head, 1)
assert real['passed'] is False and real['items'][0]['exit'] != 0 and real['tests'][0]['head']['exit'] != 0
assert 'observed=wrong expected=fixed' in (temp / 'oracle-wrong' / real['tests'][0]['head']['log']).read_text()
repaired = oracle_run('oracle-repaired', 'tests/output.test.sh', repaired_head, 0)
assert repaired['passed'] is True and repaired['tests'][0]['base']['exit'] != 0 and repaired['tests'][0]['head']['exit'] == 0
print('ok - a marker-file proxy passes fail-first on a wrong app, the real output test rejects it and accepts the repair, and evidence states semantics unassessed')

# Freeze through the same public interface spawn uses, outside the PR repo.
home = temp / 'home'
state = home / 'state'
state.mkdir(parents=True)
brief = temp / 'brief.md'
dod.write_text(text)
brief.write_text(f'''# Task
## Captain's intent
Repair the regression.
## Firstmate spec
Keep the change bounded.
### Out of scope
None.
## Definition Of Done (task)
DoD file: {dod}
## How You're Graded
''')
snapshot = json.loads(call(sys.executable, checker, 'freeze', '--brief', brief, '--state', state, '--task', 'task'))
frozen = Path(snapshot['dod_file'])
assert frozen.parent == state and frozen.read_bytes() == dod.read_bytes()
assert snapshot['dod_sha256'] == hashlib.sha256(frozen.read_bytes()).hexdigest()
dod.write_text(criteria(command='true'))
assert frozen.read_text() == text
meta = state / 'task.meta'
meta.write_text(f"worktree={repo}\nmodel=gpt-5.1\nmode=direct-PR\nbranch=fm/test\ndod_file={frozen}\ndod_sha256={snapshot['dod_sha256']}\n")
missing_brief = temp / 'missing.md'
missing_brief.write_text("# Task\n## Captain's intent\nRepair behavior.\n## Firstmate spec\nKeep it small.\n")
call(sys.executable, checker, 'freeze', '--brief', missing_brief, '--state', state, '--task', 'missing', expected=1)
assert not list(state.glob('missing.dod.*'))
print('ok - dispatch freezes selected bytes and digest outside the branch, refuses absent criteria, and ignores later criteria rewrites')

# Forge calls alone are stubbed. Produce real command logs and exact-commit diff
# records through the workflow's trusted recorder; the resolver must
# independently check their identities and digests.
artifact = temp / 'hosted-artifact'
recorded = call(sys.executable, checker, 'run', '--dod', frozen, '--repo', repo, '--base', base,
                '--head', head, '--output', artifact, env=environment)
manifest = json.loads((artifact / 'results.json').read_text())
assert manifest['passed'] is True and manifest['items'][0]['commit'] == head
assert f"command: {json.dumps(manifest['items'][0]['command'])}" in recorded and 'exit: 0' in recorded
flags = json.loads((artifact / 'weakening.json').read_text())['flags']
assert flags
pointer = {'id': 'C1', 'run_id': '123', 'commit': head, 'file': 'value', 'line': 1,
           'log': manifest['items'][0]['log'], 'log_sha256': manifest['items'][0]['sha256']}
claims = {'items': [pointer], 'rulings': [{'id': f['id'], 'decision': 'accept', 'reason': 'Replaced unconditional exit with a real regression.'} for f in flags]}
run_record = {'id': 123, 'event': 'workflow_dispatch', 'path': '.github/workflows/dod-evidence.yml',
              'status': 'completed', 'conclusion': 'success', 'repository': {'full_name': 'example/repo'},
              'head_branch': 'main', 'head_sha': base, 'run_attempt': 2}
run_file = temp / 'run.json'
run_file.write_text(json.dumps(run_record))
(temp / 'repo.json').write_text(json.dumps({'default_branch': 'main'}))
(temp / 'compare.json').write_text(json.dumps({'status': 'identical'}))
(temp / 'pr.json').write_text(json.dumps({'state': 'open', 'head': {'ref': 'fm/test', 'sha': head}}))
artifacts_file = temp / 'artifacts.json'
artifacts_file.write_text(json.dumps({'total_count': 1, 'artifacts': [{'name': f'fm-dod-evidence-{head}', 'expired': False}]}))
fakebin = temp / 'fakebin'
fakebin.mkdir()
stub = fakebin / 'gh-axi'
stub.write_text('''#!/usr/bin/env python3
import base64, json, os
from pathlib import Path
import shutil, sys
root = Path(os.environ['FM_FORGE_FIXTURE'])
args = sys.argv[1:]
if os.environ.get('FM_FORGE_DOWN'):
    sys.exit(1)
if args[0] == 'api':
    if args[1].endswith('/artifacts?per_page=100'):
        name = 'artifacts.json'
    elif '/compare/' in args[1]:
        name = 'compare.json'
    elif '/actions/runs/' in args[1]:
        name = 'run.json'
    elif args[1].endswith('/pulls/9'):
        name = 'pr.json'
    else:
        name = 'repo.json'
    data = (root / name).read_bytes()
    print('api_response:\\n  body: ' + base64.b64encode(data).decode() + '\\n  truncated: false')
elif args[:2] == ['run', 'download']:
    shutil.copytree(root / 'hosted-artifact', Path(args[args.index('--dir') + 1]))
elif args[:2] == ['workflow', 'run']:
    (root / 'dispatched.json').write_text(json.dumps(args))
else:
    sys.exit(2)
''')
stub.chmod(0o755)
forge_env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ['PATH'], FM_FORGE_FIXTURE=str(temp))

def resolve(document=claims, expected=0, live_base=base, env=forge_env):
    result = subprocess.run([sys.executable, str(checker), 'verify', '--meta', str(meta),
                             '--pr', 'https://github.com/example/repo/pull/9', '--base', live_base, '--head', head],
                            input=json.dumps(document), capture_output=True, text=True, env=env)
    assert result.returncode == expected, (result.stdout, result.stderr)
    return result.stdout

assert 'evidence: resolved' in resolve()
resolve({**claims, 'items': [{'id': 'C1', 'run_id': '123'}]})
resolve({**claims, 'run_id': '123', 'items': [{'id': 'C1', 'commit': head}]}, 1)
resolve({'items': []}, 1)
unruled = resolve({**claims, 'rulings': []}, 1)
assert flags[0]['file'] + ':' + str(flags[0]['line']) in unruled
resolve({**claims, 'rulings': claims['rulings'] * 2}, 1)
for change in ({'commit': base}, {'line': 99}, {'file': 'absent'}, {'log_sha256': '0' * 64}, {'run_id': 'bad'}):
    resolve({**claims, 'items': [{**pointer, **change}]}, 1)
run_file.write_text(json.dumps({**run_record, 'conclusion': 'failure'}))
resolve(expected=1)
run_file.write_text(json.dumps({**run_record, 'head_branch': 'fm/test', 'head_sha': head}))
assert 'not the default branch' in resolve(expected=1)
# A tag named like the default branch carries its own workflow commit.
run_file.write_text(json.dumps({**run_record, 'head_sha': head}))
(temp / 'compare.json').write_text(json.dumps({'status': 'diverged'}))
assert 'not in default branch main history' in resolve(expected=1)
(temp / 'compare.json').write_text(json.dumps({'status': 'identical'}))
run_file.write_text(json.dumps(run_record))
advanced = git('commit-tree', base + '^{tree}', '-p', base, '-m', 'unrelated base advance')
assert 'evidence: resolved' in resolve(live_base=advanced)
orphan = git('commit-tree', base + '^{tree}', '-m', 'unrelated history')
assert 'not in the live PR base history' in resolve(live_base=orphan, expected=1)
down = resolve(expected=3, env=dict(forge_env, FM_FORGE_DOWN='1'))
assert 'cannot resolve GitHub evidence' in down
original_log = (artifact / pointer['log']).read_bytes()
(artifact / pointer['log']).write_text('fabricated pass\n')
resolve(expected=1)
(artifact / pointer['log']).write_bytes(original_log)
print('ok - real machine proof resolves across an unrelated base advance; missing items, shared run ids, stale head, invalid file:line, wrong log digest, failed CI, non-default workflow refs or commits, foreign base history and missing exact-line rulings refuse, and unreachable evidence exits 3')

call(sys.executable, checker, 'dispatch', '--meta', meta, '--pr', 'https://github.com/example/repo/pull/9', env=forge_env)
dispatched = json.loads((temp / 'dispatched.json').read_text())
assert dispatched[dispatched.index('--ref') + 1] == 'main'
assert f'head={head}' in dispatched and f'dod={text}' in dispatched
generated = json.loads(call(sys.executable, checker, 'claims', '--meta', meta, '--run', '123'))
assert generated == {'items': [{'id': 'C1', 'run_id': '123'}]}
assert 'evidence: resolved' in resolve({**generated, 'rulings': claims['rulings']})
call(sys.executable, checker, 'claims', '--meta', meta, '--run', 'latest', expected=1)
print('ok - dispatch targets the default-branch workflow with the exact head, and a finished run id becomes resolving claims')

report = temp / 'review.md'
report.write_text(f'VERDICT: PASS head={head}\nIndependent review.\n')
claims_file = temp / 'claims.json'
claims_file.write_text(json.dumps(claims))
review_env = dict(forge_env, FM_HOME=str(home), NM_HOME=str(temp / 'absent-nm'))
record = root / 'bin/fm-review-record.py'
call(sys.executable, record, 'review', '--pr', 'https://github.com/example/repo/pull/9', '--head', head,
     '--verdict', 'PASS', '--reader-model', 'claude-sonnet', '--author-groups', '{"ship":["gpt-5.1"]}',
     '--loosens-deny-allow-list', 'no', '--widens-guard', 'no', '--customer-data-billing-spend', 'no',
     '--report', report, '--dod-evidence', claims_file, env=review_env)
claims_file.write_text('{}')
verify_args = [sys.executable, record, 'verify', '--pr', 'https://github.com/example/repo/pull/9',
               '--head', head, '--base', base, '--task', 'task', '--machine-checked']
assert call(*verify_args, env=review_env).strip() == 'review: PASS'
(artifact / pointer['log']).write_text('fabricated pass\n')
refusal = call(*verify_args, expected=1, env=review_env)
assert 'CI log digest does not resolve' in refusal and 'fm-dod-check.py dispatch --meta' in refusal
(state / 'legacy.meta').write_text(f"worktree={repo}\nmodel=gpt-5.1\nmode=direct-PR\nbranch=fm/test\n")
legacy = subprocess.run([*map(str, verify_args[:-2]), 'legacy', '--machine-checked'],
                        capture_output=True, text=True, env=review_env)
assert legacy.returncode == 0 and legacy.stdout.strip() == 'review: PASS', (legacy.stdout, legacy.stderr)
assert 'not machine-checked: no dispatch-time DoD digest' in legacy.stderr
call(sys.executable, record, 'captain-word', '--pr', 'https://github.com/example/repo/pull/9',
     '--head', head, '--words', 'Merge this exact PR.', env=review_env)
assert call(*verify_args, env=review_env).strip() == 'review: captain-word'
unreachable = json.loads(call(*verify_args[:-1], '--review-only', '--machine-checked', '--json', expected=1,
                              env=dict(review_env, FM_FORGE_DOWN='1')))
assert unreachable['ok'] is False and unreachable['error']['kind'] == 'unavailable'
print('ok - review copies pointers immutably and resolves them for an independent PASS; a task without a dispatch digest and captain words keep their existing route')
PY
