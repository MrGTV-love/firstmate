#!/usr/bin/env bash
# Judge one hand-edited Treehouse state with the base and the target library.
# Usage: base-vs-target.sh <lab-home> <base-tree> <target-tree>
set -u
LAB=$1 BASE=$2 TARGET=$3
POOL=$(dirname "$(dirname "$(find "$LAB/pool/.treehouse" -mindepth 3 -maxdepth 3 -type d -name demo | head -1)")")
SLOT="$POOL/1/demo"
REC='recovered: state file was corrupt or truncated; verify before reuse'
verdict() (  # <tree>
  . "$1/bin/fm-task-copy-lib.sh"
  FM_TASK_COPY_POOL_STATE_FILE=
  FM_TASK_COPY_POOL_STATE_ENTRIES=
  rc=0
  fm_task_copy_pool_slot_held "$SLOT" || rc=$?
  printf 'rc=%s state=%s' "$rc" "$FM_TASK_COPY_SLOT_STATE"
)
echo "One real leased Treehouse entry plus one alias entry for the same slot."
echo "Verdict of fm_task_copy_pool_slot_held. rc=0 means held, so a spawn is allowed."
printf '%-10s %-15s %-24s %-24s\n' alias spelling base-8a86b966 target-e87751e5
for k in unleased recovered ordinary; do
  for s in trailing-slash dot double-slash; do
    case $s in
      trailing-slash) A="$SLOT/" ;;
      dot) A="$SLOT/./" ;;
      double-slash) A="${SLOT%/*}//${SLOT##*/}" ;;
    esac
    case $k in
      unleased) F='.worktrees += [(.worktrees[0] | del(.leased,.lease_id,.lease_holder,.leased_at) | .path=$a)]' ;;
      recovered) F='.worktrees += [(.worktrees[0] | .lease_holder=$h | .path=$a)]' ;;
      ordinary) F='.worktrees += [(.worktrees[0] | .path=$a)]' ;;
    esac
    jq --arg a "$A" --arg h "$REC" "$F" "$LAB/pristine-state.json" > "$POOL/treehouse-state.json"
    printf '%-10s %-15s %-24s %-24s\n' "$k" "$s" "$(verdict "$BASE")" "$(verdict "$TARGET")"
  done
done
cp "$LAB/pristine-state.json" "$POOL/treehouse-state.json"
