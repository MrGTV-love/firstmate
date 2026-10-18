#!/usr/bin/env bash
# fm-status-cap-lib.sh - the size bounds for append-only task status logs.
# Sourcing this library only defines functions and constants.
#
# A status log (state/<task>.status) and its per-task sidecars are append-only
# records that every supervision reader walks. On 2026-10-18 a shell loop inside
# an agent harness wrote three of them to 140 GB, 265 GB and 122 GB, and every
# reader multiplied the damage. Three numbers bound that, all owned here and
# described for operators in docs/configuration.md "Status log size bounds":
#
#   cap      the byte size a status log may reach through the sanctioned writer
#            (fm_status_append_lines, bin/fm-status-append.sh). The watcher
#            guard (bin/fm-status-cap-guard.sh) also raises its one wake when any
#            status log or sidecar passes it.
#   reserve  headroom above the cap that only a decision or terminal event
#            (anything but working: and note:) may use, so a worker can still
#            report done: or blocked: from a log that is at the cap.
#   window   the most bytes (and, for a log of tiny lines, the most lines) any
#            reader takes from a log in one pass. A larger span is read from its
#            tail, aligned to a line start, and one line on stderr names what was
#            skipped (bin/fm-status-io-lib.sh).
#
# The defaults come from measurement, not guesswork: the largest status log in a
# healthy fleet on 2026-10-18 was 3,230,479 bytes (state/vernant-d7-steward.status).
# The cap is 32 MiB, about ten times that, so only a runaway reaches it. The window
# is 4 MiB and 4096 lines. The byte bound is 1.3 times that log, so it is read whole.
# The line bound is what keeps a flood of tiny lines from costing minutes in a shell
# loop: measured 2026-10-18, about 2.7 ms per line in the watcher's span classifier
# (11 s at 4096 lines) and 0.06 to 1.2 ms per line in the open-decisions fold. A log
# with more than 4096 lines is therefore read from its last 4096 when nothing narrower
# is asked; the longest healthy log has 5,338, and an incremental reader asks for far
# less than that because it starts from its saved position.
# Each can be overridden by the environment for a test or a deliberate site choice;
# a value that is not a positive integer falls back to the default.

FM_STATUS_CAP_BYTES_DEFAULT=33554432
FM_STATUS_CAP_RESERVE_BYTES_DEFAULT=1048576
FM_STATUS_READ_WINDOW_BYTES_DEFAULT=4194304
FM_STATUS_READ_WINDOW_LINES_DEFAULT=4096

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
  _fm_status_bound_value "${FM_STATUS_READ_WINDOW_BYTES:-}" "$FM_STATUS_READ_WINDOW_BYTES_DEFAULT" "${1-}"
}

fm_status_window_lines() {  # [<out-var>]
  _fm_status_bound_value "${FM_STATUS_READ_WINDOW_LINES:-}" "$FM_STATUS_READ_WINDOW_LINES_DEFAULT" "${1-}"
}

# One perl program owns the capped append so the size check, the repeat check and
# the write happen under one lock on the log itself. Advisory only: a foreign raw
# writer ignores the lock, which is what the watcher guard exists to catch.
#
# Per line it does one of three things:
#   append    the line is written, unless it would pass the cap. Past the cap only
#             a line whose verb is not working or note may use the reserve; any
#             other line is refused and the program exits 75 after saying so.
#   collapse  the line equals the last real line (compared without its [at=...]
#             stamp). The log gets ONE counter line after that real line, and each
#             further repeat rewrites that counter line's fixed-width number in
#             place, so a loop of any length adds one line and zero bytes. The
#             count is exact; no repeat is dropped without being counted.
#   frame     a log whose last byte is not a newline gets one first, so a torn
#             foreign write cannot glue itself onto a new event.
# stdout carries one token per input line: appended, collapsed:<count>, or
# refused:<size>. The counter line is a note: event so every reader already
# treats it as informational.
IFS= command read -r -d '' _FM_STATUS_APPEND_PERL <<'PERL' || :
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock);

my ($path, $cap, $reserve, @lines) = @ARGV;
my $window = 65536;
my $max_count = 999999999999;
my $counter_re = qr/^note \[at=\d+\]: \[fm-status-collapsed\] repeats=(\d{12}) /;

# State of the log's tail, kept across the lines of one call while this process is the
# only writer (the lock is held and the size is what the last write left); any other
# size reloads it from a bounded tail read.
my ($cached_size, $real, $real_norm, $counter_pos, $count) = (-1);

sub normalize {
    my ($line) = @_;
    my $colon = index($line, ':');
    return $line if $colon < 0;
    my $head = substr($line, 0, $colon);
    $head =~ s/ ?\[at=\d{1,12}\]//g;
    return $head . substr($line, $colon);
}

sub ends_with_newline {
    my ($handle, $size) = @_;
    my $last = '';
    sysseek($handle, $size - 1, 0);
    sysread($handle, $last, 1);
    return $last eq "\n";
}

# The last real line, and the counter line that may follow it, from a bounded tail.
sub load_state {
    my ($handle, $size) = @_;
    ($real, $real_norm, $counter_pos, $count) = (undef, undef, undef, undef);
    $cached_size = $size;
    return if $size <= 0;
    my $take = $size < $window ? $size : $window;
    my $buf = '';
    sysseek($handle, $size - $take, 0);
    sysread($handle, $buf, $take);
    my $base = $size - $take;
    if ($base > 0) {
        my $nl = index($buf, "\n");
        if ($nl < 0) { $buf = ''; } else { $buf = substr($buf, $nl + 1); $base += $nl + 1; }
    }
    my @rows;
    my $pos = 0;
    while ($pos < length($buf)) {
        my $nl = index($buf, "\n", $pos);
        my $end = $nl < 0 ? length($buf) : $nl;
        my $text = substr($buf, $pos, $end - $pos);
        if ($text =~ /\S/) {
            my $digits_at = $text =~ $counter_re ? $-[1] : undef;
            push @rows, [$base + $pos, $text, $digits_at, $digits_at ? $1 + 0 : undef];
        }
        $pos = $nl < 0 ? length($buf) : $nl + 1;
    }
    return unless @rows;
    my $last = $rows[-1];
    if (defined $last->[2]) {
        $counter_pos = $last->[0] + $last->[2];
        $count = $last->[3];
        $real = $rows[-2][1] if @rows > 1;
    } else {
        $real = $last->[1];
    }
    $real_norm = normalize($real) if defined $real;
}

