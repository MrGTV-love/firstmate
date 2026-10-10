#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_TASK_COPY_* are output globals for sourcing callers.
# Which local copy a task record may name.
#
# A task record's worktree= names the local copy its work lives in. Four
# callers must agree on what may be named there, so the rules live here once:
#   - bin/fm-spawn.sh admits only an isolated worktree of the project as a new
#     task's copy (fm_task_copy_isolated);
#   - bin/fm-teardown.sh refuses to return a pool slot that another task record
#     still names (fm_task_copy_other_record);
#   - bin/fm-spawn.sh and bin/fm-home-seed.sh refuse a Treehouse allocation
#     while a pool slot contains a task record's current copy
#     (fm_task_copy_pool_slots_hold_no_current_copy);
#   - bin/fm-control.sh reassociate re-points a record at a replacement copy only
#     when both hold for that copy and it shares the project's repository
#     (fm_task_copy_same_repository).
# A record's prior_worktree= lines name copies the task worked in before a
# reassociation that stay its preserved custody, so the record scan counts them
# exactly like worktree= and home=. A pool slot the task left entirely is
# released to the pool instead (its HEAD is anchored), so it is never one.
#
# Requires bin/fm-backend.sh (fm_meta_get), bin/fm-secondmate-parent-lib.sh
# (fm_firstmate_root_home), and bin/fm-wake-lib.sh to be sourced first;
# sources bin/fm-secondmate-registry-lib.sh itself when the caller has not.

FM_TASK_COPY_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
if ! declare -F secondmate_registry_parse_line >/dev/null 2>&1; then
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$FM_TASK_COPY_LIB_DIR/fm-secondmate-registry-lib.sh"
fi

