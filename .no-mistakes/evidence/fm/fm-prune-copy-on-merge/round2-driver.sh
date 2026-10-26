#!/usr/bin/env bash
# Round 2: re-drive every round-1 live scenario against target commit ad8bd7984,
# each group in its own fresh disposable lab home, removed afterwards.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
export WT=${WT:?}
run_group() {  # <name> <script> [<follow-up script>...]
  local name=$1; shift
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; return 1; }
  mkdir -p "$LAB/tmux"
  export LAB
  for s in "$@"; do
    echo "########## $name: $s (target $(git -C "$WT" rev-parse --short HEAD))"
    (cd "$WT" && timeout 900 env -u NO_MISTAKES_GATE bash "$EV/$s" 2>&1) | sed "s#$LAB#\$LAB#g"
  done
  TMUX_TMPDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB") tmux kill-server 2>/dev/null
  "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  pkill -f "$LAB" 2>/dev/null
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"
  echo "########## $name: lab removed: $([ -e "$LAB" ] && echo NO || echo yes)"
}
case "${1:-all}" in
  g1) run_group g1 live-run-1.sh ;;
  g2) run_group g2 live-run-2.sh live-run-3-watcher.sh live-run-6-unverified.sh ;;
  g4) run_group g4 live-run-4.sh live-run-5.sh ;;
esac
