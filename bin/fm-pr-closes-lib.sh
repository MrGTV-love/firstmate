# shellcheck shell=bash
# fm-pr-closes-lib.sh - the one owner of the `Closes:` syntax and of the merge-train
# member list that bin/fm-pr-close-items.sh reads from a merged pull request body.
# Usage: . bin/fm-pr-closes-lib.sh
#
# `Closes:` syntax (fm_pr_closes_ids). A pull request body names a backlog item it
# finishes with a line of its own:
#
#   Closes: <item-id>
#
# - The line starts at column 0 with the case-sensitive word `Closes:`, then one space or
#   more, one id, and optional trailing whitespace. Nothing else may share the line, so
#   an indented line, a trailing comment, a quote (`>`), a list item, a code span or an
#   inline `Closes: x` inside a sentence names nothing, and so does a lowercase
#   `closes:`.
# - The id is letters, digits, `.`, `_` and `-`, not starting with `.` (the ids
#   bin/fm-pr-lib.sh's fm_pr_task_id_valid and bin/fm-tasks-axi.sh accept), for example
#   `fm-backlog-close-at-merge` or `ship-a` or `a.b_c-1`.
# - A line inside a fenced code block (``` or ~~~) is an example, not a directive,
#   because pipeline bodies quote text they do not own.
# - A trailing carriage return is ignored, because GitHub bodies often use CRLF.
# - One id per line; list several items with several lines. A repeated id counts once.
#
# Merge-train member list (fm_pr_closes_train_members). A pull request is a merge train
# when its body has a member list, and the members are the pull request URLs that list
# holds, in the layouts the firstmate trains use. A URL anywhere else in the body (the
# intent paragraph, an excluded or context pull request, an earlier train) is not a
# member, because it did not land with this merge. A member list is one of:
#   - a table whose header row (the first row of the table, followed by a separator row)
#     has a cell that is `Component` or `Component` plus one word, such as `Component PR`;
#     the member is the URL that starts that column's cell in each following row (the
#     table ends at the first line that does not start with `|`), whether the URL column
#     comes first or after a `#` column, under any heading or lead-in line. A data row
#     that merely mentions Component is no header;
#   - a bullet whose label contains `Component`, such as `- **Component 1:** <url> ...`;
#   - the bullets under a heading containing `Component` (until the next heading), each
#     of which starts with a URL (a bullet that does not start with a URL is skipped);
#   - a numbered or bulleted list right after a line that starts with `Component` and
#     ends with a colon (until the first line that is not an item), whether or not it
#     sits inside a fenced block, because train bodies quote their record that way.
# The reader prints each candidate URL once, in body order; the caller validates and
# canonicalizes it with fm_pr_url_parse (GitHub pull, GitLab merge_requests, Forgejo
# pulls) and matches by the full URL, never by number or prefix.
#
# Linked pull requests (fm_pr_closes_linked_prs). Every GitHub pull request URL the body
# links outside a fenced code block, once each, in body order, member or not. A link to a
# page of a pull request (`/pull/7/files`, `/pull/7#issuecomment-1`) counts as that pull
# request. bin/fm-pr-close-items.sh uses this list only to name a linked pull request of
# a merge train that the member list does not hold; a link never makes a member.
#
# All three readers take a body file path (or `-` for standard input) and print one value
# per line. They never fail on a body without matches; they print nothing.

fm_pr_closes_unfenced() {  # <body-file|->
  local line in_fence=0 fence=''
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
    printf '%s\n' "$line"
  done < <(if [ "${1:--}" = - ]; then cat; else cat -- "$1"; fi)
}

fm_pr_closes_ids() {  # <body-file|->
  local line id closes_re='^Closes:[[:space:]]+([A-Za-z0-9._-]+)[[:space:]]*$'
  local seen=$'\n'
  while IFS= read -r line; do
    [[ "$line" =~ $closes_re ]] || continue
    id=${BASH_REMATCH[1]}
    case "$id" in .*) continue ;; esac
    case "$seen" in *$'\n'"$id"$'\n'*) continue ;; esac
    seen="$seen$id"$'\n'
    printf '%s\n' "$id"
  done < <(fm_pr_closes_unfenced "${1:--}")
}

