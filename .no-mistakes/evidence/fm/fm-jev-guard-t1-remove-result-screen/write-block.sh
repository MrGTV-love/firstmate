#!/usr/bin/env bash
# Live: real omp + real guard extension + scripted local provider; bash tool results.
# usage: bash-verbatim.sh <firstmate-root> <label> <evidence-dir>
set -u
ROOT=$1 LABEL=$2 EV=$3
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG ANTHROPIC_OAUTH_TOKEN CLAUDECODE
lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-scn.XXXXXX"); chmod 700 "$lab"
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5REQVENED0S53C36GXTZPR6
cleanup(){ kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; rm -rf -- "$lab"; }
trap cleanup EXIT
mkdir -p "$lab/tmp" "$lab/os-home" "$lab/agent"
export FM_TEST_SEAM=1 TMPDIR="$lab/tmp" FM_JEV_NATIVE_LAB="$lab"
: > "$lab/jev.jsonl"; : > "$lab/model.jsonl"
python3 -I "$WT/tests/fm-jev-guard-native-fixture.py" "$lab" omp > "$lab/server.out" 2>&1 & PID=$!
for i in $(seq 100); do [ -s "$lab/port" ] && break; perl -e 'select undef,undef,undef,0.2'; done
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
printf 'setupVersion: 2\nmodelRoles:\n  default: native/gpt-6.1-sol\nretry:\n  maxRetries: 0\n  fallbackChains: {}\n' > "$lab/agent/config.yml"
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
printf 'Backgrounded as job bg_N; its output is injected into the conversation as a follow-up the moment it finishes. Do NOT poll for it (no `sleep`, `ps`, `pgrep`, `top`, `pidwait`, log tailing): every poll is a wasted turn. Do other work, or end your reply and wait to be woken.' > "$lab/case-a.txt"
rm -rf "$lab/home" "$lab/worktree"; mkdir -p "$lab/home/config" "$lab/home/state" "$lab/home/data" "$lab/worktree"
printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$lab/home/.env"
jq -n --arg p "$lab/worktree/flagged.txt" '{phase:"normal",tool:"write",args:{path:$p,content:"rm -rf everything",i:"Write one file"},benign:false}' > "$lab/scenario.json"
: > "$lab/jev.jsonl"; : > "$lab/model.jsonl"; curl -fsS -X POST -d '{}' "$base/reset" >/dev/null
(cd "$lab/worktree" && HOME="$lab/os-home" PI_CODING_AGENT_DIR="$lab/agent" OMP_SKIP_SETUP=1 \
  timeout 120 omp -p "Write the one file, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
  --no-extensions -e "$lab/extension.ts" --config "$WT/.omp/fm-worker-overlay.yml" --no-skills --no-rules --no-title --no-lsp --tools write \
  < /dev/null > "$lab/native.out" 2>&1); st=$?
{
echo "=== [$LABEL] flagged write: omp exit=$st"
echo "  file created: $([ -e "$lab/worktree/flagged.txt" ] && echo yes || echo no)"
echo "  TypeSafe (Jev) requests: $(wc -l < "$lab/jev.jsonl" | tr -d ' ')"
echo "  jev-guard.jsonl rows: $(jq -c '{hook,decision,enforcement,error_type}' "$lab/home/state/jev-guard.jsonl" 2>/dev/null | tr '\n' ' ')"
echo "  tool result sent to next model turn:"
jq -r '.input[]? | select(.type=="function_call_output") | .output' "$lab/model.jsonl" | tail -1 | cut -c1-400
} | tee -a "$EV/write-block-$LABEL.txt"
