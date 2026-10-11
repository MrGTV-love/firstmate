#!/usr/bin/env bash
# Status-span classification captures one file endpoint and reports every
# actionable event through that endpoint before the endpoint may be committed.
# An absent status file is a successful empty span, while an existing status
# object that cannot be read or identified is a classification failure with no
# committable endpoint.
# A presentation marker independently stores the last reported file signature
# and the last successfully classified position.
# Successful classification advances both facts through the captured endpoint;
# after a failure is reported, only the reported signature advances, so the same
# observed state alarms once while every unclassified byte remains for recovery.
# The reported signature includes path type, mode, symlink target, and observable
# failure kind, so a readability change is a new state that triggers another read.
# A missing, malformed, identity-mismatched, or past-end classified position reads
# from byte 0, preferring a bounded duplicate over a lost event.

if ! command -v _fm_status_file_size >/dev/null 2>&1; then
  # shellcheck source=bin/fm-status-io-lib.sh
  . "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-status-io-lib.sh"
fi

# shellcheck source=bin/fm-status-event-lib.sh
. "$_FM_CLASSIFY_LIB_DIR/fm-status-event-lib.sh"

# FM_OPEN_DECISIONS_FOLD_VERSION and its bump history live with the fold rule
# they version, in bin/fm-status-decision-lib.sh.

# Printed, or assigned to <out-var> when one is given, so the per-task scans
# take an offset without forking a command substitution. The locals carry the
# __fm_pc_ prefix because an out-var named like an unprefixed local would be
# assigned here and lost under bash's dynamic scope.
status_presentation_cursor_offset() {  # <status-file> [<out-var>]
  local __fm_pc_f=$1 __fm_pc_state __fm_pc_task __fm_pc_manifest __fm_pc_data __fm_pc_row_task
  local __fm_pc_offset __fm_pc_ident __fm_pc_backstop __fm_pc_extra __fm_pc_cur_ident __fm_pc_size __fm_pc_legacy
  [ -f "$__fm_pc_f" ] && [ -r "$__fm_pc_f" ] && [ ! -L "$__fm_pc_f" ] || return 1
  __fm_pc_state=${__fm_pc_f%/*}
  __fm_pc_task=${__fm_pc_f##*/}; __fm_pc_task=${__fm_pc_task%.status}
  __fm_pc_manifest="$__fm_pc_state/.status-presentation-cursor"
  if [ -e "$__fm_pc_manifest" ] || [ -L "$__fm_pc_manifest" ]; then
    [ -f "$__fm_pc_manifest" ] && [ -r "$__fm_pc_manifest" ] && [ ! -L "$__fm_pc_manifest" ] || return 1
    _fm_read_file_into "$__fm_pc_manifest" __fm_pc_data || return 1
    __fm_pc_offset=
    while IFS=$'\t' read -r __fm_pc_row_task __fm_pc_ident __fm_pc_legacy __fm_pc_backstop __fm_pc_extra; do
      [ -n "$__fm_pc_row_task" ] || continue
      [ -z "$__fm_pc_extra" ] || return 1
      case "$__fm_pc_legacy:$__fm_pc_backstop" in *[!0-9:]*) return 1 ;; esac
      [ -n "$__fm_pc_legacy" ] && [ -n "$__fm_pc_ident" ] || return 1
      if [ "$__fm_pc_row_task" = "$__fm_pc_task" ]; then
        [ -z "$__fm_pc_offset" ] || return 1
        __fm_pc_offset=$__fm_pc_legacy
        __fm_pc_cur_ident=$__fm_pc_ident
      fi
    done <<EOF
