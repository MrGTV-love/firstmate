import json, os, shlex, subprocess, sys, threading, time, traceback
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path.cwd()
FIX = ROOT / '.gate-wake-lab'
EVID = Path(os.environ.get('LIVE_EVIDENCE', '/Users/charlesabrooker/.no-mistakes/evidence/01M4DXJQP6FBDZ6YHV46Y38ZKE'))
EVID.mkdir(parents=True, exist_ok=True)
HELPER = ROOT / 'bin/fm-herdr-lab.sh'
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith('FM_') or key.startswith('HERDR_') or key in ('TMUX', 'NO_MISTAKES_GATE'):
        ENV.pop(key, None)
ENV['FM_HERDR_LAB_STATE_DIR'] = str(FIX / 'lab-state')
ENV['TMPDIR'] = str(FIX / 'tmp')
(FIX / 'tmp').mkdir(exist_ok=True)
requests = []
notes = set()
calls = set()
lock = threading.Lock()

def text(m):
    c = m.get('content')
    return c if isinstance(c, str) else ' '.join(p.get('text', '') for p in (c or []) if isinstance(p, dict))

class Model(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get('content-length', 0))))
        msgs = req.get('messages', [])
        tools = {t.get('function', {}).get('name'): t.get('function', {}) for t in req.get('tools', [])}
        users = [text(m) for m in msgs if m.get('role') == 'user']
        latest = users[-1] if users else ''
        alltext = ' '.join(text(m) for m in msgs)
        call = None
        key = ''
        if 'advise' in tools and 'ADVISOR-SEED-' in alltext:
            marker = alltext.split('ADVISOR-SEED-')[-1].split()[0]
            key = 'advisor-' + marker
            if key not in notes:
                notes.add(key)
                call = ('advise', {'note': 'IDLE-ADVISOR-NOTE-' + marker, 'severity': 'concern'})
        elif 'bash' in tools and 'FIRSTMATE WATCHER WAKE:' in latest:
            key = latest
            if key not in calls:
                calls.add(key)
                # Run the actual product drain and the exact acknowledgement it emits.
                command = 'out=$(bin/fm-wake-drain.sh 2>&1); printf "%s\\n" "$out"; ack=$(printf "%s\\n" "$out" | /usr/bin/awk \'/^WAKE_ACK_REQUIRED:/ { sub(/^.*run /, ""); print; exit }\'); [ -z "$ack" ] || bash -c "$ack"'
                call = ('bash', {'command': command})
        elif 'bash' in tools and latest.startswith('BUSY-SEED-'):
            key = latest
            if key not in calls:
                calls.add(key)
                call = ('bash', {'command': 'sleep 24; printf "BUSY-TURN-FINISHED\\n"'})
        row = {'time': time.time(), 'latest_user': latest, 'tool_call': call, 'tools': list(tools), 'messages': msgs}
        with lock:
            requests.append(row)
            with (EVID / 'omp-model-requests.jsonl').open('a') as f:
                f.write(json.dumps(row) + '\n')
        if call:
            name, args = call
            deltas = [{'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'call_' + str(len(requests)), 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(args)}}]}]
            finish = 'tool_calls'
        else:
            deltas = [{'role': 'assistant', 'content': 'ack'}]
            finish = 'stop'
        self.send_response(200)
        self.send_header('content-type', 'text/event-stream')
        self.end_headers()
        chunk = {'id': 'lab', 'object': 'chat.completion.chunk', 'created': int(time.time()), 'model': 'm1'}
        for delta in deltas + [{}]:
            body = dict(chunk, choices=[{'index': 0, 'delta': delta, 'finish_reason': None if delta else finish}])
            self.wfile.write(b'data: ' + json.dumps(body).encode() + b'\n\n')
        self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()

server = ThreadingHTTPServer(('127.0.0.1', 0), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()

def cmd(args, env=ENV, timeout=90, check=True):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if check and p.returncode:
        raise RuntimeError(f'{args}: exit {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p

def log(s):
    print(s, flush=True)
    with (EVID / 'live-wake-transcript.log').open('a') as f: f.write(s + '\n')

def wait_for(name, fn, seconds=60):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        result = fn()
        if result: return result
        time.sleep(.5)
    raise AssertionError('Timed out: ' + name)

session = cmd([HELPER, 'name', 'idle-wake-gate']).stdout.strip()
labenv = ENV.copy()
home = FIX / 'home'
agent = FIX / 'agent'
agent.mkdir(exist_ok=True)
cmd([ROOT / 'bin/fm-lab-home.sh', 'create', home])
labenv.update(FM_HOME=str(home), PI_CODING_AGENT_DIR=str(agent), FM_POLL='1', FM_SIGNAL_GRACE='0', FM_HEARTBEAT='3600', FM_OPEN_LOOPS_INTERVAL='3600')
(home / 'state/open-loops.json').write_text(json.dumps({'schema': 'fm-open-loops.v1', 'generated_epoch': int(time.time()), 'home': str(home), 'complete': True, 'rows': []}))
(agent / 'config.yml').write_text('setupVersion: 2\nmodelRoles:\n  default: lab/m1\n  tiny: lab/m1\n  advisor: lab/m1\n  vision: lab/m1\nadvisor:\n  enabled: true\n')
(agent / 'models.yml').write_text(f'providers:\n  lab:\n    baseUrl: http://127.0.0.1:{server.server_address[1]}/v1\n    apiKey: lab-key\n    api: openai-completions\n    models:\n      - id: m1\n        contextWindow: 200000\n        maxTokens: 4096\n')
pane = None
terminal = None
results = []

def lab(*args, check=True): return cmd([HELPER, 'run', session, *args], check=check)
def screen():
    p = lab('pane', 'read', pane, '--source', 'visible', check=False)
    try:
        body = json.loads(p.stdout)
        result = body.get('result', {})
        return result.get('text', result.get('content', p.stdout)) if isinstance(result, dict) else str(result)
    except Exception: return p.stdout

def capture(label):
    s = screen()
    (EVID / (label + '-pane.txt')).write_text(s)
    log(f'PANE {label}\n{s}')
    return s

def send(s, enter=False):
    lab('pane', 'send-text', pane, s)
    if enter:
        time.sleep(1)
        lab('pane', 'send-keys', pane, 'Enter')

def saw(marker, since=0):
    return any(marker in r['latest_user'] and 'advise' not in r['tools'] for r in requests[since:])

def drained():
    q = home / 'state/.wake-queue'
    return q.exists() and not q.read_text().strip()

def signal(name):
    (home / f'state/{name}.meta').write_text('')
    (home / f'state/{name}.status').write_text(f'done: {name} disposable lab result\n')
    log(f'Published {name}.status at {time.time()}')

def queued(name):
    q = home / 'state/.wake-queue'
    return q.exists() and name + '.status' in q.read_text()

def seed(name):
    send('ADVISOR-SEED-' + name + ' reply ack', True)
    wait_for('advisor note ' + name, lambda: 'IDLE-ADVISOR-NOTE-' + name in screen())
    time.sleep(4)
    capture('advisor-' + name)

try:
    log(cmd(['omp', '--version']).stdout.strip() + '; ' + cmd(['herdr', '--version']).stdout.strip())
    log('Isolated session: ' + session)
    cmd([HELPER, 'provision', session])
    response = json.loads(lab('workspace', 'create', '--cwd', str(ROOT), '--label', 'idle-wake-gate', '--no-focus').stdout)
    pane = response['result']['root_pane']['pane_id']
    # Real TUI; Herdr terminal control gives the pane a nonzero 40x220 grid.
    terminal = subprocess.Popen([str(HELPER), 'run', session, 'terminal', 'session', 'control', pane, '--cols', '220', '--rows', '40'], cwd=ROOT, env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    launch_env = ' '.join(shlex.quote(k + '=' + labenv[k]) for k in ('FM_HOME', 'PI_CODING_AGENT_DIR', 'FM_POLL', 'FM_SIGNAL_GRACE', 'FM_HEARTBEAT', 'FM_OPEN_LOOPS_INTERVAL'))
    extension = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / '.omp/extensions/fm-primary-omp-watch.ts')
    launch = f'printf "%s\\n" $$ > {shlex.quote(str(home / "state/.lock"))}; exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE {launch_env} LAB_OBSERVATION={shlex.quote(str(EVID / "live-context.jsonl"))} omp --model lab/m1 --no-extensions -e {shlex.quote(extension)} -e {shlex.quote(str(FIX / "observe.ts"))} --no-title --no-lsp --no-skills --no-rules --tools bash --auto-approve --thinking off'
    (FIX / 'launch.sh').write_text('#!/usr/bin/env bash\n' + launch + '\n')
    lab('pane', 'run', pane, 'bash ' + shlex.quote(str(FIX / 'launch.sh')))
    wait_for('watch extension loaded', lambda: (home / 'state/.omp-watch-extension-loaded').exists())
    wait_for('real watcher armed', lambda: (home / 'state/.watch.lock/pid').exists())
    time.sleep(3)
    capture('startup')
    log(lab('pane', '--help', check=False).stdout)

    seed('empty')
    begin = len(requests)
    signal('idleempty')
    wait_for('empty-composer wake starts model turn', lambda: saw('idleempty.status', begin), 35)
    wait_for('empty-composer queue drained by real omp bash tool', drained)
    time.sleep(3)
    capture('idle-empty-drained')
    results.append({'name': 'Idle advisor-tail wake starts and drains with an empty composer', 'result': 'pass', 'live': True})
    log('PASS idle-empty: no Enter or drain steer sent after status publication; real omp executed drain and acknowledgement.')

    seed('draft')
    send('UNSENT OPERATOR DRAFT 7e91')
    time.sleep(2)
    begin = len(requests)
    signal('idledraft')
    wait_for('draft-composer wake starts model turn', lambda: saw('idledraft.status', begin), 35)
    wait_for('draft-composer wake queue drained', drained)
    time.sleep(5)
    s = capture('idle-draft-drained')
    assert 'UNSENT OPERATOR DRAFT 7e91' in s, 'draft disappeared from composer'
    assert not any('UNSENT OPERATOR DRAFT 7e91' in ' '.join(text(m) for m in r['messages']) for r in requests), 'draft sent to model'
    results.append({'name': 'Idle advisor-tail wake drains without submitting or erasing an operator draft', 'result': 'pass', 'live': True})
    log('PASS idle-draft: queue empty, draft visible in composer and absent from every model request.')
    lab('pane', 'send-keys', pane, 'ctrl+u')
    time.sleep(2)

    begin = len(requests)
    send('BUSY-SEED-queue run the bounded wait', True)
    wait_for('busy sleep tool executing', lambda: any(r['tool_call'] and r['tool_call'][1].get('command', '').startswith('sleep 24') for r in requests[begin:]))
    time.sleep(2)
    signal('busyqueue')
    wait_for('busy wake in durable own queue', lambda: queued('busyqueue'), 15)
    wait_for('busy wake accepted in real omp pending-message queue', lambda: any(not r['idle'] and r['pending'] for r in [json.loads(line) for line in (EVID / 'live-context.jsonl').read_text().splitlines()]), 15)
    capture('busy-wake-queued')
    assert not saw('busyqueue.status', begin), 'wake submitted before busy turn yielded'
    wait_for('busy follow-up consumed after tool finishes', lambda: saw('busyqueue.status', begin), 60)
    wait_for('busy wake queue drained', drained)
    time.sleep(3)
    capture('busy-wake-drained')
    results.append({'name': 'Wake arriving during a running tool waits as a follow-up and then drains', 'result': 'pass', 'live': True})
    log('PASS busy follow-up: bounded tool finished, queued wake then consumed and acknowledged.')

    # The successor must continue serving later wakes without another arm call.
    begin = len(requests)
    signal('successor')
    wait_for('successor wake consumed', lambda: saw('successor.status', begin), 35)
    wait_for('successor wake drained', drained)
    time.sleep(6)
    capture('successor-drained')
    results.append({'name': 'Automatically rearmed watcher drains a subsequent idle wake without a manual ring', 'result': 'pass', 'live': True})
    log('PASS successor: subsequent status consumed without manual arm, Enter, or steer.')
    send('/export ' + str(EVID / 'omp-live-wakes.html'), True)
    wait_for('real omp rendered HTML export', lambda: (EVID / 'omp-live-wakes.html').exists(), 20)
    log('Real omp exported rendered transcript to omp-live-wakes.html.')
except Exception as exc:
    log('FAIL ' + str(exc))
    log(traceback.format_exc())
    if pane: capture('failure')
    results.append({'name': 'Live driver failure', 'result': 'fail', 'live': bool(pane), 'reason': str(exc)})
finally:
    for name in ('.wake-queue', '.watch-cycle-exits.log', '.watch-deliveries.log', '.watcher-down'):
        path = home / 'state' / name
        if path.exists() and path.is_file():
            (EVID / ('state-' + name.lstrip('.'))).write_bytes(path.read_bytes())
    if pane: lab('pane', 'close', pane, check=False)
    if terminal:
        terminal.terminate()
        try: terminal.wait(timeout=5)
        except subprocess.TimeoutExpired: terminal.kill(); terminal.wait()
    stop = cmd([ROOT / 'bin/fm-watch-arm.sh', '--stop'], env=labenv, check=False)
    log('Home-scoped watcher stop: ' + stop.stdout + stop.stderr)
    teardown = cmd([HELPER, 'teardown', session], check=False)
    log(f'Herdr teardown exit={teardown.returncode}: {teardown.stdout}{teardown.stderr}')
    server.shutdown()
    (EVID / 'scenario-results.json').write_text(json.dumps(results, indent=2))
    if teardown.returncode: sys.exit(2)
    sys.exit(0 if results and all(r['result'] == 'pass' for r in results) else 1)
