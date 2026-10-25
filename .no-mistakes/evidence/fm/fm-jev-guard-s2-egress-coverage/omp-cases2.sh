#!/usr/bin/env bash
# Usage: omp-cases.sh <worktree-root> <evidence-file>
set -u
ROOT=$1 out=$2
lab=$(mktemp -d /tmp/fm-t4-omp.XXXXXX); chmod 700 "$lab"
export FM_JEV_NATIVE_LAB="$lab"
mkdir -p "$lab/tmp" "$lab/os-home" "$lab/agent"
: > "$lab/jev.jsonl"; : > "$lab/model.jsonl"
python3 -I "$ROOT/tests/fm-jev-guard-native-fixture.py" "$lab" omp > "$lab/server.out" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; cp "$lab"/model.jsonl "$lab"/*.out /tmp/fm-t4-scripts/dbg/ 2>/dev/null; rm -rf "$lab"' EXIT
for _ in $(seq 100); do [ -s "$lab/port" ] && break; sleep 0.1; done
base="http://127.0.0.1:$(cat "$lab/port")"
export FM_JEV_GUARD_BASE_URL="$base/v1/systemone"
cat > "$lab/extension.ts" <<TS
import { installJevGuard } from "$ROOT/bin/fm-jev-guard.ts";
export default function (pi: any) {
  const lab = process.env.FM_JEV_NATIVE_LAB!;
  installJevGuard(pi, { home: \`\${lab}/home\`, config: \`\${lab}/home/config\`, state: \`\${lab}/home/state\`,
    task: "t4omp", data: \`\${lab}/home/data\`, worktree: \`\${lab}/worktree\`, project: "firstmate",
    policy: "FIRSTMATE_JEV_GUARD_V1" });
}
TS
cat > "$lab/probe.ts" <<TS
import { writeFileSync } from "node:fs";
export default function (pi: any) {
  pi.registerTool({ name: "t4probe", label: "t4probe", description: "probe", loadMode: "essential",
    parameters: { type: "object", properties: { note: { type: "string" } } },
    async execute() { writeFileSync(process.env.FM_JEV_NATIVE_LAB + "/probe-marker", "ran"); return { content: [{ type: "text", text: "t4probe-ran" }] }; } });
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
run_case() {  # <name> <tool> <args-json> <grant-or-empty> <tools-list> [extra-ext]
  local name=$1 tool=$2 args=$3 grant=$4 tools=$5 extra=${6:-}
  rm -rf -- "$lab/home" "$lab/worktree" "$lab/probe-marker"
  mkdir -p "$lab/home/config" "$lab/home/state" "$lab/home/data" "$lab/worktree"
  printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$lab/home/.env"
  printf 'project=firstmate\n' > "$lab/home/state/t4omp.meta"
  [ -z "$grant" ] || printf 'egress=%s\n' "$grant" >> "$lab/home/state/t4omp.meta"
  jq -n --arg t "$tool" --argjson a "$args" '{phase:"normal",tool:$t,benign:true,args:$a}' > "$lab/scenario.json"
  : > "$lab/model.jsonl"; : > "$lab/jev.jsonl"
  curl --max-time 10 -fsS -X POST -d '{}' "$base/reset" > /dev/null
  local ext=(-e "$lab/extension.ts"); [ -z "$extra" ] || ext+=(-e "$extra")
  (cd "$lab/worktree" && env -i PATH="$PATH" HOME="$lab/os-home" TMPDIR="$lab/tmp" FM_JEV_NATIVE_LAB="$lab" FM_JEV_GUARD_BASE_URL="$FM_JEV_GUARD_BASE_URL" FM_TEST_SEAM=1 \
    HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost \
    PI_CODING_AGENT_DIR="$lab/agent" OMP_SKIP_SETUP=1 \
    perl -e 'alarm 120; exec @ARGV' omp -p "Use the one tool call, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
    --no-extensions "${ext[@]}" --config "$ROOT/.omp/fm-worker-overlay.yml" --no-skills --no-rules --no-title --no-lsp --tools "$tools" \
    < /dev/null > "$lab/$name.out" 2>&1)
  local rc=$?
  {
    echo "=== case $name: tool=$tool grant=${grant:-none} omp_exit=$rc"
    echo "tool output seen by next model turn:"
    tail -n 1 "$lab/model.jsonl" | jq -c '[.input[]? | select(.type=="function_call_output") | .output | tostring | .[0:420]]' 2>/dev/null
    echo "central guard events:"; [ -f "$lab/home/state/guard-events.jsonl" ] && jq -c '{guard,decision,session,source_ok}' "$lab/home/state/guard-events.jsonl"
    echo "jev-guard tool_call audit rows:"; [ -f "$lab/home/state/jev-guard.jsonl" ] && jq -c 'select(.hook=="tool_call") | {tool,decision,branch,destination_class,confinement_owner,request_started}' "$lab/home/state/jev-guard.jsonl"
    [ -z "$extra" ] || echo "probe tool body ran (must be no): $([ -e "$lab/probe-marker" ] && echo yes || echo no)"
    [ "$rc" = 0 ] || { echo "omp output tail:"; tail -5 "$lab/$name.out"; }
    echo
  } >> "$out"
}
echo "canary leak check in central events: $(cat /dev/null)" >/dev/null
run_case unlisted-extension-tool t4probe '{"note":"t4"}' '["semantic-search","web","browser","provider","subagent","dynamic-code","remote-storage"]' read,t4probe "$lab/probe.ts"
