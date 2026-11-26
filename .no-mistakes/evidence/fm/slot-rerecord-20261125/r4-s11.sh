#!/usr/bin/env bash
# r4-s11.sh: fresh lab; renew so a write is needed; S11 (TERM while the archive is staged); tear down. One shell.
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M89W4CZM5PXRFWG112YQ3V2Q
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M89W4CZM5PXRFWG112YQ3V2Q
cd "$W"
eval "$(bin/fm-lab-home.sh env 2>"$EV/.s11-env.err")"
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/.s11-env.err"); rm -f "$EV/.s11-env.err"
export FM_HOME TMUX_TMPDIR
echo "# lab FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR target=$(git rev-parse HEAD)"
case "$TMUX_TMPDIR" in /tmp/fml.*) command tmux new-session -d -s keep -c "$FM_HOME" bash ;; *) echo GUARD; exit 1 ;; esac
mkdir -p "$FM_HOME/state"; bin/fm-lock.sh
bash "$EV/lab-setup.sh" "$W" >/dev/null 2>&1 && echo "# fixture task rrt built"
bash "$EV/lab-renew.sh" src lib tools/x.sh
echo "# record still names the old base, so a write is needed:"; grep ^slot_base "$FM_HOME/state/rrt.meta"
bash "$EV/r4-drive.sh" S11
echo "# after the TERM, --check still predicts the write (nothing was published):"
bin/fm-control.sh rrt rerecord-slot --check 2>&1 | grep -E '^(write_would|base=|pending_audit)'
[ -d "$TMUX_TMPDIR" ] && command tmux kill-server 2>/dev/null; echo "# lab tmux server stopped"
chmod -R u+w "$FM_HOME" 2>/dev/null
eval "$TEARDOWN"; echo "teardown rc=$?"; [ -e "$FM_HOME" ] && echo "lab still present" || echo "lab removed"
