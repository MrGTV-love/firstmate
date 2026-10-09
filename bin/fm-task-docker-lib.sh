#!/usr/bin/env bash
# fm-task-docker-lib.sh - the single owner of which Docker objects belong to a
# task and of their removal when the task is torn down.
#
# Sourced, never executed. bin/fm-teardown.sh calls fm_task_docker_cleanup in
# the same pre-destructive cleanup that reaps leaked worktree processes, so a
# worker's throwaway database or compose stack does not outlive its task
# (observed 2026-09-30 to 2026-10-06: three stopped throwaway Postgres
# containers survived 1.5 to 8 days because teardown had no Docker step).
#
#   fm_task_docker_cleanup <task-id> <sibling-ids> <ambiguous> <protected> [<root>...]
#       Removes the Docker containers, then the compose/labelled networks and
#       labelled volumes, that this task owns. Returns 0 when nothing is owned,
#       or when Docker is absent; returns nonzero when cleanup is incomplete.
#         <sibling-ids>  space-separated ids of every OTHER live task in any
#                        local Firstmate home.
#         <ambiguous>    1 when another local home has a live task with this
#                        same id, so the id alone proves nothing.
#         <protected>    space-separated shared-stack project identities.
#         <root>...      the task's owned worktree directories.
#       fm_task_docker_path_excluded <root> <path>, when the caller defines it,
#       returns 0 for a path that sits in a nested lane the task does not own.
#
# Ownership is decided per object, from evidence the object carries itself.
# Nothing here infers ownership from timing or from "looks unused", because
# both are shared across lanes (a window test put 15 of 36 live containers
# inside the lifetime of two or more live tasks on 2026-10-08).
#   1. Marker label: the object carries `fm.task=<id>`.
#      The worker brief (bin/fm-brief.sh) tells workers to set it from the
#      FM_TASK_ID that bin/fm-spawn.sh exports into every ship and scout pane.
#   2. Name: a container name that is the id, or the id followed by - or _.
#   3. Project: a compose or Supabase CLI project label equal to the task id.
#   4. Path: a compose project whose canonical working directory is under a <root>.
#
# Never removed: an object no rule claims (the shared local Supabase stack, other
# tasks' stacks, containers a worker started without any marker); a named volume
# that does not carry the marker label, because `docker rm -v` drops only a
# container's anonymous volumes.
#
# A Docker call is bounded by FM_TASK_DOCKER_TIMEOUT_SECS (default 120) through
# bin/fm-timeout-lib.sh. A missing docker binary is silent.

_FM_TASK_DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_TASK_DOCKER_DIR/fm-timeout-lib.sh"

FM_TASK_DOCKER_MARKER_LABEL=fm.task
_FM_TASK_DOCKER_SEP=$'\037'

fm_task_docker_run() {
  local secs=${FM_TASK_DOCKER_TIMEOUT_SECS:-120}
  case "$secs" in ''|*[!0-9]*|0) secs=120 ;; esac
  fm_run_timed "$secs" docker "$@"
}

# True when <value> names task <id>: the id itself, or the id then - or _ and
# more, unless a longer sibling id (<sibling-ids>) is the better claim.
fm_task_docker_name_matches() {  # <id> <siblings> <value>
  local id=$1 siblings=$2 value=$3 sibling
  case "$value" in
    "$id"|"$id"-*|"$id"_*) ;;
    *) return 1 ;;
  esac
  for sibling in $siblings; do
    case "$sibling" in
      "$id"-*|"$id"_*)
        case "$value" in
          "$sibling"|"$sibling"-*|"$sibling"_*) return 1 ;;
        esac
        ;;
    esac
  done
  return 0
}

# True when <value> is exactly one of the <protected> names.
fm_task_docker_protected() {  # <protected> <value>
  local name
  for name in $1; do
    [ "$name" != "$2" ] || return 0
  done
  return 1
}

