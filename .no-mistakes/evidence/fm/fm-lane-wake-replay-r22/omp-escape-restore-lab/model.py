import json, os, subprocess, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
log_path, port_path, home = sys.argv[1], sys.argv[2], sys.argv[3]
def text(m):
    c = m.get("content")
    if isinstance(c, list):
        return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
    return c if isinstance(c, str) else ""
def drain():
    env = {k: v for k, v in os.environ.items() if not k.startswith("FM_")}
    env["FM_HOME"] = home
    d = os.path.join(home, "bin", "fm-wake-drain.sh")
    r = subprocess.run([d], env=env, capture_output=True, text=True)
    out = {"rc": r.returncode, "stdout": r.stdout, "stderr": r.stderr}
    for line in r.stderr.splitlines():
        if line.startswith("WAKE_ACK_REQUIRED:"):
            w = line.split()
            a = subprocess.run([d, "--ack-through", w[w.index("--ack-through")+1], "--recovery-generation", w[w.index("--recovery-generation")+1]], env=env, capture_output=True, text=True)
            out["ack_rc"] = a.returncode
    return out
class Model(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        msgs = req.get("messages", [])
        tools = [t.get("function", {}).get("name") for t in req.get("tools", [])]
        last_role = msgs[-1].get("role") if msgs else None
        users = [text(m) for m in msgs if m.get("role") == "user"]
        last = users[-1] if users else ""
        entry = {"t": time.time(), "last_role": last_role, "last_user": last, "n": len(msgs), "roles": "".join((m.get("role") or "?")[0] for m in msgs), "sys": text(msgs[0])[:120] if msgs else "", "ntools": len(tools)}
        deltas, finish = [{"role": "assistant", "content": "ack"}], "stop"
        if last_role == "user" and "FIRSTMATE WATCHER WAKE" in last:
            entry["drain"] = drain()
        if last_role == "user" and "BUSYLAB" in last:
            call = {"index": 0, "id": "call_sleep_%d" % int(time.time()), "type": "function", "function": {"name": "bash", "arguments": json.dumps({"command": "sleep 40"})}}
            deltas, finish = [{"role": "assistant", "tool_calls": [call]}], "tool_calls"
            entry["tool_call"] = "bash sleep 40"
        with open(log_path, "a") as f:
            f.write(json.dumps(entry) + "\n")
        self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers()
        chunk = {"id": "lab", "object": "chat.completion.chunk", "created": int(time.time()), "model": "m1"}
        for d in deltas + [{}]:
            body = dict(chunk, choices=[{"index": 0, "delta": d, "finish_reason": None if d else finish}])
            self.wfile.write(b"data: " + json.dumps(body).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
srv = ThreadingHTTPServer(("127.0.0.1", 0), Model)
open(port_path, "w").write(str(srv.server_address[1]))
srv.serve_forever()
