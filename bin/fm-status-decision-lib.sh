#!/usr/bin/env bash
# shellcheck source=bin/fm-status-record-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-status-record-lib.sh"
if ! command -v _fm_open_decisions_file_ident >/dev/null 2>&1; then
  # The checkpoint-seeded fold below reads file identity, size, and byte spans.
  # shellcheck source=bin/fm-status-io-lib.sh
  . "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-status-io-lib.sh"
fi

# Version of the persisted fold checkpoint (state/.<task>.open-decisions-cursor).
# It must be bumped whenever _fm_decision_fold_line semantics change, so every
# checkpoint folded under an older reading is discarded and rebuilt from byte 0.
# 4: verb parsing ends at the first "[name=value]" tag rather than only at a
# "[key=...]" one, so lines carrying another bracketed tag first became opens
# and closes.
# 5: status_line_verb now also reads through an UNBRACKETED correlation token,
# so lines that previously folded as ordinary status become opens and closes.
# 6: a done/failed line on a ship or scout closes every open decision, and the
# persisted version now carries the task kind, so cursors folded without that
# terminal rule are discarded.
# 7: that terminal rule now fires only for a line carrying a colon, so a cursor
# folded when bare prose could close every open decision is discarded.
# 8: a colonless line without a complete "[key=...]" token is no longer a
# transition at all, so a cursor holding a phantom decision that bare prose
# opened - which no later line could close - is discarded.
# 9: the two colon tests read the line with its time tag stripped, so a
# malformed worker stamp whose colons used to pose as the head/note separator
# no longer opens or closes anything; cursors folded under that reading are
# discarded.
# 10: refuse partial-line checkpoint endpoints, including when the line has
# since completed; older checkpoints can already contain polluted fold state
# even at a now-valid boundary and must be rebuilt from byte 0.
FM_OPEN_DECISIONS_FOLD_VERSION=10

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-captain-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line in bin/fm-status-event-lib.sh) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it.
# Ship/scout terminal declarations supersede stale log decisions; a secondmate's
# terminal event may describe other work and cannot close an unrelated decision.
# Who WRITES the closing line is owned elsewhere: the answering firstmate closes
# at answer time through fm-send's --resolve-key (bin/fm-send.sh header), and a
# worker self-closes only a blocker that cleared without an answer (bin/fm-brief.sh
# rule 6), so closure never depends on a busy worker's discipline.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token names the decision. Its documented
# position sits between the verb and the colon, and a complete token at the
# head of the note is accepted as an EQUIVALENT position, because that
# misplaced-colon shape is common real worker output whose stated key must
# never silently collapse into the shared "default" bucket (issue #2109):
#   needs-decision [key=api-shape]: <summary>
#   needs-decision: [key=api-shape] <summary>
#   resolved       [key=api-shape]: <how it was decided>
# Both positions state the same key and yield the same note (a consumed
# note-head token is key metadata, stripped from the note); when both positions
# carry a token, the documented before-colon one wins and the note-head token
# stays note text. A token deeper inside the note is prose, never a stated key,
# so a summary merely MENTIONING "[key=x]" cannot open or close that decision.
# A line with no token in either position uses the key "default", preserving
# the historical one-open-decision-per-task behavior (a bare "resolved:" closes
# "default"). A stated key whose slug fails the charset below is rejected (the
# folds skip the line), never rewritten to "default".
# The parsers are pure reads of a single line. Status metadata may contain any
# number of "[name=value]" tags before the colon, in any order, so verb parsing
# ends at the first tag rather than special-casing "[key=...]".
#
# Correlation tokens. That bracket rule already covers every BRACKETED tag,
# including the "[corr=<16 hex>]" form bin/fm-secondmate-report.sh writes. It
# does not cover the UNBRACKETED token that bin/fm-pending-reply-lib.sh writes
# (fm_pending_reply_corr_token), which a secondmate answering a marked request
# echoes on its parent status line ahead of the key tag (bin/fm-brief.sh), so a
# real transition routinely arrives as
#   needs-decision corr=<16 hex> [key=texte-du-mur]: <summary>
#   resolved       corr=<16 hex> [key=texte-du-mur]: <how it was decided>
# and a recovery turn can leave two such tokens on one line. All of those must
# read as the bare verb, in BOTH directions: a verb parse that keeps the token
# glued on matches no arm of _fm_decision_fold_line, so the opener never opens
# and the closer never closes, and a captain decision goes silently missing.
# Recognition starts only AFTER the retained leading verb: a token-first line
# keeps that token, so its following word cannot impersonate a transition and
# close a decision the captain is owed.
#
# The token grammar is OWNED by bin/fm-pending-reply-lib.sh
# (fm_pending_reply_corr_token, FM_PENDING_REPLY_CORR_RE). That library sources
# this one, so it cannot be sourced back here; the pattern below is a deliberate
# second statement of the SHAPE alone, and tests/fm-classify-corr-token.test.sh
# pins the two together through the real writers so they cannot drift.
#
# Recognition is deliberately narrow: EXACTLY the token that writer emits, whole
# word, and nothing else. An arbitrary "<name>=<value>" token is NOT skipped.
# Skipping unknown tokens would be the permissive road - it would let any
# free-text word carrying an equals sign ("resolved x=1 [key=k]: ...") reduce to
# a bare verb and impersonate a transition, which is the takeover the strict
# parse and _fm_decision_key_transition_allowed exist to prevent. Recognising
# only what a firstmate library actually writes costs one more line here each
# time a real new token shape is introduced, and that is the intended trade: a
# new shape is a deliberate, reviewed edit rather than a silent widening. A line
# whose token is malformed, wrong-length, or merely mentioned in prose keeps its
# extra words and therefore stays a non-transition, exactly as before.
#
# The 16 hex classes are written out literally rather than built from a
# variable, the same way bin/fm-secondmate-report.sh validates the id it is
# handed: a variable holding a glob is only re-read as a pattern under some
# shells' expansion rules, and a safety parse must not turn on that.
#
# 0 if <word> is, in whole, an unbracketed correlation token this fleet's own
# tooling writes. The bracketed form never reaches here: the tag rule above has
# already ended the verb parse at its opening bracket.
_fm_classify_is_corr_token() {  # <word>
  case "$1" in
    corr=[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
      return 0
      ;;
  esac
  return 1
}

# Printed, or assigned to <out-var> when one is given, so a per-line caller on a
# hot path can take the verb without forking a command substitution. Under bash's
# dynamic scope an <out-var> named like one of this function's own locals (v, out,
# word) would be assigned here and lost, so callers pass a distinct name.
status_line_verb() {  # <status-line> [<out-var>] -> leading verb word
  local v=${1%%:*} out='' word
  v=${v%%\[*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  # Fast path, and the whole no-regression guarantee: a prefix that cannot
  # contain a correlation token is returned byte-for-byte as before, so every
  # line without one keeps its exact historical verb, spacing included.
  case "$v" in
    *corr=*)
      # Retain the first word, then drop only recognised tokens from the remaining
      # whole words. Anything unrecognised stays, so prose still matches no verb.
      word=${v%%[[:space:]]*}
      out=$word
      v=${v#"$word"}
      v=${v#"${v%%[![:space:]]*}"}
      while [ -n "$v" ]; do
        word=${v%%[[:space:]]*}
        v=${v#"$word"}
        v=${v#"${v%%[![:space:]]*}"}
        _fm_classify_is_corr_token "$word" && continue
        out="$out $word"
      done
      ;;
    *) out=$v ;;
  esac
  if [ "$#" -gt 1 ]; then printf -v "$2" '%s' "$out"; else printf '%s' "$out"; fi
}
# 0 when a complete "[key=...]" token sits in the documented position before
# the line's first colon (or anywhere on a line that has no colon at all).
_fm_key_before_colon() {  # <status-line>
  case "${1%%:*}" in
    *\[key=*\]*) return 0 ;;
    *) return 1 ;;
  esac
}
# Raw slug of a complete "[key=<slug>]" token at the head of the note (the
# first thing after the line's first colon, ignoring whitespace). Fails when
# the line has no colon or no complete token there; slug charset validity is
# the caller's check via _fm_decision_slug_ok, exactly as for the before-colon
# position.
_fm_key_at_note_head() {  # <status-line> [<out-var>] -> raw slug
  local rest
  case "$1" in
    *:*) rest=${1#*:} ;;
    *) return 1 ;;
  esac
  rest=${rest#"${rest%%[![:space:]]*}"}
  case "$rest" in
    \[key=*\]*)
      rest=${rest#\[key=}; rest=${rest%%\]*}
      if [ "$#" -gt 1 ]; then printf -v "$2" '%s' "$rest"; else printf '%s' "$rest"; fi
      ;;
    *) return 1 ;;
  esac
}
# 0 when a stated key slug is well-formed: nonempty, A-Za-z0-9._- only.
_fm_decision_slug_ok() {  # <slug>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}
# Both readers below locate the head/note separator on an unstamped copy, so a
# worker-written stamp cannot move it: a readable time like [at=10:30] carries
# colons that would otherwise end the head mid-tag and hand the caller a note
# and a key sliced out of the timestamp. The line's own bytes are never altered.
status_line_note() {  # <status-line> [<out-var>] -> text after the first colon, trimmed
  local n k unstamped
  _fm_status_unstamped "$1" unstamped
  case "$unstamped" in
    *:*) n=${unstamped#*:}; n=${n#"${n%%[![:space:]]*}"} ;;
    *) n=$unstamped; if [ "$#" -gt 1 ]; then printf -v "$2" '%s' "$n"; else printf '%s' "$n"; fi; return 0 ;;
  esac
  # A note-head token that states this line's key (no before-colon token, valid
  # slug) is key metadata, not note text: strip it so both stated-key positions
  # yield the same note.
  if ! _fm_key_before_colon "$unstamped" && _fm_key_at_note_head "$unstamped" k \
    && _fm_decision_slug_ok "$k"; then
    n=${n#"[key=$k]"}
    n=${n#"${n%%[![:space:]]*}"}
  fi
  if [ "$#" -gt 1 ]; then printf -v "$2" '%s' "$n"; else printf '%s' "$n"; fi
}
_fm_decision_key_into() {  # <status-line> <keyless> <out-var> -> sets <out-var> to the key slug, or <keyless> when no token
  local __fm_dk_k __fm_dk_unstamped
  _fm_status_unstamped "$1" __fm_dk_unstamped
  if _fm_key_before_colon "$__fm_dk_unstamped"; then
    __fm_dk_k=${__fm_dk_unstamped%%:*}
    __fm_dk_k=${__fm_dk_k#*\[key=}
    __fm_dk_k=${__fm_dk_k%%\]*}
  elif ! _fm_key_at_note_head "$__fm_dk_unstamped" __fm_dk_k; then
    printf -v "$3" '%s' "$2"
    return 0
  fi
  _fm_decision_slug_ok "$__fm_dk_k" || return 1
  printf -v "$3" '%s' "$__fm_dk_k"
}
_fm_decision_key() {  # <status-line> [<keyless>] -> key slug, or <keyless> (default "default") when no token
  local __fm_dk_out
  _fm_decision_key_into "$1" "${2-default}" __fm_dk_out || return 1
  printf '%s' "$__fm_dk_out"
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key> [<out-var>]
  local __fm_drop_line __fm_drop_out=$1
  while [[ "$__fm_drop_out" == *$'\n' ]]; do __fm_drop_out=${__fm_drop_out%$'\n'}; done
  # Most routine resolutions name no open key; leave the set alone in that case.
  if _fm_open_set_has "$__fm_drop_out" "$2"; then
    __fm_drop_out=''
    while IFS= read -r __fm_drop_line || [ -n "$__fm_drop_line" ]; do
      [ -n "$__fm_drop_line" ] || continue
      case "$__fm_drop_line" in
        "$2"$'\t'*) : ;;
        *) __fm_drop_out+="${__fm_drop_line}"$'\n' ;;
      esac
    done <<EOF
$1
EOF
    __fm_drop_out=${__fm_drop_out%$'\n'}
  fi
  if [ "$#" -gt 2 ]; then
    printf -v "$3" '%s' "$__fm_drop_out"
  elif [ -n "$__fm_drop_out" ]; then
    printf '%s\n' "$__fm_drop_out"
  fi
}
# Fold ONE status line into an existing "<key>\t<verb>\t<note>\n"-per-line open
# set, applying the same needs-decision/blocked-opens, resolved/captain-held-closes
# rule the status-fold contract above documents. Pure text transform, no file I/O.
# This is the ONE place the per-line open/resolved rule is written; both the
# whole-file fold (status_open_decisions) and the incremental cursor-backed fold
# (status_open_decisions_incremental in bin/fm-classify-lib.sh) call this instead of re-deriving the
# rule, so the two consumption strategies can never drift apart on semantics.
# Reserved decision-key namespaces, and the rule that makes them mean something.
#
# A key like `pending-reply-<id>` names a decision that one library raises and is
# the only thing that ever closes it. Every writer reaches this same stream: a
# local mate appends straight into it, and a remote mate's lines are mirrored
# into it verbatim. So without a rule here, any writer could claim a reserved
# key with an unrelated note, take the key over in this fold, and permanently
# block the owner's close - leaving a decision nothing will ever resolve - or
# clear the owner's decision with a bare resolution.
#
# The rule is deliberately generic, so this fold needs no knowledge of any
# particular owner: a reserved key may only be opened or closed by a line whose
# note speaks that namespace's own vocabulary, which its owner states by
# beginning the note with a `<namespace>...:` token. A line failing that is not a
# decision transition at all here and is folded as ordinary status. This is a
# consumer-side rule on purpose - it protects local and remote writers
# identically, and it can never fail a whole delta or wedge a stream the way a
# writer-side rejection would.
FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT='pending-reply-'

# 0 when <key> is not reserved, or is reserved and <note> speaks its vocabulary.
_fm_decision_key_transition_allowed() {  # <key> <note>
  local key=$1 note=$2 prefix
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        case "$note" in
          "$prefix"*:*) return 0 ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done
  return 0
}

_fm_is_pending_reply_escalation() {  # <key> <note>
  case "$1" in pending-reply-*) ;; *) return 1 ;; esac
  case "$2" in
    pending-reply-missed:*|pending-reply-delivery-unknown:*|pending-reply-recovery-delivery-failed:*|pending-reply-recovery-delivery-unknown:*) return 0 ;;
    *) return 1 ;;
  esac
}

