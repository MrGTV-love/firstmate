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
#   fm_model_catalog_valid <file>
#       0 iff <file> holds exactly one normalized catalog object with at least
#       one model.
#   fm_model_catalog_bound <harness>
#       Prints the time limit in seconds that discovery uses for the harness.
#
# Live discovery, each from the harness's own surface and never inferred from a
# model name: Codex models_cache.json; Claude SDK initialize (no prompt);
# omp models --json; Pi --list-models; OpenCode models; Cursor --list-models;
# agy models. Other harnesses need an export from their own documented surface.
#
# TIME LIMITS. Measured 2026-10-10 on the 18-core, 128 GB Mac Studio that runs
# the fleet; the full record is docs/verification/model-catalog-latency.md.
# A truly idle host was not obtainable (the fleet kept the load average near 60,
# about 3.3 times the core count), so the "idle" column is that ordinary busy
# host. The "heavy" column added 36 CPU burners (twice the core count) and 4
# disk writers, which drove the load average to 109 (6 times the core count).
#   harness  idle (n=5)   heavy (n=10)   limit  margin over the worst heavy run
#   claude   1.5-4.4 s    3.5-7.2 s      30 s   4.2x
#   omp      0.4-1.6 s    2.8-5.7 s      25 s   4.4x
#   agy      0.7-1.7 s    0.8-2.2 s      10 s   4.6x
#   pi       0.3-0.4 s    0.5-1.9 s      10 s   5.2x
#   codex    0.02-0.03 s  0.01-0.04 s     5 s   a cache-file read; only a stalled disk reaches it
# The rule is a limit of at least 4 times the slowest run under heavy load, so a
# discovery that is merely slow on a loaded host still answers, while a hung one
# is cut off. pi-signed runs the same listing as pi and shares its limit.
# opencode and cursor were not installed on the measurement host, so their
# limits keep the 30 s this code used before the measurement and are NOT
# measured; re-measure them with the record's method when one is installed.
# FM_MODEL_CATALOG_BOUND_<HARNESS> (upper case, '-' as '_') overrides a limit,
# for tests that need a fast hang and for a host that measures differently.
#
# shellcheck disable=SC2034 # Sourced library: callers read its output.
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
FM_MODEL_CATALOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_MODEL_CATALOG_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$FM_MODEL_CATALOG_LIB_DIR/fm-cursor-lib.sh"

fm_model_catalog_bound() {  # <harness>
  local h=$1 override_name override
  override_name="FM_MODEL_CATALOG_BOUND_$(printf '%s' "$h" | tr '[:lower:]-' '[:upper:]_')"
  override=${!override_name:-}
  case "$override" in
    '') ;;
    0* | *[!0-9]*) ;; # a zero or malformed bound would disable the limit
    *) printf '%s\n' "$override"; return 0 ;;
  esac
  case "$h" in
    claude) printf '30\n' ;;
    omp) printf '25\n' ;;
    agy) printf '10\n' ;;
    pi | pi-signed) printf '10\n' ;;
    codex) printf '5\n' ;;
    *) printf '30\n' ;;
  esac
}

fm_model_catalog() {  # <harness> <scratch-dir>
  local h=$1 scratch=$2 raw bin bound
  if [ -n "${FM_MODEL_CATALOG_DIR:-}" ]; then
    cat "$FM_MODEL_CATALOG_DIR/$h.json"
    return
  fi
  bound=$(fm_model_catalog_bound "$h")
  case "$h" in
    codex)
      jq '{models: [.models[] | {id: .slug}]}' "${CODEX_HOME:-$HOME/.codex}/models_cache.json"
      ;;
    claude)
      printf '%s\n' '{"type":"control_request","request_id":"model-index","request":{"subtype":"initialize"}}' > "$scratch/initialize.json"
      # Timed runners may detach stdin; reopen the protocol input in the child.
      # shellcheck disable=SC2016 # Positional expansion belongs to the child.
      raw=$(fm_run_timed "$bound" bash -c 'exec claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence --setting-sources "" < "$1"' _ "$scratch/initialize.json") || return 1
      jq -s '{models: [ .[] | select(.type == "control_response" and .response.request_id == "model-index" and .response.subtype == "success") |
        .response.response.models[] | {id: .value, resolved_id: .resolvedModel}, {id: .resolvedModel} ] | unique_by(.id)}' <<< "$raw"
      ;;
    omp)
      raw=$(OMP_SKIP_SETUP=1 fm_run_timed "$bound" omp models --json </dev/null) || return 1
      jq '{models: [.models[] | {id: .selector}]}' <<< "$raw"
      ;;
    pi|pi-signed)
      raw=$(fm_run_timed "$bound" "$h" --list-models </dev/null) || return 1
      printf '%s\n' "$raw" | awk 'NR > 1 && NF >= 6 {print $1 "/" $2}' | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    opencode)
      raw=$(fm_run_timed "$bound" opencode models </dev/null) || return 1
      jq -Rsc '{models: [split("\n")[] | select(test("^[^[:space:]]+/[^[:space:]]+$")) | {id: .}]}' <<< "$raw"
      ;;
    cursor)
      bin=$(fm_cursor_resolve_binary) || return 1
      raw=$(fm_cursor_list_models "$bin") || return 1
      printf '%s\n' "$raw" | fm_cursor_catalog_ids | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    agy)
      raw=$(fm_run_timed "$bound" agy models </dev/null) || return 1
      printf '%s\n' "$raw" | awk 'NF >= 2 {print $1}' | jq -Rsc '{models: [split("\n")[] | select(length > 0) | {id: .}]}'
      ;;
    *) return 1 ;;
  esac
}

fm_model_catalog_valid() {  # <file>
  jq -se 'length == 1 and (.[0] | type == "object" and (.models | type == "array" and length > 0 and all(.[]; type == "object" and (.id | type == "string" and length > 0) and ((has("resolved_id") | not) or (.resolved_id | type == "string" and length > 0)))))' "$1" >/dev/null 2>&1
}
