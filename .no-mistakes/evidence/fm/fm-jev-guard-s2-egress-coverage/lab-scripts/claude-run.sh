#!/usr/bin/env bash
# usage: run.sh <case> <ClaudeTool> <grant-or-none> <scenario-json>
set -u; L=/Users/charlesabrooker/tmp/fm-t4-lab.PtjvJJ/c; ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5V29PD99JFK5BG4M7JKKY14
case_name=$1 tool=$2 grant=$3 scenario=$4
base="http://127.0.0.1:$(cat $L/port)"
rm -rf "$L/home" "$L/worktree"; mkdir -p "$L/home/config" "$L/home/state" "$L/home/data" "$L/worktree" "$L/out/$case_name"
printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$L/home/.env"
[ "$grant" = none ] || printf 'egress=%s\n' "$grant" > "$L/home/state/native.meta"
printf '%s' "$scenario" > "$L/scenario.json"; : > "$L/model.jsonl"; : > "$L/hook-calls.jsonl"
curl -fsS -X POST -d '{}' "$base/reset" >/dev/null
(cd "$L/worktree" && env -u CLAUDECODE -u ANTHROPIC_OAUTH_TOKEN -u NO_MISTAKES_GATE HOME="$L/os-home" CLAUDE_CONFIG_DIR="$L/claude" TMPDIR="$L/tmp"   FM_TEST_SEAM=1 FM_JEV_GUARD_BASE_URL="$base/v1/systemone" FM_GUARD_EVENT_LOG="$L/out/$case_name/guard-events.jsonl"   ANTHROPIC_API_KEY=synthetic-local-only ANTHROPIC_BASE_URL="$base" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1   timeout 120 claude -p "Use the one tool call, then stop." --model claude-sonnet-4-6 --tools "$tool" --allowedTools "$tool"   --setting-sources '' --settings "$L/settings.json" --strict-mcp-config --mcp-config '{"mcpServers":{}}'   --no-session-persistence --disable-slash-commands --output-format stream-json --verbose < /dev/null > "$L/out/$case_name/claude.out" 2>&1)
echo "claude exit=$?" >> "$L/out/$case_name/claude.out"
cp "$L/model.jsonl" "$L/hook-calls.jsonl" "$L/out/$case_name/"
cp "$L/home/state/jev-guard.jsonl" "$L/out/$case_name/" 2>/dev/null || : > "$L/out/$case_name/jev-guard.jsonl"
ls "$L/worktree" > "$L/out/$case_name/worktree-files.txt"
