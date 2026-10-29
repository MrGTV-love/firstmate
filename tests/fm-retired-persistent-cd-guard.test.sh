#!/usr/bin/env bash
# Retirement test for persistent-cd-guard.
# The guard was retired because agents will always type cd, so refusing it
# blocked an uncontrollable condition; the harm it named was a cwd-relative
# firstmate write, and the writers now resolve the home themselves.
# Pass case: every registered pre-tool shell hook, on each harness that loads
# a JSON registration, and the command mode the OpenCode, Pi and omp adapters
# call, now let a top-level cd, pushd or popd run with exit 0 and no output.
# Block case: the watcher-arm guard behind the same registrations still denies
# a backgrounded watcher arm in each harness's own deny shape.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset GROK_AGENT GROK_HOOK_EVENT
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-retired-persistent-cd)
trap fm_test_cleanup EXIT

# A primary-shaped checkout: a plain git repository holding AGENTS.md, bin/ and
# the harness registrations, the only place the retired guard ever acted.
PRIMARY="$TMP_ROOT/primary"
git init -q "$PRIMARY"
git -C "$PRIMARY" commit -q --allow-empty -m init
: > "$PRIMARY/AGENTS.md"
cp -R "$ROOT/bin" "$PRIMARY/bin"
mkdir -p "$PRIMARY/.claude" "$PRIMARY/.codex" "$PRIMARY/.grok/hooks" "$PRIMARY/.cursor" "$PRIMARY/projects/foo"
cp "$ROOT/.claude/settings.json" "$PRIMARY/.claude/settings.json"
cp "$ROOT/.codex/hooks.json" "$PRIMARY/.codex/hooks.json"
cp "$ROOT/.grok/hooks/fm-primary-pretool-check.json" "$PRIMARY/.grok/hooks/fm-primary-pretool-check.json"
cp "$ROOT/.cursor/hooks.json" "$PRIMARY/.cursor/hooks.json"

# harness|registration file|jq path to the pre-tool shell hook commands
REGISTRATIONS=(
  "claude|.claude/settings.json|.hooks.PreToolUse[] | select(.matcher == \"Bash\") | .hooks[].command"
  "codex|.codex/hooks.json|.hooks.PreToolUse[] | select(.matcher == \"Bash\") | .hooks[].command"
  "grok|.grok/hooks/fm-primary-pretool-check.json|.hooks.PreToolUse[] | select(.matcher == \"Bash\") | .hooks[].command"
  "cursor|.cursor/hooks.json|.hooks.preToolUse[] | select(.matcher == \"Shell\") | .command"
)

out=''
err=''
status=0
run_registered() {  # <command> <tool name> <shell command>
  local payload
  payload=$(jq -cn --arg tool "$2" --arg cmd "$3" --arg cwd "$PRIMARY" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$tool,tool_input:{command:$cmd},toolInput:{command:$cmd}}')
  err="$TMP_ROOT/hook.err"
  out=$(cd "$PRIMARY" && printf '%s' "$payload" \
    | CLAUDE_PROJECT_DIR="$PRIMARY" CURSOR_PROJECT_DIR="$PRIMARY" GROK_WORKSPACE_ROOT="$PRIMARY" \
      bash -c "$1" 2>"$err")
  status=$?
}

registered_commands() {  # <file> <jq path>
  jq -r "$2" "$PRIMARY/$1" || fail "cannot read pre-tool registrations from $1"
}

denied() {  # <harness>
  case "$1" in
    cursor) jq -e '.permission == "deny"' <<<"$out" >/dev/null 2>&1 ;;
    *) [ "$status" -eq 2 ] && [ -s "$err" ] ;;
  esac
}

CD_COMMANDS=('cd projects/foo' 'cd ..' 'cd' 'pushd projects/foo' 'popd' 'cd projects/foo && tasks-axi add x')
BLOCKED_ARM='bin/fm-watch-arm.sh &'

for row in "${REGISTRATIONS[@]}"; do
  IFS='|' read -r harness file path <<<"$row"
  tool=Bash
  [ "$harness" = cursor ] && tool=Shell
  hooks=$(registered_commands "$file" "$path")
  [ -n "$hooks" ] || fail "$harness registers no pre-tool shell hook in $file"
  while IFS= read -r hook; do
    for cmd in "${CD_COMMANDS[@]}"; do
      run_registered "$hook" "$tool" "$cmd"
      [ "$status" -eq 0 ] || fail "$harness pre-tool hook exited $status for '$cmd': $(cat "$err")"
      [ -z "$out" ] || fail "$harness pre-tool hook emitted output for '$cmd': $out"
      [ ! -s "$err" ] || fail "$harness pre-tool hook wrote stderr for '$cmd': $(cat "$err")"
    done
  done <<<"$hooks"
  pass "$harness pre-tool shell hooks let a top-level cd, pushd or popd run silently"

  arm_denied=0
  while IFS= read -r hook; do
    run_registered "$hook" "$tool" "$BLOCKED_ARM"
    if denied "$harness"; then arm_denied=1; fi
  done <<<"$hooks"
  [ "$arm_denied" -eq 1 ] || fail "$harness pre-tool hooks no longer deny a backgrounded watcher arm"
  pass "$harness pre-tool shell hooks still deny a backgrounded watcher arm"
done

for cmd in "${CD_COMMANDS[@]}"; do
  out=$(cd "$PRIMARY" && bin/fm-arm-pretool-check.sh --command "$cmd" 2>"$TMP_ROOT/cli.err")
  status=$?
  [ "$status" -eq 0 ] || fail "adapter command mode exited $status for '$cmd': $(cat "$TMP_ROOT/cli.err")"
  [ -z "$out" ] && [ ! -s "$TMP_ROOT/cli.err" ] || fail "adapter command mode reported on '$cmd'"
done
pass "the OpenCode, Pi and omp adapter command mode lets a top-level cd, pushd or popd run silently"

(cd "$PRIMARY" && bin/fm-arm-pretool-check.sh --command "$BLOCKED_ARM" >/dev/null 2>&1)
status=$?
[ "$status" -eq 2 ] || fail "adapter command mode no longer denies a backgrounded watcher arm (exit $status)"
pass "the adapter command mode still denies a backgrounded watcher arm at exit 2"
