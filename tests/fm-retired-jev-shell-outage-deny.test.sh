#!/usr/bin/env bash
# Retirement test for jev-shell-outage-deny.
# When the shell judgment could not run (provider unreachable, missing key,
# unwritable audit, never-send match, oversize or malformed command), the shell
# call was refused for review; the assessment at data/fm-jev-guard-e2e/report.md
# records that refusing a worker's own inbox acknowledgement (O13).
# Pass case: those shell calls now pass on omp and on a Claude worker that still
# carries the old Bash hook registration, and write no guard audit row.
# Block case: a write whose judgment cannot run still denies for review.
# No case starts a provider: the unreachable endpoint is a closed loopback port.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG
unset FM_FRICTION_EVENT_ID FM_FRICTION_ATTEMPT_ID FM_FRICTION_OPERATION_ID FM_FRICTION_EPISODE_ID
export FM_FRICTION_EXECUTION_KIND=test
export FM_JEV_GUARD_BASE_URL=http://127.0.0.1:1/v1/systemone
TMP_ROOT=$(fm_test_tmproot fm-retired-jev-shell-outage-deny)
trap 'fm_test_cleanup' EXIT
WT="$TMP_ROOT/worktree"
mkdir -p "$WT"

make_home() {  # <name> [key]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data/t1"
  [ -z "${2:-}" ] || printf 'TYPESAFE_API_KEY=%s\n' "$2" > "$home/.env"
  printf '%s' "$home"
}

out=''
status=0
run_hook() {  # <home> <payload>
  out=$(printf '%s' "$2" | "$ROOT/bin/fm-jev-guard-hook.sh" "$1" "$1/config" "$1/state" t1 "$WT" "$1/data/t1" firstmate FIRSTMATE_JEV_GUARD_V1 2>"$TMP_ROOT/hook.err")
  status=$?
}

shell_passes() {  # <home> <case> <tool-input-json>
  local home=$1 label=$2 input="$TMP_ROOT/input.json" ompout
  printf '%s' "$3" > "$input"
  run_hook "$home" "$(jq -cn --arg cwd "$WT" --slurpfile input "$input" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:$input[0],tool_use_id:"retired-call"}')"
  [ "$status" -eq 0 ] || fail "$label: Claude shell call exited $status"
  [ -z "$out" ] || fail "$label: Claude shell call was still refused: $out"
  [ ! -s "$TMP_ROOT/hook.err" ] || fail "$label: Claude shell call wrote stderr: $(cat "$TMP_ROOT/hook.err")"
  ompout=$(GUARD="$ROOT/bin/fm-jev-guard.ts" GUARD_HOME="$home" WT="$WT" INPUT_FILE="$input" \
    node --experimental-strip-types --no-warnings --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = process.env.GUARD_HOME;
const handlers = {};
installJevGuard({ on(name, handler) { handlers[name] = handler; } }, { home, config: `${home}/config`, state: `${home}/state`,
  task: 't1', worktree: process.env.WT, data: `${home}/data/t1`, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1', host: 'omp' });
assert.equal(await handlers.tool_call({ toolName: 'bash', input: JSON.parse(readFileSync(process.env.INPUT_FILE, 'utf8')) }, { cwd: process.env.WT }), undefined);
console.log('omp-shell-ok');
JS
  ) || fail "$label: omp shell call: $ompout"
  [ "$ompout" = omp-shell-ok ] || fail "$label: unexpected omp output: $ompout"
}

# --- pass cases: every former outage shape now runs the shell call ------------
home=$(make_home unreachable fm-retired-jev-shell-outage-key)
shell_passes "$home" "provider unreachable" '{"command":"mv state/t1.inbox/002.msg state/t1.inbox/handled/"}'
[ ! -e "$home/state/jev-guard.jsonl" ] || fail "an unreachable-provider shell call wrote a guard audit row"

home=$(make_home no-key)
shell_passes "$home" "missing credentials" '{"command":"rm -rf build"}'
shell_passes "$home" "oversize command" "$(jq -cn '{command: ("rm " + ("x" * 262145))}')"
shell_passes "$home" "non-string command" '{"command":42}'
printf 'synthetic-sensitive-token\n' > "$home/config/dispatch-never-send"
shell_passes "$home" "never-send match" '{"command":"rm synthetic-sensitive-token"}'
rm "$home/config/dispatch-never-send"
[ ! -e "$home/state/jev-guard.jsonl" ] || fail "a failed-judgment shell call wrote a guard audit row"

audit=$(make_home audit fm-retired-jev-shell-outage-key)
mkdir "$audit/state/jev-guard.jsonl"
shell_passes "$audit" "audit unavailable" '{"command":"rm -rf build"}'
pass "shell calls pass on omp and an old-matcher Claude worker when their judgment could not have run"

# --- block case: a write whose judgment cannot run still requires review -----
run_hook "$home" "$(jq -cn --arg cwd "$WT" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Write",tool_input:{file_path:"src/retired.txt",content:"plain write"},tool_use_id:"retired-write"}')"
[ "$status" -eq 0 ] || fail "write review exited $status instead of the deny path's 0"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("CredentialUnavailableError"))' <<<"$out" >/dev/null \
  || fail "a write without credentials no longer requires review: $out"
pass "a write whose judgment cannot run still denies for review"
