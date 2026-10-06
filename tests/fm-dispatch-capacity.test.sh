#!/usr/bin/env bash
# Pooled capacity, uncertainty, explicit fallback permission, and account pins.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dispatch-capacity-lib.sh
. "$ROOT/bin/fm-dispatch-capacity-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-capacity)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$TMP_ROOT/config"
export FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
export OMP_USAGE_FIXTURE="$TMP_ROOT/usage.json" QUOTA_FIXTURE="$TMP_ROOT/quota.json"
unset CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN BACKEND TMUX
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  usage) cat "$OMP_USAGE_FIXTURE" ;;
  models) printf '%s\n' '{"models":[{"selector":"openrouter/z-ai/glm-5.3-flash"},{"selector":"openrouter/deepseek/deepseek-v4-flash"}]}' ;;
  *) exit 2 ;;
esac
SH
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "$QUOTA_FIXTURE"
SH
chmod +x "$FAKEBIN/omp" "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$PATH"
write_pool() {
  jq -n --argjson at "$(date +%s)" --argjson remaining "$1" '
    {reports: [
      {provider:"openai-codex", fetchedAt:($at*1000),
       metadata:{meterStates:{chat:{allowed:false,limitReached:true}}},
       limits:[{scope:{shared:true},amount:{unit:"percent",remaining:0}}], resetCredits:{availableCount:1}},
      {provider:"openai-codex", fetchedAt:($at*1000),
       limits:[{scope:{shared:true},amount:{unit:"percent",remaining:$remaining}}]}
    ]}' > "$OMP_USAGE_FIXTURE"
}
write_pool 98
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
assert_equals usable "$(jq -r .status <<<"$out")" "an exhausted account must not exhaust the pool"
assert_equals 1 "$(jq -r '.accounts[0].savedResets' <<<"$out")" "saved resets remain reported rather than redeemed"
assert_not_contains "$out" '@' "public evidence must not expose account identities"
write_pool 0
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol)
assert_equals exhausted "$(jq -r .status <<<"$out")" "a saved reset is not current headroom"
jq '.accountsWithoutUsage=[{provider:"openai-codex"}]' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/missing.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/missing.json")")
assert_equals unknown "$(jq -r .status <<<"$out")" "an unmeasured sibling prevents whole-pool exhaustion"
jq '.reports[1].fetchedAt=0' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/stale.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/stale.json")")
assert_equals unknown "$(jq -r .status <<<"$out")" "stale quota is not an exhaustion verdict"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol '{')
assert_equals unknown "$(jq -r .status <<<"$out")" "invalid vendor JSON does not authorize fallback"
jq '.reports[1].metadata={meterStates:{chat:{allowed:true,limitReached:false}}}' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/serving.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/serving.json")")
assert_equals usable "$(jq -r .status <<<"$out")" "a serving verdict remains authoritative even with zero percentage"
pass "pool capacity preserves serving, missing-account, freshness, and saved-reset semantics"

primary='{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"high"}'
allowed='[{"harness":"omp","model":"openrouter/z-ai/glm-5.3-flash","effort":"high"}]'
jq -n --argjson use "$primary" --argjson fallback "$allowed" '{rules:[{when:"easy work",use:$use,fallback:$fallback}],default:$use,default_fallback:$fallback}' > "$TMP_ROOT/config/crew-dispatch.json"
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openai-codex/gpt-6-luna high)
write_pool 98
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$(jq -c .fallback <<<"$set")")
assert_equals openai-codex/gpt-6-luna "$(jq -r .profile.model <<<"$out")" "native pooled capacity precedes paid model fallback"
write_pool 0
jq '.reports[1].metadata={source:"ratelimit-headers"} |
  .reports[1].limits[0].status="warning"' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/headers.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/headers.json")")
assert_equals usable "$(jq -r .status <<<"$out")" "native successful-response warnings do not authorize paid model fallback from zero percent"
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed")
assert_equals openrouter/z-ai/glm-5.3-flash "$(jq -r .profile.model <<<"$out")" "whole-pool exhaustion selects the permitted Luna stand-in"
assert_equals true "$(jq -r .switched <<<"$out")" "selection reports a model switch"
assert_equals unknown "$(jq -r .capacity.status <<<"$out")" "unknown fallback quota is disclosed, never invented"
if fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" '[]' > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "a route with no permitted stand-in must stop"
fi
strong='{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"}'
team='[{"harness":"claude","model":"claude-opus-5-5[1m]","effort":"high","requires":"teamclaude"}]'
# A bare Claude executable is not the required configured TeamClaude route,
# whether or not the separate launch-owner library has landed.
if fm_dispatch_select "$TMP_ROOT/config" rule_1 "$strong" "$team" > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "bare Claude must not impersonate the supported TeamClaude route"
fi
write_pool 98
jq '.rules[0].fallback=[]' "$TMP_ROOT/config/crew-dispatch.json" > "$TMP_ROOT/conflicting.json"
mv "$TMP_ROOT/conflicting.json" "$TMP_ROOT/config/crew-dispatch.json"
if fm_dispatch_fallbacks "$TMP_ROOT/config" '' omp openai-codex/gpt-6-luna high > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "different lists require an explicit rule rather than an arbitrary match"
fi
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openai-codex/gpt-6-luna high)
assert_equals '[]' "$(jq -c .fallback <<<"$set")" "an explicit rule retains its own no-fallback policy"
jq '.rules[0].fallback=[{harness:"claude",model:"opus",effort:"high"}]' "$TMP_ROOT/config/crew-dispatch.json" > "$TMP_ROOT/bad.json"
mv "$TMP_ROOT/bad.json" "$TMP_ROOT/config/crew-dispatch.json"
if fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openai-codex/gpt-6-luna high > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "Claude fallback without a supported TeamClaude requirement must refuse"
fi
pass "matrix fallback retains per-rule permission and strongest-model boundaries"

