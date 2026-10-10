#!/bin/bash
# call-reader.sh <bin-dir> <function> <status-file>: source the status library and call one reader.
. "$1/fm-status-decision-lib.sh"
"$2" "$3"
