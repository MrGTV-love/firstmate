#!/usr/bin/env bash
# tests/fm-omp-lsp-overlay-live-e2e.test.sh - the live omp language-server guard
# (live-harness-optin family; task fm-worker-lsp-off-unattended).
#
# Language servers under days-old omp sessions burned host CPU, so the tracked
# fleet overlays .omp/fm-session-overlay.yml and .omp/fm-worker-overlay.yml set
# `lsp.enabled: false`. This guard drives the INSTALLED omp with those overlays
# layered the way bin/fm-spawn.sh layers them and checks the outcome:
#   1. The `lsp` tool is refused when a session asks for it by name, and is
#      available in the control run that carries no overlay.
#   2. A write of a file that a project-configured language server claims starts
#      no server process, while the same write in the control run starts one.
# `omp config list` cannot see an overlay (it rejects --config), so a launched
# session is the only place the layered value shows.
# The language server is a fixture that records its own start, and the model is
# a scripted local one, so the guard spends no tokens and needs no real server.
# It fails naming omp and `omp --version`, so run it after any omp upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OMP_LSP_OVERLAY_LIVE omp
command -v python3 > /dev/null 2>&1 || fail "python3 is missing; the fixture language server and the scripted model need it"

SESSION_OVERLAY="$ROOT/.omp/fm-session-overlay.yml"
WORKER_OVERLAY="$ROOT/.omp/fm-worker-overlay.yml"
[ -f "$SESSION_OVERLAY" ] || fail "the session overlay is missing at $SESSION_OVERLAY"
[ -f "$WORKER_OVERLAY" ] || fail "the worker overlay is missing at $WORKER_OVERLAY"

OMP_VERSION=$(omp --version 2>&1 | head -n 1)
LAB=$(fm_test_tmproot fm-omp-lsp-overlay-live) || fail "could not create the lab directory"

# A stdio language server that records its start and answers just enough of the
# protocol for omp's write path to finish without waiting on a timeout.
cat > "$LAB/fakels.py" <<'PY'
import json, os, sys, threading
marker_dir = sys.argv[1]
with open(os.path.join(marker_dir, "started.%d" % os.getpid()), "w") as marker:
    marker.write("started\n")
threading.Timer(90, os._exit, [0]).start()
def send(message):
    body = json.dumps(message).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()
def read():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        name, _, value = line.decode().partition(":")
        if name.lower() == "content-length":
            length = int(value)
    return json.loads(sys.stdin.buffer.read(length)) if length else {}
while True:
    message = read()
    if message is None:
        break
    method = message.get("method")
    if method == "exit":
        break
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": {"textDocumentSync": 1}}})
    elif method in ("textDocument/didOpen", "textDocument/didChange"):
        uri = message["params"]["textDocument"]["uri"]
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": uri, "diagnostics": []}})
    elif "id" in message and method:
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})
PY

