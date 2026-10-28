#!/usr/bin/env bash
# fm-control.sh - the CONTROL PLANE for a firstmate-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id.
#
# Usage: fm-control.sh <task-id> interrupt
#        fm-control.sh <task-id> exit
#        fm-control.sh <task-id> stay
#        fm-control.sh <task-id> authorize-continuation
#        fm-control.sh <task-id> reassociate --worktree <replacement-copy>
#                                            [--also <other-task>=<its-replacement-copy>]...
#                                            (--note <text> | --note-file <path>)
# Reassociation holds the task control lock, so it makes one nonwaiting
# bin/fm-project-lock-lib.sh attempt that never jumps a queued waiter.
#        fm-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>] [--claude-debug]
#                                         [--captain-model-pin <model-id>]
#                                         [--reconcile-only] [--worktree <path>]
#                                         (--note <text> | --note-file <path>)
#        fm-control.sh <task-id> relaunch --recover-launch
# --recover-launch is Herdr-only inspection under the control lock.
# Managed and stopped agents are left untouched. Unmanaged live agents are
# reported without lifecycle input; native restoration does not prove ownership.
# Unknown proof on a versioned launch refuses. A legacy record (no launch_proof)
# keeps exit and relaunch: an unpinned legacy omp is reported as such, and other
# legacy-unproven launches skip.
# This mode cannot change a profile or create a relaunch transaction.
# --captain-model-pin is relaunch-only. A replacement model that a newer model of
# its own family and tier has passed in the harness catalog is refused before
# the running agent stops, unless it is the model the task already records or
# the pin names it exactly; the pin is passed through to fm-spawn, and
# docs/configuration.md#model-freshness owns the model freshness gate.
# --claude-debug is relaunch-only and off by default.
# It is passed through to fm-spawn and refused unless the replacement harness is claude.
# It turns on Claude's --debug log and its diagnostics file state/<id>.claude-diagnostics.jsonl, which names the signal of the next stop.
# The spawn header owns what the flag adds to the launch.
# --reconcile-only is relaunch-only: restore an exited ship/scout instruction
# owner without dispatching blocked work. It requires a readable automatic
# backlog row already In flight, preserves every hold/dependency, and refuses
# live or unattributed owners, queued work, and pending authoritative closes.
# The replacement receives fm-dod-lib.sh's reconciliation-only role above its
# historical instructions, not implementation or validation permission.
# A recorded recovery=reconcile-only is inherited even by ordinary replacement
# calls; completing a dependency or restarting the owner is not clearance.
# authorize-continuation is metadata-only: the lock-owning main Firstmate must
# explicitly clear recovery after ordinary automatic-backlog admission.
# It neither launches an agent nor delivers instructions; then use fm-send for
# a new continuation instruction, or ordinary relaunch for an exited owner.
# reassociate is metadata-only too: the lock-owning main Firstmate re-points a
# local ship or scout's record at the replacement copy its work moved to
# (worktree=, a ship's branch=, a Treehouse pool slot claim, and the brief's
# Ship branch line), anchoring the copy it leaves, recording that copy as
# prior_worktree= (or, when it is in a pool slot the task leaves entirely,
# releasing the task's claim and recording it as released_worktree=), and
# writing the note in the brief. It stops, starts,
# deletes, resets, and returns nothing: the old copy's bytes, the endpoint, and
# any pipeline run are untouched. A recorded GitHub PR is retained only when
# the replacement's HEAD equals or descends from its recorded head and the
# current forge head when readable. Missing or contradictory proof refuses.
# For duplicate slot-root records, first retire the finished records with
# plain fm-teardown; it preserves the slot and releases only their own claim,
# then reassociate the remaining record to its real copy.
# Live records that share one slot root, each with its own copy nested in it,
# cannot go one at a time, so --also re-points them in the same call: every
# named task is locked, every record is proved against its own copy, head,
# branch, and PR head before anything is written, the records overlap each
# other only through the root they leave, and a failed write restores every
# record, instructions file, and slot claim already published.
# docs/agent-control.md "Reassociating a task with a replacement
# copy" owns every refusal and what each reader of the record does after it.
# --worktree <path> is shared by two verbs and parsed once: relaunch accepts a
# prepared absolute destination for a ship relaunch, and reassociate names the
# replacement copy the record moves to.
# docs/agent-control.md "Relocating a task whose worktree is gone" owns eligibility
# and recovery guarantees; bin/fm-control-worktree-lib.sh owns their proof.
# The exit verb writes state/<id>.control-exit, bound to the current busy generation, before it types the exit command.
# A completed exit retires the busy record, so the session-end tick already skips it; the marker covers an exit whose command was delivered but whose agent did not stop within the exit wait.
# bin/fm-session-end-relaunch-lib.sh owns how that marker is read.
# Closing the background-task exit picker with Stay cancels the exit that opened it, so that close removes the marker when it names the current busy generation.
#
# Why this exists, and how it differs from fm-send.sh. bin/fm-send.sh is the
# DATA plane: conversational text for the agent to read, always routing-marked
# for a kind=secondmate target so the reply returns through the status path.
# That marking is right for a message and wrong for a lifecycle command - a
# marked "/quit" arrives as ordinary chat the agent reasons ABOUT instead of
# executing. This script is the control plane: semantic process control with a
# closed verb list, per-harness mechanics owned by an executable adapter
# (bin/fm-control-lib.sh) rather than improvised in agent prose, and a verified
# postcondition for every action. There is deliberately NO arbitrary-text and
# NO generic raw-key entry point here; fm-send remains the only way to send an
# agent something to read.
#
#   interrupt  Deliver the harness's verified interrupt sequence. The agent
#              keeps running. Postcondition: delivery succeeded, the endpoint
#              still exists, and the agent is still alive where the backend can
#              classify that. Cancellation is confirmed only from an adapter-
#              owned acknowledgement and otherwise reported unconfirmed. Busy
#              state is never rewritten as proof of the action. Devin
#              cancellation invalidates it to unknown because its native hooks
#              emit no cancellation close; this is not a success claim.
#              An adapter whose repeated interrupt key does something else on
#              an idle agent (Devin's revert picker) sends its later presses
#              only after the first press rendered a running turn, and
#              otherwise reports `cancel=not-running` having sent one press.
#   exit       Stop the agent, preserving its terminal endpoint, worktree, and
#              every uncommitted change. Interrupts first when the task reads
#              busy, then submits the harness's exit command. Postcondition:
#              the backend's recovery-grade classifier reports the agent gone.
#              Already-stopped is success (idempotent). An endpoint that reads
#              `missing` is put through the control plane's per-backend absence
#              proof (fm_control_endpoint_absence_verdict) before anything is
#              claimed about it, because `missing` also covers an endpoint that
#              is merely unreachable from this seat. Proven gone reports
#              `endpoint-gone`; a surviving idle pane is `already-stopped`.
#              A surviving agent takes the ordinary interrupt-then-exit path.
#              fm_control_endpoint_absence_verdict owns the backend evidence,
#              including the tmux proof scoped to the recorded session and worktree.
#              Claude's background-task exit picker ("Background work is
#              running") opens when /exit meets a running background shell.
#              exit answers it with "Exit and stop tasks" only for a claude
#              ship or scout whose own state (fm-crew-state.sh) is a terminal
#              done, whose busy record read idle before
#              anything was sent, whose steering inbox holds no unread
#              steering, and whose composer this same exit proved
#              empty before typing /exit; the endpoint must still read alive
#              (and, on Herdr, attributed to the task) when the key is sent,
#              and the postcondition is the ordinary
#              agent-gone proof. A picker already open when exit begins is
#              closed with the stay key first, then the composer is read again,
#              so pending text still refuses. Every other case, including
#              relaunch's own stop, refuses naming the dialog and sends no key.
#              An unrecognised dialog is never answered: any answer to one can
#              write a permanent decline.
#   stay       Close Claude's background-task exit picker for a live task and
#              leave the agent running: one Escape, sent only while the
#              recognised picker is the visible screen. Postcondition: a
#              readable viewport no longer shows the picker and the endpoint
#              still classifies the agent alive. Refuses, sending nothing, on
#              any other screen or harness.
#   relaunch   Transactionally replace the running agent with a new one, in the
#              SAME worktree - and the same endpoint whenever that endpoint
#              still exists - on the same or a newly chosen
#              harness/model/effort - so switching harness is one ordinary use
#              of this verb. When the recorded endpoint is instead proven gone -
#              the launch owner republishes the endpoint binding in that worktree.
#              Herdr keeps its recorded session; a proven-gone tmux endpoint
#              may be replaced only with Herdr when the home's current configured
#              backend resolves to herdr and passes spawn validation.
#              An explicit `default` model or effort clears that
#              axis for the replacement. With no explicit axis, a secondmate
#              re-resolves its durable config/secondmate-harness pin (harness
#              plus its optional model and effort tokens) exactly as any other
#              respawn does, while a ship or scout keeps the exact adapter
#              already recorded for it.
#              A prefixed raw-command basename cannot reconstruct its launch
#              command, so relaunch requires an explicit --harness for it.
#              A replacement Claude or Pi profile must also pass this home's
#              worker account pin (bin/fm-worker-account-lib.sh) here, so a pin
#              that no longer resolves or is signed out refuses before the old
#              agent stops. A replacement Claude profile likewise passes this
#              home's config/claude-launcher selection
#              (bin/fm-claude-launcher-lib.sh), so a malformed file or a
#              stopped TeamClaude proxy refuses before the old agent stops.
#              The same pre-stop refusal applies to this home's worker tool
#              exclusions (bin/fm-exclude-tools-lib.sh): a malformed list, or a
#              replacement runtime that cannot hide the listed tools.
#              config/session-launch-policy is checked against the resolved
#              replacement before checkpointing or stopping the current agent.
#              --note is required for a ship or scout, whose replacement
#              inherits the local copy but none of the conversation; a
#              secondmate reconciles its own home's records at startup, so its
#              standing charter is never rewritten.
#              Read-only backlog admission is checked before recording notes or
#              stopping the agent, using the launch owner's shared rule in
#              bin/fm-backlog-transition-lib.sh; predictable blocked replacement
#              refusal therefore leaves the old owner and instructions intact.
#              Records a durable checkpoint and that note, exits the old agent,
#              then delegates the launch to its single owner,
#              bin/fm-spawn.sh --relaunch. A failure before publication keeps
#              the prior durable record in place and reports the concrete
#              state; it never leaves a half-transitioned task claiming to be
#              running.
#
# Teardown and discard are NOT verbs here and never will be. `exit` stops an
# agent and preserves everything else; removing a worktree, killing an
# endpoint, or discarding work stays with bin/fm-teardown.sh, which owns the
# landed-work test.
#
# `resume` is not a verb: it is not deterministic across the verified adapters
# (bin/fm-control-lib.sh's header owns that reasoning). `relaunch` covers the
# same need for every adapter because the brief on disk, not a harness-private
# session, is the durable instruction.
#
# Targeting is EXACT: only a bare task id with a state/<id>.meta record in
# THIS home is accepted, and the record must pass the shared endpoint-identity
# validation (bin/fm-backend.sh's fm_backend_validate_task_endpoint). A legacy
# fm-<id> label, an explicit session:window endpoint, and a bare window name
# are all refused - a lifecycle command delivered to the wrong endpoint is far
# worse than a loud refusal.
#
# A remotely placed secondmate is refused by name: its agent runs on another
# host, so no postcondition this plane verifies could be read for it here.
#
# Runtime lifecycle boundaries (metadata-only authorization follows
# docs/agent-control.md "Recovering an exited instruction owner"):
#   - An unverified harness, or a harness whose control mechanics are unknown,
#     is refused rather than guessed at.
#   - A backend that cannot deliver the harness's interrupt key is refused
#     (Orca's terminal API has no Escape).
#   - `exit` and `relaunch` require a backend with a recovery-grade agent-state
#     classifier (tmux, herdr), because without one the "the agent stopped"
#     postcondition cannot be proven. zellij, orca, and cmux are refused rather
#     than reported as successful blind.
#   - An ambiguous or unreadable endpoint state refuses; only a positively
#     classified state acts.
#   - A composer that visibly holds pending text refuses before an exit command
#     is typed, so existing text is preserved instead of being concatenated.
#   - `exit` answers no dialog except the recognised exit picker above, and only
#     under that proof; `relaunch` answers none.
#
# Environment knobs (all bounded waits, seconds):
#   FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   FM_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   FM_CONTROL_ARM_WAIT          wait for an armed interrupt's rendered proof
#                                after the press gap (1.5)
#   FM_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
#   FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   FM_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)
#   FM_CONTROL_CREW_STATE_WAIT   bound on the finished-task state read exit makes
#                                only when the exit picker is showing (20)
#   FM_CREW_STATE_BIN            the state reader for that read (bin/fm-crew-state.sh);
#                                tests stub it, as bin/fm-classify-lib.sh does
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-control cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-control-worktree-lib.sh
. "$SCRIPT_DIR/fm-control-worktree-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-project-lock-lib.sh
. "$SCRIPT_DIR/fm-project-lock-lib.sh"
# shellcheck source=bin/fm-task-copy-lib.sh
. "$SCRIPT_DIR/fm-task-copy-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-api-key-guard-lib.sh
. "$SCRIPT_DIR/fm-api-key-guard-lib.sh"
# shellcheck source=bin/fm-session-launch-policy-lib.sh
. "$SCRIPT_DIR/fm-session-launch-policy-lib.sh"
# shellcheck source=bin/fm-dsh-lib.sh
. "$SCRIPT_DIR/fm-dsh-lib.sh"
# shellcheck source=bin/fm-claude-launcher-lib.sh
. "$SCRIPT_DIR/fm-claude-launcher-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-exclude-tools-lib.sh
. "$SCRIPT_DIR/fm-exclude-tools-lib.sh"
# shellcheck source=bin/fm-dispatch-capacity-lib.sh
. "$SCRIPT_DIR/fm-dispatch-capacity-lib.sh"
# shellcheck source=bin/fm-dispatch-eligibility-lib.sh
. "$SCRIPT_DIR/fm-dispatch-eligibility-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

POLL=${FM_CONTROL_POLL:-0.5}
SETTLE_WAIT=${FM_CONTROL_SETTLE_WAIT:-5}
ARM_WAIT=${FM_CONTROL_ARM_WAIT:-1.5}
EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${FM_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3}
CREW_STATE_WAIT=${FM_CONTROL_CREW_STATE_WAIT:-20}
CREW_STATE_BIN=${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}

