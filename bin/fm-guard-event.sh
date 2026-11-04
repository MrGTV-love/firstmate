#!/usr/bin/env bash
# fm-guard-event.sh - the single best-effort writer of guard decision events.
# Usage: fm-guard-event.sh <guard-id> <deny|warn|allow|error|bypass> [options]
# Options:
#   --rule <id>             stable sub-rule (default: guard id)
#   --task <id>             affected task (default: FM_TASK_ID)
#   --session <id>          harness session when no task is known
#   --source-ok true|false  authoritative source readable (default true)
#   --elapsed-ms <n>        decision duration (default 0)
#   --cleared-by <word>     retry, captain, waiver, env, or caller-owned token
#   --repeat <n>            caller's consecutive decision count (default 1)
#   --override              existing waiver, force or escape was used
#   --actor <class>         gate, worker or main (default: worker with FM_TASK_ID,
#                           else main); an allow clears only its own class's denies
#   --no-opportunity        one more rule row for an operation already counted
#   --system <name>         default firstmate
#   --guard-version <v>     default 1
#   --head <sha>            refused/allowed commit, for read-only detection
#   --base <ref>            base branch, for read-only detection
#   --log <path>            default FM_GUARD_EVENT_LOG, else home's state log
# Session identity is the task, else physical home plus harness session.
# Without a harness session it is home:unattributed, never a new process id.
# The default home log is written only when that home's state directory already
# exists: the writer never creates a home, so a home check after it still refuses.
# Exit always 0, even with malformed arguments, missing tools or failed writes.
# Callers must also use || true so an unavailable writer never changes policy.
set -u

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in ''|-h|--help) usage; exit 0 ;; esac
GUARD=$1 DECISION=${2:-}
case "$DECISION" in deny|warn|allow|error|bypass) ;; *) exit 0 ;; esac
shift 2
SOURCE_OK=true ELAPSED_MS=0 CLEARED_BY='' REPEAT=1 OVERRIDE=false
SYSTEM=firstmate GUARD_VERSION=1 SESSION='' LOG='' RULE=$GUARD TASK=${FM_TASK_ID:-}
HEAD='' BASE='' ACTOR=${FM_TASK_ID:+worker} OPPORTUNITY=true
ACTOR=${ACTOR:-main}
while [ $# -gt 0 ]; do
  case "$1" in
    --override) OVERRIDE=true; shift; continue ;;
    --no-opportunity) OPPORTUNITY=false; shift; continue ;;
    --source-ok|--elapsed-ms|--cleared-by|--repeat|--system|--guard-version|--session|--log|--rule|--task|--head|--base|--actor)
      [ $# -ge 2 ] || exit 0 ;;
    *) shift; continue ;;
  esac
  case "$1" in
    --source-ok) SOURCE_OK=$2 ;;
    --elapsed-ms) ELAPSED_MS=$2 ;;
    --cleared-by) CLEARED_BY=$2 ;;
    --repeat) REPEAT=$2 ;;
    --system) SYSTEM=$2 ;;
    --guard-version) GUARD_VERSION=$2 ;;
    --session) SESSION=$2 ;;
    --log) LOG=$2 ;;
    --rule) RULE=$2 ;;
    --task) TASK=$2 ;;
    --head) HEAD=$2 ;;
    --base) BASE=$2 ;;
    --actor) ACTOR=$2 ;;
  esac
  shift 2
done
case "$SOURCE_OK" in true|false) ;; *) SOURCE_OK=false ;; esac
case "$ELAPSED_MS" in ''|*[!0-9]*) ELAPSED_MS=0 ;; esac
case "$REPEAT" in ''|*[!0-9]*|0) REPEAT=1 ;; esac
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 0
ROOT=$(cd "$SCRIPT_DIR/.." && pwd) || exit 0
HOME_KEY=${FM_HOME:-${FM_ROOT:-$ROOT}}
HOME_KEY=$(cd "$HOME_KEY" 2>/dev/null && pwd -P) || HOME_KEY=${FM_HOME:-${FM_ROOT:-$ROOT}}
HOME_LOG=false
if [ -z "$LOG" ]; then
  LOG=${FM_GUARD_EVENT_LOG:-}
  if [ -z "$LOG" ]; then
    [ -d "$HOME_KEY/state" ] || exit 0
    LOG=$HOME_KEY/state/guard-events.jsonl
    HOME_LOG=true
  fi
fi
if [ -n "$TASK" ]; then
  SESSION=$TASK
else
  [ -n "$SESSION" ] || SESSION=${FM_SESSION_ID:-}
  if [ -z "$SESSION" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    # The shared owner rejects a Claude id inherited by an unrelated harness.
    SESSION=$(
      # shellcheck source=bin/fm-session-lock-lib.sh
      . "$SCRIPT_DIR/fm-session-lock-lib.sh" || exit 1
      fm_session_lock_trusted_session_id
    ) 2>/dev/null || SESSION=''
  fi
  SESSION="$HOME_KEY:${SESSION:-${CODEX_THREAD_ID:-${PI_SESSION_ID:-${OMP_SESSION_ID:-${GROK_SESSION_ID:-unattributed}}}}}"
fi
# One encoder handles all JSON control characters, including multiline input.
LINE=$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg guard "$GUARD" --arg rule "$RULE" --arg task "$TASK" --arg session "$SESSION" \
  --arg version "$GUARD_VERSION" --arg system "$SYSTEM" --arg decision "$DECISION" \
  --argjson source_ok "$SOURCE_OK" --arg elapsed_ms "$ELAPSED_MS" \
  --arg cleared_by "$CLEARED_BY" --arg repeat "$REPEAT" --argjson override "$OVERRIDE" \
  --arg head "$HEAD" --arg base "$BASE" --arg actor "$ACTOR" --argjson opportunity "$OPPORTUNITY" \
  '{ts:$ts,guard:$guard,rule:$rule,task:$task,version:$version,system:$system,
    session:$session,decision:$decision,source_ok:$source_ok,elapsed_ms:($elapsed_ms|tonumber),
    cleared_by:$cleared_by,repeat:($repeat|tonumber),override:$override,head:$head,base:$base,
    actor:$actor,opportunity:$opportunity}' 2>/dev/null) || exit 0
# Never open a pipe or device: best-effort telemetry must not wait for a reader.
if [ -e "$LOG" ] && [ ! -f "$LOG" ]; then exit 0; fi
LOG_DIR=${LOG%/*}
[ "$LOG_DIR" != "$LOG" ] || LOG_DIR=.
if ! { { [ "$HOME_LOG" = true ] || mkdir -p "$LOG_DIR" 2>/dev/null; } && printf '%s\n' "$LINE" >>"$LOG" 2>/dev/null; }; then
  echo "fm-guard-event: cannot append to $LOG" >&2
fi
exit 0
