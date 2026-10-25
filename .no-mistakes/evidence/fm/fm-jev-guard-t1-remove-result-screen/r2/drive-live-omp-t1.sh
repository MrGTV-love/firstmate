#!/usr/bin/env bash
# Round 2 (head 4e3f56487 after T2 rebase): pre-tool deny case now uses the write tool; bash is no longer pre-tool judged.
# Live T1 driver: real omp + guard extension (head or base tree), private scripted providers.
# Usage: drive.sh <tree-root> <label> <evidence-dir>
set -u
TREE=$1 LABEL=$2 EV=$3 HEAD_ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5QFP1AD1JFXC1VXK7Q6PYK2
. "$HEAD_ROOT/bin/fm-timeout-lib.sh"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG ANTHROPIC_OAUTH_TOKEN CLAUDECODE OPENAI_API_KEY ANTHROPIC_API_KEY
lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-t1-live.XXXXXX"); chmod 700 "$lab"
export FM_JEV_NATIVE_LAB="$lab" FM_TEST_SEAM=1
cleanup() { [ -z "${PID:-}" ] || { kill "$PID"; wait "$PID"; } 2>/dev/null; rm -rf -- "$lab"; }
trap cleanup EXIT
mkdir -p "$lab/tmp" "$lab/os-home" "$lab/agent"; export TMPDIR="$lab/tmp"
# Stub Jev: pre-tool judgments follow scenario.benign; any result-screen request (source_role tool_result) is flagged 0.99.
python3 - "$HEAD_ROOT/tests/fm-jev-guard-native-fixture.py" "$lab/fixture.py" <<'PY'
import sys
src = open(sys.argv[1]).read()
old_n = "answers[key] = {'type': 'noul', 'noul': 0.0 if scenario.get('benign') else 0.99}"
old_c = "pick = 'irreversible' if 'irreversible' in choices and not scenario.get('benign') else choices[0]"
assert old_n in src and old_c in src
src = src.replace(old_n, "benign = scenario.get('benign') and body['state'].get('source_role') != 'tool_result'\n                    answers[key] = {'type': 'noul', 'noul': 0.0 if benign else 0.99}")
src = src.replace(old_c, "pick = 'irreversible' if 'irreversible' in choices and not (scenario.get('benign') and body['state'].get('source_role') != 'tool_result') else choices[0]")
open(sys.argv[2], 'w').write(src)
PY
: > "$lab/jev.jsonl"; : > "$lab/model.jsonl"
python3 -I "$lab/fixture.py" "$lab" omp > "$lab/server.out" 2>&1 & PID=$!
for _ in $(seq 100); do [ -s "$lab/port" ] && break; sleep 0.2; done
base="http://127.0.0.1:$(cat "$lab/port")"; export FM_JEV_GUARD_BASE_URL="$base/v1/systemone"
cat > "$lab/extension.ts" <<TS
import { installJevGuard } from "$TREE/bin/fm-jev-guard.ts";
export default function (pi: any) {
  const lab = process.env.FM_JEV_NATIVE_LAB!;
  installJevGuard(pi, { home: \`\${lab}/home\`, config: \`\${lab}/home/config\`, state: \`\${lab}/home/state\`,
    task: "native", data: \`\${lab}/home/data\`, worktree: \`\${lab}/worktree\`, project: "firstmate",
    policy: "FIRSTMATE_JEV_GUARD_V1" });
}
TS
cat > "$lab/agent/config.yml" <<'YML'
setupVersion: 2
modelRoles:
  default: native/gpt-6.1-sol
retry:
  maxRetries: 0
  fallbackChains: {}
async:
  enabled: true
YML
cat > "$lab/agent/models.yml" <<YML
providers:
  native:
    baseUrl: $base/v1
    apiKey: synthetic-local-only
    api: openai-responses
    models:
      - id: gpt-6.1-sol
        contextWindow: 200000
        maxTokens: 4096
YML
cp /Users/charlesabrooker/firstmate/data/fm-herdr-twin-server-root-cause/nm-drive-45.log "$lab/nm-drive-45.log"
run_case() {  # <name> <scenario-json>
  local name=$1 out="$EV/$LABEL-$1"
  rm -rf -- "$lab/home" "$lab/worktree"; mkdir -p "$lab/home/config" "$lab/home/state" "$lab/home/data" "$lab/worktree"
  printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$lab/home/.env"
  printf '%s' "$2" > "$lab/scenario.json"; : > "$lab/jev.jsonl"; : > "$lab/model.jsonl"
  curl --max-time 10 -fsS -X POST -d '{}' "$base/reset" > /dev/null
  (cd "$lab/worktree" && HOME="$lab/os-home" PI_CODING_AGENT_DIR="$lab/agent" OMP_SKIP_SETUP=1 \
    fm_run_timed 120 omp -p "Run the one shell command, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
    --no-extensions -e "$lab/extension.ts" --config "$TREE/.omp/fm-worker-overlay.yml" --no-skills --no-rules --no-title --no-lsp --tools bash,write \
    < /dev/null > "$lab/native.out" 2>&1)
  echo "omp exit=$?" > "$out.omp-exit"
  cp "$lab/native.out" "$out.omp-stdout.txt"
  # What reached the next model turn (the worker's context) for the shell call.
  python3 -I - "$lab/model.jsonl" > "$out.delivered.txt" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
outs = [i for r in rows[1:2] for i in r.get('input', []) if i.get('type') == 'function_call_output']
text = outs[0]['output'] if outs else '<no function_call_output>'
try:
    s = json.loads(text)
    if isinstance(s, list): text = '\n'.join(p.get('text', '') for p in s if isinstance(p, dict))
except Exception: pass
sys.stdout.write(text)
PY
  python3 -I - "$lab/jev.jsonl" > "$out.jev-requests.json" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(json.dumps([{'state_keys': sorted(r['state'].keys()), 'source_role': r['state'].get('source_role'), 'tool': r['state'].get('tool')} for r in rows], indent=1))
PY
  if [ -f "$lab/home/state/jev-guard.jsonl" ]; then
    jq -c '{hook, tool, decision, enforcement, branch, error_type}' "$lab/home/state/jev-guard.jsonl" > "$out.audit.jsonl"
  else : > "$out.audit.jsonl"; fi
  echo "== $LABEL/$name"; cat "$out.omp-exit"; echo "-- delivered to worker:"; cat "$out.delivered.txt"; echo; echo "-- jev requests:"; cat "$out.jev-requests.json"; echo "-- audit:"; cat "$out.audit.jsonl"
}
run_case a-background-notice "$(jq -n '{phase:"normal",tool:"bash",benign:true,args:{command:"sleep 3; echo finished",async:true}}')"
run_case b-bounded-wait "$(jq -n --arg c "cat $lab/nm-drive-45.log" '{phase:"normal",tool:"bash",benign:true,args:{command:$c}}')"
run_case b-bounded-wait-exit1 "$(jq -n --arg c "cat $lab/nm-drive-45.log; exit 1" '{phase:"normal",tool:"bash",benign:true,args:{command:$c}}')"
run_case large-result "$(jq -n '{phase:"normal",tool:"bash",benign:true,args:{command:"head -c 300000 /dev/zero | tr \"\\\\0\" x"}}')"
run_case pretool-deny "$(jq -n --arg m "$lab/worktree/denied-ran" '{phase:"normal",tool:"write",benign:false,args:{path:$m,content:"ran",i:"Write one fixture file"}}')"
echo "pretool marker exists: $([ -e "$lab/worktree/denied-ran" ] && echo yes || echo no)" | tee "$EV/$LABEL-pretool-deny.marker.txt"
