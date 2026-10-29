#!/usr/bin/env bash
# Captain-call churn and secondmate pause transitions: an open or reheld
# captain call bounds stale churn, a failed wake append never arms the hold
# throttle, and a secondmate pause surfaces, clears, and reclassifies.
# The stale/wedge/write-deferral cases live in
# tests/fm-watch-triage-waits.test.sh; the declared-wait cases live in
# tests/fm-watch-triage-waits-declared.test.sh; the away/quiet cases live in
# tests/fm-watch-triage-waits-away.test.sh.
set -u

# shellcheck source=tests/fm-watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-helpers.sh"

test_open_captain_call_bounds_stale_churn
test_stale_churn_without_a_captain_call_still_alarms
test_failed_wake_append_does_not_arm_the_captain_hold_throttle
test_reheld_captain_call_starts_its_own_resurface_window
test_secondmate_paused_resurfaces_in_normal_mode
test_secondmate_captain_held_resurfaces_in_normal_mode
test_secondmate_nonpaused_stale_remains_suppressed
test_secondmate_unpause_clears_pause_tracking
