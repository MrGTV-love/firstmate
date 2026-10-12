#!/usr/bin/env bash
# S3: an UNFINISHED record sharing a leased slot root (no PR, branch not landed)
# must not retire without --force: record and claim stay.
. /tmp/fm-live.UI8CJx/lib.sh
cd "$WT_ROOT" || exit 1
A=liveu-unfinished-a; B=liveu-parked-b
SLOT=$(new_slot) || { echo "no slot"; exit 1; }
SLOTDIR=$(dirname "$SLOT"); NAME=$(basename "$SLOTDIR")
th lease "$NAME" --lease-holder "$B" >/dev/null 2>&1
say "setup: leased slot $NAME; A's branch has an unpushed commit"
git -C "$SLOT" checkout -q -b "fm/$A"
echo "A unfinished" > "$SLOT/u.txt"; git -C "$SLOT" add u.txt; git -C "$SLOT" commit -qm "A unpushed work"
for t in "$A" "$B"; do
  write_meta "$t" "window=fmses:fm-$t" "endpoint_task_id=$t" "worktree=$SLOT" "project=$PROJ" "harness=claude" \
    "kind=ship" "mode=no-mistakes" "branch=fm/$t" "spawn_gen=s3.$t"
  write_brief "$t" "fm/$t"
done
printf 'task=%s\nhome=%s\n' "$A" "$LAB" > "$SLOTDIR/.fm-slot-owner"
cp "$LAB/state/$A.meta" "$W/s3-a.meta"; cp "$SLOTDIR/.fm-slot-owner" "$W/s3-claim"; fingerprint "$SLOT" > "$W/s3-slot.fp"
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?
printf '%s\n[exit %s]\n' "$out" "$rc"
check "refuses" [ "$rc" -ne 0 ]
check "names the delivery-proof boundary" grep -Fq "its own branch fm/$A is not proved landed" <<<"$out"
check "A record unchanged" cmp -s "$W/s3-a.meta" "$LAB/state/$A.meta"
check "A claim unchanged" cmp -s "$W/s3-claim" "$SLOTDIR/.fm-slot-owner"
check "slot bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$SLOT' | cmp -s - '$W/s3-slot.fp'"
check "unpushed commit still on branch" git -C "$PROJ" rev-parse --verify -q "fm/$A" >/dev/null
# Clear these fixtures so later scenarios see only their own records.
rm -f "$LAB/state/$A.meta" "$LAB/state/$B.meta"
say "S3 result: FAILS=$FAILS"
