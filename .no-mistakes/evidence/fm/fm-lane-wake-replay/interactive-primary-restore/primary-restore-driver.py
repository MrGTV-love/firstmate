import json, os, pathlib, shlex, shutil, signal, subprocess, tempfile, threading, time, traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path('/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4FKBPP79Q9T9PVBFG7F1ETZ')
EVIDENCE = pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4FKBPP79Q9T9PVBFG7F1ETZ/interactive-primary-restore')
EVIDENCE.mkdir(parents=True, exist_ok=True)
transcript = (EVIDENCE / 'transcript.log').open('w')
lab = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab-primary-restore-', dir='/tmp'))
socket_dir = None
server = None
longturn_release = threading.Event()
model_calls = []
result = {'verdict': 'inconclusive', 'attempts': 1, 'lab': str(lab), 'scenario': 'Interactive primary restores tracked wake, uses current owed rows, and preserves operator draft', 'product_changes': False, 'limitations': ['Local scripted model; only watcher extension loaded; vendor follow-up stimulus is fixture-only.']}
base = {k: os.environ[k] for k in ('PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'LANG', 'TMPDIR') if k in os.environ}
base.update(FM_HOME=str(lab), TERM='xterm-256color', PI_CODING_AGENT_DIR=str(lab / 'agent'), FM_POLL='1', FM_SIGNAL_GRACE='0', FM_HEARTBEAT='600', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', DISABLE_AUTOUPDATER='1')

def run(args, *, env=None, check=True, timeout=30):
    transcript.write('$ ' + shlex.join(str(a) for a in args) + '\n'); transcript.flush()
    completed = subprocess.run([str(a) for a in args], cwd=ROOT, env=env or base, capture_output=True, text=True, timeout=timeout)
    transcript.write(f'exit={completed.returncode}\n{completed.stdout}{completed.stderr}\n'); transcript.flush()
    if check and completed.returncode:
        raise RuntimeError(f'{shlex.join(str(a) for a in args)} exited {completed.returncode}: {completed.stderr or completed.stdout}')
    return completed

def tmux(*args, **kwargs):
    return run(['tmux', '-L', 'fm-lab-primary-restore', *args], env=dict(base, TMUX_TMPDIR=socket_dir), **kwargs)

def screen(name):
    text = tmux('capture-pane', '-p', '-t', 'primary', '-S', '-150', check=False).stdout
    (EVIDENCE / f'{name}.screen.txt').write_text(text)
    return text

def events():
    path = lab / 'state/probe.jsonl'
    if not path.exists(): return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]

def wait_for(predicate, timeout, label):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(0.1)
    screen('failure')
    raise RuntimeError(f'Timed out waiting for {label}')

def touch(name):
    (lab / 'state' / name).touch()

def text(message):
    content = message.get('content')
    if isinstance(content, list): return ' '.join(p.get('text', '') for p in content if isinstance(p, dict))
    return content if isinstance(content, str) else ''

def drain_and_ack():
    drained = run(['bash', 'bin/fm-wake-drain.sh'])
    record = {'returncode': drained.returncode, 'stdout': drained.stdout, 'stderr': drained.stderr}
    ack = [line for line in drained.stderr.splitlines() if line.startswith('WAKE_ACK_REQUIRED:')]
    if ack:
        words = shlex.split(ack[0])
        run(['bash', 'bin/fm-wake-drain.sh', '--ack-through', words[words.index('--ack-through') + 1], '--recovery-generation', words[words.index('--recovery-generation') + 1]])
    return record

class Model(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        try:
            request = json.loads(self.rfile.read(int(self.headers.get('content-length', 0))) or b'{}')
            users = [text(m) for m in request.get('messages', []) if m.get('role') == 'user']
            last = users[-1] if users else ''
            entry = {'time': time.time(), 'last': last}
            model_calls.append(entry)
            if 'LONGTURN_PRIMARY_RESTORE' in last:
                longturn_release.wait(100)
            if 'FIRSTMATE WATCHER WAKE:' in last:
                entry['drain'] = drain_and_ack()
            self.send_response(200)
            self.send_header('content-type', 'text/event-stream')
            self.end_headers()
            chunk = {'id': 'primary-lab', 'object': 'chat.completion.chunk', 'created': int(time.time()), 'model': 'm1'}
            for delta in [{'role': 'assistant', 'content': 'ack'}, {}]:
                body = dict(chunk, choices=[{'index': 0, 'delta': delta, 'finish_reason': None if delta else 'stop'}])
                self.wfile.write(b'data: ' + json.dumps(body).encode() + b'\n\n')
            self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass
        except Exception as exc:
            model_calls.append({'error': str(exc)}); traceback.print_exc(file=transcript)

try:
    run(['bash', 'bin/fm-lab-home.sh', 'create', lab])
    socket_dir = run(['bash', 'bin/fm-lab-home.sh', 'tmux-dir', lab]).stdout.strip()
    result['socket_dir'] = socket_dir
    (lab / 'agent').mkdir()
    # The bridge supplies root/config overrides internally. Strip those at the
    # supported x-mode.env boundary so the arm uses the marked stock-layout home.
    (lab / 'config/x-mode.env').write_text('unset FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE\n')
    (lab / 'config/backend').write_text('tmux\n')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Model)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    (lab / 'agent/config.yml').write_text('setupVersion: 2\nmodelRoles:\n  default: lab/m1\n  tiny: lab/m1\n  advisor: lab/m1\n  vision: lab/m1\ncomposer:\n  shape: box\nplan:\n  defaultOnStartup: false\nprewalk:\n  enabled: false\n')
    (lab / 'agent/models.yml').write_text(f'providers:\n  lab:\n    baseUrl: http://127.0.0.1:{port}/v1\n    apiKey: lab-key\n    api: openai-completions\n    models:\n      - id: m1\n        contextWindow: 200000\n        maxTokens: 4096\n')
    omp = shutil.which('omp')
    result['omp_version'] = run([omp, '--version']).stdout.strip()
    launch = [omp, '--no-session', '--model', 'lab/m1', '--no-title', '--no-skills', '--no-rules', '--no-lsp', '--no-tools', '--no-extensions', '-e', ROOT / '.gate-primary-restore-probe.ts']
    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'primary', '-n', 'main', '-x', '260', '-y', '50', '-c', ROOT, '-e', f'FM_HOME={lab}', *launch)
    wait_for(lambda: any(e['kind'] == 'lock' and e['result'].get('code') == 0 and e['hasUI'] for e in events()), 45, 'real interactive primary acquiring its lock')
    wait_for(lambda: (lab / 'state/.watch.lock/pid').exists(), 45, 'real watcher lock')
    time.sleep(2)
    screen('ready')
    touch('capture-request')
    (lab / 'state/restoreprobe.meta').write_text('')
    (lab / 'state/restoreprobe.status').write_text('done: old restoration payload\n')
    capture = wait_for(lambda: json.loads((lab / 'state/captured.json').read_text()) if (lab / 'state/captured.json').exists() else None, 45, 'idle durable watcher wake capture')
    assert capture['idle'] is True and capture['options'] is None, capture
    queued_before = run(['bash', 'bin/fm-wake-drain.sh', '--queued']).stdout
    assert queued_before and 'restoreprobe.status' in capture['content'], capture
    result['captured'] = capture
    result['queued_before'] = queued_before
    tmux('send-keys', '-t', 'primary', '-l', 'LONGTURN_PRIMARY_RESTORE')
    tmux('send-keys', '-t', 'primary', 'Enter')
    wait_for(lambda: any('LONGTURN_PRIMARY_RESTORE' in e.get('last', '') for e in model_calls), 30, 'real primary busy turn')
    draft = 'OPERATOR DRAFT — do not submit'
    tmux('send-keys', '-t', 'primary', '-l', draft)
    time.sleep(0.5)
    touch('queue-request')
    queued = wait_for(lambda: next((e for e in events() if e['kind'] == 'vendor-queued'), None), 15, 'vendor follow-up accepted during busy turn')
    assert queued['idle'] is False and queued['pending'] is True and queued['editor'] == draft, queued
    queued_screen = screen('queued-and-draft')
    assert 'After yield' in queued_screen and 'FIRSTMATE WATCHER WAKE:' in queued_screen, queued_screen
    result['drained_old'] = drain_and_ack()
    new_payload = 'signal: CURRENT OWED RESTORATION PAYLOAD'
    run(['bash', '-c', '. bin/fm-wake-lib.sh && fm_wake_append signal restore-current "$1"', 'primary-restore', new_payload])
    owed = run(['bash', 'bin/fm-wake-drain.sh', '--queued']).stdout
    assert new_payload in owed and 'restoreprobe.status' not in owed, owed
    result['current_owed'] = owed
    tmux('send-keys', '-t', 'primary', 'Escape')
    wait_for(lambda: any(e['kind'] == 'editor-observed' and capture['content'] in e['text'] and draft in e['text'] for e in events()), 12, 'actual editor restoring the tracked wake with the operator draft')
    restored_write = wait_for(lambda: next((e for e in events() if e['kind'] == 'editor-write' and capture['content'] in e['before'] and e['text'] == draft), None), 12, 'production removing only the restored template')
    assert restored_write['idle'] is True and restored_write['pending'] is False, restored_write
    sent = wait_for(lambda: next((e for e in events() if e['kind'] == 'production-send' and new_payload in e['content']), None), 20, 'production injecting current owed payload')
    assert sent['editor'] == draft and sent['idle'] is True and sent['options'] is None, sent
    assert 'restoreprobe.status' not in sent['content'], sent
    wake_call = wait_for(lambda: next((e for e in model_calls if new_payload in e.get('last', '') and 'drain' in e), None), 20, 'current wake reaching the actual model interface with its matching drain')
    assert new_payload in wake_call['drain']['stdout'], wake_call
    longturn_release.set()
    wait_for(lambda: any(e['kind'] == 'agent-end' and e['editor'] == draft for e in events()), 15, 'primary ending its wake turn without submitting the draft')
    time.sleep(3)
    final_screen = screen('recovered-draft')
    assert draft in final_screen, final_screen
    assert all(draft not in e.get('last', '') for e in model_calls), model_calls
    wakes = [e for e in model_calls if 'FIRSTMATE WATCHER WAKE:' in e.get('last', '')]
    assert len(wakes) == 1, wakes
    assert run(['bash', 'bin/fm-wake-drain.sh', '--queued']).stdout == ''
    result.update(verdict='pass', reason='A real interactive primary removed the unchanged restored watcher text, preserved the exact operator draft, and delivered exactly one fresh wake backed by the current durable row.', draft=draft, recovery=restored_write, sent=sent, wake_turn=wake_call)
except Exception as exc:
    result['reason'] = str(exc)
    result['failure_type'] = 'scenario or setup failure; no product change made'
    traceback.print_exc(file=transcript)
    if socket_dir:
        try: screen('failure')
        except Exception: pass
finally:
    longturn_release.set()
    # Retain protocol/UI observations and home state before deleting the one lab.
    for name in ('probe.jsonl', '.wake-queue', '.watch-deliveries.log', '.watch-triage.log', '.watch-cycle-exits.log', '.watcher-down', '.omp-watch-extension-loaded', '.lock', 'captured.json', 'queued.json'):
        path = lab / 'state' / name
        if path.is_file(): shutil.copyfile(path, EVIDENCE / name.lstrip('.'))
    (EVIDENCE / 'model-calls.json').write_text(json.dumps(model_calls, indent=2, ensure_ascii=False))
    owned = []
    if socket_dir:
        try:
            pane = tmux('display-message', '-p', '-t', 'primary', '#{pane_pid}', check=False).stdout.strip()
            listing = subprocess.run(['ps', '-axo', 'pid=,ppid='], capture_output=True, text=True, check=True).stdout
            pairs = [tuple(map(int, line.split())) for line in listing.splitlines() if line.strip()]
            roots = {int(pane)} if pane.isdigit() else set()
            while True:
                added = {pid for pid, parent in pairs if parent in roots} - roots
                if not added: break
                roots |= added
            owned = sorted(roots)
            tmux('kill-server', check=False)
            time.sleep(1)
            for pid in owned:
                try: os.kill(pid, signal.SIGTERM)
                except ProcessLookupError: pass
            time.sleep(1)
            for pid in owned:
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
        except Exception as exc: result['cleanup_error'] = str(exc)
    if server: server.shutdown(); server.server_close()
    if (lab / '.fm-lab-home').exists():
        teardown = run(['bash', 'bin/fm-lab-home.sh', 'teardown', lab], check=False)
        result['teardown_exit'] = teardown.returncode
        if teardown.returncode: result['cleanup_error'] = teardown.stderr
    shutil.rmtree(lab)
    result['lab_removed'] = not lab.exists()
    result['socket_removed'] = not socket_dir or not pathlib.Path(socket_dir).exists()
    result['owned_pids'] = owned
    (EVIDENCE / 'verdict.json').write_text(json.dumps(result, indent=2, ensure_ascii=False))
    transcript.close()
    print(json.dumps(result, indent=2, ensure_ascii=False))
