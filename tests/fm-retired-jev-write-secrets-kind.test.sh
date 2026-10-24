#!/usr/bin/env bash
# Retirement test for jev-write-secrets-kind.
# The write kind Choice gated writes on a "secrets" file label. It never fired in
# 4,363 judged writes, and the harm it named happens at commit and push.
# Pass case: writing a secrets-shaped configuration file holding placeholders,
# with a judge that would label it secrets at confidence 1, is admitted without
# any judgment, and the placeholder file commits through the task hooks.
# Block case: the replacement commit check still refuses a real credential shape.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-retired-jev-write-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-retired-jev-write-fixture.sh"
rjw_setup fm-retired-write-kind label-only

mkdir -p "$RJW_WT/config"
printf 'api_key: replace-me\npassword: xxx\n' >"$RJW_TMP/secrets.yml"
rjw_write "$RJW_WT/config/secrets.yml" "$RJW_TMP/secrets.yml"
rjw_assert_admitted "secrets-kind write"
cp "$RJW_TMP/secrets.yml" "$RJW_WT/config/secrets.yml"
git -C "$RJW_WT" add config/secrets.yml
rjw_commit 'placeholder secrets file'
[ "$rjw_status" -eq 0 ] || fail "a placeholder secrets file did not commit: $rjw_out"
pass "a write the kind judge would label secrets is admitted with no judgment and its placeholders commit"

printf 'api_key: ghp_%036d\n' 0 >"$RJW_WT/config/secrets.yml"
git -C "$RJW_WT" add config/secrets.yml
rjw_commit 'real credential shape'
[ "$rjw_status" -ne 0 ] || fail "the commit check admitted a GitHub token shape"
assert_contains "$rjw_out" config/secrets.yml "commit refusal did not name the file"
assert_not_contains "$rjw_out" ghp_ "commit refusal printed the matching value"
rjw_assert_guard_active
pass "the commit check still refuses a credential shape, and the admitting guard was active"
