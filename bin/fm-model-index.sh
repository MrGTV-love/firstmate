#!/usr/bin/env bash
# fm-model-index.sh - validate the home model index and resolve dispatch roles.
# Usage: fm-model-index.sh check [<harness> [<model>]]
#        fm-model-index.sh model <harness> <literal-model|role:<role>|stand-in:<role>>
#        fm-model-index.sh entry <harness> <concrete-model>
#        fm-model-index.sh profiles [<crew-dispatch.json>]
#        fm-model-index.sh check-registry <path-to-json>
# Schema owner: docs/configuration.md "Fleet model index".
# check with no arguments is the index-edit check: every active id, including
# stand-ins, against its own harness catalog. check <harness> checks only that
# harness's entries, so fm-config-push can run each under its own account.
# check <harness> <model> is the spawn and intake check of one selected id: a
# retired id refuses, and an id that is that harness's index entry is checked
# against that harness catalog in the caller's environment, so the caller
# chooses the account whose catalog answers.
# Only concrete contradictory evidence refuses: an id absent from a readable
# catalog, or an alias whose resolved id is retired. An unavailable, empty, or
# unreadable catalog, a harness without discovery, or an omp provider its
# listing does not know (extension-registered providers are never listed)
# passes with a notice on stderr.
# model and profiles resolve offline and never fetch a catalog: a role
# resolves once, profiles emits concrete JSON, model emits one id.
# entry emits true or false for exact primary/stand-in membership, offline.
# check-registry requires an index and exactly one readable JSON registry file.
# It scans string values and object keys that are whole identifier tokens (no
# whitespace or control characters), using the retirement rule in the schema owner;
# it never matches a substring in prose. Every distinct retired identifier is
# reported on stderr and makes the command fail; current-only registries pass.
# Invalid JSON (including empty or multiple documents) refuses. This check is
# offline and read-only: it fetches no catalog and writes neither input file.
# Stand-in selection, literal warnings, retirement matching, and Claude context
# suffix matching are owned by docs/configuration.md "Fleet model index".
# model passes a literal through unchanged, without jq, when no index exists.
# FM_HOME / FM_CONFIG_OVERRIDE select the index like other home configuration.
# FM_MODEL_CATALOG_DIR optionally supplies authoritative catalog exports (or test
# fixtures), <harness>.json, normalized as {"models":[{"id":"...",
# "resolved_id":"..."}]}. resolved_id is optional except for aliases.
# With a directory set, live discovery never runs; a missing export is a notice.
# Live discovery: Codex models_cache.json; Claude SDK initialize (no prompt);
# omp models --json; Pi --list-models; OpenCode models; Cursor --list-models;
# agy models. Other harnesses need an export from their authoritative surface.
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
notice() { printf 'model-index: notice: %s\n' "$*" >&2; }
usage() { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
VERB=${1:-}
shift || die 'command required (see --help)'
case "$VERB:$#" in check:0|check:1|check:2|check-registry:1|model:2|entry:2|profiles:0|profiles:1) ;; *) die 'invalid arguments (see --help)' ;; esac
if [ "$VERB" = model ] && [ ! -e "$INDEX" ] && [ ! -L "$INDEX" ]; then
  case "$2" in role:*|stand-in:*) die "index required to resolve '$2': $INDEX" ;; esac
  printf '%s\n' "$2"
  exit 0
fi
command -v jq >/dev/null 2>&1 || die 'jq required'
TMP=$(mktemp -d) || die 'mktemp failed'
trap 'rm -rf "$TMP"' EXIT
HAVE_INDEX=0
if [ -e "$INDEX" ] || [ -L "$INDEX" ]; then
  [ -f "$INDEX" ] && [ -r "$INDEX" ] || die "index is not a readable regular file: $INDEX"
  cp "$INDEX" "$TMP/index.json" || die 'could not snapshot index'
  HAVE_INDEX=1
else
  [ "$VERB" != check-registry ] || die "index required: $INDEX"
  [ "$VERB" != check ] || [ "$#" = 2 ] || die "index required: $INDEX"
  printf '%s\n' '{"version":1,"roles":{},"retired":[]}' > "$TMP/index.json"
