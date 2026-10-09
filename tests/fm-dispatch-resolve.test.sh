#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-resolve.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned typesafe.ai response.
# A fake quota-axi serves the selected schema-5 fixture. No case touches the
# network, and the absent-key case proves the tool makes no call
# at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_MODEL_CATALOG_DIR

TOOL="$ROOT/bin/fm-dispatch-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
denied=
trap '[ -z "$denied" ] || chmod 700 "$denied"; fm_test_cleanup' EXIT
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
BASE_RULES="$TMP_ROOT/rules.json"
RULES="$HOME_DIR/config/crew-dispatch.json"
QUOTA="$TMP_ROOT/quota.json"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$LOG" "$NO_CURL_BIN"
for command_name in bash chmod cp dirname grep jq mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done

cat > "$BRIEF" <<'MD'
# Task
Fix the off-by-one in the pager: root cause is the `<=` on line 40 of pager.sh, expected behavior is one page per call.
MD

cat > "$BASE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "New feature work on the app.",
      "floor": { "scope": "model:fable", "min_percent": 20, "provider": "claude" },
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" },
      "why": "SECRET-WHY-TEXT feature work wants the strongest model"
    },
    {
      "when": "The task generates images.",
      "use": [
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol", "floor": { "scope": "all_models", "min_percent": 50 } }
      ]
    },
    {
      "when": "Genuinely very difficult design or planning work.",
      "approval": "captain",
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" }
    },
    {
      "when": "A simple bug fix with a stated root cause.",
      "use": [
        { "harness": "claude", "model": "sonnet", "effort": "high" },
        { "harness": "cursor", "model": "cursor-grok-4.6-medium" },
        { "harness": "kimi", "model": "kimi-code/k3" }
      ]
    }
  ],
  "default": [
    { "harness": "claude", "model": "opus" },
    { "harness": "cursor", "model": "cursor-grok-4.6-high" }
  ]
}
JSON
cp "$BASE_RULES" "$RULES"

write_quota() {  # <path> <cursor spendPriority> [<claude all_models spendPriority>]
  local path=$1 cursor=$2 claude=${3:--0.4627}
  cat > "$path" <<JSON
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 79, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": $claude } },
      { "scope": "model:fable", "status": "known", "effectivePercentRemaining": 15, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.79 } } ] } },
    { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 31, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.1649 } } ] } },
    { "provider": "cursor", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 91, "runway": { "status": "through_reset" }, "selection": { "spendPriority": $cursor } } ] } },
    { "provider": "agy", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.4 } } ] } },
    { "provider": "google", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 72, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.3 } } ] } },
    { "provider": "kimi", "state": { "status": "unknown" }, "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } }
  ]
}
JSON
}
write_quota "$QUOTA" 0.7597

write_response() {  # <path> <choice> <confidence>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.96, "default": 0.01 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv (minus the -o target), the stdin body, and the header
# read from fd 3, then answers with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP. Like
# real curl, it renders the -w template even when the transfer fails, reporting
# FAKE_CURL_DELAY as its own transfer time.
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
out='' write=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) write=$2; printf '%s\n%s\n' "$1" "$2" >> "${FAKE_CURL_LOG:?}/argv"; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
if [ "${FAKE_CURL_DELAY:-0}" != 0 ]; then sleep "$FAKE_CURL_DELAY"; fi
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ -n "${FAKE_CURL_MUTATE_SOURCE:-}" ]; then
  cp "$FAKE_CURL_MUTATE_SOURCE" "${FAKE_CURL_MUTATE_TARGET:?}"
fi
status=${FAKE_CURL_HTTP:-200}
[ "${FAKE_CURL_FAIL:-0}" = 1 ] && status=000
write=${write//'%{http_code}'/$status}
printf '%s' "${write//'%{time_total}'/${FAKE_CURL_TIME_TOTAL:-${FAKE_CURL_DELAY:-0}}}"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf '%s\n' --version >> "${QUOTA_AXI_CALLS:?}"
  [ "${FAKE_QUOTA_VERSION_FAIL:-0}" = 1 ] && exit 1
  printf '%s\n' "${FAKE_QUOTA_VERSION:-0.1.51}"
  exit 0
fi
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'quota-axi:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'quota-axi:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
if [ "${FAKE_QUOTA_DELAY:-0}" != 0 ]; then sleep "$FAKE_QUOTA_DELAY"; fi
[ "${FAKE_QUOTA_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}" = --json ] || exit 2
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

REAL_DIRNAME=$(command -v dirname)
export REAL_DIRNAME
cat > "$FAKEBIN/dirname" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${TYPESAFE_API_KEY+x}${TYPESAFE_API_KEY_PRIVATE+x}" != "" ]; then
  printf 'secret-present\n' >> "${FAKE_CURL_LOG:?}/dirname-env"
else
  printf 'clean\n' >> "${FAKE_CURL_LOG:?}/dirname-env"
fi
exec "$REAL_DIRNAME" "$@"
SH
chmod +x "$FAKEBIN/dirname"

RESPONSE="$TMP_ROOT/response.json"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" QUOTA_AXI_CALLS="$LOG/quota-axi.calls" QUOTA_AXI_FIXTURE="$QUOTA" CHILD_ENV_LOG="$LOG/child-env"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> <err-var> [args...]: the tool with fakebin first on
# PATH and an isolated FM_HOME; TYPESAFE_API_KEY comes from the caller's env.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "${RESOLVER_BASH:-bash}" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

run_without_curl() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$NO_CURL_BIN" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

KEY='test-key-9f1c2d3e-never-on-argv'
code='' out='' err=''

# --- absent key: off, silent on stdout, no network, no quota read -----------
reset_log
write_response "$RESPONSE" rule_4 0.9
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_absent "$LOG/argv" "absent key never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent key never reads quota-axi"
pass "absent key is off: one stderr line, exit 0, no network call"

reset_log
TYPESAFE_API_KEY=$KEY run code out err --help
expect_code 0 "$code" "help exits 0 with an environment key"
assert_contains "$out" 'Usage:' "help retains the public interface"
assert_contains "$(cat "$LOG/dirname-env")" clean "startup child environment is observed"
assert_not_contains "$(cat "$LOG/dirname-env")" secret-present "help scrubs the key before its first child"
assert_absent "$LOG/argv" "help never calls curl"
reset_log
out=$(cd "$ROOT/bin" && PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" bash fm-dispatch-resolve.sh --help)
assert_contains "$out" 'Usage:' "a bare script filename resolves its shared library"
assert_contains "$(cat "$LOG/dirname-env")" clean "bare-filename startup child environment is observed"
assert_not_contains "$(cat "$LOG/dirname-env")" secret-present "bare-filename startup scrubs the key before children"
pass "help and bare-filename startup isolate environment credentials"

# --- .env key, and the environment wins over it ------------------------------
printf '%s\n' '# local secrets' 'FMX_PAIRING_TOKEN=abc' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
run code out err "$BRIEF" --project pager
expect_code 0 "$code" ".env key resolves"
assert_contains "$out" '  status: clear' ".env key produces a clear result"
assert_contains "$(cat "$LOG/header")" "Authorization: Bearer $KEY" ".env key reaches curl on the fd header"
reset_log
TYPESAFE_API_KEY=env-wins run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "environment key wins over .env"
rm -f "$HOME_DIR/.env"
OVERRIDE_CONFIG="$TMP_ROOT/override-config"
mkdir -p "$OVERRIDE_CONFIG"
cp "$BASE_RULES" "$OVERRIDE_CONFIG/crew-dispatch.json"
reset_log
TYPESAFE_API_KEY=$KEY FM_CONFIG_OVERRIDE="$OVERRIDE_CONFIG" run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "FM_CONFIG_OVERRIDE selects the canonical rules directory"
pass "TYPESAFE_API_KEY= in .env activates the tool; environment and config overrides work"

# --- clear: request shape, secret handling, argmax --------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "clear exits 0"
assert_contains "$out" 'dispatch-resolve:' "TOON block header"
assert_contains "$out" '  status: clear' "clear status"
assert_contains "$out" '  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.9' "rule and confidence line"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "argmax picks the highest spendPriority"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "every candidate is accounted for"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' "unmeasured provider stays listed as eligible and unranked"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (kimi)' "clear results flag eligible unranked candidates once"
assert_not_contains "$out" '--effort' "cursor profile without effort emits no --effort"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "the request uses the fixed typesafe.ai endpoint"
assert_contains "$argv" $'--max-time\n5' "the request uses the fixed five-second timeout"
assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "curl receives the bearer header on fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "the API key is absent from every child environment"
assert_contains "$(cat "$LOG/dirname-env")" clean "ordinary startup child environment is observed"
assert_not_contains "$(cat "$LOG/dirname-env")" secret-present "ordinary requests scrub the key before startup children"
body=$(cat "$LOG/body")
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "default model is jev-latest"
assert_equals 'pager' "$(jq -r .state.task.project <<<"$body")" "project rides in the state"
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'off-by-one in the pager' "a brief without task headings rides whole in the state"
assert_equals '["rule"]' "$(jq -c '.questions | keys' <<<"$body")" "only the rule Choice is asked"
assert_equals '["default","rule_1","rule_2","rule_3","rule_4"]' "$(jq -c '.questions.rule.criteria | keys' <<<"$body")" "one option per rule plus default"
assert_equals 'No listed rule applies to this task.' "$(jq -r '.questions.rule.criteria.default' <<<"$body")" "the fixed generic none criterion is the default option"
assert_equals 'A simple bug fix with a stated root cause.' "$(jq -r '.questions.rule.criteria.rule_4' <<<"$body")" "rule when text is the option verbatim"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "why text never leaves the machine"
assert_not_contains "$body" 'spendPriority' "quota never leaves the machine"
assert_not_contains "$body" 'cursor-grok' "use profiles never leave the machine"
pass "clear: one rule Choice request, key on the fd header only, spendPriority argmax over every candidate"

# --- API, quota, and local time are separate on stock macOS Bash too ----------
telemetry_field() {  # <output> <field>
  awk -v key="$2" '{
    for (i = 1; i <= NF; i++) {
      split($i, pair, "=")
      if (pair[1] == key) { print pair[2]; exit }
    }
  }' <<<"$1"
}
reset_log
TYPESAFE_API_KEY=$KEY RESOLVER_BASH=/bin/bash FAKE_CURL_DELAY=0.12 FAKE_QUOTA_DELAY=0.24 \
  run code out err "$BRIEF" --project pager
expect_code 0 "$code" "timed resolver exits 0 under /bin/bash"
api_ms=$(telemetry_field "$out" api_ms)
quota_ms=$(telemetry_field "$out" quota_ms)
local_ms=$(telemetry_field "$out" local_ms)
total_ms=$(telemetry_field "$out" total_ms)
case "$api_ms:$quota_ms:$local_ms:$total_ms" in
  *[!0-9:]*|:*|*::*|*:) fail "timings must be integer milliseconds: $out" ;;
