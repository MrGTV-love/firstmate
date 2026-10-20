#!/usr/bin/env bash
# fm-status-cap-lib.sh - the size bounds for append-only task status logs.
# Sourcing this library only defines functions and constants.
#
# A status log (state/<task>.status) and its per-task sidecars are append-only
# records that every supervision reader walks. On 2026-10-18 a shell loop inside
# an agent harness wrote three of them to 140 GB, 265 GB and 122 GB, and every
# reader multiplied the damage. Five numbers bound that, all owned here and
# described for operators in docs/configuration.md "Status log size bounds":
#
#   cap      the byte size a status log may reach through the sanctioned writer
#            (fm_status_append_lines, bin/fm-status-append.sh). The watcher
#            guard (bin/fm-status-cap-guard.sh) also raises its wake when any
#            status log or sidecar passes it.
#   reserve  headroom above the cap that only a decision or terminal event
#            (anything but working: and note:) may use, so a worker can still
#            report done: or blocked: from a log that is at the cap.
#   limit    cap plus reserve: the most a status log can be through the sanctioned
#            writer, and so the most a reader that needs the log's history takes
#            from it. A log up to the limit is read whole and exactly; a log past it
#            is refused, one line on stderr names the file, and nothing is read.
#            A reader never takes a clipped copy of such a log, so no position it
#            returns (a byte offset, a line number) can be relative to a copy.
#   lines    the most lines a reader that loops over a log line by line in the
#            shell takes in one pass. It is the same kind of limit as the byte
#            limit: a span with more lines is refused and named, never clipped, and
#            a reader that only filters with grep or awk, or that must return an
#            exact position, asks for the byte limit alone.
#   window   the most bytes a reader that needs only a log's latest events takes
#            from its end (the last line, the declared wait, a tail for display).
#            It is a tail read, never a substitute for history.
#
# The defaults come from measurement, not guesswork: the largest status log in a
# healthy fleet on 2026-10-18 was 3,230,479 bytes (state/vernant-d7-steward.status,
# 5,338 lines). The cap is 32 MiB, about ten times that, so only a runaway reaches
# it. The window is 4 MiB, 1.3 times that log, so a healthy log is read whole by a
# tail reader too. The line limit is 32768, 6.1 times that log's 5,338 lines, so a
# healthy log is read whole by a line-by-line reader with room to grow. It exists
# because a shell loop costs about 2.7 ms per line in the watcher's span classifier
# (measured 2026-10-18): a flood of tiny lines under the byte limit would otherwise
# hold the watcher for hours, and the watcher is what raises the over-cap wake.
# The cap and the reserve can be overridden by the environment (FM_STATUS_CAP_BYTES,
# FM_STATUS_CAP_RESERVE_BYTES) for a test or a deliberate site choice, and a value
# that is not a positive integer falls back to the default. The window and the line
# limit are constants.

FM_STATUS_CAP_BYTES_DEFAULT=33554432
FM_STATUS_CAP_RESERVE_BYTES_DEFAULT=1048576
_FM_STATUS_READ_WINDOW_BYTES=4194304
_FM_STATUS_READ_LIMIT_LINES=32768

