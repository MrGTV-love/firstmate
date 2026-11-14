# shellcheck shell=bash
# fm-pr-closes-lib.sh - the one owner of the closes block: the one place in a pull request body
# that names the backlog items a merge closes and the pull requests a merge train lands.
# bin/fm-pr-close-items.sh reads it. Usage: . bin/fm-pr-closes-lib.sh
#
# The block (Main 3039; Main 043 fixes its form). A body names what it closes only in one block:
#
#   <!-- firstmate-backlog-closes:begin -->
#   Closes-backlog-item: <item-id>
#   Train-member: <pull request URL>
#   <!-- firstmate-backlog-closes:end -->
#
# - The begin line and the end line are exactly those texts, alone on their line from column 0.
#   Trailing whitespace and a trailing carriage return (GitHub bodies often use CRLF) are
#   ignored on every line.
# - Every line between them is one of three kinds: a `Closes-backlog-item: <item-id>` line, a
#   `Train-member: <value>` line, or a blank line. A directive line starts at column 0 with
#   its word (case-sensitive) and a colon, then one space or more, one value, and optional
#   trailing whitespace.
# - An item id is letters, digits, `.`, `_` and `-`, not starting with `.` (the ids
#   bin/fm-pr-lib.sh's fm_pr_task_id_valid and bin/fm-tasks-axi.sh accept). A repeated id counts
#   once. A train member is one value; the caller validates and canonicalizes it with
#   fm_pr_url_parse and matches by the full URL. A repeated value counts once.
# - The reader reads no Markdown and no HTML anywhere: no heading, fence, quote, list, table,
#   code span, comment or element is interpreted. It only finds the two marker lines.
# - The body is refused - nothing in it closes, and fm_pr_closes_refusal names why - when it
#   holds a line that carries the marker text (`firstmate-backlog-closes:`) but is not exactly a
#   marker line, more than one begin or end line, a begin line with no end line after it, an
#   end line with no begin line before it, or a line between them of any other kind. The
#   refusal is per body: a refused train member's body closes nothing, and the train's own
#   block and the other members are read as usual.
# - A body with no marker line has no block and closes nothing.
# - What it cannot tell apart: because nothing outside the marker lines is read, a whole, valid
#   block that a body quotes as an example (inside a fence, a quote or a `<details>` element)
#   is still the body's block, and it closes. Quote a block without its marker lines.
#
# Outside the block. Every line that is not inside a valid block (every line of a refused body)
# is plain text, read with no Markdown: fm_pr_closes_outside lists its well-formed directive
# lines, fm_pr_closes_malformed its column-0 lines that start with a directive word but do not
# fit the form, fm_pr_closes_legacy_ids the ids of its old `Closes: <item-id>` lines, and
# fm_pr_closes_prose the rest (the marker lines left out), whose words and pull request links
# bin/fm-pr-close-items.sh reads only to report that something was mentioned and closed nothing.
#
# Every reader takes a body file path (or `-` for standard input) and prints one value per line,
# once each. They never fail on a body without matches; they print nothing.

FM_PR_CLOSES_ID_RE='[A-Za-z0-9._-]+'
FM_PR_CLOSES_BEGIN='<!-- firstmate-backlog-closes:begin -->'
FM_PR_CLOSES_END='<!-- firstmate-backlog-closes:end -->'
FM_PR_CLOSES_MARKER='firstmate-backlog-closes:'

# fm_pr_closes_scan <body-file|->: one tagged line per body line, the marker lines left out.
# `R<TAB>reason` comes first when the body is refused; then `I<TAB>line` for a line inside the
# valid block and `O<TAB>line` for every other line (every line, when refused). A trailing
# carriage return is removed from each line.
fm_pr_closes_scan() {
  LC_ALL=C awk -v B="$FM_PR_CLOSES_BEGIN" -v E="$FM_PR_CLOSES_END" -v M="$FM_PR_CLOSES_MARKER" '
    { sub(/\r$/, ""); line[NR] = $0 }
    END {
      nb = 0; ne = 0; begin = 0; end = 0; reason = ""
      for (i = 1; i <= NR; i++) {
        t = line[i]; sub(/[ \t]+$/, "", t)
        if (t == B) { kind[i] = "m"; nb++; if (nb == 1) begin = i; continue }
        if (t == E) { kind[i] = "m"; ne++; if (ne == 1) end = i; continue }
        if (reason == "" && index(line[i], M) > 0)
          reason = sprintf("line %d holds the closes block marker text inside other text: %s", i, line[i])
      }
      if (reason == "" && (nb > 1 || ne > 1)) reason = "it holds more than one closes block"
      if (reason == "" && nb == 1 && ne == 0) reason = "its closes block has no end line"
      if (reason == "" && ne == 1 && (nb == 0 || end < begin)) reason = "it has a closes block end line with no begin line before it"
      if (reason == "" && nb == 1) {
        for (i = begin + 1; i < end; i++) {
          t = line[i]
          if (t ~ /^[ \t]*$/) continue
          if (t ~ /^Closes-backlog-item:[ \t]+[A-Za-z0-9_-][A-Za-z0-9._-]*[ \t]*$/) continue
          if (t ~ /^Train-member:[ \t]+[^ \t]+[ \t]*$/) continue
          reason = sprintf("line %d inside its closes block is neither a Closes-backlog-item: line, a Train-member: line nor blank: %s", i, t)
          break
        }
      }
      if (reason != "") print "R\t" reason
      for (i = 1; i <= NR; i++) {
        if (kind[i] == "m") continue
        if (reason == "" && nb == 1 && i > begin && i < end) print "I\t" line[i]
        else print "O\t" line[i]
      }
    }' "${1:--}"
}

