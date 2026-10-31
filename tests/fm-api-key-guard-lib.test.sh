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

CODE_ROOT="$TMP_ROOT/code-root"
SOL_ENTRY='openai-codex/gpt-6.1-sol openrouter/xiaomi/mimo-v2.6-pro'
MIMO_ENTRY='openrouter/xiaomi/mimo-v2.6-pro openrouter/anthropic/claude-haiku-5.5'

billing_diagnostics() {
  HOME="$TMP_ROOT" FM_HOME="${CASE_FM_HOME:-$TMP_ROOT}" FM_ROOT_OVERRIDE="$CODE_ROOT" FM_CONFIG_OVERRIDE='' \
    PI_CODING_AGENT_DIR="$TMP_ROOT/agent" OMP_PROFILE='' \
    fm_omp_api_billing_config_diagnostics
}

write_sol_config() {
  cat > "$TMP_ROOT/agent/config.yml" <<'YAML'
retry:
  fallbackChains:
    openai-codex/gpt-6.1-sol:
      - openrouter/xiaomi/mimo-v2.6-pro
    openrouter/xiaomi/mimo-v2.6-pro:
      - openrouter/anthropic/claude-haiku-5.5
YAML
}

test_padded_api_selectors_are_refused() {
  local selector out rc
  for selector in 'openai/gpt-6.1-sol' ' openai/gpt-6.1-sol ' \
    ' OpenAI / gpt-6.1-sol ' $'\topenrouter\t/ vendor/model\t'; do
    out=$(fm_omp_api_billing_route_check "$selector" 2>&1); rc=$?
    [ "$rc" -eq 1 ] || fail "an API route with native whitespace normalization was admitted"
    assert_contains "$out" 'openai-codex/<gpt-model>' "a refusal must give the subscription remedy"
  done
  for selector in 'openai-codex/gpt-6.1-sol' ' openai-codex / gpt-6.1-sol ' 'ollama/model' ''; do
    out=$(fm_omp_api_billing_route_check "$selector" 2>&1); rc=$?
    [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "a non-API selector was refused: $out"
  done
  for selector in 'deepseek/model' ' DeepSeek / model '; do
    out=$(fm_omp_api_billing_route_check "$selector" 2>&1); rc=$?
    [ "$rc" -eq 1 ] || fail "DeepSeek must not launch through omp"
    assert_contains "$out" 'select --harness dsh' "DeepSeek refusal must name dsh-tui"
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
  write_sol_config
  before=$(cksum "$config")
  out=$(billing_diagnostics)
  for field in 'target[0][0]' 'key[1]' 'target[1][0]'; do
    assert_contains "$out" "$field uses openrouter/*" "unrecorded approval must not exempt $field"
  done
  printf 'approval absent:\n%s\n' "$out"
  printf '# 2026-10-20 captain approval\n%s\n%s\n' "$SOL_ENTRY" "$MIMO_ENTRY" > "$approval"
  approval_before=$(cksum "$approval")
  out=$(billing_diagnostics)
  [ -z "$out" ] || fail "the exactly approved two-entry chain must pass: $out"
  [ "$(cksum "$config")" = "$before" ] || fail "approval diagnostics modified omp config"
  [ "$(cksum "$approval")" = "$approval_before" ] || fail "approval diagnostics modified the approval record"
  printf 'approval present: no billing findings\n'
  printf '%s\r\n%s\r\n' "$SOL_ENTRY" "$MIMO_ENTRY" > "$approval"
  out=$(billing_diagnostics)
  [ -z "$out" ] || fail "a CRLF approval record must still match: $out"
  printf '%s\n' "$SOL_ENTRY" > "$approval"
  out=$(billing_diagnostics)
  assert_not_contains "$out" 'target[0][0]' "a recorded entry must stay exempt without its neighbour"
  assert_contains "$out" 'key[1] uses' "an unrecorded second entry must stay flagged"
  assert_contains "$out" 'target[1][0] uses' "an unrecorded second entry must stay flagged"
  printf '%s\n' "$MIMO_ENTRY" > "$approval"
  out=$(billing_diagnostics)
  assert_contains "$out" 'target[0][0] uses' "an unrecorded first entry must stay flagged"
  assert_not_contains "$out" 'key[1]' "a recorded entry must stay exempt without its neighbour"
  assert_not_contains "$out" 'target[1][0]' "a recorded entry must stay exempt without its neighbour"
  printf '%s\n%s\n' "$SOL_ENTRY" "$MIMO_ENTRY" > "$approval"
  out=$(CASE_FM_HOME="$TMP_ROOT/another-home" billing_diagnostics)
  assert_contains "$out" 'target[0][0] uses' "one home must not borrow another home's approval"
  out=$(HOME="$TMP_ROOT" FM_HOME="$TMP_ROOT/another-home" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" \
    FM_ROOT_OVERRIDE="$CODE_ROOT" PI_CODING_AGENT_DIR="$TMP_ROOT/agent" OMP_PROFILE='' fm_omp_api_billing_config_diagnostics)
  [ -z "$out" ] || fail "an explicit config-directory override must select its recorded approvals: $out"

  local variant
  for variant in \
    $'retry:\n  fallbackChains:\n    openai-codex/gpt-6.1-sol: [openrouter/xiaomi/mimo-v2.6-pro, openrouter/anthropic/claude-haiku-5.5]' \
    $'retry:\n  fallbackChains:\n    openai-codex/gpt-6.1-sol: [openrouter/anthropic/claude-haiku-5.5]' \
    $'retry:\n  fallbackChains:\n    openai-codex/gpt-6.1-sol: [openrouter/xiaomi/mimo-v2.6-pro, openrouter/extra/model]' \
    $'retry:\n  fallbackChains:\n    openai-codex/gpt-6.1-terra: [openrouter/xiaomi/mimo-v2.6-pro]' \
    $'retry:\n  fallbackChains:\n    openrouter/anthropic/claude-haiku-5.5: [openrouter/xiaomi/mimo-v2.6-pro]' \
    $'retry:\n  fallbackChains:\n    openai-codex/gpt-6.1-sol: [" openrouter/xiaomi/mimo-v2.6-pro "]' \
    $'retry:\n  fallbackChains:\n    openai-codex/gpt-6.1-sol: ["openrouter/xiaomi/mimo-v2.6-pro:high"]' \
    $'retry:\n  fallbackChains:\n    openai-codex/gpt-6.1-sol: [OpenRouter/xiaomi/mimo-v2.6-pro]'; do
    printf '%s\n' "$variant" > "$config"
    out=$(billing_diagnostics)
    assert_contains "$out" 'target[0][0] uses' "a changed entry must not inherit the recorded approval: $variant"
  done

  cat > "$config" <<'YAML'
modelRoles:
  default: openrouter/xiaomi/mimo-v2.6-pro
  vision: openrouter/anthropic/claude-haiku-5.5
retry:
  fallbackChains:
    openai-codex/gpt-6.1-sol:
      - openrouter/xiaomi/mimo-v2.6-pro
    openrouter/xiaomi/mimo-v2.6-pro:
      - openrouter/anthropic/claude-haiku-5.5
    default:
      - openrouter/anthropic/claude-haiku-5.5
    openrouter/anthropic/claude-haiku-5.5:
      - openrouter/xiaomi/mimo-v2.6-pro
YAML
  out=$(billing_diagnostics)
  for field in 'target[0][' 'key[1]' 'target[1][' 'key[2]'; do
    assert_not_contains "$out" "$field" "the recorded entries stay exempt beside unrecorded entries: $field"
  done
  assert_contains "$out" 'modelRoles.default uses' "a recorded route used as a model role must stay flagged"
  assert_contains "$out" 'modelRoles.vision uses' "a recorded route used as a model role must stay flagged"
  assert_contains "$out" 'target[2][0] uses' "a third unrecorded entry holding a recorded route must stay flagged"
  assert_contains "$out" 'key[3] uses' "a recorded route as the key of an unrecorded entry must stay flagged"
  assert_contains "$out" 'target[3][0] uses' "a recorded route under an unrecorded key must stay flagged"

  printf '%s\n%s\n%s\n' 'openai-codex/gpt-6.1-sol openrouter/openai/gpt-6.1-sol' \
    'openai-codex/gpt-6.1-luna openrouter/vendor/GPT-6-mini' 'openai-codex/gpt-6.1-terra openrouter/openai/o3' > "$approval"
  cat > "$config" <<'YAML'
modelRoles:
  tiny: openai/gpt-6.1-sol
retry:
  fallbackChains:
    openai-codex/gpt-6.1-sol: [openrouter/openai/gpt-6.1-sol]
    openai-codex/gpt-6.1-luna: [openrouter/vendor/GPT-6-mini]
    openai-codex/gpt-6.1-terra: [openrouter/openai/o3]
    openai/gpt-6.1-sol: [openai/gpt-6.1-sol]
YAML
  out=$(billing_diagnostics)
  for field in modelRoles.tiny 'target[0][0]' 'target[1][0]' 'target[2][0]' 'key[3]' 'target[3][0]'; do
    assert_contains "$out" "$field uses" "a recorded entry must not hide GPT or openai routes: $field"
  done
  printf '%s\n%s\n' "$SOL_ENTRY" "$MIMO_ENTRY" > "$approval"
  cat > "$config" <<'YAML'
retry:
  fallbackChains:
    openai-codex/gpt-6.1-sol:
      - openrouter/xiaomi/mimo-v2.6-pro
      - openrouter/unapproved/private-model-canary
YAML
  out=$(billing_diagnostics)
  assert_contains "$out" 'target[0][0] uses' "an unrecorded entry must flag every paid route in it"
  assert_contains "$out" 'target[0][1] uses' "an unrecorded entry must flag every paid route in it"
  assert_not_contains "$out" canary "approval diagnostics must not expose arbitrary model ids"
  rm "$approval"
  pass "recorded fallback entries are exact and entry-scoped; other entries, roles, GPT and openai stay flagged"
}

test_code_root_approval_for_first_time_seed() {
  local config="$TMP_ROOT/agent/config.yml" root_approval="$CODE_ROOT/config/omp-approved-fallback-chains" \
    home_approval="$TMP_ROOT/absent-home/config/omp-approved-fallback-chains" out
  write_sol_config
  rm -f "$TMP_ROOT/config/omp-approved-fallback-chains"
  mkdir -p "$CODE_ROOT/config"
  out=$(CASE_FM_HOME="$TMP_ROOT/absent-home" billing_diagnostics)
  for field in 'target[0][0]' 'key[1]' 'target[1][0]'; do
    assert_contains "$out" "$field uses openrouter/*" "a first-time seed with no record anywhere must stay refused: $field"
  done
  printf '%s\n%s\n' "$SOL_ENTRY" "$MIMO_ENTRY" > "$root_approval"
  out=$(CASE_FM_HOME="$TMP_ROOT/absent-home" billing_diagnostics)
  [ -z "$out" ] || fail "a first-time seed must honor the code root record: $out"
  printf '%s\n' "$SOL_ENTRY" > "$root_approval"
  out=$(CASE_FM_HOME="$TMP_ROOT/absent-home" billing_diagnostics)
  assert_not_contains "$out" 'target[0][0]' "the code root record must honor the entries it records"
  assert_contains "$out" 'target[1][0] uses' "the code root record must honor only the exact recorded entries"
  printf '%s\n%s\n' "$SOL_ENTRY" "$MIMO_ENTRY" > "$root_approval"

  mkdir -p "$TMP_ROOT/absent-home/config"
  printf 'openai-codex/gpt-6.1-sol openrouter/other/model\n' > "$home_approval"
  out=$(CASE_FM_HOME="$TMP_ROOT/absent-home" billing_diagnostics)
  assert_contains "$out" 'target[0][0] uses' "an existing home record must win over the code root record"
  printf 'not a chain\n' > "$home_approval"
  out=$(CASE_FM_HOME="$TMP_ROOT/absent-home" billing_diagnostics)
  assert_contains "$out" 'omp-approved-fallback-chains line 1' "an existing malformed home record must not fall back"
  assert_contains "$out" 'target[0][0] uses' "an existing malformed home record must not fall back"
  : > "$home_approval"
  out=$(CASE_FM_HOME="$TMP_ROOT/absent-home" billing_diagnostics)
  assert_contains "$out" 'target[0][0] uses' "an existing empty home record must not fall back"
  rm -rf "$TMP_ROOT/absent-home" "$CODE_ROOT"
  pass "a first-time seed reads the code root record only when the home has none, and honors only the recorded entries"
}

test_invalid_approval_records() {
  local approval="$TMP_ROOT/config/omp-approved-fallback-chains" line out
  cat > "$TMP_ROOT/agent/config.yml" <<'YAML'
retry:
  fallbackChains:
    openai-codex/gpt-6.1-sol: [openrouter/xiaomi/mimo-v2.6-pro]
YAML
  for line in '2026-10-20 openai-codex/gpt-6.1-sol openrouter/xiaomi/mimo-v2.6-pro' \
    'openai/gpt-6.1-sol openrouter/xiaomi/mimo-v2.6-pro' \
    'openai-codex/gpt-6.1-sol openrouter/*' \
    'openai-codex/gpt-6.1-sol,openrouter/xiaomi/mimo-v2.6-pro' \
    $'openai-codex/gpt-6.1-sol openrouter/xiaomi/mimo-v2.6-pro\xff' \
    'openai-codex/gpt-6.1-sol openrouter/xiaomi/mimo-v2.6-pro # extra-private-canary' \
    'target openrouter/xiaomi/mimo-v2.6-pro extra-private-canary'; do
    printf '# approval record\nopenai-codex/gpt-6.1-sol openrouter/xiaomi/mimo-v2.6-pro\n%s\n' "$line" > "$approval"
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

test_approval_record_without_omp_config_is_silent() {
  local approval="$TMP_ROOT/config/omp-approved-fallback-chains" out
  mkdir -p "$TMP_ROOT/empty-path"
  rm -f "$TMP_ROOT/agent/config.yml"
  printf 'not a chain\n' > "$approval"
  out=$(billing_diagnostics)
  [ -z "$out" ] || fail "an approval record without an omp config must stay silent: $out"
  out=$(PATH="$TMP_ROOT/empty-path" billing_diagnostics)
  [ -z "$out" ] || fail "an approval record without an omp config must not demand Ruby: $out"
  rm "$approval"
  pass "an approval record alone never produces a diagnostic when no omp config exists"
}

test_padded_api_selectors_are_refused
test_padded_config_selectors_are_diagnosed
test_recorded_fallback_approvals
test_code_root_approval_for_first_time_seed
test_invalid_approval_records
test_approval_record_without_omp_config_is_silent
test_ordered_role_patterns_are_all_diagnosed

echo "all fm-api-key-guard-lib tests passed"
