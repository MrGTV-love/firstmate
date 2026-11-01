. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/common.sh
f() { grep -v "^●\|WARNING: watcher"; }
id=lbndl6; S=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$id.meta"); H=$(git -C "$S" rev-parse HEAD); rec="$FM_HOME/data/$id/preservation-bundles.tsv"; cp "$rec" "$FM_HOME/rec6.good"
B=$(cut -f1 "$rec"); cp "$B" "$FM_HOME/b6.good"
kept() { [ -f "$FM_HOME/state/$id.meta" ] && [ "$(git -C "$S" rev-parse HEAD)" = "$H" ] && echo "KEPT: meta + copy HEAD $H" || echo "LOST"; }
echo "######## S10a idle reaper actor (FM_IDLE_REAP_ADMISSION=1), valid bundle + held call"
( cd "$WT" && FM_IDLE_REAP_ADMISSION=1 bin/fm-teardown.sh $id </dev/null ) 2>&1 | f | head -4; echo "exit=${PIPESTATUS[0]}"; kept
echo "######## S10b supervision branch actor (FM_SUPERVISION_ACTOR=branch)"
( cd "$WT" && FM_SUPERVISION_ACTOR=branch bin/fm-teardown.sh $id </dev/null ) 2>&1 | f | head -4; echo "exit=${PIPESTATUS[0]}"; kept
echo "######## S10c malformed record line (two fields)"
cut -f1,2 "$FM_HOME/rec6.good" > "$rec"; teardown $id 2>&1 | f | head -2; echo "exit=${PIPESTATUS[0]}"; kept
echo "######## S10d record is a symlink"
cp "$FM_HOME/rec6.good" "$FM_HOME/rec6.link-target"; rm -f "$rec"; ln -s "$FM_HOME/rec6.link-target" "$rec"; teardown $id 2>&1 | f | head -2; echo "exit=${PIPESTATUS[0]}"; kept
echo "######## S10e truncated bundle (record re-hashed to match)"
rm -f "$rec"; rm -rf "$FM_HOME/data/$id/preserved-bundles"; head -c 300 "$FM_HOME/b6.good" > "$B"; d=$(shasum -a 256 "$B" | awk '{print $1}')
awk -F'\t' -v OFS='\t' -v d="$d" '{$2=d; print}' "$FM_HOME/rec6.good" > "$rec"; teardown $id 2>&1 | f | head -2; echo "exit=${PIPESTATUS[0]}"; kept
echo "######## S10f control: restore the good bundle and record, ordinary teardown"
cp "$FM_HOME/b6.good" "$B"; cp "$FM_HOME/rec6.good" "$rec"; teardown $id 2>&1 | f | grep -E "preserved unlanded|complete|REFUSED" | head -3; echo "exit=${PIPESTATUS[0]}"
[ -f "$FM_HOME/state/$id.meta" ] && echo "meta present" || echo "meta removed"
