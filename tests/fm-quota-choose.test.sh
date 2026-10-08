#!/usr/bin/env bash
# Unit tests for bin/fm-quota-choose.sh.
# Drives the public argv interface with a mocked quota-axi JSON source.
set -u
unset CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID ANTHROPIC_ORGANIZATION_ID
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE
unset PI_CODING_AGENT_DIR PI_CONFIG_DIR OMP_PROFILE PI_PROFILE XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/fixtures.sh
. "$SCRIPT_DIR/fixtures.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-choose.XXXXXX")
fm_test_copy_managed_bin "$ROOT" "$LAB/repository"
BIN="$LAB/repository/bin"
FIXTURE="$LAB/quota.json"
MALFORMED="$LAB/malformed.json"
MULTI_JSON="$LAB/multi-json.json"
DUPLICATE="$LAB/duplicate.json"
OUT_OF_RANGE="$LAB/out-of-range.json"
INVALID_RUNWAY="$LAB/invalid-runway.json"
INVALID_AVAILABILITY="$LAB/invalid-availability.json"
EMPTY_SCOPE="$LAB/empty-scope.json"
WHITESPACE_PROVIDER="$LAB/whitespace-provider.json"
WHITESPACE_SCOPE="$LAB/whitespace-scope.json"
UNKNOWN_EXHAUSTED="$LAB/unknown-exhausted.json"
KNOWN_UNKNOWN="$LAB/known-unknown.json"
KNOWN_EMPTY="$LAB/known-empty.json"
SEMANTICS_MISMATCH="$LAB/semantics-mismatch.json"
PARTIAL="$LAB/partial.json"
NO_APPLICABLE="$LAB/no-applicable.json"
APPLICABLE_VETO="$LAB/applicable-veto.json"
MUSE_EXHAUSTED="$LAB/muse-exhausted.json"
MUSE_POSITIVE="$LAB/muse-positive.json"
AGY_POSITIVE="$LAB/agy-positive.json"
TOON="$LAB/quota.toon"
RENDERER_TOON="$LAB/renderer-quota.toon"
EMPTY_TOON="$LAB/empty-quota.toon"
EMPTY_ARRAY_TOON="$LAB/empty-array-quota.toon"
INLINE_ATTENTION_TOON="$LAB/inline-attention-quota.toon"
WHITESPACE_ATTENTION_TOON="$LAB/whitespace-attention-quota.toon"
TRUNCATED_ZERO_TOON="$LAB/truncated-zero-quota.toon"
MALFORMED_ZERO_TOON="$LAB/malformed-zero-quota.toon"
LEADING_GARBAGE_TOON="$LAB/leading-garbage-quota.toon"
LEADING_GARBAGE_NONZERO_TOON="$LAB/leading-garbage-nonzero-quota.toon"
TRAILING_GARBAGE_NONZERO_TOON="$LAB/trailing-garbage-nonzero-quota.toon"
TRUNCATED_NONZERO_TOON="$LAB/truncated-nonzero-quota.toon"
MALFORMED_COUNTED_TOON="$LAB/malformed-counted-quota.toon"
UNKNOWN_EXHAUSTED_TOON="$LAB/unknown-exhausted-quota.toon"
TRAILING_EMPTY_TOON="$LAB/trailing-empty-quota.toon"
QUOTED_TOON="$LAB/quoted-quota.toon"
SCHEMA6="$LAB/schema6.json"
SCHEMA5_PAIR="$LAB/schema5-pair.json"
SCHEMA6_KEYLESS="$LAB/schema6-keyless.json"
SCHEMA6_DUPLICATE="$LAB/schema6-duplicate.json"
SCHEMA6_TOON="$LAB/schema6-quota.toon"
FAKEBIN="$LAB/fakebin"
CALLS="$LAB/calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$FAKEBIN"
mkdir -p "$LAB/home/config"
mkdir -p "$LAB/user-home/.claude" "$LAB/project/.claude"
export HOME="$LAB/user-home"
export FM_BACKEND=tmux
unset BACKEND TMUX
export FM_AUTH_DESTINATION="$LAB/tmux-auth"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  show-environment)
    [ "${FM_AUTH_UNREADABLE:-0}" = 0 ] || exit 1
    if { [ "$2" = -g ] && [ "$#" = 2 ]; } || { [ "$2" = -t ] && [ "$#" = 3 ]; }; then exit 0; fi
    name=${!#}
    file=$FM_AUTH_DESTINATION
    [ "$2" != -g ] || file=$FM_AUTH_DESTINATION.global
    [ -f "$file" ] || exit 1
    while IFS= read -r entry; do
      case "$entry" in "$name"=*|-"$name") printf '%s\n' "$entry"; exit 0 ;; esac
    done < "$file"
    exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
[ "$1" = usage ] || exit 2
[ "${OMP_USAGE_FAIL:-0}" = 0 ] || exit 7
[ "${OMP_USAGE_EMPTY:-0}" = 0 ] || exit 0
if [ "${OMP_USAGE_INVALID:-0}" != 0 ]; then printf 'not-json\n'; exit 0; fi
remaining=${OMP_POOL_REMAINING:-20}
if [ -n "${OMP_AUTH_SELECTOR:-}" ]; then
  if [ "$OMP_AUTH_SELECTOR" = profile ]; then
    observed="profile=${OMP_PROFILE-${PI_PROFILE-}}"
  elif [ "${!OMP_AUTH_SELECTOR+x}" = x ]; then
    observed="$OMP_AUTH_SELECTOR=${!OMP_AUTH_SELECTOR}"
  else
    observed="-$OMP_AUTH_SELECTOR"
  fi
  [ "$observed" = "$OMP_AUTH_EXPECTED" ] || remaining=0
fi
jq -n --argjson now "$(date +%s)" --argjson remaining "$remaining" '
  {reports:[{provider:"openai-codex",fetchedAt:($now*1000),
    limits:[{scope:{shared:true},amount:{unit:"percent",remaining:$remaining}}]}]}'
SH
chmod +x "$FAKEBIN/omp"

