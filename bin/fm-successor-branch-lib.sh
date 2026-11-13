#!/usr/bin/env bash
# fm-successor-branch-lib.sh - the one owner of which names a recorded successor
# task branch may carry.
#
# A task's write confinement profile grants one exact literal ref (with its lock
# and reflog) for the task's branch and, when the record names one, for its
# successor branch. docs/agent-control.md "Recording a successor branch" owns the
# contract; bin/fm-control.sh `successor` is the only writer of the record.
#
# Two callers apply this same rule: fm-control.sh at admission, and fm-spawn.sh
# when it builds the next launch's profile, so a record edited by hand to name
# a branch the operation would have refused never widens a launch.
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
#       means fm/<its id>) or as its successor branch.

fm_successor_name_refusal() {
  local name=$1 recorded=$2 base=$3 own_meta=$4 project=$5 state meta other_id other_kind other_branch other_succ default
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
  [ "$name" != "$recorded" ] || { echo "it equals the task's recorded branch"; return 1; }
  [ -z "$base" ] || [ "$name" != "$base" ] || { echo "it equals the task's recorded base branch"; return 1; }
  default=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  default=${default#origin/}
  if [ -z "$default" ]; then
    for default in main master; do
      git -C "$project" show-ref --verify --quiet "refs/heads/$default" 2>/dev/null && break
      default=
    done
  fi
  [ -z "$default" ] || [ "$name" != "$default" ] || { echo "it is the project's default branch"; return 1; }
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
      if [ -n "$other_branch" ] && [ "$name" = "$other_branch" ]; then
        echo "task $other_id already records it as its branch"
        return 1
      fi
      if printf '%s\n' "$other_succ" | grep -qxF -- "$name"; then
        echo "task $other_id already records it as its successor branch"
        return 1
      fi
    done
  done
  return 0
}
