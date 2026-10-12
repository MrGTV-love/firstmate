#!/usr/bin/env bash
# S2: three root records (finished A, finished C, live B), A holds the claim,
# slot unleased. The refusal must not guess a holder: it lists every candidate
# with its last recorded status line and leaves the choice to the operator.
. /tmp/fm-live.UI8CJx/lib.sh
cd "$WT_ROOT" || exit 1
A=live3-finished-a; B=live3-working-b; C=live3-finished-c
SLOT=$(new_slot) || { echo "no slot"; exit 1; }
SLOTDIR=$(dirname "$SLOT"); NAME=$(basename "$SLOTDIR")
say "setup: real Treehouse slot $NAME at $SLOT (unleased), three root records"
git -C "$SLOT" checkout -q -b "fm/$A"
echo "A delivered" > "$SLOT/a3.txt"; git -C "$SLOT" add a3.txt; git -C "$SLOT" commit -qm "A3 delivered"
git -C "$SLOT" push -q origin "HEAD:main"
for t in "$A" "$B" "$C"; do
  write_meta "$t" "window=fmses:fm-$t" "endpoint_task_id=$t" "worktree=$SLOT" "project=$PROJ" "harness=claude" \
    "kind=ship" "mode=no-mistakes" "branch=fm/$t" "spawn_gen=s2.$t"
  write_brief "$t" "fm/$t"
done
printf '2026-10-11T09:00:00Z done: PR merged, finished\n' > "$LAB/state/$C.status"
printf '2026-10-12T10:00:00Z working: parked unpushed work in nested copy\n' > "$LAB/state/$B.status"
printf 'task=%s\nhome=%s\n' "$A" "$LAB" > "$SLOTDIR/.fm-slot-owner"
cp "$LAB/state/$A.meta" "$W/s2-a.meta"; cp "$SLOTDIR/.fm-slot-owner" "$W/s2-claim"; fingerprint "$SLOT" > "$W/s2-slot.fp"
cp "$(dirname "$SLOTDIR")/treehouse-state.json" "$W/s2-th-state"

say "cleanup of finished A with two other root records and no lease"
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?
printf '%s\n[exit %s]\n' "$out" "$rc"
check "refuses" [ "$rc" -ne 0 ]
check "names no single holder (placeholder)" grep -Fq "treehouse lease '$NAME' --lease-holder <remaining-task>" <<<"$out"
check "does not name B as holder" bash -c "! grep -Fq -- \"--lease-holder '$B'\" <<<\"\$1\"" _ "$out"
check "does not name C as holder" bash -c "! grep -Fq -- \"--lease-holder '$C'\" <<<\"\$1\"" _ "$out"
check "tells operator to select the live one" grep -Fq "select the live one" <<<"$out"
check "lists B with its recorded status" grep -Fq "  $B: 2026-10-12T10:00:00Z working: parked unpushed work in nested copy" <<<"$out"
check "lists C with its recorded status" grep -Fq "  $C: 2026-10-11T09:00:00Z done: PR merged, finished" <<<"$out"
check "A record unchanged" cmp -s "$W/s2-a.meta" "$LAB/state/$A.meta"
check "A claim unchanged" cmp -s "$W/s2-claim" "$SLOTDIR/.fm-slot-owner"
check "slot bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$SLOT' | cmp -s - '$W/s2-slot.fp'"
check "Treehouse state unchanged" cmp -s "$W/s2-th-state" "$(dirname "$SLOTDIR")/treehouse-state.json"

say "operator selects live B, leases, then retires A and C without --force"
run th lease "$NAME" --lease-holder "$B" >/dev/null 2>&1
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?; printf '%s\n[exit %s]\n' "$out" "$rc"
check "A retires after lease" bash -c "[ $rc -eq 0 ] && [ ! -e '$LAB/state/$A.meta' ]"
git -C "$PROJ" branch -q "fm/$C" main   # C's own branch is landed on main
out=$(fm bin/fm-teardown.sh "$C" 2>&1); rc=$?; printf '%s\n[exit %s]\n' "$out" "$rc"
check "C retires records-only" bash -c "[ $rc -eq 0 ] && [ ! -e '$LAB/state/$C.meta' ]"
check "B record survives" [ -e "$LAB/state/$B.meta" ]
check "slot bytes unchanged after both retirements" bash -c ". $W/lib.sh; fingerprint '$SLOT' | cmp -s - '$W/s2-slot.fp'"
echo "$SLOT" > "$W/s2-slot-path"
say "S2 result: FAILS=$FAILS"
