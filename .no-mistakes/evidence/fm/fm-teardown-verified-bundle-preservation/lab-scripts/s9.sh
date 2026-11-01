for v in slot-checkout tasktmp-like; do
id=t-s9-$v
echo; echo "=== S9 ($v): data/$id/preserved-bundles is a symlink into a removal root ==="
new_task $id
SRC=$SCR/$id.bundle; record_bundle $id "$SRC"; hold_call $id "$SRC" "$(cut -f3 "$FM_HOME/data/$id/preservation-bundles.tsv")" >/dev/null
if [ "$v" = slot-checkout ]; then T="$COPY/.store"; printf '.store/\n' >> "$(git -C "$COPY" rev-parse --path-format=absolute --git-path info/exclude)"; else T="$COPY"; fi
mkdir -p "$T"; ln -s "$T" "$FM_HOME/data/$id/preserved-bundles"
ls -l "$FM_HOME/data/$id/preserved-bundles" | cut -c40-
td $id | grep -v -e '^unpushed' -e '^Merge the branch' | cut -c1-300
present "$FM_HOME/state/$id.meta"; echo "slot HEAD: $(git -C "$COPY" rev-parse HEAD) (branch fm/$id tip $(git -C "$PROJ" rev-parse fm/$id))"
done