for container in scalar array; do
  for use in '{"harness":"claude"}' '{"harness":"claude","model":"","effort":""}' '{"harness":"claude","model":"default","effort":"default"}'; do
    jq -n --argjson use "$use" --arg container "$container" --argjson fallback "$allowed" '
      (if $container == "array" then [$use] else $use end) as $profiles |
      {rules:[{when:"default axes",use:$profiles,fallback:$fallback}],
       default:$profiles,default_fallback:$fallback}' > "$TMP_ROOT/config/crew-dispatch.json"
    for rule in rule_1 default; do
      for model in '' default; do
        for effort in '' default; do
          set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" "$rule" claude "$model" "$effort") ||
            fail "default axes must match $rule $container use"
          assert_equals "$rule" "$(jq -r .rule <<<"$set")" "default matching retains explicit rule identity"
          assert_equals "$allowed" "$(jq -c .fallback <<<"$set")" "default matching retains declared fallback"
          profile=$(jq -cn --arg model "$model" --arg effort "$effort" '{harness:"claude",model:$model,effort:$effort}')
          out=$(fm_dispatch_select "$TMP_ROOT/config" "$rule" "$profile" "$(jq -c .fallback <<<"$set")" '{"status":"unknown"}') ||
            fail "a matched default profile with unknown capacity must remain launchable"
          assert_equals false "$(jq -r .switched <<<"$out")" "unknown capacity must retain default profile"
          assert_equals "$profile" "$(jq -c .profile <<<"$out")" "matching must not rewrite launch profile"
        done
      done
    done
    set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" '' claude default '') ||
      fail "identical fallback lists must match normalized implicit defaults"
    assert_equals '' "$(jq -r .rule <<<"$set")" "identical rule/default lists do not invent a rule"
  done
done
if fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 claude sonnet default > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "a nondefault model must not match an omitted model"
fi
assert_contains "$(cat "$TMP_ROOT/error")" 'dispatch rule does not contain the requested profile' "unmatched profile remains a rule-membership failure"
jq -n --argjson fallback "$allowed" '
  {rules:[{use:{harness:"claude"},fallback:$fallback}],default:{harness:"claude"},default_fallback:[]}' > "$TMP_ROOT/config/crew-dispatch.json"
if fm_dispatch_fallbacks "$TMP_ROOT/config" '' claude default default > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "normalization must not conceal conflicting fallback permissions"
fi
assert_contains "$(cat "$TMP_ROOT/error")" 'different fallback lists match this profile' "normalized implicit ambiguity still requires a rule"
jq -n '{rules:[{use:{harness:"omp",model:"openai-codex/gpt-6-luna",effort:"high"},
  fallback:[{harness:"omp",model:"default",effort:"high"}]}]}' > "$TMP_ROOT/config/crew-dispatch.json"
for model in '' default; do
  set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp "$model" high) ||
    fail "fallback comparisons must normalize default model representations"
  assert_equals rule_1 "$(jq -r .rule <<<"$set")" "a default fallback remains a member of its rule"
done
jq '.rules[0].fallback[0].effort="default"' "$TMP_ROOT/config/crew-dispatch.json" > "$TMP_ROOT/bad-default.json"
mv "$TMP_ROOT/bad-default.json" "$TMP_ROOT/config/crew-dispatch.json"
if fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp default default > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "normalization must not turn invalid fallback effort into a valid profile"
fi
assert_contains "$(cat "$TMP_ROOT/error")" 'fallback must be an array of explicit OMP profiles' "invalid fallback differs from an unmatched valid profile"
pass "shared matching normalizes default axes without weakening fallback validation"

