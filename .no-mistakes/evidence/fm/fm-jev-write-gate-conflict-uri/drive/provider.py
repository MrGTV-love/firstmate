#!/usr/bin/env python3
"""Private scripted model for real-omp validation. Each turn emits the next tool call in
<lab>/steps.json via the OpenAI Responses stream, and records what the real omp returned."""
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
lab = pathlib.Path(sys.argv[1])
turn = 0
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, v, s=200):
        d = json.dumps(v).encode(); self.send_response(s)
        self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(d)))
        self.end_headers(); self.wfile.write(d)
    def do_POST(self):
        global turn
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        if self.path == '/reset':
            turn = 0; return self._json({})
        if self.path == '/v1/systemone':
            with (lab / 'jev.jsonl').open('a') as f: f.write(json.dumps(body) + '\n')
            return self._json({'error': 'no judgment expected'}, 402)
        steps = json.loads((lab / 'steps.json').read_text())
        outs = [i for i in body.get('input', []) if isinstance(i, dict) and i.get('type') == 'function_call_output']
        if turn > 0 and outs:
            o = outs[-1].get('output')
            with (lab / 'results.jsonl').open('a') as f:
                f.write(json.dumps({'step': turn, 'call': steps[turn-1], 'result': o}) + '\n')
        turn += 1
        if turn <= len(steps):
            s = steps[turn-1]
            names = {t.get('name','').lower(): t.get('name') for t in body.get('tools', [])}
            if s['tool'] not in names:
                return self._json({'error': {'message': 'tool absent: ' + s['tool'] + ' from ' + ','.join(names)}}, 400)
            a = json.dumps(s['args']); cid = f'call_{turn}'; fid = f'fc_{turn}'
            item = {'type':'function_call','id':fid,'call_id':cid,'name':names[s['tool']],'arguments':a,'status':'completed'}
            ev = [{'type':'response.created','response':{'id':f'r{turn}','status':'in_progress'}},
                  {'type':'response.output_item.added','output_index':0,'item':dict(item,status='in_progress',arguments='')},
                  {'type':'response.function_call_arguments.delta','output_index':0,'item_id':fid,'delta':a},
                  {'type':'response.function_call_arguments.done','output_index':0,'item_id':fid,'arguments':a}]
        else:
            item = {'type':'message','id':f'm{turn}','role':'assistant','status':'completed','content':[{'type':'output_text','text':'scripted-done'}]}
            ev = [{'type':'response.created','response':{'id':f'r{turn}','status':'in_progress'}},
                  {'type':'response.output_item.added','output_index':0,'item':dict(item,status='in_progress',content=[])},
                  {'type':'response.content_part.added','output_index':0,'item_id':item['id'],'content_index':0,'part':{'type':'output_text','text':''}},
                  {'type':'response.output_text.delta','output_index':0,'item_id':item['id'],'content_index':0,'delta':'scripted-done'}]
        ev += [{'type':'response.output_item.done','output_index':0,'item':item},
               {'type':'response.completed','response':{'id':f'r{turn}','status':'completed','output':[item],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}}]
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        for v in ev: self.wfile.write(('data: '+json.dumps(v)+'\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
s = ThreadingHTTPServer(('127.0.0.1',0),H)
(lab/'port').write_text(str(s.server_address[1]))
s.serve_forever()
