#!/usr/bin/env bash
set -u
REPO=$1 LAB=$2
. "$REPO/bin/fm-tasks-axi-lib.sh"
. "$REPO/bin/fm-backlog-transition-lib.sh"
fm_backlog_ledger_closed "$LAB/state" "$LAB/config" led-local --note "local main"
fm_backlog_ledger_closed "$LAB/state" "$LAB/config" led-drop --note dropped
fm_backlog_ledger_closed "$LAB/state" "$LAB/config" led-bundle --note "preserved in bundle /x/y.bundle, not landed"
fm_backlog_ledger_closed "$LAB/state" "$LAB/config" led-plain
fm_backlog_ledger_closed "$LAB/state" "$LAB/config" led-lookalike --note "preserved in bundle rel/y.bundle, not landed"
