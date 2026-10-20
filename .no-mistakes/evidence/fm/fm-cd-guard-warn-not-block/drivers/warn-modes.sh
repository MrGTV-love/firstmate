#!/usr/bin/env bash
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5BWZMJEVPGDQB5HWVWNFAZT
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-cdg-warn.XXXXXX")
P=$W/primary
git init -q "$P"; git -C "$P" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init
: > "$P/AGENTS.md"; mkdir -p "$P/bin" "$P/projects/foo"
for f in fm-cd-pretool-check.sh fm-hook-host-lib.sh fm-cd-command-policy.mjs fm-arm-command-policy.mjs; do cp "$WT/bin/$f" "$P/bin/$f"; done
chmod +x "$P/bin/"*.sh "$P/bin/"*.mjs
C=$P/bin/fm-cd-pretool-check.sh
show() { echo "--- $1"; echo "rc=$2"; echo "stdout: $(cat "$W/out")"; echo "stderr: $(cat "$W/err")"; }
claude_payload() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
echo "=== S2 default mode, Claude form, bare 'cd projects/foo' ==="
claude_payload 'cd projects/foo' | env -u FM_CD_GUARD_MODE "$C" --claude >"$W/out" 2>"$W/err"; rc=$?; show "claude default" $rc
jq -e '(.hookSpecificOutput|has("permissionDecision")|not) and (.systemMessage|contains("git -C")) and (.hookSpecificOutput.additionalContext==.systemMessage)' "$W/out" >/dev/null && echo "CHECK ok: no permissionDecision, git -C hint present, additionalContext==systemMessage"
[ ! -s "$W/err" ] && echo "CHECK ok: stderr empty"
echo "=== S3 default mode, Cursor form ==="
jq -cn '{tool_name:"Shell",tool_input:{command:"cd projects/foo"},cursor_version:"2026.08.11-e8db854"}' | env -u FM_CD_GUARD_MODE "$C" --cursor >"$W/out" 2>"$W/err"; rc=$?; show "cursor default" $rc
echo "=== S3b default mode, Codex/Grok/CLI forms ==="
claude_payload 'cd projects/foo' | env -u FM_CD_GUARD_MODE "$C" >"$W/out" 2>"$W/err"; rc=$?; show "codex default" $rc
jq -cn '{toolName:"run_terminal_command",toolInput:{command:"cd projects/foo"}}' | env -u FM_CD_GUARD_MODE "$C" >"$W/out" 2>"$W/err"; rc=$?; show "grok default" $rc
env -u FM_CD_GUARD_MODE "$C" --command 'cd projects/foo' >"$W/out" 2>"$W/err"; rc=$?; show "opencode/pi default" $rc
echo "=== S7 mode variable: unset / warn / deny / DENY / block / empty ==="
for m in __unset__ warn deny DENY block ""; do
  if [ "$m" = __unset__ ]; then claude_payload 'cd projects/foo' | env -u FM_CD_GUARD_MODE "$C" --claude >"$W/out" 2>"$W/err"; rc=$?
  else claude_payload 'cd projects/foo' | env "FM_CD_GUARD_MODE=$m" "$C" --claude >"$W/out" 2>"$W/err"; rc=$?; fi
  printf 'mode=[%s] rc=%s stdout_bytes=%s stderr_bytes=%s kind=%s\n' "$m" $rc "$(wc -c <"$W/out"|tr -d ' ')" "$(wc -c <"$W/err"|tr -d ' ')" "$(cat "$W/out" "$W/err" | jq -r 'if .hookSpecificOutput.permissionDecision then "DENY" elif .hookSpecificOutput.additionalContext then "WARN" else "?" end')"
done
echo "=== S4 exemptions stay silent (default + deny, claude + cursor) ==="
for cmd in 'cat foo | cd bar' 'cd projects/foo | cat' '(cd projects/foo && pwd)' 'env cd projects/foo' 'cd "projects/foo' 'git -C projects/foo status'; do
  for m in warn deny; do
    claude_payload "$cmd" | env "FM_CD_GUARD_MODE=$m" "$C" --claude >"$W/out" 2>"$W/err"; rc1=$?; b1=$(cat "$W/out" "$W/err" | wc -c | tr -d ' ')
    jq -cn --arg c "$cmd" '{tool_name:"Shell",tool_input:{command:$c}}' | env "FM_CD_GUARD_MODE=$m" "$C" --cursor >"$W/out" 2>"$W/err"; rc2=$?; b2=$(cat "$W/out" "$W/err" | wc -c | tr -d ' ')
    printf '%-28s mode=%-4s claude rc=%s bytes=%s | cursor rc=%s bytes=%s\n' "[$cmd]" $m $rc1 $b1 $rc2 $b2
  done
done
echo "=== S5 empty / malformed stdin ==="
for m in warn deny; do for r in --claude --cursor; do for inp in '' 'not json at all' '{"tool_input":'; do
  printf '%s' "$inp" | env "FM_CD_GUARD_MODE=$m" "$C" $r >"$W/out" 2>"$W/err"; rc=$?
  printf 'mode=%s %s input=[%s] rc=%s bytes=%s\n' $m $r "$inp" $rc "$(cat "$W/out" "$W/err" | wc -c | tr -d ' ')"
done; done; done
echo "=== S6 scope: linked worktree + non-firstmate repo inert in both modes ==="
git -C "$P" worktree add -q "$W/wt" -b wtb 2>/dev/null
: > "$W/wt/AGENTS.md"; mkdir -p "$W/wt/bin"; cp "$P/bin/"* "$W/wt/bin/"
N=$W/notfm; git init -q "$N"; git -C "$N" -c user.email=a@b -c user.name=t commit -q --allow-empty -m i; mkdir -p "$N/bin"; cp "$P/bin/"* "$N/bin/"
for d in wt notfm; do for m in warn deny; do
  claude_payload 'cd projects/foo' | env "FM_CD_GUARD_MODE=$m" "$W/$d/bin/fm-cd-pretool-check.sh" --claude >"$W/out" 2>"$W/err"; rc=$?
  printf '%-6s mode=%s rc=%s bytes=%s\n' $d $m $rc "$(cat "$W/out" "$W/err" | wc -c | tr -d ' ')"
done; done
git -C "$P" worktree remove --force "$W/wt" 2>/dev/null
rm -rf "$W"
