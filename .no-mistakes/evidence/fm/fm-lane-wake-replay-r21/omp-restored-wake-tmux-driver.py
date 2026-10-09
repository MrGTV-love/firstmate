import json, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lab, root, omp, mode = sys.argv[1:5]
base = os.path.join(lab, "restore-" + mode)
home = os.path.join(base, "home"); agent = os.path.join(base, "agent"); tm = os.path.join(base, "tmux")
for d in (agent, tm, os.path.join(home, ".omp", "extensions"), os.path.join(home, ".pi", "extensions", "lib"), os.path.join(home, "state")):
    os.makedirs(d, exist_ok=True)
for src, dst in ((".omp/extensions/fm-primary-omp-watch.ts", ".omp/extensions/"),
                 (".pi/extensions/lib/fm-operational-input.ts", ".pi/extensions/lib/"),
                 (".pi/extensions/lib/fm-watch-lifecycle.ts", ".pi/extensions/lib/")):
    subprocess.run(["cp", os.path.join(root, src), os.path.join(home, dst)], check=True)
subprocess.run(["cp", "-R", os.path.join(root, "bin"), os.path.join(home, "bin")], check=True)
state = os.path.join(home, "state")
# Stand-in watcher arm, identical in contract to tests/fm-omp-stale-wake-live-e2e.test.sh.
with open(os.path.join(home, "bin", "fm-watch-arm.sh"), "w") as h:
    h.write('''#!/usr/bin/env bash
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\\n' "$$"
. "${FM_HOME:?}/bin/fm-wake-lib.sh"
while :; do
  for f in "$FM_HOME"/state/trigger-*; do
    [ -e "$f" ] || continue
    name=${f##*/}; rm -f "$f"
    fm_wake_append signal "$name" "signal: $name" || exit 1
    printf 'signal: %s\\n' "$name"
    exit 0
  done
  sleep 0.2
done
''')
os.chmod(os.path.join(home, "bin", "fm-watch-arm.sh"), 0o755)
# Fixture-only wrapper, the same technique as tests/fm-omp-wake-restore-live-e2e.test.sh:
# capture one real idle production wake, then queue that same tracked text through
# omp's vendor follow-up API during a running turn.
probe = os.path.join(home, "probe.ts")
with open(probe, "w") as h:
    h.write('''import { existsSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import watchFactory from "./.omp/extensions/fm-primary-omp-watch.ts";
export default function (pi: any) {
  const state = `${process.env.FM_HOME}/state`;
  let context: any; let captured: string | null = null; let queueing = false;
  const file = (name: string) => `${state}/.wake-followup-${name}`;
  const publish = (name: string, value: unknown) => { writeFileSync(`${file(name)}.tmp`, `${JSON.stringify(value)}\\n`); renameSync(`${file(name)}.tmp`, file(name)); };
  // Observe (never alter) the editor writes the production extension makes.
  const wrapCtx = (ctx: any) => !ctx?.ui ? ctx : new Proxy(ctx, { get(t, k) {
    if (k !== "ui") return Reflect.get(t, k);
    return new Proxy(t.ui, { get(u, uk) {
      if (uk === "setEditorText") return (value: string) => { publish(`seteditor-${Date.now()}`, { before: u.getEditorText(), after: value, idle: t.isIdle() }); return u.setEditorText(value); };
      const v = Reflect.get(u, uk); return typeof v === "function" ? v.bind(u) : v;
    } });
  } });
  const wrapped = new Proxy(pi, { get(target, key) {
    if (key === "on") return (event: string, handler: any) => target.on(event, (value: any, ctx: any) => { context = ctx; return handler(value, wrapCtx(ctx)); });
    if (key === "sendUserMessage") return (content: string, options?: any) => {
      if (content.includes("FIRSTMATE WATCHER WAKE:") && existsSync(file("capture-request"))) {
        unlinkSync(file("capture-request")); captured = content;
        publish("captured", { content, idle: context?.isIdle(), deliverAs: options?.deliverAs ?? null }); return;
      }
      publish(`sent-${Date.now()}`, { content, idle: context?.isIdle(), deliverAs: options?.deliverAs ?? null, editor: context?.ui?.getEditorText(), same: content === captured });
      return target.sendUserMessage(content, options);
    };
    return Reflect.get(target, key);
  } });
  watchFactory(wrapped);
  const timer = setInterval(async () => {
    if (existsSync(file("editor-request")) && context) { unlinkSync(file("editor-request")); publish("editor", { editor: context?.ui?.getEditorText(), idle: context?.isIdle(), pending: context?.hasPendingMessages?.() }); }
    if (queueing || !captured || !existsSync(file("queue-request")) || context?.isIdle() !== false) return;
    queueing = true;
    try { unlinkSync(file("queue-request")); await pi.sendUserMessage(captured, { deliverAs: "followUp" }); publish("queued", { content: captured, idle: false }); }
    catch (error) { publish("error", String(error)); } finally { queueing = false; }
  }, 100);
  timer.unref();
  pi.on("session_shutdown", () => clearInterval(timer));
}
''')
subprocess.run(["git", "init", "-q"], cwd=home, check=True)

