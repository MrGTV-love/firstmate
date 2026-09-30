#!/usr/bin/env bash
# fm-model-index.sh - validate the home model index and resolve dispatch roles.
# Usage: fm-model-index.sh check
#        fm-model-index.sh catalog <harness>
#        fm-model-index.sh resolve <harness> <role> [--stand-in]
#        fm-model-index.sh model <harness> <literal-model|role:<role>|stand-in:<role>>
#        fm-model-index.sh profiles <crew-dispatch.json> [--schema-only]
# Schema owner: docs/configuration.md "Fleet model index".
# Intake/spawn invocations check every active id, including stand-ins, against
# its own harness catalog. No missing catalog or absent id is accepted.
# --schema-only is bootstrap's offline shape/retirement inspection; it never
# fetches catalogs and is not intake authorization. Spawn always checks catalogs.
# A role resolves once; profiles emits concrete JSON, model/resolve emit one id.
# Stand-ins are explicit selections, never automatic failure or quota fallbacks.
# Literal models work without an index; with one they cannot name a retired id.
# FM_HOME / FM_CONFIG_OVERRIDE select the index like other home configuration.
# FM_MODEL_CATALOG_DIR optionally supplies authoritative catalog exports (or test
# fixtures), <harness>.json, normalized as {"models":[{"id":"...",
# "resolved_id":"..."}]}. resolved_id is optional except for aliases.
# An explicit directory must contain every required catalog; never mix exports
# and live discovery. openrouter.json uses its native {"data":[{"id":"..."}]}.
# Live discovery: Codex models_cache.json; Claude SDK initialize (no prompt);
# omp models --json; Pi --list-models; OpenCode models; Cursor --list-models;
# agy models. Other harnesses require an export from their authoritative surface.
# Provider-qualified openrouter ids additionally require /api/v1/models.
# Commands are bounded at 30 seconds; no credential or catalog cache is changed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
INDEX="$CONFIG/model-index.json"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"

die() { printf 'model-index: %s\n' "$*" >&2; exit 2; }
usage() { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || die 'jq required'
VERB=${1:-}
shift || die 'command required (see --help)'
case "$VERB:$#" in check:0|catalog:1|resolve:2|resolve:3|model:2|profiles:1|profiles:2) ;; *) die 'invalid arguments (see --help)' ;; esac
if [ "$VERB" = resolve ] && [ "$#" = 3 ] && [ "$3" != --stand-in ]; then die 'expected --stand-in'; fi
SCHEMA_ONLY=0
if [ "$VERB" = profiles ] && [ "$#" = 2 ]; then
  [ "$2" = --schema-only ] || die 'expected --schema-only'
  SCHEMA_ONLY=1
fi
TMP=$(mktemp -d) || die 'mktemp failed'
trap 'rm -rf "$TMP"' EXIT
if [ -e "$INDEX" ] || [ -L "$INDEX" ]; then
  [ -f "$INDEX" ] && [ -r "$INDEX" ] || die "index is not a readable regular file: $INDEX"
  cp "$INDEX" "$TMP/index.json" || die 'could not snapshot index'
else
  case "$VERB" in check|resolve) die "index required: $INDEX" ;; esac
  printf '%s\n' '{"version":1,"roles":{},"retired":[]}' > "$TMP/index.json"
fi
jq -e '
  def token: type == "string" and length > 0 and (test("[[:space:][:cntrl:]]") | not);
  type == "object" and .version == 1 and
  (.roles | type == "object") and (.retired | type == "array") and
  all(.retired[]; token) and
  all(.roles | to_entries[];
    (.key | token) and (.value | type == "object" and length > 0) and
    all(.value | to_entries[];
      (.key | IN("claude","codex","omp","pi","pi-signed","opencode","cursor","agy","grok","kimi","gemini","muse","rovo","devin")) and
      (.value | type == "object" and ((keys - ["model","stand_in"]) | length == 0)) and (.value.model | token) and
      (.value | (has("stand_in") | not) or (.stand_in | token))))