$__fm_pc_data
EOF
    if [ -z "$__fm_pc_offset" ]; then
      _fm_emit_value "${2-}" 0
      return 0
    fi
    __fm_pc_ident=$__fm_pc_cur_ident
  else
    _fm_open_decisions_cursor_path "$__fm_pc_f" __fm_pc_legacy
    if [ -e "$__fm_pc_legacy" ] || [ -L "$__fm_pc_legacy" ]; then
      __fm_pc_offset=$(status_open_decisions_cursor_offset "$__fm_pc_f") || return 1
      _fm_emit_value "${2-}" "$__fm_pc_offset"
      return 0
    fi
    __fm_pc_offset=0
    _fm_open_decisions_file_ident "$__fm_pc_f" __fm_pc_ident || return 1
  fi
  _fm_status_stat_into "$__fm_pc_f" __fm_pc_cur_ident __fm_pc_size || return 1
  __fm_pc_size=${__fm_pc_size//[[:space:]]/}
  case "$__fm_pc_size:$__fm_pc_offset" in *[!0-9:]*) return 1 ;; esac
  if [ "$__fm_pc_ident" != "$__fm_pc_cur_ident" ] || [ "$__fm_pc_offset" -gt "$__fm_pc_size" ]; then __fm_pc_offset=0; fi
  _fm_emit_value "${2-}" "$__fm_pc_offset"
}

_status_observed_path_state() {
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f '%HT:%p' "$1" 2>/dev/null
  else
    LC_ALL=C stat -c '%F:%f' "$1" 2>/dev/null
  fi
}

# Path type and mode, size, device and inode, and birth time of one path from a
# single stat process, bar separated: the reported signature below needs all of
# them, and each used to be its own stat. No field can hold a bar, and the birth
# text is last, so the split below is unambiguous. Fails when stat cannot read
# the path, which is the case every one of the old separate stats failed on.
_status_observed_facts() {  # <file>
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f '%HT:%p|%z|%d:%i|%B|%FB' "$1" 2>/dev/null
  else
    LC_ALL=C stat -c '%F:%f|%s|%d:%i|%W|%w' "$1" 2>/dev/null
  fi
}

