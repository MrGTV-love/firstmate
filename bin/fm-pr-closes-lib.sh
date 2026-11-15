# shellcheck shell=bash
# fm-pr-closes-lib.sh - the one owner of the closes block: the one place in a pull request body
# that names the backlog items a merge closes and the pull requests a merge train lands.
# bin/fm-pr-close-items.sh reads it. Usage: . bin/fm-pr-closes-lib.sh
#
# The block (Main 3039 and 043; Main 045 makes it strict). A body names what it closes only in
# one block, which must open the body:
#
#   <!-- firstmate-backlog-closes:begin -->
#   Closes-backlog-item: <item-id>
#   Train-member: <pull request URL>
#   <!-- firstmate-backlog-closes:end -->
#
# The block is honored only when all of these hold; it acts only on positive proof, and any
# doubt refuses the whole body (Main 045, "refuse when in doubt"):
# - The begin line is the body's first non-empty line, exactly that text from column 0. A line
#   is empty when it has no characters once one trailing carriage return (GitHub bodies often
#   use CRLF) is removed; every line loses that one carriage return before any check.
# - One end line follows, exactly that text.
# - The marker text (`firstmate-backlog-closes:`) appears on no other line of the body.
# - Every line between them is printable ASCII (no tab, no control byte, nothing above 0x7E)
#   and is one of three exact forms: an empty line; `Closes-backlog-item: <item-id>` with one
#   space and nothing after the id; `Train-member: <url>` with one space and nothing after the
#   URL, where the URL is, by canonical full-URL identity, a GitHub, GitLab or Forgejo pull
#   request URL as bin/fm-pr-lib.sh's fm_pr_url_parse (the one owner of that URL grammar)
#   accepts it, of any repository, and not the merged pull request itself (Main 047). A Gerrit
#   change, another form or a URL that is not a pull request refuses the body.
# - An item id is letters, digits, `.`, `_` and `-`, not starting with `.` (the ids
#   bin/fm-pr-lib.sh's fm_pr_task_id_valid and bin/fm-tasks-axi.sh accept). A repeated id or
#   member counts once.
# - A body with no line holding the marker text has no block and closes nothing; it is not a
#   refusal.
# The reader interprets no Markdown and no HTML. Because the block must open the body, any
# block that a body quotes as an example (in a code span, a fence, a quote, a table, a div, a
# details element, a comment or a member body's example) is either not first or puts marker text
# on a second line, and it refuses the whole body. A real block below any other text refuses too:
# that over-refusal is the intended price of acting only on positive proof.
#
# One parse (Main 046). fm_pr_closes_parse reads a body once, with the one grammar above, and
# prints its whole typed result; bin/fm-pr-close-items.sh takes every close, edge change and
# report from that result alone, and only after the whole result is known. There is no second
# scanner or grammar: the outside-line kinds below use the same line forms as the block.
#
# Outside the block. Every line that is not inside an honored block (every line of a refused
# body) is plain text, read only for reports; nothing outside an honored block closes anything.

# The one owner of the pull request URL grammar (fm_pr_url_parse), which judges each member.
if ! declare -F fm_pr_url_parse >/dev/null; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-pr-lib.sh"
fi

FM_PR_CLOSES_BEGIN='<!-- firstmate-backlog-closes:begin -->'
FM_PR_CLOSES_END='<!-- firstmate-backlog-closes:end -->'
FM_PR_CLOSES_MARKER='firstmate-backlog-closes:'