' "$TMP/index.json" >/dev/null 2>&1 || die "malformed index: $INDEX"
jq -r '.roles | to_entries[] | .key as $role | .value | to_entries[] |
  .key as $h | (.value.model, .value.stand_in // empty) | [$role,$h,.] | @tsv' "$TMP/index.json" > "$TMP/entries"

catalog() { # <harness>; output normalized ids and optional alias targets
  local h=$1 raw bin
  if [ -n "${FM_MODEL_CATALOG_DIR:-}" ]; then
    cat "$FM_MODEL_CATALOG_DIR/$h.json" || return 1
    return 0
  fi
  case "$h" in
    codex)
      jq '{models: [.models[] | {id: .slug}]}' "${CODEX_HOME:-$HOME/.codex}/models_cache.json"
      ;;
    claude)
      printf '%s\n' '{"type":"control_request","request_id":"model-index","request":{"subtype":"initialize"}}' > "$TMP/initialize.json"
      # Timed runners may detach stdin; reopen the protocol input in the child.
      # shellcheck disable=SC2016 # Positional expansion belongs to the child.
      raw=$(fm_run_timed 30 bash -c 'exec claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence --setting-sources "" < "$1"' _ "$TMP/initialize.json") || return 1
      jq -s '{models: [ .[] | select(.type == "control_response" and .response.request_id == "model-index" and .response.subtype == "success") |
        .response.response.models[] | {id: .value, resolved_id: .resolvedModel}, {id: .resolvedModel} ] | unique_by(.id)}' <<< "$raw"
      ;;
    omp)
      raw=$(OMP_SKIP_SETUP=1 fm_run_timed 30 omp models --json </dev/null) || return 1
      jq '{models: [.models[] | {id: .selector}]}' <<< "$raw"
      ;;
    pi|pi-signed)
      raw=$(fm_run_timed 30 "$h" --list-models </dev/null) || return 1
      printf '%s\n' "$raw" | awk 'NR > 1 && NF >= 6 {print $1 "/" $2}' | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    opencode)
      fm_run_timed 30 opencode models </dev/null | jq -Rsc '{models: [split("\n")[] | select(test("^[^[:space:]]+/[^[:space:]]+$")) | {id: .}]}'
      ;;
    cursor)
      bin=$(fm_cursor_resolve_binary) || return 1
      raw=$(fm_cursor_list_models "$bin") || return 1
      printf '%s\n' "$raw" | awk '/ - / {sub(/ - .*/, ""); sub(/^[[:space:]]+/, ""); print}' | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    agy)
      raw=$(fm_run_timed 30 agy models </dev/null) || return 1
      printf '%s\n' "$raw" | awk 'NF >= 2 {print $1}' | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    *) printf 'model-index: %s requires an authoritative catalog export via FM_MODEL_CATALOG_DIR\n' "$h" >&2; return 1 ;;
  esac
}
validate_catalog() {
  jq -e '.models | type == "array" and length > 0 and all(.[]; (.id | type == "string" and length > 0) and ((has("resolved_id") | not) or (.resolved_id | type == "string" and length > 0)))' "$1" >/dev/null 2>&1
}
if [ "$VERB" = catalog ]; then
  catalog "$1" > "$TMP/catalog.json" || die "catalog unavailable for $1"
  validate_catalog "$TMP/catalog.json" || die "malformed or empty catalog for $1"
  cat "$TMP/catalog.json"
  exit 0
