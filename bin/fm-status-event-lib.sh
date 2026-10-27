#!/usr/bin/env bash
if ! command -v _fm_decision_key >/dev/null 2>&1; then
  # shellcheck source=bin/fm-status-decision-lib.sh
  . "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-status-decision-lib.sh"
fi

# How many trailing lines the latest-event read parses before it widens to the
# whole file. A status record and its continuation prose sit within a few lines
# of the log's end, so this bounds the watcher's per-poll read on a long-lived
# log while a log whose tail holds no event still gets a full pass.
FM_CLASSIFY_EVENT_WINDOW_LINES=200
# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
# A declaration whose prefix is not one of those verbs is still an event, shown
# as the line itself. That covers an unknown word such as parked: or holding:,
# and a known verb whose correlation token is missing or mismatched, so the
# declaration cannot disappear behind an earlier recognized line. Continuation
# prose is not a prefix and stays off that path. Recognized verbs keep the
# classification below.
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The declared-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare a known wait expected to clear on its own. The legacy "external
# wait" name and "awaiting external" reason also cover the worker's own work;
# they do not identify a separate classification or liveness source.
# bin/fm-brief.sh owns worker-facing declaration and resolution instructions.
# Unlike `blocked:` (stuck, firstmate must help), an idle `paused:` pane is EXPECTED, so
# the stale path bounds repeats instead of escalating a possible wedge; a live
# idle worker can still surface a first-sight stale alert. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'
_FM_CLASSIFY_KEYLESS_PHASE=$'\036default'
# The body of the note the generated OMP extension appends when a native model
# fallback serves a request. It is a machine notice, not a status event, so it
# never replaces the worker's own latest declaration.
FM_STATUS_FALLBACK_NOTICE='model-matrix fallback served '
# Return the last recognized status event, ignoring continuation prose and blanks
# (empty if missing/blank), and with <previous-event-var> the event before it.
# The optional previous event is what this reader returned before the latest one
# was appended, so a consumer can name the head it is superseding; asking for it
# always reads the log's history (_fm_status_event_history), since a bounded window
# cannot bound two events; a log past the read limit (bin/fm-status-cap-lib.sh) is
# refused and nothing is read.
# A whole-log read that is refused leaves both events empty and returns 2, which a
# caller reads as unknown, never as a log with no event.
# This is an event read; status_current_line in bin/fm-classify-lib.sh reconciles open decisions.
last_status_line() {  # <status-file> [<previous-event-var>]
  local f=$1 scan='' rc=0
  [ -f "$f" ] && [ -r "$f" ] || return 0
  if [ "$#" -gt 1 ] || ! scan=$(fm_status_tail_lines "$f" "$FM_CLASSIFY_EVENT_WINDOW_LINES" | _fm_status_event_scan); then
    scan=$(_fm_status_event_history "$f" 2>/dev/null | _fm_status_event_scan; [ "${PIPESTATUS[0]}" -ne 2 ] || exit 2) || rc=$?
  fi
  [ "$#" -lt 2 ] || printf -v "$2" '%s' "${scan%%$'\n'*}"
  printf '%s\n' "${scan##*$'\n'}"
  return "$rc"
}