esac
[ "$api_ms" -ge 120 ] || fail "API delay lost millisecond precision: $api_ms"
[ "$quota_ms" -ge 240 ] || fail "quota delay lost millisecond precision: $quota_ms"
assert_equals "$total_ms" "$(( api_ms + quota_ms + local_ms ))" "stages account for total time exactly"
assert_equals 120 "$api_ms" "API time is curl's own transfer time, without helper startup"
assert_contains "$out" "latency_ms: $api_ms" "legacy latency still measures only the API"
assert_contains "$out" 'model: jev-1.13.0' "returned model id remains observable"
assert_equals 812 "$(telemetry_field "$out" input_tokens)" "usage reports input tokens"
assert_equals 60 "$(telemetry_field "$out" output_tokens)" "usage reports output tokens"
cost=$(telemetry_field "$out" jev_cost_usd)
jq -ne --argjson cost "$cost" '$cost == (812 * 0.042 / 1000000)' >/dev/null \
  || fail "cost must charge input tokens only: $cost"
assert_equals 0.042 "$(telemetry_field "$out" jev_input_usd_per_million)" "estimate exposes its catalog rate"
assert_not_contains "$out$err" "$KEY" "timing and cost output never expose the key"
assert_not_contains "$out$err" 'off-by-one in the pager' "timing and cost output never expose brief text"
assert_equals $'--version\n--json' "$(cat "$LOG/quota-axi.calls")" "timing preserves compatibility checking and one quota snapshot"
pass "stock Bash resolver separates API, quota, local and total timing, with input-only Jev cost"

# Without EPOCHREALTIME, as on stock macOS Bash 3.2, stamps still come from the
# epoch clock at millisecond precision. A fake whole-second `date` proves the
# coarse fallback is not what answered.
cat > "$FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
printf '1\n'
SH
chmod +x "$FAKEBIN/date"
clock_ms=$(PATH="$FAKEBIN:$BASE_PATH" /bin/bash -c \
  '. "$1"; unset EPOCHREALTIME; fm_timing_now_ms' _ "$ROOT/bin/fm-timing-lib.sh")
perl -MTime::HiRes=time -e '
  my $stamp = shift;
  my $now = int(time * 1000);
  exit !($stamp =~ /\A[0-9]+\z/ && $stamp <= $now && $now - $stamp < 10000);
' "$clock_ms" || fail "Bash timer without EPOCHREALTIME did not use the epoch ms clock: $clock_ms"
rm -f "$FAKEBIN/date"
pass "stock Bash timing uses the host epoch clock at millisecond precision"

# Where the shell has EPOCHREALTIME, the timer reads it without starting Perl.
cat > "$FAKEBIN/perl" <<'SH'
#!/usr/bin/env bash
printf 'perl\n' >> "${FAKE_CURL_LOG:?}/perl.calls"
exit 1
SH
chmod +x "$FAKEBIN/perl"
reset_log
if PATH="$FAKEBIN:$BASE_PATH" bash -c '[ -n "${EPOCHREALTIME:-}" ]'; then
  clock_ms=$(PATH="$FAKEBIN:$BASE_PATH" bash -c \
    '. "$1"; fm_timing_now_ms' _ "$ROOT/bin/fm-timing-lib.sh")
  rm -f "$FAKEBIN/perl"
  perl -MTime::HiRes=time -e '
    my $stamp = shift;
    my $now = int(time * 1000);
    exit !($stamp =~ /\A[0-9]+\z/ && $stamp <= $now && $now - $stamp < 10000);
  ' "$clock_ms" || fail "EPOCHREALTIME timer did not read the epoch ms clock: $clock_ms"
  assert_absent "$LOG/perl.calls" "EPOCHREALTIME timing starts no Perl process"
  pass "EPOCHREALTIME timing stays on the builtin fast path"
else
  rm -f "$FAKEBIN/perl"
  printf 'skip: bash on PATH has no EPOCHREALTIME\n'
fi

# A curl that reports no transfer time leaves API time unknown, never invented.
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_TIME_TOTAL=unknown run code out err "$BRIEF"
expect_code 0 "$code" "unparseable curl time exits 0"
assert_contains "$out" '  status: clear' "unparseable curl time does not change resolution"
assert_equals null "$(telemetry_field "$out" api_ms)" "unparseable curl time is unknown API time"
assert_contains "$out" 'latency_ms: -' "legacy latency is unknown with API time"
pass "missing curl transfer time is reported as unknown"

# Missing usage is not fabricated as zero, and a quota failure still reports
# the paid API call while marking only the snapshot as failed.
jq 'del(.usage)' "$RESPONSE" > "$TMP_ROOT/no-usage.json"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_RESPONSE="$TMP_ROOT/no-usage.json" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "missing optional usage does not change resolution"
assert_equals null "$(telemetry_field "$out" jev_cost_usd)" "missing usage has unknown cost"
assert_equals null "$(telemetry_field "$out" input_tokens)" "missing usage has unknown input count"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_QUOTA_FAIL=1 FAKE_QUOTA_DELAY=0.12 run code out err "$BRIEF"
expect_code 0 "$code" "quota failure with telemetry exits 0"
assert_contains "$out" '  reason: quota-axi --json failed' "quota failure preserves its reason"
assert_equals "$cost" "$(telemetry_field "$out" jev_cost_usd)" "quota failure retains API cost"
assert_equals jev-1.13.0 "$(telemetry_field "$out" returned_model)" "quota failure attributes paid usage to the returned Jev version"
[ "$(telemetry_field "$out" quota_ms)" -ge 120 ] || fail "failed quota duration was lost"
pass "unavailable usage is unknown and a failed quota snapshot retains API cost"

jq --arg key "$KEY" '.model = ("jev-1.13.0\n" + $key + " private-brief-marker-4417")' "$RESPONSE" > "$TMP_ROOT/sensitive-model.json"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_RESPONSE="$TMP_ROOT/sensitive-model.json" FAKE_QUOTA_FAIL=1 \
  run code out err "$BRIEF"
expect_code 0 "$code" "unsafe response model does not block quota-error intake"
assert_equals null "$(telemetry_field "$out" returned_model)" "arbitrary response model text is not telemetry"
assert_not_contains "$out$err" "$KEY" "error model evidence cannot echo a key"
assert_not_contains "$out$err" 'private-brief-marker-4417' "error model evidence cannot echo private brief text"
pass "quota-error model evidence accepts only safe Jev version ids"

reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_RESPONSE="$TMP_ROOT/sensitive-model.json" \
  run code out err "$BRIEF"
expect_code 0 "$code" "unsafe response model does not block resolution"
assert_contains "$out" '  status: clear' "unsafe response model does not change routing"
assert_contains "$out" '  model: -   latency_ms:' "legacy model line shows an unsafe model id as unknown"
assert_equals null "$(telemetry_field "$out" returned_model)" "unsafe model id is not success telemetry"
assert_equals 812 "$(telemetry_field "$out" input_tokens)" "unsafe model id keeps usage"
assert_not_contains "$out$err" "$KEY" "success model evidence cannot echo a key"
assert_not_contains "$out$err" 'private-brief-marker-4417' "success model evidence cannot echo private brief text"
pass "successful resolution model evidence accepts only safe Jev version ids"

# API error bodies may echo an authorization header or private request state.
# They are never diagnostics, even when the resolver keeps intake moving.
printf '%s\n' "$KEY private-brief-marker-4417" > "$TMP_ROOT/sensitive-error"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=429 FAKE_CURL_RESPONSE="$TMP_ROOT/sensitive-error" \
  run code out err "$BRIEF"
expect_code 0 "$code" "sensitive API error exits 0"
assert_contains "$out" '  reason: http 429 after' "HTTP failure remains actionable"
assert_not_contains "$out$err" "$KEY" "raw HTTP error cannot expose the API key"
assert_not_contains "$out$err" 'private-brief-marker-4417' "raw HTTP error cannot expose private request text"
assert_equals null "$(telemetry_field "$out" quota_ms)" "unattempted quota is unknown, not zero"
assert_equals null "$(telemetry_field "$out" jev_cost_usd)" "unvalidated API response has no invented cost"
assert_absent "$LOG/quota-axi.calls" "HTTP error does not call quota"
pass "error diagnostics omit sensitive API bodies without blocking intake"

# --- never-send list: a match or a bad list withholds the request -------------
NEVER_SEND="$HOME_DIR/config/dispatch-never-send"
PRIVATE_BRIEF="$TMP_ROOT/private-brief.md"
cat > "$PRIVATE_BRIEF" <<'MD'
# Task
## Captain's intent
Fix the pager for the Acme-Ledger account 4417-2290.

## Firstmate spec
- Keep the change small.
MD
expect_withheld() {  # <label> <stderr fragment> [<value that must not print>...]
  local label=$1 fragment=$2
  shift 2
  expect_code 0 "$code" "$label exits 0"
  assert_equals '' "$out" "$label prints nothing on stdout, so firstmate uses its existing intake"
  assert_contains "$err" "dispatch-resolve: off ($fragment" "$label names why on stderr"
  assert_contains "$err" 'nothing sent)' "$label says nothing was sent"
  assert_absent "$LOG/argv" "$label never calls curl"
  assert_absent "$LOG/quota-axi.calls" "$label never reads quota"
  assert_not_contains "$err" "$KEY" "$label never prints the API key"
  assert_contains "$(cat "$LOG/dirname-env")" clean "$label startup child environment is observed"
  assert_not_contains "$(cat "$LOG/dirname-env")" secret-present "$label scrubs the key before startup children"
  local value
  for value in "$@"; do
    assert_not_contains "$err" "$value" "$label never prints the listed value"
  done
}

printf '%s\n' '# private values' '' '   ' 'Unlisted-Value' > "$NEVER_SEND"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "a list with no match leaves resolution unchanged"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "a list with no match sends the task text"

printf '%s\n' '# private values' '' '  acme-ledger  ' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a case-insensitive literal match" "brief text matches $NEVER_SEND line 3" 'acme-ledger' 'Acme-Ledger' '4417-2290'

