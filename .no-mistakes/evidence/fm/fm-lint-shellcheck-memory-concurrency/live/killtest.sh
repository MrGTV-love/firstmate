#!/usr/bin/env bash
# Live driver: a holder run takes the whole budget, a waiter queues, then the
# holder is ended by SIGKILL in two ways. The waiter must start, every root must
# finish, no stand-in stays, and the pool must take a later run.
set -u
WT=$1; S=/tmp/nm-live-01M6/kill; rm -rf "$S"; mkdir -p "$S/bin"
for r in a b c d; do printf '#!/usr/bin/env bash\nexit 0\n' > "$S/$r.sh"; done
cat > "$S/bin/shellcheck" <<PL
#!/usr/bin/env perl
if ((\$ARGV[0] // '') eq '--version') { print "ShellCheck - shell script analysis tool\nversion: 0.11.0\n"; exit 0 }
my \$b = 'x' x (64*1048576);
open(my \$f,'>>','$S/starts'); print {\$f} "\$\$ \$ARGV[-1]\n"; close \$f;
select(undef,undef,undef,\$ENV{HOLD} // 1);
exit 0;
PL
chmod +x "$S/bin/shellcheck"
REALPS=$(command -v ps)
cat > "$S/bin/ps" <<SH
#!/bin/sh
[ "\$*" = '-axo pid=,ppid=,rss=,comm=' ] || exec "$REALPS" "\$@"
"$REALPS" "\$@" | /usr/bin/awk '{ name = \$0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +/, "", name); sub(/ +\$/, "", name); sub(/.*\//, "", name); if (name != "shellcheck") print }'
SH
chmod +x "$S/bin/ps"
L() { env -u NO_MISTAKES_GATE FM_LINT_CACHE_DIR=off FM_LINT_SLOT_DIR="$S/pool" FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=98304 PATH="$S/bin:$PATH" HOLD="$1" "$WT/bin/fm-lint.sh" --jobs 1 "$2"; }
starts() { [ -f "$S/starts" ] && wc -l < "$S/starts" | tr -d ' ' || echo 0; }
wait_starts() { local want=$1 limit=$2 t=$SECONDS; until [ "$(starts)" -ge "$want" ]; do [ $((SECONDS-t)) -lt "$limit" ] || return 1; sleep 0.1; done; echo "$((SECONDS-t))"; }
tree() { local p=$1; echo "$p"; for c in $(pgrep -P "$p" 2>/dev/null); do tree "$c"; done; }

echo "== Case 1: SIGKILL the holder's whole process tree"
L 120 "$S/a.sh" > "$S/1a.out" 2>&1 & A=$!
wait_starts 1 30 >/dev/null || echo "holder did not start"
L 1 "$S/b.sh" > "$S/1b.out" 2>&1 & B=$!
sleep 3; echo "starts while holder lives (expect 1): $(starts)"
kill -KILL $(tree "$A") 2>/dev/null
w=$(wait_starts 2 40) && echo "waiter started $w s after SIGKILL of the tree" || echo "FAIL: waiter stayed queued"
wait "$A" 2>/dev/null; wait "$B"; echo "waiter exit=$?"

echo "== Case 2: SIGKILL only the top-level lint process, its worker tree left to notice"
: > "$S/starts"
L 25 "$S/c.sh" > "$S/2c.out" 2>&1 & A=$!
wait_starts 1 30 >/dev/null || echo "holder did not start"
HOLDER=$(awk '{print $1}' "$S/starts")
L 1 "$S/d.sh" > "$S/2d.out" 2>&1 & B=$!
sleep 3; echo "starts while holder lives (expect 1): $(starts)"
kill -KILL "$A"
w=$(wait_starts 2 60) && echo "waiter started $w s after SIGKILL of the top process" || echo "FAIL: waiter stayed queued"
wait "$A" 2>/dev/null; wait "$B"; echo "waiter exit=$?"
kill -0 "$HOLDER" 2>/dev/null && echo "orphaned stand-in pid $HOLDER still alive after waiter finished" || echo "orphaned stand-in gone"

echo "== Case 3: the pool after both kills"
ls "$S/pool" | grep -c '^queue\.0' | sed 's/^/queue tickets left: /'
: > "$S/starts"; L 0.2 "$S/a.sh" > "$S/3.out" 2>&1; echo "later run exit=$? starts=$(starts)"