# The lines on stdin a whole-log event scan must look at, in order: the event-shaped
# lines, a superset of every line _fm_status_line_is_event can accept, and then the last
# nonblank line when it is not one of them, so a scan's no-event answer is the line it
# always was. A line is event-shaped when it holds a colon and its head (the text before
# the first colon or bracket) is a recognized verb or holds a `corr` token; when, with
# its `[at=...]` stamps removed as _fm_status_unstamped removes them, its first colon (even
# one inside a bracket tag) is followed by a space or ends the line, and the text before
# the first bracket or that colon is one word that starts with no capital, digit or
# punctuation, or the text before that colon holds `corr`; or when a captain token
# (FM_CAPTAIN_RE) starts it, in any case.
# One awk pass: the shell loop after it walks only these, so prose, counters, labels and
# URLs cost it nothing. With `numbered <base>` each line is `<byte offset>\t<line>`, the
# offset counted from <base>, the log byte where stdin starts, and the last nonblank line
# is not added.
_fm_status_event_candidates() {  # [numbered <base>]
  FM_STATUS_EVENT_CANDIDATE_RE="(${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT})" \
    FM_STATUS_EVENT_CANDIDATE_VERBS="working needs-decision blocked done failed note ${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT} ${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT} ${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" \
    LC_ALL=C awk -v numbered="${1:+1}" -v base="${2:-0}" '
    BEGIN {
      re = "^[[:space:]]*" tolower(ENVIRON["FM_STATUS_EVENT_CANDIDATE_RE"])
      n = split(ENVIRON["FM_STATUS_EVENT_CANDIDATE_VERBS"], v, " ")
      for (i = 1; i <= n; i++) verbs[v[i]] = 1
    }
    {
      cand = 0
      if (index($0, ":") > 0) {
        head = $0; sub(/[:[].*$/, "", head); sub(/^[[:space:]]+/, "", head); sub(/[[:space:]]+$/, "", head)
        cand = (head in verbs) || index(head, "corr") > 0
      }
      if (!cand) {
        t = $0; gsub(/ ?\[at=[^]]*\]/, "", t); sub(/^[[:space:]]+/, "", t)
        c = index(t, ":")
        if (c > 0 && (c == length(t) || substr(t, c + 1, 1) ~ /[[:space:]]/)) {
          head = substr(t, 1, c - 1); word = head; sub(/\[.*$/, "", word); sub(/[[:space:]]+$/, "", word)
          cand = index(head, "corr") > 0 || (word !~ /[[:space:]]/ && word ~ /^[^A-Z0-9[:punct:]]/)
        }
        if (!cand) cand = tolower(t) ~ re || tolower($0) ~ re
      }
      if (cand) { if (numbered) print base + pos "\t" $0; else print }
      if ($0 ~ /[^[:space:]]/) { last = $0; last_cand = cand }
      pos += length($0) + 1
    }
    END { if (!numbered && last != "" && !last_cand) print last }'
}

# The byte where a whole-log event scan of a log of <endpoint> bytes starts, into
# <out-var>: 0, the whole log. The watcher sets FM_STATUS_EVENT_SCAN_TAIL=1, because it
# runs these scans for every window on every poll: there a scan starts no earlier than
# one tail window (bin/fm-status-cap-lib.sh) before the end. The caller reads from one
# byte before that start and drops the first line, so it drops a partial first line and
# keeps a whole one. A healthy log fits in that window whole.
_fm_status_event_scan_start() {  # <endpoint> <out-var>
  local __fm_es_window
  printf -v "$2" '%s' 0
  [ "${FM_STATUS_EVENT_SCAN_TAIL:-0}" = 1 ] || return 0
  fm_status_window_bytes __fm_es_window
  [ "$1" -le "$__fm_es_window" ] || printf -v "$2" '%s' "$(($1 - __fm_es_window))"
}

# The candidate event lines (_fm_status_event_candidates) of a status log's history:
# the whole log, read exactly up to the read limit (fm_status_cat), or in the watcher
# its last tail window (_fm_status_event_scan_start). The status is the read's, so a
# refusal is 2.
_fm_status_event_history() {  # <status-file>
  local size start rc
  _fm_status_file_size "$1" size || return 1
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  _fm_status_event_scan_start "$size" start
  if [ "$start" -eq 0 ]; then
    fm_status_cat "$1" | _fm_status_event_candidates
    rc=${PIPESTATUS[0]}
  else
    _fm_status_read_span "$1" "$((start - 1))" "$((size - start + 1))" 0 | tail -n +2 | _fm_status_event_candidates
    rc=${PIPESTATUS[0]}
  fi
  return "$rc"
}

# 0 when <verb> is exactly one recognized status verb, with no leftover token.
_fm_status_verb_recognized() {  # <verb>
  case "$1" in
    working|needs-decision|blocked|done|failed|note|\
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}"|\
    "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}"|\
    "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}")
      return 0
      ;;
  esac
  return 1
}

# 0 when <word> is a correlation-token attempt the strict parser did not accept.
# A well-formed token is stripped before this sees the verb, so only a missing
# or mismatched token remains here.
_fm_status_corr_attempt() {  # <word>
  case "$1" in
    corr|corr=*) return 0 ;;
  esac
  return 1
}

