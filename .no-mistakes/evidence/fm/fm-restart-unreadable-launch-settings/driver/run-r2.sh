#!/usr/bin/env bash
# Round-2 driver: one lab, every claude row, at the current head. Usage: run-r2.sh <lab-dir>
set -u
L=$1; D=$(cd "$(dirname "$0")" && pwd)
. "$L/env.sh"; . "$D/lib.sh"
C="$ROOT/bin/fm-control.sh"
echo "head=$(git -C "$ROOT" rev-parse HEAD)"
echo "##### ROW r1-unpinned (readable env, no FM_SPAWN_GEN)"
new_row r1-unpinned unpinned; settle alive; env_facts; meta_sha; all_consumers; meta_sha
echo "##### ROW r2-unreadable (env -i: no PATH, no HOME)"
new_row r2-unreadable unreadable; settle alive; env_facts; meta_sha; all_consumers; meta_sha
echo "##### ROW r3-elsewhere (pin for another generation)"
new_row r3-elsewhere elsewhere; settle alive; env_facts; probe
consumer "interrupt" env FM_CONTROL_SETTLE_WAIT=.5 "$C" "$ID" interrupt
consumer "exit" env FM_CONTROL_SETTLE_WAIT=.5 FM_CONTROL_EXIT_WAIT=2 "$C" "$ID" exit
consumer "secondmate restart" env FM_SECONDMATE_PERSIST_WAIT=0 "$ROOT/bin/fm-secondmate-restart.sh" "$ID"
consumer "reboot sweep: recover" "$ROOT/bin/fm-reboot-recover.sh" recover
echo "##### ROW r4-contested (matching pin, rival record on same home)"
new_row r4-contested pinned; settle alive; add_rival; probe
consumer "interrupt" env FM_CONTROL_SETTLE_WAIT=.5 "$C" "$ID" interrupt
consumer "secondmate restart" env FM_SECONDMATE_PERSIST_WAIT=0 "$ROOT/bin/fm-secondmate-restart.sh" "$ID"
rm -f "$FM_HOME/state/rival.meta"
echo "##### ROW r4-contested -> r5-managed (rival removed: positive control)"
probe
consumer "reboot sweep: recover (managed)" "$ROOT/bin/fm-reboot-recover.sh" recover
consumer "secondmate restart (pinned control)" env FM_SECONDMATE_PERSIST_WAIT=0 "$ROOT/bin/fm-secondmate-restart.sh" "$ID"
ls -R "$FM_HOME/state" | grep -E 'inbox|msg|pending|^[0-9a-f]{16}$' | tr '\n' ' '; echo
echo "##### ROW r6-legacy (launch_proof empty)"
rm -rf "$FM_HOME/state/labmate.inbox" "$FM_HOME/state/pending-replies"
new_row r6-legacy pinned legacy; settle alive; probe
consumer "interrupt (legacy)" env FM_CONTROL_SETTLE_WAIT=.5 "$C" "$ID" interrupt
echo "##### ROW r7-shell (shell-only pane)"
new_row r7-shell shell; probe
consumer "exit (shell-only)" env FM_CONTROL_SETTLE_WAIT=.5 FM_CONTROL_EXIT_WAIT=2 "$C" "$ID" exit
consumer "reboot sweep: recover (shell-only)" "$ROOT/bin/fm-reboot-recover.sh" recover