cat > "$FIXTURE" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "kimi",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 0,
            "runway": { "status": "exhausted_now" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 20,
            "runway": { "status": "projected_exhaustion" }
          },
          {
            "scope": "model:codex_bengalfox",
            "status": "known",
            "effectivePercentRemaining": 0,
            "runway": { "status": "exhausted_now" }
          }
        ]
      }
    },
    {
      "provider": "pi",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 50,
            "runway": { "status": "through_reset" }
          }
        ]
      }
    },
    {
      "provider": "claude",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 0.5,
            "runway": { "status": "through_reset" }
          },
          {
            "scope": "model:fable",
            "status": "known",
            "effectivePercentRemaining": 0,
            "runway": { "status": "exhausted_now" }
          }
        ]
      }
    },
    {
      "provider": "cursor",
      "windows": [],
      "quotaSemantics": {
        "status": "unknown",
        "effectiveAvailability": []
      }
    }
  ]
}
JSON

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "${QUOTA_AXI_CALLS:?}"
if [ "${1:-}" = "--version" ]; then
  echo "quota-axi 0.1.51"
  exit 0
fi
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" "$FAKEBIN/quota-axi" --json > "$LAB/captured.json"

call_choose() {
  local output rc call_count
  output=$(cd "${CHOOSE_CWD:-$LAB/project}" && QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" \
    PATH="$FAKEBIN:$PATH" FM_HOME="$LAB/home" "$BIN/fm-quota-choose.sh" "$@")
  rc=$?
  call_count=$(wc -l < "$CALLS" | tr -d '[:space:]')
  [ "$call_count" = 1 ] || fail "helper took an additional quota snapshot"
  printf '%s\n' "$output"
  return "$rc"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

ok() {
  printf 'ok - %s\n' "$1"
}

if help=$("$BIN/fm-quota-choose.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq \
  "candidate order and every candidate's provider is the harness's primary family." \
  || fail "help omitted the multi-provider usage restriction"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then
  fail "help leaked executable source"
fi
ok "help renders the complete header only"

# 1. First candidate with positive effective quota.
out=$(call_choose --snapshot "$LAB/captured.json" --candidate kimi:default --candidate codex:model:codex_bengalfox --candidate claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "first positive: expected 'claude claude-3-5-sonnet', got '$out'"
ok "first positive candidate wins"

# 2. Exhausted provider is skipped.
out=$(call_choose --snapshot "$LAB/captured.json" --candidate kimi:default --candidate claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "exhausted skip: expected 'claude claude-3-5-sonnet', got '$out'"
ok "exhausted provider is skipped"

# 3. No candidates have positive quota.
if out=$(call_choose --snapshot "$LAB/captured.json" --candidate kimi:default 2>/dev/null); then
  fail "no positive: expected exit 1, got exit 0 with '$out'"
fi
[ "$out" = "none" ] || fail "no positive: expected 'none', got '$out'"
ok "no positive candidate returns none and exit 1"

# 4. Positional arguments work.
out=$(call_choose --snapshot "$LAB/captured.json" claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "positional: expected 'claude claude-3-5-sonnet', got '$out'"
ok "positional candidates work"

# 5. A model-specific exhausted scope bounds a healthy all-models scope.
if out=$(call_choose --snapshot "$LAB/captured.json" --candidate codex:model:codex_bengalfox 2>/dev/null); then
  fail "specific scope: expected exit 1, got exit 0 with '$out'"
fi
[ "$out" = "none" ] || fail "specific scope: expected 'none', got '$out'"
ok "specific model scope bounds generic quota"

if out=$(OMP_POOL_REMAINING=0 call_choose --snapshot "$LAB/captured.json" --candidate omp:openai-codex/gpt-6.1-sol 2>/dev/null); then
  fail "OMP pool exhaustion must veto a positive single-account snapshot"
fi
[ "$out" = none ] || fail "exhausted OMP pool returned '$out'"
jq '(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$LAB/captured.json" > "$LAB/single-exhausted.json"
out=$(call_choose --snapshot "$LAB/single-exhausted.json" --candidate omp:openai-codex/gpt-6.1-sol)
[ "$out" = "omp openai-codex/gpt-6.1-sol" ] || fail "a healthy OMP sibling must survive single-account exhaustion: '$out'"
ok "OMP Codex uses its pooled accounts rather than the single-account snapshot"
saved_home=$HOME
for selector in HOME PI_CODING_AGENT_DIR PI_CONFIG_DIR OMP_PROFILE PI_PROFILE XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; do
  case "$selector" in
    OMP_PROFILE|PI_PROFILE) caller=caller; destination=destination ;;
    PI_CONFIG_DIR) caller=.caller-omp; destination=.destination-omp ;;
    *) caller="$LAB/caller-auth"; destination="$LAB/destination-auth" ;;
  esac
  export "$selector=$caller"
  printf '%s=%s\n' "$selector" "$destination" > "$FM_AUTH_DESTINATION"
  printf '%s=%s\n' "$selector" "$destination" > "$FM_AUTH_DESTINATION.global"
  out=$(OMP_AUTH_SELECTOR=$selector OMP_AUTH_EXPECTED="$selector=$caller" call_choose --snapshot "$LAB/single-exhausted.json" \
    --candidate omp:openai-codex/gpt-6.1-sol --candidate omp:openai-codex/gpt-6-luna)
  [ "$out" = "omp openai-codex/gpt-6.1-sol" ] || fail "$selector lost worker headroom to exhausted destination: $out"
  out=$(OMP_AUTH_SELECTOR=$selector OMP_AUTH_EXPECTED="$selector=$destination" call_choose --snapshot "$LAB/captured.json" \
    --candidate omp:openai-codex/gpt-6.1-sol --candidate omp:openai-codex/gpt-6-luna --candidate claude:default)
  [ "$out" = "claude default" ] || fail "$selector borrowed destination headroom for exhausted worker: $out"
  printf '%s\n' PATH > "$LAB/home/config/launch-env-allowlist"
  printf -- '-%s\n' "$selector" > "$FM_AUTH_DESTINATION"
  out=$(OMP_AUTH_SELECTOR=$selector OMP_AUTH_EXPECTED="$selector=$caller" call_choose --snapshot "$LAB/single-exhausted.json" \
    --candidate omp:openai-codex/gpt-6.1-sol)
  [ "$out" = "omp openai-codex/gpt-6.1-sol" ] || fail "$selector followed future allowlist or session removal: $out"
  export "$selector="
  out=$(OMP_AUTH_SELECTOR=$selector OMP_AUTH_EXPECTED="$selector=" call_choose --snapshot "$LAB/single-exhausted.json" \
    --candidate omp:openai-codex/gpt-6.1-sol)
  [ "$out" = "omp openai-codex/gpt-6.1-sol" ] || fail "$selector did not preserve inherited empty value: $out"
  unset "$selector"
  out=$(OMP_AUTH_SELECTOR=$selector OMP_AUTH_EXPECTED="-$selector" call_choose --snapshot "$LAB/single-exhausted.json" \
    --candidate omp:openai-codex/gpt-6.1-sol)
  [ "$out" = "omp openai-codex/gpt-6.1-sol" ] || fail "$selector did not preserve inherited unset value: $out"
  rm "$LAB/home/config/launch-env-allowlist" "$FM_AUTH_DESTINATION" "$FM_AUTH_DESTINATION.global"
  export HOME=$saved_home
done
printf '%s\n' 'OMP_PROFILE=destination' 'PI_PROFILE=destination' > "$FM_AUTH_DESTINATION"
out=$(OMP_PROFILE='' PI_PROFILE=legacy OMP_AUTH_SELECTOR=profile OMP_AUTH_EXPECTED=profile= \
  call_choose --snapshot "$LAB/single-exhausted.json" --candidate omp:openai-codex/gpt-6.1-sol)
[ "$out" = "omp openai-codex/gpt-6.1-sol" ] || fail "empty worker OMP_PROFILE failed to mask legacy profile: $out"
out=$(PI_PROFILE=legacy OMP_AUTH_SELECTOR=profile OMP_AUTH_EXPECTED=profile=legacy \
  call_choose --snapshot "$LAB/single-exhausted.json" --candidate omp:openai-codex/gpt-6.1-sol)
[ "$out" = "omp openai-codex/gpt-6.1-sol" ] || fail "unset worker OMP_PROFILE failed to use worker legacy profile: $out"
out=$(OMP_AUTH_SELECTOR=profile OMP_AUTH_EXPECTED=profile= \
  call_choose --snapshot "$LAB/single-exhausted.json" --candidate omp:openai-codex/gpt-6.1-sol)
[ "$out" = "omp openai-codex/gpt-6.1-sol" ] || fail "unset worker profiles borrowed destination profile: $out"
rm "$FM_AUTH_DESTINATION"
for backend in tmux herdr; do
  out=$(FM_BACKEND=$backend FM_AUTH_UNREADABLE=1 call_choose --snapshot "$LAB/single-exhausted.json" \
    --candidate omp:openai-codex/gpt-6.1-sol)
  [ "$out" = "omp openai-codex/gpt-6.1-sol" ] || fail "$backend unavailable tmux concealed worker pool: $out"
done
for scope_failure in usage empty invalid; do
  case "$scope_failure" in
    usage) out=$(OMP_USAGE_FAIL=1 call_choose --snapshot "$LAB/captured.json" \
      --candidate omp:openai-codex/gpt-6.1-sol --candidate omp:openai-codex/gpt-6-luna 2>/dev/null); rc=$? ;;
    empty) out=$(OMP_USAGE_EMPTY=1 call_choose --snapshot "$LAB/captured.json" \
      --candidate omp:openai-codex/gpt-6.1-sol --candidate omp:openai-codex/gpt-6-luna 2>/dev/null); rc=$? ;;
    invalid) out=$(OMP_USAGE_INVALID=1 call_choose --snapshot "$LAB/captured.json" \
      --candidate omp:openai-codex/gpt-6.1-sol --candidate omp:openai-codex/gpt-6-luna 2>/dev/null); rc=$? ;;
  esac
  [ "$rc:$out" = 1:none ] || fail "$scope_failure OMP usage unexpectedly dispatched: $rc:$out"
