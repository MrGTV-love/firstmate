#!/usr/bin/env bash
# Live T2 drive: the installed omp and Claude CLIs execute real tool calls that a
# private loopback model emits. Jev (TypeSafe) is the same loopback fixture; no
# paid provider is contacted. Claude uses the hook settings a real fm-spawn wrote.
# Usage: bash t2-native-drive.sh <worktree-root> <evidence-dir>
set -u
WT_ROOT=$1 EVID=$2
# shellcheck source=/dev/null
. "$WT_ROOT/tests/fixtures.sh"
. "$ROOT/bin/fm-timeout-lib.sh"
. "$ROOT/bin/fm-worker-account-lib.sh"
for credential in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do unset "$credential"; done
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG ANTHROPIC_OAUTH_TOKEN CLAUDECODE
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-t2-live.XXXXXX"); chmod 700 "$LAB"
cleanup() { [ -z "${SRV:-}" ] || kill "$SRV" 2>/dev/null; chmod -R u+w "$LAB" "${LABHOME:-$LAB}" 2>/dev/null; rm -rf -- "${LAB:?}"; [ -z "${LABHOME:-}" ] || rm -rf -- "$LABHOME"; fm_test_cleanup; }
trap cleanup EXIT
mkdir -p "$LAB/os-home" "$LAB/agent" "$LAB/claude" "$LAB/tmp"
: > "$LAB/jev.jsonl"; : > "$LAB/model.jsonl"
python3 -I "$EVID/t2-native-fixture.py" "$LAB" both > "$LAB/server.out" 2>&1 &
SRV=$!
fm_test_wait_until 20 test -s "$LAB/port" || fail "fixture provider did not start"
BASE="http://127.0.0.1:$(cat "$LAB/port")"
export FM_TEST_SEAM=1

# omp worker shape: extension installed exactly as the worker extension does, under the worker overlay.
OMP_HOME="$LAB/omp-home" OMP_WT="$LAB/omp-wt"
cat > "$LAB/extension.ts" <<TS
import { installJevGuard } from "$ROOT/bin/fm-jev-guard.ts";
export default function (pi: any) {
  installJevGuard(pi, { home: "$OMP_HOME", config: "$OMP_HOME/config", state: "$OMP_HOME/state",
    task: "t2", data: "$OMP_HOME/data/t2", worktree: "$OMP_WT", project: "firstmate", policy: "FIRSTMATE_JEV_GUARD_V1" });
}
TS
printf 'setupVersion: 2\nmodelRoles:\n  default: native/gpt-6.1-sol\nretry:\n  maxRetries: 0\n  fallbackChains: {}\n' > "$LAB/agent/config.yml"
printf 'providers:\n  native:\n    baseUrl: %s/v1\n    apiKey: synthetic-local-only\n    api: openai-responses\n    models:\n      - id: gpt-6.1-sol\n        contextWindow: 200000\n        maxTokens: 4096\n' "$BASE" > "$LAB/agent/models.yml"

