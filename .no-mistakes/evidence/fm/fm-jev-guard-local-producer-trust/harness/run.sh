#!/usr/bin/env bash
# Usage: run.sh <worktree-root> <base-guard-root> <evidence-dir>
# Drives real omp (installed) with the real fm-jev-guard extension against private local
# model/judge stand-ins. Producer CLIs are PATH stand-ins that replay recorded bytes, except
# the gh-axi "real" scenario, which execs the real installed gh-axi read-only.
set -u
ROOT=$1; BASE=$2; OUT=$3
REAL_HOME=$HOME
. "$ROOT/bin/fm-timeout-lib.sh"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG ANTHROPIC_OAUTH_TOKEN CLAUDECODE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); chmod 700 "$LAB"
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf -- "$LAB"' EXIT
mkdir -p "$LAB/tmp" "$LAB/os-home" "$LAB/agent" "$LAB/bin"
export FM_LAB="$LAB" FM_TEST_SEAM=1 FM_REAL_HOME="$REAL_HOME"
echo '{"command":"true"}' > "$LAB/scenario.json"
python3 -I "$OUT/harness/fixture.py" "$LAB" > "$LAB/server.out" 2>&1 & SRV=$!
for _ in $(seq 50); do [ -s "$LAB/port" ] && break; sleep 0.2; done
B="http://127.0.0.1:$(cat "$LAB/port")"; export FM_JEV_GUARD_BASE_URL="$B/v1/systemone"
cat > "$LAB/bin/no-mistakes" <<'S'
#!/bin/bash
case "$*" in "axi run"|"axi status") sleep "$(cat "$FM_LAB/stub-sleep")"; cat "$FM_LAB/stub-out"; exit "$(cat "$FM_LAB/stub-exit")";; esac
echo "stand-in refused: $*" >&2; exit 99
S
cat > "$LAB/bin/gh-axi" <<'S'
#!/bin/bash
[ -e "$FM_LAB/gh-real" ] && HOME="$FM_REAL_HOME" GH_NO_UPDATE_NOTIFIER=1 exec /opt/homebrew/bin/gh-axi "$@"
sleep "$(cat "$FM_LAB/stub-sleep")"; cat "$FM_LAB/stub-out"; exit "$(cat "$FM_LAB/stub-exit")"
S
cp "$LAB/bin/gh-axi" "$LAB/bin/unknown-axi"
chmod +x "$LAB/bin/"*
printf 'setupVersion: 2\nmodelRoles:\n  default: native/gpt-6.1-sol\nretry:\n  maxRetries: 0\n  fallbackChains: {}\n' > "$LAB/agent/config.yml"
printf 'providers:\n  native:\n    baseUrl: %s/v1\n    apiKey: synthetic-local-only\n    api: openai-responses\n    models:\n      - id: gpt-6.1-sol\n        contextWindow: 200000\n        maxTokens: 4096\n' "$B" > "$LAB/agent/models.yml"
for g in target base; do
  r=$ROOT; [ $g = base ] && r=$BASE
  cat > "$LAB/ext-$g.ts" <<TS
