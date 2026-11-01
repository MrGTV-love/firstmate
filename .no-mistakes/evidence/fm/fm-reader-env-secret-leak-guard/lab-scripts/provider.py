#!/usr/bin/env python3
"""Private scripted openai-responses provider: one bash tool call, then a final text. Local-only, no real model."""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
lab = Path(sys.argv[1])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{"data":[]}')
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        text = json.dumps(body.get('input', ''))
        tools = {t.get('name') for t in body.get('tools', []) or []}
        with open(lab / 'provider.log', 'a') as f:
            f.write(json.dumps({'path': self.path, 'bash_tool': 'bash' in tools, 'has_output': 'function_call_output' in text}) + '\n')
        call = 'bash' in tools and 'function_call_output' not in text and (lab / 'cmd.txt').exists()
        if call:
            args = json.dumps({'command': (lab / 'cmd.txt').read_text().strip(), 'timeout': 200})
            item = {'type': 'function_call', 'id': 'fc_1', 'call_id': 'call_1', 'name': 'bash', 'arguments': args, 'status': 'completed'}
            ev = [{'type': 'response.created', 'response': {'id': 'r1', 'status': 'in_progress'}},
                  {'type': 'response.output_item.added', 'output_index': 0, 'item': dict(item, status='in_progress', arguments='')},
                  {'type': 'response.function_call_arguments.delta', 'output_index': 0, 'item_id': 'fc_1', 'delta': args},
                  {'type': 'response.function_call_arguments.done', 'output_index': 0, 'item_id': 'fc_1', 'arguments': args}]
        else:
            item = {'type': 'message', 'id': 'm1', 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': 'scripted-done'}]}
            ev = [{'type': 'response.created', 'response': {'id': 'r1', 'status': 'in_progress'}},
                  {'type': 'response.output_item.added', 'output_index': 0, 'item': dict(item, status='in_progress', content=[])},
                  {'type': 'response.content_part.added', 'output_index': 0, 'item_id': 'm1', 'content_index': 0, 'part': {'type': 'output_text', 'text': ''}},
                  {'type': 'response.output_text.delta', 'output_index': 0, 'item_id': 'm1', 'content_index': 0, 'delta': 'scripted-done'}]
        ev += [{'type': 'response.output_item.done', 'output_index': 0, 'item': item},
               {'type': 'response.completed', 'response': {'id': 'r1', 'status': 'completed', 'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        for v in ev: self.wfile.write(('data: ' + json.dumps(v) + '\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
s = ThreadingHTTPServer(('127.0.0.1', 0), H)
(lab / 'port').write_text(str(s.server_address[1]))
s.serve_forever()
