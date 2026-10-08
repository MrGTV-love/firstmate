#!/usr/bin/env bash
# Restart second mates onto the current instruction surface and launch-time
# wiring, persisting their open records first.
#
# Usage: fm-secondmate-restart.sh <secondmate-id>... [--help]
#        fm-secondmate-restart.sh --process-requests
#
# This is the executable half of /updatefirstmate's reload step. A running agent
# holds AGENTS.md and every skill it has loaded frozen from launch, and no
# verified harness offers a reload, so a re-read steer cannot replace either -
# it appends a second copy of the mate's own job description with no defined
# precedence. Replacing the agent is the only mechanism that guarantees the new
# bytes are the ones read, and the only one that re-resolves the launch-time
# wiring - harness, model, effort, turn-end hooks, and every other flag a harness
# reads once at startup. That second half is why the update pass sends every live
# mate here, including one already on the target commit: launch-time wiring is
# not derivable from a git diff, so an unchanged tracked surface does not mean
# the running agent is already on the current behavior.
#
# The cost of that guarantee is the conversation, which is why this command runs
# in two phases and why the first one is a GATE, not a courtesy:
#
#   A. PERSIST. Every mate is asked, in one marked request, to durably record the
#      open work it holds only in conversation - a task for each unfiled open
#      record, including a captain call it formed but never registered, and a
#      status correction for each task whose recorded state is now stale. That is
#      the /stow skill's "Open-record persistence" contract and nothing else from
#      it: no memory, learnings, or captain-preference sweep, which would make
#      every instruction update cost far more than the reload it is paying for.
#      All requests go out before any restart, so a slow mate delays only its own
#      restart instead of serializing the fleet behind it.
#   B. RESTART. Only after that mate's own correlated answer lands on the parent
#      channel and affirmative evidence proves its turn ended. Both gates are
#      events, never a wall clock: this command records a durable restart
#      request, tries it once, and returns. Missing or inconclusive turn evidence,
#      including a remote route without turn evidence, leaves the restart queued
#      for supervision (bin/fm-secondmate-restart-lib.sh owns the request record,
#      gates, and the lock shared with the watcher's automatic relaunch). An
#      unanswered request stays a genuine open loop owned by the ordinary
#      pending-reply recovery ladder, not state this restart pass may close.
#
#   --process-requests is that supervision half: bin/fm-watch.sh runs it
#      detached on its liveness cadence while any request is recorded, and it
#      tries every recorded request once, leaving each finished outcome for the
#      watcher to surface as one check wake.
#
# A mate whose runtime cannot prove a restart, or whose persist request could
# not be delivered or tracked, gets the ordinary re-read nudge and is reported as
# a nudge, never as a clean reload. Once a relaunch is attempted, any failed or
# ambiguous result is reported as unknown rather than attributing it to either
# incarnation.
#
# Placement changes the transport and nothing else. A local mate is restarted
# with bin/fm-control.sh <id> relaunch, which republishes this home's own
# metadata directly; a remote mate is restarted with
# bin/fm-remote-secondmate-relaunch.sh, which runs that same command on its
# host over bin/fm-on.sh and then republishes this primary's own route
# metadata from the identity the host confirmed, since the host-local verb can
# only rewrite its own endpoint record. The restart decision, the profile, the
# request text, the bound, the failure vocabulary, and this report are all
# computed here in the primary and are identical for both.
#
# Nothing here forces, stashes, or discards anything. bin/fm-control.sh owns the
# restart transaction, its checkpoint, its journal, and its rollback; a refusal
# before the agent is stopped leaves the mate running exactly as it was.
#
# Restart candidacy itself belongs to bin/fm-update.sh, which knows which homes
# the update pass actually left on the target commit; this command re-checks
# capability on its own argv rather than trusting a caller's list.
#
# Per-mate outcome lines: `restarted: <id> ...`, `queued: <id>: <what it waits
# for>`, `nudged: <id>: <reason>`, or `unreached: <id>: <reason>`, then one
# `summary:` line.
#
# Environment knobs:
#   FM_SECONDMATE_PERSIST_POLL  seconds between checks of in-flight restarts (5)
#
# Exit status: 0 every named mate restarted or is queued for its event-driven
# restart; 3 at least one was nudged or left unreached, or request processing
# could not record completion; 1 the input itself is unusable; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,80{s/^# \{0,1\}//;p;}' "$0"
}