done
ok "OMP chooser measures inherited worker selectors independent of destination and backend"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate omp:ollama/qwen3:8b --candidate claude:claude-3-5-sonnet 2>&1); then
  fail "unmapped omp prefix unexpectedly selected a later candidate"
fi
[ "$err" = "error: omp quota mapping covers only the openai-codex and claude-bridge prefixes: ollama/qwen3:8b" ] || fail "unmapped omp prefix returned: $err"
if err=$(call_choose --snapshot "$LAB/captured.json" --candidate omp 2>&1); then
  fail "bare omp candidate unexpectedly selected"
fi
[ "$err" = "error: omp quota mapping covers only the openai-codex and claude-bridge prefixes: default" ] || fail "bare omp candidate returned: $err"
ok "omp without a mapped prefix fails closed"

out=$(call_choose --snapshot "$LAB/captured.json" --candidate codex:default)
[ "$out" = "codex default" ] || fail "default scope: expected provider-wide quota, got '$out'"
ok "default model uses provider-wide quota"

out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "fractional quota: expected positive candidate, got '$out'"
ok "fractional positive quota is eligible"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate bogus:model --candidate claude:claude-3-5-sonnet 2>&1); then
  fail "unknown harness unexpectedly selected a later candidate"
fi
[ "$err" = "error: unknown harness: bogus" ] || fail "unknown harness returned: $err"
ok "unknown harness fails closed"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate rovo:default 2>&1); then
  fail "trailing unsupported harness was hidden by an earlier selection"
fi
[ "$err" = "error: unknown harness: rovo" ] || fail "trailing unsupported harness returned: $err"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate 'claude:' 2>&1); then
  fail "trailing empty model was hidden by an earlier selection"
fi
[ "$err" = "error: invalid candidate: claude:" ] || fail "trailing empty model returned: $err"
ok "all candidates are validated before selection"

printf '{"schemaVersion":5,"providers":{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}}\n' > "$MALFORMED"
if err=$(call_choose --snapshot "$MALFORMED" --candidate claude:default 2>&1); then
  fail "malformed provider collection unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "malformed provider data returned: $err"
