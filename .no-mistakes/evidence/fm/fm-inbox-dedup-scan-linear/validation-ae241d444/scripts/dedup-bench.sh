#!/usr/bin/env bash
# usage: dedup-bench.sh <tree-root> <N handled> <new|resend-handled|resend-unhandled>
# Drives the real fm_task_inbox_write_idempotent from <tree-root>/bin/fm-task-inbox-lib.sh.
set -u
ROOT=$1; N=$2; MODE=$3
LIB="$ROOT/bin/fm-task-inbox-lib.sh"
STATE=$(mktemp -d "/tmp/fm-val-state.XXXXXX")
mkdir -p "$STATE/t1.inbox/handled"
TARGET=$'TARGET steer corr=RESEND-1\nsecond line of the target'
[ "$MODE" = shared-new ] && TARGET=$'TARGET steer corr=RESEND-1\nnew tail that differs'
[ "$MODE" = shared-resend ] && TARGET=$'TARGET steer corr=RESEND-1\nnew tail that differs'

i=0
while [ "$i" -lt "$N" ]; do
  i=$((i+1))
  if [ "$MODE" = shared-new ] || [ "$MODE" = shared-resend ]; then
    printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\nTARGET steer corr=RESEND-1\nold tail %s\n' "$i" > "$STATE/t1.inbox/handled/$(printf '%04d' "$i").msg"
  else
  printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\nhandled steer %s\nsecond line\n' "$i" > "$STATE/t1.inbox/handled/$(printf '%04d' "$i").msg"
  fi
done
case "$MODE" in
  new|shared-new) ;;
  shared-resend) printf "schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\n%s" "$TARGET" > "$STATE/t1.inbox/handled/0900.msg" ;;
  resend-handled) printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\n%s' "$TARGET" > "$STATE/t1.inbox/handled/0900.msg" ;;
  resend-unhandled) printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\n%s' "$TARGET" > "$STATE/t1.inbox/0900.msg" ;;
  *) echo "bad mode" >&2; exit 2 ;;
esac
before=$(cd "$STATE/t1.inbox" && find . -type f | sort | xargs md5 -q 2>/dev/null | md5 -q)
TIMEFORMAT=%R
T=$( { time FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_task_inbox_write_idempotent "$2" t1 "$3"' _ "$LIB" "$STATE" "$TARGET" > "$STATE/out" 2> "$STATE/err"; echo "$?" > "$STATE/rc"; } 2>&1 )
after=$(cd "$STATE/t1.inbox" && find . -type f | sort | xargs md5 -q 2>/dev/null | md5 -q)
echo "tree=$ROOT N=$N mode=$MODE seconds=$T rc=$(cat "$STATE/rc") printed=$(sed "s|$STATE/||" "$STATE/out") new_records=$( [ "$before" = "$after" ] && echo none-changed || echo changed) unhandled_count=$(ls "$STATE/t1.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ') err=$(head -c 200 "$STATE/err") uptime=[$(uptime | sed 's/.*load/load/')]"
ls -a "$STATE/t1.inbox" | grep -E '^\.(dedup|work|staging|seq)' | tr '\n' ' '; echo
rm -rf "$STATE"