WRAPPED_BRIEF="$TMP_ROOT/wrapped-brief.md"
printf '# Task\n## Captain'"'"'s intent\nFix the pager for Example Client\nLtd before\tthe\xc2\xa0release.\n' > "$WRAPPED_BRIEF"
printf '%s\n' 'example  client ltd' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief wraps across lines" "brief text matches $NEVER_SEND line 1" 'example' 'Example'

printf '%s\n' 'before the release' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief spaces with a tab and a no-break space" "brief text matches $NEVER_SEND line 1" 'release'

printf '%s\n' 'orion-private' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project orion-private
expect_withheld "a project-name match" "brief text matches $NEVER_SEND line 1" 'orion-private'

printf '%s\n' 'stated root cause' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_withheld "a rule-criterion match" "brief text matches $NEVER_SEND line 1" 'stated root cause'

SECOND_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SECOND_HOME/config"
printf '%s\n' 'acme-ledger' > "$NEVER_SEND"
# A child shell keeps the lib's own globals (such as out) out of this script
# shellcheck disable=SC2016 # Expanded by the child shell
bash -c '. "$1" && propagate_inheritable_config "$2" "$3"' _ \
  "$ROOT/bin/fm-config-inherit-lib.sh" "$HOME_DIR/config" "$SECOND_HOME/config" \
  || fail "inheritance into the secondmate home failed"
PRIMARY_HOME=$HOME_DIR
HOME_DIR=$SECOND_HOME
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "an inherited list in a secondmate home" "brief text matches $SECOND_HOME/config/dispatch-never-send line 1" 'acme-ledger' 'Acme-Ledger' '4417-2290'
HOME_DIR=$PRIMARY_HOME

rm -f "$NEVER_SEND"
mkdir "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a directory at the list path" "$NEVER_SEND is not a readable regular file" 'Acme-Ledger' '4417-2290'
rmdir "$NEVER_SEND"
ln -s "$TMP_ROOT/missing-never-send" "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a broken symlink at the list path" "$NEVER_SEND is not a readable regular file" 'Acme-Ledger' '4417-2290'
rm -f "$NEVER_SEND"

POLICY_TARGET_DIR="$TMP_ROOT/policy-target"
mkdir -p "$POLICY_TARGET_DIR"
printf 'Acme-Ledger\n' > "$POLICY_TARGET_DIR/policy"
ln -s "$POLICY_TARGET_DIR/policy" "$NEVER_SEND"
reset_log
denied=$POLICY_TARGET_DIR
chmod 400 "$denied"
[ ! -x "$denied" ] || fail "policy target fixture must deny ancestor search"
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
chmod 700 "$denied"
denied=
expect_withheld "a policy link with an inaccessible target ancestor" "$NEVER_SEND is not a readable regular file" 'Acme-Ledger' '4417-2290'
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a readable policy link" "brief text matches $NEVER_SEND line 1" 'Acme-Ledger' '4417-2290'
printf 'Unlisted-Value\n' > "$POLICY_TARGET_DIR/policy"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "readable nonmatching policy link permits normal dispatch"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "readable policy target is checked without changing task text"
rm "$NEVER_SEND"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "no list resolves exactly as before"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "no list sends the task text as before"
pass "never-send list withholds the request on a match or a bad list, and never prints the value"

# --- opt-in protected brief regions ------------------------------------------
MARKED_BRIEF="$TMP_ROOT/marked-brief.md"
cat > "$MARKED_BRIEF" <<'MD'
# Task
## Captain's intent
Fix the public pager.
<!-- dispatch-never-send:start -->
### Synthetic customer details
SYNTHETIC-CUSTOMER-4417
# Internal heading that must not truncate the public task
<!-- dispatch-never-send:end -->
Keep the public pagination behavior.

## Firstmate spec
<!-- dispatch-never-send:start -->
SYNTHETIC-PROJECT-CONSTRAINT
<!-- dispatch-never-send:end -->
Use the existing pager.

# Setup
Ignore this boilerplate.
MD

rm -f "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$MARKED_BRIEF" --project pager
expect_withheld "markers with no never-send list" "never-send markers need the marked-sections directive" 'SYNTHETIC-CUSTOMER-4417'
assert_absent "$LOG/body" "markers without the opt-in never produce an outgoing body"

printf '%s\n' 'Unrelated literal' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$MARKED_BRIEF" --project pager
expect_withheld "markers with a literal-only list" "never-send markers need the marked-sections directive" 'SYNTHETIC-CUSTOMER-4417'

NEAR_MISS_BRIEF="$TMP_ROOT/near-miss-brief.md"
printf '%s\n' 'Public task' '<!--dispatch-never-send:start-->' 'SYNTHETIC-NEAR-MISS' '<!--dispatch-never-send:end-->' > "$NEAR_MISS_BRIEF"
rm -f "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$NEAR_MISS_BRIEF" --project pager
expect_withheld "unspaced markers with no never-send list" "never-send markers need the marked-sections directive" 'SYNTHETIC-NEAR-MISS'

printf '%s\n' '# dispatch-never-send marked-sections' 'SYNTHETIC-CUSTOMER-4417' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$MARKED_BRIEF" --project pager
assert_contains "$out" '  status: clear' "protected text is removed before literal matching"
sent_brief=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent_brief" 'Fix the public pager.' "public intent before a protected region survives"
assert_contains "$sent_brief" 'Keep the public pagination behavior.' "a protected heading cannot truncate public intent after the region"
assert_contains "$sent_brief" 'Use the existing pager.' "public spec survives a second protected region"
for private_text in SYNTHETIC-CUSTOMER-4417 SYNTHETIC-PROJECT-CONSTRAINT 'Synthetic customer details' 'Internal heading' dispatch-never-send 'Ignore this boilerplate'; do
  assert_not_contains "$(cat "$LOG/body")" "$private_text" "request body excludes $private_text"
done

WHOLE_MARKED_BRIEF="$TMP_ROOT/whole-marked-brief.md"
cat > "$WHOLE_MARKED_BRIEF" <<'MD'
Public task before a protected region.
   <!-- dispatch-never-send:start -->
# Task
## Captain's intent
SYNTHETIC-HIDDEN-TASK
   <!-- dispatch-never-send:end -->
Public task after a protected region.
MD
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WHOLE_MARKED_BRIEF" --project pager
sent_brief=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent_brief" 'Public task before' "whole-brief fallback uses sanitized text before the region"
assert_contains "$sent_brief" 'Public task after' "whole-brief fallback uses sanitized text after the region"
assert_not_contains "$(cat "$LOG/body")" 'SYNTHETIC-HIDDEN-TASK' "whole-brief fallback never rereads protected text"

FENCED_MARKED_BRIEF="$TMP_ROOT/fenced-marked-brief.md"
cat > "$FENCED_MARKED_BRIEF" <<'MD'
Public fenced example:
```
<!-- dispatch-never-send:start -->
SYNTHETIC-FENCED-SECRET
<!-- dispatch-never-send:end -->
public code
```
MD
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$FENCED_MARKED_BRIEF" --project pager
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'public code' "public fenced code survives"
assert_not_contains "$(cat "$LOG/body")" 'SYNTHETIC-FENCED-SECRET' "markers protect text inside code fences"

# A literal outside a removed region still stops the entire request.
printf '%s\n' '# dispatch-never-send marked-sections' 'public pagination' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$MARKED_BRIEF" --project pager
expect_withheld "literal protection after section stripping" "brief text matches $NEVER_SEND line 2" 'public pagination'

printf '%s\n' '# dispatch-never-send marked-sections' > "$NEVER_SEND"
BAD_MARKED_BRIEF="$TMP_ROOT/bad-marked-brief.md"
for malformed in unclosed orphan nested inline typo unspaced recased; do
  case "$malformed" in
    unclosed) printf '%s\n' 'Public task' '<!-- dispatch-never-send:start -->' 'SYNTHETIC-BAD-SECRET' > "$BAD_MARKED_BRIEF" ;;
    orphan) printf '%s\n' 'SYNTHETIC-BAD-SECRET' '<!-- dispatch-never-send:end -->' > "$BAD_MARKED_BRIEF" ;;
    nested) printf '%s\n' '<!-- dispatch-never-send:start -->' '<!-- dispatch-never-send:start -->' 'SYNTHETIC-BAD-SECRET' '<!-- dispatch-never-send:end -->' '<!-- dispatch-never-send:end -->' > "$BAD_MARKED_BRIEF" ;;
    inline) printf '%s\n' 'Public task <!-- dispatch-never-send:start --> SYNTHETIC-BAD-SECRET' > "$BAD_MARKED_BRIEF" ;;
    typo) printf '%s\n' '<!-- dispatch-never-send:star -->' 'SYNTHETIC-BAD-SECRET' > "$BAD_MARKED_BRIEF" ;;
    unspaced) printf '%s\n' 'Public task' '<!--dispatch-never-send:start-->' 'SYNTHETIC-BAD-SECRET' '<!--dispatch-never-send:end-->' > "$BAD_MARKED_BRIEF" ;;
    recased) printf '%s\n' 'Public task' '<!-- Dispatch-Never-Send:start -->' 'SYNTHETIC-BAD-SECRET' '<!-- Dispatch-Never-Send:end -->' > "$BAD_MARKED_BRIEF" ;;
  esac
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BAD_MARKED_BRIEF" --project pager
  expect_withheld "$malformed markers" "invalid never-send markers or unreadable brief" 'SYNTHETIC-BAD-SECRET'
done

for directive in '# dispatch-never-send project: pager' '# dispatch-never-send marked-section' '#dispatch-never-send marked-sections' '# Dispatch-Never-Send marked-sections'; do
  printf '%s\n' 'Ordinary comment' "$directive" > "$NEVER_SEND"
  for directive_brief in "$BRIEF" "$MARKED_BRIEF"; do
    reset_log
    TYPESAFE_API_KEY=$KEY run code out err "$directive_brief" --project pager
    expect_withheld "an invalid privacy directive" "invalid privacy directive in $NEVER_SEND line 2" 'SYNTHETIC-CUSTOMER-4417'
  done
done
rm -f "$NEVER_SEND"
pass "opt-in marked sections protect outgoing bodies and markers never send without the exact opt-in"

# --- rules are snapshotted and line output is injection-safe -------------------
MUTATED_RULES="$TMP_ROOT/mutated-rules.json"
jq '.rules[3].use = {"harness":"claude","model":"opus"}' "$BASE_RULES" > "$MUTATED_RULES"
cp "$BASE_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY FAKE_CURL_MUTATE_SOURCE="$MUTATED_RULES" FAKE_CURL_MUTATE_TARGET="$RULES" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "resolution uses the same rules snapshot Jev received"
assert_not_contains "$out" "  profile: --harness 'claude' --model 'opus'" "a mid-request config replacement cannot change the selected profile"