_fm_status_kind() {
  local meta=${1%.status}.meta kind=${2:-} line
  if [ -z "$kind" ]; then
    [ -f "$meta" ] && [ -r "$meta" ] && [ ! -L "$meta" ] || { printf unknown; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in kind=*) kind=${line#kind=} ;; esac
    done < "$meta"
    kind=${kind:-ship}
  fi
  case "$kind" in ship|scout|secondmate) printf '%s' "$kind" ;; *) printf unknown ;; esac
}

_fm_decision_fold_line_into() {  # <open-set> <status-line> <resolve-verb> <held-verb> <kind> <out-var>
  local __fm_fl_open=$1 __fm_fl_verb __fm_fl_key __fm_fl_note __fm_fl_unstamped
  # Match the old command substitution, including on non-transition returns.
  while [[ "$__fm_fl_open" == *$'\n' ]]; do __fm_fl_open=${__fm_fl_open%$'\n'}; done
  printf -v "$6" '%s' "$__fm_fl_open"
  status_line_verb "$2" __fm_fl_verb
  # Only an opener can change an empty set; routine closes need no key/note parse.
  case "$__fm_fl_verb" in
    needs-decision|blocked) ;;
    *) [ -n "$__fm_fl_open" ] || return 0 ;;
  esac
  # Both colon tests below ask where the head ends, the same question the note
  # and key readers ask, so they read the same unstamped copy those readers do.
  # A worker-written time tag must never decide whether a decision opens or
  # closes: a readable [at=10:30] carries colons that would otherwise make bare
  # prose look like a transition, or make a keyless line open a phantom
  # decision no later line could close. The stored and surfaced bytes stay the
  # caller's own.
  _fm_status_unstamped "$2" __fm_fl_unstamped
  # Declaration guard. A transition's verb ends at a colon, or - in the colonless
  # form _fm_decision_key still accepts above - at a complete "[key=...]" token.
  # A line holding neither is continuation prose, a bare word, or blank, and can
  # never move the set. A `case` glob answers that in one pattern match; the
  # equivalent parameter expansion costs tens of milliseconds per line under bash
  # 3.2's global bracket-class substitution, which is the whole per-line cost of
  # both folds on a status log of ordinary width. Same verdict, bounded cost.
  case "$__fm_fl_unstamped" in
    *:*|*\[key=*\]*) ;;
    *) return 0 ;;
  esac
  case "$__fm_fl_unstamped" in
    *:*) case "$__fm_fl_verb:$5" in
      done:ship|done:scout|failed:ship|failed:scout) printf -v "$6" '%s' ''; return 0 ;;
    esac ;;
  esac
  case "$__fm_fl_verb" in
    needs-decision|blocked|"$3"|"$4") ;;
    *) return 0 ;;
  esac
  _fm_decision_key_into "$2" default __fm_fl_key || return 0
  status_line_note "$2" __fm_fl_note
  while [[ "$__fm_fl_note" == *$'\n' ]]; do __fm_fl_note=${__fm_fl_note%$'\n'}; done
  _fm_decision_key_transition_allowed "$__fm_fl_key" "$__fm_fl_note" || return 0
  _fm_decision_drop "$__fm_fl_open" "$__fm_fl_key" __fm_fl_open
  case "$__fm_fl_verb" in
    needs-decision|blocked)
      [ -n "$__fm_fl_open" ] && __fm_fl_open+=$'\n'
      __fm_fl_open+="${__fm_fl_key}"$'\t'"${__fm_fl_verb}"$'\t'"${__fm_fl_note}"
      ;;
  esac
  printf -v "$6" '%s' "$__fm_fl_open"
}
_fm_decision_fold_line() {  # <open-set> <status-line> <resolve-verb> <held-verb> <kind>
  local __fm_fl_out
  _fm_decision_fold_line_into "$1" "$2" "$3" "$4" "$5" __fm_fl_out
  printf '%s' "$__fm_fl_out"
}

# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Reads the
# status file, its sibling `.meta` for the task kind when the caller passes no
# <kind>, and a sibling fold checkpoint when available. The fold signature
# includes the optional verb and reserved-key overrides. This is the durable open-set the fleet
# snapshot and any point-in-time consumer must use instead of trusting the last
# status line.
# The scan_open_decisions wrapper in bin/fm-classify-lib.sh enumerates a whole directory rather than
# a single caller-chosen path, so a status file that is itself a symlink (e.g.
# escaping the state directory) is rejected outright with a plain [ -L ] check
# before any read - a cheap builtin, unlike fm_wake_latest_event's O_NOFOLLOW
# subprocess read, which exists for that function's much narrower payload-driven
# path resolution rather than this directory-local glob.
#
# Checkpoint seeding. Status logs are append-only and never compacted, so a
# fold from line 1 costs every line the task ever wrote (a long-lived second
# mate's log runs to megabytes and tens of seconds of bash per fold). The
# incremental fold in bin/fm-classify-lib.sh persists a checkpoint beside the
# log - the open set folded through a byte offset, which already holds only the
# decisions still open, every closed one compacted away. This whole-file read
# starts from that checkpoint when it is trustworthy and folds only the bytes
# after it, which is byte for byte the result a fold from line 1 prints, because
# the checkpoint IS that fold of the prefix. It stays a pure read: it never
# writes, refreshes, or creates a checkpoint, so a caller reading another home's
# log leaves that home untouched. Any doubt folds from line 1 instead: an absent,
# unreadable, symlinked, or malformed checkpoint; a fold signature that differs
# from this read's; a file identity that differs (the log was replaced); an offset
# past the current size; or a nonzero offset that does not sit just after a
# newline, because a checkpoint taken mid-append folded a partial line the
# whole-file fold would have read whole.
# A failed tail read also falls back to byte 0; no pure read repairs the checkpoint.
# Regression coverage: tests/fm-wake-drain-open-decisions-cursor.test.sh.
status_open_decisions() {  # <status-file> [<kind>]
  local f=$1 kind=${2:-} line resolve held open='' verb offset=0 span seeded=0
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  kind=$(_fm_status_kind "$f" "$kind")
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  if _fm_open_decisions_checkpoint_seed "$f" "$kind"; then
    open=$_FM_ODC_OPEN
    offset=$_FM_ODC_OFFSET
    seeded=1
  fi
  if [ "$seeded" -eq 1 ]; then
    [ "$offset" -lt "$_FM_ODC_SIZE" ] || { printf '%s' "$open"; return 0; }
    if span=$(_fm_status_read_span "$f" "$offset" "$((_FM_ODC_SIZE - offset))" 2>/dev/null); then
      while IFS= read -r line || [ -n "$line" ]; do
        status_line_verb "$line" verb
        case "$verb" in
          needs-decision|blocked|done|failed|"$resolve"|"$held")
            open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$kind")
            ;;
        esac
      done <<EOF
