EV=/Users/charlesabrooker/.no-mistakes/evidence/01M61KT5HQDB1J8ZJNXWRNSM3X; T=$EV/live-lab-transcript.txt; R=/tmp/fmlab-run.sh
H=$(cat /tmp/fmlab-home.txt)
log(){ printf '\n$ %s\n' "$*" >> "$T"; }
run(){ log "$*"; "$R" "$@" >> "$T" 2>&1; local rc=$?; echo "exit=$rc" >> "$T"; return $rc; }
wake(){ log "fm_wake_append check $1 \"$2\""; "$R" bash -c '. bin/fm-wake-lib.sh; fm_wake_append check "$1" "$2"' _ "$1" "$2" >> "$T" 2>&1; }
drain(){ log "fm-wake-drain.sh"; "$R" bash bin/fm-wake-drain.sh > /tmp/fmlab-d.out 2>/tmp/fmlab-d.err; echo "exit=$?" >> "$T"; cat /tmp/fmlab-d.out >> "$T"; grep -v '^Shell cwd' /tmp/fmlab-d.err >> "$T"; grep -o -- '--ack-through [0-9]* --recovery-generation [A-Za-z0-9._-]*' /tmp/fmlab-d.err > /tmp/fmlab-bnd; }
ack(){ local s=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())'); log "fm-wake-drain.sh $(cat /tmp/fmlab-bnd)"; "$R" bash bin/fm-wake-drain.sh $(cat /tmp/fmlab-bnd) >> "$T" 2>&1; local rc=$?; echo "exit=$rc" >> "$T"; return $rc; }
id_of(){ jq -r --arg s "$1" '.rows[]|select(.subject==$s)|.id' "$H/state/open-loops.json"; }
