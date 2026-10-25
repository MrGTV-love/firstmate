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
cp /Users/charlesabrooker/firstmate/data/fm-herdr-twin-server-root-cause/nm-drive-45.log "$lab/case-b.txt"
for c in a b; do
  rm -rf "$lab/home" "$lab/worktree"; mkdir -p "$lab/home/config" "$lab/home/state" "$lab/home/data" "$lab/worktree"
  printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$lab/home/.env"
  cp "$lab/case-$c.txt" "$lab/worktree/out.txt"
  jq -n '{phase:"normal",tool:"bash",args:{command:"cat out.txt"}}' > "$lab/scenario.json"
  : > "$lab/jev.jsonl"; : > "$lab/model.jsonl"; curl -fsS -X POST -d '{}' "$base/reset" >/dev/null
  (cd "$lab/worktree" && HOME="$lab/os-home" PI_CODING_AGENT_DIR="$lab/agent" OMP_SKIP_SETUP=1 \
    timeout 120 omp -p "Run the one command, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
    --no-extensions -e "$lab/extension.ts" --config "$WT/.omp/fm-worker-overlay.yml" --no-skills --no-rules --no-title --no-lsp --tools bash \
    < /dev/null > "$lab/native.out" 2>&1); st=$?
  python3 -I - "$lab" "$c" "$LABEL" "$st" <<'PY' | tee -a "$EV/bash-verbatim-$LABEL.txt"
import json, pathlib, sys
lab = pathlib.Path(sys.argv[1]); c = sys.argv[2]; label = sys.argv[3]; st = sys.argv[4]
rows = [json.loads(l) for l in (lab/'model.jsonl').read_text().splitlines()]
outs = [i for i in rows[-1].get('input', []) if i.get('type') == 'function_call_output'] if len(rows) >= 2 else []
text = outs[0]['output'] if outs else None
try:
    s = json.loads(text)
    if isinstance(s, list): text = '\n'.join(p.get('text','') for p in s if isinstance(p, dict))
except Exception: pass
src = (lab/f'case-{c}.txt').read_text()
ledger = lab/'home/state/jev-guard.jsonl'
led = [json.loads(l) for l in ledger.read_text().splitlines()] if ledger.exists() else []
jev = (lab/'jev.jsonl').read_text().splitlines()
print(f'=== [{label}] case ({c}) omp exit={st} model_requests={len(rows)}')
print(f'  bytes delivered to next model turn == recorded bytes: {text is not None and text.rstrip(chr(10)) == src.rstrip(chr(10))}')
print(f'  "[jev-guard]" in delivered text: {text is not None and "[jev-guard]" in text}')
print(f'  TypeSafe (Jev) requests for this result: {len(jev)}')
print(f'  jev-guard.jsonl rows: {[ (r.get("hook"), r.get("decision"), r.get("enforcement")) for r in led ]}')
print('  delivered text >>>'); print(text); print('  <<<')
PY
done