$span
EOF
      printf '%s' "$open"
      return 0
    fi
    open=''
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" verb
    case "$verb" in
      needs-decision|blocked|done|failed|"$resolve"|"$held")
        open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$kind")
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# The subset of status_open_decisions the task raised about its own work: a
# reserved-namespace key is raised by a supervisor library about the task (a
# pending-reply escalation), a `remote-reply-continuity-` key is the parent's
# own blocker about a broken remote reply mirror
# (bin/fm-procevent-remote-reply.sh), and a `captain-hold-` key relays a child
# decision a secondmate escalated to the captain (bin/fm-captain-hold.sh) while
# it keeps working, so the task is not waiting on any of them. Pending-reply
# recovery and a fire-and-forget retry ring consult this set and leave a task
# alone while it is non-empty.
status_own_open_decisions() {  # <status-file>
  local line prefix
  status_open_decisions "$1" | while IFS= read -r line || [ -n "$line" ]; do
    for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT} remote-reply-continuity- captain-hold-; do
      case "$line" in "$prefix"*) continue 2 ;; esac
    done
    printf '%s\n' "$line"
  done
}

# The same open set with each decision's opening time: one
# "<key>\t<verb>\t<epoch>\t<summary>" line per still-open decision, <epoch> empty
# when the opening line carries no readable time stamp (age unknown, never zero).
# The opening is the LAST line that opens the key, found with the same verb and
# key readers the fold uses, and its time comes from status_line_at_epoch, so a
# tag quoted in another line's prose or a malformed stamp can never set an age.
status_open_decisions_dated() {  # <status-file> [<kind>]
  local f=$1 open key verb summary line line_verb opened kind resolve held line_open
  open=$(status_open_decisions "$f" "${2:-}")
  [ -n "$open" ] || return 0
  kind=$(_fm_status_kind "$f" "${2:-}")
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS=$'\t' read -r key verb summary; do
    [ -n "$verb" ] || continue
    opened=
    while IFS= read -r line || [ -n "$line" ]; do
      status_line_verb "$line" line_verb
      [ "$line_verb" = "$verb" ] || continue
      line_open=$(_fm_decision_fold_line '' "$line" "$resolve" "$held" "$kind")
      _fm_open_set_has "$line_open" "$key" || continue
      opened=$(status_line_at_epoch "$line" 2>/dev/null || true)
    done < "$f"
    printf '%s\t%s\t%s\t%s\n' "$key" "$verb" "$opened" "$summary"
  done <<EOF
$open
EOF
}

