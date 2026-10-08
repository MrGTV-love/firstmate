#!/usr/bin/env bash
# Claude Code command hook that runs the ten-levels jev-guard adapter
# (bin/fm-jev-guard-claude.ts) for one Firstmate ship or scout worker.
# Usage (registered by bin/fm-spawn.sh in the worker's .claude/settings.local.json):
#   bin/fm-jev-guard-hook.sh <home> <config> <state> <task> <worktree> <data> <project> < Claude hook payload
# The adapter is TypeScript: bun runs it when installed, otherwise node with
# type stripping. With neither, the hook exits 0 and the tool call proceeds,
# the same allow the upstream guard gives when Jev cannot answer.
# docs/configuration.md "Jev guard" owns the contract.
set -u

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
adapter="$SCRIPT_DIR/fm-jev-guard-claude.ts"
if command -v bun >/dev/null 2>&1; then
  exec bun "$adapter" "$@"
fi
command -v node >/dev/null 2>&1 || exit 0
exec node --experimental-strip-types --no-warnings "$adapter" "$@"
