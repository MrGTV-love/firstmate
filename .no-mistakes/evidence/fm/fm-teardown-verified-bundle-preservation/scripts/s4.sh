. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/common.sh
BASE="$FM_HOME/basecode"; base_teardown() { ( cd "$BASE" && bin/fm-teardown.sh "$@" </dev/null ); }
echo "######## S4a --force --drop-file with captain words: new code (lbndl5) vs base code (lbndl7)"
printf 'drop it - captain\n' > "$FM_HOME/drop-words.txt"
S5=$(sed -n 's/^worktree=//p' "$FM_HOME/state/lbndl5.meta"); S7=$(sed -n 's/^worktree=//p' "$FM_HOME/state/lbndl7.meta")
teardown lbndl5 --force --drop-file "$FM_HOME/drop-words.txt" 2>&1 | grep -v "^●\|WARNING: watcher"; echo "new exit=${PIPESTATUS[0]}"
[ -f "$FM_HOME/state/lbndl5.meta" ] && echo "meta present" || echo "meta removed"; echo "slot5 HEAD=$(git -C "$S5" rev-parse HEAD)"
base_teardown lbndl7 --force --drop-file "$FM_HOME/drop-words.txt" 2>&1 | grep -v "^●\|WARNING: watcher"; echo "base exit=${PIPESTATUS[0]}"
[ -f "$FM_HOME/state/lbndl7.meta" ] && echo "meta present" || echo "meta removed"; echo "slot7 HEAD=$(git -C "$S7" rev-parse HEAD)"
echo "origin/main=$(git -C "$PROJ" rev-parse origin/main)"
