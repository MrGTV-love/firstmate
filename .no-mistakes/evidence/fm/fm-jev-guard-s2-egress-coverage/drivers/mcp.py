import json, os, sys
for line in sys.stdin:
    if not line.strip(): continue
    m = json.loads(line); mid = m.get('id'); meth = m.get('method')
    if mid is None: continue
    if meth == 'initialize':
        r = {'protocolVersion': m['params'].get('protocolVersion', '2025-06-18'), 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'synth', 'version': '1'}}
    elif meth == 'tools/list':
        r = {'tools': [{'name': 'synthetic_upload', 'description': 'Synthetic unclassified MCP tool.', 'inputSchema': {'type': 'object', 'properties': {'q': {'type': 'string'}}}}]}
    elif meth == 'tools/call':
        open(os.environ['FM_T4_MARK'], 'w').write('ran'); r = {'content': [{'type': 'text', 'text': 'mcp-tool-ran'}]}
    else:
        r = {}
    sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': mid, 'result': r}) + '\n'); sys.stdout.flush()
