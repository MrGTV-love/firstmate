#!/usr/bin/env bash
# drain-annotation-probe.sh <repo> <lab> <log-bytes> <label>
# One lane status log of <log-bytes> bytes (one distinct plain line repeated), one ordinary `signal:` wake row for it
# (what the watcher queues the first time a log changes), then the real wake drain, timed, with its peak memory.
REPO=$1; LAB=$2; BYTES=$3; LABEL=$4
ST=$LAB/state; rm -rf "$ST"; mkdir -p "$ST"
mkdir -p "$LAB/config"; : > "$LAB/config/supervision-host-off"
F=$ST/lane-$LABEL.status
yes 'working [at=1]: text' | head -c "$BYTES" > "$F"; printf '\n' >> "$F"
FM_STATE_OVERRIDE="$ST" bash -c '. "$1"; fm_wake_append signal "$2" "$3"' _ "$REPO/bin/fm-wake-lib.sh" "lane-$LABEL.status" "signal: $F"
echo "log=$(stat -f %z "$F") bytes (read limit with default cap+reserve = 34603008)"
/usr/bin/time -l env FM_STATE_OVERRIDE="$ST" FM_CONFIG_OVERRIDE="$LAB/config" timeout 120 "$REPO/bin/fm-wake-drain.sh" > "$LAB/drain.out" 2> "$LAB/drain.err"
echo "drain rc=$?"
grep -E 'maximum resident|real' "$LAB/drain.err" | sed 's/^ *//'
echo "--- drain stdout (annotation lines, cut to 160 chars):"; cut -c1-160 "$LAB/drain.out" | sed "s#$LAB#<lab>#g" | head -8
echo "--- drain stderr refusal lines naming the log:"; grep -E 'fm-status: refused' "$LAB/drain.err" | cut -c1-200 | head -3
