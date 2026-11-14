#!/usr/bin/env bash
# fm-successor-branch-lib.sh - the one owner of which branch a task's record may
# name as its successor, and of the proof that it is this task's.
#
# A task's write confinement profile grants one exact literal ref (with its lock
# and reflog) for the task's branch and, when the record names one, for its
# successor branch. docs/agent-control.md "Recording a successor branch" owns the
# contract; bin/fm-control.sh `successor` is the only writer of the record.
#
# Three callers apply the same rule and the same proof: fm-control.sh at
# admission, fm-control.sh `successor --check` (also on an already-recorded
# successor), and fm-spawn.sh each time it builds a launch's profile, so a record
# edited by hand to name a branch the operation would have refused never widens a
# launch.
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
#   Every name comparison against the recorded, base, default and other tasks'
#   branches ignores case, so a case variant never passes where the original is
#   refused, on any file system. bin/fm-write-confinement.py repeats the family
#   bound on the name it is handed.
#
# fm_successor_proof <project> <task-id> <recorded-branch> <successor> <copy>
#   Prints, on success, the lines `route=checked-out` or `route=archive-tip`,
#   `archive=<name>` (the matched archive branch, for the second route only),
#   `successor_sha=<sha>` and `prior_sha=<sha>` (the recorded branch's tip, when
#   it exists), and returns 0. On failure prints one reason line and returns 1.
#   It reads the project's ref store and worktree list and never opens a work
#   tree. The successor is proved to be this task's only when all of these hold:
#     - refs/heads/<successor> exists as a commit in the project's ref store;
#     - the recorded copy is a directory;
#     - no work tree other than the recorded copy has it checked out;
#     - and one of two routes holds:
#         checked-out: it is the branch checked out in the recorded copy and the
#           recorded branch's tip is an ancestor of, or equal to, its tip;
#         archive-tip: its tip equals the tip of one of the task's own custody
#           archive branches archive/<task>-(submitted|pipeline)-<8 hex>, whose
#           hex is the first eight digits of that archive's own tip.

if ! declare -F fm_task_copy_canonical_dir >/dev/null 2>&1; then
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-task-copy-lib.sh"
fi