# A scripted OpenAI-compatible model: the first turn that offers the write tool
# answers with one write call for the case's fixture file, every other request
# answers "done". It spends no tokens.
cat > "$LAB/model.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
target, port_path = sys.argv[1], sys.argv[2]
class Model(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        tools = {t.get("function", {}).get("name") for t in request.get("tools", [])}
        answered = any(m.get("role") == "tool" for m in request.get("messages", []))
        if "write" in tools and not answered:
            call = {"index": 0, "id": "call_write", "type": "function", "function": {"name": "write", "arguments": json.dumps({"path": target, "content": "fixture\n"})}}
            deltas, finish = [{"role": "assistant", "tool_calls": [call]}], "tool_calls"
        else:
            deltas, finish = [{"role": "assistant", "content": "done"}], "stop"
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        chunk = {"id": "lab", "object": "chat.completion.chunk", "created": int(time.time()), "model": "m1"}
        for delta in deltas + [{}]:
            body = dict(chunk, choices=[{"index": 0, "delta": delta, "finish_reason": None if delta else finish}])
            self.wfile.write(b"data: " + json.dumps(body).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
with open(port_path, "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
PY

marker_started() { find "$1" -name 'started.*' 2>/dev/null | grep -q .; }
process_gone() { ! kill -0 "$1" 2>/dev/null; }

wait_for() {  # <seconds> <command...>
  local limit=$1 waited=0
  shift
  until "$@"; do
    [ "$waited" -lt "$((limit * 4))" ] || return 1
    sleep 0.25
    waited=$((waited + 1))
  done
}

# prepare <case>: a scratch HOME whose only provider is the scripted model, and a
# workspace whose lsp.json routes `.fakels` files to the fixture server.
prepare() {
  local case_dir=$LAB/$1
  mkdir -p "$case_dir/home/.omp/agent" "$case_dir/ws" "$case_dir/markers"
  python3 -I "$LAB/model.py" "$case_dir/ws/note.fakels" "$case_dir/model.port" &
  MODEL_PID=$!
  wait_for 20 test -s "$case_dir/model.port" || fail "$1: the scripted model did not start"
  cat > "$case_dir/home/.omp/agent/models.yml" <<YML
providers:
  lab:
    baseUrl: http://127.0.0.1:$(cat "$case_dir/model.port")/v1
    apiKey: lab-key
    api: openai-completions
    models:
      - id: m1
        contextWindow: 200000
        maxTokens: 4096
YML
  python3 -I - "$LAB/fakels.py" "$case_dir/markers" > "$case_dir/ws/lsp.json" <<'PY2'
import json, sys
print(json.dumps({"servers": {"fakels": {"command": "python3", "args": ["-I", sys.argv[1], sys.argv[2]],
                                         "fileTypes": [".fakels"], "rootMarkers": ["lsp.json"], "languageId": "fakels"}}}))
PY2
}

# run_omp <case> <stdin> <extra omp flags...>: replaces its shell with omp, so
# call it in a subshell (foreground) or in the background.
run_omp() {
  local case_dir=$LAB/$1 stdin=$2
  shift 2
  HOME="$case_dir/home" OMP_SKIP_SETUP=1 exec omp --mode rpc --no-session --model lab/m1 \
    --auto-approve --cwd "$case_dir/ws" "$@" < "$stdin" > "$case_dir/rpc.out" 2> "$case_dir/rpc.err"
}

# check_case <case> <expect> <omp flag...>: <expect> is `on` for the control run
# and `off` for a run whose overlays turn the language server off.
check_case() {
  local name=$1 expect=$2 case_dir rc started fifo pid
  shift 2
  case_dir=$LAB/$name
  prepare "$name"

  # 1. Ask for the lsp tool by name; omp refuses the session when it is off.
  (run_omp "$name" /dev/null --tools lsp "$@")
  rc=$?
  if [ "$expect" = on ]; then
    [ "$rc" -eq 0 ] || fail "$name: omp exited $rc when asked for the lsp tool with no overlay ($OMP_VERSION): $(head -c 300 "$case_dir/rpc.err")"
  else
    [ "$rc" -ne 0 ] || fail "$name: omp accepted the lsp tool, so the overlays did not turn the language server off ($OMP_VERSION)"
    grep -qi 'lsp' "$case_dir/rpc.err" || fail "$name: omp exited $rc without naming the lsp tool ($OMP_VERSION): $(head -c 300 "$case_dir/rpc.err")"
  fi

  # 2. Write a file the fixture server claims, then look for a started server.
  fifo=$case_dir/rpc.in
  mkfifo "$fifo"
  run_omp "$name" "$fifo" "$@" &
  pid=$!
  exec 3> "$fifo"
  wait_for 60 grep -q '"type":"ready"' "$case_dir/rpc.out" || { exec 3>&-; fail "$name: omp never became ready ($OMP_VERSION): $(head -c 300 "$case_dir/rpc.err")"; }
  printf '%s\n' '{"id":"p1","type":"prompt","message":"write the file"}' >&3
  wait_for 90 grep -q '"type":"agent_end"' "$case_dir/rpc.out" || { exec 3>&-; fail "$name: the scripted turn never finished ($OMP_VERSION)"; }
  if [ "$expect" = on ]; then
    wait_for 20 marker_started "$case_dir/markers" || true
  else
    sleep 3
  fi
  exec 3>&-
  wait_for 20 process_gone "$pid" || kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  kill "$MODEL_PID" 2>/dev/null
  wait "$MODEL_PID" 2>/dev/null
  [ -s "$case_dir/ws/note.fakels" ] || fail "$name: the write never reached the file, so the case proves nothing ($OMP_VERSION)"
  started=$(find "$case_dir/markers" -name 'started.*' | wc -l | tr -d ' ')
  if [ "$expect" = on ]; then
    [ "$started" -ge 1 ] || fail "$name: the control run started no language server, so this probe can no longer see one ($OMP_VERSION)"
  else
    [ "$started" -eq 0 ] || fail "$name: $started language server process(es) started although the overlays turn it off ($OMP_VERSION)"
  fi
}

check_case control on
pass "no overlay: omp offers the lsp tool and starts a language server on a write"

# Secondmate launch: bin/fm-spawn.sh layers only the session overlay.
check_case secondmate off --config "$SESSION_OVERLAY"
pass "session overlay alone (secondmate launch): no lsp tool and no language server"

# Worker overlay alone: it must not depend on the session overlay.
check_case worker-alone off --config "$WORKER_OVERLAY"
pass "worker overlay alone: no lsp tool and no language server"

# Crewmate and scout launch: session overlay, then worker overlay.
check_case crewmate off --config "$SESSION_OVERLAY" --config "$WORKER_OVERLAY"
pass "session then worker overlay (crewmate and scout launch): no lsp tool and no language server"
