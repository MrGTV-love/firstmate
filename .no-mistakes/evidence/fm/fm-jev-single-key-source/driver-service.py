import socketserver, ssl, threading, json, pathlib, time, socket, select
ROOT=pathlib.Path(__file__).parent
class API(socketserver.StreamRequestHandler):
    def handle(self):
        first=self.rfile.readline().decode().strip()
        if not first: return
        headers={}
        while True:
            line=self.rfile.readline().decode().strip()
            if not line: break
            k,v=line.split(':',1); headers[k.lower()]=v.strip()
        body=json.loads(self.rfile.read(int(headers.get('content-length','0'))))
        state=body.get('state',{})
        with lock:
            with (ROOT/'requests.jsonl').open('a') as f:
                f.write(json.dumps({'path':first,'authorization':headers.get('authorization'),'body':body,'time':time.time()})+'\n')
        mode=json.loads((ROOT/'mode.json').read_text()).get('mode','reject')
        if mode=='stall': time.sleep(65); return
        if mode=='error':
            payload=json.dumps({'error':'fixture service unavailable'}).encode(); status='400 Bad Request'
        else:
            answers={}
            for name,q in body.get('questions',{}).items():
                if q.get('type')=='noul':
                    answers[name]={'type':'noul','noul':0.99 if name in ('claims_done','verification_applies') and mode!='accept' else 0.01}
                else:
                    criteria=q.get('criteria',q.get('options',{}))
                    choices=list(criteria) if isinstance(criteria,dict) else criteria
                    choice='risky' if name=='risk' else 'complete' if name=='outcome' else 'default' if name=='rule' else choices[0] if choices else 'none'
                    answers[name]={'type':'choice','choice':choice,'confidence':0.99,'probabilities':{str(c):0.99 if c==choice else 0.001 for c in choices}}
            payload=json.dumps({'model':'jev-1.13.0','usage':{'input_tokens':100,'output_tokens':1},'answers':answers}).encode();status='200 OK'
        try:
            self.wfile.write(f'HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n'.encode()+payload)
        except (BrokenPipeError,ConnectionResetError): pass
class Proxy(socketserver.StreamRequestHandler):
    def handle(self):
        first=self.rfile.readline().decode().strip()
        if not first:return
        while self.rfile.readline().strip():pass
        if first.split()[0]!='CONNECT' or first.split()[1]!='api.typesafe.ai:443':
            self.wfile.write(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n');return
        remote=socket.create_connection(('127.0.0.1',api.server_address[1]))
        self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n');self.wfile.flush()
        try:
            while True:
                r,_,_=select.select([remote,self.connection],[],[],70)
                if not r:break
                for src in r:
                    data=src.recv(65536)
                    if not data:return
                    (self.connection if src is remote else remote).sendall(data)
        finally: remote.close()
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address=True
    daemon_threads=True
lock=threading.Lock()
api=Server(('127.0.0.1',0),API)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(ROOT/'cert.pem',ROOT/'cert-key.pem')
api.socket=ctx.wrap_socket(api.socket,server_side=True)
threading.Thread(target=api.serve_forever,daemon=True).start()
proxy=Server(('127.0.0.1',0),Proxy)
(ROOT/'service.json').write_text(json.dumps({'proxy_url':f'http://127.0.0.1:{proxy.server_address[1]}','ca_path':str((ROOT/'cert.pem').absolute())}))
(ROOT/'mode.json').write_text('{"mode":"reject"}')
print('JEV fixture proxy ready',flush=True)
proxy.serve_forever()
