import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
log_path, port_path, delay = sys.argv[1], sys.argv[2], float(sys.argv[3])
def text(m):
    c = m.get("content")
    if isinstance(c, list):
        return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
    return c if isinstance(c, str) else ""
class Model(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        msgs = req.get("messages", [])
        last = text(msgs[-1]) if msgs else ""
        t0 = time.time()
        with open(log_path, "a") as log:
            log.write(json.dumps({"t": round(t0, 3), "event": "request", "wakes_in_context": sum(text(m).count("FIRSTMATE WATCHER WAKE") for m in msgs), "last": last[:160]}) + "\n")
        time.sleep(delay)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        chunk = {"id": "lab", "object": "chat.completion.chunk", "created": int(time.time()), "model": "m1"}
        for delta in [{"role": "assistant", "content": "ack"}, {}]:
            body = dict(chunk, choices=[{"index": 0, "delta": delta, "finish_reason": None if delta else "stop"}])
            self.wfile.write(b"data: " + json.dumps(body).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        with open(log_path, "a") as log:
            log.write(json.dumps({"t": round(time.time(), 3), "event": "response", "after_s": round(time.time() - t0, 1)}) + "\n")
server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
open(port_path, "w").write(str(server.server_address[1]))
server.serve_forever()
