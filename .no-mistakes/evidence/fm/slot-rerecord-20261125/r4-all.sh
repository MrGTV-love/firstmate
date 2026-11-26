#!/usr/bin/env bash
# r4-all.sh: one shell. Fresh marked lab home; keep-alive server on the lab's private tmux dir; fixture task rrt;
# drive S1..S12 with r4-drive.sh against the real bin/fm-control.sh at the target commit; tear the lab down.
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M89W4CZM5PXRFWG112YQ3V2Q
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M89W4CZM5PXRFWG112YQ3V2Q
cd "$W"
echo "# target commit: $(git rev-parse HEAD)"
eval "$(bin/fm-lab-home.sh env 2>"$EV/.r4-env.err")"
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/.r4-env.err"); rm -f "$EV/.r4-env.err"
export FM_HOME TMUX_TMPDIR
echo "# lab FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR"
tmux() { case "${TMUX_TMPDIR:-}" in /tmp/fml.*) ;; *) echo "GUARD: bad TMUX_TMPDIR" >&2; return 99 ;; esac
  [ -d "$TMUX_TMPDIR" ] || { echo "GUARD: lab tmux dir missing; refusing tmux $*" >&2; return 99; }; command tmux "$@"; }
tmux new-session -d -s keep -c "$FM_HOME" bash
mkdir -p "$FM_HOME/state"
bin/fm-lock.sh
bash "$EV/lab-setup.sh" "$W" >/dev/null 2>&1 && echo "# fixture task rrt built"
for s in S1 S2 S3 S3b S4 S5 S6 S6b S6c S7 S8 S9 S10 S11; do
  [ -d "$TMUX_TMPDIR" ] || { echo "GUARD: lab tmux dir vanished before $s; stopping" >&2; break; }
  bash "$EV/r4-drive.sh" "$s" > "$EV/r4-live-$s.txt" 2>&1; echo "# $s done"
done
# S12: rerecord the good renewal, then relaunch is admitted
bash "$EV/lab-renew.sh" src lib tools/x.sh > "$EV/r4-live-S12.txt" 2>&1
. "$FM_HOME/projects/ids.env"
( cd "$W"; C=bin/fm-control.sh
  echo "\$ fm-control.sh rrt rerecord-slot --check"; $C rrt rerecord-slot --check 2>&1 | grep -v '^fm-gate-refuse:'
  echo "\$ fm-control.sh rrt rerecord-slot --manifest-sha <sha> --note ..."; $C rrt rerecord-slot --manifest-sha "$(shasum -a 256 "$MAN" | awk '{print $1}')" --note "Lab ruling: re-record after the slot renewal" 2>&1 | grep -v '^fm-gate-refuse:'; echo "rc=${PIPESTATUS[0]}"
  grep ^slot_ "$FM_HOME/state/rrt.meta" ) >> "$EV/r4-live-S12.txt"
bash "$EV/r4-drive.sh" S12 >> "$EV/r4-live-S12.txt" 2>&1
grep -E '^(phase|exit_result)=' "$FM_HOME/state/rrt.control-relaunch" >> "$EV/r4-live-S12.txt" 2>&1
cp -R "$FM_HOME/data/rrt/slot-rerecord" "$EV/r4-lab-audit-records" 2>/dev/null
echo "# S12 done"
command tmux kill-server 2>/dev/null; echo "# lab tmux server stopped"
chmod -R u+w "$FM_HOME" 2>/dev/null
echo "# teardown: $TEARDOWN"; eval "$TEARDOWN"; echo "teardown rc=$?"; [ -e "$FM_HOME" ] && echo "lab still present" || echo "lab removed"
