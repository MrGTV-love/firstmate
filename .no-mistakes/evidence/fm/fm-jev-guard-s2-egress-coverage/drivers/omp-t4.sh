#!/usr/bin/env bash
# Disposable live driver: real installed omp + real Jev guard extension + private scripted provider.
# Usage: omp-t4.sh <repo-root>
set -u
ROOT=$1
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG FM_GUARD_EVENT_LOG
lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-t4-omp.XXXXXX"); chmod 700 "$lab"
export FM_JEV_NATIVE_LAB="$lab"
cleanup() { [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null; wait 2>/dev/null; rm -rf -- "$lab"; }
trap cleanup EXIT
mkdir -p "$lab/tmp" "$lab/os-home" "$lab/agent"
: > "$lab/jev.jsonl"; : > "$lab/model.jsonl"
echo '{"phase":"normal","tool":"read"}' > "$lab/scenario.json"
python3 -I "$ROOT/tests/fm-jev-guard-native-fixture.py" "$lab" omp > "$lab/server.out" 2>&1 &
SPID=$!
for _ in $(seq 1 40); do [ -s "$lab/port" ] && break; sleep 0.25; done
base="http://127.0.0.1:$(cat "$lab/port")"
export FM_JEV_GUARD_BASE_URL="$base/v1/systemone"
cat > "$lab/extension.ts" <<TS
import { installJevGuard } from "$ROOT/bin/fm-jev-guard.ts";
export default function (pi: any) {
  const lab = process.env.FM_JEV_NATIVE_LAB!;
  installJevGuard(pi, { home: \`\${lab}/home\`, config: \`\${lab}/home/config\`, state: \`\${lab}/home/state\`,
    task: "native", data: \`\${lab}/home/data\`, worktree: \`\${lab}/worktree\`, project: "firstmate",
    policy: "FIRSTMATE_JEV_GUARD_V1" });
}
TS
# A host tool that is NOT in TOOL_POLICY, added by an extension the way a new paid tool would appear.
cat > "$lab/newtool.ts" <<TS
import { writeFileSync } from "node:fs";
export default function (pi: any) {
  pi.registerTool({ name: "new_paid_host_tool", label: "new", description: "Synthetic unclassified host tool.",
    loadMode: "essential", parameters: { type: "object", properties: { q: { type: "string" } } },
    async execute() { writeFileSync(\`\${process.env.FM_JEV_NATIVE_LAB}/newtool-executed\`, "ran");
      return { content: [{ type: "text", text: "new-tool-ran" }] }; } });
}
TS
cat > "$lab/agent/config.yml" <<'YML'
setupVersion: 2
modelRoles:
  default: native/gpt-6.1-sol
retry:
  maxRetries: 0
  fallbackChains: {}
find:
  enabled: on
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
run_case() {  # <name> <tool> <args-json> <grant-or-empty> <tools-list>
  local name=$1 tool=$2 args=$3 grant=$4 tools=$5
  rm -rf -- "$lab/home" "$lab/worktree" "$lab/newtool-executed"
  mkdir -p "$lab/home/config" "$lab/home/state" "$lab/home/data" "$lab/worktree"
  printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$lab/home/.env"
  [ -z "$grant" ] || printf 'egress=%s\n' "$grant" > "$lab/home/state/native.meta"
  jq -n --arg tool "$tool" --argjson args "$args" '{phase:"normal",tool:$tool,benign:true,args:$args}' > "$lab/scenario.json"
  : > "$lab/model.jsonl"; : > "$lab/jev.jsonl"
  curl --max-time 10 -fsS -X POST -d '{}' "$base/reset" > /dev/null
  (cd "$lab/worktree" && HOME="$lab/os-home" PI_CODING_AGENT_DIR="$lab/agent" OMP_SKIP_SETUP=1 TMPDIR="$lab/tmp" \
    timeout 120 omp -p "Use the one tool call, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
    --no-extensions -e "$lab/extension.ts" -e "$lab/newtool.ts" --config "$ROOT/.omp/fm-worker-overlay.yml" \
    --no-skills --no-rules --no-title --no-lsp --tools "$tools" < /dev/null > "$lab/native.out" 2>&1)
  local status=$?
  echo "=== CASE $name: omp tool=$tool grant=${grant:-none} exit=$status"
  echo "--- tool result the model saw next (from the follow-up provider request):"
  tail -n 1 "$lab/model.jsonl" | jq -c '[.input[]? | select(.type=="function_call_output") | .output] ' 2>/dev/null | cut -c1-400
  echo "--- jev-guard.jsonl decision row(s):"
  if [ -s "$lab/home/state/jev-guard.jsonl" ]; then jq -c '{hook,tool,decision,enforcement,branch,destination_class,confinement_owner,request_started}' "$lab/home/state/jev-guard.jsonl"; else echo "(none)"; fi
  echo "--- central guard-events.jsonl:"
  if [ -s "$lab/home/state/guard-events.jsonl" ]; then jq -c '{guard,decision,session,system}' "$lab/home/state/guard-events.jsonl"; else echo "(none)"; fi
  echo "--- extension tool body executed: $([ -e "$lab/newtool-executed" ] && echo yes || echo no)"
  echo "--- canary leak check (call content in audit/events): $(cat "$lab/home/state/"*.jsonl 2>/dev/null | grep -c 'private-canary' || true) occurrences"
}
echo "omp: $(omp --version)"
run_case "T4(b) find, no grant" find '{"query":"private-canary query","grep_keywords":["canary"]}' "" find
run_case "T4(b) find, egress=[semantic-search]" find '{"query":"private-canary query","grep_keywords":["canary"]}' '["semantic-search"]' find
run_case "web_search, no grant" web_search '{"query":"private-canary query"}' "" web_search
run_case "T4(a) write xd://report_issue, all grants" write '{"path":"xd://report_issue","content":"private-canary report"}' '["semantic-search","web","browser","provider","subagent","dynamic-code","remote-storage"]' write
run_case "T4(c) eval" eval '{"language":"py","code":"print(\"eval-ran\")"}' "" eval
run_case "T4(d) unclassified extension tool" new_paid_host_tool '{"q":"private-canary"}' "" new_paid_host_tool
run_case "local glob stays allowed" glob '{"pattern":"*"}' "" glob
