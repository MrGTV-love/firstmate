#!/usr/bin/env bash
# Live driver for docs/turnend-guard.md "nine consecutive blocks": runs the REAL bin/fm-turnend-guard.sh --claude
# in a disposable primary-shaped home, nine times, with no failure notice on disk. Each run waits SYNC_WAIT_MS.
# usage: drive-turnend-nine.sh <repo-root> <sync-wait-ms> <outfile>
set -u
ROOT=$1 WAIT=$2 OUTFILE=$3
D=$(mktemp -d "${TMPDIR:-/tmp}/turnend9.XXXXXX")
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/state" "$D/bin" "$D/docs"
git init -q "$D"; git -C "$D" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
: > "$D/AGENTS.md"
for f in fm-turnend-guard.sh fm-turnend-guard-grok.sh fm-operational-input.sh fm-supervision-instructions.sh fm-harness.sh fm-primary-scope-lib.sh \
  fm-supervision-lib.sh fm-supervision-engine-lib.sh fm-wake-lib.sh fm-path-lib.sh fm-secondmate-parent-lib.sh fm-hook-host-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh; do
  cp "$ROOT/bin/$f" "$D/bin/$f"
done
cp -R "$ROOT/docs/supervision-protocols" "$D/docs/supervision-protocols"
chmod +x "$D"/bin/*.sh
: > "$D/state/task1.meta"
: > "$OUTFILE"
total_start=$(date +%s)
for i in 1 2 3 4 5 6 7 8 9; do
  s=$(date +%s)
  out=$(printf '{"stop_hook_active":false,"session_id":"sess-nine"}' | CLAUDECODE=1 FM_HOME="$D" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS="$WAIT" bash "$D/bin/fm-turnend-guard.sh" --claude 2>&1); st=$?
  jq -cn --argjson invocation "$i" --argjson exit_code "$st" --argjson wall_s "$(( $(date +%s) - s ))" \
    --argjson failopen "$(printf '%s' "$out" | grep -q 'systemMessage\|GENUINELY DOWN' && echo true || echo false)" \
    --argjson blocked_banner "$(printf '%s' "$out" | grep -q 'TURN WOULD END BLIND' && echo true || echo false)" \
    '{invocation:$invocation,exit_code:$exit_code,wall_s:$wall_s,fail_open_text_present:$failopen,blind_turn_banner:$blocked_banner}' | tee -a "$OUTFILE"
done
echo "failure_notice_on_disk=$([ -e "$D/state/.claude-autoarm-failure-notified" ] && echo yes || echo no) total_wall_s=$(( $(date +%s) - total_start )) sync_wait_ms=$WAIT" | tee -a "$OUTFILE"
