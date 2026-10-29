#!/usr/bin/env bash
# fm-proc-budget.sh - run a command tree under a per-tree process budget.
#
# Usage:
#   fm-proc-budget.sh [<extra>] [--memory-kib <KiB> | --own-procs <N>] -- <command...>
#   fm-proc-budget.sh --memory-kib 2097152 -- <command...>  2 GiB memory stop
#   fm-proc-budget.sh --own-procs 128 -- <command...>       128-process tree stop
#
# --own-procs stops a runaway tree by counting only the tree's own processes,
# never the user's whole count, so neighbour lanes cannot spend its budget.
# Harm: a tree that forks without end starves every other process of the user.
# Observable: the number of members of the command's tree, sampled five times a
# second by bin/fm-proc-budget-tree.py (its header owns the tree definition).
# Past <N> members the tree is frozen, then killed, and the wrapper exits 98
# with one stderr line naming the count and the limit. An unreadable sample is
# skipped and tried again next sample; it never ends the command. Only the
# first sample, taken before the command starts, refuses the launch (125). The
# kernel limit below stays in force at its default as the safety net, so a
# tree that outruns the sampling still meets it. Zombies of the tree count,
# threads do not, and the command runs as a background job for a terminal
# exactly as it does with --memory-kib. A supervisor that dies leaves the
# command running under the kernel limit only. It works on Linux and Darwin.
# Pass it instead of a small <extra>: a small positive <extra> below counts the
# whole user and is the form that neighbour lanes starve.
#
# --memory-kib adds an opt-in sampled hard stop: once per second, sum the
# command tree's resident memory and physical footprint, in KiB (1024 bytes),
# and compare the larger sum with the positive decimal limit. The command runs
# in a new process group that it leads, so the tree is that whole group, even
# a background job orphaned before the first sample, plus each descendant a
# sample has seen in another group or session, including nested wrappers. The
# only gap: a process that leaves the group (setsid or setpgid, as a daemon's
# double fork does) and that no sample has seen before its parent exits is not
# tracked; it escapes the stop and every cleanup below. Being outside the
# caller's group, the command is a background job for a terminal: Ctrl-C
# reaches the supervisor, which ends the tree, and a command that reads the
# terminal is stopped.
# The memory reader joins the command's group and reads a pipe that only the
# supervisor writes; if the supervisor dies (for example SIGKILL from a kill of
# the caller's group), the reader sends the group and every member a sample has
# seen TERM, then KILL after at most one second. The command itself starts only
# after the reader has answered a first sample; a supervisor that dies sooner
# leaves no command running. Crossing the limit STOPs and re-scans the tree
# before KILLing every member, then exits 99 with one stderr line naming the
# limit and sample. This is not a kernel allocation ceiling: memory can
# overshoot between samples. A failed, malformed, or late memory sample ends the
# tree and exits 125, as does a member of this user whose memory cannot be read, or a sample in
# which no member's memory can be read. A member running as another user (a
# setuid program such as ps) whose memory cannot be read is left out of the sum;
# a 99 or 125 stderr line counts and names such members.
# When the command itself exits, its remaining tree gets TERM, then KILL after
# at most one second, and successful cleanup preserves the command's status.
# A command meant to leave a daemon running must not use this option. HUP, INT
# and TERM that the caller ignores (nohup) stay ignored by the supervisor and
# the command; the command gets default PIPE and XFSZ handling, because Python
# discards an inherited ignore of those two before the supervisor can see it.
# The libproc reader is checked before launch; an unsupported host (currently
# any non-Darwin host) or unavailable reader refuses to start with status 125.
# No ps memory sampler or external watcher is used. Without this option the
# original exec path and process-only budget are unchanged.
#
# The kernel compares RLIMIT_NPROC with the user's WHOLE count, not with one
# process tree: processes on Darwin, tasks (threads included) on Linux.
# A runaway tree therefore starves every other process of the same user until
# the cap is full, and a bash 3.2 script exits 128 at its first failed fork.
# This wrapper reads the current count and sets the limit (soft and hard) to
# count + <extra>, then execs the command, so only the tree below it carries the
# lowered limit and the rest of the user keeps its headroom. <extra> is a
# positive decimal integer without leading zeros; omit it for 1500. Because the
# kernel counts the whole user, a small <extra> is spent by neighbours: observed
# at 138 new processes in one 10 s window on a busy host. The limit is therefore
# the safety net; --own-procs is the leash for a tree that must stay small.
#
# The budget only tightens. A limit the command already inherits that is lower
# than count + <extra> stays as it is, and the hard limit is lowered with the
# soft one so the tree cannot raise it again; a nested wrapper therefore never
# widens an outer budget.
#
# Only commands started through the wrapper are protected. Route every shim,
# lab, and measurement script through it. The headers of bin/fm-test-run.sh,
# bin/fm-live-lab.sh, and bin/fm-herdr-lab.sh own their launch integration.
#
# The budget is headroom over the count at the moment the command starts, so a
# tree that outlives a large rise in the rest of the user's processes can meet
# the limit without having grown.
#
# Exit status: the command's own, 2 for a malformed call, and 125 when no budget
# can be set (an unreadable process count, or a limit the host refuses). The
# command never runs unbudgeted behind the caller's back in those two cases.
# With --own-procs, 98 is a crossed own-tree limit and 125 also covers a table
# that cannot be read before launch or a failed cleanup after the command exits.
# With --memory-kib, 99 is a crossed memory limit, 125 also covers a failed
# memory sample or a failed cleanup after the command exits. A command that
# cannot start gets bash's own exec status and message (127 or 126), as without
# the option. On a failed supervisor cleanup sweep, the independent reader
# receives EOF and finishes its bounded TERM/KILL cleanup before it is ended.
# The command's own status comes after successful cleanup of its remaining
# tree; only an untracked process (above) survives it. Cleanup failures are
# reported on one stderr line, never as a successful command exit.
#
# tests/fm-proc-budget.test.sh is the regression entry point for a leashed
# recursive shim and an unbudgeted probe that must keep forking alongside it,
# for the own-tree stop with neighbours spending the shared count, and for the
# memory stop.
set -u
FM_PROC_BUDGET_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fm_proc_budget_error() {
  echo "fm-proc-budget: $*" >&2
}

