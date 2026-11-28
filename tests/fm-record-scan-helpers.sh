#!/usr/bin/env bash
# Shared fixtures for the suites that drive the real bin/fm-teardown.sh over many task records:
# tests/fm-record-paths-scan.test.sh (the scans hold no pipe fd past a record) and
# tests/fm-teardown-scan-bounds.test.sh (a scan under the project lock is bounded, and a teardown ends
# cleanly on SIGTERM). Source this from a suite; it sources tests/fm-teardown-helpers.sh.
# The cases source libraries inside subshells on purpose, so a variable they set there is not the suite's own.
# shellcheck disable=SC2030,SC2031
# shellcheck source=tests/fm-teardown-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-helpers.sh"

# --- teardown fixtures ---------------------------------------------------------------------------------------------

# make_scan_case <name> <n>: a scout task-x1 in a Treehouse-shaped pool slot, with n-1 other records spread over
# the primary state and three registered local homes; every other record names its own existing directory.
make_scan_case() {
  local name=$1 n=$2 case_dir wt f slot sd i homes=3 fwt
  case_dir=$(make_case "$name")
  wt=$(move_case_to_pool_slot "$case_dir" 9)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_clean_fd "$case_dir"
  printf 'manual\n' > "$case_dir/config/backlog-backend"
  : > "$case_dir/data/secondmates.md"
  i=1
  while [ "$i" -le "$homes" ]; do
    mkdir -p "$case_dir/h$i/state" "$case_dir/h$i/data"
    printf -- '- h%s - fixture (home: %s; scope: x; projects: y; added 2026-01-01)\n' "$i" "$case_dir/h$i" >> "$case_dir/data/secondmates.md"
    i=$((i + 1))
  done
  f=1
  while [ "$f" -le $((n - 1)) ]; do
    slot=$((f % (homes + 1)))
    if [ "$slot" -eq 0 ]; then sd="$case_dir/state"; else sd="$case_dir/h$slot/state"; fi
    fwt="$case_dir/pool/fill-$f/repo"
    mkdir -p "$fwt"
    printf 'worktree=%s\nproject=%s\nkind=ship\n' "$fwt" "$case_dir/project" > "$sd/fill-$(printf '%04d' "$f").meta"
    f=$((f + 1))
  done
  printf '%s\n' "$case_dir"
}

