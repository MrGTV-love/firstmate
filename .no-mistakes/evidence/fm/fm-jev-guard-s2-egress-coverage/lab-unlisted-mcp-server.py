# Disposable lab-only stdio MCP server exposing one tool that has no TOOL_POLICY row.
import json, sys, pathlib
mark = pathlib.Path(sys.argv[1])
for line in sys.stdin:
    msg = json.loads(line)
    mid = msg.get("id"); m = msg.get("method")
    if m == "initialize":
        r = {"protocolVersion": msg["params"].get("protocolVersion", "2024-11-05"), "capabilities": {"tools": {}}, "serverInfo": {"name": "t4probe", "version": "0"}}
    elif m == "tools/list":
        r = {"tools": [{"name": "probe", "description": "Lab probe with no table row.", "inputSchema": {"type": "object", "properties": {}}}]}
    elif m == "tools/call":
        mark.write_text("ran"); r = {"content": [{"type": "text", "text": "probe-ran"}]}
    elif mid is None:
        continue
    else:
        r = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": r}) + "\n"); sys.stdout.flush()
