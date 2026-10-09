#!/usr/bin/env bash
# fm-task-docker-lib.sh - the single owner of which Docker objects belong to a
# task and of their removal when the task is torn down.
#
# Sourced, never executed. bin/fm-teardown.sh's header owns the lifecycle ordering,
# forced-descendant handling, refusal-and-retry behavior, and top-level residual.
#
#   fm_task_docker_cleanup <task-id> <sibling-ids> <ambiguous> <protected> <meta> [<root>...]
#       Removes the Docker containers, then the compose/labelled networks and
#       volumes, that this task owns. Returns 0 when nothing is owned, when Docker
#       is absent, or when the first listing fails and <meta> retains no
#       docker_projects; returns nonzero when cleanup is incomplete.
#         <sibling-ids>  space-separated ids of every OTHER live task in any
#                        local Firstmate home.
#         <ambiguous>    1 when another local home has a live task with this
#                        same id, so the id alone proves nothing.
#         <protected>    space-separated shared-stack project identities.
#         <meta>         retained task record for derived project identities.
#         <root>...      the task's owned worktree directories.
#       fm_task_docker_path_excluded <root> <path>, when the caller defines it,
#       returns 0 for a path that sits in a nested lane the task does not own.
#
# Ownership is decided per object, never from age or whether it looks unused.
# A marker naming another task vetoes every container and network claim.
# When the task id is unambiguous, container evidence is considered in order:
#   1. Marker label: `fm.task=<id>` is authoritative, even on a protected project.
#   2. Name: the exact id, or the id followed by - or _; a longer matching live
#      sibling id vetoes the shorter id's claim.
#   3. Project: a Compose or Supabase CLI project label equal to the exact id,
#      never a project name that merely starts with the id.
#   4. Path: a canonical Compose working directory under an owned <root>, unless
#      fm_task_docker_path_excluded rejects the path.
# Either project label matching a <protected> identity vetoes all heuristics,
# including name and path evidence, but not an unambiguous explicit marker.
# A container name equal to a protected identity is not name evidence either.
# If the id is ambiguous across homes, only path evidence can claim a container.
# Path attribution requires python3 to resolve both the workdir and roots.
#
# Prefix-name protection uses current live sibling records only, not historical
# identities. After a longer sibling's record is retired, its unlabelled leftovers
# can match a remaining shorter id. The worker Docker instructions rendered by
# bin/fm-brief.sh require explicit markers rather than historical prefix protection.
#
# Networks need an unambiguous marker, an exact task-id project label, or a Compose
# project identity retained from owned containers. The derived-project rule applies
# only when the network has a Compose project label and no Supabase project label.
# Protected identities veto heuristic network claims. So does either network
# project identity carried in either project label by a foreign container in the
# latest successful container listing, even if that container has no endpoint on
# the network. An unambiguous marker bypasses both heuristic vetoes.
# Named volumes need an unambiguous marker or an exact task-id Compose or Supabase
# project label; names and derived projects do not establish volume ownership.
# A marker naming another task, a protected identity, or a foreign container
# carrying either volume project identity vetoes the project-label claim.
# `docker rm -v` also removes anonymous volumes.
# Objects with no qualifying ownership evidence are left alone.
#
# Before removing containers, cleanup atomically retains their Compose and Supabase
# project identities in the task record's docker_projects field. Retries read that
# field after the containers are gone; task-record retirement removes it.
# Listing, metadata read/publication, removal, or verification failures return
# nonzero, except that a failed first listing (a stopped or unreachable daemon)
# only warns and returns 0 when the task record retains no docker_projects.
# After container removal, any surviving owned container refuses cleanup and
# prints the removal's own error; a failed removal with no survivor is not a failure.
# A final container listing also rejects arrivals during network or volume cleanup.
# Portable regression coverage: tests/fm-teardown.test.sh; real Docker CLI guard:
# tests/fm-task-docker-live-e2e.test.sh.
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

fm_task_docker_cleanup() {
  local id=$1 siblings=$2 ambiguous=$3 protected=$4 record=$5 sep=$_FM_TASK_DOCKER_SEP
  local objects cid names project supabase why projects foreign_projects="" nname candidate saved_projects tmp rm_err
  local -a ids
  shift 5
  command -v docker >/dev/null 2>&1 || return 0
  if [ "$#" -gt 0 ] && ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required to resolve Docker working directories for $id" >&2
    return 1
  fi
  if [ ! -f "$record" ] || [ -L "$record" ] \
     || ! projects=$(LC_ALL=C awk 'index($0, "docker_projects=") == 1 {value=substr($0, 17)} END {print value}' "$record"); then
    echo "error: cannot read retained Docker project identities for $id" >&2
    return 1
  fi
  saved_projects=$projects
  if ! objects=$(fm_task_docker_containers "$id" "$siblings" "$ambiguous" "$protected" "$@"); then
    if [ -z "$saved_projects" ]; then
      echo "warning: Docker could not be listed for $id and its task record retains no Docker project identities, so Docker cleanup was skipped; with Docker running, list its own with: docker ps -a --filter label=$FM_TASK_DOCKER_MARKER_LABEL=$id" >&2
      return 0
    fi
    echo "warning: Docker could not be listed for $id, so its Docker stacks were not cleaned up; with Docker running, list its own with: docker ps -a --filter label=$FM_TASK_DOCKER_MARKER_LABEL=$id" >&2
    return 1
  fi
  ids=()
  names=
  while IFS="$sep" read -r cid nname project supabase why; do
    [ -n "$cid" ] || continue
    for candidate in "$project" "$supabase"; do
      [ -n "$candidate" ] || continue
      [ -n "$why" ] || continue
      case " $projects " in *" $candidate "*) ;; *) projects="$projects $candidate" ;; esac
    done
    [ -n "$why" ] || continue
    ids+=("$cid")
    names="$names $nname($why)"
  done <<EOF
