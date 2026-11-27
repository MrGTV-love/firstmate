#!/usr/bin/env bash
# Regression tests for bin/fm-drift-check.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-drift-check)
CHECK="$ROOT/bin/fm-drift-check.sh"

make_repo() {
  local name=$1
  local bare="$TMP_ROOT/$name-origin.git"
  local repo="$TMP_ROOT/$name"
  git init -q --bare "$bare"
  git init -q -b main "$repo"
  git -C "$repo" config user.name fixture
  git -C "$repo" config user.email fixture@example.invalid
  printf 'initial\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial"
  git -C "$repo" remote add origin "$bare"
  git -C "$repo" push -q -u origin main
  git -C "$repo" checkout -q --detach origin/main
  printf '%s\n' "$repo"
}

# 1. Clean detached primary checkout passes with exit 0.
REPO_CLEAN=$(make_repo clean)
out=$(bash "$CHECK" --repo "$REPO_CLEAN" 2>&1)
rc=$?
assert_equals "0" "$rc" "clean detached primary checkout exits 0"
assert_contains "$out" "OK: primary checkout clean at origin/main" "clean checkout prints OK summary"

# 2. Primary checkout on a named branch reports drift and exits 1 (and 0 with --warn-only).
git -C "$REPO_CLEAN" checkout -q main
out=$(bash "$CHECK" --repo "$REPO_CLEAN" 2>&1)
rc=$?
assert_equals "1" "$rc" "named branch on primary checkout exits 1"
assert_contains "$out" "DRIFT: primary checkout is on branch 'main'" "named branch drift message"

out_warn=$(bash "$CHECK" --repo "$REPO_CLEAN" --warn-only 2>&1)
rc_warn=$?
assert_equals "0" "$rc_warn" "--warn-only exits 0 even with drift"
assert_contains "$out_warn" "DRIFT: primary checkout is on branch 'main'" "--warn-only still prints drift"

git -C "$REPO_CLEAN" checkout -q --detach origin/main

# 3. Modified tracked file on primary checkout reports drift.
printf 'dirty\n' >> "$REPO_CLEAN/README.md"
out=$(bash "$CHECK" --repo "$REPO_CLEAN" 2>&1)
rc=$?
assert_equals "1" "$rc" "modified tracked file exits 1"
assert_contains "$out" "DRIFT: primary checkout has modified tracked files:" "dirty tracked file drift header"
assert_contains "$out" "README.md" "dirty tracked file listed"
git -C "$REPO_CLEAN" checkout -q -- README.md

# 4. Stale unpushed branch (>max-ahead or >max-age-days) is flagged; fresh pushed branch is not.
git -C "$REPO_CLEAN" branch fresh-feature origin/main
git -C "$REPO_CLEAN" checkout -q fresh-feature
printf 'one\n' > "$REPO_CLEAN/one.txt"
git -C "$REPO_CLEAN" add one.txt
git -C "$REPO_CLEAN" commit -q -m "commit 1"
printf 'two\n' > "$REPO_CLEAN/two.txt"
git -C "$REPO_CLEAN" add two.txt
git -C "$REPO_CLEAN" commit -q -m "commit 2"
git -C "$REPO_CLEAN" checkout -q --detach origin/main

out=$(bash "$CHECK" --repo "$REPO_CLEAN" --max-ahead 1 2>&1)
rc=$?
assert_equals "1" "$rc" "branch exceeding --max-ahead exits 1"
assert_contains "$out" "fresh-feature (+2 vs origin/main" "branch ahead count reported"

out_ok=$(bash "$CHECK" --repo "$REPO_CLEAN" --max-ahead 5 2>&1)
rc_ok=$?
assert_equals "0" "$rc_ok" "recent branch within --max-ahead exits 0"
assert_contains "$out_ok" "OK: primary checkout clean" "within-threshold branch prints OK"
git -C "$REPO_CLEAN" branch -q -D fresh-feature

# 5. Linked worktrees: Treehouse pool path is allowed; non-Treehouse and prunable worktrees are flagged.
th_wt="$TMP_ROOT/.treehouse/pool-1/slot"
mkdir -p "$(dirname "$th_wt")"
git -C "$REPO_CLEAN" worktree add -q --detach "$th_wt" origin/main
out=$(bash "$CHECK" --repo "$REPO_CLEAN" 2>&1)
rc=$?
assert_equals "0" "$rc" "Treehouse pool worktree is not flagged as drift"

stray_wt="$TMP_ROOT/stray-worktree"
git -C "$REPO_CLEAN" worktree add -q --detach "$stray_wt" origin/main
out=$(bash "$CHECK" --repo "$REPO_CLEAN" 2>&1)
rc=$?
assert_equals "1" "$rc" "non-Treehouse worktree exits 1"
assert_contains "$out" "DRIFT: 1 non-Treehouse worktree(s):" "non-Treehouse worktree header"
assert_contains "$out" "stray-worktree" "non-Treehouse worktree path printed"

# Removing the stray worktree directory without git worktree prune turns it into prunable drift.
rm -rf "$stray_wt"
out=$(bash "$CHECK" --repo "$REPO_CLEAN" 2>&1)
rc=$?
assert_equals "1" "$rc" "prunable worktree exits 1"
assert_contains "$out" "DRIFT: 1 prunable worktree(s)" "prunable worktree drift reported"

git -C "$REPO_CLEAN" worktree prune
git -C "$REPO_CLEAN" worktree remove -f "$th_wt"

# 6. Invalid arguments and missing base ref exit 2.
bash "$CHECK" --repo "$REPO_CLEAN" --max-ahead notanumber >/dev/null 2>&1
assert_equals "2" "$?" "invalid --max-ahead exits 2"
bash "$CHECK" --repo "$REPO_CLEAN" --base refs/heads/does-not-exist >/dev/null 2>&1
assert_equals "2" "$?" "missing base ref exits 2"
pass "fm-drift-check"