# Printed, or assigned to <out-var> when one is given, so a reader takes the bound
# without forking a command substitution. Locals carry the __fm_cb_ prefix because
# an out-var named like an unprefixed local would be lost under bash's dynamic scope.
_fm_status_bound_value() {  # <value> <default> [<out-var>]
  local __fm_cb_value=$1
  case "$__fm_cb_value" in
    ''|*[!0-9]*) __fm_cb_value=$2 ;;
    *) __fm_cb_value=$((10#$__fm_cb_value)) ;;
  esac
  [ "$__fm_cb_value" -gt 0 ] || __fm_cb_value=$2
  if [ -n "${3-}" ]; then printf -v "$3" '%s' "$__fm_cb_value"; else printf '%s' "$__fm_cb_value"; fi
}

fm_status_cap_bytes() {  # [<out-var>]
  _fm_status_bound_value "${FM_STATUS_CAP_BYTES:-}" "$FM_STATUS_CAP_BYTES_DEFAULT" "${1-}"
}

fm_status_cap_reserve_bytes() {  # [<out-var>]
  _fm_status_bound_value "${FM_STATUS_CAP_RESERVE_BYTES:-}" "$FM_STATUS_CAP_RESERVE_BYTES_DEFAULT" "${1-}"
}

fm_status_window_bytes() {  # [<out-var>]
  if [ -n "${1-}" ]; then printf -v "$1" '%s' "$_FM_STATUS_READ_WINDOW_BYTES"; else printf '%s' "$_FM_STATUS_READ_WINDOW_BYTES"; fi
}

fm_status_read_limit_lines() {  # [<out-var>]
  if [ -n "${1-}" ]; then printf -v "$1" '%s' "$_FM_STATUS_READ_LIMIT_LINES"; else printf '%s' "$_FM_STATUS_READ_LIMIT_LINES"; fi
}

# cap plus reserve. The locals carry the __fm_rl_ prefix for the same reason as above.
fm_status_read_limit_bytes() {  # [<out-var>]
  local __fm_rl_cap __fm_rl_reserve
  fm_status_cap_bytes __fm_rl_cap
  fm_status_cap_reserve_bytes __fm_rl_reserve
  if [ -n "${1-}" ]; then
    printf -v "$1" '%s' "$((__fm_rl_cap + __fm_rl_reserve))"
  else
    printf '%s' "$((__fm_rl_cap + __fm_rl_reserve))"
  fi
}

# 0 when a reader may take <bytes> bytes of <status-file> in one pass, 2 when that is
# past the read limit: one line on stderr then names the file, the span and the
# supported route, and the reader must take nothing. Every reader that needs a log's
# history asks here, so a log past the limit is refused the same way, and named,
# wherever it is read. Status 2 is the refusal and no other failure uses it, so a
# caller can tell "this log cannot be read" from "this log is empty".
fm_status_read_allowed() {  # <status-file> <bytes>
  local __fm_ra_limit
  fm_status_read_limit_bytes __fm_ra_limit
  [ "$2" -le "$__fm_ra_limit" ] && return 0
  echo "fm-status: refused to read ${1##*/}: a span of $2 bytes is past the read limit of $__fm_ra_limit bytes (cap plus reserve); nothing was read and nothing was changed. Read its tail with tail -c, or tear the lane down to retire the log" >&2
  return 2
}

# Print exactly <byte-length> bytes of <status-file> from <start-offset>, or nothing.
# Past the byte limit, and past the line limit unless <max-lines> is 0 (byte limit
# alone), the read is refused: one line on stderr names the file, the span and the
# supported route, nothing is printed, and the status is 2. A span is never clipped, so
# a caller that turns the bytes into a position measures it against the span it asked
# for. Any other failure (a file that cannot be opened or is shorter than asked) is
# status 1 with no message.
fm_status_read_exact() {  # <status-file> <start-offset> <byte-length> [<max-lines>]
  local f=$1 start=$2 length=$3 lines rc=0
  fm_status_read_allowed "$f" "$length" || return 2
  case "${4-}" in
    0) lines=0 ;;
    ''|*[!0-9]*) fm_status_read_limit_lines lines ;;
    *) lines=$4 ;;
  esac
  perl -MFcntl=:DEFAULT -e '
    my ($path, $start, $length, $max_lines) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    sysseek($file, $start, 0) == $start or exit 1;
    my $held = "";
    while ($length > 0) {
      my $want = $length > 65536 ? 65536 : $length;
      my $read = sysread($file, my $chunk, $want);
      defined($read) && $read > 0 or exit 1;
      $length -= $read;
      if ($max_lines > 0) { $held .= $chunk; } else { print $chunk or exit 1; }
    }
    if ($max_lines > 0) {
      exit 3 if ($held =~ tr/\n//) > $max_lines;
      print $held or exit 1;
    }
  ' "$f" "$start" "$length" "$lines" || rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "fm-status: refused to read ${f##*/}: a span of more than $lines lines is past the line-by-line read limit; nothing was read and nothing was changed. Read its tail with tail -c, or tear the lane down to retire the log" >&2
    return 2
  fi
  return "$rc"
}