ok "malformed provider data fails closed"

printf '{"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}\n' > "$MULTI_JSON"
cat "$LAB/captured.json" >> "$MULTI_JSON"
if err=$(call_choose --snapshot "$MULTI_JSON" --candidate claude:default 2>&1); then
  fail "multiple JSON values unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "multiple JSON values returned: $err"
ok "multiple JSON values fail closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = []' \
  "$LAB/captured.json" > "$KNOWN_EMPTY"
if err=$(call_choose --snapshot "$KNOWN_EMPTY" --candidate claude:default 2>&1); then
  fail "known-empty quota unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "known-empty quota returned: $err"
ok "known-empty quota fails closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.status) = "unknown"' \
  "$LAB/captured.json" > "$SEMANTICS_MISMATCH"
if err=$(call_choose --snapshot "$SEMANTICS_MISMATCH" --candidate claude:default 2>&1); then
  fail "unknown semantics with known entries unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "semantics mismatch returned: $err"
ok "semantics and availability statuses must agree"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [{"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}]' \
  "$LAB/captured.json" > "$UNKNOWN_EXHAUSTED"
if out=$(call_choose --snapshot "$UNKNOWN_EXHAUSTED" --candidate claude:default 2>/dev/null); then
  fail "unknown headroom with exhausted runway unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "unknown exhausted quota returned: $out"
ok "exhausted runway vetoes unknown headroom"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [{"scope":"all_models","status":"unknown","runway":{"status":"unknown"}}]' \
  "$LAB/captured.json" > "$KNOWN_UNKNOWN"
if out=$(call_choose --snapshot "$KNOWN_UNKNOWN" --candidate claude:default 2>/dev/null); then
  fail "unknown headroom unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "unknown headroom returned: $out"
ok "unknown headroom is not positive quota"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.status) = "partial" |
    (.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) += [{"scope":"model:unmeasured","status":"unknown","runway":{"status":"unknown"}}]' \
  "$LAB/captured.json" > "$PARTIAL"
out=$(call_choose --snapshot "$PARTIAL" --candidate claude:default)
[ "$out" = "claude default" ] || fail "valid partial semantics were rejected: $out"
ok "partial semantics accept mixed availability"

out=$(call_choose --candidate claude:default < "$LAB/captured.json")
[ "$out" = "claude default" ] || fail "stdin snapshot returned '$out'"
ok "stdin snapshot is accepted"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate 'claude:' 2>&1); then
  fail "empty model candidate unexpectedly dispatched"
fi
[ "$err" = "error: invalid candidate: claude:" ] || fail "empty model candidate returned: $err"
ok "empty model candidate fails closed"

# A bare harness with no colon means the default model.
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude)
[ "$out" = "claude default" ] || fail "bare harness: expected 'claude default', got '$out'"
ok "bare harness maps to default model"

for scope_file in claude-launcher claude-account; do
  case "$scope_file" in
    claude-launcher) printf 'teamclaude\n' > "$LAB/home/config/$scope_file" ;;
    claude-account) printf 'different-account\n' > "$LAB/home/config/$scope_file" ;;
  esac
  out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
  [ "$out" = "claude default" ] || fail "future Claude account or launcher concealed worker native headroom: $out"
  out=$(ANTHROPIC_API_KEY=worker-alternate call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
  [ "$out" = "codex gpt-6.1-sol" ] || fail "future Claude account or launcher replaced alternate worker auth: $out"
  rm "$LAB/home/config/$scope_file"
done
ok "future Claude account and launcher do not classify worker authentication"

export CLAUDE_CONFIG_DIR="$LAB/alternate-claude"
printf 'PATH\n' > "$LAB/home/config/launch-env-allowlist"
printf '%s\n' '-CLAUDE_CONFIG_DIR' > "$FM_AUTH_DESTINATION"
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
[ "$out" = "codex gpt-6.1-sol" ] || fail "ambient alternate Claude authentication used native headroom: $out"
if out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default 2>/dev/null); then
  fail "ambient alternate Claude authentication unexpectedly ranked native quota"
fi
[ "$out" = none ] || fail "unmapped ambient Claude authentication returned: $out"
export CLAUDE_CONFIG_DIR=''
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default)
[ "$out" = "claude default" ] || fail "empty ambient config directory discarded native default headroom: $out"
unset CLAUDE_CONFIG_DIR
rm "$LAB/home/config/launch-env-allowlist" "$FM_AUTH_DESTINATION"
ok "ambient alternate Claude authentication has no native default quota mapping"

CLAUDE_EXHAUSTED="$LAB/claude-exhausted.json"
jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$LAB/captured.json" > "$CLAUDE_EXHAUSTED"
for credential in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS; do
  export "$credential=worker-alternate"
  printf -- '-%s\n' "$credential" > "$FM_AUTH_DESTINATION"
  for policy in inherited retained stripped; do
    case "$policy" in
      inherited) rm -f "$LAB/home/config/launch-env-allowlist" ;;
      retained) printf '%s\n' "$credential" > "$LAB/home/config/launch-env-allowlist" ;;
      stripped) printf 'PATH\n' > "$LAB/home/config/launch-env-allowlist" ;;
    esac
    out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
    [ "$out" = "codex gpt-6.1-sol" ] || fail "$credential $policy borrowed native quota despite worker auth: $out"
    if out=$(call_choose --snapshot "$CLAUDE_EXHAUSTED" --candidate claude:default 2>/dev/null); then
      fail "$credential $policy unexpectedly selected unmapped worker auth: $out"
    fi
    [ "$out" = none ] || fail "$credential $policy unmapped worker auth returned: $out"
  done
  export "$credential="
  out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default)
  [ "$out" = "claude default" ] || fail "empty $credential concealed native worker quota: $out"
  unset "$credential"
  printf '%s=destination-alternate\n' "$credential" > "$FM_AUTH_DESTINATION"
  printf '%s=destination-global\n' "$credential" > "$FM_AUTH_DESTINATION.global"
  out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default)
  [ "$out" = "claude default" ] || fail "$credential destination-only auth concealed worker quota: $out"
  rm "$FM_AUTH_DESTINATION" "$FM_AUTH_DESTINATION.global"
