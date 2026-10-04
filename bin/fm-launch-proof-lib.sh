#!/usr/bin/env bash
# Proof that a recorded Herdr agent came through Firstmate's launch boundary.
# fm-spawn stamps FM_SPAWN_GEN with the record's spawn_gen and records
# launch_proof=env-v1. This is an incarnation binding, not an auth credential.
# Native Herdr restore reconstructs argv, not the launch environment/settings.
# Verdicts: managed|unmanaged|unknown. Unknown never authorizes a relaunch.
# Legacy records are recoverable only with exact bare native-resume argv;
# missing proof on an ordinary legacy launch is not evidence it is unmanaged.
# No endpoint discovery: callers supply this home's validated exact endpoint.

_FM_LAUNCH_PROOF_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-remote-herdr-owner-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-agent-process-lib.sh"

fm_launch_proof_pid() { # <pid> <spawn-gen> -> managed|unmanaged|unknown
  local pid=$1 gen=$2 environment
  case "$pid" in ''|*[!0-9]*) printf unknown; return ;; esac
  [ -n "$gen" ] || { printf unknown; return; }
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
  local meta=$1 target session pane info foreground pid argv harness proof gen
  local candidates ids='' name argv0 parents group
  local program native installed interpreted=0
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
  if [ "$proof" = env-v1 ]; then
    pid=$(printf '%s' "$foreground" | jq -er '.pid
      | select(type == "number" and . > 1) | floor' 2>/dev/null) \
      || { printf unknown; return; }
    gen=$(fm_meta_get "$meta" spawn_gen)
    fm_launch_proof_pid "$pid" "$gen"
    return
  fi
  [ -z "$proof" ] || { printf unknown; return; }
  harness=$(fm_meta_get "$meta" harness)
  argv=$(printf '%s' "$foreground" | jq -ec '.argv
    | select(type == "array" and length > 0 and all(.[]; type == "string"))' 2>/dev/null) \
    || { printf unknown; return; }
  # Native commands may exec a version-named binary or a shebang interpreter.
  # Resolve an interpreter's entry point against the installed recorded CLI,
  # never a harness-shaped substring in a prompt or an arbitrary script path.
  native=$harness
  [ "$native" != pi-signed ] || native=pi
  program=$(printf '%s' "$argv" | jq -r '.[0]')
  case "${program##*/}" in
    node|nodejs|bun|python|python[0-9]*)
      interpreted=1
      program=$(printf '%s' "$argv" | jq -r '.[1] // empty')
      argv=$(printf '%s' "$argv" | jq -c '.[1:]')
      ;;
  esac
  if [ "$harness" = cursor ]; then
    fm_cursor_path_is_cursor "$program" || { printf unknown; return; }
  elif [ "$interpreted" = 0 ] && { [ "${program##*/}" = "$native" ] \
    || { [ "$native" = pi ] && [ "${program##*/}" = pi-launcher ]; } \
    || [ "$(fm_harness_path_name "$program" 2>/dev/null)" = "$native" ]; }; then
    :
  else
    installed=$(command -v "$native" 2>/dev/null || true)
    [ -n "$installed" ] && [ -f "$installed" ] && [ -f "$program" ] \
      && [ "$(fm_cursor_canonical_path "$installed")" = "$(fm_cursor_canonical_path "$program")" ] \
      || { printf unknown; return; }
  fi
  # The native commands documented by Herdr contain only a resume flag and a
  # session ref. Extra flags are not interpreted or silently discarded.
  if printf '%s' "$argv" | jq -e --arg h "$harness" '
    if $h == "omp" then
      (length == 2 and (.[1] | startswith("--resume=") and length > 9))
      or (length == 3 and .[1] == "--resume" and .[2] != "")
    elif $h == "codex" then length == 3 and .[1] == "resume" and .[2] != ""
    elif $h == "pi" or $h == "pi-signed" or $h == "kimi" or $h == "opencode" then
      length == 3 and .[1] == "--session" and .[2] != ""
    elif $h == "agy" then length == 3 and .[1] == "--conversation" and .[2] != ""
    elif $h == "claude" or $h == "cursor" or $h == "grok" or $h == "devin" then
      length == 3 and .[1] == "--resume" and .[2] != ""
    else false end
  ' >/dev/null 2>&1; then printf unmanaged; else printf unknown; fi
}
