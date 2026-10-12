#!/usr/bin/env bash
# 5a (realistic): A and B both name the root, claim already names B, slot UNLEASED.
# B's parked work sits in a nested copy; the root is clean at a landed HEAD.
. /tmp/fm-live.UI8CJx/lib.sh
cd "$WT_ROOT" || exit 1
A=liver2-finished-a; B=liver2-claimant-b
SLOT=$(new_slot) || exit 1; SLOTDIR=$(dirname "$SLOT")
NESTED="$SLOT/.claude/worktrees/$B"; mkdir -p "$SLOT/.claude/worktrees"
git -C "$PROJ" worktree add -q -b "fm/$B" "$NESTED"
for n in 1 2; do echo "unlanded $n" > "$NESTED/c$n.txt"; git -C "$NESTED" add "c$n.txt"; git -C "$NESTED" commit -qm "parked $n"; done
echo scratch > "$NESTED/scratch.txt"; echo "tracked edit" >> "$NESTED/c1.txt"
for t in "$A" "$B"; do
  write_meta "$t" "window=fmses:fm-$t" "endpoint_task_id=$t" "worktree=$SLOT" "project=$PROJ" "harness=claude" \
    "kind=ship" "mode=no-mistakes" "branch=fm/$t" "spawn_gen=s5r.$t"
  write_brief "$t" "fm/$t"
done
printf 'task=%s\nhome=%s\n' "$B" "$LAB" > "$SLOTDIR/.fm-slot-owner"
cp "$LAB/state/$B.meta" "$W/s5r-b.meta"; cp "$SLOTDIR/.fm-slot-owner" "$W/s5r-claim"
fingerprint "$SLOT" > "$W/s5r-slot.fp"; fingerprint "$NESTED" > "$W/s5r-nested.fp"; branches > "$W/s5r-br"
cp "$(dirname "$SLOTDIR")/treehouse-state.json" "$W/s5r-th"
say "plain cleanup of A; claim names B; slot unleased"
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?
printf '%s\n[exit %s]\n' "$(grep -v -e '^●' <<<"$out")" "$rc"
check "succeeds without --force" [ "$rc" -eq 0 ]
check "no lease requested" bash -c "! grep -Fq 'treehouse lease' <<<\"\$1\"" _ "$out"
check "A record retired" [ ! -e "$LAB/state/$A.meta" ]
check "B record unchanged" cmp -s "$W/s5r-b.meta" "$LAB/state/$B.meta"
check "B claim unchanged" cmp -s "$W/s5r-claim" "$SLOTDIR/.fm-slot-owner"
check "slot root bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$SLOT' | cmp -s - '$W/s5r-slot.fp'"
check "B nested copy bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$NESTED' | cmp -s - '$W/s5r-nested.fp'"
check "branches unchanged" bash -c ". $W/lib.sh; branches | cmp -s - '$W/s5r-br'"
check "Treehouse state unchanged" cmp -s "$W/s5r-th" "$(dirname "$SLOTDIR")/treehouse-state.json"
say "B reassociates to its nested copy"
out=$(fm bin/fm-control.sh "$B" reassociate --worktree "$NESTED" --note 'Recover nested copy' 2>&1); rc=$?
printf '%s\n[exit %s]\n' "$out" "$rc"
check "reassociate succeeds" [ "$rc" -eq 0 ]
check "B nested bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$NESTED' | cmp -s - '$W/s5r-nested.fp'"
rm -f "$LAB/state/$B.meta"
say "S5a-realistic result: FAILS=$FAILS"
