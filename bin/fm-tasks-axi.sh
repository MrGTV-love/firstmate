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
# exactly one ID, and --pr, --report, --note, --drop-file, --duplicate-of, --keep,
# --no-prune, --json, or --help. Valued options accept split or = forms; --keep requires a
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
#   - `done`/`close` --duplicate-of <id> (split or = form, once, a plain id) is the one
#     close that needs neither proof nor the captain's words, because no work can be lost:
#     it records the fixed note "duplicate of <id>" on a ship or scout row, and only
#     when, inside the same locks, the row is exactly `queued no no` (no hold, no blocked-by
#     edge), no other row waits on it, and none of this exists: its task record, a
#     state/<id>.status, .inbox, .launch-models, .backlog-close, .control-exit or
#     .control-relaunch file or another state/.control-<id>* file, any ref in its
#     project repository whose last name part is <id> or ends in <id> after a /, -, _
#     or . (so a branch under any branch prefix), a `git worktree list` copy whose path
#     holds an <id> component, data/<id>/skipped-copies.tsv, or any entry in data/<id>/
#     besides plain brief.md and dod.md. The project repository is the one the row's
#     repo field names, resolved as bin/fm-dispatch-project.py resolves it: $FM_HOME
#     itself for repo firstmate, else $FM_PROJECTS_OVERRIDE or $FM_HOME/projects. A copy
#     is seen only when `git worktree list` shows a path with an <id> part or when the
#     task branch is checked out in it (the branch check refuses that branch). The
#     survivor must be another row that exists with no body line starting "duplicate of ";
#     a Done survivor must have finished by a merged PR or a report (a pr: or report:
#     link), so one closed by the captain's drop ("dropped") or by a "preserved in bundle
#     ..., not landed" note refuses. An unreadable repository, a
#     missing repo field, or an unreadable row, backlog, or directory refuses. Combining
#     it with --drop-file, --pr, --report, or --note refuses, as does any row that is
#     not a queued ship or scout. Not covered (owner: Main): a leased treehouse slot
#     whose path holds no <id> part and which is on another branch or detached (git lists
#     it, yet it passes the copy check; only the branch check, the task-record check, and
#     the data/<id>/ allowlist protect it), a branch that exists only on the remote, a
#     direct tasks-axi call that skips this wrapper, and a survivor closed by another
#     call between the check and the close (the survivor row is not locked).
# FM_TASKS_AXI_REFUSE_OPEN_CALL=1 (set only by bin/fm-pr-close-items.sh) makes that guard
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

parse_duplicate_of() {  # <survivor-id>; one use per completion, a plain id
  TASK_DUP_COUNT=$((TASK_DUP_COUNT + 1))
  [ "$TASK_DUP_COUNT" -eq 1 ] || fail "--duplicate-of may be given only once; run tasks-axi directly for other grammar"
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--duplicate-of requires one plain task id, not '$1'; run tasks-axi directly for other grammar"
  TASK_DUP=$1
}

parse_task_mutation() {
  local tokens=("$@") i=0 expect='' token bounded=0
  TASK_COMMAND=
  TASK_ID=
  TASK_HELP=0
  TASK_PR=
  TASK_REPORT=
  TASK_DROP=
  TASK_NOTE=0
  TASK_DUP=
  TASK_DUP_COUNT=0
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
        --duplicate-of) parse_duplicate_of "$token" ;;
      esac
      expect=''
      continue
    fi
    if [ "$bounded" = 1 ]; then
      case "$TASK_COMMAND:$token" in
        *:--help) TASK_HELP=1; continue ;;
        *:--json) continue ;;
        done:--no-prune|close:--no-prune) continue ;;
        done:--pr|close:--pr|done:--report|close:--report|done:--drop-file|close:--drop-file|done:--note|close:--note|done:--keep|close:--keep|done:--duplicate-of|close:--duplicate-of)
          expect=$token; continue ;;
        done:--pr=*|close:--pr=*|done:--report=*|close:--report=*|done:--drop-file=*|close:--drop-file=*|done:--note=*|close:--note=*|done:--keep=*|close:--keep=*|done:--duplicate-of=*|close:--duplicate-of=*)
          expect=${token%%=*}
          token=${token#*=}
          case "$token" in
            ''|-*) fail "$expect requires a value, not an option; run tasks-axi directly for other grammar" ;;
          esac
          case "$expect" in
            --pr) TASK_PR=$token ;; --report) TASK_REPORT=$token ;;
            --drop-file) TASK_DROP=$token ;; --note) TASK_NOTE=1 ;;
            --duplicate-of) parse_duplicate_of "$token" ;;
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

