#!/usr/bin/env bash
# Disposable live driver: real installed Claude Code + the PreToolUse ".*" guard hook fm-spawn writes
# + private scripted Anthropic-compatible provider (no real login, no paid model).
# Usage: claude-t4.sh <repo-root>
set -u
ROOT=$1; D=$(cd "$(dirname "$0")" && pwd)
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG FM_GUARD_EVENT_LOG ANTHROPIC_OAUTH_TOKEN CLAUDECODE CLAUDE_CODE_OAUTH_TOKEN
lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-t4-claude.XXXXXX"); chmod 700 "$lab"
export FM_JEV_NATIVE_LAB="$lab" FM_T4_MARK="$lab/mcp-executed"
cleanup() { [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null; wait 2>/dev/null; rm -rf -- "$lab"; }
trap cleanup EXIT
mkdir -p "$lab/tmp" "$lab/os-home" "$lab/claude"
: > "$lab/jev.jsonl"; : > "$lab/model.jsonl"
echo '{"phase":"normal","tool":"glob"}' > "$lab/scenario.json"
python3 -I "$D/fixture.py" "$lab" claude > "$lab/server.out" 2>&1 &
SPID=$!
for _ in $(seq 1 40); do [ -s "$lab/port" ] && break; sleep 0.25; done
base="http://127.0.0.1:$(cat "$lab/port")"
export FM_JEV_GUARD_BASE_URL="$base/v1/systemone"
hook="$(printf '%q ' "$ROOT/bin/fm-jev-guard-hook.sh" "$lab/home" "$lab/home/config" "$lab/home/state" native "$lab/worktree" "$lab/home/data" firstmate FIRSTMATE_JEV_GUARD_V1)"
# Same PreToolUse shape fm-spawn.sh now writes: one ".*" matcher, no PostToolUse.
jq -n --arg command "$hook" '{hooks:{PreToolUse:[{matcher:".*",hooks:[{type:"command",command:$command,timeout:330}]}]}}' > "$lab/settings.json"
jq -n --arg key synthetic-local-only '{hasCompletedOnboarding:true,customApiKeyResponses:{approved:[$key],rejected:[]}}' > "$lab/claude/.claude.json"
mcp=$(jq -nc --arg py "$(command -v python3)" --arg srv "$D/mcp.py" '{mcpServers:{synth:{type:"stdio",command:$py,args:["-I",$srv]}}}')
run_case() {  # <name> <tool-lowercase> <args-json> <grant-or-empty> <--tools list> <allowed list>
  local name=$1 tool=$2 args=$3 grant=$4 tools=$5 allowed=$6
  rm -rf -- "$lab/home" "$lab/worktree" "$FM_T4_MARK"
  mkdir -p "$lab/home/config" "$lab/home/state" "$lab/home/data" "$lab/worktree"
  printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$lab/home/.env"
  [ -z "$grant" ] || printf 'egress=%s\n' "$grant" > "$lab/home/state/native.meta"
  jq -n --arg tool "$tool" --argjson args "$args" '{phase:"normal",tool:$tool,benign:true,args:$args}' > "$lab/scenario.json"
  : > "$lab/model.jsonl"; : > "$lab/jev.jsonl"
  curl --max-time 10 -fsS -X POST -d '{}' "$base/reset" > /dev/null
  (cd "$lab/worktree" && HOME="$lab/os-home" CLAUDE_CONFIG_DIR="$lab/claude" TMPDIR="$lab/tmp" \
    ANTHROPIC_API_KEY=synthetic-local-only ANTHROPIC_BASE_URL="$base" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
    timeout 120 claude -p "Use the one tool call, then stop." --model claude-sonnet-4-6 --tools "$tools" --allowedTools "$allowed" \
    --setting-sources '' --settings "$lab/settings.json" --strict-mcp-config --mcp-config "$mcp" \
    --no-session-persistence --disable-slash-commands --output-format stream-json --verbose < /dev/null > "$lab/native.out" 2>&1)
  local status=$?
  echo "=== CASE $name: claude tool=$tool grant=${grant:-none} exit=$status"
  echo "--- tool_use name Claude emitted: $(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name' "$lab/native.out" 2>/dev/null | head -1)"
  echo "--- tool result Claude returned to the model:"
  jq -c 'select(.type=="user") | [.message.content[]? | select(.type=="tool_result") | {is_error, content: (.content|tostring|.[0:330])}]' "$lab/native.out" 2>/dev/null | head -1
  echo "--- jev-guard.jsonl decision row(s):"
  if [ -s "$lab/home/state/jev-guard.jsonl" ]; then jq -c '{hook,tool,decision,enforcement,branch,destination_class,confinement_owner,request_started}' "$lab/home/state/jev-guard.jsonl"; else echo "(none)"; fi
  echo "--- central guard-events.jsonl:"
  if [ -s "$lab/home/state/guard-events.jsonl" ]; then jq -c '{guard,decision,session,system}' "$lab/home/state/guard-events.jsonl"; else echo "(none)"; fi
  echo "--- MCP tool body executed: $([ -e "$FM_T4_MARK" ] && echo yes || echo no)"
  echo "--- canary leak check (call content in audit/events): $(cat "$lab/home/state/"*.jsonl 2>/dev/null | grep -c 'private-canary' || true) occurrences"
}
echo "claude: $(claude --version)"
run_case "WebFetch, no grant" webfetch '{"url":"https://example.invalid/private-canary","prompt":"summarize"}' "" WebFetch WebFetch
run_case "WebFetch, egress=[web]" webfetch '{"url":"https://example.invalid/private-canary","prompt":"summarize"}' '["web"]' WebFetch WebFetch
run_case "T4(d) unclassified MCP tool" mcp__synth__synthetic_upload '{"q":"private-canary"}' "" Glob mcp__synth__synthetic_upload
run_case "local Glob stays allowed" glob '{"pattern":"*"}' "" Glob Glob
run_case "Bash keeps shell screening" bash '{"command":"echo shell-ran","description":"echo"}' "" Bash Bash
