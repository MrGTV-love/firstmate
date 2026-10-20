#!/usr/bin/env bash
# Live Claude Code run against a scratch primary-shaped checkout (docs/cd-guard.md method).
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5BWZMJEVPGDQB5HWVWNFAZT
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5BWZMJEVPGDQB5HWVWNFAZT
MODE=$1   # warn|deny
L=$(mktemp -d "${TMPDIR:-/tmp}/fm-cdg-live-$MODE.XXXXXX")
L=$(cd "$L" && pwd -P)
git init -q "$L"; git -C "$L" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init
: > "$L/AGENTS.md"; mkdir -p "$L/bin" "$L/projects/foo" "$L/.claude"
for f in fm-cd-pretool-check.sh fm-hook-host-lib.sh fm-cd-command-policy.mjs fm-arm-command-policy.mjs; do cp "$WT/bin/$f" "$L/bin/$f"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$L/bin/fm-arm-pretool-check.sh"
chmod +x "$L/bin/"*.sh "$L/bin/"*.mjs
cp "$WT/.claude/settings.json" "$L/.claude/settings.json"
jq '{hooks:{PreToolUse:.hooks.PreToolUse}}' "$WT/.claude/settings.json" > "$L/.claude/settings.json"
PROMPT="You are testing a hook. Make exactly two separate Bash tool calls, in order. Call 1: cd projects/foo && touch $L/RAN_TOPLEVEL_CD . Call 2: (cd projects/foo && touch $L/RAN_SUBSHELL_CD) . Do not use any other tool. After both calls, reply with one line per call saying whether it ran, and quote verbatim any hook/system message text you were shown about call 1 (or write NONE)."
cd "$L" || exit 1
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  $( [ "$MODE" = deny ] && echo FM_CD_GUARD_MODE=deny || echo -u FM_CD_GUARD_MODE ) \
  /Users/charlesabrooker/.local/bin/claude -p "$PROMPT" --model haiku --setting-sources project --dangerously-skip-permissions \
  --output-format stream-json --verbose --include-hook-events --no-session-persistence --max-budget-usd 1 --disable-slash-commands \
  > "$EV/s10-live-claude-$MODE.stream.jsonl" 2> "$EV/s10-live-claude-$MODE.stderr.txt"
echo "claude exit=$?"
echo "sentinels:"; ls "$L" | grep RAN_ || echo "(none)"
echo "$L" > /tmp/fm-cdg-driver/lab-$MODE.path
