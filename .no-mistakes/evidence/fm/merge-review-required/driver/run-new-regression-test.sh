#!/usr/bin/env bash
# Runs test_github_review_required_refuses from the change's test file against
# the script tree given as $2 (the change, or the base commit). Usage: <worktree> <script-root>
set -u
WT=$1 TARGET=$2
. "$WT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
H=$(mktemp "${TMPDIR:-/tmp}/fm-rr.XXXXXX")
sed -n '15,784p' "$WT/tests/fm-pr-merge.test.sh" > "$H"
sed -n '/^test_github_review_required_refuses() {/,/^}/p' "$WT/tests/fm-pr-merge.test.sh" >> "$H"
. "$H"; rm -f "$H"
ROOT=$TARGET PR_MERGE="$TARGET/bin/fm-pr-merge.sh"
echo "running test_github_review_required_refuses against $PR_MERGE"
test_github_review_required_refuses
