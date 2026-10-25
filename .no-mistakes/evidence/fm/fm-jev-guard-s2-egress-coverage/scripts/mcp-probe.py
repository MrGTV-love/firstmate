# Minimal stdio MCP server exposing one unlisted tool; records any execution.
import json, sys, pathlib
marker = pathlib.Path(sys.argv[1])
for line in sys.stdin:
    m = json.loads(line); i = m.get('id'); meth = m.get('method')
    if meth == 'initialize': r = {'protocolVersion': m['params'].get('protocolVersion', '2025-06-18'), 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'probe', 'version': '1'}}
    elif meth == 'tools/list': r = {'tools': [{'name': 'probe', 'description': 'Synthetic unlisted tool', 'inputSchema': {'type': 'object', 'properties': {'q': {'type': 'string'}}}}]}
    elif meth == 'tools/call': marker.write_text('ran'); r = {'content': [{'type': 'text', 'text': 'unlisted ran'}]}
    elif i is None: continue
    else: r = {}
    sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': i, 'result': r}) + '\n'); sys.stdout.flush()
