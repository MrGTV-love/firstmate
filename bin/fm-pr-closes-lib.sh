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
# - A NUL byte anywhere in the body refuses it before any pass (Main 1785 F2), since a tool on
#   the way may drop it. bin/fm-pr-close-items.sh writes the forge's bytes to files, never
#   through command substitution, and refuses a body any read step failed to write in full.
# - A parse that fails (its snapshot or pass cannot run) gives `status failed`, never `block`, so
#   it closes nothing; the caller reports it (Main 1785 F3).
# - One token reading (Main 1785 F4): the value of an exact directive line is the same for the
#   close and for every report, so a refusal names each id exactly as written.
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
#   status   block (an honored block), refused, none (no line holds the marker text), or
#            failed (the parse could not run; fm_pr_closes_failed, exit 1)
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
  local merged=${2:-} snap result member members why='' size kept rc=0
  # A failure of the parse itself (Main 1785 F3) prints `status failed` and its reason, with the
  # ids the same pass can read from the original file under a forced refusal, and returns 1.
  if ! snap=$(mktemp "${TMPDIR:-/tmp}/fm-pr-closes.XXXXXX" 2>/dev/null); then
    fm_pr_closes_failed "$1" "$merged" "the parse could not make its snapshot"
    return 1
  fi
  if ! cat -- "$1" > "$snap" 2>/dev/null; then
    rm -f -- "$snap"
    fm_pr_closes_failed "$1" "$merged" "the parse could not copy the body into its snapshot"
    return 1
  fi
  # Main 1785 F2: a NUL byte anywhere refuses the whole body before any pass, because a tool on
  # the way (a command substitution, an awk) may drop it; the forced pass reads a copy with each
  # NUL shown as `?`, only for the report.
  size=$(LC_ALL=C wc -c < "$snap" | tr -d ' ') && kept=$(LC_ALL=C tr -d '\000' < "$snap" | LC_ALL=C wc -c | tr -d ' ') || rc=1
  if [ "$rc" -eq 0 ] && [ "$size" != "$kept" ]; then
    LC_ALL=C tr '\000' '?' < "$snap" > "$snap.nul" && result=$(fm_pr_closes_pass "$snap.nul" "$merged" "the body contains a NUL byte, so nothing in it is read as a closes block") || rc=1
    rm -f -- "$snap" "$snap.nul"
    [ "$rc" -eq 0 ] || { fm_pr_closes_failed "$1" "$merged" "the parse could not read its snapshot"; return 1; }
    printf '%s\n' "$result"
    return 0
  fi
  [ "$rc" -eq 0 ] && result=$(fm_pr_closes_pass "$snap" "$merged" '') || rc=1
  if [ "$rc" -eq 0 ] && [ "${result%%$'\n'*}" = "$(printf 'status\tblock')" ]; then
    # Main 1851 F1: the member list is read into a variable and its status checked; when it
    # cannot be read, the whole block is refused before any item in it can act.
    if ! members=$(fm_pr_closes_values "$result" member); then
      why="its Train-member values could not be read for validation"
      members=''
    fi
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
    done <<< "$members"
    [ -z "$why" ] || result=$(fm_pr_closes_pass "$snap" "$merged" "$why") || rc=1
  fi
  rm -f -- "$snap"
  [ "$rc" -eq 0 ] || { fm_pr_closes_failed "$1" "$merged" "the parse's pass failed"; return 1; }
  printf '%s\n' "$result"
}

# fm_pr_closes_failed <body-file> <merged-pr-url> <reason>: the result of a parse that failed:
# `status failed`, the reason, and the seenid and seenpr records the same pass reads from the
# original file under a forced refusal, when it can.
fm_pr_closes_failed() {
  printf 'status\tfailed\nreason\t%s\n' "$3"
  fm_pr_closes_pass "$1" "$2" "$3" 2>/dev/null | LC_ALL=C awk -F '\t' '$1 == "seenid" || $1 == "seenpr"'
  return 0
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
    # The one token reading (Main 1785 F4): the value of an exact directive line, the same for
    # the close (id, member, legacy) and for every report (seenid, seenpr).
    function token(l) { return substr(l, index(l, ": ") + 2) }
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
    function seen_tokens(l,   w, word, rest, p, n, j, t, tok, k) {
      k = kind(l)
      if (k == "id" || k == "legacy") { out("seenid", token(l)); links(l, "seenpr"); return }
      if (k == "member") { out("seenpr", token(l)); links(l, "seenpr"); return }
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
            # A token is kept as written when it has an id or link shape; only otherwise is
            # trailing sentence punctuation dropped.
            if (t !~ /^https?:\/\// && !idform(t)) sub(/[.;:]+$/, "", t)
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
            if (token(t) == U) { reason = sprintf("line %d inside its closes block names the merged pull request itself as a Train-member: %s", i, t); break }
            continue
          }
          reason = sprintf("line %d inside its closes block is not exactly a Closes-backlog-item: <item-id> line, a Train-member: <url> line or an empty line: %s", i, t)
        }
      }
      if (F != "" && reason == "") reason = F
      # A forced reason (a NUL byte, an invalid member) refuses the body even when it has no
      # marker line (Main 1851 F5).
      status = (reason != "") ? "refused" : (nm == 0) ? "none" : "block"
      print "status\t" status
      if (reason != "") print "reason\t" reason
      for (i = 1; i <= NR; i++) {
        t = line[i]
        if (status == "block" && (i == first || i == end)) continue
        if (status == "block" && i > first && i < end) {
          if (t == "") continue
          k = kind(t)
          if (k == "id") out("id", token(t))
          else out("member", token(t))
          continue
        }
        k = kind(t)
        if (k == "id" || k == "member") out("outside", t)
        else if (k == "malformed") out("malformed", t)
        else if (k == "legacy") out("legacy", token(t))
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

# fm_pr_closes_values <parse-result-text> <type>: the same, from a result held in a variable.
fm_pr_closes_values() {  # <parse-result-text> <type>
  printf '%s\n' "$1" | LC_ALL=C awk -v t="$2" '{ i = index($0, "\t"); if (substr($0, 1, i - 1) == t) print substr($0, i + 1) }'
}

# fm_pr_closes_load <parse-result-file>: reads the status, ids and members of a parse result
# whole, each with its reader's status checked (Main 1851 F2), into FM_PR_CLOSES_STATUS,
# FM_PR_CLOSES_IDS and FM_PR_CLOSES_MEMBERS (newline lists). Returns 1, with all three empty,
# when any of them cannot be read, so a caller acts on all of a body's items or on none.
fm_pr_closes_load() {  # <parse-result-file>
  local status ids members
  # shellcheck disable=SC2034  # The callers read these.
  FM_PR_CLOSES_STATUS='' FM_PR_CLOSES_IDS='' FM_PR_CLOSES_MEMBERS=''
  status=$(fm_pr_closes_get "$1" status) || return 1
  ids=$(fm_pr_closes_get "$1" id) || return 1
  members=$(fm_pr_closes_get "$1" member) || return 1
  case "$status" in block|refused|none|failed) ;; *) return 1 ;; esac
  # shellcheck disable=SC2034  # The callers read these.
  FM_PR_CLOSES_STATUS=$status FM_PR_CLOSES_IDS=$ids FM_PR_CLOSES_MEMBERS=$members
  return 0
}
