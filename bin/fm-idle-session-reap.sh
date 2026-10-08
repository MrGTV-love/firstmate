#!/usr/bin/env bash
# fm-idle-session-reap.sh - clean up finished worker sessions whose work has landed.
#
# Usage:
#   fm-idle-session-reap.sh scan   Print one row per ordinary task in this home; change nothing.
#   fm-idle-session-reap.sh reap   Scan, then run bin/fm-teardown.sh on each reap-ready task.
#
# WHY. A finished worker keeps its agent process, and several hundred MB of
# memory, until someone runs bin/fm-teardown.sh for it. That someone is the
# supervising model, and on an overloaded host it can lag by a day. This sweep
# makes the cleanup of the unambiguous cases mechanical. It decides nothing about
# landing: bin/fm-teardown.sh is the sole authority, and this script only picks
# which tasks are worth asking it about. It never passes --force, never edits a
# project, and never touches a worker that could still be waiting on something.
#
# A task is reap-ready only when ALL of these hold:
#   - it is an ordinary ship or scout (never a secondmate, never a remote task);
#   - its harness reports a semantic busy state of idle (an unknown, missing, or
#     stale record is never idle: bin/fm-busy-lib.sh);
#   - no steering message is waiting unhandled in state/<id>.inbox/;
#   - its newest status event is `done` and the keyed decision fold has nothing
#     open (a paused, blocked, needs-decision, captain-held, or failed task is
#     PARKED and only reported, with its reason);
#   - landing evidence exists locally, without any forge call: a scout needs a
#     nonempty regular data/<id>/report.md, and a ship needs the merge poll's
#     state/<id>.pr-poll-merge-notified marker for the PR recorded in its meta;
#   - the `done` line and the evidence are older than FM_IDLE_REAP_GRACE_SECS
#     (default 1800), so the supervising mate has had time to read the outcome;
#   - no refusal from a recent teardown attempt still stands (see below).
# A ship that is done but has no merge marker is awaiting its pipeline or its
# merge and is reported, not reaped.
#
# A teardown that refuses is not an error: it is the landed-work test working.
# The refusal reason is recorded in state/.idle-reap/<id>.refused together with
# the status line it was made against, and the task is not offered to teardown
# again until its newest status line changes or FM_IDLE_REAP_RETRY_SECS (default
# 21600) passes. This bounds the cost of a task that stays refused for days.
# A refusal because the other supervision actor holds the task's lease
# (FM_LEASE_REFUSE_EXIT) is transient and records nothing.
#
# `scan` rows are tab-separated: <class> <task-id> <kind> <age-secs> <detail>.
# Classes: reap, wait-grace, refused, parked, awaiting-pipeline, awaiting-merge,
# scout-noreport, idle-unreported, steer-pending, active, secondmate, remote.
# `reap` adds the result rows reaped, teardown-refused, teardown-timeout, and
# lease-skipped, and publishes the complete row set atomically to
# state/idle-sessions.report so the parked sessions and their pause reasons
# can be read without rerunning the scan.
#
# Cost. The scan reads state files with shell builtins and forks only to read a
# newest status event, so a quiet sweep creates a handful of processes per task
# and none per second. At most FM_IDLE_REAP_BUDGET (default 3) teardowns start
# per `reap` run, each bounded by FM_IDLE_REAP_TEARDOWN_SECS (default 600), and a
# home-local single-flight lock keeps overlapping sweeps from queuing.
# bin/fm-watch.sh starts `reap` detached every FM_IDLE_REAP_INTERVAL seconds
# (default 900, 0 disables).
#
# Test seam: FM_IDLE_REAP_TEARDOWN_BIN replaces bin/fm-teardown.sh.
# Regression coverage: tests/fm-idle-session-reap.test.sh.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REAP_DIR="$STATE/.idle-reap"
REPORT="$STATE/idle-sessions.report"
LOCK="$STATE/.idle-reap.lock"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

TEARDOWN_BIN="${FM_IDLE_REAP_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

die() {
  printf 'fm-idle-session-reap: %s\n' "$*" >&2
  exit 2
}

