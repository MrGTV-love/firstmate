package FakeClock;
# Fixture only: a perl module that DRIVES time for the one process under test, so that a wait whose length is counted in retries (the
# unbind's) reaches its end without real waiting AND the time it would have taken can be read. The virtual clock starts at a fixed instant;
# the four-argument select and sleep advance it by the time they were asked to wait and return at once; time, Time::HiRes::time,
# Time::HiRes::sleep, usleep and gettimeofday read it. With FM_FAKE_CLOCK_LOG set, every line the process writes to standard error is
# also appended there as `vt=<virtual seconds since the start>\t<line>`, and an `end` line closes the record. The code under test is unchanged
# and its own constants are not touched.
use strict;
use warnings;
our $start = 1_000_000_000.0;
our $now = $start;

sub advance {
  my ($seconds) = @_;
  $now += $seconds if defined $seconds && $seconds > 0;
}

sub note {
  my ($text) = @_;
  my $path = $ENV{FM_FAKE_CLOCK_LOG};
  return unless defined $path && length $path;
  if (open(my $log, '>>', $path)) {
    printf $log "vt=%.1f\t%s", $now - $start, $text;
    close $log;
  }
}

BEGIN {
  no warnings 'redefine';
  *CORE::GLOBAL::select = sub {
    if (@_ == 4) { advance($_[3]); return 0 }
    return CORE::select($_[0]) if @_ == 1;
    return CORE::select($_[0], $_[1], $_[2], $_[3]);
  };
  *CORE::GLOBAL::sleep = sub { my $seconds = defined $_[0] ? $_[0] : 0; advance($seconds); return int($seconds) };
  *CORE::GLOBAL::time = sub () { return int($now) };
  require Time::HiRes;
  *Time::HiRes::time = sub () { return $now };
  *Time::HiRes::sleep = sub (;@) { advance($_[0]); return $_[0] };
  *Time::HiRes::usleep = sub ($) { advance($_[0] / 1e6); return $_[0] };
  *Time::HiRes::nanosleep = sub ($) { advance($_[0] / 1e9); return $_[0] };
  *Time::HiRes::gettimeofday = sub () { return wantarray ? (int($now), int(($now - int($now)) * 1e6)) : $now };
}

package FakeClock::Stderr;
sub TIEHANDLE { my ($class) = @_; open(my $copy, '>&', \*STDERR) or die "FakeClock: cannot copy standard error"; return bless { fh => $copy }, $class }
sub PRINT { my $self = shift; my $text = join(defined $, ? $, : '', @_); my $fh = $self->{fh}; print $fh $text; FakeClock::note($text); return 1 }
sub PRINTF { my $self = shift; my $text = sprintf(shift, @_); my $fh = $self->{fh}; print $fh $text; FakeClock::note($text); return 1 }

package FakeClock;
tie *STDERR, 'FakeClock::Stderr';
END { FakeClock::note("end\n") }
1;
