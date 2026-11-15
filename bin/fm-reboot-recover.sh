#!/usr/bin/env bash
# Inspect this home's recorded Herdr agents after native bare restoration.
# Usage: FM_HOME=<home> fm-reboot-recover.sh [recover] [--one]
# Native restores without a matching live Firstmate spawn pin are unmanaged.
# The sweep reports them without lifecycle input or task-record mutation.
# No namespace discovery, child-home traversal, config change, endpoint removal,
# branch operation, or worktree allocation occurs.
# Remote secondmates and other backends keep their existing recovery owners.
# Missing/stopped agents remain with their existing liveness recovery paths.
# Herdr's session-wide auto-resume setting is deliberately not changed.
# Unknown versioned launch proof is reported as unreadable. A claude whose
# readable environment carries no launch pin is reported as an unpinned native
# restore, which nothing can authorize, and keeps the nonzero status.
# A claude whose readable environment carries a pin for another launch generation
# is reported as pinned elsewhere and keeps the nonzero status.
# A legacy record (no launch_proof)
# keeps exit and relaunch: an unpinned legacy omp is reported as such, and other
# legacy-unproven records skip.
# Failed inspection is surfaced; an unbounded sweep continues inspecting records.
# --one stops after one selected local Herdr record, including inspection refusals.
# STATE/.reboot-recovery-cursor holds that id. It advances atomically before
# backend inspection, so the next tick follows it even if inspection is interrupted.
# Unbounded recover does not read or change that scheduling cursor.
# STATE/<id>.reboot-notice holds a task's last notice with its verdict and
# restored-agent identity (pane, PID and start time). --one stays quiet while
# both are unchanged; the record clears when no notice applies, and relaunch
# and teardown remove it. Unbounded recover always reports and does not read or
# change that notice state.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in
  recover) shift ;;
  ''|-*) ;;
  *) echo "error: unknown recovery command '$1'; use recover (--help for options)" >&2; exit 2 ;;
esac
ONE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --one) ONE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected recovery argument '$1'; valid options: --one, --help" >&2; exit 2 ;;
  esac
  shift
done
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || { echo 'error: FM_HOME must name an explicit home' >&2; exit 1; }
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
[ -d "$STATE" ] || exit 0
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-launch-proof-lib.sh
. "$SCRIPT_DIR/fm-launch-proof-lib.sh"
fm_backend_source herdr
result=0
# notice <id> <verdict-and-identity> <line>: 1 when --one suppressed it.
# forget <id>: a bounded tick clears the task's notice when none applies.
notice() {
  local file="$STATE/$1.reboot-notice" last='' tmp
  [ "$ONE" = 1 ] || { echo "$3"; return 0; }
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    IFS= read -r last < "$file" || true
    [ "$last" != "$2" ] || return 1
  fi
  echo "$3"
  tmp=$(umask 077; mktemp "$STATE/.reboot-notice.XXXXXX") || return 0
  if ! printf '%s\n' "$2" > "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
  fi
}
forget() {
  [ "$ONE" = 0 ] || rm -f -- "$STATE/$1.reboot-notice"
}
records=("$STATE"/*.meta)
count=${#records[@]}
[ "$count" -gt 0 ] || exit 0
start=0
cursor="$STATE/.reboot-recovery-cursor"
if [ "$ONE" = 1 ]; then
  if [ -e "$cursor" ] || [ -L "$cursor" ]; then
    [ -f "$cursor" ] && [ ! -L "$cursor" ] || {
      echo "error: recovery scheduling cursor is not a regular file: $cursor" >&2
      exit 1
    }
    last=''
    IFS= read -r last < "$cursor" || true
    for ((index=0; index<count; index++)); do
      if [ "${records[index]}" = "$STATE/$last.meta" ]; then
        start=$(( (index + 1) % count ))
        break
      fi
    done
  fi
fi
selected=0
for ((offset=0; offset<count && (ONE == 0 || selected == 0); offset++)); do
  index=$(( (start + offset) % count ))
  meta=${records[index]}
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  [ "$(fm_meta_get "$meta" backend)" = herdr ] || continue
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
  id=${meta##*/}; id=${id%.meta}
  case "$(fm_meta_get "$meta" kind)" in ship|scout|secondmate|'') ;; *) continue ;; esac
  selected=1
  if [ "$ONE" = 1 ]; then
    tmp=$(umask 077; mktemp "$STATE/.reboot-recovery-cursor.XXXXXX") || exit 1
    if ! printf '%s\n' "$id" > "$tmp" || ! mv -f -- "$tmp" "$cursor"; then
      rm -f -- "$tmp"
      echo "error: recovery scheduling cursor could not advance: $cursor" >&2
      exit 1
    fi
  fi
  if ! fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null; then
    result=1
    continue
  fi
  target=$FM_BACKEND_VALIDATED_TARGET
  case "$(fm_backend_agent_state herdr "$target")" in
    alive) ;;
    dead|missing) forget "$id"; continue ;;
    unreadable)
      notice "$id" "state-unreadable $target" \
        "REBOOT_RECOVERY: $id: agent state is unreadable; no lifecycle action taken" && result=1
      continue
      ;;
    *) result=1; continue ;;
  esac
  born=''
  # One record read decides the legacy branch, the attributed PID and the
  # verdict (Main 1807 (2)).
  judged=$(fm_launch_proof_recovery_judge "$meta" "$target")
  legacy=${judged%%$'\t'*}; judged=${judged#*$'\t'}
  pid=${judged%%$'\t'*}; judged=${judged#*$'\t'}
  proof=${judged%%$'\t'*}
  detail=${judged#*$'\t'}
  [ -z "$pid" ] || born=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}') || born=''
  identity="$target $pid $born"
  case "$proof" in
    managed) forget "$id"; continue ;;
    unknown)
      if [ "$legacy" = 1 ]; then
        forget "$id"
        continue
      fi
      notice "$id" "launch-unreadable $identity" \
        "REBOOT_RECOVERY: $id: $(fm_launch_proof_refusal_cause unknown "$detail"); no lifecycle action taken; $(fm_launch_proof_refusal_next unknown "$meta")" && result=1
      continue
      ;;
    unmanaged)
      if [ "$legacy" = 1 ]; then
        notice "$id" "legacy $identity" \
          "REBOOT_RECOVERY: $id: legacy record; exit and relaunch are allowed" || true
        continue
      fi
      if [ "$(fm_meta_get "$meta" harness)" = claude ]; then
        # An unpinned native restore keeps the nonzero status an unproven
        # versioned launch always had; only its wording follows the true cause.
        notice "$id" "unmanaged $identity" \
          "REBOOT_RECOVERY: $id: $(fm_launch_proof_refusal_cause unmanaged); no lifecycle action taken; $(fm_launch_proof_refusal_next unmanaged "$meta")" && result=1
        continue
      fi
      notice "$id" "unmanaged $identity" \
        "REBOOT_RECOVERY: $id: live launch is unmanaged; no lifecycle action taken" || true
      ;;
    pinned-elsewhere|contested)
      notice "$id" "$proof $identity" \
        "REBOOT_RECOVERY: $id: $(fm_launch_proof_refusal_cause "$proof" "$detail"); no lifecycle action taken; $(fm_launch_proof_refusal_next "$proof" "$meta")" && result=1
      continue
      ;;
    *) result=1 ;;
  esac
done
exit "$result"
