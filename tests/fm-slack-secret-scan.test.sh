#!/usr/bin/env bash
# DOD-16: the bot token and the signing secret never reach a tracked file or home runtime state.
# The plane runs with a known token and signing secret (mirror, poll, arm, check, a transport
# failure, and the owner-request intake: arm, a poll, and a standing check that each take in
# a typed request), its stdout and stderr are captured inside the scanned home, and the
# scan then looks for either secret anywhere in tracked files, state, data, and
# config. The scan prints paths and counts only; never a secret or contents.
set -euo pipefail
# Every plane run here is on a transcript; the real transport is closed so none can reach Slack.
export FM_SLACK_NO_NETWORK=1
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v tasks-axi >/dev/null || { printf 'skip: tasks-axi not found\n'; exit 0; }
cd "$ROOT"
TMP=$(fm_test_tmproot fm-slack-secret-scan)
FIX="$ROOT/tests/fixtures/slack"
SECRET=${FM_SLACK_TEST_SECRET:-"fixture-secret-$(date +%s)-$$"}
SIGNING=${FM_SLACK_TEST_SIGNING:-"fixture-signing-$(date +%s)-$$"}
HELPER="$ROOT/tests/fm_slack_watch_test.py"
planted="$ROOT/tests/.fm-slack-secret-planted"
cleanup() { rm -f "$planted"; }
trap cleanup EXIT HUP INT TERM
HOMES=("$TMP/ok" "$TMP/failing" "$TMP/intake")
bash "$FIX/make-home.sh" mirror "${HOMES[0]}" >/dev/null
bash "$FIX/make-home.sh" unreachable "${HOMES[1]}" >/dev/null
bash "$FIX/make-home.sh" intake "${HOMES[2]}" >/dev/null

run_plane() {  # <home> <capture-name> <command> [args...]
  local h=$1 name=$2
  shift 2
  mkdir -p "$h/data/captured"
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" \
    SLACK_BOT_TOKEN="$SECRET" SLACK_SIGNING_SECRET="$SIGNING" "$@" > "$h/data/captured/$name.out" 2> "$h/data/captured/$name.err" || true
}

run_plane "${HOMES[0]}" mirror "$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/mirror/transcript.json"
run_plane "${HOMES[0]}" poll "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/mirror/transcript.json"
run_plane "${HOMES[0]}" arm "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json"
run_plane "${HOMES[0]}" check "$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/mirror/transcript.json"
run_plane "${HOMES[1]}" poll "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/unreachable/transcript.json"

# The owner-request intake: arm, then two typed requests, one taken in by a poll and one by the standing check.
INTAKE="$FIX/intake/transcript.json"
run_plane "${HOMES[2]}" arm "$ROOT/bin/fm-slack-check.sh" arm --replay "$INTAKE"
replay=$(python3 "$HELPER" replay-file "${HOMES[2]}/state/slack-watch")
python3 "$HELPER" owner-message "$replay" 2000.000100 U0TESTOWNER 'a request typed while the plane is armed'
run_plane "${HOMES[2]}" request-poll "$ROOT/bin/fm-slack-poll.sh" --replay "$INTAKE"
python3 "$HELPER" owner-message "$replay" 2000.000200 U0TESTOWNER 'a second request, taken in by the standing check'
run_plane "${HOMES[2]}" request-check "$ROOT/bin/fm-slack-check.sh" check --replay "$INTAKE"

# The scan is only meaningful if the plane really ran with the token.
[ -s "${HOMES[0]}/state/slack-watch/state.json" ] || fail "the plane left no state to scan"
[ -s "${HOMES[0]}/state/slack-watch/outbound.jsonl" ] || fail "the mirror posted nothing"
grep -q '^armed: ' "${HOMES[0]}/data/captured/arm.out" || fail "the arm did not run"
grep -q 'transport failure' "${HOMES[1]}/data/captured/poll.out" || fail "the failure path did not run"
grep -q '^check: slack request 2000.000100 ' "${HOMES[2]}/data/captured/request-poll.out" || fail "the intake poll did not take the request in"
grep -q '^check: slack request 2000.000200 ' "${HOMES[2]}/data/captured/request-check.out" || fail "the intake check did not take the request in"
[ "$(grep -c '"method": "chat.postMessage"' "${HOMES[2]}/state/slack-watch/outbound.jsonl")" = 2 ] || fail "the intake did not acknowledge both requests"

scan() {  # <output-file>; prints matches=N
  FM_SLACK_SCAN_SECRET="$SECRET" FM_SLACK_SCAN_SIGNING="$SIGNING" python3 - "$1" "${HOMES[@]}" <<'PY'
import os, subprocess, sys
out, homes = sys.argv[1], sys.argv[2:]
needles = [os.environ['FM_SLACK_SCAN_SECRET'].encode(), os.environ['FM_SLACK_SCAN_SIGNING'].encode()]
paths = subprocess.check_output(['git', 'ls-files', '-z']).split(b'\0')
paths += [os.path.join(root, name).encode()
          for home in homes
          for part in ('state', 'data', 'config')
          for root, _, names in os.walk(os.path.join(home, part))
          for name in names]
matches = []
for raw in paths:
    if not raw:
        continue
    path = raw.decode(errors='replace')
    if os.path.isfile(path) and any(needle in open(path, 'rb').read() for needle in needles):
        matches.append(path)
with open(out, 'w') as handle:
    for path in matches:
        handle.write('match: ' + path + '\n')
print('matches=' + str(len(matches)))
PY
}
scan "$TMP/clean.out" > "$TMP/clean.count"
[ "$(cat "$TMP/clean.count")" = "matches=0" ] || fail "the token reached a tracked file or home state"

# Planted state copy, inside a longer line.
printf '{"token": "%s"}\n' "$SECRET" > "${HOMES[0]}/state/leak.txt"
scan "$TMP/state.out" > "$TMP/state.count"
[ "$(cat "$TMP/state.count")" = "matches=1" ] || fail "the scan missed a planted state copy"
grep -q "match: ${HOMES[0]}/state/leak.txt" "$TMP/state.out" || fail "the state match was not named"

# Planted tracked copy, using a temporary index so the real index is untouched.
rm -f "${HOMES[0]}/state/leak.txt"
export GIT_INDEX_FILE="$TMP/index"
git read-tree HEAD
printf '%s\n' "$SECRET" > "$planted"
git add -f tests/.fm-slack-secret-planted
scan "$TMP/tracked.out" > "$TMP/tracked.count"
cleanup
unset GIT_INDEX_FILE
[ "$(cat "$TMP/tracked.count")" = "matches=1" ] || fail "the scan missed a planted tracked copy"
grep -q 'tests/.fm-slack-secret-planted' "$TMP/tracked.out" || fail "the tracked match was not named"
[ "$(grep -c "$SECRET" "$TMP/tracked.out" || true)" = 0 ] || fail "the scan printed the literal secret"
printf 'ok - scan redacted and detected both planted copies\n'
