#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-proc.sh: arming, result classification, and
# the generic runner end to end - one pile-up produces one census, one durable wake,
# and no repeat while the count stays high.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="$ROOT/bin/fm-procevent-proc.sh"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-proc)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_PROCEVENT_OWNER_LEASE_SECONDS=1 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=60

new_home() {  # <name>: print a tracked lab home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  fm_test_track_procevent_home "$home" "$FM_PROCEVENT_CLAIM_ROOT"
  printf '%s\n' "$home"
}
census_n() {  # <state-dir>
  local n=0 f
  for f in "$1"/proc-census.*.json; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s\n' "$n"
}
in_home() {  # <home> <command>...
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$@"
}

if help=$("$ADAPTER" --help 2>&1); then fail "help unexpectedly exited zero"; fi
printf '%s\n' "$help" | grep -Fq 'fm-procevent-proc.sh arm [--hold <secs>] [--interval <secs>] [--limit <n>]' \
  || fail "help omitted the arm usage"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then fail "help leaked executable source"; fi
pass "help renders only the complete header"

[ "$("$ADAPTER" source-id)" = proc-guard ] || fail "source-id is not proc-guard"

HOME_A=$(new_home arm)
out=$(in_home "$HOME_A" "$ADAPTER" arm --hold 1.5 --interval 0.25 --limit 1000000000) || fail "arm failed: $out"
printf '%s\n' "$out" | grep -qx 'armed: proc-guard' || fail "arm did not report armed: $out"
registration="$HOME_A/state/procevent/proc-guard.source"
[ -f "$registration" ] || fail "arm wrote no registration"
for expected in poll --hold 1.5 --interval 0.25 --limit 1000000000; do
  grep -qxF -- "$expected" "$registration" || fail "registration lost the argument $expected"
