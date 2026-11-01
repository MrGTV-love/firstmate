. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/common.sh
f() { grep -v "^●\|WARNING: watcher"; }
real_bundle=$(ls "$FM_HOME"/data/lbndl1/preserved-bundles/*.bundle | head -1)
for posture in forced; do
  id=lsm-$posture; home="$(cat "$EVID/scripts/smbase.path")/$id"; wt="$FM_HOME/sm-wt-$id"
  echo "######## S8 secondmate retirement ($posture) while its home keeps a stored bundle"
  git -C "$PROJ" worktree add -q -b "fm/$id" "$wt" main
  mkdir -p "$home/state" "$home/data" "$home/config"; printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  stored="$home/data/child-a/preserved-bundles/${real_bundle##*/}"; mkdir -p "${stored%/*}"; cp "$real_bundle" "$stored"
  { printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=secondmate\nmode=local-only\nspawn_gen=lab-%s\nhome=%s\n' "$id" "$id" "$wt" "$PROJ" "$id" "$home"; } > "$FM_HOME/state/$id.meta"
  tmux new-window -d -t firstmate: -n "fm-$id" -c "$home" 'sleep 86400'
  args=()
  if [ $posture = forced ]; then
    cwt="$(cat "$EVID/scripts/smbase.path")/child-a-wt-$id"; git -C "$PROJ" worktree add -q -b "fm/child-a-$id" "$cwt" main
    printf 'window=firstmate:fm-child-a\nendpoint_task_id=child-a\nworktree=%s\nproject=%s\nkind=ship\nmode=local-only\n' "$cwt" "$PROJ" > "$home/state/child-a.meta"; : > "$home/state/child-a.status"
    args=(--force --drop-file "$FM_HOME/drop-words.txt")
  fi
  teardown $id ${args[@]+"${args[@]}"} 2>&1 | f; echo "exit=${PIPESTATUS[0]}"
  [ -f "$stored" ] && echo "stored bundle kept: sha $(shasum -a 256 "$stored" | cut -c1-16)…"
  [ -f "$home/.fm-secondmate-home" ] && echo "home kept"; [ -f "$FM_HOME/state/$id.meta" ] && echo "secondmate record kept"
  tmux list-windows -t firstmate -F '#W' | grep -qx "fm-$id" && echo "secondmate endpoint window ALIVE"
  if [ $posture = forced ]; then [ -f "$home/state/child-a.meta" ] && echo "child-a record kept"; [ -e "$cwt/.git" ] && echo "child-a copy kept"; fi
  echo "-- move the stored bundle to a durable place outside the home, retry"
  mkdir -p "$FM_HOME/durable"; mv "$stored" "$FM_HOME/durable/$id-${stored##*/}"
  teardown $id ${args[@]+"${args[@]}"} 2>&1 | f | tail -6; echo "exit=${PIPESTATUS[0]}"
  [ -e "$home" ] && echo "home still present" || echo "home retired"; [ -f "$FM_HOME/durable/$id-${stored##*/}" ] && echo "moved bundle kept"
done
