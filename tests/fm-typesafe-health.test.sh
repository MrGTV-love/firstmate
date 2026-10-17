#!/usr/bin/env bash
# TypeSafe account-health alert (bin/fm-typesafe-health.sh) through its public
# interface, with a fake curl on PATH standing in for the endpoint:
#   - 402 raises exactly one wake naming what failed, since when, and the
#     affected consumers; a repeat is silent; a 200 raises one recovered note
#   - 401 and 403 alert as an auth failure, and a change of class alerts again
#   - a timeout below the measured threshold stays silent, and a persistent one
#     raises one wake of its own
#   - a consumer-reported code alerts at once, with no probe
#   - a secondmate home and a keyless home stay silent
#   - the key never reaches argv, output, state, or a wake
# The watcher integration lives in tests/fm-watch-typesafe-health.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-typesafe-health)

HEALTH="$ROOT/bin/fm-typesafe-health.sh"
KEY="tsk-health-secret-9f3a1c"
FAKEBIN="$TMP_ROOT/fakebin"
LOG="$TMP_ROOT/curl-log"
mkdir -p "$FAKEBIN" "$LOG"

# Fake curl: records argv, drains stdin, checks the bearer header read from fd 3
# without recording it, then answers like the real tool would. FAKE_CURL_MODE is
# ok (the default, answering FAKE_CURL_HTTP), timeout (exit 28), or refused
# (exit 7); like real curl it renders the -w template even when the transfer fails.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out='' write=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) write=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > /dev/null
if [ -n "${TYPESAFE_API_KEY+x}${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'env-leak\n' >> "$FAKE_CURL_LOG/env"
else
  printf 'env-clean\n' >> "$FAKE_CURL_LOG/env"
fi
header=$(cat /dev/fd/3 2>/dev/null || true)
if [ "$header" = "Authorization: Bearer ${FAKE_CURL_EXPECT_KEY:-}" ]; then
  printf 'header-ok\n' >> "$FAKE_CURL_LOG/auth"
else
  printf 'header-bad\n' >> "$FAKE_CURL_LOG/auth"
fi
printf 'call\n' >> "$FAKE_CURL_LOG/calls"
case "${FAKE_CURL_MODE:-ok}" in
  timeout)
    write=${write//'%{http_code}'/000}; write=${write//'%{time_total}'/5.001}
    printf '%s' "$write"; exit 28 ;;
  refused)
    write=${write//'%{http_code}'/000}; write=${write//'%{time_total}'/0.012}
    printf '%s' "$write"; exit 7 ;;
esac
write=${write//'%{http_code}'/${FAKE_CURL_HTTP:-200}}; write=${write//'%{time_total}'/0.180}
printf '%s' "$write"
printf '{}' > "$out"
SH
chmod +x "$FAKEBIN/curl"

new_home() {  # <name> [with-key] -> prints the home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  [ "${2:-key}" != key ] || printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$home/.env"
  printf '%s\n' "$home"
}

# health <home> <mode|http> <args...>: run the tool the way a caller does. It
# sets the fake endpoint (an HTTP code, or timeout or refused), runs the tool
# in the home, and prints the combined output; the exit status is left in $?.
health() {
  local home=$1 behavior=$2 mode=ok http=200
  shift 2
  case "$behavior" in timeout|refused) mode=$behavior ;; *) http=$behavior ;; esac
  env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE \
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$LOG" FAKE_CURL_EXPECT_KEY="$KEY" FAKE_CURL_MODE="$mode" FAKE_CURL_HTTP="$http" \
    FM_TYPESAFE_HEALTH_UNREACHABLE_PROBES="${HEALTH_PROBES:-}" \
    bash "$HEALTH" "$@" 2>&1
}

wakes() {  # <home> [key-prefix] -> number of queued wake rows with this key
  local queue="$1/state/.wake-queue"
  [ -f "$queue" ] || { printf 0; return 0; }
  awk -F '\t' -v prefix="${2:-typesafe-health}" 'index($4, prefix) == 1 { n++ } END { print n + 0 }' "$queue"
}

wake_payloads() {  # <home> -> every queued payload, one per line
  [ ! -f "$1/state/.wake-queue" ] || awk -F '\t' '{ print $5 }' "$1/state/.wake-queue"
}

state_field() { sed -n "s/^$2=//p" "$1/state/.typesafe-health" 2>/dev/null; }

