#!/usr/bin/env bash
# Live drive of bin/fm-spawn.sh in the lab with jq hidden from PATH.
# Usage: live-nojq.sh <lab-home> <worktree>
set -u
LAB=$1 WT=$2 ID=new-nojq
F="$LAB/nojq-bin"; mkdir -p "$F"
IFS=: read -ra D <<< "$PATH"
for d in "${D[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    n=${f##*/}
    [ "$n" = jq ] && continue
    [ -e "$F/$n" ] || ln -s "$f" "$F/$n" 2>/dev/null
  done
done
lab_tmux() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
POOL=$(dirname "$(dirname "$(find "$LAB/pool/.treehouse" -mindepth 3 -maxdepth 3 -type d -name demo | head -1)")")
mkdir -p "$LAB/data/$ID"
sed 's/x/x/' "$LAB/data/new-pristine-none/brief.md" > "$LAB/data/$ID/brief.md"
cp "$POOL/treehouse-state.json" "$LAB/before-state.json"
echo "=== case: slot 1 holds an ordinary real Treehouse lease; jq is not on PATH ==="
echo "jq on the spawn PATH: $(PATH="$F" command -v jq || echo none)"
rm -f "$LAB/out-$ID.log"
lab_tmux send-keys -t primary "cd '$WT' && PATH='$F' bin/fm-spawn.sh $ID '$LAB/projects/demo' --scout > '$LAB/out-$ID.log' 2>&1; echo \"exit=\$?\" >> '$LAB/out-$ID.log'" Enter
for _ in $(seq 1 240); do grep -q '^exit=' "$LAB/out-$ID.log" 2>/dev/null && break; sleep 0.5; done
echo "--- bin/fm-spawn.sh $ID <project> --scout (stdout+stderr, then exit code) ---"
cat "$LAB/out-$ID.log"
echo "--- after ---"
if cmp -s "$LAB/before-state.json" "$POOL/treehouse-state.json"; then echo "pool state file: unchanged"; else echo "pool state file: CHANGED"; fi
if [ -e "$LAB/state/$ID.meta" ]; then echo "task record $ID.meta: published"; else echo "task record $ID.meta: not published"; fi
echo "lab tmux windows: $(lab_tmux list-windows -a -F '#{session_name}:#{window_name}' | tr '\n' ' ')"
