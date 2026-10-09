import json, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lab, root, omp, mode = sys.argv[1:5]
home = os.path.join(lab, mode, "home"); agent = os.path.join(lab, mode, "agent")
for d in (agent, os.path.join(home, ".omp", "extensions"), os.path.join(home, ".pi", "extensions", "lib"), os.path.join(home, "state"), os.path.join(home, "config")):
    os.makedirs(d, exist_ok=True)
for src, dst in ((".omp/extensions/fm-primary-omp-watch.ts", ".omp/extensions/"),
                 (".pi/extensions/lib/fm-operational-input.ts", ".pi/extensions/lib/"),
                 (".pi/extensions/lib/fm-watch-lifecycle.ts", ".pi/extensions/lib/")):
    subprocess.run(["cp", os.path.join(root, src), os.path.join(home, dst)], check=True)
subprocess.run(["cp", "-R", os.path.join(root, "bin"), os.path.join(home, "bin")], check=True)
# Opt the home into the supervision host (the real gate query decides host mode).
open(os.path.join(home, "config", "supervision-host"), "w").close()
state = os.path.join(home, "state")
AWAY = os.path.join(state, ".afk-contract")
# Stand-in for bin/fm-supervision-host.sh park --restart: it reports ready, then
# waits for a trigger file whose lines are: optional "ROW <name>" (append a real
# durable row) followed by the literal close lines it prints before exiting.
host = os.path.join(home, "bin", "fm-supervision-host.sh")
with open(host, "w") as h:
    h.write('''#!/usr/bin/env bash
echo "spawn $$ $*" >> "$FM_HOME/state/host-spawns.log"
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\\n' "$$"
. "${FM_HOME:?}/bin/fm-wake-lib.sh"
while :; do
  for f in "$FM_HOME"/state/trigger-*; do
    [ -e "$f" ] || continue
    body=$(cat "$f"); rm -f "$f"
    while IFS= read -r line; do
      case "$line" in
        "ROW "*) n=${line#ROW }; fm_wake_append signal "$n" "signal: $n" || exit 1 ;;
        *) printf '%s\\n' "$line" ;;
      esac
    done <<EOF
$body
EOF
    exit 0
  done
  sleep 0.2
done
''')
os.chmod(host, 0o755)
# Same stand-in contract as tests/fm-omp-stale-wake-live-e2e.test.sh: the
# stand-in watcher's fake recovery generation is confirmed as delivered.
arm = os.path.join(home, "bin", "fm-watch-arm.sh")
with open(arm, "w") as h:
    h.write('#!/usr/bin/env bash\n[ "${1:-}" != --handling-delivered ] || exit 0\nexit 1\n')
os.chmod(arm, 0o755)
subprocess.run(["git", "init", "-q"], cwd=home, check=True)

