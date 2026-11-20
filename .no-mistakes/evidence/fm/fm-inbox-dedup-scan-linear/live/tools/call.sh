#!/bin/bash
# call.sh <lib-root> <state-dir> <task> <text> [delivery-mode]
# Sources the real lib from <lib-root> and calls the idempotent writer once.
set -u
. "$1/bin/fm-pending-reply-lib.sh"
. "$1/bin/fm-marker-lib.sh"
. "$1/bin/fm-task-inbox-lib.sh"
fm_task_inbox_write_idempotent "$2" "$3" "$4" ${5:-}
