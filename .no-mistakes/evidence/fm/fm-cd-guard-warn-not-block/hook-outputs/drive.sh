#!/usr/bin/env bash
# drive.sh <checkout> <label> <mode|unset> -- runs real checker for each entry form, records stdout/stderr/exit
set -u
CO=$1; LABEL=$2; MODE=$3; CMDSTR=$4; OUT=$5
mkdir -p "$OUT"
payload_claude=$(jq -nc --arg c "$CMDSTR" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')
payload_grok=$(jq -nc --arg c "$CMDSTR" '{hookEventName:"PreToolUse",toolName:"bash",toolInput:{command:$c}}')
payload_cursor=$(jq -nc --arg c "$CMDSTR" '{hook_event_name:"preToolUse",tool_name:"Shell",tool_input:{command:$c},cursor_version:"1.0"}')
run() { form=$1; shift
  if [ "$MODE" = unset ]; then envp=(env -u FM_CD_GUARD_MODE); else envp=(env FM_CD_GUARD_MODE="$MODE"); fi
  ( cd "$CO" && "${envp[@]}" "$@" ) >"$OUT/$LABEL.$form.out" 2>"$OUT/$LABEL.$form.err"; echo $? >"$OUT/$LABEL.$form.rc"
}
run claude   bash -c 'printf %s "$1" | bin/fm-cd-pretool-check.sh --claude' _ "$payload_claude"
run codex    bash -c 'printf %s "$1" | bin/fm-cd-pretool-check.sh' _ "$payload_claude"
run grok     bash -c 'printf %s "$1" | bin/fm-cd-pretool-check.sh' _ "$payload_grok"
run cursor   bash -c 'printf %s "$1" | bin/fm-cd-pretool-check.sh --cursor' _ "$payload_cursor"
run cli      bin/fm-cd-pretool-check.sh --command "$CMDSTR"
