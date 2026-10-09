import json, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lab, root, omp, mode = sys.argv[1:5]
sys.path.insert(0, os.path.join(root, "tests"))
from omp_wake_turns import classify_turn, summarize
home = os.path.join(lab, mode, "home")
agent = os.path.join(lab, mode, "agent")
for d in (agent, os.path.join(home, ".omp", "extensions"), os.path.join(home, ".pi", "extensions", "lib"), os.path.join(home, "state")):
    os.makedirs(d, exist_ok=True)

# The real extension, its operational-input encoder, and the real bin/ (the real
# drain and queue library); only the watcher arm is a stand-in.
for src, dst in (
    (".omp/extensions/fm-primary-omp-watch.ts", ".omp/extensions/"),
    (".pi/extensions/lib/fm-operational-input.ts", ".pi/extensions/lib/"),
):
    if mode != "legacy":
        subprocess.run(["cp", os.path.join(root, src), os.path.join(home, dst)], check=True)
subprocess.run(["cp", "-R", os.path.join(root, "bin"), os.path.join(home, "bin")], check=True)
arm = os.path.join(home, "bin", "fm-watch-arm.sh")
with open(arm, "w") as handle:
    handle.write('''#!/usr/bin/env bash
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\\n' "$$"
. "${FM_HOME:?}/bin/fm-wake-lib.sh"
while :; do
  for f in "$FM_HOME"/state/trigger-*; do
    [ -e "$f" ] || continue
    name=${f##*/}
    rm -f "$f"
    reason="signal: $name"
    fm_wake_append signal "$name" "$reason" || exit 1
    printf '%s\\n' "$reason"
    exit 0
  done
  sleep 0.2
done
''')
os.chmod(arm, 0o755)
if mode == "legacy":
    with open(os.path.join(home, ".omp", "extensions", "legacy-watch.ts"), "w") as handle:
        handle.write('''import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
export default function (pi: any) {
  const home = process.env.FM_HOME!;
  let child: ReturnType<typeof spawn> | undefined;
  let stopped = false;
  function arm() {
    if (stopped) return;
    let output = "";
    child = spawn(home + "/bin/fm-watch-arm.sh", [], { env: process.env });
    child.stdout!.on("data", (chunk) => { output += chunk.toString(); });
    child.on("close", () => {
      if (stopped) return;
      for (const line of output.split("\\n")) {
        if (line.startsWith("signal: ")) {
          pi.sendUserMessage("FIRSTMATE WATCHER WAKE\\n" + line, { deliverAs: "followUp" });
        }
      }
      arm();
    });
  }
  pi.on("session_start", () => {
    writeFileSync(home + "/state/.omp-watch-extension-loaded", "legacy fixture\\n");
    arm();
  });
  pi.on("session_shutdown", () => { stopped = true; child?.kill(); });
}
''')
subprocess.run(["git", "init", "-q"], cwd=home, check=True)


real_drain = os.path.join(home, "bin", "fm-wake-drain-real.sh")
os.rename(os.path.join(home, "bin", "fm-wake-drain.sh"), real_drain)
with open(os.path.join(home, "bin", "fm-wake-drain.sh"), "w") as f:
    f.write('#!/usr/bin/env bash\nif [ "${1:-}" = --queued ]; then printf "query\\n" >> "$FM_HOME/state/query-log"; fi\nexec bash "${FM_HOME:?}/bin/fm-wake-drain-real.sh" "$@"\n')
os.chmod(os.path.join(home, "bin", "fm-wake-drain.sh"), 0o755)

log = []
log_lock = threading.Lock()
longturn_release = threading.Event()
state = os.path.join(home, "state")

def lane_drains():
    """The lane's part: run the real drain, then the acknowledgement it prints."""
    drain = os.path.join(home, "bin", "fm-wake-drain.sh")
    drain_env = dict(os.environ, FM_HOME=home)
    for name in ("FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_DATA_OVERRIDE", "FM_SUPERVISION_ACTOR"):
        drain_env.pop(name, None)
    drained = subprocess.run([drain], env=drain_env, capture_output=True, text=True)
    record = {"returncode": drained.returncode, "stdout": drained.stdout, "stderr": drained.stderr}
    if drained.returncode != 0:
        raise RuntimeError(f"lane drain failed: {record}")
    command = [line for line in drained.stderr.splitlines() if line.startswith("WAKE_ACK_REQUIRED:")]
    if not command:
        return record
    words = command[0].split()
    seq = words[words.index("--ack-through") + 1]
    generation = words[words.index("--recovery-generation") + 1]
    subprocess.run([drain, "--ack-through", seq, "--recovery-generation", generation], env=drain_env, capture_output=True, text=True, check=True)
    return record