# DIE_PREFIX names the task a refusal belongs to while one call handles several
# (reassociate --also); it is empty otherwise.
DIE_PREFIX=
die() {  # <message>
  echo "error: ${DIE_PREFIX}$1" >&2
  exit 1
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
CONTROL_META_LOCK=
CONTROL_META_LOCK_HELD=0
CONTROL_META_TMP=
CONTROL_PROJECT_LOCK=
CONTROL_PROJECT_LOCK_HELD=0
REASSOCIATE_ACTIVE=0
# The extra locks reassociate --also holds for its other tasks.
RA_CONTROL_LOCKS=()
RA_META_LOCKS=()
RA_GUARD_LOCKS=()
RELAUNCH_ACTIVE=0
RELAUNCH_PHASE=start
RELAUNCH_PAIR_DIR=

control_cleanup() {
  local status=$? extra_lock
  if [ "$RELAUNCH_ACTIVE" = 1 ] \
     && declare -F relaunch_rollback >/dev/null 2>&1; then
    relaunch_rollback || true
  fi
  if [ "$REASSOCIATE_ACTIVE" = 1 ] \
     && declare -F reassociate_rollback >/dev/null 2>&1; then
    reassociate_rollback || true
  fi
  [ -z "$CONTROL_META_TMP" ] || rm -f "$CONTROL_META_TMP"
  [ -z "$RELAUNCH_PAIR_DIR" ] || rm -rf -- "$RELAUNCH_PAIR_DIR"
  if [ "$CONTROL_META_LOCK_HELD" = 1 ]; then
    CONTROL_META_LOCK_HELD=0
    fm_lock_release "$CONTROL_META_LOCK" || true
  fi
  for extra_lock in ${RA_META_LOCKS[@]+"${RA_META_LOCKS[@]}"}; do
    fm_lock_release "$extra_lock" || true
  done
  # Remove the dialog file while the lock is still held: once it is released,
  # the next lifecycle command for this task writes the same path.
  if [ -n "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
    rm -f "$FM_COMPOSER_DIALOG_SINK"
  fi
  if [ "$CONTROL_PROJECT_LOCK_HELD" = 1 ]; then
    CONTROL_PROJECT_LOCK_HELD=0
    fm_project_lock_release "$CONTROL_PROJECT_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  for extra_lock in ${RA_CONTROL_LOCKS[@]+"${RA_CONTROL_LOCKS[@]}"} ${RA_GUARD_LOCKS[@]+"${RA_GUARD_LOCKS[@]}"}; do
    fm_lock_release "$extra_lock" || true
  done
  if declare -F fm_lease_guard_release >/dev/null 2>&1; then
    fm_lease_guard_release || true
  fi
  return "$status"
}

# --- argument parsing -------------------------------------------------------

RAW_ID=${1:-}
VERB=${2:-}
[ -n "$RAW_ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
shift 2

if ! fm_control_verb_allowed "$VERB"; then
  {
    if [ "$VERB" = resume ]; then
      echo "error: 'resume' is not a control verb: resuming an exited agent is not deterministic across the verified adapters (codex and grok need a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, and kimi have no verified pane-resume contract). Use 'relaunch', which carries the brief plus a progress note into a fresh agent on any adapter."
    else
      echo "error: '$VERB' is not a control verb"
    fi
    echo "allowed verbs:"
    fm_control_verbs | sed 's/^/  /'
  } >&2
  exit 2
fi

NEW_HARNESS=
NEW_MODEL=
NEW_EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
NOTE=
NOTE_SET=0
CLAUDE_DEBUG=0
CAPTAIN_MODEL_PIN=
CAPTAIN_MODEL_PIN_SET=0
RECONCILE_ONLY=0
RELOCATE_TO=
RELOCATE_SET=0
control_want_value=
RECOVER_LAUNCH=0
ALSO_IDS=()
ALSO_COPIES=()
# --also <task-id>=<replacement-copy>: another task reassociate re-points in the same call.
parse_also() {  # <value>
  local value=$1 also_id also_copy existing
  case "$value" in
    *=*) ;;
    *) die "--also requires <task-id>=<replacement-copy>, got '$value'" ;;
  esac
  also_id=${value%%=*}
  also_copy=${value#*=}
  fm_task_id_creation_valid "$also_id" || die "--also '$also_id' is not a valid task id"
  [ -n "$also_copy" ] || die "--also $also_id= requires a replacement copy"
  [ "$also_id" != "$RAW_ID" ] || die "--also names task $also_id, which the command already re-points"
  for existing in ${ALSO_IDS[@]+"${ALSO_IDS[@]}"}; do
    [ "$existing" != "$also_id" ] || die "--also names task $also_id twice"
  done
  ALSO_IDS+=("$also_id")
  ALSO_COPIES+=("$also_copy")
}
for control_arg in "$@"; do
  if [ -n "$control_want_value" ]; then
    case "$control_arg" in
      --*) die "--$control_want_value requires a value" ;;
    esac
    case "$control_want_value" in
      harness) NEW_HARNESS=$control_arg; HARNESS_SET=1 ;;
      model) NEW_MODEL=$control_arg; MODEL_SET=1 ;;
      effort) NEW_EFFORT=$control_arg; EFFORT_SET=1 ;;
      captain-model-pin) CAPTAIN_MODEL_PIN=$control_arg; CAPTAIN_MODEL_PIN_SET=1 ;;
      note) NOTE=$control_arg; NOTE_SET=1 ;;
      worktree) RELOCATE_TO=$control_arg; RELOCATE_SET=1 ;;
      also) parse_also "$control_arg" ;;
      note_file)
        [ -f "$control_arg" ] || die "--note-file '$control_arg' is not a readable file"
        NOTE=$(cat "$control_arg")
        NOTE_SET=1
        ;;
    esac
    control_want_value=
    continue
  fi
  case "$control_arg" in
    --harness) control_want_value=harness ;;
    --harness=*) NEW_HARNESS=${control_arg#--harness=}; HARNESS_SET=1 ;;
    --model) control_want_value=model ;;
    --model=*) NEW_MODEL=${control_arg#--model=}; MODEL_SET=1 ;;
    --effort) control_want_value=effort ;;
    --effort=*) NEW_EFFORT=${control_arg#--effort=}; EFFORT_SET=1 ;;
    --captain-model-pin) control_want_value=captain-model-pin ;;
    --captain-model-pin=*) CAPTAIN_MODEL_PIN=${control_arg#--captain-model-pin=}; CAPTAIN_MODEL_PIN_SET=1 ;;
    --worktree) control_want_value=worktree ;;
    --worktree=*) RELOCATE_TO=${control_arg#--worktree=}; RELOCATE_SET=1 ;;
    --also) control_want_value=also ;;
    --also=*) parse_also "${control_arg#--also=}" ;;
    --note) control_want_value=note ;;
    --note=*) NOTE=${control_arg#--note=}; NOTE_SET=1 ;;
    --note-file) control_want_value=note_file ;;
    --note-file=*)
      [ -f "${control_arg#--note-file=}" ] || die "--note-file '${control_arg#--note-file=}' is not a readable file"
      NOTE=$(cat "${control_arg#--note-file=}")
      NOTE_SET=1
      ;;
    --claude-debug) CLAUDE_DEBUG=1 ;;
    --recover-launch) RECOVER_LAUNCH=1 ;;
    --reconcile-only) RECONCILE_ONLY=1 ;;
    *) die "unexpected argument '$control_arg'" ;;
  esac
done
if [ -n "$control_want_value" ]; then
  [ "$control_want_value" = note_file ] && die "--note-file requires a value"
  die "--$control_want_value requires a value"
fi

[ "${#ALSO_IDS[@]}" = 0 ] || [ "$VERB" = reassociate ] \
  || die "--also applies to 'reassociate' only"
if [ "$VERB" = reassociate ]; then
  # reassociate takes --worktree, --also, and --note; every other relaunch option stays refused.
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$CLAUDE_DEBUG" = 0 ] && [ "$CAPTAIN_MODEL_PIN_SET" = 0 ] && [ "$RECOVER_LAUNCH" = 0 ] && [ "$RECONCILE_ONLY" = 0 ] \
    || die "--harness, --model, --effort, --claude-debug, --captain-model-pin, --recover-launch, and --reconcile-only apply to 'relaunch' only"
elif [ "$VERB" != relaunch ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] && [ "$CLAUDE_DEBUG" = 0 ] && [ "$CAPTAIN_MODEL_PIN_SET" = 0 ] && [ "$RECOVER_LAUNCH" = 0 ] && [ "$RECONCILE_ONLY" = 0 ] && [ "$RELOCATE_SET" = 0 ] \
    || die "--harness, --model, --effort, --note, --claude-debug, --captain-model-pin, --recover-launch, --reconcile-only, and --worktree apply to 'relaunch' only (reassociate also takes --worktree and --note)"
fi
if [ "$RECOVER_LAUNCH" = 1 ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] && [ "$CLAUDE_DEBUG" = 0 ] && [ "$CAPTAIN_MODEL_PIN_SET" = 0 ] && [ "$RECONCILE_ONLY" = 0 ] && [ "$RELOCATE_SET" = 0 ] \
    || die "--recover-launch only inspects the recorded launch; it cannot be combined with replacement options, --reconcile-only, or --worktree"
fi
[ "$RELOCATE_SET" = 0 ] || [ -n "$RELOCATE_TO" ] || die "--worktree requires a value"

[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
[ "$CAPTAIN_MODEL_PIN_SET" = 0 ] || [ -n "$CAPTAIN_MODEL_PIN" ] || die "--captain-model-pin requires a non-empty <model-id> value"
case "$NEW_EFFORT" in
  ''|default|low|medium|high|xhigh|max|ultra) ;;
  *) die "--effort must be one of default, low, medium, high, xhigh, max, ultra" ;;
esac

# --- exact task-id resolution ----------------------------------------------

case "$RAW_ID" in
  *:*) die "'$RAW_ID' is an explicit backend endpoint; fm-control accepts an exact task id only, so a lifecycle command can never land on an endpoint this home does not own" ;;
esac
if ! fm_task_id_creation_valid "$RAW_ID"; then
  die "'$RAW_ID' is not a valid task id"
fi
ID=$RAW_ID
# Supervision lease guard: lifecycle control is overlap territory between the
# two Pi supervision actors; refuse while the OTHER actor holds this task's
# live lease (contract: bin/fm-lease-lib.sh; no-op in homes without leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_guard "$ID" "lifecycle control (fm-control)"
CONTROL_LOCK="$STATE/.control-$ID.lock"
trap control_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" \
  || die "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1
# do_exit runs in a command substitution. That subshell does not run this
# EXIT trap, so the parent has to hold the path the trap removes. Set it
# only once the lock is held: a process that loses the lock runs the same
# trap, and would remove the file the lock holder is reading.
FM_COMPOSER_DIALOG_SINK=$STATE/$ID.composer-dialog
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  case "$RAW_ID" in
    fm-*)
      if [ -f "$STATE/${RAW_ID#fm-}.meta" ]; then
        die "'$RAW_ID' is a window label, not a task id; pass the exact task id '${RAW_ID#fm-}'"
      fi
      ;;
  esac
  die "no task '$ID' in $STATE (fm-control resolves an exact task id only)"
fi

if [ "$VERB" = authorize-continuation ]; then
  [ -z "${FM_TASK_ID:-}" ] \
    || die "workers cannot authorize continuation"
  fm_lease_forbid_branch "continuation authorization (fm-control)"
  CONTROL_META_LOCK=$(fm_meta_lock_path "$META") || exit 1
  fm_lock_acquire_wait "$CONTROL_META_LOCK"
  CONTROL_META_LOCK_HELD=1
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$STATE" \
    || die "continuation authorization requires the actual lock-owning main Firstmate"
  fm_backlog_record_present "$META" "task record" "$STATE" \
    || die "$FM_BACKLOG_TRANSITION_ERROR"
  [ -z "$(fm_meta_get "$META" remote_host)" ] \
    || die "continuation authorization requires a local ship or scout"
  fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
  continuation_kind=$(fm_backend_meta_exact_value "$META" kind) \
    || die "continuation authorization requires an unambiguous ship or scout kind"
  case "$continuation_kind" in
    ship|scout) ;;
    *) die "continuation authorization requires a ship or scout" ;;
  esac
  continuation_recovery=$(fm_backend_meta_exact_value "$META" recovery) \
    || die "continuation authorization requires an unambiguous recovery field"
  [ "$continuation_recovery" = reconcile-only ] \
    || die "continuation authorization requires recovery=reconcile-only"
  fm_backlog_transition_applies "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$DATA" "$continuation_kind" \
    || die "continuation authorization requires a readable automatic backlog"
  fm_backlog_relaunch_admission "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$DATA" "$continuation_kind" "$ID" 0 \
    || die "$FM_BACKLOG_TRANSITION_ERROR"
  [ ! -e "$STATE/$ID.backlog-close" ] && [ ! -L "$STATE/$ID.backlog-close" ] \
    || die "task $ID has a pending authoritative backlog close; finish or repair it before authorizing continuation"
  CONTROL_META_TMP=$(mktemp "$STATE/.$ID.meta.continuation.XXXXXX") \
    || die "could not stage continuation authorization for $ID"
  perl -e 'open(my $f, "<", $ARGV[0]) or exit 1; binmode $f; binmode STDOUT; local $/; my $s = <$f>; defined $s or exit 1; $s =~ s/^recovery=reconcile-only(?:\n|\z)//mg; print $s or exit 1' -- "$META" > "$CONTROL_META_TMP" \
    || die "could not stage continuation authorization for $ID"
  fm_backlog_atomic_transition publish "$CONTROL_META_TMP" "$META" "task record" "$STATE" \
    || die "$FM_BACKLOG_TRANSITION_ERROR"
  CONTROL_META_TMP=
  echo "continuation-authorized $ID"
  exit 0
fi

# --- reassociate: re-point the record at a replacement copy -----------------
#
# Nothing here stops, starts, deletes, resets, or returns anything.
#
# One call re-points the command's task or, with --also, several tasks whose
# records leave one shared slot root, each at its own replacement copy, under
# one set of locks. Every record is proved before anything is written, and
# every write is undone if a later one fails. The per-record state lives in the
# parallel RA_* arrays below, indexed by record: index 0 is the command's task.

RA_IDS=()
RA_METAS=()
RA_REQUEST=()
RA_NEWWT=()
RA_PREWT=()
RA_PREPROJECT=()
RA_BRIEFS=()
RA_PROJECT=()
RA_OLDWT=()
RA_OLDREAL=()
RA_OLDSTATE=()
RA_NEWBRANCH=()
RA_OLDBRANCH=()
RA_SETBRANCH=()
RA_BRANCHCOUNT=()
RA_OLDRELEASED=()
RA_SLOTRESULT=()
RA_ANCHOR=()
RA_LEFT=()
RA_NEWSLOTS=()
RA_OWN=()
RA_PROOFS=()
RA_BRIEF_TMPS=()
RA_BRIEF_BACKUPS=()
RA_BRIEF_PUBLISHED=()
RA_META_TMPS=()
RA_META_BACKUPS=()
RA_META_PUBLISHED=()
REASSOCIATE_OWNER_PATHS=()
REASSOCIATE_OWNER_BACKUPS=()
REASSOCIATE_CLAIMED=0