$objects
EOF
  if [ "$projects" != "$saved_projects" ]; then
    tmp=$(umask 077; mktemp "${record%/*}/.docker-projects.XXXXXXXX") || return 1
    if ! { LC_ALL=C awk 'index($0, "docker_projects=") != 1' "$record" \
           && printf 'docker_projects=%s\n' "$projects"; } > "$tmp" \
       || ! mv -f "$tmp" "$record"; then
      rm -f "$tmp"
      echo "error: cannot retain Docker project identities for $id before removal" >&2
      return 1
    fi
  fi
  if [ "${#ids[@]}" -gt 0 ]; then
    echo "teardown: removing Docker container(s) owned by $id:$names" >&2
    rm_err=$(fm_task_docker_run rm -f -v "${ids[@]}" 2>&1 >/dev/null) || true
    if ! objects=$(fm_task_docker_containers "$id" "$siblings" "$ambiguous" "$protected" "$@"); then
      echo "warning: Docker could not be listed again after removing the containers owned by $id, so the removal is unverified; check with: docker ps -a --filter label=$FM_TASK_DOCKER_MARKER_LABEL=$id" >&2
      return 1
    fi
    while IFS="$sep" read -r cid nname project supabase why; do
      [ -n "$cid" ] && [ -n "$why" ] || continue
      echo "error: Docker container owned by $id is still present after removal: $nname" >&2
      [ -z "$rm_err" ] || printf '%s\n' "$rm_err" >&2
      return 1
    done <<EOF
$objects
EOF
  fi
  while IFS="$sep" read -r cid nname project supabase why; do
    [ -n "$cid" ] && [ -z "$why" ] || continue
    for candidate in "$project" "$supabase"; do
      [ -n "$candidate" ] || continue
      case " $foreign_projects " in *" $candidate "*) ;; *) foreign_projects="$foreign_projects $candidate" ;; esac
    done
  done <<EOF
$objects
EOF
  fm_task_docker_remove_networks "$id" "$ambiguous" "$protected" "$projects" "$foreign_projects" || return 1
  fm_task_docker_remove_volumes "$id" "$ambiguous" "$protected" "$foreign_projects" || return 1
  if ! objects=$(fm_task_docker_containers "$id" "$siblings" "$ambiguous" "$protected" "$@"); then
    echo "warning: Docker could not be listed after cleaning the stacks owned by $id, so cleanup is unverified" >&2
    return 1
  fi
  while IFS="$sep" read -r cid nname project supabase why; do
    [ -n "$cid" ] && [ -n "$why" ] || continue
    echo "error: Docker container owned by $id is still present after stack cleanup: $nname" >&2
    return 1
  done <<EOF
$objects
EOF
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

fm_task_docker_remove_volumes() {  # <id> <ambiguous> <protected> <foreign-projects>
  local id=$1 ambiguous=$2 protected=$3 foreign_projects=$4 sep=$_FM_TASK_DOCKER_SEP out vol label proj supabase
  [ "$ambiguous" != 1 ] || return 0
  out=$(fm_task_docker_run volume ls --format \
    "{{.Name}}${sep}{{.Label \"$FM_TASK_DOCKER_MARKER_LABEL\"}}${sep}{{.Label \"com.docker.compose.project\"}}${sep}{{.Label \"com.supabase.cli.project\"}}" \
    2>/dev/null) || return 1
  while IFS="$sep" read -r vol label proj supabase; do
    [ -n "$vol" ] || continue
    if [ "$label" != "$id" ]; then
      [ -z "$label" ] || continue
      [ "$proj" = "$id" ] || [ "$supabase" = "$id" ] || continue
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
    fi
    if fm_task_docker_run volume rm "$vol" >/dev/null 2>&1; then
      echo "teardown: removed Docker volume $vol owned by $id" >&2
    else
      echo "warning: Docker volume $vol is owned by $id but could not be removed (in use?); remove it by hand with: docker volume rm $vol" >&2
      return 1
    fi
  done <<EOF
$out
EOF
  return 0
}
