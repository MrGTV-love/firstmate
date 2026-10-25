#!/usr/bin/env bash
# Live T4 smoke: real fm-spawn writes the Claude worker hook settings; the real installed
# Claude CLI loads them and calls tools scripted by a private local provider. No paid model.
set -u
WTROOT=$1 EVD=$2
. "$WTROOT/tests/fixtures.sh"
LAB=$(fm_test_tmproot fm-t4-claude)
dir=$LAB/spawn
fm_test_spawn_home "$dir/home" claude
fm_git_worktree "$dir/project" "$dir/wt" wt-t4-claude >/dev/null 2>&1
fm_test_spawn_brief "$dir/home" t4-claude
out=$(fm_test_run_spawn "$dir/home" "$dir/wt" "$(make_spawn_fakebin "$dir/fake" claude)" t4-claude "$dir/project" --mode no-mistakes --yolo off) || { echo "spawn failed: $out"; exit 1; }
S="$dir/wt/.claude/settings.local.json"
echo "== fm-spawn generated PreToolUse hooks:"; jq -c '.hooks.PreToolUse' "$S" | sed "s#$LAB#<lab>#g"
META="$dir/home/state/t4-claude.meta"; echo "== spawned task meta keys: $(cut -d= -f1 "$META" | tr '\n' ' ')"
mkdir -p "$LAB/claude" "$LAB/os-home" "$LAB/tmp"
jq -n '{hasCompletedOnboarding:true,customApiKeyResponses:{approved:["synthetic-local-only"],rejected:[]}}' > "$LAB/claude/.claude.json"
python3 -I "$EVD/scripts/anthropic-scripted.py" "$LAB" > "$LAB/server.log" 2>&1 &
SP=$!
trap 'kill $SP 2>/dev/null; wait $SP 2>/dev/null; fm_test_cleanup' EXIT
for _ in $(seq 100); do [ -s "$LAB/port" ] && break; sleep 0.1; done
PORT=$(cat "$LAB/port")
MCP=$(jq -cn --arg py "$EVD/scripts/mcp-probe.py" --arg m "$LAB/mcp-ran" '{mcpServers:{probe:{command:"python3",args:["-I",$py,$m]}}}')
EVENTS="$dir/home/state/guard-events.jsonl"
fails=0
run() {  # <name> <tool> <args-json> <expect: deny|allow|nohook> <grant-or-empty> <result-must-contain>
  local name=$1 tool=$2 args=$3 expect=$4 grant=$5 want=$6 before after res evs
  grep -v '^egress=' "$META" > "$META.tmp"; mv "$META.tmp" "$META"
  [ -z "$grant" ] || printf 'egress=%s\n' "$grant" >> "$META"
  jq -n --arg t "$tool" --argjson a "$args" '{tool:$t,args:$a}' > "$LAB/scenario.json"
  : > "$LAB/model.jsonl"
  before=$( [ -f "$EVENTS" ] && wc -l < "$EVENTS" || echo 0)
  (cd "$dir/wt" && env -i PATH="$PATH" HOME="$LAB/os-home" TMPDIR="$LAB/tmp" CLAUDE_CONFIG_DIR="$LAB/claude" \
     ANTHROPIC_API_KEY=synthetic-local-only ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" \
     HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost \
     CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_MAX_RETRIES=0 ENABLE_TOOL_SEARCH=false \
     timeout 120 claude -p "Run the one scripted tool call, then stop." --model claude-sonnet-4-6 \
       --setting-sources local --strict-mcp-config --mcp-config "$MCP" \
       --allowedTools "Bash" "WebFetch" "Monitor" "Read" "mcp__probe__probe" --no-session-persistence \
       --output-format stream-json --verbose > "$LAB/$tool.out" 2>&1)
  local st=$?
  after=$( [ -f "$EVENTS" ] && wc -l < "$EVENTS" || echo 0)
  evs=$( [ "$after" -gt "$before" ] && tail -n $((after-before)) "$EVENTS" | jq -c '[.guard,.decision,.session,.source_ok]' | tr '\n' ' ')
  res=$(tail -n 1 "$LAB/model.jsonl" | jq -r '.messages[]? | .content | if type=="array" then .[] else empty end | select(.type=="tool_result") | (.content|if type=="array" then map(.text // "")|join(" ") else tostring end)' 2>/dev/null | tr '\n' ' ' | cut -c1-360)
  local ok=1
  [ "$st" -eq 0 ] || ok=0
  case "$expect" in
    deny) grep -q '"permissionDecision"\|Missing task egress grant\|Unclassified host tool' <<<"$res" || ok=0; grep -qF -- "$want" <<<"$res" || ok=0 ;;
    allow) grep -q 'jev-tool-coverage' <<<"$evs" || ok=0; ! grep -q 'Missing task egress grant\|Unclassified host tool' <<<"$res" || ok=0; grep -qF -- "$want" <<<"$res" || ok=0 ;;
    nohook) [ -z "$evs" ] || ok=0; grep -qF -- "$want" <<<"$res" || ok=0 ;;
  esac
  [ ! -e "$LAB/mcp-ran" ] || ok=0
  [ "$ok" = 1 ] && echo "PASS $name" || { echo "FAIL $name (claude exit=$st)"; fails=$((fails+1)); tail -c 1500 "$LAB/$tool.out" | sed "s#$LAB#<lab>#g"; }
  echo "    central guard events: ${evs:-<none: no guard process ran>}"
  echo "    tool result seen by model: ${res:-<none>}" | sed "s#$LAB#<lab>#g"
}
echo "== claude $(claude --version)"
run 'WebFetch without a task grant is refused before any request' WebFetch '{"url":"https://example.invalid/t4","prompt":"summarize"}' deny '' 'Missing task egress grant: request Firstmate authorization for egress=["web"]'
run 'WebFetch with egress=["web"] passes the guard (then fails on the dead proxy)' WebFetch '{"url":"https://example.invalid/t4","prompt":"summarize"}' allow '["web"]' ''
run 'WebFetch with only egress=["semantic-search"] is still refused' WebFetch '{"url":"https://example.invalid/t4","prompt":"summarize"}' deny '["semantic-search"]' 'Missing task egress grant'
run 'Unlisted MCP tool is refused by coverage even with every grant' mcp__probe__probe '{"q":"x"}' deny '["semantic-search","web","browser","provider","subagent","remote-storage"]' 'Unclassified host tool "mcp__probe__probe"'
run 'Bash runs with no guard process and no grant' Bash '{"command":"echo live-shell-canary-ok","description":"echo"}' nohook '' 'live-shell-canary-ok'
run 'Read (local paths) reaches coverage and is allowed' Read "{\"file_path\":\"$dir/wt/README.md\"}" allow '' ''
echo "== Monitor input schema: $(head -n 1 "$LAB/model.jsonl" | jq -c '.tools[] | select(.name=="Monitor") | .input_schema.required')"
run 'Monitor runs with no guard process and no grant' Monitor '{"command":"echo live-monitor-canary","description":"echo canary","timeout_ms":30000,"persistent":false}' nohook '' ''
jq -r '.[]' "$LAB/tools-offered.json" | tr '\n' ' ' | sed 's/^/== tools Claude offered the model: /'; echo
echo "RESULT failures=$fails"