fm_pr_closes_linked_prs() {  # <body-file|->
  fm_pr_closes_unfenced "${1:--}" \
    | LC_ALL=C grep -Eo 'https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pull/[0-9]+' \
    | awk '!seen[$0]++'
}

fm_pr_closes_train_members() {  # <body-file|->
  local line mode=none list_kind='' items=0 cells i col=0 rest url
  local seen=$'\n' cell
  local url_re='https?://[^][:space:]|)<>`*,;]+'
  local table_re='^[[:space:]]*[|]'
  local label_re='^[[:space:]]*[-*][[:space:]]+[*_]*[Cc]omponent[^:]*:[*_]*[[:space:]]*(.*)$'
  local heading_re='^[[:space:]]{0,3}#+[[:space:]]'
  local heading_component_re='^[[:space:]]{0,3}#+[[:space:]].*[Cc]omponent'
  local leadin_re='^[Cc]omponents?[^:]*:[[:space:]]*$'
  local item_re='^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]+(.*)$'
  local sep_re='^[[:space:]]*[|]?[[:space:]]*:?-+:?[[:space:]]*([|][[:space:]]*:?-+:?[[:space:]]*)*[|]?[[:space:]]*$'
  local header_cell_re='^[Cc]omponent([[:space:]]+[A-Za-z]+)?$'
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    url=
    if [[ "$line" =~ $table_re ]]; then
      IFS='|' read -r -a cells <<< "$line"
      if [ "$mode" = list ]; then mode=none; fi
      if [ "$mode" = header ]; then
        # The row under a candidate header must be the separator row, or it was no header.
        if [[ "$line" =~ $sep_re ]]; then mode=table; else mode=other; fi
        continue
      fi
      if [ "$mode" = none ]; then
        # Only the first row of a table can be its header; a later row is a data row.
        col=0
        for ((i = 1; i < ${#cells[@]}; i++)); do
          cell=${cells[i]#"${cells[i]%%[![:space:]]*}"}
          cell=${cell%"${cell##*[![:space:]]}"}
          if [[ "$cell" =~ $header_cell_re ]]; then col=$i; break; fi
        done
        if [ "$col" -gt 0 ]; then mode=header; else mode=other; fi
        continue
      fi
      [ "$mode" = table ] || continue
      cell=${cells[col]:-}
      cell=${cell#"${cell%%[![:space:]]*}"}
      if [[ "$cell" =~ ^($url_re) ]]; then url=${BASH_REMATCH[1]}; fi
    else
      case "$mode" in
        table|header|other) if [ "$list_kind" = heading ]; then mode=list; else mode=none; fi ;;
      esac
      if [[ "$line" =~ $heading_re ]]; then
        mode=none
        list_kind=''
        if [[ "$line" =~ $heading_component_re ]]; then mode=list; list_kind=heading; items=0; fi
        continue
      fi
      if [[ "$line" =~ $leadin_re ]]; then mode=list; list_kind=leadin; items=0; continue; fi
      if [[ "$line" =~ $label_re ]]; then
        rest=${BASH_REMATCH[1]}
        if [[ "$rest" =~ $url_re ]]; then url=${BASH_REMATCH[0]}; fi
      elif [ "$mode" = list ]; then
        if [[ "$line" =~ $item_re ]]; then
          rest=${BASH_REMATCH[2]}
          if [[ "$rest" =~ ^($url_re) ]]; then url=${BASH_REMATCH[1]}; items=$((items + 1)); fi
        elif [ "$list_kind" = leadin ] && { [ "$items" -gt 0 ] || [ -n "${line//[[:space:]]/}" ]; }; then
          mode=none
        fi
      fi
    fi
    [ -n "$url" ] || continue
    url=${url%[.:]}
    case "$seen" in *$'\n'"$url"$'\n'*) continue ;; esac
    seen="$seen$url"$'\n'
    printf '%s\n' "$url"
  done < <(if [ "${1:--}" = - ]; then cat; else cat -- "$1"; fi)
}
