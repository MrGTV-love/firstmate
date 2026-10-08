# shellcheck shell=bash disable=SC2034
# fm-secondmate-restart-lib.sh - the shared contract for restarting a second
# mate onto the current instruction surface and launch-time wiring. Source only.
#
# Two consumers, one owner:
#   - bin/fm-update.sh decides WHICH live mates belong in the restart set, so it
#     needs the capability test before it prints its action lines.
#   - bin/fm-secondmate-restart.sh performs the pass, so it needs the same test
#     again on its own argv rather than trusting a caller's list.
#
# The capability test is the pre-stop half of the control plane's own refusals
# (bin/fm-control-lib.sh owns those tables): a mate whose recorded backend has
# no recovery-grade agent-state classifier, or whose harness has no verified
# control mechanics, can never have "the old agent stopped and the replacement
# came up" proven for it. Asking here keeps that verdict on the side of the
# transaction where nothing has been touched yet, so an incapable mate is routed
# to the ordinary re-read nudge instead of being stopped for a launch that must
# be refused.
#
# Placement is resolved from the same remote_host= signal bin/fm-send.sh routes
# on, and it changes only the transport: the restart itself is bin/fm-control.sh
# <id> relaunch either way, run here for a local mate and run on the host over
# bin/fm-on.sh for a remote one.

_FM_SECONDMATE_RESTART_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-control-lib.sh"

# The persist request the primary sends before it restarts anything. It is the
# open-record half of /stow and nothing more: a restart needs the state of work
# written down, not a memory curation pass, and bundling one would make every
# instruction update cost far more than the reload it is paying for.
# The mate answers through its parent channel, which is what resolves the
# parent-owned reply expectation fm-send arms for a marked request; that
# correlated answer, never the wall clock, is what releases the restart.
FM_SECONDMATE_PERSIST_REQUEST='Firstmate was updated and I am about to restart your agent so it comes up on the current instructions and launch-time settings, which drops your conversation but keeps every durable record. Before that, persist the open work you are holding only in this conversation, following the /stow skill'"'"'s "Open-record persistence" section and nothing else from that skill: file a task for each open record that exists only in this conversation, including any captain call you had formed but never registered, and correct any task whose status no longer reflects what you now know. Do NOT run the memory, learnings, or captain-preference sweeps. Then reply on your parent channel saying it is done, or saying what you deliberately left alone and why.'

# Resolve one mate's restart capability from its durable record alone.
# Publishes, on success:
#   FM_SECONDMATE_RESTART_PLACEMENT  local|remote
#   FM_SECONDMATE_RESTART_BACKEND    the backend whose classifier must prove the stop
#   FM_SECONDMATE_RESTART_HARNESS    the verified control adapter it runs on
#   FM_SECONDMATE_RESTART_HOST       the configured host (remote placement only)
# and on failure sets FM_SECONDMATE_RESTART_REASON to one operator-readable line.
FM_SECONDMATE_RESTART_PLACEMENT=""
FM_SECONDMATE_RESTART_BACKEND=""
FM_SECONDMATE_RESTART_HARNESS=""
FM_SECONDMATE_RESTART_HOST=""
FM_SECONDMATE_RESTART_REASON=""
fm_secondmate_restart_capable() {  # <meta-file>
  local meta=$1 kind window remote_host backend harness family
  FM_SECONDMATE_RESTART_PLACEMENT=""
  FM_SECONDMATE_RESTART_BACKEND=""
  FM_SECONDMATE_RESTART_HARNESS=""
  FM_SECONDMATE_RESTART_HOST=""
  FM_SECONDMATE_RESTART_REASON=""

  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    FM_SECONDMATE_RESTART_REASON="no durable record for this second mate in this home"
    return 1
  fi
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" != secondmate ]; then
    FM_SECONDMATE_RESTART_REASON="the durable record is not a second mate's"
    return 1
  fi
  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ]; then
    FM_SECONDMATE_RESTART_REASON="the durable record names no endpoint, so there is no agent to replace"
    return 1
  fi
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    FM_SECONDMATE_RESTART_PLACEMENT=remote
    FM_SECONDMATE_RESTART_HOST=$remote_host
    # A remote mate's endpoint record lives on its host; the parent's own record
    # names the backend that launch established there, and the remote route
    # accepts nothing but herdr.
    backend=$(fm_meta_get "$meta" remote_backend)
    [ -n "$backend" ] || backend=herdr
  else
    FM_SECONDMATE_RESTART_PLACEMENT=local
    backend=$(fm_backend_of_meta "$meta")
  fi
  FM_SECONDMATE_RESTART_BACKEND=$backend
  if ! fm_control_backend_state_verified "$backend"; then
    FM_SECONDMATE_RESTART_REASON="its runtime cannot prove an agent stopped and came back (backend $backend)"
    return 1
  fi
  if ! family=$(fm_control_harness_family "$harness") \
    || ! fm_control_harness_supported "$family" \
    || ! fm_control_harness_supports_kind "$family" secondmate; then
    FM_SECONDMATE_RESTART_REASON="its worker runtime '${harness:-none}' has no verified restart mechanics for a second mate"
    return 1
  fi
  FM_SECONDMATE_RESTART_HARNESS=$family
  return 0
}

