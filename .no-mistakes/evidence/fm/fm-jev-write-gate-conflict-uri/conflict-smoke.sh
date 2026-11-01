#!/usr/bin/env bash
# Disposable native omp smoke for the conflict:// refusal remedy.
# Real omp + the real bin/fm-jev-guard.ts extension + the real worker overlay,
# a real git merge conflict, and the repo's scripted local provider (no paid model, no Jev).
# Usage: bash conflict-smoke.sh <repo-root> <evidence-dir>
set -u
ROOT=$1 EV=$2
. "$ROOT/bin/fm-timeout-lib.sh"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG ANTHROPIC_OAUTH_TOKEN CLAUDECODE
lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-conflict-smoke.XXXXXX"); chmod 700 "$lab"
export FM_JEV_NATIVE_LAB="$lab" FM_TEST_SEAM=1
cleanup() { [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null; wait 2>/dev/null; rm -rf -- "$lab"; }
trap cleanup EXIT
mkdir -p "$lab/tmp" "$lab/os-home" "$lab/agent" "$lab/home/config" "$lab/home/state" "$lab/home/data" "$lab/outside"
export TMPDIR="$lab/tmp"
printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$lab/home/.env"
: > "$lab/jev.jsonl"; : > "$lab/model.jsonl"
python3 -I "$ROOT/tests/fm-jev-guard-native-fixture.py" "$lab" omp > "$lab/server.out" 2>&1 &
SPID=$!
for _ in $(seq 100); do [ -s "$lab/port" ] && break; sleep 0.1; done
base="http://127.0.0.1:$(cat "$lab/port")"
export FM_JEV_GUARD_BASE_URL="$base/v1/systemone"
cat > "$lab/extension.ts" <<TS
import { installJevGuard } from "$ROOT/bin/fm-jev-guard.ts";
export default function (pi: any) {
  const lab = process.env.FM_JEV_NATIVE_LAB!;
  installJevGuard(pi, { home: \`\${lab}/home\`, config: \`\${lab}/home/config\`, state: \`\${lab}/home/state\`,
    task: "conflicts", data: \`\${lab}/home/data\`, worktree: \`\${lab}/worktree\`, project: "firstmate",
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
# A real merge conflict in the task's own work copy.
wt="$lab/worktree"; mkdir -p "$wt"
( cd "$wt" && git init -q -b main && git config user.email lab@example.invalid && git config user.name lab \
  && printf 'base\n' > conflicted.txt && git add . && git commit -qm base \
  && git checkout -qb topic && printf 'theirs\n' > conflicted.txt && git commit -qam topic \
  && git checkout -q main && printf 'ours\n' > conflicted.txt && git commit -qam ours \
  && { git merge -q topic >/dev/null 2>&1 || true; } )
cp "$wt/conflicted.txt" "$lab/conflict.orig"
cp "$wt/conflicted.txt" "$lab/outside/conflicted.txt"
conflict=$(cat "$lab/conflict.orig")$'\n'
{ echo "== git status before (real merge conflict) =="; (cd "$wt" && git status --short); echo "== conflicted.txt before =="; cat "$wt/conflicted.txt"; } > "$EV/smoke-00-setup.txt"

run() {  # <name> <tool> <scenario-args-json>
  local name=$1 tool=$2 args=$3
  jq -n --arg tool "$tool" --argjson args "$args" '{phase:"normal",tool:$tool,args:$args}' > "$lab/scenario.json"
  : > "$lab/model.jsonl"; : > "$lab/jev.jsonl"
  curl --max-time 10 -fsS -X POST -d '{}' "$base/reset" > /dev/null
  (cd "$wt" && HOME="$lab/os-home" PI_CODING_AGENT_DIR="$lab/agent" OMP_SKIP_SETUP=1 PI_EDIT_VARIANT=replace \
    fm_run_timed 120 omp -p "Use the one tool call, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
    --no-extensions -e "$lab/extension.ts" --config "$ROOT/.omp/fm-worker-overlay.yml" --no-skills --no-rules --no-title --no-lsp --tools "$tool" \
    < /dev/null > "$lab/native.out" 2>&1)
  local status=$?
  {
    echo "== scenario $name: model issues $tool $(jq -c . <<<"$args") =="
    echo "omp exit: $status ($(omp --version 2>&1))"
    echo "== tool result omp returned to the model =="
    tail -n 1 "$lab/model.jsonl" | jq -r '[.input[]? | select(.type=="function_call_output") | .output] | .[-1] // "none" | if type=="string" then . else tojson end'
    echo "== guard audit record (state/jev-guard ledger) =="
    node "$ROOT/bin/fm-jev-audit-read.mjs" "$lab/home/state" | jq -c 'select(.hook=="tool_call") | {tool,decision,branch,enforcement,refused_path,request_started}' | tail -n 1
    echo "== Jev requests sent: $(wc -l < "$lab/jev.jsonl" | tr -d ' ') =="
    echo "== worktree conflicted.txt after =="; cat "$wt/conflicted.txt"
    echo "== outside copy after =="; cat "$lab/outside/conflicted.txt"
  } > "$EV/smoke-$name.txt" 2>&1
  cat "$EV/smoke-$name.txt"
}

run 01-conflict-uri-write write '{"path":"conflict://1","content":"resolved\n","i":"Resolve conflict 1"}'
run 02-conflict-uri-wildcard write '{"path":"conflict://*","content":"resolved\n","i":"Resolve all conflicts"}'
run 03-outside-real-path-edit edit "$(jq -n --arg p "$lab/outside/conflicted.txt" --arg o "$conflict" '{path:$p,old_string:$o,new_string:"resolved\n",i:"Edit outside copy"}')"
run 04-real-path-edit edit "$(jq -n --arg o "$conflict" '{path:"conflicted.txt",old_string:$o,new_string:"resolved\n",i:"Resolve conflict at real path"}')"
{ echo "== finish the merge with git =="; (cd "$wt" && git add conflicted.txt && git -c core.editor=true commit -q --no-edit && git status --short && git log --oneline -1 && grep -c '<<<<<<<\|>>>>>>>' conflicted.txt || true); } > "$EV/smoke-05-merge-complete.txt" 2>&1
cat "$EV/smoke-05-merge-complete.txt"
