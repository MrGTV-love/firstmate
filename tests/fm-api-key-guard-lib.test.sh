#!/usr/bin/env bash
# Behavior regressions for the shared omp billing-route admission and read-only
# config diagnostic, without launching a worker or making a provider request.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-api-key-guard-lib.sh
. "$ROOT/bin/fm-api-key-guard-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-api-key-guard-lib)
mkdir -p "$TMP_ROOT/agent"

billing_diagnostics() {
  HOME="$TMP_ROOT" FM_HOME="$TMP_ROOT" FM_ROOT_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    PI_CODING_AGENT_DIR="$TMP_ROOT/agent" OMP_PROFILE='' \
    fm_omp_api_billing_config_diagnostics
}

test_padded_api_selectors_are_refused() {
  local selector out rc
  for selector in 'openai/gpt-6.1-sol' ' openai/gpt-6.1-sol ' \
    ' OpenAI / gpt-6.1-sol ' $'\topenrouter\t/ vendor/model\t'; do
    out=$(fm_omp_api_billing_route_check "$selector" 2>&1); rc=$?
    [ "$rc" -eq 1 ] || fail "an API route with native whitespace normalization was admitted"
    assert_contains "$out" 'openai-codex/<gpt-model>' "a refusal must give the subscription remedy"
  done
  for selector in 'openai-codex/gpt-6.1-sol' ' openai-codex / gpt-6.1-sol ' 'deepseek/model' ''; do
    out=$(fm_omp_api_billing_route_check "$selector" 2>&1); rc=$?
    [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "a non-API selector was refused: $out"
  done
  pass "padded API selectors are refused while subscription selectors remain admitted"
}

test_padded_config_selectors_are_diagnosed() {
  local config="$TMP_ROOT/agent/config.yml" before out
  cat > "$config" <<'YAML'
modelRoles:
  default: ' OpenAI / private-model-canary '
  vision: ' openrouter/vendor/private-model-canary '
  tiny: ' OPENAI/gpt-mini '
retry:
  fallbackChains:
    ' OpenAI / * ': [' openrouter / vendor/private-model-canary ']
providers:
  private-provider-canary:
    apiKey: private-key-canary
YAML
  before=$(cksum "$config")
  out=$(billing_diagnostics)
  for field in modelRoles.default modelRoles.vision modelRoles.tiny \
    'retry.fallbackChains key[0]' 'retry.fallbackChains target[0][0]'; do
    assert_contains "$out" "$field uses" "a padded $field must be diagnosed"
  done
  assert_not_contains "$out" canary "diagnostics must not expose model ids or credentials"
  [ "$(cksum "$config")" = "$before" ] || fail "read-only diagnostics changed config.yml"
  pass "padded role and fallback selectors are diagnosed without writes or secret output"
}

test_ordered_role_patterns_are_all_diagnosed() {
  local config="$TMP_ROOT/agent/config.yml" before out role
  cat > "$config" <<'YAML'
modelRoles:
  default: 'openai-codex/gpt-6.1-sol, openai/private-model-canary'
  vision: 'deepseek/model, openai-codex/gpt-6.1-sol, OpenRouter / vendor/private-model-canary'
  tiny: ' openai-codex/gpt-mini , OPENAI / private-model-canary, deepseek/model'
providers:
  private-provider-canary:
    apiKey: private-key-canary
YAML
  before=$(cksum "$config")
  out=$(billing_diagnostics)
  for role in default vision tiny; do
    assert_contains "$out" "modelRoles.$role uses" "a later API pattern in $role must be diagnosed"
  done
  assert_not_contains "$out" canary "ordered-pattern diagnostics must remain redacted"
  [ "$(cksum "$config")" = "$before" ] || fail "ordered-pattern diagnostics changed config.yml"
  cat > "$config" <<'YAML'
modelRoles:
  default: ' openai-codex / gpt-6.1-sol, deepseek/model '
  vision: 'deepseek/model, openai-codex/gpt-6.1-sol'
  tiny: 'openai-codex/gpt-mini'
YAML
  out=$(billing_diagnostics)
  [ -z "$out" ] || fail "subscription-only ordered patterns must stay unflagged: $out"
  pass "all ordered role patterns are inspected and subscription-only lists stay unflagged"
}

test_recorded_fallback_approvals() {
  local config="$TMP_ROOT/agent/config.yml" approval="$TMP_ROOT/config/omp-approved-fallback-chains" out before approval_before
  mkdir -p "$TMP_ROOT/config"
  cat > "$config" <<'YAML'
retry:
  fallbackChains:
    openai-codex/gpt-6.1-sol:
      - openrouter/xiaomi/mimo-v2.6-pro
      - openrouter/anthropic/claude-haiku-5.5
YAML
  before=$(cksum "$config")
  out=$(billing_diagnostics)
  assert_contains "$out" 'target[0][0] uses openrouter/*' "unrecorded approval must not exempt the first paid target"
  assert_contains "$out" 'target[0][1] uses openrouter/*' "unrecorded approval must not exempt the second paid target"
  printf 'approval absent:\n%s\n' "$out"
  cat > "$approval" <<'APPROVAL'
# Recorded owner approvals
2026-10-20 key openai-codex/gpt-6.1-sol
2026-10-20 target openrouter/xiaomi/mimo-v2.6-pro
2026-10-20 target openrouter/anthropic/claude-haiku-5.5
APPROVAL
  approval_before=$(cksum "$approval")
  out=$(billing_diagnostics)
  [ -z "$out" ] || fail "the exactly approved fallback routes must pass: $out"
  [ "$(cksum "$config")" = "$before" ] || fail "approval diagnostics modified omp config"
  [ "$(cksum "$approval")" = "$approval_before" ] || fail "approval diagnostics modified the approval record"
  printf 'approval present: no billing findings\n'
  out=$(HOME="$TMP_ROOT" FM_HOME="$TMP_ROOT/another-home" FM_CONFIG_OVERRIDE='' \
    FM_ROOT_OVERRIDE='' PI_CODING_AGENT_DIR="$TMP_ROOT/agent" OMP_PROFILE='' \
    fm_omp_api_billing_config_diagnostics)
  assert_contains "$out" 'target[0][0] uses' "one home must not borrow another home's approval"
  out=$(HOME="$TMP_ROOT" FM_HOME="$TMP_ROOT/another-home" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" \
    PI_CODING_AGENT_DIR="$TMP_ROOT/agent" OMP_PROFILE='' fm_omp_api_billing_config_diagnostics)
  [ -z "$out" ] || fail "an explicit config-directory override must select its recorded approvals: $out"

  cat >> "$approval" <<'APPROVAL'
2026-10-20 target openrouter/openai/gpt-6.1-sol
2026-10-20 target openrouter/vendor/GPT-6-mini
2026-10-20 target openai/gpt-6.1-sol
2026-10-20 target openrouter/openai/o3
APPROVAL
  cat > "$config" <<'YAML'
modelRoles:
  default: openrouter/xiaomi/mimo-v2.6-pro
  vision: openrouter/anthropic/claude-haiku-5.5
  tiny: openai/gpt-6.1-sol
retry:
  fallbackChains:
    openrouter/xiaomi/mimo-v2.6-pro:
      - openrouter/unapproved/private-model-canary
      - openrouter/openai/gpt-6.1-sol
      - openai/gpt-6.1-sol
      - openrouter/vendor/GPT-6-mini
      - openrouter/openai/o3
      - ' openrouter/xiaomi/mimo-v2.6-pro '
      - openrouter/xiaomi/mimo-v2.6-pro:high
      - OpenRouter/xiaomi/mimo-v2.6-pro
YAML
  out=$(billing_diagnostics)
  for field in modelRoles.default modelRoles.vision modelRoles.tiny \
    'key[0]' 'target[0][0]' 'target[0][1]' 'target[0][2]' 'target[0][3]' \
    'target[0][4]' 'target[0][5]' 'target[0][6]' 'target[0][7]'; do
    assert_contains "$out" "$field uses" "approval must not hide unapproved position, route, GPT or API provider: $field"
  done
  assert_not_contains "$out" canary "approval diagnostics must not expose arbitrary model ids"
  cat > "$approval" <<'APPROVAL'
2026-10-20 key openrouter/xiaomi/mimo-v2.6-pro
APPROVAL
  cat > "$config" <<'YAML'
retry:
  fallbackChains:
    openrouter/xiaomi/mimo-v2.6-pro: [openrouter/xiaomi/mimo-v2.6-pro]
YAML
  out=$(billing_diagnostics)
  assert_not_contains "$out" 'key[0] uses' "an approved key should pass only as a key"
  assert_contains "$out" 'target[0][0] uses' "key approval must not authorize a target"
  rm "$approval"
  pass "recorded fallback approvals are exact and position-scoped; unlisted routes, roles, GPT and openai stay flagged"
}

test_invalid_approval_records() {
  local approval="$TMP_ROOT/config/omp-approved-fallback-chains" line out
  cat > "$TMP_ROOT/agent/config.yml" <<'YAML'
retry:
  fallbackChains:
    default: [openrouter/xiaomi/mimo-v2.6-pro]
YAML
  for line in 'not-a-date target openrouter/xiaomi/mimo-v2.6-pro' \
    '2026-02-30 target openrouter/xiaomi/mimo-v2.6-pro' \
    '2026-10-20 role openrouter/xiaomi/mimo-v2.6-pro' \
    '2026-10-20 target openrouter/*' \
    $'2026-10-20 target openrouter/xiaomi/mimo-v2.6-pro\xff' \
    '2026-10-20 target openrouter/xiaomi/mimo-v2.6-pro extra-private-canary'; do
    printf '# approval record\n2026-10-20 target openrouter/xiaomi/mimo-v2.6-pro\n%s\n' "$line" > "$approval"
    out=$(billing_diagnostics)
    assert_contains "$out" 'omp-approved-fallback-chains line 3' "malformed approval must name its line"
    assert_contains "$out" 'target[0][0] uses' "a malformed approval file must not authorize routes"
    assert_not_contains "$out" canary "approval errors must not print malformed contents"
  done
  rm "$approval"
  mkdir "$approval"
  out=$(billing_diagnostics)
  assert_contains "$out" 'cannot inspect omp approvals' "a directory in place of the approval file must be diagnostic"
  assert_contains "$out" 'target[0][0] uses' "unreadable approval must never grant permission"
  rmdir "$approval"
  ln -s "$TMP_ROOT/missing-approval" "$approval"
  out=$(billing_diagnostics)
  assert_contains "$out" 'cannot inspect omp approvals' "a dangling approval symlink must be diagnostic"
  rm "$approval"
  pass "malformed and unreadable approval records diagnose configuration problems without granting exceptions"
}

test_padded_api_selectors_are_refused
test_padded_config_selectors_are_diagnosed
test_recorded_fallback_approvals
test_invalid_approval_records
test_ordered_role_patterns_are_all_diagnosed

echo "all fm-api-key-guard-lib tests passed"