def text(message):
    content = message.get("content")
    if isinstance(content, list):
        return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return content if isinstance(content, str) else ""

class Model(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        users = [text(m) for m in request.get("messages", []) if m.get("role") == "user"]
        last = users[-1] if users else ""
        entry = {"t": time.time(), "last": last}
        if "FIRSTMATE WATCHER WAKE" in last:
            entry["drain"] = lane_drains()
        with log_lock:
            log.append(entry)
        if "LONGTURN" in last:
            if not longturn_release.wait(120):
                raise TimeoutError("the driver never released the long turn")
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        chunk = {"id": "lab", "object": "chat.completion.chunk", "created": int(time.time()), "model": "m1"}
        for delta in [{"role": "assistant", "content": "ack"}, {}]:
            body = dict(chunk, choices=[{"index": 0, "delta": delta, "finish_reason": None if delta else "stop"}])
            self.wfile.write(b"data: " + json.dumps(body).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
with open(os.path.join(agent, "config.yml"), "w") as handle:
    handle.write("setupVersion: 2\nmodelRoles:\n  default: lab/m1\n  tiny: lab/m1\n  advisor: lab/m1\n  vision: lab/m1\n")
with open(os.path.join(agent, "models.yml"), "w") as handle:
    handle.write(f"providers:\n  lab:\n    baseUrl: http://127.0.0.1:{port}/v1\n    apiKey: lab-key\n    api: openai-completions\n    models:\n      - id: m1\n        contextWindow: 200000\n        maxTokens: 4096\n")

env = dict(os.environ, FM_HOME=home, PI_CODING_AGENT_DIR=agent, FM_WATCH_REARM_RETRY_LIMIT="2")
for name in ("FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_DATA_OVERRIDE", "FM_SUPERVISION_ACTOR"):
    env.pop(name, None)

# The pid written to state/.lock is the omp the shell execs, so the extension
# owns the lock and arms at session_start without a model turn.
launch = f'printf "%s\\n" $$ > "{home}/state/.lock"; exec "{omp}" --mode rpc --no-session --model lab/m1 --no-title --no-skills --no-rules --no-lsp'
errors = open(os.path.join(lab, mode, "omp.stderr"), "w")
proc = subprocess.Popen(["bash", "-c", launch], cwd=home, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True)
events = []
def read_events():
    for line in proc.stdout:
        try:
            events.append((time.time(), json.loads(line)))
        except ValueError:
            pass
threading.Thread(target=read_events, daemon=True).start()

def send(command):
    proc.stdin.write(json.dumps(command) + "\n")
    proc.stdin.flush()

def wait_for(predicate, seconds, what):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    print(f"timed out waiting for {what}", file=sys.stderr)
    shutdown(1)

def wake_turns():
    with log_lock:
        return [entry for entry in log if "FIRSTMATE WATCHER WAKE" in entry["last"]]

def shutdown(code):
    try:
        proc.kill()
    except Exception:
        pass
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)

def fire(name):
    open(os.path.join(state, name), "w").close()
    wait_for(lambda: not os.path.exists(os.path.join(state, name)), 20, f"the watcher to take {name}")
    time.sleep(1.0)

wait_for(lambda: any(e.get("type") == "ready" for _, e in events), 120, "omp to be ready")
wait_for(lambda: os.path.exists(os.path.join(state, ".omp-watch-extension-loaded")), 120, "the watch extension to load")

time.sleep(3)
def save(name, value):
    with open(os.path.join(lab, mode, name), "w") as f: json.dump(value, f, indent=2)
def queue():
    out=subprocess.run([os.path.join(home,"bin","fm-wake-drain.sh"),"--queued"],env=dict(env,FM_HOME=home),capture_output=True,text=True)
    return {"returncode":out.returncode,"stdout":out.stdout,"stderr":out.stderr}
def queries():
    p=os.path.join(state,"query-log")
    return len(open(p).readlines()) if os.path.exists(p) else 0
if mode == "consumed":
    fire("trigger-1")
    wait_for(lambda: len(wake_turns()) == 1, 30, "one consumed wake turn")
    wait_for(lambda: any(e.get("type") == "agent_end" for _,e in events), 30, "consumed wake agent_end")
    time.sleep(2)
    before=queries()
    # An unrelated event enters the durable queue without closing this watcher.
    subprocess.run(["bash","-c",'. "$1"; fm_wake_append check unrelated "check: unrelated later row"',"_",os.path.join(home,"bin","fm-wake-lib.sh")],env=env,check=True)
    time.sleep(3)
    after=queries()
    turns=wake_turns()
    save("proof.json", {"scenario":mode,"query_count_after_consumption":before,"query_count_after_later_row":after,"turns":turns,"queued_after_observation":queue()})
    if before != 1 or after != before or len(turns) != 1: raise RuntimeError("consumption produced phantom queue queries or extra turn")
    print("consumed: one queue query, no new query or wake after agent_end or an unrelated later row")
elif mode == "query-failure":
    send({"type":"prompt","message":"LONGTURN failed queue read proof"})
    wait_for(lambda:any("LONGTURN" in x["last"] for x in log),30,"long turn")
    fire("trigger-1")
    queue_path=os.path.join(state,".wake-queue")
    with open(queue_path) as f: valid_rows=f.read()
    with open(queue_path,"a") as f: f.write("malformed queue record\n")
    failed_query=queue()
    if failed_query["returncode"] == 0 or failed_query["stdout"]: raise RuntimeError("malformed queue was accepted")
    longturn_release.set()
    wait_for(lambda:any(e.get("type")=="agent_end" for _,e in events),30,"long turn end")
    wait_for(lambda:queries()>=4,20,"repeated failed queries")
    time.sleep(.3)
    if wake_turns(): raise RuntimeError("unreadable queue emitted a watcher headline")
    failed_events=list(events)
    if not any("could not read the wake queue" in json.dumps(e) for _,e in failed_events): raise RuntimeError("queue failure did not surface a typed notice")
    with open(queue_path,"w") as f: f.write(valid_rows)
    wait_for(lambda:len(wake_turns())==1,20,"owed wake after queue repair")
    time.sleep(3)
    turns=wake_turns()
    save("proof.json",{"scenario":mode,"failed_query":failed_query,"failed_events":failed_events,"turns_after_repair":turns,"queued_after":queue()})
    if len(turns)!=1 or classify_turn(turns[0])!="owed": raise RuntimeError("queue recovery lost or replayed work")
    print("query-failure: malformed queue emitted no watcher wake, surfaced a typed notice, then delivered exactly one owed wake after repair")
elif mode.startswith("replacement-"):
    send({"type":"prompt","message":"LONGTURN replacement proof"})
    wait_for(lambda:any("LONGTURN" in x["last"] for x in log),30,"long turn")
    for name in ("trigger-1","trigger-2"): fire(name)
    queued_before=queue()
    if mode == "replacement-empty":
        original_drain=lane_drains()
    else: original_drain=None
    # Real unreadable queue prevents the predecessor from consuming the pending
    # mark at abort's agent_end before the new session is established.
    os.chmod(os.path.join(state, ".wake-queue"), 0)
    send({"type":"abort"})
    time.sleep(.2)
    send({"type":"new_session"})
    # Release the model's old connection after omp has received the replacement.
    longturn_release.set()
    wait_for(lambda:any(e.get("type")=="response" and e.get("command")=="new_session" for _,e in events),30,"RPC session replacement response")
    if wake_turns(): raise RuntimeError("predecessor consumed wake before replacement")
    handoff_path=os.path.join(state,"extensions","omp-primary-watch","session-replacement-actionable.json")
    handoff=json.load(open(handoff_path)) if os.path.exists(handoff_path) else None
    replacement_at=max(t for t,e in events if e.get("type")=="response" and e.get("command")=="new_session")
    os.chmod(os.path.join(state, ".wake-queue"), 0o600)
    time.sleep(8)
    turns=wake_turns()
    response=[e for _,e in events if e.get("type")=="response" and e.get("command")=="new_session"]
    save("proof.json",{"scenario":mode,"replacement_response":response,"pending_handoff_before_read_recovery":handoff,"replacement_at":replacement_at,"queued_before":queued_before,"in_turn_drain":original_drain,"turns":turns,"queued_after":queue(),"events":events})
    if not response[-1].get("success"): raise RuntimeError("RPC replacement failed")
    if mode == "replacement-empty":
        if turns: raise RuntimeError("replacement replayed a drained headline")
    elif len(turns)!=1 or classify_turn(turns[0])!="owed": raise RuntimeError("replacement lost or replayed owed work")
    if any(turn["t"] <= replacement_at for turn in turns): raise RuntimeError("wake ran before replacement completion")
    print(mode+": public new_session completed before any wake; restored queue access delivered only currently owed rows")
else: raise RuntimeError("unknown mode")
shutdown(0)
