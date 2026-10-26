#!/usr/bin/env bash
# S6n (fixed rebase) and S8b (nested independent clone) re-driven in the run-4 lab.
set -u
. "$(dirname "$0")/live-lab.sh"
export TMUX_TMPDIR; TMUX_TMPDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export FM_MERGE_PRUNE_TEARDOWN_BIN="$LAB/bin/teardown-logged"
REAL_TH=$(sed -n 's/^exec "\(.*\)" "\$@"$/\1/p' "$LAB/bin/treehouse")
td() { awk -v id="$1" '/^=== teardown/{on=($3==id)} on' "$LAB/teardown-calls.log" | grep -E '^(===|REFUSED|error|teardown |unpushed|commits)' | head -10; }
slot_line() { (cd "$PROJ" && "$REAL_TH" status 2>/dev/null) | grep -F -- "$1" || echo "(slot not listed)"; }

echo "===== S6n: natural squash false positive: the pipeline rebased the branch onto a moved main (copy HEAD only on the gate remote)"
new_task t6r 41; C=$COPY
[ -d "$LAB/remote/gate.git" ] || git init -q --bare "$LAB/remote/gate.git"
git -C "$C" remote add no-mistakes "$LAB/remote/gate.git"; git -C "$C" push -q no-mistakes "fm/t6r" 2>/dev/null
rm -rf "$LAB/pl"; git clone -q "$ORIGIN" "$LAB/pl" 2>/dev/null
git -C "$LAB/pl" checkout -q main; git -C "$LAB/pl" reset -q --hard HEAD~1
printf 'other %s\n' "$RANDOM" > "$LAB/pl/other-t6r.txt"; git -C "$LAB/pl" add -A; git -C "$LAB/pl" commit -q -m "another PR"
git -C "$LAB/pl" cherry-pick "$(git -C "$C" rev-parse HEAD)" >/dev/null || echo "cherry-pick failed"
RB=$(git -C "$LAB/pl" rev-parse HEAD)
git -C "$LAB/pl" push -q -f origin "$RB:refs/heads/fm/t6r" 2>/dev/null
SQ=$(git -C "$LAB/pl" commit-tree "$RB^{tree}" -p "$RB~1" -m "t6r (#41)"); git -C "$LAB/pl" push -q -f origin "$SQ:refs/heads/main" 2>/dev/null
rm -rf "$LAB/pl"; git -C "$C" fetch -q --prune origin
printf '%s\n' "$RB" > "$LAB/gh/41.head"; sed -i.bak "s/^pr_head=.*/pr_head=$RB/" "$STATE/t6r.meta"
echo "copy HEAD $(git -C "$C" rev-parse --short HEAD) is ancestor of PR head $(git -C "$C" rev-parse --short "$RB"): $(git -C "$C" merge-base --is-ancestor HEAD "$RB" && echo yes || echo no); main carries t6r.txt: $(git -C "$C" cat-file -e origin/main:t6r.txt 2>/dev/null && echo yes || echo no)"
mkdir -p "$C/node_modules/x"; printf 'x\n' > "$C/node_modules/x/i.js"
prune arm t6r >/dev/null 2>&1
FM_MERGE_PRUNE_EXIT_WAIT=5 prune run t6r --now >/dev/null 2>&1
show t6r; echo "real teardown said:"; td t6r; echo "copy dir exists: $([ -e "$C" ] && echo yes || echo no); slot: $(slot_line "$C")"

echo "===== S8b: an unpushed commit in a NESTED independent clone (.claude/worktrees/n2, its own .git) under a squash-merged copy"
new_task t8b 42; C=$COPY
git clone -q "$ORIGIN" "$C/.claude/worktrees/n2" 2>/dev/null
printf 'o\n' > "$C/.claude/worktrees/n2/o.txt"; git -C "$C/.claude/worktrees/n2" add o.txt; git -C "$C/.claude/worktrees/n2" commit -q -m "unpushed in nested clone"
prune arm t8b >/dev/null 2>&1
prune run t8b --now >/dev/null 2>&1; prune run t8b --now >/dev/null 2>&1
show t8b; echo "real teardown said:"; td t8b
echo "slot: $(slot_line "$C")"
echo "nested unpushed commit still on disk: $(git -C "$C/.claude/worktrees/n2" log --oneline HEAD --not --remotes 2>&1)"
echo "--- a new task's 'treehouse get' now:"
new_task t8next 43
echo "t8next got: $COPY"
echo "t8next's copy holds t8b's nested clone with the unpushed commit: $([ -d "$COPY/.claude/worktrees/n2" ] && git -C "$COPY/.claude/worktrees/n2" log --oneline HEAD --not --remotes || echo no)"