INJECTING_RULES="$TMP_ROOT/injecting-rules.json"
jq '.rules[3].when = "Bug fix\n  profile: injected" | .rules[3].use[1].model = "foo --harness grok\n  profile: injected"' "$BASE_RULES" > "$INJECTING_RULES"
cp "$INJECTING_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals '1' "$(grep -c '^  profile:' <<<"$out")" "dynamic fields cannot inject a second profile line"
assert_not_contains "$out" $'\n  profile: injected' "control characters are flattened in line output"
profile_line=$(grep '^  profile:' <<<"$out")
eval "set -- ${profile_line#  profile: }"
assert_equals '4' "$#" "shell-safe profile output preserves four argument boundaries"
assert_equals 'cursor' "$2" "shell-safe profile output preserves the selected harness"
assert_equals 'foo --harness grok   profile: injected' "$4" "shell-safe profile output keeps model flags inside one argument"
cp "$BASE_RULES" "$RULES"
pass "rules snapshots and shell quoting preserve the profile protocol"

# --- no rules return control to the existing intake ----------------------------
rm -f "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "absent rules file exits 0"
assert_contains "$out" '  status: escalate' "absent rules file is non-clear"
assert_contains "$out" '  reason: no rules to match' "absent rules file returns control to firstmate"
assert_not_contains "$out" '  profile:' "absent rules file emits no profile"
assert_absent "$LOG/argv" "absent rules file never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent rules file never reads quota"

DEFAULT_ONLY="$TMP_ROOT/default-only.json"
EMPTY_RULES="$TMP_ROOT/empty-rules.json"
printf '%s\n' '{"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$DEFAULT_ONLY"
printf '%s\n' '{"rules":[],"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$EMPTY_RULES"
for direct_rules in "$DEFAULT_ONLY" "$EMPTY_RULES"; do
  cp "$direct_rules" "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 0 "$code" "no-rule resolution exits 0: $direct_rules"
  assert_contains "$out" '  status: escalate' "no-rule resolution is non-clear: $direct_rules"
  assert_contains "$out" '  reason: no rules to match' "no-rule resolution returns control to firstmate: $direct_rules"
  assert_not_contains "$out" '  profile:' "no-rule resolution emits no profile: $direct_rules"
  assert_absent "$LOG/argv" "no-rule resolution never calls curl: $direct_rules"
  assert_absent "$LOG/quota-axi.calls" "no-rule resolution never reads quota: $direct_rules"
done

AGY_RULE="$TMP_ROOT/agy-rule.json"
printf '%s\n' '{"rules":[{"when":"Agy work.","use":{"harness":"agy"}}]}' > "$AGY_RULE"
cp "$AGY_RULE" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}}},"usage":{"input_tokens":100,"output_tokens":60}}
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: agy:-  provider=agy  scope=all_models  remaining=64%  spendPriority=0.4  runway=through_reset  -> eligible' "agy uses its resolver-only authoritative quota provider"
assert_contains "$out" "  profile: --harness 'agy'" "provider-less agy rule resolves"

GEMINI_RULE="$TMP_ROOT/gemini-rule.json"
printf '%s\n' '{"rules":[{"when":"Gemini work.","use":{"harness":"gemini","model":"gemini-3.8-flash-high","provider":"google"}}]}' > "$GEMINI_RULE"
cp "$GEMINI_RULE" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: gemini:gemini-3.8-flash-high  provider=google  scope=all_models  remaining=72%  spendPriority=0.3  runway=through_reset  -> eligible' "Gemini resolves through its explicit provider"
assert_contains "$out" "  profile: --harness 'gemini' --model 'gemini-3.8-flash-high'" "Gemini is a typed verified dispatch harness"

cp "$ROOT/docs/examples/crew-dispatch.json" "$RULES"
cp "$ROOT/docs/examples/model-index.json" "$HOME_DIR/config/model-index.json"
mkdir -p "$TMP_ROOT/no-catalogs"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"default","confidence":0.9,"probabilities":{"rule_1":0.02,"rule_2":0.02,"rule_3":0.02,"default":0.94}}},"usage":{"input_tokens":812,"output_tokens":60}}
JSON
reset_log
FM_MODEL_CATALOG_DIR="$TMP_ROOT/no-catalogs" TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "the documented example passes opted-in resolution"
assert_contains "$out" 'candidate: pi:anthropic/claude-sonnet-5-5  provider=claude' "the documented Pi default uses its declared Claude provider"
assert_not_contains "$err" 'malformed rules file' "the documented example reaches resolution"
assert_not_contains "$err" 'warning: literal model' "the documented example names roles, never literal ids"
assert_contains "$err" 'catalog unavailable' "an unavailable chosen-model catalog is a notice, not a refusal"
rm "$HOME_DIR/config/model-index.json"
cp "$BASE_RULES" "$RULES"
pass "no-rule fallback, Agy, Gemini, and documented configurations resolve"

# --- ambiguous: fixed confidence floor -----------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.41
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "ambiguous exits 0"
assert_contains "$out" '  status: ambiguous' "below the floor is ambiguous"
assert_contains "$out" '  reason: confidence 0.41 below floor 0.6' "ambiguous names the floor"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "ambiguous preserves matched candidate evidence"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' "ambiguous preserves eligible unranked candidate evidence"
assert_not_contains "$out" '  profile:' "ambiguous emits no profile line"
pass "ambiguous: confidence below the fixed floor hands the decision back"

# --- per-rule confidence floor ------------------------------------------------
write_floor_response() {  # <path> <choice> <confidence> <rule_1> <rule_2> <rule_3> <rule_4> <default>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": $4, "rule_2": $5, "rule_3": $6, "rule_4": $7, "default": $8 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}
FLOOR_RULES="$TMP_ROOT/floor-rules.json"
jq '.rules[1].min_confidence = 0.9 | .rules[3].min_confidence = 0.1' "$BASE_RULES" > "$FLOOR_RULES"
cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.18 0.02
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a top rule below its own floor falls to a runner-up that clears its floor"
assert_contains "$out" '  rule: rule_2 (The task generates images.)   confidence: 0.76' "the model's own pick stays visible"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.18 clears its floor 0.1; rule_2 probability 0.76 is below its floor 0.9' "the fallback names both floors"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the runner-up rule's profiles are resolved"
assert_not_contains "$(cat "$LOG/body")" 'min_confidence' "the model never sees confidence floors"

reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.08 0.12
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "no runner-up clearing its own floor is ambiguous"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; no other option clears its own floor' "the undeclared default keeps the global floor as a runner-up"
assert_not_contains "$out" '  fallback:' "no fallback is reported when none is taken"
assert_not_contains "$out" '  profile:' "ambiguous per-rule floor emits no profile"

jq '.rules[0].min_confidence = 0.1' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.12 0.76 0.0 0.12 0.0
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "equally probable runner-ups never break by option order"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; runner-up tie' "a runner-up tie is named"

cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.45 0.01 0.01 0.01 0.45 0.52
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "a declared floor below the global floor lets the picked rule resolve"

# A declared floor needs the same support from a rule as the pick or as a runner-up
jq '.rules[3].min_confidence = 0.3' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.25 0.25 0.05 0.05 0.35 0.30
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a picked rule clears its declared floor on its own probability, not the answer confidence"
assert_not_contains "$out" '  fallback:' "a picked rule that clears its own floor takes no fallback"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the picked rule resolves at probability 0.35 over floor 0.3"

reset_log
write_floor_response "$RESPONSE" rule_2 0.95 0.05 0.55 0.05 0.30 0.05
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a high answer confidence does not lift a picked rule over its own floor"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.30 clears its floor 0.3; rule_2 probability 0.55 is below its floor 0.9' "the runner-up clears the same floor it would need as the pick"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.05 0.55 0.05 0.25 0.10
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a runner-up below its own floor is not taken"
assert_contains "$out" '  reason: rule_2 probability 0.55 below its floor 0.9; no other option clears its own floor' "the missed runner-up floor is named"
cp "$BASE_RULES" "$RULES"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.01 0.55 0.01 0.42 0.01
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "without declared floors a low pick stays ambiguous"
assert_contains "$out" '  reason: confidence 0.55 below floor 0.6' "without declared floors the global floor reason is unchanged"
assert_not_contains "$out" '  fallback:' "without declared floors no runner-up is taken"
pass "per-rule confidence floors fall to the most probable runner-up that clears its own floor"

# --- the model sees only the task-specific brief sections ----------------------
SCAFFOLD_BRIEF="$TMP_ROOT/scaffold-brief.md"
cat > "$SCAFFOLD_BRIEF" <<'MD'
# Task
## Captain's intent
Add a flag to the pager.

## Firstmate spec
Touch pager.sh only.
```sh
# Not a heading inside a fence
## Setup
```
### Out of scope
Anything else.

# Setup
BOILERPLATE-SETUP never push to the default branch.

## Captain intent authorized for --intent
BOILERPLATE-DUPLICATE
MD
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$SCAFFOLD_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "the captain's intent section is sent"
assert_contains "$sent" $'## Firstmate spec\nTouch pager.sh only.' "the Firstmate spec section is sent"
assert_contains "$sent" $'# Not a heading inside a fence\n## Setup\n```\n### Out of scope\nAnything else.' "fenced lines and subheadings stay inside the section"
assert_not_contains "$sent" 'BOILERPLATE' "scaffold boilerplate after the task sections is not sent"
assert_not_contains "$sent" '# Task' "the enclosing Task heading is not sent"
assert_not_contains "$sent" 'Brief kind:' "a brief without a scout contract line gets no kind line"

SPEC_ONLY_BRIEF="$TMP_ROOT/spec-only-brief.md"
printf '%s\n' '# Task' '## Firstmate spec' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals $'## Firstmate spec\nSpec text.' "$(jq -r .state.task.brief "$LOG/body")" "one recognized section is enough"

printf '%s\n' '# Task' '## Firstmate spec   ' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a heading with trailing blanks is not a section, matching spawn validation"

printf '%s\n' 'Preamble.' '## Firstmate spec' 'Spec text.' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a section outside the Task heading is not a task section"

KIND_BRIEF="$TMP_ROOT/kind-brief.md"
{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' '# Definition of done' 'Delivery contract: mode=no-mistakes' 'Delivery contract: mode=direct-PR'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "a ship brief still sends its task sections"
assert_not_contains "$sent" 'Brief kind:' "a ship brief gets no kind line"
assert_not_contains "$sent" 'mode=' "a ship brief's delivery mode is not sent"

{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' 'This is a SCOUT task: the deliverable is a written report, not a PR.'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'Brief kind: scout (report only)\n\n## Captain\'s intent' "a scout brief's contract line names its kind"
assert_not_contains "$sent" 'This is a SCOUT task' "the scout contract line itself is not sent"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals "$(cat "$BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a brief with neither heading is sent whole"
pass "only the brief's task sections and scout tag reach the model, with a whole-brief fallback"

# --- escalate: captain approval ------------------------------------------------
reset_log
write_response "$RESPONSE" rule_3 0.95
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "escalate exits 0"
assert_contains "$out" '  status: escalate' "approval-gated rule escalates"
assert_contains "$out" "  reason: rule requires the captain's explicit approval before dispatch" "escalate names the approval gate"
assert_contains "$out" 'candidate: claude:fable  provider=claude  scope=model:fable  remaining=15%  spendPriority=-0.79  runway=projected_exhaustion  bounds=all_models:79%/projected_exhaustion,model:fable:15%/projected_exhaustion  -> eligible' "approval escalation preserves matched candidate evidence"
assert_not_contains "$out" '  profile:' "escalate emits no profile line"
pass "escalate: a rule declared approval: captain never yields a profile"

# --- rule floor fails: fall through to default -------------------------------
reset_log
write_response "$RESPONSE" rule_1 0.97
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "rule floor fall-through still resolves"
assert_contains "$out" '  note: rule rule_1 floor model:fable below 20%: fall through to default' "rule floor fall-through is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "fall-through resolves among the default profiles"
assert_not_contains "$out" 'candidate: claude:fable' "the floored rule's own profile is not a candidate"

MISSING_RULE_FLOOR="$TMP_ROOT/missing-rule-floor.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) |= map(select(.scope != "model:fable"))' "$QUOTA" > "$MISSING_RULE_FLOOR"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$MISSING_RULE_FLOOR" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "an unverifiable rule floor escalates"
assert_contains "$out" '  reason: rule rule_1 floor claude/model:fable is unverifiable' "the unverifiable rule floor names its provider and scope"
assert_not_contains "$out" '  profile:' "an unverifiable rule floor never authorizes default routing"
pass "rule floor: known shortfall falls through while unavailable evidence escalates"

# --- declared provider and profile floor --------------------------------------
reset_log
write_response "$RESPONSE" rule_2 0.99
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%' "declared provider routes a Pi profile to the codex row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  -> not eligible: profile floor all_models below 50%' "profile floor makes a candidate ineligible with its reason"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "the remaining eligible candidate wins"

FLOOR_BOUNDS="$TMP_ROOT/floor-bounds.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":10,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.9}}
]' "$QUOTA" > "$FLOOR_BOUNDS"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_BOUNDS" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:10%/projected_exhaustion  -> not eligible: profile floor all_models below 50%' "a failed profile floor reports its named row while retaining all bounds"

