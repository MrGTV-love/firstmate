#!/usr/bin/env bash
# Runs each live group in its own fresh marked lab home (bin/fm-lab-home.sh),
# with a private tmux socket dir, and removes the lab afterwards.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
export WT=${WT:?}
run_group() {  # <name> <script>...
  local name=$1; shift
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  LAB=$("$WT/bin/fm-lab-home.sh" create "$LAB") || { echo "lab create failed"; return 1; }
  export LAB
  for s in "$@"; do
    echo "########## $name: $s (target $(git -C "$WT" rev-parse --short HEAD))"
    (cd "$WT" && timeout 1500 env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS bash "$EV/$s" 2>&1) | sed "s#$LAB#\$LAB#g"
  done
  TMUX_TMPDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB") tmux kill-server 2>/dev/null
  "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  pkill -f "$LAB" 2>/dev/null
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"
  echo "########## $name: lab removed: $([ -e "$LAB" ] && echo NO || echo yes)"
}
case "${1:?}" in
  agent) run_group agent live-run-agent.sh ;;
  core) run_group core live-run-1.sh ;;
  more) run_group more live-run-2.sh live-run-6-unverified.sh ;;
  nested) run_group nested live-run-7.sh ;;
  fallback) run_group fallback live-run-4.sh live-run-5.sh ;;
  watch) run_group watch live-run-2.sh live-run-3-watcher.sh ;;
esac
