#!/usr/bin/env bash
# fm-control-worktree-lib.sh - read-only validation for explicit relaunch
# relocation. Both fm-control and fm-spawn --relaunch call this owner; neither
# allocates or moves a worktree. Requires fm-backend.sh's metadata helpers.
# Sets FM_CONTROL_RELOCATION_PATH and HEAD; refusals leave records untouched.
# A recorded commit comes from worktree_head or pr_head metadata, or the task's
# prior control journal bound to its recorded path. No current branch tip is
# substituted for missing historical evidence.

fm_control_worktree_relocation() { # <meta> <id> <state> <replacement>
  local meta=$1 id=$2 state=$3 replacement=$4 old kind project branch head journal
  local probe parent real top common project_common git_dir checked_branch other owned
  old=$(fm_meta_get "$meta" worktree)
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in ''|ship|scout) ;; *) echo 'error: --worktree relocation is for ships and scouts only' >&2; return 1 ;; esac
  case "$old" in
    /*) ;;
    *) echo 'error: the recorded worktree has no absolute path to prove absent' >&2; return 1 ;;
  esac
  case "$old" in
    */../*|*/./*|*/..|*/.) echo 'error: the recorded worktree path is not canonical enough to prove absent' >&2; return 1 ;;
  esac
  # Prove absence from a readable, searchable ancestor, not a failed -d test:
  # files, dangling symlinks and inaccessible ancestry are not missing copies.
  probe=$old
  while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    parent=${probe%/*}
    [ -n "$parent" ] || parent=/
    [ "$parent" != "$probe" ] || return 1
    if [ -d "$parent" ]; then
      [ -r "$parent" ] && [ -x "$parent" ] || {
        echo 'error: recorded worktree absence cannot be proven through unreadable ancestry' >&2; return 1;
      }
      break
    fi
    probe=$parent
  done
  if [ -e "$probe" ] || [ -L "$probe" ]; then
    echo 'error: recorded worktree still exists or its absence cannot be proven; --worktree refuses' >&2
    return 1
  fi
  real=$(cd "$replacement" 2>/dev/null && pwd -P) || {
    echo 'error: replacement worktree is not a readable directory' >&2; return 1;
  }
  top=$(git -C "$real" rev-parse --show-toplevel 2>/dev/null) &&
    top=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  [ "$real" = "$top" ] || { echo 'error: replacement is not a worktree root' >&2; return 1; }
  project=$(fm_meta_get "$meta" project)
  [ -n "$project" ] || { echo 'error: relocation requires a recorded project' >&2; return 1; }
  project=$(cd "$project" 2>/dev/null && pwd -P) || {
    echo 'error: the recorded project cannot be resolved' >&2; return 1;
  }
  [ "$real" != "$project" ] || {
    echo 'error: replacement cannot be the spawning project itself' >&2; return 1;
  }
  common=$(git -C "$real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    common=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    project_common=$(cd "$project_common" 2>/dev/null && pwd -P) || return 1
  git_dir=$(git -C "$real" rev-parse --absolute-git-dir 2>/dev/null) &&
    git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || return 1
  [ "$common" = "$project_common" ] && [ "$git_dir" != "$common" ] || {
    echo 'error: replacement must be an isolated worktree of the same repository' >&2; return 1;
  }
  branch=$(fm_meta_get "$meta" branch)
  checked_branch=$(git -C "$real" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] && [ "$branch" = "$checked_branch" ] || {
    echo 'error: replacement branch does not equal the recorded branch' >&2; return 1;
  }
  head=$(fm_meta_get "$meta" worktree_head)
  [ -n "$head" ] || head=$(fm_meta_get "$meta" pr_head)
  journal="$state/$id.control-relaunch"
  if [ -z "$head" ] && [ -f "$journal" ] && [ ! -L "$journal" ] &&
      [ "$(fm_meta_get "$journal" task)" = "$id" ]; then
    if [ "$(fm_meta_get "$journal" worktree)" = "$old" ]; then
      head=$(fm_meta_get "$journal" worktree_head)
    elif [ "$(fm_meta_get "$journal" relocation_from)" = "$old" ]; then
      head=$(fm_meta_get "$journal" relocation_head)
    fi
  fi
  case "$head" in
    ''|*[!0-9a-fA-F]*) echo 'error: relocation requires a recorded commit head; no branch-tip guess is allowed' >&2; return 1 ;;
  esac
  [ "${#head}" = 40 ] || [ "${#head}" = 64 ] || {
    echo 'error: recorded relocation head must be a full commit id' >&2; return 1;
  }
  if ! git -C "$real" cat-file -e "$head^{commit}" 2>/dev/null ||
      ! git -C "$real" merge-base --is-ancestor "$head" HEAD 2>/dev/null; then
    echo 'error: replacement HEAD does not contain the recorded head' >&2; return 1
  fi
  for other in "$state"/*.meta; do
    [ "$other" != "$meta" ] || continue
    [ -e "$other" ] || [ -L "$other" ] || continue
    if [ ! -f "$other" ] || [ -L "$other" ] || ! cat "$other" >/dev/null 2>&1; then
      echo 'error: another task record cannot be inspected for replacement ownership' >&2; return 1
    fi
    owned=$(fm_meta_get "$other" worktree)
    [ -n "$owned" ] || continue
    if [ "$owned" = "$real" ] || [ "$(cd "$owned" 2>/dev/null && pwd -P)" = "$real" ]; then
      echo "error: replacement worktree is recorded by another task ($(basename "$other" .meta))" >&2
      return 1
    fi
  done
  # These result variables are consumed by callers sourcing this library.
  # shellcheck disable=SC2034
  FM_CONTROL_RELOCATION_HEAD=$head
  # shellcheck disable=SC2034
  FM_CONTROL_RELOCATION_PATH=$real
}