FLOOR_WITH_UNKNOWN="$TMP_ROOT/floor-with-unknown.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:gpt-5.6-sol","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$FLOOR_WITH_UNKNOWN"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_WITH_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:-%/unknown  -> not eligible: profile floor all_models below 50%' "a known profile-floor shortfall wins over unrelated unknown model evidence"

MISSING_PROFILE_FLOOR_RULES="$TMP_ROOT/missing-profile-floor-rules.json"
jq '.rules[1].use[1].floor.scope = "model:missing"' "$BASE_RULES" > "$MISSING_PROFILE_FLOOR_RULES"
cp "$MISSING_PROFILE_FLOOR_RULES" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=model:missing  remaining=-%  spendPriority=-  runway=-  -> eligible, unranked: profile floor model:missing is unverifiable: not rankable: disclosed uncertainty' "a missing profile floor remains eligible but unranked"
assert_not_contains "$out" 'profile floor model:missing below' "missing profile evidence is not described as a shortfall"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "another candidate may clear without misrepresenting missing floor evidence"
cp "$BASE_RULES" "$RULES"
pass "declared provider and profile floor evidence are applied in code"

# --- malformed ranking evidence is never ordered -------------------------------
reset_log
NONNUMERIC="$TMP_ROOT/nonnumeric-spend-priority.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .selection.spendPriority) = "high"' "$QUOTA" > "$NONNUMERIC"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONNUMERIC" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=-  runway=through_reset  -> eligible, unranked: spendPriority missing or non-numeric at all_models: not rankable: disclosed uncertainty' "a nonnumeric spendPriority remains eligible but unranked"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "numeric evidence wins without mixed-type ordering"
pass "nonnumeric spendPriority evidence is never ranked"

# --- partial providers retain their known row evidence --------------------------
reset_log
PARTIAL="$TMP_ROOT/partial.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.status) = "partial"' "$QUOTA" > "$PARTIAL"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible' "a known row from a partial provider remains rankable"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "partial provider evidence can win the argmax"

PARTIAL_UNKNOWN="$TMP_ROOT/partial-unknown.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$PARTIAL_UNKNOWN"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=model:cursor-grok-4.6-medium  remaining=-%  spendPriority=-  runway=-  bounds=all_models:91%/through_reset,model:cursor-grok-4.6-medium:-%/unknown  -> eligible, unranked: quota row model:cursor-grok-4.6-medium unknown: not rankable: disclosed uncertainty' "an unknown exact-model row preserves partial known evidence without ranking"
assert_contains "$out" '  note: 2 eligible candidate(s) unranked (cursor, kimi)' "clear result lists every provider with unranked uncertainty"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "another measured candidate can clear"

PARTIAL_EXHAUSTED="$TMP_ROOT/partial-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
] | .effectiveAvailability[] |= if .scope == "all_models" then .effectivePercentRemaining = 0 | .runway.status = "exhausted_now" else . end)' "$QUOTA" > "$PARTIAL_EXHAUSTED"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  bounds=all_models:0%/exhausted_now,model:cursor-grok-4.6-medium:-%/unknown  -> not eligible: runway exhausted_now at all_models' "known exhaustion vetoes a candidate despite unknown exact-model evidence"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (kimi)' "an exhausted candidate is excluded from the unranked uncertainty note"

UNKNOWN_EXHAUSTED="$TMP_ROOT/unknown-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) = {
  "status":"unknown","effectiveAvailability":[
    {"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}
  ]
}' "$QUOTA" > "$UNKNOWN_EXHAUSTED"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$UNKNOWN_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=-%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "unknown provider semantics cannot mask concrete exhaustion"

NO_APPLICABLE="$TMP_ROOT/no-applicable.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability) = [
  {"scope":"model:other","status":"known","effectivePercentRemaining":91,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}
]' "$QUOTA" > "$NO_APPLICABLE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NO_APPLICABLE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  -> eligible, unranked: no applicable quota row for provider cursor: disclosed uncertainty' "a candidate without an applicable row remains eligible but unranked"
assert_contains "$out" '  note: 2 eligible candidate(s) unranked (cursor, kimi)' "no-applicable-row uncertainty appears in the clear-result note"
pass "partial and missing quota evidence remain eligible but unranked"

# --- provider-wide rows remain bounds beside exact model rows ------------------
reset_log
BOUNDED="$TMP_ROOT/bounded.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:sonnet","status":"known","effectivePercentRemaining":99,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.9}}
]' "$QUOTA" > "$BOUNDED"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$BOUNDED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627' "the limiting provider-wide row drives ranking"
assert_contains "$out" 'bounds=all_models:79%/projected_exhaustion,model:sonnet:99%/through_reset' "all applicable quota bounds are disclosed"

EXHAUSTED_WIDE="$TMP_ROOT/exhausted-wide.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")) |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$BOUNDED" > "$EXHAUSTED_WIDE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$EXHAUSTED_WIDE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=0%' "the exhausted account-wide bound is the candidate evidence"
assert_contains "$out" '-> not eligible: runway exhausted_now at all_models' "a healthy exact row cannot bypass an exhausted account-wide bound"
pass "provider-wide and exact quota rows combine into one limiting candidate"

# --- default choice ------------------------------------------------------------
reset_log
write_response "$RESPONSE" default 0.88
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  rule: default (No listed rule applies to this task.)' "default names the fixed neutral none option"
assert_contains "$out" '  note: no rule matched' "default is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "default resolves by argmax"
pass "default: no rule matched resolves among the default profiles"

# --- genuine tie escalates ---------------------------------------------------------
reset_log
TIE="$TMP_ROOT/tie.json"
write_quota "$TIE" 0.5 0.5
write_response "$RESPONSE" default 0.88
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "tie escalates"
assert_contains "$out" '  reason: genuine spendPriority tie' "tie is named"
pass "tie: equal spendPriority never breaks by array order"

# --- nothing rankable escalates -------------------------------------------------
reset_log
NONE="$TMP_ROOT/none.json"
jq '.providers |= map(if .provider == "cursor" or .provider == "claude" then .quotaSemantics.effectiveAvailability |= map(.runway.status = "exhausted_now") else . end)' "$QUOTA" > "$NONE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "no rankable candidate escalates"
assert_contains "$out" '  reason: no rankable eligible candidate' "no-candidate reason"
assert_contains "$out" '-> not eligible: runway exhausted_now' "exhausted candidates keep their reason"
pass "no rankable candidate: the tool escalates instead of guessing"

