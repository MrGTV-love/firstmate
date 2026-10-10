#!/usr/bin/env bash
# Shared emission-time metadata and retry identity for status records.
# Sourcing this library only defines functions; it does not initialize globals.

# --- optional event emission time -------------------------------------------
# New writers may append "[at=<epoch>]" before the first colon, alongside key
# and corr tags in any order. Epoch is UTC Unix seconds: canonical unsigned
# decimal, at most 12 digits (bounded for safe shell arithmetic). For example:
#   resolved [key=api-shape] [at=1788576000]: answered: use REST
# No colons appear inside this field, so existing verb/key/note readers retain
# their grammar. Missing, malformed, or duplicate time fields mean UNKNOWN time;
# never infer emission time from file mtime, a wake, or observation time. Relays
# preserve source tags and leave legacy source events unstamped. Time describes
# event history only and must never decide current state or decision closure.
# This parser owns that grammar; every reader below is a thin adapter over it,
# so no second spelling of "well-formed" can drift against this one.
# Internals carry a reserved prefix: bash locals are dynamically scoped, so a
# plain name here would shadow the caller's out-var of the same name.
_fm_status_at_epoch() {  # <status-line> <out-var> -> 0 and the epoch when known
  local __fm_at_head __fm_at_value __fm_at_rest
  printf -v "$2" '%s' ''
  case "$1" in *:*) __fm_at_head=${1%%:*} ;; *) return 1 ;; esac
  case "$__fm_at_head" in *\[at=*\]*) ;; *) return 1 ;; esac
  __fm_at_rest=${__fm_at_head#*\[at=}
  __fm_at_value=${__fm_at_rest%%\]*}
  case "${__fm_at_rest#*\]}" in *\[at=*) return 1 ;; esac
  case "$__fm_at_value" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#__fm_at_value}" -le 12 ] || return 1
  printf -v "$2" '%s' "$__fm_at_value"
}

status_line_at_epoch() {  # <status-line> -> epoch; nonzero when unknown
  local epoch
  _fm_status_at_epoch "$1" epoch || return 1
  printf '%s' "$epoch"
}

# Stamp only a newly emitted event. Preserve an existing tag, even malformed,
# and preserve the event itself if the clock cannot be read. Never use this to
# timestamp a copied historical line.
status_stamp_line() {  # <new-status-line> -> line (without newline)
  local head epoch
  case "$1" in
    *:*) head=${1%%:*} ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  case "$head" in *\[at=*) printf '%s' "$1"; return 0 ;; esac
  if epoch=$(date +%s); then
    printf '%s [at=%s]:%s' "$head" "$epoch" "${1#*:}"
  else
    printf '%s' "$1"
  fi
}

# Characters status_stamp_line would insert into a line it stamps: the space,
# the "[at=" and "]" delimiters, and the clock's own digit width. A writer that
# caps a status line BEFORE the append stamps it must subtract this from its
# cap, or the bytes actually appended overrun the cap that writer enforces and
# every capped rendering downstream loses that much real note text. Zero when
# the clock cannot be read, because then nothing is stamped either.
status_stamp_width() {  # -> characters a stamp adds to a line
  local epoch tag
  epoch=$(date +%s) || { printf 0; return 0; }
  case "$epoch" in ''|*[!0-9]*) printf 0; return 0 ;; esac
  tag=" [at=$epoch]"
  printf '%s' "${#tag}"
}

# Strip the one well-formed time tag _fm_status_at_epoch accepts, for readers
# that need a stamped line as the exact bytes it carried before stamping:
# retry-dedup identity here, and the pending-reply escalation match in
# bin/fm-pending-reply-lib.sh, which compares against its own literal spellings.
# Every other [at=...] byte run - malformed, duplicate, or outside the canonical
# bounds - is ordinary line bytes here, never a time tag, so a retry of it stays
# a distinct event. A reader that instead asks where the HEAD ends owns a more
# tolerant rule in _fm_status_unstamped below and must route through that one;
# do not route such a reader through this one. It reads the grammar from that
# single parser rather than a second spelling of it, and a sweep that normalizes
# a line at a time never pays a fork for the match it prepares.
_fm_status_untimed() {  # <status-line> <out-var> -> line without a time tag
  local __fm_untimed_epoch __fm_untimed_head __fm_untimed_tag __fm_untimed_before
  if _fm_status_at_epoch "$1" __fm_untimed_epoch; then
    __fm_untimed_head=${1%%:*}
    __fm_untimed_tag="[at=$__fm_untimed_epoch]"
    __fm_untimed_before=${__fm_untimed_head%%"$__fm_untimed_tag"*}
    printf -v "$2" '%s%s:%s' "${__fm_untimed_before% }" \
      "${__fm_untimed_head#*"$__fm_untimed_tag"}" "${1#*:}"
    return 0
  fi
  printf -v "$2" '%s' "$1"
}

# Strip every time-tag-shaped run a worker could have written as the stamp,
# however malformed its value. This is the shared head-boundary rule for every
# reader that asks where a line's head ends rather than what its stamp means:
# captain-relevance, the event scan, and the note, key, and decision-fold
# readers. A tag is metadata a worker appended, so it must never decide whether
# a terminal event reaches its supervisor, which note or key that event carries,
# or whether a decision opens or closes - not when the worker left the brief's
# <epoch> placeholder unsubstituted, and not when they wrote a readable time
# whose colons swallow the head/note separator.
# A run is the stamp only while nothing before it holds a colon; once one does,
# the head has ended and every later [at=...] is note text the override may
# legitimately match on, so scanning stops there. The caller's own bytes are
# untouched: this writes a throwaway copy used for matching only.
_fm_status_unstamped() {  # <status-line> <out-var> -> line with its stamp removed
  local __fm_unstamped_rest=$1 __fm_unstamped_keep='' __fm_unstamped_before
  while :; do
    case "$__fm_unstamped_rest" in *\[at=*\]*) ;; *) break ;; esac
    __fm_unstamped_before=${__fm_unstamped_rest%%\[at=*}
    case "$__fm_unstamped_before" in *:*) break ;; esac
    __fm_unstamped_keep=$__fm_unstamped_keep${__fm_unstamped_before% }
    __fm_unstamped_rest=${__fm_unstamped_rest#*\[at=}
    __fm_unstamped_rest=${__fm_unstamped_rest#*\]}
  done
  printf -v "$2" '%s' "$__fm_unstamped_keep$__fm_unstamped_rest"
}

# Retry deduplication ignores only a well-formed optional numeric time tag;
# all other bytes, including correlation metadata, still identify the event.
# Both sides normalize through _fm_status_untimed, so a stamped retry of an
# already-recorded event can never read as a new one.
# A match stays recorded for the life of the file, whatever follows it: a
# later resolved line for the same key does not make the line new again, so a
# caller that re-reads an unchanged source after an operator resolve (the
# continuity break in bin/fm-procevent-remote-reply.sh, which does not advance
# its cursor) appends nothing. A caller that owns evidence of a new episode
# decides that itself, as bin/fm-pending-reply-lib.sh's escalation does.
status_event_recorded() {  # <status-file> <new-status-line>
  local wanted line untimed
  [ -f "$1" ] || return 1
  _fm_status_untimed "$2" wanted
  while IFS= read -r line || [ -n "$line" ]; do
    _fm_status_untimed "$line" untimed
    [ "$untimed" != "$wanted" ] || return 0
  done < "$1"
  return 1
}