whole_number_env() {  # <name> <default> <min> <max>
  local name=$1 default=$2 min=$3 max=$4 value
  eval "value=\${$name:-$default}"
  case "$value" in
    ''|*[!0-9]*) die "$name must be a whole number from $min to $max" ;;
  esac
  value=$((10#$value))
  [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] || die "$name must be a whole number from $min to $max"
  printf -v "$name" '%s' "$value"
}

whole_number_env FM_IDLE_REAP_GRACE_SECS 1800 0 604800
whole_number_env FM_IDLE_REAP_RETRY_SECS 21600 60 604800
whole_number_env FM_IDLE_REAP_BUDGET 3 1 50
whole_number_env FM_IDLE_REAP_TEARDOWN_SECS 600 1 3600

NOW=0
fm_epoch_seconds_to NOW

# Tab and newline would break the row format; a detail is also capped so one
# very long status line cannot flood the report.
clean_detail() {  # <text> -> single-line text on stdout
  local text=$1
  text=${text//$'\t'/ }
  text=${text//$'\n'/ }
  [ "${#text}" -le 240 ] || text="${text:0:240}..."
  printf '%s' "$text"
}

# Sets META_KIND, META_PR, META_REMOTE from state/<id>.meta without forking.
read_meta() {  # <meta-file>
  local line
  META_KIND=ship
  META_PR=
  META_REMOTE=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*) META_KIND=${line#kind=} ;;
      pr=*) META_PR=${line#pr=} ;;
      remote_host=*) META_REMOTE=${line#remote_host=} ;;
    esac
  done < "$1" 2>/dev/null
  [ -n "$META_KIND" ] || META_KIND=ship
}

# 0 when the merge poll's marker proves the PR recorded in meta merged. The
# marker is only ever written by the merge poll after the forge reported the
# merge (bin/fm-pr-lib.sh), so reading it needs no forge call; teardown still
# proves landing itself before anything is removed.
merge_marker_matches_pr() {  # <marker-file> <pr-url>
  local marker=$1 pr=$2 version _provider _host path number
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  { IFS= read -r version && IFS= read -r _provider && IFS= read -r _host \
      && IFS= read -r path && IFS= read -r number; } < "$marker" 2>/dev/null || return 1
  [ "$version" = fm-pr-poll-merge-notified-v1 ] || return 1
  case "$number" in ''|*[!0-9]*) return 1 ;; esac
  case "$pr" in
    */"$path"/pull/"$number"|*/"$path"/merge_requests/"$number"|*/"$path"/-/merge_requests/"$number") return 0 ;;
  esac
  return 1
}

# Prints the age in seconds of the newer of: the done line's own stamp and the
# evidence file's mtime. An unreadable time reads as 0 so it never passes grace.
terminal_age() {  # <status-line> <evidence-file>
  local line=$1 evidence=$2 at='' m='' newest=0
  if at=$(status_line_at_epoch "$line" 2>/dev/null) && [ -n "$at" ]; then
    newest=$at
  fi
  if m=$(fm_path_mtime "$evidence") && [ -n "$m" ] && [ "$m" -gt "$newest" ]; then
    newest=$m
  fi
  if [ "$newest" -eq 0 ] || [ "$newest" -gt "$NOW" ]; then
    printf '0'
  else
    printf '%s' $((NOW - newest))
  fi
}

# 0 when a recorded teardown refusal still stands for this status line.
refusal_stands() {  # <task-id> <status-line>
  local memo="$REAP_DIR/$1.refused" version at fingerprint reason
  [ -f "$memo" ] && [ ! -L "$memo" ] || return 1
  { IFS= read -r version && IFS= read -r at && IFS= read -r fingerprint && IFS= read -r reason; } < "$memo" 2>/dev/null || return 1
  [ "$version" = fm-idle-reap-refused-v1 ] || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$fingerprint" = "$2" ] || return 1
  [ $((NOW - at)) -lt "$FM_IDLE_REAP_RETRY_SECS" ] || return 1
  REFUSAL_REASON=$reason
  return 0
}

record_refusal() {  # <task-id> <status-line> <reason>
  local tmp
  mkdir -p "$REAP_DIR" 2>/dev/null || return 0
  tmp=$(mktemp "$REAP_DIR/.refused.XXXXXX" 2>/dev/null) || return 0
  if printf 'fm-idle-reap-refused-v1\n%s\n%s\n%s\n' "$NOW" "$(clean_detail "$2")" "$(clean_detail "$3")" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$REAP_DIR/$1.refused"; then
    :
  else
    rm -f -- "$tmp"
  fi
}

# A memo for a task whose record is gone describes nothing; drop it.
prune_refusals() {
  local memo id
  [ -d "$REAP_DIR" ] || return 0
  for memo in "$REAP_DIR"/*.refused; do
    [ -e "$memo" ] || continue
    id=${memo##*/}
    id=${id%.refused}
    [ -e "$STATE/$id.meta" ] || rm -f -- "$memo"
  done
}

