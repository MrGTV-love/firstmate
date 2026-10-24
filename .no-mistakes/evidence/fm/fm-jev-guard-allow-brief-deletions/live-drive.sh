#!/usr/bin/env bash
# Live drive: real omp / real claude CLI with the firstmate Jev guard, private scripted provider.
set -u
ROOT=$1; backend=$2; OUT=$3
CLAUDE_BIN=/Users/charlesabrooker/.local/bin/claude
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG ANTHROPIC_OAUTH_TOKEN CLAUDECODE ANTHROPIC_AUTH_TOKEN
lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-del-live.XXXXXX"); chmod 700 "$lab"
export FM_DEL_LAB="$lab" FM_DEL_ROOT="$ROOT"
cleanup() { [ -z "${SPID:-}" ] || kill "$SPID" 2>/dev/null; rm -rf -- "$lab"; }
trap cleanup EXIT
mkdir -p "$lab/tmp" "$lab/os-home" "$lab/agent" "$lab/claude" "$lab/home/config" "$lab/home/state" "$lab/home/data" "$lab/worktree"
export FM_TEST_SEAM=1
python3 -I /tmp/fmdel-scripts/fixture.py "$lab" "$backend" > "$lab/server.out" 2>&1 & SPID=$!
for _ in $(seq 50); do [ -s "$lab/port" ] && break; sleep 0.2; done
base="http://127.0.0.1:$(cat "$lab/port")"
export FM_JEV_GUARD_BASE_URL="$base/v1/systemone"
printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$lab/home/.env"
W=$lab/worktree; S=$lab/home/state
git init -q "$W"
CD="bin/fm-cd-pretool-check.sh bin/fm-cd-command-policy.mjs tests/fm-cd-pretool-check.test.sh docs/cd-guard.md .grok/hooks/fm-primary-cd-check.json .opencode/plugins/fm-primary-cd-check.js"
for p in $CD listed.txt unlisted.txt; do mkdir -p "$W/$(dirname "$p")"; echo "tracked: $p" > "$W/$p"; done
git -C "$W" add . && git -C "$W" -c user.name=L -c user.email=l@example.invalid -c commit.gpgsign=false commit -qm fixture
printf 'worktree=%s\nharness=%s\n' "$W" "$backend" > "$S/native.meta"
cat > "$lab/extension.ts" <<TS
import { installJevGuard } from "$ROOT/bin/fm-jev-guard.ts";
export default function (pi: any) {
  const lab = process.env.FM_DEL_LAB!;
  installJevGuard(pi, { home: \`\${lab}/home\`, config: \`\${lab}/home/config\`, state: \`\${lab}/home/state\`,
    task: "native", data: \`\${lab}/home/data\`, worktree: \`\${lab}/worktree\`, project: "firstmate", policy: "FIRSTMATE_JEV_GUARD_V1" });
}
TS
printf 'setupVersion: 2\nmodelRoles:\n  default: native/gpt-6.1-sol\nretry:\n  maxRetries: 0\n  fallbackChains: {}\n' > "$lab/agent/config.yml"
printf 'providers:\n  native:\n    baseUrl: %s/v1\n    apiKey: synthetic-local-only\n    api: openai-responses\n    models:\n      - id: gpt-6.1-sol\n        contextWindow: 200000\n        maxTokens: 4096\n' "$base" > "$lab/agent/models.yml"
hookcmd="$(printf '%q ' "$ROOT/bin/fm-jev-guard-hook.sh" "$lab/home" "$lab/home/config" "$S" native "$W" "$lab/home/data" firstmate FIRSTMATE_JEV_GUARD_V1)"
jq -n --arg c "$hookcmd" '{hooks:{PreToolUse:[{matcher:"^(Bash|Write|Edit)$",hooks:[{type:"command",command:$c,timeout:330}]}]}}' > "$lab/settings.json"
jq -n --arg key synthetic-local-only '{hasCompletedOnboarding:true,customApiKeyResponses:{approved:[$key],rejected:[]}}' > "$lab/claude/.claude.json"
publish() { FM_HOME="$lab/home" bash "$ROOT/bin/fm-jev-deletions.sh" native --replace "$@"; }
run_agent() {  # <args-json>
  jq -n --argjson a "$1" '{args:$a}' > "$lab/scenario.json"
  : > "$lab/jev.jsonl"; : > "$lab/model.jsonl"; curl -fsS -X POST -d '{}' "$base/reset" >/dev/null
  if [ "$backend" = omp ]; then
    (cd "$W" && HOME="$lab/os-home" PI_CODING_AGENT_DIR="$lab/agent" OMP_SKIP_SETUP=1 TMPDIR="$lab/tmp" \
      timeout 120 omp -p "Run the one shell command, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
      --no-extensions -e "$lab/extension.ts" --config "$ROOT/.omp/fm-worker-overlay.yml" --no-skills --no-rules --no-title --no-lsp --tools bash \
      < /dev/null > "$lab/native.out" 2>&1)
  else
    (cd "$W" && HOME="$lab/os-home" CLAUDE_CONFIG_DIR="$lab/claude" TMPDIR="$lab/tmp" ANTHROPIC_API_KEY=synthetic-local-only ANTHROPIC_BASE_URL="$base" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
      timeout 120 "$CLAUDE_BIN" -p "Run the one shell command, then stop." --model claude-sonnet-4-6 --tools Bash --allowedTools Bash \
      --setting-sources '' --settings "$lab/settings.json" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --no-session-persistence --disable-slash-commands --output-format stream-json --verbose < /dev/null > "$lab/native.out" 2>&1)
  fi
  echo "    agent exit=$?"
}
report() {  # <label> <files...>
  local label=$1; shift
  echo "  [$label]"
  echo "    jev pre-tool command judgments: $(jq -s 'map(select(.state.command != null)) | length' "$lab/jev.jsonl")  (post-tool result screens: $(jq -s 'map(select(.state.command == null)) | length' "$lab/jev.jsonl"))"
  for f in "$@"; do if [ -e "$W/$f" ]; then echo "    file $f: PRESENT"; else echo "    file $f: DELETED"; fi; done
  echo "    pre-tool guard row: $(jq -c 'select(.hook != "tool_result" and .hook != "PostToolUse") | {hook,tool,decision,enforcement,branch,request_started}' "$S/jev-guard.jsonl" | tail -n 1)"
  echo "    audit rows: $( [ -f "$S/native.authorized-deletions.jsonl" ] && wc -l < "$S/native.authorized-deletions.jsonl" | tr -d ' ' || echo 0)"
  if [ "$backend" = claude ]; then
    echo "    tool result: $(jq -rc 'select(.type=="user") | .message.content[]? | select(.type=="tool_result") | (.content|tostring)[0:220]' "$lab/native.out" 2>/dev/null | head -1)"
  else
    echo "    tool result seen by model: $(tail -n 1 "$lab/model.jsonl" | jq -rc '[.input[]? | select(.type=="function_call_output") | .output] | last | tostring | .[0:220]')"
  fi
}
restore() { git -C "$W" checkout -q -- . ; git -C "$W" status --short | head; }
echo "== backend: $backend ($( [ "$backend" = omp ] && omp --version || "$CLAUDE_BIN" --version))"
echo "== S0 baseline: no list declared, listed.txt via plain rm -f"
run_agent '{"command":"rm -f listed.txt"}'; report S0-no-list listed.txt; restore
echo "== publish six cd-guard paths + listed.txt via bin/fm-jev-deletions.sh"
publish $CD listed.txt
echo "    meta digest line: $(grep '^jev_deletions_sha256=' "$S/native.meta")"
echo "    list: $(cat "$S/native.authorized-deletions.json")"
echo "== S1 listed: rm -rf -- <six cd-guard paths>"
run_agent "$(jq -n --arg c "rm -rf -- $CD" '{command:$c}')"; report S1-listed-six $CD
echo "    last audit row: $(tail -n 1 "$S/native.authorized-deletions.jsonl")"
echo "    git status after: $(git -C "$W" status --short | tr '\n' ' ')"
restore
echo "== S2 unlisted: rm -f unlisted.txt"
run_agent '{"command":"rm -f unlisted.txt"}'; report S2-unlisted unlisted.txt; restore
echo "== S3 mixed listed+unlisted: rm -f listed.txt unlisted.txt"
run_agent '{"command":"rm -f listed.txt unlisted.txt"}'; report S3-mixed listed.txt unlisted.txt; restore
echo "== S4 /bin/rm spelling of a listed file"
run_agent '{"command":"/bin/rm -f listed.txt"}'; report S4-bin-rm listed.txt; restore
echo "== S5 rm --force spelling of a listed file"
run_agent '{"command":"rm --force listed.txt"}'; report S5-long-flag listed.txt; restore
echo "== S6 tampered list (listed.txt -> unlisted.txt, digest unchanged), rm -f unlisted.txt"
cp "$S/native.authorized-deletions.json" "$lab/list.saved"
sed -i '' 's/"listed.txt"/"unlisted.txt"/' "$S/native.authorized-deletions.json"
run_agent '{"command":"rm -f unlisted.txt"}'; report S6-tampered unlisted.txt
cp "$lab/list.saved" "$S/native.authorized-deletions.json"; restore
if [ "$backend" = omp ]; then
  echo "== S7 omp bash cwd input pointing outside worktree"
  mkdir -p "$lab/other/bin"; echo other > "$lab/other/bin/fm-cd-pretool-check.sh"
  run_agent "$(jq -n --arg d "$lab/other" '{command:"rm -f bin/fm-cd-pretool-check.sh",cwd:$d}')"; report S7-omp-cwd bin/fm-cd-pretool-check.sh
  echo "    other-dir file: $([ -e "$lab/other/bin/fm-cd-pretool-check.sh" ] && echo PRESENT || echo DELETED)"
  restore
fi
echo "== S8 revoke: bin/fm-jev-deletions.sh native --replace (empty), then rm -f listed.txt"
publish
echo "    list after revoke: $(cat "$S/native.authorized-deletions.json")"
run_agent '{"command":"rm -f listed.txt"}'; report S8-revoked listed.txt; restore
cp "$S/jev-guard.jsonl" "$OUT.guard.jsonl"; cp "$S/native.authorized-deletions.jsonl" "$OUT.audit.jsonl" 2>/dev/null
echo "== done"