# Lower-case hex of the fields' bytes, joined by a NUL byte (hex 00), into
# <out-var>: one printf per byte instead of a printf, od and tr pipeline. The
# signature's fields are printable ASCII except a symlink target, which can hold
# any byte, so a call with any other byte takes the od pipeline this replaced.
_status_hex_fields_to() {  # <out-var> <six fields...>
  local LC_ALL=C _hx_var=$1 _hx_out='' _hx_field _hx_byte _hx_i _hx_first=1 _hx_plain=1
  shift
  for _hx_field in "$@"; do
    case "$_hx_field" in *[!\ -~]*) _hx_plain=0 ;; esac
  done
  if [ "$_hx_plain" -eq 1 ]; then
    for _hx_field in "$@"; do
      [ "$_hx_first" -eq 1 ] || _hx_out="${_hx_out}00"
      _hx_first=0
      for ((_hx_i = 0; _hx_i < ${#_hx_field}; _hx_i++)); do
        printf -v _hx_byte '%02x' "'${_hx_field:_hx_i:1}"
        _hx_out="$_hx_out$_hx_byte"
      done
    done
  else
    _hx_out=$(printf '%s\0%s\0%s\0%s\0%s\0%s' "$@" | od -An -v -tx1 | tr -d ' \n') || return 1
  fi
  printf -v "$_hx_var" '%s' "$_hx_out"
}

# Reported-state signature of <file> into <out-var>. A caller that already holds
# the size or identity passes them; otherwise one stat supplies them, unless a
# test seam replaces the identity or size reader, which keeps the separate reads.
status_observed_signature_to() {  # <out-var> <file> [size] [ident]
  local f=$2 size=${3-} ident=${4-} path_state link_target=- access kind
  local facts='' f_state f_size f_ident f_epoch f_birth birth rest hex
  if [ -n "${FM_STATUS_IDENTITY_READER:-}${FM_STATUS_SIZE_READER:-}" ]; then
    path_state=$(_status_observed_path_state "$f") || path_state=stat-error
  elif facts=$(_status_observed_facts "$f"); then
    f_state=${facts%%|*}; rest=${facts#*|}
    f_size=${rest%%|*}; rest=${rest#*|}
    f_ident=${rest%%|*}; rest=${rest#*|}
    f_epoch=${rest%%|*}; f_birth=${rest#*|}
    path_state=$f_state
  else
    path_state=stat-error
  fi
  if [ -L "$f" ]; then
    link_target=$(readlink "$f" 2>/dev/null) || link_target=readlink-error
    kind=symlink
  elif [ ! -e "$f" ]; then
    kind=absent
  elif [ ! -f "$f" ]; then
    kind=nonregular
  elif [ -r "$f" ]; then
    kind=readable
  else
    kind=unreadable
  fi
  if [ -z "$size" ]; then
    if [ -n "${FM_STATUS_IDENTITY_READER:-}${FM_STATUS_SIZE_READER:-}" ]; then
      size=$(_fm_status_file_size "$f") || size='size-error'
    else
      size=${f_size-size-error}
    fi
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) size='size-error' ;; esac
  fi
  if [ -z "$ident" ]; then
    if [ -n "${FM_STATUS_IDENTITY_READER:-}${FM_STATUS_SIZE_READER:-}" ]; then
      ident=$(_fm_open_decisions_file_ident "$f") || ident=identity-error
    elif [ -n "${f_ident-}" ]; then
      # Same rule as _fm_open_decisions_file_ident: a birth time is part of the
      # identity only when the file system records one.
      birth=''
      [ "$f_epoch" = 0 ] || birth=$f_birth
      case "$f_ident$birth" in
        *$'\t'*|*$'\n'*) ident=identity-error ;;
        *)
          if [ -n "$birth" ]; then ident="strong:$f_ident:$birth"; else ident="weak:$f_ident"; fi
          ;;
      esac
    else
      ident=identity-error
    fi
    [ -n "$ident" ] || ident=identity-error
  fi
  if [ -r "$f" ]; then access=readable; else access=unreadable; fi
  _status_hex_fields_to hex "$size" "$ident" "$path_state" "$link_target" "$access" "$kind" || return 1
  printf -v "$1" 'r1:%s' "$hex"
}

status_observed_signature() {  # <file> [size] [ident]
  local _fm_sig_out
  status_observed_signature_to _fm_sig_out "$@" || return 1
  printf '%s' "$_fm_sig_out"
}

status_presentation_marker_commit() {
  local marker=$1 file=$2 endpoint=$3 ident=$4 current reported classified
  case "$endpoint" in ''|*[!0-9]*) return 1 ;; esac
  current=$(_fm_open_decisions_file_ident "$file") || return 1
  [ -n "$ident" ] && [ "$ident" = "$current" ] || return 1
  reported=$(status_observed_signature "$file" "$endpoint" "$ident") || return 1
  classified="${endpoint}@${ident}"
  printf 'v2\t%s\t%s' "$reported" "$classified" > "$marker"
}
# Read the legacy per-task open-decisions cursor used to seed the presentation
# offset before the fleet manifest exists. A fold-version mismatch, identity
# mismatch, or offset past the current size falls back to 0. Never writes unless
# a caller explicitly requests a migration snapshot.
status_open_decisions_cursor_offset() {  # <status-file>
  local f=$1 cf offset=0 ident='' version='' cursor_data first rest open=''
  local offset_line ident_line cur_ident size fold_version boundary_rc
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  fold_version=$(_fm_open_decisions_fold_signature "$(_fm_status_kind "$f")")
  cf=$(_fm_open_decisions_cursor_path "$f")
  if [ -e "$cf" ] || [ -L "$cf" ]; then
    [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ] || return 1
    if cursor_data=$(LC_ALL=C command cat "$cf" 2>/dev/null); then
      first=${cursor_data%%$'\n'*}
      case "$first" in
        version=*)
          version=${first#version=}
          [ "$version" = "$fold_version" ] || version=''
          rest=${cursor_data#*$'\n'}
          offset_line=${rest%%$'\n'*}
          case "$offset_line" in
            offset=*) offset=${offset_line#offset=} ;;
            *) offset=0; version='' ;;
          esac
          case "$offset" in
            ''|*[!0-9]*) offset=0; version='' ;;
            *)
              case "$rest" in
                *$'\n'*)
                  rest=${rest#*$'\n'}
                  ident_line=${rest%%$'\n'*}
                  case "$ident_line" in
                    ident=*)
                      ident=${ident_line#ident=}
                      case "$rest" in *$'\n'*) open=${rest#*$'\n'} ;; esac
                      ;;
                    *) offset=0; version='' ;;
                  esac
                  ;;
                *) offset=0; version='' ;;
              esac
              ;;
          esac
          ;;
      esac
    else
      return 1
    fi
  fi
  cur_ident=$(_fm_open_decisions_file_ident "$f") || return 1
  [ -n "$cur_ident" ] || return 1
  size=$(_fm_status_file_size "$f") || return 1
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$version" ] || [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then
    offset=0
    open=''
  elif _fm_open_decisions_checkpoint_boundary "$f" "$offset"; then
    :
  else
    boundary_rc=$?
    [ "$boundary_rc" -ne 2 ] || return 1
    offset=0
    open=''
  fi
  if [ -n "${FM_STATUS_CURSOR_SNAPSHOT_FILE:-}" ]; then
    {
      printf 'version=%s\n' "$fold_version"
      printf 'offset=%s\n' "$offset"
      printf 'ident=%s\n' "$cur_ident"
      if [ -n "$open" ]; then printf '%s' "$open"; fi
    } > "$FM_STATUS_CURSOR_SNAPSHOT_FILE" || return 1
  fi
  printf '%s' "$offset"
}

