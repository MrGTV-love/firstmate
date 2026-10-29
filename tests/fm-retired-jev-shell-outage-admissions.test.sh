#!/usr/bin/env bash
# Retirement test for jev-shell-outage-admissions.
# When the shell judgment could not run, only a command the read-only classifier
# proved, or any command in a home carrying the `.fm-lab-home` token with no
# FM_*_OVERRIDE set, was admitted; the assessment at
# data/fm-jev-guard-e2e/report.md found no ledger row ever used either branch.
# Pass case: commands both admissions refused (unproven, forged marker, marker
# split by an override) now pass with no credentials on omp and on a Claude
# worker that still carries the old Bash hook registration, writing no audit row.
# Block case: a write outside the allowed roots in a valid lab home still
# denies; the marker grants no write admission.
# No case starts a provider.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG
unset FM_FRICTION_EVENT_ID FM_FRICTION_ATTEMPT_ID FM_FRICTION_OPERATION_ID FM_FRICTION_EPISODE_ID
export FM_FRICTION_EXECUTION_KIND=test
export FM_JEV_GUARD_BASE_URL=http://127.0.0.1:1/v1/systemone
TMP_ROOT=$(fm_test_tmproot fm-retired-jev-shell-outage-admissions)
trap 'fm_test_cleanup' EXIT
HOME_DIR="$TMP_ROOT/home"
WT="$TMP_ROOT/worktree"
TASK_DATA="$HOME_DIR/data/t1"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$TASK_DATA" "$WT"

out=''
status=0
run_hook() {  # <payload>
  out=$(printf '%s' "$1" | "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate FIRSTMATE_JEV_GUARD_V1 2>"$TMP_ROOT/hook.err")
  status=$?
}

shell_passes() {  # <case> <command>
  local label=$1 command=$2 ompout
  run_hook "$(jq -cn --arg cwd "$WT" --arg c "$command" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:$c},tool_use_id:"retired-call"}')"
  [ "$status" -eq 0 ] || fail "$label: Claude shell call exited $status"
  [ -z "$out" ] || fail "$label: Claude shell call was still refused: $out"
  [ ! -s "$TMP_ROOT/hook.err" ] || fail "$label: Claude shell call wrote stderr: $(cat "$TMP_ROOT/hook.err")"
  ompout=$(GUARD="$ROOT/bin/fm-jev-guard.ts" HOME_DIR="$HOME_DIR" WT="$WT" TASK_DATA="$TASK_DATA" COMMAND="$command" \
    node --experimental-strip-types --no-warnings --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = process.env.HOME_DIR;
const handlers = {};
installJevGuard({ on(name, handler) { handlers[name] = handler; } }, { home, config: `${home}/config`, state: `${home}/state`,
  task: 't1', worktree: process.env.WT, data: process.env.TASK_DATA, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1', host: 'omp' });
assert.equal(await handlers.tool_call({ toolName: 'bash', input: { command: process.env.COMMAND } }, { cwd: process.env.WT }), undefined);
console.log('omp-shell-ok');
JS
  ) || fail "$label: omp shell call: $ompout"
  [ "$ompout" = omp-shell-ok ] || fail "$label: unexpected omp output: $ompout"
}

# --- pass cases: commands neither admission accepted now run ----------------
for command in 'ls; rm -rf build' 'find . -delete' 'git branch -D main' 'ls | xargs rm'; do
  shell_passes "unproven read-only" "$command"
done
printf 'fm-lab-home v1-forged\n' > "$HOME_DIR/.fm-lab-home"
shell_passes "forged lab marker" 'rm -rf build'
printf 'fm-lab-home v1\n' > "$HOME_DIR/.fm-lab-home"
FM_STATE_OVERRIDE="$TMP_ROOT/elsewhere" shell_passes "lab marker split by an override" 'rm -rf build'
[ ! -e "$HOME_DIR/state/jev-guard.jsonl" ] || fail "a shell call wrote a guard audit row"
pass "shell commands both outage admissions refused pass on omp and an old-matcher Claude worker without an audit row"

# --- block case: the lab marker still admits no write outside the roots ------
run_hook "$(jq -cn --arg cwd "$WT" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Write",tool_input:{file_path:"/etc/fm-retired-lab-outside",content:"plain write"},tool_use_id:"retired-write"}')"
[ "$status" -eq 0 ] || fail "lab write refusal exited $status instead of the deny path's 0"
jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null || fail "a lab-home write outside the roots was admitted: $out"
pass "a lab-home write outside the allowed roots still denies"
