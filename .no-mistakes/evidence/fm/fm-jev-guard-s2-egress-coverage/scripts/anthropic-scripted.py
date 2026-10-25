# Private scripted Anthropic Messages provider: turn 1 calls scenario.tool with scenario.args, turn 2 ends.
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
lab = pathlib.Path(sys.argv[1])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        if not self.path.startswith('/v1/messages') or self.path.startswith('/v1/messages/count_tokens'):
            data = json.dumps({'input_tokens': 1}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        with (lab / 'model.jsonl').open('a') as f: f.write(json.dumps(body) + '\n')
        sc = json.loads((lab / 'scenario.json').read_text())
        msgs = body.get('messages', [])
        has_result = any(isinstance(m.get('content'), list) and any(b.get('type') == 'tool_result' for b in m['content']) for m in msgs)
        names = [t.get('name') for t in body.get('tools', [])]
        (lab / 'tools-offered.json').write_text(json.dumps(names))
        first = not has_result and sc['tool'] in names
        msg = {'id': 'msg_s', 'type': 'message', 'role': 'assistant', 'model': body.get('model', 'x'), 'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}}
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        def ev(n, v): self.wfile.write(('event: ' + n + '\ndata: ' + json.dumps(v) + '\n\n').encode())
        ev('message_start', {'type': 'message_start', 'message': msg})
        if first:
            ev('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 'toolu_s1', 'name': sc['tool'], 'input': {}}})
            ev('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(sc['args'])}})
        else:
            ev('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
            ev('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'scripted-done' if has_result else 'tool-not-offered'}})
        ev('content_block_stop', {'type': 'content_block_stop', 'index': 0})
        ev('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use' if first else 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 1}})
        ev('message_stop', {'type': 'message_stop'})
        self.wfile.flush()
s = ThreadingHTTPServer(('127.0.0.1', 0), H)
(lab / 'port').write_text(str(s.server_address[1]))
s.serve_forever()
