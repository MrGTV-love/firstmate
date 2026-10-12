#!/usr/bin/env bash
# S4: finished A's record names its OWN nested copy inside a slot whose root a
# parked B still names. A's PR is really MERGED on GitHub (read-only gh query).
# The merged PR must not waive the ordinary dirty / landed proof on A's copy.
. /tmp/fm-live.UI8CJx/lib.sh
cd "$WT_ROOT" || exit 1
A=liven-nested-a; B=liven-parked-b
PR=https://github.com/MrGTV-love/firstmate/pull/109
SLOT=$(new_slot) || { echo "no slot"; exit 1; }
SLOTDIR=$(dirname "$SLOT"); NAME=$(basename "$SLOTDIR")
th lease "$NAME" --lease-holder "$B" >/dev/null 2>&1
say "setup: leased slot $NAME, parked B names root, A names nested copy; gh says $PR is $(gh pr view "$PR" --json state -q .state)"
COPY="$SLOT/.claude/worktrees/$A"; mkdir -p "$SLOT/.claude/worktrees"
git -C "$PROJ" fetch -q origin
git -C "$PROJ" worktree add -q -b "fm/$A" "$COPY" origin/main
echo "A landed" > "$COPY/n.txt"; git -C "$COPY" add n.txt; git -C "$COPY" commit -qm "A landed work"
git -C "$COPY" push -q origin HEAD:main
write_meta "$A" "window=fmses:fm-$A" "endpoint_task_id=$A" "worktree=$COPY" "project=$PROJ" "harness=claude" \
  "kind=ship" "mode=no-mistakes" "branch=fm/$A" "spawn_gen=s4.a" "pr=$PR"
write_meta "$B" "window=fmses:fm-$B" "endpoint_task_id=$B" "worktree=$SLOT" "project=$PROJ" "harness=claude" \
  "kind=ship" "mode=no-mistakes" "branch=fm/$B" "spawn_gen=s4.b"
write_brief "$A" "fm/$A"; write_brief "$B" "fm/$B"
printf 'task=%s\nhome=%s\n' "$A" "$LAB" > "$SLOTDIR/.fm-slot-owner"
cp "$LAB/state/$A.meta" "$W/s4-a.meta"; cp "$SLOTDIR/.fm-slot-owner" "$W/s4-claim"

say "4a: merged PR, but A's nested copy has a later LOCAL commit"
echo "late local" > "$COPY/late.txt"; git -C "$COPY" add late.txt; git -C "$COPY" commit -qm "late local commit"
fingerprint "$COPY" > "$W/s4a.fp"
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?; printf '%s\n[exit %s]\n' "$out" "$rc"
check "4a refuses" [ "$rc" -ne 0 ]
check "4a record unchanged" cmp -s "$W/s4-a.meta" "$LAB/state/$A.meta"
check "4a claim unchanged" cmp -s "$W/s4-claim" "$SLOTDIR/.fm-slot-owner"
check "4a copy bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$COPY' | cmp -s - '$W/s4a.fp'"
git -C "$COPY" reset -q --hard HEAD~1

say "4b: merged PR, landed HEAD, but a TRACKED edit in A's nested copy"
echo "tracked dirt" >> "$COPY/n.txt"
fingerprint "$COPY" > "$W/s4b.fp"
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?; printf '%s\n[exit %s]\n' "$out" "$rc"
check "4b refuses" [ "$rc" -ne 0 ]
check "4b refusal names the dirty file" grep -Fq "n.txt" <<<"$out"
check "4b record unchanged" cmp -s "$W/s4-a.meta" "$LAB/state/$A.meta"
check "4b claim unchanged" cmp -s "$W/s4-claim" "$SLOTDIR/.fm-slot-owner"
check "4b copy bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$COPY' | cmp -s - '$W/s4b.fp'"
git -C "$COPY" checkout -q -- n.txt

say "4c: clean and landed nested copy: records-only retirement, copy left in place"
fingerprint "$COPY" > "$W/s4c.fp"; fingerprint "$SLOT" > "$W/s4c-slot.fp"
cp "$LAB/state/$B.meta" "$W/s4-b.meta"
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?; printf '%s\n[exit %s]\n' "$out" "$rc"
check "4c succeeds" [ "$rc" -eq 0 ]
check "4c A record retired" [ ! -e "$LAB/state/$A.meta" ]
check "4c nested copy still present, bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$COPY' | cmp -s - '$W/s4c.fp'"
check "4c slot root bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$SLOT' | cmp -s - '$W/s4c-slot.fp'"
check "4c B record unchanged" cmp -s "$W/s4-b.meta" "$LAB/state/$B.meta"
check "4c slot still leased" bash -c "jq -e '.worktrees[] | select(.name==\"$NAME\") | .leased==true' '$(dirname "$SLOTDIR")/treehouse-state.json' >/dev/null"
rm -f "$LAB/state/$B.meta"
say "S4 result: FAILS=$FAILS"
