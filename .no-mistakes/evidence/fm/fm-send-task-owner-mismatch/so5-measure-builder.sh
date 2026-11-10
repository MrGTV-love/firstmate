#!/usr/bin/env bash
# Builds a measurement copy of tests/fm-task-inbox.test.sh (definitions only)
# plus a timing variant of test_watcher_rerings_idle_pane_quietly that waits up
# to 60 s and reports when the first re-ring lands relative to the test's own
# 100-iteration (nominal 10 s) wait. Output: <dest>.
dest=$1
head -n 1353 "/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M72J0F8JK5E0YM7A7MKYVDN2/tests/fm-task-inbox.test.sh" | sed "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")|/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M72J0F8JK5E0YM7A7MKYVDN2/tests|g" > "$dest"
cat >> "$dest" <<'EOS'
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
measure_rering() {
  local dir state out log pid rec verdict t0 t1 i=0 iter_at_ring=-1 alive
  dir=$(setup_watch_case "rering-m$RANDOM")
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'unrecognized idle prompt\n' > "$dir/unknown.capture"
  verdict=$(PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/unknown.capture"     bash -c '. "$1"; fm_backend_composer_state tmux sess:fm-t1 fm-t1' _ "$ROOT/bin/fm-backend.sh")
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  t0=$(now_ms)
  watch_bg "$state" "$dir/fakebin" "$out" FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/unknown.capture"     FM_FAKE_TMUX_AGENT=claude FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 600 ]; do
    if grep -qF 'Firstmate instruction waiting' "$log" 2>/dev/null; then iter_at_ring=$i; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1; i=$((i + 1))
  done
  t1=$(now_ms)
  kill -0 "$pid" 2>/dev/null && alive=yes || alive=no
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if [ "$iter_at_ring" -lt 0 ]; then
    echo "verdict=$verdict ring=NONE watched_ms=$((t1-t0)) iters=$i watcher_alive=$alive load=$(sysctl -n vm.loadavg)"
  else
    echo "verdict=$verdict ring=yes first_ring_ms=$((t1-t0)) iter_at_ring=$iter_at_ring within_test_budget=$([ $iter_at_ring -lt 100 ] && echo yes || echo NO) watcher_alive=$alive load=$(sysctl -n vm.loadavg)"
  fi
}
for n in $(seq 1 "${SO5_REPS:-8}"); do measure_rering; done
EOS
