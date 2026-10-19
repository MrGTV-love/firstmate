#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/lab.sh"
lab_start || exit 1
trap lab_stop EXIT
new_home duplicate
mirror >/dev/null; T=$(thread_ts dup-a); echo "T=$T"
reply "$T" "1" "user=$OWNER"
echo "poll1: [$(poll)]"; echo "bots after poll1: $(bot_count "$T")"
thread_texts "$T"
echo "poll2: [$(poll)]"; echo "poll3: [$(poll)]"; echo "bots after poll3: $(bot_count "$T")"
echo "open dup-a: $(is_open dup-a)"
"$REPO/bin/fm-tasks-axi.sh" show dup-a --full | head -30
echo ---- terminal close then record format
new_home typed-reply
mirror >/dev/null; T=$(thread_ts typed-call)
printf 'closed in terminal\n' > "$FM_HOME/decision.txt"; "$CAPTAIN" answer typed-call --decision-file "$FM_HOME/decision.txt"
"$REPO/bin/fm-tasks-axi.sh" show typed-call --full | head -30
