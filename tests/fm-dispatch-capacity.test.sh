#!/usr/bin/env bash
# Pooled capacity, uncertainty, explicit fallback permission, and account pins.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-dispatch-capacity-lib.sh
. "$ROOT/bin/fm-dispatch-capacity-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-capacity)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$TMP_ROOT/config"
export FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
export OMP_USAGE_FIXTURE="$TMP_ROOT/usage.json" QUOTA_FIXTURE="$TMP_ROOT/quota.json"
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
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_9 omp openai-codex/gpt-6-luna high) || fail "a missing recorded rule must not refuse"
assert_equals "$allowed" "$(jq -c .fallback <<<"$set")" "a missing recorded rule counts as no recorded rule"
cp "$TMP_ROOT/config/crew-dispatch.json" "$TMP_ROOT/identical.json"
jq '.rules[0].fallback=[{harness:"omp",model:"openrouter/deepseek/deepseek-v4-flash",effort:"high"}] |
  .default_fallback=.rules[0].fallback' "$TMP_ROOT/identical.json" > "$TMP_ROOT/config/crew-dispatch.json"
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openrouter/z-ai/glm-5.3-flash high) || fail "an edited recorded rule must not refuse"
assert_equals '{"rule":"","fallback":[]}' "$set" "a recorded rule that no longer contains the profile counts as absent"
jq '.rules[0].fallback=[]' "$TMP_ROOT/identical.json" > "$TMP_ROOT/config/crew-dispatch.json"
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" '' omp openai-codex/gpt-6-luna high) || fail "differing unlabeled lists must not refuse"
assert_equals '{"rule":"","fallback":[]}' "$set" "differing unlabeled lists permit no fallback"
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openai-codex/gpt-6-luna high)
assert_equals '{"rule":"","fallback":[]}' "$set" "an explicit rule retains its own no-fallback policy"
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" default omp openai-codex/gpt-6-luna high)
assert_equals "$(jq -cn --argjson f "$allowed" '{rule:"default",fallback:$f}')" "$set" "an explicit rule with a fallback policy is reported"
jq '.rules[0].fallback=[{harness:"claude",model:"opus",effort:"high"}]' "$TMP_ROOT/config/crew-dispatch.json" > "$TMP_ROOT/bad.json"
mv "$TMP_ROOT/bad.json" "$TMP_ROOT/config/crew-dispatch.json"
if fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openai-codex/gpt-6-luna high > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "Claude fallback without a supported TeamClaude requirement must refuse"
fi
pass "matrix fallback retains per-rule permission and strongest-model boundaries"

cat > "$TMP_ROOT/config/model-index.json" <<'JSON'
{"version":1,"roles":{"sonnet-grade":{"omp":{"model":"openai-codex/gpt-6-luna","stand_in":"openrouter/deepseek/deepseek-v4-flash"}}},"retired":[]}
JSON
for use in '{"harness":"omp","role":"sonnet-grade"}' \
  '[{"harness":"omp","role":"sonnet-grade","stand_in":true}]' \
  '{"harness":"omp"}'; do
  jq -n --argjson use "$use" --argjson fallback "$allowed" \
    '{rules:[{when:"work",use:$use,fallback:$fallback}],default:$use,default_fallback:$fallback}' > "$TMP_ROOT/config/crew-dispatch.json"
  model=$(jq -r 'if type == "array" then .[0] else . end |
    if .stand_in then "openrouter/deepseek/deepseek-v4-flash"
    elif .role then "openai-codex/gpt-6-luna" else "default" end' <<<"$use")
  for rule in rule_1 default ''; do
    set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" "$rule" omp "$model" default) || fail "resolved profile lookup refused $use"
    assert_equals "$allowed" "$(jq -c .fallback <<<"$set")" "resolved and persisted default axes retain their fallback policy"
    set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" "$rule" omp "${model/default/}" '') || fail "omitted launch axes refused $use"
    assert_equals "$allowed" "$(jq -c .fallback <<<"$set")" "omitted launch axes match the same policy"
  done
done
pass "fallback lookup resolves primary and stand-in roles and normalizes omitted axes"

for retired in openrouter/z-ai/glm-5.3-flash glm-5.3-flash; do
  jq --arg retired "$retired" '.retired=[$retired]' "$TMP_ROOT/config/model-index.json" > "$TMP_ROOT/retired-index.json"
  mv "$TMP_ROOT/retired-index.json" "$TMP_ROOT/config/model-index.json"
  if fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp default default > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
    fail "retired rule and default stand-ins must refuse before launch"
  fi
  if fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed" '{"status":"exhausted"}' > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
    fail "catalog membership must not authorize a retired stand-in"
  fi
done
jq -n --argjson use "$primary" '{rules:[
    {when:"easy work",use:$use,fallback:[{harness:"omp",model:"openrouter/deepseek/deepseek-v4-flash",effort:"high"}]},
    {when:"unconfigured",use:{harness:"omp",role:"missing-role"}},
    {when:"strong work",use:{harness:"omp",model:"openai-codex/gpt-6.1-sol",effort:"high"},
     fallback:[{harness:"omp",model:"openrouter/z-ai/glm-5.3-flash",effort:"high"}]}]}' > "$TMP_ROOT/config/crew-dispatch.json"
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" '' omp openai-codex/gpt-6-luna high) || fail "a stale unrelated rule must not block the lookup"
assert_equals rule_1 "$(jq -r .rule <<<"$set")" "the matched rule survives stale unrelated rules"
assert_equals openrouter/deepseek/deepseek-v4-flash "$(jq -r '.fallback[0].model' <<<"$set")" "the matched rule keeps its own stand-in"
if fm_dispatch_fallbacks "$TMP_ROOT/config" '' omp openai-codex/gpt-6.1-sol high > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "a matched rule with a retired stand-in must refuse"
fi
rm "$TMP_ROOT/config/model-index.json"
pass "retirement applies to matched lists and direct fallback selection, not unrelated rules"

cat > "$QUOTA_FIXTURE" <<'JSON'
{"schemaVersion":6,"providers":[
 {"provider":"claude","accountKey":"other","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0}]}},
 {"provider":"claude","accountKey":"default","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70}]}}
]}
JSON
out=$(fm_dispatch_capacity claude claude-sonnet-5-5)
assert_equals usable "$(jq -r .status <<<"$out")" "another Claude account must not veto the selected default"
jq '(.providers[] | select(.accountKey=="default").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining)=0' "$QUOTA_FIXTURE" > "$TMP_ROOT/native-claude-zero.json"
mv "$TMP_ROOT/native-claude-zero.json" "$QUOTA_FIXTURE"
printf 'teamclaude\n' > "$TMP_ROOT/config/claude-launcher"
fm_test_fake_teamclaude "$FAKEBIN"
out=$(fm_dispatch_capacity claude claude-opus-5-5)
assert_equals exhausted "$(jq -r .status <<<"$out")" "a Claude-primary route keeps native quota evidence"
write_pool 0
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$strong" "$team") || fail "native Claude exhaustion must not veto the TeamClaude stand-in"
assert_equals claude "$(jq -r .profile.harness <<<"$out")" "exhausted Sol switches to its declared TeamClaude stand-in"
assert_equals unknown "$(jq -r .capacity.status <<<"$out")" "TeamClaude proxy quota is unknown, not native Claude's row"
rm "$TMP_ROOT/config/claude-launcher"
pass "capacity does not conflate native Claude quota with a TeamClaude stand-in"
printf '# all fm-dispatch-capacity tests passed\n'
