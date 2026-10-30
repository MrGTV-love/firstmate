#!/usr/bin/env bash
# Live drive: the real runner bin/fm-test-run.sh in a fresh TMPDIR that holds
# what a KILLed test left (a record, a fixture root and a stray process with its
# cwd inside that root), an old-layout registry of a dead shell, and unrelated
# fm-* entries. One runner start must stop the stray, remove the record, root
# and registry, keep everything unrelated, and leave nothing new behind.
set -u
WT=$1; SB=$(mktemp -d /tmp/fmnm-s6.XXXXXX); SB=$(cd -P "$SB" && pwd -P); T=$SB/t; mkdir -p "$T"; LIB=$WT/tests/lib.sh
for i in 1 2 3; do mkdir "$T/fm-gh-rest.UNREL$i"; : > "$T/fm-timeout-status.UNREL$i"; done
mkdir "$T/fm-gh-rest.scratch"; : > "$T/fm-gh-rest.scratch/1.LIVEXX"
env TMPDIR="$T" bash -c '. "$1"; d=$(fm_test_tmproot fm-test-killed); printf "%s\n" "$d" > "$2"; (cd "$d" && exec sleep 300) >/dev/null 2>&1 & printf "%s\n" "$!" > "$3"; kill -KILL $$' _ "$LIB" "$SB/root" "$SB/stray" >/dev/null 2>&1
root=$(cat "$SB/root"); stray=$(cat "$SB/stray"); rec=$(dirname "$(grep -l . "$T"/fm-test-owners/*/.fm-test-fixture | head -1)")
dead=99999; while kill -0 $dead 2>/dev/null; do dead=$((dead-1)); done
: > "$T/.fm-test-cleanup.$dead.AbCdEf"
find "$T" -name .fm-test-fixture -exec touch -t 202001010000 {} \; ; touch -t 202001010000 "$T/.fm-test-cleanup.$dead.AbCdEf"
echo "before: stray pid $stray alive=$(kill -0 $stray 2>/dev/null && echo yes || echo no) cwd=$(lsof -a -p $stray -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sed "s#$SB#<SB>#")"
echo "before: top of TMPDIR:"; ls -1A "$T" | sed 's/^/  /'
echo "--- runner: bin/fm-test-run.sh tests/fm-scratch-legacy-reap.test.sh"
env -u FM_TEST_SLOT_DIR -u FM_PROCEVENT_CLAIM_ROOT -u FM_TEST_DROP_WORDS TMPDIR="$T" "$WT/bin/fm-test-run.sh" tests/fm-scratch-legacy-reap.test.sh > "$SB/run.log" 2>&1; echo "runner rc=$?"; tail -3 "$SB/run.log" | sed "s#$SB#<SB>#g"
st() { [ -e "$1" ] && echo kept || echo removed; }
echo "after: stray process alive=$(kill -0 $stray 2>/dev/null && echo yes || echo no) (expect no)"
echo "after: killed shell's root=$(st "$root") record=$(st "$rec") old-layout registry=$(st "$T/.fm-test-cleanup.$dead.AbCdEf") (expect removed x3)"
echo "after: top of TMPDIR:"; ls -1A "$T" | sed 's/^/  /'
echo "after: inside fm-test-owners:"; ls -1A "$T/fm-test-owners" | sed 's/^/  /'
kill $stray 2>/dev/null; rm -rf "$SB"
