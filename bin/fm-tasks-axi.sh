#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Accepted arguments reach tasks-axi as given except for
# captain-drop completion below and file addressing: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# Supported completion grammar: an optional `task` noun, `done` or `close`,
# exactly one ID, and --pr, --report, --note, --drop-file, --keep, --no-prune,
# --json, or --help. Valued options accept split or = forms; --keep requires a
# non-negative count. `start` and `reopen` accept the same noun and single-ID
# forms with only --json or --help. Exact unconsumed --help prints help without
# mutation and may omit the ID; a help token consumed as a value is refused.
# Unknown or global options (including --backend), option-like values, and
# extra positionals are refused before writes; use tasks-axi directly for
# unsupported grammar.
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
#     a row would lack (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file;
#   - `done`/`close` (with or without the optional `task` noun) of a ship or scout row
#     without proof that its deliverable exists: a regular, nonsymlink,
#     non-empty report for a scout, a GitHub pull request the forge reports
#     merged for a ship, or --drop-file carrying the captain's own words.
#     The drop file must be regular and nonsymlink, contain non-whitespace
#     words without NUL bytes, and be 1..8192 bytes; the exact words are retained
#     at data/<id>/captain-drop.md and the row records only the fixed note
#     "dropped". Do not combine --drop-file with --pr, --report, or --note.
#     A live task record completes only through bin/fm-teardown.sh, which owns the
#     landing proof; a local-only merge records itself there too. Other row kinds
#     close as before, and a help token never reaches this guard.
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"

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

parse_task_mutation() {
  local tokens=("$@") i=0 expect='' token bounded=0
  TASK_COMMAND=
  TASK_ID=
  TASK_HELP=0
  TASK_PR=
  TASK_REPORT=
  TASK_DROP=
  TASK_NOTE=0
  [ "${tokens[0]:-}" != task ] || i=1
  TASK_COMMAND=${tokens[i]:-}
  case "$TASK_COMMAND" in
    -*) fail "unsupported global options; run tasks-axi directly for that invocation" ;;
    done|close|start|reopen) bounded=1 ;;
    hold|unhold|update|edit) ;;
    *) return 0 ;;
  esac
  for token in "${tokens[@]:$((i + 1))}"; do
    if [ -n "$expect" ]; then
      if [ "$bounded" = 1 ]; then
        case "$token" in
          ''|-*) fail "$expect requires a value, not an option; run tasks-axi directly for other grammar" ;;
        esac
        if [ "$expect" = --keep ] && ! [[ "$token" =~ ^[0-9]+$ ]]; then
          fail "--keep requires a non-negative count; run tasks-axi directly for other grammar"
        fi
      fi
      case "$expect" in
        --pr) TASK_PR=$token ;; --report) TASK_REPORT=$token ;;
        --drop-file) TASK_DROP=$token ;; --note) TASK_NOTE=1 ;;
      esac
      expect=''
      continue
    fi
    if [ "$bounded" = 1 ]; then
      case "$TASK_COMMAND:$token" in
        *:--help) TASK_HELP=1; continue ;;
        *:--json) continue ;;
        done:--no-prune|close:--no-prune) continue ;;
        done:--pr|close:--pr|done:--report|close:--report|done:--drop-file|close:--drop-file|done:--note|close:--note|done:--keep|close:--keep)
          expect=$token; continue ;;
        done:--pr=*|close:--pr=*|done:--report=*|close:--report=*|done:--drop-file=*|close:--drop-file=*|done:--note=*|close:--note=*|done:--keep=*|close:--keep=*)
          expect=${token%%=*}
          token=${token#*=}
          case "$token" in
            ''|-*) fail "$expect requires a value, not an option; run tasks-axi directly for other grammar" ;;
          esac
          case "$expect" in
            --pr) TASK_PR=$token ;; --report) TASK_REPORT=$token ;;
            --drop-file) TASK_DROP=$token ;; --note) TASK_NOTE=1 ;;
            --keep) [[ "$token" =~ ^[0-9]+$ ]] || fail "--keep requires a non-negative count; run tasks-axi directly for other grammar" ;;
          esac
          expect=''
          continue ;;
        *:-*) fail "unsupported $TASK_COMMAND option '$token'; run tasks-axi directly for that invocation" ;;
      esac
      [ -z "$TASK_ID" ] || fail "$TASK_COMMAND accepts exactly one id; run tasks-axi directly for other grammar"
      [[ "$token" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsupported task id '$token'; run tasks-axi directly for that invocation"
      TASK_ID=$token
      continue
    fi
    case "$token" in
      -h|--help) TASK_HELP=1 ;;
      --pr|--report|--drop-file|--note|--keep|--backend|--reason|--until|--kind|--title|--body|--body-file|--repo|--priority) expect=$token ;;
      --pr=*) TASK_PR=${token#*=} ;; --report=*) TASK_REPORT=${token#*=} ;;
      --drop-file=*) TASK_DROP=${token#*=} ;; --note=*) TASK_NOTE=1 ;;
      -*) ;;
      *) [ -n "$TASK_ID" ] || TASK_ID=$token ;;
    esac
  done
  if [ "$bounded" = 1 ]; then
    [ -z "$expect" ] || fail "$expect requires a value; run tasks-axi directly for other grammar"
    [ "$TASK_HELP" = 1 ] || [ -n "$TASK_ID" ] || fail "$TASK_COMMAND requires exactly one id; run tasks-axi directly for other grammar"
  fi
}

