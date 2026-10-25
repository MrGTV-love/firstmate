#!/usr/bin/env bash
# Claude UserPromptSubmit and StopFailure hook: release main's presentation hold.
#
# Registered in tracked .claude/settings.json for both events. StopFailure ends
# a main turn on an API error, which fires no Stop hook. A submitted prompt opens
# a new main turn - a typed prompt, a steer, or the turn an asyncRewake Stop hook
# wakes (docs/verification/runtime-backends.md) - so the previous turn has ended
# by some route, including a mid-stream Escape, which fires no hook at all.
# .agents/skills/harness-adapters/references/harness/claude.md records both
# events. Whatever presentation hold that turn left
# (fm_wake_main_presentation_hold in bin/fm-wake-lib.sh) no longer holds its
# rows, so a later supervision-host close for them is delivered.
#
# Only the genuine primary's session-lock owner releases it, and a home without
# a hold is untouched. The hook is always silent and exits 0: its stdout would
# become prompt context, and it never blocks a prompt.
set -u
[ "$#" -eq 0 ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
HOLD="$STATE/.main-eligible-rows.held"

cat >/dev/null 2>&1 || true
[ -e "$HOLD" ] || exit 0

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_session_lock_owned_by_self "$STATE" || exit 0

fm_wake_main_presentation_release "$(cat "$HOLD" 2>/dev/null || true)" >/dev/null 2>&1 || true
exit 0