# Print every non-blank status line whose bytes begin at or after the persisted
# presentation offset. Does not write the cursor. A missing manifest row or
# changed status identity reads the current file from offset 0; malformed or
# unreadable cursor state fails the scan. Symlinks and unreadable status files
# print nothing. With <out-var>, the lines are assigned to it instead of
# printed, so a per-task scan takes them without forking a substitution.
status_new_lines_since_cursor() {  # <status-file> [<captured-end-offset>] [<out-var>]
  local f=$1 captured_end=${2:-} __fm_nl_out=${3-} __fm_nl_acc='' cf offset size actual_size chunk_file line rc=0
  [ -z "$__fm_nl_out" ] || printf -v "$__fm_nl_out" '%s' ''
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  _fm_open_decisions_cursor_path "$f" cf
  chunk_file="$cf.unread.$$"
  status_presentation_cursor_offset "$f" offset || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  _fm_status_file_size "$f" actual_size || return 1
  actual_size=${actual_size//[[:space:]]/}
  case "$actual_size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -n "$captured_end" ]; then
    case "$captured_end" in ''|*[!0-9]*) return 1 ;; esac
    [ "$captured_end" -le "$actual_size" ] || return 1
    size=$captured_end
  else
    size=$actual_size
  fi
  [ "$offset" -lt "$size" ] || return 0
  _fm_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk_file" 2>/dev/null \
    || { rm -f "$chunk_file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *[![:space:]]*)
        if [ -n "$__fm_nl_out" ]; then
          __fm_nl_acc+="$line"$'\n'
        else
          printf '%s\n' "$line" || { rc=1; break; }
        fi
        ;;
    esac
  done < "$chunk_file"
  rm -f "$chunk_file"
  # Matches the stripped-newline text a command substitution would have given.
  [ -z "$__fm_nl_out" ] || printf -v "$__fm_nl_out" '%s' "${__fm_nl_acc%$'\n'}"
  return "$rc"
}

