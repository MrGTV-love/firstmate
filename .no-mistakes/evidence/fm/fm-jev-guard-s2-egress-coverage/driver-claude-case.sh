#!/usr/bin/env bash
# claude-case.sh <name> <ToolName> <args-json> <grant-json-or-none> [extra claude args...]
# Drives the REAL installed Claude Code with the REAL fm-spawn-generated hook settings; the model
# is a loopback scripted Anthropic-protocol provider that emits exactly one tool call.
set -u
S=/Users/charlesabrooker/tmp/fm-t4-live.qr0aEH
name=$1 tool=$2 args=$3 grant=$4; shift 4
H=$S/lab/spawn-claude/home; WT=$S/lab/spawn-claude/wt; OUT=$S/out/claude-$name; mkdir -p "$OUT"
meta=$H/state/t4claude.meta
grep -v '^egress=' "$meta" > "$meta.tmp"; mv "$meta.tmp" "$meta"
[ "$grant" = none ] || printf 'egress=%s\n' "$grant" >> "$meta"
mcp=${MCP_CONFIG:-'{"mcpServers":{}}'}
lower=$(printf %s "$tool" | tr 'A-Z' 'a-z')
jq -n --arg tool "$lower" --argjson args "$args" '{phase:"normal",tool:$tool,benign:true,args:$args,path:"unused"}' > "$S/crun/scenario.json"
: > "$S/crun/model.jsonl"
rows_before=$(cat "$H/state/jev-guard.jsonl" 2>/dev/null | wc -l); ev_before=$(cat "$H/state/guard-events.jsonl" 2>/dev/null | wc -l)
curl -fsS -X POST -d '{}' "http://127.0.0.1:$(cat $S/crun/port)/reset" >/dev/null
base="http://127.0.0.1:$(cat $S/crun/port)"
(cd "$WT" && env -u CLAUDECODE -u ANTHROPIC_OAUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY \
  HOME="$S/crun/os-home" CLAUDE_CONFIG_DIR="$S/crun/claude" TMPDIR="$S/crun/tmp" \
  ANTHROPIC_API_KEY=synthetic-local-only ANTHROPIC_BASE_URL="$base" \
  HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
  timeout 120 "$HOME/.local/bin/claude" -p "Use the one tool call, then stop." --model claude-sonnet-4-6 --tools "${TOOLS_OVERRIDE:-$tool}" --allowedTools "$tool" \
  --setting-sources '' --settings "$WT/.claude/settings.local.json" --strict-mcp-config --mcp-config "$mcp" \
  --no-session-persistence --disable-slash-commands --output-format stream-json --verbose "$@" \
  < /dev/null > "$OUT/claude.jsonl" 2>&1); echo "exit=$?" > "$OUT/exit"
{ echo "== case: $name  tool=$tool grant=$grant"; echo "== claude version: $("$HOME/.local/bin/claude" --version)"; echo "== args: $args"; cat "$OUT/exit"
  echo "== tools offered to the scripted model (turn 1):"; head -1 "$S/crun/model.jsonl" | jq -c '[.tools[]?.name]' 2>/dev/null | head -c 400; echo
  echo "== tool_result Claude returned to the model:"
  grep '"tool_result"' "$OUT/claude.jsonl" | jq -r '.message.content[]? | select(.type=="tool_result") | (.content | if type=="string" then . else (map(.text? // "") | join(" ")) end)' 2>/dev/null | head -c 1500; echo
  echo "== new state/jev-guard.jsonl rows:"; tail -n +$((rows_before+1)) "$H/state/jev-guard.jsonl" 2>/dev/null | jq -c '{tool,decision,enforcement,branch,destination_class,confinement_owner}'
  echo "== new state/guard-events.jsonl events:"; tail -n +$((ev_before+1)) "$H/state/guard-events.jsonl" 2>/dev/null | jq -c '{guard,decision,session,source_ok}'
} > "$OUT/transcript.txt"
cat "$OUT/transcript.txt"