# --- schema 6: rows keyed by provider + accountKey bind per account ----------------
# quota-axi emits schema 6 once a provider expands to several accounts; every
# row then carries accountKey and one provider id may appear on several rows.
# Native Codex and Pi lanes bind to their own account rows, with no row
# chosen by position or summed across accounts.
LANE_RULES="$TMP_ROOT/lane-rules.json"
SCHEMA6="$TMP_ROOT/schema6.json"
SCHEMA5_PAIR="$TMP_ROOT/schema5-pair.json"
cat > "$LANE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "Codex work.",
      "use": [
        { "harness": "pi", "model": "openai-codex-work/gpt-5.6-terra", "provider": "codex" },
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol" }
      ]
    }
  ]
}
JSON
cat > "$SCHEMA6" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 6,
  "providers": [
    { "provider": "claude", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
    { "provider": "codex", "accountKey": "openai-codex", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": { "status": "exhausted_now" }, "selection": { "spendPriority": -1.4788 } } ] } },
    { "provider": "codex", "accountKey": "openai-codex-work", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 11, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -5.6819 } } ] } },
    { "provider": "cursor", "accountKey": "default", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 24, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": 0.3917 } } ] } }
  ]
}
JSON
cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.9,
    "probabilities": { "rule_1": 0.97, "default": 0.03 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
cp "$LANE_RULES" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
expect_code 0 "$code" "schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "schema 6 snapshot resolves"
assert_contains "$out" 'candidate: pi:openai-codex-work/gpt-5.6-terra  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible' "a Pi lane binds to its own account row"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "the sibling lane reads its own exhausted row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  -> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty' "native Codex never infers an account from a Pi lane"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex-work/gpt-5.6-terra'" "the lane with headroom is chosen"
assert_equals $'--version\n--json' "$(cat "$LOG/quota-axi.calls")" "schema 6 checks compatibility and reads one snapshot"

SCHEMA6_NATIVE="$TMP_ROOT/schema6-native.json"
jq '
  .providers |= map(if .provider == "codex" then
    .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    else . end) |
  (.providers[] | select(.accountKey == "openai-codex-work")) as $account |
  .providers += [($account | .accountKey = "default"),
    ($account | .accountKey = "codex-home" |
      .quotaSemantics.effectiveAvailability |= map(
        .effectivePercentRemaining = 80 | .runway.status = "through_reset" | .selection.spendPriority = 0.8))]
' "$SCHEMA6" > "$SCHEMA6_NATIVE"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_NATIVE" run code out err "$BRIEF"
expect_code 0 "$code" "native Codex schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "native Codex headroom resolves despite exhausted Pi and default rows"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  -> eligible' "native Codex reads codex-home"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex headroom is chosen"

jq '.providers |= reverse' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-reversed.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-reversed.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex selection ignores row order"

jq '.providers |= map(select(.provider != "codex" or .accountKey != "default") |
  if .accountKey == "codex-home" then .accountKey = "default" else . end)' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-default.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex falls back to the default row when codex-home is absent"
pass "native Codex binds to codex-home before default, independently of Pi accounts and row order"

jq '.schemaVersion = 5 | .providers |= map(select(.accountKey != "openai-codex")) | del(.providers[].accountKey)' "$SCHEMA6" > "$SCHEMA5_PAIR"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "schema 5 keeps joining by provider alone"
assert_contains "$out" '  reason: genuine spendPriority tie' "every codex profile reads the one schema 5 codex row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible' "a schema 5 row never needs accountKey"

SCHEMA6_PI_NATIVE="$TMP_ROOT/schema6-pi-native.json"
jq '.providers |= map(select(.provider != "codex" or .accountKey != "default"))' "$SCHEMA6_NATIVE" > "$SCHEMA6_PI_NATIVE"
for harness in pi pi-signed; do
  jq --arg harness "$harness" '.rules[0].use |= map(if .harness == "codex" then
    {harness: $harness, model: "codex-native/gpt-6-astra", provider: "codex", effort: "ultra"}
    else . end)' "$LANE_RULES" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_PI_NATIVE" run code out err "$BRIEF"
  expect_code 0 "$code" "$harness native adapter schema 6 exits 0"
  assert_contains "$out" '  status: clear' "$harness native adapter resolves with codex-home and no default row"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  -> eligible" "$harness native adapter reads codex-home"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter is chosen over exhausted Pi accounts"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter falls back to default"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  -> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty" "$harness native adapter never borrows a Pi account"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible" "$harness native adapter still joins schema 5 by provider alone"
done
cp "$LANE_RULES" "$RULES"
pass "Pi native adapters bind to codex-home with existing fallbacks and schema 5 compatibility"

jq 'del(.providers[1].accountKey)' "$SCHEMA6" > "$TMP_ROOT/schema6-keyless.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-keyless.json" run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a schema 6 row without accountKey is an error outcome"
assert_contains "$out" '  reason: quota-axi --json returned an invalid snapshot' "keyless schema 6 row is named as an invalid snapshot"
cp "$BASE_RULES" "$RULES"
pass "schema 6: each candidate binds to its account row; schema 5 is unchanged"

# --- runway is judged against the task horizon, not the reset clock ------------
GUARD_RULES="$TMP_ROOT/guard-rules.json"
GUARD_QUOTA="$TMP_ROOT/guard-quota.json"
jq '.rules = [.rules[3]] | .rules[0].use = [{harness:"codex",model:"gpt-6-luna"}]' "$BASE_RULES" > "$GUARD_RULES"
cp "$GUARD_RULES" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"choice":"rule_1","confidence":0.9,"probabilities":{"rule_1":0.97,"default":0.03}}}}
JSON
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining = 6 | .selection.spendPriority = 0.9)' "$QUOTA" > "$GUARD_QUOTA"
guard_runway() {  # <name> <runway JSON>: write guard-<name>.json with that codex runway
  jq --argjson runway "$2" '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[].runway) = $runway' "$GUARD_QUOTA" > "$TMP_ROOT/guard-$1.json"
}
guard_runway short '{"status":"projected_exhaustion","usableRunwaySeconds":3600,"projectionConfidence":"established"}'
guard_runway long '{"status":"projected_exhaustion","usableRunwaySeconds":80796,"projectionConfidence":"established"}'
guard_runway boundary '{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectionConfidence":"established"}'
guard_runway early-short '{"status":"projected_exhaustion","usableRunwaySeconds":3600,"projectionConfidence":"early"}'
guard_runway early-long '{"status":"projected_exhaustion","usableRunwaySeconds":80796,"projectionConfidence":"early"}'
guard_runway safe '{"status":"through_reset"}'
guard_runway unknown '{"status":"unknown"}'
guard_runway exhausted_now '{"status":"exhausted_now"}'

reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-short.json" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "established runway shorter than the task horizon does not authorize dispatch"
assert_contains "$out" '  reason: highest-ranked candidate codex:gpt-6-luna has established runway shorter than the 240-minute task horizon; completion is not proven' "the default horizon is 240 minutes"
assert_contains "$out" 'candidate: codex:gpt-6-luna  provider=codex  scope=all_models  remaining=6%  spendPriority=0.9  runway=projected_exhaustion  -> eligible [warning: projected_exhaustion at all_models (usableRunwaySeconds=3600 projectionConfidence=established)]' "the candidate names its short runway"
assert_not_contains "$out" '  profile:' "short runway emits no dispatch profile"
for name in long boundary safe; do
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-$name.json" run code out err "$BRIEF"
  assert_contains "$out" '  status: clear' "$name runway covering the task horizon clears despite 6% remaining"
  assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-6-luna'" "$name runway authorizes the profile"
  assert_not_contains "$out" '[warning:' "$name runway is not a warning"
done
for name in early-short early-long unknown; do
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-$name.json" run code out err "$BRIEF"
  assert_contains "$out" '  status: clear' "$name runway is a disclosed warning, not a veto"
  assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-6-luna'" "$name runway keeps the highest-ranked profile"
  assert_contains "$out" '-> eligible [warning: ' "$name runway is disclosed on the candidate"
  if [ "$name" = early-short ]; then
    assert_contains "$out" '[warning: projected_exhaustion at all_models (usableRunwaySeconds=3600 projectionConfidence=early)]' "an early projection names its confidence"
  fi
done
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$GUARD_QUOTA" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a projection without confidence is a warning, not a veto"
assert_contains "$out" '[warning: projected_exhaustion at all_models (usableRunwaySeconds=unknown projectionConfidence=unknown)]' "absent projection fields are disclosed as unknown"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-exhausted_now.json" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "exhausted_now always vetoes"
assert_contains "$out" '-> not eligible: runway exhausted_now at all_models' "exhausted_now is named"
assert_not_contains "$out" '  profile:' "exhausted_now emits no dispatch profile"
# An exact-model short runway is noticed even when the limiting rank row is safe.
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability) += [
  {scope:"model:gpt-6-luna",status:"known",effectivePercentRemaining:50,runway:{status:"projected_exhaustion",usableRunwaySeconds:600,projectionConfidence:"established"},selection:{spendPriority:1}}
]' "$TMP_ROOT/guard-safe.json" > "$TMP_ROOT/guard-bound.json"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-bound.json" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "every applicable bound participates in the horizon check"
assert_contains "$out" '[warning: projected_exhaustion at model:gpt-6-luna (usableRunwaySeconds=600 projectionConfidence=established)]' "the candidate names the non-limiting short bound"

# The horizon is a declared setting.
jq '.task_horizon_minutes = 30' "$GUARD_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-short.json" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "one hour of runway covers a declared 30-minute horizon"
jq '.task_horizon_minutes = 120' "$GUARD_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-short.json" run code out err "$BRIEF"
assert_contains "$out" 'shorter than the 120-minute task horizon' "a declared horizon replaces the default"
assert_not_contains "$(cat "$LOG/body")" 'task_horizon_minutes' "the model never sees the task horizon"

# A short winner is not replaced by a lower-ranked candidate in the same rule.
jq '.rules[0].use += [{harness:"cursor",model:"cursor-grok-4.6-medium"}]' "$GUARD_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-short.json" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "a short highest-ranked candidate escalates"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible' "the lower-ranked candidate stays visible"
assert_not_contains "$out" '  profile:' "no same-rule fallback profile is emitted"
# A short matched rule never falls back to another rule or the default array.
jq '.rules += [{when:"Cheap chores.",use:{harness:"cursor",model:"cursor-grok-4.6-medium"}}]
  | .default = [{harness:"cursor",model:"cursor-grok-4.6-high"}]' "$GUARD_RULES" > "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"choice":"rule_1","confidence":0.9,"probabilities":{"rule_1":0.9,"rule_2":0.08,"default":0.02}}}}
JSON
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-short.json" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "a short matched rule escalates despite runway elsewhere"
assert_not_contains "$out" 'candidate: cursor' "no other rule's or default candidate is evaluated"
assert_not_contains "$out" '  profile:' "no cross-rule or weaker-class downgrade is emitted"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"choice":"rule_1","confidence":0.9,"probabilities":{"rule_1":0.97,"default":0.03}}}}
JSON

# omp's pooled Codex accounts rank on the visible account as a lower bound,
# through the same task-horizon classification as a single account.
jq '.rules[0].use = [{harness:"omp",model:"openai-codex/gpt-6-luna",provider:"codex"}]' "$GUARD_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-safe.json" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a through_reset visible account proves pool runway"
assert_contains "$out" 'candidate: omp:openai-codex/gpt-6-luna  provider=codex  scope=all_models  remaining=6%  spendPriority=0.9  runway=through_reset  -> eligible' "the pool ranks on its visible lower bound"
assert_contains "$out" "  profile: --harness 'omp' --model 'openai-codex/gpt-6-luna'" "the pooled lane can be auto-selected"
for name in long early-long early-short unknown; do
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-$name.json" run code out err "$BRIEF"
  assert_contains "$out" '  status: clear' "a $name visible reading ranks the pool"
  assert_contains "$out" "  profile: --harness 'omp' --model 'openai-codex/gpt-6-luna'" "a $name visible reading authorizes the pooled profile"
  if [ "$name" = early-long ]; then
    assert_contains "$out" 'candidate: omp:openai-codex/gpt-6-luna  provider=codex  scope=all_models  remaining=6%  spendPriority=0.9  runway=projected_exhaustion  -> eligible [warning: projected_exhaustion at all_models (usableRunwaySeconds=80796 projectionConfidence=early)]' "an early pool projection is a disclosed warning"
  fi
