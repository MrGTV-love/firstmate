#!/usr/bin/env bash
# fm-successor-branch-lib.sh - the one owner of which branch a task's record may
# name as its successor, and of the proof that it is this task's.
#
# A task's write confinement profile grants one exact literal ref (with its lock
# and reflog) for the task's branch and, when the record names one, for its
# successor branch. docs/agent-control.md "Recording a successor branch" owns the
# contract; bin/fm-control.sh `successor` is the only writer of the record.
#
# Three callers apply the same rule: fm-control.sh `successor` at admission and
# when it is repeated for an already-recorded successor, fm-control.sh `relaunch`
# before it stops the live worker, and fm-spawn.sh each time it builds a launch's
# profile. A record edited by hand therefore never widens a launch beyond one
# branch in the task's name family that no other task records, that is checked
# out in no other work tree, and whose history contains a commit of the task's
# own: an archive tip of the task or a commit of its recorded branch, never one
# the project's default or base branch contains (see fm_successor_tip_is_own), so
# an archive branch the worker points at shared history proves nothing.
#
# A fresh spawn and a reassociation of another task ask fm_successor_claimant
# whether some task's record already names their branch as its successor_branch=,
# and refuse when one does, so no later task takes over a recorded successor ref.
#
# fm_successor_name_refusal <name> <recorded-branch> <base-branch> <own-meta> <project> <state-dir>...
#   Prints the reason and returns 1 when <name> may not be the successor of the task whose record is <own-meta>;
#   prints nothing and returns 0 when it may. <own-meta> is the task's own record,
#   which the other-task scan skips. Each <state-dir> is one local Firstmate home's
#   state folder; every other task record there is scanned.
#   A name is admissible only when all of these hold:
#     - it uses only letters, digits, '.', '_', '-' and '/', starting with a letter
#       or digit, so no wildcard, space, quote, backslash or control character can
#       reach a profile line;
#     - git accepts it as a branch name;
#     - it is not under archive/, which only a task's own recovery branches use;
#     - it is not the task's recorded branch, its recorded base branch or the
#       project's default branch (origin/HEAD, else main or master);
#     - no other task record names it as its branch (an absent branch= on a ship
#       means fm/<its id>) or as its successor branch;
#     - it is in the task's own name family: the recorded branch name, then '-',
#       then one or more of letters, digits, '.', '_' and '-'. That bound is what
#       keeps a branch of another lineage (develop, release/*, a person's branch)
#       out of a task's profile whichever route proves it.
#   The other-task scan needs every task record it names to be readable; a record
#   or a state folder that cannot be read refuses, because an unread record leaves
#   the question of who owns the name unanswered.
#   Every name comparison against the recorded, base, default and other tasks'
#   branches ignores case, so a case variant never passes where the original is
#   refused, on any file system. bin/fm-write-confinement.py repeats the family
#   bound on the name it is handed.
#
# fm_successor_proof <project> <task-id> <recorded-branch> <successor> <copy> <base-branch> [<proved-tip>]
#   Prints, on success, the lines `route=checked-out`, `route=archive-tip` or
#   `route=proved-tip`, `archive=<name>` (the matched archive branch, for the
#   archive route only), `successor_sha=<sha>`, `prior_sha=<sha>` (the recorded
#   branch's tip, when it exists) and `proved_tip=<sha>` (the commit the successor
#   was proved to descend from), and returns 0. On failure prints one reason line
#   and returns 1.
#   It reads the project's ref store and worktree list and never opens a work
#   tree. Refs, archives and the worktree list are read through the recorded copy,
#   the repository whose common directory the profile generator grants. The
#   successor is proved to be this task's only when all of these hold:
#     - the recorded copy is a directory whose git common directory is the
#       project's, so the ref proved here is the ref the copy's profile grants;
#     - refs/heads/<successor> exists as a commit in the project's ref store;
#     - no work tree other than the recorded copy has it checked out (every
#       worktree on the branch is checked, not the first one listed);
#     - and, without <proved-tip> (a first admission), one of two routes holds:
#         checked-out: it is the branch checked out in the recorded copy, the
#           recorded branch's tip is an ancestor of, or equal to, its tip, and
#           that tip is the task's own (fm_successor_tip_is_own); the proved tip
#           is the recorded branch's tip;
#         archive-tip: the tip of one of the task's own custody archive branches
#           archive/<task>-(submitted|pipeline)-<8 hex>, whose hex is the first
#           eight digits of that archive's own tip and which neither the
#           default nor the base branch contains (fm_successor_tip_unshared), is
#           an ancestor of, or equal to, its tip; the proved tip is that
#           archive's tip;
#     - or, with <proved-tip> (a successor the record already names, with the
#       tip proved at its admission), route proved-tip: that commit is an
#       ancestor of, or equal to, its tip and is still the task's own
#       (fm_successor_tip_is_own). A successor whose history no longer contains
#       the proved tip, or a proved tip that is not the task's own, is refused.
#
# fm_successor_tip_is_own <copy> <task-id> <recorded-tip> <base-branch> <tip>
#   True when <tip> is a commit of this task's own: the tip of one of its own
#   archive/<task>-(submitted|pipeline)-<8 hex> branches, or a commit in the
#   recorded branch's history, and in either case one that the project's default
#   branch and the task's recorded base branch (local or origin) do not contain
#   (fm_successor_tip_unshared). A commit every branch shares, such as the
#   project's first commit, is never the task's own, even when an archive branch
#   points at it; when neither the default nor the base branch resolves, no tip
#   is. The archive-tip route skips an archive whose tip fails the same test.
#
# fm_successor_claimant <branch> <own-meta> <state-dir>...
#   Prints the id of a task other than <own-meta>'s whose record names <branch>
#   as its successor_branch= (case ignored) and returns 0; returns 1 when no
#   readable record does. A record or folder that cannot be read is skipped, so
#   a home with no recorded successor behaves as it always did.
#
# fm_successor_recorded_proof <task-id> <recorded-branch> <base-branch> <own-meta> <project> <copy> <successor> <proved-tip> <state-dir>...
#   The admission of a successor the record already names: the name rule, then
#   the proof from the tip proved at its admission. Prints the proof's lines on
#   success; prints one reason naming the task and the successor and returns 1
#   on failure, also when the record names no proved tip.