# The signature a fold checkpoint must carry to be reused for <kind>: the fold
# version and the task kind, plus every fold-affecting override when one is set,
# so a checkpoint folded under the default verbs is never reused by a read that
# overrides them (and the default signature stays the historical one).
_fm_open_decisions_fold_signature() {  # <kind> [<out-var>]
  local __fm_fs_sig="$FM_OPEN_DECISIONS_FOLD_VERSION:$1"
  if [ -n "${FM_CLASSIFY_RESOLVE_VERB:-}" ] || [ -n "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-}" ] \
    || [ -n "${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-}" ]; then
    __fm_fs_sig="$__fm_fs_sig:${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}"
    __fm_fs_sig="$__fm_fs_sig:${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}"
    __fm_fs_sig="$__fm_fs_sig:${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}"
  fi
  _fm_emit_value "${2-}" "$__fm_fs_sig"
}

# Parse one checkpoint file: `version=`, `offset=`, `ident=` header lines, then
# the folded open set. Sets _FM_ODC_VERSION, _FM_ODC_OFFSET, _FM_ODC_IDENT, and
# _FM_ODC_OPEN; returns 1 for an absent, unreadable, symlinked, or malformed
# checkpoint. Shared by the writer in bin/fm-classify-lib.sh and the whole-file
# readers here; the legacy offset/export reader in bin/fm-status-wake-lib.sh
# applies the same signature, identity, size, and boundary checks.
_fm_open_decisions_checkpoint_parse() {  # <checkpoint-file>
  local cf=$1 data first rest line
  _FM_ODC_VERSION='' _FM_ODC_OFFSET=0 _FM_ODC_IDENT='' _FM_ODC_OPEN=''
  [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ] || return 1
  data=$(LC_ALL=C command cat "$cf" 2>/dev/null) || return 1
  first=${data%%$'\n'*}
  case "$first" in version=?*) _FM_ODC_VERSION=${first#version=} ;; *) return 1 ;; esac
  case "$data" in *$'\n'*) rest=${data#*$'\n'} ;; *) return 1 ;; esac
  line=${rest%%$'\n'*}
  case "$line" in offset=*) _FM_ODC_OFFSET=${line#offset=} ;; *) return 1 ;; esac
  case "$_FM_ODC_OFFSET" in ''|*[!0-9]*) _FM_ODC_OFFSET=0; return 1 ;; esac
  case "$rest" in *$'\n'*) rest=${rest#*$'\n'} ;; *) return 1 ;; esac
  line=${rest%%$'\n'*}
  case "$line" in ident=?*) _FM_ODC_IDENT=${line#ident=} ;; *) return 1 ;; esac
  case "$rest" in *$'\n'*) _FM_ODC_OPEN=${rest#*$'\n'} ;; esac
  return 0
}