done
rm "$LAB/home/config/launch-env-allowlist"
for selector in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE; do
  for value in 1 true TRUE yes YeS on ON; do
    export "$selector=$value"
    out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
    [ "$out" = "codex gpt-6.1-sol" ] || fail "$selector=$value borrowed native worker quota: $out"
  done
  for value in '' 0 false FALSE no off enabled; do
    export "$selector=$value"
    printf '%s=true\n' "$selector" > "$FM_AUTH_DESTINATION"
    out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default)
    [ "$out" = "claude default" ] || fail "$selector=$value lost native worker quota: $out"
  done
  unset "$selector"
  rm "$FM_AUTH_DESTINATION"
done
out=$(ANTHROPIC_FEDERATION_RULE_ID=worker-rule ANTHROPIC_ORGANIZATION_ID=worker-org \
  call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
[ "$out" = "codex gpt-6.1-sol" ] || fail "paired worker federation borrowed native quota: $out"
for pair in rule-only organization-only empty-rule empty-organization; do
  case "$pair" in
    rule-only) out=$(ANTHROPIC_FEDERATION_RULE_ID=worker-rule call_choose --snapshot "$LAB/captured.json" --candidate claude:default) ;;
    organization-only) out=$(ANTHROPIC_ORGANIZATION_ID=worker-org call_choose --snapshot "$LAB/captured.json" --candidate claude:default) ;;
    empty-rule) out=$(ANTHROPIC_FEDERATION_RULE_ID='' ANTHROPIC_ORGANIZATION_ID=worker-org call_choose --snapshot "$LAB/captured.json" --candidate claude:default) ;;
    empty-organization) out=$(ANTHROPIC_FEDERATION_RULE_ID=worker-rule ANTHROPIC_ORGANIZATION_ID='' call_choose --snapshot "$LAB/captured.json" --candidate claude:default) ;;
  esac
  [ "$out" = "claude default" ] || fail "$pair federation concealed native worker quota: $out"
done
printf '%s\n' 'CLAUDE_CONFIG_DIR=destination' 'ANTHROPIC_FEDERATION_RULE_ID=destination' 'ANTHROPIC_ORGANIZATION_ID=destination' > "$FM_AUTH_DESTINATION"
for backend in tmux herdr; do
  out=$(FM_BACKEND=$backend FM_AUTH_UNREADABLE=1 call_choose --snapshot "$LAB/captured.json" --candidate claude:default)
  [ "$out" = "claude default" ] || fail "$backend unavailable destination concealed native worker quota: $out"
  out=$(FM_BACKEND=$backend ANTHROPIC_API_KEY=worker-only call_choose --snapshot "$LAB/captured.json" \
    --candidate claude:default --candidate codex:gpt-6.1-sol)
  [ "$out" = "codex gpt-6.1-sol" ] || fail "$backend worker key borrowed native quota: $out"
done
rm "$FM_AUTH_DESTINATION"
ok "native Claude classification uses worker selectors, truth switches and paired federation"

for source in "$LAB/user-home/.claude/settings.json" "$LAB/user-home/.claude/remote-settings.json" \
  "$LAB/project/.claude/settings.json" "$LAB/project/.claude/settings.local.json" \
  "$LAB/repository/managed/macos/managed-settings.json" "$LAB/repository/managed/macos/managed-settings.d/auth.json" \
  "$LAB/repository/managed/linux/managed-settings.json" "$LAB/repository/managed/linux/managed-settings.d/auth.json"; do
  for helper in apiKeyHelper policyHelper; do
    jq -n --arg helper "$helper" --arg command "touch '$LAB/helper-ran'; printf settings-secret" \
      '{($helper):$command}' > "$source"
    out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol 2>&1)
    [ "$out" = "codex gpt-6.1-sol" ] || fail "$source $helper borrowed default quota or leaked helper: $out"
    [ ! -e "$LAB/helper-ran" ] || fail "quota chooser executed $helper"
    if out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default 2>&1); then
      fail "$source $helper ranked a Claude-only candidate"
    fi
    [ "$out" = none ] || fail "$source $helper leaked settings: $out"
  done
  for selector in forceLoginMethod forceLoginGatewayUrl; do
    case "$selector" in
      forceLoginMethod) value=gateway ;;
      forceLoginGatewayUrl) value=https://gateway.invalid ;;
    esac
    jq -n --arg selector "$selector" --arg value "$value" '{($selector):$value}' > "$source"
    out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol 2>&1)
    [ "$out" = "codex gpt-6.1-sol" ] || fail "$source $selector borrowed or leaked default quota: $out"
    if out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default 2>&1); then
      fail "$source $selector ranked an unbound Claude candidate"
    fi
    [ "$out" = none ] || fail "$source $selector leaked settings: $out"
  done
  for selector in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR ANTHROPIC_PROFILE \
    CLAUDE_CONFIG_DIR HOME ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_FEDERATION_RULE_ID ANTHROPIC_ORGANIZATION_ID \
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE; do
    jq -n --arg selector "$selector" '{env:{($selector):"settings-secret"}}' > "$source"
    out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol 2>&1)
    [ "$out" = "codex gpt-6.1-sol" ] || fail "$source $selector borrowed or leaked default quota: $out"
  done
  for body in '{' '[]' '{"env":[]}' '{"env":{"ANTHROPIC_API_KEY":""}}' '{"env":{"CLAUDE_CODE_USE_BEDROCK":"false"}}'; do
    printf '%s\n' "$body" > "$source"
    out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
    [ "$out" = "codex gpt-6.1-sol" ] || fail "$source uncertain settings borrowed default quota: $out"
  done
  printf '%s\n' '{"model":"opus","permissions":{"allow":[]},"hooks":{},"env":{},"apiKeyHelper":"","forceLoginMethod":"","forceLoginGatewayUrl":""}' > "$source"
  out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default)
  [ "$out" = "claude default" ] || fail "$source neutral settings concealed default quota: $out"
  chmod 000 "$source"
  if [ ! -r "$source" ]; then
    out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
    [ "$out" = "codex gpt-6.1-sol" ] || fail "$source unreadable settings borrowed default quota: $out"
  fi
  chmod 600 "$source"
  rm "$source"
  ln -s "$LAB/missing-settings" "$source"
  out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
  [ "$out" = "codex gpt-6.1-sol" ] || fail "$source dangling settings borrowed default quota: $out"
  rm "$source"
  mkdir "$source"
  out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
  [ "$out" = "codex gpt-6.1-sol" ] || fail "$source nonregular settings borrowed default quota: $out"
  rmdir "$source"
