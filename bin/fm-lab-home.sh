#!/usr/bin/env bash
# fm-lab-home.sh - mint a disposable firstmate "lab" home.
#
# A lab home is a throwaway FM_HOME that a no-mistakes GATE agent may drive
# through the fleet lifecycle entrypoints: bin/fm-gate-refuse-lib.sh refuses
# those calls inside a gate agent unless FM_HOME carries the marker file this
# helper writes (the lib owns the gate token and authorization decision;
# bin/fm-test-reap-orphans.sh owns the reaping provenance requirements, and
# this script is the supported writer).
#
# Usage:
#   fm-lab-home.sh env               mint a marked lab home and print the
#                                    FM_HOME and TMUX_TMPDIR exports to eval
#   fm-lab-home.sh create <dir>       make a marked lab home and print its
#                                    canonical path
#   fm-lab-home.sh tmux-dir <dir>     create or print its private tmux socket dir
#   fm-lab-home.sh record-launch <dir> <task-id> <pid>
#                                    record the shell that leads a lab worker
#                                    endpoint's session
#   fm-lab-home.sh teardown <dir>     end every process in a recorded session,
#                                    then remove its private tmux socket dir
#
# A lab home must live outside every git work tree: an agent running inside a
# lab inside the repository writes scratch files there, and a catch-all stage
# step then commits them. create refuses such a directory; use
# mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX".
# A lab home is the stock layout only - state/, data/, config/, projects/ - and
# callers remove it with ordinary rm -rf when done. Drive it with plain
# FM_HOME=<dir>; any FM_*_OVERRIDE relocation defeats the allowance.
# tmux-dir is the single owner of the short private socket directory: callers
# use TMUX_TMPDIR=<printed-dir> and call teardown from their cleanup trap after
# killing only the server addressed through that directory.
# env is the one-command form of the supported setup: it mints a fresh lab home
# plus its private socket directory and prints `export FM_HOME=...` and
# `export TMUX_TMPDIR=...`, so a caller evals it once per scenario shell instead
# of composing mktemp, create, and a mkdir for tmux. It repeats both exports and
# prints the teardown line, with literal paths, on stderr so they stay visible
# past the eval for a caller whose next command runs in a fresh shell, and it is
# the recipe the gate-context refusal names; never re-express it
# in prose somewhere else.
# A refused teardown reports the tmux probe's exit status and stderr while
# retaining the socket directory and its durable ownership record.
#
# Lab processes. Stopping the lab tmux server does not stop a lab worker:
# bin/fm-spawn.sh runs it as a job of the `treehouse get` subshell, and that
# job's process group received no SIGHUP when the server was killed (measured
# 2026-11-24 on macOS: the launcher, its stand-in agent and the subshell all
# kept running with parent pid 1 and no terminal). What still ties them to the
# lab is their session: every process started in a pane keeps the session id of
# the pane's shell. record-launch is the single writer of state/.fm-lab-launches,
# one `launch<TAB><task-id><TAB><pid><TAB><sha256 of fm_pid_identity>` line for
# the shell that leads an endpoint's session. bin/fm-spawn.sh calls it for every
# tmux endpoint in a marked lab home before it types anything there, and refuses
# the launch when the record cannot be written.
# teardown keeps the stopped-server proof above, then ends the lab's processes:
# every live process whose session id is a recorded pid, plus each live
# descendant of one. A recorded pid that a live process now holds with another
# identity is a reused pid, so that session is skipped. A recorded leader that
# is gone is taken to have left its session behind; this assumes the kernel
# never hands out a pid that is still a live session id (unverified here), and a
# record that outlives every member of its session could match a later session
# that reuses the id once its own leader has also exited. Process names, paths
# and parents never decide. This process, its ancestors and its descendants are
# never signalled. Each target gets CONT and TERM, then KILL once 2 seconds
# have passed, each signal only while the target's identity matches the one
# first read; a process that joins a recorded session meanwhile gets the same.
# A lab process still alive once 5 more seconds have passed, or a process list
# or session id that cannot be read, makes teardown exit 1 naming each pid, with
# the socket directory and the launch record kept for a retry. Each round also
# rereads the process table and every target's identity, so a large lab takes
# that much longer than 7 seconds. A complete reap removes the launch record,
# so a later teardown signals nothing; a lab with no launch record gets the
# stopped-server proof alone.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

