#!/usr/bin/env bash
# lab-run.sh <name> <commands>: save the commands as steps/<name>.sh, run them in
# the lab pane, wait, and print the output file <name>.txt.
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M6HN2SACGPQ0JDT575QV98KC
name=$1; shift
printf '%s\n' "$*" > "$EV/steps/$name.sh"
rm -f "$EV/.done-$name"
tmux -L fm-lab send-keys -t primary:0 "source $EV/lab-lib.sh; source $EV/steps/$name.sh > $EV/$name.txt 2>&1; touch $EV/.done-$name" Enter
for _ in $(seq 1 580); do [ -f "$EV/.done-$name" ] && break; sleep 1; done
rm -f "$EV/.done-$name"
cat "$EV/$name.txt"
