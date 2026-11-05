# Shared by the round 2 live drivers: stand-in analysis, ps shim, small helpers.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6MC9FAZ2R279RGXAGWCSZK4
REALPS=$(command -v ps)
hide_ps() { # hide other lanes' real shellcheck from the gate's table, as the suite does
cat > "$1/ps" <<SH
#!/bin/sh
[ "\$*" = '-axo pid=,ppid=,rss=,comm=' ] || exec "$REALPS" "\$@"
"$REALPS" "\$@" | /usr/bin/awk '{ name = \$0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +/, "", name); sub(/ +\$/, "", name); sub(/.*\//, "", name); if (name != "shellcheck") print }'
SH
chmod +x "$1/ps"; }
standin() { # <bin> <spans file>; MiB and hold come from the environment
cat > "$1/shellcheck" <<PL
#!/usr/bin/env perl
use Time::HiRes qw(time);
if ((\$ARGV[0] // '') eq '--version') { print "ShellCheck - shell script analysis tool\nversion: 0.11.0\n"; exit 0 }
select(undef,undef,undef,\$ENV{DELAY} // 0);
my \$b = 'x' x ((\$ENV{MIB} // 64)*1048576);
my \$t = time();
open(my \$s,'>>','$2.starts'); print {\$s} "\$\$ \$ARGV[-1]\n"; close \$s;
select(undef,undef,undef,\$ENV{HOLD} // 1);
open(my \$f,'>>','$2'); printf {\$f} "%d %.6f %.6f %s\n", \$\$, \$t, time(), \$ARGV[-1]; close \$f;
exit(length(\$b) ? 0 : 1);
PL
chmod +x "$1/shellcheck"; hide_ps "$1"; }
root() { printf '#!/usr/bin/env bash\nexit 0\n' > "$1"; }
most() { perl -ane 'push @e,[$F[1],1],[$F[2],-1]; END{my($n,$m)=(0,0); for(sort{$a->[0]<=>$b->[0]||$a->[1]<=>$b->[1]}@e){$n+=$_->[1];$m=$n if $n>$m} print "$m\n"}' "$1"; }
count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
wait_count() { local f=$1 want=$2 limit=$3 t=$SECONDS; until [ "$(count "$f")" -ge "$want" ]; do [ $((SECONDS-t)) -lt "$limit" ] || return 1; sleep 0.1; done; }
hkey() { perl -MDigest::SHA=sha256_hex -e 'print sha256_hex($ARGV[0])' "$1"; }
L() { env -u NO_MISTAKES_GATE -u FM_LINT_REQUIRE_BOUNDS CI= GITHUB_ACTIONS= FM_LINT_CACHE_DIR="${CACHE:-off}" PATH="$BIN:$PATH" "${LINT:-$WT/bin/fm-lint.sh}" "$@"; }
