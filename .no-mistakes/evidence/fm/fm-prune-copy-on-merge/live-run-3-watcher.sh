#!/usr/bin/env bash
# S9 live: the real bin/fm-watch.sh, re-run after every exit the way the primary
# re-arms it, until its prune tick has run the sweep for the armed record t9.
set -u
. "$(dirname "$0")/live-lab.sh"
export TMUX_TMPDIR; TMUX_TMPDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
C=$(sed -n 's/^worktree=//p' "$STATE/t9.meta")
echo "record before: $(sed -n 's/^state=//p' "$STATE/t9.merge-prune") attempts=$(sed -n 's/^attempts=//p' "$STATE/t9.merge-prune"); slot: $( (cd "$PROJ" && treehouse status 2>/dev/null) | grep -F -- "$C")"
for run in 1 2 3 4 5 6 7 8; do
  [ -e "$STATE/t9.merge-prune" ] || break
  FM_MERGE_PRUNE_INTERVAL=2 FM_IDLE_REAP_INTERVAL=0 timeout 40 "$WT/bin/fm-watch.sh" </dev/null > "$LAB/watch.$run.out" 2> "$LAB/watch.$run.err"
  echo "watcher run $run exited $?: $(head -c 160 "$LAB/watch.$run.out" | tr '\n' ' ')"
  for i in $(seq 1 20); do [ -e "$STATE/t9.merge-prune" ] || break; sleep 1; done
done
show t9
echo "slot after: $( (cd "$PROJ" && treehouse status 2>/dev/null) | grep -F -- "$C")"
