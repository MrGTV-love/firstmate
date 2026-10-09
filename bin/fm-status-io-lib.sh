#!/usr/bin/env bash

_FM_CLASSIFY_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# Read the kernel name once at source time, not per status metadata lookup.
# This also serves stdout helpers called through $(), where a lazy cache would
# not persist. Reuse fm-wake-lib.sh's _FM_UNAME when already loaded; either value
# is compared only against Darwin.
_FM_CLASSIFY_UNAME_S=${_FM_UNAME:-$(uname -s 2>/dev/null)}


# fm_run_timed supplies the shared hard bound for the worktree write probe in
# bin/fm-classify-lib.sh. bin/fm-timeout-lib.sh owns bounded execution for this
# repo, so nothing here re-derives the coreutils/BSD/perl selection. That library
# declares `set -u` for its own hygiene, which a sourced sibling must not impose on
# this library's consumers - several of them deliberately run without it - so the
# caller's setting is restored around the source.
case $- in *u*) _fm_classify_nounset=on ;; *) _fm_classify_nounset=off ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_CLASSIFY_LIB_DIR/fm-timeout-lib.sh"
[ "$_fm_classify_nounset" = on ] || set +u
unset _fm_classify_nounset

# Parameter expansion rather than dirname and basename: every presentation scan
# asks for the cursor path of every task, and two child processes per call were
# the largest process count in a wake drain.
_fm_open_decisions_cursor_path() {  # <status-file> [<out-var>]
  local __fm_cursor_file=$1 __fm_cursor_dir __fm_cursor_base __fm_cursor_path
  case "$__fm_cursor_file" in
    */*)
      __fm_cursor_dir=${__fm_cursor_file%/*}
      while [ "${__fm_cursor_dir%/}" != "$__fm_cursor_dir" ]; do __fm_cursor_dir=${__fm_cursor_dir%/}; done
      [ -n "$__fm_cursor_dir" ] || __fm_cursor_dir=/
      ;;
    *) __fm_cursor_dir=. ;;
  esac
  __fm_cursor_base=${__fm_cursor_file##*/}
  __fm_cursor_path="$__fm_cursor_dir/.${__fm_cursor_base%.status}.open-decisions-cursor"
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__fm_cursor_path"; else printf '%s' "$__fm_cursor_path"; fi
}


