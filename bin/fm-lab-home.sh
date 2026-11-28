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
#   fm-lab-home.sh primary <dir> <command> [<arg>...]
#                                    start the lab primary on the private socket
#   fm-lab-home.sh record-launch <dir> <task-id> <pid>
#                                    record the process that leads a lab
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
# one `launch<TAB><task-id><TAB><pid><TAB><start time>` line for the process
# that leads an endpoint's session, the start time as `ps -o lstart=` prints it,
# or on Linux the kernel start ticks (/proc stat field 22), which a wall-clock
# step does not change; an exec changes neither. bin/fm-spawn.sh calls it for every tmux
# endpoint in a marked lab home before it types anything there, and refuses the
# launch when the record cannot be written.
# primary is the single entry point for the lab primary: it runs
# `tmux -L fm-lab new-session -d -s primary` on the lab's private socket in the
# caller's directory, with FM_HOME set to the lab and with NO_MISTAKES_GATE,
# FM_GATE_REFUSE_BYPASS, TMUX and every FM_*_OVERRIDE removed so all paths
# resolve inside the lab. The pane first runs a holding shell; primary records
# that shell as task `primary`, and only then lets it exec <command>, so the
# command never runs unrecorded. When the record fails, primary stops the
# session and the holding shell and exits 1.
# teardown keeps the stopped-server proof above, then ends the lab's processes:
# every live process in a recorded session the lab is proven to own, plus each
# live descendant of one. A recorded pid that a live process now holds with
# another start time is a reused pid, so that session is skipped. While a
# recorded leader lives with its recorded start time, its whole session is the
# lab's. Once the leader is gone, its id could have been reused by a session
# outside the lab, so a member is the lab's only when its TMUX environment
# value names a socket in the lab's private socket directory, which tmux sets
# in every lab pane; any other member of that session is never signalled and
# makes teardown exit 1 naming its pid. Process names, cwds and parents never
# decide. This process, its ancestors and its descendants are never signalled.
# Each target gets CONT and TERM, then KILL once 2 seconds have passed, each
# signal only while the target's start time matches the one the membership
# read's process table gave; a process that joins a recorded session meanwhile
# gets the same. A lab process still alive once 5 more seconds have passed, or a
# process list or session id that cannot be read, makes teardown exit 1 naming
# each pid, with the socket directory and the launch record kept for a retry.
# Each round also rereads the process table and every target's start time, so a
# large lab takes that much longer than 7 seconds. A complete reap removes the
# launch record, so a later teardown signals nothing; a lab with no launch
# record gets the stopped-server proof alone.
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
# fm_lab_home_lstart <pid>: the process's start time, as `ps -o lstart=` prints it.
fm_lab_home_lstart() {
  local start rc
  start=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 126 ]; then
    start=$(python3 "$SCRIPT_DIR/fm-proc-info.py" lstart "$1" 2>/dev/null) || return 1
  elif [ "$rc" -ne 0 ]; then
    return 1
  fi
  start=$(printf '%s\n' "$start" | awk '{$1=$1; print}')
  [ -n "$start" ] || return 1
  printf '%s\n' "$start"
}
# fm_lab_home_start <pid>: the start time a launch record holds, the kernel's
# start ticks (/proc stat field 22) on Linux, where a wall-clock step changes lstart.
fm_lab_home_start() {
  local stat
  [ "$(uname -s)" = Linux ] || { fm_lab_home_lstart "$1"; return; }
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  # shellcheck disable=SC2086 # The fields after the command name split on purpose.
  set -- ${stat##*)}
  case "${20:-}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "${20}"
}

# fm_lab_home_sessions <dir>: print each recorded session id the lab still owns
# as <id>:live while its recorded leader lives, or <id>:gone once it has exited.
fm_lab_home_sessions() {
  local record tag id pid start current seen=' '
  record=$(fm_lab_home_launch_record "$1")
  [ -f "$record" ] || return 0
  while IFS=$'\t' read -r tag id pid start; do
    [ "$tag" = launch ] && [ -n "$id" ] && [ -n "$start" ] || return 1
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
    case "$seen" in *" $pid "*) continue ;; esac
    if current=$(fm_lab_home_start "$pid"); then
      [ "$current" = "$start" ] || continue
      printf '%s:live\n' "$pid"
    else
      printf '%s:gone\n' "$pid"
    fi
    seen="$seen$pid "
  done < "$record"
}

