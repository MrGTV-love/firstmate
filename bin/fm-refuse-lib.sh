#!/usr/bin/env bash
# Typed policy refusal presentation, not policy enforcement.
# Usage (source this library):
#   fm_refuse GUARD RULE MISSING machine COMMAND SUBJECT_KIND SUBJECT [TASK]
#   fm_refuse GUARD RULE MISSING human-only QUESTION SUBJECT_KIND SUBJECT [TASK]
# Prints only to stderr. Returns 0, including on optional telemetry failure;
# the caller retains its existing exit/return code and all policy predicates.
# Never call on usage, contention, transport or other transient errors alone.
# fm_friction_event GUARD RULE SUBJECT_KIND SUBJECT EXIT_KIND [TASK] records a
# blocked event through the single Python writer. It never records the missing
# predicate's text, command, question or raw subject. FM_HOME must be explicit.
# FM_FRICTION_{EVENT,ATTEMPT,OPERATION,EPISODE}_ID optionally correlate events;
# reuse EVENT_ID only for duplicate delivery, not a new attempt.
# docs/configuration.md "Friction ledger" owns the schema and privacy contract.

FM_REFUSE_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fm_friction_event() {  # <guard> <rule> <subject-kind> <subject> <exit-kind> [task]
  python3 "$FM_REFUSE_LIB_DIR/fm-friction-ledger.py" refusal \
    "$1" "$2" "$3" "$4" "$5" "${6:-${FM_TASK_ID:-}}" \
    "${FM_FRICTION_REVISION_FILE:-$FM_REFUSE_LIB_DIR/fm-refuse-lib.sh}" || true
  return 0
}

fm_refuse() {  # <guard> <rule> <missing> <exit-kind> <exit> <subject-kind> <subject> [task]
  printf 'REFUSED: guard=%s rule=%s missing=%s\n' "$1" "$2" "$3" >&2
  case "$4" in
    machine) printf 'completing-command: %s\n' "$5" >&2 ;;
    human-only) printf 'human-only-exit: %s\n' "$5" >&2 ;;
    *) printf 'fm-friction: invalid refusal exit category; guarded result unchanged\n' >&2; return 0 ;;
  esac
  fm_friction_event "$1" "$2" "$6" "$7" "$4" "${8:-${FM_TASK_ID:-}}"
  return 0
}