log = []; log_lock = threading.Lock(); release = threading.Event()
def lane_drains():
    drain = os.path.join(home, "bin", "fm-wake-drain.sh")
    env2 = dict(os.environ, FM_HOME=home)
    for n in ("FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_DATA_OVERRIDE", "FM_SUPERVISION_ACTOR"): env2.pop(n, None)
    r = subprocess.run([drain], env=env2, capture_output=True, text=True)
    cmd = [l for l in r.stderr.splitlines() if l.startswith("WAKE_ACK_REQUIRED:")]
    if cmd:
        w = cmd[0].split()
        subprocess.run([drain, "--ack-through", w[w.index("--ack-through")+1], "--recovery-generation", w[w.index("--recovery-generation")+1]], env=env2, capture_output=True, text=True)
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
        if "FIRSTMATE WATCHER WAKE" in last or "FIRSTMATE SUPERVISION HOST" in last: e["drain"] = lane_drains()
        with log_lock: log.append(e)
        if "LONGTURN" in last: release.wait(120)
        self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers()
        ch = {"id": "lab", "object": "chat.completion.chunk", "created": int(time.time()), "model": "m1"}
        for d in [{"role": "assistant", "content": "ack"}, {}]:
            self.wfile.write(b"data: " + json.dumps(dict(ch, choices=[{"index": 0, "delta": d, "finish_reason": None if d else "stop"}])).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
srv = ThreadingHTTPServer(("127.0.0.1", 0), Model); threading.Thread(target=srv.serve_forever, daemon=True).start()
with open(os.path.join(agent, "config.yml"), "w") as h:
    h.write("setupVersion: 2\nmodelRoles:\n  default: lab/m1\n  tiny: lab/m1\n  advisor: lab/m1\n  vision: lab/m1\n")
with open(os.path.join(agent, "models.yml"), "w") as h:
    h.write(f"providers:\n  lab:\n    baseUrl: http://127.0.0.1:{srv.server_address[1]}/v1\n    apiKey: lab-key\n    api: openai-completions\n    models:\n      - id: m1\n        contextWindow: 200000\n        maxTokens: 4096\n")
env = dict(os.environ, FM_HOME=home, PI_CODING_AGENT_DIR=agent, FM_WATCH_REARM_RETRY_LIMIT="2")
for n in ("FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_DATA_OVERRIDE", "FM_SUPERVISION_ACTOR"): env.pop(n, None)
launch = f'printf "%s\\n" $$ > "{home}/state/.lock"; exec "{omp}" --mode rpc --no-session --model lab/m1 --no-title --no-skills --no-rules --no-lsp'
proc = subprocess.Popen(["bash", "-c", launch], cwd=home, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(os.path.join(lab, mode, "omp.stderr"), "w"), text=True)
events = []
def rd():
    for l in proc.stdout:
        try: events.append((time.time(), json.loads(l)))
        except ValueError: pass
threading.Thread(target=rd, daemon=True).start()
def send(c): proc.stdin.write(json.dumps(c) + "\n"); proc.stdin.flush()
def out(code, msg):
    print(msg, file=sys.stderr if code else sys.stdout)
    with open(os.path.join(lab, mode, "turns.json"), "w") as h: json.dump(log, h, indent=1)
    try: proc.kill()
    except Exception: pass
    sys.stdout.flush(); sys.stderr.flush(); os._exit(code)
def wait_for(p, s, what):
    dl = time.time() + s
    while time.time() < dl:
        if p(): return
        time.sleep(0.1)
    out(1, f"timed out waiting for {what}")
def spawns():
    try: return len(open(os.path.join(state, "host-spawns.log")).read().splitlines())
    except OSError: return 0
def fire(name, lines):
    before = spawns()
    with open(os.path.join(state, name + ".tmp"), "w") as h: h.write("\n".join(lines) + "\n")
    os.rename(os.path.join(state, name + ".tmp"), os.path.join(state, name))
    wait_for(lambda: not os.path.exists(os.path.join(state, name)), 20, f"host to take {name}")
    wait_for(lambda: spawns() > before, 20, f"next park to start after {name}")
    time.sleep(1.0)
def wakes():
    with log_lock: return [e for e in log if "FIRSTMATE" in e["last"]]
def longturn_start():
    send({"type": "prompt", "message": "LONGTURN start"})
    wait_for(lambda: any("LONGTURN" in e["last"] for e in log), 30, "long turn")
    return time.time()
def longturn_end(t0):
    release.set()
    wait_for(lambda: any(e.get("type") == "agent_end" for t, e in events if t > t0), 40, "long turn end")
    time.sleep(8)

wait_for(lambda: any(e.get("type") == "ready" for _, e in events), 120, "omp ready")
wait_for(lambda: os.path.exists(os.path.join(state, ".omp-watch-extension-loaded")), 120, "extension load")
wait_for(lambda: spawns() >= 1, 30, "first host park")
time.sleep(3)
AWAYLINE = "This wake comes from automatic supervision under the away-posture record"
PAUSED = "supervision-host: the away session is paused after repeated engine errors; this wake is yours"
if mode in ("away-archived", "away-present"):
    with open(AWAY, "w") as h: h.write("version: 2\nentered: 2026-10-09T00:00:00Z\n")
    t0 = longturn_start()
    fire("trigger-a", ["ROW owed-1", "signal: owed-1", PAUSED])
    if wakes(): out(1, f"a wake reached main while busy: {wakes()}")
    if mode == "away-archived": os.remove(AWAY)   # the /afk return archives the record before the send
    longturn_end(t0)
    w = wakes()
    if len(w) != 1: out(1, f"expected one wake turn, saw {len(w)}: {[x['last'][:300] for x in w]}")
    last = w[0]["last"]
    ok_core = "signal: owed-1" in last and PAUSED in last and "owed-1" in w[0]["drain"]["stdout"]
    has_note = AWAYLINE in last
    if not ok_core: out(1, f"wake lacked row headline/host line/drained row: {last!r} drain={w[0]['drain']}")
    if mode == "away-archived" and has_note: out(1, f"stale away note delivered after record archived: {last!r}")
    if mode == "away-present" and not has_note: out(1, f"away note missing while record present: {last!r}")
    out(0, f"{mode}: one wake naming the durable row 'signal: owed-1' plus the host line; away note present={has_note}\nDELIVERED: {last!r}")
elif mode == "boundary":
    # Host absorbed its own wakes: boundary-only closes, no row. Limit is 2 retries,
    # so 3 closes would exhaust it if boundaries were failures.
    for i in range(4):
        fire(f"trigger-b{i}", ["supervision-host: cycle boundary - the host handled the wake; the next park starts at once"])
    time.sleep(5)
    if log: out(1, f"boundary-only closes produced model turns: {[x['last'][:300] for x in log]}")
    out(0, f"boundary: 4 boundary-only closes, 0 model turns, {spawns()} host parks (re-armed every time, no FAILED notice)")
elif mode == "diag-empty":
    DIAG = "supervision-host: the away session could not take this wake: the engine turn failed (exit 1); this wake is yours"
    HEALTH = "supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next 30 minutes"
    fire("trigger-d", [DIAG, HEALTH])
    time.sleep(6)
    w = wakes()
    if len(w) != 1: out(1, f"expected one diagnostic wake, saw {len(w)}: {[x['last'][:300] for x in w]}")
    last = w[0]["last"]
    if not ("check: wake may be due" in last and DIAG in last and HEALTH in last): out(1, f"diagnostic wake malformed: {last!r}")
    if "signal:" in last or AWAYLINE in last: out(1, f"diagnostic wake carried a headline or away note with no record: {last!r}")
    out(0, f"diag-empty: empty queue still delivered 'check: wake may be due' plus both host diagnostics\nDELIVERED: {last!r}")
elif mode == "host-handled":
    # The host already handled and acknowledged this wake (no durable row), but
    # its close still carries the old headline: nothing may reach main.
    for i in range(3):
        fire(f"trigger-h{i}", [f"signal: already-handled-{i}", "supervision-host: cycle boundary - the host handled the wake; the next park starts at once"])
    time.sleep(5)
    if log: out(1, f"handled headlines re-injected with no queued row: {[x['last'][:300] for x in log]}")
    out(0, f"host-handled: 3 closes carrying handled 'signal:' headlines with no durable row, 0 model turns, {spawns()} host parks")
elif mode == "operational-away":
    with open(AWAY, "w") as h: h.write("version: 2\nentered: 2026-10-09T00:00:00Z\n")
    RET = "supervision-host: outcome 3 the away session finished its work"
    fire("trigger-o", ["signal: already-handled-original", RET])
    time.sleep(6)
    w = wakes()
    if len(w) != 1: out(1, f"expected one hand-back, saw {len(w)}: {[x['last'][:300] for x in w]}")
    last = w[0]["last"]
    if RET not in last or "already-handled-original" in last or AWAYLINE not in last: out(1, f"hand-back malformed: {last!r}")
    out(0, f"operational-away: hand-back carries the outcome and the send-time away note, no handled headline\nDELIVERED: {last!r}")
elif mode == "operational":
    RET = "supervision-host: the captain returned; the away session handed control back"
    fire("trigger-o", ["signal: already-handled-original", RET])
    time.sleep(6)
    w = wakes()
    if len(w) != 1: out(1, f"expected one hand-back, saw {len(w)}: {[x['last'][:300] for x in w]}")
    last = w[0]["last"]
    if "FIRSTMATE SUPERVISION HOST" not in last or RET not in last: out(1, f"hand-back malformed: {last!r}")
    if "already-handled-original" in last: out(1, f"hand-back replayed a handled headline with no row: {last!r}")
    if AWAYLINE in last: out(1, f"away note with no away record: {last!r}")
    out(0, f"operational: hand-back delivered without the handled 'signal:' headline and with no away note\nDELIVERED: {last!r}")
