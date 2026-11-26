#!/usr/bin/env bash
# r3-s12-clean.sh: fresh lab; renew; re-record; relaunch on the lab's private tmux server; tear down. One shell.
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M89W4CZM5PXRFWG112YQ3V2Q
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M89W4CZM5PXRFWG112YQ3V2Q
cd "$W"
eval "$(bin/fm-lab-home.sh env 2>"$EV/.s12-env.err")"
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/.s12-env.err"); rm -f "$EV/.s12-env.err"
echo "# lab FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR"
tmux() { case "${TMUX_TMPDIR:-}" in /tmp/fml.*) ;; *) echo "GUARD: bad TMUX_TMPDIR" >&2; return 99 ;; esac
  [ -d "$TMUX_TMPDIR" ] || { echo "GUARD: lab tmux dir missing; refusing tmux $*" >&2; return 99; }; command tmux "$@"; }
# keep the private server alive from the start, so the lab never reads as an ended lab
tmux new-session -d -s keep -c "$FM_HOME" bash
mkdir -p "$FM_HOME/state"
bin/fm-lock.sh
bash "$EV/lab-setup.sh" "$W" >/dev/null 2>&1 && echo "# fixture task rrt built"
. "$FM_HOME/projects/ids.env"
bash "$EV/lab-renew.sh" src lib tools/x.sh
C=bin/fm-control.sh; META=$FM_HOME/state/rrt.meta
run() { echo "\$ fm-control.sh $*"; "$C" "$@" 2>&1 | grep -v '^fm-gate-refuse:'; echo "rc=${PIPESTATUS[0]}"; }
run rrt relaunch --note "resume after slot renewal" | grep -E 'refused|rc='
run rrt rerecord-slot --manifest-sha "$(shasum -a 256 "$MAN" | awk '{print $1}')" --note "Lab ruling: re-record after the slot renewal" | grep -E 'rerecord-slot rrt|rc='
grep ^slot_ "$META"
tmux new-window -d -t keep: -n placeholder bash
tmux new-session -d -s fmlab -n fm-rrt -c "$WT" bash
echo "# panes before relaunch:"; tmux list-panes -a -F '#{socket_path} #{session_name}:#{window_name} cmd=#{pane_current_command}'
run rrt relaunch --note "resume after slot renewal"
sleep 8
echo "# panes after relaunch:"; tmux list-panes -a -F '#{socket_path} #{session_name}:#{window_name} cmd=#{pane_current_command}'
grep -E '^(phase|exit_result)=' "$FM_HOME/state/rrt.control-relaunch"
echo "# capture of fmlab:fm-rrt (last lines):"; tmux capture-pane -p -t fmlab:fm-rrt | grep -v '^\s*$' | tail -8
tmux kill-server; echo "# lab tmux server stopped"
echo "# teardown: $TEARDOWN"; eval "$TEARDOWN"; echo "teardown rc=$?"; [ -e "$FM_HOME" ] && echo "lab still present" || echo "lab removed"
