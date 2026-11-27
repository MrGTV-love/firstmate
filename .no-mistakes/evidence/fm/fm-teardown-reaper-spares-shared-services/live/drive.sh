#!/usr/bin/env bash
# Live drive of bin/fm-teardown.sh in a disposable marked lab home.
# Real: fm-teardown.sh, tmux (private lab socket via TMUX_TMPDIR), lsof, ps, git, perl, docker (read only).
# Stand-ins (external services teardown must not reach): gh, gh-axi, no-mistakes, treehouse (logs calls).
# Usage: drive.sh <worktree> <scenario>
set -u
WT_REPO=$1 SCEN=$2
EV=$(cd "$(dirname "$0")" && pwd)/$SCEN
rm -rf "$EV"; mkdir -p "$EV"
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
eval "$("$WT_REPO/bin/fm-lab-home.sh" env 2>"$EV/lab-env.stderr")" || { echo "lab env failed"; exit 2; }
SCR=$(TMPDIR=/tmp mktemp -d /tmp/fm-live.XXXXXX)
PIDS=()
cleanup() {
  chmod 700 "$TMUX_TMPDIR"/tmux-* 2>/dev/null || true
  for p in ${PIDS[@]+"${PIDS[@]}"}; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true; done
  tmux kill-server >/dev/null 2>&1 || true
  "$WT_REPO/bin/fm-lab-home.sh" teardown "$FM_HOME" >/dev/null 2>&1 || echo "lab teardown refused for $FM_HOME" >&2
  sleep 2  # let teardown's own background home-summary refresh finish before the home goes
  rm -rf "$FM_HOME" "$SCR"
  [ ! -e "$FM_HOME" ] && [ ! -e "$SCR" ] && [ ! -e "$TMUX_TMPDIR" ] && echo "lab removed: $FM_HOME $TMUX_TMPDIR $SCR" >> "$EV/transcript.txt"
}
trap cleanup EXIT
log() { printf '%s\n' "$*" | tee -a "$EV/transcript.txt"; }
log "== scenario $SCEN"
log "lab FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR scratch=$SCR"

