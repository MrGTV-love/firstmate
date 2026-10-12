#!/usr/bin/env bash
# S1: two records name one real Treehouse slot root. Finished A holds the claim,
# parked B has unlanded work in a nested copy. Prove: unleased refusal names B,
# the printed lease command works, A retires records-only, B reassociates.
. /tmp/fm-live.UI8CJx/lib.sh
cd "$WT_ROOT" || exit 1
A=live-finished-a; B=live-parked-b
SLOT=$(new_slot) || { echo "no slot"; exit 1; }
SLOTDIR=$(dirname "$SLOT"); NAME=$(basename "$SLOTDIR")
say "setup: real Treehouse slot $NAME at $SLOT (unleased)"
th status 2>/dev/null | grep -E "^$NAME "
# Finished A: its branch lives in the slot root and is landed on origin/main.
git -C "$SLOT" checkout -q -b "fm/$A"
echo "A delivered" > "$SLOT/a.txt"; git -C "$SLOT" add a.txt; git -C "$SLOT" commit -qm "A delivered"
git -C "$SLOT" push -q origin "HEAD:main"
# Parked B: a nested copy with 3 unpushed commits, untracked files, a tracked edit.
NESTED="$SLOT/.claude/worktrees/$B"; mkdir -p "$SLOT/.claude/worktrees"
git -C "$PROJ" worktree add -q -b "fm/$B" "$NESTED"
for n in 1 2 3; do echo "unlanded $n" > "$NESTED/c$n.txt"; git -C "$NESTED" add "c$n.txt"; git -C "$NESTED" commit -qm "parked $n"; done
for n in 1 2 3 4 5; do echo "scratch $n" > "$NESTED/scratch-$n.txt"; done
echo "tracked unfinished edit" >> "$NESTED/c1.txt"
write_meta "$A" "window=fmses:fm-$A" "endpoint_task_id=$A" "worktree=$SLOT" "project=$PROJ" "harness=claude" \
  "kind=ship" "mode=no-mistakes" "branch=fm/$A" "spawn_gen=s1.1.1"
write_meta "$B" "window=fmses:fm-$B" "endpoint_task_id=$B" "worktree=$SLOT" "project=$PROJ" "harness=claude" \
  "kind=ship" "mode=no-mistakes" "branch=fm/$B" "spawn_gen=s1.1.2"
write_brief "$A" "fm/$A"; write_brief "$B" "fm/$B"
printf 'task=%s\nhome=%s\n' "$A" "$LAB" > "$SLOTDIR/.fm-slot-owner"
labtmux new-window -d -t fmses -n "fm-$A" -c "$SLOT"
labtmux new-window -d -t fmses -n "fm-$B" -c "$NESTED"
fingerprint "$SLOT" > "$W/s1-slot.fp"; fingerprint "$NESTED" > "$W/s1-nested.fp"; branches > "$W/s1-branches"
cp "$LAB/state/$B.meta" "$W/s1-b.meta"; cp "$LAB/state/$A.meta" "$W/s1-a.meta"; cp "$SLOTDIR/.fm-slot-owner" "$W/s1-claim"
echo "records:"; grep -H '^worktree=' "$LAB/state/$A.meta" "$LAB/state/$B.meta"
echo "claim:"; cat "$SLOTDIR/.fm-slot-owner"
echo "lab tmux windows:"; labtmux list-windows -t fmses -F '#W'

say "step 1: before the fix this deadlocked. Plain cleanup of finished A while the slot is unleased"
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?
printf '%s\n[exit %s]\n' "$out" "$rc"
check "unleased cleanup refuses" [ "$rc" -ne 0 ]
check "refusal names exact lease command with sole holder B" grep -Fq "treehouse lease '$NAME' --lease-holder '$B'" <<<"$out"
check "A record unchanged" cmp -s "$W/s1-a.meta" "$LAB/state/$A.meta"
check "A claim unchanged" cmp -s "$W/s1-claim" "$SLOTDIR/.fm-slot-owner"
check "A window still alive" bash -c "env -u TMUX TMUX_TMPDIR='$LAB/tmux' tmux list-windows -t fmses -F '#W' | grep -qx 'fm-$A'"

say "step 2: operator runs the printed state-only lease command (real treehouse)"
lease_cmd=$(grep -o "(cd '.*' && treehouse lease .*)" <<<"$out" | head -1)
echo "printed: $lease_cmd"
run th lease "$NAME" --lease-holder "$B"
th status 2>/dev/null | grep -E "^$NAME "
jq -c '.worktrees[] | {name,leased,lease_holder}' "$(dirname "$SLOTDIR")/treehouse-state.json"
check "lease did not change slot bytes" bash -c ". $W/lib.sh; fingerprint '$SLOT' | cmp -s - '$W/s1-slot.fp'"

say "step 3: plain cleanup of finished A (no --force)"
out=$(fm bin/fm-teardown.sh "$A" 2>&1); rc=$?
printf '%s\n[exit %s]\n' "$out" "$rc"
check "cleanup succeeds" [ "$rc" -eq 0 ]
check "A record retired" [ ! -e "$LAB/state/$A.meta" ]
check "A's own claim released" [ ! -e "$SLOTDIR/.fm-slot-owner" ]
check "B record byte-identical" cmp -s "$W/s1-b.meta" "$LAB/state/$B.meta"
check "slot root bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$SLOT' | cmp -s - '$W/s1-slot.fp'"
check "parked nested copy bytes unchanged" bash -c ". $W/lib.sh; fingerprint '$NESTED' | cmp -s - '$W/s1-nested.fp'"
check "branches unchanged" bash -c ". $W/lib.sh; branches | cmp -s - '$W/s1-branches'"
check "slot still leased to B" bash -c "jq -e '.worktrees[] | select(.name==\"$NAME\") | .leased==true and .lease_holder==\"$B\"' '$(dirname "$SLOTDIR")/treehouse-state.json' >/dev/null"
echo "lab tmux windows after:"; labtmux list-windows -t fmses -F '#W'
check "A window closed" bash -c "! env -u TMUX TMUX_TMPDIR='$LAB/tmux' tmux list-windows -t fmses -F '#W' | grep -qx 'fm-$A'"
check "B window still alive" bash -c "env -u TMUX TMUX_TMPDIR='$LAB/tmux' tmux list-windows -t fmses -F '#W' | grep -qx 'fm-$B'"

say "step 4: reassociate parked B to its real nested copy"
out=$(fm bin/fm-control.sh "$B" reassociate --worktree "$NESTED" --note 'Recover the actual task copy' 2>&1); rc=$?
printf '%s\n[exit %s]\n' "$out" "$rc"
check "reassociate succeeds" [ "$rc" -eq 0 ]
check "B record names nested copy" grep -Fxq "worktree=$NESTED" "$LAB/state/$B.meta"
check "slot claim now names B" grep -Fxq "task=$B" "$SLOTDIR/.fm-slot-owner"
check "parked nested copy bytes still unchanged" bash -c ". $W/lib.sh; fingerprint '$NESTED' | cmp -s - '$W/s1-nested.fp'"
check "slot root bytes still unchanged" bash -c ". $W/lib.sh; fingerprint '$SLOT' | cmp -s - '$W/s1-slot.fp'"
echo "B record now:"; cat "$LAB/state/$B.meta"
echo "$SLOT" > "$W/s1-slot-path"; echo "$NESTED" > "$W/s1-nested-path"
say "S1 result: FAILS=$FAILS"