fm_successor_lc() {  # <string>: the string in lower case (bash 3.2 has no ${var,,})
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
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
  default=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  default=${default#origin/}
  if [ -z "$default" ]; then
    for default in main master; do
      git -C "$project" show-ref --verify --quiet "refs/heads/$default" 2>/dev/null && break
      default=
    done
  fi
  if [ -n "$default" ]; then
    ldefault=$(fm_successor_lc "$default")
    [ "$lname" != "$ldefault" ] || { echo "it is the project's default branch"; return 1; }
  fi
  for state in "$@"; do
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      [ "$meta" != "$own_meta" ] || continue
      [ ! "$meta" -ef "$own_meta" ] || continue
      other_id=$(basename "$meta" .meta)
      other_kind=$(LC_ALL=C awk -F= '$1 == "kind" { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$meta" 2>/dev/null || true)
      other_branch=$(LC_ALL=C awk -F= '$1 == "branch" { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$meta" 2>/dev/null || true)
      other_succ=$(LC_ALL=C awk -F= '$1 == "successor_branch" { sub(/^[^=]*=/, ""); print }' "$meta" 2>/dev/null || true)
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

# The worktree that has refs/heads/<successor> attached, read from the project's
# worktree list so no work tree is opened. Prints its path (nothing when no
# worktree has it); fails only when the list cannot be read.
fm_successor_checkout_path() {  # <project> <successor>
  local project=$1 successor=$2 line path="" attached="" listed
  listed=$(git -C "$project" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) path=${line#worktree }; attached= ;;
      'branch '*) attached=${line#branch } ;;
      '')
        if [ -n "$path" ] && [ "$attached" = "refs/heads/$successor" ]; then
          printf '%s\n' "$path"
          return 0
        fi
        path=
        attached=
        ;;
    esac
  done <<< "$listed"$'\n\n'
  return 0
}

# The archive route of the proof: the successor's tip is the tip of one of this
# task's own custody archive branches, archive/<id>-(submitted|pipeline)-<8 hex>
# whose hex is the first eight digits of its own tip. Prints the matching
# archive name; fails when none matches. No other name can match: the task id is
# anchored by the trailing '-', the middle word is one of two, the hex is eight
# lowercase digits and must equal the archive's own tip's first eight.
fm_successor_archive_match() {  # <project> <task-id> <successor-sha>
  local project=$1 id=$2 sha=$3 name tip rest
  while read -r name tip; do
    rest=${name#"archive/$id-"}
    [ "$rest" != "$name" ] || continue
    [[ $rest =~ ^(submitted|pipeline)-([0-9a-f]{8})$ ]] || continue
    [ "${tip:0:8}" = "${BASH_REMATCH[2]}" ] || continue
    [ "$tip" = "$sha" ] || continue
    printf '%s\n' "$name"
    return 0
  done < <(git -C "$project" for-each-ref --format='%(refname:short) %(objectname)' "refs/heads/archive/$id-submitted-*" "refs/heads/archive/$id-pipeline-*" 2>/dev/null)
  return 1
}

fm_successor_proof() {  # <project> <task-id> <recorded-branch> <successor> <copy>
  local project=$1 id=$2 recorded=$3 successor=$4 wt=$5
  local succ_sha copy other_path why1 archive_name prior_sha=""
  succ_sha=$(git -C "$project" rev-parse --verify --quiet "refs/heads/$successor^{commit}" 2>/dev/null) || {
    echo "successor branch '$successor' does not exist in the project's ref store ($project); create it first"
    return 1
  }
  copy=$(fm_task_copy_canonical_dir "$wt") || {
    echo "task $id's recorded copy $wt is not a directory, so the successor cannot be proved to be this task's"
    return 1
  }
  other_path=$(fm_successor_checkout_path "$project" "$successor") || {
    echo "cannot read $project's worktree list, so the successor cannot be proved to be this task's"
    return 1
  }
  if [ -n "$other_path" ] && [ "$other_path" != "$copy" ] && [ "$(fm_task_copy_canonical_dir "$other_path" 2>/dev/null || true)" != "$copy" ]; then
    echo "successor branch '$successor' is checked out in $other_path, which is not this task's recorded copy $wt"
    return 1
  fi
  prior_sha=$(git -C "$project" rev-parse --verify --quiet "refs/heads/$recorded^{commit}" 2>/dev/null || true)
  why1=
  if [ -z "$other_path" ]; then
    why1="it is not checked out in the recorded copy $wt"
  elif [ -z "$prior_sha" ]; then
    why1="the recorded branch '$recorded' does not exist in the project's ref store"
  elif ! git -C "$project" merge-base --is-ancestor "$prior_sha" "$succ_sha" 2>/dev/null; then
    why1="the recorded tip $prior_sha is not an ancestor of the successor tip $succ_sha"
  fi
  if [ -z "$why1" ]; then
    printf 'route=checked-out\nsuccessor_sha=%s\nprior_sha=%s\n' "$succ_sha" "$prior_sha"
    return 0
  fi
  archive_name=$(fm_successor_archive_match "$project" "$id" "$succ_sha") || {
    echo "successor branch '$successor' is not proved to be this task's successor; the checked-out route (checked out in the recorded copy and containing the recorded branch's tip) fails because $why1; the archive-tip route (its tip $succ_sha is the tip of one of the task's own archive/$id-(submitted|pipeline)-<8 hex> branches) fails because none points there"
    return 1
  }
  printf 'route=archive-tip\narchive=%s\nsuccessor_sha=%s\nprior_sha=%s\n' "$archive_name" "$succ_sha" "$prior_sha"
  return 0
}