# 0 when a status line is an informational `note:` or a reserved-key
# pending-reply resolution. Those lines never fold into OPEN DECISIONS, so the
# drain's unread-status surface is their only guaranteed presentation.
status_line_is_unread_surface() {  # <status-line>
  local line=$1 verb key note resolve held prefix
  [ -n "$line" ] || return 1
  status_line_verb "$line" verb
  [ "$verb" = note ] && return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$verb" in
    "$resolve"|"$held") ;;
    *) return 1 ;;
  esac
  _fm_decision_key_into "$line" default key || return 1
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        status_line_note "$line" note
        _fm_decision_key_transition_allowed "$key" "$note"
        return
        ;;
    esac
  done
  return 1
}
# --- home-owned status-append ledger ----------------------------------------
#
# This home's bookkeeping closes (fm_wake_status_append_self_announced) record
# the exact byte range they appended so the wake scan can tell this home's own
# growth from a foreign write. That is the multi-answer path: two distinct
# --resolve-key closes must not each force a captain-facing wake solely because
# each one appended a status line, while a worker-authored line that is not in
# this ledger still signals.
# fm_wake_signal_seen_current (bin/fm-wake-lib.sh) is the ONLY consumer. The
# ledger decides whether growth wakes this home and nothing else: it never
# removes a line from presentation, so the drain's signal annotation and its
# UNREAD STATUS section both still print these bytes.
# The ledger does not use lag verbs to hide a worker `resolved` line; only
# bytes this home itself recorded as owned are ever treated as owned.
#
# Path: state/.<task>.home-appends
# Format:
#   v1
#   ident=<file-ident>
#   <start><TAB><end>
# Ranges are half-open [start, end), written in the order they were appended.
# The only writer is fm_wake_status_append_self_announced, which records the
# pre- and post-append size of an append-only log it just grew, so each new
# start is at or after the last recorded end; a new range that begins exactly
# where the last one ended extends that line instead of adding another.
# status_home_appends_covers depends on that ascending order: it walks the
# ledger once and ignores any range starting past the point it has reached, so
# a ledger written out of order would refuse to prove coverage and fail toward
# waking, never toward silence.
# An identity mismatch (file rotated) discards the ledger. Teardown deletes it.
# Not a pure status-file read: status_home_appends_record writes this sidecar.
# That read-merge-write serializes through bin/fm-wake-lib.sh's fm_lock_*
# helpers, exactly as status_retire_presentation_task in bin/fm-classify-lib.sh does, so a caller
# that touches this ledger must have sourced that library first.

status_home_appends_path() {  # <status-file>
  local f=$1 dir base
  dir=$(dirname "$f")
  base=$(basename "$f")
  printf '%s/.%s.home-appends' "$dir" "${base%.status}"
}

status_home_appends_ranges() {  # <status-file> -> start<TAB>end lines
  local f=$1 path ident data first rest line start end extra
  path=$(status_home_appends_path "$f")
  [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || return 0
  ident=$(_fm_open_decisions_file_ident "$f") || return 0
  data=$(LC_ALL=C command cat "$path" 2>/dev/null) || return 0
  first=${data%%$'\n'*}
  [ "$first" = v1 ] || return 0
  rest=${data#*$'\n'}
  [ "$rest" != "$data" ] || return 0
  line=${rest%%$'\n'*}
  case "$line" in ident=*) ;; *) return 0 ;; esac
  [ "${line#ident=}" = "$ident" ] || return 0
  case "$rest" in
    *$'\n'*) rest=${rest#*$'\n'} ;;
    *) return 0 ;;
  esac
  while IFS=$'\t' read -r start end extra || [ -n "$start" ]; do
    [ -n "$start" ] || continue
    [ -z "$extra" ] || continue
    case "$start:$end" in *[!0-9:]*) continue ;; esac
    [ "$end" -gt "$start" ] || continue
    printf '%s\t%s\n' "$start" "$end" || return 1
  done <<EOF
$rest
EOF
}

status_home_appends_covers() {  # <status-file> <start> <end>
  local start=$2 end=$3 range_start range_end
  case "$start:$end" in *[!0-9:]*) return 1 ;; esac
  [ "$end" -ge "$start" ] || return 1
  while IFS=$'\t' read -r range_start range_end; do
    [ -n "$range_start" ] || continue
    case "$range_start:$range_end" in *[!0-9:]*) continue ;; esac
    [ "$range_start" -le "$start" ] || continue
    if [ "$range_end" -gt "$start" ]; then
      start=$range_end
    fi
    if [ "$start" -ge "$end" ]; then
      return 0
    fi
  done <<EOF
$(status_home_appends_ranges "$1")
EOF
  [ "$start" -ge "$end" ]
}

status_home_appends_record() {  # <status-file> <start> <end>
  local f=$1 start=$2 end=$3 path lock rc=0
  case "$start:$end" in *[!0-9:]*) return 1 ;; esac
  [ "$end" -gt "$start" ] || return 1
  path=$(status_home_appends_path "$f")
  lock="$path.lock"
  fm_lock_acquire_wait "$lock" || return 1
  _fm_status_home_appends_merge_locked "$f" "$path" "$start" "$end" || rc=1
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