# The reason a body is refused, or nothing.
fm_pr_closes_refusal() {  # <body-file|->
  fm_pr_closes_lines R "${1:--}"
}

# fm_pr_closes_lines <I|O|R> <body-file|->: the body lines inside (I) or outside (O) the block,
# or the refusal reason (R), each as written (leading whitespace kept).
fm_pr_closes_lines() {
  local want=$1 raw
  while IFS= read -r raw; do
    [ "${raw%%$'\t'*}" = "$want" ] && printf '%s\n' "${raw#*$'\t'}"
  done < <(fm_pr_closes_scan "${2:--}")
  return 0
}

# fm_pr_closes_directive <word> <I|O> <body-file|->: the value of each well-formed
# `<word>: value` line inside (I) or outside (O) the block, once each, in body order.
fm_pr_closes_directive() {
  local word=$1 where=$2 line value seen=$'\n'
  local re="^${word}:[[:space:]]+([^[:space:]]+)[[:space:]]*\$"
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || continue
    value=${BASH_REMATCH[1]}
    case "$seen" in *$'\n'"$value"$'\n'*) continue ;; esac
    seen="$seen$value"$'\n'
    printf '%s\n' "$value"
  done < <(fm_pr_closes_lines "$where" "${3:--}")
}

fm_pr_closes_ids() {  # <body-file|->
  local id id_re="^${FM_PR_CLOSES_ID_RE}\$"
  while IFS= read -r id; do
    [[ "$id" =~ $id_re ]] || continue
    case "$id" in .*) continue ;; esac
    printf '%s\n' "$id"
  done < <(fm_pr_closes_directive 'Closes-backlog-item' I "${1:--}")
}

fm_pr_closes_members() {  # <body-file|->
  fm_pr_closes_directive 'Train-member' I "${1:--}"
}

# The old line form outside the block: reported by the caller, never a directive.
fm_pr_closes_legacy_ids() {  # <body-file|->
  fm_pr_closes_directive 'Closes' O "${1:--}"
}

# A well-formed directive line outside the block (every one, when the body is refused). It
# closes nothing; the whole line is printed, once each.
fm_pr_closes_outside() {  # <body-file|->
  local line
  local id_re="^Closes-backlog-item:[[:space:]]+(${FM_PR_CLOSES_ID_RE})[[:space:]]*\$"
  local member_re='^Train-member:[[:space:]]+[^[:space:]]+[[:space:]]*$'
  while IFS= read -r line; do
    if [[ "$line" =~ $id_re ]]; then
      case "${BASH_REMATCH[1]}" in .*) continue ;; esac
    elif ! [[ "$line" =~ $member_re ]]; then
      continue
    fi
    printf '%s\n' "$line"
  done < <(fm_pr_closes_lines O "${1:--}") | LC_ALL=C awk '!seen[$0]++'
}

# A column-0 line outside the block that starts with a directive word (the two forms and the old
# `Closes:`) but does not fit its form: an id with a bad character or a leading `.`, a missing
# or doubled value, trailing text. The whole line is printed, once each.
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
  done < <(fm_pr_closes_lines O "${1:--}") | LC_ALL=C awk '!seen[$0]++'
}

# The text outside the block that is not a column-0 directive-word line, as plain text.
fm_pr_closes_prose() {  # <body-file|->
  local line
  local directive_re='^(Closes-backlog-item|Train-member|Closes):'
  while IFS= read -r line; do
    [[ "$line" =~ $directive_re ]] || printf '%s\n' "$line"
  done < <(fm_pr_closes_lines O "${1:--}")
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