curl_calls() { if [ -f "$LOG/calls" ]; then wc -l < "$LOG/calls" | tr -d ' '; else printf 0; fi; }

# ---- 402: one alert, repeats suppressed, one recovery note ---------------------
HOME_A=$(new_home credits)
out=$(health "$HOME_A" 402 probe); rc=$?
expect_code 0 "$rc" "a 402 probe exits 0"
assert_contains "$out" 'typesafe-health: credits (http 402)' "a 402 probe prints its class"
assert_equals 1 "$(wakes "$HOME_A")" "a 402 raises exactly one wake"
assert_equals 1 "$(wakes "$HOME_A" typesafe-health-credits)" "the wake is keyed by its class"
payload=$(wake_payloads "$HOME_A")
assert_contains "$payload" 'check: typesafe-health:' "the wake is a check wake"
assert_contains "$payload" 'out of credits (HTTP 402)' "the wake names what failed"
assert_contains "$payload" 'first seen 20' "the wake says since when"
for consumer in 'worker dispatch resolution' 'worker skill picking' 'compact-adviser' 'Level 6 jev-guard' 'belay Stop hook'; do
  assert_contains "$payload" "$consumer" "the wake names the affected consumer: $consumer"
done
assert_equals credits "$(state_field "$HOME_A" alerted)" "the alert is recorded for deduplication"

health "$HOME_A" 402 probe >/dev/null
health "$HOME_A" 402 record 402 dispatch-resolve >/dev/null
health "$HOME_A" 402 record 402 skill-pick >/dev/null
assert_equals 1 "$(wakes "$HOME_A")" "a repeat of the same failure, from a probe or a consumer, stays silent"

health "$HOME_A" 200 probe >/dev/null
assert_equals 2 "$(wakes "$HOME_A")" "recovery raises one more wake"
assert_equals 1 "$(wakes "$HOME_A" typesafe-health-recovered)" "the recovery wake is keyed as recovered"
assert_contains "$(wake_payloads "$HOME_A")" 'recovered - the TypeSafe (Jev) API answers again' "the recovery wake says what recovered"
assert_equals '' "$(state_field "$HOME_A" alerted)" "recovery clears the alert record"
health "$HOME_A" 200 probe >/dev/null
health "$HOME_A" 200 record 200 dispatch-resolve >/dev/null
assert_equals 2 "$(wakes "$HOME_A")" "a healthy home raises nothing more"

health "$HOME_A" 402 probe >/dev/null
assert_equals 3 "$(wakes "$HOME_A")" "after recovery a new 402 alerts again"
pass "402: one alert, repeats suppressed, one recovery note, and a fresh alert after recovery"

# ---- 401 and 403: an auth failure, and a change of class alerts again ----------
HOME_B=$(new_home auth)
health "$HOME_B" 401 probe >/dev/null
assert_equals 1 "$(wakes "$HOME_B" typesafe-health-auth)" "a 401 raises one auth wake"
assert_contains "$(wake_payloads "$HOME_B")" 'rejected the API key (HTTP 401)' "the auth wake names the rejected key"
health "$HOME_B" 403 record 403 dispatch-resolve >/dev/null
assert_equals 1 "$(wakes "$HOME_B")" "a 403 after a 401 is the same failure and stays silent"
health "$HOME_B" 402 probe >/dev/null
assert_equals 2 "$(wakes "$HOME_B")" "a different failure the captain has not heard of alerts again"
assert_equals 1 "$(wakes "$HOME_B" typesafe-health-credits)" "the second wake is the credits one"
health "$HOME_B" 200 probe >/dev/null
assert_equals 1 "$(wakes "$HOME_B" typesafe-health-recovered)" "recovery from a changed class is one note"
HOME_B2=$(new_home auth-403)
health "$HOME_B2" 403 probe >/dev/null
assert_contains "$(wake_payloads "$HOME_B2")" 'rejected the API key (HTTP 403)' "a 403 alerts as an auth failure too"
pass "401 and 403 alert as auth failures, and a change of class alerts again"