ROWS=()
add_row() {  # <class> <task-id> <kind> <age> <detail>
  ROWS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$(clean_detail "$5")")
}

# A reap-ready row is superseded by the row for what teardown then did.
replace_reap_row() {  # <task-id>
  local row kept=()
  for row in "${ROWS[@]}"; do
    case "$row" in reap$'\t'"$1"$'\t'*) continue ;; esac
    kept+=("$row")
  done
  ROWS=()
  [ "${#kept[@]}" -eq 0 ] || ROWS=("${kept[@]}")
}

REAP_READY=()
REAP_READY_LINES=()

classify_task() {  # <task-id>
  local id=$1 meta="$STATE/$1.meta" kind busy busy_state last verb note status inbox msg evidence age open
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  read_meta "$meta"
  kind=$META_KIND
  if [ "$kind" = secondmate ]; then
    add_row secondmate "$id" "$kind" - "persistent; never reaped here"
    return 0
  fi
  if [ -n "$META_REMOTE" ]; then
    add_row remote "$id" "$kind" - "remote task on $META_REMOTE; its host owns cleanup"
    return 0
  fi

  # A record that cannot be read is named by its reason (missing, malformed,
  # gen-mismatch) and counts as unknown, which is never idle.
  if busy=$(fm_busy_record_read "$STATE" "$id"); then
    busy_state=${busy%% *}
  else
    busy_state="unknown (${busy:-unreadable})"
  fi
  if [ "$busy_state" != idle ]; then
    add_row active "$id" "$kind" - "busy state $busy_state"
    return 0
  fi

  inbox="$STATE/$id.inbox"
  for msg in "$inbox"/*.msg; do
    if [ -e "$msg" ]; then
      add_row steer-pending "$id" "$kind" - "unhandled instruction ${msg##*/}"
      return 0
    fi
  done

  status="$STATE/$id.status"
  last=$(last_status_line "$status")
  if [ -z "$last" ]; then
    add_row idle-unreported "$id" "$kind" - "idle with no status event"
    return 0
  fi
  status_line_verb "$last" verb
  note=$(status_line_note "$last")
  case "$verb" in
    done) ;;
    paused|blocked|needs-decision|failed|captain-held)
      add_row parked "$id" "$kind" - "$verb: $note"
      return 0
      ;;
    *)
      add_row idle-unreported "$id" "$kind" - "idle after $verb: $note"
      return 0
      ;;
  esac

  # The newest event is done. A keyed decision still open is the worker's claim
  # that something remains undecided, which the done line does not retire.
  open=$(status_open_decisions "$status" "$kind")
  if [ -n "$open" ]; then
    add_row parked "$id" "$kind" - "open decision: ${open%%$'\n'*}"
    return 0
  fi

  if [ "$kind" = scout ]; then
    evidence="$DATA/$id/report.md"
    if [ ! -f "$evidence" ] || [ -L "$evidence" ] || [ ! -s "$evidence" ]; then
      add_row scout-noreport "$id" "$kind" - "done without a nonempty data/$id/report.md"
      return 0
    fi
  else
    if [ -z "$META_PR" ]; then
      add_row awaiting-pipeline "$id" "$kind" - "done; no pull request recorded yet"
      return 0
    fi
    evidence="$STATE/$id.pr-poll-merge-notified"
    if ! merge_marker_matches_pr "$evidence" "$META_PR"; then
      add_row awaiting-merge "$id" "$kind" - "done; $META_PR not recorded merged"
      return 0
    fi
  fi

  age=$(terminal_age "$last" "$evidence")
  if [ "$age" -lt "$FM_IDLE_REAP_GRACE_SECS" ]; then
    add_row wait-grace "$id" "$kind" "$age" "finished ${age}s ago; grace is ${FM_IDLE_REAP_GRACE_SECS}s"
    return 0
  fi
  if refusal_stands "$id" "$last"; then
    add_row refused "$id" "$kind" "$age" "$REFUSAL_REASON"
    return 0
  fi
  add_row reap "$id" "$kind" "$age" "finished and idle"
  REAP_READY+=("$id")
  REAP_READY_LINES+=("$last")
}

