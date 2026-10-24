#!/usr/bin/env bash
# Retirement test for jev-write-judgment-unavailable.
# A write whose content judgment could not run (provider outage, a request too
# large, or never-send withholding) was denied for review, refusing harmless
# writes such as a worker's own report. Writes no longer need a content judgment.
# Pass case: with the provider answering 503, and again with the content listed
# in the never-send policy, a report write is admitted without any judgment.
# Block case: a shell command that is not read-only is still denied for review
# while the same provider is down.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-retired-jev-write-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-retired-jev-write-fixture.sh"
rjw_setup fm-retired-write-unavailable down

printf 'Measured observations in an ordinary report.\n' >"$RJW_TMP/report.md"
rjw_write "$RJW_WT/report.md" "$RJW_TMP/report.md"
rjw_assert_admitted "report write during a provider outage"
printf 'Measured observations\n' >"$RJW_HOME/config/dispatch-never-send"
rjw_write "$RJW_WT/report.md" "$RJW_TMP/report.md"
rjw_assert_admitted "report write holding never-send text"
rm -f "$RJW_HOME/config/dispatch-never-send"
pass "report writes are admitted with no judgment during an outage and under never-send text"

rjw_shell 'touch retired-fixture'
[ "$rjw_status" -eq 0 ] || fail "outage control exited $rjw_status"
rjw_denied || fail "a shell command was admitted while its judgment could not run: $rjw_out"
[ "$(rjw_requests)" -ge 1 ] || fail "the outage control never reached the provider"
pass "a shell command whose judgment cannot run is still denied for review"
