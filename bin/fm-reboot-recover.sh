#!/usr/bin/env bash
# Recover this home's recorded Herdr agents after native bare restoration.
# Usage: FM_HOME=<home> fm-reboot-recover.sh [check|recover] [--one]
# Default recover repairs each positively unmanaged live ship, scout, or local
# secondmate through fm-control relaunch --recover-launch, in its recorded pane
# and local copy. check is read-only and prints one launch verdict per live
# recorded Herdr agent. No namespace discovery, child-home traversal, config
# change, endpoint removal, branch operation, or worktree allocation occurs.
# Remote secondmates and other backends keep their existing recovery owners.
# Missing/stopped agents remain with their existing liveness recovery paths.
# Herdr's session-wide auto-resume setting is deliberately not changed: it
# applies to unrelated panes too. Exact recorded launch recovery supplies the
# settings its native resume drops. Unknown proof is reported, never acted on.
# Failed recovery is surfaced; an unbounded sweep continues inspecting records.
# --one stops after one repair attempt. Bounded recover scans rotate after the
# previous attempt, including a refusal, so pending input cannot starve others.
# STATE/.reboot-recovery-cursor holds the last attempted id. It advances
# atomically before repair, including when the caller times out during repair.
# check and unbounded recover do not read or change that scheduling cursor.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }
ACTION=recover
case "${1:-}" in
  check|recover) ACTION=$1; shift ;;
  ''|-*) ;;
  *) echo "error: unknown recovery command '$1'; use check or recover (--help for options)" >&2; exit 2 ;;
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
records=("$STATE"/*.meta)
count=${#records[@]}
[ "$count" -gt 0 ] || exit 0
start=0
cursor="$STATE/.reboot-recovery-cursor"
if [ "$ACTION" = recover ] && [ "$ONE" = 1 ]; then
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
for ((offset=0; offset<count; offset++)); do
  index=$(( (start + offset) % count ))
  meta=${records[index]}
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  [ "$(fm_meta_get "$meta" backend)" = herdr ] || continue
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
  id=${meta##*/}; id=${id%.meta}
  case "$(fm_meta_get "$meta" kind)" in ship|scout|secondmate|'') ;; *) continue ;; esac
  if ! fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null; then
    result=1
    continue
  fi
  target=$FM_BACKEND_VALIDATED_TARGET
  [ "$(fm_backend_agent_state herdr "$target")" = alive ] || continue
  proof=$(fm_launch_proof_herdr "$meta")
  if [ "$ACTION" = check ]; then
    printf '%s launch=%s\n' "$id" "$proof"
    continue
  fi
  case "$proof" in
    managed) continue ;;
    unknown)
      [ -n "$(fm_meta_get "$meta" launch_proof)" ] || continue
      echo "REBOOT_RECOVERY: $id: live launch settings are unreadable; no lifecycle action taken"
      result=1
      continue
      ;;
    unmanaged) ;;
    *) result=1; continue ;;
  esac
  if [ "$ONE" = 1 ]; then
    tmp=$(umask 077; mktemp "$STATE/.reboot-recovery-cursor.XXXXXX") || exit 1
    if ! printf '%s\n' "$id" > "$tmp" || ! mv -f -- "$tmp" "$cursor"; then
      rm -f -- "$tmp"
      echo "error: recovery scheduling cursor could not advance: $cursor" >&2
      exit 1
    fi
  fi
  # fm-control rechecks proof under its per-task lock and pins every recorded
  # profile axis itself, including secondmates whose current config changed.
  if out=$("$SCRIPT_DIR/fm-control.sh" "$id" relaunch --recover-launch 2>&1); then
    printf 'REBOOT_RECOVERY: %s: %s\n' "$id" "$out"
  else
    printf 'REBOOT_RECOVERY: %s: failed: %s\n' "$id" "$out"
    result=1
  fi
  [ "$ONE" != 1 ] || break
done
exit "$result"
