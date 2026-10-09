#!/usr/bin/env bash
set -eu

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_WATCH_LOADER_LIVE_E2E node npm
export FM_PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$FM_PI_PACKAGE_DIR/package.json" ] || fail "Pi package absent: set FM_PI_PACKAGE_DIR to the installed SDK"
node "$ROOT/tests/fm-pi-watch-loader-live.test.mjs"