# --duplicate-of: close a never-dispatched row as a duplicate of a surviving item, with no
# captain words, only when no work can exist for the row. Each check below is one function
# that refuses with `fail` (exit 2, nothing written), runs inside the locks guard_completion
# holds, and reads only the filesystem, git, and the backlog. Anything unreadable refuses.
dup_present() { [ -e "$1" ] || [ -L "$1" ]; }

dup_git() {  # <project-dir> <git args...>; the caller's GIT_* variables never pick another repository
  local dir=$1
  shift
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_CEILING_DIRECTORIES \
    GIT_OPTIONAL_LOCKS=0 git -C "$dir" "$@"
}

dup_refuse_row_state() {  # <id>: only a queued row with no hold and no blocked-by edge
  [ "$FM_BACKLOG_ROW_STATE" = "queued no no" ] && [ -z "$FM_BACKLOG_ROW_HOLD_KIND" ] \
    || fail "$1 is not a plain queued row (state '$FM_BACKLOG_ROW_STATE', hold kind '${FM_BACKLOG_ROW_HOLD_KIND:--}'); only a queued row with no hold and no blocked-by edge closes as a duplicate"
}

dup_refuse_task_record() {  # <id>
  ! dup_present "$task_state/$1.meta" \
    || fail "$1 has a task record ($task_state/$1.meta), so work may exist; complete it with bin/fm-teardown.sh $1, which owns the landing proof"
}

dup_refuse_dispatch_files() {  # <id>: status, inbox, launch models, an end-of-run marker, or another control file
  local id=$1 path own_owner
  # The lock this command holds is a link to its owner directory beside it; neither is a dispatch file.
  own_owner=$(readlink "$TASK_CONTROL_LOCK" 2>/dev/null) || own_owner=
  for path in "$task_state/$id.status" "$task_state/$id.inbox" "$task_state/$id.launch-models" \
    "$task_state/$id.backlog-close" "$task_state/$id.control-exit" "$task_state/$id.control-relaunch" \
    "$task_state"/.control-"$id"*; do
    [ "${path##*/}" != "${TASK_CONTROL_LOCK##*/}" ] && [ "${path##*/}" != "${own_owner##*/}" ] || continue
    ! dup_present "$path" || fail "$id has a dispatch file ($path), so it was started"
  done
}

dup_project_dir() {  # <id> <repo-from-the-row>: sets DUP_PROJECT to the repository's own directory
  local id=$1 repo=$2 projects dir prefix
  case "$repo" in ''|-|.|..|*[!A-Za-z0-9._-]*) fail "$id has no usable repo field ('$repo'), so its project cannot be checked for work" ;; esac
  if [ "$repo" = firstmate ]; then
    dir=$FM_HOME
  else
    projects=${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}
    case "$projects" in /*) ;; *) projects="$CALLER_DIR/$projects" ;; esac
    dir="$projects/$repo"
  fi
  [ -d "$dir" ] || fail "the project $repo of $id is not at $dir, so its branches and copies cannot be checked"
  prefix=$(dup_git "$dir" rev-parse --show-prefix 2>/dev/null) && [ -z "$prefix" ] \
    || fail "$dir is not a git repository of its own, so the branches and copies of $id cannot be checked"
  DUP_PROJECT=$dir
}

dup_refuse_branch() {  # <id> <project-dir>: any ref whose last part is the id or ends in it after a separator
  local id=$1 refs ref
  refs=$(dup_git "$2" for-each-ref --format='%(refname)') \
    || fail "the refs of $2 cannot be read, so a branch of $id cannot be ruled out"
  while IFS= read -r ref; do
    case "${ref##*/}" in "$id"|*[-_.]"$id") fail "$id has a branch ($ref), so work may exist" ;; esac
  done <<< "$refs"
}