# fm_pr_closes_parse <body-file> <merged-pr-url>: the one parse. <merged-pr-url> is the merged
# pull request this body belongs to (the train's own URL for a train member's body), which may
# not be a member. The body file is read once, into a snapshot; the structural pass judges it
# with the one line grammar, each block member is then checked with fm_pr_url_parse, and a
# member that fails refuses the whole body, so the same pass runs again on the same snapshot
# with that reason. Prints one record per line, `<type><TAB><value>`, in this order:
#   status   block (an honored block), refused, or none (no line holds the marker text)
#   reason   why the body is refused (refused only)
#   id       an item id of a `Closes-backlog-item:` line inside the honored block, once each
#   member   a `Train-member:` URL inside the honored block, once each
#   outside  a well-formed `Closes-backlog-item:` or `Train-member:` line outside it, once each
#   malformed  a column-0 line outside it that starts with `Closes-backlog-item:`,
#            `Train-member:` or `Closes:` but is not exactly one of the line forms, once each
#   legacy   the id of a well-formed old `Closes: <item-id>` line outside it, once each
#   word     a word of the text read for mentions (every outside line except a well-formed
#            `Closes-backlog-item:` or `Closes:` line), as an item-id candidate, once each
#   link     a pull request, merge request or change link in that text, once each
#   seenid   an id-shaped token after a directive word anywhere in the body, once each
#   seenpr   a link token after a directive word, or a pull request link, anywhere, once each
# Line forms (the one grammar): `Closes-backlog-item: <item-id>` and `Closes: <item-id>` with
# one space and nothing after the id; `Train-member: <url>` with one space and one value with no
# space after it, the value being a pull request URL by fm_pr_url_parse.
fm_pr_closes_parse() {  # <body-file> <merged-pr-url>
  local merged=${2:-} snap result member why=''
  snap=$(mktemp "${TMPDIR:-/tmp}/fm-pr-closes.XXXXXX") || return 1
  cat -- "$1" > "$snap" || { rm -f -- "$snap"; return 1; }
  result=$(fm_pr_closes_pass "$snap" "$merged" '')
  if [ "${result%%$'\n'*}" = "$(printf 'status\tblock')" ]; then
    while IFS= read -r member; do
      [ -n "$member" ] || continue
      if ! fm_pr_url_parse "$member" || [ "$FM_PR_URL" != "$member" ]; then
        why="its closes block names Train-member $member, which is not a GitHub, GitLab or Forgejo pull request URL in its canonical form"
      else
        case "$FM_PR_PROVIDER" in
          github|gitlab|forgejo) ;;
          *) why="its closes block names Train-member $member, a ${FM_PR_PROVIDER:-unknown} URL, which is not a GitHub, GitLab or Forgejo pull request URL" ;;
        esac
      fi
      [ -z "$why" ] || break
    done <<< "$(printf '%s\n' "$result" | LC_ALL=C awk -F '\t' '$1 == "member" { print substr($0, 8) }')"
    [ -z "$why" ] || result=$(fm_pr_closes_pass "$snap" "$merged" "$why")
  fi
  rm -f -- "$snap"
  printf '%s\n' "$result"
}

