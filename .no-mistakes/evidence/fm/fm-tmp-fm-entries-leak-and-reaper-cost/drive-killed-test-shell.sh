#!/usr/bin/env bash
# A test shell sources tests/lib.sh, makes a fixture root named NOT fm-test-* (fm-scratch-leaks.*),
# starts a disowned stray in it, and is KILLed (no trap runs). Then a plain new test shell
# (narrow sweep, no FM_TEST_SWEEP_ALL) sources tests/lib.sh. The stray must be stopped; the root
# is removed once it is past the age floor (backdated here to prove the removal path).
set -u
WT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/nm-drive-kshell.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir "$T/tmp"
env -u FM_TEST_SWEEP_ALL TMPDIR="$T/tmp" bash -c '
  . "$1/tests/lib.sh"
  r=$(fm_test_tmproot fm-scratch-leaks)
  ( cd "$r" && exec perl -e "sleep 300" ) </dev/null >/dev/null 2>&1 & disown
  echo $! > "$2/stray.pid"; echo "$r" > "$2/root"
  kill -KILL $$' _ "$WT" "$T" >/dev/null 2>&1
R=$(cat "$T/root"); P=$(cat "$T/stray.pid")
echo "after KILL: root exists=$([ -d "$R" ] && echo yes || echo no), stray alive=$(kill -0 "$P" 2>/dev/null && echo yes || echo no)"
echo "temp dir: $(ls -A "$T/tmp" | tr '\n' ' ')"
env -u FM_TEST_SWEEP_ALL TMPDIR="$T/tmp" bash -c '. "$1/tests/lib.sh"' _ "$WT" >/dev/null 2>&1
sleep 0.5
echo "after 1st new test shell: stray alive=$(kill -0 "$P" 2>/dev/null && echo yes || echo no), root exists=$([ -d "$R" ] && echo yes || echo no) (root is younger than the age floor)"
find "$T/tmp" -name .fm-test-fixture -exec touch -t 202601010000 {} + ; touch -t 202601010000 "$R"
find "$T/tmp/fm-test-owners" -mindepth 1 -exec touch -t 202601010000 {} + 2>/dev/null
env -u FM_TEST_SWEEP_ALL TMPDIR="$T/tmp" bash -c '. "$1/tests/lib.sh"' _ "$WT" >/dev/null 2>&1
echo "after markers backdated past the floor + 2nd new test shell: root exists=$([ -d "$R" ] && echo yes || echo no)"
echo "temp dir: $(ls -A "$T/tmp" | tr '\n' ' ') ; owner records: $(ls -A "$T/tmp/fm-test-owners" 2>/dev/null | wc -l | tr -d ' ')"
kill "$P" 2>/dev/null; true