# Undo whatever this attempt published before it failed: every record's
# instructions, record, and slot claim come back as they were. Records are
# published last, so a failure before them never leaves one re-pointed.
reassociate_rollback() {
  local i marker backup
  for ((i=${#RA_IDS[@]} - 1; i >= 0; i--)); do
    [ -z "${RA_META_TMPS[i]:-}" ] || rm -f -- "${RA_META_TMPS[i]}"
    [ -z "${RA_BRIEF_TMPS[i]:-}" ] || rm -f -- "${RA_BRIEF_TMPS[i]}"
    if [ "${RA_META_PUBLISHED[i]:-0}" = 1 ]; then
      if fm_backlog_atomic_transition publish "${RA_META_BACKUPS[i]}" "${RA_METAS[i]}" "task record" "$STATE"; then
        RA_META_BACKUPS[i]=
      else
        echo "error: task ${RA_IDS[i]}'s record could not be restored after the failed reassociation; the prior record is at ${RA_META_BACKUPS[i]}" >&2
      fi
    elif [ -n "${RA_META_BACKUPS[i]:-}" ]; then
      rm -f -- "${RA_META_BACKUPS[i]}"
    fi
    if [ "${RA_BRIEF_PUBLISHED[i]:-0}" = 1 ] && [ -n "${RA_BRIEF_BACKUPS[i]:-}" ]; then
      if mv -f -- "${RA_BRIEF_BACKUPS[i]}" "${RA_BRIEFS[i]}" 2>/dev/null; then
        RA_BRIEF_BACKUPS[i]=
      else
        echo "error: task ${RA_IDS[i]}'s instructions could not be restored after the failed reassociation; the prior copy is at ${RA_BRIEF_BACKUPS[i]}" >&2
      fi
    elif [ -n "${RA_BRIEF_BACKUPS[i]:-}" ]; then
      rm -f -- "${RA_BRIEF_BACKUPS[i]}"
    fi
  done
  for ((i=${#REASSOCIATE_OWNER_PATHS[@]} - 1; i >= 0; i--)); do
    marker=${REASSOCIATE_OWNER_PATHS[i]}
    backup=${REASSOCIATE_OWNER_BACKUPS[i]}
    if [ -n "$backup" ]; then
      mv -f -- "$backup" "$marker" \
        || echo "error: a slot claim could not be restored from $backup" >&2
    else
      rm -f -- "$marker"
    fi
  done
}

# Refuse when another task record names <path>, since then the copy has no
# single owner and re-pointing either record would make two tasks' cleanup
# reach the same bytes. The records re-pointed together in this call are
# checked against each other by reassociate_group_check instead.
reassociate_require_sole_record() {  # <path> <label>
  local path=$1 label=$2 rc=0
  fm_task_copy_other_record "$META" "$STATE" "$path" ${RA_METAS[@]+"${RA_METAS[@]}"} || rc=$?
  case "$rc" in
    0) die "the $label $path is also task $FM_TASK_COPY_OTHER_ID's recorded $FM_TASK_COPY_OTHER_FIELD, so it has no single owner; reconcile whichever record is wrong (bin/fm-crew-state.sh $ID; bin/fm-crew-state.sh $FM_TASK_COPY_OTHER_ID) before reassociating, or name that task with --also if it leaves this copy too" ;;
    1) return 0 ;;
    *) die "could not prove that no other task record names the $label $path; nothing was changed" ;;
  esac
}

# Whether the pool slot claim just read belongs to another task re-pointed in
# this same call, so the claim is not a foreign one.
reassociate_slot_owner_is_sibling() {
  local id
  for id in ${RA_IDS[@]+"${RA_IDS[@]}"}; do
    [ "$id" != "$ID" ] && [ "$id" = "$FM_TREEHOUSE_SLOT_OWNER_ID" ] || continue
    [ -z "$FM_TREEHOUSE_SLOT_OWNER_HOME" ] || [ "$FM_TREEHOUSE_SLOT_OWNER_HOME" -ef "$FM_HOME" ] || return 1
    return 0
  done
  return 1
}

# Refuse a pool slot whose owner claim does not leave it provably this task's.
# Sets REASSOCIATE_SLOT_STATE to the claim state for the caller.
reassociate_require_slot_claim() {  # <path> <label>
  local path=$1 label=$2 marker
  fm_treehouse_slot_owner_state "$path" "$ID"
  REASSOCIATE_SLOT_STATE=$FM_TREEHOUSE_SLOT_OWNER
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine|absent) return 0 ;;
    other)
      if reassociate_slot_owner_is_sibling; then
        REASSOCIATE_SLOT_STATE=sibling
        return 0
      fi
      die "the $label $path is a pool slot claimed by task $FM_TREEHOUSE_SLOT_OWNER_ID${FM_TREEHOUSE_SLOT_OWNER_HOME:+ (home $FM_TREEHOUSE_SLOT_OWNER_HOME)}, so it is not provably task $ID's; nothing was changed"
      ;;
  esac
  marker=$(fm_treehouse_slot_owner_marker "$path" 2>/dev/null) || marker="beside $path"
  die "the $label $path carries a pool slot owner claim that cannot be read ($marker), so its owner cannot be proved; nothing was changed"
}

# Claim the replacement copy's pool slot for this task, or release this task's
# claim on a pool slot it leaves, after saving the claim for rollback. A claim
# held by another task re-pointed in this call stays that task's to keep or
# release.
reassociate_publish_slot_claim() {  # <slot> <claim|release>
  local slot=$1 action=$2 marker backup="" home=$FM_HOME
  marker=$(fm_treehouse_slot_owner_marker "$slot") || die "cannot resolve pool slot claim for $slot"
  fm_treehouse_slot_owner_state "$slot" "$ID"
  if [ "$FM_TREEHOUSE_SLOT_OWNER" = other ] && reassociate_slot_owner_is_sibling; then
    return 0
  fi
  if [ -f "$marker" ]; then
    backup=$(mktemp "$DATA/$ID/.slot-owner.prior.XXXXXX") || die "could not preserve pool slot claim for $slot"
    cp -p -- "$marker" "$backup" || { rm -f -- "$backup"; die "could not preserve pool slot claim for $slot"; }
  fi
  REASSOCIATE_OWNER_PATHS+=("$marker")
  REASSOCIATE_OWNER_BACKUPS+=("$backup")
  if [ "$action" = release ]; then
    fm_treehouse_slot_owner_release "$slot" "$ID"
    fm_treehouse_slot_owner_state "$slot" "$ID"
    [ "$FM_TREEHOUSE_SLOT_OWNER" = absent ] \
      || die "could not release task $ID's claim on pool slot $slot; nothing was changed"
    return 0
  fi
  [ "$FM_TREEHOUSE_SLOT_OWNER" != mine ] || home=$FM_TREEHOUSE_SLOT_OWNER_HOME
  [ "$FM_TREEHOUSE_SLOT_OWNER" != absent ] || REASSOCIATE_CLAIMED=1
  fm_treehouse_slot_owner_claim "$slot" "$ID" "$home" \
    || die "could not claim pool slot $slot for task $ID; nothing was changed"
}

# A recorded PR can follow its work into a new copy only when no published
# history is lost. Check the recorded head and, when the forge answers, its
# current head. A successful but malformed forge answer is not an outage.
reassociate_require_pr_head() {  # <pr-url> <replacement-copy> <project>
  local pr=$1 copy=$2 project=$3 recorded live="" head number
  local -a heads=()
  [ -n "$pr" ] || return 0
  fm_pr_url_parse "$pr" || die "recorded PR $pr has no supported identity for a PR head proof; nothing was changed"
  [ "$FM_PR_PROVIDER" = github ] \
    || die "recorded PR $pr is not a GitHub PR; its PR head cannot be verified by reassociate; nothing was changed"
  number=$FM_PR_NUMBER
  if ! recorded=$(fm_backend_meta_exact_value "$META" pr_head); then
    ! grep -q '^pr_head=' "$META" \
      || die "task $ID has no single nonempty recorded PR head; reconcile its PR registration before reassociating; nothing was changed"
    recorded=
  fi
  if [ -n "$recorded" ]; then
    fm_pr_head_valid "$recorded" \
      || die "recorded PR head '$recorded' is not a full commit SHA; nothing was changed"
    heads+=("$recorded")
  fi
  if live=$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null); then
    fm_pr_head_valid "$live" \
      || die "the forge returned no valid PR head for $pr; nothing was changed"
    [ "$live" = "$recorded" ] || heads+=("$live")
  fi
  [ "${#heads[@]}" -gt 0 ] \
    || die "task $ID already records PR $pr, but no recorded PR head or reachable forge head proves its history; restore forge access or register the PR head with bin/fm-pr-check.sh $ID '$pr' before reassociating; nothing was changed"
  for head in "${heads[@]}"; do
    if ! git -C "$project" cat-file -e "$head^{commit}" 2>/dev/null; then
      git -C "$project" fetch --quiet origin "refs/pull/$number/head" >/dev/null 2>&1 || true
    fi
    git -C "$project" cat-file -e "$head^{commit}" 2>/dev/null \
      || die "PR head $head for $pr is missing from $project's Git objects; fetch that PR's history before reassociating; nothing was changed"
    git -C "$copy" merge-base --is-ancestor "$head" HEAD \
      || die "replacement copy $copy does not contain PR head $head for $pr; use the copy whose branch tip equals or descends from that head; nothing was changed"
  done
}

# Make record <m> the current record: the globals every check and refusal reads.
reassociate_select() {  # <record-index>
  ID=${RA_IDS[$1]}
  META=${RA_METAS[$1]}
  DIE_PREFIX=
  [ "${#RA_IDS[@]}" -le 1 ] || DIE_PREFIX="task $ID: "
}

# One list per line, so a record's slot and copy lists survive in RA_* arrays.
reassociate_list() {
  local item
  for item in "$@"; do
    printf '%s\n' "$item"
  done
}

