#!/usr/bin/env bash
# Second driver: the registered check file that the watcher runs, the per-poll cap and order,
# a failed history read, and a failed acknowledgement post. Real CLI, replay transcripts, no socket.
# Usage: drive-intake-2.sh <worktree>
set -uo pipefail
ROOT=${1:?worktree}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-intake-drive2.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FIX="$ROOT/tests/fixtures/slack"
HELPER="$ROOT/tests/fm_slack_watch_test.py"
INTAKE="$FIX/intake/transcript.json"
PASS=0; FAILN=0
ok() { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAILN=$((FAILN+1)); printf '  FAIL: %s\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3 (= $2)"; else bad "$3: expected [$2] got [$1]"; fi; }
has() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3: missing [$2]"; fi; }
hasnt() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3: found [$2]"; else ok "$3"; fi; }
show() { printf '  stdout> %s\n' "${1:-<empty>}"; }
home() {
  HOME_DIR=$(mktemp -d "$TMP/home.XXXXXX")
  bash "$FIX/make-home.sh" "$1" "$HOME_DIR" >/dev/null
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
}
log() { printf '%s/slack-watch/outbound.jsonl' "$FM_STATE_OVERRIDE"; }
posts() { python3 "$HELPER" outbound-count "$(log)" chat.postMessage "${1:-}"; }
woken() { printf '%s\n' "$1" | sed -n 's/^check: slack request \([0-9.]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }
# A transcript with the given owner messages after the pre-arm one, plus extra top-level keys.
transcript() {  # <out> <messages-json> [key json]...
  local out=$1 msgs=$2; shift 2
  python3 "$HELPER" set-transcript "$INTAKE" "$out" messages "$msgs"
  while [ "$#" -ge 2 ]; do python3 "$HELPER" set-transcript "$out" "$out" "$1" "$2"; shift 2; done
}

echo "## T1 the registered check file (state/slack.check.sh) that fm-watch.sh runs is registered and runs the check path (not executed: it has no replay)"
home intake
T="$TMP/t1.json"; transcript "$T" '[{"ts":"100.000100","user":"U0TESTOWNER","text":"old"}]'
"$ROOT/bin/fm-slack-check.sh" arm --replay "$T" | sed 's/^/  arm> /'
printf '  check file> %s\n' "$(grep -v '^#' "$FM_STATE_OVERRIDE/slack.check.sh" | grep . | tr '\n' ' ')"
reg=$(bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"; fm_custom_check_registered "$2" slack && echo registered' _ "$ROOT" "$FM_STATE_OVERRIDE")
check "$reg" registered "the check is registered and its trust hash matches (fm_custom_check_registered)"
body=$(grep -v '^#' "$FM_STATE_OVERRIDE/slack.check.sh" | grep .)
has "$body" "$ROOT/bin/fm-slack-check.sh check" "the registered check runs fm-slack-check.sh check (the S2 path)"
hasnt "$body" "--replay" "the registered check carries no --replay (it would call real Slack, so it is not executed here)"

echo "## T2 several requests: oldest first, within FM_SLACK_POLL_MAX_ANSWERS=2, rest wait, none skipped or repeated"
home intake
T="$TMP/t2.json"; transcript "$T" '[{"ts":"100.000100","user":"U0TESTOWNER","text":"old"}]'
"$ROOT/bin/fm-slack-check.sh" arm --replay "$T" >/dev/null
R=$(python3 "$HELPER" replay-file "$FM_STATE_OVERRIDE/slack-watch")
for n in 1 2 3; do python3 "$HELPER" owner-message "$R" "2000.00010$n" U0TESTOWNER "request number $n"; done
o1=$(FM_SLACK_POLL_MAX_ANSWERS=2 "$ROOT/bin/fm-slack-poll.sh" --replay "$T"); show "$o1"
check "$(woken "$o1")" "2000.000101 2000.000102" "poll 1 wakes the two oldest in order"
check "$(posts)" 2 "poll 1 posts two acknowledgements"
o2=$(FM_SLACK_POLL_MAX_ANSWERS=2 "$ROOT/bin/fm-slack-poll.sh" --replay "$T"); show "$o2"
check "$(woken "$o2")" "2000.000103" "poll 2 wakes the third"
for n in 1 2 3; do check "$(posts 2000.00010$n)" 1 "one acknowledgement in thread 2000.00010$n"; done
o3=$(FM_SLACK_POLL_MAX_ANSWERS=2 "$ROOT/bin/fm-slack-poll.sh" --replay "$T"); check "$o3" "" "poll 3 silent"

echo "## T3 history read fails once (503): reported once, nothing woken; next poll takes the request in"
home intake
T="$TMP/t3.json"; transcript "$T" '[{"ts":"100.000100","user":"U0TESTOWNER","text":"old"}]'
"$ROOT/bin/fm-slack-check.sh" arm --replay "$T" >/dev/null
R=$(python3 "$HELPER" replay-file "$FM_STATE_OVERRIDE/slack-watch")
python3 "$HELPER" owner-message "$R" 2000.000100 U0TESTOWNER 'request during an outage'
python3 - "$R" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['failures'] = {'conversations.history': {'times': 1, 'status': 503}}
json.dump(d, open(p, 'w'))
PY
o1=$("$ROOT/bin/fm-slack-poll.sh" --replay "$T" 2>&1); rc=$?; show "$o1 (rc=$rc)"
has "$o1" 'transport failure: unreachable' "the read error is reported as a transport failure"
hasnt "$o1" 'check: slack request' "nothing woken during the failure"
check "$(posts)" 0 "nothing posted during the failure"
o2=$("$ROOT/bin/fm-slack-poll.sh" --replay "$T" 2>&1); show "$o2"
check "$(woken "$o2")" 2000.000100 "next poll takes the request in"
check "$(posts 2000.000100)" 1 "acknowledged once"

echo "## T4 acknowledgement post fails once (503): no loss, no duplicate; later poll acks once and wakes"
home intake
T="$TMP/t4.json"; transcript "$T" '[{"ts":"100.000100","user":"U0TESTOWNER","text":"old"}]'
"$ROOT/bin/fm-slack-check.sh" arm --replay "$T" >/dev/null
R=$(python3 "$HELPER" replay-file "$FM_STATE_OVERRIDE/slack-watch")
python3 "$HELPER" owner-message "$R" 2000.000100 U0TESTOWNER 'request whose ack fails'
python3 - "$R" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['failures'] = {'chat.postMessage': {'times': 1, 'status': 503}}
json.dump(d, open(p, 'w'))
PY
o1=$("$ROOT/bin/fm-slack-poll.sh" --replay "$T" 2>&1); rc=$?; show "$o1 (rc=$rc)"
check "$(posts)" 0 "no acknowledgement recorded on the failed post"
o2=$("$ROOT/bin/fm-slack-poll.sh" --replay "$T" 2>&1); show "$o2"
o3=$("$ROOT/bin/fm-slack-poll.sh" --replay "$T" 2>&1); show "$o3"
n=$(printf '%s\n%s\n%s\n' "$o1" "$o2" "$o3" | grep -c '^check: slack request 2000.000100' || true)
if [ "$n" -ge 1 ]; then ok "request woken $n time(s) across the three runs"; else bad "request never woken"; fi
check "$(posts 2000.000100)" 1 "exactly one acknowledgement in the thread"

printf '\nRESULT: %d pass, %d fail\n' "$PASS" "$FAILN"
[ "$FAILN" = 0 ]
