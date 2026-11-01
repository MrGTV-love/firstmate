. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/common.sh
f() { grep -v "^●\|WARNING: watcher"; }
echo "######## S9 control: a landed task (lbndl11, commit pushed to origin) closes normally"
make_task lbndl11 || exit 1; git -C "$SLOT" push -q origin HEAD:main; git -C "$PROJ" fetch -q origin
teardown lbndl11 2>&1 | f | tail -3; echo "exit=${PIPESTATUS[0]}"
echo "######## captain answers the bundle-kept row lbndl1 (drop)"
printf 'drop lbndl1 commits\n' > "$FM_HOME/answer-lbndl1.txt"
"$WT/bin/fm-captain-hold.sh" answer lbndl1 --decision-file "$FM_HOME/answer-lbndl1.txt" </dev/null; echo "answer exit=$?"
for t in lbndl1 lbndl3 lbndl11; do printf '%s: ' $t; tasks-axi show $t --file "$FM_HOME/data/backlog.md" | grep -E "^  (state|hold_kind|closed):" | tr -d '\n'; echo; done
echo "######## bearings snapshot landed list"
( cd "$WT" && bin/fm-bearings-snapshot.sh --json --all-landed </dev/null 2>/dev/null ) > "$EVID/transcripts/s9-bearings.json"; echo "snapshot exit=$?"
jq -c '.landed // .sections.landed // empty' "$EVID/transcripts/s9-bearings.json" 2>/dev/null | head -5
jq -r 'paths(scalars) as $p | select(($p|map(tostring)|join("."))|test("landed")) | ($p|map(tostring)|join("."))+"="+(getpath($p)|tostring)' "$EVID/transcripts/s9-bearings.json" 2>/dev/null | head -20
