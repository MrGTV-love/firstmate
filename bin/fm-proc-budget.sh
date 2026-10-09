#!/usr/bin/env bash
# fm-proc-budget.sh - run a command tree under a per-tree process budget.
#
# Usage:
#   fm-proc-budget.sh [<extra>] -- <command...>   run <command...> with a budget
#   fm-proc-budget.sh --count                     print the user's process count
#   fm-proc-budget.sh --check                     exit 0 when a budget can be set here
#
# The kernel compares RLIMIT_NPROC with the user's WHOLE process count, not with
# one process tree. A runaway tree therefore starves every other process of the
# same user until the cap is full, and a bash 3.2 script exits 128 at its first
# failed fork. The only handle is to stop the runaway early: this wrapper reads
# the current count and sets the limit (soft and hard) to count + <extra>, then
# execs the command, so only the tree below it carries the lowered limit and the
# rest of the user keeps its headroom. <extra> is a positive decimal integer;
# omit it for FM_PROC_BUDGET_EXTRA, or 1500 when that is unset.
#
# The budget only tightens. A limit the command already inherits that is lower
# than count + <extra> stays as it is, and the hard limit is lowered with the
# soft one so the tree cannot raise it again; a nested wrapper therefore never
# widens an outer budget.
#
# Only commands started through the wrapper are protected. Route every shim,
# lab, and measurement script through it; bin/fm-test-run.sh and
# bin/fm-live-lab.sh do so for the trees they start.
#
# FM_PROC_BUDGET=off runs the command with no budget, for a host where the
# budget turns out to starve a legitimate tree.
#
# The budget is headroom over the count at the moment the command starts, so a
# tree that outlives a large rise in the rest of the user's processes can meet
# the limit without having grown.
#
# Exit status: the command's own, 2 for a malformed call, and 125 when no budget
# can be set (an unreadable process count, or a limit the host refuses). The
# command never runs unbudgeted behind the caller's back in those two cases.
set -u

fm_proc_budget_error() {
  echo "fm-proc-budget: $*" >&2
}

fm_proc_budget_usage() {
  fm_proc_budget_error "usage: fm-proc-budget.sh [<extra>] -- <command...> | --count | --check"
}

# The kernel counts what RLIMIT_NPROC is compared with: processes on Darwin,
# tasks (threads included) on Linux.
fm_proc_budget_count() {
  local uid count
  uid=$(id -u) || return 1
  set -o pipefail
  case "$(uname -s)" in
    Linux) count=$(ps -L -U "$uid" -o lwp= | wc -l) || return 1 ;;
    *) count=$(ps -U "$uid" -o pid= | wc -l) || return 1 ;;
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
  local extra=$1 count current limit
  count=$(fm_proc_budget_count) || {
    fm_proc_budget_error "cannot read the process count, so no budget can be set"
    return 125
  }
  limit=$((count + extra))
  current=$(ulimit -u) || {
    fm_proc_budget_error "cannot read the current process limit"
    return 125
  }
  case "$current" in
    ''|*[!0-9]*) ;;  # unlimited: the budget is the only bound
    *) [ "$limit" -lt "$current" ] || return 0 ;;
  esac
  ulimit -u "$limit" 2>/dev/null || {
    fm_proc_budget_error "this host refused a process limit of $limit (count $count + $extra)"
    return 125
  }
}

case "${1:-}" in
  --count)
    fm_proc_budget_count || {
      fm_proc_budget_error "cannot read the process count"
      exit 125
    }
    exit 0
    ;;
  --check)
    # The limit is applied in a subshell, so this process keeps its own.
    ( fm_proc_budget_apply 1500 ) || exit 1
    echo "fm-proc-budget: a process budget can be set on this host"
    exit 0
    ;;
esac

extra=${FM_PROC_BUDGET_EXTRA:-1500}
if [ "${1:-}" != -- ] && [ "$#" -gt 0 ]; then
  extra=$1
  shift
fi
if [ "${1:-}" != -- ]; then
  fm_proc_budget_usage
  exit 2
fi
shift
[ "$#" -gt 0 ] || { fm_proc_budget_usage; exit 2; }
case "$extra" in
  ''|*[!0-9]*|0|0[0-9]*)
    fm_proc_budget_error "extra must be a positive decimal integer, got '$extra'"
    exit 2
    ;;
esac

if [ "${FM_PROC_BUDGET:-}" != off ]; then
  fm_proc_budget_apply "$extra" || exit 125
fi
exec "$@"