_fm_status_home_appends_merge_locked() {  # <status-file> <ledger-path> <start> <end>
  local f=$1 path=$2 start=$3 end=$4 ident tmp line last='' body='' coalesced=0
  local LC_ALL=C
  ident=$(_fm_open_decisions_file_ident "$f") || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -n "$last" ]; then body="${body}${last}"$'\n'; fi
    last=$line
  done <<EOF
$(status_home_appends_ranges "$f")
EOF
  if [ -n "$last" ]; then
    if [ "${last#*$'\t'}" = "$start" ]; then
      last="${last%%$'\t'*}"$'\t'"$end"
      coalesced=1
    fi
    body="${body}${last}"$'\n'
  fi
  if [ "$coalesced" -eq 0 ]; then
    body="${body}${start}"$'\t'"${end}"$'\n'
  fi
  tmp="$path.tmp.$$"
  printf 'v1\nident=%s\n%s' "$ident" "$body" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# Capture the bytes of an append-only status log at or after <start-offset> under
# one size-and-identity snapshot.
# The record form produces `<endpoint>\t<identity>\t<events>` and returns 0 when
# the span has actionable events, joining every such event in source order with
# ` ; ` so callers report the complete captured span before committing it.
# With optional <record-var>, it assigns that record instead of printing it; with
# optional <needs-decision-var>, it also assigns 1 when the span newly surfaces a
# needs-decision, captain-held declaration, or pending-reply escalation, otherwise
# 0. This side-band classification never changes the event text.
# It returns 1 after a successful classification with no actionable event; an
# existing log still produces its committable endpoint and identity, while an absent
# log is the ordinary empty case and produces no record.
# It returns 2 with no committable endpoint when an existing status object cannot
# be classified.
# The simpler wrapper prints only the event field, and the predicate discards the
# record; all three inherit the library-header contract above.
#
# A keyed `needs-decision` or `blocked` opening is included only when the
# captured span's fold still names that exact opening as live.
# Earlier log lines cannot change whether an opening in the span survives:
# only later lines can close or supersede it. Folding only the span therefore
# gives the same verdict for its openings without rereading the log's history.
# A transition rejected by the reserved-key vocabulary is surfaced instead as a
# reconciliation signal and never treated here as an open decision.
# status_open_decisions remains the single owner of open/closed semantics,
# including same-key reopening and reserved-key handling.
# Every other captain-relevant event is terminal and always actionable.
_fm_decision_origin_drop() {  # <origins> <key>
  local origin
  while IFS= read -r origin; do
    case "$origin" in "$2"$'\t'*) ;; *) [ -n "$origin" ] && printf '%s\n' "$origin" ;; esac
  done <<EOF
$1
EOF
}

_fm_status_open_decision_origins() {  # <status-file> [<kind>]
  local f=$1 line open='' after='' key verb note number=0 origins=''
  local resolve held kind
  kind=$(_fm_status_kind "$f" "${2:-}")
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    _fm_decision_fold_line_into "$open" "$line" "$resolve" "$held" "$kind" after
    [ -n "$after" ] || origins=''
    key=$(_fm_decision_key "$line") || { open=$after; continue; }
    verb=$(status_line_verb "$line")
    note=$(status_line_note "$line")
    case "$verb" in
      needs-decision|blocked)
        if _fm_open_set_has "$after" "$key" \
          && [ "$(_fm_open_set_verb "$after" "$key")" = "$verb" ]; then
          case "$after" in
            "$key"$'\t'"$verb"$'\t'"$note"|*$'\n'"$key"$'\t'"$verb"$'\t'"$note")
              origins=$(_fm_decision_origin_drop "$origins" "$key")
              [ -n "$origins" ] && origins="${origins}"$'\n'
              origins="${origins}${key}"$'\t'"${number}"
              ;;
          esac
        fi
        ;;
      "$resolve"|"$held")
        _fm_open_set_has "$after" "$key" || origins=$(_fm_decision_origin_drop "$origins" "$key")
        ;;
    esac
    open=$after
  done < "$f"
  printf '%s' "$origins"
}

