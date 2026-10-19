#!/usr/bin/env bash
# S2: unconfigured = off and silent; explicit arm names refusals on stderr; arm/check/disarm life cycle
#     under the watcher's custom-check contract (trust + snapshot + 30s bound + stderr discarded).
set -uo pipefail
. "$(dirname "$0")/lab.sh"
FAILED=0
lab_start || exit 1
trap lab_stop EXIT

# Run the armed check the way bin/fm-watch.sh does: trust-checked snapshot, FM_CHECK_TIMEOUT bound, stderr dropped.
watcher_run_check() {
  ( . "$REPO/bin/fm-pr-lib.sh"; . "$REPO/bin/fm-check-lib.sh"
    fm_custom_check_snapshot_prepare "$FM_STATE_OVERRIDE" slack || { echo "WATCHER-REJECTED-CHECK"; exit 0; }
    out=$(timeout 30 bash "$FM_CUSTOM_CHECK_SNAPSHOT" 2>/dev/null); rc=$?
    fm_custom_check_snapshot_cleanup
    printf '%s' "$out"; exit 0 )
}

step "S2.1 no token: poll, mirror, check all silent, exit 0, zero network, no state created"
new_home allowlist
printf 'FM_SLACK_DM_USER=%s\nFM_SLACK_ALLOWED_AUTHORS=%s\n' "$OWNER" "$OWNER" > "$FM_HOME/.env"
before=$(requests_total)
for c in "poll" "mirror"; do out=$($c 2>&1); rc=$?; expect_eq "$rc/$out" "0/" "$c with no token: rc/stdout+stderr"; done
out=$("$REPO/bin/fm-slack-check.sh" check 2>&1); rc=$?; expect_eq "$rc/$out" "0/" "check with no token"
expect_eq "$(requests_total)" "$before" "no request reached the server"
[ ! -e "$FM_STATE_OVERRIDE/slack-watch" ] && ok "no state/slack-watch created" || bad "state dir created while off"

step "S2.2 token set, allowlist empty: still off and silent (the 'unconfigured' rule)"
new_home allowlist
printf 'SLACK_BOT_TOKEN=%s\nFM_SLACK_DM_USER=%s\nFM_SLACK_ALLOWED_AUTHORS=\n' "$FAKE_TOKEN" "$OWNER" > "$FM_HOME/.env"
before=$(requests_total)
out=$(poll 2>&1); rc=$?; echo "poll output: [$out] rc=$rc"
expect_eq "$rc" 0 "poll rc with empty allowlist"
expect_eq "$(requests_total)" "$before" "no request with empty allowlist"
[ ! -e "$FM_STATE_OVERRIDE/slack-watch" ] && ok "no state created" || bad "state created"

step "S2.3 explicit arm while unconfigured: stderr names the refusal, stdout empty, rc!=0, nothing registered"
new_home allowlist
printf 'FM_SLACK_DM_USER=%s\n' "$OWNER" > "$FM_HOME/.env"
so=$("$REPO/bin/fm-slack-check.sh" arm 2>"$LABROOT/err"); rc=$?
echo "stdout=[$so] stderr=[$(cat "$LABROOT/err")] rc=$rc"
expect_eq "$so" "" "arm stdout empty"; expect_has "$(cat "$LABROOT/err")" 'slack: refused: unconfigured' "stderr reason"
[ "$rc" != 0 ] && ok "arm exits non-zero" || bad "arm exited 0 while unconfigured"
[ ! -e "$FM_STATE_OVERRIDE/slack.check.sh" ] && ok "no shim registered" || bad "shim registered"

step "S2.4 malformed allowlist refuses everything with a named reason"
new_home allowlist
printf 'SLACK_BOT_TOKEN=%s\nFM_SLACK_DM_USER=%s\nFM_SLACK_ALLOWED_AUTHORS=charles,@owner\n' "$FAKE_TOKEN" "$OWNER" > "$FM_HOME/.env"
out=$(poll 2>&1); echo "poll output: [$out]"
expect_has "$out" 'slack: refused: allowlist_unparseable' "named refusal"
before=$(requests_total); expect_eq "$before" 0 "server saw no request"

step "S2.5 arm before 'bind slack-dm' is refused on stderr; no shim"
new_home arming
so=$("$REPO/bin/fm-slack-check.sh" arm 2>"$LABROOT/err"); rc=$?
echo "stdout=[$so] stderr=[$(cat "$LABROOT/err")] rc=$rc"
expect_has "$(cat "$LABROOT/err")" 'source_not_bound' "refusal names unbound source"
[ "$rc" != 0 ] && ok "non-zero" || bad "rc 0"
[ ! -e "$FM_STATE_OVERRIDE/slack.check.sh" ] && ok "no shim" || bad "shim written"