# ---- unreachable: below the threshold silent, at it one wake -------------------
HOME_C=$(new_home timeout)
health "$HOME_C" timeout probe >/dev/null
health "$HOME_C" timeout probe >/dev/null
assert_equals 0 "$(wakes "$HOME_C")" "a timeout below the threshold stays internal"
assert_equals 2 "$(state_field "$HOME_C" unreachable_count)" "the consecutive misses are counted"
assert_contains "$(health "$HOME_C" timeout status)" 'last_detail: timed out after 5s' "a timeout is told apart from a refusal"
health "$HOME_C" 200 probe >/dev/null
assert_equals 0 "$(state_field "$HOME_C" unreachable_count)" "a success resets the count"
assert_equals 0 "$(wakes "$HOME_C")" "recovering from a quiet blip raises no note, since nothing was alerted"
for _ in 1 2 3; do health "$HOME_C" refused probe >/dev/null; done
assert_equals 1 "$(wakes "$HOME_C" typesafe-health-unreachable)" "the third consecutive miss raises one wake"
assert_contains "$(wake_payloads "$HOME_C")" 'has not answered 3 checks in a row (no connection (curl exit 7))' "the wake states the measured threshold"
health "$HOME_C" refused probe >/dev/null
health "$HOME_C" 503 probe >/dev/null
assert_equals 1 "$(wakes "$HOME_C")" "more misses after the alert stay silent"
health "$HOME_C" 200 probe >/dev/null
assert_equals 1 "$(wakes "$HOME_C" typesafe-health-recovered)" "recovery after an unreachable alert is one note"

HEALTH_PROBES=2
HOME_C2=$(new_home timeout-threshold)
health "$HOME_C2" 500 probe >/dev/null
assert_equals 0 "$(wakes "$HOME_C2")" "an HTTP 500 counts as a miss, not an alert, on its own"
health "$HOME_C2" 500 probe >/dev/null
assert_equals 1 "$(wakes "$HOME_C2" typesafe-health-unreachable)" "FM_TYPESAFE_HEALTH_UNREACHABLE_PROBES moves the threshold"
HEALTH_PROBES=

# A failure the captain already knows about is never replaced by a vaguer one.
HOME_C3=$(new_home credits-then-timeout)
health "$HOME_C3" 402 probe >/dev/null
for _ in 1 2 3 4; do health "$HOME_C3" timeout probe >/dev/null; done
assert_equals 1 "$(wakes "$HOME_C3")" "an unreachable run after a credits alert adds no wake"
health "$HOME_C3" 402 probe >/dev/null
assert_equals 1 "$(wakes "$HOME_C3")" "the credits alert is still deduplicated afterwards"
pass "unreachable and timeout stay internal below the threshold and alert once at it"

# Guard budget exhaustion is counted independently of ordinary probe misses.
HOME_G=$(new_home guard-outages)
health "$HOME_G" 000 record 000 jev-guard >/dev/null
health "$HOME_G" 000 record 000 jev-guard >/dev/null
assert_equals 0 "$(wakes "$HOME_G")" "two exhausted guard budgets do not alert"
health "$HOME_G" 000 record 000 unrelated >/dev/null
assert_equals 0 "$(wakes "$HOME_G")" "other consumer transport codes do not become guard outages"
health "$HOME_G" 000 record 000 jev-guard >/dev/null
assert_equals 1 "$(wakes "$HOME_G" typesafe-health-unreachable)" "three exhausted budgets in fifteen minutes alert"
health "$HOME_G" 000 record 000 jev-guard >/dev/null
assert_equals 1 "$(wakes "$HOME_G")" "repeated guard outages remain deduplicated"
health "$HOME_G" 200 record 200 dispatch-resolve >/dev/null
assert_equals 1 "$(wakes "$HOME_G" typesafe-health-recovered)" "normal health recovery clears a guard alert"
HOME_G2=$(new_home guard-old-outages)
health "$HOME_G2" 000 record 000 jev-guard >/dev/null
old=$(( $(date +%s) - 901 ))
printf 'guard_outages=%s %s\n' "$old" "$old" >> "$HOME_G2/state/.typesafe-health"
health "$HOME_G2" 000 record 000 jev-guard >/dev/null
assert_equals 0 "$(wakes "$HOME_G2")" "outages older than fifteen minutes cannot trigger the guard alert"
pass "guard exhaustion alerts after three recent budgets, ignores expired history, deduplicates and recovers through the health channel"