dup_refuse_copy() {  # <id> <project-dir>: a copy git lists under the id, or one the spawn recorded
  local id=$1 list line path first=1
  ! dup_present "$DATA/$id/skipped-copies.tsv" \
    || fail "$id has a recorded copy ($DATA/$id/skipped-copies.tsv), so work may exist"
  list=$(dup_git "$2" worktree list --porcelain) \
    || fail "the copies of $2 cannot be listed, so a copy of $id cannot be ruled out"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path=${line#worktree }
        if [ "$first" = 1 ]; then first=0; continue; fi
        case "/$path/" in *"/$id/"*) fail "$id has a copy ($path), so work may exist" ;; esac
        ;;
    esac
  done <<< "$list"
}

dup_refuse_work_dir() {  # <id>: data/<id>/ holds at most the brief and the definition of done
  local id=$1 dir="$DATA/$1" entries entry
  dup_present "$dir" || return 0
  { [ -d "$dir" ] && [ ! -L "$dir" ]; } || fail "$dir is not a plain directory, so what $id holds cannot be checked"
  entries=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null) || fail "$dir cannot be read, so what $id holds cannot be checked"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "${entry##*/}" in
      brief.md|dod.md) { [ -f "$entry" ] && [ ! -L "$entry" ]; } || fail "$entry is not a plain file, so what $id holds cannot be checked" ;;
      *) fail "$id holds $entry; only brief.md and dod.md are allowed in $dir" ;;
    esac
  done <<< "$entries"
}

dup_show_field() {  # <show-output> <key>: the decoded value of one field of `show --full`
  local raw
  raw=$(printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1)
  case "$raw" in
    '"'*) perl -MJSON::PP -e 'print JSON::PP->new->allow_nonref->decode($ARGV[0]), "\n"' -- "$raw" 2>/dev/null ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

dup_refuse_survivor() {  # <id> <survivor-id>: a row that exists, is no duplicate close, and when Done finished by a PR or report
  local id=$1 keep=$2 out rc=0 state body links line
  out=$(fm_backlog_row_show "$DATA" "$keep" --full) || rc=$?
  if [ "$rc" -ne 0 ]; then
    if printf '%s\n' "$out" | grep -q '^code: NOT_FOUND$'; then
      fail "the surviving item $keep is not in the backlog, so $id would be lost"
    fi
    fail "the surviving item $keep cannot be read: $(printf '%s\n' "$out" | sed -n '1p')"
  fi
  state=$(dup_show_field "$out" state) && [ -n "$state" ] || fail "the surviving item $keep has no readable state"
  body=$(dup_show_field "$out" body) || fail "the surviving item $keep has no readable body"
  links=$(dup_show_field "$out" links) || fail "the surviving item $keep has no readable links"
  while IFS= read -r line; do
    case "$line" in "duplicate of "*) fail "the surviving item $keep is itself closed as a duplicate ($line); name the item that remains" ;; esac
  done <<< "$body"
  [ "$state" = "done" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      dropped|"Deliverable of the finished work: dropped") fail "the surviving item $keep was closed by the captain's drop, so its work did not survive; ask the captain about $id" ;;
      "preserved in bundle /"*", not landed"|"Deliverable of the finished work: preserved in bundle /"*", not landed") fail "the surviving item $keep was closed with its work preserved in a bundle, not landed, so its work did not survive; ask the captain about $id" ;;
    esac
  done <<< "$body"
  [[ ",$links" =~ ,(pr|report): ]] \
    || fail "the surviving item $keep is Done without a merged PR or a report, so its work did not survive; ask the captain about $id"
}

