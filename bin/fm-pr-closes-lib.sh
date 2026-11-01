# shellcheck shell=bash
# fm-pr-closes-lib.sh - the one owner of the `Closes:` syntax and of the train
# member table that bin/fm-pr-close-items.sh reads from a merged pull request body.
# Usage: . bin/fm-pr-closes-lib.sh
#
# `Closes:` syntax. A pull request body names a backlog item it finishes with a
# line of its own:
#
#   Closes: <item-id>
#
# - The line is exactly `Closes:`, one space or more, one id, and optional trailing
#   whitespace. The word is case sensitive. Nothing else may share the line, so an
#   inline `Closes: x` inside a sentence, a code span, a quote (`>`) or a list item
#   names nothing.
# - The id follows bin/fm-pr-lib.sh's fm_pr_task_id_valid: letters, digits, `.`, `_`
#   and `-`, not starting with `.`. An id that is not valid names nothing.
# - A line inside a fenced code block (``` or ~~~) names nothing, because pipeline
#   bodies quote text they do not own.
# - A trailing carriage return is ignored, because GitHub bodies often use CRLF.
# - One id per line; list several items with several lines. A repeated id counts once.
#
# Train member syntax. A merge-train body lists its members in a markdown table whose
# header's first cell is `Component`. The first cell of each following row is a member
# pull request, a bare https://github.com/<owner>/<repo>/pull/<n> URL. Only that column
# names members: the same body also links excluded pull requests, earlier trains and
# context pull requests, and those did not land with this merge. The table ends at the
# first line that does not start with `|`.
#
# Both readers take a body file path (or `-` for standard input) and print one value
# per line. They never fail on a body without matches; they print nothing.

fm_pr_closes_ids() {  # <body-file|->
  local line id in_fence=0 fence='' closes_re='^Closes:[[:space:]]+([A-Za-z0-9._-]+)[[:space:]]*$'
  local seen=$'\n'
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [ "$in_fence" = 1 ]; then
      case "$line" in
        "$fence"*) in_fence=0 ;;
      esac
      continue
    fi
    case "$line" in
      '```'*) in_fence=1; fence='```'; continue ;;
      '~~~'*) in_fence=1; fence='~~~'; continue ;;
    esac
    [[ "$line" =~ $closes_re ]] || continue
    id=${BASH_REMATCH[1]}
    case "$id" in .*) continue ;; esac
    case "$seen" in *$'\n'"$id"$'\n'*) continue ;; esac
    seen="$seen$id"$'\n'
    printf '%s\n' "$id"
  done < <(if [ "${1:--}" = - ]; then cat; else cat -- "$1"; fi)
}

fm_pr_closes_train_members() {  # <body-file|->
  local line cell in_table=0 in_fence=0 fence=''
  local header_re='^[|][[:space:]]*Component[[:space:]]*[|]'
  local member_re='^https://github[.]com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+$'
  local seen=$'\n'
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [ "$in_fence" = 1 ]; then
      case "$line" in
        "$fence"*) in_fence=0 ;;
      esac
      continue
    fi
    case "$line" in
      '```'*) in_fence=1; fence='```'; in_table=0; continue ;;
      '~~~'*) in_fence=1; fence='~~~'; in_table=0; continue ;;
    esac
    if [ "$in_table" = 0 ]; then
      [[ "$line" =~ $header_re ]] && in_table=1
      continue
    fi
    case "$line" in
      '|'*) ;;
      *) in_table=0; continue ;;
    esac
    cell=${line#|}
    cell=${cell%%|*}
    cell=${cell#"${cell%%[![:space:]]*}"}
    cell=${cell%"${cell##*[![:space:]]}"}
    [[ "$cell" =~ $member_re ]] || continue
    case "$seen" in *$'\n'"$cell"$'\n'*) continue ;; esac
    seen="$seen$cell"$'\n'
    printf '%s\n' "$cell"
  done < <(if [ "${1:--}" = - ]; then cat; else cat -- "$1"; fi)
}
