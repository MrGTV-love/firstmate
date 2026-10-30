#!/usr/bin/env bash
# Live lab for the open-work ledger change: mints a marked lab FM_HOME with its own private tmux
# socket, runs the worktree's real bin/ against it, and tears it down on exit.
# Usage: run-lab.sh <worktree> <evidence-dir>
set -u
WT=$1 E=$2
cd "$WT" || exit 1
unset TMUX TMUX_PANE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>"$E/lab-env.stderr")" || { echo "lab env failed"; cat "$E/lab-env.stderr"; exit 1; }
LAB=$FM_HOME
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-scratch.XXXXXX")
teardown() {
  tmux kill-server 2>/dev/null
  "$WT/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"
  echo "teardown: lab=$LAB rc=$? exists_after=$([ -e "$LAB" ] && echo yes || echo no)"
  rm -rf "$SCRATCH"
}
trap teardown EXIT
echo "lab FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR"
[ -z "${TMUX:-}" ] && [ -n "${TMUX_TMPDIR:-}" ] || { echo "refusing: tmux socket not isolated"; exit 1; }
python3 "$E/lab/drive.py" "$WT" "$SCRATCH" "$E"
echo "driver exit=$?"
