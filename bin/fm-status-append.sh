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
# disk. This command makes that impossible through the sanctioned path:
#   - an exact consecutive repeat of the last event (compared without its
#     [at=<epoch>] stamp) is counted in ONE note line that follows it, whose
#     fixed-width number is rewritten in place, so a loop adds one line and no
#     further bytes, and the count stays exact;
#   - a line that would pass the cap is refused, loudly, with exit 75, and nothing
#     is written; only a decision or terminal line (anything but working: and
#     note:) may use the reserve above the cap, so a worker at the cap can still
#     report done: or blocked:.
# It never deletes, truncates or rewrites an existing event line. Exit status: 0
# when every line was appended or counted, 75 when one was refused at the cap, 2
# for a malformed call, 1 for any other failure.
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

# stdout of the library is one token per line; only a counted repeat is news to
# the worker, and it goes to stderr with the refusal messages.
tokens=$(fm_status_append_lines "$FILE" "$@")
rc=$?
for token in $tokens; do
  case "$token" in
    collapsed:*) echo "fm-status-append: repeat ${token#collapsed:} of the previous event counted in its note line, not written again" >&2 ;;
  esac
done
exit "$rc"
