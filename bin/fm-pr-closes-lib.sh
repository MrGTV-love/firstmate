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
# - An HTML comment is an example too, read as CommonMark reads it. A line that starts with
#   `<!--` after at most three spaces opens a comment block: that line through the first
#   line that holds `-->` (the same line when `-->` follows the `<!`, so `<!-->` and
#   `<!--->` close at once) is skipped, and a block that never closes runs to the end of the
#   body. The pipeline's own attestation comment is one such line and hides nothing. A
#   `<!--` later in a line, outside a backtick code span, is kept with its line; when it does
#   not close on that line, the lines after it through the first line that holds `-->` are
#   skipped, but only when that `-->` comes in the same paragraph, before the next blank
#   line, fence line, comment-block line, ATX heading, `>` quote, list item, thematic
#   break or setext underline (a line of only `=` or only `-`); otherwise the `<!--` is plain text and hides nothing. So a directive line with a
#   trailing comment is still reported as malformed.
# - A trailing carriage return is ignored, because GitHub bodies often use CRLF.
# - Nothing else is read as a name: no table, heading, bullet, link or sentence ever
#   closes an item or makes a member.
# - The old `Closes: <item-id>` line closes nothing. It is reported (fm_pr_closes_legacy_ids),
#   as is a column-0 line that starts with a directive word but does not fit its form
#   (fm_pr_closes_malformed), so a misspelled block is never silent.
#
# Prose. The rest of the body (fm_pr_closes_prose) is the text a reader sees on every line not
# skipped above (the text inside a comment left out, the text after a comment's `-->` kept)
# that does not start at column 0 with a directive word or the old `Closes:`, so a malformed
# directive line is reported as malformed, never as prose. bin/fm-pr-close-items.sh reads its words and
# its pull request links only to report that something was mentioned and closed nothing.
#
# Every reader takes a body file path (or `-` for standard input) and prints one value per
# line, once each. They never fail on a body without matches; they print nothing.

FM_PR_CLOSES_ID_RE='[A-Za-z0-9._-]+'

