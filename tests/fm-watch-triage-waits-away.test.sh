#!/usr/bin/env bash
# Away-mode and quiet-mode triage: a captain hold, backlog hold, or declared
# pause under an away record is never rechecked or handed off, and one-shot
# away mode keeps the same contract.
# The stale/wedge/write-deferral cases live in
# tests/fm-watch-triage-waits.test.sh; the declared-wait cases live in
# tests/fm-watch-triage-waits-declared.test.sh; the captain-call and
# secondmate pause cases live in tests/fm-watch-triage-waits-pauses.test.sh.
set -u

# shellcheck source=tests/fm-watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-helpers.sh"

test_afk_paused_changed_pane_hands_off_plain_stale
test_captain_held_never_rechecked_while_away_record_exists
test_live_captain_held_first_sight_silenced_by_away_record
test_backlog_hold_never_rechecked_while_away_record_exists
test_afk_one_shot_never_hands_off_captain_held_under_away_record
test_captain_held_rechecked_under_a_quiet_record
