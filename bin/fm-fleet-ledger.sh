#!/usr/bin/env bash
# fm-fleet-ledger.sh - append records to the opt-in fleet activity ledger.
#
# docs/fleet-ledger.md owns the public record contract (file, events, fields,
# limits). This header owns only the writer mechanics.
#
# Off by default. Every producer guards its call with one file test on the
# home's config/fleet-ledger flag, so while the flag is absent this script is
# never run. It repeats that test so a direct invocation writes nothing.
#
# Producers:
#   bin/fm-brief.sh              appended (in every worker's status command,
#                                right after its unchanged plain append)
#   bin/fm-spawn.sh              dispatched (fresh spawns only, never relaunch)
#   bin/fm-watch.sh              capture, once per poll cycle
#   bin/fm-pr-check.sh           pr_ready (a PR registered for review, not the
#                                merge-time re-record from bin/fm-pr-merge.sh)
#   bin/fm-merge-outcome-lib.sh  merged ... pr (a recorded PR merge)
#   bin/fm-merge-local.sh        merged ... local (a local-only landing)
#   bin/fm-teardown.sh           cleaned_up
#   bin/fm-backlog-transition-lib.sh  closed (a landed backlog close: teardown,
#                                its replay, and a proven `done`)
#   bin/fm-tasks-axi.sh          filed (an `add` that created a new item)
#   bin/fm-send.sh               answered ... send (a --resolve-key close)
#   bin/fm-captain-hold.sh       filed (a captain-hold item it created),
#                                closed (a held item it moved to Done),
#                                answered ... hold (an answer or a reconciliation)
#
# Usage:
#   fm-fleet-ledger.sh dispatched <task> <kind> <project> <harness> <model>
#   fm-fleet-ledger.sh pr_ready <task> <url>
#   fm-fleet-ledger.sh merged <task> pr <url>
#   fm-fleet-ledger.sh merged <task> local
#   fm-fleet-ledger.sh cleaned_up <task>
#   fm-fleet-ledger.sh filed <task> <repo> <kind> <priority>
#   fm-fleet-ledger.sh closed <task> <evidence> <pr>
#   fm-fleet-ledger.sh answered <task> send <key>
#   fm-fleet-ledger.sh answered <task> hold <key> <source>
#   fm-fleet-ledger.sh capture [--try-lock]
#   fm-fleet-ledger.sh appended <config> <state>/<task>.status
#
# capture appends one task.status record for every complete (newline-ended)
# line added to a state/<task>.status log since that task's byte offset in
# state/.<task>.fleet-ledger-offset. An absent offset reads from byte 0, and a
# log shorter than its offset is re-read from byte 0. A partial last line waits
# for a later capture. Records are appended before the offset is saved, so an
# interrupted capture repeats records rather than losing them. Without any
# grown log, capture returns after one size listing and sources nothing.
# appended captures only that task, so a worker's status line is recorded as
# soon as the worker writes it; the byte offset keeps the per-poll capture from
# recording it again. Its arguments name the home, because a worker has no
# firstmate environment: the flag lives in <config> and the state directory is
# the status file's directory.
# pr_ready, merged, and cleaned_up first capture their own task, so its status
# records precede them. cleaned_up then deletes the task's offset, because teardown
# retires that status log right after. dispatched deletes any leftover offset
# so a reused task id starts at byte 0 of its fresh log.
# filed, closed, and answered are the lifecycle records the fleet's own scripts
# already know at the moment they happen; their callers pass what they hold and
# an empty argument is recorded as null. They add an `at` member (the same
# instant as `ts`, as ISO 8601 UTC) and capture nothing. `answered` derives its
# answered_by value itself (bin/fm-answered-by-lib.sh) from this home's role
# and, for a hold, the recorded <source> text; no caller types it. closed writes
# nothing when the task's current incarnation (after its latest task.dispatched)
# already holds a task.closed with the same evidence and pr, so a close that more
# than one path reaches is recorded once and a reopened task records its next close.
# Every write holds state/.fleet-ledger.lock.
# capture --try-lock is the watcher's periodic, nonblocking attempt: it returns
# 75 on contention without changing any status offset or ledger record, so the
# next poll retries the pending growth while lock alarms remain runnable.
# Explicit lifecycle writers and plain capture retain their blocking contract.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 on success or when off, 2 on a usage error, 75 when --try-lock
# sees contention, 1 when a record could not be written. Producers ignore a
# failure so it never changes theirs.
set -u
# Byte semantics for offsets and lengths; jq still reads the text as UTF-8.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LEDGER="$STATE/fleet-ledger.jsonl"
LOCK="$STATE/.fleet-ledger.lock"
TEXT_MAX_CHARS=2000

usage() {
  echo "usage: fm-fleet-ledger.sh dispatched <task> <kind> <project> <harness> <model> | pr_ready <task> <url> | merged <task> pr <url> | merged <task> local | cleaned_up <task> | filed <task> <repo> <kind> <priority> | closed <task> <evidence> <pr> | answered <task> send <key> | answered <task> hold <key> <source> | capture [--try-lock] | appended <config> <state>/<task>.status" >&2
  exit 2
}