# fm_pr_closes_inline <text>: read one line's inline code spans and HTML comments left to
# right. FM_PR_CLOSES_VIS is the text with each comment replaced by a space. When a `<!--`
# outside a code span does not close on the line, FM_PR_CLOSES_OPEN is 1 and
# FM_PR_CLOSES_HEAD is the text before it (FM_PR_CLOSES_VIS then keeps it as plain text).
fm_pr_closes_inline() {
  local rest=$1 out='' pre_t pre_c run s pre r found tick='`'
  FM_PR_CLOSES_OPEN=0
  FM_PR_CLOSES_HEAD=
  while :; do
    pre_t=${rest%%"$tick"*}
    pre_c=${rest%%'<!--'*}
    if [ "${#pre_t}" -lt "${#pre_c}" ]; then
      out=$out$pre_t
      rest=${rest:${#pre_t}}
      run=${rest%%[!\`]*}
      s=${rest:${#run}}
      found=$run
      while [[ "$s" == *"$tick"* ]]; do
        pre=${s%%"$tick"*}
        s=${s:${#pre}}
        r=${s%%[!\`]*}
        s=${s:${#r}}
        found=$found$pre$r
        if [ "${#r}" = "${#run}" ]; then
          out=$out$found
          rest=$s
          found=
          break
        fi
      done
      if [ -n "$found" ]; then
        out=$out$run
        rest=${rest:${#run}}
      fi
    elif [ "${#pre_c}" -lt "${#rest}" ]; then
      out=$out$pre_c
      rest=${rest:$((${#pre_c} + 2))}
      case "$rest" in
        *'-->'*) out="$out "; rest=${rest#*'-->'} ;;
        *) FM_PR_CLOSES_OPEN=1; FM_PR_CLOSES_HEAD=$out; out="$out<!$rest"; break ;;
      esac
    else
      out=$out$rest
      break
    fi
  done
  FM_PR_CLOSES_VIS=$out
}

# fm_pr_closes_unfenced <body-file|-> [prose]: every line outside a fence and an HTML comment.
# With `prose`, only the text a reader sees: comment text is left out and the text after any
# comment's `-->` on its closing line is kept, on a line of its own after a space.
fm_pr_closes_unfenced() {
  local mode=${2:-lines} line seg in_fence=0 in_comment=0 char='' len=0 run i=0 j k count=0
  local open_re='^[ ]{0,3}(`{3,}|~{3,})(.*)$'
  local close_re='^[ ]{0,3}(`{3,}|~{3,})[[:space:]]*$'
  local block_re='^[ ]{0,3}<!--'
  local stop_re='^[[:space:]]*$|^[ ]{0,3}(#{1,6}([[:space:]]|$)|>|[-+*]([[:space:]]|$)|[0-9]{1,9}[.)]([[:space:]]|$)|(\*[[:space:]]*){3,}$|(-[[:space:]]*){3,}$|(_[[:space:]]*){3,}$|(=+|-+)[[:space:]]*$|<!--|`{3,}|~{3,})'
  local lines=()
  while IFS= read -r line || [ -n "$line" ]; do
    lines[count]=${line%$'\r'}
    count=$((count + 1))
  done < <(if [ "${1:--}" = - ]; then cat; else cat -- "$1"; fi)
  while [ "$i" -lt "$count" ]; do
    line=${lines[i]}
    i=$((i + 1))
    if [ "$in_fence" = 1 ]; then
      if [[ "$line" =~ $close_re ]]; then
        run=${BASH_REMATCH[1]}
        if [ "${run:0:1}" = "$char" ] && [ "${#run}" -ge "$len" ]; then in_fence=0; fi
      fi
      continue
    fi
    if [ "$in_comment" = 1 ]; then
      case "$line" in
        *'-->'*)
          in_comment=0
          if [ "$mode" = prose ]; then fm_pr_closes_inline " ${line#*'-->'}"; printf '%s\n' "$FM_PR_CLOSES_VIS"; fi ;;
      esac
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
    if [[ "$line" =~ $block_re ]]; then
      seg=${line#*'<!'}
      case "$seg" in
        *'-->'*) if [ "$mode" = prose ]; then fm_pr_closes_inline " ${seg#*'-->'}"; printf '%s\n' "$FM_PR_CLOSES_VIS"; fi ;;
        *) in_comment=1 ;;
      esac
      continue
    fi
    case "$line" in *'<!--'*) ;; *) printf '%s\n' "$line"; continue ;; esac
    [ "$mode" = prose ] || printf '%s\n' "$line"
    seg=$line
    while :; do
      fm_pr_closes_inline "$seg"
      j=-1
      if [ "$FM_PR_CLOSES_OPEN" = 1 ]; then
        k=$i
        while [ "$k" -lt "$count" ] && ! [[ "${lines[k]}" =~ $stop_re ]]; do
          case "${lines[k]}" in *'-->'*) j=$k; break ;; esac
          k=$((k + 1))
        done
      fi
      if [ "$j" -lt 0 ]; then
        [ "$mode" != prose ] || printf '%s\n' "$FM_PR_CLOSES_VIS"
        break
      fi
      [ "$mode" != prose ] || printf '%s\n' "$FM_PR_CLOSES_HEAD"
      i=$((j + 1))
      seg=" ${lines[j]#*'-->'}"
    done
  done
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
  done < <(fm_pr_closes_unfenced "${1:--}" prose)
}

# The distinct words of the prose, as item-id candidates. A word keeps every character a
# task id may hold (letters, digits, `.`, `_`, `-`), so an id that begins or ends with `_`
# or `-` is found as spelled. Because a sentence can end right after an id, each word is
# printed as written and, when that differs, once more with leading and trailing `.`
# removed (an id never starts with `.`). When that word is wrapped in one matched Markdown
# emphasis pair (`_x_` or `__x__`), it is printed once more without the pair; a lone
# leading or trailing `_` stays. The caller can match any of these against its ids.
fm_pr_closes_prose_words() {  # <body-file|->
  fm_pr_closes_prose "${1:--}" \
    | LC_ALL=C tr -c 'A-Za-z0-9._-' '\n' \
    | LC_ALL=C awk 'NF {
        print
        t = $0
        sub(/^\.+/, "", t)
        sub(/\.+$/, "", t)
        if (t != "" && t != $0) print t
        e = t
        if (e ~ /^__.+__$/) e = substr(e, 3, length(e) - 4)
        else if (e ~ /^_.+_$/) e = substr(e, 2, length(e) - 2)
        if (e != "" && e != t) print e
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