status_span_first_actionable_record() {  # <status-file> <start-offset> [record-var] [needs-decision-var]
  local f=$1 start=${2:-0} output_var=${3-} needs_var=${4-} size ident cur_ident scratch chunk_file result
  local line verb key origins='' folded=0 rc=1 failed=0 line_number=0 live_line='' events='' _line _key _fm_span_needs_decision=0
  [ -e "$f" ] || { [ -L "$f" ] && return 2; return 1; }
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 2
  ident=$(_fm_open_decisions_file_ident "$f") || return 2
  size=$(_fm_status_file_size "$f") || return 2
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 2 ;; esac
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  [ "$start" -le "$size" ] || start=0
  if [ "$start" -ge "$size" ]; then
    result="${size}"$'\t'"${ident}"
    if [ -n "$output_var" ]; then
      printf -v "$output_var" '%s' "$result"
      [ -z "$needs_var" ] || printf -v "$needs_var" '%s' 0
    else
      printf '%s' "$result"
    fi
    return 1
  fi
  scratch=$(_fm_status_span_scratch "$f") || return 2
  chunk_file="${scratch}.span"
  _fm_status_read_span "$f" "$start" "$((size - start))" > "$chunk_file" 2>/dev/null \
    || { rm -f "$chunk_file"; return 2; }
  cur_ident=$(_fm_open_decisions_file_ident "$f") || {
    rm -f "$chunk_file"; return 2;
  }
  [ "$cur_ident" = "$ident" ] || { rm -f "$chunk_file"; return 2; }
  # shellcheck disable=SC2094 # The loop and the origin fold below only read the span scratch.
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    if status_is_captain_held "$line"; then
      # A transfer closes the status-log decision and remains non-actionable to
      # stale classification. The side-band marker lets signal routing surface
      # the captain-owned hold without changing that established stale verdict.
      _fm_span_needs_decision=1
      continue
    fi
    status_is_captain_relevant "$line" || continue
    verb=$(status_line_verb "$line")
    case "$verb" in
      needs-decision|blocked)
        key=$(_fm_decision_key "$line") || {
          [ -n "$events" ] && events="${events} ; "
          events="${events}${line}"
          [ "$verb" = needs-decision ] && _fm_span_needs_decision=1
          rc=0
          continue
        }
        _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")" || {
          [ -n "$events" ] && events="${events} ; "
          events="${events}reconciliation-required: ${line}"
          [ "$verb" = needs-decision ] && _fm_span_needs_decision=1
          rc=0
          continue
        }
        if [ "$folded" -eq 0 ]; then
          origins=$(_fm_status_open_decision_origins "$chunk_file" "$(_fm_status_kind "$f")") || { failed=1; break; }
          folded=1
        fi
        live_line=$(while IFS=$'\t' read -r _key _line; do
          [ "$_key" = "$key" ] && { printf '%s' "$_line"; break; }
        done <<EOF
$origins
EOF
)
        [ -n "$live_line" ] && [ "$line_number" -eq "$live_line" ] || continue
        [ -n "$events" ] && events="${events} ; "
        events="${events}${line}"
        if [ "$verb" = needs-decision ] || { [ "$verb" = blocked ] &&
          _fm_is_pending_reply_escalation "$key" "$(status_line_note "$line")"; }; then
          _fm_span_needs_decision=1
        fi
        rc=0
        ;;
      *)
        [ -n "$events" ] && events="${events} ; "
        events="${events}${line}"
        rc=0
        ;;
    esac
  done < "$chunk_file"
  rm -f "$chunk_file"
  [ "$failed" -eq 0 ] || return 2
  if [ "$rc" -eq 0 ]; then result="${size}"$'\t'"${ident}"$'\t'"${events}"; else result="${size}"$'\t'"${ident}"; fi
  if [ -n "$output_var" ]; then
    printf -v "$output_var" '%s' "$result"
    [ -z "$needs_var" ] || printf -v "$needs_var" '%s' "$_fm_span_needs_decision"
  else
    printf '%s' "$result"
  fi
  return "$rc"
}

status_span_first_actionable() {  # <status-file> <start-offset>
  local record rc rest
  record=$(status_span_first_actionable_record "$1" "${2:-0}")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rest=${record#*$'\t'}
    printf '%s' "${rest#*$'\t'}"
  fi
  return "$rc"
}

status_span_has_actionable() {  # <status-file> <start-offset>
  status_span_first_actionable_record "$1" "${2:-0}" > /dev/null
}