# Validate record <m> against the world and work out which pool slots it
# claims and leaves and which of its copies a reset could reach. Writes nothing.
reassociate_check() {  # <record-index>
  local m=$1 old_wt project kind kind_count branch_count old_branch new_wt new_branch="" pr
  local old_real="" old_state=present slot_result=none old_released=0 set_branch=0 brief_branch_other=0
  local line slot registered prior_real j brief
  local -a left_slots=() new_slots=() own_copies=() proofs=()
  reassociate_select "$m"
  new_wt=${RA_NEWWT[m]}
  brief="$DATA/$ID/brief.md"

  fm_backlog_record_present "$META" "task record" "$STATE" \
    || die "$FM_BACKLOG_TRANSITION_ERROR"
  [ -z "$(fm_meta_get "$META" remote_host)" ] \
    || die "task $ID is a remotely placed secondmate; reassociation applies to a local ship or scout"
  fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
  [ "$FM_BACKEND_VALIDATED_BACKEND" != orca ] \
    || die "task $ID runs on Orca, whose recorded orca_worktree_id binds the copy Orca created; re-pointing worktree= would leave Orca and the record naming different copies"
  old_wt=$(fm_backend_meta_exact_value "$META" worktree)
  project=$(fm_backend_meta_exact_value "$META" project)
  [ "$old_wt" = "${RA_PREWT[m]}" ] && [ "$project" = "${RA_PREPROJECT[m]}" ] \
    || die "task $ID's record changed while reassociation acquired its locks; nothing was changed"
  [ -d "$project" ] \
    || die "task $ID's recorded project $project is not a directory; nothing was changed"

  kind_count=$(grep -c '^kind=' "$META" 2>/dev/null || true)
  [ "${kind_count:-0}" -le 1 ] || die "task $ID records more than one kind; nothing was changed"
  kind=$(fm_meta_get "$META" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship|scout) ;;
    *) die "reassociation applies to a ship or scout; task $ID is a $kind, whose home is its identity" ;;
  esac

  pr=$(fm_meta_get "$META" pr)
  [ ! -e "$STATE/$ID.backlog-close" ] && [ ! -L "$STATE/$ID.backlog-close" ] \
    || die "task $ID has a pending authoritative backlog close from an interrupted cleanup; finish or repair it before reassociating"
  # A finished relaunch keeps its journal as that transaction's durable record,
  # so only a journal that is this task's and reads phase=complete is finished.
  if [ -e "$STATE/$ID.control-relaunch" ] || [ -L "$STATE/$ID.control-relaunch" ]; then
    [ -f "$STATE/$ID.control-relaunch" ] && [ ! -L "$STATE/$ID.control-relaunch" ] \
      && [ "$(fm_meta_get "$STATE/$ID.control-relaunch" task)" = "$ID" ] \
      && [ "$(fm_meta_get "$STATE/$ID.control-relaunch" phase)" = complete ] \
      || die "task $ID has an unfinished relaunch transaction at $STATE/$ID.control-relaunch; reconcile it before reassociating"
  fi

  RA_BRIEFS[m]=$brief
  [ -f "$brief" ] && [ ! -L "$brief" ] \
    || die "task $ID has no regular instructions file at $brief; the replacement copy must be recorded there for any future worker, so nothing was changed"

  # The replacement copy: an isolated worktree of this project's repository.
  fm_task_copy_isolated "$new_wt" "$project" \
    || die "replacement copy $new_wt is not an isolated worktree of $project: $FM_TASK_COPY_REASON; nothing was changed"
  fm_task_copy_same_repository "$new_wt" "$project" \
    || die "replacement copy $new_wt is not a checkout of task $ID's project repository ($project): it uses a different repository/ref store, even if it has the same origin; nothing was changed"

  # The current copy. A path that no longer exists has no bytes or owner left
  # to protect and is recorded as it was; anything else that exists but is not
  # a directory cannot be proved preserved, so it refuses.
  if [ -e "$old_wt" ] || [ -L "$old_wt" ]; then
    old_real=$(fm_task_copy_canonical_dir "$old_wt") \
      || die "task $ID's recorded copy $old_wt exists but is not a directory, so it cannot be proved preserved; nothing was changed"
  else
    old_state=absent
  fi
  [ "$old_real" != "$new_wt" ] \
    || die "task $ID's record already names $new_wt; nothing to reassociate"

  if [ "$kind" = ship ]; then
    new_branch=$(git -C "$new_wt" symbolic-ref --quiet --short HEAD 2>/dev/null) \
      || die "replacement copy $new_wt has a detached HEAD; a ship's record names the branch it delivers, so check that branch out there first"
    git check-ref-format --branch "$new_branch" >/dev/null 2>&1 \
      || die "replacement copy $new_wt is on '$new_branch', which is not a valid branch name"
    branch_count=$(grep -c '^branch=' "$META" 2>/dev/null || true)
    [ "${branch_count:-0}" -le 1 ] || die "task $ID records more than one branch; nothing was changed"
    old_branch=$(fm_meta_get "$META" branch)
    # The default every launch and landing path applies to a record without one.
    [ -n "$old_branch" ] || old_branch="fm/$ID"
    [ "$new_branch" = "$old_branch" ] || set_branch=1
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "Ship branch: $old_branch") ;;
        "Ship branch: "*) brief_branch_other=$((brief_branch_other + 1)) ;;
      esac
    done < "$brief"
    [ "$brief_branch_other" = 0 ] \
      || die "task $ID's instructions name a Ship branch other than its recorded branch $old_branch; reconcile the two before reassociating"
    RA_OLDBRANCH[m]=$old_branch
    RA_BRANCHCOUNT[m]=${branch_count:-0}
  fi

  reassociate_require_pr_head "$pr" "$new_wt" "$project"

  # Ownership: neither copy may be named by another task record, and a pool
  # slot either copy overlaps must be claimed by this task or by no one. A
  # slot that overlaps the replacement copy stays the task's; one that overlaps
  # only the copy it leaves is released to the pool, and no copy inside it
  # stays prior custody, since its anchored commits are what is preserved.
  reassociate_require_sole_record "$new_wt" "replacement copy"
  [ -z "$old_real" ] || reassociate_require_sole_record "$old_real" "current copy"
  registered=$(git -C "$project" worktree list --porcelain) \
    || die "could not list $project's registered worktrees to find its pool slots; nothing was changed"
  while IFS= read -r line; do
    case "$line" in worktree\ *) ;; *) continue ;; esac
    slot=$(fm_task_copy_canonical_dir "${line#worktree }") || continue
    fm_treehouse_pool_slot "$project" "$slot" || continue
    if fm_task_copy_paths_overlap "$slot" "$new_wt"; then
      reassociate_require_slot_claim "$slot" "replacement copy's overlapping pool slot"
      new_slots+=("$slot")
      case "$REASSOCIATE_SLOT_STATE" in
        mine) [ "$slot_result" = claimed ] || slot_result=kept ;;
        sibling) [ "$slot_result" = claimed ] || slot_result=kept ;;
        absent) slot_result=claimed ;;
      esac
    elif [ -n "$old_real" ] && fm_task_copy_paths_overlap "$slot" "$old_real"; then
      reassociate_require_slot_claim "$slot" "current copy's overlapping pool slot"
      left_slots+=("$slot")
      case "$old_real" in "$slot"|"$slot"/*) old_released=1 ;; esac
    fi
  done <<< "$registered"

  # A recorded copy that is gone but sat in Treehouse's <pool>/<slot>/<repo>
  # layout is a slot path, not custody: recording it as a prior copy would make
  # it block whichever task Treehouse later hands that slot to. It is history,
  # and this task's claim on it, if any, is released.
  if [ "$old_state" = absent ] && [ -f "${old_wt%/*/*}/treehouse-state.json" ] \
     && [ ! -L "${old_wt%/*/*}/treehouse-state.json" ]; then
    old_released=1
    fm_treehouse_slot_owner_state "$old_wt" "$ID"
    [ "$FM_TREEHOUSE_SLOT_OWNER" != mine ] || left_slots+=("$old_wt")
  fi

  if [ -n "$old_real" ]; then
    fm_task_copy_same_repository "$old_real" "$project" \
      || die "current copy $old_real does not share $project's Git ref store: it uses a different repository/ref store, even if it has the same origin; its commits cannot be anchored there; nothing was changed"
  fi

  # Every copy of this task a reset could reach once the record moves - the
  # current copy, each pool slot it leaves, and each prior copy inside such a
  # slot - must be clean and is anchored at refs/fm/anchor/<task>-<sha>
  # (bin/fm-task-copy-lib.sh fm_task_copy_preserve). The task's own copies
  # nested in one of them are proved or preserved on their own, so they are not
  # its dirt; so are the copies of the tasks re-pointed together with it.
  own_copies=("$new_wt")
  [ -z "$old_real" ] || own_copies+=("$old_real")
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      prior_worktree=?*)
        prior_real=$(fm_task_copy_canonical_dir "${line#prior_worktree=}") || continue
        own_copies+=("$prior_real")
        ;;
    esac
  done < "$META"
  for ((j=0; j<${#RA_IDS[@]}; j++)); do
    [ "$j" != "$m" ] || continue
    own_copies+=("${RA_NEWWT[j]}")
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        prior_worktree=?*)
          prior_real=$(fm_task_copy_canonical_dir "${line#prior_worktree=}") || continue
          own_copies+=("$prior_real")
          ;;
      esac
    done < "${RA_METAS[j]}"
  done
  for slot in ${left_slots[@]+"${left_slots[@]}"}; do
    [ ! -d "$slot" ] || proofs+=("$slot")
    while IFS= read -r prior_real; do
      proofs+=("$prior_real")
    done < <(fm_task_copy_priors_inside "$META" "$slot")
  done
  [ -z "$old_real" ] || proofs=("$old_real" ${proofs[@]+"${proofs[@]}"})

  RA_PROJECT[m]=$project
  RA_OLDWT[m]=$old_wt
  RA_OLDREAL[m]=$old_real
  RA_OLDSTATE[m]=$old_state
  RA_NEWBRANCH[m]=$new_branch
  RA_SETBRANCH[m]=$set_branch
  RA_OLDRELEASED[m]=$old_released
  RA_SLOTRESULT[m]=$slot_result
  RA_LEFT[m]=$(reassociate_list ${left_slots[@]+"${left_slots[@]}"})
  RA_NEWSLOTS[m]=$(reassociate_list ${new_slots[@]+"${new_slots[@]}"})
  RA_OWN[m]=$(reassociate_list "${own_copies[@]}")
  RA_PROOFS[m]=$(reassociate_list ${proofs[@]+"${proofs[@]}"})
}

# Records re-pointed together may share one slot root and nothing else: each
# one's current copy may be the root the others' current copies are, and each
# replacement copy may sit inside that root, but no copy may be another
# record's replacement, and no replacement may overlap anything else another
# record names. Anything else would leave two tasks with the same bytes.
reassociate_group_check() {
  local i j k line field path real target label
  for ((i=0; i<${#RA_IDS[@]}; i++)); do
    for ((j=0; j<${#RA_IDS[@]}; j++)); do
      [ "$i" != "$j" ] || continue
      reassociate_select "$i"
      if [ "$i" -lt "$j" ] && fm_task_copy_paths_overlap "${RA_NEWWT[i]}" "${RA_NEWWT[j]}"; then
        die "task ${RA_IDS[i]}'s replacement copy ${RA_NEWWT[i]} and task ${RA_IDS[j]}'s replacement copy ${RA_NEWWT[j]} overlap, so neither task would own its copy alone; give each task its own copy; nothing was changed"
      fi
      while IFS= read -r line; do
        field=${line%% *}
        path=${line#* }
        [ -n "$path" ] || continue
        real=$(fm_task_copy_canonical_dir "$path") || continue
        for k in new old; do
          if [ "$k" = new ]; then
            target=${RA_NEWWT[i]}
            label="replacement copy"
          else
            target=${RA_OLDREAL[i]}
            label="current copy"
          fi
          [ -n "$target" ] || continue
          fm_task_copy_paths_overlap "$real" "$target" || continue
          # The one overlap that is not a second owner: the root both records
          # leave, which is this record's current copy.
          if [ -n "${RA_OLDREAL[i]}" ] && [ "$real" = "${RA_OLDREAL[i]}" ]; then
            [ "$k" = old ] && continue
            case "$target" in "$real"/*) continue ;; esac
          fi
          die "the $label $target is also task ${RA_IDS[j]}'s recorded $field, so it has no single owner; reconcile whichever record is wrong (bin/fm-crew-state.sh ${RA_IDS[i]}; bin/fm-crew-state.sh ${RA_IDS[j]}) before reassociating"
        done
      done < <(fm_task_copy_record_paths "${RA_METAS[j]}")
    done
  done
}

# One proof pass over record <m>: every copy a reset could reach is clean, and
# its HEAD is anchored (written only in the write pass).
reassociate_prove() {  # <record-index> <write 0|1>
  local m=$1 write=$2 slot prior rc label old_real
  local -a own_copies=() proofs=() proved=()
  old_real=${RA_OLDREAL[m]}
  reassociate_select "$m"
  while IFS= read -r slot; do
    [ -z "$slot" ] || own_copies+=("$slot")
  done <<< "${RA_OWN[m]}"
  while IFS= read -r slot; do
    [ -z "$slot" ] || proofs+=("$slot")
  done <<< "${RA_PROOFS[m]}"
  for slot in ${proofs[@]+"${proofs[@]}"}; do
    rc=0
    for prior in ${proved[@]+"${proved[@]}"}; do
      [ "$prior" != "$slot" ] || rc=1
    done
    [ "$rc" = 0 ] || continue
    proved+=("$slot")
    label="current copy $slot"
    [ "$slot" = "$old_real" ] || label="copy $slot, which this reassociation releases to the pool,"
    fm_task_copy_preserve "${RA_PROJECT[m]}" "$ID" "$slot" "$write" "${own_copies[@]}" || rc=$?
    case "$rc" in
      0|2) ;;
      *)
        die "$label $FM_TASK_COPY_REASON; commit or carry its work over, or reassociate the task back to it, before reassociating; nothing was changed${FM_TASK_COPY_DIRTY:+:
$FM_TASK_COPY_DIRTY}"
        ;;
    esac
    [ "$slot" != "$old_real" ] || RA_ANCHOR[m]=$FM_TASK_COPY_ANCHOR
  done
}

# Stage record <m>'s new instructions and record next to the originals.
reassociate_stage() {  # <record-index> <timestamp>
  local m=$1 stamp=$2 line prior prior_real slot brief_text meta_text
  local new_wt=${RA_NEWWT[m]} new_branch=${RA_NEWBRANCH[m]} old_wt=${RA_OLDWT[m]} old_real=${RA_OLDREAL[m]}
  local set_branch=${RA_SETBRANCH[m]} old_branch=${RA_OLDBRANCH[m]:-} old_released=${RA_OLDRELEASED[m]}
  local anchor=${RA_ANCHOR[m]:-} branch_count=${RA_BRANCHCOUNT[m]:-0}
  local -a priors_kept=() left_slots=()
  reassociate_select "$m"
  while IFS= read -r slot; do
    [ -z "$slot" ] || left_slots+=("$slot")
  done <<< "${RA_LEFT[m]}"

  RA_BRIEF_TMPS[m]=$(mktemp "$DATA/$ID/.brief.reassociate.XXXXXX") \
    || die "could not stage task $ID's instructions"
  # Each staged write is checked, and each source is read whole first, so a
  # failed read or write refuses instead of publishing a truncated file.
  brief_text=$(cat -- "${RA_BRIEFS[m]}" && printf .) \
    || die "could not read task $ID's instructions; nothing was changed"
  brief_text=${brief_text%.}
  (
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$set_branch" = 1 ] && [ "$line" = "Ship branch: $old_branch" ]; then
        printf 'Ship branch: %s\n' "$new_branch" || exit 1
      else
        printf '%s\n' "$line" || exit 1
      fi
    done < <(printf '%s' "$brief_text")
    line="Work only in $new_wt."
    [ -z "$new_branch" ] || line="Work only in $new_wt, on branch $new_branch."
    prior="It replaces $old_wt, which is preserved exactly as it was; do not change it."
    [ "$old_released" != 1 ] \
      || prior="It replaces $old_wt, whose pool slot was released for reuse${anchor:+; its commits are preserved at $anchor}."
    printf '%s\n' "" "## Copy reassociation ($stamp)" "" \
      "This task's work moved to a replacement local copy." "$line" "$prior" "" "$NOTE"
  ) > "${RA_BRIEF_TMPS[m]}" || die "could not stage task $ID's instructions"

  # Which recorded prior copies survive: one that IS the replacement copy is
  # dropped (moving the task back undoes that hop), and the current copy joins
  # them unless the record already names it. A copy inside a pool slot this hop
  # releases is recorded as released_worktree= instead: history, not custody.
  RA_META_TMPS[m]=$(mktemp "$STATE/.$ID.meta.reassociate.XXXXXX") \
    || die "could not stage task $ID's record"
  meta_text=$(cat -- "$META" && printf .) \
    || die "could not read task $ID's record; nothing was changed"
  meta_text=${meta_text%.}
  (
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        worktree=*) printf 'worktree=%s\n' "$new_wt" || exit 1 ;;
        branch=*)
          if [ "$set_branch" = 1 ]; then
            printf 'branch=%s\n' "$new_branch" || exit 1
          else
            printf '%s\n' "$line" || exit 1
          fi
          ;;
        prior_worktree=*)
          prior=${line#prior_worktree=}
          prior_real=$(fm_task_copy_canonical_dir "$prior" 2>/dev/null) || prior_real=$prior
          if [ "$prior_real" = "$new_wt" ]; then
            continue
          fi
          for slot in ${left_slots[@]+"${left_slots[@]}"}; do
            case "$prior_real" in
              "$slot"|"$slot"/*)
                printf 'released_worktree=%s\n' "$prior" || exit 1
                continue 2
                ;;
            esac
          done
          priors_kept+=("$prior_real")
          printf '%s\n' "$line" || exit 1
          ;;
        *) printf '%s\n' "$line" || exit 1 ;;
      esac
    done < <(printf '%s' "$meta_text")
    if [ "$set_branch" = 1 ] && [ "$branch_count" = 0 ]; then
      printf 'branch=%s\n' "$new_branch" || exit 1
    fi
    line=${old_real:-$old_wt}
    if [ "$old_released" = 1 ]; then
      printf 'released_worktree=%s\n' "$old_wt" || exit 1
      line=
    fi
    for prior in ${priors_kept[@]+"${priors_kept[@]}"}; do
      [ "$prior" != "$line" ] || line=
    done
    [ -z "$line" ] || printf 'prior_worktree=%s\n' "$old_wt" || exit 1
  ) > "${RA_META_TMPS[m]}" || die "could not stage task $ID's record"
}

do_reassociate() {
  local m x slot stamp copy backup guard_keep
  local -a left_slots=()

  [ "$RELOCATE_SET" = 1 ] \
    || die "reassociate requires --worktree <replacement copy>"
  [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
    || die "reassociate requires --note (or --note-file) saying why the work moved; it is recorded in the task's instructions"

  # The command's task is record 0; each --also task follows it.
  RA_IDS=("$ID")
  RA_METAS=("$META")
  RA_REQUEST=("$RELOCATE_TO")
  for ((m=0; m<${#ALSO_IDS[@]}; m++)); do
    RA_IDS+=("${ALSO_IDS[$m]}")
    RA_METAS+=("$STATE/${ALSO_IDS[$m]}.meta")
    RA_REQUEST+=("${ALSO_COPIES[$m]}")
  done
  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    reassociate_select "$m"
    copy=$(fm_task_copy_canonical_dir "${RA_REQUEST[m]}") \
      || die "$([ "$m" = 0 ] && printf -- '--worktree ' || printf -- '--also %s=' "${RA_IDS[m]}")'${RA_REQUEST[m]}' is not an existing directory"
    RA_NEWWT[m]=$copy
  done

  # Each --also task is held exactly as the command's task is: the supervision
  # lease guard, then its lifecycle lock.
  for ((m=1; m<${#RA_IDS[@]}; m++)); do
    reassociate_select "$m"
    x=${RA_IDS[m]}
    [ -f "${RA_METAS[m]}" ] \
      || die "no task '$x' in $STATE (fm-control resolves an exact task id only)"
    guard_keep=$FM_LEASE_GUARD_LOCK
    FM_LEASE_GUARD_LOCK=
    fm_lease_guard "$x" "task copy reassociation (fm-control)"
    [ -z "$FM_LEASE_GUARD_LOCK" ] || RA_GUARD_LOCKS+=("$FM_LEASE_GUARD_LOCK")
    FM_LEASE_GUARD_LOCK=$guard_keep
    fm_lock_try_acquire "$STATE/.control-$x.lock" \
      || die "another lifecycle action is already running for task $x"
    RA_CONTROL_LOCKS+=("$STATE/.control-$x.lock")
  done

  # Read only what decides the lock set; everything is re-read under the locks.
  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    reassociate_select "$m"
    RA_PREWT[m]=$(fm_meta_get "${RA_METAS[m]}" worktree)
    RA_PREPROJECT[m]=$(fm_meta_get "${RA_METAS[m]}" project)
    [ "${RA_PREPROJECT[m]}" = "${RA_PREPROJECT[0]}" ] \
      || die "tasks ${RA_IDS[0]} and ${RA_IDS[m]} record different projects; one reassociation re-points tasks of a single project; nothing was changed"
  done
  reassociate_select 0
  CONTROL_PROJECT_LOCK=$(fm_treehouse_project_lock_path "${RA_PREPROJECT[0]}") \
    || die "cannot resolve the shared Treehouse project lock for ${RA_PREPROJECT[0]}; nothing was changed"
  fm_project_lock_try "$CONTROL_PROJECT_LOCK" "reassociate $ID" \
    || die "another task copy allocation, return, or reassociation is in progress for ${RA_PREPROJECT[0]}; refusing to race it, nothing was changed"
  CONTROL_PROJECT_LOCK_HELD=1
  CONTROL_META_LOCK=$(fm_meta_lock_path "$META") || exit 1
  fm_lock_acquire_wait "$CONTROL_META_LOCK"
  CONTROL_META_LOCK_HELD=1
  for ((m=1; m<${#RA_IDS[@]}; m++)); do
    x=$(fm_meta_lock_path "${RA_METAS[m]}") || exit 1
    fm_lock_acquire_wait "$x"
    RA_META_LOCKS+=("$x")
  done

  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    reassociate_check "$m"
  done
  if [ "${#RA_IDS[@]}" -gt 1 ]; then
    reassociate_group_check
  fi

  # Every copy of every record is checked before any anchor is written.
  for x in 0 1; do
    for ((m=0; m<${#RA_IDS[@]}; m++)); do
      reassociate_prove "$m" "$x"
    done
  done

  # Stage every write before publishing any of them.
  REASSOCIATE_ACTIVE=1
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    reassociate_stage "$m" "$stamp"
  done

  # Publish: the slot claims, then the instructions, then the records last, so
  # every earlier failure rolls back to the records that were there. Each
  # record is saved first, so a record that fails after another published
  # restores that one too. Every release comes before any claim, so a slot one
  # record leaves while another keeps it ends claimed by the one that keeps it.
  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    reassociate_select "$m"
    RA_META_BACKUPS[m]=$(mktemp "$STATE/.$ID.meta.prior.XXXXXX") \
      || die "could not preserve task $ID's record"
    cp -p -- "$META" "${RA_META_BACKUPS[m]}" \
      || die "could not preserve task $ID's record"
  done
  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    reassociate_select "$m"
    while IFS= read -r slot; do
      [ -z "$slot" ] || reassociate_publish_slot_claim "$slot" release
    done <<< "${RA_LEFT[m]}"
  done
  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    reassociate_select "$m"
    REASSOCIATE_CLAIMED=0
    while IFS= read -r slot; do
      [ -z "$slot" ] || reassociate_publish_slot_claim "$slot" claim
    done <<< "${RA_NEWSLOTS[m]}"
    # A slot another record of this call already claimed is kept, not claimed.
    if [ "${RA_SLOTRESULT[m]}" = claimed ] && [ "$REASSOCIATE_CLAIMED" = 0 ]; then
      RA_SLOTRESULT[m]=kept
    fi
  done
  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    reassociate_select "$m"
    RA_BRIEF_BACKUPS[m]=$(mktemp "$DATA/$ID/.brief.prior.XXXXXX") \
      || die "could not preserve task $ID's instructions"
    cp -p "${RA_BRIEFS[m]}" "${RA_BRIEF_BACKUPS[m]}" \
      || die "could not preserve task $ID's instructions"
    mv -f -- "${RA_BRIEF_TMPS[m]}" "${RA_BRIEFS[m]}" \
      || die "could not publish task $ID's instructions"
    RA_BRIEF_TMPS[m]=
    RA_BRIEF_PUBLISHED[m]=1
  done
  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    reassociate_select "$m"
    fm_backlog_atomic_transition publish "${RA_META_TMPS[m]}" "$META" "task record" "$STATE" \
      || die "$FM_BACKLOG_TRANSITION_ERROR"
    RA_META_TMPS[m]=
    RA_META_PUBLISHED[m]=1
  done
  # Committed: nothing below may roll a record back. A published record's
  # backup is spent, and its rollback flag is cleared so a late failure cannot
  # restore it.
  REASSOCIATE_ACTIVE=0
  for backup in ${REASSOCIATE_OWNER_BACKUPS[@]+"${REASSOCIATE_OWNER_BACKUPS[@]}"}; do
    [ -z "$backup" ] || rm -f -- "$backup"
  done
  REASSOCIATE_OWNER_PATHS=()
  REASSOCIATE_OWNER_BACKUPS=()
  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    rm -f -- "${RA_BRIEF_BACKUPS[m]}" "${RA_META_BACKUPS[m]}"
    RA_BRIEF_BACKUPS[m]=
    RA_META_BACKUPS[m]=
  done
  for ((m=0; m<${#RA_IDS[@]}; m++)); do
    left_slots=()
    while IFS= read -r slot; do
      [ -z "$slot" ] || left_slots+=("$slot")
    done <<< "${RA_LEFT[m]}"
    echo "reassociated ${RA_IDS[m]} worktree=${RA_NEWWT[m]}${RA_NEWBRANCH[m]:+ branch=${RA_NEWBRANCH[m]}} prior=${RA_OLDWT[m]}$([ "${RA_OLDSTATE[m]}" = present ] || printf ' prior_state=%s' "${RA_OLDSTATE[m]}") slot=${RA_SLOTRESULT[m]}${left_slots[*]+ released_slot=${left_slots[*]}}"
  done
}

if [ "$VERB" = reassociate ]; then
  [ -z "${FM_TASK_ID:-}" ] \
    || die "workers cannot reassociate a task record"
  fm_lease_forbid_branch "task copy reassociation (fm-control)"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$STATE" \
    || die "task copy reassociation requires the actual lock-owning main Firstmate"
  do_reassociate
  exit 0
fi
# A remotely placed secondmate records its endpoint on ANOTHER host, so every
# postcondition this plane verifies - the agent-state classification, the busy
# verdict, the endpoint's existence - would be read here for an endpoint that
# does not live here. Endpoint validation already refuses such a record, since
# `window=remote:<id>` can never match a local backend's required shape, so
# nothing can be delivered to a wrong endpoint either way. What that refusal
# cannot say is WHY, and "malformed metadata" is the wrong thing to tell an
# operator about a correctly configured remote route. Name the placement
# instead, using the same `remote_host` signal bin/fm-send.sh routes on.
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  die "task $ID is a remotely placed secondmate on $(fm_meta_get "$META" remote_host); its agent runs outside this home, so no lifecycle action here could verify that it interrupted, stopped, or came back. Drive its lifecycle on that host, and reconcile it through the secondmate recovery path rather than this plane"
fi

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
LABEL="fm-$ID"
RECORDED_HARNESS=$(fm_meta_get "$META" harness)
KIND=$(fm_meta_get "$META" kind)
WT=$(fm_meta_get "$META" worktree)
[ -n "$KIND" ] || KIND=ship

HARNESS=$(fm_control_harness_family "$RECORDED_HARNESS") \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"
fm_control_harness_supported "$HARNESS" \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"

fm_backend_validate "$BACKEND" || exit 1
# The adapter brings in the composer library whose dialog recogniser the picker
# answers read in this shell; a command substitution would drop it.
fm_backend_source "$BACKEND" || die "could not load the $BACKEND backend adapter"

if [ "$BACKEND" = herdr ]; then
  # shellcheck source=bin/fm-launch-proof-lib.sh
  . "$SCRIPT_DIR/fm-launch-proof-lib.sh"
  fm_backend_source herdr || die "could not load Herdr lifecycle control"
fi

# --- shared helpers ---------------------------------------------------------

agent_state() {
  fm_backend_agent_state "$BACKEND" "$T"
}

busy_verdict() {
  fm_busy_classify_meta "$META" "$ID" "$STATE"
}

require_live_task_attribution() {
  local state=${1:-} absence
  [ "$BACKEND" = herdr ] || return 0
  [ -n "$state" ] || state=$(agent_state)
  if [ "$state" = missing ]; then
    absence=$(fm_control_endpoint_absence_verdict "$BACKEND" "$T")
    state=${absence%%$'\t'*}
  fi
  case "$state" in
    dead|gone) return 0 ;;
    alive) ;;
    *) return 1 ;;
  esac
  fm_launch_proof_herdr_authorizes "$META"
}

# wait_agent_state <timeout> <wanted...>: poll until a wanted state is proven.
# Herdr's alive postcondition also requires the managed launch incarnation.
wait_agent_state() {  # <timeout> <wanted>...
  local timeout=$1 state want elapsed=0
  shift
  while :; do
    state=$(agent_state)
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        if [ "$want" = alive ] && [ "$BACKEND" = herdr ] \
          && ! fm_launch_proof_herdr_authorizes "$META"; then
          continue
        fi
        printf '%s' "$state"
        return 0
      fi
    done
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
  return 1
}

require_state_verified_backend() {  # <verb>
  fm_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

# refuse_blocking_prompt: the screen is a dialog a confirming Enter would
# answer. Name it and stop, typing nothing: every key either dismisses or
# chooses. The only answers are exit_picker_answerable's, under its own proof.
refuse_blocking_prompt() {  # <dialog-name> [why-it-was-left]
  die "task $ID is blocked on a prompt: $1. Refusing to type Enter into it.${2:+ $2}"
}

# exit_picker_visible: the visible viewport is, right now, exactly the
# recognised Claude background-task exit picker. An unreadable viewport is a
# no, so no key is ever sent on a screen that was not read.
exit_picker_visible() {
  local screen name
  screen=$(fm_backend_visible_capture "$BACKEND" "$T" "$LABEL" 2>/dev/null) || return 1
  name=$(fm_composer_blocking_dialog "$screen") || return 1
  [ "$name" = "$FM_COMPOSER_DIALOG_CLAUDE_EXIT_PICKER" ]
}

# wait_exit_picker_closed <timeout>: poll until a READABLE, nonempty viewport no
# longer shows the picker. An unreadable or blank read is not proof it closed.
wait_exit_picker_closed() {  # <timeout>
  local elapsed=0 step screen name
  step=$(awk -v p="$POLL" 'BEGIN{printf "%s", (p < 0.1 ? p : 0.1)}')
  while :; do
    if screen=$(fm_backend_visible_capture "$BACKEND" "$T" "$LABEL" 2>/dev/null) \
       && [ -n "$screen" ]; then
      name=$(fm_composer_blocking_dialog "$screen") || name=
      [ "$name" = "$FM_COMPOSER_DIALOG_CLAUDE_EXIT_PICKER" ] || return 0
    fi
    awk -v e="$elapsed" -v t="$1" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$step"
    elapsed=$(awk -v e="$elapsed" -v p="$step" 'BEGIN{printf "%.3f", e + p}')
  done
}

# control_exit_gen: the busy generation state/<id>.control-exit binds to, or -
# when none is armed. The marker writer and the marker clearer share it, so
# both name the same incarnation.
control_exit_gen() {
  local gen
  gen=$(cat "$(fm_busy_gen_path "$STATE" "$ID")" 2>/dev/null || true)
  printf '%s' "${gen:--}"
}

# clear_cancelled_exit_marker: the exit picker was closed with Stay, so the exit
# whose /exit opened it is cancelled and its deliberate-exit marker is stale. It
# is removed only when it names the current busy generation: a marker from
# another incarnation is not this exit's to clear.
clear_cancelled_exit_marker() {
  local marker=$STATE/$ID.control-exit marker_gen
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  marker_gen=$(sed -n 's/^gen=//p' "$marker" | head -1)
  [ "$marker_gen" = "$(control_exit_gen)" ] || return 0
  rm -f -- "$marker" \
    || die "task $ID's exit picker was closed, but its deliberate-exit marker $marker could not be removed"
}

# dismiss_exit_picker: choose Stay on the recognised picker with one key, then
# prove the picker closed and the agent is still alive. Sends nothing, and dies,
# unless the recognised picker is the visible screen: the same key could answer
# another dialog, and any answer to an unrecognised one can write a decline.
# Closing the picker cancels the exit that opened it, so a deliberate-exit
# marker that exit left behind is cleared here for every caller.
dismiss_exit_picker() {
  local key
  key=$(fm_control_exit_picker_stay_key "$HARNESS") || key=
  [ -n "$key" ] \
    || die "task $ID runs $HARNESS, which has no recognised exit picker; nothing was sent"
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "task $ID's $BACKEND backend cannot deliver $key; nothing was sent"
  exit_picker_visible \
    || die "task $ID does not show the recognised Claude background-task exit picker; nothing was sent, because the same key could answer a different dialog"
  fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
    || die "the $key that closes the exit picker was not delivered to task $ID"
  wait_exit_picker_closed "$SETTLE_WAIT" \
    || die "task $ID still shows the exit picker after one $key; nothing else was sent"
  [ "$(agent_state)" = alive ] \
    || die "task $ID's agent is not alive after the exit picker closed; closing it must not stop the agent, so inspect the endpoint before any other action"
  clear_cancelled_exit_marker
}

# exit_picker_answerable <dialog-name> <pre-exit-busy-verdict>: 0 only when
# exit may answer this dialog. It must be the recognised picker, on an exit
# (relaunch answers nothing), for a claude ship or scout whose OWN state is a
# terminal done, with a busy record that read idle before this exit sent
# anything and no unread steering in its inbox, which a parked picker leaves
# unhandled and stopping the task would leave unread. Any other busy verdict,
# unknown included, refuses: unknown is never promoted to idle. The busy
# verdict is passed in rather than re-read, so a hook that records the /exit
# line itself as a turn cannot make a finished task read as active. Sets
# EXIT_PICKER_WHY to the reason when it returns 1.
EXIT_PICKER_WHY=
exit_picker_answerable() {
  local dialog=$1 busy=$2 line rc=0 state unread
  EXIT_PICKER_WHY=
  if [ "$dialog" != "$FM_COMPOSER_DIALOG_CLAUDE_EXIT_PICKER" ]; then
    EXIT_PICKER_WHY="it is not a dialog exit knows how to answer"
    return 1
  fi
  if [ "$VERB" != exit ]; then
    EXIT_PICKER_WHY="$VERB never answers it"
    return 1
  fi
  if [ -z "$(fm_control_exit_picker_confirm_key "$HARNESS" 2>/dev/null)" ]; then
    EXIT_PICKER_WHY="the $HARNESS adapter has no answer for it"
    return 1
  fi
  case "$KIND" in
    ship|scout) ;;
    *)
      EXIT_PICKER_WHY="a $KIND is never finished"
      return 1
      ;;
  esac
  line=$(fm_run_timed "$CREW_STATE_WAIT" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_CREW_STATE_NO_FORGE=1 "$CREW_STATE_BIN" "$ID" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$line" ]; then
    EXIT_PICKER_WHY="its current state could not be read"
    return 1
  fi
  state=${line#state: }
  state=${state%% *}
  case "$line" in
    'state: done '*) ;;
    *)
      EXIT_PICKER_WHY="its current state is $state, not done"
      return 1
      ;;
  esac
  case "$busy" in
    idle|idle\ *) ;;
    *)
      EXIT_PICKER_WHY="its busy record reads '$busy', not idle"
      return 1
      ;;
  esac
  if unread=$(fm_task_inbox_oldest_unhandled "$STATE" "$ID"); then
    EXIT_PICKER_WHY="its steering inbox still holds unread steering (${unread##*/}) that stopping it would leave unread"
    return 1
  fi
  return 0
}

