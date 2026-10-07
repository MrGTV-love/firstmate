#!/usr/bin/env python3
"""Disposable fixture-assisted real omp TUI matrix; NOT a real Jev evaluation."""
import argparse
import fcntl
import hashlib
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import termios
import threading
import time
import uuid

SCENARIOS = ['large-read', 'ascii-cumulative', 'utf8-36', 'utf8-37', 'small-read',
             'utf8-36-x', 'utf8-37-x', 'small-error', 'small-bash', 'large-error',
             'large-bash', 'assistant-clipped', 'user-clipped', 'redacted', 'image',
             'unknown-context', 'session-removed', 'missing-host', 'no-credentials']
LABEL = 'fixture-assisted real omp runtime; not real Jev evaluation'
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)')
FIXTURE_KEY = 'fixture-typesafe-not-a-secret'


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    path.chmod(0o600)


def rows(path):
    if not path.exists():
        return []
    result = []
    for line in path.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # A reader can observe the last line while its producer is writing.
    return result


def sanitize(text):
    return text.replace(FIXTURE_KEY, '[fixture-credential-omitted]').replace('fixture-provider-not-a-secret', '[fixture-credential-omitted]')


class Terminal:
    def __init__(self, command, cwd, env, output):
        self.master, slave = pty.openpty()
        # Size BOTH endpoints before Popen/exec: unlike pty.fork then parent ioctl,
        # this cannot race the child's terminal initialization.
        size = struct.pack('HHHH', 35, 120, 0, 0)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, size)
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, size)
        self.initial_size = list(struct.unpack('HHHH', fcntl.ioctl(slave, termios.TIOCGWINSZ, bytes(8))))
        self.chunks = []
        self.failure = None
        self.stop = threading.Event()
        self.output = output

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        try:
            self.process = subprocess.Popen(command, cwd=cwd, env=env, stdin=slave,
                                            stdout=slave, stderr=slave,
                                            preexec_fn=controlling_terminal, close_fds=True)
        finally:
            os.close(slave)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        queries = b''
        query = re.compile(rb'\x1b\[(\??)6n|\x1b\[>c|\x1b\[c|\x1b\](10|11);\?(?:\x07|\x1b\\)')
        try:
            while not self.stop.is_set():
                if not select.select([self.master], [], [], .05)[0]:
                    continue
                try:
                    data = os.read(self.master, 65536)
                except OSError:
                    break
                if not data:
                    break
                self.chunks.append(data)
                queries += data
                while True:
                    match = query.search(queries)
                    if not match:
                        queries = queries[-64:]
                        break
                    token = match.group(0)
                    if token.startswith(b'\x1b]'):
                        response = b'\x1b]' + match.group(2) + b';rgb:0000/0000/0000\x1b\\'
                    elif b'6n' in token:
                        response = b'\x1b[?1;1R' if match.group(1) == b'?' else b'\x1b[1;1R'
                    elif token == b'\x1b[>c':
                        response = b'\x1b[>0;95;0c'
                    else:
                        response = b'\x1b[?1;2c'
                    os.write(self.master, response)
                    queries = queries[match.end():]
        except Exception as error:
            self.failure = repr(error)

    def clean(self):
        return ANSI.sub('', b''.join(self.chunks).decode('utf-8', 'replace'))

    def send(self, text):
        os.write(self.master, text.encode())

    def wait(self, predicate, timeout, label):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.failure:
                raise RuntimeError('PTY reader failed: ' + self.failure)
            if self.process.poll() is not None:
                raise RuntimeError(f'omp exited {self.process.returncode} while waiting for {label}: {self.clean()[-4000:]}')
            time.sleep(.025)
        raise TimeoutError(f'Timeout waiting for {label}: {self.clean()[-4000:]}')

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()  # Only the standalone child created by this driver.
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        time.sleep(.1)
        self.stop.set()
        self.reader.join(timeout=2)
        os.close(self.master)
        self.output.write_text(sanitize(b''.join(self.chunks).decode('utf-8', 'replace')))
        self.output.chmod(0o600)
        self.output.with_name('terminal-clean.log').write_text(sanitize(self.clean()))