# 0 when <line> declares a status prefix that did not parse as a recognized verb.
# An unknown lowercase word (parked:, holding:) is one shape. A recognized verb
# followed only by a missing or mismatched correlation token is the other, as is
# a token written ahead of the verb. The line stays that text: it does not
# become the verb the token failed to separate. Continuation prose is not a
# prefix, including a sentence that merely starts with a known verb, a label
# such as Reason: or e.g.:, a URL, or a clock time such as 10:30.
status_prefix_unrecognized() {  # <status-line>
  local line verb first rest word
  _fm_status_unstamped "$1" line
  case "$line" in *:*) ;; *) return 1 ;; esac
  case "${line#*:}" in ''|[[:space:]]*) ;; *) return 1 ;; esac
  status_line_verb "$line" verb
  [ -n "$verb" ] || return 1
  _fm_status_verb_recognized "$verb" && return 1
  first=${verb%%[[:space:]]*}
  rest=${verb#"$first"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  if [ -z "$rest" ]; then
    case "$first" in [[:lower:]]*) ;; *) return 1 ;; esac
    case "$first" in *[![:lower:]-]*) return 1 ;; esac
    return 0
  fi
  if _fm_status_corr_attempt "$first"; then
    word=${rest%%[[:space:]]*}
    _fm_status_verb_recognized "$word" || return 1
    rest=${rest#"$word"}
    rest=${rest#"${rest%%[![:space:]]*}"}
  else
    _fm_status_verb_recognized "$first" || return 1
  fi
  while [ -n "$rest" ]; do
    word=${rest%%[[:space:]]*}
    _fm_status_corr_attempt "$word" || return 1
    rest=${rest#"$word"}
    rest=${rest#"${rest%%[![:space:]]*}"}
  done
  return 0
}

# Print "<previous event>\n<latest event>" for the status lines on stdin, and
# return 1 when the stream holds no event at all, so a caller reading a bounded
# window knows to widen it. A stream without events keeps its last nonblank
# line as the latest, matching the read this replaced.
# Keep decision-closing events: skipping a resolved line would revive its opener.
# A bare legacy free-text line counts as an event only when a captain token leads
# it, so continuation prose that merely mentions one cannot hide a declaration.
# An unrecognized status prefix is an event too, so that declaration is the
# latest line instead of disappearing behind an earlier recognized one.
_fm_status_event_scan() {
  local line last='' prev='' fallback='' legacy_re
  legacy_re="^[[:space:]]*(${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT})"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "${FM_STATUS_SPAN_TICK:-}" ] || "$FM_STATUS_SPAN_TICK"
    case "$line" in *[![:space:]]*) fallback=$line ;; *) continue ;; esac
    _fm_status_line_is_event "$line" "$legacy_re" && { prev=$last; last=$line; }
  done
  printf '%s\n%s\n' "$prev" "${last:-$fallback}"
  [ -n "$last" ]
}

# 0 when a nonblank <line> is a recognized status event for the scan above.
_fm_status_line_is_event() {  # <line> <legacy-captain-re>
  local verb unstamped
  case "$1" in "note [at="*"]: $FM_STATUS_FALLBACK_NOTICE"*) return 1 ;; esac
  case "$1" in *:*) status_line_verb "$1" verb ;; *) verb='' ;; esac
  _fm_status_verb_recognized "$verb" && return 0
  # Unrecognized verb-shaped prefixes (parked:, holding:, bad corr tokens) stay
  # events so a bad declaration cannot vanish behind an earlier recognized line.
  status_prefix_unrecognized "$1" && return 0
  _fm_status_unstamped "$1" unstamped
  _fm_classify_matches "$unstamped" "$2"
}

