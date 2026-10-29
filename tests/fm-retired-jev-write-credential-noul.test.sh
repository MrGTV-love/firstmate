#!/usr/bin/env bash
# Retirement test for jev-write-credential-noul.
# The contains_secret Noul refused writes whose content scored as a real
# credential. Writing a key into an ignored .env is correct behaviour; the harm
# is the key reaching a commit or a push, where the replacement check runs.
# Pass case: writing a GitHub token shape to an ignored .env, with a judge that
# would score it 0.99, is admitted without any judgment and stages nothing.
# Block case: force-adding that file still refuses at commit.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-retired-jev-write-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-retired-jev-write-fixture.sh"
rjw_setup fm-retired-write-noul

printf '.env\n' >"$RJW_WT/.gitignore"
git -C "$RJW_WT" add .gitignore
rjw_commit 'ignore local environment'
[ "$rjw_status" -eq 0 ] || fail "ignore setup did not commit: $rjw_out"
before=$(git -C "$RJW_WT" rev-parse HEAD)
printf 'GITHUB_TOKEN=ghp_%036d\n' 0 >"$RJW_TMP/env"
rjw_write "$RJW_WT/.env" "$RJW_TMP/env"
rjw_assert_admitted "credential write to an ignored .env"
cp "$RJW_TMP/env" "$RJW_WT/.env"
git -C "$RJW_WT" add -A
assert_equals '' "$(git -C "$RJW_WT" diff --cached --name-only)" "the ignored .env entered the index"
pass "a credential write the Noul would score 0.99 is admitted with no judgment and stages nothing"

git -C "$RJW_WT" add -f .env
rjw_commit 'force-added credential'
[ "$rjw_status" -ne 0 ] || fail "the commit check admitted a force-added credential"
assert_contains "$rjw_out" .env "commit refusal did not name the file"
assert_not_contains "$rjw_out" ghp_ "commit refusal printed the matching value"
assert_equals "$before" "$(git -C "$RJW_WT" rev-parse HEAD)" "the refused commit moved HEAD"
rjw_assert_guard_active
pass "a force-added credential still refuses at commit, and the admitting guard was active"