done
printf '%s\n' '{"env":{"ANTHROPIC_ORGANIZATION_ID":"settings-org"}}' > "$LAB/project/.claude/settings.json"
out=$(ANTHROPIC_FEDERATION_RULE_ID=worker-rule call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
[ "$out" = "codex gpt-6.1-sol" ] || fail "cross-source federation borrowed default quota: $out"
rm "$LAB/project/.claude/settings.json"
git -C "$LAB/project" init -q
mkdir -p "$LAB/project/subdir"
printf '%s\n' '{"apiKeyHelper":"false"}' > "$LAB/project/.claude/settings.json"
out=$(CHOOSE_CWD="$LAB/project/subdir" call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate codex:gpt-6.1-sol)
[ "$out" = "codex gpt-6.1-sol" ] || fail "subdirectory chooser missed actual project settings: $out"
rm "$LAB/project/.claude/settings.json"
mkdir -p "$LAB/sibling/.claude"
printf '%s\n' '{"apiKeyHelper":"false"}' > "$LAB/sibling/.claude/settings.json"
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default)
[ "$out" = "claude default" ] || fail "unrelated sibling settings concealed default quota: $out"
ok "chooser inspects inherited settings without executing helpers or leaking credentials"

cat > "$TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  codex,all_models,20,-1,through_reset,high,weekly,2030-01-02T00:00:00Z
  claude,all_models,0.5,-1,through_reset,high,weekly,2030-01-02T00:00:00Z
exhaustion[0]:
attention[0]:
TOON
out=$(call_choose --snapshot "$TOON" --candidate claude:default)
[ "$out" = "claude default" ] || fail "default TOON snapshot returned '$out'"
ok "default TOON snapshot is accepted"

cat > "$RENDERER_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z"
exhaustion: []
attention: []
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
out=$(call_choose --snapshot "$RENDERER_TOON" --candidate claude:default)
[ "$out" = "claude default" ] || fail "renderer-shaped TOON snapshot returned: $out"
ok "renderer-shaped TOON snapshot is accepted"

printf 'garbage\n' > "$LEADING_GARBAGE_NONZERO_TOON"
cat "$TOON" >> "$LEADING_GARBAGE_NONZERO_TOON"
cat "$TOON" > "$TRAILING_GARBAGE_NONZERO_TOON"
printf 'garbage\n' >> "$TRAILING_GARBAGE_NONZERO_TOON"
sed '$d' "$TOON" > "$TRUNCATED_NONZERO_TOON"
for malformed_toon in \
  "$LEADING_GARBAGE_NONZERO_TOON" \
  "$TRAILING_GARBAGE_NONZERO_TOON" \
  "$TRUNCATED_NONZERO_TOON"; do
  if err=$(call_choose --snapshot "$malformed_toon" --candidate claude:default 2>&1); then
    fail "malformed nonzero TOON unexpectedly dispatched: $malformed_toon"
  fi
  [ "$err" = "error: invalid quota-axi snapshot" ] \
    || fail "malformed nonzero TOON returned: $err"
done
ok "malformed nonzero TOON envelopes fail closed"

cat > "$EMPTY_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[0]:
exhaustion[0]:
attention[0]:
TOON
if out=$(call_choose --snapshot "$EMPTY_TOON" --candidate claude:default 2>/dev/null); then
  fail "zero-row TOON unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "zero-row TOON returned: $out"
ok "zero-row TOON has no positive quota"

cat > "$EMPTY_ARRAY_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention[1]{provider,scope,kind,detail,remedy}:
  claude,all_models,error,"request failed, retry later",none
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
if out=$(call_choose --snapshot "$EMPTY_ARRAY_TOON" --candidate claude:default 2>/dev/null); then
  fail "empty-array TOON unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "empty-array TOON returned: $out"
ok "empty-array TOON has no positive quota"

cat > "$INLINE_ATTENTION_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention: [{"provider":"claude","scope":"all_models","kind":"unmeasurable","detail":"unknown quota","remedy":"none"}]
TOON
if out=$(call_choose --snapshot "$INLINE_ATTENTION_TOON" --candidate claude:default 2>/dev/null); then
  fail "inline attention TOON unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "inline attention TOON returned: $out"
ok "inline attention TOON has no positive quota"

cat > "$WHITESPACE_ATTENTION_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention[1]{provider,scope,kind,detail,remedy}:
  claude,all_models ,unmeasurable,unknown quota,none
TOON
if err=$(call_choose --snapshot "$WHITESPACE_ATTENTION_TOON" --candidate claude:default 2>&1); then
  fail "whitespace attention scope unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "whitespace attention scope returned: $err"
ok "TOON attention identities fail closed"

cat > "$TRUNCATED_ZERO_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota: []
TOON
if err=$(call_choose --snapshot "$TRUNCATED_ZERO_TOON" --candidate claude:default 2>&1); then
  fail "truncated zero-row TOON unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "truncated zero-row TOON returned: $err"
ok "truncated zero-row TOON fails closed"

cat > "$MALFORMED_ZERO_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[0]:
garbage
TOON
if err=$(call_choose --snapshot "$MALFORMED_ZERO_TOON" --candidate claude:default 2>&1); then
  fail "malformed zero-row TOON unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "malformed zero-row TOON returned: $err"
ok "malformed zero-row TOON fails closed"

cat > "$LEADING_GARBAGE_TOON" <<'TOON'
garbage
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[0]:
exhaustion[0]:
attention[0]:
TOON
if err=$(call_choose --snapshot "$LEADING_GARBAGE_TOON" --candidate claude:default 2>&1); then
  fail "zero-row TOON with leading garbage unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "leading garbage TOON returned: $err"