# fm_pr_closes_pass <snapshot> <merged-pr-url> <forced-reason>: the structural pass of the one
# parse; a non-empty <forced-reason> refuses the body with it. Called only by fm_pr_closes_parse.
fm_pr_closes_pass() {
  LC_ALL=C awk -v B="$FM_PR_CLOSES_BEGIN" -v E="$FM_PR_CLOSES_END" -v M="$FM_PR_CLOSES_MARKER" \
    -v U="$2" -v F="$3" '
    function out(t, v) { if (!seen[t "\t" v]++) print t "\t" v }
    function idform(v) { return v ~ /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/ }
    # The one grammar: the kind of a line.
    function kind(l,   v) {
      if (substr(l, 1, 21) == "Closes-backlog-item: ") return idform(substr(l, 22)) ? "id" : "malformed"
      if (substr(l, 1, 8) == "Closes: ") return idform(substr(l, 9)) ? "legacy" : "malformed"
      if (substr(l, 1, 14) == "Train-member: ") return (substr(l, 15) ~ /^[^ ]+$/) ? "member" : "malformed"
      if (l ~ /^(Closes-backlog-item|Train-member|Closes):/) return "malformed"
      return "prose"
    }
    function words(l,   n, i, w, t, e, parts) {
      n = split(l, parts, /[^A-Za-z0-9._-]+/)
      for (i = 1; i <= n; i++) {
        w = parts[i]
        if (w == "") continue
        out("word", w)
        t = w; sub(/^\.+/, "", t); sub(/\.+$/, "", t)
        if (t != "" && t != w) out("word", t)
        e = t
        if (e ~ /^__.+__$/) e = substr(e, 3, length(e) - 4)
        else if (e ~ /^_.+_$/) e = substr(e, 2, length(e) - 2)
        if (e != "" && e != t) out("word", e)
      }
    }
    function links(l, t,   rest) {
      rest = l
      while (match(rest, /https?:\/\/[A-Za-z0-9.-]+(:[0-9]+)?\/[A-Za-z0-9._~\/+-]*\/(pull|pulls|merge_requests|\+)\/[0-9]+/)) {
        out(t, substr(rest, RSTART, RLENGTH))
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    function seen_tokens(l,   w, word, rest, p, n, j, t, tok) {
      for (w = 1; w <= 3; w++) {
        word = (w == 1) ? "Closes-backlog-item:" : (w == 2) ? "Closes:" : "Train-member:"
        rest = l
        while ((p = index(rest, word)) > 0) {
          rest = substr(rest, p + length(word))
          n = split(rest, tok, /[[:space:],"'"'"'`<>()|\[\]]+/)
          for (j = 1; j <= n; j++) {
            t = tok[j]
            if (t == "") continue
            if (t ~ /^(Closes-backlog-item|Closes|Train-member):/) break
            sub(/[.;:]+$/, "", t)
            if (t ~ /^https?:\/\//) out("seenpr", t)
            else if (idform(t)) out("seenid", t)
          }
        }
      }
      links(l, "seenpr")
    }
    { sub(/\r$/, ""); line[NR] = $0 }
    END {
      nm = 0; first = 0; end = 0; reason = ""
      for (i = 1; i <= NR; i++) {
        if (!first && length(line[i]) > 0) first = i
        if (index(line[i], M) > 0) { nm++; if (nm == 2) end = i }
      }
      if (nm > 0) {
        if (line[first] != B) {
          if (index(line[first], M) > 0)
            reason = sprintf("its first non-empty line, line %d, holds the closes block marker text but is not exactly the begin line: %s", first, line[first])
          else
            reason = sprintf("its first non-empty line, line %d, is not the closes block begin line, so any block it holds is not at the top of the body: %s", first, line[first])
        } else if (nm == 1) reason = "its closes block has no end line"
        else if (line[end] != E) reason = sprintf("line %d holds the closes block marker text but is not exactly the end line: %s", end, line[end])
        else if (nm > 2) {
          for (i = end + 1; i <= NR; i++) if (index(line[i], M) > 0) break
          reason = sprintf("line %d holds the closes block marker text outside its one block: %s", i, line[i])
        }
        for (i = first + 1; reason == "" && i < end; i++) {
          t = line[i]
          if (t == "") continue
          if (t !~ /^[ -~]+$/) { reason = sprintf("line %d inside its closes block holds a tab, a control byte or a byte that is not printable ASCII", i); break }
          k = kind(t)
          if (k == "id") continue
          if (k == "member") {
            if (substr(t, 15) == U) { reason = sprintf("line %d inside its closes block names the merged pull request itself as a Train-member: %s", i, t); break }
            continue
          }
          reason = sprintf("line %d inside its closes block is not exactly a Closes-backlog-item: <item-id> line, a Train-member: <url> line or an empty line: %s", i, t)
        }
      }
      if (F != "" && reason == "") reason = F
      status = (nm == 0) ? "none" : (reason == "") ? "block" : "refused"
      print "status\t" status
      if (reason != "") print "reason\t" reason
      for (i = 1; i <= NR; i++) {
        t = line[i]
        if (status == "block" && (i == first || i == end)) continue
        if (status == "block" && i > first && i < end) {
          if (t == "") continue
          k = kind(t)
          if (k == "id") out("id", substr(t, 22))
          else out("member", substr(t, 15))
          continue
        }
        k = kind(t)
        if (k == "id" || k == "member") out("outside", t)
        else if (k == "malformed") out("malformed", t)
        else if (k == "legacy") out("legacy", substr(t, 9))
        if (k != "id" && k != "legacy") { words(t); links(t, "link") }
      }
      for (i = 1; i <= NR; i++) seen_tokens(line[i])
    }' "$1"
}

# fm_pr_closes_get <parse-result-file> <type>: the values of one record type of a parse result,
# in order. It reads the result, never a body.
fm_pr_closes_get() {  # <parse-result-file> <type>
  LC_ALL=C awk -v t="$2" '{ i = index($0, "\t"); if (substr($0, 1, i - 1) == t) print substr($0, i + 1) }' "$1"
}
