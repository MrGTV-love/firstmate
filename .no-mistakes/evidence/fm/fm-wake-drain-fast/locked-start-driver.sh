#!/bin/bash
# locked-start-driver.sh <label>: real Claude primary on a private fm-lab tmux
# socket with a disposable marked lab home seeded with 25 cold status logs
# (60 keyed resolved/working pairs each); its SessionStart hook runs the real
# locked session start. Tears the lab down in the same turn.
set -u
label=$1
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M4H90MTFF5AXBWANAFDMBF3V
ROOT=$PWD
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX); rmdir "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
cleanup() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null; rm -rf "$LAB"; echo "teardown: private fm-lab server killed; lab home removed (exists now: $([ -e "$LAB" ] && echo yes || echo no))"; }
trap cleanup EXIT
for ((t = 0; t < 25; t++)); do
  { printf 'working: starting task %s\n' "$t"
    for ((i = 0; i < 60; i++)); do printf 'resolved [key=side-%s]: routine close %s\n' "$i" "$i"; printf 'working: step %s\n' "$i"; done
  } > "$LAB/state/task$t.status"
done
settings="$EV/$label-settings.json"
printf '{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"python3 %s/startup-hook.py","timeout":180}]}]}}\n' "$EV" > "$settings"
CMD=(claude --setting-sources "" --settings "$settings" --strict-mcp-config --tools "" --no-session-persistence --max-budget-usd 0.10 -p "Reply exactly LAB_STARTUP_OK. Do not use tools.")
echo "launch: tmux -L fm-lab (TMUX_TMPDIR=<lab>/tmux) new-session -d -s primary -x 120 -y 40 -c <run worktree> -e FM_HOME=<lab> ${CMD[*]}"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$ROOT" \
  -e FM_HOME="$LAB" -e FM_LIVE_EVIDENCE="$EV" -e FM_LIVE_LABEL="$label" -e FM_LIVE_ROOT="$ROOT" \
  "${CMD[@]}" || exit 1
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab set-option -t primary remain-on-exit on >/dev/null
TMUX_TMPDIR="$LAB/tmux" /usr/bin/perl -e 'alarm 240; exec @ARGV' tmux -L fm-lab wait-for lab-startup-finished
echo "wait-for exit=$?"
for ((k = 0; k < 60; k++)); do
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > "$EV/$label-pane.txt" 2>/dev/null
  grep -q 'LAB_STARTUP_OK\|Pane is dead' "$EV/$label-pane.txt" && break
  /bin/sleep 2
done
echo "pane:"; grep -v '^$' "$EV/$label-pane.txt"
echo "measurement:"; cat "$EV/$label-measurement.json"