ok "zero-row TOON rejects leading garbage"

cat > "$MALFORMED_COUNTED_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z"
exhaustion[1]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  garbage
attention[0]:
TOON
if err=$(call_choose --snapshot "$MALFORMED_COUNTED_TOON" --candidate claude:default 2>&1); then
  fail "malformed counted TOON unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "malformed counted TOON returned: $err"
ok "counted TOON rows require every declared field"

cat > "$UNKNOWN_EXHAUSTED_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention[1]{provider,scope,kind,detail,remedy}:
  claude,all_models,headroom_unknown,"weekly · exhausted_now limited by weekly",none
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
if out=$(call_choose --snapshot "$UNKNOWN_EXHAUSTED_TOON" --candidate claude:default 2>/dev/null); then
  fail "TOON unknown headroom exhaustion unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "TOON unknown headroom exhaustion returned: $out"
ok "TOON conversion preserves unknown-headroom exhaustion"

cat > "$TRAILING_EMPTY_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z",
exhaustion[0]:
attention[0]:
TOON
if err=$(call_choose --snapshot "$TRAILING_EMPTY_TOON" --candidate claude:default 2>&1); then
  fail "TOON row with trailing empty field unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "trailing empty TOON field returned: $err"
ok "trailing empty TOON fields fail closed"

cat > "$QUOTED_TOON" <<'TOON'
bin: quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z"
  claude,"model:fable",0,-1,exhausted_now,high,weekly,"2030-01-02T00:00:00Z"
exhaustion[0]:
attention[0]:
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
if out=$(call_choose --snapshot "$QUOTED_TOON" --candidate claude:fable 2>/dev/null); then
  fail "quoted exhausted model scope unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "quoted exhausted model scope returned: $out"
ok "quoted TOON scope vetoes dispatch"

if out=$(call_choose --snapshot "$LAB/captured.json" --candidate cursor:default 2>/dev/null); then
  fail "provider-level unknown quota unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "provider-level unknown quota returned: $out"
ok "provider-level unknown quota is not positive"

jq '.providers += [{"provider":"meta","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":25,"runway":{"status":"through_reset"}}]}}]' \
  "$LAB/captured.json" > "$MUSE_POSITIVE"
out=$(call_choose --snapshot "$MUSE_POSITIVE" --candidate muse:default)
[ "$out" = "muse default" ] || fail "supported Muse candidate returned: $out"
ok "Muse candidate is accepted"

jq '.providers += [{"provider":"meta","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]' \
  "$LAB/captured.json" > "$MUSE_EXHAUSTED"
if out=$(call_choose --snapshot "$MUSE_EXHAUSTED" --candidate muse:default 2>/dev/null); then
  fail "Muse candidate dispatched with exhausted Meta quota"
fi
[ "$out" = "none" ] || fail "exhausted Meta quota returned: $out"
ok "Muse uses Meta quota"

jq '.providers += [{"provider":"agy","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":25,"runway":{"status":"through_reset"}}]}}]' \
  "$LAB/captured.json" > "$AGY_POSITIVE"
if err=$(call_choose --snapshot "$AGY_POSITIVE" --candidate agy:default 2>&1); then
  fail "legacy quota chooser unexpectedly accepted Agy"
fi
printf '%s\n' "$err" | grep -F 'unknown harness: agy' >/dev/null || fail "legacy Agy rejection changed: $err"
ok "Agy remains resolver-only"

jq '.providers += [.providers[] | select(.provider == "claude")]' "$LAB/captured.json" > "$DUPLICATE"
if err=$(call_choose --snapshot "$DUPLICATE" --candidate claude:default 2>&1); then
  fail "duplicate provider snapshot unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "duplicate provider returned: $err"
ok "duplicate providers fail closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].scope) = ""' \
  "$LAB/captured.json" > "$EMPTY_SCOPE"
if err=$(call_choose --snapshot "$EMPTY_SCOPE" --candidate claude:default 2>&1); then
  fail "empty quota scope unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "empty quota scope returned: $err"
ok "empty quota scopes fail closed"

jq '(.providers[] | select(.provider == "claude").provider) = " claude" |
    (.providers[] | select(.provider == " claude").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining) = 0 |
    (.providers[] | select(.provider == " claude").quotaSemantics.effectiveAvailability[0].runway.status) = "exhausted_now"' \
  "$LAB/captured.json" > "$WHITESPACE_PROVIDER"
if err=$(call_choose --snapshot "$WHITESPACE_PROVIDER" --candidate claude:default 2>&1); then
  fail "whitespace provider identity unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "whitespace provider returned: $err"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].scope) = "all_models "' \
  "$LAB/captured.json" > "$WHITESPACE_SCOPE"
if err=$(call_choose --snapshot "$WHITESPACE_SCOPE" --candidate claude:default 2>&1); then
  fail "whitespace scope identity unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "whitespace scope returned: $err"
ok "whitespace quota identities fail closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining) = 150' "$LAB/captured.json" > "$OUT_OF_RANGE"
if err=$(call_choose --snapshot "$OUT_OF_RANGE" --candidate claude:default 2>&1); then
  fail "out-of-range quota unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "out-of-range quota returned: $err"
ok "out-of-range quota fails closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].runway.status) = "invalid"' "$LAB/captured.json" > "$INVALID_RUNWAY"
if err=$(call_choose --snapshot "$INVALID_RUNWAY" --candidate claude:default 2>&1); then
  fail "invalid runway status unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "invalid runway status returned: $err"
ok "invalid runway status fails closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [{"scope":"model:other","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]' \
  "$LAB/captured.json" > "$NO_APPLICABLE"
if out=$(call_choose --snapshot "$NO_APPLICABLE" --candidate claude:fable 2>/dev/null); then
  fail "candidate without applicable quota unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "missing applicable quota returned: $out"