# 0 when <line> matches the extended regex <pattern> case-insensitively, leaving
# the caller's nocasematch setting untouched.
_fm_classify_matches() {  # <line> <pattern>
  local matched=1 restore_case=0
  shopt -q nocasematch || { shopt -s nocasematch; restore_case=1; }
  [[ "$1" =~ $2 ]] && matched=0
  [ "$restore_case" -eq 0 ] || shopt -u nocasematch
  return "$matched"
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
# Regex matching ignores any emission-time tag before the first colon - here and
# in the shared event scan, the module's two FM_CAPTAIN_RE sites - so an override
# keeps matching a stamped event however the worker spelled the stamp; other
# metadata and note text remain intact, as do the stored and surfaced event bytes.
status_is_captain_relevant() {
  local line=$1 verb unstamped
  [ -n "$line" ] || return 1
  status_line_verb "$line" verb
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  # An unrecognized prefix is surfaced as itself. The check sits after the
  # recognized nonterminal verbs, so working, paused, resolved, and captain-held
  # keep their existing non-relevant classification.
  status_prefix_unrecognized "$line" && return 0
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  _fm_status_unstamped "$line" unstamped
  _fm_classify_matches "$unstamped" "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line's leading verb is the verified captain-held transfer verb.
# The same pure verb read as status_is_paused, and the discriminator a supervisor
# needs once a declared wait has already been recognized: the two declarations get
# the same bounded cadence, but they block on DIFFERENT humans, so a recheck that
# names an external dependency for a hold points the captain away from the fact
# that they are the one who can clear it.
status_is_captain_held() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave a crew's endpoint idle, so both
# supervisors give them one cadence: the away-mode daemon defers the wedge and
# ages a pause marker instead, and the watcher applies its bounded pause cadence
# once pause_state_class has admitted the wait (fm-watch.sh owns which liveness
# evidence each kind of crew must supply for that).
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1
  status_is_paused "$line" || status_is_captain_held "$line"
}

# The status line that holds a crew in a declared wait, or nothing when it is in
# none. Supervisors decide the wait from this line, never from the raw latest
# event: a resolved line is also how firstmate answers a decision (fm-send
# --resolve-key), and one that lands after a pause for a different phase key -
# including the stated default key a keyless decision shares - does not end the
# pause. Only a resolved line for the pause's own phase key (the keyed
# activity fold's key, where a keyless line is its own phase) retracts it, as
# does any other later event. A captain-held line counts only while it is the
# latest event. Bounded like last_status_line: only a tail window made wholly of
# resolved events widens the read to the log's history (_fm_status_event_history).
status_declared_wait_line() {  # <status-file>
  local f=$1 last verb resolve legacy_re
  last=$(last_status_line "$f")
  if status_is_paused_or_captain_held "$last"; then
    printf '%s\n' "$last"
    return 0
  fi
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  status_line_verb "$last" verb
  [ "$verb" = "$resolve" ] || return 0
  legacy_re="^[[:space:]]*(${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT})"
  fm_status_tail_lines "$f" "$FM_CLASSIFY_EVENT_WINDOW_LINES" \
    | _fm_status_declared_wait_scan "$resolve" "$legacy_re" \
    || _fm_status_event_history "$f" 2>/dev/null | _fm_status_declared_wait_scan "$resolve" "$legacy_re" || :
}

# Walk the status lines on stdin back from the newest event past resolved lines
# to the first other event, and print it when it is a pause none of those
# resolved lines share a phase key with. Returns 1 when every event is a
# resolved line, so a caller reading a bounded window knows to widen it.
_fm_status_declared_wait_scan() {  # <resolve-verb> <legacy-captain-re>
  local resolve=$1 legacy_re=$2 line verb key keys=$'\n' i=0
  local -a _fm_wait_scan_lines=()
  while IFS= read -r line || [ -n "$line" ]; do
    _fm_wait_scan_lines[i]=$line
    i=$((i + 1))
  done
  while [ "$i" -gt 0 ]; do
    [ -z "${FM_STATUS_SPAN_TICK:-}" ] || "$FM_STATUS_SPAN_TICK"
    i=$((i - 1))
    line=${_fm_wait_scan_lines[i]}
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    _fm_status_line_is_event "$line" "$legacy_re" || continue
    status_line_verb "$line" verb
    case "$verb" in
      "$resolve") ;;
      "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") ;;
      *) return 0 ;;
    esac
    key=$(_fm_decision_key "$line" "$_FM_CLASSIFY_KEYLESS_PHASE") || key=
    if [ "$verb" = "$resolve" ]; then
      keys="$keys$key"$'\n'
      continue
    fi
    case "$keys" in *$'\n'"$key"$'\n'*) return 0 ;; esac
    printf '%s\n' "$line"
    return 0
  done
  return 1
}