# read_exit_composer_after_picker: read the composer again once the picker is
# closed, until it reads empty or the settle wait ends, since Claude repaints it
# a moment later. Sets EXIT_COMPOSER_STATE to the last verdict. A dialog on the
# screen at any read refuses: the picker came back, or another dialog is up.
EXIT_COMPOSER_STATE=unknown
read_exit_composer_after_picker() {
  local elapsed=0
  while :; do
    : > "$FM_COMPOSER_DIALOG_SINK" \
      || die "task $ID's dialog check could not be recorded"
    EXIT_COMPOSER_STATE=$(fm_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null) \
      || EXIT_COMPOSER_STATE=unknown
    if [ -s "$FM_COMPOSER_DIALOG_SINK" ]; then
      refuse_blocking_prompt "$(cat "$FM_COMPOSER_DIALOG_SINK")" \
        "The exit picker had just been closed, so nothing more was sent."
    fi
    [ "$EXIT_COMPOSER_STATE" != empty ] || return 0
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || return 0
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
}

# refuse_exit_picker <dialog-name>: refuse a dialog exit_picker_answerable said
# no to, naming why and the supported way to close it.
refuse_exit_picker() {  # <dialog-name>
  refuse_blocking_prompt "$1" "It was left as it was because ${EXIT_PICKER_WHY:-it is not answerable}. Run 'fm-control $ID stay' to close it and keep the agent running."
}

# confirm_exit_picker <dialog-name> <pre-exit-busy-verdict>: the picker opened
# AFTER this exit proved the composer empty and typed /exit, so the only input
# it holds is that command. Choose its selected row, "Exit and stop tasks", when
# exit_picker_answerable says the task is finished; otherwise refuse. The
# endpoint must read positively alive, and on Herdr stay attributed to this
# task, at the key: both callers reach here after time has passed. The screen is
# read again immediately before the key so a changed screen gets nothing.
confirm_exit_picker() {
  local dialog=$1 busy=$2 key state
  exit_picker_answerable "$dialog" "$busy" || refuse_exit_picker "$dialog"
  key=$(fm_control_exit_picker_confirm_key "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "task $ID's $BACKEND backend cannot deliver $key; the exit picker was left as it was"
  state=$(agent_state)
  [ "$state" = alive ] \
    || refuse_blocking_prompt "$dialog" "It was left as it was because the endpoint reads '$state' rather than a positively classified live agent."
  require_live_task_attribution alive \
    || refuse_blocking_prompt "$dialog" "It was left as it was because the live agent cannot be positively attributed to this task."
  if ! exit_picker_visible; then
    EXIT_PICKER_WHY="the screen changed before the key could be sent"
    refuse_exit_picker "$dialog"
  fi
  fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
    || die "the $key that confirms the exit picker was not delivered to task $ID"
  printf 'note: task %s finished, so exit chose "Exit and stop tasks" on the background-task exit picker\n' "$ID" >&2
}

# rendered_matches <ere>: whether any row of the visible viewport matches.
# An unreadable viewport is a no, so every caller treats it as missing proof.
rendered_matches() {  # <ere>
  local screen
  screen=$(fm_backend_visible_capture "$BACKEND" "$T" "$LABEL" 2>/dev/null) || return 1
  printf '%s\n' "$screen" | grep -Eq -- "$1"
}

# wait_rendered <ere> <timeout>: poll the viewport until a row matches.
wait_rendered() {  # <ere> <timeout>
  local elapsed=0 step
  step=$(awk -v p="$POLL" 'BEGIN{printf "%s", (p < 0.1 ? p : 0.1)}')
  while :; do
    rendered_matches "$1" && return 0
    awk -v e="$elapsed" -v t="$2" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$step"
    elapsed=$(awk -v e="$elapsed" -v p="$step" 'BEGIN{printf "%.3f", e + p}')
  done
}

# dismiss_interrupt_hazard <key> <ere>: after the presses, close a surface a
# mistimed press opened (Devin's revert picker) with one more key, before
# anything else can be typed into it. Sets INTERRUPT_HAZARD.
dismiss_interrupt_hazard() {  # <key> <ere>
  local key=$1 hazard=$2 gap
  gap=$(fm_control_interrupt_press_gap "$HARNESS")
  sleep "$gap"
  rendered_matches "$hazard" || return 0
  fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
    || die "task $ID shows the $HARNESS revert picker after its interrupt, and the $key that closes it was not delivered; nothing else was typed. Close it with $key, never Enter, before any other action"
  sleep "$gap"
  ! rendered_matches "$hazard" \
    || die "task $ID still shows the $HARNESS revert picker after one $key; nothing else was typed. Close it with $key, never Enter, before any other action"
  INTERRUPT_HAZARD=dismissed
}

# send_interrupt_keys: deliver the harness's interrupt key the verified number
# of times, then the composer-clear key when the adapter needs one. Refuses
# before sending anything when the backend cannot deliver either key, because
# an interrupt that cancels the turn but leaves the restored prompt in the
# composer would make the next submitted line concatenate onto it. An adapter
# with an arm signal (fm_control_interrupt_arm_signal) gets each later press
# only after the viewport proves the first one armed a running turn, and never
# sooner than its press gap; without that proof INTERRUPT_ARMED=no and no
# further press is sent. Its hazard surface is then closed before returning.
send_interrupt_keys() {
  local key repeat clear arm hazard gap i=0
  key=$(fm_control_interrupt_key "$HARNESS")
  repeat=$(fm_control_interrupt_repeat "$HARNESS")
  clear=$(fm_control_interrupt_clear_key "$HARNESS")
  arm=$(fm_control_interrupt_arm_signal "$HARNESS")
  hazard=$(fm_control_interrupt_hazard_signal "$HARNESS")
  gap=$(fm_control_interrupt_press_gap "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  [ -z "$clear" ] || fm_control_backend_supports_key "$BACKEND" "$clear" \
    || die "harness $HARNESS needs $clear to clear its composer after an interrupt, which the $BACKEND backend cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it"
  [ -z "$arm$hazard" ] || fm_backend_visible_capture_supported "$BACKEND" \
    || die "harness $HARNESS must see its screen between interrupt presses, because a repeated $key on an idle agent opens its revert picker, and the $BACKEND backend has no verified viewport read; refusing to press blind"
  INTERRUPT_ARMED=yes
  INTERRUPT_HAZARD=none
  while [ "$i" -lt "$repeat" ]; do
    fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
      || die "interrupt key $key was not delivered to task $ID on $BACKEND"
    i=$((i + 1))
    [ "$i" -lt "$repeat" ] || break
    sleep "$gap"
    if [ -n "$arm" ] && ! wait_rendered "$arm" "$ARM_WAIT"; then
      INTERRUPT_ARMED=no
      break
    fi
  done
  [ -z "$hazard" ] || dismiss_interrupt_hazard "$key" "$hazard"
  [ -z "$clear" ] || fm_backend_send_key "$BACKEND" "$T" "$clear" "$LABEL" \
    || die "interrupt key $key reached task $ID, but $clear did not, so its composer still holds the cancelled prompt; clear it before the next lifecycle action"
}

prepare_interrupt_ack() {
  INTERRUPT_ACK_SOURCE=$(fm_control_interrupt_ack_source "$HARNESS")
  INTERRUPT_ACK_LOG=
  INTERRUPT_ACK_RUN=
  case "$INTERRUPT_ACK_SOURCE" in
    muse-session-terminal)
      INTERRUPT_ACK_LOG=$(fm_busy_muse_session_log "$STATE" "$ID" 2>/dev/null || true)
      [ -n "$INTERRUPT_ACK_LOG" ] || return 0
      INTERRUPT_ACK_RUN=$(fm_busy_muse_active_run_id "$INTERRUPT_ACK_LOG" 2>/dev/null || true)
      ;;
  esac
}

interrupt_cancel_claim() {
  local elapsed=0 terminal=
  case "$INTERRUPT_ACK_SOURCE:$INTERRUPT_ACK_RUN" in
    muse-session-terminal:?*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  while :; do
    terminal=$(fm_busy_muse_run_terminal "$INTERRUPT_ACK_LOG" "$INTERRUPT_ACK_RUN" 2>/dev/null || true)
    case "$terminal" in
      cancelled) printf 'confirmed'; return 0 ;;
      ?*) printf 'unconfirmed'; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# deliver_interrupt: deliver and observe the strongest adapter-owned
# cancellation claim available after delivery. `not-running` means an armed
# adapter's first press rendered no running turn, so nothing was cancelled; a
# dismissed revert picker is reported beside the claim.
deliver_interrupt() {
  local cancel devin_gen=
  # Devin does not emit Stop for cancellation. Capture this incarnation before
  # keys, then invalidate its state conservatively rather than claiming idle.
  if [ "$HARNESS" = devin ]; then
    devin_gen=$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null || true)
  fi
  prepare_interrupt_ack
  send_interrupt_keys
  if [ "$INTERRUPT_ARMED" = no ]; then
    cancel=not-running
  else
    cancel=$(interrupt_cancel_claim)
    if [ "$HARNESS" = devin ] && [ -n "$devin_gen" ]; then
      "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" unknown \
        --gen "$devin_gen" --source fm-interrupt --event interrupt >/dev/null 2>&1 || true
    fi
  fi
  [ "$INTERRUPT_HAZARD" = none ] || cancel="$cancel revert-picker=$INTERRUPT_HAZARD"
  printf '%s' "$cancel"
}

