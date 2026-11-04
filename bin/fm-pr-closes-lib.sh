# shellcheck shell=bash
# fm-pr-closes-lib.sh - the one owner of the directive lines that name the backlog items
# a merged pull request closes and the pull requests a merge train lands. Both are read
# by bin/fm-pr-close-items.sh. Usage: . bin/fm-pr-closes-lib.sh
#
# The block. A pull request body names what it closes only with directive lines, and
# only these two forms close anything:
#
#   Closes-backlog-item: <item-id>
#   Train-member: <pull request URL>
#
# - A directive is a whole line that starts at column 0. The word is case-sensitive,
#   then one space or more, then one value, then optional trailing whitespace. Nothing
#   else may share the line, so an indented line, a trailing comment, a quote (`>`), a
#   list item, a table cell, a heading, a link, a code span or a sentence that holds the
#   text names nothing.
# - The block is every directive line in the body. Where the lines sit does not matter
#   (the pipeline's body rewrite keeps a section above its own); put them together, one
#   per line, in one section.
# - An item id is letters, digits, `.`, `_` and `-`, not starting with `.` (the ids
#   bin/fm-pr-lib.sh's fm_pr_task_id_valid and bin/fm-tasks-axi.sh accept), for example
#   `fm-backlog-close-at-merge` or `ship-a` or `a.b_c-1`. A repeated id counts once.
# - A train member is one pull request URL (GitHub pull, GitLab merge_requests or Forgejo
#   pulls; the caller validates and canonicalizes it with fm_pr_url_parse and matches by
#   the full URL, never by number or prefix). A repeated URL counts once.
# - A line inside a fenced code block is an example, never a directive. The fence follows
#   the CommonMark rule: it opens with a run of three or more backticks or tildes, after
#   at most three spaces, a backtick fence's info text holds no backtick; it closes with
#   a run of the same character at least as long, after at most three spaces, with only
#   whitespace after it; a fence that never closes runs to the end of the body.
#   Pipeline bodies quote text they do not own, so quoted examples stay examples.
# - An HTML comment is an example too: every line from one that holds `<!--` through the
#   line that holds `-->` (the same line when both are on it) is skipped, and a comment that
#   never closes runs to the end of the body. The pipeline's own attestation comment is one
#   line and hides nothing.
# - A trailing carriage return is ignored, because GitHub bodies often use CRLF.
# - Nothing else is read as a name: no table, heading, bullet, link or sentence ever
#   closes an item or makes a member.
# - The old `Closes: <item-id>` line closes nothing. It is reported (fm_pr_closes_legacy_ids),
#   as is a column-0 line that starts with a directive word but does not fit its form
#   (fm_pr_closes_malformed), so a misspelled block is never silent.
#
# Prose. The rest of the body (fm_pr_closes_prose) is every line outside a fence that does
# not start at column 0 with a directive word or the old `Closes:`, so a malformed directive
# line is reported as malformed, never as prose. bin/fm-pr-close-items.sh reads its words and
# its pull request links only to report that something was mentioned and closed nothing.
#
# Every reader takes a body file path (or `-` for standard input) and prints one value per
# line, once each. They never fail on a body without matches; they print nothing.

FM_PR_CLOSES_ID_RE='[A-Za-z0-9._-]+'

fm_pr_closes_unfenced() {  # <body-file|->
  local line in_fence=0 in_comment=0 char='' len=0 run
  local open_re='^[ ]{0,3}(`{3,}|~{3,})(.*)$'
  local close_re='^[ ]{0,3}(`{3,}|~{3,})[[:space:]]*$'
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [ "$in_fence" = 1 ]; then
      if [[ "$line" =~ $close_re ]]; then
        run=${BASH_REMATCH[1]}
        if [ "${run:0:1}" = "$char" ] && [ "${#run}" -ge "$len" ]; then in_fence=0; fi
      fi
      continue
    fi
    if [ "$in_comment" = 1 ]; then
      case "$line" in *'-->'*) in_comment=0 ;; esac
      continue
    fi
    if [[ "$line" =~ $open_re ]]; then
      run=${BASH_REMATCH[1]}
      # A backtick fence's info text may not hold a backtick (that is inline code).
      if [ "${run:0:1}" != '`' ] || [[ "${BASH_REMATCH[2]}" != *'`'* ]]; then
        in_fence=1
        char=${run:0:1}
        len=${#run}
        continue
      fi
    fi
    case "$line" in
      *'<!--'*)
        # The comment opens here and closes on this line only if `-->` follows the opener.
        case "${line#*'<!--'}" in *'-->'*) ;; *) in_comment=1 ;; esac
        continue ;;
    esac
    printf '%s\n' "$line"
  done < <(if [ "${1:--}" = - ]; then cat; else cat -- "$1"; fi)
}