task_ok() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

cmd=${1:-}
TRY_CAPTURE=0
case "$cmd" in
  dispatched) { [ "$#" -eq 6 ] && task_ok "$2"; } || usage ;;
  pr_ready) { [ "$#" -eq 3 ] && task_ok "$2" && [ -n "$3" ]; } || usage ;;
  merged)
    task_ok "${2:-}" || usage
    case "$#:${3:-}" in 4:pr) [ -n "$4" ] || usage ;; 3:local) ;; *) usage ;; esac
    ;;
  cleaned_up) { [ "$#" -eq 2 ] && task_ok "$2"; } || usage ;;
  filed) { [ "$#" -eq 5 ] && task_ok "$2"; } || usage ;;
  closed) { [ "$#" -eq 4 ] && task_ok "$2" && [ -n "$3" ]; } || usage ;;
  answered)
    task_ok "${2:-}" || usage
    case "$#:${3:-}" in 4:send) ;; 5:hold) ;; *) usage ;; esac
    [ -n "$4" ] || usage
    ;;
  capture)
    case "$#" in
      1) ;;
      2) [ "$2" = --try-lock ] || usage; TRY_CAPTURE=1 ;;
      *) usage ;;
    esac
    ;;
  appended)
    [ "$#" -eq 3 ] && [ -n "$2" ] || usage
    case "$3" in /*/*.status) ;; *) usage ;; esac
    APPENDED_TASK=${3##*/}
    APPENDED_TASK=${APPENDED_TASK%.status}
    task_ok "$APPENDED_TASK" || usage
    CONFIG=$2
    STATE=${3%/*}
    LEDGER="$STATE/fleet-ledger.jsonl"
    LOCK="$STATE/.fleet-ledger.lock"
    ;;
  *) usage ;;
esac

[ -e "$CONFIG/fleet-ledger" ] || exit 0
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1

offset_path() { printf '%s/.%s.fleet-ledger-offset' "$STATE" "$1"; }

read_offset() { # <task> <out-var>: saved byte offset, 0 when absent or malformed
  local value=0
  { IFS= read -r value < "$STATE/.$1.fleet-ledger-offset"; } 2>/dev/null || value=0
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  printf -v "$2" '%s' "$value"
}

# Print "<task>\t<size>" for every status log whose size differs from its
# saved offset, using one wc call for the whole state directory.
grown_logs() {
  local -a logs=()
  local f size path id saved
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    id=${f##*/}
    task_ok "${id%.status}" || continue
    logs+=("$f")
  done
  [ "${#logs[@]}" -gt 0 ] || return 0
  wc -c -- "${logs[@]}" 2>/dev/null | while read -r size path; do
    case "$path" in "$STATE"/*.status) ;; *) continue ;; esac
    id=${path##*/}
    id=${id%.status}
    read_offset "$id" saved
    [ "$size" = "$saved" ] || printf '%s\t%s\n' "$id" "$size"
  done
}

LIBS_LOADED=0
load_libs() {
  [ "$LIBS_LOADED" = 1 ] && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || return 1
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh" || return 1
  # shellcheck source=bin/fm-answered-by-lib.sh
  . "$SCRIPT_DIR/fm-answered-by-lib.sh" || return 1
  LIBS_LOADED=1
}

# append <event> <task> <jq-object-of-extra-members> [jq --arg pairs...]
append() {
  local event=$1 task=$2 extra=$3 line head
  # shellcheck disable=SC2016 # $event and $task here are jq variables.
  head='{v: 1, ts: (now | floor), event: $event, task: $task}'
  shift 3
  # LEDGER_AT=1 adds the same instant as ISO 8601 UTC, read once so ts and at agree.
  # shellcheck disable=SC2016 # $event, $task, and $t here are jq variables.
  [ "${LEDGER_AT:-0}" = 0 ] \
    || head='(now | floor) as $t | {v: 1, ts: $t, at: ($t | todate), event: $event, task: $task}'
  line=$(jq -cn --arg event "$event" --arg task "$task" "$@" \
    "def n: if . == \"\" then null else . end; $head + ($extra)") \
    || return 1
  # The open error is silenced so an unwritable ledger costs one summary line below.
  printf '%s\n' "$line" 2>/dev/null >> "$LEDGER"
}

# Whether the task's current incarnation already has this close: a task.closed
# for the same evidence and pr that follows the task's latest task.dispatched.
# The caller holds the lock.
closed_recorded() { # <task> <evidence> <pr>
  [ -f "$LEDGER" ] || return 1
  # shellcheck disable=SC2016 # $task, $evidence, $pr, and $e here are jq variables.
  jq -en --arg task "$1" --arg evidence "$2" --arg pr "$3" \
    'reduce (inputs | select(.task == $task)) as $e (false;
      if $e.event == "task.dispatched" then false
      elif $e.event == "task.closed" and $e.evidence == $evidence
        and $e.pr == (if $pr == "" then null else $pr end) then true
      else . end)' "$LEDGER" >/dev/null 2>&1
}

