# shellcheck shell=bash
# Restore the registered ship-branch folder of a project clone after a firstmate
# delete of its last loose ref.
# Usage: . bin/fm-branch-ref-dirs-lib.sh
#   fm_restore_branch_ref_dirs <dir-in-the-clone> <project-name>
#
# Git removes an empty refs/heads/<prefix> folder (and, when its last reflog goes,
# logs/refs/heads/<prefix>) once the last loose ref under it is deleted. A worker
# whose confinement profile has no create grant for those folders then fails its
# next commit with "unable to create directory for .../refs/heads/<prefix>/<branch>".
# The two firstmate deletes that can empty the folder - the gone-upstream prune in
# bin/fm-fleet-sync.sh and the task-branch deletes in bin/fm-teardown.sh - call this
# helper right after the delete, whether or not the delete succeeded, so the
# folders are back before any worker needs them.
#
# The prefix is the project's registered ship-branch prefix, read through the
# bin/fm-project-mode.sh beside this file (--branch-prefix) with every trailing slash stripped; it is
# never hard-coded. A prefix that is empty (bare "<task-id>" branches have no folder),
# or holds an empty, "." or ".." component, or that cannot be read, restores nothing.
# Each folder is made by one non-recursive mkdir per component, starting under
# refs/heads and logs/refs/heads, which must already exist as real directories. A
# component that already exists, as a directory or as any other kind of entry
# including a symbolic link, is never replaced and never followed: the walk stops
# there. The helper never deletes anything and never fails its caller.
#
# fm-worker-branch-no-ref-dir-prereq's relaunch mkdir is a later user of this
# helper: it keys its folders to state/*.meta, and this helper is the one owner of
# restoring them from the registered prefix.

fm_branch_ref_dirs_prefix() {
  local name=$1 prefix script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  prefix=$("$script_dir/fm-project-mode.sh" --branch-prefix "$name" 2>/dev/null) || return 1
  while [ "${prefix%/}" != "$prefix" ]; do prefix=${prefix%/}; done
  [ -n "$prefix" ] || return 1
  case "$prefix" in /* | */./* | ./* | */. | . | */../* | ../* | */.. | .. | *//*) return 1 ;; esac
  printf '%s\n' "$prefix"
}

fm_restore_branch_ref_dirs() {
  local dir=$1 name=$2 prefix common root path comp rest
  prefix=$(fm_branch_ref_dirs_prefix "$name") || return 0
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 0
  [ -n "$common" ] || return 0
  case "$common" in
    /*) ;;
    *) common=$(cd "$dir" && cd "$common" && pwd -P) || return 0 ;;
  esac
  for root in "$common/refs/heads" "$common/logs/refs/heads"; do
    [ -d "$root" ] && [ ! -L "$root" ] || continue
    path=$root
    rest=$prefix
    while [ -n "$rest" ]; do
      comp=${rest%%/*}
      if [ "$comp" = "$rest" ]; then rest=; else rest=${rest#*/}; fi
      path=$path/$comp
      if [ -e "$path" ] || [ -L "$path" ]; then
        [ -d "$path" ] && [ ! -L "$path" ] || break
        continue
      fi
      mkdir -- "$path" 2>/dev/null || { [ -d "$path" ] && [ ! -L "$path" ]; } || break
    done
  done
  return 0
}
