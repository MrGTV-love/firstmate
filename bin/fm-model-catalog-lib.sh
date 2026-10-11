#!/usr/bin/env bash
# fm-model-catalog-lib.sh - the single owner of reading a harness's own model catalog.
#
# Sourced, never executed. bin/fm-model-index.sh (absent or retired ids) and
# bin/fm-model-freshness.sh (older than the newest catalog model) both read
# catalogs through it, so the discovery command of each harness is stated once.
#
#   fm_model_catalog <harness> <scratch-dir>
#       Prints the normalized catalog {"models":[{"id":"...","resolved_id":"..."}]}
#       (resolved_id is optional) and returns 0, or returns non-zero when the
#       catalog cannot be read. With FM_MODEL_CATALOG_DIR set it prints
#       $FM_MODEL_CATALOG_DIR/<harness>.json and never runs live discovery.
#       The scratch directory must exist and be writable.
#   fm_model_catalog_normalize <harness>
#       Reads the raw output of the harness's discovery command on stdin (for
#       codex, the models_cache.json content) and prints the normalized catalog.
#       bin/fm-spawn.sh uses it for a listing its own validators already read.
#   fm_model_catalog_valid <file>
#       0 iff <file> holds exactly one normalized catalog object with at least
#       one model.
#
# Live discovery, each from the harness's own surface and never inferred from a
# model name: Codex models_cache.json; Claude SDK initialize (no prompt);
# omp models --json; Pi --list-models; OpenCode models; Cursor --list-models;
# agy models. Other harnesses need an export from their own documented surface.
#
# TIME LIMIT. Every discovery command runs under one 30 second limit. Per-harness
# limits are a follow-up: they need idle and heavy-load measurements first.
#
# shellcheck disable=SC2034 # Sourced library: callers read its output.
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
FM_MODEL_CATALOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_MODEL_CATALOG_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$FM_MODEL_CATALOG_LIB_DIR/fm-cursor-lib.sh"

fm_model_catalog_normalize() {  # <harness>; stdin: raw discovery output
  case "$1" in
    codex)
      jq '{models: [.models[] | {id: .slug}]}'
      ;;
    claude)
      jq -s '{models: [ .[] | select(.type == "control_response" and .response.request_id == "model-index" and .response.subtype == "success") |
        .response.response.models[] | {id: .value, resolved_id: .resolvedModel}, {id: .resolvedModel} ] | unique_by(.id)}'
      ;;
    omp)
      jq '{models: [.models[] | {id: .selector}]}'
      ;;
    pi|pi-signed)
      awk 'NR > 1 && NF >= 6 {print $1 "/" $2}' | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    opencode)
      jq -Rsc '{models: [split("\n")[] | select(test("^[^[:space:]]+/[^[:space:]]+$")) | {id: .}]}'
      ;;
    cursor)
      fm_cursor_catalog_ids | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    agy)
      awk 'NF >= 2 {print $1}' | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    *) return 1 ;;
  esac
}

fm_model_catalog() {  # <harness> <scratch-dir>
  local h=$1 scratch=$2 raw bin
  if [ -n "${FM_MODEL_CATALOG_DIR:-}" ]; then
    cat "$FM_MODEL_CATALOG_DIR/$h.json"
    return
  fi
  case "$h" in
    codex)
      raw=$(cat "${CODEX_HOME:-$HOME/.codex}/models_cache.json") || return 1
      ;;
    claude)
      printf '%s\n' '{"type":"control_request","request_id":"model-index","request":{"subtype":"initialize"}}' > "$scratch/initialize.json"
      # Timed runners may detach stdin; reopen the protocol input in the child.
      # shellcheck disable=SC2016 # Positional expansion belongs to the child.
      raw=$(fm_run_timed 30 bash -c 'exec claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence --setting-sources "" < "$1"' _ "$scratch/initialize.json") || return 1
      ;;
    omp)
      raw=$(OMP_SKIP_SETUP=1 fm_run_timed 30 omp models --json </dev/null) || return 1
      ;;
    pi|pi-signed)
      raw=$(fm_run_timed 30 "$h" --list-models </dev/null) || return 1
      ;;
    opencode)
      raw=$(fm_run_timed 30 opencode models </dev/null) || return 1
      ;;
    cursor)
      bin=$(fm_cursor_resolve_binary) || return 1
      raw=$(fm_cursor_list_models "$bin") || return 1
      ;;
    agy)
      raw=$(fm_run_timed 30 agy models </dev/null) || return 1
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$raw" | fm_model_catalog_normalize "$h"
}

fm_model_catalog_valid() {  # <file>
  jq -se 'length == 1 and (.[0] | type == "object" and (.models | type == "array" and length > 0 and all(.[]; type == "object" and (.id | type == "string" and length > 0) and ((has("resolved_id") | not) or (.resolved_id | type == "string" and length > 0)))))' "$1" >/dev/null 2>&1
}
