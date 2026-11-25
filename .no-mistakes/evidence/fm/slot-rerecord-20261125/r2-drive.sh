#!/usr/bin/env bash
# drive.sh <scenario>: run one rerecord-slot scenario in the lab; print a transcript.
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M89W4CZM5PXRFWG112YQ3V2Q
export FM_HOME=/Users/charlesabrooker/tmp/fm-lab.tRIjsw TMUX_TMPDIR=/tmp/fml.pk0VoR
. "$FM_HOME/projects/ids.env"
cd "$W"
C=bin/fm-control.sh
META=$FM_HOME/state/rrt.meta
AD=$FM_HOME/data/rrt/slot-rerecord
NOTE="Lab ruling: re-record after the slot renewal"
g() { git -C "$1" -c user.name=Lab -c user.email=lab@example.invalid "${@:2}"; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
run() { echo "\$ fm-control.sh $*"; "$C" "$@" 2>&1 | grep -v '^fm-gate-refuse:'; echo "rc=${PIPESTATUS[0]}"; }
msha() { sha "$MAN"; }
latest_audit() { ls -t "$AD"/*.record 2>/dev/null | head -1; }
crash() { # leave the newest audit as a SIGKILL between publish and commit leaves it
  local a; a=$(latest_audit); sed -i '' 's/^result=published$/result=pending/' "$a"; echo "# simulated crash: $(basename "$a") result=$(grep ^result= "$a" | cut -d= -f2)"; }
move_head() { printf 'moved %s\n' "$RANDOM" >> "$WT/src/owned.txt"; g "$WT" commit -qam "move HEAD inside scope"; echo "# copy HEAD moved inside scope to $(g "$WT" rev-parse --short HEAD)"; }
agent_up() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  tmux new-session -d -s fmlab -n fm-rrt -c "$WT" -e FM_HOME="$FM_HOME" /Users/charlesabrooker/.local/bin/claude; sleep 4
  echo "# lab tmux panes:"; tmux list-panes -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command} dead=#{pane_dead}'; }
agent_down() { tmux kill-server 2>/dev/null; echo "# lab tmux server stopped"; tmux list-panes -a 2>&1 | head -1; }
case "$1" in
  A) echo "# A: --check after a renewal, no agent, no pending audit"; echo "record sha before: $(sha "$META")"; run rrt rerecord-slot --check; echo "record sha after:  $(sha "$META")"; ls "$AD" 2>&1 ;;
  B) echo "# B: wrong --manifest-sha, no pending audit"; b=$(sha "$META"); run rrt rerecord-slot --manifest-sha 0000000000000000000000000000000000000000000000000000000000000000 --note "$NOTE"; [ "$(sha "$META")" = "$b" ] && echo "record unchanged"; ls "$AD" 2>&1 ;;
  C) echo "# C: correct write publishes"; b=$(sha "$META"); run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; echo "record sha $b -> $(sha "$META")"; grep ^slot_ "$META"; a=$(latest_audit); echo "audit $(basename "$a"): $(grep ^result= "$a")" ;;
  D) echo "# D: pending audit + HEAD moved + live claude agent -> rollback, then refuse"; crash; move_head; agent_up
     a=$(latest_audit); arch=$(grep ^archive= "$a" | cut -d= -f2-)
     run rrt rerecord-slot --check
     run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"
     echo "audit $(basename "$a"): $(grep ^result= "$a")"
     cmp -s "$META" "$arch" && echo "task record is byte-identical to the archived prior record $(basename "$arch")"; grep ^slot_ "$META" ;;
  E) echo "# E: no agent; re-publish, crash, move HEAD, then write with a stale --manifest-sha"; agent_down
     run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"
     crash; move_head; a=$(latest_audit); arch=$(grep ^archive= "$a" | cut -d= -f2-)
     m0=$(msha); h0=$(g "$WT" rev-parse HEAD); j0=$(ls "$FM_HOME/state" | grep -c control-relaunch)
     run rrt rerecord-slot --manifest-sha 1111111111111111111111111111111111111111111111111111111111111111 --note "$NOTE"
     [ "$(msha)" = "$m0" ] && echo "manifest bytes unchanged"; [ "$(g "$WT" rev-parse HEAD)" = "$h0" ] && echo "copy HEAD unchanged"; echo "relaunch journals in state/: before=$j0 after=$(ls "$FM_HOME/state" | grep -c control-relaunch)"
     echo "audit $(basename "$a"): $(grep ^result= "$a")"
     cmp -s "$META" "$arch" && echo "task record is byte-identical to the archived prior record $(basename "$arch")" ;;
  F) echo "# F: re-publish, crash, nothing moved, live claude agent -> recover, exit 0"
     run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; crash; agent_up; a=$(latest_audit); b=$(sha "$META")
     run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"
     echo "audit $(basename "$a"): $(grep ^result= "$a")"; [ "$(sha "$META")" = "$b" ] && echo "record unchanged (left as published)"; agent_down ;;
esac