# The status-line grammar belongs to bin/fm-status-decision-lib.sh; this only projects it.
append_status() { # <task> <status-line>
  local task=$1 line=$2 verb key text
  status_line_verb "$line" verb
  case "$verb" in [a-z]*) case "$verb" in *[!a-z-]*) verb='' ;; esac ;; *) verb='' ;; esac
  key=$(_fm_decision_key "$line" 2>/dev/null) || key=''
  [ "$key" != default ] || key=''
  text=${line#*:}
  append task.status "$task" \
    "{state: (\$state | n), key: (\$key | n), text: \$text[0:$TEXT_MAX_CHARS]}" \
    --arg state "$verb" --arg key "$key" --arg text "$text"
}

capture_task() { # <task>; caller holds the lock
  local task=$1 log offset data complete tail line saved
  log="$STATE/$task.status"
  saved=$(offset_path "$task")
  [ -f "$log" ] && [ ! -L "$log" ] || return 0
  read_offset "$task" offset
  data=$(wc -c < "$log") || return 1
  data=${data//[[:space:]]/}
  [ "$data" -ge "$offset" ] || offset=0
  [ "$data" -gt "$offset" ] || return 0
  # The trailing x keeps a final newline that command substitution would strip.
  data=$(tail -c "+$((offset + 1))" "$log"; printf x) || return 1
  data=${data%x}
  tail=${data##*$'\n'}
  complete=${data%"$tail"}
  [ -n "$complete" ] || return 0
  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    append_status "$task" "$line" || return 1
  done <<< "${complete%$'\n'}"
  offset=$((offset + ${#complete}))
  printf '%s\n' "$offset" > "$saved.tmp" && mv -f "$saved.tmp" "$saved"
}

if [ "$cmd" = capture ]; then
  grown=$(grown_logs) || exit 1
  [ -n "$grown" ] || exit 0
fi

load_libs || exit 1
if [ "$TRY_CAPTURE" -eq 1 ]; then
  if ! fm_lock_try_acquire "$LOCK"; then
    [ "${FM_LOCK_BUSY:-0}" -ne 1 ] || exit 75
    exit 1
  fi
else
  fm_lock_acquire_wait "$LOCK" || exit 1
fi
trap 'fm_lock_release "$LOCK"' EXIT
rc=0
# shellcheck disable=SC2016 # $names below are jq variables, not shell ones.
case "$cmd" in
  capture)
    while IFS=$'\t' read -r task _; do
      capture_task "$task" || rc=1
    done <<< "$grown"
    ;;
  appended)
    capture_task "$APPENDED_TASK" || rc=1
    ;;
  dispatched)
    rm -f -- "$(offset_path "$2")"
    append task.dispatched "$2" \
      '{kind: ($kind | n), project: ($project | n), harness: ($harness | n), model: ($model | n)}' \
      --arg kind "$3" --arg project "$4" --arg harness "$5" --arg model "$6" || rc=1
    ;;
  pr_ready)
    capture_task "$2" || rc=1
    append task.pr_ready "$2" '{pr: $pr}' --arg pr "$3" || rc=1
    ;;
  merged)
    capture_task "$2" || rc=1
    if [ "$3" = pr ]; then
      append task.merged "$2" '{via: "pr", pr: $pr}' --arg pr "$4" || rc=1
    else
      append task.merged "$2" '{via: "local"}' || rc=1
    fi
    ;;
  filed)
    LEDGER_AT=1 append task.filed "$2" \
      '{repo: ($repo | n), kind: ($kind | n), priority: ($priority | n | if . == null then null else (tonumber? // .) end)}' \
      --arg repo "$3" --arg kind "$4" --arg priority "$5" || rc=1
    ;;
  closed)
    closed_recorded "$2" "$3" "$4" \
      || LEDGER_AT=1 append task.closed "$2" '{evidence: $evidence, pr: ($pr | n)}' \
        --arg evidence "$3" --arg pr "$4" || rc=1
    ;;
  answered)
    by=$(fm_answered_by "$FM_HOME" "$STATE" "$3" "${5:-}")
    LEDGER_AT=1 append task.answered "$2" \
      '{via: $via, key: $key, answered_by: $by}' \
      --arg via "$3" --arg key "$4" --arg by "$by" || rc=1
    ;;
  cleaned_up)
    capture_task "$2" || rc=1
    append task.cleaned_up "$2" '{}' || rc=1
    [ "$rc" -ne 0 ] || rm -f -- "$(offset_path "$2")"
    ;;
esac
[ "$rc" -eq 0 ] || echo "fm-fleet-ledger: could not record $cmd${2:+ for $2}; the ledger may be missing records" >&2
exit "$rc"
