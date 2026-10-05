#!/usr/bin/env python3
"""Disposable validation of the real resolver with controlled external inputs."""
import copy
import datetime
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading

ROOT = Path.cwd()
WORK = ROOT / '.runway-validation'
EVIDENCE = Path('/Users/charlesabrooker/.no-mistakes/evidence/01M46CWAPPBX74ZZNE5E6HQC1P')
EVIDENCE.mkdir(parents=True, exist_ok=True)
HOME = WORK / 'home'
CONFIG = HOME / 'config'
BIN = WORK / 'bin'
TMP = WORK / 'tmp'
for directory in (CONFIG, BIN, TMP):
    directory.mkdir(parents=True, exist_ok=True)
BRIEF = WORK / 'brief.md'
BRIEF.write_text('# Task\nFix the pager off-by-one with a stated root cause.\n')
PYTHON = shutil.which('python3')
CURL = shutil.which('curl')
assert PYTHON and CURL

# Only external data sources are substituted. All matching, validation, quota
# joins, horizon classification, ranking and text output execute the real CLI.
(BIN / 'curl').write_text('#!' + PYTHON + '\n' + '''import os, sys
args = [os.environ['CONTROLLED_ENDPOINT'] if a == 'https://api.typesafe.ai/v1/systemone' else a for a in sys.argv[1:]]
os.execv(os.environ['REAL_CURL'], [os.environ['REAL_CURL']] + args)
''')
(BIN / 'quota-axi').write_text('#!' + PYTHON + '\n' + '''import os, sys
from pathlib import Path
with open(os.environ['QUOTA_CALL_LOG'], 'a') as log:
    log.write(' '.join(sys.argv[1:]) + '\\n')
if sys.argv[1:] == ['--version']:
    if os.environ.get('CONTROLLED_VERSION_FAIL') == '1':
        sys.exit(1)
    print(os.environ['CONTROLLED_VERSION'])
elif sys.argv[1:] == ['--json']:
    print(Path(os.environ['CONTROLLED_QUOTA']).read_text())
else:
    sys.exit(2)
''')
for executable in BIN.iterdir():
    executable.chmod(0o755)