# Stand-ins for the forge and the shared pipeline daemon: "no pull request", "no active run".
FB=$SCR/fakebin; mkdir -p "$FB"
cat > "$FB/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr view") echo "error: pull request not found" >&2; exit 1 ;; esac
exit 0
SH
cat > "$FB/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FB/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SCR/treehouse.calls"
exit 0
SH
chmod +x "$FB"/*

# A real project, its origin, and the task's copy on fm/task-x1, landed (empty commit, same tree as main).
G="git -c user.email=t@t -c user.name=t"
git init -q --bare "$SCR/origin.git"; git -C "$SCR/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$SCR/origin.git" "$SCR/seed" 2>/dev/null
$G -C "$SCR/seed" commit -q --allow-empty -m baseline; git -C "$SCR/seed" push -q origin main; rm -rf "$SCR/seed"
git clone -q "$SCR/origin.git" "$SCR/project" 2>/dev/null
git -C "$SCR/project" remote set-head origin main 2>/dev/null || true
git -C "$SCR/project" worktree add -q -b fm/task-x1 "$SCR/wt" main
$G -C "$SCR/wt" commit -q --allow-empty -m "shippable work"
git -C "$SCR/wt" push -q origin fm/task-x1; git -C "$SCR/project" fetch -q origin
WT=$(cd "$SCR/wt" && pwd -P)
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$SCR/wt" \
  "project=$SCR/project" "kind=ship" "mode=no-mistakes" "spawn_gen=live-task-x1" > "$FM_HOME/state/task-x1.meta"
touch "$FM_HOME/state/.last-watcher-beat"

# The task's real tmux window on the lab's private server: one pane, a plain shell loop, cwd outside the copy.
WIN=fm-task-x1
[ "$SCEN" = exact-name ] && WIN=fm-task-x10
tmux new-session -d -s firstmate -n "$WIN" -c "$SCR" 'exec sleep 3600' || { log "tmux start failed"; exit 2; }
tmux new-window -d -t firstmate -n bystander -c "$SCR" 'exec sleep 3600'

detached_daemon() {  # a session-leading, double-forked process at the copy root, child of no task process
  local out=$SCR/daemon.pid i
  perl -MPOSIX -e '
    my ($cwd, $out) = @ARGV;
    my $first = fork(); die "fork" unless defined $first;
    if ($first) { waitpid($first, 0); exit 0; }
    POSIX::setsid(); my $second = fork(); die "fork" unless defined $second; POSIX::_exit(0) if $second;
    chdir $cwd or die; open STDIN, "<", "/dev/null"; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
    open my $fh, ">", "$out.tmp" or die; print {$fh} "$$\n"; close $fh; rename "$out.tmp", $out;
    $0 = "no-mistakes-daemon-standin"; sleep 600;' "$WT" "$out"
  for i in $(seq 100); do [ -s "$out" ] && break; sleep 0.05; done
  DAEMON=$(cat "$out"); PIDS+=("$DAEMON")
}

snapshot() {  # <phase>
  {
    echo "-- $1"
    echo "tmux windows:"; tmux list-windows -a -F '  #{session_name}:#{window_name} panes=#{window_panes}' 2>&1
    echo "tmux panes:"; tmux list-panes -a -F '  #{window_name} #{pane_id} pid=#{pane_pid}' 2>&1
    echo "processes with cwd in the copy:"; lsof -a -d cwd -Fpn 2>/dev/null | awk -v r="$WT" '/^p/{p=substr($0,2)} /^n/{n=substr($0,2); if (n==r || index(n, r"/")==1) print "  pid=" p " cwd=" n}'
    echo "task record: $( [ -f "$FM_HOME/state/task-x1.meta" ] && echo present || echo absent )"
    echo "copy: $( [ -d "$SCR/wt" ] && echo present || echo absent )"
    echo "audit:"; cat "$FM_HOME/state/task-x1.teardown-processes" 2>/dev/null | sed 's/^/  /' || true
  } >> "$EV/transcript.txt" 2>&1
}

run_teardown() {
  RC=0
  ( cd "$WT_REPO" && env -u FM_GATE_REFUSE_BYPASS PATH="$FB:$PATH" FM_HOME="$FM_HOME" TMUX_TMPDIR="$TMUX_TMPDIR" \
      bin/fm-teardown.sh task-x1 "$@" ) > "$EV/teardown.stdout" 2> "$EV/teardown.stderr" || RC=$?
  log "\$ FM_HOME=<lab> bin/fm-teardown.sh task-x1 $* -> exit $RC"
  { echo "stderr (last 12 lines):"; tail -12 "$EV/teardown.stderr" | sed 's/^/  /'; } >> "$EV/transcript.txt"
}
alive() { kill -0 "$1" 2>/dev/null; }
check() {  # <desc> <cmd...>
  if "${@:2}"; then log "PASS: $1"; else log "FAIL: $1"; FAILED=1; fi
}
FAILED=0
win_exists() { tmux list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -Fxq "$1"; }
not() { ! "$@"; }

case "$SCEN" in
  daemon|daemon-force)
    detached_daemon
    log "shared-daemon stand-in pid=$DAEMON ppid=$(ps -o ppid= -p "$DAEMON" | tr -d ' ') sid-leader cwd=$WT"
    snapshot before
    if [ "$SCEN" = daemon-force ]; then
      printf 'Lab: the captain approved discarding this work.\n' > "$SCR/drop.txt"
      run_teardown --force --drop-file "$SCR/drop.txt"
    else
      run_teardown
    fi
    snapshot after
    check "teardown refuses (exit 1)" test "$RC" = 1
    check "the shared daemon is still alive" alive "$DAEMON"
    check "the refusal names the daemon pid and says nothing proves it is the task's" grep -Eq "REFUSED: process $DAEMON .*nothing proves it belongs to task-x1" "$EV/teardown.stderr"
    check "the task window was not closed" win_exists fm-task-x1
    check "the bystander window was not closed" win_exists bystander
    check "the task record is kept" test -f "$FM_HOME/state/task-x1.meta"
    check "no signal was audited" test ! -s "$FM_HOME/state/task-x1.teardown-processes"
    check "treehouse was not asked to return the copy" test ! -s "$SCR/treehouse.calls"
    ;;
  leak)
    tmux respawn-pane -k -t firstmate:fm-task-x1 "sh -c '(cd \"$WT\" && exec perl -e \"\\\$0=q(leaked-task-helper); sleep 600\") & exec sleep 3600'"
    PANE=$(tmux display-message -p -t firstmate:fm-task-x1 '#{pane_pid}')
    LEAK=
    for i in $(seq 100); do LEAK=$(pgrep -P "$PANE" 2>/dev/null | head -n1); [ -n "$LEAK" ] && [ "$(lsof -a -d cwd -p "$LEAK" -Fn 2>/dev/null | sed -n 's/^n//p')" = "$WT" ] && break; LEAK=; sleep 0.05; done
    PIDS+=("$LEAK")
    log "pane pid=$PANE leaked child pid=$LEAK cwd=$WT"
    snapshot before
    run_teardown
    for i in $(seq 50); do alive "$LEAK" || break; sleep 0.1; done
    snapshot after
    check "teardown succeeds (exit 0)" test "$RC" = 0
    check "the leaked child of the task pane is gone" not alive "$LEAK"
    check "the TERM of the leak is audited" grep -q "	TERM	$LEAK	" "$FM_HOME/state/task-x1.teardown-processes"
    check "the task window is closed" not win_exists fm-task-x1
    check "the bystander window survives" win_exists bystander
    check "the task record is removed" test ! -f "$FM_HOME/state/task-x1.meta"
    ;;
  mixed)
    tmux respawn-pane -k -t firstmate:fm-task-x1 "sh -c '(cd \"$WT\" && exec perl -e \"\\\$0=q(leaked-task-helper); sleep 600\") & exec sleep 3600'"
    PANE=$(tmux display-message -p -t firstmate:fm-task-x1 '#{pane_pid}')
    LEAK=
    for i in $(seq 100); do LEAK=$(pgrep -P "$PANE" 2>/dev/null | head -n1); [ -n "$LEAK" ] && [ "$(lsof -a -d cwd -p "$LEAK" -Fn 2>/dev/null | sed -n 's/^n//p')" = "$WT" ] && break; LEAK=; sleep 0.05; done
    PIDS+=("$LEAK")
    detached_daemon
    log "pane pid=$PANE proven leak pid=$LEAK and unproven daemon pid=$DAEMON, both at the copy root"
    snapshot before
    run_teardown
    snapshot after
    check "teardown refuses (exit 1)" test "$RC" = 1
    check "the unproven daemon is alive" alive "$DAEMON"
    check "the proven leak is also left alive (nothing signalled before every proof passed)" alive "$LEAK"
    check "the refusal names the daemon" grep -Eq "REFUSED: process $DAEMON .*nothing proves it belongs to task-x1" "$EV/teardown.stderr"
    check "the task window was not closed" win_exists fm-task-x1
    check "no signal was audited" test ! -s "$FM_HOME/state/task-x1.teardown-processes"
    check "the task record is kept" test -f "$FM_HOME/state/task-x1.meta"
    ;;
  shared-window)
    tmux split-window -d -t firstmate:fm-task-x1 -c "$SCR" 'exec sleep 3600'
    P1=$(tmux list-panes -t firstmate:fm-task-x1 -F '#{pane_pid}' | sed -n 1p); P2=$(tmux list-panes -t firstmate:fm-task-x1 -F '#{pane_pid}' | sed -n 2p)
    log "recorded window has two panes: pids $P1 $P2 (a user split)"
    snapshot before
    run_teardown
    snapshot after
    check "teardown refuses (exit 1)" test "$RC" = 1
    check "the refusal names the endpoint and several panes" grep -Eq "REFUSED: the endpoint firstmate:fm-task-x1 of task task-x1 cannot be closed safely: .*several panes" "$EV/teardown.stderr"
    check "the shared window still exists" win_exists fm-task-x1
    check "both pane processes are alive" alive "$P1"
    check "second pane process is alive" alive "$P2"
    check "the task record is kept" test -f "$FM_HOME/state/task-x1.meta"
    check "no signal was audited" test ! -s "$FM_HOME/state/task-x1.teardown-processes"
    ;;
  unreadable-socket)
    SOCKDIR=$(ls -d "$TMUX_TMPDIR"/tmux-* | head -n1)
    chmod 000 "$SOCKDIR"
    log "tmux socket directory $SOCKDIR made unreadable (mode 000)"
    tmux list-windows -t firstmate >> "$EV/transcript.txt" 2>&1 || log "tmux itself now answers: $(tmux list-windows -t firstmate 2>&1 | head -1)"
    run_teardown
    chmod 700 "$SOCKDIR"
    snapshot after-restore
    check "teardown refuses (exit 1)" test "$RC" = 1
    check "the refusal says the endpoint cannot be read" grep -Eq "REFUSED: the endpoint firstmate:fm-task-x1 of task task-x1 cannot be closed safely: .*cannot be read" "$EV/teardown.stderr"
    check "the task window still exists" win_exists fm-task-x1
    check "the task record is kept" test -f "$FM_HOME/state/task-x1.meta"
    ;;
  exact-name)
    P10=$(tmux list-panes -t firstmate:fm-task-x10 -F '#{pane_pid}' | head -n1)
    log "recorded window fm-task-x1 is absent; a lookalike window fm-task-x10 (pane pid $P10) exists"
    snapshot before
    run_teardown
    snapshot after
    check "teardown completes (exit 0): the recorded window is absent" test "$RC" = 0
    check "the lookalike window fm-task-x10 survives" win_exists fm-task-x10
    check "the lookalike pane process is alive" alive "$P10"
    check "the bystander window survives" win_exists bystander
    ;;
esac
log "RESULT $SCEN: $([ "$FAILED" = 0 ] && echo pass || echo fail)"
exit "$FAILED"