ok "missing applicable quota is not positive"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [
      {"scope":"all_models","status":"known","effectivePercentRemaining":10,"runway":{"status":"exhausted_now"}},
      {"scope":"model:foo","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}
    ]' "$LAB/captured.json" > "$APPLICABLE_VETO"
if out=$(call_choose --snapshot "$APPLICABLE_VETO" --candidate claude:foo 2>/dev/null); then
  fail "provider-wide exhausted scope did not veto the candidate"
fi
[ "$out" = "none" ] || fail "applicable exhausted scope returned: $out"
ok "any exhausted applicable scope vetoes dispatch"

if out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:fable 2>/dev/null); then
  fail "exact named model exhaustion unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "exact named model returned '$out'"
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:fable-2)
[ "$out" = "claude fable-2" ] || fail "named model scope overmatched fable-2: $out"
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default)
[ "$out" = "claude default" ] || fail "named model scope overmatched default: $out"
ok "named model quota matches exact identity only"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[1].status) = "typo"' "$LAB/captured.json" > "$INVALID_AVAILABILITY"
if err=$(call_choose --snapshot "$INVALID_AVAILABILITY" --candidate claude:default 2>&1); then
  fail "invalid availability status unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "invalid availability status returned: $err"
ok "invalid availability status fails closed"

# Schema 6: quota-axi keys every row by provider + accountKey once a provider
# expands to several accounts. Shaped like a real expanded snapshot: two codex
# rows with different keys and percentages plus default-keyed providers.
cat > "$SCHEMA6" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 6,
  "providers": [
    { "provider": "claude", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
    { "provider": "codex", "accountKey": "openai-codex", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 3, "runway": { "status": "projected_exhaustion" } } ] } },
    { "provider": "codex", "accountKey": "openai-codex-work", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 11, "runway": { "status": "projected_exhaustion" } } ] } },
    { "provider": "cursor", "accountKey": "default", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 24, "runway": { "status": "projected_exhaustion" } } ] } }
  ]
}
JSON
out=$(call_choose --snapshot "$SCHEMA6" --candidate codex:default --candidate cursor:default)
[ "$out" = "cursor default" ] || fail "schema 6 snapshot returned: $out"
ok "native Codex never infers an account from a Pi lane"

SCHEMA6_NATIVE="$LAB/schema6-native.json"
jq '
  .providers |= map(if .provider == "codex" then
    .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    else . end) |
  (.providers[] | select(.accountKey == "openai-codex-work")) as $account |
  .providers += [($account | .accountKey = "default"),
    ($account | .accountKey = "codex-home" |
      .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 80 | .runway.status = "through_reset"))]
' "$SCHEMA6" > "$SCHEMA6_NATIVE"
for model in default gpt-5.6-sol; do
  out=$(call_choose --snapshot "$SCHEMA6_NATIVE" --candidate "codex:$model" --candidate cursor:default)
  [ "$out" = "codex $model" ] || fail "native Codex did not select codex-home for $model: $out"
done
jq '.providers |= reverse' "$SCHEMA6_NATIVE" > "$LAB/schema6-reversed.json"
out=$(call_choose --snapshot "$LAB/schema6-reversed.json" --candidate codex:default --candidate cursor:default)
[ "$out" = "codex default" ] || fail "native Codex selection depended on row order: $out"

jq '.providers |= map(select(.provider != "codex" or .accountKey != "default") |
  if .accountKey == "codex-home" then .accountKey = "default" else . end)' "$SCHEMA6_NATIVE" > "$LAB/schema6-default.json"
out=$(call_choose --snapshot "$LAB/schema6-default.json" --candidate codex:default --candidate cursor:default)
[ "$out" = "codex default" ] || fail "native Codex did not fall back to the default row: $out"
ok "native Codex binds to codex-home before default, independently of model and row order"

jq '.schemaVersion = 5 | .providers |= unique_by(.provider) | del(.providers[].accountKey)' "$SCHEMA6" > "$SCHEMA5_PAIR"
out=$(call_choose --snapshot "$SCHEMA5_PAIR" --candidate codex:default --candidate cursor:default)
[ "$out" = "codex default" ] || fail "schema 5 pair snapshot returned: $out"
ok "the same path still selects from a schema 5 snapshot by provider alone"

jq 'del(.providers[1].accountKey)' "$SCHEMA6" > "$SCHEMA6_KEYLESS"
if err=$(call_choose --snapshot "$SCHEMA6_KEYLESS" --candidate cursor:default 2>&1); then
  fail "schema 6 row without accountKey unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "keyless schema 6 row returned: $err"
jq '.providers[2].accountKey = "openai-codex"' "$SCHEMA6" > "$SCHEMA6_DUPLICATE"
if err=$(call_choose --snapshot "$SCHEMA6_DUPLICATE" --candidate cursor:default 2>&1); then
  fail "duplicate provider + accountKey unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "duplicate schema 6 key returned: $err"
ok "schema 6 requires accountKey on every row and uniqueness on provider + accountKey"

cat > "$SCHEMA6_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota[3]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  codex,openai-codex,all_models,3,-1.4788,projected_exhaustion,established,weekly,"2030-01-03T00:00:00Z"
  codex,openai-codex-work,all_models,11,-5.6818,projected_exhaustion,established,weekly,"2030-01-07T00:00:00Z"
  cursor,default,all_models,24,0.3917,projected_exhaustion,established,auto_usage,"2030-01-12T00:00:00Z"
exhaustion[2]{provider,accountKey,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  codex,openai-codex,all_models,11644,"2030-01-01T03:00:00Z",weekly
  codex,openai-codex-work,all_models,11447,"2030-01-01T03:00:00Z",weekly
attention[1]{provider,accountKey,scope,kind,detail,remedy}:
  claude,default,all,auth_required,keychain_prompt_required · reason keychain_access_required,quota-axi --allow-keychain-prompt
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
out=$(call_choose --snapshot "$SCHEMA6_TOON" --candidate claude:default --candidate codex:default --candidate cursor:default)
[ "$out" = "cursor default" ] || fail "schema 6 TOON snapshot returned: $out"
ok "schema 6 TOON with the accountKey column is accepted"

[ "$(wc -l < "$CALLS" | tr -d '[:space:]')" = 1 ] || fail "helper took an additional quota snapshot"
ok "helper reuses the captured quota snapshot"

printf '# all fm-quota-choose tests passed\n'
