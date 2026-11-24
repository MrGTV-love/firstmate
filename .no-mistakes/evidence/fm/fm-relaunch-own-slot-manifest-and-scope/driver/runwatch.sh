# run_watch <tag>: run the lab's real bin/fm-watch.sh in a lab tmux window until it exits (max 240s); output to $ROOT/watch-<tag>.out
run_watch() {
  local tag=$1 out=$ROOT/watch-$1.out i
  rm -f "$out"
  lt new-window -d -t firstmate: -n "watch-$tag" -c "$LAB" \
    "env -i HOME='$HOME' USER='$USER' PATH='$PATH' SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 TMUX_TMPDIR='$TMUX_DIR' TREEHOUSE_ROOT='$ROOT/treehouse' FM_BACKEND=tmux DISABLE_AUTOUPDATER=1 FM_HOME='$LAB' '$LAB/bin/fm-watch.sh' > '$out' 2>&1; echo \"watcher-exit=\$?\" >> '$out'"
  for i in $(seq 1 120); do grep -q '^watcher-exit=' "$out" 2>/dev/null && break; sleep 2; done
  grep -q '^watcher-exit=' "$out" || { echo "(watcher still running after 240s; stopping its window)"; lt kill-window -t "firstmate:watch-$tag"; sleep 2; }
  cat "$out"
}