PROCESS_REQUESTS=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --process-requests)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    PROCESS_REQUESTS=1
    ;;
  '') usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-restart refuses to resolve second mates without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing; fm-secondmate-restart cannot resolve second mates for FM_HOME '$FM_HOME'" >&2; exit 1; }

# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# The per-mate lock the restart shares with the watcher's automatic relaunch.
# shellcheck source=/dev/null # Analyzed separately as a canonical lint root.
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

PERSIST_POLL=${FM_SECONDMATE_PERSIST_POLL:-5}
case "$PERSIST_POLL" in ''|*[!0-9]*|0) echo "error: FM_SECONDMATE_PERSIST_POLL must be a positive integer: $PERSIST_POLL" >&2; exit 2 ;; esac

IDS=()
RESULT_DIR=

stop_restart_tree() {
  local pid=$1 children child
  kill -STOP "$pid" 2>/dev/null || return 0
  children=$(ps -axo pid=,ppid= | awk -v parent="$pid" '$2 == parent { print $1 }')
  for child in $children; do
    stop_restart_tree "$child"
  done
  STOPPED_RESTART_PIDS+=("$pid")
}

reap_restart_children() {
  local owner children pid state
  local -a STOPPED_RESTART_PIDS=()
  fm_sm_live_require_locks || return 1
  fm_current_pid owner || return 1
  children=$(ps -axo pid=,ppid= | awk -v parent="$owner" '$2 == parent { print $1 }')
  for pid in $children; do
    stop_restart_tree "$pid"
  done
  for pid in "${STOPPED_RESTART_PIDS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
    while :; do
      state=$(ps -p "$pid" -o stat= 2>/dev/null) || break
      case "$state" in ''|Z*) break ;; esac
      sleep 0.01
    done
    wait "$pid" 2>/dev/null || true
  done
}

cleanup_restart() {
  trap '' INT TERM HUP
  reap_restart_children
  for id in "${IDS[@]}"; do
    fm_secondmate_liveness_unlock "$id"
  done
  [ -z "$RESULT_DIR" ] || rm -rf -- "$RESULT_DIR"
}

trap cleanup_restart EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Supervision half: try every recorded request once and leave each finished
# outcome for the watcher to surface. Completion errors remain visible.
if [ "$PROCESS_REQUESTS" -eq 1 ]; then
  process_rc=0
  for request in "$STATE"/.secondmate-restart-*.request; do
    [ -f "$request" ] && [ ! -L "$request" ] || continue
    id=${request##*/.secondmate-restart-}
    id=${id%.request}
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    IDS=("$id")
    fm_secondmate_liveness_lock "$id" || continue
    (
      trap 'trap "" INT TERM HUP; reap_restart_children' EXIT
      trap 'exit 143' TERM
      trap 'exit 129' HUP
      fm_secondmate_restart_service_locked "$STATE" "$id" >/dev/null
    ) &
    wait "$!"
    [ "$?" -ne 3 ] || process_rc=3
    fm_secondmate_liveness_unlock "$id"
  done
  exit "$process_rc"
fi

for arg in "$@"; do
  case "$arg" in
    -*) echo "error: unexpected argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
  # /updatefirstmate's action line names each mate by its fm-<id> selector; the
  # bare id is equally acceptable so a hand-run stays natural.
  id=${arg#fm-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $arg" >&2; exit 2 ;; esac
  case " ${IDS[*]:-} " in
    *" $id "*) continue ;;
  esac
  IDS+=("$id")
done
[ "${#IDS[@]}" -gt 0 ] || { usage >&2; exit 2; }

# Per-mate pass state, kept as parallel indexed arrays so this stays bash-3.2
# safe. PLAN is the phase the mate reached: persist-sent, or fallback with the
# reason already decided.
PLAN=()
REASON=()
PLACEMENT=()
HOST=()
HARNESS=()
MODEL=()
EFFORT=()
RESTART_PID=()
RESTART_RESULT=()

restarted_count=0
queued_count=0
nudged_count=0
unreached_count=0

# A refusal's own words are the most useful thing this report can carry, and
# its first line is often blank.
first_reported_line() {  # <text>
  fm_secondmate_restart_first_line "$1"
}

