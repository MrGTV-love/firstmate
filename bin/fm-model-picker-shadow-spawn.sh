#!/usr/bin/env bash
# fm-model-picker-shadow-spawn.sh - observe one launch in shadow mode.
# Usage: fm-model-picker-shadow-spawn.sh --brief PATH --harness NAME [--model ID]
#        [--effort LEVEL] --rules PATH [--never-send PATH] [--kind ship|scout]
#
# Called by bin/fm-spawn.sh after a ship or scout launch has been delivered, so the
# picker observes dispatches that never pass through the typed resolver. It builds the
# launch observation (the sanitized launch-brief task text, the actual route, one
# bounded quota snapshot) and hands it to bin/fm-model-picker-shadow.sh --observe.
#
# Shadow only: it prints nothing, exits 0 on every failure, and no caller reads its
# output. bin/fm-spawn.sh wraps it in fm_run_timed; this tool also bounds its own
# quota read. The flag is checked by the caller through
# bin/fm-model-picker-shadow-lib.sh, and again here so a standalone call is inert.
# docs/configuration.md "Shadow model picker (FM_MODEL_PICKER_SHADOW)" owns the contract.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-model-picker-shadow-lib.sh
. "$SCRIPT_DIR/fm-model-picker-shadow-lib.sh"
fm_model_picker_shadow_enabled 2>/dev/null || exit 0

BRIEF='' HARNESS='' MODEL='' EFFORT='' RULES='' NEVER_SEND='' KIND='ship'
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) BRIEF=${2:-}; shift 2 ;;
    --harness) HARNESS=${2:-}; shift 2 ;;
    --model) MODEL=${2:-}; shift 2 ;;
    --effort) EFFORT=${2:-}; shift 2 ;;
    --rules) RULES=${2:-}; shift 2 ;;
    --never-send) NEVER_SEND=${2:-}; shift 2 ;;
    --kind) KIND=${2:-}; shift 2 ;;
    *) exit 0 ;;
  esac
done
[ -n "$BRIEF" ] && [ -r "$BRIEF" ] && [ -n "$HARNESS" ] || exit 0
case "$KIND" in ship|scout) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=bin/fm-typesafe-lib.sh
. "$SCRIPT_DIR/fm-typesafe-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-shadow-spawn.XXXXXX") || exit 0
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
TEXT="$TMP/task.txt"
RESOLVED="$TMP/rules.json"
RESULT="$TMP/result.json"
QUOTA="$TMP/quota.json"

observe() {  # <status> [reason]
  local status=$1 reason=${2:-}
  # measured: value=25 date=2026-10-23 host=Mac-Studio margin=1.7 (three bounded five-second provider calls plus policy, helper and SQLite overhead; one stalled-call run measured 5.2 s)
  fm_run_timed 25 "$SCRIPT_DIR/fm-model-picker-shadow.sh" --observe \
    --brief "$BRIEF" --task-text "$TEXT" --rules "$RESOLVED" --result "$RESULT" \
    --quota "$QUOTA" --status "$status" --reason "$reason" \
    --never-send "$NEVER_SEND" \
    3< <(printf '%s' "${TYPESAFE_API_KEY_PRIVATE:-}") >/dev/null 2>&1 || true
  exit 0
}

if ! fm_typesafe_brief_task "$BRIEF" "$NEVER_SEND" "$TEXT" "$KIND" 2>/dev/null; then
  printf '%s' '{}' > "$RESULT"
  : > "$RESOLVED"
  : > "$QUOTA"
  observe withheld "${FM_TYPESAFE_WITHHELD_REASON:-never-send policy withheld the launch text}"
fi

printf '%s' '{}' > "$RESOLVED"
if [ -n "$RULES" ] && [ -r "$RULES" ]; then
  if resolved=$(FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-$(dirname "$RULES")}" \
      "$SCRIPT_DIR/fm-model-index.sh" profiles "$RULES" 2>/dev/null); then
    printf '%s' "$resolved" > "$RESOLVED"
  else
    cp "$RULES" "$RESOLVED" 2>/dev/null || printf '{}' > "$RESOLVED"
  fi
fi

jq -cn --arg harness "$HARNESS" --arg model "$MODEL" --arg effort "$EFFORT" \
  '{status:"clear", chosen:{profile:{harness:$harness, model:$model, effort:$effort}}, candidates:[]}' \
  > "$RESULT" 2>/dev/null || exit 0

: > "$QUOTA"
if command -v quota-axi >/dev/null 2>&1; then
  # measured: value=10 date=2026-10-23 host=Mac-Studio margin=3.4 (three local quota-axi --json runs on 2026-10-17 took 2.89 s at the slowest)
  fm_run_timed 10 quota-axi --json > "$QUOTA" 2>/dev/null || : > "$QUOTA"
fi

observe clear
