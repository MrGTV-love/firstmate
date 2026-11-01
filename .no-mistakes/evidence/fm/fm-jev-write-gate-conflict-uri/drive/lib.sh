# Disposable real-omp rig. Source after setting WT_ROOT (the firstmate tree whose guard is under test).
set -u
E=/Users/charlesabrooker/.no-mistakes/evidence/01M6A4ZJ12RM84AK2CCJBAEXT9
rig_up() {  # creates $lab with private provider
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-conflict-drive.XXXXXX"); lab=$(cd -P "$lab" && pwd -P); chmod 700 "$lab"
  mkdir -p "$lab/tmp" "$lab/os-home" "$lab/agent" "$lab/home/config" "$lab/home/state" "$lab/home/data"
  : > "$lab/jev.jsonl"; printf '[]' > "$lab/steps.json"
  python3 -I "$E/drive/provider.py" "$lab" >"$lab/server.out" 2>&1 & srv=$!
  for _ in $(seq 100); do [ -s "$lab/port" ] && break; python3 -c 'import time;time.sleep(.1)'; done
  base="http://127.0.0.1:$(cat "$lab/port")"
  cat > "$lab/agent/config.yml" <<YML
setupVersion: 2
modelRoles:
  default: native/gpt-6.1-sol
retry:
  maxRetries: 0
  fallbackChains: {}
YML
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
  cat > "$lab/guard.ts" <<TS
import { installJevGuard } from "$WT_ROOT/bin/fm-jev-guard.ts";
export default function (pi: any) {
  const lab = process.env.RIG_LAB!;
  installJevGuard(pi, { home: \`\${lab}/home\`, config: \`\${lab}/home/config\`, state: \`\${lab}/home/state\`,
    task: "native", data: \`\${lab}/home/data\`, worktree: \`\${lab}/worktree\`, project: "firstmate",
    host: "omp", policy: "FIRSTMATE_JEV_GUARD_V1" });
}
TS
}
rig_down() { kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; rm -rf -- "${lab:?}"; }
mk_conflict() {  # real repo stopped mid-rebase with 2 unresolved files
  rm -rf -- "$lab/worktree"; mkdir -p "$lab/worktree"; (
    cd "$lab/worktree"; git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf 'base\n' > conflicted.txt; printf 'base2\n' > second.txt; git add .; git commit -qm base
    git checkout -qb topic; printf 'topic\n' > conflicted.txt; printf 'topic2\n' > second.txt; git commit -qam topic
    git checkout -q main; printf 'main\n' > conflicted.txt; printf 'main2\n' > second.txt; git commit -qam main
    git checkout -q topic; git rebase main >/dev/null 2>&1 || true
  )
}
run_omp() {  # <steps-json> <tools> [extra omp args...]; stdout/err in $lab/native.out
  local steps=$1 tools=$2; shift 2
  printf '%s' "$steps" > "$lab/steps.json"; : > "$lab/results.jsonl"
  curl --max-time 10 -fsS -X POST -d '{}' "$base/reset" >/dev/null
  (cd "$lab/worktree" && env -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY -u ANTHROPIC_OAUTH_TOKEN -u CLAUDECODE -u FM_WRITE_CONFINEMENT \
    RIG_LAB="$lab" HOME="$lab/os-home" TMPDIR="$lab/tmp" PI_CODING_AGENT_DIR="$lab/agent" OMP_SKIP_SETUP=1 PI_EDIT_VARIANT=replace \
    FM_JEV_GUARD_BASE_URL="$base/v1/systemone" "${OMP_PREFIX[@]+"${OMP_PREFIX[@]}"}" \
    omp -p "Follow the scripted steps, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
    --config "$WT_ROOT/.omp/fm-worker-overlay.yml" --no-skills --no-rules --no-title --no-lsp --no-extensions "$@" --tools "$tools" \
    </dev/null >"$lab/native.out" 2>&1)
  echo "omp-exit=$?"
}
show() { python3 -I "$E/drive/show.py" "$lab/results.jsonl"; }
audit() { node "$WT_ROOT/bin/fm-jev-audit-read.mjs" "$lab/home/state" 2>&1 | python3 -I -c '
import json,sys
for l in sys.stdin:
    try: r=json.loads(l)
    except Exception: print(l.rstrip()); continue
    if r.get("hook")=="tool_call": print({k:r.get(k) for k in ("tool","decision","enforcement","branch","refused_path","request_started")})
'; }
