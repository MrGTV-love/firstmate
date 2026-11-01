#!/usr/bin/env python3
"""Private scripted Anthropic-Messages model for real Claude Code validation."""
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
lab = pathlib.Path(sys.argv[1])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, v, s=200):
        d = json.dumps(v).encode(); self.send_response(s)
        self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(d)))
        self.end_headers(); self.wfile.write(d)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        if self.path.split('?')[0].endswith('/messages/count_tokens'):
            return self._json({'input_tokens': 1})
        steps = json.loads((lab / 'steps.json').read_text())
        tools = {t.get('name') for t in body.get('tools', [])}
        if not ({'Write','Edit','Read'} & tools):   # side requests (titles etc.)
            return self._stream(body, [{'type':'text','text':'ok'}], 'end_turn')
        results = []
        for m in body['messages']:
            if isinstance(m.get('content'), list):
                results += [c for c in m['content'] if c.get('type') == 'tool_result']
        n = len(results)
        if n:
            r = results[-1]; c = r.get('content'); c = c if isinstance(c, str) else ''.join(x.get('text','') for x in c)
            done = (lab/'results.jsonl').read_text().count('\n') if (lab/'results.jsonl').exists() else 0
            if done < n:
                with (lab/'results.jsonl').open('a') as f:
                    f.write(json.dumps({'step': n, 'call': {'tool': steps[n-1]['tool'], 'args': {'path': steps[n-1]['args'].get('file_path')}}, 'result': c, 'is_error': r.get('is_error', False)})+'\n')
        if n < len(steps):
            s = steps[n]
            return self._stream(body, [{'type':'tool_use','id':f'toolu_{n}','name':s['tool'],'input':s['args']}], 'tool_use')
        return self._stream(body, [{'type':'text','text':'scripted-done'}], 'end_turn')
    def _stream(self, body, parts, stop):
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        def ev(n, v): self.wfile.write(('event: '+n+'\ndata: '+json.dumps(v)+'\n\n').encode())
        ev('message_start', {'type':'message_start','message':{'id':'msg_s','type':'message','role':'assistant','model':body.get('model'),'content':[],'stop_reason':None,'stop_sequence':None,'usage':{'input_tokens':1,'output_tokens':1}}})
        for i,p in enumerate(parts):
            if p['type']=='tool_use':
                ev('content_block_start',{'type':'content_block_start','index':i,'content_block':dict(p,input={})})
                ev('content_block_delta',{'type':'content_block_delta','index':i,'delta':{'type':'input_json_delta','partial_json':json.dumps(p['input'])}})
            else:
                ev('content_block_start',{'type':'content_block_start','index':i,'content_block':{'type':'text','text':''}})
                ev('content_block_delta',{'type':'content_block_delta','index':i,'delta':{'type':'text_delta','text':p['text']}})
            ev('content_block_stop',{'type':'content_block_stop','index':i})
        ev('message_delta',{'type':'message_delta','delta':{'stop_reason':stop,'stop_sequence':None},'usage':{'output_tokens':1}})
        ev('message_stop',{'type':'message_stop'}); self.wfile.flush()
s = ThreadingHTTPServer(('127.0.0.1',0),H)
(lab/'port').write_text(str(s.server_address[1]))
s.serve_forever()
