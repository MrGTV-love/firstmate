#!/usr/bin/env bash
set -u
ROOT=$1; EV=$2; LAB=$(cat "$EV/.olab"); cd "$ROOT"
export FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/procevent-claims
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE NO_MISTAKES_GATE FM_PROCEVENT_OWNER_CHECK_SECONDS
echo "--- explicit FM_PROCEVENT_OWNER_CHECK_SECONDS=10 on a second source (expect sleep 5):"
export FM_PROCEVENT_OWNER_CHECK_SECONDS=10
bin/fm-procevent.sh register lavish explicit-src -- "$LAB/quiet.sh"
bin/fm-procevent.sh reconcile >/dev/null 2>&1
sleep 3
for g in $(pgrep -f "_owner-watchdog explicit-src"); do pgrep -P "$g" | while read -r c; do ps -o command= -p "$c"; done; done | sort -u | sed 's/^/  /'
bin/fm-procevent.sh retire explicit-src >/dev/null 2>&1
echo "--- invalid value is refused by name (FM_PROCEVENT_OWNER_CHECK_SECONDS=0):"
FM_PROCEVENT_OWNER_CHECK_SECONDS=0 bin/fm-procevent.sh reconcile 2>&1 | head -3