done
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-short.json" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "an established short visible projection is not viable"
assert_contains "$out" '  reason: highest-ranked candidate omp:openai-codex/gpt-6-luna has established runway shorter than the 240-minute task horizon' "a short pool escalates like a single account"
assert_contains "$out" 'candidate: omp:openai-codex/gpt-6-luna  provider=codex  scope=all_models  remaining=6%  spendPriority=0.9  runway=projected_exhaustion  -> eligible [warning: projected_exhaustion at all_models (usableRunwaySeconds=3600 projectionConfidence=established)]' "a short pool stays ranked with its warning"
assert_not_contains "$out" '  profile:' "a short pool cannot authorize a profile"
for snapshot in "$TMP_ROOT/guard-exhausted_now.json" "$SCHEMA6_NATIVE"; do
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$snapshot" run code out err "$BRIEF"
  assert_contains "$out" '  status: escalate' "an exhausted visible account cannot clear the pool"
  assert_contains "$out" 'candidate: omp:openai-codex/gpt-6-luna  provider=codex  -> eligible, unranked: omp Codex account pool is only lower-bounded by its visible account (runway exhausted_now at all_models)' "pool uncertainty is stated on the candidate"
  assert_contains "$out" '[warning: exhausted_now at all_models]' "the visible account's exhaustion is disclosed"
  assert_not_contains "$out" 'remaining=' "single-account headroom is not shown as pool headroom"
  assert_not_contains "$out" 'not eligible' "single-account exhaustion cannot veto the pool"
  assert_not_contains "$out" '  profile:' "an exhausted visible account cannot authorize a profile"
done
# A declared profile floor stays a captain veto for the pool.
jq '.rules[0].use = [{harness:"omp",model:"openai-codex/gpt-6-luna",provider:"codex",floor:{scope:"all_models",min_percent:50}}]' "$GUARD_RULES" > "$RULES"
for snapshot in "$TMP_ROOT/guard-safe.json" "$TMP_ROOT/guard-exhausted_now.json"; do
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$snapshot" run code out err "$BRIEF"
  assert_contains "$out" '-> not eligible: profile floor all_models below 50%' "a pool below its declared floor is not eligible"
  assert_not_contains "$out" 'unranked' "a floor shortfall is not reported as an eligible alternative"
done
jq '.rules[0].use = [{harness:"omp",model:"openai-codex/gpt-6-luna",provider:"codex"},{harness:"cursor",model:"cursor-grok-4.6-medium"}]' "$GUARD_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-short.json" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "a short highest-ranked pool escalates"
assert_not_contains "$out" '  profile:' "a short pool is never replaced by a lower-ranked candidate"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-exhausted_now.json" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "an unranked exhausted pool does not block a measured candidate"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the measured profile clears beside the unranked pool"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (codex)' "a clear choice still discloses pool uncertainty"

# OpenRouter absent rows and credit-only rows are uncertainty, not quota runway.
jq '.rules[0].use = [{harness:"omp",model:"openrouter/provider/model",provider:"openrouter"}]' "$GUARD_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "an absent OpenRouter row cannot clear"
assert_contains "$out" 'candidate: omp:openrouter/provider/model  provider=openrouter  -> eligible, unranked: provider openrouter not in the quota snapshot' "absent OpenRouter coverage is disclosed"
jq '.providers += [{provider:"openrouter",windows:[{id:"credits",remaining:100,unit:"USD"}],quotaSemantics:{status:"unknown",effectiveAvailability:[]}}]' "$QUOTA" > "$TMP_ROOT/guard-openrouter.json"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-openrouter.json" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "a positive OpenRouter credit balance does not establish runway"
assert_contains "$out" 'eligible, unranked: provider openrouter unmeasured (unknown)' "credit-only evidence stays eligible but unranked"
assert_not_contains "$out" '  profile:' "credit-only evidence never authorizes dispatch"

# An unreadable or older version is an error before snapshot interpretation.
cp "$GUARD_RULES" "$RULES"
for version in 0.1.50 'quota-axi development build'; do
  reset_log
  TYPESAFE_API_KEY=$KEY FAKE_QUOTA_VERSION="$version" run code out err "$BRIEF"
  expect_code 0 "$code" "incompatible quota version is a normal error outcome"
  assert_contains "$out" '  status: error' "incompatible quota version never clears"
  assert_contains "$out" 'quota-axi requires >= 0.1.51' "the error names the required minimum"
  assert_equals '--version' "$(cat "$LOG/quota-axi.calls")" "an incompatible binary never supplies ranking evidence"
  assert_not_contains "$out" '  profile:' "an incompatible version emits no dispatch profile"
done
for version in 0.1.51 0.1.55 0.2.0 1.0.0; do
  TYPESAFE_API_KEY=$KEY FAKE_QUOTA_VERSION="$version" QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-safe.json" run code out err "$BRIEF"
  assert_contains "$out" '  status: clear' "compatible $version is usable"
done
reset_log
TYPESAFE_API_KEY=$KEY FAKE_QUOTA_VERSION_FAIL=1 run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a failed version read never clears"
assert_contains "$out" 'quota-axi requires >= 0.1.51' "the failed version read names the minimum"
assert_equals '--version' "$(cat "$LOG/quota-axi.calls")" "a failed version read never takes a quota snapshot"
cp "$BASE_RULES" "$RULES"
pass "task-horizon runway, pooled-account, OpenRouter coverage, and minimum-version guards"

# --- quota-axi is read exactly once --------------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi path exits 0"
assert_equals $'--version\n--json' "$(cat "$LOG/quota-axi.calls")" "quota-axi compatibility is checked and --json is called exactly once"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "quota-axi snapshot drives the argmax"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_QUOTA_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi failure exits 0"
assert_contains "$out" '  status: error' "quota-axi failure is an error outcome"
assert_contains "$out" '  reason: quota-axi --json failed' "quota-axi failure is named"
pass "quota evidence comes from one quota-axi --json read, and its failure is an error outcome"

# --- API and response failures are error outcomes, exit 0 ----------------------
reset_log
run_without_curl code out err "$BRIEF"
expect_code 0 "$code" "missing curl exits 0"
assert_contains "$out" '  status: error' "missing curl is a structured error outcome"
assert_contains "$out" '  reason: curl not installed' "missing curl is named in the TOON block"
assert_contains "$err" 'dispatch-resolve: error (curl not installed)' "missing curl is also reported on stderr"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=429 run code out err "$BRIEF"
expect_code 0 "$code" "http 429 exits 0"
assert_contains "$out" '  status: error' "http 429 is an error outcome"
assert_contains "$out" '  reason: http 429 after' "http status is reported"
assert_contains "$err" 'dispatch-resolve: error (http 429' "error also goes to stderr"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "curl failure exits 0"
assert_contains "$out" '  reason: http 000 after 0 ms' "transport failure reads as http 000 with curl's elapsed time"
reset_log
printf '%s\n' '{"model":"jev","answers":{}}' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  reason: response is not a rule Choice answer' "a malformed answer is an error outcome"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.usage = "bad"' "$RESPONSE" > "$TMP_ROOT/malformed-usage.json"
mv "$TMP_ROOT/malformed-usage.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "malformed usage is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "malformed usage cannot break text rendering silently"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq 'del(.answers.rule.probabilities.default)' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "missing probability choice is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must name every offered choice"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities.rule_4 = "high"' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "nonnumeric probability is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must be numeric and bounded"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities[] = 0' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a zero-mass probability distribution is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must sum to approximately one"
reset_log
write_response "$RESPONSE" rule_4 2
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "out-of-range confidence is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "out-of-range confidence is a malformed answer"
reset_log
write_response "$RESPONSE" rule_9 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "an unknown rule id is an error outcome"
assert_contains "$out" '  reason: rule rule_9 is not in the rules file' "unknown rule id is named"
write_response "$RESPONSE" rule_0 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "rule zero is an error outcome"
assert_contains "$out" '  reason: rule rule_0 is not in the rules file' "rule zero cannot alias the final rule"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=500 run code out err "$BRIEF"
assert_contains "$out" '  status: error' "http 500 is a TOON error outcome"
pass "API, transport, and response failures are error outcomes with exit 0"

# --- configuration errors exit 2 and select nothing ----------------------------------
reset_log
TYPESAFE_API_KEY=$KEY run code out err
expect_code 2 "$code" "missing brief exits 2"
assert_contains "$err" 'brief file required' "missing brief is named"
rm -f "$RULES"
ln -s "$TMP_ROOT/missing-rules-target.json" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "broken canonical rules symlink exits 2"
assert_contains "$err" "rules file not readable: $RULES" "broken rules symlink is actionable"
rm -f "$RULES"
printf '%s\n' '{"rules":[' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "non-JSON rules exits 2"
assert_contains "$err" 'not JSON' "non-JSON rules is named"
for bad in \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"approval":"firstmate"}]}|approval must be "captain" when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"select":"mystery"}]}|unknown select: mystery' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":"high"}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":1.5}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"task_horizon_minutes":0,"rules":[{"when":"x","use":{"harness":"claude"}}]}|task_horizon_minutes must be a positive number when present' \
  '{"task_horizon_minutes":"4h","rules":[{"when":"x","use":{"harness":"claude"}}]}|task_horizon_minutes must be a positive number when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20,"provider":"CLAUDE"}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":""}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":" claude"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":"claude\n"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex","floor":{"scope":"all_models","min_percent":20,"provider":"claude"}}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]}]}|each rule use must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":[{"harness":"claude","model":"opus"},{"harness":"claude","model":"opus"}]}|default must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"spaceship"}}]}|each use profile must name a verified harness' \
  '{"rules":[{"when":"x","use":{"harness":"grok","effort":"max"}}]}|each use profile effort must be supported by its harness and model' \
  '{"rules":[{"when":"x","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5"}}]}|use profiles whose harness lacks one authoritative provider family require provider: opencode' \
  '{"rules":[{"when":"x","use":{"harness":"rovo"}}]}|use profiles whose harness lacks one authoritative provider family require provider: rovo' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":{"harness":"pi","model":"anthropic/claude-sonnet-5"}}|default profiles whose harness lacks one authoritative provider family require provider: pi'; do
  printf '%s\n' "${bad%%|*}" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "malformed rules exit 2: ${bad#*|}"
  assert_contains "$err" "malformed rules file: $RULES - ${bad#*|}" "malformed rules are named: ${bad#*|}"
