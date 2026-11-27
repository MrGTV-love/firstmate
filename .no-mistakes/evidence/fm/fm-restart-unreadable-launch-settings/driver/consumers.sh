# all_consumers: drive every lifecycle consumer of the verdict on the current row.
all_consumers() {
  local C="$ROOT/bin/fm-control.sh"
  echo "=== row $ROW: pane $SESSION:$PANE"; probe
  consumer "reboot sweep: recover" "$ROOT/bin/fm-reboot-recover.sh" recover
  consumer "reboot sweep: recover --one" "$ROOT/bin/fm-reboot-recover.sh" recover --one
  consumer "relaunch --recover-launch" "$C" "$ID" relaunch --recover-launch
  consumer "interrupt" env FM_CONTROL_SETTLE_WAIT=.5 "$C" "$ID" interrupt
  consumer "exit" env FM_CONTROL_SETTLE_WAIT=.5 FM_CONTROL_EXIT_WAIT=2 "$C" "$ID" exit
  consumer "stay" env FM_CONTROL_SETTLE_WAIT=.5 "$C" "$ID" stay
  consumer "relaunch" "$C" "$ID" relaunch --note "keep the lane"
  consumer "adopt" "$C" "$ID" adopt
  consumer "secondmate restart" env FM_SECONDMATE_PERSIST_WAIT=0 FM_SECONDMATE_PERSIST_POLL=1 "$ROOT/bin/fm-secondmate-restart.sh" "$ID"
  mkdir -p "$WT/state/parent-route"; cp "$META" "$WT/state/parent-route/$ID.meta"
  consumer "host attribution verb" env FM_HOME="$WT" "$ROOT/bin/fm-remote-secondmate-control.sh" attribution "$ID" "$SESSION:$PANE"
  rm -rf "$WT/state/parent-route"
  echo "=== after row $ROW"; probe; screen | tail -2
  ls "$FM_HOME/state" "$WT/state" 2>/dev/null | tr '\n' ' '; echo
}
