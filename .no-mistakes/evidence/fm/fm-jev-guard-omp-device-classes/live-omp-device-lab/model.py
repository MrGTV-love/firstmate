#!/usr/bin/env python3
# Scripted local model: each turn emits the next planned tool call, logs every request.
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
lab = pathlib.Path(sys.argv[1])
state = {'turn': 0}
def send_json(h, v, status=200):
    d = json.dumps(v).encode(); h.send_response(status); h.send_header('Content-Type','application/json'); h.send_header('Content-Length',str(len(d))); h.end_headers(); h.wfile.write(d)
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        with (lab/'other.jsonl').open('a') as f: f.write(json.dumps({'method':'GET','path':self.path})+'\n')
        send_json(self, {}, 404)
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length',0)))
        try: body = json.loads(raw)
        except Exception: body = {'raw': raw.decode('utf8','replace')}
        if self.path == '/reset':
            state['turn'] = 0; return send_json(self, {})
        if self.path.startswith('/v1/systemone'):
            with (lab/'jev.jsonl').open('a') as f: f.write(json.dumps(body)+'\n')
            return send_json(self, {'error':'judge not expected in this lab'}, 500)
        if not self.path.startswith('/v1/responses'):
            with (lab/'other.jsonl').open('a') as f: f.write(json.dumps({'path':self.path,'body':body})+'\n')
            return send_json(self, {}, 404)
        with (lab/'model.jsonl').open('a') as f: f.write(json.dumps(body)+'\n')
        calls = json.loads((lab/'scenario.json').read_text())['calls']
        t = state['turn']; state['turn'] += 1
        if t < len(calls):
            c = calls[t]
            item = {'type':'function_call','id':f'fc_{t}','call_id':f'call_{t}','name':c['tool'],'arguments':json.dumps(c['args']),'status':'completed'}
        else:
            item = {'type':'message','id':'m_done','role':'assistant','status':'completed','content':[{'type':'output_text','text':'lab-done'}]}
        ev = [{'type':'response.created','response':{'id':f'r{t}','status':'in_progress'}},
              {'type':'response.output_item.added','output_index':0,'item':dict(item,status='in_progress',**({'arguments':''} if item['type']=='function_call' else {'content':[]}))}]
        if item['type']=='function_call':
            ev += [{'type':'response.function_call_arguments.delta','output_index':0,'item_id':item['id'],'delta':item['arguments']},
                   {'type':'response.function_call_arguments.done','output_index':0,'item_id':item['id'],'arguments':item['arguments']}]
        else:
            ev += [{'type':'response.content_part.added','output_index':0,'item_id':'m_done','content_index':0,'part':{'type':'output_text','text':''}},
                   {'type':'response.output_text.delta','output_index':0,'item_id':'m_done','content_index':0,'delta':'lab-done'}]
        ev += [{'type':'response.output_item.done','output_index':0,'item':item},
               {'type':'response.completed','response':{'id':f'r{t}','status':'completed','output':[item],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}}]
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        for v in ev: self.wfile.write(('data: '+json.dumps(v)+'\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
s = ThreadingHTTPServer(('127.0.0.1',0), H)
(lab/'port').write_text(str(s.server_address[1]))
s.serve_forever()
