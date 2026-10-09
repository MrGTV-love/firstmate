import copy, hashlib, http.server, json, socketserver, ssl, threading, time
from graphql_selection import response_fields, project
import re

class Forge:
    def __init__(self, directory):
        self.directory = directory
        self.resources = {}
        self.requests = []
        self.barriers = []
        self.lock = threading.Lock()
        self.rate = {'limit':5000,'remaining':4000,'reset':int(time.time())+3600,'resource':'core'}
        self.pr = {'id':'PR_lab','number':8,'url':'https://github.com/o/r/pull/8','state':'OPEN',
          'mergedAt':None,'isDraft':False,'headRefOid':'a'*40,'headRefName':'fm/lab','baseRefName':'main',
          'author':{'login':'author','__typename':'User'},'mergeable':'MERGEABLE','reviewDecision':'CHANGES_REQUESTED',
          'statusCheckRollup':{'contexts':{'nodes':[],'pageInfo':{'hasNextPage':False,'endCursor':None}}},
          'headRef':{'name':'fm/lab','target':{'oid':'a'*40}},'baseRef':{'name':'main'},
          'baseRepository':{'name':'r','owner':{'login':'o'},'defaultBranchRef':{'name':'main'}},
          'headRepository':{'name':'r','owner':{'login':'o'}}}
        self.pr['commits']={'nodes':[{'commit':{'oid':'a'*40,'statusCheckRollup':self.pr['statusCheckRollup']}}]}
        forge = self
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *args): pass
            def do_CONNECT(self):
                if self.path not in ('api.github.com:443','github.com:443'):
                    self.send_error(403); return
                self.send_response(200, 'Connection established'); self.end_headers()
                self.wfile.flush()
                self.connection = forge.context.wrap_socket(self.connection, server_side=True)
                self.rfile = self.connection.makefile('rb', -1)
                self.wfile = self.connection.makefile('wb', 0)
                self.close_connection = False
            def do_GET(self): self.answer()
            def do_POST(self): self.answer()
            def answer(self):
                request_body = self.rfile.read(int(self.headers.get('Content-Length','0'))).decode()
                with forge.lock:
                    resource = copy.deepcopy(forge.resources.get(self.path))
                    rate = copy.deepcopy(forge.rate)
                    barrier = None
                    for b in forge.barriers:
                        if b['path'] == self.path and not b['claimed']:
                            b['claimed'] = True; barrier = b; break
                    record = {'method':self.command,'path':self.path,'conditional':self.headers.get('If-None-Match'),
                              'request_body':request_body or None,'rate':rate}
                    forge.requests.append(record)
                if self.path == '/graphql':
                    query = json.loads(request_body)
                    if 'mutation' in query.get('query','').lower():
                        status, body, headers = 403, {'message':'writes forbidden in lab'}, {}
                    else:
                        repo = {'pullRequest':copy.deepcopy(forge.pr), 'name':'r','owner':{'login':'o'},
                          'defaultBranchRef':{'name':'main'},'branchProtectionRules':{'nodes':[]}}
                        text=query['query']
                        if '__type(' in text:
                            names=['statusCheckRollup','contexts','nodes','pageInfo','workflowRun','workflow','name','event','isRequired']
                            data={alias:{'fields':[{'name':n} for n in names]} for alias in re.findall(r'(\w+):\s*__type\(',text)}
                        else:
                            data=project({'repository':repo,'viewer':{'login':'lab'},'node':copy.deepcopy(forge.pr)},response_fields(text))
                        body = {'data':data}
                        status, headers = 200, {}
                elif resource is None:
                    status, body, headers = 404, {'message':'unconfigured isolated endpoint'}, {}
                else:
                    status, body = resource.get('status',200), resource['body']
                    headers = {}
                    rate.update(resource.get('rate',{}))
                    if status == 200:
                        etag = '"'+hashlib.sha256(json.dumps(body,sort_keys=True).encode()).hexdigest()[:16]+'"'
                        headers['ETag'] = etag
                        if record['conditional'] == etag:
                            status = 304
                            if not resource.get('omit_link_304'):
                                headers.update(resource.get('headers',{}))
                        else:
                            headers.update(resource.get('headers',{}))
                    headers.update({'X-RateLimit-'+key.title():str(value) for key,value in rate.items()})
                record.update(status=status,etag=headers.get('ETag'),link=headers.get('Link'),response_body=body,rate=rate)
                if barrier:
                    barrier['ready'].set()
                    if not barrier['release'].wait(15): raise RuntimeError('lab barrier timed out')
                if resource and resource.get('delay'): time.sleep(resource['delay'])
                payload = b'' if status == 304 else json.dumps(body).encode()
                self.send_response(status)
                for name,value in headers.items(): self.send_header(name,value)
                self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(payload)))
                self.send_header('Connection','close')
                self.end_headers()
                try: self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError): pass
                self.close_connection = True
        class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(str(directory/'cert.pem'),str(directory/'key.pem'))
        self.server = Server(('127.0.0.1',0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()
    def put(self,path,body,**extra):
        with self.lock: self.resources[path] = {'body':body,**extra}
    def pause(self,path):
        b = {'path':path,'claimed':False,'ready':threading.Event(),'release':threading.Event()}
        with self.lock: self.barriers.append(b)
        return b
    def close(self):
        for b in self.barriers: b['release'].set()
        self.server.shutdown(); self.server.server_close(); self.thread.join()
