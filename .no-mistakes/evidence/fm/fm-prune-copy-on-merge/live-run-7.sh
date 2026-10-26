#!/usr/bin/env bash
# Round 2 extra scenarios for the new pre-teardown nested proof (ad8bd7984):
# S11 clean pushed nested copies do not block the prune; S12 a nested copy with
# an uncommitted file keeps the slot with one wake; S7t where the real teardown
# puts a unique ignored file when it returns the slot.
set -u
. "$(dirname "$0")/live-lab.sh"
lab_init
cat > "$LAB/bin/teardown-logged" <<X
#!/usr/bin/env bash
out=\$("$WT/bin/fm-teardown.sh" "\$@" 2>&1); rc=\$?
printf '=== teardown %s rc=%s\\n%s\\n' "\$*" "\$rc" "\$out" >> "$LAB/teardown-calls.log"
printf '%s\\n' "\$out" >&2
exit \$rc
X
chmod +x "$LAB/bin/teardown-logged"
export FM_MERGE_PRUNE_TEARDOWN_BIN="$LAB/bin/teardown-logged"
td() { awk -v id="$1" '/^=== teardown/{on=($3==id)} on' "$LAB/teardown-calls.log" 2>/dev/null | head -8; }
slot_line() { (cd "$PROJ" && treehouse status 2>/dev/null) | grep -F -- "$1" || echo "(slot not listed)"; }

echo "===== S11: clean, pushed nested copies (a linked worktree n1 and an independent clone n2) do not block: the copy is pruned"
new_task t11 61; C=$COPY
git -C "$C" worktree add -q --detach "$C/.claude/worktrees/n1" HEAD
git clone -q "$ORIGIN" "$C/.claude/worktrees/n2" 2>/dev/null
prune arm t11 >/dev/null 2>&1
prune run t11 --now >/dev/null 2>&1
show t11; echo "real teardown said:"; td t11; echo "slot: $(slot_line "$C")"

echo "===== S12: a nested clone with an uncommitted file keeps the whole slot with one wake; teardown never runs"
new_task t12 62; C=$COPY
git clone -q "$ORIGIN" "$C/.claude/worktrees/n2" 2>/dev/null
printf 'draft\n' > "$C/.claude/worktrees/n2/draft.txt"
prune arm t12 >/dev/null 2>&1
prune run t12 --now >/dev/null 2>&1; prune run t12 --now >/dev/null 2>&1
show t12; echo "teardown calls for t12: $(grep -c '^=== teardown t12' "$LAB/teardown-calls.log" 2>/dev/null || echo 0)"
echo "draft still there: $([ -f "$C/.claude/worktrees/n2/draft.txt" ] && echo yes || echo no); slot: $(slot_line "$C")"

echo "===== S7t: a unique ignored file (notes.local) in a copy the real teardown accepts: where does it go"
new_task t7t 63; C=$COPY
printf 'only copy of my notes\n' > "$C/notes.local"
prune arm t7t >/dev/null 2>&1
prune run t7t --now >/dev/null 2>&1
show t7t; echo "real teardown said:"; td t7t
echo "slot: $(slot_line "$C"); notes.local left in returned slot: $([ -f "$C/notes.local" ] && echo yes || echo no)"
echo "copies of notes.local under the lab home (outside the pool):"; find "$LAB/data" "$LAB/state" -name 'notes.local*' 2>/dev/null
grep -rl 'only copy of my notes' "$LAB/data" "$LAB/state" 2>/dev/null
