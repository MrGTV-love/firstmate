#!/usr/bin/env bash
# Retirement test for jev-write-remainder-shapes.
# Writes too long for model screening had their whole replacement text checked
# for credential shapes before any model request. With no write-content model
# screening there is no remainder; the shapes run over added lines at commit.
# Pass case: a write of about 300 KB ending in a GitHub token shape is admitted
# without any judgment.
# Block case: committing that file refuses by name without printing the value.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-retired-jev-write-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-retired-jev-write-fixture.sh"
rjw_setup fm-retired-write-remainder

for _ in $(seq 1 6000); do printf 'Measured observations in an ordinary report.\n'; done >"$RJW_TMP/report.md"
printf 'token ghp_%036d\n' 0 >>"$RJW_TMP/report.md"
[ "$(wc -c <"$RJW_TMP/report.md" | tr -d ' ')" -gt 262144 ] || fail "fixture is not beyond the old screening budget"
rjw_write "$RJW_WT/report.md" "$RJW_TMP/report.md"
rjw_assert_admitted "long write ending in a credential shape"
pass "a long write whose remainder holds a credential shape is admitted with no judgment"

cp "$RJW_TMP/report.md" "$RJW_WT/report.md"
git -C "$RJW_WT" add report.md
before=$(git -C "$RJW_WT" rev-parse HEAD)
rjw_commit 'report with credential'
[ "$rjw_status" -ne 0 ] || fail "the commit check admitted the credential shape"
assert_contains "$rjw_out" report.md "commit refusal did not name the file"
assert_not_contains "$rjw_out" ghp_ "commit refusal printed the matching value"
assert_equals "$before" "$(git -C "$RJW_WT" rev-parse HEAD)" "the refused commit moved HEAD"
rjw_assert_guard_active
pass "the same shapes refuse the added lines at commit, and the admitting guard was active"