fi
while IFS=$'\t' read -r role harness model; do
  [ -n "$harness" ] || continue
  jq -e --arg m "$model" 'all(.retired[]; . != $m and . != ($m | split("/") | last))' "$TMP/index.json" >/dev/null || die "retired id '$model' in role '$role' ($harness)"
  [ "$SCHEMA_ONLY" = 0 ] || continue
  if [ ! -f "$TMP/$harness.json" ]; then
    catalog "$harness" > "$TMP/$harness.json" || die "catalog unavailable for $harness"
    validate_catalog "$TMP/$harness.json" || die "malformed or empty catalog for $harness"
  fi
  jq -e --arg m "$model" --slurpfile idx "$TMP/index.json" '
    [.models[] | select(.id == $m)] as $found |
    ($found | length > 0) and all($found[]; (.resolved_id // .id) as $id |
      all($idx[0].retired[]; . != $id and . != ($id | split("/") | last)))
  ' "$TMP/$harness.json" >/dev/null || die "id '$model' absent or retired in $harness catalog (role '$role')"
  case "$model" in openrouter/*)
    if [ ! -f "$TMP/openrouter.json" ]; then
      if [ -n "${FM_MODEL_CATALOG_DIR:-}" ]; then
        cp "$FM_MODEL_CATALOG_DIR/openrouter.json" "$TMP/openrouter.json" || die 'OpenRouter catalog unavailable'
      else
        curl -fsS --max-time 30 https://openrouter.ai/api/v1/models > "$TMP/openrouter.json" || die 'OpenRouter catalog unavailable'
      fi
    fi
    jq -e --arg m "${model#openrouter/}" '.data | type == "array" and any(.[]; .id == $m)' "$TMP/openrouter.json" >/dev/null || die "id '$model' absent in OpenRouter catalog"
    ;;
  esac
done < "$TMP/entries"

# One transformation shared by manual intake, typed intake, and spawn. Removing
# role/stand_in ensures downstream consumers see only the concrete model.
# shellcheck disable=SC2016 # jq variables, not shell expansions.
RESOLVE_JQ='
  def resolve_profile:
    if type != "object" then .
    elif has("role") then
      if has("model") then error("profile cannot name both role and model")
      elif (.role | type) != "string" or (.role | length) == 0 then error("role must be a non-empty string")
      elif has("stand_in") and (.stand_in | type) != "boolean" then error("stand_in must be boolean")
      else . as $p | $idx[0].roles[$p.role][$p.harness] as $entry |
        (if $p.stand_in == true then $entry.stand_in else $entry.model end) as $model |
        if $model == null then error("role or stand-in not configured: " + $p.harness + ":" + $p.role)
        else .model = $model | del(.role, .stand_in) end
      end
    elif has("stand_in") then error("stand_in requires role")
    else . end;
  def retired_guard:
    . as $p | if type == "object" and has("model") and
      any($idx[0].retired[]; . == $p.model or . == ($p.model | split("/") | last))
    then error("retired model: " + $p.model) else . end;
  def profile: resolve_profile | retired_guard;
  def profile_set: if type == "array" then map(profile) else profile end;
'
case "$VERB" in
  check) printf 'model-index: catalogs checked; all active ids available and not retired\n' ;;
  resolve)
    jq -n --arg h "$1" --arg r "$2" --argjson stand "$([ "$#" = 3 ] && printf true || printf false)" '{harness:$h,role:$r,stand_in:$stand}' > "$TMP/profile.json"
    jq -er --slurpfile idx "$TMP/index.json" "$RESOLVE_JQ profile | .model" "$TMP/profile.json"
    ;;
  model)
    case "$2" in
      role:*) p=$(jq -n --arg h "$1" --arg r "${2#role:}" '{harness:$h,role:$r}') ;;
      stand-in:*) p=$(jq -n --arg h "$1" --arg r "${2#stand-in:}" '{harness:$h,role:$r,stand_in:true}') ;;
      *) p=$(jq -n --arg h "$1" --arg m "$2" '{harness:$h,model:$m}') ;;
    esac
    jq -er --slurpfile idx "$TMP/index.json" "$RESOLVE_JQ profile | .model" <<< "$p"
    ;;
  profiles)
    jq --slurpfile idx "$TMP/index.json" "$RESOLVE_JQ
      if (.rules | type) == \"array\" then .rules |= map(if type == \"object\" and has(\"use\") then .use |= profile_set else . end) else . end |
      if type == \"object\" and has(\"default\") then .default |= profile_set else . end" "$1"
    ;;
esac
