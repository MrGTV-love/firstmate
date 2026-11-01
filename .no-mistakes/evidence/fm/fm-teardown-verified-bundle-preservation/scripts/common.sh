# Sourced by every lab scenario. Lab-only paths; strips fleet overrides.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6ARTNJJE53FT9ETN002MAA0
EVID=/Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0
. "$EVID/scripts/lab.env"
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export TREEHOUSE_ROOT="$FM_HOME/pool" NM_HOME="$FM_HOME/nm"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@lab GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@lab
PROJ="$FM_HOME/projects/demo"
. "$WT/bin/fm-wake-lib.sh" 2>/dev/null || true

# make_task <id>: lease a real treehouse slot on branch fm/<id>, commit one
# unpushed change, claim the slot, open a real tmux endpoint on the lab socket,
# write the task record (lab fixture), and file an In flight backlog row.
make_task() {
  local id=$1 slot
  slot=$(cd "$PROJ" && treehouse get --lease -b "fm/$id" 2>"$FM_HOME/th-$id.err") || { cat "$FM_HOME/th-$id.err"; return 1; }
  slot=$(cd "$slot" && pwd -P)
  printf 'work of %s\n' "$id" > "$slot/work.txt"
  git -C "$slot" add work.txt && git -C "$slot" commit -qm "unpublished work of $id"
  fm_treehouse_slot_owner_claim "$slot" "$id" "$FM_HOME" || return 1
  tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate -n keep 'sleep 86400'
  tmux new-window -d -t firstmate: -n "fm-$id" -c "$slot" 'sleep 86400'
  {
    printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nbranch=fm/%s\n' "$id" "$id" "$slot" "$id"
    printf 'project=%s\nkind=ship\nmode=local-only\nspawn_gen=lab-%s\n' "$PROJ" "$id"
  } > "$FM_HOME/state/$id.meta"
  tasks-axi add "$id" "lab bundle task $id" --kind ship --file "$FM_HOME/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$FM_HOME/data/backlog.md" >/dev/null
  SLOT=$slot
}

# record_bundle <id> <copy> <bundle> [revs...]: the header's documented recipe.
record_bundle() {
  local task=$1 copy=$2 bundle=$3 digest tips; shift 3
  mkdir -p "${bundle%/*}" "$FM_HOME/data/$task"
  git -C "$copy" bundle create "$bundle" "${@:---all}" 2>/dev/null &&
  git -C "$copy" bundle verify "$bundle" >/dev/null 2>&1 &&
  digest=$(shasum -a 256 "$bundle" | awk '{print $1}') &&
  tips=$(git bundle list-heads "$bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -) &&
  printf '%s\t%s\t%s\n' "$bundle" "$digest" "$tips" > "$FM_HOME/data/$task/preservation-bundles.tsv"
  BUNDLE_TIPS=$tips BUNDLE_DIGEST=$digest
}

hold_call() {  # <id> <bundle>
  "$WT/bin/fm-captain-hold.sh" hold "$1" --owner captain \
    --reason "Land or drop the unlanded commits of $1: preserved in bundle $2, recorded tips $BUNDLE_TIPS." </dev/null
}

teardown() {  # <id> [args]  (stdin closed)
  ( cd "$WT" && bin/fm-teardown.sh "$@" </dev/null )
}
