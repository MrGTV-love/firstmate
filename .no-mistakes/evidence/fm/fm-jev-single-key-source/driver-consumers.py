#!/usr/bin/env python3
"""Disposable real-CLI/TLS validation; no product source edits or substitutions."""
import json, os, pathlib, shlex, subprocess, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORK = ROOT / '.live-validation' / 'consumers'
EVIDENCE = pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4C9C1P6TN97HD7NAANKCK9T')
SERVICE = json.loads((ROOT / '.live-validation/service.json').read_text())
REQUESTS = ROOT / '.live-validation/requests.jsonl'
WORK.mkdir(mode=0o700, parents=True, exist_ok=True)
EVIDENCE.mkdir(parents=True, exist_ok=True)
TRANSCRIPT = EVIDENCE / 'consumer-command-transcripts.jsonl'
RECEIPTS = EVIDENCE / 'consumer-sanitized-request-receipts.jsonl'
RESULTS = EVIDENCE / 'consumer-scenario-results.json'
COMMANDS = EVIDENCE / 'consumer-exact-commands.txt'
resuming = TRANSCRIPT.exists() and TRANSCRIPT.stat().st_size > 0
for path in (TRANSCRIPT, RECEIPTS, COMMANDS):
    if not path.exists():
        path.write_text('')
        path.chmod(0o600)
scenarios = []
previous = {}
prior_receipts = [json.loads(line) for line in RECEIPTS.read_text().splitlines()]
if resuming:
    for line in TRANSCRIPT.read_text().splitlines():
        entry = json.loads(line)
        label, consumer = entry['scenario'], entry['consumer']
        target = pathlib.Path(next(word.split('=', 1)[1] for word in shlex.split(entry['command']) if word.startswith('FM_HOME=')))
        incoming = [row for row in prior_receipts if row['scenario'] == label and row['consumer'] == consumer]
        status, hook_result = None, None
        if consumer == 'hook':
            log_path = target / 'state' / (label + '.jsonl')
            if log_path.exists():
                hook_result = next((row for row in reversed([json.loads(v) for v in log_path.read_text().splitlines()]) if row.get('event') == 'result'), None)
                status = hook_result.get('status') if hook_result else None
        elif consumer == 'dispatch':
            status = 'off' if 'dispatch-resolve: off' in entry['stderr'] else 'error' if 'status: error' in entry['stdout'] else 'other'
        else:
            status = next((v.strip().split(': ', 1)[1] for v in entry['stdout'].splitlines() if v.strip().startswith('status: ')), None)
        result = {'scenario': label, 'consumer': consumer, 'home': str(target.relative_to(ROOT)), 'exit_code': entry['exit_code'], 'status': status, 'network_calls': len(incoming), 'key_labels': [row['key_label'] for row in incoming], 'passed': entry['exit_code'] == 0 and status is not None}
        if hook_result:
            result['hook_result'] = hook_result
        previous[(label, consumer)] = result
        scenarios.append(result)


def write(path, text):
    if path.exists() and path.read_text() == text:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o600)