# fm_pr_closes_directive <word> <body-file|->: the value of each well-formed `<word>: value`
# line outside a fence, once each, in body order.
fm_pr_closes_directive() {
  local word=$1 line value seen=$'\n'
  local re="^${word}:[[:space:]]+([^[:space:]]+)[[:space:]]*\$"
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || continue
    value=${BASH_REMATCH[1]}
    case "$seen" in *$'\n'"$value"$'\n'*) continue ;; esac
    seen="$seen$value"$'\n'
    printf '%s\n' "$value"
  done < <(fm_pr_closes_unfenced "${2:--}")
}

fm_pr_closes_ids() {  # <body-file|->
  local id id_re="^${FM_PR_CLOSES_ID_RE}\$"
  while IFS= read -r id; do
    [[ "$id" =~ $id_re ]] || continue
    case "$id" in .*) continue ;; esac
    printf '%s\n' "$id"
  done < <(fm_pr_closes_directive 'Closes-backlog-item' "${1:--}")
}

fm_pr_closes_members() {  # <body-file|->
  fm_pr_closes_directive 'Train-member' "${1:--}"
}

# The old line form: reported by the caller, never a directive.
fm_pr_closes_legacy_ids() {  # <body-file|->
  fm_pr_closes_directive 'Closes' "${1:--}"
}

# A column-0 line that starts with a directive word (the two forms and the old `Closes:`)
# but does not fit its form: an id with a bad character or a leading `.`, a missing or
# doubled value, trailing text. The whole line is printed, once each.
fm_pr_closes_malformed() {  # <body-file|->
  local line id
  local id_re="^Closes-backlog-item:[[:space:]]+(${FM_PR_CLOSES_ID_RE})[[:space:]]*\$"
  local one_re='^(Train-member|Closes):[[:space:]]+[^[:space:]]+[[:space:]]*$'
  while IFS= read -r line; do
    case "$line" in
      'Closes-backlog-item:'*)
        if [[ "$line" =~ $id_re ]]; then
          id=${BASH_REMATCH[1]}
          case "$id" in .*) ;; *) continue ;; esac
        fi ;;
      'Train-member:'*|'Closes:'*) [[ "$line" =~ $one_re ]] && continue ;;
      *) continue ;;
    esac
    printf '%s\n' "$line"
  done < <(fm_pr_closes_unfenced "${1:--}") | LC_ALL=C awk '!seen[$0]++'
}

fm_pr_closes_prose() {  # <body-file|->
  local line
  local directive_re='^(Closes-backlog-item|Train-member|Closes):'
  while IFS= read -r line; do
    [[ "$line" =~ $directive_re ]] || printf '%s\n' "$line"
  done < <(fm_pr_closes_unfenced "${1:--}")
}

# The distinct words of the prose, as item-id candidates. A word keeps every character a
# task id may hold (letters, digits, `.`, `_`, `-`), so an id that begins or ends with `_`
# or `-` is found as spelled. Because a sentence can end right after an id, each word is
# printed as written and, when that differs, once more with leading and trailing `.`
# removed (an id never starts with `.`), so the caller can match either against its ids.
fm_pr_closes_prose_words() {  # <body-file|->
  fm_pr_closes_prose "${1:--}" \
    | LC_ALL=C tr -c 'A-Za-z0-9._-' '\n' \
    | LC_ALL=C awk 'NF {
        print
        t = $0
        sub(/^\.+/, "", t)
        sub(/\.+$/, "", t)
        if (t != "" && t != $0) print t
      }' \
    | LC_ALL=C awk '!seen[$0]++'
}

# Every pull request link in the prose, once each, in body order. A link to a page of a
# pull request (`/pull/7/files`, `/pull/7#issuecomment-1`) counts as that pull request.
# GitHub (`/pull/N`), GitLab (`/-/merge_requests/N`) and Forgejo (`/pulls/N`) links are
# read; the caller validates each with fm_pr_url_parse.
fm_pr_closes_prose_prs() {  # <body-file|->
  fm_pr_closes_prose "${1:--}" \
    | LC_ALL=C grep -Eo 'https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/-]*/(pull|pulls|merge_requests)/[0-9]+' \
    | awk '!seen[$0]++'
}