if ! declare -F fm_task_copy_canonical_dir >/dev/null 2>&1; then
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-task-copy-lib.sh"
fi

fm_successor_lc() {  # <string>: the string in lower case (bash 3.2 has no ${var,,})
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# The project's default branch name: origin/HEAD's, else main or master when it
# exists locally; empty when none does.
fm_successor_default_branch() {  # <project>
  local default
  default=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  default=${default#origin/}
  if [ -z "$default" ]; then
    for default in main master; do
      git -C "$1" show-ref --verify --quiet "refs/heads/$default" 2>/dev/null && break
      default=
    done
  fi
  printf '%s' "$default"
}

fm_successor_claimant() {  # <branch> <own-meta> <state-dir>...
  local lname own=$2 state meta succ
  lname=$(fm_successor_lc "$1")
  shift 2
  for state in "$@"; do
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ -r "$meta" ] || continue
      [ "$meta" != "$own" ] && [ ! "$meta" -ef "$own" ] || continue
      while IFS= read -r succ; do
        [ -n "$succ" ] && [ "$lname" = "$(fm_successor_lc "$succ")" ] || continue
        basename "$meta" .meta
        return 0
      done < <(LC_ALL=C sed -n 's/^successor_branch=//p' "$meta" 2>/dev/null)
    done
  done
  return 1
}

fm_successor_name_refusal() {
  local name=$1 recorded=$2 base=$3 own_meta=$4 project=$5 state meta other_id other_kind other_branch other_succ default
  local lname lrecorded lbase ldefault rest
  shift 5
  case "$name" in
    '') echo "it is empty"; return 1 ;;
  esac
  case "$name" in
    [!A-Za-z0-9]* | *[!A-Za-z0-9._/-]*)
      echo "it may use only letters, digits, '.', '_', '-' and '/', starting with a letter or digit (no wildcard, space or other character)"
      return 1
      ;;
  esac
  git check-ref-format --branch "$name" >/dev/null 2>&1 || {
    echo "it is not a valid git branch name"
    return 1
  }
  case "$name" in
    archive/*) echo "it is under archive/, which only a task's own recovery branches use"; return 1 ;;
  esac
  lname=$(fm_successor_lc "$name")
  lrecorded=$(fm_successor_lc "$recorded")
  [ "$lname" != "$lrecorded" ] || { echo "it equals the task's recorded branch"; return 1; }
  if [ -n "$base" ]; then
    lbase=$(fm_successor_lc "$base")
    [ "$lname" != "$lbase" ] || { echo "it equals the task's recorded base branch"; return 1; }
  fi
  default=$(fm_successor_default_branch "$project")
  if [ -n "$default" ]; then
    ldefault=$(fm_successor_lc "$default")
    [ "$lname" != "$ldefault" ] || { echo "it is the project's default branch"; return 1; }
  fi
  for state in "$@"; do
    # The inventory of which task owns which branch is the proof that a name is
    # not another task's. A folder or record that cannot be read leaves that proof
    # unknown, so it refuses; it never reads as "no owner".
    if [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; then
      echo "cannot read the task records in $state, so the name cannot be checked against the branches other tasks own"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      [ "$meta" != "$own_meta" ] || continue
      [ ! "$meta" -ef "$own_meta" ] || continue
      other_id=$(basename "$meta" .meta)
      [ -f "$meta" ] || continue
      if [ ! -r "$meta" ]; then
        echo "cannot read task $other_id's record $meta, so the name cannot be checked against the branches other tasks own"
        return 1
      fi
      if ! other_kind=$(LC_ALL=C awk -F= '$1 == "kind" { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$meta" 2>/dev/null) \
        || ! other_branch=$(LC_ALL=C awk -F= '$1 == "branch" { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$meta" 2>/dev/null) \
        || ! other_succ=$(LC_ALL=C awk -F= '$1 == "successor_branch" { sub(/^[^=]*=/, ""); print }' "$meta" 2>/dev/null); then
        echo "cannot read task $other_id's record $meta, so the name cannot be checked against the branches other tasks own"
        return 1
      fi
      if [ -z "$other_branch" ]; then
        case "$other_kind" in
          ''|ship) other_branch="fm/$other_id" ;;
        esac
      fi
      if [ -n "$other_branch" ] && [ "$lname" = "$(fm_successor_lc "$other_branch")" ]; then
        echo "task $other_id already records it as its branch"
        return 1
      fi
      while IFS= read -r other_branch; do
        [ -n "$other_branch" ] || continue
        if [ "$lname" = "$(fm_successor_lc "$other_branch")" ]; then
          echo "task $other_id already records it as its successor branch"
          return 1
        fi
      done <<< "$other_succ"
    done
  done
  rest=${name#"$recorded"-}
  if [ "$rest" = "$name" ] || ! [[ $rest =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "it is outside the task's own name family: the recorded branch name '$recorded', then '-', then one or more of letters, digits, '.', '_' and '-'; that bound keeps a branch of another lineage such as develop or release/* out of the task's write profile"
    return 1
  fi
  return 0
}

# Every worktree that has refs/heads/<successor> attached, one path per line,
# read from the project's worktree list so no work tree is opened. Prints nothing
# when no worktree has it; fails only when the list cannot be read. Git lets a
# branch be checked out in more than one worktree when it is forced, so a proof
# that looked at the first listed worktree would miss the others.
fm_successor_checkout_paths() {  # <project> <successor>
  local project=$1 successor=$2 line path="" attached="" listed
  listed=$(git -C "$project" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) path=${line#worktree }; attached= ;;
      'branch '*) attached=${line#branch } ;;
      '')
        if [ -n "$path" ] && [ "$attached" = "refs/heads/$successor" ]; then
          printf '%s\n' "$path"
        fi
        path=
        attached=
        ;;
    esac
  done <<< "$listed"$'\n\n'
  return 0
}

# The archive route of the proof: the tip of one of this task's own custody
# archive branches, archive/<id>-(submitted|pipeline)-<8 hex> whose hex is the
# first eight digits of its own tip, is an ancestor of, or equal to, the
# successor's tip. Prints the matching archive name and its tip; fails when none
# matches. No other name can match: the task id is anchored by the trailing '-',
# the middle word is one of two, the hex is eight lowercase digits and must equal
# the archive's own tip's first eight.
# With `exact`, the archive's tip must equal <successor-sha>.
fm_successor_archive_match() {  # <project> <task-id> <successor-sha> <base-branch> [exact]
  local project=$1 id=$2 sha=$3 base=$4 exact=${5-} name tip rest
  while read -r name tip; do
    rest=${name#"archive/$id-"}
    [ "$rest" != "$name" ] || continue
    [[ $rest =~ ^(submitted|pipeline)-([0-9a-f]{8})$ ]] || continue
    [ "${tip:0:8}" = "${BASH_REMATCH[2]}" ] || continue
    if [ -n "$exact" ]; then
      [ "$tip" = "$sha" ] || continue
    else
      git -C "$project" merge-base --is-ancestor "$tip" "$sha" 2>/dev/null || continue
    fi
    fm_successor_tip_unshared "$project" "$base" "$tip" || continue
    printf '%s %s\n' "$name" "$tip"
    return 0
  done < <(git -C "$project" for-each-ref --format='%(refname:short) %(objectname)' "refs/heads/archive/$id-submitted-*" "refs/heads/archive/$id-pipeline-*" 2>/dev/null)
  return 1
}

# True when <tip> is in neither the project's default branch nor the task's
# recorded base branch (local or origin/<name>), and at least one of them resolves.
# A tip either contains, such as the project's first commit, is shared history and
# never proves that anything is the task's own.
fm_successor_tip_unshared() {  # <copy> <base-branch> <tip>
  local copy=$1 base=$2 tip=$3 name ref shared seen=0
  for name in "$(fm_successor_default_branch "$copy")" "$base"; do
    [ -n "$name" ] || continue
    for ref in "refs/heads/$name" "refs/remotes/origin/$name"; do
      shared=$(git -C "$copy" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null) || continue
      seen=1
      ! git -C "$copy" merge-base --is-ancestor "$tip" "$shared" 2>/dev/null || return 1
    done
  done
  [ "$seen" = 1 ]
}

fm_successor_tip_is_own() {  # <copy> <task-id> <recorded-tip> <base-branch> <tip>
  local copy=$1 id=$2 prior=$3 base=$4 tip=$5
  fm_successor_archive_match "$copy" "$id" "$tip" "$base" exact >/dev/null && return 0
  [ -n "$prior" ] && git -C "$copy" merge-base --is-ancestor "$tip" "$prior" 2>/dev/null || return 1
  fm_successor_tip_unshared "$copy" "$base" "$tip"
}

# The git common directory of a path, canonical; empty when it has none.
fm_successor_store_of() {  # <path>
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  (cd "$common" 2>/dev/null && pwd -P)
}

fm_successor_proof() {  # <project> <task-id> <recorded-branch> <successor> <copy> <base-branch> [<proved-tip>]
  local project=$1 id=$2 recorded=$3 successor=$4 wt=$5 base=$6 proved=${7-}
  local succ_sha copy paths path elsewhere="" in_copy=0 why1 archive_match archive_name prior_sha="" copy_store project_store
  copy=$(fm_task_copy_canonical_dir "$wt") || {
    echo "task $id's recorded copy $wt is not a directory, so the successor cannot be proved to be this task's"
    return 1
  }
  # The profile is derived from the copy's own repository, so the ref the proof reads
  # must be in that repository: a copy of some other repository proves nothing here.
  copy_store=$(fm_successor_store_of "$copy" || true)
  project_store=$(fm_successor_store_of "$project" || true)
  if [ -z "$copy_store" ] || [ "$copy_store" != "$project_store" ]; then
    echo "the recorded copy $wt does not share the project's ref store ($project), so a ref proved in the project is not the ref the copy's write profile would grant"
    return 1
  fi
  succ_sha=$(git -C "$copy" rev-parse --verify --quiet "refs/heads/$successor^{commit}" 2>/dev/null) || {
    echo "successor branch '$successor' does not exist in the project's ref store ($project); create it first"
    return 1
  }
  paths=$(fm_successor_checkout_paths "$copy" "$successor") || {
    echo "cannot read $project's worktree list, so the successor cannot be proved to be this task's"
    return 1
  }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ "$path" = "$copy" ] || [ "$(fm_task_copy_canonical_dir "$path" 2>/dev/null || true)" = "$copy" ]; then
      in_copy=1
    else
      elsewhere=$path
      break
    fi
  done <<< "$paths"
  if [ -n "$elsewhere" ]; then
    echo "successor branch '$successor' is checked out in $elsewhere, which is not this task's recorded copy $wt"
    return 1
  fi
  prior_sha=$(git -C "$copy" rev-parse --verify --quiet "refs/heads/$recorded^{commit}" 2>/dev/null || true)
  if [ -n "$proved" ]; then
    if ! [[ $proved =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] \
      || [ "$(git -C "$copy" rev-parse --verify --quiet "$proved^{commit}" 2>/dev/null)" != "$proved" ]; then
      echo "the tip $proved proved at the successor's admission is not a commit in the project's ref store"
      return 1
    fi
    git -C "$copy" merge-base --is-ancestor "$proved" "$succ_sha" 2>/dev/null || {
      echo "successor branch '$successor' at $succ_sha no longer contains the tip $proved proved at its admission"
      return 1
    }
    fm_successor_tip_is_own "$copy" "$id" "$prior_sha" "$base" "$proved" || {
      echo "the tip $proved recorded as proved at the successor's admission is not a commit of task $id's own: it is neither the tip of one of its archive/$id-(submitted|pipeline)-<8 hex> branches nor a commit of the recorded branch '$recorded' that the project's default or base branch does not contain"
      return 1
    }
    printf 'route=proved-tip\nsuccessor_sha=%s\nprior_sha=%s\nproved_tip=%s\n' "$succ_sha" "$prior_sha" "$proved"
    return 0
  fi
  why1=
  if [ "$in_copy" = 0 ]; then
    why1="it is not checked out in the recorded copy $wt"
  elif [ -z "$prior_sha" ]; then
    why1="the recorded branch '$recorded' does not exist in the project's ref store"
  elif ! git -C "$copy" merge-base --is-ancestor "$prior_sha" "$succ_sha" 2>/dev/null; then
    why1="the recorded tip $prior_sha is not an ancestor of the successor tip $succ_sha"
  elif ! fm_successor_tip_is_own "$copy" "$id" "$prior_sha" "$base" "$prior_sha"; then
    why1="the recorded tip $prior_sha is shared with the project's default or base branch, so it is not a commit of the task's own"
  fi
  if [ -z "$why1" ]; then
    printf 'route=checked-out\nsuccessor_sha=%s\nprior_sha=%s\nproved_tip=%s\n' "$succ_sha" "$prior_sha" "$prior_sha"
    return 0
  fi
  archive_match=$(fm_successor_archive_match "$copy" "$id" "$succ_sha" "$base") || {
    echo "successor branch '$successor' is not proved to be this task's successor; the checked-out route (checked out in the recorded copy and containing the recorded branch's tip) fails because $why1; the archive-tip route (its tip $succ_sha contains the tip of one of the task's own archive/$id-(submitted|pipeline)-<8 hex> branches) fails because no such archive tip is in its history"
    return 1
  }
  archive_name=${archive_match%% *}
  printf 'route=archive-tip\narchive=%s\nsuccessor_sha=%s\nprior_sha=%s\nproved_tip=%s\n' "$archive_name" "$succ_sha" "$prior_sha" "${archive_match#* }"
  return 0
}

fm_successor_recorded_proof() {  # <task-id> <recorded-branch> <base-branch> <own-meta> <project> <copy> <successor> <proved-tip> <state-dir>...
  local id=$1 recorded=$2 base=$3 own_meta=$4 project=$5 copy=$6 successor=$7 proved=$8 reason
  shift 8
  reason=$(fm_successor_name_refusal "$successor" "$recorded" "$base" "$own_meta" "$project" "$@") || {
    echo "task $id records successor branch '$successor', which is not admissible: $reason"
    return 1
  }
  [ -n "$proved" ] || {
    echo "task $id records successor branch '$successor' but no successor_proved_tip=, so the tip proved at its admission is unknown"
    return 1
  }
  reason=$(fm_successor_proof "$project" "$id" "$recorded" "$successor" "$copy" "$base" "$proved") || {
    echo "task $id records successor branch '$successor', which is no longer proved to be this task's: $reason"
    return 1
  }
  printf '%s\n' "$reason"
}
