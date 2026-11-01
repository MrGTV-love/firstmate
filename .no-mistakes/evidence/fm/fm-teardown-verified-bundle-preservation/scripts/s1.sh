. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/common.sh
id=lbndl1
make_task $id || exit 1
head=$(git -C "$SLOT" rev-parse HEAD)
echo "== slot=$SLOT head=$head"
echo "== (a) no bundle, ordinary teardown"; teardown $id; echo "exit=$?"
test -d "$SLOT" && echo "slot still present"; test -f "$FM_HOME/state/$id.meta" && echo "meta still present"
B="$FM_HOME/scratch-bundles/$id.bundle"
record_bundle $id "$SLOT" "$B" --all; echo "== record:"; cat "$FM_HOME/data/$id/preservation-bundles.tsv"
echo "== (b) bundle recorded, no captain call held"; teardown $id; echo "exit=$?"
test -d "$SLOT" && echo "slot still present"
echo "== (c) file the captain's call"; hold_call $id "$B"; echo "exit=$?"
tasks-axi show $id --file "$FM_HOME/data/backlog.md" | sed -n '1,12p'
echo "== (d) ordinary teardown, no --force"; teardown $id; echo "exit=$?"
test -d "$SLOT" && echo "slot dir still present (pool slot)" ; git -C "$SLOT" rev-parse HEAD 2>/dev/null
test -f "$FM_HOME/state/$id.meta" && echo "META STILL PRESENT" || echo "meta removed"
(cd "$PROJ" && treehouse status 2>&1 | head -5)
echo "== backlog row after:"; tasks-axi show $id --file "$FM_HOME/data/backlog.md" | sed -n '1,14p'
grep -n "Recently Landed" -A5 "$FM_HOME/data/backlog.md" || echo "(no Recently Landed section)"
git -C "$PROJ" rev-parse --verify -q "fm/$id" && echo "branch fm/$id still in project" || echo "branch fm/$id gone from project"
echo "== (e) delete source bundle, restore from stored copy"
digest=$(cut -f2 "$FM_HOME/data/$id/preservation-bundles.tsv"); stored="$FM_HOME/data/$id/preserved-bundles/$digest.bundle"
rm -f "$B"; ls -l "$stored"; shasum -a 256 "$stored"
R="$FM_HOME/restore-$id.git"; git init -q --bare "$R"
git -C "$R" fetch -q "$stored" "$head:refs/heads/recovered" && git -C "$R" show "recovered:work.txt" && git -C "$R" rev-parse recovered
