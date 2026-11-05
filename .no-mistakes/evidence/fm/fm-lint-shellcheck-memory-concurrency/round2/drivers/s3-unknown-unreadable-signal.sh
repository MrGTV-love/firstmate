#!/usr/bin/env bash
# Unknown slot record, unreadable process table, signalled gate: each charged the worst case. Each has a control.
. "$(dirname "$0")/lib.sh"
S=/tmp/nm-r2/s3; rm -rf "$S"; mkdir -p "$S/bin"; BIN=$S/bin; standin "$BIN" "$S/spans"
CAP=262144; R=$S/roots; mkdir -p "$R"; for r in h w x cut ctl; do root "$R/$r.sh"; done
export FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=$CAP MIB=8
P=$S/pool; export FM_LINT_SLOT_DIR=$P
echo "# seed records for h.sh and w.sh in a roomy pool"
FM_LINT_HOST_RSS_KIB=100000000 HOLD=0.2 L --jobs 1 "$R/h.sh" "$R/w.sh" >/dev/null 2>&1; echo "seed exit=$?"
for r in h w; do echo "record $r.sh: $(cat "$P/history/$(hkey "full:$R/$r.sh")" 2>/dev/null) KiB"; done
BUDGET=$CAP   # two recorded roots fit; a worst-case charge plus a recorded root does not
export FM_LINT_HOST_RSS_KIB=$BUDGET
hold_slot() { # <pool> <slot file content, %d is the holder pid>: perl keeps the flock until the release file appears
  perl -e 'use Fcntl qw(:flock); my($f,$c,$rel)=@ARGV; open(my $h,">>",$f) or die; flock($h,LOCK_EX) or die; $c=~s/%d/$$/; print {$h} $c; $h->flush; until(-e $rel){select(undef,undef,undef,0.05)}' "$1/slot.0" "$2" "$S/release" &
  HP=$!; sleep 0.3; }
echo; echo "## unknown record in a held slot"
echo "# control: the held slot names a small charge, so a recorded root joins"
rm -f "$S/release"; : > "$P/slot.0"; hold_slot "$P" $'ctl\t1\t%d\t2000\n'
: > "$S/spans.starts"; HOLD=0.2 L --jobs 1 "$R/w.sh" > "$S/c1.out" 2>&1 & W=$!
if wait_count "$S/spans.starts" 1 8; then echo "control: root started beside a named small charge (expected)"; else echo "control FAIL: root did not start"; fi
: > "$S/release"; wait "$W"; echo "control exit=$?"; wait "$HP" 2>/dev/null
echo "# case: the held slot holds garbage, so it is charged the worst case and the root waits"
rm -f "$S/release"; : > "$P/slot.0"; hold_slot "$P" "garbage without a tab"$'\n'
: > "$S/spans.starts"; HOLD=0.2 L --jobs 1 "$R/w.sh" > "$S/c2.out" 2>&1 & W=$!
sleep 4; echo "starts after 4 s beside a garbage slot (expect 0): $(count "$S/spans.starts")"
: > "$S/release"; wait_count "$S/spans.starts" 1 20 && echo "root started after the holder ended (expected)" || echo "FAIL: root stayed queued"
wait "$W"; echo "root exit=$?"; wait "$HP" 2>/dev/null; : > "$P/slot.0"
echo; echo "## unreadable process table"
A=$S/arch; mkdir -p "$A"; git -C "$WT" archive HEAD | tar -x -C "$A"
rm -f "$A/bin/fm-proc-info.py"
( cd "$A" && git init -q -b main . && git add -A >/dev/null && git -c user.name=lab -c user.email=lab@example.invalid commit -q -m lab --no-verify )
for side in readable unreadable; do
  B2=$S/bin.$side; cp -R "$BIN" "$B2"
  [ "$side" = unreadable ] && { printf '#!/bin/sh\nexit 1\n' > "$B2/ps"; chmod +x "$B2/ps"; }
  : > "$S/spans.starts"; : > "$S/spans"
  ( BIN=$B2 LINT=$A/bin/fm-lint.sh HOLD=5 L --jobs 1 "$R/h.sh" > "$S/t.$side.h.out" 2>&1 ) & H=$!
  wait_count "$S/spans.starts" 1 20 || echo "$side holder did not start"
  ( BIN=$B2 LINT=$A/bin/fm-lint.sh HOLD=0.2 L --jobs 1 "$R/w.sh" > "$S/t.$side.w.out" 2>&1 ) & W=$!
  sleep 3; echo "$side table (no fm-proc-info.py): starts 3 s after a recorded second root asked: $(count "$S/spans.starts") (expect readable=2, unreadable=1)"
  wait "$H"; rh=$?; wait "$W"; rw=$?
  echo "$side: holder exit=$rh second root exit=$rw roots finished=$(count "$S/spans")/2"
  [ "$rh" = 0 ] && [ "$rw" = 0 ] || sed -n 1,5p "$S/t.$side.w.out"
done
echo; echo "## signalled gate leaves no record, a complete run does"
m=$(hkey "full:$R/cut.sh"); c=$(hkey "full:$R/ctl.sh")
FM_LINT_HOST_RSS_KIB=100000000 HOLD=0.1 L --jobs 1 "$R/ctl.sh" >/dev/null 2>&1; echo "control, complete run: record=$(cat "$P/history/$c" 2>/dev/null || echo none)"
: > "$S/spans.starts"
FM_LINT_HOST_RSS_KIB=100000000 HOLD=30 L --jobs 1 "$R/cut.sh" > "$S/cut.out" 2>&1 & C=$!
wait_count "$S/spans.starts" 1 20 || echo "signalled root did not start"
G=$(pgrep -f "fm-lint-cache.pl gate $P" | head -1); echo "gate pid found: ${G:+yes}"; kill -TERM "$G"; wait "$C"; echo "lint exit after TERM of the gate=$?"
echo "signalled run: record=$(cat "$P/history/$m" 2>/dev/null || echo none) (expect none)"
echo "# next request of that root is charged the worst case: it waits beside a recorded holder, where the recorded control joined"
: > "$S/spans.starts"; : > "$S/spans"
HOLD=5 L --jobs 1 "$R/h.sh" > "$S/s.h.out" 2>&1 & H=$!
wait_count "$S/spans.starts" 1 20
HOLD=0.2 L --jobs 1 "$R/cut.sh" > "$S/s.c.out" 2>&1 & W=$!
sleep 3; echo "starts 3 s after the signalled root asked again beside a recorded holder (expect 1): $(count "$S/spans.starts")"
wait "$H"; wait "$W"; echo "that root exit=$? roots finished=$(count "$S/spans")/2 most at once=$(most "$S/spans")"
