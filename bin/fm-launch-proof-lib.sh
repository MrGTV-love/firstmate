#!/usr/bin/env bash
# Proof that a recorded Herdr agent came through Firstmate's launch boundary.
# fm-spawn stamps FM_SPAWN_GEN with the record's spawn_gen and records
# launch_proof=env-v1. The live PID's pin must match that recorded incarnation.
# For omp, a matching pin also requires extension-recorded current-session proof.
# Native Herdr restore reconstructs argv, not the launch environment/settings.
# Verdicts: managed|unmanaged|unknown. Only managed authorizes lifecycle action.
# No endpoint discovery: callers supply this home's validated exact endpoint.

_FM_LAUNCH_PROOF_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-remote-herdr-owner-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-agent-process-lib.sh"

fm_launch_proof_pid() { # <pid> <spawn-gen> -> managed|unmanaged|unknown
  local pid=$1 gen=$2 environment
  case "$pid" in ''|*[!0-9]*) printf unknown; return ;; esac
  [ -n "$gen" ] || { printf unmanaged; return; }
  environment=$(fm_remote_herdr_process_env "$pid") || { printf unknown; return; }
  # A platform which hides process environments supplies neither signal.
  # Do not confuse that with a positively readable environment missing our pin.
  if ! printf '%s\n' "$environment" | grep -Eq '^(PATH|HOME)='; then
    printf unknown
  elif printf '%s\n' "$environment" | grep -Fx "FM_SPAWN_GEN=$gen" >/dev/null; then
    printf managed
  else
    printf unmanaged
  fi
}

fm_launch_proof_herdr() { # <meta> -> managed|unmanaged|unknown
  local meta=$1 target session pane info foreground pid proof gen verdict
  local candidates ids='' name argv0 parents group record task_file current_file
  target=$(fm_meta_get "$meta" window)
  session=${target%%:*}; pane=${target#*:}
  info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) \
    || { printf unknown; return; }
  # The process-group leader may be a launcher shell, and omp helpers share
  # the group. Attribute the unique ancestor-most non-shell process instead.
  candidates=$(printf '%s' "$info" | jq -ec --arg pane "$pane" '
    select(.result.type == "pane_process_info" and .result.process_info.pane_id == $pane)
    | .result.process_info as $view | $view.foreground_processes
    | select(type == "array" and length > 0
        and all(.[]; .pid | type == "number" and . > 1 and floor == .))
    | select((map(.pid) | unique | length) == length)
    | if $view.foreground_process_group_id != null then
        select(any(.[]; .pid == $view.foreground_process_group_id))
      else select(length == 1) end' 2>/dev/null) \
    || { printf unknown; return; }
  while IFS=$'\t' read -r pid name argv0; do
    [ "$(fm_agent_process_classify_name "$name" "$argv0")" = shell ] || ids="$ids $pid"
  done < <(printf '%s' "$candidates" | jq -r '.[] | [.pid, (.name // ""), (.argv0 // "")] | @tsv')
  candidates=$(printf '%s' "$candidates" | jq -c --arg ids "$ids " '
    map(select(.pid as $pid | $ids | contains(" \($pid) ")))')
  if [ "$(printf '%s' "$info" | jq '.result.process_info.foreground_processes | length')" -gt 1 ]; then
    group=$(printf '%s' "$info" | jq '.result.process_info.foreground_process_group_id')
    parents=$(ps -axo pid=,ppid= 2>/dev/null | jq -Rnc '
      [inputs | capture("^\\s*(?<pid>[0-9]+)\\s+(?<ppid>[0-9]+)\\s*$")
        | {key:.pid,value:(.ppid | tonumber)}] | from_entries') \
      || { printf unknown; return; }
    candidates=$(printf '%s' "$candidates" | jq -ec --argjson parents "$parents" --argjson group "$group" '
      map(.pid) as $ids
      | def below($pid; $targets; $seen):
          $parents[$pid | tostring] as $parent
          | if $parent == null or ($seen | index($parent)) != null then error("unreadable ancestry")
            elif ($targets | index($parent)) != null then true
            elif $parent <= 1 then false
            elif ($seen | length) >= 64 then error("deep ancestry")
            else below($parent; $targets; $seen + [$parent]) end;
        map(select(below(.pid; $ids; [.pid]) | not))
        | map(select(.pid == $group or below(.pid; [$group]; [.pid])))' 2>/dev/null) \
      || { printf unknown; return; }
  fi
  foreground=$(printf '%s' "$candidates" | jq -ec 'select(length == 1) | .[0]') \
    || { printf unknown; return; }
  proof=$(fm_meta_get "$meta" launch_proof)
  case "$proof" in
    env-v1|'') ;;
    *) printf unknown; return ;;
  esac
  gen=$(fm_meta_get "$meta" spawn_gen)
  pid=$(printf '%s' "$foreground" | jq -er '.pid
    | select(type == "number" and . > 1) | floor' 2>/dev/null) \
    || { printf unknown; return; }
  verdict=$(fm_launch_proof_pid "$pid" "$gen")
  if [ "$verdict" = managed ] && [ "$(fm_meta_get "$meta" harness)" = omp ]; then
    # Launch argv and the environment survive /resume. Only the extension's
    # current activation for this live PID may authorize the task conversation.
    record=$(jq -ec --arg gen "$gen" --argjson pid "$pid" '
      select(.version == 1 and .spawn_gen == $gen and .pid == $pid)
      | select(all(.task_session_file, .current_session_file;
          type == "string" and startswith("/") and (explode | all(. >= 32))))' \
      "${meta%.meta}.omp-session.json" 2>/dev/null) \
      || { printf unmanaged; return; }
    task_file=$(printf '%s' "$record" | jq -r '.task_session_file')
    current_file=$(printf '%s' "$record" | jq -r '.current_session_file')
    if [ ! -f "$task_file" ] || [ ! -f "$current_file" ] \
      || [ ! "$task_file" -ef "$current_file" ]; then
      printf unmanaged
      return
    fi
  fi
  case "$verdict" in
    managed|unknown) printf '%s' "$verdict" ;;
    unmanaged)
      if [ "$(fm_meta_get "$meta" harness)" = omp ]; then
        printf unmanaged
      else
        printf unknown
      fi
      ;;
  esac
}
