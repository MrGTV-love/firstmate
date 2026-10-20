#!/usr/bin/env bash
# fm-copy-sweep.sh - find, size and remove provably stale nested task copies, and
# wake once when the bytes they hold pass a budget or when a nested copy sits
# inside a live task's copy.
#
# Usage:
#   fm-copy-sweep.sh                report every nested copy; change nothing
#   fm-copy-sweep.sh --apply        also remove the REAPABLE-PROVEN copies
#   fm-copy-sweep.sh check          the watcher's periodic entry (report only)
#   fm-copy-sweep.sh arm            bind `check` to the existing watcher cadence
#   fm-copy-sweep.sh disarm         remove that binding and the record (budgets and live copies)
#   fm-copy-sweep.sh --help
#
# Hourly hygiene job, one line (bounded by the process budget, never forced):
#   bin/fm-proc-budget.sh -- bin/fm-copy-sweep.sh --apply
#
# What it sweeps. A nested copy is a worktree that a pool slot's clone, or a
# project clone under a local Firstmate home (this home and every home
# data/secondmates.md registers locally), has registered strictly inside its own
# directory, such as <clone>/.claude/worktrees/<name>. `git -C <clone> worktree
# list --porcelain` is the only enumeration. Pool slots come from each
# <treehouse root>/<pool>/treehouse-state.json, so the sweep reads the pool and
# never asks Treehouse to change it. The whole-slot reaper (`treehouse prune`)
# works on slots and cannot see these copies; this script does not touch slots.
#
# Classes. Each copy gets the first class that applies, in this order:
#   ORPHAN-NO-RECORD   nothing can explain it or prove it: the directory is gone,
#                      is no worktree root of that clone, or its git or lock state
#                      cannot be read. Never touched; `git worktree prune` and
#                      the owner are the repair.
#   HELD-LOCKED        a worktree lock holds it and this sweep may not remove it.
#                      A lock that is not Vernant's exact creation-lock format,
#                      or whose launcher may still be alive, stays here, as does
#                      a Vernant-locked copy whose clone has no closeout driver
#                      or no usable interpreter for it: the closeout driver is
#                      the only supported release and this sweep never unlocks
#                      by hand. A REAPABLE-DRIVER copy whose driver plan refuses
#                      it in --apply joins this class, with the driver's own
#                      reason as its reason.
#   HELD-LIVE-TASK     an active task record in any local home names it (or a
#                      path inside or around it, except a registered secondmate's
#                      own home chain), a process has its working directory
#                      inside it, it holds this home or this process, or the
#                      records or the process table cannot be read. A project
#                      clone under a registered secondmate home is judged as that
#                      home would judge it (FM_HOME set to that home): the lane's
#                      own records apply, its secondmate record in the root home
#                      is its home chain, and a lane whose records cannot be read
#                      holds all of its copies.
#   HELD-DIRTY         git status shows any change or untracked file, an
#                      operation (rebase, merge, cherry-pick, revert, bisect) is
#                      in progress, it is not locked and holds an ignored file
#                      that exists nowhere else (the teardown library's rule; a
#                      locked copy's are preserved before its release), or
#                      another registered copy with an existing directory is
#                      inside it:
#                      a plain `git worktree remove` of the outer copy would
#                      delete that inner copy and whatever it holds, and git
#                      status cannot see it when `.claude/worktrees/` is ignored.
#   HELD-UNPUSHED      its HEAD holds a commit that is on no remote and whose
#                      content is not already in the default branch (a locked
#                      copy has no such fallback; see REAPABLE-DRIVER).
#   REAPABLE-PROVEN    clean, HEAD contained in a remote branch (the whole-slot
#                      reaper's rule) or its content already in the default
#                      branch (bin/fm-task-copy-lib.sh's landed rule, the one
#                      bin/fm-teardown.sh uses), no process inside, no record.
#   REAPABLE-DRIVER    a clean worktree root, no active record, no process
#                      inside, every local commit reachable from HEAD contained
#                      in a remote branch (the content-in-default fallback does
#                      not apply to a locked copy), plus Vernant's exact
#                      creation lock whose launcher pid is gone or recycled.
#                      The launcher test is bin/fm-teardown-nested-lib.sh's own
#                      teardown_lock_launcher_may_be_live: a pid that started
#                      after the lock file was written is recycled and owns
#                      nothing, and a pid that started before it, still alive, is
#                      the lock's launcher and keeps the copy locked. Only
#                      Vernant's closeout driver releases it, and --apply first
#                      asks that driver for its plan.
# HELD-LOCKED is its own class: a locked copy cannot be removed by a plain
# `git worktree remove`, so calling it live or orphaned would mislead.
# Independently of class and byte budgets, one HELD-LIVE-TASK report line names
# every nested copy on disk strictly inside a ship/scout record's current or prior
# copy, where that copy is the registering clone itself (a pool slot) or lies
# inside it, with its absolute path, owning task, and age in seconds from the
# lock mtime (source=lock) or, when unlocked, the directory mtime
# (source=directory). A lock state that cannot be read, such as
# a probe cut by `check`'s time bound, reads source=unknown and age=unknown, never
# the directory of a copy that may be locked. A record's presence means it is
# still in custody; teardown removes closed records. This check only reports,
# including locked copies, and never releases anything. Only the report, a run
# with no flag, prints the whole line. `check` and `--apply` put one bounded part
# of it in their one aggregated wake, even below the byte budget: the count, five
# copies in all (new copies first, then the oldest), and a pointer to the no-flag
# run. A copy with no live owning record is left to the existing reap path.
#
# --apply removes the REAPABLE-PROVEN and REAPABLE-DRIVER copies, one at a time,
# deepest path first, each re-proved just before its own removal. An unlocked
# copy goes by a plain `git worktree remove` run from the parent clone. A locked
# one first gets the closeout driver's plan, run from that clone without
# --execute-cleanup and before anything is copied or hashed. The plan must exit
# 0 AND say allowed: its whole answer is one JSON document whose "allowed" is the
# boolean true, or is exactly the literal allowed=true. A non-zero exit, an empty,
# malformed or verdictless answer, text that only mentions allowed=true, any other
# value, or a timeout holds the copy as HELD-LOCKED with the driver's own words
# (the first 600 characters, on one line), copies nothing, and is not a failure.
# The timeout is deliberate (FM_COPY_SWEEP_PLAN_TIMEOUT seconds, 120 by default):
# the owner's rule holds a copy whose plan does not answer. The plan runs as a
# process group of its own and the timeout kills that whole group, so neither the
# driver nor anything it started outlives the sweep. A copy whose plan allows it
# has its ignored entries preserved by the teardown library's own preservation,
# its creation lock read again, and is then released and removed by the driver,
# as bin/fm-teardown.sh does it. The preserved entries land in
# data/copy-sweep/<run stamp>-<HEAD>/nested-copy-preserved/<sha256 of the path>,
# so no later run or copy at the same path replaces them. Never a force flag,
# never a recursive delete of a copy (the only recursive delete is the teardown
# library's of its own staging directory under data/), never a hand unlock, never
# a Treehouse call. A removal that fails after its plan was allowed, or that git
# refuses, leaves the copy and is reported with the refusal text, and the run
# exits 1; it is not retried in that run. The sweep prints that refusal itself,
# as one REFUSED line: a preservation that fails ends in a human-only question, a
# lock that is no longer Vernant's says the next run proves the copy again, and a
# driver that refuses ends in the driver's own words. None names a completing
# command, because the release id is no teardown task id and bin/fm-teardown.sh
# would reject a command built from it. Each REMOVED line reports "copy X GiB,
# preserved Y GiB, net freed Z GiB" (the copy's size less the bytes it preserved;
# a size that was not measured shows "-" and "unmeasured"), and the run ends with
# one line "freed X GiB measured, N copies unmeasured". Each removal appends one
# line to data/copy-sweep.log (append-only). An outer copy whose inner copy was
# removed in the same run is removed by the next run; a second run otherwise
# finds nothing left to remove. Report mode (no flag) reads the size cache and writes
# nothing; `check` writes only the size cache and the record (budgets and live copies).
# Only the landed proof in --apply mode fetches the default branch (as the
# teardown rule does); report and check use the refs already present, which can
# only hold a copy back, never release one.
#
# Sizes. One `nice -n 20 du -sk` runs at a time, never in parallel. Each size is
# cached in state/copy-sweep.sizes by copy path and the copy's mtime and reused
# until that mtime changes or the entry is older than cache-max-age (a copy's
# root mtime does not move when a deep file grows). A copy nested in another copy
# is subtracted from its enclosing copy so no byte is counted twice.
# While the 1-minute load average exceeds load-limit (default 90), or cannot be
# read, no du runs: the listing, the classes and --apply still run, only fresh
# cached sizes are used, and a report or --apply run prints one line, "scan
# skipped: load N above limit M". --apply and `check` also record it, `check`
# stays quiet, and either raises one wake once 6 runs in a row have skipped. A
# `check` cut by its time bound counts at most once per `interval` toward that
# count, measured from the last time the count advanced, so a check that is cut
# and skipped on every poll still reaches the wake after 6 intervals.
#
# Budgets. config/copy-budget (docs/configuration.md owns the format) holds a
# GiB budget per pool root and per container (a pool slot, or a Firstmate home).
# Built-in defaults apply when the file or a line is absent. A budget is over
# when the measured bytes of its nested copies exceed it. A scan cut short
# (check's time bound) still counts what it measured, so an unmeasured copy can
# only delay a wake, never invent one. The run raises exactly ONE wake for the
# budgets that just went over - budget, total, and the five largest copies with
# their class - and none again while the same budget stays over. A budget that
# drops under and goes over again wakes again. state/copy-sweep.record holds that
# memory; --apply raises the wake itself through the wake queue, `check` prints
# the line and the watcher turns it into the same `check:` wake.
#
# The live-copy fact wakes once when a copy joins the named set, not once per poll,
# and a copy leaving it is silent. state/copy-sweep.record keeps that set beside
# the budget memory, so an unchanged set stays silent in `check` and `--apply`
# while every report still prints it. A cut scan keeps a recorded path because
# it cannot prove it gone.
#
# `arm` writes state/copy-sweep.check.sh and binds its bytes with
# fm-check-register.sh, so the existing watcher runs `check` on its normal
# FM_CHECK_INTERVAL cadence, at most once per `interval` seconds of scanning;
# no extra daemon or scheduler is installed. `check` never removes anything. The
# watcher kills a check that outlives FM_CHECK_TIMEOUT and keeps nothing, so
# `check` bounds its whole run by that timeout minus five seconds. It scans each
# clone as it finds it and stops looking for clones once that time is spent, so
# on a host with many clones it covers the first clones it reaches and a later
# poll starts from the same place: partial coverage. The size cache saves only
# du time, so a poll that du holds up reaches a little further each time; once
# sizes are cached the time goes to finding and listing clones, which the cache
# does not skip, and a poll bound that way stops at the same clone every time.
# Home project clones come after the pool clones, so such a check may never
# reach them. A cut run writes no completed-scan mark, its wake names
# only what it measured, every budget the record holds as over keeps its place in
# it because a cut scan cannot prove any budget back under (only a complete run
# clears one), and it keeps the still-fresh cached sizes of the copies it never
# reached. Each du runs under the time left and is cut when it cannot finish, and
# `check` classifies only the copies it names in a wake (the rest read
# UNCLASSIFIED). Every git and lsof call of those classifications runs under the
# time left too, so a copy whose classification cannot finish reads UNCLASSIFIED.
# The bound holds to within the work of one clone. The hourly `--apply` run has
# no time bound, is the only run certain to cover every clone, and warms the
# cache for large copies.
#
# Exit status: 0 done, 1 a removal or write failed, 2 bad call or bad config.
# tests/fm-copy-sweep.test.sh is the regression entry point.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TREEHOUSE_ROOT="${FM_COPY_SWEEP_TREEHOUSE_ROOT:-$HOME/.treehouse}"
CHECK_ID='copy-sweep'
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/$CHECK_ID.record"
SIZE_CACHE="$STATE/$CHECK_ID.sizes"
SWEEP_LOCK="$STATE/.$CHECK_ID.lock"
REMOVAL_LOG="$DATA_DIR/$CHECK_ID.log"
RECORD_SCHEMA_LINE=$'schema\tfm-copy-sweep-v1'
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
PROC_BUDGET_BIN="$SCRIPT_DIR/fm-proc-budget.sh"
MAX_LINE=1600

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-task-copy-lib.sh
. "$SCRIPT_DIR/fm-task-copy-lib.sh"
# shellcheck source=bin/fm-refuse-lib.sh
. "$SCRIPT_DIR/fm-refuse-lib.sh"
# shellcheck source=bin/fm-teardown-nested-lib.sh
. "$SCRIPT_DIR/fm-teardown-nested-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"
}