fm_proc_budget_usage() {
  fm_proc_budget_error "usage: fm-proc-budget.sh [<extra>] [--memory-kib <KiB> | --own-procs <N>] -- <command...>"
}

fm_proc_budget_count() {
  local uid count
  uid=$(id -u) || return 1
  set -o pipefail
  case "$(uname -s)" in
    Linux) count=$(ps -L -U "$uid" -o lwp= | wc -l) || return 1 ;;
    # A confined worker's sandbox refuses to run setuid ps (exit 126), so the
    # count then comes from bin/fm-proc-info.py instead.
    *)
      count=$(ps -U "$uid" -o pid= 2>/dev/null)
      case $? in
        0) [ -n "$count" ] || return 1; count=$(printf '%s\n' "$count" | wc -l) || return 1 ;;
        126) count=$(python3 "$FM_PROC_BUDGET_DIR/fm-proc-info.py" count-uid "$uid") || return 1 ;;
        *) return 1 ;;
      esac
      ;;
  esac
  count=$(printf '%s' "$count" | tr -d '[:space:]')
  case "$count" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  printf '%s\n' "$count"
}

# fm_proc_budget_apply <extra>: lower this process's limit to count + <extra>
# unless the inherited limit is already lower. Prints nothing on success.
fm_proc_budget_apply() {
  local extra=$1 count current hard limit
  count=$(fm_proc_budget_count) || {
    fm_proc_budget_error "cannot read the process count, so no budget can be set"
    return 125
  }
  limit=$((count + extra))
  current=$(ulimit -S -u) || {
    fm_proc_budget_error "cannot read the current process limit"
    return 125
  }
  hard=$(ulimit -H -u) || {
    fm_proc_budget_error "cannot read the hard process limit"
    return 125
  }
  case "$current" in
    ''|*[!0-9]*) ;;  # unlimited: the budget is the only bound
    *) [ "$limit" -lt "$current" ] || limit=$current ;;
  esac
  case "$hard" in
    ''|*[!0-9]*) ;;
    *) [ "$limit" -lt "$hard" ] || limit=$hard ;;
  esac
  ulimit -u "$limit" 2>/dev/null || {
    fm_proc_budget_error "this host refused a process limit of $limit (count $count + $extra)"
    return 125
  }
}

extra=1500
memory_kib=
own_procs=
extra_given=0
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  if [ "$1" = --memory-kib ]; then
    [ "$#" -ge 2 ] && [ -z "$memory_kib" ] || { fm_proc_budget_usage; exit 2; }
    memory_kib=$2
    case "$memory_kib" in
      ''|*[!0-9]*|0|0[0-9]*) fm_proc_budget_error "memory limit must be a positive decimal integer in KiB"; exit 2 ;;
    esac
    # Bound conversion before Python or shell arithmetic can overflow.
    [ "${#memory_kib}" -le 15 ] || { fm_proc_budget_error "memory limit is too large"; exit 2; }
    shift 2
  elif [ "$1" = --own-procs ]; then
    [ "$#" -ge 2 ] && [ -z "$own_procs" ] || { fm_proc_budget_usage; exit 2; }
    own_procs=$2
    case "$own_procs" in
      ''|*[!0-9]*|0|0[0-9]*) fm_proc_budget_error "own-procs limit must be a positive decimal integer"; exit 2 ;;
    esac
    [ "${#own_procs}" -le 9 ] || { fm_proc_budget_error "own-procs limit is too large"; exit 2; }
    shift 2
  elif [ "$extra_given" -eq 0 ]; then
    extra=$1
    extra_given=1
    shift
  else
    fm_proc_budget_usage
    exit 2
  fi
done
if [ "${1:-}" != -- ]; then
  fm_proc_budget_usage
  exit 2
fi
shift
[ "$#" -gt 0 ] || { fm_proc_budget_usage; exit 2; }
[ -z "$memory_kib" ] || [ -z "$own_procs" ] || {
  fm_proc_budget_error "--memory-kib and --own-procs cannot be combined"
  exit 2
}
case "$extra" in
  ''|*[!0-9]*|0|0[0-9]*)
    fm_proc_budget_error "extra must be a positive decimal integer, got '$extra'"
    exit 2
    ;;
esac

fm_proc_budget_apply "$extra" || exit 125
if [ -n "$memory_kib" ]; then
  command -v python3 >/dev/null 2>&1 && [ -r "$FM_PROC_BUDGET_DIR/fm-proc-budget-memory.py" ] || {
    fm_proc_budget_error "cannot start memory reader; command not started"
    exit 125
  }
  exec python3 "$FM_PROC_BUDGET_DIR/fm-proc-budget-memory.py" "$memory_kib" -- "$@"
fi
if [ -n "$own_procs" ]; then
  command -v python3 >/dev/null 2>&1 && [ -r "$FM_PROC_BUDGET_DIR/fm-proc-budget-tree.py" ] || {
    fm_proc_budget_error "cannot start own-tree supervisor; command not started"
    exit 125
  }
  exec python3 "$FM_PROC_BUDGET_DIR/fm-proc-budget-tree.py" "$own_procs" -- "$@"
fi
exec "$@"
