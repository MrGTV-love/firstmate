#!/usr/bin/env bash
# Proof that a recorded Herdr agent came through Firstmate's launch boundary.
# fm-spawn stamps FM_SPAWN_GEN with the record's spawn_gen and records
# launch_proof=env-v1. This is an incarnation binding, not an auth credential.
# Native Herdr restore reconstructs argv, not the launch environment/settings.
# Verdicts: managed|unmanaged|unknown. Unknown never authorizes a relaunch.
# Missing incarnation proof requires exact bare compiled omp resume argv, the
# recorded cwd, and persisted task-owned initial launch provenance.
# No endpoint discovery: callers supply this home's validated exact endpoint.

_FM_LAUNCH_PROOF_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-remote-herdr-owner-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-operational-input.sh"

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

# The native conversation, not a current pane registration, binds a bare
# restore to this task's delivered launch input. Read only the named file.
fm_launch_proof_native_startup() { # <meta> <session-file> <worktree>
  local meta=$1 ref=$2 worktree=$3 message kind body expected source state id data
  local role_head role_tail inbox inbox_state recorded_state
  [ -f "$ref" ] && [ -r "$ref" ] || return 1
  message=$(jq -ern --arg cwd "$worktree" '
    def native_title_slot:
      type == "object" and .type == "title" and .v == 1
      and (.title | type == "string") and (.updatedAt | type == "string")
      and (.pad | type == "string")
      and ((has("source") | not) or .source == "auto" or .source == "user");
    reduce inputs as $entry ({header:null, first:null, header_seen:false, user_seen:false, first_entry:true};
      if .first_entry and ($entry | native_title_slot) then .first_entry = false
      elif .header_seen == false then .header = $entry | .header_seen = true | .first_entry = false
      elif .user_seen == false and $entry.type == "message" and $entry.message.role == "user"
        then .first = $entry.message.content | .user_seen = true
      else . end)
    | select(.header.type == "session" and .header.cwd == $cwd and .first != null)
    | .first
    | if type == "string" then .
      elif type == "array" and length > 0
        and all(.[]; .type == "text" and (.text | type == "string"))
        then map(.text) | join("")
      else error("unreadable initial user input") end
    | select(length > 0)' "$ref" 2>/dev/null) || return 1
  fm_operational_generic_kind "$message" kind && [ "$kind" = launch-brief ] || return 1
  fm_operational_input_body "$message" body || return 1
  state=${meta%/*}
  id=${meta##*/}; id=${id%.meta}
  case "$(fm_meta_get "$meta" kind)" in
    secondmate)
      source="$worktree/data/charter.md"
      if [ ! -f "$source" ]; then
        data=${FM_DATA_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$_FM_LAUNCH_PROOF_DIR/..}}/data}
        source="$data/$id/brief.md"
      fi
      expected=$(cat "$source" 2>/dev/null) || return 1
      [ -n "$expected" ] && [ "$body" = "$expected" ]
      ;;
    ship|scout|'')
      expected=$(fm_brief_worker_role "$state" "$id") || return 1
      role_head=${expected%%"$state/$id.inbox"*}
      role_tail=${expected#*"$state/$id.inbox"}
      case "$body" in "$role_head"*) ;; *) return 1 ;; esac
      inbox=${body#"$role_head"}
      inbox=${inbox%%"$role_tail"*}
      [ "${inbox##*/}" = "$id.inbox" ] || return 1
      case "$inbox" in /*) ;; *) return 1 ;; esac
      inbox_state=${inbox%/*}
      expected=$(fm_brief_worker_role "$inbox_state" "$id") || return 1
      case "$body" in "$expected"$'\n\n'?*) ;; *) return 1 ;; esac
      inbox_state=$(CDPATH='' cd -P -- "$inbox_state" 2>/dev/null && pwd -P) || return 1
      recorded_state=$(CDPATH='' cd -P -- "$state" 2>/dev/null && pwd -P) || return 1
      [ "$inbox_state" = "$recorded_state" ]
      ;;
    *) return 1 ;;
  esac
}

fm_launch_proof_herdr() { # <meta> -> managed|unmanaged|unknown
  local meta=$1 target session pane info foreground pid argv harness proof gen
  local candidates ids='' name argv0 parents group
  local verdict worktree cwd ref
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
  if [ "$proof" = env-v1 ] || [ -n "$gen" ]; then
    pid=$(printf '%s' "$foreground" | jq -er '.pid
      | select(type == "number" and . > 1) | floor' 2>/dev/null) \
      || { printf unknown; return; }
    verdict=$(fm_launch_proof_pid "$pid" "$gen")
    case "$verdict" in
      managed) printf managed; return ;;
      unknown) [ "$proof" != env-v1 ] || { printf unknown; return; } ;;
    esac
  fi
  harness=$(fm_meta_get "$meta" harness)
  [ "$harness" = omp ] || { printf unknown; return; }
  argv=$(printf '%s' "$foreground" | jq -ec '.argv
    | select(type == "array" and length > 0 and all(.[]; type == "string"))' 2>/dev/null) \
    || { printf unknown; return; }
  name=$(printf '%s' "$foreground" | jq -r '.name // .argv0 // .argv[0] // ""')
  argv0=$(printf '%s' "$foreground" | jq -r '.argv0 // .argv[0] // ""')
  [ "${name##*/}" = omp ] && [ "${argv0##*/}" = omp ] \
    || { printf unknown; return; }
  ref=$(printf '%s' "$argv" | jq -er '
    select(length == 2 and (.[0] | split("/") | last) == "omp"
      and (.[1] | startswith("--resume=") and length > 9))
    | .[1][9:]' 2>/dev/null) || { printf unknown; return; }
  worktree=$(fm_meta_get "$meta" worktree)
  cwd=$(printf '%s' "$foreground" | jq -er '.cwd | select(type == "string" and length > 0)' 2>/dev/null) \
    || { printf unknown; return; }
  [ -n "$worktree" ] && [ "$cwd" = "$worktree" ] \
    && fm_launch_proof_native_startup "$meta" "$ref" "$worktree" \
    && { printf unmanaged; return; }
  printf unknown
}