fail() {
  printf 'fm-copy-sweep: %s\n' "$1" >&2
  exit "${2:-1}"
}

now_epoch() {
  case "${FM_COPY_SWEEP_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_COPY_SWEEP_NOW" ;;
  esac
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

gib_to_kib() {  # <GiB, may be decimal>
  awk -v g="$1" 'BEGIN { printf "%.0f\n", g * 1048576 }'
}

kib_to_gib() {  # <KiB>
  awk -v k="$1" 'BEGIN { printf "%.2f", k / 1048576 }'
}

# --- configuration -----------------------------------------------------------

LOAD_LIMIT=90
DEFAULT_POOL_GIB=60
DEFAULT_CONTAINER_GIB=20
SCAN_INTERVAL=3600
CACHE_MAX_AGE=86400
POOL_BUDGETS=
CONTAINER_BUDGETS=
CONFIG_ERROR=

valid_number() {  # <value> [allow-decimal]
  [[ $1 =~ ^[0-9]+$ ]] && return 0
  [ "${2:-}" = decimal ] && [[ $1 =~ ^[0-9]+\.[0-9]+$ ]]
}

valid_gib() {
  [ "$1" = off ] || valid_number "$1" decimal
}

# Reads config/copy-budget. Returns 1 with CONFIG_ERROR set for a malformed file.
load_config() {
  local file=$CONFIG_DIR/copy-budget line key a b extra n=0
  CONFIG_ERROR=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    CONFIG_ERROR="config/copy-budget is not a regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    key='' a='' b='' extra=''
    read -r key a b extra <<< "$line"
    [ -n "$key" ] || continue
    if [ -n "$extra" ]; then
      CONFIG_ERROR="config/copy-budget line $n has too many fields"
      return 1
    fi
    case "$key" in
      default-pool)
        if [ -n "$a" ] && [ -z "$b" ] && valid_gib "$a"; then DEFAULT_POOL_GIB=$a
        else CONFIG_ERROR="config/copy-budget line $n: default-pool wants one GiB value or off"; return 1; fi ;;
      default-container)
        if [ -n "$a" ] && [ -z "$b" ] && valid_gib "$a"; then DEFAULT_CONTAINER_GIB=$a
        else CONFIG_ERROR="config/copy-budget line $n: default-container wants one GiB value or off"; return 1; fi ;;
      load-limit)
        if [ -n "$a" ] && [ -z "$b" ] && valid_number "$a" decimal; then LOAD_LIMIT=$a
        else CONFIG_ERROR="config/copy-budget line $n: load-limit wants one number"; return 1; fi ;;
      interval)
        if [ -n "$a" ] && [ -z "$b" ] && valid_number "$a"; then SCAN_INTERVAL=$a
        else CONFIG_ERROR="config/copy-budget line $n: interval wants whole seconds"; return 1; fi ;;
      cache-max-age)
        if [ -n "$a" ] && [ -z "$b" ] && valid_number "$a"; then CACHE_MAX_AGE=$a
        else CONFIG_ERROR="config/copy-budget line $n: cache-max-age wants whole seconds"; return 1; fi ;;
      pool)
        if [ -n "$a" ] && [ -n "$b" ] && valid_gib "$b"; then POOL_BUDGETS="$POOL_BUDGETS$a"$'\t'"$b"$'\n'
        else CONFIG_ERROR="config/copy-budget line $n: pool wants a pool name or path and a GiB value or off"; return 1; fi ;;
      container)
        case "$a" in
          /*) ;;
          *) CONFIG_ERROR="config/copy-budget line $n: container wants an absolute path"; return 1 ;;
        esac
        if [ -n "$b" ] && valid_gib "$b"; then CONTAINER_BUDGETS="$CONTAINER_BUDGETS$a"$'\t'"$b"$'\n'
        else CONFIG_ERROR="config/copy-budget line $n: container wants a path and a GiB value or off"; return 1; fi ;;
      *)
        CONFIG_ERROR="config/copy-budget line $n: unknown key '$key'"
        return 1 ;;
    esac
  done < "$file"
}

# Prints the budget in GiB (or off) for pool <path> or container <path>.
budget_gib_for() {  # pool|container <path>
  local kind=$1 key=$2 table name value found=
  if [ "$kind" = pool ]; then table=$POOL_BUDGETS; else table=$CONTAINER_BUDGETS; fi
  while IFS=$'\t' read -r name value; do
    [ -n "$name" ] || continue
    if [ "$name" = "$key" ] || { [ "$kind" = pool ] && [ "$name" = "${key##*/}" ]; }; then
      found=$value
    fi
  done <<< "$table"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
  elif [ "$kind" = pool ]; then
    printf '%s\n' "$DEFAULT_POOL_GIB"
  else
    printf '%s\n' "$DEFAULT_CONTAINER_GIB"
  fi
}

# --- load guard --------------------------------------------------------------

