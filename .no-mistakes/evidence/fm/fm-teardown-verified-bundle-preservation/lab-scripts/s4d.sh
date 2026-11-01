# s4d.sh: nested prior copy with a unique ignored file, commits LANDED (pushed), preservation dir blocked.
# CODE selects the teardown: new (gate worktree) or base (3c750632 extract).
nested_case() {  # <id> <block:1|0>
  local id=$1
  new_task "$id" || return 1
  NEST="$COPY/.claude/worktrees/side"; mkdir -p "${NEST%/*}"
  git -C "$PROJ" worktree add -q -b "fm/$id-side" "$NEST" main
  echo side > "$NEST/side.txt"; git -C "$NEST" add side.txt; git -C "$NEST" commit -qm 'side work'
  printf 'unique.dat\n' >> "$(git -C "$NEST" rev-parse --path-format=absolute --git-path info/exclude)"
  echo 'only copy of these bytes' > "$NEST/unique.dat"
  echo "prior_worktree=$NEST" >> "$FM_HOME/state/$id.meta"
  git -C "$PROJ" merge -q --no-edit "fm/$id" "fm/$id-side" && git -C "$PROJ" push -q origin main
  git -C "$PROJ" fetch -q origin
  mkdir -p "$FM_HOME/data/$id"
  [ "$2" = 0 ] || : > "$FM_HOME/data/$id/nested-copy-preserved"
}
report() {
  present "$NEST/.git"; echo "unique.dat in copy: $(cat "$NEST/unique.dat" 2>&1)"
  echo "preserved copies under data/$1:"; find "$FM_HOME/data/$1" -type f | sed "s|$FM_HOME/||"
}
for CODE in base new; do
  [ "$CODE" = base ] && TDBIN=$SCR/base/bin/fm-teardown.sh || TDBIN=$WT/bin/fm-teardown.sh
  for BLOCK in 1 0; do
    id=t-s4e-$CODE-$BLOCK
    echo; echo "=== $CODE code, landed (merged into main and pushed) commits, nested copy with unique ignored file, preservation blocked=$BLOCK ==="
    nested_case $id $BLOCK
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE "$TDBIN" $id 2>&1 | grep -v -e '^●' -e 'watcher still down' -e '^fm-gate-refuse' -e '^$'; echo "[exit ${PIPESTATUS[0]}]"
    report $id
  done
done
