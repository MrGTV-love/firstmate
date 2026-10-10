#!/usr/bin/env bash
# tests/fm-omp-fallback-chain-live-e2e.test.sh - the live omp fallback-chain guard
# (live-harness-optin family; task fm-omp-sol-fallback-downgrade).
#
# On 2026-10-09 a lane recorded on openai-codex/gpt-6.1-sol fell to
# openrouter/deepseek/deepseek-v4-flash. The operator's global omp config chained
# Sol to its equal and then on to DeepSeek, so when the equal answered 402 and
# 401, omp moved the lane to a model far weaker than the one it was recorded on,
# and it stayed there. Fleet agents also run on no OpenRouter route, so the
# tracked overlay now empties the Sol chain. This guard drives the INSTALLED omp
# against scripted local providers that stand in for the real routes (the
# built-in openai-codex and deepseek providers are pointed at them through the
# isolated agent directory's models.yml), so it spends no model tokens, and
# requires through the tracked session overlay that Firstmate launches omp with:
#   1. control: the global chain alone still reaches the weak model, so the lab
#      reproduces the incident and the next checks cannot pass vacuously;
#   2. the overlay stops the Sol chain: when the primary fails, the weak model
#      receives no request, the run ends with the provider's error, and the
#      live-model record carries that error and the recorded model
#      (bin/fm-omp-live-model.ts);
#   3. return: for a chain that remains (the lab layers one on after the tracked
#      overlay), omp's own revert restores the recorded model at the next prompt
#      after the primary's suppression window ends, even when the global config
#      says `fallbackRevertPolicy: never`, and the record follows;
#   4. control: without the overlay, `never` leaves the session on the fallback.
# It fails naming omp and `omp --version`. Refresh docs/verification/runtime-backends.md
# ("omp fallback chain") from its output after any omp upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OMP_FALLBACK_LIVE omp python3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB=$(fm_test_tmproot fm-omp-fallback)
OVERLAY="$ROOT/.omp/fm-session-overlay.yml"
VERSION=$(omp --version 2>/dev/null | head -1)
SUBJECT="omp ($VERSION)"
SERVER_PIDS=()
cleanup() {
  local pid
  for pid in "${SERVER_PIDS[@]:-}"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

# A scripted provider. Behaviors:
#   ok [delay]        answers "ack" after delay seconds
#   credits           always 402
#   limit <seconds>   always 429 with that retry-after
#   flaky             the first request refused as a concurrency limit, which omp
#                     suppresses for 5 seconds (a provider's own retry-after that
#                     short is waited out inside the provider call, so no
#                     fallback would be needed), then answers
#   split             402 for a Sol model id, answers any other model
cat > "$LAB/server.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
behavior, log_path, port_path = sys.argv[1], sys.argv[2], sys.argv[3]
param = float(sys.argv[4]) if len(sys.argv) > 4 else 0
seen = {"n": 0}
def fail(h, code, message, retry=None):
    data = json.dumps({"error": {"message": message, "code": code}}).encode()
    h.send_response(code)
    if retry is not None: h.send_header("retry-after", str(int(retry)))
    h.send_header("content-type", "application/json"); h.send_header("content-length", str(len(data))); h.end_headers(); h.wfile.write(data)
def stream(h, events):
    h.send_response(200); h.send_header("content-type", "text/event-stream"); h.end_headers()
    for event in events: h.wfile.write(b"data: " + json.dumps(event).encode() + b"\n\n")
    h.wfile.write(b"data: [DONE]\n\n"); h.wfile.flush()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        seen["n"] += 1
        with open(log_path, "a") as log: log.write(str(body.get("model")) + "\n")
        if behavior == "limit":
            return fail(self, 429, "You have hit your usage limit. Try again later.", param)
        if behavior == "flaky" and seen["n"] == 1:
            return fail(self, 402, "Too many concurrent requests: concurrency limit reached.")
        if behavior == "credits" or (behavior == "split" and "gpt-6.1-sol" in str(body.get("model"))):
            return fail(self, 402, "This request would exceed your available credits.")
        if behavior == "ok": time.sleep(param)
        item = {"type": "message", "id": "m1", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": "ack"}]}
        stream(self, [
            {"type": "response.created", "response": {"id": "r1", "status": "in_progress"}},
            {"type": "response.output_item.added", "output_index": 0, "item": dict(item, status="in_progress", content=[])},
            {"type": "response.content_part.added", "output_index": 0, "item_id": "m1", "content_index": 0, "part": {"type": "output_text", "text": ""}},
            {"type": "response.output_text.delta", "output_index": 0, "item_id": "m1", "content_index": 0, "delta": "ack"},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": {"id": "r1", "status": "completed", "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}},
        ])
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open(port_path, "w").write(str(server.server_address[1]))
server.serve_forever()
PY