load_average() {
  local out v
  out=$(uptime 2>/dev/null) || return 1
  v=$(printf '%s\n' "$out" | sed -n 's/.*load averages\{0,1\}:[[:space:]]*\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\).*/\1/p')
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# Returns 0 when du may run; 1 with SKIP_LINE set when it may not.
SKIP_LINE=
load_allows_sizing() {
  local load
  SKIP_LINE=
  if ! load=$(load_average); then
    SKIP_LINE="scan skipped: load cannot be read, limit $LOAD_LIMIT"
    return 1
  fi
  if awk -v l="$load" -v m="$LOAD_LIMIT" 'BEGIN { exit !(l > m) }'; then
    SKIP_LINE="scan skipped: load $load above limit $LOAD_LIMIT"
    return 1
  fi
}

# --- enumeration -------------------------------------------------------------

# One "pool<TAB>container<TAB>clone" line per clone to inspect.
CLONES=
NOTES=
SCAN_MODE=
ROWS=

add_note() {
  NOTES="$NOTES$1"$'\n'
}

clone_seen() {  # <canonical-clone>
  printf '%s' "$CLONES" | awk -F '\t' -v c="$1" '$3 == c { found = 1 } END { exit !found }'
}

# True, with SCAN_CUT set, once check's time bound is spent. A run with no
# deadline never is.
scan_out_of_time() {
  [ "$SCAN_DEADLINE" -gt 0 ] && [ "$(date +%s)" -ge "$SCAN_DEADLINE" ] || return 1
  SCAN_CUT=1
}

# Records one clone and scans it at once, so a check that runs out of time has
# measured every clone it reached.
emit_clone() {  # <pool> <container> <clone>
  CLONES="$CLONES$1"$'\t'"$2"$'\t'"$3"$'\n'
  scan_clone "$1" "$2" "$3" </dev/null
}

# Read the same local task records as classification, once per run rather than
# once per nested copy. Secondmate homes are not task copies.
LIVE_TASK_COPIES=
read_live_task_copies() {
  local state_dir meta kind field path line
  LIVE_TASK_COPIES=
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      scan_out_of_time && return
      kind=$(fm_meta_get "$meta" kind)
      case "${kind:-ship}" in ship|scout) ;; *) continue ;; esac
      while IFS= read -r line; do
        field=${line%% *}
        case "$field" in worktree|prior_worktree) ;; *) continue ;; esac
        path=$(fm_task_copy_canonical_dir "${line#* }") || continue
        LIVE_TASK_COPIES="$LIVE_TASK_COPIES$path"$'\t'"${meta##*/}"$'\n'
      done < <(fm_task_copy_record_paths "$meta")
    done
  done
}

