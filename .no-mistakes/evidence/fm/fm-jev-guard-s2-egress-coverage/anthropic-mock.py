#!/usr/bin/env python3
# Scripted Anthropic Messages mock: first turn asks for scenario tool, next turn ends.
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
lab = pathlib.Path(sys.argv[1])

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(404); self.end_headers()
    def do_HEAD(self):
        self.send_response(200); self.end_headers()
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        if self.path.endswith('/count_tokens'):
            d = b'{"input_tokens":1}'; self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(d))); self.end_headers(); self.wfile.write(d); return
        with (lab / 'model.jsonl').open('a') as f: f.write(json.dumps(body) + '\n')
        sc = json.loads((lab / 'scenario.json').read_text())
        names = [t.get('name') for t in body.get('tools', [])]
        msgs = body.get('messages', [])
        last = msgs[-1] if msgs else {}
        has_result = isinstance(last.get('content'), list) and any(isinstance(c, dict) and c.get('type') == 'tool_result' for c in last['content'])
        use_tool = sc['tool'] in names and not has_result
        msg = {'id': 'msg_t4', 'type': 'message', 'role': 'assistant', 'model': body.get('model', 'x'), 'content': [],
               'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}}
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        def ev(n, v): self.wfile.write(('event: ' + n + '\ndata: ' + json.dumps(v) + '\n\n').encode())
        ev('message_start', {'type': 'message_start', 'message': msg})
        if use_tool:
            ev('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 'toolu_t4', 'name': sc['tool'], 'input': {}}})
            ev('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(sc['input'])}})
        else:
            ev('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
            ev('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 't4-done'}})
        ev('content_block_stop', {'type': 'content_block_stop', 'index': 0})
        ev('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use' if use_tool else 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 1}})
        ev('message_stop', {'type': 'message_stop'})
        self.wfile.flush()

s = ThreadingHTTPServer(('127.0.0.1', 0), H)
(lab / 'port').write_text(str(s.server_address[1]))
s.serve_forever()