fm_lab_home_error() {
  echo "fm-lab-home: $*" >&2
}

fm_lab_home_tmux_record() { printf '%s/state/.fm-lab-tmux-dir' "$1"; }
fm_lab_home_mode() {
  case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac
}
fm_lab_home_owner() {
  case "$(uname -s)" in Darwin) stat -f '%u' "$1" ;; *) stat -c '%u' "$1" ;; esac
}
fm_lab_home_launch_record() { printf '%s/state/.fm-lab-launches' "$1"; }
fm_lab_home_marked() {
  [ -f "$1/.fm-lab-home" ] && [ -d "$1/state" ]
}
fm_lab_home_wake_lib() {
  command -v fm_pid_identity >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  FM_STATE_OVERRIDE="$1/state" . "$SCRIPT_DIR/fm-wake-lib.sh"
}
# fm_lab_home_identity <pid>: the sha256 of the process's fm_pid_identity.
fm_lab_home_identity() {
  local identity
  identity=$(fm_pid_identity "$1" 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\n' "$identity" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s\n' "$identity" | sha256sum | awk '{print $1}'
  fi
}

# fm_lab_home_sessions <dir>: print the recorded session ids the lab still owns.
fm_lab_home_sessions() {
  local record tag id pid digest current seen=' '
  record=$(fm_lab_home_launch_record "$1")
  [ -f "$record" ] || return 0
  while IFS=$'\t' read -r tag id pid digest; do
    [ "$tag" = launch ] && [ -n "$id" ] && [ -n "$digest" ] || return 1
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
    case "$seen" in *" $pid "*) continue ;; esac
    seen="$seen$pid "
    if current=$(fm_lab_home_identity "$pid"); then
      [ "$current" = "$digest" ] || continue
    fi
    printf '%s\n' "$pid"
  done < "$record"
}

# The session reader: argv[1] holds the session ids, argv[2] this script's pid,
# stdin a `pid ppid stat` table. It prints every non-zombie member of those
# sessions and each live descendant of one, never this script, an ancestor or a
# descendant of it, and exits 1 when the table or a session id cannot be read.
IFS= read -r -d '' FM_LAB_HOME_MEMBERS_PY <<'PY' || true
import errno, os, sys
sessions = {int(s) for s in sys.argv[1].split()}
me = int(sys.argv[2])
parent, zombie, children = {}, set(), {}
for line in sys.stdin:
    f = line.split()
    if len(f) < 3 or not f[0].isdigit() or not f[1].isdigit():
        continue
    pid, ppid = int(f[0]), int(f[1])
    parent[pid] = ppid
    children.setdefault(ppid, []).append(pid)
    if f[2].startswith("Z"):
        zombie.add(pid)
if me not in parent:
    sys.exit(1)
protected, p = set(), me
while p > 1 and p in parent and p not in protected:
    protected.add(p)
    p = parent[p]
stack = [me]
while stack:
    for child in children.get(stack.pop(), []):
        if child not in protected:
            protected.add(child)
            stack.append(child)
members = set()
for pid in parent:
    if pid in protected or pid in zombie or pid <= 1:
        continue
    try:
        sid = os.getsid(pid)
    except OSError as exc:
        if exc.errno == errno.ESRCH:
            continue
        sys.exit(1)
    if sid in sessions:
        members.add(pid)
stack = list(members)
while stack:
    for child in children.get(stack.pop(), []):
        if child not in members and child not in protected and child not in zombie:
            members.add(child)
            stack.append(child)
for pid in sorted(members):
    print(pid)
PY

# fm_lab_home_members <session-ids>: print the live lab processes; fails when the
# process list or a session id cannot be read.
fm_lab_home_members() {
  local table rc
  table=$(LC_ALL=C ps -A -o pid=,ppid=,stat= 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 126 ]; then
    # A confined caller's sandbox refuses setuid ps; fm-proc-info.py reads sysctl.
    table=$(python3 "$SCRIPT_DIR/fm-proc-info.py" table pid,ppid,stat 2>/dev/null) || return 1
  elif [ "$rc" -ne 0 ]; then
    return 1
  fi
  [ -n "$table" ] || return 1
  printf '%s\n' "$table" | python3 -I -c "$FM_LAB_HOME_MEMBERS_PY" "$1" "$$"
}