enumerate_clones() {
  local state pool_dir path clone state_dir home entry top
  local -a state_dirs
  CLONES=
  NOTES=
  fm_local_firstmate_state_dirs "$STATE" tolerant
  for entry in ${FM_LOCAL_FIRSTMATE_SKIPPED[@]+"${FM_LOCAL_FIRSTMATE_SKIPPED[@]}"}; do
    add_note "a local home was not read: $entry"
  done
  read_live_task_copies
  state_dirs=("${FM_LOCAL_FIRSTMATE_STATES[@]}")
  for state in "$TREEHOUSE_ROOT"/*/treehouse-state.json; do
    [ -f "$state" ] && [ ! -L "$state" ] || continue
    pool_dir=$(fm_task_copy_canonical_dir "${state%/*}") || continue
    if ! command -v jq >/dev/null 2>&1; then
      add_note "pool $pool_dir was not read: jq is not installed"
      continue
    fi
    if ! entry=$(jq -r '.worktrees[]? | .path // empty' "$state" 2>/dev/null); then
      add_note "pool $pool_dir was not read: its Treehouse state cannot be parsed"
      continue
    fi
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      scan_out_of_time && break 2
      clone=$(fm_task_copy_canonical_dir "$path") || continue
      case "$clone" in "$pool_dir"/*) ;; *) continue ;; esac
      git -C "$clone" rev-parse --git-dir >/dev/null 2>&1 || continue
      clone_seen "$clone" && continue
      emit_clone "$pool_dir" "$clone" "$clone"
    done <<< "$entry"
  done
  for state_dir in "${state_dirs[@]}"; do
    home=$(fm_task_copy_canonical_dir "${state_dir%/*}") || continue
    for path in "$home"/projects/*; do
      [ -d "$path" ] || continue
      scan_out_of_time && break 2
      clone=$(fm_task_copy_canonical_dir "$path") || continue
      top=$(git -C "$clone" rev-parse --show-toplevel 2>/dev/null) || continue
      [ "$(fm_task_copy_canonical_dir "$top")" = "$clone" ] || continue
      clone_seen "$clone" && continue
      emit_clone - "$home" "$clone"
    done
  done
}

# The registered worktrees strictly inside <clone>; bin/fm-task-copy-lib.sh owns
# the enumeration.
list_nested() {  # <clone>
  fm_task_copy_registered_nested "$1"
}

# --- bounded commands --------------------------------------------------------

SCAN_DEADLINE=0
CLASSIFY_BOUNDED=0

# Runs an external command under the time check's scan has left: status 124 when
# that time is spent or runs out. A plain call when the run has no deadline.
run_before_deadline() {  # <command> [args...]
  local remaining bin
  if [ "$SCAN_DEADLINE" -le 0 ]; then
    command "$@"
    return
  fi
  remaining=$((SCAN_DEADLINE - $(date +%s)))
  [ "$remaining" -ge 1 ] || return 124
  bin=$(type -P "$1") || return 127
  shift
  fm_run_timed "$remaining" "$bin" "$@"
}

# While check classifies, every git and lsof call, including the ones the sourced
# libraries make, runs under the time left.
git() {
  if [ "$CLASSIFY_BOUNDED" = 1 ]; then run_before_deadline git "$@"; else command git "$@"; fi
}

lsof() {
  if [ "$CLASSIFY_BOUNDED" = 1 ]; then run_before_deadline lsof "$@"; else command lsof "$@"; fi
}

# --- process table -----------------------------------------------------------

PROC_TABLE=
PROC_OK=1

# One "pid<TAB>cwd" line per process, from a bounded system-wide cwd scan.
scan_processes() {
  local out line pid=
  PROC_TABLE=
  PROC_OK=1
  if ! out=$(lsof -a -d cwd -Fpn 2>/dev/null); then
    PROC_OK=0
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p} ;;
      n*)
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        [ "$pid" = "$$" ] || PROC_TABLE="$PROC_TABLE$pid"$'\t'"${line#n}"$'\n'
        ;;
    esac
  done <<< "$out"
}

# Prints the first pid whose cwd is the copy or inside it.
process_inside() {  # <copy>
  printf '%s' "$PROC_TABLE" | awk -F '\t' -v c="$1" '
    index($2, c) == 1 && (length($2) == length(c) || substr($2, length(c) + 1, 1) == "/") { print $1; exit }'
}

# --- classification ----------------------------------------------------------

CLASS=
REASON=
APPLY=0

# True when the copy's content is already in the default branch. Only --apply
# fetches; the others read the refs that are already here.
content_in_default() {  # <copy> <clone>
  local copy=$1 clone=$2 name ref default_tree merged_tree
  if [ "$APPLY" = 1 ]; then
    fm_task_copy_content_in_default "$copy" "$clone"
    return
  fi
  name=$(fm_task_copy_default_branch "$clone") || return 1
  ref=refs/remotes/origin/$name
  git -C "$copy" rev-parse --quiet --verify "$ref^{commit}" >/dev/null 2>&1 || ref=refs/heads/$name
  default_tree=$(git -C "$copy" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  merged_tree=$(git -C "$copy" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  [ "${merged_tree%%$'\n'*}" = "$default_tree" ]
}

# Sets CLASS and REASON for <copy>, registered by <clone> of <pool> and
# <container>. A clone under a Firstmate home other than this one is judged as
# that home would judge it.
classify() {  # <copy> <clone> <pool> <container>
  local copy=$1 clone=$2 pool=$3 container=$4 top rc admin status count name pid unique pending inner
  local home=$FM_HOME state=$STATE locked=0 launcher=
  CLASS=
  REASON=
  if [ "$pool" = - ] && ! [ "$container/state" -ef "$STATE" ]; then
    home=$container
    state=$container/state
  fi
  if [ ! -d "$copy" ]; then
    CLASS=ORPHAN-NO-RECORD
    REASON="its directory is gone; git worktree prune is the repair"
    return 0
  fi
  top=$(git -C "$copy" rev-parse --show-toplevel 2>/dev/null) && top=$(fm_task_copy_canonical_dir "$top")
  if [ "$top" != "$copy" ]; then
    CLASS=ORPHAN-NO-RECORD
    REASON="it is not a readable git worktree root"
    return 0
  fi
  if ! fm_task_copy_same_repository "$copy" "$clone"; then
    CLASS=ORPHAN-NO-RECORD
    REASON="it does not belong to the repository that registered it"
    return 0
  fi
  if ! git -C "$copy" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; then
    CLASS=ORPHAN-NO-RECORD
    REASON="its HEAD cannot be resolved"
    return 0
  fi
  rc=0
  teardown_copy_lock_file "$copy" || rc=$?
  case "$rc" in
    0)
      CLASS=HELD-LOCKED
      REASON="worktree lock: ${TEARDOWN_FOREIGN_LOCK:-no reason given}"
      if ! pid=$(teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK"); then
        REASON="$REASON (not the supported Vernant creation-lock format)"
        return 0
      fi
      if teardown_lock_launcher_may_be_live "$pid" "$TEARDOWN_FOREIGN_LOCK_FILE"; then
        REASON="$REASON (launcher $pid is alive or its start cannot be proved)"
        return 0
      fi
      REASON="$REASON (launcher $pid is gone or recycled; only Vernant's closeout driver releases it)"
      if [ ! -f "$clone/scripts/git-stability/closeout_pr.py" ] \
        || [ ! -x "${FM_TEARDOWN_VERNANT_PYTHON:-$clone/.venv/bin/python}" ]; then
        REASON="$REASON; closeout driver or interpreter unavailable"
        return 0
      fi
      launcher=$pid
      locked=1
      CLASS=
      REASON=
      ;;
    1) ;;
    *)
      CLASS=ORPHAN-NO-RECORD
      REASON="its lock state cannot be read"
      return 0
      ;;
  esac
  for pending in "$FM_HOME" "$STATE" "$PWD" "$FM_ROOT"; do
    pending=$(fm_task_copy_canonical_dir "$pending") || continue
    case "$pending/" in
      "$copy"/*)
        CLASS=HELD-LIVE-TASK
        REASON="it holds $pending, which this run needs"
        return 0
        ;;
    esac
  done
  rc=0
  FM_HOME=$home fm_task_copy_other_record "" "$state" "$copy" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0)
      CLASS=HELD-LIVE-TASK
      REASON="task $FM_TASK_COPY_OTHER_ID's active record names it as its $FM_TASK_COPY_OTHER_FIELD"
      return 0
      ;;
    1) ;;
    *)
      CLASS=HELD-LIVE-TASK
      REASON="the active task records of $home cannot be read, so none is ruled out"
      return 0
      ;;
  esac
  if [ "$PROC_OK" != 1 ]; then
    CLASS=HELD-LIVE-TASK
    REASON="the process scan failed, so no process is ruled out"
    return 0
  fi
  pid=$(process_inside "$copy")
  if [ -n "$pid" ]; then
    CLASS=HELD-LIVE-TASK
    REASON="process $pid is running inside it"
    return 0
  fi
  if ! status=$(git -C "$copy" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null); then
    CLASS=ORPHAN-NO-RECORD
    REASON="git status cannot read it"
    return 0
  fi
  if [ -n "$status" ]; then
    count=$(printf '%s\n' "$status" | wc -l | tr -d '[:space:]')
    CLASS=HELD-DIRTY
    REASON="$count uncommitted or untracked path(s), first: $(printf '%s\n' "$status" | head -1)"
    return 0
  fi
  admin=$(git -C "$copy" rev-parse --absolute-git-dir 2>/dev/null) || admin=
  for name in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer; do
    if [ -n "$admin" ] && { [ -e "$admin/$name" ] || [ -L "$admin/$name" ]; }; then
      CLASS=HELD-DIRTY
      REASON="a git operation is in progress in it ($name)"
      return 0
    fi
  done
  # A locked copy's ignored entries are preserved by its driver release, so only
  # an unlocked copy is held for them; an unreadable list holds either kind.
  if ! unique=$(teardown_preservable_ignored "$copy"); then
    CLASS=ORPHAN-NO-RECORD
    REASON="its ignored files cannot be listed, so none is ruled out"
    return 0
  fi
  if [ "$locked" != 1 ] && [ -n "$unique" ]; then
    CLASS=HELD-DIRTY
    REASON="it holds ignored files that exist nowhere else: $(printf '%s' "$unique" | tr '\n' ' ')"
    return 0
  fi
  while IFS= read -r inner; do
    case "$inner" in "$copy"/*) ;; *) continue ;; esac
    [ -d "$inner" ] || continue
    CLASS=HELD-DIRTY
    REASON="another registered copy is inside it: $inner"
    return 0
  done < <(list_nested "$clone")
  if ! count=$(git -C "$copy" rev-list --count HEAD --not --remotes 2>/dev/null); then
    CLASS=HELD-UNPUSHED
    REASON="its HEAD cannot be compared with the remotes"
    return 0
  fi
  if [ "$count" = 0 ]; then
    if [ "$locked" = 1 ]; then
      CLASS=REAPABLE-DRIVER
      REASON="clean, no process, no record, HEAD contained in a remote branch, Vernant launcher $launcher is gone"
    else
      CLASS=REAPABLE-PROVEN
      REASON="clean, no process, no record, HEAD contained in a remote branch"
    fi
  elif [ "$locked" = 1 ]; then
    # A locked copy is released only when every local commit is on a remote.
    # The content-in-default fallback stays an unlocked-copy rule: a bundle is
    # the recovery for its commits, not a landed proof for a lock release.
    CLASS=HELD-UNPUSHED
    REASON="$count commit(s) are on no remote; a locked copy is released only when every local commit is on a remote"
  elif content_in_default "$copy" "$clone"; then
    CLASS=REAPABLE-PROVEN
    REASON="clean, no process, no record, content already in the default branch"
  else
    CLASS=HELD-UNPUSHED
    REASON="$count commit(s) are on no remote and not in the default branch"
  fi
}

# --- sizes -------------------------------------------------------------------

SCAN_CUT=0
SIZING=1
CACHE_NOW=
SIZE_KIB=
CACHE_NEW=

cache_lookup() {  # <copy> <mtime> -> "<measured-at><TAB><KiB>" when fresh
  [ -f "$SIZE_CACHE" ] && [ ! -L "$SIZE_CACHE" ] || return 1
  awk -F '\t' -v p="$1" -v m="$2" -v now="$CACHE_NOW" -v age="$CACHE_MAX_AGE" '
    $1 == p && $2 == m && $4 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && now - $3 < age { print $3 "\t" $4; found = 1; exit }
    END { exit !found }' "$SIZE_CACHE"
}

# Sets SIZE_KIB to the KiB under <path>, or empty when du did not finish or
# printed no size. A cut du marks the scan cut.
du_kib() {  # <path>
  local out rc=0
  SIZE_KIB=
  out=$(run_before_deadline nice -n 20 du -sk -- "$1" 2>/dev/null) || rc=$?
  if fm_timed_out "$rc"; then
    SCAN_CUT=1
    return 0
  fi
  out=${out%%[[:space:]]*}
  case "$out" in ''|*[!0-9]*) return 0 ;; esac
  SIZE_KIB=$out
}

# Sets SIZE_KIB to the size of the directory <dir> in KiB: 0 when it does not
# exist, empty when it was not measured.
measure_dir() {  # <dir>
  SIZE_KIB=0
  [ -d "$1" ] || return 0
  SIZE_KIB=
  [ "$SIZING" = 1 ] || return 0
  du_kib "$1"
}

# Sets SIZE_KIB to the copy's size in KiB, or empty when it was not measured.
# One du at a time; a deadline stops new measurements, never one in flight.
measure_copy() {  # <copy>
  local copy=$1 mtime hit measured=$CACHE_NOW
  SIZE_KIB=
  if [ ! -d "$copy" ]; then
    SIZE_KIB=0
    return 0
  fi
  mtime=$(file_mtime "$copy") || mtime=
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  if hit=$(cache_lookup "$copy" "$mtime"); then
    # The entry keeps its original measurement time, so cache-max-age bounds
    # how long an unchanged root mtime can hide growth deeper in the copy.
    SIZE_KIB=${hit#*$'\t'}
    CACHE_NEW="$CACHE_NEW$copy"$'\t'"$mtime"$'\t'"${hit%%$'\t'*}"$'\t'"$SIZE_KIB"$'\n'
    return 0
  fi
  [ "$SIZING" = 1 ] || return 0
  # The watcher kills a check that outlives its bound and keeps nothing, so a
  # measurement that cannot finish inside the time left is cut, not awaited.
  du_kib "$copy"
  [ -n "$SIZE_KIB" ] || return 0
  CACHE_NEW="$CACHE_NEW$copy"$'\t'"$mtime"$'\t'"$measured"$'\t'"$SIZE_KIB"$'\n'
}

# --- the scan ----------------------------------------------------------------

# One line per copy: container, pool, clone, copy, class, KiB net of the copies
# nested in it ("-" when unmeasured), reason. Empty fields are never used; tab is
# IFS whitespace, so read would merge them.
COPIES=

# Subtracts each copy's directly nested copies from it, so no byte counts twice.
net_sizes() {
  awk 'BEGIN { FS = OFS = "\t" }
    { row[NR] = $0; copy[NR] = $4; size[NR] = $6; n = NR }
    END {
      for (i = 1; i <= n; i++) {
        net = size[i]
        if (net != "-") {
          for (j = 1; j <= n; j++) {
            if (j == i || index(copy[j], copy[i] "/") != 1) continue
            near = 1
            for (k = 1; k <= n; k++) {
              if (k == i || k == j) continue
              if (index(copy[k], copy[i] "/") == 1 && index(copy[j], copy[k] "/") == 1) { near = 0; break }
            }
            if (near && size[j] != "-") net -= size[j]
          }
          if (net < 0) net = 0
        }
        split(row[i], f, "\t")
        print f[1], f[2], f[3], f[4], f[5], net, f[7]
      }
    }'
}

# One "age-in-seconds<TAB>copy<TAB>task<TAB>age<TAB>source" line per live copy,
# the first field -1 when the age is unknown.
LIVE_NESTED_ROWS=
LIVE_NESTED_COUNT=0
LIVE_NESTED_FACT_NEW=0
LIVE_RECORD_NEW=

# A named fact, independent of the removal classifier (locks take precedence
# there). The enclosing clone is already proved by list_nested; only custody
# comes from records, never from a process-table guess or a directory walker.
# The age is the lock's when the copy is locked and the directory's when it is
# not; a lock state the probe could not read leaves source and age unknown
# rather than naming the directory of a copy that may be locked.
record_live_nested_copy() {  # <copy> <clone>
  local copy=$1 clone=$2 owner stamp='' secs=-1 age=unknown source=unknown rc=0
  [ -d "$copy" ] || return 0
  owner=$(printf '%s' "$LIVE_TASK_COPIES" | awk -F '\t' -v c="$copy" -v root="$clone" '
    ($1 == root || index($1, root "/") == 1) && index(c, $1 "/") == 1 { print $2; exit }')
  [ -n "$owner" ] || return 0
  teardown_copy_lock_file "$copy" || rc=$?
  case "$rc" in
    0) stamp=$(file_mtime "$TEARDOWN_FOREIGN_LOCK_FILE") || stamp=; source=lock ;;
    1) stamp=$(file_mtime "$copy") || stamp=; source=directory ;;
  esac
  case "$stamp" in
    ''|*[!0-9]*) ;;
    *) secs=$((CACHE_NOW - stamp)); [ "$secs" -ge 0 ] || secs=0; age=${secs}s ;;
  esac
  LIVE_NESTED_COUNT=$((LIVE_NESTED_COUNT + 1))
  LIVE_NESTED_ROWS="$LIVE_NESTED_ROWS$secs"$'\t'"$copy"$'\t'"${owner%.meta}"$'\t'"$age"$'\t'"$source"$'\n'
}

scan_clone() {  # <pool> <container> <clone>
  local pool=$1 container=$2 clone=$3 copy nested
  if ! nested=$(list_nested "$clone"); then
    add_note "clone $clone was not read: its registered worktrees cannot be listed"
    return 0
  fi
  # A dedicated descriptor keeps every command inside the loop off its input.
  while IFS= read -r copy <&4; do
    [ -n "$copy" ] || continue
    CLASSIFY_BOUNDED=1
    record_live_nested_copy "$copy" "$clone"
    CLASSIFY_BOUNDED=0
    if [ "$SCAN_MODE" = check ]; then
      CLASS=UNCLASSIFIED
      REASON="check does not classify; run bin/fm-copy-sweep.sh for the class"
    else
      classify "$copy" "$clone" "$pool" "$container"
    fi
    measure_copy "$copy"
    ROWS="$ROWS$container"$'\t'"$pool"$'\t'"$clone"$'\t'"$copy"$'\t'"$CLASS"$'\t'"${SIZE_KIB:--}"$'\t'"$(printf '%s' "$REASON" | tr '\t\n' '  ')"$'\n'
  done 4< <(printf '%s\n' "$nested" | LC_ALL=C sort -u)
}

scan() {  # <mode>
  CACHE_NEW=
  CACHE_NOW=$(now_epoch)
  SCAN_CUT=0
  SCAN_MODE=$1
  ROWS=
  LIVE_NESTED_ROWS=
  LIVE_NESTED_COUNT=0
  LIVE_NESTED_FACT_NEW=0
  # check measures every copy but classifies only the ones it names in a wake,
  # so its time goes to the sizes the budget needs.
  [ "$1" = check ] || scan_processes
  enumerate_clones
  COPIES=$(printf '%s' "$ROWS" | net_sizes)
}

# --- removal -----------------------------------------------------------------

REMOVAL_REPORT=
REMOVED_COUNT=0
FAILED_COUNT=0
FREED_KIB=0
FREED_UNMEASURED=0

log_removal() {  # <copy> <clone> <head> <branch> <kib> <preserved-kib> <proof>
  mkdir -p "$DATA_DIR" 2>/dev/null || return 1
  printf '%s\tremoved\t%s\tclone=%s\thead=%s\tbranch=%s\tkib=%s\tpreserved_kib=%s\tproof=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$REMOVAL_LOG"
}

# <KiB> as GiB, or "-" when it was not measured.
gib_or_dash() {  # <KiB or ->
  case "$1" in ''|*[!0-9]*) printf -- '-' ;; *) kib_to_gib "$1" ;; esac
}

# True only when <driver output> carries a real positive verdict: the whole
# trimmed answer is the literal `allowed=true`, or it is exactly one JSON
# document whose top-level "allowed" key is the boolean true. Text that merely
# mentions allowed=true, a false or non-boolean value, no verdict, an empty or
# malformed answer, and more than one document are not permission.
plan_verdict_allows() {  # <driver output>
  local out=$1
  out=${out#"${out%%[![:space:]]*}"}
  out=${out%"${out##*[![:space:]]}"}
  [[ $out =~ ^allowed[[:blank:]]*=[[:blank:]]*true$ ]] && return 0
  printf '%s' "$out" | jq -s -e 'length == 1 and (.[0] | type == "object" and .allowed == true)' >/dev/null 2>&1
}

# The plan's process group, while one runs. Killing the whole group is the only
# way the driver and what it started stop with the sweep, so every exit path of
# the plan, and the sweep's own signal traps, go through stop_plan.
PLAN_PID=
stop_plan() {
  [ -z "$PLAN_PID" ] || kill -s KILL -- "-$PLAN_PID" 2>/dev/null
  PLAN_PID=
}

# Asks Vernant's closeout driver, in plan mode, whether it would release <copy>,
# before anything is copied or hashed. The copy stays unless the driver exits 0
# AND states allowed=true; a non-zero exit, silence, an unparsable verdict, or
# no answer within the plan timeout (FM_COPY_SWEEP_PLAN_TIMEOUT seconds, 120 by
# default) all keep it, with PLAN_WHY holding the driver's own words. The plan
# runs as the leader of its own process group, and the timeout kills that whole
# group, so the driver and anything it started never outlive the sweep.
PLAN_WHY=
driver_plan_allows() {  # <clone> <copy>
  local dir rc=0 limit ticks=0 timed_out=0 pid
  limit=${FM_COPY_SWEEP_PLAN_TIMEOUT:-120}
  case "$limit" in ''|*[!0-9]*) limit=0 ;; esac
  limit=$((10#$limit))
  [ "$limit" -ge 1 ] || limit=120
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-sweep-plan.XXXXXX") || {
    PLAN_WHY="its closeout driver could not be planned (no temporary directory)"
    return 1
  }
  set -m
  (
    local r=0
    teardown_run_closeout "$1" "$2" plan || r=$?
    printf '%s' "$TEARDOWN_CLOSEOUT_OUT" > "$dir/out"
    printf '%s' "$r" > "$dir/rc"
  ) </dev/null &
  pid=$!
  PLAN_PID=$pid
  set +m
  while kill -0 "$pid" 2>/dev/null && [ "$ticks" -lt $((limit * 10)) ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    timed_out=1
  fi
  stop_plan
  wait "$pid" 2>/dev/null
  rc=$(cat "$dir/rc" 2>/dev/null) || rc=1
  TEARDOWN_CLOSEOUT_OUT=$(cat "$dir/out" 2>/dev/null) || TEARDOWN_CLOSEOUT_OUT=
  rm -f "$dir/out" "$dir/rc"
  rmdir "$dir" 2>/dev/null
  if [ "$timed_out" = 1 ]; then
    PLAN_WHY="its closeout driver did not answer within ${limit}s"
    return 1
  fi
  PLAN_WHY=$(printf '%s' "$TEARDOWN_CLOSEOUT_OUT" | tr '\n\t' '  ')
  PLAN_WHY=${PLAN_WHY:0:600}
  if [ "$rc" != 0 ] || ! plan_verdict_allows "$TEARDOWN_CLOSEOUT_OUT"; then
    PLAN_WHY="its closeout driver would not release it (exit ${rc:-1}): ${PLAN_WHY:-no output}"
    return 1
  fi
}

# Preserves the ignored entries of a REAPABLE-DRIVER copy, then releases and
# removes it through Vernant's own closeout driver, which is the only supported
# release for its creation lock. The preservation lands under this sweep's data
# directory in <release-id>, which holds the run stamp and the copy's HEAD, so a
# later copy at the same path never replaces it. The teardown library owns the
# preservation and the driver run; the refusals are the sweep's own, one REFUSED
# line each on stderr, because the library's envelope names a teardown command
# built from the release id, which is no task id.
teardown_driver_release() {  # <clone> <copy> <release-id>
  local clone=$1 copy=$2 rc=0 saved_data=${DATA-} saved_id=${ID-} shown
  shown=$(fm_refuse_text "$copy")
  DATA=$DATA_DIR
  ID=$3
  teardown_preserve_ignored "$copy" || rc=$?
  DATA=$saved_data
  ID=$saved_id
  if [ "$rc" != 0 ]; then
    echo "REFUSED: the ignored files of $shown could not be preserved in $DATA_DIR/$3/nested-copy-preserved; it was not removed. human-only-exit: Which owner-approved storage or disposition preserves them? The next sweep run tries again; no removal or forced cleanup is authorized." >&2
    return 1
  fi
  rc=0
  teardown_copy_lock_file "$copy" || rc=$?
  if [ "$rc" != 0 ] || ! teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK" >/dev/null; then
    echo "REFUSED: $shown is no longer locked by Vernant's exact creation lock; it was not removed. The next sweep run proves it again." >&2
    return 1
  fi
  rc=0
  teardown_run_closeout "$clone" "$copy" || rc=$?
  if [ "$rc" != 0 ]; then
    echo "REFUSED: Vernant's closeout driver did not release $shown (exit $rc): $(fm_refuse_text "${TEARDOWN_CLOSEOUT_OUT:0:600}")" >&2
    return 1
  fi
}

# Removes the REAPABLE-PROVEN and REAPABLE-DRIVER copies, one at a time, deepest
# path first, each proved again just before its own removal. An unlocked copy
# goes by plain `git worktree remove` run from the registering clone: it refuses
# a dirty or locked copy by itself. A driver-releasable copy goes through
# Vernant's closeout driver, planned first: a copy the plan refuses is held with
# the driver's reason and nothing is copied. A failure after the plan was allowed
# leaves the copy and is reported, never retried harder.
apply_removals() {
  local line container pool clone copy kib head branch err refusal freed gone='' held='' stamp
  local release_id preserve_dir preserved net
  stamp=$(date -u +%Y%m%dT%H%M%SZ).$$
  REMOVAL_REPORT=
  REMOVED_COUNT=0
  FAILED_COUNT=0
  FREED_KIB=0
  FREED_UNMEASURED=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r container pool clone copy _ kib _ <<< "$line"
    scan_processes
    classify "$copy" "$clone" "$pool" "$container"
    case "$CLASS" in
      REAPABLE-PROVEN) ;;
      REAPABLE-DRIVER) ;;
      *)
        REMOVAL_REPORT="${REMOVAL_REPORT}SKIPPED"$'\t'"$copy"$'\t'"no longer proven: $CLASS, $REASON"$'\n'
        continue
        ;;
    esac
    head=$(git -C "$copy" rev-parse HEAD 2>/dev/null) || head=unknown
    branch=$(git -C "$copy" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=detached
    preserve_dir=
    if [ "$CLASS" = REAPABLE-DRIVER ]; then
      # The copy is Vernant-locked with a dead or recycled launcher. Its own
      # driver is the only supported release: it unlocks and removes, after the
      # teardown library preserved every ignored entry it holds.
      if ! driver_plan_allows "$clone" "$copy"; then
        held="$held$copy"$'\t'"$PLAN_WHY"$'\n'
        continue
      fi
      release_id="$CHECK_ID/$stamp-$head"
      preserve_dir="$DATA_DIR/$release_id/nested-copy-preserved"
      if ! err=$(teardown_driver_release "$clone" "$copy" "$release_id" 2>&1); then
        FAILED_COUNT=$((FAILED_COUNT + 1))
        refusal=$(printf '%s\n' "$err" | sed -n '/^REFUSED:/,$p')
        REMOVAL_REPORT="${REMOVAL_REPORT}FAILED"$'\t'"$copy"$'\t'"the copy was left: $(printf '%s' "${refusal:-$err}" | tr '\n\t' '  ')"$'\n'
        continue
      fi
    elif ! err=$(git -C "$clone" worktree remove -- "$copy" 2>&1); then
      FAILED_COUNT=$((FAILED_COUNT + 1))
      REMOVAL_REPORT="${REMOVAL_REPORT}FAILED"$'\t'"$copy"$'\t'"git worktree remove refused and the copy was left: $(printf '%s' "$err" | head -1)"$'\n'
      continue
    fi
    if [ -e "$copy" ] || [ -L "$copy" ] || list_nested "$clone" | grep -qxF "$copy"; then
      FAILED_COUNT=$((FAILED_COUNT + 1))
      REMOVAL_REPORT="${REMOVAL_REPORT}FAILED"$'\t'"$copy"$'\t'"it is still present or registered after its removal"$'\n'
      continue
    fi
    REMOVED_COUNT=$((REMOVED_COUNT + 1))
    gone="$gone$copy"$'\n'
    preserved=0
    if [ -n "$preserve_dir" ]; then
      measure_dir "$preserve_dir"
      preserved=${SIZE_KIB:--}
    fi
    if [[ $kib =~ ^[0-9]+$ && $preserved =~ ^[0-9]+$ ]]; then
      net=$((kib - preserved))
      [ "$net" -ge 0 ] || net=0
      FREED_KIB=$((FREED_KIB + net))
      freed="net freed $(kib_to_gib "$net") GiB"
    else
      FREED_UNMEASURED=$((FREED_UNMEASURED + 1))
      freed="net freed - GiB, unmeasured"
    fi
    freed="copy $(gib_or_dash "$kib") GiB, preserved $(gib_or_dash "$preserved") GiB, $freed"
    REMOVAL_REPORT="${REMOVAL_REPORT}REMOVED"$'\t'"$copy"$'\t'"branch $branch at ${head:0:12}, $freed (${REASON})"$'\n'
    log_removal "$copy" "$clone" "$head" "$branch" "$kib" "$preserved" "$REASON" \
      || { FAILED_COUNT=$((FAILED_COUNT + 1)); REMOVAL_REPORT="${REMOVAL_REPORT}FAILED"$'\t'"$copy"$'\t'"it was removed but $REMOVAL_LOG could not be appended"$'\n'; }
  done < <(printf '%s\n' "$COPIES" | awk -F '\t' '$5 == "REAPABLE-PROVEN" || $5 == "REAPABLE-DRIVER"' | LC_ALL=C sort -t "$(printf '\t')" -k4,4r)
  if [ -n "$gone" ]; then
    COPIES=$(printf '%s\n' "$COPIES" | GONE=$gone awk -F '\t' 'BEGIN { n = split(ENVIRON["GONE"], g, "\n"); for (i = 1; i <= n; i++) if (g[i] != "") drop[g[i]] = 1 } !($4 in drop)')
  fi
  if [ -n "$held" ]; then
    COPIES=$(printf '%s\n' "$COPIES" | HELD=$held awk -F '\t' 'BEGIN { OFS = "\t"; n = split(ENVIRON["HELD"], h, "\n"); for (i = 1; i <= n; i++) if (h[i] != "") { split(h[i], kv, "\t"); why[kv[1]] = kv[2] } } $4 in why { $5 = "HELD-LOCKED"; $7 = why[$4] } { print }')
  fi
}

# --- budgets and the one wake ------------------------------------------------

BUDGET_REPORT=
OVER_NOW=
UNKNOWN_NOW=
WAKE_PARTS=

# The five largest measured copies of a budget, "path size GiB CLASS", comma
# joined. check classifies these few copies here, while time remains.
largest_five() {  # <field> <key>
  local rows container pool clone copy class kib out='' scanned=0
  rows=$(printf '%s\n' "$COPIES" | awk -F '\t' -v f="$1" -v k="$2" '$f == k && $6 != "-" { print }' \
    | LC_ALL=C sort -t "$(printf '\t')" -k6,6nr -k4,4 | head -5)
  while IFS=$'\t' read -r container pool clone copy class kib _; do
    [ -n "$copy" ] || continue
    if [ "$class" = UNCLASSIFIED ] && [ "$SCAN_DEADLINE" -gt 0 ] && [ "$(date +%s)" -lt "$SCAN_DEADLINE" ]; then
      CLASSIFY_BOUNDED=1
      [ "$scanned" = 1 ] || { scan_processes; scanned=1; }
      classify "$copy" "$clone" "$pool" "$container"
      CLASSIFY_BOUNDED=0
      class=$CLASS
      [ "$(date +%s)" -lt "$SCAN_DEADLINE" ] || class=UNCLASSIFIED
    fi
    out="$out${out:+, }$copy $(awk -v k="$kib" 'BEGIN { printf "%.2f", k / 1048576 }') GiB $class"
  done <<< "$rows"
  printf '%s' "$out"
}

# Weighs each budget against its measured bytes. OVER_NOW lists "kind:key" for
# every budget that is over, UNKNOWN_NOW the ones that are not provably under
# because a copy went unmeasured, and WAKE_PARTS the wake text of each budget
# that was not already over at the previous run.
evaluate_budgets() {
  local kind key field gib kib total unknown status members text
  BUDGET_REPORT=
  OVER_NOW=
  UNKNOWN_NOW=
  WAKE_PARTS=
  for kind in pool container; do
    if [ "$kind" = pool ]; then field=2; else field=1; fi
    while IFS= read -r key; do
      [ -n "$key" ] && [ "$key" != - ] || continue
      gib=$(budget_gib_for "$kind" "$key")
      members=$(printf '%s\n' "$COPIES" | awk -F '\t' -v f="$field" -v k="$key" '$f == k')
      read -r total unknown <<< "$(printf '%s\n' "$members" | awk -F '\t' '{ if ($6 == "-") u++; else t += $6 } END { printf "%d %d\n", t, u }')"
      if [ "$gib" = off ]; then
        status=off
      else
        kib=$(gib_to_kib "$gib")
        if [ "$total" -gt "$kib" ]; then
          status=over
        elif [ "$unknown" -gt 0 ]; then
          status=unknown
        else
          status=ok
        fi
      fi
      if [ "$gib" = off ]; then
        BUDGET_REPORT="${BUDGET_REPORT}budget $kind $key: $(kib_to_gib "$total") GiB, no budget (off)"
      else
        BUDGET_REPORT="${BUDGET_REPORT}budget $kind $key: $(kib_to_gib "$total") GiB of $gib GiB, $status"
      fi
      [ "$unknown" -eq 0 ] || BUDGET_REPORT="$BUDGET_REPORT ($unknown copies unmeasured)"
      BUDGET_REPORT="$BUDGET_REPORT"$'\n'
      case "$status" in
        over)
          OVER_NOW="$OVER_NOW$kind:$key"$'\n'
          if ! printf '%s' "$REC_OVER" | grep -qxF "$kind:$key"; then
            text="$kind $key is over its budget: $(kib_to_gib "$total") GiB against $gib GiB; largest copies: $(largest_five "$field" "$key")"
            [ "$unknown" -eq 0 ] || text="$text; $unknown copies unmeasured"
            WAKE_PARTS="${WAKE_PARTS:+$WAKE_PARTS; }$text"
          fi
          ;;
        unknown) UNKNOWN_NOW="$UNKNOWN_NOW$kind:$key"$'\n' ;;
      esac
    done < <(printf '%s\n' "$COPIES" | awk -F '\t' -v f="$field" 'NF { print $f }' | LC_ALL=C sort -u)
  done
}

# A run that skipped its sizing adds one to the count of skipped runs in a row.
# A cut run writes no completed-scan mark, so nothing gates it to one per
# `interval`; it counts only when a whole `interval` has passed since the time
# the streak was last advanced, which the record keeps. Once the count reaches
# SKIP_WAKE_RUNS, "skip:load" stands over like a budget does and raises its wake
# once; the first run that sizes again ends the streak. The hourly --apply and
# the gated `check` each count about once per `interval`, so 6 runs in a row are
# about 6 intervals, 6 hours at the default.
SKIP_WAKE_RUNS=6
SKIP_RUNS_NOW=
SKIP_COUNTED_NOW=

evaluate_skip() {  # <now>
  local now=$1 runs at
  SKIP_RUNS_NOW=
  SKIP_COUNTED_NOW=
  [ -n "$SKIP_LINE" ] || return 0
  runs=$REC_SKIP_RUNS
  at=$REC_SKIP_AT
  case "$runs" in ''|*[!0-9]*) runs=0 ;; esac
  case "$at" in ''|*[!0-9]*) at= ;; esac
  SKIP_RUNS_NOW=$runs
  SKIP_COUNTED_NOW=$at
  if [ "$SCAN_CUT" != 1 ] || [ -z "$at" ] || [ $((now - at)) -ge "$SCAN_INTERVAL" ] || [ "$now" -lt "$at" ]; then
    SKIP_RUNS_NOW=$((runs + 1))
    SKIP_COUNTED_NOW=$now
  fi
  [ "$SKIP_RUNS_NOW" -ge "$SKIP_WAKE_RUNS" ] || return 0
  OVER_NOW="${OVER_NOW}skip:load"$'\n'
  ! printf '%s' "$REC_OVER" | grep -qxF skip:load || return 0
  WAKE_PARTS="${WAKE_PARTS:+$WAKE_PARTS; }$SKIP_LINE on $SKIP_RUNS_NOW runs in a row"
}

# One wake when a copy joins the live copy set, never one per poll. A copy stays
# named in the report while it exists, and its record entry survives a cut scan,
# which cannot prove it gone.
evaluate_live_fact() {
  local path
  LIVE_NESTED_FACT_NEW=0
  LIVE_RECORD_NEW=$(printf '%s' "$LIVE_NESTED_ROWS" | awk -F '\t' 'NF { print $2 }' | LC_ALL=C sort -u)
  if [ "$SCAN_CUT" = 1 ] && [ -n "$REC_LIVE" ]; then
    LIVE_RECORD_NEW=$(printf '%s\n%s\n' "$REC_LIVE" "$LIVE_RECORD_NEW" | sed '/^$/d' | LC_ALL=C sort -u)
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s' "$REC_LIVE" | grep -qxF "$path" && continue
    LIVE_NESTED_FACT_NEW=1
    return 0
  done <<< "$LIVE_RECORD_NEW"
}

# --- the record and the cache ------------------------------------------------

REC_LAST_SCAN=
REC_OVER=
REC_ERROR=
REC_SKIP_RUNS=
REC_SKIP_AT=
REC_SKIP_LINE=
REC_LIVE=

record_usable() {
  local line
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  IFS= read -r line < "$RECORD" || return 1
  [ "$line" = "$RECORD_SCHEMA_LINE" ]
}

read_record() {
  REC_LAST_SCAN=
  REC_OVER=
  REC_ERROR=
  REC_SKIP_RUNS=
  REC_SKIP_AT=
  REC_SKIP_LINE=
  REC_LIVE=
  record_usable || return 0
  REC_LAST_SCAN=$(awk -F '\t' '$1 == "last_scan" { print $2; exit }' "$RECORD")
  REC_OVER=$(awk -F '\t' '$1 == "over" { print $2 }' "$RECORD")
  REC_ERROR=$(awk -F '\t' '$1 == "error" { print $2; exit }' "$RECORD")
  REC_SKIP_RUNS=$(awk -F '\t' '$1 == "skip" { print $2; exit }' "$RECORD")
  REC_SKIP_AT=$(awk -F '\t' '$1 == "skip" { print $3; exit }' "$RECORD")
  REC_SKIP_LINE=$(awk -F '\t' '$1 == "skip" { print $4; exit }' "$RECORD")
  REC_LIVE=$(awk -F '\t' '$1 == "live" { print $2 }' "$RECORD")
}

write_atomic() {  # <destination> <content>
  local dest=$1 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(mktemp "$STATE/.$CHECK_ID.XXXXXX") || return 1
  if ! printf '%s' "$2" > "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Publishes the record: the budgets over now, plus the recorded ones this run
# could not prove back under. A budget with an unmeasured copy is one, and on a
# cut run every recorded budget is, because a cut scan sees only part of any of
# them. Only a complete run clears a standing budget.
write_record() {  # <last-scan> <error>
  local key content
  content="$RECORD_SCHEMA_LINE"$'\n'
  [ -z "$1" ] || content="$content"$'last_scan\t'"$1"$'\n'
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    content="$content"$'over\t'"$key"$'\n'
  done <<< "$OVER_NOW"
  while IFS= read -r key; do
    case "$key" in pool:*|container:*) ;; *) continue ;; esac
    printf '%s' "$OVER_NOW" | grep -qxF "$key" && continue
    if [ "$SCAN_CUT" = 1 ] || printf '%s' "$UNKNOWN_NOW" | grep -qxF "$key"; then
      content="$content"$'over\t'"$key"$'\n'
    fi
  done <<< "$REC_OVER"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    content="$content"$'live\t'"$key"$'\n'
  done <<< "$LIVE_RECORD_NEW"
  [ -z "$SKIP_RUNS_NOW" ] || content="$content"$'skip\t'"$SKIP_RUNS_NOW"$'\t'"$SKIP_COUNTED_NOW"$'\t'"$SKIP_LINE"$'\n'
  [ -z "$2" ] || content="$content"$'error\t'"$2"$'\n'
  write_atomic "$RECORD" "$content"
}

# Rewrites the size cache from what this run measured. A cut run also keeps the
# still-fresh lines of the copies it never reached.
write_cache() {
  local keep='' nl=$'\n'
  if [ "$SCAN_CUT" = 1 ] && [ -f "$SIZE_CACHE" ] && [ ! -L "$SIZE_CACHE" ]; then
    keep=$(printf '%s' "$CACHE_NEW" | awk -F '\t' -v now="$CACHE_NOW" -v age="$CACHE_MAX_AGE" '
      pass == 1 { seen[$1] = 1; next }
      !($1 in seen) && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && now - $3 < age { print }' pass=1 - pass=2 "$SIZE_CACHE")
  fi
  [ -z "$keep" ] || keep=$keep$nl
  write_atomic "$SIZE_CACHE" "$CACHE_NEW$keep"
}

# "<copy> (task=<id> age=<age> source=<source>)" per live copy, "; " joined, for
# the first <limit> rows on stdin.
live_nested_entries() {  # <limit>
  awk -F '\t' -v limit="$1" '
    NF { if (++n > limit) exit; printf "%s%s (task=%s age=%s source=%s)", sep, $2, $3, $4, $5; sep = "; " }'
}

# The full report line: every live copy, in scan order.
live_nested_report() {
  [ "$LIVE_NESTED_COUNT" -gt 0 ] || return 0
  printf 'HELD-LIVE-TASK nested copies=%s: %s' "$LIVE_NESTED_COUNT" \
    "$(printf '%s' "$LIVE_NESTED_ROWS" | live_nested_entries "$LIVE_NESTED_COUNT")"
}

# The wake's part of it: the count, a few copies (those the record has not named
# yet first, then the oldest), and where the rest is.
LIVE_WAKE_COPIES=5
live_nested_wake() {
  local shown=$LIVE_NESTED_COUNT
  [ "$LIVE_NESTED_COUNT" -gt 0 ] || return 0
  [ "$shown" -le "$LIVE_WAKE_COPIES" ] || shown=$LIVE_WAKE_COPIES
  printf 'HELD-LIVE-TASK nested copies=%s, %s shown (new first, then oldest): %s; run bin/fm-copy-sweep.sh with no flag for the full HELD-LIVE-TASK line' \
    "$LIVE_NESTED_COUNT" "$shown" \
    "$(printf '%s' "$LIVE_NESTED_ROWS" | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 \
      | RECORDED="$REC_LIVE" awk -F '\t' '
          BEGIN { n = split(ENVIRON["RECORDED"], r, "\n"); for (i = 1; i <= n; i++) if (r[i] != "") known[r[i]] = 1 }
          NF { if ($2 in known) old[++o] = $0; else print }
          END { for (i = 1; i <= o; i++) print old[i] }' \
      | live_nested_entries "$shown")"
}

# Raises the one wake. `check` prints the line for the watcher to turn into a
# wake; every other mode appends the same `check:` wake itself. Budget details
# retain their cap; the live-copy fact stays one bounded part of the same line.
raise_wake() {  # <mode>
  local line='copy-sweep:'
  [ -n "$WAKE_PARTS" ] || { [ "$LIVE_NESTED_COUNT" -gt 0 ] && [ "$LIVE_NESTED_FACT_NEW" = 1 ]; } || return 0
  if [ -n "$WAKE_PARTS" ]; then
    fm_cap_line_var "copy-sweep: $WAKE_PARTS" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
  fi
  if [ "$LIVE_NESTED_COUNT" -gt 0 ] && [ "$LIVE_NESTED_FACT_NEW" = 1 ]; then
    line="$line $(live_nested_wake)"
  fi
  if [ "$1" = check ]; then
    printf '%s\n' "$line"
  else
    fm_wake_append check "$CHECK_SHIM" "check: $CHECK_SHIM: $line" || return 1
    printf 'copy-sweep: wake raised: %s\n' "$line"
  fi
}

# --- the report --------------------------------------------------------------

print_report() {  # <mode>
  local class kib line container pool clone copy reason size count
  printf 'copy-sweep: mode=%s containers=%s copies=%s\n' "$1" \
    "$(printf '%s\n' "$COPIES" | awk -F '\t' 'NF { c[$1] = 1 } END { n = 0; for (k in c) n++; print n }')" \
    "$(printf '%s\n' "$COPIES" | awk -F '\t' 'NF { n++ } END { print n + 0 }')"
  [ -z "$SKIP_LINE" ] || printf 'copy-sweep: %s\n' "$SKIP_LINE"
  if [ "$1" = report ] && [ "$LIVE_NESTED_COUNT" -gt 0 ]; then
    printf 'copy-sweep: %s\n' "$(live_nested_report)"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r container pool clone copy class kib reason <<< "$line"
    if [ "$kib" = - ]; then size='? GiB'; else size="$(kib_to_gib "$kib") GiB"; fi
    printf '%s\t%s\t%s\t%s\n' "$class" "$size" "$copy" "$reason"
  done < <(printf '%s\n' "$COPIES" | LC_ALL=C sort -t "$(printf '\t')" -k4,4)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done <<< "$REMOVAL_REPORT"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'note: %s\n' "$line"
  done <<< "$NOTES"
  [ "$SCAN_CUT" != 1 ] || printf 'note: the scan stopped at its time bound; unmeasured copies show ? GiB\n'
  for class in REAPABLE-PROVEN REAPABLE-DRIVER HELD-LIVE-TASK HELD-LOCKED HELD-UNPUSHED HELD-DIRTY ORPHAN-NO-RECORD; do
    count=$(printf '%s\n' "$COPIES" | awk -F '\t' -v c="$class" '$5 == c { n++ } END { print n + 0 }')
    printf 'summary: %s=%s\n' "$class" "$count"
  done
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done <<< "$BUDGET_REPORT"
  if [ "$1" = apply ]; then
    printf 'freed %s GiB measured, %s copies unmeasured\n' "$(kib_to_gib "$FREED_KIB")" "$FREED_UNMEASURED"
  fi
}

# --- arm and disarm ----------------------------------------------------------

SHIM_TMP=
ARM_BACKUP=

shim_write() {  # <wanted-bytes> <state-device>
  local want=$1 device=$2
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  SHIM_TMP=$(umask 077; mktemp "$STATE/.$CHECK_ID-shim.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$SHIM_TMP" \
    || ! chmod 0700 "$SHIM_TMP" \
    || ! fm_pr_private_file_valid "$SHIM_TMP" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$SHIM_TMP" "$CHECK_SHIM"; then
    rm -f -- "$SHIM_TMP"
    SHIM_TMP=
    return 1
  fi
  SHIM_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {  # <state-device>
  local device=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.$CHECK_ID-shim.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

arm_rollback() {
  [ -z "$SHIM_TMP" ] || rm -f -- "$SHIM_TMP"
  SHIM_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
}

arm_failed() {  # <message>
  trap - HUP INT TERM
  arm_rollback
  fail "$1"
}

arm() {
  local state_device home want
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$PROC_BUDGET_BIN") -- $(printf '%q' "$SCRIPT_DIR/fm-copy-sweep.sh") check")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup "$state_device") || fail "could not save the existing check shim"
  fi
  trap 'arm_failed "arming was interrupted"' HUP INT TERM
  shim_write "$want" "$state_device" || arm_failed "check shim path is unavailable"
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || arm_failed "could not register the check shim"
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

# --- main --------------------------------------------------------------------

LOCK_HELD=0
release_lock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$SWEEP_LOCK"
  LOCK_HELD=0
}

run_sweep() {  # report|apply|check
  local mode=$1 cap now rc=0
  if ! load_config; then
    if [ "$mode" = check ]; then
      read_record
      if [ "$REC_ERROR" != "$CONFIG_ERROR" ]; then
        printf 'copy-sweep: %s\n' "$CONFIG_ERROR"
        OVER_NOW=$REC_OVER
        SKIP_LINE=$REC_SKIP_LINE
        SKIP_RUNS_NOW=$REC_SKIP_RUNS
        SKIP_COUNTED_NOW=$REC_SKIP_AT
        LIVE_RECORD_NEW=$REC_LIVE
        write_record "$REC_LAST_SCAN" "$CONFIG_ERROR" || true
      fi
      return 0
    fi
    fail "$CONFIG_ERROR" 2
  fi
  if [ "$mode" != report ]; then
    if ! fm_lock_try_acquire "$SWEEP_LOCK"; then
      [ "$mode" = check ] || printf 'copy-sweep: another sweep holds %s; nothing was done\n' "$SWEEP_LOCK"
      return 0
    fi
    LOCK_HELD=1
    trap 'stop_plan; release_lock' EXIT
    trap 'stop_plan; release_lock; exit 1' HUP INT TERM
  fi
  read_record
  now=$(now_epoch)
  if [ "$mode" = check ]; then
    case "$REC_LAST_SCAN" in
      ''|*[!0-9]*) ;;
      *) [ $((now - REC_LAST_SCAN)) -ge "$SCAN_INTERVAL" ] || [ $((now - REC_LAST_SCAN)) -lt 0 ] || return 0 ;;
    esac
  fi
  SIZING=1
  load_allows_sizing || SIZING=0
  SCAN_DEADLINE=0
  if [ "$mode" = check ]; then
    # The watcher runs a check under FM_CHECK_TIMEOUT; stay clear of it.
    cap=${FM_CHECK_TIMEOUT:-30}
    case "$cap" in *[!0-9]*) cap=30 ;; esac
    cap=$(( 10#$cap - 5 ))
    [ "$cap" -ge 1 ] || cap=1
    SCAN_DEADLINE=$(( $(date +%s) + cap ))
  fi
  APPLY=0
  [ "$mode" != apply ] || APPLY=1
  scan "$mode"
  [ "$mode" = report ] || evaluate_live_fact
  REMOVAL_REPORT=
  if [ "$mode" = apply ]; then
    apply_removals
    [ "$FAILED_COUNT" -eq 0 ] || rc=1
  fi
  evaluate_budgets
  evaluate_skip "$now"
  if [ "$mode" != report ]; then
    write_cache || { echo "fm-copy-sweep: could not write $SIZE_CACHE" >&2; rc=1; }
    if ! raise_wake "$mode"; then
      echo "fm-copy-sweep: could not raise the notification; the record was left so the next run raises it" >&2
      return 1
    fi
    if [ "$SCAN_CUT" = 1 ]; then
      write_record "$REC_LAST_SCAN" "" || rc=1
    else
      write_record "$now" "" || { echo "fm-copy-sweep: could not write $RECORD" >&2; rc=1; }
    fi
  fi
  [ "$mode" = check ] || print_report "$mode"
  return "$rc"
}

case "${1:-}" in
  '')
    [ "$#" -le 1 ] || { usage >&2; exit 2; }
    run_sweep report
    exit $?
    ;;
  --apply)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    run_sweep apply
    exit $?
    ;;
  check)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    run_sweep check
    exit $?
    ;;
  arm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    arm
    ;;
  disarm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    disarm
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