fi
jq -se '
  def token: type == "string" and length > 0 and (test("[[:space:][:cntrl:]]") | not);
  length == 1 and (.[0] |
  type == "object" and .version == 1 and
  (.roles | type == "object") and (.retired | type == "array") and
  all(.retired[]; token) and
  all(.roles | to_entries[];
    (.key | token) and (.value | type == "object" and length > 0) and
    all(.value | to_entries[];
      (.key | IN("claude","codex","omp","pi","pi-signed","opencode","cursor","agy","grok","kimi","gemini","muse","rovo","devin")) and
      (.value | type == "object" and ((keys - ["model","stand_in"]) | length == 0)) and (.value.model | token) and
      (.value | (has("stand_in") | not) or (.stand_in | token)))))
' "$TMP/index.json" >/dev/null 2>&1 || die "malformed index: $INDEX"

# The one retirement and index-entry rule, shared by every check and resolution.
# shellcheck disable=SC2016 # jq variables, not shell expansions.
LIB_JQ='
  def base_id: sub("\\[[^\\]]*\\]$"; "");
  def retired($id): ($id | base_id) as $base |
    any($idx[0].retired[]; . == $id or . == $base or . == ($base | split("/") | last));
  def entry($h; $m): any($idx[0].roles[] | .[$h] // empty | (.model, .stand_in // empty); . == $m);
'
if [ "$VERB" = check-registry ]; then
  [ -f "$1" ] && [ -r "$1" ] || die "registry is not a readable regular file: $1"
  jq -sr --slurpfile idx "$TMP/index.json" "$LIB_JQ"'
    if length != 1 then error("registry must contain exactly one JSON document") else .[0] end |
    [.. | (strings, (objects | keys[])) |
      select(length > 0 and (test("[[:space:][:cntrl:]]") | not)) |
      select(retired(.))] | unique[]' "$1" > "$TMP/registry-hits" \
    || die "invalid or unreadable registry: $1"
  if [ -s "$TMP/registry-hits" ]; then
    while IFS= read -r id; do
      printf "model-index: retired id '%s' in registry %s\n" "$id" "$1" >&2
    done < "$TMP/registry-hits"
    exit 2
  fi
  printf 'model-index: registry checked; no retired identifiers\n'
  exit 0
fi

jq -r '.roles | to_entries[] | .key as $role | .value | to_entries[] |
  .key as $h | (.value.model, .value.stand_in // empty) | [$role,$h,.] | @tsv' "$TMP/index.json" > "$TMP/entries"

catalog() { # <harness>; output normalized ids and optional alias targets
  local h=$1 raw bin
  if [ -n "${FM_MODEL_CATALOG_DIR:-}" ]; then
    cat "$FM_MODEL_CATALOG_DIR/$h.json"
    return
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
      raw=$(fm_run_timed 30 opencode models </dev/null) || return 1
      jq -Rsc '{models: [split("\n")[] | select(test("^[^[:space:]]+/[^[:space:]]+$")) | {id: .}]}' <<< "$raw"
      ;;
    cursor)
      bin=$(fm_cursor_resolve_binary) || return 1
      raw=$(fm_cursor_list_models "$bin") || return 1
      printf '%s\n' "$raw" | fm_cursor_catalog_ids | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    agy)
      raw=$(fm_run_timed 30 agy models </dev/null) || return 1
      printf '%s\n' "$raw" | awk 'NF >= 2 {print $1}' | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    *) return 1 ;;
  esac
}
validate_catalog() {
  jq -se 'length == 1 and (.[0] | type == "object" and (.models | type == "array" and length > 0 and all(.[]; type == "object" and (.id | type == "string" and length > 0) and ((has("resolved_id") | not) or (.resolved_id | type == "string" and length > 0)))))' "$1" >/dev/null 2>&1
}
check_entry() { # <role> <harness> <model>; refuses only on catalog evidence
  local role=$1 h=$2 m=$3 f="$TMP/catalog-$2.json"
  if [ "${FM_MODEL_CATALOG_CONTEXT:-}" = unavailable ] && [ -z "${FM_MODEL_CATALOG_DIR:-}" ]; then
    notice "$h catalog unavailable (effective worker account context is not established); '$m' (role '$role') not validated"
    return 0
  fi
  if [ ! -f "$f" ] && [ ! -f "$f.none" ]; then
    { catalog "$h" > "$f" 2>/dev/null </dev/null && validate_catalog "$f"; } || { rm -f "$f"; : > "$f.none"; }
  fi
  if [ -f "$f.none" ]; then
    notice "$h catalog unavailable (no readable listing or FM_MODEL_CATALOG_DIR export); '$m' (role '$role') not validated"
    return 0
  fi
  jq -e --arg m "$m" --arg h "$h" --slurpfile idx "$TMP/index.json" "$LIB_JQ"'
    [.models[] | select(.id == $m)] as $exact |
    (if ($exact | length) == 0 and $h == "claude" then [.models[] | select((.id | base_id) == ($m | base_id))] else $exact end) as $found |
    ($found | length > 0) and all($found[]; retired(.resolved_id // .id) | not)
  ' "$f" >/dev/null && return 0
  case "$h:$m" in omp:*/*)
    if ! jq -e --arg p "${m%%/*}/" 'any(.models[]; .id | startswith($p))' "$f" >/dev/null; then
      notice "omp provider '${m%%/*}' is not in 'omp models --json' (extension-registered providers are never listed); '$m' (role '$role') not validated"
      return 0
    fi
    ;;
  esac
  die "id '$m' absent or retired in $h catalog (role '$role')"
}
refuse_retired() { # <harness> <model> <where>
  if jq -e --arg m "$2" --slurpfile idx "$TMP/index.json" "$LIB_JQ"'retired($m)' -n >/dev/null; then
    die "retired id '$2' $3 ($1)"
  fi
}

if [ "$VERB" = check ]; then
  [ "$#" != 2 ] || refuse_retired "$1" "$2" 'selected'
  while IFS=$'\t' read -r role harness model <&3; do
    [ -n "$harness" ] || continue
    [ "$#" = 0 ] || [ "$harness" = "$1" ] || continue
    [ "$#" != 2 ] || [ "$model" = "$2" ] || continue
    refuse_retired "$harness" "$model" "in role '$role'"
    check_entry "$role" "$harness" "$model"
    [ "$#" != 2 ] || break
  done 3< "$TMP/entries"
  [ "$#" = 2 ] || printf 'model-index: active ids checked; none absent or retired\n'
  exit 0
fi

# One transformation shared by manual intake, typed intake, and spawn. Removing
# role/stand_in ensures downstream consumers see only the concrete model.
# shellcheck disable=SC2016 # jq variables, not shell expansions.
RESOLVE_JQ="$LIB_JQ"'
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
    . as $p | if type == "object" and (.model | type) == "string" and retired($p.model)
    then error("retired model: " + $p.model) else . end;
  def profile: resolve_profile | retired_guard;
  def profile_set: if type == "array" then map(profile) else profile end;
  def literal_warning:
    select(type == "object" and has("model") and (has("role") | not) and
      (.model | type) == "string" and (.harness | type) == "string" and (entry(.harness; .model) | not)) |
    "model-index: warning: literal model \u0027\(.model)\u0027 for \(.harness) is not an index entry; name its role so the next model release is one index edit";
'
case "$VERB" in
  entry)
    jq -r --arg h "$1" --arg m "$2" --slurpfile idx "$TMP/index.json" "$LIB_JQ entry(\$h; \$m)" -n
    ;;
  model)
    case "$2" in
      role:*) p=$(jq -n --arg h "$1" --arg r "${2#role:}" '{harness:$h,role:$r}') ;;
      stand-in:*) p=$(jq -n --arg h "$1" --arg r "${2#stand-in:}" '{harness:$h,role:$r,stand_in:true}') ;;
      *) p=$(jq -n --arg h "$1" --arg m "$2" '{harness:$h,model:$m}') ;;
    esac
    [ "$HAVE_INDEX" = 0 ] || jq -r --slurpfile idx "$TMP/index.json" "$RESOLVE_JQ literal_warning" <<< "$p" >&2
    jq -er --slurpfile idx "$TMP/index.json" "$RESOLVE_JQ profile | .model" <<< "$p"
    ;;
  profiles)
    [ "$#" != 0 ] || exit 0
    jq -s 'if length == 1 and (.[0] | type == "object") then .[0]
      else error("dispatch must contain exactly one JSON object") end' "$1" > "$TMP/dispatch.json" \
      || die "malformed dispatch: $1"
    jq --slurpfile idx "$TMP/index.json" "$RESOLVE_JQ
      if (.rules | type) == \"array\" then .rules |= map(if type == \"object\" and has(\"use\") then .use |= profile_set else . end) else . end |
      if type == \"object\" and has(\"default\") then .default |= profile_set else . end" "$TMP/dispatch.json"
    [ "$HAVE_INDEX" = 0 ] || jq -r --slurpfile idx "$TMP/index.json" "$RESOLVE_JQ
      [(.rules[]? | objects | .use), .default] | .[] | (if type == \"array\" then .[] else . end) | literal_warning" "$TMP/dispatch.json" >&2
    ;;
esac
