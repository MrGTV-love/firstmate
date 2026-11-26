#!/usr/bin/env bash
# r4-rest.sh: resume r4-all.sh from S8 in the same lab (r4-all.sh hit the tool's 10-minute limit during S8, before S8 wrote anything).
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M89W4CZM5PXRFWG112YQ3V2Q
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M89W4CZM5PXRFWG112YQ3V2Q
export FM_HOME=/Users/charlesabrooker/tmp/fm-lab.IbTtp1 TMUX_TMPDIR=/tmp/fml.5bAl8h
TEARDOWN="$W/bin/fm-lab-home.sh teardown $FM_HOME && rm -rf $FM_HOME"
cd "$W"
for s in S8 S9 S10 S11; do
  [ -d "$TMUX_TMPDIR" ] || { echo "GUARD: lab tmux dir vanished before $s; stopping" >&2; break; }
  bash "$EV/r4-drive.sh" "$s" > "$EV/r4-live-$s.txt" 2>&1; echo "# $s done"
done
bash "$EV/lab-renew.sh" src lib tools/x.sh > "$EV/r4-live-S12.txt" 2>&1
. "$FM_HOME/projects/ids.env"
( C=bin/fm-control.sh
  echo "\$ fm-control.sh rrt rerecord-slot --manifest-sha <sha> --note ..."; $C rrt rerecord-slot --manifest-sha "$(shasum -a 256 "$MAN" | awk '{print $1}')" --note "Lab ruling: re-record after the slot renewal" 2>&1 | grep -v '^fm-gate-refuse:'; echo "rc=${PIPESTATUS[0]}"
  grep ^slot_ "$FM_HOME/state/rrt.meta" ) >> "$EV/r4-live-S12.txt"
[ -d "$TMUX_TMPDIR" ] && bash "$EV/r4-drive.sh" S12 >> "$EV/r4-live-S12.txt" 2>&1
grep -E '^(phase|exit_result)=' "$FM_HOME/state/rrt.control-relaunch" >> "$EV/r4-live-S12.txt" 2>&1
cp -R "$FM_HOME/data/rrt/slot-rerecord" "$EV/r4-lab-audit-records" 2>/dev/null
echo "# S12 done"
[ -d "$TMUX_TMPDIR" ] && command tmux kill-server 2>/dev/null; echo "# lab tmux server stopped"
chmod -R u+w "$FM_HOME" 2>/dev/null
echo "# teardown: $TEARDOWN"; eval "$TEARDOWN"; echo "teardown rc=$?"; [ -e "$FM_HOME" ] && echo "lab still present" || echo "lab removed"
