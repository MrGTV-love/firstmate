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
#     while a pool slot that Treehouse's state does not durably hold contains a
#     task record's current copy (fm_task_copy_pool_slots_hold_no_current_copy);
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

# A failed content check is no verdict on the work while FM_TASK_COPY_UNASKED
# names why: it is cleared only once the check compared the two trees, and a
# merge conflict is that comparison's answer.
FM_TASK_COPY_UNASKED=
fm_task_copy_content_in_default() {  # <worktree> <project> [<default-branch>] [<head-ref>]
  local worktree=$1 project=$2 name=${3:-} head=${4:-HEAD} ref default_tree merged_tree
  FM_TASK_COPY_UNASKED='the content check could not compare with the default branch'
  [ -d "$worktree" ] || return 1
  [ -n "$name" ] || name=$(fm_task_copy_default_branch "$project") || return 1
  if git -C "$worktree" remote get-url origin >/dev/null 2>&1; then
    git -C "$worktree" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || {
      FM_TASK_COPY_UNASKED="origin/$name could not be fetched"
      return 1
    }
    ref="refs/remotes/origin/$name"
  elif git -C "$worktree" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$worktree" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$worktree" merge-tree --write-tree "$ref" "$head" 2>/dev/null) || {
    [ "$?" != 1 ] || FM_TASK_COPY_UNASKED=
    return 1
  }
  FM_TASK_COPY_UNASKED=
  merged_tree=${merged_tree%%$'\n'*}
  [ "$merged_tree" = "$default_tree" ]
}