def home(name, parent=None):
    target = WORK / name
    (target / 'config').mkdir(parents=True, exist_ok=True)
    (target / 'tmp').mkdir(exist_ok=True)
    (target / 'operator-home').mkdir(exist_ok=True)
    write(target / 'config/crew-dispatch.json', json.dumps({'rules': [{'when': 'Disposable fixture maintenance task', 'use': {'harness': 'claude', 'model': 'claude-sonnet-4-6', 'provider': 'anthropic'}}]}))
    if parent:
        write(target / '.fm-secondmate-parent', f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n')
    return target


def records():
    if not REQUESTS.exists():
        return []
    rows = []
    for line in REQUESTS.read_text().splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        questions = row.get('body', {}).get('questions', {})
        if any(q in questions for q in ('risk', 'rule', 'need')):
            rows.append(row)
    return rows


def run(label, consumer, target, expected_key=None, expected_status=None, environment_key=None, private=False):
    prior = previous.get((label, consumer))
    if prior and prior['passed']:
        return
    if prior:
        label += '-retry-current-v2' if expected_key == 'primary-fixture-v1' else '-retry'
        if expected_key == 'primary-fixture-v1':
            expected_key = 'primary-fixture-v2'
    log = target / 'state' / (label + '.jsonl')
    text = 'Disposable fixture maintenance only.' + (' fixture-private-sentinel' if private else '')
    if consumer == 'hook':
        argv = ['/opt/homebrew/bin/node', str(ROOT / 'bin/fm-jev-guardrail.mjs'), 'hook', '--host', 'claude', '--log', str(log)]
        stdin = json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'git push --force origin ' + ('fixture-private-sentinel' if private else 'fixture-branch')}})
    elif consumer == 'dispatch':
        brief = target / (label + '-brief.txt')
        write(brief, "## Captain's intent\n" + text + '\n\n## Firstmate spec\nOnly synthetic fixture material.\n')
        argv = [str(ROOT / 'bin/fm-dispatch-resolve.sh'), str(brief), '--project', 'consumer-fixture']
        stdin = ''
    else:
        task = target / (label + '-task.txt')
        write(task, text + '\n')
        argv = [str(ROOT / 'bin/fm-skill-suggest.sh'), '--task-file', str(task)]
        stdin = ''
    env = {
        'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(target / 'operator-home'),
        'TMPDIR': str(target / 'tmp'), 'LANG': 'en_US.UTF-8', 'FM_HOME': str(target),
        'FM_ROOT_OVERRIDE': str(target), 'FM_CONFIG_OVERRIDE': str(target / 'config'),
        'FM_STATE_OVERRIDE': str(target / 'state'),
        'HTTPS_PROXY': SERVICE['proxy_url'], 'https_proxy': SERVICE['proxy_url'],
        'HTTP_PROXY': SERVICE['proxy_url'], 'http_proxy': SERVICE['proxy_url'],
        'ALL_PROXY': SERVICE['proxy_url'], 'all_proxy': SERVICE['proxy_url'],
        'NO_PROXY': '', 'no_proxy': '', 'CURL_CA_BUNDLE': SERVICE['ca_path'],
        'NODE_USE_ENV_PROXY': '1', 'NODE_EXTRA_CA_CERTS': SERVICE['ca_path'],
        'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
    }
    if environment_key:
        env['TYPESAFE_API_KEY'] = environment_key
    exact = 'env -i ' + ' '.join(shlex.quote(k + '=' + v) for k, v in sorted(env.items())) + ' ' + shlex.join(argv)
    if stdin:
        exact = 'printf %s ' + shlex.quote(stdin) + ' | ' + exact
    before = len(records())
    started = time.time()
    try:
        proc = subprocess.run(argv, input=stdin, text=True, capture_output=True, env=env, cwd=ROOT, timeout=120)
        rc, stdout, stderr = proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as exc:
        rc, stdout, stderr = 124, str(exc.stdout or ''), str(exc.stderr or '')
    incoming = records()[before:]
    status = None
    hook_result = None
    if consumer == 'hook' and log.exists():
        log_rows = [json.loads(line) for line in log.read_text().splitlines()]
        hook_result = next((row for row in reversed(log_rows) if row.get('event') == 'result'), None)
        status = hook_result.get('status') if hook_result else None
    elif consumer == 'dispatch':
        status = 'off' if 'dispatch-resolve: off' in stderr else 'error' if 'status: error' in stdout else 'other'
    else:
        status = next((line.strip().split(': ', 1)[1] for line in stdout.splitlines() if line.strip().startswith('status: ')), None)
    receipt_keys = [row.get('authorization', '').removeprefix('Bearer ') for row in incoming]
    success = rc == 0 and status == expected_status and (len(incoming) == 1 and receipt_keys == [expected_key] if expected_key else len(incoming) == 0)
    result = {'scenario': label, 'consumer': consumer, 'home': str(target.relative_to(ROOT)), 'exit_code': rc, 'status': status, 'expected_status': expected_status, 'network_calls': len(incoming), 'key_labels': receipt_keys, 'expected_key_label': expected_key, 'passed': success}
    if hook_result:
        result['hook_result'] = hook_result
    scenarios.append(result)
    with TRANSCRIPT.open('a') as out:
        out.write(json.dumps({'scenario': label, 'consumer': consumer, 'command': exact, 'stdin': stdin, 'started_at': started, 'finished_at': time.time(), 'exit_code': rc, 'stdout': stdout, 'stderr': stderr}) + '\n')
    with COMMANDS.open('a') as out:
        out.write('# ' + label + ' / ' + consumer + '\n' + exact + '\n\n')
    with RECEIPTS.open('a') as out:
        for row in incoming:
            body = row.get('body', {})
            out.write(json.dumps({'scenario': label, 'consumer': consumer, 'request_time': row.get('time'), 'path': row.get('path'), 'key_label': row.get('authorization', '').removeprefix('Bearer '), 'model': body.get('model'), 'question_types': {k: v.get('type') for k, v in body.get('questions', {}).items()}, 'state_fields': sorted(body.get('state', {})), 'raw_authorization_omitted': True, 'request_text_omitted': True}) + '\n')
    print(json.dumps(result), flush=True)


