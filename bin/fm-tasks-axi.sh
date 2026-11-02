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
# exactly one ID, and --pr, --report, --note, --drop-file, --duplicate-of,
# --moved-to, --keep, --no-prune, --json, or --help. Valued options accept split
# or = forms except --moved-to, which takes two values (`--moved-to <home>
# <item-id>`); --keep requires a non-negative count. `start` and `reopen` accept the same noun and single-ID
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
# Relative FM_HOME, FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE paths are anchored
# to the caller before changing directory, so ledger writes keep the same home.
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
#   - `add`/`create` without an objective, or with a title that overlaps an
#     open or recently closed item (see "Intake" below), or `done`/`close` with a
#     closing proof the checks below stop. No flag or environment variable waives
#     any of them. docs/guards/registry.json registers these guards (backlog-intake-*
#     and backlog-close-*). Each policy refusal prints the bin/fm-refuse-lib.sh
#     envelope above its message, and each decision writes one guard event on
#     backlog-intake-duplicate: --dup-of agrees with that guard and records
#     cleared_by dup-of, and --not-dup waives it and also records --override.
#
# Intake. Every `add` (and the `create` alias, with or without the `task` noun,
# the title positional or `--title`, and `--mint`) must name the objective the
# item serves: `--objective O1`..`O7`, the ids that docs/objectives.md lists, or
# `--objective none --objective-reason "<why>"`. An unknown id, or `none` with no
# reason, is refused, and so is an `--dup-of` or `--not-dup` without one. The
# objective and its reason land in data/backlog-review.tsv, one line per filed
# item (id, review-by left empty, objective, reason), because tasks-axi has no
# field for them. The file is
# checked writable before anything is filed, and an item whose line fails to
# write is removed again. An add whose title overlaps a Queued or In flight item,
# or one of the 50 newest Done items, is refused with the three best neighbours
# and the two overrides as full commands: `--dup-of <kept-id>` appends the new
# title and body to that kept item in the active backlog through `tasks-axi
# update --archive-body` and files nothing (an item that is only in the done
# archive is refused with a pointer to `--not-dup`), and `--not-dup <id>`, given
# once and naming a qualifying neighbour, files the item. All four intake flags
# refuse an empty or option-like value in split and = form alike. An add is never
# its own neighbour, and `--dup-of` its own id is refused. A backlog
# or done archive that cannot be read stops the add. bin/fm-backlog-intake.py
# owns the overlap rule, the Done window, and the owner-filed pattern; the
# objective list is docs/objectives.md; docs/configuration.md states the rule.
#
# Closing proofs. `done`/`close` also accepts two proofs that need no deliverable
# and no owner words, for an item of any kind:
#   --duplicate-of <kept-id>  the kept item exists and is Queued or In flight;
#                             the duplicate's title and body are appended to it
#                             first (under the kept item's control lock, with the
#                             body read again before the write), then the
#                             duplicate closes.
#   --moved-to <home> <id>    <home> is registered exactly once in the
#                             secondmate registry of this operation's own data
#                             directory, is a different backlog from this one, and
#                             its own backlog holds <id> open. A local home is read
#                             through tasks-axi; a remote home through bin/fm-on.sh.
# Both stop at an item the owner filed (bin/fm-backlog-intake.py OWNER_PATTERN), an
# open owner call (bin/fm-captain-hold.sh open, where a call it cannot read counts
# as undecided), an item with a live task record, a closed item, and an item that
# still blocks an open item (the refusal names those items and how to re-point
# them; nothing re-points them for you); neither combines with --pr, --report,
# --drop-file, or --note. The closing note records
# the proof ("duplicate of <kept-id>", "moved to <home> as <id>").
# FM_TASKS_AXI_REFUSE_OPEN_CALL=1 (set only by bin/fm-pr-close-items.sh) makes the `done`/`close` guard
# also refuse an open captain hold on a row of any kind, inside the lock; without it a
# row that is not a ship or scout closes as before.
# A `done`/`close` (or a `public-followup record-delivery`/`waive` that left the row Done
# or archived it) that tasks-axi accepted also removes the finished id from every other
# item's blocked-by list, so work stops waiting on a blocker that is done; the cleared
# edges are reported on stderr as `unblocked:` lines
# (bin/fm-backlog-transition-lib.sh's fm_backlog_unblock_dependents owns the rule).
# Opt-in fleet activity ledger (docs/fleet-ledger.md): an `add` that created a
# new item also appends one task.filed record, and a `done`/`close` that passed
# the proof check above and moved a row to Done appends one task.closed record
# (bin/fm-backlog-transition-lib.sh, which writes a repeat of a close once). The
# command's stdout and exit status stay tasks-axi's own (stderr carries only the
# `unblocked:`/`actionable:` lines above and tasks-axi's own diagnostics); an add that
# found the id already present (tasks-axi reports `already`) writes nothing, and
# a failed ledger write costs one stderr line. While config/fleet-ledger is
# absent the command runs as before.
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
# shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-refuse-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-refuse-lib.sh"
INTAKE_HELPER="$SCRIPT_DIR/fm-backlog-intake.py"
OBJECTIVES_FILE="$SCRIPT_DIR/../docs/objectives.md"

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

# One policy refusal of a backlog-intake-* or backlog-close-* guard: the guard
# event and the fm_refuse envelope. With <message> it then fails with that message;
# without one it returns, for a caller that prints a longer refusal itself.
backlog_refuse() {  # <guard> <rule> <missing> <machine|human-only> <next-step> <subject> [<message>]
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-guard-event.sh" "$1" deny --source-ok true 2>/dev/null || true
  FM_HOME="$FM_HOME" FM_FRICTION_REVISION_FILE="${FM_FRICTION_REVISION_FILE:-$SCRIPT_DIR/fm-tasks-axi.sh}" \
    fm_refuse "$1" "$2" "$3" "$4" "$5" backlog-item "$6"
  [ "$#" -lt 7 ] || fail "$7"
}

# The guard's source cannot be read, so it fails closed. This is not a policy
# judgment, so the event marks the source and no envelope is printed.
backlog_source_stop() {  # <guard> <message>
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-guard-event.sh" "$1" deny --source-ok false 2>/dev/null || true
  fail "$2"
}

