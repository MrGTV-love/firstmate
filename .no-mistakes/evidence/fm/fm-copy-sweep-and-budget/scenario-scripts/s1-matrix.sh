#!/usr/bin/env bash
# Scenario 1-4: class matrix, report changes nothing, --apply removes only proven copies, never forces.
set -u
. /Users/charlesabrooker/tmp/fm-sweep-live-scripts/common.sh
LAB=$1
new_world "$LAB"
make_slot vernant 1
S=$SLOT
W=$S/.claude/worktrees
# REAPABLE (clean, pushed)
add_copy "$S" reap 2
# landed: commit never pushed to a branch, but its content is already in main (pushed)
git -C "$S" worktree add -q -b fm/landed "$W/landed"
printf 'landed\n' > "$W/landed/landed.txt"; git -C "$W/landed" add landed.txt; git -C "$W/landed" commit -qm landed
printf 'landed\n' > "$S/landed.txt"; git -C "$S" add landed.txt; git -C "$S" commit -qm "land landed"; git -C "$S" push -q origin main
# dirty: untracked file
add_copy "$S" dirty 1; echo scratch > "$W/dirty/untracked.txt"
# unpushed: commit on no remote and not in default
add_copy "$S" unpushed 1; echo x > "$W/unpushed/local.txt"; git -C "$W/unpushed" add local.txt; git -C "$W/unpushed" commit -qm local-only
# live: active task record names it
add_copy "$S" live 1; printf 'worktree=%s\nkind=ship\n' "$W/live" > "$LAB/state/live-task.meta"
# locked: Vernant creation lock
add_copy "$S" locked 1; git -C "$S" worktree lock --reason 'vernant-session-active owner=launcher:999999 launcher=999999' "$W/locked"
# orphan: .git garbage
add_copy "$S" orphan 1; printf 'garbage\n' > "$W/orphan/.git"
# process inside: a real process whose cwd is inside the copy
add_copy "$S" proc 1; ( cd "$W/proc" && exec sleep 600 ) & PROCPID=$!
# ignored file that exists nowhere else (.env) => must be held
add_copy "$S" envfile 1
printf '.env\nlocal-data/\nnode_modules/\n' > "$W/envfile/.gitignore"; git -C "$W/envfile" add .gitignore; git -C "$W/envfile" commit -qm ignore; git -C "$W/envfile" push -q origin fm/envfile
echo SECRET=1 > "$W/envfile/.env"
# ignored but allow-listed derived output (node_modules) => reaped
add_copy "$S" nm 1
printf 'node_modules/\n' > "$W/nm/.gitignore"; git -C "$W/nm" add .gitignore; git -C "$W/nm" commit -qm ignore; git -C "$W/nm" push -q origin fm/nm
mkdir -p "$W/nm/node_modules/x"; echo js > "$W/nm/node_modules/x/i.js"
# outer copy that holds a registered, existing inner copy
add_copy "$S" outer 1
git -C "$W/outer" ls-files >/dev/null
printf '.claude/worktrees/\n' > "$W/outer/.gitignore"; git -C "$W/outer" add .gitignore; git -C "$W/outer" commit -qm ignore-wt; git -C "$W/outer" push -q origin fm/outer
git -C "$S" worktree add -q -b fm/inner "$W/outer/.claude/worktrees/inner"
sleep 1
echo "=== world ready; proc pid $PROCPID ==="
git -C "$S" worktree list
for n in reap landed dirty unpushed live locked orphan envfile nm outer; do snap "$W/$n" > "$LAB/snap-$n-before" 2>/dev/null; done
snap "$W/outer/.claude/worktrees/inner" > "$LAB/snap-inner-before"
echo
echo "##### REPORT MODE (no flag) #####"
sweep "$WT/bin/fm-copy-sweep.sh"; echo "exit=$?"
for n in reap landed dirty unpushed live locked orphan envfile nm outer; do snap "$W/$n" > "$LAB/snap-$n-after-report" 2>/dev/null; cmp -s "$LAB/snap-$n-before" "$LAB/snap-$n-after-report" && echo "report left $n byte-identical" || echo "REPORT CHANGED $n"; done
ls "$LAB/state" "$LAB/data"
echo
echo "##### APPLY #####"
GIT_TRACE="$LAB/git-trace.log" sweep "$WT/bin/fm-copy-sweep.sh" --apply; echo "exit=$?"
echo
echo "=== survivors / removed ==="
for n in reap landed dirty unpushed live locked orphan proc envfile nm outer; do [ -d "$W/$n" ] && echo "KEPT    $n" || echo "REMOVED $n"; done
[ -d "$W/outer/.claude/worktrees/inner" ] && echo "KEPT    inner" || echo "REMOVED inner"
for n in dirty unpushed live locked orphan envfile outer; do snap "$W/$n" > "$LAB/snap-$n-after" 2>/dev/null; cmp -s "$LAB/snap-$n-before" "$LAB/snap-$n-after" && echo "held copy $n byte-identical" || echo "HELD COPY CHANGED $n"; done
echo "env file content: $(cat "$W/envfile/.env" 2>&1)"
echo "=== removal log ==="; cat "$LAB/data/copy-sweep.log"
echo "=== git worktree remove calls in GIT_TRACE (force check) ==="
grep -E 'worktree (remove|unlock|prune)|--force| -f ' "$LAB/git-trace.log" | grep -v 'trace: exec' | sed 's/^[0-9:.]* //' | sort | uniq -c
echo "=== any forced/unlock/clean/prune? ==="
if grep -E 'worktree remove (-f|--force)|worktree unlock|git clean|worktree prune|rm -rf' "$LAB/git-trace.log" >/dev/null; then echo "YES (bad)"; else echo "none"; fi
echo
echo "##### APPLY AGAIN (idempotence; outer should now be reapable after inner... inner is held-dirty? ) #####"
sweep "$WT/bin/fm-copy-sweep.sh" --apply; echo "exit=$?"
kill "$PROCPID" 2>/dev/null
