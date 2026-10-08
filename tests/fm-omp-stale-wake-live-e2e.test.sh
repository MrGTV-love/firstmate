#!/usr/bin/env bash
# tests/fm-omp-stale-wake-live-e2e.test.sh - the live omp stale-wake guard
# (live-harness-optin family; task fm-lane-wake-replay).
#
# Lanes were handed watcher headlines the durable queue no longer owed. omp cannot
# retract a follow-up, and a lane drains and acknowledges every durable row inside
# the turn a follow-up was queued behind, so each queued headline then started a
# turn that found nothing to drain (the lane answered each with a no-op). The
# portable suite pins the extension's logic over a fake omp API; this guard drives
# the INSTALLED omp, headless over its RPC protocol, with the real watch
# extension, the real wake queue and recovery marker, and the real
# bin/fm-wake-drain.sh. A scripted local model answers every request and spends no
# tokens; the guard plays the lane's part by running the real drain and
# acknowledgement at the moments a lane would.
#   stale   Three watcher cycles close while a long turn runs; the lane drains and
#           acknowledges all of them inside that turn. No wake turn may follow.
#   owed    The same closes, but the lane does not drain during the long turn.
#           Exactly one wake turn may follow; the lane drains inside it, and no
#           further wake turn may follow that drain.
#   legacy  The stale scenario with the gate disabled (FM_OMP_WAKE_HOLD_MAX_MS=0)
#           must still produce the stale turns, which proves the scenario can see
#           the defect it guards against.
# It spends no model tokens, so it runs by default wherever omp is installed and
# fails naming omp and `omp --version`. Refresh docs/verification/runtime-backends.md
# ("omp stale wake gating") from its output after any omp upgrade.
set -u
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
unset FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_OMP_STALE_WAKE_LIVE omp python3

REAL_OMP=$(command -v omp)
SUBJECT="omp ($(omp --version 2>/dev/null | head -n 1))"
LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-omp-stale-wake.XXXXXX")

# Every process the lab started (omp, the stand-in arm, the model) names the lab
# path on its command line or in its environment-derived arguments.
reap_lab() {
  local pid
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" -v me="$$" 'index($0, lab) && $1 != me { print $1 }'); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" -v me="$$" 'index($0, lab) && $1 != me { print $1 }'); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

cleanup() {
  local rc=$?
  trap - EXIT
  reap_lab
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT

cat > "$LAB/driver.py" <<'PY'
import json, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lab, root, omp, mode = sys.argv[1:5]
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
subprocess.run(["git", "init", "-q"], cwd=home, check=True)

log = []
log_lock = threading.Lock()
state = os.path.join(home, "state")

def lane_drains():
    """The lane's part: run the real drain, then the acknowledgement it prints."""
    drain = os.path.join(home, "bin", "fm-wake-drain.sh")
    drain_env = dict(os.environ, FM_HOME=home)
    for name in ("FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_DATA_OVERRIDE", "FM_SUPERVISION_ACTOR"):
        drain_env.pop(name, None)
    drained = subprocess.run([drain], env=drain_env, capture_output=True, text=True)
    command = [line for line in drained.stderr.splitlines() if line.startswith("WAKE_ACK_REQUIRED:")]
    if not command:
        return False
    words = command[0].split()
    seq = words[words.index("--ack-through") + 1]
    generation = words[words.index("--recovery-generation") + 1]
    subprocess.run([drain, "--ack-through", seq, "--recovery-generation", generation], env=drain_env, capture_output=True, text=True, check=True)
    return True

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
        with log_lock:
            log.append({"t": time.time(), "last": last})
        # In the owed scenario the lane drains inside its wake turn, as a real
        # lane does before it answers.
        if mode == "owed" and "FIRSTMATE WATCHER WAKE" in last:
            lane_drains()
        if "LONGTURN" in last:
            time.sleep(float(os.environ.get("LONGTURN_SECONDS", "9")))
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

env = dict(
    os.environ, FM_HOME=home, PI_CODING_AGENT_DIR=agent, FM_OMP_WAKE_FLUSH_MS="300",
    FM_OMP_ARM_READY_TIMEOUT_MS="8000", FM_WATCH_REARM_RETRY_LIMIT="2",
)
for name in ("FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_DATA_OVERRIDE", "FM_SUPERVISION_ACTOR"):
    env.pop(name, None)
if mode == "legacy":
    env["FM_OMP_WAKE_HOLD_MAX_MS"] = "0"

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

wait_for(lambda: any(e.get("type") == "ready" for _, e in events), 30, "omp to be ready")
wait_for(lambda: os.path.exists(os.path.join(state, ".omp-watch-extension-loaded")), 30, "the watch extension to load")
time.sleep(3)
send({"type": "prompt", "message": "LONGTURN start the long turn"})
wait_for(lambda: any("LONGTURN" in entry["last"] for entry in log), 30, "the long turn to start")
long_started = time.time()
for name in ("trigger-1", "trigger-2", "trigger-3"):
    fire(name)
if mode in ("stale", "legacy"):
    time.sleep(0.5)
    if not lane_drains():
        print("the lane's drain had nothing to present: the closes left no durable row", file=sys.stderr)
        shutdown(1)
wait_for(lambda: any(e.get("type") == "agent_end" for t, e in events if t > long_started), 40, "the long turn to end")
settle = float(os.environ.get("SETTLE_SECONDS", "8"))
time.sleep(settle)
turns = wake_turns()
if mode == "owed":
    if len(turns) != 1 or "signal: trigger-1" not in turns[0]["last"]:
        print(f"expected exactly one wake turn naming trigger-1, saw {len(turns)}: {[t['last'][:160] for t in turns]}", file=sys.stderr)
        shutdown(1)
    print("owed: one wake turn, and none after the drain it triggered covered every row")
elif mode == "stale":
    if turns:
        print(f"{len(turns)} stale wake turn(s) reached a lane that had drained every row: {[t['last'][:160] for t in turns]}", file=sys.stderr)
        shutdown(1)
    print("stale: no wake turn after the lane drained and acknowledged every row")
else:
    if len(turns) < 2:
        print(f"the gate was disabled yet only {len(turns)} stale wake turn(s) appeared: the scenario cannot see the defect", file=sys.stderr)
        shutdown(1)
    print(f"legacy: {len(turns)} stale wake turns without the gate")
shutdown(0)
PY

for mode in stale owed legacy; do
  mkdir -p "$LAB/$mode"
  out=$(python3 -I "$LAB/driver.py" "$LAB" "$ROOT" "$REAL_OMP" "$mode" 2>"$LAB/$mode/driver.stderr") \
    || { cat "$LAB/$mode/driver.stderr" >&2; [ ! -s "$LAB/$mode/omp.stderr" ] || cat "$LAB/$mode/omp.stderr" >&2; fail "$SUBJECT: stale-wake scenario $mode failed"; }
  reap_lab
  case "$mode" in
    stale) pass "live omp stale wake: $SUBJECT delivered no wake turn after the lane drained and acknowledged every row inside a long turn ($out)" ;;
    owed) pass "live omp owed wake: $SUBJECT delivered exactly one wake turn to a lane that had not drained, and none after the drain that turn ran ($out)" ;;
    legacy) pass "live omp control: $SUBJECT with the gate disabled still shows the stale wake turns the guard exists to prevent ($out)" ;;
  esac
done
