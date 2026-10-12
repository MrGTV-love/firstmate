#!/usr/bin/env bash
# S5: reassigned slots keep base behaviour and need no lease.
#  5a: A and B both name the root, the claim already names B, slot UNLEASED:
#      plain cleanup retires A records-only; B and its claim untouched.
#  5b: stale ship A, no PR, its branch pruned, claim names another task Z with
#      no record here: base reassigned-slot cleanup retires A records-only.
. /tmp/fm-live.UI8CJx/lib.sh
cd "$WT_ROOT" || exit 1
say "5a: both records, claim=B, slot unleased"
A=liver-finished-a; B=liver-claimant-b
SLOT=$(new_slot) || { echo "no slot"; exit 1; }
SLOTDIR=$(dirname "$SLOT")
git -C "$SLOT" checkout -q -b "fm/$B"
echo "B work" > "$SLOT/b.txt"; git -C "$SLOT" add b.txt; git -C "$SLOT" commit -qm "B unpushed work"
echo "B scratch" > "$SLOT/scratch.txt"
for t in "$A" "$B"; do
  write_meta "$t" "window=fmses:fm-$t" "endpoint_task_id=$t" "worktree=$SLOT" "project=$PROJ" "harness=claude" \
    "kind=ship" "mode=no-mistakes" "branch=fm/$t" "spawn_gen=s5.$t"
  write_brief "$t" "fm/$t"
done
printf 'task=%s\nhome=%s\n' "$B" "$LAB" > "$SLOTDIR/.fm-slot-owner"
cp "$LAB/state/$B.meta" "$W/s5-b.meta"; cp "$SLOTDIR/.fm-slot-owner" "$W/s5-claim"; fingerprint "$SLOT" > "$W/s5-slot.fp"
cp "$(dirname "$SLOTDIR")/treehouse-state.json" "$W/s5-th"
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?; printf '%s\n[exit %s]\n' "$out" "$rc"
check "5a succeeds without --force and without a lease" [ "$rc" -eq 0 ]
check "5a A record retired" [ ! -e "$LAB/state/$A.meta" ]
check "5a B record unchanged" cmp -s "$W/s5-b.meta" "$LAB/state/$B.meta"
check "5a B claim unchanged" cmp -s "$W/s5-claim" "$SLOTDIR/.fm-slot-owner"
check "5a slot bytes (B's unpushed commit + scratch) unchanged" bash -c ". $W/lib.sh; fingerprint '$SLOT' | cmp -s - '$W/s5-slot.fp'"
check "5a no lease added" cmp -s "$W/s5-th" "$(dirname "$SLOTDIR")/treehouse-state.json"
rm -f "$LAB/state/$B.meta"

say "5b: stale ship, no PR, branch pruned, claim names another task with no record"
A=lives-stale-a
SLOT=$(new_slot) || { echo "no slot"; exit 1; }
SLOTDIR=$(dirname "$SLOT")
write_meta "$A" "window=fmses:fm-$A" "endpoint_task_id=$A" "worktree=$SLOT" "project=$PROJ" "harness=claude" \
  "kind=ship" "mode=no-mistakes" "branch=fm/$A" "spawn_gen=s5.stale"
write_brief "$A" "fm/$A"
check "5b branch is pruned (absent)" bash -c "! git -C '$PROJ' rev-parse --verify -q 'refs/heads/fm/$A' >/dev/null"
printf 'task=%s\nhome=%s\n' "lives-other-z" "$LAB" > "$SLOTDIR/.fm-slot-owner"
cp "$SLOTDIR/.fm-slot-owner" "$W/s5b-claim"; fingerprint "$SLOT" > "$W/s5b-slot.fp"
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?; printf '%s\n[exit %s]\n' "$out" "$rc"
check "5b succeeds" [ "$rc" -eq 0 ]
check "5b A record retired" [ ! -e "$LAB/state/$A.meta" ]
check "5b other task's claim unchanged" cmp -s "$W/s5b-claim" "$SLOTDIR/.fm-slot-owner"
check "5b slot bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$SLOT' | cmp -s - '$W/s5b-slot.fp'"
say "S5 result: FAILS=$FAILS"