def fixture_server(evidence):
    captured = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            response = {'model': 'jev-fixture', 'fixture': True,
                        'usage': {'input_tokens': 2000, 'output_tokens': 60, 'fixture': True},
                        'answers': {
                            'done': {'type': 'choice', 'choice': 'finished', 'probabilities': {'finished': 1, 'not_finished': 0, 'unclear': 0}, 'confidence': 1},
                            'shape': {'type': 'choice', 'choice': 'hands_on', 'probabilities': {'hands_on': 1, 'coordinating': 0, 'unclear': 0}, 'confidence': 1}}}
            try:
                body = json.loads(raw)
                capture = {'classification': LABEL, 'fixture': True, 'path': self.path,
                           'method': 'POST', 'body': body, 'bodyUtf8': sanitize(raw.decode()),
                           'bodyBytes': len(raw), 'bodySha256': hashlib.sha256(raw).hexdigest(),
                           'headers': {'content-type': self.headers.get('Content-Type'), 'authorization': '[fixture-credential-omitted]'},
                           'response': response}
                captured.append(capture)
                save(evidence / 'http-requests.json', captured)
                if self.path != '/v1/systemone':
                    self.send_error(404)
                    return
                encoded = json.dumps(response).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
            except Exception as error:
                captured.append({'fixture': True, 'error': repr(error)})
                save(evidence / 'http-requests.json', captured)
                self.send_error(500)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    save(evidence / 'http-requests.json', captured)
    return server, thread, captured


def assert_evidence(manifest, metrics, events, captured, native):
    checks = []

    def check(condition, label):
        if not condition:
            raise AssertionError(label)
        checks.append(label)

    check(any(e.get('event') == 'pipeline-loaded' for e in metrics), 'actual pipeline static entry loaded')
    check(any(e.get('event') == 'runtime-start' and e.get('mode') == 'tui' for e in events), 'actual host mode is tui')
    terminal_calls = [e for e in events if e.get('event') == 'provider' and not e.get('summary')]
    check(len(terminal_calls) == 1 and terminal_calls[0]['responseText'] == manifest['finalAnswer'], 'exact 18-byte final answer emitted once')
    branches = [e['entries'] for e in events if e.get('event') == 'native-branch-before-checkpoint']
    check(bool(branches) and any(e.get('message', {}).get('role') == 'assistant' and
                               e['message'].get('content') == [{'type': 'text', 'text': manifest['finalAnswer']}] for e in branches[0]), 'final answer persisted in native branch')
    compactions = [e for e in native if e.get('type') == 'compaction']
    if manifest['positive']:
        check(len(captured) == 1, 'one genuine loopback HTTP request')
        request = captured[0]
        check(request['path'] == '/v1/systemone' and request['response']['model'] == 'jev-fixture', 'HTTP fixture schema explicitly labelled')
        state = request['body']['state']
        recent = state['recent']
        roles = [{k: e[k] for k in ('role', 'tool', 'error') if k in e} for e in recent]
        check(roles == manifest['expectedRecent'], 'no recent role entries dropped or reordered')
        check(recent[-1]['text'] == manifest['finalAnswer'], 'final answer preserved verbatim in HTTP payload')
        check(state['coverage']['recentTextTruncated'] is False, 'coverage is complete')
        count = sum('sha256 ' in e['text'] for e in recent if e['role'] == 'toolResult')
        check(count == manifest['expectedAttested'], 'exact attested result count')
        start = next(e for e in metrics if e['event'] == 'judge-start')
        check(start['attestedResults'] == manifest['expectedAttested'], 'metrics match attested count')
        if count:
            check(state['coverage']['recentBulkAttested'] == count, 'payload coverage attestation count matches')
        tools = [e for e in recent if e['role'] == 'toolResult']
        check(len(tools) == len(manifest['reads']), 'every seeded tool result retained')
        for entry, read in zip(tools, manifest['reads']):
            if 'sha256 ' in entry['text']:
                check(f"{read['bytes']} bytes" in entry['text'] and f"{read['lines']} lines" in entry['text'] and f"sha256 {read['sha256']}" in entry['text'], 'full read digest, size and lines: ' + read['id'])
            else:
                check(entry['text'] == read['text'], 'unattested tool body preserved: ' + read['id'])
            check('\ufffd' not in entry['text'], 'no UTF8 replacement corruption: ' + read['id'])
        check(not any(e['event'] == 'coverage-ineligible' for e in metrics), 'positive checkpoint not coverage-ineligible')
        check(any(e['event'] == 'judgment' and e['finished'] for e in metrics), 'fixture qualifying judgment recorded')
    else:
        check(len(captured) == 0, 'zero HTTP requests for ineligible/configuration scenario')
        if manifest['nativeOnly']:
            check(any(e['event'] == 'checkpoint-ineligible' and e.get('reason') == 'configuration' for e in metrics), 'no-credential configuration safely ineligible')
            check(any(e['event'] == 'native-precedence' for e in metrics), 'manual native compaction has precedence without credentials')
        else:
            check(any(e['event'] == 'coverage-ineligible' for e in metrics), 'incomplete checkpoint coverage-ineligible')
            check(not compactions and not any(e['event'] in ('checkpoint-compact', 'native-persisted') for e in metrics), 'rejected checkpoint never compacted')
    if manifest['positive'] or manifest['nativeOnly']:
        check(bool(compactions), 'native session file contains persisted compaction')
        check(all(e.get('fromExtension') is False for e in compactions), 'compaction persisted by native host, not an extension override')
        check(all(e.get('method') in ('soft', 'snapcompact', 'remote', 'handoff', 'context-full', 'shake') for e in compactions), 'host selected and persisted its runnable native method')
        check(any(e['event'] == 'native-persisted' for e in metrics), 'pipeline observes native persisted compaction')
    if manifest['removeSession']:
        check(any(e['event'] == 'session-file-removed-after-load' for e in events), 'actual loaded session file removed after final persistence')
        check(any('transcript-unrecoverable' in e.get('reasons', []) for e in metrics), 'missing file rejects transcript recovery')
    return checks


