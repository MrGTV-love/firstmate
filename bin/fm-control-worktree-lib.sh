#!/usr/bin/env bash
# fm-control-worktree-lib.sh - the ONE owner of the proof behind relocating a
# ship task whose recorded worktree is gone onto a fresh copy of its branch
# (`fm-control.sh <id> relaunch --worktree <path>`, `fm-spawn.sh <id> --relaunch
# --worktree <path>`). Both callers run this same proof, so the control plane
# and the launch owner cannot reach two answers about one destination.
#
# The proof is read-only and allocates, moves and removes nothing: the caller
# prepares the fresh copy (docs/agent-control.md "Relocating a task whose
# worktree is gone" owns the procedure and why it is not allocated here).
# Requires fm-backend.sh (fm_meta_get), fm-wake-lib.sh (slot ownership and
# fm_local_firstmate_state_dirs), and fm-secondmate-registry-lib.sh for that walk.
#
# fm_control_worktree_relocation <meta> <id> <state-dir> <destination>
#   Returns 0 and sets, for the caller to journal and publish:
#     FM_CONTROL_RELOCATION_PATH         the destination's physical root
#     FM_CONTROL_RELOCATION_FROM         the recorded path proven absent
#     FM_CONTROL_RELOCATION_HEAD         the destination's proven HEAD
#     FM_CONTROL_RELOCATION_HEAD_SOURCE  comma-separated sources checked for containment
#   Returns 1 after printing the concrete refusal on stderr. A refusal changes
#   nothing.
#
# docs/agent-control.md "Relocating a task whose worktree is gone" owns the
# eligibility and refusal contract; keep its prose there rather than copying it.
#

fm_control_worktree_wiring_free() {
  local wt=$1 state=$2 id=$3 h path rel
  while read -r h; do
    while read -r path; do
      case "$path" in
        "$wt/"*) rel=${path#"$wt/"} ;;
        *) continue ;;
      esac
      if [ -e "$path" ] || [ -L "$path" ]; then
        echo "error: the fresh copy $wt already holds the harness file $rel, which the launch would overwrite or delete; relocation never touches a file it did not create. Use a copy without it (a copy returned to the pool carries none)" >&2
        return 1
      fi
    done < <(fm_control_harness_wiring_paths "$h" "$wt" "$state" "$id")
  done < <(fm_control_harnesses)
}

