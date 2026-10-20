#!/usr/bin/env bash
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5BWZMJEVPGDQB5HWVWNFAZT
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5BWZMJEVPGDQB5HWVWNFAZT
L=$(mktemp -d "${TMPDIR:-/tmp}/fm-cdg-codex.XXXXXX"); L=$(cd "$L" && pwd -P)
git init -q "$L"; git -C "$L" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init
: > "$L/AGENTS.md"; mkdir -p "$L/bin" "$L/projects/foo" "$L/.codex"
for f in fm-cd-pretool-check.sh fm-hook-host-lib.sh fm-cd-command-policy.mjs fm-arm-command-policy.mjs; do cp "$WT/bin/$f" "$L/bin/$f"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$L/bin/fm-arm-pretool-check.sh"; chmod +x "$L/bin/"*.sh "$L/bin/"*.mjs
jq '{hooks:{PreToolUse:.hooks.PreToolUse}}' "$WT/.codex/hooks.json" > "$L/.codex/hooks.json"
PROMPT="You are testing a hook. Make exactly two separate shell tool calls, in order. Call 1: cd projects/foo && touch $L/RAN_TOPLEVEL_CD . Call 2: (cd $L/projects/foo && touch $L/RAN_SUBSHELL_CD) . After both, reply with one line per call saying whether it ran, and quote verbatim any hook message text you were shown about call 1 (or write NONE)."
cd "$L" || exit 1
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_CD_GUARD_MODE \
  codex exec --ephemeral --json --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C "$L" "$PROMPT" \
  < /dev/null > "$EV/s12-live-codex-warn.stream.jsonl" 2> "$EV/s12-live-codex-warn.stderr.txt"
echo "codex exit=$?"; echo "sentinels:"; ls "$L" | grep RAN_ || echo "(none)"
rm -rf "$L"
