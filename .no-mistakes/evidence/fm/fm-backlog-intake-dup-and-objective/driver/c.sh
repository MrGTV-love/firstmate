. ~/tmp/fm-drv/lib.sh
st() { run bin/fm-tasks-axi.sh show "$1" | grep -E '^\$|state:|exit'; }
say "C0 setup: a kept item and its duplicate (filed with --not-dup)"
fm add dc-keep "Scrub galley copper pots" --objective O7 --body "kept body line" >/dev/null
fm add dc-dup "Scrub galley copper pots and pans" --objective O7 --body "use lemon and salt" --not-dup dc-keep >/dev/null
run grep -A3 '^- \[ \] dc-' $B
say "C1 done --duplicate-of closes the duplicate on checked proof, no owner words"
fm done dc-dup --duplicate-of dc-keep
fm show dc-keep --full
run grep -c 'fm-add:' <(cd $W && bin/fm-tasks-axi.sh show dc-keep --full)
run grep -n 'dc-dup' $B
run grep 'dc-dup' $LAB/state/fleet-ledger.jsonl
say "C2 refused: the item is already closed"
fm done dc-dup --duplicate-of dc-keep
say "C3 refused: an owner-filed item (Captain 2027-01-06 asked, no colon)"
fm add own-1 "Paint the bilge pump housing" --objective O7 --body "Captain 2027-01-06 asked to keep this blue" >/dev/null
fm done own-1 --duplicate-of dc-keep; st own-1
say "C4 refused: an owner-filed item (Owner: in the body)"
fm add own-2 "Coil the spare halyard ropes" --objective O7 --body "Owner: wants these coiled clockwise" >/dev/null
fm done own-2 --duplicate-of dc-keep; st own-2
say "C5 refused: an open owner call (a real captain hold)"
fm add oc-1 "Choose the dinghy sail colour" --objective O7 >/dev/null
run bin/fm-captain-hold.sh hold oc-1 --reason "which colour does the owner want" --boundary dinghy-colour --if-no "keep white"
fm done oc-1 --duplicate-of dc-keep; st oc-1
say "C6 refused: an item with a live task record (state/<id>.meta)"
fm add lt-1 "Grease the rudder pintle pins" --objective O7 --kind ship >/dev/null
run touch $LAB/state/lt-1.meta
fm done lt-1 --duplicate-of dc-keep; st lt-1
run rm $LAB/state/lt-1.meta
say "C7 refused: the kept item is closed"
fm add ck-1 "Wax the deck hatch hinges" --objective O7 >/dev/null
fm done ck-1 >/dev/null
fm add ck-2 "Clean the porthole brass rims" --objective O7 >/dev/null
fm done ck-2 --duplicate-of ck-1; st ck-2
say "C8 refused: the kept item does not exist"
fm done ck-2 --duplicate-of no-such-item; st ck-2
say "C9 refused: the item names itself as the kept item"
fm done ck-2 --duplicate-of ck-2; st ck-2
say "C10 refused: the item still blocks open work"
fm add bl-1 "Restitch the mainsail luff tape" --objective O7 >/dev/null
fm add bl-2 "Hoist the repaired mainsail aloft" --objective O7 >/dev/null
fm block bl-2 --by bl-1 >/dev/null
fm done bl-1 --duplicate-of dc-keep; st bl-1
say "C11 refused: --duplicate-of combined with --pr, --report, --drop-file or --note"
fm done ck-2 --duplicate-of dc-keep --pr https://github.com/o/r/pull/1
fm done ck-2 --duplicate-of dc-keep --note dup
st ck-2
