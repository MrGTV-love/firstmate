#!/usr/bin/env bash
# Stop-hook wrapper that runs the published jev-belay hook (belay.mjs) for a
# Firstmate-launched Claude worker, with the TypeSafe key delivered at call time.
# Usage (registered by bin/fm-spawn.sh in the worker's .claude/settings.local.json):
#   FM_HOME=<home> bin/fm-jev-belay-hook.sh < Claude Stop payload
#
# belay.mjs reads the key only from its own process environment, and Firstmate
# keeps the key out of worker environments, so this wrapper resolves it with
# fm_typesafe_key (environment, home .env, then the primary home .env) and sets
# it for the one node process it execs: never in Claude's environment, never in
# a file, never on argv.
# belay.mjs comes from the pinned, gitignored clone of valentynkit/jev-belay at
# <primary home>/data/vendor/jev-belay (commit ef719db7eaadc56aa4def86c4da4ffff5bcbca35).
# It runs only when the file's git blob id equals the pin, so a changed or
# replaced file is never executed with the key. docs/configuration.md "Jev belay
# Stop hook" owns the contract and the install command.
# Every refusal exits 0 silently: a missing clone, key, node, or a pin mismatch
# must never block or delay a worker's stop. belay.mjs keeps its published
# defaults; only the variables that could redirect the key or change the model
# pin (JEV_BASE_URL, JEV_MODEL, JEV_API_KEY and the plugin option copy) are
# cleared first.
# FM_JEV_BELAY_BLOB overrides the pin only when FM_TEST_SEAM=1.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JEV_BELAY_BLOB=2dec6cfbeeefb364d916176680e2598abc4e0dde
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_JEV_BELAY_BLOB:-}" ]; then
  JEV_BELAY_BLOB=$FM_JEV_BELAY_BLOB
fi

# shellcheck source=bin/fm-typesafe-lib.sh
. "$SCRIPT_DIR/fm-typesafe-lib.sh"

home=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
primary=$(fm_firstmate_root_home "$home" 2>/dev/null) || exit 0
belay="$primary/data/vendor/jev-belay/belay.mjs"
{ [ -f "$belay" ] && [ ! -L "$belay" ]; } || exit 0
command -v node >/dev/null 2>&1 || exit 0
[ "$(git hash-object -- "$belay" 2>/dev/null)" = "$JEV_BELAY_BLOB" ] || exit 0
fm_typesafe_key "$home" || exit 0

unset JEV_BASE_URL JEV_MODEL JEV_API_KEY CLAUDE_PLUGIN_OPTION_TYPESAFE_API_KEY
TYPESAFE_API_KEY=$TYPESAFE_API_KEY_PRIVATE exec node "$belay"
