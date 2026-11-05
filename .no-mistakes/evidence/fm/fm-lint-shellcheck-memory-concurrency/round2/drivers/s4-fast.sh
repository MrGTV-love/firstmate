#!/usr/bin/env bash
# A --fast record never lowers the full charge.
. "$(dirname "$0")/lib.sh"
S=/tmp/nm-r2/s4; rm -rf "$S"; mkdir -p "$S/bin"; BIN=$S/bin; standin "$BIN" "$S/spans"
for r in a b; do root "$S/$r.sh"; done
CAP=262144; P=$S/pool; export FM_LINT_SLOT_DIR=$P FM_LINT_ROOT_RSS_KIB=$CAP MIB=1 HOLD=0.1
L --fast --jobs 1 "$S/a.sh" > "$S/fast.out" 2>&1; echo "fast run exit=$?"
f=$P/history/$(hkey "fast:$S/a.sh"); u=$P/history/$(hkey "full:$S/a.sh")
echo "history for fast:a.sh = $(cat "$f" 2>/dev/null || echo none) KiB"; echo "history for full:a.sh = $(cat "$u" 2>/dev/null || echo none) (expect none)"
rec=$(cat "$f"); export FM_LINT_HOST_RSS_KIB=$((CAP + rec * 2))
: > "$S/spans.starts"
HOLD=25 L --jobs 1 "$S/b.sh" > "$S/h.out" 2>&1 & H=$!
wait_count "$S/spans.starts" 1 20 || echo "holder did not start"
HOLD=0.1 L --fast --jobs 1 "$S/a.sh" > "$S/f2.out" 2>&1; echo "fast request beside an unrecorded holder: exit=$? starts=$(count "$S/spans.starts") (expect 2, it joins)"
HOLD=0.1 L --jobs 1 "$S/a.sh" > "$S/full.out" 2>&1 & W=$!
sleep 4; echo "starts 4 s after a full request of the same root (expect still 2, it waits): $(count "$S/spans.starts")"
kill -TERM "$H"; wait "$H" 2>/dev/null; wait "$W"; echo "full request exit=$? after the holder ended; starts=$(count "$S/spans.starts")"
echo "history for full:a.sh after its own run: $(cat "$u" 2>/dev/null || echo none) KiB"
