#!/usr/bin/env bash
# "Another agent": run a command in its own window of the lab's private tmux server.
# Usage: other.sh <window> <command...>   |   other.sh --stop <window>
set -u
T() { env TMUX_TMPDIR="$LABTMUX" tmux -L fm-lab "$@"; }
if [ "$1" = --stop ]; then T send-keys -t "other:$2" C-c; exit; fi
w=$1; shift
T new-window -d -t other -n "$w" -e LAVISH_AXI_STATE_DIR="$LAVISH_AXI_STATE_DIR" -e LAVISH_AXI_PORT="$LAVISH_AXI_PORT" -e LAVISH_AXI_HOST=127.0.0.1 -e LAVISH_AXI_NO_OPEN=1 -e FM_HOME="${OTHER_FM_HOME:-}" -e FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT"
T send-keys -t "other:$w" "$*" Enter
