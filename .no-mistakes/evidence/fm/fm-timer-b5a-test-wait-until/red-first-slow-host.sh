#!/usr/bin/env bash
# Usage: slow-host.sh <lib.sh> <old|new> <dilation> <cap>
# A publisher does 20 journaled steps of 0.2s*dilation, then publishes.
# At 1x it takes ~4s; a 5x-slowed host makes it ~20s. Old helper caps at <cap>s.
set -u
LIB=$1 MODE=$2 DIL=$3 CAP=$4
:
. "$LIB"
T=$(mktemp -d /tmp/fm-b5a-pub.XXXX); FM_TEST_TMPDIR=$T; export FM_TEST_TMPDIR
python3 -c '
import pathlib, sys, time
j, r, d = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
for s in range(20):
    time.sleep(0.2 * d); j.write_text(str(s))
r.write_text("published")
' "$T/journal" "$T/result" "$DIL" &
pub=$!
start=$(date +%s)
if [ "$MODE" = old ]; then
  fm_test_wait_until "$CAP" test -s "$T/result"; rc=$?
else
  fm_test_wait_until --while-alive "$pub" --progress-file "$T/journal" -- test -s "$T/result"; rc=$?
fi
el=$(( $(date +%s) - start ))
kill "$pub" 2>/dev/null; wait "$pub" 2>/dev/null
echo "helper=$MODE dilation=${DIL}x cap=${CAP}s wait_rc=$rc elapsed=${el}s published=$([ -s "$T/result" ] && echo yes || echo no-yet)"
rm -rf "$T"