# The session reader: argv[1] holds the <id>:<live|gone> sessions, argv[2] this
# script's pid, argv[3] the lab's private socket directory (may be empty), stdin
# a `pid ppid stat lstart` table. It prints `+ <pid> <lstart>` for every
# non-zombie member of a live session, every member of a gone session whose TMUX
# names a socket in that directory, and each live descendant of one, and
# `? <pid>` for every other member of a gone session. It never prints this
# script, an ancestor or a descendant of it, and exits 1 when the table or a
# session id cannot be read.
IFS= read -r -d '' FM_LAB_HOME_MEMBERS_PY <<'PY' || true
import ctypes, errno, os, struct, sys
sessions = dict(s.split(":") for s in sys.argv[1].split())
sessions = {int(k): v for k, v in sessions.items()}
me = int(sys.argv[2])
lab = os.path.realpath(sys.argv[3]) if sys.argv[3] else None
libc = ctypes.CDLL(None, use_errno=True)
def environ(pid):
    if os.path.isdir("/proc/self"):
        with open("/proc/%d/environ" % pid, "rb") as f:
            return f.read().split(b"\0")
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0):
        raise OSError(ctypes.get_errno(), "sysctl")
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0):
        raise OSError(ctypes.get_errno(), "sysctl")
    data = buf.raw[:size.value]
    argc = struct.unpack_from("i", data, 0)[0]
    return data[4:].split(b"\0", 1)[1].lstrip(b"\0").split(b"\0")[argc:]
def in_lab(pid):
    if lab is None:
        return False
    try:
        words = environ(pid)
    except (OSError, LookupError, struct.error, IndexError):
        return False
    for word in words:
        if word.startswith(b"TMUX="):
            socket = os.fsdecode(word[5:].split(b",", 1)[0])
            return os.path.dirname(os.path.dirname(socket)) == lab
    return False
parent, zombie, children, start = {}, set(), {}, {}
for line in sys.stdin:
    f = line.split()
    if len(f) < 8 or not f[0].isdigit() or not f[1].isdigit():
        continue
    pid, ppid = int(f[0]), int(f[1])
    parent[pid] = ppid
    start[pid] = " ".join(f[3:8])
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
def sid_of(pid):
    try:
        return os.getsid(pid)
    except OSError as exc:
        if exc.errno == errno.ESRCH:
            return None
        sys.exit(1)
members, unproven = set(), set()
for pid in parent:
    if pid in protected or pid in zombie or pid <= 1:
        continue
    sid = sid_of(pid)
    if sid not in sessions:
        continue
    if sessions[sid] == "live" or in_lab(pid):
        members.add(pid)
    elif sid_of(pid) == sid:
        unproven.add(pid)
stack = list(members)
while stack:
    for child in children.get(stack.pop(), []):
        if child not in members and child not in protected and child not in zombie:
            members.add(child)
            stack.append(child)
for pid in sorted(members):
    print("+ %d %s" % (pid, start[pid]))
for pid in sorted(unproven - members):
    print("? %d" % pid)
PY

# fm_lab_home_members <sessions> <socket-dir>: print the session reader's lines;
# fails when the process list or a session id cannot be read.
fm_lab_home_members() {
  local table rc
  table=$(LC_ALL=C ps -A -o pid=,ppid=,stat=,lstart= 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 126 ]; then
    # A confined caller's sandbox refuses setuid ps; fm-proc-info.py reads sysctl.
    table=$(python3 "$SCRIPT_DIR/fm-proc-info.py" table pid,ppid,stat,lstart 2>/dev/null) || return 1
  elif [ "$rc" -ne 0 ]; then
    return 1
  fi
  [ -n "$table" ] || return 1
  printf '%s\n' "$table" | python3 -I -c "$FM_LAB_HOME_MEMBERS_PY" "$1" "$$" "$2"
}

