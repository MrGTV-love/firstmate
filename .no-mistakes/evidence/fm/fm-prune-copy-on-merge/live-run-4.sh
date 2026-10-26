#!/usr/bin/env bash
# Live scenarios: nested linked worktree, and the provable-scratch fallback with
# the REAL treehouse destroy, real tmux pane (its `treehouse get` subshell is the
# idle shell the fallback must end) and real bin/fm-control.sh.
set -u
. "$(dirname "$0")/live-lab.sh"
lab_init
# Real teardown, logged. When $LAB/refuse-<id> exists and the copy is still on
# disk it refuses the way the 2026-10-18 Vernant closeout driver did (the same
# stand-in tests/fm-merge-prune.test.sh section 5 uses), so the fallback decides.
cat > "$LAB/bin/teardown-logged" <<SH
#!/usr/bin/env bash
copy=\$(sed -n 's/^worktree=//p' "$STATE/\$1.meta" 2>/dev/null)
if [ -e "$LAB/refuse-\$1" ] && [ -n "\$copy" ] && [ -e "\$copy" ]; then
  out="REFUSED: Vernant's closeout driver did not release foreign copy \$copy/.claude/worktrees/n1 (exit 1): exact tree not covered by the merged PR"; rc=1
else
  out=\$("$WT/bin/fm-teardown.sh" "\$@" 2>&1); rc=\$?
fi
printf '=== teardown %s rc=%s\\n%s\\n' "\$*" "\$rc" "\$out" >> "$LAB/teardown-calls.log"
printf '%s\\n' "\$out" >&2
exit \$rc
SH
chmod +x "$LAB/bin/teardown-logged"
export FM_MERGE_PRUNE_TEARDOWN_BIN="$LAB/bin/teardown-logged"
# treehouse, logged: the real binary, every call recorded.
REAL_TH=$(command -v treehouse)
cat > "$LAB/bin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$LAB/treehouse-calls.log"
exec "$REAL_TH" "\$@"
SH
chmod +x "$LAB/bin/treehouse"
td() { awk -v id="$1" '/^=== teardown/{on=($3==id)} on' "$LAB/teardown-calls.log" | grep -E '^(===|REFUSED|error|teardown )' | head -10; }
slot_line() { (cd "$PROJ" && "$REAL_TH" status 2>/dev/null) | grep -F -- "$1" || echo "(slot not listed)"; }

echo "===== S8a: an unpushed commit in a NESTED linked worktree (.claude/worktrees/n1) keeps the whole slot with one wake"
new_task t8a 31; C=$COPY
git -C "$C" worktree add -q -b n1-work "$C/.claude/worktrees/n1" HEAD
printf 'o\n' > "$C/.claude/worktrees/n1/o.txt"; git -C "$C/.claude/worktrees/n1" add o.txt; git -C "$C/.claude/worktrees/n1" commit -q -m "unpushed in nested"
prune arm t8a >/dev/null 2>&1
prune run t8a --now >/dev/null 2>&1; prune run t8a --now >/dev/null 2>&1
show t8a; echo "real teardown said:"; td t8a
echo "nested unpushed still: $(git -C "$C/.claude/worktrees/n1" log --oneline HEAD --not --remotes); slot: $(slot_line "$C")"

echo "===== S6n: natural squash false positive: the pipeline rebased the branch (copy HEAD only on the gate remote)"
new_task t6n 32; C=$COPY
git init -q --bare "$LAB/remote/gate.git"; git -C "$C" remote add no-mistakes "$LAB/remote/gate.git"; git -C "$C" push -q no-mistakes "fm/t6n" 2>/dev/null
rm -rf "$LAB/pl"; git clone -q "$ORIGIN" "$LAB/pl" 2>/dev/null
git -C "$LAB/pl" checkout -q main; git -C "$LAB/pl" reset -q --hard HEAD~1   # main before this task's squash
printf 'other\n' > "$LAB/pl/other.txt"; git -C "$LAB/pl" add -A; git -C "$LAB/pl" commit -q -m "another PR"
git -C "$LAB/pl" cherry-pick -q "$(git -C "$C" rev-parse HEAD)" >/dev/null
RB=$(git -C "$LAB/pl" rev-parse HEAD)
git -C "$LAB/pl" push -q -f origin "$RB:refs/heads/fm/t6n" 2>/dev/null
SQ=$(git -C "$LAB/pl" commit-tree "$RB^{tree}" -p "$RB~1" -m "t6n (#32)"); git -C "$LAB/pl" push -q -f origin "$SQ:refs/heads/main" 2>/dev/null
rm -rf "$LAB/pl"; git -C "$C" fetch -q origin; git -C "$C" fetch -q --prune origin
printf '%s\n' "$RB" > "$LAB/gh/32.head"; sed -i.bak "s/^pr_head=.*/pr_head=$RB/" "$STATE/t6n.meta"
mkdir -p "$C/node_modules/x"; printf 'x\n' > "$C/node_modules/x/i.js"
prune arm t6n >/dev/null 2>&1
FM_MERGE_PRUNE_EXIT_WAIT=5 prune run t6n --now >/dev/null 2>&1
show t6n; echo "real teardown said:"; td t6n; echo "copy dir exists: $([ -e "$C" ] && echo yes || echo no); slot: $(slot_line "$C")"