_fm_open_decisions_checkpoint_boundary() {  # <status-file> <offset>
  local last
  [ "$2" -gt 0 ] || return 0
  last=$(_fm_status_read_span "$1" "$(($2 - 1))" 1 2>/dev/null && printf '.') || return 2
  case "$last" in
    $'\n.') return 0 ;;
    .) return 2 ;;
    *) return 1 ;;
  esac
}

# 0 when <status-file>'s checkpoint can seed a fold for <kind>, with the seed in
# _FM_ODC_OPEN / _FM_ODC_OFFSET and the current file size in _FM_ODC_SIZE.
# Read-only; status_open_decisions above owns every rejection reason.
_fm_open_decisions_checkpoint_seed() {  # <status-file> <kind>
  local f=$1 kind=$2 cur_ident
  _FM_ODC_SIZE=0
  _fm_open_decisions_checkpoint_parse "$(_fm_open_decisions_cursor_path "$f")" || return 1
  [ "$_FM_ODC_VERSION" = "$(_fm_open_decisions_fold_signature "$kind")" ] || return 1
  cur_ident=$(_fm_open_decisions_file_ident "$f" 2>/dev/null) || return 1
  [ -n "$cur_ident" ] && [ "$cur_ident" = "$_FM_ODC_IDENT" ] || return 1
  _FM_ODC_SIZE=$(_fm_status_file_size "$f" 2>/dev/null) || return 1
  _FM_ODC_SIZE=${_FM_ODC_SIZE//[[:space:]]/}
  case "$_FM_ODC_SIZE" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_FM_ODC_OFFSET" -le "$_FM_ODC_SIZE" ] || return 1
  _fm_open_decisions_checkpoint_boundary "$f" "$_FM_ODC_OFFSET"
}

# 0 when <key> has a record in a folded "<key>\t<verb>\t<note>" open set.
_fm_open_set_has() {  # <open-set> <key>
  case "$1" in
    "$2"$'\t'*|*$'\n'"$2"$'\t'*) return 0 ;;
    *) return 1 ;;
  esac
}

# The verb stored for <key> in a folded open set (empty when it has no record).
_fm_open_set_verb() {  # <open-set> <key>
  local line
  while IFS= read -r line; do
    case "$line" in
      "$2"$'\t'*) line=${line#*$'\t'}; printf '%s' "${line%%$'\t'*}"; return 0 ;;
    esac
  done <<EOF
$1
EOF
  return 0
}
