#!/usr/bin/env python3
# Private scripted provider: model turn 1 issues one bash tool call from scenario.json; Jev answers destructive unless benign.
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
lab = pathlib.Path(sys.argv[1]); backend = sys.argv[2]; turn = 0
def send_json(h, v, status=200):
    d = json.dumps(v).encode(); h.send_response(status); h.send_header('Content-Type','application/json')
    h.send_header('Content-Length', str(len(d))); h.end_headers(); h.wfile.write(d)
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        global turn
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        if self.path.endswith('/messages/count_tokens'): return send_json(self, {'input_tokens': 1})
        sc = json.loads((lab/'scenario.json').read_text())
        if self.path == '/v1/systemone':
            with (lab/'jev.jsonl').open('a') as f: f.write(json.dumps(body)+'\n')
            ans = {}
            for k, q in body['questions'].items():
                if q['type'] == 'noul': ans[k] = {'type':'noul','noul': 0.0 if sc.get('benign') else 0.99}
                else:
                    ch = list(q['criteria']); pick = 'irreversible' if 'irreversible' in ch and not sc.get('benign') else ch[0]
                    ans[k] = {'type':'choice','choice':pick,'confidence':1,'probabilities':{c:int(c==pick) for c in ch}}
            return send_json(self, {'model':'jev-local','answers':ans,'usage':{'input_tokens':1,'output_tokens':1}})
        if self.path == '/reset': turn = 0; return send_json(self, {})
        with (lab/'model.jsonl').open('a') as f: f.write(json.dumps(body)+'\n')
        turn += 1
        tools = body.get('tools', [])
        tool = next((t for t in tools if t.get('name','').lower() == 'bash'), None)
        if turn == 1 and not tool: return send_json(self, {'error': {'message': 'bash tool absent'}}, 400)
        args = sc['args']
        if backend == 'claude':
            content = [{'type':'tool_use','id':'tool_del','name':tool['name'],'input':args}] if turn == 1 else [{'type':'text','text':'done'}]
            msg = {'id':'msg_del','type':'message','role':'assistant','model':body['model'],'content':[],'stop_reason':None,'stop_sequence':None,'usage':{'input_tokens':1,'output_tokens':1}}
            self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
            def ev(n, v): self.wfile.write(('event: '+n+'\ndata: '+json.dumps(v)+'\n\n').encode())
            ev('message_start', {'type':'message_start','message':msg}); p = content[0]
            ev('content_block_start', {'type':'content_block_start','index':0,'content_block': dict(p, input={}) if turn == 1 else dict(p, text='')})
            dl = {'type':'input_json_delta','partial_json':json.dumps(args)} if turn == 1 else {'type':'text_delta','text':p['text']}
            ev('content_block_delta', {'type':'content_block_delta','index':0,'delta':dl})
            ev('content_block_stop', {'type':'content_block_stop','index':0})
            ev('message_delta', {'type':'message_delta','delta':{'stop_reason':'tool_use' if turn == 1 else 'end_turn','stop_sequence':None},'usage':{'output_tokens':1}})
            ev('message_stop', {'type':'message_stop'})
        else:
            if turn == 1: item = {'type':'function_call','id':'fc_del','call_id':'call_del','name':tool['name'],'arguments':json.dumps(args),'status':'completed'}
            else: item = {'type':'message','id':'m_del','role':'assistant','status':'completed','content':[{'type':'output_text','text':'done'}]}
            evs = [{'type':'response.created','response':{'id':'r_del','status':'in_progress'}},
                   {'type':'response.output_item.added','output_index':0,'item':dict(item, status='in_progress', **({'arguments':''} if turn == 1 else {'content':[]}))}]
            if turn == 1:
                evs += [{'type':'response.function_call_arguments.delta','output_index':0,'item_id':'fc_del','delta':json.dumps(args)},
                        {'type':'response.function_call_arguments.done','output_index':0,'item_id':'fc_del','arguments':json.dumps(args)}]
            else:
                evs += [{'type':'response.content_part.added','output_index':0,'item_id':'m_del','content_index':0,'part':{'type':'output_text','text':''}},
                        {'type':'response.output_text.delta','output_index':0,'item_id':'m_del','content_index':0,'delta':'done'}]
            evs += [{'type':'response.output_item.done','output_index':0,'item':item},
                    {'type':'response.completed','response':{'id':'r_del','status':'completed','output':[item],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}}]
            self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
            for v in evs: self.wfile.write(('data: '+json.dumps(v)+'\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()
s = ThreadingHTTPServer(('127.0.0.1', 0), H); (lab/'port').write_text(str(s.server_address[1])); s.serve_forever()