backlog_guard_allow() {  # <guard> [<writer options>...]
  local guard=$1
  shift
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-guard-event.sh" "$guard" allow "$@" 2>/dev/null || true
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)
ORIG_ARGS=("$@")  # the command as typed, for the override lines a refusal prints
# These directories are used again after entering the backlog root. Preserve
# their caller-relative meaning for ledger configuration and state writes too.
case "$FM_HOME" in /*) ;; *) FM_HOME="$CALLER_DIR/$FM_HOME" ;; esac
case "${FM_STATE_OVERRIDE:-}" in ''|/*) ;; *) FM_STATE_OVERRIDE="$CALLER_DIR/$FM_STATE_OVERRIDE" ;; esac
case "${FM_CONFIG_OVERRIDE:-}" in ''|/*) ;; *) FM_CONFIG_OVERRIDE="$CALLER_DIR/$FM_CONFIG_OVERRIDE" ;; esac

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
  TASK_DUP_OF=
  TASK_MOVED_HOME=
  TASK_MOVED_ITEM=
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
        --duplicate-of) TASK_DUP_OF=$token ;;
        --moved-to) TASK_MOVED_HOME=$token; expect=--moved-to-item; continue ;;
        --moved-to-item) TASK_MOVED_ITEM=$token ;;
      esac
      expect=''
      continue
    fi
    if [ "$bounded" = 1 ]; then
      case "$TASK_COMMAND:$token" in
        *:--help) TASK_HELP=1; continue ;;
        *:--json) continue ;;
        done:--no-prune|close:--no-prune) continue ;;
        done:--pr|close:--pr|done:--report|close:--report|done:--drop-file|close:--drop-file|done:--note|close:--note|done:--keep|close:--keep|done:--duplicate-of|close:--duplicate-of|done:--moved-to|close:--moved-to)
          expect=$token; continue ;;
        done:--moved-to=*|close:--moved-to=*)
          fail "--moved-to takes two values: --moved-to <home> <item-id>" ;;
        done:--pr=*|close:--pr=*|done:--report=*|close:--report=*|done:--drop-file=*|close:--drop-file=*|done:--note=*|close:--note=*|done:--keep=*|close:--keep=*|done:--duplicate-of=*|close:--duplicate-of=*)
          expect=${token%%=*}
          token=${token#*=}
          case "$token" in
            ''|-*) fail "$expect requires a value, not an option; run tasks-axi directly for other grammar" ;;
          esac
          case "$expect" in
            --pr) TASK_PR=$token ;; --report) TASK_REPORT=$token ;;
            --drop-file) TASK_DROP=$token ;; --note) TASK_NOTE=1 ;;
            --duplicate-of) TASK_DUP_OF=$token ;;
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
    case "$expect" in
      --moved-to-item) fail "--moved-to takes two values: --moved-to <home> <item-id>" ;;
    esac
    [ -z "$expect" ] || fail "$expect requires a value; run tasks-axi directly for other grammar"
    [ "$TASK_HELP" = 1 ] || [ -n "$TASK_ID" ] || fail "$TASK_COMMAND requires exactly one id; run tasks-axi directly for other grammar"
  fi
}

TASK_CONTROL_LOCK_HELD=0
TASK_META_LOCK_HELD=0
task_mutation_cleanup() {
  kept_lock_release
  if [ "$TASK_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TASK_META_LOCK" || true
    TASK_META_LOCK_HELD=0
  fi
  if [ "$TASK_CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TASK_CONTROL_LOCK" || true
    TASK_CONTROL_LOCK_HELD=0
  fi
}

intake_python() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the backlog intake and closing-proof checks"
  python3 "$INTAKE_HELPER" "$@"
}

# The kept item's control lock serializes this append with every other wrapper
# command on that item; it is taken without waiting, so two items that name each
# other cannot deadlock. A direct tasks-axi write is not serialized, which the
# read-compare-write in append_to_kept covers.
KEPT_LOCK=
KEPT_LOCK_HELD=0
kept_lock_acquire() {  # <kept-id>
  local st
  # shellcheck disable=SC2153  # STATE comes from fm-wake-lib.sh
  case "$STATE" in /*) st=$STATE ;; *) st="$CALLER_DIR/$STATE" ;; esac
  trap task_mutation_cleanup EXIT
  KEPT_LOCK="$st/.control-$1.lock"
  fm_lock_try_acquire "$KEPT_LOCK" \
    || { KEPT_LOCK=; fail "another command is changing the kept item $1; run this again in a moment"; }
  KEPT_LOCK_HELD=1
}
kept_lock_release() {
  if [ "$KEPT_LOCK_HELD" = 1 ]; then
    fm_lock_release "$KEPT_LOCK" || true
    KEPT_LOCK_HELD=0
  fi
}

# Append <title> and <body> to the kept item <kept> through tasks-axi's
# recoverable body rewrite (--archive-body keeps the old body). The body is read
# again just before the write; a change in between is read afresh and merged, so
# another writer's text is never overwritten. A repeat after an interrupted run
# finds the whole block (the exact marker line and the body) already in the body
# and adds nothing; any other text is appended.
append_to_kept() {  # <kept-id> <origin label> <title> <body>
  local kept=$1 label=$2 title=$3 body=$4 shown again current latest block tmp attempt=0
  block=$(printf -- '---\nMerged from %s: %s\n%s' "$label" "$title" "$body")
  kept_lock_acquire "$kept"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-tasks-axi-merge.XXXXXX" 2>/dev/null) \
    || fail "cannot create a scratch file to merge into $kept"
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    shown=$(fm_backlog_row_show "$DATA" "$kept" --full) \
      || { rm -f -- "$tmp"; fail "cannot read the kept item $kept: $(printf '%s\n' "$shown" | sed -n '1p')"; }
    current=$(printf '%s\n' "$shown" | intake_python field body) || current=
    case $'\n'"$current"$'\n' in *$'\n'"$block"$'\n'*) rm -f -- "$tmp"; kept_lock_release; return 0 ;; esac
    {
      [ -z "$current" ] || printf '%s\n\n' "$current"
      printf '%s\n' "$block"
    } > "$tmp"
    again=$(fm_backlog_row_show "$DATA" "$kept" --full) \
      || { rm -f -- "$tmp"; fail "cannot read the kept item $kept: $(printf '%s\n' "$again" | sed -n '1p')"; }
    latest=$(printf '%s\n' "$again" | intake_python field body) || latest=
    [ "$latest" = "$current" ] || continue
    fm_backlog_mutate "$DATA" update "$kept" --body-file "$tmp" --archive-body \
      || { rm -f -- "$tmp"; fail "could not append to the kept item $kept: ${FM_BACKLOG_TRANSITION_ERROR:-tasks-axi said no}"; }
    rm -f -- "$tmp"
    kept_lock_release
    return 0
  done
  rm -f -- "$tmp"
  fail "the kept item $kept changed three times while its text was being read; nothing was appended, try again"
}

# Read <item> in the registered remote home <home> through bin/fm-on.sh, which
# owns the route, the transport, and the remote wrapper's own backlog addressing.
# Sets REMOTE_ITEM_STATE on success. Exit 1: the item is absent there; exit 2: the
# remote backlog cannot be read (the transport failed or the answer is not a task
# record), with the reason in REMOTE_ITEM_ERROR. Call it in this shell, not in a
# command substitution, so both values reach the caller.
REMOTE_ITEM_STATE=
REMOTE_ITEM_ERROR=
remote_item_state() {  # <home> <item>
  local out status state
  out=$(env -u FM_ROOT_OVERRIDE FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-on.sh" "$1" fm-tasks-axi.sh show "$2" 2>&1 </dev/null)
  status=$?
  if [ "$status" -ne 0 ]; then
    if printf '%s\n' "$out" | grep -q '^code: NOT_FOUND$'; then return 1; fi
    REMOTE_ITEM_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
    return 2
  fi
  state=$(printf '%s\n' "$out" | sed -n 's/^  state: *//p' | sed -n '1p')
  [ -n "$state" ] || { REMOTE_ITEM_ERROR="the answer from $1 is not a task record"; return 2; }
  REMOTE_ITEM_STATE=$state
}

