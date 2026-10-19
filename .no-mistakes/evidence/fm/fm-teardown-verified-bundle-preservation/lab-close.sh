#!/usr/bin/env bash
# Drives the same product function bin/fm-teardown.sh calls to close a row:
# fm_backlog_done <data-dir> <id> [flags]. usage: lab-close.sh <repo> <data-dir> <id> [flags...]
set -u
REPO=$1 DATA=$2 ID=$3; shift 3
. "$REPO/bin/fm-tasks-axi-lib.sh"
. "$REPO/bin/fm-backlog-transition-lib.sh"
fm_backlog_done "$DATA" "$ID" "$@"
