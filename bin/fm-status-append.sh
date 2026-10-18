#!/usr/bin/env bash
# fm-status-append.sh - the sanctioned worker write to a task status log.
#
# Usage: fm-status-append.sh <status-file> <line>...
#
# Appends each <line> (one status event, no trailing newline) to <status-file>
# under the size bound owned by
# bin/fm-status-cap-lib.sh and described in docs/configuration.md "Status log size
# bounds". bin/fm-brief.sh puts this command in every worker's instructions.
#
# Why a helper and not a bare `>>`: a status log is a record every supervision
# reader walks, and on 2026-10-18 a loop appending to three of them filled the
# disk. This command makes that impossible through the sanctioned path: a line that
# would pass the cap is refused, loudly, with exit 75, and nothing is written. Only
# a decision or terminal line (anything but working: and note:) may use the reserve
# above the cap, so a worker at the cap can still report done: or blocked:. A line
# repeated by a loop is written like any other until the cap refuses it. A log
# already past cap plus reserve refuses every line, terminal ones included, and each
# refusal names the file on stderr. It never deletes, truncates or rewrites an
# existing event line. Exit status: 0 when every line was appended, 75 when one was
# refused at the cap, 2 for a malformed call, 1 for any other failure.
#
# tests/fm-status-runaway-guard.test.sh is the regression entry point.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-status-cap-lib.sh
. "$SCRIPT_DIR/fm-status-cap-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "usage: fm-status-append.sh <status-file> <line>..." >&2
  exit 2
fi
FILE=$1
shift
for LINE in "$@"; do
  case "$LINE" in *$'\n'*) echo "fm-status-append: one event per argument; no newline inside a line" >&2; exit 2 ;; esac
done
if [ -L "$FILE" ]; then
  echo "fm-status-append: refusing a symbolic link: $FILE" >&2
  exit 1
fi

fm_status_append_lines "$FILE" "$@"
