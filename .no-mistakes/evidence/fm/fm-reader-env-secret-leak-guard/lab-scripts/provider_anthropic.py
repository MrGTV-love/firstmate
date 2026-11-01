#!/usr/bin/env python3
"""Private scripted Anthropic-Messages provider for DSH: one shell tool call, then a final text. Local-only."""
import json, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
lab = Path(sys.argv[1])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{"data":[]}')
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        tools = body.get('tools') or []
        names = [t.get('name') for t in tools]
        tool = next((t for t in tools if re.fullmatch(r'(?i).*(bash|shell).*', t.get('name') or '') and 'command' in json.dumps(t.get('input_schema', {}))), None)
        seen = 'tool_result' in json.dumps(body.get('messages', ''))
        with open(lab / 'provider.log', 'a') as f:
            f.write(json.dumps({'path': self.path, 'tool_names': names[:30], 'chosen': tool and tool['name'], 'seen_result': seen, 'stream': body.get('stream'), 'harness_sent_fake_key': any('sentinel-not-a-secret' in v for v in self.headers.values()), 'header_names': sorted(self.headers.keys())}) + '\n')
        call = tool and not seen and (lab / 'cmd.txt').exists()
        msg = {'id': 'msg_1', 'type': 'message', 'role': 'assistant', 'model': body.get('model', 'm'), 'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}}
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        def ev(n, v): self.wfile.write(('event: ' + n + '\ndata: ' + json.dumps(v) + '\n\n').encode())
        ev('message_start', {'type': 'message_start', 'message': msg})
        if call:
            args = {'command': (lab / 'cmd.txt').read_text().strip(), 'description': 'Run the names-only probe'}
            ev('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 'toolu_1', 'name': tool['name'], 'input': {}}})
            ev('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(args)}})
        else:
            ev('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
            ev('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'scripted-done'}})
        ev('content_block_stop', {'type': 'content_block_stop', 'index': 0})
        ev('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use' if call else 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 1}})
        ev('message_stop', {'type': 'message_stop'}); self.wfile.flush()
s = ThreadingHTTPServer(('127.0.0.1', 0), H)
(lab / 'port').write_text(str(s.server_address[1]))
s.serve_forever()
