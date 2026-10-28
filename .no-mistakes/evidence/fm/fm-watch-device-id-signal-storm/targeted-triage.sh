# Targeted driver: only the device-shift, dedupe, beacon and stall regressions from tests/fm-watch-triage.test.sh.
set -u
. "$PWD/tests/fm-watch-triage-helpers.sh"
test_status_device_shift_does_not_resignal || exit $?
test_status_identity_replacement_still_signals || exit $?
test_status_device_shift_lagging_log_reads_only_new_bytes || exit $?
test_status_device_shift_keeps_owned_appends || exit $?
test_status_marker_adoption_follows_each_field_device || exit $?
test_signal_rescan_deduplicates_pending || exit $?
test_long_status_scan_keeps_beacon_fresh || exit $?
test_progressing_status_read_outlives_stall_bound || exit $?
test_idle_status_read_is_stalled || exit $?
test_vanished_status_log_is_a_quiet_empty_span || exit $?
