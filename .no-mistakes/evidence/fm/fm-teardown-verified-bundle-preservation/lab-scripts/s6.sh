echo "=== S6: the bundle-kept row stays held for the captain; answering it is not a landing ==="
echo "--- t-s1 row after its bundle teardown (state / held / hold_kind / closed / links) ---"
tasks-axi show t-s1 --file "$FM_HOME/data/backlog.md" | grep -E '^  (state|held|hold_kind|closed|links):'
echo "--- the pending-close deliverable recorded for the row ---"
grep -rn "preserved in bundle" "$FM_HOME/data/backlog.md" "$FM_HOME/state" 2>/dev/null | cut -c1-260 | head -5
echo "--- Recently Landed BEFORE the captain answers (bearings --json --all-landed) ---"
"$WT/bin/fm-bearings-snapshot.sh" --json --all-landed 2>/dev/null | jq -c '[.landed[]? | {id, artifact}]'
echo "--- captain answers t-s1: drop the commits ---"
echo 'Drop the unlanded commits of t-s1.' > "$SCR/t-s1.decision"
show "$WT/bin/fm-captain-hold.sh" answer t-s1 --decision-file "$SCR/t-s1.decision"
tasks-axi show t-s1 --file "$FM_HOME/data/backlog.md" | grep -E '^  (state|held|hold_kind|closed|links):'
echo "--- fleet snapshot record for t-s1 (captain_drop) ---"
"$WT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null | jq -c '.backlog.records[]? | select(.id=="t-s1") | {id,state,captain_drop}'
echo "--- Recently Landed AFTER the answer ---"
"$WT/bin/fm-bearings-snapshot.sh" --json --all-landed 2>/dev/null | jq -c '[.landed[]? | {id, artifact}]'
echo "--- control: a really landed task (t-s4e-new-0, merged into main) for comparison ---"
tasks-axi show t-s4e-new-0 --file "$FM_HOME/data/backlog.md" | grep -E '^  (state|links):'
