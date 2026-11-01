. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/common.sh
BASE="$FM_HOME/basecode"; base_teardown() { ( cd "$BASE" && bin/fm-teardown.sh "$@" </dev/null ); }
f() { grep -v "^●\|WARNING: watcher"; }
echo "######## S4b --force --drop-file on a captain-held task, no bundle: new (lbndl9) vs base (lbndl10)"
for pair in "lbndl9 new" "lbndl10 base"; do set -- $pair
  make_task $1 || exit 1
  "$WT/bin/fm-captain-hold.sh" hold $1 --owner captain --reason "Land or drop $1?" </dev/null >/dev/null
  if [ $2 = new ]; then teardown $1 --force --drop-file "$FM_HOME/drop-words.txt" 2>&1 | f; else base_teardown $1 --force --drop-file "$FM_HOME/drop-words.txt" 2>&1 | f; fi
  echo "$2 exit=${PIPESTATUS[0]}"; [ -f "$FM_HOME/state/$1.meta" ] && echo "meta present" || echo "meta removed"
  tasks-axi show $1 --file "$FM_HOME/data/backlog.md" | grep -E "state:|held:|body:"
done