# measured: value=2 date=2026-11-24 host=Mac-Studio margin=625 (a reproduced lab launcher exited at most 0.0032 s after TERM over 20 trials; a real agent's TERM shutdown was not measured, and 2 s matches bin/fm-test-reap-orphans.sh's grace)
FM_LAB_HOME_TERM_SECONDS=2
# measured: value=5 date=2026-11-24 host=Mac-Studio margin=1064 (the TERM-ignoring treehouse subshell exited at most 0.0047 s after KILL over 20 trials; only a process KILL cannot end waits this long)
FM_LAB_HOME_KILL_SECONDS=5

# fm_lab_home_alive <index>: the tracked target still has the start time first read.
fm_lab_home_alive() {
  [ "$(fm_lab_home_lstart "${REAP_PIDS[$1]}" 2>/dev/null || true)" = "${REAP_IDENTS[$1]}" ]
}

# fm_lab_home_describe <pid>...: one `pid ppid command` line per pid.
fm_lab_home_describe() {
  local pid line
  for pid in $(printf '%s\n' "$@" | sort -un); do
    line=$(LC_ALL=C ps -o pid=,ppid=,command= -p "$pid" 2>/dev/null) ||
      line="$pid $(python3 "$SCRIPT_DIR/fm-proc-info.py" ppid "$pid" 2>/dev/null) $(python3 "$SCRIPT_DIR/fm-proc-info.py" args "$pid" 2>/dev/null)"
    printf '\n  %s' "$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-200)"
  done
}

