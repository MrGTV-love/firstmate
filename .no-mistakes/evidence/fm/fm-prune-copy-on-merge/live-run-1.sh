#!/usr/bin/env bash
# Live scenarios 1-5 against one lab: real treehouse pool, real tmux panes,
# real teardown/control/prune. Prints a transcript.
set -u
. "$(dirname "$0")/live-lab.sh"
lab_init
wait_gone() { local i; for i in $(seq 1 120); do [ -e "$STATE/$1.merge-prune" ] || return 0; sleep 1; done; return 1; }
slot_line() { (cd "$PROJ" && treehouse status 2>/dev/null) | grep -F -- "$1" || echo "(slot not listed)"; }

echo "===== S1: a verified merge prunes the copy with no human step"
new_task t1 7; C1=$COPY
echo "copy: $C1 (branch $(git -C "$C1" symbolic-ref --short HEAD))"
slot_line "$C1"
# The exact call bin/fm-pr-merge.sh makes after it verified a merge.
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$WT/bin/fm-merge-prune.sh" arm t1 --run </dev/null >/dev/null 2>&1
wait_gone t1 || echo "S1: record still present after 120s"
show t1
echo "slot after: $(slot_line "$C1")"
echo "copy status after: $(git -C "$C1" status --porcelain --untracked-files=all | wc -l | tr -d ' ') dirty lines, HEAD $(git -C "$C1" symbolic-ref -q --short HEAD || echo detached)"
echo "tmux windows: $(T list-windows -t firstmate -F '#{window_name}' | tr '\n' ' ')"

echo "===== S2: a transient refusal (co-tenant lifecycle lock) retries, then reaps"
new_task t2 8; C2=$COPY
sleep 600 & HOLDER=$!
mkdir "$STATE/.control-t2.lock"; printf '%s\n' "$HOLDER" > "$STATE/.control-t2.lock/pid"
prune arm t2 >/dev/null 2>&1
prune run t2 --now >/dev/null 2>&1
echo "after attempt 1 (lock held):"; show t2; echo "copy exists: $([ -e "$C2" ] && echo yes || echo no); slot: $(slot_line "$C2")"
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; rm -rf "$STATE/.control-t2.lock"
sed -i.bak 's/^next_at=.*/next_at=0/' "$STATE/t2.merge-prune"
prune run t2 >/dev/null 2>&1
echo "after the lock cleared and the backoff elapsed:"; show t2; echo "slot: $(slot_line "$C2")"

echo "===== S3: a copy with a changed file is kept with exactly one wake"
new_task t3 9; C3=$COPY
printf 'uncommitted edit\n' >> "$C3/README.md"
prune arm t3 >/dev/null 2>&1
prune run t3 --now >/dev/null 2>&1; prune run t3 --now >/dev/null 2>&1; prune run t3 --now >/dev/null 2>&1
show t3; echo "copy: $(git -C "$C3" status --porcelain) on $(git -C "$C3" symbolic-ref --short HEAD); slot: $(slot_line "$C3")"

echo "===== S4: a copy with an unpushed commit is kept with exactly one wake"
new_task t4 10; C4=$COPY
printf 'more\n' > "$C4/more.txt"; git -C "$C4" add more.txt; git -C "$C4" commit -q -m "unpushed work"
prune arm t4 >/dev/null 2>&1
prune run t4 --now >/dev/null 2>&1; prune run t4 --now >/dev/null 2>&1; prune run t4 --now >/dev/null 2>&1
show t4; echo "unpushed: $(git -C "$C4" log --oneline HEAD --not --remotes); slot: $(slot_line "$C4")"

echo "===== S5: a copy with a live process (a job in the pane) is kept with exactly one wake"
new_task t5 11; C5=$COPY
T send-keys -t firstmate:fm-t5 'sleep 900' Enter
sleep 2
prune arm t5 >/dev/null 2>&1
prune run t5 --now >/dev/null 2>&1; prune run t5 --now >/dev/null 2>&1
show t5; echo "copy exists: $([ -e "$C5" ] && echo yes || echo no); slot: $(slot_line "$C5")"
echo "pane still running sleep: $(pgrep -f 'sleep 900' >/dev/null && echo yes || echo no)"
T send-keys -t firstmate:fm-t5 C-c

echo "===== forbidden flags in treehouse calls? (none expected)"
grep -rhoE -- '--include-unlanded|--include-in-use|--force-destroy' "$LAB/state" "$LAB/data" 2>/dev/null | sort -u || true
