#!/usr/bin/env bash
# Run: FM_JEV_GUARD_CLAUDE_LIVE=1 bash tests/fm-jev-guard-claude-live-e2e.test.sh
# Installed Claude submits native prompts only to private scripted providers.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_JEV_GUARD_CLAUDE_LIVE claude python3 node jq curl bash
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=tests/fm-jev-guard-native-helpers.sh
. "$ROOT/tests/fm-jev-guard-native-helpers.sh"
fm_jev_native_run claude
