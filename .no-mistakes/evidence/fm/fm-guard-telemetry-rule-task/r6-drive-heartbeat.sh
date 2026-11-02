#!/usr/bin/env bash
# Live: real fm-watch.sh heartbeat in a marked lab home. Ship records point at
# (a) the real train-5 merge 5ad471a2b (read-only shared clone), (b) a copy whose
# head changed only by a base merge after a merge-checks-green refusal (split
# guard), (c) the same history after a refusal from a guard the detector does not
# read (merge-held-task), (d) a refusal followed by a real fix. Only (a) and (b)
# may be reported; no wake is queued; the scan writes no event.
set -u
WT=${1:?worktree}; cd "$WT"
unset FM_GUARD_EVENT_LOG FM_TASK_ID FM_GATE_REFUSE_BYPASS
ERR=$(mktemp); eval "$(bin/fm-lab-home.sh env 2>"$ERR")"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' "$ERR" | head -1); rm -f "$ERR"
trap 'tmux -L fm-lab kill-server 2>/dev/null; eval "$TEARDOWN" >/dev/null 2>&1; echo "lab torn down: $([ -e "$FM_HOME" ] && echo no || echo yes)"' EXIT
ST=$FM_HOME/state; PR=$FM_HOME/projects
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=l@x.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=l@x.invalid
g() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
git init -q -b main "$PR/origin"; echo base > "$PR/origin/f"; g "$PR/origin" add f; g "$PR/origin" commit -m base
mk() { git clone -q "$PR/origin" "$PR/$1"; g "$PR/$1" checkout -b "fm/$1"; echo "impl $1" > "$PR/$1/impl"; g "$PR/$1" add impl; g "$PR/$1" commit -m "impl $1"
  printf 'kind=ship\nworktree=%s\nbranch=fm/%s\nbase_branch=main\n' "$PR/$1" "$1" > "$ST/$1.meta"; git -C "$PR/$1" rev-parse HEAD; }
HB=$(mk checks-red-then-basemerge); HC=$(mk held-then-basemerge); HD=$(mk checks-red-then-real-fix)
# Refusal rows through the real writer on its default home path (no --log).
bin/fm-guard-event.sh merge-checks-green deny --rule checks-green --task checks-red-then-basemerge --head "$HB" --base main
bin/fm-guard-event.sh merge-held-task deny --rule captain-hold --task held-then-basemerge --head "$HC" --base main
bin/fm-guard-event.sh merge-checks-green deny --rule checks-green --task checks-red-then-real-fix --head "$HD" --base main
echo "== refusal rows in the lab home log"; jq -c '{guard,decision,rule,task,head:.head[0:7],base}' "$ST/guard-events.jsonl"
ROWS0=$(wc -l < "$ST/guard-events.jsonl" | tr -d ' ')
sleep 2; echo base2 >> "$PR/origin/f"; g "$PR/origin" commit -am base2
for t in checks-red-then-basemerge held-then-basemerge checks-red-then-real-fix; do g "$PR/$t" fetch -q origin; done
g "$PR/checks-red-then-basemerge" merge --no-ff -m "merge base" origin/main
g "$PR/held-then-basemerge" merge --no-ff -m "merge base" origin/main
echo fix >> "$PR/checks-red-then-real-fix/impl"; g "$PR/checks-red-then-real-fix" commit -am "real fix"
C=$PR/train5-clone; git clone -q --shared --no-checkout "$WT" "$C"
git -C "$C" branch -q train-5 5ad471a2bcdbe867ce73d1c880b8cb2a0371f68c; git -C "$C" branch -q train-base 5ad471a2bcdbe867ce73d1c880b8cb2a0371f68c^1
printf 'kind=ship\nworktree=%s\nbranch=train-5\nbase_branch=train-base\n' "$C" > "$ST/train-5.meta"
WT_BEFORE=$(git -C "$WT" status --porcelain | wc -l | tr -d ' ')
env -u NO_MISTAKES_GATE FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=2 bin/fm-watch.sh >"$FM_HOME/watch.out" 2>&1 </dev/null &
PID=$!
for _ in $(seq 1 120); do grep -q 5ad471a2b "$ST/.guard-workarounds-next" 2>/dev/null && break; sleep 1; done
sleep 2; kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
echo "== state/.guard-workarounds-next written by the heartbeat:"; cat "$ST/.guard-workarounds-next" 2>/dev/null || echo "(missing)"
R=$ST/.guard-workarounds-next
chk() { grep -q "task=$1 " "$R" 2>/dev/null && echo "$1 reported: yes" || echo "$1 reported: no"; }
chk train-5; chk checks-red-then-basemerge; chk held-then-basemerge; chk checks-red-then-real-fix
echo "== same scan as JSON (detector feed)"; python3 bin/fm-guard-workarounds.py --state "$ST" --json | tee "$FM_HOME/wk.jsonl" | jq -c '{guard,rule,task,kind,head:.head[0:9],refused_head:(.refused_head//""|.[0:7])}'
echo "== wake queue has guard-workarounds: $(grep -c guard-workarounds "$ST/.wake-queue" 2>/dev/null || echo 0)"
echo "== guard rows added by the scan: $(( $(wc -l < "$ST/guard-events.jsonl" | tr -d ' ') - ROWS0 ))"
echo "== gate worktree status lines $WT_BEFORE -> $(git -C "$WT" status --porcelain | wc -l | tr -d ' ')"
echo "== metrics with the detector feed (merge-checks-green)"
bin/fm-guard-metrics.sh --workarounds "$FM_HOME/wk.jsonl" --guards merge-checks-green,merge-held-task | grep -E '^(METRIC|RULE)' | sed -E 's/ (warns|median_clear_attempts|verdict|recurrences)=[^ ]*//g'
