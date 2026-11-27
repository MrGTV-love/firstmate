#!/usr/bin/env bash
# Round-2b: real claude binary (unpinned and pinned) and the sweep's bounded suppression, at head.
set -u
L=$1; D=$(cd "$(dirname "$0")" && pwd)
. "$L/env.sh"; . "$D/lib.sh"
C="$ROOT/bin/fm-control.sh"; RC="$HOME/.local/bin/claude"
echo "head=$(git -C "$ROOT" rev-parse HEAD)"
real_row() { # <row> <pin: none|match>
  new_row "$1" shell
  local pre=''; [ "$2" = match ] && pre="FM_SPAWN_GEN=$GEN" || pre="-u FM_SPAWN_GEN"
  herdr pane send-text "$PANE" "cd $WT && env $pre $RC --resume $UUID" >/dev/null; herdr pane send-keys "$PANE" Enter >/dev/null
  settle alive; sleep 3; env_facts; probe
}
echo "##### ROW real-claude-unpinned"
real_row real-claude-unpinned none
s0=$(screen | shasum | cut -c1-12); m0=$(shasum -a 256 "$META" | cut -c1-16)
consumer "interrupt (real claude, unpinned)" env FM_CONTROL_SETTLE_WAIT=.5 "$C" "$ID" interrupt
consumer "exit (real claude, unpinned)" env FM_CONTROL_SETTLE_WAIT=.5 FM_CONTROL_EXIT_WAIT=2 "$C" "$ID" exit
consumer "relaunch (real claude, unpinned)" "$C" "$ID" relaunch --note "keep the lane"
consumer "secondmate restart (real claude, unpinned)" env FM_SECONDMATE_PERSIST_WAIT=0 "$ROOT/bin/fm-secondmate-restart.sh" "$ID"
echo "##### sweep suppression on the same live unpinned agent: recover --one, recover --one, recover"
rm -f "$FM_HOME/state/.reboot-recovery-cursor" "$FM_HOME/state/$ID.reboot-notice"
for step in one1 one2 full; do
  case $step in full) out=$("$ROOT/bin/fm-reboot-recover.sh" recover 2>/dev/null) ;; *) out=$("$ROOT/bin/fm-reboot-recover.sh" recover --one 2>/dev/null) ;; esac
  printf 'HEAD %-5s lines=%s notice=%s cursor=%s :: %s\n' "$step" "$(printf '%s' "$out" | grep -c REBOOT_RECOVERY)" \
    "$(cut -c1-60 "$FM_HOME/state/$ID.reboot-notice" 2>/dev/null | tr '\n' ' ')" "$(tr '\n' ' ' < "$FM_HOME/state/.reboot-recovery-cursor" 2>/dev/null)" "$(printf '%s' "$out" | head -1 | cut -c1-140)"
done
s1=$(screen | shasum | cut -c1-12); m1=$(shasum -a 256 "$META" | cut -c1-16)
echo "screen_identical_after_all=$([ "$s0" = "$s1" ] && echo yes || echo no) meta_unchanged=$([ "$m0" = "$m1" ] && echo yes || echo no)"
screen | grep -E 'trust|No, exit|Yes, I trust' | head -3
herdr pane send-keys "$PANE" C-c >/dev/null 2>&1; sleep 1; herdr pane send-keys "$PANE" C-c >/dev/null 2>&1; sleep 1
echo "##### ROW real-claude-pinned (managed control)"
real_row real-claude-pinned match
consumer "reboot sweep: recover (real claude, pinned)" "$ROOT/bin/fm-reboot-recover.sh" recover
echo "notice_after_managed=$([ -e "$FM_HOME/state/$ID.reboot-notice" ] && echo present || echo absent)"
herdr pane send-keys "$PANE" C-c >/dev/null 2>&1; sleep 1; herdr pane send-keys "$PANE" C-c >/dev/null 2>&1
