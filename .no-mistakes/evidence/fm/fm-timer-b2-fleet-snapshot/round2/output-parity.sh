#!/usr/bin/env bash
# Round 2 output parity: base and fix fm-fleet-snapshot.sh against one lab home with
# 4 secondmates whose notes hold spaces, tabs, unicode and quotes, plus one with no
# status file. Diffs .secondmate_current after dropping clock-derived fields.
# Usage: output-parity.sh <fix-root> <base-root>
set -u
FIX=$1 BASE=$2
eval "$("$FIX/bin/fm-lab-home.sh" env 2>/dev/null)"
H=$FM_HOME
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"
: > "$H/data/secondmates.md"
tmux new-session -d -s firstmate -n boot "exec sleep 600"
notes=('plain review underway' '  lead and trail  ' $'tab\there "quoted" é ✓' 'dollar $HOME `x`')
for i in 1 2 3 4 5; do
  id=mate$i
  printf 'kind=secondmate\nharness=codex\nbackend=tmux\nwindow=firstmate:fm-%s\n' "$id" > "$H/state/$id.meta"
  if [ "$i" -le 4 ]; then
    printf 'working [key=k%s]: %s\n' "$i" "${notes[$((i-1))]}" > "$H/state/$id.status"
    printf -- '- %s (home: %s/missing-%s; scope: reviews; projects: alpha; added 2026-10-01)\n' "$id" "$H" "$id" >> "$H/data/secondmates.md"
  fi
  tmux new-window -d -t firstmate -n "fm-$id" "printf '%s\n> \n' \"${notes[0]}\"; exec sleep 600"
done
sleep 1
strip='.secondmate_current | walk(if type == "object" then del(.observed_at, .age_seconds, .observed_age_seconds, .captured_at, .generated_at, .elapsed_ms) else . end)'
for r in base:"$BASE" fix:"$FIX"; do
  env -u NO_MISTAKES_GATE FM_DURATION_FILE=off "${r#*:}/bin/fm-fleet-snapshot.sh" --json > "$H/${r%%:*}.json" 2> "$H/${r%%:*}.err"
  echo "${r%%:*} rc=$? records=$(jq '.secondmate_current.records | length' "$H/${r%%:*}.json")"
  jq -S "$strip" "$H/${r%%:*}.json" > "$H/${r%%:*}.norm"
done
if diff -u "$H/base.norm" "$H/fix.norm"; then echo "secondmate_current identical (clock fields dropped)"; else echo "secondmate_current DIFFERS"; fi
echo "fix event notes as parsed:"; jq -r '.secondmate_current.records[] | "\(.id): \(.parent_event.note // .parent_event.last_event.note // "-" | @json)"' "$H/fix.json"
tmux kill-server
"$FIX/bin/fm-lab-home.sh" teardown "$H" && rm -rf "$H" && echo "lab torn down"
