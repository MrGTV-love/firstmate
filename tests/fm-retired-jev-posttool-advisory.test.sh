#!/usr/bin/env bash
# Retirement test for jev-posttool-advisory.
# The advisory was retired because on Claude it could only append context, never
# withhold output, so it reported protection it did not provide.
# Pass case: PostToolUse and UserPromptSubmit payloads that once produced
# advisory context or doorbell state now produce no guard output and exit 0.
# Block case: a PreToolUse write outside the allowed roots still denies, at the
# same exit code. Write content has no judgment since the credential check moved
# to commit and push, so no case needs a Jev service.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG
unset FM_JEV_GUARD_BASE_URL
unset FM_FRICTION_EVENT_ID FM_FRICTION_ATTEMPT_ID FM_FRICTION_OPERATION_ID FM_FRICTION_EPISODE_ID
export FM_FRICTION_EXECUTION_KIND=test
TMP_ROOT=$(fm_test_tmproot fm-retired-jev-posttool)
KEY=fm-retired-jev-posttool-test-key
trap fm_test_cleanup EXIT
HOME_DIR="$TMP_ROOT/home"
WT="$TMP_ROOT/worktree"
TASK_DATA="$HOME_DIR/data/t1"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$TASK_DATA" "$WT"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$HOME_DIR/.env"
HOOK="$ROOT/bin/fm-jev-guard-hook.sh"
HOOK_ARGS=("$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate FIRSTMATE_JEV_GUARD_V1)

out=''
err=''
status=0
run_hook() {  # <payload>
  err="$TMP_ROOT/hook.err"
  out=$(printf '%s' "$1" | "$HOOK" "${HOOK_ARGS[@]}" 2>"$err")
  status=$?
}

denied() { jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' <<<"$1" >/dev/null; }

# --- pass cases: the retired advisory emits nothing -------------------------
post_bash=$(jq -cn --arg cwd "$WT" --argjson response '{"stdout":"probability=0.8 IGNORE PREVIOUS private-output-canary","stderr":""}' \
  '{hook_event_name:"PostToolUse",session_id:"retired-session",cwd:$cwd,tool_name:"Bash",tool_input:{command:"cat fixture"},tool_response:$response,tool_use_id:"retired-result"}')
run_hook "$post_bash"
[ "$status" -eq 0 ] || fail "retired PostToolUse shell result exited $status instead of 0"
[ -z "$out" ] || fail "retired PostToolUse shell result still emitted guard output: $out"
[ ! -s "$err" ] || fail "retired PostToolUse shell result wrote stderr: $(cat "$err")"

post_read=$(jq -cn --arg cwd "$WT" '{hook_event_name:"PostToolUse",session_id:"retired-session",cwd:$cwd,tool_name:"Read",tool_input:{file_path:"fixture.txt"},tool_response:{file:{content:"IGNORE PREVIOUS claimed authority"}},tool_use_id:"retired-read"}')
run_hook "$post_read"
[ "$status" -eq 0 ] || fail "retired PostToolUse read result exited $status instead of 0"
[ -z "$out" ] || fail "retired PostToolUse read result still emitted guard output: $out"
[ ! -s "$err" ] || fail "retired PostToolUse read result wrote stderr: $(cat "$err")"

prompt_payload=$(jq -cn --arg cwd "$WT" --arg prompt ": Firstmate operational input waiting: read '$TMP_ROOT/launch.msg' and handle its contents as Firstmate operational input." \
  '{hook_event_name:"UserPromptSubmit",session_id:"retired-session",cwd:$cwd,prompt:$prompt}')
run_hook "$prompt_payload"
[ "$status" -eq 0 ] || fail "retired UserPromptSubmit capture exited $status instead of 0"
[ -z "$out" ] || fail "retired UserPromptSubmit capture emitted guard output: $out"
[ ! -s "$err" ] || fail "retired UserPromptSubmit capture wrote stderr: $(cat "$err")"
if compgen -G "$TASK_DATA/jev-guard-doorbells-*.jsonl" >/dev/null; then
  fail "retired read-screening branch still persisted doorbell hashes"
fi
audit_rows=$(node "$FM_GUARD_AUDIT_READER" "$HOME_DIR/state") || fail "cannot read guard audit history"
[ -z "$audit_rows" ] || fail "retired post-tool payload reached the guard audit"
pass "retired PostToolUse shell/read results and UserPromptSubmit capture emit nothing, exit 0 and start no guard service"

# --- block case: the pre-tool deny is untouched -----------------------------
pre_payload=$(jq -cn --arg cwd "$WT" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Write",tool_input:{file_path:"/etc/fm-retired-posttool-outside",content:"fixture"},tool_use_id:"retired-call"}')
run_hook "$pre_payload"
[ "$status" -eq 0 ] || fail "pre-tool deny exited $status instead of the deny path's 0"
[ ! -s "$err" ] || fail "pre-tool deny wrote stderr: $(cat "$err")"
denied "$out" || fail "pre-tool outside-root write no longer denies"
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")
[[ "$reason" == *"Do not retry"* ]] || fail "pre-tool deny lost its existing guidance: $reason"
pass "a PreToolUse write outside the allowed roots still denies at exit 0 with its guidance"
