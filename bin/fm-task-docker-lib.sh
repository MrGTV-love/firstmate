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
#       when Docker is absent, or when Docker could not be asked (a warning
#       names the manual command); returns 1 when an owned container survives
#       its removal, so the caller keeps the task's records for a rerun.
#         <sibling-ids>  space-separated ids of every OTHER live task in any
#                        local Firstmate home.
#         <ambiguous>    1 when another local home has a live task with this
#                        same id, so the id alone proves nothing.
#         <protected>    space-separated names no name or project rule may claim,
#                        by exact equality: the project's own name, which is what
#                        its shared local stack (Supabase) is called.
#         <root>...      directories whose compose project working directory
#                        marks a stack as the task's own (the task worktree
#                        and its per-task temp root).
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
#   3. Project: a compose or Supabase CLI project label that satisfies rule 2.
#   4. Path: a compose project whose working directory is at or under a <root>.
# Rules 2 to 4 never claim an object that carries a DIFFERENT fm.task label, and
# rules 1 to 3 are not applied at all when <ambiguous> is 1. Rule 2 and 3 names
# that a longer sibling id claims (`task-v2-db` belongs to task-v2, not task)
# are left alone (only LIVE sibling tasks are known, so an id whose longer sibling
# has already finished is still read as the shorter task's). Rule 4 is the only
# rule that needs no cooperation from the worker, and it is skipped for paths in
# a nested lane.
#
# Never removed: an object no rule claims (the shared local Supabase stack, other
# tasks' stacks, containers a worker started without any marker); a named volume
# that does not carry the marker label, because `docker rm -v` drops only a
# container's anonymous volumes; a network that still has endpoints (Docker
# itself refuses); and a Supabase CLI network claimed only through a compose
# project name, so a worker's stack never takes the shared stack's network with it.
#
# A Docker call is bounded by FM_TASK_DOCKER_TIMEOUT_SECS (default 120) through
# bin/fm-timeout-lib.sh. A missing docker binary is silent. A daemon that cannot
# be listed is a warning, not a refusal: with it down nothing is running, and
# blocking every cleanup on a stopped Docker Desktop would strand finished work.

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
  for root in "$@"; do
    [ -n "$root" ] || continue
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
  if [ "$ambiguous" != 1 ]; then
    [ "$label" = "$id" ] && { printf 'label\n'; return 0; }
    for part in ${names//,/ }; do
      if ! fm_task_docker_protected "$protected" "$part" \
         && fm_task_docker_name_matches "$id" "$siblings" "$part"; then
        printf 'name\n'
        return 0
      fi
    done
    if [ -n "$project" ] && ! fm_task_docker_protected "$protected" "$project" \
       && fm_task_docker_name_matches "$id" "$siblings" "$project"; then
      printf 'project\n'
      return 0
    fi
    if [ -n "$supabase" ] && ! fm_task_docker_protected "$protected" "$supabase" \
       && fm_task_docker_name_matches "$id" "$siblings" "$supabase"; then
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

# Prints the owned containers, one per line: <id><sep><name><sep><project><sep><why>.
# Returns 2 when the daemon could not be listed.
fm_task_docker_owned_containers() {  # <id> <siblings> <ambiguous> <protected> <root>...
  local id=$1 siblings=$2 ambiguous=$3 protected=$4 sep=$_FM_TASK_DOCKER_SEP out cid names label project supabase workdir why
  shift 4
  out=$(fm_task_docker_run ps -a --no-trunc --format \
    "{{.ID}}${sep}{{.Names}}${sep}{{.Label \"$FM_TASK_DOCKER_MARKER_LABEL\"}}${sep}{{.Label \"com.docker.compose.project\"}}${sep}{{.Label \"com.supabase.cli.project\"}}${sep}{{.Label \"com.docker.compose.project.working_dir\"}}" \
    2>/dev/null) || return 2
  while IFS="$sep" read -r cid names label project supabase workdir; do
    [ -n "$cid" ] || continue
    why=$(fm_task_docker_claim "$id" "$siblings" "$ambiguous" "$protected" "$label" "$names" "$project" "$supabase" "$workdir" "$@") || continue
    printf '%s%s%s%s%s%s%s\n' "$cid" "$sep" "$names" "$sep" "${project:-$supabase}" "$sep" "$why"
  done <<EOF
$out
EOF
}

fm_task_docker_cleanup() {  # <task-id> <sibling-ids> <ambiguous> <protected> [<root>...]
  local id=$1 siblings=$2 ambiguous=$3 protected=$4 sep=$_FM_TASK_DOCKER_SEP rc=0
  local owned cid names project why survivors projects="" nname
  local -a ids
  shift 4
  command -v docker >/dev/null 2>&1 || return 0
  owned=$(fm_task_docker_owned_containers "$id" "$siblings" "$ambiguous" "$protected" "$@") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "warning: Docker could not be listed for $id, so its Docker stacks were not cleaned up; with Docker running, list its own with: docker ps -a --filter label=$FM_TASK_DOCKER_MARKER_LABEL=$id" >&2
    return 0
  fi
  ids=()
  names=
  while IFS="$sep" read -r cid nname project why; do
    [ -n "$cid" ] || continue
    ids+=("$cid")
    names="$names $nname($why)"
    case " $projects " in *" $project "*) ;; *) [ -z "$project" ] || projects="$projects $project" ;; esac
  done <<EOF
