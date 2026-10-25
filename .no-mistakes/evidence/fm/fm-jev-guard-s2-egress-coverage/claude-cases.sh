#!/usr/bin/env bash
# Usage: claude-cases.sh <lab> <evidence-file>
set -u
lab=$1 out=$2
mkdir -p "$lab/claude" "$lab/os-home"
jq -n --arg key synthetic-local-only '{hasCompletedOnboarding:true,customApiKeyResponses:{approved:[$key],rejected:[]}}' > "$lab/claude/.claude.json"
: > "$lab/model.jsonl"
python3 -I /tmp/fm-t4-scripts/anthropic-mock.py "$lab" > "$lab/mock.out" 2>&1 & mock=$!
trap 'kill $mock 2>/dev/null' EXIT
for _ in $(seq 50); do [ -s "$lab/port" ] && break; sleep 0.1; done
base="http://127.0.0.1:$(cat "$lab/port")"
state="$lab/home/state"; meta="$state/t4claude.meta"
printf 'fm-t4-local-file-canary\n' > "$lab/wt/local.txt"
events() { wc -l < "$state/guard-events.jsonl" 2>/dev/null | tr -d ' ' || echo 0; }
run_case() {  # <name> <tool> <input-json> <grant-or-empty>
  local name=$1 tool=$2 input=$3 grant=$4 before jbefore
  grep -v '^egress=' "$meta" > "$meta.tmp"; mv "$meta.tmp" "$meta"
  [ -z "$grant" ] || printf 'egress=%s\n' "$grant" >> "$meta"
  jq -n --arg t "$tool" --argjson i "$input" '{tool:$t,input:$i}' > "$lab/scenario.json"
  : > "$lab/model.jsonl"
  [ -f "$state/guard-events.jsonl" ] || : > "$state/guard-events.jsonl"
  before=$(wc -l < "$state/guard-events.jsonl" | tr -d ' ')
  jbefore=$( [ -f "$state/jev-guard.jsonl" ] && wc -l < "$state/jev-guard.jsonl" | tr -d ' ' || echo 0)
  (cd "$lab/wt" && env -i PATH="$PATH" HOME="$lab/os-home" TMPDIR="$lab/tmp" CLAUDE_CONFIG_DIR="$lab/claude" \
    ANTHROPIC_API_KEY=synthetic-local-only ANTHROPIC_BASE_URL="$base" \
    HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 CLAUDE_CODE_MAX_RETRIES=0 \
    /Users/charlesabrooker/.local/bin/claude -p "Run the one tool call, then stop." --model claude-sonnet-4-6 \
      --tools "WebFetch,WebSearch,Bash,Read,Agent" --allowedTools "WebFetch WebSearch Bash Read Agent" \
      --setting-sources local --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --no-session-persistence --disable-slash-commands --output-format stream-json --verbose \
      < /dev/null > "$lab/$name.out" 2>&1)
  local rc=$?
  local result
  result=$(jq -c 'select(.type=="user") | .message.content[]? | select(.type=="tool_result") | {is_error, content: (.content|tostring|.[0:400])}' "$lab/$name.out" 2>/dev/null | head -1)
  {
    echo "=== case $name: tool=$tool grant=${grant:-none} claude_exit=$rc"
    echo "tool_result: $result"
    echo "new central guard events:"; tail -n +"$((before+1))" "$state/guard-events.jsonl" | jq -c '{guard,decision,session,source_ok}'
    echo "new jev-guard audit rows:"; [ -f "$state/jev-guard.jsonl" ] && tail -n +"$((jbefore+1))" "$state/jev-guard.jsonl" | jq -c '{hook,tool,decision,branch,destination_class,request_started}'
    echo
  } >> "$out"
}
run_case webfetch-ungranted WebFetch '{"url":"https://example.invalid/t4","prompt":"summarize"}' ''
run_case websearch-ungranted WebSearch '{"query":"t4 synthetic query canary"}' ''
run_case agent-ungranted Agent '{"description":"t4","prompt":"say hi","subagent_type":"general-purpose"}' ''
run_case bash-no-guard Bash '{"command":"echo t4-bash-ran","description":"echo"}' ''
run_case read-local Read "{\"file_path\":\"$lab/wt/local.txt\"}" ''
run_case webfetch-granted WebFetch '{"url":"https://example.invalid/t4","prompt":"summarize"}' '["web"]'
run_case websearch-wrong-grant WebSearch '{"query":"t4 synthetic query canary"}' '["semantic-search"]'
echo "canary leak check (query/url text in central events): $(grep -c 'canary\|example.invalid' "$state/guard-events.jsonl")" >> "$out"
