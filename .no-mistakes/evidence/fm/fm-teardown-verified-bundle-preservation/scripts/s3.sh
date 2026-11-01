. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/common.sh
BASE="$FM_HOME/basecode"; mkdir -p "$BASE"; git -C "$WT" archive 8618f63732d41ed857468b40a825f4db4135cf66 | tar -x -C "$BASE"
base_teardown() { ( cd "$BASE" && bin/fm-teardown.sh "$@" </dev/null ); }
kept() { [ -f "$FM_HOME/state/$1.meta" ] && echo "meta present" || echo "meta removed"; }
echo "######## S3a base code, same wrong-sha task lbndl2"; base_teardown lbndl2; echo "exit=$?"; kept lbndl2
echo "######## S3b base code, dirty task lbndl4"; S4=$(sed -n 's/^worktree=//p' "$FM_HOME/state/lbndl4.meta"); printf 'uncommitted\n' > "$S4/dirty.txt"
base_teardown lbndl4; echo "exit=$?"; kept lbndl4
echo "######## S3b' new code, same dirty task lbndl4"; teardown lbndl4; echo "exit=$?"; kept lbndl4; rm -f "$S4/dirty.txt"
echo "######## S3c base code with a fully valid bundle + held call (lbndl6)"
make_task lbndl6 || exit 1; B="$FM_HOME/scratch-bundles/lbndl6.bundle"; record_bundle lbndl6 "$SLOT" "$B" --all; hold_call lbndl6 "$B" >/dev/null
base_teardown lbndl6; echo "exit=$?"; kept lbndl6
echo "######## S3d --force, no drop words, no bundle: new code (lbndl5 after .afk removed; drop its bundle record)"
mv "$FM_HOME/data/lbndl5/preservation-bundles.tsv" "$FM_HOME/data/lbndl5/preservation-bundles.tsv.off"
teardown lbndl5 --force; echo "exit=$?"; kept lbndl5
echo "######## S3e --force, no drop words, no bundle: base code (lbndl7)"
make_task lbndl7 || exit 1
base_teardown lbndl7 --force; echo "exit=$?"; kept lbndl7
