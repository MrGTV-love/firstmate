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
  HOME="$TMP_ROOT" PI_CODING_AGENT_DIR="$TMP_ROOT/agent" OMP_PROFILE= \
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

test_padded_api_selectors_are_refused
test_padded_config_selectors_are_diagnosed
test_ordered_role_patterns_are_all_diagnosed

echo "all fm-api-key-guard-lib tests passed"