# The checks both closing proofs share: the item must not belong to the owner.
# Runs with the item's row already probed (FM_BACKLOG_ROW_*).
guard_owner_items() {  # <id> <title> <body>
  local id=$1 hold_status
  local hold_env=(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA")
  [ -z "${FM_STATE_OVERRIDE:-}" ] || hold_env+=(FM_STATE_OVERRIDE="$FM_STATE_OVERRIDE")
  [ -z "${FM_CONFIG_OVERRIDE:-}" ] || hold_env+=(FM_CONFIG_OVERRIDE="$FM_CONFIG_OVERRIDE")
  [ "${FM_BACKLOG_ROW_STATE%% *}" != "done" ] \
    || backlog_refuse backlog-close-item-eligible item-closed "an open item to close" machine "bin/fm-tasks-axi.sh show $id" "$id" "$id is already closed"
  [ ! -e "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta" ] \
    || backlog_refuse backlog-close-item-eligible live-task "an item with no live task record" machine "bin/fm-teardown.sh $id" "$id" "$id has a live task record; complete it with bin/fm-teardown.sh $id, which owns the landing proof"
  env -u FM_ROOT_OVERRIDE "${hold_env[@]}" "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1
  hold_status=$?
  case "$hold_status" in
    0) backlog_refuse backlog-close-item-eligible open-owner-call "the owner's answer to this call" human-only "what is the owner's answer to the call $id?" "$id" "$id is an open owner call; answer it with bin/fm-captain-hold.sh answer $id --decision-file <the owner's words>, or reconcile it with bin/fm-captain-hold.sh reconcile close $id" ;;
    1) ;;
    *) backlog_source_stop backlog-close-item-eligible "cannot tell whether $id is an open owner call, so it counts as undecided; run bin/fm-captain-hold.sh open $id and fix what it reports" ;;
  esac
  if printf '%s\n%s\n' "$2" "$3" | intake_python owner-filed; then
    backlog_refuse backlog-close-item-eligible owner-filed "the owner's words" human-only "does the owner close $id, and in what words?" "$id" "$id quotes the owner or captain, so it is the owner's own item; only the owner's words close it: get them, then record them with --drop-file <words-file>"
  fi
}

# A proof close leaves the work open elsewhere, so it must not release the open
# items <id> still blocks. <advice> says how to re-point them for this proof.
guard_open_dependents() {  # <id> <advice>
  local list dependents status
  list=$(fm_backlog_row_list "$DATA" --fields blocked_by) \
    || backlog_source_stop backlog-close-item-eligible "cannot read the backlog to find what $1 blocks, so nothing was closed: $(printf '%s\n' "$list" | sed -n '1p')"
  dependents=$(printf '%s\n' "$list" | intake_python dependents "$1")
  status=$?
  case "$status" in
    0) backlog_refuse backlog-close-item-eligible open-dependents "no open item blocked by this one" machine "bin/fm-tasks-axi.sh unblock <dependent> --by $1" "$1" "$1 still blocks open items: $(printf '%s' "$dependents" | tr '\n' ' '). Closing it would release them while its work is still open, so nothing was closed. $2" ;;
    1) ;;
    *) backlog_source_stop backlog-close-item-eligible "cannot tell what $1 blocks, so nothing was closed; fix what is named above, then close it again" ;;
  esac
}

