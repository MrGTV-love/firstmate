#!/usr/bin/env bash
# usage: scale.sh <tree-root> <N handled records> <mode: new|resend|same-unhandled>
set -u
ROOT=$1; N=$2; MODE=$3
STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-scale-state.XXXXXX")
mkdir -p "$STATE/t1.inbox/handled"
i=0
while [ "$i" -lt "$N" ]; do
  i=$((i+1))
  printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\nhandled steer %s corr=old-%s' "$i" "$i" > "$STATE/t1.inbox/handled/$(printf '%04d' "$i").msg"
done
TEXT="fresh steer corr=NEW-1"
[ "$MODE" = resend ] && TEXT="handled steer 900 corr=old-900"
if [ "$MODE" = same-unhandled ]; then
  TEXT="fresh steer corr=NEW-2"
  printf 'schema=fm-task-inbox.v1\nat=x\n--\n%s' "$TEXT" > "$STATE/t1.inbox/$(printf '%04d' $((N+1))).msg"
fi
TIMEFORMAT=%R
T=$( { time FM_STATE_OVERRIDE="$STATE" bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write_idempotent "$2" t1 "$3"' _ "$ROOT" "$STATE" "$TEXT" > "$STATE/out.txt" 2> "$STATE/err.txt"; echo "rc=$?" > "$STATE/rc.txt"; } 2>&1 )
echo "tree=$(basename "$ROOT") N=$N mode=$MODE seconds=$T rc=$(cut -d= -f2 "$STATE/rc.txt") printed=$(sed "s|$STATE|STATE|" "$STATE/out.txt") handled_after=$(ls "$STATE/t1.inbox/handled" | wc -l | tr -d ' ') unhandled_after=$(ls "$STATE/t1.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ') temps=$(ls -a "$STATE/t1.inbox" | grep -c '\.dedup\|\.work')"
[ -s "$STATE/err.txt" ] && echo "stderr: $(head -3 "$STATE/err.txt")"
rm -rf "$STATE"