verify_interrupt_running() {
  local proof after
  fm_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint presence could not be verified after interrupting it; no further control action is safe"
  proof=endpoint
  if fm_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof=agent-alive
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  require_live_task_attribution alive \
    || die "task $ID cannot positively attribute its live Herdr agent to this task; refusing lifecycle input"
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

# Drop busy_gen from the task record when it still names <gen>.
# fm-busy-event.sh owns the sidecar and the record; fm_backlog_atomic_transition
# publish owns the task record. Clearing the line inside the busy writer would
# take the task-record lock that teardown and spawn already hold; the busy
# writer is their child process, so it would wait on a live holder that is
# itself waiting on the child, and neither would ever proceed.
clear_retired_meta_busy_gen() {  # <gen>
  local gen=$1 meta="$STATE/$ID.meta" lock tmp current line
  [ -n "$gen" ] || return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  if ! declare -F fm_backlog_atomic_transition >/dev/null 2>&1; then
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  fi
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  current=$(fm_meta_get "$meta" busy_gen)
  if [ "$current" != "$gen" ]; then
    fm_lock_release "$lock"
    return 0
  fi
  tmp=$(mktemp "$STATE/.$ID.meta.retire.XXXXXX") || {
    fm_lock_release "$lock"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      busy_gen=*) ;;
      *)
        printf '%s\n' "$line" >> "$tmp" || {
          rm -f "$tmp"
          fm_lock_release "$lock"
          return 1
        }
        ;;
    esac
  done < "$meta" || {
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  }
  if ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

retire_busy_incarnation() {
  local gen=
  if [ -f "$STATE/$ID.busy-gen" ]; then
    gen=$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null || true)
    if [ -n "$gen" ] \
      && "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --gen "$gen" >/dev/null 2>&1; then
      clear_retired_meta_busy_gen "$gen" || true
    fi
  fi
}

