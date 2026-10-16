#!/usr/bin/env bash
# Claude Code command hook that runs the ten-levels jev-guard adapter
# (bin/fm-jev-guard-claude.ts) for one Firstmate ship or scout worker.
# Usage (registered by bin/fm-spawn.sh in the worker's .claude/settings.local.json):
#   bin/fm-jev-guard-hook.sh <home> <config> <state> <task> <worktree> <data> <project> <policy> < Claude hook payload
# The adapter is TypeScript: bun runs it when installed, otherwise node with
# type stripping. Missing or failed active runtimes return blocking exit 2 with
# sanitized diagnostics; successful handler stdout retains its hook semantics.
# Post-tool feedback remains advisory-only/no protection on this integration.
# docs/configuration.md "Jev guard" owns the contract.
set -u
[ "${8:-}" = FIRSTMATE_JEV_GUARD_V1 ] || exit 0

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
adapter="$SCRIPT_DIR/fm-jev-guard-claude.ts"
if command -v bun >/dev/null 2>&1; then
  runtime=(bun)
elif command -v node >/dev/null 2>&1; then
  runtime=(node --experimental-strip-types --no-warnings)
else
  [ "${7:-}" = firstmate ] || exit 0
  printf '%s\n' '[jev-guard] Review required: RuntimeUnavailableError. REVIEW_ON_UNAVAILABLE_V1.' >&2
  exit 2
fi

# Publish only a successful handler's stdout. Startup errors and partial output
# can contain input or secrets, so never relay either stream after failure.
if output=$("${runtime[@]}" "$adapter" "$@" 2>/dev/null); then
  printf '%s' "$output"
  exit 0
else
  runtime_status=$?
fi
[ "${7:-}" = firstmate ] || exit 0
printf '[jev-guard] Review required: RuntimeExecutionError (exit_status=%s). REVIEW_ON_UNAVAILABLE_V1.\n' "$runtime_status" >&2
exit 2