done
printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"opencode"},{"harness":"rovo"},{"harness":"codex"}]}],"default":[{"harness":"pi"},{"harness":"claude"}]}' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "multiple provider-less profiles exit 2"
assert_contains "$err" "malformed rules file: $RULES - use profiles whose harness lacks one authoritative provider family require provider: opencode; use profiles whose harness lacks one authoritative provider family require provider: rovo; default profiles whose harness lacks one authoritative provider family require provider: pi" "all provider-less profiles are reported together across use and default"
[ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" -eq 1 ] || fail "provider errors must use one diagnostic"
assert_absent "$LOG/argv" "configuration errors never reach the network"
cp "$BASE_RULES" "$RULES"
for removed in --json --rules --quota; do
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" "$removed"
  expect_code 2 "$code" "removed option is rejected: $removed"
  assert_contains "$err" "unknown flag $removed" "removed option has no public path: $removed"
done
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --bogus
expect_code 2 "$code" "unknown flag exits 2"
run code out err --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" 'Usage:' "--help prints usage"
pass "configuration errors exit 2 before any network call"

# Role resolution feeds concrete model ids into quota matching and publication.
cp "$BASE_RULES" "$RULES"
write_quota "$QUOTA" 0.7597
write_response "$RESPONSE" rule_4 0.9
mkdir -p "$TMP_ROOT/model-catalogs"
printf '%s\n' '{"models":[{"id":"cursor-grok-4.6-medium"}]}' > "$TMP_ROOT/model-catalogs/cursor.json"
printf '%s\n' '{"version":1,"roles":{"routine":{"cursor":{"model":"cursor-grok-4.6-medium"}}},"retired":[]}' > "$HOME_DIR/config/model-index.json"
jq '.rules[3].use[1] |= (del(.model) | .role = "routine")' "$BASE_RULES" > "$RULES"
# Withheld intakes must not even try to read live catalog exports.
printf '%s\n' 'New feature work on the app.' > "$HOME_DIR/config/dispatch-never-send"
reset_log
FM_MODEL_CATALOG_DIR="$TMP_ROOT/absent-catalogs" TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "never-send suppresses catalog validation as well as the rule request"
[ -z "$out" ] || fail "withheld indexed intake emitted a profile: $out"
assert_contains "$err" 'dispatch-resolve: off' "withheld indexed intake must stay off"
assert_absent "$LOG/argv" "withheld indexed intake must not reach a request"
rm "$HOME_DIR/config/dispatch-never-send"
reset_log
FM_MODEL_CATALOG_DIR="$TMP_ROOT/model-catalogs" TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "role-based typed intake resolves"
assert_contains "$out" "profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "typed intake publishes a concrete id"
assert_contains "$err" "literal model 'sonnet' for claude is not an index entry" "literal profile ids warn while an index exists"
mkdir -p "$TMP_ROOT/other-catalogs"
printf '%s\n' '{"models":[{"id":"cursor-other"}]}' > "$TMP_ROOT/other-catalogs/cursor.json"
reset_log
FM_MODEL_CATALOG_DIR="$TMP_ROOT/other-catalogs" TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "a chosen id absent from its catalog never blocks intake"
assert_contains "$out" '  status: error' "a chosen id absent from its catalog returns the decision to firstmate"
assert_not_contains "$out" '  profile:' "a chosen id absent from its catalog publishes no profile"
assert_contains "$err" "id 'cursor-grok-4.6-medium' absent or retired in cursor catalog" "the catalog refusal names the chosen id"
# An index edit during the rule request cannot change this intake's resolved id.
cp "$HOME_DIR/config/model-index.json" "$TMP_ROOT/original-index.json"
jq '.roles.routine.cursor.model = "new-model-not-in-catalog"' "$TMP_ROOT/original-index.json" > "$TMP_ROOT/changed-index.json"
reset_log
FM_MODEL_CATALOG_DIR="$TMP_ROOT/model-catalogs" TYPESAFE_API_KEY=$KEY \
  FAKE_CURL_MUTATE_SOURCE="$TMP_ROOT/changed-index.json" FAKE_CURL_MUTATE_TARGET="$HOME_DIR/config/model-index.json" \
  run code out err "$BRIEF"
expect_code 0 "$code" "in-flight index edit must not re-resolve the role"
assert_contains "$out" "profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "intake must keep the id resolved from its frozen index"
cp "$TMP_ROOT/original-index.json" "$HOME_DIR/config/model-index.json"
# A role and a literal that resolve to the same candidate remain duplicates.
jq '.rules[3].use += [{harness:"cursor",model:"cursor-grok-4.6-medium"}]' "$RULES" > "$TMP_ROOT/duplicate-role.json"
mv "$TMP_ROOT/duplicate-role.json" "$RULES"
reset_log
FM_MODEL_CATALOG_DIR="$TMP_ROOT/model-catalogs" TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "duplicate concrete role/literal profiles refuse intake"
assert_absent "$LOG/argv" "duplicate candidates must refuse before the rule request"
rm "$HOME_DIR/config/model-index.json"
pass "typed intake resolves roles before quota ranking and detects concrete duplicates"

# The chosen id is checked against the catalog of the account a pinned worker
# would launch under, not the intake's ambient account.
mkdir -p "$TMP_ROOT/pinned-claude" "$TMP_ROOT/ambient-claude"
printf 'pinned-only\n' > "$TMP_ROOT/pinned-claude/catalog"
printf 'ambient-only\n' > "$TMP_ROOT/ambient-claude/catalog"
cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$TMP_ROOT/claude-catalog-roots'
jq -Rsc '{type:"control_response",response:{subtype:"success",request_id:"model-index",
  response:{models:[split("\\n")[] | select(length > 0) | {value:., resolvedModel:.}]}}}' "\${CLAUDE_CONFIG_DIR}/catalog"
SH
chmod +x "$FAKEBIN/claude"
printf '%s\n' '{"version":1,"roles":{"routine":{"claude":{"model":"pinned-only"}}},"retired":[]}' > "$HOME_DIR/config/model-index.json"
printf '%s\n' "$TMP_ROOT/pinned-claude" > "$HOME_DIR/config/claude-account"
printf '%s\n' '{"rules":[{"when":"Claude work.","use":{"harness":"claude","role":"routine"}}]}' > "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}}},"usage":{"input_tokens":100,"output_tokens":60}}
JSON
reset_log
CLAUDE_CONFIG_DIR="$TMP_ROOT/ambient-claude" TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "pinned-account intake exits 0"
assert_contains "$out" "  profile: --harness 'claude' --model 'pinned-only'" "the pinned account's catalog must decide the chosen id: $err"
[ "$(cat "$TMP_ROOT/claude-catalog-roots")" = "$TMP_ROOT/pinned-claude" ] \
  || fail "the chosen-id catalog must be read from the pinned root only: $(cat "$TMP_ROOT/claude-catalog-roots")"
rm "$HOME_DIR/config/model-index.json" "$HOME_DIR/config/claude-account" "$FAKEBIN/claude"
cp "$BASE_RULES" "$RULES"
pass "typed intake checks the chosen id against the pinned worker account's catalog"

mkdir -p "$TMP_ROOT/supervisor-account"
printf '%s\n' '{"models":[{"slug":"supervisor-only"}]}' > "$TMP_ROOT/supervisor-account/models_cache.json"
printf 'openai-codex  supervisor-only  272K  32K  yes  no\n' > "$TMP_ROOT/supervisor-account/listed"
cat > "$FAKEBIN/pi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${PI_CODING_AGENT_DIR-unset}" >> '$TMP_ROOT/unpinned-catalog-calls'
printf 'provider model context\n'
cat "\$PI_CODING_AGENT_DIR/listed"
SH
chmod +x "$FAKEBIN/pi"
: > "$HOME_DIR/config/launch-env-allowlist"
for context_harness in codex pi; do
  for context_model in pane-only supervisor-only; do
    context_id=$context_model
    [ "$context_harness" != pi ] || context_id="openai-codex/$context_model"
    jq -n --arg h "$context_harness" --arg m "$context_id" \
      '{version:1,roles:{chosen:{($h):{model:$m}}},retired:[]}' > "$HOME_DIR/config/model-index.json"
    jq -n --arg h "$context_harness" \
      '{rules:[{when:"Indexed work.",use:{harness:$h,role:"chosen",provider:"codex"}}]}' > "$RULES"
    reset_log
    CODEX_HOME="$TMP_ROOT/supervisor-account" PI_CODING_AGENT_DIR="$TMP_ROOT/supervisor-account" \
      TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
    expect_code 0 "$code" "unknown chosen context keeps intake available"
    assert_contains "$out" '  status: clear' "supervisor listing or omission must not decide the chosen entry: $err"
    assert_contains "$out" "--model '$context_id'" "the chosen profile must retain the indexed model"
    assert_contains "$err" "effective worker account context is not established" "chosen context uncertainty must be precise"
    assert_contains "$err" "not validated" "a matching supervisor listing must not imply validation"
    assert_absent "$TMP_ROOT/unpinned-catalog-calls" "chosen Pi must not query the supervisor catalog"
  done
done
mkdir -p "$TMP_ROOT/context-exports"
printf '%s\n' '{"models":[{"id":"openai-codex/supervisor-only","resolved_id":"retired-target"}]}' > "$TMP_ROOT/context-exports/pi.json"
jq '.retired = ["retired-target"]' "$HOME_DIR/config/model-index.json" > "$TMP_ROOT/context-index.json"
cp "$TMP_ROOT/context-index.json" "$HOME_DIR/config/model-index.json"
FM_MODEL_CATALOG_DIR="$TMP_ROOT/context-exports" TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "an authoritative export must still refuse an alias resolved to a retired id"
assert_not_contains "$out" '  profile:' "an export-backed retirement must not publish a profile"
assert_contains "$err" "absent or retired in pi catalog" "explicit export evidence remains authoritative despite unknown pane context"
rm "$HOME_DIR/config/model-index.json" "$HOME_DIR/config/launch-env-allowlist" "$FAKEBIN/pi"
cp "$BASE_RULES" "$RULES"
pass "chosen Codex and Pi entries never use supervisor catalogs and retain authoritative export retirement checks"

printf '# all fm-dispatch-resolve tests passed\n'