TASK_CONTROL_LOCK_HELD=0
TASK_META_LOCK_HELD=0
task_mutation_cleanup() {
  if [ "$TASK_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TASK_META_LOCK" || true
    TASK_META_LOCK_HELD=0
  fi
  if [ "$TASK_CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TASK_CONTROL_LOCK" || true
    TASK_CONTROL_LOCK_HELD=0
  fi
}

guard_completion() {
  local id=$TASK_ID pr=$TASK_PR report=$TASK_REPORT drop note=$TASK_NOTE
  drop=$(absolute_from_caller "$TASK_DROP")
  case "$TASK_COMMAND" in done|close) ;; *) return 0 ;; esac
  [ "$TASK_CONTROL_LOCK_HELD" = 1 ] || return 0
  fm_backlog_row_probe "$DATA" "$id" || {
    [ "$FM_BACKLOG_ROW_RESULT" = not_found ] && return 0
    fail "cannot identify the task being completed: ${FM_BACKLOG_ROW_ERROR:-unreadable backlog}"
  }
  case "$FM_BACKLOG_ROW_KIND" in ship|scout) ;; *) return 0 ;; esac
  [ ! -e "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta" ] \
    || fail "$id has a live task record; complete it with bin/fm-teardown.sh $id, which owns the landing proof"
  if [ "${FM_BACKLOG_ROW_STATE%% *}" != "done" ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
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
resolved_data=$(fm_backlog_data_absolute "$DATA") \
  || fail "data directory cannot be resolved: $DATA"
DATA=$resolved_data
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
parse_task_mutation "$@"
if [ "$TASK_HELP" = 0 ] && [[ "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  trap task_mutation_cleanup EXIT
  case "$STATE" in /*) task_state=$STATE ;; *) task_state="$CALLER_DIR/$STATE" ;; esac
  TASK_CONTROL_LOCK="$task_state/.control-$TASK_ID.lock"
  TASK_META_LOCK=$(fm_meta_lock_path "$task_state/$TASK_ID.meta") || fail "cannot resolve the task record lock for $TASK_ID"
  fm_lock_acquire_wait "$TASK_CONTROL_LOCK"
  TASK_CONTROL_LOCK_HELD=1
  fm_lock_acquire_wait "$TASK_META_LOCK"
  TASK_META_LOCK_HELD=1
fi
guard_completion
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
case "${1:-}" in
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
case "$TASK_COMMAND" in
  reopen|start)
    if [ "$TASK_CONTROL_LOCK_HELD" = 1 ]; then
      if [ "$TASK_COMMAND" = start ]; then target_state=in_flight; else target_state=queued; fi
      fm_backlog_new_work_transition "$DATA" "$TASK_ID" "$target_state" tasks-axi "${ARGS[@]}"
      result=$?
      if [ "$result" -ne 0 ] && [ -n "$FM_BACKLOG_TRANSITION_ERROR" ]; then
        printf 'fm-tasks-axi: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
      fi
      exit "$result"
    fi
    ;;
esac
if [ "$TASK_CONTROL_LOCK_HELD" = 1 ]; then
  tasks-axi ${ARGS[@]+"${ARGS[@]}"}
  exit "$?"
fi
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
