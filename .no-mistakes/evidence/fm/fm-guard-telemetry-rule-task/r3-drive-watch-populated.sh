#!/usr/bin/env bash
# Live driver: a real fm-watch.sh heartbeat in a marked lab home whose ship
# metadata points at the real train-5 branch (read-only) and at a lab task with
# a tree-equal merge. The heartbeat must publish both signatures, including the
# real instance 5ad471a2b, to state/.guard-workarounds-next and queue no wake.
set -u
WT=${1:?worktree}
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fm-lab-env.$$)"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' /tmp/fm-lab-env.$$ | head -1); rm -f /tmp/fm-lab-env.$$
trap 'tmux -L fm-lab kill-server 2>/dev/null; eval "$TEARDOWN" >/dev/null 2>&1' EXIT
ST=$FM_HOME/state
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=l@x.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=l@x.invalid
P=$FM_HOME/projects/demo
git init -q -b main "$P"; echo x > "$P/x"; git -C "$P" add x; git -C "$P" commit -qm init
git -C "$P" checkout -q -b fm/lab-task; echo impl > "$P/impl"; git -C "$P" add impl; git -C "$P" commit -qm impl
git -C "$P" checkout -q -b side; echo s > "$P/s"; git -C "$P" add s; git -C "$P" commit -qm side
git -C "$P" checkout -q fm/lab-task; git -C "$P" merge -q --no-ff -s ours -m "tree-equal merge" side
LAB_MERGE=$(git -C "$P" rev-parse HEAD)
printf 'kind=ship\nworktree=%s\nbranch=fm/lab-task\nbase_branch=main\n' "$P" > "$ST/lab-task.meta"
# train-5 has since landed on main, so a scan against main excludes it as base
# lineage by design. A shared local clone recreates the refusal-time view: the
# train branch at 5ad471a2b and its base at that merge's first parent.
C=$FM_HOME/projects/train5-clone
git clone -q --shared --no-checkout "$WT" "$C"
git -C "$C" branch -q train-5 5ad471a2bcdbe867ce73d1c880b8cb2a0371f68c
git -C "$C" branch -q train-base 5ad471a2bcdbe867ce73d1c880b8cb2a0371f68c^1
echo "clone tree-equal check: $(git -C "$C" rev-parse 5ad471a2b^{tree}) vs first parent $(git -C "$C" rev-parse 5ad471a2b^1^{tree})"
printf 'kind=ship\nworktree=%s\nbranch=train-5\nbase_branch=train-base\n' "$C" > "$ST/train-5.meta"
WT_BEFORE=$(git -C "$WT" status --porcelain | wc -l | tr -d ' '); REF_BEFORE=$(git -C "$WT" rev-parse fm/fm-merge-train-5)
echo "lab tree-equal merge: $LAB_MERGE"
env -u NO_MISTAKES_GATE -u FM_TASK_ID FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=2 bin/fm-watch.sh >"$FM_HOME/watch.out" 2>&1 </dev/null &
PID=$!
for _ in $(seq 1 90); do
  grep -q 5ad471a2b "$ST/.guard-workarounds-next" 2>/dev/null && break
  sleep 1
done
sleep 2
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
echo "== state/.guard-workarounds-next written by the heartbeat:"
cat "$ST/.guard-workarounds-next" 2>/dev/null || echo "(missing)"
grep -q "5ad471a2bcdbe867ce73d1c880b8cb2a0371f68c" "$ST/.guard-workarounds-next" 2>/dev/null && echo "real instance 5ad471a2b reported: yes" || echo "real instance 5ad471a2b reported: NO"
grep -q "$LAB_MERGE" "$ST/.guard-workarounds-next" 2>/dev/null && echo "lab tree-equal merge reported: yes" || echo "lab tree-equal merge reported: NO"
echo "temp leftovers: $(ls "$ST"/.guard-workarounds-next.* 2>/dev/null | wc -l | tr -d ' ')"
echo "== wake queue:"; cat "$ST/.wake-queue" 2>/dev/null || echo "(none)"
grep -q guard-workarounds "$ST/.wake-queue" 2>/dev/null && echo "FAIL: guard-workarounds wake queued" || echo "no guard-workarounds wake queued"
echo "== read-only: gate worktree status lines $WT_BEFORE -> $(git -C "$WT" status --porcelain | wc -l | tr -d ' '); train-5 ref unchanged: $([ "$REF_BEFORE" = "$(git -C "$WT" rev-parse fm/fm-merge-train-5)" ] && echo yes || echo no)"
echo "== guard events written by the scan: $(cat "$ST/guard-events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
