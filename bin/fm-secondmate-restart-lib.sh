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
# shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-secondmate-registry-lib.sh"

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

# Decide, before the restart's first effect, whether a live local Herdr agent is
# positively this task's own. The restart's first effects (the pending-reply
# record, the persistence request, and the fallback nudge) all reach the pane,
# so an agent the launch-proof owner cannot attribute receives none of them.
# This reads the one verdict owner (bin/fm-launch-proof-lib.sh) and keeps the
# control plane's exemption: a pane whose agent is positively dead or missing is
# governed by fm-control's own stopped-agent proofs, unchanged. Any other state,
# an endpoint that does not validate, or a backend that does not load is
# unproven and refuses. A mate whose record names a remote_host is decided on
# its host by the same owner, through the read-only
# `fm-remote-secondmate-control.sh attribution` verb over bin/fm-on.sh, whatever
# its capability verdict: a remote_backend other than herdr (or omitted, which
# is herdr) refuses, and only the exact bytes "attribution=proceed" plus one
# newline, with a zero transport status, let the restart go on; a transport
# failure, any other or extra output, or a host whose code lacks the verb refuses.
# The remote route is compared field by field (Main 1709 ruling 3, Main 1713
# (7)): the registry host, root and home must equal the record's remote_host,
# remote_root and home, and the record must name a remote_target. A remote
# proceed leaves that compared route in FM_SECONDMATE_RESTART_ROUTE_PLACEMENT
# (remote), _HOST, _ROOT, _HOME and _TARGET; a local decision leaves placement
# local and its endpoint target (Main 1807 (4)). Every later effect on the mate
# passes it through (fm_secondmate_restart_route_env), so bin/fm-on.sh,
# bin/fm-send.sh and the host verbs refuse a route or endpoint that changed
# after the decision.
# Returns 1 with FM_SECONDMATE_RESTART_REASON set when the agent is unproven.
fm_secondmate_restart_attribution() {  # <meta-file>
  local meta=$1 id cause state out rc remote_host remote_backend remote_target remote_root remote_home
  id=${meta##*/}; id=${id%.meta}
  FM_SECONDMATE_RESTART_ROUTE_PLACEMENT='' FM_SECONDMATE_RESTART_ROUTE_HOST=''
  FM_SECONDMATE_RESTART_ROUTE_ROOT='' FM_SECONDMATE_RESTART_ROUTE_HOME='' FM_SECONDMATE_RESTART_ROUTE_TARGET=''
  remote_host=$(fm_meta_get "$meta" remote_host 2>/dev/null)
  if [ -n "$remote_host" ]; then
    remote_backend=$(fm_meta_get "$meta" remote_backend 2>/dev/null)
    case "$remote_backend" in
      ''|herdr) ;;
      *)
        FM_SECONDMATE_RESTART_REASON="its record names remote_backend '$remote_backend', not herdr, so its host cannot decide the attribution and no request, record or nudge was sent to it"
        return 1
        ;;
    esac
    # The decision is bound to the route the parent recorded (Main 1634 D4):
    # bin/fm-on.sh selects the host from the registry by id, so the registry
    # route must name the recorded host, and the host compares its own endpoint
    # with the recorded target.
    remote_target=$(fm_meta_get "$meta" remote_target 2>/dev/null)
    if [ -z "$remote_target" ]; then
      FM_SECONDMATE_RESTART_REASON="its record names no remote_target, so its host decision cannot be bound to its recorded route; its host was not asked and no request, record or nudge was sent to it"
      return 1
    fi
    remote_root=$(fm_meta_get "$meta" remote_root 2>/dev/null)
    remote_home=$(fm_meta_get "$meta" home 2>/dev/null)
    if ! secondmate_registry_line_for_id "${FM_DATA_OVERRIDE:-$FM_HOME/data}/secondmates.md" "$id" \
      || [ "$SECONDMATE_REGISTRY_REMOTE" != 1 ] || [ "$SECONDMATE_REGISTRY_HOST" != "$remote_host" ] \
      || [ -z "$remote_root" ] || [ "$SECONDMATE_REGISTRY_ROOT" != "$remote_root" ] \
      || [ -z "$remote_home" ] || [ "$SECONDMATE_REGISTRY_HOME" != "$remote_home" ]; then
      FM_SECONDMATE_RESTART_REASON="its registry route (host '${SECONDMATE_REGISTRY_HOST:-none}', root '${SECONDMATE_REGISTRY_ROOT:-none}', home '${SECONDMATE_REGISTRY_HOME:-none}') is not its recorded route (host '$remote_host', root '${remote_root:-none}', home '${remote_home:-none}'); its host was not asked and no request, record or nudge was sent to it"
      return 1
    fi
    # The trailing marker keeps every byte of the reply, trailing newlines too,
    # and carries the transport status. Bash drops NUL bytes from a command
    # substitution, so each is turned into another byte first: a reply with a NUL
    # can then never equal the exact token.
    out=$(FM_HOME="$FM_HOME" FM_ON_EXPECTED_HOST="$remote_host" FM_ON_EXPECTED_ROOT="$remote_root" \
      FM_ON_EXPECTED_HOME="$remote_home" "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-on.sh" "$id" \
      fm-remote-secondmate-control.sh attribution "$id" "$remote_target" < /dev/null 2>/dev/null | LC_ALL=C tr '\000' '\001'
      printf 'x%d' "${PIPESTATUS[0]}")
    rc=${out##*x}; out=${out%x*}
    if [ "$rc" = 0 ] && [ "$out" = $'attribution=proceed\n' ]; then
      FM_SECONDMATE_RESTART_ROUTE_PLACEMENT=remote
      FM_SECONDMATE_RESTART_ROUTE_HOST=$remote_host FM_SECONDMATE_RESTART_ROUTE_ROOT=$remote_root
      FM_SECONDMATE_RESTART_ROUTE_HOME=$remote_home FM_SECONDMATE_RESTART_ROUTE_TARGET=$remote_target
      return 0
    fi
    case "$rc:$out" in
      '0:attribution=refuse: '*) cause=${out#attribution=refuse: }; cause=${cause%%$'\n'*} ;;
      *) cause="its host returned no attribution decision in the exact form (unreachable, extra output, or its code lacks the attribution verb until it is synced)" ;;
    esac
    FM_SECONDMATE_RESTART_REASON="its remote agent on $remote_host was not attributed to this task, so no request, record or nudge was sent to it: $cause"
    return 1
  fi
  # Read the backend from the record itself, never from the capability check's
  # globals: an early capability refusal leaves those empty, and the verdict
  # owner must still be asked (Main 1634 D3). A local decision keeps its
  # placement and the endpoint fm-send resolves for the mate (Main 1807 (4)).
  FM_SECONDMATE_RESTART_ROUTE_PLACEMENT=local
  FM_SECONDMATE_RESTART_ROUTE_TARGET=$(fm_backend_target_of_meta "$meta" 2>/dev/null)
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || return 0
  # shellcheck source=bin/fm-launch-proof-lib.sh disable=SC1091
  . "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-launch-proof-lib.sh"
  if ! fm_backend_source herdr; then
    FM_SECONDMATE_RESTART_REASON="the Herdr backend could not be loaded to attribute its agent, so no request or nudge was sent to it"
    return 1
  fi
  if ! fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
    FM_SECONDMATE_RESTART_REASON="its recorded Herdr endpoint does not validate, so no request or nudge was sent to it"
    return 1
  fi
  state=$(fm_backend_agent_state herdr "$FM_BACKEND_VALIDATED_TARGET")
  case "$state" in
    dead|missing) return 0 ;;
    alive) ;;
    *)
      FM_SECONDMATE_RESTART_REASON="its Herdr agent state reads '$state' rather than a positively classified state, so no request or nudge was sent to it"
      return 1
      ;;
  esac
  if cause=$(fm_launch_proof_herdr_refusal "$meta"); then
    return 0
  fi
  FM_SECONDMATE_RESTART_REASON="its live Herdr agent cannot be positively attributed to this task, so no request or nudge was sent to it${cause:+: $cause}"
  return 1
}