dup_refuse_dependents() {  # <id>: closing the row would unblock any row that waits on it
  local id=$1 out line dep deps rest
  out=$(fm_backlog_row_list "$DATA" --fields deps --limit 100000) \
    || fail "the backlog cannot be listed, so the rows that wait on $id cannot be found"
  while IFS= read -r line; do
    case "$line" in '  '[!\ ]*) ;; *) continue ;; esac
    line=${line#  }
    dep=${line%%,*}
    case "$dep" in '"'*'"') dep=${dep#\"}; dep=${dep%\"} ;; esac
    case "$line" in
      *'"') rest=${line%\"}; deps=${rest##*,\"} ;;
      *) deps=${line##*,} ;;
    esac
    case ",$deps," in *",blocked-by:$id,"*) ;; *) continue ;; esac
    [ "$dep" != "$id" ] || continue
    fail "$dep waits on $id (blocked-by), and closing $id would unblock it while the surviving item is not done"
  done <<< "$out"
}

guard_duplicate() {  # <id> <survivor-id> <other-proof> <note-flag>
  local id=$1 keep=$2 other=$3 note=$4 out repo
  { [ -z "$other" ] && [ "$note" = 0 ]; } \
    || fail "a duplicate close is its own completion; do not combine --duplicate-of with --drop-file, --pr, --report, or --note"
  case "$id" in .|..) fail "unsupported task id '$id'" ;; esac
  [ "$keep" != "$id" ] || fail "$id cannot be a duplicate of itself"
  case "$FM_BACKLOG_ROW_KIND" in ship|scout) ;; *) fail "$id is not a ship or scout row; a duplicate close covers only those" ;; esac
  dup_refuse_row_state "$id"
  dup_refuse_task_record "$id"
  dup_refuse_dispatch_files "$id"
  out=$(fm_backlog_row_show "$DATA" "$id") || fail "cannot read the row of $id: $(printf '%s\n' "$out" | sed -n '1p')"
  repo=$(printf '%s\n' "$out" | sed -n 's/^  repo: *//p' | head -1 | tr -d '"')
  dup_project_dir "$id" "$repo"
  dup_refuse_branch "$id" "$DUP_PROJECT"
  dup_refuse_copy "$id" "$DUP_PROJECT"
  dup_refuse_work_dir "$id"
  dup_refuse_survivor "$id" "$keep"
  dup_refuse_dependents "$id"
  GUARD_ARGS=(--note "duplicate of $keep")
  # The ledger records no deliverable for a duplicate close; --duplicate-of reads as evidence none.
  LEDGER_CLOSE_ARGS=(--duplicate-of "$keep")
}

guard_completion() {
  local id=$TASK_ID pr=$TASK_PR report=$TASK_REPORT drop note=$TASK_NOTE proof=()
  drop=$(absolute_from_caller "$TASK_DROP")
  case "$TASK_COMMAND" in done|close) ;; *) return 0 ;; esac
  [ "$TASK_CONTROL_LOCK_HELD" = 1 ] || return 0
  fm_backlog_row_probe "$DATA" "$id" || {
    [ "$FM_BACKLOG_ROW_RESULT" = not_found ] && { [ -z "$TASK_DUP" ] || fail "$id is not in the backlog, so there is no row to close as a duplicate"; return 0; }
    fail "cannot identify the task being completed: ${FM_BACKLOG_ROW_ERROR:-unreadable backlog}"
  }
  # Opt-in for bin/fm-pr-close-items.sh only: refuse an open owner call for every row kind,
  # under the lock this command already holds, so a hold placed before the close wins.
  if [ "${FM_TASKS_AXI_REFUSE_OPEN_CALL:-}" = 1 ] && [ "${FM_BACKLOG_ROW_STATE%% *}" != "done" ] \
    && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
    fail "$id is an open owner call (a captain hold); resolve it with bin/fm-captain-hold.sh before completing it"
  fi
  if [ -n "$TASK_DUP" ]; then
    guard_duplicate "$id" "$TASK_DUP" "$pr$report$drop" "$note"
    return 0
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
    GUARD_STRIP_DROP=1
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
GUARD_STRIP_DROP=0
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