echo "===== S6w: teardown refuses (closeout driver 'exact tree not covered'); the fallback proves the squash-merged copy scratch, preserves the bug-evidence record with SHA-256, ends the pane's idle treehouse subshell, and the REAL treehouse destroy removes it"
new_task t6w 33; C=$COPY; : > "$LAB/refuse-t6w"
mkdir -p "$C/.claude/bug-evidence" "$C/node_modules/x"
printf 'closeout evidence\n' > "$C/.claude/bug-evidence/slot.json"; printf 'x\n' > "$C/node_modules/x/i.js"
echo "before: slot $(slot_line "$C"); pane processes: $(pgrep -P "$PANE" | tr '\n' ' ')"
prune arm t6w >/dev/null 2>&1
FM_MERGE_PRUNE_EXIT_WAIT=5 prune run t6w --now >/dev/null 2>&1
show t6w; echo "real teardown said:"; td t6w
echo "copy dir exists after: $([ -e "$C" ] && echo yes || echo no); slot: $(slot_line "$C")"
echo "treehouse destroy calls:"; grep '^destroy' "$LAB/treehouse-calls.log" | sed "s#$LAB#\$LAB#g"
echo "preserved files:"; find "$DATA/t6w/merge-prune-preserved" -type f 2>/dev/null | sed "s#$DATA#\$DATA#"
for f in $(find "$DATA/t6w/merge-prune-preserved" -type f 2>/dev/null); do case "$f" in *sha256*|*SHA256*) echo "checksum file $(basename "$f"):"; cat "$f";; esac; done
echo "tmux windows: $(T list-windows -t firstmate -F '#{window_name}' | tr '\n' ' ')"

echo "===== S7w: same refusal, but the copy holds a unique ignored file (notes.local) outside the preserve list and scratch: kept, one wake, nothing destroyed"
new_task t7w 34; C=$COPY; : > "$LAB/refuse-t7w"
mkdir -p "$C/node_modules/x"; printf 'x\n' > "$C/node_modules/x/i.js"; printf 'only copy of my notes\n' > "$C/notes.local"
before=$(grep -c '^destroy' "$LAB/treehouse-calls.log" 2>/dev/null || echo 0)
prune arm t7w >/dev/null 2>&1
FM_MERGE_PRUNE_EXIT_WAIT=5 prune run t7w --now >/dev/null 2>&1; FM_MERGE_PRUNE_EXIT_WAIT=5 prune run t7w --now >/dev/null 2>&1
show t7w
echo "notes.local still there: $([ -f "$C/notes.local" ] && echo yes || echo no); copy on $(git -C "$C" symbolic-ref -q --short HEAD || echo detached); new destroy calls: $(( $(grep -c '^destroy' "$LAB/treehouse-calls.log" 2>/dev/null || echo 0) - before )); slot: $(slot_line "$C")"
echo "pane subshell still alive: $(pgrep -P "$PANE" >/dev/null && echo yes || echo no)"

echo "===== no forbidden treehouse flags in any call:"
grep -E -- '--include-unlanded|--include-in-use' "$LAB/treehouse-calls.log" | sed "s#$LAB#\$LAB#g" || echo "(none)"
echo "all treehouse destroy/return calls:"; grep -E '^(destroy|return)' "$LAB/treehouse-calls.log" | sed "s#$LAB#\$LAB#g"
