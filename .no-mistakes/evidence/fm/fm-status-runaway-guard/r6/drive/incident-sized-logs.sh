#!/usr/bin/env bash
# incident-sized-logs.sh <repo> <lab>
# Three sparse lane logs at the incident's sizes (140, 265, 122 GB; real blocks a few KB) left in place, then the
# real helper, guard, and readers run against them. Nothing may be deleted, truncated or rewritten.
REPO=$1; LAB=$2; ST=$LAB/state; export FM_HOME="$LAB"
mkdir -p "$ST"
mk() { # name bytes
  F=$ST/$1.status
  printf 'working [at=1]: head event\ndecision [at=2]: first decision\n' > "$F"
  perl -e 'my ($f,$n)=@ARGV; open(my $h,"+<",$f) or die; truncate($h,$n) or die; seek($h,$n-9,0); print $h "text\ntext\n"; close $h' "$F" "$2"
}
mk lane-a 140000000000; mk lane-b 265000000000; mk lane-c 122000000000
echo "du (real blocks) of state dir: $(du -sk "$ST" | cut -f1) KiB"
for n in a b c; do F=$ST/lane-$n.status; printf '%s size=%s head_sha=%s mtime=%s\n' "$n" "$(stat -f %z "$F")" "$(head -c 60 "$F" | shasum | cut -c1-12)" "$(stat -f %m "$F")"; done > "$LAB/before.txt"
cat "$LAB/before.txt"
echo "--- 1. the sanctioned helper on each: refuses, exit 75, names the file, a done: line too"
for n in a b c; do
  F=$ST/lane-$n.status
  out=$("$REPO/bin/fm-status-append.sh" "$F" "done [at=3]: finished" 2>&1); rc=$?
  echo "lane-$n append rc=$rc msg=$(printf '%s' "$out" | cut -c1-150)"
done
echo "--- 2. the guard scan (nothing holds them open): names each, stops nothing, deletes nothing"
FM_STATE_OVERRIDE="$ST" timeout 60 "$REPO/bin/fm-status-cap-guard.sh" scan 2>&1 | cut -f1,3,4 | sed "s#$LAB#<lab>#g" | cut -c1-330
echo "--- 3. readers on the same logs, each with a 60 s timeout"
t() { local s=$SECONDS; "$@" > "$LAB/r.out" 2> "$LAB/r.err"; local rc=$?; echo "   rc=$rc secs=$((SECONDS-s)) out=$(head -c 120 "$LAB/r.out" | tr '\n' '|') err=$(head -c 160 "$LAB/r.err" | tr '\n' '|')"; }
FM_STATE_OVERRIDE="$ST" FM_CONFIG_OVERRIDE="$LAB/config" t timeout 60 "$REPO/bin/fm-wake-drain.sh"
FM_STATE_OVERRIDE="$ST" FM_CONFIG_OVERRIDE="$LAB/config" t timeout 60 "$REPO/bin/fm-fleet-snapshot.sh"
echo "--- 4. after"
for n in a b c; do F=$ST/lane-$n.status; printf '%s size=%s head_sha=%s mtime=%s\n' "$n" "$(stat -f %z "$F")" "$(head -c 60 "$F" | shasum | cut -c1-12)" "$(stat -f %m "$F")"; done > "$LAB/after.txt"
cat "$LAB/after.txt"; cmp "$LAB/before.txt" "$LAB/after.txt" && echo "IDENTICAL: nothing deleted, truncated or rewritten"
echo "big files created beside the logs: $(find "$ST" -type f -size +1048576c ! -name '*.status' | wc -l | tr -d ' ')"
