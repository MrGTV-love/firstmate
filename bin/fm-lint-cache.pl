#!/usr/bin/env perl
# fm-lint-cache.pl - private dependency selection and successful-result cache for fm-lint.sh.
# Usage: perl fm-lint-cache.pl select <root> <NUL-separated changes on stdin>
#        perl fm-lint-cache.pl check <cache-dir|off> <root> <shellcheck> <args> -- <file>
# ShellCheck retains source-aware extended analysis; only identical successful checks
# are reused. flock serializes identical misses across worktrees, not unrelated roots.
# Unknown source forms disable reuse and conservatively select the root on changes.
#
use Cwd qw(abs_path);
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock);
use File::Path qw(make_path);

my ($mode, $root, @args) = @ARGV;
my $cache;
if (defined $mode && $mode eq 'check') {
    $cache = $root;
    $root = shift @args;
}
die "fm-lint-cache: invalid private invocation\n" unless defined $root && ($mode eq 'select' || $mode eq 'check');
chdir $root or die "fm-lint-cache: chdir $root: $!\n";
my @inventory = sort map { glob $_ } qw(bin/*.sh bin/backends/*.sh tests/*.sh);
my (%text, %edges, %unknown);
# ShellCheck recognizes escaped keywords and backslash-newline continuations.
my $source_command = qr/(?:\\\n)*(?:\\?s(?:\\\n)*\\?o(?:\\\n)*\\?u(?:\\\n)*\\?r(?:\\\n)*\\?c(?:\\\n)*\\?e|\\?\.)(?:\\\n)*/;
my $prefix_word = qr/(?:"(?:\\.|[^"\\])*"|'[^']*'|\$\([^)]*\)|\\(?:.|\n)|[^\s;()<>"'\\])+/;
my $command_prefix = qr/(?:(?:if|then|elif|else|while|until|do|!|time(?:\s+-p)?|[A-Za-z_]\w*=$prefix_word|\d*(?:>>?|<<?|<&|>&|&>)\s*$prefix_word)\s+)*/;
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
    return $path unless defined $absolute;
    $absolute =~ s{^\Q$root\E/}{};
    return $absolute;
}
sub dependencies {
    my ($path) = @_;
    return @{$edges{$path}} if exists $edges{$path};
    my $body = contents($path);
    my %deps;
    if (defined $body) {
        # Include every override, even one in a nested function or comment. This
        # deliberately over-selects rather than relying on shell execution order.
        while ($body =~ /^\s*#\s*shellcheck\s+[^\n]*?\bsource=(?:"([^"]+)"|'([^']+)'|([^\s]+))/mg) {
            my $source = defined $1 ? $1 : defined $2 ? $2 : $3;
            $deps{$source} = 1 unless $source eq '/dev/null';
        }
        # ShellCheck can resolve a literal source or strip one dynamic directory
        # prefix ($dir/file -> ./file). Track both that path and repository-local
        # basename candidates for runtime reverse-dependency selection.
        my %recognized_sources;
        while ($body =~ /(?:^\s*|[;({)]\s*|(?:&&|\|\|)\s*)$command_prefix($source_command)(?=\s|[<>]|&>)\s*(?:"([^"\n]+)"|'([^'\n]+)'|([^\s;\n]+))/mg) {
            my $source = defined $2 ? $2 : defined $3 ? $3 : $4;
            my $offset = $-[1];
            $recognized_sources{$offset} = 1;
            my $word_end = $+[0];
            my $prefix = substr($body, 0, $offset);
            my $has_override = $prefix =~ /(?:^|\n)\s*#\s*shellcheck[^\n]*\bsource=[^\n]+(?:\n|\z)(?:\s*#[^\n]*\n)*\s*\z/;
            if ($word_end < length($body) && substr($body, $word_end, 1) !~ /[\s;#&|(){}<>]/) {
                $unknown{$path} = 1 unless $has_override;
                next;
            }
            my $line_prefix = substr($body, 0, $offset);
            $line_prefix =~ s/.*\n//s;
            next if $line_prefix =~ /^\s*#/;
            next if $source eq '/dev/null';
            if ($source =~ /^\$/ && $source =~ m#^\$(?:[A-Za-z_]\w*|[0-9]|\{[^}]+\}|\([^)]*\))(/[^\$`*?\[\\<>&|'"]+)\z#) {
                $deps{".$1"} = 1;
                my ($base) = $source =~ m{([^/]+)$};
                $deps{$_} = 1 for grep { m{(?:^|/)\Q$base\E$} } @inventory;
            } elsif ($source !~ /[\$`*?\[\\<>&|'"]/ && $source !~ /^-/) {
                $source =~ s{^\./}{};
                $deps{$source} = 1;
            } else {
                next if $has_override;
                # A bare variable has no literal filename for ShellCheck to
                # follow. It therefore contributes no external analysis input.
                next if $source =~ /^\$(?:[A-Za-z_]\w*|[0-9]|\{[^}]+\})\z/;
                # Other unresolved word shapes and custom search paths may add
                # inputs we cannot prove; select conservatively and do not cache.
                $unknown{$path} = 1;
            }
        }
        # A keyword-shaped source command outside the supported grammar may
        # still import analysis inputs. Never let an unparsed command authorize
        # reuse or hide its caller when repository inputs change. The required
        # token boundaries exclude case dot patterns such as ''|.|.. .
        while ($body =~ /(?:^|[\s;({)&|<>])($source_command)(?=\s|[<>]|&>)/mg) {
            next if $recognized_sources{$-[1]};
            my $line_prefix = substr($body, 0, $-[1]);
            $line_prefix =~ s/.*\n//s;
            next if $line_prefix =~ /^\s*#/;
            # Declaration arguments and comments after a function opener are
            # not commands. In particular, a local variable named "source"
            # must not disable reuse for every root importing that library.
            # Reject substitution/operator syntax here rather than mistaking
            # a source command inside an assignment for a declaration argument.
            next if $line_prefix =~ /^\s*(?:local|declare|typeset|readonly|export)(?:\s+(?:-[A-Za-z]+|[A-Za-z_]\w*(?:=[^\s;()<>|&`"']*)?))*\s+\z/;
            next if $line_prefix =~ /^\s*[A-Za-z_]\w*\(\)\s*\{\s*#/;
            $unknown{$path} = 1;
        }
        $unknown{$path} = 1 if $body =~ /^\s*#\s*shellcheck\s+[^\n]*\bsource-path=/m;
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
    my $policy_changed = grep { $changed{$_} } qw(bin/fm-lint.sh bin/fm-lint-cache.pl);
    my $inputs_changed = scalar keys %changed;
    my %selected;
    for my $path (@inventory) {
        my %seen;
        closure($path, \%seen);
        $selected{$path} = 1 if $policy_changed || $changed{$path}
            || grep { $changed{$_} || ($unknown{$_} && $inputs_changed) } keys %seen;
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