# The environment assignments that bind a delivery to one compared route, one
# per line for `env`, for either placement (Main 1777 (2), Main 1807 (4)). With
# no arguments it names the route the last decision compared; a caller that
# kept a mate's route passes it as <placement> <host> <root> <home> <target>.
fm_secondmate_restart_route_env() {  # [<placement> <host> <root> <home> <target>]
  local placement=${1-${FM_SECONDMATE_RESTART_ROUTE_PLACEMENT:-}} host=${2-${FM_SECONDMATE_RESTART_ROUTE_HOST:-}}
  local root=${3-${FM_SECONDMATE_RESTART_ROUTE_ROOT:-}} home=${4-${FM_SECONDMATE_RESTART_ROUTE_HOME:-}}
  local target=${5-${FM_SECONDMATE_RESTART_ROUTE_TARGET:-}}
  case "$placement" in
    remote)
      printf '%s\n' FM_SEND_EXPECTED_PLACEMENT=remote "FM_ON_EXPECTED_HOST=$host" "FM_ON_EXPECTED_ROOT=$root" \
        "FM_ON_EXPECTED_HOME=$home" "FM_SEND_EXPECTED_REMOTE_HOST=$host" "FM_SEND_EXPECTED_REMOTE_TARGET=$target" ;;
    local)
      printf '%s\n' FM_SEND_EXPECTED_PLACEMENT=local "FM_SEND_EXPECTED_ENDPOINT=$target" ;;
  esac
}

# Whether the last decision compared exactly the route <placement> <host>
# <root> <home> <target>. Prints nothing.
fm_secondmate_restart_route_is() {  # <placement> <host> <root> <home> <target>
  [ "${FM_SECONDMATE_RESTART_ROUTE_PLACEMENT:-}" = "$1" ] && [ "${FM_SECONDMATE_RESTART_ROUTE_HOST:-}" = "$2" ] \
    && [ "${FM_SECONDMATE_RESTART_ROUTE_ROOT:-}" = "$3" ] && [ "${FM_SECONDMATE_RESTART_ROUTE_HOME:-}" = "$4" ] \
    && [ "${FM_SECONDMATE_RESTART_ROUTE_TARGET:-}" = "$5" ]
}

# The same decision, re-derived from <meta-file> alone at the moment of a later
# effect (a fallback nudge after the persistence wait), so it never rests on
# another mate's placement or on an attribution read before the wait.
fm_secondmate_restart_attribution_now() {  # <meta-file>
  fm_secondmate_restart_capable "$1" || true
  fm_secondmate_restart_attribution "$1"
}
