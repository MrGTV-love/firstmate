#!/usr/bin/env bash
# Token-free compatibility guard for model-index native catalog adapters.
# FM_MODEL_INDEX_LIVE_E2E / FM_LIVE force this on or off through fm_live_gate.
# Every installed native catalog adapter must return ids and refuse an absent id.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_MODEL_INDEX_LIVE_E2E jq
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
forced=${FM_MODEL_INDEX_LIVE_E2E:-${FM_LIVE:-0}}
TMP_ROOT=$(fm_test_tmproot fm-model-index-live)
mkdir -p "$TMP_ROOT/home/config"
export FM_HOME="$TMP_ROOT/home"
unset FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_MODEL_CATALOG_DIR
TOOL="$ROOT/bin/fm-model-index.sh"
checked=0
for harness in codex claude omp pi pi-signed opencode cursor agy; do
  binary=$harness
  if [ "$harness" = cursor ]; then
    # shellcheck source=bin/fm-cursor-lib.sh
    . "$ROOT/bin/fm-cursor-lib.sh"
    binary=$(fm_cursor_resolve_binary 2>/dev/null) || binary=''
  fi
  if [ -z "$binary" ] || ! command -v "$binary" >/dev/null 2>&1; then
    printf 'skip - %s catalog adapter: executable absent\n' "$harness"
    continue
  fi
  version=$("$binary" --version 2>&1) || version='version unavailable'
  [ "$harness" != codex ] || [ -f "${CODEX_HOME:-$HOME/.codex}/models_cache.json" ] || {
    [ "$forced" != 1 ] || fail "codex $version: native models cache absent"
    printf 'skip - codex %s: native models cache absent\n' "$version"
    continue
  }
  case "$harness" in pi|pi-signed)
    listing=$(fm_run_timed 30 "$binary" --list-models) || fail "$harness $version: catalog command failed"
    case "$listing" in 'No models available. Use /login'*)
      [ "$forced" != 1 ] || fail "$harness $version: no authenticated provider catalog"
      printf 'skip - %s %s: no authenticated provider catalog\n' "$harness" "$version"
      continue
      ;;
    esac
    ;;
  esac
  rm -f "$TMP_ROOT/home/config/model-index.json"
  "$TOOL" catalog "$harness" > "$TMP_ROOT/catalog.json" || fail "$harness $version: catalog discovery failed"
  model=$(jq -er '.models[0].id' "$TMP_ROOT/catalog.json") || fail "$harness $version: no model ids"
  # Reuse this live authoritative snapshot for both verdicts, rather than
  # fetching an account catalog three times and racing vendor refreshes.
  mkdir -p "$TMP_ROOT/catalogs/$harness"
  cp "$TMP_ROOT/catalog.json" "$TMP_ROOT/catalogs/$harness/$harness.json"
  case "$model" in openrouter/*)
    curl -fsS --max-time 30 https://openrouter.ai/api/v1/models > "$TMP_ROOT/catalogs/$harness/openrouter.json" || fail "$harness $version: OpenRouter catalog unavailable"
    ;;
  esac
  jq -n --arg h "$harness" --arg m "$model" '{version:1,roles:{live:{($h):{model:$m}}},retired:[]}' > "$TMP_ROOT/home/config/model-index.json"
  FM_MODEL_CATALOG_DIR="$TMP_ROOT/catalogs/$harness" "$TOOL" check >/dev/null || fail "$harness $version: returned catalog id was refused: $model"
  jq '.roles.live[].model = "fm-intentionally-absent-model-index-guard"' "$TMP_ROOT/home/config/model-index.json" > "$TMP_ROOT/absent.json"
  mv "$TMP_ROOT/absent.json" "$TMP_ROOT/home/config/model-index.json"
  if FM_MODEL_CATALOG_DIR="$TMP_ROOT/catalogs/$harness" "$TOOL" check > "$TMP_ROOT/refusal" 2>&1; then
    fail "$harness $version: absent id was accepted"
  fi
  assert_contains "$(cat "$TMP_ROOT/refusal")" 'absent or retired' "$harness $version: absence did not receive a catalog verdict"
  printf 'ok - %s %s: catalog id accepted; absent id refused\n' "$harness" "$version"
  checked=$((checked + 1))
done
if [ "$checked" = 0 ]; then
  [ "$forced" != 1 ] || fail 'no installed native catalog adapter was checked'
  printf 'skip: live: no installed native adapter has an available catalog\n'
  exit 0
fi
printf '# model-index live adapters checked: %s\n' "$checked"
