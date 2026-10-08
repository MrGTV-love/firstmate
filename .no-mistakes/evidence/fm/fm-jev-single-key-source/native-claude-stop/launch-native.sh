#!/usr/bin/env bash
set -u
ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4C9C1P6TN97HD7NAANKCK9T
LAB="$ROOT/.native-stop-lab"
cd "$LAB/case/wt" || exit 1
unset CLAUDECODE FM_TASK_ID ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
export DISABLE_AUTOUPDATER=1
export NODE_USE_SYSTEM_CA=1
export NODE_OPTIONS="${NODE_OPTIONS:-} --use-system-ca"
set -o pipefail
claude --print --verbose --output-format stream-json --include-hook-events --setting-sources '' --settings "$LAB/settings.native.json" --strict-mcp-config --disable-slash-commands --tools Read,Write,Edit,Bash --dangerously-skip-permissions --system-prompt 'You are a coding assistant executing a tiny isolated JavaScript task. Use the available file and command tools. Honor the user task and hook feedback.' 'Write increment.cjs exporting increment via module.exports = { increment }; increment(n) returns n + 1. A real check exists in increment.test.cjs. For this initial response, do not run any tests, checks, validation, builds, or lint; just write the module and report exactly: Implemented increment; complete. If a Stop hook rejects that completion and requests verification, resume and run node --test increment.test.cjs, then report the actual result. Do not touch any other files or use git.' 2>&1 | tee "$LAB/native-output.jsonl"
rc=${PIPESTATUS[0]}
printf '%s\n' "$rc" > "$LAB/native-exit-code"
printf '\nNATIVE_CLAUDE_EXIT_CODE=%s\n' "$rc"
exit "$rc"
