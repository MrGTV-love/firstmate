#!/usr/bin/env bash
# S6: Claude host. Real Claude Code, real PreToolUse hook as fm-spawn registers it, private scripted API.
set -u
WT_ROOT=$1; E=/Users/charlesabrooker/.no-mistakes/evidence/01M6A4ZJ12RM84AK2CCJBAEXT9
lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-conflict-claude.XXXXXX"); lab=$(cd -P "$lab" && pwd -P); chmod 700 "$lab"
mkdir -p "$lab/tmp" "$lab/os-home" "$lab/claude" "$lab/home/config" "$lab/home/state" "$lab/home/data" "$lab/worktree"
python3 -I "$E/drive/provider-claude.py" "$lab" >"$lab/server.out" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null; rm -rf -- "$lab"' EXIT
for _ in $(seq 100); do [ -s "$lab/port" ] && break; python3 -c 'import time;time.sleep(.1)'; done
( cd "$lab/worktree"; git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  printf 'base\n' > conflicted.txt; git add .; git commit -qm base
  git checkout -qb topic; printf 'topic\n' > conflicted.txt; git commit -qam topic
  git checkout -q main; printf 'main\n' > conflicted.txt; git commit -qam main
  git checkout -q topic; git rebase main >/dev/null 2>&1 || true )
cat > "$lab/hook-log.sh" <<'LOG'
#!/usr/bin/env bash
# Passes the payload unchanged to the real hook; records only tool_name and file_path for evidence.
p=$(cat); printf '%s' "$p" | jq -c '{tool_name,file_path:.tool_input.file_path}' >> "$HOOK_LOG"
printf '%s' "$p" | "$@"
LOG
chmod +x "$lab/hook-log.sh"; export HOOK_LOG="$lab/hook-payloads.jsonl"
hook="'$lab/hook-log.sh' '$WT_ROOT/bin/fm-jev-guard-hook.sh' '$lab/home' '$lab/home/config' '$lab/home/state' native '$lab/worktree' '$lab/home/data' firstmate FIRSTMATE_JEV_GUARD_V1"
jq -n --arg c "$hook" '{hooks:{PreToolUse:[{matcher:"^(?!(Bash|Monitor|PowerShell)$).*",hooks:[{type:"command",command:$c,timeout:330}]}]}}' > "$lab/settings.json"
jq -n --arg key synthetic-local-only '{hasCompletedOnboarding:true,customApiKeyResponses:{approved:[$key],rejected:[]}}' > "$lab/claude/.claude.json"
python3 -I -c '
import json,sys
lab=sys.argv[1]; f=lab+"/worktree/conflicted.txt"; c=open(f).read()
print(json.dumps([
 {"tool":"Read","args":{"file_path":f}},
 {"tool":"Write","args":{"file_path":"conflict://1","content":"resolved\n"}},
 {"tool":"Edit","args":{"file_path":"conflict://1","old_string":"<<<<<<<","new_string":"x"}},
 {"tool":"Edit","args":{"file_path":"ssh://remote/file","old_string":"a","new_string":"b"}},
 {"tool":"Edit","args":{"file_path":"/etc/conflicted.txt","old_string":"a","new_string":"b"}},
 {"tool":"Edit","args":{"file_path":f,"old_string":c,"new_string":"resolved\n"}},
]))' "$lab" > "$lab/steps.json"
echo "claude=$(claude --version)"
(cd "$lab/worktree" && env -u ANTHROPIC_OAUTH_TOKEN -u CLAUDECODE -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_ENTRYPOINT HOME="$lab/os-home" TMPDIR="$lab/tmp" CLAUDE_CONFIG_DIR="$lab/claude" \
  ANTHROPIC_API_KEY=synthetic-local-only ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$lab/port")" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
  claude -p "Follow the scripted steps" --model claude-sonnet-4-6 --tools Read,Write,Edit --permission-mode acceptEdits \
  --setting-sources '' --settings "$lab/settings.json" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --no-session-persistence --disable-slash-commands --output-format text </dev/null >"$lab/native.out" 2>&1)
echo "claude-exit=$?"
echo "== what the model saw =="; python3 -I "$E/drive/show.py" "$lab/results.jsonl"
echo "== audit =="; node "$WT_ROOT/bin/fm-jev-audit-read.mjs" "$lab/home/state" 2>&1 | python3 -I -c '
import json,sys
for l in sys.stdin:
    try: r=json.loads(l)
    except Exception: print(l.rstrip()); continue
    if r.get("hook")=="tool_call": print({k:r.get(k) for k in ("tool","decision","enforcement","branch","refused_path")})'
echo "== payloads the real hook received =="; cat "$HOOK_LOG"
echo "== worktree tree =="; (cd "$lab/worktree"; git status --short; find . -path ./.git -prune -o -type f -print)
echo "== direct hook call with raw spelling (real hook entrypoint) =="
for t in Write Edit; do jq -nc --arg t $t --arg cwd "$lab/worktree" '{hook_event_name:"PreToolUse",tool_name:$t,cwd:$cwd,tool_input:{file_path:"conflict://1",content:"x",old_string:"a",new_string:"b"}}' | "$WT_ROOT/bin/fm-jev-guard-hook.sh" "$lab/home" "$lab/home/config" "$lab/home/state" native "$lab/worktree" "$lab/home/data" firstmate FIRSTMATE_JEV_GUARD_V1; echo; done
echo "== after =="; cat "$lab/worktree/conflicted.txt"; tail -2 "$lab/native.out" | cut -c1-300