# One perl program owns the capped append so the size check and the write happen
# under one lock on the log itself. Advisory only: a foreign raw writer ignores
# the lock, which is what the watcher guard exists to catch.
#
# Per line it does one of two things:
#   append    the line is written, unless it would pass the cap. Past the cap only
#             a line whose verb is not working or note may use the reserve; any
#             other line is refused and the program exits 75 after saying so on
#             stderr, naming the file. Nothing is written for a refused line, and
#             a later line in the same call is judged on its own.
#   frame     a log whose last byte is not a newline gets one first, so a torn
#             foreign write cannot glue itself onto a new event.
# stdout stays empty: the exit status and stderr are the whole contract. A repeated
# line is written like any other; the cap is what stops a loop, and it stops it
# loudly.
IFS= command read -r -d '' _FM_STATUS_APPEND_PERL <<'PERL' || :
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock);

my ($path, $cap, $reserve, @lines) = @ARGV;
if (!@lines) { @lines = map { chomp; $_ } <STDIN>; }

sub ends_with_newline {
    my ($handle, $size) = @_;
    my $last = '';
    sysseek($handle, $size - 1, 0);
    sysread($handle, $last, 1);
    return $last eq "\n";
}

sysopen(my $fh, $path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW, 0644)
    or do { print STDERR "fm-status-append: cannot open $path: $!\n"; exit 1 };
flock($fh, LOCK_EX) or do { print STDERR "fm-status-append: cannot lock $path: $!\n"; exit 1 };

my $rc = 0;
for my $line (@lines) {
    my $size = (stat($fh))[7];
    my $frame = ($size > 0 && !ends_with_newline($fh, $size)) ? "\n" : '';
    my $out = $frame . $line . "\n";
    my $terminal = $line !~ /^\s*(?:working|note)\b/;
    my $limit = $terminal ? $cap + $reserve : $cap;
    if ($size + length($out) > $limit) {
        print STDERR "fm-status-append: refused: $path is $size bytes and this line would pass the limit of $limit bytes (cap $cap, reserve $reserve for decision and terminal lines)\n";
        $rc = 75;
        next;
    }
    my $written = syswrite($fh, $out);
    (defined $written && $written == length($out))
        or do { print STDERR "fm-status-append: short write to $path: $!\n"; exit 1 };
}
close($fh);
exit $rc;
PERL

# Append <line>... to <status-file> through the cap above. Each line is one status
# event without its newline. Returns 0 when every line was appended, 75 when a line
# was refused at the cap (stderr names the file), 1 on any other failure.
fm_status_append_lines() {  # <status-file> <line>...
  local file=$1 cap reserve
  shift
  [ "$#" -gt 0 ] || return 0
  fm_status_cap_bytes cap
  fm_status_cap_reserve_bytes reserve
  perl -e "$_FM_STATUS_APPEND_PERL" -- "$file" "$cap" "$reserve" "$@"
}

fm_status_append_line() {  # <status-file> <line>
  fm_status_append_lines "$1" "$2"
}

# The same append for every line of <lines-file>, one event per line, read by the
# writer itself rather than passed on its command line, for a batch too large for one
# command line. Returns as fm_status_append_lines does; an empty file appends nothing.
fm_status_append_file() {  # <status-file> <lines-file>
  local file=$1 cap reserve
  fm_status_cap_bytes cap
  fm_status_cap_reserve_bytes reserve
  perl -e "$_FM_STATUS_APPEND_PERL" -- "$file" "$cap" "$reserve" < "$2"
}

