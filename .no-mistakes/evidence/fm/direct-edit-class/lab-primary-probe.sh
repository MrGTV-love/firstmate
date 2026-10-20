#!/usr/bin/env bash
# probe.sh <lab> <label> <prompt> : send one prompt to the lab primary, wait for idle, capture pane
set -u
LAB=$1 LABEL=$2 PROMPT=$3 EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5BEKG2HAK954QR23EVTRQA7
T() { TMUX_TMPDIR="$(cat "$LAB/state/.fm-lab-tmux-dir")" tmux -L fm-lab "$@"; }
T send-keys -t primary -l "$PROMPT"
sleep 1
T send-keys -t primary Enter
sleep 8
for i in $(seq 1 40); do
  sleep 4
  out=$(T capture-pane -p -t primary -S -200)
  # idle when no spinner/interrupt hint is shown
  if ! printf '%s\n' "$out" | grep -qE 'esc to interrupt|Thinking|Running…|\([0-9]+s · |thinking with'; then break; fi
done
T capture-pane -p -t primary -S -200 | sed -e 's/[[:space:]]*$//' | cat -s > "$EV/probe-$LABEL.txt"
cat "$EV/probe-$LABEL.txt" | tail -60