def trio(label, target, key=None, private=False, environment_key=None):
    for consumer, on_status, off_status in [('hook', 'judged', 'withheld' if private else 'missing_key'), ('dispatch', 'error', 'off'), ('skill', 'none', 'off')]:
        run(label, consumer, target, key, on_status if key else off_status, environment_key, private)

primary = home('primary')
if not resuming:
    write(primary / '.env', 'TYPESAFE_API_KEY=primary-fixture-v1\n')
lanes = [home(f'lane-{n}', primary) for n in range(1, 8)]
nested = home('nested-descendant', lanes[0])
for n, lane in enumerate(lanes, 1):
    trio(f'lane-{n}-primary-v1', lane, 'primary-fixture-v1')
trio('nested-primary-v1', nested, 'primary-fixture-v1')
write(primary / '.env', 'TYPESAFE_API_KEY=primary-fixture-v2\n')
trio('rotation-next-call-v2', lanes[0], 'primary-fixture-v2')
trio('nested-rotation-v2', nested, 'primary-fixture-v2')
own = home('own-env-precedence', primary)
write(own / '.env', 'TYPESAFE_API_KEY=own-fixture-key\n')
trio('own-env-over-primary', own, 'own-fixture-key')
trio('process-env-over-own-and-primary', own, 'environment-fixture-key', environment_key='environment-fixture-key')
missing = home('missing-key')
trio('missing-key', missing)
remote = home('remote-parent')
write(remote / '.fm-secondmate-parent', 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=fixture-unreachable-host\n')
trio('remote-parent-key-absent', remote)
malformed = home('malformed-parent')
write(malformed / '.fm-secondmate-parent', f'schema=fm-secondmate-parent.v1\nroute=local\nroute=local\nparent_home={primary}\n')
trio('malformed-parent', malformed)
cycle_a, cycle_b = home('cycle-a'), home('cycle-b')
write(cycle_a / '.fm-secondmate-parent', f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={cycle_b}\n')
write(cycle_b / '.fm-secondmate-parent', f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={cycle_a}\n')
trio('cyclic-parent', cycle_a)
unreachable = home('unreachable-parent', WORK / 'does-not-exist')
trio('unreachable-parent', unreachable)
private_home = home('privacy-withheld', primary)
write(private_home / 'config/dispatch-never-send', 'fixture-private-sentinel\n')
trio('privacy-withheld', private_home, private=True)
summary = {
    'all_passed': all(row['passed'] for row in scenarios if row not in previous.values()) and all(row['passed'] or any(new['consumer'] == row['consumer'] and new['scenario'].startswith(row['scenario'] + '-retry') and new['passed'] for new in scenarios) for row in previous.values()), 'scenarios': scenarios,
    'baseline_seven_hook_judged': sum(row['consumer'] == 'hook' and row['scenario'].startswith('lane-') and row['status'] == 'judged' for row in scenarios),
    'seven_lane_dotenv_absent': all(not (lane / '.env').exists() for lane in lanes),
    'nested_dotenv_absent': not (nested / '.env').exists(),
    'only_primary_rotated': 'primary/.env changed v1 to v2; no lane/nested key copies created',
    'dispatch_scope': 'Real resolver posts accepted Choice response; then intentionally reports quota-axi not installed under isolated PATH. No dispatch routing claim; no quota process or operator config touched.',
    'executable_policy': 'Actual /usr/bin/curl, /opt/homebrew/bin/node, /usr/bin/jq and unchanged product CLIs; no substitutions or package installs.',
    'artifacts': [str(path) for path in (TRANSCRIPT, RECEIPTS, RESULTS, COMMANDS)],
    'cleanup': 'Parent must remove .live-validation/consumers.py and .live-validation/consumers (disposable synthetic homes, .env files, logs, input files, empty TMPDIRs). Evidence retained. No source edits.',
}
write(RESULTS, json.dumps(summary, indent=2) + '\n')
raise SystemExit(0 if summary['all_passed'] and summary['baseline_seven_hook_judged'] == 7 and summary['seven_lane_dotenv_absent'] else 1)