$owned
EOF
  if [ "${#ids[@]}" -gt 0 ]; then
    echo "teardown: removing Docker container(s) owned by $id:$names" >&2
    fm_task_docker_run rm -f -v "${ids[@]}" >/dev/null 2>&1 || true
    rc=0
    survivors=$(fm_task_docker_owned_containers "$id" "$siblings" "$ambiguous" "$protected" "$@") || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "warning: Docker could not be listed again after removing the containers owned by $id, so the removal is unverified; check with: docker ps -a --filter label=$FM_TASK_DOCKER_MARKER_LABEL=$id" >&2
    elif [ -n "$survivors" ]; then
      echo "error: Docker container(s) owned by $id are still present after removal:$(printf '%s\n' "$survivors" | while IFS="$sep" read -r cid nname _ _; do printf ' %s' "$nname"; done)" >&2
      return 1
    fi
  fi
  fm_task_docker_remove_networks "$id" "$siblings" "$ambiguous" "$protected" "$projects"
  fm_task_docker_remove_volumes "$id" "$ambiguous"
  return 0
}

fm_task_docker_remove_networks() {  # <id> <siblings> <ambiguous> <protected> <owned-projects>
  local id=$1 siblings=$2 ambiguous=$3 protected=$4 projects=$5 sep=$_FM_TASK_DOCKER_SEP out nid nname label proj supabase claim
  out=$(fm_task_docker_run network ls --no-trunc --format \
    "{{.ID}}${sep}{{.Name}}${sep}{{.Label \"$FM_TASK_DOCKER_MARKER_LABEL\"}}${sep}{{.Label \"com.docker.compose.project\"}}${sep}{{.Label \"com.supabase.cli.project\"}}" \
    2>/dev/null) || return 0
  while IFS="$sep" read -r nid nname label proj supabase; do
    [ -n "$nid" ] || continue
    claim=0
    if [ -n "$label" ] && [ "$label" != "$id" ]; then
      continue
    fi
    if [ "$ambiguous" != 1 ]; then
      [ "$label" = "$id" ] && claim=1
      if [ -n "$proj" ] && ! fm_task_docker_protected "$protected" "$proj" \
         && fm_task_docker_name_matches "$id" "$siblings" "$proj"; then claim=1; fi
      if [ -n "$supabase" ] && ! fm_task_docker_protected "$protected" "$supabase" \
         && fm_task_docker_name_matches "$id" "$siblings" "$supabase"; then claim=1; fi
    fi
    if [ "$claim" = 0 ] && [ -n "$proj" ] && [ -z "$supabase" ] \
       && ! fm_task_docker_protected "$protected" "$proj"; then
      case " $projects " in *" $proj "*) claim=1 ;; esac
    fi
    [ "$claim" = 1 ] || continue
    # Docker refuses a network that still has endpoints, which is the guard that
    # keeps another stack's live network; a refusal is the expected answer.
    if fm_task_docker_run network rm "$nid" >/dev/null 2>&1; then
      echo "teardown: removed Docker network $nname owned by $id" >&2
    fi
  done <<EOF
$out
EOF
}

fm_task_docker_remove_volumes() {  # <id> <ambiguous>
  local id=$1 ambiguous=$2 out vol
  [ "$ambiguous" != 1 ] || return 0
  out=$(fm_task_docker_run volume ls -q --filter "label=$FM_TASK_DOCKER_MARKER_LABEL=$id" 2>/dev/null) || return 0
  while IFS= read -r vol; do
    [ -n "$vol" ] || continue
    if fm_task_docker_run volume rm "$vol" >/dev/null 2>&1; then
      echo "teardown: removed Docker volume $vol owned by $id" >&2
    else
      echo "warning: Docker volume $vol is labelled for $id but could not be removed (in use?); remove it by hand with: docker volume rm $vol" >&2
    fi
  done <<EOF
$out
EOF
}