# A scan scopes these facts with `local _FM_STATUS_STAT_BATCH`, then refreshes
# them before walking the fleet. Never carry them across scans or reuse them for
# a post-read validation; cursor commitment must start a new metadata scan.
# Identity/size reader seams bypass batching and keep their per-file calls.
# An unavailable batch or unrepresentable path falls back to per-file metadata.
_fm_status_stat_batch_into() {  # <state> <out-var>
  local __fm_sb_file __fm_sb_data='' __fm_sb_files=()
  printf -v "$2" '%s' ''
  [ -z "${FM_STATUS_IDENTITY_READER:-}${FM_STATUS_SIZE_READER:-}" ] || return 0
  for __fm_sb_file in "$1"/*.status; do
    [ -f "$__fm_sb_file" ] && [ -r "$__fm_sb_file" ] && [ ! -L "$__fm_sb_file" ] || continue
    # Unusual path bytes cannot be represented in this private row format.
    case "$__fm_sb_file" in *$'\t'*|*$'\n'*) return 0 ;; esac
    __fm_sb_files[${#__fm_sb_files[@]}]=$__fm_sb_file
  done
  [ "${#__fm_sb_files[@]}" -gt 0 ] || return 0
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    __fm_sb_data=$(LC_ALL=C /usr/bin/stat -f $'%N\t%d:%i|%B|%FB|%z|%m' "${__fm_sb_files[@]}" 2>/dev/null) || return 0
  else
    __fm_sb_data=$(LC_ALL=C stat -c $'%n\t%d:%i|%W|%w|%s|%Y' "${__fm_sb_files[@]}" 2>/dev/null) || return 0
  fi
  printf -v "$2" '%s' "$__fm_sb_data"
}

# Use this scan's batch row when available; otherwise read device:inode identity,
# birth time, size, and mtime together in one per-file stat, avoiding separate
# forks and observations for each field. A batch row is not fresh validation.
# <ident-var>, <size-var>, and <mtime-var> name the variables to set; an empty
# name skips that value. A value this host cannot read fails the whole call.
# Every local below carries the __fm_ prefix because an out-var named like an
# unprefixed local would be assigned here and lost under bash's dynamic scope.
_fm_status_stat_raw() {  # <file> <ident-var> <size-var> <mtime-var>
  local __fm_st_facts='' __fm_st_path __fm_st_row __fm_st_dev_ino __fm_st_epoch __fm_st_birth __fm_st_rest __fm_st_size __fm_st_mtime
  while IFS=$'\t' read -r __fm_st_path __fm_st_row; do
    if [ "$__fm_st_path" = "$1" ]; then __fm_st_facts=$__fm_st_row; break; fi
  done <<EOF
${_FM_STATUS_STAT_BATCH:-}
EOF
  if [ -z "$__fm_st_facts" ]; then
    if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
      __fm_st_facts=$(LC_ALL=C /usr/bin/stat -f '%d:%i|%B|%FB|%z|%m' "$1" 2>/dev/null) || return 1
    else
      __fm_st_facts=$(LC_ALL=C stat -c '%d:%i|%W|%w|%s|%Y' "$1" 2>/dev/null) || return 1
    fi
  fi
  __fm_st_dev_ino=${__fm_st_facts%%|*}; __fm_st_rest=${__fm_st_facts#*|}
  __fm_st_epoch=${__fm_st_rest%%|*}; __fm_st_rest=${__fm_st_rest#*|}
  # The birth text can hold spaces but never a bar, so the last two bars end it.
  __fm_st_mtime=${__fm_st_rest##*|}; __fm_st_rest=${__fm_st_rest%|*}
  __fm_st_size=${__fm_st_rest##*|}; __fm_st_birth=${__fm_st_rest%|*}
  [ "$__fm_st_epoch" != 0 ] || __fm_st_birth=''
  if [ -n "${2-}" ]; then
    case "$__fm_st_dev_ino$__fm_st_birth" in *$'\t'*|*$'\n'*|'') return 1 ;; esac
    if [ -n "$__fm_st_birth" ]; then
      printf -v "$2" 'strong:%s:%s' "$__fm_st_dev_ino" "$__fm_st_birth"
    else
      printf -v "$2" 'weak:%s' "$__fm_st_dev_ino"
    fi
  fi
  if [ -n "${3-}" ]; then printf -v "$3" '%s' "$__fm_st_size"; fi
  if [ -n "${4-}" ]; then printf -v "$4" '%s' "$__fm_st_mtime"; fi
}

# Printed, or assigned to <out-var> when one is given, so a per-task caller can
# take the identity without forking a command substitution around the stat.
_fm_open_decisions_file_ident() {  # <file> [<identity-out-var> [<size-out-var>]]
  local __fm_id_value
  if [ -n "${FM_STATUS_IDENTITY_READER:-}" ]; then
    if [ "$#" -le 1 ]; then "$FM_STATUS_IDENTITY_READER" "$1"; return; fi
    __fm_id_value=$("$FM_STATUS_IDENTITY_READER" "$1") || return
  else
    _fm_status_stat_raw "$1" __fm_id_value "${3-}" '' || return 1
  fi
  if [ -n "${3:-}" ] && [ -n "${FM_STATUS_IDENTITY_READER:-}${FM_STATUS_SIZE_READER:-}" ]; then
    _fm_status_file_size "$1" "$3" || return 1
  fi
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__fm_id_value"; else printf '%s' "$__fm_id_value"; fi
}

_fm_status_file_size() {  # <status-file> [<out-var>]
  local __fm_sz_value
  if [ -n "${FM_STATUS_SIZE_READER:-}" ]; then
    if [ "$#" -le 1 ]; then "$FM_STATUS_SIZE_READER" "$1"; return; fi
    __fm_sz_value=$("$FM_STATUS_SIZE_READER" "$1") || return
    printf -v "$2" '%s' "$__fm_sz_value"
    return
  fi
  if [ "$#" -gt 1 ]; then
    _fm_status_stat_raw "$1" '' "$2" ''
  else
    _fm_status_stat_raw "$1" '' __fm_sz_value '' || return 1
    printf '%s' "$__fm_sz_value"
  fi
}

_fm_status_file_mtime() {  # <status-file> [<out-var>]
  if [ "$#" -gt 1 ]; then
    _fm_status_stat_raw "$1" '' '' "$2"
    return
  fi
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f '%m' "$1" 2>/dev/null
  else
    LC_ALL=C stat -c '%Y' "$1" 2>/dev/null
  fi
}

# Identity, size, and mtime together: use scan-batched facts or one per-file stat,
# unless a reader seam requires separate reads.
_fm_status_stat_into() {  # <file> <ident-var> <size-var> <mtime-var>
  if [ -n "${FM_STATUS_IDENTITY_READER:-}${FM_STATUS_SIZE_READER:-}" ]; then
    if [ -n "${2-}" ]; then _fm_open_decisions_file_ident "$1" "$2" || return 1; fi
    if [ -n "${3-}" ]; then _fm_status_file_size "$1" "$3" || return 1; fi
    if [ -n "${4-}" ]; then _fm_status_file_mtime "$1" "$4" || return 1; fi
    return 0
  fi
  _fm_status_stat_raw "$1" "${2-}" "${3-}" "${4-}"
}

# Whole file into <out-var> without forking cat: the fleet cursor manifest is
# read once per task per scan, so a child per read was a measurable share of a
# drain's processes. Fails when the file cannot be opened. Trailing newlines
# are kept, and the line loops that consume the text skip blank rows.
_fm_read_file_into() {  # <file> <out-var>
  local __fm_rf_data=
  { IFS= read -r -d '' __fm_rf_data || :; } 2>/dev/null < "$1" || return 1
  printf -v "$2" '%s' "$__fm_rf_data"
}

# Printed, or assigned to <out-var> when one is named: the one place a value
# leaves a function that offers both the printing and the fork-free form.
_fm_emit_value() {  # <out-var-or-empty> <value>
  if [ -n "${1-}" ]; then printf -v "$1" '%s' "$2"; else printf '%s' "$2"; fi
}

# Private scratch path for a one-shot span read, alongside the status file the
# same way the cursor above is, and PID-scoped so concurrent readers of one log
# (the watcher and the away-mode daemon both classify the same stream) never
# truncate each other's chunk.
_fm_status_span_scratch() {  # <status-file>
  local __fm_ss_cursor
  _fm_open_decisions_cursor_path "$1" __fm_ss_cursor
  printf '%s.span.%s' "$__fm_ss_cursor" "$$"
}

_fm_status_read_span() {  # <status-file> <start-offset> <byte-length>
  local f=$1 start=$2 length=$3
  if [ -n "${FM_STATUS_SPAN_READER:-}" ]; then
    "$FM_STATUS_SPAN_READER" "$f" "$start" "$length"
    return
  fi
  perl -MFcntl=:DEFAULT -e '
    my ($path, $start, $length) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    sysseek($file, $start, 0) == $start or exit 1;
    while ($length > 0) {
      my $want = $length > 65536 ? 65536 : $length;
      my $read = sysread($file, my $chunk, $want);
      defined($read) && $read > 0 or exit 1;
      print $chunk or exit 1;
      $length -= $read;
    }
  ' "$f" "$start" "$length"
}
FM_STATUS_SNAPSHOT_EVENT_LINE=
FM_STATUS_SNAPSHOT_EVENT_MTIME=
FM_STATUS_SNAPSHOT_EVENT_ENDPOINT=
# Read the latest non-blank event through one captured presentation endpoint.
# This is the bounded latest-event owner for fleet-wide backstops: at most the
# final 64 KiB is inspected, and a file that changes during the read is deferred
# to the next snapshot instead of combining a line from one state with the mtime
# from another. The status log is append-only and ordinary event lines are far
# below this bound. A pathological latest line that crosses the fixed bound is
# intentionally unclassifiable and omitted: bounded memory and never presenting
# a possibly routine line as captain-facing take precedence on that edge.
# shellcheck disable=SC2034 # Output globals are consumed by sourcing drain scripts.
status_snapshot_latest_event() {  # <status-file> <captured-endpoint> <captured-identity>
  local f=$1 endpoint=$2 expected_ident=$3 limit=65536 start length scratch record line event_endpoint
  local before_mtime after_mtime before_size after_size before_ident after_ident skip_first=0
  FM_STATUS_SNAPSHOT_EVENT_LINE=
  FM_STATUS_SNAPSHOT_EVENT_MTIME=
  FM_STATUS_SNAPSHOT_EVENT_ENDPOINT=
  case "$endpoint" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "$expected_ident" ] || return 1

  _fm_status_stat_into "$f" before_ident before_size before_mtime || return 1
  before_size=${before_size//[[:space:]]/}
  case "$before_mtime:$before_size" in *[!0-9:]*) return 1 ;; esac
  [ "$before_size" -eq "$endpoint" ] && [ "$before_ident" = "$expected_ident" ] || return 1

  if [ "$endpoint" -gt "$limit" ]; then
    start=$((endpoint - limit))
    skip_first=1
  else
    start=0
  fi
  length=$((endpoint - start))
  scratch="$(_fm_status_span_scratch "$f").latest"
  _fm_status_read_span "$f" "$start" "$length" > "$scratch" 2>/dev/null \
    || { rm -f "$scratch"; return 1; }
  if record=$(LC_ALL=C perl -e '
    my ($path, $start, $skip_first) = @ARGV;
    open my $file, "<", $path or exit 1;
    binmode $file;
    scalar(<$file>) if $skip_first;
    my ($latest, $end);
    while (defined(my $line = <$file>)) {
      next unless $line =~ /[^\s]/;
      $line =~ s/[\r\n]+\z//;
      ($latest, $end) = ($line, $start + tell($file));
    }
    exit 1 unless defined $end;
    print "$end\t$latest";
  ' "$scratch" "$start" "$skip_first"); then :; else rm -f "$scratch"; return 1; fi
  rm -f "$scratch"
  event_endpoint=${record%%$'\t'*}
  line=${record#*$'\t'}
  case "$event_endpoint" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$line" ] || return 1

  local _FM_STATUS_STAT_BATCH=''
  _fm_status_stat_into "$f" after_ident after_size after_mtime || return 1
  after_size=${after_size//[[:space:]]/}
  case "$after_mtime:$after_size" in *[!0-9:]*) return 1 ;; esac
  [ "$after_mtime" = "$before_mtime" ] \
    && [ "$after_size" -eq "$endpoint" ] \
    && [ "$after_ident" = "$expected_ident" ] \
    || return 1

  FM_STATUS_SNAPSHOT_EVENT_LINE=$line
  FM_STATUS_SNAPSHOT_EVENT_MTIME=$before_mtime
  FM_STATUS_SNAPSHOT_EVENT_ENDPOINT=$event_endpoint
}

_status_presentation_signature_valid() {
  local value=$1 size ident encoded
  [ "$value" = unverifiable ] && return 0
  case "$value" in
    r1:*)
      encoded=${value#r1:}
      case "$encoded" in ''|*[!0-9a-f]*) return 1 ;; esac
      return 0
      ;;
  esac
  case "$value" in *@*) size=${value%%@*}; ident=${value#*@} ;; *) return 1 ;; esac
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  case "$ident" in ''|*$'\t'*|*$'\n'*) return 1 ;; esac
}

STATUS_PRESENTATION_REPORTED=
STATUS_PRESENTATION_CLASSIFIED=
status_presentation_marker_parse() {
  local raw=$1 rest reported classified
  STATUS_PRESENTATION_REPORTED=
  STATUS_PRESENTATION_CLASSIFIED=
  case "$raw" in
    v2$'\t'*)
      rest=${raw#v2$'\t'}
      case "$rest" in *$'\t'*) reported=${rest%%$'\t'*}; classified=${rest#*$'\t'} ;; *) return 1 ;; esac
      case "$classified" in *$'\t'*) return 1 ;; esac
      _status_presentation_signature_valid "$reported" || return 1
      if [ "$classified" != - ]; then
        _status_presentation_signature_valid "$classified" || return 1
        case "$classified" in unverifiable|r1:*) return 1 ;; esac
      fi
      ;;
    *)
      _status_presentation_signature_valid "$raw" || return 1
      case "$raw" in unverifiable|r1:*) return 1 ;; esac
      reported=$raw
      classified=$raw
      ;;
  esac
  STATUS_PRESENTATION_REPORTED=$reported
  STATUS_PRESENTATION_CLASSIFIED=$classified
}
status_presentation_marker_reported_matches() {
  local raw
  raw=$(cat "$1" 2>/dev/null) || return 1
  status_presentation_marker_parse "$raw" || return 1
  [ "$STATUS_PRESENTATION_REPORTED" = "$2" ]
}

status_presentation_marker_offset() {
  local raw classified offset ident current
  raw=$(cat "$1" 2>/dev/null) || { printf '0'; return 0; }
  status_presentation_marker_parse "$raw" || { printf '0'; return 0; }
  classified=$STATUS_PRESENTATION_CLASSIFIED
  [ "$classified" != - ] || { printf '0'; return 0; }
  offset=${classified%%@*}; ident=${classified#*@}
  current=$(_fm_open_decisions_file_ident "$2") || { printf '0'; return 0; }
  [ "$ident" = "$current" ] || { printf '0'; return 0; }
  printf '%s' "$offset"
}

status_presentation_marker_report() {
  local marker=$1 reported=$2 raw classified=-
  _status_presentation_signature_valid "$reported" || return 1
  if raw=$(cat "$marker" 2>/dev/null) && status_presentation_marker_parse "$raw"; then
    classified=$STATUS_PRESENTATION_CLASSIFIED
  fi
  printf 'v2\t%s\t%s' "$reported" "$classified" > "$marker"
}