if [ -n "$TASK_DUP" ]; then
  # The survivor's id stays out of tasks-axi's grammar; an approved close carries only the fixed note.
  kept=()
  skip=0
  for arg in "${ARGS[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$arg" in --duplicate-of) skip=1; continue ;; --duplicate-of=*) continue ;; esac
    kept+=("$arg")
  done
  ARGS=("${kept[@]}" ${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"})
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
# Append task.filed for the item an `add` just created, read from the add's own
# output so a minted id and every defaulted field are the ones tasks-axi stored.
ledger_task_filed() {  # <captured-stdout-file>
  local out fields id='' repo='' kind='' priority='' key value ledger_state ledger_config
  out=$(cat -- "$1") || return 0
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    fields=$(printf '%s' "$out" | jq -r 'select(.ok == true and .action == "add" and (.already | not))
      | .task | "id\t\(.id // "")", "repo\t\(.repo // "")", "kind\t\(.kind // "")", "priority\t\(.priority // "")"' 2>/dev/null) || return 0
  else
    fields=$(printf '%s\n' "$out" | awk '
      /^ok: added / { added = 1; next }
      added && /^  (id|kind|repo|priority): / {
        key = $1; sub(/:$/, "", key); value = $0; sub(/^  [a-z]+: /, "", value)
        gsub(/^"|"$/, "", value); if (value == "-") value = ""
        printf "%s\t%s\n", key, value
      }') || return 0
  fi
  while IFS=$'\t' read -r key value; do
    case "$key" in id) id=$value ;; repo) repo=$value ;; kind) kind=$value ;; priority) priority=$value ;; esac
  done <<< "$fields"
  [ -n "$id" ] || return 0
  ledger_state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  ledger_config=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$ledger_state FM_CONFIG_OVERRIDE=$ledger_config \
    "$SCRIPT_DIR/fm-fleet-ledger.sh" filed "$id" "$repo" "$kind" "$priority" || true
}

