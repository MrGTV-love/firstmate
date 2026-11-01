# Exact s4c shape: an UNLANDED own nested prior copy with a unique ignored file, plus a recorded bundle and filed call.
nested_bundle_case() {  # <id> <relpath> <block>
  local id=$1
  new_task "$id" || return 1
  NEST="$COPY/$2"; mkdir -p "${NEST%/*}"
  git -C "$PROJ" worktree add -q -b "fm/$id-side" "$NEST" main
  echo side > "$NEST/side.txt"; git -C "$NEST" add side.txt; git -C "$NEST" commit -qm 'unpublished side work'
  printf 'unique.dat\n' >> "$(git -C "$NEST" rev-parse --path-format=absolute --git-path info/exclude)"
  echo 'only copy of these bytes' > "$NEST/unique.dat"
  echo "prior_worktree=$NEST" >> "$FM_HOME/state/$id.meta"
  SRC=$SCR/$id.bundle; mkdir -p "$FM_HOME/data/$id"
  git -C "$PROJ" bundle create "$SRC" --all 2>/dev/null
  printf '%s\t%s\t%s\n' "$SRC" "$(shasum -a 256 "$SRC" | awk '{print $1}')" "$(git bundle list-heads "$SRC" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)" > "$FM_HOME/data/$id/preservation-bundles.tsv"
  hold_call "$id" "$SRC" "$(cut -f3 "$FM_HOME/data/$id/preservation-bundles.tsv")" >/dev/null
  [ "$3" = 0 ] || : > "$FM_HOME/data/$id/nested-copy-preserved"
}
n=0
for rel in .claude/worktrees/side nested/side; do
  for CODE in base new; do
    [ "$CODE" = base ] && TDBIN=$SCR/base/bin/fm-teardown.sh || TDBIN=$WT/bin/fm-teardown.sh
    for BLOCK in 0 1; do
      n=$((n+1)); id=t-h$n
      echo; echo "=== $CODE code | unlanded nested prior copy at <slot>/$rel | unique ignored file | bundle+call recorded | preservation blocked=$BLOCK ($id) ==="
      nested_bundle_case $id $rel $BLOCK
      env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE "$TDBIN" $id 2>&1 | grep -v -e '^●' -e 'watcher still down' -e '^fm-gate-refuse' -e '^$' -e '^🌳' | grep -v -e 'land-or-drop call for' | cut -c1-300; echo "[exit ${PIPESTATUS[0]}]"
      present "$NEST/.git"; echo "unique.dat in copy: $(cat "$NEST/unique.dat" 2>&1 | head -1)"
      echo "preserved files under data/$id/nested-copy-preserved:"; find "$FM_HOME/data/$id/nested-copy-preserved" -type f 2>/dev/null | sed "s|$FM_HOME/||"
    done
  done
done
