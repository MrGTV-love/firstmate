#!/usr/bin/env bash
# Stop-hook wrapper that runs the published jev-belay hook (belay.mjs) for a
# Firstmate-launched Claude worker, with the TypeSafe key delivered at call time.
# Usage (registered by bin/fm-spawn.sh in the worker's .claude/settings.local.json):
#   FM_HOME=<home> bin/fm-jev-belay-hook.sh < Claude Stop payload
#
# belay.mjs reads the key only from its own process environment, and Firstmate
# keeps the key out of worker environments, so this wrapper resolves it with
# fm_typesafe_key in bin/fm-typesafe-lib.sh (the credential-precedence owner)
# and sets it for the one bounded node process: never in Claude's environment,
# never in a file, never on argv.
# belay.mjs comes from the pinned, gitignored clone of valentynkit/jev-belay at
# <primary home>/data/vendor/jev-belay (commit ef719db7eaadc56aa4def86c4da4ffff5bcbca35).
# It runs only when the file's git blob id equals the pin, so a changed or
# replaced file is never executed with the key. docs/configuration.md "Jev belay
# Stop hook" owns the contract and the install command.
# Missing prerequisites or a pin mismatch exit 0 silently.
# Once launched, the wrapper preserves the upstream exit status unless its
# 20-second deadline fires, returning 124 after a 0.2-second termination grace.
# The policy preload checks requests before transport; JEV_BASE_URL, JEV_MODEL,
# JEV_API_KEY and the plugin option copy are cleared before launch.
# FM_JEV_BELAY_BLOB overrides the pin only when FM_TEST_SEAM=1.
set -u

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
case "$SCRIPT_DIR" in
  /*) ;;
  *) SCRIPT_DIR=$PWD/$SCRIPT_DIR ;;
esac
JEV_BELAY_BLOB=2dec6cfbeeefb364d916176680e2598abc4e0dde
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_JEV_BELAY_BLOB:-}" ]; then
  JEV_BELAY_BLOB=$FM_JEV_BELAY_BLOB
fi

unset JEV_BASE_URL JEV_MODEL JEV_API_KEY CLAUDE_PLUGIN_OPTION_TYPESAFE_API_KEY
# shellcheck source=bin/fm-typesafe-lib.sh
. "$SCRIPT_DIR/fm-typesafe-lib.sh"

. "$SCRIPT_DIR/fm-timeout-lib.sh"

fm_jev_belay_run() {
  local home primary belay
  home=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
  primary=$(fm_firstmate_root_home "$home" 2>/dev/null) || exit 0
  belay="$primary/data/vendor/jev-belay/belay.mjs"
  { [ -f "$belay" ] && [ ! -L "$belay" ]; } || exit 0
  command -v node >/dev/null 2>&1 || exit 0
  [ "$(git hash-object -- "$belay" 2>/dev/null)" = "$JEV_BELAY_BLOB" ] || exit 0
  fm_typesafe_key "$home" || exit 0

  FM_HOME=$home TYPESAFE_API_KEY=$TYPESAFE_API_KEY_PRIVATE exec node --import "$SCRIPT_DIR/fm-jev-belay-policy.mjs" "$belay" <&3
}

FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed 20 fm_jev_belay_run 3<&0
