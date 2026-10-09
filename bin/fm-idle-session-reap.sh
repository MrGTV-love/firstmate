#!/usr/bin/env bash
# fm-idle-session-reap.sh - clean up finished worker sessions whose work has landed.
#
# Usage:
#   fm-idle-session-reap.sh scan   Print one row per ordinary task in this home; never run teardown.
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
#   - its harness reports a semantic busy state of idle (unknown is never idle:
#     bin/fm-busy-lib.sh);
#   - no steering message is waiting unhandled in state/<id>.inbox/;
#   - its newest status event is `done` and the keyed decision fold has nothing
#     open (a paused, blocked, needs-decision, captain-held, or failed task is
#     PARKED and only reported, with its reason);
#   - landing evidence exists locally, without any forge call: a scout needs a
#     nonempty regular data/<id>/report.md, and a ship needs the merge poll's
#     state/<id>.pr-poll-merge-notified marker for the PR recorded in its meta;
#   - the `done` line and the evidence are older than 30 minutes,
#     so the supervising mate has had time to read the outcome;
#   - no refusal from a recent teardown attempt still stands (see below).
# A ship that is done but has no merge marker is awaiting its pipeline or its
# merge and is reported, not reaped.
#
# A teardown that refuses is not an error: it is the landed-work test working.
# The refusal reason is recorded in state/.idle-reap/<id>.refused together with
# the status line it was made against, and the task is not offered to teardown
# again until its newest status line changes or six hours pass.
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
# At most 3 teardowns start
# per `reap` run, each bounded by 600 seconds, and a
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

. "$SCRIPT_DIR/fm-idle-reap-lib.sh"
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

record_refusal() {  # <task-id> <status-line> <reason>
  local tmp
  mkdir -p "$REAP_DIR" 2>/dev/null || return 0
  tmp=$(mktemp "$REAP_DIR/.refused.XXXXXX" 2>/dev/null) || return 0
  if printf 'fm-idle-reap-refused-v1\n%s\n%s\n%s\n' "$NOW" "$2" "$(clean_detail "$3")" > "$tmp" \
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

classify_task() {
  fm_idle_reap_classify "$FM_HOME" "$STATE" "$DATA" "$1"
  add_row "$IDLE_REAP_CLASS" "$1" "$IDLE_REAP_KIND" "$IDLE_REAP_AGE" "$IDLE_REAP_DETAIL"
  if [ "$IDLE_REAP_CLASS" = reap ]; then
    REAP_READY+=("$1")
    REAP_READY_LINES+=("$IDLE_REAP_LAST")
  fi
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
  out=$(FM_HOME="$FM_HOME" FM_IDLE_REAP_ADMISSION=1 \
    fm_run_timed 600 "$TEARDOWN_BIN" "$id" </dev/null 2>&1) || rc=$?
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
    add_row teardown-timeout "$id" - - "teardown exceeded 600s"
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
      [ "$started" -lt 3 ] || break
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