# measured: value=2 date=2026-11-24 host=Mac-Studio margin=625 (a reproduced lab launcher exited at most 0.0032 s after TERM over 20 trials; a real agent's TERM shutdown was not measured, and 2 s matches bin/fm-test-reap-orphans.sh's grace)
FM_LAB_HOME_TERM_SECONDS=2
# measured: value=5 date=2026-11-24 host=Mac-Studio margin=1064 (the TERM-ignoring treehouse subshell exited at most 0.0047 s after KILL over 20 trials; only a process KILL cannot end waits this long)
FM_LAB_HOME_KILL_SECONDS=5

# fm_lab_home_alive <index>: the tracked target still has the identity first read.
fm_lab_home_alive() {
  [ -n "${REAP_IDENTS[$1]}" ] && [ "$(fm_pid_identity "${REAP_PIDS[$1]}" 2>/dev/null || true)" = "${REAP_IDENTS[$1]}" ]
}

# fm_lab_home_reap <dir>: end every process in a session the lab recorded (header).
fm_lab_home_reap() {
  local dir=$1 sessions members pid i phase=soft deadline survivors line details=''
  REAP_PIDS=()
  REAP_IDENTS=()
  [ -e "$(fm_lab_home_launch_record "$dir")" ] || return 0
  fm_lab_home_wake_lib "$dir" || { fm_lab_home_error "refusing teardown: cannot load the process identity reader"; return 1; }
  sessions=$(fm_lab_home_sessions "$dir") || {
    fm_lab_home_error "refusing teardown: the lab launch record $(fm_lab_home_launch_record "$dir") is unreadable"
    return 1
  }
  sessions=$(printf '%s' "$sessions" | tr '\n' ' ')
  [ -n "${sessions// /}" ] || { rm -f "$(fm_lab_home_launch_record "$dir")"; return 0; }
  deadline=$((SECONDS + FM_LAB_HOME_TERM_SECONDS))
  while :; do
    members=$(fm_lab_home_members "$sessions") || {
      fm_lab_home_error "refusing teardown: cannot read the process list or session ids, so the lab's processes cannot be proven ended (recorded sessions: $sessions)"
      return 1
    }
    for pid in $members; do
      i=0
      while [ "$i" -lt "${#REAP_PIDS[@]}" ] && [ "${REAP_PIDS[$i]}" != "$pid" ]; do i=$((i + 1)); done
      [ "$i" -eq "${#REAP_PIDS[@]}" ] || continue
      REAP_PIDS+=("$pid")
      REAP_IDENTS+=("$(fm_pid_identity "$pid" 2>/dev/null || true)")
      fm_lab_home_alive "$i" || continue
      kill -CONT "$pid" 2>/dev/null || true
      if fm_lab_home_alive "$i"; then
        if [ "$phase" = soft ]; then kill -TERM "$pid" 2>/dev/null || true; else kill -KILL "$pid" 2>/dev/null || true; fi
      fi
    done
    survivors=
    i=0
    while [ "$i" -lt "${#REAP_PIDS[@]}" ]; do
      ! fm_lab_home_alive "$i" || survivors="$survivors ${REAP_PIDS[$i]}"
      i=$((i + 1))
    done
    [ -n "$survivors$members" ] || { rm -f "$(fm_lab_home_launch_record "$dir")"; return 0; }
    if [ "$phase" = soft ] && [ "$SECONDS" -ge "$deadline" ]; then
      phase=hard
      deadline=$((SECONDS + FM_LAB_HOME_KILL_SECONDS))
      i=0
      while [ "$i" -lt "${#REAP_PIDS[@]}" ]; do
        ! fm_lab_home_alive "$i" || kill -KILL "${REAP_PIDS[$i]}" 2>/dev/null || true
        i=$((i + 1))
      done
    elif [ "$phase" = hard ] && [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    sleep 0.2
  done
  for pid in $(printf '%s %s' "$survivors" "$members" | tr ' ' '\n' | sort -un); do
    line=$(LC_ALL=C ps -o pid=,ppid=,command= -p "$pid" 2>/dev/null) ||
      line="$pid $(python3 "$SCRIPT_DIR/fm-proc-info.py" ppid "$pid" 2>/dev/null) $(python3 "$SCRIPT_DIR/fm-proc-info.py" args "$pid" 2>/dev/null)"
    details="$details"$'\n'"  $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-200)"
  done
  fm_lab_home_error "refusing teardown: lab processes did not exit after TERM and KILL (pid ppid command):$details"
  return 1
}

case "${1:-}" in
  env)
    base=${TMPDIR:-/tmp}
    base=${base%/}
    dir=$(mktemp -d "$base/fm-lab.XXXXXX") || exit 1
    lab=$("$SCRIPT_DIR/fm-lab-home.sh" create "$dir") || { rmdir "$dir" 2>/dev/null || true; exit 1; }
    socket=$("$SCRIPT_DIR/fm-lab-home.sh" tmux-dir "$lab") || { rm -rf "$lab"; exit 1; }
    exports=$(printf 'export FM_HOME=%q\nexport TMUX_TMPDIR=%q' "$lab" "$socket")
    printf '%s\n' "$exports"
    printf '%s\n' "$exports" >&2
    printf 'fm-lab-home: teardown: %q teardown %q && rm -rf %q\n' "$SCRIPT_DIR/fm-lab-home.sh" "$lab" "$lab" >&2
    ;;
  create)
    dir=${2:-}
    [ -n "$dir" ] || { fm_lab_home_error "create requires a directory path"; exit 2; }
    if [ -e "$dir" ] && [ ! -d "$dir" ]; then
      fm_lab_home_error "refusing '$dir': exists and is not a directory"
      exit 1
    fi
    probe=$dir
    case "$probe" in /*) ;; *) probe="$PWD/$probe" ;; esac
    while [ ! -d "$probe" ]; do
      probe=$(dirname "$probe")
    done
    if env -u GIT_DIR -u GIT_WORK_TREE git -C "$probe" rev-parse --show-toplevel >/dev/null 2>&1; then
      fm_lab_home_error "refusing '$dir': a lab home must live outside the repository; use mktemp -d \"\${TMPDIR:-/tmp}/fm-lab.XXXXXX\""
      exit 1
    fi
    mkdir -p "$dir" || exit 1
    dir=$(cd -P -- "$dir" && pwd -P) || exit 1
    fm_gate_lab_mark "$dir" || {
      fm_lab_home_error "refusing '$dir': a lab marker is only ever stamped on a fresh empty dir"
      exit 1
    }
    # shellcheck source=bin/fm-wake-lib.sh
    FM_STATE_OVERRIDE="$dir" . "$SCRIPT_DIR/fm-wake-lib.sh"
    owner_identity=$(fm_pid_identity "$PPID") || { fm_lab_home_error "cannot identify the lab owner"; exit 1; }
    printf 'owner_pid=%s\nowner_identity=%s\n' "$PPID" "$owner_identity" >> "$dir/.fm-lab-home" || exit 1
    mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects" || exit 1
    printf '%s\n' "$dir"
    ;;
  tmux-dir)
    dir=${2:-}
    [ -n "$dir" ] || { fm_lab_home_error "tmux-dir requires a marked lab home"; exit 2; }
    [ -f "$dir/.fm-lab-home" ] && [ -d "$dir/state" ] \
      || { fm_lab_home_error "refusing '$dir': not a marked lab home"; exit 1; }
    record=$(fm_lab_home_tmux_record "$dir")
    if [ -f "$record" ]; then
      socket_dir=$(cat "$record")
      case "$socket_dir" in /tmp/fml.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) fm_lab_home_error "invalid recorded tmux directory"; exit 1 ;; esac
      [ -d "$socket_dir" ] && [ ! -L "$socket_dir" ] \
        || { fm_lab_home_error "recorded tmux directory is missing or unsafe"; exit 1; }
      [ "$(fm_lab_home_mode "$socket_dir")" = 700 ] && [ "$(fm_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
        || { fm_lab_home_error "recorded tmux directory is not private and user-owned"; exit 1; }
    else
      socket_dir=$(mktemp -d /tmp/fml.XXXXXX) || exit 1
      chmod 700 "$socket_dir" || { rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
      [ "$(fm_lab_home_mode "$socket_dir")" = 700 ] && [ "$(fm_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
        || { rmdir "$socket_dir" 2>/dev/null || true; fm_lab_home_error "cannot secure tmux directory"; exit 1; }
      (umask 077; printf '%s\n' "$socket_dir" > "$record") || { rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
      chmod 600 "$record" || { rm -f "$record"; rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
    fi
    printf '%s\n' "$socket_dir"
    ;;
  record-launch)
    dir=${2:-} id=${3:-} pid=${4:-}
    { [ -n "$dir" ] && [ -n "$id" ]; } || { fm_lab_home_error "record-launch requires a marked lab home, a task id and a pid"; exit 2; }
    fm_lab_home_marked "$dir" || { fm_lab_home_error "refusing '$dir': not a marked lab home"; exit 1; }
    case "$id" in *[!A-Za-z0-9._-]*) fm_lab_home_error "record-launch: invalid task id '$id'"; exit 2 ;; esac
    case "$pid" in
      ''|*[!0-9]*|0|1)
        fm_lab_home_error "refusing to launch task $id in lab '$dir': its endpoint shell pid is unreadable ('$pid'), so teardown could not reap what it starts"
        exit 1
        ;;
    esac
    fm_lab_home_wake_lib "$dir" || exit 1
    digest=$(fm_lab_home_identity "$pid") || {
      fm_lab_home_error "refusing to launch task $id in lab '$dir': the identity of its endpoint shell (pid $pid) is unreadable, so teardown could not reap what it starts"
      exit 1
    }
    printf 'launch\t%s\t%s\t%s\n' "$id" "$pid" "$digest" >> "$(fm_lab_home_launch_record "$dir")" || {
      fm_lab_home_error "refusing to launch task $id in lab '$dir': cannot write $(fm_lab_home_launch_record "$dir")"
      exit 1
    }
    ;;
  teardown)
    dir=${2:-}
    [ -n "$dir" ] || { fm_lab_home_error "teardown requires a marked lab home"; exit 2; }
    [ -f "$dir/.fm-lab-home" ] && [ -d "$dir/state" ] \
      || { fm_lab_home_error "refusing '$dir': not a marked lab home"; exit 1; }
    record=$(fm_lab_home_tmux_record "$dir")
    if [ ! -f "$record" ]; then
      fm_lab_home_reap "$dir" || exit 1
      exit 0
    fi
    socket_dir=$(cat "$record")
    case "$socket_dir" in /tmp/fml.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) fm_lab_home_error "invalid recorded tmux directory"; exit 1 ;; esac
    [ -d "$socket_dir" ] && [ ! -L "$socket_dir" ] \
      || { fm_lab_home_error "recorded tmux directory is missing or unsafe"; exit 1; }
    [ "$(fm_lab_home_mode "$socket_dir")" = 700 ] && [ "$(fm_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
      || { fm_lab_home_error "refusing to remove a non-private or non-user-owned tmux directory"; exit 1; }
    # -L names its own socket (not "default"); inspect every socket this
    # private TMUX_TMPDIR could have hosted before removing the directory.
    for socket in "$socket_dir/tmux-$(id -u)"/*; do
      [ -e "$socket" ] || [ -L "$socket" ] || continue
      if probe=$(tmux -S "$socket" list-sessions 2>&1 >/dev/null); then
        probe_status=0
      else
        probe_status=$?
      fi
      if [ "$probe_status" -eq 0 ] || [ "${probe#*no server running}" = "$probe" ]; then
        fm_lab_home_error "refusing teardown: cannot confirm the lab tmux server has stopped (tmux probe exit=$probe_status)"
        [ -z "$probe" ] || printf '%s\n' "$probe" >&2
        exit 1
      fi
    done
    fm_lab_home_reap "$dir" || exit 1
    rm -rf "$socket_dir" && rm -f "$record"
    ;;
  *)
    fm_lab_home_error "usage: fm-lab-home.sh env | create <dir> | tmux-dir <dir> | record-launch <dir> <task-id> <pid> | teardown <dir>"
    exit 2
    ;;
esac
