#!/usr/bin/env bash
# Round 2 wall-time pairs: real fm-fleet-snapshot.sh (base vs fix) against the same
# disposable lab home (bin/fm-lab-home.sh env) with N secondmates, each with a real
# tmux window on the lab's private socket (TMUX_TMPDIR). Alternates base/fix.
# Usage: wall-pairs.sh <fix-root> <base-root> <mates> <pairs>
set -u
FIX=$1 BASE=$2 N=$3 PAIRS=$4
eval "$("$FIX/bin/fm-lab-home.sh" env 2>/dev/null)"
H=$FM_HOME
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"
: > "$H/data/secondmates.md"
tmux new-session -d -s firstmate -n boot "exec sleep 3600"
for i in $(seq 1 "$N"); do
  id=mate$i
  printf 'kind=secondmate\nharness=codex\nbackend=tmux\nwindow=firstmate:fm-%s\n' "$id" > "$H/state/$id.meta"
  printf 'working [key=review%s]: review %s underway\n' "$i" "$i" > "$H/state/$id.status"
  printf -- '- %s (home: %s/missing-%s; scope: reviews; projects: alpha; added 2026-10-01)\n' "$id" "$H" "$id" >> "$H/data/secondmates.md"
  tmux new-window -d -t firstmate -n "fm-$id" "printf 'review $i underway\n> \n'; exec sleep 3600"
done
sleep 1
echo "lab=$H mates=$N windows=$(tmux list-windows -t firstmate | wc -l | tr -d ' ')"
run() {  # <root>
  local s e
  s=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  env -u NO_MISTAKES_GATE FM_DURATION_FILE=off "$1/bin/fm-fleet-snapshot.sh" --json > "$H/out.json" 2> "$H/err"
  rc=$?
  e=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  W=$(echo "$e - $s" | bc)
  C=$(jq '[.secondmate_current.records[] | select(.terminal_evidence.captured == true)] | length' "$H/out.json" 2>/dev/null)
  R=$(jq '.secondmate_current.registry.available' "$H/out.json" 2>/dev/null)
  A=$(jq '[.secondmate_current.records[] | select(.parent_event.activity_scan.available == true)] | length' "$H/out.json" 2>/dev/null)
}
for p in $(seq 1 "$PAIRS"); do
  if [ "${ORDER:-base-first}" = fix-first ]; then
    run "$FIX";  f="fix=${W}s rc=$rc captured=$C registry=$R activity_ok=$A"
    run "$BASE"; b="base=${W}s rc=$rc captured=$C registry=$R activity_ok=$A"
  else
    run "$BASE"; b="base=${W}s rc=$rc captured=$C registry=$R activity_ok=$A"
    run "$FIX";  f="fix=${W}s rc=$rc captured=$C registry=$R activity_ok=$A"
  fi
  echo "pair $p: $b | $f | load=$(sysctl -n vm.loadavg)"
done
tmux kill-server
"$FIX/bin/fm-lab-home.sh" teardown "$H" && rm -rf "$H"
echo "lab torn down"
