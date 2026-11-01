. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/common.sh
check_kept() { local id=$1 s=$2 h=$3
  [ -f "$FM_HOME/state/$id.meta" ] && echo "KEPT: meta present" || echo "LOST: meta removed"
  [ "$(git -C "$s" rev-parse HEAD 2>/dev/null)" = "$h" ] && echo "KEPT: copy HEAD $h still checked out" || echo "LOST: copy HEAD moved"
  tmux list-windows -t firstmate -F '#W' | grep -qx "fm-$id" && echo "KEPT: endpoint window alive" || echo "NOTE: endpoint window gone"; }
prep() { local id=$1; make_task $id || exit 1; H=$(git -C "$SLOT" rev-parse HEAD); B="$FM_HOME/scratch-bundles/$id.bundle"; record_bundle $id "$SLOT" "$B" --all; hold_call $id "$B" >/dev/null; }

echo "######## S2a wrong sha256 in record"
id=lbndl2; prep $id
rec="$FM_HOME/data/$id/preservation-bundles.tsv"; awk -F'\t' -v OFS='\t' '{ $2="0000000000000000000000000000000000000000000000000000000000000000"; print }' "$rec" > "$rec.n" && mv "$rec.n" "$rec"; cat "$rec"
teardown $id; echo "exit=$?"; check_kept $id "$SLOT" "$H"

echo "######## S2b bundle lacks a later unlanded tip, then re-bundled"
id=lbndl3; prep $id
printf 'second\n' > "$SLOT/second.txt"; git -C "$SLOT" add second.txt; git -C "$SLOT" commit -qm "second unpublished commit"; H2=$(git -C "$SLOT" rev-parse HEAD); echo "new tip $H2 (first $H)"
teardown $id; echo "exit=$?"; check_kept $id "$SLOT" "$H2"
echo "-- re-bundle with both commits and re-file the call"
record_bundle $id "$SLOT" "$B" --all; cat "$FM_HOME/data/$id/preservation-bundles.tsv"
"$WT/bin/fm-captain-hold.sh" answer $id </dev/null >/dev/null 2>&1; hold_call $id "$B" >/dev/null; echo "hold rc=$?"
tasks-axi show $id --file "$FM_HOME/data/backlog.md" | grep -E "state:|held:"
teardown $id; echo "exit=$?"
[ -f "$FM_HOME/state/$id.meta" ] && echo "meta present" || echo "meta removed"
R="$FM_HOME/restore-$id.git"; git init -q --bare "$R"; st="$FM_HOME/data/$id/preserved-bundles/$(cut -f2 "$FM_HOME/data/$id/preservation-bundles.tsv").bundle"; rm -f "$B"
git -C "$R" fetch -q "$st" "$H2:refs/heads/r" && echo "restored: $(git -C "$R" show r:work.txt) / $(git -C "$R" show r:second.txt) / parent=$(git -C "$R" rev-parse r^)"

echo "######## S2c valid bundle + uncommitted file"
id=lbndl4; prep $id
printf 'uncommitted\n' > "$SLOT/dirty.txt"
teardown $id; echo "exit=$?"; check_kept $id "$SLOT" "$H"; [ -f "$SLOT/dirty.txt" ] && echo "KEPT: dirty.txt bytes: $(cat "$SLOT/dirty.txt")"
rm -f "$SLOT/dirty.txt"

echo "######## S2d valid bundle + away mode (.afk)"
id=lbndl5; prep $id
touch "$FM_HOME/state/.afk"
teardown $id; echo "exit=$?"; check_kept $id "$SLOT" "$H"
rm -f "$FM_HOME/state/.afk"
