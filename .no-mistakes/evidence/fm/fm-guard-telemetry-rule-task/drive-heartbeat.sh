#!/usr/bin/env bash
# Live: the real watcher's heartbeat runs the read-only detector in a marked lab home.
set -u
WT=$PWD; EV=$1
unset FM_GUARD_EVENT_LOG FM_GATE_REFUSE_BYPASS FM_TASK_ID
eval "$(bin/fm-lab-home.sh env 2>"$EV/.lab-stderr")"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' "$EV/.lab-stderr" | head -1); rm -f "$EV/.lab-stderr"
echo "lab home: $FM_HOME"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-hb.XXXXXX")
g() { git -C "$T/copy" -c user.name=t -c user.email=t@example.invalid "$@"; }
git init -q --bare "$T/origin.git"; git init -q -b main "$T/copy"; g remote add origin "$T/origin.git"
echo a >"$T/copy/a"; g add a; g commit -qm base1; g push -q origin main
g checkout -qb fm/hb-task; echo f >"$T/copy/f"; g add f; g commit -qm feat
g checkout -q main; echo b >"$T/copy/b"; g add b; g commit -qm base2; g push -q origin main; g fetch -q origin
g checkout -q fm/hb-task; g merge -q -s ours --no-edit origin/main; MERGE=$(g rev-parse HEAD)
echo "tree-equal merge on task branch: $MERGE"
printf 'kind=ship\nworktree=%s\nbranch=fm/hb-task\nbase_branch=main\n' "$T/copy" >"$FM_HOME/state/hb-task.meta"
( cd "$WT" && FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 FM_POLL=1 bin/fm-watch.sh >"$T/watch.out" 2>"$T/watch.err" ) &
W=$!
i=0; while [ $i -lt 40 ] && [ ! -s "$FM_HOME/state/.guard-workarounds-next" ]; do sleep 1; i=$((i+1)); done
kill "$W" 2>/dev/null; wait "$W" 2>/dev/null
echo "watcher ran ${i}s; report file:"
cat "$FM_HOME/state/.guard-workarounds-next" 2>/dev/null || { echo "(no report)"; echo "--- watcher stdout"; head -20 "$T/watch.out"; echo "--- watcher stderr"; head -20 "$T/watch.err"; }
echo "guard events written by the heartbeat detector: $(cat "$FM_HOME/state/guard-events.jsonl" 2>/dev/null | jq -s '[.[]|select(.guard=="merge-green-head")]|length')"
echo "task branch unchanged: $([ "$(g rev-parse HEAD)" = "$MERGE" ] && echo yes || echo NO)"
pkill -f "fm-guard-workarounds.py --state $FM_HOME/state" 2>/dev/null
tmux -L fm-lab kill-server 2>/dev/null
rm -rf "$T"; eval "$TEARDOWN" && echo "lab removed: $([ -e "$FM_HOME" ] && echo NO || echo yes)"
