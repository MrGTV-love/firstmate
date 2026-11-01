# Round-2 adversarial shapes around the new ignored-file guard. Each shape: base code vs new code.
bundle_all() {  # <id>: bundle every ref in the project, record it, and file the call
  local id=$1 SRC=$SCR/$1.bundle; mkdir -p "$FM_HOME/data/$id"
  git -C "$PROJ" bundle create "$SRC" --all 2>/dev/null
  printf '%s\t%s\t%s\n' "$SRC" "$(shasum -a 256 "$SRC" | awk '{print $1}')" "$(git bundle list-heads "$SRC" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)" > "$FM_HOME/data/$id/preservation-bundles.tsv"
  hold_call "$id" "$SRC" "$(cut -f3 "$FM_HOME/data/$id/preservation-bundles.tsv")" >/dev/null
}
tdv() {  # <code> <id>
  local bin=$WT/bin/fm-teardown.sh; [ "$1" = base ] && bin=$SCR/base/bin/fm-teardown.sh
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE "$bin" "$2" 2>&1 | grep -v -e '^●' -e 'watcher still down' -e '^fm-gate-refuse' -e '^$' -e '^🌳' -e 'land-or-drop call for' -e 'preserved unlanded commits in bundle' | cut -c1-320; echo "[exit ${PIPESTATUS[0]}]"
}
nested_copy() {  # <id> <relpath>: unlanded nested copy with a unique ignored file
  NEST="$COPY/$2"; mkdir -p "${NEST%/*}"
  git -C "$PROJ" worktree add -q -b "fm/$1-side" "$NEST" main
  echo side > "$NEST/side.txt"; git -C "$NEST" add side.txt; git -C "$NEST" commit -qm 'side work'
  printf 'unique.dat\n' >> "$(git -C "$NEST" rev-parse --path-format=absolute --git-path info/exclude)"
  echo 'only copy of these bytes' > "$NEST/unique.dat"
}
report() {  # <id>
  present "$NEST/.git"; echo "unique.dat in copy: $(cat "$NEST/unique.dat" 2>&1 | head -1)"; present "$FM_HOME/state/$1.meta"
  echo "hash-recorded copies:"; find "$FM_HOME/data/$1/nested-copy-preserved" -type f 2>/dev/null | sed "s|$FM_HOME/||"
}
for CODE in base new; do
  id=t-a-$CODE
  echo; echo "=== A ($CODE): task's own returned slot, unlanded, holds a unique ignored file; bundle + call ==="
  new_task $id || exit 1
  printf 'slot-unique.dat\n' >> "$(git -C "$COPY" rev-parse --path-format=absolute --git-path info/exclude)"
  echo 'slot bytes' > "$COPY/slot-unique.dat"
  bundle_all $id; tdv $CODE $id
  echo "slot-unique.dat after: $(cat "$COPY/slot-unique.dat" 2>&1)"; present "$FM_HOME/state/$id.meta"; echo "slot HEAD: $(git -C "$COPY" rev-parse --short HEAD)"

  id=t-b-$CODE
  echo; echo "=== B ($CODE): slot bundle-only; nested prior copy is LANDED (merged, pushed) and holds a unique ignored file ==="
  new_task $id || exit 1
  nested_copy $id nested/side
  echo "prior_worktree=$NEST" >> "$FM_HOME/state/$id.meta"
  git -C "$PROJ" merge -q --no-edit "fm/$id-side" && git -C "$PROJ" push -q origin main; git -C "$PROJ" fetch -q origin
  bundle_all $id; tdv $CODE $id; report $id

  id=t-c-$CODE
  echo; echo "=== C ($CODE): slot bundle-only; nested prior copy is ANCHORED (refs/fm/anchor) and holds a unique ignored file ==="
  new_task $id || exit 1
  nested_copy $id nested/side
  echo "prior_worktree=$NEST" >> "$FM_HOME/state/$id.meta"
  h=$(git -C "$NEST" rev-parse HEAD); git -C "$PROJ" update-ref "refs/fm/anchor/$id-$(git -C "$NEST" rev-parse --short HEAD)" "$h"
  bundle_all $id; tdv $CODE $id; report $id

  id=t-d-$CODE
  echo; echo "=== D ($CODE): task's current copy nested in the claimed slot (enclosing), unlanded, unique ignored file; bundle + call ==="
  new_task $id || exit 1
  nested_copy $id nested/current
  { sed -e '/^worktree=/d' -e '/^branch=/d' "$FM_HOME/state/$id.meta"; echo "worktree=$NEST"; echo "branch=fm/$id-side"; echo "prior_worktree=$COPY"; } > "$FM_HOME/state/$id.meta.new"; mv "$FM_HOME/state/$id.meta.new" "$FM_HOME/state/$id.meta"
  bundle_all $id; tdv $CODE $id; report $id

  id=t-f-$CODE
  echo; echo "=== F ($CODE): nested prior copy, unlanded, holds ONLY machinery ignored files (node_modules, .claude/x); bundle + call ==="
  new_task $id || exit 1
  NEST="$COPY/nested/side"; mkdir -p "${NEST%/*}"
  git -C "$PROJ" worktree add -q -b "fm/$id-side" "$NEST" main
  echo side > "$NEST/side.txt"; git -C "$NEST" add side.txt; git -C "$NEST" commit -qm 'side work'
  printf 'node_modules/\n.claude/\n' >> "$(git -C "$NEST" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$NEST/node_modules" "$NEST/.claude"; echo cache > "$NEST/node_modules/x.js"; echo note > "$NEST/.claude/x"
  echo "prior_worktree=$NEST" >> "$FM_HOME/state/$id.meta"
  bundle_all $id; tdv $CODE $id; present "$NEST/.git"; present "$FM_HOME/state/$id.meta"
done

for CODE in base new; do
  for SHAPE in unique clean; do
    id=t-e-$SHAPE-$CODE
    echo; echo "=== E ($CODE): PLAIN git worktree task copy outside the pool, unlanded, shape=$SHAPE; bundle + call ==="
    new_task $id || exit 1
    (cd "$PROJ" && treehouse return --force "$COPY" >/dev/null 2>&1) || true
    P="$FM_HOME/work/$id/plain"; git -C "$PROJ" worktree add -q -b "fm/$id-plain" "$P" main
    P=$(cd "$P" && pwd -P)
    echo plain > "$P/plain.txt"; git -C "$P" add plain.txt; git -C "$P" commit -qm 'plain work'
    if [ "$SHAPE" = unique ]; then
      printf 'unique.dat\n' >> "$(git -C "$P" rev-parse --path-format=absolute --git-path info/exclude)"
      echo 'only copy of these bytes' > "$P/unique.dat"
    fi
    { sed -e '/^worktree=/d' -e '/^branch=/d' "$FM_HOME/state/$id.meta"; echo "worktree=$P"; echo "branch=fm/$id-plain"; } > "$FM_HOME/state/$id.meta.new"; mv "$FM_HOME/state/$id.meta.new" "$FM_HOME/state/$id.meta"
    H=$(git -C "$P" rev-parse HEAD)
    bundle_all $id; tdv $CODE $id; NEST=$P; report $id
    D=$(cut -f2 "$FM_HOME/data/$id/preservation-bundles.tsv"); S="$FM_HOME/data/$id/preserved-bundles/$D.bundle"
    if [ -f "$S" ]; then r=$SCR/restore-$id; rm -rf "$r"; git init -q "$r"; git -C "$r" fetch -q "$S" "$H:refs/heads/recovered" && echo "stored copy restores $H: $(git -C "$r" show recovered:plain.txt)"; fi
  done
done
