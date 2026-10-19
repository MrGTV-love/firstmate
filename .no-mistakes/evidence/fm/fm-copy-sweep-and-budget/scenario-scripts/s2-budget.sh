#!/usr/bin/env bash
# Budget wake: one wake naming budget, total, five largest + class; none while still over; again after drop-under and re-cross.
set -u
. /Users/charlesabrooker/tmp/fm-sweep-live-scripts/common.sh
LAB=$1
new_world "$LAB"
make_slot vernant 1
S=$SLOT; W=$S/.claude/worktrees
printf 'pool vernant 0.004\ninterval 0\n' > "$LAB/config/copy-budget"
add_copy "$S" big1 3
add_copy "$S" big2 2
add_copy "$S" big3 1
add_copy "$S" big4 1
add_copy "$S" big5 1
add_copy "$S" small1 0
add_copy "$S" small2 0
echo scratch > "$W/big2/untracked.txt"   # makes big2 HELD-DIRTY so its class label differs
echo "=== config ==="; cat "$LAB/config/copy-budget"
echo
echo "##### check #1 (budget crossed): expect exactly ONE wake line #####"
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/c1.out" 2>&1; echo "exit=$?"; cat "$LAB/c1.out"; echo "wake lines: $(grep -c '^copy-sweep:' "$LAB/c1.out")"
echo "record:"; cat "$LAB/state/copy-sweep.record"
echo
echo "##### check #2 (still over): expect NO wake #####"
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/c2.out" 2>&1; echo "exit=$?"; echo "output bytes: $(wc -c < "$LAB/c2.out")"; cat "$LAB/c2.out"
echo
echo "##### check #3 (still over): expect NO wake #####"
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/c3.out" 2>&1; echo "exit=$?"; echo "output bytes: $(wc -c < "$LAB/c3.out")"
echo
echo "##### drop under budget (test fixture removes the big copies by hand) #####"
for n in big1 big2 big3 big4 big5; do git -C "$S" worktree remove --force "$W/$n"; done
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/c4.out" 2>&1; echo "exit=$?"; echo "output bytes: $(wc -c < "$LAB/c4.out") (expect 0)"; echo "record:"; cat "$LAB/state/copy-sweep.record"
echo
echo "##### cross again: expect a NEW wake #####"
add_copy "$S" big6 3; add_copy "$S" big7 2
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/c5.out" 2>&1; echo "exit=$?"; cat "$LAB/c5.out"; echo "wake lines: $(grep -c '^copy-sweep:' "$LAB/c5.out")"
echo
echo "##### check never removes: all copies still registered #####"
git -C "$S" worktree list | wc -l
echo
echo "##### report mode shows budget lines #####"
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" | grep -E '^budget|^summary'