requests = []
current_response = {}
class Endpoint(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        requests.append(json.loads(body))
        payload = json.dumps(current_response).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()

NATIVE = {'harness': 'codex', 'model': 'gpt-6-luna'}
POOL = {'harness': 'omp', 'model': 'openai-codex/gpt-6-luna', 'provider': 'codex'}
CURSOR = {'harness': 'cursor', 'model': 'cursor-grok-4.6-medium'}
OPENROUTER = {'harness': 'omp', 'model': 'openrouter/provider/model', 'provider': 'openrouter'}

def config(profiles, horizon=None, extra_rules=False, floor=None):
    result = {'rules': [{'when': 'A simple bug fix with a stated root cause.', 'use': copy.deepcopy(profiles)}]}
    if horizon is not None:
        result['task_horizon_minutes'] = horizon
    if extra_rules:
        result['rules'].append({'when': 'Cheap chores.', 'use': CURSOR})
        result['default'] = [{'harness': 'cursor', 'model': 'cursor-grok-4.6-high'}]
    if floor:
        result['rules'][0]['floor'] = floor
    return result

def runway(status='projected_exhaustion', seconds=3600, confidence='established'):
    value = {'status': status}
    if seconds is not None:
        value['usableRunwaySeconds'] = seconds
    if confidence is not None:
        value['projectionConfidence'] = confidence
    return value

def row(scope='all_models', percent=6, priority=0.9, run=None):
    return {'scope': scope, 'status': 'known', 'effectivePercentRemaining': percent,
            'selection': {'spendPriority': priority}, 'runway': run or runway()}

def quota(run=None, percent=6, extra_bound=None, schema6=False, openrouter=False, missing_priority=False):
    bounds = [row(run=run, percent=percent)]
    if extra_bound:
        bounds.append(extra_bound)
    if missing_priority:
        bounds[0].pop('selection')
    providers = [
        {'provider': 'codex', 'state': {'status': 'fresh'}, 'quotaSemantics': {'status': 'known', 'effectiveAvailability': bounds}},
        {'provider': 'cursor', 'state': {'status': 'fresh'}, 'quotaSemantics': {'status': 'known', 'effectiveAvailability': [row(percent=91, priority=0.7597, run={'status': 'through_reset'})]}}
    ]
    if openrouter:
        providers.append({'provider': 'openrouter', 'windows': [{'id': 'credits', 'remaining': 100, 'unit': 'USD'}], 'quotaSemantics': {'status': 'unknown', 'effectiveAvailability': []}})
    if schema6:
        providers[0]['accountKey'] = 'default'
        providers[1]['accountKey'] = 'default'
    return {'generatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'schemaVersion': 6 if schema6 else 5, 'providers': providers}

results = []
def drive(name, cfg, snapshot, status, profile=None, require=(), forbid=(), code=0, version='0.1.51', version_fail=False, calls=None, http_count=1):
    global current_response
    choices = ['rule_' + str(i + 1) for i in range(len(cfg['rules']))] + ['default']
    probabilities = {choice: (0.97 if choice == 'rule_1' else 0.03 / (len(choices) - 1)) for choice in choices}
    current_response = {'model': 'jev-controlled-input', 'answers': {'rule': {'type': 'choice', 'choice': 'rule_1', 'confidence': 0.9, 'probabilities': probabilities}}}
    (CONFIG / 'crew-dispatch.json').write_text(json.dumps(cfg))
    quota_path = WORK / 'quota.json'
    quota_path.write_text(json.dumps(snapshot))
    call_log = WORK / 'quota.calls'
    call_log.write_text('')
    env = os.environ.copy()
    for key in list(env):
        if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in ('FM_HOME', 'TYPESAFE_API_KEY', 'TYPESAFE_API_KEY_PRIVATE', 'FM_GATE_REFUSE_BYPASS', 'FM_TEST_SEAM'):
            env.pop(key, None)
    env.update(PATH=str(BIN) + os.pathsep + os.environ['PATH'], FM_HOME=str(HOME), TMPDIR=str(TMP),
               TYPESAFE_API_KEY='controlled-local-endpoint-only', REAL_CURL=CURL,
               CONTROLLED_ENDPOINT='http://127.0.0.1:' + str(server.server_port) + '/v1/systemone',
               CONTROLLED_QUOTA=str(quota_path), QUOTA_CALL_LOG=str(call_log),
               CONTROLLED_VERSION=version, CONTROLLED_VERSION_FAIL='1' if version_fail else '0')
    before = len(requests)
    command = [str(ROOT / 'bin/fm-dispatch-resolve.sh'), str(BRIEF), '--project', 'firstmate']
    run = subprocess.run(command, env=env, cwd=ROOT, text=True, capture_output=True, timeout=30)
    actual_calls = call_log.read_text().splitlines()
    failures = []
    if run.returncode != code:
        failures.append('exit code: expected ' + str(code) + ', got ' + str(run.returncode))
    if status and '  status: ' + status + '\n' not in run.stdout:
        failures.append('expected status ' + status)
    profile_lines = [line for line in run.stdout.splitlines() if line.startswith('  profile:')]
    if profile is None and profile_lines:
        failures.append('unexpected dispatch profile')
    if profile is not None and profile_lines != ['  profile: ' + profile]:
        failures.append('wrong dispatch profile ' + repr(profile_lines))
    for text in require:
        if text not in run.stdout + run.stderr:
            failures.append('missing: ' + text)
    for text in forbid:
        if text in run.stdout + run.stderr:
            failures.append('forbidden: ' + text)
    if 'quota_summary' in run.stdout:
        failures.append('obsolete quota_summary output')
    if calls is not None and actual_calls != calls:
        failures.append('unexpected quota calls: ' + repr(actual_calls))
    if len(requests) - before != http_count:
        failures.append('unexpected API call count')
    if http_count:
        # The task horizon is local policy and must not leak into the model request.
        request = requests[-1]
        if 'task_horizon_minutes' in json.dumps(request):
            failures.append('task horizon sent to model')
    artifact = {'name': name, 'result': 'fail' if failures else 'pass',
                'evidence_type': 'actual resolver CLI with controlled external quota and model-answer inputs; not fresh provider readings',
                'command': 'bin/fm-dispatch-resolve.sh .runway-validation/brief.md --project firstmate',
                'config': cfg, 'quota_input': snapshot, 'quota_version': version,
                'model_answer_input': current_response, 'request': requests[-1] if http_count else None,
                'exit_code': run.returncode, 'stdout': run.stdout, 'stderr': run.stderr,
                'quota_calls': actual_calls, 'failures': failures}
    (EVIDENCE / (name + '.json')).write_text(json.dumps(artifact, indent=2) + '\n')
    results.append(artifact)
    print(name + ': ' + artifact['result'])
    print(run.stdout or run.stderr, end='')
    if failures:
        print('ASSERTION FAILURES:', failures)

P_NATIVE = "--harness 'codex' --model 'gpt-6-luna'"
P_POOL = "--harness 'omp' --model 'openai-codex/gpt-6-luna'"
P_CURSOR = "--harness 'cursor' --model 'cursor-grok-4.6-medium'"
SHORT = ('shorter than the 240-minute task horizon',)
try:
    # Eight previously unexercised acceptance scenarios, with explicit subcases.
    drive('report-case-six-percent-1800-established', config([NATIVE]), quota(runway(seconds=1800)), 'escalate', require=SHORT + ('remaining=6%', 'usableRunwaySeconds=1800 projectionConfidence=established'))
    drive('established-3600-short', config([NATIVE]), quota(), 'escalate', require=SHORT)
    for harness, p in ((NATIVE, P_NATIVE), (POOL, P_POOL)):
        prefix = 'pool' if harness == POOL else 'single'
        for confidence in ('early', None):
            drive(prefix + '-low-confidence-' + str(confidence), config([harness]), quota(runway(seconds=1800, confidence=confidence)), 'clear', p, require=('[warning: projected_exhaustion at all_models', 'projectionConfidence=' + (confidence or 'unknown')))
        drive(prefix + '-exact-14400-boundary', config([harness]), quota(runway(seconds=14400)), 'clear', p, forbid=('[warning:',))
        drive(prefix + '-covering-80796-established', config([harness]), quota(runway(seconds=80796)), 'clear', p, forbid=('[warning:',))
    drive('configured-30-minute-horizon', config([NATIVE], horizon=30), quota(), 'clear', P_NATIVE, forbid=('[warning:',))
    drive('configured-120-minute-horizon', config([NATIVE], horizon=120), quota(), 'escalate', require=('shorter than the 120-minute task horizon',))
    drive('invalid-zero-horizon', config([NATIVE], horizon=0), quota(), None, code=2, require=('task_horizon_minutes must be a positive number',), calls=[], http_count=0)
    exhausted = quota(runway('exhausted_now', None, None), percent=0)
    drive('exhausted-pool-unranked', config([POOL]), exhausted, 'escalate', require=('-> eligible, unranked: omp Codex account pool is only lower-bounded', '[warning: exhausted_now at all_models]'), forbid=('not eligible', 'remaining='))
    drive('exhausted-pool-beside-measured', config([POOL, CURSOR]), exhausted, 'clear', P_CURSOR, require=('  note: 1 eligible candidate(s) unranked (codex)', '[warning: exhausted_now at all_models]'), forbid=('not eligible',))
    drive('short-pool-winner-no-same-rule-fallback', config([POOL, CURSOR]), quota(), 'escalate', require=SHORT + ('highest-ranked candidate omp:openai-codex/gpt-6-luna', 'candidate: cursor:cursor-grok-4.6-medium'))
    drive('healthy-pool-winner-control', config([POOL, CURSOR]), quota(runway('through_reset', None, None)), 'clear', P_POOL, forbid=('[warning:',))
    drive('outdated-quota-axi', config([NATIVE]), quota(), 'error', version='0.1.50', require=('quota-axi requires >= 0.1.51',), forbid=('candidate:',), calls=['--version'])
    # Preserve floors, provider coverage, every applicable bound, and route class.
    for run_name, run_value in (('safe', runway('through_reset', None, None)), ('exhausted', runway('exhausted_now', None, None))):
        with_floor = dict(POOL, floor={'scope': 'all_models', 'min_percent': 50})
        drive('pool-explicit-floor-' + run_name, config([with_floor]), quota(run_value), 'escalate', require=('-> not eligible: profile floor all_models below 50%',), forbid=('eligible, unranked',))
    drive('single-exhausted-veto', config([NATIVE]), exhausted, 'escalate', require=('-> not eligible: runway exhausted_now at all_models',))
    drive('single-zero-veto', config([NATIVE]), quota(runway('through_reset', None, None), percent=0), 'escalate', require=('-> not eligible: 0% remaining at all_models',))
    drive('pool-zero-unranked', config([POOL]), quota(runway('through_reset', None, None), percent=0), 'escalate', require=('-> eligible, unranked:', '0% remaining at all_models'), forbid=('not eligible',))
    drive('short-pool-no-cross-rule-or-default-fallback', config([POOL], extra_rules=True), quota(), 'escalate', require=SHORT, forbid=('candidate: cursor', 'fallback:'))
    drive('short-single-no-same-rule-fallback', config([NATIVE, CURSOR]), quota(), 'escalate', require=SHORT)
    drive('short-nonlimiting-model-bound', config([POOL]), quota(runway('through_reset', None, None), extra_bound=row(scope='model:gpt-6-luna', percent=50, priority=1, run=runway(seconds=600))), 'escalate', require=SHORT + ('[warning: projected_exhaustion at model:gpt-6-luna',))
    for mode in ('absent', 'credit-only'):
        snapshot = quota(runway('through_reset', None, None), openrouter=mode == 'credit-only')
        drive('openrouter-' + mode + '-alone', config([OPENROUTER]), snapshot, 'escalate', require=('eligible, unranked:',), forbid=('not eligible',))
        drive('openrouter-' + mode + '-beside-measured', config([OPENROUTER, CURSOR]), snapshot, 'clear', P_CURSOR, require=('  note: 1 eligible candidate(s) unranked (openrouter)',))
    drive('missing-spend-priority-unranked', config([NATIVE]), quota(runway('through_reset', None, None), missing_priority=True), 'escalate', require=('eligible, unranked:',))
    for name, value in (('unknown', runway('unknown', None, None)), ('missing-seconds', runway(seconds=None))):
        drive('pool-' + name + '-warning', config([POOL]), quota(value), 'clear', P_POOL, require=('[warning:',))
    drive('schema6-short-pool-winner', config([POOL, CURSOR]), quota(schema6=True), 'escalate', require=SHORT)
    drive('schema6-exhausted-pool', config([POOL]), quota(runway('exhausted_now', None, None), percent=0, schema6=True), 'escalate', require=('eligible, unranked:', '[warning: exhausted_now at all_models]'), forbid=('not eligible',))
    for name, version, fail in (('unparseable', 'quota-axi development build', False), ('failed-read', '0.1.51', True)):
        drive('quota-version-' + name, config([NATIVE]), quota(), 'error', version=version, version_fail=fail, require=('quota-axi requires >= 0.1.51',), calls=['--version'])
    drive('minimum-quota-version-control', config([NATIVE]), quota(runway('through_reset', None, None)), 'clear', P_NATIVE, calls=['--version', '--json'])
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=3)
    summary = {'validation_time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'scope': 'controlled product CLI scenarios; no fresh Jev or provider calls, no lifecycle activity',
               'results': [{'name': r['name'], 'result': r['result'], 'failures': r['failures']} for r in results]}
    (EVIDENCE / 'controlled-cli-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    transcript = '\n'.join('=== ' + r['name'] + ' ===\n$ ' + r['command'] + '\n' + r['stdout'] + r['stderr'] + 'exit=' + str(r['exit_code']) + '\nquota calls=' + repr(r['quota_calls']) + '\n' for r in results)
    (EVIDENCE / 'controlled-cli-transcript.txt').write_text('Actual resolver CLI, controlled inputs via isolated FM_HOME. Quota and model answers are synthetic external inputs, not observed live-provider readings. Real curl communicates with a disposable localhost HTTP endpoint.\n\n' + transcript)
if any(r['result'] == 'fail' for r in results):
    raise SystemExit(1)