import { installJevGuard } from "$r/bin/fm-jev-guard.ts";
export default function (pi: any) {
  const lab = process.env.FM_LAB!;
  installJevGuard(pi, { home: \`\${lab}/home\`, config: \`\${lab}/home/config\`, state: \`\${lab}/home/state\`,
    task: "producer-live", data: \`\${lab}/home/data\`, worktree: \`\${lab}/worktree\`, project: "firstmate",
    policy: "FIRSTMATE_JEV_GUARD_V1" });
}
TS
done
# scenario <name> <guard> <command> <stub-out-file|-> <exit> <stub-sleep-seconds> [gh-real]
scenario() {
  local name=$1 guard=$2 cmd=$3 src=$4 code=$5 slp=$6 real=${7:-}
  rm -rf -- "$LAB/home" "$LAB/worktree" "$LAB/gh-real"; mkdir -p "$LAB/home/config" "$LAB/home/state" "$LAB/home/data" "$LAB/worktree"
  printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$LAB/home/.env"
  [ "$src" = - ] || cp "$src" "$LAB/stub-out"; printf %s "$code" > "$LAB/stub-exit"; printf %s "$slp" > "$LAB/stub-sleep"; [ -z "$real" ] || : > "$LAB/gh-real"
  jq -n --arg c "${cmd//@LAB@/$LAB}" '{command:$c}' > "$LAB/scenario.json"
  : > "$LAB/jev.jsonl"; : > "$LAB/model.jsonl"; : > "$LAB/events.jsonl"; curl -fsS -X POST -d '{}' "$B/reset" >/dev/null
  (cd "$LAB/worktree" && HOME="$LAB/os-home" PATH="$LAB/bin:$PATH" TMPDIR="$LAB/tmp" PI_CODING_AGENT_DIR="$LAB/agent" OMP_SKIP_SETUP=1 \
    fm_run_timed 120 omp -p "Run the one shell command, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
    --no-extensions -e "$OUT/harness/event-dump.ts" -e "$LAB/ext-$guard.ts" --config "$ROOT/.omp/fm-worker-overlay.yml" --no-skills --no-rules --no-title --no-lsp --tools bash \
    < /dev/null > "$LAB/omp.out" 2>&1); local st=$?
  mkdir -p "$OUT/scenarios/$name"
  cp "$LAB/omp.out" "$OUT/scenarios/$name/omp-stdout.txt"; cp "$LAB/events.jsonl" "$OUT/scenarios/$name/native-tool-result-event.jsonl"
  [ -f "$LAB/stub-out" ] && [ -z "$real" ] && cp "$LAB/stub-out" "$OUT/scenarios/$name/producer-stdout.txt"
  python3 -I - "$LAB" "$OUT/scenarios/$name" "$name" "$guard" "${cmd//@LAB@/<lab>}" "$st" <<'PY'
import json, pathlib, sys
lab, out, name, guard, cmd, st = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), *sys.argv[3:]
rows = [json.loads(l) for l in (lab/'model.jsonl').read_text().splitlines()]
res = [i for i in rows[-1].get('input', []) if i.get('type') == 'function_call_output'] if len(rows) >= 2 else []
text = res[0]['output'] if res else None
try:
    s = json.loads(text)
    if isinstance(s, list): text = '\n'.join(p.get('text', '') for p in s if isinstance(p, dict))
except Exception: pass
jev = [json.loads(l) for l in (lab/'jev.jsonl').read_text().splitlines()]
screens = [j['state']['content'] for j in jev if 'content' in j['state']]
audit_p = lab/'home/state/jev-guard.jsonl'
audit = [json.loads(l) for l in audit_p.read_text().splitlines()] if audit_p.exists() else []
results = [a for a in audit if a.get('hook') == 'tool_result']
(out/'delivered-to-model.txt').write_text(text if text is not None else '<no tool result reached the model>')
(out/'judge-screened-copy.txt').write_text('\n=====PIECE=====\n'.join(screens))
(out/'audit-rows.jsonl').write_text(''.join(json.dumps(a)+'\n' for a in audit))
prod = (out/'producer-stdout.txt').read_text() if (out/'producer-stdout.txt').exists() else None
r = results[-1] if results else {}
summary = {'scenario': name, 'guard': guard, 'command': cmd, 'omp_exit': int(st),
  'model_turns': len(rows), 'withheld': text is not None and '[jev-guard]' in text,
  'delivered_head': (text or '')[:160], 'delivered_tail': (text or '')[-120:],
  'delivered_starts_with_producer_bytes': (text or '').startswith(prod.rstrip('\n')) if prod else None,
  'native_event': (lambda e: {'isError': e.get('isError'), 'details': e.get('details'), 'content_tail': e['content'][0]['text'][-80:]})(json.loads((out/'native-tool-result-event.jsonl').read_text().splitlines()[0])) if (out/'native-tool-result-event.jsonl').read_text().strip() else None,
  'delivered_equals_native_content': (text == json.loads((out/'native-tool-result-event.jsonl').read_text().splitlines()[0])['content'][0]['text']) if (out/'native-tool-result-event.jsonl').read_text().strip() and text is not None else None,
  'judge_result_screens': len(screens), 'judge_saw_help_line': any('help[' in s for s in screens),
  'audit_tool_result': {k: r.get(k) for k in ('decision', 'branch', 'enforcement', 'error_type', 'producer_fields') if k in r}}
(out/'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
PY
}
. "$OUT/harness/scenarios.sh"
