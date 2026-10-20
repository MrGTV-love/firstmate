#!/usr/bin/env bash

_FM_CLASSIFY_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# shellcheck source=bin/fm-file-identity-lib.sh
. "$_FM_CLASSIFY_LIB_DIR/fm-file-identity-lib.sh"

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
  local __fm_sb_file __fm_sb_data='' __fm_sb_files=() __fm_sb_manifest="$1/.status-presentation-cursor"
  printf -v "$2" '%s' ''
  for __fm_sb_file in "$__fm_sb_manifest" "$1"/*.status; do
    if [ "$__fm_sb_file" != "$__fm_sb_manifest" ] && [ -n "${FM_STATUS_IDENTITY_READER:-}${FM_STATUS_SIZE_READER:-}" ]; then continue; fi
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

# Read the presentation manifest without per-task cat forks, keeping trailing
# newlines. Publish <out-var> only after a successful read of the metadata byte
# count; open/read failures, short reads, and NUL-delimited prefixes leave it
# unchanged. Consumers distinguish a missing manifest from a failed read of an
# existing receipt, which must never become an empty or partial successful read.
_fm_read_file_into() {  # <file> <out-var>
  local __fm_rf_data='' __fm_rf_size LC_ALL=C
  _fm_status_stat_raw "$1" '' __fm_rf_size '' || return 1
  case "$__fm_rf_size" in ''|*[!0-9]*) return 1 ;; esac
  { [ "$__fm_rf_size" -eq 0 ] || IFS= read -r -d '' -n "$__fm_rf_size" __fm_rf_data; } 2>/dev/null < "$1" || return 1
  [ "${#__fm_rf_data}" -eq "$__fm_rf_size" ] || return 1
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
# Split an r1 signature on NUL bytes, not on the substring "00" (a hex
# substring can cross a byte boundary). Decode only identity; the other five
# fields stay byte-exact hex, so path/access/type changes cannot be adopted.
_status_reported_identity_into() {  # <signature> <identity-out> <other-fields-out>
  local __fm_ri_hex=${1#r1:} __fm_ri_pair __fm_ri_field=0 __fm_ri_esc='' __fm_ri_other=''
  case "$1" in r1:*) ;; *) return 1 ;; esac
  case "$__fm_ri_hex" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "$((${#__fm_ri_hex} % 2))" -eq 0 ] || return 1
  while [ -n "$__fm_ri_hex" ]; do
    __fm_ri_pair=${__fm_ri_hex:0:2}; __fm_ri_hex=${__fm_ri_hex:2}
    if [ "$__fm_ri_pair" = 00 ]; then
      __fm_ri_field=$((__fm_ri_field + 1))
      __fm_ri_other="${__fm_ri_other}00"
    elif [ "$__fm_ri_field" -eq 1 ]; then
      __fm_ri_esc="${__fm_ri_esc}\\x${__fm_ri_pair}"
    else
      __fm_ri_other="${__fm_ri_other}${__fm_ri_pair}"
    fi
  done
  [ "$__fm_ri_field" -eq 5 ] || return 1
  printf -v "$2" '%b' "$__fm_ri_esc"
  printf -v "$3" '%s' "$__fm_ri_other"
}

# A strong identity (device:inode:birth) that differs from another only in its
# device number. A weak identity, which lacks a birth time, never qualifies.
_fm_status_ident_device_shifted() {  # <recorded-identity> <current-identity>
  case "$1" in strong:*:*:?*) ;; *) return 1 ;; esac
  case "$2" in strong:*:*:?*) ;; *) return 1 ;; esac
  fm_file_identity_device_shifted "${1#strong:}" "${2#strong:}"
}

# Explicit migration, separate from the pure marker readers below. The marker's
# classified position migrates whenever its strong inode+birth are unchanged and
# its offset is within the file: the offset is kept, so a log that grew past it
# reads only the new bytes. The reported signature migrates only when every
# other observed field is also unchanged; a grown or otherwise changed log keeps
# its old signature and signals once. Never advance a classified offset or turn
# a reported-but-unclassified state into a classified one. Revalidate the file
# and marker immediately before atomic publication; failure leaves detection
# conservative. A marker whose reported signature already equals the current one
# is left alone. Every scan that reads a marker calls this first.
status_presentation_marker_adopt_device() {  # <marker> <status-file> [current-signature]
  local marker=$1 file=$2 current=${3-} raw reported classified old_ident new_ident old_other new_other
  local new_reported new_classified offset fresh fresh_ident='' fresh_size='' tmp
  [ -f "$marker" ] && [ -r "$marker" ] && [ ! -L "$marker" ] || return 1
  { IFS= read -r -d '' raw || :; } 2>/dev/null < "$marker" || return 1
  while [ "${raw%$'\n'}" != "$raw" ]; do raw=${raw%$'\n'}; done
  status_presentation_marker_parse "$raw" || return 1
  reported=$STATUS_PRESENTATION_REPORTED
  classified=$STATUS_PRESENTATION_CLASSIFIED
  [ -n "$current" ] || current=$(status_observed_signature "$file") || return 1
  [ "$reported" != "$current" ] || return 0
  _status_reported_identity_into "$current" new_ident new_other || return 1
  new_reported=$reported
  new_classified=$classified
  if _status_reported_identity_into "$reported" old_ident old_other \
    && [ "$old_other" = "$new_other" ] \
    && _fm_status_ident_device_shifted "$old_ident" "$new_ident"; then
    new_reported=$current
  fi
  if [ "$classified" != - ]; then
    offset=${classified%%@*}
    if _fm_status_ident_device_shifted "${classified#*@}" "$new_ident"; then
      new_classified="${offset}@${new_ident}"
    fi
  fi
  [ "$new_reported" != "$reported" ] || [ "$new_classified" != "$classified" ] || return 0
  if [ "$new_reported" != "$reported" ]; then
    fresh=$(status_observed_signature "$file") && [ "$fresh" = "$current" ] || new_reported=$reported
  fi
  if [ "$new_classified" != "$classified" ]; then
    _fm_open_decisions_file_ident "$file" fresh_ident fresh_size || fresh_ident=
    fresh_size=${fresh_size//[[:space:]]/}
    case "$fresh_size" in ''|*[!0-9]*) fresh_size=-1 ;; esac
    { [ "$fresh_ident" = "$new_ident" ] && [ "$offset" -le "$fresh_size" ]; } || new_classified=$classified
  fi
  [ "$new_reported" != "$reported" ] || [ "$new_classified" != "$classified" ] || return 1
  [ "$(cat "$marker" 2>/dev/null)" = "$raw" ] || return 1
  tmp=$(mktemp "$marker.device.XXXXXX") || return 1
  if ! printf 'v2\t%s\t%s' "$new_reported" "$new_classified" > "$tmp" \
    || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    return 1
  fi
}

status_presentation_marker_reported_matches() {
  local raw
  # Read the marker with the shell's own read, not a cat process: this runs for
  # every status log on every watcher cycle. Trailing newlines are dropped, as
  # the command substitution this replaced dropped them.
  { IFS= read -r -d '' raw || :; } 2>/dev/null < "$1" || return 1
  while [ "${raw%$'\n'}" != "$raw" ]; do raw=${raw%$'\n'}; done
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