# The publisher under test, loaded exactly as the generated per-task extension
# and the home extension load it.
cat > "$LAB/publisher.ts" <<TS
import { installLiveModelPublisher } from "$ROOT/bin/fm-omp-live-model.ts";
export default function (pi: any) {
  installLiveModelPublisher(pi, process.env.FM_LAB_RECORD!);
}
TS

# Replaces any earlier provider of the same name; <name>_PORT and $LAB/<name>.log
# belong to the newest one.
serve() {  # <name> <behavior> [param]
  local name=$1 behavior=$2 param=${3:-0} old
  old=$(cat "$LAB/$name.pid" 2>/dev/null || true)
  [ -z "$old" ] || kill "$old" 2>/dev/null || true
  : > "$LAB/$name.log"
  rm -f "$LAB/$name.port"
  python3 -I "$LAB/server.py" "$behavior" "$LAB/$name.log" "$LAB/$name.port" "$param" &
  SERVER_PIDS+=("$!")
  printf '%s\n' "$!" > "$LAB/$name.pid"
  fm_test_wait_until 20 test -s "$LAB/$name.port" || fail "$SUBJECT: the scripted $name provider did not start"
  printf -v "${name}_PORT" '%s' "$(cat "$LAB/$name.port")"
}

# shellcheck disable=SC2154  # <name>_PORT is assigned by serve through printf -v
# An isolated agent directory holding the operator's chain as it stands.
# $1 name, $2 fallbackRevertPolicy, $3 maxDelayMs
agent_dir() {
  local dir="$LAB/agent-$1"
  mkdir -p "$dir"
  cat > "$dir/config.yml" <<YML
setupVersion: 2
modelRoles:
  default: openai-codex/gpt-6.1-sol
retry:
  maxRetries: 2
  baseDelayMs: 100
  maxDelayMs: $3
  fallbackRevertPolicy: $2
  fallbackChains:
    openai-codex/gpt-6.1-sol:
      - deepseek/deepseek-v4-pro
YML
  cat > "$dir/models.yml" <<YML
providers:
  openai-codex: {baseUrl: http://127.0.0.1:${codex_PORT}/v1, apiKey: lab}
  deepseek: {baseUrl: http://127.0.0.1:${weak_PORT}/v1, apiKey: lab}
  lab-equal: {baseUrl: http://127.0.0.1:${equal_PORT}/v1, apiKey: lab, api: openai-responses, models: [{id: gpt-6.1-sol, contextWindow: 200000, maxTokens: 4096}]}
YML
  printf '%s\n' "$dir"
}

# A chain that remains after the tracked overlay, layered on after it the way a
# later --config wins: the primary falls to a lab-only equal route.
cat > "$LAB/lab-chain.yml" <<YML
retry:
  fallbackChains:
    openai-codex/gpt-6.1-sol:
      - lab-equal/gpt-6.1-sol
YML

# run_omp <agent-dir> <overlay|none> <message>... -> sets OUT and RC
# EXTRA_CONFIG, when set, is layered on after the overlay.

run_omp() {
  local dir=$1 overlay=$2 args=()
  shift 2
  [ "$overlay" = none ] || args=(--config "$overlay")
  [ -z "${EXTRA_CONFIG:-}" ] || args+=(--config "$EXTRA_CONFIG")
  rm -f "$LAB/record"
  OUT=$(cd "$LAB" && PI_CODING_AGENT_DIR=$dir OMP_SKIP_SETUP=1 FM_LAB_RECORD="$LAB/record" \
    timeout 240 omp -p "$@" ${args[@]+"${args[@]}"} -e "$LAB/publisher.ts" --no-session \
    --model openai-codex/gpt-6.1-sol --thinking off </dev/null 2>&1)
  RC=$?
}
requests() { wc -l < "$LAB/$1.log" | tr -d ' '; }
record_has() { grep -qF -- "$1" "$LAB/record" 2>/dev/null; }

# --- 1 and 2: the chain --------------------------------------------------------
serve codex limit 3600
serve weak ok
serve equal ok
AGENT=$(agent_dir chain never 300000)

run_omp "$AGENT" none "say hi"
[ "$(grep -c '^deepseek-v4-pro$' "$LAB/weak.log")" -ge 1 ] \
  || fail "$SUBJECT: without the overlay the global chain no longer reaches the weak model, so the lab does not reproduce the incident (weak saw: $(tr '\n' ' ' < "$LAB/weak.log")); output: $OUT"
pass "$SUBJECT: control - the global Sol chain alone still falls to the weak model"

: > "$LAB/codex.log"; : > "$LAB/weak.log"
run_omp "$AGENT" "$OVERLAY" "say hi"
[ "$(requests codex)" -ge 1 ] \
  || fail "$SUBJECT: with the overlay the Sol session never tried its recorded model; output: $OUT"
[ "$(requests weak)" -eq 0 ] \
  || fail "$SUBJECT: with the overlay the Sol session reached the weak model after its recorded model failed: $(tr '\n' ' ' < "$LAB/weak.log")"
[ "$(requests equal)" -eq 0 ] || fail "$SUBJECT: with the overlay the Sol session left its recorded model for another route"
[ "$RC" -ne 0 ] || fail "$SUBJECT: with the recorded model failing the run must stop with an error, but it exited 0: $OUT"
case "$OUT" in *"rate limit exceeded"*) ;; *) fail "$SUBJECT: the stopped run did not report the provider's error: $OUT" ;; esac
record_has "model=openai-codex/gpt-6.1-sol" \
  || fail "$SUBJECT: the live-model record does not name the recorded model that stopped: $(cat "$LAB/record" 2>/dev/null)"
record_has "error=" \
  || fail "$SUBJECT: the live-model record does not carry the unrecovered run error: $(cat "$LAB/record" 2>/dev/null)"
pass "$SUBJECT: the overlay empties the Sol chain, the run stops with the provider error, and the record carries it"

# --- 3 and 4: the return -------------------------------------------------------
# The primary refuses once and omp suppresses it for 5 seconds, the equal answers
# slowly enough for that window to end, and the second message is the next prompt.
serve codex flaky
serve equal ok 6
AGENT=$(agent_dir return never 300000)

EXTRA_CONFIG="$LAB/lab-chain.yml"
run_omp "$AGENT" "$OVERLAY" "one" "two"
[ "$RC" -eq 0 ] || fail "$SUBJECT: the return scenario failed (rc=$RC): $OUT"
[ "$(requests codex)" -ge 2 ] || fail "$SUBJECT: after its window ended the recorded model was not tried again at the next prompt (codex saw $(requests codex), equal saw $(requests equal))"
[ "$(requests equal)" -ge 1 ] || fail "$SUBJECT: the first prompt never ran on the chain's route while the primary refused"
record_has "model=openai-codex/gpt-6.1-sol" \
  || fail "$SUBJECT: the live-model record did not follow the session back to the recorded model: $(cat "$LAB/record" 2>/dev/null)"
pass "$SUBJECT: with the overlay a fallen-back session returns to its recorded model at the next prompt even under a global fallbackRevertPolicy: never"

serve codex flaky
serve equal ok 6
AGENT=$(agent_dir return never 300000)
run_omp "$AGENT" none "one" "two"
[ "$(requests codex)" -eq 1 ] \
  || fail "$SUBJECT: control - without the overlay a global 'never' no longer keeps the session on its fallback, so the return check proves nothing (codex saw $(requests codex))"
pass "$SUBJECT: control - without the overlay a global fallbackRevertPolicy: never keeps the session on the fallback"
