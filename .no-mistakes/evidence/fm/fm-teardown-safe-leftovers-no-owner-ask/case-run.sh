#!/bin/bash
# usage: case-run.sh <tree-root> <test-file-with-cases> <case-name>
# Plain bash: loads the block of the test file from r5_harness to the case list
# (the round 5 and PR 400 library-level cases and their harness), with no suite
# runner and no exit trap, then runs one case against the tree's bin/.
set -u
ROOT=$1 FILE=$2 CASE=$3
mkdir -p /private/tmp/fm-fm-teardown-safe-leftovers-no-owner-ask
TMP_ROOT=$(mktemp -d /private/tmp/fm-fm-teardown-safe-leftovers-no-owner-ask/case.XXXXXX)
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
R5_OUT=/dev/null R5_ERR=/dev/null
fail() { echo "not ok - $1"; echo "--- out"; cat "$R5_OUT"; echo "--- err"; tail -20 "$R5_ERR"; echo "tmp=$TMP_ROOT"; exit 1; }
pass() { echo "ok - $1"; }
skip_case() { printf 'SKIP - %s: %s\n' "$1" "$2"; }
block=$(sed -n '/^r5_harness() {/,/^teardown_test_cases=(/p' "$FILE" | sed '$d')
[ -n "$block" ] || { echo "not ok - no r5_harness block in $FILE"; exit 2; }
eval "$block"
declare -F "$CASE" >/dev/null || { echo "not ok - $CASE not defined in $FILE"; exit 2; }
"$CASE"
echo "tmp=$TMP_ROOT"