cat > "$QUOTA_FIXTURE" <<'JSON'
{"schemaVersion":6,"providers":[
 {"provider":"claude","accountKey":"other","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0}]}},
 {"provider":"claude","accountKey":"default","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70}]}}
]}
JSON
out=$(fm_dispatch_capacity claude claude-sonnet-5-5)
assert_equals usable "$(jq -r .status <<<"$out")" "another Claude account must not veto the selected default"
printf 'pinned-account\n' > "$TMP_ROOT/config/claude-account"
out=$(fm_dispatch_capacity claude claude-sonnet-5-5)
assert_equals unknown "$(jq -r .status <<<"$out")" "a pin without established quota mapping is not inferred"
rm "$TMP_ROOT/config/claude-account"
jq '(.providers[] | select(.accountKey=="default").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining)=0' "$QUOTA_FIXTURE" > "$TMP_ROOT/native-claude-zero.json"
mv "$TMP_ROOT/native-claude-zero.json" "$QUOTA_FIXTURE"
native_primary='{"harness":"claude","model":"claude-sonnet-5-5","effort":"high"}'
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals exhausted "$(jq -r .status <<<"$out")" "native default exhaustion remains measured without alternate auth"
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
assert_equals true "$(jq -r .switched <<<"$out")" "native default exhaustion authorizes a permitted fallback"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/alternate-claude"
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals unknown "$(jq -r .status <<<"$out")" "ambient alternate authentication must not inherit default exhaustion"
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
assert_equals false "$(jq -r .switched <<<"$out")" "ambient alternate authentication must not switch on unrelated default exhaustion"
assert_equals "$native_primary" "$(jq -c .profile <<<"$out")" "alternate-auth uncertainty retains the original profile"
export CLAUDE_CONFIG_DIR=''
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals exhausted "$(jq -r .status <<<"$out")" "an empty forwarded auth directory is still native default authentication"
unset CLAUDE_CONFIG_DIR
for credential in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
  export "$credential=retained-routing-fixture"
  for forwarding in ambient allowlisted; do
    if [ "$forwarding" = allowlisted ]; then
      printf '%s\n' "$credential" > "$TMP_ROOT/config/launch-env-allowlist"
    fi
    out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
    assert_equals unknown "$(jq -r .status <<<"$out")" "$forwarding $credential must not inherit subscription exhaustion"
    out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
    assert_equals false "$(jq -r .switched <<<"$out")" "$forwarding $credential must retain the original route"
    assert_equals "$native_primary" "$(jq -c .profile <<<"$out")" "$forwarding $credential must not substitute a model"
  done
  printf '# no alternate API authentication\n' > "$TMP_ROOT/config/launch-env-allowlist"
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
  assert_equals exhausted "$(jq -r .status <<<"$out")" "filtered $credential must not conceal real subscription exhaustion"
  out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals true "$(jq -r .switched <<<"$out")" "filtered $credential permits the declared exhaustion fallback"
  printf '%s\n' "$credential" > "$TMP_ROOT/config/launch-env-allowlist"
  export "$credential="
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
  assert_equals exhausted "$(jq -r .status <<<"$out")" "an empty $credential is not alternate authentication"
  unset "$credential"
  rm "$TMP_ROOT/config/launch-env-allowlist"
done
pass "capacity and selection bind API authentication only when actually retained"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  show-environment)
    if [ "$2" = -t ]; then
      file="$FM_HOME/tmux-session-env"
      [ "$3" != recorded ] || file="$FM_HOME/tmux-recorded-env"
      [ -f "$file" ] || exit 1
      cat "$file"
    else
      [ -f "$FM_HOME/tmux-global-env" ] || exit 1
      cat "$FM_HOME/tmux-global-env"
    fi ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"
for credential in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
  printf '%s=global-routing-fixture\n' "$credential" > "$TMP_ROOT/tmux-global-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals false "$(jq -r .switched <<<"$out")" "destination global $credential must not inherit subscription exhaustion"
  printf '%s=session-routing-fixture\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals unknown "$(jq -r .capacity.status <<<"$out")" "destination session $credential is alternate authentication"
  printf -- '-%s\n' "$credential" > "$TMP_ROOT/tmux-recorded-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" "" recorded)
  assert_equals true "$(jq -r .switched <<<"$out")" "the explicit recorded session must override the current session's $credential"
  rm "$TMP_ROOT/tmux-recorded-env"
  printf -- '-%s\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals true "$(jq -r .switched <<<"$out")" "session removal of $credential must suppress the global credential"
  printf '%s=\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals true "$(jq -r .switched <<<"$out")" "empty session $credential must override the global credential"
  printf '%s=session-routing-fixture\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  printf '# filter destination credentials\n' > "$TMP_ROOT/config/launch-env-allowlist"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals true "$(jq -r .switched <<<"$out")" "the allowlist must strip destination $credential"
  rm "$TMP_ROOT/tmux-session-env" "$TMP_ROOT/tmux-global-env" "$TMP_ROOT/config/launch-env-allowlist"
done
pass "destination tmux credential layering respects removal, emptiness, and filtering"
printf 'teamclaude\n' > "$TMP_ROOT/config/claude-launcher"
out=$(fm_dispatch_capacity claude claude-opus-5-5)
assert_equals unknown "$(jq -r .status <<<"$out")" "native Claude's exhausted account is not the TeamClaude proxy's quota"
pass "capacity does not conflate default and pinned Claude accounts"
printf '# all fm-dispatch-capacity tests passed\n'
