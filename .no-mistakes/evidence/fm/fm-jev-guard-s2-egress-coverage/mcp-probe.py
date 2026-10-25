#!/usr/bin/env python3
# Minimal stdio MCP server with one tool that leaves a marker when it runs.
import json, sys, pathlib
marker = pathlib.Path(sys.argv[1])
for line in sys.stdin:
    try: req = json.loads(line)
    except Exception: continue
    mid, m = req.get('id'), req.get('method')
    if mid is None: continue
    if m == 'initialize':
        res = {'protocolVersion': req['params'].get('protocolVersion', '2024-11-05'), 'capabilities': {'tools': {}}, 'serverInfo': {'name': 't4', 'version': '1'}}
    elif m == 'tools/list':
        res = {'tools': [{'name': 't4probe', 'description': 'probe', 'inputSchema': {'type': 'object', 'properties': {}}}]}
    elif m == 'tools/call':
        marker.write_text('ran'); res = {'content': [{'type': 'text', 'text': 't4probe-ran'}]}
    else:
        res = {}
    sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': mid, 'result': res}) + '\n'); sys.stdout.flush()