step "S2.6 bind + arm: DM opened and proved readable; shim + trust written; stdout 'armed:'"
"$CAPTAIN" bind slack-dm >/dev/null
so=$("$REPO/bin/fm-slack-check.sh" arm 2>"$LABROOT/err"); rc=$?
echo "stdout=[$so] stderr=[$(cat "$LABROOT/err")] rc=$rc"
expect_eq "$so" "armed: state/slack.check.sh" "arm stdout"; expect_eq "$rc" 0 "arm rc"
[ -x "$FM_STATE_OVERRIDE/slack.check.sh" ] && [ -f "$FM_STATE_OVERRIDE/slack.check-trust" ] && ok "shim + trust present" || bad "missing shim/trust"
admin log | python3 -c 'import json,sys; print("methods during arm:", [r["method"] for r in json.load(sys.stdin)])'

step "S2.7 the watcher contract: armed check runs trust-checked, quiet when nothing to report"
out=$(watcher_run_check); echo "watcher-run check output: [$out]"
expect_eq "$out" "" "armed check silent with no answer and (first) mirror of resolve-call"
T=$(thread_ts resolve-call); echo "thread for resolve-call: $T"
[ -n "$T" ] && ok "armed check mirrored the open hold into a thread" || bad "no thread mirrored by armed check"

step "S2.8 AFK owner types answer; the next watcher sweep emits ONE wake line"
reply "$T" "1" "user=$OWNER"
out=$(watcher_run_check); echo "watcher-run check output: [$out]"
expect_eq "$out" "closed: resolve-call" "single wake line"
expect_eq "$(answer_line resolve-call)" ship "answer recorded"
out=$(watcher_run_check); expect_eq "$out" "" "next sweep silent (no repeat wake)"

step "S2.9 edited shim is rejected by the watcher trust binding"
cp "$FM_STATE_OVERRIDE/slack.check.sh" "$LABROOT/shim.bak"
printf '# tampered\n' >> "$FM_STATE_OVERRIDE/slack.check.sh"
out=$(watcher_run_check); expect_eq "$out" "WATCHER-REJECTED-CHECK" "tampered shim not run by watcher"
cp "$LABROOT/shim.bak" "$FM_STATE_OVERRIDE/slack.check.sh"; chmod 700 "$FM_STATE_OVERRIDE/slack.check.sh"
out=$(watcher_run_check); expect_eq "$out" "" "restored shim runs again"

step "S2.10 hard off switch: disarm removes check immediately, even with token+allowlist still set"
so=$("$REPO/bin/fm-slack-check.sh" disarm 2>&1); rc=$?
echo "disarm: [$so] rc=$rc"
expect_eq "$so" "disarmed: state/slack.check.sh" "disarm stdout"; expect_eq "$rc" 0 "disarm rc"
[ ! -e "$FM_STATE_OVERRIDE/slack.check.sh" ] && [ ! -e "$FM_STATE_OVERRIDE/slack.check-trust" ] && ok "shim + trust gone" || bad "artifacts remain"
out=$(watcher_run_check); expect_eq "$out" "WATCHER-REJECTED-CHECK" "watcher finds nothing to run"
# A pending owner reply must not be read once disarmed + check invoked by hand.
new_home allowlist
"$REPO/bin/fm-slack-check.sh" arm >/dev/null 2>&1
mirror >/dev/null; A=$(thread_ts allow-a)
"$REPO/bin/fm-slack-check.sh" disarm >/dev/null
reply "$A" "2" "user=$OWNER"
out=$("$REPO/bin/fm-slack-check.sh" check 2>&1); rc=$?
expect_eq "$rc/$out" "0/" "manual 'check' after disarm does nothing"
expect_eq "$(is_open allow-a)" open "allow-a untouched after disarm"

step "S2.11 unbind slack-dm: poll no longer feeds answers"
"$CAPTAIN" unbind slack-dm >/dev/null
out=$(poll 2>&1); echo "poll after unbind: [$out]"
expect_not "$out" 'closed:' "no close while unbound"
expect_eq "$(is_open allow-a)" open "allow-a still open while unbound"
"$CAPTAIN" bind slack-dm >/dev/null
out=$(poll 2>&1); echo "poll after re-bind: [$out]"
expect_has "$out" 'closed: allow-a' "answer delivered once re-bound"
[ "$FAILED" = 0 ] && echo "S2 RESULT: ALL PASS" || echo "S2 RESULT: FAILURES"
exit $FAILED