# The porcelain status lines of <copy> that are its own uncommitted work:
# Firstmate's hook files do not count, and neither does the untracked entry of
# each of the task's own <nested-copy> paths inside <copy>, since each of those
# is preserved or proved on its own.
fm_task_copy_dirty_status() {  # <porcelain-status> [<copy> <nested-copy>...]
  local status=$1 copy=${2:-} line nested
  shift
  [ "$#" -eq 0 ] || shift
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'?? .claude/'*|'?? .fm-grok-turnend'|'?? .fm-kimi-turnend') continue ;;
    esac
    for nested in "$@"; do
      case "$nested" in
        "$copy"/*) [ "$line" != "?? ${nested#"$copy"/}/" ] || continue 2 ;;
      esac
    done
    printf '%s\n' "$line"
  done <<< "$status"
}

# The canonical paths of the task's own prior_worktree= copies that lie strictly
# inside <slot>: the copies a reset or release of that slot would sweep away.
# Shared by bin/fm-control.sh reassociate and bin/fm-teardown.sh.
fm_task_copy_priors_inside() {  # <meta> <slot>
  local meta=$1 slot=$2 line prior_real
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in prior_worktree=?*) ;; *) continue ;; esac
    prior_real=$(fm_task_copy_canonical_dir "${line#prior_worktree=}") || continue
    case "$prior_real" in "$slot"/*) printf '%s\n' "$prior_real" ;; esac
  done < "$meta"
}

# The one rule for a task's own copy that a pool slot reset or release may
# sweep away, shared by bin/fm-control.sh reassociate and bin/fm-teardown.sh:
# <copy> must be a clean Git worktree root (fm_task_copy_dirty_status, with the
# task's own <nested-copy> paths) whose HEAD a refs/fm/anchor/<task>-<sha>
# preservation anchor in <project> holds. With <write> 1 a missing anchor is
# written and verified; with 0 nothing is written and a missing anchor returns
# 2. FM_TASK_COPY_HEAD and FM_TASK_COPY_ANCHOR name the HEAD and its anchor.
# Any other failure returns 1 with FM_TASK_COPY_REASON, a clause following the
# copy's path, and FM_TASK_COPY_DIRTY listing any dirt. A failure that stays the
# same until someone decides (not a worktree root, unresolved HEAD, an anchor
# naming another commit) also sets FM_TASK_COPY_STABLE to its predicate id; a
# Git read or write failure leaves it empty.
FM_TASK_COPY_HEAD=
FM_TASK_COPY_ANCHOR=
FM_TASK_COPY_DIRTY=
FM_TASK_COPY_STABLE=
fm_task_copy_preserve() {  # <project> <task> <copy> <write> [<nested-copy>...]
  local project=$1 task=$2 copy=$3 write=$4 top status ref short current
  shift 4
  FM_TASK_COPY_HEAD=
  FM_TASK_COPY_ANCHOR=
  FM_TASK_COPY_DIRTY=
  FM_TASK_COPY_STABLE=
  FM_TASK_COPY_REASON=
  top=$(git -C "$copy" rev-parse --show-toplevel 2>/dev/null) \
    && top=$(fm_task_copy_canonical_dir "$top") && [ "$top" = "$copy" ] || {
    FM_TASK_COPY_STABLE='copy-worktree-root'
    FM_TASK_COPY_REASON="is not a Git worktree root, so its contents cannot be proved preserved"
    return 1
  }
  status=$(git -C "$copy" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || {
    FM_TASK_COPY_REASON="cannot be inspected for uncommitted changes"
    return 1
  }
  FM_TASK_COPY_DIRTY=$(fm_task_copy_dirty_status "$status" "$copy" "$@")
  if [ -n "$FM_TASK_COPY_DIRTY" ]; then
    FM_TASK_COPY_REASON="has uncommitted or untracked-unignored changes"
    return 1
  fi
  FM_TASK_COPY_HEAD=$(git -C "$copy" rev-parse --verify --quiet 'HEAD^{commit}') || {
    FM_TASK_COPY_STABLE='copy-head-resolved'
    FM_TASK_COPY_REASON="has a HEAD that cannot be resolved"
    return 1
  }
  while IFS= read -r ref; do
    short=${ref#"refs/fm/anchor/$task-"}
    case "$short" in ''|*[!0-9a-f]*) continue ;; esac
    case "$FM_TASK_COPY_HEAD" in
      "$short"*)
        FM_TASK_COPY_ANCHOR=$ref
        return 0
        ;;
    esac
  done < <(git -C "$project" for-each-ref --points-at "$FM_TASK_COPY_HEAD" --format='%(refname)' "refs/fm/anchor/$task-*" 2>/dev/null)
  short=$(git -C "$copy" rev-parse --short "$FM_TASK_COPY_HEAD") || {
    FM_TASK_COPY_REASON="has a HEAD $FM_TASK_COPY_HEAD that could not be named for its preservation anchor"
    return 1
  }
  FM_TASK_COPY_ANCHOR="refs/fm/anchor/$task-$short"
  if git -C "$project" rev-parse --verify --quiet "$FM_TASK_COPY_ANCHOR" >/dev/null; then
    FM_TASK_COPY_STABLE='copy-anchor-commit'
    FM_TASK_COPY_REASON="cannot be anchored: preservation anchor $FM_TASK_COPY_ANCHOR already names a different commit"
    return 1
  fi
  [ "$write" = 1 ] || return 2
  git -C "$project" update-ref "$FM_TASK_COPY_ANCHOR" "$FM_TASK_COPY_HEAD" "" || {
    FM_TASK_COPY_REASON="could not be anchored: writing $FM_TASK_COPY_ANCHOR at $FM_TASK_COPY_HEAD failed"
    return 1
  }
  current=$(git -C "$project" rev-parse --verify "$FM_TASK_COPY_ANCHOR") \
    && [ "$current" = "$FM_TASK_COPY_HEAD" ] || {
    FM_TASK_COPY_REASON="could not be anchored: $FM_TASK_COPY_ANCHOR could not be verified at $FM_TASK_COPY_HEAD"
    return 1
  }
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

# Prints the canonical path of every worktree <canonical-clone> has registered
# strictly inside itself, one per line. A registered copy whose directory is
# gone keeps its raw path. Fails when the registration list cannot be read, so a
# caller never takes an unreadable list for an empty one.
fm_task_copy_registered_nested() {  # <canonical-clone>
  local clone=$1 field path canon
  while IFS= read -r -d '' field; do
    case "$field" in
      registration-list-unreadable) return 1 ;;
      'worktree '*) path=${field#worktree } ;;
      *) continue ;;
    esac
    canon=$(fm_task_copy_canonical_dir "$path") || canon=$path
    case "$canon" in "$clone"/*) printf '%s\n' "$canon" ;; esac
  done < <(git -C "$clone" worktree list --porcelain -z 2>/dev/null || printf '\0registration-list-unreadable\0')
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
# prior_worktree=. The current record is excluded, and so is every optional
# <skip-meta> record: bin/fm-control.sh reassociate passes the records it
# re-points together in one call, and checks those against each other itself.
# Returns 0 on overlap, setting FM_TASK_COPY_OTHER_ID and
# FM_TASK_COPY_OTHER_FIELD;
# 1 for no overlap or a missing path; 2 when the scan cannot be completed.
#
# Identity, not spelling: the same record reached through a differently
# resolved state dir (e.g. a symlinked $FM_HOME) is still <record-meta>. A
# differently named hardlink is another task's record, so the name must match
# too.
#
# A caller that sets FM_TASK_COPY_RELEASED_PRIOR_RETIRING to the retiring task's
# own record meta also passes over an overlap that is only another record's
# released root (fm_task_copy_prior_root_released); every other caller, and every
# other overlap, still counts.
FM_TASK_COPY_OTHER_ID=
FM_TASK_COPY_OTHER_FIELD=
FM_TASK_COPY_RELEASED_PRIOR_RETIRING=
fm_task_copy_other_record() {  # <record-meta> <record-state> <path> [<skip-meta>...]
  local record_meta=$1 record_state=$2 path=$3
  local target state_dir other_meta line field other_path other_real skip
  shift 3
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
      for skip in "$@"; do
        [ "${other_meta##*/}" = "${skip##*/}" ] && [ "$other_meta" -ef "$skip" ] && continue 2
      done
      while IFS= read -r line || [ -n "$line" ]; do
        field=${line%% *}
        other_path=${line#* }
        [ -n "$other_path" ] || continue
        other_real=$(fm_task_copy_canonical_dir "$other_path") || continue
        fm_task_copy_paths_overlap "$other_real" "$target" || continue
        fm_task_copy_ancestor_current "$other_meta" "$record_state" "$field" "$other_real" "$target" && continue
        if [ "$field" = prior_worktree ] && [ -n "$FM_TASK_COPY_RELEASED_PRIOR_RETIRING" ] \
           && fm_task_copy_prior_root_released "$other_meta" "$other_real" "$target" \
             "$FM_TASK_COPY_RELEASED_PRIOR_RETIRING" "${FM_LOCAL_FIRSTMATE_STATES[@]}"; then
          continue
        fi
        FM_TASK_COPY_OTHER_ID=$(basename "$other_meta" .meta)
        FM_TASK_COPY_OTHER_FIELD=$field
        return 0
      done < <(fm_task_copy_record_paths "$other_meta")
    done
  done
  return 1
}

# Whether the prior_worktree= <root> of record <other-meta> is a pool slot root
# that task has left, so that it does not keep <target>, a copy of the retiring
# task strictly inside <root>, from being cleaned up. bin/fm-control.sh
# reassociate leaves two live records in this shape when it re-points them
# together off one slot root: each now works in its own copy nested in the root,
# and each names the root as prior_worktree=. All of these must hold, and any
# other shape keeps the overlap:
#   - <other-meta> is a ship or scout record, not an Orca task, and <root> is a
#     Treehouse pool slot of its project;
#   - its current copy (worktree=) lies strictly inside <root> and neither
#     contains, equals, nor lies inside <target>, so the record has been
#     re-pointed away from the root and its own copy is untouched;
#   - the retiring task is itself re-pointed off the root: <retiring-meta> names
#     <root> as a prior_worktree= of its own;
#   - no other record, apart from <other-meta> and the retiring task's
#     <retiring-meta>, still names <root> or a directory enclosing it as worktree=
#     or home=; a copy of some record inside <root> belongs to that record.
# <state-dir>... are the local Firstmate state directories to scan, as
# fm_local_firstmate_state_dirs produced them. <root> and <target> are canonical.
fm_task_copy_prior_root_released() {  # <other-meta> <root> <target> <retiring-meta> <state-dir>...
  local other=$1 root=$2 target=$3 retiring=$4 kind project wt state_dir meta field path real line named
  shift 4
  case "$target" in "$root"/*) ;; *) return 1 ;; esac
  kind=$(fm_meta_get "$other" kind)
  case "${kind:-ship}" in ship|scout) ;; *) return 1 ;; esac
  [ -z "$(fm_meta_get "$other" orca_worktree_id)" ] || return 1
  project=$(fm_meta_get "$other" project)
  [ -n "$project" ] && fm_treehouse_pool_slot "$project" "$root" || return 1
  wt=$(fm_task_copy_canonical_dir "$(fm_meta_get "$other" worktree)") || return 1
  case "$wt" in "$root"/*) ;; *) return 1 ;; esac
  ! fm_task_copy_paths_overlap "$wt" "$target" || return 1
  named=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in prior_worktree=?*) ;; *) continue ;; esac
    [ "$(fm_task_copy_canonical_dir "${line#prior_worktree=}" 2>/dev/null)" != "$root" ] || named=1
  done < "$retiring"
  [ "$named" = 1 ] || return 1
  for state_dir in "$@"; do
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "${meta##*/}" = "${other##*/}" ] && [ "$meta" -ef "$other" ] && continue
      [ "${meta##*/}" = "${retiring##*/}" ] && [ "$meta" -ef "$retiring" ] && continue
      for field in worktree home; do
        path=$(fm_meta_get "$meta" "$field")
        [ -n "$path" ] || continue
        real=$(fm_task_copy_canonical_dir "$path") || continue
        fm_task_copy_paths_overlap "$real" "$root" || continue
        case "$real" in "$root"/*) continue ;; esac
        return 1
      done
    done
  done
  return 0
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

# The lease holder Treehouse writes on every entry it rebuilds from a corrupt
# or truncated state file. Treehouse 3.1.0 and later free such an entry on their
# own, under the state lock of whichever pool command runs next (treehouse get
# included), once the slot is idle, tracked-clean, and landed; an ordinary lease
# is released only by treehouse return.
FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER='recovered: state file was corrupt or truncated; verify before reuse'

# Whether Treehouse's own pool state durably holds pool slot <slot>, so that
# treehouse get cannot hand it out. treehouse get reuses only a slot its state
# file records as not leased (`treehouse get --help`: a leased worktree is never
# handed out by a later get until treehouse return releases it); a live owner
# process, dirt, or an unmerged HEAD also make a get skip a slot, but each of
# those can change before the get runs, so none of them counts here. Every
# entry naming <slot>'s directory, however its path is spelled, must be leased:
# an ordinary lease holds; a
# recovered lease (FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER) holds only when
# <slot> is one of the given local Firstmate <home> directories, since a home
# freed and handed out is lost whole, nested copies or not. Reading the state
# needs jq; without it, with an unreadable state file, with no entry for
# <slot>, or with any relative or TSV-escaped entry path in the state, the slot
# is not proved held.
# Sets FM_TASK_COPY_SLOT_NAME to the slot's name in Treehouse state (the name
# treehouse status and treehouse lease use), or empty when no entry records
# <slot>; FM_TASK_COPY_SLOT_STATE to held, unleased, conflicting, recovered,
# escaped, relative, missing-jq, or unknown; FM_TASK_COPY_SLOT_HOLDER to the lease
# holder of the last leased entry that records <slot>, or empty; and on failure
# FM_TASK_COPY_SLOT_REASON to a clause following the slot's path.
# Returns 0 when held, 1 otherwise.
# The last state file read and its entries are kept in
# FM_TASK_COPY_POOL_STATE_FILE and FM_TASK_COPY_POOL_STATE_ENTRIES, so a scan
# reads each pool's state once; a scan clears both before it starts.
FM_TASK_COPY_SLOT_NAME=
FM_TASK_COPY_SLOT_HOLDER=
FM_TASK_COPY_SLOT_STATE=
FM_TASK_COPY_SLOT_REASON=
FM_TASK_COPY_POOL_STATE_FILE=
FM_TASK_COPY_POOL_STATE_ENTRIES=
fm_task_copy_pool_slot_held() {  # <slot> [<home>...]
  local slot=$1 state leaf entries name leased holder path home matched=0 is_home=0
  local has_unleased=0 has_recovered=0 named=0
  shift
  state="${slot%/*/*}/treehouse-state.json"
  leaf=${slot#"${slot%/*/*}"}
  FM_TASK_COPY_SLOT_NAME=
  FM_TASK_COPY_SLOT_HOLDER=
  FM_TASK_COPY_SLOT_STATE=unknown
  FM_TASK_COPY_SLOT_REASON=
  if ! command -v jq >/dev/null 2>&1; then
    FM_TASK_COPY_SLOT_STATE=missing-jq
    FM_TASK_COPY_SLOT_REASON="cannot be proved leased: reading Treehouse state $state needs jq, which is not installed"
    return 1
  fi
  # One line per entry. Each field carries a one-letter prefix so none is ever
  # empty: tab is IFS whitespace, so read would otherwise merge an empty field
  # into its neighbour.
  if [ "$state" = "$FM_TASK_COPY_POOL_STATE_FILE" ]; then
    entries=$FM_TASK_COPY_POOL_STATE_ENTRIES
  else
    entries=$(jq -r '.worktrees[]? | [("L" + (if .leased == true then "leased" else "unleased" end)), ("H" + (.lease_holder // "" | tostring)), ("N" + (.name // "" | tostring)), ("P" + (.path // "" | tostring))] | @tsv' "$state" 2>/dev/null) || {
      FM_TASK_COPY_SLOT_REASON="cannot be proved leased: Treehouse state $state cannot be read"
      return 1
    }
    FM_TASK_COPY_POOL_STATE_FILE=$state
    FM_TASK_COPY_POOL_STATE_ENTRIES=$entries
  fi
  for home in "$@"; do
    [ "$home" != "$slot" ] || is_home=1
  done
  while IFS=$'\t' read -r leased holder name path; do
    path=${path#P}
    [ -n "$path" ] || continue
    # @tsv escapes backslashes and line/field separators; relative paths
    # depend on the caller's working directory. Neither can prove identity.
    case "$path" in
      *\\*)
        FM_TASK_COPY_SLOT_STATE=escaped
        FM_TASK_COPY_SLOT_REASON="cannot be proved leased: Treehouse state $state contains an escaped entry path for entry '${name#N}': '$path' (TSV-escaped), which cannot be compared safely"
        return 1
        ;;
      /*) ;;
      *)
        FM_TASK_COPY_SLOT_STATE=relative
        FM_TASK_COPY_SLOT_REASON="cannot be proved leased: Treehouse state $state contains a relative entry path for entry '${name#N}': '$path'"
        return 1
        ;;
    esac
    if [ "$path" != "$slot" ]; then
      # Only ordinary leased entries may be skipped by their raw suffix:
      # skipping an unleased or recovered-lease alias can hide a conflict
      # with a matching leased entry.
      case "$leased$holder" in
        Lunleased*|"LleasedH$FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER") ;;
        *) [ "${path#"${path%/*/*}"}" = "$leaf" ] || continue ;;
      esac
      # Bash's inode/device comparison resolves aliases without a subshell
      # and cd/pwd for every entry that reaches it in an unmatched scan.
      [ "$path" -ef "$slot" ] || continue
    fi
    matched=$((matched + 1))
    FM_TASK_COPY_SLOT_NAME=${name#N}
    [ "${leased#L}" != leased ] || FM_TASK_COPY_SLOT_HOLDER=${holder#H}
    if [ "${leased#L}" != leased ]; then
      has_unleased=1
    elif [ "${holder#H}" = "$FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER" ] && [ "$is_home" = 0 ]; then
      has_recovered=1
    fi
  done <<< "$entries"
  if [ "$has_unleased" = 1 ]; then
    if [ "$matched" = 1 ]; then
      # Ordinary leases safely skipped on the held path still affect the
      # remedy: any leased directory alias makes this a mixed slot, and a
      # duplicate name makes LeaseExisting select only its first record.
      while IFS=$'\t' read -r leased holder name path; do
        [ "${name#N}" != "$FM_TASK_COPY_SLOT_NAME" ] || named=$((named + 1))
        if [ "$leased" = Lleased ] && [ "${path#P}" -ef "$slot" ]; then
          matched=$((matched + 1))
          break
        fi
        [ "$named" -le 1 ] || break
      done <<< "$entries"
    fi
    if [ "$matched" -gt 1 ] || [ "$named" -gt 1 ]; then
      # LeaseExisting changes only the first entry with a given name: one
      # lease cannot reliably clear duplicate records in either entry order.
      FM_TASK_COPY_SLOT_STATE=conflicting
      FM_TASK_COPY_SLOT_REASON="has conflicting lease records in Treehouse state $state, including an unleased entry, so its hold cannot be proved"
    else
      FM_TASK_COPY_SLOT_STATE=unleased
      FM_TASK_COPY_SLOT_REASON="is not leased in Treehouse state $state, so treehouse get may hand it out"
    fi
    return 1
  fi
  if [ "$has_recovered" = 1 ]; then
    FM_TASK_COPY_SLOT_STATE=recovered
    FM_TASK_COPY_SLOT_REASON="is not a Firstmate home and carries Treehouse's recovered-state lease in $state, which Treehouse 3.1.0 and later release on their own once the slot is idle, clean, and landed"
    return 1
  fi
  if [ "$matched" -gt 0 ]; then
    FM_TASK_COPY_SLOT_STATE=held
    return 0
  fi
  FM_TASK_COPY_SLOT_REASON="has no entry in Treehouse state $state, so its lease cannot be proved"
  return 1
}

# The folder name Treehouse gives <project>'s pool today: the checkout's
# directory name, a dash, and the first six hex digits of the SHA-256 of the
# origin URL git reports for it.
fm_task_copy_current_pool_folder() {  # <project>
  local project=$1 top origin hash
  top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] || return 1
  origin=$(git -C "$project" remote get-url origin 2>/dev/null) && [ -n "$origin" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$origin" | shasum -a 256 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$origin" | sha256sum 2>/dev/null) || return 1
  else
    return 1
  fi
  [ "${#hash}" -ge 6 ] || return 1
  printf '%s-%s\n' "${top##*/}" "${hash:0:6}"
}

