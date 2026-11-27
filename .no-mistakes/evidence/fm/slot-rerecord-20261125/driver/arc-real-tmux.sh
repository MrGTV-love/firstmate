#!/usr/bin/env bash
# The stopped proof of bin/fm-control.sh <id> rerecord-slot against a REAL tmux server on a private socket directory
# (TMUX_TMPDIR), never the default server. Fixture F of tests/fm-control-rerecord-slot.test.sh, with the suite's tmux
# stub removed from the fixture's fakebin so the verb's tmux calls reach /opt/homebrew/bin/tmux.
. "$(dirname "${BASH_SOURCE[0]}")/rr-lib.sh"
say() { printf '\n===== %s =====\n' "$*"; }

rr_make_f realtmux
rm -f "$RR_DIR/fakebin/tmux" "$RR_DIR/fakebin/tmux-runtime"
LAB_TMUX=$(mktemp -d /tmp/fmlab-tmux.XXXXXX)
export TMUX_TMPDIR=$LAB_TMUX
unset TMUX TMUX_PANE
lab_cleanup() { tmux kill-server 2>/dev/null; rm -rf "$LAB_TMUX"; }
trap 'lab_cleanup; relaunch_cleanup' EXIT
echo "tmux resolved by the verb: $(PATH="$RR_DIR/fakebin:$PATH" command -v tmux)"
echo "private TMUX_TMPDIR=$TMUX_TMPDIR"

mkdir -p "$RR_DIR/agentbin"
# A copied /bin/sleep is killed by code signing on macOS, so the stand-in agent is a tiny compiled binary named claude.
printf '#include <unistd.h>\nint main(void){sleep(600);return 0;}\n' > "$LAB_TMUX/agent.c"
cc -o "$RR_DIR/agentbin/claude" "$LAB_TMUX/agent.c" || { echo "cc failed"; exit 1; }
tmux new-session -d -s fmses -n "fm-$RR_ID" -c "$RR_DIR/wt" "$RR_DIR/agentbin/claude"
/bin/sleep 1
say "real tmux inventory on the private socket"
tmux ls
tmux list-windows -t fmses -F '#{session_name}:#{window_name} pane_current_command=#{pane_current_command} pane_pid=#{pane_pid}'

say "A. agent alive in a real pane: rerecord-slot --check"
before=$(rec_inventory)
rr_run --check; echo "exit=$?"
say "B. agent alive in a real pane: rerecord-slot write"
rr_write; echo "exit=$?"
[ "$before" = "$(rec_inventory)" ] && echo "ALIVE-REFUSAL-WROTE-NOTHING" || echo "ALIVE-RUN-CHANGED-STATE"
rr_slot_lines

say "C. kill the real tmux server (agent gone), then rerecord-slot write"
tmux kill-server
/bin/sleep 0.5
tmux ls 2>&1 | head -n 2
rr_write; echo "exit=$?"
rr_slot_lines
ls -1 "$(rr_audit_dir)" 2>/dev/null
