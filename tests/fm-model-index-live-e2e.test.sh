#!/usr/bin/env bash
# Token-free compatibility guard for model-index native catalog adapters.
# FM_MODEL_INDEX_LIVE_E2E / FM_LIVE force this on or off through fm_live_gate.
# Every installed native catalog adapter must accept an id its own CLI lists
# and refuse an absent id, through the public check with a two-entry index.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_MODEL_INDEX_LIVE_E2E jq
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"
forced=${FM_MODEL_INDEX_LIVE_E2E:-${FM_LIVE:-0}}
TMP_ROOT=$(fm_test_tmproot fm-model-index-live)
mkdir -p "$TMP_ROOT/home/config"
export FM_HOME="$TMP_ROOT/home"
unset FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_MODEL_CATALOG_DIR
TOOL="$ROOT/bin/fm-model-index.sh"
ABSENT=fm-intentionally-absent-model-index-guard

# listed_id <harness> <binary>: one id read straight from the harness's own
# listing, independent of the adapter under test. Each listing is captured
# before parsing; a timed CLI writing straight into a pipe can emit nothing.
listed_id() {
  local raw
  case "$1" in
    codex) jq -r '.models[0].slug // empty' "${CODEX_HOME:-$HOME/.codex}/models_cache.json" ;;
    claude)
      printf '%s\n' '{"type":"control_request","request_id":"live","request":{"subtype":"initialize"}}' > "$TMP_ROOT/initialize.json"
      # shellcheck disable=SC2016 # Positional expansion belongs to the child.
      raw=$(fm_run_timed 30 bash -c 'exec claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence --setting-sources "" < "$1"' _ "$TMP_ROOT/initialize.json")
      jq -rs '[.[] | select(.type == "control_response") | .response.response.models[]?.value] | .[0] // empty' <<< "$raw"
      ;;
    omp) raw=$(OMP_SKIP_SETUP=1 fm_run_timed 30 omp models --json </dev/null); jq -r '.models[0].selector // empty' <<< "$raw" ;;
    pi|pi-signed) raw=$(fm_run_timed 30 "$2" --list-models </dev/null); awk 'NR > 1 && NF >= 6 {print $1 "/" $2; exit}' <<< "$raw" ;;
    opencode) raw=$(fm_run_timed 30 opencode models </dev/null); awk '/^[^[:space:]]+\/[^[:space:]]+$/ {print; exit}' <<< "$raw" ;;
    cursor) raw=$(fm_cursor_list_models "$2"); fm_cursor_catalog_ids <<< "$raw" | awk 'NF {print; exit}' ;;
    agy) raw=$(fm_run_timed 30 agy models </dev/null); awk 'NF >= 2 {print $1; exit}' <<< "$raw" ;;
  esac
}

checked=0
for harness in codex claude omp pi pi-signed opencode cursor agy; do
  binary=$harness
  if [ "$harness" = cursor ]; then
    binary=$(fm_cursor_resolve_binary 2>/dev/null) || binary=''
  fi
  if [ -z "$binary" ] || ! command -v "$binary" >/dev/null 2>&1; then
    printf 'skip - %s catalog adapter: executable absent\n' "$harness"
    continue
  fi
  version=$("$binary" --version 2>&1) || version='version unavailable'
  model=$(listed_id "$harness" "$binary" 2>/dev/null || true)
  if [ -z "$model" ]; then
    [ "$forced" != 1 ] || fail "$harness $version: its own listing named no model"
    printf 'skip - %s %s: no listed model (signed out or no catalog)\n' "$harness" "$version"
    continue
  fi
  # One invocation queries the catalog once: the listed id comes first, so a
  # refusal naming only the absent id proves both verdicts.
  jq -n --arg h "$harness" --arg m "$model" --arg a "$ABSENT" \
    '{version:1,roles:{live:{($h):{model:$m}},absent:{($h):{model:$a}}},retired:[]}' > "$TMP_ROOT/home/config/model-index.json"
  if "$TOOL" check > "$TMP_ROOT/verdict" 2>&1; then
    fail "$harness $version: absent id was accepted ($(cat "$TMP_ROOT/verdict"))"
  fi
  verdict=$(cat "$TMP_ROOT/verdict")
  assert_not_contains "$verdict" 'catalog unavailable' "$harness $version: the adapter could not read the catalog its CLI lists"
  assert_contains "$verdict" "id '$ABSENT' absent or retired" "$harness $version: absence did not receive a catalog verdict"
  printf 'ok - %s %s: catalog id accepted; absent id refused\n' "$harness" "$version"
  checked=$((checked + 1))
done
if [ "$checked" = 0 ]; then
  [ "$forced" != 1 ] || fail 'no installed native catalog adapter was checked'
  printf 'skip: live: no installed native adapter has an available catalog\n'
  exit 0
fi
printf '# model-index live adapters checked: %s\n' "$checked"
