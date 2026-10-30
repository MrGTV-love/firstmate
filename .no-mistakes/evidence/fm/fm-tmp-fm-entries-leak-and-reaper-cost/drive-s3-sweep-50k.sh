#!/usr/bin/env bash
# Live drive: time and check the orphan sweep that runs when a shell sources
# tests/lib.sh, with 0 and with 50000 unrelated fm-* entries in a fresh TMPDIR.
# Compares the change (target) with the base commit's tests/lib.sh.
set -u
WT=$1 BASE_REV=$2 N=${3:-50000}
SB=$(mktemp -d /tmp/fmnm-s3.XXXXXX); SB=$(cd -P "$SB" && pwd -P)
mkdir -p "$SB/base"; git -C "$WT" archive "$BASE_REV" bin tests | tar -x -C "$SB/base"
make_unrelated() { python3 -I -c '
import os,sys
d,n=sys.argv[1],int(sys.argv[2])
pre=["fm-timeout-status","fm-fleet-tasks","fm-gh-rest","fm-remote-reply-ingest","fm-contributions","fm-session-start-stage","fm-lavish-poll","fm-drop-words"]
for i in range(n):
    p=os.path.join(d,"%s.U%06d"%(pre[i%len(pre)],i))
    if i%2: os.mkdir(p); open(os.path.join(p,"x"),"w").close()
    else: open(p,"w").close()
' "$1" "$2"; }
secs() {  # <lib> <tmpdir> [env...]
  local lib=$1 tmp=$2; shift 2
  perl -MTime::HiRes=time -e '$t=time; system(@ARGV); printf "%.3f\n", time-$t' env TMPDIR="$tmp" "$@" bash -c '. "$1"' _ "$lib"
}
median3() { sort -n | sed -n 2p; }
for side in base target; do
  [ "$side" = base ] && lib="$SB/base/tests/lib.sh" || lib="$WT/tests/lib.sh"
  for n in 0 "$N"; do
    tmp="$SB/$side-$n"; mkdir -p "$tmp"; [ "$n" = 0 ] || make_unrelated "$tmp" "$n"
    secs "$lib" "$tmp" >/dev/null   # warm the cache; on target this also writes the discovery stamp
    if [ "$side" = target ]; then
      wide=$( for i in 1 2 3; do secs "$lib" "$tmp" FM_TEST_SWEEP_ALL=1; done | median3)
      disc=$( for i in 1 2 3; do rm -f "$tmp/fm-test-owners/.legacy-discovery"; secs "$lib" "$tmp"; done | median3)
      stamped=$( for i in 1 2 3; do secs "$lib" "$tmp"; done | median3)
      printf '%-6s unrelated=%-6s ordinary(stamped)=%ss  discovery(stamp cleared)=%ss  wide(FM_TEST_SWEEP_ALL=1)=%ss\n' "$side" "$n" "$stamped" "$disc" "$wide"
    else
      ord=$( for i in 1 2 3; do secs "$lib" "$tmp"; done | median3)
      printf '%-6s unrelated=%-6s ordinary=%ss\n' "$side" "$n" "$ord"
    fi
  done
done
echo "unrelated entries still present after all target sweeps: $(find "$SB/target-$N" -mindepth 1 -maxdepth 1 -name 'fm-*.U*' | wc -l | tr -d ' ') of $N"

echo "=== safety at $N entries (target)"
tmp="$SB/target-$N"; LIB="$WT/tests/lib.sh"
sleep 600 & live=$!
ident() { FM_STATE_OVERRIDE="$tmp" bash -c '. "$1"; fm_pid_identity "$2"' _ "$WT/bin/fm-wake-lib.sh" "$1"; }
dead=99999; while kill -0 $dead 2>/dev/null; do dead=$((dead-1)); done
mkdir -p "$tmp/fm-legacy-dead.AAAAAA" "$tmp/fm-legacy-live.BBBBBB" "$tmp/fm-unmarked-old.CCCCCC"
printf '%s\n%s\n' "$dead" "bogus identity" > "$tmp/fm-legacy-dead.AAAAAA/.fm-test-fixture"
printf '%s\n%s\n' "$live" "$(ident $live)" > "$tmp/fm-legacy-live.BBBBBB/.fm-test-fixture"
echo data > "$tmp/fm-unmarked-old.CCCCCC/file"
# A test shell that made a fixture root and was then KILLed (KILL runs no trap).
env TMPDIR="$tmp" bash -c '. "$1"; d=$(fm_test_tmproot fm-test-killed); printf "%s\n" "$d" > "$2"; kill -KILL $$' _ "$LIB" "$SB/killed-root" >/dev/null 2>&1
killed_root=$(cat "$SB/killed-root"); killed_rec=$(grep -l "^$(cat "$killed_root/.fm-test-fixture" | head -1)\$" "$tmp"/fm-test-owners/*/.fm-test-fixture | head -1); killed_rec=${killed_rec%/.fm-test-fixture}
find "$tmp" -maxdepth 1 \( -name 'fm-legacy-*' -o -name 'fm-unmarked-old*' -o -name 'fm-test-killed*' \) -exec touch -t 202001010000 {} \;
find "$tmp" -maxdepth 3 -name .fm-test-fixture -path '*fm-test-owners*' -exec touch -t 202001010000 {} \;
find "$tmp" -maxdepth 2 -name .fm-test-fixture \( -path '*fm-legacy-*' -o -path '*fm-test-killed*' \) -exec touch -t 202001010000 {} \;
rm -f "$tmp/fm-test-owners/.legacy-discovery"
echo "before: dead-owner legacy root=$( [ -e "$tmp/fm-legacy-dead.AAAAAA" ] && echo present) live-owner root=$( [ -e "$tmp/fm-legacy-live.BBBBBB" ] && echo present) unmarked=$( [ -e "$tmp/fm-unmarked-old.CCCCCC" ] && echo present) killed-shell root=$( [ -e "$killed_root" ] && echo present) killed-shell record=$( [ -e "$killed_rec" ] && echo present)"
t=$(secs "$LIB" "$tmp")
st() { [ -e "$1" ] && echo kept || echo removed; }
echo "one ordinary sourcing at $N entries took ${t}s"
echo "after:  dead-owner legacy root=$(st "$tmp/fm-legacy-dead.AAAAAA") (expect removed)"
echo "        live-owner old root=$(st "$tmp/fm-legacy-live.BBBBBB") (expect kept)"
echo "        unmarked old fm-* entry=$(st "$tmp/fm-unmarked-old.CCCCCC") (expect kept)"
echo "        KILLed shell's fixture root=$(st "$killed_root") (expect removed)"
echo "        KILLed shell's record=$(st "$killed_rec") (expect removed)"
echo "        unrelated entries=$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'fm-*.U*' | wc -l | tr -d ' ') of $N (expect $N)"
kill $live; wait $live 2>/dev/null
rm -rf "$SB"