# add_fd_git_shim <case-dir>: a `git` that, when asked the Git common directory of one of the filler copies (the one
# per-record command the teardown scan runs), appends its own open-fd count to $FM_FD_LOG, then runs the real git.
# Optional controls, all read from the environment of the run:
#   FM_FDCASE_STOP_AFTER=<n>  SIGTERM to the process group led by the pid in $FM_FDCASE_LEADER after n reads, so a case
#                             run against code that leaks a pipe per record, or loops on a full table, ends by itself;
#   FM_BLOCK_IGNORE_TERM=1    with FM_BLOCK_AT: the waiting shim ignores SIGTERM (its pid is in $FM_BLOCK_DIR/producer.pid);
#   FM_BLOCK_AT=<n>           at read number n write $FM_BLOCK_DIR/blocked.<n> and wait until $FM_BLOCK_DIR/release.<n>
#                             exists (a harness waits on the marker, it never sleeps a fixed time).
add_fd_git_shim() {
  cat > "$1/fakebin/git" <<'SH'
#!/usr/bin/env bash
# A run with a full file table (FM_SCAN_NOFILE) hands this shim a table it cannot fork or open files in; the shim raises its
# own soft limit first so that its log, its count and its stop signal still work.
ulimit -n 4096 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
case " $* " in
  *" --git-common-dir "*)
    case "$2" in
      */pool/fill-*)
        fds=(/dev/fd/*)
        echo "${#fds[@]}" >> "$FM_FD_LOG"
        n=$(wc -l < "$FM_FD_LOG" | tr -d ' ')
        if [ -n "${FM_FDCASE_STOP_AFTER:-}" ] && [ "$n" -ge "$FM_FDCASE_STOP_AFTER" ]; then
          # The leader runs in its own process group (start_scan_teardown), so the group is this run and nothing else.
          kill -TERM -- "-$(cat "$FM_FDCASE_LEADER")" 2>/dev/null
        fi
        if [ -n "${FM_BLOCK_AT:-}" ] && [ "$n" = "$FM_BLOCK_AT" ]; then
          # FM_BLOCK_IGNORE_TERM=1: this stand-in for git is a producer that ignores SIGTERM and never closes its pipe.
          [ -z "${FM_BLOCK_IGNORE_TERM:-}" ] || { trap '' TERM; echo "$$" > "$FM_BLOCK_DIR/producer.pid"; }
          : > "$FM_BLOCK_DIR/blocked.$n"
          waited=0
          while [ ! -e "$FM_BLOCK_DIR/release.$n" ] && [ "$waited" -lt 3000 ]; do
            sleep 0.1
            waited=$((waited + 1))
          done
        fi
        ;;
    esac
    ;;
esac
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  chmod +x "$1/fakebin/git"
}

# start_scan_teardown <case-dir> <bin-dir> [NAME=value ...]: the real teardown of task-x1 in its own process group (its
# leader is the group's only starting member; the pid is in <case-dir>/leader, also SCAN_PID), stdout and stderr in
# <case-dir>/out. FM_SCAN_TRACE=1 in the caller runs it under bash -x with a PS4 naming function and line.
start_scan_teardown() {
  local case_dir=$1 bindir=$2 trace='' kv
  shift 2
  mkdir -p "$case_dir/hhome" "$case_dir/block"
  rm -f "$case_dir/code-root/bin"
  ln -s "$bindir" "$case_dir/code-root/bin"
  : > "$case_dir/fd.log"
  [ "${FM_SCAN_TRACE:-0}" != 1 ] || trace=-x
  (
    export HOME="$case_dir/hhome" FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$case_dir/code-root" FM_STATE_OVERRIDE="$case_dir/state" \
      FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" NM_HOME="$case_dir/nm" \
      PATH="$case_dir/fakebin:$PATH" FM_FD_LOG="$case_dir/fd.log" FM_FDCASE_LEADER="$case_dir/leader" FM_BLOCK_DIR="$case_dir/block" \
      PS4='+${FUNCNAME[0]:-main}:${LINENO}: '
    for kv in "$@"; do export "${kv?}"; done
    # FM_SCAN_NOFILE=<n>: the run's soft limit on open files, so a table that fills up fails a pipe() call at once
    # instead of faulting a fork (a stand-in for a child that died, with no spinner and no signal).
    [ -z "${FM_SCAN_NOFILE:-}" ] || ulimit -n "$FM_SCAN_NOFILE"
    exec python3 -I -c 'import os,sys; os.setpgrp(); os.execv(sys.argv[1], sys.argv[1:])' \
      /bin/bash ${trace:+"$trace"} "$bindir/fm-teardown.sh" task-x1
  ) > "$case_dir/out" 2>&1 < /dev/null &
  SCAN_PID=$!
  printf '%s\n' "$SCAN_PID" > "$case_dir/leader"
}

# finish_scan_teardown <case-dir>: waits for the leader, records its raw status (rc is the shell's, 143 for SIGTERM).
finish_scan_teardown() {
  local rc=0
  wait "$(cat "$1/leader")" || rc=$?
  printf '%s\n' "$rc" > "$1/rc"
}

# run_scan_teardown <case-dir> <bin-dir> [NAME=value ...]: start and wait.
run_scan_teardown() {
  start_scan_teardown "$@"
  finish_scan_teardown "$1"
}

# run_scan_teardown_guarded <case-dir> <bin-dir> <limit> [NAME=value ...]: run_scan_teardown for a run whose file table is
# limited to <limit> (it sets FM_SCAN_NOFILE itself). A run that fills the table and then does not finish is a loop, and
# nothing inside it can stop it, so this harness does: a watcher reads the case's fd log once a second and, when a count
# reaches <limit> - 2 and the leader is still alive 30 seconds later, sends SIGTERM to the leader's own process group
# (the group is that run and nothing else) and writes <case-dir>/guard-fired. The leader's status is in <case-dir>/rc.
run_scan_teardown_guarded() {
  local case_dir=$1 bindir=$2 limit=$3 leader watcher
  shift 3
  start_scan_teardown "$case_dir" "$bindir" "FM_SCAN_NOFILE=$limit" "$@"
  leader=$(cat "$case_dir/leader")
  rm -f "$case_dir/guard-fired"
  (
    while kill -0 "$leader" 2>/dev/null; do
      if [ -s "$case_dir/fd.log" ] && [ "$(sort -n "$case_dir/fd.log" | tail -1)" -ge $((limit - 2)) ]; then
        sleep 30
        if kill -0 "$leader" 2>/dev/null; then
          : > "$case_dir/guard-fired"
          kill -TERM -- "-$leader" 2>/dev/null
        fi
        exit 0
      fi
      sleep 1
    done
  ) > /dev/null 2>&1 &
  watcher=$!
  finish_scan_teardown "$case_dir"
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return 0
}

# wait_for_file <path> [tenths-of-a-second-bound]: polls for the file, no fixed sleep; fails at the bound.
wait_for_file() {
  local n=0 bound=${2:-6000}
  while [ ! -e "$1" ]; do
    n=$((n + 1))
    [ "$n" -le "$bound" ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

# wait_until_clock_passes <seconds>: returns once the wall clock has moved on by that many whole seconds.
wait_until_clock_passes() {
  local end=$(( $(date +%s) + $1 + 1 ))
  while [ "$(date +%s)" -lt "$end" ]; do sleep 0.2; done
}

# project_lock_state <case-dir> [<home>]: "free" when a probe can take the shared Treehouse project lock of the case's project and
# release it at once, "held" when it cannot (the probe never waits). <home> is the FM_HOME of the run (default: the case dir).
project_lock_state() {
  (
    export HOME="$1/hhome" FM_HOME="${2:-$1}"
    mkdir -p "$HOME"
    # shellcheck disable=SC1090,SC1091
    . "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-wake-lib.sh"; . "$ROOT/bin/fm-secondmate-registry-lib.sh"
    . "$ROOT/bin/fm-project-lock-lib.sh"
    lock=$(fm_treehouse_project_lock_path "$1/project") || { echo no-lock-path; exit 0; }
    if fm_project_lock_try "$lock" "scan-bounds probe" >/dev/null 2>&1; then
      fm_project_lock_release "$lock" >/dev/null 2>&1
      echo free
    else
      echo held
    fi
  )
}

# proc_table_pid_ppid_pgid: print "<pid> <ppid> <pgid>" for every visible process.
# Uses ps first (works on Linux and unconfined macOS) and falls back to
# bin/fm-proc-info.py when macOS sandbox-exec refuses setuid ps.
proc_table_pid_ppid_pgid() {
  local out rc=0
  out=$(LC_ALL=C ps -axo pid=,ppid=,pgid= 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  python3 -I "$ROOT/bin/fm-proc-info.py" table pid,ppid,pgid | awk '{ gsub(",", " "); print $1, $2, $3 }'
}

# group_members <pgid>: pids still in that process group.
group_members() {
  proc_table_pid_ppid_pgid | awk -v g="$1" '$3 == g { print $1 }'
}

# normalize_out <case-dir> <file>: paths and pids masked, so two cases compare.
normalize_out() {
  # The guard banner counts the in-flight records and the age of the watcher beat, which follow the fixture size and the clock.
  sed -e "s#$1#CASE#g" -e "s#$TMP_ROOT#TMP#g" -e 's#[0-9]\{4,\}#N#g' \
    -e 's#[0-9][0-9]* task(s) in flight#K task(s) in flight#' -e 's#last beat: [0-9]*s ago#last beat: Ts ago#' "$2"
}