case "$TASK_COMMAND" in
  add|create)
    if [ -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] && add_out=$(mktemp "${TMPDIR:-/tmp}/fm-tasks-axi-add.XXXXXX" 2>/dev/null); then
      tasks-axi ${ARGS[@]+"${ARGS[@]}"} > "$add_out"
      add_status=$?
      cat -- "$add_out"
      [ "$add_status" -ne 0 ] || ledger_task_filed "$add_out" || true
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
# Typed public-followup completions, in every form tasks-axi accepts (an optional `task` noun,
# flags before or after the id): fm_typed_completion_resolve (bin/fm-tasks-axi-lib.sh) reads
# them with tasks-axi's own grammar. These completions can move a row to Done, and a done_keep of
# 0 archives it at once, so they run without exec and a finished row stops blocking its
# dependents in the same run, exactly like done/close.
pf_form=0
fm_typed_completion_resolve ${ARGS[@]+"${ARGS[@]}"} || pf_form=$?
if [ "$pf_form" != 1 ]; then
  pf_id=$FM_TYPED_COMPLETION_ID
  pf_name=$FM_TYPED_COMPLETION
  # Main 1785 F5: the capture file exists before the completion runs. When it cannot be made,
  # the completion does not run, so nothing changes, and the caller is told to retry.
  if ! pf_out=$(mktemp "${TMPDIR:-/tmp}/fm-tasks-axi-pf.XXXXXX" 2>/dev/null); then
    printf 'actionable: the %s of %s did not run, so nothing changed: the wrapper could not make the file that keeps its output, which it needs to clear the items %s blocks; retry when %s is writable\n' \
      "$pf_name" "${pf_id:-its item}" "${pf_id:-it}" "${TMPDIR:-/tmp}" >&2
    exit 1
  fi
  tasks-axi ${ARGS[@]+"${ARGS[@]}"} > "$pf_out"
  pf_status=$?
  # Main 1875 F8: the replay of the kept output is checked. When it fails, the caller may hold
  # cut output (a JSON caller, invalid JSON), so the wrapper says the completion's own status
  # and exits 1, and the item's edges are handled below from the kept result as usual.
  pf_replay=0
  cat -- "$pf_out" || pf_replay=$?
  if [ "$pf_replay" -ne 0 ]; then
    printf 'actionable: tasks-axi finished the %s of %s with status %s, but the wrapper could not show its output (status %s), so what was printed may be cut; read the item with tasks-axi show %s before acting on it\n' \
      "$pf_name" "${pf_id:-its item}" "$pf_status" "$pf_replay" "${pf_id:-<id>}" >&2
  fi
  if [ "$pf_status" -eq 0 ] && [ "$pf_form" = 2 ]; then
    printf 'actionable: tasks-axi accepted the %s, but the wrapper could not resolve which item it completed from these arguments, so no blocked-by edge was cleared; clear the items it blocked with tasks-axi unblock <item> --by <id>\n' \
      "$pf_name" >&2
  elif [ "$pf_status" -eq 0 ] && [ "$pf_form" = 0 ]; then
    # Main 2086: the completion's own result decides the clear, with no other read. tasks-axi
    # exits 0 from `public-followup waive` and `record-delivery` only when the row it completed is
    # Done, refuses to move a public-followup row through any generic transition, and prints that
    # row's state in its result, plain and --json (fm_typed_completion_result_state reads it).
    # When the printed result names the row done, or there is no readable result at all and the
    # exit 0 alone is the proof (Main 1795), its dependents are cleared through tasks-axi's own
    # unblock, exactly as after done and close (fm_backlog_unblock_dependents). When a readable
    # result names another state or another row, every edge and hold is kept and the item is
    # reported. No tasks-axi module is loaded and no tasks-axi version is checked. tasks-axi has no
    # command that clears an id's dependents only while that id is done, in one locked write
    # (docs/configuration.md names the window this leaves).
    pf_result=0
    fm_typed_completion_result_state "$pf_out" "$pf_id" || pf_result=$?
    pf_state=$FM_TYPED_COMPLETION_RESULT_STATE
    case "$pf_result:$pf_state" in
      0:done)
        fm_backlog_unblock_dependents "$DATA" "$pf_id" >&2
        ;;
      0:*)
        printf 'actionable: tasks-axi accepted the %s of %s, but its own result shows %s as %s, not done, so every blocked-by edge and hold on it is kept\n' \
          "$pf_name" "$pf_id" "$pf_id" "$pf_state" >&2
        ;;
      2:*)
        printf 'actionable: tasks-axi accepted the %s of %s, but its own result names the row %s, not %s, so every blocked-by edge and hold on %s is kept; once %s reads done, clear its dependents with tasks-axi unblock <item> --by %s\n' \
          "$pf_name" "$pf_id" "$FM_TYPED_COMPLETION_RESULT_ROW" "$pf_id" "$pf_id" "$pf_id" "$pf_id" >&2
        ;;
      *)
        printf '%s: tasks-axi printed no result the wrapper can read for its %s, so the clear rests on its exit 0, which tasks-axi gives only when the row is done\n' \
          "$pf_id" "$pf_name" >&2
        fm_backlog_unblock_dependents "$DATA" "$pf_id" >&2
        ;;
    esac
  fi
  rm -f -- "$pf_out"
  [ "$pf_replay" -eq 0 ] || exit 1
  exit "$pf_status"
fi
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