def run_scenario(args, scenario, run_id):
    repo = Path(__file__).resolve().parent.parent
    work = repo / '.validation-jev' / 'live' / run_id / scenario
    evidence = args.evidence / ('live-driver-' + run_id) / scenario
    work.mkdir(parents=True, exist_ok=False)
    evidence.mkdir(parents=True, exist_ok=False)
    for name in ('home', 'agent', 'xdg-config', 'xdg-cache', 'xdg-data', 'tmp'):
        (work / name).mkdir()
    env = {'PATH': os.environ['PATH'], 'HOME': str(work / 'home'), 'PI_CODING_AGENT_DIR': str(work / 'agent'),
           'XDG_CONFIG_HOME': str(work / 'xdg-config'), 'XDG_CACHE_HOME': str(work / 'xdg-cache'),
           'XDG_DATA_HOME': str(work / 'xdg-data'), 'TMPDIR': str(work / 'tmp'),
           'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8', 'LC_ALL': 'en_US.UTF-8',
           'FM_JEV_OMP_PIPELINE': '1', 'FM_JEV_PIPELINE_AGENT_DIR': str(work / 'agent'),
           'FM_JEV_PIPELINE_METRICS': str(evidence / 'pipeline-metrics.jsonl'),
           'JEV_LIVE_EVENTS': str(evidence / 'runtime-events.jsonl'), 'COMPACT_ADVISER_DISABLE': '0'}
    result = {'scenario': scenario, 'classification': LABEL, 'fixture': True, 'ok': False,
              'workDirectory': str(work), 'evidenceDirectory': str(evidence)}
    terminal = None
    server = None
    captured = []
    manifest = None
    native = []
    try:
        seed = subprocess.run([args.bun, str(repo / '.validation-jev' / 'jev-live-seed.ts'), scenario, str(work)],
                              cwd=repo, env=env, text=True, capture_output=True, timeout=60)
        (evidence / 'seed-output.log').write_text(sanitize(seed.stdout + seed.stderr))
        if seed.returncode:
            raise RuntimeError(f'Native SDK seed failed: {seed.stderr}')
        manifest = json.loads((work / 'manifest.json').read_text())
        save(evidence / 'manifest.json', manifest)
        shutil.copyfile(work / 'seed-native-entries.json', evidence / 'seed-native-entries.json')
        shutil.copyfile(manifest['sessionFile'], evidence / 'seed-session.jsonl')
        save(work / 'agent' / 'compact-adviser.json', {'version': 1, 'mode': 'auto', 'autoAcknowledged': True, 'minContextTokens': 40000, 'logRequests': False})
        # Keep unrelated host automatic compaction away from rejected checkpoints.
        (work / 'agent' / 'config.yml').write_text('compaction:\n  thresholdTokens: 200000\n')
        server, server_thread, captured = fixture_server(evidence)
        env['TYPESAFE_BASE'] = f'http://127.0.0.1:{server.server_address[1]}'
        if not manifest['nativeOnly']:
            env['TYPESAFE_API_KEY'] = FIXTURE_KEY
        if manifest['removeSession']:
            env['JEV_LIVE_REMOVE_SESSION'] = '1'
        entry = repo / '.validation-jev' / 'jev-live-missing-host.mjs' if manifest['missingHost'] else args.entry
        command = [args.omp, '--no-extensions', '-e', str(args.runtime), '-e', str(entry),
                   '--no-skills', '--no-rules', '--no-tools', '--no-lsp', '--no-title',
                   '--model', 'jev-live-fixture/local', '--thinking', 'off', '--resume', manifest['sessionFile'],
                   '--session-dir', str(work / 'sessions')]
        save(evidence / 'invocation.json', {'classification': LABEL, 'command': command, 'cwd': str(work),
                                         'env': {k: '[fixture-credential-omitted]' if k == 'TYPESAFE_API_KEY' else v for k, v in env.items()}})
        terminal = Terminal(command, work, env, evidence / 'terminal.log')
        result['ptySizeBeforeExec'] = terminal.initial_size
        terminal.wait(lambda: any(e.get('event') == 'runtime-start' and e.get('mode') == 'tui' for e in rows(evidence / 'runtime-events.jsonl'))
                      and 'Jev live fixture provider' in terminal.clean(), args.timeout, 'real TUI prompt/footer and runtime-start')
        terminal.send('Finish fixture turn.\r')
        metrics_path = evidence / 'pipeline-metrics.jsonl'
        if manifest['positive']:
            terminal.wait(lambda: any(e['event'] == 'native-persisted' for e in rows(metrics_path)), args.timeout, 'fixture judged checkpoint and native persisted compaction')
        elif manifest['nativeOnly']:
            terminal.wait(lambda: any(e['event'] == 'checkpoint-ineligible' for e in rows(metrics_path)), args.timeout, 'credential-free native checkpoint')
            terminal.send('/compact\r')
            terminal.wait(lambda: any(e['event'] == 'native-persisted' for e in rows(metrics_path)), args.timeout, 'manual native compaction without Jev credentials')
        else:
            terminal.wait(lambda: any(e['event'] == 'coverage-ineligible' for e in rows(metrics_path)), args.timeout, 'coverage-ineligible checkpoint')
        # Reader continues draining while waiting; prove zero-request cases remain quiet.
        time.sleep(1)
    except Exception as error:
        result['error'] = str(error)
    finally:
        if terminal:
            terminal.close()
            result['ompExitAfterDriverStop'] = terminal.process.returncode
        if server:
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=2)
        save(evidence / 'http-requests.json', captured)
        metrics = rows(evidence / 'pipeline-metrics.jsonl')
        events = rows(evidence / 'runtime-events.jsonl')
        if manifest:
            session = Path(manifest['sessionFile'])
            if session.exists():
                native = rows(session)
                shutil.copyfile(session, evidence / 'native-session.jsonl')
            else:
                branches = [e['entries'] for e in events if e.get('event') == 'native-branch-before-checkpoint']
                native = branches[-1] if branches else []
                result['sessionFileAbsentAfterLoad'] = True
            save(evidence / 'native-session-entries.json', native)
        save(evidence / 'pipeline-metrics.json', metrics)
        result['metricsEvents'] = [e.get('event') for e in metrics]
        result['httpRequests'] = len(captured)
        result['nativeCompactions'] = sum(e.get('type') == 'compaction' for e in native)
        if 'error' not in result:
            try:
                result['assertions'] = assert_evidence(manifest, metrics, events, captured, native)
                result['ok'] = True
            except Exception as error:
                result['error'] = str(error)
        save(evidence / 'result.json', result)
    return result


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario', action='append', choices=SCENARIOS, help='Repeat to select cases; default runs full matrix')
    parser.add_argument('--exclude', action='append', choices=SCENARIOS, default=[])
    parser.add_argument('--omp', default=shutil.which('omp'))
    parser.add_argument('--bun', default=shutil.which('bun'))
    parser.add_argument('--entry', type=Path, default=repo / '.fm-adviser-root' / 'omp-jev-entry.mjs')
    parser.add_argument('--runtime', type=Path, default=repo / '.fm-adviser-root' / 'jev-live-runtime.ts')
    parser.add_argument('--evidence', type=Path, default=Path('/Users/charlesabrooker/.no-mistakes/evidence/01M49Z3HDRT372QCEKK8ARM4G3'))
    parser.add_argument('--timeout', type=float, default=120)
    args = parser.parse_args()
    if not args.omp or not args.bun or not args.entry.is_file() or not args.runtime.is_file():
        parser.error('Need real omp and Bun on PATH, actual static entry copy, and runtime copy beside installed SDK dependencies')
    args.entry = args.entry.resolve()
    args.runtime = args.runtime.resolve()
    args.evidence = args.evidence.resolve()
    run_id = uuid.uuid4().hex[:12]
    results = []
    for scenario in args.scenario or SCENARIOS:
        if scenario in args.exclude:
            continue
        result = run_scenario(args, scenario, run_id)
        results.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    combined = {'classification': LABEL, 'fixture': True, 'realJevEvaluation': False, 'runId': run_id,
                'ok': bool(results) and all(r['ok'] for r in results), 'results': results}
    args.evidence.mkdir(parents=True, exist_ok=True)
    path = args.evidence / f'live-driver-results-{run_id}.json'
    save(path, combined)
    print(json.dumps({'combinedResult': str(path), 'ok': combined['ok']}), flush=True)
    raise SystemExit(0 if combined['ok'] else 1)


if __name__ == '__main__':
    main()