# --- over-cap detection ------------------------------------------------------
#
# The writers above only bound the sanctioned path. A foreign process that opens
# the log itself (a raw `>>` loop, which is how 2026-10-18 happened) is caught here:
# one stat over every status log and per-task sidecar in <state> per watcher poll,
# no other process, and a durable marker per file that records the size at which it
# was last alerted. An existing log is never deleted or rewritten, so a log that
# went over the cap stays over it; detection therefore keys on GROWTH, not on being
# over the cap. A file raises one wake when it first passes the cap and one more each
# time it has grown by more than one cap since its marker, so a writer that is
# resumed after a stop, or a relaunch that appends to the same inode, is caught
# again, and a file that has not grown raises nothing. At most one wake per poll
# covers every file that is due. bin/fm-status-cap-guard.sh turns a row into the wake
# text and the containment; the watcher (bin/fm-watch.sh) owns the wake itself.

# Print "<size>\t<ident>\t<path>" for every status log and sidecar in <state> that
# a bounded reader could meet: state/*.status and the dot-sidecars that carry a
# fold cursor, a span scratch or the home-appends ledger. One stat, no recursion.
fm_status_cap_stat_rows() {  # <state>
  local state=$1
  # Unmatched globs stay literal and make stat report them; stat still prints the
  # rest, so its status is ignored.
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f $'%z\t%d:%i:%B\t%N' \
      "$state"/*.status "$state"/.*open-decisions-cursor* "$state"/.*.home-appends* \
      "$state"/.status-presentation* 2>/dev/null || :
  else
    LC_ALL=C stat -c $'%s\t%d:%i:%W\t%n' \
      "$state"/*.status "$state"/.*open-decisions-cursor* "$state"/.*.home-appends* \
      "$state"/.status-presentation* 2>/dev/null || :
  fi
}

fm_status_cap_marker_path() {  # <state> <path> [<out-var>]
  local __fm_cm_name=${2##*/} __fm_cm_path
  # No _ in the class: it maps to itself, and ShellCheck reads a bare _ inside
  # ${..//[..]/..} as a variable, which flags every caller that loops with `for _`.
  __fm_cm_path="$1/.status-cap-alerted.${__fm_cm_name//[^A-Za-z0-9.-]/_}"
  if [ -n "${3-}" ]; then printf -v "$3" '%s' "$__fm_cm_path"; else printf '%s' "$__fm_cm_path"; fi
}

# Print "<size>\t<ident>\t<path>" for each file over the cap that is due an alert:
# one with no marker for its current identity, or one that has grown by more than one
# cap since the size its marker holds. Delete the markers of files that are gone,
# replaced, or back under the cap so a later episode alarms again. Cheap in the quiet
# case: one stat, plus a read per marker.
fm_status_cap_unalerted() {  # <state>
  local state=$1 cap size ident path marker held_ident held_path held_size
  local rows over_paths=$'\n'
  fm_status_cap_bytes cap
  rows=$(fm_status_cap_stat_rows "$state")
  while IFS=$'\t' read -r size ident path; do
    case "$size" in ''|*[!0-9]*) continue ;; esac
    [ "$size" -gt "$cap" ] || continue
    over_paths="$over_paths$path"$'\t'"$ident"$'\n'
    fm_status_cap_marker_path "$state" "$path" marker
    held_ident='' held_size=''
    if [ -f "$marker" ]; then IFS=$'\t' read -r held_ident held_path held_size < "$marker" || :; fi
    if [ "$held_ident" = "$ident" ]; then
      case "$held_size" in ''|*[!0-9]*) held_size=0 ;; esac
      [ "$size" -gt $((held_size + cap)) ] || continue
    fi
    printf '%s\t%s\t%s\n' "$size" "$ident" "$path"
  done <<EOF
$rows
EOF
  for marker in "$state"/.status-cap-alerted.*; do
    [ -f "$marker" ] || continue
    held_ident='' held_path=''
    IFS=$'\t' read -r held_ident held_path _ < "$marker" || :
    case "$over_paths" in
      *$'\n'"$held_path"$'\t'"$held_ident"$'\n'*) ;;
      *) rm -f -- "$marker" ;;
    esac
  done
}