scan_all() {
  local meta id
  ROWS=()
  REAP_READY=()
  REAP_READY_LINES=()
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    case "$id" in
      ''|.*|*[!A-Za-z0-9._-]*) continue ;;
    esac
    classify_task "$id"
  done
}

print_rows() {
  local row
  [ "${#ROWS[@]}" -gt 0 ] || return 0
  for row in "${ROWS[@]}"; do
    printf '%s\n' "$row"
  done
}

publish_report() {
  local tmp
  mkdir -p "$REAP_DIR" 2>/dev/null || return 0
  tmp=$(mktemp "$REAP_DIR/.report.XXXXXX" 2>/dev/null) || return 0
  if { printf '# fm-idle-session-reap %s\n' "$NOW"; print_rows; } > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$REPORT"; then
    :
  else
    rm -f -- "$tmp"
  fi
}

# The first output line that names a refusal, or nothing.
first_refusal_line() {  # <teardown-output>
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      REFUSED*|error:*|refused*)
        printf '%s' "$line"
        return 0
        ;;
    esac
  done <<EOF
$1
EOF
}

reap_one() {  # <task-id> <status-line>
  local id=$1 last=$2 out rc=0 reason
  replace_reap_row "$id"
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    fm_run_timed "$FM_IDLE_REAP_TEARDOWN_SECS" "$TEARDOWN_BIN" "$id" </dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$REAP_DIR/$id.refused"
    add_row reaped "$id" - - "teardown completed"
    return 0
  fi
  if [ "$rc" -eq "$FM_LEASE_REFUSE_EXIT" ]; then
    add_row lease-skipped "$id" - - "another supervision actor holds the task lease"
    return 0
  fi
  # The first line that names a refusal is the reason; fall back to the last
  # output line, then to the exit status.
  reason=$(first_refusal_line "$out")
  [ -n "$reason" ] || reason=${out##*$'\n'}
  [ -n "$reason" ] || reason="exit status $rc"
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    add_row teardown-timeout "$id" - - "teardown exceeded ${FM_IDLE_REAP_TEARDOWN_SECS}s"
  else
    add_row teardown-refused "$id" - - "$reason"
  fi
  record_refusal "$id" "$last" "$reason"
}

cmd_scan() {
  [ -d "$STATE" ] || die "state directory not found: $STATE"
  scan_all
  print_rows
}

cmd_reap() {
  local i started=0
  [ -d "$STATE" ] || die "state directory not found: $STATE"
  fm_lock_try_acquire "$LOCK" || exit 0
  trap 'fm_lock_release "$LOCK"' EXIT
  prune_refusals
  scan_all
  if [ "${#REAP_READY[@]}" -gt 0 ]; then
    for i in "${!REAP_READY[@]}"; do
      [ "$started" -lt "$FM_IDLE_REAP_BUDGET" ] || break
      started=$((started + 1))
      reap_one "${REAP_READY[$i]}" "${REAP_READY_LINES[$i]}"
    done
  fi
  publish_report
  print_rows
}

case "${1:-}" in
  scan) [ "$#" -eq 1 ] || die "usage: fm-idle-session-reap.sh scan|reap"; cmd_scan ;;
  reap) [ "$#" -eq 1 ] || die "usage: fm-idle-session-reap.sh scan|reap"; cmd_reap ;;
  -h|--help) usage ;;
  *) die "usage: fm-idle-session-reap.sh scan|reap" ;;
esac