# --- event-driven restart requests ------------------------------------------
#
# A restart is released by two events and never by a clock: the mate's own
# correlated persist answer, then - for a local mate - the end of the turn that
# answered. A mate can sit inside one turn for hours, so a fixed wait for that
# answer could only ever fail against a busy mate; instead the request is
# recorded durably and finished whenever both events have happened.
#
# The request lives at state/.secondmate-restart-<id>.request (key=value lines:
# corr, placement, host, harness, model, effort, requested_at, and answered_at
# once the answer is seen). bin/fm-secondmate-restart.sh records it and tries it
# once; bin/fm-watch.sh's restart tick has `fm-secondmate-restart.sh
# --process-requests` try every recorded request again on the liveness cadence
# until it finishes. A finished attempt leaves exactly one outcome line at
# state/.secondmate-restart-<id>.outcome, which the watcher surfaces as one
# check wake and then removes. Teardown removes both files.
#
# Servicing holds the same per-mate lock the liveness probe and its automatic
# relaunch hold (bin/fm-secondmate-liveness-lib.sh), across the whole stop and
# relaunch, so a restart in progress can never be read as a dead endpoint and
# relaunched a second time behind it - and a liveness relaunch in progress
# defers the restart to a later attempt instead of contending with it.

fm_secondmate_restart_request_path() {  # <state> <id>
  printf '%s/.secondmate-restart-%s.request' "$1" "$2"
}

fm_secondmate_restart_outcome_path() {  # <state> <id>
  printf '%s/.secondmate-restart-%s.outcome' "$1" "$2"
}

