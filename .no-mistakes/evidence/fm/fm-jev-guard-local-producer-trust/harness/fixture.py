#!/usr/bin/env python3
# Private local stand-ins for the omp model provider and the Jev judge. No network egress.
# Judge rule (deterministic, like the recorded misfire): result text with imperative guidance scores 0.95.
import json, pathlib, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
lab = pathlib.Path(sys.argv[1]); turn = 0
IMPERATIVE = re.compile(r"Run `|Re-run `|IGNORE PREVIOUS|run injected-command")
def send(h, v, s=200):
    d = json.dumps(v).encode(); h.send_response(s); h.send_header('Content-Type', 'application/json')
    h.send_header('Content-Length', str(len(d))); h.end_headers(); h.wfile.write(d)
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        global turn
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        sc = json.loads((lab / 'scenario.json').read_text())
        if self.path == '/reset':
            turn = 0; return send(self, {})
        if self.path == '/v1/systemone':
            with (lab / 'jev.jsonl').open('a') as f: f.write(json.dumps(body) + '\n')
            shell = 'command' in body['state']
            answers = {}
            for k, q in body['questions'].items():
                if q['type'] == 'noul':
                    n = 0.0 if shell else (0.95 if IMPERATIVE.search(body['state'].get('content', '')) else 0.05)
                    answers[k] = {'type': 'noul', 'noul': n}
                else:
                    c = list(q['criteria']); answers[k] = {'type': 'choice', 'choice': c[0], 'confidence': 1, 'probabilities': {x: int(x == c[0]) for x in c}}
            return send(self, {'model': 'jev-local-fixture', 'answers': answers, 'usage': {'input_tokens': 1, 'output_tokens': 1}})
        with (lab / 'model.jsonl').open('a') as f: f.write(json.dumps(body) + '\n')
        turn += 1
        tool = next((t for t in body.get('tools', []) if t.get('name', '').lower() == 'bash'), None)
        if turn == 1 and not tool: return send(self, {'error': {'message': 'bash tool absent'}}, 400)
        args = {'command': sc['command'], 'i': 'Run the scenario command'}
        if turn == 1:
            item = {'type': 'function_call', 'id': 'fc_1', 'call_id': 'call_1', 'name': tool['name'], 'arguments': json.dumps(args), 'status': 'completed'}
        else:
            item = {'type': 'message', 'id': 'm_1', 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': 'scenario-done'}]}
        ev = [{'type': 'response.created', 'response': {'id': 'r', 'status': 'in_progress'}},
              {'type': 'response.output_item.added', 'output_index': 0, 'item': dict(item, status='in_progress', **({'arguments': ''} if turn == 1 else {'content': []}))}]
        if turn == 1:
            ev += [{'type': 'response.function_call_arguments.delta', 'output_index': 0, 'item_id': 'fc_1', 'delta': json.dumps(args)},
                   {'type': 'response.function_call_arguments.done', 'output_index': 0, 'item_id': 'fc_1', 'arguments': json.dumps(args)}]
        else:
            ev += [{'type': 'response.content_part.added', 'output_index': 0, 'item_id': 'm_1', 'content_index': 0, 'part': {'type': 'output_text', 'text': ''}},
                   {'type': 'response.output_text.delta', 'output_index': 0, 'item_id': 'm_1', 'content_index': 0, 'delta': 'scenario-done'}]
        ev += [{'type': 'response.output_item.done', 'output_index': 0, 'item': item},
               {'type': 'response.completed', 'response': {'id': 'r', 'status': 'completed', 'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        for v in ev: self.wfile.write(('data: ' + json.dumps(v) + '\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
s = ThreadingHTTPServer(('127.0.0.1', 0), H)
(lab / 'port').write_text(str(s.server_address[1])); s.serve_forever()