# Send the ordinary re-read steer to a mate this pass will not restart, and say
# plainly which it was. A nudge is a partial reload and is never reported as more.
fall_back_to_nudge() {  # <id> <reason>
  local id=$1 reason=$2 out
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$FM_SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
    nudged_count=$((nudged_count + 1))
    printf 'nudged: %s: %s\n' "$id" "$reason"
  else
    unreached_count=$((unreached_count + 1))
    printf 'unreached: %s: %s; the re-read message could not be delivered either: %s\n' \
      "$id" "$reason" "$(first_reported_line "$out")"
  fi
}

# One restart worker: try the mate's recorded request once. A finished
# outcome was reported here, so its outcome record is removed rather than left
# for the watcher to surface a second time; a waiting mate stays queued.
service_mate() {  # <array-index>
  local i=$1 id line rc
  id=${IDS[$i]}
  line=$(fm_secondmate_restart_service_locked "$STATE" "$id" consume); rc=$?
  case "$rc" in
    0|3)
      printf '%s\n' "$line"
      ;;
    1)
      printf 'queued: %s: %s; supervision restarts it once it has\n' "$id" "${line#waiting: "$id": }"
      ;;
    *)
      printf 'unreached: %s: its recorded restart request could not be serviced\n' "$id"
      ;;
  esac
}

launch_restart() {  # <array-index>
  local i=$1 result tmp
  result="$RESULT_DIR/$i.result"
  tmp="$result.tmp"
  (
    trap 'trap "" INT TERM HUP; reap_restart_children' EXIT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    service_mate "$i" > "$tmp"
    mv -f "$tmp" "$result"
  ) &
  RESTART_PID[i]=$!
  RESTART_RESULT[i]=$result
  PLAN[i]=restarting
  restart_active_count=$((restart_active_count + 1))
}

harvest_restarts() {
  local i out worker_state
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != restarting ]; then
      i=$((i + 1))
      continue
    fi
    if [ -f "${RESTART_RESULT[i]}" ]; then
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      out=$(cat "${RESTART_RESULT[i]}")
    else
      if kill -0 "${RESTART_PID[i]}" 2>/dev/null; then
        worker_state=$(ps -p "${RESTART_PID[i]}" -o stat= 2>/dev/null || true)
        case "$worker_state" in
          Z*) ;;
          *)
            i=$((i + 1))
            continue
            ;;
        esac
      fi
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      if [ -f "${RESTART_RESULT[i]}" ]; then
        out=$(cat "${RESTART_RESULT[i]}")
      else
        out="unreached: ${IDS[$i]}: the restart worker exited before publishing an outcome"
      fi
    fi
    fm_secondmate_liveness_unlock "${IDS[$i]}"
    printf '%s\n' "$out"
    case "$out" in
      restarted:*) restarted_count=$((restarted_count + 1)) ;;
      queued:*) queued_count=$((queued_count + 1)) ;;
      nudged:*) nudged_count=$((nudged_count + 1)) ;;
      *) unreached_count=$((unreached_count + 1)) ;;
    esac
    PLAN[i]="done"
    restart_active_count=$((restart_active_count - 1))
    i=$((i + 1))
  done
}

RESULT_DIR=$(mktemp -d "$STATE/.secondmate-restart.XXXXXX") || {
  echo "error: could not create restart result directory under $STATE" >&2
  exit 1
}
restart_active_count=0
sorted_ids=$(printf '%s\n' "${IDS[@]}" | LC_ALL=C sort)
IDS=()
while IFS= read -r id; do IDS+=("$id"); done <<EOF
$sorted_ids
EOF