log = []; lock = threading.Lock(); release = threading.Event()
def lane_drains():
    drain = os.path.join(home, "bin", "fm-wake-drain.sh")
    e = dict(os.environ, FM_HOME=home)
    for n in ("FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_DATA_OVERRIDE", "FM_SUPERVISION_ACTOR"): e.pop(n, None)
    r = subprocess.run([drain], env=e, capture_output=True, text=True)
    c = [l for l in r.stderr.splitlines() if l.startswith("WAKE_ACK_REQUIRED:")]
    if c:
        w = c[0].split()
        subprocess.run([drain, "--ack-through", w[w.index("--ack-through")+1], "--recovery-generation", w[w.index("--recovery-generation")+1]], env=e, capture_output=True, text=True)
    return {"returncode": r.returncode, "stdout": r.stdout}
def text(m):
    c = m.get("content")
    if isinstance(c, list): return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
    return c if isinstance(c, str) else ""
class Model(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        users = [text(m) for m in req.get("messages", []) if m.get("role") == "user"]
        last = users[-1] if users else ""
        e = {"t": time.time(), "last": last}
        if "FIRSTMATE WATCHER WAKE" in last: e["drain"] = lane_drains()
        with lock: log.append(e)
        if "LONGTURN" in last: release.wait(90)
        try:
            self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers()
            ch = {"id": "lab", "object": "chat.completion.chunk", "created": int(time.time()), "model": "m1"}
            for d in [{"role": "assistant", "content": "ack"}, {}]:
                self.wfile.write(b"data: " + json.dumps(dict(ch, choices=[{"index": 0, "delta": d, "finish_reason": None if d else "stop"}])).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
        except OSError: pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), Model); threading.Thread(target=srv.serve_forever, daemon=True).start()
with open(os.path.join(agent, "config.yml"), "w") as h:
    h.write("setupVersion: 2\nmodelRoles:\n  default: lab/m1\n  tiny: lab/m1\n  advisor: lab/m1\n  vision: lab/m1\n")
with open(os.path.join(agent, "models.yml"), "w") as h:
    h.write(f"providers:\n  lab:\n    baseUrl: http://127.0.0.1:{srv.server_address[1]}/v1\n    apiKey: lab-key\n    api: openai-completions\n    models:\n      - id: m1\n        contextWindow: 200000\n        maxTokens: 4096\n")

tenv = dict(os.environ, TMUX_TMPDIR=tm)
for n in ("TMUX", "FM_HOME", "FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_DATA_OVERRIDE", "FM_SUPERVISION_ACTOR", "NO_MISTAKES_GATE", "FM_GATE_REFUSE_BYPASS"): tenv.pop(n, None)
def tmux(*a, **k): return subprocess.run(["tmux", "-L", "fm-lab", *a], env=tenv, capture_output=True, text=True, **k)
launch = f'printf "%s\\n" $$ > "{state}/.lock"; exec "{omp}" --no-extensions -e "{probe}" --no-session --model lab/m1 --no-title --no-skills --no-rules --no-lsp'
r = tmux("new-session", "-d", "-s", "primary", "-x", "220", "-y", "50", "-c", home, "-e", f"FM_HOME={home}", "-e", f"PI_CODING_AGENT_DIR={agent}", "-e", "FM_WATCH_REARM_RETRY_LIMIT=2", "bash", "-c", launch)
if r.returncode: print("tmux start failed", r.stderr, file=sys.stderr); os._exit(1)
shots = []
def pane(): return tmux("capture-pane", "-p", "-t", "primary").stdout
def shot(label):
    s = pane(); shots.append(f"===== {label} =====\n{s}"); return s
def out(code, msg):
    shot("final")
    with open(os.path.join(base, "screens.txt"), "w") as h: h.write("\n".join(shots))
    with open(os.path.join(base, "turns.json"), "w") as h: json.dump(log, h, indent=1)
    tmux("kill-server")
    print(msg, file=sys.stderr if code else sys.stdout); sys.stdout.flush(); sys.stderr.flush(); os._exit(code)