# The identity of the declared wait status_declared_wait_line names, for a
# consumer that must tell a RESTATED wait from a REPLACEMENT one. Prints
# `<key>:<cksum>:<offset>` and returns 0 while a wait is declared; returns 1 when
# none is declared or the read fails. declared_wait_scope in bin/fm-watch.sh owns
# the fail-open fallback. The identity is the FIRST line of the contiguous episode:
# the declared line plus earlier lines of the same verb and key, reaching back past
# resolved lines for other keys, and stopping at any other event or at a resolved
# line for this key. A key re-declared after its own resolved line is therefore a
# new episode even when both landed between two polls. A keyless line has no key
# to compare, so it is its own episode (key `-`) and any new keyless text is a
# replacement. <cksum> and <offset> bind the identity to that first line's text and
# position, the byte offset where it starts in the log, so two identical lines in
# different episodes stay distinct.
# Declaration, line count, and episode position all come from one captured byte
# endpoint, so an append during the read cannot change the episode's position.
# The episode is walked over the snapshot's numbered candidate event lines
# (_fm_status_event_candidates), so non-event lines cost the walk nothing; the walk
# takes the last window of them first and widens to all of them when it finds no opener
# or the episode remains open at the window's start. In the watcher the snapshot is the
# log's last tail window (_fm_status_event_scan_start); the offset is still counted from
# the start of the log, so the identity is the same in both modes and does not move as
# the window does.
status_declared_wait_identity() {  # <status-file>
  local f=$1 declared verb key resolve legacy_re rec idx text endpoint snapshot start numbered taken
  [ -f "$f" ] && [ -r "$f" ] || return 1
  endpoint=$(_fm_status_file_size "$f") || return 1
  endpoint=${endpoint//[[:space:]]/}
  _fm_status_event_scan_start "$endpoint" start
  snapshot="$(_fm_status_span_scratch "$f").wait"
  if [ "$start" -eq 0 ]; then
    _fm_status_read_span "$f" 0 "$endpoint" 0 > "$snapshot" 2>/dev/null || { rm -f "$snapshot"; return 1; }
  else
    _fm_status_read_span "$f" "$((start - 1))" "$((endpoint - start + 1))" 0 2>/dev/null | tail -n +2 > "$snapshot"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { rm -f "$snapshot"; return 1; }
  fi
  _fm_status_file_size "$snapshot" taken || { rm -f "$snapshot"; return 1; }
  taken=${taken//[[:space:]]/}
  declared=$(status_declared_wait_line "$snapshot")
  [ -n "$declared" ] || { rm -f "$snapshot"; return 1; }
  status_line_verb "$declared" verb
  key=$(_fm_decision_key "$declared" '') || key=
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  legacy_re="^[[:space:]]*(${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT})"
  numbered=$(_fm_status_event_candidates numbered "$((endpoint - taken))" < "$snapshot") || { rm -f "$snapshot"; return 1; }
  rm -f "$snapshot"
  rec=$(printf '%s\n' "$numbered" | tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES" \
    | _fm_status_wait_episode_scan "$resolve" "$legacy_re" "$verb" "$key") || rec=
  if [ -z "$rec" ] || [ "${rec%%$'\t'*}" = open ]; then
    rec=$(printf '%s\n' "$numbered" | _fm_status_wait_episode_scan "$resolve" "$legacy_re" "$verb" "$key") || return 1
  fi
  rec=${rec#*$'\t'}
  idx=${rec%%$'\t'*}
  text=${rec#*$'\t'}
  printf '%s:%s:%s' "${key:--}" "$(printf '%s' "$text" | cksum | cut -d' ' -f1)" "$idx"
}

# Walk the numbered status lines on stdin (`<byte offset>\t<line>`) back from the newest
# event to the first line of the declared wait's episode and print
# `<state>\t<byte offset>\t<line>`, where <state> is `open` when the episode reached the
# start of the input without a closing event, so a caller reading a bounded window must
# widen it, and `closed` otherwise. Returns 1 when the stream holds no declared wait.
_fm_status_wait_episode_scan() {  # <resolve-verb> <legacy-captain-re> <verb> <key>
  local resolve=$1 legacy_re=$2 want_verb=$3 want_key=$4 line verb key i=0 first='' first_line='' state=open
  local -a _fm_wait_scan_lines=() _fm_wait_scan_numbers=()
  while IFS= read -r line || [ -n "$line" ]; do
    _fm_wait_scan_numbers[i]=${line%%$'\t'*}
    _fm_wait_scan_lines[i]=${line#*$'\t'}
    i=$((i + 1))
  done
  while [ "$i" -gt 0 ]; do
    [ -z "${FM_STATUS_SPAN_TICK:-}" ] || "$FM_STATUS_SPAN_TICK"
    i=$((i - 1))
    line=${_fm_wait_scan_lines[i]}
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    _fm_status_line_is_event "$line" "$legacy_re" || continue
    status_line_verb "$line" verb
    key=$(_fm_decision_key "$line" '') || key=
    if [ -z "$first" ]; then
      [ "$verb" != "$resolve" ] || continue
      [ "$verb" = "$want_verb" ] || return 1
      first=${_fm_wait_scan_numbers[i]}; first_line=$line
      [ -n "$want_key" ] || { state=closed; break; }
      continue
    fi
    if [ "$verb" = "$resolve" ]; then
      [ "$key" != "$want_key" ] || { state=closed; break; }
      continue
    fi
    if [ "$verb" = "$want_verb" ] && [ "$key" = "$want_key" ]; then
      first=${_fm_wait_scan_numbers[i]}; first_line=$line
      continue
    fi
    state=closed
    break
  done
  [ -n "$first" ] || return 1
  printf '%s\t%s\t%s\n' "$state" "$first" "$first_line"
}