# fm_lab_home_reap <dir>: end every process in a session the lab recorded (header).
fm_lab_home_reap() {
  local dir=$1 sessions socket='' out members unproven pid start i phase=soft deadline survivors rc=0
  REAP_PIDS=()
  REAP_IDENTS=()
  [ -e "$(fm_lab_home_launch_record "$dir")" ] || return 0
  sessions=$(fm_lab_home_sessions "$dir") || {
    fm_lab_home_error "refusing teardown: the lab launch record $(fm_lab_home_launch_record "$dir") is unreadable"
    return 1
  }
  sessions=$(printf '%s' "$sessions" | tr '\n' ' ')
  [ -n "${sessions// /}" ] || { rm -f "$(fm_lab_home_launch_record "$dir")"; return 0; }
  [ ! -f "$(fm_lab_home_tmux_record "$dir")" ] || socket=$(cat "$(fm_lab_home_tmux_record "$dir")")
  deadline=$((SECONDS + FM_LAB_HOME_TERM_SECONDS))
  while :; do
    out=$(fm_lab_home_members "$sessions" "$socket") || {
      fm_lab_home_error "refusing teardown: cannot read the process list or session ids, so the lab's processes cannot be proven ended (recorded sessions: $sessions)"
      return 1
    }
    members=$(printf '%s\n' "$out" | sed -n 's/^+ \([0-9]*\) .*/\1/p')
    unproven=$(printf '%s\n' "$out" | sed -n 's/^? //p')
    while read -r pid start; do
      [ -n "$pid" ] || continue
      i=0
      while [ "$i" -lt "${#REAP_PIDS[@]}" ] && [ "${REAP_PIDS[$i]} ${REAP_IDENTS[$i]}" != "$pid $start" ]; do i=$((i + 1)); done
      [ "$i" -eq "${#REAP_PIDS[@]}" ] || continue
      REAP_PIDS+=("$pid")
      REAP_IDENTS+=("$start")
      fm_lab_home_alive "$i" || continue
      kill -CONT "$pid" 2>/dev/null || true
      if fm_lab_home_alive "$i"; then
        if [ "$phase" = soft ]; then kill -TERM "$pid" 2>/dev/null || true; else kill -KILL "$pid" 2>/dev/null || true; fi
      fi
    done <<< "$(printf '%s\n' "$out" | sed -n 's/^+ //p')"
    survivors=
    i=0
    while [ "$i" -lt "${#REAP_PIDS[@]}" ]; do
      ! fm_lab_home_alive "$i" || survivors="$survivors ${REAP_PIDS[$i]}"
      i=$((i + 1))
    done
    [ -n "$survivors$members" ] || break
    if [ "$phase" = soft ] && [ "$SECONDS" -ge "$deadline" ]; then
      phase=hard
      deadline=$((SECONDS + FM_LAB_HOME_KILL_SECONDS))
      i=0
      while [ "$i" -lt "${#REAP_PIDS[@]}" ]; do
        ! fm_lab_home_alive "$i" || kill -KILL "${REAP_PIDS[$i]}" 2>/dev/null || true
        i=$((i + 1))
      done
    elif [ "$phase" = hard ] && [ "$SECONDS" -ge "$deadline" ]; then
      # shellcheck disable=SC2086 # Each pid is one word.
      fm_lab_home_error "refusing teardown: lab processes did not exit after TERM and KILL (pid ppid command):$(fm_lab_home_describe $survivors $members)"
      rc=1
      break
    fi
    sleep 0.2
  done
  if [ -n "$unproven" ]; then
    # shellcheck disable=SC2086 # Each pid is one word.
    fm_lab_home_error "refusing teardown: these processes hold a recorded session whose leader is gone, but their TMUX names no socket in the lab's private socket directory, so they were not signalled (pid ppid command):$(fm_lab_home_describe $unproven)"
    rc=1
  fi
  [ "$rc" -ne 0 ] || rm -f "$(fm_lab_home_launch_record "$dir")"
  return "$rc"
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
  primary)
    dir=${2:-}
    [ "$#" -ge 3 ] && [ -n "$dir" ] && [ -n "$3" ] || { fm_lab_home_error "primary requires a marked lab home and a command"; exit 2; }
    shift 2
    fm_lab_home_marked "$dir" || { fm_lab_home_error "refusing '$dir': not a marked lab home"; exit 1; }
    dir=$(cd -P -- "$dir" && pwd -P) || exit 1
    socket_dir=$("$SCRIPT_DIR/fm-lab-home.sh" tmux-dir "$dir") || exit 1
    go="$dir/state/.fm-lab-primary-go.$$"
    rm -f "$go"
    # The holding shell waits while this process lives and execs the command
    # only once the go file exists, which this process writes after the record.
    # shellcheck disable=SC2016 # The holding shell expands its own arguments.
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX TMUX_TMPDIR="$socket_dir" \
      tmux -L fm-lab new-session -d -s primary -c "$PWD" -e FM_HOME="$dir" \
      /bin/sh -c 'while [ ! -e "$2" ] && kill -0 "$1" 2>/dev/null; do sleep 0.05; done; [ -e "$2" ] || exit 1; rm -f "$2"; shift 2; exec "$@"' \
      fm-lab-primary "$$" "$go" "$@" || { fm_lab_home_error "cannot start the lab primary session"; exit 1; }
    pid=$(TMUX_TMPDIR="$socket_dir" tmux -L fm-lab display-message -p -t primary '#{pane_pid}' 2>/dev/null) || pid=
    if ! "$SCRIPT_DIR/fm-lab-home.sh" record-launch "$dir" primary "$pid"; then
      TMUX_TMPDIR="$socket_dir" tmux -L fm-lab kill-session -t primary 2>/dev/null || true
      fm_lab_home_error "refusing to start the lab primary: its session could not be recorded, so its command was not run"
      exit 1
    fi
    : > "$go" || { fm_lab_home_error "cannot release the recorded lab primary (pane pid $pid)"; exit 1; }
    printf 'lab primary started: pane pid %s, session primary on %s\n' "$pid" "$socket_dir/tmux-$(id -u)/fm-lab"
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
    start=$(fm_lab_home_start "$pid") || {
      fm_lab_home_error "refusing to launch task $id in lab '$dir': the start time of its endpoint shell (pid $pid) is unreadable, so teardown could not reap what it starts"
      exit 1
    }
    printf 'launch\t%s\t%s\t%s\n' "$id" "$pid" "$start" >> "$(fm_lab_home_launch_record "$dir")" || {
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
    fm_lab_home_error "usage: fm-lab-home.sh env | create <dir> | tmux-dir <dir> | primary <dir> <command> [<arg>...] | record-launch <dir> <task-id> <pid> | teardown <dir>"
    exit 2
    ;;
esac
