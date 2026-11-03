#!/usr/bin/env bash
# Live drive of bin/fm-tasks-axi.sh intake and closing proofs against a disposable lab home.
# Usage: drive-intake.sh <worktree> <lab-home> <peer-home>
set -u
WT=$1; export FM_HOME=$2; PEER=$3
cd "$WT"
W=bin/fm-tasks-axi.sh
run() { echo; echo "\$ $*"; "$@"; echo "[exit=$?]"; }
step() { echo; echo "=================== $* ==================="; }
B=$FM_HOME/data/backlog.md

step "S1 objective required"
run $W add lock-a "Lock holder crash"
run $W add lock-a "Lock holder crash" --objective O9
run $W add lock-a "Lock holder crash" --objective none
run $W add lock-a "Lock holder crash" --objective O7
run $W add misc-a "Unrelated widget polish" --objective none --objective-reason "housekeeping, no objective applies"
echo "--- data/backlog-review.tsv:"; cat -A "$FM_HOME/data/backlog-review.tsv" 2>/dev/null || cat "$FM_HOME/data/backlog-review.tsv"

step "S2 duplicate check: documented worked pairs"
run $W add lock-b "Lock holder crash recovery" --objective O7
run $W add lock-c "Lock timeout" --objective O7
run $W add lock-d "Lock timeout retry loop" --objective O7
echo "--- lock-b/lock-c must be absent, lock-d present:"; grep -E 'lock-(b|c|d)' "$B" || true

step "S3 --not-dup override files the item"
run $W add lock-c "Lock timeout" --objective O7 --not-dup lock-a
run $W add lock-e "Lock holder crash again" --objective O7 --not-dup misc-a
run $W add lock-e "Lock holder crash again" --objective O7 --not-dup lock-e
grep -E 'lock-(c|e)' "$B" || true

step "S4 --dup-of appends to kept item and files nothing"
run $W add lock-f "Lock holder crash recovery" --body "seen again on host b" --objective O7 --dup-of lock-a
run $W add lock-f "Lock holder crash recovery" --objective O7 --dup-of lock-f
grep -c 'lock-f' "$B"; echo "--- kept item lock-a:"; tasks-axi show lock-a --file "$B" 2>&1 | head -30

step "S5 done --duplicate-of closes on checked proof"
run $W add dup-x "Rotate signing keyring quarterly" --objective O5
run $W add dup-y "Rotate signing keyring" --objective O5 --not-dup dup-x
run $W done dup-y --duplicate-of dup-y
run $W done dup-y --duplicate-of nope-zz
run $W done dup-y --duplicate-of dup-x --note "extra"
run $W done dup-y --duplicate-of dup-x
echo "--- dup-y row and dup-x body:"; grep -n 'dup-y' "$B"; tasks-axi show dup-x --file "$B" 2>&1 | head -30

step "S6 guards: closed kept item, owner-filed item, item that blocks open work"
run $W done misc-a --duplicate-of dup-y
run $W add own-a "Owner widget quota" --body "Captain's words, 2026-10-20 (via /kun): 'keep this one'." --objective O7
run $W add own-b "Owner widget quota limit" --objective O7 --not-dup own-a
run $W done own-a --duplicate-of own-b
run $W add blk-a "Blocker cache warming" --objective O6
run $W add blk-b "Dependent cache shard rollout" --objective O6
tasks-axi block blk-b --by blk-a --file "$B" >/dev/null 2>&1; grep -n 'blk-b' "$B"
run $W add blk-k "Blocker cache warming kept" --objective O6 --not-dup blk-a
run $W done blk-a --duplicate-of blk-k

step "S7 done --moved-to closes on a registered home"
printf -- '- sm-peer - A peer home (home: %s; scope: lab; projects: p; added 2026-11-02)\n' "$PEER" > "$FM_HOME/data/secondmates.md"
(FM_HOME=$PEER $W add peer-open "Moved over lighthouse importer" --objective O3 >/dev/null 2>&1)
(FM_HOME=$PEER $W add peer-gone "Finished peer zebra item" --objective O3 >/dev/null 2>&1; FM_HOME=$PEER tasks-axi done peer-gone --file "$PEER/data/backlog.md" >/dev/null 2>&1)
run $W add mv-a "Lighthouse importer cleanup" --objective O3
run $W done mv-a --moved-to sm-nowhere peer-open
run $W done mv-a --moved-to sm-peer peer-absent
run $W done mv-a --moved-to sm-peer peer-gone
run $W done mv-a --moved-to sm-peer
run $W done mv-a --moved-to sm-peer peer-open
grep -n 'mv-a' "$B"

step "S8 Done window: overlap with a recently closed item is refused"
run $W add lock-g "Lighthouse importer cleanup followup" --objective O3

step "S9 ship row still needs a deliverable without a proof"
run $W add ship-a "Quartz palette exporter" --objective O2 --kind ship
run $W done ship-a

step "guard events"
tail -n 8 "$FM_HOME/state/guard-events.jsonl" 2>/dev/null
step "final backlog"; cat "$B"
