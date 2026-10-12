#!/usr/bin/env bash
# Live drive of bin/fm-spawn.sh in a disposable lab home, on the lab's private
# tmux socket, against a pool slot that real Treehouse leased.
# Usage: live-drive.sh <lab-home> <worktree> <case-kind> <spelling>
#   case-kind: unleased | recovered | ordinary
#   spelling:  trailing-slash | dot | double-slash
set -u
LAB=$1 WT=$2 KIND=$3 SPELLING=$4
POOL=$(dirname "$(dirname "$(find "$LAB/pool/.treehouse" -mindepth 3 -maxdepth 3 -type d -name demo | head -1)")")
SLOT="$POOL/1/demo"
P="$LAB/projects/demo"
NESTED="$SLOT/.claude/worktrees/nested-holder"
ID="new-$KIND-$SPELLING"
RECOVERED='recovered: state file was corrupt or truncated; verify before reuse'
lab_tmux() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }

[ -f "$LAB/pristine-state.json" ] || cp "$POOL/treehouse-state.json" "$LAB/pristine-state.json"
case "$SPELLING" in
  trailing-slash) ALIAS="$SLOT/" ;;
  dot) ALIAS="$SLOT/./" ;;
  double-slash) ALIAS="${SLOT%/*}//${SLOT##*/}" ;;
  none) ALIAS=$SLOT ;;
esac
case "$KIND" in
  unleased) FILTER='.worktrees += [(.worktrees[0] | del(.leased, .lease_id, .lease_holder, .leased_at) | .path = $alias)]' ;;
  recovered) FILTER='.worktrees += [(.worktrees[0] | .lease_holder = $holder | .path = $alias)]' ;;
  ordinary) FILTER='.worktrees += [(.worktrees[0] | .path = $alias)]' ;;
  pristine) FILTER='.' ;;
esac
jq --arg alias "$ALIAS" --arg holder "$RECOVERED" "$FILTER" "$LAB/pristine-state.json" > "$POOL/treehouse-state.json"
cp "$POOL/treehouse-state.json" "$LAB/before-state.json"

mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Reply with the single word done and then stop.

## Firstmate spec
Do nothing else. Do not edit any file.
EOF
printf 'window=primary:fm-holder\nworktree=%s\nproject=%s\nkind=ship\n' "$NESTED" "$P" > "$LAB/state/holder.meta"
touch "$LAB/state/.last-watcher-beat"

if ! lab_tmux has-session -t primary 2>/dev/null; then
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 200 -y 50 -c "$WT" \
    -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$LAB/pool" /bin/bash --norc --noprofile
fi

echo "=== case: $KIND alias spelled $SPELLING ==="
echo "--- Treehouse state entries (leased, holder, path) before the spawn ---"
jq -r '.worktrees[] | [(.leased // false | tostring), (.lease_holder // "-"), .path] | @tsv' "$POOL/treehouse-state.json"
fingerprint() { git -C "$SLOT" rev-parse HEAD; git -C "$SLOT" status --porcelain --untracked-files=all; git -C "$NESTED" rev-parse HEAD; }
fingerprint > "$LAB/before-copy"
rm -f "$LAB/out-$ID.log"
lab_tmux send-keys -t primary "cd '$WT' && bin/fm-spawn.sh $ID '$P' --scout > '$LAB/out-$ID.log' 2>&1; echo \"exit=\$?\" >> '$LAB/out-$ID.log'" Enter
for _ in $(seq 1 240); do
  grep -q '^exit=' "$LAB/out-$ID.log" 2>/dev/null && break
  sleep 0.5
done
echo "--- bin/fm-spawn.sh $ID <project> --scout (stdout+stderr, then exit code) ---"
cat "$LAB/out-$ID.log"
echo "--- after ---"
if cmp -s "$LAB/before-state.json" "$POOL/treehouse-state.json"; then echo "pool state file: unchanged"; else echo "pool state file: CHANGED"; fi
if fingerprint | cmp -s - "$LAB/before-copy"; then echo "leased slot and nested copy: unchanged"; else echo "leased slot and nested copy: CHANGED"; fi
if [ -e "$LAB/state/$ID.meta" ]; then echo "task record $ID.meta: published"; sed -n '/^worktree=/p' "$LAB/state/$ID.meta"; else echo "task record $ID.meta: not published"; fi
echo "lab tmux windows: $(lab_tmux list-windows -a -F '#{session_name}:#{window_name}' | tr '\n' ' ')"