sysopen(my $fh, $path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW, 0644)
    or do { print STDERR "fm-status-append: cannot open $path: $!\n"; exit 1 };
flock($fh, LOCK_EX) or do { print STDERR "fm-status-append: cannot lock $path: $!\n"; exit 1 };

my $rc = 0;
for my $line (@lines) {
    my $size = (stat($fh))[7];
    load_state($fh, $size) if $size != $cached_size;

    my $norm = normalize($line);
    my $same = defined $real_norm && $norm eq $real_norm;

    if ($same && defined $counter_pos) {
        $count++ if $count < $max_count;
        sysopen(my $w, $path, O_WRONLY | O_NOFOLLOW)
            or do { print STDERR "fm-status-append: cannot reopen $path: $!\n"; exit 1 };
        sysseek($w, $counter_pos, 0);
        syswrite($w, sprintf('%012d', $count));
        close($w);
        print "collapsed:$count\n";
        next;
    }

    my $text = $same
        ? sprintf('note [at=%d]: [fm-status-collapsed] repeats=%012d of the line above (bin/fm-status-append.sh counts exact consecutive repeats in this one line instead of writing each)', time(), 1)
        : $line;
    my $frame = ($size > 0 && !ends_with_newline($fh, $size)) ? "\n" : '';
    my $out = $frame . $text . "\n";
    my $after = $size + length($out);
    my $terminal = $text !~ /^\s*(?:working|note)\b/;
    my $limit = ($terminal || $same) ? $cap + $reserve : $cap;
    if ($after > $limit) {
        print "refused:$size\n";
        print STDERR "fm-status-append: refused: $path is $size bytes and this line would pass the limit of $limit bytes (cap $cap, reserve $reserve for decision and terminal lines)\n";
        $rc = 75;
        next;
    }
    my $written = syswrite($fh, $out);
    (defined $written && $written == length($out))
        or do { print STDERR "fm-status-append: short write to $path: $!\n"; exit 1 };
    $cached_size = $after;
    if ($same) {
        $counter_pos = $size + length($frame) + index($text, 'repeats=') + 8;
        $count = 1;
        print "collapsed:1\n";
    } else {
        ($real, $real_norm, $counter_pos, $count) = ($line, $norm, undef, undef);
        print "appended\n";
    }
}
close($fh);
exit $rc;
PERL

# Append <line>... to <status-file> through the cap and the repeat counter above.
# Each line is one status event without its newline. Returns 0 when every line was
# appended or counted, 75 when a line was refused at the cap, 1 on any other
# failure. stdout carries the per-line tokens (appended, collapsed:<count>,
# refused:<size>); callers that only need the status discard it.
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

# --- over-cap detection ------------------------------------------------------
#
# The writers above only bound the sanctioned path. A foreign process that opens
# the log itself (a raw `>>` loop, which is how 2026-10-18 happened) is caught here:
# one stat over every status log and per-task sidecar in <state> per watcher poll,
# no other process, and a durable marker per episode so exactly ONE wake is raised
# for a file however long it stays over the cap. bin/fm-status-cap-guard.sh turns a
# row into the wake text and the containment; the watcher (bin/fm-watch.sh) owns
# the wake itself.

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
  __fm_cm_path="$1/.status-cap-alerted.${__fm_cm_name//[^A-Za-z0-9._-]/_}"
  if [ -n "${3-}" ]; then printf -v "$3" '%s' "$__fm_cm_path"; else printf '%s' "$__fm_cm_path"; fi
}

# Print "<size>\t<ident>\t<path>" for each file over the cap that has no marker for
# its current identity, and delete the markers of files that are gone, replaced,
# or back under the cap so a later episode alarms again. Cheap in the quiet case:
# one stat, plus a read per marker.
fm_status_cap_unalerted() {  # <state>
  local state=$1 cap size ident path marker held_ident held_path
  local rows over_paths=$'\n'
  fm_status_cap_bytes cap
  rows=$(fm_status_cap_stat_rows "$state")
  while IFS=$'\t' read -r size ident path; do
    case "$size" in ''|*[!0-9]*) continue ;; esac
    [ "$size" -gt "$cap" ] || continue
    over_paths="$over_paths$path"$'\t'"$ident"$'\n'
    fm_status_cap_marker_path "$state" "$path" marker
    held_ident=
    if [ -f "$marker" ]; then IFS=$'\t' read -r held_ident held_path < "$marker" || :; fi
    [ "$held_ident" = "$ident" ] && continue
    printf '%s\t%s\t%s\n' "$size" "$ident" "$path"
  done <<EOF
$rows
EOF
  for marker in "$state"/.status-cap-alerted.*; do
    [ -f "$marker" ] || continue
    held_ident='' held_path=''
    IFS=$'\t' read -r held_ident held_path < "$marker" || :
    case "$over_paths" in
      *$'\n'"$held_path"$'\t'"$held_ident"$'\n'*) ;;
      *) rm -f -- "$marker" ;;
    esac
  done
}
