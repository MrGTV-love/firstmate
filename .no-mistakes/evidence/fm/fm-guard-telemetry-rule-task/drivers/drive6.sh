#!/usr/bin/env bash
# Heartbeat home-scan: the detector reads lab task records and their branches, read-only.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6FJ8XSS0AWB1CFHTT675C3M
cd "$WT"; unset FM_GUARD_EVENT_LOG FM_TASK_ID
. /tmp/fmtest-01M6/lab.path; export FM_HOME=$LAB; STATE=$LAB/state
R=/tmp/fmtest-01M6/fixrepo; rm -rf "$R" "$R-origin"
g() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
git init -q -b main "$R"; echo a > "$R/a"; g add a; g commit -qm base
g checkout -qb tree-eq; echo b > "$R/b"; g add b; g commit -qm work
g checkout -q main; echo m > "$R/m"; g add m; g commit -qm main2
g checkout -q tree-eq; g merge -q -s ours main -m "tree-equal merge"           # tree equals first parent
g checkout -q -b base-only main~1; echo c > "$R/c"; g add c; g commit -qm work2
OLD=$(g rev-parse HEAD)
sleep 1
g merge -q --no-edit main                                                     # head changed only by a base merge
g checkout -q -b clean main; echo d > "$R/d"; g add d; g commit -qm honest       # control: no signature
g checkout -q main
for t in tree-eq base-only clean; do printf 'kind=ship\nworktree=%s\nbranch=%s\nbase_branch=main\n' "$R" "$t" > "$STATE/wa-$t.meta"; done
# The refusal the base-merge-only signature needs, written by the real writer before the merge commit time is irrelevant here: back-date it.
FM_GUARD_EVENT_LOG=/tmp/fmtest-01M6/wa-events.jsonl bin/fm-guard-event.sh merge-checks-green deny --rule checks-green --task wa-base-only --head "$OLD" --base main
python3 - /tmp/fmtest-01M6/wa-events.jsonl <<'PY'
import json,sys; p=sys.argv[1]; rows=[json.loads(l) for l in open(p)]
for r in rows: r['ts']='2000-01-01T00:00:00Z'
open(p,'w').write(''.join(json.dumps(r)+'\n' for r in rows))
PY
before=$(git -C "$R" for-each-ref | shasum); lb=$(ls -la "$STATE" | shasum)
echo "### home scan (what the heartbeat runs) over 3 lab task records"
python3 bin/fm-guard-workarounds.py --state "$STATE" --log /tmp/fmtest-01M6/wa-events.jsonl; echo "rc=$?"
after=$(git -C "$R" for-each-ref | shasum); la=$(ls -la "$STATE" | shasum)
[ "$before" = "$after" ] && echo "fixture refs unchanged"; [ "$lb" = "$la" ] && echo "lab state dir unchanged"
echo "### heartbeat function: guard_workarounds_detached publishes state/.guard-workarounds-next"
( SCRIPT_DIR=$WT/bin; eval "$(sed -n '/^GUARD_WORKAROUND_PID=$/,/^}$/p' bin/fm-watch.sh)"; FM_GUARD_EVENT_LOG=/tmp/fmtest-01M6/wa-events.jsonl guard_workarounds_detached; wait "$GUARD_WORKAROUND_PID"; echo "report:"; cat "$STATE/.guard-workarounds-next" )
rm -f "$STATE"/wa-*.meta "$STATE/.guard-workarounds-next"
