n=10
for CODE in base new; do
  [ "$CODE" = base ] && TDBIN=$SCR/base/bin/fm-teardown.sh || TDBIN=$WT/bin/fm-teardown.sh
  n=$((n+1)); id=t-i$n
  echo; echo "=== $CODE code | LANDED (merged into main) nested prior copy at <slot>/nested/side | unique ignored file | no bundle ($id) ==="
  new_task $id
  NEST="$COPY/nested/side"; mkdir -p "${NEST%/*}"
  git -C "$PROJ" worktree add -q -b "fm/$id-side" "$NEST" main
  echo side > "$NEST/side.txt"; git -C "$NEST" add side.txt; git -C "$NEST" commit -qm 'side work'
  printf 'unique.dat\n' >> "$(git -C "$NEST" rev-parse --path-format=absolute --git-path info/exclude)"
  echo 'only copy of these bytes' > "$NEST/unique.dat"
  echo "prior_worktree=$NEST" >> "$FM_HOME/state/$id.meta"
  git -C "$PROJ" merge -q --no-edit "fm/$id" "fm/$id-side" && git -C "$PROJ" push -q origin main
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE "$TDBIN" $id 2>&1 | grep -e REFUSED -e 'complete (' | cut -c1-200; echo "[exit ${PIPESTATUS[0]}]"
  present "$NEST/.git"; echo "unique.dat in copy: $(cat "$NEST/unique.dat" 2>&1 | head -1)"
  echo "preserved:"; find "$FM_HOME/data/$id" -path '*nested-copy-preserved*' -type f 2>/dev/null | sed "s|$FM_HOME/||"
done
echo; echo "=== S9: stored copy location inside a removal root (data/<id>/preserved-bundles is a symlink into the slot) ==="
new_task t-s9
SRC=$SCR/t-s9.bundle; record_bundle t-s9 "$SRC"; hold_call t-s9 "$SRC" "$(cut -f3 "$FM_HOME/data/t-s9/preservation-bundles.tsv")" >/dev/null
mkdir -p "$(git -C "$COPY" rev-parse --path-format=absolute --git-dir)/fm-lab-store"
ln -s "$(git -C "$COPY" rev-parse --path-format=absolute --git-dir)/fm-lab-store" "$FM_HOME/data/t-s9/preserved-bundles"
ls -l "$FM_HOME/data/t-s9/preserved-bundles"
td t-s9 | grep -v -e '^unpushed' -e '^Merge the branch' | cut -c1-300
present "$FM_HOME/state/t-s9.meta"; echo "slot HEAD: $(git -C "$COPY" rev-parse HEAD)"
echo "--- variant: preserved-bundles symlink points into the copy's checkout ---"
rm "$FM_HOME/data/t-s9/preserved-bundles"; mkdir -p "$SCR/inside-target"; 
ln -s "$COPY" "$FM_HOME/data/t-s9/preserved-bundles"
td t-s9 | grep -v -e '^unpushed' -e '^Merge the branch' | cut -c1-300
present "$FM_HOME/state/t-s9.meta"; echo "slot HEAD: $(git -C "$COPY" rev-parse HEAD)"; git -C "$COPY" status --short
