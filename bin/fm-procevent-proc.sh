#!/usr/bin/env bash
# Process pile-up process-event adapter.
#
# Usage:
#   fm-procevent-proc.sh arm [--warn-pct <percent>] [--hold <secs>] [--interval <secs>] [--limit <n>]
#   fm-procevent-proc.sh poll [--warn-pct <percent>] [--hold <secs>] [--interval <secs>] [--limit <n>]
#   fm-procevent-proc.sh classify <result-file>
#   fm-procevent-proc.sh terminal <result-file>
#   fm-procevent-proc.sh source-id
#   fm-procevent-proc.sh retire
#
# arm        Register the standing pile-up detector. Its blocking child is
#            bin/fm-proc-guard.sh watch: it samples the user's process count once
#            per --interval (default 1s) and, when the count stays above
#            --warn-pct of the per-user limit (default 60) for more than --hold
#            seconds (default 5), writes one census to state/proc-census.*.json
#            and ends with a result that becomes the durable
#            `check: procevent proc-guard:<seq>` wake. --limit overrides the host's
#            limit for a host that cannot read it. Arming again with the same
#            flags is idempotent. A host the guard cannot measure is refused
#            with exit 3 and registers nothing. The detector never kills anything.
# poll       The blocking child the generic runner executes; never run this
#            directly in a conversational turn.
# classify   Print the captured outcome class: pileup, error, or unknown.
# terminal   Only an error result ends the source; a pile-up keeps listening.
# source-id  Print the canonical source id.
# retire     Retire the registration.
#
# After a capture the runner exits and the watcher's next reconcile starts a new
# poll. An open episode (state/proc-guard.episode) makes that poll wait, silently,
# until the count has dropped back, so one pile-up produces one census and one wake.
# bin/fm-proc-guard.py owns the thresholds, the count semantics, and the census
# document.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SOURCE_ID=proc-guard

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

positive_number() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

positive_int() { case "${1-}" in ''|*[!0-9]*|0|0[0-9]*) return 1 ;; *) return 0 ;; esac; }

# parse_flags <arg>...
# Fills GUARD_FLAGS with validated guard watch flags and CHECK_FLAGS with the
# subset the one-shot check also takes.
parse_flags() {
  GUARD_FLAGS=()
  CHECK_FLAGS=()
  local LC_ALL=C
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --warn-pct)
        positive_number "${2-}" && [[ "$2" =~ ^([0-9]{1,2}(\.[0-9]+)?|100(\.0+)?)$ ]] \
          || die "--warn-pct needs a percent above 0 and at most 100"
        GUARD_FLAGS+=(--warn-pct "$2"); CHECK_FLAGS+=(--warn-pct "$2"); shift 2 ;;
      --hold)
        positive_number "${2-}" || die "--hold needs a positive number of seconds"
        GUARD_FLAGS+=(--hold "$2"); shift 2 ;;
      --interval)
        positive_number "${2-}" || die "--interval needs a positive number of seconds"
        GUARD_FLAGS+=(--interval "$2"); shift 2 ;;
      --limit)
        positive_int "${2-}" || die "--limit needs a positive integer"
        GUARD_FLAGS+=(--limit "$2"); CHECK_FLAGS+=(--limit "$2"); shift 2 ;;
      *) usage ;;
    esac
  done
}

cmd_arm() {
  parse_flags "$@"
  local verdict
  verdict=$("$SCRIPT_DIR/fm-proc-guard.sh" check --json ${CHECK_FLAGS[@]+"${CHECK_FLAGS[@]}"} 2>/dev/null) || verdict=
  case "$verdict" in
    *'"status": "UNKNOWN"'*|'')
      printf 'unsupported: the process guard cannot measure this host\n' >&2
      exit 3 ;;
  esac
  "$SCRIPT_DIR/fm-procevent.sh" register proc "$SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-proc.sh" poll ${GUARD_FLAGS[@]+"${GUARD_FLAGS[@]}"} || exit 1
  printf 'armed: %s\n' "$SOURCE_ID"
}

cmd_poll() {
  parse_flags "$@"
  exec "$SCRIPT_DIR/fm-proc-guard.sh" watch --state-dir "$STATE" --source-id "$SOURCE_ID" \
    ${GUARD_FLAGS[@]+"${GUARD_FLAGS[@]}"}
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(awk '
    $0 == "output:" { exit }
    /^status: / { sub(/^status: /, ""); print; exit }
  ' "$file")
  case "$status" in
    pileup|error) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ "$(cmd_classify "$file")" = error ]
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  source-id) shift; printf '%s\n' "$SOURCE_ID" ;;
  retire)    shift; [ "$#" -eq 0 ] || usage; "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