def wait_for(p, s, what):
    dl = time.time() + s
    while time.time() < dl:
        if p(): return
        time.sleep(0.1)
    out(1, f"timed out waiting for {what}")
def sf(name): return os.path.join(state, ".wake-followup-" + name)
def rj(name):
    with open(sf(name)) as h: return json.load(h)
def editor():
    try: os.remove(sf("editor"))
    except OSError: pass
    open(sf("editor-request"), "w").close()
    wait_for(lambda: os.path.exists(sf("editor")), 10, "editor readback")
    return rj("editor")
def wakes():
    with lock: return [e for e in log if "FIRSTMATE WATCHER WAKE" in e["last"]]

wait_for(lambda: os.path.exists(os.path.join(state, ".omp-watch-extension-loaded")), 120, "extension load")
time.sleep(5); shot("started")
# 1. Capture a real idle production wake for a durable row.
open(sf("capture-request"), "w").close()
open(os.path.join(state, "trigger-restore"), "w").close()
wait_for(lambda: os.path.exists(sf("captured")), 30, "idle production wake capture")
cap = rj("captured")
if not (cap["idle"] is True and cap["deliverAs"] is None and "signal: trigger-restore" in cap["content"]): out(1, f"capture was not an idle production wake naming the row: {cap}")
# 2. Busy turn, operator draft, then the tracked wake enters omp's follow-up queue.
tmux("send-keys", "-t", "primary", "-l", "LONGTURN go"); time.sleep(0.5); tmux("send-keys", "-t", "primary", "Enter")
wait_for(lambda: any("LONGTURN" in e["last"] for e in log), 30, "long turn")
time.sleep(1)
DRAFT = "operator draft keep me"
tmux("send-keys", "-t", "primary", "-l", DRAFT); time.sleep(0.5)
open(sf("queue-request"), "w").close()
wait_for(lambda: os.path.exists(sf("queued")), 20, "follow-up queued")
time.sleep(1); shot("busy: wake queued as vendor follow-up, draft typed")
if mode == "stale":
    d = lane_drains()
    if "trigger-restore" not in d["stdout"]: out(1, f"lane drain found no row: {d}")
# 3. Interrupt: omp restores the queued follow-up into the composer.
tmux("send-keys", "-t", "primary", "Escape")
def seteds(): return [json.load(open(os.path.join(state, f))) for f in sorted(os.listdir(state)) if f.startswith(".wake-followup-seteditor-")]
wait_for(lambda: seteds(), 20, "production to clear a restored wake from the composer after Escape")
se = seteds()[0]
if not ("FIRSTMATE WATCHER WAKE" in se["before"] and "signal: trigger-restore" in se["before"] and se["after"] == DRAFT and se["idle"]):
    out(1, f"production editor write was not a restored-wake removal that kept the draft: {se}")
release.set()
time.sleep(10)
ed = editor(); s = shot("settled"); w = wakes()
sent = sorted(f for f in os.listdir(state) if f.startswith(".wake-followup-sent-"))
resent = [json.load(open(os.path.join(state, f))) for f in sent]
resent = [x for x in resent if x["same"] or "FIRSTMATE WATCHER WAKE" in x["content"]]
if "FIRSTMATE WATCHER WAKE" in (ed["editor"] or ""): out(1, f"wake text was left in the composer: {ed}")
if ed["editor"] != DRAFT: out(1, f"operator draft not preserved: {ed}")
if mode == "owed":
    if len(w) != 1 or "signal: trigger-restore" not in w[0]["last"] or "trigger-restore" not in w[0]["drain"]["stdout"]:
        out(1, f"expected exactly one wake turn naming the owed row: {[x['last'][:200] for x in w]} resent={resent}")
    out(0, f"owed: omp restored the wake into the composer ({se['before']!r}); production removed it ({se['after']!r} kept);  wake removed from the composer, draft {ed['editor']!r} kept, one wake turn re-sent at idle (deliverAs={resent[0]['deliverAs'] if resent else '?'}) naming 'signal: trigger-restore', drain showed the row")
else:
    if w or resent: out(1, f"a stale restored wake was re-sent with no queued row: turns={[x['last'][:200] for x in w]} resent={resent}")
    out(0, f"stale: omp restored the wake into the composer ({se['before']!r}); production removed it ({se['after']!r} kept);  wake removed from the composer, draft {ed['editor']!r} kept, 0 wake turns after the lane had drained and acknowledged the row")