# The last head git's own reflog holds for a vanished worktree, read from the
# registration it leaves in the shared repository until someone prunes it. A
# linked worktree's HEAD names its branch, so asking git for its HEAD would
# just return the branch tip; the per-worktree reflog is what keeps the commit
# the copy last stood on even after the branch itself was moved. Prints nothing
# when no registration or reflog survives.
fm_control_worktree_registered_head() {  # <git-common-dir> <path>
  local common=$1 want=$2 admin registered reflog
  if [ -d "$common/worktrees" ] && { [ ! -r "$common/worktrees" ] || [ ! -x "$common/worktrees" ]; }; then
    echo "error: worktree registrations in $common/worktrees cannot be read" >&2
    return 1
  fi
  for admin in "$common"/worktrees/*; do
    [ -d "$admin" ] || continue
    [ -r "$admin" ] && [ -x "$admin" ] || {
      echo "error: worktree registration $admin cannot be read" >&2
      return 1
    }
    [ -e "$admin/gitdir" ] || [ -L "$admin/gitdir" ] || continue
    registered=$(cat "$admin/gitdir" 2>/dev/null) || {
      echo "error: worktree registration $admin/gitdir cannot be read" >&2
      return 1
    }
    [ "$registered" = "$want/.git" ] || continue
    if [ -d "$admin/logs" ] && { [ ! -r "$admin/logs" ] || [ ! -x "$admin/logs" ]; }; then
      echo "error: recorded worktree reflog $admin/logs cannot be read" >&2
      return 1
    fi
    [ -e "$admin/logs/HEAD" ] || [ -L "$admin/logs/HEAD" ] || return 0
    reflog=$(tail -n 1 "$admin/logs/HEAD" 2>/dev/null) || {
      echo "error: recorded worktree reflog $admin/logs/HEAD cannot be read" >&2
      return 1
    }
    printf '%s\n' "$reflog" | awk '{ print $2 }'
    return 0
  done
}

fm_control_worktree_relocation() {  # <meta> <id> <state-dir> <destination>
  local meta=$1 id=$2 state=$3 dest=$4
  local kind old probe parent real top project common project_common git_dir branch checked
  local head='' evidence='' journal other owned status source i owner_home this_home s field
  local -a heads=() sources=()

  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || {
    echo "error: --worktree relocation is for ships only: a $kind has no recorded branch to match" >&2
    return 1
  }

  old=$(fm_meta_get "$meta" worktree)
  case "$old" in
    /*) ;;
    *) echo "error: task $id records no absolute worktree path to prove absent" >&2; return 1 ;;
  esac
  case "$old" in
    */../*|*/./*|*/..|*/.) echo "error: task $id's recorded worktree $old is not a canonical path, so its absence cannot be proven" >&2; return 1 ;;
  esac
  # Absence is shown from the nearest existing ancestor, never from a failed
  # directory test: a file, a dangling symlink and an unreadable ancestry all
  # fail that test without the copy being gone.
  probe=$old
  while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    parent=${probe%/*}
    [ -n "$parent" ] || parent=/
    [ "$parent" != "$probe" ] || break
    if [ -d "$parent" ]; then
      [ -r "$parent" ] && [ -x "$parent" ] || {
        echo "error: task $id's recorded worktree $old cannot be proven absent: its ancestor $parent is unreadable" >&2
        return 1
      }
      break
    fi
    probe=$parent
  done
  if [ -e "$probe" ] || [ -L "$probe" ]; then
    echo "error: task $id's recorded worktree $old still exists or its absence cannot be proven ($probe is present); --worktree replaces a copy that is gone, never one that is there" >&2
    return 1
  fi

  case "$dest" in
    /*) ;;
    *) echo "error: the fresh copy must be given as an absolute path, not '$dest'" >&2; return 1 ;;
  esac
  real=$(cd "$dest" 2>/dev/null && pwd -P) || {
    echo "error: the fresh copy $dest is not a readable directory" >&2
    return 1
  }
  if top=$(git -C "$real" rev-parse --show-toplevel 2>/dev/null); then
    top=$(cd "$top" 2>/dev/null && pwd -P) || top=
  fi
  [ -n "$top" ] || {
    echo "error: the fresh copy $dest is not a git worktree" >&2
    return 1
  }
  [ "$real" = "$top" ] || {
    echo "error: the fresh copy $dest is not a worktree root (root is $top)" >&2
    return 1
  }

  project=$(fm_meta_get "$meta" project)
  [ -n "$project" ] || { echo "error: task $id records no project, so the fresh copy cannot be tied to its repository" >&2; return 1; }
  project=$(cd "$project" 2>/dev/null && pwd -P) || {
    echo "error: task $id's recorded project cannot be resolved" >&2
    return 1
  }
  common=$(git -C "$real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && common=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  if project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    project_common=$(cd "$project_common" 2>/dev/null && pwd -P) || project_common=
  fi
  [ -n "$project_common" ] || {
    echo "error: task $id's recorded project is not a git repository" >&2
    return 1
  }
  git_dir=$(git -C "$real" rev-parse --absolute-git-dir 2>/dev/null) \
    && git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || return 1
  [ "$common" = "$project_common" ] || {
    echo "error: the fresh copy $dest is not a worktree of the same repository as task $id's project $project" >&2
    return 1
  }
  { [ "$real" != "$project" ] && [ "$git_dir" != "$common" ]; } || {
    echo "error: the fresh copy must be an isolated worktree of the repository, not the project's own checkout" >&2
    return 1
  }

  branch=$(fm_meta_get "$meta" branch)
  [ -n "$branch" ] || branch="fm/$id"
  checked=$(git -C "$real" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$checked" ] && [ "$checked" = "$branch" ] || {
    echo "error: the fresh copy's branch '${checked:-detached HEAD}' does not equal the recorded branch '$branch'" >&2
    return 1
  }
  status=$(git -C "$real" status --porcelain 2>/dev/null) || {
    echo "error: the fresh copy's status cannot be inspected" >&2
    return 1
  }
  [ -z "$status" ] || {
    echo "error: the fresh copy $dest has uncommitted changes that are not this task's; a fresh copy carries none" >&2
    return 1
  }

  head=$(fm_control_worktree_registered_head "$common" "$old") || return 1
  if [ -n "$head" ]; then heads+=("$head"); sources+=("registered-worktree"); fi
  journal="$state/$id.control-relaunch"
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    if [ ! -f "$journal" ] || [ -L "$journal" ] || ! cat "$journal" >/dev/null 2>&1; then
      echo "error: control journal $journal cannot be read, so recorded head evidence cannot be established" >&2
      return 1
    fi
    if [ "$(fm_meta_get "$journal" task)" = "$id" ]; then
      if [ "$(fm_meta_get "$journal" relocation_from)" = "$old" ] \
         || [ "$(fm_meta_get "$journal" relocation_to)" = "$old" ]; then
        head=$(fm_meta_get "$journal" relocation_head)
        if [ -n "$head" ]; then heads+=("$head"); sources+=("journal-relocation_head"); fi
      fi
      if [ "$(fm_meta_get "$journal" worktree)" = "$old" ]; then
        head=$(fm_meta_get "$journal" worktree_head)
        if [ -n "$head" ]; then heads+=("$head"); sources+=("journal-worktree_head"); fi
      fi
    fi
  fi
  head=$(fm_meta_get "$meta" pr_head)
  if [ -n "$head" ]; then heads+=("$head"); sources+=("meta-pr_head"); fi
  [ -n "${heads[*]-}" ] || {
    echo "error: no recorded head exists for branch '$branch', so the fresh copy cannot be shown to contain the task's work" >&2
    echo "  Re-create the copy with 'git worktree add -f <path> $branch' and do not run 'git worktree prune' first: the vanished copy's registration keeps its reflog head." >&2
    if [ -z "$(fm_meta_get "$meta" pr)" ]; then
      echo "  If the registration was already pruned, give a known commit of the branch: write one line, pr_head=<sha>, into the task record $meta." >&2
    else
      echo "  If the registration was already pruned, give the PR head or a known commit of the branch: write the three lines task=$id, worktree=$old, worktree_head=<sha> into the control journal $journal." >&2
    fi
    return 1
  }
  for i in "${!heads[@]}"; do
    head=${heads[$i]}
    source=${sources[$i]}
    case "$head" in
      *[!0-9a-fA-F]*) echo "error: the recorded head '$head' is not a full commit id" >&2; return 1 ;;
    esac
    [ "${#head}" = 40 ] || [ "${#head}" = 64 ] || {
      echo "error: the recorded head '$head' is not a full commit id" >&2
      return 1
    }
    git -C "$real" cat-file -e "$head^{commit}" 2>/dev/null || {
      echo "error: the recorded head $head ($source) is not in the repository, so the fresh copy cannot be shown to contain it" >&2
      return 1
    }
    git -C "$real" merge-base --is-ancestor "$head" HEAD 2>/dev/null || {
      echo "error: the fresh copy's HEAD does not contain the recorded head $head ($source); the branch was moved behind the task's work, so relocating would drop commits" >&2
      return 1
    }
    evidence="${evidence:+$evidence,}$source"
  done
  head=$(git -C "$real" rev-parse --verify HEAD) || return 1

  fm_local_firstmate_state_dirs "$state" || {
    echo "error: $FM_LOCAL_FIRSTMATE_ERROR, so the fresh copy's ownership cannot be ruled out" >&2
    return 1
  }
  for s in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$s" ] && { [ ! -d "$s" ] || [ ! -r "$s" ] || [ ! -x "$s" ]; }; then
      echo "error: local Firstmate state directory $s cannot be read, so the fresh copy's ownership cannot be ruled out" >&2
      return 1
    fi
    for other in "$s"/*.meta; do
      [ "${other##*/}" = "${meta##*/}" ] && [ "$other" -ef "$meta" ] && continue
      [ -e "$other" ] || [ -L "$other" ] || continue
      if [ ! -f "$other" ] || [ -L "$other" ] || ! cat "$other" >/dev/null 2>&1; then
        echo "error: another task record ($other) cannot be read, so the fresh copy's ownership cannot be ruled out" >&2
        return 1
      fi
      for field in worktree home; do
        owned=$(fm_meta_get "$other" "$field")
        [ -n "$owned" ] || continue
        if [ "$owned" = "$real" ] || [ "$(cd "$owned" 2>/dev/null && pwd -P)" = "$real" ]; then
          echo "error: the fresh copy $dest is recorded by another task ($(basename "$other" .meta)$([ "$s" -ef "$state" ] || printf ' of home %s' "${s%/state}"))" >&2
          return 1
        fi
      done
    done
  done
  # A Treehouse slot also carries a claim, written by whichever task took it.
  if declare -F fm_treehouse_pool_slot >/dev/null 2>&1 && fm_treehouse_pool_slot "$project" "$real"; then
    fm_treehouse_slot_owner_state "$real" "$id"
    case "$FM_TREEHOUSE_SLOT_OWNER" in
      absent) ;;
      mine)
        owner_home=$(cd "$FM_TREEHOUSE_SLOT_OWNER_HOME" 2>/dev/null && pwd -P) || owner_home=
        this_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || this_home=
        if [ -z "$FM_TREEHOUSE_SLOT_OWNER_HOME" ] || [ -z "$this_home" ] || [ "$owner_home" != "$this_home" ]; then
          echo "error: the pool slot $dest is claimed by task $id of home $FM_TREEHOUSE_SLOT_OWNER_HOME, not this home" >&2
          return 1
        fi
        ;;
      other)
        echo "error: the pool slot $dest is claimed by task $FM_TREEHOUSE_SLOT_OWNER_ID${FM_TREEHOUSE_SLOT_OWNER_HOME:+ (home $FM_TREEHOUSE_SLOT_OWNER_HOME)}, not by $id" >&2
        return 1
        ;;
      *)
        echo "error: the pool slot $dest carries a claim that cannot be read, so its owner cannot be established" >&2
        return 1
        ;;
    esac
  fi

  fm_control_worktree_wiring_free "$real" "$state" "$id" || return 1

  # These result variables are consumed by the sourcing caller.
  # shellcheck disable=SC2034
  FM_CONTROL_RELOCATION_PATH=$real
  # shellcheck disable=SC2034
  FM_CONTROL_RELOCATION_FROM=$old
  # shellcheck disable=SC2034
  FM_CONTROL_RELOCATION_HEAD=$head
  # shellcheck disable=SC2034
  FM_CONTROL_RELOCATION_HEAD_SOURCE=$evidence
}