# The physical path of an existing directory, or a failure.
fm_task_copy_canonical_dir() {  # <path>
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

fm_task_copy_paths_overlap() {  # <canonical-a> <canonical-b>
  local a=$1 b=$2
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  case "$a" in "$b"/*) return 0 ;; esac
  case "$b" in "$a"/*) return 0 ;; esac
  [ "$a" = / ] || [ "$b" = / ]
}

fm_task_copy_default_branch() {
  local project=$1 ref branch
  ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$project" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

fm_task_copy_content_in_default() {
  local worktree=$1 project=$2 name=${3:-} ref default_tree merged_tree
  [ -d "$worktree" ] || return 1
  [ -n "$name" ] || name=$(fm_task_copy_default_branch "$project") || return 1
  if git -C "$worktree" remote get-url origin >/dev/null 2>&1; then
    git -C "$worktree" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$worktree" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$worktree" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$worktree" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=${merged_tree%%$'\n'*}
  [ "$merged_tree" = "$default_tree" ]
}

fm_task_copy_dirty_status() {
  local status=$1 line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'?? .claude/'*|'?? .fm-grok-turnend'|'?? .fm-kimi-turnend') continue ;;
    esac
    printf '%s\n' "$line"
  done <<< "$status"
}

fm_task_copy_landed() {
  local worktree=$1 project=$2 dirty_raw dirty
  dirty_raw=$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null) || return 1
  dirty=$(fm_task_copy_dirty_status "$dirty_raw")
  [ -z "$dirty" ] || return 1
  fm_task_copy_content_in_default "$worktree" "$project"
}

# True when <path> is an isolated worktree of <project>: a real directory that
# is its own worktree root, is not the project checkout itself, and is not the
# repository's primary checkout. FM_TASK_COPY_TOP is left holding the worktree
# root the check read, and FM_TASK_COPY_REASON a short phrase naming why a
# rejected path failed, both for refusal messages.
FM_TASK_COPY_TOP=
FM_TASK_COPY_REASON=
fm_task_copy_isolated() {  # <path> <project>
  local path=$1 project=$2 wt_real wt_top_real wt_git_dir proj_real proj_common
  FM_TASK_COPY_TOP=
  FM_TASK_COPY_REASON=
  wt_real=
  if ! wt_real=$(cd "$path" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  if [ -z "$wt_real" ]; then
    FM_TASK_COPY_REASON="it is not a readable directory"
    return 1
  fi
  FM_TASK_COPY_TOP=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
  # A path in no repository leaves the toplevel empty, and that empty value must
  # never reach `cd`: bash before 5.3 accepts `cd ""` as a successful no-op, so
  # it would resolve to the caller's OWN cwd and report the path as a
  # subdirectory of whatever checkout firstmate happens to be running from.
  wt_top_real=
  if [ -n "$FM_TASK_COPY_TOP" ] && ! wt_top_real=$(cd "$FM_TASK_COPY_TOP" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_top_real" ]; then
    FM_TASK_COPY_REASON="it is not inside a git worktree"
    return 1
  fi
  if [ "$wt_real" != "$wt_top_real" ]; then
    FM_TASK_COPY_REASON="it is a subdirectory of worktree root '$wt_top_real', not a worktree root"
    return 1
  fi
  # The project may be spelled through a symlink; compare physical forms, and
  # fall back to the spelling given when it does not resolve.
  if ! proj_real=$(cd "$project" 2>/dev/null && pwd -P); then
    proj_real=$project
  fi
  if [ "$wt_real" = "$proj_real" ]; then
    FM_TASK_COPY_REASON="it is the project checkout itself"
    return 1
  fi
  # The primary checkout uses the repository's common git dir as its own git
  # dir. A linked project home has a different top-level, but the same common
  # dir, so comparing only the two working directories cannot protect primary.
  wt_git_dir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) &&
    wt_git_dir=$(cd "$wt_git_dir" 2>/dev/null && pwd -P) || wt_git_dir=
  proj_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    proj_common=$(cd "$proj_common" 2>/dev/null && pwd -P) || proj_common=
  if [ -z "$wt_git_dir" ] || [ -z "$proj_common" ]; then
    FM_TASK_COPY_REASON="its git directory could not be resolved"
    return 1
  fi
  if [ "$wt_git_dir" = "$proj_common" ]; then
    FM_TASK_COPY_REASON="it is the repository's primary checkout (its git dir is the project's common git dir)"
    return 1
  fi
  return 0
}

# True when <path> is a checkout of the same repository as <project>: both
# resolve to one Git common directory. An isolated worktree of some other
# repository passes fm_task_copy_isolated but fails this.
fm_task_copy_same_repository() {  # <path> <project>
  local path=$1 project=$2 path_common proj_common
  path_common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    path_common=$(cd "$path_common" 2>/dev/null && pwd -P) || return 1
  proj_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    proj_common=$(cd "$proj_common" 2>/dev/null && pwd -P) || return 1
  [ "$path_common" = "$proj_common" ]
}

# The local copies a task record names, one "<field> <path>" line each: the
# last worktree= and home= values (the values every reader of those fields
# uses) and every prior_worktree= line.
fm_task_copy_record_paths() {  # <meta>
  local meta=$1 value line
  for value in worktree home; do
    line=$(fm_meta_get "$meta" "$value")
    [ -z "$line" ] || printf '%s %s\n' "$value" "$line"
  done
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      prior_worktree=?*) printf 'prior_worktree %s\n' "${line#prior_worktree=}" ;;
    esac
  done < "$meta" 2>/dev/null || true
}

fm_task_copy_ancestor_current() {
  local meta=$1 state=$2 field=$3 copy=$4 target=$5 home owner parent id depth=0
  case "$field" in worktree|home) ;; *) return 1 ;; esac
  case "$target" in "$copy"/*) ;; *) return 1 ;; esac
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || return 1
  owner=$(fm_meta_get "$meta" home)
  [ -n "$owner" ] || owner=$(fm_meta_get "$meta" worktree)
  owner=$(fm_task_copy_canonical_dir "$owner") || return 1
  home=$(fm_task_copy_canonical_dir "$state") || return 1
  home=${home%/*}
  while [ "$depth" -lt 64 ]; do
    fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 1
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
    parent=$(fm_task_copy_canonical_dir "$FM_SECONDMATE_PARENT_HOME") || return 1
    if [ "$home" = "$owner" ]; then
      [ "${meta%/*}" -ef "$parent/state" ] || return 1
      id=${meta##*/}
      id=${id%.meta}
      secondmate_registry_validate_bindings "$parent/data/secondmates.md" \
        secondmate_registry_path_key "$id" "$home" || return 1
      [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" = 0 ]
      return
    fi
    home=$parent
    depth=$((depth + 1))
  done
  return 1
}

# Whether a task record in this home or any locally registered Firstmate home
# names a canonical copy overlapping <path> in worktree=, home=, or
# prior_worktree=. The current record is excluded. Returns 0 on overlap, setting
# FM_TASK_COPY_OTHER_ID and FM_TASK_COPY_OTHER_FIELD;
# 1 for no overlap or a missing path; 2 when the scan cannot be completed.
#
# Identity, not spelling: the same record reached through a differently
# resolved state dir (e.g. a symlinked $FM_HOME) is still <record-meta>. A
# differently named hardlink is another task's record, so the name must match
# too.
FM_TASK_COPY_OTHER_ID=
FM_TASK_COPY_OTHER_FIELD=
fm_task_copy_other_record() {  # <record-meta> <record-state> <path>
  local record_meta=$1 record_state=$2 path=$3
  local target state_dir other_meta line field other_path other_real
  FM_TASK_COPY_OTHER_ID=
  FM_TASK_COPY_OTHER_FIELD=
  target=$(fm_task_copy_canonical_dir "$path") || return 1
  fm_local_firstmate_state_dirs "$record_state" || {
    echo "REFUSED: $FM_LOCAL_FIRSTMATE_ERROR; nothing was changed" >&2
    return 2
  }
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for other_meta in "$state_dir"/*.meta; do
      [ -f "$other_meta" ] && [ ! -L "$other_meta" ] || continue
      [ "${other_meta##*/}" = "${record_meta##*/}" ] && [ "$other_meta" -ef "$record_meta" ] && continue
      while IFS= read -r line || [ -n "$line" ]; do
        field=${line%% *}
        other_path=${line#* }
        [ -n "$other_path" ] || continue
        other_real=$(fm_task_copy_canonical_dir "$other_path") || continue
        fm_task_copy_paths_overlap "$other_real" "$target" || continue
        fm_task_copy_ancestor_current "$other_meta" "$record_state" "$field" "$other_real" "$target" && continue
        FM_TASK_COPY_OTHER_ID=$(basename "$other_meta" .meta)
        FM_TASK_COPY_OTHER_FIELD=$field
        return 0
      done < <(fm_task_copy_record_paths "$other_meta")
    done
  done
  return 1
}

# The pool slot of <project> that strictly contains <canonical-path>, or a
# failure when none does.
fm_task_copy_enclosing_pool_slot() {  # <project> <canonical-path>
  local project=$1 dir=${2%/*}
  while [ -n "$dir" ]; do
    if [ -f "${dir%/*/*}/treehouse-state.json" ] && fm_treehouse_pool_slot "$project" "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=${dir%/*}
  done
  return 1
}

# True when no pool slot of <project> strictly contains the current copy
# (worktree=) of a task record in this home or any locally registered Firstmate
# home. treehouse get resets whichever slot it hands out, so a slot holding a
# live record's nested copy must not be allocated; a slot a task merely left is
# not a record's current copy and stays allocatable. A registered local home
# that cannot be read is named in one warning line and skipped: one broken home
# must not stop every allocation for a project.
fm_task_copy_pool_slots_hold_no_current_copy() {  # <project> <record-state>
  local project=$1 record_state=$2 state_dir meta copy slot skipped
  fm_local_firstmate_state_dirs "$record_state" tolerant
  for skipped in ${FM_LOCAL_FIRSTMATE_SKIPPED[@]+"${FM_LOCAL_FIRSTMATE_SKIPPED[@]}"}; do
    echo "warning: $skipped; its task records were not checked for a current copy inside a Treehouse pool slot" >&2
  done
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      copy=$(fm_meta_get "$meta" worktree)
      copy=$(fm_task_copy_canonical_dir "$copy") || continue
      slot=$(fm_task_copy_enclosing_pool_slot "$project" "$copy") || continue
      echo "error: Treehouse pool slot $slot contains task $(basename "$meta" .meta)'s current copy $copy; refusing allocation before treehouse get" >&2
      return 1
    done
  done
}
