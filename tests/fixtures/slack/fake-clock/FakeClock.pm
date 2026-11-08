package FakeClock;
# Fixture only: a perl module that makes the four-argument select and sleep return at once, so that a wait
# which counts retries (as the unbind's does) reaches its end without real waiting. The code under test is
# unchanged and its own constant is not touched.
use strict;
use warnings;
BEGIN {
  *CORE::GLOBAL::select = sub {
    return 0 if @_ == 4;
    return CORE::select($_[0]) if @_ == 1;
    return CORE::select($_[0], $_[1], $_[2], $_[3]);
  };
  *CORE::GLOBAL::sleep = sub { return $_[0] };
}
1;