# --duplicate-of <kept> and --moved-to <home> <item>: close on checked proof,
# without the owner's words. Runs with the item's row already probed (found).
# Nothing is written until every check has passed.
guard_closing_proof() {
  local id=$TASK_ID kept=$TASK_DUP_OF home_id=$TASK_MOVED_HOME item=$TASK_MOVED_ITEM shown title body home_data probe_status dest_state
  [ -z "$TASK_PR$TASK_REPORT$TASK_DROP" ] && [ "$TASK_NOTE" = 0 ] \
    || fail "a duplicate or moved item closes on its own proof; do not combine --duplicate-of or --moved-to with --pr, --report, --drop-file, or --note"
  { [ -z "$kept" ] || [ -z "$home_id$item" ]; } \
    || fail "give --duplicate-of or --moved-to, not both"
  shown=$(fm_backlog_row_show "$DATA" "$id" --full) \
    || backlog_source_stop backlog-close-item-eligible "cannot read $id: $(printf '%s\n' "$shown" | sed -n '1p')"
  title=$(printf '%s\n' "$shown" | intake_python field title) || title=
  body=$(printf '%s\n' "$shown" | intake_python field body) || body=
  guard_owner_items "$id" "$title" "$body"
  if [ -n "$kept" ]; then
    [[ "$kept" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsupported kept item id '$kept'"
    [ "$kept" != "$id" ] \
      || backlog_refuse backlog-close-duplicate-of kept-is-self "a kept item other than this one" machine "bin/fm-tasks-axi.sh done $id --duplicate-of <kept-id>" "$id" "an item cannot be a duplicate of itself"
    fm_backlog_row_probe "$DATA" "$kept" || {
      [ "$FM_BACKLOG_ROW_RESULT" = not_found ] \
        && backlog_refuse backlog-close-duplicate-of kept-missing "a kept item in this backlog" machine "bin/fm-tasks-axi.sh done $id --duplicate-of <kept-id>" "$id" "the kept item $kept does not exist in this backlog"
      backlog_source_stop backlog-close-duplicate-of "cannot read the kept item $kept: ${FM_BACKLOG_ROW_ERROR:-unreadable backlog}"
    }
    case "${FM_BACKLOG_ROW_STATE%% *}" in
      queued|in_flight) ;;
      *) backlog_refuse backlog-close-duplicate-of kept-not-open "a Queued or In flight kept item" machine "bin/fm-tasks-axi.sh done $id --duplicate-of <kept-id>" "$id" "the kept item $kept is not Queued or In flight; a duplicate closes into open work only" ;;
    esac
    guard_open_dependents "$id" "Re-point every one first, held or not: bin/fm-tasks-axi.sh block <dependent> --by $kept, then bin/fm-tasks-axi.sh unblock <dependent> --by $id (the kept item $kept itself needs only the unblock step)."
    backlog_guard_allow backlog-close-item-eligible
    append_to_kept "$kept" "duplicate $id" "$title" "$body"
    backlog_guard_allow backlog-close-duplicate-of
    GUARD_ARGS=(--note "duplicate of $kept")
    LEDGER_CLOSE_ARGS=(--duplicate-of "$kept")
  else
    [[ "$home_id" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$item" =~ ^[A-Za-z0-9._-]+$ ]] \
      || fail "--moved-to takes a registered home id and an item id: --moved-to <home> <item-id>"
    # The registry is the one in this operation's own data directory, and the home
    # id must name exactly one record there.
    secondmate_registry_line_for_id "$DATA/secondmates.md" "$home_id" \
      || backlog_refuse backlog-close-moved-to home-not-registered "one registered home" machine "bin/fm-tasks-axi.sh done $id --moved-to <home> <item-id>" "$id" "$home_id is not one registered home in $DATA/secondmates.md"
    if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
      remote_item_state "$home_id" "$item"
      case $? in
        0) dest_state=$REMOTE_ITEM_STATE ;;
        1) backlog_refuse backlog-close-moved-to item-missing "the item in the new home" machine "bin/fm-tasks-axi.sh done $id --moved-to $home_id <item-id>" "$id" "$home_id's backlog has no item $item" ;;
        *) backlog_source_stop backlog-close-moved-to "cannot read $home_id's backlog, so nothing was closed: ${REMOTE_ITEM_ERROR:-unreachable remote}" ;;
      esac
    else
      case "$SECONDMATE_REGISTRY_HOME" in /*) ;; *) backlog_source_stop backlog-close-moved-to "the registered home path for $home_id is not absolute" ;; esac
      home_data="$SECONDMATE_REGISTRY_HOME/data"
      if [ "$home_data" -ef "$DATA" ] || { [ -e "$home_data/backlog.md" ] && [ "$home_data/backlog.md" -ef "$DATA/backlog.md" ]; }; then
        backlog_refuse backlog-close-moved-to same-backlog "a different backlog" machine "bin/fm-tasks-axi.sh done $id --moved-to <home> <item-id>" "$id" "$home_id is this backlog itself; a moved item must live in a different backlog"
      fi
      fm_backlog_row_probe "$home_data" "$item"
      probe_status=$?
      # The probe re-addressed the backlog to that home; point it back at this one.
      fm_backlog_tasks_axi_addressing "$DATA" || fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
      if [ "$probe_status" -ne 0 ]; then
        [ "$FM_BACKLOG_ROW_RESULT" = not_found ] \
          && backlog_refuse backlog-close-moved-to item-missing "the item in the new home" machine "bin/fm-tasks-axi.sh done $id --moved-to $home_id <item-id>" "$id" "$home_id's backlog has no item $item"
        backlog_source_stop backlog-close-moved-to "cannot read $home_id's backlog, so nothing was closed: ${FM_BACKLOG_ROW_ERROR:-unreadable backlog}"
      fi
      dest_state=${FM_BACKLOG_ROW_STATE%% *}
    fi
    case "${dest_state%% *}" in
      queued|in_flight) ;;
      *) backlog_refuse backlog-close-moved-to item-not-open "an open item in the new home" machine "bin/fm-tasks-axi.sh done $id --moved-to $home_id <item-id>" "$id" "$home_id's item $item is not open (Queued or In flight); moved work must be open in the new home" ;;
    esac
    guard_open_dependents "$id" "Re-point each one first: for a dependent with no hold, bin/fm-tasks-axi.sh hold <dependent> --reason \"waits for $item in $home_id\" (a blocker cannot name an item in another backlog); then, for every dependent, bin/fm-tasks-axi.sh unblock <dependent> --by $id. A dependent already on a hold keeps that hold and needs only the unblock step, because a new hold replaces the old one and can erase an owner call."
    backlog_guard_allow backlog-close-item-eligible
    backlog_guard_allow backlog-close-moved-to
    GUARD_ARGS=(--note "moved to $home_id as $item")
    LEDGER_CLOSE_ARGS=(--moved-to "$home_id" "$item")
  fi
  GUARD_STRIP_PROOF=1
}

# Intake: parse an add, drop the flags tasks-axi does not know, and judge the
# objective and the duplicate neighbours before anything is written.
ADD_TITLE=
ADD_BODY=
ADD_OBJECTIVE=
ADD_REASON=
ADD_DUP_OF=
ADD_ID=
ADD_NOT_DUP=
ADD_HELP=0
ADD_NEIGHBOURS=
set_intake_flag() {  # <flag> <value>
  case "$2" in
    ''|-*) fail "$1 requires a value; run tasks-axi directly for other grammar" ;;
  esac
  case "$1" in
    --objective) ADD_OBJECTIVE=$2 ;;
    --objective-reason) ADD_REASON=$2 ;;
    --dup-of) ADD_DUP_OF=$2 ;;
    --not-dup)
      [ -z "$ADD_NOT_DUP" ] || fail "--not-dup takes one neighbour id; give it once"
      ADD_NOT_DUP=$2
      ;;
  esac
}
parse_add_intake() {  # <args...>; rewrites ARGS without the intake flags
  local tokens=("$@") i=0 j token expect='' mint=0 body_file='' flag_title=''
  local positionals=() kept=()
  [ "${tokens[0]:-}" != task ] || i=1
  i=$((i + 1))
  for ((j = 0; j < i; j++)); do kept+=("${tokens[j]}"); done
  for token in "${tokens[@]:$i}"; do
    if [ -n "$expect" ]; then
      case "$expect" in
        --objective|--objective-reason|--dup-of|--not-dup) set_intake_flag "$expect" "$token" ;;
        *)
          kept+=("$token")
          case "$expect" in --body) ADD_BODY=$token ;; --body-file) body_file=$token ;; --title) flag_title=$token ;; esac
          ;;
      esac
      expect=''
      continue
    fi
    case "$token" in
      --help|-h) ADD_HELP=1; kept+=("$token") ;;
      --objective|--objective-reason|--dup-of|--not-dup) expect=$token ;;
      --objective=*|--objective-reason=*|--dup-of=*|--not-dup=*) set_intake_flag "${token%%=*}" "${token#*=}" ;;
      --kind|--repo|--body|--body-file|--title|--blocked-by|--pr|--report|--priority|--prefix)
        kept+=("$token"); expect=$token ;;
      --body=*) ADD_BODY=${token#*=}; kept+=("$token") ;;
      --body-file=*) body_file=${token#*=}; kept+=("$token") ;;
      --title=*) flag_title=${token#*=}; kept+=("$token") ;;
      --mint) mint=1; kept+=("$token") ;;
      -*) kept+=("$token") ;;
      *) positionals+=("$token"); kept+=("$token") ;;
    esac
  done
  [ -z "$expect" ] || fail "$expect requires a value; run tasks-axi directly for other grammar"
  if [ "$mint" = 1 ]; then
    ADD_TITLE=${positionals[0]:-}
  else
    ADD_ID=${positionals[0]:-}
    ADD_TITLE=${positionals[1]:-}
  fi
  [ -z "$flag_title" ] || ADD_TITLE=$flag_title
  if [ -z "$ADD_BODY" ] && [ -n "$body_file" ]; then
    ADD_BODY=$(cat -- "$body_file" 2>/dev/null) || fail "cannot read --body-file $body_file"
  fi
  ARGS=("${kept[@]}")
}

intake_archive() {  # prints the markdown done archive path; empty for another backend
  local archive
  [ -n "$FM_BACKLOG_AXI_FILE" ] || return 0
  archive=$(sed -n "s/^[[:space:]]*archive[[:space:]]*=[[:space:]]*[\"']\\([^\"']*\\)[\"'].*/\\1/p" \
    "$FM_BACKLOG_AXI_ROOT/.tasks.toml" 2>/dev/null | sed -n '1p')
  case "$archive" in
    '') archive="$DATA/done-archive.md" ;;
    /*) ;;
    *) archive="$FM_BACKLOG_AXI_ROOT/$archive" ;;
  esac
  printf '%s' "$archive"
}

# The objective sidecar must be writable before anything is filed, so a filed
# item is never left without its row.
intake_sidecar_ready() {
  local sidecar="$DATA/backlog-review.tsv"
  if [ -e "$sidecar" ] || [ -L "$sidecar" ]; then
    [ -f "$sidecar" ] && [ ! -L "$sidecar" ] && [ -w "$sidecar" ] \
      || fail "cannot record the objective: $sidecar is not a writable regular file; fix it, then file the item again (nothing was filed)"
  else
    [ -d "$DATA" ] && [ -w "$DATA" ] \
      || fail "cannot record the objective: $DATA is not a writable directory (nothing was filed)"
  fi
}

state_label() {  # <state> <source>
  local label
  case "$1" in queued) label=Queued ;; in_flight) label="In flight" ;; done) label=Done ;; *) label=$1 ;; esac
  [ "$2" != archive ] || label="$label, archived"
  printf '%s' "$label"
}

guard_intake() {
  local list valid id state score source ntitle neighbour_ids='' keep_line='' status top='' shown_count=0 known=0
  local subject=${ADD_ID:-new-item} add_step='bin/fm-tasks-axi.sh add <id> <title>'
  [ "$ADD_HELP" = 0 ] || return 0
  valid=$(intake_python objectives "$OBJECTIVES_FILE") \
    || backlog_source_stop backlog-intake-objective "cannot read the objective list $OBJECTIVES_FILE"
  valid=$(printf '%s' "$valid" | tr '\n' ' ')
  if [ -z "$ADD_OBJECTIVE" ]; then
    backlog_refuse backlog-intake-objective objective-missing "an objective" machine "$add_step --objective <objective-id>" "$subject" "add needs the objective the item serves: --objective <id> with one of $valid (docs/objectives.md), or --objective none --objective-reason \"<why no objective applies>\""
  fi
  if [ "$ADD_OBJECTIVE" = none ]; then
    [[ "$ADD_REASON" =~ [^[:space:]] ]] \
      || backlog_refuse backlog-intake-objective reason-missing "a reason for no objective" machine "$add_step --objective none --objective-reason <why>" "$subject" "--objective none needs --objective-reason \"<why no objective applies>\""
  else
    for id in $valid; do
      [ "$id" != "$ADD_OBJECTIVE" ] || known=1
    done
    [ "$known" = 1 ] \
      || backlog_refuse backlog-intake-objective objective-unknown "an objective docs/objectives.md lists" machine "$add_step --objective <objective-id>" "$subject" "unknown objective '$ADD_OBJECTIVE'; use one of $valid (docs/objectives.md), or --objective none --objective-reason \"<why>\""
  fi
  backlog_guard_allow backlog-intake-objective
  if [ -n "$ADD_DUP_OF" ] && [ -n "$ADD_NOT_DUP" ]; then
    fail "give --dup-of or --not-dup, not both"
  fi
  if [ -n "$ADD_DUP_OF" ] && [ "$ADD_DUP_OF" = "$ADD_ID" ]; then
    backlog_refuse backlog-intake-dup-of kept-is-self "a kept item other than this add" machine "$add_step --objective <objective-id> --dup-of <kept-id>" "$subject" "--dup-of names this add's own id $ADD_ID; an item cannot be a duplicate of itself, so nothing was filed or appended"
  fi
  [ -n "$ADD_TITLE" ] || return 0
  list=$(fm_backlog_row_list "$DATA") \
    || backlog_source_stop backlog-intake-duplicate "cannot read the backlog to check for duplicates, so nothing was filed: $(printf '%s\n' "$list" | sed -n '1p')"
  ADD_NEIGHBOURS=$(printf '%s\n' "$list" | intake_python neighbours "$ADD_TITLE" "$(intake_archive)" "$ADD_ID")
  status=$?
  case "$status" in
    0|1) ;;
    *) backlog_source_stop backlog-intake-duplicate "the duplicate check could not read the backlog or its done archive, so nothing was filed; fix what is named above, then file the item again" ;;
  esac
  if [ -n "$ADD_DUP_OF" ]; then
    [[ "$ADD_DUP_OF" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsupported kept item id '$ADD_DUP_OF'"
    if ! printf '%s\n' "$list" | intake_python exists "$ADD_DUP_OF"; then
      if intake_python archived "$(intake_archive)" "$ADD_DUP_OF"; then
        backlog_refuse backlog-intake-dup-of kept-archived "a kept item in the active backlog" machine "$add_step --objective <objective-id> --not-dup $ADD_DUP_OF" "$subject" "the kept item $ADD_DUP_OF is Done and archived, and an archived item cannot take an appended note; nothing was filed or appended. If the new item is the same work, nothing needs filing; if it is different work, file it with --not-dup $ADD_DUP_OF"
      fi
      backlog_refuse backlog-intake-dup-of kept-missing "a kept item in this backlog" machine "$add_step --objective <objective-id> --dup-of <kept-id>" "$subject" "the kept item $ADD_DUP_OF does not exist in this backlog"
    fi
    append_to_kept "$ADD_DUP_OF" "a duplicate filing" "$ADD_TITLE" "$ADD_BODY"
    backlog_guard_allow backlog-intake-dup-of
    backlog_guard_allow backlog-intake-duplicate --cleared-by dup-of
    printf 'ok: merged into %s (nothing filed)\n' "$ADD_DUP_OF"
    exit 0
  fi
  while IFS=$'\t' read -r id _; do
    [ -z "$id" ] || neighbour_ids="$neighbour_ids $id "
  done <<NEIGHBOURS
$ADD_NEIGHBOURS
NEIGHBOURS
  if [ -n "$ADD_NOT_DUP" ]; then
    case "$neighbour_ids" in
      *" $ADD_NOT_DUP "*) ;;
      *)
        if printf '%s\n' "$list" | intake_python exists "$ADD_NOT_DUP" || intake_python archived "$(intake_archive)" "$ADD_NOT_DUP"; then
          backlog_refuse backlog-intake-not-dup not-a-neighbour "a neighbour of this title" machine "$add_step --objective <objective-id> --not-dup <neighbour-id>" "$subject" "--not-dup $ADD_NOT_DUP names an item whose title does not overlap this one enough to be a neighbour; nothing was filed"
        fi
        backlog_refuse backlog-intake-not-dup item-missing "an item in this backlog" machine "$add_step --objective <objective-id> --not-dup <neighbour-id>" "$subject" "--not-dup $ADD_NOT_DUP names no item in this backlog; nothing was filed"
        ;;
    esac
    intake_sidecar_ready
    backlog_guard_allow backlog-intake-not-dup
    backlog_guard_allow backlog-intake-duplicate --override --cleared-by not-dup
    return 0
  fi
  if [ -z "$ADD_NEIGHBOURS" ]; then
    intake_sidecar_ready
    backlog_guard_allow backlog-intake-duplicate
    return 0
  fi
  backlog_refuse backlog-intake-duplicate title-overlap "a judgment of the listed neighbours" human-only "is this add the same work as ${ADD_NEIGHBOURS%%$'\t'*}?" "$subject"
  {
    printf 'fm-tasks-axi: this title overlaps open or recently closed items, so nothing was filed:\n'
    while IFS=$'\t' read -r id state score source ntitle; do
      [ -n "$id" ] || continue
      shown_count=$((shown_count + 1))
      [ "$shown_count" -le 3 ] || break
      printf '  %s (%s, overlap %s) %s\n' "$id" "$(state_label "$state" "$source")" "$score" "$ntitle"
    done <<NEIGHBOURS
$ADD_NEIGHBOURS
NEIGHBOURS
    while IFS=$'\t' read -r id state _ source _; do
      if [ -z "$top" ] && [ "$source" = active ]; then top=$id; fi
      [ -n "$keep_line" ] || keep_line=$id
    done <<NEIGHBOURS
$ADD_NEIGHBOURS
NEIGHBOURS
    printf 'Judge them, then run the add again with one of these two overrides (each still needs --objective):\n'
    if [ -n "$top" ]; then
      printf '  the work is the same - append this title and body to %s and file nothing:\n    %q' "$top" "$0"
      printf ' %q' "${ORIG_ARGS[@]}" --dup-of "$top"
      printf '\n'
    else
      printf '  (every neighbour is Done and archived, so --dup-of has no item to append to)\n'
    fi
    printf '  the work is different from %s - file it:\n    %q' "$keep_line" "$0"
    printf ' %q' "${ORIG_ARGS[@]}" --not-dup "$keep_line"
    printf '\n'
  } >&2
  exit 2
}

# One line per filed item in data/backlog-review.tsv: id, review-by (empty),
# objective, and reason. A row
# that cannot be written removes the item again, so an item never stays filed
# without its row.
intake_record() {  # <captured-add-stdout-file>
  local reason row
  added_fields "$1" || return 0
  reason=$(printf '%s' "$ADD_REASON" | tr '\t\n' '  ')
  row=$(printf '%s\t\t%s\t%s' "$ADDED_ID" "$ADD_OBJECTIVE" "$reason")
  printf '%s\n' "$row" >> "$DATA/backlog-review.tsv" && return 0
  if fm_backlog_mutate "$DATA" rm "$ADDED_ID"; then
    printf 'fm-tasks-axi: could not record the objective of %s in %s/backlog-review.tsv, so the item was removed again; nothing is filed\n' "$ADDED_ID" "$DATA" >&2
  else
    printf 'fm-tasks-axi: could not record the objective of %s in %s/backlog-review.tsv, and the item could not be removed (%s); remove it with tasks-axi rm %s\n' \
      "$ADDED_ID" "$DATA" "${FM_BACKLOG_TRANSITION_ERROR:-tasks-axi said no}" "$ADDED_ID" >&2
  fi
  return 1
}

guard_completion() {
  local id=$TASK_ID pr=$TASK_PR report=$TASK_REPORT drop note=$TASK_NOTE proof=()
  drop=$(absolute_from_caller "$TASK_DROP")
  case "$TASK_COMMAND" in done|close) ;; *) return 0 ;; esac
  [ "$TASK_CONTROL_LOCK_HELD" = 1 ] || return 0
  fm_backlog_row_probe "$DATA" "$id" || {
    if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      [ -z "$TASK_DUP_OF$TASK_MOVED_HOME$TASK_MOVED_ITEM" ] \
        || backlog_refuse backlog-close-item-eligible item-missing "an item in this backlog" machine "bin/fm-tasks-axi.sh list" "$id" "no item $id in this backlog to close"
      return 0
    fi
    fail "cannot identify the task being completed: ${FM_BACKLOG_ROW_ERROR:-unreadable backlog}"
  }
  # Opt-in for bin/fm-pr-close-items.sh only: refuse an open owner call for every row kind,
  # under the lock this command already holds, so a hold placed before the close wins.
  if [ "${FM_TASKS_AXI_REFUSE_OPEN_CALL:-}" = 1 ] && [ "${FM_BACKLOG_ROW_STATE%% *}" != "done" ] \
    && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
    fail "$id is an open owner call (a captain hold); resolve it with bin/fm-captain-hold.sh before completing it"
  fi
  if [ -n "$TASK_DUP_OF$TASK_MOVED_HOME$TASK_MOVED_ITEM" ]; then
    guard_closing_proof
    return
  fi
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
    GUARD_STRIP_PROOF=1
    proof=("${GUARD_ARGS[@]}")
  elif [ -n "$report" ]; then
    [ "$FM_BACKLOG_ROW_KIND" = scout ] \
      || fail "a report is not a ship's deliverable; land its pull request or record the captain's drop"
    case "$report" in /*) ;; *) report="$FM_BACKLOG_AXI_ROOT/$report" ;; esac
    [ -f "$report" ] && [ ! -L "$report" ] && [ -s "$report" ] \
      || fail "the report has not been written: $report"
    proof=(--report "$report")
  elif [ -n "$pr" ]; then
    [ "$FM_BACKLOG_ROW_KIND" = ship ] || fail "a scout's deliverable is its written report"
    [[ "$pr" =~ ^https://github[.]com/([^/]+/[^/]+)/pull/([0-9]+)$ ]] \
      || fail "only a GitHub pull request can be proved merged here; complete other deliveries with bin/fm-teardown.sh or record the captain's drop"
    gh-axi api "/repos/${BASH_REMATCH[1]}/pulls/${BASH_REMATCH[2]}" --jq '"merged=" + ((.merged_at != null)|tostring)' --full 2>/dev/null \
      | grep -Eq '^  body: "?merged=true"?$' || fail "the pull request has not merged: $pr"
    proof=(--pr "$pr")
  else
    fail "completion needs proof of the deliverable: --report (scout), a merged --pr (ship), or --drop-file with the captain's words"
  fi
  [ "${FM_BACKLOG_ROW_STATE%% *}" = "done" ] || LEDGER_CLOSE_ARGS=("${proof[@]}")
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
GUARD_STRIP_PROOF=0
LEDGER_CLOSE_ARGS=()
parse_task_mutation "$@"
if [ "$TASK_HELP" = 0 ] && [[ "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  trap task_mutation_cleanup EXIT
  case "$STATE" in /*) task_state=$STATE ;; *) task_state="$CALLER_DIR/$STATE" ;; esac
  TASK_CONTROL_LOCK="$task_state/.control-$TASK_ID.lock"
  TASK_META_LOCK=$(fm_meta_lock_path "$task_state/$TASK_ID.meta") || fail "cannot resolve the task record lock for $TASK_ID"
  fm_lock_acquire_wait "$TASK_CONTROL_LOCK" || exit 1
  TASK_CONTROL_LOCK_HELD=1
  fm_lock_acquire_wait "$TASK_META_LOCK" || exit 1
  TASK_META_LOCK_HELD=1
fi
guard_completion
case "$TASK_COMMAND" in
  add|create)
    # shellcheck source=bin/fm-wake-lib.sh
    command -v fm_lock_try_acquire >/dev/null 2>&1 || . "$SCRIPT_DIR/fm-wake-lib.sh"
    parse_add_intake "${ARGS[@]}"
    guard_intake
    ;;
esac
if [ "$GUARD_STRIP_PROOF" = 1 ]; then
  # The drop words stay in the retained file, and a duplicate or moved item's
  # proof is checked above; tasks-axi receives only the fixed note.
  kept=()
  skip=0
  for arg in "${ARGS[@]}"; do
    if [ "$skip" -gt 0 ]; then skip=$((skip - 1)); continue; fi
    case "$arg" in
      --drop-file|--duplicate-of) skip=1; continue ;;
      --moved-to) skip=2; continue ;;
      --drop-file=*|--duplicate-of=*) continue ;;
    esac
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
# Read the item an `add` just created from the add's own captured stdout, so a
# minted id and every defaulted field are the ones tasks-axi stored. Sets
# ADDED_ID/REPO/KIND/PRIORITY and returns 0 only for a newly created item: an add
# that found its id already present (`already`) or failed returns 1.
added_fields() {  # <captured-stdout-file>
  local out fields key value json_status
  ADDED_ID=
  ADDED_REPO=
  ADDED_KIND=
  ADDED_PRIORITY=
  out=$(cat -- "$1") || return 1
  # JSON output is read with python3, which the intake checks already require,
  # so a home without jq still records the objective of a --json add.
  # Exit 3 means the output is not JSON and the text reader below takes over.
  json_status=0
  fields=$(printf '%s' "$out" | python3 -I -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not (isinstance(doc, dict) and doc.get("ok") is True and doc.get("action") == "add" and not doc.get("already")):
    sys.exit(0)
task = doc.get("task") or {}
for key in ("id", "repo", "kind", "priority"):
    value = task.get(key)
    print("%s\t%s" % (key, "" if value is None else value))
' 2>/dev/null) || json_status=$?
  case "$json_status" in
    0) ;;
    3)
      fields=$(printf '%s\n' "$out" | awk '
        /^ok: added / { added = 1; next }
        added && /^  (id|kind|repo|priority): / {
          key = $1; sub(/:$/, "", key); value = $0; sub(/^  [a-z]+: /, "", value)
          gsub(/^"|"$/, "", value); if (value == "-") value = ""
          printf "%s\t%s\n", key, value
        }') || return 1
      ;;
    *) return 1 ;;
  esac
  while IFS=$'\t' read -r key value; do
    case "$key" in id) ADDED_ID=$value ;; repo) ADDED_REPO=$value ;; kind) ADDED_KIND=$value ;; priority) ADDED_PRIORITY=$value ;; esac
  done <<< "$fields"
  [ -n "$ADDED_ID" ]
}

# Append task.filed for the item an `add` just created.
ledger_task_filed() {  # <captured-stdout-file>
  local ledger_state ledger_config
  added_fields "$1" || return 0
  ledger_state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  ledger_config=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$ledger_state FM_CONFIG_OVERRIDE=$ledger_config \
    "$SCRIPT_DIR/fm-fleet-ledger.sh" filed "$ADDED_ID" "$ADDED_REPO" "$ADDED_KIND" "$ADDED_PRIORITY" || true
}

case "$TASK_COMMAND" in
  add|create)
    if [ "$ADD_HELP" = 0 ]; then
      # Capture the add's stdout: the objective record and the fleet ledger both
      # need the id tasks-axi stored, and a failed capture must not file unrecorded.
      add_out=$(mktemp "${TMPDIR:-/tmp}/fm-tasks-axi-add.XXXXXX" 2>/dev/null) \
        || fail "cannot create a scratch file to record the add's objective"
      tasks-axi ${ARGS[@]+"${ARGS[@]}"} > "$add_out"
      add_status=$?
      if [ "$add_status" -eq 0 ] && ! intake_record "$add_out"; then
        rm -f -- "$add_out"
        exit 1
      fi
      cat -- "$add_out"
      if [ "$add_status" -eq 0 ]; then
        [ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || ledger_task_filed "$add_out" || true
      fi
      rm -f -- "$add_out"
      exit "$add_status"
    fi
    ;;
esac
if [ "$TASK_CONTROL_LOCK_HELD" = 1 ]; then
  tasks-axi ${ARGS[@]+"${ARGS[@]}"}
  task_status=$?
  [ "$task_status" -ne 0 ] || [ "${#LEDGER_CLOSE_ARGS[@]}" -eq 0 ] \
    || fm_backlog_ledger_closed "$task_state" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$TASK_ID" "${LEDGER_CLOSE_ARGS[@]}"
  # A completed item stops blocking its dependents (fm_backlog_unblock_dependents).
  if [ "$task_status" -eq 0 ] && [ "$TASK_HELP" = 0 ]; then
    case "$TASK_COMMAND" in
      done|close) fm_backlog_unblock_dependents "$DATA" "$TASK_ID" >&2 ;;
    esac
  fi
  exit "$task_status"
fi
case "${ARGS[0]:-}:${ARGS[1]:-}" in
  public-followup:record-delivery|public-followup:waive)
    # These typed completions can move a row to Done, and a done_keep of 0 archives it at
    # once. Run them without exec so a row they finished stops blocking its dependents,
    # exactly like done/close.
    pf_id=${ARGS[2]:-}
    tasks-axi "${ARGS[@]}"
    pf_status=$?
    pf_help=0
    for pf_arg in "${ARGS[@]}"; do
      case "$pf_arg" in -h|--help) pf_help=1 ;; esac
    done
    if [ "$pf_status" -eq 0 ] && [ "$pf_help" = 0 ] && [[ "$pf_id" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]]; then
      if fm_backlog_row_probe "$DATA" "$pf_id"; then
        [ "${FM_BACKLOG_ROW_STATE%% *}" != "done" ] || fm_backlog_unblock_dependents "$DATA" "$pf_id" >&2
      elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
        fm_backlog_unblock_dependents "$DATA" "$pf_id" >&2
      else
        printf 'actionable: tasks-axi accepted the %s of %s, but its state could not be read (%s); if it is done, clear the items it blocked with tasks-axi unblock <item> --by %s\n' \
          "${ARGS[1]}" "$pf_id" "${FM_BACKLOG_ROW_ERROR:-unknown error}" "$pf_id" >&2
      fi
    fi
    exit "$pf_status"
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