# do_exit: stop the running agent, preserving endpoint and worktree. Prints
# `already-stopped`, `endpoint-gone`, or `stopped`.
do_exit() {
  local state cmd hazard verdict composer_state cancel absence interrupt_result=not-needed dialog pre_busy
  require_state_verified_backend exit
  state=$(agent_state)
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    missing)
      # `missing` on its own is not a finding about the endpoint: it conflates
      # "destroyed" with "unreachable from this seat". Route it through the
      # control plane's one absence proof - the same one the relaunch gate uses
      # - and report what that proof actually established, never more.
      absence=$(fm_control_endpoint_absence_verdict "$BACKEND" "$T" "$WT")
      case "${absence%%$'\t'*}" in
        gone)
          # Proven gone, so the agent that lived in it went with it: exit's
          # postcondition already holds and there is nothing to send. Its own
          # outcome rather than `already-stopped`, because the endpoint this
          # verb normally preserves did not survive. The worktree and every
          # uncommitted change are untouched, and `relaunch` re-creates the
          # endpoint from here.
          printf 'endpoint-gone'
          return 0
          ;;
        dead)
          # The endpoint was only unreachable and is there after all, holding
          # no agent - a herdr pane whose session server was merely stopped is
          # the common case. Nothing is gone, so this is the ordinary
          # already-stopped outcome.
          printf 'already-stopped'
          return 0
          ;;
        alive)
          # The agent came back with its endpoint. Fall through to the ordinary
          # alive path: interrupt if busy, then the harness's exit command.
          ;;
        *)
          die "task $ID's endpoint $T reads 'missing', but ${absence#*$'\t'}; exit will not claim an agent stopped at an address it cannot trust, nor send lifecycle input to one"
          ;;
      esac
      ;;
    *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint" ;;
  esac
  require_live_task_attribution alive \
    || die "task $ID cannot positively attribute its live Herdr agent to this task; refusing lifecycle input"
  # A busy agent is interrupted first before the exit command is submitted.
  # The verdict is kept: exit_picker_answerable reads it, and it must be the one
  # taken before anything was sent.
  pre_busy=$(busy_verdict)
  case "$pre_busy" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          retire_busy_incarnation
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  cmd=$(fm_control_exit_command "$HARNESS")
  hazard=$(fm_control_interrupt_hazard_signal "$HARNESS")
  if [ -n "$hazard" ] && rendered_matches "$hazard"; then
    die "task $ID shows the $HARNESS revert picker, where typed text becomes a search and Enter reverts file changes; refusing to type the $cmd exit command. Close it with $(fm_control_interrupt_key "$HARNESS"), never Enter, then retry '$VERB'"
  fi
  : > "$FM_COMPOSER_DIALOG_SINK" \
    || die "task $ID's dialog check could not be recorded"
  composer_state=$(fm_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null) \
    || composer_state=unknown
  # The classify that filled the sink ran in a subshell, so read the file
  # rather than a function that subshell sourced.
  if [ -s "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
    dialog=$(cat "$FM_COMPOSER_DIALOG_SINK")
    # A picker already open hides the composer, and the picker's own rows read
    # as pending text, so nothing here proves the composer empty. A finished
    # task gets the picker closed with Stay and the composer read again, so
    # text it was hiding still refuses; any other task keeps the refusal.
    EXIT_PICKER_WHY=
    exit_picker_answerable "$dialog" "$pre_busy" || refuse_exit_picker "$dialog"
    dismiss_exit_picker
    printf 'note: task %s finished and was parked on the background-task exit picker; exit closed it with Stay and read the composer again\n' "$ID" >&2
    read_exit_composer_after_picker
    composer_state=$EXIT_COMPOSER_STATE
  fi
  case "$composer_state" in
    empty) ;;
    pending)
      die "task $ID's composer visibly holds pending text; refusing to type the $cmd exit command because it would concatenate onto that text. Clear or submit the pending text, then retry '$VERB'"
      ;;
    *)
      die "task $ID's composer state is '$composer_state', not proven empty; refusing to type the $cmd exit command because it could concatenate onto existing text. Clear the composer, then retry '$VERB'"
      ;;
  esac
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Known non-delivery (send-failed), including
  # a refused pre-Enter proof, aborts; otherwise the authoritative proof is the
  # agent-state wait below. The retried Enter still
  # matters, because a slash command opens a completion popup on some TUIs that
  # swallows the first Enter.
  # A deliberate exit verb records the busy generation before anything is typed.
  # A completed exit retires the busy record anyway; the marker keeps a later
  # SessionEnd deliberate when the agent outlives the exit wait and this
  # transaction dies before that retire. Relaunch calls this function too and
  # must not mark its own replacement stop as a deliberate exit.
  if [ "$VERB" = exit ]; then
    printf 'gen=%s\n' "$(control_exit_gen)" > "$STATE/$ID.control-exit" \
      || die "could not record that this exit of $ID was deliberate; nothing was typed"
  fi
  verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL") \
    || verdict=send-failed
  if [ "$verdict" = send-failed ]; then
    [ "$VERB" != exit ] || rm -f -- "$STATE/$ID.control-exit"
    die "the exit command could not be sent to task $ID on $BACKEND"
  fi
  # The submitting Enter can open the picker. The agent is still alive, and
  # another Enter would confirm the selected row. A dead agent may leave the
  # same text behind; that is not a prompt still waiting. The composer was
  # proven empty above and /exit is the only thing typed since, so a finished
  # task's picker is answered here and every other task's is refused.
  if [ -s "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
    dialog=$(cat "$FM_COMPOSER_DIALOG_SINK")
    if [ "$(agent_state)" != dead ]; then
      confirm_exit_picker "$dialog" "$pre_busy"
    fi
  fi
  state=$(wait_agent_state "$EXIT_WAIT" dead) || {
    # A submit can return before any read sees the picker: a native busy
    # verdict needs no composer read, and a cleared composer can be read
    # before the picker renders. Read the screen once more here.
    : > "$FM_COMPOSER_DIALOG_SINK" || true
    fm_backend_composer_state "$BACKEND" "$T" "$LABEL" >/dev/null 2>&1 || true
    if [ -s "$FM_COMPOSER_DIALOG_SINK" ]; then
      confirm_exit_picker "$(cat "$FM_COMPOSER_DIALOG_SINK")" "$pre_busy"
      state=$(wait_agent_state "$EXIT_WAIT" dead) \
        || die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered picker=exit-and-stop-tasks agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s of the picker's confirming key"
    else
      die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
    fi
  }
  # The incarnation is over: retire its busy wiring so no stale record or
  # orphaned generation survives the agent that produced it.
  retire_busy_incarnation
  printf 'stopped'
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# relaunch_rollback (an EXIT trap, so a refusal raised deep inside a shared
# helper is covered too) and leaves either the pre-relaunch durable record or a
# concrete, named partial state - never a task whose record claims an agent
# that is not running.

JOURNAL="$STATE/$ID.control-relaunch"
META_PRIOR="$JOURNAL.meta-prior"
BRIEF_PRIOR="$JOURNAL.brief-prior"
NOTE_FILE="$JOURNAL.note"
RELAUNCH_META_PUBLISHED=0
RELAUNCH_AGENT_CONFIRMED=0
RELOCATING=0
RELOCATE_FROM=
RELOCATE_DEST=
RELOCATE_HEAD=
RELOCATE_HEAD_SOURCE=
PRIOR_RELOCATE_FROM=
PRIOR_RELOCATE_TO=
PRIOR_RELOCATE_HEAD=
PRIOR_RELOCATE_HEAD_SOURCE=
if [ "$VERB" = relaunch ] && { [ -e "$JOURNAL" ] || [ -L "$JOURNAL" ]; }; then
  if [ ! -f "$JOURNAL" ] || [ -L "$JOURNAL" ] || ! cat "$JOURNAL" >/dev/null 2>&1; then
    die "control journal $JOURNAL cannot be read; refusing to overwrite recorded recovery evidence"
  fi
  if [ "$(fm_meta_get "$JOURNAL" task)" = "$ID" ]; then
    PRIOR_RELOCATE_FROM=$(fm_meta_get "$JOURNAL" relocation_from)
    PRIOR_RELOCATE_TO=$(fm_meta_get "$JOURNAL" relocation_to)
    PRIOR_RELOCATE_HEAD=$(fm_meta_get "$JOURNAL" relocation_head)
    PRIOR_RELOCATE_HEAD_SOURCE=$(fm_meta_get "$JOURNAL" relocation_head_source)
  fi
fi
RELAUNCH_TX=
RELAUNCH_BRIEF=
PRIOR_HARNESS=$HARNESS
PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
CONFIG_HARNESS=
CONFIG_MODEL=
CONFIG_EFFORT=
PRIOR_MODEL=
PRIOR_EFFORT=
TARGET_HARNESS=$HARNESS
TARGET_MODEL=
TARGET_EFFORT=
TARGET_DISPATCH_RULE=
TARGET_DISPATCH_ROUTE=
TARGET_DISPATCH_SWITCHED=false

journal_write() {  # <phase> [extra-line]...
  local phase=$1
  shift
  if {
    echo "v1"
    echo "task=$ID"
    echo "phase=$phase"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "backend=$BACKEND"
    echo "endpoint=$T"
    echo "worktree=$WT"
    echo "kind=$KIND"
    echo "from_harness=$PRIOR_RECORDED_HARNESS"
    echo "from_model=$PRIOR_MODEL"
    echo "from_effort=$PRIOR_EFFORT"
    echo "to_harness=$TARGET_HARNESS"
    echo "to_model=$TARGET_MODEL"
    echo "to_effort=$TARGET_EFFORT"
    # The relocation proof rides every rewrite, the failure journals included:
    # it is written here rather than passed by each caller, so no phase can
    # forget it. A later identical relocation is judged against it
    # (fm_control_worktree_relocation reads relocation_head back).
    if [ "$RELOCATING" = 1 ]; then
      echo "relocation_from=$RELOCATE_FROM"
      echo "relocation_to=$RELOCATE_DEST"
      echo "relocation_head=$RELOCATE_HEAD"
      echo "relocation_head_source=$RELOCATE_HEAD_SOURCE"
    else
      [ -z "$PRIOR_RELOCATE_FROM" ] || echo "relocation_from=$PRIOR_RELOCATE_FROM"
      [ -z "$PRIOR_RELOCATE_TO" ] || echo "relocation_to=$PRIOR_RELOCATE_TO"
      [ -z "$PRIOR_RELOCATE_HEAD" ] || echo "relocation_head=$PRIOR_RELOCATE_HEAD"
      [ -z "$PRIOR_RELOCATE_HEAD_SOURCE" ] || echo "relocation_head_source=$PRIOR_RELOCATE_HEAD_SOURCE"
    fi
    local line
    for line in "${CHECKPOINT_LINES[@]}" "$@"; do
      echo "$line"
    done
  } > "$JOURNAL.tmp" && mv -f "$JOURNAL.tmp" "$JOURNAL"; then
    RELAUNCH_PHASE=$phase
    return 0
  fi
  return 1
}

# Where the task's work is preserved: the recorded copy, or the fresh one a
# relocation is moving it to (the recorded copy is gone by definition).
work_location() {
  if [ "$RELOCATING" = 1 ]; then
    printf '%s' "$RELOCATE_DEST"
  else
    printf '%s' "$WT"
  fi
}

relaunch_rollback() {
  local state
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  [ "$RELAUNCH_PHASE" != complete ] || return 0
  RELAUNCH_ACTIVE=0
  case "$RELAUNCH_PHASE" in
    checkpoint|noted)
      # The old agent was never touched. Restore the instructions byte-exact so
      # a refused relaunch leaves nothing behind.
      if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
        cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
      fi
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      echo "error: relaunch of $ID was refused before its agent was touched; nothing changed" >&2
      ;;
    stopping)
      state=$(agent_state 2>/dev/null || printf unknown)
      case "$state" in
        alive)
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-alive" || true
          echo "error: relaunch of $ID failed while stopping the old agent, which is still running; its original instructions were restored" >&2
          ;;
        dead)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-dead" || true
          echo "error: $ID's agent stopped but relaunch did not reach replacement launch; no agent is running, and its work plus progress note are preserved at $(work_location)" >&2
          ;;
        *)
          # The old agent was NOT proven stopped, so no replacement is coming
          # and the agent that may still be reading these instructions is the
          # original one. The note exists to brief a replacement; leaving it in
          # a possibly-live agent's brief would be an unrequested edit to a
          # running task. Restore byte-exact, exactly as the alive case does.
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-state-$state" || true
          echo "error: relaunch of $ID failed while stopping the old agent and its state is '$state', so it was not proven stopped; its original instructions were restored and the durable record was retained for recovery" >&2
          ;;
      esac
      ;;
    exited|launching)
      if [ "$RELAUNCH_AGENT_CONFIRMED" = 1 ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-agent-confirmed" || true
        echo "error: $ID's replacement is running on $TARGET_HARNESS, but transaction completion could not be persisted; its published record was retained for reconciliation" >&2
      elif [ "$RELAUNCH_META_PUBLISHED" = 1 ] \
         || { [ -n "$RELAUNCH_TX" ] \
              && [ "$(fm_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; }; then
        # The launch owner published the new incarnation's record. Leaving it
        # in place is the honest state: the task is now recorded on the new
        # harness with no agent confirmed, which is exactly what recovery
        # reconciles. Rewriting it back to the old harness would be a second,
        # worse inaccuracy.
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-record-kept" || true
        echo "error: $ID was relaunched on $TARGET_HARNESS but no running agent could be confirmed; its work is preserved at $(work_location)" >&2
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept" || true
        echo "error: $ID's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at $(work_location)" >&2
      fi
      ;;
  esac
  return 0
}

relaunch_pair_stage() {
  [ -z "$RELAUNCH_PAIR_DIR" ] || return 0
  RELAUNCH_PAIR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-pair.XXXXXX") || return 1
  FM_INHERITABLE_CONFIG='model-index.json crew-dispatch.json' \
    fm_config_inherit_pair_stage "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$RELAUNCH_PAIR_DIR"
}

resolve_relaunch_profile() {
  PRIOR_HARNESS=$HARNESS
  PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
  PRIOR_MODEL=$(fm_meta_get "$META" model)
  PRIOR_EFFORT=$(fm_meta_get "$META" effort)
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
  [ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
  TARGET_API_KEY_ALLOW=0
  [ "$(fm_meta_get "$META" api_key)" = allow ] && TARGET_API_KEY_ALLOW=1
  if [ "$HARNESS_SET" = 0 ] \
     && [ "$PRIOR_RECORDED_HARNESS" != "$PRIOR_HARNESS" ]; then
    die "task $ID records harness '$PRIOR_RECORDED_HARNESS', whose original launch command cannot be reconstructed from its recorded basename; relaunching without --harness would substitute the canonical adapter '$PRIOR_HARNESS' for the command actually running. Pass an explicit --harness to choose the replacement runtime deliberately"
  fi
  CONFIG_HARNESS=
  CONFIG_MODEL=
  CONFIG_EFFORT=
  if [ "$KIND" = secondmate ]; then
    # A secondmate's harness, model, and effort are a durable configured pin
    # that every respawn re-resolves (the secondmate-provisioning contract), so
    # a relaunch with no explicit harness picks up a newly configured one
    # instead of freezing whatever this incarnation happens to run. Crewmates
    # and scouts deliberately do NOT resolve config here: their harness comes
    # from firstmate's own dispatch-profile judgment at intake, and silently
    # re-resolving it would bypass that consultation.
    CONFIG_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    CONFIG_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    CONFIG_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "$CONFIG_EFFORT" in
      ''|low|medium|high|xhigh|max|ultra) ;;
      *)
        echo "warning: config/secondmate-harness effort token '$CONFIG_EFFORT' is not one of low, medium, high, xhigh, max, ultra; ignoring" >&2
        CONFIG_EFFORT=
        ;;
    esac
  fi
  if [ "$HARNESS_SET" = 1 ]; then
    fm_control_harness_supported "$NEW_HARNESS" \
      || die "'$NEW_HARNESS' is not a verified harness; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$NEW_HARNESS
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    fm_control_harness_supported "$CONFIG_HARNESS" \
      || die "the configured secondmate harness '$CONFIG_HARNESS' is not verified; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$CONFIG_HARNESS
  else
    TARGET_HARNESS=$PRIOR_HARNESS
  fi
  fm_session_launch_policy_check "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$TARGET_HARNESS" || return 1
  # The launch owner refuses an adapter that cannot run this task's kind, but it
  # is only reached after the old agent has been stopped. Asking the same
  # capability table here keeps that refusal on the pre-stop side of the
  # transaction, where nothing has changed yet.
  fm_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
    || die "'$TARGET_HARNESS' is not verified to run a $KIND task, so relaunching $ID onto it would stop the running agent for a launch that must be refused; choose an adapter verified for this kind"
  if [ "$TARGET_HARNESS" = omp ]; then
    fm_control_omp_launch_check || return 1
  fi
  if [ "$TARGET_HARNESS" = dsh ]; then
    fm_dsh_launch_check '' "$KIND" || return 1
  fi
  # A model or effort chosen for the previous harness does not transfer to a
  # different one, so an explicit harness change resets both axes unless the
  # caller names them too.
  local dsh_prior_kept=0 dsh_model
  if [ "$MODEL_SET" = 1 ]; then
    TARGET_MODEL=$NEW_MODEL
    if [ "$TARGET_HARNESS" = dsh ] && [ "$PRIOR_HARNESS" = dsh ] && [ "$NEW_MODEL" != default ]; then
      relaunch_pair_stage || return 1
      dsh_model=$(FM_CONFIG_OVERRIDE="$RELAUNCH_PAIR_DIR" "$SCRIPT_DIR/fm-model-index.sh" model dsh "$NEW_MODEL") || return 1
      dsh_model=$(python3 "$SCRIPT_DIR/fm-dsh.py" canonical "$dsh_model") || return 1
      if [ "$dsh_model" = "$PRIOR_MODEL" ]; then
        dsh_prior_kept=1
      fi
    fi
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_MODEL=${CONFIG_MODEL:-default}
    if [ "$TARGET_HARNESS" = dsh ] && [ "$PRIOR_HARNESS" = dsh ] && [ "$PRIOR_MODEL" != default ] \
       && { [ "$TARGET_MODEL" = default ] || [ "$EFFORT_SET" = 0 ]; }; then
      dsh_model=$PRIOR_MODEL
      if [ "$TARGET_MODEL" != default ]; then
        relaunch_pair_stage || return 1
        dsh_model=$(FM_CONFIG_OVERRIDE="$RELAUNCH_PAIR_DIR" "$SCRIPT_DIR/fm-model-index.sh" model dsh "$TARGET_MODEL") || return 1
        dsh_model=$(python3 "$SCRIPT_DIR/fm-dsh.py" canonical "$dsh_model") || return 1
      fi
      if [ "$EFFORT_SET" = 0 ] && { [ "$dsh_model" != "$PRIOR_MODEL" ] \
         || [ "${CONFIG_EFFORT:-$PRIOR_EFFORT}" != "$PRIOR_EFFORT" ]; }; then
        die "task $ID's bound dsh conversation runs model $PRIOR_MODEL at effort $PRIOR_EFFORT, but config/secondmate-harness names model ${CONFIG_MODEL:-(none)} at effort ${CONFIG_EFFORT:-(none)}; a plain relaunch would discard that conversation. Pass an explicit --model and --effort to start a fresh conversation on the configured profile. The running agent was not stopped"
      fi
      TARGET_MODEL=$PRIOR_MODEL
      dsh_prior_kept=1
    elif [ "$TARGET_HARNESS" = dsh ] && [ "$TARGET_MODEL" = default ]; then
      TARGET_MODEL=$(python3 "$SCRIPT_DIR/fm-dsh.py" own-model) \
        || die "the dsh harness from config/secondmate-harness or this firstmate's own DSH session has no configured model, and no live DSH session record supplied one; pass --model deepseek/<id> or add a model token to config/secondmate-harness. The running agent was not stopped"
    fi
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_MODEL=$PRIOR_MODEL
  else
    TARGET_MODEL=default
  fi
  if [ "$EFFORT_SET" = 1 ]; then
    TARGET_EFFORT=$NEW_EFFORT
  elif [ "$dsh_prior_kept" = 1 ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_EFFORT=${CONFIG_EFFORT:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
  else
    TARGET_EFFORT=default
  fi
  # A role reference, or a model the index has since retired, is resolved or
  # refused here, before the stop, exactly as the launch owner would.
  if [ "$TARGET_MODEL" != default ] || [ "$KIND" != secondmate ]; then
    relaunch_pair_stage || return 1
    if [ "$TARGET_MODEL" != default ]; then
      TARGET_MODEL=$(FM_CONFIG_OVERRIDE="$RELAUNCH_PAIR_DIR" \
        "$SCRIPT_DIR/fm-model-index.sh" model "$TARGET_HARNESS" "$TARGET_MODEL") || return 1
    fi
  fi
  if [ "$TARGET_HARNESS" = omp ]; then
    fm_omp_api_billing_route_check "$TARGET_MODEL" || return 1
  fi
  if [ "$KIND" != secondmate ]; then
    local dispatch_set dispatch_profile dispatch_result config_dir dispatch_verdict
    local dispatch_recorded dispatch_rules_to_check dispatch_check_rule
    local dispatch_requested_match dispatch_authorizing dispatch_hard_projects dispatch_authorized
    local dispatch_rules_file
    config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
    TARGET_DISPATCH_RULE=$(fm_meta_get "$META" dispatch_rule)
    TARGET_DISPATCH_ROUTE=$(fm_meta_get "$META" dispatch_route)
    if [ "$HARNESS_SET" = 1 ] || [ "$MODEL_SET" = 1 ] || [ "$EFFORT_SET" = 1 ]; then
      TARGET_DISPATCH_RULE=
      TARGET_DISPATCH_ROUTE=
    fi
    dispatch_recorded=$TARGET_DISPATCH_RULE
    dispatch_set=$(fm_dispatch_fallbacks "$RELAUNCH_PAIR_DIR" "$TARGET_DISPATCH_RULE" \
      "$TARGET_HARNESS" "$TARGET_MODEL" "$TARGET_EFFORT") || return 1
    TARGET_DISPATCH_RULE=$(jq -r .rule <<<"$dispatch_set")
    dispatch_rules_file="${RELAUNCH_PAIR_DIR:-${FM_CONFIG_OVERRIDE:-$FM_HOME/config}}/crew-dispatch.json"
    dispatch_requested_match=$(jq -r '.requested_rule_match | if . == null then "none" else tostring end' <<<"$dispatch_set")
    dispatch_authorizing=$(jq -c '.authorizing_rules // []' <<<"$dispatch_set")
    dispatch_hard_projects=0
    fm_dispatch_projects_configured "$dispatch_rules_file" && dispatch_hard_projects=1
    # A recorded rule that does not authorize the recorded profile must refuse
    # under hard projects rather than letting another rule's fallback list
    # stand in for it.
    if [ "$dispatch_hard_projects" -eq 1 ] && [ -n "$dispatch_recorded" ] &&
       [ "$dispatch_requested_match" = false ]; then
      die "$ID cannot relaunch: recorded dispatch rule $dispatch_recorded does not authorize the recorded profile $TARGET_HARNESS:${TARGET_MODEL:-default}:${TARGET_EFFORT:-default} under hard project eligibility; refusing to infer another rule (docs/configuration.md \"Crew dispatch profiles\")"
    fi
    # The recorded rule and any rule inferred from the recorded profile must
    # both still be eligible for THIS project before the old agent is stopped
    # or a stand-in is chosen, so a config edit after the launch cannot silently
    # widen the captain's restriction on recovery. An identity that no longer
    # resolves refuses: its restriction cannot be verified.
    dispatch_rules_to_check=$dispatch_recorded
    if [ -n "$TARGET_DISPATCH_RULE" ] && [ "$TARGET_DISPATCH_RULE" != "$dispatch_recorded" ]; then
      dispatch_rules_to_check="${dispatch_rules_to_check}${dispatch_rules_to_check:+$'\n'}$TARGET_DISPATCH_RULE"
    fi
    while IFS= read -r dispatch_check_rule; do
      [ -n "$dispatch_check_rule" ] || continue
      dispatch_verdict=0
      fm_dispatch_rule_project_verdict "$DATA" "$dispatch_rules_file" \
        "$dispatch_check_rule" "$(basename "$(fm_meta_get "$META" project)")" || dispatch_verdict=$?
      case "$dispatch_verdict" in
        0) ;;
        *) die "$ID cannot relaunch: $FM_DISPATCH_ELIGIBILITY_ERROR; refusing to replace the running agent for an incompatible or unverifiable dispatch rule (docs/configuration.md \"Crew dispatch profiles\")" ;;
      esac
    done <<<"$dispatch_rules_to_check"
    # Without a recorded identity, the recorded profile must be authorized by
    # at least one rule this project allows; an empty authorizing set is a
    # manual profile outside the rule matrix.
    if [ "$dispatch_hard_projects" -eq 1 ] && [ -z "$dispatch_recorded" ] &&
       [ "$(jq 'length' <<<"$dispatch_authorizing")" -gt 0 ]; then
      dispatch_authorized=0
      while IFS= read -r dispatch_check_rule; do
        [ -n "$dispatch_check_rule" ] || continue
        dispatch_verdict=0
        fm_dispatch_rule_project_verdict "$DATA" "$dispatch_rules_file" \
          "$dispatch_check_rule" "$(basename "$(fm_meta_get "$META" project)")" || dispatch_verdict=$?
        case "$dispatch_verdict" in
          0) dispatch_authorized=1 ;;
          1) ;;
          *) die "$ID cannot relaunch: $FM_DISPATCH_ELIGIBILITY_ERROR; refusing to replace the running agent for an unauthorized profile (docs/configuration.md \"Crew dispatch profiles\")" ;;
        esac
      done < <(jq -r '.[]' <<<"$dispatch_authorizing")
      if [ "$dispatch_authorized" -ne 1 ]; then
        die "$ID cannot relaunch: the recorded profile $TARGET_HARNESS:${TARGET_MODEL:-default}:${TARGET_EFFORT:-default} is not authorized by any dispatch rule eligible for project $(basename "$(fm_meta_get "$META" project)"); refusing to infer around the hard project restriction (docs/configuration.md \"Crew dispatch profiles\")"
      fi
    fi
    if [ "$TARGET_HARNESS" = omp ] && [[ "$TARGET_MODEL" == openai-codex/* ]] \
       || [ "$(jq -c .fallback <<<"$dispatch_set")" != '[]' ]; then
      dispatch_profile=$(jq -cn --arg h "$TARGET_HARNESS" --arg m "$TARGET_MODEL" \
        --arg e "$TARGET_EFFORT" '{harness:$h,model:$m,effort:$e}')
      dispatch_result=$(fm_dispatch_select "$config_dir" "$TARGET_DISPATCH_RULE" \
        "$dispatch_profile" "$(jq -c .fallback <<<"$dispatch_set")" "" "$RELAUNCH_PAIR_DIR" "$TARGET_DISPATCH_ROUTE") || return 1
      TARGET_DISPATCH_SWITCHED=$(jq -r .switched <<<"$dispatch_result")
      TARGET_HARNESS=$(jq -r .profile.harness <<<"$dispatch_result")
      TARGET_MODEL=$(jq -r .profile.model <<<"$dispatch_result")
      TARGET_EFFORT=$(jq -r .profile.effort <<<"$dispatch_result")
    fi
  fi
  if [ "$TARGET_DISPATCH_SWITCHED" = true ]; then
    TARGET_MODEL=$(FM_CONFIG_OVERRIDE="$RELAUNCH_PAIR_DIR" \
      "$SCRIPT_DIR/fm-model-index.sh" model "$TARGET_HARNESS" "$TARGET_MODEL") || return 1
    fm_session_launch_policy_check "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$TARGET_HARNESS" || return 1
    fm_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
      || die "'$TARGET_HARNESS' is not verified to run a $KIND task"
  fi
  if [ "$TARGET_HARNESS" = omp ]; then
    fm_omp_api_billing_route_check "$TARGET_MODEL" || return 1
  fi
  local dsh_route_model=$TARGET_MODEL
  [ "$dsh_route_model" != default ] || dsh_route_model=
  python3 "$SCRIPT_DIR/fm-dsh.py" check "$TARGET_HARNESS" "$dsh_route_model" || return 1
  if [ "$TARGET_HARNESS" = dsh ]; then
    dsh_model=$(python3 "$SCRIPT_DIR/fm-dsh.py" canonical "$TARGET_MODEL") || return 1
    if [ "$dsh_model" != "$TARGET_MODEL" ]; then
      relaunch_pair_stage || return 1
      dsh_model=$(FM_CONFIG_OVERRIDE="$RELAUNCH_PAIR_DIR" "$SCRIPT_DIR/fm-model-index.sh" model dsh "$dsh_model") || return 1
    fi
    TARGET_MODEL=$dsh_model
  fi
  case "$(fm_meta_get "$META" omp_no_helpers)" in
    '') ;;
    on)
      [ "$TARGET_HARNESS" = omp ] \
        || die "task $ID records omp_no_helpers=on, which only omp can honor; relaunching it onto '$TARGET_HARNESS' would stop the running agent for a launch that must be refused"
      ;;
    *) die "task $ID records an invalid omp_no_helpers posture; refusing to stop the running agent for a launch that must be refused" ;;
  esac
  if [ "$TARGET_EFFORT" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$TARGET_HARNESS" "$TARGET_MODEL" "$TARGET_EFFORT" || return 1
  fi
  # The launch owner applies this home's worker account pin too, but only after
  # the old agent has been stopped, so a pin that no longer resolves or is
  # signed out must refuse here, while nothing has changed yet.
  local account_model=$TARGET_MODEL config=${FM_CONFIG_OVERRIDE:-$FM_HOME/config} launcher=claude catalog_context=selected
  [ "$account_model" != default ] || account_model=
  TARGET_WORKER_ACCOUNT=$(fm_worker_account_select "$TARGET_HARNESS" "$config" \
    "$account_model" "$TARGET_HARNESS") || return 1
  # The same holds for config/claude-launcher: a malformed file or a stopped
  # TeamClaude proxy must refuse before the old agent stops.
  if [ "$TARGET_HARNESS" = claude ]; then
    launcher=$(fm_claude_launcher_select "$config") || return 1
    [ "$launcher" = claude ] || catalog_context=unavailable
  fi
  if [ -n "$account_model" ] && { [ -e "$RELAUNCH_PAIR_DIR/model-index.json" ] || [ -L "$RELAUNCH_PAIR_DIR/model-index.json" ]; }; then
    FM_CONFIG_OVERRIDE="$RELAUNCH_PAIR_DIR" fm_worker_account_check_entry "$TARGET_WORKER_ACCOUNT" \
      "$SCRIPT_DIR/fm-model-index.sh" "$TARGET_HARNESS" "$account_model" "$catalog_context" || return 1
  fi
  # Likewise config/crew-exclude-tools: a malformed file, or a replacement
  # runtime that cannot hide the listed tools, refuses here, before the old
  # agent stops. Secondmate agents are not covered.
  if [ "$KIND" != secondmate ]; then
    fm_exclude_tools_check "$TARGET_HARNESS" 0 "$config" >/dev/null || return 1
  fi
  # The launch owner's model freshness gate refuses a replacement model that a
  # newer model of its own family and tier has passed, but only after the old
  # agent has stopped. The same verdict is asked here, under the same worker
  # account, so that refusal happens while nothing has changed yet. The model the
  # task already records was admitted at launch, a captain pin naming the model
  # admits it, and a newer model of another tier only warns.
  if [ "$catalog_context" = selected ] && [ -n "$account_model" ] \
     && [ "$TARGET_MODEL" != "$PRIOR_MODEL" ] && [ "$CAPTAIN_MODEL_PIN" != "$TARGET_MODEL" ]; then
    local stale
    stale=$(fm_worker_account_check_entry "$TARGET_WORKER_ACCOUNT" "$SCRIPT_DIR/fm-model-freshness.sh" \
      "$TARGET_HARNESS" "$TARGET_MODEL" 2>/dev/null </dev/null | sed -n 's/^MODEL_FRESHNESS: //p' | head -n 1) || stale=
    case "$stale" in
      ''|*' (other tier: '*')') ;;
      *)
        [ -z "$CAPTAIN_MODEL_PIN" ] \
          || echo "error: --captain-model-pin '$CAPTAIN_MODEL_PIN' is not the requested model '$TARGET_MODEL'; a pin authorizes only that exact model" >&2
        die "refusing to relaunch $ID onto a stale model - $stale; the running agent was not stopped (relaunch onto the newer model, or pass --captain-model-pin $TARGET_MODEL only when the captain explicitly asked for $TARGET_MODEL)"
        ;;
    esac
  fi
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty children marker child_meta check_wt
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to relaunch without a recorded local copy to preserve"
  if [ "$RELOCATE_SET" = 1 ]; then
    # The recorded copy is gone, so there is nothing at $WT to account for. The
    # proof runs BEFORE the journal or anything else is written; the checkpoint
    # below then accounts for the fresh copy the replacement will start from.
    fm_control_worktree_relocation "$META" "$ID" "$STATE" "$RELOCATE_TO" || exit 1
    RELOCATING=1
    RELOCATE_FROM=$FM_CONTROL_RELOCATION_FROM
    RELOCATE_DEST=$FM_CONTROL_RELOCATION_PATH
    RELOCATE_HEAD=$FM_CONTROL_RELOCATION_HEAD
    RELOCATE_HEAD_SOURCE=$FM_CONTROL_RELOCATION_HEAD_SOURCE
    check_wt=$RELOCATE_DEST
  else
    check_wt=$WT
  fi
  [ -d "$check_wt" ] || die "task $ID's recorded worktree $WT is missing; refusing to relaunch and lose track of its work (a fresh copy of the same branch can replace it: pass --worktree <path>)"
  wt_real=$(cd "$check_wt" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $check_wt cannot be resolved"
  wt_top=$(git -C "$check_wt" rev-parse --show-toplevel 2>/dev/null) \
    || die "task $ID's recorded worktree $check_wt is not a git worktree; refusing to relaunch without a checkout whose unlanded work can be accounted for"
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top_real=$wt_top
  [ "$wt_real" = "$wt_top_real" ] \
    || die "task $ID's recorded worktree $check_wt is not a worktree root (root is $wt_top); refusing to relaunch against an ambiguous checkout"
  if head=$(git -C "$check_wt" rev-parse --verify HEAD 2>/dev/null); then
    :
  elif head_ref=$(git -C "$check_wt" symbolic-ref -q HEAD 2>/dev/null); then
    if git -C "$check_wt" show-ref --verify --quiet "$head_ref" 2>/dev/null; then
      die "task $ID's worktree HEAD exists but cannot be resolved; refusing to relaunch from an unreadable checkout"
    else
      head_ref_status=$?
      [ "$head_ref_status" -eq 1 ] \
        || die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
      head=unborn
    fi
  else
    die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
  fi
  status_output=$(git -C "$check_wt" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected; refusing to relaunch without accounting for local changes"
  if [ -n "$status_output" ]; then
    dirty=yes
  else
    dirty=no
  fi
  CHECKPOINT_LINES+=("worktree_head=$head" "worktree_dirty=$dirty")
  if [ "$KIND" = secondmate ]; then
    # A secondmate's own crewmates outlive its relaunch: they run in their own
    # endpoints, and the relaunched secondmate reconciles them from its home's
    # durable records at startup. The checkpoint proves those records are
    # readable BEFORE the agent stops, so a relaunch can never strand child
    # work behind an unreadable home.
    marker=$(cat "$WT/.fm-secondmate-home" 2>/dev/null || true)
    [ "$marker" = "$ID" ] \
      || die "task $ID's home $WT is not marked as its own seeded secondmate home (marker: ${marker:-none}); refusing to relaunch"
    # Do not walk state/ with find(1): watcher scratch files can vanish
    # mid-scan and make find fail even when every child *.meta is readable.
    [ -d "$WT/state" ] && [ -r "$WT/state" ] && [ -x "$WT/state" ] \
      || die "secondmate $ID's home has no readable state directory, so its child work cannot be accounted for; refusing to relaunch"
    children=0
    for child_meta in "$WT/state"/*.meta; do
      if [ ! -e "$child_meta" ] && [ ! -L "$child_meta" ]; then
        continue
      fi
      if [ ! -f "$child_meta" ] || [ -L "$child_meta" ] \
         || ! cat "$child_meta" >/dev/null 2>&1; then
        die "secondmate $ID's child record $child_meta is not a readable regular file; refusing to relaunch"
      fi
      children=$((children + 1))
    done
    CHECKPOINT_LINES+=("children=$children")
  fi
}

# record_note: put the required progress note somewhere durable, and - for a
# ship or scout, whose only record of the interrupted reasoning is the
# conversation about to be discarded - into the instructions the replacement
# actually reads. A secondmate's charter is a durable standing document and is
# never rewritten: a secondmate reconciles its own home's records at startup,
# so the note stays parent-side audit evidence.
record_note() {
  local stamp
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      {
        echo
        echo "## Progress note ($stamp)"
        echo
        if [ "$RECONCILE_ONLY" = 1 ]; then
          echo "This task was relaunched for instruction reconciliation only, not continuation."
        elif [ "$RELOCATING" = 1 ]; then
          echo "This task was relaunched in $RELOCATE_DEST because its recorded local copy"
          echo "($RELOCATE_FROM) was proven absent. The new copy is a fresh checkout of the same branch"
          echo "and contains every surviving recorded head ($RELOCATE_HEAD_SOURCE), proven at $RELOCATE_HEAD."
          echo "Uncommitted changes in the vanished copy are not recoverable; check the branch"
          echo "and the status log for what is missing before continuing."
        else
          echo "This task was relaunched. Continue from here; the local copy and every"
          echo "uncommitted change are exactly as the previous worker left them."
        fi
        echo
        echo "First, handle the surviving instruction records individually announced"
        echo "by this launch, in numeric order, then mv each handled file into"
        echo "$STATE/$ID.inbox/handled/. Wait for unannounced records' own doorbells."
        echo
        printf '%s\n' "$NOTE"
      } >> "$RELAUNCH_BRIEF" \
        || die "could not append the progress note to task $ID's instructions"
      ;;
  esac
}

do_relaunch() {
  local exit_result state note_line secondmate_home
  local -a spawn_args

  require_state_verified_backend relaunch
  if [ "$RECOVER_LAUNCH" = 1 ]; then
    [ "$BACKEND" = herdr ] || die "--recover-launch is supported only for recorded Herdr endpoints"
    state=$(agent_state)
    case "$state" in
      dead|missing) echo "recovery-skipped $ID agent=$state"; return 0 ;;
      alive) ;;
      *) die "launch recovery for $ID cannot attribute its endpoint (agent=$state)" ;;
    esac
    state=$(fm_launch_proof_herdr "$META")
    case "$state" in
      managed) echo "recovery-skipped $ID launch=managed"; return 0 ;;
      unmanaged)
        if [ -z "$(fm_meta_get "$META" launch_proof)" ]; then
          echo "recovery-skipped $ID launch=legacy record; exit and relaunch are allowed"
          return 0
        fi
        echo "recovery-skipped $ID launch=unmanaged; no lifecycle action taken"
        return 0
        ;;
      unknown)
        if [ -z "$(fm_meta_get "$META" launch_proof)" ]; then
          echo "recovery-skipped $ID launch=legacy-unproven"
          return 0
        fi
        die "launch recovery for $ID cannot prove its live launch settings; no lifecycle action taken"
        ;;
      *) die "invalid launch proof for $ID: $state" ;;
    esac
  fi
  resolve_relaunch_profile
  if [ "$CLAUDE_DEBUG" = 1 ] && [ "$TARGET_HARNESS" != claude ]; then
    die "--claude-debug applies only to a claude relaunch; $ID would be replaced on $TARGET_HARNESS"
  fi

  case "$KIND" in
    ship|scout)
      RELAUNCH_BRIEF="$DATA/$ID/brief.md"
      [ -f "$RELAUNCH_BRIEF" ] \
        || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to relaunch a worker with nothing to work from"
      [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
        || die "relaunch of a $KIND task requires --note (or --note-file): the replacement worker inherits the local copy but none of the conversation, so it must be told what happened"
      ;;
    secondmate)
      # The charter in the secondmate's own home is its instruction source and
      # stays untouched.
      RELAUNCH_BRIEF=
      ;;
    *)
      die "task $ID records kind '$KIND', which has no defined relaunch shape"
      ;;
  esac

  if [ -n "$NOTE" ]; then
    note_line="note_file=$NOTE_FILE"
  else
    note_line="note=none"
  fi
  # A replacement is not continuation consent. Inherit the recorded recovery
  # restriction even when an automatic caller uses ordinary relaunch syntax.
  if [ "$(fm_meta_get "$META" recovery)" = reconcile-only ]; then
    RECONCILE_ONLY=1
  fi
  # Share the launch owner's admission rule before lifecycle input can stop a
  # live owner. An explicit reconciliation recovery may only restore an exited
  # owner, never interrupt a live one or turn a hold into dispatch permission.
  fm_backlog_relaunch_admission "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$DATA" "$KIND" "$ID" "$RECONCILE_ONLY" \
    || die "$FM_BACKLOG_TRANSITION_ERROR"
  [ ! -e "$STATE/$ID.backlog-close" ] && [ ! -L "$STATE/$ID.backlog-close" ] \
    || die "task $ID has a pending authoritative backlog close; finish or repair it before relaunch"
  if [ "$RECONCILE_ONLY" = 1 ]; then
    state=$(agent_state)
    case "$state" in
      dead) ;;
      missing)
        state=$(fm_control_endpoint_absence_verdict "$BACKEND" "$T" "$WT")
        case "${state%%$'\t'*}" in
          dead|gone) ;;
          *) die "reconciliation-only recovery requires a proven exited owner (endpoint reads $state)" ;;
        esac
        ;;
      *) die "reconciliation-only recovery requires a proven exited owner (endpoint reads $state)" ;;
    esac
  fi
  # Admission refusals above name the task's own state; only then does an
  # unattributable live Herdr agent stop an ordinary relaunch, still before any
  # checkpoint or lifecycle input.
  require_live_task_attribution \
    || die "task $ID cannot positively attribute its live Herdr agent to this task; refusing relaunch before checkpoint or lifecycle input"
  safe_checkpoint
  if [ "$KIND" = secondmate ]; then
    secondmate_home=$(fm_meta_get "$META" home)
    [ -n "$secondmate_home" ] || secondmate_home=$WT
    fm_session_launch_policy_converge_child "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$secondmate_home" "$ID" "$TARGET_HARNESS" || return 1
  fi
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before relaunching"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "$note_line"

  record_note
  journal_write noted "$note_line"

  # Refuse before stopping the current worker, using the replacement harness,
  # account pin, allowlist, and backend that fm-spawn will use.
  fm_api_key_guard_launch_env_config "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" \
    || die "could not inspect the replacement launch environment before stopping $ID"
  fm_api_key_guard "$TARGET_HARNESS" "$TARGET_API_KEY_ALLOW" "$TARGET_WORKER_ACCOUNT" \
    "$FM_API_KEY_LAUNCH_ENV_ENABLED" "$FM_API_KEY_LAUNCH_ENV_NAMES" "$BACKEND" \
    || die "refused before stopping $ID: an Anthropic credential would reach the replacement worker"
  journal_write stopping "$note_line"
  exit_result=$(do_exit)
  journal_write exited "$note_line" "exit_result=$exit_result"

  # The launch owner (fm-spawn --relaunch) clears the previous incarnation's
  # per-task harness wiring before arming the new one, so nothing to do here.
  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write launching "$note_line" "relaunch_tx=$RELAUNCH_TX"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  [ "$RECONCILE_ONLY" = 0 ] || spawn_args+=(--reconcile-only)
  [ "$CLAUDE_DEBUG" = 0 ] || spawn_args+=(--claude-debug)
  [ "$RELOCATING" = 0 ] || spawn_args+=(--worktree "$RELOCATE_DEST")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$CAPTAIN_MODEL_PIN_SET" = 0 ] || spawn_args+=(--captain-model-pin "$CAPTAIN_MODEL_PIN")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  [ -z "$TARGET_DISPATCH_RULE" ] || spawn_args+=(--dispatch-rule "$TARGET_DISPATCH_RULE")
  [ -z "$TARGET_DISPATCH_ROUTE" ] || spawn_args+=(--dispatch-route "$TARGET_DISPATCH_ROUTE")
  if [ "$TARGET_API_KEY_ALLOW" = 1 ]; then
    spawn_args+=(--allow-api-key)
  fi
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      FM_CONFIG_INHERIT_PAIR_DIR="${RELAUNCH_PAIR_DIR:-${FM_CONFIG_INHERIT_PAIR_DIR:-}}" \
      "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
    # $T was resolved from the record before the launch. When the recorded
    # endpoint was gone, the launch owner created a fresh one and republished
    # the record pointing at it, so every postcondition below must be read from
    # the endpoint the task now HAS, not the one it had. Re-resolving through
    # the same shared validation is what makes that safe: a record that no
    # longer passes it refuses here rather than leaving this transaction
    # polling an address nothing owns.
    # stdout is dropped (it is only the resolved target), but the refusal on
    # stderr names the exact row that failed - and in this one branch the record
    # was just rewritten by the launch owner, so that row is the whole
    # diagnostic. Let it through rather than dying with nothing to act on.
    if fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null \
       && [ -n "$FM_BACKEND_VALIDATED_TARGET" ]; then
      T=$FM_BACKEND_VALIDATED_TARGET
      BACKEND=$FM_BACKEND_VALIDATED_BACKEND
      WT=$(fm_meta_get "$META" worktree)
      if [ "$BACKEND" = herdr ] && ! declare -F fm_launch_proof_herdr >/dev/null 2>&1; then
        # shellcheck source=bin/fm-launch-proof-lib.sh
        . "$SCRIPT_DIR/fm-launch-proof-lib.sh"
        fm_backend_source herdr || die "could not load Herdr lifecycle control"
      fi
    else
      die "the replacement agent for $ID was launched, but task $ID's republished record no longer passes endpoint validation (the refusal above names the row), so this transaction cannot say which endpoint to confirm it on; reconcile $META before any further control action"
    fi
  else
    if [ "$(fm_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; then
      RELAUNCH_META_PUBLISHED=1
      WT=$(fm_meta_get "$META" worktree)
    fi
    die "the replacement agent for $ID could not be launched on $TARGET_HARNESS"
  fi

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    if [ "$BACKEND" = herdr ] && [ "$state" = alive ]; then
      die "the replacement agent for $ID is running but its managed launch incarnation could not be proven within ${LAUNCH_WAIT}s"
    fi
    die "the replacement agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  journal_write complete "$note_line" "exit_result=$exit_result"
  RELAUNCH_ACTIVE=0
  if [ "$TARGET_DISPATCH_SWITCHED" = true ]; then
    printf 'working [at=%s]: model-matrix fallback relaunched %s %s for %s\n' "$(date +%s)" "$TARGET_HARNESS" "$TARGET_MODEL" "${TARGET_DISPATCH_RULE:-matching profiles}" >> "$STATE/$ID.status"
  fi
  echo "relaunched $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
}

# --- verbs ------------------------------------------------------------------

case "$VERB" in
  interrupt)
    state=$(agent_state)
    case "$state" in
      alive) ;;
      unverified)
        # No recovery-grade classifier on this backend. Interrupt is
        # non-destructive and its endpoint-existence postcondition is still
        # real, so it proceeds - the printed proof names exactly what was
        # verified rather than implying more.
        ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is nothing to interrupt" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint" ;;
    esac
    proof=$(do_interrupt)
    echo "interrupt-delivered $ID harness=$HARNESS backend=$BACKEND verified=$proof"
    ;;
  exit)
    result=$(do_exit)
    echo "$result $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    ;;
  stay)
    # Close the recognised exit picker and leave the agent running. The picker
    # is read from the viewport, so the backend must have a viewport read and
    # the recovery-grade classifier that proves the agent is still alive.
    require_state_verified_backend stay
    state=$(agent_state)
    case "$state" in
      alive) ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is no exit picker to close" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a key into an unattributed endpoint" ;;
    esac
    require_live_task_attribution alive \
      || die "task $ID cannot positively attribute its live Herdr agent to this task; refusing lifecycle input"
    dismiss_exit_picker
    echo "stayed $ID harness=$HARNESS backend=$BACKEND endpoint=$T verified=picker-closed agent=alive"
    ;;
  relaunch)
    do_relaunch
    ;;
esac
