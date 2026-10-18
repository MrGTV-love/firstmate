#!/usr/bin/env bash
# Scenario P: three simultaneous real bin/fm-test-run.sh runs of one script, default slot limit 2.
set -u
ROOT=$1; EV=$2
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-runner-lab.XXXXXX"); echo "$S" > "$EV/.plab"
mkdir -p "$S/repo/bin" "$S/repo/tests"
for f in bin/fm-test-run.sh bin/fm-duration-lib.sh bin/fm-duration.py bin/fm-timeout-lib.sh tests/git-config-helpers.sh; do cp "$ROOT/$f" "$S/repo/$f"; done
printf 'echo heavy-start\nsleep 6\necho heavy-end\n' > "$S/repo/tests/fm-heavy.test.sh"
git -C "$S/repo" init -q 2>/dev/null
export FM_TEST_SLOT_DIR=$S/slots FM_DURATION_FILE=$S/durations.jsonl
unset FM_TEST_KEY_SLOTS FM_TEST_SLOT_WAIT_SECONDS NO_MISTAKES_GATE
echo "### Scenario P: 3 simultaneous 'bin/fm-test-run.sh tests/fm-heavy.test.sh' (script sleeps 6s), default limit 2"
t0=$(date +%s)
for i in 1 2 3; do
  ( cd "$S/repo" && ./bin/fm-test-run.sh tests/fm-heavy.test.sh > "$S/run$i.out" 2> "$S/run$i.err"; echo "exit=$?" >> "$S/run$i.out" ) &
  sleep 0.5
done
wait
echo "all three finished in $(( $(date +%s) - t0 ))s (serial would be ~18s+, two-at-a-time ~12s)"
for i in 1 2 3; do
  echo "--- run $i: $(grep -h 'FM_TEST_END' "$S/run$i.out" | sed 's/[0-9T:-]\{19\}Z\? //') ; $(grep -h FM_TEST_SUMMARY "$S/run$i.out")"
  grep -h "fm-duration:" "$S/run$i.err" | sed 's/^/    stderr: /'
done
echo "--- recorded samples:"
python3 - "$S/durations.jsonl" <<'PY'
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if 'event' in r: continue
    print(" ", r['key'], "duration_ms=%s" % r['duration_ms'], "load_start=%s" % r.get('load_start'), "load_end=%s" % r.get('load_end'))
PY