# The last value recorded for <key> in a request record (empty when absent).
fm_secondmate_restart_request_get() {  # <request> <key>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

fm_secondmate_restart_request_write() {  # <state> <id> <corr> <placement> <host> <harness> <model> <effort>
  local request tmp
  request=$(fm_secondmate_restart_request_path "$1" "$2")
  tmp="$request.tmp.$$"
  {
    printf 'corr=%s\n' "$3"
    printf 'placement=%s\n' "$4"
    printf 'host=%s\n' "$5"
    printf 'harness=%s\n' "$6"
    printf 'model=%s\n' "$7"
    printf 'effort=%s\n' "$8"
    printf 'requested_at=%s\n' "$(date +%s)"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$request" 2>/dev/null && return 0
  rm -f "$tmp"
  return 1
}

# Retire a request with one outcome line; the outcome is written before the
# request is removed, so a crash between the two leaves a finished request that
# the next service pass retires rather than a request with no outcome.
fm_secondmate_restart_request_finish() {  # <state> <id> <outcome-line>
  local outcome tmp
  outcome=$(fm_secondmate_restart_outcome_path "$1" "$2")
  tmp="$outcome.tmp.$$"
  printf '%s\n' "$3" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$outcome" 2>/dev/null || { rm -f "$tmp"; return 1; }
  rm -f "$(fm_secondmate_restart_request_path "$1" "$2")"
}

# 0 when a local mate's recorded endpoint is provably inside a turn, by the
# semantic busy-state contract (bin/fm-busy-lib.sh). Only an exact busy verdict
# holds the restart; idle, unknown, and dead release it, because the answer has
# already said the open work is written down and an unknown can never be
# promoted to busy.
fm_secondmate_restart_mid_turn() {  # <state> <id>
  local state=$1 id=$2 meta backend target tail40 verdict
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  if ! command -v fm_busy_classify_meta >/dev/null 2>&1; then
    # shellcheck source=bin/fm-busy-lib.sh disable=SC1091
    . "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-busy-lib.sh" || return 1
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  tail40=$(fm_backend_capture "$backend" "$target" 40 "fm-$id" 2>/dev/null) || tail40=''
  verdict=$(fm_busy_classify_meta "$meta" "$id" "$state" "$tail40" 2>/dev/null) || return 1
  [ "${verdict%% *}" = busy ]
}

# The first line of output that carries anything, flattened to one readable
# line with its "error: " prefix dropped.
fm_secondmate_restart_first_line() {  # <text>
  printf '%s\n' "$1" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
}

# Run the restart itself and print exactly one outcome line: `restarted: ...`
# or `unreached: ...`. Placement changes only the transport (see
# bin/fm-secondmate-restart.sh). Needs FM_HOME and the caller's STATE.
fm_secondmate_restart_run() {  # <state> <id> <placement> <host> <harness> <model> <effort>
  local state=$1 id=$2 placement=$3 host=$4 harness=$5 model=$6 effort=$7
  local out rc ran_on reason
  if [ "$placement" = remote ]; then
    out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" \
      "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-remote-secondmate-relaunch.sh" \
      "$id" "$harness" "${model:-default}" "${effort:-default}" < /dev/null 2>&1)
    rc=$?
  else
    out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" \
      "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-control.sh" "$id" relaunch 2>&1)
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    ran_on=$(printf '%s\n' "$out" | sed -n 's/^relaunched .* harness=\([^ ]*\).*/\1/p' | tail -1)
    [ -n "$ran_on" ] || ran_on=$harness
    if [ "$placement" = remote ]; then
      printf 'restarted: %s on %s (%s)\n' "$id" "$host" "$ran_on"
    else
      printf 'restarted: %s (%s)\n' "$id" "$ran_on"
    fi
    return 0
  fi
  reason=$(fm_secondmate_restart_first_line "$out")
  [ -n "$reason" ] || reason="the restart failed without a reported reason"
  printf 'unreached: %s: the restart outcome is unknown: %s\n' "$id" "$reason"
}

# Try one recorded request once. Needs bin/fm-secondmate-liveness-lib.sh and
# bin/fm-pending-reply-lib.sh loaded by the caller. Prints one line and returns
#   0  finished: `restarted: ...` or `unreached: ...`, recorded as the outcome
#      and the request retired
#   1  still waiting: `waiting: <id>: <why>`, the request kept for a later try
#   2  no request is recorded for <id>
fm_secondmate_restart_service() {  # <state> <id>
  local state=$1 id=$2 request corr line now
  request=$(fm_secondmate_restart_request_path "$state" "$id")
  [ -f "$request" ] && [ ! -L "$request" ] || return 2
  if ! fm_secondmate_liveness_lock "$id"; then
    printf 'waiting: %s: supervision is probing or relaunching its endpoint right now\n' "$id"
    return 1
  fi
  corr=$(fm_secondmate_restart_request_get "$request" corr)
  if [ -z "$corr" ] || ! fm_pending_reply_try_resolve "$state" "$corr"; then
    fm_secondmate_liveness_unlock "$id"
    printf 'waiting: %s: it has not yet confirmed that its open work is written down\n' "$id"
    return 1
  fi
  if [ -z "$(fm_secondmate_restart_request_get "$request" answered_at)" ]; then
    now=$(date +%s)
    printf 'answered_at=%s\n' "$now" >> "$request" 2>/dev/null || true
  fi
  if [ "$(fm_secondmate_restart_request_get "$request" placement)" != remote ] \
    && fm_secondmate_restart_mid_turn "$state" "$id"; then
    fm_secondmate_liveness_unlock "$id"
    printf 'waiting: %s: it confirmed its open work is written down and is still finishing that turn\n' "$id"
    return 1
  fi
  line=$(fm_secondmate_restart_run "$state" "$id" \
    "$(fm_secondmate_restart_request_get "$request" placement)" \
    "$(fm_secondmate_restart_request_get "$request" host)" \
    "$(fm_secondmate_restart_request_get "$request" harness)" \
    "$(fm_secondmate_restart_request_get "$request" model)" \
    "$(fm_secondmate_restart_request_get "$request" effort)")
  fm_secondmate_restart_request_finish "$state" "$id" "$line" || true
  fm_secondmate_liveness_unlock "$id"
  printf '%s\n' "$line"
  return 0
}
