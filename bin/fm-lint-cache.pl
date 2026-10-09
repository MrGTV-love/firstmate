#!/usr/bin/env perl
# fm-lint-cache.pl - private dependency selection and successful-result cache for fm-lint.sh.
# Usage: perl fm-lint-cache.pl select <root> <NUL-separated changes on stdin>
#        perl fm-lint-cache.pl check <cache-dir|off> <root> <shellcheck> <args> -- <file>
# ShellCheck retains source-aware extended analysis; only identical successful checks
# are reused. flock serializes identical misses across worktrees, not unrelated roots.
#
use Cwd qw(abs_path);
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock F_SETFD);
use File::Path qw(make_path);
use File::Basename qw(dirname basename);

# gate mode: hold one host-wide ShellCheck slot while the command runs, so many
# concurrent fm-lint.sh runs queue instead of each adding its own workers.
# Usage: perl fm-lint-cache.pl gate <slot-dir> <ncpu> <wait-file> -- <command...>
# Slots are flock files, so the kernel frees one when its holder dies. The slot
# count is FM_LINT_HOST_SLOTS, else half the cores, but never below two (one
# run's default workers). The full cap is available until 1-minute load exceeds
# two times the cores; only the excess load is subtracted from the cap, down
# to the two-slot floor. A slot directory that cannot be used lets the command
# run ungated. The wait is written in milliseconds to <wait-file> so the caller
# can keep queue time out of its own timings.
if (($ARGV[0] // '') eq 'gate') {
    require POSIX;
    require Time::HiRes;
    my (undef, $slot_dir, $ncpu, $wait_file, $dashes, @command) = @ARGV;
    die "fm-lint-gate: invalid private invocation\n"
        unless defined $dashes && $dashes eq '--' && @command && ($ncpu // '') =~ /\A[1-9][0-9]*\z/;
    my ($child, $caught);
    my %signal_number = (HUP => 1, INT => 2, TERM => 15);
    for my $name (keys %signal_number) {
        $SIG{$name} = sub { $caught = $name; kill 'TERM', $child if $child; };
    }
    my $floor = 2;
    my $cap = ($ENV{FM_LINT_HOST_SLOTS} // '') =~ /\A[1-9][0-9]*\z/ ? $ENV{FM_LINT_HOST_SLOTS} + 0
        : ($ncpu >> 1) > $floor ? ($ncpu >> 1) : $floor;
    $floor = $cap if $cap < $floor;
    my $slot_load = sub {
        return $ENV{FM_LINT_SLOT_LOAD} + 0
            if ($ENV{FM_TEST_SEAM} // '') eq '1' && ($ENV{FM_LINT_SLOT_LOAD} // '') =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
        if (open(my $fh, '<', '/proc/loadavg')) {
            my $line = <$fh>;
            return $1 + 0 if defined $line && $line =~ /\A([0-9]+(?:\.[0-9]+)?)/;
        }
        if (open(my $pipe, '-|', 'sysctl', '-n', 'vm.loadavg')) {
            my $line = <$pipe>;
            close $pipe;
            return $1 + 0 if defined $line && $line =~ /([0-9]+(?:\.[0-9]+)?)/;
        }
        return 0;
    };
    my ($slot, $waited_from);
    my $available = eval { make_path($slot_dir, {mode => 0700}); -d $slot_dir && -w _ };
    if ($available) {
        $waited_from = Time::HiRes::time();
        ACQUIRE: while (!$slot) {
            exit 128 + $signal_number{$caught} if $caught;
            my $allowed = int($cap + 2 * $ncpu - $slot_load->() + 0.5);
            $allowed = $floor if $allowed < $floor;
            $allowed = $cap if $allowed > $cap;
            for my $index (0 .. $allowed - 1) {
                open(my $fh, '>>', "$slot_dir/slot.$index")
                    or do { $available = 0; last ACQUIRE; };
                if (flock($fh, LOCK_EX | LOCK_NB)) { $slot = $fh; last; }
                my $busy = $!{EWOULDBLOCK} || $!{EAGAIN} || $!{EINTR};
                close $fh;
                unless ($busy) { $available = 0; last ACQUIRE; }
            }
            next if $slot || $caught;
            # Every allowed slot is busy: block on one so a freed slot wakes this
            # waiter at once, and re-read the load every two seconds.
            if (open(my $fh, '>>', "$slot_dir/slot.@{[ int(rand($allowed)) ]}")) {
                my $locked = eval {
                    local $SIG{ALRM} = sub { die "gate-recheck\n" };
                    alarm 2;
                    my $got = flock($fh, LOCK_EX);
                    my $interrupted = $!{EINTR};
                    alarm 0;
                    die "gate-lock: $!\n" unless $got || $interrupted;
                    $got;
                };
                alarm 0;
                my $error = $@;
                if ($locked) { $slot = $fh; } else { close $fh; }
                if ($error && $error ne "gate-recheck\n") { $available = 0; last ACQUIRE; }
            } else {
                $available = 0;
                last ACQUIRE;
            }
        }
    }
    if ($slot && !defined fcntl($slot, F_SETFD, 0)) {
        close $slot;
        undef $slot;
        $available = 0;
    }
    unless ($available) {
        warn "fm-lint: host slot directory unavailable; running without the host-wide ShellCheck bound\n";
    }
    if (open(my $fh, '>', $wait_file)) {
        printf {$fh} "%d\n", $waited_from ? (Time::HiRes::time() - $waited_from) * 1000 : 0;
        close $fh;
    }
    exit 128 + $signal_number{$caught} if $caught;
    $child = fork();
    die "fm-lint-gate: fork: $!\n" unless defined $child;
    if (!$child) {
        exec {$command[0]} @command;
        warn "fm-lint-gate: exec $command[0]: $!\n";
        POSIX::_exit(127);
    }
    kill 'TERM', $child if $caught;
    my $reaped;
    while (($reaped = waitpid($child, 0)) == -1 && $!{EINTR}) { }
    my $status = $reaped == $child ? $? : 127 << 8;
    exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
}

my ($mode, $root, @args) = @ARGV;
my $cache;
if (defined $mode && $mode eq 'check') {
    $cache = $root;
    $root = shift @args;
}
die "fm-lint-cache: invalid private invocation\n" unless defined $root && ($mode eq 'select' || $mode eq 'check');
chdir $root or die "fm-lint-cache: chdir $root: $!\n";
my @inventory = sort map { glob $_ } qw(bin/*.sh bin/backends/*.sh tests/*.sh);
my @source_candidates = @inventory;
my (%text, %edges, %unknown);
sub contents {
    my ($path) = @_;
    return $text{$path} if exists $text{$path};
    open my $fh, '<', $path or return $text{$path} = undef;
    local $/;
    return $text{$path} = <$fh>;
}
sub identity_path {
    my ($path) = @_;
    my $absolute = abs_path($path);
    if (!defined $absolute) {
        my $parent = abs_path(dirname($path));
        $absolute = "$parent/" . basename($path) if defined $parent;
    }
    return $path unless defined $absolute;
    $absolute =~ s{^\Q$root\E/}{};
    return $absolute;
}
sub balanced_text {
    my ($body, $position, $open, $close, $subs) = @_;
    my $start = $$position;
    my $depth = 1;
    while ($$position < length $body) {
        my $char = substr($body, $$position, 1);
        if ($char eq $open) { $depth++; $$position++; next; }
        if ($char eq $close) {
            $$position++;
            return substr($body, $start, $$position - $start - 1) if --$depth == 0;
            next;
        }
        if ($char =~ /[\s;&|<>]/) { $$position++; next; }
        if ($char eq '#' && $open eq '(') {
            my $end = index($body, "\n", $$position);
            $$position = $end < 0 ? length($body) : $end;
            next;
        }
        my $before = $$position;
        my $word = shell_word($body, $position, {}, $close);
        push @$subs, @{$word->{subs}} if defined $subs;
        $$position++ if $$position == $before;
    }
    return substr($body, $start);
}
sub shell_word {
    my ($body, $position, $parameters, $stop, $literal) = @_;
    my ($value, $quote, @subs) = ('', '');
    my $raw_start = $$position;
    while ($$position < length $body) {
        my $char = substr($body, $$position, 1);
        last if !$quote && defined $stop && $char eq $stop;
        last if !$quote && $char =~ /[\s;&|<>()]/ && substr($body, $$position, 2) !~ /^[<>]\(/;
        if (!$quote && $char eq "'") {
            my $end = index($body, "'", $$position + 1);
            $end = length $body if $end < 0;
            $value .= substr($body, $$position + 1, $end - $$position - 1);
            $$position = $end < length($body) ? $end + 1 : $end;
            next;
        }
        if ($char eq '"') { $quote = $quote ? '' : '"'; $$position++; next; }
        if ($char eq '\\') {
            my $next = substr($body, $$position + 1, 1);
            $value .= '\\' if $quote && $next !~ /[\$`"\\\n]/;
            $value .= $next unless $next eq "\n";
            $$position += 2;
            next;
        }
        if (substr($body, $$position, 2) eq '$(' || (!$quote && substr($body, $$position, 2) =~ /^[<>]\(/)) {
            my $start = $$position;
            $$position += 2;
            my $program = balanced_text($body, $position, '(', ')');
            push @subs, $program unless $literal || $program =~ /^\(/;
            $value .= $literal ? substr($body, $start, $$position - $start) : "\x01";
            next;
        }
        if ($char eq '`') {
            my $start = $$position;
            $$position++;
            my $program = '';
            while ($$position < length $body) {
                my $part = substr($body, $$position++, 1);
                last if $part eq '`';
                if ($part eq '\\' && substr($body, $$position, 1) =~ /[\$`\\]/) {
                    $part = substr($body, $$position++, 1);
                }
                $program .= $part;
            }
            push @subs, $program unless $literal;
            $value .= $literal ? substr($body, $start, $$position - $start) : "\x01";
            next;
        }
        if ($char eq '$' && !$literal) {
            pos($body) = $$position;
            if ($body =~ /\G\$(?:\{([0-9]+)\}|([0-9]))/gc) {
                my $number = defined $1 ? $1 : $2;
                $$position = pos($body);
                $value .= exists $parameters->{$number} ? $parameters->{$number} : "\x01";
                next;
            }
            if ($body =~ /\G\$(?:[A-Za-z_]\w*|[?!#*@-])/gc) {
                $$position = pos($body);
                $value .= "\x01";
                next;
            }
            if (substr($body, $$position, 2) eq '${') {
                $$position += 2;
                balanced_text($body, $position, '{', '}', \@subs);
                $value .= "\x01";
                next;
            }
        }
        $value .= $char;
        $$position++;
    }
    return {value => $value, raw => substr($body, $raw_start, $$position - $raw_start), subs => \@subs};
}
sub source_dependency {
    my ($path, $word, $deps, $finite_backend) = @_;
    unless (defined $word) { $unknown{$path} = 1; return; }
    my $source = $word->{value};
    return if $source eq '/dev/null';
    if ($source =~ m{^\x01(/[^\x01\$`*?\[\\<>&|'"]+)\z}) {
        my $suffix = $1;
        $deps->{".$suffix"} = 1;
        $deps->{dirname($path) . $suffix} = 1;
        my ($base) = $source =~ m{([^/]+)$};
        $deps->{$_} = 1 for grep { m{(?:^|/)\Q$base\E$} } @source_candidates;
    } elsif ($source ne '' && $source !~ /[\x01\$`*?\[\\<>&|'"]/ && $source !~ /^-/) {
        $source =~ s{^\./}{};
        $deps->{$source} = 1;
    } else {
        return if $finite_backend && ($word->{raw} eq '"$adapter"' || $word->{raw} eq '$adapter');
        $unknown{$path} = 1;
    }
}
sub command_dependencies {
    my ($path, $words, $deps, $finite_backend, $stdin) = @_;
    my @words = @$words;
    while (@words) {
        my $raw = $words[0]{raw} // $words[0]{value};
        $raw =~ s/\\\n//g;
        last unless $raw =~ /^(?:if|then|elif|else|while|until|do|!|time)$/ || $raw =~ /^[A-Za-z_]\w*=/;
        my $prefix = shift @words;
        shift @words if $prefix->{value} eq 'time' && @words && $words[0]{value} eq '-p';
    }
    return unless @words;
    my $command = shift @words;
    if ($command->{value} =~ /^(?:builtin|command)$/ && @words && $words[0]{value} =~ /^(?:source|\.)$/) {
        $unknown{$path} = 1;
        shift @words;
        source_dependency($path, $words[0], $deps, $finite_backend);
    } elsif ($command->{value} =~ /^(?:source|\.)$/) {
        source_dependency($path, $words[0], $deps, $finite_backend);
    } else {
        while ($command->{value} =~ /^(?:exec|command|env)$/ && @words) {
            shift @words while @words && ($words[0]{value} =~ /^-/ || $words[0]{value} =~ /^[A-Za-z_]\w*=/);
            return unless @words;
            $command = shift @words;
        }
        return unless $command->{value} =~ m{(?:^|/)(?:bash|sh)$};
        my $stdin_mode = 0;
        while (@words && $words[0]{value} =~ /^[-+]/) {
            my $option = shift @words;
            if ($option->{value} eq '-') { $stdin_mode = 1; last; }
            last if $option->{value} eq '--';
            if ($option->{value} =~ /^-[A-Za-z]*c[A-Za-z]*$/) {
                my $payload = shift @words;
                return unless defined $payload;
                if ($payload->{value} =~ /\x01/) { $unknown{$path} = 1; return; }
                my %child_parameters;
                $child_parameters{$_} = $words[$_]{value} for 0 .. $#words;
                scan_program($path, $payload->{value}, $deps, $finite_backend, \%child_parameters);
                return;
            }
            $stdin_mode = 1 if $option->{value} =~ /^-[A-Za-z]*s[A-Za-z]*$/;
            shift @words if $option->{value} =~ /^(?:[-+][oO]|--rcfile|--init-file)$/;
        }
        if (!$stdin_mode && @words && $words[0]{value} eq '-') { $stdin_mode = 1; shift @words; }
        return unless defined $stdin && ($stdin_mode || !@words);
        my %child_parameters;
        $child_parameters{$_ + 1} = $words[$_]{value} for 0 .. $#words;
        $stdin->{parameters} = \%child_parameters;
    }
}
sub scan_program {
    my ($path, $body, $deps, $finite_backend, $parameters) = @_;
    my ($position, @words, @heredocs, @cases, $stdin);
    $position = 0;
    while ($position < length $body) {
        pos($body) = $position;
        if ($body =~ /\G(?:[ \t\r]+|\\\n)/gc) { $position = pos($body); next; }
        if ($body =~ /\G(#[^\n]*)/gc) {
            my $comment = $1;
            $position = pos($body);
            if ($comment =~ /^#\s*shellcheck\s+.*?\bsource=(?:"([^"]+)"|'([^']+)'|([^\s]+))/) {
                my $source = defined $1 ? $1 : defined $2 ? $2 : $3;
                $deps->{$source} = 1 unless $source eq '/dev/null';
            }
            $unknown{$path} = 1 if $comment =~ /^#\s*shellcheck\s+.*\bsource-path=/;
            next;
        }
        if (substr($body, $position, 2) eq '[[' || substr($body, $position, 2) eq '((') {
            my $close = substr($body, $position, 2) eq '[[' ? ']]' : '))';
            $position += 2;
            while ($position < length($body) && substr($body, $position, 2) ne $close) {
                if (substr($body, $position, 1) =~ /[\s;&|<>()]/) { $position++; next; }
                my $word = shell_word($body, \$position, $parameters);
                scan_program($path, $_, $deps, $finite_backend, $parameters) for @{$word->{subs}};
            }
            $position += 2;
            push @words, {value => 'test'};
            next;
        }
        if (substr($body, $position, 2) !~ /^[<>]\(/ && $body =~ /\G((?:[0-9]+)?(?:<<<|<<-|<<|>>|<&|>&|<>|>|<)|&>)/gc) {
            my $operator = $1;
            $position = pos($body);
            $position++ while substr($body, $position, 1) =~ /[ \t]/;
            my $heredoc = $operator =~ /^(?:[0-9]+)?<<-?$/;
            my $target = shell_word($body, \$position, $parameters, undef, $heredoc);
            scan_program($path, $_, $deps, $finite_backend, $parameters) for @{$target->{subs}};
            my $input = $operator =~ /^(?:0)?</;
            $stdin = undef if $input;
            if ($heredoc) {
                my $record = {
                    delimiter => $target->{value},
                    tabs => scalar($operator =~ /<<-/),
                    quoted => scalar($target->{raw} =~ /['"\\]/),
                };
                push @heredocs, $record;
                $stdin = $record if $input;
            }
            next;
        }
        if ($body =~ /\G([\n;(){}|&])/gc) {
            my $separator = $1;
            $position = pos($body);
            if (@cases && $cases[-1] eq 'pattern') {
                $cases[-1] = 'body' if $separator eq ')';
            } else {
                command_dependencies($path, \@words, $deps, $finite_backend, $stdin);
                $cases[-1] = 'pattern' if @cases && $separator eq ';' && substr($body, $position, 1) =~ /[;&]/;
            }
            @words = ();
            $stdin = undef;
            if ($separator eq "\n") {
                for my $heredoc (@heredocs) {
                    my $program = '';
                    while ($position < length $body) {
                        my $end = index($body, "\n", $position);
                        $end = length $body if $end < 0;
                        my $line = substr($body, $position, $end - $position);
                        $position = $end < length($body) ? $end + 1 : $end;
                        $line =~ s/^\t+// if $heredoc->{tabs};
                        last if $line eq $heredoc->{delimiter};
                        $program .= "$line\n" if exists $heredoc->{parameters};
                    }
                    if (exists $heredoc->{parameters}) {
                        my $child_parameters = $heredoc->{quoted} ? $heredoc->{parameters} : $parameters;
                        $unknown{$path} = 1 if !$heredoc->{quoted} && $program =~ /[\$`]/;
                        scan_program($path, $program, $deps, $finite_backend, $child_parameters);
                    }
                }
                @heredocs = ();
            }
            next;
        }
        my $word = shell_word($body, \$position, $parameters);
        scan_program($path, $_, $deps, $finite_backend, $parameters) for @{$word->{subs}};
        if (!@words && $word->{raw} eq 'case') { push @cases, 'header'; next; }
        if (@cases && $cases[-1] eq 'header') { $cases[-1] = 'pattern' if $word->{raw} eq 'in'; next; }
        if (@cases && $word->{raw} eq 'esac' && !@words) { pop @cases; next; }
        next if @cases && $cases[-1] eq 'pattern';
        push @words, $word;
    }
    command_dependencies($path, \@words, $deps, $finite_backend, $stdin);
}
sub dependencies {
    my ($path) = @_;
    return @{$edges{$path}} if exists $edges{$path};
    my $body = contents($path);
    my %deps;
    my $finite_backend = identity_path($path) eq 'bin/fm-backend.sh';
    if ($finite_backend) {
        $deps{"bin/backends/$_.sh"} = 1 for qw(tmux herdr zellij orca cmux);
    }
    if (defined $body) {
        scan_program($path, $body, \%deps, $finite_backend, {});
    }
    return @{$edges{$path} = [sort map { identity_path($_) } keys %deps]};
}
sub closure {
    my ($path, $seen) = @_;
    return if $seen->{$path}++;
    closure($_, $seen) for dependencies($path);
}
if ($mode eq 'select') {
    local $/ = "\0";
    my %changed;
    while (<STDIN>) { chomp; s{^\./}{}; $changed{$_} = 1; }
    push @source_candidates, keys %changed;
    my $policy_changed = grep { $changed{$_} } qw(bin/fm-lint.sh bin/fm-lint-cache.pl);
    my (%selected, %closures, %inputs);
    for my $path (@inventory) {
        my %seen;
        closure($path, \%seen);
        $closures{$path} = \%seen;
        $inputs{$_} = 1 for keys %seen;
    }
    my $source_changed = grep { $inputs{$_} || /\.sh\z/ } keys %changed;
    for my $path (@inventory) {
        my $seen = $closures{$path};
        $selected{$path} = 1 if $policy_changed || $changed{$path}
            || (grep { $changed{$_} } keys %$seen)
            || ($source_changed && (grep { $unknown{$_} } keys %$seen));
    }
    print "$_\0" for grep { $selected{$_} } @inventory;
    exit 0;
}
my $tool = shift @args;
my $path = $args[-1];
die "fm-lint-cache: missing analysis command\n" unless defined $path && defined $tool;
$path = identity_path($path);
sub fingerprint {
    %text = (); %edges = (); %unknown = ();
    return undef unless defined contents($tool);
    my %seen;
    closure($path, \%seen);
    return undef if grep { $unknown{$_} } keys %seen;
    my @key_args = map { my $arg = $_; $arg =~ s{^\Q$root\E/}{}; $arg } @args;
    my @parts = ('fm-lint-cache-v1', $^O, @key_args);
    $seen{$_} = 1 for ($tool, 'bin/fm-lint.sh', 'bin/fm-lint-cache.pl');
    for my $name (sort keys %seen) {
        my $body = contents($name);
        push @parts, $name eq $tool ? 'shellcheck-binary' : $name,
            defined $body ? sha256_hex($body) : 'missing';
    }
    return sha256_hex(join "\0", @parts);
}
my $key = $cache eq 'off' ? undef : fingerprint();
my ($lock, $passed);
if (defined $key) {
    # An unavailable cache is an optimization failure, not a lint failure.
    if (eval { make_path($cache, {mode => 0700}); 1 }
        && open($lock, '>>', "$cache/$key.lock") && flock($lock, LOCK_EX)) {
        $passed = "$cache/$key.passed";
        my $locked_key = fingerprint();
        if (!defined $locked_key || $locked_key ne $key) {
            close $lock;
            undef $key;
        }
        if (defined $key && open(my $fh, '<', $passed)) {
            my $record = <$fh>;
            close $fh;
            if (defined $record && $record eq "$key\n") {
                print STDERR "fm-lint: cache hit $path\n";
                exit 0;
            }
        }
    } else {
        warn "fm-lint: cache unavailable; checking $path\n";
        undef $key;
    }
}
my $status = system {$tool} $tool, @args;
my $rc = $status == -1 ? 127 : ($status & 127) ? 128 + ($status & 127) : $status >> 8;
if ($rc == 0 && defined $key) {
    my $after = fingerprint();
    if (defined $after && $after eq $key && open(my $fh, '>', $passed)) {
        print {$fh} "$key\n";
        close $fh;
    }
}
exit $rc;
