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
# The folder is the registered ship-branch prefix up to its last slash, read through the
# bin/fm-project-mode.sh beside this file (--branch-prefix); it is never hard-coded. A
# branch is <prefix><task-id>, so "fm/" and "team/fm/" name a folder, "team/fm-" names
# "team", and "fm-" or an empty prefix (bare "<task-id>" branches) names none. A prefix that
# holds an empty, "." or ".." component, that is not a valid branch ref name, or that cannot
# be read, restores nothing.
# Each folder is made by one non-recursive mkdir per component, starting under
# refs/heads and logs/refs/heads, which and every directory above them must already
# exist as real directories (never a link). A
# component that already exists, as a directory or as any other kind of entry
# including a symbolic link, is never replaced and never followed: the walk stops
# there. The helper never deletes anything and never fails its caller.
#
# fm-worker-branch-no-ref-dir-prereq's relaunch mkdir is a later user of this
# helper: it keys its folders to state/*.meta, and this helper is the one owner of
# restoring them from the registered prefix.

fm_branch_ref_dirs_folder() {
  local name=$1 prefix script_dir folder
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  prefix=$("$script_dir/fm-project-mode.sh" --branch-prefix "$name" 2>/dev/null) || return 1
  # A branch is <prefix><task-id>, so the folder is the prefix up to its last slash: "fm/" and
  # "team/fm/" name a folder, "team/fm-" names "team", and "fm-" names none.
  case "$prefix" in */*) folder=${prefix%/*} ;; *) return 1 ;; esac
  # Every component must be non-empty, not "." or "..", and the whole name a valid branch ref.
  case "/$folder/" in *//* | */./* | */../*) return 1 ;; esac
  git check-ref-format "refs/heads/$folder/x" >/dev/null 2>&1 || return 1
  printf '%s\n' "$folder"
}

# fm_branch_ref_dirs_real <path>: an existing directory that is not a link.
fm_branch_ref_dirs_real() { [ -d "$1" ] && [ ! -L "$1" ]; }

fm_restore_branch_ref_dirs() {
  local dir=$1 name=$2 folder common root path comp rest
  folder=$(fm_branch_ref_dirs_folder "$name") || return 0
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 0
  [ -n "$common" ] || return 0
  case "$common" in
    /*) ;;
    *) common=$(cd "$dir" && cd "$common" && pwd -P) || return 0 ;;
  esac
  for root in refs/heads logs/refs/heads; do
    # Every directory above the folders must be a real directory too: a link at refs, logs or logs/refs is never followed.
    path=$common
    rest=$root
    while [ -n "$rest" ]; do
      comp=${rest%%/*}
      if [ "$comp" = "$rest" ]; then rest=; else rest=${rest#*/}; fi
      path=$path/$comp
      fm_branch_ref_dirs_real "$path" || continue 2
    done
    rest=$folder
    while [ -n "$rest" ]; do
      comp=${rest%%/*}
      if [ "$comp" = "$rest" ]; then rest=; else rest=${rest#*/}; fi
      path=$path/$comp
      if [ -e "$path" ] || [ -L "$path" ]; then
        fm_branch_ref_dirs_real "$path" || break
        continue
      fi
      mkdir -- "$path" 2>/dev/null || fm_branch_ref_dirs_real "$path" || break
    done
  done
  return 0
}
