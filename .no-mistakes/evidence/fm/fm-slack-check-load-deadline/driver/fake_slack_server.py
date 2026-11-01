#!/usr/bin/env python3
"""Disposable local Slack Web API stand-in backed by the repo replay transcript.
Usage: fake_slack_server.py ROOT TRANSCRIPT STATE_DIR CONTROL_DIR
CONTROL_DIR/mode: ok | latency:<s> | stop:<s> | hang
CONTROL_DIR/client.pid: written by the client hook; used by stop mode.
"""
import json, os, signal, sys, threading, time, urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
root, transcript, state_dir, control = sys.argv[1:5]
sys.path.insert(0, str(Path(root) / 'bin'))
from fm_slack_replay import Replay
from fm_slack import SlackError
control = Path(control)
lock = threading.Lock()

def log(row):
    with open(control / 'server.jsonl', 'a') as out:
        out.write(json.dumps(row) + '\n')

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a):
        pass
    def do_POST(self):
        method = self.path.rsplit('/', 1)[-1]
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        fields = dict(urllib.parse.parse_qsl(body))
        for k, v in fields.items():
            try:
                fields[k] = json.loads(v)
            except ValueError:
                pass
        mode = (control / 'mode').read_text().strip() if (control / 'mode').exists() else 'ok'
        t0 = time.time()
        log({'event': 'request', 'method': method, 'mode': mode, 't': t0})
        if mode == 'hang':
            time.sleep(120)  # accept and stay silent
            return
        if mode == 'trickle':  # headers, then one body byte every 5 s, forever (each read < 10 s)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', '100000')
            self.end_headers()
            self.wfile.flush()
            try:
                for _ in range(120):
                    self.wfile.write(b' ')
                    self.wfile.flush()
                    time.sleep(5)
            except OSError:
                log({'event': 'trickle-client-gone', 'method': method, 'after_s': round(time.time() - t0, 3)})
            return
        if mode.startswith('latency:'):
            time.sleep(float(mode.split(':')[1]))
        with lock:
            replay = Replay(transcript, state_dir)
            try:
                data = replay.call(method, **fields)
            except SlackError as e:
                data = {'ok': False, 'error': str(e)}
            scopes = ','.join(sorted(replay.scopes))
        raw = json.dumps(data).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('x-oauth-scopes', scopes)
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()
        log({'event': 'reply', 'method': method, 'mode': mode, 'served_s': round(time.time() - t0, 3)})
        if mode.startswith('stop:'):
            secs = float(mode.split(':')[1])
            (control / 'mode').write_text('ok')
            pid = int((control / 'client.pid').read_text())
            def starve():
                time.sleep(0.2)
                os.kill(pid, signal.SIGSTOP)
                log({'event': 'SIGSTOP', 'pid': pid, 'seconds': secs})
                time.sleep(secs)
                os.kill(pid, signal.SIGCONT)
                log({'event': 'SIGCONT', 'pid': pid})
            threading.Thread(target=starve, daemon=True).start()

srv = ThreadingHTTPServer(('127.0.0.1', 0), H)
srv.daemon_threads = True
(control / 'port').write_text(str(srv.server_address[1]))
srv.serve_forever()
