#!/usr/bin/env bash

_FM_CLASSIFY_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The kernel name, read once at source time rather than forked by every status
# stat helper below. These helpers mostly run inside $() subshells, where a lazy
# cache would never persist. fm-wake-lib.sh's _FM_UNAME is reused when it is
# already loaded; either value is compared only against Darwin.
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


# Portable strongest-available identity: strong:<device>:<inode>:<birth-time>
# when birth time is available, otherwise weak:<device>:<inode>.
# The default reader captures identity and size in one stat invocation to avoid
# repeated per-task scheduling and to sample both from the same metadata read.
# Optional output variables let warm fold callers avoid command substitutions;
# without an identity output variable, the identity is printed on stdout.
_fm_open_decisions_file_ident() {  # <file> [<identity-out-var> [<size-out-var>]]
  local __fm_info_record __fm_info_rest __fm_info_ident __fm_info_epoch __fm_info_birth __fm_info_size
  if [ -n "${FM_STATUS_IDENTITY_READER:-}" ]; then
    __fm_info_ident=$("$FM_STATUS_IDENTITY_READER" "$1") || return 1
    if [ -n "${3:-}" ]; then __fm_info_size=$(_fm_status_file_size "$1") || return 1; fi
  else
    if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
      __fm_info_record=$(LC_ALL=C /usr/bin/stat -f $'%d:%i\t%B\t%FB\t%z' "$1" 2>/dev/null) || return 1
    else
      __fm_info_record=$(LC_ALL=C stat -c $'%d:%i\t%W\t%w\t%s' "$1" 2>/dev/null) || return 1
    fi
    __fm_info_ident=${__fm_info_record%%$'\t'*}
    __fm_info_rest=${__fm_info_record#*$'\t'}
    __fm_info_epoch=${__fm_info_rest%%$'\t'*}
    __fm_info_rest=${__fm_info_rest#*$'\t'}
    __fm_info_birth=${__fm_info_rest%%$'\t'*}
    __fm_info_size=${__fm_info_rest#*$'\t'}
    [ "$__fm_info_epoch" != 0 ] || __fm_info_birth=''
    case "$__fm_info_ident$__fm_info_birth" in *$'\t'*|*$'\n'*|'') return 1 ;; esac
    if [ -n "$__fm_info_birth" ]; then
      __fm_info_ident="strong:$__fm_info_ident:$__fm_info_birth"
    else
      __fm_info_ident="weak:$__fm_info_ident"
    fi
    if [ -n "${3:-}" ] && [ -n "${FM_STATUS_SIZE_READER:-}" ]; then
      __fm_info_size=$("$FM_STATUS_SIZE_READER" "$1") || return 1
    fi
  fi
  if [ -n "${3:-}" ]; then printf -v "$3" '%s' "$__fm_info_size"; fi
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__fm_info_ident"; else printf '%s' "$__fm_info_ident"; fi
}

_fm_status_file_size() {  # <status-file>
  local f=$1
  if [ -n "${FM_STATUS_SIZE_READER:-}" ]; then
    "$FM_STATUS_SIZE_READER" "$f"
    return
  fi
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f '%z' "$f" 2>/dev/null
  else
    LC_ALL=C stat -c '%s' "$f" 2>/dev/null
  fi
}

_fm_status_file_mtime() {  # <status-file>
  local f=$1
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f '%m' "$f" 2>/dev/null
  else
    LC_ALL=C stat -c '%Y' "$f" 2>/dev/null
  fi
}

# Private scratch path for a one-shot span read, alongside the status file the
# same way the cursor above is, and PID-scoped so concurrent readers of one log
# (the watcher and the away-mode daemon both classify the same stream) never
# truncate each other's chunk.
_fm_status_span_scratch() {  # <status-file>
  printf '%s.span.%s' "$(_fm_open_decisions_cursor_path "$1")" "$$"
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

  before_mtime=$(_fm_status_file_mtime "$f") || return 1
  before_size=$(_fm_status_file_size "$f") || return 1
  before_size=${before_size//[[:space:]]/}
  before_ident=$(_fm_open_decisions_file_ident "$f") || return 1
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

  after_mtime=$(_fm_status_file_mtime "$f") || return 1
  after_size=$(_fm_status_file_size "$f") || return 1
  after_size=${after_size//[[:space:]]/}
  after_ident=$(_fm_open_decisions_file_ident "$f") || return 1
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
