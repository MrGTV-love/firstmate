#!/usr/bin/env python3
# Minimal stdio language server for .fmprobe files; logs every message it receives.
import json, sys, pathlib
log = pathlib.Path(sys.argv[1])
def read():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line: sys.exit(0)
        line = line.decode().strip()
        if not line: break
        k, v = line.split(':', 1); headers[k.lower()] = v.strip()
    return json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
def send(msg):
    d = json.dumps(msg).encode(); sys.stdout.buffer.write(b'Content-Length: %d\r\n\r\n' % len(d) + d); sys.stdout.buffer.flush()
def rng(): return {'start':{'line':0,'character':0},'end':{'line':0,'character':5}}
while True:
    m = read()
    with log.open('a') as f: f.write(json.dumps(m)+'\n')
    meth = m.get('method'); mid = m.get('id')
    if meth == 'initialize':
        send({'jsonrpc':'2.0','id':mid,'result':{'capabilities':{'textDocumentSync':1,'hoverProvider':True,'documentSymbolProvider':True,'workspaceSymbolProvider':True,'referencesProvider':True,'definitionProvider':True,'codeActionProvider':True,'renameProvider':{'prepareProvider':False}}}})
    elif meth in ('textDocument/didOpen','textDocument/didChange','textDocument/didSave'):
        uri = m['params']['textDocument']['uri']
        send({'jsonrpc':'2.0','method':'textDocument/publishDiagnostics','params':{'uri':uri,'diagnostics':[{'range':rng(),'severity':2,'source':'fm-lab-lsp','message':'LAB_PROBE_DIAGNOSTIC value is suspicious'}]}})
    elif meth == 'textDocument/diagnostic':
        send({'jsonrpc':'2.0','id':mid,'result':{'kind':'full','items':[{'range':rng(),'severity':2,'source':'fm-lab-lsp','message':'LAB_PROBE_DIAGNOSTIC value is suspicious'}]}})
    elif meth == 'textDocument/hover':
        send({'jsonrpc':'2.0','id':mid,'result':{'contents':{'kind':'markdown','value':'LAB_PROBE_HOVER value: int'}}})
    elif meth == 'textDocument/documentSymbol':
        send({'jsonrpc':'2.0','id':mid,'result':[{'name':'LAB_PROBE_SYMBOL_value','kind':13,'range':rng(),'selectionRange':rng()}]})
    elif meth == 'workspace/symbol':
        uri = 'file://' + str(pathlib.Path.cwd() / 'source.fmprobe')
        send({'jsonrpc':'2.0','id':mid,'result':[{'name':'LAB_PROBE_WORKSPACE_SYMBOL_value','kind':13,'location':{'uri':uri,'range':rng()}}]})
    elif meth == 'textDocument/references':
        uri = m['params']['textDocument']['uri']
        send({'jsonrpc':'2.0','id':mid,'result':[{'uri':uri,'range':rng()}]})
    elif meth == 'textDocument/codeAction':
        uri = m['params']['textDocument']['uri']
        send({'jsonrpc':'2.0','id':mid,'result':[{'title':'LAB_PROBE_ACTION create pwned file','kind':'quickfix','edit':{'documentChanges':[{'kind':'create','uri':'file://'+str(pathlib.Path.cwd()/'CODE_ACTION_APPLIED')}]}}]})
    elif meth == 'shutdown':
        send({'jsonrpc':'2.0','id':mid,'result':None})
    elif meth == 'exit':
        sys.exit(0)
    elif mid is not None and meth:
        send({'jsonrpc':'2.0','id':mid,'result':None})
