. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/common.sh
f() { grep -v "^●\|WARNING: watcher"; }
# nested_case <id> <unique|clean> <present|removed>: real leased slot (prior_worktree),
# nested current copy with unlanded work (bundle-covered), anchored own prior copy
# with a sentinel process whose cwd is inside it.
nested_case() {
  local id=$1 bytes=$2 cur=$3 slot nested prior head
  slot=$(cd "$PROJ" && treehouse get --lease -b "fm/$id" 2>/dev/null) || return 1; slot=$(cd "$slot" && pwd -P)
  fm_treehouse_slot_owner_claim "$slot" "$id" "$FM_HOME"
  nested="$slot/nested/current"; prior="$slot/nested/prior"; mkdir -p "$slot/nested"
  git -C "$PROJ" worktree add -q -b "fm/$id-v2" "$nested" main
  printf 'task work %s\n' "$id" > "$nested/work.txt"; git -C "$nested" add work.txt; git -C "$nested" commit -qm "unpublished task work $id"
  git -C "$PROJ" worktree add -q -b "fm/$id-prior" "$prior" main
  printf 'prior work\n' > "$prior/prior.txt"; git -C "$prior" add prior.txt; git -C "$prior" commit -qm "anchored prior work $id"
  head=$(git -C "$prior" rev-parse HEAD); git -C "$PROJ" update-ref "refs/fm/anchor/$id-$head" "$head"
  if [ "$bytes" = unique ]; then
    printf 'unique-anchored.dat\n' >> "$(git -C "$prior" rev-parse --path-format=absolute --git-path info/exclude)"
    printf 'only copy %s\n' "$id" > "$prior/unique-anchored.dat"
  fi
  { printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nbranch=fm/%s-v2\n' "$id" "$id" "$nested" "$id"
    printf 'project=%s\nkind=ship\nmode=local-only\nspawn_gen=lab-%s\nprior_worktree=%s\nprior_worktree=%s\n' "$PROJ" "$id" "$slot" "$prior"; } > "$FM_HOME/state/$id.meta"
  tasks-axi add "$id" "lab nested $id" --kind ship --file "$FM_HOME/data/backlog.md" >/dev/null; tasks-axi start "$id" --file "$FM_HOME/data/backlog.md" >/dev/null
  B="$FM_HOME/scratch-bundles/$id.bundle"; record_bundle "$id" "$nested" "$B" --all; hold_call "$id" "$B" >/dev/null
  tmux new-window -d -t firstmate: -n "fm-$id" -c "$slot" 'sleep 86400'
  tmux new-window -d -t firstmate: -n "sentinel-$id" -c "$prior" 'exec sleep 86401'
  sleep 1
  SENT=$(pgrep -f 'sleep 86401' | while read p; do [ "$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$prior" ] && echo $p; done | head -1)
  if [ "$cur" = removed ]; then git -C "$PROJ" worktree remove --force "$nested"; fi
  NSLOT=$slot NNESTED=$nested NPRIOR=$prior
  echo "case $id: slot=$slot nested=$nested ($cur) prior=$prior sentinel_pid=$SENT"
}
report() { local id=$1
  [ -f "$FM_HOME/state/$id.meta" ] && echo "meta present" || echo "meta removed"
  [ -e "$NPRIOR/.git" ] && echo "prior copy present" || echo "prior copy removed"
  [ -f "$NPRIOR/unique-anchored.dat" ] && echo "ignored bytes: $(cat "$NPRIOR/unique-anchored.dat")"
  [ -e "$NNESTED/.git" ] && echo "current copy present" || echo "current copy absent"
  kill -0 "$SENT" 2>/dev/null && echo "sentinel $SENT ALIVE (no reap ran)" || echo "sentinel $SENT gone (reaped)"
  tmux list-windows -t firstmate -F '#W' | grep -qx "fm-$id" && echo "endpoint window alive" || echo "endpoint window gone"
  (cd "$PROJ" && treehouse status 2>/dev/null | grep -F "$NSLOT" | sed 's/  */ /g')
}
