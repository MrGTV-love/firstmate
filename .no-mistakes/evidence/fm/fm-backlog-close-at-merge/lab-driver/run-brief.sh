#!/usr/bin/env bash
# S1: generate real ship briefs with bin/fm-brief.sh in a marked lab home.
set -u
WT=$1; EV=$2; cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>"$EV/lab-home-brief.stderr")"; LAB=$FM_HOME
trap 'bin/fm-lab-home.sh teardown "$LAB" && rm -rf "$LAB" && echo "lab removed: $LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
for mode in no-mistakes direct-PR; do
  id=lab-brief-$(printf '%s' "$mode" | tr 'A-Z' 'a-z')
  echo "\$ FM_HOME=<lab> bin/fm-brief.sh $id alpha --mode $mode"
  FM_HOME="$LAB" bin/fm-brief.sh "$id" alpha --mode "$mode" 2>&1 | tail -3
  b="$LAB/data/$id/brief.md"
  [ -f "$b" ] || { echo "no brief written"; continue; }
  cp "$b" "$EV/generated-ship-brief-$mode.md"
  echo "-- lines in the generated brief that teach the block ($mode):"
  grep -n "Closes-backlog-item\|Train-member\|Before that done, check the PR body\|After /no-mistakes reports CI green\|is the handoff that starts the pipeline" "$b" | cut -c1-300
  echo "-- old 'Closes: <task-id>' form present: $(grep -c 'Closes: <task-id>' "$b") line(s)"
  echo
done