# ---- consumer reports: at once, with no probe ----------------------------------
HOME_D=$(new_home consumer)
before=$(curl_calls)
health "$HOME_D" 402 record 402 dispatch-resolve >/dev/null
assert_equals "$before" "$(curl_calls)" "a consumer-reported code makes no request"
assert_equals 1 "$(wakes "$HOME_D" typesafe-health-credits)" "a consumer's 402 alerts at once"
assert_contains "$(wake_payloads "$HOME_D")" 'by dispatch-resolve' "the wake says which consumer saw it"
health "$HOME_D" 200 record 200 skill-pick >/dev/null
assert_equals 1 "$(wakes "$HOME_D" typesafe-health-recovered)" "a consumer's 200 proves recovery at once"
HOME_D2=$(new_home consumer-ok)
health "$HOME_D2" 200 record 200 dispatch-resolve >/dev/null
assert_absent "$HOME_D2/state/.typesafe-health" "a healthy dispatch leaves no state behind"
health "$HOME_D2" 500 record 500 dispatch-resolve >/dev/null
health "$HOME_D2" 429 record 429 skill-pick >/dev/null
health "$HOME_D2" 000 record 000 skill-pick >/dev/null
assert_absent "$HOME_D2/state/.typesafe-health" "codes the probe owns are ignored from consumers"
assert_equals 0 "$(wakes "$HOME_D2")" "ignored codes raise nothing"
health "$HOME_D2" 200 record 12 >/dev/null; rc=$?
expect_code 2 "$rc" "a malformed code is a usage error"
health "$HOME_D2" 200 bogus >/dev/null; rc=$?
expect_code 2 "$rc" "an unknown subcommand is a usage error"
pass "a consumer-reported 402, 401, 403, or 200 acts at once and other codes are ignored"

# ---- secondmate and keyless homes stay silent ----------------------------------
HOME_E=$(new_home lane nokey)
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_A" > "$HOME_E/.fm-secondmate-parent"
before=$(curl_calls)
health "$HOME_E" 402 probe >/dev/null; rc=$?
expect_code 0 "$rc" "a secondmate probe exits 0"
health "$HOME_E" 402 record 402 dispatch-resolve >/dev/null
health "$HOME_E" 401 record 401 skill-pick >/dev/null
assert_equals "$before" "$(curl_calls)" "a secondmate home makes no request"
assert_equals 0 "$(wakes "$HOME_E")" "a secondmate home raises no wake"
assert_absent "$HOME_E/state/.typesafe-health" "a secondmate home keeps no health state"
assert_contains "$(health "$HOME_E" 402 status)" 'secondmate home (silent' "status explains the silence"
HOME_E2=$(new_home lane-marker)
: > "$HOME_E2/.fm-secondmate-home"
health "$HOME_E2" 402 record 402 dispatch-resolve >/dev/null
assert_equals 0 "$(wakes "$HOME_E2")" "the identity marker alone also marks a secondmate home"

HOME_F=$(new_home keyless nokey)
before=$(curl_calls)
health "$HOME_F" 402 probe >/dev/null; rc=$?
expect_code 0 "$rc" "a keyless probe exits 0"
assert_equals "$before" "$(curl_calls)" "no key means Jev is off and nothing is requested"
assert_equals 0 "$(wakes "$HOME_F")" "a keyless home raises no wake"
assert_absent "$HOME_F/state/.typesafe-health" "a keyless home keeps no health state"
pass "a secondmate home and a keyless home stay silent and make no request"

# ---- the key never leaves its channel ------------------------------------------
assert_not_contains "$(cat "$LOG/argv")" "$KEY" "the key never appears on curl argv"
assert_not_contains "$(cat "$LOG/argv")" "Bearer" "no auth header appears on curl argv"
assert_equals header-ok "$(sort -u "$LOG/auth")" "every request delivered the bearer header on fd 3 and nothing else"
leaks=$(find "$TMP_ROOT" -type f \( -name .typesafe-health -o -name .wake-queue \) -exec grep -lF -- "$KEY" {} + 2>/dev/null || true)
assert_equals '' "$leaks" "the key is in no state file and no wake"
assert_not_contains "$(health "$HOME_A" 402 probe)$(health "$HOME_A" 402 status)" "$KEY" "the key is in no output"
assert_equals env-clean "$(sort -u "$LOG/env")" "the key is never in the environment of the request process"
pass "the key never reaches argv, output, state, wakes, or the environment"
