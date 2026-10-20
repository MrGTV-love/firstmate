#!/usr/bin/env bash
# Typed policy refusal presentation, not policy enforcement.
# Usage (source this library):
#   fm_refuse GUARD RULE MISSING machine COMMAND SUBJECT_KIND SUBJECT [TASK]
#   fm_refuse GUARD RULE MISSING human-only QUESTION SUBJECT_KIND SUBJECT [TASK]
# Prints only to stderr. Returns 0, including on optional telemetry failure;
# the caller retains its existing exit/return code and all policy predicates.
# Never call on usage, contention, transport or other transient errors alone.
# A machine COMMAND is printed with FM_FRICTION_OPERATION_ID and
# FM_FRICTION_EPISODE_ID prefixed, so its run correlates with this refusal. One
# process keeps one operation across its refusals unless the environment supplies one.
# fm_friction_event GUARD RULE SUBJECT_KIND SUBJECT EXIT_KIND [TASK] records a
# blocked event through the single Python writer. It never records the missing
# predicate's text, command, question or raw subject. FM_HOME must be explicit.
# FM_FRICTION_{EVENT,ATTEMPT,OPERATION,EPISODE}_ID optionally correlate events;
# reuse EVENT_ID only for duplicate delivery, not a new attempt.
# fm_friction_outcome OUTCOME GUARD SUBJECT_KIND SUBJECT [TASK] appends a
# follow-up event only for the operation FM_FRICTION_OPERATION_ID names and only
# when the ledger already holds its blocked event; an empty SUBJECT is the whole
# operation. Call it only where the outcome was observed.
# Every field the envelope prints is shown through fm_refuse_text, so text a
# copy path, lock reason or tool message carries can never add a line of its own.
# docs/configuration.md "Friction ledger" owns the schema and privacy contract.

FM_REFUSE_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FM_REFUSE_OPERATION=

fm_refuse_text() {  # <text>: the text with every control character, newline included, shown as ?
  printf '%s' "${1//[[:cntrl:]]/?}"
}

fm_friction_event() {  # <guard> <rule> <subject-kind> <subject> <exit-kind> [task]
  python3 "$FM_REFUSE_LIB_DIR/fm-friction-ledger.py" refusal \
    "$1" "$2" "$3" "$4" "$5" "${6:-${FM_TASK_ID:-}}" \
    "${FM_FRICTION_REVISION_FILE:-$FM_REFUSE_LIB_DIR/fm-refuse-lib.sh}" || true
  return 0
}

fm_friction_outcome() {  # <outcome> <guard> <subject-kind> <subject> [task]
  [ -n "${FM_FRICTION_OPERATION_ID:-}" ] || return 0
  python3 "$FM_REFUSE_LIB_DIR/fm-friction-ledger.py" outcome \
    "$1" "$2" "$3" "$4" "${5:-${FM_TASK_ID:-}}" || true
  return 0
}

fm_refuse() {  # <guard> <rule> <missing> <exit-kind> <exit> <subject-kind> <subject> [task]
  local operation episode
  printf 'REFUSED: guard=%s rule=%s missing=%s\n' "$(fm_refuse_text "$1")" "$(fm_refuse_text "$2")" "$(fm_refuse_text "$3")" >&2
  case "$4" in
    machine|human-only) ;;
    *) printf 'fm-friction: invalid refusal exit category; guarded result unchanged\n' >&2; return 0 ;;
  esac
  operation=${FM_FRICTION_OPERATION_ID:-$FM_REFUSE_OPERATION}
  [ -n "$operation" ] || operation=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null) || operation=
  FM_REFUSE_OPERATION=$operation
  episode=${FM_FRICTION_EPISODE_ID:-$operation}
  if [ "$4" = machine ]; then
    printf 'completing-command: %s%s\n' \
      "${operation:+FM_FRICTION_OPERATION_ID=$operation FM_FRICTION_EPISODE_ID=$episode }" "$(fm_refuse_text "$5")" >&2
  else
    printf 'human-only-exit: %s\n' "$(fm_refuse_text "$5")" >&2
  fi
  FM_FRICTION_OPERATION_ID=$operation FM_FRICTION_EPISODE_ID=$episode \
    fm_friction_event "$1" "$2" "$6" "$7" "$4" "${8:-${FM_TASK_ID:-}}"
  return 0
}
