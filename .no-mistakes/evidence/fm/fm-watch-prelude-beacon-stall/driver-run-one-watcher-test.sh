#!/usr/bin/env bash
set -u
. "$1/tests/fm-watch-triage-helpers.sh"
test_pending_reply_pass_keeps_the_beacon_fresh
echo "ok - driver done"