done
registration_inode=$(python3 -I -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$registration")
fm_test_wait_until 300 test -s "$HOME_A/state/procevent/proc-guard.runner" || fail "arm left no listener"
prior_runner=$(cat "$HOME_A/state/procevent/proc-guard.runner")
in_home "$HOME_A" "$ADAPTER" arm --hold 1.5 --interval 0.25 --limit 1000000000 >/dev/null \
  || fail "arming twice with the same flags failed"
[ "$(python3 -I -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$registration")" = "$registration_inode" ] \
  || fail "an identical arm replaced the registration generation"
[ "$(cat "$HOME_A/state/procevent/proc-guard.runner")" = "$prior_runner" ] \
  || fail "an identical arm replaced the listener"
sleep 3
[ -s "$HOME_A/state/procevent/proc-guard.runner" ] || fail "arm left no listener"
kill -0 "$(cat "$HOME_A/state/procevent/proc-guard.runner")" 2>/dev/null || fail "idle lease expired the standing listener"
in_home "$HOME_A" "$ADAPTER" arm --hold 1.5 --interval 0.25 --limit 1 >/dev/null \
  || fail "rearming with a changed limit failed"
fm_test_wait_until 300 test -e "$HOME_A/state/procevent-inbox/proc-guard.1.result" \
  || fail "the changed limit never reached the sampler"
changed_result="$HOME_A/state/procevent-inbox/proc-guard.1.result"
grep -qx 'limit: 1' "$changed_result" || fail "the replacement sampler retained the old limit"
kill -0 "$prior_runner" 2>/dev/null && fail "changed rearm left the obsolete listener alive"
in_home "$HOME_A" "$ADAPTER" arm --hold 1.5 --interval 0.25 --limit 1000000000 >/dev/null \
  || fail "restoring the quiet sampler failed"
fm_test_wait_until 100 bash -c 'test ! -e "$1/proc-guard.episode"' _ "$FM_PROCEVENT_CLAIM_ROOT" \
  || fail "the quiet replacement never cleared the episode"
in_home "$HOME_A" "$ADAPTER" retire >/dev/null || fail "quiet retire failed"
pass "arm starts an idempotent standing listener without a watcher or fresh owner lease"

HOME_B=$(new_home refuse)
for bad in "--hold 0" "--hold x" "--interval 0" "--warn-pct 40" "--clear-pct 50" "--limit 0" "--limit x" "--limit 007" "--warn-pct"; do
  # shellcheck disable=SC2086
  if in_home "$HOME_B" "$ADAPTER" arm $bad >/dev/null 2>&1; then fail "arm accepted: $bad"; fi
done
if in_home "$HOME_B" "$ADAPTER" arm --nonsense >/dev/null 2>&1; then fail "arm accepted an unknown flag"; fi
[ ! -e "$HOME_B/state/procevent/proc-guard.source" ] || fail "a refused arm still registered a source"
pass "arm refuses malformed flags and registers nothing"

BARE="$TMP_ROOT/bare-bin"
mkdir -p "$BARE"
for tool in bash dirname env cat awk; do ln -s "$(command -v "$tool")" "$BARE/$tool"; done
HOME_C=$(new_home unsupported)
rc=0
err=$(in_home "$HOME_C" env PATH="$BARE" "$ADAPTER" arm 2>&1) || rc=$?
[ "$rc" = 3 ] || fail "a host the guard cannot measure exited $rc, not 3: $err"
printf '%s\n' "$err" | grep -q 'unsupported' || fail "the refusal did not say why: $err"
[ ! -e "$HOME_C/state/procevent/proc-guard.source" ] || fail "an unsupported host still registered a source"
pass "arm refuses a host the guard cannot measure with exit 3"

RESULT_DIR="$TMP_ROOT/results"
mkdir -p "$RESULT_DIR"
printf 'proc-guard: proc-guard\nstatus: pileup\ncount: 7000\n' > "$RESULT_DIR/pileup"
printf 'proc-guard: proc-guard\nstatus: error\ndetail: unsupported platform\n' > "$RESULT_DIR/error"
printf 'proc-guard: proc-guard\nstatus: idle\n' > "$RESULT_DIR/idle"
[ "$("$ADAPTER" classify "$RESULT_DIR/pileup")" = pileup ] || fail "pileup result misclassified"
[ "$("$ADAPTER" classify "$RESULT_DIR/error")" = error ] || fail "error result misclassified"
[ "$("$ADAPTER" classify "$RESULT_DIR/idle")" = unknown ] || fail "idle result misclassified"
if "$ADAPTER" terminal "$RESULT_DIR/pileup"; then fail "a pile-up ended the source"; fi
"$ADAPTER" terminal "$RESULT_DIR/error" || fail "an error did not end the source"
if "$ADAPTER" terminal "$RESULT_DIR/idle"; then fail "an unknown result ended the source"; fi
if "$ADAPTER" classify "$RESULT_DIR/missing" >/dev/null 2>&1; then fail "classify accepted a missing file"; fi
pass "classify and terminal: a pile-up keeps listening, an error ends the source"

# --- the runner, end to end --------------------------------------------------

HOME_E=$(new_home e2e)
STATE_E="$HOME_E/state"
in_home "$HOME_E" "$ADAPTER" arm --limit 1 --hold 1 --interval 0.2 >/dev/null || fail "e2e arm failed"
fm_test_wait_until 300 test -s "$STATE_E/procevent/proc-guard.runner" || fail "arm never established a listener"
RUNNER=$(cat "$STATE_E/procevent/proc-guard.runner")
fm_test_wait_until 300 test -e "$STATE_E/procevent-inbox/proc-guard.1.result" || fail "the runner never captured a pile-up"

result="$STATE_E/procevent-inbox/proc-guard.1.result"
[ "$("$ADAPTER" classify "$result")" = pileup ] || fail "captured result is not a pile-up: $(cat "$result")"
census=$(sed -n 's/^census: //p' "$result")
[ -f "$census" ] || fail "the captured result names a missing census: $census"
fm_test_wait_until 300 awk -F '\t' '$3 == "check" && $4 == "procevent:proc-guard:1" { found = 1 } END { exit !found }' "$STATE_E/.wake-queue" \
  || fail "no durable wake was queued for the pile-up: $(cat "$STATE_E/.wake-queue" 2>/dev/null)"
[ "$(awk -F '\t' '$3 == "check"' "$STATE_E/.wake-queue" | grep -c .)" = 1 ] || fail "more than one wake for one pile-up"
[ -f "$STATE_E/procevent/proc-guard.source" ] || fail "a pile-up retired the standing detector"
pass "a pile-up becomes one census and one durable wake, and the detector stays registered"

HOME_F=$(new_home competitor)
in_home "$HOME_F" "$ADAPTER" arm --limit 1000000000 --hold 1 --interval 0.2 >/dev/null || fail "competing arm failed"
sleep 4
in_home "$HOME_F" "$ADAPTER" arm --limit 1 --hold 1 --interval 0.2 >/dev/null || fail "competing rearm failed"
[ "$(awk -F '\t' '$3 == "check"' "$STATE_E/.wake-queue" | grep -c .)" = 1 ] || fail "a second wake appeared while the count stayed high"
[ ! -e "$STATE_E/procevent-inbox/proc-guard.2.result" ] || fail "a second result was captured while the count stayed high"
[ "$(census_n "$STATE_E")" = 1 ] || fail "a second census was written while the count stayed high"
[ "$(census_n "$HOME_F/state")" = 0 ] || fail "a competing home captured the same pile-up"
kill -0 "$RUNNER" 2>/dev/null || fail "the restarted poll did not keep waiting"
in_home "$HOME_E" "$ADAPTER" retire >/dev/null || fail "retire failed"
fm_test_wait_until 30 bash -c "! kill -0 $RUNNER 2>/dev/null" || fail "retire left the poll running"
pass "the same canonical runner keeps listening after capture and retire stops it"

in_home "$HOME_F" "$ADAPTER" arm --limit 1 --hold 1 --interval 0.2 >/dev/null || fail "handoff arm failed"
sleep 4
[ "$(census_n "$HOME_F/state")" = 0 ] || fail "ownership handoff duplicated the open episode"
[ ! -e "$HOME_F/state/procevent-inbox/proc-guard.1.result" ] || fail "ownership handoff duplicated the wake"
in_home "$HOME_F" "$ADAPTER" retire >/dev/null || fail "handoff retire failed"
pass "the canonical episode suppresses duplicates across owner homes"

out=$(in_home "$HOME_E" "$PROCEVENT" handled proc-guard 1) || fail "handled failed"
printf '%s\n' "$out" | grep -qx 'handled: proc-guard 1' || fail "the wake was not acknowledged: $out"
pass "the wake is acknowledged through the generic handled command"
