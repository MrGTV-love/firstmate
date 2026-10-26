#!/usr/bin/env bash
# Live scenarios 5b-9 against one lab (same helpers as live-run-1.sh).
set -u
. "$(dirname "$0")/live-lab.sh"
lab_init
# The real teardown, with its output kept per call so the transcript can show
# what it refused (pure pass-through: same args, same exit status).
cat > "$LAB/bin/teardown-logged" <<SH
#!/usr/bin/env bash
out=\$("$WT/bin/fm-teardown.sh" "\$@" 2>&1); rc=\$?
printf '=== teardown %s rc=%s\\n%s\\n' "\$*" "\$rc" "\$out" >> "$LAB/teardown-calls.log"
printf '%s\\n' "\$out" >&2
exit \$rc
SH
chmod +x "$LAB/bin/teardown-logged"
export FM_MERGE_PRUNE_TEARDOWN_BIN="$LAB/bin/teardown-logged"
td_refusals() { grep -E "^(=== teardown $1|REFUSED|error)" "$LAB/teardown-calls.log" | awk -v id="$1" '/^=== teardown/{on=($3==id)} on' | sed "s#$LAB#\$LAB#g" | head -12; }
wait_gone() { local i; for i in $(seq 1 "${2:-120}"); do [ -e "$STATE/$1.merge-prune" ] || return 0; sleep 1; done; return 1; }
slot_line() { (cd "$PROJ" && treehouse status 2>/dev/null) | grep -F -- "$1" || echo "(slot not listed)"; }

echo "===== S5b: a process working in a subdirectory of the copy (not provably the task's) keeps the copy with one wake"
new_task t5b 21; C=$COPY
mkdir -p "$C/src"; printf 'x\n' > "$C/src/a.txt"; git -C "$C" add src && git -C "$C" commit -q -m src && git -C "$C" push -q origin fm/t5b 2>/dev/null
printf '%s\n' "$(git -C "$C" rev-parse HEAD)" > "$LAB/gh/21.head"
sed -i.bak "s/^pr_head=.*/pr_head=$(git -C "$C" rev-parse HEAD)/" "$STATE/t5b.meta"
sq=$(git -C "$C" commit-tree 'HEAD^{tree}' -p "$(git -C "$C" rev-parse origin/main)" -m "t5b (#21)"); git -C "$C" push -q origin "$sq:refs/heads/main" 2>/dev/null; git -C "$C" fetch -q origin
(cd "$C/src" && exec sleep 900) & BG=$!
sleep 1
prune arm t5b >/dev/null 2>&1
prune run t5b --now >/dev/null 2>&1; prune run t5b --now >/dev/null 2>&1
show t5b; echo "copy on: $(git -C "$C" symbolic-ref -q --short HEAD || echo detached); process $BG alive: $(kill -0 $BG 2>/dev/null && echo yes || echo no); slot: $(slot_line "$C")"
kill $BG 2>/dev/null; wait $BG 2>/dev/null

echo "===== S6: a squash-merged copy (pipeline commit on top) with ignored scratch and a bug-evidence record: teardown refuses, the fallback proves it scratch, preserves the record with a checksum, and real treehouse destroy removes it"
PIPELINE=1 new_task t6 22; C=$COPY
mkdir -p "$C/.claude/bug-evidence" "$C/node_modules/x"
printf 'closeout evidence\n' > "$C/.claude/bug-evidence/slot.json"; printf 'x\n' > "$C/node_modules/x/i.js"
echo "copy before: $C on $(git -C "$C" symbolic-ref --short HEAD); ignored: $(cd "$C" && git ls-files -o -i --exclude-standard --directory | tr '\n' ' ')"
prune arm t6 >/dev/null 2>&1
FM_MERGE_PRUNE_EXIT_WAIT=5 prune run t6 --now >/dev/null 2>&1
show t6
echo "real teardown said:"; td_refusals t6
echo "copy dir exists after: $([ -e "$C" ] && echo yes || echo no); slot: $(slot_line "$C")"
echo "preserved:"; find "$DATA/t6/merge-prune-preserved" -type f 2>/dev/null | sed "s#$LAB#\$LAB#" ; cat "$DATA/t6/merge-prune-preserved"/*SHA256* "$DATA/t6/merge-prune-preserved"/*/*SHA256* 2>/dev/null | sed "s#$LAB#\$LAB#"
echo "tmux windows: $(T list-windows -t firstmate -F '#{window_name}' | tr '\n' ' ')"

echo "===== S7: same squash-merged shape but with a unique ignored file outside the preserve list and scratch: kept with one wake"
PIPELINE=1 new_task t7 23; C=$COPY
mkdir -p "$C/node_modules/x"; printf 'x\n' > "$C/node_modules/x/i.js"
printf 'only copy of my notes\n' > "$C/notes.local"
prune arm t7 >/dev/null 2>&1
FM_MERGE_PRUNE_EXIT_WAIT=5 prune run t7 --now >/dev/null 2>&1; FM_MERGE_PRUNE_EXIT_WAIT=5 prune run t7 --now >/dev/null 2>&1
show t7; echo "notes.local still there: $([ -f "$C/notes.local" ] && echo yes || echo no); slot: $(slot_line "$C")"

echo "===== S8: an unpushed commit in a NESTED copy keeps the whole slot with one wake"
PIPELINE=1 new_task t8 24; C=$COPY
git clone -q "$ORIGIN" "$C/.claude/worktrees/n1" 2>/dev/null
printf 'o\n' > "$C/.claude/worktrees/n1/o.txt"; git -C "$C/.claude/worktrees/n1" add o.txt; git -C "$C/.claude/worktrees/n1" commit -q -m "unpushed in nested"
prune arm t8 >/dev/null 2>&1
FM_MERGE_PRUNE_EXIT_WAIT=5 prune run t8 --now >/dev/null 2>&1; FM_MERGE_PRUNE_EXIT_WAIT=5 prune run t8 --now >/dev/null 2>&1
show t8; echo "nested unpushed: $(git -C "$C/.claude/worktrees/n1" log --oneline HEAD --not --remotes); slot: $(slot_line "$C")"

echo "===== S9: a merge armed by the poll (arm only) is pruned by the real watcher's tick"
new_task t9 25; C=$COPY
prune arm t9 >/dev/null 2>&1
echo "record before watcher: $(sed -n 's/^state=//p' "$STATE/t9.merge-prune")"
FM_MERGE_PRUNE_INTERVAL=2 FM_IDLE_REAP_INTERVAL=0 "$WT/bin/fm-watch.sh" </dev/null > "$LAB/watch.out" 2> "$LAB/watch.err" & WPID=$!
wait_gone t9 90 || echo "S9: record still present after 90s"
show t9; echo "slot: $(slot_line "$C")"
kill "$WPID" 2>/dev/null; sleep 1; kill -9 "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
echo "watcher stderr tail:"; tail -5 "$LAB/watch.err" | sed "s#$LAB#\$LAB#g"