fm_task_docker_path_owned() {  # <path> <root>...
  local path=$1 root
  shift
  [ -n "$path" ] || return 1
  [ "$#" -gt 0 ] || return 1
  path=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path") || return 1
  for root in "$@"; do
    [ -n "$root" ] || continue
    root=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$root") || continue
    case "$path" in
      "$root"|"$root"/*)
        if declare -F fm_task_docker_path_excluded >/dev/null 2>&1 \
           && fm_task_docker_path_excluded "$root" "$path"; then
          continue
        fi
        return 0
        ;;
    esac
  done
  return 1
}

# Why an object is the task's, or nothing when it is not. Fields are the object's
# own: marker label, compose project, supabase project, working dir, name(s).
fm_task_docker_claim() {  # <id> <siblings> <ambiguous> <protected> <label> <name> <project> <supabase> <workdir> <root>...
  local id=$1 siblings=$2 ambiguous=$3 protected=$4 label=$5 names=$6 project=$7 supabase=$8 workdir=$9 part
  shift 9
  if [ -n "$label" ] && [ "$label" != "$id" ]; then
    return 1
  fi
  if [ "$ambiguous" != 1 ] && [ "$label" = "$id" ]; then
    printf 'label\n'
    return 0
  fi
  if fm_task_docker_protected "$protected" "$project" \
     || fm_task_docker_protected "$protected" "$supabase"; then
    return 1
  fi
  if [ "$ambiguous" != 1 ]; then
    for part in ${names//,/ }; do
      if ! fm_task_docker_protected "$protected" "$part" \
         && fm_task_docker_name_matches "$id" "$siblings" "$part"; then
        printf 'name\n'
        return 0
      fi
    done
    if [ "$project" = "$id" ] || [ "$supabase" = "$id" ]; then
      printf 'project\n'
      return 0
    fi
  fi
  if fm_task_docker_path_owned "$workdir" "$@"; then
    printf 'path\n'
    return 0
  fi
  return 1
}

fm_task_docker_containers() {
  local id=$1 siblings=$2 ambiguous=$3 protected=$4 sep=$_FM_TASK_DOCKER_SEP out cid names label project supabase workdir why
  shift 4
  out=$(fm_task_docker_run ps -a --no-trunc --format \
    "{{.ID}}${sep}{{.Names}}${sep}{{.Label \"$FM_TASK_DOCKER_MARKER_LABEL\"}}${sep}{{.Label \"com.docker.compose.project\"}}${sep}{{.Label \"com.supabase.cli.project\"}}${sep}{{.Label \"com.docker.compose.project.working_dir\"}}" \
    2>/dev/null) || return 2
  while IFS="$sep" read -r cid names label project supabase workdir; do
    [ -n "$cid" ] || continue
    why=$(fm_task_docker_claim "$id" "$siblings" "$ambiguous" "$protected" "$label" "$names" "$project" "$supabase" "$workdir" "$@") || why=
    printf '%s%s%s%s%s%s%s%s%s\n' "$cid" "$sep" "$names" "$sep" "$project" "$sep" "$supabase" "$sep" "$why"
  done <<EOF
$out
EOF
}

fm_task_docker_cleanup() {  # <task-id> <sibling-ids> <ambiguous> <protected> [<root>...]
  local id=$1 siblings=$2 ambiguous=$3 protected=$4 sep=$_FM_TASK_DOCKER_SEP
  local objects cid names project supabase why survivors projects="" foreign_projects="" nname candidate
  local -a ids
  shift 4
  command -v docker >/dev/null 2>&1 || return 0
  if [ "$#" -gt 0 ] && ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required to resolve Docker working directories for $id" >&2
    return 1
  fi
  if ! objects=$(fm_task_docker_containers "$id" "$siblings" "$ambiguous" "$protected" "$@"); then
    echo "warning: Docker could not be listed for $id, so its Docker stacks were not cleaned up; with Docker running, list its own with: docker ps -a --filter label=$FM_TASK_DOCKER_MARKER_LABEL=$id" >&2
    return 1
  fi
  ids=()
  names=
  while IFS="$sep" read -r cid nname project supabase why; do
    [ -n "$cid" ] || continue
    for candidate in "$project" "$supabase"; do
      [ -n "$candidate" ] || continue
      if [ -n "$why" ]; then
        case " $projects " in *" $candidate "*) ;; *) projects="$projects $candidate" ;; esac
      else
        case " $foreign_projects " in *" $candidate "*) ;; *) foreign_projects="$foreign_projects $candidate" ;; esac
      fi
    done
    [ -n "$why" ] || continue
    ids+=("$cid")
    names="$names $nname($why)"
  done <<EOF
$objects
EOF
  if [ "${#ids[@]}" -gt 0 ]; then
    echo "teardown: removing Docker container(s) owned by $id:$names" >&2
    fm_task_docker_run rm -f -v "${ids[@]}" >/dev/null 2>&1 || return 1
    if ! survivors=$(fm_task_docker_containers "$id" "$siblings" "$ambiguous" "$protected" "$@"); then
      echo "warning: Docker could not be listed again after removing the containers owned by $id, so the removal is unverified; check with: docker ps -a --filter label=$FM_TASK_DOCKER_MARKER_LABEL=$id" >&2
      return 1
    fi
    while IFS="$sep" read -r cid nname project supabase why; do
      [ -n "$cid" ] && [ -n "$why" ] || continue
      echo "error: Docker container owned by $id is still present after removal: $nname" >&2
      return 1
    done <<EOF
$survivors
EOF
  fi
  fm_task_docker_remove_networks "$id" "$ambiguous" "$protected" "$projects" "$foreign_projects" || return 1
  fm_task_docker_remove_volumes "$id" "$ambiguous" || return 1
  return 0
}

fm_task_docker_remove_networks() {
  local id=$1 ambiguous=$2 protected=$3 projects=$4 foreign_projects=$5 sep=$_FM_TASK_DOCKER_SEP out nid nname label proj supabase claim
  out=$(fm_task_docker_run network ls --no-trunc --format \
    "{{.ID}}${sep}{{.Name}}${sep}{{.Label \"$FM_TASK_DOCKER_MARKER_LABEL\"}}${sep}{{.Label \"com.docker.compose.project\"}}${sep}{{.Label \"com.supabase.cli.project\"}}" \
    2>/dev/null) || return 1
  while IFS="$sep" read -r nid nname label proj supabase; do
    [ -n "$nid" ] || continue
    claim=0
    if [ -n "$label" ] && [ "$label" != "$id" ]; then
      continue
    fi
    if [ "$ambiguous" != 1 ] && [ "$label" = "$id" ]; then
      claim=1
    else
      if fm_task_docker_protected "$protected" "$proj" \
         || fm_task_docker_protected "$protected" "$supabase"; then
        continue
      fi
      if [ -n "$proj" ]; then
        case " $foreign_projects " in *" $proj "*) continue ;; esac
      fi
      if [ -n "$supabase" ]; then
        case " $foreign_projects " in *" $supabase "*) continue ;; esac
      fi
      if [ "$ambiguous" != 1 ] && { [ "$proj" = "$id" ] || [ "$supabase" = "$id" ]; }; then
        claim=1
      fi
      # An empty foreign network with no foreign project container is indistinguishable.
      if [ "$claim" = 0 ] && [ -n "$proj" ] && [ -z "$supabase" ]; then
        case " $projects " in *" $proj "*) claim=1 ;; esac
      fi
    fi
    [ "$claim" = 1 ] || continue
    if fm_task_docker_run network rm "$nid" >/dev/null 2>&1; then
      echo "teardown: removed Docker network $nname owned by $id" >&2
    else
      echo "warning: Docker network $nname owned by $id could not be removed" >&2
      return 1
    fi
  done <<EOF
$out
EOF
  return 0
}

fm_task_docker_remove_volumes() {  # <id> <ambiguous>
  local id=$1 ambiguous=$2 out vol
  [ "$ambiguous" != 1 ] || return 0
  out=$(fm_task_docker_run volume ls -q --filter "label=$FM_TASK_DOCKER_MARKER_LABEL=$id" 2>/dev/null) || return 1
  while IFS= read -r vol; do
    [ -n "$vol" ] || continue
    if fm_task_docker_run volume rm "$vol" >/dev/null 2>&1; then
      echo "teardown: removed Docker volume $vol owned by $id" >&2
    else
      echo "warning: Docker volume $vol is labelled for $id but could not be removed (in use?); remove it by hand with: docker volume rm $vol" >&2
      return 1
    fi
  done <<EOF
$out
EOF
  return 0
}
