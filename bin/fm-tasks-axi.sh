#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file;
#   - `done`/`close` (with or without the optional `task` noun) of a ship or scout row
#     without proof that its deliverable exists: a written non-empty report for a
#     scout, a GitHub pull request the forge reports merged for a ship, or
#     --drop-file carrying the captain's own words (1..8192 bytes, retained at
#     data/<id>/captain-drop.md; the row then records the fixed note "dropped").
#     A live task record completes only through bin/fm-teardown.sh, which owns the
#     landing proof; a local-only merge records itself there too. Other row kinds
#     close as before, and a help token never reaches this guard.
# Otherwise the exit status is tasks-axi's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

# The completion guard reads the actual argument tokens: a value (a note that happens to
# read "--help") is never a flag, and the optional `task` noun is normalized away.
guard_completion() {
  local tokens=("$@") i=0 command='' id='' expect='' token pr='' report='' drop='' help=0 note=0
  [ "${tokens[0]:-}" != task ] || i=1
  command=${tokens[i]:-}
  case "$command" in done|close) ;; *) return 0 ;; esac
  for token in "${tokens[@]:$((i + 1))}"; do
    if [ -n "$expect" ]; then
      case "$expect" in
        --pr) pr=$token ;; --report) report=$token ;; --drop-file) drop=$token ;; --note) note=1 ;;
        --keep|--backend) ;;
      esac
      expect=''
      continue
    fi
    case "$token" in
      -h|--help) help=1 ;;
      --pr|--report|--drop-file|--note|--keep|--backend) expect=$token ;;
      --pr=*) pr=${token#*=} ;; --report=*) report=${token#*=} ;;
      --drop-file=*) drop=${token#*=} ;; --note=*) note=1 ;;
      -*) ;;
      *) [ -n "$id" ] || id=$token ;;
    esac
  done
  [ "$help" = 0 ] || return 0
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  fm_backlog_row_probe "$DATA" "$id" || {
    [ "$FM_BACKLOG_ROW_RESULT" = not_found ] && return 0
    fail "cannot identify the task being completed: ${FM_BACKLOG_ROW_ERROR:-unreadable backlog}"
  }
  case "$FM_BACKLOG_ROW_KIND" in ship|scout) ;; *) return 0 ;; esac
  [ ! -e "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta" ] \
    || fail "$id has a live task record; complete it with bin/fm-teardown.sh $id, which owns the landing proof"
  if [ "${FM_BACKLOG_ROW_STATE%% *}" != done ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
    fail "$id is an open captain call; resolve it with bin/fm-captain-hold.sh answer or reconcile close before completing the deliverable"
  fi
  if [ -n "$drop" ]; then
    [ -z "$pr$report" ] && [ "$note" = 0 ] \
      || fail "a captain's drop is its own completion; do not combine --drop-file with --pr, --report, or --note"
    fm_backlog_drop_record "$DATA" "$id" "$drop" \
      || fail "--drop-file must be a regular file holding the captain's own words (1..8192 bytes)"
    GUARD_ARGS=(--note dropped)
    GUARD_STRIP_DROP=1
  elif [ -n "$report" ]; then
    [ "$FM_BACKLOG_ROW_KIND" = scout ] \
      || fail "a report is not a ship's deliverable; land its pull request or record the captain's drop"
    case "$report" in /*) ;; *) report="$FM_BACKLOG_AXI_ROOT/$report" ;; esac
    [ -f "$report" ] && [ ! -L "$report" ] && [ -s "$report" ] \
      || fail "the report has not been written: $report"
  elif [ -n "$pr" ]; then
    [ "$FM_BACKLOG_ROW_KIND" = ship ] || fail "a scout's deliverable is its written report"
    [[ "$pr" =~ ^https://github[.]com/([^/]+/[^/]+)/pull/([0-9]+)$ ]] \
      || fail "only a GitHub pull request can be proved merged here; complete other deliveries with bin/fm-teardown.sh or record the captain's drop"
    gh-axi api "/repos/${BASH_REMATCH[1]}/pulls/${BASH_REMATCH[2]}" --jq '"merged=" + ((.merged_at != null)|tostring)' --full 2>/dev/null \
      | grep -Eq '^  body: "?merged=true"?$' || fail "the pull request has not merged: $pr"
  else
    fail "completion needs proof of the deliverable: --report (scout), a merged --pr (ship), or --drop-file with the captain's words"
  fi
}

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

GUARD_ARGS=()
GUARD_STRIP_DROP=0
guard_completion ${ARGS[@]+"${ARGS[@]}"}
if [ "$GUARD_STRIP_DROP" = 1 ]; then
  # The drop words stay in the retained file; tasks-axi receives only the fixed note.
  kept=()
  skip=0
  for arg in "${ARGS[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$arg" in --drop-file) skip=1; continue ;; --drop-file=*) continue ;; esac
    kept+=("$arg")
  done
  ARGS=("${kept[@]}" "${GUARD_ARGS[@]}")
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
new_work_command=${ARGS[0]:-}
new_work_offset=1
if [ "$new_work_command" = task ]; then
  new_work_command=${ARGS[1]:-}
  new_work_offset=2
fi
case "$new_work_command" in
  reopen|start)
    new_work_id=''
    new_work_help=0
    new_work_backend_next=0
    for arg in "${ARGS[@]:$new_work_offset}"; do
      if [ "$new_work_backend_next" = 1 ]; then
        new_work_backend_next=0
        continue
      fi
      case "$arg" in
        -h|--help) new_work_help=1 ;;
        --backend) new_work_backend_next=1 ;;
        -*) ;;
        *) [ -n "$new_work_id" ] || new_work_id=$arg ;;
      esac
    done
    if [ "$new_work_help" = 0 ] && [[ "$new_work_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
      fm_backlog_new_work_transition "$DATA" "$new_work_id" tasks-axi "${ARGS[@]}"
      result=$?
      if [ "$result" -ne 0 ] && [ -n "$FM_BACKLOG_TRANSITION_ERROR" ]; then
        printf 'fm-tasks-axi: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
      fi
      exit "$result"
    fi
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