# treehouse status --json run from <project>, read once per process and kept,
# with a failed read kept as an empty listing, for every later call: one
# teardown reuses it across all its descendants. Sets
# FM_TASK_COPY_CURRENT_POOL_JSON; returns 0 only when the listing was read.
FM_TASK_COPY_CURRENT_POOL_JSON=
FM_TASK_COPY_POOL_LISTING_PROJECTS=()
FM_TASK_COPY_POOL_LISTINGS=()
fm_task_copy_current_pool_listing() {  # <project>
  local project=$1 i json=
  for ((i = 0; i < ${#FM_TASK_COPY_POOL_LISTING_PROJECTS[@]}; i++)); do
    [ "${FM_TASK_COPY_POOL_LISTING_PROJECTS[$i]}" = "$project" ] || continue
    FM_TASK_COPY_CURRENT_POOL_JSON=${FM_TASK_COPY_POOL_LISTINGS[$i]}
    [ -n "$FM_TASK_COPY_CURRENT_POOL_JSON" ]
    return
  done
  if command -v treehouse >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    json=$(cd "$project" 2>/dev/null && treehouse status --json </dev/null 2>/dev/null) \
      && jq -e 'type == "array"' <<<"$json" >/dev/null 2>&1 || json=
  fi
  FM_TASK_COPY_POOL_LISTING_PROJECTS+=("$project")
  FM_TASK_COPY_POOL_LISTINGS+=("$json")
  FM_TASK_COPY_CURRENT_POOL_JSON=$json
  [ -n "$json" ]
}

# Where pool slot <slot>, named <state-name> in its own pool folder's state, stands
# against the pool Treehouse resolves for <project> today. Treehouse names a
# pool folder as fm_task_copy_current_pool_folder derives it, so repointing
# origin moves the project to a new, initially empty folder and leaves earlier
# copies in the old one, whose state file still records them. treehouse get
# allocates from the current pool only, and treehouse lease and treehouse
# return <name> resolve a slot NAME there, so a name taken from an older
# folder's state would act on a different copy that shares it. A slot whose
# folder has the current folder's name is in the current pool, with no
# treehouse status call; otherwise only a path that the status listing
# (fm_task_copy_current_pool_listing) holds is.
# Sets FM_TASK_COPY_POOL_CURRENCY to current (and FM_TASK_COPY_CURRENT_SLOT_NAME
# to the name the current pool gives <slot>), superseded (the listing was read
# and does not hold <slot>), or unknown (the listing could not be read).
# Returns 0 only for current.
FM_TASK_COPY_POOL_CURRENCY=
FM_TASK_COPY_CURRENT_SLOT_NAME=
fm_task_copy_slot_in_current_pool() {  # <project> <slot> <state-name>
  local project=$1 slot=$2 state_name=$3 pool folder listing name path
  FM_TASK_COPY_POOL_CURRENCY=unknown
  FM_TASK_COPY_CURRENT_SLOT_NAME=
  pool=${slot%/*/*}
  if [ -n "$state_name" ] && folder=$(fm_task_copy_current_pool_folder "$project") \
      && [ "${pool##*/}" = "$folder" ]; then
    FM_TASK_COPY_POOL_CURRENCY=current
    FM_TASK_COPY_CURRENT_SLOT_NAME=$state_name
    return 0
  fi
  fm_task_copy_current_pool_listing "$project" || return 1
  listing=$(jq -r '.[] | ["N" + (.name // "" | tostring), "P" + (.path // "" | tostring)] | @tsv' \
    <<<"$FM_TASK_COPY_CURRENT_POOL_JSON" 2>/dev/null) || return 1
  FM_TASK_COPY_POOL_CURRENCY=superseded
  while IFS=$'\t' read -r name path; do
    path=${path#P}
    [ -n "$path" ] || continue
    if [ "$path" = "$slot" ] || [ "$path" -ef "$slot" ]; then
      FM_TASK_COPY_POOL_CURRENCY=current
      FM_TASK_COPY_CURRENT_SLOT_NAME=${name#N}
      return 0
    fi
  done <<< "$listing"
  return 1
}

# True when no pool slot of <project> that treehouse get could hand out strictly
# contains the current copy (worktree=) of a task record in this home or any
# locally registered Firstmate home. treehouse get resets and reassigns the slot
# it hands out, so a slot holding a live record's nested copy must not be
# allocatable; a slot Treehouse's state durably holds
# (fm_task_copy_pool_slot_held) is never handed out, whatever lies inside it,
# nor is an unleased slot in a superseded pool folder
# (fm_task_copy_slot_in_current_pool), which is judged again at each call, and a
# slot a task merely left is not a record's current copy, so none of them
# stops the allocation. A uniquely recorded unleased slot names the treehouse
# lease command that holds it in place without touching it; teardown's
# treehouse return releases that lease with the slot. Conflicting records
# instead need inspection and repair: lease selects only the first matching
# name, so it cannot reliably clear that refusal. No other refusal names a
# lease as a remedy. A registered local home
# that cannot be read is named in one warning line and skipped: one broken home
# must not stop every allocation for a project.
fm_task_copy_pool_slots_hold_no_current_copy() {  # <project> <record-state>
  local project=$1 record_state=$2 state_dir meta copy slot skipped id home remedy
  local -a homes=()
  FM_TASK_COPY_POOL_STATE_FILE=
  FM_TASK_COPY_POOL_STATE_ENTRIES=
  fm_local_firstmate_state_dirs "$record_state" tolerant
  for skipped in ${FM_LOCAL_FIRSTMATE_SKIPPED[@]+"${FM_LOCAL_FIRSTMATE_SKIPPED[@]}"}; do
    echo "warning: $skipped; its task records were not checked for a current copy inside a Treehouse pool slot" >&2
  done
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    home=$(fm_task_copy_canonical_dir "${state_dir%/*}") && homes+=("$home")
  done
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      copy=$(fm_meta_get "$meta" worktree)
      copy=$(fm_task_copy_canonical_dir "$copy") || continue
      slot=$(fm_task_copy_enclosing_pool_slot "$project" "$copy") || continue
      fm_task_copy_pool_slot_held "$slot" ${homes[@]+"${homes[@]}"} || true
      id=$(basename "$meta" .meta)
      case "$FM_TASK_COPY_SLOT_STATE" in
        held) continue ;;
        unleased)
          if fm_task_copy_slot_in_current_pool "$project" "$slot" "$FM_TASK_COPY_SLOT_NAME"; then
            remedy="To hold that slot in place without touching its contents, run: (cd '$project' && treehouse lease '$FM_TASK_COPY_CURRENT_SLOT_NAME' --lease-holder '$id')"
          elif [ "$FM_TASK_COPY_POOL_CURRENCY" = superseded ]; then
            continue
          else
            remedy="To hold that slot in place without touching its contents, confirm that treehouse status run from $project lists slot $FM_TASK_COPY_SLOT_NAME at $slot, then run: (cd '$project' && treehouse lease '$FM_TASK_COPY_SLOT_NAME' --lease-holder '$id')"
          fi
          ;;
        conflicting)
          remedy="Inspect the pool with: (cd '$project' && treehouse status); report the conflicting entries for repair before retrying. A lease cannot reliably clear this conflict."
          ;;
        recovered)
          remedy="treehouse lease refuses a slot that is already leased; inspect it with: (cd '$project' && treehouse status)"
          ;;
        escaped|relative)
          remedy="Have the pool owner remove or rename the offending entry so its recorded path is absolute and contains no TSV-escaped characters, then retry; a lease does not clear this refusal. A real path containing those characters remains unsupported while the entry exists."
          ;;
        missing-jq)
          remedy="Install jq so the pool state can be read, then retry; a lease does not clear this refusal."
          ;;
        *)
          remedy="A lease does not clear this refusal; inspect the pool with: (cd '$project' && treehouse status)"
          ;;
      esac
      echo "error: Treehouse pool slot $slot contains task $id's current copy $copy and $FM_TASK_COPY_SLOT_REASON; refusing allocation before treehouse get" >&2
      echo "$remedy" >&2
      return 1
    done
  done
}