# Claude worker shape: a real fm-spawn writes the worktree hook settings.
# The spawn home is a marked disposable lab home (bin/fm-lab-home.sh), so the gate
# refusal admits it without any bypass and with no FM_*_OVERRIDE relocation.
CH="$LAB/claude-spawn"; mkdir -p "$CH"
LABHOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LABHOME" > /dev/null || fail "lab home create failed"
LABHOME=$(cd "$LABHOME" && pwd -P)
ln -s "$LABHOME" "$CH/home"
fm_test_spawn_home "$LABHOME" claude
fm_git_worktree "$CH/project" "$CH/wt" wt-t2-live
fm_test_spawn_brief "$LABHOME" t2-live
mkdir -p "$CH/user-home"
out=$(FM_HOME="$LABHOME" HOME="$CH/user-home" CLAUDE_CONFIG_DIR= FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CH/wt" TMUX="fake,1,0" \
  FM_CLAUDE_START_POLL_INTERVAL=0.02 PATH="$(make_spawn_fakebin "$CH/fake" claude):$PATH" \
  "$ROOT/bin/fm-spawn.sh" t2-live "$CH/project" --mode no-mistakes --yolo off 2>&1) || fail "spawn: $out"
printf '%s\n' "$out" | sed "s#$LAB#\$LAB#g; s#$LABHOME#\$LABHOME#g" > "$EVID/claude-spawn.out"
CLAUDE_SETTINGS="$CH/wt/.claude/settings.local.json"
jq '.hooks.PreToolUse' "$CLAUDE_SETTINGS" | sed "s#$LAB#\$LAB#g" > "$EVID/claude-spawned-pretool-hooks.json"
# The guard is active only for the firstmate project itself (report.ts), and the spawned
# fixture project is named "project"; a copy differing only in that one argument lets
# the judged write cases reach a live judge. Bash cases use the spawned file unmodified.
CLAUDE_SETTINGS_FM="$LAB/settings-firstmate.json"
sed "s/'project' 'FIRSTMATE_JEV_GUARD_V1'/'firstmate' 'FIRSTMATE_JEV_GUARD_V1'/" "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS_FM"
cmp -s "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS_FM" && fail "firstmate settings copy did not change the project argument"
diff <(jq -S . "$CLAUDE_SETTINGS") <(jq -S . "$CLAUDE_SETTINGS_FM") | sed "s#$LAB#\$LAB#g; s#$LABHOME#\$LABHOME#g" > "$EVID/claude-settings-firstmate.diff"
jq -n --arg key synthetic-local-only '{hasCompletedOnboarding:true,customApiKeyResponses:{approved:[$key],rejected:[]}}' > "$LAB/claude/.claude.json"
printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$CH/home/.env"

TRANSCRIPT="$EVID/t2-native-transcript.log"; : > "$TRANSCRIPT"
log() { printf '%s\n' "$*" | sed "s#$LABHOME#\$LABHOME#g; s#$LAB#\$LAB#g" | tee -a "$TRANSCRIPT"; }

# drive <host> <case> <tool> <args-json> [unreachable] ; sets JEV_REQS
drive() {
  local host=$1 name=$2 tool=$3 args=$4 unreach=${5:-} status wt home jevurl
  jq -n --arg tool "$tool" --argjson args "$args" '{phase:"normal",tool:$tool,args:$args,benign:(env.T2_BENIGN=="1")}' > "$LAB/scenario.json"
  : > "$LAB/jev.jsonl"; : > "$LAB/model.jsonl"
  curl --max-time 10 -fsS -X POST -d '{}' "$BASE/reset" > /dev/null
  jevurl="$BASE/v1/systemone"; [ -z "$unreach" ] || jevurl="http://127.0.0.1:1/v1/systemone"
  if [ "$host" = omp ]; then
    wt=$OMP_WT home=$OMP_HOME
    (cd "$wt" && FM_JEV_GUARD_BASE_URL="$jevurl" HOME="$LAB/os-home" PI_CODING_AGENT_DIR="$LAB/agent" OMP_SKIP_SETUP=1 \
      fm_run_timed 120 omp -p "Run the one fixture tool call, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
      --no-extensions -e "$LAB/extension.ts" --config "$ROOT/.omp/fm-worker-overlay.yml" --no-skills --no-rules --no-title --no-lsp \
      --tools "$tool" < /dev/null > "$LAB/out" 2>&1)
    status=$?
  else
    wt=$CH/wt home=$CH/home
    local ctool; ctool=$(tr '[:lower:]' '[:upper:]' <<<"${tool:0:1}")${tool:1}
    (cd "$wt" && FM_JEV_GUARD_BASE_URL="$jevurl" HOME="$LAB/os-home" CLAUDE_CONFIG_DIR="$LAB/claude" \
      ANTHROPIC_API_KEY=synthetic-local-only ANTHROPIC_BASE_URL="$BASE" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
      fm_run_timed 120 claude -p "Run the one fixture tool call, then stop." --model claude-sonnet-4-6 --tools "$ctool" \
      --permission-mode bypassPermissions --setting-sources '' --settings "${T2_SETTINGS:-$CLAUDE_SETTINGS}" --strict-mcp-config \
      --mcp-config '{"mcpServers":{}}' --no-session-persistence --disable-slash-commands --output-format stream-json \
      --verbose --include-hook-events < /dev/null > "$LAB/out" 2>&1)
    status=$?
  fi
  JEV_ALL=$(wc -l < "$LAB/jev.jsonl" | tr -d ' ')
  # A pre-call request carries the call's own state (command for shell, path for write);
  # result screening of the tool's output stays in force and is counted separately.
  JEV_REQS=$(jq -s '[.[] | select(.state | has("command") or has("path"))] | length' "$LAB/jev.jsonl")
  JEV_KINDS=$(jq -rs 'map(.state|keys|join("+")) | join(",")' "$LAB/jev.jsonl")
  local called; called=$(jq -r 'select(.input) | .input[]? | select(.type=="function_call_output" or .type=="function_call") | .type' "$LAB/model.jsonl" 2>/dev/null | sort -u | tr '\n' ' ')
  local hooks="n/a"
  [ "$host" = omp ] || hooks=$(jq -r 'select(.type=="system" and (.subtype|tostring|test("hook"))) | "\(.subtype):\(.hook_event // .hook_event_name // "?"):\(.hook_name // .tool_name // "")"' "$LAB/out" 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ';')
  local rows; rows=$(jq -c 'select(.hook=="tool_call") | {tool,decision,branch,error_type,request_started}' "$home/state/jev-guard.jsonl" 2>/dev/null | tr '\n' ' ')
  local result; result=$(jq -r 'select(.type=="user") | .message.content[]? | select(.type=="tool_result") | (if .is_error then "ERROR: " else "OK: " end) + ((.content|tostring)[0:220])' "$LAB/out" 2>/dev/null | head -1)
  [ "$host" = claude ] || result=$(grep -o 'jev-guard[^"]*' "$LAB/out" | head -1)
  log "[$host] $name: exit=$status jev_precall_requests=$JEV_REQS jev_all_requests=$JEV_ALL jev_state_keys=[$JEV_KINDS] pretool_audit_rows=[${rows}] hook_events=[$hooks] tool_result=[$result]"
  cp "$LAB/out" "$EVID/native-$host-$(tr ' ()/,' '_____' <<<"$name").out"
  sed -i '' "s#$LAB#\$LAB#g" "$EVID/native-$host-$(tr ' ()/,' '_____' <<<"$name").out"
  : > "$home/state/jev-guard.jsonl" 2>/dev/null || true
}

q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
cmd() { jq -cn --arg c "$1" '{command:$c}'; }
check() { if eval "$2"; then log "  PASS $1"; else log "  FAIL $1"; FAILS=$((FAILS + 1)); fi; }
FAILS=0

for host in omp claude; do
  if [ "$host" = omp ]; then wt=$OMP_WT home=$OMP_HOME; data=$OMP_HOME/data/t2; state=$OMP_HOME/state
  else wt=$CH/wt home=$CH/home; data=$CH/home/data/t2-live; state=$CH/home/state; fi
  mkdir -p "$wt" "$data" "$state" "$home/config"
  [ "$host" = claude ] || { git init -q "$wt"; printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$home/.env"; }

  printf '# disposable smoke\n' > "$data/smoke.py"
  drive "$host" "T2(a) B68 rm smoke.py" bash "$(cmd "rm $(q "$data/smoke.py")")"
  check "smoke.py removed by the real shell" "[ ! -e '$data/smoke.py' ]"
  check "no TypeSafe request for the bash call" "[ $JEV_REQS -eq 0 ]"

  files=(); for n in host-probe.ts native-probe.ts device-probe.ts config-probe.ts; do printf '// probe\n' > "$data/$n"; files+=("$(q "$data/$n")"); done
  drive "$host" "T2(b) B69 four-file cleanup" bash "$(cmd "rm ${files[*]}")"
  check "four probe files removed" "! ls '$data'/*-probe.ts >/dev/null 2>&1"
  check "no TypeSafe request" "[ $JEV_REQS -eq 0 ]"

  six=(bin/fm-cd-pretool-check.sh bin/fm-cd-command-policy.mjs tests/fm-cd-pretool-check.test.sh docs/cd-guard.md .grok/hooks/fm-primary-cd-check.json .opencode/plugins/fm-primary-cd-check.ts)
  for p in "${six[@]}"; do mkdir -p "$wt/$(dirname "$p")"; printf 'tracked guard\n' > "$wt/$p"; done
  git -C "$wt" add -- "${six[@]}"
  drive "$host" "T2(c) B57 six tracked cd-guard deletions" bash "$(cmd "rm ${six[*]}")"
  check "six tracked files deleted in worktree" "[ \$(git -C '$wt' diff --name-only --diff-filter=D | wc -l) -eq 6 ]"
  check "no TypeSafe request" "[ $JEV_REQS -eq 0 ]"

  printf '#!/bin/sh\nprintf "%%s" "$1" > %s\n' "$(q "$data/teardown-args")" > "$wt/fm-herdr-lab.sh"; chmod 700 "$wt/fm-herdr-lab.sh"
  drive "$host" "T2(d) B22-B50 fm-herdr-lab.sh teardown dispatch" bash "$(cmd "./fm-herdr-lab.sh teardown")"
  check "disposable fm-herdr-lab.sh received teardown" "[ \"\$(cat '$data/teardown-args' 2>/dev/null)\" = teardown ]"
  check "no TypeSafe request" "[ $JEV_REQS -eq 0 ]"

  mkdir -p "$state/t2.inbox/handled"; printf 'steering record\n' > "$state/t2.inbox/002.msg"
  drive "$host" "T2(e) O13 mv inbox with provider unreachable" bash "$(cmd "mv $(q "$state/t2.inbox/002.msg") $(q "$state/t2.inbox/handled/")")" unreachable
  check "002.msg moved to handled/" "[ ! -e '$state/t2.inbox/002.msg' ] && [ -e '$state/t2.inbox/handled/002.msg' ]"

  rm -f "$state/jev-guard.jsonl"; mkdir -p "$state/jev-guard.jsonl"
  big=$(head -c 300000 /dev/zero | tr '\0' x)
  drive "$host" "T2(f) oversize command with audit ledger unavailable" bash "$(cmd "printf '%s' $big > $(q "$data/large.txt")")"
  check "300000-byte command ran" "[ \$(wc -c < '$data/large.txt' | tr -d ' ') -eq 300000 ]"
  check "no TypeSafe request" "[ $JEV_REQS -eq 0 ]"
  rmdir "$state/jev-guard.jsonl"

  # Write coverage kept: deterministic outside-root refusal, then a judged write each way.
  outside="/etc/fm-jev-guard-outside-t2-$host"
  wargs() { if [ "$host" = omp ]; then jq -cn --arg p "$1" --arg c "$2" '{path:$p,content:$c}'; else jq -cn --arg p "$1" --arg c "$2" '{file_path:$p,content:$c}'; fi; }
  drive "$host" "write outside worktree" write "$(wargs "$outside" x)"
  check "outside-root write refused, file absent" "[ ! -e '$outside' ]"
  check "outside-root write sent no TypeSafe request" "[ $JEV_REQS -eq 0 ]"
  T2_SETTINGS=; [ "$host" = omp ] || T2_SETTINGS=$CLAUDE_SETTINGS_FM
  T2_BENIGN=1 drive "$host" "benign write inside worktree" write "$(wargs "$wt/notes.txt" 'plain notes')"
  check "benign write allowed" "[ -e '$wt/notes.txt' ]"
  check "benign write reached the judge" "[ $JEV_REQS -ge 1 ]"
  drive "$host" "judge-refused write inside worktree" write "$(wargs "$wt/risky.txt" 'risky content')"
  check "judge-refused write blocked, file absent" "[ ! -e '$wt/risky.txt' ]"
  check "judge-refused write reached the judge" "[ $JEV_REQS -ge 1 ]"
  # Adversarial: with the guard active and the judge set to refuse, a destructive shell call still runs unjudged.
  printf '# disposable smoke\n' > "$data/smoke2.py"
  drive "$host" "active guard, refusing judge, rm -rf smoke2.py" bash "$(cmd "rm -rf $(q "$data/smoke2.py")")"
  check "destructive shell call ran with an active guard and a refusing judge" "[ ! -e '$data/smoke2.py' ]"
  check "no TypeSafe pre-call request" "[ $JEV_REQS -eq 0 ]"
  T2_SETTINGS=
done
log "omp=$(omp --version 2>&1) claude=$(claude --version 2>&1) host=$(uname -sm) FAILS=$FAILS"
[ "$FAILS" -eq 0 ]