# --- phase A: persist ------------------------------------------------------
# Every request goes out before any restart, so the fleet persists concurrently
# and one busy mate delays only itself.

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  id=${IDS[$i]}
  PLAN[i]="fallback"
  REASON[i]=""
  PLACEMENT[i]=""
  HOST[i]=""
  HARNESS[i]=""
  MODEL[i]=""
  EFFORT[i]=""
  if ! fm_secondmate_liveness_lock "$id"; then
    printf 'waiting: %s: supervision is probing or relaunching its endpoint; waiting to record its restart request\n' "$id" >&2
    fm_lock_acquire_wait "$STATE/.secondmate-liveness-$id.lock"
  fi
  if ! fm_secondmate_restart_capable "$STATE/$id.meta"; then
    REASON[i]=$FM_SECONDMATE_RESTART_REASON
    fm_secondmate_liveness_unlock "$id"
    i=$((i + 1))
    continue
  fi
  PLACEMENT[i]=$FM_SECONDMATE_RESTART_PLACEMENT
  HOST[i]=$FM_SECONDMATE_RESTART_HOST
  HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS
  if [ "${PLACEMENT[i]}" = remote ]; then
    # A local relaunch re-resolves this home's durable secondmate pin on its own,
    # which is the one owner of that resolution. A remote one cannot: it runs in
    # a home whose config/secondmate-harness is deliberately NOT inherited, so
    # the file on that host belongs to a different home and re-resolving there
    # would silently move the mate onto another runtime. Resolve the pin here and
    # pass it explicitly, so both placements land on the same decision.
    HARNESS[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    [ -n "${HARNESS[i]}" ] || HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS
    MODEL[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    EFFORT[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "${EFFORT[i]}" in
      ''|low|medium|high|xhigh|max|ultra) ;;
      *) EFFORT[i]="" ;;
    esac
    resolved_model=${MODEL[i]}
    if [ -n "${MODEL[i]}" ] && ! resolved_model=$("$SCRIPT_DIR/fm-model-index.sh" model "${HARNESS[i]}" "${MODEL[i]}" 2>/dev/null); then
      REASON[i]="its configured model does not resolve through the model index (a retired id or an unconfigured role)"
      fm_secondmate_liveness_unlock "$id"
      i=$((i + 1))
      continue
    fi
    if [ "${EFFORT[i]}" = ultra ] && ! "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "${HARNESS[i]}" "$resolved_model" "${EFFORT[i]}"; then
      REASON[i]="the configured Ultra profile does not select native Codex through Pi"
      fm_secondmate_liveness_unlock "$id"
      i=$((i + 1))
      continue
    fi
  fi

  # A restart already recorded for this mate is still waiting on that mate's
  # own events; asking again would only queue a second persist request behind
  # the first, so the recorded request is tried instead.
  if [ -f "$(fm_secondmate_restart_outcome_path "$STATE" "$id")" ]; then
    RESTART_RESULT[i]="$RESULT_DIR/$i.result"
    RESTART_PID[i]=""
    service_mate "$i" > "${RESTART_RESULT[i]}"
    PLAN[i]="restarting"
    restart_active_count=$((restart_active_count + 1))
    fm_secondmate_liveness_unlock "$id"
    i=$((i + 1))
    continue
  fi
  if [ -f "$(fm_secondmate_restart_request_path "$STATE" "$id")" ]; then
    PLAN[i]="recorded"
    i=$((i + 1))
    continue
  fi

  if ! corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$id" \
    "$FM_SECONDMATE_PERSIST_REQUEST"); then
    REASON[i]="its answer about the open work cannot be tracked, so a clean reload could not be proven"
    fm_secondmate_liveness_unlock "$id"
    i=$((i + 1))
    continue
  fi
  if ! send_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$FM_SECONDMATE_PERSIST_REQUEST" 2>&1); then
    fm_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
    REASON[i]="the request to write down its open work could not be delivered: $(first_reported_line "$send_out")"
    fm_secondmate_liveness_unlock "$id"
    i=$((i + 1))
    continue
  fi
  if ! fm_secondmate_restart_request_write "$STATE" "$id" "$corr" "${PLACEMENT[i]}" \
    "${HOST[i]}" "${HARNESS[i]}" "${MODEL[i]}" "${EFFORT[i]}"; then
    REASON[i]="its restart request could not be recorded, so it was asked to write down its open work but will not be restarted"
    fm_secondmate_liveness_unlock "$id"
    i=$((i + 1))
    continue
  fi
  PLAN[i]="recorded"
  i=$((i + 1))
done

# --- phase B: restart ------------------------------------------------------
# Each recorded mate is tried once, in parallel. One whose answer and turn end
# have already happened restarts now; any other stays queued for supervision.

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  if [ "${PLAN[i]}" = recorded ]; then
    launch_restart "$i"
  elif [ "${PLAN[i]}" != restarting ]; then
    fall_back_to_nudge "${IDS[$i]}" "${REASON[i]}"
    PLAN[i]="done"
  fi
  i=$((i + 1))
done

while [ "$restart_active_count" -gt 0 ]; do
  harvest_restarts
  [ "$restart_active_count" -eq 0 ] || sleep "$PERSIST_POLL"
done

# --- summary ---------------------------------------------------------------

printf 'summary: %d of %d restarted, %d queued, %d nudged, %d unreached\n' \
  "$restarted_count" "${#IDS[@]}" "$queued_count" "$nudged_count" "$unreached_count"
[ "$((nudged_count + unreached_count))" -eq 0 ] || exit 3
exit 0
